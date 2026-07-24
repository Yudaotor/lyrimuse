import Foundation

// Lyrimuse 读取"本地正在播放"状态的目标 App——rawValue 必须跟 collector/features.go 的
// playerXxx 常量逐字对应,这是两侧通过共享 json 文件("player" 字段)交换的字符串。两个
// case 对应两条完全不同的读取路径(见 MediaControlClient.swift/collector/system.go 的
// 注释):Apple Music 走 AppleScript 直接问 Music.app 要;QQ 音乐没有 AppleScript 支持
// (用 `sdef`/PlistBuddy 核实过,压根没有 .sdef、也没开 NSAppleScriptEnabled),改走系统级
// MediaRemote(经内置的 media-control 二进制读,不需要用户单独安装任何东西)。这是一个
// 用户显式选择、持久化的设置,不是运行时按"当前谁在前台/谁最近更新过"自动判定——两个
// 播放器同时开着时自动判定天然有歧义,显式选择完全绕开这个问题。
public enum PlaybackPlayer: String, CaseIterable, Identifiable, Codable {
    case appleMusic = "apple_music"
    case qqMusic = "qq_music"

    public var id: Self { self }

    // 各自对应的 App bundle id——AppDelegate.swift("App 联动"打开对应播放器)、
    // MediaControlClient.swift(核对 media-control 报的 bundleIdentifier 是不是它)
    // 两处共用同一份映射,不重复各写一份魔法字符串。
    public var bundleIdentifier: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .qqMusic: return "com.tencent.QQMusicMac"
        }
    }
}

// 独立、轻量地读一次共享 features 文件(~/.config/lyrimuse/lyrimuse-features.json)里的
// "player" 字段——不能直接复用 FeatureSettingsStore(那是 lyrimuse 主 App target 的东西,
// LyrimuseCore 是被依赖的下层,不能反向依赖上层,见 Package.swift 的单向依赖关系)。跟
// EnrichCacheReader 是同一种模式:LyrimuseCore 自己独立读一份 App target 也在维护的共享
// JSON 文件,只取用得到的这一个字段(JSONDecoder 对不认识的其它字段直接忽略,不需要在
// 这里镜像整个 FeatureFlagsFile 的形状)。LocalPlaybackSource 每次 2 秒轮询都会读一次,
// 文件很小,不值得像 EnrichCacheReader 那样加 mtime 缓存。
public enum PlaybackPlayerPreference {
    private struct MinimalFeatureFlags: Decodable {
        let player: String?
    }

    private static let featuresURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-features.json")

    // 文件不存在/解析失败/字段缺失/值认不出,一律兜底 Apple Music——这是这个设置加入
    // 之前唯一存在过的行为,保证没有明确选过的人(全新安装、旧配置文件)不会被静默切换
    // 到一个从没配置过的播放器。
    public static var current: PlaybackPlayer {
        guard let data = try? Data(contentsOf: featuresURL),
              let f = try? JSONDecoder().decode(MinimalFeatureFlags.self, from: data),
              let raw = f.player,
              let player = PlaybackPlayer(rawValue: raw) else {
            return .appleMusic
        }
        return player
    }
}
