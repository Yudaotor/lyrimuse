import Foundation

/// 歌词管理「同一首歌的其它写法」(18 章决策 28):同一首歌(缓存条目的 `song` 相同)的其它写法、它们跟这条之间的证据、
/// 是不是同一个共享组,以及用户拆开过的写法。拆开、恢复合并走引擎的请求通道(`split_song` / `unsplit_song`),这里只读:
/// 实体表 `lyrimuse-song-entities.json`(证据)和用户判断文件 `lyrimuse-song-entity-user.json`(`user_splits`)都只有引擎写。
public enum SongVersions {
    /// 一条写法在哪个实体、哪个共享组。
    public struct Membership: Equatable, Sendable {
        public let song: String
        public let share: Int

        public init(song: String, share: Int) {
            self.song = song
            self.share = share
        }
    }

    /// 实体表里的一条证据边(两端是写法键)。
    public struct Edge: Equatable, Sendable {
        public let kind: String
        public let a: String
        public let b: String

        public init(kind: String, a: String, b: String) {
            self.kind = kind
            self.a = a
            self.b = b
        }
    }

    public struct Row: Equatable, Sendable {
        public let key: String
        /// 跟这条在同一个共享组:自动选的歌词共用一份。
        public let sharesLyrics: Bool
        /// 跟这条直接相连的证据种类,按 `evidenceOrder` 排、去重;空的是经由别的写法连着。
        public let evidence: [String]
    }

    public struct SplitRow: Equatable, Sendable {
        /// 拆开过的另一边那条写法。
        public let key: String
        /// 恢复合并交给引擎的写法:两边各自所在实体的全部写法,按键排序。
        public let mergeKeys: [String]
    }

    public struct Listing: Equatable, Sendable {
        public let song: String
        public let rows: [Row]
        public let splits: [SplitRow]

        public var isEmpty: Bool { rows.isEmpty && splits.isEmpty }
    }

    /// 证据种类的显示顺序:强证据在前,检索 id、写法族、歌词、登记名字在后。跟引擎 songEvidenceKinds 的种类一一对应,
    /// 引擎加了种类这里跟着加(SongVersionsTests 拿引擎源码核对)。
    public static let evidenceOrder = [
        "isrc", "mb_recording", "spotify_track", "amazon_asin", "kkbox_song", "soda_track", "youtube_video",
        "apple_song", "netease_song", "qq_song", "family", "lyrics", "apple_name", "netease_name",
    ]

    public static let tableURL = LyrimusePaths.configFile("lyrimuse-song-entities.json")
    public static let userURL = LyrimusePaths.configFile("lyrimuse-song-entity-user.json")

    /// key 这条的列表;它没有实体 id 时是 nil。memberships 是写法 → 实体与共享组(没有实体 id 的不放),
    /// edges 是实体表里含这条的那首歌的证据边,splits 是用户判断文件里的写法对。
    public static func listing(key: String, memberships: [String: Membership], edges: [Edge],
                               splits: [[String]]) -> Listing? {
        guard let own = memberships[key], !own.song.isEmpty else { return nil }
        var members: [String: [String]] = [:]
        for (k, m) in memberships where !m.song.isEmpty {
            members[m.song, default: []].append(k)
        }
        let mine = (members[own.song] ?? []).sorted()
        var kinds: [String: Set<String>] = [:]
        for e in edges {
            if e.a == key { kinds[e.b, default: []].insert(e.kind) }
            if e.b == key { kinds[e.a, default: []].insert(e.kind) }
        }
        let rows = mine.filter { $0 != key }.map { k in
            Row(key: k, sharesLyrics: memberships[k]?.share == own.share,
                evidence: evidenceOrder.filter { kinds[k]?.contains($0) == true }
                    + (kinds[k] ?? []).filter { !evidenceOrder.contains($0) }.sorted())
        }
        let inside = Set(mine)
        var seen: Set<String> = []
        var splitRows: [SplitRow] = []
        for pair in splits where pair.count == 2 {
            let (x, y) = (pair[0], pair[1])
            let other: String
            switch (inside.contains(x), inside.contains(y)) {
            case (true, false): other = y
            case (false, true): other = x
            default: continue
            }
            guard let m = memberships[other], seen.insert(other).inserted else { continue }
            let theirs = m.song.isEmpty ? [other] : (members[m.song] ?? [other])
            splitRows.append(SplitRow(key: other, mergeKeys: Array(inside.union(theirs)).sorted()))
        }
        splitRows.sort { $0.key < $1.key }
        return Listing(song: own.song, rows: rows, splits: splitRows)
    }

    /// 实体表里含 key 这条写法的那首歌的证据边。文件缺了、坏了、没收这条时是空的(实体表每次建表才写,刚拆开的写法要等
    /// 下一次建表)。
    public static func edges(tableData: Data, key: String) -> [Edge] {
        guard let root = try? JSONSerialization.jsonObject(with: tableData) as? [String: Any],
              let songs = root["songs"] as? [String: Any] else { return [] }
        for case let rec as [String: Any] in songs.values {
            guard let variants = rec["variants"] as? [String], variants.contains(key) else { continue }
            let raw = rec["evidence"] as? [[String: Any]] ?? []
            return raw.compactMap { e in
                guard let kind = e["kind"] as? String, let a = e["a"] as? String, let b = e["b"] as? String else { return nil }
                return Edge(kind: kind, a: a, b: b)
            }
        }
        return []
    }

    /// 用户判断文件里的拆开记录;文件缺了、坏了时是空的。
    public static func splits(userData: Data) -> [[String]] {
        guard let root = try? JSONSerialization.jsonObject(with: userData) as? [String: Any],
              let raw = root["user_splits"] as? [[String]] else { return [] }
        return raw.filter { $0.count == 2 && !$0[0].isEmpty && !$0[1].isEmpty && $0[0] != $0[1] }
    }
}
