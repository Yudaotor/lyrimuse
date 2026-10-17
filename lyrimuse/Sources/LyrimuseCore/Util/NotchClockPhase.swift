import Foundation

/// 灵动岛时间类模块(耳朵里的「已播放 / 剩余」、广告倒计时)那条秒表的节拍。
///
/// 相位对齐到**显示的秒数正好要变**的那个墙钟时刻,步长按倍速取 `1/rate`。正计时(已播放)变在位置的整秒上;
/// 倒计时(剩余、广告还剩)显示 `(总长 − 位置) / 1000` 向下取整,变在位置 ≡ 总长 (mod 1000) 上,调用方传 `countdownFromMs`。不能钉在墙钟整秒上:
/// 曲目位置的整秒边界跟墙钟整秒之间差一个由锚点定死的常量相位,钉墙钟的话耳朵里的时间可能整首歌都比
/// 正下方那条迷你进度条(30Hz,同一份 `mmss`)慢 1 秒。
///
/// 只读锚点的低频字段(`fetchedAt` / `progressMs` / `rate`),不读当前时刻:相位在 body 反复重估之间稳定。
/// SwiftUI 的 `PeriodicTimelineSchedule` 由 App 侧(`NotchTimeFormat.clockSchedule`)按这里的结果构造。
public enum NotchClockPhase {
    public struct Tick: Equatable, Sendable {
        /// 第一次跳秒的墙钟时刻。
        public let start: Date
        /// 两次跳秒之间的墙钟秒数。
        public let interval: TimeInterval

        public init(start: Date, interval: TimeInterval) {
            self.start = start
            self.interval = interval
        }
    }

    /// 速率非正(暂停 / 未知)时位置不前进、相位无意义,钉在 `epoch` 上按 1 秒走。
    public static func tick(for anchor: ProgressAnchor, epoch: Date, countdownFromMs total: Int? = nil) -> Tick {
        guard anchor.rate > 0 else { return Tick(start: epoch, interval: 1) }
        let ref = anchor.fetchedAt
        let posAtRef = Double(anchor.extrapolatedPositionMs(now: ref))
        let msToBoundary = 1000 - msSinceBoundary(positionMs: posAtRef, countdownFromMs: total)
        return Tick(start: ref.addingTimeInterval(msToBoundary / 1000 / anchor.rate),
                    interval: 1 / anchor.rate)
    }

    /// 位置走过上一个跳秒边界多少毫秒(0..<1000)。`countdownFromMs` 为 nil 是正计时,给总长是倒计时。
    public static func msSinceBoundary(positionMs: Double, countdownFromMs total: Int?) -> Double {
        let phase = Double((total ?? 0) % 1000)
        let r = (positionMs - phase).truncatingRemainder(dividingBy: 1000)
        return r < 0 ? r + 1000 : r
    }

    /// `m:ss`,负数按 0。耳朵、广告倒计时、迷你进度条的时间行共用这一份。
    public static func mmss(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
