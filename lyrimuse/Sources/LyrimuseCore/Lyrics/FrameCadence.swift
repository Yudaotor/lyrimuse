import Foundation

/// 逐帧时钟的节流判据:离上一次刷新够不够 `minimumInterval`。按帧的目标时刻比,留 `tolerance` 的余量 ——
/// 帧间隔有抖动,`minimumInterval` 恰好等于帧长(60Hz 屏上的 1/60)时不留余量会隔一帧才刷一次。
public enum FrameCadence {
    public static let tolerance: Double = 0.002

    public static func isDue(sinceLast elapsed: Double, minimumInterval: Double) -> Bool {
        elapsed >= minimumInterval - tolerance
    }
}
