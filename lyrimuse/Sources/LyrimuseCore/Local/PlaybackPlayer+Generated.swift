// 由 scripts/gen-players.py 从 shared/players.json 生成,请勿手改。
// 接一个新播放器:改那份 JSON → 跑 `python3 scripts/gen-players.py` → 补一张品牌图标。
// CI 跑 `--check` 对账,手改这里会红。
//
// 这个类型为什么是「用户显式选择」而不是运行时自动判定、.auto 为什么是那条原则的
// 例外、bundleIdentifier 为什么对 .auto 返回空字符串 —— 完整背景在 PlaybackPlayer.swift。

import Foundation

public enum PlaybackPlayer: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 系统自带,走 AppleScript(JXA)直问 Music.app,因此要一份「自动化」权限;scrobbleLabel 同时是 mediaPlayerLabel 认不出来源时的兜底值。
    case appleMusic = "apple_music"
    /// 无 AppleScript 字典(核实过:无 .sdef、未开 NSAppleScriptEnabled),走 media-control;读数整秒下取整 + ±1~1.5s 抖动。随机 / 循环走它菜单栏「播放控制 → 播放模式」(QQMusicMenuControl),所以要辅助功能权限。
    case qqMusic = "qq_music"
    /// 同 QQ 音乐:无 AppleScript 字典,走 media-control,整秒量化。冷启动后一两秒内开播,它启动时那次延迟的清空会把在放的会话撤掉、声音照放,直到暂停或换歌才重新登记(02 章决策 96)。
    case netease = "netease_music"
    /// Mac Catalyst 应用,靠 MPNowPlayingInfoCenter 发布进 MediaRemote。processName 是 UTF-8 12 字节,内核 p_comm 上限 16 字节——再长两个汉字 pgrep -x 就会失效。
    case kugou = "kugou_music"
    /// Electron 应用,走 media-control。只在开播发一个 elapsed=0 锚点、播放中不再重发(实测 42 秒里 elapsedTime 恒 0、timestamp 冻在开播那一刻),位置全靠墙钟外推,所以归 cleanExtrapolated —— 这也正是它此前作为信任播放器走的那一档,内置化不改变位置行为。那个 0 锚点有概率被原样重发一次,由 zeroAnchorRepublishWindowSecs 的时间窗兜住。processName 是 UTF-8 12 字节,与酷狗同长,在内核 p_comm 16 字节上限内。
    case soda = "soda_music"
    /// Electron 应用,走 media-control,没有 AppleScript 字典、没有沙盒。播放中约每 1.06 秒重发一次锚点,位置精确到微秒、跟墙钟一致(实测 92 秒累计偏差 0.8 毫秒),归 cleanExtrapolated —— 跟它此前作为信任播放器走的是同一档,内置化不改变位置行为。开播先发一帧只有歌名的(歌手空、时长 0、rate 0),约半秒后才补齐,所以 artistArrivesLate;开播那个 0 锚点没见过原样重发。切歌时会先撤掉 Now Playing(多数 4~5 秒,刚开播一张专辑后的第一次切歌实测有过 19 秒),暂停着点开新列表加载时也撤,所以 dropsSessionBetweenTracks。歌手名取每首歌自己的 artist_roles,同一个歌手也时有时无括号里的译名(`Taylor Swift` / `Taylor Swift (泰勒絲)`、`周杰倫` / `周杰倫 (Jay Chou)`)。nativeLyricSource 填 kkbox:不是歌词源(接入走不通,见 kkboxlyrics.go 头注),是用它放歌时读它自己缓存里的那份歌词,享受同源加权。processName 5 字节。
    case kkbox = "kkbox"
    /// 自己有 AppleScript 字典,曲目与播放位置都走它直问 Spotify.app(跟 Apple Music 同一条路);media-control 只负责回答「现在是谁在放」,以及 AppleScript 不可达时兜底。duration 那边是毫秒,Music.app 是秒。
    case spotify = "spotify"
    /// CEF 桌面客户端(x86_64,在 Apple 芯片上走 Rosetta),走 media-control,没有 AppleScript 字典、没有沙盒。系统 Now Playing 里**没有 elapsedTime**:时间戳是这首真正出声(缓冲完)的时刻,暂停只翻 playing、playbackRate 恒为 1、时间戳不动,拖动进度什么都不报,media-control 的 seek 命令它也不响应。所以位置不取系统值,由 AmazonMusicPlayhead 按它自己的日志(开播 / 暂停 / 恢复 / 拖动 / 缓冲卡顿)重放,读不到日志时退回按开播时刻加暂停记时;换上去的是干净锚点,归 cleanExtrapolated。切歌不撤会话,开播的 0 锚点不重发,歌手不晚到。刚开播时偶尔先发一帧上一次会话的旧曲目(旧时间戳、playing 为真),约 3 秒后才换成真的。播客歌手、专辑为空、时长大于 0。多个歌手用 ` & ` 连,专辑名常带 ` [Explicit]`。nativeLyricSource 填 amazon:不是歌词源,是用它放歌时读它自己缓存里的那份歌词(逐行、毫秒,按 ASIN 认身份,见 amazonlibrary.go),享受同源加权。processName 12 字节。
    case amazonMusic = "amazon_music"
    /// YouTube Music 的原生客户端:Swift 外壳加一个隐藏的 WKWebView 跑 YouTube Music 网页版放歌,有 AppleScript 字典(`get player info` 回一段 JSON:曲目、时长、位置、播放状态、videoId),没有沙盒。系统 Now Playing 里它那份靠不住:播放中把会话交给 WebKit(那份只有时长和进度、歌名歌手是空的,bundle id 报成 com.apple.WebKit.GPU),自己只在暂停、加载的空档发一份只有歌名歌手的,所以连播换歌后常停在上一首,换歌加载时整个撤掉、放起来也不一定补回。曲目与位置因此整份换成 AppleScript 那份(KasetPlayerInfo),系统那边只用来认是不是它在放,一拍都没有它时它开着就直接问。位置是网页 video.currentTime 每 0.5 秒推一次的值,读到的只会比真值晚 0~0.5 秒、不会早,跟 QQ 音乐、网易云的整秒下取整同一类,归 noisyFloored。广告与开播缓冲时报在放、位置停在 0,曲尾偶尔卡住(报在放、位置不动),都按没在走算。署名是逐个艺人用 `, ` 连起来的,界面语言是中文时会把「、」「和」这类连接词也当成艺人;专辑一栏放歌单时填的是歌单名,不用。media-control 的播放、暂停、切歌、跳转它都响应,快进 15 秒不响应。nativeLyricSource 填 lyricfind:它放的是 YouTube Music 曲库,显示的是 YouTube Music 自己的歌词(这一源只收 LyricFind 那部分)。processName 5 字节。
    case kaset = "kaset"
    /// 不是一个具体 App——把「谁在报 Now Playing」交给系统仲裁。bundleID 空字符串是刻意的,调用方据此 no-op 掉需要具体 App 的联动。
    case auto = "auto"

    public var id: Self { self }

    /// 对应的 App bundle id。`.auto` 是空字符串 —— 它没有唯一目标,调用方据此
    /// 自然地 no-op 掉「打开 Lyrimuse 时唤起播放器」这类需要具体 App 才成立的联动。
    public var bundleIdentifier: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .qqMusic: return "com.tencent.QQMusicMac"
        case .netease: return "com.netease.163music"
        case .kugou: return "com.kugou.mac.Music"
        case .soda: return "com.soda.music"
        case .kkbox: return "com.kkbox.electron-app"
        case .spotify: return "com.spotify.client"
        case .amazonMusic: return "com.amazon.music"
        case .kaset: return "com.sertacozercan.Kaset"
        case .auto: return ""
        }
    }

    /// 这个播放器自家的歌词源(同源加权)。Go 侧 playerNativeLyricSources 同源。
    public var nativeLyricSource: String? {
        switch self {
        case .appleMusic: return "applemusic"
        case .qqMusic: return "qq"
        case .netease: return "netease"
        case .kugou: return "kugou"
        case .soda: return "soda"
        case .kkbox: return "kkbox"
        case .amazonMusic: return "amazon"
        case .kaset: return "lyricfind"
        default: return nil
        }
    }

    /// 位置读数画像的标识(precise / cleanExtrapolated / noisyFloored)。
    /// 映射成 `LocalPlaybackSource.PositionSourceTier` 在那边做 —— 那个枚举连同
    /// 每一档的实测依据都属于伺服逻辑,不该跟着这张表走。
    public var positionTierID: String? {
        switch self {
        case .appleMusic: return "precise"
        case .qqMusic: return "noisyFloored"
        case .netease: return "noisyFloored"
        case .kugou: return "cleanExtrapolated"
        case .soda: return "cleanExtrapolated"
        case .kkbox: return "cleanExtrapolated"
        case .spotify: return "precise"
        case .amazonMusic: return "cleanExtrapolated"
        case .kaset: return "noisyFloored"
        default: return nil
        }
    }

    /// 向这个播放器发 Apple Event 要不要 macOS 的「自动化」权限。
    /// = 它有 AppleScript 字典、且本仓真的在用(读播放头 / 播放控制 / 取图床地址)。
    /// 只覆盖 Lyrimuse 自己这一份身份;引擎不向播放器发 Apple Event(预解析那几样由 App 代跑)。
    /// 消费点见 `Set<PlaybackPlayer>.playersNeedingAutomation`。
    public var needsAutomationPermission: Bool {
        switch self {
        case .appleMusic: return true
        case .spotify: return true
        case .kaset: return true
        default: return false
        }
    }

    /// 引擎读这个播放器的客户端文件(歌词缓存 / 播放队列)要不要「完全磁盘访问」。
    /// = 那些文件在 `~/Library/Containers/` 下;引擎侧有测试按真实路径对账。
    /// 消费点见 `Set<PlaybackPlayer>.playersNeedingFullDiskAccess`。
    public var needsFullDiskAccess: Bool {
        switch self {
        case .qqMusic: return true
        case .netease: return true
        case .kugou: return true
        default: return false
        }
    }

    /// Lyrimuse 要不要「辅助功能」权限来读这个播放器的界面(读的是 App,不是引擎)。
    /// = 本仓真的在读它的辅助功能树。消费点见 `Set<PlaybackPlayer>.playersNeedingAccessibility`。
    public var needsAccessibilityPermission: Bool {
        switch self {
        case .qqMusic: return true
        case .amazonMusic: return true
        default: return false
        }
    }

    /// 开播那个 `elapsed == 0` 的锚点会不会被这个播放器原样重发一次。
    /// 只有**实测见过**的播放器为 true:真起播点是连发里的哪一个,各家相反
    /// (汽水音乐/网易云是第一个,Apple Music 是最后一个),判反 = 整首歌恒定偏移。
    /// 判定本身在 `MediaControlClient.isStaleAnchorRepublish`。
    public var republishesZeroAnchor: Bool {
        switch self {
        case .netease: return true
        case .soda: return true
        case .spotify: return true
        default: return false
        }
    }

    /// 这个播放器报的 `playing:false` 不可信、要按 `playbackRate > 0` 判在不在播。
    /// 只有**实测见过**的播放器为 true。判定本身在 `MediaControlClient.effectivePlaying`。
    public var playingFromRate: Bool {
        switch self {
        case .kugou: return true
        default: return false
        }
    }

    /// 开播先发一帧只有歌名、歌手还空着的,过一会儿才补齐。只有**实测见过**的播放器为 true。
    /// 那一帧当作还没准备好,判定在 `TrustedPlayers.notASong`。
    public var artistArrivesLate: Bool {
        switch self {
        case .kkbox: return true
        default: return false
        }
    }

    /// 歌手空、时长 > 0、在放的快照是非歌曲内容(播客单集)。只有**实测见过**的播放器为 true。
    /// 判定在 `TrustedPlayers.artistlessContent`;Go 侧 playerArtistlessNotMusic 同源(歌词解析入口用)。
    public var artistlessNotMusic: Bool {
        switch self {
        case .kkbox: return true
        case .amazonMusic: return true
        default: return false
        }
    }

    /// 外部的跳转指令它不响应。只有**实测见过**的播放器为 true。进度条只显示不能拖,
    /// 见 `LocalPlaybackSource.acceptsSeek`。
    public var ignoresSeekCommand: Bool {
        switch self {
        case .amazonMusic: return true
        default: return false
        }
    }

    /// 切歌时先撤掉 Now Playing、隔几秒才发下一首。只有**实测见过**的播放器为 true。
    /// 判定在 `PlayerGapHold`。
    public var dropsSessionBetweenTracks: Bool {
        switch self {
        case .kkbox: return true
        default: return false
        }
    }

    /// 在放的时候会把 Now Playing 撤掉、声音照放,直到暂停或换歌才重新登记。只有**实测见过**的播放器为 true。
    /// 判定在 `PlayerGapHold.shouldHoldWhileOutputting`。
    public var dropsSessionWhilePlaying: Bool {
        switch self {
        case .netease: return true
        default: return false
        }
    }

    /// 这个 bundle id 属于哪个内置播放器 —— 认不出来(第三方 / 信任列表里的 App /
    /// 空值)返回 nil。`.auto` 永远不会被返回:它不对应任何 App。
    public static func builtin(forBundleID bundleID: String?) -> PlaybackPlayer? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return allCases.first { $0 != .auto && $0.bundleIdentifier == bundleID }
    }
}

extension TrustedPlayers {
    /// 「媒体进程 bundle id → 宿主 App bundle id」:Safari 报 Now Playing 用的是 WebKit GPU 进程,
    /// 查信任列表之前先换回宿主(判法见 `mediaProxyOwner(of:)`)。Go 侧 mediaProxyOwners 同源。
    public static let mediaProxyOwners: [String: String] = [
        "com.apple.WebKit.GPU": "com.apple.Safari",
    ]
}
