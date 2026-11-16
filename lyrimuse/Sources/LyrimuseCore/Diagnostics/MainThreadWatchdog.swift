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
/// 状态(定时器、Tracker、上次采样时刻、预期停顿、节流读数)只在 `queue` 上读写。
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
    /// 主线程的 mach 端口,`start()` 时记下;读节流状态用。
    private var mainThread: mach_port_t?
    private let readThrottle: @Sendable (mach_port_t?) -> MainThreadThrottle.Reading
    /// 调试深链造的读数(`simulateThrottle`),非 nil 时代替真实读数。
    private var simulatedThrottle: MainThreadThrottle.Reading?
    /// 最近一次节流读数,日志里带主线程优先级用。
    private var lastThrottleReading: MainThreadThrottle.Reading?

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

    /// 调试深链用:之后的节流读数当作是 `reading`(nil = 照实读)。
    public func simulateThrottle(_ reading: MainThreadThrottle.Reading?) {
        queue.async { [self] in simulatedThrottle = reading }
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
        let sentAt = tracker.pendingSince
        if sentAt != nil { observeThrottle(at: now, probeSentAt: sentAt) }
        if let event = tracker.check(now: now) { handle(event, at: now, probeSentAt: sentAt) }
        guard tracker.shouldProbe(now: now) else { return }
        let provider = windowProvider
        DispatchQueue.main.async { [weak self] in
            let answeredAt = ProcessInfo.processInfo.systemUptime
            let windows = provider.map { provider in MainActor.assumeIsolated { provider() } }
            self?.queue.async {
                guard let self else { return }
                if let windows { self.lastWindows = windows }
                let sentAt = self.tracker.pendingSince
                if let sentAt, answeredAt - sentAt >= self.tracker.stallThreshold {
                    self.observeThrottle(at: answeredAt, probeSentAt: sentAt)
                }
                guard let event = self.tracker.answered(now: answeredAt) else { return }
                self.handle(event, at: answeredAt, probeSentAt: sentAt)
            }
        }
    }

    /// 读一次节流状态,并进在等的那次探测。
    private func observeThrottle(at now: TimeInterval, probeSentAt: TimeInterval?) {
        let reading = simulatedThrottle ?? readThrottle(mainThread)
        lastThrottleReading = reading
        if let event = tracker.observe(throttle: reading.reasons) { handle(event, at: now, probeSentAt: probeSentAt) }
    }

    private func throttleNote(_ throttle: Set<String>) -> String {
        MainThreadThrottle.logNote(throttle, priority: lastThrottleReading?.priority)
    }

    private func handle(_ event: Tracker.Event, at now: TimeInterval, probeSentAt: TimeInterval?) {
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
            logger.notice("main thread: stalled for \(String(format: "%.1f", seconds), privacy: .public)s\(self.throttleNote(throttle), privacy: .public)")
            // 报过 unresponsive 的那次才补时长;没卡满 sampleAfter 的不算一次卡顿。
            if tracker.reportedStill { TelemetryActivity.shared.finishHang(seconds: seconds) }
        case .stillStalled(let seconds, let throttle):
            let detailed = TelemetryActivity.shared.noteHang(hangContext(at: now, throttle: throttle))
            let sample = Self.shouldSample(tookDetailSlot: detailed, lastSampleAt: lastSampleAt, now: now)
            logger.error("main thread: unresponsive for \(Int(seconds), privacy: .public)s\(sample ? ", sampling its stack" : "", privacy: .public)\(self.throttleNote(throttle), privacy: .public)")
            if sample {
                lastSampleAt = now
                takeSample()
            }
        case .throttled(let throttle):
            logger.notice("main thread: still stalled\(self.throttleNote(throttle), privacy: .public)")
            TelemetryActivity.shared.markHangThrottled(throttle.sorted())
        }
    }

    /// 要不要采这一次:占到了当天的遥测概况名额就采(不采那条概况就没有栈),否则离上次采样满 `sampleCooldown` 才采。
    public static func shouldSample(tookDetailSlot: Bool, lastSampleAt: TimeInterval?, now: TimeInterval) -> Bool {
        tookDetailSlot || lastSampleAt.map { now - $0 >= sampleCooldown } ?? true
    }

    /// 卡住这一刻的概况(时长先记成没恢复,恢复时再补)。
    private func hangContext(at now: TimeInterval, throttle: Set<String>) -> TelemetryHang {
        TelemetryHang(sinceLaunch: TelemetryHang.elapsedBucket(seconds: now - (startedAt ?? now)),
                      sinceWake: wake.lastWakeUptime.map { TelemetryHang.elapsedBucket(seconds: now - $0) },
                      windows: TelemetryHang.windowTags(identifiers: lastWindows),
                      thermal: TelemetryHang.thermalTag(ProcessInfo.processInfo.thermalState),
                      throttled: throttle.isEmpty ? nil : throttle.sorted())
    }

    private func takeSample() {
        let path = LogFiles.mainThreadStall.path
        let args = [String(getpid()), String(Self.sampleSeconds), "-mayDie", "-file", path]
        let logger = logger
        let executable = Bundle.main.executableURL?.lastPathComponent ?? "lyrimuse"
        sampleQueue.async {
            let result = ProcessRunner.run("/usr/bin/sample", args, timeout: 30, captureStderr: true)
            if result?.succeeded == true {
                logger.notice("main thread: stall sample written to \(LogFiles.mainThreadStall.lastPathComponent, privacy: .public)")
                if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    TelemetryActivity.shared.attachHangStack(TelemetryHang.mainThreadStack(fromSample: text, executable: executable))
                }
            } else {
                logger.error("main thread: could not sample the stall, status=\(result?.status ?? -1, privacy: .public) timed_out=\(result?.timedOut ?? false, privacy: .public)")
            }
        }
    }
}
