import Foundation
import LyrimuseCore

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
/// 因:新账号首次连接 Last.fm 后所有界面都卡、常听加载失败要反复刷新——
/// 根因是 ensureTitleFormsIndex(写法索引全量建索引)和 refreshDailyCounts(热力图全量
/// 同步)各自独立分页扫**同一段历史**,互不协调,同时跑时叠加的请求量轻松顶到甚至超过
/// Last.fm 实测约 5 req/s 的限速。
actor LastfmRateLimiter {
    static let shared = LastfmRateLimiter()

    /// 排队顺序、冷却期、前台是否安静的判断都在 LyrimuseCore.LastfmRequestGate(selftest 覆盖);
    /// 这里只管续体和 sleep。
    typealias Priority = LastfmRequestGate.Priority

    /// 放行间隔:4 req/s,留出安全边际(社区经验 Last.fm 约 5 req/s)。
    private static let interval: UInt64 = 250_000_000

    private var gate = LastfmRequestGate()
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID = 0
    private var pumpTask: Task<Void, Never>?

    /// 排队取一个"可以发请求了"的通行证。
    ///
    /// 正确性关键:预约时间片必须在 acquire 这一次 actor 方法调用的**同步前缀**内
    /// 完成(入队这一步没有 await,天然在 actor 隔离内串行,不会有两个调用者同时读到
    /// 同一个"当前时间片"抢跑)。真正的等待发生在 pump() 循环里,由它一个一个 resume——
    /// 不能写成"调用者各自算出该等多久再自己 sleep",那样算的时候大家看到的都是同一个
    /// "现在没人在等",算出来的等待时长会一样,实际吞吐远超限速。
    func acquire(priority: Priority) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let id = nextWaiterID
            nextWaiterID += 1
            waiters[id] = cont
            gate.enqueue(id, priority, now: Date())
            startPumpIfNeeded()
        }
    }

    /// request() 探测到 429 / Last.fm error 29(Rate Limit Exceeded)时调用。
    func reportThrottled(cooldown: TimeInterval) {
        gate.extendCooldown(until: Date().addingTimeInterval(cooldown))
    }

    /// request() 碰到传输层失败(超时 / 连不上)时调用;连续几次后整条队列退避,见 LastfmRequestGate.noteTransportFailure。
    /// 返回这次开始冷却的秒数(没开始冷却为 nil),给调用方记日志。
    func reportTransportFailure() -> TimeInterval? {
        gate.noteTransportFailure(now: Date())
    }

    /// request() 拿到任何 HTTP 响应时调用,清零传输失败的退避。
    func reportResponse() {
        gate.noteResponse()
    }

    /// 连续重试仍被限流时整体冷却的时长,同引擎出站闸 429 窗口的默认值。
    static let exhaustedCooldown: TimeInterval = 60

    /// request() 重试用完仍被限流时调用:全局冷却 `exhaustedCooldown`,并写进跟引擎共享的
    /// 限流窗口(`OutboundCooldowns`)——同一个出口 IP,引擎接着打只会被一起限。
    func reportRateLimitExhausted() {
        let until = Date().addingTimeInterval(Self.exhaustedCooldown)
        gate.extendCooldown(until: until)
        OutboundCooldownStore.shared.publish(OutboundCooldowns.lastfmKey, until: until)
    }

    private func startPumpIfNeeded() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    /// 单循环、单点放行。每轮:先睡完冷却期(如果有,含引擎写进共享文件的 Last.fm 窗口),
    /// 前台队列优先,取不到前台再取后台,两条队列都空就退出循环(下次 acquire 重新拉起,没有常驻
    /// 空转的任务)。
    private func pump() async {
        while true {
            let now = Date()
            gate.adoptSharedCooldown(OutboundCooldownStore.shared.activeUntil(OutboundCooldowns.lastfmKey, now: now))
            let wait = gate.waitBeforeRelease(now: now)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                // 睡着的时候冷却可能被推后了(别处报了限流、引擎写了共享窗口):回到开头重新算,
                // 不然醒来照样放一个出去,再撞一次 429。
                continue
            }
            guard let id = gate.popNext() else {
                pumpTask = nil
                return
            }
            waiters.removeValue(forKey: id)?.resume()
            try? await Task.sleep(nanoseconds: Self.interval)
        }
    }
}
