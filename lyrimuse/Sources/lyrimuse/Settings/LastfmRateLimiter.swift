import Foundation

/// 全局限速队列:所有到 Last.fm 的请求(唯一出口 LastfmStatsService.request)都先在
/// 这里排队取"通行证"再真正发出,取代之前散落在各处的局部节流
/// (ensureTitleFormsIndex/refreshDailyCounts 各自的 `Task.sleep(150ms)`)。
///
/// 为什么不用令牌桶:两条历史全量扫描(见 LastfmHistorySync)是持续型负载,需要的是
/// **严格限制瞬时速率**,不是"允许攒桶后突发打光"——对 Last.fm 这种没有公开配额文档、
/// 靠社区实测摸出软限速的接口,突发比持续更容易撞线。用固定间隔调度更直白:每隔
/// `interval` 放行一个请求,跟现有代码里 `Task.sleep(150ms)` 是同一种节流思路,
/// 只是收进一个统一的地方管,不再各写各的、互不知道对方存在。
///
/// 2026-08-25 起因:新账号首次连接 Last.fm 后所有界面都卡、常听加载失败要反复刷新——
/// 根因是 ensureTitleFormsIndex(写法索引全量建索引)和 refreshDailyCounts(热力图全量
/// 同步)各自独立分页扫**同一段历史**,互不协调,同时跑时叠加的请求量轻松顶到甚至超过
/// Last.fm 实测约 5 req/s 的限速。
actor LastfmRateLimiter {
    static let shared = LastfmRateLimiter()

    enum Priority {
        /// 用户当下在等的操作(切 tab、翻页、换歌取次数……)。默认优先级,永远排在
        /// 后台任务前面放行。
        case interactive
        /// 大批量后台任务(历史全量扫描)。不抢占用户操作的带宽——扫描本身是串行请求,
        /// 任意时刻这条队列最多 1 个等待者,只要前台队列偶尔空一拍就轮得到它,
        /// 不存在"永远排不上"的问题。
        case background
    }

    /// 放行间隔:4 req/s,留出安全边际(社区经验 Last.fm 约 5 req/s)。
    private static let interval: UInt64 = 250_000_000

    private var fgWaiters: [CheckedContinuation<Void, Never>] = []
    private var bgWaiters: [CheckedContinuation<Void, Never>] = []
    private var pumpTask: Task<Void, Never>?
    /// 429/限流命中后的额外冷却期限——pump 循环下一次放行前会先睡到这个时刻。
    /// 让**全局**队列一起退避,不是只有那一次请求自己重试、其它请求继续按老节奏撞上去。
    private var cooldownUntil: Date = .distantPast

    /// 排队取一个"可以发请求了"的通行证。
    ///
    /// ⚠️ 正确性关键:预约时间片必须在 acquire 这一次 actor 方法调用的**同步前缀**内
    /// 完成(入队这一步没有 await,天然在 actor 隔离内串行,不会有两个调用者同时读到
    /// 同一个"当前时间片"抢跑)。真正的等待发生在 pump() 循环里,由它一个一个 resume——
    /// 不能写成"调用者各自算出该等多久再自己 sleep",那样算的时候大家看到的都是同一个
    /// "现在没人在等",算出来的等待时长会一样,实际吞吐远超限速。
    func acquire(priority: Priority) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            switch priority {
            case .interactive:
                fgWaiters.append(cont)
                lastInteractiveAcquire = Date()
            case .background: bgWaiters.append(cont)
            }
            startPumpIfNeeded()
        }
    }

    /// 最近一次前台(interactive)排队的时刻。给"前台安静了才跑"的后台批任务用,见
    /// `interactiveIdle(for:)`。
    private var lastInteractiveAcquire: Date = .distantPast

    /// 过去 `seconds` 秒内没有任何前台请求排过队 → true。别名自动发现这类一轮几十个请求的
    /// 后台批任务先问一句再动手(2026-09-03):它们虽然排在后台队列、放行让前台优先,但
    /// 4 路并发的 getinfo 一旦发出去,就在同一条(本机实测很慢的)链路上跟前台请求排队,
    /// 用户正在等的那几个次数/封面会被拖慢——不如等前台歇下来再扫。
    func interactiveIdle(for seconds: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastInteractiveAcquire) >= seconds
    }

    /// request() 探测到 429 / Last.fm error 29(Rate Limit Exceeded)时调用。
    func reportThrottled(cooldown: TimeInterval) {
        let target = Date().addingTimeInterval(cooldown)
        if target > cooldownUntil { cooldownUntil = target }
    }

    private func startPumpIfNeeded() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    /// 单循环、单点放行。每轮:先睡完冷却期(如果有),前台队列优先,取不到前台再取
    /// 后台,两条队列都空就退出循环(下次 acquire 重新拉起,没有常驻空转的任务)。
    private func pump() async {
        while true {
            let now = Date()
            if cooldownUntil > now {
                let wait = cooldownUntil.timeIntervalSince(now)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            if !fgWaiters.isEmpty {
                fgWaiters.removeFirst().resume()
            } else if !bgWaiters.isEmpty {
                bgWaiters.removeFirst().resume()
            } else {
                pumpTask = nil
                return
            }
            try? await Task.sleep(nanoseconds: Self.interval)
        }
    }
}
