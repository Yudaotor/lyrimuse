import CoreGraphics
import Foundation

/// 灵动岛底边进度线(App 侧 `NotchProgressLine`)多久重画一次:线每走半个点重画一次,夹在 0.25～2 秒之间。
public enum NotchProgressLineTiming {
    public static func interval(durationMs: Int, width: CGFloat) -> TimeInterval {
        guard width > 0, durationMs > 0 else { return 2 }
        return min(2, max(0.25, Double(durationMs) / 1000 / Double(width * 2)))
    }
}
