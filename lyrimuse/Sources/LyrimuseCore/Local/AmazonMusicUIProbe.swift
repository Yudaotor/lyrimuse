import ApplicationServices
import Foundation

/// 读 Amazon Music 界面上的播放时间,拿它校准自动连播的提前量(见 `AmazonMusicPlayhead` 头注)。
///
/// 界面上那两个时间(已播 `02:24`、剩余 `-01:05`)按真正出声走(引擎每 100 毫秒推一次进度给界面,
/// `setTrackProgressNotificationPeriod ( 100 )`),是唯一能拿到的真值。Amazon Music 是 CEF 应用,网页内容的辅助功能树
/// 不跟着界面刷新,注册观察者也不推送;**只有 `AXEnhancedUserInterface` 从 false 设成 true 那一下会整棵重建一次**
/// (实测约 230 毫秒建好,期间读是空的,偶尔先读到上次那棵旧树;已经是 true 时再设 true 不刷新)。
///
/// 所以每次「关 → 开 → 等建好 → 读」得到一个读数:它对应的时刻落在切换到建好之间,读到的是整秒数。每个读数给这首的
/// 真实起点划出一个区间(见 `originInterval`),读几次取交集,窄到 `targetWidth` 就停,取中点(`settledOrigin`)。
/// 交集变空(界面时间停了一下又走,常见于刚恢复播放)就丢掉之前的读数,从最新这次重新收。
///
/// 开关之后头 100~150 毫秒读到的还是旧树(值是上一轮的,元素也是同一个),之后才换成新树、元素换成新的:所以只认跟上次
/// 读到的不是同一个元素的读数(`lastElapsedElement`),否则旧值偏小,推出的起点偏晚、歌词偏慢。
///
/// 每开关一次 Amazon 都要整棵重建树,整棵遍历一次也要一两百毫秒的跨进程查询,都会抢它的 CPU(读得密时它更容易卡顿断音)。
/// 所以:① 找到过的那一对时间文字记下在树里的子节点路径(`clockPaths`),之后按路径直接读,走不通才整棵找;
/// ② 有了第一个读数之后,下一次开关挑在「区间中点对上界面跳秒」的那一刻(`nextToggleTime`),每读一次区间砍一半,
/// 取样阶段最多开关 `maxSampleToggles` 次。
///
/// 只读属性、不做任何动作;结束时把 `AXEnhancedUserInterface` 设回 false。需要「辅助功能」权限,没有就不读
/// (调用方退回不校准)。剩余时间用来核对读到的是当前这首:已播 + 剩余要跟时长对得上。
///
/// 自动连播切歌时界面跟日志同一刻换到下一首,但时间停在 `00:00` 直到真正出声才走;所以 0 秒的读数不用,
/// 否则几次停住的 0 会收敛出一个偏早的起点。停在 `00:00` 的这段最多等 `startWait`,不算进 `timeout`:调用方切歌后
/// 很快就来读,上一首的尾巴还在放(实测最长 4.6 秒)。
public enum AmazonMusicUIProbe {
    public struct Sample: Equatable, Sendable {
        /// 切换开关的时刻与树建好、读到数的时刻。
        public let toggledAt: Date
        public let readAt: Date
        /// 读到的已播秒数。
        public let seconds: Int

        public init(toggledAt: Date, readAt: Date, seconds: Int) {
            self.toggledAt = toggledAt
            self.readAt = readAt
            self.seconds = seconds
        }
    }

    /// 界面文字比真实位置最多晚这么多更新(引擎推进度的周期)。
    public static let displayLag: TimeInterval = 0.1
    /// 交集窄到这个宽度就停。下限由读数本身定:每次读数对应的时刻在「切换到建好」这约 0.23 秒里不确定,界面文字又最多晚
    /// `displayLag`,交集最窄也有 0.33 秒左右 —— 别把门槛设到这个量以下,否则永远收不住。
    public static let targetWidth: TimeInterval = 0.45
    /// 从读到第一个非 0 读数起最多再读这么久(`nextToggleTime` 每次最多等一秒多)。
    public static let timeout: TimeInterval = 6
    /// 取样阶段(拿到第一个非 0 读数起)最多开关几次。按 `nextToggleTime` 取样,5 次收到 `targetWidth` 以内。
    public static let maxSampleToggles = 6
    /// 一次重建通常多久(开关到读到数)。
    static let typicalRebuild: TimeInterval = 0.23
    /// 界面停在 `00:00` 最多等这么久(上一首的尾巴还没放完)。
    public static let startWait: TimeInterval = 7
    /// 停在 `00:00` 时两次读之间隔多久:每读一次整棵辅助功能树都要重建,等出声这段不必读得太密。
    static let startPollInterval: TimeInterval = 0.25
    /// 一次重建最多等这么久。
    public static let rebuildTimeout: TimeInterval = 1

    /// 一组读数推出的「这首真实起点」区间(epoch 秒,位置 = 当前时刻 − 起点)。交集为空(中途暂停、读错)返回 nil。纯函数。
    ///
    /// 读数 v 在 [切换, 建好] 之间某一刻 t 取得,那一刻真实位置落在 [v, v + 1 + displayLag) → 起点 ∈ (切换 − v − 1 − displayLag, 建好 − v]。
    public static func originInterval(_ samples: [Sample]) -> ClosedRange<Double>? {
        guard !samples.isEmpty else { return nil }
        var lo = -Double.infinity
        var hi = Double.infinity
        for s in samples {
            let v = Double(s.seconds)
            lo = max(lo, s.toggledAt.timeIntervalSince1970 - v - 1 - displayLag)
            hi = min(hi, s.readAt.timeIntervalSince1970 - v)
        }
        return lo < hi ? lo...hi : nil
    }

    /// 一组读数收得住就给起点(区间中点):交集窄到 `targetWidth`,而且读数里至少跨过一次整秒跳变 —— 界面时间停着
    /// (刚恢复、刚切歌还没出声)时几次同样的读数也能把区间收窄,但收出的起点是错的。收不住返回 nil。纯函数。
    public static func settledOrigin(_ samples: [Sample]) -> Double? {
        settledInterval(samples).map { ($0.lowerBound + $0.upperBound) / 2 }
    }

    /// 同 `settledOrigin`,给出整个区间(调用方要跟下一次校准的区间叠)。纯函数。
    public static func settledInterval(_ samples: [Sample]) -> ClosedRange<Double>? {
        guard let range = originInterval(samples), range.upperBound - range.lowerBound <= targetWidth,
              Set(samples.map(\.seconds)).count >= 2 else { return nil }
        return range
    }

    /// 解析界面上的时间:`02:24` / `1:02:03`;带负号的是剩余时间。认不出返回 nil。纯函数,selftest 直接覆盖。
    public static func parseClock(_ text: String) -> (seconds: Int, negative: Bool)? {
        var s = text.trimmingCharacters(in: .whitespaces)
        let negative = s.hasPrefix("-") || s.hasPrefix("−")
        if negative { s.removeFirst() }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }) else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count, nums.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let seconds = nums.reduce(0) { $0 * 60 + $1 }
        return (seconds, negative)
    }

    /// 已播 + 剩余跟时长差多少还算同一首(界面取整、元数据时长取整)。
    public static let durationTolerance: Double = 3

    /// 读到的已播秒数跟日志推出的位置(没扣提前量的 `engineTimelinePosition`)对不对得上。切歌后头一秒界面偶尔还是
    /// 上一首的时间,时长又跟这首差不多时 `matchesTrack` 拦不住,靠这条拦:界面比日志位置超前不了多少。余量
    /// `elapsedSlack` = 提前量下限(`AmazonMusicPlayhead.audibleLeadRange` 的 −4)+ 秒级取整。纯函数。
    public static func plausibleElapsed(_ elapsed: Int, timelinePosition: TimeInterval?) -> Bool {
        guard let timelinePosition else { return true }
        return Double(elapsed) <= timelinePosition + elapsedSlack
    }

    static let elapsedSlack: TimeInterval = 5

    /// 一组读数是不是当前这首的进度条。纯函数。
    public static func matchesTrack(elapsed: Int, remaining: Int?, duration: Double?) -> Bool {
        guard let remaining, let duration, duration > 0 else { return true }
        return abs(Double(elapsed + remaining) - duration) <= durationTolerance
    }

    /// 读不出起点的原因(写进日志)。
    public enum Failure: String, Sendable {
        case notTrusted = "no accessibility permission"
        case noClock = "no clock text in the accessibility tree"
        case notStarted = "the clock on screen stayed at 0:00"
        case otherTrack = "the clock on screen belongs to another track"
        case inconsistent = "readings do not advance with time (paused or seeking?)"
        case timedOut = "did not narrow down in time"
    }

    /// 同步读,阻塞最多 `startWait` + `timeout`,返回这首真实起点(epoch 秒)所在的区间,见 `settledInterval`。别在主线程调。
    /// `timelineOrigin`:日志位置的零点(当前时刻 − `engineTimelinePosition`),给 `plausibleElapsed` 用。`isCurrent`
    /// 每读一次问一下,返回 false(已经换歌)就不读了。
    public static func sampleOrigin(pid: pid_t, duration: Double?, timelineOrigin: Date? = nil,
                                    isCurrent: () -> Bool = { true }) -> Result<ClosedRange<Double>, FailureBox> {
        guard AXIsProcessTrusted() else { return .failure(.init(.notTrusted, samples: 0)) }
        let durationText = duration.map { String(Int($0)) } ?? "?"
        let app = AXUIElementCreateApplication(pid)
        defer { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        var samples: [Sample] = []
        var restarts = 0
        var otherTrack: String?
        var sawZero = false
        var sampleToggles = 0
        let waitDeadline = Date().addingTimeInterval(startWait)
        var deadline: Date?
        while Date() < (deadline ?? waitDeadline), isCurrent() {
            if deadline != nil {
                guard sampleToggles < maxSampleToggles else { break }
                sampleToggles += 1
            }
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            let toggledAt = Date()
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            var found: [FoundClock] = []
            while found.isEmpty, Date().timeIntervalSince(toggledAt) < rebuildTimeout {
                found = readClocks(app)
                if found.isEmpty { Thread.sleep(forTimeInterval: 0.02) }
            }
            let readAt = Date()
            guard !found.isEmpty else { continue }
            let pairs = found.map(\.pair)
            // 开关之后头一次读到的偶尔还是上次那棵旧树(上一首的时间),跳过接着读,别整次放弃。
            guard let picked = pickIndex(pairs, duration: duration), case let elapsed = pairs[picked].elapsed,
                  plausibleElapsed(elapsed, timelinePosition: timelineOrigin.map { readAt.timeIntervalSince($0) }) else {
                otherTrack = pairs.map { "\($0.elapsed)+\($0.remaining.map(String.init) ?? "?")" }.joined(separator: ",")
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            if elapsed == 0 {
                sawZero = true
                Thread.sleep(forTimeInterval: startPollInterval)
                continue
            }
            rememberPaths(found[picked])
            if deadline == nil {
                deadline = Date().addingTimeInterval(timeout)
                sampleToggles = 1
            }
            samples.append(Sample(toggledAt: toggledAt, readAt: readAt, seconds: elapsed))
            if originInterval(samples) == nil {
                restarts += 1
                samples = [samples.last!]
            }
            if let origin = settledInterval(samples) { return .success(origin) }
            if let range = originInterval(samples), let deadline {
                let next = nextToggleTime(origin: range, notBefore: Date().timeIntervalSince1970 + 0.05)
                let wait = min(next, deadline.timeIntervalSince1970) - Date().timeIntervalSince1970
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
        if samples.isEmpty, let otherTrack {
            return .failure(.init(.otherTrack, samples: 0, detail: "clocks \(otherTrack) vs duration \(durationText)"))
        }
        if samples.isEmpty, sawZero { return .failure(.init(.notStarted, samples: 0)) }
        let reason: Failure = samples.isEmpty ? .noClock : (restarts > 0 ? .inconsistent : .timedOut)
        return .failure(.init(reason, samples: samples.count, detail: restarts > 0 ? "restarted \(restarts)x" : nil))
    }

    public struct FailureBox: Error, Sendable {
        public let reason: Failure
        public let samples: Int
        /// 读到了什么(写进日志排查)。
        public let detail: String?
        public init(_ reason: Failure, samples: Int, detail: String? = nil) {
            self.reason = reason
            self.samples = samples
            self.detail = detail
        }
    }

    /// 树里挨在一起的一对已播 / 剩余时间。剩余缺了是 nil。
    public struct ClockPair: Equatable, Sendable {
        public let elapsed: Int
        public let remaining: Int?
        public init(elapsed: Int, remaining: Int?) {
            self.elapsed = elapsed
            self.remaining = remaining
        }
    }

    /// 已播后面隔多少个节点之内的剩余时间算同一对(进度条两端的两段文字在树里相隔两个节点)。
    static let pairDistance = 4

    /// 按树的遍历顺序把时间文字配成对:每个已播配它后面 `pairDistance` 个节点之内的第一个剩余。纯函数。
    public static func pairClocks(_ clocks: [(index: Int, seconds: Int, negative: Bool)]) -> [ClockPair] {
        var out: [ClockPair] = []
        for (i, c) in clocks.enumerated() where !c.negative {
            let next = clocks.dropFirst(i + 1).first { $0.negative && $0.index - c.index <= pairDistance }
            out.append(ClockPair(elapsed: c.seconds, remaining: next?.seconds))
        }
        return out
    }

    /// 从几对里挑当前这首的进度条:第一对带剩余、对得上时长的;整棵树都没有剩余时间才退回第一个已播。
    /// 有剩余却都对不上返回 nil。纯函数。
    public static func pickPair(_ pairs: [ClockPair], duration: Double?) -> (elapsed: Int, remaining: Int?)? {
        pickIndex(pairs, duration: duration).map { (pairs[$0].elapsed, pairs[$0].remaining) }
    }

    /// 同 `pickPair`,给出是第几对。纯函数。
    public static func pickIndex(_ pairs: [ClockPair], duration: Double?) -> Int? {
        guard pairs.contains(where: { $0.remaining != nil }) else { return pairs.isEmpty ? nil : 0 }
        return pairs.firstIndex { $0.remaining != nil && matchesTrack(elapsed: $0.elapsed, remaining: $0.remaining, duration: duration) }
    }

    /// 下一次开关挑在哪一刻(epoch 秒)。一次读数只有两种结果:还没跳到下一秒,新下界落在「开关时刻 − `displayLag`」
    /// (见 `originInterval`);已经跳了,新上界落在「读到时刻 ≈ 开关 + `typicalRebuild`」。让这两个切点对称地夹住起点区间的
    /// 中点(再加整秒),不管读到哪种,区间都砍掉一半。取不早于 `notBefore` 的最近那一刻。纯函数。
    public static func nextToggleTime(origin: ClosedRange<Double>, notBefore: Double) -> Double {
        let mid = (origin.lowerBound + origin.upperBound) / 2 - (typicalRebuild - displayLag) / 2
        return mid + max(0, (notBefore - mid).rounded(.up))
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    /// 读到的一对时间文字,连同它们在树里的子节点路径(从应用根往下每一层是第几个孩子)。
    struct FoundClock {
        let pair: ClockPair
        let elapsedPath: [Int]
        let remainingPath: [Int]?
        let elapsedElement: AXUIElement?
    }

    /// 上次选中的那一对的路径。只在校准队列上读写(一次只有一个探针在跑),锁只是保险。
    private static let pathLock = NSLock()
    nonisolated(unsafe) private static var clockPaths: (elapsed: [Int], remaining: [Int]?)?
    /// 上次采信的那个已播时间元素。开关之后读到的还是它,就是旧树还没换掉。
    nonisolated(unsafe) private static var lastElapsedElement: AXUIElement?

    private static func rememberPaths(_ f: FoundClock) {
        pathLock.lock()
        clockPaths = (f.elapsedPath, f.remainingPath)
        lastElapsedElement = f.elapsedElement
        pathLock.unlock()
    }

    /// 这个元素是不是上次采信过的那一个(旧树)。
    private static func isStale(_ e: AXUIElement?) -> Bool {
        pathLock.lock()
        defer { pathLock.unlock() }
        guard let e, let last = lastElapsedElement else { return false }
        return CFEqual(e, last)
    }

    private static func element(_ app: AXUIElement, at path: [Int]) -> AXUIElement? {
        var e = app
        for i in path {
            guard let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement], i < kids.count else { return nil }
            e = kids[i]
        }
        return e
    }

    /// 按记下的路径直接读那一对:已播要读得出正的时间、剩余(记了的话)读得出负的,否则当作走不通。
    private static func readAtPaths(_ app: AXUIElement) -> FoundClock? {
        pathLock.lock()
        let paths = clockPaths
        pathLock.unlock()
        guard let paths, let e = element(app, at: paths.elapsed),
              let es = attr(e, kAXValueAttribute) as? String, let ec = parseClock(es), !ec.negative else { return nil }
        var remaining: Int?
        if let rp = paths.remaining {
            guard let r = element(app, at: rp), let rs = attr(r, kAXValueAttribute) as? String,
                  let rc = parseClock(rs), rc.negative else { return nil }
            remaining = rc.seconds
        }
        return FoundClock(pair: ClockPair(elapsed: ec.seconds, remaining: remaining), elapsedPath: paths.elapsed,
                          remainingPath: paths.remaining, elapsedElement: e)
    }

    /// 树里所有配成对的时间文字;树还没建好(读到的还是旧树、或者空的)返回空。先按记下的路径读,走不通再整棵遍历。
    private static func readClocks(_ app: AXUIElement) -> [FoundClock] {
        if let hit = readAtPaths(app) { return isStale(hit.elapsedElement) ? [] : [hit] }
        var clocks: [(index: Int, seconds: Int, negative: Bool)] = []
        var paths: [Int: [Int]] = [:]
        var elements: [Int: AXUIElement] = [:]
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int, _ path: [Int]) {
            visited += 1
            guard depth <= 40, visited <= 5000 else { return }
            if let s = attr(e, kAXValueAttribute) as? String, let c = parseClock(s) {
                clocks.append((visited, c.seconds, c.negative))
                paths[visited] = path
                elements[visited] = e
            }
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
                for (i, k) in kids.enumerated() { walk(k, depth + 1, path + [i]) }
            }
        }
        walk(app, 0, [])
        var out: [FoundClock] = []
        for (i, c) in clocks.enumerated() where !c.negative {
            let next = clocks.dropFirst(i + 1).first { $0.negative && $0.index - c.index <= pairDistance }
            if isStale(elements[c.index]) { return [] }
            out.append(FoundClock(pair: ClockPair(elapsed: c.seconds, remaining: next?.seconds),
                                  elapsedPath: paths[c.index] ?? [], remainingPath: next.flatMap { paths[$0.index] },
                                  elapsedElement: elements[c.index]))
        }
        return out
    }
}
