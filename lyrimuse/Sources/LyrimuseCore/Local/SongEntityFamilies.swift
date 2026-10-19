import Foundation

/// 歌曲实体并进「第 N 次收听」的写法族(18 章决策 9)。引擎给每条写法记了所在实体的 id(缓存条目的 `song`);
/// 同一个实体里各写法按现有规则算出的族键(`PlayCountFold.baseFamilyKey`)并成一组,组里的键都指向同一个代表键。
///
/// 只在歌手、歌名两张别名表之上再并,所以族只会变大。一个族键同时出现在两个以上实体里(不同录音的写法折成了同一个键,
/// 比如合唱版归首位之后跟独唱版同名)时分不清是哪一首,不拿它并:不同的歌不会经它连成一族。代表键含汉字 / 假名的优先,
/// 再按字典序,跟歌名别名表挑中文名同一个取向。
public enum SongEntityFamilies {
    public struct Member: Hashable, Sendable {
        public var song: String
        public var familyKey: String

        public init(song: String, familyKey: String) {
            self.song = song
            self.familyKey = familyKey
        }
    }

    /// 旧别名表并起来、录音对不上而撤出来的一块写法:原来所在的族键,撤出后的族键。
    public struct AliasWithdrawal: Hashable, Sendable, Codable {
        public var family: String
        public var key: String

        public init(family: String, key: String) {
            self.family = family
            self.key = key
        }
    }

    /// withdrawals 判两块写法时长对得上的容差(秒)。
    public static let withdrawalToleranceSecs = 2.0

    /// 旧别名表(歌手、歌名两张)并起来、录音却对不上的写法撤出来(18 章决策 19)。同一个族里按 plainFamilyKey 分块;
    /// 两块之间有同一个实体的写法,或者各有一条时长差在 withdrawalToleranceSecs 以内,就算连着。跟族键本身那一块连着的
    /// 留在族里(族键那一块没有时长、或者族键不是哪一块的原始族键时,留写法最多的那一片,一样多取字典序小的);其余有时长的各片撤出去,
    /// 一片成一族,代表键跟 derive 同一个取向。没有时长的块判不了,照旧留在族里。没有实体 id 的写法不进。
    /// 结果按原始族键给:原始族键 → 撤出记录。
    public static func withdrawals(_ entries: [EnrichTitleAliases.Entry], artists: [String: String],
                                   titles: [String: [String: String]]) -> [String: AliasWithdrawal] {
        struct Block { var songs: Set<String> = []; var durations: [Double] = []; var writings = 0 }
        var byFamily: [String: [String: Block]] = [:]
        for e in entries {
            guard let song = e.song, !song.isEmpty else { continue }
            let family = PlayCountFold.baseFamilyKey(artist: e.artist, title: e.title, artists: artists, titles: titles)
            let plain = PlayCountFold.plainFamilyKey(artist: e.artist, title: e.title)
            var block = byFamily[family, default: [:]][plain, default: Block()]
            block.songs.insert(song)
            block.writings += 1
            if let d = e.durationSecs, d > 0 { block.durations.append(d) }
            byFamily[family, default: [:]][plain] = block
        }
        func linked(_ a: Block, _ b: Block) -> Bool {
            !a.songs.isDisjoint(with: b.songs)
                || a.durations.contains { x in b.durations.contains { abs(x - $0) <= withdrawalToleranceSecs } }
        }
        var out: [String: AliasWithdrawal] = [:]
        for (family, blocks) in byFamily where blocks.count > 1 {
            let keys = blocks.keys.sorted()
            var parent = Dictionary(uniqueKeysWithValues: keys.map { ($0, $0) })
            func find(_ k: String) -> String {
                var x = k
                while let p = parent[x], p != x { x = p }
                return x
            }
            for (i, a) in keys.enumerated() {
                for b in keys[(i + 1)...] where linked(blocks[a]!, blocks[b]!) {
                    parent[find(a)] = find(b)
                }
            }
            var pieces: [String: [String]] = [:]
            for k in keys where !blocks[k]!.durations.isEmpty {
                pieces[find(k), default: []].append(k)
            }
            guard pieces.count > 1 else { continue }
            let familyRoot = blocks[family] == nil ? nil : find(family)
            let weight = pieces.mapValues { $0.reduce(0) { $0 + blocks[$1]!.writings } }
            let keep = familyRoot.flatMap { pieces[$0] == nil ? nil : $0 }
                ?? weight.max { a, b in a.value != b.value ? a.value < b.value : pieces[a.key]!.min()! > pieces[b.key]!.min()! }!.key
            for (root, members) in pieces where root != keep {
                let rep = members.min(by: representativePrecedes)!
                for k in members {
                    out[k] = AliasWithdrawal(family: family, key: rep)
                }
            }
        }
        return out
    }

    /// 一组族键里挑代表键:含汉字 / 假名的优先,再按字典序。
    static func representativePrecedes(_ a: String, _ b: String) -> Bool {
        let ha = !PlayCountFold.hasNoHanLikeChars(a), hb = !PlayCountFold.hasNoHanLikeChars(b)
        return ha != hb ? ha : a < b
    }

    /// 旧别名表(歌手、歌名两张)把几种写法并成一族、实体却判成不同歌的地方:同一个族里、不套别名表时族键不同、
    /// 实体 id 也不同的写法。阶段 1 计数族是「实体 ∪ 旧表」,这些照旧并着;列出来逐条过目,确认是旧表并错了再撤(方案 §5.6)。
    /// countKeyOnly:整族按「原始族键(plainFamilyKey)相同或实体相同」就能连成一片,跨实体的是计数键本身并的、不是别名表,
    /// 撤出(withdrawals)管不到(18 章决策 22)。
    public struct AliasOnlyMerge: Equatable, Sendable {
        public struct Writing: Equatable, Sendable {
            public var artist: String
            public var title: String
            public var song: String
        }

        public var familyKey: String
        public var writings: [Writing]
        public var countKeyOnly = false
    }

    public static func aliasOnlyMerges(_ entries: [EnrichTitleAliases.Entry], artists: [String: String],
                                       titles: [String: [String: String]],
                                       withdrawals: [String: AliasWithdrawal] = [:]) -> [AliasOnlyMerge] {
        struct Row { var plain: String; var writing: AliasOnlyMerge.Writing }
        var byFamily: [String: [Row]] = [:]
        let regroup = withdrawals.mapValues(\.key)
        for e in entries {
            guard let song = e.song, !song.isEmpty else { continue }
            let family = PlayCountFold.baseFamilyKey(artist: e.artist, title: e.title, artists: artists, titles: titles,
                                                     withdrawals: regroup)
            let plain = PlayCountFold.plainFamilyKey(artist: e.artist, title: e.title)
            byFamily[family, default: []].append(Row(plain: plain, writing: .init(artist: e.artist, title: e.title, song: song)))
        }
        // 原始族键相同或实体相同的写法连起来,看整族是不是一片。
        func onePiece(_ rows: [Row]) -> Bool {
            var parent = Array(rows.indices)
            func find(_ x: Int) -> Int {
                var x = x
                while parent[x] != x { x = parent[x] }
                return x
            }
            for i in rows.indices {
                for j in rows.indices where j > i && (rows[i].plain == rows[j].plain || rows[i].writing.song == rows[j].writing.song) {
                    parent[find(i)] = find(j)
                }
            }
            return Set(rows.indices.map(find)).count == 1
        }
        var out: [AliasOnlyMerge] = []
        for (family, rows) in byFamily {
            let split = rows.contains { x in rows.contains { y in x.plain != y.plain && x.writing.song != y.writing.song } }
            guard split else { continue }
            let writings = rows.map(\.writing).sorted { ($0.song, $0.artist, $0.title) < ($1.song, $1.artist, $1.title) }
            out.append(AliasOnlyMerge(familyKey: family, writings: writings, countKeyOnly: onePiece(rows)))
        }
        return out.sorted { $0.familyKey < $1.familyKey }
    }

    /// aliasOnlyMerges 的结果写成给人看的文本(诊断包里的 song-entity-alias-gaps.txt):别名表并的、计数键本身并的各一节,
    /// 后面接着列撤出来的写法块。
    public static func aliasOnlyMergesText(_ merges: [AliasOnlyMerge], withdrawals: [String: AliasWithdrawal] = [:]) -> String {
        let byAlias = merges.filter { !$0.countKeyOnly }, byKey = merges.filter(\.countKeyOnly)
        var lines = ["旧别名表并着、实体判成不同歌的写法族 \(byAlias.count) 个(计数照旧按旧表并着,逐条过目;见 18 章决策 11)", ""]
        func list(_ ms: [AliasOnlyMerge]) {
            for m in ms {
                lines.append(m.familyKey)
                for w in m.writings {
                    lines.append("  \(w.song)  \(w.artist) | \(w.title)")
                }
            }
        }
        list(byAlias)
        lines += ["", "计数键本身并着、实体判成不同歌的写法族 \(byKey.count) 个(只按原始族键和实体就连成一片,撤出管不到,要等计数按实体算;见 18 章决策 22)", ""]
        list(byKey)
        lines += ["", "旧别名表并着、录音对不上撤出来的写法块 \(withdrawals.count) 个(原始族键:原来的族 → 撤出后的族;见 18 章决策 19)", ""]
        for (plain, w) in withdrawals.sorted(by: { ($0.value.family, $0.key) < ($1.value.family, $1.key) }) {
            lines.append("  \(plain):\(w.family) → \(w.key)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 结果只含不是代表的那些键:族键 → 代表键。没有并上什么时是空表。
    public static func derive(_ members: [Member]) -> [String: String] {
        var songsOf: [String: Set<String>] = [:]
        for m in members where !m.song.isEmpty && !m.familyKey.isEmpty {
            songsOf[m.familyKey, default: []].insert(m.song)
        }
        // 只属于一个实体的族键按实体分组;被几个实体共用的不进任何一组。
        var groups: [String: [String]] = [:]
        for (k, songs) in songsOf where songs.count == 1 {
            groups[songs.first!, default: []].append(k)
        }
        var out: [String: String] = [:]
        for group in groups.values where group.count > 1 {
            let rep = group.min(by: representativePrecedes)!
            for k in group where k != rep {
                out[k] = rep
            }
        }
        return out
    }
}
