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
    /// 无 AppleScript 字典(核实过:无 .sdef、未开 NSAppleScriptEnabled),走 media-control;读数整秒下取整 + ±1~1.5s 抖动。
    case qqMusic = "qq_music"
    /// 同 QQ 音乐:无 AppleScript 字典,走 media-control,整秒量化。
    case netease = "netease_music"
    /// Mac Catalyst 应用,靠 MPNowPlayingInfoCenter 发布进 MediaRemote。processName 是 UTF-8 12 字节,内核 p_comm 上限 16 字节——再长两个汉字 pgrep -x 就会失效。
    case kugou = "kugou_music"
    /// Electron 应用,走 media-control。只在开播发一个 elapsed=0 锚点、播放中不再重发(实测 42 秒里 elapsedTime 恒 0、timestamp 冻在开播那一刻),位置全靠墙钟外推,所以归 cleanExtrapolated —— 这也正是它此前作为信任播放器走的那一档,内置化不改变位置行为。那个 0 锚点有概率被原样重发一次,由 zeroAnchorRepublishWindowSecs 的时间窗兜住。processName 是 UTF-8 12 字节,与酷狗同长,在内核 p_comm 16 字节上限内。
    case soda = "soda_music"
    /// 自己有 AppleScript 字典,曲目与播放位置都走它直问 Spotify.app(跟 Apple Music 同一条路);media-control 只负责回答「现在是谁在放」,以及 AppleScript 不可达时兜底。duration 那边是毫秒,Music.app 是秒。
    case spotify = "spotify"
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
        case .spotify: return "com.spotify.client"
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
        case .spotify: return "precise"
        default: return nil
        }
    }

    /// 向这个播放器发 Apple Event 要不要 macOS 的「自动化」权限。
    /// = 它有 AppleScript 字典、且本仓真的在用(读播放头 / 播放控制 / 取图床地址)。
    /// 只覆盖 Lyrimuse 自己这一份身份:collector 是独立签名身份,TCC 里是另一条记录。
    /// 消费点见 `Set<PlaybackPlayer>.playersNeedingAutomation`。
    public var needsAutomationPermission: Bool {
        switch self {
        case .appleMusic: return true
        case .spotify: return true
        default: return false
        }
    }

    /// collector 读这个播放器的客户端文件(歌词缓存 / 播放队列)要不要「完全磁盘访问」。
    /// = 那些文件在 `~/Library/Containers/` 下;collector 侧有测试按真实路径对账。
    /// 消费点见 `Set<PlaybackPlayer>.playersNeedingFullDiskAccess`。
    public var needsFullDiskAccess: Bool {
        switch self {
        case .qqMusic: return true
        case .netease: return true
        case .kugou: return true
        default: return false
        }
    }

    /// 开播那个 `elapsed == 0` 的锚点会不会被这个播放器原样重发一次。
    /// 只有**实测见过**的播放器为 true:真起播点是连发里的哪一个,各家相反
    /// (汽水音乐/网易云是第一个,Apple Music 是最后一个),判反 = 整首歌恒定偏移。
    /// 判定本身在 `MediaControlClient.isStaleAnchorRepublish`,Go 侧同源。
    public var republishesZeroAnchor: Bool {
        switch self {
        case .netease: return true
        case .soda: return true
        case .spotify: return true
        default: return false
        }
    }

    /// 这个播放器报的 `playing:false` 不可信、要按 `playbackRate > 0` 判在不在播。
    /// 只有**实测见过**的播放器为 true。判定本身在 `MediaControlClient.effectivePlaying`,Go 侧同源。
    public var playingFromRate: Bool {
        switch self {
        case .kugou: return true
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
