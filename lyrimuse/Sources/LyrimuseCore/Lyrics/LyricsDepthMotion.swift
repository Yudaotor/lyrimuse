import Foundation

/// 歌词窗口各行景深(不透明度 / 模糊)的过渡曲线与取值。窗口那边按显示刷新逐帧来取,不挂 SwiftUI 动画。
public enum LyricsDepthMotion {
    /// 一次过渡走哪条曲线。
    public enum Curve: Equatable, Sendable {
        /// 换句:同 SwiftUI `.smooth(duration: 0.45)`,临界阻尼弹簧。
        case line
        /// 悬停:同 SwiftUI `.easeOut(duration: 0.16)`,三次贝塞尔 (0, 0, 0.58, 1)。
        case hover
    }

    public static let lineResponse = 0.45
    public static let hoverDuration = 0.16
    /// 弹簧离终点不到千分之一就算走完:`(1 + ωt)·e^(−ωt)` 降到 0.001 时 ωt ≈ 9.2334。
    private static let lineSettleOmegaT = 9.2334
    private static var lineOmega: Double { 2 * .pi / lineResponse }

    /// 这条曲线走完要多久(秒)。
    public static func settleSeconds(_ curve: Curve) -> Double {
        switch curve {
        case .line: return lineSettleOmegaT / lineOmega
        case .hover: return hoverDuration
        }
    }

    /// 走了 `elapsed` 秒时走到几成,0…1;走完之后恒为 1。
    public static func progress(_ curve: Curve, elapsed: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        guard elapsed < settleSeconds(curve) else { return 1 }
        switch curve {
        case .line:
            let x = lineOmega * elapsed
            return 1 - (1 + x) * exp(-x)
        case .hover:
            return easeOut(elapsed / hoverDuration)
        }
    }

    /// 三次贝塞尔 (0, 0, 0.58, 1) 在横坐标 `x` 处的纵坐标:先二分出参数,再求纵坐标。
    static func easeOut(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bezier(mid, 0, 0.58) < x { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, 0, 1)
    }

    /// 一个量(不透明度或模糊半径)的过渡:从 `from` 沿 `curve` 走到 `to`;`curve` 为 nil 就停在 `to`。
    public struct Channel: Equatable, Sendable {
        public private(set) var from: Double
        public private(set) var to: Double
        public private(set) var start: Date
        public private(set) var curve: Curve?

        public init(value: Double, now: Date) {
            from = value
            to = value
            start = now
            curve = nil
        }

        public func value(at now: Date) -> Double {
            guard let curve else { return to }
            return from + (to - from) * LyricsDepthMotion.progress(curve, elapsed: now.timeIntervalSince(start))
        }

        public func isMoving(at now: Date) -> Bool {
            guard let curve, from != to else { return false }
            return now.timeIntervalSince(start) < LyricsDepthMotion.settleSeconds(curve)
        }

        /// 走完的时刻;不动时就是开始的时刻。
        public var end: Date {
            guard let curve, from != to else { return start }
            return start.addingTimeInterval(LyricsDepthMotion.settleSeconds(curve))
        }

        /// 换目标:从此刻正画着的值起,沿新曲线走过去;`curve` 为 nil 时直接落到新目标。
        public mutating func retarget(to target: Double, curve: Curve?, now: Date) {
            from = curve == nil ? target : value(at: now)
            to = target
            start = now
            self.curve = curve
        }
    }
}
