import Foundation

/// 「搜索候选歌词」右侧那只预览框里显示的文本(2026-09-04)。
///
/// # 为什么要有这一层
///
/// 预览框原来直接摊开候选的原始 LRC,于是最先映入眼帘的永远是那五六行**永远不会被显示**
/// 的东西(用户反馈「像是这种是不是不应该展示在右侧的框里面呢」):
///
/// ```
/// [ti:]
/// [ar:]
/// [al:]
/// [by:krc转qrc工具]
/// [offset:0]
/// [00:00.000] 作词 : Prince
/// ```
///
/// 前五行是 LRC 的元信息标签 —— `LRCParser.parse` 把它们整行跳过(去掉 `[...]` 后正文为空),
/// 一个字都到不了屏幕上;更糟的是这几个源常常把它们留成**空标签**,或者拿来签工具名。
/// 第六行起是署名/职员表,`LyricsSyncEngine` 播放时会用 `strippingCreditLines` 过滤掉。
/// 也就是说:预览框顶部这一整块,恰恰是这份歌词里唯一保证看不到的部分,而它挤掉的是
/// 用户真正要判断的东西 —— **第一句词对不对、时间轴准不准**。
///
/// 所以这里按**播放时的同一套判据**把它们摘掉,让预览等于"采纳之后你会看到的样子"。
///
/// # 三条边界
///
/// - **只影响预览,不影响落盘**:采纳写进缓存的仍然是候选的原始文本(`Candidate.lyrics`),
///   这个函数一个调用点都不在写入路径上。元信息里 `[offset:]` 是**有人消费的**
///   (`LRCParser.parseOffsetMs`,整份时间轴的偏移),要是连带把存的内容也剥了,这首歌的
///   歌词就会整体偏几百毫秒。
/// - **时间戳留着**:被摘掉的是"不会显示的行",不是"行首的时间戳"。预览里那一列
///   `[00:20.50]` 正是用户判断这份歌词有没有轴、轴密不密的依据。
/// - **署名过滤复用 Core 的同一个判据**(`LyricsSyncEngine.creditLineDropDecisions`),
///   不在这里另写一套关键词表:那张表被真实语料喂了十几轮(见 09 章),第二份必然漂移。
///   `LyricDuet.speakers` 的豁免同样要传 —— 对唱歌每句都带 `周杰伦：` 这种标记,天然满足
///   署名过滤"命中过半"的闸门,不给豁免就是整首被摘空(播放路径也是先认标记再过滤,
///   顺序不能反,见 LyricsSyncEngine 里那段注释)。
public enum LyricsPreviewText {
    /// 摘掉元信息标签行与署名行之后的预览文本。`title` / `artist` 传候选自己那份元数据,
    /// 只用于署名过滤的豁免判断(播放路径传的是曲目元数据,同一个用途)。
    public static func forPreview(_ lyrics: String, title: String = "", artist: String = "") -> String {
        // 一行的两副面孔:`raw` 是原样(带时间戳,要显示的就是它),`body` 是剥掉行首所有
        // `[...]` 之后的正文(喂给署名判据的就是它 —— 那套规则认的是词,不是时间戳)。
        struct Line { let raw: String; let body: String; let isBlank: Bool }
        var lines: [Line] = []
        // ⚠️ 按 Unicode 标量切,不能 `split(separator: "\n")`:`\r\n` 是单个字素簇、跟 `"\n"`
        // 不相等,CRLF 的社区歌词(酷狗尤其常见)会整份切不开。同 ManualPickLock.canonicalLyrics
        // 那处踩过的坑,理由完整写在那边。
        for rawScalars in lyrics.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(String.UnicodeScalarView(rawScalars))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // 真空行留着 —— 纯文本候选(lrclib 那种没有时间戳的)靠它分段。
                lines.append(Line(raw: "", body: "", isBlank: true))
                continue
            }
            var body = trimmed
            while body.hasPrefix("["), let end = body.firstIndex(of: "]") {
                body = String(body[body.index(after: end)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // 剥完什么都不剩 = 这一行只有标签:`[ti:]`/`[by:工具名]`/`[offset:0]` 这些元信息,
            // 或者一个孤零零、后面没词的时间戳。播放路径(LRCParser.parse)对两者都是整行跳过。
            if body.isEmpty { continue }
            lines.append(Line(raw: trimmed, body: body, isBlank: false))
        }

        let bodies = lines.filter { !$0.isBlank }.map(\.body)
        var drop: [Bool] = Array(repeating: false, count: bodies.count)
        if !bodies.isEmpty {
            drop = LyricsSyncEngine.creditLineDropDecisions(
                bodies, trackTitle: title, trackArtist: artist,
                speakerExemptions: LyricDuet.speakers(in: bodies))
        }

        var out: [String] = []
        var i = 0
        for line in lines {
            if line.isBlank {
                out.append("")
                continue
            }
            defer { i += 1 }
            if drop[i] { continue }
            out.append(line.raw)
        }
        // 头尾的空行是上面摘完之后剩下的空档,留着等于预览框顶部又空一截 —— 而"顶部这一截
        // 被浪费掉"正是这个函数存在的原因。中间的空行不动(纯文本候选的分段)。
        while out.first?.isEmpty == true { out.removeFirst() }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
