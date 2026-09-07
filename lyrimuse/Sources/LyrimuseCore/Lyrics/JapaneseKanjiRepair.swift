import Foundation

/// 修回被歌词源「简化」过的日文汉字(2026-09-06)。
///
/// 病根:中文源(实测全部来自酷狗)上的一部分日文歌词是用中文输入法录入/整理的,日文汉字被敲成了
/// 对应的**大陆简体字**——「飲まれちまう」成了「饮まれちまう」、「聞こえたら」成了「闻こえたら」、
/// 「優しさ」成了「优しさ」。日本根本没有这些字,日文分词器也不认它们(罗马音跟着一起错)。
/// 本机缓存实测(2026-09-06,69 首日文歌 / 3334 行含假名的正文):66 行受害、涉及 24 首,重灾区
/// 神山羊《journey》《青い棘》31 行;其余多是署名行「作词」「编曲」(引擎随后就过滤掉)和 `[ti:]`
/// 里源加的中文译名。
///
/// ═══ 不维护任何表,全部是通用规则(用户要求:「不允许维护人工表,必须是通用规则」)═══
///
/// 一个汉字该不该修、修成什么,只问两个系统自带的事实:
///
///   1. **它是不是日文里存在的字** —— 判据是"能不能用 JIS X 0208(Shift_JIS)编码"。JIS X 0208 是
///      日本的标准汉字集(6355 字):大陆简化专用字(饮/闻/优/热/这/们…)一个都不在里面;而日文新字体
///      和简体恰好同形的字(国/学/会/体/点/灯/双/旧/机…)**在**里面,天然不会被误伤。
///      ⚠️ 这一条不能换成「是不是简体字」:「国」既是简体也是日文新字体,按后者判就会把它改成「國」。
///   2. **不是的话,它的繁体是什么** —— ICU `Simplified-Traditional` 单字转换。转出来的字再过一次
///      规则 1,能编码才换(饮→飲、闻→聞、优→優),不能编码就原样留着(「步」ICU 不动 → 留;「你」不是
///      简体 → 留)。
///
/// 两道守卫把改动面钉死在"日文歌里的日文行":
///   - **整首**要按 `Romanizer.looksJapaneseSong` 判为日文歌(含假名的行占非空行 ≥ 50%)。中日混排的
///     中文歌(陶喆《My Anata》「只听见おじさん骑着单车卖着馒头」)整首不是日文,那句里的简体字是正文
///     本来就该有的,一个都不能动;
///   - **该行**要含假名(`Romanizer.looksJapanese`)。日文歌里源加的中文标题行/译名行没有假名,不碰——
///     那是中文,不该被"修"成繁体。
///
/// ⚠️ 已知边界(不引表就到此为止,刻意接受):
///   - 繁体与日文新字体不同的字落在**旧字体**上:颜→顏(现行写法 顔)、丝→絲(糸)。旧字体是 JIS X 0208
///     里真实存在、日本读者认得的字形,比留着一个日本根本不存在的简体字好得多;再往新字体走需要一张
///     旧→新对照表,而那正是用户不要的东西。本机实测 31 种被修的字里只有这 2 种落在旧字体上。
///   - 简体与繁体同形、日文却另有写法的字(步 / 歩)无从判断是不是被写坏的,原样留着(实测 6 处)。
///   - 含假名的行里夹着的中文括注(`[ti:クランベリーとパンケーキ (蔓越莓和煎饼)]`)会跟着变繁(饼→餅);
///     那是标签/抬头行,引擎不显示它们,接受。
///   - 只修显示、不动缓存原文,跟简繁转换同一条纪律;作用在正文与逐字数据上,译文是中文不修,罗马音是
///     拉丁字母不修;纯文本兜底(plainLyrics)跟简繁转换一样不经过这里。
public enum JapaneseKanjiRepair {
    /// 规则 1 用的字符集:JIS X 0208 + JIS X 0201,即 Shift_JIS。
    /// 刻意**不用** Shift_JIS-2004(JIS X 0213,多 3695 字,收了不少旧字体与生僻字,"是日文字"会判得太松)
    /// 也不用 EUC-JP(带 JIS X 0212 补助汉字 5801 字,同理)。
    private static let japaneseEncoding: String.Encoding = .shiftJIS

    private static let toTraditional = StringTransform("Simplified-Traditional")

    /// 单字结论缓存。同一个字的答案是确定的,而一首歌几千个字里不同的汉字只有几百个;换歌 / 改设置时
    /// `reloadCurrentLyrics` 会带着整份歌词反复进来,别每次都去问编码器和 ICU。
    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var memo: [Character: Character?] = [:]

    /// 这个字能不能用 JIS X 0208 编码 —— "它是日文里存在的字"的判据(规则 1)。
    static func isJapaneseKanji(_ ch: Character) -> Bool {
        String(ch).data(using: japaneseEncoding) != nil
    }

    /// 单字规则:该换成哪个字;nil = 不动。
    static func repaired(_ ch: Character) -> Character? {
        // 单一码位的表意文字才谈得上简繁;组合序列 / 假名 / 标点 / 数字直接放过。
        guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first,
              scalar.properties.isIdeographic else { return nil }
        memoLock.lock()
        defer { memoLock.unlock() }
        if let cached = memo[ch] { return cached }
        var result: Character? = nil
        if !isJapaneseKanji(ch),
           let trad = String(ch).applyingTransform(toTraditional, reverse: false),
           trad.count == 1, let candidate = trad.first,
           candidate != ch, isJapaneseKanji(candidate) {
            result = candidate
        }
        memo[ch] = result
        return result
    }

    /// 修一行。**只修含假名的行**(第二道守卫),整首是不是日文歌由 `repair(_:japaneseSong:)` 管。
    public static func repairLine(_ line: String) -> String {
        guard Romanizer.looksJapanese(line), Romanizer.containsHan(line),
              line.contains(where: { repaired($0) != nil }) else { return line }
        return String(line.map { repaired($0) ?? $0 })
    }

    /// 修整份歌词(LRC / YRC 整串都行:时间戳是数字,规则只碰汉字)。`japaneseSong` 由调用方按**整首**
    /// 判定传入(`Romanizer.looksJapaneseSong(正文)`),不是日文歌一个字都不动。
    ///
    /// 快路径:整份里没有任何一个字需要修(绝大多数日文歌)就返回原字符串本身。慢路径逐行走
    /// `repairLine`,换行符原样保留 —— 酷狗常见 CRLF,`split("\n")` 切不开(Swift 把 `\r\n` 当一个字素),
    /// 而 `components(separatedBy: .newlines)` 再拼回去会把 CRLF 抹成 LF,所以这里手动按字素扫。
    public static func repair(_ text: String, japaneseSong: Bool) -> String {
        guard japaneseSong, !text.isEmpty, Romanizer.containsHan(text),
              text.contains(where: { repaired($0) != nil }) else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var lineStart = text.startIndex
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch.isNewline {
                out += repairLine(String(text[lineStart..<idx]))
                out.append(ch)
                lineStart = text.index(after: idx)
            }
            idx = text.index(after: idx)
        }
        out += repairLine(String(text[lineStart..<text.endIndex]))
        return out
    }
}
