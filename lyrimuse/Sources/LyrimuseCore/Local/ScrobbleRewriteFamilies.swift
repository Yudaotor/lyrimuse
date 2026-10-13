import Foundation

/// 智能档上送的写法并进「第 N 次收听」的写法族(12 章决策 73)。引擎上送前按 Last.fm 编目条目改写歌手和曲名,之后这首歌的
/// 收听记在改写后的写法下;改写后的写法跟本机写法按歌手、歌名两张别名表和实体那一层折不到一族时(别名表不认得改写后的
/// 歌手名),那些收听不算进这首。这一层按引擎的编目结论把两边的族键并起来,接在实体那一层之后。
///
/// 跟实体那一层一样只并不拆,也一样保守:一个上送写法连着两个以上本机族时分不清是哪一首,不并;两边都有实体 id、又互不
/// 重叠(实体判成不同歌)的不并;连成一片之后片里有两个互不重叠的实体,整片不并。代表键同 `SongEntityFamilies`。
public enum ScrobbleRewriteFamilies {
    /// 一条改写:播放器报的歌手、歌名,实际上送的歌手、歌名。
    public struct Rewrite: Hashable, Sendable {
        public var artist: String
        public var title: String
        public var sentArtist: String
        public var sentTitle: String

        public init(artist: String, title: String, sentArtist: String, sentTitle: String) {
            self.artist = artist
            self.title = title
            self.sentArtist = sentArtist
            self.sentTitle = sentTitle
        }
    }

    static let catalogFileName = "lyrimuse-lastfm-catalog.json"

    /// 读引擎的编目结论。读不到、解不开给空。
    public static func load(configDir: URL = LyrimusePaths.configDir) -> [Rewrite] {
        let url = configDir.appendingPathComponent(catalogFileName)
        guard let data = FileIO.read(url) else { return [] }
        return rewrites(fromCatalog: data, source: url)
    }

    /// 编目结论文件的内容 → 改写过的那些,按播放器报的写法排好。键是「歌手串\n曲名」,`verdict` 为 `match` 的才改写过
    /// (keep / defer 原样发);上送的歌手、曲名哪一样是空的,那一样按原样算。
    public static func rewrites(fromCatalog data: Data, source: URL) -> [Rewrite] {
        struct Decision: Decodable {
            var verdict: String?
            var artist: String?
            var track: String?
        }
        guard let all = FileIO.decodeJSON([String: Decision].self, from: data, source: source) else { return [] }
        var out: [Rewrite] = []
        for (key, d) in all where d.verdict == "match" {
            guard let nl = key.firstIndex(of: "\n") else { continue }
            let artist = String(key[..<nl]), title = String(key[key.index(after: nl)...])
            let sentArtist = d.artist.flatMap { $0.isEmpty ? nil : $0 } ?? artist
            let sentTitle = d.track.flatMap { $0.isEmpty ? nil : $0 } ?? title
            out.append(Rewrite(artist: artist, title: title, sentArtist: sentArtist, sentTitle: sentTitle))
        }
        return out.sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
    }

    /// 编目结论文件的修改时间和大小。
    public struct Stamp: Equatable, Sendable {
        let modified: Date
        let size: Int
    }

    /// 看一眼编目结论文件(一次 stat,不读内容),没有这个文件给 nil。别名表算好之后它变了就得重算:引擎每判一首新歌
    /// 就写它,不碰歌词缓存的条目(见 EnrichCacheReader.adopt)。
    public static func stamp(configDir: URL = LyrimusePaths.configDir) -> Stamp? {
        let path = configDir.appendingPathComponent(catalogFileName).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Stamp(modified: modified, size: (attrs[.size] as? NSNumber)?.intValue ?? 0)
    }

    /// 推导:`familyKey` 是到实体那一层为止的族键(跟灌进全局之后 familyKey 去掉这一层算的一样),`songs` 是本机写法按
    /// 这个族键分好的实体 id。结果只含不是代表的那些键:族键 → 代表族键。没有并上什么时是空表。
    public static func derive(_ rewrites: [Rewrite], familyKey: (String, String) -> String,
                              songs: [String: Set<String>]) -> [String: String] {
        var localsOf: [String: Set<String>] = [:] // 上送族键 → 连着它的本机族键
        for r in rewrites {
            let local = familyKey(r.artist, r.title), sent = familyKey(r.sentArtist, r.sentTitle)
            guard !local.isEmpty, !sent.isEmpty, local != sent else { continue }
            localsOf[sent, default: []].insert(local)
        }
        func disjoint(_ a: String, _ b: String) -> Bool {
            guard let x = songs[a], let y = songs[b], !x.isEmpty, !y.isEmpty else { return false }
            return x.isDisjoint(with: y)
        }
        var parent: [String: String] = [:]
        func find(_ k: String) -> String {
            var x = k
            while let p = parent[x], p != x { x = p }
            return x
        }
        for (sent, locals) in localsOf where locals.count == 1 {
            let local = locals.first!
            guard !disjoint(local, sent) else { continue }
            for k in [local, sent] where parent[k] == nil { parent[k] = k }
            let (a, b) = (find(local), find(sent))
            if a != b { parent[b] = a }
        }
        var groups: [String: [String]] = [:]
        for k in parent.keys { groups[find(k), default: []].append(k) }
        var out: [String: String] = [:]
        for group in groups.values where group.count > 1 {
            guard !group.contains(where: { a in group.contains { b in disjoint(a, b) } }) else { continue }
            let rep = group.min(by: SongEntityFamilies.representativePrecedes)!
            for k in group where k != rep {
                out[k] = rep
            }
        }
        return out
    }
}
