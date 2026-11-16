import Foundation

/// 心跳里「之前几天的活动」的记账:放过哪些播放器、主线程卡住几次(前几次带概况)、几个动作各做了几次、放过的歌各拿到哪档歌词、显示的那份来自哪个源、是什么语言,按本地自然日一天一格,存在 UserDefaults。
/// 播放源换播放器、看门狗报卡住时各记一笔;`isRecording` 为假(遥测关着)时一律不记。心跳发出去之后
/// `remove(days:)` 删掉发过的那几天。最多留 `maxStoredDays` 天,多了丢最早的。
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

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    /// 写盘走这条串行队列,不持 `lock`:UserDefaults 写入会同步等主线程上的观察者处理完,持着 `lock` 写的话,主线程这时来拿
    /// `lock`(读 `isRecording`)就互相等死,主线程看门狗记卡顿时就是这样卡死的(14 章决策 175)。别把写盘挪回锁里。
    private let writeQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.telemetry-activity-write")
    /// 记下的几天的内存副本,读都走它;nil = 还没从磁盘读过。
    private var cache: [TelemetryActivityDay]?
    private var recording = false
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

    public init(defaults: UserDefaults, key: String = TelemetryActivity.storageKey) {
        self.defaults = defaults
        self.key = key
    }

    public var isRecording: Bool {
        get { lock.withLock { recording } }
        set { lock.withLock { recording = newValue } }
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
            update(day: day) { $0.actions[action.rawValue, default: 0] += 1 }
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
                d.lyrics[result.rawValue, default: 0] += 1
                if let language { d.languages[language.rawValue, default: 0] += 1 }
                if let key = note.sourceKey { d.lyricSources[key, default: 0] += 1 }
            }
        }
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
                d.hangs += 1
                if throttled { d.throttledHangs += 1 }
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
    /// 当天已经记满 `maxLayoutLimitsPerDay` 种时新的一种不记。
    public func noteLayoutLimit(window: String?, windowClass: String, pass: String, now: Date = Date()) {
        let day = Telemetry.day(now)
        lock.withLock {
            guard recording else { return }
            update(day: day) { d in
                if let i = d.layoutLimits.firstIndex(where: { $0.window == window && $0.windowClass == windowClass && $0.pass == pass }) {
                    d.layoutLimits[i].count = min(d.layoutLimits[i].count + 1, 10_000)
                } else if d.layoutLimits.count < Self.maxLayoutLimitsPerDay {
                    d.layoutLimits.append(TelemetryLayoutLimit(window: window, windowClass: windowClass, pass: pass, count: 1))
                }
            }
        }
    }

    /// 最近那次卡顿恢复了,一共卡了 `seconds` 秒。
    public func finishHang(seconds: TimeInterval) {
        changeOpenHang { $0.duration = TelemetryHang.durationBucket(seconds: seconds) }
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
        lock.withLock { load().filter { $0.day < today } }
    }

    public func remove(days: [String]) {
        lock.withLock {
            let drop = Set(days)
            store(load().filter { !drop.contains($0.day) })
        }
    }

    /// 遥测关掉时清空记下的全部活动。
    public func clear() {
        lock.withLock {
            lastPlayer = nil
            openHang = nil
            lyricsNoted = ("", [:])
            store([])
        }
    }

    /// 等排着的写盘都落地(测试读磁盘前用)。
    public func waitForPendingWrites() {
        writeQueue.sync {}
    }

    // 以下都在锁里调。

    private func update(day: String, _ change: (inout TelemetryActivityDay) -> Void) {
        var days = load()
        if let i = days.firstIndex(where: { $0.day == day }) {
            change(&days[i])
        } else {
            var fresh = TelemetryActivityDay(day: day)
            change(&fresh)
            days.append(fresh)
        }
        store(days)
    }

    private func load() -> [TelemetryActivityDay] {
        if let cache { return cache }
        let days = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([TelemetryActivityDay].self, from: $0) } ?? []
        cache = days
        return days
    }

    /// 改内存副本,写盘交给 `writeQueue`(见它的注释)。
    private func store(_ days: [TelemetryActivityDay]) {
        let kept = Array(days.sorted { $0.day < $1.day }.suffix(Self.maxStoredDays))
        cache = kept
        let data = kept.isEmpty ? nil : try? JSONEncoder().encode(kept)
        let defaults = self.defaults, key = self.key
        writeQueue.async {
            if let data {
                defaults.set(data, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
