import AppKit

/// 悬浮歌词上按住 ⌘ 滚动滚轮 / 触控板双指上下滑调字号(见 04 章决策 62)的纯计算部分:把滚动量折成档数,一档就是
/// ⚙ 菜单「字号」按一下(`AppSettings.steppedOverlayFontSize`)。正数放大、负数缩小。
public struct OverlayFontZoom: Sendable {
    /// 按住它才调字号;没按着的滚动照旧让给下层窗口。
    public static let modifier: NSEvent.ModifierFlags = .command
    /// 触控板滚动攒够这么多点算一档。鼠标滚轮不攒,一格一档。
    public static let pointsPerStep: CGFloat = 24

    private var scrollCarry: CGFloat = 0

    public init() {}

    /// 按设备方向的纵向滚动量:滚轮往前推、触控板手指往上为正,跟「自然滚动」开没开无关。
    public static func deviceDeltaY(_ scrollingDeltaY: CGFloat, invertedFromDevice: Bool) -> CGFloat {
        invertedFromDevice ? -scrollingDeltaY : scrollingDeltaY
    }

    /// 一次滚动折成几档。`precise`:触控板 / 妙控鼠标这类连续滚动;松手后的惯性滚动(`momentum`)不算,不然轻轻
    /// 一划会多跳好几档。中途换方向从零攒起。
    public mutating func steps(scrollDeltaY: CGFloat, precise: Bool, momentum: Bool) -> Int {
        guard !momentum, scrollDeltaY != 0 else { return 0 }
        guard precise else { return scrollDeltaY > 0 ? 1 : -1 }
        return Self.take(&scrollCarry, adding: scrollDeltaY, per: Self.pointsPerStep)
    }

    /// 新的一段手势从零攒起。
    public mutating func reset() {
        scrollCarry = 0
    }

    private static func take(_ carry: inout CGFloat, adding delta: CGFloat, per unit: CGFloat) -> Int {
        if carry != 0, (carry > 0) != (delta > 0) { carry = 0 }
        carry += delta
        let steps = Int(carry / unit)
        carry -= CGFloat(steps) * unit
        return steps
    }
}
