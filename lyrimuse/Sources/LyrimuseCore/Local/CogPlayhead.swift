import ApplicationServices
import Foundation
import os

/// Cog 的位置。系统那份的锚点带小数,自然连播、循环回到开头、跳转都准(差 0.1 秒以内),这几种不准:
///
/// - 暂停恢复:恢复锚点报的是暂停那一刻界面定时器留下的旧值,比真位置少 0.25~0.40 秒(`resumeLagSecs`);
/// - 点播(上一首 / 下一首、停止后再播放):锚点比出声晚 0~0.5 秒,每次不同;
/// - 冷启动:连发两份 0 秒锚点,第一份早 0.24~0.35 秒,第二份晚 0.18~0.29 秒;
/// - 开了工具栏的 Speed 变速时,系统那份照报速率 1,位置却按原曲时间走。
///
/// 所以每来一份新锚点就在后台读它窗口里的 Position 滑块(值是带小数的原曲秒数,界面定时器每 0.2 秒刷一次):每 20 毫秒读一次,
/// 读到值变了,那一刻(前后两次读的中点)的位置 = 新值 + `sliderLagSecs`。在放时每过 `recheckSecs` 再读一次,同一段里两次读数
/// 隔 `rateWindowSecs` 以上就算出速率。滑块读不到(没授辅助功能、`SourceKnockout` 关了 `cog-slider`、窗口里没有)时,恢复锚点补
/// `resumeLagSecs`,别的照锚点走。见 02 章决策 275。
public enum CogPlayhead {
    public static let bundleID = PlaybackPlayer.cog.bundleIdentifier

    /// 系统那份的一个原始锚点。
    public struct Anchor: Equatable, Sendable {
        public var track: String
        public var elapsed: Double
        public var at: Date
        public var playing: Bool

        public init(track: String, elapsed: Double, at: Date, playing: Bool) {
            self.track = track
            self.elapsed = elapsed
            self.at = at
            self.playing = playing
        }
    }

    /// 这一段是怎么来的。
    public enum Kind: String, Sendable {
        case start, resume, seek, paused
    }

    /// 滑块跳格:跳到的值和那一刻。
    public struct Tick: Equatable, Sendable {
        public var value: Double
        public var at: Date

        public init(value: Double, at: Date) {
            self.value = value
            self.at = at
        }
    }

    /// 这块表此刻的状态。在走时位置 = `base` + (现在 − `baseAt`) × `rate`;暂停着报 `pausedPosition`。
    public struct Clock: Equatable, Sendable {
        public var anchor: Anchor
        public var kind: Kind
        public var base: Double
        public var baseAt: Date
        /// 量出来的速率,换歌、跳转都沿用(Speed 是全局设置)。
        public var rate: Double
        /// `base` 是滑块校准过的。
        public var precise: Bool
        public var pausedPosition: Double?
        /// 到这一刻该读滑块;nil = 这一段不读(暂停着、读不了)。
        public var sampleAt: Date?
        /// 量速率的起点:这一段第一次读到的跳格。
        public var rateFrom: Tick?

        public init(anchor: Anchor, kind: Kind, base: Double, baseAt: Date, rate: Double = 1, precise: Bool = false,
                    pausedPosition: Double? = nil, sampleAt: Date? = nil, rateFrom: Tick? = nil) {
            self.anchor = anchor
            self.kind = kind
            self.base = base
            self.baseAt = baseAt
            self.rate = rate
            self.precise = precise
            self.pausedPosition = pausedPosition
            self.sampleAt = sampleAt
            self.rateFrom = rateFrom
        }
    }

    /// 恢复锚点比真位置少的量:实测 0.25~0.40 秒(停 6 / 12 / 18 秒、输出设备停没停都一样),取中间。
    public static let resumeLagSecs: Double = 0.33
    /// 滑块跳格那一刻比出声落后的量(实测约 0.04 秒)。
    public static let sliderLagSecs: Double = 0.04
    /// 在放时隔多久再读一次滑块(搭播放中每 2 秒一拍的轮询)。
    public static let recheckSecs: TimeInterval = 5
    /// 这一段还没校准上(冷启动输出设备还没转起来、滑块没跳)时隔多久再试。
    public static let retrySecs: TimeInterval = 0.5
    /// 同一段里两次跳格至少隔这么久才算速率:单次跳格时刻误差约 ±0.01 秒,隔 4 秒在 0.5% 以内。
    public static let rateWindowSecs: TimeInterval = 4
    /// 偏离 1 倍不到这么多算 1 倍。
    public static let rateDeadband: Double = 0.02
    /// 校准出的位置离按锚点推的(速率按 0.25~4 倍的范围放宽)差出这么多就不采信(读到的不是这一段的滑块)。
    static let calibrationSlackSecs: Double = 2
    /// 同一首、同一个位置的两份锚点时刻差在这以内算同一份(按 bundle id 单问到的那份跟主路径读到的差几毫秒)。
    static let anchorJitterSecs: TimeInterval = 0.05
    /// 同一首在放时来的新锚点离这块表推的位置差在这以内,是 Cog 每放 10 秒重发的那份,不是跳转:校准留着。
    static let republishSlackSecs: Double = 0.3
    /// 恢复锚点跟暂停锚点报的位置差在这以内算同一个位置。
    static let resumeMatchSecs: Double = 0.002
    /// 暂停时没补发暂停锚点(表停在推到报停那一刻的位置)时,恢复锚点报的是暂停前最后一格界面定时器的值:
    /// 比停住的位置小、差在这以内算恢复,不算暂停中跳转。见 02 章决策 275。
    static let resumeStaleSecs: Double = 0.8

    // MARK: 纯函数

    /// 两份锚点是不是同一份。纯函数,selftest 覆盖。
    public static func sameAnchor(_ a: Anchor, _ b: Anchor) -> Bool {
        a.track == b.track && a.elapsed == b.elapsed && a.playing == b.playing
            && abs(a.at.timeIntervalSince(b.at)) <= anchorJitterSecs
    }

    /// 来了一份锚点之后的表。同一份锚点原样交回。纯函数,selftest 覆盖。
    public static func advance(_ clock: Clock?, anchor: Anchor, now: Date) -> Clock {
        if let clock, sameAnchor(clock.anchor, anchor) { return clock }
        let same = clock?.anchor.track == anchor.track ? clock : nil
        let rate = clock?.rate ?? 1
        guard anchor.playing else {
            // 刚报停、锚点还是在放时那一份(暂停锚点晚 0.4~0.5 秒才到):停在这块表推到现在的位置。
            if let same, same.anchor.playing, same.anchor.elapsed == anchor.elapsed,
               abs(same.anchor.at.timeIntervalSince(anchor.at)) <= anchorJitterSecs {
                var out = same
                out.anchor = anchor
                out.kind = .paused
                out.pausedPosition = position(same, now: now)
                out.sampleAt = nil
                return out
            }
            let stopped = anchor.elapsed > 0 ? anchor.elapsed + resumeLagSecs : anchor.elapsed
            return Clock(anchor: anchor, kind: .paused, base: anchor.elapsed, baseAt: anchor.at, rate: rate,
                         precise: false, pausedPosition: stopped)
        }
        if let same, !same.anchor.playing, anchor.elapsed > 0, isResume(anchor.elapsed, after: same) {
            let base = max(anchor.elapsed + resumeLagSecs, same.pausedPosition ?? 0)
            return Clock(anchor: anchor, kind: .resume, base: base, baseAt: anchor.at, rate: rate, sampleAt: now)
        }
        if let same, same.anchor.playing, anchor.elapsed > 1,
           abs(anchor.elapsed - position(same, now: anchor.at)) <= republishSlackSecs {
            var out = same
            out.anchor = anchor
            return out
        }
        let kind: Kind = anchor.elapsed < 0.5 ? .start : .seek
        return Clock(anchor: anchor, kind: kind, base: anchor.elapsed, baseAt: anchor.at, rate: rate, sampleAt: now)
    }

    /// 暂停着的表之后来的在放锚点是不是恢复:报的跟暂停锚点同一个位置,或落在停住的位置往下 `resumeStaleSecs` 以内。
    static func isResume(_ elapsed: Double, after paused: Clock) -> Bool {
        if abs(elapsed - paused.anchor.elapsed) <= resumeMatchSecs { return true }
        guard let stopped = paused.pausedPosition else { return false }
        return elapsed <= stopped + resumeMatchSecs && stopped - elapsed <= resumeStaleSecs
    }

    /// 此刻的位置。纯函数,selftest 覆盖。
    public static func position(_ clock: Clock, now: Date) -> Double {
        guard clock.anchor.playing else { return clock.pausedPosition ?? clock.anchor.elapsed }
        return max(0, clock.base + now.timeIntervalSince(clock.baseAt) * clock.rate)
    }

    /// 这一拍该不该去读滑块。纯函数,selftest 覆盖。
    public static func wantsSlider(_ clock: Clock, now: Date) -> Bool {
        guard clock.anchor.playing, let at = clock.sampleAt else { return false }
        return now >= at
    }

    /// 两次跳格 → 速率(保留两位);隔得不够久、读数倒退或离谱时为 nil。纯函数,selftest 覆盖。
    public static func measuredRate(from first: Tick, to latest: Tick) -> Double? {
        let span = latest.at.timeIntervalSince(first.at)
        guard span >= rateWindowSecs else { return nil }
        let rate = (latest.value - first.value) / span
        guard rate > 0.25, rate < 4 else { return nil }
        return abs(rate - 1) < rateDeadband ? 1 : (rate * 100).rounded() / 100
    }

    /// 滑块在 `tick.at` 跳到 `tick.value` 之后的表。离按锚点推的位置太远的不采信,只排下一次读。纯函数,selftest 覆盖。
    public static func calibrated(_ clock: Clock, tick: Tick) -> Clock {
        var out = clock
        guard clock.anchor.playing else { return out }
        out.sampleAt = tick.at.addingTimeInterval(recheckSecs)
        let since = max(0, tick.at.timeIntervalSince(clock.anchor.at))
        let lowest = clock.anchor.elapsed + since * 0.25 - calibrationSlackSecs
        let highest = clock.anchor.elapsed + since * 4 + calibrationSlackSecs
        guard tick.value >= lowest, tick.value <= highest else { return out }
        if let from = clock.rateFrom {
            if let rate = measuredRate(from: from, to: tick) {
                out.rate = rate
            } else if tick.value < from.value || tick.at.timeIntervalSince(from.at) < 0 {
                out.rateFrom = tick
            }
        } else {
            out.rateFrom = tick
        }
        out.base = tick.value + sliderLagSecs * out.rate
        out.baseAt = tick.at
        out.precise = true
        return out
    }

    /// 读了一轮没见到跳格(滑块不在、还没开始出声):过一会儿再试;找不到滑块的等下一次复读。纯函数,selftest 覆盖。
    public static func missed(_ clock: Clock, found: Bool, now: Date) -> Clock {
        var out = clock
        guard clock.anchor.playing else { return out }
        out.sampleAt = now.addingTimeInterval(found ? retrySecs : recheckSecs)
        return out
    }

    /// 排着的补查到点之后:滑块还在读就隔 `followUp` 再查,读完了就不排。纯函数,selftest 覆盖。
    public static func pendingCheck(_ due: Date?, sampling: Bool, now: Date) -> Date? {
        guard let due, due <= now else { return due }
        return sampling ? now.addingTimeInterval(PositionSlider.followUp) : nil
    }

    /// 开读滑块时排的第一次补查。
    public static func firstCheck(now: Date) -> Date { now.addingTimeInterval(PositionSlider.firstCheck) }

    /// 认 Position 滑块的判据(`PositionSlider` 那份),给 selftest 用。
    public static func isPositionSlider(description: String?, max: Double, duration: Double) -> Bool {
        PositionSlider.isPositionSlider(description: description, max: max, duration: duration)
    }

    // MARK: 轮询线程上用的

    /// 这一拍交给快照的位置和速率;`precise` 时位置是滑块量准的,`dueBy` 是滑块读完该补查一次的时刻。
    public struct Reading: Equatable, Sendable {
        public var position: Double
        public var rate: Double
        public var precise: Bool
        public var dueBy: Date?
    }

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "cog")
    private static let state = OSAllocatedUnfairLock<Clock?>(initialState: nil)
    private static let sampling = OSAllocatedUnfairLock<Bool>(initialState: false)
    private static let calibrationDue = OSAllocatedUnfairLock<Date?>(initialState: nil)
    private static let queue = DispatchQueue(label: "lyrimuse.cog.position-slider", qos: .userInitiated)

    /// 系统那份这一拍的原始锚点 → 这块表给的位置。主路径与焦点回退都走这里。没有锚点为 nil(调用方照用系统那份)。
    public static func reading(track: String, playing: Bool, anchorElapsed: Double?, anchorAt: Date?, duration: Double?,
                               pid: Int?, now: Date = Date()) -> Reading? {
        guard let anchorElapsed, let anchorAt else { return nil }
        let anchor = Anchor(track: track, elapsed: anchorElapsed, at: anchorAt, playing: playing)
        let (clock, changed) = state.withLock { s -> (Clock, Bool) in
            let next = advance(s, anchor: anchor, now: now)
            defer { s = next }
            return (next, next.kind != s?.kind || next.base != s?.base || next.baseAt != s?.baseAt
                        || next.anchor.playing != s?.anchor.playing)
        }
        if changed {
            logger.notice("cog clock: \(clock.kind.rawValue, privacy: .public) anchor \(anchorElapsed, format: .fixed(precision: 3)) → \(position(clock, now: now), format: .fixed(precision: 3)), rate \(clock.rate, format: .fixed(precision: 2)), precise \(clock.precise, privacy: .public)")
        }
        if wantsSlider(clock, now: now) {
            if let pid, let duration, duration > 0, duration < PositionSlider.maxDuration,
               startSampling(anchor: clock.anchor, pid: pid_t(pid), duration: duration) {
                calibrationDue.withLock { due in
                    if due.map({ $0 <= now }) ?? true { due = firstCheck(now: now) }
                }
            } else {
                state.withLock { s in if let c = s, sameAnchor(c.anchor, anchor) { s?.sampleAt = nil } }
            }
        }
        let busy = sampling.withLock { $0 }
        let dueBy = calibrationDue.withLock { due -> Date? in
            due = pendingCheck(due, sampling: busy, now: now)
            return due
        }
        return Reading(position: position(clock, now: now), rate: clock.anchor.playing ? clock.rate : 0,
                       precise: clock.precise && clock.anchor.playing, dueBy: dueBy)
    }

    /// 在后台读一轮滑块,读到跳格就校准同一个锚点的表。读不了(没权限、关掉了这条)返回 false;已经在读返回 true。
    private static func startSampling(anchor: Anchor, pid: pid_t, duration: Double) -> Bool {
        guard !SourceKnockout.isOut(.cogSlider), AXIsProcessTrusted() else { return false }
        guard sampling.withLock({ busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }) else { return true }
        queue.async {
            let read = PositionSlider.nextTick(pid: pid, duration: duration)
            defer { sampling.withLock { $0 = false } }
            let result = state.withLock { s -> (before: Clock, after: Clock)? in
                guard let current = s, sameAnchor(current.anchor, anchor) else { return nil }
                let next = read.tick.map { calibrated(current, tick: $0) } ?? missed(current, found: read.found, now: Date())
                s = next
                return (current, next)
            }
            guard let result else { return }
            if let tick = read.tick {
                logger.notice("cog slider: \(result.before.kind.rawValue, privacy: .public) ticked to \(tick.value, format: .fixed(precision: 3)), base \(result.before.base, format: .fixed(precision: 3)) → \(result.after.base, format: .fixed(precision: 3)), rate \(result.after.rate, format: .fixed(precision: 2)), adopted \(result.after.precise && result.after.baseAt == tick.at, privacy: .public)")
            } else if result.before.kind != .seek || !result.before.precise {
                logger.notice("cog slider: no tick for the \(result.before.kind.rawValue, privacy: .public) anchor, slider found \(read.found, privacy: .public)")
            }
        }
        return true
    }

    /// 回放测试用:清空这块表。
    public static func reset() {
        state.withLock { $0 = nil }
    }

    // MARK: 界面滑块

    /// Cog 窗口里的 Position 滑块(`AXSlider`,描述 Position,值是带小数的原曲秒数,最大值是这首时长)。只读属性,不做任何动作。
    enum PositionSlider {
        /// 读多久等它跳一格(界面定时器每 0.2 秒刷一次)。
        static let window: TimeInterval = 0.6
        /// 开读后隔多久补查一次快照(多数 0.2 秒内就跳到),到点还在读就隔 `followUp` 再查,校准好的位置不用等满 `window` 才上屏。
        static let firstCheck: TimeInterval = 0.3
        static let followUp: TimeInterval = 0.15
        /// 隔多久读一次。
        static let interval: TimeInterval = 0.02
        /// 最大值跟这首时长差这么多以内才认。
        static let durationSlack: Double = 1.5
        /// 时长到这么长不去找(网络流报的时长可能是无限大)。
        static let maxDuration: Double = 1e7
        /// 往下找几层子元素(滑块在工具栏项里,实测在第 3~4 层)。
        static let maxDepth = 5
        /// 跨进程查询超时,App 元素和往下取到的每个元素都设。
        static let axTimeout: Float = 0.25

        /// 等滑块跳一格:跳到的值和那一刻(前后两次读的中点)。`found` = 找到了滑块。阻塞最多 `window`。
        static func nextTick(pid: pid_t, duration: Double) -> (tick: Tick?, found: Bool) {
            let app = MenuBarAX.timed(AXUIElementCreateApplication(pid), timeout: axTimeout)
            guard let slider = find(in: app, duration: duration) else { return (nil, false) }
            guard var last = value(slider) else { return (nil, true) }
            var lastAt = Date()
            let end = lastAt.addingTimeInterval(window)
            while Date() < end {
                Thread.sleep(forTimeInterval: interval)
                guard let v = value(slider) else { return (nil, true) }
                let now = Date()
                if v != last {
                    return (Tick(value: v, at: lastAt.addingTimeInterval(now.timeIntervalSince(lastAt) / 2)), true)
                }
                last = v
                lastAt = now
            }
            return (nil, true)
        }

        /// 各窗口里描述是 Position、最大值对得上时长的那根滑块(菜单栏不进)。
        static func find(in app: AXUIElement, duration: Double) -> AXUIElement? {
            for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute, timeout: axTimeout) {
                if let hit = search(window, duration: duration, depth: 0) { return hit }
            }
            return nil
        }

        private static func search(_ element: AXUIElement, duration: Double, depth: Int) -> AXUIElement? {
            for child in MenuBarAX.children(element, timeout: axTimeout) {
                let role = attribute(child, kAXRoleAttribute) as? String
                if role == kAXSliderRole, isPositionSlider(child, duration: duration) { return child }
                if depth + 1 < maxDepth, role != kAXMenuBarRole,
                   let hit = search(child, duration: duration, depth: depth + 1) { return hit }
            }
            return nil
        }

        static func isPositionSlider(_ element: AXUIElement, duration: Double) -> Bool {
            guard let max = (attribute(element, kAXMaxValueAttribute) as? NSNumber)?.doubleValue else { return false }
            return isPositionSlider(description: attribute(element, kAXDescriptionAttribute) as? String, max: max,
                                    duration: duration)
        }

        /// 工具栏项的名字就是滑块的描述,跟着 Cog 的界面语言(英文、西班牙文两套)。
        static let positionLabels: Set<String> = ["Position", "Posición"]
        static let volumeLabels: Set<String> = ["Volume", "Volumen"]

        /// 最大值对得上时长,描述是 Position;描述认不出时不是音量那根(最大值 100、描述 Volume)也认。纯函数,selftest 覆盖。
        static func isPositionSlider(description: String?, max: Double, duration: Double) -> Bool {
            guard max.isFinite, abs(max - duration) <= durationSlack else { return false }
            if let description, positionLabels.contains(description) { return true }
            return !volumeLabels.contains(description ?? "") && max != 100
        }

        static func value(_ element: AXUIElement) -> Double? {
            guard let v = (attribute(element, kAXValueAttribute) as? NSNumber)?.doubleValue, v.isFinite else { return nil }
            return v
        }

        private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
    }
}
