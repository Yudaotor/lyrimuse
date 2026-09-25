import Foundation

/// App 侧 Last.fm 限速队列(LastfmRateLimiter)的放行决策:谁先走、放行前要等多久、前台安静了没有。
///
/// 只存等待者的编号,不碰续体和时钟 —— 时间都由调用方传进来,selftest 能逐步驱动。
/// 两次放行之间的固定间隔由 LastfmRateLimiter 的 pump 循环自己 sleep,不在这里。
public struct LastfmRequestGate {
    public enum Priority {
        /// 用户当下在等的操作(切 tab、翻页、换歌取次数……)。永远排在后台任务前面放行。
        case interactive
        /// 大批量后台任务(历史全量扫描)。只要前台队列偶尔空一拍就轮得到它。
        case background
    }

    private var interactive: [Int] = []
    private var background: [Int] = []
    /// 限流命中后的冷却期限:下一次放行前先等到这个时刻,整条队列一起退避。
    public private(set) var cooldownUntil: Date = .distantPast
    private var lastInteractiveAcquire: Date = .distantPast

    public init() {}

    public var isEmpty: Bool { interactive.isEmpty && background.isEmpty }

    public mutating func enqueue(_ id: Int, _ priority: Priority, now: Date) {
        switch priority {
        case .interactive:
            interactive.append(id)
            lastInteractiveAcquire = now
        case .background:
            background.append(id)
        }
    }

    /// 取下一个放行的编号:前台优先,同一优先级按排队顺序。两条队列都空返回 nil。
    public mutating func popNext() -> Int? {
        if !interactive.isEmpty { return interactive.removeFirst() }
        if !background.isEmpty { return background.removeFirst() }
        return nil
    }

    /// 冷却期限只往后推,不往前拉:同时有几处报限流时取最晚的那个。
    public mutating func extendCooldown(until: Date) {
        if until > cooldownUntil { cooldownUntil = until }
    }

    /// 并入跟 collector 共享的限流窗口(OutboundCooldownStore);nil = 共享窗口里没有有效期限。
    public mutating func adoptSharedCooldown(_ until: Date?) {
        if let until { extendCooldown(until: until) }
    }

    /// 此刻放行前还要等多少秒(不在冷却期为 0)。
    public func waitBeforeRelease(now: Date) -> TimeInterval {
        max(0, cooldownUntil.timeIntervalSince(now))
    }

    /// 过去 `seconds` 秒内没有任何前台请求排过队。
    public func interactiveIdle(for seconds: TimeInterval, now: Date) -> Bool {
        now.timeIntervalSince(lastInteractiveAcquire) >= seconds
    }
}
