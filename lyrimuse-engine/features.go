package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"log/slog"
	"os"
	"os/exec"
	"slices"
	"sort"
	"strings"
	"sync/atomic"
	"time"
)

// 九个歌词源的 key——跟 enrich.go 里 lyricCandidate.source/scoredLyricCandidateResult.
// Source 的取值、以及 desktop-lyrics「歌词管理」窗口 LyricsManagerView.swift 的
// sourceDisplayName 逐字对应,这是整个项目里"歌词源"唯一的一套 id,不是这里新起的。
const (
	lyricSourceNetease    = "netease"
	lyricSourceQQ         = "qq"
	lyricSourceKugou      = "kugou"
	lyricSourceMusixmatch = "musixmatch"
	lyricSourceLRCLIB     = "lrclib"
	// amll-ttml-db 社区库(见 amllttml.go)。它跟其余源的区别是**格式本身**能携带
	// 演唱者归属(TTML 的 ttm:agent),命中即拿到真·结构化对唱,不用靠行首前缀的启发式。
	// 覆盖率有限(实测约 6%),所以是"锦上添花"的一档,不是主力源。
	lyricSourceAMLL = "amll"
	// LyricFind(检索机制见 ytmusic.go)。YouTube Music 的歌词后端同时
	// 接了 Musixmatch 和 LyricFind 两家供应商,只有 LyricFind 是六源之外的真实增量
	// 数据——ytmusic.go 按 timedLyricsData 的 sourceMessage 过滤,查到的是 Musixmatch
	// 换个管道重发时一律当"没查到"处理,所以这个源名副其实:只要叫这个名字的候选,
	// 就真的是 LyricFind 的数据(源名因此叫 "lyricfind" 不是 "ytmusic"——这是检索
	// 机制,不是数据归属方,归属方才是这个项目给源命名的准则,见 musixmatch/lrclib)。
	// 只有逐行,没有逐字。实测(用户曲库 9 首抽样,过滤前的原始命中)8/9 在 YTM 上有
	// 歌词,但只有 2/9 是 LyricFind,覆盖率不算高,归在"锦上添花",不是主力源。
	lyricSourceLyricFind = "lyricfind"
	// 酷我音乐(加,见 kuwo.go 头注)。接口契约从公开的第三方开源实现
	// 逆向出来,实测搜索排序完全不可信(原版录音室版本常年不进 top10),接入时已经补了
	// 自己的重新打分排序,不是简单照搬。逐行 + 逐字(lrcx)+ 从正文摘出的中文译文,覆盖率同 amll/lyricfind
	// 一档,是"锦上添花"的兜底,不是主力源。
	lyricSourceKuwo = "kuwo"
	// 咪咕音乐(加,见 migu.go 头注)。跟酷我相反,搜索排序基本可信(原版排第一),
	// 只套身份闸淘汰、不重新打分;逐行 LRC + 逐字(MRC)+ 外语歌的中文译文。华语曲库覆盖率预期
	// 不低,但仍先按"锦上添花"档排在默认顺序末尾——三处顺序必须一致(见 lyricsSourceDefaultOrder)。
	lyricSourceMigu = "migu"
	// Deezer(加,见 deezer.go 头注)。跟 lyricfind **数据同源**:Deezer 的词
	// 由 LyricFind 供、时间轴 Deezer 自己做。接它有两层意义:① 给 LyricFind 这家版权方补
	// 第二条管道(那家原本只有 YouTube Music 一条路,YTM 一改版 / 一被地区限制,整家的数据
	// 就都没了);② Deezer 是法国公司,法语曲库覆盖比现有九源都好——接入实测里三首"九源
	// 只有 lrclib/netease 给得出低分候选"的法语小众歌,它都给出了逐行歌词。取词走
	// pipe.deezer.com 的 GraphQL + 匿名 JWT(不需要账号)。逐行之外带逐字(只在跟逐行轨对得上时用)和按译文语言设置取的译文。
	// 默认顺序排在末尾的理由跟前四个新源一样:样本还不够,不是覆盖率结论。
	lyricSourceDeezer = "deezer"
	// Apple Music 官方歌词(加,见 applemusic.go 头注)。跟前十个源都不同:
	// 它是**唯一**一家在现有十源之外、还给得出时间轴的信源,而且**往往**是逐字的
	// (itunes:timing="Word")——但别当成保证:有的曲目只有逐行(timing="Line"),
	// 甚至只有没时间戳的正文,取词那一步会依次退档,见 resolveApplemusicLyric。代价是需要用户在设置里连一次 Apple Music
	// (media-user-token,6 个月过期、不可续期),所以没连的时候这一路会安静跳过。
	// 覆盖率实测:用户本机 158 首"十源全空"的歌里,18 首 Apple 有时间轴、15 首有纯文本。
	lyricSourceAppleMusic = "applemusic"
	// 汽水音乐(加,见 soda.go 头注)。跟其它源都不同:它**不做搜索**,曲目 id 只来自汽水
	// 客户端自己的播放队列缓存,所以只有"正在用汽水听歌"时才有候选 —— 那也正是它的价值
	// 所在(时间轴对着用户耳朵里那一条录音),以及同源加权成立的场景。取词走 web 端给搜索
	// 引擎用的 seo_track 端点,无签名、无 Cookie、无需登录。正文格式与酷狗 KRC 同构,
	// 逐字归一化直接复用 krcToLRC / krcToYRC。
	lyricSourceSoda = "soda"
)

const (
	lyricsModeSmart    = "smart"
	lyricsModePriority = "priority"
)

// 播放器标识——跟 lyrimuse 侧 PlaybackPlayer(LyrimuseCore/Local/PlaybackPlayer.swift)的 rawValue
// 逐字对应,共享文件里 "players" 列表的取值。认哪首歌、怎么读全由 App 决定(poller.isTracked 只看 App 状态里
// 有没有曲目);引擎只在「跟随播放器启动」里用选中集合决定盯哪几个进程(companionLaunchProcessNames)。
// playerAuto("自动识别")不对应固定的某个 App:任一内置播放器或信任列表里的播放器都算。playerXxx 常量本身由 scripts/gen-players.py 从 shared/players.json 生成,在
// players_generated.go —— 接一个新播放器改那份 JSON,Swift 侧的 rawValue 跟着同一份走,两边不可能再漂。

// lyricsSourceDefaultOrder 是"顺序优先"模式缺省的顺序。
// 顺序必须与 Swift 侧 LyricsSource.allCases 的**声明顺序**一致 —— 那边的
// lyricsSourceOrder 默认值就是 allCases,两边对不上会让"顺序优先"模式在首次写盘前后
// 表现不同。改这里就要同步改那里,反之亦然(那边注释也钉着这条)。
//
// 排序依据(按实测采用率,此前是照抄 enrich.go candidates 的 append 顺序):
// 用户本机 3744 条 enrich 缓存里最终被采用的歌词来自 酷狗 1506(40.2%)/ 网易云 1125(30.0%)/
// QQ 732(19.6%)/ Musixmatch 176(4.7%)/ LRCLIB 74(2.0%) —— 酷狗是第一主力却长期排第三,
// 这次提到首位,前五个自此按真实采用率排。
//
// 后四个(amll/lyricfind/kuwo/migu)**刻意不按采用率排**,维持"锦上添花"档排在末尾:
// 它们分别是 / 08-31 / 08-31 / 09-04 才接入的,上面那 3744 条缓存绝大多数早于
// 它们存在,采用数 0~16 是样本偏差、不是覆盖率结论 —— 别拿"没赶上考试"当"考砸了"。等各自
// 跑满一段时间再拿数据重排。想让它们优先,用户可以自己在设置里拖。
var lyricsSourceDefaultOrder = []string{
	lyricSourceKugou, lyricSourceNetease, lyricSourceQQ, lyricSourceMusixmatch, lyricSourceLRCLIB,
	lyricSourceAMLL, lyricSourceLyricFind, lyricSourceKuwo, lyricSourceMigu, lyricSourceDeezer,
	lyricSourceAppleMusic, lyricSourceSoda,
}

// featureFlagsFile 是 App「设置」写的共享文件 lyrimuse-features.json(FeatureSettingsStore)在这边的形状,引擎
// 只读,按 mtime 热重读(featuresreload.go)。App 每次加载设置都把整份写全:缺的项补上默认值、旧写法改成新写法
// (FeatureSettingsStore.load),所以这里不做迁移,遗留键一律不认;各项的缺省只在 App 还没写过这份文件时用。
// 用 *bool 是为了分得出"没写"和"写了 false"。
//
// 这里的开关跟 config.go 里已有的凭据判断是 AND 关系,不是替代:没配凭据的功能,开关打开也没用。
type featureFlagsFile struct {
	// Players：可多选的播放器集合——跟 lyrimuse 侧 FeatureSettingsStore.players(Set<PlaybackPlayer>)对应,
	// rawValue 逐字相同。resolvePlayers 负责校验/兜底,任何时候 features().Players 都保证非空。
	Players       []string `json:"players,omitempty"`
	AlbumPrefetch *bool    `json:"album_prefetch,omitempty"`
	// LyricsAutoUpgrade:歌词定下来之后,还要不要跟着"匹配算法/打分规则升级"在后台自动
	// 换掉(把这个能力交出来:「控制是否会有自动按照最新版本的算法优化
	// 调整歌词的能力;开了就是现状,不开就是一开始选了什么就不会后台自动给换了」)。
	// 缺失=true=现状。闸门只加在**换掉已有歌词**的那两条路径上(enrich.go 的
	// needsLyricsRescore / needsLyricsRetry),首次填充、封面/译文回填、用户手动重搜都不受它管。
	LyricsAutoUpgrade    *bool `json:"lyrics_auto_upgrade,omitempty"`
	LastfmMirrorScrobble *bool `json:"lastfm_mirror_scrobble,omitempty"`
	// LastfmMatchMode：上送 Last.fm 前怎么对待播放器报的标签,三档 lastfmMatchSmart / lastfmMatchCustom /
	// lastfmMatchRaw,缺失 / 非法值按原始(见 resolveLastfmMatch)。语义与取舍见 lastfm.go 里
	// resolveScrobbleTags 与 lastfmcatalog.go 的注释。
	LastfmMatchMode string `json:"lastfm_match_mode,omitempty"`
	// 下面三个只在 lastfmMatchCustom 下读(另两档的值由档位本身决定,见 resolveLastfmMatch)。
	// 都缺失时按 false —— fail-closed 跟其余"改变上送内容"的开关一致。
	LastfmMatchArtist          *bool `json:"lastfm_match_artist,omitempty"`
	LastfmMatchTrack           *bool `json:"lastfm_match_track,omitempty"`
	LastfmMatchFirstArtistOnly *bool `json:"lastfm_match_first_artist_only,omitempty"`
	// ScrobbleShortTracks:短于 minTrackSecs(30 秒)的曲目也 scrobble 到 Last.fm(加,
	// 设置里 Last.fm →「短于 30 秒的曲目」)。**默认 false = 现状**:Last.fm 官方规则要求曲目长于
	// 30 秒,主流 scrobbler 都在客户端照做。**只管 Last.fm**(含给 Last.fm 兜底的本地收听日志和
	// 回填),ListenBrainz 不受影响 —— 见 poller.go tooShortToScrobble / shortTrackLastfmOnly。
	ScrobbleShortTracks *bool `json:"scrobble_short_tracks,omitempty"`
	// LastfmScrobblePoint:一次收听**记到 Last.fm** 的时点(加,设置里 Last.fm →
	// 「Scrobble 时机」),四档 scrobblePointHalf / scrobblePoint75 / scrobblePoint90 / scrobblePointEnd。
	// 默认 scrobblePointHalf = 现状(官方规则:曲长一半或 4 分钟,先到为准)。**只管 Last.fm**:
	// ListenBrainz、网页中继照旧在官方阈值那一刻提交,Last.fm 那一路(含给它兜底的本地收听日志)
	// 挂起到更严的时点才发 —— 见 poller.go lastfmScrobblePointReached / settleLastfmPending。
	// 只允许比官方下限更严:官方规则是下限,没有低于一半的档。
	LastfmScrobblePoint string `json:"lastfm_scrobble_point,omitempty"`
	WeeklyDigest        *bool  `json:"weekly_digest,omitempty"`
	// DailyDigest：见 daily.go。跟 WeeklyDigest 是独立开关，两个可以同时开、只开一个、
	// 或都不开。
	DailyDigest *bool `json:"daily_digest,omitempty"`
	// WeeklyDigestSource/DailyDigestSource："lastfm"/"listenbrainz"/空。空值(用户
	// 从没在设置里手动选过)交给 resolveDigestSource(digest.go)按"两个账号都配了→
	// lastfm,只配了一个→用那个,都没配→跳过"自动判定,不是"缺省当 lastfm 处理"这么
	// 简单——所以这里特意留空字符串而不是给一个非空的默认值常量。
	WeeklyDigestSource string `json:"weekly_digest_source,omitempty"`
	DailyDigestSource  string `json:"daily_digest_source,omitempty"`
	// MonthlyDigest/YearlyDigest：见 calendardigest.go。跟周报、日报都是独立开关。数据源字段
	// 同上，空值交给 resolveDigestSource。
	MonthlyDigest       *bool  `json:"monthly_digest,omitempty"`
	YearlyDigest        *bool  `json:"yearly_digest,omitempty"`
	MonthlyDigestSource string `json:"monthly_digest_source,omitempty"`
	YearlyDigestSource  string `json:"yearly_digest_source,omitempty"`
	// LyricsSources：启用的歌词源集合(lyricSourceXxx 常量的子集)。nil / 缺失 = 全部启用。
	// 文件里另有一组 xxx_lyrics 迁移标记(老配置升级后补上新加的源),只 App 读,补完写进这个列表。
	LyricsSources []string `json:"lyrics_sources,omitempty"`
	// LyricsSourceMode："smart"(默认,全部源全查+打分取最高分,见 enrich.go 的
	// scoredLyricCandidates/pickLyricCandidate)或"priority"(按 LyricsSourceOrder
	// 的顺序,取第一个通过质量校验(score>=0)的源,不比较分数高低)。空值按 smart 处理。
	LyricsSourceMode string `json:"lyrics_source_mode,omitempty"`
	// LyricsSourceOrder：只有 LyricsSourceMode == "priority" 时才生效。缺失时按
	// lyricsSourceDefaultOrder 兜底。
	LyricsSourceOrder []string `json:"lyrics_source_order,omitempty"`
	// LyricsDir：歌词文件夹("歌词文件夹作为权威源"读写的那个文件夹)的自定义位置。
	// 留空则用默认位置(config.json 同目录下的 lyrics/,main.go 里兜底)。
	LyricsDir string `json:"lyrics_dir,omitempty"`
	// LyricsTranslationLanguage："auto"(跟随系统语言,默认)或 ISO 639-1 两位小写代码
	// (如"en"/"es"/"ja")——Musixmatch 译文(crowd.track.translations.get)的目标语言。
	// 网易云/QQ 音乐的译文固定是中文,只有 Musixmatch 这个源支持指定任意语言。
	// resolveLyricsTranslationLanguage 负责把"auto"/空值解析成具体代码,见其注释。
	LyricsTranslationLanguage string `json:"lyrics_translation_language,omitempty"`
	// SystemLanguage:App 写进来的本机系统语言(AppleLocale 下划线前那段转小写,App 侧 SystemLanguage),
	// LyricsTranslationLanguage 是 auto 时按它解析。
	SystemLanguage string `json:"system_language,omitempty"`
	// LyricsMachineTranslation:歌词源没带社区译文时,用机器翻译补一份(见 translate.go)。
	// **默认关**,跟其它附加功能一致 —— 它会把歌词正文发给第三方翻译服务,而现有的五个
	// 歌词源只发歌手/歌名,这是一条新的外发数据,该由用户显式同意。
	LyricsMachineTranslation *bool `json:"lyrics_machine_translation,omitempty"`
	// LaunchLyrimuseOnPlayers:「跟随播放器启动」逐播放器勾选(Swift 侧 FeatureSettingsStore 的
	// launchLyrimuseOnPlayers):打开勾了的播放器时顺带唤起 Lyrimuse.app(见 companionlaunch.go)。缺失 / 空 = 不跟随。
	// 反方向("打开 Lyrimuse 时启动播放器")是 Swift 侧 AppSettings 自己的本地设置,不在这份文件里。
	LaunchLyrimuseOnPlayers []string `json:"launch_lyrimuse_on_players,omitempty"`
	// TrustedPlayers:用户显式信任的"未知播放器"—— bundle id → 界面显示名。
	//
	// 「自动识别」原来只认写死的内置播放器,别的 App 在报 Now Playing 一律当"没有可关心
	// 的播放"。这道白名单不只挡显示,**也挡打卡**(poller.go 的 isTracked):放开它等于
	// 让 YouTube 视频、播客、网课被当成收听写进用户的 Last.fm/ListenBrainz 永久历史,
	// 还会往"设计上永不清理"的歌词缓存里灌垃圾条目、白烧全部歌词源的查询。而想靠内容
	// 形状分辨也不可靠 —— 浏览器里的网页播放器能通过 MediaSession API 自己填
	// title/artist/artwork,一个 YouTube 音乐视频跟一首歌长得一模一样。
	//
	// 所以口径是**用户显式同意**:设置页发现未知播放器就提示,用户点一下加进这里,之后
	// 它跟五个内置播放器完全同权(显示 + 打卡)。这样任何 App 都能接(包括这个项目从没
	// 听说过的),而默认状态下一条垃圾都进不来。
	TrustedPlayers map[string]string `json:"trusted_players,omitempty"`
	// LastfmExcludedBundles:**不** scrobble 到 Last.fm 的播放器(bundle id 列表)。
	// 设置 → 账号 → Last.fm → 设置 →「Scrobble 的播放器」取消勾选的那几个;缺失 / 空 = 全部上送(现状)。
	// **只管 Last.fm**(含给它兜底的本地收听日志 / 回填与 now-playing),ListenBrainz 不受影响 —— 与
	// ScrobbleShortTracks / LastfmScrobblePoint 同一口径。与 Swift 侧 FeatureFlagsFile.lastfmExcludedBundles
	// 一一对应。语义、出口与粒度见 lastfmexclude.go 头注。
	LastfmExcludedBundles []string `json:"lastfm_excluded_bundles,omitempty"`
	// BrowserPlatformPairs:「网页播放器」里的配对关系,平台 id → 浏览器 bundle id 列表(Swift 侧
	// FeatureFlagsFile.browserPlatformPairs,App 从 AppSettings 镜像过来)。只决定网页平台探针对哪些浏览器跑,
	// 见 browserpairs.go;键缺失 = 老配置,所有浏览器都探。
	BrowserPlatformPairs map[string][]string `json:"browser_platform_pairs,omitempty"`
	// LyricsDecisionTrace:歌词解析决策的 append-only NDJSON 流水账,见 lyricstrace.go。
	// **默认关** —— 纯诊断旁路,平时不该往磁盘攒文件;要排查"为什么选了这份歌词"的
	// 历史过程时才开。缓存内的决策记录(decision.go)不受这个开关影响,始终会写。
	LyricsDecisionTrace *bool `json:"lyrics_decision_trace,omitempty"`
}

// featureFlags is the resolved (never-nil) form consulted at every gate site.
//
// 推送类模块(网页展示子开关、TopArtistsDigest、故障告警)不在这里出现:前两者已
// 改成"配置齐了就默认全跑"(pushRelayState 只看 cfg.StateRelayURL 是否非空,见
// config.go;TopArtistsDigest 见 topArtistsDigest()),不需要单独开关;故障告警
// 已整个下线,见 alerter.go。Last.fm 桥接(读 Last.fm 转发进 LB + 喂
// 网页"正在播放")加入这个"不需要单独开关"的阵营——之前独立的 LastfmBridge 开关
// 在 UI 上本来就要求"Last.fm 桥接凭据 + ListenBrainz 都配好"才能打开,跟自动判定
// 的条件完全一样,单独留一个开关只是多一次点击,没有实际区分度,见 poller.go 的
// bridge() 判断条件。
type featureFlags struct {
	// Players 是已经解析/校验过的播放器集合(键是 playerAppleMusic/playerQQMusic 等
	// 常量,值恒为 true;不会是空 map,见 resolvePlayers)。companionlaunch.go、match.go 的同源加权读它。
	Players       map[string]bool
	AlbumPrefetch bool
	// 见 featureFlagsFile.LyricsAutoUpgrade。默认 true(现状)。
	LyricsAutoUpgrade    bool
	LastfmMirrorScrobble bool
	// 上送匹配档位,恒为 lastfmMatchSmart/Custom/Raw 之一(resolveLastfmMatch 保证),
	// 默认 lastfmMatchRaw(原样发)。只给日志和诊断看 —— 判断行为一律读下面三个布尔,
	// 它们已经把档位摊平了(智能档恒为 true/true/false)。
	LastfmMatchMode string
	// 允许把歌手 / 曲名改写成 Last.fm 编目条目的写法。两个都 false = 不打网络。
	LastfmMatchArtist bool
	LastfmMatchTrack  bool
	// 合唱串截成第一位(firstCreditedArtist,纯字符串、不联网)。**只在没匹配到编目条目时**
	// 应用 —— 匹配到的写法已经是编目认的那条,再截一刀就把它变成一个不存在的条目了
	// (Hall & Oates → Hall)。见 resolveScrobbleTags。
	LastfmMatchFirstArtistOnly bool
	// 见 featureFlagsFile.ScrobbleShortTracks。默认 false(短曲目不记,Last.fm 官方规则)。
	ScrobbleShortTracks bool
	// 见 featureFlagsFile.LastfmScrobblePoint。恒为 scrobblePointHalf/75/90/End 之一
	// (resolveScrobblePoint 保证),默认 scrobblePointHalf(官方规则那一刻就发)。
	LastfmScrobblePoint string
	WeeklyDigest        bool
	DailyDigest         bool
	WeeklyDigestSource  string
	DailyDigestSource   string
	MonthlyDigest       bool
	YearlyDigest        bool
	MonthlyDigestSource string
	YearlyDigestSource  string
	// pickLyricCandidate(enrich.go)读这三个字段决定冠军。
	//
	// 订正:原注释说 `lyrimuse-engine search-lyrics` 子命令"从不调用
	// loadFeatureFlags、这三个字段在那条路径上永远是零值",**这是错的** —— searchcli.go
	// 一直自己加载一遍(不然 LyricsSources 是 nil map,过滤时全部源被误判成"没启用"、
	// 直接返回空列表)。LyricsSources 早就被 filterEnabledLyricSources 实际读取着;
	// LyricsSourceMode/Order 在 -pick 模式下也被读(冠军要按用户选的「匹配算法」算)。
	// 这条错注释误导过一轮设计评审,别再照它推结论。
	LyricsSources     map[string]bool
	LyricsSourceMode  string
	LyricsSourceOrder []string
	// LyricsDir 空字符串表示"用默认位置",由 main.go 里设置包级变量 lyricsDir() 时兜底,
	// 不在这里(loadFeatureFlags)展开成绝对路径——那时候 *cfgPath 还没解析完。
	LyricsDir string
	// LyricsTranslationLanguage 是已经解析过的具体 ISO 639-1 代码(不会是"auto"或空值,
	// 见 resolveLyricsTranslationLanguage)。三处读取,含义都是"译文要什么语言":
	// musixmatchTranslationLRC(musixmatch.go)向 Musixmatch 索取该语言的社区译文;
	// appleLangCode / myMemoryLangCode(translate.go)把它转成端上翻译和网络兜底
	// 各自的语言代码。网易云/QQ 不在此列——它们自带的社区译文只有中文,给不了别的语言。
	LyricsTranslationLanguage string
	// SystemLanguage:App 写进来的本机系统语言(AppleLocale 下划线前那段转小写,见 featureFlagsFile.SystemLanguage),
	// App 还没写过时是空串。按界面语言问 YouTube Music 时用(ytmusicDisplayLanguage)。
	SystemLanguage string
	// 见上面同名字段的注释。只被 needsTranslationBackfill/backfillTranslation 读取。
	LyricsMachineTranslation bool
	// LaunchLyrimuseOnPlayers 是逐播放器勾选的集合(键是 player* 常量),空 = 不跟随。只被 companionlaunch.go 读取。
	LaunchLyrimuseOnPlayers map[string]bool
	// LyricsDecisionTrace 只被 lyricstrace.go 读取,见那边注释。
	LyricsDecisionTrace bool
	// TrustedPlayers 是已经清洗过的形态(见 resolveTrustedPlayers):键一定非空、一定不是
	// 五个内置播放器之一;值可能是空字符串(反查不到 App 名),此时标签退回 bundle id。
	TrustedPlayers map[string]string
	// LastfmExcludedBundles 是已清洗的集合(见 resolveLastfmExcludedBundles),空 map 而不是 nil。
	// 只被 lastfmexclude.go 的 lastfmExcluded 读取;poller 在开会话那一拍算一次存进 playSession。
	LastfmExcludedBundles map[string]bool
	// BrowserPlatformPairs:平台 id → 配对过的浏览器集合。nil = 文件里没有这个键(沿用所有浏览器都探),
	// 空 map = App 写过、一个都没配。只被 browserpairs.go 的 browserPlatformPaired 读取。
	BrowserPlatformPairs map[string]map[string]bool
}

// 这里原本是 `var features featureFlags` —— 启动时赋值一次、运行期再也不变,于是设置页
// 每保存一次都得重启引擎才生效(一次 40~47 秒的停摆)。现在改成了同名的**函数**
// features(),内部是原子快照 + 按 mtime 热重读,见 featuresreload.go。
//
// 之所以保留 `features` 这个名字而不是另起一个访问器:`features().X` 这种旧写法会直接**编译失败**,
// 183 个读点、53 个赋值点一个都漏不掉 —— 靠编译器兜底,不靠人眼。

// resolveLaunchLyrimuseOnPlayers 把「跟随哪些播放器启动」的原始列表清洗成集合(缺失 = 空集合),不认识的值丢掉
// (auto 也丢 —— 它不是一个可以"启动"的进程)。
//
// 认得哪些按 playerBundleIDs(生成自 players.json,auto 不在里面),别写成手写清单:设置里每个播放器都勾得上,
// 漏一个就是勾了不生效、也不报错。
func resolveLaunchLyrimuseOnPlayers(raw []string) map[string]bool {
	out := map[string]bool{}
	for _, p := range raw {
		if _, ok := playerBundleIDs[p]; ok {
			out[p] = true
		}
	}
	return out
}

func boolOr(p *bool, def bool) bool {
	if p == nil {
		return def
	}
	return *p
}

// loadFeatureFlags reads the shared feature-toggle file (best-effort — missing
// file / unparseable content all resolve to defaults below). Core behavior
// toggles (lyrics/albumPrefetch) miss-field-defaults to true — a
// pure increment that never silently changes existing behavior. The toggles
// that each require an external account (Last.fm mirror / weekly digest /
// daily digest) default to false instead: turning them on by default for a
// stranger who never opened Settings would silently start network calls to
// services they never configured.
func loadFeatureFlags(path string) featureFlags {
	var f featureFlagsFile
	if data, err := os.ReadFile(path); err == nil {
		if jerr := json.Unmarshal(data, &f); jerr != nil {
			log.Printf("parse feature flags %s: %v (falling back to defaults)", path, jerr)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		log.Printf("read feature flags %s: %v (falling back to defaults)", path, err)
	}
	return buildFeatureFlags(f)
}

// readFeatureFlags 是 loadFeatureFlags 的**不吞错**版本 —— 专给热重读用(featuresreload.go)。
//
// 两者的失败语义必须不同,这不是重复代码:启动那次读不出来,除了退回默认值没有别的东西可用;
// 而热重读那一刻**手上正握着一份生效中的配置**,再退回默认就等于"文件坏了一下,用户所有设置当场
// 被重置成出厂值"——那比"这次没更新成"严重得多。所以这里一律把错误抛出去,由调用方保留旧快照。
func readFeatureFlags(path string) (featureFlags, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return featureFlags{}, err
	}
	var f featureFlagsFile
	if err := json.Unmarshal(data, &f); err != nil {
		return featureFlags{}, err
	}
	return buildFeatureFlags(f), nil
}

// buildFeatureFlags 把解析好的文件结构变成运行期用的那份配置:缺省值和清洗都在这里(老写法的迁移只在 App 做),
// 两条读取路径(启动 / 热重读)共用它,免得缺省值在两边各写一份、迟早漂移。
func buildFeatureFlags(f featureFlagsFile) featureFlags {
	match := resolveLastfmMatch(f)
	return featureFlags{
		Players:        resolvePlayers(f.Players),
		TrustedPlayers: resolveTrustedPlayers(f.TrustedPlayers),
		// 缺失 / 空 = 全部上送:跟 TrustedPlayers 一样"少一个键不改变现有行为"。
		LastfmExcludedBundles: resolveLastfmExcludedBundles(f.LastfmExcludedBundles),
		BrowserPlatformPairs:  resolveBrowserPlatformPairs(f.BrowserPlatformPairs),
		AlbumPrefetch:         boolOr(f.AlbumPrefetch, true),
		// 缺省 true = 保持这个能力上线以来的行为。
		LyricsAutoUpgrade:    boolOr(f.LyricsAutoUpgrade, true),
		LastfmMirrorScrobble: boolOr(f.LastfmMirrorScrobble, false),
		// 默认 lastfmMatchRaw:原样发。理由见 lastfm.go resolveScrobbleTags ——
		// ListenBrainz 文档要求合唱 credit "include them all",Navidrome 同名开关默认也是 false。
		LastfmMatchMode:            match.Mode,
		LastfmMatchArtist:          match.Artist,
		LastfmMatchTrack:           match.Track,
		LastfmMatchFirstArtistOnly: match.FirstArtistOnly,
		// 默认 false:照 Last.fm 官方规则,短于 30 秒不记。fail-closed 跟其余"改变上送内容"的
		// 开关一致——字段缺失不能让老用户的历史突然多出一批短曲目。
		ScrobbleShortTracks:       boolOr(f.ScrobbleShortTracks, false),
		LastfmScrobblePoint:       resolveScrobblePoint(f.LastfmScrobblePoint),
		WeeklyDigest:              boolOr(f.WeeklyDigest, false),
		DailyDigest:               boolOr(f.DailyDigest, false),
		WeeklyDigestSource:        f.WeeklyDigestSource,
		DailyDigestSource:         f.DailyDigestSource,
		MonthlyDigest:             boolOr(f.MonthlyDigest, false),
		YearlyDigest:              boolOr(f.YearlyDigest, false),
		MonthlyDigestSource:       f.MonthlyDigestSource,
		YearlyDigestSource:        f.YearlyDigestSource,
		LyricsSources:             resolveLyricsSources(f.LyricsSources),
		LyricsSourceMode:          resolveLyricsSourceMode(f.LyricsSourceMode),
		LyricsSourceOrder:         resolveLyricsSourceOrder(f.LyricsSourceOrder),
		LyricsDir:                 f.LyricsDir,
		LyricsTranslationLanguage: resolveLyricsTranslationLanguage(f.LyricsTranslationLanguage, f.SystemLanguage),
		SystemLanguage:            strings.ToLower(strings.TrimSpace(f.SystemLanguage)),
		LyricsMachineTranslation:  boolOr(f.LyricsMachineTranslation, false),
		LaunchLyrimuseOnPlayers:   resolveLaunchLyrimuseOnPlayers(f.LaunchLyrimuseOnPlayers),
		LyricsDecisionTrace:       boolOr(f.LyricsDecisionTrace, false),
	}
}

// 上送匹配档位(features().LastfmMatchMode)。字符串值跟 Swift 侧 LastfmMatchMode 的
// rawValue 逐字相同 —— 两侧通过同一份 features.json 交换。
const (
	// 智能:在 Last.fm 编目里找这首歌对应的条目,歌手和曲名都按那条发(见 lastfmcatalog.go)。
	lastfmMatchSmart = "smart"
	// 自定义:三个维度各自开关(改歌手 / 改曲名 / 合唱只发第一位)。
	lastfmMatchCustom = "custom"
	// 原始:原样发播放器报的标签,一个字都不动,不打网络。
	lastfmMatchRaw = "raw"
)

// lastfmMatchSettings 是档位摊平之后的四个值。判断行为一律读后三个布尔,别再去看 Mode ——
// 智能档恒为 true/true/false,自定义档才按文件里的三个键。
type lastfmMatchSettings struct {
	Mode            string
	Artist          bool
	Track           bool
	FirstArtistOnly bool
}

// resolveLastfmMatch 把文件里的档位校验成三个常量之一并摊平成布尔;缺失 / 非法时按「原始」(不改上送内容)。
// 非法值除了兜底还记一行日志 —— 拼错档位名的后果是"设置里选了智能、引擎一直在发整串",不报出来查不到。
//
// 全新装机默认「智能」由 App 判(判据要看 UserDefaults,引擎读不到),加载设置时写进文件;老写法
// (lastfm_scrobble_artist_mode / lastfm_scrobble_first_artist_only)也由 App 加载时改写成档位。这里只认档位。
func resolveLastfmMatch(f featureFlagsFile) lastfmMatchSettings {
	switch f.LastfmMatchMode {
	case lastfmMatchSmart:
		return lastfmMatchSettings{Mode: lastfmMatchSmart, Artist: true, Track: true}
	case lastfmMatchCustom:
		return lastfmMatchSettings{
			Mode:            lastfmMatchCustom,
			Artist:          boolOr(f.LastfmMatchArtist, false),
			Track:           boolOr(f.LastfmMatchTrack, false),
			FirstArtistOnly: boolOr(f.LastfmMatchFirstArtistOnly, false),
		}
	case lastfmMatchRaw, "":
	default:
		log.Printf("feature flags: unknown lastfm_match_mode %q (falling back)", f.LastfmMatchMode)
	}
	return lastfmMatchSettings{Mode: lastfmMatchRaw}
}

// Last.fm scrobble 时点(features().LastfmScrobblePoint)。字符串值跟 Swift 侧
// LastfmScrobblePoint 的 rawValue 逐字相同 —— 两侧通过同一份 features.json 交换。
const (
	// 官方规则:播满曲长一半、或满 4 分钟,先到为准(默认)。这也是 ListenBrainz 那一路提交的时刻,
	// 所以这一档下 Last.fm 跟原来一样当场发。
	scrobblePointHalf = "50"
	// 播满曲长的 75% / 90%。纯按已播时长算,不再套 4 分钟上限——"听了 75%"就是字面意思。
	scrobblePoint75 = "75"
	scrobblePoint90 = "90"
	// 一直放到结尾才记,中途切歌不记。判据见 poller.go sessionEndedNaturally。
	scrobblePointEnd = "end"
)

// resolveScrobblePoint 把文件里的时点字符串校验成四个常量之一;缺失兜底 scrobblePointHalf,
// 非法值同样兜底但记一行日志(理由同 resolveLastfmMatch:拼错了不报出来查不到)。
func resolveScrobblePoint(raw string) string {
	switch raw {
	case scrobblePointHalf, scrobblePoint75, scrobblePoint90, scrobblePointEnd:
		return raw
	case "":
	default:
		log.Printf("feature flags: unknown lastfm_scrobble_point %q (falling back)", raw)
	}
	return scrobblePointHalf
}

// isValidPlayerValue 核对一个字符串是不是已知播放器的 rawValue(resolvePlayers 校验列表条目用)。
func isValidPlayerValue(p string) bool {
	// 合法取值来自 allPlayerIDs(生成自 shared/players.json)——接一个播放器时
	// 这里不用改,漏改也不可能发生。
	return slices.Contains(allPlayerIDs, p)
}

// resolvePlayers 把文件里的播放器列表清洗成集合:认得出的值收进来,认不出的静默丢掉(比如以后某个版本删掉的
// 播放器,不该让整份解析失败);一个能收的都没有(nil / 空 / 全认不出)兜底成 playerAuto(写死 Apple Music
// 会让只用别的播放器的新用户对着一个永远空白的界面,见 PlaybackPlayer.swift 顶部注释)。返回值保证非空、
// 且键全部是已知值,调用方可以放心用 `m[playerXxx]` 判断成员,不需要再校验一遍。
func resolvePlayers(list []string) map[string]bool {
	m := map[string]bool{}
	for _, p := range list {
		if isValidPlayerValue(p) {
			m[p] = true
		}
	}
	if len(m) > 0 {
		return m
	}
	return map[string]bool{playerAuto: true}
}

// resolveTrustedPlayers 清洗用户信任列表:去掉空 bundle id、去掉首尾空白、去掉五个
// 内置播放器(它们本来就认,留在这里只会让"已信任"列表看起来莫名多几条)。
//
// 返回 nil(而不是空 map)是刻意的:调用方一律用 `m[k]` 取值,对 nil map 取值是合法的
// 零值读取,不需要在每个调用点判空。
func resolveTrustedPlayers(m map[string]string) map[string]string {
	if len(m) == 0 {
		return nil
	}
	builtin := builtinPlayerBundleIDs
	out := make(map[string]string, len(m))
	for bundleID, name := range m {
		id := strings.TrimSpace(bundleID)
		if id == "" || builtin[id] {
			continue
		}
		out[id] = strings.TrimSpace(name)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// resolveLyricsSources:文件里的启用列表,先去掉这个版本不认识的源名(跟 App 侧 FeatureSettingsStore 的 compactMap
// 同一口径:降级安装、手改过文件时清单里可能全是不认识的名字,不去掉的话这边等于所有已知源都关了,App 那边却显示
// 全开);列表缺失 / 为空 = 全部启用。老配置升级后补上新加的源是 App 的事(xxx_lyrics 迁移标记),这里只认列表。
func resolveLyricsSources(list []string) map[string]bool {
	m := make(map[string]bool, len(lyricSourceNames))
	for _, s := range list {
		if slices.Contains(lyricSourceNames, s) {
			m[s] = true
		}
	}
	if len(m) == 0 {
		for _, s := range lyricSourceNames {
			m[s] = true
		}
	}
	return m
}

// lyricSourceEnabled 是"这个歌词源开着吗"的**唯一**判据。判定原先散在六处、形式还不
// 完全一致(有的带 len==0 兜底、有的不带),统一到这里。
// 注:resolveLyricsSources 在列表为空时返回全集,所以集合永远非 nil,
// 那些 len==0 的兜底其实是历史冗余,留着不碍事。
//
// 读的是 currentLyricSources()(按 features.json 的 mtime 热重读),不是启动时展开的
// features().LyricsSources —— 勾一下源就重启引擎的代价是半分多钟的服务停摆,见
// lyricsourcesreload.go 头注。这也是这个判据必须唯一的原因:多一处直接读 features().LyricsSources,
// 那一处就还停在启动时的旧值。
func lyricSourceEnabled(source string) bool {
	// KKBOX 本地歌词不是歌词源、设置里没有它的开关:用 KKBOX 放歌时读它自己缓存里的那份,跟着播放器走(见 kkboxlyrics.go)。
	// Spotify 本地歌词、Amazon Music 本地歌词同理(见 spotifylyrics.go、amazonlibrary.go)。
	if isPlayerLocalLyricSource(source) {
		return true
	}
	enabled := currentLyricSources()
	return len(enabled) == 0 || enabled[source]
}

// isPlayerLocalLyricSource:这份候选是不是读播放器自己缓存来的(KKBOX / Spotify / Amazon Music 本地歌词)。
func isPlayerLocalLyricSource(source string) bool {
	return source == kkboxLocalLyricsSource || source == spotifyLocalLyricsSource || source == amazonLocalLyricsSource
}

func resolveLyricsSourceMode(mode string) string {
	if mode == lyricsModePriority {
		return lyricsModePriority
	}
	return lyricsModeSmart
}

// resolveLyricsSourceOrder:用户排的顺序里认得的源按原顺序保留(去重、丢掉不认得的),没排进去的按默认顺序
// 补在末尾 —— 新加了一个源、旧文件的顺序表还没有它时,用户手排的前几位原样生效,新源排最后。口径与 Swift 侧
// FeatureSettingsStore.completedLyricsSourceOrder 一致。原来非空就原样用,缺的源在「顺序优先」模式下永远选不到。
func resolveLyricsSourceOrder(order []string) []string {
	known := make(map[string]bool, len(lyricsSourceDefaultOrder))
	for _, s := range lyricsSourceDefaultOrder {
		known[s] = true
	}
	out := make([]string, 0, len(lyricsSourceDefaultOrder))
	seen := make(map[string]bool, len(lyricsSourceDefaultOrder))
	for _, s := range order {
		if known[s] && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	for _, s := range lyricsSourceDefaultOrder {
		if !seen[s] {
			out = append(out, s)
		}
	}
	return out
}

// resolveLyricsTranslationLanguage 把共享文件里的"auto"/空值解析成一个具体的语言代码:用 App 写进同一份
// 文件的 system_language(featureFlagsFile.SystemLanguage)。启动时解析一次,features.json 热重读时再解析
// 一次(featuresreload.go);系统语言换了,App 下次加载设置时改写这个键,这边跟着热重读。
//
// 文件里还没有这个键(App 还没写过)时自己查一次本机(systemLanguageCode),取法跟 App 一致。这一步别直接
// 兜底 "en":启动清理(invalidateStaleTranslations)按解析结果清掉别的语言的机翻,兜错一次就是整库重翻。
// 查不到才兜底 "en"。
//
// 设置里的值只认 App 那份枚举(lyricsTranslationLanguageCodes):不认识的值(手改过文件、降级安装后
// 留下新版才有的语言)当作 auto。App 读到不认识的值显示「跟随系统语言」,这边原样拿去用的话,界面
// 写着跟随系统、后台却按一门没人选过的语言请求译文、清理机翻。
func resolveLyricsTranslationLanguage(lang, systemLang string) string {
	if lang != "" && lang != "auto" && slices.Contains(lyricsTranslationLanguageCodes, lang) {
		return lang
	}
	if code := strings.ToLower(strings.TrimSpace(systemLang)); code != "" {
		return code
	}
	if code := systemLanguageCode(); code != "" {
		return code
	}
	return "en"
}

// systemLanguageCode 自己查一次本机系统语言(`defaults read -g AppleLocale`,取法见 appleLocaleLanguage),
// 只在 features.json 里还没有 App 写的 system_language 时用(见 resolveLyricsTranslationLanguage)。
// 查询失败(命令不存在 / 超时 / 输出为空)返回空串,交给调用方兜底,不 panic、不重试。
//
// 查成功的结果记在 systemLanguageLast 里,之后查询失败时沿用它:热重读时那一次查询偶尔失败,结果掉回兜底的
// "en" 会被当成「译文语言换了」,整库机翻清一遍,下一次查成功又清一遍。
// 查询带超时:热重读跑在任意一个调用 features() 的 goroutine 上(可能正持着 enrichMu),不能被一个卡住的
// 子进程拖住。
func systemLanguageCode() string {
	if code := querySystemLanguageCode(); code != "" {
		systemLanguageLast.Store(&code)
		return code
	}
	if last := systemLanguageLast.Load(); last != nil {
		return *last
	}
	return ""
}

// lyricsTranslationLanguageCodes:设置里可选的译文语言,跟 App 侧 MusixmatchTranslationLanguage 的
// rawValue 逐项一致(auto 除外),TestLyricsTranslationLanguageCodesMatchSwift 对账。
var lyricsTranslationLanguageCodes = []string{
	"en", "zh", "ja", "ko", "es", "fr", "de", "pt", "it", "ru", "ar", "vi", "th", "id", "nl", "pl", "tr",
}

// systemLanguageLast:这个进程里最近一次查成功的系统语言代码。
var systemLanguageLast atomic.Pointer[string]

// querySystemLanguageQuery 可换,只为单测。
var querySystemLanguageQuery = func(ctx context.Context) ([]byte, error) {
	return exec.CommandContext(ctx, "defaults", "read", "-g", "AppleLocale").Output()
}

func querySystemLanguageCode() string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := querySystemLanguageQuery(ctx)
	if err != nil {
		return ""
	}
	return appleLocaleLanguage(string(out))
}

// appleLocaleLanguage:AppleLocale("zh_CN" / "en_US" / "zh-Hans_CN")下划线前那段转小写,文字子标签原样留着;
// 取不到是空串。必须跟 App 的 SystemLanguage.appleLocaleLanguage 逐字一致(两侧共用样例
// shared/testdata/system-language.json):两边对同一台机器得出不同语言,会被当成译文语言换了、整库机翻清一遍。
func appleLocaleLanguage(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '_'); i > 0 {
		s = s[:i]
	}
	return strings.ToLower(s)
}

// ---- 启动时的开关快照 ----

// logFeatureSnapshot 把当前生效的功能开关整体打一行。
//
// 为什么要有:启动行原来只有版本号和 bundle 列表,同一份日志里看不出这台机器究竟开了
// 什么。"为什么我这儿不补译文 / 不跟着启动 / 少一个源"这类问题,不先把"配置不同"这个
// 变量排除掉就没法往下查,而这些开关是用户自己在设置里改的,问他往往问不明白。
//
// 全量打而不是只挑"跟默认不一样的":默认值散在各个 resolve* 函数里,挑出来容易挑错,
// 而这一行一次启动只出现一次,全打也就几百字节。
//
// 这里全是布尔 / 枚举 / 名单,不含任何凭据。LyricsDir 只记"有没有自定义过",不记路径
// 本身 —— 那是用户的目录结构,跟排查无关。
func logFeatureSnapshot() {
	lyricsDirMode := "default"
	if features().LyricsDir != "" {
		lyricsDirMode = "custom"
	}
	slog.Info("feature flags",
		"players", sortedEnabledKeys(features().Players),
		"album_prefetch", features().AlbumPrefetch,
		"lyrics_auto_upgrade", features().LyricsAutoUpgrade,
		"lyrics_sources", sortedEnabledKeys(features().LyricsSources),
		"lyrics_source_mode", orDash(features().LyricsSourceMode),
		"lyrics_source_order", orDash(strings.Join(features().LyricsSourceOrder, ",")),
		"lyrics_dir", lyricsDirMode,
		"lyrics_translation_language", orDash(features().LyricsTranslationLanguage),
		"lyrics_machine_translation", features().LyricsMachineTranslation,
		"lyrics_decision_trace", features().LyricsDecisionTrace,
		"lastfm_mirror_scrobble", features().LastfmMirrorScrobble,
		// 档位 + 摊平后的三个布尔一起打:排查时「界面选了什么」和「实际按什么办」是两件事,
		// 只记档位的话自定义档看不出它到底开了哪几项。三个布尔各占一个键 —— 拼成一个带
		// 空格的值会被 slog 加引号,也不好 grep。
		"lastfm_match_mode", orDash(features().LastfmMatchMode),
		"lastfm_match_artist", features().LastfmMatchArtist,
		"lastfm_match_track", features().LastfmMatchTrack,
		"lastfm_match_first_artist_only", features().LastfmMatchFirstArtistOnly,
		"lastfm_scrobble_point", orDash(features().LastfmScrobblePoint),
		"scrobble_short_tracks", features().ScrobbleShortTracks,
		"lastfm_excluded_bundles", len(features().LastfmExcludedBundles),
		"weekly_digest", features().WeeklyDigest,
		"weekly_digest_source", orDash(features().WeeklyDigestSource),
		"daily_digest", features().DailyDigest,
		"daily_digest_source", orDash(features().DailyDigestSource),
		"monthly_digest", features().MonthlyDigest,
		"monthly_digest_source", orDash(features().MonthlyDigestSource),
		"yearly_digest", features().YearlyDigest,
		"yearly_digest_source", orDash(features().YearlyDigestSource),
		"launch_on_players", sortedEnabledKeys(features().LaunchLyrimuseOnPlayers),
		"trusted_players", orDash(sortedMapKeys(features().TrustedPlayers)),
		"browser_platform_pairs", browserPlatformPairsSummary(features().BrowserPlatformPairs),
	)
}

// orDash 把空串换成 "-":key=value 里一个空值读起来像是字段丢了,而"这一项是空的"
// 本身就是诊断信息,不能让人分不清。
func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// sortedEnabledKeys 把开关集合里**为真**的键压成稳定顺序的逗号串。
func sortedEnabledKeys(m map[string]bool) string {
	ks := make([]string, 0, len(m))
	for k, on := range m {
		if on {
			ks = append(ks, k)
		}
	}
	sort.Strings(ks)
	return orDash(strings.Join(ks, ","))
}

// sortedMapKeys 只取键(值可能是反查不到的空 App 名,对排查没用)。
func sortedMapKeys(m map[string]string) string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return strings.Join(ks, ",")
}
