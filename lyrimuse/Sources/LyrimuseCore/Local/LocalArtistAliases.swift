import Foundation

/// 歌手写法归并(罗马字艺名 ↔ 中文本名、乐队别名)的**通用推断**(2026-09-04),取代此前手写的
/// `romanizedArtistAliases` 静态表 —— 用户明确要求「尽可能去掉手工表,一切由通用逻辑覆盖,不要特殊化」。
///
/// 证据全部来自本机、零网络:
///  1. collector 的 MusicBrainz 缓存(它解析歌词时已经替每个新歌手查过一次 MusicBrainz):
///     - `lyrimuse-artist-alias-cache.json`:原始标签 → 中文别名(`Crowd Lu → 卢广仲`);
///     - `lyrimuse-artist-identity-cache.json`:名字 → {mbid, zh}(`Soft Lipa → 蛋堡`);
///     - `lyrimuse-artist-primary-cache.json`:名字 → MusicBrainz 上的全部别名
///       (`周杰伦 → [Jay Chou, Jay, Zhou Jie Lun, ジェイ・チョウ, …]`、`Will Pan → [潘瑋柏, Wilber Pan]`)。
///  2. enrich 缓存里的共现:两种歌手写法名下的曲目被歌词解析落到了**同一批歌曲 id**
///     (`Khalil Fong` 与 `方大同` 共享 13 个网易云 id、`David Tao` 与 `陶喆` 3 个)。要求 ≥ 2 个
///     不同 id —— 单个共享 id 实测全是噪音(`方大同 ↔ 王诗安` 是合唱、`K ↔ 英雄联盟` 是配错)。
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

    public static let minSharedSongIDs = 2
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
        /// MusicBrainz 缓存的键/别名是不是**单个**歌手写法。缓存按 collector 收到的原始标签存,里面
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

        // 2. enrich 缓存:本机曲目数(选代表用)+ 共享歌曲 id
        var artistsByID: [String: Set<String>] = [:]
        for e in entries {
            guard let key = note(e.artist, weight: 1) else { continue }
            for id in EnrichTitleAliases.songIDs(neteaseURL: e.neteaseURL, qqMusicURL: e.qqMusicURL) {
                artistsByID[id, default: []].insert(key)
            }
        }
        var shared: [String: Set<String>] = [:] // "a\u{1F}b"(a<b) → ids
        for (id, keys) in artistsByID where keys.count > 1 {
            let sorted = keys.sorted()
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    shared[sorted[i] + "\u{1F}" + sorted[j], default: []].insert(id)
                }
            }
        }
        for (pair, ids) in shared where ids.count >= minSharedSongIDs {
            let parts = pair.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            uf.union(parts[0], parts[1])
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

/// 读 collector 的三份 MusicBrainz 歌手缓存(纯读盘、解 JSON,失败给空表)。放在 Core 是因为
/// EnrichCacheReader 同样在 Core 读盘;selftest 不碰它,只测 LocalArtistAliases.derive 的纯函数部分。
public enum ArtistIdentityCaches {
    public static func load(configDir: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".config/lyrimuse")) -> LocalArtistAliases.MusicBrainzCaches {
        var out = LocalArtistAliases.MusicBrainzCaches()
        if let data = try? Data(contentsOf: configDir.appendingPathComponent("lyrimuse-artist-alias-cache.json")),
           let m = try? JSONDecoder().decode([String: String].self, from: data) {
            out.aliasCache = m
        }
        struct Identity: Decodable { var zh: String? }
        if let data = try? Data(contentsOf: configDir.appendingPathComponent("lyrimuse-artist-identity-cache.json")),
           let m = try? JSONDecoder().decode([String: Identity].self, from: data) {
            out.identityZh = m.compactMapValues { $0.zh }.filter { !$0.value.isEmpty }
        }
        if let data = try? Data(contentsOf: configDir.appendingPathComponent("lyrimuse-artist-primary-cache.json")),
           let m = try? JSONDecoder().decode([String: [String]].self, from: data) {
            out.primaryAliases = m
        }
        return out
    }
}
