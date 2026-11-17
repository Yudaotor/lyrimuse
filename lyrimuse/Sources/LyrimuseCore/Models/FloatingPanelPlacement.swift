import CoreGraphics

/// 窗内自绘浮层(歌词窗口的输出面板、「⋯」菜单和它点出的几块面板)的落点:先按锚点给的首选位置摆,
/// 出了窗口就往回推,外框离窗口边至少 `margin`;理想尺寸比窗口还宽时收到窗口里,行内文字自己截断。
/// 纯函数,selftest 覆盖;SwiftUI 那一层是 `LyricsWindowView` 里的 `FloatingPanelLayout`。见 07 章决策 211。
public enum FloatingPanelPlacement {
    /// 浮层外框离窗口边至少这么多。
    public static let margin: CGFloat = 8

    /// 一个方向上能给浮层的最大长度。
    public static func maxLength(container: CGFloat, margin: CGFloat = margin) -> CGFloat {
        max(0, container - 2 * margin)
    }

    /// 一个方向上的起点:首选起点夹进 [lower + margin, upper - margin - length]。浮层比可用长度还长时贴 `lower + margin`。
    public static func origin(preferred: CGFloat, length: CGFloat, lower: CGFloat = 0, upper: CGFloat,
                              margin: CGFloat = margin) -> CGFloat {
        max(lower + margin, min(preferred, upper - margin - length))
    }

    /// 浮层的外框:`size` 是浮层量出来的尺寸(调用方已按 `maxLength` 收过宽),`preferred` 是锚点给的左上角。
    /// `bounds` 是浮层能占的范围,跟 `preferred` 同一个坐标系;歌词窗口里它比摆浮层的内容区多出顶部 safe area
    /// 那一截(标题栏那一行也是窗口里看得见的地方),所以 `minY` 可以是负的。
    public static func frame(preferred: CGPoint, size: CGSize, bounds: CGRect,
                             margin: CGFloat = margin) -> CGRect {
        CGRect(x: origin(preferred: preferred.x, length: size.width, lower: bounds.minX, upper: bounds.maxX, margin: margin),
               y: origin(preferred: preferred.y, length: size.height, lower: bounds.minY, upper: bounds.maxY, margin: margin),
               width: size.width, height: size.height)
    }
}
