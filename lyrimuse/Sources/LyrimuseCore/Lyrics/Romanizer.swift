import Foundation

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
    public static func romanize(_ text: String, japanese: Bool = false) -> String? {
        guard !text.isEmpty else { return nil }
        // 日文歌里夹的纯英文行不要送进分词器:它会按词边界重新加空格,产出一份跟原文只差
        // 空格的"罗马音",纯属噪声。只有真的含假名/汉字的行才需要读音。
        if japanese, looksJapanese(text) || containsHan(text),
            let reading = japaneseReading(text), reading != text
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

    /// 把若干个片段的读音拼成一段罗马音。跟 `japaneseReading` 用同一套促音归并规则,
    /// 分组渲染时才不会跟整行渲染出现不一致的写法。
    public static func joinLatin(_ pieces: [String]) -> String {
        mergeSokuon(pieces).joined(separator: " ")
    }

    public static func japaneseSegments(_ text: String) -> [JapaneseSegment] {
        let cf = text as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        let tokenizer = CFStringTokenizerCreate(
            nil, cf, range, kCFStringTokenizerUnitWordBoundary, japaneseLocale)
        var out: [JapaneseSegment] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let piece = CFStringCreateWithSubstring(nil, cf, r) as String? ?? ""
            var latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String ?? ""
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

    private static func japaneseReading(_ text: String) -> String? {
        let cf = text as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        let tokenizer = CFStringTokenizerCreate(
            nil, cf, range, kCFStringTokenizerUnitWordBoundary, japaneseLocale)
        var tokens: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let piece = CFStringCreateWithSubstring(nil, cf, tokenRange) as String? ?? ""
            if let reading = CFStringTokenizerCopyCurrentTokenAttribute(
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
