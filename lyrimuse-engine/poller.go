package main

import (
	"context"
	"errors"
	"log"
	"log/slog"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
)

// playSession tracks accrued playtime of the current track for the
// half-or-4-minutes listen rule.
type playSession struct {
	key        string
	meta       snapshot
	startedAt  time.Time
	playedSecs float64
	// lastSeen / lastSeenPos / lastSeenHasPos:上一个计时起点(App 新读到、在播的那一拍)的时刻与位置,
	// 收听时长从这里往后算(见 accrueListening)。lastSeen 为零 = 没在计时(暂停、还没开播)。
	lastSeen       time.Time
	lastSeenPos    float64
	lastSeenHasPos bool
	// gapHeld:上一个计时起点之后 App 按住过状态(holding)。按住解除那一次写出的是 App 新读到的位置,
	// 这段空档可以按位置补,不受 maxAccrualGapSecs 限制。
	gapHeld    bool
	listenSent bool
	// listenFailures / listenRetryAt:这首的收听提交连着失败了几次、下一次最早什么时候再试(listenRetrySchedule)。
	// 只管歌还在放时的重试;会话结束之后的失败进待重发队列(lbretry.go)。
	listenFailures int
	listenRetryAt  time.Time
	// pnTriedAt:上一次往 LB 发 playing_now 的时刻,成败都算。周期刷新、挂起首条的重发都按它隔 playingNowRefresh:
	// LB 挂着时失败了就等下一次刷新,别改成每拍重发(一个 8 秒超时接一个,对着一个挂掉的服务每 10 秒打一次)。
	pnTriedAt time.Time
	// lastfmNPAt:上一次发 Last.fm now-playing 的时刻。LB 那条在播放 / 暂停切换、重新对时这些时候都会发,
	// Last.fm 那一路自己节流(见 announce 里的 lastfmDue),不跟着发。
	lastfmNPAt  time.Time
	lastPlaying bool // last observed play/pause state, to detect transitions
	pnPending   bool // 首条 playing_now 因歌词还在异步解析而挂起(LB 只认换曲那条,故首条必须带歌词)
	// submitting/announcing:见 submitSingleAsync/announce 顶部的设计说明——LB 提交
	// 挪到后台 goroutine 跑之后,这两个标记防止同一个 session 在上一次提交结果还没
	// 返回时(LB 慢时 single 类型最长可达约 24s)被下一轮 5s poll 重复触发一次提交。
	submitting bool
	announcing bool
	// 会话级广告标记:开播时判一次(App 的广告结论,见 detectAdAtSessionStart),
	// 同曲期间任一拍 App 判成广告就往 true 棘轮、绝不回落。
	// 动机:实测广告字段会**闪变**(开播 album 空、几拍后补齐,Blinds.com 坐实漏成
	// Last.fm nowplaying),announce 的门若按"当下字段"逐拍重判,任何一拍看走眼就漏。
	isAd bool
	// 会话级「不 scrobble 到 Last.fm」标记:开播时按 features().LastfmExcludedBundles
	// 算一次(lastfmExcluded,见 lastfmexclude.go 头注)。**只管 Last.fm**:recordLastfmListen 不挂起也不镜像、
	// 不记给它兜底的本地收听日志,announce 不发 track.updateNowPlaying;ListenBrainz / 网页中继照旧。
	// 同曲期间不重算 —— 改设置伴随引擎重启,新会话自然拿到新值。
	lastfmExcluded bool
	// lastfmPending / lastfmSettled(Last.fm scrobble 时点):这次收听过了官方阈值
	// (ListenBrainz / 网页中继那一刻已经提交)之后,Last.fm 那一路按用户选的更严时点
	// (features().LastfmScrobblePoint)挂起、到点再发。pending 非 nil = 挂着;settled = 已经发过
	// (或已记进本地收听日志),LB 重试成功再次走到 applySubmitOutcome 时不再重来。
	// 见 recordLastfmListen / settleLastfmPending。
	lastfmPending *pendingLastfmListen
	lastfmSettled bool
	// ended / endedNaturally:finalize(与退出兜底)时置位。ended 让迟到的 applySubmitOutcome 知道
	// 会话已经结束、不会再有下一拍;endedNaturally 是「曲终」档的判据(sessionEndedNaturally),
	// 只在会话结束那一刻算一次。null-glitch 续接旧会话时 ended 复位(handle 里 recentFinalized 那段)。
	ended          bool
	endedNaturally bool
	// lastPos / lastPosAt:最近一拍观察到的播放位置及其锚点时刻(p.cur.Position / AnchorTS),
	// 只在播放中更新。finalize 那一拍 p.cur 已经是新曲目(或空),旧曲播到了哪里只能从这里拿,
	// 见 sessionEndedNaturally。
	lastPos   float64
	lastPosAt time.Time
}

// pendingLastfmListen 是挂起等 scrobble 时点的那条 Last.fm 收听——commit 时要用的全部参数。
// artistName 是 lbMeta(meta).ArtistName,跟 LB 那一路同源(见 submitOutcome.artistName)。
type pendingLastfmListen struct {
	artistName string
	meta       snapshot
	startedAt  int64
}

func listenThreshold(duration float64) float64 {
	if duration > 0 {
		return min(duration/2, listenCapSecs)
	}
	return listenCapSecs
}

// tooShortToScrobble 判"这首歌短到不该记一次收听"。Last.fm 官方规则(api/scrobbling)写的是
// "The track must be longer than 30 seconds",是给客户端的规则——服务端不拒收、ignoredMessage
// 也没有"太短"这一码;主流 scrobbler 都在客户端照做。这里默认照做(minTrackSecs),用户显式
// 打开 features().ScrobbleShortTracks 才放行(加,设置里「短于 30 秒的曲目」,默认关)。
//
// 三点不变:①曲长拿不到(≤0)时不拦,跟原来一样;②放行之后半程规则(listenThreshold)照旧,
// 20 秒的歌得听满 10 秒;③这条闸在提交漏斗**入口**(到点提交/切歌收尾/退出兜底)和回填复核
// 四处共用。放行的短曲目**只发 Last.fm**(含本地收听日志和回填——它们本来就是给 Last.fm 兜底
// 的),ListenBrainz 那一路由 shortTrackLastfmOnly 单独挡住、维持原状:这是 Last.fm 页的设置,
// 它跟 ListenBrainz 无关。
func tooShortToScrobble(durationSecs float64) bool {
	if durationSecs <= 0 || durationSecs >= minTrackSecs {
		return false
	}
	return !features().ScrobbleShortTracks
}

// shortTrackLastfmOnly 判"这次收听只发 Last.fm、不发 ListenBrainz"。短曲目只有在
// features().ScrobbleShortTracks 打开时才能通过 tooShortToScrobble 走进提交漏斗,而那个开关是
// Last.fm 页的设置——ListenBrainz 自己没有 30 秒规则,但用户要的是"这个配置项跟 ListenBrainz
// 没有一点关系",所以 LB 对短曲目维持原来的行为(不发)。两处调用:submitSingleAsync(活路径)
// 和退出兜底那条同步路径,两处都要挡,漏一处就是"平时不发、退出时发"的分裂。
func shortTrackLastfmOnly(durationSecs float64) bool {
	return features().ScrobbleShortTracks && durationSecs > 0 && durationSecs < minTrackSecs
}

// 「曲终」档(scrobblePointEnd)判定的容差,见 sessionEndedNaturally。
const (
	// 会话结束时的推算位置离曲尾不到这么多秒就算「放到了结尾」。要盖住两类真实存在的提前切换:
	// 播放器自己的淡入淡出(Apple Music / Spotify 的 crossfade 最长 12 s,新曲在旧曲真声还剩几秒
	// 时就接上)和 Spotify gapless 提前打锚点(~0.84 s,见 posBias)。短曲目按曲长的 10% 收窄,
	// 免得 40 秒的歌放到 28 秒也算放完。
	trackEndSlackSecs     = 12.0
	trackEndSlackFraction = 0.10
	// 最近一拍到会话结束之间按播放外推,但外推量封顶两拍:播放器退出 / 断读后 nullStreak 要走满
	// 三拍(15 s)才终结会话,不封顶的话"中途退出播放器"会被多算 15 s、误判成放完。
	trackEndMaxExtrapolateSecs = 2 * float64(pollInterval/time.Second)
)

// lastfmScrobblePointReached 判"Last.fm 那一路现在该发了没"。调用前提是这次收听**已经过了官方
// 阈值**(listenThreshold)——那是 ListenBrainz / 网页中继提交的时刻,也是 Last.fm 官方规则的下限,
// 所以默认档(scrobblePointHalf)在这里恒为 true、行为跟加这个设置之前一字不差。更严的档只管
// Last.fm(这个设置按设计只作用于 Last.fm 这一路),ListenBrainz 不受影响。
//
// 曲长拿不到(≤0)时百分比无从算起、曲终也判不了,一律退回官方规则(当场发)——不把「没有时长」
// 变成「永远不发」。百分比档纯按已播时长(playedSecs,口径见 accrueListening:暂停不计、拖进度不灌水、
// App 没新读到的那几拍不计)算,不再套 4 分钟上限:"听了 75%" 就是字面意思。
func lastfmScrobblePointReached(s *playSession) bool {
	d := s.meta.Duration
	switch features().LastfmScrobblePoint {
	case scrobblePoint75:
		return d <= 0 || s.playedSecs >= 0.75*d
	case scrobblePoint90:
		return d <= 0 || s.playedSecs >= 0.90*d
	case scrobblePointEnd:
		return d <= 0 || s.endedNaturally
	default:
		return true
	}
}

// sessionEndedNaturally 判"这个会话是放到结尾才结束的"(「曲终」档的判据)。finalize 那一拍
// p.cur 已经是新曲目(或空),旧曲播到了哪里只能从会话自己记的最近一拍位置(lastPos@lastPosAt)
// 往前推:仍在播就按墙钟外推(封顶 trackEndMaxExtrapolateSecs),暂停着就取原值;推算位置离曲尾
// 不到 trackEndSlack 即算放完。
//
// 它分不开「最后十几秒被切掉」和「淡入淡出提前接歌」,这是刻意的取舍:前者本来就该算听完了,
// 后者不放过会让所有开着 crossfade 的用户在这一档一条都记不上。单曲循环回绕(loopRestart)
// 也走 finalize,位置在曲尾附近,同样判成放完——那一遍确实放完了。
func sessionEndedNaturally(s *playSession, now time.Time) bool {
	d := s.meta.Duration
	if d <= 0 || s.lastPosAt.IsZero() {
		return false
	}
	pos := s.lastPos
	if s.lastPlaying {
		pos += min(max(now.Sub(s.lastPosAt).Seconds(), 0), trackEndMaxExtrapolateSecs)
	}
	return pos >= d-trackEndSlack(d)
}

func trackEndSlack(duration float64) float64 {
	return min(trackEndSlackSecs, duration*trackEndSlackFraction)
}

// recordLastfmListen 是 Last.fm 那一路的入口:官方阈值一到(applySubmitOutcome),把这条挂到会话上,
// 再问一次 settleLastfmPending——默认档当场就发,更严的 scrobble 时点则留着等。挂起的条目跟着会话走:
// 播放中每拍(handle)、会话结束(finalize)、进程退出(run 的 flush)三处都会再问;会话就此消亡
// (被别的会话顶掉、或读空续接窗口过期)则这条对 Last.fm 永远不发 —— 这正是用户选更严
// 时点想要的效果,不是丢失,所以也**不**写本地收听日志(那份日志只给 Last.fm 回填兜底)。
//
// 不在 finalize 里"没到点就丢弃":finalize 也会因为短暂读空被调用(比如 App 重启、更新那几秒),60 s 内
// 同一首歌复现会续接旧会话(handle 里 recentFinalized 那段),丢早了续接回来就再也发不出去了。
//
// 幂等:LB 失败后重试成功会再次走到这里,lastfmSettled / 已有 pending 都直接返回——原来这种情况下
// appendListen 会重复追加一行(mirrorScrobbleTracked 有 uts 守卫,本地日志没有),现在不会了。
func (p *poller) recordLastfmListen(s *playSession, artistName string, meta snapshot, startedAt int64) {
	if s.lastfmSettled || s.lastfmPending != nil {
		return
	}
	// 没有歌手就别上送:Last.fm 的 track.updateNowPlaying / track.scrobble 与
	// ListenBrainz 的 submit-listens **都把 artist 当必填**,少了一律 400。实测电台的台标 / 口播
	// 正是这个形状(标题 "YEONJUN"、歌手与专辑全空),那 80 秒里每 5 秒往两边各打一次 400、
	// 没有退避也没有上限,当天累计 30 次。这道闸跟电台无关、对所有播放器成立 —— 发一个必然
	// 被拒的请求没有任何收益。
	if artistName == "" {
		s.lastfmSettled = true
		log.Printf("lastfm: skipping scrobble without an artist: %q - %q", meta.Artist, meta.Title)
		return
	}
	// 用户在 Last.fm 设置里把这个播放器排除(lastfmexclude.go):不镜像、也不记给它兜底的
	// 本地收听日志,标成 settled 让后续到点判断全部跳过。ListenBrainz 那一路早在 submitSingleAsync 发过了,
	// 不受影响 —— 与短曲目 / scrobble 时点同一口径,「Last.fm 页的设置跟 ListenBrainz 无关」。
	if s.lastfmExcluded {
		s.lastfmSettled = true
		log.Printf("lastfm: skipping scrobble from excluded player %s: %q - %q", meta.Bundle, meta.Artist, meta.Title)
		return
	}
	s.lastfmPending = &pendingLastfmListen{artistName: artistName, meta: meta, startedAt: startedAt}
	if !p.settleLastfmPending(s) {
		slog.Debug("lastfm: scrobble deferred to scrobble point", "point", features().LastfmScrobblePoint,
			"played_secs", int(s.playedSecs), "duration_secs", int(meta.Duration), "artist", meta.Artist, "title", meta.Title)
	}
}

// settleLastfmPending 到点就把挂起的 Last.fm 收听发出去,返回本次是否发了。真正的两个动作跟加
// 这个设置之前 applySubmitOutcome 里的一模一样:连着账号就镜像(mirrorScrobbleTracked,异步),
// 没连就记进本地收听日志(它只给 Last.fm 回填兜底,所以同样服从 scrobble 时点)。
func (p *poller) settleLastfmPending(s *playSession) bool {
	if s.lastfmPending == nil || !lastfmScrobblePointReached(s) {
		return false
	}
	if p.exitFlushCtx != nil {
		p.settleLastfmPendingSync(p.exitFlushCtx, s)
		return true
	}
	l := s.lastfmPending
	s.lastfmPending, s.lastfmSettled = nil, true
	p.mirrorScrobbleTracked(l.artistName, l.meta.Title, l.meta.albumForUpload(), l.startedAt, l.meta.Artist, l.meta.Duration, l.meta.NotAudio)
	// 本地收听日志:**只在没有在往 Last.fm 提交时**才记(见 appendListen 的注释)。
	//
	// 这一段原来的注释写的是"**无条件**记一笔,不看任何账号配没配",而紧跟着的就是
	// 下面这个 `if p.lfm == nil` —— 收窄之后旧结论留在了最显眼的位置,新结论
	// 被塞在末尾当补充。通盘梳理时坐实这确实误导过判断(照字面读会以为镜像
	// 失败时本地还有一份兜底,实际没有,那正是那次数据丢失能瞒住这么久的原因之一)。
	if p.lfm == nil {
		appendListen(l.meta.Artist, l.meta.Title, l.meta.albumForUpload(), l.startedAt, l.meta.Duration)
	}
	return true
}

// settleLastfmPendingSync 是 settleLastfmPending 的**同步**变体,只给进程退出前的最后一次 flush 用
// (mirrorAsync 起的 goroutine 活不过紧接着的 return,见 mirrorScrobbleSync)。
func (p *poller) settleLastfmPendingSync(ctx context.Context, s *playSession) {
	if s.lastfmPending == nil || !lastfmScrobblePointReached(s) {
		return
	}
	l := s.lastfmPending
	s.lastfmPending, s.lastfmSettled = nil, true
	p.mirrorScrobbleSync(withCatalogDurationUnknown(ctx, l.meta.NotAudio), l.artistName, l.meta.Title, l.meta.albumForUpload(), l.startedAt, l.meta.Artist, l.meta.Duration, l.meta.NotAudio)
	if p.lfm == nil {
		appendListen(l.meta.Artist, l.meta.Title, l.meta.albumForUpload(), l.startedAt, l.meta.Duration)
	}
}

// poller holds all the mutable state a run() loop iteration reads/writes,
// organized as a struct + methods (rather than closures over run()'s locals)
// so each piece can be unit-tested in isolation.
type poller struct {
	ctx context.Context
	cfg *config
	lb  *lbClient

	lfm         *lastfmScrobbler
	lfmKey      lastfmScrobblerKey // 建 lfm 时用的那组输入,见 syncLiveConfig
	lfmMirrored map[int64]bool

	cur  snapshot
	sess *playSession
	// 供 null-glitch 假死恢复续接用:最近一次因"停播"(含假死误判)终结的 session 及其
	// 终结时刻,见 finalize()/handle() 里 nullResumeGraceWindow 的用法。
	recentFinalized   *playSession
	recentFinalizedAt time.Time
	// app:读 App 写的播放状态当这一拍的快照(见 appsource.go);nil = 不读(测试)。
	app *appPlayback
	// appSpotifyTrackID:这一拍 App 带来的 Spotify 曲目 ID,开会话时用(见 detectAdAtSessionStart)。
	appSpotifyTrackID string

	// 自建状态中继:每轮把"网页该显示的当前状态"推到 /push(Mac 在放优先,否则 iPhone
	// 镜像,否则上次播放)。按状态变化 + 心跳去重。remoteTrack/lastListen 由 bridge/
	// finalize 更新。这是取代 LB 作网页主数据源的写入端。
	relayLastState   string
	relayLastAt      time.Time
	relayWrites      int           // 累计成功 KV /push 写次数(埋点:实测每日写量+定位大头)
	relayFailKey     string        // 上次推送失败时的 key:内容变了就清退避、立即再试
	relayFailAt      time.Time     // 上次推送失败时刻(零=当前无退避)
	relayBackoff     time.Duration // 当前退避间隔(失败翻倍,上限 10min)
	relayStateSince  time.Time     // 最近一次推上去的 key 从什么时候起没变过(不在播放的状态据此停心跳)
	relayDeferKey    string        // 换歌后等封面的那条 key 与开始等的时刻(见 relayShouldPush)
	relayDeferSince  time.Time
	relayInflight    bool                 // 有一次推送在后台飞着;结果经 relayDoneCh 回主循环
	relayDoneCh      chan relayPushResult // 容量 1,配合 relayInflight 保证发送永不阻塞
	lastListenSeedCh chan lastListenSeed  // 启动时从 ListenBrainz 取回的最近一条收听(见 seedLastListen)
	remoteTrack      snapshot             // iPhone(经 Last.fm)当前在播;remoteAt 为零表示无
	remoteAt         time.Time
	lastListen       snapshot // 最近一条完成收听(供空闲时显示"上次播放")
	lastListenAt     int64
	lastListenDev    string

	// 启动时等推送要用的信息到齐(见 relayStartupPending)。
	relayStartupUntil time.Time // 等到这一刻为止;零值表示不等
	lastListenSeeding bool      // 启动补种(seedLastListen)还没回来

	// 推送健康度(见 relaystatus.go)。
	relayGen          int       // 中继地址或令牌每改一次加一;在飞的推送带着它,回来时不是这一份就不记账
	relayFailingSince time.Time // 这一串推送失败从什么时候开始;零 = 上一次推成功了或还没推过
	relayStatusKey    string    // 上次写进状态文件的失败类别(kind|status),同一类不重写

	// Last.fm bridge (iPhone via FastScrobbler→Last.fm) state.
	forwardedSet    persistedTTLSet
	lfmMirroredSet  persistedTTLSet
	lastfmCheckedAt time.Time
	bridgeFetching  bool // 见 bridge()/applyBridgeResult 顶部注释,防止同时起两个 lastfmRecent 请求
	// feed 里最近一次"有人在听"的时刻(now-playing / 新 scrobble),决定拉取节奏,见
	// lastfmFeedInterval。跟 remoteAt 不是一回事:remoteAt 只在 LB 桥接那段里维护、
	// 且 Mac 一活跃就被清零,这里要的是"Last.fm 那边最近有没有动静"本身。
	feedActivityAt   time.Time
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

	// 每月 / 年度听歌小结(见 calendardigest.go)。
	monthlyRun calendarDigestRun
	yearlyRun  calendarDigestRun

	// 历史播放 Top10 歌手,一天算一次推给状态中继(见 topartists.go)。
	topArtistsState         topArtistsState
	topArtistsLastCheckedAt time.Time

	// 身份缓存旧条目下一轮补核的时刻(见 identityrecheck.go)。
	identityRecheckAt time.Time

	// 上面四档报告与 Top 歌手榜在后台 goroutine 里跑,有一轮在跑时为 true(见 runDigestsAsync)。
	// 这几组 *State / *LastCheckedAt / *Run 字段只由那个 goroutine 读写。
	digestBusy atomic.Bool

	nullStreak int
	// nullSince:这一串连续读空的第一拍是什么时候。清空要求「三拍」**而且**持续够 nullClearMinWait:
	// poll() 不只由 5 秒的 ticker 触发,预取的每一首解析完都会经 enrichNotify 再触发一轮,换歌那几秒里
	// 三次读空能挤在一两秒内凑齐,「三拍 = 15 秒」的前提(见 trackEndMaxExtrapolateSecs)就不成立了。
	nullSince time.Time
	// curStale:这一拍 p.cur 不是 App 新读到的 —— App 按住着上一份(holding),或者 App 状态不可用 / 没在放、
	// p.cur 是读空去抖期间留着的上一首。这几拍不计收听时长(见 noteListeningTick)。curHeld:是按住造成的。
	curStale bool
	curHeld  bool

	// LB 提交(single/playing_now)改到后台 goroutine 跑，结果经这两个 channel 送回单一
	// 的 poll 主循环处理——goroutine 本身只做网络 I/O,不直接碰 session/poller 字段，
	// 所有状态变更仍然只发生在 poll 主循环里，不引入并发读写。见 submitSingleAsync/
	// announce 顶部注释、run() 里的 drain 分支。
	submitDoneCh   chan submitOutcome
	announceDoneCh chan announceOutcome
	// submitsInflight:发出去了、结果还没回到 applySubmitOutcome 的那几条 single 提交(按会话记)。
	// 只给退出兜底用:上一首刚 finalize、它的提交还在飞时进程要退出,run() 不再等 submitDoneCh,
	// 这一条的 Last.fm 镜像、本地收听日志、LB 待重发全都没人管(见 drainSubmitsOnExit)。只在主循环上读写。
	submitsInflight map[*playSession]submitOutcome
	// exitFlushCtx:进程正在退出(run() 的最后一次 flush)时是那次 flush 的 ctx,平时 nil。非 nil 时
	// settleLastfmPending 改走同步变体:退出兜底里 drainSubmitsOnExit 结算的那些会话要发 Last.fm,异步 goroutine
	// 活不过紧接着的 return,而「已镜像」标记在发之前就落了盘,被截断的那一条从此谁都不会再发。只在主循环上读写。
	exitFlushCtx context.Context
	// bridge() 里读 Last.fm(lastfmRecent,8s 超时)改到后台 goroutine 跑,结果经这个
	// channel 送回单一 poll 主循环处理——理由同 submitDoneCh/announceDoneCh:Last.fm
	// 一慢,同步调用会连带堵住 poll() 后面紧接着的 pushRelayState,让网页刷新(包括
	// enrichNotify 刚解析出的封面/歌词)跟着冻结最长 8 秒。
	bridgeDoneCh chan bridgeFetchResult
	// iPhone 完成收听转发到 LB 在后台跑(forwardBridgeListens),结果经这个 channel 回主循环;
	// bridgeForwarding 为 true 时有一轮在飞,不另起一轮。
	bridgeForwardDoneCh chan []bridgeForwardResult
	bridgeForwarding    bool
}

// bridgeFetchResult 是后台 goroutine 拉取 Last.fm 数据(lastfmRecent)的结果，经
// bridgeDoneCh 送回 poll 主循环，由 applyBridgeResult 处理(转发/镜像 iPhone 状态等
// 有状态副作用的逻辑，仍只在主循环里跑，不引入并发读写)。
type bridgeFetchResult struct {
	now  time.Time
	page lastfmRecentPage // np/done/total 一起(2026-09-03,feed 要用 total)
	ok   bool
}

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

// isTracked:这一拍 Mac 上有一首在算的歌(App 播放状态里认下的那首)。选中了哪些播放器、自动识别认哪些、
// 信任列表,都只在 App 判:App 只把它认下的播放器写进播放状态。别在这里按选中集合再复核一遍,两份规则一旦
// 漂开,App 认下的歌会在这里被静默丢掉(不记收听、不推网页)。pushRelayState / handle / bridge 共用。
func (p *poller) isTracked() bool {
	return p.cur.key() != ""
}

// mirrorScrobbleTracked 先同步记入"已镜像"集合并落盘,再异步镜像写入 Last.fm——见
// lfmMirroredTTL 处注释:写入必须先于发起请求完成,防 bridge 抢在标记前误转发。
//
// 幂等:同一个 timestamp 只提交一次。Last.fm 镜像与 ListenBrainz 的
// 提交结果解耦(见 applySubmitOutcome),LB 失败重试成功后会再次走到调用点 —— 没有
// 这个守卫就会对 Last.fm 重复提交同一次收听。
// rawArtist/durationSecs 只在失败留痕时用(见 recordFailedMirror):写进本地收听日志的
// 必须是**播放器报的原始艺人名** —— 上送本身也是原样发原始标签,
// 见 listenLogLine.AR 的注释,回填会拿它重新跑一遍同样的归一化,喂折叠后的值进去等于
// 折叠两次。
// notAudio:这一条是 MV(snapshot.NotAudio),编目匹配按未知时长判,见 withCatalogDurationUnknown。
func (p *poller) mirrorScrobbleTracked(artist, title, album string, timestamp int64, rawArtist string, durationSecs float64, notAudio bool) {
	if p.lfm == nil || timestamp <= 0 {
		return
	}
	if p.lfmMirrored[timestamp] {
		return
	}
	p.lfmMirrored[timestamp] = true
	// 写之前顺手修剪:bridge() 里那处修剪要求配了桥接用户名,只开镜像写入、没配桥接的机器上
	// 这个集合只涨不落,而且每次 scrobble 都整份重写。
	p.lfmMirroredSet.trim(p.lfmMirrored, time.Now())
	p.lfmMirroredSet.save(p.lfmMirrored)
	// 取一份局部变量再交给 goroutine:p.lfm 会被主循环换掉(syncLiveConfig)。
	lfm := p.lfm
	mirrorAsync(lfm, "scrobble", func(ctx context.Context) error {
		err := lfm.scrobble(withCatalogDurationUnknown(ctx, notAudio), artist, title, album, timestamp, durationSecs)
		if err == nil {
			// 我们自己刚写进 Last.fm 一条:几秒后拉一次 feed,App 那边"上一首"就能立刻进
			// 列表,不用等下一个拉取周期(这里在 goroutine 里,只碰 atomic,见 lastfmfeed.go)。
			requestLastfmFeedRefresh(5 * time.Second)
		}
		return err
	}, func(err error) {
		recordFailedMirror(err, rawArtist, title, album, timestamp, durationSecs)
		enqueueLastfmRetryIfSafe(err, lfmRetryItem{User: lfm.user, Timestamp: timestamp, Artist: artist, Title: title, Album: album,
			Duration: durationSecs, NotAudio: notAudio})
	})
}

// recordFailedMirror 给一次**没写进 Last.fm** 的收听留痕,让它还有被救回来的机会。
//
// 为什么不是"撤销 lfmMirrored 标记、下一拍重发"(评估后否掉的方案):
//   - 那要从 mirrorAsync 的 goroutine 里写 p.lfmMirrored,而主循环会经
//     persistedTTLSet.save 整个 range 它 —— 并发写 = 不可 recover 的 fatal error。
//   - 收益也几乎没有:实测 10 次 DNS 故障里只有 1 次在同一首歌还没放完时等到网络恢复,
//     其余 9 次 session 早被 finalize 丢弃,标记撤了也没人再提交。
//
// 所以标记**保持置位**(活路径永不再发这条 到 物理上不可能双发),改为把这一条落进
// listens.jsonl,交给作者已经写好的回填(13 天窗口/批量/限速/隔离/UI 有计数)。
//
// 三类失败的处置完全不同,合并成一种就必然错一边:
//
//   - **可证明没发出去**(DNS/dial 失败):服务端不可能见过它,补提交零重复风险 到 只写
//     "l",回填会正常挑走。
//   - **服务端拒收内容本身**(accepted=0):这首歌换多少次也还是这首歌,重发必然同样被拒
//     到 什么都不写,只靠上面 mirrorAsync 那行日志把真实原因(现在带 ignoredMessage 了)
//     暴露出来,让人去改数据而不是让机器空转。
//   - **不确定发没发到**(超时/连接中断/服务端说自己暂时不可用):写 "l" + "q" 一对。
//     "q" 让回填**永远不会自动重试**它(见 markQuarantined 的注释:重复比漏补贵得多),
//     "l" 则保住艺人/曲名,将来要人工对账才有依据 —— 原来这种情况连曲目是什么都查不
//     出来。
//
// 应用层错误(lastfmAPIError)**不能**一律当成"拒收":
// 限流(29)和凭据失效(4/9/10/26)下服务端**确定没落库**,那恰恰是最该
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
// 一次 flush 用:mirrorAsync 起的 goroutine 活不过紧接着的进程退出(审阅
// 确认的竞态 —— 标记已落盘、请求没发出去,这首歌对 Last.fm 永久丢失),退出路径必须
// 拿 flush 的 ctx 同步把请求发完。
func (p *poller) mirrorScrobbleSync(ctx context.Context, artist, title, album string, timestamp int64, rawArtist string, durationSecs float64, notAudio bool) {
	if p.lfm == nil || timestamp <= 0 {
		return
	}
	// 幂等守卫排在已熔断分支前面:活路径已经处理过这一条(发了、或者已经留过痕)时,退出这一拍不能再留一次痕、
	// 再排一次重发。
	if p.lfmMirrored[timestamp] {
		return
	}
	// 标记同样先于熔断分支:这一条将来经回填 / 重发队列补进 Last.fm 时,bridge 靠它认出是自己写的,
	// 不当 iPhone 收听再转发一遍(同 mirrorScrobbleTracked)。
	p.lfmMirrored[timestamp] = true
	p.lfmMirroredSet.save(p.lfmMirrored)
	if ctx.Err() != nil {
		// 退出兜底的时限在轮到这一条之前就用完了(前面几条同步提交、LB 提交慢):请求根本不会发出去,
		// 按「确定没发」留痕、排进重发队列,别让下面那次注定失败的调用把它当成「不确定」隔离掉。
		notSent := errors.Join(errLastfmNotSent, ctx.Err())
		recordFailedMirror(notSent, rawArtist, title, album, timestamp, durationSecs)
		enqueueLastfmRetryIfSafe(notSent, lfmRetryItem{User: p.lfm.user, Timestamp: timestamp, Artist: artist, Title: title, Album: album,
			Duration: durationSecs, NotAudio: notAudio})
		return
	}
	if p.lfm.dead.Load() {
		// 同 mirrorAsync 的入口:不发请求,但这一条确定没写进去,该留痕 —— 退出路径尤其
		// 不能漏,进程正要结束,没有"下一拍"能补。
		deadErr := &lastfmAPIError{Code: 9, Message: "mirror disabled (credentials judged dead)", Method: "track.scrobble"}
		recordFailedMirror(deadErr, rawArtist, title, album, timestamp, durationSecs)
		enqueueLastfmRetryIfSafe(deadErr, lfmRetryItem{User: p.lfm.user, Timestamp: timestamp, Artist: artist, Title: title, Album: album,
			Duration: durationSecs, NotAudio: notAudio})
		return
	}
	if err := p.lfm.scrobble(ctx, artist, title, album, timestamp, durationSecs); err != nil {
		warnf("lastfm mirror scrobble (final flush) failed: %v", err)
		// 退出路径同样要留痕 —— 而且这里比活路径更需要:进程正在退出,没有"下一拍"
		// 可言。这条是同步调用,本来就在主 goroutine 上,不涉及上面那条并发约束。
		recordFailedMirror(err, rawArtist, title, album, timestamp, durationSecs)
		enqueueLastfmRetryIfSafe(err, lfmRetryItem{User: p.lfm.user, Timestamp: timestamp, Artist: artist, Title: title, Album: album,
			Duration: durationSecs, NotAudio: notAudio})
	}
}

// 门槛只看 StateRelayURL 是否配置——不需要 features().StateRelay 这个独立总开关，
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
	// "他正在播放 We're Here / Instacart"(0:14、暂无同步歌词)。现象是。
	//
	// 判成 false 之后会顺着下面的 switch 落到 iPhone 正在放 / 上次播放,也就是广告这几十秒
	// 网页停在上一首,跟"没在放"时的表现一致 —— 不会出现一张假的当前曲目卡。判据见 isAdBreak。
	macHasTrack := p.isTracked() && !isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) &&
		!(p.sess != nil && p.sess.isAd)
	iphonePlaying := !p.remoteAt.IsZero() && now.Sub(p.remoteAt) < 90*time.Second
	switch {
	case macHasTrack && p.cur.Playing: // Mac 正在放 → 最高优先(带进度条)
		payload = relayState(p.cur, true, "mac", 0, true)
		key = "mac|" + p.cur.key() + relayAlbumHintSuffix(p.cur)
	case iphonePlaying: // iPhone(经 Last.fm 桥接)正在放
		payload = relayState(p.remoteTrack, true, "iphone", 0, true)
		key = "ip|" + p.remoteTrack.key()
	case macHasTrack: // Mac 有当前曲目但暂停 → 显示暂停态,让位给 iPhone 正在放
		payload = relayState(p.cur, false, "mac", 0, true) // 暂停但仍是 Mac 界面上此刻的曲目,current=true
		key = "macpause|" + p.cur.key() + relayAlbumHintSuffix(p.cur)
	case p.lastListen.key() != "":
		payload = relayState(p.lastListen, false, p.lastListenDev, p.lastListenAt, false) // 纯历史,current=false
		key = "last|" + p.lastListen.key() + relayAlbumHintSuffix(p.lastListen)
	default:
		payload = map[string]any{"ok": true, "empty": true, "playing": false}
		key = "empty"
	}
	if p.relayStartupPending(now, key) {
		return
	}
	// enrich 完成后同一首歌封面会从无到有,并入去重 key,触发一次补推(否则 key 未变被吞)。
	if cov, _ := payload["artwork"].(string); cov != "" {
		key += "|c"
	}
	reason, ok := p.relayShouldPush(now, key, payload, reanchored)
	if !ok || p.relayInflight {
		return
	}
	// 推送放后台:中继一次往返中位约 0.9 秒、偶尔 6 秒超时,同步做会让主循环在换歌那一刻停住
	// (暂停、拖进度、下一首都察觉不到)。记账在 applyRelayResult 里,仍只在主循环上改字段。
	p.relayInflight = true
	cfg, gen := p.cfg, p.relayGen
	go func() {
		err := postRelay(p.ctx, cfg, "/push", payload)
		p.relayDoneCh <- relayPushResult{key: key, reason: reason, at: now, err: err, gen: gen}
	}()
}

// 中继推送的节奏。省 KV 写额度(免费仅 1000 写/天,实测有一天写了 1022 次):进度由网页从锚点外推,
// 连播中途无需重写。
const (
	// 心跳:同一状态最多隔这么久重写一次,须 < worker STALE_MS=5min,否则 KV 会被判过期而退回 LB。
	relayHeartbeat = 4 * time.Minute
	// 不在播放的状态(暂停 / 上次播放 / 空)维持这么久之后不再续心跳:之后 KV 过期、网页和飞书退回
	// ListenBrainz 的「上次播放」,内容基本一样,省下的是长时间暂停每 4 分钟一次的写(实测占全部写的两成多)。
	relayIdleHeartbeatFor = 30 * time.Minute
	// 换了一首歌、封面还没到位时最多等这么久再推:封面一般几秒内就解析出来(enrichNotify 会立刻补一拍),
	// 等一下就能一次写到位,不用先推一次无封面、再补推一次(实测补推约占全部写的一成)。网页本身
	// 10 秒才拉一次,这点延迟看不出来。
	relayCoverWait = 5 * time.Second
	// 引擎刚启动时最多等这么久再推(见 relayStartupPending),覆盖启动补种那次请求的整个时限。
	relayStartupWait = relayRequestTimeout
)

// relayTrackOf 取 key 里标识曲目的那段(去掉状态前缀和 |c / |a 后缀),用来判断是不是换了一首歌。
func relayTrackOf(key string) string {
	_, rest, _ := strings.Cut(key, "|")
	rest = strings.TrimSuffix(rest, "|c")
	return strings.TrimSuffix(rest, "|a")
}

// relayHasProgress:这个状态的负载带进度条(Mac 正在放 / iPhone 正在放)。只有它们需要重锚。
func relayHasProgress(key string) bool {
	return strings.HasPrefix(key, "mac|") || strings.HasPrefix(key, "ip|")
}

// relayShouldPush 决定这一拍要不要推、为什么推(给日志埋点)。只读写中继相关的 poller 字段,
// 在主循环上调用。
func (p *poller) relayShouldPush(now time.Time, key string, payload map[string]any, reanchored bool) (string, bool) {
	progress := relayHasProgress(key)
	if !progress {
		reanchored = false // 没有进度条的状态,重锚改不了网页上任何东西
	}
	changed := key != p.relayLastState
	if changed && progress && relayTrackOf(key) != relayTrackOf(p.relayLastState) {
		if cov, _ := payload["artwork"].(string); cov == "" {
			if key != p.relayDeferKey {
				p.relayDeferKey, p.relayDeferSince = key, now
				return "", false
			}
			if now.Sub(p.relayDeferSince) < relayCoverWait {
				return "", false
			}
		}
	}
	if !changed && !reanchored {
		if now.Sub(p.relayLastAt) < relayHeartbeat {
			return "", false
		}
		if !progress && now.Sub(p.relayStateSince) >= relayIdleHeartbeatFor {
			return "", false
		}
	}
	reason := "heartbeat"
	if changed {
		reason = "change"
	} else if reanchored {
		reason = "reanchor"
	}
	// 退避:上次推送失败(配额爆/中继挂)后别每轮硬试(否则每 5s 白烧一次 worker 请求+刷屏)。
	// 内容变了(key 变,如换歌)→ 清退避立即再试,让 KV 恢复后尽快回主路径;同内容按退避重试。
	if key != p.relayFailKey {
		p.relayFailAt, p.relayBackoff = time.Time{}, 0
	}
	if !p.relayFailAt.IsZero() && now.Sub(p.relayFailAt) < p.relayBackoff {
		return "", false
	}
	return reason, true
}

// relayStartupPending:引擎刚启动时这一拍先不推。App 的播放状态读到之前什么都不推(还不知道 Mac 在不在放),
// 启动补种回来之前不推「空」。两样都到齐、或等满 relayStartupWait,就撤掉这道等,往后照常推。见 13 章决策 13。
func (p *poller) relayStartupPending(now time.Time, key string) bool {
	if p.relayStartupUntil.IsZero() {
		return false
	}
	appKnown := p.app == nil || p.app.usedAvail == appStateAvailable
	if !now.Before(p.relayStartupUntil) || appKnown && !p.lastListenSeeding {
		p.relayStartupUntil = time.Time{}
		return false
	}
	return !appKnown || key == "empty"
}

// relayPushResult 是后台推送的结果,经 relayDoneCh 送回主循环。
type relayPushResult struct {
	key, reason string
	at          time.Time
	err         error
	gen         int // 发出时的 relayGen
}

// applyRelayResult 在主循环上记账:成功更新去重锚点,失败进退避(去重锚点不动,按退避在后续 poll 重试)。
func (p *poller) applyRelayResult(r relayPushResult) {
	p.relayInflight = false
	if r.gen != p.relayGen {
		return // 中继地址或令牌在它飞着的时候改了:说的是旧配置,不记账
	}
	if r.err != nil {
		warnf("relay push failed: %v", r.err)
		p.relayFailKey, p.relayFailAt = r.key, r.at
		if p.relayBackoff == 0 {
			p.relayBackoff = 30 * time.Second
		} else if p.relayBackoff < 10*time.Minute {
			p.relayBackoff *= 2
		}
		p.noteRelayFailure(r.err, r.at)
		return
	}
	p.relayFailAt, p.relayBackoff, p.relayFailKey = time.Time{}, 0, ""
	p.noteRelaySuccess()
	if r.key != p.relayLastState {
		p.relayStateSince = r.at
	}
	p.relayLastState, p.relayLastAt = r.key, r.at
	p.relayWrites++
	log.Printf("relay write #%d [%s] key=%q", p.relayWrites, r.reason, r.key) // 埋点:实测每日 KV 写量与来源
}

// pushScrobble 记一条完成收听。历史/今日统计现改由网页从 LB 合并(每条完成收听已双写 LB,
// 见各 lb.submit "single"),不再写 KV /scrobble——省写额度(①减写)。仅更新内存 lastListen:
// 空闲时"上次播放"显示 + pushRelayState 兜底态用。
func (p *poller) pushScrobble(s snapshot, listenedAt int64, device string) {
	p.lastListen, p.lastListenAt, p.lastListenDev = s, listenedAt, device
}

// albumHintFor:这条快照要不要、能不能补一个 Apple 目录反查的专辑名(见 albumhint.go 头注)。
// 已经有专辑名的不动;广告不查 —— Spotify 原生广告的形状恰好就是 album 为空,拿广告标题去 iTunes 搜只会白烧
// 请求。appleAlbumHint 只读缓存、没命中就后台补取,这一拍先按现状走;旁证(lyricResolvedArtists)每拍重读,
// 歌词晚几秒解析出来、回填就晚几秒出现。
func (p *poller) albumHintFor(s snapshot) string {
	if s.Album != "" || s.Title == "" || s.Artist == "" || isAdBreak(s.Bundle, s.Artist, s.Title, s.Album) {
		return ""
	}
	// 用 Kaset 放的歌先用 YouTube Music 给它登记的专辑:App 界面专辑位显示的就是它,上送跟界面一致。
	if album := kasetListedAlbumFor(kasetVideoIDFor(s.Bundle, s.Artist, s.Title), s.Duration, s.Artist, s.Title); album != "" {
		return album
	}
	return appleAlbumHint(p.ctx, s.Artist, s.Title, albumHintDurationSecs(s), lyricResolvedArtists(s.Artist, s.Title, s.Album))
}

// relayAlbumHintSuffix:Apple 目录回填的专辑名到位后(通常比换歌晚一拍),同一首歌的 relay 负载里 album 会从空
// 变有 —— 跟封面那个 `|c` 一样并进去重 key,触发一次补推;否则 key 没变会被吞、网页要等 4 分钟心跳才看到专辑。
func relayAlbumHintSuffix(s snapshot) string {
	if s.Album == "" && s.AlbumHint != "" {
		return "|a"
	}
	return ""
}

// submitOutcome/announceOutcome 是后台 goroutine 提交完成后、经 channel 送回单一
// poll 主循环处理的结果。goroutine 本身只做网络 I/O,不直接改 session/poller 字段。
type submitOutcome struct {
	sess *playSession
	meta snapshot
	// artistName 是 lbMeta(meta).ArtistName,顺带给 Last.fm 镜像复用(见
	// applySubmitOutcome),两条路取同一份、不各算一遍。
	// lbMeta 不再做任何替换,所以它就等于**播放器报的原始标签**;
	// 保留这个字段是为了两条路径永远同源,而不是因为它还需要被加工。
	artistName string
	startedAt  int64
	// lm:当初发给 LB 的那份载荷。失败进待重发队列时原样用它,不再对 meta 重算 lbMeta —— 重算会带上歌词、
	// 对已经结束的曲目还可能触发一次首次联网解析(trackEnrichment)。
	lm lbTrackMeta
	// lastfmOnly:这条是开着「短于 30 秒的曲目」放进来的短曲目,没发 ListenBrainz(见
	// shortTrackLastfmOnly);err 恒为 nil,applySubmitOutcome 据此换一行日志。
	lastfmOnly bool
	err        error
	// doneAt:提交结果回来的时刻,失败时据此排下一次重试(listenRetryAt)。没填(测试里手拼的)按处理时的当前时间算。
	doneAt time.Time
}

// listenRetrySchedule:歌还在放时,收听提交连着失败第 N 次之后隔多久再试(N 从 1 起,超出表长按最后一档)。
// 别改成每拍重试:LB 回 502 的时候一首歌会在一分钟里连发十几次。
var listenRetrySchedule = []time.Duration{15 * time.Second, 30 * time.Second, time.Minute, 2 * time.Minute}

func listenRetryDelay(failures int) time.Duration {
	if failures < 1 {
		failures = 1
	}
	if failures > len(listenRetrySchedule) {
		failures = len(listenRetrySchedule)
	}
	return listenRetrySchedule[failures-1]
}

type announceOutcome struct {
	sess *playSession
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
	// 没有歌手就别上送 —— 两个平台都把 artist 当必填,发过去只会 400(理由与实测见 recordLastfmListen
	// 里那道同款闸)。标成已处理,免得每一轮 poll 都重来一次。
	if lm.ArtistName == "" {
		log.Printf("skipping listen without an artist: %q - %q", meta.Artist, meta.Title)
		sess.listenSent = true
		return
	}
	if shortTrackLastfmOnly(meta.Duration) {
		// 短曲目只发 Last.fm(见 shortTrackLastfmOnly):不打 LB,直接把一个"成功"结果送回
		// 主循环,让 applySubmitOutcome 走 Last.fm 镜像 / 本地日志 / 会话收尾那条既有路径——
		// 不另开一条分支,免得两条路以后各改各的。这里已经在主循环里,同步调用即可。
		p.applySubmitOutcome(submitOutcome{sess: sess, meta: meta, artistName: lm.ArtistName, startedAt: startedAt, lastfmOnly: true})
		return
	}
	if p.submitsInflight == nil {
		p.submitsInflight = map[*playSession]submitOutcome{}
	}
	p.submitsInflight[sess] = submitOutcome{sess: sess, meta: meta, artistName: lm.ArtistName, startedAt: startedAt, lm: lm}
	go func() {
		err := p.lb.submit(p.ctx, "single", startedAt, lm)
		select {
		case p.submitDoneCh <- submitOutcome{sess: sess, meta: meta, artistName: lm.ArtistName, startedAt: startedAt, lm: lm, err: err,
			doneAt: time.Now()}:
		case <-p.ctx.Done():
		}
	}()
}

// drainSubmitsOnExit 是退出兜底的第一步:已经回来的提交结果照常处理;还在飞的(请求随 p.ctx 一起被取消,
// 结果多半到不了 submitDoneCh)按「没发成」处理 —— applySubmitOutcome 会照常走 Last.fm 那一路,会话已经结束
// 的再交给 LB 待重发队列(下次启动由 lbretry.go 重发;万一其实已经送到,LB 按 listened_at 去重)。
// 当前会话不在这里管,由 run() 里紧接着的同步提交兜底。
func (p *poller) drainSubmitsOnExit() {
	for drained := false; !drained; {
		select {
		case r := <-p.submitDoneCh:
			p.applySubmitOutcome(r)
		default:
			drained = true
		}
	}
	for sess, r := range p.submitsInflight {
		if sess == p.sess {
			delete(p.submitsInflight, sess)
			continue
		}
		r.err = context.Canceled
		p.applySubmitOutcome(r)
	}
}

// applySubmitOutcome 在 poll 主循环里处理 submitSingleAsync 的结果——不管此时 p.sess
// 是否还指向同一个 session(很可能早已因为换曲被 finalize 分离走了)，这里的字段变更和
// 收听记录都只作用于结果自带的 sess/meta，不依赖 p.sess 当前值，所以时序上没有问题。
func (p *poller) applySubmitOutcome(r submitOutcome) {
	delete(p.submitsInflight, r.sess)
	r.sess.submitting = false
	// Last.fm 镜像与 ListenBrainz 的提交结果解耦(批4):这次收听够不够格
	// 在发起提交前就已经判定过了,LB 服务抽风不该殃及 Last.fm 那份记录 —— 原来镜像躲
	// 在下面的成功分支里,LB 挂则两边一起停摆。LB 失败重试成功后会再次走到
	// 这里,mirrorScrobbleTracked 的幂等守卫保证不重复提交。
	//
	// 经 recordLastfmListen:Last.fm 镜像 + 本地收听日志这两个动作搬进了
	// settleLastfmPending,默认档(scrobblePointHalf)当场就发、跟原来一字不差;用户选了更严的
	// scrobble 时点时先挂在会话上,到点再发(见 recordLastfmListen 的注释)。
	//
	// 位置必须在下面那句 `if r.err != nil { return }` **之前**:LB token 填错或 LB 挂掉
	// 时 Last.fm 这一路同样要走 —— 这个理由至今成立,收窄针对的是"连没连 Last.fm",不是"LB 成没
	// 成功"。跟紧上方把 Last.fm 镜像从 LB 成功分支里挪出来是同一个道理。
	p.recordLastfmListen(r.sess, r.artistName, r.meta, r.startedAt)
	if r.err != nil {
		warnf("submit listen failed: %v", r.err)
		// 会话已经结束就不会再有人重试它(播放中每拍重试只管当前会话),交给待重发队列;
		// LB 明确拒收(4xx)的重发也没用,不进队列。
		if errors.Is(r.err, errListenRejected) {
			// LB 明确不收这条(内容本身的问题,令牌被拒是另一种错误、不走这里):重发多少次都一样,标成已处理,
			// 免得歌还在放时每拍再发一次。
			r.sess.listenSent = true
			return
		}
		if r.sess.ended {
			enqueueLBRetry(r.startedAt, r.lm)
			return
		}
		doneAt := r.doneAt
		if doneAt.IsZero() {
			doneAt = time.Now()
		}
		r.sess.listenFailures++
		r.sess.listenRetryAt = doneAt.Add(listenRetryDelay(r.sess.listenFailures))
		return
	}
	r.sess.listenSent = true
	if r.lastfmOnly {
		log.Printf("listen recorded (Last.fm only, %.0fs track under %.0fs): %s - %s", r.meta.Duration, minTrackSecs, r.meta.Artist, r.meta.Title)
	} else {
		log.Printf("listen recorded: %s - %s", r.meta.Artist, r.meta.Title)
	}
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
	// 会话结束:先给挂着的 Last.fm 收听一次"到点了吗"的机会——「曲终」档的判据只有在这一刻才成立,
	// 百分比档也可能恰好在最后一拍之后才过线。没到点**不**在这里丢(理由见 recordLastfmListen)。
	s.ended, s.endedNaturally = true, sessionEndedNaturally(s, now)
	if !p.settleLastfmPending(s) && s.lastfmPending != nil {
		slog.Debug("lastfm: session ended before scrobble point", "point", features().LastfmScrobblePoint,
			"played_secs", int(s.playedSecs), "duration_secs", int(s.meta.Duration), "artist", s.meta.Artist, "title", s.meta.Title)
	}
	if s.listenSent || s.submitting || tooShortToScrobble(s.meta.Duration) {
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
// 去重(sess.announcing)；pnPending 在 applyAnnounceOutcome 里清除,调用方拿不到同步的"是否成功"。
// 发出去就记 pnTriedAt(成败都算),下一次刷新按它隔开。
// detectAdAtSessionStart 开播时的广告判定:isAdBreak(App 的广告结论)。不是广告的 Spotify
// 原生播放顺带记下这次的曲目 ID(App 带来的那个),给歌词缓存的真曲目链接与 LB 上送用。
func (p *poller) detectAdAtSessionStart() bool {
	if isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) {
		return true
	}
	// Spotify 曲目 ID 用 App 带来的那个(它取自 Spotify 自己的播放通知)。
	if p.cur.Bundle == spotifyBundleID && p.appSpotifyTrackID != "" {
		noteSpotifyTrackID(p.cur.Artist, p.cur.Title, p.cur.Album, p.appSpotifyTrackID)
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
	// 没有歌手就别宣布"正在播放" —— 同一道闸(见 submitSingleAsync)。电台台标那 80 秒里
	// 每 5 秒一次的 400 就是从这里发出去的。
	if p.cur.Artist == "" {
		return
	}
	p.sess.announcing = true
	p.sess.pnTriedAt = now
	sess := p.sess
	m := lbMeta(p.cur)
	// artist 给 Last.fm 用:跟 m.ArtistName(给 LB 用)取同一份,保证 now-playing 与
	// 落库不会各说各话。
	//
	// lbMeta **不再做 canonical_artist 替换**,两者都等于播放器原始
	// 标签。原注释描述的是那次替换(为了解决"方大同/Khalil Fong 在 Last.fm 分裂"),
	// 现在那个问题改由**显示/统计层**归并解决,上送层只如实记录 —— 完整依据见 lb.go
	// 里 lbMeta 那段(Last.fm 官方反对自动套用纠正 / 业界无一默认这么做 / 实测有真错)。
	// album 走 albumForUpload:播放器没报专辑名时用 Apple 目录回填的那个,报了就原样。
	artist, title, album := m.ArtistName, p.cur.Title, p.cur.albumForUpload()
	// 跟 artist/title/album 一样在**闭包外**取值:下面那个 goroutine 直接读 p.cur 就是
	// 跨 goroutine 读 poller 状态,违反"所有状态只在 poll 主循环里碰"那条不变量。
	durationSecs := p.cur.Duration
	notAudio := p.cur.NotAudio
	playing := p.cur.Playing
	// Last.fm 那一路的按播放器排除(lastfmexclude.go):只挡 track.updateNowPlaying,LB 的 playing_now 照发。
	// 同样在闭包外取值,理由同上。
	lastfmSkip := p.sess.lastfmExcluded
	// Last.fm writer 同样在闭包外取:主循环的配置热重读会换掉 p.lfm(syncLiveConfig),
	// 在 goroutine 里读就是跟它的数据竞争(见 configreload.go 头注那条约定)。
	lfm := p.lfm
	// Last.fm now-playing 自己节流(见 lastfmNPAt):播放 / 暂停切换当场发,其余最多每 playingNowRefresh 一次。
	lastfmDue := playing && !lastfmSkip &&
		(sess.lastfmNPAt.IsZero() || why == "state change" || now.Sub(sess.lastfmNPAt) >= playingNowRefresh)
	if lastfmDue {
		sess.lastfmNPAt = now
	}
	go func() {
		// now-playing 镜像与 LB 解耦(批4):"正在播放"反映的是本机播放器
		// 的真实状态,不是 LB 提交的成败。放在 LB 请求之前发起 —— 两者本就各自异步。
		//
		// 只在**真的在放**时镜像给 Last.fm:track.updateNowPlaying 没有"暂停"这个
		// 概念,暂停时发过去等于宣布"我正在听这首"。announce 有三个调用点会在非播放态
		// 触发:进程启动时当前曲目本就暂停(走"换曲"分支开 session)、播放与暂停的状态
		// 切换、挂起首条到点补发。引擎一重启就会把一首
		// 暂停的歌 announce 上去,直接顶掉用户手机上正在放的那首的 nowplaying。
		// LB 不受影响 —— 它要靠 rate=0 表达暂停、自己会丢弃,所以下面的 submit 照旧发。
		if lastfmDue {
			mirrorAsync(lfm, "now-playing", func(ctx context.Context) error {
				return lfm.updateNowPlaying(withCatalogDurationUnknown(ctx, notAudio), artist, title, album, durationSecs)
			}, nil) // now-playing 失败无需留痕:它是瞬时状态,下一拍自然覆盖(跟 scrobble 相反)
		}
		err := p.lb.submit(p.ctx, "playing_now", 0, m)
		if err != nil {
			warnf("submit playing_now (%s) failed: %v", why, err)
		}
		select {
		case p.announceDoneCh <- announceOutcome{sess: sess, ok: err == nil}:
		case <-p.ctx.Done():
		}
	}()
}

func (p *poller) handle(now time.Time, reanchored, loopRestart bool) {
	key := p.cur.key()
	isMusic := p.isTracked()
	// 专辑回填通常比换歌晚一拍到(见 albumHintFor):同一首歌的会话元数据跟着补上,这样到点提交的
	// Last.fm scrobble / 本地收听日志(它们用的是会话开始时那份 meta)也带上专辑。
	if p.sess != nil && p.sess.key == key && p.sess.meta.AlbumHint == "" && p.cur.AlbumHint != "" {
		p.sess.meta.AlbumHint = p.cur.AlbumHint
	}
	// 电台真曲长同样比会话起点晚到,补同一份 meta。电台的 duration 只有 Apple 目录知道(系统报的是整档节目,
	// 实测 7074.538s),而目录锚点是**异步**的:实测 Dolly Parton《Dumb Blonde》会话 20:15:45.030
	// 建立、目录 20:15:49.740 才给出 150.447s,晚 4.7 秒。sess.meta 是会话创建那一刻的快照,
	// 不补的话 listenThreshold 拿到的是 0 → 退回 240s 上限 → 电台曲目(普遍 2~4 分钟)永远够不着,
	// 一条收听都提交不了 —— 跟 radioduration.go 头注里"条目落盘那一拍目录还没命中"是同一个异步坑,
	// 只是那边补的是歌词缓存的时长、这边补的是打卡阈值的分母。
	//
	// 只填空缺、不覆盖已有值(同上面专辑回填的规则):有值就说明会话起点那一拍已经拿到了权威时长。
	// **只对电台生效**:非电台时 p.cur.Duration 来自播放器自己,而 media-control 在换曲预载窗口
	// 里会把**下一首**的时长拼进当前曲目(见 enrich.go 的 observeWrongDuration),拿那种脏值回填
	// 等于把一个错的分母钉死一整首歌;电台这一路的 duration 只可能来自过了自校验的目录锚点。
	if p.sess != nil && needsRadioDurationBackfill(p.sess.key == key, p.cur.Radio,
		p.sess.meta.Duration, p.cur.Duration) {
		p.sess.meta.Duration = p.cur.Duration
	}
	// 汽水非会员试听:会话开在试听段还没查到的那一拍,记下的是试听段长度,查到之后补成整首 ——
	// 否则试听 30 秒就够着「听满一半」,被记成一次收听。判据见 sodaPreviewSessionBackfill。
	if p.sess != nil && p.sess.key == key &&
		sodaPreviewSessionBackfill(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.sess.meta.Duration, p.cur.Duration) {
		p.sess.meta.Duration = p.cur.Duration
	}

	// Player quit or another app took over: finalize and drop the session.
	if !isMusic {
		if p.sess != nil {
			// 有位置可核的留着计时起点:短暂读空误判停播、同一首很快复现续接这个会话时,空档按 App 报的位置补
			// (位置没走就补不上,见 listenAccrualSecs);没有位置的照旧不补。
			if !p.sess.lastSeenHasPos {
				p.sess.lastSeen = time.Time{}
			}
			p.finalize(now)
		}
		return
	}

	// New track: finalize previous, open a session, announce playing_now.
	if p.sess == nil || p.sess.key != key {
		p.finalize(now)
		if p.recentFinalized != nil && p.recentFinalized.key == key && now.Sub(p.recentFinalizedAt) < nullResumeGraceWindow {
			// 短暂读空(比如 App 重启、更新那几秒)误判停播后同一首歌很快复现:续接旧
			// session(播放进度/是否已提交过 listen 都带过去),不清零重开——否则这次
			// 收听会被切成两段,各自达到阈值时向 LB 提交两条重复的 listen。
			p.sess = p.recentFinalized
			p.sess.pnPending = false // 即将重新走一遍"是否需要挂起等歌词"的判定
			p.sess.ended = false     // 会话还没完;挂着的 Last.fm 收听(lastfmPending)继续跟着它等到点
		} else {
			p.sess = &playSession{key: key, meta: p.cur, startedAt: now, lastPlaying: p.cur.Playing}
			p.noteListeningTick(now)
			p.sess.isAd = p.detectAdAtSessionStart()
			p.sess.lastfmExcluded = lastfmExcluded(p.cur.Bundle)
		}
		p.recentFinalized = nil
		// 带上 bundle:换歌是按播放器排查问题的起点(预解析走哪一层、署名修正、本地缓存命中都按
		// 播放器分流),不带就追不到这一首是哪个播放器在放。专辑和时长是缓存 key 与选版本的依据,
		// 不带的话要另外去查这一首落在哪条缓存上。
		// 括号里的放在最后,前半段格式不变,按「now playing: 歌手 - 歌名」grep 的老习惯照样好用。
		log.Printf("now playing: %s - %s (album=%q duration=%.0fs bundle=%s)", p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Duration, p.cur.Bundle)
		// 记下正在播的这首:它的提交当场写单条快照、整份落盘最多节流 2 秒,别的歌的落盘攒着(见 enrichsave.go)。
		// 只能在这里记 —— trackEnrichment 也会被「上一首」调到(切歌后给上一首提交收听、空闲时中继推上一首)。
		noteEnrichPlayingKey(enrichKey(p.cur.Artist, p.cur.Title, p.cur.Album))
		// 顺手把接下来会播的那几首也丢到后台解析,提前解析好等真播到时大概率不用现等。
		// 优先读播放器自己的队列,读不到才退回"同一张专辑里的其它曲目"——两层的理由见
		// upcoming.go 头注。
		// 广告不预取:它的「专辑」不是专辑、队列里也找不到它,读一遍队列只会白等重试再退回同专辑预取。
		if features().AlbumPrefetch && (p.sess == nil || !p.sess.isAd) &&
			!isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) {
			prefetchUpcoming(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle, p.cur.Duration)
		}
		// LB 的 playing_now 只在"换曲"时更新、同曲存活期内拒绝覆盖,迟到的歌词再也进不去。
		// 故首条须在 enrich 解析完后再发(那时才知有无歌词、有则带上)。已解析(缓存命中,无论
		// 有无歌词)立即发;仅首次解析中(缓存未命中)才挂起,由下方处理器等 enrich 完成
		// (enrichNotify 触发)或超时再发。仅影响 KV 兜底路径,KV 主路径不受此延迟。
		// 汽水试听段还在搜:这一拍的时长是试听段长度,先不解析歌词,挂起等下一拍(见 SodaPreviewPending)。
		if !p.cur.SodaPreviewPending &&
			len(trackEnrichment(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle, p.cur.lyricsDurationSecs(), true, p.cur.Radio)) > 0 {
			p.announce(now, "new")
		} else {
			p.sess.pnPending = true
		}
		return
	}

	// 单曲循环重新起播(App 的 play_seq 增加而身份不变,见 appPlaybackTickFor 里
	// loopRestart 的判定):上一轮的收听记录早该已经提交过,这里另起一个全新 session
	// 重新计时,让新一轮播满阈值时也能被当成一条独立收听提交。不能走上面"换曲"分支的
	// recentFinalized 续接逻辑——那是给 null-glitch 假死恢复用的,key 没变的话会被
	// 误判成同一次收听的假死恢复,反而抵消掉这里想要的效果,所以显式清空、不复用。
	if loopRestart {
		p.finalize(now)
		p.recentFinalized = nil
		p.sess = &playSession{key: key, meta: p.cur, startedAt: now, lastPlaying: p.cur.Playing}
		p.noteListeningTick(now)
		p.sess.isAd = p.detectAdAtSessionStart()
		p.sess.lastfmExcluded = lastfmExcluded(p.cur.Bundle)
		log.Printf("loop restart: %s - %s", p.cur.Artist, p.cur.Title)
		if len(trackEnrichment(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle, p.cur.lyricsDurationSecs(), true, p.cur.Radio)) > 0 {
			p.announce(now, "loop restart")
		} else {
			p.sess.pnPending = true
		}
		return
	}

	// 广告标记棘轮:同曲期间任一拍 App 判成广告就永久置位(字段会闪变,App 的结论跟着闪,见 playSession.isAd)。
	if !p.sess.isAd && isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) {
		p.sess.isAd = true
		log.Printf("ad break detected mid-session: %q - %q", p.cur.Artist, p.cur.Title)
	}

	// Same track: on a play/pause transition, re-announce immediately so the
	// web progress bar re-anchors on resume or freezes on pause (rate=0),
	// instead of waiting up to one refresh interval.
	submitted := false
	// 挂起的首条:等 enrich 解析完(enrichNotify 会触发一轮 poll,那时才知有无歌词)或超过
	// pnPendingMax 再作为"换曲那条"发出,发出去失败了隔 playingNowRefresh 再发(pnTriedAt)。
	// 挂起期间不发状态切换/刷新提交(会锁死无歌词的换曲那条)。
	if p.sess.pnPending {
		// isNewTrack 传 false:这是同一个 session 里等 enrich 完成的轮询重试,不是新曲目
		// 开始播放的那一刻,不该再取一次设备封面(那一刻已经在上面 "New track" 分支取过了)。
		resolved := !p.cur.SodaPreviewPending &&
			len(trackEnrichment(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle, p.cur.lyricsDurationSecs(), false, p.cur.Radio)) > 0
		if (resolved || now.Sub(p.sess.startedAt) >= pnPendingMax) && now.Sub(p.sess.pnTriedAt) >= playingNowRefresh {
			p.announce(now, "first") // pnPending 在结果异步返回后由 applyAnnounceOutcome 清除
		}
		submitted = true
	}
	// 计时始终维护(即便挂起中):否则挂起窗口内的暂停不会停表,恢复时会把暂停时长误计入 playedSecs。
	// 只把"状态切换的 playing_now 提交"挡在挂起之后。
	p.noteListeningTick(now)
	if p.cur.Playing != p.sess.lastPlaying {
		p.sess.lastPlaying = p.cur.Playing
		if !p.sess.pnPending {
			p.announce(now, "state change")
			submitted = true
		}
	}

	// App 没新读到的拍(按住、读空去抖)到这里为止:不挪「曲终」书签、不刷新正在播放、不判阈值。
	if !p.cur.Playing || p.curStale {
		return
	}
	// 「曲终」档要用的位置书签(见 sessionEndedNaturally),只在播放中记;顺带看挂着的 Last.fm
	// 收听是否到了 scrobble 时点(百分比档在这里过线)。
	if at := p.cur.AnchorTS; at.IsZero() {
		p.sess.lastPos, p.sess.lastPosAt = p.cur.Position, now
	} else {
		p.sess.lastPos, p.sess.lastPosAt = p.cur.Position, at
	}
	p.settleLastfmPending(p.sess)
	// Publish a fresh anchor on a re-anchor (seek / sleep-wake) or on the
	// periodic refresh, so the web always extrapolates from a recent point.
	if !submitted && (reanchored || now.Sub(p.sess.pnTriedAt) >= playingNowRefresh) {
		p.announce(now, "refresh")
	}
	if !p.sess.listenSent && !p.sess.submitting && !now.Before(p.sess.listenRetryAt) &&
		p.sess.playedSecs >= listenThreshold(p.sess.meta.Duration) &&
		!tooShortToScrobble(p.sess.meta.Duration) {
		p.sess.submitting = true
		p.submitSingleAsync(p.sess, p.sess.meta, p.sess.startedAt.Unix())
	}
}

// noteListeningTick 让会话的收听计时走一拍(handle 每拍调一次,p.sess 就是 p.cur 这首)。这一拍不是 App 新读到的
// (p.curStale)就不计、不挪起点,只记下空档里 App 按住过;是新读到的交给 accrueListening。
func (p *poller) noteListeningTick(now time.Time) {
	if p.curStale {
		if p.curHeld {
			p.sess.gapHeld = true
		}
		return
	}
	p.sess.accrueListening(now, p.cur)
}

// accrueListening 把上一个计时起点到这一拍之间的收听计进 playedSecs,再按这一拍挪起点:在播就记下此刻与位置,
// 暂停就停表。只拿 App 新读到的拍调用。
func (s *playSession) accrueListening(now time.Time, cur snapshot) {
	hasPos := !cur.AnchorTS.IsZero()
	if !s.lastSeen.IsZero() {
		s.playedSecs += listenAccrualSecs(now.Sub(s.lastSeen).Seconds(), s.lastSeenPos, cur.Position,
			s.lastSeenHasPos && hasPos, s.gapHeld, cur.Playing)
	}
	s.gapHeld = false
	if cur.Playing {
		s.lastSeen, s.lastSeenPos, s.lastSeenHasPos = now, cur.Position, hasPos
	} else {
		s.lastSeen = time.Time{}
	}
}

// listenAccrualSecs:两次读数之间计多少收听(秒)。纯函数,单测覆盖。
//   - 两头都有 App 报的位置:不超过位置实际前进的量。暂停、短睡眠、按住期间播放器停了,位置不走就不算;
//     往后拖进度不灌水,往回拖的那一拍不算。间隔超过 maxAccrualGapSecs 时,只有空档是 App 按住造成的
//     (heldGap)才补:按住解除那一次写出的是 App 新读到的位置。别的长空档(睡眠唤醒后保活先于读数写出)
//     里的位置可能是从旧锚点外推的,不算。
//   - 没有位置可核:按墙钟,超过 maxAccrualGapSecs 的不算;这一拍已经暂停也不补(分不出暂停前放了多久)。
func listenAccrualSecs(wall, fromPos, toPos float64, positions, heldGap, playingNow bool) float64 {
	if wall <= 0 {
		return 0
	}
	if !positions {
		if !playingNow || wall > maxAccrualGapSecs {
			return 0
		}
		return wall
	}
	if wall > maxAccrualGapSecs && !heldGap {
		return 0
	}
	return max(min(wall, toPos-fromPos), 0)
}

// bridge kicks off a background fetch of Last.fm (iPhone via FastScrobbler→
// Last.fm) gently every lastfmFeedInterval(15 s / 空闲 60 s) — 见 bridgeDoneCh 顶部注释,
// lastfmRecent 本身(8s 超时)挪到 goroutine 跑,不阻塞 poll() 后面紧跟的
// pushRelayState。实际的转发/镜像逻辑(有状态副作用)在 applyBridgeResult 里、
// 结果送回主循环后才跑。
//
// 不再看一个独立的 features().LastfmBridge 开关——Last.fm 桥接凭据 +
// ListenBrainz 账号都配好,就默认跑;独立开关只是多一次点击,没有实际区分度。
//
// 更正:这段原来还断言"这两项本来就是 Swift 侧 UI 上打开那个开关的前置
// 条件(lastfmBridgeMissingHint()==nil 且 isListenBrainzConfigured 都满足才让点)"——
// 那句话是**错的**。下面这个门要求 cfg.User(ListenBrainz 用户名)非空,而 Swift 侧的
// isListenBrainzConfigured 只看 token,当时 UI 上用户名那栏还标着"选填"。于是只填
// token 的用户在设置页看到桥接是"活的",这里却直接 return,什么都不发生、也不报错。
// Swift 侧现已补上 isListenBrainzReadable(token+用户名)专门表示"能读统计",跟这个门
// 对齐;用户名输入框的提示也改成了"听歌报告需要"。改这里的条件时记得同步那一侧。
//
// 拉取这一步的门槛**只看 Last.fm 凭据**,不再要求 ListenBrainz 也配好——同一份
// 响应现在还要落成 App 读的 recent feed(lastfmfeed.go),那跟 LB 毫无关系。LB 桥接
// (转发 iPhone 收听、镜像远端 now-playing)的门槛原样保留,搬到了 applyBridgeResult 里
// (bridgeForwardingEnabled)。节奏也从固定 15 s 改成自适应(lastfmFeedInterval:有人在听
// 15 s、空闲 60 s),并接受"镜像 scrobble 刚成功"的提前拉一次(lastfmFeedNudgeDue)。
func (p *poller) bridge(now time.Time) {
	if p.cfg.LastfmUser == "" || p.cfg.lastfmBridgeAPIKey() == "" {
		return
	}
	if p.bridgeFetching || lastfmRecentRateLimited(now) {
		return
	}
	localPlaying := p.cur.Playing && p.isTracked()
	due := now.Sub(p.lastfmCheckedAt) >= lastfmFeedInterval(localPlaying, p.feedActivityAt, now)
	// 跨进程信号文件(回填子命令刚补进一批,见 lastfmFeedNudgePath):**消费掉,但不当场拉**,
	// 改成排一个延迟拉取。理由跟 requestLastfmFeedRefresh 头注是同一条 —— Last.fm 把刚收到的
	// scrobble 并进 recenttracks 要一两秒,立刻拉多半还看不到。
	//
	// 当场拉的代价不止"这一次白拉"(用户**第三次**报「补提交之后下面的列表没
	// 刷新」的根因,前两次修在别处):拉回来的是旧内容,却照样把 feed 的 fetchedAt 刷成此刻,
	// 于是 App 侧那道兜底强刷(ScrobbleBackfillService 在 accepted > 0 之后 8 秒发、判据是
	// LastfmStatsService.feedIsFresh → LastfmRecentFeed.isFresh,fetchedAt 在 180 s 窗口内)
	// **永远判"新鲜"、永远不触发** —— 而 feed 只要引擎活着就每 60 s 心跳重写一次
	// (feedHeartbeat),fetchedAt 跟内容有没有变没关系。两头一叠,用户只能干等下一个
	// 15 s/60 s 周期。镜像 scrobble 那条路径从一开始就是延迟 5 秒的,这里跟它对齐。
	if lastfmFeedNudgeFileDue() {
		requestLastfmFeedRefresh(backfillFeedNudgeDelay)
	}
	// 两个触发源任一成立就拉:到周期、提前拉到期(镜像 scrobble / 回填,两者都带延迟)。
	if !due && !lastfmFeedNudgeDue(now) {
		return
	}
	p.lastfmCheckedAt = now
	p.bridgeFetching = true
	user, apiKey := p.cfg.LastfmUser, p.cfg.lastfmBridgeAPIKey()
	go func() {
		page, ok := lastfmRecent(p.ctx, user, apiKey)
		select {
		case p.bridgeDoneCh <- bridgeFetchResult{now: now, page: page, ok: ok}:
		case <-p.ctx.Done():
		}
	}()
}

// bridgeForwardItem 是一条要转发给 LB 的 iPhone 完成收听(载荷在主循环上算好)。
type bridgeForwardItem struct {
	uts   int64
	meta  lbTrackMeta
	track snapshot
}

// bridgeForwardResult:rejected = LB 明确拒收(4xx,记进 forwarded 不再试);否则就是送达了。
// 没送达的瞬时失败不出现在结果里,下一轮从它重试。
type bridgeForwardResult struct {
	item     bridgeForwardItem
	rejected bool
}

// forwardBridgeListens 在后台按从旧到新的顺序逐条提交,瞬时失败就停(停在这一条,下一轮从它重试),
// 结果经 bridgeForwardDoneCh 回主循环。
func (p *poller) forwardBridgeListens(items []bridgeForwardItem) {
	var out []bridgeForwardResult
	for _, it := range items {
		err := p.lb.submit(p.ctx, "single", it.uts, it.meta)
		if err != nil {
			if errors.Is(err, errListenRejected) {
				log.Printf("bridge: skip rejected lastfm listen %q - %q: %v", it.track.Artist, it.track.Title, err)
				out = append(out, bridgeForwardResult{item: it, rejected: true})
				continue
			}
			warnf("bridge: forward lastfm listen failed, will retry: %v", err)
			break
		}
		out = append(out, bridgeForwardResult{item: it})
	}
	select {
	case p.bridgeForwardDoneCh <- out:
	case <-p.ctx.Done():
	}
}

// applyBridgeForwardResults 在主循环上把后台那一轮的结果记进 forwarded。
func (p *poller) applyBridgeForwardResults(results []bridgeForwardResult) {
	p.bridgeForwarding = false
	if len(results) == 0 {
		return
	}
	for _, r := range results {
		p.forwarded[r.item.uts] = true
		if !r.rejected {
			log.Printf("bridge: listen from iPhone/Last.fm: %s - %s", r.item.track.Artist, r.item.track.Title)
			p.pushScrobble(r.item.track, r.item.uts, "iphone")
		}
	}
	p.forwardedSet.save(p.forwarded)
	p.pushRelayState(time.Now(), false)
}

// lfmNowPlayingEcho:Last.fm 上这条「正在播放」是不是我们自己镜像写进去的。先按本地当前曲目比(原来的判据),
// 再按最近一次实际发出去的写法比 —— 编目匹配 / 合唱截断改写过的歌手名,跟本地标签比不上。
func (p *poller) lfmNowPlayingEcho(artist, title string, now time.Time) bool {
	if p.lfm == nil {
		return false
	}
	if p.cur.Title != "" && looseContains(artist, p.cur.Artist) && looseContains(title, p.cur.Title) {
		return true
	}
	sa, st := p.lfm.sentNowPlayingAt(now)
	return st != "" && looseContains(artist, sa) && looseContains(title, st)
}

// bridgeForwardingEnabled:iPhone→ListenBrainz 桥接(转发完成收听 + 镜像远端 now-playing)
// 的既有门槛。之前它跟"要不要拉 Last.fm"是同一个判断,现在拉取只看 Last.fm
// 凭据(见 bridge()),这里单独保住 LB 那半边的条件不变。
func (p *poller) bridgeForwardingEnabled() bool {
	return p.cfg.User != "" && p.cfg.Token != ""
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
	// 先落 feed(App 读的那份,见 lastfmfeed.go)——这一步只要 Last.fm 凭据,跟下面的 LB
	// 桥接无关。fetchedAt 用发起拉取的时刻 r.now(不是现在):响应体反映的是那一刻的状态。
	writeLastfmRecentFeed(p.cfg.LastfmUser, r.page, r.now)
	if at := lastfmFeedActivityAt(r.page, r.now); !at.IsZero() && at.After(p.feedActivityAt) {
		p.feedActivityAt = at
	}
	if !p.bridgeForwardingEnabled() {
		return // 没配 ListenBrainz:下面全是往 LB 转发/镜像的逻辑,原来在 bridge() 入口就挡掉
	}
	// 异步化之后,这次处理结果不再必然发生在 poll() 里紧跟 pushRelayState 那次调用之内
	// (可能在两次 poll tick 之间才到达),所以这里补一次推送——沿用
	// applySubmitOutcome/applyAnnounceOutcome 同款"处理完就主动推一次、内部去重兜底"
	// 的模式。用 defer 而不是在每个 return 分支前手动加一遍,保证不管走哪条分支
	// (Mac 抢占/iPhone 停播/判定为自己的回声/正常记录 iPhone 在播)都会触发。
	defer p.pushRelayState(time.Now(), false)
	now, np, done := r.now, r.page.NowPlaying, r.page.Done

	// 把 Last.fm 上"没转发过"的完成收听转成 LB listen(集合去重,天然兼容乱序/迟到:
	// 第三方客户端后台漏了、之后补同步的旧时间戳记录,只要不在集合里就会被补上)。首次(无持久化
	// 文件)只 seed 当前窗口、不回灌整段历史。
	fwdChanged := false
	var pending []bridgeForwardItem
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
			m := lbMeta(snapshot{Title: s.Title, Artist: s.Artist, Album: s.Album, Remote: true})
			m.AdditionalInfo["source"] = "iphone"                     // 来源:iPhone(经 Last.fm 桥接)
			m.AdditionalInfo["media_player"] = mediaPlayerLabelIPhone // 这条桥接固定是 iPhone 上的 Apple Music,不受本地 Mac 播放器选择影响
			pending = append(pending, bridgeForwardItem{uts: s.UTS, meta: m, track: snapshot{Title: s.Title, Artist: s.Artist, Album: s.Album, Remote: true}})
		}
		// 本机经回填 / 重发队列补进 Last.fm 的收听:它们的时间戳不在 lfmMirrored 里(回填是独立的子命令进程,
		// 重发队列补的可能是早被修剪掉的旧条目),却有收听日志里的 "s" 回执。不排除的话会被当成 iPhone 新收听
		// 再转发给 ListenBrainz 一次(LB 已经从 Mac 路径收过)。只在真有候选时读一次日志。
		if len(pending) > 0 {
			receipts := listenLogReceiptTimestamps()
			kept := pending[:0]
			for _, it := range pending {
				if receipts[it.uts] {
					p.forwarded[it.uts], fwdChanged = true, true
					continue
				}
				kept = append(kept, it)
			}
			pending = kept
		}
		// 提交放后台:LB 一次提交中位约 1.1 秒、慢时十几秒,手机一次同步上来好几条时串行跑在主循环里
		// 会卡住十几到几十秒(暂停、换歌都察觉不到)。按顺序提交、失败即停这个语义留在后台那一轮里,
		// 结果交回主循环再记进 forwarded。上一轮还在飞时不另起一轮:挑出来的条目还没记进 forwarded,
		// 再起一轮会把它们重复转发。
		if len(pending) > 0 && !p.bridgeForwarding {
			p.bridgeForwarding = true
			go p.forwardBridgeListens(pending)
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
	if p.lfmNowPlayingEcho(np.Artist, np.Title, now) {
		// Last.fm 上的"正在播放"跟本地 Mac 当前/最近曲目同名——很可能是我们自己刚
		// 镜像写入、Mac 已暂停但 Last.fm 侧还没自然过期的残留状态,不是真实 iPhone
		// 在放同一首歌。宁可漏判(小概率两台设备真放同一首)也不能误判成 iPhone。
		return
	}
	// 记录 iPhone 当前在播,供中继 /push 显示(Mac 空闲时)。
	p.remoteTrack, p.remoteAt = snapshot{Title: np.Title, Artist: np.Artist, Album: np.Album, Playing: true, Remote: true}, now
	key := np.Title + "|" + np.Artist
	if key == p.remoteKey && now.Sub(p.remotePN) < playingNowRefresh {
		return // already announced; refresh only every playingNowRefresh
	}
	p.remoteKey, p.remotePN = key, now
	meta := lbMeta(snapshot{Title: np.Title, Artist: np.Artist, Album: np.Album, Playing: true, Remote: true})
	meta.AdditionalInfo["source"] = "iphone"                     // 来源:iPhone(经 Last.fm 桥接)
	meta.AdditionalInfo["media_player"] = mediaPlayerLabelIPhone // 这条桥接固定是 iPhone 上的 Apple Music,不受本地 Mac 播放器选择影响
	artist, title := np.Artist, np.Title
	// 异步提交,不阻塞 bridge()/poll() 主循环(理由同 submitSingleAsync)——这条提交没有
	// 任何后续状态要维护(不像 Mac 侧的 lastPN/pnPending),失败只需要记日志,fire-and-forget
	// 即可,不需要像 single 提交那样经 channel 回主循环。
	go func() {
		if err := p.lb.submit(p.ctx, "playing_now", 0, meta); err != nil {
			warnf("bridge: submit lastfm playing_now failed: %v", err)
		} else {
			log.Printf("bridge: now playing (iPhone via Last.fm): %s - %s", artist, title)
		}
	}()
}

// needsRadioDurationBackfill 判「这一拍要不要把电台的真曲长补进会话元数据」(纯函数,单测钉住)。
// 语义、理由与四个条件各自防什么,见 handle() 里唯一那处调用点上方的注释。
func needsRadioDurationBackfill(sameTrack, radio bool, sessionDuration, currentDuration float64) bool {
	return sameTrack && radio && sessionDuration <= 0 && currentDuration > 0
}

// nullStreakMeansStopped:连续读空到了当停播处理的地步 —— 三拍,而且持续够 nullClearMinWait(见 poller.nullSince)。
func nullStreakMeansStopped(streak int, since, now time.Time) bool {
	return streak >= 3 && now.Sub(since) >= nullClearMinWait
}

// poll 跑一拍:按 App 写的播放状态得出此刻在放什么(见 appsource.go),再走会话、桥接、推送、报告。
func (p *poller) poll() {
	p.syncLiveConfig()
	now, reanchored, loopRestart := p.readAppPlayback()
	p.handle(now, reanchored, loopRestart)
	p.bridge(now)
	p.pushRelayState(now, reanchored)
	p.runDigestsAsync(now)
}

// readAppPlayback:用 App 写的播放状态得出这一拍(见 appsource.go)。App 状态不可用(退出中、进程不在、15 秒没写、
// 契约版本不认识)时待机:按读空处理,沿用停播确认结束会话;桥接、报告、补搜这些跟 Mac 播放无关的事照常。
func (p *poller) readAppPlayback() (now time.Time, reanchored, loopRestart bool) {
	now = time.Now()
	a := p.app
	if a == nil {
		return now, false, false
	}
	rec, avail, version := a.reader.readVersioned(now)
	a.usedPID, a.usedVersion, a.usedAvail = rec.AppPID, version, avail
	if avail != appStateAvailable {
		a.notePath("standby:"+string(avail), "App playback state "+string(avail)+", standing by")
		reanchored, loopRestart = p.applyAppPlaybackTick(now, appPlaybackTick{})
		return now, reanchored, loopRestart
	}
	a.notePath("app", "using the App's playback state")
	var tick appPlaybackTick
	tick, a.marks = appPlaybackTickFor(rec, a.marks, now, a.judge)
	reanchored, loopRestart = p.applyAppPlaybackTick(now, tick)
	return now, reanchored, loopRestart
}

// applyAppPlaybackTick 把 App 状态得出的这一拍落到 p.cur。App 没在放(或待机)时按停播确认处理
// (nullStreakMeansStopped):连续够三拍、满 nullClearMinWait 才清空,之前 p.cur 原样保留。留着的那几拍和
// App 按住着的拍记成 curStale,不计收听时长。
func (p *poller) applyAppPlaybackTick(now time.Time, t appPlaybackTick) (reanchored, loopRestart bool) {
	if !t.tracked {
		p.curStale, p.curHeld = true, false
		p.appSpotifyTrackID = ""
		if p.nullStreak == 0 {
			p.nullSince = now
		}
		p.nullStreak++
		if nullStreakMeansStopped(p.nullStreak, p.nullSince, now) {
			p.cur = snapshot{}
			// 广告标记跟着留下的那一首走,p.cur 清空时才清。别在空拍一来就清:App 卡住超过 appStateFreshness 时
			// 引擎进待机、p.cur 还留着那首广告,标记先没了的话补歌词会把广告当歌搜、写进缓存(见 02 章决策 99)。
			noteAppReportedAd(snapshot{}, false)
		}
		return false, false
	}
	p.nullStreak = 0
	p.cur = t.snap
	p.curStale, p.curHeld = t.holding, t.holding
	p.appSpotifyTrackID = t.spotifyTrackID
	noteAppReportedAd(p.cur, t.ad)
	noteAmazonCurrentTrack(p.cur.Bundle, p.cur.Artist, p.cur.Title, t.amazonTrackID)
	noteKasetCurrentTrack(p.cur.Bundle, p.cur.Artist, p.cur.Title, t.youtubeMusicVideoID)
	if p.cur.Radio {
		noteRadioDuration(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Duration)
	}
	if p.cur.NotAudio {
		noteMusicVideoDuration(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Duration)
	}
	p.cur.AlbumHint = p.albumHintFor(p.cur)
	return t.reanchor, t.loopRestart
}

func run(ctx context.Context, cfg *config, lb *lbClient) error {
	startLyricSourceStats(ctx)
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
		lfm:                 lastfmScrobblerIfEnabled(cfg),
		lfmKey:              lastfmScrobblerKeyOf(cfg),
		lfmMirrored:         lfmMirrored,
		forwardedSet:        forwardedSet,
		lfmMirroredSet:      lfmMirroredSet,
		forwarded:           forwarded,
		fwdSeeded:           fwdSeeded,
		weeklyState:         weeklyDigestState{path: weeklyDigestPath},
		dailyState:          dailyDigestState{path: dailyDigestPath},
		monthlyRun:          calendarDigestRun{state: calendarDigestState{path: monthlyDigestPath}},
		yearlyRun:           calendarDigestRun{state: calendarDigestState{path: yearlyDigestPath}},
		topArtistsState:     topArtistsState{path: topArtistsStatePath},
		submitDoneCh:        make(chan submitOutcome, 8),
		announceDoneCh:      make(chan announceOutcome, 8),
		bridgeDoneCh:        make(chan bridgeFetchResult, 1),
		bridgeForwardDoneCh: make(chan []bridgeForwardResult, 1),
		relayDoneCh:         make(chan relayPushResult, 1),
		lastListenSeedCh:    make(chan lastListenSeed, 1),
	}
	enrichNotify = make(chan struct{}, 1) // 后台 enrich 完成后触发一次重推
	lfmRetryTarget.Store(p.lfm)
	appState := newAppStateReader(configFilePath(clientName + "-playback-state.json"))
	p.app = &appPlayback{reader: appState, judge: liveAppPlaybackJudge}
	setAppPlaybackArtworkSource(appState, configFilePath(clientName+"-now-playing-artwork"))
	appAvailable := func() bool { _, avail := appState.read(time.Now()); return avail == appStateAvailable }
	// 预解析要问播放器的那几样请 App 代跑(见 appquery.go);文件名与 App 侧 PlayerQueryServer 逐字一致。
	setAppQueryChannel(configFilePath(clientName+"-player-query-request.json"), configFilePath(clientName+"-player-query-reply.json"), appAvailable)
	if cfg.StateRelayURL != "" && cfg.User != "" && lb != nil {
		p.lastListenSeeding = true
		go seedLastListen(ctx, lb.apiRoot(), cfg.User, p.lastListenSeedCh)
	}
	p.relayStartupUntil = time.Now().Add(relayStartupWait)
	p.poll() // render immediately, don't wait a full interval on startup
	if lb != nil {
		// 不看启动时有没有令牌:令牌可能是之后热重读才填上的。没有令牌的那几轮由循环自己跳过(见 startLBRetryLoop)。
		go startLBRetryLoop(ctx, lb) // 会话结束后才失败的收听,后台重发,见 lbretry.go
	}
	go startLfmRetryLoop(ctx)                         // 确定没写进 Last.fm 的收听,后台重发,见 lfmretry.go
	go startCompanionLaunchWatcher(ctx, appAvailable) // App 可用时不读进程表,见 companionlaunch.go 顶部注释
	go startEnrichCancelWatcher(ctx)                  // 独立节奏,见 enrichcancel.go 顶部注释
	go startEnrichEditWatcher(ctx)                    // App 侧改歌词缓存的请求,见 enrichedit.go 顶部注释
	go startKasetAlbumSweep(ctx)                      // 用 Kaset 放过、还没按当前界面语言判过专辑的条目补判一次,见 kasetalbum.go
	go startLyricsFillSweeper(ctx)                    // 存量空歌词的定时/手动补空扫描,见 lyricsfillsweep.go 顶部注释
	go startCoverSweeper(ctx)                         // 有词、没封面、外围字段从没补过的条目在后台各补一次,见 coversweep.go 顶部注释
	go startLyricsRematchWatcher(ctx)                 // 「重新自动匹配」,见 lyricsrematch.go 顶部注释

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	// 快速通道:App 状态一变就跑一轮,不等主节拍(见 appsource.go)。
	appTicker := time.NewTicker(appStateCheckInterval)
	defer appTicker.Stop()
	// App 一写播放状态就跑一轮:盯着状态文件所在的目录(见 dirwatch.go);盯不了时只剩上面每秒一次的检查。
	appWrites := make(chan struct{}, 1)
	if !watchDirWrites(ctx, filepath.Dir(appState.path), appWrites) {
		warnf("playback source: cannot watch the playback state dir, checking it once a second instead")
	}
	var lastWritePoll time.Time
	for {
		select {
		case <-ctx.Done():
			// Best-effort final flush with a fresh context.
			flushCtx, cancel := context.WithTimeout(context.Background(), submitTimeout)
			defer cancel()
			p.exitFlushCtx = flushCtx
			p.drainSubmitsOnExit()
			// 这条退出兜底路径直接调 mirrorScrobbleSync/lb.submit,不经过 submitSingleAsync,
			// 所以广告判据要在这里再挡一次(见 isAdBreak)。
			if p.sess != nil {
				// 会话到此为止:先算「曲终」判据,再看挂着等 scrobble 时点的那条 Last.fm 收听
				// (官方阈值早过了、LB 也早提交了的那种)到点没有,到了就同步发掉——异步 goroutine
				// 活不过紧接着的 return(见 mirrorScrobbleSync 注释)。
				p.sess.ended, p.sess.endedNaturally = true, sessionEndedNaturally(p.sess, time.Now())
				p.settleLastfmPendingSync(flushCtx, p.sess)
			}
			if p.sess != nil && !p.sess.listenSent && p.sess.playedSecs >= listenThreshold(p.sess.meta.Duration) &&
				!tooShortToScrobble(p.sess.meta.Duration) &&
				!p.sess.isAd && !isAdBreak(p.sess.meta.Bundle, p.sess.meta.Artist, p.sess.meta.Title, p.sess.meta.Album) {
				// Last.fm 镜像:与 LB 解耦,同样服从 scrobble 时点(默认档当场发),且必须走同步变体。
				//
				// 艺人名跟 LB 提交取同一份(lm.ArtistName)。lbMeta 不再做
				// canonical_artist 替换,所以 lm.ArtistName 就是**播放器原始标签** ——
				// 这里保持取同一份,是为了万一以后 lbMeta 又加了什么处理,两条路不会分叉。
				// 本地收听日志也在 settleLastfmPendingSync 里:退出前这最后一首也是一次算数的收听,
				// 不能漏。放在 LB 提交之前,理由跟 applySubmitOutcome 那处一致。
				lm := lbMeta(p.sess.meta)
				// 按播放器排除的(lastfmExcluded)不挂 Last.fm 那条,跟 recordLastfmListen 同一道闸;LB 照发。
				if !p.sess.lastfmSettled && p.sess.lastfmPending == nil && !p.sess.lastfmExcluded {
					p.sess.lastfmPending = &pendingLastfmListen{artistName: lm.ArtistName, meta: p.sess.meta, startedAt: p.sess.startedAt.Unix()}
				}
				p.settleLastfmPendingSync(flushCtx, p.sess)
				// 短曲目只发 Last.fm、不发 LB —— 跟 submitSingleAsync 同一条判据,两处都要挡。
				if shortTrackLastfmOnly(p.sess.meta.Duration) {
					p.recordRecentMacListen(p.sess.meta.Artist, p.sess.meta.Title, p.sess.startedAt.Unix())
				} else if err := lb.submit(flushCtx, "single", p.sess.startedAt.Unix(), lm); err != nil {
					warnf("final listen flush failed: %v", err)
					// 进程正在退出,没有下一拍重试它了:交给 LB 待重发队列(同 applySubmitOutcome 里会话已结束那一支)。
					if !errors.Is(err, errListenRejected) {
						enqueueLBRetry(p.sess.startedAt.Unix(), lm)
					}
				} else {
					p.recordRecentMacListen(p.sess.meta.Artist, p.sess.meta.Title, p.sess.startedAt.Unix())
				}
				// relay 现在是网页历史主源:退出前放的最后一首也要补进 relay。
				p.pushScrobble(p.sess.meta, p.sess.startedAt.Unix(), "mac")
			}
			// 活路径上已经发出去的 Last.fm 写入(mirrorAsync)活不过紧接着的进程退出,而它们的「已镜像」标记在
			// 发请求之前就落了盘 —— 被截断的那一条从此谁都不会再发。等它们发完。
			//
			// 单独给一段时限,不跟 flushCtx 共用:上面 LB 同步提交慢的时候会把 flushCtx 用光,这里就一毫秒都等不了。
			// 它们在后台是跟上面那几步同时跑的,这段只是收尾;flushCtx 15 秒 + 这 4 秒仍在 launchd 默认 20 秒的
			// 退出宽限之内。
			waitCtx, cancelWait := context.WithTimeout(context.Background(), exitMirrorWait)
			defer cancelWait()
			if n := waitMirrorsInflight(waitCtx); n > 0 {
				log.Printf("lastfm: exiting with %d mirror write(s) still in flight", n)
			}
			return nil
		case <-enrichNotify:
			p.poll() // 后台 enrichment 完成,立刻带完整封面/歌词重推一轮
		case <-ticker.C:
			p.poll()
		case <-appTicker.C:
			if p.app.changed(time.Now()) {
				p.poll()
			}
		case <-appWrites:
			now := time.Now()
			if now.Sub(lastWritePoll) >= appStateMinGap && p.app.changed(now) {
				lastWritePoll = now
				p.poll()
			}
		case r := <-p.submitDoneCh:
			p.applySubmitOutcome(r)
		case r := <-p.announceDoneCh:
			p.applyAnnounceOutcome(r)
		case r := <-p.relayDoneCh:
			p.applyRelayResult(r)
		case r := <-p.lastListenSeedCh:
			p.applyLastListenSeed(r)
		case r := <-p.bridgeForwardDoneCh:
			p.applyBridgeForwardResults(r)
		case r := <-p.bridgeDoneCh:
			p.applyBridgeResult(r)
		}
	}
}
