import CoreGraphics

/// 布局反馈里用的几把尺子:按设备像素取整再比、过阈值带回差、按屏幕可用高度封顶。布局回调里量尺寸再改尺寸的地方,
/// 差不到一个像素也算「变了」、或者宽度停在阈值附近,都会让 AppKit 一轮接一轮地重排,超过上限就抛异常。见 15 章决策 105。
public enum LayoutHysteresis {
    /// 向上取整到设备像素(`scale` 是 backingScaleFactor,非正按 1)。
    public static func ceilToPixels(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let s = scale > 0 ? scale : 1
        return (value * s).rounded(.up) / s
    }

    public static func ceilToPixels(_ size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: ceilToPixels(size.width, scale: scale), height: ceilToPixels(size.height, scale: scale))
    }

    /// 两个尺寸差到一个设备像素才算不一样。
    public static func differsByPixel(_ a: CGSize, _ b: CGSize, scale: CGFloat) -> Bool {
        let px = 1 / (scale > 0 ? scale : 1)
        return abs(a.width - b.width) >= px - 0.0001 || abs(a.height - b.height) >= px - 0.0001
    }

    /// 宽度到 `threshold` 才变宽版;已经是宽版时,掉到 `threshold - band` 以下才变回窄版。
    public static func isWide(width: CGFloat, wasWide: Bool, threshold: CGFloat, band: CGFloat = 16) -> Bool {
        wasWide ? width >= threshold - band : width >= threshold
    }
}

/// 设置窗口内容区的最小 / 理想高度:按设计值,但不超过屏幕可用高度减去标题栏和工具栏。设置场景按内容定尺寸,
/// 最小高度比屏幕还高时 SwiftUI 撑、系统压,两边在布局回调里拉扯。见 15 章决策 105。
public enum SettingsWindowHeight {
    public static let designMinimum: CGFloat = 690
    public static let designIdeal: CGFloat = 720
    /// 统一样式工具栏的标题栏高度。
    public static let chrome: CGFloat = 52
    /// 再小的屏也至少这么高,页面靠滚动。
    public static let floor: CGFloat = 400

    public static func minimum(visibleHeight: CGFloat?) -> CGFloat {
        guard let visible = visibleHeight, visible > 0 else { return designMinimum }
        return max(floor, min(designMinimum, visible - chrome))
    }

    public static func ideal(visibleHeight: CGFloat?) -> CGFloat {
        let minimum = minimum(visibleHeight: visibleHeight)
        guard let visible = visibleHeight, visible > 0 else { return designIdeal }
        return max(minimum, min(designIdeal, visible - chrome))
    }
}
