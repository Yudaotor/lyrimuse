package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ---- 歌词源级熔断 / 退避 ----
//
// 全部歌词源并发、20 秒总截止(lyricSearchDeadline)。某个源整个哑掉(DNS 污染、TLS 挂死、5xx)时,不熔断的话
// 每首歌都要把它等到自己的超时。这里是「某个源连续失败就在接下来一段时间跳过它」的通用层;点状的退避另有
// 网易云按端点分桶的拒绝退避(2 分钟起翻倍、封顶 15 分钟,netease.go)、lb.go 的 429 阶梯、Musixmatch 自己换 token。
//
// 挂在哪:各源函数把所有错误都吞成空结果、不区分"没查到"和"没查成",唯一集中的地方是 doHTTPTracked
// (所有对外请求的统一出口),能拿到网络层错误与状态码,所以失败观察挂在那里,按请求主机归到源
// (lyricSourceForHost);跳过决策挂在 fetchScoredLyricCandidatesStreaming 每个源 goroutine 的开头(planRound)。
//
// 只统计两类失败:http.Client.Do 本身返回错误(DNS/连接/TLS/超时)和 5xx;429 单独按 Retry-After 处理(没给时按连着被限流
// 几次升档,见 observeWith 的 429 那一支)。
// 拿到响应且状态码 < 500 的请求都算一次成功,当场解除冷却(档位另算,见 lyricSourceBreakerSchedule)。
// 4xx 一律不算:那是各源自己的业务判定(网易云 body 里的 405、Musixmatch 的 401 hint=captcha 各自处理,后者由它
// 自己调 noteBlocked,见「反爬拦截」一节)。401/402/403 也不当长期粘性冷却的理由:对没有凭据的源,那样会让它
// 永久缺席、界面还不提示。
//
// 两条护栏(理由见 09 章决策 41):
//   - 连续 2 次失败才开(lyricSourceBreakerTripAfter),不是 1 次:一次网络抖动不该让下一首歌
//     少一个源。网易云一轮最多发 4 个变体,lrclib 一首歌三级查询再加一次 503 重试,一首歌都可能触发。
//   - 被跳过的源记进 lyricSourceRound(经 ctx 传给 enrich.go),落到 lyrics_sources_skipped /
//     决策留痕的 sources_skipped;歌词为空且这一轮有源被跳过时,needsLyricsFirstFill 的补空
//     间隔缩短成 10 分钟,被跳过的源已经不在冷却时 30 秒(只对第一次生效,见 lyricsFillSkippedRetryInterval)。
//
// 被跳过的源在"哪些源应答了"的口径里就是没应答,接上既有的两条机制:needsLyricsRetry 会在 6 小时后重搜
// (最多 3 次),rescoreDecidable 拒绝在当前源缺席时降级。冷却状态在进程内存里,引擎重启归零;search-lyrics
// 这类一次性 CLI 进程从空开始,只读进常驻进程存着的反爬暂停(下面「反爬拦截」一节)。
//
// 冷却到期后下一轮把这个源照常问一遍(不是只放一个试探请求):跳不跳过是按轮决定的(planRound),同源并发的几个请求
// (网易云的歌手变体)要么一起问、要么一起跳,在请求这一层只放一个会让试探那一轮丢掉别的变体。源还没好时白发的是
// 这一轮的请求,每个冷却窗口(最长 5 分钟)一轮。同一个 observe 入口顺手记下的传输层失败分类(本文件最后一节)以
// dns_failed / connect_failed / server_error 三个代码报给弹窗(lyricsourcefailure.go)。

// lyricSourceBreakerSchedule:第 N 次达到触发阈值之后的冷却时长(N 从 0 起),超出表长封顶
// 在最后一档——上限 5 分钟,误熔断的代价有界。
//
// 档位(trips)走到第几档由「离上一次跳闸多久」决定,不由「中间有没有成功过」决定:
// 成功一次当场解除冷却,但档位要连着 lyricSourceBreakerTripsDecay 没再跳闸才归零(成功分支删 state、失败分支跳闸前
// 清 trips,见 observeWith)。
var lyricSourceBreakerSchedule = []time.Duration{
	15 * time.Second, 30 * time.Second, time.Minute, 2 * time.Minute, 5 * time.Minute,
}

const (
	// lyricSourceBreakerTripAfter:连续多少次失败才进入冷却。
	lyricSourceBreakerTripAfter = 2
	// 429 的 Retry-After:没给或解析不出用默认值,给了也封顶,别被一个离谱的头把源关掉一天。
	lyricSourceBreakerRetryAfterDefault = time.Minute
	lyricSourceBreakerRetryAfterMax     = 5 * time.Minute
	// lyricSourceBreakerTripsDecay:离上一次跳闸多久没再跳,才把档位(trips)清零。
	// 档位由时间清零而不是由"拿到一次正常响应"清零,理由见 observeWith 的 default 分支。
	lyricSourceBreakerTripsDecay = 10 * time.Minute
	// lyricSourceEndpointHealthyWindow:同源另一个端点多久之内成功过,这个端点的 5xx 就只算它自己
	// 的问题(交给出站闸的接口熔断),不计入整个源的连续失败。见 observeWith 里 5xx 那一支。
	lyricSourceEndpointHealthyWindow = time.Minute
)

// 不在熔断里、请求却没发出去的三种跳过(lyricSourceRound.skipReason)。paused:对方 503 / 429 之后后台请求暂停中;
// queued:本地限速排不上队,跟这个源好不好无关,近况统计不算它这一轮。
const (
	lyricSourceSkipReasonPaused = "paused"
	lyricSourceSkipReasonQueued = "queued"
	// budget:后台请求用完了这个源的小时额度(sourcebudget.go),同 queued 不算这个源的这一轮。
	lyricSourceSkipReasonBudget = "budget"
)

// lyricSourceShortRetryMax:503 / 429 的 Retry-After 不超过这么久时,对方是在说「等一下再来」,不是这个源坏了:
// 调用方等一下重发那一次(withLyricSourceRetryPending),冷却也不整轮跳过它(planRound)。见 09 章决策 272。
const lyricSourceShortRetryMax = 2 * time.Second

type lyricSourceRetryPendingKey struct{}

// withLyricSourceRetryPending:这次请求回 503 / 429 且 Retry-After 不超过 lyricSourceShortRetryMax 时,调用方会等一下
// 再发一次。这一次不计入熔断,重发那次照常计:一次过载应答加它的重试只算一次失败,不会单独凑够跳闸的两次。
func withLyricSourceRetryPending(ctx context.Context) context.Context {
	return context.WithValue(ctx, lyricSourceRetryPendingKey{}, true)
}

// lyricSourceRetryForgiven:这次应答是不是 withLyricSourceRetryPending 说好了要重发的那种。
func lyricSourceRetryForgiven(ctx context.Context, status int, retryAfter string) bool {
	if pending, _ := ctx.Value(lyricSourceRetryPendingKey{}).(bool); !pending {
		return false
	}
	if status != http.StatusServiceUnavailable && status != http.StatusTooManyRequests {
		return false
	}
	d, ok := retryAfterSeconds(retryAfter)
	return ok && d <= lyricSourceShortRetryMax
}

const (
	lyricSourceCooldownReasonNetwork     = "network"
	lyricSourceCooldownReasonServerError = "http_5xx"
	lyricSourceCooldownReasonRateLimited = "http_429"
	// lyricSourceCooldownReasonBlocked:被对方的反爬拦下(见下面「反爬拦截」一节),不是出错。
	lyricSourceCooldownReasonBlocked = "blocked"
)

// ---- 反爬拦截:按源暂停,15 分钟起翻倍 ----
//
// Musixmatch 拦一个出口 IP 时,从这个出口来的每个数据请求都回 HTTP 200 + `status_code:401, hint:"captcha"`,两台主机
// 都一样,刚换的 token 也照样被拒。换个出口(改走系统代理、切 Clash 节点)照常能用,所以 musixmatch.go 先换出口,
// 换不了才走到这里的暂停(musixmatchreroute.go)。上面那套熔断看的是 HTTP 层,这种应答算成功、一档都不跳 ——
// 不单独处理的话每一轮照发、每一轮被拒,整段时间一首词都给不出,还可能把封禁拖得更久。认得出这种应答的
// 只有源自己(musixmatch.go 解应答头),由它调 noteBlocked。
//
// 跟上面的冷却分开存,两条理由:① 拦截应答本身是 HTTP 200,observeWith 的 default 分支会把同一个源的冷却
// 当场撤掉;② 上面的档位离上次跳闸 10 分钟就归零,而这里一档就 15 分钟,放在一起永远升不上去。
// 所以这份状态只认两个入口:noteBlocked(又被拦了)和 clearBlocked(数据接口正经答了一次 200)。
// 冷却期内再被拦(之前在飞的请求)不升档、不续期,同上面那条「余震」规矩。
var lyricSourceBlockSchedule = []time.Duration{
	15 * time.Minute, 30 * time.Minute, time.Hour, 2 * time.Hour, 4 * time.Hour,
}

type lyricSourceBlockState struct {
	until time.Time
	// tier:已经被拦过几轮,下一次被拦取第几档。只由 clearBlocked 归零。
	tier int
}

// 暂停状态存盘:常驻进程在 run() 开头调 enableLyricSourceBlockPersistence,读回上次存的、之后每次变化都写回。
// 别只放内存:引擎一重启就从 15 分钟那档重来,装机频繁时每次启动后的第一个请求都去撞一下,一小时能撞六次,
// 而对方的反爬看的正是请求频率。手动搜索的一次性子命令只读不写(loadLyricSourceBlocksReadOnly):暂停期里它也不去碰,
// 存盘那份归常驻进程。单测都不开:单测进程要是读到本机真实的「被拦」记录,Musixmatch 的测试会在被拦的机器上莫名其妙地失败。
const (
	lyricSourceBlocksFileName = "lyrimuse-source-blocks.json"
	// lyricSourceBlocksForgetAfter:暂停到期这么久还没再被拦(引擎一直没跑),读回时整条丢掉、档位从头算。
	lyricSourceBlocksForgetAfter = 24 * time.Hour
)

type lyricSourceBlockRecord struct {
	Until int64 `json:"until"`
	Tier  int   `json:"tier"`
}

// enableLyricSourceBlockPersistence:给常驻进程那一份熔断器开存盘,并读回上次存的暂停状态。
func enableLyricSourceBlockPersistence() {
	path := configFilePath(lyricSourceBlocksFileName)
	if path == lyricSourceBlocksFileName {
		return
	}
	sharedLyricSourceBreaker().loadBlocks(path)
}

// loadLyricSourceBlocksReadOnly:一次性子命令(手动搜索)读回常驻进程存着的暂停状态,自己这边的变化不写回。
func loadLyricSourceBlocksReadOnly(path string) {
	sharedLyricSourceBreaker().loadBlocksFrom(path, false)
}

// loadBlocks 读回 path 里的暂停状态(到期超过 lyricSourceBlocksForgetAfter 的丢掉),此后变化都写回 path。
func (b *lyricSourceBreaker) loadBlocks(path string) {
	b.loadBlocksFrom(path, true)
}

// loadBlocksFrom:读回 path 里的暂停状态;persist 时此后的变化都写回 path。
func (b *lyricSourceBreaker) loadBlocksFrom(path string, persist bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if persist {
		b.blocksPath = path
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return
	}
	var saved map[string]lyricSourceBlockRecord
	if json.Unmarshal(raw, &saved) != nil {
		log.Printf("lyrics: %s unreadable, ignoring it", path)
		return
	}
	now := b.now()
	for source, r := range saved {
		until := time.Unix(r.Until, 0)
		if now.Sub(until) > lyricSourceBlocksForgetAfter || r.Tier <= 0 {
			continue
		}
		b.blocked[source] = &lyricSourceBlockState{until: until, tier: r.Tier}
		if until.After(now) {
			log.Printf("lyrics: source %s still paused after its anti-bot block for %s (trip=%d)",
				source, until.Sub(now).Round(time.Second), r.Tier)
		}
	}
}

// saveBlocksLocked:开了存盘就把当前暂停状态写回去。调用方持有 b.mu。
func (b *lyricSourceBreaker) saveBlocksLocked() {
	if b.blocksPath == "" {
		return
	}
	saved := map[string]lyricSourceBlockRecord{}
	for source, bs := range b.blocked {
		saved[source] = lyricSourceBlockRecord{Until: bs.until.Unix(), Tier: bs.tier}
	}
	raw, err := json.Marshal(saved)
	if err == nil {
		err = writeFileAtomic(b.blocksPath, raw)
	}
	if err != nil {
		log.Printf("lyrics: saving anti-bot pauses to %s: %v", b.blocksPath, err)
	}
}

type lyricSourceBreakerState struct {
	until       time.Time
	consecutive int
	// trips:这个源熔断过几轮(不是失败过几个请求)。冷却档位按它取,见 observeWith。
	// 归零看的是离 lastTrip 多久,不是"中间有没有拿到过一次正常响应"。
	trips int
	// lastTrip:最近一次跳闸的时刻,只用来让 trips 随时间衰减(见 observeWith 的失败分支与 default 分支)。
	lastTrip time.Time
	reason   string
	// rateLimits / lastRateLimited:没带 Retry-After 的 429 连着来了几次、最近一次在什么时候。默认停的时长按它翻倍,
	// 跟 trips 一样离上一次 lyricSourceBreakerTripsDecay 没再来才归零。
	rateLimits      int
	lastRateLimited time.Time
}

type lyricSourceBreaker struct {
	mu    sync.Mutex
	now   func() time.Time
	state map[string]*lyricSourceBreakerState
	// transport:按源累计的传输层结局(本文件最后一节「传输层失败分类」)。跟 state 分开放:
	// state 在成功时会被整个删掉,而"这个源拿到过响应"这个事实恰恰要在成功之后留下来。
	transport map[string]*lyricSourceTransportState
	// endpointOK:源 到 端点键(guardEndpointKey)到 最近一次拿到非 5xx 响应的时刻。
	endpointOK map[string]map[string]time.Time
	// blocked:被反爬拦下的源,见上面「反爬拦截」一节。
	blocked map[string]*lyricSourceBlockState
	// blocksPath:暂停状态存在哪;空 = 只放内存(一次性子命令只读、单测不读)。见 enableLyricSourceBlockPersistence。
	blocksPath string
}

func newLyricSourceBreaker(now func() time.Time) *lyricSourceBreaker {
	return &lyricSourceBreaker{
		now:        now,
		state:      map[string]*lyricSourceBreakerState{},
		transport:  map[string]*lyricSourceTransportState{},
		endpointOK: map[string]map[string]time.Time{},
		blocked:    map[string]*lyricSourceBlockState{},
	}
}

// noteBlocked:source 的应答说这台机器被它的反爬拦下了。不在暂停期内就按档位暂停并升一档,返回 true;
// 已经在暂停期内(之前在飞的请求带回来的)什么都不做。
func (b *lyricSourceBreaker) noteBlocked(source string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	bs := b.blocked[source]
	if bs == nil {
		bs = &lyricSourceBlockState{}
		b.blocked[source] = bs
	}
	if bs.until.After(now) {
		return false
	}
	idx := min(bs.tier, len(lyricSourceBlockSchedule)-1)
	bs.tier++
	bs.until = now.Add(lyricSourceBlockSchedule[idx])
	log.Printf("lyrics: source %s blocked by its anti-bot check, pausing it for %s (reason=%s trip=%d)",
		source, lyricSourceBlockSchedule[idx], lyricSourceCooldownReasonBlocked, bs.tier)
	b.saveBlocksLocked()
	noteLyricSourceTrip(source, lyricSourceCooldownReasonBlocked)
	return true
}

// clearBlocked:source 的数据接口正经答了一次,撤掉暂停、档位归零。
func (b *lyricSourceBreaker) clearBlocked(source string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	bs := b.blocked[source]
	if bs == nil {
		return
	}
	delete(b.blocked, source)
	b.saveBlocksLocked()
	log.Printf("lyrics: source %s answered normally again, anti-bot pause cleared (trips=%d)", source, bs.tier)
}

// blockedFor:source 还要暂停多久;没在暂停期内返回 0, false。
func (b *lyricSourceBreaker) blockedFor(source string) (time.Duration, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.blockedForLocked(source, b.now())
}

func (b *lyricSourceBreaker) blockedForLocked(source string, now time.Time) (time.Duration, bool) {
	bs := b.blocked[source]
	if bs == nil || !bs.until.After(now) {
		return 0, false
	}
	return bs.until.Sub(now), true
}

// cooldownReason:source 这会儿为什么不能问(lyricSourceCooldownReason*);能问返回空串。反爬暂停排在前面:
// 它更长,也更说明问题。给各源近况统计记「被跳过的那几轮是什么原因」用。
func (b *lyricSourceBreaker) cooldownReason(source string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	if _, ok := b.blockedForLocked(source, now); ok {
		return lyricSourceCooldownReasonBlocked
	}
	if st := b.state[source]; st != nil && st.until.After(now) {
		return st.reason
	}
	return ""
}

// lyricSourceBreakerSharedPtr 是常驻采集器用的那一份(进程级)。经 sharedLyricSourceBreaker / setSharedLyricSourceBreaker 读写,
// 原子指针的理由同 hostGuardSharedPtr。
var lyricSourceBreakerSharedPtr atomic.Pointer[lyricSourceBreaker]

func init() { lyricSourceBreakerSharedPtr.Store(newLyricSourceBreaker(time.Now)) }

func sharedLyricSourceBreaker() *lyricSourceBreaker { return lyricSourceBreakerSharedPtr.Load() }

// setSharedLyricSourceBreaker 只给单测换掉整份熔断器。
func setSharedLyricSourceBreaker(b *lyricSourceBreaker) { lyricSourceBreakerSharedPtr.Store(b) }

// lyricSourceForHost 把请求主机归到歌词源名(lyricSourceNames 里的写法);不是歌词源的主机
// (Last.fm / ListenBrainz / MusicBrainz / iTunes / DoH …)返回空串。主机名单来自各源文件里
// 实际请求的域名(grep 核对);raw.githubusercontent.com 全仓只有 amll 在用。
func lyricSourceForHost(host string) string {
	h := strings.ToLower(strings.TrimSpace(host))
	if strings.Contains(h, ":") {
		if hostOnly, _, err := net.SplitHostPort(h); err == nil {
			h = hostOnly
		}
	}
	switch {
	case h == "music.163.com" || strings.HasSuffix(h, ".163.com"):
		return "netease"
	case h == "qq.com" || strings.HasSuffix(h, ".qq.com"):
		return "qq"
	case h == "kugou.com" || strings.HasSuffix(h, ".kugou.com"):
		return "kugou"
	case h == "lrclib.net" || strings.HasSuffix(h, ".lrclib.net"):
		return "lrclib"
	case h == "musixmatch.com" || strings.HasSuffix(h, ".musixmatch.com"):
		return "musixmatch"
	case h == "raw.githubusercontent.com" || h == "cdn.jsdelivr.net" || h == "fastly.jsdelivr.net" || h == "api.amll.dev":
		// jsDelivr 两个是 amll-ttml-db 的镜像(sourcefallback.go 的 amllBases),api.amll.dev 是 AMLL 官方接口(amllttml.go 的
		// amllAPIBase),全仓只有 amll 在用。
		return "amll"
	case h == "music.youtube.com" || h == "youtubei.googleapis.com" || h == "www.youtube.com":
		// 后两个是同一套 InnerTube 的备用主机(sourcefallback.go 的 ytmusicAPIBases)。
		return "lyricfind"
	case h == "kuwo.cn" || strings.HasSuffix(h, ".kuwo.cn"):
		return "kuwo"
	case h == "migu.cn" || strings.HasSuffix(h, ".migu.cn"):
		return "migu" // 搜索 pd.musicapp.migu.cn、歌词文件 d.musicapp.migu.cn 都归这一源
	case h == "deezer.com" || strings.HasSuffix(h, ".deezer.com"):
		return "deezer" // 搜索 api.deezer.com、取词 www.deezer.com 都归这一源
	case h == "amp-api.music.apple.com" || h == "amp-api-edge.music.apple.com" || h == "api.music.apple.com":
		// Apple Music 的 catalog API —— applemusic 这个歌词源真正发请求的地方。
		//
		// 只认这三个主机(主用加搜索、取词各一个备用,见 sourcefallback.go),别扩成 `*.apple.com`,那会把另外两个用途完全不同的主机
		// 卷进来、让它们的故障去停掉一个能出歌词的源:
		//   - itunes.apple.com:公开的目录检索(专辑提示/封面/标题反查/目录 id),跟歌词
		//     正文无关,而且被限流得最狠(实测 49.8% 失败)。它有自己的端点级退避,
		//     见 apple.go 的 itunesSearchCoolingDown。
		//   - music.apple.com:抓 developer token 的 web origin。它失败意味着"没凭据"
		//     (applemusic_not_connected),不是"源坏了" —— 那种情况 resolveApplemusicLyric
		//     在发请求之前就安静返回空了,本来也轮不到熔断。
		//
		// 不在这张表里的源,observe 拿到空源名直接返回,失败一次都不记:新加歌词源别漏登记它的主机。
		return "applemusic"
	case h == sodaSeoTrackHost || h == sodaSearchHost:
		// 汽水的两个主机,取词(seo_track)和搜索两个端点都在上面,互为备用(sourcefallback.go)。
		// beta-luna 只认这一个主机,别扩成 `*.douyin.com`:那个域名下还有抖音自己的一大
		// 堆服务,跟歌词无关的故障会连带停掉这个源。分享页的 music.douyin.com 同理不进来(见 soda.go
		// sodaSharePageURL)。
		return "soda"
	case h == "apis.naver.com":
		// VIBE 的搜索和取词都在这个主机的 /vibeWeb/ 下(vibe.go)。全仓只有这一源请求它;封面图在 musicmeta-phinf.pstatic.net,
		// 跟歌词无关,不进来。
		return "vibe"
	case h == "app.genie.co.kr" || h == "dn.genie.co.kr":
		// Genie 的搜索在 app.genie.co.kr、取词在 dn.genie.co.kr(genie.go)。全仓只有这一源请求它们;封面图在
		// image.genie.co.kr,跟歌词无关,不进来。
		return "genie"
	case h == "p1.petitlyrics.com" || h == "p0.petitlyrics.com" || h == "on.petitlyrics.com":
		// PetitLyrics 轮换着用的三个主机(petitlyrics.go 的 petitClients),全仓只有这一源请求它们。
		return "petitlyrics"
	}
	return ""
}

// observe 记录一次对外请求的结果。err 是 http.Client.Do 的返回错误(nil = 拿到了响应),
// status 是响应状态码(err != nil 时忽略),retryAfter 是响应的 Retry-After 头原文(可空)。
// 没有 DNS 轨迹的调用方(测试、以及日后别的入口)用这个;doHTTPTracked 走 observeTraced。
func (b *lyricSourceBreaker) observe(host string, err error, status int, retryAfter string) {
	b.observeWith(host, "", err, status, retryAfter, transportTrace{})
}

// observeWith 的 endpoint 是端点键(guardEndpointKey),空串表示不知道是哪个端点、按整个源算。
func (b *lyricSourceBreaker) observeWith(host, endpoint string, err error, status int, retryAfter string, tr transportTrace) {
	source := lyricSourceForHost(host)
	if source == "" {
		return
	}
	// 用户主动取消(enrichcancel.go)会让全部在飞的请求同时以 context.Canceled 失败——
	// 那是用户的动作,不是源的毛病,一次都不算。
	if err != nil && errors.Is(err, context.Canceled) {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.noteTransport(source, err, status, tr)
	now := b.now()
	st := b.state[source]
	switch {
	case err == nil && status >= 500 && b.otherEndpointHealthyLocked(source, endpoint, now):
		// 同源另一个端点刚成功过:这是一个端点单独挂了(同主机别的接口照常),不是整个源坏了。
		// 按源计数的话,一个一直 500 的端点会反复把整个源停掉,连带它健康的端点和备用链一起
		// 被跳过;这种由出站闸的接口熔断按端点处理(hostguard.go)。传输层失败不走这一支:
		// 连不上是整个源(或网络)的事。
		return
	case err != nil || status >= 500:
		reason := lyricSourceCooldownReasonNetwork
		if err == nil {
			reason = lyricSourceCooldownReasonServerError
		}
		if st == nil {
			st = &lyricSourceBreakerState{}
			b.state[source] = st
		}
		st.consecutive++
		if st.consecutive < lyricSourceBreakerTripAfter {
			return
		}
		// 已经在冷却里就到此为止:不升档、也不续期。档位按熔断了几轮(trips)取,不按失败请求数:一轮搜索里同一个源
		// 要发好几个请求(网易云 4 个歌手别名变体、QQ 的 smartbox + client_search),源整个挂掉时它们同一瞬间一起失败,
		// 按请求数升档的话一次抖动就走完整个阶梯。冷却窗口内的余震不是新证据,也不续期(续期会让"上限 5 分钟"变成
		// "只要还在失败就永远冷却")。consecutive 只管"连续两次才开"那道门槛。见 09 章决策 41。
		if st.until.After(now) {
			return
		}
		// 档位衰减在这里也要做,不能只靠成功分支:一直失败、中间没有一次正常应答的源(断网、主机被打掉)走不到那一支,
		// 隔了几个小时的下一次跳闸会接着上回的档位。离上次跳闸满 lyricSourceBreakerTripsDecay 就从第一档重新算,
		// 两条分支同一个口径。限流的连续次数在 429 那一支自己按 lastRateLimited 衰减。见 09 章决策 41、301。
		if !st.lastTrip.IsZero() && now.Sub(st.lastTrip) >= lyricSourceBreakerTripsDecay {
			st.trips = 0
		}
		idx := st.trips
		if idx >= len(lyricSourceBreakerSchedule) {
			idx = len(lyricSourceBreakerSchedule) - 1
		}
		st.trips++
		st.lastTrip = now
		st.until = now.Add(lyricSourceBreakerSchedule[idx])
		st.reason = reason
		log.Printf("lyrics: source %s cooling down %s (reason=%s trip=%d consecutive=%d host=%s)",
			source, lyricSourceBreakerSchedule[idx], reason, st.trips, st.consecutive, host)
		noteLyricSourceTrip(source, reason)
	case status == http.StatusTooManyRequests:
		if st == nil {
			st = &lyricSourceBreakerState{}
			b.state[source] = st
		}
		d, given := lyricSourceRetryAfter(retryAfter)
		// 对方没说要等多久:按连着被限流几次翻倍(1 → 2 → 4 → 封顶 5 分钟),不然持续限流时每 60 秒撞一次。
		// 还在上一个限流窗口里的(同一批在途请求一起被拒)是余震,不升档。
		if !given && !(st.until.After(now) && st.reason == lyricSourceCooldownReasonRateLimited) {
			if st.lastRateLimited.IsZero() || now.Sub(st.lastRateLimited) >= lyricSourceBreakerTripsDecay {
				st.rateLimits = 0
			}
			d = lyricSourceBreakerRetryAfterMax
			if shift := min(st.rateLimits, 3); lyricSourceBreakerRetryAfterDefault<<shift < d {
				d = lyricSourceBreakerRetryAfterDefault << shift
			}
			st.rateLimits++
			st.lastRateLimited = now
		}
		// 只往后延、不往前缩:正在一段更长的冷却里(5xx / 断网升上去的档)时,一次 429 的 Retry-After
		// 不该把它缩短成 60 秒。
		if until := now.Add(d); until.After(st.until) {
			st.until = until
			st.reason = lyricSourceCooldownReasonRateLimited
			log.Printf("lyrics: source %s cooling down %s (reason=%s host=%s)", source, d, st.reason, host)
			noteLyricSourceTrip(source, st.reason)
		}
	default:
		if endpoint != "" {
			m := b.endpointOK[source]
			if m == nil {
				m = map[string]time.Time{}
				b.endpointOK[source] = m
			}
			m[endpoint] = now
		}
		if st == nil {
			return
		}
		st.consecutive = 0
		// 限流窗口不因为一次正常应答就撤:服务端用 Retry-After 说了要等多久,同一轮并发的另一个请求
		// 刚好答了 200 不代表限流过去了(网易云一轮四个变体并发,一个吃 429、一个 200 是常态)。
		if st.until.After(now) && st.reason != lyricSourceCooldownReasonRateLimited {
			log.Printf("lyrics: source %s recovered, cooldown cleared (reason=%s)", source, st.reason)
			st.until = time.Time{}
			st.reason = ""
		}
		// 档位(trips)不跟着这一次正常响应归零,要连着 lyricSourceBreakerTripsDecay 没再跳闸才归零:有的源正常应答里
		// 本来就混着失败(lrclib 用 503 限流,404 和 200 又是它最常见的应答),一次 200/404 就清档的话阶梯永远升不上去,
		// 冷却一过就再撞一次限流。一次正常响应只证明这会儿能通,不证明限流已经过去。封顶仍是 5 分钟。见 09 章决策 41。
		// 还在上面留着的限流窗口里就不抹:整条 state 删掉等于把那个窗口一起撤了。限流的连续次数同理要留到衰减完。
		recent := func(t time.Time) bool { return !t.IsZero() && now.Sub(t) < lyricSourceBreakerTripsDecay }
		if !recent(st.lastTrip) && !recent(st.lastRateLimited) && !st.until.After(now) {
			delete(b.state, source)
		}
	}
}

// parseLyricSourceRetryAfter 只认「秒数」写法;HTTP-date 写法(RFC 7231 允许)用默认值——
// 各源里没见过谁发日期形态的 Retry-After,不值得为它引入日期解析。
func parseLyricSourceRetryAfter(v string) time.Duration {
	d, _ := lyricSourceRetryAfter(v)
	return d
}

// lyricSourceRetryAfter 同 parseLyricSourceRetryAfter,另报对方有没有给出能用的秒数(没给时返回的是默认值)。
// 先比秒数再乘:离谱的大数乘成纳秒会溢出成负数,等于不停。
func lyricSourceRetryAfter(v string) (time.Duration, bool) {
	secs, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || secs <= 0 {
		return lyricSourceBreakerRetryAfterDefault, false
	}
	if secs >= int(lyricSourceBreakerRetryAfterMax/time.Second) {
		return lyricSourceBreakerRetryAfterMax, true
	}
	return time.Duration(secs) * time.Second, true
}

// lyricSourceRoundPlan:这一轮该跳过的源 → 剩余冷却时长。
type lyricSourceRoundPlan map[string]time.Duration

// planRound 在一轮全源搜索起跑前算一次"谁在冷却中",在冷却的都跳过,全都在冷却时也一样。断网时别让熔断把它伪装成
// "这首歌没歌词"由别处管:这一轮一个请求都没成功时不认定查无(lyricsRoundConfirmsNoResult),「网络连接失败」也不会被
// 这种轮次撤掉(noteLyricsRoundNetwork)。从前这里另有一道「启用的源全部在冷却时谁也不跳过」:amll 要等网易云 / QQ 的
// id 才发请求、从不进冷却,默认设置下凑不满,从来不触发;真触发时又正好在断网那一刻把冷却中的源全打一遍。见 09 章决策 301。
// 未启用的源在不在名单里无所谓——fetchScoredLyricCandidatesStreaming 对关掉的源直接跳过、根本不起请求(enrich.go
// lyricSourceSkipFor),这里只管冷却。
func (b *lyricSourceBreaker) planRound(sources []string) lyricSourceRoundPlan {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	plan := lyricSourceRoundPlan{}
	for _, s := range sources {
		var left time.Duration
		// 只剩 lyricSourceShortRetryMax 以内的限流窗口不整轮跳过:一轮最长要跑 20 秒,对方只让等 1 秒。
		if st := b.state[s]; st != nil && st.until.After(now) &&
			!(st.reason == lyricSourceCooldownReasonRateLimited && st.until.Sub(now) <= lyricSourceShortRetryMax) {
			left = st.until.Sub(now)
		}
		if d, ok := b.blockedForLocked(s, now); ok && d > left {
			left = d
		}
		if left > 0 {
			plan[s] = left
		}
	}
	if len(plan) == 0 {
		return nil
	}
	return plan
}

// anyLyricSourceCooling 回答"这些源里还有没有在冷却中的"。
//
// 给 needsLyricsFirstFill 用:上一轮因熔断被跳过的那些源要是都不冷却了,那条"补空歌词"
// 就不必再干等满 10 分钟(见那边的注释)。写成包级变量而不是直接调
// sharedLyricSourceBreaker(),是为了让 enrich 侧的单测能把它换掉——熔断状态在进程内存里,
// 测试不该为了跑一条节流判定去伪造一个全局熔断器。
var anyLyricSourceCooling = func(sources []string) bool {
	for _, s := range sources {
		if _, cooling := sharedLyricSourceBreaker().coolingDown(s); cooling {
			return true
		}
	}
	return false
}

// lyricSourceCooldownLeft:source 还要冷却多久(反爬暂停也算),不在冷却返回 false。写成包级变量给单测替换。
var lyricSourceCooldownLeft = func(source string) (time.Duration, bool) {
	return sharedLyricSourceBreaker().coolingDown(source)
}

// lyricSourcesSkippedForRetry 从这一轮跳过的源里挑出写进条目 LyricsSourcesSkipped 的那几个:剩余冷却超过
// lyricsFillSkippedRetryInterval 的不留。这份名单说的是「这一轮没搜完整,补搜马上会来」:App 据此不下「暂无歌词」
// (EnrichCacheLyrics.searchIncomplete),needsLyricsFirstFill 据此提早补搜。决策记录里的跳过名单照记全部,
// 别把它也换成这一份。见 09 章决策 204。
func lyricSourcesSkippedForRetry(skipped []string) []string {
	var out []string
	for _, s := range skipped {
		if left, cooling := lyricSourceCooldownLeft(s); cooling && left > lyricsFillSkippedRetryInterval {
			continue
		}
		out = append(out, s)
	}
	return out
}

// coolingDown 只读地回答某个源现在是不是在冷却中(反爬暂停也算),给诊断/测试用。
func (b *lyricSourceBreaker) coolingDown(source string) (time.Duration, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	var left time.Duration
	if st := b.state[source]; st != nil && st.until.After(now) {
		left = st.until.Sub(now)
	}
	if d, ok := b.blockedForLocked(source, now); ok && d > left {
		left = d
	}
	return left, left > 0
}

// ---- 把"这一轮跳过了谁"从 fetchScoredLyricCandidatesStreaming 传回给写缓存的那几层 ----
//
// 用 context 值而不是改返回值:fetchScoredLyricCandidatesStreaming 在 scoredLyricCandidatesStreaming
// 里为歌手别名 / 标题反查会被调最多 4 次,再往上还有三层调用链(retryLyricsUpgrade /
// rescoreLyrics / resolveTrackEnrichment),逐层加返回值要改六处签名却只为传一份名单;
// 挂在 ctx 上,只有真关心的三个写缓存点各拿一次。没挂(search-lyrics CLI)就什么都不记。

type lyricSourceRound struct {
	mu      sync.Mutex
	skipped map[string]bool
	// skipReason:跳过的那一刻记下的原因(lyricSourceCooldownReason* / lyricSourceSkipReasonPaused / Queued),
	// 只给各源近况统计用。事后再问熔断器的话,后台暂停和本地排队那几次问不出原因。
	skipReason map[string]string
	// reached:这一轮拿到过正常应答(状态码 < 500 且不是 429,404 也算)的源,由 doHTTPTracked 记。
	// 一个都没有 = 这一轮没连上任何歌词源(断网、DNS 抽风、全被熔断),结论不作数,见 reachedAny。
	reached map[string]bool
	// parent:外层的 round(补空扫描套在 retryLyricsUpgrade / rescoreLyrics 外面那一层)。
	// reached 往上传,外层才看得见里层这一轮连没连上;skipped 不传,那是写缓存的那一层自己的账。
	parent *lyricSourceRound
	// enabled:开搜那一刻开着的联网歌词源。在开搜时取、不在写缓存时取:一轮要搜十几秒,用户在这期间新开的源
	// 这一轮没问到,记进名单就不会再按它补搜。
	enabled []string
}

type lyricSourceRoundKey struct{}

func withLyricSourceRound(ctx context.Context) (context.Context, *lyricSourceRound) {
	r := &lyricSourceRound{skipped: map[string]bool{}, skipReason: map[string]string{}, reached: map[string]bool{},
		parent: lyricSourceRoundFrom(ctx), enabled: enabledNetworkLyricSources()}
	return context.WithValue(ctx, lyricSourceRoundKey{}, r), r
}

// enabledSources:nil 接收者(CLI 路径没有 round)返回 nil。
func (r *lyricSourceRound) enabledSources() []string {
	if r == nil {
		return nil
	}
	return r.enabled
}

func lyricSourceRoundFrom(ctx context.Context) *lyricSourceRound {
	if ctx == nil {
		return nil
	}
	r, _ := ctx.Value(lyricSourceRoundKey{}).(*lyricSourceRound)
	return r
}

// ---- 「这一轮只查这些源」(给别名轮用) ----
//
// 跟上面 lyricSourceRound 同一个理由走 ctx:fetchScoredLyricCandidatesStreaming 的签名不动。
// nil 名单 = 不限制(所有调用方的默认);非 nil 时名单外的源在 skipSource 里静默跳过。

type lyricSourceOnlyKey struct{}

// withLyricSourceOnly:sources 为空切片 / nil 时返回原 ctx(不限制)。
func withLyricSourceOnly(ctx context.Context, sources []string) context.Context {
	if len(sources) == 0 {
		return ctx
	}
	set := make(map[string]bool, len(sources))
	for _, s := range sources {
		set[s] = true
	}
	return context.WithValue(ctx, lyricSourceOnlyKey{}, set)
}

// lyricSourceOnlyFrom:没挂 / ctx 为 nil 时返回 nil(不限制)。
func lyricSourceOnlyFrom(ctx context.Context) map[string]bool {
	if ctx == nil {
		return nil
	}
	set, _ := ctx.Value(lyricSourceOnlyKey{}).(map[string]bool)
	return set
}

// markSkipped / skippedSources 对 nil 接收者都是安全的空操作(CLI 路径没有 round)。
func (r *lyricSourceRound) markSkipped(source string) {
	r.markSkippedBecause(source, "")
}

// markSkippedBecause 同 markSkipped,顺带记下原因;同一轮里先记下的原因不被后来的空原因盖掉。
func (r *lyricSourceRound) markSkippedBecause(source, reason string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	r.skipped[source] = true
	if reason != "" && r.skipReason[source] == "" {
		r.skipReason[source] = reason
	}
	r.mu.Unlock()
}

// statsSkips:给各源近况统计的「这一轮没问到」名单,源 → 跳过原因(说不出时为空)。这一轮拿到过它正常应答的
// 不算:别名轮、补查那几次被跳过时,原名那一轮其实问过它了,整轮记成没问会把跳过率算高(见 09 章决策 272)。
func (r *lyricSourceRound) statsSkips() map[string]string {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string]string{}
	for s := range r.skipped {
		if !r.reached[s] {
			out[s] = r.skipReason[s]
		}
	}
	return out
}

// markReached / reachedAny 同样对 nil 接收者安全。
func (r *lyricSourceRound) markReached(source string) {
	for ; r != nil; r = r.parent {
		r.mu.Lock()
		r.reached[source] = true
		r.mu.Unlock()
	}
}

func (r *lyricSourceRound) reachedAny() bool {
	if r == nil {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.reached) > 0
}

// reachedSource:这一轮 source 拿到过正常应答(口径同 reached)。
func (r *lyricSourceRound) reachedSource(source string) bool {
	if r == nil {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.reached[source]
}

func (r *lyricSourceRound) skippedSources() []string {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.skipped) == 0 {
		return nil
	}
	out := make([]string, 0, len(r.skipped))
	for s := range r.skipped {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

// ---- 传输层失败分类:给「歌词源可用情况」按源报"为什么连不上" ----
//
// 判据是这个源在本进程里有没有拿到过任何一个 HTTP 响应(状态码 < 500 即算:4xx 也是服务器在说话,
// 404 = 没这首、403 = 反爬,跟上面熔断的口径一致):一次都没有、且失败过 → 报最多见的那一类失败
// (dns_failed / connect_failed / server_error,见 lyricsourcefailure.go)。拿到过响应的源不报:
// "响应了但没这首歌"跟"连不上"必须分开,否则系统 DNS 对歌词源不答时弹窗会把"连不上"说成"没收录"
// (见 09 章「六个源死在 DNS 这一步」)。
//
// DNS 失败不能只靠 errors.As(err, *net.DNSError)认:各源的 client 都设了 http.Client.Timeout(4–8 秒),DNS 挂住
// 不答(而不是秒答 NXDOMAIN)时是这个 Timeout 先到,Transport.getConn 直接返回 ctx.Err()、丢掉拨号 goroutine 里
// 那条带 DNSError 的错误,Client.do 再把它整体换成 *http.timeoutError(纯字符串,没有 Unwrap),只看错误链会把
// "DNS 不答"归成 connect_failed。所以 doHTTPTracked 给每个请求挂 httptrace.ClientTrace 记 DNSStart / DNSDone
// (net 包在系统解析器与纯 Go 解析器两条路上都会调这两个钩子,ctx 被取消时 DNSDone 也会带 err 调一次),分类时
// 先看轨迹:DNS 阶段开始了却没结束、或结束时带错 → dns_failed;错误链里有 DNSError → dns_failed;其余才是
// connect_failed。复用连接(没有 DNS 阶段)拿不到轨迹,退回错误链判定;歌词源走 DoH 时轨迹由 lyricsourcedial.go
// 手动补。musixmatch 的 DoH 拨号(dohDialContext)没有 DNS 钩子,退回错误链判定:它用 %w 包住了系统解析的
// NXDOMAIN,"DoH 解析成功但拨不通"会被归成 dns_failed,由 musixmatch_direct_blocked 这个具体代码盖住。
//
// 两处消费:一次性 CLI(searchcli.go 的 lyricSourceFailureReasons)报失败原因;常驻引擎的别名重查
// (enrich.go lyricSourcesWorthRetry)剔掉连不上的源。常驻引擎里这份是进程生命周期累计的、不按轮清零,
// 跟 xxxLastFailureReasonNow 同一条注意事项 —— 一个源进程里从没拿到过响应、失败过一次,就一直不进别名重查;
// search-lyrics 每次都是全新进程,读到的就是这一次搜索本身的结局。

type lyricSourceTransportState struct {
	responded bool           // 拿到过 < 500 的响应
	failures  map[string]int // 失败代码 → 次数
}

// transportTrace 是 doHTTPTracked 从 httptrace 钩子里收来的 DNS 阶段轨迹。零值 = 没有观察到
// DNS 阶段(复用连接 / 自定义拨号 / 没挂钩子),分类退回只看错误链。
type transportTrace struct {
	dnsStarted bool
	dnsDone    bool
	dnsErr     error
}

// classifyLyricSourceTransportFailure 把一次请求的结局归到三个通用代码之一;拿到 < 500 的响应
// 返回空串。err 是 http.Client.Do 的返回值,status 只在 err == nil 时有意义,tr 见 transportTrace。
func classifyLyricSourceTransportFailure(err error, status int, tr transportTrace) string {
	if err == nil {
		if status >= 500 {
			return lyricFailureReasonServerError
		}
		return ""
	}
	// 先看轨迹:DNS 阶段没走完 / 走完了但带错,不管错误链被 http.Client 换成了什么。
	if tr.dnsStarted && (!tr.dnsDone || tr.dnsErr != nil) {
		return lyricFailureReasonDNSFailed
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return lyricFailureReasonDNSFailed
	}
	return lyricFailureReasonConnectFailed
}

// observeTraced 是 observe 的带轨迹、带端点键的版本,doHTTPTracked 用它;observe 本身等价于零轨迹、
// 不知道端点。
func (b *lyricSourceBreaker) observeTraced(host, endpoint string, err error, status int, retryAfter string, tr transportTrace) {
	b.observeWith(host, endpoint, err, status, retryAfter, tr)
}

// otherEndpointHealthyLocked:同源除 endpoint 以外的端点,有没有在 lyricSourceEndpointHealthyWindow
// 之内成功过。endpoint 为空时一律 false(按整个源算)。调用方持有 b.mu。
func (b *lyricSourceBreaker) otherEndpointHealthyLocked(source, endpoint string, now time.Time) bool {
	if endpoint == "" {
		return false
	}
	for k, at := range b.endpointOK[source] {
		if k != endpoint && now.Sub(at) < lyricSourceEndpointHealthyWindow {
			return true
		}
	}
	return false
}

// noteTransport 在 observeWith 里(已持锁)记一笔。context.Canceled 已在那边开头被过滤。
func (b *lyricSourceBreaker) noteTransport(source string, err error, status int, tr transportTrace) {
	ts := b.transport[source]
	if ts == nil {
		ts = &lyricSourceTransportState{failures: map[string]int{}}
		b.transport[source] = ts
	}
	code := classifyLyricSourceTransportFailure(err, status, tr)
	if code == "" {
		ts.responded = true
		return
	}
	ts.failures[code]++
}

// lyricSourceTransportFailureOrder:并列时的取舍顺序。DNS 失败是最靠前、最能解释其它现象的那
// 一层(解析都不通,别的更谈不上),其次是连不上,最后才是"连上了但服务器报错"。
// 这份顺序也是 Swift 侧空状态分组的顺序(LyricsSearchSheet.transportFailureCodes,那边多一个
// 只由 searchcli 派生、不经这里的 upstream_unreachable),lyricsourcefailure_test.go 钉着两边一致。
var lyricSourceTransportFailureOrder = []string{
	lyricFailureReasonDNSFailed, lyricFailureReasonConnectFailed, lyricFailureReasonServerError,
}

func dominantLyricSourceTransportFailure(failures map[string]int) string {
	best, bestN := "", 0
	for _, code := range lyricSourceTransportFailureOrder {
		if n := failures[code]; n > bestN {
			best, bestN = code, n
		}
	}
	return best
}

// transportFailureCodes:本进程里一个响应都没拿到过、又确实失败过的源 → 最多见的那类失败代码。
// 没有这样的源返回 nil。
func (b *lyricSourceBreaker) transportFailureCodes() map[string]string {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := map[string]string{}
	for source, ts := range b.transport {
		if ts.responded || len(ts.failures) == 0 {
			continue
		}
		if code := dominantLyricSourceTransportFailure(ts.failures); code != "" {
			out[source] = code
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
