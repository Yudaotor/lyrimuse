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

    /// 一行至少这么高(字号的倍数):单行、不带译文时字高约 1.175 倍字号,行距 0.98 倍字号(歌词窗口 `lyricLineSpacing`),往小取。
    public static let minimumRowPitchEm = 2.1
    /// 视口外再多带几行:页面一次最多滚 `maxStaggerJumpRows` 行,错开期间刚出视口、还没进视口的行也会露出来。
    public static let reachMarginRows = 4
    /// 一次换句滚动锚最多跳这么多行还走错开;跳得更远(点了远处一句、跳转)整页带动画滚过去(07 章决策 109)。
    public static let maxStaggerJumpRows = 3
    /// 换句前用户自己滚开超过视口高度的这个比例,同样整页带动画滚回来。
    public static let maxStaggerDriftFraction = 0.25

    /// 离滚动锚多少行以内的行跟着错开:视口按最矮的行放得下几行,再加 `reachMarginRows`。还没量出尺寸时全都带上。
    public static func reachRows(viewportHeight: Double, fontSize: Double) -> Int {
        guard viewportHeight > 0, fontSize > 0 else { return Int.max }
        return Int((viewportHeight / (minimumRowPitchEm * fontSize)).rounded(.up)) + reachMarginRows
    }
}
