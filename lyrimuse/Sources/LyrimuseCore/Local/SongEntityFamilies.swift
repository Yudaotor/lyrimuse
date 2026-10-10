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

    /// 旧别名表(歌手、歌名两张)把几种写法并成一族、实体却判成不同歌的地方:同一个族里、不套别名表时族键不同、
    /// 实体 id 也不同的写法。阶段 1 计数族是「实体 ∪ 旧表」,这些照旧并着;列出来逐条过目,确认是旧表并错了再撤(方案 §5.6)。
    public struct AliasOnlyMerge: Equatable, Sendable {
        public struct Writing: Equatable, Sendable {
            public var artist: String
            public var title: String
            public var song: String
        }

        public var familyKey: String
        public var writings: [Writing]
    }

    public static func aliasOnlyMerges(_ entries: [EnrichTitleAliases.Entry], artists: [String: String],
                                       titles: [String: [String: String]]) -> [AliasOnlyMerge] {
        struct Row { var plain: String; var writing: AliasOnlyMerge.Writing }
        var byFamily: [String: [Row]] = [:]
        for e in entries {
            guard let song = e.song, !song.isEmpty else { continue }
            let family = PlayCountFold.baseFamilyKey(artist: e.artist, title: e.title, artists: artists, titles: titles)
            let plain = PlayCountFold.baseFamilyKey(artist: e.artist, title: e.title, artists: [:], titles: [:])
            byFamily[family, default: []].append(Row(plain: plain, writing: .init(artist: e.artist, title: e.title, song: song)))
        }
        var out: [AliasOnlyMerge] = []
        for (family, rows) in byFamily {
            let split = rows.contains { x in rows.contains { y in x.plain != y.plain && x.writing.song != y.writing.song } }
            guard split else { continue }
            let writings = rows.map(\.writing).sorted { ($0.song, $0.artist, $0.title) < ($1.song, $1.artist, $1.title) }
            out.append(AliasOnlyMerge(familyKey: family, writings: writings))
        }
        return out.sorted { $0.familyKey < $1.familyKey }
    }

    /// aliasOnlyMerges 的结果写成给人看的文本(诊断包里的 song-entity-alias-gaps.txt)。
    public static func aliasOnlyMergesText(_ merges: [AliasOnlyMerge]) -> String {
        var lines = ["旧别名表并着、实体判成不同歌的写法族 \(merges.count) 个(计数照旧按旧表并着,逐条过目;见 18 章决策 11)", ""]
        for m in merges {
            lines.append(m.familyKey)
            for w in m.writings {
                lines.append("  \(w.song)  \(w.artist) | \(w.title)")
            }
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
            let rep = group.min { a, b in
                let ha = !PlayCountFold.hasNoHanLikeChars(a), hb = !PlayCountFold.hasNoHanLikeChars(b)
                return ha != hb ? ha : a < b
            }!
            for k in group where k != rep {
                out[k] = rep
            }
        }
        return out
    }
}
