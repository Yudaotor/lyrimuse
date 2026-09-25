import Foundation
import LyrimuseCore
import os
import SwiftUI

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "feature-settings")

// 十二个歌词源——rawValue 必须跟 collector/features.go 的 lyricSourceXxx 常量逐字对应,
// 这是两侧通过共享 json 文件交换的字符串。displayName/color 直接委托给
// LyricsManagerView.swift 已有的 sourceDisplayName/sourceColor(那两个函数今天也在给
// "歌词管理"窗口的来源筛选/列表用),不重复维护第二份名字/颜色映射。
//
// **声明顺序是有语义的,不是随手排的**,它同时是两处的顺序:
//   ① 设置页「歌词来源」那张卡里九个勾选框的展示序(`ForEach(LyricsSource.allCases)`);
//   ② 「顺序优先」模式下 `lyricsSourceOrder` 的**默认值**(见下面 @Published 的初值)——
//      也就是新装机器上"按顺序取第一个有结果的源"真正的取用顺序。用户拖拽排过之后
//      以自己那份为准,改这里只影响没排过的人。
// 所以它必须跟 collector `features.go` 的 `lyricsSourceDefaultOrder` **逐字同序**,
// 否则同一台机器在首次写盘前后表现不同(那边注释也钉着这条)。
//
// 排序依据(按实测调整):前五个按真实采用率排 —— 用户本机 3744 条 enrich 缓存里
// 最终被采用的歌词来自 酷狗 1506(40.2%)/ 网易云 1125(30.0%)/ QQ 732(19.6%)/
// Musixmatch 176(4.7%)/ LRCLIB 74(2.0%),酷狗是第一主力却长期排在第三,这次提到首位。
// 后五个(amll/lyricfind/kuwo/migu/deezer)**刻意不按采用率排**:它们分别是 /
// 08-31 / 08-31 / 09-04 / 09-13 才接入的,那 3744 条缓存绝大多数早于它们存在,采用数 0~16 是
// 样本偏差、不是覆盖率结论。等各自跑满一段时间再拿数据说话,别用"没赶上考试"当"考砸了"。
// deezer 跟 lyricfind 数据同源(都是 LyricFind 供词),但两条管道各走各的接口:接它既是
// 给那家版权方补条后路,也因为 Deezer 的法语曲库覆盖更好,见 collector/deezer.go 头注。
public enum LyricsSource: String, CaseIterable, Identifiable, Codable, Hashable {
    case kugou, netease, qq, musixmatch, lrclib, amll, lyricfind, kuwo, migu, deezer, applemusic, soda
    public var id: Self { self }
    public var displayName: String { sourceDisplayName(rawValue) }
    public var color: Color { sourceColor(rawValue) }

    /// 「歌词来源」卡里的排列:中文用户中文源在前,其余用户国外源在前(规则见 `LyricsSourceRegion`)。
    /// 只是显示顺序,不影响「顺序优先」的优先级。
    static var settingsDisplayOrder: [LyricsSource] {
        let chineseFirst = LyricsSourceRegion.prefersChineseSources(
            appLanguageOverride: L10n.languageOverride, preferredLanguage: Locale.preferredLanguages.first)
        return LyricsSourceRegion.displayOrder(allCases.map(\.rawValue), chineseFirst: chineseFirst)
            .compactMap(LyricsSource.init(rawValue:))
    }
}

// Musixmatch 译文(collector/musixmatch.go 的 crowd.track.translations.get)目标语言——
// 网易云/QQ 音乐的译文固定是中文,只有 Musixmatch 这个源能指定任意语言,rawValue 必须是
// Musixmatch 认的 ISO 639-1 两位小写代码(已用真实接口核实过这个格式,见开发时的调研)。
// .auto 的字面值原样写进共享 json,由 collector 侧 resolveLyricsTranslationLanguage
// (features.go)解析成具体代码——那边用 `defaults read -g AppleLocale` 读 macOS 系统
// 语言,不是 Swift 这边解析:collector 是长驻后台进程,读一次系统级偏好设置比 Swift
// App 每次保存时读 Locale.current 更贴近"用户实际在用的系统语言此刻是什么",也让这个
// 字段跟这个 store 里其它字段一样,原始 rawValue 直接对称读写、不需要额外的解析层。
// 跟随的是 macOS 系统语言而不是 App 界面语言:App 界面本身只做了中英两版翻译,母语是
// 西语/日语等的用户即使 App 界面只能显示英文,系统语言仍然如实反映其母语,能让这个
// 功能真正惠及"母语非中非英"的用户,而不是被 App 界面语言的两个选项卡住。
public enum MusixmatchTranslationLanguage: String, CaseIterable, Identifiable, Codable {
    case auto
    case en, zh, ja, ko, es, fr, de, pt, it, ru, ar, vi, th, id, nl, pl, tr

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .auto: return L10n.t("跟随系统语言")
        case .en: return "English"
        case .zh: return "简体中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .pt: return "Português"
        case .it: return "Italiano"
        case .ru: return "Русский"
        case .ar: return "العربية"
        case .vi: return "Tiếng Việt"
        case .th: return "ไทย"
        case .id: return "Bahasa Indonesia"
        case .nl: return "Nederlands"
        case .pl: return "Polski"
        case .tr: return "Türkçe"
        }
    }
}

// PlaybackPlayer 定义在 LyrimuseCore(见 Local/PlaybackPlayer.swift 与生成的
// Local/PlaybackPlayer+Generated.swift)——MediaControlClient/LocalPlaybackSource 也需要
// 认这个类型,而它们在 LyrimuseCore、不能反向依赖这个(lyrimuse 主 App target)文件,所以
// 类型本身放在被依赖的下层,这里只是引用。
//
// displayName / tintColor / fallbackSymbolName / bundledIconResourceName 和两份顺序
// 清单,现在由 scripts/gen-players.py 从 shared/players.json 生成,在同目录的
// PlaybackPlayerMeta+Generated.swift —— 接一个新播放器改那份 JSON,不改这里。
// 留在这里的只有"按系统语言二选一"这条判断:它是逻辑,不是每播放器一行的数据。
extension PlaybackPlayer {
    /// 图标网格(引导页"选择播放器" + 设置页"播放器"卡)的摆放顺序,按
    /// 系统语言排——只影响这两处图标网格,不改 `allCases` 本身:这个类型别的消费点
    /// (`PlaybackCoordinator.allCases.first(where:)` 这类按 bundle id 查找)不关心顺序,
    /// 没有必要跟着这条语言判断联动。
    ///
    /// Apple Music 两种语境下都排第一(系统自带、认知成本最低),「自动识别」恒定垫底
    /// (它不是一个具体播放器,当兜底选项摆最后符合直觉)。中间四个按这批用户的实际
    /// 使用习惯排:简体中文语境下国内三家排在 Spotify 前面;非简体中文(含繁体中文/
    /// 英文等)语境反过来,Spotify 排到国内三家前面。两份清单本身在生成文件里。
    public static var displayOrder: [PlaybackPlayer] {
        AppSettings.userReadsSimplifiedChinese ? displayOrderForSimplifiedChinese : displayOrderDefault
    }
}

// "智能算法"=四源全查+打分取最高分(现有行为,见 collector/enrich.go 的
// scoredLyricCandidates/pickLyricCandidate);"顺序优先"=按用户手排的顺序,取第一个
// 通过质量校验的源,不比较分数。
public enum LyricsSourceMode: String, CaseIterable, Identifiable, Codable {
    case smart, priority
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .smart: return L10n.t("智能算法")
        case .priority: return L10n.t("顺序优先")
        }
    }
}

// 上送 Last.fm 前怎么对待播放器报的标签(三档)。rawValue 必须跟 collector features.go 的
// lastfmMatchSmart/Custom/Raw 常量逐字相同——两侧通过同一份 features.json 交换,collector
// 只认这三个串,拼错就静默退回 raw。
//
// - smart:在 Last.fm 编目里找这首歌对应的条目,歌手和曲名都按那条发(collector
//   lastfmcatalog.go)。等价于「自定义」下把改歌手、改曲名都打开。全新装机的默认档。
// - custom:曲名、歌手两个维度各自选,见 `LastfmTrackRule` / `LastfmArtistRule`(它们是
//   `lastfmMatchArtist` / `lastfmMatchTrack` / `lastfmMatchFirstArtistOnly` 三个落盘布尔的界面形状)。
// - raw:原样发播放器报的标签,一个字都不动、不打网络;老装机(features.json 已存在)的
//   默认档,两条默认值的分野见 `FeatureSettingsStore` 里 `isFreshInstall` 那段。
//
// **case 的声明顺序就是分段控件上从左到右的顺序** —— 唯一的消费点是
// `AccountLinkingTab.lastfmScrobbleSettingsCard` 里那个 `ForEach(allCases)`,所以「智能」写在最前。
// rawValue 才是跟 collector 的契约,与顺序无关:重排不动已存的值,也不动两侧的默认档。
public enum LastfmMatchMode: String, CaseIterable, Identifiable, Codable {
    case smart, custom, raw
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .smart: return L10n.t("智能")
        case .custom: return L10n.t("自定义")
        case .raw: return L10n.t("原始")
        }
    }
}

// 「自定义」档下曲名怎么发。**不是新的落盘契约** —— 它是 `lastfm_match_track` 那个布尔的
// 界面形状(catalog = true、raw = false),features.json 的字段一个没动,collector 侧
// resolveScrobbleTags 也不用跟着改。
//
// 做成选项而不是继续用开关:「改写曲名」四个字没说出**改成什么**,开关只表达得了开/关,
// 选项能把「改用编目里的写法」和「原样发」两件事都摆在明面上。
public enum LastfmTrackRule: String, CaseIterable, Identifiable, Codable {
    case catalog, raw
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .catalog: return L10n.t("匹配条目")
        case .raw: return L10n.t("原始")
        }
    }
}

// 「自定义」档下歌手怎么发。同样是既有两个布尔(`lastfm_match_artist` /
// `lastfm_match_first_artist_only`)的界面形状,不是新契约。
//
// 这三档**互斥**,而盘上那两个布尔还能表达出第四种组合(两个都 true =「先按编目匹配,
// 匹配不到再截第一位」)。界面不再产出这种组合;读到它时按 `.catalog` 显示 —— 匹配本来就
// 优先、截断只是它的兜底 —— 用户下一次拨动就会把它归一掉。
public enum LastfmArtistRule: String, CaseIterable, Identifiable, Codable {
    case catalog, firstOnly, raw
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .catalog: return L10n.t("匹配条目")
        case .firstOnly: return L10n.t("只发第一位")
        case .raw: return L10n.t("原始")
        }
    }
}

// Last.fm scrobble 时点:一次收听听到哪里才记到 Last.fm。rawValue 必须跟 collector
// features.go 的 scrobblePointHalf/75/90/End 常量逐字相同——两侧通过同一份 features.json 交换,
// collector 只认这四个串,拼错就静默退回官方规则。
//
// - half("50"):官方规则,曲长一半或 4 分钟,先到为准(默认)。这也是 ListenBrainz 那一路提交的时刻,
//   所以这一档下 Last.fm 跟加这个设置之前一样当场发。
// - threeQuarters("75") / ninety("90"):听满曲长的 75% / 90%,纯按已播时长算,不套 4 分钟上限。
// - end("end"):一直放到结尾才记,中途切歌不记(判据见 collector poller.go sessionEndedNaturally)。
//
// **只管 Last.fm**(「只考虑 lastfm 的」):ListenBrainz、网页中继照旧在官方阈值那一刻提交,
// Last.fm 那一路(含给它兜底的本地收听日志)挂起到点再发。官方规则是下限,所以没有低于一半的档;
// 曲长未知时按官方规则。
public enum LastfmScrobblePoint: String, CaseIterable, Identifiable, Codable {
    case half = "50", threeQuarters = "75", ninety = "90", end
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .half: return "50%"
        case .threeQuarters: return "75%"
        case .ninety: return "90%"
        case .end: return L10n.t("曲终")
        }
    }
}

// 跟 collector/features.go 的 featureFlagsFile 逐字段对应的 on-disk 形状——所有字段
// 可选(nil = 沿用默认开启),跟 collector 侧"文件缺失/字段缺失都当作 true"的约定一致,
// 这里存的是 Lyrimuse 这台机器上用户明确设置过的值。collector/features.go 那侧是
// 同一份共享 JSON 文件的镜像,字段增删两侧同步;旧配置文件里如果还留着已经删掉的
// key,JSONDecoder/Go 的 encoding/json 都会静默忽略未知字段,不需要额外的迁移代码。
struct FeatureFlagsFile: Codable, Equatable {
    // player:**遗留字段**(被下面的 players 取代,只留着给一次性迁移用)。
    // 旧版本只能选一个播放器时写的就是这个键;players 缺失时 load() 把它当迁移前的
    // 选择读一次。这台机器往后只会写 players,不会再写这个键,但读老配置(iCloud
    // 同步/降级)时不能让它凭空消失——跟 collector 侧 featureFlagsFile.Player 对称。
    var player: String?
    // players:可多选的播放器集合(支持多选,取代上面的 player)——
    // PlaybackPlayer 的 rawValue 数组:"auto"/"apple_music"/"qq_music"/"netease_music"/
    // "kugou_music"/"spotify"(见 PlaybackPlayer 注释,LyrimuseCore)。跟 LyrimuseCore
    // 的 PlaybackPlayerPreference.selected 读的是同一个键,collector 侧对应
    // featureFlagsFile.Players。
    //
    // 生效时机两侧**不一样**,别照抄别的字段的说法:LocalPlaybackSource 每次轮询都会
    // 重新读一次这个字段(它在 LyrimuseCore,没法直接订阅这个 store 的 @Published),
    // 所以 App 侧改了立刻生效;collector 只在启动时读一次,要靠保存触发的 kickstart
    // 重启才会跟上。
    var players: [String]?
    var albumPrefetch: Bool?
    /// 歌词定下来之后要不要跟着算法/打分升级在后台自动换掉。缺失=true(现状),
    /// 跟 collector 侧 `boolOr(f.LyricsAutoUpgrade, true)` 对齐。
    var lyricsAutoUpgrade: Bool?
    var lyricsMachineTranslation: Bool?
    var lastfmMirrorScrobble: Bool?
    /// 合唱串上送档位,LastfmScrobbleArtistMode 的 rawValue("all"/"first"/"smart")。
    /// 缺失时 load() 退回下面的遗留布尔做一次迁移。
    var lastfmMatchMode: String?
    /// 下面三个只在 `custom` 档下读(另两档的值由档位本身决定)。都缺失时按 false ——
    /// fail-closed 跟其余"改变上送内容"的开关一致。
    var lastfmMatchArtist: Bool?
    var lastfmMatchTrack: Bool?
    var lastfmMatchFirstArtistOnly: Bool?
    /// **遗留字段**(被上面的 lastfmMatchMode 取代,只留着给一次性迁移用):
    /// `smart` 与 智能、`all` 与 原始、`first` 与 自定义且只开「合唱只发第一位」。
    var lastfmScrobbleArtistMode: String?
    /// **更早的遗留字段**(二态开关,被 lastfmScrobbleArtistMode 取代):true 与 旧的 `first`。
    /// 迁移链因此是两级:这个 → ArtistMode → MatchMode。跟 collector 侧 featureFlagsFile 对称。
    var lastfmScrobbleFirstArtistOnly: Bool?
    /// 短于 30 秒的曲目也 scrobble 到 Last.fm。**默认 false = 现状**(Last.fm 官方规则要求曲目长于
    /// 30 秒)。只管 Last.fm(含给它兜底的本地收听日志/回填),ListenBrainz 不受影响 —— 见
    /// collector poller.go tooShortToScrobble / shortTrackLastfmOnly。
    var scrobbleShortTracks: Bool?
    /// Last.fm scrobble 时点,LastfmScrobblePoint 的 rawValue("50"/"75"/"90"/"end")。缺失 = 官方规则
    /// (跟 collector 侧 resolveScrobblePoint 的兜底一致)。只管 Last.fm,见枚举注释。
    var lastfmScrobblePoint: String?
    var weeklyDigest: Bool?
    // 见 collector/daily.go——独立于 weeklyDigest 的开关,两个可以同时开、只开一个、
    // 或都不开。
    var dailyDigest: Bool?
    // "lastfm"/"listenbrainz"/缺省(空字符串)——两个 cadence 各自用哪个账号的数据源,
    // 缺省时按 collector/digest.go 的 resolveDigestSource 规则(两个都配了→lastfm,
    // 只配了一个→用那个,都没配→这个功能没法跑)自动判定,不是"缺省当 lastfm 处理"
    // 这么简单,所以特意不给非空默认值。两个 cadence 都能自己选数据源,是因为
    // Last.fm 的周榜接口其实接受任意 from/to,不是只认它自己的官方周边界。
    var weeklyDigestSource: String?
    var dailyDigestSource: String?
    // 见 collector/calendardigest.go——每月 / 年度听歌小结,跟周报、日报都是独立开关;数据源
    // 字段同上,缺省交给 resolveDigestSource。
    var monthlyDigest: Bool?
    var yearlyDigest: Bool?
    var monthlyDigestSource: String?
    var yearlyDigestSource: String?
    var lyricsSources: [String]?
    /// **迁移标记,不是开关**。amll 的启用状态跟其余源一样记在 lyricsSources 里。
    ///
    /// 它存在只为解决一件事:lyrics_sources 是白名单,而老配置写的时候 amll 这个源还不
    /// 存在,列表里不可能有它 —— 直接按白名单办等于对所有老用户默认关闭,而"没列出"在
    /// 这里的真实含义是"当时没这个选项",不是"用户排除了它"。
    ///
    /// 所以:缺失 到 这是一份老配置,加载时把 amll 补进启用集合(只补这一次);一旦保存过,
    /// 这个字段就落盘,从此完全以 lyricsSources 为准,用户取消勾选能正常生效。
    /// 与 collector 侧 featureFlagsFile.AMLLLyrics 一一对应。
    var amllLyrics: Bool?
    /// 跟 amllLyrics 同一个套路的迁移标记(加 lyricfind 时补)。lyricfind 没有
    /// amll 那样"曾经有过独立开关"的历史,但要解决的是**同一个**问题:老配置(写的时候
    /// lyricfind 这个源还不存在)按白名单办会被静默关掉。缺失 到 老配置,加载时把 lyricfind
    /// 补进启用集合(只补这一次)。与 collector 侧 featureFlagsFile.LyricFindLyrics 一一对应。
    var lyricFindLyrics: Bool?
    /// 跟 amllLyrics/lyricFindLyrics 同一个套路的迁移标记(加 kuwo 时补)。
    /// 缺失 到 老配置,加载时把 kuwo 补进启用集合(只补这一次)。与 collector 侧
    /// featureFlagsFile.KuwoLyrics 一一对应。
    var kuwoLyrics: Bool?
    /// 同上一套迁移标记(加 migu 时补)。缺失 到 老配置,加载时把 migu 补进启用集合
    /// (只补这一次)。与 collector 侧 featureFlagsFile.MiguLyrics 一一对应。
    var miguLyrics: Bool?
    /// 同上一套迁移标记(加 deezer 时补)。缺失 到 老配置,加载时把 deezer 补进
    /// 启用集合(只补这一次)。与 collector 侧 featureFlagsFile.DeezerLyrics 一一对应。
    var deezerLyrics: Bool?
    /// 同上一套迁移标记(加 applemusic 时补)。与 collector 侧 featureFlagsFile.AppleMusicLyrics
    /// 一一对应 —— 这个对应关系是硬性的:少了它,collector 那边 appleMusicSeen 恒为 nil、
    /// 每次加载都把 applemusic 补回启用集合,用户在界面上取消勾选 Apple Music 对后台完全无效
    /// (界面自己按 lyrics_sources 显示成已取消,两边说法不一致)。
    var appleMusicLyrics: Bool?
    /// 同上一套迁移标记(加 soda 时补)。与 collector 侧 featureFlagsFile.SodaLyrics 一一对应。
    var sodaLyrics: Bool?
    var lyricsSourceMode: String?
    var lyricsSourceOrder: [String]?
    var lyricsDir: String?
    // "auto"(跟随系统语言,默认)或具体 ISO 639-1 代码("en"/"zh"/"ja"...)——见
    // MusixmatchTranslationLanguage 注释,collector 侧负责把 "auto" 解析成具体代码。
    var lyricsTranslationLanguage: String?
    // 打开 Apple Music 时顺带唤起 Lyrimuse——这个方向的联动由 collector(常驻后台,
    // 不依赖 Lyrimuse.app 主进程是否在运行)负责监测 Music.app 的启动状态,见
    // collector/companionlaunch.go。反方向("打开 Lyrimuse 时唤起 Music")不需要
    // 这份共享文件,直接是 AppSettings.launchMusicOnLyrimuseOpen 一个纯 Swift 侧设置。
    var launchLyrimuseOnMusicOpen: Bool?
    /// 「跟随播放器启动」逐播放器勾选(PlaybackPlayer.rawValue 列表)。键在就严格按它来(空列表 = 关),
    /// 键缺失是布尔年代的老配置,collector 退回「盯整个选中集合 / auto 全量」。上面那个布尔仍然写(= 列表非空),
    /// 给还没升级的 collector 当总开关用;collector 侧对称的解析见 features.go / companionlaunch.go。
    var launchLyrimuseOnPlayers: [String]?
    /// 用户显式信任的「未知播放器」:bundle id → 界面显示名(反查不到 App 名时是空串)。
    /// 语义见 LyrimuseCore 的 TrustedPlayers —— 为什么是"信任列表"而不是"一律接受",
    /// 那份注释里写了(白名单同时挡着打卡,一律接受会把视频/播客写进永久收听历史)。
    var trustedPlayers: [String: String]?
    /// **不** scrobble 到 Last.fm 的播放器(bundle id 列表)。缺失 / 空 = 全部上送。
    /// 只管 Last.fm(含给它兜底的本地收听日志与 now-playing),ListenBrainz 不受影响。与 collector 的
    /// featureFlagsFile.LastfmExcludedBundles 一一对应,语义见那边 lastfmexclude.go 头注。
    var lastfmExcludedBundles: [String]?

    /// CaseIterable 是为了让 `knownFileKeys` 能自动跟着字段增删走 —— 手工维护第二份
    /// 键名清单迟早会跟这里对不上,而对不上的后果正是下面要修的那种静默丢数据。
    enum CodingKeys: String, CodingKey, CaseIterable {
        case player
        case players
        case albumPrefetch = "album_prefetch"
        case lyricsAutoUpgrade = "lyrics_auto_upgrade"
        case lyricsMachineTranslation = "lyrics_machine_translation"
        case lastfmMirrorScrobble = "lastfm_mirror_scrobble"
        case lastfmMatchMode = "lastfm_match_mode"
        case lastfmMatchArtist = "lastfm_match_artist"
        case lastfmMatchTrack = "lastfm_match_track"
        case lastfmMatchFirstArtistOnly = "lastfm_match_first_artist_only"
        case lastfmScrobbleArtistMode = "lastfm_scrobble_artist_mode"
        case lastfmScrobbleFirstArtistOnly = "lastfm_scrobble_first_artist_only"
        case scrobbleShortTracks = "scrobble_short_tracks"
        case lastfmScrobblePoint = "lastfm_scrobble_point"
        case weeklyDigest = "weekly_digest"
        case dailyDigest = "daily_digest"
        case weeklyDigestSource = "weekly_digest_source"
        case dailyDigestSource = "daily_digest_source"
        case monthlyDigest = "monthly_digest"
        case yearlyDigest = "yearly_digest"
        case monthlyDigestSource = "monthly_digest_source"
        case yearlyDigestSource = "yearly_digest_source"
        case lyricsSources = "lyrics_sources"
        case amllLyrics = "amll_lyrics"
        case lyricFindLyrics = "lyricfind_lyrics"
        case kuwoLyrics = "kuwo_lyrics"
        case miguLyrics = "migu_lyrics"
        case deezerLyrics = "deezer_lyrics"
        case appleMusicLyrics = "applemusic_lyrics"
        case sodaLyrics = "soda_lyrics"
        case lyricsSourceMode = "lyrics_source_mode"
        case lyricsSourceOrder = "lyrics_source_order"
        case lyricsDir = "lyrics_dir"
        case lyricsTranslationLanguage = "lyrics_translation_language"
        case launchLyrimuseOnMusicOpen = "launch_lyrimuse_on_music_open"
        case launchLyrimuseOnPlayers = "launch_lyrimuse_on_players"
        case trustedPlayers = "trusted_players"
        case lastfmExcludedBundles = "lastfm_excluded_bundles"
    }

    /// 这个版本认识的全部 JSON 键。见 FeatureSettingsStore.unknownFileKeys 的注释。
    static let knownFileKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))
}

// "歌词"tab 的纯行为开关(lyrics/albumPrefetch 等)和"账号连接"tab 里各张
// 账号卡片的开关(lastfmMirrorScrobble/weeklyDigest)共用同一份数据层——读写
// ~/.config/lyrimuse/lyrimuse-features.json,跟
// collector/features.go 是同一份共享文件的两侧独立实现。Last.fm 桥接
// (读 Last.fm 转发进 ListenBrainz + 喂网页"正在播放")不再是这里的一个独立开关——
// Last.fm 桥接凭据 + ListenBrainz 账号都配好就自动生效,跟 collector 侧
// poller.go 的 bridge() 判断条件一致,见那边的注释。
//
// 这个 store 里的每一个开关都是"改了立刻保存"——Binding 的 set 里包一层
// `Task { await features.save() }`,持久化+重启挪到后台执行,但从用户视角"点开关
// 立刻生效"这个体验不变(不需要等;设置窗口底部有一条**不阻塞**的状态条
// CollectorApplyStatusBar:重启进行中一行小字、重启失败给原因和「重试」、后台服务被主动停用给
// 中性提示——lastError 从此有人读)。"账号连接"tab 底部那条
// 批量保存栏(isDirty/saveBar)管的是 ConfigStore 的文本/密钥字段,跟这个 store 的开关
// 无关,不要混为一谈。
@MainActor
public final class FeatureSettingsStore: ObservableObject {
    public static let shared = FeatureSettingsStore()

    // 本地播放状态读取哪个 App(集合,可多选)——默认**{自动识别}**。
    //
    // 初值必须跟 collector 侧 resolvePlayers 的兜底(`.auto`)与下面 load() 的兜底
    // (`?? [.auto]`)一致:features.json **还不存在**时(全新安装)load() 会在 guard 处
    // 提前 return,界面就停在这个初值上——三处不一致会导致设置里显示的播放器和
    // collector 实际采集的播放器不是一回事。
    //
    // 保证非空——UI 层(播放器卡片网格)负责不让用户把最后一个选项也取消勾选,跟
    // LyrimuseCore 的 PlaybackPlayerPreference.selected/collector 的 resolvePlayers
    // 同一份"选中集合永远至少有一个成员"的不变量。
    @Published public var players: Set<PlaybackPlayer> = [.auto]

    /// 点一下切换这个播放器的选中状态,并落盘。设置页「播放器」卡和引导页「选择播放器」
    /// 那一步共用这一份(从 `SettingsView.toggleSelectedPlayer` 提上来 ——
    /// 引导页同日从单选改成多选,两处各写一遍就有两份"最后一个能不能取消"的判断)。
    ///
    /// 「自动识别」跟具体播放器不是互斥关系,可以一起勾——见 PlaybackPlayerPreference
    /// 的注释,勾了自动识别之后它按超集处理,不会因为同时也勾了具体播放器就退化。
    ///
    /// **不能取消到空集**:选中集合永远至少留一个,跟上面那条"保证非空"的不变量以及
    /// LyrimuseCore `PlaybackPlayerPreference.selected` / collector `resolvePlayers` 对称
    /// —— 真放任清空,下一次 collector 重启读到的会是"什么都没选"这个非法状态(两侧都会
    /// 各自兜底成 auto,但界面会有一瞬间显示"什么都没选中",观感是错的)。
    @MainActor
    public func togglePlayer(_ player: PlaybackPlayer) {
        if players.contains(player) {
            guard players.count > 1 else { return }
            players.remove(player)
        } else {
            players.insert(player)
        }
        Task { await save() }
    }

    /// 预解析待播曲目。字段名和 json 键(`album_prefetch`)是这个功能只预取
    /// 「同一张专辑里其它曲目」那阵子留下的,语义**已经扩到整条播放队列**(见
    /// collector/upcoming.go)。不改名是刻意的:改了就要多一个迁移标记,而迁移标记漏写一边
    /// 的坑刚踩过(`applemusic_lyrics`),为一个纯内部的名字不值得。
    @Published public var albumPrefetch = true
    /// 「自动跟进算法升级」——关掉之后,已经选定的歌词不再被后台的重打分/升级重搜换掉
    /// 。 初值 true 必须跟 collector 侧
    /// `boolOr(f.LyricsAutoUpgrade, true)` 一致,不然全新安装时两边行为对不上。
    @Published public var lyricsAutoUpgrade = true
    // 这几个都要连一个外部账号才有意义,默认关闭。collector/features.go 的 boolOr
    // 默认值要跟着一起改,否则全新安装时 Swift 这边显示关、Go 那边却按"缺字段=开启"
    // 实际执行,两边会对不上。
    // 歌词源没带社区译文时,自己补一份翻译。默认关:优先走系统端上翻译(不联网),
    // 但在 macOS 26 以下、或语言包没装时会退到网络翻译服务,那条路会把歌词正文发出去,
    // 该由用户显式同意 —— 现有的九个歌词源只发歌手/歌名。
    @Published public var lyricsMachineTranslation = false
    @Published public var lastfmMirrorScrobble = false
    /// 这里的初值 .all 是**给老机器的**,而且 **必须逐字等于 collector features.go 里
    /// resolveScrobbleArtistMode 的兜底值** —— 那条对齐是人工维持的,没有机制保证
    /// (见 load() 里的警告)。语义与取舍见 collector lastfm.go 的 resolveScrobbleArtist:
    /// ListenBrainz 文档要求合唱 credit "include them all";折叠会丢信息且不可逆,不折叠
    /// 最坏只是 Last.fm 上多一个听众很少的合唱条目 —— 代价不对称。
    ///
    /// **全新装机默认 .smart**(口径是「把这个智能改为默认选项,但是之前已经
    /// 在用全部的了就不要改了,只有新下载的才变为智能」)。抬档只发生在 load() 里"文件不存在"
    /// 那一条路径上、且 `isFreshInstall` 成立时,并当场写实到盘上 —— 完整理由见那里。
    /// 这个初值**不能**直接改成 .smart:它同时是 features.json 损坏时的兜底,那种情况下的
    /// 机器几乎必然是老用户,改了就等于背着他折叠合唱串。
    @Published public var lastfmMatchMode: LastfmMatchMode = .raw
    /// 「自定义」档的三个维度。 只在 `lastfmMatchMode == .custom` 时有意义 ——
    /// 另两档由档位本身决定(智能 = 改歌手+改曲名、原始 = 全不改),写盘时由
    /// `currentSnapshot` 按档位算出该落什么,不直接用这三个值。
    @Published public var lastfmMatchArtist = false
    @Published public var lastfmMatchTrack = false
    @Published public var lastfmMatchFirstArtistOnly = false

    /// 上面那三个布尔的界面形状:曲名一维、歌手一维。界面只绑这两个,布尔本身仍是
    /// 落盘契约、也仍是 `effectiveMatch*` 的输入 —— 所以 collector 那侧一个字都不用改。
    ///
    /// 歌手那一维把「改写歌手」和「合唱只发第一位」合成了互斥的三档(理由见
    /// `LastfmArtistRule`)。setter 每次都把两个布尔一起写,不会留下半旧半新的组合。
    public var lastfmTrackRule: LastfmTrackRule {
        get { lastfmMatchTrack ? .catalog : .raw }
        set { lastfmMatchTrack = newValue == .catalog }
    }
    public var lastfmArtistRule: LastfmArtistRule {
        get {
            if lastfmMatchArtist { return .catalog }
            return lastfmMatchFirstArtistOnly ? .firstOnly : .raw
        }
        set {
            lastfmMatchArtist = newValue == .catalog
            lastfmMatchFirstArtistOnly = newValue == .firstOnly
        }
    }

    /// 三个维度**按档位算出来的有效值** —— 落盘、以及任何"实际会怎么发"的判断都用它们,
    /// 别直接读上面那三个 @Published(那三个只是「自定义」档的界面状态)。
    /// 跟 collector `resolveLastfmMatch` 是同一份规则,两侧要一起改。
    public var effectiveMatchArtist: Bool {
        switch lastfmMatchMode {
        case .smart: return true
        case .custom: return lastfmMatchArtist
        case .raw: return false
        }
    }
    public var effectiveMatchTrack: Bool {
        switch lastfmMatchMode {
        case .smart: return true
        case .custom: return lastfmMatchTrack
        case .raw: return false
        }
    }
    public var effectiveMatchFirstArtistOnly: Bool {
        lastfmMatchMode == .custom && lastfmMatchFirstArtistOnly
    }
    /// 默认 false:短于 30 秒不记(Last.fm 官方规则)。**必须逐字等于 collector features.go 里
    /// boolOr 的默认值**(人工维持,见 load() 里的警告)。
    @Published public var scrobbleShortTracks = false
    /// 默认 .half:官方规则那一刻就发,跟加这个设置之前一样。**必须逐字等于 collector features.go 里
    /// resolveScrobblePoint 的兜底值**(人工维持,见 load() 里的警告)。
    @Published public var lastfmScrobblePoint: LastfmScrobblePoint = .half
    @Published public var weeklyDigest = false
    @Published public var dailyDigest = false
    // 空字符串 = 用户没手动选过,交给 AccountLinkingTab 的 resolvedDigestSource 按
    // "已配置的账号"自动判定要不要显示成"lastfm"/"listenbrainz"，这里只负责持久化
    // 用户一旦手动选过之后的显式值。
    @Published public var weeklyDigestSource = ""
    @Published public var dailyDigestSource = ""
    @Published public var monthlyDigest = false
    @Published public var yearlyDigest = false
    @Published public var monthlyDigestSource = ""
    @Published public var yearlyDigestSource = ""
    @Published public var lyricsSources: Set<LyricsSource> = Set(LyricsSource.allCases)
    @Published public var lyricsSourceMode: LyricsSourceMode = .smart
    // 始终是全部 4 个源的一个排列(不是"只放启用的那几个")——启用/禁用状态单独由
    // lyricsSources 记录,顺序调整只在这个数组内部交换位置,两者互不干扰,不需要"禁用
    // 一个源时把它从顺序表里摘出来/重新插回去"这种同步逻辑。
    @Published public var lyricsSourceOrder: [LyricsSource] = LyricsSource.allCases
    // 空字符串 = 用默认位置(~/.config/lyrimuse/lyrics)。用 effectiveLyricsDir
    // 取实际生效的路径,不要直接读这个属性去拼路径。
    @Published public var lyricsDir = ""
    // 只影响 Musixmatch 这个源的译文语言,详见 MusixmatchTranslationLanguage 注释。
    @Published public var lyricsTranslationLanguage: MusixmatchTranslationLanguage = .auto
    // 打开 Apple Music 时顺带唤起 Lyrimuse——默认关闭,理由跟
    // AppSettings.launchMusicOnLyrimuseOpen 一样:"自动启动另一个 App"不该是没问过
    // 用户就默认打开的行为。
    // 默认开:这是「装了就该有的样子」——打开播放器歌词就跟上来,而不是每次还要先
    // 想起来去菜单栏点一下 Lyrimuse。 改默认值必须跟 collector 侧 features.go 的
    // boolOr(..., true) 一起改,不然 Swift 这边显示「开」而真正执行的 collector 当它是关。
    // 从布尔改成逐播放器集合(见 LyrimuseCore.PlayerLinkage 头注)。默认值由 load 里的
    // 迁移决定(布尔年代默认 true → 当时的全部候选),这里的初值只是占位。写盘时同时落布尔 = 集合非空。
    @Published public var launchLyrimuseOnPlayers: Set<PlaybackPlayer> = []
    /// 见 FeatureFlagsFile.trustedPlayers。改它一律走 trust/untrust 两个方法,别直接赋值
    /// —— 那两个方法负责反查 App 名并立刻落盘(collector 按 mtime 重读,不需要重启)。
    @Published public private(set) var trustedPlayers: [String: String] = [:]
    /// 见 FeatureFlagsFile.lastfmExcludedBundles。改它一律走 updateLastfmExclusion(立刻落盘 + 重启 collector,
    /// 跟 trust/untrust 同一条路 —— collector 只在启动时读一次这份文件)。
    @Published public private(set) var lastfmExcludedBundles: Set<String> = []

    @Published public private(set) var lastError: String?
    /// 上一次保存落盘成功、但 collector 没重启——因为用户在「播放器」页主动停用了后台服务(kickstart 对没加载的
    /// job 必然失败)。不是错误:collector 下次启动时读盘就拿到新值。设置窗口底部状态条据此显示一句中性提示
    ///;下一次成功重启清掉。
    @Published public private(set) var pendingUntilServiceEnabled = false
    /// 启动时 features.json 判定为**损坏**(文件在、但不是 JSON 对象,或字段按类型解不出来)的原因;
    /// nil = 正常或文件不存在。非 nil 期间 `persistFile()` 一律拒绝,设置窗口顶部的 `ConfigFileDamageBanner`
    /// 据此显示告示与出口。三态口径见 Core `JSONConfigDocument` 头注。
    @Published public private(set) var loadFailure: String?

    static let fileURL = LyrimusePaths.configFile("lyrimuse-features.json")

    /// 这台机器是不是**头一回**用 lyrimuse。只给"新装的默认值跟老用户不一样"的开关用
    /// (引入时只有 `lastfmScrobbleArtistMode` 一个,见它的声明)。
    ///
    /// 为什么非要这么一个东西:想给某个开关换默认值时,"从没设置过"和"显式选了旧默认值"
    /// 在 features.json 里**长得一模一样** —— persistFile() 写的是全量快照,所以用户只要
    /// 动过**任何**一个别的开关,这个键就已经带着旧默认值落了盘。光看键在不在分不出新老,
    /// 只能另找"这台机器以前就在用"的信号。
    ///
    /// 三个信号任一成立就算老机器。取并集是因为它们各有盲区,单独用哪个都会漏:
    ///  ① `np:hasCompletedOnboarding` 存在 —— 跟 `AppSettingsMirror.restoreIfPristine()` 用的是
    ///     同一个键、同一个语义("这台机器有没有自己的偏好")。它被刻意排除在导出/镜像之外,
    ///     所以在真·新机器上一定不存在。盲区:引导没走完就一直用下去的老用户。
    ///  ② features.json 存在 —— 这台机器跑过旧版(这文件只有 Swift 侧会写)。
    ///     盲区:从没动过任何开关的老用户 —— 那时文件压根还没被创建。
    ///  ③ app-settings 镜像存在 —— 带着配置文件夹搬家过来的老用户。他的 ① 一定不成立
    ///     (那个键不进镜像),② 也未必拷了,这一条专门兜他。
    ///
    /// 三条**全都往"老机器"那边倒**,这是刻意的:判错的代价不对称。判成老机器,最坏是
    /// 新用户拿到旧默认值,他在设置里一眼看得见、随手能改;判成新机器却其实是老用户,等于
    /// 背着他改了 scrobble 行为 —— 而 scrobble 落进 Last.fm 之后基本删不掉。同一条
    /// "写侧不可逆、宁可不动"的取舍贯穿这个开关,见 lastfmScrobbleArtistMode 的声明。
    static var isFreshInstall: Bool {
        if UserDefaults.standard.object(forKey: "np:hasCompletedOnboarding") != nil { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) { return false }
        if fm.fileExists(atPath: AppSettingsMirror.fileURL.path) { return false }
        return true
    }

    private var savedSnapshot = FeatureFlagsFile()
    private var currentSnapshot: FeatureFlagsFile {
        FeatureFlagsFile(
            // 只写 players——player 是纯读的迁移字段(见其注释),这台机器往后不再写它。
            players: players.map(\.rawValue).sorted(),
            albumPrefetch: albumPrefetch,
            lyricsAutoUpgrade: lyricsAutoUpgrade,
            lyricsMachineTranslation: lyricsMachineTranslation,
            lastfmMirrorScrobble: lastfmMirrorScrobble,
            // 只写新键;两个遗留字段(lastfm_scrobble_artist_mode /
            // lastfm_scrobble_first_artist_only)都是纯读的迁移字段,见它们的注释。
            //
            // 三个布尔落盘的是**按档位算出来的有效值**,不是 UI 上那三个 @Published ——
            // 智能档恒为 true/true/false、原始档恒为全 false。这样盘上永远不会出现
            // 「mode=smart 但 match_artist=false」这种自相矛盾的组合,collector 那边也就
            // 不必再判一次档位优先级(它确实不判,直接读布尔)。
            lastfmMatchMode: lastfmMatchMode.rawValue,
            lastfmMatchArtist: effectiveMatchArtist,
            lastfmMatchTrack: effectiveMatchTrack,
            lastfmMatchFirstArtistOnly: effectiveMatchFirstArtistOnly,
            scrobbleShortTracks: scrobbleShortTracks,
            lastfmScrobblePoint: lastfmScrobblePoint.rawValue,
            weeklyDigest: weeklyDigest, dailyDigest: dailyDigest,
            weeklyDigestSource: weeklyDigestSource.isEmpty ? nil : weeklyDigestSource,
            dailyDigestSource: dailyDigestSource.isEmpty ? nil : dailyDigestSource,
            monthlyDigest: monthlyDigest, yearlyDigest: yearlyDigest,
            monthlyDigestSource: monthlyDigestSource.isEmpty ? nil : monthlyDigestSource,
            yearlyDigestSource: yearlyDigestSource.isEmpty ? nil : yearlyDigestSource,
            lyricsSources: lyricsSources.map(\.rawValue).sorted(),
            // 只要保存过一次就落这个字段,值如实反映集合状态。它的作用是让上面那条
            // "老配置补 amll"的迁移**只生效一次** —— 之后用户取消勾选才不会被补回来。
            amllLyrics: lyricsSources.contains(.amll),
            // 同上,lyricfind 的迁移标记独立生效一次。
            lyricFindLyrics: lyricsSources.contains(.lyricfind),
            // 同上,kuwo 的迁移标记独立生效一次。
            kuwoLyrics: lyricsSources.contains(.kuwo),
            // 同上,migu 的迁移标记独立生效一次。
            miguLyrics: lyricsSources.contains(.migu),
            // 同上,deezer 的迁移标记独立生效一次。
            deezerLyrics: lyricsSources.contains(.deezer),
            // 同上,applemusic 的迁移标记独立生效一次。不写它,collector 会一直把这个源补回来。
            appleMusicLyrics: lyricsSources.contains(.applemusic),
            // 同上,soda 的迁移标记独立生效一次。不写它,collector 会一直把这个源补回来。
            sodaLyrics: lyricsSources.contains(.soda),
            lyricsSourceMode: lyricsSourceMode.rawValue,
            lyricsSourceOrder: lyricsSourceOrder.map(\.rawValue),
            lyricsDir: lyricsDir.isEmpty ? nil : lyricsDir,
            lyricsTranslationLanguage: lyricsTranslationLanguage.rawValue,
            launchLyrimuseOnMusicOpen: !launchLyrimuseOnPlayers.isEmpty,
            launchLyrimuseOnPlayers: launchLyrimuseOnPlayers.map(\.rawValue).sorted(),
            trustedPlayers: trustedPlayers.isEmpty ? nil : trustedPlayers,
            lastfmExcludedBundles: lastfmExcludedBundles.isEmpty ? nil : lastfmExcludedBundles.sorted()
        )
    }

    /// 把一个未知播放器加进信任列表。
    ///
    /// 显示名在这里就地反查并一起存下来,不是每次显示时现查:collector(Go)也要用它当
    /// ListenBrainz 的 media_player 标签,而 Go 那边没有 NSWorkspace 可用 —— 名字必须由
    /// Swift 侧写进共享文件。反查不到就存空串,标签退回 bundle id(总比谎报成
    /// "Apple Music"好,那会让来源统计彻底失真)。
    public func trust(bundleID: String) async {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, trustedPlayers[id] == nil else { return }
        // 内置播放器本来就认,加进来只会让"已信任"列表看起来莫名多几条(collector 侧
        // resolveTrustedPlayers 也会把它们剔掉,这里提前挡住,别让界面先显示后消失)。
        guard !PlaybackPlayer.allCases.contains(where: { $0 != .auto && $0.bundleIdentifier == id }) else { return }
        trustedPlayers[id] = Self.appDisplayName(forBundleID: id) ?? ""
        _ = await save()
    }

    public func untrust(bundleID: String) async {
        guard trustedPlayers.removeValue(forKey: bundleID) != nil else { return }
        _ = await save()
    }

    /// 「Scrobble 的播放器」按播放器开关(「只控制 lastfm 的上送」)。存的是
    /// **排除**集合:缺失 / 空 = 全部上送,跟其余"缺字段 = 沿用现有行为"的键同一口径,新装机、老配置都不会突然
    /// 少记。一次调用可以同时改多个(那排芯片一次交回整组勾选),只落一次盘、只重启一次 collector;没变化就什么
    /// 都不做。
    public func updateLastfmExclusion(scrobbled: [String], excluded: [String]) async {
        var next = lastfmExcludedBundles
        next.subtract(scrobbled)
        next.formUnion(excluded.filter { !$0.isEmpty })
        guard next != lastfmExcludedBundles else { return }
        lastfmExcludedBundles = next
        _ = await save()
    }

    /// bundle id → App 的本地化显示名。查不到返回 nil(App 被删了/从没装过)。
    ///
    /// 优先 `CFBundleDisplayName`(本地化名,中文系统上「酷狗音乐」这种)再退
    /// `CFBundleName`,最后退文件名去掉 .app —— 三级都落空才 nil。
    public static func appDisplayName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        if let info = Bundle(url: url)?.infoDictionary {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = info[key] as? String,
                   !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    return name
                }
            }
        }
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? nil : base
    }

    // 供 EnrichCacheStore("歌词管理"窗口的文件读写)和 Settings 里的"打开歌词文件夹"
    // 按钮共用——两边都必须认同一个文件夹,不能各自兜底出两份不一致的默认路径。
    public var effectiveLyricsDir: URL {
        if !lyricsDir.isEmpty {
            return URL(fileURLWithPath: lyricsDir)
        }
        return LyrimusePaths.configFile("lyrics")
    }
    public var isDirty: Bool { currentSnapshot != savedSnapshot }

    private init() {
        load()
    }

    /// 磁盘上存在、但**这个版本**的 FeatureFlagsFile 不认识的键,原样留着,写盘时再合并回去
    /// —— 否则多设备同步时(如 Mac A 已更新到新版、Mac B 还没跟上,B 写盘时按旧版 struct
    /// 重新编码)会把新版才有的字段丢掉,再同步回去就连累了另一台机器。
    ///
    /// 隔壁 ConfigStore 走 `raw: [String: Any]` 整字典读写(见那边 :72-78)。
    ///
    /// 两个 Store 统一走 Core `JSONConfigDocument`:磁盘上那份对象(全部键,含不认识的)的镜像
    /// 就是 `document.raw`,写盘时 `save(fields:knownKeys:)` 按「已知键以本次编码为准、其余原样保留」合并 ——
    /// 上面说的那条保护由它兑现。同时带来三态(不存在 / 正常 / 损坏),损坏时拒绝保存,见 loadFailure。
    private var document = JSONConfigDocument(url: FeatureSettingsStore.fileURL)

    /// 诊断导出用:磁盘上那份文件的三态。
    public var fileState: JSONConfigDocument.LoadState { document.state }

    public func load() {
        document = JSONConfigDocument.load(url: Self.fileURL)
        loadFailure = nil
        var decoded: FeatureFlagsFile?
        switch document.state {
        case .missing:
            break
        case .corrupt(let reason):
            loadFailure = reason
            logger.error("features.json is unusable, saves refused until it is fixed or discarded: \(reason, privacy: .public)")
        case .loaded:
            // 对象再按类型解一遍。对象是合法 JSON 但字段类型对不上(手改成 "album_prefetch": "yes")同样按
            // 损坏处理:退默认值再保存会把整份开关覆盖成默认,跟 JSON 语法坏了没有区别 —— 所以一样拒绝
            // 保存,原因(键名 + 期望类型,不含值)进横幅让用户自己修或放弃。
            do {
                decoded = try JSONDecoder().decode(FeatureFlagsFile.self, from: JSONConfigDocument.serialize(document.raw))
            } catch {
                let reason = "fields do not decode: \(Self.describeDecodingError(error))"
                document.markCorrupt(reason: reason)
                loadFailure = reason
                logger.error("features.json fields do not decode, saves refused: \(reason, privacy: .public)")
            }
        }
        guard let f = decoded else {
            // 文件不存在 / 损坏——维持属性的默认值,须跟 collector 侧 loadFeatureFlags
            // 的默认值逐字对齐(核心行为开关 fail-open=true;需要外部账号的 6 个
            // fail-closed=false,见上面属性声明处的说明)。
            //
            // 这条对齐是**人工维持**的,没有任何机制保证 —— 就抓到 player
            // 一项脱节了(属性初值 .appleMusic vs collector 的 auto,已修)。改任一侧的
            // 默认值都要回头核对另一侧,别信这行注释说"一致"就跳过。
            //
            // 上面那条对齐有且只有一个例外:「上送的写法」在**全新装机**上默认「智能」
            //。它只能在这里做,也只能在这一条路径上做 ——
            //  · 走到 `decoded != nil` 就说明文件在、能解析,那这台机器必是老的,一律维持原样;
            //  · 文件**损坏**时也会落到这个 guard 里,但那时 `isFreshInstall` 因信号②为 false,
            //    照旧 .all —— 老用户文件坏了,更不该顺手改他的 scrobble 行为。
            if Self.isFreshInstall {
                lastfmMatchMode = .smart
                // 必须当场写实到盘上。collector 是另一个进程、读不到 UserDefaults,只认这份
                // features.json,而它对"文件不存在"的兜底是 all(features.go
                // resolveScrobbleArtistMode)—— 不写的话界面显示「智能」、实际一直在发整串,
                // 而且这个不一致会一直挂到用户碰巧改了别的开关触发一次 save 为止。
                // 反过来说,这一写也让 collector 那边"文件不存在"重新只剩一个含义:
                // 老用户从没动过任何开关 → all。两边因此不需要各自判一次"新装没有"。
                //
                // 用 persistFile() 而不是 save():这里只要把默认值固化下来,不该顺带触发
                // collector 重启/热读那一套(全新装机时它多半还没配置好)。写失败也不致命 ——
                // 那时两边都还是 all(旧行为),下一次真正的 save 会把它带上,不会出现
                // "界面与实际不一致"这种更坏的中间态。
                try? persistFile()
            }
            savedSnapshot = currentSnapshot
            return
        }
        // 这个版本不认识的键留在 document.raw 里,写盘时由 JSONConfigDocument 合并回去(见 document 的注释)。
        let unknownCount = document.raw.keys.filter { !FeatureFlagsFile.knownFileKeys.contains($0) }.count
        if unknownCount > 0 {
            logger.notice("features.json carries \(unknownCount) key(s) this build doesn't know; they will be preserved on write")
        }
        // players 缺失/空数组时退回 player(遗留单选字段)做一次性迁移;两者都没有
        // 可用值才最终兜底 {auto}——跟 collector 侧 resolvePlayers 是同一份迁移逻辑。
        let decodedPlayers = Set((f.players ?? []).compactMap(PlaybackPlayer.init(rawValue:)))
        if !decodedPlayers.isEmpty {
            players = decodedPlayers
        } else if let legacy = f.player.flatMap(PlaybackPlayer.init(rawValue:)) {
            players = [legacy]
        } else {
            players = [.auto]
        }
        albumPrefetch = f.albumPrefetch ?? true
        lyricsAutoUpgrade = f.lyricsAutoUpgrade ?? true
        lyricsMachineTranslation = f.lyricsMachineTranslation ?? false
        lastfmMirrorScrobble = f.lastfmMirrorScrobble ?? false
        // 上送匹配:新键缺失/非法时顺着**两级遗留链**迁移(lastfm_match_mode →
        // lastfm_scrobble_artist_mode → lastfm_scrobble_first_artist_only),全都没有才
        // 兜底「原始」—— 跟 collector 侧 resolveLastfmMatch 是同一份规则,两侧要一起改。
        //
        // 迁移表的承诺是**行为逐字不变**:旧 smart 到 智能、旧 all 到 原始、
        // 旧 first 到 自定义且只开「合唱只发第一位」(到 照旧不打网络)。
        if let mode = f.lastfmMatchMode.flatMap(LastfmMatchMode.init(rawValue:)) {
            lastfmMatchMode = mode
            lastfmMatchArtist = f.lastfmMatchArtist ?? false
            lastfmMatchTrack = f.lastfmMatchTrack ?? false
            lastfmMatchFirstArtistOnly = f.lastfmMatchFirstArtistOnly ?? false
        } else {
            let legacyFirstOnly = f.lastfmScrobbleArtistMode == "first"
                || (f.lastfmScrobbleArtistMode == nil && (f.lastfmScrobbleFirstArtistOnly ?? false))
            switch f.lastfmScrobbleArtistMode {
            case "smart": lastfmMatchMode = .smart
            default: lastfmMatchMode = legacyFirstOnly ? .custom : .raw
            }
            lastfmMatchArtist = false
            lastfmMatchTrack = false
            lastfmMatchFirstArtistOnly = legacyFirstOnly
        }
        scrobbleShortTracks = f.scrobbleShortTracks ?? false
        // 缺失/非法一律官方规则 —— 跟 collector 侧 resolveScrobblePoint 是同一份规则。
        lastfmScrobblePoint = f.lastfmScrobblePoint.flatMap(LastfmScrobblePoint.init(rawValue:)) ?? .half
        weeklyDigest = f.weeklyDigest ?? false
        dailyDigest = f.dailyDigest ?? false
        weeklyDigestSource = f.weeklyDigestSource ?? ""
        dailyDigestSource = f.dailyDigestSource ?? ""
        monthlyDigest = f.monthlyDigest ?? false
        yearlyDigest = f.yearlyDigest ?? false
        monthlyDigestSource = f.monthlyDigestSource ?? ""
        yearlyDigestSource = f.yearlyDigestSource ?? ""
        // 缺失/空数组(旧配置文件没这个字段,或者曾经被清空过)都按"全部启用"处理,跟
        // collector 侧 resolveLyricsSources 的兜底规则一致。
        let decodedSources = (f.lyricsSources ?? []).compactMap(LyricsSource.init(rawValue:))
        var enabled = Set(decodedSources)
        if enabled.isEmpty {
            enabled = Set(LyricsSource.allCases)
        } else {
            // amll/lyricfind/kuwo 的迁移标记各自独立判断——一份配置可能在 amll 时代之后、
            // lyricfind 时代之前保存过(amllLyrics 非空、lyricFindLyrics 为空),这种配置
            // 只该补 lyricfind,不该把 amll 也重新补一遍(用户可能已经手动关掉了它)。
            //
            // 漏掉这一支会让 lyricfind 在已经保存过设置的老用户
            // 机器上静默不参与检索(lyrics_sources 白名单里没有它、
            // lyricFindLyrics 又缺失,本该判定"这是老配置、要补齐"却没有对应分支)。
            if f.amllLyrics == nil {
                // 老配置(写的时候还没有这个源)——见 FeatureFlagsFile.amllLyrics。只补这一次。
                enabled.insert(.amll)
            }
            if f.lyricFindLyrics == nil {
                // 同上,见 FeatureFlagsFile.lyricFindLyrics。
                enabled.insert(.lyricfind)
            }
            if f.kuwoLyrics == nil {
                // 同上,见 FeatureFlagsFile.kuwoLyrics。
                enabled.insert(.kuwo)
            }
            if f.miguLyrics == nil {
                // 同上,见 FeatureFlagsFile.miguLyrics。
                enabled.insert(.migu)
            }
            if f.deezerLyrics == nil {
                // 同上,见 FeatureFlagsFile.deezerLyrics。
                enabled.insert(.deezer)
            }
            if f.appleMusicLyrics == nil {
                // 同上,见 FeatureFlagsFile.appleMusicLyrics。这一支必须跟 collector 侧
                // resolveLyricsSources 的 appleMusicSeen 分支同进同退:只有一边补,同一份老配置
                // 在界面和后台会得到两种不同的启用集合。
                enabled.insert(.applemusic)
            }
            if f.sodaLyrics == nil {
                // 同上,见 FeatureFlagsFile.sodaLyrics,跟 collector 侧的 sodaSeen 分支同进同退。
                enabled.insert(.soda)
            }
        }
        lyricsSources = enabled
        lyricsSourceMode = f.lyricsSourceMode.flatMap(LyricsSourceMode.init(rawValue:)) ?? .smart
        // 必须是全部源的完整排列(数量 == LyricsSource.allCases.count,不是写死的字面量——
        // 这句注释曾经写死过"4 个",源数量涨到 8 个都没跟着改,不要重蹈一样的坑)。数量
        // 对不上(文件被手动改坏/缺字段,或者刚加了新源、旧文件的顺序列表还没跟上)就整体
        // 退回默认顺序,不做"缺的补在末尾"这种部分修复,避免搞出一份既不是默认顺序、
        // 也不是用户真实排过的四不像顺序。
        let decodedOrder = (f.lyricsSourceOrder ?? []).compactMap(LyricsSource.init(rawValue:))
        lyricsSourceOrder = decodedOrder.count == LyricsSource.allCases.count ? decodedOrder : LyricsSource.allCases
        trustedPlayers = f.trustedPlayers ?? [:]
        lastfmExcludedBundles = Set((f.lastfmExcludedBundles ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        lyricsDir = f.lyricsDir ?? ""
        lyricsTranslationLanguage = f.lyricsTranslationLanguage.flatMap(MusixmatchTranslationLanguage.init(rawValue:)) ?? .auto
        if let raw = f.launchLyrimuseOnPlayers {
            launchLyrimuseOnPlayers = Set(raw.compactMap(PlaybackPlayer.init(rawValue:)))
        } else {
            // 布尔年代的一次性迁移:true(默认)→ 当时的全部候选(选中集合的具体播放器,auto 时五个全上),
            // 这正是 collector 当年盯的范围;false → 空。下次 save 就把列表写进文件,以后走新键。
            launchLyrimuseOnPlayers = PlayerLinkage.migratedLaunchSet(
                legacyEnabled: f.launchLyrimuseOnMusicOpen ?? true, selectedPlayers: players, requiresSole: false)
        }
        savedSnapshot = currentSnapshot
    }

    // 只写盘,不重启。
    //
    // 原注释说"底部保存栏会把这个和 ConfigStore.persistFile() 一起调用后统一重启
    // 一次" —— 那个保存栏已经不存在了,且本方法只被自己的 save 调用(
    // 核实)。"只重启一次"现在由 CollectorRestartCoordinator 保证。
    public func persistFile() throws {
        // 当前快照编码成字典。JSONEncoder 这一步只会因为编程错误失败,不会因为用户数据失败。
        let encoded = try JSONEncoder().encode(currentSnapshot)
        guard let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw ConfigFileSaveError.notSerializable
        }
        do {
            // 已知键以本次编码为准(遗留的 player / lastfm_scrobble_first_artist_only 没编码就从文件删掉,
            // 「这台机器往后不再写它」的语义靠这条),这个版本不认识的键原样保留;写成功后镜像才更新。
            // 磁盘上那份判定为损坏时这里直接抛,一个字节不碰。features.json 不含凭据,普通原子写。
            try document.save(fields: fields, knownKeys: FeatureFlagsFile.knownFileKeys, secure: false)
        } catch JSONConfigDocument.Failure.refusedCorruptFile {
            throw ConfigFileSaveError.refusedCorruptFile
        } catch JSONConfigDocument.Failure.notSerializable {
            throw ConfigFileSaveError.notSerializable
        }
    }

    /// 横幅上的「放弃坏文件并重建」:把损坏的 features.json 挪到旁边(`lyrimuse-features.json.corrupt-<时间>`,
    /// 不删),然后用当前内存里的值(损坏时是各开关的默认值)重建并保存。
    @discardableResult
    public func discardCorruptFileAndSave() async -> Bool {
        do {
            if let moved = try document.quarantineCorruptFile() {
                logger.notice("corrupt features.json moved aside as \(moved.lastPathComponent, privacy: .public)")
            }
        } catch {
            lastError = String(format: L10n.t("无法移走损坏的配置文件：%@"), error.localizedDescription)
            logger.error("quarantine failed: \(String(describing: error), privacy: .public)")
            return false
        }
        loadFailure = nil
        return await save()
    }

    /// DecodingError → 「键路径: 期望什么、遇到什么」一句话,不带值。别的错误退回 String(describing:)。
    private static func describeDecodingError(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: error) }
        let context: DecodingError.Context
        switch decoding {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            context = c
        @unknown default:
            return String(describing: error)
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }

    public func commitSnapshot() {
        savedSnapshot = currentSnapshot
    }

    /// 设置窗口底部状态条的「关闭」:清掉上一次保存的失败原因 / 「服务已停用」提示。不改任何数据。
    public func clearApplyStatus() {
        lastError = nil
        pendingUntilServiceEnabled = false
    }

    // 重启去抖的状态原来在这里,整体挪进了共享的
    // CollectorRestartCoordinator —— 原因不是嫌它写得不好,而是它只能是**私有**的:
    // 看不见 ConfigStore 也在重启,于是"改一个凭据 + 改一个开关"照样两次重启,正好是
    // 它当初想消灭的那个场景。别在这里重新加一份局部去抖。
    // 独立保存入口(持久化+重启+提交快照一步到位)——给本文件里每一个即时保存的开关用。
    /// 这次保存改了哪些顶层键(json 键名)。拿它问 `CollectorRestartPolicy` 要不要重启 collector。
    /// 编码失败(只会是编程错误)时返回空集合 —— 空集合按"不知道改了什么"处理,照旧重启。
    private var changedFileKeysSinceLastSave: Set<String> {
        func fields(_ snapshot: FeatureFlagsFile) -> [String: Any] {
            guard let data = try? JSONEncoder().encode(snapshot),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return dict
        }
        return CollectorRestartPolicy.changedKeys(from: fields(savedSnapshot), to: fields(currentSnapshot))
    }

    @discardableResult
    public func save() async -> Bool {
        // 在 persistFile() **之前**算:那一步之后 savedSnapshot 还没动,但先算出来更不容易漏。
        let changedKeys = changedFileKeysSinceLastSave
        do {
            try persistFile()
        } catch ConfigFileSaveError.refusedCorruptFile {
            // 不是「写失败」,是刻意不写:文案直说原因,横幅里有出口。
            lastError = ConfigFileSaveError.refusedCorruptFile.errorDescription
            logger.notice("save refused: features.json on disk is corrupt")
            return false
        } catch {
            lastError = String(format: L10n.t("写入功能开关文件失败：%@"), error.localizedDescription)
            logger.error("write failed: \(String(describing: error), privacy: .public)")
            return false
        }
        // 不重启 collector:它按 mtime 自己热重读这份文件(featuresreload.go),lyrics_dir 也在运行中
        // 切换(lyricsdirswitch.go)。见 CollectorRestartPolicy 头注。
        logger.notice("saved, collector hot-reloads it (\(changedKeys.sorted().joined(separator: ","), privacy: .public))")
        lastError = nil
        // 后台服务没在跑(用户停用了)时,文件已是新值、下次启动读盘生效;状态条据此提示「服务已停用」。
        pendingUntilServiceEnabled = !CollectorServiceManager.isRunning
        commitSnapshot()
        return true
    }

}
