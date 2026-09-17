package main

import (
	"encoding/json"
	"log/slog"
	"os"
	"sort"
	"sync"
	"time"
)

// 「全量重新扫库」——把整个歌词库按**当前**打分规则重过一遍,而不是等每首歌各自被播到。
//
// ## 为什么补空扫描不够
//
// lyricsfillsweep.go 那一轮只收「一条歌词都没有」的条目(本机 104 首)。库里真正的大头是
// **已经有词、但那份词是按早就作废的打分规则选出来的**:实测本机 5514 条里
// 5472 条(99.2%)的 lyrics_scoring_version 落后于当前的 v19,版本分布从 v0 一直摊到 v18
// (v6 1266 条、v15 1476 条……)。收编它们的是 rescoreLyrics,而它的触发点
// (needsLyricsRescore)跟补空一样挂在"这首歌又被播到"那一刻——一个几千首的库靠自然播放
// 追平算法版本,要走好几年。
//
// ## 每条做什么
//
// 分两支,不是一视同仁:
//   - 没词的走 retryLyricsUpgrade(firstFill=true),跟补空扫描**同一个函数**;
//   - 有词的走 rescoreLyrics。刻意**不**用 retryLyricsUpgrade:那条是"新分严格更高才换",
//     而跨打分版本的分数根本不可比(v3 给同一份候选普遍多算几百分,见 lyricsUpgradeBaseline
//     的头注),拿它来比大小这道闸形同虚设。rescoreLyrics 是版本感知的、压根不比大小,
//     只问"按今天的规矩重选一次是谁",正是这件事该用的动作。
//
// ## 挑哪些、什么顺序(收益递减的三层)
//
// 全量是真的全量,但**顺序**按预期收益排,好让用户中途停掉时留下的是最值钱的那部分:
//  1. 没词 / 只有纯文本兜底——补空扫描的那批,最可能从无到有;
//  2. 有词但没逐字——唯一可能"升一档成色"的一批(本机 397 条);
//  3. 有逐字、只是打分版本落后——"全量"字面上的那批(本机 4971 条),收益最薄:逐字本来
//     就是这套打分里的天花板(+400),重选多半选回同一份;真正能修的是版本/译文选错那种。
//
// 已经是逐字**且**版本已经追平的条目一条都不碰:同一套规则重跑一遍必然得出同一个结论,
// 那是纯粹的白烧网络。这也让"跑完一轮之后再点一次"天然变成一次几乎为空的扫描——按钮上
// 那个数会随着追平自己缩下去,不需要额外的"已经扫过"账本。
//
// ## 三道硬闸(比补空扫描多一道)
//
// 手改过的(ManualLyrics)、确证纯音乐的(Instrumental)、正在飞的(enrichInflight)——同
// 补空扫描;**外加已校准时间轴的(lyricsPinned)**。补空那边不需要这一道:它只碰没词的条目,
// 没词就没有校正值可作废。这里的第 2、3 层全是有词条目,换一份歌词就等于把用户一句句听出来
// 的几百毫秒当场作废(见 lyricspins.go 头注),这道闸缺不得。
//
// 「自动跟进算法升级」那个开关(features.LyricsAutoUpgrade)**不管这条路径**:它管的是
// needsLyricsRescore / needsLyricsRetry 这些自动路径,features.go 里那句"用户手动重搜都不受
// 它管"是既定口径,全量扫库是用户点出来的,同理。
//
// ## 跨重启续跑
//
// 这一轮要跑多久:本机 5472 条 × (15 秒间隔 + 每条一轮全源搜索),一天半到两天。这个量级里
// collector 一定会重启好几次(改设置会触发 reload、装新版、机器重启),所以"进程死了就从头
// 再来"等于这个功能不成立。
//
// 续跑不需要断点账本——**进度本身就存在数据里**:每条跑完 lyrics_scoring_version 就被推到
// 当前版本,下次重新算候选时它自然不在列表里了,候选集合单调收缩。所以只需要一个开关文件
// 记住"有一轮全量还没跑完",启动时看见就接着跑。
//
// 开关的清除点刻意**不**放在扫描循环的出口:那里分不清"用户按了停止"和"进程正在关机"
// (两者都表现为 ctx 被取消),放在那里会让每次重启都把待续的标记擦掉。清除只发生在两处:
// 跑完整份候选列表,以及 cancelLyricsFillSweep(用户按停止那条路)。进程被杀不经过任何一处,
// 标记留在盘上,下次启动续跑。
//
// ## 跟补空扫描共用一条通道
//
// 请求文件多认一个动词 "full",状态文件多一个 full 字段,其余(单轮互斥、取消、进度上报、
// 15 秒间隔)全部复用 lyricsfillsweep.go 那一套,不另起一条并行通道——两条通道并存就会有
// "两轮同时在跑、抢同一批 enrichInflight 和同一个源的限流额度"这种没人想调的 bug。

// lyricsFullScanStatePath 这份状态文件同时干两件事:
//   - 记住"有一轮全量还没跑完"(Active),供启动时续跑;
//   - 把 lyricsScoringVersion 这个常量公布给 App —— 界面要显示「N 首待跟进」就得知道
//     当前版本号是几,而那个常量住在 Go 这边。App 不认识这个文件时只是显示不出这个数,
//     不影响任何既有功能。
var (
	lyricsFullScanStatePath string
	lyricsFullScanMu        sync.Mutex
)

type lyricsFullScanState struct {
	// ScoringVersion:写这份文件时 collector 的 lyricsScoringVersion。
	ScoringVersion int `json:"scoringVersion"`
	// Active:有一轮全量扫库还没跑完(被进程退出打断),下次启动应当续跑。
	Active bool `json:"active"`
	// StartedAt:这一轮**最初**是什么时候被请求的(续跑不刷新它),给界面显示用。
	StartedAt int64 `json:"startedAt,omitempty"`
	UpdatedAt int64 `json:"updatedAt"`
	// SecondsPerTrack:每首歌的粗略耗时估计,给界面说一句「预计约 N 小时」用
	//。
	//
	// 跟 ScoringVersion 同一个理由:这个数由 collector 侧的常量决定
	// (lyricsFullScanGap + 一轮全源搜索),**App 不能自己写死一份**。此前界面里就硬编码着
	// 25 秒、注释写着「15 秒固定间隔(lyricsFillSweepGap)」,而全量改用
	// lyricsFullScanGap(5 秒)之后那句话和那个数当场都成了错的 —— 没有任何东西会报错,
	// 只是用户看到的预计时长凭空多出一倍。
	SecondsPerTrack int `json:"secondsPerTrack,omitempty"`
}

// lyricsFullScanSearchEstimate:一首歌那一轮全源搜索的粗略耗时。
//
// 8 秒是换 gap 之后**实测修正过**的值,别按"搜索很快"的直觉往回调。
//
// ⚠️ 别按 5 秒估("gap 15 秒时每首 18 秒 → 搜索 3 秒"那种小样本、又恰好是简单的歌);
// gap 换成 5 秒后实测 **15.9 秒/首**,反推搜索约 11 秒 —— 差了三倍多。差距来自扫描的
// 分层顺序:最先跑的 tier 0 是"一条歌词都没有"的那批,要把所有源加别名轮全遍历一遍,最慢;
// 后面 tier 2(本机 4900+ 首,只是打分版本旧)会快得多。取 8 秒是这两端之间的一档。
//
// 只用于界面那句"预计约 N 小时",不参与任何调度判断;而且跑起来之后界面会改用**这一轮的
// 实测速度**外推(见 LyricsLibraryStats.remainingText),这个常量只影响还没点「开始」那一刻。
const lyricsFullScanSearchEstimate = 8 * time.Second

// lyricsFullScanSecondsPerTrack 是上面两个常量的和,取整到秒。抽出来是为了让单测能钉住
// 「界面拿到的数必须跟真实 gap 对得上」这条,而不是又一次靠人去记得同步两个地方。
func lyricsFullScanSecondsPerTrack() int {
	return int((lyricsFullScanGap + lyricsFullScanSearchEstimate) / time.Second)
}

// setLyricsFullScanStatePath 由 setLyricsFillPaths 调用。
//
// ⚠️ 跟隔壁那两份不一样,这份文件**启动时绝不能删** —— 它整个存在的意义就是跨进程活着。
// 这里只把当前的打分版本号刷进去(Active 原样保留)。
func setLyricsFullScanStatePath(path string) {
	lyricsFullScanMu.Lock()
	lyricsFullScanStatePath = path
	lyricsFullScanMu.Unlock()
	state := readLyricsFullScanState()
	state.ScoringVersion = lyricsScoringVersion
	state.SecondsPerTrack = lyricsFullScanSecondsPerTrack()
	writeLyricsFullScanState(state)
}

func readLyricsFullScanState() lyricsFullScanState {
	lyricsFullScanMu.Lock()
	path := lyricsFullScanStatePath
	lyricsFullScanMu.Unlock()
	if path == "" {
		return lyricsFullScanState{}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return lyricsFullScanState{}
	}
	var state lyricsFullScanState
	// 解析失败一律当"没有待续的一轮":这份文件坏了最坏的后果是少续一次跑(用户再点一下
	// 就好),而把坏文件当成 Active=true 会让每次启动都自动开一轮几十小时的全库联网扫描。
	if err := json.Unmarshal(data, &state); err != nil {
		return lyricsFullScanState{}
	}
	return state
}

func writeLyricsFullScanState(state lyricsFullScanState) {
	lyricsFullScanMu.Lock()
	path := lyricsFullScanStatePath
	lyricsFullScanMu.Unlock()
	if path == "" {
		return
	}
	state.UpdatedAt = time.Now().Unix()
	data, err := json.Marshal(state)
	if err != nil {
		return
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		slog.Warn("lyrics full scan: state write failed", "err", err)
	}
}

// lyricsFullScanActive:盘上记着有一轮全量还没跑完吗。
func lyricsFullScanActive() bool {
	return readLyricsFullScanState().Active
}

// setLyricsFullScanActive 置/清"待续"标记。置上时顺带记下起始时刻(已经在跑的那一轮不刷新,
// 续跑要显示的是最初点下去的时间)。
func setLyricsFullScanActive(active bool) {
	state := readLyricsFullScanState()
	if state.Active == active {
		return
	}
	state.Active = active
	state.ScoringVersion = lyricsScoringVersion
	state.SecondsPerTrack = lyricsFullScanSecondsPerTrack()
	if active {
		state.StartedAt = time.Now().Unix()
	} else {
		state.StartedAt = 0
	}
	writeLyricsFullScanState(state)
}

// lyricsFullScanTier 给一条缓存分层,-1 = 这一轮不碰它。分层规则见文件头注。
// 纯函数(pin 由调用方查好传进来),单测直接钉。
func lyricsFullScanTier(e enrichEntry, pinned, inflight bool) int {
	if e.ManualLyrics || e.Instrumental || pinned || inflight {
		return -1
	}
	switch {
	case e.Lyrics == "":
		return 0
	case e.LyricsYRC == "":
		return 1
	case e.LyricsScoringVersion < lyricsScoringVersion:
		return 2
	}
	return -1
}

// lyricsFullScanCandidates 挑这一轮要过的 key:三层各自按字典序排好(确定、可复现),
// 再按层拼接 —— 中途停掉时留下的是收益最高的那部分。
func lyricsFullScanCandidates() []string {
	// pin 快照必须在拿 enrichMu **之前**取:它要读文件,不能把几千条的循环连同一次 Stat
	// 一起压在缓存锁里(见 lyricsPinnedKeys 头注)。
	pins := lyricsPinnedKeys()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	var tiers [3][]string
	for key, e := range enrichCache {
		tier := lyricsFullScanTier(e, pins[key], enrichInflight[key])
		if tier < 0 {
			continue
		}
		tiers[tier] = append(tiers[tier], key)
	}
	keys := make([]string, 0, len(tiers[0])+len(tiers[1])+len(tiers[2]))
	for i := range tiers {
		sort.Strings(tiers[i])
		keys = append(keys, tiers[i]...)
	}
	return keys
}

// lyricsFullScanOne 对一条跑一次,返回内容有没有真的变过。
//
// 进门再核一遍资格,理由同 lyricsFillSweepOne:挑候选到轮到它可能隔了几十小时,期间它可能
// 被播到(自己升级过了)、被用户手改/删除/校准。
func lyricsFullScanOne(key string) bool {
	artist, title, album := splitEnrichKey(key)
	enrichMu.Lock()
	before, ok := enrichCache[key]
	if !ok || before.ManualLyrics || before.Instrumental || enrichInflight[key] {
		enrichMu.Unlock()
		return false
	}
	enrichMu.Unlock()
	// 没词的整条交给补空那支:写回规则(升级/纯音乐标记/纯文本兜底/退避账)全在那边,
	// 这里一个字都不重写。它自己会重新取锁、重新核资格。
	if before.Lyrics == "" {
		return lyricsFillSweepOne(key)
	}
	if lyricsPinned(key) {
		return false
	}
	duration := before.ResolvedDurationSecs
	if duration <= 0 {
		duration = before.DurationSecs
	}
	enrichMu.Lock()
	// 重新确认没被别人抢走 —— 上面那段解锁期间可能有播放侧的后台任务插进来。
	if enrichInflight[key] {
		enrichMu.Unlock()
		return false
	}
	enrichInflight[key] = true
	enrichMu.Unlock()
	// 同步跑:rescoreLyrics 自己 defer 清 enrichInflight,并负责落盘/导出/通知重推。
	rescoreLyrics(key, artist, title, album, duration)
	enrichMu.Lock()
	after := enrichCache[key]
	enrichMu.Unlock()
	// 只认"歌词族内容真的换过"。rescoreLyrics 就算什么都没换也会推进重选计数和版本号,
	// 把那些算成"更新了"会让收据上的数字虚高一个数量级。
	return after.Lyrics != before.Lyrics || after.LyricsYRC != before.LyricsYRC ||
		after.LyricsTr != before.LyricsTr
}
