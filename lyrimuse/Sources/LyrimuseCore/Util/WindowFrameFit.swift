import CoreGraphics
import Foundation

/// 把存下来的窗口 frame 摆回屏幕时的几何。歌词窗口完整尺寸和迷你尺寸共用这一份 ——
/// 两处各写一遍的话迟早只改一边。
public enum WindowFrameFit {
    /// 夹进那块屏的可见区:先把尺寸压到放得下,再把原点推进来。存的时候屏幕分辨率 / 缩放可能跟
    /// 现在不同,不夹的话窗口会有一部分挂在屏幕外。
    public static func clamp(_ frame: CGRect, into visible: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    /// 迷你窗该用的尺寸:用户拖过的尺寸(宽高都 > 0 才算)优先,否则默认;不小于下限;有屏幕时
    /// 不大于可见区。
    public static func miniSize(saved: CGSize?, defaultSize: CGSize, minimum: CGSize,
                                visible: CGSize?) -> CGSize {
        var size = defaultSize
        if let saved, saved.width > 0, saved.height > 0 { size = saved }
        size.width = max(size.width, minimum.width)
        size.height = max(size.height, minimum.height)
        if let visible {
            size.width = min(size.width, visible.width)
            size.height = min(size.height, visible.height)
        }
        return size
    }
}
