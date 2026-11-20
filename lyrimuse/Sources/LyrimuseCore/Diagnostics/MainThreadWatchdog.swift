import Foundation
import os

/// App 主线程卡顿探针。后台队列每 `probeInterval` 秒往主线程投一个空任务:超过 `stallThreshold` 秒才被执行到,恢复时记一行卡了多久;
/// 卡满 `sampleAfter` 秒还没被执行到,先记一行,再用 `/usr/bin/sample` 采一次调用栈写到 `LogFiles.mainThreadStall`
/// (覆盖写)。占到当天遥测概况名额的那几次(每天前 `TelemetryActivity.maxHangDetailsPerDay` 次)每次都采,
/// 别的按 `sampleCooldown` 秒内最多一次(`shouldSample`,14 章决策 195)。播放状态的保活挂在主线程上(PlaybackStatePublisher),
/// 卡满 15 秒引擎就判 App 不可用、进待机。
///
/// 卡满 `sampleAfter` 时给遥测记一条概况(`TelemetryHang`:启动 / 唤醒后多久、开着哪些窗口、温度状态),恢复时补上卡了多久,
/// 采样完补上主线程调用栈。开着哪些窗口在主线程还能动的时候记(每次探测任务被执行到时问 `windowIdentifiers`),
/// 卡住之后再问就问不到了。
///
/// 计时用不含睡眠的系统运行时长(`systemUptime`):睡前投出去的任务醒来才被执行到,不算卡顿。
/// 只在以 Lyrimuse.app 身份运行时启动:selftest 与 `swift run` 起的进程不采样。
///
/// App 有意占住主线程的那一段(锁屏时拆掉关着的大窗口的视图树,`beginExpectedStall` / `endExpectedStall`):这段里投出的
/// 探测任务卡多久都只记一行说明,不进遥测、不采样(`isExpected`)。
///
/// 探测任务过了一拍还没被执行到时(以及卡过 `stallThreshold` 后被执行到的那一刻),看一眼主线程是不是被系统压着
/// (`MainThreadThrottle`:锁屏、优先级落到后台档)。停顿期间任何一次看到就算:日志和遥测概况照记,带上节流标记,
/// 卡住之后才锁屏的也补上(`Tracker.Event.throttled`)。见 14 章决策 202。
///
/// 同样的几个时刻读系统内存压力,概况记停顿期间最紧的一档;每次投探测时记下进程累计的换页次数,报卡顿、恢复时
/// 取差值记进概况(`HangMemory`),恢复时的那个数扣掉 `/usr/bin/sample` 采栈那几秒造成的换页。见 14 章决策 222、231。
///
/// 投探测时同样记下主线程累计的 CPU 时间(`MainThreadCPU`,按 `start()` 记下的主线程端口读),报卡顿时取到那一刻的差值,
/// 恢复时取到主线程执行到探测那一刻的(主线程自己读,跟着回应一起交回来)。见 14 章决策 238。
///
/// 看门狗队列上读的都只问内核(线程优先级、CPU 时间、内存压力、换页次数),锁屏状态读 `ScreenLockState` 的标志位,不同步问
/// WindowServer:WindowServer 卡住时看门狗不能跟着卡。见 14 章决策 231。
///
/// 调试深链 / 启动参数故意造的停顿(`simulateStall`):这段里投出的探测照常判卡顿、记日志、采栈、记概况,概况带 `simulated`,
/// 日志行尾带 ` (simulated)`;遥测活动不计次数,接收端统计不算。停顿区间跟 `expected` 一样按探测投出时刻认。见 14 章决策 240。
///
/// 一次停顿在遥测里记成哪一条,按 `noteHang` 给的回执(`HangLedger`)补时长、补标记、补调用栈,不按「最近一次」补。
///
/// 状态(定时器、Tracker、上次采样时刻、预期停顿、模拟停顿、节流读数、内存读数、卡顿回执)只在 `queue` 上读写。
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()

    /// 2 秒:探针从启动跑到退出,一拍就是后台、主线程各醒一次。卡满 `sampleAfter` 最晚隔一拍报出(第 6 秒),
    /// 仍早于引擎判过期的 15 秒(ops-diagnostics 组守着)。见 15 章决策 63。
    public static let probeInterval: TimeInterval = 2
    public static let stallThreshold: TimeInterval = 3
    public static let sampleAfter: TimeInterval = 5
    public static let sampleCooldown: TimeInterval = 30 * 60
    public static let sampleSeconds = 2

    /// 判卡顿的纯逻辑,selftest 直接覆盖。时刻都是 `systemUptime` 口径的秒数。
    public struct Tracker: Equatable, Sendable {
        public enum Event: Equatable, Sendable {
            /// 探测任务等了 `seconds` 秒还没被主线程执行到(一次卡顿只报一次)。`throttle` 是到这时为止看到的节流原因。
            case stillStalled(seconds: TimeInterval, throttle: Set<String> = [])
            /// 卡过 `stallThreshold` 之后被执行到,一共等了 `seconds` 秒。`throttle` 是这次停顿里看到过的节流原因。
            case recovered(seconds: TimeInterval, throttle: Set<String> = [])
            /// 报过 `stillStalled`、还没恢复的这次停顿又看到了新的节流原因;带的是并起来的全部。
            case throttled(Set<String>)
        }

        public let stallThreshold: TimeInterval
        public let sampleAfter: TimeInterval
        public private(set) var pendingSince: TimeInterval?
        public private(set) var reportedStill = false
        /// 在等的这次探测期间看到过的节流原因(`MainThreadThrottle.reasons` 里的取值)。
        public private(set) var throttle: Set<String> = []

        public init(stallThreshold: TimeInterval = MainThreadWatchdog.stallThreshold,
                    sampleAfter: TimeInterval = MainThreadWatchdog.sampleAfter) {
            self.stallThreshold = stallThreshold
            self.sampleAfter = sampleAfter
        }

        /// 该不该投一个新的探测任务:上一个还没被执行到就不投。投的话记下投出的时刻。
        public mutating func shouldProbe(now: TimeInterval) -> Bool {
            guard pendingSince == nil else { return false }
            pendingSince = now
            reportedStill = false
            throttle = []
            return true
        }

        /// 主线程在 `now` 执行到了探测任务。
        public mutating func answered(now: TimeInterval) -> Event? {
            guard let since = pendingSince else { return nil }
            pendingSince = nil
            let waited = now - since
            return waited >= stallThreshold ? .recovered(seconds: waited, throttle: throttle) : nil
        }

        /// 定时器每次触发时看一眼:探测任务还没被执行到,而且等满了 `sampleAfter`。
        public mutating func check(now: TimeInterval) -> Event? {
            guard let since = pendingSince, !reportedStill else { return nil }
            let waited = now - since
            guard waited >= sampleAfter else { return nil }
            reportedStill = true
            return .stillStalled(seconds: waited, throttle: throttle)
        }

        /// 探测任务还没被执行到时看到的节流原因,并进这一次停顿。已经报过 `stillStalled`、又多出新原因时返回 `.throttled`。
        public mutating func observe(throttle reasons: Set<String>) -> Event? {
            guard pendingSince != nil, !reasons.isSubset(of: throttle) else { return nil }
            throttle.formUnion(reasons)
            return reportedStill ? .throttled(throttle) : nil
        }
    }

    /// App 有意占住主线程的一段:`from` 起、到 `until`(还没结束是 nil)。时刻是 `systemUptime` 口径的秒数。
    public struct ExpectedStall: Equatable, Sendable {
        public var from: TimeInterval
        public var until: TimeInterval?
        public var reason: String

        public init(from: TimeInterval, until: TimeInterval? = nil, reason: String) {
            self.from = from
            self.until = until
            self.reason = reason
        }
    }

    /// 在 `probeSentAt` 投出的探测任务是不是撞上了预期停顿:投出时刻落在这一段里(开始前一拍投出、开始后才被卡住的也算)。
    public static func isExpected(probeSentAt: TimeInterval?, _ stall: ExpectedStall?,
                                  probeInterval: TimeInterval = probeInterval) -> Bool {
        guard let sent = probeSentAt, let stall else { return false }
        return sent >= stall.from - probeInterval && stall.until.map { sent <= $0 } ?? true
    }

    private let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.main-thread-watchdog", qos: .utility)
    private let sampleQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.main-thread-sample", qos: .utility)
    private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "main-thread")
    private let enabled: Bool
    private let interval: TimeInterval
    /// 单测把事件交给它:不记日志、不采样。nil = 正常记日志。
    private let onEvent: (@Sendable (Tracker.Event) -> Void)?
    private var timer: DispatchSourceTimer?
    private var tracker: Tracker
    private var lastSampleAt: TimeInterval?
    private var startedAt: TimeInterval?
    private var wake = WakeDetector()
    /// 最近一次探测任务被执行到时开着的窗口(标识)。
    private var lastWindows: [String] = []
    private var expected: ExpectedStall?
    private var windowProvider: (@MainActor @Sendable () -> [String])?
    /// 主线程的 mach 端口,`start()` 时记下;读节流状态和主线程 CPU 时间用。
    private var mainThread: mach_port_t?
    private let readThrottle: @Sendable (mach_port_t?) -> MainThreadThrottle.Reading
    /// 调试造的停顿(`simulateStall`)的区间,结束后留着:停顿期间投出的那个探测之后才被执行到,还要靠它认出来。
    private var simulated: ExpectedStall?
    /// 调试造的停顿带的节流读数,非 nil 时代替真实读数。
    private var simulatedThrottle: MainThreadThrottle.Reading?
    /// 最近一次节流读数,日志里带主线程优先级用。
    private var lastThrottleReading: MainThreadThrottle.Reading?
    /// 在等的这次探测期间的内存读数:投出时的换页累计、看到过的最紧的内存压力、采栈造成的换页。
    private var memory = HangMemory.Stall()
    /// `memory` 是哪一次探测的(投出时刻);采栈跑完回报换页时按它对上。
    private var memorySentAt: TimeInterval?
    /// 在等的这次探测投出时主线程累计的 CPU 时间(微秒),读不到为 nil。
    private var mainCPUAtStart: UInt64?
    private var hangs = HangLedger(activity: .shared)
    private let answer = ProbeAnswerBox()

    private init() {
        enabled = Bundle.main.bundleIdentifier == LyrimuseIdentity.bundleIdentifier
        interval = Self.probeInterval
        onEvent = nil
        tracker = Tracker()
        readThrottle = { MainThreadThrottle.read(thread: $0) }
    }

    /// 单测用:探测间隔与阈值自己定,节流读数由 `throttle` 给,事件交给 `onEvent`(不记日志、不采样),不看运行身份。
    public init(probeInterval: TimeInterval, stallThreshold: TimeInterval, sampleAfter: TimeInterval,
                throttle: @escaping @Sendable () -> MainThreadThrottle.Reading = { .init(screenLocked: false, priority: nil) },
                onEvent: @escaping @Sendable (Tracker.Event) -> Void) {
        enabled = true
        interval = probeInterval
        self.onEvent = onEvent
        tracker = Tracker(stallThreshold: stallThreshold, sampleAfter: sampleAfter)
        readThrottle = { _ in throttle() }
    }

    /// App 给的「此刻开着哪些窗口」(窗口标识,`TelemetryHang.windowTag` 认),在主线程上调。
    public func setWindowProvider(_ provider: @escaping @MainActor @Sendable () -> [String]) {
        queue.async { [self] in windowProvider = provider }
    }

    /// 在主线程上调。
    public func start() {
        guard enabled else { return }
        if onEvent == nil { ScreenLockState.shared.start() }
        let main = Thread.isMainThread ? pthread_mach_thread_np(pthread_self()) : nil
        queue.async { [self] in
            if let main { mainThread = main }
            guard timer == nil else { return }
            startedAt = ProcessInfo.processInfo.systemUptime
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval,
                            leeway: .milliseconds(max(Int(interval * 200), 1)))
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
    }

    /// 接下来主线程要有意占住一段(在主线程上、动手之前调)。跟 `endExpectedStall` 成对。
    public func beginExpectedStall(_ reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in expected = ExpectedStall(from: now, reason: reason) }
    }

    /// 那一段结束了(在主线程上调)。区间留着:卡住期间投出的那个探测任务这之后才被执行到,还要靠它认出来。
    public func endExpectedStall() {
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in expected?.until = now }
    }

    /// 调试用(在主线程上调):让主线程停 `seconds` 秒,`busy` 时空转占满 CPU,否则睡着;这段里的节流读数当作 `throttle`
    /// (nil = 照实读)。这段里投出的探测报的卡顿标成模拟的;停完、返回之前收起区间和节流读数。
    public func simulateStall(seconds: TimeInterval, busy: Bool = false, throttle: MainThreadThrottle.Reading? = nil) {
        let from = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            simulated = ExpectedStall(from: from, reason: "simulated")
            simulatedThrottle = throttle
        }
        if busy {
            Self.spin(until: from + seconds)
        } else {
            Thread.sleep(forTimeInterval: seconds)
        }
        let until = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            simulated?.until = until
            simulatedThrottle = nil
        }
    }

    /// 在 `sentAt` 投出的探测报的卡顿算不算模拟的(单测读)。
    public func isSimulatedProbe(sentAt: TimeInterval) -> Bool {
        queue.sync { isSimulated(probeSentAt: sentAt) }
    }

    private func isSimulated(probeSentAt: TimeInterval?) -> Bool {
        Self.isExpected(probeSentAt: probeSentAt, simulated, probeInterval: interval)
    }

    private static func spin(until: TimeInterval) {
        var counter: UInt64 = 0
        while ProcessInfo.processInfo.systemUptime < until { counter &+= 1 }
        _ = counter
    }

    /// 停掉探测(单测收尾用)。
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        wake.observe(uptime: now, continuous: WakeDetector.continuousNow)
        // 主线程已经执行到、回应块还没排到这条队列的那次先算掉:不然 4.9 秒执行到的,这一拍会照报一次卡满 5 秒。
        takeAnswer()
        let sentAt = tracker.pendingSince
        if sentAt != nil { observeStall(at: now, probeSentAt: sentAt) }
        if let event = tracker.check(now: now) { handle(event, at: now, probeSentAt: sentAt) }
        guard tracker.shouldProbe(now: now) else { return }
        memory = HangMemory.Stall(pageinsAtStart: HangMemory.readPageins())
        memorySentAt = now
        mainCPUAtStart = MainThreadCPU.readMicroseconds(thread: mainThread)
        hangs.reset()
        let provider = windowProvider
        let answer = answer
        DispatchQueue.main.async { [weak self] in
            let answeredAt = ProcessInfo.processInfo.systemUptime
            let mainCPU = MainThreadCPU.readMicrosecondsOnCurrentThread()
            let windows = provider.map { provider in MainActor.assumeIsolated { provider() } }
            answer.put(ProbeAnswerBox.Answer(sentAt: now, answeredAt: answeredAt, mainCPU: mainCPU, windows: windows))
            self?.queue.async { self?.takeAnswer() }
        }
    }

    /// 处理主线程对探测任务的回应(定时器那一拍和回应块谁先到谁处理,另一个取到空)。
    private func takeAnswer() {
        guard let answered = answer.take() else { return }
        if let windows = answered.windows { lastWindows = windows }
        let sentAt = tracker.pendingSince
        guard let sentAt, sentAt == answered.sentAt else { return }
        let answeredAt = answered.answeredAt
        if answeredAt - sentAt >= tracker.stallThreshold { observeStall(at: answeredAt, probeSentAt: sentAt) }
        guard let event = tracker.answered(now: answeredAt) else { return }
        handle(event, at: answeredAt, probeSentAt: sentAt, mainCPUNow: answered.mainCPU)
    }

    /// 读一次节流状态和内存压力,并进在等的那次探测。
    private func observeStall(at now: TimeInterval, probeSentAt: TimeInterval?) {
        memory.observe(pressure: HangMemory.readPressure())
        let reading = simulatedThrottle ?? readThrottle(mainThread)
        lastThrottleReading = reading
        if let event = tracker.observe(throttle: reading.reasons) { handle(event, at: now, probeSentAt: probeSentAt) }
    }

    private func throttleNote(_ throttle: Set<String>) -> String {
        MainThreadThrottle.logNote(throttle, priority: lastThrottleReading?.priority)
    }

    /// `mainCPUNow`:恢复时主线程执行到探测那一刻自己读的累计 CPU 时间。
    private func handle(_ event: Tracker.Event, at now: TimeInterval, probeSentAt: TimeInterval?, mainCPUNow: UInt64? = nil) {
        if let onEvent {
            onEvent(event)
            return
        }
        if Self.isExpected(probeSentAt: probeSentAt, expected, probeInterval: interval) {
            if case .recovered(let seconds, _) = event {
                let reason = expected?.reason ?? ""
                logger.notice("main thread: busy for \(String(format: "%.1f", seconds), privacy: .public)s on purpose (\(reason, privacy: .public)), not reported")
            }
            return
        }
        switch event {
        case .recovered(let seconds, let throttle):
            let pageins = memory.pageinsExcludingSample(now: HangMemory.readPageins())
            let mainCPU = MainThreadCPU.millisecondsBetween(mainCPUAtStart, mainCPUNow)
            let memoryNote = HangMemory.logNote(pressure: memory.pressure, pageins: pageins) + MainThreadCPU.logNote(milliseconds: mainCPU)
                + Self.simulatedLogNote(isSimulated(probeSentAt: probeSentAt))
            logger.notice("main thread: stalled for \(String(format: "%.1f", seconds), privacy: .public)s\(self.throttleNote(throttle), privacy: .public)\(memoryNote, privacy: .public)")
            // 报过 unresponsive 的那次才补时长;没卡满 sampleAfter 的不算一次卡顿。
            if tracker.reportedStill {
                hangs.recovered(seconds: seconds, memoryPressure: memory.pressure, pageins: pageins, mainCPUMilliseconds: mainCPU)
            }
        case .stillStalled(let seconds, let throttle):
            let context = hangContext(at: now, throttle: throttle, probeSentAt: probeSentAt)
            let hang = hangs.stalled(context)
            let sample = Self.shouldSample(tookDetailSlot: hang?.detailed == true, lastSampleAt: lastSampleAt, now: now)
            let memoryNote = HangMemory.logNote(pressure: context.memoryPressure, pageins: context.pageins)
                + MainThreadCPU.logNote(milliseconds: context.mainCPUMilliseconds) + Self.simulatedLogNote(context.simulated == true)
            logger.error("main thread: unresponsive for \(Int(seconds), privacy: .public)s\(sample ? ", sampling its stack" : "", privacy: .public)\(self.throttleNote(throttle), privacy: .public)\(memoryNote, privacy: .public)")
            if sample {
                lastSampleAt = now
                takeSample(for: hang)
            }
        case .throttled(let throttle):
            logger.notice("main thread: still stalled\(self.throttleNote(throttle), privacy: .public)")
            hangs.throttled(throttle.sorted())
        }
    }

    /// 要不要采这一次:占到了当天的遥测概况名额就采(不采那条概况就没有栈),否则离上次采样满 `sampleCooldown` 才采。
    public static func shouldSample(tookDetailSlot: Bool, lastSampleAt: TimeInterval?, now: TimeInterval) -> Bool {
        tookDetailSlot || lastSampleAt.map { now - $0 >= sampleCooldown } ?? true
    }

    /// 日志行尾的模拟停顿说明。
    public static func simulatedLogNote(_ simulated: Bool) -> String {
        simulated ? " (simulated)" : ""
    }

    /// 卡住这一刻的概况(时长先记成没恢复,恢复时再补)。
    private func hangContext(at now: TimeInterval, throttle: Set<String>, probeSentAt: TimeInterval?) -> TelemetryHang {
        TelemetryHang(sinceLaunch: TelemetryHang.elapsedBucket(seconds: now - (startedAt ?? now)),
                      sinceWake: wake.lastWakeUptime.map { TelemetryHang.elapsedBucket(seconds: now - $0) },
                      windows: TelemetryHang.windowTags(identifiers: lastWindows),
                      thermal: TelemetryHang.thermalTag(ProcessInfo.processInfo.thermalState),
                      throttled: throttle.isEmpty ? nil : throttle.sorted(),
                      memoryPressure: memory.pressure, pageins: memory.pageins(now: HangMemory.readPageins()),
                      mainCPUMilliseconds: MainThreadCPU.millisecondsBetween(mainCPUAtStart, MainThreadCPU.readMicroseconds(thread: mainThread)),
                      appVersion: TelemetryHang.currentAppVersion,
                      simulated: isSimulated(probeSentAt: probeSentAt) ? true : nil)
    }

    /// 采一次主线程调用栈;`hang` 是报卡顿时拿到的回执,栈补到那一条(遥测没在记时为 nil,只写本机日志)。
    /// 采栈前后各读一次换页累计,回报给这次停顿,恢复时从整段里扣掉(`HangMemory.Stall.pageinsExcludingSample`)。
    private func takeSample(for hang: TelemetryActivity.HangTicket?) {
        let path = LogFiles.mainThreadStall.path
        let args = [String(getpid()), String(Self.sampleSeconds), "-mayDie", "-file", path]
        let logger = logger
        let executable = Bundle.main.executableURL?.lastPathComponent ?? "lyrimuse"
        let sentAt = memorySentAt
        memory.sampleStarted()
        sampleQueue.async { [weak self] in
            let pageinsBefore = HangMemory.readPageins()
            let result = ProcessRunner.run("/usr/bin/sample", args, timeout: 30, captureStderr: true)
            let samplePageins = HangMemory.pageinsBetween(pageinsBefore, HangMemory.readPageins())
            self?.queue.async { self?.sampleFinished(probeSentAt: sentAt, pageins: samplePageins) }
            if result?.succeeded == true {
                logger.notice("main thread: stall sample written to \(LogFiles.mainThreadStall.lastPathComponent, privacy: .public)")
                if let hang, let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    TelemetryActivity.shared.attachHangStack(TelemetryHang.mainThreadStack(fromSample: text, executable: executable), to: hang)
                }
            } else {
                logger.error("main thread: could not sample the stall, status=\(result?.status ?? -1, privacy: .public) timed_out=\(result?.timedOut ?? false, privacy: .public)")
            }
        }
    }

    /// 采栈跑完了:还是同一次停顿的话,记下采栈期间的换页。
    private func sampleFinished(probeSentAt: TimeInterval?, pageins: Int?) {
        guard probeSentAt != nil, probeSentAt == memorySentAt else { return }
        memory.sampleFinished(pageins: pageins)
    }
}

/// 看门狗这边一次停顿的遥测记账:报卡顿时 `noteHang` 给的回执,恢复时补时长、后来看到被压着补标记,都按它补。
/// 遥测关着时回执为 nil,这次停顿什么都不补,不会补到上一次卡顿那一条上。只在看门狗队列上用。
public struct HangLedger {
    public let activity: TelemetryActivity
    public private(set) var current: TelemetryActivity.HangTicket?

    public init(activity: TelemetryActivity) {
        self.activity = activity
    }

    /// 报卡顿;返回的回执给采栈用(栈补到这一次)。
    public mutating func stalled(_ context: TelemetryHang, now: Date = Date()) -> TelemetryActivity.HangTicket? {
        current = activity.noteHang(context, now: now)
        return current
    }

    public mutating func recovered(seconds: TimeInterval, memoryPressure: String?, pageins: Int?, mainCPUMilliseconds: Int? = nil) {
        if let current {
            activity.finishHang(current, seconds: seconds, memoryPressure: memoryPressure, pageins: pageins,
                                mainCPUMilliseconds: mainCPUMilliseconds)
        }
        current = nil
    }

    public func throttled(_ reasons: [String]) {
        if let current { activity.markHangThrottled(reasons, for: current) }
    }

    /// 投新的探测时调:上一次停顿的回执不再补。
    public mutating func reset() {
        current = nil
    }
}

/// 主线程执行到探测任务的那一刻:主线程写,看门狗队列取(定时器那一拍和回应块谁先到谁取)。
private final class ProbeAnswerBox: @unchecked Sendable {
    struct Answer {
        let sentAt: TimeInterval
        let answeredAt: TimeInterval
        /// 主线程执行到探测时自己读的累计 CPU 时间(微秒)。
        let mainCPU: UInt64?
        let windows: [String]?
    }

    private let lock = NSLock()
    private var answer: Answer?

    func put(_ answer: Answer) {
        lock.withLock { self.answer = answer }
    }

    func take() -> Answer? {
        lock.withLock {
            defer { answer = nil }
            return answer
        }
    }
}
