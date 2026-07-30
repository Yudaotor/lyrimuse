// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"errors"
	"log"
	"math"
	"slices"
	"time"
)

// playSession tracks accrued playtime of the current track for the
// half-or-4-minutes listen rule.
type playSession struct {
	key         string
	meta        snapshot
	startedAt   time.Time
	playedSecs  float64
	lastSeen    time.Time // zero while paused
	listenSent  bool
	lastPN      time.Time
	lastPlaying bool // last observed play/pause state, to detect transitions
	pnPending   bool // 首条 playing_now 因歌词还在异步解析而挂起(LB 只认换曲那条,故首条必须带歌词)
	// submitting/announcing:见 submitSingleAsync/announce 顶部的设计说明——LB 提交
	// 挪到后台 goroutine 跑之后,这两个标记防止同一个 session 在上一次提交结果还没
	// 返回时(LB 慢时 single 类型最长可达约 24s)被下一轮 5s poll 重复触发一次提交。
	submitting bool
	announcing bool
}

func listenThreshold(duration float64) float64 {
	if duration > 0 {
		return min(duration/2, listenCapSecs)
	}
	return listenCapSecs
}

// seedPosition derives the true current playback position (seconds) from a
// media-control reading. media-control freezes elapsedTime/timestamp at the
// moment a track started (observed: a track 133s in still reports elapsed≈0 with
// timestamp 133s ago), so the real position is elapsed + (now - McTS)*rate. Used
// when (re)anchoring on a new track / seek / restart; if only elapsed were taken,
// the progress bar would trail reality by up to a poll interval (more on restart
// onto a mid-track). Paused: position is frozen, so no catch-up is added.
func seedPosition(elapsed, rate float64, playing bool, mcTS, now time.Time) float64 {
	p := elapsed
	if !playing {
		return p
	}
	if rate == 0 { // media-control briefly reports rate=0 right as a track loads
		rate = 1
	}
	if !mcTS.IsZero() {
		if d := now.Sub(mcTS).Seconds(); d > 0 {
			p += d * rate
		}
	}
	return p
}

// poller holds all the mutable state a run() loop iteration reads/writes,
// organized as a struct + methods (rather than closures over run()'s locals)
// so each piece can be unit-tested in isolation.
type poller struct {
	ctx context.Context
	cfg *config
	lb  *lbClient

	lfm         *lastfmScrobbler
	lfmMirrored map[int64]bool

	cur  snapshot
	sess *playSession
	// 供 null-glitch 假死恢复续接用:最近一次因"停播"(含假死误判)终结的 session 及其
	// 终结时刻,见 finalize()/handle() 里 nullResumeGraceWindow 的用法。
	recentFinalized   *playSession
	recentFinalizedAt time.Time

	// Position tracking. media-control freezes elapsedTime during steady play and
	// its timestamp drifts stale across sleep/idle, so we can't just extrapolate
	// from it. Instead we advance the position by our OWN wall-clock between polls
	// while playing, and re-anchor to media-control's elapsedTime on real
	// discontinuities (new track, seek, pause, or a large poll gap = sleep). The
	// result (cur.Position at cur.AnchorTS=now) is what we publish, so the web
	// only ever extrapolates a few fresh seconds. updatePosition returns true on a
	// re-anchor, so the caller can publish it promptly instead of waiting for the
	// refresh.
	trackPos   float64
	trackKey   string
	prevElapse float64
	prevWall   time.Time

	// 自建状态中继:每轮把"网页该显示的当前状态"推到 /push(Mac 在放优先,否则 iPhone
	// 镜像,否则上次播放)。按状态变化 + 心跳去重。remoteTrack/lastListen 由 bridge/
	// finalize 更新。这是取代 LB 作网页主数据源的写入端。
	relayLastState string
	relayLastAt    time.Time
	relayWrites    int           // 累计成功 KV /push 写次数(埋点:实测每日写量+定位大头)
	relayFailKey   string        // 上次推送失败时的 key:内容变了就清退避、立即再试
	relayFailAt    time.Time     // 上次推送失败时刻(零=当前无退避)
	relayBackoff   time.Duration // 当前退避间隔(失败翻倍,上限 10min)
	remoteTrack    snapshot      // iPhone(经 Last.fm)当前在播;remoteAt 为零表示无
	remoteAt       time.Time
	lastListen     snapshot // 最近一条完成收听(供空闲时显示"上次播放")
	lastListenAt   int64
	lastListenDev  string

	// Last.fm bridge (iPhone via FastScrobbler→Last.fm) state.
	forwardedSet     persistedTTLSet
	lfmMirroredSet   persistedTTLSet
	lastfmCheckedAt  time.Time
	bridgeFetching   bool // 见 bridge()/applyBridgeResult 顶部注释,防止同时起两个 lastfmRecent 请求
	remoteKey        string
	remotePN         time.Time
	forwarded        map[int64]bool
	fwdSeeded        bool
	recentMacListens []recentListen // 见 recordRecentMacListen

	// Last.fm 每周听歌小结推送(见 weekly.go)，复用桥接同一套 lastfm_user/lastfm_api_key。
	weeklyState         weeklyDigestState
	weeklyLastCheckedAt time.Time

	// ListenBrainz 每日听歌报告推送(见 daily.go)，复用提交收听同一套 cfg.User/cfg.Token，
	// 跟上面的 Last.fm 每周小结是两个独立功能。
	dailyState         dailyDigestState
	dailyLastCheckedAt time.Time

	// 历史播放 Top10 歌手,一天算一次推给状态中继(见 topartists.go)。
	topArtistsState         topArtistsState
	topArtistsLastCheckedAt time.Time

	nullStreak int

	// LB 提交(single/playing_now)改到后台 goroutine 跑，结果经这两个 channel 送回单一
	// 的 poll 主循环处理——goroutine 本身只做网络 I/O,不直接碰 session/poller 字段，
	// 所有状态变更仍然只发生在 poll 主循环里，不引入并发读写。见 submitSingleAsync/
	// announce 顶部注释、run() 里的 drain 分支。
	submitDoneCh   chan submitOutcome
	announceDoneCh chan announceOutcome
	// bridge() 里读 Last.fm(lastfmRecent,8s 超时)改到后台 goroutine 跑,结果经这个
	// channel 送回单一 poll 主循环处理——理由同 submitDoneCh/announceDoneCh:Last.fm
	// 一慢,同步调用会连带堵住 poll() 后面紧接着的 pushRelayState,让网页刷新(包括
	// enrichNotify 刚解析出的封面/歌词)跟着冻结最长 8 秒。
	bridgeDoneCh chan bridgeFetchResult
}

// bridgeFetchResult 是后台 goroutine 拉取 Last.fm 数据(lastfmRecent)的结果，经
// bridgeDoneCh 送回 poll 主循环，由 applyBridgeResult 处理(转发/镜像 iPhone 状态等
// 有状态副作用的逻辑，仍只在主循环里跑，不引入并发读写)。
type bridgeFetchResult struct {
	now  time.Time
	np   *lastfmTrack
	done []lastfmTrack
	ok   bool
}

const lastfmPollInterval = 15 * time.Second

// nearDuplicateWindow：见 recordRecentMacListen 注释。同一首歌从 Mac 完成收听到在
// Last.fm 上冒出一条"独立"的第二条(带 (Remaster) 等标题后缀、uts 对不上我方镜像写入
// 值)之间，观察到的间隔在 4~19 分钟不等，取 30 分钟留足余量。这个窗口只判断"两条记录
// 的 listened_at 是否足够接近、代表同一次物理收听"，不是缓冲区保留多久（见
// recentMacListenRetention）。
const nearDuplicateWindow = 30 * time.Minute

// recentMacListenRetention：recentMacListens 缓冲区实际保留多久。故意跟
// nearDuplicateWindow（判重阈值）解耦：FastScrobbler 把 scrobble 转发到 Last.fm
// 服务器这一步可能顺延数小时甚至跨夜，如果保留时长也只有 30 分钟，早的那条 Mac 记录
// 会被后续新记录挤掉，等 bridge() 终于看到延迟的回声时缓冲区里已经找不到匹配项，被
// 误判成"iPhone 新收听"转发进去，造成同一首歌历史里一条 mac 一条 iphone 的重复。这里
// 给足 24 小时覆盖观察到的最长延迟；缓冲区里存的 (artist,title,uts) 三元组一天顶多
// 几百条，内存开销可以忽略。
const recentMacListenRetention = 24 * time.Hour

// recentListen 是最近一条已确认的 Mac 完成收听(artist/title/uts)，只用于
// recentlyPlayedOnMac 的窗口去重检查。
type recentListen struct {
	artist, title string
	uts           int64
}

// recordRecentMacListen 记一条刚完成的 Mac 收听，供 bridge() 的近重复抑制检查用。
// 背景：iPhone 侧的 FastScrobbler 有时会经 Apple Music 跨设备"最近播放"同步，把 Mac
// 已经播过、已经通过 lfm 镜像写过一次的同一首歌，在几分钟到十几分钟后又单独 scrobble
// 一次到 Last.fm——新生成的 uts 跟我方镜像写入值不一致(标题有时还带 "(2012 Remaster)"
// 这类 Last.fm/MusicBrainz 校正后缀)，lfmMirroredSet 的精确 uts 匹配抓不到，bridge()
// 会把它当"iPhone 新收听"转发进 LB，造成同一首歌历史里一条 source=mac、一条
// source=iphone 的重复。这条记录只喂给"名字够像+时间够近"的兜底检查，不影响精确匹配
// 那条路径。
func (p *poller) recordRecentMacListen(artist, title string, uts int64) {
	p.recentMacListens = append(p.recentMacListens, recentListen{artist: artist, title: title, uts: uts})
	cutoff := uts - int64(recentMacListenRetention/time.Second)
	kept := p.recentMacListens[:0]
	for _, r := range p.recentMacListens {
		if r.uts >= cutoff {
			kept = append(kept, r)
		}
	}
	p.recentMacListens = kept
}

// recentlyPlayedOnMac reports whether artist/title matches a Mac listen
// recorded within nearDuplicateWindow of uts — see recordRecentMacListen。
// 艺人名允许"精确匹配 或 宽松互相包含"(而不是只认 artistMatches 那种更严格的精确/
// 逗号分割式匹配)——FastScrobbler 侧有时会把艺人报成缩写艺名(比如漏掉合作艺人)，
// artistMatches 判不过会漏判。这里放宽风险可控:判重失败最多是漏转发一条真实 iPhone
// 收听(少记，不是错记成别人的封面/歌词那种会显示错误信息的场景，跟 artistMatches 本来
// 要防的仿冒号场景不是一个量级)。
func (p *poller) recentlyPlayedOnMac(artist, title string, uts int64) bool {
	for _, r := range p.recentMacListens {
		artistOK := artistMatches(r.artist, artist) || looseContains(r.artist, artist)
		if !artistOK || !looseContains(r.title, title) {
			continue
		}
		d := uts - r.uts
		if d < 0 {
			d = -d
		}
		if d <= int64(nearDuplicateWindow/time.Second) {
			return true
		}
	}
	return false
}

// isTracked reports whether the currently observed track is a real
// observation from one of the tracked bundle IDs (cfg.BundleIDs) — the
// "is this someone I actually care about" check that used to be repeated
// (with slightly different combinations of the cur.Playing check) at each of
// pushRelayState/handle/bridge/poll.
//
// 也接受当前选定播放器(features.Player)自己期望的 bundle id,不只是 cfg.BundleIDs
// 里配置的那份——getState() 的两条路径(getAppleMusicState/getQQMusicState)只会在
// bundle id 确实对得上当前选定的播放器时才产出非空快照,所以这里理应无条件认它,不能
// 因为用户没有额外手动去 config.json 里加一条 bundle_ids 就把 QQ 音乐的播放判定成
// "不是我关心的来源"。cfg.BundleIDs 仍然保留:留给需要额外识别别的 bundle id 的高级
// 用法。
func (p *poller) isTracked() bool {
	if p.cur.key() == "" {
		return false
	}
	if slices.Contains(p.cfg.BundleIDs, p.cur.Bundle) {
		return true
	}
	// playerAuto("自动识别")没有唯一固定的期望 bundle id——getAutoDetectedState 已经
	// 只在确认是四个已知播放器之一时才产出非空快照,这里认它是不是这四个之一即可,不能
	// 拿 expectedPlayerBundleID() 那种"只认一个固定值"的判断(会把除了默认兜底值以外
	// 的其它三个播放器误判成"不是我关心的来源")。
	if features.Player == playerAuto {
		return isKnownPlayerBundleID(p.cur.Bundle)
	}
	return p.cur.Bundle == expectedPlayerBundleID()
}

// mirrorScrobbleTracked 先同步记入"已镜像"集合并落盘,再异步镜像写入 Last.fm——见
// lfmMirroredTTL 处注释:写入必须先于发起请求完成,防 bridge 抢在标记前误转发。
func (p *poller) mirrorScrobbleTracked(artist, title, album string, timestamp int64) {
	if p.lfm == nil || timestamp <= 0 {
		return
	}
	p.lfmMirrored[timestamp] = true
	p.lfmMirroredSet.save(p.lfmMirrored)
	mirrorAsync(p.lfm, "scrobble", func(ctx context.Context) error {
		return p.lfm.scrobble(ctx, artist, title, album, timestamp)
	})
}

// loopRestartMinElapsedFrac/loopRestartMaxNewElapsedSecs 判定"单曲循环重新起播"(含
// Apple Music 原生单曲循环、以及手动把进度条拖回接近开头这两种变体)：这一轮开始前
// 我们自己追踪的位置(trackPos)已经播到了 90% 时长以上,这一轮算出来的新位置又回到了
// 开头 10 秒以内——普通向后拖动进度条(比如从 3 分钟拖回 2 分钟)不会同时满足这两个
// 极端条件。
//
// ⚠️ 这条判定必须建立在"我们自己连续追踪的 trackPos"上,不能挂在任何一个具体的
// switch 分支/或 media-control 的 Elapsed 字段变化上——Apple Music 原生单曲循环
// 重新起播时,media-control 的 elapsedTime 有时全程冻结在轨道最近一次真正开播的锚点
// (常年是 0,见 seedPosition 注释"a track 133s in still reports elapsed≈0"),循环
// 前后 Elapsed 值一样、不会触发"Elapsed 变了"那个 discontinuity 判断；即使某次
// Elapsed 确有变化，变化前的值(prevElapse)也可能一直冻结在低位、不满足"上一次接近
// 末尾"这个子条件，同样会被绑在具体分支里的判定漏判。现在不管 switch 走了哪个分支
// 算出新位置,统一在 switch 结束后用"prevTrackPos(这一轮开始前)"vs"p.trackPos(这一轮
// 算出来的)"判定,不关心中间是通过 seedFromMC() 还是 wall-clock 累加得到的,天然不受
// media-control 具体行为差异影响。
const (
	loopRestartMinElapsedFrac    = 0.9
	loopRestartMaxNewElapsedSecs = 10.0
	// system.go 用 AppleScript(Music.playerPosition())取代 media-control 后,Elapsed
	// 不再于稳定播放期间"冻结"、而是每一轮轮询都读到当下的实时进度。updatePosition()
	// 判断"是否是 seek/resume"因此不能再用逐字节的 != 比较——那会把平稳播放的每一轮
	// 都误判成一次 seek,绕过 pushRelayState 的"变化才写"节流,播放中每个 pollInterval
	// 都写一次 KV,足以烧穿 1000 写/天的免费额度。改成"实际值 vs 按 gap*rate 预测的值,
	// 偏差是否超出容差"。2 秒容差:大于轮询间隔的正常抖动(进程调度/AppleScript 调用
	// 往返延迟),小于真实 seek/跳曲通常至少几秒的跳变量。
	seekJumpToleranceSecs = 2.0
)

func (p *poller) updatePosition(now time.Time) (reanchor bool, loopRestart bool) {
	key := p.cur.key()
	if key == "" { // nothing playing
		p.trackKey, p.prevWall = "", time.Time{}
		p.cur.Position, p.cur.AnchorTS = 0, now
		return false, false
	}
	sameTrackAsBefore := key == p.trackKey
	prevTrackPos := p.trackPos
	gap := now.Sub(p.prevWall).Seconds()
	reanchor = true
	seedFromMC := func() float64 { return seedPosition(p.cur.Elapsed, p.cur.Rate, p.cur.Playing, p.cur.McTS, now) }
	switch {
	case key != p.trackKey: // new track / 重启首见 → 用 media-control 锚点补齐真实位置
		p.trackPos = seedFromMC()
	case !p.cur.Playing: // paused → media-control's frozen elapsed is the true position
		p.trackPos = p.cur.Elapsed
		// 暂停后位置冻结不变,不该每轮都当"重新锚定"处理——那会让 pushRelayState
		// 的"变化才写"节流失效,暂停多久就以 pollInterval 频率写多久 KV(实测烧穿
		// 1000写/天配额)。暂停这个事件本身已经通过 key 从 mac|X 变成 macpause|X
		// 触发过一次写入,不需要这里再帮它每轮强制重写。
		reanchor = false
	case math.Abs(p.cur.Elapsed-(p.prevElapse+gap*p.cur.Rate)) > seekJumpToleranceSecs: // seek/resume: actual position diverges from what steady playback alone would predict → re-anchor to it (补 McTS→now)
		p.trackPos = seedFromMC()
	case p.prevWall.IsZero(): // first observation → best guess from media-control's own anchor
		p.trackPos = seedFromMC()
	case gap > 3*pollInterval.Seconds(): // big gap (sleep/App Nap) → trust frozen elapsed, don't count the gap
		p.trackPos = p.cur.Elapsed
	default: // steady play → advance by real elapsed wall time
		p.trackPos += gap * p.cur.Rate
		reanchor = false
	}
	// 单曲循环重新起播判定,见上面常量注释——用 prevTrackPos/p.trackPos 的连续性判断,
	// 不看是哪个分支算出来的。命中时从余数重新起播(而不是硬归零),减少跨越边界这一轮的
	// 外推误差;并强制 reanchor=true,让这次重置立刻推一次 relay,网页进度条不用等到
	// 下次心跳才刷新。
	if sameTrackAsBefore && p.cur.Playing && p.cur.Duration > 0 &&
		prevTrackPos >= p.cur.Duration*loopRestartMinElapsedFrac &&
		(p.trackPos >= p.cur.Duration || p.trackPos <= loopRestartMaxNewElapsedSecs) {
		loopRestart = true
		reanchor = true
		if p.trackPos >= p.cur.Duration {
			p.trackPos -= p.cur.Duration
		}
	}
	if p.cur.Duration > 0 && p.trackPos > p.cur.Duration {
		p.trackPos = p.cur.Duration
	}
	if p.trackPos < 0 {
		p.trackPos = 0
	}
	p.trackKey, p.prevElapse, p.prevWall = key, p.cur.Elapsed, now
	p.cur.Position, p.cur.AnchorTS = p.trackPos, now
	return reanchor, loopRestart
}

// 门槛只看 StateRelayURL 是否配置——不需要 features.StateRelay 这个独立总开关，
// 地址+令牌本身就是唯一的"要不要推"开关(对应 desktop-lyrics 侧
// AccountLinkingTab.swift)。
func (p *poller) pushRelayState(now time.Time, reanchored bool) {
	if p.cfg.StateRelayURL == "" {
		return
	}
	var payload map[string]any
	key := ""
	// 显示优先级:Mac 正在放 > iPhone(经 Last.fm)正在放 > Mac 暂停 > 上次播放。
	// 关键:Mac 只是"有当前曲目但暂停"(没退出 Music)时应让位给 iPhone 正在放的,并如实
	// 报暂停(playing=false)——否则一首暂停没退出的歌会一直盖住 iPhone 正在放的、且误报在播。
	macHasTrack := p.isTracked()
	iphonePlaying := !p.remoteAt.IsZero() && now.Sub(p.remoteAt) < 90*time.Second
	switch {
	case macHasTrack && p.cur.Playing: // Mac 正在放 → 最高优先(带进度条)
		payload = relayState(p.cur, true, "mac", 0, true)
		key = "mac|" + p.cur.key()
	case iphonePlaying: // iPhone(经 Last.fm 桥接)正在放
		payload = relayState(p.remoteTrack, true, "iphone", 0, true)
		key = "ip|" + p.remoteTrack.key()
	case macHasTrack: // Mac 有当前曲目但暂停 → 显示暂停态,让位给 iPhone 正在放
		payload = relayState(p.cur, false, "mac", 0, true) // 暂停但仍是 Mac 界面上此刻的曲目,current=true
		key = "macpause|" + p.cur.key()
	case p.lastListen.key() != "":
		payload = relayState(p.lastListen, false, p.lastListenDev, p.lastListenAt, false) // 纯历史,current=false
		key = "last|" + p.lastListen.key()
	default:
		payload = map[string]any{"ok": true, "empty": true, "playing": false}
		key = "empty"
	}
	// 省 KV 写额度(免费仅 1000 写/天):进度由网页从锚点外推,连播中途无需重写。
	// 只在①状态变化(切歌/暂停/切设备)、②重锚(拖动/唤醒)、③兜底每 4 分钟刷一次
	// 时才写(须 < worker STALE_MS=5min,否则 KV 会被判过期而误退 LB——这俩常数曾经
	// 一个 15min 一个 20min 配得上,后来 worker 那边为了配额爆时更快回退缩到了 5min,
	// 这边忘了跟着改,导致长暂停/长稳定播放期间有 10 分钟窗口白白掉回 LB 兜底)。
	// enrich 完成后同一首歌封面会从无到有 → 并入去重 key,触发一次补推(否则 key 未变被吞)。
	if cov, _ := payload["artwork"].(string); cov != "" {
		key += "|c"
	}
	changed := key != p.relayLastState
	if !changed && !reanchored && now.Sub(p.relayLastAt) < 4*time.Minute {
		return
	}
	writeReason := "heartbeat"
	if changed {
		writeReason = "change"
	} else if reanchored {
		writeReason = "reanchor"
	}
	// 退避:上次推送失败(配额爆/中继挂)后别每轮硬试(否则每 5s 白烧一次 worker 请求+刷屏)。
	// 内容变了(key 变,如换歌)→ 清退避立即再试,让 KV 恢复后尽快回主路径;同内容按退避重试。
	if key != p.relayFailKey {
		p.relayFailAt, p.relayBackoff = time.Time{}, 0
	}
	if !p.relayFailAt.IsZero() && now.Sub(p.relayFailAt) < p.relayBackoff {
		return
	}
	if err := postRelay(p.ctx, p.cfg, "/push", payload); err != nil {
		log.Printf("relay push failed: %v", err)
		p.relayFailKey, p.relayFailAt = key, now
		if p.relayBackoff == 0 {
			p.relayBackoff = 30 * time.Second
		} else if p.relayBackoff < 10*time.Minute {
			p.relayBackoff *= 2
		}
		return // 去重锚点不更新;按退避在后续 poll 重试
	}
	p.relayFailAt, p.relayBackoff, p.relayFailKey = time.Time{}, 0, ""
	p.relayLastState, p.relayLastAt = key, now
	p.relayWrites++
	log.Printf("relay write #%d [%s] key=%q", p.relayWrites, writeReason, key) // 埋点:实测每日 KV 写量与来源
}

// pushScrobble 记一条完成收听。历史/今日统计现改由网页从 LB 合并(每条完成收听已双写 LB,
// 见各 lb.submit "single"),不再写 KV /scrobble——省写额度(①减写)。仅更新内存 lastListen:
// 空闲时"上次播放"显示 + pushRelayState 兜底态用。
func (p *poller) pushScrobble(s snapshot, listenedAt int64, device string) {
	p.lastListen, p.lastListenAt, p.lastListenDev = s, listenedAt, device
}

// submitOutcome/announceOutcome 是后台 goroutine 提交完成后、经 channel 送回单一
// poll 主循环处理的结果。goroutine 本身只做网络 I/O,不直接改 session/poller 字段。
type submitOutcome struct {
	sess      *playSession
	meta      snapshot
	startedAt int64
	err       error
}

type announceOutcome struct {
	sess *playSession
	at   time.Time
	ok   bool
}

// submitSingleAsync 在后台 goroutine 提交一条"完成收听"(single)，不阻塞 poll 主循环——
// LB(文档已知间歇性慢)的 single 类型带重试，最长可达约 24s，堵在主循环里会连带拖住
// pushRelayState(网页展示更新全靠 poll() 按时跑),十几到三十秒展示就会跟着冻结。
// 调用前调用方必须已把 sess.submitting 置 true(防止同一个 session 在结果返回前被
// 下一轮 poll 重复触发提交、造成同一次收听被提交两次)；结果由 applySubmitOutcome
// 统一清除。goroutine 退出时机受 p.ctx 控制,进程退出不会泄漏。
func (p *poller) submitSingleAsync(sess *playSession, meta snapshot, startedAt int64) {
	lm := lbMeta(meta)
	go func() {
		err := p.lb.submit(p.ctx, "single", startedAt, lm)
		select {
		case p.submitDoneCh <- submitOutcome{sess: sess, meta: meta, startedAt: startedAt, err: err}:
		case <-p.ctx.Done():
		}
	}()
}

// applySubmitOutcome 在 poll 主循环里处理 submitSingleAsync 的结果——不管此时 p.sess
// 是否还指向同一个 session(很可能早已因为换曲被 finalize 分离走了)，这里的字段变更和
// 收听记录都只作用于结果自带的 sess/meta，不依赖 p.sess 当前值，所以时序上没有问题。
func (p *poller) applySubmitOutcome(r submitOutcome) {
	r.sess.submitting = false
	if r.err != nil {
		log.Printf("submit listen failed: %v", r.err)
		return
	}
	r.sess.listenSent = true
	log.Printf("listen recorded: %s - %s", r.meta.Artist, r.meta.Title)
	p.pushScrobble(r.meta, r.startedAt, "mac")
	p.mirrorScrobbleTracked(r.meta.Artist, r.meta.Title, r.meta.Album, r.startedAt)
	p.recordRecentMacListen(r.meta.Artist, r.meta.Title, r.startedAt)
	p.pushRelayState(time.Now(), false) // 立刻把刚确认的收听/上次播放状态推给网页,不必等下一轮 5s 心跳
}

// applyAnnounceOutcome 在 poll 主循环里处理 announce() 的异步结果。
func (p *poller) applyAnnounceOutcome(r announceOutcome) {
	r.sess.announcing = false
	if !r.ok {
		return
	}
	r.sess.lastPN = r.at
	r.sess.pnPending = false
	p.pushRelayState(time.Now(), false)
}

func (p *poller) finalize(now time.Time) {
	if p.sess == nil {
		return
	}
	s := p.sess
	p.sess = nil
	p.recentFinalized, p.recentFinalizedAt = s, now
	if s.listenSent || s.submitting || s.meta.Duration > 0 && s.meta.Duration < minTrackSecs {
		return
	}
	if s.playedSecs < listenThreshold(s.meta.Duration) {
		return
	}
	s.submitting = true
	p.submitSingleAsync(s, s.meta, s.startedAt.Unix())
}

// announce 异步提交一条 playing_now，不阻塞 poll 主循环(理由同 submitSingleAsync)。
// 歌词/封面是开播后异步解析的;LB 只认"换曲那条"、同曲存活期内拒覆盖,故首条须带
// 歌词,未就绪时挂起等 enrich(见 handle)。同一个 session 在结果返回前重复调用会被
// 去重(sess.announcing)；lastPN/pnPending 的变更挪到 applyAnnounceOutcome,调用方
// 不再能同步拿到"是否成功"。
func (p *poller) announce(now time.Time, why string) {
	if p.sess.announcing {
		return
	}
	p.sess.announcing = true
	sess := p.sess
	m := lbMeta(p.cur)
	artist, title, album := p.cur.Artist, p.cur.Title, p.cur.Album
	go func() {
		err := p.lb.submit(p.ctx, "playing_now", 0, m)
		if err != nil {
			log.Printf("submit playing_now (%s) failed: %v", why, err)
		} else {
			mirrorAsync(p.lfm, "now-playing", func(ctx context.Context) error {
				return p.lfm.updateNowPlaying(ctx, artist, title, album)
			})
		}
		select {
		case p.announceDoneCh <- announceOutcome{sess: sess, at: now, ok: err == nil}:
		case <-p.ctx.Done():
		}
	}()
}

func (p *poller) handle(now time.Time, reanchored, loopRestart bool) {
	key := p.cur.key()
	isMusic := p.isTracked()

	// Player quit or another app took over: finalize and drop the session.
	if !isMusic {
		if p.sess != nil {
			p.sess.lastSeen = time.Time{}
			p.finalize(now)
		}
		return
	}

	// New track: finalize previous, open a session, announce playing_now.
	if p.sess == nil || p.sess.key != key {
		p.finalize(now)
		if p.recentFinalized != nil && p.recentFinalized.key == key && now.Sub(p.recentFinalizedAt) < nullResumeGraceWindow {
			// media-control 短暂假死(null-glitch)误判停播后同一首歌很快复现:续接旧
			// session(播放进度/是否已提交过 listen 都带过去),不清零重开——否则这次
			// 收听会被假死切成两段,各自达到阈值时向 LB 提交两条重复的 listen。
			p.sess = p.recentFinalized
			p.sess.pnPending = false // 即将重新走一遍"是否需要挂起等歌词"的判定
		} else {
			p.sess = &playSession{key: key, meta: p.cur, startedAt: now, lastPlaying: p.cur.Playing}
			if p.cur.Playing {
				p.sess.lastSeen = now
			}
		}
		p.recentFinalized = nil
		log.Printf("now playing: %s - %s", p.cur.Artist, p.cur.Title)
		// 顺手把同一张专辑里其它还没解析过的曲目也丢到后台解析——用户按专辑顺序一首首听,
		// 提前解析好等真播到那首歌时大概率不用现等。见 albumprefetch.go。
		if features.AlbumPrefetch {
			prefetchAlbumSiblings(p.cur.Artist, p.cur.Title, p.cur.Album)
		}
		// LB 的 playing_now 只在"换曲"时更新、同曲存活期内拒绝覆盖,迟到的歌词再也进不去。
		// 故首条须在 enrich 解析完后再发(那时才知有无歌词、有则带上)。已解析(缓存命中,无论
		// 有无歌词)立即发;仅首次解析中(缓存未命中)才挂起,由下方处理器等 enrich 完成
		// (enrichNotify 触发)或超时再发。仅影响 KV 兜底路径,KV 主路径不受此延迟。
		if len(trackEnrichment(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Duration)) > 0 {
			p.announce(now, "new")
		} else {
			p.sess.pnPending = true
		}
		return
	}

	// 单曲循环重新起播(位置从接近末尾跳回接近开头,key 没变,见 updatePosition 里
	// loopRestart 的判定):上一轮的收听记录早该已经提交过,这里另起一个全新 session
	// 重新计时,让新一轮播满阈值时也能被当成一条独立收听提交。不能走上面"换曲"分支的
	// recentFinalized 续接逻辑——那是给 null-glitch 假死恢复用的,key 没变的话会被
	// 误判成同一次收听的假死恢复,反而抵消掉这里想要的效果,所以显式清空、不复用。
	if loopRestart {
		p.finalize(now)
		p.recentFinalized = nil
		p.sess = &playSession{key: key, meta: p.cur, startedAt: now, lastPlaying: p.cur.Playing}
		if p.cur.Playing {
			p.sess.lastSeen = now
		}
		log.Printf("loop restart: %s - %s", p.cur.Artist, p.cur.Title)
		if len(trackEnrichment(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Duration)) > 0 {
			p.announce(now, "loop restart")
		} else {
			p.sess.pnPending = true
		}
		return
	}

	// Same track: on a play/pause transition, re-announce immediately so the
	// web progress bar re-anchors on resume or freezes on pause (rate=0),
	// instead of waiting up to one refresh interval.
	submitted := false
	// 挂起的首条:等 enrich 解析完(enrichNotify 会触发一轮 poll,那时才知有无歌词)或超过
	// pnPendingMax 再作为"换曲那条"发出。挂起期间不发状态切换/刷新提交(会锁死无歌词的换曲那条)。
	if p.sess.pnPending {
		resolved := len(trackEnrichment(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Duration)) > 0
		if resolved || now.Sub(p.sess.startedAt) >= pnPendingMax {
			p.announce(now, "first") // pnPending 在结果异步返回后由 applyAnnounceOutcome 清除
		}
		submitted = true
	}
	// 计时/播放态始终维护(即便挂起中):否则挂起窗口内的暂停不会清零 lastSeen,恢复时会把
	// 暂停时长误计入 playedSecs。只把"状态切换的 playing_now 提交"挡在挂起之后。
	if p.cur.Playing != p.sess.lastPlaying {
		p.sess.lastPlaying = p.cur.Playing
		if p.cur.Playing {
			p.sess.lastSeen = now
		} else {
			p.sess.lastSeen = time.Time{} // stop accruing while paused
		}
		if !p.sess.pnPending {
			p.announce(now, "state change")
			submitted = true
		}
	}

	if !p.cur.Playing {
		return
	}

	if !p.sess.lastSeen.IsZero() {
		if d := now.Sub(p.sess.lastSeen).Seconds(); d > 0 && d <= maxAccrualGapSecs {
			p.sess.playedSecs += d
		}
	}
	p.sess.lastSeen = now
	// Publish a fresh anchor on a re-anchor (seek / sleep-wake) or on the
	// periodic refresh, so the web always extrapolates from a recent point.
	if !submitted && (reanchored || now.Sub(p.sess.lastPN) >= playingNowRefresh) {
		p.announce(now, "refresh")
	}
	if !p.sess.listenSent && !p.sess.submitting && p.sess.playedSecs >= listenThreshold(p.sess.meta.Duration) &&
		(p.sess.meta.Duration <= 0 || p.sess.meta.Duration >= minTrackSecs) {
		p.sess.submitting = true
		p.submitSingleAsync(p.sess, p.sess.meta, p.sess.startedAt.Unix())
	}
}

// bridge kicks off a background fetch of Last.fm (iPhone via FastScrobbler→
// Last.fm) gently every lastfmPollInterval — 见 bridgeDoneCh 顶部注释,
// lastfmRecent 本身(8s 超时)挪到 goroutine 跑,不阻塞 poll() 后面紧跟的
// pushRelayState。实际的转发/镜像逻辑(有状态副作用)在 applyBridgeResult 里、
// 结果送回主循环后才跑。
//
// 2026-07-29:不再看一个独立的 features.LastfmBridge 开关——Last.fm 桥接凭据 +
// ListenBrainz 账号都配好,就默认跑;这两项本来就是 Swift 侧 UI 上打开那个开关的
// 前置条件(config.lastfmBridgeMissingHint()==nil 且 isListenBrainzConfigured 都
// 满足才让点),独立开关只是多一次点击,没有实际区分度。
func (p *poller) bridge(now time.Time) {
	if p.cfg.LastfmUser == "" || p.cfg.lastfmBridgeAPIKey() == "" || p.cfg.User == "" || p.cfg.Token == "" {
		return
	}
	if p.bridgeFetching || now.Sub(p.lastfmCheckedAt) < lastfmPollInterval {
		return
	}
	p.lastfmCheckedAt = now
	p.bridgeFetching = true
	user, apiKey := p.cfg.LastfmUser, p.cfg.lastfmBridgeAPIKey()
	go func() {
		np, done, ok := lastfmRecent(p.ctx, user, apiKey)
		select {
		case p.bridgeDoneCh <- bridgeFetchResult{now: now, np: np, done: done, ok: ok}:
		case <-p.ctx.Done():
		}
	}()
}

// applyBridgeResult 在 poll 主循环里处理 bridge() 后台拉取的 Last.fm 结果——转发/
// 镜像 iPhone 状态等有状态副作用的逻辑,原样保留在这里同步跑(不引入并发读写)。
// (1) forward completed scrobbles into LB as listens so "last played"/history
// are cross-device; (2) when the Mac isn't playing locally, mirror the
// phone's now-playing. Mac local playback wins the live view (it has the
// progress bar); iPhone plays carry no progress.
func (p *poller) applyBridgeResult(r bridgeFetchResult) {
	p.bridgeFetching = false
	if !r.ok {
		return
	}
	// 异步化之后,这次处理结果不再必然发生在 poll() 里紧跟 pushRelayState 那次调用之内
	// (可能在两次 poll tick 之间才到达),所以这里补一次推送——沿用
	// applySubmitOutcome/applyAnnounceOutcome 同款"处理完就主动推一次、内部去重兜底"
	// 的模式。用 defer 而不是在每个 return 分支前手动加一遍,保证不管走哪条分支
	// (Mac 抢占/iPhone 停播/判定为自己的回声/正常记录 iPhone 在播)都会触发。
	defer p.pushRelayState(time.Now(), false)
	now, np, done := r.now, r.np, r.done

	// 把 Last.fm 上"没转发过"的完成收听转成 LB listen(集合去重,天然兼容乱序/迟到:
	// Marvis 后台漏了、之后补同步的旧时间戳记录,只要不在集合里就会被补上)。首次(无持久化
	// 文件)只 seed 当前窗口、不回灌整段历史。
	fwdChanged := false
	if !p.fwdSeeded {
		for _, s := range done {
			if s.UTS > 0 {
				p.forwarded[s.UTS] = true
			}
		}
		p.fwdSeeded, fwdChanged = true, true
	} else {
		for i := len(done) - 1; i >= 0; i-- { // oldest → newest
			s := done[i]
			if s.UTS <= 0 || p.forwarded[s.UTS] {
				continue // 已转发过(不看时间顺序)→ 跳,天然容忍乱序/迟到
			}
			if p.lfmMirrored[s.UTS] {
				// 这是我们自己镜像写进 Last.fm 的 Mac 完成收听,不是真实 iPhone 收听——
				// LB 已经从 Mac 路径收到过一次了,不能再当"iPhone 新记录"转发一次
				// (否则会重复计入 + 设备归属被错误标成 iphone)。标记已处理,不再重复判断。
				p.forwarded[s.UTS], fwdChanged = true, true
				continue
			}
			if p.recentlyPlayedOnMac(s.Artist, s.Title, s.UTS) {
				// 上面的精确 uts 匹配抓不到、但名字够像+时间够近——见
				// recordRecentMacListen 注释:大概率是 FastScrobbler 经跨设备"最近
				// 播放"同步、真的在 Last.fm 上又单独 scrobble 了一次 Mac 已经放过的
				// 同一首歌(标题常带 remaster 后缀导致 uts/标题都跟我方镜像值对不上)。
				p.forwarded[s.UTS], fwdChanged = true, true
				continue
			}
			m := lbMeta(snapshot{Title: s.Title, Artist: s.Artist, Album: s.Album})
			m.AdditionalInfo["source"] = "iphone"                     // 来源:iPhone(经 Last.fm 桥接)
			m.AdditionalInfo["media_player"] = mediaPlayerLabelIPhone // 这条桥接固定是 iPhone 上的 Apple Music,不受本地 Mac 播放器选择影响
			// 这条特意保留同步:失败要 break(停在这个点,下次从同一条重试)、成功要继续
			// 处理 done 里剩下的旧记录——这个"按顺序处理、失败即停"的语义依赖同步调用,
			// 改成 submitSingleAsync 那种即发即走会打乱这个顺序保证。且这里处理的是
			// iPhone 那边已经完成的历史收听(不是当下的实时展示),没有 announce()/
			// 内联 single 提交那样"卡住会冻结网页展示"的紧迫性(bridge 本身也只有每
			// lastfmPollInterval=15s 才跑一次,不是每 5s 的 poll 主循环),所以这条暂不
			// 纳入本轮"poll() 提交异步化"的范围。
			if err := p.lb.submit(p.ctx, "single", s.UTS, m); err != nil {
				if errors.Is(err, errListenRejected) {
					// 永久性 4xx:LB 不会收这条,记入集合避免反复重试。
					log.Printf("bridge: skip rejected lastfm listen %q - %q: %v", s.Artist, s.Title, err)
					p.forwarded[s.UTS], fwdChanged = true, true
					continue
				}
				// 瞬时失败(LB 挂/超时):停在此下轮重试,不记入集合(否则会漏)。
				log.Printf("bridge: forward lastfm listen failed, will retry: %v", err)
				break
			}
			log.Printf("bridge: listen from iPhone/Last.fm: %s - %s", s.Artist, s.Title)
			p.pushScrobble(snapshot{Title: s.Title, Artist: s.Artist, Album: s.Album}, s.UTS, "iphone")
			p.forwarded[s.UTS], fwdChanged = true, true
		}
	}
	// 修剪:只保留最近 forwardedTTL 的 uts,防集合无限增长。
	if p.forwardedSet.trim(p.forwarded, now) {
		fwdChanged = true
	}
	if fwdChanged {
		p.forwardedSet.save(p.forwarded)
	}
	// 修剪 lfmMirrored:同上,只保留最近 lfmMirroredTTL 的 uts,防集合无限增长
	// (未启用镜像/lfm==nil 时该集合恒为空,这段是空操作)。
	if p.lfmMirroredSet.trim(p.lfmMirrored, now) {
		p.lfmMirroredSet.save(p.lfmMirrored)
	}

	// Mirror the phone's now-playing only while the Mac is idle.
	macActive := p.cur.Playing && p.isTracked()
	if macActive {
		p.remoteKey = ""         // Mac owns the live view; re-announce iPhone track when it returns
		p.remoteAt = time.Time{} // 让中继显示优先 Mac
		return
	}
	if np == nil {
		p.remoteAt = time.Time{} // iPhone 也停了 → 中继转"上次播放"
		return
	}
	if p.lfm != nil && looseContains(np.Artist, p.cur.Artist) && looseContains(np.Title, p.cur.Title) && p.cur.Title != "" {
		// Last.fm 上的"正在播放"跟本地 Mac 当前/最近曲目同名——很可能是我们自己刚
		// 镜像写入、Mac 已暂停但 Last.fm 侧还没自然过期的残留状态,不是真实 iPhone
		// 在放同一首歌。宁可漏判(小概率两台设备真放同一首)也不能误判成 iPhone。
		return
	}
	// 记录 iPhone 当前在播,供中继 /push 显示(Mac 空闲时)。
	p.remoteTrack, p.remoteAt = snapshot{Title: np.Title, Artist: np.Artist, Album: np.Album, Playing: true}, now
	key := np.Title + "|" + np.Artist
	if key == p.remoteKey && now.Sub(p.remotePN) < playingNowRefresh {
		return // already announced; refresh only every playingNowRefresh
	}
	p.remoteKey, p.remotePN = key, now
	meta := lbMeta(snapshot{Title: np.Title, Artist: np.Artist, Album: np.Album, Playing: true})
	meta.AdditionalInfo["source"] = "iphone"                     // 来源:iPhone(经 Last.fm 桥接)
	meta.AdditionalInfo["media_player"] = mediaPlayerLabelIPhone // 这条桥接固定是 iPhone 上的 Apple Music,不受本地 Mac 播放器选择影响
	artist, title := np.Artist, np.Title
	// 异步提交,不阻塞 bridge()/poll() 主循环(理由同 submitSingleAsync)——这条提交没有
	// 任何后续状态要维护(不像 Mac 侧的 lastPN/pnPending),失败只需要记日志,fire-and-forget
	// 即可,不需要像 single 提交那样经 channel 回主循环。
	go func() {
		if err := p.lb.submit(p.ctx, "playing_now", 0, meta); err != nil {
			log.Printf("bridge: submit lastfm playing_now failed: %v", err)
		} else {
			log.Printf("bridge: now playing (iPhone via Last.fm): %s - %s", artist, title)
		}
	}()
}

// poll polls ground truth via `media-control get`. The stream subscription
// proved unreliable for play/pause/seek notifications on this macOS beta (it
// keeps reporting the pre-pause state), so a straight poll is the robust
// source. `media-control get` also intermittently returns "null" while a
// track is playing; treat a lone null as a glitch (keep the last state), and
// only declare playback stopped after a few consecutive nulls.
func (p *poller) poll() {
	if state, ok := getState(p.ctx); ok {
		if len(state) == 0 { // "null" — nothing playing, or a transient read glitch
			p.nullStreak++
			if p.nullStreak >= 3 {
				p.cur = snapshot{}
			}
		} else {
			p.nullStreak = 0
			p.cur = extract(state)
		}
	}
	now := time.Now()
	reanchored, loopRestart := p.updatePosition(now)
	// Mac 本地放 Apple Music 时,用 AppleScript 的权威播放头覆盖推算位置(精确到 ~0.1s,
	// 消除 media-control 推算的 ~1-2s 偏差,让网页进度条/逐字歌词严格对齐)。拿不到就沿用
	// updatePosition 的结果。
	// 锚点时间必须在 osascript 真正返回之后重新取——它要 fork 一个进程走 AppleEvents,
	// 实测能有几百 ms 到 ~1s 的延迟;如果沿用调用前的 now,相当于把"稍晚采到的位置"报成
	// "更早时刻就已经在那",网页据此外推会一直快出这段延迟(实锤:网页比实际快1秒左右)。
	// appleMusicPosition 只对 Apple Music 有意义(它是专门再问一次 Music.app 要更精确
	// 播放头的第二次调用)——QQ 音乐没有这条路径,getQQMusicState 用的 elapsedTimeNow
	// 已经是每一轮都新鲜的读数,不需要、也不应该再叠加这一步(不加这个判断的话,即使
	// 选的是 QQ 音乐,这里仍会照样问一次 Music.app,如果它碰巧也开着在放别的东西,会
	// 用 Music.app 的位置错误覆盖掉 QQ 音乐这边正确算出来的位置)。playerAuto("自动
	// 识别")下额外允许"这一轮观测到的 bundle 恰好是 Apple Music"这个条件——故意不是
	// 简单把整个判断换成只看 p.cur.Bundle:那样会让"手动选了 QQ 音乐/网易云音乐/
	// Spotify,但 p.cur.Bundle 因为某种原因还留着上一轮的 Apple Music 值"这种边界情况
	// 重新引入上面这段注释描述的坑,所以手动选择的三个非 Apple Music 播放器行为完全
	// 不变,只有 playerAuto 这一种情况需要额外看 p.cur.Bundle。
	if (features.Player == playerAppleMusic || (features.Player == playerAuto && p.cur.Bundle == "com.apple.Music")) &&
		p.cur.Playing && p.isTracked() {
		if pos, ok := appleMusicPosition(p.ctx); ok {
			p.cur.Position, p.cur.AnchorTS = pos, time.Now()
		}
	}
	p.handle(now, reanchored, loopRestart)
	p.bridge(now)
	p.pushRelayState(now, reanchored)
	p.weeklyDigest(now)
	p.dailyDigest(now)
	p.topArtistsDigest(now)
}

func run(ctx context.Context, cfg *config, lb *lbClient) error {
	forwardedSet := persistedTTLSet{path: forwardedPath, ttl: forwardedTTL}
	lfmMirroredSet := persistedTTLSet{path: lfmMirroredPath, ttl: lfmMirroredTTL}
	forwarded, fwdSeeded := forwardedSet.load() // 已转发 uts 集合 + 是否已初始化(替代单调水位线,兼容迟到/乱序)
	lfmMirrored, _ := lfmMirroredSet.load()
	p := &poller{
		ctx: ctx,
		cfg: cfg,
		lb:  lb,
		// Last.fm 镜像写入(可选,三个凭证字段都配置且 lastfm_mirror_scrobble 开关打开才
		// 启用)。这里是唯一的构造点,p.lfm==nil 天然让 mirrorScrobbleTracked/mirrorAsync
		// 两处调用(now-playing 镜像 + scrobble 镜像)都跳过,不需要在两处各自判断开关。
		lfm:             lastfmScrobblerIfEnabled(cfg),
		lfmMirrored:     lfmMirrored,
		forwardedSet:    forwardedSet,
		lfmMirroredSet:  lfmMirroredSet,
		forwarded:       forwarded,
		fwdSeeded:       fwdSeeded,
		weeklyState:     weeklyDigestState{path: weeklyDigestPath},
		dailyState:      dailyDigestState{path: dailyDigestPath},
		topArtistsState: topArtistsState{path: topArtistsStatePath},
		submitDoneCh:    make(chan submitOutcome, 8),
		announceDoneCh:  make(chan announceOutcome, 8),
		bridgeDoneCh:    make(chan bridgeFetchResult, 1),
	}
	enrichNotify = make(chan struct{}, 1) // 后台 enrich 完成后触发一次重推
	p.poll()                              // render immediately, don't wait a full interval on startup
	go startCompanionLaunchWatcher(ctx)   // 独立节奏,见 companionlaunch.go 顶部注释

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			// Best-effort final flush with a fresh context.
			flushCtx, cancel := context.WithTimeout(context.Background(), submitTimeout)
			defer cancel()
			if p.sess != nil && !p.sess.listenSent && p.sess.playedSecs >= listenThreshold(p.sess.meta.Duration) &&
				(p.sess.meta.Duration <= 0 || p.sess.meta.Duration >= minTrackSecs) {
				if err := lb.submit(flushCtx, "single", p.sess.startedAt.Unix(), lbMeta(p.sess.meta)); err != nil {
					log.Printf("final listen flush failed: %v", err)
				} else {
					p.mirrorScrobbleTracked(p.sess.meta.Artist, p.sess.meta.Title, p.sess.meta.Album, p.sess.startedAt.Unix())
					p.recordRecentMacListen(p.sess.meta.Artist, p.sess.meta.Title, p.sess.startedAt.Unix())
				}
				// relay 现在是网页历史主源:退出前放的最后一首也要补进 relay。
				p.pushScrobble(p.sess.meta, p.sess.startedAt.Unix(), "mac")
			}
			return nil
		case <-enrichNotify:
			p.poll() // 后台 enrichment 完成,立刻带完整封面/歌词重推一轮
		case <-ticker.C:
			p.poll()
		case r := <-p.submitDoneCh:
			p.applySubmitOutcome(r)
		case r := <-p.announceDoneCh:
			p.applyAnnounceOutcome(r)
		case r := <-p.bridgeDoneCh:
			p.applyBridgeResult(r)
		}
	}
}
