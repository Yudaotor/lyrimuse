import Foundation

/// 测试期开关的租约表(数据目录下 `lyrimuse-scrobble-hold.json`),`debug/scrobble-hold` 写,引擎 scrobblehold.go 读:
/// 任一条没到期,测试播放就不发 Last.fm / ListenBrainz、不记本地收听日志。字段名、`since` 封顶的算法跟引擎那边一致,
/// 两处一起改。见 12 章决策 98。
public enum ScrobbleHold {
    public static let fileName = "lyrimuse-scrobble-hold.json"

    public struct Lease: Codable, Equatable, Sendable {
        public var id: String
        /// 写入时刻(Unix 秒)。引擎按它封顶:`until` 最晚算到 `since` 加上限。
        public var since: Int64
        public var until: Int64

        public init(id: String, since: Int64, until: Int64) {
            self.id = id
            self.since = since
            self.until = until
        }
    }

    struct File: Codable {
        var holds: [Lease]
    }

    /// 没带 id 的租约记在这个名下。
    public static let defaultID = "manual"

    /// 读出来的租约;读不了、解析不了当没有。
    public static func leases(from data: Data?) -> [Lease] {
        guard let data, let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.holds
    }

    /// 在 `current` 上处理一次深链:`minutes > 0` 加上或换掉 `id` 那一条,0 收掉 `id` 那一条(`id` 为 nil 时全部收掉)。
    /// 顺带丢掉已到期的。
    public static func updated(_ current: [Lease], minutes: Int, id: String?, now: Date) -> [Lease] {
        let nowSecs = Int64(now.timeIntervalSince1970)
        var kept = current.filter { $0.until > nowSecs }
        if minutes <= 0 {
            guard let id else { return [] }
            kept.removeAll { $0.id == id }
            return kept
        }
        let key = id ?? defaultID
        kept.removeAll { $0.id == key }
        let span = Int64(min(minutes, LyrimuseDeepLink.DebugCommand.maxScrobbleHoldMinutes)) * 60
        kept.append(Lease(id: key, since: nowSecs, until: nowSecs + span))
        return kept
    }

    public static func encode(_ leases: [Lease]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(File(holds: leases))
    }
}
