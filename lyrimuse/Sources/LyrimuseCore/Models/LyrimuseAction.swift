import Foundation

/// 全局快捷键能做的每一件事,也是 `lyrimuse://action/<名字>` 能触发的那一套。rawValue 就是快捷键的内部名
/// (`KeyboardShortcuts.Name`,存在用户偏好里,不能改);链接里用 `linkName`(小写加连字符)。两边执行同一份逻辑
/// (App 侧 `LyrimuseActionRunner.perform`),行为和回声一致。见 14 章「深链」。
///
/// 只收打开窗口、可随时撤回的开关、播放控制、歌词时间轴和悬浮歌词字号的一档档微调;会改歌词缓存或别的设置的不在这里(任何网页都能拉起
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
    case overlayFontLargerHotkey
    case overlayFontSmallerHotkey
    case toggleAllLyricsHotkey
    case toggleFavoriteHotkey
    case openPlayerHotkey

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
        case .overlayFontLargerHotkey: return "overlay-font-larger"
        case .overlayFontSmallerHotkey: return "overlay-font-smaller"
        case .toggleAllLyricsHotkey: return "toggle-all-lyrics"
        case .toggleFavoriteHotkey: return "toggle-favorite"
        case .openPlayerHotkey: return "open-player"
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
             .toggleRomanizationHotkey, .toggleNotchOverlayHotkey, .toggleMenuBarLyricsHotkey, .toggleAllLyricsHotkey,
             .toggleFavoriteHotkey:
            return true
        default:
            return false
        }
    }

    /// 能带 `step=<秒>` 的:歌词提前 / 延后。不带就用设置里的步长。
    public var acceptsStep: Bool { self == .lyricsAdvanceHotkey || self == .lyricsDelayHotkey }

    /// `step` 的上限(秒)。再大就不是「微调」了,链接里写错一位数会把整首歌词错开很远。
    public static let maxStepSeconds = 5.0

    // MARK: - 快捷键页

    /// 「快捷键」页的四张卡。
    public enum ShortcutGroup: String, CaseIterable, Sendable {
        case display, window, timing, playback

        /// 卡标题(简体就是 L10n 的键)。
        public var titleKey: String {
            switch self {
            case .display: return "显示开关"
            case .window: return "打开窗口"
            case .timing: return "歌词时间轴"
            case .playback: return "播放控制"
            }
        }
    }

    /// 快捷键页每张卡里摆哪几格、什么顺序。每个动作正好出现一次(selftest 核对):设置页的格子、撞键检查、
    /// 设置搜索都按这一份来,加动作只在这个文件里登记。
    public static let shortcutLayout: [(group: ShortcutGroup, actions: [LyrimuseAction])] = [
        (.display, [.toggleOverlay, .toggleNotchOverlayHotkey, .toggleMenuBarLyricsHotkey, .toggleTouchBarLyricsHotkey,
                    .toggleAllLyricsHotkey, .toggleLockPosition, .toggleTranslationHotkey, .toggleRomanizationHotkey,
                    .overlayFontLargerHotkey, .overlayFontSmallerHotkey]),
        (.window, [.openLyricsManagerHotkey, .openLyricsWindowHotkey, .toggleLyricsWindowMiniHotkey,
                   .lyricsQuickSearchHotkey, .openSettingsHotkey, .openPlayerHotkey]),
        (.timing, [.lyricsAdvanceHotkey, .lyricsDelayHotkey, .lyricsOffsetResetHotkey]),
        (.playback, [.playPauseHotkey, .nextTrackHotkey, .previousTrackHotkey, .toggleFavoriteHotkey]),
    ]

    /// 给用户看的名字(简体就是 L10n 的键):快捷键页那一格、撞键提示、设置搜索共用。
    public var titleKey: String {
        switch self {
        case .toggleOverlay: return "显示/隐藏悬浮歌词"
        case .toggleNotchOverlayHotkey: return "显示/隐藏灵动岛歌词"
        case .toggleMenuBarLyricsHotkey: return "显示/隐藏菜单栏歌词"
        case .toggleTouchBarLyricsHotkey: return "展开/收起触控栏歌词"
        case .toggleAllLyricsHotkey: return "隐藏/恢复全部歌词"
        case .toggleLockPosition: return "锁定/解锁位置"
        case .toggleTranslationHotkey: return "显示/隐藏译文"
        case .toggleRomanizationHotkey: return "显示/隐藏读音"
        case .overlayFontLargerHotkey: return "放大悬浮歌词字号"
        case .overlayFontSmallerHotkey: return "缩小悬浮歌词字号"
        case .openLyricsManagerHotkey: return "打开歌词管理"
        case .openLyricsWindowHotkey: return "打开歌词窗口"
        case .toggleLyricsWindowMiniHotkey: return "切换迷你 / 完整尺寸"
        case .lyricsQuickSearchHotkey: return "搜索歌词"
        case .openSettingsHotkey: return "打开设置"
        case .openPlayerHotkey: return "回到播放器"
        case .lyricsAdvanceHotkey: return "歌词提前"
        case .lyricsDelayHotkey: return "歌词延后"
        case .lyricsOffsetResetHotkey: return "歌词偏移归零"
        case .playPauseHotkey: return "播放/暂停"
        case .nextTrackHotkey: return "下一首"
        case .previousTrackHotkey: return "上一首"
        case .toggleFavoriteHotkey: return "喜欢/取消喜欢"
        }
    }

    /// 快捷键页那一格的图标:SF Symbol 名;触控栏那一格是自画图标的名字(App 侧 `SurfaceGlyph.touchBar`)。
    public var iconName: String {
        switch self {
        case .toggleOverlay: return "eye"
        case .toggleNotchOverlayHotkey: return "inset.filled.topthird.square"
        case .toggleMenuBarLyricsHotkey: return "menubar.rectangle"
        case .toggleTouchBarLyricsHotkey: return "lyrimuse.touchbar"
        case .toggleAllLyricsHotkey: return "eye.slash"
        case .toggleLockPosition: return "lock"
        case .toggleTranslationHotkey: return "character.book.closed"
        case .toggleRomanizationHotkey: return "textformat.abc"
        case .overlayFontLargerHotkey: return "textformat.size.larger"
        case .overlayFontSmallerHotkey: return "textformat.size.smaller"
        case .openLyricsManagerHotkey: return "list.bullet.rectangle"
        case .openLyricsWindowHotkey: return "text.quote"
        case .toggleLyricsWindowMiniHotkey: return "rectangle.inset.bottomright.filled"
        case .lyricsQuickSearchHotkey: return "magnifyingglass"
        case .openSettingsHotkey: return "gearshape"
        case .openPlayerHotkey: return "play.rectangle"
        case .lyricsAdvanceHotkey: return "backward.end"
        case .lyricsDelayHotkey: return "forward.end"
        case .lyricsOffsetResetHotkey: return "arrow.counterclockwise"
        case .playPauseHotkey: return "playpause"
        case .nextTrackHotkey: return "forward.fill"
        case .previousTrackHotkey: return "backward.fill"
        case .toggleFavoriteHotkey: return "heart"
        }
    }

    /// 设置搜索的关键词(简体)。「快捷键」「hotkey」由目录统一加上。
    public var searchKeywords: [String] {
        switch self {
        case .toggleOverlay: return ["悬浮歌词", "开关"]
        case .toggleNotchOverlayHotkey: return ["灵动岛", "开关"]
        case .toggleMenuBarLyricsHotkey: return ["菜单栏", "开关"]
        case .toggleTouchBarLyricsHotkey: return ["触控栏", "Touch Bar", "功能栏", "展开", "收起", "开关"]
        case .toggleAllLyricsHotkey: return ["全部", "隐藏", "开会", "共享屏幕", "录屏", "开关"]
        case .toggleLockPosition: return ["锁定", "位置"]
        case .toggleTranslationHotkey: return ["译文", "翻译"]
        case .toggleRomanizationHotkey: return ["罗马音", "发音", "拼音", "粤拼"]
        case .overlayFontLargerHotkey: return ["字号", "字体大小", "放大", "font size"]
        case .overlayFontSmallerHotkey: return ["字号", "字体大小", "缩小", "font size"]
        case .openLyricsManagerHotkey: return ["歌词管理", "窗口"]
        case .openLyricsWindowHotkey: return ["歌词窗口", "窗口"]
        case .toggleLyricsWindowMiniHotkey: return ["歌词窗口", "迷你", "完整尺寸"]
        case .lyricsQuickSearchHotkey: return ["手动搜索", "换歌词"]
        case .openSettingsHotkey: return ["设置窗口"]
        case .openPlayerHotkey: return ["播放器", "切换", "前台"]
        case .lyricsAdvanceHotkey, .lyricsDelayHotkey: return ["偏移", "时间轴", "校准"]
        case .lyricsOffsetResetHotkey: return ["偏移", "重置", "时间轴"]
        case .playPauseHotkey: return ["播放控制"]
        case .nextTrackHotkey, .previousTrackHotkey: return ["播放控制", "切歌"]
        case .toggleFavoriteHotkey: return ["喜欢", "收藏", "红心", "星标", "favorite", "love"]
        }
    }
}
