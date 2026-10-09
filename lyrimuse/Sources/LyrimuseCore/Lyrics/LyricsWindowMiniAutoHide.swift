import Foundation

/// 迷你窗「暂停时隐藏」「全屏时隐藏」的判据,App 侧执行在 `LyricsMiniPanelAutoHide`。见 07 章决策 142。
public enum LyricsWindowMiniAutoHide {
    /// 规则此刻要不要藏:开着「暂停时隐藏」且没在播,或开着「全屏时隐藏」且面板所在屏幕的当前 Space 是全屏 App。
    public static func hides(hideWhenNotPlaying: Bool, isPlaying: Bool,
                             hideInFullScreen: Bool, coveredByFullScreen: Bool) -> Bool {
        (hideWhenNotPlaying && !isPlaying) || (hideInFullScreen && coveredByFullScreen)
    }

    public enum Action: Equatable, Sendable {
        case hide
        case show
        case none
    }

    /// 判据翻转那一拍做什么:要藏且面板在屏上就藏;不藏了只摆回自己藏起来的那扇(用户关着的、本来就在屏上的都不动)。
    public static func action(hides: Bool, panelVisible: Bool, hiddenByRule: Bool) -> Action {
        if hides { return panelVisible ? .hide : .none }
        return hiddenByRule && !panelVisible ? .show : .none
    }
}
