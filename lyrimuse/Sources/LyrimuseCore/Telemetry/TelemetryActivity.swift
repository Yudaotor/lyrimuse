import Foundation

/// 心跳里「之前几天的活动」的记账:放过哪些播放器、主线程卡住几次(前几次带概况)、几个动作各做了几次、放过的歌各拿到哪档歌词、显示的那份来自哪个源、是什么语言,按本地自然日一天一格,存在 UserDefaults。
/// 播放源换播放器、看门狗报卡住时各记一笔;`isRecording` 为假(遥测关着)时一律不记。心跳发出去之后
/// `remove(days:)` 删掉发过的那几天。最多留 `maxStoredDays` 天,多了丢最早的。早于 `sentBefore`(已随心跳发出)、
/// 或比今天晚一天以上(系统日期往前调过)的日子不记也不留。
public final class TelemetryActivity: @unchecked Sendable {
    public static let shared = TelemetryActivity(defaults: .standard)

    public static let storageKey = "np:telemetryActivity"
    public static let maxStoredDays = 3
    /// 每天最多记几次卡顿的概况(次数照记);心跳带最多 `maxStoredDays` 天,负载要在 Worker 的 MAX_BODY 以内。
    /// 停顿期间主线程被系统压着的(`TelemetryHang.throttled`)另算名额,不挤掉没被压着的。Worker 的两个同名常量一起改。
    public static let maxHangDetailsPerDay = 3
    public static let maxThrottledHangDetailsPerDay = 1
    /// 每天最多记几种窗口布局超限(按窗口 + 类名 + pass 分;同一种只加次数)。
    public static let maxLayoutLimitsPerDay = 5
    /// 每天每项计数的上限,跟 Worker 收的上限(`int(v, …, 10_000)`)一致,超了 Worker 判这一项不合法。两处一起改。
    public static let maxCount = 10_000

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    /// 写盘走这条串行队列,不持 `lock`:UserDefaults 写入会同步等主线程上的观察者处理完,持着 `lock` 写的话,主线程这时来拿
    /// `lock`(读 `isRecording`)就互相等死,主线程看门狗记卡顿时就是这样卡死的(14 章决策 175)。别把写盘挪回锁里。
    private let writeQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.telemetry-activity-write")
    /// 记下的几天的内存副本,读都走它;nil = 还没从磁盘读过。
    private var cache: [TelemetryActivityDay]?
    /// 有一次延后的写盘排着(`store(_:deferred:)`)。
    private var deferredWritePending = false
    private var queuedWriteCount = 0
    /// 写盘队列已经写完的次数;跟 `queuedWriteCount` 不等就还有排着没写完的。
    private var finishedWriteCount = 0
    /// 延后写盘等多久:布局超限振荡时每帧都来一次,同一种只加次数的那些攒到这么久写一次。
    static let deferredWriteDelay: TimeInterval = 5
    private var recording = false
    private var sentDay: String?
    private let clock: @Sendable () -> Date
    private var trusted: Set<String> = []
    /// 上一次记下的播放器,同一个播放器连着报不重复写盘。
    private var lastPlayer: (day: String, tag: String)?
    /// 最近那次卡顿记在哪一天、概况是第几条(没占到名额为 nil)、算没算进被压着的次数:恢复时补时长、采样完补调用栈、
    /// 后来才看到被压着时补标记,都补到它。只在内存里。
    private var openHang: (day: String, index: Int?, throttled: Bool)?
    /// 今天记过歌词结果的歌(曲目键 → 记下的那一笔)。只在内存里,不写盘、不上报;换天清空。
    private var lyricsNoted: (day: String, songs: [String: LyricsNote]) = ("", [:])

    private struct LyricsNote: Equatable {
        var result: TelemetryLyricsResult
        var language: TelemetrySongLanguage?
        /// `lyric_sources` 里记到的键;纯音乐、没找到为 nil。
        var sourceKey: String?
    }

    public init(defaults: UserDefaults, key: String = TelemetryActivity.storageKey, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.key = key
        self.clock = clock
    }

    /// 排给写盘队列的写入次数(不含还在等的延后写)。selftest 按它判「振荡时不每帧写盘」。
    public var queuedWrites: Int { lock.withLock { queuedWriteCount } }

    public var isRecording: Bool {
        get { lock.withLock { recording } }
        set { lock.withLock { recording = newValue } }
    }

    /// 上次发心跳的那天(App 从 `TelemetryService.Keys.lastHeartbeatDay` 同步):更早的日子已随心跳发出,不再记、存着的也丢。
    /// 系统日期往回调后接着记的话,下一条心跳会拿半截数据把服务器上那天已收的整行盖掉(14 章决策 230)。
    public var sentBefore: String? {
        get { lock.withLock { sentDay } }
        set { lock.withLock { sentDay = newValue } }
    }

    /// 用户信任的第三方播放器与浏览器(bundle id):放过歌时记 bundle id,不记 `other`。
    public var trustedBundleIDs: Set<String> {
        get { lock.withLock { trusted } }
        set { lock.withLock { trusted = newValue } }
    }

    public func notePlayer(bundleID: String?, now: Date = Date()) {
        guard let tag = Telemetry.playerTag(forBundleID: bundleID, trusted: trustedBundleIDs) else { return }
        let day = Telemetry.day(now)
        lock.withLock {
            guard recording, lastPlayer?.day != day || lastPlayer?.tag != tag else { return }
            lastPlayer = (day, tag)
            update(day: day) { if !$0.playersPlayed.contains(tag) { $0.playersPlayed.append(tag); $0.playersPlayed.sort() } }
        }
    }

    public func noteAction(_ action: TelemetryAction, now: Date = Date()) {
        let day = Telemetry.day(now)
        lock.withLock {
            guard recording else { return }
            update(day: day) { Self.increment(&$0.actions, action.rawValue) }
        }
    }

    /// 一首歌的歌词落定了。`source` 是显示的那份的来源(条目的 `lyrics_source` 这类原值,`TelemetryLyricSource.tag` 归一)。
    /// 同一首一天只算一次;结果或来源变了(补出了逐字、手动换了一份)就把这首那一笔挪到新的那一档。
    /// App 重启后内存里的记录没了,同一天再放到会再算一次。
    public func noteLyricsResult(track: String, result: TelemetryLyricsResult, source: String?, language: TelemetrySongLanguage?,
                                 now: Date = Date()) {
        let day = Telemetry.day(now)
        let note = LyricsNote(result: result, language: language,
                              sourceKey: TelemetryLyricSource.key(source: source, result: result))
        lock.withLock {
            guard recording else { return }
            if lyricsNoted.day != day { lyricsNoted = (day, [:]) }
            let previous = lyricsNoted.songs[track]
            guard previous != note else { return }
            lyricsNoted.songs[track] = note
            update(day: day) { d in
                if let previous {
                    Self.decrement(&d.lyrics, previous.result.rawValue)
                    if let old = previous.language { Self.decrement(&d.languages, old.rawValue) }
                    if let old = previous.sourceKey { Self.decrement(&d.lyricSources, old) }
                }
                Self.increment(&d.lyrics, result.rawValue)
                if let language { Self.increment(&d.languages, language.rawValue) }
                if let key = note.sourceKey { Self.increment(&d.lyricSources, key) }
            }
        }
    }

    private static func increment(_ counts: inout [String: Int], _ key: String) {
        counts[key] = min((counts[key] ?? 0) + 1, maxCount)
    }

    private static func decrement(_ counts: inout [String: Int], _ key: String) {
        let left = (counts[key] ?? 0) - 1
        counts[key] = left > 0 ? left : nil
    }

    /// 主线程卡住一次。`detail` 带了 `throttled` 的同时记进被压着的次数。`detail` 给了且当天同一类(被压着 / 没被压着)
    /// 还有名额,记下概况(播放器填最近一次放歌的那个),之后的 `finishHang` / `attachHangStack` / `markHangThrottled`
    /// 补到这一条。返回这一次有没有占到当天的概况名额(占到了,看门狗就该采栈)。
    @discardableResult
    public func noteHang(_ detail: TelemetryHang? = nil, now: Date = Date()) -> Bool {
        let day = Telemetry.day(now)
        return lock.withLock {
            guard recording else { return false }
            let throttled = detail?.throttled != nil
            var index: Int?
            update(day: day) { d in
                d.hangs = min(d.hangs + 1, Self.maxCount)
                if throttled { d.throttledHangs = min(d.throttledHangs + 1, d.hangs) }
                guard var detail, Self.hasDetailSlot(d.hangDetails, throttled: throttled) else { return }
                if detail.player == nil { detail.player = lastPlayer?.tag }
                d.hangDetails.append(detail)
                index = d.hangDetails.count - 1
            }
            openHang = (day, index, throttled)
            return index != nil
        }
    }

    /// 当天的概况里,同一类(被压着 / 没被压着)还有没有名额;两类合起来也不超过两个上限之和。
    static func hasDetailSlot(_ details: [TelemetryHang], throttled: Bool) -> Bool {
        let sameKind = details.filter { ($0.throttled != nil) == throttled }.count
        return sameKind < (throttled ? maxThrottledHangDetailsPerDay : maxHangDetailsPerDay)
            && details.count < maxHangDetailsPerDay + maxThrottledHangDetailsPerDay
    }

    /// 最近那次卡顿记下之后才看到主线程被系统压着(`reasons` 是并起来的全部):这一次补进被压着的次数(只补一次),
    /// 概况补上标记。那一天已经随心跳发出、删掉了的不补。
    public func markHangThrottled(_ reasons: [String]) {
        guard !reasons.isEmpty else { return }
        lock.withLock {
            guard recording, let open = openHang else { return }
            var days = load()
            guard let i = days.firstIndex(where: { $0.day == open.day }) else { return }
            let before = days[i]
            if !open.throttled { days[i].throttledHangs = min(days[i].throttledHangs + 1, days[i].hangs) }
            if let index = open.index, index < days[i].hangDetails.count { days[i].hangDetails[index].throttled = reasons }
            openHang = (open.day, open.index, true)
            if days[i] != before { store(days) }
        }
    }

    /// 窗口布局轮数超限被接住一次(`DisplayCycleLimit`)。同一种(窗口、类名、pass 都一样)只加次数,
    /// 当天已经记满 `maxLayoutLimitsPerDay` 种时新的一种不记。振荡时每帧都超一次:只加次数的不当场写盘,
    /// 攒到 `deferredWriteDelay` 后写一次,不然每帧在主线程上编码一遍、再让 UserDefaults 发一次全域变更通知(见 14 章决策 209)。
    public func noteLayoutLimit(window: String?, windowClass: String, pass: String, now: Date = Date()) {
        let day = Telemetry.day(now)
        lock.withLock {
            guard recording else { return }
            let known = load().first { $0.day == day }?.layoutLimits
                .contains { $0.window == window && $0.windowClass == windowClass && $0.pass == pass } ?? false
            update(day: day, deferWrite: known) { d in
                if let i = d.layoutLimits.firstIndex(where: { $0.window == window && $0.windowClass == windowClass && $0.pass == pass }) {
                    d.layoutLimits[i].count = min(d.layoutLimits[i].count + 1, Self.maxCount)
                } else if d.layoutLimits.count < Self.maxLayoutLimitsPerDay {
                    d.layoutLimits.append(TelemetryLayoutLimit(window: window, windowClass: windowClass, pass: pass, count: 1))
                }
            }
        }
    }

    /// 最近那次卡顿恢复了,一共卡了 `seconds` 秒。`memoryPressure` 是整段停顿里看到的最紧的一档(跟记下时的取紧的),
    /// `pageins` 是整段的换页次数(换掉记下时到报卡顿为止的那个数);读不到的不改。
    public func finishHang(seconds: TimeInterval, memoryPressure: String? = nil, pageins: Int? = nil) {
        changeOpenHang {
            $0.duration = TelemetryHang.durationBucket(seconds: seconds)
            $0.memoryPressure = HangMemory.tighter($0.memoryPressure, memoryPressure)
            if let pageins { $0.pageins = pageins }
        }
    }

    /// 最近那次卡顿采到了调用栈(只补一次)。
    public func attachHangStack(_ stack: [TelemetryCrash.Frame]) {
        guard !stack.isEmpty else { return }
        changeOpenHang { if $0.stack.isEmpty { $0.stack = stack } }
    }

    private func changeOpenHang(_ change: (inout TelemetryHang) -> Void) {
        lock.withLock {
            guard recording, let open = openHang, let index = open.index else { return }
            var days = load()
            guard let i = days.firstIndex(where: { $0.day == open.day }), index < days[i].hangDetails.count else { return }
            let before = days[i].hangDetails[index]
            change(&days[i].hangDetails[index])
            if days[i].hangDetails[index] != before { store(days) }
        }
    }

    /// 今天之前记下的几天,按日期升序。
    public func completedDays(before today: String) -> [TelemetryActivityDay] {
        lock.withLock {
            let accepts = acceptsDay()
            return load().filter { $0.day < today && accepts($0.day) }
        }
    }

    public func remove(days: [String]) {
        lock.withLock {
            let drop = Set(days)
            store(load().filter { !drop.contains($0.day) })
        }
    }

    /// 遥测关掉、清除所有设置时清空记下的全部活动。清除所有设置时先把 `isRecording` 置假再删偏好键、删完再调这里:
    /// 不然删键之后到重启之间记的一笔会把内存里清除前的活动整份写回(14 章决策 230)。
    public func clear() {
        lock.withLock {
            lastPlayer = nil
            openHang = nil
            lyricsNoted = ("", [:])
            store([])
        }
    }

    /// 等排着的写盘都落地(测试读磁盘前用);排着的延后写当场写。主线程上别调:写 UserDefaults 要等主线程上的观察者,
    /// 主线程在这里同步等写盘队列会互相等死(14 章决策 175),退出时用 `flushPendingWrites(timeout:notifying:_:)`。
    public func waitForPendingWrites() {
        lock.withLock { if deferredWritePending { store(load()) } }
        writeQueue.sync {}
    }

    /// 还有没落盘的记账:排着的延后写,或排进写盘队列还没写完的。
    public var hasPendingWrites: Bool {
        lock.withLock { deferredWritePending || finishedWriteCount < queuedWriteCount }
    }

    /// 退出前调:排着的延后写当场排进写盘队列,队列把这之前的写都写完、或过了 `timeout` 秒(先到的那个)时在 `queue` 上调一次
    /// `done`。调用线程不等,主线程上调也不会跟写盘互相等死。见 14 章决策 214。
    public func flushPendingWrites(timeout: TimeInterval, notifying queue: DispatchQueue = .main,
                                   _ done: @escaping @Sendable () -> Void) {
        lock.withLock { if deferredWritePending { store(load()) } }
        let once = FlushOnce()
        writeQueue.async { if once.claim() { queue.async(execute: done) } }
        queue.asyncAfter(deadline: .now() + timeout) { if once.claim() { done() } }
    }

    // 以下都在锁里调。

    private func update(day: String, deferWrite: Bool = false, _ change: (inout TelemetryActivityDay) -> Void) {
        guard acceptsDay()(day) else { return }
        var days = load()
        if let i = days.firstIndex(where: { $0.day == day }) {
            change(&days[i])
        } else {
            var fresh = TelemetryActivityDay(day: day)
            change(&fresh)
            days.append(fresh)
        }
        store(days, deferred: deferWrite)
    }

    /// 还记、还留的日子:不早于 `sentBefore`,也不晚于明天。
    private func acceptsDay() -> (String) -> Bool {
        let latest = Telemetry.day(clock().addingTimeInterval(86_400))
        let sentDay = self.sentDay
        return { day in day <= latest && !(sentDay.map { day < $0 } ?? false) }
    }

    private func load() -> [TelemetryActivityDay] {
        if let cache { return cache }
        let days = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([TelemetryActivityDay].self, from: $0) } ?? []
        cache = days
        return days
    }

    /// 改内存副本,写盘交给 `writeQueue`(见它的注释)。`deferred`:过 `deferredWriteDelay` 再写当时的副本,
    /// 已经排着一次就不再排;这期间有一次当场写就把延后的那次一起带走。
    private func store(_ days: [TelemetryActivityDay], deferred: Bool = false) {
        let accepts = acceptsDay()
        let kept = Array(days.filter { accepts($0.day) }.sorted { $0.day < $1.day }.suffix(Self.maxStoredDays))
        cache = kept
        if deferred {
            guard !deferredWritePending else { return }
            deferredWritePending = true
            writeQueue.asyncAfter(deadline: .now() + Self.deferredWriteDelay) { [weak self] in
                guard let self else { return }
                self.lock.withLock { if self.deferredWritePending { self.store(self.load()) } }
            }
            return
        }
        deferredWritePending = false
        queuedWriteCount += 1
        let data = kept.isEmpty ? nil : try? JSONEncoder().encode(kept)
        let defaults = self.defaults, key = self.key
        writeQueue.async { [weak self] in
            if let data {
                defaults.set(data, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            if let self { self.lock.withLock { self.finishedWriteCount += 1 } }
        }
    }
}

/// `flushPendingWrites` 的写完与超时两条路只有先到的那条调 `done`。
private final class FlushOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
