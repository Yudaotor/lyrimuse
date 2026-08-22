import Foundation

// Lyrimuse 读取"本地正在播放"状态的目标 App——rawValue 必须跟 collector/features.go 的
// playerXxx 常量逐字对应,这是两侧通过共享 json 文件("player" 字段)交换的字符串。四个
// 具体 App 对应两条完全不同的读取路径(见 MediaControlClient.swift/collector/system.go
// 的注释):Apple Music 走 AppleScript 直接问 Music.app 要;QQ 音乐/网易云音乐/酷狗音乐都没有
// AppleScript 支持(用 `sdef`/PlistBuddy 核实过,两者都压根没有 .sdef、也没开
// NSAppleScriptEnabled),共用同一条系统级 MediaRemote 路径(经内置的 media-control
// 二进制读,不需要用户单独安装任何东西),只是各自的 bundleIdentifier 不同。Spotify
// 虽然自己有完整的 AppleScript 支持(跟 QQ/网易云不一样),但它同样会把播放状态发布进
// 系统级 MediaRemote(2026-07-29 实测坐实:`media-control get`/控制指令对 Spotify 都
// 正常工作,读到的字段形状跟 Apple Music/QQ音乐/网易云音乐完全一致),没有必要为它单独
// 写一套 AppleScript 集成、多背一份"自动化"权限依赖——归到跟 QQ/网易云同一条路径。
//
// 具体选好某一个 App 是一个用户显式选择、持久化的设置,不是运行时按"当前谁在前台/谁
// 最近更新过"自动判定——多个播放器同时开着时自动判定天然有歧义,显式选择完全绕开这个
// 问题。2026-07-29 新增的 .auto 是这条原则的例外:它不是"不自动判定",而是主动把"系统
// 当前认定的唯一 Now Playing 来源是谁"这件事直接交给系统本身仲裁——媒体系统(macOS 的
// MediaRemote/Control Center)本来就只会有一个"当前正在播放"焦点,不是这个 App 自己在
// 猜。.auto 因此不对应任何单一固定的 bundle id(bundleIdentifier 返回空字符串,调用方
// 按"没有唯一确定的目标 App"处理,比如"打开 Lyrimuse 时唤起播放器"这类需要一个具体
// App 才有意义的联动直接跳过),真正的检测逻辑在 MediaControlClient.fetchSnapshot/
// collector 的 getState() 里:问 media-control 当前是谁在报告 Now Playing,核对是不是
// 这五个已知播放器之一,是 Apple Music 的话还会额外走一次 AppleScript 拿更精确的播放
// 位置(拿不到权限就退回 media-control 本身的读数,不会整个放弃)。
public enum PlaybackPlayer: String, CaseIterable, Identifiable, Codable {
    case appleMusic = "apple_music"
    case qqMusic = "qq_music"
    case netease = "netease_music"
    // 酷狗音乐(2026-08-21 接入)。跟 QQ/网易云同一条路径,不需要新代码分支:它是个 Mac
    // Catalyst 应用(主二进制链的是 /System/iOSSupport/.../MediaPlayer.framework),自己把
    // 播放状态发布进系统级 MediaRemote;同样没有 AppleScript 字典(Info.plist 里没有
    // NSAppleScriptEnabled、Resources 下也没有 .sdef,2026-08-21 核实),所以扩展控件
    // (喜欢/音量/播放模式)一律没有。顺带白捡一项:酷狗本来就是这个项目的五个歌词源之一,
    // 接入播放器等于把「同源加权」也接上了(见 collector 的 playerNativeLyricSource)。
    case kugou = "kugou_music"
    case spotify = "spotify"
    case auto = "auto"

    public var id: Self { self }

    // 各自对应的 App bundle id——AppDelegate.swift("App 联动"打开对应播放器)、
    // MediaControlClient.swift(核对 media-control 报的 bundleIdentifier 是不是它)
    // 两处共用同一份映射,不重复各写一份魔法字符串。.auto 没有唯一固定的目标,返回空
    // 字符串——AppDelegate.swift 用它去查 NSWorkspace.urlForApplication(withBundleIdentifier:),
    // 空字符串查不到任何 App,自然、安全地no-op掉"打开 Lyrimuse 时唤起播放器"这个方向,
    // 不需要在调用点额外加判断。
    public var bundleIdentifier: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .qqMusic: return "com.tencent.QQMusicMac"
        case .netease: return "com.netease.163music"
        case .kugou: return "com.kugou.mac.Music"
        case .spotify: return "com.spotify.client"
        case .auto: return ""
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

    // 文件不存在/解析失败/字段缺失/值认不出,一律兜底**自动识别**。
    //
    // 2026-08-13 从 appleMusic 改成 auto。原来的理由是"这是这个设置加入之前唯一存在过的
    // 行为",但那对全新用户是个坏默认:只用 Spotify / QQ 音乐 / 网易云的人如果跳过引导里
    // 选播放器那一步,App 会一直去问 Music.app,界面永远空白、且完全看不出原因;顺带还要
    // 为此多要一次 Apple Music 自动化权限(请求前会后台把 Music.app 拉起来),对一个压根
    // 不用 Apple Music 的人既没必要又突兀。auto 问的是系统级 Now Playing 是谁在放,
    // 装完就能用。
    public static var current: PlaybackPlayer {
        guard let data = try? Data(contentsOf: featuresURL),
              let f = try? JSONDecoder().decode(MinimalFeatureFlags.self, from: data),
              let raw = f.player,
              let player = PlaybackPlayer(rawValue: raw) else {
            return .auto
        }
        return player
    }
}
