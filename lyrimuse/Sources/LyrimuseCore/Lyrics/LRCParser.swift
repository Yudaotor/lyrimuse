import Foundation

public struct LyricLine: Equatable {
    public let timeMs: Int
    public let text: String
    public init(timeMs: Int, text: String) {
        self.timeMs = timeMs
        self.text = text
    }
}

// 逐行 LRC 解析,算法照抄 web/index.html 的 parseLRC():一行可能带多个时间戳(副歌重复出现),
// 每个时间戳各生成一条;跳过纯标签/元信息行([ti:]、[by:] 等,去掉所有 [...] 后文本为空)。
public enum LRCParser {
    private static let tagRegex = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
    private static let bracketRegex = try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)
    private static let offsetRegex = try! NSRegularExpression(pattern: #"\[offset:\s*([+-]?\d+)\s*\]"#)

    /// LRC 格式标准里的 `[offset:±毫秒]` 标签 —— 「这份歌词的全部时间戳整体偏移多少」。
    /// 打轴的人发现自己整份早了/晚了就写一个 offset,而不是逐行改几百个时间戳。
    ///
    /// `parse(_:)` 会把它当元信息行整个跳过(去掉 `[...]` 后正文为空),所以在此之前
    /// **这个字段全链路无人消费** —— 歌词源明确告诉了我们要偏多少,而我们没听。
    ///
    /// 符号约定跟 LRC 规范一致、也跟 `LyricsSyncEngine.offsetMs` 同号:**正数 = 歌词整体
    /// 提前显示**。规范原文是 "+ shifts the lyrics earlier";换算过来 `显示时刻 = 时间戳 −
    /// offset`,而引擎那边是「查询位置 = 播放位置 + offsetMs」再扫 `timeMs <= 查询位置`,
    /// 两者等价,所以可以直接相加、不用取反。
    ///
    /// 实测(2026-08-22,本机 114 条缓存):**不是只有某一个源会带**——酷狗 50 条里 30 条带
    /// 这个标签(2 条非零:242 / 600),QQ 12 条**全部**带(本机恰好都是 0)。网易云/Musixmatch
    /// 从不带,lrclib 样本只有 1 条不足为据(而它是社区上传的纯 LRC,格式上最有可能带)。
    /// 所以这件事必须放在通用解析层,不能对某个源特判。
    ///
    /// 找不到/解析不出返回 0。多个 offset 标签取**第一个** —— 那是文件头部的元信息区,
    /// 正文里再出现同样形状的东西不该被当成全局设置。
    public static func parseOffsetMs(_ text: String) -> Int {
        let ns = text as NSString
        guard let m = offsetRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let value = Int(ns.substring(with: m.range(at: 1)))
        else { return 0 }
        // 夹一个量级闸:正常的 offset 是几百毫秒到一两秒。见过畸形数据把整份歌词推到几十秒
        // 开外的形态,那种"修正"比不修正糟得多,宁可当它不存在。
        guard abs(value) <= maxOffsetMs else { return 0 }
        return value
    }

    /// `[offset:]` 的可信上限。10 秒:比任何真实的打轴误差都大一个量级,又不至于把
    /// 少数确实偏得多的社区歌词一并否掉。
    public static let maxOffsetMs = 10_000

    public static func parse(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        // 见 YRCParser.parse 同一处注释:CRLF 换行的社区上传内容(酷狗尤其常见)会让
        // split(separator:"\n") 按 Character 比较时把整份文本当一整行切不开。这里的
        // 后果比 YRCParser 更隐蔽也更严重——tagRegex(找 [mm:ss.xx])没有 `^` 锚点,会在
        // 这"一整行"里到处找到多个时间戳,但 stripped(去掉所有方括号标签后的正文)是
        // 对整份文本只算了一次,于是每个时间戳都各自生成一条 LyricLine、但 text 字段
        // 全部是同一份"整首歌歌词拼在一起"的巨大字符串——播放到任意一个时间戳都会把
        // 全曲歌词当成"这一行"整个显示出来,表现正是"整个桌面都是歌词"。
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = tagRegex.matches(in: line, range: fullRange)
            if matches.isEmpty { continue }
            let stripped = bracketRegex
                .stringByReplacingMatches(in: line, range: fullRange, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            for m in matches {
                let minutes = Int(nsLine.substring(with: m.range(at: 1))) ?? 0
                let seconds = Int(nsLine.substring(with: m.range(at: 2))) ?? 0
                var fracMs = 0
                let fracRange = m.range(at: 3)
                if fracRange.location != NSNotFound {
                    // 小数位可能是 1~3 位(.5/.50/.500 都代表 500ms):右补两个0再截前3位,
                    // 跟 JS 版 (m[3]+'00').slice(0,3) 是同一个归一化写法。
                    var frac = nsLine.substring(with: fracRange)
                    frac += "00"
                    frac = String(frac.prefix(3))
                    fracMs = Int(frac) ?? 0
                }
                let t = (minutes * 60 + seconds) * 1000 + fracMs
                out.append(LyricLine(timeMs: t, text: stripped))
            }
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }
}
