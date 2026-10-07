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
    private var consecutiveTransportFailures = 0
    private var transportBackoffStep = 0

    /// 连续几次传输层失败(超时 / 连不上)才开始退避。
    public static let transportFailureThreshold = 3
    /// 退避时长逐级加长;期间再失败只保证冷却还在,不跳级 —— 同一批在途请求一起超时只算一级。
    public static let transportBackoff: [TimeInterval] = [15, 30, 60, 120, 300]

    public init() {}

    public var isEmpty: Bool { interactive.isEmpty && background.isEmpty }

    public mutating func enqueue(_ id: Int, _ priority: Priority, now: Date) {
        switch priority {
        case .interactive:
            interactive.append(id)
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

    /// 并入跟引擎共享的限流窗口(OutboundCooldownStore);nil = 共享窗口里没有有效期限。
    public mutating func adoptSharedCooldown(_ until: Date?) {
        if let until { extendCooldown(until: until) }
    }

    /// 记一次传输层失败。连续失败达到门槛、且不在冷却期内时整条队列冷却下一级时长,返回这次冷却多少秒;否则返回 nil。
    /// 链路不通时接着发只会一个个等到超时,冷却期过了放一个出去试,还不通就再退一级。
    public mutating func noteTransportFailure(now: Date) -> TimeInterval? {
        consecutiveTransportFailures += 1
        guard consecutiveTransportFailures >= Self.transportFailureThreshold, now >= cooldownUntil else { return nil }
        let seconds = Self.transportBackoff[min(transportBackoffStep, Self.transportBackoff.count - 1)]
        transportBackoffStep += 1
        extendCooldown(until: now.addingTimeInterval(seconds))
        return seconds
    }

    /// 链路层面的失败(超时、连不上、断网、DNS / TLS 失败):这类失败说明现在发了也白发,计入退避。
    /// 取消(换页、离开页面)不算。
    public static func isTransportFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// 拿到了响应(不论状态码):链路是通的,传输失败的计数和退避级数清零。
    public mutating func noteResponse() {
        consecutiveTransportFailures = 0
        transportBackoffStep = 0
    }

    /// 此刻放行前还要等多少秒(不在冷却期为 0)。
    public func waitBeforeRelease(now: Date) -> TimeInterval {
        max(0, cooldownUntil.timeIntervalSince(now))
    }
}
