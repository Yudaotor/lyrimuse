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
        "apple_song", "netease_song", "qq_song", "family", "bare_title", "lyrics", "apple_name", "netease_name",
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

    /// 一条写法在歌词窗口里显示的行(文字和行首时间)。走播放引擎同一条路(`LyricsSyncEngine.load` → `allLines`),跟歌词窗口
    /// 一致:抬头、署名、声明不显示,演唱者标注(`周杰伦：` `v1：`)剥掉、独占一行的整行不算,同一时间的几行拼成一行;空行不算。
    /// 时间是实际生效的(减去歌词自带的 `[offset:]`),按 0.01 秒取整:对比表只显示到这一位,逐字歌词的行首是毫秒,差几毫秒
    /// 看不出来。title / artist 是这条写法的歌名、歌手,aliases 是同曲条目里别的写法的,都拿来认抬头。
    public struct Shown: Equatable {
        /// 只交整行歌词时显示的行。
        public let lines: [LyricLine]
        /// 带上逐字歌词时显示的行;没有逐字歌词、或者引擎嫌逐字行太少退回整行时为空。
        public let words: [LyricLine]

        public init(lines: [LyricLine], words: [LyricLine]) {
            self.lines = lines
            self.words = words
        }

        /// 参与比对的那一份:整行的,整行一句都没有时用逐字的。
        public var text: [LyricLine] { lines.isEmpty ? words : lines }
    }

    public static func displayed(lyrics: String, yrc: String, title: String, artist: String,
                                 aliases: [LRCParser.HeaderIdentity] = []) -> Shown {
        let embedded = LRCParser.parseOffsetMs(lyrics)
        let offsetMs = embedded != 0 ? embedded : LRCParser.parseOffsetMs(yrc)
        func lines(yrc: String) -> [LyricLine] {
            let engine = LyricsSyncEngine()
            engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, trackTitle: title, trackArtist: artist,
                        headerAliases: aliases, romanizationScripts: [])
            let all = engine.allLines(idPrefix: "")
            if !yrc.isEmpty, all.first?.line.words == nil { return [] }
            return all.compactMap { row in
                let text = row.line.plainText ?? ""
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return LyricLine(timeMs: (row.timeMs - offsetMs) / 10 * 10, text: text)
            }
        }
        return Shown(lines: lines(yrc: ""), words: yrc.isEmpty ? [] : lines(yrc: yrc))
    }

    /// 所选条目的歌词跟当前条目比的结论(18 章决策 73)。
    public enum LyricsMatch: Equatable, Sendable {
        /// 显示出来的字和行时间都一样(整行、逐字两份都比;逐字里每个字的时间不比)。
        case identical
        /// 词一样:按字对齐没有对不上的字、也没有只一边有的句子(`LyricsCandidateComparison`)。标点、空格、大小写、繁简
        /// 写法、分行不同都算词一样;时间差不算进来,在对比小结和那一行的时间上另说。
        case sameText
        case different
    }

    /// 逐行对比的一块:两边各是连续的几句(一边一句、另一边几句就是分行不同);只有一边有的那块,另一边是空的。
    public struct LyricBlock: Equatable {
        public enum Kind: Equatable, Sendable {
            case same, resegmented, changed, onlyCurrent, onlyOther
        }

        public let kind: Kind
        public let current: [LyricLine]
        public let other: [LyricLine]
        /// 跟 current / other 一一对应:那一句里对不上的字(按 `Character` 下标)。
        public let currentMarks: [Set<Int>]
        public let otherMarks: [Set<Int>]
        /// 块开头那句所选条目比当前条目晚多少毫秒,差超过 `LyricsCandidateComparison.retimeThresholdMs` 才有。
        public let deltaMs: Int?

        /// 有字对不上,或者只有一边有。
        public var differs: Bool { kind == .changed || kind == .onlyCurrent || kind == .onlyOther }
    }

    public struct LyricComparison: Equatable {
        public let match: LyricsMatch
        public let blocks: [LyricBlock]
        public let summary: LyricsCandidateComparison.Summary
        /// 字全对得上的那些块里,所选条目比当前条目晚多少毫秒的中位数;没有这样的块时为 nil。
        public let shiftMs: Int?

        /// 只有所选条目有的句数。
        public var extraLines: Int { blocks.filter { $0.kind == .onlyOther }.count }
        /// 只有当前条目有的句数。
        public var missingLines: Int { blocks.filter { $0.kind == .onlyCurrent }.count }
    }

    /// 所选条目(other)的歌词跟当前条目比:按字对齐(`LyricsCandidateComparison.align`,跟「搜索候选歌词」的对照同一套),
    /// 各家分行不同、繁简写法不同、标点空格不同都不算改了字。当前条目放在 candidate 那一边:它一句一块,所选条目同一块的
    /// 几句并进这一块。
    public static func compareLyrics(current: Shown, other: Shown) -> LyricComparison {
        let a = current.text, b = other.text
        func lines(_ shown: [LyricLine]) -> [LyricsCandidateComparison.Line] {
            shown.map { LyricsCandidateComparison.Line(timeMs: $0.timeMs, text: $0.text) }
        }
        let pairs = LyricsCandidateComparison.align(candidate: lines(a), current: lines(b))
        var blocks: [LyricBlock] = []
        var shifts: [Int] = []
        for pair in pairs {
            if pair.continuation, let last = blocks.last, let i = pair.candidate {
                blocks[blocks.count - 1] = LyricBlock(kind: last.kind, current: last.current + [a[i]], other: last.other,
                                                       currentMarks: last.currentMarks + [pair.candidateMarks],
                                                       otherMarks: last.otherMarks, deltaMs: last.deltaMs)
                continue
            }
            let kind: LyricBlock.Kind
            switch pair.kind {
            case .same: kind = .same
            case .resegmented: kind = .resegmented
            case .changed: kind = .changed
            case .onlyCandidate: kind = .onlyCurrent
            case .onlyCurrent: kind = .onlyOther
            }
            let mine = pair.candidate.map { [a[$0]] } ?? []
            let theirs = pair.current.map { b[$0] }
            if kind == .same || kind == .resegmented, let x = mine.first, let y = theirs.first {
                shifts.append(y.timeMs - x.timeMs)
            }
            blocks.append(LyricBlock(kind: kind, current: mine, other: theirs,
                                     currentMarks: pair.candidate == nil ? [] : [pair.candidateMarks],
                                     otherMarks: pair.currentMarks, deltaMs: pair.deltaMs.map { -$0 }))
        }
        shifts.sort()
        let summary = LyricsCandidateComparison.summary(pairs)
        let match: LyricsMatch
        if a.isEmpty || b.isEmpty {
            match = .different
        } else if current == other {
            match = .identical
        } else {
            match = summary.changed == 0 && summary.onlyCandidate == 0 && summary.onlyCurrent == 0 ? .sameText : .different
        }
        return LyricComparison(match: match, blocks: blocks, summary: summary,
                               shiftMs: shifts.isEmpty ? nil : shifts[shifts.count / 2])
    }
}
