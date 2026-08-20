import Foundation

/// 同一段汉字文本的「另一种写法」(繁↔简孪生)。
///
/// 为什么放 LyrimuseCore:跟 EnrichCacheKeys 同一个理由 —— 确定性纯逻辑下沉到这里,
/// lyrimuse-selftest(只依赖 LyrimuseCore)才能对它写断言;留在 app target 里一行都测不到。
///
/// 目前唯一的消费方是 Last.fm 统计页的「第 N 次听」:scrobble 是把本机播放**原样**镜像
/// 上去的,同一首歌从不同播放器放,报的歌名写法一繁一简,Last.fm 就记成两个曲目实体、
/// 两本分开的账(实测《我不是农人》11 次/《我不是農人》3 次,2026-08-18 用户截图)。
/// autocorrect=1 帮不上忙 —— 它只在「查询的实体不存在」时才改写,这两个实体都真实存在。
/// 所以显示端取次数时要把孪生写法也查一遍、求和。
///
/// 方向选择:先试繁→简,有变化就用;没变化再试简→繁。都用 ICU(CFStringTransform),
/// 跟 EnrichCacheKeys.looseKey 同一套。⚠️ 简→繁本质是一对多(发→發/髮),ICU 挑的未必是
/// Last.fm 上真实存在的那个写法 —— 挑错的后果只是那一次 getinfo 查不到、贡献 0 次,
/// 可接受;绝不能反过来把这个转换结果当权威写法去显示或者构造 key。
public enum HanScript {
    /// (歌手, 歌名) 的繁简孪生写法;两个字段都转不动(纯拉丁/写法本就相同)时返回 nil。
    /// 两个字段必须用**同一个方向**转 —— 一繁一简混拼出来的组合在 Last.fm 上不存在。
    public static func siblingPair(artist: String, title: String)
        -> (artist: String, title: String)?
    {
        let sa = transform(artist, "Hant-Hans"), st = transform(title, "Hant-Hans")
        if sa != artist || st != title { return (sa, st) }
        let ta = transform(artist, "Hans-Hant"), tt = transform(title, "Hans-Hant")
        if ta != artist || tt != title { return (ta, tt) }
        return nil
    }

    /// 单串版,给「歌手|歌名」这类**已经拼好**的 key 用(分隔符不是汉字,转换动不了它)。
    public static func sibling(_ s: String) -> String? {
        let t2s = transform(s, "Hant-Hans")
        if t2s != s { return t2s }
        let s2t = transform(s, "Hans-Hant")
        if s2t != s { return s2t }
        return nil
    }

    private static func transform(_ s: String, _ id: String) -> String {
        let m = NSMutableString(string: s) as CFMutableString
        CFStringTransform(m, nil, id as CFString, false)
        return m as String
    }
}

/// 「第 N 次听」的写法孪生候选(2026-08-18 从纯繁简扩成写法族)。
///
/// 实测坐实的分裂形态(丁世光《神经志》,用户截图"专辑各首次数极不均匀"):同一首歌在
/// Last.fm 被**括号风格**拆成多本账 —— `一口（The Day You Left Me）`(全角,Spotify
/// 现在报的)2 次、`一口(The Day You Left Me)`(半角无空格,历史来源报的)25 次、
/// `一口` 1 次;全专辑只有 E.T./Simon 这种纯 ASCII 歌名从没分裂过(31/29 次),反而
/// 显得"不均匀"。所以候选按实测的账量排序:半角无空格 > 全角 > 半角带空格 > 纯中文名
/// > 繁简孪生,封顶 4 个(每个候选是一次 getinfo 的代价,结果随总数一起缓存)。
/// 括号变体只对**含汉字**的歌名生成 —— 纯英文的 `(feat. …)` 副题各来源写法一致,
/// 生成变体只会白烧限速额度。
public enum PlayCountVariants {
    /// 繁体内部的字形变体对(2026-08-18 实测坐实):历史来源写《愛在什麽地方都有》用的
    /// 是「麽」(U+9EBD),Spotify 现在报「麼」(U+9EBC),肉眼几乎相同却是两个实体
    /// (70 条 scrobble 全记在麽形下,括号/繁简变体全部扑空)。这一族的共同点是 ICU
    /// **两个方向都到不了**:t2s 时两个都折到同一个简体,s2t 却永远只生成其中一个 ——
    /// 所以必须显式列表。挑的都是歌名里真实出现过/高频的:麼麽、裡裏、為爲、晚晩、
    /// 線綫、眾衆。发现新的分裂再添。
    static let hanVariantPairs: [Character: Character] = [
        "麼": "麽", "麽": "麼", "裡": "裏", "裏": "裡", "為": "爲", "爲": "為",
        "晚": "晩", "晩": "晚", "線": "綫", "綫": "線", "眾": "衆", "衆": "眾",
    ]

    /// 把字形变体表应用到整串(全部命中字符一起换);没有可换的字返回 nil。
    static func variantSwapped(_ s: String) -> String? {
        guard s.contains(where: { hanVariantPairs[$0] != nil }) else { return nil }
        return String(s.map { hanVariantPairs[$0] ?? $0 })
    }

    /// 返回不含本尊、已按 歌手|歌名 小写键去重的候选列表(封顶 6)。
    /// 顺序即优先级(实测账量):半角无空格(本字形→变体字形)> 全角(同序)>
    /// 半角带空格 > 纯名 > 繁简孪生 —— 封顶挤掉的永远是低优先级候选。
    public static func siblings(artist: String, title: String) -> [(artist: String, title: String)] {
        var out: [(artist: String, title: String)] = []
        var seen: Set<String> = [fold(artist, title)]
        func add(_ a: String, _ t: String) {
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, out.count < 6, seen.insert(fold(a, trimmed)).inserted else { return }
            out.append((a, trimmed))
        }
        // 目录学噪音副题(remaster/feat 家族):不论是否含汉字都补一个「去副题」候选
        // (2026-08-19 用户实测 Automatic (Remastered 2014) vs Automatic 两本账 ——
        // 纯拉丁歌名此前完全不生成任何括号候选)。真版本((Live)/(Remix))不在此列,
        // 见 isCatalogNoiseSubtitle。
        if let (base, sub) = subtitleSplit(title), isCatalogNoiseSubtitle(sub) {
            add(artist, base)
        }
        if let (base, sub) = subtitleSplit(title), containsHan(title) {
            let bases = [base] + (variantSwapped(base).map { [$0] } ?? [])
            for b in bases { add(artist, "\(b)(\(sub))") }
            for b in bases { add(artist, "\(b)（\(sub)）") }
            add(artist, "\(base) (\(sub))")
            for b in bases { add(artist, b) }
        } else if let swapped = variantSwapped(title) {
            // 无副题但含变体字:直接给字形变体候选
            add(artist, swapped)
        }
        if let sib = HanScript.siblingPair(artist: artist, title: title) {
            add(sib.artist, sib.title)
        }
        return out
    }

    /// 目录学噪音副题:同一份录音在不同曲库间的写法差异,不是真版本。两族:
    ///  - **remaster 家族**:`(Remastered 2014)` / `(2014 Remaster)` / `(Remastered
    ///    Version)`(2026-08-19 用户实测:宇多田ヒカル「Automatic (Remastered 2014)」
    ///    与「Automatic」两本账 —— 纯拉丁歌名既不生成括号候选、折叠键又刻意保留副题,
    ///    两道设计正好都躲过);
    ///  - **feat 客串署名家族**:`(feat. X)` / `(feat X)` / `(featuring X)` / `(ft. X)`
    ///    是歌手信息、不是版本(2026-08-19 同日用户实测第二波:王力宏「盖世英雄
    ///    (feat. 欧阳靖 & 李岩)」第 2 次 vs「蓋世英雄」的几十次,历史账全记在无副题
    ///    繁体形下)。
    /// 只认**完整**命中 —— `(Live)` / `(Remix)` / `(Acoustic)` 是真的不同录音,照旧分开;
    /// 混着别的词的副题(`(Live 2014 Remaster)`)也不动,宁可漏合。
    static func isCatalogNoiseSubtitle(_ sub: String) -> Bool {
        let normalized = sub.precomposedStringWithCompatibilityMapping
            .lowercased().trimmingCharacters(in: .whitespaces)
        if normalized.range(
            of: "^(\\d{4}\\s+)?remaster(ed)?(\\s+\\d{4})?(\\s+version)?$",
            options: .regularExpression) != nil {
            return true
        }
        // feat 家族:前缀 + (点或空格) + 非空署名。"feathers" 这类只是巧合同头的词
        // 靠「必须跟点/空格」挡住;空署名("(feat.)")不算,不折。
        for prefix in ["featuring", "feat", "ft"] where normalized.hasPrefix(prefix) {
            let rest = normalized.dropFirst(prefix.count)
            guard let boundary = rest.first, boundary == "." || boundary == " " else { continue }
            if !rest.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        return false
    }

    /// 歌名结尾的括号副题:`一口（The Day You Left Me）` → ("一口", "The Day You Left Me")。
    /// 开/闭括号不要求同风格配对 —— 目的只是切出副题,不是校验语法。
    static func subtitleSplit(_ title: String) -> (base: String, sub: String)? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let last = t.last, last == "）" || last == ")" else { return nil }
        let body = t.dropLast()
        guard let openIdx = body.lastIndex(where: { $0 == "（" || $0 == "(" }) else { return nil }
        let base = String(body[..<openIdx]).trimmingCharacters(in: .whitespaces)
        let sub = String(body[body.index(after: openIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !sub.isEmpty else { return nil }
        return (base, sub)
    }

    static func containsHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    private static func fold(_ a: String, _ t: String) -> String {
        a.trimmingCharacters(in: .whitespaces).lowercased()
            + "|" + t.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// 「第 N 次听」写法索引的折叠键(2026-08-19,数据驱动合并的地基)。
///
/// 与 PlayCountVariants(猜枚举)相反的思路:不猜写法,而是把用户**自己历史上真实出现过**
/// 的写法按这个键归到同一族,查次数时按族查。这个键要把实测见过的全部分裂维度都折掉:
///  - 全角/半角括号与全角空格(NFKC);
///  - 繁简 + 同折简体的字形变体(ICU Hant-Hans:麼/麽 都折到 么,验证于 2026-08-18);
///  - 空格有无(全部剥除)、大小写;
///  - 「CJK 段 + 空格 + 拉丁段」的双语拼接名(实测《月食 The Weeping Woman》30 次 vs
///    《月食》6 次)—— 恰好两段时取 CJK 段,对应导出脚本的 R1 规则。
/// 刻意**不**折一般括号副题:`一口(The Day You Left Me)` 与 `一口` 不同键 ——括号常携带
/// 版本信息((Live)/(Remix)),折掉会把不同录音并成一首(沿用导出脚本的取舍)。
/// **唯一例外是目录学噪音**(2026-08-19):`(remastered 2014)` 这类 remaster 家族、
/// `(feat. X)` 这类客串署名家族,都是同一份录音的目录学差异,折掉 —— 判定见
/// PlayCountVariants.isCatalogNoiseSubtitle。
/// ⚠️ 只用于索引查询,绝不用于显示、绝不用于构造别处的 key。
/// ⚠️ 折叠规则演进后旧索引文件不用重建:loadTitleForms 加载时按当前规则从真实写法
/// 重算全部键(键不入信盘上存的),自动就地迁移。
public enum PlayCountFold {
    /// 折叠规则版本。**凡改动 key/foldTitle 的语义必须 +1**:写法索引文件把这个数
    /// 存在身上,加载时版本一致就直接采用盘上的键(零计算),不一致才做一次性重折迁移
    /// (见 LastfmStatsService.loadTitleForms)。1=初版;2=remaster 噪音折叠;3=feat 噪音。
    public static let foldVersion = 3

    /// key 的 memo(2026-08-19 性能审计):单次 key 要走 2 次 NFKC + 2 次 ICU 繁简
    /// transform(各自新建 CFMutableString),几十 µs 量级;而每次刷新最近记录都对同一批
    /// 行反复算。输入是有限集合(用户听过的写法),按原始串缓存。上锁而不是挂 @MainActor:
    /// 现有调用方都在主线程,但这个类型在 LyrimuseCore,不该替它锁死并发前提。
    /// 只增不清:一条 ~100 字节,进程生命周期内到不了需要淘汰的量级。
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var keyCache: [String: String] = [:]

    public static func key(artist: String, title: String) -> String {
        let raw = artist + "\u{1F}" + title
        cacheLock.lock()
        let hit = keyCache[raw]
        cacheLock.unlock()
        if let hit { return hit }
        let value = stripSpaces(normalized(artist)) + "|" + foldTitle(title)
        cacheLock.lock()
        keyCache[raw] = value
        cacheLock.unlock()
        return value
    }

    public static func foldTitle(_ title: String) -> String {
        stripSpaces(collapseBilingual(stripCatalogNoise(normalized(title))))
    }

    /// 循环剥掉结尾的目录学噪音副题(可能叠多层:`x (feat. y) (remastered 2014)`)。
    /// 输入已经 normalized(NFKC+小写),括号必为半角。放在 collapseBilingual 之前:
    /// 剥掉副题后「CJK 段 + 拉丁段」的双语拼接名才有机会走 R1 收敛。
    static func stripCatalogNoise(_ s: String) -> String {
        var t = s
        while let (base, sub) = PlayCountVariants.subtitleSplit(t),
              PlayCountVariants.isCatalogNoiseSubtitle(sub) {
            t = base
        }
        return t
    }

    /// NFKC(全角→半角) → 繁简(ICU) → 小写。
    private static func normalized(_ s: String) -> String {
        let nfkc = s.precomposedStringWithCompatibilityMapping
        let m = NSMutableString(string: nfkc) as CFMutableString
        CFStringTransform(m, nil, "Hant-Hans" as CFString, false)
        return (m as String).lowercased()
    }

    /// R1:恰好「CJK 段 + 拉丁段」(顺序不限、以空格分界、不含括号)的双语拼接名
    /// → 取 CJK 段。含括号或段落交错的不动 —— 宁可漏合,不错合。
    static func collapseBilingual(_ s: String) -> String {
        guard !s.contains("("), !s.contains(")") else { return s }
        let t = s.trimmingCharacters(in: .whitespaces)
        let tokens = t.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return t }
        let flags = tokens.map { PlayCountVariants.containsHan($0) }
        guard flags.contains(true), flags.contains(false) else { return t }
        // CJK 全在前缀:后面全是拉丁
        if flags[0], let cut = flags.firstIndex(of: false), !flags[cut...].contains(true) {
            let han = tokens[..<cut].joined()
            if han.count >= 2 { return han }
        }
        // CJK 全在后缀:前面全是拉丁
        if !flags[0], let cut = flags.firstIndex(of: true), !flags[cut...].contains(false) {
            let han = tokens[cut...].joined()
            if han.count >= 2 { return han }
        }
        return t
    }

    private static func stripSpaces(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }
}
