import Foundation
import LyrimuseCore
import os
import SwiftUI

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "feature-settings")

// 八个歌词源——rawValue 必须跟 collector/features.go 的 lyricSourceXxx 常量逐字对应,
// 这是两侧通过共享 json 文件交换的字符串。displayName/color 直接委托给
// LyricsManagerView.swift 已有的 sourceDisplayName/sourceColor(那两个函数今天也在给
// "歌词管理"窗口的来源筛选/列表用),不重复维护第二份名字/颜色映射。
public enum LyricsSource: String, CaseIterable, Identifiable, Codable, Hashable {
    case netease, qq, kugou, musixmatch, lrclib, amll, lyricfind, kuwo
    public var id: Self { self }
    public var displayName: String { sourceDisplayName(rawValue) }
    public var color: Color { sourceColor(rawValue) }
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

// PlaybackPlayer 定义在 LyrimuseCore(见 Local/PlaybackPlayer.swift)——MediaControlClient/
// LocalPlaybackSource 也需要认这个类型,而它们在 LyrimuseCore、不能反向依赖这个
// (lyrimuse 主 App target)文件,所以类型本身放在被依赖的下层,这里只是引用。
extension PlaybackPlayer {
    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .qqMusic: return L10n.t("QQ 音乐")
        case .netease: return L10n.t("网易云音乐")
        case .kugou: return L10n.t("酷狗音乐")
        case .spotify: return "Spotify"
        case .auto: return L10n.t("自动识别")
        }
    }

    // 引导页"选择播放器"那一步的图标卡片用(2026-08-25)。真图标优先——已安装就用
    // NSWorkspace 按 bundleIdentifier 查到的真实 App 图标去画,这两个只是**没装时**的
    // 占位:引导阶段大概率大部分播放器都还没装,不能什么都不画。品牌色跟"歌词来源"
    // 那套复用同一份(sourceColor,LyricsManagerView.swift)——QQ音乐/网易云音乐/酷狗音乐
    // 本来就是同一批 App,没理由维护第二份配色映射;Apple Music/Spotify/自动识别这三个
    // 不在歌词来源清单里,单独给。
    public var tintColor: Color {
        switch self {
        case .appleMusic: return Color(red: 0.98, green: 0.20, blue: 0.35)
        case .qqMusic: return sourceColor("qq")
        case .netease: return sourceColor("netease")
        case .kugou: return sourceColor("kugou")
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        case .auto: return .secondary
        }
    }

    public var fallbackSymbolName: String {
        switch self {
        case .auto: return "wand.and.stars"
        default: return "music.note"
        }
    }

    /// 这台机器没装对应 App 时,`AppIconResolver.icon(bundledResourceName:)` 该去找哪个
    /// 随包打包的静态品牌图(2026-09-02,见该函数头注的完整背景)。nil = 没有这一层兜底,
    /// 直接落到 `tintColor`+`fallbackSymbolName` 那套纯色占位——Apple Music 是系统自带,
    /// 几乎不存在"没装"这种情况;`.auto` 本来就不对应任何具体 App。
    public var bundledIconResourceName: String? {
        switch self {
        case .qqMusic: return "QQMusicIcon"
        case .netease: return "NeteaseIcon"
        case .kugou: return "KugouIcon"
        case .spotify: return "SpotifyIcon"
        case .appleMusic, .auto: return nil
        }
    }

    /// 图标网格(引导页"选择播放器" + 设置页"播放器"卡,2026-08-25)的摆放顺序,按
    /// 系统语言排——只影响这两处图标网格,不改 `allCases` 本身:这个类型别的消费点
    /// (`PlaybackCoordinator.allCases.first(where:)` 这类按 bundle id 查找)不关心顺序,
    /// 没有必要跟着这条语言判断联动。
    ///
    /// Apple Music 两种语境下都排第一(系统自带、认知成本最低),「自动识别」恒定垫底
    /// (它不是一个具体播放器,当兜底选项摆最后符合直觉)。中间四个按这批用户的实际
    /// 使用习惯排:简体中文语境下国内三家排在 Spotify 前面;非简体中文(含繁体中文/
    /// 英文等)语境反过来,Spotify 排到国内三家前面。
    public static var displayOrder: [PlaybackPlayer] {
        AppSettings.userReadsSimplifiedChinese
            ? [.appleMusic, .qqMusic, .netease, .kugou, .spotify, .auto]
            : [.appleMusic, .spotify, .qqMusic, .netease, .kugou, .auto]
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

// 合唱串("A & B")scrobble 时发哪个名字(2026-09-03 起三档)。rawValue 必须跟 collector
// features.go 的 scrobbleArtistAll/First/Smart 常量逐字相同——两侧通过同一份 features.json
// 交换,collector 只认这三个串,拼错就静默退回 all。
//
// - all:原样发整串(默认)。
// - first:纯字符串取第一位(collector firstCreditedArtist),不联网。
// - smart:按 Last.fm 编目判定(collector lastfmcollapse.go):合唱串已被收录就原样发;没收录、
//   而第一位歌手名下这首歌已被收录才只发第一位;两边都查不到或查询失败维持原样。每首歌只判
//   一次、结论永久沿用。
public enum LastfmScrobbleArtistMode: String, CaseIterable, Identifiable, Codable {
    case all, first, smart
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .all: return L10n.t("全部")
        case .first: return L10n.t("只发第一位")
        case .smart: return L10n.t("智能")
        }
    }
}

// 跟 collector/features.go 的 featureFlagsFile 逐字段对应的 on-disk 形状——所有字段
// 可选(nil = 沿用默认开启),跟 collector 侧"文件缺失/字段缺失都当作 true"的约定一致,
// 这里存的是 Lyrimuse 这台机器上用户明确设置过的值。collector/features.go 那侧是
// 同一份共享 JSON 文件的镜像,字段增删两侧同步;旧配置文件里如果还留着已经删掉的
// key,JSONDecoder/Go 的 encoding/json 都会静默忽略未知字段,不需要额外的迁移代码。
struct FeatureFlagsFile: Codable, Equatable {
    // player:**遗留字段**(2026-09-01 起被下面的 players 取代,只留着给一次性迁移用)。
    // 旧版本只能选一个播放器时写的就是这个键;players 缺失时 load() 把它当迁移前的
    // 选择读一次。这台机器往后只会写 players,不会再写这个键,但读老配置(iCloud
    // 同步/降级)时不能让它凭空消失——跟 collector 侧 featureFlagsFile.Player 对称。
    var player: String?
    // players:可多选的播放器集合(2026-09-01 起支持多选,取代上面的 player)——
    // PlaybackPlayer 的 rawValue 数组:"auto"/"apple_music"/"qq_music"/"netease_music"/
    // "kugou_music"/"spotify"(见 PlaybackPlayer 注释,LyrimuseCore)。跟 LyrimuseCore
    // 的 PlaybackPlayerPreference.selected 读的是同一个键,collector 侧对应
    // featureFlagsFile.Players。
    //
    // ⚠️ 生效时机两侧**不一样**,别照抄别的字段的说法:LocalPlaybackSource 每次轮询都会
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
    var lastfmScrobbleArtistMode: String?
    /// **遗留字段**(2026-08-31 ~ 09-03 之间的二态开关,被上面的 lastfmScrobbleArtistMode
    /// 取代,只留着给一次性迁移用):true ↔ first,false/缺失 ↔ all。这台机器往后只写
    /// lastfmScrobbleArtistMode,不再写它——跟 collector 侧 featureFlagsFile 对称。
    var lastfmScrobbleFirstArtistOnly: Bool?
    /// 短于 30 秒的曲目也 scrobble 到 Last.fm。**默认 false = 现状**(Last.fm 官方规则要求曲目长于
    /// 30 秒)。只管 Last.fm(含给它兜底的本地收听日志/回填),ListenBrainz 不受影响 —— 见
    /// collector poller.go tooShortToScrobble / shortTrackLastfmOnly。
    var scrobbleShortTracks: Bool?
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
    var lyricsSources: [String]?
    /// **迁移标记,不是开关**。amll 的启用状态跟其余五源一样记在 lyricsSources 里。
    ///
    /// 它存在只为解决一件事:lyrics_sources 是白名单,而老配置写的时候 amll 这个源还不
    /// 存在,列表里不可能有它 —— 直接按白名单办等于对所有老用户默认关闭,而"没列出"在
    /// 这里的真实含义是"当时没这个选项",不是"用户排除了它"。
    ///
    /// 所以:缺失 ⇒ 这是一份老配置,加载时把 amll 补进启用集合(只补这一次);一旦保存过,
    /// 这个字段就落盘,从此完全以 lyricsSources 为准,用户取消勾选能正常生效。
    /// 与 collector 侧 featureFlagsFile.AMLLLyrics 一一对应。
    var amllLyrics: Bool?
    /// 跟 amllLyrics 同一个套路的迁移标记(2026-08-25 加 lyricfind 时补)。lyricfind 没有
    /// amll 那样"曾经有过独立开关"的历史,但要解决的是**同一个**问题:老配置(写的时候
    /// lyricfind 这个源还不存在)按白名单办会被静默关掉。缺失 ⇒ 老配置,加载时把 lyricfind
    /// 补进启用集合(只补这一次)。与 collector 侧 featureFlagsFile.LyricFindLyrics 一一对应。
    var lyricFindLyrics: Bool?
    /// 跟 amllLyrics/lyricFindLyrics 同一个套路的迁移标记(2026-08-31 加 kuwo 时补)。
    /// 缺失 ⇒ 老配置,加载时把 kuwo 补进启用集合(只补这一次)。与 collector 侧
    /// featureFlagsFile.KuwoLyrics 一一对应。
    var kuwoLyrics: Bool?
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
    /// 用户显式信任的「未知播放器」:bundle id → 界面显示名(反查不到 App 名时是空串)。
    /// 语义见 LyrimuseCore 的 TrustedPlayers —— 为什么是"信任列表"而不是"一律接受",
    /// 那份注释里写了(白名单同时挡着打卡,一律接受会把视频/播客写进永久收听历史)。
    var trustedPlayers: [String: String]?

    /// CaseIterable 是为了让 `knownFileKeys` 能自动跟着字段增删走 —— 手工维护第二份
    /// 键名清单迟早会跟这里对不上,而对不上的后果正是下面要修的那种静默丢数据。
    enum CodingKeys: String, CodingKey, CaseIterable {
        case player
        case players
        case albumPrefetch = "album_prefetch"
        case lyricsAutoUpgrade = "lyrics_auto_upgrade"
        case lyricsMachineTranslation = "lyrics_machine_translation"
        case lastfmMirrorScrobble = "lastfm_mirror_scrobble"
        case lastfmScrobbleArtistMode = "lastfm_scrobble_artist_mode"
        case lastfmScrobbleFirstArtistOnly = "lastfm_scrobble_first_artist_only"
        case scrobbleShortTracks = "scrobble_short_tracks"
        case weeklyDigest = "weekly_digest"
        case dailyDigest = "daily_digest"
        case weeklyDigestSource = "weekly_digest_source"
        case dailyDigestSource = "daily_digest_source"
        case lyricsSources = "lyrics_sources"
        case amllLyrics = "amll_lyrics"
        case lyricFindLyrics = "lyricfind_lyrics"
        case kuwoLyrics = "kuwo_lyrics"
        case lyricsSourceMode = "lyrics_source_mode"
        case lyricsSourceOrder = "lyrics_source_order"
        case lyricsDir = "lyrics_dir"
        case lyricsTranslationLanguage = "lyrics_translation_language"
        case launchLyrimuseOnMusicOpen = "launch_lyrimuse_on_music_open"
        case trustedPlayers = "trusted_players"
    }

    /// 这个版本认识的全部 JSON 键。见 FeatureSettingsStore.unknownFileKeys 的注释。
    static let knownFileKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))
}

// "歌词"tab 的纯行为开关(lyrics/albumPrefetch 等)和"账号连接"tab 里各张
// 账号卡片的开关(lastfmMirrorScrobble/weeklyDigest)共用同一份数据层——读写
// ~/.config/lyrimuse/lyrimuse-features.json,跟
// collector/features.go 是同一份共享文件的两侧独立实现。2026-07-29:Last.fm 桥接
// (读 Last.fm 转发进 ListenBrainz + 喂网页"正在播放")不再是这里的一个独立开关——
// Last.fm 桥接凭据 + ListenBrainz 账号都配好就自动生效,跟 collector 侧
// poller.go 的 bridge() 判断条件一致,见那边的注释。
//
// 这个 store 里的每一个开关都是"改了立刻保存"——Binding 的 set 里包一层
// `Task { await features.save() }`,持久化+重启挪到后台执行,但从用户视角"点开关
// 立刻生效"这个体验不变(不需要等,也没有额外的"保存中"提示)。"账号连接"tab 底部那条
// 批量保存栏(isDirty/saveBar)管的是 ConfigStore 的文本/密钥字段,跟这个 store 的开关
// 无关,不要混为一谈。
@MainActor
public final class FeatureSettingsStore: ObservableObject {
    public static let shared = FeatureSettingsStore()

    // 本地播放状态读取哪个 App(集合,2026-09-01 起可多选)——默认**{自动识别}**。
    //
    // ⚠️ 这里原来是 `.appleMusic`(理由是"保持这个设置加入之前唯一存在过的行为不变"),
    // 但 collector 侧的 resolvePlayers 早在 2026-08-13 就从 appleMusic 改成了 auto,
    // 下面 load() 的兜底也是 `?? [.auto]` —— 只有这个属性初值没跟上。后果不是纯注释
    // 问题:features.json **还不存在**时(全新安装)load() 在 guard 处提前 return,
    // 界面就停在这个初值上,于是设置里显示"Apple Music"、collector 实际按"自动识别"
    // 采,两边说的不是一回事(2026-08-30 核实)。
    //
    // 保证非空——UI 层(播放器卡片网格)负责不让用户把最后一个选项也取消勾选,跟
    // LyrimuseCore 的 PlaybackPlayerPreference.selected/collector 的 resolvePlayers
    // 同一份"选中集合永远至少有一个成员"的不变量。
    @Published public var players: Set<PlaybackPlayer> = [.auto]

    /// 点一下切换这个播放器的选中状态,并落盘。设置页「播放器」卡和引导页「选择播放器」
    /// 那一步共用这一份(2026-09-03 从 `SettingsView.toggleSelectedPlayer` 提上来 ——
    /// 引导页同日从单选改成多选,两处各写一遍就有两份"最后一个能不能取消"的判断)。
    ///
    /// 「自动识别」跟具体播放器不是互斥关系,可以一起勾——见 PlaybackPlayerPreference
    /// 的注释,勾了自动识别之后它按超集处理,不会因为同时也勾了具体播放器就退化。
    ///
    /// ⚠️ **不能取消到空集**:选中集合永远至少留一个,跟上面那条"保证非空"的不变量以及
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

    @Published public var albumPrefetch = true
    /// 「自动跟进算法升级」——关掉之后,已经选定的歌词不再被后台的重打分/升级重搜换掉
    /// (2026-09-03 用户要求)。⚠️ 初值 true 必须跟 collector 侧
    /// `boolOr(f.LyricsAutoUpgrade, true)` 一致,不然全新安装时两边行为对不上。
    @Published public var lyricsAutoUpgrade = true
    // 这几个都要连一个外部账号才有意义,默认关闭。collector/features.go 的 boolOr
    // 默认值要跟着一起改,否则全新安装时 Swift 这边显示关、Go 那边却按"缺字段=开启"
    // 实际执行,两边会对不上。
    // 歌词源没带社区译文时,自己补一份翻译。默认关:优先走系统端上翻译(不联网),
    // 但在 macOS 26 以下、或语言包没装时会退到网络翻译服务,那条路会把歌词正文发出去,
    // 该由用户显式同意 —— 现有的八个歌词源只发歌手/歌名。
    @Published public var lyricsMachineTranslation = false
    @Published public var lastfmMirrorScrobble = false
    /// 默认 .all:原样发整串。**必须逐字等于 collector features.go 里 resolveScrobbleArtistMode
    /// 的兜底值** —— 那条对齐是人工维持的,没有机制保证(见 load() 里的警告)。
    /// 语义与取舍见 collector lastfm.go 的 resolveScrobbleArtist:ListenBrainz 文档要求
    /// 合唱 credit "include them all";折叠会丢信息且不可逆,不折叠最坏只是 Last.fm 上
    /// 多一个听众很少的合唱条目 —— 代价不对称。
    @Published public var lastfmScrobbleArtistMode: LastfmScrobbleArtistMode = .all
    /// 默认 false:短于 30 秒不记(Last.fm 官方规则)。**必须逐字等于 collector features.go 里
    /// boolOr 的默认值**(人工维持,见 load() 里的警告)。
    @Published public var scrobbleShortTracks = false
    @Published public var weeklyDigest = false
    @Published public var dailyDigest = false
    // 空字符串 = 用户没手动选过,交给 AccountLinkingTab 的 resolvedDigestSource 按
    // "已配置的账号"自动判定要不要显示成"lastfm"/"listenbrainz"，这里只负责持久化
    // 用户一旦手动选过之后的显式值。
    @Published public var weeklyDigestSource = ""
    @Published public var dailyDigestSource = ""
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
    // 想起来去菜单栏点一下 Lyrimuse。⚠️ 改默认值必须跟 collector 侧 features.go 的
    // boolOr(..., true) 一起改,不然 Swift 这边显示「开」而真正执行的 collector 当它是关。
    @Published public var launchLyrimuseOnMusicOpen = true
    /// 见 FeatureFlagsFile.trustedPlayers。改它一律走 trust/untrust 两个方法,别直接赋值
    /// —— 那两个方法负责反查 App 名并立刻落盘(collector 按 mtime 重读,不需要重启)。
    @Published public private(set) var trustedPlayers: [String: String] = [:]

    @Published public private(set) var lastError: String?

    private static let featuresURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-features.json")

    private var savedSnapshot = FeatureFlagsFile()
    private var currentSnapshot: FeatureFlagsFile {
        FeatureFlagsFile(
            // 只写 players——player 是纯读的迁移字段(见其注释),这台机器往后不再写它。
            players: players.map(\.rawValue).sorted(),
            albumPrefetch: albumPrefetch,
            lyricsAutoUpgrade: lyricsAutoUpgrade,
            lyricsMachineTranslation: lyricsMachineTranslation,
            lastfmMirrorScrobble: lastfmMirrorScrobble,
            // 只写新键;遗留的 lastfm_scrobble_first_artist_only 是纯读的迁移字段(见其注释)。
            lastfmScrobbleArtistMode: lastfmScrobbleArtistMode.rawValue,
            scrobbleShortTracks: scrobbleShortTracks,
            weeklyDigest: weeklyDigest, dailyDigest: dailyDigest,
            weeklyDigestSource: weeklyDigestSource.isEmpty ? nil : weeklyDigestSource,
            dailyDigestSource: dailyDigestSource.isEmpty ? nil : dailyDigestSource,
            lyricsSources: lyricsSources.map(\.rawValue).sorted(),
            // 只要保存过一次就落这个字段,值如实反映集合状态。它的作用是让上面那条
            // "老配置补 amll"的迁移**只生效一次** —— 之后用户取消勾选才不会被补回来。
            amllLyrics: lyricsSources.contains(.amll),
            // 同上,lyricfind 的迁移标记独立生效一次。
            lyricFindLyrics: lyricsSources.contains(.lyricfind),
            // 同上,kuwo 的迁移标记独立生效一次(2026-08-31 加)。
            kuwoLyrics: lyricsSources.contains(.kuwo),
            lyricsSourceMode: lyricsSourceMode.rawValue,
            lyricsSourceOrder: lyricsSourceOrder.map(\.rawValue),
            lyricsDir: lyricsDir.isEmpty ? nil : lyricsDir,
            lyricsTranslationLanguage: lyricsTranslationLanguage.rawValue,
            launchLyrimuseOnMusicOpen: launchLyrimuseOnMusicOpen,
            trustedPlayers: trustedPlayers.isEmpty ? nil : trustedPlayers
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
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lyrimuse/lyrics")
    }
    public var isDirty: Bool { currentSnapshot != savedSnapshot }

    private init() {
        load()
    }

    /// 磁盘上存在、但**这个版本**的 FeatureFlagsFile 不认识的键,原样留着,写盘时再合并回去。
    ///
    /// 2026-08-13 补。原来 persistFile() 直接 `JSONEncoder().encode(currentSnapshot)`,
    /// 只吐出 FeatureFlagsFile 声明过的字段 —— 磁盘上任何它不认识的键**写一次就没了**。
    /// 上面 :93 那条注释("JSONDecoder/Go 都会静默忽略未知字段,不需要额外的迁移代码")
    /// 只对**读**成立,漏了写这一半。
    ///
    /// 具体会怎么丢:Mac A 已经更新到新版、Mac B 还停在旧版(Sparkle 不会同时到达两台)。
    /// A 导出 → B 导入,B 的 features.json 这时带着新版才有的字段 → 用户在 B 上随手拨一个
    /// 开关 → persistFile() 按旧版的 struct 重新编码 → 新版字段被抹掉 → B 再导出/更新
    /// iCloud 备份,损失就回传给 A 了。
    ///
    /// 隔壁 ConfigStore 没这个问题,它是 `raw: [String: Any]` 整字典读写(见那边 :72-78
    /// 花了六行解释为什么必须这样)。两个 Store 对未知字段的处理原本是**反的**,这里补齐。
    private var unknownFileKeys: [String: Any] = [:]

    public func load() {
        guard let data = try? Data(contentsOf: Self.featuresURL),
              let f = try? JSONDecoder().decode(FeatureFlagsFile.self, from: data) else {
            // 文件不存在/解析失败——维持属性的默认值,须跟 collector 侧 loadFeatureFlags
            // 的默认值逐字对齐(核心行为开关 fail-open=true;需要外部账号的 6 个
            // fail-closed=false,见上面属性声明处的说明)。
            //
            // ⚠️ 这条对齐是**人工维持**的,没有任何机制保证 —— 2026-08-30 就抓到 player
            // 一项脱节了(属性初值 .appleMusic vs collector 的 auto,已修)。改任一侧的
            // 默认值都要回头核对另一侧,别信这行注释说"一致"就跳过。
            unknownFileKeys = [:]
            savedSnapshot = currentSnapshot
            return
        }
        // 同一份字节再按裸字典解一次,把这个版本不认识的键记下来(见 unknownFileKeys)。
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            unknownFileKeys = obj.filter { !FeatureFlagsFile.knownFileKeys.contains($0.key) }
            // os.Logger 的插值参数是 @autoclosure,引用实例属性要显式写 self —— debug 构建
            // 放过了这一点,release(-O)才报错,所以只跑 `swift build` 验证是不够的。
            if !unknownFileKeys.isEmpty {
                logger.notice("features.json carries \(self.unknownFileKeys.count) key(s) this build doesn't know; they will be preserved on write")
            }
        } else {
            unknownFileKeys = [:]
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
        // 新键缺失/非法时退回遗留二态开关迁移一次(true → first),两者都没有才兜底 all ——
        // 跟 collector 侧 resolveScrobbleArtistMode 是同一份规则。
        lastfmScrobbleArtistMode = f.lastfmScrobbleArtistMode.flatMap(LastfmScrobbleArtistMode.init(rawValue:))
            ?? ((f.lastfmScrobbleFirstArtistOnly ?? false) ? .first : .all)
        scrobbleShortTracks = f.scrobbleShortTracks ?? false
        weeklyDigest = f.weeklyDigest ?? false
        dailyDigest = f.dailyDigest ?? false
        weeklyDigestSource = f.weeklyDigestSource ?? ""
        dailyDigestSource = f.dailyDigestSource ?? ""
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
            // ⚠️ 2026-08-25 实测坐实过:漏了这一支的那版代码,在已经保存过设置的老用户
            // 机器上会让 lyricfind 静默不参与检索(lyrics_sources 白名单里没有它、
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
                // 同上,见 FeatureFlagsFile.kuwoLyrics(2026-08-31 加)。
                enabled.insert(.kuwo)
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
        lyricsDir = f.lyricsDir ?? ""
        lyricsTranslationLanguage = f.lyricsTranslationLanguage.flatMap(MusixmatchTranslationLanguage.init(rawValue:)) ?? .auto
        launchLyrimuseOnMusicOpen = f.launchLyrimuseOnMusicOpen ?? true
        savedSnapshot = currentSnapshot
    }

    // 只写盘,不重启。
    //
    // ⚠️ 原注释说"底部保存栏会把这个和 ConfigStore.persistFile() 一起调用后统一重启
    // 一次" —— 那个保存栏已经不存在了,且本方法只被自己的 save() 调用(2026-08-30
    // 核实)。"只重启一次"现在由 CollectorRestartCoordinator 保证。
    public func persistFile() throws {
        let data = try JSONEncoder().encode(currentSnapshot)
        var payload = data
        // 把这个版本不认识的键合并回去,别让它们随这次写盘消失(见 unknownFileKeys)。
        // 合并方向是"已知字段覆盖未知同名键"——本次编码出来的才是用户刚设置的值。
        if !unknownFileKeys.isEmpty,
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in unknownFileKeys where obj[key] == nil {
                obj[key] = value
            }
            if let merged = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
            ) {
                payload = merged
            }
        }
        try payload.write(to: Self.featuresURL, options: .atomic)
    }

    public func commitSnapshot() {
        savedSnapshot = currentSnapshot
    }

    // ⚠️ 重启去抖的状态原来在这里(2026-08-02 加),2026-08-30 整体挪进了共享的
    // CollectorRestartCoordinator —— 原因不是嫌它写得不好,而是它只能是**私有**的:
    // 看不见 ConfigStore 也在重启,于是"改一个凭据 + 改一个开关"照样两次重启,正好是
    // 它当初想消灭的那个场景。别在这里重新加一份局部去抖。
    // 独立保存入口(持久化+重启+提交快照一步到位)——给本文件里每一个即时保存的开关用。
    @discardableResult
    public func save() async -> Bool {
        do {
            try persistFile()
        } catch {
            lastError = String(format: L10n.t("写入功能开关文件失败: %@"), error.localizedDescription)
            logger.error("write failed: \(String(describing: error), privacy: .public)")
            return false
        }
        // 去抖逻辑 2026-08-30 挪进了共享的 CollectorRestartCoordinator —— 原来这份是本
        // store **私有**的,只合并得了自己的连续 save(),看不见 ConfigStore 也在重启,
        // 于是"改一个凭据 + 改一个开关"仍然是两次重启(见协调器头注释)。
        if await CollectorRestartCoordinator.shared.requestRestart() {
            lastError = nil
            commitSnapshot()
            return true
        }
        lastError = L10n.t("后台采集服务重启失败")
        return false
    }

}
