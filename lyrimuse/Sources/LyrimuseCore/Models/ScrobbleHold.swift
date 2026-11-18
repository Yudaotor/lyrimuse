import Foundation

/// 测试期开关的租约表(数据目录下 `lyrimuse-scrobble-hold.json`),`debug/scrobble-hold` 写,引擎 scrobblehold.go 读:
/// 任一条没到期,测试播放就不发 Last.fm / ListenBrainz、不记本地收听日志、不推网页中继。字段名、`since` 封顶的算法跟引擎那边一致,
/// 两处一起改。App 这边按同一套判定(租约 + 测试曲名单)挡 Discord「正在听」。见 12 章决策 98、99。
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

    /// 此刻开着的租约里最晚的到期时刻;没开着为 nil。跟引擎 `scrobbleHoldUntil` 同一个算法:没写 `since`、`since` 在一分钟以后的
    /// 不认,`until` 最晚算到 `since` 加上限。两侧跑 `shared/testdata/scrobble-hold` 的同一批样例。
    public static func activeUntil(_ leases: [Lease], now: Date) -> Date? {
        let nowSecs = now.timeIntervalSince1970
        let maxSecs = Int64(LyrimuseDeepLink.DebugCommand.maxScrobbleHoldMinutes) * 60
        var latest: Int64?
        for lease in leases where lease.since > 0 && Double(lease.since) <= nowSecs + 60 {
            let until = min(lease.until, lease.since + maxSecs)
            if nowSecs < Double(until), until > (latest ?? .min) { latest = until }
        }
        return latest.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// 歌手是合成测试曲专用的写法(名单 `testArtistPrefixes` / `testArtists`,生成自 `shared/test-tracks.json`),
    /// 或者歌手为空、歌名整串等于没写歌手标签的测试素材(`testUntaggedTitles`)。
    /// 去首尾空白、不分大小写,前缀或整串比对,不做子串;跟引擎 `isTestTrack` 同一口径。
    public static func isTestTrack(artist: String, title: String) -> Bool {
        let a = normalized(artist)
        guard !a.isEmpty else {
            let t = normalized(title)
            return !t.isEmpty && normalizedUntaggedTitles.contains(t)
        }
        return normalizedPrefixes.contains { !$0.isEmpty && a.hasPrefix($0) } || normalizedArtists.contains(a)
    }

    private static func normalized(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private static let normalizedPrefixes = testArtistPrefixes.map(normalized)
    private static let normalizedArtists = Set(testArtists.map(normalized))
    private static let normalizedUntaggedTitles = Set(testUntaggedTitles.map(normalized))

    /// 按曲目棘轮的判定,跟引擎按会话的 `heldForTest` 同一个形状:这一首第一次判成测试播放(名单命中或开关开着)之后一直算,
    /// 开关中途到期或被收掉也不回落;换了一首重新判。
    public struct TrackGate: Sendable {
        public private(set) var heldTrack: String?

        public init() {}

        public mutating func isHeld(track: String, artist: String, title: String, leases: [Lease], now: Date) -> Bool {
            if heldTrack == track { return true }
            heldTrack = nil
            guard ScrobbleHold.isTestTrack(artist: artist, title: title) || ScrobbleHold.activeUntil(leases, now: now) != nil else {
                return false
            }
            heldTrack = track
            return true
        }
    }

    public static func encode(_ leases: [Lease]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(File(holds: leases))
    }
}
