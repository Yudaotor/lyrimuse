import CoreGraphics
import Foundation

/// 圆弧拆成折线时拆几段。灵动岛卡片外形和沿外沿的进度线都自己把圆弧拆成折线再交给 SwiftUI,不用 `addArc` / `addCurve`:
/// 渲染器自己拆曲线拆得粗,2x 屏上弧线的边缘有约 0.1 像素的台阶。见 05 章决策 114。
public enum ArcFlattening {
    /// 每段弦离圆弧最远多少点。
    public static let maxDeviation: CGFloat = 0.005
    public static let maxSegments = 256

    /// 半径 `radius`、扫过 `sweep`(弧度,正负都行)要拆的段数:每段弦的拱高 r(1 − cos(θ/2)) 不超过 `maxDeviation`。
    /// 至少 2 段,至多 `maxSegments`;半径或扫角为 0 时 1 段。
    public static func segments(radius: CGFloat, sweep: CGFloat) -> Int {
        guard radius > 0, sweep != 0 else { return 1 }
        let step = 2 * acos(max(0, 1 - maxDeviation / radius))
        return min(maxSegments, max(2, Int((abs(sweep) / step).rounded(.up))))
    }
}
