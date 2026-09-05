import Foundation

/// 从本机 enrich 缓存推「英文/罗马字歌名 → 中文歌名」别名(2026-09-04)。纯函数;读缓存、灌进
/// PlayCountFold 的那两步在 EnrichCacheReader / LastfmStatsService。背景见
/// `PlayCountFold.setLocalTitleAliases` 的注释。同日下午起它是歌名维度**唯一**的推断来源之一
/// (手写的 `titleAliasesByArtist` 静态表已删,用户要求「一切由通用逻辑覆盖,不要特殊化」),所以
/// 证据要够宽、闸要够严。
///
/// 两条证据路径,任一条成立即产出(结果再过共同的冲突闸):
///
/// **E1 · 同一个歌曲 id**:同一个(合唱归首位、罗马字折中文之后的)歌手名下,两条**不同歌名**的缓存
/// 条目被歌词解析各自独立地匹配到了**同一个网易云歌曲 id 或同一个 QQ 音乐 songmid**。
///
/// **E2 · 时长 + 歌词都对得上**(E1 够不着的:早期解析没落平台链接的条目,`Black Hole` / `Small Insects`
/// / `Write A Song For You` / `Twenty Three` / `Love Love Love` 全是这种):同一歌手名下,两种写法满足
/// ①都有播放器报的时长且**存在**一对接近——两侧都是毫秒级小数时差 ≤ 0.05 s,任一侧是整秒才放宽到
/// 0.6 s(理由见 durationsClose:配错词的两首歌时长天然接近,同一份录音却几乎相等);②各自的歌词都**可信**——条目里同时有播放器时长与所配歌词的时长
/// (`resolved_duration_secs`)时二者差 ≤ 3 s(差得多说明配到了别的歌的词:实测《Weather Report》61 s
/// 过场曲配上了《天气先生》271 s 的词,光看歌词两首会"完全一样");③歌词正文(去时间戳/署名行/标点
/// 空白,NFKC + 繁简 + 小写)的词元三元组 Jaccard ≥ 0.6(见 lyricsSimilarity,字符二元组对英文歌词
/// 完全不管用)。三个条件缺一不可:时长相等在整秒精度下 40%
/// 的歌都能撞上同歌手的另一首,歌词相同挡不住"配错词",各自单独都不够。满足的写法连边、并查集成类,
/// 类里选代表(含汉字优先 → 本机条目多 → 字典序),其余都指向它。连边的脚本规则:英文 ↔ 中文随便连;
/// 同脚本的两个折叠键只在"等长且恰好一个字不同"时连(`为你写的歌` / `为妳写的歌`,你/妳 不在繁简表里;
/// `无敌铁金刚` / `无敌铁金钢`),别的同脚本组合(`阿拉斯加海湾` vs `阿拉斯加海湾伴奏`)不连 —— 于是
/// `为你写的歌` / `为妳写的歌` / `Write A Song For You` 三种写法成一类(旧规则下英文名对上两个中文名
/// 只能整个跳过)。
///
/// 「含汉字的一侧」按**主标题**判(`coreTitle`:剥掉末尾的括号/方括号/破折号副题之后还含汉字/假名),
/// 不是整串含汉字就算 —— 实测 `Ten Reasons (Live版)` 只因为一个「版」字被当成中文名,配上同一个 QQ
/// mid 的 `Ten Reasons` 就会把录音室版并进 Live 版(歌词源本来就分不清同一首歌的两个版本,两次
/// 检索落到同一个 id 对**版本**不构成证据);`All for Joy (feat. 关诗敏)` 同理。E2 的中文侧候选还要求
/// 折叠后不带版本尾缀(`foldTitle(title) == foldTitle(coreTitle)`)—— 别把英文录音室版并进中文 Live 版。
///
/// 四道保守闸(错合并比不合并更糟,沿用发现表那边的取舍):
///  1. E1 里任一侧折叠后出现 ≥ 2 种歌名 → 这个 id 整组不采纳。中文侧不唯一 = 同一个 id 被匹配给了
///     两首不同的中文歌;英文侧不唯一(实测 陶喆 名下 `I Like It (Ballad Version)` 与 `What Is Love`
///     落到同一个网易云 id)= 至少有一条解析配错了,而分不清是哪条;
///  2. E1 里两条都带播放器时长时相差 > 3 s → 不采纳;
///  3. 同一个英文折叠键从不同来源推出了**不同的**中文歌名 → 两条都撤(分不清哪条对);
///  4. 两侧折叠键本来就相等的不产出(空转的别名,`All for Joy` ↔ `All for Joy (feat. X)` 那种)。
///
/// E1 只认「英文 → 中文」这个方向(同 id 的中文 ↔ 中文分裂——繁简/括号——本来就由折叠键管,剩下的
/// 交给 E2);E2 不限方向,见上。搜索页地址(`y.qq.com/n/ryqq/search?w=…`)不是身份,不算 id。
public enum EnrichTitleAliases {
    public struct Entry {
        public var artist: String
        public var title: String
        public var neteaseURL: String?
        public var qqMusicURL: String?
        /// 播放器报的时长(秒),缓存里的 `duration_secs`;没有就 nil。
        public var durationSecs: Double?
        /// 所配歌词那条候选在来源上的时长(秒),缓存里的 `resolved_duration_secs`;E2 用来判歌词可信。
        public var resolvedDurationSecs: Double?
        /// LRC 正文(缓存里的 `lyrics`);E2 用。
        public var lyrics: String?

        public init(artist: String, title: String, neteaseURL: String?, qqMusicURL: String?, durationSecs: Double?,
                    resolvedDurationSecs: Double? = nil, lyrics: String? = nil) {
            self.artist = artist
            self.title = title
            self.neteaseURL = neteaseURL
            self.qqMusicURL = qqMusicURL
            self.durationSecs = durationSecs
            self.resolvedDurationSecs = resolvedDurationSecs
            self.lyrics = lyrics
        }
    }

    /// E1:两条都有时长时允许的最大差值(秒)。播放器报的时长对同一录音应当逐秒一致
    /// (实测 161 vs 161.000022);3 s 是给不同来源的 ms 取整留的余量。
    public static let durationTolerance: Double = 3
    /// E2:播放器时长的最大差值(秒)。两侧都是播放器报的数,同一录音只差取整(实测 213 vs 213.267、
    /// 224 vs 224.499),0.6 s 刚好盖住整秒精度的一侧。
    public static let e2DurationTolerance: Double = 0.6
    /// 歌词可信:播放器时长与所配歌词候选时长的最大差值(秒)。
    public static let lyricsTrustTolerance: Double = 3
    /// E2:歌词正文字符二元组 Jaccard 的下限。
    public static let lyricsSimilarityMin: Double = 0.6
    /// E2:歌词正文剥完之后至少要有这么多词元(汉字一个字一个、英文一个词一个),太短的(过场曲/只有
    /// 署名行)不参与比对。
    public static let lyricsMinTokens = 24

    /// 一条缓存条目里能当身份用的 id,带来源前缀(`netease:2635125902` / `qq:002lChJY23SXj7`)。
    public static func songIDs(neteaseURL: String?, qqMusicURL: String?) -> [String] {
        var out: [String] = []
        if let s = neteaseURL, let id = neteaseSongID(s) { out.append("netease:" + id) }
        if let s = qqMusicURL, let mid = qqSongMid(s) { out.append("qq:" + mid) }
        return out
    }

    /// `https://music.163.com/song?id=2635125902`(也接受 `/#/song?id=`)→ "2635125902"。
    static func neteaseSongID(_ url: String) -> String? {
        guard url.contains("music.163.com"), let range = url.range(of: "id=") else { return nil }
        let digits = url[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// `https://y.qq.com/n/ryqq/songDetail/002lChJY23SXj7` → "002lChJY23SXj7";搜索页地址 → nil。
    static func qqSongMid(_ url: String) -> String? {
        guard url.contains("y.qq.com"), let range = url.range(of: "/songDetail/") else { return nil }
        let mid = url[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
        return mid.isEmpty ? nil : String(mid)
    }

    /// 剥掉末尾的括号 / 方括号 / 破折号副题(可叠多层)之后的主标题。只给「这是不是中文名」的分类用。
    public static func coreTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespaces)
        for _ in 0..<4 {
            if let (base, _) = PlayCountVariants.subtitleSplit(t) { t = base; continue }
            if let (base, _) = PlayCountVariants.bracketSuffixSplit(t) { t = base; continue }
            if let (base, _) = PlayCountVariants.dashSuffixSplit(t) { t = base; continue }
            break
        }
        return t
    }

    /// 主标题含汉字/假名 → 中文(或日文)名;否则算英文/罗马字名。
    public static func isHanTitled(_ title: String) -> Bool {
        !PlayCountFold.hasNoHanLikeChars(coreTitle(title))
    }

    // MARK: 歌词正文相似度(E2)

    /// LRC → 可比对的正文:去掉 `[…]` 时间戳/头标签、`<…>` 逐字标签、署名行,再 NFKC + 繁简 + 小写、
    /// 只留字母数字(含汉字),拼成一串。
    public static func lyricsBody(_ lrc: String) -> String {
        var out = ""
        for rawLine in lrc.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            var line = String(rawLine)
            line = line.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            let norm = PlayCountFold.normalized(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !norm.isEmpty, !isCreditLine(norm) else { continue }
            // 字母数字之间的空白/标点换成一个空格当分词边界,汉字之间什么都不留(中文歌词本来没空格)
            var line2 = ""
            var pendingBreak = false
            for scalar in norm.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) {
                    if pendingBreak, let last = line2.unicodeScalars.last,
                       !CharacterSet.hanLike.contains(last), !CharacterSet.hanLike.contains(scalar) {
                        line2.append(" ")
                    }
                    line2.unicodeScalars.append(scalar)
                    pendingBreak = false
                } else {
                    pendingBreak = !line2.isEmpty
                }
            }
            out += line2 + " "
        }
        return out
    }

    /// 署名行(作词/作曲/编曲/…):不同来源各带各的一套,比对正文时剥掉。输入已 normalized(小写)。
    static func isCreditLine(_ s: String) -> Bool {
        let prefixes = ["作词", "作曲", "编曲", "词:", "曲:", "词：", "曲：", "制作", "监制", "录音", "混音", "母带",
                        "lyrics", "lyricist", "composer", "producer", "arranger", "arrangement", "written by",
                        "produced by", "mixed by", "mastered by"]
        return prefixes.contains { s.hasPrefix($0) }
    }

    /// 歌词正文的相似度:词元三元组(shingle)集合的 Jaccard。
    ///
    /// 词元:汉字/假名每个字一个词元,拉丁字母/数字一段连续串一个词元。⚠️ 不能用字符二元组:字母表
    /// 只有 26 个字母,两首**不同**的英文歌的字母二元组集合几乎必然大面积重合(实测 MJ《Keep the Faith》
    /// 与《Thriller》0.65、时长又都是 5:57,直接被并成一首);按词切了再取三元组,不同的歌几乎没有
    /// 共同的三词短语,同一首歌的两份歌词(行切分不同、繁简不同、少数字形差异)三元组仍大面积重合。
    /// 汉字按字切是因为中文歌词没有空格,一个汉字的信息量本来就够(几千个字的三元组极难撞)。
    public static func lyricsSimilarity(_ a: String, _ b: String) -> Double {
        let ga = shingles(lyricsTokens(a)), gb = shingles(lyricsTokens(b))
        let union = ga.union(gb)
        guard !union.isEmpty else { return 0 }
        return Double(ga.intersection(gb).count) / Double(union.count)
    }

    /// 正文(lyricsBody 的输出:已 NFKC + 繁简 + 小写、只剩字母数字汉字)切词元。
    static func lyricsTokens(_ body: String) -> [String] {
        var out: [String] = []
        var latin = ""
        for ch in body {
            if ch == " " {
                if !latin.isEmpty { out.append(latin); latin = "" }
                continue
            }
            let isHan = ch.unicodeScalars.contains { CharacterSet.hanLike.contains($0) }
            if isHan {
                if !latin.isEmpty { out.append(latin); latin = "" }
                out.append(String(ch))
            } else {
                latin.append(ch)
            }
        }
        if !latin.isEmpty { out.append(latin) }
        return out
    }

    static func shingles(_ tokens: [String], size: Int = 3) -> Set<String> {
        guard tokens.count >= size else { return tokens.isEmpty ? [] : [tokens.joined(separator: "\u{1F}")] }
        var out = Set<String>()
        for i in 0...(tokens.count - size) { out.insert(tokens[i..<(i + size)].joined(separator: "\u{1F}")) }
        return out
    }

    /// 这条条目的歌词可不可信:有播放器时长、也有所配歌词的时长时,两者要接近;缺一个就只能信它。
    static func lyricsTrusted(_ e: Entry) -> Bool {
        guard let d = e.durationSecs, d > 0, let r = e.resolvedDurationSecs, r > 0 else { return true }
        return abs(d - r) <= lyricsTrustTolerance
    }

    /// 两组时长里**存在**一对"接近"即算接近 —— 同一写法在不同专辑下的条目时长可能不同(实测
    /// `Small Insects` 在《橙月》240.13 s、在精选《Timeless》236.09 s),取最小值比会错杀。
    ///
    /// "接近"按**精度**分档(E2 的核心闸):两侧都是毫秒级小数时,同一份录音的播放器时长应当几乎相等
    /// (实测 213.586666 vs 213.586、197.273696 vs 197.274002、161.000022 vs 161,差 < 0.001 s),容差
    /// 0.05 s;任一侧是整秒(来源丢了小数)才放宽到 0.6 s(实测 213 vs 213.267、224 vs 224.499)。
    /// 为什么必须这么严:歌词解析器本来就按时长挑候选,**配错词的两首歌时长天然接近**(实测南拳妈妈
    /// 《神奇剪刀》配上了同专辑《小时候》的词,225.12 vs 223.99),差 1 s 那一档正是错配的高发区,
    /// 而同一份录音差不到 0.01 s。
    static func durationsClose(_ a: [Double], _ b: [Double], tolerance: Double) -> Bool {
        for x in a {
            for y in b {
                let tol = (isIntegral(x) || isIntegral(y)) ? tolerance : e2PreciseTolerance
                if abs(x - y) <= tol { return true }
            }
        }
        return false
    }

    static func isIntegral(_ v: Double) -> Bool { abs(v - v.rounded()) < 1e-6 }

    /// 两侧都是毫秒级时长时的容差(秒)。
    public static let e2PreciseTolerance: Double = 0.05

    /// 同一脚本(都含汉字 / 都不含)的两个折叠键只在"等长且恰好一个字不同"时才允许连 E2 的边:
    /// 那是一个字形/用字差异(`无敌铁金刚`/`无敌铁金钢`、`为你写的歌`/`为妳写的歌`,你/妳 不在繁简表里);
    /// 别的同脚本组合(`阿拉斯加海湾` vs `阿拉斯加海湾伴奏`、两首不同的歌)不连 —— 同一份录音的两种
    /// 中文写法除了这种单字差异,其余分裂(繁简/括号/空格)折叠键早就并掉了,再多出来的多半是版本。
    static func oneCharVariant(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard x.count == y.count, x.count >= 2 else { return false }
        var diff = 0
        for i in 0..<x.count where x[i] != y[i] { diff += 1; if diff > 1 { return false } }
        return diff == 1
    }

    // MARK: 推表

    /// 推别名表。结构同旧静态表:`canonicalArtistKey → foldTitle(英文歌名) → 中文歌名原始写法`。
    /// - Parameter artistKey: 歌手分桶用的键函数。默认走 `PlayCountFold.canonicalArtistKey`(读全局的本机
    ///   歌手别名表);EnrichCacheReader 同一轮刚推完歌手表、还没灌进全局时,把基于新表的键函数传进来。
    public static func derive(_ entries: [Entry],
                              artistKey: (String) -> String = { PlayCountFold.canonicalArtistKey($0) }) -> [String: [String: String]] {
        // 同一歌手名下,按折叠键去重的条目(原始写法取字典序最小),两侧分开放
        struct Item {
            var title: String
            var count = 0                     // 本机条目数(E2 选代表用)
            var durations: [Double] = []
            var lyricsBodies: [String] = []   // 可信的歌词正文(同一写法在几张专辑下的条目都收)
        }
        struct Bucket { var han: [String: Item] = [:]; var nonHan: [String: Item] = [:] }
        var buckets: [String: Bucket] = [:]
        // E1 分组:(歌手键, id) → 两侧 折叠键 → 原始写法,以及两侧的时长
        struct IDGroup { var han: [String: String] = [:]; var nonHan: [String: String] = [:]
                         var hanDur: [Double] = []; var nonHanDur: [Double] = [] }
        var idGroups: [String: [String: IDGroup]] = [:]
        // E2 的参与条件:有时长、有可信歌词、折叠后不带版本尾缀
        func eligibleForE2(_ folded: String, _ item: Item) -> Bool {
            !item.durations.isEmpty && !item.lyricsBodies.isEmpty
                && PlayCountFold.foldTitle(coreTitle(item.title)) == folded
        }

        for e in entries {
            let title = e.title.trimmingCharacters(in: .whitespaces)
            guard !e.artist.isEmpty, !title.isEmpty else { continue }
            let artistKey = artistKey(e.artist)
            let folded = PlayCountFold.foldTitle(title)
            let isHan = isHanTitled(title)

            var bucket = buckets[artistKey] ?? Bucket()
            var side = isHan ? bucket.han : bucket.nonHan
            var item = side[folded] ?? Item(title: title)
            item.count += 1
            if title < item.title { item.title = title }
            if let d = e.durationSecs, d > 0 { item.durations.append(d) }
            if let l = e.lyrics, lyricsTrusted(e) {
                let body = lyricsBody(l)
                if lyricsTokens(body).count >= lyricsMinTokens { item.lyricsBodies.append(body) }
            }
            side[folded] = item
            if isHan { bucket.han = side } else { bucket.nonHan = side }
            buckets[artistKey] = bucket

            for id in songIDs(neteaseURL: e.neteaseURL, qqMusicURL: e.qqMusicURL) {
                var byID = idGroups[artistKey] ?? [:]
                var g = byID[id] ?? IDGroup()
                if isHan {
                    if let existing = g.han[folded] { if title < existing { g.han[folded] = title } } else { g.han[folded] = title }
                    if let d = e.durationSecs, d > 0 { g.hanDur.append(d) }
                } else {
                    if let existing = g.nonHan[folded] { if title < existing { g.nonHan[folded] = title } } else { g.nonHan[folded] = title }
                    if let d = e.durationSecs, d > 0 { g.nonHanDur.append(d) }
                }
                byID[id] = g
                idGroups[artistKey] = byID
            }
        }

        // 候选:歌手键 → 英文折叠键 → (中文折叠键 → 中文原始写法)。同一英文键攒出 ≥ 2 个不同中文键 → 闸 3 撤。
        var proposals: [String: [String: [String: String]]] = [:]
        func propose(_ artistKey: String, _ engFolded: String, _ hanFolded: String, _ hanRaw: String) {
            guard engFolded != hanFolded else { return } // 闸 4
            var forEng = proposals[artistKey]?[engFolded] ?? [:]
            if let existing = forEng[hanFolded] { if hanRaw < existing { forEng[hanFolded] = hanRaw } }
            else { forEng[hanFolded] = hanRaw }
            proposals[artistKey, default: [:]][engFolded] = forEng
        }

        // E1
        for artistKey in idGroups.keys.sorted() {
            for id in idGroups[artistKey]!.keys.sorted() {
                let g = idGroups[artistKey]![id]!
                guard g.nonHan.count == 1, g.han.count == 1,
                      let (hanFolded, hanRaw) = g.han.first, let (engFolded, _) = g.nonHan.first
                else { continue }   // 闸 1
                if let a = g.hanDur.min(), let b = g.nonHanDur.min(), abs(a - b) > durationTolerance { continue } // 闸 2
                propose(artistKey, engFolded, hanFolded, hanRaw)
            }
        }

        // E2:同一歌手名下,凡「播放器时长差 ≤ 0.6 s 且歌词正文相似 ≥ 0.6」的两种写法连一条边,并查集成类;
        // 一个类 = 同一份录音的若干写法(英文名 / 中文名 / 中文的你妳之类折叠键并不到一起的字形差异),
        // 类里选一个代表(含汉字优先 → 本机条目多 → 字典序),其余写法都指向它。不参与:没时长、
        // 没可信歌词、折叠后带版本尾缀(Live/Remix 之类是另一份录音,别被卷进来)。
        for artistKey in buckets.keys.sorted() {
            let bucket = buckets[artistKey]!
            var members: [(folded: String, item: Item, han: Bool)] = []
            for (folded, item) in bucket.han where eligibleForE2(folded, item) { members.append((folded, item, true)) }
            for (folded, item) in bucket.nonHan where eligibleForE2(folded, item) { members.append((folded, item, false)) }
            guard members.count >= 2 else { continue }
            members.sort { $0.folded < $1.folded }
            var uf = LocalArtistAliases.UnionFind()
            for i in 0..<members.count {
                uf.add(members[i].folded)
                for j in (i + 1)..<members.count {
                    let x = members[i], y = members[j]
                    // 跨脚本(英文 ↔ 中文)随便连;同脚本只连单字差异,见 oneCharVariant
                    guard x.han != y.han || oneCharVariant(x.folded, y.folded) else { continue }
                    guard durationsClose(x.item.durations, y.item.durations, tolerance: e2DurationTolerance) else { continue }
                    var best = 0.0
                    for p in x.item.lyricsBodies { for q in y.item.lyricsBodies { best = max(best, lyricsSimilarity(p, q)) } }
                    if best >= lyricsSimilarityMin { uf.union(x.folded, y.folded) }
                }
            }
            var classes: [String: [(folded: String, item: Item, han: Bool)]] = [:]
            for m in members { classes[uf.find(m.folded), default: []].append(m) }
            for (_, group) in classes where group.count >= 2 {
                let rep = group.min { a, b in
                    if a.han != b.han { return a.han }
                    if a.item.count != b.item.count { return a.item.count > b.item.count }
                    return a.folded < b.folded
                }!
                for m in group where m.folded != rep.folded {
                    propose(artistKey, m.folded, rep.folded, rep.item.title)
                }
            }
        }

        // 闸 3 + 出表(键排序遍历只为结果确定,字典本身无序)
        var out: [String: [String: String]] = [:]
        for artistKey in proposals.keys.sorted() {
            for (engFolded, targets) in proposals[artistKey]! where targets.count == 1 {
                out[artistKey, default: [:]][engFolded] = targets.values.first!
            }
        }
        return out
    }
}
