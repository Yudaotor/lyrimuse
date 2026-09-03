// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type neteaseInfo struct {
	Cover, SongURL, Lyrics, Trans, Roma, YRC string
	// DurationSecs:网易云曲库里这首歌自报的时长(秒),0=没拿到。2026-08-12 起透传给
	// 候选(sourceReportedDurationSecs);2026-08-22 起参与打分,见
	// match.go:sourceDurationMismatchPenalty。
	DurationSecs float64
	// Artist 是网易云曲库里这首歌的官方歌手名(单一歌手才填,合唱/多歌手曲目留空——
	// 避免把本地"歌手A & 歌手B"的联合署名压缩成只剩其中一个)。用于统一同一歌手在历史
	// 记录里时而中文时而英文、时而全大写的写法(如 PRINCE/Prince、David Tao/陶喆)。
	Artist string
	// Title/Album 是这首歌在网易云曲库里实际匹配到的歌名/专辑名,取自 pick() 选中的
	// chosen(候选 neSong)。主要给"搜索候选歌词"弹窗展示用(用户想知道这个候选具体
	// 对应哪首歌/哪张专辑,不是只看"netease"这个来源名);Album 另外**参与封面选源**
	// (见 enrich.go 的 preferAppleCoverOverNetease:网易云这张封面属于另一次发行时,
	// 改用 Apple 那张对得上专辑的)—— 但两者都不参与 pick() 自己的匹配/打分。
	// 跟 Artist 不同,这两个字段不做"是否单一歌手"之类的过滤,原样如实展示网易云曲库
	// 里的名字。
	Title, Album string
	// SongID 是这首歌在网易云的 id,0=没拿到。给 amll-ttml-db 按 ID 直取歌词用
	// (见 amllttml.go)——那个库的目录就是按平台音乐 ID 命名的。
	SongID int64
	// AlbumID 是 Album 那张专辑在网易云的 id,0=没拿到。只给同专辑预取用
	// (见 neteaseAlbumTracks)。跟 Title/Album 一样取自 pick() 选中的 chosen。
	AlbumID int64
	// PureMusic:网易云明确说这首歌是**纯音乐**。2026-08-20 加。
	//
	// 歌词接口对纯音乐会在顶层给 `pureMusic: true`,正文则是「作曲 : X」+
	// 「纯音乐,请欣赏」两行占位(实测 LoL 原声带 id=30431011)。这两行过不了
	// isTimedLRC 的三行门槛,所以 Lyrics 留空、网易云连一条候选都不产生 —— 而
	// "查过了、确实没有词"和"这首本来就没有词"在 UI 上是两句不同的话(「无歌词」vs
	// 「纯音乐」)。这个字段就是把后者那个明确结论带出来,跟 lrclib 的 instrumental
	// 标记汇到同一处(见 enrich.go 的 instrumentalMarker)。
	PureMusic bool
}

// neteaseCache 是这个文件自己内部的网络请求结果缓存(避免短时间内重复打网易云的接口),
// 跟 enrichCache(enrich.go)是两回事、各自独立——enrichCache 里一条歌只要解析出结果就
// 永久生效,不再有整体过期这回事;这里的 TTL 分级只管"多久内不用重新问网易云要一次数据"。
// 封面拿到了才算"拿全了"，给长 TTL；只拿到 SongURL+Lyrics 但 Cover 仍是空(多半是取封面
// 那次请求单独限流/超时)用短 TTL,让它有机会自愈——否则会永久遮蔽 enrich.go 那边
// backfillPeripheralFields 的外围字段重试(重试时调到这里,却直接命中这份"缺封面"的
// 旧缓存,永远补不回封面)。
const (
	neteaseCacheTTL        = 30 * 24 * time.Hour
	neteaseCacheTTLNoCover = 10 * time.Minute
)

type neteaseCacheEntry struct {
	info neteaseInfo
	ts   int64
}

var (
	neteaseMu    sync.Mutex
	neteaseCache = map[string]neteaseCacheEntry{}

	// neteaseLastFailureMu/neteaseLastFailureReason:诊断用的只读旁路(2026-08-31,跟
	// ytmusic.go 的 ytmusicLastFailureReason 同一个思路——不改 neteaseLookup 的返回值
	// 形状,自动解析路径从来不需要"为什么没查到"这个原因,只给设置页"测试这个源"功能多开
	// 一条只读旁路)。⚠️ 网易云对 405 限流本来就有备用接口兜底(见下面 get 闭包的注释),
	// 这条旁路只在**两个接口同一拍都被限流**这种少见情况下才有机会被读到——多数时候
	// 405 会被兜底吸收,压根不会走到"这个源整体没查到"这一步。
	neteaseLastFailureMu     sync.Mutex
	neteaseLastFailureReason string
)

// neteaseMinIntervalBetweenCalls:2026-08-31 加——网易云是按接口端点分桶、按短时间内
// 请求量触发限流的(见 resolveNeteaseInfo 里那段实测记录:"短时间内连发几十次搜索之后"
// 才会触发),之前完全没有任何节流。真实案例:陶喆和盧廣仲《那個女孩》这首本地匹配不到
// 的歌,"换个身份再搜"(别名重试轮)+ "按标题反查"(标题反查轮)两轮兜底加起来在 13
// 秒内连发了 16 次网易云请求,把自己先打成限流——表现是"这首歌搜不到"其实是"被自己的
// 重试轮打限流了",而且越是难匹配的歌触发的重试轮越多、越容易自己撞限流,跟"歌好不好搜"
// 反向关联。这里加一道全局节流,所有网易云请求共享同一个最小间隔,跟
// musicbrainzThrottle(musicbrainz.go)同一个模式。间隔选得比 MB 的 1.1s 短很多——网易云
// 容忍的请求量本身就远比 MB 官方限速(1 req/s)宽松,没必要把正常搜索拖得太慢,只要把
// 最密集的那段峰值削掉,让同一次搜索里连续几个重试轮之间留出呼吸空间。
const neteaseMinIntervalBetweenCalls = 250 * time.Millisecond

// neteaseBlockCooldown:2026-09-02 加——探测到网易云在 body 里拒绝请求(限流/风控,
// 见下面 neteaseReportBlocked)之后,这个端点桶要退避多久才再放行。之前完全没有这一层:
// neteaseThrottle 只管"发得多快",探测到拒绝之后什么反应都没有,下一次还是按原节奏
// 250ms 后立刻再发——等于对着已经关上的门继续按原速敲,真被限流的那几十秒里越敲越难
// 自愈,而且现有代码对拒绝完全不留痕(见 neteaseReportBlocked 旁边补的日志),连事后
// 复盘"到底有没有被限流过"都做不到。
//
// 参照 LastfmRateLimiter.reportThrottled(同一个项目里已经验证过的思路:探测到 429 就让
// 队列整体退避)。跟那边的关键差异:网易云是**按端点分桶**限流的(neteaseAlbumIDByName
// 头注的实测记录——同一时刻 /api/search/get/web 被拒、/api/search/get 照常放行),
// 所以这里的退避也按桶记,不是让整个网易云一起停摆——否则 neteaseSearch 那道"主端点被拒
// 立刻换备用端点试"的兜底会被这里新加的退避直接废掉(备用端点的请求同样要过
// neteaseThrottle,退避要是全局的,它也得跟着傻等)。
//
// ⚠️ **2026-09-03:从固定 30 秒改成按"这个桶连续被拒几次"指数递增**(base → ×2 → … →
// 上限,该桶有一次请求成功就清零,见 neteaseReportSuccess)。上一版注释自己写着"30 秒是
// 没有实测依据的保守起步值……以后如果观察到退避期一过又立刻再被拒,再按实际现象调大"——
// 现在观察到了,而且是数出来的:
//
// 拿 ~25 小时的真实日志(~/Library/Logs/lyrimuse.log.old,2026-09-01 18:47 → 09-02 19:12
// UTC)统计 171 次拒绝(164× code 405 / 7× 406,**全部落在 /api/search/get/web 一个桶**):
//   - 相邻两次拒绝间隔 **≤35 秒的有 89 次(52%)** —— 也就是"退避刚满就再撞一次";
//   - 这种"满了就撞"最长**连成 21 次一串**(≈10.5 分钟一直在敲同一扇关着的门);
//   - 间隔 2-10 分钟的 48 次,>10 分钟的 12 次 —— 说明真正的恢复窗口是分钟级,不是 30 秒。
// 固定 30 秒的后果不只是白撞:每次撞上去都会把服务端的惩罚窗口续一次,等于自己把限流
// 维持住。
//
// base 取 2 分钟(能消掉绝大多数"满了就撞")、上限 15 分钟(别让一个桶因为一串连撞被
// 永久打死)。这两个数来自上面那份分布,不是拍的;有新数据再调。
const (
	neteaseBlockCooldownBase = 2 * time.Minute
	neteaseBlockCooldownMax  = 15 * time.Minute
)

var (
	neteaseRateMu        sync.Mutex
	neteaseLastCall      time.Time
	neteaseCooldownUntil = map[string]time.Time{}
	// neteaseBlockStreak:每个端点桶**连续**被拒了几次(成功一次就清零)。指数退避的指数。
	neteaseBlockStreak = map[string]int{}
	// neteaseAnySuccess:这次进程生命周期里,网易云有没有任何一个请求真的成功过。
	// 它不参与节流,只给"该不该把限流当成这个源没给候选的原因"当判据 —— 见
	// neteaseSawSuccessNow 的头注。
	neteaseAnySuccess bool
)

// 网易云搜索的两个端点桶。⚠️ **2026-09-03 主备对调**:原来 /api/search/get/web 是首选、
// /api/search/get 是被限流时的兜底,现在反过来。
//
// 依据是同一份 25 小时日志里的对照:两个端点的请求量同一量级(/web 10029 次、/get 8537 次),
// 而**拒绝 171 : 0** —— 171 次全在 /web,/get 一次都没被拒过。也就是说这不是"谁被打得多
// 谁就被限得狠"的采样偏差,是这两个端点在服务端的宽容度本身差一个量级。响应结构完全一致
// (result.songs[] 里 name/id/artists/album/duration 都在,2026-08-09 实测),对调没有
// 解析层面的代价。
//
// 兜底那一条**保留不删**:分桶限流的意义就是"一条路堵了还有另一条",把 /web 删掉等于把
// 冗余也删了。只是它现在排第二 —— 平时压根不会被用到,真轮到它时也说明首选那条出事了。
const (
	neteaseSearchEndpointPrimary  = "https://music.163.com/api/search/get"
	neteaseSearchEndpointFallback = "https://music.163.com/api/search/get/web"
)

// neteaseEndpointBucket 把请求 URL 归到"网易云按端点分桶限流"的那个桶——只取路径,
// query string 里 type=1/type=10 这类参数不影响服务端按哪个桶计数(2026-08-09/
// 2026-08-28 两次实测都是同一路径下不同 query 一起被限、不同路径各自独立限流)。
func neteaseEndpointBucket(rawURL string) string {
	if u, err := neturl.Parse(rawURL); err == nil && u.Path != "" {
		return u.Path
	}
	return rawURL
}

// neteaseReportBlocked 供各处"body code 显示被拒绝"的分支调用(见 resolveNeteaseInfo/
// neteaseAlbumTracks/neteaseAlbumIDByName/retryTitleFromArtistSearchDetailed 各自的
// get/fetch 闭包):让 rawURL 对应的端点桶接下来 cooldown 这么久都不再放行
// (neteaseThrottle 里的第二层等待)。同一个桶如果已经在更晚的退避期里(比如短时间内
// 连续被拒两次),只会延长、不会缩短——后到的拒绝信号更新鲜,没理由让它把已经算好的
// 更长退避覆盖成更短的,跟 LastfmRateLimiter.reportThrottled"只可能往后延"同一个理由。
func neteaseReportBlocked(rawURL string, cooldown time.Duration) {
	bucket := neteaseEndpointBucket(rawURL)
	target := time.Now().Add(cooldown)
	neteaseRateMu.Lock()
	if existing, ok := neteaseCooldownUntil[bucket]; !ok || target.After(existing) {
		neteaseCooldownUntil[bucket] = target
	}
	neteaseRateMu.Unlock()
}

// neteaseReportRejected 是各处 get/fetch 闭包真正该调的那个(2026-09-03 加):记一次
// body 层面的拒绝 —— 递增这个桶的连撞计数、按指数算出这次退避多久、写进冷却表,把
// (退避时长, 连撞第几次)交回去给调用方打日志。
//
// 拆成两层而不是直接把指数逻辑塞进 neteaseReportBlocked:后者是"退避到某个时刻"这个
// 纯粹的原语,neteasethrottle_test.go 拿它构造精确的退避场景(毫秒级),指数逻辑混进去
// 就没法再构造了。
func neteaseReportRejected(rawURL string) (time.Duration, int) {
	bucket := neteaseEndpointBucket(rawURL)
	neteaseRateMu.Lock()
	neteaseBlockStreak[bucket]++
	streak := neteaseBlockStreak[bucket]
	neteaseRateMu.Unlock()
	neteaseReportBlocked(rawURL, neteaseCooldownForStreak(streak))
	return neteaseCooldownForStreak(streak), streak
}

// neteaseCooldownForStreak:连撞第 streak 次该退避多久。base × 2^(streak-1),封顶。
// ⚠️ 移位前必须先卡住 streak:`time.Duration` 是 int64,base(2min=1.2e11ns)左移 30 位
// 就溢出成负数,而负的退避会被 neteaseReportBlocked 算成"已经过期",等于**没有退避**——
// 连撞越多反而越不退避,正好反了。streak ≥ 4 时 base<<3 = 16min 已经超过上限,直接封顶。
func neteaseCooldownForStreak(streak int) time.Duration {
	if streak < 1 {
		streak = 1
	}
	if streak >= 4 {
		return neteaseBlockCooldownMax
	}
	if scaled := neteaseBlockCooldownBase << (streak - 1); scaled < neteaseBlockCooldownMax {
		return scaled
	}
	return neteaseBlockCooldownMax
}

// neteaseReportSuccess:这个桶刚真的答了一次(HTTP 200 且 body 里没有拒绝码)。
// 三件事:①连撞计数清零,下次被拒重新从 base 起算(不然一个桶只会越退越久、永不复原);
// ②顺手清掉这个桶可能残留的冷却标记;③置那个"这次进程里网易云成功过"的全局标记。
func neteaseReportSuccess(rawURL string) {
	bucket := neteaseEndpointBucket(rawURL)
	neteaseRateMu.Lock()
	delete(neteaseBlockStreak, bucket)
	delete(neteaseCooldownUntil, bucket)
	neteaseAnySuccess = true
	neteaseRateMu.Unlock()
}

// neteaseSawSuccessNow:这次进程里网易云有没有任何一个请求成功过。
//
// 用途只有一个(2026-09-03 加):`lyricSourceFailureReasons`(搜索候选弹窗的「歌词源
// 可用情况」)和 `test-lyric-sources` 在决定"要不要把限流当成这个源没给出候选的原因"
// 时先问一下这里。
//
// ⚠️ 病根是实测坐实的**张冠李戴**:`neteaseLastFailureReason` 只要进程里出现过一次
// code 405 就会被贴上,而只要该源这一轮没给出候选就会显示出来 —— 两件独立的事被显示成
// 因果。对照实验(2026-09-03,同一分钟内跑两次 `collector search-lyrics`):
//   - 《妳聽得到》:首个网易云请求吃 405 → 换备用端点 10 次全 200 → 仍然零候选,
//     面板显示"未给出候选 + 接口限流";
//   - 《白发》:**同样**吃 405 → 走备用端点 → netease **给出 4 条候选**,最终
//     failureCodes 里根本没有 netease。
// 后者证明"吃过 405"跟"没给出候选"根本不是同一件事。加这道判据之后,只有该源这一轮
// **一次都没成功过**才会把限流报成原因,否则如实显示"未给出候选"(没有更多信息)。
func neteaseSawSuccessNow() bool {
	neteaseRateMu.Lock()
	defer neteaseRateMu.Unlock()
	return neteaseAnySuccess
}

// neteaseThrottle 跟 musicbrainzThrottle 同一个模式:全局锁串行化 + 按需 sleep 补足
// 间隔,ctx 取消时提前退出等待(不占用这次调用名额,不更新 neteaseLastCall)。
//
// 2026-09-02 加了第二层等待:rawURL 对应的端点桶如果最近被 neteaseReportBlocked 标记过
// 退避,还要多等到那个退避期满。⚠️ 两层等待都**不持锁 sleep**——这一点故意跟
// musicbrainzThrottle"锁一直拿着睡"不一样:退避可能长达 30 秒,如果也锁着睡,会把
// **所有**端点(包括没被限流的备用端点、其它完全不相干的接口)一起卡住 30 秒,直接废掉
// neteaseSearch"主端点被拒立刻换备用端点试"这条兜底,也会让同时在解析别的曲目、命中
// 别的健康端点的请求跟着白等。改成"锁内只读/写状态、算出该睡多久、解锁再睡、睡醒了回去
// 重新排队"的轮询式设计,任何一个端点桶的长退避都不会挡住其它桶或全局最小间隔的正常节奏。
// errNeteaseBucketCooling:这个端点桶正在退避期内。**立刻返回,不睡**。
//
// ⚠️ 2026-09-02 改的语义(此前是睡满整个退避期再放行),连带改掉了
// neteasethrottle_test.go 里那两条断言。实测依据(「搜索候选歌词」搜
// DAOKO×米津玄師《打上花火》,逐条打时间戳):**整次搜索 150 秒以上,其中约 120 秒
// 是在这里睡掉的**,而且睡出来的是一条等差数列 —— 30 / 60 / 90 / 120 / 150 秒。
//
// 病灶形状:调用方(retryTitleFromArtistSearchDetailed / neteaseAlbumIDByName)都是
// "主端点不行就换备用端点"的两段式写法 ——
//
//	tracks, ok := get(".../api/search/get/web?...")  // 正在被 405 限流的桶
//	if !ok {
//	    tracks, ok = get(".../api/search/get?...")   // 另一个桶,健康,150ms 就回
//	}
//
// 主端点冷却中时,旧写法先睡满 30 秒、醒来发一个请求、再被 405 拒一次(顺带把退避又
// 延长 30 秒),然后才轮到那个**本来就健康**的备用端点。反查轮要发好几个这样的请求,
// 于是每一个都白睡 30 秒。
//
// 立刻返回错误对"被限流就别继续敲门"这个原始意图其实**更强**:退避期内一个请求都不
// 发(旧写法是睡完再发一个去试),同时调用方能立刻改走备用桶。
//
// ⚠️ 别把这条读成"退避变宽松了"。250ms 最小间隔那一层照旧**睡**(它管的是"发得太快",
// 不是"这个桶被拒了"),两层的语义不一样,不能一起改。
var errNeteaseBucketCooling = errors.New("netease: endpoint bucket cooling down")

func neteaseThrottle(ctx context.Context, rawURL string) error {
	bucket := neteaseEndpointBucket(rawURL)
	for {
		neteaseRateMu.Lock()
		now := time.Now()
		// 退避期:不睡,直接告诉调用方"这个桶现在别用"。见 errNeteaseBucketCooling。
		if until, ok := neteaseCooldownUntil[bucket]; ok && until.After(now) {
			neteaseRateMu.Unlock()
			return errNeteaseBucketCooling
		}
		wait := neteaseMinIntervalBetweenCalls - now.Sub(neteaseLastCall)
		if wait <= 0 {
			neteaseLastCall = now
			neteaseRateMu.Unlock()
			return nil
		}
		neteaseRateMu.Unlock()
		select {
		case <-time.After(wait):
			// 睡醒了不代表这个名额一定还留着(别的调用者可能抢先拿走了、或者这期间这个桶
			// 被拒绝标记进了退避),回到循环开头重新读一次最新状态、重新排队,不假设睡完
			// 这一段就一定能通过。
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func neteaseSetLastFailureReason(reason string) {
	neteaseLastFailureMu.Lock()
	neteaseLastFailureReason = reason
	neteaseLastFailureMu.Unlock()
}

// neteaseLastFailureReasonNow 供 test-lyric-sources 用——本次进程里最近一次识别出的
// 具体失败原因,识别不出就是空串。
func neteaseLastFailureReasonNow() string {
	neteaseLastFailureMu.Lock()
	defer neteaseLastFailureMu.Unlock()
	return neteaseLastFailureReason
}

// neteaseLookup returns a China-reachable album cover URL (p*.music.126.net) and
// the NetEase song page URL for a track. The album is used to disambiguate: the
// same song appears on many NetEase albums (originals, compilations, "This Is
// It"…), so picking songs[0] blindly grabs the wrong cover. Cached per
// artist|title|album; only cached once the song id is found.
func neteaseLookup(ctx context.Context, artist, title, album string, durationSecs float64) neteaseInfo {
	return withholdImpersonatorRiddenIdentity(artist, neteaseLookupAll(ctx, artist, title, album, durationSecs))
}

// withholdImpersonatorRiddenIdentity 对"版权整体下架、曲库里只剩仿冒号"的艺人
// (见 isNeteaseImpersonatorRidden)只保留**歌词族**字段,把身份/封面/跳转链接/专辑 id
// 全部扣下 —— 净效果跟这道防线原来那种"整源跳过"逐条一致(Cover 空 → 不写
// CoverSource/CoverAlbum;AlbumID=0 → 专辑预取早退;SongURL 空 → 不写 NeteaseURL;
// Artist 空 → canonical_artist 走其它链路),唯一的差别是歌词照常进入五源打分。
//
// 为什么身份/封面照旧不信:仿冒号能把歌名、专辑名、时长一字不差地抄成目标曲目,
// pick() 的标题/歌手名校验对这类艺人天然拦不住(见 isNeteaseImpersonatorRidden 注释)。
// 采信它的署名就等于把仿冒号的名字写进 canonical_artist,采信它的封面就是挂错图。
//
// 为什么歌词可以放行:歌词是按 songID 挂在网易云**歌词库**上的,跟"这条曲目记录是谁传的"
// 是两回事;而歌词候选另有一整套跟来源无关的防线(lyricTitleAccepted + 歌手闸 +
// 版本限定词 -600 + 时长 -700/-500 + 语言闸 + creditOnly 闸 + 跨源共识),错版本的歌词
// 在打分层就会掉下去,不需要靠"整源不看"这种粒度的封锁 —— 那个粒度的代价是:这位艺人
// 的每一首歌都**先天少一个源**,而网易云恰好是五源里唯一同时供逐字 YRC、社区译文和
// 罗马音的那个。
//
// 2026-08-22 实测(用户报「开不了口 (Live) 歌词不准」):本地在放《周杰伦地表最强世界
// 巡回演唱会 (Live)》里的「开不了口 (Live)」(272.973s)。整源跳过之下,五个源里 QQ 的
// smartbox 首个查询只回一条署名"周杰伦微博台"的仿冒条目(被歌手闸拒)、酷狗只有 2010
// 超时代演唱会那版(399s,错版本)、musixmatch 空,只剩 LRCLIB 一条 509 分的候选,而那份
// 的时间轴相对录音室版从 +1.0s 一路漂到 +11.5s、只有 34 行、末句比录音室版还早,根本
// 不是这次现场的时间轴。网易云上**有**对版的那份:歌名「开不了口 (Live)」、专辑
// 「周杰伦地表最强世界巡回演唱会」、自报时长 272.973 与本地逐位一致、正文带这次现场
// 特有的返场段(「我就是开不了口 / 我只能够远远的看着你 / 开不了口」),逐行比对相对
// 录音室版是**恒定** -10.7s 偏移(前奏短了 10.7 秒,之后每一句都严丝合缝),而且带 YRC
// 逐字。它经 pick() 的严格档(标题精确 + artistMatches + 多候选要求专辑分>0)能被唯一
// 锁定 —— 唯一挡住它的就是这里的整源跳过。
func withholdImpersonatorRiddenIdentity(artist string, info neteaseInfo) neteaseInfo {
	if !isNeteaseImpersonatorRidden(artist) {
		return info
	}
	// Title/Album/DurationSecs 一并留下:它们是这条候选的**自证元数据**,正是版本限定词
	// (versionTagsMismatch)、专辑亲和(albumScore)、时长吻合那几道打分闸的输入 —— 扣掉
	// 它们等于把放行歌词之后唯一的把关依据也一起拿走。Album 虽然也参与封面选源,但那条
	// 路径以 Cover 非空为前提(见 enrich.go 里 e.CoverAlbum 的写入),Cover 已经扣掉了。
	//
	// PureMusic 不留:纯音乐标记是"这首歌本来就没词"的结论,由它写进条目会挡掉后续重搜
	// (见 needsLyricsFirstFill),而这类艺人的曲库记录本身就不可信,不该拿它下这种结论。
	//
	// SongID 留下:它跟 Lyrics/Trans/Roma/YRC 同属**歌词族**。这个函数开头那段注释自己
	// 写了理由 —— "歌词是按 songID 挂在网易云歌词库上的,跟这条曲目记录是谁传的是两回事"。
	// 它的唯一用途是拿去 amll-ttml-db 按 ID 直取(见 amllttml.go),而那边命不命中由那个
	// 库自己说了算:仿冒条目的 id 在人工提交的 amll 库里查不到,直接 404。
	return neteaseInfo{
		Lyrics:       info.Lyrics,
		Trans:        info.Trans,
		Roma:         info.Roma,
		YRC:          info.YRC,
		SongID:       info.SongID,
		Title:        info.Title,
		Album:        info.Album,
		DurationSecs: info.DurationSecs,
	}
}

// neteaseLookupAll 是不分艺人、如实返回网易云这一趟查到的全部字段的内层实现。
// 调用方一律走 neteaseLookup(它在出口按艺人扣字段),不要直接调这个。
//
// durationSecs:本地真实曲长(秒),给 pick() 的时长锚定档用(见 pick 头注),不知道就传 0
// (锚定档关闭,行为与 2026-09-01 之前逐字节一致)。它参与缓存 key —— 否则预取路径
// (传 0)先跑,缓存住一个没经过锚定的结果,真播放那次(带时长)命中同一个 key,锚定档
// 永远轮不到生效,直到 30 天 TTL 过期。
func neteaseLookupAll(ctx context.Context, artist, title, album string, durationSecs float64) neteaseInfo {
	if title == "" {
		return neteaseInfo{}
	}
	key := artist + "|" + title + "|" + album + "|" + strconv.Itoa(int(durationSecs))
	now := time.Now().Unix()
	neteaseMu.Lock()
	if e, ok := neteaseCache[key]; ok {
		ttl := int64(neteaseCacheTTL / time.Second)
		if e.info.Cover == "" {
			ttl = int64(neteaseCacheTTLNoCover / time.Second)
		}
		if now-e.ts < ttl {
			neteaseMu.Unlock()
			return e.info
		}
	}
	neteaseMu.Unlock()

	info := resolveNeteaseInfo(ctx, artist, title, album, durationSecs)
	// 只缓存"拿到实质内容"的结果:找到歌但封面+歌词都空(多半被限流)不缓存,以免遮蔽
	// enrich 的短 TTL 自愈——否则下次重解析命中这份空缓存、永远补不回封面/歌词。
	if info.SongURL != "" && (info.Cover != "" || info.Lyrics != "") {
		neteaseMu.Lock()
		neteaseCache[key] = neteaseCacheEntry{info: info, ts: now}
		neteaseMu.Unlock()
	}
	return info
}

// neteaseSearch 发一次搜索,主端点被限流时换备用端点再试一次。
//
// 2026-08-09 实测:网易云的限流是**按端点分桶**的 —— 短时间内多查几十次之后
// /api/search/get/web 稳定回 code 405,而同一刻 /api/search/get 照常返回 200,两者的
// 响应结构完全一致(result.songs[] 里 name/id/artists/album/duration 都在)。
//
// 只有一个端点的时候,一撞上限流这个源就整个哑掉,而它是唯一给译文和罗马音的源;结果还会
// 被永久缓存(缓存没有 TTL)。多一个桶不是为了跑得更快,是为了在被限的那几分钟里仍然有
// 一条路走通。
func neteaseSearch(get func(string, any) error, q string, out any) error {
	escaped := neturl.QueryEscape(q)
	const query = "?type=1&limit=30&s="
	err := get(neteaseSearchEndpointPrimary+query+escaped, out)
	if err == nil {
		return nil
	}
	return get(neteaseSearchEndpointFallback+query+escaped, out)
}

// isInstrumentalPlaceholderLyric 判断这份 lrc 是不是"纯音乐占位"而不是真歌词。
//
// ⚠️ 2026-08-22 从 isNeteasePureMusicLyric 改名成来源中立:它对 **QQ 音乐**的占位文案
// 逐字适用 —— QQ 对纯音乐曲目回的是单行 `[00:00:00]此歌曲为没有填词的纯音乐,请您欣赏`,
// 正文含 neteaseInstrumentalPlaceholderMarker、除它之外没有别的正文行,这个函数直接判 true。
// 同一个事实两处别各写一份判定。
//
// 顶层 pureMusic 标记是主判据,这个是**备份**:网易云自己的数据不齐,实测同一批曲目里
// 有的条目只有正文占位、没有那个顶层字段。
//
// 占位文案复用 match.go 已有的 neteaseInstrumentalPlaceholderMarker(那边的
// isCreditOnlyLRC 拿它判"这份不是真歌词"、直接判废)—— 同一个事实两处别各写一份。
// 这里做的是**另一件事**:把"判废"升级成"得出结论"。判据刻意收紧成「整份只有占位 +
// 可选的署名行」,任何一句真歌词都让它不成立,免得把歌词里恰好唱到"纯音乐"的句子误判。
func isInstrumentalPlaceholderLyric(lrc string) bool {
	if strings.TrimSpace(lrc) == "" {
		return false
	}
	hasPlaceholder := false
	for _, line := range strings.Split(lrc, "\n") {
		body := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if body == "" {
			continue
		}
		if strings.Contains(body, neteaseInstrumentalPlaceholderMarker) {
			hasPlaceholder = true
			continue
		}
		// 署名行(作曲/作词/编曲…)允许共存 —— 纯音乐条目基本都带一行作曲。
		if isCreditLine(body) {
			continue
		}
		return false // 有真正的歌词内容
	}
	return hasPlaceholder
}

// stripNeteaseEscapedApostrophes 清掉网易云 lyric/tlyric/romalrc/yrc 接口里一小撮曲目
// 自带的字面 `\'`(反斜杠+英文引号两个字符,不是 JSON 转义——json.Unmarshal 早就完成了
// 正常解码,这是网易云自己数据库里躺着的脏数据)。2026-09-01 用户报"陈奕迅《爱是怀疑
// (Live)》里 It\'s / Can\'t 这种反斜杠直接显示在歌词里",实测抓了本地缓存的
// ~/.config/lyrimuse/lyrics/*.lrc 全量按来源分组核实过:1669 条网易云缓存里只有这 2 条
// 命中(且都是英文歌词行,反斜杠只出现在撇号前面),QQ/酷狗/musixmatch/lrclib/amll 缓存
// 里零命中——是网易云这一个源的孤立脏数据,不是我们自己转义/反转义链路的 bug,所以固定
// 替换反斜杠+撇号这一种组合就够,不用做成通用的转义清洗器。
func stripNeteaseEscapedApostrophes(s string) string {
	if !strings.Contains(s, `\'`) {
		return s
	}
	return strings.ReplaceAll(s, `\'`, "'")
}

func resolveNeteaseInfo(ctx context.Context, artist, title, album string, durationSecs float64) neteaseInfo {
	cli := &http.Client{Timeout: 4 * time.Second}
	get := func(u string, v any) error {
		if err := neteaseThrottle(ctx, u); err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return err
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := doHTTPTracked(cli, req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("status %d", resp.StatusCode)
		}
		// ⚠️ 网易云限流时**照样回 HTTP 200**,把拒绝写在 body 的 code 字段里(实测
		// 2026-08-09:短时间内连发几十次搜索之后,/api/search/get/web 稳定返回
		// {"result":{},"code":405},而同一刻 /api/search/get 仍然正常 —— 是按端点分桶的
		// 应用层限流,不是封 IP)。
		//
		// 只看 HTTP 状态码的话,这份响应会被解成"零首歌",跟"这首歌网易云真的没有"完全
		// 分不开。后果不是少一条候选那么轻:这一轮的结果会被**永久缓存**(缓存没有 TTL),
		// 而网易云是唯一提供译文和罗马音的源 —— 一次几分钟的限流,能让那段时间里解析的
		// 歌永远缺译文。当成错误返回之后,这个源就不会被记进 LyricsSourcesSeen,
		// needsLyricsRetry 才有机会在之后重搜(见那边的 missing 判断)。
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return err
		}
		var probe struct {
			Code int `json:"code"`
		}
		// code 缺省(有些端点不带这个字段)时是 0,不当作错误。
		if err := json.Unmarshal(body, &probe); err == nil && probe.Code != 0 && probe.Code != 200 {
			// 2026-09-02:body 拒绝一律记日志 + 退避这个端点桶(neteaseReportBlocked),
			// 不再只在 code==405 时才留痕——退避这层不需要先搞懂拒绝码具体是什么意思,
			// 任何非 0/200 都当"这个桶该歇一歇"处理,宁可偶尔多等一次没必要的退避,
			// 也不要对着还没搞懂的拒绝码继续按原速撞。
			cooldown, streak := neteaseReportRejected(u)
			log.Printf("netease: %s rejected (code %d), backing off %s (这个桶连续第 %d 次被拒)",
				neteaseEndpointBucket(u), probe.Code, cooldown, streak)
			if probe.Code == 405 {
				// 2026-08-31 实测坐实的具体原因,见 neteaseLastFailureReason 声明处注释。
				// 只在确认是这个 code 时才记**具体原因**——其它非零 code 目前没有验证过
				// 具体含义,不编一个没核实过的理由。存的是稳定代码不是文案,见
				// lyricsourcefailure.go 头注,两侧必须同步维护。（上面的退避不受这条限制,
				// 是两件事:退避只需要知道"被拒了",不需要知道"为什么"。）
				neteaseSetLastFailureReason(lyricFailureReasonNeteaseRateLimited)
			}
			return fmt.Errorf("netease api code %d", probe.Code)
		}
		// 走到这儿 = 这个桶真的答了(HTTP 200 且 body 里没有拒绝码):清连撞计数、
		// 记下"这次进程里网易云成功过"。见 neteaseReportSuccess / neteaseSawSuccessNow。
		neteaseReportSuccess(u)
		return json.Unmarshal(body, v)
	}

	// NetEase 搜索对词序/括号噪声敏感:带一堆 (feat.)/(with) 的完整标题常搜不到真曲、
	// 只回一堆热门歌兜底。用去括号标题查,不中再换一个词序(实测 "标题 歌手" 召回更好)。
	//
	// ⚠️ 这里**故意不走 searchTitleVariants**,是唯一一个不走的源 —— 别把它"顺手统一"过去。
	// 那个函数里的"版本限定词 → 原样标题优先"守卫是给 kugou/QQ/Musixmatch 准备的,因为
	// 那三个源是**取第一条通过校验的候选就收工**,搜索词一偏就直接定死在错版本上。而下面
	// 的 pick() 是**扫完 10 条结果再排序挑**(精确同名 exactCands 优先于宽松 looseCands,
	// 再按专辑分),版本选择由排序负责,不依赖搜索词的写法。
	//
	// 2026-08-09 实测坐实:把这里也改成"版本限定词原样优先"之后,14 首带 (Live)/
	// (Original Version)/(reprise) 的歌,网易云拿到的候选曲名**一条都没变**(分数的整齐
	// -50 是另一次改动删掉来源加分造成的,与此无关),白白多打最多 2 次请求 —— 而网易云
	// 恰恰是五个源里最容易被限流的那个(HTTP 200 + body code 405)。所以改回来。
	ct := stripParens(title)
	// ca:去掉艺人标签自带的括号别名再拼进搜索词——2026-08-30 真实bug(温岚《夏日の風》):
	// 本地艺人字段有时是"主名 (罗马化别名)"(YouTube Music 桥接给的常见形态,如
	// "溫嵐 (Landy Wen)"),整串原样拼进网易云的模糊搜索会把召回带偏、搜不到任何候选。
	// 跟 ct 去标题括号是同一个坑、同一个修法。下面 pick() 里的 artistMatches 仍然拿
	// **原始** artist 去核验身份(它自己有 stripParens 的兜底分支,核验不受影响),这里
	// 只改"拿什么去发搜索请求"。
	ca := stripParens(artist)
	var queries []string
	// 老歌撞新翻唱/新演出版本同名时,纯"歌手+标题"召回率不够——真正想要的旧版本可能在
	// NetEase 搜索排名里靠后,掉出 pick() 能看到的候选窗口,导致只看到新版本这一条"唯一
	// 候选"而选错了封面。带上本地专辑名一起查能大幅提升召回排名——只在本地专辑名非空时才
	// 加这条查询、且放在最前面优先尝试,不影响本来就没有专辑信息的情形(如"大鱼"那种本地
	// 专辑名对不上/为空的正常单曲，见 pick 注释)。
	if album != "" {
		queries = append(queries, ca+" "+ct+" "+album)
	}
	queries = append(queries, ca+" "+ct)
	if ct != title {
		queries = append(queries, ca+" "+title) // 保留原始作为补充
	}
	queries = append(queries, ct+" "+ca)
	type neSong = struct {
		ID      int64  `json:"id"`
		Name    string `json:"name"`
		Artists []struct {
			Name string `json:"name"`
		} `json:"artists"`
		Album struct {
			Name string `json:"name"`
			// ID:专辑 id。给"提前解析同专辑其它曲目"用 —— 拿的是 **pick() 选中的这首歌
			// 自己所属**的专辑,不是拿专辑名去另搜一次,所以天然不会撞上同名专辑/精选集
			// (实测搜 "Michael Jackson Bad",前三条全是套装:King of Pop 48 首、
			// The Collection 76 首,原专辑排到第 13 条)。
			ID int64 `json:"id"`
		} `json:"album"`
		// Duration:搜索结果自带的曲长(毫秒)。透传给候选,不参与本文件内的任何挑选逻辑。
		Duration float64 `json:"duration"`
	}
	// 选谁的封面/链接:同名歌里混着别歌手的翻唱/演奏/卡拉OK/同名他人歌。优先级:
	// ①歌名+歌手都匹配、且专辑分最高(专辑名 loose 相等=100 直接锁定正确专辑版本);
	// ②歌手名跨平台不一致但专辑强匹配(albumScore>0);③都无 → 返回空,不串错歌手。
	// 只信 byArtist(歌手名精确对上),不再有"歌手对不上、专辑名对上就认"的 byAlbum 兜底——
	// 专辑名字段能被仿冒号无成本抄成任意值(比 artistMatches 要防的"歌手名加个符号"更难防),
	// 官方曲库缺失时宁可 pick() 返回空,让 resolveTrackEnrichment 退到 QQ 音乐兜底(QQ 侧
	// 要求歌手名双重精确匹配,见 qqCoverFallback),也不要信一个只凭专辑名认亲的结果。
	// pick 分两步:①先把"歌手真的对上"的候选按标题精确/宽松分两档;②每档内部只有
	// 出现"不止一条"候选时才要求专辑分>0 才采信,单独一条候选时直接信它。
	// 按"是否有歧义"分情况,而不是无脑要求专辑分>0:很多正常单曲在网易云上专辑名字段本就
	// 跟本地(Apple Music)写法不一致、甚至整个空着,这时候只有一条真人候选、没有竞争者,
	// 没道理因为专辑名对不上就弃用。但当同一首歌出现两条以上"歌手都是真人、标题都精确同名"
	// 的候选时,说明网易云上确实存在多个实体版本(旧单曲发行版/后来收录进新专辑的版本等),
	// 这时候才需要专辑分>0 来确认选的是目标专辑对应的版本,选不出来宁可整体放弃、交给
	// QQ 音乐兜底,也不要矮子里拔将军选一个不确定对不对版本的候选。
	pick := func(songs []neSong) *neSong {
		type cand struct {
			s  *neSong
			sc int
		}
		var exactCands, looseCands []cand
		for i := range songs {
			s := &songs[i]
			if !lyricTitleAccepted(s.Name, title) {
				continue
			}
			artistMatch := false
			for _, a := range s.Artists {
				if artistMatches(a.Name, artist) {
					artistMatch = true
					break
				}
			}
			if !artistMatch {
				continue
			}
			sc := albumScore(s.Album.Name, album)
			if normLoose(s.Name) == normLoose(title) {
				exactCands = append(exactCands, cand{s, sc})
			} else {
				looseCands = append(looseCands, cand{s, sc})
			}
		}
		// 时长+专辑锚定档(v8,2026-09-01,陈奕迅《孤独探戈 (Live)》案),排在既有分层
		// **之前**:曲库里混着同一首歌的多个实体版本时,"精确同名优先"这条排序对
		// 「源平台在曲名里多标注了演奏方式」的正确版本是盲的 —— 本地《The Easy Ride
		// 演唱会 (Live)》的「孤独探戈 (Live)」,网易云库里正确版本叫「孤独探戈(Acoustic
		// Piano)(Live)」(专辑对、自报时长 215.4s 与本地 215.373s 逐位吻合),却因为标题
		// 不精确落进 looseCands,被三条**错场次**的精确同名(Get A Life sc=1/Third
		// Encounter sc=1/拉阔压轴 sc=0)按"exactCands 优先"永远压住 —— pick 原来完全
		// 不看时长,而时长 ≤1% 恰恰是"同一次录音"的最硬证据(第 14 条三角判据同一档)。
		//
		// 判据(全部成立才接管):①sameRecordingDespiteVersionTags 四道门(时长 ≤1% +
		// 专辑亲和 + 不缺本地限定词 + 多出的词全在 acoustic 家族白名单 —— 伴奏/粤语/国语
		// 这类"时长相同但确是另一次录音"的词永不锚定,见 match.go 那边的注释);
		// ②它的专辑分**严格高于**其它全部已通过校验的候选(证据必须是"唯独它对得上",
		// 不是"大家都差不多");③锚定候选唯一(两条都满足①且专辑分打平 → 有歧义,放弃)。
		// durationSecs 未知(=0,预取路径)时整档关闭,行为与旧版逐字节一致。
		if durationSecs > 0 {
			all := append(append([]cand{}, exactCands...), looseCands...)
			var anchor *neSong
			anchorSc := -1
			for _, c := range all {
				if !sameRecordingDespiteVersionTags(title, album, durationSecs, c.s.Name, c.s.Album.Name, c.s.Duration/1000) {
					continue
				}
				switch {
				case c.sc > anchorSc:
					anchor, anchorSc = c.s, c.sc
				case c.sc == anchorSc:
					anchor = nil // 两条锚定候选专辑分打平,有歧义,这一档整体放弃
				}
			}
			if anchor != nil && anchorSc >= 1 {
				strictlyHighest := true
				for _, c := range all {
					if c.s != anchor && c.sc >= anchorSc {
						strictlyHighest = false
						break
					}
				}
				if strictlyHighest {
					return anchor
				}
			}
		}
		// strict:looseCands 传 true——这批候选标题本身就带着"(Extended)"/"(Live)"/
		// "(Instrumental)"这类版本限定词,天然就是"另一个版本",唯一候选也不能免检直接信。
		// exactCands 传 false,保留"唯一精确同名候选、专辑名对不上也认"的既有行为,不能收紧。
		bestOf := func(cands []cand, strict bool) *neSong {
			if len(cands) == 1 && !(strict && album != "" && cands[0].sc == 0) {
				return cands[0].s // 唯一候选,没有歧义,直接信
			}
			// 多条候选(有歧义)→ 要求专辑分>0 才采信,选分最高的;都是0就整体放弃。
			var best *neSong
			bestSc := 0
			for _, c := range cands {
				if album != "" && c.sc == 0 {
					continue
				}
				if best == nil || c.sc > bestSc {
					best, bestSc = c.s, c.sc
				}
			}
			return best
		}
		// exactCands 优先,但优先到"没有 bestOf 选得出的"时不能直接放弃返回 nil——网易云上
		// 常年混着跟目标专辑无关、却标题恰好逐字同名的现场/盗版录音,这类候选一多就会让
		// exactCands 内部因"有歧义+都对不上专辑"被 bestOf 拒绝返回 nil;但 looseCands 里
		// 那条真正官方专辑版本(标题带"(Remaster)"等后缀、专辑分却明确对得上)本来是能唯一
		// 确定的,不该因为 exactCands 抢先返回 nil 就被连带放弃。
		if len(exactCands) > 0 {
			if c := bestOf(exactCands, false); c != nil {
				return c
			}
		}
		// looseCands 的"唯一候选直接信"不能像 exactCands 一样无条件生效——"查询词带上
		// 本地专辑名"这条优化(见上面 queries 构造处注释)可能让网易云的搜索排序把其它候选
		// 挤出结果窗口,只剩一条恰好通过标题/歌手校验、实为错误版本的候选,造成"看似唯一、
		// 其实只是被这次查询词意外筛剩下"的假象。looseCands 天然都是"标题带版本限定词"的
		// 候选(不然早被分进 exactCands 了),比 exactCands 更容易出现这种假象,所以收紧成
		// "本地有专辑名时,唯一候选也必须专辑分>0 才采信",专辑分对不上就整体放弃、交给
		// QQ 音乐兜底(宁可没有,也不要错,跟这个函数其它几处判断同一个原则)。
		if len(looseCands) > 0 {
			return bestOf(looseCands, true)
		}
		return nil
	}
	// 仅用于统一"歌手名怎么写"的兜底候选:歌名+专辑名都精确对上(albumScore=200)、且这批
	// 结果里只有唯一一条这样的候选,才采信它的歌手名——即便歌手名字面对不上查询词也认(比如
	// 查询用了罗马化/英文名,网易云库里这首歌记的是中文名)。跟 pick() 分开、绝不影响封面/
	// 歌词选择:那条判定必须先核实歌手名(见 artistMatches 注释——版权下架的艺人满屏都是
	// 仿冒号,专辑名可以被仿冒号随意抄成目标专辑名蒙混过关)。这里放宽的代价只是"历史列表
	// 偶尔显示错一个名字"这种低风险的展示问题,跟"封面选错"不是一个量级,所以能接受;但
	// 仍要求"唯一候选"防止同名同专辑撞车时瞎选一个。繁简转换已下沉到 normLoose/albumScore
	// 本身(见 match.go 的 normLoose 注释),这里不用再手动转一遍。
	nameOnlyMatch := func(songs []neSong) string {
		var found string
		n := 0
		for i := range songs {
			s := &songs[i]
			if normLoose(s.Name) != normLoose(title) || albumScore(s.Album.Name, album) < 200 || len(s.Artists) != 1 {
				continue
			}
			n++
			found = s.Artists[0].Name
		}
		if n == 1 {
			return found
		}
		return ""
	}

	// limit=30:"带专辑名"这条查询词(queries 第一条)对某些歌曲的检索排序反而有害——
	// 正确候选可能压根没出现在其结果里,加大它的 limit 也无济于事;但"不带专辑名"的兜底
	// 查询词(queries 第二条)在 limit=30 时能捞到这条本来就存在、只是排得靠后的正确候选。
	// 不需要为"带专辑名"那条单独做排除/回退,它找不到东西时自然不会返回任何可用候选,
	// 后续查询词的结果照常生效(见下面 chosen 只在 albumScore 更高时才覆盖的逻辑)。
	var chosen *neSong
	var nameOnlyArtist string
	for _, q := range queries {
		var r struct {
			Result struct {
				Songs []neSong `json:"songs"`
			} `json:"result"`
		}
		if err := neteaseSearch(get, q, &r); err != nil {
			continue
		}
		if c := pick(r.Result.Songs); c != nil {
			// 专辑名完全相等(albumScore=200)已是最优,直接采用;否则继续尝试下个查询看能否
			// 更好——注意 100 分只是"宽松包含"(可能是重发/纪念版),不能当作已经够好而提前退出。
			if chosen == nil || albumScore(c.Album.Name, album) > albumScore(chosen.Album.Name, album) {
				chosen = c
			}
			if albumScore(c.Album.Name, album) >= 200 {
				break
			}
		}
		// 跟 chosen 分支同样的道理(见下方注释):本地标签本来就是多人合credit时不用这条
		// 兜底,避免用只记了其中一位的 NetEase 单曲数据悄悄丢掉本地已经写全的合作者。
		// isNeteaseImpersonatorRidden(artist) 时也跳过——见该函数注释,这类艺人网易云
		// 官方曲库整体缺失,任何"标题+专辑名精确匹配"的候选先天就是仿冒号,nameOnlyMatch
		// 的"歌手名字面对不上也认"这条规则对他们而言等于直接采信仿冒号的署名。
		if nameOnlyArtist == "" && len(artistCreditParts(artist)) < 2 && !isNeteaseImpersonatorRidden(artist) {
			nameOnlyArtist = nameOnlyMatch(r.Result.Songs)
		}
	}
	// 专辑锚定兜底(2026-09-01,周杰伦《简单爱 (Live)》/《The One 周杰伦演唱会》案):
	// 四条查询词全部无可信匹配 ≠ 网易云没有这首歌——官方老曲目会被 UGC 翻做/仿冒号从曲目
	// 搜索排名里彻底挤出窗口(实测四条查询词各自的前 30 条里,官方 The One 版一次都没出现,
	// 而 /api/album/18906 的曲目列表里它就躺着,id=186043、自报 273.0s 与本地 273.227s
	// 相差 0.227s,还带 52 行 LRC)。本地专辑名 + 真实时长都已知时,改走"搜专辑
	// (neteaseAlbumIDByName,artistMatches + albumScore>=100 双闸)→ 浏览曲目 → 标题/
	// 歌手闸 + 时长唯一锚定"这条不依赖曲目搜索排名的入口,拿曲目 ID 接回既有的取词/取封面
	// 流程。闸门与 pick() 同强度(见 anchorAlbumTrackForLocalTitle 头注),不是放宽。
	//
	// 为什么不交给 enrich.go 的标题反查轮:那轮确实能找到同一条曲目(title-from-album,
	// 实测 albumDiff=0.227s),但它只把**标题文字**带出来重搜——「简单爱(Live)」跟本地
	// 「简单爱 (Live)」normLoose 相等,重搜轮直接被"纠正后标题没变化"的判据跳过;就算不跳,
	// 拿文字重搜撞的还是同一堵召回墙。ID 在手却只回传文字,正是这条兜底要补的缺口。
	//
	// 成本:仅在"搜索召回已全空 + 本地有专辑名"时多两次网易云请求(搜专辑 + 浏览曲目),
	// 走同一个 neteaseThrottle 节流;durationSecs=0(预取路径)时整档关闭,跟 pick() 的
	// 时长锚定档同一条纪律。
	if chosen == nil && album != "" && durationSecs > 0 {
		if albumID, found := neteaseAlbumIDByName(ctx, artist, album); found {
			if tracks, ok := neteaseAlbumTracks(albumID); ok {
				if t, ok := anchorAlbumTrackForLocalTitle(tracks, artist, title, durationSecs); ok {
					var anchored neSong
					anchored.ID = t.neteaseSongID
					anchored.Name = t.title
					anchored.Album.Name = t.neteaseAlbum
					anchored.Album.ID = albumID
					anchored.Duration = t.duration * 1000 // neSong.Duration 是毫秒
					if t.artist != "" {
						anchored.Artists = make([]struct {
							Name string `json:"name"`
						}, 1)
						anchored.Artists[0].Name = t.artist
					}
					chosen = &anchored
				}
			}
		}
	}
	if chosen == nil {
		if nameOnlyArtist != "" {
			return neteaseInfo{Artist: nameOnlyArtist} // 只拿到统一歌手名用的信号,不给封面/歌词
		}
		return neteaseInfo{} // 三种查询都没可信匹配 → 不给封面,别串错歌
	}
	id := chosen.ID
	info := neteaseInfo{
		SongURL:      fmt.Sprintf("https://music.163.com/song?id=%d", id),
		Title:        chosen.Name,
		Album:        chosen.Album.Name,
		AlbumID:      chosen.Album.ID,
		DurationSecs: chosen.Duration / 1000,
	}
	// 只有本地(Apple Music)标签本身就是单一人名(没有 &/、/, 等分隔符)时,才尝试用
	// NetEase 这条数据统一拼写:pick() 选中候选已经证明其中恰好一位通过 artistMatches 核实
	// 等于本地这唯一一人,复用那次核实结果统一这一位的写法即可。
	// 但如果本地标签本来就是多人合credit(如"Prince & The Revolution"),就完全不碰、
	// 让 lbMeta 原样用本地标签——NetEase 对同一张专辑不同曲目的"合credit拆分"口径本就
	// 不统一(有的单曲只记其中一位),拿这种残缺的单曲级别数据去顶替本地已经写全的多人
	// credit,会悄悄丢人。
	if len(artistCreditParts(artist)) < 2 {
		for _, a := range chosen.Artists {
			if artistMatches(a.Name, artist) {
				info.Artist = a.Name
				break
			}
		}
	}
	var dr struct {
		Songs []struct {
			Album struct {
				PicURL string `json:"picUrl"`
			} `json:"album"`
		} `json:"songs"`
	}
	if err := get(fmt.Sprintf("https://music.163.com/api/song/detail?ids=[%d]", id), &dr); err == nil && len(dr.Songs) > 0 && dr.Songs[0].Album.PicURL != "" {
		// 800 是网易云这个图床实测的真实天花板(2026-08-28,拿两张不同封面各测一轮:
		// 800 给 800,再往上请求 1000/1200/2000 全部被 CDN 静默钳到 800、字节数跟 800
		// 完全相同)。原来写死 600——悬浮歌词窗口那张满幅封面卡是 820px(@2x,QQ 音乐
		// 2026-08-24 那次修复时量出来的),600 拉到 820 是 1.37 倍放大,跟 QQ 当初被
		// 用户报"很模糊"同一个问题,只是没人在网易云这条上报过,顺带一起提到实际上限。
		info.Cover = dr.Songs[0].Album.PicURL + "?param=800y800"
	}
	// 带时间轴的 LRC 歌词，网页跟实时进度条同步高亮滚动。一次老接口就能拿齐原文(lrc)+
	// 中文翻译(tlyric)+罗马音(romalrc)，三者时间轴对齐；逐字(yrc，词级)走 v1 接口、只有
	// 部分歌有。只在确有时间戳时带上；同一首歌各版本歌词相同，选中版本无词时退到其它同名版本。
	fetchBundle := func(songID int64) (lrc, tr, roma string, pureMusic bool) {
		var r struct {
			Lrc struct {
				Lyric string `json:"lyric"`
			} `json:"lrc"`
			Tlyric struct {
				Lyric string `json:"lyric"`
			} `json:"tlyric"`
			Romalrc struct {
				Lyric string `json:"lyric"`
			} `json:"romalrc"`
			// 纯音乐标记,见 neteaseInfo.PureMusic。2026-08-20 补上 —— 在此之前这个字段
			// 压根不在结构体里,信号在解码那一步就丢了。
			PureMusic bool `json:"pureMusic"`
		}
		if err := get(fmt.Sprintf("https://music.163.com/api/song/lyric?id=%d&lv=-1&kv=-1&tv=-1&rv=-1", songID), &r); err != nil {
			return "", "", "", false
		}
		return stripNeteaseEscapedApostrophes(r.Lrc.Lyric),
			stripNeteaseEscapedApostrophes(r.Tlyric.Lyric),
			stripNeteaseEscapedApostrophes(r.Romalrc.Lyric),
			r.PureMusic
	}
	fetchYRC := func(songID int64) string {
		var r struct {
			Yrc struct {
				Lyric string `json:"lyric"`
			} `json:"yrc"`
		}
		if err := get(fmt.Sprintf("https://music.163.com/api/song/lyric/v1?id=%d&yv=-1", songID), &r); err != nil {
			return ""
		}
		if y := stripNeteaseEscapedApostrophes(r.Yrc.Lyric); strings.Contains(y, "[") && len(y) < 40000 {
			return y
		}
		return ""
	}
	info.SongID = id
	lrc, tr, roma, pureMusic := fetchBundle(id)
	// 纯音乐这个结论跟"有没有可用歌词"分开记:占位正文过不了 isTimedLRC,Lyrics 会留空,
	// 而"留空"本身分不出"这首没词"和"没查到词"。见 neteaseInfo.PureMusic。
	info.PureMusic = pureMusic || isInstrumentalPlaceholderLyric(lrc)
	if isTimedLRC(lrc) {
		info.Lyrics = lrc
		if isTimedLRC(tr) {
			info.Trans = tr
		}
		if isTimedLRC(roma) {
			info.Roma = roma
		}
		info.YRC = fetchYRC(id) // 逐字，无则空串，前端退回行级
	}
	return info
}

// neteaseAlbumTracks 按专辑 id 列出这张专辑的全部曲目,给"提前解析同专辑其它曲目"用。
//
// ⚠️ 必须带 Cookie: os=pc。2026-08-14 实测:不带 cookie 时这个端点会**间歇性**返回
// HTTP 200 + body {"code":-462,"message":"请绑定手机后再试哦~"}(9 次里中 5 次,同一个
// 专辑 id 有时通有时不通,是反爬闸门不是"这张专辑要登录");带上之后 9/9 全通。HTTP 状态
// 码始终是 200,所以只看 status 会把拒绝解成"这张专辑零首歌" —— 跟本文件 resolveNeteaseInfo
// 里那个 code 守卫同一个坑,同一个修法。
//
// 备用端点 /api/v1/album/{id} 的 shape 不同(曲目在顶层 songs 而不是 album.songs),两种
// 都吃。网易云是**按端点分桶**限流的(见 resolveNeteaseInfo 里那段注释),主端点被限时
// 备用桶往往还通。
func neteaseAlbumTracks(albumID int64) ([]albumTrack, bool) {
	if albumID <= 0 {
		return nil, false
	}
	cli := &http.Client{Timeout: 6 * time.Second}
	// ⚠️ 两个端点的字段名不一样(2026-09-01 实测 /api/v1/album/18906 坐实):老端点是
	// duration/artists,v1 端点是 dt/ar(id/name 两边一致)。原来只解码 duration/artists,
	// 走 v1 兜底那条路时时长恒为 0、歌手恒为空——bestAlbumTrackByDuration 对时长 <=0 的
	// 曲目直接跳过,等于"主端点被限流时这条兜底整个静默失效",而且表现跟"专辑里没有时长
	// 接近的歌"一模一样,从外面看不出来。两套字段都解,谁有值用谁。
	type neAlbumSong struct {
		ID       int64   `json:"id"`
		Name     string  `json:"name"`
		Duration float64 `json:"duration"` // 毫秒(老端点)
		DT       float64 `json:"dt"`       // 毫秒(v1 端点)
		Artists  []struct {
			Name string `json:"name"`
		} `json:"artists"`
		Ar []struct {
			Name string `json:"name"`
		} `json:"ar"`
	}
	var payload struct {
		Code  int `json:"code"`
		Album struct {
			Name  string        `json:"name"`
			Size  int           `json:"size"`
			Songs []neAlbumSong `json:"songs"`
		} `json:"album"`
		Songs []neAlbumSong `json:"songs"` // /api/v1/album/{id} 把曲目放在顶层
	}
	fetch := func(u string) bool {
		// 这个函数没有 ctx 参数(调用方目前都不需要取消),context.Background() 只用来
		// 让 neteaseThrottle 复用同一套等待/退出逻辑——不可取消。
		//
		// ⚠️ **更正(2026-09-02 当天,实测证伪)**:这里原来写着「这个端点桶如果刚被
		// neteaseReportBlocked 标记过退避,最长可能等到 neteaseBlockCooldown(30s)——这条
		// 路径本来就是后台预取/兜底重试(调用方 retryTitleFromAlbumDetailed 等不阻塞任何
		// 用户可见的同步等待),偶尔多等几十秒不影响体验」。**那个前提是错的**:
		// retryTitleFromAlbumDetailed 正长在用户可见的同步路径上 ——「搜索候选歌词」弹窗
		// 就是它,实测用户盯着转圈等了 150 秒以上,其中约 120 秒是这层退避睡掉的。
		// 退避现在**不睡了**(见 errNeteaseBucketCooling),这里最长仍然只等
		// neteaseMinIntervalBetweenCalls 那一档。
		if err := neteaseThrottle(context.Background(), u); err != nil {
			return false
		}
		req, err := http.NewRequest(http.MethodGet, u, nil)
		if err != nil {
			return false
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		req.Header.Set("Cookie", "os=pc") // 见函数注释,少了它会间歇性被 -462 拦掉
		resp, err := doHTTPTracked(cli, req)
		if err != nil {
			return false
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return false
		}
		payload = struct {
			Code  int `json:"code"`
			Album struct {
				Name  string        `json:"name"`
				Size  int           `json:"size"`
				Songs []neAlbumSong `json:"songs"`
			} `json:"album"`
			Songs []neAlbumSong `json:"songs"`
		}{}
		if json.NewDecoder(resp.Body).Decode(&payload) != nil {
			return false
		}
		// code 非 200/0 一律当失败(-462 就走这里),别把限流解成"零首歌"。
		if payload.Code != 0 && payload.Code != 200 {
			cooldown, streak := neteaseReportRejected(u)
			log.Printf("netease: %s rejected (code %d), backing off %s (这个桶连续第 %d 次被拒)",
				neteaseEndpointBucket(u), payload.Code, cooldown, streak)
			return false
		}
		neteaseReportSuccess(u) // 见 resolveNeteaseInfo 的 get 里同一句的注释
		return true
	}
	if !fetch(fmt.Sprintf("https://music.163.com/api/album/%d", albumID)) {
		if !fetch(fmt.Sprintf("https://music.163.com/api/v1/album/%d", albumID)) {
			return nil, false
		}
	}
	songs := payload.Album.Songs
	if len(songs) == 0 {
		songs = payload.Songs
	}
	if len(songs) == 0 {
		return nil, false
	}
	out := make([]albumTrack, 0, len(songs))
	for _, s := range songs {
		if s.Name == "" {
			continue
		}
		// 合唱曲目 artists 是数组,按 " & " 拼回去 —— 跟本地标签"歌手A & 歌手B"的写法
		// 对齐,别压缩成第一位(压缩会让 enrich 的 key 跟真播到这首歌时算出来的对不上,
		// 预取的结果白存)。
		artists := s.Artists
		if len(artists) == 0 {
			artists = s.Ar // v1 端点的字段名,见 neAlbumSong 注释
		}
		names := make([]string, 0, len(artists))
		for _, a := range artists {
			if a.Name != "" {
				names = append(names, a.Name)
			}
		}
		dur := s.Duration
		if dur <= 0 {
			dur = s.DT // v1 端点的字段名,见 neAlbumSong 注释
		}
		out = append(out, albumTrack{
			title:    s.Name,
			artist:   strings.Join(names, " & "),
			duration: dur / 1000, // 网易云给的是毫秒
			// payload.Album.Name 两种端点 shape 都带(v1 把曲目放顶层,但 album 对象
			// 照样有,2026-09-01 实测 /api/v1/album/18906 核实),这里不用分情况。
			neteaseSongID: s.ID,
			neteaseAlbum:  payload.Album.Name,
		})
	}
	return out, len(out) > 0
}

// neteaseAlbumIDByName 按歌手+专辑名搜网易云的专辑索引(type=10),不依赖任何具体曲目的
// 标题能不能搜到——给 retryTitleFromAlbum 用,专救"整张专辑名对得上、但某一首歌的标题
// 在平台间是意译、文字层面完全无法互认"这种场景,这一步不能像 resolveNeteaseInfo 那样
// 靠曲目搜索间接带出专辑,必须直接搜专辑本身。
//
// 跟 resolveNeteaseInfo 的 get 闭包同一个理由,同一个修法(2026-08-28 实测坐实:开发这个
// 函数当天就把自己测出了限流——网易云限流照样回 HTTP 200,拒绝写在 body 的 code 字段里,
// 只看 HTTP 状态码会把"这次被限流了"解成"这张专辑网易云真的没有",而且是**按端点分桶**
// 限流,同一时刻换 /api/search/get 往往还通):按端点分桶重试一次,body code 非
// 200/0 一律当失败,不当"零张专辑"。
func neteaseAlbumIDByName(ctx context.Context, artist, album string) (int64, bool) {
	// 2026-08-30 真实bug(温岚《夏日の風》= 网易云《夏天的风》):本地艺人标签有时自带
	// 括号里的罗马化别名(如 YouTube Music 给的"溫嵐 (Landy Wen)"),整串原样拼进搜索词
	// 会把网易云的模糊搜索带偏、专辑一条都搜不到——跟 retryTitleFromArtistSearch 早就在
	// 用的"stripParens(title)"是同一个坑、同一个修法,只是这里之前漏了对 artist 也做。
	// 后面 artistMatches 那道身份核验闸不受影响:它自己已经有 stripParens 的兜底分支
	// (专治这类"主名(外文别名)"形态),核验用的仍然是完整的原始 artist,不受这里影响。
	q := stripParens(artist) + " " + album
	get := func(u string) (int64, bool, bool) { // (albumID, found, requestSucceeded)
		if err := neteaseThrottle(ctx, u); err != nil {
			return 0, false, false
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return 0, false, false
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := doHTTPTracked(&http.Client{Timeout: 4 * time.Second}, req)
		if err != nil {
			return 0, false, false
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return 0, false, false
		}
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return 0, false, false
		}
		var probe struct {
			Code int `json:"code"`
		}
		if err := json.Unmarshal(body, &probe); err == nil && probe.Code != 0 && probe.Code != 200 {
			// 限流/拒绝,不是"零张专辑"。跟 resolveNeteaseInfo 的 get 同一份处理:
			// 记日志 + 指数退避这个端点桶,405 时额外记具体原因(见那边注释)。
			cooldown, streak := neteaseReportRejected(u)
			log.Printf("netease: %s rejected (code %d), backing off %s (这个桶连续第 %d 次被拒)",
				neteaseEndpointBucket(u), probe.Code, cooldown, streak)
			if probe.Code == 405 {
				neteaseSetLastFailureReason(lyricFailureReasonNeteaseRateLimited)
			}
			return 0, false, false
		}
		neteaseReportSuccess(u) // 见 resolveNeteaseInfo 的 get 里同一句的注释
		var out struct {
			Result struct {
				Albums []struct {
					ID     int64  `json:"id"`
					Name   string `json:"name"`
					Artist struct {
						Name string `json:"name"`
					} `json:"artist"`
				} `json:"albums"`
			} `json:"result"`
		}
		if err := json.Unmarshal(body, &out); err != nil {
			return 0, false, false
		}
		// 2026-08-30 真实bug(方大同「Lovers Policy」专辑"15"案):以前是"扫到第一条满足
		// 门槛(>=100)的专辑就收工",而网易云的搜索排名不保证精确同名的排在前面——搜"方大同
		// 15"时,《15 香港演唱会(2011Live)》排在了正好叫《15》的录音室专辑前面,两者的
		// albumScore 都够门槛(前者是"字符串包含"档 100,后者是"完全同名"档 200,但"第一条
		// 满足门槛就收工"从不比较、只看谁先出现),于是浏览曲目时进的是演唱会专辑,配出来的
		// 是那首歌的 Live 版而不是录音室版(分数因此长期偏低,287 分——这个异常偏低本身就是
		// 信号,只是这里第一次真正查到根子上)。改成扫完这一页全部结果、取 albumScore **最高**
		// 的那个,同分才按到达顺序决胜——跟 bestAlbumTrackByDuration"不是谁先到就信谁,而是
		// 比谁更贴切"是同一个原则。
		bestID := int64(0)
		bestScore := -1
		for _, a := range out.Result.Albums {
			if !artistMatches(a.Artist.Name, artist) {
				continue
			}
			s := albumScore(a.Name, album)
			if s >= 100 && s > bestScore {
				bestID, bestScore = a.ID, s
			}
		}
		if bestID != 0 {
			return bestID, true, true
		}
		return 0, false, true // 请求成功、确实没有匹配的专辑
	}
	const query = "?type=10&limit=5&s="
	if id, ok, succeeded := get(neteaseSearchEndpointPrimary + query + neturl.QueryEscape(q)); succeeded {
		return id, ok
	}
	id, ok, _ := get(neteaseSearchEndpointFallback + query + neturl.QueryEscape(q))
	return id, ok
}

// retryTitleFromAlbumMaxDurationDiffSecs 故意卡得很紧:这是**唯一**一处纯粹依赖时长做
// 身份判定、完全不借助任何文字信号的匹配,专辑内两首不同的歌时长凑巧接近并非不可能,
// 容差每放宽一秒,错配的风险都在涨,不能像别的地方那样给几秒钟余量。
const retryTitleFromAlbumMaxDurationDiffSecs = 2.0

// retryTitleFromAlbum 是"标题彻底搜不到、但本地专辑名已知"时的最后一道兜底——有些歌在
// 不同平台间是**意译**标题(不是音译/直译/加括号注释这类常见的写法差异),文字层面完全
// 无法互认。2026-08-28 真实案例:Khalil Fong《Revisited》= 网易云《回留》,同一张专辑
// 《梦想家 The Dreamer》,时长精确到毫秒吻合(236.344s vs 236.343s),但两个标题连一个
// 字都不共享,任何基于文字的匹配(含 searchTitleVariants/知名艺人别名表那类思路)都碰不到。
//
// 只在网易云上做——QQ/酷狗都没有"按专辑名直接搜出专辑再浏览全部曲目"这条可靠入口(QQ 的
// 单曲详情接口只能查已知某首歌的专辑内序号,没有反过来"按专辑名搜专辑"的公开接口;酷狗
// 搜索结果连专辑内序号字段都没有,2026-08-28 调研过)。查到网易云自己认定的标题后,回喂给
// enrich.go 的 scoredLyricCandidatesStreaming 重新查一遍全部源——已验证这首歌在 QQ/酷狗
// 上同样是收录在"回留"这个标题下,只是搜索引擎按"Revisited"完全查不到,不是三个平台都
// 没收录这首歌。
//
// 两首歌时长同样接近、分不出该是哪首时返回空,宁可不给也不猜。
func retryTitleFromAlbum(ctx context.Context, artist, album string, durationSecs float64) string {
	title, _, _ := retryTitleFromAlbumDetailed(ctx, artist, album, durationSecs)
	return title
}

// retryTitleFromAlbumDetailed 同 retryTitleFromAlbum,多带回命中时的时长误差——见
// bestAlbumTrackByDurationDetailed 头注,给 enrich.go 裁决"这条兜底 vs retryTitleFromArtistSearch
// 谁更可信"用。
func retryTitleFromAlbumDetailed(ctx context.Context, artist, album string, durationSecs float64) (title string, diff float64, ok bool) {
	if album == "" || durationSecs <= 0 {
		return "", 0, false
	}
	albumID, found := neteaseAlbumIDByName(ctx, artist, album)
	if !found {
		return "", 0, false
	}
	tracks, found := neteaseAlbumTracks(albumID)
	if !found {
		return "", 0, false
	}
	return bestAlbumTrackByDurationDetailed(tracks, durationSecs)
}

// retryTitleFromArtistSearch 是 retryTitleFromAlbum 找不到时的第二道兜底——专救"本地专辑名
// 对应的网易云专辑,收的不是目标那次录音"的情况。2026-08-29 真实案例:陶喆《Airport in
// 10:30》,本地专辑标"乐之路",网易云上名字对得上的是精选集《Ultrasound 乐之路
// 1997-2003》(albumScore 判定为同一张不成问题),但精选集里收录的《飞机场的10:30》是
// 295.314s 的重制/精选版,跟本地文件真正对应的原版录音(280.773s,收在同名专辑《陶喆》
// 里,专辑名跟本地标签完全对不上、albumTracks 那条路径根本摸不到)差了 14 秒多,超出
// bestAlbumTrackByDuration 的容差——retryTitleFromAlbum 因此正确地"宁可不给也不猜",
// 返回空,但这首歌其实是有救的。
//
// 不按专辑找,直接拿"歌手+本地标题"去网易云曲库搜索(跟 resolveNeteaseInfo 用的是同一个
// 搜索入口),对搜索结果按歌手过滤后复用 bestAlbumTrackByDuration 判定——这就是为什么
// 前面 pick()/lyricTitleAccepted 会漏掉这条候选而这里不会:lyricTitleAccepted 是纯文字
// 比较(《飞机场的10:30》跟《Airport in 10:30》一个字都不共享),但 NetEase 的全文搜索
// 引擎本身認得英文译名/关键词(该曲目自带 transNames:["Airport at 10:30"]),照样能把
// 正确的那首曲子排进搜索结果——只是排进来之后过不了纯文字的 accept 闸。这里绕开那道闸,
// 复用本文件里另一处例外的纯时长判据(同一个 bestAlbumTrackByDuration,同一份 2 秒容差、
// 同一份"两首同样接近就拒绝"守卫),不重新发明一套判定。
//
// 只按"歌手对上"过滤——不比标题文字(那正是绕不过 lyricTitleAccepted 的原因),所以极度
// 依赖 bestAlbumTrackByDuration 的严格容差 + 排歧义守卫兜底;传入的 artist 必须是调用方已经
// 做过别名解析的那个(如"陶喆"而不是"David Tao"),否则 artistMatches 直接判不上、白搜。
func retryTitleFromArtistSearch(ctx context.Context, artist, title string, durationSecs float64) string {
	found, _, _ := retryTitleFromArtistSearchDetailed(ctx, artist, title, durationSecs)
	return found
}

// retryTitleFromArtistSearchDetailed 同 retryTitleFromArtistSearch,多带回命中时的时长
// 误差——见 bestAlbumTrackByDurationDetailed 头注。
func retryTitleFromArtistSearchDetailed(ctx context.Context, artist, title string, durationSecs float64) (found string, diff float64, ok bool) {
	if artist == "" || title == "" || durationSecs <= 0 {
		return "", 0, false
	}
	// stripParens(artist):同 neteaseAlbumIDByName 头注,本地艺人标签自带的罗马化别名
	// 括号(如"溫嵐 (Landy Wen)")原样拼进搜索词会带偏网易云的模糊搜索。
	q := stripParens(artist) + " " + stripParens(title)
	type neSearchSong struct {
		Name     string  `json:"name"`
		Duration float64 `json:"duration"`
		Artists  []struct {
			Name string `json:"name"`
		} `json:"artists"`
	}
	get := func(u string) ([]albumTrack, bool) { // (candidates, requestSucceeded)
		if err := neteaseThrottle(ctx, u); err != nil {
			return nil, false
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return nil, false
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := doHTTPTracked(&http.Client{Timeout: 4 * time.Second}, req)
		if err != nil {
			return nil, false
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, false
		}
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, false
		}
		var probe struct {
			Code int `json:"code"`
		}
		// 跟本文件其它两处网易云调用同一个理由:限流照样回 HTTP 200,拒绝写在 body 的 code
		// 里,不能当成"零条搜索结果"。记日志 + 退避这个端点桶,405 时额外记具体原因
		// (见 resolveNeteaseInfo 的 get 那段注释)。
		if err := json.Unmarshal(body, &probe); err == nil && probe.Code != 0 && probe.Code != 200 {
			cooldown, streak := neteaseReportRejected(u)
			log.Printf("netease: %s rejected (code %d), backing off %s (这个桶连续第 %d 次被拒)",
				neteaseEndpointBucket(u), probe.Code, cooldown, streak)
			if probe.Code == 405 {
				neteaseSetLastFailureReason(lyricFailureReasonNeteaseRateLimited)
			}
			return nil, false
		}
		neteaseReportSuccess(u) // 见 resolveNeteaseInfo 的 get 里同一句的注释
		var out struct {
			Result struct {
				Songs []neSearchSong `json:"songs"`
			} `json:"result"`
		}
		if err := json.Unmarshal(body, &out); err != nil {
			return nil, false
		}
		tracks := make([]albumTrack, 0, len(out.Result.Songs))
		for _, s := range out.Result.Songs {
			if s.Name == "" {
				continue
			}
			matched := false
			for _, a := range s.Artists {
				if artistMatches(a.Name, artist) {
					matched = true
					break
				}
			}
			if !matched {
				continue
			}
			tracks = append(tracks, albumTrack{title: s.Name, artist: artist, duration: s.Duration / 1000})
		}
		return tracks, true
	}
	const query = "?type=1&limit=30&s="
	tracks, reqOK := get(neteaseSearchEndpointPrimary + query + neturl.QueryEscape(q))
	if !reqOK {
		tracks, reqOK = get(neteaseSearchEndpointFallback + query + neturl.QueryEscape(q))
		if !reqOK {
			return "", 0, false
		}
	}
	return bestAlbumTrackByDurationDetailed(topSearchRanked(tracks, retryTitleFromArtistSearchMaxRank), durationSecs)
}

// retryTitleFromArtistSearchMaxRank:泛搜回来的 30 条里,只有**排名最靠前的这几条**够格
// 交给纯时长判据。2026-09-02 修的真实 bug(打上花火 → 春雷 案)。
//
// 病灶:这条兜底刻意不看标题文字(理由见 retryTitleFromArtistSearch 头注),判据只剩
// "歌手对得上 + 时长差 < 2s"。而搜索词是"歌手 + 本地标题",标题一个字都没命中时,搜索
// 引擎返回的就是**这个歌手的曲库**——30 条里总能矬出一首时长凑巧接近的,于是纯时长判据
// 从"在几个相关候选里挑对的那个"退化成"在整个曲库里抽签"。
//
// 用户实例:DAOKO×米津玄師《打上花火》(本地 289.334s)。搜"米津玄师 Uchiagehanabi"回来
// 30 条,落在 2s 容差内的有四条,判据挑了误差最小的《春雷》(288.949s,差 0.385s)——完全
// 另一首歌,整屏歌词都是错的。而它在搜索结果里排**第 12 名**。
//
// 排名恰好是这里缺的那个信号,实测三个案例分得干干净净(2026-09-02 各真查一次网易云):
//
//	查询                        纯时长会选的        它的排名   对错
//	米津玄师 Uchiagehanabi       春雷               第 12 名   ✗ 错(另一首歌)
//	方大同 Love Love Love        爱爱爱             第  2 名   ✓ 对
//	陶喆 Airport in 10:30        飞机场的10:30      第  1 名   ✓ 对
//
// 后两个正是这条兜底存在的理由(见 retryTitleFromArtistSearch 头注和 enrich.go 里那段
// "两条兜底谁更可信"),它们都靠**搜索引擎认得那个标题**才排到最前面;而排到第 12 名
// 说明引擎压根没把它跟标题关联起来,那一条纯粹是"同歌手 + 时长撞车"。取 5 是给已知的
// 最差正例(第 2 名)留一倍余量,同时离错例(第 12 名)还差得远。
//
// ⚠️ 只对这条**泛搜**路径生效,不能下放进 bestAlbumTrackByDurationDetailed:另一个调用方
// retryTitleFromAlbum 喂进去的是"某张专辑的完整曲目表",那里的顺序是曲序、不是相关性
// 排名,截断前几条等于随机丢掉后半张专辑。
//
// ⚠️ 排名是**过滤掉非本歌手之后**的名次(get 里的 artistMatches 那道闸先跑)。这只会让
// 名次更靠前、不会更靠后,对上面那张表的结论只增不减。
//
// 另外核实过、但**没有**采用的一条修法:把网易云搜索结果里的 alias/transNames 取回来当
// 文字佐证。字段确实有(《飞机场的10:30》正是靠 transNames:["Airport at 10:30"] 成立的),
// 但《爱爱爱》两个字段**全空**——做成硬闸会把 2026-08-30 刚修好的那个案例重新打死。
const retryTitleFromArtistSearchMaxRank = 5

// topSearchRanked 取前 n 条(不足就全给)。单独拆出来是为了让上面那条判据能被断言覆盖。
func topSearchRanked(tracks []albumTrack, n int) []albumTrack {
	if n <= 0 || len(tracks) <= n {
		return tracks
	}
	return tracks[:n]
}

// bestAlbumTrackByDuration 是 retryTitleFromAlbum 的判据部分,拆出来是为了能不发真实网络
// 请求就对这条纯时长匹配逻辑写断言(跟 t2s.go/musicbrainz.go 里同类"网络函数拆出纯判据"
// 的做法一致)。两首**不同**歌时长同样接近、分不出该是哪首时返回空,宁可不给也不猜。
//
// ⚠️ 2026-08-30 修的真实 bug(方大同「Love Love Love」= 「爱爱爱」案):retryTitleFromArtistSearch
// 是泛搜"歌手+本地标题",同一首歌被不同专辑/合辑重复收录是常态——"爱爱爱"这首歌当时就在
// 候选列表里出现了两次(专辑《爱爱爱》和合辑《The Soulboy Collection》各一条),时长分毫不差
// (213.266s,本地时长 213s)。旧逻辑一见到"第二条一样近"就无条件判 ambiguous、整体弃权,
// 于是这条本该毫无疑问的正确答案被判成"分不清是哪首"而白白丢弃,回退到 retryTitleFromAlbum
// 那条从错误专辑里找出的《春风吹 (Live)》(时长凑巧也在容差内,但根本是另一首歌)。
// 真正的歧义只发生在"两个不同标题"打平的时候——同一个标题出现多次(同一首歌被反复收录）
// 不构成歧义,不该拖累判定。
func bestAlbumTrackByDuration(tracks []albumTrack, durationSecs float64) string {
	title, _, ok := bestAlbumTrackByDurationDetailed(tracks, durationSecs)
	if !ok {
		return ""
	}
	return title
}

// bestAlbumTrackByDurationDetailed 是 bestAlbumTrackByDuration 的完整版本,多带回命中时的
// 时长误差(diff,秒)——2026-08-30 加,给 enrich.go 那处"泛搜 vs 按专辑名浏览,两条兜底
// 都给出候选时,谁更可信"的裁决用:光看"有没有返回"不够,retryTitleFromAlbum(方大同
// 「Singer and Model」案:泛搜排名进不了前 30,只有按专辑浏览才能摸到「歌手与模特儿」,
// 时长误差 0.0005s)和 retryTitleFromArtistSearch(方大同「Love Love Love」案:按专辑名找到
// 的是错误专辑里的《春风吹》,泛搜反而在结果第一条就搜到真正对的《爱爱爱》,误差 0.266s)
// 各自都真实证明过"我更准"的案例,谁先跑、谁的结果就被无条件采纳这个旧逻辑必然在另一个
// 案例上出错——必须两条都跑、比谁的 diff 更小,而不是"谁先成功就用谁"。
// anchorAlbumTrackForLocalTitle 在"浏览专辑全部曲目"的结果里,为本地曲目锚定唯一对应的
// 网易云曲目(带 neteaseSongID,给 resolveNeteaseInfo 的专辑锚定兜底按 ID 直取歌词用)。
//
// 跟 bestAlbumTrackByDurationDetailed 的分工:那个是**纯时长**判据(给标题反查用——标题
// 在平台间是意译时文字信号本来就不可用,只能赌时长,所以容差卡到 2 秒都嫌松);这里恰恰
// 相反,产出的是完整歌词候选,闸门必须与 pick() 同强度——lyricTitleAccepted + artistMatches
// (曲目 artist 为空时跳过歌手闸:专辑记录本身已在 neteaseAlbumIDByName 里按歌手核验过)
// 先把关,时长只负责在同名多版本里挑对那一个。容差沿用同一个常量:这里文字闸都在,理论上
// 可以更宽,但没有真实案例证明需要,先不另开一个数值。
//
// 同误差出现两个标题不同的曲目时判有歧义、整体放弃(宁可没有,也不要错,跟
// bestAlbumTrackByDurationDetailed 同一个原则)。
func anchorAlbumTrackForLocalTitle(tracks []albumTrack, artist, title string, durationSecs float64) (albumTrack, bool) {
	var best albumTrack
	bestDiff := math.Inf(1)
	found := false
	ambiguous := false
	for _, t := range tracks {
		// neteaseSongID<=0 = 不是 neteaseAlbumTracks 填的(Apple 本地资料库/搜索结果
		// 两条来源都不带 ID),这条兜底拿它没用。
		if t.neteaseSongID <= 0 || t.title == "" || t.duration <= 0 {
			continue
		}
		if !lyricTitleAccepted(t.title, title) {
			continue
		}
		if t.artist != "" && !artistMatches(t.artist, artist) {
			continue
		}
		d := math.Abs(t.duration - durationSecs)
		if d > retryTitleFromAlbumMaxDurationDiffSecs {
			continue
		}
		switch {
		case d < bestDiff:
			best, bestDiff, found, ambiguous = t, d, true, false
		case d == bestDiff && normLoose(t.title) != normLoose(best.title):
			ambiguous = true
		}
	}
	if !found || ambiguous {
		return albumTrack{}, false
	}
	return best, true
}

// bestAlbumTrackAmbiguityMarginSecs:亚军(**标题跟冠军不同**的那些候选里最接近的一个)
// 跟冠军的误差差距小于这个值,就判"分不出是哪首"、整体弃权。
//
// 2026-09-02 加。在此之前这道守卫写的是 `d == bestDiff` —— **浮点精确相等**,两首不同的歌
// 时长差要 bit 级完全一样才会触发,等于这道守卫从来没生效过。它不是被写坏的,是随
// 2026-08-30 那次修改(把"任何第二条一样近都算歧义"收紧成"只有标题不同才算歧义",见
// bestAlbumTrackByDuration 头注那个《爱爱爱》案)顺手留下的:那次要修的是"同一首歌被反复
// 收录不该算歧义",标题判据加对了,但打平判据仍旧沿用了精确相等。
//
// 0.5s 的来历:容差本身是 2s,而"两首不同的歌时长差在半秒以内"已经完全在纯时长判据分辨
// 不了的范围里了。取值刻意保守——这道守卫的方向是**弃权**,而弃权只是"这轮兜底不出结果",
// 上层还有别的候选源兜着,代价远小于给出一首错歌。
const bestAlbumTrackAmbiguityMarginSecs = 0.5

func bestAlbumTrackByDurationDetailed(tracks []albumTrack, durationSecs float64) (title string, diff float64, ok bool) {
	best := ""
	bestDiff := math.Inf(1)
	// runnerDiff:跟当前冠军**标题不同**的候选里,最接近的那个的误差。同名重复(同一首歌
	// 被不同专辑/合辑反复收录)不进这里 —— 那正是 2026-08-30 那次要保住的东西。
	runnerDiff := math.Inf(1)
	for _, t := range tracks {
		if t.title == "" || t.duration <= 0 {
			continue
		}
		d := math.Abs(t.duration - durationSecs)
		if d > retryTitleFromAlbumMaxDurationDiffSecs {
			continue
		}
		switch {
		case d < bestDiff:
			// 冠军被换掉时,旧冠军**降级成亚军候选**——不这么做的话,先出现的那条会被
			// 静默忘掉,守卫又会退化成只看"最后一次打平"。
			if best != "" && normLoose(best) != normLoose(t.title) && bestDiff < runnerDiff {
				runnerDiff = bestDiff
			}
			best, bestDiff = t.title, d
		case normLoose(t.title) != normLoose(best) && d < runnerDiff:
			runnerDiff = d
		}
	}
	if best == "" {
		return "", 0, false
	}
	if runnerDiff-bestDiff <= bestAlbumTrackAmbiguityMarginSecs {
		return "", 0, false
	}
	return best, bestDiff, true
}
