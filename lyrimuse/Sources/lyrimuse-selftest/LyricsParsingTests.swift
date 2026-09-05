import LyrimuseCore
import Foundation

// 歌词解析:LRC / YRC / 逐字时间轴归一化。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runLyricsParsingTests() {
    // ---- LRCParser ----

    expectEqual(
        LRCParser.parse("[00:01.50]la la la\n[00:03.00]la la\n"),
        [LyricLine(timeMs: 1500, text: "la la la"), LyricLine(timeMs: 3000, text: "la la")],
        "LRC: 基本时间戳解析"
    )

    expectEqual(
        LRCParser.parse("[00:01.5]a\n[00:02.50]b\n[00:03.500]c\n").map(\.timeMs),
        [1500, 2500, 3500],
        "LRC: 1/2/3位小数归一化成毫秒"
    )

    expectEqual(
        LRCParser.parse("[00:01:25]x\n"),
        [LyricLine(timeMs: 1250, text: "x")],
        "LRC: 冒号做小数分隔符的变体"
    )

    expectEqual(
        LRCParser.parse("[00:10.00][00:40.00]repeat me\n"),
        [LyricLine(timeMs: 10000, text: "repeat me"), LyricLine(timeMs: 40000, text: "repeat me")],
        "LRC: 一行多个时间戳(副歌重复)各生成一条"
    )

    // --- FrameRateProbe (2026-08-22) ---
    //
    // 拆成纯值类型放 Core 就是为了能无屏测它(同 KaraokeFill/MarqueeMath)。
    do {
        var probe = FrameRateProbe()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        expectEqual(probe.fps == nil, true, "帧率探针: 第一帧还没有样本")
        probe.tick(at: t0)
        expectEqual(probe.fps == nil, true, "帧率探针: 只有一帧仍算不出间隔")
        // 稳定 30fps 喂 200 帧,EMA 该收敛到 30 附近。
        var t = t0
        for _ in 0..<200 {
            t = t.addingTimeInterval(1.0 / 30)
            probe.tick(at: t)
        }
        let fps = probe.fps ?? 0
        expectEqual(abs(fps - 30) < 0.5, true, "帧率探针: 稳定 30fps 收敛到 30(实测 \(fps))")
        // 长空档(暂停/停表)必须重新起算,不能把那个间隔算进平均值 —— 否则恢复播放后
        // 读数会长时间失真。
        probe.tick(at: t.addingTimeInterval(5))
        expectEqual(probe.fps == nil, true, "帧率探针: 超过不连续阈值后重新起算")
        // 时钟回拨/同一帧调两次不该污染平均值。
        var probe2 = FrameRateProbe()
        let s0 = Date(timeIntervalSinceReferenceDate: 2000)
        probe2.tick(at: s0)
        probe2.tick(at: s0)
        expectEqual(probe2.fps == nil, true, "帧率探针: 零间隔被丢弃")
        probe2.tick(at: s0.addingTimeInterval(-1))
        expectEqual(probe2.fps == nil, true, "帧率探针: 负间隔被丢弃")
    }

    // --- LRC 自带的 [offset:] (2026-08-22) ---
    //
    // 这个字段此前全链路无人消费:parse() 把它当元信息行整个跳过,于是"歌词源明确告诉了我们
    // 要偏多少"这件事被静默丢掉。本机 114 条缓存实测:酷狗 50 条里 30 条带这个标签(2 条非零,
    // 242 / 600ms)、QQ 12 条全部带(恰好都是 0),网易云/Musixmatch 从不带 —— 不是单个源的
    // 特性,所以处理放在通用解析层。
    expectEqual(LRCParser.parseOffsetMs("[offset:242]\n[00:01.00]x\n"), 242, "LRC offset: 正数")
    expectEqual(LRCParser.parseOffsetMs("[offset:+500]\n"), 500, "LRC offset: 显式带加号")
    expectEqual(LRCParser.parseOffsetMs("[offset:-300]\n"), -300, "LRC offset: 负数")
    expectEqual(LRCParser.parseOffsetMs("[offset: 600 ]\n"), 600, "LRC offset: 冒号后/数字后允许空格")
    expectEqual(LRCParser.parseOffsetMs("[offset:0]\n"), 0, "LRC offset: 零就是没有偏移")
    expectEqual(LRCParser.parseOffsetMs("[ti:x]\n[00:01.00]y\n"), 0, "LRC offset: 没有这个标签返回 0")
    // 量级闸:见过畸形数据把整份歌词推到几十秒开外,那种"修正"比不修正糟得多。
    expectEqual(LRCParser.parseOffsetMs("[offset:99999]\n"), 0, "LRC offset: 超出可信上限一律不采纳")
    expectEqual(LRCParser.parseOffsetMs("[offset:-99999]\n"), 0, "LRC offset: 负向超限同样不采纳")
    expectEqual(LRCParser.parseOffsetMs("[offset:10000]\n"), 10000, "LRC offset: 上限本身仍然采纳")
    // 多个标签取第一个:文件头部才是元信息区,正文里再出现同形状的东西不该当成全局设置。
    expectEqual(LRCParser.parseOffsetMs("[offset:100]\n[offset:900]\n"), 100, "LRC offset: 多个取第一个")
    // parse() 的行为一点没变 —— offset 行仍然不产出歌词行。
    expectEqual(
        LRCParser.parse("[offset:242]\n[00:01.00]x\n"),
        [LyricLine(timeMs: 1000, text: "x")],
        "LRC offset: 标签行不会被当成一句歌词"
    )

    // 引擎侧:LRC offset 与用户偏移是**两层**,相加后才是定位用的总偏移。
    // 分开存的理由见 LyricsSyncEngine.lrcOffsetMs 的注释(换歌词时旧值不会残留在用户那层,
    // 且符号约定万一相反时用户能用单曲微调抵消)。
    do {
        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: "[offset:400]\n[00:10.00]a\n[00:20.00]b\n",
                        lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.lrcOffsetMs, 400, "引擎: 从歌词内容解析出 LRC offset")
        expectEqual(engine.effectiveOffsetMs, 400, "引擎: 用户偏移为 0 时总偏移=LRC offset")
        engine.offsetMs = 250
        expectEqual(engine.effectiveOffsetMs, 650, "引擎: 两层相加")
        // 正数=提前显示:第二行时间戳 20000,总偏移 650 时播放到 19400 就该切过去了。
        expectEqual(engine.activeLine(atMs: 19400)?.plainText, "b", "引擎: 正偏移让下一行提前出现")
        expectEqual(engine.activeLine(atMs: 19300)?.plainText, "a", "引擎: 差 100ms 还没到")
        // 换一份不带 offset 的歌词,那一层必须归零(不能残留)。
        _ = engine.load(lyrics: "[00:10.00]c\n", lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.lrcOffsetMs, 0, "引擎: 换成不带 offset 的歌词后该层归零")
        expectEqual(engine.effectiveOffsetMs, 250, "引擎: 归零后只剩用户那层")
    }

    // 只有逐字数据、整行为空时,从 YRC 里取 —— 酷狗那两首非零的实测里 .lrc/.yrc 头部
    // 带的是同一个值(KRC 母版转出来的两种形态)。
    do {
        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "",
                        lyricsYRC: "[offset:600]\n[10000,2000](10000,2000,0)a\n")
        expectEqual(engine.lrcOffsetMs, 600, "引擎: 整行为空时从 YRC 取 offset")
    }

    expectEqual(
        LRCParser.parse("[ti:Test Song]\n[by:Someone]\n[00:00.00]actual line\n"),
        [LyricLine(timeMs: 0, text: "actual line")],
        "LRC: 跳过纯标签/元信息行"
    )

    expectEqual(LRCParser.parse("just plain text\n"), [], "LRC: 无时间戳的行整体忽略")
    expectEqual(LRCParser.parse(""), [], "LRC: 空输入")

    expectEqual(
        LRCParser.parse("[00:05.00]second\n[00:01.00]first\n").map(\.timeMs),
        [1000, 5000],
        "LRC: 输出按时间排序(输入乱序)"
    )

    // CRLF 换行(酷狗等社区上传内容常见 Windows 风格换行)——Swift 把 "\r\n" 当成一个扩展
    // 字形簇,split(separator:"\n") 按 Character 比较匹配不上,会导致整份文本切不开、
    // tagRegex(无 ^ 锚点)在这"一整行"里找到多个时间戳,但方括号剥离只对整份文本做了一次,
    // 于是每个时间戳都各自生成一条 LyricLine、text 却全部是同一份"整首歌拼在一起"的巨大
    // 字符串——这正是"酷狗歌词整个桌面都是歌词"这个坑的根因,回归测试要覆盖。
    expectEqual(
        LRCParser.parse("[00:01.00]first\r\n[00:02.00]second\r\n[00:03.00]third\r\n"),
        [LyricLine(timeMs: 1000, text: "first"), LyricLine(timeMs: 2000, text: "second"), LyricLine(timeMs: 3000, text: "third")],
        "LRC: CRLF换行正确切成三条独立行,而非合并成一整块"
    )

    // ---- YRCParser ----

    do {
        let text = "[1000,2000](1000,500,0)la (1500,500,0)la (2000,500,0)la "
        let lines = YRCParser.parse(text)
        expectEqual(lines.count, 1, "YRC: 单行解析出恰好一条")
        expectEqual(lines.first?.timeMs, 1000, "YRC: 行时间戳")
        expectEqual(lines.first?.words ?? [], [
            LyricWord(startMs: 1000, durationMs: 500, text: "la "),
            LyricWord(startMs: 1500, durationMs: 500, text: "la "),
            LyricWord(startMs: 2000, durationMs: 500, text: "la "),
        ], "YRC: 逐字词数组")
    }

    do {
        let text = "[0,1000](0,0,0)(500,500,0)word"
        let lines = YRCParser.parse(text)
        expectEqual(lines.first?.words ?? [], [LyricWord(startMs: 500, durationMs: 500, text: "word")], "YRC: 跳过零宽标记词")
    }

    expectEqual(YRCParser.parse("[0,1000](0,0,0)(100,0,0)"), [], "YRC: 整行全是零宽标记则整行跳过")
    expectEqual(YRCParser.parse("no header here (1,2,0)x"), [], "YRC: 没有行头的行忽略")

    do {
        // 2026-08-02 修复:词文字本身含字面括号(和声/口白标注常见,比如"(oh)")时,不能被
        // 误判成"下一个时间戳元组开始了"而截断丢字,详见 wordRegex 定义处的注释。
        let text = "[0,3000](0,500,0)Hello(1600,400,0)(oh)(2100,300,0)world"
        let lines = YRCParser.parse(text)
        expectEqual(lines.first?.words ?? [], [
            LyricWord(startMs: 0, durationMs: 500, text: "Hello"),
            LyricWord(startMs: 1600, durationMs: 400, text: "(oh)"),
            LyricWord(startMs: 2100, durationMs: 300, text: "world"),
        ], "YRC: 词文字含字面括号时不会被误判丢字")
    }

    do {
        // 2026-08-03 修复:2026-08-02 那条修复的负向前瞻只认"紧跟着的是完整三段式
        // (数字,数字,数字)"才算真时间戳——真实缓存数据(Michael Jackson《Morphine》标题行
        // 括号注音部分)里给标点配的元组缺了第三段 flag,变成畸形两段式 (18040,2255),
        // 既不满足三段式、又不是真的该保留的字面文字(纯数字,不是人写的歌词内容),会被
        // 上面那条负向前瞻整个当成字面文字吃进相邻词里,把裸数字原样吐给用户看。
        let text = "[0,3000](0,500,0)Jackson(1600,500,0) ((1000,500)(2100,300,0)word(2400,300,0)(2700,300)"
        let lines = YRCParser.parse(text)
        expectEqual(lines.first?.words ?? [], [
            LyricWord(startMs: 0, durationMs: 500, text: "Jackson"),
            LyricWord(startMs: 1600, durationMs: 500, text: " ("),
            LyricWord(startMs: 2100, durationMs: 300, text: "word"),
        ], "YRC: 畸形两段式元组(缺 flag)被整体切掉,不会把裸数字吐给用户")
    }

    expectEqual(
        YRCParser.parse("[5000,1000](5000,500,0)second\n[1000,1000](1000,500,0)first\n").map(\.timeMs),
        [1000, 5000],
        "YRC: 输出按时间排序(输入乱序)"
    )

    expectEqual(YRCParser.parse(""), [], "YRC: 空输入")

    // 见上面 LRCParser 同一处注释——CRLF 换行会让 YRCParser 更彻底地失败:整份文本切不开后,
    // headRegex 有 ^ 锚点、匹配不上"一整行"开头(通常是元信息标签而非 [数字,数字]),直接
    // 整份解析结果为空(比 LRCParser 的"表面有行、内容全错"更隐蔽,会静默退化成没有逐字数据)。
    expectEqual(
        YRCParser.parse("[1000,500](1000,500,0)la \r\n[2000,500](2000,500,0)la \r\n"),
        [
            LyricLineWords(timeMs: 1000, words: [LyricWord(startMs: 1000, durationMs: 500, text: "la ")]),
            LyricLineWords(timeMs: 2000, words: [LyricWord(startMs: 2000, durationMs: 500, text: "la ")]),
        ],
        "YRC: CRLF换行正确切成两条独立行,而非整份解析失败"
    )

    // MARK: - LyricTimelineNormalizer:逐字时间轴合法性归一化(2026-09-02)
    //
    // 规则与阈值的依据见 LyricTimelineNormalizer 头注(全库 3071 首实测)。这里钉住每条规则的
    // 数值行为:夹到哪、终点动不动、什么情况退化、退化成什么形状、边界(最后一行 / 同时间戳 / 空)。
    do {
        let W = LyricTimelineNormalizer.tailWindowMs
        func line(_ t: Int, _ ws: [(Int, Int, String)]) -> LyricLineWords {
            LyricLineWords(timeMs: t, words: ws.map { LyricWord(startMs: $0.0, durationMs: $0.1, text: $0.2) })
        }
        expectEqual(W, KaraokeFill.lineTailLeadMs + KaraokeFill.minTailFillMs,
                    "时间轴归一化: 拉回窗口 = 换行提前量 + 最短填色时长,跟 KaraokeFill 绑定")

        // 合法数据原样返回,报告为空
        let ok = [line(1000, [(1000, 300, "a"), (1300, 300, "b")]), line(2000, [(2000, 500, "c")])]
        let r0 = LyricTimelineNormalizer.normalize(ok)
        expectEqual(r0.lines, ok, "时间轴归一化: 合法数据一个字不动")
        expectEqual(r0.report.isEmpty, true, "时间轴归一化: 合法数据报告为空")

        // 字起点早于行首 ≤250ms:夹到行首,终点不动
        let before = [line(1000, [(900, 400, "a"), (1300, 300, "b")]), line(2000, [(2000, 500, "c")])]
        let r1 = LyricTimelineNormalizer.normalize(before)
        expectEqual(r1.lines[0].words[0], LyricWord(startMs: 1000, durationMs: 300, text: "a"),
                    "时间轴归一化: 早于行首 100ms 的字夹到行首、终点不动")
        expectEqual(r1.lines[0].words[1], LyricWord(startMs: 1300, durationMs: 300, text: "b"),
                    "时间轴归一化: 同行其它字不受影响")
        expectEqual(r1.report.clampedToLineStart, 1, "时间轴归一化: 行首夹取计数")

        // 早于行首 >250ms:整行退化成一个字,文字拼接,从行首扫到下一行开始
        let far = [line(1000, [(600, 400, "a"), (1300, 300, "b")]), line(2000, [(2000, 500, "c")])]
        let r2 = LyricTimelineNormalizer.normalize(far)
        expectEqual(r2.lines[0].words, [LyricWord(startMs: 1000, durationMs: 1000, text: "ab")],
                    "时间轴归一化: 早于行首 400ms → 整行退化为单字匀速扫过,文字不丢")
        expectEqual(r2.report.degradedLines[.wordBeforeLine], 1, "时间轴归一化: 退化原因 word_before_line")
        expectEqual(r2.lines[1], far[1], "时间轴归一化: 退化只影响那一行")

        // 起点正好等于下一行开始(网易云行尾标点、时长 0):拉到 next - W,终点不动 → 时长变成 W
        let punct = [line(1000, [(1000, 300, "a"), (2000, 0, "?")]), line(2000, [(2000, 500, "c")])]
        let r3 = LyricTimelineNormalizer.normalize(punct)
        expectEqual(r3.lines[0].words[1], LyricWord(startMs: 2000 - W, durationMs: W, text: "?"),
                    "时间轴归一化: 起点=下一行起点的字拉回换行前 W 毫秒,终点不动")
        expectEqual(r3.report.clampedBeforeNextLine, 1, "时间轴归一化: 下一行夹取计数")

        // 晚于下一行 100ms 的真词(酷狗/QQ 形态):同样拉回,终点保留
        let late = [line(1000, [(1000, 300, "a"), (2100, 200, "b")]), line(2000, [(2000, 500, "c")])]
        let r4 = LyricTimelineNormalizer.normalize(late)
        expectEqual(r4.lines[0].words[1], LyricWord(startMs: 2000 - W, durationMs: 2300 - (2000 - W), text: "b"),
                    "时间轴归一化: 晚于下一行 100ms 的字拉回 next-W,终点 2300 不动")

        // 晚于下一行 >250ms:整行退化
        let veryLate = [line(1000, [(1000, 300, "a"), (2400, 200, "b")]), line(2000, [(2000, 500, "c")])]
        let r5 = LyricTimelineNormalizer.normalize(veryLate)
        expectEqual(r5.report.degradedLines[.wordAfterNextLine], 1, "时间轴归一化: 晚 400ms → 退化 word_after_next_line")
        expectEqual(r5.lines[0].words, [LyricWord(startMs: 1000, durationMs: 1000, text: "ab")],
                    "时间轴归一化: 退化行从行首扫到下一行开始")

        // 起点倒退:整行退化
        let dec = [line(1000, [(1000, 300, "a"), (1500, 300, "b"), (1200, 300, "c")]), line(3000, [(3000, 500, "d")])]
        let r6 = LyricTimelineNormalizer.normalize(dec)
        expectEqual(r6.lines[0].words, [LyricWord(startMs: 1000, durationMs: 2000, text: "abc")],
                    "时间轴归一化: 字起点倒退 → 整行退化")
        expectEqual(r6.report.degradedLines[.wordStartDecreased], 1, "时间轴归一化: 退化原因 word_start_decreased")

        // 最后一行没有下一行:晚起点不判;退化时长到原最后一字终点
        let last = [line(1000, [(1000, 300, "a"), (9000, 200, "b")])]
        expectEqual(LyricTimelineNormalizer.normalize(last).lines, last, "时间轴归一化: 最后一行没有边界,晚起点不动")
        let lastDec = [line(1000, [(1000, 300, "a"), (1500, 300, "b"), (1200, 800, "c")])]
        expectEqual(LyricTimelineNormalizer.normalize(lastDec).lines[0].words,
                    [LyricWord(startMs: 1000, durationMs: 1000, text: "abc")],
                    "时间轴归一化: 最后一行退化时长 = 原最后一字终点(2000) - 行首")

        // 相邻行同一时间戳(对唱两声部/重复行):没有可用边界,不能把整行判成越过下一行
        let same = [line(1000, [(1000, 300, "a"), (1300, 300, "b")]), line(1000, [(1000, 300, "c")]), line(2000, [(2000, 100, "d")])]
        let r7 = LyricTimelineNormalizer.normalize(same)
        expectEqual(r7.lines[0].words, same[0].words, "时间轴归一化: 同时间戳的下一行不算边界")
        expectEqual(r7.report.isEmpty, true, "时间轴归一化: 同时间戳场景报告为空")

        // 拉回 next-W 时不能倒退到前一个字之前,也不能早于行首
        let crowd = [line(1000, [(1000, 300, "a"), (1900, 50, "b"), (2000, 50, "c")]), line(2000, [(2000, 500, "d")])]
        let r8 = LyricTimelineNormalizer.normalize(crowd)
        expectEqual(r8.lines[0].words[2].startMs, 1900, "时间轴归一化: 拉回不越过前一个字的起点")
        let short = [line(1900, [(2000, 50, "a")]), line(2000, [(2000, 500, "b")])]
        let r9 = LyricTimelineNormalizer.normalize(short)
        expectEqual(r9.lines[0].words[0].startMs, 1900, "时间轴归一化: 行比 W 短时拉回到行首为止")

        expectEqual(LyricTimelineNormalizer.normalize([]).lines, [], "时间轴归一化: 空输入")
    }

    // ---- LyricsPreviewText(2026-09-04) ----
    //
    // 「搜索候选歌词」右侧预览框摘掉"永远不会显示的那几行"。判据必须跟播放路径同源,
    // 所以这里钉的是**边界**:该摘的摘干净、不该摘的一行都不能少。
    do {
        let head = "[ti:]\n[ar:]\n[al:]\n[by:krc转qrc工具]\n[offset:0]\n[00:20.50]One more card\n"
        expectEqual(
            LyricsPreviewText.forPreview(head),
            "[00:20.50]One more card",
            "预览: 元信息标签行(含空标签/工具签名/offset)整块摘掉"
        )

        expectEqual(
            LyricsPreviewText.forPreview("[00:00.00] 作词 : Prince\n[00:01.00] 作曲 : Prince\n[00:02.00] 制作人 : Prince\n[00:20.50]One more card\n"),
            "[00:20.50]One more card",
            "预览: 署名行走 creditLineDropDecisions 同一套判据"
        )

        // 时间戳是用户判断"有没有轴"的依据,摘行不等于摘时间戳。
        expectEqual(
            LyricsPreviewText.forPreview("[00:20.50]a\n[00:24.25]b\n"),
            "[00:20.50]a\n[00:24.25]b",
            "预览: 正文行连时间戳原样留着"
        )

        // 只有时间戳、后面没词的孤立行,播放路径(LRCParser.parse)也是整行跳过。
        expectEqual(
            LyricsPreviewText.forPreview("[00:20.50]\n[00:24.25]b\n"),
            "[00:24.25]b",
            "预览: 只有时间戳没正文的行摘掉"
        )

        // CRLF:按标量切才分得开(同 ManualPickLock 那处的坑),按字素簇切会整份不分行、
        // 于是一行都摘不掉。
        expectEqual(
            LyricsPreviewText.forPreview("[ti:]\r\n[00:20.50]a\r\n"),
            "[00:20.50]a",
            "预览: CRLF 换行照样分得开"
        )

        // 对唱标记每句都命中署名过滤的形状,豁免没传就是整首被摘空。
        let duet = "[00:10.00]周杰伦：我送你离开\n[00:12.00]周杰伦：千里之外\n[00:14.00]周杰伦：醉解千愁\n"
        expectEqual(
            LyricsPreviewText.forPreview(duet),
            duet.trimmingCharacters(in: .newlines),
            "预览: 对唱标记行带豁免,不被当署名摘掉"
        )

        // 纯文本候选(lrclib 那种没有时间戳的)靠空行分段,中间的空行要留着。
        expectEqual(
            LyricsPreviewText.forPreview("first verse\n\nsecond verse\n"),
            "first verse\n\nsecond verse",
            "预览: 纯文本候选中间的空行保留"
        )

        expectEqual(LyricsPreviewText.forPreview(""), "", "预览: 空输入")
        expectEqual(LyricsPreviewText.forPreview("[ti:]\n[ar:]\n"), "", "预览: 整份只有元信息 → 空")
    }

    // ---- LyricsQueryFieldLayout(2026-09-04) ----
    //
    // 「搜索候选歌词」那排查询词输入框按内容长度分宽。三条规则各钉边界。
    do {
        // 规则 2:放得下 → 每栏拿满自己想要的,多出来的**平均**分(而不是全给最长那栏)
        let roomy = LyricsQueryFieldLayout.widths(desired: [100, 90, 170], available: 390, minWidth: 88)
        expectEqual(roomy, [110, 100, 180], "查询词分宽: 放得下时各拿所需 + 余量平均分")
        expectEqual(roomy.reduce(0, +), 390, "查询词分宽: 放得下时正好铺满")

        // 空栏(desired 小于下限)先被托到下限,再参与余量平均分
        expectEqual(
            LyricsQueryFieldLayout.widths(desired: [10, 10, 10], available: 300, minWidth: 88),
            [100, 100, 100],
            "查询词分宽: 短到低于下限的栏先托到下限"
        )

        // 规则 3:放不下 → 按比例,但谁都不低于下限;被托住的钉死,其余再按比例分
        let tight = LyricsQueryFieldLayout.widths(desired: [400, 40, 400], available: 500, minWidth: 88)
        expectEqual(tight[1], 88, "查询词分宽: 挤的时候短栏被下限托住,不会压成几像素")
        expectEqual(tight[0], tight[2], "查询词分宽: 同样长的两栏分到一样宽")
        expectEqual(tight.reduce(0, +), 500, "查询词分宽: 挤的时候也正好铺满")
        expectEqual(tight[0] > 88, true, "查询词分宽: 长栏拿到的比下限多")

        // 规则 1:连下限都给不到 → 平均分(可预测优先)
        expectEqual(
            LyricsQueryFieldLayout.widths(desired: [400, 40, 400], available: 120, minWidth: 88),
            [40, 40, 40],
            "查询词分宽: 窄到给不满下限时平均分"
        )

        expectEqual(LyricsQueryFieldLayout.widths(desired: [], available: 400, minWidth: 88), [],
                    "查询词分宽: 空输入")
        expectEqual(LyricsQueryFieldLayout.widths(desired: [100, 100], available: 0, minWidth: 88), [0, 0],
                    "查询词分宽: 可用宽度为 0")
        expectEqual(
            LyricsQueryFieldLayout.widths(desired: [0, 0, 0], available: 600, minWidth: 88),
            [200, 200, 200],
            "查询词分宽: desired 全 0 退化成等分,不出 NaN"
        )
    }
}
