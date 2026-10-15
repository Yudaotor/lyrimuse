import Foundation

/// 确定性伪随机(SplitMix64),给"看着乱、但同一个 seed 每次都一样"的装饰动画用:撒花(`ConfettiField`)、
/// 引导开场的光点(`OnboardingIntro.particles`)。
///
/// **不用 `Double.random(in:)`**:那个走系统 RNG,同一个 seed 也每次不同,于是"这一场长什么样"没法断言。
/// 这里只要"看着乱",不需要密码学强度;SplitMix64 短、无状态依赖、跨平台同结果。
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1。取高 53 位 —— Double 的有效位就这么多,低位给了也是丢。
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }

    mutating func double(_ lower: Double, _ upper: Double) -> Double {
        lower + (upper - lower) * unit()
    }
}
