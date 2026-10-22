import Foundation

/// 「跟随当前窗口」的换屏判据:焦点屏换了先记下,新的那块稳定 `delay` 之后才跟;已经跟着的那块不再触发。
/// 按「焦点屏换了」触发,不按「宿主不在焦点屏上」:用户把窗口拖到另一块屏,下一拍不会被拽回焦点屏。
/// App 侧 `ActiveScreenFollower` 喂焦点屏、按结论执行。见 04 章决策 63。
public struct ActiveScreenSettle: Sendable {
    /// 焦点屏换了之后等多久才搬:快速切几个 App 时不来回闪。
    public static let delay: TimeInterval = 0.5

    public enum Decision: Equatable, Sendable {
        /// 什么都不做。
        case none
        /// 刚换到一块新屏:过 `delay` 再看一次。
        case wait
        /// 稳定够久了:跟过去(调用方再调 `followed(_:)`)。
        case follow
    }

    /// 上一次跟过去的焦点屏;nil = 还没跟过(刚打开开关 / 刚启动,下一次无论在哪块屏都跟)。
    public private(set) var followedID: String?
    /// 这会儿在不在盯。没在盯时 `observe` 一律不动:关掉跟随、宿主藏起来之前排下的复查到点了也不搬。
    public private(set) var isTracking = false
    private var pending: (id: String, since: Date)?

    public init() {}

    /// 开始盯:之前等着的那块作废。
    public mutating func start() {
        isTracking = true
        pending = nil
    }

    /// 停止盯。
    public mutating func stop() {
        isTracking = false
    }

    /// 看到焦点屏是 `id`(时刻 `now`)。
    public mutating func observe(_ id: String, at now: Date) -> Decision {
        guard isTracking else { return .none }
        guard id != followedID else {
            pending = nil
            return .none
        }
        guard let pending, pending.id == id else {
            self.pending = (id, now)
            return .wait
        }
        return now.timeIntervalSince(pending.since) >= Self.delay ? .follow : .none
    }

    /// 已经跟到 `id` 了。
    public mutating func followed(_ id: String) {
        followedID = id
        pending = nil
    }

    /// 忘掉跟过的屏和等着的那块(刚打开开关)。
    public mutating func reset() {
        followedID = nil
        pending = nil
    }
}
