/// 悬浮歌词窗口的显示判定(`LyricsOverlayWindowController.updateActualVisibility` 的纯逻辑部分)。
public enum OverlayVisibility {
    /// 窗口该不该在屏上:悬浮歌词开着,没被「纯音乐/无歌词时隐藏」「全屏时隐藏」藏起来,
    /// 且没开「暂停时隐藏」或正在播。
    public static func shouldShow(isVisible: Bool, hiddenForNoLyrics: Bool, coveredByFullScreen: Bool,
                                  hideWhenNotPlaying: Bool, isPlaying: Bool) -> Bool {
        isVisible && !hiddenForNoLyrics && !coveredByFullScreen && (!hideWhenNotPlaying || isPlaying)
    }

    /// 「全屏时隐藏」开着、窗口所在屏幕的当前 Space 是全屏 App 时,整扇藏起来。
    public static func fullScreenHides(enabled: Bool, coveredByFullScreenApp: Bool) -> Bool {
        enabled && coveredByFullScreenApp
    }
}
