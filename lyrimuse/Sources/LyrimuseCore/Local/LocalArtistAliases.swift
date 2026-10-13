import Foundation

/// 歌手写法归并(罗马字艺名 与 中文本名、乐队别名)的**通用推断**,取代此前手写的
/// `romanizedArtistAliases` 静态表 —— 「尽可能去掉手工表,一切由通用逻辑覆盖,不要特殊化」。
///
/// 证据全部来自本机、零网络:
///  1. 引擎的 MusicBrainz 缓存(它解析歌词时已经替每个新歌手查过一次 MusicBrainz):
///     - `lyrimuse-artist-alias-cache.json`:原始标签 → 中文别名(`Crowd Lu → 卢广仲`);
///     - `lyrimuse-artist-identity-cache.json`:名字 → {mbid, zh}(`Soft Lipa → 蛋堡`);
///     - `lyrimuse-artist-primary-cache.json`:名字 → MusicBrainz 上的全部别名
///       (`周杰伦 → [Jay Chou, Jay, Zhou Jie Lun, ジェイ・チョウ, …]`、`Will Pan → [潘瑋柏, Wilber Pan]`)。
///  2. enrich 缓存里的共现:两种歌手写法名下的曲目被歌词解析落到了**同一批歌曲**(见 12 章决策 75)。
///     - 按首数,不按 id 数:同一条目上的网易云 id 和 QQ id 是同一首。
///     - 两种写法互不包含时,要共享 `minSharedSongs` 首,两人合作的那首不算:落在这首上的条目里有一条两个
///       名字都署了(合唱串里,或者歌名里写着另一位)。
///     - 一种写法包含另一种(`名字 (英文名)` 与 `名字`)时共享一首就够。被包含的不在开头、前面那段又以另一块
///       里的写法开头(没拆开的合唱串 `A×B` 里的 B)时不连它;剩下的分属几块时一个都不连。
///
/// 把这些边丢进并查集,每个连通块选一个代表:优先含汉字/假名的写法,同样含的取本机曲目数最多的
/// (那才是用户自己历史里的主流写法),再同样取字典序最小 —— 结果确定、不依赖字典遍历顺序。
/// 输出:`stripSpaces(normalized(mergeArtist(写法))) → 代表写法`,只给 `PlayCountFold.canonicalArtist`
/// 用(查族键 / 明细 / 别名推断的歌手分桶),不碰整本账的身份键 `PlayCountFold.key`。
///
/// 保守闸:
///  - MusicBrainz 别名里去掉空格后不足 3 个字符且不含汉字的不用(`K` 这种撞上别的艺人的概率太高;
///    匹配本身是整串相等,`asi`(A Si → 阿肆)这种 3 字符键只会撞上同名艺人,留下);
///  - 合唱串先归首位(`Khalil Fong & Fiona Sit → Khalil Fong`),不让一次合唱把两位歌手并成一块。
public enum LocalArtistAliases {
    /// MusicBrainz 三份缓存的内容(由 ArtistIdentityCaches.load 读盘,这里只吃字典)。
    public struct MusicBrainzCaches {
        public var aliasCache: [String: String]
        public var identityZh: [String: String]
        public var primaryAliases: [String: [String]]
        public init(aliasCache: [String: String] = [:], identityZh: [String: String] = [:],
                    primaryAliases: [String: [String]] = [:]) {
            self.aliasCache = aliasCache
            self.identityZh = identityZh
            self.primaryAliases = primaryAliases
        }
    }

    public static let minSharedSongs = 2
    public static let minAliasLength = 3

    /// 歌手写法的归一键 —— 跟 PlayCountFold.canonicalArtistKey 去掉别名那一步之后完全一致。
    public static func artistKey(_ name: String) -> String {
        PlayCountFold.stripSpaces(PlayCountFold.normalized(ArtistCredit.mergeArtist(name)))
    }

    /// 用一份(刚推出来、还没灌进全局的)歌手表算 `canonicalArtistKey`:跟 PlayCountFold.canonicalArtistKey
    /// 完全同一把尺子,只是查的表由参数给。EnrichCacheReader 推歌名表时用。
    public static func canonicalArtistKey(_ name: String, table: [String: String]) -> String {
        let primary = ArtistCredit.mergeArtist(name)
        let canon = table[artistKey(primary)] ?? primary
        return PlayCountFold.stripSpaces(PlayCountFold.normalized(canon))
    }

    public static func derive(caches: MusicBrainzCaches, entries: [EnrichTitleAliases.Entry]) -> [String: String] {
        var uf = UnionFind()
        // 键 → 见过的原始写法(归首位之后)及其本机曲目数
        var spellings: [String: [String: Int]] = [:]
        func note(_ name: String, weight: Int = 0) -> String? {
            let primary = ArtistCredit.mergeArtist(name).trimmingCharacters(in: .whitespaces)
            guard !primary.isEmpty else { return nil }
            let key = artistKey(primary)
            guard !key.isEmpty else { return nil }
            spellings[key, default: [:]][primary, default: 0] += weight
            uf.add(key)
            return key
        }
        /// MusicBrainz 缓存的键/别名是不是**单个**歌手写法。缓存按引擎收到的原始标签存,里面
        /// 有合唱串和带逗号的乐队名(`Earth, Wind & Fire`),归首位会把它们切成 `Earth` 这种碎片,再拿
        /// 碎片去连边就是乱连(实测推出 `earth → アース`)。碎片不当边的端点;共现那条路不受影响
        /// (它按 enrich 条目自己的写法归首位,两侧都是同一套切法)。
        func single(_ name: String) -> Bool {
            ArtistCredit.mergeArtist(name).trimmingCharacters(in: .whitespaces) == name.trimmingCharacters(in: .whitespaces)
        }
        func usable(_ alias: String) -> Bool {
            let squeezed = PlayCountFold.stripSpaces(alias)
            return !PlayCountFold.hasNoHanLikeChars(squeezed) || squeezed.count >= minAliasLength
        }

        // 1. MusicBrainz 缓存(两端都得是单个歌手写法,见 single)
        for (raw, zh) in caches.aliasCache where !zh.isEmpty && single(raw) && single(zh) {
            guard let a = note(raw), let b = note(zh) else { continue }
            uf.union(a, b)
        }
        for (name, zh) in caches.identityZh where !zh.isEmpty && single(name) && single(zh) {
            guard let a = note(name), let b = note(zh) else { continue }
            uf.union(a, b)
        }
        for (name, aliases) in caches.primaryAliases where single(name) {
            guard let a = note(name) else { continue }
            for alias in aliases where usable(alias) && single(alias) {
                guard let b = note(alias) else { continue }
                uf.union(a, b)
            }
        }

        // 2. enrich 缓存:本机曲目数(选代表用)+ 共享的歌
        var songOf = UnionFind() // 平台 id → 所在那一首:同一条目上的几个 id 连在一起
        var artistsByID: [String: Set<String>] = [:]
        var entriesByID: [String: [Int]] = [:]
        var keyOf: [Int: String] = [:]
        for (i, e) in entries.enumerated() {
            guard let key = note(e.artist, weight: 1) else { continue }
            keyOf[i] = key
            let ids = EnrichTitleAliases.songIDs(neteaseURL: e.neteaseURL, qqMusicURL: e.qqMusicURL)
            for id in ids {
                artistsByID[id, default: []].insert(key)
                entriesByID[id, default: []].append(i)
                songOf.union(ids[0], id)
            }
        }
        var shared: [String: Set<String>] = [:] // "a\u{1F}b"(a<b) → 共享的歌(songOf 的根)
        for (id, keys) in artistsByID where keys.count > 1 {
            let song = songOf.find(id)
            let sorted = keys.sorted()
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    shared[sorted[i] + "\u{1F}" + sorted[j], default: []].insert(song)
                }
            }
        }
        var creditsOn: [String: [Credit]] = [:] // 共享的歌 → 落在上面的条目各署了谁
        let sharedSongs = shared.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for (id, indices) in entriesByID {
            let song = songOf.find(id)
            guard sharedSongs.contains(song) else { continue }
            for i in indices {
                guard let key = keyOf[i] else { continue }
                let e = entries[i]
                creditsOn[song, default: []].append(Credit(key: key, duet: ArtistCredit.primary(e.artist).map { _ in fold(e.artist) },
                                                           title: fold(e.title)))
            }
        }
        var containing: [String: Set<String>] = [:] // 包含着别的写法的键 → 被它包含、跟它共享过歌的键
        for (pair, songs) in shared {
            let parts = pair.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (a, b) = (parts[0], parts[1])
            if let (outer, inner) = containment(a, b) {
                containing[outer, default: []].insert(inner)
                continue
            }
            let solo = songs.filter { song in !(creditsOn[song] ?? []).contains { $0.names(a) && $0.names(b) } }
            if solo.count >= minSharedSongs { uf.union(a, b) }
        }
        let known = Array(spellings.keys)
        for (outer, inners) in containing.sorted(by: { $0.key < $1.key }) {
            let kept = inners.filter { inner in
                guard let r = outer.range(of: inner), r.lowerBound > outer.startIndex else { return true }
                let head = outer[..<r.lowerBound]
                let block = uf.find(inner)
                return !known.contains { $0 != inner && containable($0) && head.hasPrefix($0) && uf.find($0) != block }
            }
            guard let inner = kept.first, Set(kept.map { uf.find($0) }).count == 1 else { continue }
            uf.union(outer, inner)
        }

        // 3. 每个连通块选代表
        var groups: [String: [String]] = [:]
        for key in spellings.keys { groups[uf.find(key), default: []].append(key) }
        var out: [String: String] = [:]
        for (_, keys) in groups where keys.count > 1 {
            var candidates: [(name: String, han: Bool, weight: Int)] = []
            for key in keys {
                for (name, weight) in spellings[key] ?? [:] {
                    candidates.append((name, !PlayCountFold.hasNoHanLikeChars(name), weight))
                }
            }
            guard let rep = candidates.min(by: { a, b in
                if a.han != b.han { return a.han }
                if a.weight != b.weight { return a.weight > b.weight }
                return a.name < b.name
            }) else { continue }
            let repKey = artistKey(rep.name)
            for key in keys where key != repKey { out[key] = rep.name }
        }
        return out
    }

    /// 共享的歌上一个条目署了谁(折法同 artistKey):`key` 是它自己的键,`duet` 是合唱串整串(单人为 nil),`title` 是歌名。
    struct Credit {
        let key: String
        let duet: String?
        let title: String
        func names(_ k: String) -> Bool {
            key == k || duet?.range(of: k) != nil || title.range(of: k) != nil
        }
    }

    /// 两种写法里一种包含另一种时给 (包含的, 被包含的)。
    static func containment(_ a: String, _ b: String) -> (String, String)? {
        let (outer, inner) = a.count > b.count ? (a, b) : (b, a)
        guard containable(inner), outer.range(of: inner) != nil else { return nil }
        return (outer, inner)
    }

    /// 能不能当包含关系里被包含的那一方:不含汉字的至少 minAliasLength 个字符,含汉字的至少两个字。
    static func containable(_ k: String) -> Bool {
        k.count >= (PlayCountFold.hasNoHanLikeChars(k) ? minAliasLength : 2)
    }

    static func fold(_ s: String) -> String {
        PlayCountFold.stripSpaces(PlayCountFold.normalized(s))
    }

    /// 最小并查集(路径压缩),字符串键。
    struct UnionFind {
        private var parent: [String: String] = [:]
        mutating func add(_ k: String) { if parent[k] == nil { parent[k] = k } }
        mutating func find(_ k: String) -> String {
            add(k)
            var root = k
            while let p = parent[root], p != root { root = p }
            var cur = k
            while let p = parent[cur], p != root { parent[cur] = root; cur = p }
            return root
        }
        mutating func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            // 让根确定(字典序小的当根),结果不依赖插入顺序
            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }
    }
}

/// 读引擎的三份 MusicBrainz 歌手缓存(纯读盘、解 JSON,失败给空表)。放在 Core 是因为
/// EnrichCacheReader 同样在 Core 读盘;selftest 不测读盘,测 LocalArtistAliases.derive 的纯函数部分和 `stamp`。
public enum ArtistIdentityCaches {
    static let aliasFileName = "lyrimuse-artist-alias-cache.json"
    static let identityFileName = "lyrimuse-artist-identity-cache.json"
    static let primaryFileName = "lyrimuse-artist-primary-cache.json"

    public static func load(configDir: URL = LyrimusePaths.configDir) -> LocalArtistAliases.MusicBrainzCaches {
        var out = LocalArtistAliases.MusicBrainzCaches()
        if let data = FileIO.read(configDir.appendingPathComponent(aliasFileName)),
           let m = FileIO.decodeJSON([String: String].self, from: data, source: configDir.appendingPathComponent(aliasFileName)) {
            out.aliasCache = m
        }
        struct Identity: Decodable { var zh: String? }
        if let data = FileIO.read(configDir.appendingPathComponent(identityFileName)),
           let m = FileIO.decodeJSON([String: Identity].self, from: data, source: configDir.appendingPathComponent(identityFileName)) {
            out.identityZh = m.compactMapValues { $0.zh }.filter { !$0.value.isEmpty }
        }
        if let data = FileIO.read(configDir.appendingPathComponent(primaryFileName)),
           let m = FileIO.decodeJSON([String: [String]].self, from: data, source: configDir.appendingPathComponent(primaryFileName)) {
            out.primaryAliases = m
        }
        return out
    }

    /// 三份缓存各自的修改时间和大小,没有的那份记空。别名表算好之后它们变了就得重算(见 EnrichCacheReader.adopt):
    /// 引擎的歌手身份核对、Top 歌手统计这类后台任务只写这三份,不碰歌词缓存的条目。
    public struct Stamp: Equatable, Sendable {
        fileprivate let files: [File?]

        fileprivate struct File: Equatable, Sendable {
            let modified: Date
            let size: Int
        }
    }

    /// 看一眼三份缓存(三次 stat,不读内容)。
    public static func stamp(configDir: URL = LyrimusePaths.configDir) -> Stamp {
        Stamp(files: [aliasFileName, identityFileName, primaryFileName].map { name in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: configDir.appendingPathComponent(name).path),
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            return Stamp.File(modified: modified, size: (attrs[.size] as? NSNumber)?.intValue ?? 0)
        })
    }
}
