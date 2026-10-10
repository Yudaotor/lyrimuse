import Foundation

/// 迷你窗「悬浮淡化」:指针一进迷你窗,整扇窗淡下去,看得见底下的东西。默认不穿透 —— 淡着的时候点击、拖动照样
/// 落在这扇窗上(07 章决策 118);开着从属的「淡化时点按穿透」时,淡着的点按落到下面的窗口,按住 ⌥ 恢复不透明、
/// 可以操作(07 章决策 144)。
public enum LyricsWindowMiniHoverFade {
    /// 淡到多少。跟悬浮歌词「悬浮淡化」同一个数。
    public static let dimmedAlpha: Double = 0.15
    /// 淡下去快、回来慢:扫过去要立刻让开才有用,回来从容一点。跟悬浮歌词那一组同样的两个数。
    public static let dimSeconds: Double = 0.12
    public static let restoreSeconds: Double = 0.18
    /// 穿透那段时间里读指针位置和 ⌥ 的间隔。
    public static let pointerPollSeconds: Double = 0.05

    /// 这一刻该不该淡:开着这颗设置、窗口是迷你、指针在窗里,这次停留里还没按过鼠标,而且没按住 ⌥(`revealHeld`,
    /// 只在开着「淡化时点按穿透」时由调用方传 true)。按过就是要用这扇窗,恢复不透明,指针出去再进来才重新算。
    public static func shouldDim(enabled: Bool, isMini: Bool, hovered: Bool, heldOpenByClick: Bool,
                                 revealHeld: Bool = false) -> Bool {
        enabled && isMini && hovered && !heldOpenByClick && !revealHeld
    }

    /// 点按要不要穿透到下面的窗口:开着「淡化时点按穿透」,而且此刻正淡着。
    public static func passesClicksThrough(clickThrough: Bool, dimmed: Bool) -> Bool {
        clickThrough && dimmed
    }

    /// 要不要轮询指针位置和 ⌥:穿透期间这扇窗收不到鼠标事件,跟踪区报的进出不可信;⌥ 按下 / 松开也不经过鼠标事件。
    /// 这次停留里按过鼠标就不再穿透,离开交给跟踪区报。
    public static func pollsPointer(enabled: Bool, clickThrough: Bool, isMini: Bool, hovered: Bool,
                                    heldOpenByClick: Bool) -> Bool {
        enabled && clickThrough && isMini && hovered && !heldOpenByClick
    }
}
