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
    /// 一行的分类:`blank` 真空行(纯文本候选靠它分段)、`hidden` 播放时永远不会显示的行(元信息标签 /
    /// 只有时间戳没正文 / 署名行)、`visible` 正文行。`raw` 是 trim 过的原样(带时间戳)。
    /// `forPreview` 与 `LyricsBodyEdit` 共用这一份判据 —— 两处必须同源,否则预览和编辑框会各摘各的。
    struct ClassifiedLine {
        enum Kind { case blank, hidden, visible }
        let raw: String
        let kind: Kind
    }

    static func classify(_ lyrics: String, title: String, artist: String) -> [ClassifiedLine] {
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
            lines.append(Line(raw: trimmed, body: body, isBlank: false))
        }

        let bodies = lines.filter { !$0.isBlank && !$0.body.isEmpty }.map(\.body)
        var drop: [Bool] = Array(repeating: false, count: bodies.count)
        if !bodies.isEmpty {
            drop = LyricsSyncEngine.creditLineDropDecisions(
                bodies, trackTitle: title, trackArtist: artist,
                speakerExemptions: LyricDuet.speakers(in: bodies))
        }

        var out: [ClassifiedLine] = []
        var i = 0
        for line in lines {
            if line.isBlank {
                out.append(ClassifiedLine(raw: "", kind: .blank))
                continue
            }
            if line.body.isEmpty {
                out.append(ClassifiedLine(raw: line.raw, kind: .hidden))
                continue
            }
            defer { i += 1 }
            out.append(ClassifiedLine(raw: line.raw, kind: drop[i] ? .hidden : .visible))
        }
        return out
    }

    /// 摘掉元信息标签行与署名行之后的预览文本。`title` / `artist` 传候选自己那份元数据,
    /// 只用于署名过滤的豁免判断(播放路径传的是曲目元数据,同一个用途)。
    public static func forPreview(_ lyrics: String, title: String = "", artist: String = "") -> String {
        var out: [String] = []
        for line in classify(lyrics, title: title, artist: artist) {
            switch line.kind {
            case .blank: out.append("")
            case .hidden: continue
            case .visible: out.append(line.raw)
            }
        }
        // 头尾的空行是上面摘完之后剩下的空档,留着等于预览框顶部又空一截 —— 而"顶部这一截
        // 被浪费掉"正是这个函数存在的原因。中间的空行不动(纯文本候选的分段)。
        while out.first?.isEmpty == true { out.removeFirst() }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}

/// 「歌词管理」详情页「歌词(LRC)」编辑框显示的**正文**(2026-09-12,用户圈图问「帮我把这些部分在歌词管理里面
/// 去掉,不需要显示,只需要显示歌词正文」—— 圈的是 `[id:]`/`[ar:]`/`[ti:]`…`[offset:0]` 十行元信息标签,加上
/// 开头 `[00:00.00]One Last Kiss - 宇多田光`、`[00:09.57]词: 宇多田ヒカル` 那几行署名)。
///
/// 摘行的判据跟 `LyricsPreviewText.forPreview` 完全同源(元信息标签行 + 署名行摘掉、时间戳留着),差别在这里是
/// **编辑框**:用户改完要点「保存修改」写回缓存,被摘掉的那几行不能因为没显示就跟着丢 —— `[offset:]` 是有人消费的
/// (`LRCParser.parseOffsetMs`,整份时间轴的偏移),丢了这首歌会整体偏几百毫秒;`[ar:]/[ti:]` 也是备份归档
/// (`LyricsBackupArchive`)认的头部。所以把摘掉的行**按位置留底**:第一条可见行之前的原样原序做前缀(元信息标签 +
/// 开头的署名),之后的(夹在正文中间 / 尾部的署名)原样原序接在正文后面 —— 它们播放时本来就被 strippingCreditLines
/// 过滤,在文件里的位置对 LRC 解析无关紧要。
///
/// 正文没被改过时 `reassembled` 返回原文**一个字节都不动**:「保存修改」的内容指纹(offset 的 key)与脏判定不受影响。
/// 改过才按上面的规则拼(每行的首尾空白、CRLF 会随之归一,这是编辑的副作用,不是丢数据)。
///
/// 视图侧的接法(LyricsManagerView.detailView):编辑框绑的是 `body`,两条 onChange 互不打圈 —— `editedLyrics` 变了
/// 且**不等于**当前正文拼回去的结果(说明是换曲 / 采纳候选写进来的),才重算 `body`;`body` 变了就用本结构拼回
/// `editedLyrics`。要是无条件重算,用户敲下的每个回车都会被上面的归一化吃掉。
public struct LyricsBodyEdit: Equatable, Sendable {
    /// 原文,一字不动。
    public let original: String
    /// 编辑框里显示的正文(摘掉隐藏行、去掉头尾空行后按 `\n` 拼)。
    public let body: String
    /// 第一条可见行之前被摘掉的行,原样原序。
    public let hiddenPrefix: [String]
    /// 第一条可见行之后被摘掉的行,原样原序;拼回去时接在正文后面。
    public let hiddenSuffix: [String]

    public init(lyrics: String, title: String = "", artist: String = "") {
        original = lyrics
        var prefix: [String] = []
        var suffix: [String] = []
        var visible: [String] = []
        var seenVisible = false
        for line in LyricsPreviewText.classify(lyrics, title: title, artist: artist) {
            switch line.kind {
            case .blank:
                visible.append("")
            case .hidden:
                if seenVisible { suffix.append(line.raw) } else { prefix.append(line.raw) }
            case .visible:
                seenVisible = true
                visible.append(line.raw)
            }
        }
        while visible.first?.isEmpty == true { visible.removeFirst() }
        while visible.last?.isEmpty == true { visible.removeLast() }
        body = visible.joined(separator: "\n")
        hiddenPrefix = prefix
        hiddenSuffix = suffix
    }

    /// 把编辑框里的正文拼回完整歌词。正文没变 → 原文原样;变了 → 前缀 + 新正文(逐行原样,用户加的空行也留着)+ 后缀,
    /// 原文以换行收尾的话拼出来也以换行收尾。
    public func reassembled(body newBody: String) -> String {
        if newBody == body { return original }
        var out = hiddenPrefix
        if !newBody.isEmpty {
            out.append(contentsOf: newBody.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
        out.append(contentsOf: hiddenSuffix)
        var text = out.joined(separator: "\n")
        if original.hasSuffix("\n"), !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        return text
    }
}
