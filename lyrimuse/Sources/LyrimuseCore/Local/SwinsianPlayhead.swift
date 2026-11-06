import Foundation
import os

/// Swinsian 的位置。它的脚本 `player position` 是下取整的整秒,但整秒跳变的时刻跟真实出声对得上(差 ±0.03 秒);两份锚点
/// (系统会话、它的分布式通知)按事件不同各早或晚零点几秒,所以位置以脚本的整秒为准:
///
/// - 来了新的锚点(开播、恢复、暂停、换歌、循环绕回、系统指令跳转)先按它走(`base` 不准,`precise` 为 false),
///   接着在后台盯一次脚本的整秒跳变(`Tick`),跳到 N 的那一刻位置就是 N,这一段从此是准的。
/// - 每一拍问一次脚本的整秒(`Check`):推出来的位置落不进它报的那一秒(含 `checkSlackSecs` 余量),就是播放中跳转了
///   (脚本、界面拖进度条,两份锚点都不报),或者锚点偏了:差得远的按「报的值 + 0.5」重起一段,差得近的挪进那一秒的边上,
///   再盯一次跳变。
/// - 已经量准的表遇到同一件事的另一份锚点(系统那份和通知各报一次),推出来的位置跟它差不过 `sameEventSlackSecs` 就不换。
/// - 量准的表每过 `recheckSecs` 再盯一次跳变:播放中跳转不到一秒的,整秒核对看不出来,靠这一次纠回。
/// - 暂停着的位置就是暂停锚点报的(两份一致,恢复时声音从这里接着出)。
///
/// 见 02 章决策 241。
public enum SwinsianPlayhead {
    /// 一份锚点:系统会话的,或通知的(`currentTime` 和收到的时刻)。
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

    /// 一次脚本整秒读数:`from`~`to` 之间某一刻读到的 `position`(真位置在它和它 + 1 之间)。
    public struct Check: Equatable, Sendable {
        public var position: Int
        public var from: Date
        public var to: Date

        public init(position: Int, from: Date, to: Date) {
            self.position = position
            self.from = from
            self.to = to
        }
    }

    /// 脚本整秒跳到 `value` 的那一刻。
    public struct Tick: Equatable, Sendable {
        public var value: Int
        public var at: Date

        public init(value: Int, at: Date) {
            self.value = value
            self.at = at
        }
    }

    /// 这块表此刻的状态。在走时位置 = `base` + (现在 − `baseAt`);停着时是 `base`。`anchor` 是最近采信的那份锚点,
    /// 同一份不再重起一段。
    public struct Clock: Equatable, Sendable {
        public var anchor: Anchor
        public var base: Double
        public var baseAt: Date
        public var playing: Bool
        /// `base` 是按整秒跳变量准的。
        public var precise: Bool
        /// 这一段还要盯一次跳变。
        public var wantsTick: Bool
        /// 这一段已经盯过几次跳变(读不到、对不上都算),到 `maxTickAttempts` 不再盯。
        public var tickAttempts: Int

        public init(anchor: Anchor, base: Double, baseAt: Date, playing: Bool, precise: Bool = false,
                    wantsTick: Bool = false, tickAttempts: Int = 0) {
            self.anchor = anchor
            self.base = base
            self.baseAt = baseAt
            self.playing = playing
            self.precise = precise
            self.wantsTick = wantsTick
            self.tickAttempts = tickAttempts
        }
    }

    /// 两份锚点时刻差在这以内、位置和播放状态一样,算同一份。
    static let anchorJitterSecs: TimeInterval = 0.05
    /// 量准的表遇到新锚点,推出来的位置跟锚点差这么多以内算同一件事(实测两份锚点对出声最多差 0.38 秒)。
    public static let sameEventSlackSecs: Double = 0.45
    /// 脚本整秒读数核对的余量(整秒跳变对出声 ±0.03 秒,加上读数往返)。
    public static let checkSlackSecs: Double = 0.15
    /// 推出来的位置离脚本那一秒差过这么多,当成跳转了,按那一秒的中间重起;差得少的只挪进那一秒。
    public static let seekGapSecs: Double = 1.5
    /// 挪进那一秒时离边留的量。
    static let edgeInsetSecs: Double = 0.05
    /// 跳变推出的位置跟这一段差过这么多不采信(盯的那一秒里又跳转了)。
    public static let tickSlackSecs: Double = 1.2
    /// 一段最多盯几次跳变。
    public static let maxTickAttempts = 3
    /// 量准的表隔这么久再盯一次跳变。
    public static let recheckSecs: TimeInterval = 20

    // MARK: 纯函数

    public static func sameAnchor(_ a: Anchor, _ b: Anchor) -> Bool {
        a.track == b.track && a.elapsed == b.elapsed && a.playing == b.playing
            && abs(a.at.timeIntervalSince(b.at)) <= anchorJitterSecs
    }

    /// 此刻的位置。纯函数,selftest 覆盖。
    public static func position(_ clock: Clock, now: Date) -> Double {
        clock.playing ? max(0, clock.base + now.timeIntervalSince(clock.baseAt)) : clock.base
    }

    /// 两份锚点里该采信哪份:只看这一首、播放状态跟这一拍一致的,取时刻最新的。纯函数,selftest 覆盖。
    public static func newest(_ anchors: [Anchor?], track: String, playing: Bool) -> Anchor? {
        anchors.compactMap { $0 }.filter { $0.track == track && $0.playing == playing }.max { $0.at < $1.at }
    }

    /// 来了一份锚点之后的表。同一份、或比现在采信的那份旧的,原样交回;量准的表遇到同一件事的另一份锚点也不换。纯函数,selftest 覆盖。
    public static func adopt(_ clock: Clock?, anchor: Anchor) -> Clock {
        if let clock, clock.anchor.track == anchor.track {
            if sameAnchor(clock.anchor, anchor) || anchor.at <= clock.anchor.at { return clock }
            if clock.precise, clock.playing, anchor.playing,
               abs(position(clock, now: anchor.at) - anchor.elapsed) <= sameEventSlackSecs {
                var kept = clock
                kept.anchor = anchor
                return kept
            }
        }
        return Clock(anchor: anchor, base: anchor.elapsed, baseAt: anchor.at, playing: anchor.playing,
                     wantsTick: anchor.playing)
    }

    /// 脚本整秒读数核对之后的表:对得上原样交回;对不上的,差得远按那一秒的中间、差得近挪进那一秒,重新盯跳变。纯函数,selftest 覆盖。
    public static func checked(_ clock: Clock, _ check: Check) -> Clock {
        guard clock.playing else { return clock }
        let low = Double(check.position), high = Double(check.position + 1)
        let early = position(clock, now: check.from), late = position(clock, now: check.to)
        guard late < low - checkSlackSecs || early > high + checkSlackSecs else { return clock }
        let mid = check.from.addingTimeInterval(check.to.timeIntervalSince(check.from) / 2)
        let predicted = position(clock, now: mid)
        let base: Double
        if predicted < low - seekGapSecs || predicted > high + seekGapSecs {
            base = low + 0.5
        } else {
            base = predicted < low ? low + edgeInsetSecs : high - edgeInsetSecs
        }
        var out = clock
        out.base = base
        out.baseAt = mid
        out.precise = false
        out.wantsTick = true
        out.tickAttempts = 0
        return out
    }

    /// 盯到跳变之后的表:推出来的位置跟这一段差不过 `tickSlackSecs` 就从跳变那一刻起算、记成准的;差得多的不采信
    /// (`wantsTick` 留着,下一拍再盯,到 `maxTickAttempts` 为止)。`nil` = 这一次没盯到。纯函数,selftest 覆盖。
    public static func calibrated(_ clock: Clock, tick: Tick?) -> Clock {
        var out = clock
        out.tickAttempts += 1
        if let tick, clock.playing, abs(position(clock, now: tick.at) - Double(tick.value)) <= tickSlackSecs {
            out.base = Double(tick.value)
            out.baseAt = tick.at
            out.precise = true
            out.wantsTick = false
            return out
        }
        if out.tickAttempts >= maxTickAttempts { out.wantsTick = false }
        return out
    }

    /// 一拍的推进:换了一首从头起,两份锚点里取最新的那份采信,再拿脚本读数核对。两份锚点都没有、也没有这一首的表为 nil。
    /// 纯函数,selftest 覆盖。
    public static func advance(_ clock: Clock?, track: String, playing: Bool, system: Anchor?, notice: Anchor?,
                               check: Check?) -> Clock? {
        var next = clock?.anchor.track == track ? clock : nil
        if let anchor = newest([system, notice], track: track, playing: playing) { next = adopt(next, anchor: anchor) }
        if let check, let current = next { next = checked(current, check) }
        return next
    }

    /// 量准的表在走、离上次对时过了 `recheckSecs`:再盯一次跳变(还算准,盯到了从跳变起算)。纯函数,selftest 覆盖。
    public static func rechecked(_ clock: Clock, now: Date) -> Clock {
        guard clock.precise, clock.playing, !clock.wantsTick, now.timeIntervalSince(clock.baseAt) >= recheckSecs else { return clock }
        var out = clock
        out.wantsTick = true
        out.tickAttempts = 0
        return out
    }

    /// 这一拍该不该去盯跳变。纯函数,selftest 覆盖。
    public static func wantsTick(_ clock: Clock) -> Bool {
        clock.playing && clock.wantsTick && clock.tickAttempts < maxTickAttempts
    }

    // MARK: 轮询线程上用的

    /// 这一拍交给快照的位置;`precise` 时位置是量准的(快照标 `positionIsPrecise`),`dueBy` 是盯跳变的结果该到的时刻。
    public struct Reading: Equatable, Sendable {
        public var position: Double
        public var precise: Bool
        public var dueBy: Date?
    }

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "swinsian")
    private static let state = OSAllocatedUnfairLock<Clock?>(initialState: nil)
    private static let sampling = OSAllocatedUnfairLock<Bool>(initialState: false)
    private static let tickDue = OSAllocatedUnfairLock<Date?>(initialState: nil)
    private static let queue = DispatchQueue(label: "lyrimuse.swinsian.tick", qos: .userInitiated)
    /// 盯一次跳变最多多久(脚本里等 1.3 秒,加上起 osascript)。
    static let tickTimeout: TimeInterval = 2.5
    /// 排补查时按这么久之后结果该到了。
    static let tickExpectedSecs: TimeInterval = 1.6

    /// 这一拍的两份锚点和脚本读数 → 这块表给的位置。主路径与焦点回退都走这里。两份锚点都没有为 nil(调用方照用系统那份)。
    /// 该盯跳变时在后台盯,盯完下一拍用上。
    public static func reading(track: String, playing: Bool, system: Anchor?, notice: Anchor?, check: Check?,
                               now: Date = Date()) -> Reading? {
        let (clock, before) = state.withLock { s -> (Clock?, Clock?) in
            let previous = s
            s = advance(s, track: track, playing: playing, system: system, notice: notice, check: check).map {
                rechecked($0, now: now)
            }
            return (s, previous)
        }
        guard let clock else { return nil }
        if clock != before, clock.base != before?.base || clock.anchor != before?.anchor {
            logger.notice("swinsian clock: anchor \(clock.anchor.elapsed, format: .fixed(precision: 3)) playing \(clock.playing, privacy: .public) → \(position(clock, now: now), format: .fixed(precision: 3)), precise \(clock.precise, privacy: .public), check \(check.map { String($0.position) } ?? "-", privacy: .public)")
        }
        if wantsTick(clock), startSampling(track: track) {
            tickDue.withLock { due in if due.map({ $0 <= now }) ?? true { due = now.addingTimeInterval(tickExpectedSecs) } }
        }
        let due = tickDue.withLock { due -> Date? in
            if let d = due, d <= now { due = nil }
            return due
        }
        return Reading(position: position(clock, now: now), precise: clock.precise && clock.playing, dueBy: due)
    }

    /// 在后台盯一次脚本的整秒跳变,盯到就校准同一首的表。脚本关掉了返回 false;已经在盯返回 true。
    private static func startSampling(track: String) -> Bool {
        guard !SourceKnockout.isOut(.swinsianScript) else { return false }
        guard sampling.withLock({ busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }) else { return true }
        queue.async {
            let tick = SwinsianPlayerInfo.sampleTick(timeout: tickTimeout)
            defer { sampling.withLock { $0 = false } }
            let result = state.withLock { s -> (before: Clock, after: Clock)? in
                guard let current = s, current.anchor.track == track, wantsTick(current) else { return nil }
                let next = calibrated(current, tick: tick)
                s = next
                return (current, next)
            }
            guard let result else { return }
            if let tick {
                logger.notice("swinsian tick: \(tick.value, privacy: .public), base \(result.before.base, format: .fixed(precision: 3)) → \(result.after.base, format: .fixed(precision: 3)), precise \(result.after.precise, privacy: .public)")
            } else {
                logger.notice("swinsian tick: none read (attempt \(result.after.tickAttempts, privacy: .public))")
            }
        }
        return true
    }

    /// 回放测试用:清空这块表。
    public static func reset() {
        state.withLock { $0 = nil }
    }
}
