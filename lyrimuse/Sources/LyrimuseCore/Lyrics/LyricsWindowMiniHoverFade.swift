import Foundation

/// 迷你窗「悬浮淡化」:指针一进迷你窗,整扇窗淡下去,看得见底下的东西。不穿透 —— 淡着的时候点击、拖动照样
/// 落在这扇窗上。见 07 章决策 118。
public enum LyricsWindowMiniHoverFade {
    /// 淡到多少。跟悬浮歌词「悬浮淡化」同一个数。
    public static let dimmedAlpha: Double = 0.15
    /// 淡下去快、回来慢:扫过去要立刻让开才有用,回来从容一点。跟悬浮歌词那一组同样的两个数。
    public static let dimSeconds: Double = 0.12
    public static let restoreSeconds: Double = 0.18

    /// 这一刻该不该淡:开着这颗设置、窗口是迷你、指针在窗里,而且这次停留里还没按过鼠标。
    /// 按过就是要用这扇窗,恢复不透明,指针出去再进来才重新算。
    public static func shouldDim(enabled: Bool, isMini: Bool, hovered: Bool, heldOpenByClick: Bool) -> Bool {
        enabled && isMini && hovered && !heldOpenByClick
    }
}
