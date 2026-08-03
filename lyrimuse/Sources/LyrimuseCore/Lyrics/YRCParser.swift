import Foundation

public struct LyricWord: Equatable {
    public let startMs: Int
    public let durationMs: Int
    public let text: String
    public init(startMs: Int, durationMs: Int, text: String) {
        self.startMs = startMs
        self.durationMs = durationMs
        self.text = text
    }
}

public struct LyricLineWords: Equatable {
    public let timeMs: Int
    public let words: [LyricWord]
    public init(timeMs: Int, words: [LyricWord]) {
        self.timeMs = timeMs
        self.words = words
    }
}

// 网易云逐字 yrc 解析,算法照抄 web/index.html 的 parseYRC():每行 [行始ms,行长ms] 后跟
// 若干 (词始ms,词长ms,0)文字;跳过没有任何非空词的行(NetEase 会吐一些零宽标记行)。
public enum YRCParser {
    private static let headRegex = try! NSRegularExpression(pattern: #"^\[(\d+),\d+\]"#)
    // 词文字捕获组(第 3 组)不能简单写 [^(]*——2026-08-02 实测排查坐实:如果某个词的
    // 原文本身含字面 "("(和声/口白标注常见,比如 "(oh)"),[^(]* 会在遇到这个字面 "("
    // 时就把这个词截断成空(空词在下面 wordText.isEmpty 判断里被整个丢弃),而剩下的
    // "(oh)" 因为不满足 \(\d+,\d+,\d+\) 这个真正的时间戳元组格式,正则引擎会继续往后扫,
    // 导致这段文字既不在被截断的这个词里、也不在下一个词里,彻底从输出里消失。改成
    // "遇到 ( 时,只有当它后面紧跟的确实是 \d+,\d+,\d+) 这个时间戳元组格式时才当作
    // 新词的开始;否则这个 ( 就是词文字本身的一部分,继续吃进当前词"——用负向前瞻
    // (?!\d+,\d+,\d+\)) 实现,不影响原有三个捕获组的编号(内层 (?:...) 都是非捕获组)。
    private static let wordRegex = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)((?:[^(]|\((?!\d+,\d+,\d+\)))*)"#)
    // 2026-08-03 实测排查坐实(周杰伦……不是,是 Michael Jackson《Morphine》的真实缓存
    // 数据,标题行 "********(0,2255,0) - Michael Jackson (迈克尔·杰克逊)" 的括号注音部分):
    // 上面那条 wordRegex 的负向前瞻只认"紧跟着的是完整 (数字,数字,数字) 三段式元组"才
    // 算真时间戳,这份真实数据里给"(""）"这两个标点各自配的元组却缺了第三段 flag——
    // 变成畸形的两段式 (18040,2255)、(36080,2255)。这种畸形元组既不满足三段式(不会被
    // wordRegex 当成词边界正确消费掉),又不是"(oh)"那种真的该保留的字面文字(它就是
    // 数字+逗号,不是人写的歌词内容)——上面那条 fix 的负向前瞻会把它整个当成"字面文字"
    // 吃进相邻词里,結果是把这两串裸数字原样显示给用户看("((18040,2255)迈克尔·杰克逊)
    // (36080,2255)"),比 fix 之前的旧正则(旧正则至少会把匹配不上的碎片直接跳过、只是
    // 丢一个字面括号,不会吐数字)还糟。在真正跑 wordRegex 之前,先把这类"两段式、没有
    // flag"的畸形元组整个切掉——真实歌词内容不会是"纯数字,纯数字"这种形状,判定
    // 依据足够安全,不会误伤"(oh)"这类真实字面括号内容。
    private static let malformedTupleRegex = try! NSRegularExpression(pattern: #"\(\d+,\d+\)"#)

    public static func parse(_ text: String) -> [LyricLineWords] {
        var out: [LyricLineWords] = []
        // 酷狗(KRC)歌词库是社区上传内容,不同贡献者的原始文件用 Windows 风格 CRLF("\r\n")
        // 换行的情况很常见(缓存里约一半酷狗 yrc 数据是 CRLF)。Swift 的 String 把 "\r\n"
        // 当成*一个*扩展字形簇(grapheme cluster),`split(separator:"\n")` 按 Character
        // 比较,单独的 "\n" 匹配不上这个复合字符,导致整份文本一条都切不开、原样当一整行——
        // 这一整"行"的开头是 [id:...]/[ar:...] 这类元信息标签而不是 [数字,数字],
        // headRegex 的 `^` 锚点匹配不上,直接整份歌词解析结果为空。归一化成纯 "\n" 后
        // 再切,才能正确按行处理。
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLineString = String(rawLine)
            let rawNsLine = rawLineString as NSString
            let headRange = NSRange(location: 0, length: rawNsLine.length)
            guard let head = headRegex.firstMatch(in: rawLineString, range: headRange) else { continue }
            let lineTimeMs = Int(rawNsLine.substring(with: head.range(at: 1))) ?? 0
            // 畸形两段式元组统一切掉——见 malformedTupleRegex 定义处的注释,必须先做这一步
            // 再跑 wordRegex,不然这些碎片会被 wordRegex 的负向前瞻误判成字面词文字整个
            // 吃进去,把裸数字显示给用户看。
            let line = malformedTupleRegex.stringByReplacingMatches(
                in: rawLineString, range: headRange, withTemplate: "")
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            var words: [LyricWord] = []
            for m in wordRegex.matches(in: line, range: fullRange) {
                let wordText = nsLine.substring(with: m.range(at: 3))
                if wordText.isEmpty { continue }
                let start = Int(nsLine.substring(with: m.range(at: 1))) ?? 0
                let dur = Int(nsLine.substring(with: m.range(at: 2))) ?? 0
                words.append(LyricWord(startMs: start, durationMs: dur, text: wordText))
            }
            if !words.isEmpty { out.append(LyricLineWords(timeMs: lineTimeMs, words: words)) }
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }
}
