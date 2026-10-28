import ApplicationServices
import Foundation
import os

/// Pine Player 的位置。系统那份的锚点只到整秒(下取整,真位置在报的值和它 + 1 之间),这里换成准的:
///
/// - 开播的 0 秒锚点连发两份:第一份比真起播早 0.5~1.9 秒,第二份早约 0.05 秒(`startAnchorEarlySecs`)。第一份到了先按
///   「在加载」停在 0(`holdUntil`),第二份一到从它起算;`startHoldSecs` 内没等到第二份就按第一份走。循环回到这一首开头时
///   第一份报的是 1 秒、0.7 秒后才是 0 秒那份:0 秒那份前面刚有这一首不到 `restartFirstAnchorMaxSecs` 的锚点,就当第二份。
/// - 跳转、恢复的锚点是取整的。界面进度条每过一个整秒跳一格,跳格时刻跟出声差一个这一段固定的量(`sliderBias`,进度条超前为正):
///   开播那一段约 0.24 秒,跳转之后 0~0.12 秒。开播那一段的拿准的开播锚点当场量(量出来不在合理范围里,是那两份开播锚点都不准;
///   开播锚点只有一份的(没等到第二份、循环回到开头)也一样:反过来按 `startSliderBias` 从进度条推开播位置),跳转之后按 `seekSliderBias`,中途才看到的按
///   `joinedSliderBias`,暂停恢复沿用这一段的。新锚点之后读进度条等它跳一格(`ProgressBar.nextTick`),位置补成「格值 − 这段的差」。
/// - 进度条读不到(没授「辅助功能」权限、主窗口关了、`SourceKnockout` 关掉了这条)时:恢复按暂停前的位置接上(暂停锚点的时刻比真
///   停下晚 0.1~0.5 秒,所以夹进它报的那一秒里),跳转和中途看到的补半秒(`flooredMidpointSecs`)。
///
/// 见 02 章决策 155。
public enum PinePlayhead {
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
        case start, resume, seek, joined, paused
    }

    /// 这块表此刻的状态。在走时位置 = `base` + (现在 − `baseAt`);暂停着时 `base` / `baseAt` 是暂停前那一段的,报 `pausedPosition`。
    public struct Clock: Equatable, Sendable {
        public var anchor: Anchor
        public var kind: Kind
        public var base: Double
        public var baseAt: Date
        /// `base` 是量准的(开播锚点、进度条校准过、或从量准的那段接上),不是补的半秒。
        public var precise: Bool
        /// `base` / `baseAt` 是一段在走的表(暂停着时是暂停前那段);暂停着才看到、暂停着跳转的为 false,不能往后推。
        public var running: Bool
        /// 这一段进度条比出声超前多少秒;nil = 还没有(开播那一段等着量,中途看到的按 `joinedSliderBias`)。
        public var sliderBias: Double?
        /// 开播第一份锚点:到这一刻之前停在 0、报在加载(循环回到开头的那份设成锚点时刻,不停)。不为 nil = 这一段的开播锚点
        /// 只有一份(没等到第二份),进度条校准时按 `startSliderBias` 补位置。
        public var holdUntil: Date?
        public var pausedPosition: Double?
        /// 这个锚点已经读过进度条(或者读不了)。
        public var sliderDone: Bool

        public init(anchor: Anchor, kind: Kind, base: Double, baseAt: Date, precise: Bool, running: Bool = true,
                    sliderBias: Double? = nil, holdUntil: Date? = nil, pausedPosition: Double? = nil, sliderDone: Bool = false) {
            self.anchor = anchor
            self.kind = kind
            self.base = base
            self.baseAt = baseAt
            self.precise = precise
            self.running = running
            self.sliderBias = sliderBias
            self.holdUntil = holdUntil
            self.pausedPosition = pausedPosition
            self.sliderDone = sliderDone
        }
    }

    public static let startAnchorEarlySecs: Double = 0.05
    /// 开播第一份锚点之后最多等第二份这么久。实测两份隔 0.48~1.92 秒。
    public static let startHoldSecs: TimeInterval = 2.2
    /// 循环回到开头时第一份锚点报的位置最多这么大(实测 1.0)。
    static let restartFirstAnchorMaxSecs: Double = 1.5
    /// 上一段推到这份锚点时离结尾不到这么多秒,回到开头算循环(不是重新开播)。
    static let loopEndSlackSecs: Double = 1.5
    /// 上一段推出来超过结尾这么多就不是刚放完的(没收到暂停锚点就断了的旧表),不认循环。
    static let loopOverrunSecs: Double = 5
    /// 取整的锚点不知道小数时补的量(真位置在报的值和它 + 1 之间)。
    public static let flooredMidpointSecs: Double = 0.5
    /// 取整的锚点夹位置时的上沿(报的值 + 它)。
    static let flooredSpanSecs: Double = 0.999
    /// 跳转之后进度条比出声超前的量:每次跳转不一样,实测 0~0.12 秒,取中间。
    public static let seekSliderBias: Double = 0.05
    /// 中途才看到、这一段从哪来不知道时的估计:开播那一段的 0.24 和跳转之后的 0.05 取中间。
    public static let joinedSliderBias: Double = 0.14
    /// 开播那一段量出的差在这个范围内才采信(实测 0.21~0.25)。
    static let startSliderBiasRange: ClosedRange<Double> = -0.1...0.6
    /// 开播那一段进度条超前的典型量:量出来不在合理范围里时按它从进度条推开播位置。
    public static let startSliderBias: Double = 0.23
    /// 按进度条推出的开播位置离开播锚点差出这么多就不采信(读到的不是这一段的进度条)。
    static let startCorrectionMaxSecs: Double = 2.5
    /// 同一首、同一个位置的两份锚点时刻差在这以内算同一份(按 bundle id 单问到的那份跟主路径读到的,时刻差几位小数)。
    static let anchorJitterSecs: TimeInterval = 0.05
    /// 校准后的 `base` 离报的整秒差出这么多就不采信(读到的不是这一段的进度条)。
    static let calibrationSlackSecs: Double = 0.25
    /// 暂停锚点推出的位置离它报的整秒差出这么多,就是暂停着跳转了,不是这一段停下的位置。
    static let pauseMatchSlackSecs: Double = 0.6

    // MARK: 纯函数

    /// 两份锚点是不是同一份:同一首、同一个位置、同样在走或停着,时刻差在 `anchorJitterSecs` 以内。纯函数,selftest 覆盖。
    public static func sameAnchor(_ a: Anchor, _ b: Anchor) -> Bool {
        a.track == b.track && a.elapsed == b.elapsed && a.playing == b.playing
            && abs(a.at.timeIntervalSince(b.at)) <= anchorJitterSecs
    }

    /// 来了一份锚点之后的表。同一份锚点(`sameAnchor`)原样交回。`duration` 用来认循环回到开头。纯函数,selftest 覆盖。
    public static func advance(_ clock: Clock?, anchor: Anchor, now: Date, duration: Double? = nil) -> Clock {
        if let clock, sameAnchor(clock.anchor, anchor) { return clock }
        let same = clock?.anchor.track == anchor.track ? clock : nil
        guard anchor.playing else { return paused(same, anchor: anchor, now: now) }
        // 第一秒里停下、再恢复:恢复报的是下取整的 0,按恢复接着走,别当成重新开播停在 0。
        if anchor.elapsed <= 0, let same, !same.anchor.playing, same.running, let stopped = same.pausedPosition,
           stopped > 0, stopped < 1 {
            return Clock(anchor: anchor, kind: .resume, base: stopped, baseAt: anchor.at, precise: same.precise,
                         sliderBias: same.sliderBias)
        }
        if anchor.elapsed <= 0 {
            let second = same.map { previous in
                let recent = anchor.at > previous.anchor.at && anchor.at.timeIntervalSince(previous.anchor.at) <= startHoldSecs + 0.5
                let restart = previous.anchor.playing && previous.anchor.elapsed > 0
                    && previous.anchor.elapsed <= restartFirstAnchorMaxSecs
                return recent && ((previous.kind == .start && previous.holdUntil != nil) || restart)
            } ?? false
            let looped = same.map { nearEnd($0, at: anchor.at, duration: duration) } ?? false
            let hold: Date? = second ? nil : looped ? anchor.at : anchor.at.addingTimeInterval(startHoldSecs)
            return Clock(anchor: anchor, kind: .start, base: -startAnchorEarlySecs, baseAt: anchor.at, precise: true, holdUntil: hold)
        }
        if let same, !same.anchor.playing, let stopped = same.pausedPosition,
           stopped.rounded(.down) == anchor.elapsed.rounded(.down) {
            return Clock(anchor: anchor, kind: .resume, base: stopped, baseAt: anchor.at, precise: same.precise,
                         sliderBias: same.sliderBias)
        }
        let kind: Kind = same == nil ? .joined : .seek
        let looped = anchor.elapsed <= restartFirstAnchorMaxSecs && (same.map { nearEnd($0, at: anchor.at, duration: duration) } ?? false)
        return Clock(anchor: anchor, kind: kind, base: anchor.elapsed + flooredMidpointSecs, baseAt: anchor.at, precise: false,
                     sliderBias: kind == .seek ? (looped ? startSliderBias : seekSliderBias) : nil)
    }

    /// 上一段在走、推到 `at` 时离结尾不到 `loopEndSlackSecs`(也没超过结尾 `loopOverrunSecs`):这时回到开头的锚点是循环回来的,进度条按开播那段超前。纯函数,selftest 覆盖。
    static func nearEnd(_ clock: Clock, at: Date, duration: Double?) -> Bool {
        guard let duration, duration > 0, clock.anchor.playing, clock.running else { return false }
        let pushed = position(clock, now: at).position
        return pushed >= duration - loopEndSlackSecs && pushed <= duration + loopOverrunSecs
    }

    /// 暂停锚点:停下的位置按上一段的表推到暂停锚点那一刻,夹进它报的那一秒;它跟上一段在走的锚点一模一样(停下之前先报的那份,
    /// 位置还没更新)时推到现在、不夹。上一份锚点也是停着的,用停下时记的位置,不往后推。推出来离报的值太远是暂停着跳转了
    /// (停在 0 秒的也一样,暂停着重开同一个文件先报这一份),补半秒。上一段不是在走的表时不推。
    static func paused(_ same: Clock?, anchor: Anchor, now: Date) -> Clock {
        let floored = anchor.elapsed >= 1
        var out = Clock(anchor: anchor, kind: .paused, base: anchor.elapsed, baseAt: anchor.at, precise: false, running: false,
                        pausedPosition: anchor.elapsed + (floored ? flooredMidpointSecs : 0), sliderDone: true)
        guard let same, same.running else {
            if same != nil { out.sliderBias = seekSliderBias }
            return out
        }
        let carried = same.anchor.playing && anchor.elapsed == same.anchor.elapsed
            && abs(anchor.at.timeIntervalSince(same.anchor.at)) <= anchorJitterSecs
        let at = carried ? now : anchor.at
        var estimate = same.anchor.playing ? max(0, same.base + at.timeIntervalSince(same.baseAt)) : (same.pausedPosition ?? same.base)
        if let hold = same.holdUntil, at < hold { estimate = 0 }
        let matches = carried
            || (estimate >= anchor.elapsed - pauseMatchSlackSecs && estimate <= anchor.elapsed + 1 + pauseMatchSlackSecs)
        guard matches else {
            out.sliderBias = seekSliderBias
            return out
        }
        out.base = same.base
        out.baseAt = same.baseAt
        out.precise = same.precise
        out.running = true
        out.sliderBias = same.sliderBias
        out.pausedPosition = carried || !floored ? estimate : min(max(estimate, anchor.elapsed), anchor.elapsed + flooredSpanSecs)
        return out
    }

    /// 此刻的位置,和是不是在加载(开播第一份锚点停在 0 那几拍)。纯函数,selftest 覆盖。
    public static func position(_ clock: Clock, now: Date) -> (position: Double, waiting: Bool) {
        guard clock.anchor.playing else { return (clock.pausedPosition ?? clock.anchor.elapsed, false) }
        if let hold = clock.holdUntil, now < hold { return (0, true) }
        return (max(0, clock.base + now.timeIntervalSince(clock.baseAt)), false)
    }

    /// 这一拍该不该去读进度条:在走、还没读过、没停在开播第一份上。纯函数,selftest 覆盖。
    public static func wantsProgressBar(_ clock: Clock, now: Date) -> Bool {
        guard clock.anchor.playing, !clock.sliderDone else { return false }
        return clock.holdUntil.map { now >= $0 } ?? true
    }

    /// 进度条在 `at` 跳到 `value` 之后的表:开播那一段(两份开播锚点都到了)量出这一段的差,量出来不在合理范围里、或开播锚点
    /// 只有一份时按 `startSliderBias` 把开播位置补成进度条推出来的;别的段把位置补成「格值 − 这一段的差」。补出的位置不在合理范围里的不采信,只记下读过。纯函数,selftest 覆盖。
    public static func calibrated(_ clock: Clock, value: Int, at: Date) -> Clock {
        var out = clock
        out.sliderDone = true
        guard clock.anchor.playing else { return out }
        if clock.kind == .start {
            let bias = Double(value) - position(clock, now: at).position
            if clock.holdUntil == nil, startSliderBiasRange.contains(bias) {
                out.sliderBias = bias
                return out
            }
            let base = Double(value) - startSliderBias - at.timeIntervalSince(clock.baseAt)
            guard abs(base - clock.base) <= startCorrectionMaxSecs else { return out }
            out.base = base
            out.sliderBias = startSliderBias
            return out
        }
        let base = Double(value) - (clock.sliderBias ?? joinedSliderBias) - at.timeIntervalSince(clock.baseAt)
        guard base >= clock.anchor.elapsed - calibrationSlackSecs,
              base <= clock.anchor.elapsed + 1 + calibrationSlackSecs else { return out }
        out.base = base
        out.precise = true
        return out
    }

    // MARK: 轮询线程上用的

    /// 这一拍交给快照的位置;`waiting` 时快照报在加载,`precise` 时位置是量准的(快照标 `positionIsPrecise`,差过 0.1 秒当拍重锚),
    /// `dueBy` 是该补查一次的时刻(等开播第二份锚点、等进度条校准)。
    public struct Reading: Equatable, Sendable {
        public var position: Double
        public var waiting: Bool
        public var precise: Bool
        public var dueBy: Date?
    }

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "pine")
    private static let state = OSAllocatedUnfairLock<Clock?>(initialState: nil)
    private static let sampling = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// 进度条在读、读完该补查的时刻。每一拍都带上(`LocalPlaybackSource` 每来一份快照会换掉排着的补查),过了就清掉。
    private static let calibrationDue = OSAllocatedUnfairLock<Date?>(initialState: nil)
    private static let starts = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// 认出过几次开播:一次开播的第一份锚点(停住等第二份的,或前面不是开播的表)加一,第二份不加。`PinePlayerInfo` 按它重挑当前文件
    /// (同一首换了个文件再放,歌名和歌手一栏不变)。
    public static var startCount: Int { starts.withLock { $0 } }

    /// 换了这块表算不算新的一次开播。纯函数,selftest 覆盖。
    public static func isNewStart(from previous: Clock?, to next: Clock) -> Bool {
        guard next.kind == .start, next != previous else { return false }
        return next.holdUntil != nil || previous?.kind != .start || previous?.anchor.track != next.anchor.track
    }
    private static let queue = DispatchQueue(label: "lyrimuse.pine.progress-bar", qos: .userInitiated)

    /// 系统那份这一拍的原始锚点 → 这块表给的位置。主路径与焦点回退都走这里。没有锚点为 nil(调用方照用系统那份)。
    /// 该读进度条时在后台读,读完下一拍用上。
    public static func reading(track: String, playing: Bool, anchorElapsed: Double?, anchorAt: Date?, duration: Double?,
                               pid: Int?, now: Date = Date()) -> Reading? {
        guard let anchorElapsed, let anchorAt else { return nil }
        let anchor = Anchor(track: track, elapsed: anchorElapsed, at: anchorAt, playing: playing)
        let (clock, changed) = state.withLock { s -> (Clock, Bool) in
            let next = advance(s, anchor: anchor, now: now, duration: duration)
            if isNewStart(from: s, to: next) { starts.withLock { $0 += 1 } }
            defer { s = next }
            return (next, next != s)
        }
        if changed {
            logger.notice("pine clock: \(clock.kind.rawValue, privacy: .public) anchor \(anchorElapsed, format: .fixed(precision: 3)) → \(position(clock, now: now).position, format: .fixed(precision: 3)), precise \(clock.precise, privacy: .public), hold \(clock.holdUntil != nil, privacy: .public)")
        }
        if wantsProgressBar(clock, now: now) {
            if let pid, let duration, duration > 0, duration < ProgressBar.maxDuration, startSampling(anchor: clock.anchor, pid: pid_t(pid), duration: duration) {
                calibrationDue.withLock { due in if due.map({ $0 <= now }) ?? true { due = now.addingTimeInterval(ProgressBar.window + 0.15) } }
            } else {
                state.withLock { s in if let c = s, sameAnchor(c.anchor, anchor) { s?.sliderDone = true } }
            }
        }
        let calibrating = calibrationDue.withLock { due -> Date? in
            if let d = due, d <= now { due = nil }
            return due
        }
        let dueBy = [clock.holdUntil.flatMap { now < $0 ? $0 : nil }, calibrating].compactMap { $0 }.min()
        let p = position(clock, now: now)
        return Reading(position: p.position, waiting: p.waiting, precise: clock.precise && clock.anchor.playing && !p.waiting,
                       dueBy: dueBy)
    }

    /// 在后台读一次进度条,读到就按它校准同一个锚点的表。读不了(没权限、关掉了这条)返回 false;已经在读返回 true。
    private static func startSampling(anchor: Anchor, pid: pid_t, duration: Double) -> Bool {
        guard !SourceKnockout.isOut(.pineSlider), AXIsProcessTrusted() else { return false }
        guard sampling.withLock({ busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }) else { return true }
        queue.async {
            let tick = ProgressBar.nextTick(pid: pid, duration: duration)
            // 先写回结果再放开:夹在中间的一拍看到还没读过,会对同一份锚点再读一轮、再校准一次。
            defer { sampling.withLock { $0 = false } }
            let result = state.withLock { s -> (before: Clock, after: Clock)? in
                guard let current = s, sameAnchor(current.anchor, anchor) else { return nil }
                var next = current
                if let tick { next = calibrated(current, value: tick.value, at: tick.at) } else { next.sliderDone = true }
                s = next
                return (current, next)
            }
            guard let result else { return }
            if let tick {
                logger.notice("pine progress bar: \(result.before.kind.rawValue, privacy: .public) ticked to \(tick.value, privacy: .public), bias \(result.after.sliderBias ?? joinedSliderBias, format: .fixed(precision: 3)), base \(result.before.base, format: .fixed(precision: 3)) → \(result.after.base, format: .fixed(precision: 3))")
            } else {
                logger.notice("pine progress bar: no tick read for the \(result.before.kind.rawValue, privacy: .public) anchor")
            }
        }
        return true
    }

    /// 回放测试用:清空这块表。
    public static func reset() {
        state.withLock { $0 = nil }
    }

    // MARK: 界面进度条

    /// Pine 主窗口里的进度条(`AXSlider`,值是整秒,最大值是这首的整秒时长;窗口最小化时照样走)。只读属性,不做任何动作。
    enum ProgressBar {
        /// 读多久等它跳一格。
        static let window: TimeInterval = 1.3
        /// 隔多久读一次。读到跳格的时刻最多晚这么多,按一半补。
        static let interval: TimeInterval = 0.02
        /// 进度条最大值跟这首时长差这么多以内才认(另一根滑块是音量,最大值 1)。
        static let durationSlack: Double = 1.5
        /// 时长到这么长不去找进度条(网络电台报的时长是 Int64 上限)。
        static let maxDuration: Double = 1e7
        /// 跨进程查询超时,App 元素和往下取到的每个元素都设。
        static let axTimeout: Float = 0.25

        /// 等进度条跳下一格:跳到的格值和那一刻。找不到进度条、读不到、窗口里没有跳格的返回 nil。阻塞最多 `window`。
        static func nextTick(pid: pid_t, duration: Double) -> (value: Int, at: Date)? {
            let app = MenuBarAX.timed(AXUIElementCreateApplication(pid), timeout: axTimeout)
            guard let bar = find(in: app, duration: duration) else { return nil }
            guard var last = value(bar) else { return nil }
            let end = Date().addingTimeInterval(window)
            while Date() < end {
                Thread.sleep(forTimeInterval: interval)
                guard let v = value(bar) else { return nil }
                if v == last + 1 { return (v, Date().addingTimeInterval(-interval / 2)) }
                last = v
            }
            return nil
        }

        /// 各窗口第一、二层子元素里最大值对得上时长的那根滑块。
        static func find(in app: AXUIElement, duration: Double) -> AXUIElement? {
            for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute, timeout: axTimeout) {
                for child in MenuBarAX.children(window, timeout: axTimeout) {
                    if isBar(child, duration: duration) { return child }
                    if let hit = MenuBarAX.children(child, timeout: axTimeout).first(where: { isBar($0, duration: duration) }) {
                        return hit
                    }
                }
            }
            return nil
        }

        static func isBar(_ element: AXUIElement, duration: Double) -> Bool {
            guard (attribute(element, kAXRoleAttribute) as? String) == kAXSliderRole,
                  let max = (attribute(element, kAXMaxValueAttribute) as? NSNumber)?.doubleValue else { return false }
            return max > 1 && abs(max - duration) <= durationSlack
        }

        static func value(_ element: AXUIElement) -> Int? {
            (attribute(element, kAXValueAttribute) as? NSNumber).flatMap { Int(exactly: $0.doubleValue.rounded()) }
        }

        private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
    }
}
