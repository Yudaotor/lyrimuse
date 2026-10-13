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

    /// 实体表里的一条证据边(两端是写法键)。countOnly:只用来合并播放次数、不让歌词共用(引擎 `count_only`)。
    public struct Edge: Equatable, Sendable {
        public let kind: String
        public let a: String
        public let b: String
        public let countOnly: Bool

        public init(kind: String, a: String, b: String, countOnly: Bool = false) {
            self.kind = kind
            self.a = a
            self.b = b
            self.countOnly = countOnly
        }
    }

    /// 强证据的种类(播放器或目录直接给的 id):跟引擎 songEvidenceKinds 里 `strong: true` 的那几种一致。
    public static let strongKinds: Set<String> = [
        "isrc", "mb_recording", "spotify_track", "amazon_asin", "kkbox_song", "soda_track", "youtube_video",
        "apple_song_player", "netease_song_player", "qq_song_player", "kugou_song_player",
    ]

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

    /// 判两份手改用的一条写法:手改标记、副本的原件、采纳指纹,和完整的主歌词与逐字歌词。
    public struct ManualCandidate: Equatable, Sendable {
        public let key: String
        public let manual: Bool
        public let origin: String
        public let pickSHA: String?
        public let lyrics: String
        public let yrc: String

        public init(key: String, manual: Bool, origin: String, pickSHA: String?, lyrics: String, yrc: String) {
            self.key = key
            self.manual = manual
            self.origin = origin
            self.pickSHA = pickSHA
            self.lyrics = lyrics
            self.yrc = yrc
        }

        /// 手改原件:手改过或者采纳的那一份还在,有正文,不是同步来的副本。跟引擎 songShareManualOriginal 同一判据。
        public var isOriginal: Bool {
            origin.isEmpty && !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (manual || ManualPickLock.state(sha: pickSHA, lyrics: lyrics) == .original)
        }
    }

    /// 同一首歌的这几条写法里,手改原件的内容不止一份时返回这些原件的键(按键排);一份或没有时是空的。引擎遇到这种情况
    /// 不替用户选,同一首歌的其他写法不跟着任何一份同步(18 章决策 31)。
    public static func manualConflict(_ members: [ManualCandidate]) -> [String] {
        let originals = members.filter(\.isOriginal)
        let contents = Set(originals.map { $0.lyrics + "\u{1}" + $0.yrc })
        return contents.count > 1 ? originals.map(\.key).sorted() : []
    }

    /// 证据种类的显示顺序:强证据在前,检索 id、写法族、歌词、登记名字在后。跟引擎 songEvidenceKinds 的种类一一对应,
    /// 引擎加了种类这里跟着加(SongVersionsTests 拿引擎源码核对)。
    public static let evidenceOrder = [
        "isrc", "mb_recording", "spotify_track", "amazon_asin", "kkbox_song", "soda_track", "youtube_video",
        "apple_song_player", "netease_song_player", "qq_song_player", "kugou_song_player",
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
                return Edge(kind: kind, a: a, b: b, countOnly: e["count_only"] as? Bool ?? false)
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

// MARK: - 收录的播放器、歌词逐句对照(18 章决策 38)

extension SongVersions {
    /// 这条写法是哪些播放器收录的(bundle id):引擎记下的 `players`;没记时从播放器自己给的那几样 id 推断,inferred 为 true。
    /// 两样都没有时是空的。引擎启动时会按同一张表把这几样 id 补进 `players`(enrich.go playerIDFields),两处同步改;
    /// 这里的推断只在引擎还没补上时用到。
    public static func players(entry: [String: Any]) -> (bundleIDs: [String], inferred: Bool) {
        if let noted = entry["players"] as? [String], !noted.isEmpty { return (noted, false) }
        func has(_ field: String) -> Bool { !((entry[field] as? String) ?? "").isEmpty }
        var out: [String] = []
        if has("spotify_track_id") { out.append(PlaybackPlayer.spotify.bundleIdentifier) }
        if has("kkbox_url") { out.append(PlaybackPlayer.kkbox.bundleIdentifier) }
        if has("amazon_url") { out.append(PlaybackPlayer.amazonMusic.bundleIdentifier) }
        if has("soda_url") { out.append(PlaybackPlayer.soda.bundleIdentifier) }
        if has("youtube_music_url") { out.append(PlaybackPlayer.kaset.bundleIdentifier) }
        return (out, !out.isEmpty)
    }

    /// 播放器原样报的一份写法(引擎条目的 `reported`,跟写法键不一样时才记,18 章决策 50)。
    public struct ReportedName: Equatable, Sendable {
        public let bundleID: String
        public let title: String
        public let artist: String
        public let album: String
    }

    /// 条目里各播放器原样报的写法,按 bundle id 排;没有为空。
    public static func reportedNames(entry: [String: Any]) -> [ReportedName] {
        guard let raw = entry["reported"] as? [String: Any] else { return [] }
        return raw.keys.sorted().compactMap { bundleID in
            guard let r = raw[bundleID] as? [String: Any] else { return nil }
            return ReportedName(bundleID: bundleID, title: r["title"] as? String ?? "", artist: r["artist"] as? String ?? "",
                                album: r["album"] as? String ?? "")
        }
    }

    /// 一份歌词里会显示出来的行:去掉开头的抬头(「歌名 - 歌手」)、署名和声明这类行,跟歌词窗口同一套过滤
    /// (LyricsSyncEngine.creditLineDropDecisions;title / artist 是这条写法的歌名、歌手,aliases 是同曲条目里别的写法的,都拿来
    /// 认抬头),再去掉空行。wordTimed 时 text 是逐字歌词,先摊成每行「行首时间 + 这一行的字」(LyricsWordTimingEdit.editableText)
    /// 再过滤。
    public static func displayedLines(_ text: String, title: String, artist: String, aliases: [LRCParser.HeaderIdentity] = [],
                                      wordTimed: Bool = false) -> [LyricLine] {
        let lrc = wordTimed ? LyricsWordTimingEdit.editableText(yrc: text) : text
        let parsed = LRCParser.parse(lrc)
        let texts = parsed.map(\.text)
        var tags = LRCParser.headerTags(text)
        tags.aliases = aliases
        let drop = LyricsSyncEngine.creditLineDropDecisions(
            texts, trackTitle: title, trackArtist: artist, tags: tags,
            speakerExemptions: LyricDuet.speakers(in: texts))
        return zip(parsed, drop).compactMap { line, dropped in
            dropped || line.text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : line
        }
    }

    /// 两份歌词(displayedLines 过滤过的行)逐句对照:按句子的先后一一对齐,文字不同或一边没有的那一行标 differs。shiftMs 是
    /// 文字相同的那些行里 other 比 current 晚多少毫秒的中位数,没有文字相同的行时为 nil。
    public struct LyricDiff: Equatable {
        public struct Row: Equatable {
            public let current: LyricLine?
            public let other: LyricLine?
            public let differs: Bool
        }
        public let rows: [Row]
        public let differentLines: Int
        public let shiftMs: Int?
    }

    public static func lyricDiff(current a: [LyricLine], other b: [LyricLine]) -> LyricDiff {
        var rows: [LyricDiff.Row] = []
        var shifts: [Int] = []
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : nil, y = i < b.count ? b[i] : nil
            let same = x != nil && y != nil
                && x!.text.trimmingCharacters(in: .whitespaces) == y!.text.trimmingCharacters(in: .whitespaces)
            if same { shifts.append(y!.timeMs - x!.timeMs) }
            rows.append(LyricDiff.Row(current: x, other: y, differs: !same))
        }
        shifts.sort()
        return LyricDiff(rows: rows, differentLines: rows.filter(\.differs).count,
                         shiftMs: shifts.isEmpty ? nil : shifts[shifts.count / 2])
    }
}
