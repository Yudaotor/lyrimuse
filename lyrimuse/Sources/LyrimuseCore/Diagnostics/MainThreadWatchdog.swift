import Foundation
import os

/// App 主线程卡顿探针。后台队列每秒往主线程投一个空任务:超过 `stallThreshold` 秒才被执行到,恢复时记一行卡了多久;
/// 卡满 `sampleAfter` 秒还没被执行到,先记一行,再用 `/usr/bin/sample` 采一次调用栈写到 `LogFiles.mainThreadStall`
/// (覆盖写,`sampleCooldown` 秒内最多采一次)。播放状态的保活挂在主线程上(PlaybackStatePublisher),
/// 卡满 15 秒引擎就判 App 不可用、进待机。
///
/// 计时用不含睡眠的系统运行时长(`systemUptime`):睡前投出去的任务醒来才被执行到,不算卡顿。
/// 只在以 Lyrimuse.app 身份运行时启动:selftest 与 `swift run` 起的进程不采样。
///
/// 状态(定时器、Tracker、上次采样时刻)只在 `queue` 上读写。
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()

    public static let probeInterval: TimeInterval = 1
    public static let stallThreshold: TimeInterval = 3
    public static let sampleAfter: TimeInterval = 5
    public static let sampleCooldown: TimeInterval = 30 * 60
    public static let sampleSeconds = 2

    /// 判卡顿的纯逻辑,selftest 直接覆盖。时刻都是 `systemUptime` 口径的秒数。
    public struct Tracker: Equatable, Sendable {
        public enum Event: Equatable, Sendable {
            /// 探测任务等了 `seconds` 秒还没被主线程执行到(一次卡顿只报一次)。
            case stillStalled(seconds: TimeInterval)
            /// 卡过 `stallThreshold` 之后被执行到,一共等了 `seconds` 秒。
            case recovered(seconds: TimeInterval)
        }

        public let stallThreshold: TimeInterval
        public let sampleAfter: TimeInterval
        public private(set) var pendingSince: TimeInterval?
        public private(set) var reportedStill = false

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
            return true
        }

        /// 主线程在 `now` 执行到了探测任务。
        public mutating func answered(now: TimeInterval) -> Event? {
            guard let since = pendingSince else { return nil }
            pendingSince = nil
            let waited = now - since
            return waited >= stallThreshold ? .recovered(seconds: waited) : nil
        }

        /// 定时器每次触发时看一眼:探测任务还没被执行到,而且等满了 `sampleAfter`。
        public mutating func check(now: TimeInterval) -> Event? {
            guard let since = pendingSince, !reportedStill else { return nil }
            let waited = now - since
            guard waited >= sampleAfter else { return nil }
            reportedStill = true
            return .stillStalled(seconds: waited)
        }
    }

    private let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.main-thread-watchdog", qos: .utility)
    private let sampleQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.main-thread-sample", qos: .utility)
    private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "main-thread")
    private let enabled: Bool
    private let interval: TimeInterval
    /// 单测把事件交给它:不记日志、不采样。nil = 正常记日志。
    private let onEvent: (@Sendable (Tracker.Event) -> Void)?
    private var timer: DispatchSourceTimer?
    private var tracker: Tracker
    private var lastSampleAt: TimeInterval?

    private init() {
        enabled = Bundle.main.bundleIdentifier == LyrimuseIdentity.bundleIdentifier
        interval = Self.probeInterval
        onEvent = nil
        tracker = Tracker()
    }

    /// 单测用:探测间隔与阈值自己定,事件交给 `onEvent`(不记日志、不采样),不看运行身份。
    public init(probeInterval: TimeInterval, stallThreshold: TimeInterval, sampleAfter: TimeInterval,
                onEvent: @escaping @Sendable (Tracker.Event) -> Void) {
        enabled = true
        interval = probeInterval
        self.onEvent = onEvent
        tracker = Tracker(stallThreshold: stallThreshold, sampleAfter: sampleAfter)
    }

    public func start() {
        guard enabled else { return }
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval,
                            leeway: .milliseconds(max(Int(interval * 200), 1)))
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
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
        if let event = tracker.check(now: now) { handle(event, at: now) }
        guard tracker.shouldProbe(now: now) else { return }
        DispatchQueue.main.async { [weak self] in
            let answeredAt = ProcessInfo.processInfo.systemUptime
            self?.queue.async {
                guard let self, let event = self.tracker.answered(now: answeredAt) else { return }
                self.handle(event, at: answeredAt)
            }
        }
    }

    private func handle(_ event: Tracker.Event, at now: TimeInterval) {
        if let onEvent {
            onEvent(event)
            return
        }
        switch event {
        case .recovered(let seconds):
            logger.notice("main thread: stalled for \(String(format: "%.1f", seconds), privacy: .public)s")
        case .stillStalled(let seconds):
            let sample = lastSampleAt.map { now - $0 >= Self.sampleCooldown } ?? true
            logger.error("main thread: unresponsive for \(Int(seconds), privacy: .public)s\(sample ? ", sampling its stack" : "", privacy: .public)")
            if sample {
                lastSampleAt = now
                takeSample()
            }
        }
    }

    private func takeSample() {
        let path = LogFiles.mainThreadStall.path
        let args = [String(getpid()), String(Self.sampleSeconds), "-mayDie", "-file", path]
        let logger = logger
        sampleQueue.async {
            let result = ProcessRunner.run("/usr/bin/sample", args, timeout: 30, captureStderr: true)
            if result?.succeeded == true {
                logger.notice("main thread: stall sample written to \(LogFiles.mainThreadStall.lastPathComponent, privacy: .public)")
            } else {
                logger.error("main thread: could not sample the stall, status=\(result?.status ?? -1, privacy: .public) timed_out=\(result?.timedOut ?? false, privacy: .public)")
            }
        }
    }
}
