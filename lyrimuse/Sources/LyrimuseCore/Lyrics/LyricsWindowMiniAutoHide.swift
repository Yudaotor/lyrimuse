import Foundation

/// 迷你窗「暂停时隐藏」「纯音乐/无歌词时隐藏」「广告时隐藏」「全屏时隐藏」的判据,App 侧执行在 `LyricsMiniPanelAutoHide`。
/// 见 07 章决策 142、190、209。
public enum LyricsWindowMiniAutoHide {
    /// 规则此刻要不要藏:开着「暂停时隐藏」且没在播,或开着「纯音乐/无歌词时隐藏」且这首没有能显示的歌词
    /// (`NoLyricsAutoHide.lacksLyrics`,搜索期间算有),或开着「广告时隐藏」且这一刻在放广告,
    /// 或开着「全屏时隐藏」且面板所在屏幕的当前 Space 是全屏 App。
    public static func hides(hideWhenNotPlaying: Bool, isPlaying: Bool,
                             hideWhenNoLyrics: Bool, lacksLyrics: Bool,
                             hideDuringAds: Bool = false, isAdBreak: Bool = false,
                             hideInFullScreen: Bool, coveredByFullScreen: Bool) -> Bool {
        (hideWhenNotPlaying && !isPlaying)
            || NoLyricsAutoHide.hides(enabled: hideWhenNoLyrics, lacksLyrics: lacksLyrics)
            || (hideDuringAds && isAdBreak)
            || (hideInFullScreen && coveredByFullScreen)
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
