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

    /// 目录学噪音副题:同一份录音在不同曲库间的写法差异,不是真版本。
    ///
    /// 口径的**权威来源**是 `scripts/export-lastfm-tracks.py`(2026-08-18 与用户逐对核定,
    /// 见那份 docstring 的 T1/T2 与「刻意不做」清单)。Swift 侧此前只搬了它的两族,
    /// 2026-08-22 补齐剩下的 —— 用户报周杰倫《一路向北 (bonus track)》显示「第 2 次听」,
    /// 实测 Last.fm 两个实体:「一路向北」14 次、「一路向北 (bonus track)」2 次,真实合计 16。
    /// 改动前后的差距就是「Swift 落后于自己的参考实现」这一条,不是新发明的规则。
    ///
    /// 两大类:
    ///  - **客串署名家族**(署名是歌手信息、不是版本):`(feat. X)` / `(feat X)` /
    ///    `(featuring X)` / `(ft. X)`(2026-08-19 用户实测:王力宏「盖世英雄
    ///    (feat. 欧阳靖 & 李岩)」第 2 次 vs「蓋世英雄」几十次),以及 **`(with X)`**
    ///    (2026-08-22 补;参考实现的 T1 一直把 with 与 feat 并列。用户索引里 19 条,
    ///    实测 7 例真碰撞:周杰倫《不該 (with aMEI)》、Daniel Caesar《Toronto 2014
    ///    (with Mustafa)》、MJ《The Girl Is Mine (with Paul McCartney)》…)。
    ///    ⚠️ 残余风险已知并接受:`(With or Without You)` 这种以 with 开头的**词组**副题
    ///    会被当成署名剥掉(署名非空守卫拦不住它)。真出现了在这里加个词组黑名单,
    ///    别去动「前缀后必须跟点/空格」那道守卫 —— 那道是挡 "(Feathers)" 用的。
    ///  - **再版/发行标签家族**(同一份录音在不同版本专辑、不同分级下的收录标记):
    ///    `(Remastered 2014)` / `(2014 Remaster)` / `(Remastered Version)`
    ///    (2026-08-19 实测:宇多田ヒカル「Automatic (Remastered 2014)」与「Automatic」
    ///    两本账);`(Bonus Track)`(2026-08-22,用户报的那首);`(Explicit)`
    ///    (2026-08-22,索引里 5 条、2 例真碰撞:方大同《无所谓 (Explicit)》《烦 (Explicit)》)。
    ///
    /// 只认**完整**命中 —— `(Live)` / `(Remix)` / `(Acoustic)` 是真的不同录音,照旧分开;
    /// 混着别的词的副题(`(Live 2014 Remaster)`)也不动,宁可漏合。bonus 前面只允许挂
    /// **地区/渠道**限定词(`(Japanese Bonus Track)`),刻意**不**允许任意词 ——
    /// 「(Live Bonus Track)」那种带版本信息的必须挡住。参考实现用的是括号内**子串**匹配,
    /// 这里没跟 —— 完整命中是 Swift 侧一贯的取舍,子串会让上面那条挡不住。
    ///
    /// ⚠️ 刻意**不**收的(与参考实现的「刻意不做」清单一致,别顺手加):
    ///  - `(Clean)`:消音版是另一份音频。⚠️ 2026-08-22 订正:这里原来写的理由是
    ///    「索引里有《Simple and Clean》,子串匹配会误伤它」—— **那条理由是错的**,
    ///    裸标题《Simple and Clean》末尾没有右括号,subtitleSplit 恒返回 nil,判定
    ///    根本摸不到它。真正会被误伤的是**副题**形态 `X (Simple and Clean)`,
    ///    selftest 里钉的就是这一条。结论没变,理由别再照旧的抄。
    ///  - `(original version)`:MJ《Xscape》的原始版与当代化版是两套制作(参考实现附录 B)。
    ///  - `(single version)` / `(7" Single Edit)`:单曲剪辑,用户未拍板。
    ///  - `(國)` / `(粵)`:参考实现只把《愛情轉移(國)》做成**手工对**而没有立通则 ——
    ///    《K歌之王》这类同名國/粵两版是真的两份录音,通则会错合。用户索引里 7 条,
    ///    要合得单独拍板。
    static func isCatalogNoiseSubtitle(_ sub: String) -> Bool {
        let normalized = sub.precomposedStringWithCompatibilityMapping
            .lowercased().trimmingCharacters(in: .whitespaces)
        // 地区/渠道限定词:附加曲标记常带发行地或渠道前缀。刻意是白名单而不是 `\\w+`。
        let region = "japan(ese)?|jp|us|uk|eu|international|digital|itunes|deluxe(\\s+edition)?|cd|hidden"
        for pattern in [
            "^(\\d{4}\\s+)?remaster(ed)?(\\s+\\d{4})?(\\s+version)?$",
            "^((\(region))\\s+)?bonus(\\s+track)?(\\s+version)?$",
            "^explicit(\\s+version)?$",
        ] where normalized.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        // 客串署名家族:前缀 + (点或空格) + 非空署名。"feathers" 这类只是巧合同头的词
        // 靠「必须跟点/空格」挡住(实测 Without You / Withdrawal / Within Temptation
        // 全部被它挡住,这道守卫别动);空署名("(feat.)")不算,不折。
        for prefix in ["featuring", "feat", "ft", "with"] where normalized.hasPrefix(prefix) {
            let rest = normalized.dropFirst(prefix.count)
            guard let boundary = rest.first, boundary == "." || boundary == " " else { continue }
            let credit = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !credit.isEmpty else { continue }
            // `with` 专属的第二道:feat./ft./featuring 是纯署名标记,语法上后面只能跟
            // 表演者;`with` 是介词,后面还可以跟乐队编制、音频内容,本身又能当歌名首词。
            // 这是 with 与 feat 的本质不对称,守卫不能照搬。
            if prefix == "with",
               let head = credit.split(whereSeparator: { $0.isWhitespace }).first,
               nonCreditHeadWords.contains(
                   String(head).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)) {
                continue
            }
            return true
        }
        return false
    }

    /// `(with …)` 后面跟的**不是人**的头词。两类:
    ///  ①乐队编制/音频内容(strings / orchestra / intro / backing …)—— 那标的是
    ///    **另一份录音**(重录的管弦版之类),不是署名;
    ///  ②冠词与连接词(the / a / or / out …)—— 说明副题是个**词组**而不是署名,
    ///    典型 `(With or Without You)` / `(With A Little Help From My Friends)`,
    ///    剥掉会把两首**不同的歌**并成一首。
    /// ⚠️ 这份用户索引里 19 条 `(with …)` 的头词全是真人名,这张表**当下 0 命中**——
    /// 也就是加它零行为变化。加的理由是折叠键会**永久**写进索引文件,而这个库里就有
    /// Horace Silver / Paul Desmond / Johnny Griffin / Nancy Wilson 这批爵士,
    /// 「with strings」正是该品类的标准写法,哪天进库就是错合。
    /// 代价:`with The Weeknd` 会被 `the` 漏掉 —— 符合本文件一贯的「宁可漏合,不错合」。
    static let nonCreditHeadWords: Set<String> = [
        "the", "a", "an", "no", "or", "out", "my", "your", "all",
        "strings", "string", "orchestra", "orchestral", "choir", "chorus", "band",
        "intro", "outro", "interlude", "dialogue", "commentary", "narration",
        "vocal", "vocals", "backing", "drums", "beat", "beats", "rain", "lyrics",
        "弦乐", "弦樂", "交响", "交響", "乐团", "樂團", "伴奏", "和声", "和聲", "前奏",
    ]

    /// 版本/发行标记词:这一段不是"译名"而是"另一份录音的标记"。刻意**不**收 feat/with ——
    /// 那是署名(目录学噪音),该收敛;这里收的是"不同录音"。
    /// 输入都已过 PlayCountFold.normalized(NFKC + ICU 繁简 + 小写),所以只列**简体**形。
    static let versionMarkerWords: Set<String> = [
        "live", "demo", "remix", "mix", "acoustic", "instrumental", "inst", "karaoke",
        "unplugged", "reprise", "edit", "version", "remaster", "remastered", "acappella",
        "alternate", "reimagined", "session", "sessions", "medley", "dub",
    ]

    /// 中文的版本词。中文没有空格、分不了词,所以另走一条判据:整串以「版」收尾
    /// (钢琴版/独唱版/live版/国语版/完整版),或整串就是这几个词。
    static let cjkVersionWords: Set<String> = ["现场", "演唱会", "纯音乐", "伴奏", "原唱"]

    /// 这个尾缀是不是**版本标记**。给分隔符归一用(见 PlayCountFold.canonicalizeVersionSuffix)。
    static func isVersionSuffix(_ sub: String) -> Bool {
        let t = sub.trimmingCharacters(in: .whitespaces)
        let squeezed = String(t.filter { !$0.isWhitespace })
        // 「…版」/「…版本」都是中文的 version。`版本` 单独判是因为它以「本」收尾、
        // hasSuffix("版") 接不住(实测漏判 `你不知道的事 - 宋曉青版本`)。
        if squeezed.hasSuffix("版") || squeezed.hasSuffix("版本") { return true }
        if cjkVersionWords.contains(squeezed) { return true }
        return t.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .contains { versionMarkerWords.contains($0) }
    }

    /// **裸场次标记** —— 这类尾缀说明"是个现场版",但**不说明是哪一场**。
    ///
    /// 2026-08-22 用 album.getinfo 实测坐实(推翻了原来的归一设计):方大同索引里 21 条
    /// `X - Live` 与《This Love Live 2007》的 21 首曲目**完全双射**,而 30 条 `X (Live)`
    /// 只有 2 首落在那张里 —— 两种写法指的是**两场不同的演唱会**(重叠曲目时长也不同:
    /// 手拖手 2007=233s / 2011=236s,而索引里 `手拖手 (Live)` 报的正是 236000)。
    /// 一个歌手可以有四五张现场专辑,所以裸 `live` 是**信息缺失**,不是"内容相同即同一录音"。
    ///
    /// 于是分隔符归一必须**跳过**这一类:归一的立论是「分隔符不携带信息、副题内容才携带」,
    /// 对 `(钢琴版)`/`(single version)`/`(Instrumental)` 成立(那种版本一首歌通常只有一个),
    /// 对裸 `live` **不成立**。代价:同一场演唱会被两种写法记的会继续分开算(漏合,安全方向);
    /// 带场次信息的(`[Live 08]` / `- 15 Khalil Live in HK 2011`)照旧归一。
    static let ambiguousConcertMarkers: Set<String> = [
        "live", "现场", "现场版", "live版", "演唱会", "演唱会版", "演唱会现场",
    ]

    /// 方括号尾缀:`南音 [Live 08]` → ("南音", "Live 08")。
    /// ⚠️ **只给分隔符归一用**,刻意不接进 stripCatalogNoise —— 「方括号里的目录学噪音要不要剥」
    /// 是另一个还没拍板的口径(2026-08-22 的 E 项),混进来会顺手改掉它。
    static func bracketSuffixSplit(_ title: String) -> (base: String, sub: String)? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let last = t.last, last == "]" || last == "】" else { return nil }
        let body = t.dropLast()
        guard let open = body.lastIndex(where: { $0 == "[" || $0 == "【" }) else { return nil }
        let base = String(body[..<open]).trimmingCharacters(in: .whitespaces)
        let sub = String(body[body.index(after: open)...]).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !sub.isEmpty else { return nil }
        return (base, sub)
    }

    /// 破折号版本尾缀:`Bad - 2012 Remaster` → ("Bad", "2012 Remaster")。
    /// 破折号**两侧必须有空白** —— 参考实现 export-lastfm-tracks.py 用的
    /// `\s*[-–]\s*` 会把 `Anti-Remastered` 切成 `Anti`(实测),这里刻意不照抄。
    /// 副题是不是噪音由 isCatalogNoiseSubtitle 判,
    /// 这里只负责切 —— 这个用户索引里 216 条破折号尾缀,只有 6 条能过那道判定。
    static func dashSuffixSplit(_ title: String) -> (base: String, sub: String)? {
        let t = title.trimmingCharacters(in: .whitespaces)
        // 取**最后**一个分隔符。⚠️ 不能写 `options: [.regularExpression, .backwards]` ——
        // Foundation 里这两个 option 同用时 .backwards **不生效**,返回的是第一个匹配
        // (2026-08-22 实测:`苏州河 - 慕容雪 - Mandarin Version` 被切成 base=`苏州河`,
        // 于是它跟 `蘇州河 - 慕容雪 (Mandarin Version)` 落进两个族 —— 正是归一要消除的碎片)。
        var lastRange: Range<String.Index>?
        var from = t.startIndex
        while let hit = t.range(of: "\\s+[-\u{2013}\u{2014}]\\s+",
                                options: .regularExpression, range: from..<t.endIndex) {
            lastRange = hit
            from = hit.upperBound
        }
        guard let r = lastRange else { return nil }
        let base = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        let sub = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !sub.isEmpty else { return nil }
        return (base, sub)
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
    /// (见 LastfmStatsService.loadTitleForms)。1=初版;2=remaster 噪音折叠;3=feat 噪音;
    /// 4=补齐到参考实现口径(with 客串 + bonus track + explicit)+ 派生串 R1 版本标记
    /// 守卫(2026-08-22);5=同日第二批:破折号版本尾缀(`Bad - 2012 Remaster`)+ with
    /// 头词黑名单;6=同日第三批(**用户拍板**):R1 守卫套到原串(中文歌名的 Live 版不再
    /// 并进录音室版)+ 版本尾缀分隔符归一;7=第三批的修正(并行核实推翻了归一的一半):
    /// 裸场次标记不归一 + dashSuffixSplit 真取最后一个分隔符 + 归一后补剥一次目录学噪音 +
    /// 别名表剔掉 jasonchan/kun。⚠️ 前几版都装过机、盘上可能已被盖成那个号,
    /// 所以每一批都必须再 +1,否则「版本相等直接采用盘上旧键、永不迁移」。
    ///
    /// ⚠️ **`familyKey`/`canonicalArtist`/歌名别名表的改动不算在内,不用 +1**:
    /// 这个版本号只管 `key()`/`foldTitle()` 落进 `titleForms` 索引的键要不要重折——
    /// `familyKey` 是**派生**索引 `primaryCreditFamilies` 的键,`loadTitleForms` 两条分支
    /// (版本相等/不等)**都无条件**调用 `rebuildPrimaryCreditFamilies()`(2026-08-29 读代码
    /// 确认),也就是每次启动都会用当前 `familyKey` 重新分组,不需要靠这个版本号触发迁移。
    /// 2026-08-29 新增歌名别名表时特意验证过这一点,没有 +1。
    public static let foldVersion = 7

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

    /// 查「写法族」用的键(2026-08-22 第三批):歌手先归**合唱首位**(mergeArtist),
    /// 再把**罗马字写法折到中文本名**(canonicalArtist,本机推断的歌手别名表);歌名走 foldTitle,
    /// 另外查歌名别名(本机推断表 → 自动发现表,2026-09-04 起没有手写表)把歌名维度的罗马字/译名
    /// 也折到中文本名。
    ///
    /// 三个调用点必须**完全**用这一个函数(LastfmStatsService 的 insertForm /
    /// playCountSiblings、LastfmStatsSection 的 recentRows)—— 之前是三处各自拼
    /// `key(artist: mergeArtist(...), title:)`,任一处漏改就会出现「取数用的是合并总数、
    /// 减法用的是另一套键」这种自相矛盾(2026-08-21 用户报的「第 15 次听下面紧跟第 21 次听」
    /// 就是那个形状)。
    ///
    /// 只作用在**派生索引** primaryCreditFamilies 的键上,不改 PlayCountFold.key 本身的
    /// 歌手口径 —— 沿用 2026-08-20 合唱 credit 归并的既有做法:那个键是整本统计账的身份,
    /// 而这里要的只是「查族时多看一眼隔壁桶」。
    public static func familyKey(artist: String, title: String) -> String {
        let canonArtist = canonicalArtist(artist)
        let artistKey = canonicalArtistKey(canonArtist)
        let foldedTitle = foldTitle(title)
        // 本机推断表(同歌曲 id / 时长+歌词,证据硬)优先于自动发现表(Last.fm 整秒时长撞相等,弱)。
        let canonTitle = lookupLocalTitleAlias(artistKey: artistKey, foldedTitle: foldedTitle)
            ?? lookupDiscoveredTitleAlias(artistKey: artistKey, foldedTitle: foldedTitle)
            ?? title
        return key(artist: canonArtist, title: canonTitle)
    }

    /// `familyKey` 拼外层键那一步单独拎出来 —— App 侧的自动发现扫描
    /// (LastfmStatsService.discoverTitleAliasesIfNeeded)要按「同一个歌手」分组比较
    /// 候选写法,得用**跟 familyKey 完全同一把尺子**算歌手键,不能自己另写一遍归一逻辑
    /// (两处稍有出入就会出现"发现表写的键,familyKey 查的时候对不上"的静默失效)。
    /// 参数接受原始歌手写法即可(内部会先 canonicalArtist),不要求调用方先归一。
    public static func canonicalArtistKey(_ artist: String) -> String {
        stripSpaces(normalized(canonicalArtist(artist)))
    }

    /// 一个歌名折叠键里完全不含汉字/假名 —— 判定"这是候选的罗马字/译名写法,值得去
    /// 找它的中文对应"的信号。复用 LyricsSyncEngine 里给歌词抬头分段判定用的
    /// `CharacterSet.hanLike`(汉字 + 假名),不新造一套字符集判断。
    public static func hasNoHanLikeChars(_ s: String) -> Bool {
        !s.unicodeScalars.contains { CharacterSet.hanLike.contains($0) }
    }

    /// 合唱归首位 + 歌手写法归并(罗马字艺名 / 乐队别名 → 本机数据里的代表写法)。查不到就原样返回
    /// (交给 key() 去做常规归一)。
    ///
    /// 2026-09-04 起**没有手写表**:此前这里查的是编译进二进制的 `romanizedArtistAliases`(28 条,
    /// `davidtao → 陶喆` 这种),用户要求「尽可能去掉手工表,一切由通用逻辑覆盖,不要特殊化」——现在
    /// 查的是 App 启动/enrich 缓存变化时由 `LocalArtistAliases.derive` 从本机数据推出来、经
    /// `setLocalArtistAliases` 灌进来的表(证据:collector 的 MusicBrainz 缓存 + 两种写法名下曲目共享
    /// ≥ 2 个歌曲 id,详见那个文件的头注)。实测这台机器上历史里真有两种写法并存的歌手
    /// (Khalil Fong / David Tao / Jay Chou / Wang Leehom / Dean Ting / Crowd Lu / Leah Dou)全部
    /// 被推出来了;旧表里其余那些(Eason Chan / Sodagreen / Utada …)历史里压根没有罗马字写法的
    /// 播放,删掉零损失,以后一旦出现也会由同一套逻辑接住。
    ///
    /// 旧表刻意剔掉的 `jasonchan` / `kun` 那两条的教训(Last.fm 那边是同名多人/大杂烩实体)在新
    /// 逻辑里对应两道闸:MusicBrainz 别名去空格后短于 3 个字符不用、共享 id 单个不算。
    public static func canonicalArtist(_ artist: String) -> String {
        let primary = ArtistCredit.mergeArtist(artist)
        return lookupLocalArtistAlias(stripSpaces(normalized(primary))) ?? primary
    }

    private static let artistLock = NSLock()
    nonisolated(unsafe) private static var localArtistAliases: [String: String] = [:]

    /// 灌入 `LocalArtistAliases.derive` 的结果:`stripSpaces(normalized(mergeArtist(写法))) → 代表写法`。
    public static func setLocalArtistAliases(_ table: [String: String]) {
        artistLock.lock()
        localArtistAliases = table
        artistLock.unlock()
    }

    private static func lookupLocalArtistAlias(_ key: String) -> String? {
        artistLock.lock()
        let value = localArtistAliases[key]
        artistLock.unlock()
        return value
    }

    /// 歌名维度(2026-08-29 起)的别名分三层查(见 familyKey):本机推断表 → 自动发现表。手写的
    /// `titleAliasesByArtist`(方大同 7 条,三步法人工核过)2026-09-04 删除——同样是用户要求去掉手工表:
    /// 那 7 条现在由 `EnrichTitleAliases.derive` 的 E1(同歌曲 id)/E2(时长 + 歌词都对得上)两条证据
    /// 路径自动推出来(selftest 用它们当回归样本钉住)。当年那张表的三步核实法留下的两条经验仍然有效、
    /// 已经变成代码里的闸:①"平台官方标题是不是中文"跟"用户历史里用什么字写"是两件事,别拿前者
    /// 当后者;②时长比对不是可选项(`Weather Report` 61 s 过场曲 vs 《天氣先生》271 s,光看歌名/专辑
    /// 序号会误判)。

    /// 自动发现表(2026-08-29):当时用户问「只能这样一个一个加白名单吗,不能搞个通用逻辑」,拍板要
    /// 一套自动发现的机制——运行时可增长、持久化在本机的第二张表(算法用 Last.fm 整秒时长比对自动
    /// 确认,理论上有假阳性 —— 见 discoverTitleAliasesIfNeeded 的注释;2026-09-04 实测这台机器上它
    /// 既没在产出、产出时质量也不可信,所以 familyKey 里它排在本机推断表之后当兜底)。
    ///
    /// 存/取都由 App 侧的 LastfmStatsService 负责(它才有网络请求 + 本机文件读写的能力,
    /// 这个类型在 LyrimuseCore、selftest 也依赖它,不能牵涉 I/O)——这里只留一个线程安全的
    /// 内存副本 + 一个查询入口,App 启动加载完发现表后调 `setDiscoveredTitleAliases`
    /// 灌进来,发现新映射时再调一次覆盖。结构跟本机推断表完全一致:
    /// 外层键 = `canonicalArtistKey`,内层键 = `foldTitle`,值 = 中文歌名原始写法。
    private static let discoveredLock = NSLock()
    nonisolated(unsafe) private static var discoveredTitleAliasesByArtist: [String: [String: String]] = [:]

    public static func setDiscoveredTitleAliases(_ table: [String: [String: String]]) {
        discoveredLock.lock()
        discoveredTitleAliasesByArtist = table
        discoveredLock.unlock()
    }

    private static func lookupDiscoveredTitleAlias(artistKey: String, foldedTitle: String) -> String? {
        discoveredLock.lock()
        let value = discoveredTitleAliasesByArtist[artistKey]?[foldedTitle]
        discoveredLock.unlock()
        return value
    }

    /// 第三层歌名别名(2026-09-04):从**本机 enrich 缓存**推出来的「英文/罗马字歌名 → 中文歌名」。
    ///
    /// 用户点开方大同《Oasis》的合并明细问「能不能把中文对应的歌名也合并进来」——历史里
    /// 《那沙漠里的水》是同一首录音。两张既有表都够不着它:静态表要人工核实+改代码装机;
    /// 发现表靠 Last.fm 整秒 duration 撞相等,实测假阳性极高(2026-09-02 那台机器上 14 条采纳里
    /// 11 条是错的——「Mojito→红模仿」「Melody→中國姑娘」这种),而且它的扫描门(前台安静 60 s
    /// + 40 个请求的预算)在这台机器上从没让它跑完过一轮。
    ///
    /// 而 collector 早就替我们做过一件更可靠的事:两种写法各自播放时,歌词解析各自独立地把
    /// 它们匹配到了**同一个网易云 / QQ 的歌曲 id**(`netease_url` / `qq_music_url` 落在 enrich
    /// 缓存里)。两次独立检索落到同一个 id,比"时长整秒相等"硬得多,而且零网络、零新请求 ——
    /// 判定在 EnrichTitleAliases.derive(纯函数,selftest 钉住),App 侧 enrich 缓存一变就重算。
    /// 查找顺序:静态表 → 发现表 → 这张表;结构与前两张完全一致。
    private static let localLock = NSLock()
    nonisolated(unsafe) private static var localTitleAliasesByArtist: [String: [String: String]] = [:]

    public static func setLocalTitleAliases(_ table: [String: [String: String]]) {
        localLock.lock()
        localTitleAliasesByArtist = table
        localLock.unlock()
    }

    private static func lookupLocalTitleAlias(artistKey: String, foldedTitle: String) -> String? {
        localLock.lock()
        let value = localTitleAliasesByArtist[artistKey]?[foldedTitle]
        localLock.unlock()
        return value
    }

    public static func foldTitle(_ title: String) -> String {
        let n = normalized(title)
        let stripped = stripCatalogNoise(n)
        // 2026-08-22 第三批(用户拍板):中文歌名的 Live/Demo 版此前被 R1 当译名收进录音室版
        // (`流沙 - Live` → 《流沙》),而英文歌名的 `Melody - Live` 因为不含 CJK 段根本进不了
        // R1 —— 中英待遇不一致,也跟 isCatalogNoiseSubtitle 注释里「Live/Remix/Acoustic
        // 照旧分开」自相矛盾。实测拆开 54 族(方大同/陶喆居多),那些「本尊」行的数字合计小 200
        // —— 变对了,不是回归。顺带修掉两个重度退化键:`方大同|live版`(All Night /
        // Ten Reasons / Catch a Dream 三首**不同的歌**焊成一族)、`方大同|薛凱琪`
        // (`Something Stupid [Live 08] featuring 薛凱琪` 折成 薛凱琪)。
        //
        // 两步分工(变异测试实测出来的,别搞反):
        // ① canonicalizeVersionSuffix 干了**绝大部分**活 —— 尾缀是版本标记时归一成括号形,
        //    而 R1 见括号就 bail,于是所有「尾缀型」版本词自然被挡住。撤掉它有 7 条断言变红。
        // ② collapseBilingualGuardingVersionMarkers 现在对**原串**也生效,但它真正承重的
        //    只剩一种:版本词**不在尾缀位置**、切不出来的形态 —— 实测只有
        //    `Something Stupid [Live 08] featuring 薛凱琪`(方括号在中间)这一条会红。
        //    别因为「看起来只值一条断言」就删掉它:那一条正是把一整首歌折成人名的那种硬错。
        // ⚠️ 归一之后必须**再剥一次**目录学噪音:归一会把方括号里的内容翻成括号形,
        // 而 stripCatalogNoise 只认括号 —— 少了这一步,`一口 [Remastered 2014]` 会从
        // 《一口》拆出去变成 `一口(remastered2014)`(并行核实抓到的潜伏回归;当前索引
        // 0 命中,但 Prince/MJ 那批方括号 remaster 标注一进中文标题就会踩到)。
        let canon = stripCatalogNoise(canonicalizeVersionSuffix(stripped))
        return stripSpaces(collapseBilingualGuardingVersionMarkers(canon))
    }

    /// 尾缀是版本标记时,把它的**分隔符**归一成半角括号 —— 分隔符不携带信息,副题内容才携带。
    ///
    /// 为什么必须跟上面那条 R1 守卫**同批**做:只修守卫的话,`流沙 - Live` 从《流沙》拆出来后
    /// 就跟本来就独立的 `流沙 (live)` 各成一族 —— 同一场录音又被分隔符拆开。实测分隔符碎片
    /// 会从 10 组涨到 **31** 组;两条一起做则降到 **0** 组(连 10 组存量一并清掉,
    /// 例如 `沙滩 (钢琴版)` 与 `沙灘 - 鋼琴版`、`Rock With You (single version)` 与
    /// `- Single Version`)。
    ///
    /// 刻意**只**对版本尾缀归一:`月食 - The Weeping Woman` 这种**译名**尾缀要留给 R1 收敛到
    /// 《月食》,一并归一会把它跟《月食》拆开。判定见 PlayCountVariants.isVersionSuffix。
    /// 切法按「圆括号 → 方括号 → 破折号」顺序试,命中即止 —— 只归一**最外层**那一个尾缀。
    static func canonicalizeVersionSuffix(_ s: String) -> String {
        let splits = [PlayCountVariants.subtitleSplit,
                      PlayCountVariants.bracketSuffixSplit,
                      PlayCountVariants.dashSuffixSplit]
        for split in splits {
            guard let (base, sub) = split(s), PlayCountVariants.isVersionSuffix(sub) else { continue }
            // 裸场次标记不归一 —— 它不说明是哪一场,归一会把两场不同的演唱会并成一首。
            // 判据与理由见 PlayCountVariants.ambiguousConcertMarkers。
            let squeezed = String(sub.filter { !$0.isWhitespace }).lowercased()
            if PlayCountVariants.ambiguousConcertMarkers.contains(squeezed) { return s }
            return base + "(" + sub + ")"
        }
        return s
    }

    /// 带版本标记守卫的 R1:任一拉丁词命中标记表就整串不动(宁可漏合)。
    /// 按词比对而不是子串 —— 否则《寂寞的季節 Lonely Season》里的 "season" 之类
    /// 会连带误伤;词两端的标点先剥掉(`[live` / `2009]` 这种方括号残片要能对上)。
    static func collapseBilingualGuardingVersionMarkers(_ s: String) -> String {
        let words = s.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
        if words.contains(where: isVersionToken) { return s }
        return collapseBilingual(s)
    }

    /// 单个词是不是版本标记。除了词表,还认「以 版 / 版本 收尾」——
    /// 中文没有空格,`Live版` / `现场版` / `国语版` 是**一个词**,词表接不住
    /// (2026-08-22:裸场次标记改成不归一之后,`All Night - Live版` 就从归一那条路
    /// 掉回 R1,而 R1 的「CJK 全在后缀」分支会把整首歌折成 `live版` ——
    /// 三首不同的歌焊成一族。这道判据是那个重度退化键的唯一防线)。
    static func isVersionToken(_ w: String) -> Bool {
        if PlayCountVariants.versionMarkerWords.contains(w) { return true }
        return w.hasSuffix("版") || w.hasSuffix("版本")
    }

    /// 循环剥掉结尾的目录学噪音副题(可能叠多层:`x (feat. y) (remastered 2014)`)。
    /// 输入已经 normalized(NFKC+小写),括号必为半角。放在 collapseBilingual 之前:
    /// 剥掉副题后「CJK 段 + 拉丁段」的双语拼接名才有机会走 R1 收敛。
    static func stripCatalogNoise(_ s: String) -> String {
        var t = s
        // 括号副题与破折号尾缀**交替**循环 —— 单独跑两遍的话
        // `X - 2012 Remaster (feat. Y)` 只掉一层。
        while true {
            if let (base, sub) = PlayCountVariants.subtitleSplit(t),
               PlayCountVariants.isCatalogNoiseSubtitle(sub) {
                t = trimTrailingJoiners(base); continue
            }
            if let (base, sub) = PlayCountVariants.dashSuffixSplit(t),
               PlayCountVariants.isCatalogNoiseSubtitle(sub) {
                t = trimTrailingJoiners(base); continue
            }
            break
        }
        return t
    }

    /// 剥完之后本尊尾巴上可能还挂着连接符(`X - 2012 Remaster (feat. Y)` 剥两层后是 `X -`)。
    /// 不能指望 collapseBilingual 碰巧擦干净 —— 它见空格分词,`x -` 会原样留着那个横杠。
    private static func trimTrailingJoiners(_ s: String) -> String {
        var t = s
        while let last = t.last,
              last.isWhitespace || "-\u{2013}\u{2014}:,\u{3001}".contains(last) {
            t.removeLast()
        }
        return t
    }

    /// NFKC(全角→半角) → 繁简(ICU) → 小写。
    /// 模块内可见(2026-09-04):PlayCountFoldExplainer 要沿这条流水线逐级比对给出「为什么并进来」,
    /// 必须用同一个函数而不是再写一遍归一。
    static func normalized(_ s: String) -> String {
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

    /// 模块内可见,理由同 normalized。
    static func stripSpaces(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }
}
