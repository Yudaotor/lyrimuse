import Foundation

/// 心跳里「之前几天的活动」的记账:放过哪些播放器、主线程卡住几次、几个动作各做了几次,按本地自然日一天一格,存在 UserDefaults。
/// 播放源换播放器、看门狗报卡住时各记一笔;`isRecording` 为假(遥测关着)时一律不记。心跳发出去之后
/// `remove(days:)` 删掉发过的那几天。最多留 `maxStoredDays` 天,多了丢最早的。
public final class TelemetryActivity: @unchecked Sendable {
    public static let shared = TelemetryActivity(defaults: .standard)

    public static let storageKey = "np:telemetryActivity"
    public static let maxStoredDays = 3

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var recording = false
    private var trusted: Set<String> = []
    /// 上一次记下的播放器,同一个播放器连着报不重复写盘。
    private var lastPlayer: (day: String, tag: String)?

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

    public func noteHang(now: Date = Date()) {
        let day = Telemetry.day(now)
        lock.withLock {
            guard recording else { return }
            update(day: day) { $0.hangs += 1 }
        }
    }

    /// 今天之前记下的几天,按日期升序。
    public func completedDays(before today: String) -> [TelemetryActivityDay] {
        lock.withLock { load().filter { $0.day < today } }
    }

    public func remove(days: [String]) {
        lock.withLock {
            let drop = Set(days)
            save(load().filter { !drop.contains($0.day) })
        }
    }

    /// 遥测关掉时清空记下的全部活动。
    public func clear() {
        lock.withLock {
            lastPlayer = nil
            defaults.removeObject(forKey: key)
        }
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
        save(days)
    }

    private func load() -> [TelemetryActivityDay] {
        guard let data = defaults.data(forKey: key),
              let days = try? JSONDecoder().decode([TelemetryActivityDay].self, from: data) else { return [] }
        return days
    }

    private func save(_ days: [TelemetryActivityDay]) {
        let kept = Array(days.sorted { $0.day < $1.day }.suffix(Self.maxStoredDays))
        if kept.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: key)
        }
    }
}
