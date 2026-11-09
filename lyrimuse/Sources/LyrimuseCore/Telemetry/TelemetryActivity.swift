import Foundation

/// 心跳里「之前几天的活动」的记账:放过哪些播放器、主线程卡住几次(前几次带概况)、几个动作各做了几次、放过的歌各拿到哪档歌词和是什么语言,按本地自然日一天一格,存在 UserDefaults。
/// 播放源换播放器、看门狗报卡住时各记一笔;`isRecording` 为假(遥测关着)时一律不记。心跳发出去之后
/// `remove(days:)` 删掉发过的那几天。最多留 `maxStoredDays` 天,多了丢最早的。
public final class TelemetryActivity: @unchecked Sendable {
    public static let shared = TelemetryActivity(defaults: .standard)

    public static let storageKey = "np:telemetryActivity"
    public static let maxStoredDays = 3
    /// 每天最多记几次卡顿的概况(次数照记);心跳带最多 `maxStoredDays` 天,负载要在 Worker 的 MAX_BODY 以内。
    public static let maxHangDetailsPerDay = 3

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
    /// 最近记下的那条卡顿概况在哪一天的第几条:恢复时补时长、采样完补调用栈都补到它。只在内存里。
    private var openHang: (day: String, index: Int)?
    /// 今天记过歌词结果的歌(曲目键 → 记下的那一笔)。只在内存里,不写盘、不上报;换天清空。
    private var lyricsNoted: (day: String, songs: [String: LyricsNote]) = ("", [:])

    private struct LyricsNote: Equatable {
        var result: TelemetryLyricsResult
        var language: TelemetrySongLanguage?
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

    /// 一首歌的歌词落定了。同一首一天只算一次;结果变了(补出了逐字、手动换了一份)就把这首那一笔挪到新的那一档。
    /// App 重启后内存里的记录没了,同一天再放到会再算一次。
    public func noteLyricsResult(track: String, result: TelemetryLyricsResult, language: TelemetrySongLanguage?,
                                 now: Date = Date()) {
        let day = Telemetry.day(now)
        let note = LyricsNote(result: result, language: language)
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
                }
                d.lyrics[result.rawValue, default: 0] += 1
                if let language { d.languages[language.rawValue, default: 0] += 1 }
            }
        }
    }

    private static func decrement(_ counts: inout [String: Int], _ key: String) {
        let left = (counts[key] ?? 0) - 1
        counts[key] = left > 0 ? left : nil
    }

    /// 主线程卡住一次。`detail` 给了且当天还没记满,记下概况(播放器填最近一次放歌的那个),之后的 `finishHang` /
    /// `attachHangStack` 补到这一条。
    public func noteHang(_ detail: TelemetryHang? = nil, now: Date = Date()) {
        let day = Telemetry.day(now)
        lock.withLock {
            guard recording else { return }
            openHang = nil
            update(day: day) { d in
                d.hangs += 1
                guard var detail, d.hangDetails.count < Self.maxHangDetailsPerDay else { return }
                if detail.player == nil { detail.player = lastPlayer?.tag }
                d.hangDetails.append(detail)
                openHang = (day, d.hangDetails.count - 1)
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
            guard recording, let open = openHang else { return }
            var days = load()
            guard let i = days.firstIndex(where: { $0.day == open.day }), open.index < days[i].hangDetails.count else { return }
            let before = days[i].hangDetails[open.index]
            change(&days[i].hangDetails[open.index])
            if days[i].hangDetails[open.index] != before { store(days) }
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
