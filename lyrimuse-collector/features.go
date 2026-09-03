// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"strings"
)

// featureFlagsFile is the on-disk shape written by desktop-lyrics's "设置" →
// "功能开关" section and read once at collector startup — same "Swift 写共享
// 文件 → launchctl kickstart 重启 collector → collector 下次启动读到新内容"
// 约定,已经在 enrichCache/lyrics 文件夹这两处验证过(见 main.go 顶部注释),collector
// 没有文件监听,状态只在启动时读一次。用 *bool 而不是 bool——文件不存在、或者文件里
// 缺某个字段,都要解读成"沿用现有行为"(默认开启),而不是"关闭";bool 零值会把两者
// 都错误地解读成"关闭",导致这个改动从"纯增量开关"变成"静默改变现有行为"。
//
// 这里的开关跟 config.go 里已有的凭据判断是 AND 关系,不是替代:没配凭据的功能,
// 开关打开也没用;已经配了凭据的功能,现在才第一次有独立的"关"(尤其是
// lastfm_bridge/weekly_digest/top_artists_digest 这三个,过去共用同一对
// lastfm_user/lastfm_api_key 凭据当唯一开关,逻辑上是三个独立能力)。
// 八个歌词源的 key——跟 enrich.go 里 lyricCandidate.source/scoredLyricCandidateResult.
// Source 的取值、以及 desktop-lyrics「歌词管理」窗口 LyricsManagerView.swift 的
// sourceDisplayName 逐字对应,这是整个项目里"歌词源"唯一的一套 id,不是这里新起的。
const (
	lyricSourceNetease    = "netease"
	lyricSourceQQ         = "qq"
	lyricSourceKugou      = "kugou"
	lyricSourceMusixmatch = "musixmatch"
	lyricSourceLRCLIB     = "lrclib"
	// amll-ttml-db 社区库(见 amllttml.go)。它跟前五个源的区别是**格式本身**能携带
	// 演唱者归属(TTML 的 ttm:agent),命中即拿到真·结构化对唱,不用靠行首前缀的启发式。
	// 覆盖率有限(实测约 6%),所以是"锦上添花"的一档,不是主力源。
	lyricSourceAMLL = "amll"
	// LyricFind(检索机制见 ytmusic.go,2026-08-25 加)。YouTube Music 的歌词后端同时
	// 接了 Musixmatch 和 LyricFind 两家供应商,只有 LyricFind 是六源之外的真实增量
	// 数据——ytmusic.go 按 timedLyricsData 的 sourceMessage 过滤,查到的是 Musixmatch
	// 换个管道重发时一律当"没查到"处理,所以这个源名副其实:只要叫这个名字的候选,
	// 就真的是 LyricFind 的数据(源名因此叫 "lyricfind" 不是 "ytmusic"——这是检索
	// 机制,不是数据归属方,归属方才是这个项目给源命名的准则,见 musixmatch/lrclib)。
	// 只有逐行,没有逐字。实测(用户曲库 9 首抽样,过滤前的原始命中)8/9 在 YTM 上有
	// 歌词,但只有 2/9 是 LyricFind,覆盖率不算高,归在"锦上添花",不是主力源。
	lyricSourceLyricFind = "lyricfind"
	// 酷我音乐(2026-08-31 加,见 kuwo.go 头注)。接口契约从公开的第三方开源实现
	// 逆向出来,实测搜索排序完全不可信(原版录音室版本常年不进 top10),接入时已经补了
	// 自己的重新打分排序,不是简单照搬。只有逐行,没有逐字/译文,覆盖率同 amll/lyricfind
	// 一档,是"锦上添花"的兜底,不是主力源。
	lyricSourceKuwo = "kuwo"
)

const (
	lyricsModeSmart    = "smart"
	lyricsModePriority = "priority"
)

// 本地播放状态读取哪个 App——跟 lyrimuse 侧 PlaybackPlayer(LyrimuseCore/Local/
// PlaybackPlayer.swift)的 rawValue 逐字对应,共享文件里 "player" 字段的取值。
// Apple Music 走 AppleScript;QQ 音乐/网易云音乐都没有 AppleScript 支持(用
// sdef/PlistBuddy 核实过,两者都没有 .sdef、也没开 NSAppleScriptEnabled),共用同一条
// 系统级 MediaRemote(media-control)读取路径,只是 bundle id 不同——见 system.go 的
// getState()/appleMusicPosition() 注释。Spotify 自己虽然有 AppleScript 支持,但
// 2026-07-29 实测坐实它同样会把播放状态发布进系统级 MediaRemote(`media-control get`/
// 控制指令都正常),没必要单独写一套 AppleScript 集成,归到跟 QQ/网易云一样的路径。
// playerAuto("自动识别")不对应固定的某个 App——问 media-control 当前系统级 Now
// Playing 焦点是谁,核对是不是这四个已知播放器之一,见 system.go 的 getSpotifyState
// 附近 getAutoDetectedState 的注释。
const (
	playerAppleMusic = "apple_music"
	playerQQMusic    = "qq_music"
	playerNetease    = "netease_music"
	playerSpotify    = "spotify"
	// 酷狗音乐(2026-08-21 接入)。它是个 Mac Catalyst 应用(主二进制链的是
	// /System/iOSSupport/.../MediaPlayer.framework),自己把播放状态发布进系统级
	// MediaRemote,所以跟 QQ/网易云/Spotify 走同一条 media-control 路径,不需要新代码路径。
	// 跟 QQ/网易云一样没有 AppleScript 字典(`Info.plist` 里没有 NSAppleScriptEnabled、
	// Resources 下也没有 .sdef,2026-08-21 核实),所以扩展控件(喜欢/音量/播放模式)一律没有。
	playerKugou = "kugou_music"
	playerAuto  = "auto"
)

// lyricsSourceDefaultOrder 是"顺序优先"模式缺省的顺序——照抄 enrich.go
// scoredLyricCandidates 里 candidates 列表本来的 append 顺序,不是这里凭空定的。
// ⚠️ 顺序必须与 Swift 侧 LyricsSource.allCases 的**声明顺序**一致 —— 那边的
// lyricsSourceOrder 默认值就是 allCases,两边对不上会让"顺序优先"模式在首次写盘前后
// 表现不同。amll/lyricfind 放最后:两个都是覆盖率有限的"锦上添花"档,想让它们优先
// 由用户自己在设置里拖。
var lyricsSourceDefaultOrder = []string{
	lyricSourceNetease, lyricSourceQQ, lyricSourceKugou, lyricSourceMusixmatch, lyricSourceLRCLIB,
	lyricSourceAMLL, lyricSourceLyricFind, lyricSourceKuwo,
}

type featureFlagsFile struct {
	// Player：**遗留字段**(2026-09-01 起被下面的 Players 取代,只留着给一次性迁移用)。
	// 旧版本只能选一个播放器时写的就是这个键;Players 缺失时 resolvePlayers 把它当成
	// 迁移前的选择读一次,resolvePlayers 兜底成 playerAuto。这台机器往后只会写 Players,
	// 不会再写这个键,但读老配置(iCloud 同步/降级）时不能让它凭空消失。
	Player string `json:"player,omitempty"`
	// Players：可多选的播放器集合(2026-09-01 起支持多选,取代上面的 Player)——跟
	// lyrimuse 侧 FeatureSettingsStore.players(Set<PlaybackPlayer>)对应,rawValue 逐字
	// 相同。resolvePlayers 负责校验/迁移/兜底,任何时候 features.Players 都保证非空。
	Players       []string `json:"players,omitempty"`
	AlbumPrefetch *bool    `json:"album_prefetch,omitempty"`
	// LyricsAutoUpgrade:歌词定下来之后,还要不要跟着"匹配算法/打分规则升级"在后台自动
	// 换掉(2026-09-03 用户要求把这个能力交出来:「控制是否会有自动按照最新版本的算法优化
	// 调整歌词的能力;开了就是现状,不开就是一开始选了什么就不会后台自动给换了」)。
	// 缺失=true=现状。闸门只加在**换掉已有歌词**的那两条路径上(enrich.go 的
	// needsLyricsRescore / needsLyricsRetry),首次填充、封面/译文回填、用户手动重搜都不受它管。
	LyricsAutoUpgrade    *bool `json:"lyrics_auto_upgrade,omitempty"`
	LastfmMirrorScrobble *bool `json:"lastfm_mirror_scrobble,omitempty"`
	// LastfmScrobbleArtistMode：合唱串("A & B")上送时发哪个名字,三档
	// scrobbleArtistAll / scrobbleArtistFirst / scrobbleArtistSmart(2026-09-03 起)。
	// 缺失/非法值时退回下面的遗留布尔做一次迁移,见 resolveScrobbleArtistMode。
	// 语义与取舍见 lastfm.go 里 resolveScrobbleArtist 的注释。
	LastfmScrobbleArtistMode string `json:"lastfm_scrobble_artist_mode,omitempty"`
	// LastfmScrobbleFirstArtistOnly：**遗留字段**(2026-08-31 ~ 2026-09-03 之间的二态开关,
	// 被上面的 LastfmScrobbleArtistMode 取代,只留着给一次性迁移用)。true ↔ scrobbleArtistFirst,
	// false/缺失 ↔ scrobbleArtistAll。这台机器往后只写 LastfmScrobbleArtistMode,不再写它。
	LastfmScrobbleFirstArtistOnly *bool `json:"lastfm_scrobble_first_artist_only,omitempty"`
	// ScrobbleShortTracks:短于 minTrackSecs(30 秒)的曲目也 scrobble 到 Last.fm(2026-09-03 加,
	// 设置里 Last.fm →「短于 30 秒的曲目」)。**默认 false = 现状**:Last.fm 官方规则要求曲目长于
	// 30 秒,主流 scrobbler 都在客户端照做。**只管 Last.fm**(含给 Last.fm 兜底的本地收听日志和
	// 回填),ListenBrainz 不受影响 —— 见 poller.go tooShortToScrobble / shortTrackLastfmOnly。
	ScrobbleShortTracks *bool `json:"scrobble_short_tracks,omitempty"`
	WeeklyDigest        *bool `json:"weekly_digest,omitempty"`
	// DailyDigest：见 daily.go。跟 WeeklyDigest 是独立开关，两个可以同时开、只开一个、
	// 或都不开。
	DailyDigest *bool `json:"daily_digest,omitempty"`
	// WeeklyDigestSource/DailyDigestSource："lastfm"/"listenbrainz"/空。空值(用户
	// 从没在设置里手动选过)交给 resolveDigestSource(digest.go)按"两个账号都配了→
	// lastfm,只配了一个→用那个,都没配→跳过"自动判定,不是"缺省当 lastfm 处理"这么
	// 简单——所以这里特意留空字符串而不是给一个非空的默认值常量。
	WeeklyDigestSource string `json:"weekly_digest_source,omitempty"`
	DailyDigestSource  string `json:"daily_digest_source,omitempty"`
	// LyricsSources：启用的歌词源集合(lyricSourceXxx 常量的子集)。nil/缺失 = 全部
	// 启用,维持这个字段加之前的既有行为不变。
	LyricsSources []string `json:"lyrics_sources,omitempty"`
	// AMLLLyrics：**迁移标记,不是开关**。amll 的启用状态跟其余五源一样记在 LyricsSources 里。
	//
	// 它只解决一件事:LyricsSources 是白名单,而老配置写的时候 amll 这个源还不存在,列表里
	// 不可能有它 —— 按白名单办等于对所有老用户默认关闭,而"没列出"在这里的真实含义是
	// "当时没这个选项"。缺失 ⇒ 老配置,补进启用集合(只补这一次);一旦 App 保存过设置,
	// 这个字段就落盘,从此完全以 LyricsSources 为准。与 Swift 侧 FeatureFlagsFile.amllLyrics
	// 一一对应,改一边必须改另一边。
	AMLLLyrics *bool `json:"amll_lyrics,omitempty"`
	// LyricFindLyrics：跟 AMLLLyrics 同一个套路的迁移标记(2026-08-25 加 lyricfind 时补)。
	// lyricfind 没有 amll 那样"曾经有过独立开关"的历史——它从一开始就直接进
	// LyricsSources 白名单——但这个字段要解决的是**同一个**问题:老配置(写的时候
	// lyricfind 这个源还不存在)按白名单办会被静默关掉。缺失 ⇒ 老配置,把 lyricfind 补进
	// 启用集合(只补这一次);一旦保存过,这个字段落盘,从此完全以 LyricsSources 为准。
	// 与 Swift 侧 FeatureFlagsFile.lyricFindLyrics 一一对应。
	LyricFindLyrics *bool `json:"lyricfind_lyrics,omitempty"`
	// KuwoLyrics:跟 AMLLLyrics/LyricFindLyrics 同一个套路的迁移标记(2026-08-31 加
	// kuwo 时补)。老配置(写的时候 kuwo 这个源还不存在)按白名单办会被静默关掉。
	// 缺失 ⇒ 老配置,把 kuwo 补进启用集合(只补这一次);一旦保存过,这个字段落盘,
	// 从此完全以 LyricsSources 为准。与 Swift 侧 FeatureFlagsFile.kuwoLyrics 一一对应。
	KuwoLyrics *bool `json:"kuwo_lyrics,omitempty"`
	// LyricsSourceMode："smart"(默认,五源全查+打分取最高分,见 enrich.go 的
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
	// LyricsMachineTranslation:歌词源没带社区译文时,用机器翻译补一份(见 translate.go)。
	// **默认关**,跟其它附加功能一致 —— 它会把歌词正文发给第三方翻译服务,而现有的五个
	// 歌词源只发歌手/歌名,这是一条新的外发数据,该由用户显式同意。
	LyricsMachineTranslation *bool `json:"lyrics_machine_translation,omitempty"`
	// LaunchLyrimuseOnMusicOpen：检测到 Music.app 从没运行变成运行时,顺带启动/唤起
	// Lyrimuse.app(见 companionlaunch.go)。反方向("打开 Lyrimuse 时唤起 Music")
	// 不在这份共享文件里,是 Swift 侧 AppSettings 自己的纯本地设置,不需要 collector
	// 知道。
	LaunchLyrimuseOnMusicOpen *bool `json:"launch_lyrimuse_on_music_open,omitempty"`
	// TrustedPlayers:用户显式信任的"未知播放器"—— bundle id → 界面显示名。
	//
	// 「自动识别」原来只认写死的五个播放器,别的 App 在报 Now Playing 一律当"没有可关心
	// 的播放"。这道白名单不只挡显示,**也挡打卡**(poller.go 的 isTracked):放开它等于
	// 让 YouTube 视频、播客、网课被当成收听写进用户的 Last.fm/ListenBrainz 永久历史,
	// 还会往"设计上永不清理"的歌词缓存里灌垃圾条目、白烧五个歌词源的查询。而想靠内容
	// 形状分辨也不可靠 —— 浏览器里的网页播放器能通过 MediaSession API 自己填
	// title/artist/artwork,一个 YouTube 音乐视频跟一首歌长得一模一样。
	//
	// 所以口径是**用户显式同意**:设置页发现未知播放器就提示,用户点一下加进这里,之后
	// 它跟五个内置播放器完全同权(显示 + 打卡)。这样任何 App 都能接(包括这个项目从没
	// 听说过的),而默认状态下一条垃圾都进不来。
	TrustedPlayers map[string]string `json:"trusted_players,omitempty"`
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
// 已整个下线,见 alerter.go。2026-07-29:Last.fm 桥接(读 Last.fm 转发进 LB + 喂
// 网页"正在播放")加入这个"不需要单独开关"的阵营——之前独立的 LastfmBridge 开关
// 在 UI 上本来就要求"Last.fm 桥接凭据 + ListenBrainz 都配好"才能打开,跟自动判定
// 的条件完全一样,单独留一个开关只是多一次点击,没有实际区分度,见 poller.go 的
// bridge() 判断条件。
type featureFlags struct {
	// Players 是已经解析/校验过的播放器集合(键是 playerAppleMusic/playerQQMusic 等
	// 常量,值恒为 true;不会是空 map,见 resolvePlayers)——2026-09-01 从单选的 Player
	// 改成可多选。system.go 的 getState()/mediaPlayerLabel()、poller.go 的 isTracked()、
	// companionlaunch.go、match.go 的同源加权都读它。
	Players       map[string]bool
	AlbumPrefetch bool
	// 见 featureFlagsFile.LyricsAutoUpgrade。默认 true(现状)。
	LyricsAutoUpgrade    bool
	LastfmMirrorScrobble bool
	// 合唱串上送档位,恒为 scrobbleArtistAll/First/Smart 之一(resolveScrobbleArtistMode
	// 保证),默认 scrobbleArtistAll(发整串)。
	LastfmScrobbleArtistMode string
	// 见 featureFlagsFile.ScrobbleShortTracks。默认 false(短曲目不记,Last.fm 官方规则)。
	ScrobbleShortTracks bool
	WeeklyDigest        bool
	DailyDigest         bool
	WeeklyDigestSource  string
	DailyDigestSource   string
	// pickLyricCandidate(enrich.go)读这三个字段决定冠军。
	//
	// ⚠️ 2026-08-21 订正:原注释说 `collector search-lyrics` 子命令"从不调用
	// loadFeatureFlags、这三个字段在那条路径上永远是零值",**这是错的** —— searchcli.go
	// 一直自己加载一遍(不然 LyricsSources 是 nil map,过滤时五个源全被误判成"没启用"、
	// 直接返回空列表)。LyricsSources 早就被 filterEnabledLyricSources 实际读取着;
	// LyricsSourceMode/Order 在 -pick 模式下也被读(冠军要按用户选的「匹配算法」算)。
	// 这条错注释误导过一轮设计评审,别再照它推结论。
	LyricsSources     map[string]bool
	LyricsSourceMode  string
	LyricsSourceOrder []string
	// LyricsDir 空字符串表示"用默认位置",由 main.go 里设置包级变量 lyricsDir 时兜底,
	// 不在这里(loadFeatureFlags)展开成绝对路径——那时候 *cfgPath 还没解析完。
	LyricsDir string
	// LyricsTranslationLanguage 是已经解析过的具体 ISO 639-1 代码(不会是"auto"或空值,
	// 见 resolveLyricsTranslationLanguage)。三处读取,含义都是"译文要什么语言":
	// musixmatchTranslationLRC(musixmatch.go)向 Musixmatch 索取该语言的社区译文;
	// appleLangCode / myMemoryLangCode(translate.go)把它转成端上翻译和网络兜底
	// 各自的语言代码。网易云/QQ 不在此列——它们自带的社区译文只有中文,给不了别的语言。
	LyricsTranslationLanguage string
	// 见上面同名字段的注释。只被 needsTranslationBackfill/backfillTranslation 读取。
	LyricsMachineTranslation bool
	// LaunchLyrimuseOnMusicOpen 只被 companionlaunch.go 读取。
	LaunchLyrimuseOnMusicOpen bool
	// LyricsDecisionTrace 只被 lyricstrace.go 读取,见那边注释。
	LyricsDecisionTrace bool
	// TrustedPlayers 是已经清洗过的形态(见 resolveTrustedPlayers):键一定非空、一定不是
	// 五个内置播放器之一;值可能是空字符串(反查不到 App 名),此时标签退回 bundle id。
	TrustedPlayers map[string]string
}

// features is set once in main() before run() starts; every gate site reads
// this package-level value (same style as enrichCache/lyricsDir等既有包级状态)。
var features featureFlags

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
			log.Printf("parse feature flags %s: %v (使用默认值)", path, jerr)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		log.Printf("read feature flags %s: %v (使用默认值)", path, err)
	}
	return featureFlags{
		Players:        resolvePlayers(f.Players, f.Player),
		TrustedPlayers: resolveTrustedPlayers(f.TrustedPlayers),
		AlbumPrefetch:  boolOr(f.AlbumPrefetch, true),
		// 默认 true = 保持这个能力上线以来的行为;Swift 侧 `lyricsAutoUpgrade` 的属性初值
		// 必须跟这里一致(两侧默认值对齐那条老规矩,见上面 AlbumPrefetch 的注释)。
		LyricsAutoUpgrade:    boolOr(f.LyricsAutoUpgrade, true),
		LastfmMirrorScrobble: boolOr(f.LastfmMirrorScrobble, false),
		// 默认 scrobbleArtistAll:原样发整串。理由见 lastfm.go resolveScrobbleArtist ——
		// ListenBrainz 文档要求合唱 credit "include them all",Navidrome 同名开关默认也是 false。
		LastfmScrobbleArtistMode: resolveScrobbleArtistMode(f.LastfmScrobbleArtistMode, f.LastfmScrobbleFirstArtistOnly),
		// 默认 false:照 Last.fm 官方规则,短于 30 秒不记。fail-closed 跟其余"改变上送内容"的
		// 开关一致——字段缺失不能让老用户的历史突然多出一批短曲目。
		ScrobbleShortTracks:       boolOr(f.ScrobbleShortTracks, false),
		WeeklyDigest:              boolOr(f.WeeklyDigest, false),
		DailyDigest:               boolOr(f.DailyDigest, false),
		WeeklyDigestSource:        f.WeeklyDigestSource,
		DailyDigestSource:         f.DailyDigestSource,
		LyricsSources:             resolveLyricsSources(f.LyricsSources, f.AMLLLyrics, f.LyricFindLyrics, f.KuwoLyrics),
		LyricsSourceMode:          resolveLyricsSourceMode(f.LyricsSourceMode),
		LyricsSourceOrder:         resolveLyricsSourceOrder(f.LyricsSourceOrder),
		LyricsDir:                 f.LyricsDir,
		LyricsTranslationLanguage: resolveLyricsTranslationLanguage(f.LyricsTranslationLanguage),
		LyricsMachineTranslation:  boolOr(f.LyricsMachineTranslation, false),
		LaunchLyrimuseOnMusicOpen: boolOr(f.LaunchLyrimuseOnMusicOpen, true),
		LyricsDecisionTrace:       boolOr(f.LyricsDecisionTrace, false),
	}
}

// 合唱串上送档位(features.LastfmScrobbleArtistMode)。字符串值跟 Swift 侧
// LastfmScrobbleArtistMode 的 rawValue 逐字相同 —— 两侧通过同一份 features.json 交换。
const (
	// 原样发播放器报的整串(默认)。
	scrobbleArtistAll = "all"
	// 纯字符串取第一位(firstCreditedArtist),不联网。
	scrobbleArtistFirst = "first"
	// 按 Last.fm 编目判定:合唱串已被收录就原样发;没收录、而第一位歌手名下这首歌已被
	// 收录才折成第一位;两边都查不到或查询失败维持原样。见 lastfmcollapse.go。
	scrobbleArtistSmart = "smart"
)

// resolveScrobbleArtistMode 把文件里的档位字符串校验成三个常量之一;缺失/非法时退回
// 遗留的二态开关 lastfm_scrobble_first_artist_only 做一次迁移(true → first),两者都没有
// 才兜底 all。非法值**不**当成 all 静默吞掉之外还会记一行日志 —— 拼错档位名的后果是
// "设置里选了智能、collector 一直在发整串",不报出来查不到。
func resolveScrobbleArtistMode(raw string, legacyFirstOnly *bool) string {
	switch raw {
	case scrobbleArtistAll, scrobbleArtistFirst, scrobbleArtistSmart:
		return raw
	case "":
	default:
		log.Printf("feature flags: unknown lastfm_scrobble_artist_mode %q (falling back)", raw)
	}
	if legacyFirstOnly != nil && *legacyFirstOnly {
		return scrobbleArtistFirst
	}
	return scrobbleArtistAll
}

// isValidPlayerValue 核对一个字符串是不是六个已知播放器 rawValue 之一——resolvePlayers
// 校验列表条目、以及迁移路径校验 legacy 字段共用同一份判据。
func isValidPlayerValue(p string) bool {
	switch p {
	case playerAppleMusic, playerQQMusic, playerNetease, playerSpotify, playerKugou, playerAuto:
		return true
	default:
		return false
	}
}

// resolvePlayers 是 2026-09-01 从单选 resolvePlayer 改成多选后的替代——list 是新字段
// featureFlagsFile.Players(可能为 nil,老配置/全新安装都会是这样),legacy 是旧字段
// Player(单选年代写的值)。
//
// 优先级:list 里任何认得出的值都收进结果集,认不出的静默丢弃(比如未来某个版本删掉的
// 播放器,不该让整份解析失败)；list 过滤后一个能收的都没有(nil/空/全认不出),才退回
// legacy 做**一次性迁移**——老配置只选过一个,迁移后的结果集就是那一个;legacy 也认不出
// 或本身是空值,才最终兜底成 playerAuto(2026-08-13 定的默认,理由见 PlaybackPlayer.swift
// 顶部注释:写死 Apple Music 会让只用 Spotify/QQ 音乐/网易云的新用户对着一个永远空白的
// 界面)。返回值保证非空、且键全部是六个已知值之一,调用方可以放心用 `m[playerXxx]` 判断
// 成员,不需要再校验一遍。
func resolvePlayers(list []string, legacy string) map[string]bool {
	m := map[string]bool{}
	for _, p := range list {
		if isValidPlayerValue(p) {
			m[p] = true
		}
	}
	if len(m) > 0 {
		return m
	}
	if isValidPlayerValue(legacy) {
		return map[string]bool{legacy: true}
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
	builtin := map[string]bool{
		"com.apple.Music": true, qqMusicBundleID: true,
		neteaseMusicBundleID: true, spotifyBundleID: true, kugouMusicBundleID: true,
	}
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

func resolveLyricsSources(list []string, amllSeen *bool, lyricFindSeen *bool, kuwoSeen *bool) map[string]bool {
	if len(list) == 0 {
		return map[string]bool{
			lyricSourceNetease: true, lyricSourceQQ: true, lyricSourceKugou: true,
			lyricSourceMusixmatch: true, lyricSourceLRCLIB: true,
			lyricSourceAMLL: true, lyricSourceLyricFind: true, lyricSourceKuwo: true,
		}
	}
	m := make(map[string]bool, len(list)+1)
	for _, s := range list {
		m[s] = true
	}
	// 老配置的一次性迁移,见 featureFlagsFile.AMLLLyrics/.LyricFindLyrics/.KuwoLyrics。三个
	// 标记各自独立判断——一份配置可能在 amll 时代之后、lyricfind 时代之前保存过(amllSeen
	// 非空、lyricFindSeen 为空),这种配置只该补 lyricfind,不该把 amll 也重新补一遍(用户
	// 可能已经手动关掉了它)。
	//
	// ⚠️ 2026-08-25 实测坐实过一次:这里漏了迁移标记参数的那版代码,在这台机器真实的
	// lyrimuse-features.json(lyrics_sources 只有旧的六个、没有对应迁移字段)上跑
	// search-lyrics,sourcesTotal 停在 6、候选列表里一条新源都没有——「代码接好了但
	// 静默对现有用户不生效」不是假设的风险,是真的在这台机器上复现过的 bug,加上这几个
	// 迁移标记的**回归测试**就是防它复发。
	if amllSeen == nil {
		m[lyricSourceAMLL] = true
	}
	if lyricFindSeen == nil {
		m[lyricSourceLyricFind] = true
	}
	if kuwoSeen == nil {
		m[lyricSourceKuwo] = true
	}
	return m
}

// lyricSourceEnabled 是"这个歌词源开着吗"的**唯一**判据。判定原先散在六处、形式还不
// 完全一致(有的带 len==0 兜底、有的不带),统一到这里。
// 注:resolveLyricsSources 在列表为空时返回全集,所以 LyricsSources 永远非 nil,
// 那些 len==0 的兜底其实是历史冗余,留着不碍事。
func lyricSourceEnabled(source string) bool {
	return len(features.LyricsSources) == 0 || features.LyricsSources[source]
}

func resolveLyricsSourceMode(mode string) string {
	if mode == lyricsModePriority {
		return lyricsModePriority
	}
	return lyricsModeSmart
}

func resolveLyricsSourceOrder(order []string) []string {
	if len(order) == 0 {
		return append([]string(nil), lyricsSourceDefaultOrder...)
	}
	return order
}

// resolveLyricsTranslationLanguage 把共享文件里的"auto"/空值解析成一个具体的 ISO
// 639-1 代码——collector 是长驻后台进程(launchd gui/$(id -u) 用户级 agent,跟登录用户
// 的 Aqua 会话同一身份运行),用 `defaults read -g AppleLocale` 能可靠读到这台 Mac 当前
// 的系统语言,不依赖 launchd 环境变量(环境变量对用户级 agent 不一定完整继承登录 shell
// 的 locale 设置)。读不到/查不到对应语言代码时兜底 "en"——总比整段不请求译文更有用。
// 只在启动时解析一次(跟这个文件里其它字段同一个"读一次,重启才生效"的既定约定),运行
// 中途切系统语言不会实时生效。
func resolveLyricsTranslationLanguage(lang string) string {
	if lang != "" && lang != "auto" {
		return lang
	}
	if code := systemLanguageCode(); code != "" {
		return code
	}
	return "en"
}

// systemLanguageCode 读 macOS 当前系统语言,取 AppleLocale("zh_Hans_CN"/"en_US"/
// "ja_JP"这类形式)下划线前的两位语言代码并转小写。查询失败(命令不存在/超时/返回值
// 解析不出下划线分隔的语言段)一律返回空串,交给调用方兜底,不 panic、不重试。
func systemLanguageCode() string {
	out, err := exec.Command("defaults", "read", "-g", "AppleLocale").Output()
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(string(out))
	if i := strings.IndexByte(s, '_'); i > 0 {
		s = s[:i]
	}
	if s == "" {
		return ""
	}
	return strings.ToLower(s)
}
