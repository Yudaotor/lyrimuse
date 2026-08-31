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
	// 会话级广告标记(2026-08-19):开播时判一次(字段启发式 + Spotify AppleScript 权威,
	// 见 detectAdAtSessionStart),同曲期间字段任一拍判中就往 true 棘轮、绝不回落。
	// 动机:实测广告字段会**闪变**(开播 album 空、几拍后补齐,Blinds.com 实锤漏成
	// Last.fm nowplaying),announce 的门若按"当下字段"逐拍重判,任何一拍看走眼就漏。
	isAd bool
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
	// Spotify gapless 自然切歌锚点超前校正(2026-08-20,与 App 侧 LocalPlaybackSource
	// 同批改——两侧位置逻辑必须一致,只改一边就是"采集器和悬浮窗各说各话"的老坑)。
	// 实测:自然切歌时 Spotify 在旧曲真声还剩 ~0.84s 时就打好新曲锚点,此后整首歌
	// elapsedTimeNow 恒定超前真声(+0.888s±0.009,锚点从不重打)——稳定播放期间我们
	// 只按墙钟累加、从不回看读数,所以播种时刻的超前量整首锁死。修法:换歌那一拍用
	// "旧曲自己的连续外推越过时长的量"(overrun)当真值播种(允许为负=旧曲真声未完,
	// 发布口钳到 0),量出偏置 posBias;之后凡直接采信 media-control 读数的分支(暂停
	// 冻结值)都扣掉它;真实 seek 会让 Spotify 重打对齐真声的新锚点,偏置清零。
	posBias      float64 // 当前曲目锚点超前量(秒),仅 Spotify 自然切歌时非零
	prevDuration float64 // 上一轮快照的曲目时长(自然切歌判定用"旧曲"时长)
	prevPlaying  bool    // 上一轮快照是否在播(gapless 判定要求旧曲正在播)
	prevBundle   string  // 上一轮快照的播放器 bundle(旧曲真值必须同样来自 Spotify)
	// 上一轮是否触发了 loopRestart(单曲循环归位)——回绕分两拍被观察到时,第二拍的
	// 偏置重估要以"已归位的新一遍位置"为真值基准,见 updatePosition 里回绕形态 (a)。
	prevLoopRestart bool
	// 本轮 p.cur 是否是上一轮的陈旧残留(getState 读取失败/瞬时 null 未达清空门槛)。
	// poll() 每轮设置;updatePosition 靠它拒绝让陈旧 Elapsed 走 seek 分支。
	snapshotStale bool

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
// bridgeMaxListenAge:bridge 只转发**足够新**的 Last.fm 记录,更老的一律跳过。
//
// 修一个既有缺陷 + 为回填铺路,一举两得:
//
//  1. **既有缺陷**:forwarded 集合是 7 天 TTL(dedup.go 的 forwardedTTL),而 bridge 读的是
//     `user.getrecenttracks limit=50` —— 一个听歌频繁的用户,最近 50 条只覆盖一两天,
//     远小于 7 天,所以"被 trim 掉的条目还留在窗口里"不会发生。但一个**听歌很少**的用户
//     (一周十几首),最近 50 条能横跨好几周:超过 7 天的条目被 trim → 集合里查不到 →
//     bridge 又转发一次 → 记入集合 → 7 天后再被裁……周期性地把同一条重复灌进 ListenBrainz。
//     整个链条只靠"窗口跨度 < TTL"这条**隐式**不变量撑着,而那取决于用户听歌多勤。
//  2. **回填**:回填会往 Last.fm 写带过去时间戳的 scrobble。那些条目如果落进 bridge 的
//     可见窗口,会被当成"真实 iPhone 收听"再转发进 LB(设备归属还会被错标成 iphone)。
//
// 3 天这个值:比观察到的最长回声延迟(FastScrobbler 跨设备同步可到跨夜,见
// recentMacListenRetention 那段)宽出一倍多,又明显小于 forwardedTTL 的 7 天 —— 必须小于,
// 否则被 trim 的条目仍能过闸,缺陷 1 就没修掉。
//
// 这道闸**无状态**:不读任何集合、不受 trim 影响,所以永久有效,不像 TTL 那样会过期。
const bridgeMaxListenAge = 3 * 24 * time.Hour

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
		return isAcceptedPlayerBundleID(p.cur.Bundle)
	}
	return p.cur.Bundle == expectedPlayerBundleID()
}

// mirrorScrobbleTracked 先同步记入"已镜像"集合并落盘,再异步镜像写入 Last.fm——见
// lfmMirroredTTL 处注释:写入必须先于发起请求完成,防 bridge 抢在标记前误转发。
//
// 幂等:同一个 timestamp 只提交一次。2026-08-11 起 Last.fm 镜像与 ListenBrainz 的
// 提交结果解耦(见 applySubmitOutcome),LB 失败重试成功后会再次走到调用点 —— 没有
// 这个守卫就会对 Last.fm 重复提交同一次收听。
// rawArtist/durationSecs 只在失败留痕时用(见 recordFailedMirror):写进本地收听日志的
// 必须是**播放器报的原始艺人名** —— 2026-08-31 起上送本身也是原样发原始标签,
// 见 listenLogLine.AR 的注释,回填会拿它重新跑一遍同样的归一化,喂折叠后的值进去等于
// 折叠两次。
func (p *poller) mirrorScrobbleTracked(artist, title, album string, timestamp int64, rawArtist string, durationSecs float64) {
	if p.lfm == nil || timestamp <= 0 {
		return
	}
	if p.lfmMirrored[timestamp] {
		return
	}
	p.lfmMirrored[timestamp] = true
	p.lfmMirroredSet.save(p.lfmMirrored)
	mirrorAsync(p.lfm, "scrobble", func(ctx context.Context) error {
		return p.lfm.scrobble(ctx, artist, title, album, timestamp, durationSecs)
	}, func(err error) {
		recordFailedMirror(err, rawArtist, title, album, timestamp, durationSecs)
	})
}

// recordFailedMirror 给一次**没写进 Last.fm** 的收听留痕,让它还有被救回来的机会。
//
// 为什么不是"撤销 lfmMirrored 标记、下一拍重发"(2026-08-30 评估后否掉的方案):
//   - 那要从 mirrorAsync 的 goroutine 里写 p.lfmMirrored,而主循环会经
//     persistedTTLSet.save 整个 range 它 —— 并发写 = 不可 recover 的 fatal error。
//   - 收益也几乎没有:实测 10 次 DNS 故障里只有 1 次在同一首歌还没放完时等到网络恢复,
//     其余 9 次 session 早被 finalize 丢弃,标记撤了也没人再提交。
//
// 所以标记**保持置位**(活路径永不再发这条 ⇒ 物理上不可能双发),改为把这一条落进
// listens.jsonl,交给作者已经写好的回填(13 天窗口/批量/限速/隔离/UI 有计数)。
//
// 三类失败的处置完全不同,合并成一种就必然错一边:
//
//   - **可证明没发出去**(DNS/dial 失败):服务端不可能见过它,补提交零重复风险 ⇒ 只写
//     "l",回填会正常挑走。
//   - **服务端拒收内容本身**(accepted=0):这首歌换多少次也还是这首歌,重发必然同样被拒
//     ⇒ 什么都不写,只靠上面 mirrorAsync 那行日志把真实原因(现在带 ignoredMessage 了)
//     暴露出来,让人去改数据而不是让机器空转。
//   - **不确定发没发到**(超时/连接中断/服务端说自己暂时不可用):写 "l" + "q" 一对。
//     "q" 让回填**永远不会自动重试**它(见 markQuarantined 的注释:重复比漏补贵得多),
//     "l" 则保住艺人/曲名,将来要人工对账才有依据 —— 原来这种情况连曲目是什么都查不
//     出来。
//
// ⚠️ 应用层错误(lastfmAPIError)**不能**一律当成"拒收"。2026-08-30 首版就是这么写的,
// 当天复查抓出来:限流(29)和凭据失效(4/9/10/26)下服务端**确定没落库**,那恰恰是最该
// 留痕待补的情形,一律 return 等于把这个函数要修的洞换个门又开一个 —— 一次限流就让这
// 首歌在 Last.fm、listens.jsonl 两边同时没有。分档判据用 mayHaveStored(),口径跟
// runBackfill 头注释里已经定过的一致,不另立一套。
func recordFailedMirror(err error, rawArtist, title, album string, timestamp int64, durationSecs float64) {
	var ignored *lastfmIgnoredError
	if errors.As(err, &ignored) {
		return // 服务端看过内容并拒收,补提交没有意义
	}
	appendListen(rawArtist, title, album, timestamp, durationSecs)

	// 走到这里都要留痕,只剩"能不能自动补"这一个问题。
	var apiErr *lastfmAPIError
	if errors.As(err, &apiErr) {
		if apiErr.mayHaveStored() {
			markQuarantined(timestamp)
		}
		return // 其余应用层错误:服务端明确表过态、确定没落库,回填可以放心补
	}
	if !provablyNeverSent(err) {
		markQuarantined(timestamp)
	}
}

// mirrorScrobbleSync 是 mirrorScrobbleTracked 的**同步**变体,只给进程退出前的最后
// 一次 flush 用:mirrorAsync 起的 goroutine 活不过紧接着的进程退出(2026-08-11 审阅
// 确认的竞态 —— 标记已落盘、请求没发出去,这首歌对 Last.fm 永久丢失),退出路径必须
// 拿 flush 的 ctx 同步把请求发完。
func (p *poller) mirrorScrobbleSync(ctx context.Context, artist, title, album string, timestamp int64, rawArtist string, durationSecs float64) {
	if p.lfm == nil || timestamp <= 0 {
		return
	}
	if p.lfm.dead.Load() {
		// 同 mirrorAsync 的入口:不发请求,但这一条确定没写进去,该留痕 —— 退出路径尤其
		// 不能漏,进程正要结束,没有"下一拍"能补。
		recordFailedMirror(&lastfmAPIError{Code: 9, Message: "mirror disabled (credentials judged dead)", Method: "track.scrobble"},
			rawArtist, title, album, timestamp, durationSecs)
		return
	}
	if p.lfmMirrored[timestamp] {
		return
	}
	p.lfmMirrored[timestamp] = true
	p.lfmMirroredSet.save(p.lfmMirrored)
	if err := p.lfm.scrobble(ctx, artist, title, album, timestamp, durationSecs); err != nil {
		log.Printf("lastfm mirror scrobble (final flush) failed: %v", err)
		// 退出路径同样要留痕 —— 而且这里比活路径更需要:进程正在退出,没有"下一拍"
		// 可言。这条是同步调用,本来就在主 goroutine 上,不涉及上面那条并发约束。
		recordFailedMirror(err, rawArtist, title, album, timestamp, durationSecs)
	}
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

	// Spotify 自然切歌锚点校正的守卫(机制见 poller 结构体 posBias 一带的注释)。
	// 窗口要吞下 pollInterval(5s,采集器没有事件通知,发现换歌最晚滞后一整拍)+
	// 元数据提前量 ~1s + 余量;App 侧(2s 轮询+通知,延迟 ~0.3s)对应值是 4.0。
	naturalAdvanceWindowSecs = 6.5
	// 偏置可信区间:下限滤测量噪声;上限之外视为陈旧读数/模型失效,放弃校正退回原样
	// 采信(=改动前行为)。实测真实偏置 0.69~1.32s;上限同时把"手动跳歌恰好发生在结尾
	// 窗口内"这种误判的伤害钉死在 ≤2.5s(仅那一首、且是偏慢,比整首偏快的现状轻)。
	naturalAdvanceMaxBiasSecs = 2.5
	naturalAdvanceMinBiasSecs = 0.05
)

// naturalAdvanceCorrection 自然切歌锚点偏置估计,纯函数(与 App 侧
// LocalPlaybackSource.naturalAdvanceCorrection 同一套判据,常量除窗口外一致)。
// reported=新曲第一笔原始读数;overrun=换歌被观察到那一刻旧曲连续外推位置−旧曲时长
// (负=真声还没放完)。ok=false 表示窗口外/偏置不可信,按原逻辑采信读数。
func naturalAdvanceCorrection(reported, overrun float64) (seed, bias float64, ok bool) {
	if math.Abs(overrun) > naturalAdvanceWindowSecs {
		return 0, 0, false
	}
	bias = reported - overrun
	if bias <= naturalAdvanceMinBiasSecs || bias > naturalAdvanceMaxBiasSecs {
		return 0, 0, false
	}
	return overrun, bias, true
}

func (p *poller) updatePosition(now time.Time) (reanchor bool, loopRestart bool) {
	key := p.cur.key()
	if key == "" { // nothing playing
		p.trackKey, p.prevWall = "", time.Time{}
		p.posBias, p.prevDuration, p.prevPlaying, p.prevBundle = 0, 0, false, ""
		p.prevLoopRestart = false
		p.cur.Position, p.cur.AnchorTS = 0, now
		return false, false
	}
	sameTrackAsBefore := key == p.trackKey
	prevTrackPos := p.trackPos
	gap := now.Sub(p.prevWall).Seconds()
	reanchor = true
	// 切歌/加载瞬间会短暂报 rate=0(playing 仍 true),按 1 计(与 lb.go 的 reconcile
	// 规则、seedPosition 内部一致)。不归一的话 predicted 停走,下一拍正常前进的读数会
	// 被误判成 seek 跳变,顺手清掉自然切歌偏置(2026-08-20 对抗审查抓出)。
	rate := p.cur.Rate
	if p.cur.Playing && rate <= 0 {
		rate = 1
	}
	if p.cur.Bundle != spotifyBundleID && p.posBias != 0 {
		// 同 key 跨播放器接续(同一首歌换了源):偏置只对打歪的 Spotify 锚点有意义。
		p.posBias = 0
	}
	seedFromMC := func() float64 { return seedPosition(p.cur.Elapsed, p.cur.Rate, p.cur.Playing, p.cur.McTS, now) }
	// 单曲循环(repeat-one)的 gapless 回绕:key 不变、走不到换歌分支,但与跨曲自然切歌
	// 是同一机制(引擎驱动的自然过渡,新锚点先于真声打好)——不识别的话会落进 seek 分支
	// 把量准的偏置清掉,循环第 2 遍起整曲回到偏快(2026-08-20 对抗审查抓出)。签名=外推
	// 已过曲尾窗口且按"回绕真值=越界量"估出的偏置可信(稳定播放到曲尾时原始读数是大值,
	// 估出的偏置≈整曲时长,天然不命中)。命中后下方 loopRestart 连续性判定照常触发,
	// 收听计数不受影响。
	// 回绕有两种观察形态(5s 轮询下都常见):
	// (b) 同一拍观察到——上一拍外推还在结尾前,这一拍原始读数已回绕:真值=越界量,
	//     交给 naturalAdvanceCorrection(与跨曲自然切歌同一套守卫);
	// (a) 分两拍观察到——上一拍外推先越过时长、下方 loopRestart 启发式已把 trackPos
	//     归到新一遍(prevTrackPos 已是新一遍真值),这一拍原始读数才回绕:真值=
	//     prevTrackPos+gap,只需按偏置可信区间守卫,不再套 |越界|窗口(那是跨界拍的语义)。
	wrapSeed, wrapBias := 0.0, 0.0
	wrapOK := false
	if sameTrackAsBefore && !p.snapshotStale && p.cur.Playing && p.prevPlaying &&
		p.cur.Bundle == spotifyBundleID && p.prevBundle == spotifyBundleID && p.prevDuration > 0 {
		if p.prevLoopRestart { // (a)
			base := prevTrackPos + gap*rate
			if b := seedFromMC() - base; b > naturalAdvanceMinBiasSecs && b <= naturalAdvanceMaxBiasSecs {
				wrapSeed, wrapBias, wrapOK = base, b, true
			}
		} else { // (b)
			wrapSeed, wrapBias, wrapOK = naturalAdvanceCorrection(seedFromMC(), prevTrackPos+gap*rate-p.prevDuration)
		}
	}
	switch {
	case p.snapshotStale && sameTrackAsBefore:
		// 这一轮没拿到新快照(读取失败/瞬时 null),p.cur 还是上一轮的陈旧值——绝不能让
		// 陈旧的 Elapsed 走 seek 分支"重锚回过去"、顺手清掉自然切歌偏置(2026-08-20
		// 对抗审查抓出)。播放中按墙钟推进、暂停维持冻结,等下一轮新鲜快照。
		if p.cur.Playing {
			p.trackPos += gap * rate
			// Elapsed 也同步外推:函数末尾会把它记进 prevElapse@prevWall=now 这对
			// 基准里,不外推的话这对基准彼此错位一拍,下一轮新鲜读数会被 seek 判据
			// 误判成跳变(又把偏置清了)。外推值 = media-control 若读取成功本会给的
			// elapsedTimeNow,语义一致;真在陈旧窗口里发生的 seek/暂停,下一轮新鲜
			// 读数照常从各自分支兜住。
			p.cur.Elapsed += gap * rate
		}
		reanchor = false
	case key != p.trackKey: // new track / 重启首见 → 用 media-control 锚点补齐真实位置
		// Spotify gapless 自然切歌(旧曲在播且已连续外推到结尾附近):锚点先于真声,
		// 按旧曲连续性播种并量出整曲偏置——机制/守卫见 posBias 与 naturalAdvanceCorrection。
		// 旧曲真值必须同样来自 Spotify 的连续外推(prevBundle 门):auto 模式跨播放器
		// 切歌时,拿 QQ/网易云整秒地板或 Apple Music 播放头的外推当旧曲真值是错的。
		p.posBias = 0
		p.trackPos = seedFromMC()
		if p.cur.Bundle == spotifyBundleID && p.prevBundle == spotifyBundleID &&
			p.cur.Playing && p.prevPlaying && p.prevDuration > 0 && !p.prevWall.IsZero() {
			overrun := prevTrackPos + gap*rate - p.prevDuration
			if seed, bias, ok := naturalAdvanceCorrection(p.trackPos, overrun); ok {
				log.Printf("natural advance: seed %.3fs, anchor leads audio by %.3fs (raw %.3f)", seed, bias, p.trackPos)
				p.trackPos, p.posBias = seed, bias
			}
		}
	case !p.cur.Playing: // paused → media-control's frozen elapsed is the true position
		// (扣掉自然切歌偏置:冻结值带着同一个超前锚点的值)
		// 暂停中用户在播放器里拖了进度条:冻结值跳变 = Spotify 已重打对齐真声的锚点,
		// 旧偏置作废——不清的话恢复播放后整曲反向偏慢一个旧偏置(2026-08-20 对抗审查抓出)。
		if !p.prevPlaying && p.posBias != 0 &&
			math.Abs(p.cur.Elapsed-p.prevElapse) > seekJumpToleranceSecs {
			p.posBias = 0
		}
		p.trackPos = p.cur.Elapsed - p.posBias
		// 暂停后位置冻结不变,不该每轮都当"重新锚定"处理——那会让 pushRelayState
		// 的"变化才写"节流失效,暂停多久就以 pollInterval 频率写多久 KV(实测烧穿
		// 1000写/天配额)。暂停这个事件本身已经通过 key 从 mac|X 变成 macpause|X
		// 触发过一次写入,不需要这里再帮它每轮强制重写。
		reanchor = false
	case !p.prevPlaying: // 暂停→恢复(同曲):偏置继承,冻结值扣偏置就是恢复点
		// 不能落进下面的 seek 分支——那会把仍然有效的偏置清掉、位置前跳一个偏置量,
		// 且与 App 侧"暂停⇄恢复继承偏置"的语义相反(2026-08-20 对抗审查抓出,high)。
		// 恢复时 Spotify 重打的锚点值来自仍超前的内部计数器,偏置继续成立。
		p.trackPos = p.cur.Elapsed - p.posBias
	case wrapOK: // repeat-one gapless 回绕(见上方 wrapOK 注释)
		log.Printf("repeat-one wrap: seed %.3fs, anchor leads audio by %.3fs", wrapSeed, wrapBias)
		p.trackPos, p.posBias = wrapSeed, wrapBias
	case math.Abs(p.cur.Elapsed-(p.prevElapse+gap*rate)) > seekJumpToleranceSecs: // seek: actual position diverges from what steady playback alone would predict → re-anchor to it (补 McTS→now);原始值对原始值,自然切歌偏置在差里天然消掉
		// 真实 seek 会让 Spotify 重打与真声对齐的新锚点——偏置作废,改信原始读数。
		p.posBias = 0
		p.trackPos = seedFromMC()
	case p.prevWall.IsZero(): // first observation → best guess from media-control's own anchor
		p.posBias = 0
		p.trackPos = seedFromMC()
	case gap > 3*pollInterval.Seconds(): // big gap (sleep/App Nap) → trust frozen elapsed, don't count the gap
		p.posBias = 0
		p.trackPos = p.cur.Elapsed
	default: // steady play → advance by real elapsed wall time
		p.trackPos += gap * rate
		reanchor = false
	}
	// 单曲循环重新起播判定,见上面常量注释——用 prevTrackPos/p.trackPos 的连续性判断,
	// 不看是哪个分支算出来的。命中时从余数重新起播(而不是硬归零),减少跨越边界这一轮的
	// 外推误差;并强制 reanchor=true,让这次重置立刻推一次 relay,网页进度条不用等到
	// 下次心跳才刷新。
	if sameTrackAsBefore && !p.snapshotStale && p.cur.Playing && p.cur.Duration > 0 &&
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
	p.trackKey, p.prevElapse, p.prevWall = key, p.cur.Elapsed, now
	p.prevDuration, p.prevPlaying, p.prevBundle = p.cur.Duration, p.cur.Playing, p.cur.Bundle
	p.prevLoopRestart = loopRestart
	// 负位置只对内部连续性有意义(自然切歌播种时=旧曲真声还没放完,或暂停冻结值扣完
	// 偏置后略负),对外发布钳到 0。
	// ⚠️ 内部 p.trackPos 不再钳 0:钳了的话播种的负值立刻丢失,稳定播放分支从 0 起
	// 累加,整首歌就会超前 |播种值|,校正白做。
	pub := p.trackPos
	pubAt := now
	if pub < 0 {
		// 发布"位置 0 @ 未来 |trackPos| 秒"而不是"位置 0 @ 现在":网页外推是
		// pos = progress + age×rate 且 age>0 才加(web frame()/ProgressClock 同一套
		// 钳位),未来锚点让进度自然停在曲首等真声;锚在"现在"的话,relay 写入按变化
		// 去重、最长 4 分钟不重写,网页会整段超前 |播种值|(2026-08-20 对抗审查抓出)。
		pubAt = now.Add(time.Duration(-pub * float64(time.Second)))
		pub = 0
	}
	p.cur.Position, p.cur.AnchorTS = pub, pubAt
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
	// 广告不算"Mac 上有曲目"。
	//
	// 这条推送路径跟上送(submitSingleAsync)和 now-playing(announce)完全独立 —— 它只看
	// p.cur 是什么就往中继推什么,所以前两处挡住之后,网页顶部那张卡照样会显示
	// "他正在播放 We're Here / Instacart"(0:14、暂无同步歌词)。2026-08-14 用户实测反馈。
	//
	// 判成 false 之后会顺着下面的 switch 落到 iPhone 正在放 / 上次播放,也就是广告这几十秒
	// 网页停在上一首,跟"没在放"时的表现一致 —— 不会出现一张假的当前曲目卡。判据见 isAdBreak。
	macHasTrack := p.isTracked() && !isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) &&
		!(p.sess != nil && p.sess.isAd)
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
	sess *playSession
	meta snapshot
	// artistName 是 lbMeta(meta).ArtistName,顺带给 Last.fm 镜像复用(见
	// applySubmitOutcome),两条路取同一份、不各算一遍。
	// 2026-08-31 起 lbMeta 不再做任何替换,所以它就等于**播放器报的原始标签**;
	// 保留这个字段是为了两条路径永远同源,而不是因为它还需要被加工。
	artistName string
	startedAt  int64
	err        error
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
	// 广告不算一次收听。挡在这个漏斗上而不是各个调用点:曲终 finalize 和播放中达阈值两条
	// 闸门都汇到这里,而 applySubmitOutcome 里的 Last.fm 镜像、本地收听日志、网页中继全都
	// 挂在它的结果后面,挡住这里就一起挡住了。判据和误伤面见 isAdBreak。
	if sess.isAd || isAdBreak(meta.Bundle, meta.Artist, meta.Title, meta.Album) {
		log.Printf("skipping ad break: %q - %q", meta.Artist, meta.Title)
		sess.listenSent = true // 标记成已处理,免得每一轮 poll 都重新判一次
		return
	}
	lm := lbMeta(meta)
	go func() {
		err := p.lb.submit(p.ctx, "single", startedAt, lm)
		select {
		case p.submitDoneCh <- submitOutcome{sess: sess, meta: meta, artistName: lm.ArtistName, startedAt: startedAt, err: err}:
		case <-p.ctx.Done():
		}
	}()
}

// applySubmitOutcome 在 poll 主循环里处理 submitSingleAsync 的结果——不管此时 p.sess
// 是否还指向同一个 session(很可能早已因为换曲被 finalize 分离走了)，这里的字段变更和
// 收听记录都只作用于结果自带的 sess/meta，不依赖 p.sess 当前值，所以时序上没有问题。
func (p *poller) applySubmitOutcome(r submitOutcome) {
	r.sess.submitting = false
	// Last.fm 镜像与 ListenBrainz 的提交结果解耦(2026-08-11,批4):这次收听够不够格
	// 在发起提交前就已经判定过了,LB 服务抽风不该殃及 Last.fm 那份记录 —— 原来镜像躲
	// 在下面的成功分支里,LB 挂则两边一起停摆(审阅确认)。LB 失败重试成功后会再次走到
	// 这里,mirrorScrobbleTracked 的幂等守卫保证不重复提交。
	p.mirrorScrobbleTracked(r.artistName, r.meta.Title, r.meta.Album, r.startedAt, r.meta.Artist, r.meta.Duration)
	// 本地收听日志:**只在没有在往 Last.fm 提交时**才记(见 appendListen 的注释)。
	//
	// ⚠️ 这一段原来的注释写的是"**无条件**记一笔,不看任何账号配没配",而紧跟着的就是
	// 下面这个 `if p.lfm == nil` —— 2026-08-13 收窄之后旧结论留在了最显眼的位置,新结论
	// 被塞在末尾当补充。2026-08-30 通盘梳理时坐实这确实误导过判断(照字面读会以为镜像
	// 失败时本地还有一份兜底,实际没有,那正是那次数据丢失能瞒住这么久的原因之一)。
	//
	// 位置必须在下面那句 `if r.err != nil { return }` **之前**:LB token 填错或 LB 挂掉
	// 时这一条同样要落盘 —— 这个理由至今成立,收窄针对的是"连没连 Last.fm",不是"LB 成没
	// 成功"。跟紧上方 2026-08-11 把 Last.fm 镜像从 LB 成功分支里挪出来是同一个道理。
	if p.lfm == nil {
		appendListen(r.meta.Artist, r.meta.Title, r.meta.Album, r.startedAt, r.meta.Duration)
	}
	if r.err != nil {
		log.Printf("submit listen failed: %v", r.err)
		return
	}
	r.sess.listenSent = true
	log.Printf("listen recorded: %s - %s", r.meta.Artist, r.meta.Title)
	p.pushScrobble(r.meta, r.startedAt, "mac")
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
// detectAdAtSessionStart 开播时的广告判定:字段启发式(isAdBreak)先行;是 Spotify 且
// 字段没判中时,再向 Spotify 本尊要一次权威判据 —— AppleScript 的 `spotify url` 对广告
// 返回 "spotify:ad:…"(字段启发式打不完地鼠:广告可以带全 artist/title/album)。
// 每次换曲最多一次 osascript(~50ms),失败静默退回字段启发式,不劣于旧状。
func (p *poller) detectAdAtSessionStart() bool {
	if isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) {
		return true
	}
	if p.cur.Bundle == spotifyBundleID {
		return spotifyCurrentTrackIsAd(p.ctx)
	}
	return false
}

func (p *poller) announce(now time.Time, why string) {
	if p.sess.announcing {
		return
	}
	// 广告同样不宣布"正在播放"。playing_now 也是往 ListenBrainz / Last.fm 上送,而且它直接
	// 决定网页顶部那张卡显示什么 —— 一个公开页面上写着"正在播放 BLIZZARD® Double Flip Deal
	// BOGO for 99¢"是纯粹的噪声。挡掉之后广告这几十秒里网页停在上一首,跟"没在放"时的表现
	// 一致,不会出现假的当前曲目。判据见 isAdBreak。
	if p.sess.isAd || isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) {
		return
	}
	p.sess.announcing = true
	sess := p.sess
	m := lbMeta(p.cur)
	// artist 给 Last.fm 用:跟 m.ArtistName(给 LB 用)取同一份,保证 now-playing 与
	// 落库不会各说各话。
	//
	// ⚠️ 2026-08-31 起 lbMeta **不再做 canonical_artist 替换**,两者都等于播放器原始
	// 标签。原注释描述的是那次替换(为了解决"方大同/Khalil Fong 在 Last.fm 分裂"),
	// 现在那个问题改由**显示/统计层**归并解决,上送层只如实记录 —— 完整依据见 lb.go
	// 里 lbMeta 那段(Last.fm 官方反对自动套用纠正 / 业界无一默认这么做 / 实测有真错)。
	artist, title, album := m.ArtistName, p.cur.Title, p.cur.Album
	// 跟 artist/title/album 一样在**闭包外**取值:下面那个 goroutine 直接读 p.cur 就是
	// 跨 goroutine 读 poller 状态,违反"所有状态只在 poll 主循环里碰"那条不变量。
	durationSecs := p.cur.Duration
	playing := p.cur.Playing
	go func() {
		// now-playing 镜像与 LB 解耦(2026-08-11,批4):"正在播放"反映的是本机播放器
		// 的真实状态,不是 LB 提交的成败。放在 LB 请求之前发起 —— 两者本就各自异步。
		//
		// ⚠️ 只在**真的在放**时镜像给 Last.fm:track.updateNowPlaying 没有"暂停"这个
		// 概念,暂停时发过去等于宣布"我正在听这首"。announce 有三个调用点会在非播放态
		// 触发:进程启动时当前曲目本就暂停(走"换曲"分支开 session)、播放↔暂停的状态
		// 切换、挂起首条到点补发。2026-08-12 实测坐实危害:collector 一重启就把一首
		// 暂停的歌 announce 上去,直接顶掉了用户手机上正在放的那首的 nowplaying。
		// LB 不受影响 —— 它要靠 rate=0 表达暂停、自己会丢弃,所以下面的 submit 照旧发。
		if playing {
			mirrorAsync(p.lfm, "now-playing", func(ctx context.Context) error {
				return p.lfm.updateNowPlaying(ctx, artist, title, album, durationSecs)
			}, nil) // now-playing 失败无需留痕:它是瞬时状态,下一拍自然覆盖(跟 scrobble 相反)
		}
		err := p.lb.submit(p.ctx, "playing_now", 0, m)
		if err != nil {
			log.Printf("submit playing_now (%s) failed: %v", why, err)
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
			p.sess.isAd = p.detectAdAtSessionStart()
		}
		p.recentFinalized = nil
		log.Printf("now playing: %s - %s", p.cur.Artist, p.cur.Title)
		// 顺手把同一张专辑里其它还没解析过的曲目也丢到后台解析——用户按专辑顺序一首首听,
		// 提前解析好等真播到那首歌时大概率不用现等。见 albumprefetch.go。
		if features.AlbumPrefetch {
			prefetchAlbumSiblings(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle)
		}
		// LB 的 playing_now 只在"换曲"时更新、同曲存活期内拒绝覆盖,迟到的歌词再也进不去。
		// 故首条须在 enrich 解析完后再发(那时才知有无歌词、有则带上)。已解析(缓存命中,无论
		// 有无歌词)立即发;仅首次解析中(缓存未命中)才挂起,由下方处理器等 enrich 完成
		// (enrichNotify 触发)或超时再发。仅影响 KV 兜底路径,KV 主路径不受此延迟。
		if len(trackEnrichment(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle, p.cur.Duration, true)) > 0 {
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
		p.sess.isAd = p.detectAdAtSessionStart()
		log.Printf("loop restart: %s - %s", p.cur.Artist, p.cur.Title)
		if len(trackEnrichment(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle, p.cur.Duration, true)) > 0 {
			p.announce(now, "loop restart")
		} else {
			p.sess.pnPending = true
		}
		return
	}

	// 广告标记棘轮:同曲期间任一拍字段判中就永久置位(字段会闪变,见 playSession.isAd)。
	if !p.sess.isAd && isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) {
		p.sess.isAd = true
		log.Printf("ad break detected mid-session: %q - %q", p.cur.Artist, p.cur.Title)
	}

	// Same track: on a play/pause transition, re-announce immediately so the
	// web progress bar re-anchors on resume or freezes on pause (rate=0),
	// instead of waiting up to one refresh interval.
	submitted := false
	// 挂起的首条:等 enrich 解析完(enrichNotify 会触发一轮 poll,那时才知有无歌词)或超过
	// pnPendingMax 再作为"换曲那条"发出。挂起期间不发状态切换/刷新提交(会锁死无歌词的换曲那条)。
	if p.sess.pnPending {
		// isNewTrack 传 false:这是同一个 session 里等 enrich 完成的轮询重试,不是新曲目
		// 开始播放的那一刻,不该再问一次 media-control 要设备封面(那一刻已经在上面
		// "New track" 分支问过了)。
		resolved := len(trackEnrichment(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle, p.cur.Duration, false)) > 0
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
// ListenBrainz 账号都配好,就默认跑;独立开关只是多一次点击,没有实际区分度。
//
// ⚠️ 2026-08-13 更正:这段原来还断言"这两项本来就是 Swift 侧 UI 上打开那个开关的前置
// 条件(lastfmBridgeMissingHint()==nil 且 isListenBrainzConfigured 都满足才让点)"——
// 那句话是**错的**。下面这个门要求 cfg.User(ListenBrainz 用户名)非空,而 Swift 侧的
// isListenBrainzConfigured 只看 token,当时 UI 上用户名那栏还标着"选填"。于是只填
// token 的用户在设置页看到桥接是"活的",这里却直接 return,什么都不发生、也不报错。
// Swift 侧现已补上 isListenBrainzReadable(token+用户名)专门表示"能读统计",跟这个门
// 对齐;用户名输入框的提示也改成了"听歌报告需要"。改这里的条件时记得同步那一侧。
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
			// 年龄闸,见 bridgeMaxListenAge。放在所有集合判断**之前**:它无状态,
			// 不依赖 forwarded/lfmMirrored 是否还留着对应条目。
			if s.UTS > 0 && now.Unix()-s.UTS > int64(bridgeMaxListenAge/time.Second) {
				continue
			}
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
	// snapshotStale:这一轮 p.cur 是否还是上一轮的陈旧残留——getState 直接失败,或
	// 瞬时 null 未达 3 连清空门槛时,p.cur 原样保留,但它的 Elapsed 已经落后墙钟一整拍,
	// updatePosition 不能把它当新鲜读数用(会误判 seek、清掉自然切歌偏置,2026-08-20
	// 对抗审查抓出)。真空态(3 连 null 清空)是新信息,不算陈旧。
	p.snapshotStale = true
	if state, ok := getState(p.ctx); ok {
		if len(state) == 0 { // "null" — nothing playing, or a transient read glitch
			p.nullStreak++
			if p.nullStreak >= 3 {
				p.cur = snapshot{}
				p.snapshotStale = false
			}
		} else {
			p.nullStreak = 0
			p.cur = extract(state)
			p.snapshotStale = false
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
			correctedAt := time.Now()
			p.cur.Position, p.cur.AnchorTS = pos, correctedAt
			// 2026-08-04 实测排查坐实的一个真实 bug(不是这次网页/本地进度差的全部
			// 根因,但独立成立、值得修):光纠正 p.cur.Position/AnchorTS(这一轮推给
			// 网页的值)不够——下一轮 updatePosition() 的"稳定播放:按真实经过时间
			// 累加"分支(p.trackPos += gap*rate,见该函数)是从 p.trackPos 这个内部
			// 累加器续算的,这里的校准值从没回写过 p.trackPos/p.prevWall,所以这次
			// 校准只在"这一轮"昙花一现,下一轮立刻从纠正前那个可能已经悄悄漂移的旧
			// p.trackPos 继续累加,校准效果被吃掉——只有累积漂移凑巧超过 2 秒的 seek
			// 容差时才会被动纠正一次。回写这两个字段,让下一轮从这次校准过的真值+
			// 对应时刻开始累加,而不是从旧累加器续算。
			p.trackPos = pos
			p.prevWall = correctedAt
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
	go startEnrichCancelWatcher(ctx)      // 独立节奏,见 enrichcancel.go 顶部注释

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			// Best-effort final flush with a fresh context.
			flushCtx, cancel := context.WithTimeout(context.Background(), submitTimeout)
			defer cancel()
			// 这条退出兜底路径直接调 mirrorScrobbleSync/lb.submit,不经过 submitSingleAsync,
			// 所以广告判据要在这里再挡一次(见 isAdBreak)。
			if p.sess != nil && !p.sess.listenSent && p.sess.playedSecs >= listenThreshold(p.sess.meta.Duration) &&
				(p.sess.meta.Duration <= 0 || p.sess.meta.Duration >= minTrackSecs) &&
				!p.sess.isAd && !isAdBreak(p.sess.meta.Bundle, p.sess.meta.Artist, p.sess.meta.Title, p.sess.meta.Album) {
				// Last.fm 镜像:与 LB 解耦,且必须走同步变体 —— 异步 goroutine 活不过
				// 紧接着的 return(见 mirrorScrobbleSync 注释)。
				//
				// 艺人名跟 LB 提交取同一份(lm.ArtistName)。2026-08-31 起 lbMeta 不再做
				// canonical_artist 替换,所以 lm.ArtistName 就是**播放器原始标签** ——
				// 这里保持取同一份,是为了万一以后 lbMeta 又加了什么处理,两条路不会分叉。
				lm := lbMeta(p.sess.meta)
				p.mirrorScrobbleSync(flushCtx, lm.ArtistName, p.sess.meta.Title, p.sess.meta.Album, p.sess.startedAt.Unix(),
					p.sess.meta.Artist, p.sess.meta.Duration)
				// 同上:退出前这最后一首也是一次算数的收听,本地日志不能漏。放在 LB
				// 提交之前,理由跟 applySubmitOutcome 那处一致。
				if p.lfm == nil {
					appendListen(p.sess.meta.Artist, p.sess.meta.Title, p.sess.meta.Album,
						p.sess.startedAt.Unix(), p.sess.meta.Duration)
				}
				if err := lb.submit(flushCtx, "single", p.sess.startedAt.Unix(), lm); err != nil {
					log.Printf("final listen flush failed: %v", err)
				} else {
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
