import Foundation

/// 歌词正文的简繁偏好。只影响**显示**,不动缓存里存的原文 —— 随时切回来都是无损的。
public enum ChineseVariant: String, CaseIterable, Sendable {
    case off, simplified, traditional

    /// ⚠️ 只对**中文**歌词生效,日文歌一律原样返回。
    ///
    /// 日文汉字里有大量新字体(学/国/条…),简繁转换会把它们一起改掉(学→學、国→國),
    /// 那不是"转成繁体",是把日文写坏。判据用"这段文字里有没有假名"——有假名就是日文,
    /// 中文歌不会有假名。
    ///
    /// 用 ICU 的 Simplified-Traditional。实测它不是无脑逐字:头发→頭髮、干净→乾淨、
    /// 后来→後來 都对,「只有你」也没被误转成「隻」;日文/拉丁字符完全不动。
    ///
    /// ⚠️ 但 ICU(以及 OpenCC)只管**繁简**,不管**异体字**,转简体时必须再补一层
    /// `HanVariants` —— 2026-08-22 用户报「开了简体还是看到繁体」,实例是《开不了口 (Live)》:
    /// ICU 把那首歌 37 种字符全转对了,只剩「妳」没动而它出现 21 次,整屏都是。「妳」不是
    /// 「你」的繁体,是大陆已淘汰、港台仍在用的异体字,所以两边的繁简表里都没有它。
    /// 完整判据和收录标准见 HanVariants。
    ///
    /// 反方向(转繁体)**刻意不做**异体字映射:简体只有「你」,转繁体时无从判断该写「你」
    /// 还是「妳」,那要猜被称呼者的性别。
    /// `converted(_:)` 会不会真的改动这段文字 —— 也就是"简繁转换对它有没有用"。
    ///
    /// 抽成单独一个判据(2026-08-31),是为了让**所有**依赖"这段文字算不算中文"的地方共用
    /// 同一份逻辑,不可能各自漂开:
    ///   - `converted(_:)` 自己的早退(下面);
    ///   - `LocalPlaybackSource.sawChineseLyrics`(粘性,设置页据它决定露不露出开关)——
    ///     那边原本就手抄了一份一模一样的条件,注释还专门写了"判据跟 ChineseVariant.converted
    ///     一致",正说明这是一份该被共享的逻辑,不是巧合;
    ///   - `LocalPlaybackSource.currentLyricsSupportsChineseVariant`(不粘,悬浮窗右键菜单
    ///     据它决定显不显示「简繁转换」)。
    ///
    /// ⚠️ 判据是"有汉字、且没有假名",**不是**"整首歌是不是中文歌"。这两者不等价,而且
    /// 用后者会出真 bug:
    ///   - `Romanizer.songScript(of:)` 把"含谚文"排在"含汉字"**之前**判,于是韩文歌里的
    ///     汉字(漢字)会让它返回 `.korean` —— 但 `converted(_:)` 并没有谚文守卫,照样会把
    ///     那些汉字转掉。按 songScript 隐藏菜单 = **正在转换、而开关不见了**,那正是
    ///     SettingsView 里那条「只要它还在起作用,就一定看得见」要防的最坏状态。
    ///   - 反方向:`looksJapaneseSong` 按**行占比**判,而这里按"有没有假名"判 —— 一首只有
    ///     3/75 行带假名的中文歌,前者说不是日文歌、后者说是,按前者显示菜单就成了"菜单在、
    ///     点了没反应"。
    /// 共用同一个判据之后,这两类不一致都不可能出现:**菜单显示 ⟺ 转换真的会发生**。
    public static func affects(_ text: String) -> Bool {
        !text.isEmpty && Romanizer.containsHan(text) && !Romanizer.looksJapanese(text)
    }

    public func converted(_ text: String) -> String {
        guard self != .off, Self.affects(text) else { return text }
        let transform: StringTransform =
            self == .traditional
            ? StringTransform("Simplified-Traditional")
            : StringTransform("Traditional-Simplified")
        let icu = text.applyingTransform(transform, reverse: false) ?? text
        return self == .simplified ? HanVariants.normalizeToSimplified(icu) : icu
    }
}


// 罗马音兜底——LyricsSyncEngine 现有的罗马音字段完全依赖网易云服务端"恰好给这首歌算好了
// lyrics_roma"(见 enrich.go/collector 那边),源没给就是空,中文歌曲的拼音、日文歌曲的
// 罗马字完全没有客户端兜底。2026-08-04 补上:用系统自带的音译在服务端没给这个字段时现算
// 一份兜底——真正的专业标注仍然优先用服务端字段(见调用点)。
public enum Romanizer {
    /// 现算一份罗马音。`japanese` 由调用方按**整首歌**判定后传进来(见 looksJapanese)。
    ///
    /// ⚠️ 日文**必须**走形态分析,不能用 ICU 的 Any-Latin。汉字是中日共用的文字系统,而
    /// Any-Latin 对汉字一律按普通话读——2026-08-09 用户报的正是这个:
    ///
    ///     火曜日の朝は   → Any-Latin: "huǒ yào rìno cháoha"   ← 拼音,完全不对
    ///                    → 形态分析: "kayou hi no asa ha"
    ///     受話器を取った君 → Any-Latin: "shòu huà qìwo qǔtta jūn"
    ///                    → 形态分析: "juwa ki wo totta kimi"
    ///
    /// 2026-08-04 那次只解决了"别给纯中文歌加拼音"(靠 songLooksJapanese 整首拦掉),
    /// 但日文行里夹着的汉字照样走 Any-Latin,于是假名出罗马字、汉字出拼音,混在一行里。
    ///
    /// 非日文(韩文谚文/泰文/西里尔字母等)跟汉字毫无交集,Any-Latin 对它们本来就是正确、
    /// 无歧义的罗马化,继续用。
    public static func romanize(
        _ text: String, japanese: Bool = false,
        marks: [KanaAnnotation.Mark] = []
    ) -> String? {
        guard !text.isEmpty else { return nil }
        // 日文歌里夹的纯英文行不要送进分词器:它会按词边界重新加空格,产出一份跟原文只差
        // 空格的"罗马音",纯属噪声。只有真的含假名/汉字的行才需要读音。
        if japanese, looksJapanese(text) || containsHan(text),
            let reading = japaneseReading(text, marks: marks), reading != text
        {
            return reading
        }
        // 输出等于输入(原文本来就是拉丁字母,音译是无操作)时返回 nil——不展示一份跟原文
        // 一模一样的"罗马音",那对用户没有任何信息增量,徒增一行重复文字。
        guard let transformed = text.applyingTransform(.toLatin, reverse: false),
            transformed != text
        else { return nil }
        return transformed
    }

    // 系统自带的日语形态分析:按词切开,每个词问它的拉丁转写。这是 Apple 平台上拿日文读音
    // 的标准做法,kanji 的读音由词典决定,而不是逐字音译。
    private static let japaneseLocale = CFLocaleCreate(
        nil, CFLocaleIdentifier("ja_JP" as CFString))

    /// 助词读音修正。は/へ/を 作助词时读 wa/e/o,而分词器给的是**字面**读音 ha/he/wo ——
    /// Apple Music 标的是前者,这也是日语实际的念法。
    ///
    /// 判据是「这个 token 恰好就是这一个假名」。2026-08-10 实测 CFStringTokenizer 对日文
    /// 的切分:助词总是被单独切成一个 token(「今/は/まだ/悲しい」「本/を/読む」
    /// 「海/へ/行く」),而词内部的同一个假名不会单独成词(「あなた」是一整个 token,不会
    /// 切出中间的「な」)。所以只改单独成词的那些,词里的假名一概不碰。
    ///
    /// 另外单列几个固定语:它们被当成**一个**词切出来(「こんにちは」→ 一个 token,读音
    /// kon'nichiha),规则套不上,但词尾那个は历史上同样是助词、实际就念 wa。这个表只收
    /// "整词固定、且词尾は必读wa"的少数几个,不做通用推测。
    ///
    /// 返回 nil 表示"这个片段不需要修正",照用分词器给的读音。
    static func particleLatin(for piece: String) -> String? {
        switch piece {
        case "は": return "wa"
        case "へ": return "e"
        case "を": return "o"
        case "こんにちは": return "konnichiwa"
        case "こんばんは": return "konbanwa"
        default: return nil
        }
    }

    /// 一段日文按分词器切出来的片段:每片带它在原文里的 UTF-16 范围和拉丁读音。
    ///
    /// `japaneseReading` 把这些片段拼成一整行就丢掉了位置信息;要做 Apple Music 那种
    /// "罗马音跟着具体内容走"(每个词下面单独标注)就必须留着范围,才能把读音对回原文的
    /// 哪几个字。**整行一次性分词**而不是逐词分,是因为日文读音吃上下文:同样是「明日」,
    /// 单独喂给分词器和放在句子里给出的读音可能不同。
    public struct JapaneseSegment: Equatable {
        public let utf16Start: Int
        public let utf16Length: Int
        public let latin: String
        public var utf16End: Int { utf16Start + utf16Length }
    }

    /// 用歌词源自带的假名标注拼出这个 token 的读音;这个 token 上没有标注时返回 nil,
    /// 交回给分词器。
    ///
    /// 拼法是"标注段用标注的假名、空档处保留原字":「明日の」里 明日 换成 あした、の 原样
    /// 留着 → あしたの,再整体音译成罗马字。纯假名走 ICU 的 toLatin 是确定的、无歧义的
    /// (汉字才有拼音那个坑,见 romanize 的注释),所以这一步安全。
    /// `unitsHint`:调用方已物化好的整行 UTF-16 数组。japaneseSegments 对一行的每个 token
    /// 都要调进来,原来每个 token 各自 `Array(text.utf16)` 重新物化整行(2026-08-20 性能
    /// 审计,只在带假名标注的酷狗日文歌上生效)。不传时自己物化,行为不变。
    static func annotatedReading(
        in text: String, utf16Start: Int, utf16Length: Int, marks: [KanaAnnotation.Mark],
        unitsHint: [UTF16.CodeUnit]? = nil
    ) -> String? {
        let end = utf16Start + utf16Length
        let hits = marks.filter { $0.utf16Start < end && $0.utf16End > utf16Start }
            .sorted { $0.utf16Start < $1.utf16Start }
        guard !hits.isEmpty else { return nil }
        let units = unitsHint ?? Array(text.utf16)
        guard end <= units.count else { return nil }
        var kana = ""
        var cursor = utf16Start
        for m in hits {
            // 标注可能超出 token 边界(整词标注跨过分词边界),超出就别用 —— 宁可退回
            // 分词器,也不要把邻词的读音塞进来。
            guard m.utf16Start >= utf16Start, m.utf16End <= end else { return nil }
            if m.utf16Start > cursor {
                kana += String(utf16CodeUnits: Array(units[cursor..<m.utf16Start]),
                               count: m.utf16Start - cursor)
            }
            kana += m.reading
            cursor = m.utf16End
        }
        if cursor < end {
            kana += String(utf16CodeUnits: Array(units[cursor..<end]), count: end - cursor)
        }
        guard !kana.isEmpty,
            let latin = kana.applyingTransform(.toLatin, reverse: false),
            latin != kana
        else { return nil }
        return latin.trimmingCharacters(in: .whitespaces)
    }

    /// 把若干个片段的读音拼成一段罗马音。跟 `japaneseReading` 用同一套促音归并规则,
    /// 分组渲染时才不会跟整行渲染出现不一致的写法。
    public static func joinLatin(_ pieces: [String]) -> String {
        mergeSokuon(pieces).joined(separator: " ")
    }

    /// 从一份已分好词的片段直接派生整行读音 —— 语义等价于 `japaneseReading(text)`
    /// (两条管线的片段级优先级一致:particleLatin > 假名标注 > 分词器转写 > 原文,
    /// 尾部同走 mergeSokuon+join),给 LyricsSyncEngine 复用 segmentsCache 用:同一行
    /// 的整行读音和逐词分组共用**同一次** CFStringTokenizer,不再各分一遍(2026-08-20
    /// 性能审计)。返回 nil 的口径也对齐 romanize:片段为空(=分不出词)或读音跟原文
    /// 一模一样(没有信息增量)都算"没有读音",调用方照 romanize 的原语义退 ICU 音译。
    /// **整行罗马音的判定阶梯** —— 播放引擎的客户端兜底和 `lyrics-romanize` helper
    /// (collector 预生成那条路)**共用这一份**。
    ///
    /// 2026-09-03 从 `LyricsSyncEngine.romanizationText` 里提出来。提的理由不是"整理代码":
    /// 预生成写进 `lyrics_roma` 之后,那份产物必须跟播放时现算的结果**逐字一致** ——
    /// 否则同一首歌"这次装了缓存"和"上次现算"读音不一样,而且这种不一致**不会报错**,
    /// 只会表现成用户偶尔觉得"某句罗马音怎么变了"。照抄一份阶梯就是给这件事开第二个漂移点。
    ///
    /// ⚠️ 两个条件是**或**的关系,不是"整首歌像日文"再判行(2026-08-24 定):
    ///   · 行内有假名 → 这一行确证是日文,不管整首歌是什么(中文歌里引用的日文行);
    ///   · 纯汉字行 → 中日读音歧义,只有这种行才看整首歌的标记。
    /// 写成 `songLooksJapanese && (looksJapanese || containsHan)` 的话,中文歌一旦被整首
    /// 判成日文,它的**纯中文行**就靠 containsHan 一路走进日语形态分析。
    ///
    /// - Parameter segments: 用 `@autoclosure` 收 —— 只有走进日语分支时才需要分词
    ///   (CFStringTokenizer 不便宜),而调用方常常持有按行缓存的分词结果。求值必须是惰性的,
    ///   否则纯英文歌的每一行都要白分一次词。
    public static func lineReading(
        _ line: String,
        songLooksJapanese: Bool,
        segments: @autoclosure () -> [JapaneseSegment]
    ) -> String? {
        if looksJapanese(line) || (songLooksJapanese && containsHan(line)),
            let reading = readingFromSegments(segments(), original: line)
        {
            return reading
        }
        return romanize(line, japanese: false)
    }

    public static func readingFromSegments(
        _ segs: [JapaneseSegment], original text: String
    ) -> String? {
        guard !segs.isEmpty else { return nil }
        let joined = joinLatin(segs.map(\.latin))
        // 刻意允许返回空串(整行只有促音「っ」这类病态行,归并后读音为空):旧路径
        // romanize(japanese:true) 对它返回 "" 而不落 ICU —— 落 ICU 会产出字面垃圾
        // "~tsu" 被展示出来。只有"读音跟原文一模一样"才算没有信息增量、交还 ICU 路径。
        guard joined != text else { return nil }
        return joined
    }

    /// 韩语按空格切词的"片段"——跟 japaneseSegments 形状一致(UTF16 范围 + 读音),但来源
    /// 不是分词器,是文本自带的词间空格:韩语原文本来就按空格分词,罗马字转写(服务端给的
    /// 或 ICU 现算的)会保留同样的词间空格,不需要跟日语一样现分词。实测坐实:
    /// "나는 너를 사랑해"(3 词)→ ICU 给的 "naneun neoleul salanghae" 恰好也是 3 个空格
    /// 分隔的词、顺序不变;而单字块内部(比如"안녕"→"annyeong")ICU 不插空格,所以这里
    /// 是按**词**跟逐字词做归并,不是按谚文字符——一个词常常横跨好几个逐字词(酷狗式的
    /// 逐字切分一个谚文字一个词很常见),归并算法复用 mergeSegmentsIntoWordGroups 那套。
    ///
    /// 词数(空格分隔的段数)对不上时返回 nil——多半是罗马字来源对这一行的标点/空格做了
    /// 什么改写,宁可放弃对齐、退回整行罗马音,也不要猜错位置(跟 hanRomanization 那条
    /// 分支同一个安全网思路)。
    public static func koreanSegments(_ text: String, romanization: String) -> [JapaneseSegment]? {
        let romTokens = romanization.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !romTokens.isEmpty else { return nil }
        var segs: [JapaneseSegment] = []
        var utf16Offset = 0
        var tokenIdx = 0
        var wordStart: Int?
        for ch in text {
            let chLen = String(ch).utf16.count
            if ch.isWhitespace {
                if let start = wordStart {
                    guard tokenIdx < romTokens.count else { return nil }
                    segs.append(JapaneseSegment(
                        utf16Start: start, utf16Length: utf16Offset - start, latin: romTokens[tokenIdx]))
                    tokenIdx += 1
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = utf16Offset
            }
            utf16Offset += chLen
        }
        if let start = wordStart {
            guard tokenIdx < romTokens.count else { return nil }
            segs.append(JapaneseSegment(
                utf16Start: start, utf16Length: utf16Offset - start, latin: romTokens[tokenIdx]))
            tokenIdx += 1
        }
        guard tokenIdx == romTokens.count else { return nil }
        return segs
    }

    public static func japaneseSegments(
        _ text: String, marks: [KanaAnnotation.Mark] = []
    ) -> [JapaneseSegment] {
        let cf = text as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        let tokenizer = CFStringTokenizerCreate(
            nil, cf, range, kCFStringTokenizerUnitWordBoundary, japaneseLocale)
        // 整行 UTF-16 只物化一次,供 annotatedReading 的每个 token 共用(没有标注时它
        // 用不到,不白建)。
        let units: [UTF16.CodeUnit]? = marks.isEmpty ? nil : Array(text.utf16)
        var out: [JapaneseSegment] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let piece = CFStringCreateWithSubstring(nil, cf, r) as String? ?? ""
            var latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String ?? ""
            // 歌词源自带的假名标注优先于分词器 —— 多音词该念哪个,标注说了算。
            if let annotated = annotatedReading(
                in: text, utf16Start: r.location, utf16Length: r.length, marks: marks,
                unitsHint: units)
            {
                latin = annotated
            }
            if let fixed = particleLatin(for: piece) { latin = fixed }
            if latin.isEmpty {
                // 拿不到读音的(标点/拉丁词本身)原样留着 —— 但纯空白不值得占一个片段。
                guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                latin = piece
            }
            // ICU 对促音「っ」会吐出字面的 "~tsu",单片段里也要按双写辅音归并
            // (mergeSokuon 是按片段序列做的,这里先各自留着,拼接时再交给它)。
            out.append(JapaneseSegment(
                utf16Start: r.location, utf16Length: r.length, latin: latin))
        }
        return out
    }

    private static func japaneseReading(
        _ text: String, marks: [KanaAnnotation.Mark] = []
    ) -> String? {
        let cf = text as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        let tokenizer = CFStringTokenizerCreate(
            nil, cf, range, kCFStringTokenizerUnitWordBoundary, japaneseLocale)
        var tokens: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let piece = CFStringCreateWithSubstring(nil, cf, tokenRange) as String? ?? ""
            if let fixed = particleLatin(for: piece) {
                tokens.append(fixed)
            } else if let annotated = annotatedReading(
                in: text, utf16Start: tokenRange.location, utf16Length: tokenRange.length,
                marks: marks)
            {
                tokens.append(annotated)
            } else if let reading = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                !reading.isEmpty
            {
                tokens.append(reading)
            } else if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                // 标点/符号之类拿不到读音的,原样保留,别把它们吞掉。
                tokens.append(piece)
            }
        }
        guard !tokens.isEmpty else { return nil }
        return mergeSokuon(tokens).joined(separator: " ")
    }

    /// 促音「っ」被单独切成一个词时,ICU 转写成字面的 "~tsu" —— 直接显示出来是乱码。
    /// 赫本式的写法是把后一个辅音双写:取った → "to~tsu" + "ta" → "totta"。
    private static func mergeSokuon(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasSuffix("~tsu"), index + 1 < tokens.count,
                let consonant = tokens[index + 1].first, consonant.isASCII, consonant.isLetter
            {
                out.append(token.dropLast(4) + String(consonant) + tokens[index + 1])
                index += 2
            } else if token.hasSuffix("~tsu") {
                // 后面没词可双写(整行以促音结尾),丢掉这个记号,不要露给用户。
                let head = String(token.dropLast(4))
                if !head.isEmpty { out.append(head) }
                index += 1
            } else {
                out.append(token)
                index += 1
            }
        }
        return out
    }

    // 2026-08-04 实测排查坐实的真实 bug:汉字本身是中文/日文共用的文字系统,
    // .toLatin 对纯中文歌词(比如"你对我笑一次")一样能音译出一份"看起来正常"的拼音,
    // 上面的 romanize() 单靠"输出是否等于输入"判断不出这首歌到底是不是真的需要罗马音——
    // 结果中文歌曲(NetEase 本来就不给它算 lyrics_roma,这本身就是"不需要罗马音"的正确
    // 信号)也被这套兜底逻辑摆上了一行拼音,现实世界的歌词 App(网易云/QQ音乐/Apple
    // Music/LyricFever)都不会这么做。
    //
    // 修法:平假名/片假名是日文独有、中文完全没有的两套文字系统,一首歌只要出现过一个
    // 假名字符就能确证"这是日文",借这个信号反过来判定该不该对含汉字的行启用兜底——
    // 调用方(LyricsSyncEngine)按"整首歌"粒度调一次、缓存结果,不是逐行判断,理由见
    // 调用点注释(极少数纯汉字的日文行不该因为局部特征被误判成中文)。
    private static let kanaPattern = try! NSRegularExpression(
        pattern: #"\p{Hiragana}|\p{Katakana}"#)

    public static func looksJapanese(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return kanaPattern.firstMatch(in: text, range: range) != nil
    }

    // 含汉字的行是"中文拼音 vs 日文罗马字"这个混淆的唯一来源——韩文谚文/泰文/西里尔
    // 字母等其它非拉丁文字系统跟汉字毫无交集,不需要这层额外判断,ICU 音译对它们
    // 本来就是正确、无歧义的罗马化展示。
    private static let hanPattern = try! NSRegularExpression(pattern: #"\p{Han}"#)

    public static func containsHan(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return hanPattern.firstMatch(in: text, range: range) != nil
    }
}

/// 一份歌词整体属于哪种文字。**按整首歌判一次**,不逐行判 —— 理由见 Romanizer 里
/// looksJapanese 的注释:极少数纯汉字的日文行不该被局部特征误判成中文。
public enum LyricScript: String, Sendable, CaseIterable {
    case japanese, korean, chinese
    /// 粤语歌的汉字行。文字本身(汉字)跟 .chinese 没有任何差异,分不出普通话还是
    /// 粤语——这一档只能靠外部信号(collector 判定的 SongLanguage 真值,见
    /// EnrichCacheLyrics.isCantonese)分派,不能像日语假名/韩语谚文那样靠文字本身
    /// 判定。2026-08-29 加,拼音/粤拼两个开关分开之后才需要区分。
    case cantonese
    /// 拉丁字母、泰文、西里尔字母等等。这些跟汉字没有交集,音译无歧义,历来是无条件
    /// 允许的,不纳入按语言开关的管辖 —— 用户提的是"汉语/韩语/日语"三选。
    case other

    var option: RomanizationScripts? {
        switch self {
        case .japanese: return .japanese
        case .korean: return .korean
        case .chinese: return .chinese
        case .cantonese: return .cantonese
        case .other: return nil
        }
    }
}

/// 哪几种文字需要标罗马音。用户可以按语言分别开关。
///
/// 为什么要分语言:同一个人对不同语言的需求是相反的 —— 听日文歌想要罗马字才跟得上,
/// 听中文歌却完全不需要拼音(对中文读者是纯噪声,2026-08-04 就是因为这个才把中文歌的
/// 客户端兜底整个关掉的)。原来只有一个总开关,表达不了这件事。
public struct RomanizationScripts: OptionSet, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let japanese = RomanizationScripts(rawValue: 1 << 0)
    public static let korean = RomanizationScripts(rawValue: 1 << 1)
    /// 中文(普通话拼音)。设置页文案是"拼音",跟"粤拼"对举——枚举名保留 chinese 不改,
    /// 只是没必要为了改名字连带迁移已经落盘的用户设置(OptionSet 按 rawValue 持久化,
    /// 位不变就不用管旧设置怎么迁移)。
    public static let chinese = RomanizationScripts(rawValue: 1 << 2)
    /// 粤语(粤拼/Jyutping)。2026-08-29 加——此前粤拼罗马音只在服务端无条件生成,
    /// 客户端完全没有开关能控制显不显示。
    public static let cantonese = RomanizationScripts(rawValue: 1 << 3)

    /// 2026-08-29 改:四项默认全开——"显示罗马音"总开关一旦打开,不该还要用户再去
    /// 逐项勾选才看得到东西。此前中文(拼音)单独默认关是因为普通话读者本来就认字、
    /// 拼音是纯噪声;但那次决定早于粤拼的出现,不该被直接套用到全部四项上(用户
    /// 2026-08-29 拍板:统一默认开)。
    public static let `default`: RomanizationScripts = [.japanese, .korean, .chinese, .cantonese]
}

extension Romanizer {
    // 谚文。跟汉字没有交集,单独一个信号就能确证。
    private static let hangulPattern = try! NSRegularExpression(
        pattern: #"\p{Hangul}"#)

    public static func containsHangul(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return hangulPattern.firstMatch(in: text, range: range) != nil
    }

    /// 判定一份歌词整体是哪种文字。
    ///
    /// 顺序有讲究,不能重排:
    /// - 假名是日文独有的,一出现就确证日文 —— 必须排在汉字之前,否则日文歌里的汉字会
    ///   把它判成中文(这正是 2026-08-04 那个 bug 的形状)。
    /// - 谚文同样是韩文独有的。韩文歌词里夹汉字很少见但存在(人名/成语),所以也排在
    ///   汉字之前。
    /// - 剩下含汉字的才是中文。
    public static func script(of text: String) -> LyricScript {
        if looksJapanese(text) { return .japanese }
        if containsHangul(text) { return .korean }
        if containsHan(text) { return .chinese }
        return .other
    }

    // MARK: - 整首歌 vs 一行:两个不同粒度的判断(2026-08-24 重做)
    //
    // 2026-08-24 用户报「怎么中文也注音了」:《这样吧》(群星/动力火车翻唱)是一首中文歌,
    // 但它引用了三次「サヨナラ」。原来的判据是**「整首歌出现过一个假名字符就算日文」**,
    // 于是整首歌被判成日文,每一行汉字都去走日语形态分析 ——「就从明天开始吧」的罗马音
    // 出成了「就从 mei ten 开始 吧」(mei ten 是「明天」的日文音读)。
    //
    // 那个判据的原始理由是对的:假名是日文独有、中文完全没有,所以**一行里有假名**足以
    // 确证这一行是日文。错的是把它从「一行」放大到「整首歌」——引用外语词太常见了。
    //
    // 现在分成两层:
    //   · 一行里有假名/谚文 → 按这一行自己的文字算(确证,不看整首歌);
    //   · **纯汉字**的行才有中日歧义(同一个汉字两种读音),这种行退回整首歌的判断;
    //   · 整首歌的判断改成**含假名的行占比**,而不是「出现过没有」。
    //
    // 实测用户曲库 647 首有歌词的歌里只有 3 首出现过假名,含假名行占比分别是:
    //   Michael Jackson《Keep the Faith》 1/156  =  0.6%(夹了一行日文)
    //   群星《这样吧》                     3/75   =  4.0%(就是这次报的)
    //   陶喆《My Anata》                  18/44  = 40.9%(真·中日混唱)
    // ⚠️ 这批数据里**没有一首纯日文歌**,所以阈值的正向一侧不是从数据拟合的,是从正字法
    // 推的:日语正字法离不开假名(助词 は/が/を/の、动词词尾、送り仮名),真正的日文歌
    // 几乎每一行都含假名、占比接近 100%。取 50% 两边都留着很宽的余量。

    /// 「整首歌是日文歌」的阈值:含假名的**行**占非空行的比例。
    public static let japaneseSongKanaLineRatio = 0.5

    /// 含假名的行占非空行的比例。没有非空行时返回 0。
    public static func kanaLineRatio(_ text: String) -> Double {
        var total = 0
        var kana = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            total += 1
            if looksJapanese(line) { kana += 1 }
        }
        guard total > 0 else { return 0 }
        return Double(kana) / Double(total)
    }

    /// 整首歌是不是日文歌。**只**用来给纯汉字行的读音做兜底判断,行内有假名的一律按行算。
    public static func looksJapaneseSong(_ text: String) -> Bool {
        kanaLineRatio(text) >= japaneseSongKanaLineRatio
    }

    /// 整首歌的文字种类。跟 script(of:) 的唯一区别是日文那一档按**行占比**判。
    public static func songScript(of text: String) -> LyricScript {
        if looksJapaneseSong(text) { return .japanese }
        if containsHangul(text) { return .korean }
        if containsHan(text) { return .chinese }
        return .other
    }

    /// **一行**的文字种类。行内有假名/谚文就按行自己算(确证);只有纯汉字行才有
    /// 中文/日文/粤语的歧义,那种行退回整首歌的判断——粤语和普通话的汉字长得
    /// 一模一样,光看这一行的文字本身分不出来,只能信 song 这个整首歌级别的判定
    /// (它来自 collector 的 SongLanguage 真值,不是文字分析,见 isCantonese 的注释)。
    public static func script(ofLine line: String, song: LyricScript) -> LyricScript {
        if looksJapanese(line) { return .japanese }
        if containsHangul(line) { return .korean }
        if containsHan(line) {
            if song == .japanese { return .japanese }
            if song == .cantonese { return .cantonese }
            return .chinese
        }
        return .other
    }
}
