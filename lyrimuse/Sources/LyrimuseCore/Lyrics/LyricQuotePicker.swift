import Foundation

/// 从整份歌词里挑「摆得出来的一句话」——停播页 hero 下面那条静默字幕带用。
///
/// ⚠️ **不能直接拿单行 LRC 当一句话**(2026-08-24 用户实测反馈:「经常只显示半句,没有什么含义」)。
/// 根因:LRC 的行是**打轴单位、不是句子单位** —— 一句完整的话经常被拆到两三行上
/// (`我们` / `都有难忘的回忆`),单独摆出任何一半都不成话。本机全库实测:31,492 行里
/// 8.7% 是 ≤5 字的短行、2.0% 以悬挂词结尾,这些单摆出来都是半句。
///
/// 所以这里不是「过滤单行」而是「先把碎片并回乐句,再挑」。整条链:
/// 1. 归一化空白、按时间排序 —— **必须排序**:一行带多个时间戳(副歌复用)时 `LRCParser`
///    会按**文件顺序**各生成一条,数组并不按时间有序,不排序行间时间差会算出负数,断句全乱;
/// 2. `LyricDuet.plan` 剥掉对唱标记(`男：`)并丢掉只有标记的行;
/// 3. `LyricsSyncEngine.creditLineDropDecisions` 挡署名/职员表(演唱者当豁免喂进去,
///    否则「每句都带标记」的对唱歌会被整首删空);
/// 4. 本文件自己的噪音闸:段落标记(`Rap2：`)、字符复读(`面面面面面`)、括号伴唱、
///    标点占多数的行、以及「歌名 - 歌手」这类被当正文存进来的抬头行;
/// 5. 丢掉**回声行**:后一行是前一行的子串/后缀(和声重复,实测会产出
///    `我记得你爱喝的饮料 / 的饮料` 这种);
/// 6. 并句:**只在这一行本身看起来没说完时**才去并下一行,阈值用**这首歌自己的行间隔
///    中位数**而不是写死的毫秒数 —— 本机实测中位数 2810ms、p25 1930ms,写死 3000ms 会把
///    一半的正常相邻行也并起来,那样整页永远是两三行的大段,原设计「一句短句」的克制就没了;
/// 7. 收尾再验一遍:还是以悬挂词结尾、或以附着成分(`的 / 了 / 着 / 吗`)开头的,整条弃用
///    ——候选池很大(本机 551 首筛出约 12,000 条),宁可少挑几条也不摆半句话。
public enum LyricQuotePicker {
    public struct Line: Sendable {
        public let timeMs: Int
        public let text: String
        public init(timeMs: Int, text: String) {
            self.timeMs = timeMs
            self.text = text
        }
    }

    /// - Parameters:
    ///   - charRange: 一条候选**合起来**的字数区间。下限挡「Oh」这类没有意义的短句,
    ///     上限挡摆出来会折成三四行、把版面撑坏的长句。
    ///   - maxLines: 一条候选最多并几行(保留原始换行,渲染时直接多行显示)。
    /// - Returns: 每条候选是 1...maxLines 行原文;拿不到任何合规候选时返回空数组,
    ///   调用方按「整块缺席」处理(宁可没有,也不摆半句)。
    public static func phrases(
        _ lines: [Line], trackTitle: String = "", trackArtist: String = "",
        charRange: ClosedRange<Int> = 8 ... 32, maxLines: Int = 3
    ) -> [[String]] {
        // ① 归一化 + 排序
        var ordered = lines
            .map { Line(timeMs: $0.timeMs, text: collapseWhitespace($0.text)) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.timeMs < $1.timeMs }
        guard !ordered.isEmpty else { return [] }

        // ② 对唱标记:剥掉行首标记,丢掉只有标记的行
        let duet = LyricDuet.plan(lineTexts: ordered.map(\.text))
        if duet.texts.count == ordered.count, duet.dropped.count == ordered.count {
            var kept: [Line] = []
            for (i, line) in ordered.enumerated() where !duet.dropped[i] {
                let stripped = collapseWhitespace(duet.texts[i])
                if !stripped.isEmpty { kept.append(Line(timeMs: line.timeMs, text: stripped)) }
            }
            ordered = kept
        }
        guard !ordered.isEmpty else { return [] }

        // ③ 署名/职员表(引擎那份 public 的整份闸门,不在这里另抄一套正则)
        let texts = ordered.map(\.text)
        let drop = LyricsSyncEngine.creditLineDropDecisions(
            texts, trackTitle: trackTitle, trackArtist: trackArtist,
            speakerExemptions: LyricDuet.speakers(in: texts))
        if drop.count == ordered.count {
            ordered = zip(ordered, drop).compactMap { $0.1 ? nil : $0.0 }
        }

        // ④ 自己的噪音闸
        ordered = ordered.filter { !isNoise($0.text, trackTitle: trackTitle, trackArtist: trackArtist) }

        // ⑤ 回声行
        var deduped: [Line] = []
        for line in ordered {
            if let prev = deduped.last?.text, line.text.count <= prev.count,
               prev.contains(line.text) {
                continue
            }
            deduped.append(line)
        }
        ordered = deduped
        guard ordered.count >= 1 else { return [] }

        // ⑥ 并句
        let threshold = mergeThresholdMs(ordered)
        var segments: [[String]] = []
        var current: [String] = []
        var currentChars = 0
        for (i, line) in ordered.enumerated() {
            current.append(line.text)
            currentChars += line.text.count
            let next: Line? = i + 1 < ordered.count ? ordered[i + 1] : nil
            guard let next else { break }
            let gap = next.timeMs - line.timeMs
            let wantsMore = needsContinuation(line.text, next: next.text)
            let canTake = gap <= threshold
                && current.count < maxLines
                && currentChars + next.text.count <= charRange.upperBound
            if !(wantsMore && canTake) {
                segments.append(current)
                current = []
                currentChars = 0
            }
        }
        if !current.isEmpty { segments.append(current) }

        // ⑦ 收尾复验 + 去重
        var seen = Set<String>()
        return segments.filter { seg in
            let joined = seg.joined()
            guard charRange.contains(joined.count),
                  let first = seg.first, let last = seg.last,
                  !danglesAtEnd(last), !opensWithEnclitic(first),
                  hasEnoughWords(seg, joined: joined),
                  seen.insert(joined).inserted
            else { return false }
            return true
        }
    }

    // MARK: - 判据

    /// 并句阈值:这首歌自己的行间隔中位数,兜底 1800ms。
    ///
    /// 为什么用中位数而不是写死的毫秒:慢歌一行 4 秒、快歌一行 1 秒,同一个绝对阈值对两者
    /// 一个太松一个太紧。>15s 的间隔(间奏/前后奏)不参与中位数,否则会被拉高。
    static func mergeThresholdMs(_ lines: [Line]) -> Int {
        var gaps: [Int] = []
        for i in 0 ..< max(0, lines.count - 1) {
            let g = lines[i + 1].timeMs - lines[i].timeMs
            if g > 0, g < 15_000 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return 2500 }
        gaps.sort()
        return max(1800, gaps[gaps.count / 2])
    }

    /// 这一行看起来「没说完」吗 —— 只有它为真才会去并下一行。
    static func needsContinuation(_ text: String, next: String) -> Bool {
        guard let last = text.last else { return false }
        // 已经有终止标点:相信标点,不再并
        if terminalPunctuation.contains(last) { return false }
        if text.count <= 5 { return true }
        if danglesAtEnd(text) { return true }
        // 下一行以附着成分开头 → 它是这一行的尾巴
        if let head = next.first, encliticHeads.contains(head) { return true }
        return false
    }

    private static let terminalPunctuation: Set<Character> = [
        "。", "！", "？", "!", "?", "…", "；", ";",
    ]

    /// 句尾悬挂:以这些字结尾说明后面还有话。
    /// 刻意**不含** `了 / 着 / 过 / 吗 / 呢 / 吧` —— 那些是句末语气/体标记,结尾很正常。
    private static let danglingTailChars: Set<Character> = [
        "的", "地", "和", "跟", "与", "及", "而", "但", "却", "把", "被", "让", "使",
        "向", "往", "从", "对", "给", "比", "像", "为", "在", "是", "有", "没", "无",
        "要", "想", "会", "能", "可", "就", "才", "也", "还", "更", "又", "很", "太",
        "最", "这", "那", "哪", "如", "若", "因", "所", "将", "由", "于", "被",
    ]

    /// 英文句尾悬挂词。刻意**不含** can / will / do / go —— 它们结句很正常
    /// (「Yes I can」「Let it go」),放进来会杀掉正常歌词。
    private static let danglingTailWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for",
        "with", "my", "your", "our", "his", "her", "its", "their", "is", "are",
        "was", "were", "be", "been", "so", "that", "this", "then", "than", "as",
        "does", "did", "would", "could", "should", "must", "gonna", "wanna", "gotta",
    ]

    /// 拉丁文本的字数下限要单独把关:8 个字符对中文是三四个词,对英文只有两个单词
    /// (实测抽样命中过「Come true」),摆出来同样没有意义。判据是「拉丁字母占多数」时
    /// 至少要有 3 个词 —— 用词数而不是再抬字符下限,免得把 CJK 的短句一起收紧。
    static func hasEnoughWords(_ seg: [String], joined: String) -> Bool {
        let latin = joined.filter { $0.isASCII && $0.isLetter }.count
        guard latin * 2 > joined.count else { return true }
        let words = seg.joined(separator: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "\'" })
        return words.count >= 3
    }

    static func danglesAtEnd(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return true }
        if danglingTailChars.contains(last) { return true }
        // 英文按最后一个词判(中文没有词边界,上面按字判)
        if let raw = t.split(separator: " ").last {
            let word = raw.lowercased().filter { $0.isLetter || $0.isNumber }
            if !word.isEmpty, danglingTailWords.contains(word) { return true }
        }
        return false
    }

    /// 一句话不会从 `的 / 了 / 着 / 吗` 起头,出现就说明这是被切下来的尾巴。
    /// 刻意**不含** `但 / 却 / 就 / 也 / 还 / 更 / 又 / 而` —— 它们起头很正常(「但我还是想你」)。
    private static let encliticHeads: Set<Character> = [
        "的", "了", "着", "过", "吗", "呢", "吧", "啊", "呀", "嘛", "呐", "地", "得",
    ]

    static func opensWithEnclitic(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespaces).first else { return true }
        return encliticHeads.contains(first)
    }

    /// 段落标记 / 复读 / 括号伴唱 / 标点占多数 / 被当正文存进来的抬头行。
    static func isNoise(_ text: String, trackTitle: String, trackArtist: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if sectionMarker.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return true }
        // 同一个字连着出现 ≥4 次:`面面面面面`、`嘿嘿嘿嘿`
        var run = 0
        var previous: Character?
        for c in t {
            if c == previous { run += 1; if run >= 3 { return true } } else { run = 0 }
            previous = c
        }
        // 整行都在括号里 = 伴唱/和声
        if (t.hasPrefix("(") && t.hasSuffix(")")) || (t.hasPrefix("（") && t.hasSuffix("）")) {
            return true
        }
        // 字母/数字/汉字不到一半 = 标点或符号堆
        let wordish = t.filter { $0.isLetter || $0.isNumber }.count
        if wordish * 2 < t.count { return true }
        // 「歌名 - 歌手」这类抬头行被当正文存进来。判据刻意收得很窄:**整行归一化后正好等于**
        // 歌名/歌手/两者拼接才算 —— 不能用「包含歌名」,那会把《成都》里「如果你正好在成都」
        // 这种正常歌词一起杀掉。
        let key = squeeze(t)
        if !key.isEmpty {
            let title = squeeze(trackTitle), artist = squeeze(trackArtist)
            if !title.isEmpty, key == title { return true }
            if !artist.isEmpty, key == artist { return true }
            if !title.isEmpty, !artist.isEmpty, key == title + artist || key == artist + title {
                return true
            }
        }
        return false
    }

    private static let sectionMarker = try! NSRegularExpression(
        pattern: "^(rap|chorus|verse|bridge|intro|outro|hook|pre-?chorus|间奏|間奏|副歌|主歌|前奏|尾奏|独白|獨白)\\s*\\d*\\s*[:：]?$",
        options: [.caseInsensitive])

    /// 归一化:去掉所有非字母数字汉字的字符再小写 —— 给「整行是不是就等于歌名」这类比较用。
    private static func squeeze(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 连续空白压成一个空格(部分源的正文带成串空格,实测出现过 `I  thought  i  heard`)。
    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
