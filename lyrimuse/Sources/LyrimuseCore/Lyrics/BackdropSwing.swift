import Foundation

/// 歌词窗口背景光斑的往复摆动,按固定步频取样成离散关键帧(07 章决策 172)。
/// 连续插值的整层旋转让窗口服务器每帧都重新合成整扇窗,帧率区间压不住;离散关键帧只在跳档那一刻有变化。
public enum BackdropSwing {
    /// 每秒跳几档。光斑整窗羽化、摆得极慢,一档转动不到 0.1°,看不出跳。
    public static let stepsPerSecond: Double = 10

    /// 一个完整往复(`from` → `to` → `from`,时长 `2 × halfPeriod`)的各档角度,走 smoothstep 缓入缓出;
    /// 首尾相同,`repeatCount = .infinity` 循环时接得上。档数 = 往复时长 × 步频(至少 2),返回档数 + 1 个值。
    public static func angles(from: Double, to: Double, halfPeriod: Double,
                              stepsPerSecond: Double = stepsPerSecond) -> [Double] {
        let steps = max(2, Int((2 * halfPeriod * stepsPerSecond).rounded()))
        return (0...steps).map { k in
            let t = 2 * Double(k) / Double(steps)
            let u = t <= 1 ? t : 2 - t
            return from + (to - from) * u * u * (3 - 2 * u)
        }
    }
}
