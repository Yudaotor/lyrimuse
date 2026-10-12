import Foundation

/// 全局快捷键能做的每一件事,也是 `lyrimuse://action/<名字>` 能触发的那一套。rawValue 就是快捷键的内部名
/// (`KeyboardShortcuts.Name`,存在用户偏好里,不能改);链接里用 `linkName`(小写加连字符)。两边执行同一份逻辑
/// (App 侧 `LyrimuseActionRunner.perform`),行为和回声一致。见 14 章「深链」。
///
/// 只收打开窗口、可随时撤回的开关、播放控制、歌词时间轴微调;会改歌词缓存或设置的不在这里(任何网页都能拉起
/// `lyrimuse://`,见 docs/proposals/deep-links.md 第 6 节)。
public enum LyrimuseAction: String, CaseIterable, Sendable {
    case toggleOverlay
    case toggleLockPosition
    case openLyricsManagerHotkey
    case openLyricsWindowHotkey
    case toggleLyricsWindowMiniHotkey
    case openSettingsHotkey
    case playPauseHotkey
    case nextTrackHotkey
    case previousTrackHotkey
    case lyricsAdvanceHotkey
    case lyricsDelayHotkey
    case lyricsQuickSearchHotkey
    case toggleTranslationHotkey
    case toggleRomanizationHotkey
    case toggleNotchOverlayHotkey
    case toggleMenuBarLyricsHotkey
    case toggleTouchBarLyricsHotkey
    case lyricsOffsetResetHotkey

    /// `lyrimuse://action/<linkName>` 里那一段。对外契约,改名前先看对外说过没有。
    public var linkName: String {
        switch self {
        case .toggleOverlay: return "toggle-overlay"
        case .toggleLockPosition: return "toggle-lock-position"
        case .openLyricsManagerHotkey: return "open-lyrics-manager"
        case .openLyricsWindowHotkey: return "open-lyrics-window"
        case .toggleLyricsWindowMiniHotkey: return "toggle-lyrics-window-mini"
        case .openSettingsHotkey: return "open-settings"
        case .playPauseHotkey: return "play-pause"
        case .nextTrackHotkey: return "next-track"
        case .previousTrackHotkey: return "previous-track"
        case .lyricsAdvanceHotkey: return "lyrics-advance"
        case .lyricsDelayHotkey: return "lyrics-delay"
        case .lyricsQuickSearchHotkey: return "search-lyrics"
        case .toggleTranslationHotkey: return "toggle-translation"
        case .toggleRomanizationHotkey: return "toggle-romanization"
        case .toggleNotchOverlayHotkey: return "toggle-notch"
        case .toggleMenuBarLyricsHotkey: return "toggle-menubar-lyrics"
        case .toggleTouchBarLyricsHotkey: return "toggle-touchbar"
        case .lyricsOffsetResetHotkey: return "lyrics-offset-reset"
        }
    }

    public init?(linkName: String) {
        guard let match = Self.allCases.first(where: { $0.linkName == linkName.lowercased() }) else { return nil }
        self = match
    }

    /// 能带 `on=1 / on=0` 指定目标状态的开关(重复执行结果不变,自动化工具要的就是这个)。不带就翻转。
    /// 触控栏那一个按此刻看不看得见来展开 / 收起(17 章决策 40),没有「目标状态」可言,不收。
    public var acceptsTargetState: Bool {
        switch self {
        case .toggleOverlay, .toggleLockPosition, .toggleLyricsWindowMiniHotkey, .toggleTranslationHotkey,
             .toggleRomanizationHotkey, .toggleNotchOverlayHotkey, .toggleMenuBarLyricsHotkey:
            return true
        default:
            return false
        }
    }

    /// 能带 `step=<秒>` 的:歌词提前 / 延后。不带就用设置里的步长。
    public var acceptsStep: Bool { self == .lyricsAdvanceHotkey || self == .lyricsDelayHotkey }

    /// `step` 的上限(秒)。再大就不是「微调」了,链接里写错一位数会把整首歌词错开很远。
    public static let maxStepSeconds = 5.0
}
