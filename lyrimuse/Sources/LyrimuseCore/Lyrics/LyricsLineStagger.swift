import Foundation

/// 歌词窗口换句时的逐行错开(照 Apple Music 歌词页录屏,07 章决策 94):页面一次滚到位,每一行先被垫回
/// 原处,再各自走一条弹簧回去 —— 从视口顶往下,越靠下起步越晚,看上去是一道从上往下传的波。
public enum LyricsLineStagger {
    /// 每行那条弹簧,跟 SwiftUI `Spring(response:dampingRatio:)` 同一组参数:约 0.15 秒走到一半、0.3 秒走到九成,
    /// 过冲约 0.8%,看不出回弹。阻尼比必须小于 1:`progress` 与 `springSettleMs` 按欠阻尼解算,到 1 就除零。
    public static let springResponse = 0.62
    public static let springDampingRatio = 0.84
    /// 往下每隔这么多倍字号,起步晚 `rowDelayMs`(Apple 带译文的一行约 3 倍字号高,相邻两行起步差约 50ms)。
    public static let rowPitchEm = 3.0
    public static let rowDelayMs = 50.0
    /// 起步最多晚这么多:视口下面还没露出来的行不再往后推。
    public static let maxDelayMs = 400.0

    /// 弹簧阶跃响应,0 → 1;没到起步时刻时 0。
    public static func progress(elapsedMs: Double) -> Double {
        guard elapsedMs > 0 else { return 0 }
        let omega = 2 * Double.pi / springResponse
        let zeta = springDampingRatio
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let t = elapsedMs / 1000
        return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
    }

    /// 离视口顶 `distanceFromTop`(点)的那一行起步晚多少毫秒。视口顶上面的行不等。
    public static func delayMs(distanceFromTop: Double, fontSize: Double) -> Double {
        guard fontSize > 0 else { return 0 }
        return min(maxDelayMs, max(0, distanceFromTop) / (rowPitchEm * fontSize) * rowDelayMs)
    }

    /// 这一行此刻还要垫回多少,占这次滚动量的比例。
    public static func remaining(elapsedMs: Double, delayMs: Double) -> Double {
        1 - progress(elapsedMs: elapsedMs - delayMs)
    }

    /// 弹簧剩余不到千分之五要多久。
    public static var springSettleMs: Double {
        let omega = 2 * Double.pi / springResponse
        let zeta = springDampingRatio
        return log(1 / (0.005 * (1 - zeta * zeta).squareRoot())) / (zeta * omega) * 1000
    }

    /// 一次换句从开始到最晚那一行落定。
    public static var settleMs: Double { maxDelayMs + springSettleMs }
}
