import LyrimuseCore
import Foundation

// 手写的极简断言跑法:这台机器没有完整 Xcode,XCTest/Testing 两个测试框架都用不了
// ("no such module"),所以用普通可执行 target + assert 风格的比较代替,`swift run
// lyrimuse-selftest` 跑一遍即可,失败时进程以非零状态码退出。所有用例都是合成
// 字符串,不含真实歌词文本。

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        print("ok - \(label)")
    } else {
        failures += 1
        print("FAIL - \(label)\n    actual:   \(actual)\n    expected: \(expected)")
    }
}

func expectNotEqual<T: Equatable>(_ actual: T, _ unexpected: T, _ label: String) {
    if actual != unexpected {
        print("ok - \(label)")
    } else {
        failures += 1
        print("FAIL - \(label)\n    两者相等,但期望不同:  \(actual)")
    }
}

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

// ---- LyricsSyncEngine: 署名/制作人员噪声行过滤 ----

do {
    let engine = LyricsSyncEngine()
    let lrc = "[00:00.00]作词 : 甲\n[00:01.00]作曲：乙\n[00:26.74]la la la\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 500)?.mainText, nil, "SyncEngine: 署名行时段内没有真歌词,判定成还没到第一句")
    expectEqual(engine.activeLine(atMs: 27000)?.mainText, "la la la", "SyncEngine: 真歌词开始后正常显示")
    expectEqual(engine.upcomingLineText(afterMs: 500), "la la la", "SyncEngine: 署名行被过滤后,双行预览提前露出第一句真歌词")
}

do {
    let engine = LyricsSyncEngine()
    let yrc = "[0,1000](0,500,0)作词 (500,500,0)：甲 \n[26740,1000](26740,500,0)la (27240,500,0)la \n"
    engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 500)?.words, nil, "SyncEngine(YRC): 整行都是署名词时整行被过滤")
    expectEqual(engine.activeLine(atMs: 27000)?.words?.map(\.text), ["la ", "la "], "SyncEngine(YRC): 真歌词行不受影响")
}

// ---- 间奏点(2026-08-19,歌词窗口的 Apple Music 式「•••」) ----
do {
    let engine = LyricsSyncEngine()
    // 逐字:前奏 8s(≥5s → 标);第一句唱到 9s、第二句 25s 开始(静默 16s ≥ 6s → 标);
    // 第二句唱到 26s、第三句 28s 开始(静默 2s → 不标)。
    let yrc = "[8000,1000](8000,500,0)aa (8500,500,0)bb \n"
        + "[25000,1000](25000,500,0)cc (25500,500,0)dd \n"
        + "[28000,1000](28000,500,0)ee (28500,500,0)ff \n"
    engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, preferWordLevel: true)
    expectEqual(engine.gapMarkers().map(\.index), [-1, 0],
                "间奏点: 前奏 + 第一句后各一个,静默太短的不标")
    expectEqual(engine.activeGapIndex(atMs: 3000), -1, "间奏点: 前奏进行中")
    expectEqual(engine.activeGapIndex(atMs: 8200), nil, "间奏点: 唱着的时候不算间奏(词尾余量)")
    expectEqual(engine.activeGapIndex(atMs: 15000), 0, "间奏点: 第一句唱完后的静默段")
    expectEqual(engine.activeGapIndex(atMs: 24700), nil, "间奏点: 下一句开始前 leadMs 先熄灭")
    // 行级 LRC 不知道一行唱多久:两句起点差 ≥15s 才标(宁可漏合,别在普通句间闪点)。
    let engine2 = LyricsSyncEngine()
    let lrc = "[00:01.00]aa\n[00:13.00]bb\n[00:40.00]cc\n"
    engine2.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: false)
    expectEqual(engine2.gapMarkers().map(\.index), [1], "间奏点(LRC): 只有 ≥15s 的起点差才标")
}

// ---- 滚动先于染色(2026-08-22,歌词窗口 AM 式提前滚动,tickQuery.scrollIndex) ----
do {
    // 同上面间奏点块的时间轴:前奏 8s(标 -1、窗口熄于 7200);第一句 8~9s 唱完,
    // 第二句 25s 开始(长间奏,标 0、窗口 10200~24200);第二句 25~26s 唱完,
    // 第三句 28s 开始(短间隙 2s,不标)。
    let engine = LyricsSyncEngine()
    let yrc = "[8000,1000](8000,500,0)aa (8500,500,0)bb \n"
        + "[25000,1000](25000,500,0)cc (25500,500,0)dd \n"
        + "[28000,1000](28000,500,0)ee (28500,500,0)ff \n"
    engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, preferWordLevel: true)
    expectEqual(engine.tickQuery(atMs: 3000).scrollIndex, nil, "提前滚动: 前奏「•••」亮着时还不滚第一句")
    expectEqual(engine.tickQuery(atMs: 7500).scrollIndex, 0, "提前滚动: 前奏收尾 leadMs 先把第一句挪到常规锚位")
    expectEqual(engine.tickQuery(atMs: 8500).scrollIndex, 0, "提前滚动: 唱着的时候滚动锚=当前行")
    expectEqual(engine.tickQuery(atMs: 15000).scrollIndex, 0, "提前滚动: 长间奏点亮期间滚动停在「•••」,锚不动")
    expectEqual(engine.tickQuery(atMs: 24500).scrollIndex, 1, "提前滚动: 长间奏收尾 leadMs 先滚向下一句")
    expectEqual(engine.tickQuery(atMs: 25500).scrollIndex, 1, "提前滚动: 第二句唱着时锚=第二句")
    expectEqual(engine.tickQuery(atMs: 26500).scrollIndex, 2, "提前滚动: 短间隙里一唱完就滚向下一句")
    expectEqual(engine.tickQuery(atMs: 26500).index, 1, "提前滚动: 同一时刻染色下标还停在唱完的那行")
    expectEqual(engine.tickQuery(atMs: 28500).scrollIndex, 2, "提前滚动: 最后一行没有下一句,锚=当前行")
    // 行级 LRC 不知道一行唱到几点,短间隙不抢跑(两个下标恒等,行为与改动前一致)。
    let engine2 = LyricsSyncEngine()
    let lrc = "[00:01.00]aa\n[00:05.00]bb\n"
    engine2.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: false)
    expectEqual(engine2.tickQuery(atMs: 3000).scrollIndex, 0, "提前滚动(LRC): 行级不知道唱完时刻,不抢跑")
    expectEqual(engine2.tickQuery(atMs: 3000).index, 0, "提前滚动(LRC): 两个下标一致")
}

// ---- LyricsSyncEngine: 单曲歌词时间轴微调(offsetMs) ----

do {
    let engine = LyricsSyncEngine()
    let lrc = "[00:10.00]第一句\n[00:20.00]第二句\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 15000)?.mainText, "第一句", "SyncEngine(offset): 校正前 15s 还是第一句")
    engine.offsetMs = 6000 // 提前 6 秒
    expectEqual(engine.activeLine(atMs: 15000)?.mainText, "第二句", "SyncEngine(offset): 提前 6s 后 15s 已经算第二句")
    engine.offsetMs = -6000 // 延后 6 秒
    expectEqual(engine.activeLine(atMs: 15000)?.mainText, nil, "SyncEngine(offset): 延后 6s 后 15s 还没到第一句")
}

// ---- LyricsSyncEngine: allLines()/activeLineIndex(atMs:) ("歌词窗口"用) ----

do {
    let engine = LyricsSyncEngine()
    let lrc = "[00:00.00]作词 : 甲\n[00:10.00]第一句\n[00:20.00]第二句\n[00:30.00]第三句\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    let lines = engine.allLines(idPrefix: "test")
    expectEqual(lines.count, 3, "SyncEngine.allLines: 署名行被过滤后只剩 3 条真歌词行")
    expectEqual(lines.map { $0.line.mainText }, ["第一句", "第二句", "第三句"], "SyncEngine.allLines: 行内容按时间顺序排列")
    expectEqual(lines.map(\.id), ["test#0", "test#1", "test#2"], "SyncEngine.allLines: id 按 idPrefix#下标 拼接")
}

// ---- Romanizer: 罗马音客户端兜底(服务端没给 lyrics_roma 时用系统 ICU 音译现算一份) ----

expectEqual(Romanizer.romanize(""), nil, "Romanizer: 空输入返回 nil")
expectEqual(Romanizer.romanize("hello"), nil, "Romanizer: 已经是拉丁字母,音译等于原文,不重复展示")
expectEqual(Romanizer.romanize("你好") != nil, true, "Romanizer: 中文输入应该能现算出一份跟原文不同的音译")

// 2026-08-04 实测排查坐实的真实 bug 的回归测试:汉字是中文/日文共用的文字系统,
// Romanizer.romanize 单靠"输出是否等于输入"分不清这两种语言,必须靠假名(日文独有、
// 中文完全没有)反过来判定——见 Romanizer.looksJapanese/containsHan 的定义处注释。
expectEqual(Romanizer.looksJapanese("你好"), false, "Romanizer.looksJapanese: 纯汉字没有假名,不是日文")
expectEqual(Romanizer.looksJapanese("こんにちは"), true, "Romanizer.looksJapanese: 平假名足以判定是日文")
expectEqual(Romanizer.looksJapanese("トマト"), true, "Romanizer.looksJapanese: 片假名同样判定是日文")
expectEqual(Romanizer.containsHan("你好"), true, "Romanizer.containsHan: 汉字判定为真")
expectEqual(Romanizer.containsHan("こんにちは"), false, "Romanizer.containsHan: 纯假名不含汉字")

do {
    // 纯中文歌曲(整首歌没有任何假名)不该被客户端兜底转成拼音展示——NetEase 本来就
    // 不给中文歌曲算 lyrics_roma,这是"不需要罗马音"的正确信号,兜底不该越权覆盖
    // (真实回归:方大同《叫我怎么说》这类纯中文歌曲曾经在悬浮窗/歌词窗口显示出一行
    // 拼音)。
    let engine = LyricsSyncEngine()
    let lrc = "[00:10.00]你好\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 10000)?.romanization, nil, "SyncEngine(罗马音兜底): 纯中文歌曲(没有假名)不该现算拼音")
}

do {
    // 日文歌曲(整首歌任意一行出现过假名"のの")里含汉字的其它行("早安")仍应正常
    // 触发兜底——songLooksJapanese 按整首歌判一次,不是逐行判,不会因为这一行本身
    // 没有假名就被误判成中文。
    let engine = LyricsSyncEngine()
    let lrc = "[00:05.00]のの\n[00:10.00]早安\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 10000)?.romanization != nil, true, "SyncEngine(罗马音兜底): 日文歌曲(含假名)的汉字行应该正常现算罗马音")
}

do {
    let engine = LyricsSyncEngine()
    let lrc = "[00:10.00]你好\n"
    // 服务端给了罗马音字段,但这一行本身在 700ms 容差内没匹配上——不应该在局部空档现算
    // 兜底,避免同一首歌一部分罗马音来自服务端、一部分是客户端现算,观感不一致。
    let roma = "[00:20.00]别的行的罗马音\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: roma, lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 10000)?.romanization, nil, "SyncEngine(罗马音兜底): 服务端提供了罗马音字段时,不在没匹配上的单行现算兜底")
}

// 副歌重复句:两处出现的歌词文字完全相同(常见于"副歌"),activeLineIndex 必须靠时间戳
// 扫下标区分是第几次出现——如果实现改成"拿 activeLine 的内容去 allLines 里找相同内容
// 的下标",遇到这种重复句会永远选中第一次出现,这个用例专门堵住这种回归。
do {
    let engine = LyricsSyncEngine()
    let lrc = "[00:10.00]副歌歌词\n[00:20.00]桥段歌词\n[00:30.00]副歌歌词\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLineIndex(atMs: 15000), 0, "SyncEngine.activeLineIndex: 第一次出现的副歌句命中下标 0")
    expectEqual(engine.activeLineIndex(atMs: 35000), 2, "SyncEngine.activeLineIndex: 第二次出现的副歌句命中下标 2(不是被内容匹配误判回 0)")
    expectEqual(engine.activeLineIndex(atMs: 5000), nil, "SyncEngine.activeLineIndex: 还没到第一句时是 nil")
}

do {
    let engine = LyricsSyncEngine()
    let yrc = "[10000,1000](10000,500,0)la (10500,500,0)la \n[20000,1000](20000,500,0)la (20500,500,0)la \n"
    engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, preferWordLevel: true)
    let lines = engine.allLines(idPrefix: "test")
    expectEqual(lines.count, 2, "SyncEngine.allLines(YRC): 逐字歌词也能拿到完整行列表")
    expectEqual(lines.map { $0.line.words?.map(\.text) }, [["la ", "la "], ["la ", "la "]], "SyncEngine.allLines(YRC): 每行的逐字词数组保留完整")
    expectEqual(engine.activeLineIndex(atMs: 20500), 1, "SyncEngine.activeLineIndex(YRC): 逐字歌词同样按时间戳扫下标")
}

// ---- LyricsSyncEngine: 热路径记忆化(2026-08-19 性能审计落地) ----
// activeLine/upcomingLineText 按行下标缓存构建结果(20Hz 的 fastTick 约 99% 的调用命中
// 同一行)。这里钉住两条不变量:①记忆化不改变语义 —— 行内反复查询、跨行、倒回都跟
// 无缓存时逐字一致;②load() 换歌词内容后缓存必须失效 —— 新歌同一个下标是完全不同的
// 内容,忘了失效会把上一首歌的行返回出去。

do {
    let engine = LyricsSyncEngine()
    let lrc = "[00:10.00]第一句\n[00:20.00]第二句\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 12000)?.mainText, "第一句", "SyncEngine(记忆化): 首次查询正常构建")
    expectEqual(engine.activeLine(atMs: 13000)?.mainText, "第一句", "SyncEngine(记忆化): 同一行内反复查询命中缓存,内容不变")
    expectEqual(engine.activeLine(atMs: 21000)?.mainText, "第二句", "SyncEngine(记忆化): 跨到下一行后缓存随下标失效")
    expectEqual(engine.activeLine(atMs: 5000)?.mainText, nil, "SyncEngine(记忆化): 倒回第一句之前(下标 -1)同样正确")
    expectEqual(engine.upcomingLineText(afterMs: 12000), "第二句", "SyncEngine(记忆化): 下一行预览正常")
    expectEqual(engine.upcomingLineText(afterMs: 21000), nil, "SyncEngine(记忆化): 最后一行之后没有下一句")
    expectEqual(engine.upcomingLineText(afterMs: 12000), "第二句", "SyncEngine(记忆化): 倒回后下一行缓存随下标失效")
}

do {
    let engine = LyricsSyncEngine()
    engine.load(lyrics: "[00:10.00]旧歌词\n", lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 15000)?.mainText, "旧歌词", "SyncEngine(记忆化): 换歌前正常")
    expectEqual(engine.upcomingLineText(afterMs: 5000), "旧歌词", "SyncEngine(记忆化): 换歌前下一行预览正常")
    engine.load(lyrics: "[00:10.00]新歌词\n", lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 15000)?.mainText, "新歌词", "SyncEngine(记忆化): load 换内容后同一下标的行缓存必须失效")
    expectEqual(engine.upcomingLineText(afterMs: 5000), "新歌词", "SyncEngine(记忆化): load 换内容后下一行缓存同样失效")
}

// ---- KaraokeFill.lineFillSettledMs: 整行填色定格时刻(悬浮歌词行尾停表用) ----
// 阈值 = startMs + 有效时长 × (1 + wordEdgeSoftenBand),整行取所有词/组的最大值。
// 词:(1000, 500) → 1000 + ceil(500×1.08) = 1540;极短词吃 minWordDurationMs(80)地板:
// (1000, 10) → 1000 + ceil(80×1.08) = 1087;逐词罗马音按整组伪词(跨度可能远大于单词)
// 填色,组也要算进最大值,否则罗马音还在填、行就被提前定格。

do {
    let w1 = SyncedLyricWord(text: "aa", startMs: 1000, durationMs: 500)
    let w2 = SyncedLyricWord(text: "bb", startMs: 1500, durationMs: 500)
    expectEqual(KaraokeFill.lineFillSettledMs(words: [w1], groups: nil), 1540,
                "lineFillSettledMs: 单词阈值 = start + 时长×(1+软化带)")
    expectEqual(KaraokeFill.lineFillSettledMs(words: [SyncedLyricWord(text: "a", startMs: 1000, durationMs: 10)], groups: nil), 1087,
                "lineFillSettledMs: 极短词按 minWordDurationMs 地板算")
    expectEqual(KaraokeFill.lineFillSettledMs(words: [w1, w2], groups: nil), 2040,
                "lineFillSettledMs: 整行取所有词的最大值")
    let group = SyncedLyricWordGroup(id: 0, words: [w1, w2], romanization: "aabb")
    expectEqual(KaraokeFill.lineFillSettledMs(words: [w1, w2], groups: [group]), 2080,
                "lineFillSettledMs: 整组伪词(跨度 1000)的阈值 2080 盖过词级最大值 2040")
}

// ---- LyricsOffsetStore: 校正值 key 要按"歌词内容"区分,不能只按歌手/歌名 ----

do {
    let keyA = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:10.00]第一句\n", lyricsYRC: "")
    let keyASame = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:10.00]第一句\n", lyricsYRC: "")
    let keyBDifferentLyrics = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:12.00]第一句(重新匹配的另一份歌词)\n", lyricsYRC: "")
    expectEqual(keyA, keyASame, "LyricsOffsetStore.trackKey: 同一首歌+同一份歌词内容,key 应该完全一致")
    expectEqual(keyA == keyBDifferentLyrics, false, "LyricsOffsetStore.trackKey: 同一首歌换了一份不同的歌词内容,key 应该不同")
}

// ---- 最近记录的封面兜底:合唱 credit 要能对上主歌手写法(2026-08-20) ----
//
// 同一次收听以两种歌手写法存在:本机缓存 key 用播放器的逐曲 credit(`英雄联盟/Sara Skinner`),
// Last.fm 那一行记主歌手(`英雄联盟`)。前两级查找(归一化 key 精确 / looseKey)都救不了 ——
// looseKey 只把分隔符变体折成 `&`,不会把合唱者去掉。下面这批是用户 2026-08-20 报的那一屏
// (英雄联盟原声带)里真实的 key 与真实的行,逐条从缓存里抄出来的。
do {
    typealias R = EnrichCacheReader
    let covers = [
        "Sebastien Najand/英雄联盟|PROJECT: Ashe|PROJECT: Ashe": "https://cover/ashe",
        "英雄联盟/Sara Skinner|Bring Home The Glory|Bring Home The Glory": "https://cover/glory",
        "英雄联盟/Against the Current|Legends Never Die|Legends Never Die": "https://cover/legends",
        "英雄联盟 & The Crystal Method|Senna, the Redeemer|Senna, the Redeemer": "https://cover/senna",
        "英雄联盟 & Mako & The Word Alive & The Glitch Mob|RISE|RISE": "https://cover/rise",
        "Edouard Brenneisen & 英雄联盟|Jhin, the Virtuoso|Jhin, the Virtuoso": "https://cover/jhin",
        // 对照:单人写法,本来就命中,这一级之前就该返回
        "Imagine Dragons|Warriors|Warriors (Official Anthem of League of Legends 2014 World Championship)": "https://cover/warriors",
        "英雄联盟|Aphelios, the Weapon of the Faithful|Aphelios, the Weapon of the Faithful": "https://cover/aphelios",
    ]
    let index = R.coverIndexByArtistTitle(covers)
    func cover(_ artist: String, _ title: String) -> String? {
        R.coverURLString(in: index, artist: artist, title: title)
    }
    // 截图里那 6 行(Last.fm 报的是主歌手写法)
    expectEqual(cover("Sebastien Najand", "PROJECT: Ashe"), "https://cover/ashe", "封面兜底: 斜杠合唱归主歌手")
    expectEqual(cover("英雄联盟", "Bring Home The Glory"), "https://cover/glory", "封面兜底: 主歌手在前的斜杠合唱")
    expectEqual(cover("英雄联盟", "Legends Never Die"), "https://cover/legends", "封面兜底: 同上,另一首")
    expectEqual(cover("英雄联盟", "Senna, the Redeemer"), "https://cover/senna", "封面兜底: & 号合唱")
    expectEqual(cover("英雄联盟", "RISE"), "https://cover/rise", "封面兜底: 四人 & 号合唱")
    // 大小写差异(行里是 The、缓存里是 the)由 artistTitleKey 折小写兜住
    expectEqual(cover("Edouard Brenneisen", "Jhin, The Virtuoso"), "https://cover/jhin", "封面兜底: 合唱 + 歌名大小写不一致")
    // 对照行不受影响
    expectEqual(cover("Imagine Dragons", "Warriors"), "https://cover/warriors", "封面兜底: 单人写法照旧命中")
    expectEqual(cover("英雄联盟", "Aphelios, the Weapon of the Faithful"), "https://cover/aphelios",
                "封面兜底: 单人写法照旧命中(同一个主歌手下的另一首)")
    // 反方向:行里是完整合唱写法、缓存里只有主歌手 —— 查询侧也归并一次
    let single = R.coverIndexByArtistTitle(["Daniel Caesar|Toronto 2014|NEVER ENOUGH": "https://cover/toronto"])
    expectEqual(R.coverURLString(in: single, artist: "Daniel Caesar & Mustafa", title: "Toronto 2014"),
                "https://cover/toronto", "封面兜底: 反方向(行是合唱、缓存是单人)也要命中")
    // 精确写法优先:别让合唱条目的图盖掉同名单人条目自己的图
    let both = R.coverIndexByArtistTitle([
        "英雄联盟|RISE|The Music of League of Legends": "https://cover/exact",
        "英雄联盟 & Mako|RISE|RISE": "https://cover/collab",
    ])
    expectEqual(R.coverURLString(in: both, artist: "英雄联盟", title: "RISE"), "https://cover/exact",
                "封面兜底: 精确歌手写法优先于合唱别名")
    // K/DA 那类名字自带斜杠的不能被劈开(mergeArtist 已有守卫,这里守住它别被绕过)
    let kda = R.coverIndexByArtistTitle(["K/DA|POP/STARS|POP/STARS": "https://cover/kda"])
    expectEqual(R.coverURLString(in: kda, artist: "K/DA", title: "POP/STARS"), "https://cover/kda",
                "封面兜底: K/DA 不会被斜杠劈成 K")
}

// ---- LyricsOffsetStore.trackKey:歌手/歌名必须归一化(2026-08-20 修的真 bug) ----
//
// 播放侧传播放器报的**原始**歌手/歌名,「歌词管理」传缓存 key 拆出来的(已归一化)那两段。
// trackKey 不自己归一化的话,同一首歌就有两个身份:在管理页敲的偏移播放时查不到、菜单栏
// 调的值在管理页看不见、「重置」也清不掉。实测这台机器 2483 首里 111 首(4.5%)落在这个
// 差异上 —— 全是歌名结尾带译名括号/`(with X)` 的那类。
do {
    let lrc = "[00:10.00]句\n"
    func key(_ artist: String, _ title: String) -> String {
        LyricsOffsetStore.trackKey(artist: artist, title: title, lyrics: lrc, lyricsYRC: "")
    }
    // 这一条就是 bug 本体:带译名括号的原始歌名 vs 缓存里那个剥过的歌名,必须同一个 key。
    expectEqual(key("丁世光", "不散的筵席（I Miss You）"), key("丁世光", "不散的筵席"),
                "trackKey: 结尾译名括号剥不剥都是同一首歌")
    expectEqual(key("Ari Lennox", "Queen Space (with Summer Walker)"), key("Ari Lennox", "Queen Space"),
                "trackKey: (with X) 同理")
    // 幂等:管理页传进来的本来就是归一化过的值,再过一遍不能变。
    expectEqual(key("丁世光", "不散的筵席"), key("丁世光", "不散的筵席"), "trackKey: 归一化是幂等的")
    // 版本标记不能剥 —— 那是另一个录音,合并了就是把两首不同的音频当成同一首。
    expectEqual(key("宇多田ヒカル", "Automatic (Remastered 2014)") == key("宇多田ヒカル", "Automatic"),
                false, "trackKey: (Remastered 2014) 是版本标记,不能剥")
    // 全角空格/零宽字符走 cleanTag,跟 enrich 缓存 key 同一套。
    expectEqual(key("Hikaru Utada", "Gold\u{3000}～また逢う日まで～"),
                key("Hikaru Utada", "Gold ～また逢う日まで～"),
                "trackKey: 全角空格折成普通空格")
}

// ---- 存量 key 搬迁:老记录留在旧形态下会永久查不到 ----
do {
    let fp = "abc123def456"
    let legacy = "丁世光|不散的筵席（I Miss You）|\(fp)"
    let canonical = "丁世光|不散的筵席|\(fp)"

    // 旧形态搬到新形态,值原样保留
    let moved = LyricsOffsetStore.migratedOffsetKeys([legacy: 1800])
    expectEqual(moved, [canonical: 1800], "key 搬迁: 旧形态被搬到归一化形态,值不变")

    // 已经是归一化形态的原样不动
    let untouched = LyricsOffsetStore.migratedOffsetKeys([canonical: 700])
    expectEqual(untouched, [canonical: 700], "key 搬迁: 已归一化的记录原样不动")

    // 撞车:两种拼法同时存在(指纹相同=同一份内容),让"本来就是归一化形态"那条赢 ——
    // 它是新形态下唯一查得到的身份,拿旧形态的值盖掉它等于把用户正在用的换成更旧的。
    let collided = LyricsOffsetStore.migratedOffsetKeys([legacy: 1800, canonical: 700])
    expectEqual(collided, [canonical: 700], "key 搬迁: 撞车时归一化形态那条胜出")

    // 段数不对的 key(不是这个仓库写出来的)原样保留,不猜
    let weird = LyricsOffsetStore.migratedOffsetKeys(["没有分隔符": 1, "只有一个|分隔符": 2])
    expectEqual(weird, ["没有分隔符": 1, "只有一个|分隔符": 2], "key 搬迁: 段数不对的 key 不动")

    // 空指纹段(歌词还没解析出来时调过偏移)也要能搬,不能崩
    let emptyFp = LyricsOffsetStore.migratedOffsetKeys(["丁世光|不散的筵席（I Miss You）|": 300])
    expectEqual(emptyFp, ["丁世光|不散的筵席|": 300], "key 搬迁: 指纹段为空也照搬")
}

// ---- MediaControlClient.ageCompensatedCachedElapsed: 借用后台 AppleScript 缓存 ----
// 快照前的年龄补偿+合理性核对(2026-08-04 实测排查坐实的回归:缓存值不补偿年龄直接
// 当"当前位置"用,本地整条展示链慢 ~1.8s,详见该函数注释)。

do {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    // 稳定播放:缓存读数 100.0s、1.8s 前抓的、速率 1 → 补偿到 101.8s;新鲜读数 101.9s,
    // 差 0.1s 在核对容差内 → 借用补偿后的值,而不是原始的 100.0。
    let steady = MediaControlClient.ageCompensatedCachedElapsed(
        cachedElapsed: 100.0, cachedPlaying: true, cachedRate: 1, cachedAt: t0,
        freshElapsed: 101.9, freshPlaying: true, now: t0.addingTimeInterval(1.8)
    )
    expectEqual(steady.map { abs($0 - 101.8) < 0.001 }, true, "ageCompensatedCachedElapsed: 稳定播放按读数年龄×速率补偿")
    // 单曲循环重启:缓存还是上一轮循环的位置(240s),真实已经回到 1.6s → 补偿后跟新鲜
    // 读数差 2s 以上,缓存不可信,返回 nil(调用方退回新鲜读数)。
    let loopRestart = MediaControlClient.ageCompensatedCachedElapsed(
        cachedElapsed: 240.0, cachedPlaying: true, cachedRate: 1, cachedAt: t0,
        freshElapsed: 1.6, freshPlaying: true, now: t0.addingTimeInterval(1.8)
    )
    expectEqual(loopRestart == nil, true, "ageCompensatedCachedElapsed: 单曲循环重启后过期缓存不借用")
    // 缓存是暂停态读数(刚恢复播放):这段年龄里位置没在走,没法按速率外推 → 不借用。
    let pausedCache = MediaControlClient.ageCompensatedCachedElapsed(
        cachedElapsed: 100.0, cachedPlaying: false, cachedRate: 0, cachedAt: t0,
        freshElapsed: 100.1, freshPlaying: true, now: t0.addingTimeInterval(1.8)
    )
    expectEqual(pausedCache == nil, true, "ageCompensatedCachedElapsed: 暂停态缓存读数不借用")
    // 切歌加载瞬间速率短暂报 0 但确实在播:按速率 1 计,跟 collector/lb.go 同一处理。
    let zeroRate = MediaControlClient.ageCompensatedCachedElapsed(
        cachedElapsed: 100.0, cachedPlaying: true, cachedRate: 0, cachedAt: t0,
        freshElapsed: 101.9, freshPlaying: true, now: t0.addingTimeInterval(1.8)
    )
    expectEqual(zeroRate.map { abs($0 - 101.8) < 0.001 }, true, "ageCompensatedCachedElapsed: 播放中速率报 0 按 1 计")
}

// ---- 歌词噪声过滤:日文标注 / 繁体自动识别 / 纯符号行 ----
// 2026-08-18 调研 LyricsX 的默认过滤表之后补的。它把繁简两种写法都手工列进表里(有「作詞」
// 也有「作词」,但「録音」就只列了简体),我们改成转孪生写法再比一次,表不必双写。
// 日文汉字标注(収録/主題歌/片頭曲)本地缓存里一条样本都没有,是照它那份真实数据提前补的坑。

do {
    // 日文源常见的头部标注(汉字形态)。
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("主題歌：LiSA"), true,
                "日文标注: 主題歌")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("片頭曲：藍井エイル"), true,
                "日文标注: 片頭曲")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("収録：ベストアルバム"), true,
                "日文标注: 収録")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("挿入歌：花澤香菜"), true,
                "日文标注: 挿入歌")
    // 繁体标签不再需要在表里双写一份 —— 靠 HanScript 转孪生写法比对。
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("作詞：林夕"), true,
                "繁体自动识别: 作詞(表里只有简体「作词」)")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("編曲：陳建騏"), true,
                "繁体自动识别: 編曲")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("錄音：李振權"), true,
                "繁体自动识别: 錄音")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("歌手：周杰伦"), true,
                "新增角色词: 歌手")
    // 反例:说话人标签仍然要豁免,别被新词带塌了。
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("他说：我不走"), false,
                "反例: 对白式冒号不是署名行")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("曲婉婷：好久不见"), false,
                "反例: 歌手名当说话人标签不是署名行")
}

do {
    // 整行只有符号:实测库里存在单独一行 `-`。
    expectEqual(LyricsSyncEngine.isSymbolOnlyLine("-"), true, "纯符号行: 单个连字符")
    expectEqual(LyricsSyncEngine.isSymbolOnlyLine("——"), true, "纯符号行: 破折号")
    expectEqual(LyricsSyncEngine.isSymbolOnlyLine("......"), true, "纯符号行: 省略号")
    expectEqual(LyricsSyncEngine.isSymbolOnlyLine("~ * ~"), true, "纯符号行: 混合符号")
    // 反例:括号里有字的**不能**当纯符号删 —— 库里 `(開心啊)` 是真歌词。
    expectEqual(LyricsSyncEngine.isSymbolOnlyLine("(開心啊)"), false,
                "纯符号行(反向): 括号里有字的是真歌词")
    expectEqual(LyricsSyncEngine.isSymbolOnlyLine("Oh"), false, "纯符号行(反向): 短英文语气词")
    expectEqual(LyricsSyncEngine.isSymbolOnlyLine(""), false, "纯符号行(反向): 空行不算")
}

// ---- 歌词噪声过滤:抬头 / 版权声明 / 新补角色词 ----
// 用例全部取自 2026-08-18 对用户真实缓存(490 首、29390 行)的全量扫描:改之前首/末行有
// 45 条抬头、10 条版权声明、5 条短标签冒号漏网,改之后分别剩 3 / 0 / 0,且 29390 行里零误伤。

do {
    // ① 简繁:本地标签是繁体,抬头写简体。
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine("小步舞曲 - 陈绮贞",
                trackTitle: "小步舞曲", trackArtist: "陳綺貞"), true,
                "抬头: 简繁不一致也要认出来")
    // ② 多歌手:标签用 & 拼接,抬头用 / 且每个名字后面夹着英文名 —— 整串拼起来连不成一段。
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine(
                "无所谓 (Explicit) - 方大同 (Khalil Fong)/张靓颖 (Jane Zhang)",
                trackTitle: "无所谓", trackArtist: "方大同 & 张靓颖"), true,
                "抬头: 多歌手且中间夹英文名")
    // ③ 标签里有抬头没写的合作者。
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine("电子羊 - 某幻君",
                trackTitle: "电子羊", trackArtist: "某幻君 & 王瀚哲 (中国BOY)"), true,
                "抬头: 标签比抬头多一个合作者")
    // ④ 双语歌名:标签是「日出 The Dawn」,抬头只写中文段。
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine("丁世光 - 日出",
                trackTitle: "日出 The Dawn", trackArtist: "丁世光"), true,
                "抬头: 双语歌名只写中文段")
    // ⑤ 短歌名走形状约束那条分支(歌名一两个字,长度下限挡不住它)。
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine("GF - 方大同",
                trackTitle: "GF", trackArtist: "方大同"), true, "抬头: 两字母短歌名")
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine("追 - 陶喆 (David Zee Tao)",
                trackTitle: "追", trackArtist: "陶喆"), true, "抬头: 单字歌名")
    // ⑥ 反序、无空格。
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine("陳柏宇-最後的擁抱",
                trackTitle: "最后的拥抱", trackArtist: "陈柏宇"), true,
                "抬头: 歌手在前、无空格、且繁体")
}

do {
    // 反向用例:这些**不能**被当成抬头删掉。
    // 真歌词里念自己名字(蛋堡《经典!》的实际歌词,库里存在)。
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine("新的经典 蛋堡 x Jabberloop",
                trackTitle: "经典!", trackArtist: "蛋堡"), false,
                "抬头(反向): 歌词里念自己名字不算抬头")
    // 第一句歌词恰好就是歌名 —— 缺歌手名,不该删(注释里原本就点明的场景)。
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine("First Love",
                trackTitle: "First Love", trackArtist: "宇多田ヒカル"), false,
                "抬头(反向): 只有歌名、没有歌手名")
    // 短歌名那条分支要求"整行就是两段",句中带连字符的真歌词不该命中。
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine("我 - 你 - 他都在等",
                trackTitle: "我", trackArtist: "某人"), false,
                "抬头(反向): 多个连字符不算两段形状")
}

do {
    // 版权/免责声明:没有冒号,所有"角色+冒号"规则都够不着,所以单独一条。
    expectEqual(LyricsSyncEngine.matchesCopyrightNotice("未经著作权人许可不得翻录翻唱或使用"),
                true, "版权声明: 郭顶整张专辑末行的实测形态")
    expectEqual(LyricsSyncEngine.matchesCopyrightNotice("未经著作权人许可 不得翻录翻唱或使用"),
                true, "版权声明: 中间带空格的变体")
    expectEqual(LyricsSyncEngine.matchesCopyrightNotice("（未经许可,不得翻唱或使用）"),
                true, "版权声明: 带括号的短变体")
    expectEqual(LyricsSyncEngine.matchesCopyrightNotice("All Rights Reserved"),
                true, "版权声明: 英文成句写法")
    // 反向:光有"未经"不够,必须成对出现法务词,否则真歌词会被吞。
    expectEqual(LyricsSyncEngine.matchesCopyrightNotice("未经允许的心动"), false,
                "版权声明(反向): 只有「未经」的真歌词不算")
    expectEqual(LyricsSyncEngine.matchesCopyrightNotice("我不得不承认"), false,
                "版权声明(反向): 只有「不得」的真歌词不算")
}

// ---- OverlayControlHitTest: 悬浮窗按钮的命中测试 ----
// (2026-08-18 结构性改动:悬浮窗改成常年 ignoresMouseEvents=true,胶囊上五个按钮的点击
// 由控制器拿全局鼠标监听的屏幕坐标比对矩形自己分发。这段判定是整条链路上唯一能脱离
// 窗口/事件系统单独验证的部分。)

do {
    // 按 HStack 排开的五个按钮:26/30/26 宽,间距 18,y 都一样。
    let rects: [OverlayControlID: CGRect] = [
        .previous: CGRect(x: 100, y: 200, width: 26, height: 26),
        .playPause: CGRect(x: 144, y: 198, width: 30, height: 30),
        .next: CGRect(x: 192, y: 200, width: 26, height: 26),
        .favorite: CGRect(x: 236, y: 200, width: 26, height: 26),
        .lock: CGRect(x: 299, y: 200, width: 26, height: 26),
    ]
    expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 113, y: 213), in: rects), .previous,
                "命中测试: 上一首中心")
    expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 159, y: 213), in: rects), .playPause,
                "命中测试: 播放/暂停中心")
    expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 311, y: 213), in: rects), .lock,
                "命中测试: 锁定中心")
    // 按钮之间的空隙(间距 18)不该命中任何一个 —— 否则点在缝里会误触发相邻按钮。
    expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 135, y: 213), in: rects) == nil, true,
                "命中测试: 两个按钮之间的空隙不命中")
    // 胶囊之外(比如歌词文字上)一律不命中 —— 那里要留给长按拖动。
    expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 400, y: 300), in: rects) == nil, true,
                "命中测试: 胶囊之外不命中")
    // 空表(控制排没显示)不命中 —— 控制器靠这个避免"看不见却挡手"。
    expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 113, y: 213), in: [:]) == nil, true,
                "命中测试: 没显示控制排时一个都不命中")
}

do {
    // 重叠时取面积最小的那个,而且结果必须**稳定** —— 字典遍历顺序不确定,"取第一个命中的"
    // 会让重叠情形随机命中,是最难查的一类 bug。跑多次断言结果一致。
    let overlapping: [OverlayControlID: CGRect] = [
        .previous: CGRect(x: 0, y: 0, width: 100, height: 100),
        .next: CGRect(x: 10, y: 10, width: 20, height: 20),
    ]
    var results = Set<OverlayControlID?>()
    for _ in 1...50 {
        results.insert(OverlayControlHitTest.control(at: CGPoint(x: 15, y: 15), in: overlapping))
    }
    expectEqual(results.count, 1, "命中测试: 重叠情形下结果必须稳定,不随字典顺序变")
    expectEqual(results.first ?? nil, .next, "命中测试: 重叠时命中面积更小的那个")
}

// ---- MediaControlClient.livePositionSeconds: rate 缺失时别信 elapsedTimeNow ----
// (2026-08-18 实测坐实:Spotify 暂停后恢复播放,上报的 playbackRate 变成 null,而
// media-control 的 --now 外推是 elapsed + (now-ts)*rate —— rate 缺失时增量为 0,
// elapsedTimeNow 15 秒纹丝不动。那个恒定值喂进伺服会把位置一路拽回去、歌词冻在一行。)

do {
    let ts = Date(timeIntervalSince1970: 1_000_000)
    // rate 正常:优先用 media-control 自己的外推(实测比自算准一个量级)。
    let healthy = MediaControlClient.livePositionSeconds(
        playing: true, elapsedTime: 170.866, elapsedTimeNow: 176.21,
        playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(6.0))
    expectEqual(healthy.map { ($0 * 100).rounded() / 100 }, 176.21,
                "livePositionSeconds: rate 正常时用 elapsedTimeNow")

    // rate 缺失(恢复播放后的实测形态):elapsedTimeNow 已经退化成 elapsedTime,
    // 必须自己按 rate=1 补算,否则位置恒定不动。
    let stalled = MediaControlClient.livePositionSeconds(
        playing: true, elapsedTime: 178.604, elapsedTimeNow: 178.604,
        playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(16.0))
    expectEqual(stalled.map { ($0 * 1000).rounded() / 1000 }, 194.604,
                "livePositionSeconds: rate 缺失时按墙钟自己补算,不能停在 178.604")

    // 同一份输入连采两次必须给出**不同**的位置 —— 这条才是这个 bug 的直接断言。
    let a = MediaControlClient.livePositionSeconds(
        playing: true, elapsedTime: 178.604, elapsedTimeNow: 178.604,
        playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(2))
    let b = MediaControlClient.livePositionSeconds(
        playing: true, elapsedTime: 178.604, elapsedTimeNow: 178.604,
        playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(15))
    expectEqual((a ?? 0) < (b ?? 0), true,
                "livePositionSeconds: rate 缺失时位置必须随时间前进(暂停后恢复的冻结 bug)")

    // 暂停态:elapsedTimeNow 在暂停期间照样涨(实测拿到过远超曲长的值),必须用原始 elapsedTime。
    let paused = MediaControlClient.livePositionSeconds(
        playing: false, elapsedTime: 104.948, elapsedTimeNow: 108.428,
        playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30))
    expectEqual(paused, 104.948, "livePositionSeconds: 暂停时用冻结的 elapsedTime,不外推")

    // ---- 整秒时间戳的相位订正(2026-08-21) ----
    //
    // 实测:media-control 的 timestamp 恒无小数秒,`ts = floor(真实时刻)`,于是
    // `位置 + (now − ts)` 恒偏快 frac 秒。用 Apple Music 的 AppleScript 播放头当独立真值
    // 采了 12 个样本:偏差 +0.824s、极差只有 0.042s —— 同一个锚点上稳如磐石(锚点冻结了
    // 51 秒没刷新,所以测到的就是这一个锚点的 frac)。
    //
    // 订正靠夹逼:τ ∈ [ts, min(ts+1, 首见时刻)],取中点。下面守的是这个式子的三条性质。
    do {
        let ts = Date(timeIntervalSince1970: 1_000_000)
        func est(_ gap: Double) -> Double {
            MC.estimatedAnchorInstant(timestamp: ts, firstSeenAt: ts.addingTimeInterval(gap))
                .timeIntervalSince(ts)
        }
        // 事件流即时发现:订正量 = 间隔的一半,很小
        // Date 走 Double 秒数(基准 1e6 量级),往返会掉有效位 —— 这几条按毫秒四舍五入再比,
        // 不是放宽要求,是别把浮点表示误差当成逻辑错。
        func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        expectEqual(ms(est(0.10)), 0.05, "相位订正: 即时发现时只订正间隔的一半")
        expectEqual(ms(est(0.90)), 0.45, "相位订正: 间隔 0.9 → 订正 0.45")
        // 只靠 2 秒轮询发现:间隔 ≥ 1 一律夹到 1(frac < 1),退化成 ts + 0.5
        expectEqual(est(1.00), 0.5, "相位订正: 间隔到 1 就夹住(frac 不可能 ≥ 1)")
        expectEqual(est(5.00), 0.5, "相位订正: 间隔再大也只到 ts+0.5,不会过冲")
        // 永远不会比现状(ts 本身)更差:订正量恒在 [0, 0.5]
        for gap in [0.01, 0.3, 0.7, 1.0, 2.0, 30.0] {
            let v = est(gap)
            expectEqual(v >= 0 && v <= 0.5, true, "相位订正: 订正量恒在 [0,0.5](间隔 \(gap))")
        }
        // 首见时刻早于时间戳(时钟回拨/解析异常)→ 不猜,原样返回
        expectEqual(MC.estimatedAnchorInstant(timestamp: ts, firstSeenAt: ts.addingTimeInterval(-3)),
                    ts, "相位订正: 首见早于时间戳时原样返回,不倒推")

        // 冻结锚点走自己的外推(订正后基准),不再用 media-control 那个偏快的 elapsedTimeNow
        let frozen = MC.livePositionSeconds(
            playing: true, elapsedTime: 100, elapsedTimeNow: 130.0,
            playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30),
            lastPlayingPosition: nil, firstSeenAt: ts.addingTimeInterval(0.4))
        // 订正后基准 = ts+0.2 → 位置 = 100 + (30 − 0.2) = 129.8(比 130 慢 0.2,正是订正量)
        expectEqual(frozen.map { (($0) * 1000).rounded() / 1000 }, 129.8,
                    "相位订正: 冻结锚点按订正后的基准自己外推")
        // 锚点还新鲜(age ≤ 门槛)→ 不接手,仍然用 elapsedTimeNow(QQ/网易云那条路不受影响)
        let fresh = MC.livePositionSeconds(
            playing: true, elapsedTime: 100, elapsedTimeNow: 100.9,
            playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(0.9),
            lastPlayingPosition: nil, firstSeenAt: ts.addingTimeInterval(0.2))
        expectEqual(fresh, 100.9, "相位订正: 锚点新鲜时不接手,行为跟改动前一致")
        // 不传 firstSeenAt(既有调用方)同样不接手
        let legacy = MC.livePositionSeconds(
            playing: true, elapsedTime: 100, elapsedTimeNow: 130.0,
            playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30))
        expectEqual(legacy, 130.0, "相位订正: 不传首见时刻时行为跟改动前逐字相同")
    }

    // ---- 锚点冻结的源:暂停时不能回退到那个恒为 0 的 elapsedTime(2026-08-21) ----
    //
    // 2026-08-21 用户报「用 Arc 播放音乐歌词进度慢」时查出来的连带 bug。Arc 这类网页播放器
    // (页面没调 mediaSession.setPositionState)实测 elapsedTime 恒 0、timestamp 恒为开播
    // 那一刻,于是"暂停时用原始 elapsedTime"这条既有规则会让位置**直接归零** —— 用户视角
    // 是"在浏览器里一按暂停,歌词跳回第一句"。
    typealias MC = MediaControlClient
    // ① Arc 形态:锚点 187 秒没刷新 + 报告值 0 → 用播放中最后一次位置
    expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: 187, lastPlayingPosition: 187),
                187, "暂停位置: 锚点冻结的源用最后已知位置,不归零")
    // ② 会刷新锚点的源:时间戳新鲜 → 原样用报告值,哪怕它比最后位置低得多
    //    (向后 seek 之后暂停就是这个形状,这一条保住它不被误改)
    expectEqual(MC.pausedPositionSeconds(elapsedTime: 12, anchorAge: 0.3, lastPlayingPosition: 100),
                12, "暂停位置: 锚点新鲜时原样用报告值(向后 seek 后暂停)")
    // ③ 正常暂停:两者只差一拍
    expectEqual(MC.pausedPositionSeconds(elapsedTime: 99, anchorAge: 30, lastPlayingPosition: 100),
                99, "暂停位置: 只差一拍不算冻结")
    // ④⑤ 缺输入时一律原样,不猜
    expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: 999, lastPlayingPosition: nil),
                0, "暂停位置: 没有最后位置时原样返回")
    expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: nil, lastPlayingPosition: 187),
                0, "暂停位置: 拿不到锚点年龄时原样返回")
    // ⑥⑦ 两个门槛的边界都是"等于不算"
    expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: MC.staleAnchorAfter,
                                         lastPlayingPosition: 187),
                0, "暂停位置: 年龄等于门槛不算陈旧")
    expectEqual(MC.pausedPositionSeconds(elapsedTime: 100, anchorAge: 60,
                                         lastPlayingPosition: 100 + MC.frozenAnchorPauseDrop),
                100, "暂停位置: 跌幅等于门槛不算冻结")
    // ⑧ 既有行为不变:不传 lastPlayingPosition 时 livePositionSeconds 跟改动前逐字相同
    expectEqual(MC.livePositionSeconds(playing: false, elapsedTime: 104.948, elapsedTimeNow: 999,
                                       playbackRate: 1, timestamp: nil, now: Date()),
                104.948, "暂停位置: 不传最后位置时行为跟改动前一致")

    // rate 为 0 跟缺失同义(media-control 恢复播放后也报过 0)。
    let zeroRate = MediaControlClient.livePositionSeconds(
        playing: true, elapsedTime: 10, elapsedTimeNow: 10,
        playbackRate: 0, timestamp: ts, now: ts.addingTimeInterval(5))
    expectEqual(zeroRate, 15, "livePositionSeconds: rate=0 与缺失同义,同样自己补算")

    // 时钟回拨/时间戳解析异常时不倒推。
    let backwards = MediaControlClient.livePositionSeconds(
        playing: true, elapsedTime: 50, elapsedTimeNow: 50,
        playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(-10))
    expectEqual(backwards, 50, "livePositionSeconds: 时间戳在未来时不倒推位置")
}

do {
    // timestamp 解析:media-control 实测给不带小数秒的 Z 形式,也要兼容带小数秒的。
    expectEqual(MediaControlClient.parseTimestamp("2026-08-18T08:51:46Z") != nil, true,
                "parseTimestamp: 不带小数秒的 ISO8601 能解")
    expectEqual(MediaControlClient.parseTimestamp("2026-08-18T08:51:46.123Z") != nil, true,
                "parseTimestamp: 带小数秒的 ISO8601 能解")
    expectEqual(MediaControlClient.parseTimestamp(nil) == nil, true,
                "parseTimestamp: nil 进 nil 出")
}

// ---- LocalPlaybackSource.servoDecision: 播放位置外推的"锁死偏差"伺服校正 ----
// (2026-08-04 实测排查坐实:稳定播放分支只按墙钟外推、不回看真实读数,播种偏差/漏观察
// 的短暂停会造成小于 seek 容差的永久锁死,详见该函数注释。)

do {
    // 精确源(Apple Music):持续 1.2s 的锁死偏差(漏观察的短暂停)应在几轮内触发校正。
    var ema = 0.0
    var snapped = false
    var rounds = 0
    for _ in 1...5 {
        rounds += 1
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: -1.2, tier: .precise)
        ema = newEMA
        if snap { snapped = true; break }
    }
    expectEqual(snapped, true, "servoDecision(精确源): 持续 1.2s 偏差应触发校正")
    expectEqual(rounds <= 3, true, "servoDecision(精确源): 校正应在 3 轮(6 秒)内发生,实际 \(rounds) 轮")
}

do {
    // 精确源:实测抓到的那次 0.205s 启动播种偏差,同样应该被修正(原实现会永久锁死)。
    var ema = 0.0
    var snapped = false
    for _ in 1...10 {
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: 0.205, tier: .precise)
        ema = newEMA
        if snap { snapped = true; break }
    }
    expectEqual(snapped, true, "servoDecision(精确源): 0.205s 的播种偏差(实测案例)应被校正")
}

do {
    // 精确源:±0.06s 的正常读数噪声(零均值)不该误触发校正。
    var ema = 0.0
    var falseSnap = false
    for i in 1...50 {
        let err = i % 2 == 0 ? 0.06 : -0.06
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, tier: .precise)
        ema = newEMA
        if snap { falseSnap = true; break }
    }
    expectEqual(falseSnap, false, "servoDecision(精确源): ±0.06s 零均值噪声不该误触发")
}

do {
    // 噪声源(QQ 音乐):±1.5s 的零均值抖动不该误触发校正——这正是原来"只按墙钟外推"
    // 设计要防的场景,伺服不能把它破坏掉。
    var ema = 0.0
    var falseSnap = false
    for i in 1...50 {
        let err = i % 2 == 0 ? 1.5 : -1.5
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, tier: .noisyFloored)
        ema = newEMA
        if snap { falseSnap = true; break }
    }
    expectEqual(falseSnap, false, "servoDecision(噪声源): ±1.5s 零均值抖动不该误触发")
}

do {
    // 噪声源:持续 +1.5s 的真锁死偏差(低于 2s seek 容差,原来永远修不掉)应该能修正。
    var ema = 0.0
    var snapped = false
    for _ in 1...10 {
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: 1.5, tier: .noisyFloored)
        ema = newEMA
        if snap { snapped = true; break }
    }
    expectEqual(snapped, true, "servoDecision(噪声源): 持续 1.5s 锁死偏差应最终被校正")
}

// ---- servoDecision 第三档:Spotify(cleanExtrapolated,2026-08-18 拆档) ----
//
// 背景(实测 140+ 样本):Spotify 的 elapsedTimeNow 稳态偏差 ±0.05s、比 QQ 音乐干净
// 一个量级,但换歌头几秒 MediaRemote 报数是脏的(最高 +1.32s)。播种进 <1.0s 的超前值
// 后,老的 noisyFloored 1.0s 门槛让它整曲不被纠正——"Spotify 歌词经常偏快"的主因。
do {
    // 换歌脏窗口播种 +0.8s 超前(老门槛下整曲锁死)——应在 3 轮(~6 秒)内校正。
    var ema = 0.0
    var snapped = false
    var rounds = 0
    for _ in 1...5 {
        rounds += 1
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: -0.8, tier: .cleanExtrapolated)
        ema = newEMA
        if snap { snapped = true; break }
    }
    expectEqual(snapped, true, "servoDecision(Spotify): 0.8s 播种超前应触发校正")
    expectEqual(rounds <= 3, true, "servoDecision(Spotify): 校正应在 3 轮内发生,实际 \(rounds) 轮")
}

do {
    // 暂停/切换瞬间的单发陈旧读数(实测 -1.27s)不该触发回跳——EMA 只到 -0.38,低于门槛。
    let (ema1, snap1) = LocalPlaybackSource.servoDecision(errEMA: 0, error: -1.27, tier: .cleanExtrapolated)
    expectEqual(snap1, false, "servoDecision(Spotify): 单发 -1.27s 陈旧读数不回跳")
    // 下一轮恢复干净读数,EMA 衰减、依旧不触发。
    let (_, snap2) = LocalPlaybackSource.servoDecision(errEMA: ema1, error: -0.05, tier: .cleanExtrapolated)
    expectEqual(snap2, false, "servoDecision(Spotify): 陈旧读数后一轮即衰减不触发")
}

do {
    // 稳态 ±0.05s 抖动(实测量级)绝不该误触发。
    var ema = 0.0
    var falseSnap = false
    for i in 1...50 {
        let err = i % 2 == 0 ? 0.05 : -0.05
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, tier: .cleanExtrapolated)
        ema = newEMA
        if snap { falseSnap = true; break }
    }
    expectEqual(falseSnap, false, "servoDecision(Spotify): ±0.05s 稳态抖动不误触发")
}

// ---- 自然切歌锚点超前校正(2026-08-20):Spotify gapless 整曲偏快的根修 ----
//
// 实测(Forever Love→在那遙遠的地方,0.25s 采样):自然切歌时元数据/新锚点先于真声
// 0.837s 打好,整曲 elapsedTimeNow 恒定超前 +0.888s±0.009 且锚点从不重打——伺服对
// "每笔读数与外推步调一致的常量偏置"结构性失明,必须在换歌那拍用旧曲连续外推当真值
// 把偏置量出来、之后逐笔扣除。机制详见 LocalPlaybackSource.naturalAdvanceCorrection。
do {
    // 实测样本:首笔原始读数 0.048、旧曲连续外推越界 -0.837(真声还剩 0.837s)。
    let corr = LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.048, overrun: -0.837)
    expectEqual(corr != nil, true, "naturalAdvance: 实测切歌样本应被校正")
    if let corr {
        expectEqual(abs(corr.seed - (-0.837)) < 1e-9, true, "naturalAdvance: 播种=越界量(允许为负,UI 钳 0 等真声)")
        expectEqual(abs(corr.bias - 0.885) < 1e-9, true, "naturalAdvance: 偏置=读数-越界量")
    }
}

do {
    // 元数据晚于真声切换(越界为正):真值=越界量,同样成立。
    let corr = LocalPlaybackSource.naturalAdvanceCorrection(reported: 1.5, overrun: 0.6)
    expectEqual(corr?.seed == 0.6 && corr?.bias == 0.9, true, "naturalAdvance: 晚切元数据也按连续性播种")
}

do {
    // 四类不校正:手动跳歌(窗口外)/噪声级偏置/陈旧读数(08-18 实测换歌瞬间还挂上一首的
    // 30.3)/负偏置(模型外)。返回 nil = 按原逻辑采信读数(改动前行为)。
    expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.3, overrun: -188) == nil, true, "naturalAdvance: 手动跳歌不校正")
    expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.3, overrun: 0.28) == nil, true, "naturalAdvance: 噪声级偏置不校正")
    expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 30.3, overrun: -0.5) == nil, true, "naturalAdvance: 陈旧首笔读数不校正")
    expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.1, overrun: 0.9) == nil, true, "naturalAdvance: 负偏置不校正")
}

do {
    // 误判伤害上限:偏置守卫把"手动跳歌恰好发生在结尾窗口内"的错误校正钉死在 ≤2.5s。
    let corr = LocalPlaybackSource.naturalAdvanceCorrection(reported: 3.2, overrun: 0.2)
    expectEqual(corr == nil, true, "naturalAdvance: 超过 \(LocalPlaybackSource.naturalAdvanceMaxBiasSecs)s 的偏置不采信")
}

// ---- 冻结守卫(2026-08-18):曲目/广告结尾 Spotify 锚点冻住 ----
//
// 实测(边界探针):广告结尾 elapsedTimeNow 卡死 6 秒,真声一路走到落后 8 秒。不拦的话
// 冻结值几秒后超过 2s seek 容差,位置被"重锚"回冻结值,歌尾歌词整段倒回去 —— 用户报
// "自动切歌之后变慢"的主要成分。
do {
    typealias L = LocalPlaybackSource
    expectEqual(L.isFrozenReport(reportedAdvance: 0.0, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                true, "冻结守卫: 报告值 2 秒没动判冻结")
    expectEqual(L.isFrozenReport(reportedAdvance: 2.0, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                false, "冻结守卫: 正常推进不误判")
    expectEqual(L.isFrozenReport(reportedAdvance: -8.0, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                false, "冻结守卫: 向后 seek 是大负数,不误判(判的是几乎没动)")
    expectEqual(L.isFrozenReport(reportedAdvance: 8.2, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                false, "冻结守卫: 解冻大步前跳不拦,落回 seek 分支瞬间追上")
    expectEqual(L.isFrozenReport(reportedAdvance: 0.02, gap: 0.3, rate: 1, tier: .cleanExtrapolated),
                false, "冻结守卫: 事件触发的短间隔补查不判(正常前进量也接近 0)")
    expectEqual(L.isFrozenReport(reportedAdvance: 0.0, gap: 2.0, rate: 1, tier: .noisyFloored),
                false, "冻结守卫: QQ/网易云档不启用")
    // 冻结的**第一拍**检测还认不出(只有一次大负偏差),靠单样本限幅兜住:
    // 0.3×(-1.74) = -0.52 本会冲过 0.4 门槛把歌词拖回半秒,限幅后只到 -0.225。
    let (_, snap) = L.servoDecision(errEMA: 0, error: -1.74, tier: .cleanExtrapolated)
    expectEqual(snap, false, "冻结守卫: 第一拍大负偏差被限幅拦住,不回拖")
}

// ---- bundleID → 数据源档位映射 ----
do {
    typealias L = LocalPlaybackSource
    expectEqual(L.positionSourceTier(forBundleID: "com.apple.Music") == .precise, true,
                "档位映射: Apple Music → precise")
    expectEqual(L.positionSourceTier(forBundleID: "com.spotify.client") == .cleanExtrapolated, true,
                "档位映射: Spotify → cleanExtrapolated")
    expectEqual(L.positionSourceTier(forBundleID: "com.tencent.QQMusicMac") == .noisyFloored, true,
                "档位映射: QQ 音乐 → noisyFloored")
    expectEqual(L.positionSourceTier(forBundleID: "com.netease.163music") == .noisyFloored, true,
                "档位映射: 网易云 → noisyFloored")
    // 酷狗归 cleanExtrapolated 是实测定的:它播放期间不刷新锚点,位置全靠墙钟外推,
    // 23 秒累计偏差 +0.0011s、小数位完全连续(不是 QQ 那种整秒下取整)。归错档会给它
    // 挂上前向棘轮,而棘轮的前提对纯外推源不成立。
    expectEqual(L.positionSourceTier(forBundleID: "com.kugou.mac.Music") == .cleanExtrapolated, true,
                "档位映射: 酷狗 → cleanExtrapolated(2026-08-21 实测:纯外推、无量化)")
    expectEqual(L.shouldRatchetForward(reported: 10, predicted: 5, tier: .cleanExtrapolated), false,
                "档位映射: 酷狗这一档不吃前向棘轮")
    // 2026-08-21 翻了默认档:noisyFloored 的两样东西(1.0s 大门槛 + 前向棘轮)只对**整秒
    // 量化**的源成立(棘轮前提是"报告值 ≤ 真实位置"),而实测所有走 media-control 的源都是
    // 纯外推、无量化(酷狗 23 秒累计偏差 +0.0011s;Arc 小数位完全连续)。所以量化源是少数派,
    // 显式登记它们、其余走 cleanExtrapolated。nil 也走这一档:"保守"应该是"别用前提不成立
    // 的棘轮",不是"选门槛最大的那一档"。
    expectEqual(L.positionSourceTier(forBundleID: nil) == .cleanExtrapolated, true,
                "档位映射: 没有来源信息时归 cleanExtrapolated(不套前提不成立的棘轮)")
    expectEqual(L.positionSourceTier(forBundleID: "company.thebrowser.Browser") == .cleanExtrapolated,
                true, "档位映射: 信任的未知 App(实测纯外推)归 cleanExtrapolated")
    expectEqual(L.shouldRatchetForward(reported: 10, predicted: 5,
                                       tier: L.positionSourceTier(forBundleID: "company.thebrowser.Browser")),
                false, "档位映射: 未知源不吃前向棘轮")
}

// ---- EnrichCacheKeys: 缓存 key ↔ lyrics/ 导出文件名(2026-08-05) ----
//
// 2026-08-05 实测排查坐实的真实 bug 的回归测试:collector 会给"sanitize 出来的文件名只差
// 大小写"的碰撞组成员改用带 crc32 后缀的文件名(lyricsexport.go:105-141),而 Swift 侧原来
// 一律只认普通名——删除时漏删 → collector 重启后 importLyricsFromFiles 从残留文件把条目
// 复活(本机 852 条里 219 条命中,占 25.7%);保存修改时写出普通名 → 同一个 key 对应两组
// 文件、导入时各写一次、生效哪份取决于 Go map 的随机遍历顺序。
// crc32 必须跟 Go 的 hash/crc32.ChecksumIEEE 逐位一致,否则算出来的文件名对不上。

do {
    // 公认的 CRC-32(IEEE) 标准向量,锁死查表实现本身。
    expectEqual(EnrichCacheKeys.crc32IEEE(""), UInt32(0), "EnrichCacheKeys: crc32 空串标准向量")
    expectEqual(EnrichCacheKeys.crc32IEEE("123456789"), UInt32(0xCBF4_3926), "EnrichCacheKeys: crc32 \"123456789\" 标准向量")
    expectEqual(EnrichCacheKeys.crc32IEEE("a"), UInt32(0xE8B7_BE43), "EnrichCacheKeys: crc32 \"a\" 标准向量")

    // 从本机磁盘上真实存在的两个碰撞文件反推出来的用例(同一首歌只差 feat./Feat. 一个
    // 字母大小写,两条 key 都真的在缓存里)——这两条锁死的是"Swift 算出来的文件名跟
    // collector 实际写在磁盘上的那个一模一样"。
    expectEqual(
        EnrichCacheKeys.disambiguatedName(forKey: "方大同|张永成 (feat. Ghost Style)|15"),
        "方大同 - 张永成 (feat. Ghost Style) - 15~00fad0",
        "EnrichCacheKeys: 消歧文件名跟磁盘上真实文件一致(小写 feat.)"
    )
    expectEqual(
        EnrichCacheKeys.disambiguatedName(forKey: "方大同|张永成 (Feat. Ghost Style)|15"),
        "方大同 - 张永成 (Feat. Ghost Style) - 15~c8df08",
        "EnrichCacheKeys: 同一首歌大小写不同的另一条 key 落在不同文件名"
    )
}

do {
    // "|" 换成 " - ",文件系统不安全字符转下划线,跟 collector/lyricsexport.go 的
    // sanitizeLyricsFilename 对齐。
    expectEqual(EnrichCacheKeys.sanitizeFilename("Artist|Song|Album"), "Artist - Song - Album", "EnrichCacheKeys: 「|」换成「 - 」")
    expectEqual(EnrichCacheKeys.sanitizeFilename("A/B|C:D|E*F?"), "A_B - C_D - E_F_", "EnrichCacheKeys: 不安全字符转下划线")

    // 删除必须把两种形态各 4 个后缀全试一遍——漏掉带后缀那 4 个就是上面说的复活 bug。
    let names = EnrichCacheKeys.exportedFileNames(forKey: "Artist|Song|Album")
    expectEqual(names.count, 8, "EnrichCacheKeys: 待删文件名 = 普通名4个 + 消歧名4个")
    expectEqual(names[0], "Artist - Song - Album.lrc", "EnrichCacheKeys: 普通名第一个是 .lrc")
    expectEqual(names[3], "Artist - Song - Album.yrc", "EnrichCacheKeys: 普通名第四个是 .yrc")
    expectEqual(
        names[4], "Artist - Song - Album~\(String(format: "%06x", EnrichCacheKeys.crc32IEEE("Artist|Song|Album") & 0xFF_FFFF)).lrc",
        "EnrichCacheKeys: 第五个开始是带消歧后缀的同族文件"
    )
    // 普通名恰好是消歧名的前缀,所以任何"按前缀筛"的写法都会出错——这条锁死这个陷阱。
    expectEqual(names[4].hasPrefix("Artist - Song - Album"), true, "EnrichCacheKeys: 消歧名以普通名开头(禁止用 hasPrefix 区分两种形态)")
}

do {
    // 选中集合 → 实际删除计划:交集 + 排序。
    let existing: Set<String> = ["B|b|al2", "A|a|al1", "C|c|al3"]
    expectEqual(
        EnrichCacheKeys.deletionPlan(selected: ["A|a|al1", "已经没了|x|y"], existing: existing),
        ["A|a|al1"],
        "EnrichCacheKeys: 选中集合里已失效的 key 被剔除"
    )
    expectEqual(EnrichCacheKeys.deletionPlan(selected: [], existing: existing), [], "EnrichCacheKeys: 空选中集合不产生删除")
    expectEqual(
        EnrichCacheKeys.deletionPlan(selected: existing, existing: existing),
        ["A|a|al1", "B|b|al2", "C|c|al3"],
        "EnrichCacheKeys: 全选时按 key 排序返回,顺序稳定可复现"
    )
    expectEqual(
        EnrichCacheKeys.deletionPlan(selected: ["X|x|x"], existing: existing), [],
        "EnrichCacheKeys: 全部失效时删除计划为空(调用方据此直接返回,不做空写盘)"
    )
}

// ---- LyricDuet: 对唱歌词的左右分栏(2026-08-14) ----
//
// 用例全部照真实数据写:演唱者信息是**塞在正文里的前缀**(男：/女：/合：),而且只有部分行
// 带标记(《真爱等一下 (feat. 蔡健雅)》65 行里 22 行),其余按"一个标记管到下一个标记"延续。
do {
    let D = LyricDuet.self

    // ---- splitLabel: 只认形状,不判断这个标签是不是演唱者 ----
    expectEqual(D.splitLabel("男：周末守着烤箱")?.label, "男", "对唱: 全角冒号识别")
    expectEqual(D.splitLabel("男：周末守着烤箱")?.rest, "周末守着烤箱", "对唱: 前缀从正文里剥掉")
    expectEqual(D.splitLabel("女: 偏爱年轻女伴")?.rest, "偏爱年轻女伴", "对唱: 半角冒号+空格")
    expectEqual(D.splitLabel("合：何时想戒掉流浪")?.label, "合", "对唱: 合唱标记")
    expectEqual(D.splitLabel("男声：测试")?.rest, "测试", "对唱: 标签整段取到冒号(男声 不是 男+声)")
    expectEqual(D.splitLabel("情人节也落单") == nil, true, "对唱: 无冒号的行没有标签")
    // 标签里不许有空白/标点 —— 这是"标签"跟"带冒号的歌词句子"唯一的形状差别
    expectEqual(D.splitLabel("Baby, I said: hello") == nil, true, "对唱: 含标点的长句不是标签")
    expectEqual(D.splitLabel("Chris Tucker: Oh man") == nil, true, "对唱: 含空格的全名不当标签(已知取舍)")
    expectEqual(D.splitLabel("一二三四五六七八九十一：x") == nil, true, "对唱: 标签超过 10 字不认")
    // prefixCount 以**原串**为准(逐字路径按它跨词剥),含冒号和冒号后的空格
    expectEqual(D.splitLabel("男：周末")?.prefixCount, 2, "对唱: prefixCount 含冒号")
    expectEqual(D.splitLabel("女: 偏爱")?.prefixCount, 3, "对唱: prefixCount 含冒号后空格")

    // ---- speakers(in:): 整份判定,已知声部词直通、人名要过闸 ----
    // 已知声部词单独出现就算数
    expectEqual(D.speakers(in: ["男：一", "女：二"]), Set(["男", "女"]), "对唱: 男/女 直接算演唱者")
    // 署名行不算 —— 「词/曲」既不是已知声部词,也过不了下面那道闸
    expectEqual(D.speakers(in: ["词：葛大为", "曲：陶喆/蔡健雅", "真歌词"]).isEmpty, true,
                "对唱: 一次性的署名标签不算演唱者")
    // 人名标记:≥2 个不同 + 合计 ≥3 处 + 至少一个重复,三条都满足才算
    do {
        // 《圣诞星》的真实形态:周杰伦 x2 + 杨瑞代 x1
        let s = D.speakers(in: ["周杰伦：", "一", "杨瑞代：", "二", "周杰伦：", "三"])
        expectEqual(s, Set(["周杰伦", "杨瑞代"]), "对唱: 人名标记过闸(2 个/3 处/有重复)")
    }
    do {
        // 《好走不见》的真实形态:Rap x1 + Rap2 x1 —— 段落标记,只有 2 处,不该算
        let s = D.speakers(in: ["Rap：", "一", "Rap2：", "二"])
        expectEqual(s.isEmpty, true, "对唱: 只有 2 处的一次性标记不算")
    }
    do {
        // 《红尘客栈》的真实形态:5 个标签各 1 次 —— 职员表,每个角色只出现一次
        let s = D.speakers(in: ["执行制作：甲", "录音师：乙", "混音师：丙", "录音室：丁", "混音室：戊", "歌词"])
        expectEqual(s.isEmpty, true, "对唱: 都不重复的多标签是职员表,不是对唱")
    }
    do {
        // 《Wonderful Tonight》译文的真实形态:「我说」x3 +「然后她问我」x2 —— 计数够,
        // 但它们是叙事句不是名字,靠 nonNameCharacters 挡住
        let s = D.speakers(in: ["我说：是的", "然后她问我：好吗", "我说：好", "然后她问我：真的", "我说：真的"])
        expectEqual(s.isEmpty, true, "对唱: 含代词/动词的叙事标签不是演唱者")
    }
    do {
        // 漏网的乐器署名:计数可能凑够,但词根挡住
        let s = D.speakers(in: ["小号：涂", "小打击乐器组：Joni", "小号：涂"])
        expectEqual(s.isEmpty, true, "对唱: 乐器/职能词根不是演唱者")
    }
    do {
        // 串烧 Live 的真实形态(《大笨钟+暗号+彩虹+龙卷风 (Live)》):每首各带一份署名,
        // 于是「词」x4「曲」x4 —— 计数三条全过,只能靠 exactCreditLabels 在形状这层拦。
        // 这条是回归护栏:2026-08-23 第一版漏了单字署名词,全库扫描当场抓到两首串烧被误判。
        let s = D.speakers(in: [
            "词：方文山", "曲：周杰伦", "歌词一",
            "词：方文山", "曲：周杰伦", "歌词二",
            "词：黄俊郎", "曲：周杰伦", "歌词三",
            "词：方文山", "曲：周杰伦", "歌词四",
        ])
        expectEqual(s.isEmpty, true, "对唱: 串烧 Live 里重复出现的单字署名词不是演唱者")
    }
    do {
        // 反例:单字署名词只能**等值**排除 ——「曲」是姓,「曲婉婷」得照样认出来
        let s = D.speakers(in: ["曲婉婷：一", "李健：二", "曲婉婷：三"])
        expectEqual(s, Set(["曲婉婷", "李健"]), "对唱: 姓「曲」的人名不被单字署名词误杀")
    }
    do {
        // 整份闸是全份一起过的:真演唱者把门槛顶开之后,同一份里的署名残余不能跟着被收编。
        // 收编 = 拿到署名过滤豁免 = 那行既不被删、又被剥掉前缀,变成一行假歌词「某某」。
        // 2026-08-23 审查发现的活回归,回归护栏。
        let s = D.speakers(in: [
            "周杰伦：", "一", "阿信：", "二", "周杰伦：", "三",
            "和声：陈某某", "监制：李某某", "母带处理：王某某",
        ])
        expectEqual(s, Set(["周杰伦", "阿信"]),
                    "对唱: 真演唱者顶开门槛后,同份里的署名残余不被连带收编")
    }

    // 标记向后延续 + 按出现顺序分左右(不写死性别)
    do {
        let markers: [String?] = [nil, "男", nil, nil, "女", nil, "合", nil, "男"]
        let sides = D.sides(for: markers)
        expectEqual(sides[0], nil, "对唱: 第一个标记之前没有对唱信息(不是靠左)")
        expectEqual(sides[1], .leading, "对唱: 先出现的那位靠左")
        expectEqual(sides[2], .leading, "对唱: 标记向后延续")
        expectEqual(sides[3], .leading, "对唱: 标记继续延续")
        expectEqual(sides[4], .trailing, "对唱: 第二位靠右")
        expectEqual(sides[5], .trailing, "对唱: 第二位的延续")
        expectEqual(sides[6], .center, "对唱: 合唱居中")
        expectEqual(sides[7], .center, "对唱: 合唱也向后延续")
        expectEqual(sides[8], .leading, "对唱: 回到第一位仍然靠左")
    }
    // 女声先开口的歌:靠左的是**她**,不是按性别写死
    do {
        let sides = D.sides(for: ["女", "男"])
        expectEqual(sides[0], .leading, "对唱: 女声先开口时她靠左")
        expectEqual(sides[1], .trailing, "对唱: 后出现的男声靠右")
    }
    // 同义归并:同一位歌手的两种写法必须始终同侧(amll-ttml-db 提交规范的硬要求)
    do {
        expectEqual(D.identity(of: "男声"), "男", "对唱身份: 男声 归并成 男")
        expectEqual(D.identity(of: "男合"), "男", "对唱身份: 男合 归并成 男")
        expectEqual(D.identity(of: "Female"), "女", "对唱身份: Female 归并成 女")
        expectEqual(D.identity(of: "周杰伦"), "周杰伦", "对唱身份: 人名原样")
        let sides = D.sides(for: ["男", "男声", "女"])
        expectEqual(sides[0], .leading, "对唱身份: 男 靠左")
        expectEqual(sides[1], .leading, "对唱身份: 男声 跟 男 同一个人,还是靠左")
        expectEqual(sides[2], .trailing, "对唱身份: 女 才是第二位,靠右")
    }
    // 补齐 speakerLabels 缺的那 12 个 —— 它们此前既不被删也不被认,原样显示成脏行
    do {
        let s = D.speakers(in: ["旁白：从前有座山", "男：一", "女：二", "口白：完"])
        expectEqual(s.contains("旁白"), true, "对唱: 旁白 是认得的声部词")
        expectEqual(s.contains("口白"), true, "对唱: 口白 是认得的声部词")
        let sides = D.sides(for: ["旁白", "男", "女"])
        expectEqual(sides[0], .center, "对唱: 口白类居中,不占左右席位")
        expectEqual(sides[1], .leading, "对唱: 口白之后 男 仍是第一位")
        expectEqual(sides[2], .trailing, "对唱: 女 是第二位")
    }
    // 身份数下限:少于两个能分左右的身份,整首不判左右(丢行/剥前缀照旧,那是另一件事)
    do {
        expectEqual(D.sides(for: ["合", nil, "合"]).compactMap { $0 }.isEmpty, true,
                    "对唱: 只有合唱标记时没有左右可言")
        expectEqual(D.sides(for: ["男", nil, "男"]).compactMap { $0 }.isEmpty, true,
                    "对唱: 只有一位歌手时不判左右(否则单人歌在悬浮窗上会从居中变靠左)")
        expectEqual(D.sides(for: ["男", "合", "男"]).compactMap { $0 }.isEmpty, true,
                    "对唱: 一位歌手 + 合唱仍然不够两个身份")
        expectEqual(D.sides(for: ["v1", nil, "v2"])[2], .trailing,
                    "对唱: TTML 的匿名声部 v1/v2 是认得的身份")
        expectEqual(D.speakers(in: ["v1：一", "v2：二"]), Set(["v1", "v2"]),
                    "对唱: 匿名声部直通整份闸(agent 是上游权威标注)")
    }
    // 剥离与定边是两件事:身份不够也照样剥前缀、丢独占行
    do {
        let plan = D.plan(lineTexts: ["合：", "何时想戒掉流浪", "普通一行"])
        expectEqual(plan.dropped, [true, false, false], "对唱: 身份不够也照样丢掉独占标记行")
        expectEqual(plan.sides.compactMap { $0 }.isEmpty, true, "对唱: 但不判左右")
    }
    // group 不参与左右交替(AMLL 同款):「男-合-女」不能因为中间的合唱把侧算反
    do {
        let sides = D.sides(for: ["男", "合", "女", "合", "男"])
        expectEqual(sides[0], .leading, "对唱: 男 靠左")
        expectEqual(sides[1], .center, "对唱: 合 居中")
        expectEqual(sides[2], .trailing, "对唱: 合唱不打乱交替,女 仍是第二位靠右")
        expectEqual(sides[4], .leading, "对唱: 回到男 仍靠左")
    }
    // 整首没有标记的歌:全是 nil。这一条是**回归护栏** —— 混成 .leading 的话,悬浮窗上
    // 每一首普通歌都会从居中变成靠左。
    do {
        let sides = D.sides(for: [nil, nil, nil])
        expectEqual(sides.compactMap { $0 }.isEmpty, true, "对唱: 没有标记的歌全程无对唱信息")
    }
    // plan:剥正文 + 定边 + 标出该丢的行,一次算完
    do {
        let plan = D.plan(lineTexts: ["男：周末守着烤箱", "情人节也落单", "女：偏爱年轻女伴"])
        expectEqual(plan.texts, ["周末守着烤箱", "情人节也落单", "偏爱年轻女伴"], "对唱: plan 剥掉全部前缀")
        expectEqual(plan.sides, [.leading, .leading, .trailing], "对唱: plan 定边")
        expectEqual(plan.dropped, [false, false, false], "对唱: 行内前缀不丢行")
    }
    // 独占一行的标记(《说好不哭》的真实形态):剥完为空 → 整行丢掉,但**归属照样延续**
    do {
        let plan = D.plan(lineTexts: ["周杰伦：", "没有了联络", "阿信：", "电话开始躲", "周杰伦：", "你什么都没有"])
        expectEqual(plan.dropped, [true, false, true, false, true, false], "对唱: 独占标记行整行丢掉")
        expectEqual(plan.sides, [.leading, .leading, .trailing, .trailing, .leading, .leading],
                    "对唱: 独占标记的归属延续到下一个标记")
        expectEqual(plan.texts[1], "没有了联络", "对唱: 独占标记的下一行正文不受影响")
    }

    // ---- planWords: 逐字路径。标记在真实 YRC 里会被拆成好几个词 ----
    func w(_ start: Int, _ dur: Int, _ t: String) -> LyricWord {
        LyricWord(startMs: start, durationMs: dur, text: t)
    }
    do {
        // 《好好说再见》的真实形态:`(881,30)男` `(911,40)：` `(951,..)我` ——
        // 标记独立成词、冒号又是另一个词。旧实现只看第一个词,"男" 匹配不上 "男："。
        let lines = [
            LyricLineWords(timeMs: 881, words: [w(881, 30, "男"), w(911, 40, "："), w(951, 200, "我"), w(1151, 200, "爱")]),
            LyricLineWords(timeMs: 31038, words: [w(31038, 170, "女"), w(31208, 170, "："), w(31378, 200, "时"), w(31578, 200, "间")]),
        ]
        let plan = D.planWords(lines)
        expectEqual(plan.lines[0].words.map(\.text), ["我", "爱"], "对唱逐字: 标记独立成词也能剥掉")
        expectEqual(plan.lines[0].words[0].startMs, 951, "对唱逐字: 剥完首词的时间戳是真正第一个字的")
        expectEqual(plan.sides, [.leading, .trailing], "对唱逐字: 定边")
        expectEqual(plan.dropped, [false, false], "对唱逐字: 有正文的行不丢")
    }
    do {
        // 粘连形态:`男：周` 是一个词,扛着「周」的发声时间 —— 只能改文本,不能删词
        let lines = [
            LyricLineWords(timeMs: 21155, words: [w(21155, 180, "男：周"), w(21335, 320, "末")]),
            LyricLineWords(timeMs: 40310, words: [w(40310, 180, "女：偏"), w(40490, 320, "爱")]),
        ]
        let plan = D.planWords(lines)
        expectEqual(plan.lines[0].words.map(\.text), ["周", "末"], "对唱逐字: 粘连形态只改文本不删词")
        expectEqual(plan.lines[0].words[0].startMs, 21155, "对唱逐字: 粘连词保留原时间戳")
        expectEqual(plan.lines[0].words[0].durationMs, 180, "对唱逐字: 粘连词保留原时长")
    }
    do {
        // 人名逐字拆开 + 独占一行:`周` `杰` `伦` `：` 整行剥空 → 丢掉
        let lines = [
            LyricLineWords(timeMs: 24838, words: [w(24838, 154, "周"), w(24992, 204, "杰"), w(25196, 205, "伦"), w(25401, 255, "：")]),
            LyricLineWords(timeMs: 26499, words: [w(26499, 203, "没"), w(26702, 255, "有")]),
            LyricLineWords(timeMs: 113700, words: [w(113700, 200, "阿"), w(113900, 200, "信"), w(114100, 200, "：")]),
            LyricLineWords(timeMs: 114800, words: [w(114800, 200, "电"), w(115000, 200, "话")]),
            LyricLineWords(timeMs: 172200, words: [w(172200, 154, "周"), w(172354, 204, "杰"), w(172558, 205, "伦"), w(172763, 255, "：")]),
            LyricLineWords(timeMs: 173500, words: [w(173500, 200, "你"), w(173700, 200, "什")]),
        ]
        let plan = D.planWords(lines)
        expectEqual(plan.dropped, [true, false, true, false, true, false], "对唱逐字: 独占标记行整行丢掉")
        expectEqual(plan.sides, [.leading, .leading, .trailing, .trailing, .leading, .leading],
                    "对唱逐字: 人名标记的归属延续")
        expectEqual(plan.lines[1].words.map(\.text), ["没", "有"], "对唱逐字: 正文行不受影响")
    }
    do {
        // 回归护栏:普通歌(没有任何标记)逐字路径一个词都不能少
        let lines = [
            LyricLineWords(timeMs: 1000, words: [w(1000, 200, "情"), w(1200, 200, "人")]),
            LyricLineWords(timeMs: 2000, words: [w(2000, 200, "节"), w(2200, 200, "也")]),
        ]
        let plan = D.planWords(lines)
        expectEqual(plan.lines.map { $0.words.map(\.text) }, [["情", "人"], ["节", "也"]], "对唱逐字: 普通歌原样不动")
        expectEqual(plan.dropped, [false, false], "对唱逐字: 普通歌一行不丢")
        expectEqual(plan.sides.compactMap { $0 }.isEmpty, true, "对唱逐字: 普通歌没有对唱信息")
    }
}

// ---- LyricDuetLayout: 对唱行的两侧内缩(2026-08-23) ----
do {
    let L = LyricDuetLayout.self
    // 没有对唱信息的行一律 0 —— 普通歌的排版必须逐像素不变,这是回归护栏
    do {
        let i = L.insets(for: nil, availableWidth: 400, fontSize: 30)
        expectEqual(i.leading, 0, "对唱内缩: 无声部信息不留白(leading)")
        expectEqual(i.trailing, 0, "对唱内缩: 无声部信息不留白(trailing)")
    }
    // 左声部只在右边留白,右声部反过来
    do {
        let i = L.insets(for: .leading, availableWidth: 400, fontSize: 200)
        expectEqual(i.leading, 0, "对唱内缩: 左声部左边不留")
        expectEqual(i.trailing, 60, "对唱内缩: 左声部右边留 15%")
    }
    do {
        let i = L.insets(for: .trailing, availableWidth: 400, fontSize: 200)
        expectEqual(i.leading, 60, "对唱内缩: 右声部左边留 15%")
        expectEqual(i.trailing, 0, "对唱内缩: 右声部右边不留")
    }
    // 合唱两边都留 —— 它既不属于左也不属于右
    do {
        let i = L.insets(for: .center, availableWidth: 400, fontSize: 200)
        expectEqual(i.leading, 60, "对唱内缩: 合唱左边也留")
        expectEqual(i.trailing, 60, "对唱内缩: 合唱右边也留")
    }
    // 字号封顶接管:窗口很宽时 15% 会变成一大片空白,4 个字宽就够读出偏向了
    do {
        let i = L.insets(for: .leading, availableWidth: 4000, fontSize: 30)
        expectEqual(i.trailing, 120, "对唱内缩: 宽窗口下由 4 字宽封顶接管(不是 600)")
    }
    // 退化输入不产生负值/NaN
    do {
        expectEqual(L.insets(for: .leading, availableWidth: 0, fontSize: 30).trailing, 0,
                    "对唱内缩: 宽度为 0 时不留白")
        expectEqual(L.insets(for: .leading, availableWidth: -100, fontSize: 30).trailing, 0,
                    "对唱内缩: 负宽度不产生负内缩")
        expectEqual(L.insets(for: .leading, availableWidth: 400, fontSize: 0).trailing, 0,
                    "对唱内缩: 字号为 0 时封顶为 0")
    }
}

// ---- MusicPlaybackMode: 播放模式档位轮换,按播放器有没有「单曲循环」分两套(2026-08-14) ----
//
// Spotify 的 AppleScript 字典里 `repeating` 只是布尔,够不到 repeat-one —— 所以它的按钮
// 只在 列表 ↔ 随机 两档之间倒。轮换必须**闭合**:不管从哪一档起步,反复点下去都要能回到
// 原点,否则按钮会卡在一个出不来的档位上。
do {
    typealias Mode = MusicPlaybackController.MusicPlaybackMode

    // Apple Music:三档循环
    expectEqual(Mode.list.next(allowsRepeatOne: true), .shuffle, "播放模式: 列表→随机")
    expectEqual(Mode.shuffle.next(allowsRepeatOne: true), .repeatOne, "播放模式: 随机→单曲")
    expectEqual(Mode.repeatOne.next(allowsRepeatOne: true), .list, "播放模式: 单曲→列表")

    // 列表循环档(2026-08-21 补,AM 循环键三态):全部→单曲;够不到单曲的播放器直接回列表
    expectEqual(Mode.repeatAll.next(allowsRepeatOne: true), .repeatOne, "播放模式: 全部→单曲")
    expectEqual(Mode.repeatAll.next(allowsRepeatOne: false), .list, "播放模式(无单曲): 全部→列表")

    // Spotify:跳过单曲那一档
    expectEqual(Mode.list.next(allowsRepeatOne: false), .shuffle, "播放模式(无单曲): 列表→随机")
    expectEqual(Mode.shuffle.next(allowsRepeatOne: false), .list, "播放模式(无单曲): 随机→列表")
    // 起步档位恰好是单曲时(用户在 Apple Music 里开了单曲循环,再切到 Spotify 播放)也要能出来
    expectEqual(Mode.repeatOne.next(allowsRepeatOne: false), .list, "播放模式(无单曲): 单曲→列表")

    // 轮换闭合:连点下去不能卡在某一档出不来。
    //
    // ⚠️ 例外是**只能离开、回不去**的过渡态,它们能一步走掉(上面那些断言)就够了:
    // ① "单曲档 + 不支持单曲"(用户在 Apple Music 里开着单曲循环、切到 Spotify 播放时
    //   可能读到它),回不去正是设计意图,不是卡住;第一版把它也算进"必须回到原点",
    //   断言直接红了,是断言写宽了,不是实现错了。
    // ② 列表循环档(2026-08-21 新增):next() 的老三档轮换不产出它 —— 产出它的是歌词
    //   窗口循环键自己的三态 switch(关→全部→单曲→关),cyclePlaybackMode 读到它时
    //   顺 AM 语义走 全部→单曲,不需要转回来。
    for allows in [true, false] {
        for start in Mode.allCases {
            var cur = start
            var seen: [Mode] = []
            for _ in 0..<4 { cur = cur.next(allowsRepeatOne: allows); seen.append(cur) }
            let startIsUnreachable = (!allows && start == .repeatOne) || start == .repeatAll
            if !startIsUnreachable {
                expectEqual(seen.contains(start), true,
                            "播放模式: allowsRepeatOne=\(allows) 从 \(start.rawValue) 起步能转回原点")
            }
            if !allows {
                expectEqual(seen.contains(.repeatOne), false,
                            "播放模式: allowsRepeatOne=false 时永远不会落到单曲档")
            }
        }
    }

    // 能力表:只有 Apple Music 有单曲循环;QQ音乐/网易云连扩展控制都没有(两个 .app 无 .sdef)
    expectEqual(MusicPlaybackController.supportsRepeatOne(.appleMusic), true, "能力: Apple Music 有单曲循环")
    expectEqual(MusicPlaybackController.supportsRepeatOne(.spotify), false, "能力: Spotify 没有单曲循环")
    expectEqual(MusicPlaybackController.supportsExtendedControls(.appleMusic), true, "能力: Apple Music 支持音量/模式")
    expectEqual(MusicPlaybackController.supportsExtendedControls(.spotify), true, "能力: Spotify 支持音量/模式")
    expectEqual(MusicPlaybackController.supportsExtendedControls(.qqMusic), false, "能力: QQ音乐不支持")
    expectEqual(MusicPlaybackController.supportsExtendedControls(.netease), false, "能力: 网易云不支持")
    expectEqual(MusicPlaybackController.supportsExtendedControls(.kugou), false, "能力: 酷狗不支持(无 .sdef)")
    expectEqual(MusicPlaybackController.supportsRepeatOne(.kugou), false, "能力: 酷狗没有单曲循环")
}

// ---- 信任列表:「自动识别」放开到任意 App(2026-08-21) ----
//
// 白名单不只挡显示,**也挡打卡**(collector 的 poller.isTracked),所以口径是"用户显式
// 同意"而不是"一律接受"—— 一律接受等于让 YouTube/播客写进永久收听历史。这里守的是
// 那道闸的语义:内置的永远认、信任过的认、其它一律不认。
do {
    typealias T = TrustedPlayers
    let trusted = ["com.foobar.mac": "Foobar2000", "com.some.player": ""]

    // 内置五个:跟信任列表无关,永远认(空名单也认)
    for player in PlaybackPlayer.allCases where player != .auto {
        expectEqual(T.isAccepted(player.bundleIdentifier, trusted: [:]), true,
                    "信任列表: 内置播放器 \(player) 不依赖名单")
    }
    // 信任过的:认。名字是空串(反查不到 App 名)也照样认 —— 名字只影响显示/标签,不影响准入
    expectEqual(T.isAccepted("com.foobar.mac", trusted: trusted), true, "信任列表: 信任过的 App 被接受")
    expectEqual(T.isAccepted("com.some.player", trusted: trusted), true,
                "信任列表: 名字为空(反查不到)不影响准入")
    // 没信任过的:一律不认 —— 这条就是"默认一条垃圾都进不来"
    expectEqual(T.isAccepted("com.apple.Safari", trusted: trusted), false, "信任列表: 陌生 App 默认不接受")
    expectEqual(T.isAccepted("", trusted: trusted), false, "信任列表: 空 bundle id 不接受")
    expectEqual(T.isAccepted(nil, trusted: trusted), false, "信任列表: nil 不接受")
    // .auto 自己那个空 bundle id 不能被当成"匹配上了"
    expectEqual(T.isAccepted(PlaybackPlayer.auto.bundleIdentifier, trusted: [:]), false,
                "信任列表: 自动识别的空 bundle id 不算命中")
}

// ---- 「这不是一首歌」守卫:信任的 App 报空歌手/空专辑就丢掉(2026-08-21) ----
//
// 判据跟 collector 的 isAdBreak 完全一致(`album == "" || artist == ""`),区别只在作用域:
// 那个只服务 Spotify 广告,这个服务信任列表。样本全是真抓的,四份:
//   酷狗 周杰伦/七里香、Spotify 方大同/Soulboy、Apple Music 卢广仲/100种生活 → 是歌
//   Arc 放视频 两次:①artist/album 都空 ②artist=频道名「Dream in reality」、album 仍空
// **album 是这四份里唯一 100% 分对的字段** —— ② 正是"只卡 artist 不够"的证据。
do {
    typealias T = TrustedPlayers
    let arc = "company.thebrowser.Browser"
    let trusted = [arc: "Arc"]

    // Arc 两份真实样本都该被丢掉
    expectEqual(T.notASong(bundleID: arc, artist: "", album: "", trusted: trusted), true,
                "非歌守卫: artist/album 都空 → 丢掉(Arc 第一份样本)")
    expectEqual(T.notASong(bundleID: arc, artist: "Dream in reality", album: "", trusted: trusted), true,
                "非歌守卫: YouTube 频道名进了 artist 但 album 空 → 仍然丢掉(这是只卡 artist 不够的证据)")
    expectEqual(T.notASong(bundleID: arc, artist: "", album: "某专辑", trusted: trusted), true,
                "非歌守卫: 反方向(artist 空)同样丢掉")
    expectEqual(T.notASong(bundleID: arc, artist: nil, album: nil, trusted: trusted), true,
                "非歌守卫: 字段缺失等于空")
    expectEqual(T.notASong(bundleID: arc, artist: "  ", album: "某专辑", trusted: trusted), true,
                "非歌守卫: 纯空白按空处理")

    // 三个真音乐 App 的真实样本都该放行
    for sample in [("周杰伦", "七里香"), ("方大同", "Soulboy"), ("卢广仲", "100种生活")] {
        expectEqual(T.notASong(bundleID: arc, artist: sample.0, album: sample.1, trusted: trusted), false,
                    "非歌守卫: 两个字段都齐就放行(\(sample.0) / \(sample.1))")
    }

    // 内置播放器不受这条约束 —— 它们各有既有守卫,卷进来等于偷偷改既有行为
    for player in PlaybackPlayer.allCases where player != .auto {
        expectEqual(T.notASong(bundleID: player.bundleIdentifier, artist: "", album: "", trusted: trusted),
                    false, "非歌守卫: 内置播放器 \(player) 不受影响")
    }
    // 没信任过的:由准入层挡,这里返回 false —— 别掩盖真实原因
    expectEqual(T.notASong(bundleID: "com.apple.Safari", artist: "", album: "", trusted: trusted), false,
                "非歌守卫: 没信任过的由准入层挡,不在这条守卫里报 true")
}

// ---- 灵动岛展开区高度:按里面真正会渲染的东西算(2026-08-21) ----
//
// 用户报「没有歌词的时候这块太大、很多空的地方」:展开区原来恒高 76 且 alignment .top,
// 而三样内容里两样是条件渲染的(没歌词就没有预览行、没时长就没有进度条),两样都缺时
// 里面只剩一排三键,剩下 41pt 全是底部空白。
//
// 这一组断言守两件事:①三样齐时**跟改动前逐字相等**(76),不是顺手改了既有布局;
// ②每一段的增量正好是当初推出 76 时用的那几个数,不能被随手调松。
do {
    typealias M = NotchExpandedMetrics
    expectEqual(M.height(hasLyricPreview: true, hasScrubber: true), 76,
                "岛展开区: 有歌词有时长 = 76(必须跟改动前逐字相等)")
    expectEqual(M.height(hasLyricPreview: true, hasScrubber: true),
                M.maxHeight,
                "岛展开区: 三样齐就等于窗口/预览容器用的那个 Max")
    expectEqual(M.height(hasLyricPreview: false, hasScrubber: true), 59,
                "岛展开区: 没歌词省掉预览行的 17pt")
    expectEqual(M.height(hasLyricPreview: true, hasScrubber: false), 52,
                "岛展开区: 没时长省掉进度条那 24pt")
    expectEqual(M.height(hasLyricPreview: false, hasScrubber: false), 35,
                "岛展开区: 两样都没有只剩三键+底边距(用户截图里那个状态)")
    // 恒有的那一段必须够放下三键(22)+底边距(10),不然最下面那排会被 alignment .top 裁掉
    expectEqual(M.height(hasLyricPreview: false, hasScrubber: false) >= 32, true,
                "岛展开区: 最小高度仍装得下三键+底边距,不会裁按钮")
    // 单调:多一样内容不能反而变矮
    expectEqual(M.height(hasLyricPreview: true, hasScrubber: false)
                > M.height(hasLyricPreview: false, hasScrubber: false), true,
                "岛展开区: 加一段内容必须变高")
}

// ---- 「第 N 次听」的作废判据:按最新一条收听的时刻,而不是页内出现次数(2026-08-21) ----
//
// 用户报「第 15 次听下面紧跟着第 21 次听」。根因:原来只按页内出现次数判作废,而连播同一
// 首歌时这一页很快被它占满 —— 新的挤进来、旧的挤出去,页内次数**不再增长**,缓存总数于是
// 永久冻结(实测冻在 15,真实合计 22 = 园游会 10 + 園遊會 12 两个 Last.fm 实体),而实时行
// 是每次换歌现取的、显示 21。完整推导见 PlayCountRecency 的注释。
do {
    typealias R = PlayCountRecency
    func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
    let k = "周杰倫|园游会"

    // 同一个 key 多条 → 取**最新**那条(不是第一条也不是最后一条)
    expectEqual(R.newest([(k, at(1000)), (k, at(3000)), (k, at(2000))])[k], at(3000),
                "次数作废: 取同曲最新那条的时刻")

    // 页内条数**饱和**时仍然分辨得出"多听了一次" —— 这正是原判据漏掉的那一类:
    // 两批都是 3 条(条数没变),但最新时刻从 3000 前进到 4000
    let before = R.newest([(k, at(1000)), (k, at(2000)), (k, at(3000))])
    let after = R.newest([(k, at(2000)), (k, at(3000)), (k, at(4000))])
    expectEqual(before[k], at(3000), "次数作废: 前一批的最新时刻")
    expectEqual(after[k]! > before[k]!, true,
                "次数作废: 条数不变(3→3)但最新时刻前进 → 必须判成过期(原判据在这里失效)")

    // date 为 nil 的跳过(「正在播放」那条:还没落库、不在 userplaycount 里)
    expectEqual(R.newest([(k, at(5000)), (k, nil)])[k], at(5000), "次数作废: 无时间戳的条目不参与")
    expectEqual(R.newest([(k, nil)]).isEmpty, true, "次数作废: 只有无时间戳条目时不产出基线")
    // 不同 key 各自记账(两个写法在 Last.fm 上确实是两个实体)
    expectEqual(R.newest([(k, at(100)), ("周杰倫|園遊會", at(200))]).count, 2,
                "次数作废: 两个写法各自一条")
}

// ---- 「第 N 次听」判据③:页内自相矛盾(2026-08-22) ----
//
// 判据①②都要跟上一轮比,而基线只在内存、次数表却持久化 —— App 重启后基线被重设成
// 「当下」,那首歌不再被播一次就永远等不到作废。用户实测:缓存冻在 3、真实 12,那一页有
// 11 行《开不了口 (live)》,视图侧减法把后 8 行全算成 ≤0,整片空白且不自愈。
// 这一条只看当下这一页站不站得住,无状态,重启后第一轮就生效。
do {
    typealias R = PlayCountRecency
    func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
    let now = at(10_000)
    let throttle: TimeInterval = 300

    // 用户那一幕:页内 11 行 vs 缓存 3 → 缓存必错。本进程还没问过(nil)→ 立刻作废,
    // 这正是"重启后第一轮就质疑一次"。
    expectEqual(R.contradicted(onPage: 11, cachedTotal: 3, lastFetched: nil,
                               now: now, recheckAfter: throttle), true,
                "判据③: 页内 11 行 > 缓存 3 且从没问过 → 作废")
    // 页内数 <= 缓存总数 = 没有矛盾。等号也不算 —— 缓存里是"到此刻为止的总数",
    // 页内正好看见这么多次是完全自洽的。
    expectEqual(R.contradicted(onPage: 3, cachedTotal: 3, lastFetched: nil,
                               now: now, recheckAfter: throttle), false,
                "判据③: 页内 3 行 = 缓存 3 → 自洽,不作废")
    expectEqual(R.contradicted(onPage: 2, cachedTotal: 12, lastFetched: nil,
                               now: now, recheckAfter: throttle), false,
                "判据③: 页内比缓存少 → 不作废")
    // 节流:Last.fm 自己的 userplaycount 滞后几分钟,刚问过就再问是每轮白发请求
    expectEqual(R.contradicted(onPage: 11, cachedTotal: 3, lastFetched: at(9_800),
                               now: now, recheckAfter: throttle), false,
                "判据③: 200s 前刚问过(< 300s 节流) → 这一轮不重取")
    expectEqual(R.contradicted(onPage: 11, cachedTotal: 3, lastFetched: at(9_700),
                               now: now, recheckAfter: throttle), true,
                "判据③: 距上次 300s 到点 → 重取")
    // 节流只在真有矛盾时才轮得到判 —— 没矛盾的话多久没问过都不该作废
    expectEqual(R.contradicted(onPage: 1, cachedTotal: 99, lastFetched: at(0),
                               now: now, recheckAfter: throttle), false,
                "判据③: 无矛盾时,再久没问过也不作废")
}

// ---- nowPlayingCount 追赶 trackPlayCounts(2026-08-24) ----
//
// 用户实测(《Controversy》):换歌那一刻 nowPlayingCount 取到 16(显示 17),trackPlayCounts
// 随后追到 27(显示 28)——nowPlayingCount 没有任何自愈机制,永远停在 17,直到下一次换歌。
// 这组用例钉住"只能涨、不能跌"的取舍。
do {
    typealias R = PlayCountRecency
    // 正题:trackPlayCounts 学到了更高的总数 → 采纳,+1 换算成显示值
    expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 27), 28,
                "nowPlayingCount 追赶: 27+1=28,比当前 17 高 → 采纳")
    // 还没显示过(nil,理论上不该发生在这条路径,但当 0 处理不炸)
    expectEqual(R.reconciledNowPlayingCount(current: nil, freshTotal: 5), 6,
                "nowPlayingCount 追赶: current 为 nil 时按 0 比较")
    // ⚠️ 只能涨、不能跌 —— 新数字更低时必须按兵不动,不能让显示的数字倒退
    expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 10), nil,
                "nowPlayingCount 追赶: 新总数更低 → 不采纳,返回 nil")
    // 等于当前值:没有新信息,不该触发一次无意义的写入(SwiftUI 不必要的重渲染)
    expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 16), nil,
                "nowPlayingCount 追赶: 换算后与当前相等 → 不采纳")
    // 差 1 也要涨 —— 阈值判断用的是 > 不是 >=,别把等于的情况错判成"该涨"
    expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 17), 18,
                "nowPlayingCount 追赶: 新总数比换算前的 total 还高一点 → 仍要涨")
}

// ---- 封面第⑤级:Apple Music 目录匹配守卫(2026-08-22) ----
//
// 前四级封面兜底里只有「本机 enrich 缓存」覆盖得了 Last.fm 对中文曲库缺图,而那一级只有
// 本机播过才有数据 —— iPhone 听的歌、翻历史页看到的老歌天生在盲区里(实测抽样 205 首里
// 25% 缺图,getinfo 只救回 20%、同专辑兄弟一张都救不到)。第⑤级去 iTunes Search 补。
//
// ⚠️ 这一组断言守的是「宁可留空位,也不挂错图」。实测:裸用搜索结果第一条会给
// 《微醺卡带 - 情非得已 (微醺版)》配上《鱼翅Fin - 无声的告别是对往事的礼赞》的封面。
do {
    typealias M = MusicCatalogSearch
    func item(_ artist: String, _ track: String, _ album: String,
              art: String? = "https://is1.mzstatic.com/x/100x100bb.jpg") -> M.Item {
        M.Item(trackName: track, artistName: artist, collectionName: album,
               trackViewUrl: nil, artistViewUrl: nil, collectionViewUrl: nil, artworkUrl100: art)
    }
    let 地表最强 = "周杰伦地表最强世界巡回演唱会 (Live)"

    // 100pt → 600pt;认不出尺寸段就原样(用小图也比没有强)
    expectEqual(M.upscaleArtwork("https://is1.mzstatic.com/x/100x100bb.jpg")?.absoluteString,
                "https://is1.mzstatic.com/x/600x600bb.jpg", "封面⑤: 升到 600pt")
    expectEqual(M.upscaleArtwork("https://is1.mzstatic.com/x/64x64.jpg")?.absoluteString,
                "https://is1.mzstatic.com/x/64x64.jpg", "封面⑤: 认不出尺寸段就原样")
    expectEqual(M.upscaleArtwork(nil) == nil, true, "封面⑤: 没有图就是 nil")

    // 歌手+歌名+专辑全对 → 高置信
    expectEqual(M.pickArtwork([item("周杰伦", "床边故事 (Live)", 地表最强)],
                              title: "床边故事 (Live)", artist: "周杰伦", album: 地表最强)?.confidence,
                .albumMatch, "封面⑤: 三项全对 = 高置信")
    // 繁简:Last.fm 那行常是「周杰倫」,iTunes 是「周杰伦」—— familyKey 的 ICU 折叠救回
    expectEqual(M.pickArtwork([item("周杰伦", "开不了口 (Live)", 地表最强)],
                              title: "开不了口 (live)", artist: "周杰倫", album: 地表最强)?.confidence,
                .albumMatch, "封面⑤: 繁简歌手名对得上")
    // 合唱 credit:查询侧是主歌手、目录侧带上了客串
    expectEqual(M.pickArtwork([item("周杰伦 & 派伟俊", "我要夏天 (Live)", 地表最强)],
                              title: "我要夏天 (Live)", artist: "周杰伦", album: 地表最强)?.confidence,
                .albumMatch, "封面⑤: 合唱 credit 归首位后对得上")

    // ⚠️ 挑选必须扫完候选、不能只看第一条。实测 30 首里有 5 首靠这一步纠正回正确那张
    //(《NOW YOU SEE ME (Live)》第一条是录音室版、《青花瓷 (Live)》第一条是魔天伦演唱会)。
    let mixed = [item("周杰伦", "青花瓷 (Live)", "魔天伦世界巡回演唱会 (Live)"),
                 item("周杰伦", "青花瓷 (Live)", 地表最强)]
    let picked = M.pickArtwork(mixed, title: "青花瓷 (Live)", artist: "周杰伦", album: 地表最强)
    expectEqual(picked?.confidence, .albumMatch, "封面⑤: 越过第一条去找专辑也对上的")
    expectEqual(picked?.matchedAlbum, 地表最强, "封面⑤: 挑中的确实是同一张专辑")

    // 专辑对不上但同曲 → 中置信(比空位强,但同屏可能不一致)
    expectEqual(M.pickArtwork([item("Beyond", "光辉岁月", "Beyond - 25th Anniversary")],
                              title: "光辉岁月", artist: "Beyond", album: "BEYOND音乐大全 101")?.confidence,
                .trackOnly, "封面⑤: 只有歌名歌手对上 = 中置信")

    // ⚠️ 这条是这一级存在的底线:匹配不上必须留空位,绝不退回搜索结果第一条
    expectEqual(M.pickArtwork([item("鱼翅Fin", "无声的告别是对往事的礼赞", "工作札记 - EP")],
                              title: "情非得已 (微醺版)", artist: "微醺卡带",
                              album: "情非得已（微醺版）") == nil,
                true, "封面⑤: 完全不相干的结果必须留空位(实测踩到过这一条)")
    // Live 版不能拿录音室版的封面 —— familyKey 刻意不折 (Live) 这类版本副题
    expectEqual(M.pickArtwork([item("周杰伦", "美人鱼", "哎呦, 不错哦")],
                              title: "美人鱼 (Live)", artist: "周杰伦", album: 地表最强) == nil,
                true, "封面⑤: Live 版不匹配录音室版")
    // 目录学噪音(feat 客串署名)该折掉 —— 这类差异不是两份录音
    expectEqual(M.pickArtwork([item("Cailin Russo", "Phoenix (feat. Chrissy Costanza)", "Phoenix")],
                              title: "Phoenix", artist: "Cailin Russo", album: "Phoenix")?.confidence,
                .albumMatch, "封面⑤: feat 副题属目录学噪音,折掉后对得上")
    // 没有图的条目跳过,不能因为它占了第一条就放弃后面能用的
    expectEqual(M.pickArtwork([item("周杰伦", "床边故事 (Live)", 地表最强, art: nil),
                               item("周杰伦", "床边故事 (Live)", 地表最强)],
                              title: "床边故事 (Live)", artist: "周杰伦", album: 地表最强)?.confidence,
                .albumMatch, "封面⑤: 跳过没有图的条目")
    expectEqual(M.pickArtwork([], title: "x", artist: "y", album: nil) == nil, true,
                "封面⑤: 空结果集")
    // 行没有专辑名时(Last.fm 偶尔缺 album)退化成只按歌名歌手判,给中置信
    expectEqual(M.pickArtwork([item("周杰伦", "床边故事 (Live)", 地表最强)],
                              title: "床边故事 (Live)", artist: "周杰伦", album: nil)?.confidence,
                .trackOnly, "封面⑤: 行缺专辑名时退成中置信")
}

// ---- Last.fm GET query 的双重编码(2026-08-22) ----
//
// 端点会对 query value 多解一次码(第二遍是 form-urlencoded 口径,`+` 当空格),所以
// `+` 和 `%` 必须各多编一层。实测:track=…%2B… → error 6 Track not found;
// track=…%252B… → 命中 userplaycount=2。用真实存在的乐队 `+44` 独立验证过是端点级行为。
// URLComponents.queryItems 走的 urlQueryAllowed **放行 `+`**,正是这个坑的入口。
do {
    typealias Q = LastfmQuery
    expectEqual(Q.escape("夜曲+窃爱 (Live)"),
                "%E5%A4%9C%E6%9B%B2%252B%E7%AA%83%E7%88%B1%20%28Live%29",
                "lastfm query: 加号编成 %252B(实测这一串才命中)")
    expectEqual(Q.escape("+44"), "%252B44", "lastfm query: 乐队名 +44")
    // 百分号同理要多编一层:服务端解两遍才还原成字面 %
    expectEqual(Q.escape("100%"), "100%2525", "lastfm query: 百分号编成 %2525")
    // 顺序守卫:先换 % 再换 + —— 反过来的话 %2B 里的 % 会被再啃一遍变成 %2525 2B
    expectEqual(Q.escape("a+b%c"), "a%252Bb%2525c", "lastfm query: 加号与百分号同时出现")
    // 不含这两个字符的 value 必须跟标准编码逐字节相同 —— 这是"对既有请求零影响"的依据
    expectEqual(Q.escape("开不了口 (live)"),
                "%E5%BC%80%E4%B8%8D%E4%BA%86%E5%8F%A3%20%28live%29",
                "lastfm query: 不含 +/% 时与标准编码一致")
    expectEqual(Q.escape("Beyond"), "Beyond", "lastfm query: 纯 ASCII 原样")
    // 空格用 %20 而不是 +(用 + 会被第二遍解码当成空格,结果碰巧也对,但两侧口径要一致)
    expectEqual(Q.escape("a b").contains("+"), false, "lastfm query: 空格不编成加号")
    expectEqual(Q.queryString([("method", "track.getinfo"), ("track", "+44")]),
                "method=track.getinfo&track=%252B44", "lastfm query: 拼串按传入顺序")
}

// ---- 播放器身份契约:rawValue / bundle id 必须跟 collector 逐字对应 ----
//
// rawValue 是两侧通过共享 features.json 的 "player" 字段交换的字符串(Go 侧 features.go 的
// playerXxx 常量);bundle id 是核对"系统级 Now Playing 是谁在报"的唯一依据(Go 侧 system.go
// 的 xxxBundleID 常量)。这两组字符串任一侧改了名而另一侧没跟上,表现都是**静默失效**:
// 用户在设置里选了某个播放器,collector 认不出这个值就默默兜底成"自动识别",界面一切正常、
// 只是选择没生效 —— 所以这里把它们钉成断言,而不是靠"记得两边一起改"。
do {
    let expected: [PlaybackPlayer: (raw: String, bundle: String)] = [
        .appleMusic: ("apple_music", "com.apple.Music"),
        .qqMusic: ("qq_music", "com.tencent.QQMusicMac"),
        .netease: ("netease_music", "com.netease.163music"),
        .kugou: ("kugou_music", "com.kugou.mac.Music"),
        .spotify: ("spotify", "com.spotify.client"),
    ]
    for (player, want) in expected {
        expectEqual(player.rawValue, want.raw, "播放器契约: \(player) 的 rawValue")
        expectEqual(player.bundleIdentifier, want.bundle, "播放器契约: \(player) 的 bundle id")
        expectEqual(PlaybackPlayer(rawValue: want.raw) == player, true,
                    "播放器契约: \(want.raw) 能解回 \(player)")
    }
    // .auto 刻意没有固定 bundle id(见 PlaybackPlayer 注释),空串让"唤起播放器"那类联动
    // 自然 no-op。
    expectEqual(PlaybackPlayer.auto.bundleIdentifier, "", "播放器契约: 自动识别没有固定 bundle id")
    // 全部 case 都得在上表里 —— 新加一个播放器就必须来这里补一行,漏了这条断言会红。
    expectEqual(PlaybackPlayer.allCases.count, expected.count + 1,
                "播放器契约: 新增播放器要同步补进契约表(+1 是 .auto)")
    // bundle id 不能撞车:复制粘贴加播放器时最容易犯,而撞车的表现是"选了 A 却跟着 B 走"。
    let bundles = PlaybackPlayer.allCases.filter { $0 != .auto }.map(\.bundleIdentifier)
    expectEqual(Set(bundles).count, bundles.count, "播放器契约: bundle id 互不重复")
}

// ---- EnrichCacheKeys: 缓存 key 归一化,必须跟 collector 逐字节一致(2026-08-14) ----
//
// 这组用例跟 collector/enrichkey_test.go 的 TestNormEnrichTitle 是**同一张表**。两边只要
// 有一处对不上,collector 按归一化 key 写盘、悬浮窗按另一种拼法查,结果不是"显示了旧歌词"
// 而是**整首歌查不到词**,且只在某些播放器上复现 —— 这种失败最难从现象倒推回来,所以钉死。
do {
    let K = EnrichCacheKeys.self
    let cases: [(String, String, String)] = [
        // 要修的那一类:中文歌名 + 括号里的英文译名(本机缓存里真实存在过的重复条目)
        ("全角括号译名", "不散的筵席（I Miss You）", "不散的筵席"),
        ("全角括号译名2", "神探（The Detective）", "神探"),
        ("半角括号译名", "小師妹 (Love Triangle)", "小師妹"),
        // 版本标记必须原样保留:合并了就是把两个不同的录音当成同一首
        ("remix 保留", "Song (Remix)", "Song (Remix)"),
        ("live 保留", "告白气球 (Live)", "告白气球 (Live)"),
        ("remaster 保留", "Bad (2012 Remaster)", "Bad (2012 Remaster)"),
        ("feat 保留", "爱我的人 (feat. MOE.)", "爱我的人 (feat. MOE.)"),
        ("instrumental 保留", "Song (Instrumental)", "Song (Instrumental)"),
        ("interlude 保留", "The Girl In Red (Interlude)", "The Girl In Red (Interlude)"),
        ("中文版本标记保留", "月亮代表我的心 (现场版)", "月亮代表我的心 (现场版)"),
        // 边界
        ("括号就是整个歌名", "(Interlude)", "(Interlude)"),
        ("括号就是整个歌名2", "（前奏）", "（前奏）"),
        ("两层括号连剥", "歌名（译名）[Explicit]", "歌名"),
        ("剥到版本标记停手", "歌名（译名）(Live)", "歌名（译名）(Live)"),
        ("中间的括号不动", "Song (A) tail", "Song (A) tail"),
        ("没有括号", "不散的筵席", "不散的筵席"),
        ("空串", "", ""),
        ("不换行空格", "Song\u{00a0}(I Miss You)", "Song"),
        ("零宽字符", "不散\u{200b}的筵席", "不散的筵席"),
        ("全角空格", "不散的筵席\u{3000}（I Miss You）", "不散的筵席"),
    ]
    for (name, input, want) in cases {
        expectEqual(K.normalizedTitle(input), want, "缓存key: \(name)")
    }
    // 不转小写、不折繁简 —— 列表显示的就是 key 拆出来的三段,折了会看到"神经志 the journal"
    expectEqual(
        K.normalizedKey(artist: "PRINCE", title: "The Girl In Red (Interlude)", album: "神經志 The Journal"),
        "PRINCE|The Girl In Red (Interlude)|神經志 The Journal",
        "缓存key: 不转小写也不折繁简"
    )
    // 幂等:迁移每次 collector 启动都会跑一遍
    let once = K.normalizedKey(artist: "丁世光", title: "不散的筵席（I Miss You）", album: "神經志 The Journal")
    expectEqual(once, "丁世光|不散的筵席|神經志 The Journal", "缓存key: 三段拼接")
    expectEqual(K.normalizedTitle("不散的筵席"), "不散的筵席", "缓存key: 归一化过的再算一次不变")

    // ---- looseKey:只用于查询兜底的宽松形态(2026-08-16) ----
    //
    // collector 把"其实是同一首歌"的重复条目合并成一条后,缓存里只剩最适合显示的那个写法;
    // 播放器报的可能是另一个写法,靠这一层才查得到。⚠️ 它**只能**用于兜底,绝不能拿去构造
    // key —— 繁简这一档两侧本来就不一致(collector 用 OpenCC 词典、这边用 ICU),写进 key
    // 就是「悬浮窗整首歌没词」。理由完整版见 EnrichCacheKeys.looseKey 的注释。
    let loosePairs: [(String, String, String)] = [
        ("半角空格", "陶喆|Susan 说|太平盛世", "陶喆|Susan说|太平盛世"),
        ("中英之间空格", "陶喆|Sula 与 Lampa 的寓言|太平盛世", "陶喆|Sula 与 Lampa的寓言|太平盛世"),
        ("歌名繁简", "方大同|千纸鹤|回到未來", "方大同|千紙鶴|回到未來"),
        ("歌手名繁简", "孙燕姿|我懷念的|逆光", "孫燕姿|我懷念的|逆光"),
        ("大小写", "PRINCE|Kiss|Parade", "Prince|Kiss|Parade"),
    ]
    for (name, a, b) in loosePairs {
        expectEqual(K.looseKey(a), K.looseKey(b), "looseKey 同组: \(name)")
    }
    // 版本/专辑/歌手不同的绝不能被兜到一起 —— 兜底再宽松也不能把两首歌混成一首。
    let looseDistinct: [(String, String, String)] = [
        ("版本括号", "陶喆|Susan 说|太平盛世", "陶喆|Susan 说(Music鉴赏版)|太平盛世"),
        ("不同专辑", "陶喆|Susan 说|太平盛世", "陶喆|Susan 说|黑色柳丁"),
        ("不同歌手", "陶喆|Susan 说|太平盛世", "王力宏|Susan 说|太平盛世"),
    ]
    for (name, a, b) in looseDistinct {
        expectNotEqual(K.looseKey(a), K.looseKey(b), "looseKey 不同组: \(name)")
    }
    // looseKey 绝不能影响 normalizedKey —— 后者是真正落盘/显示用的那个。
    expectEqual(
        K.normalizedKey(artist: "孙燕姿", title: "我懷念的", album: "逆光"),
        "孙燕姿|我懷念的|逆光",
        "缓存key: looseKey 不污染 normalizedKey"
    )
}

// ---- HanScript:繁简孪生写法(2026-08-18) ----
//
// Last.fm 统计页「第 N 次听」的前提:scrobble 是本机播放的原样镜像,同一首歌从不同
// 播放器放、报的歌名一繁一简,Last.fm 就记成两个曲目实体、两本分开的账(《我不是农人》
// 11 次/《我不是農人》3 次,2026-08-18 用户截图坐实)。显示端拿孪生写法再查一次求和,
// 这里锁死孪生写法的推导规则。⚠️ 它只用于发起查询,绝不用于显示或构造 key。
do {
    typealias H = HanScript
    let t = H.siblingPair(artist: "方大同", title: "我不是農人")
    expectEqual(t?.artist ?? "", "方大同", "孪生写法: 繁→简 歌手同形不动")
    expectEqual(t?.title ?? "", "我不是农人", "孪生写法: 繁→简 歌名")
    let s = H.siblingPair(artist: "方大同", title: "我不是农人")
    expectEqual(s?.title ?? "", "我不是農人", "孪生写法: 简→繁(ICU 挑的候选)")
    let a = H.siblingPair(artist: "陳奕迅", title: "富士山下")
    expectEqual(a?.artist ?? "", "陈奕迅", "孪生写法: 歌手名也跟着转")
    expectEqual(a?.title ?? "", "富士山下", "孪生写法: 同形歌名不动")
    expectEqual(H.siblingPair(artist: "Taylor Swift", title: "Style") == nil, true,
                "孪生写法: 纯拉丁没有孪生")
    expectEqual(H.sibling("方大同|我不是農人") ?? "", "方大同|我不是农人",
                "孪生写法: 拼好的 key 整串转,分隔符不动")
}

// ---- PlayCountVariants:「第 N 次听」的写法孪生族(2026-08-18,括号风格分裂实测) ----
//
// 丁世光《神经志》实测:`一口（The Day You Left Me）`全角 2 次/`一口(The Day You Left
// Me)`半角无空格 25 次/`一口`1 次——Last.fm 按写法各记各的账,合并要把整族都问到。
do {
    typealias V = PlayCountVariants
    let full = V.siblings(artist: "丁世光", title: "一口（The Day You Left Me）").map(\.title)
    expectEqual(full.contains("一口(The Day You Left Me)"), true, "写法族: 全角→半角无空格")
    expectEqual(full.contains("一口 (The Day You Left Me)"), true, "写法族: 全角→半角带空格")
    expectEqual(full.contains("一口"), true, "写法族: 全角→纯中文名")
    expectEqual(full.contains("一口（The Day You Left Me）"), false, "写法族: 不含本尊")
    expectEqual(full.count <= 6, true, "写法族: 封顶 6 个,实际 \(full.count)")
    // 半角无空格(历史大头写法)反向也要能生成全角
    let half = V.siblings(artist: "丁世光", title: "一口(The Day You Left Me)").map(\.title)
    expectEqual(half.contains("一口（The Day You Left Me）"), true, "写法族: 半角→全角")
    // 纯 ASCII 歌名(E.T./Simon)从不分裂,零候选零请求
    expectEqual(V.siblings(artist: "丁世光", title: "E.T.").isEmpty, true, "写法族: 纯 ASCII 零候选")
    expectEqual(V.siblings(artist: "丁世光", title: "Simon").isEmpty, true, "写法族: Simon 零候选")
    // 纯英文 feat 副题:只补一个「去副题」候选,不生成全角/半角括号族(那套只为
    // 含汉字歌名)。(2026-08-19 第二波推翻了此前"各来源写法一致、零候选"的假设 ——
    // 实测同一首歌带/不带 feat 后缀两本账,见 isCatalogNoiseSubtitle。)
    let featSibs = V.siblings(artist: "MJ", title: "Scream (feat. Janet Jackson)")
    expectEqual(featSibs.map(\.title), ["Scream"], "写法族: 纯英文 feat 副题只给去副题候选")
    // 无副题的繁体歌名仍然给繁简孪生
    let han = V.siblings(artist: "方大同", title: "我不是農人")
    expectEqual(han.first?.title ?? "", "我不是农人", "写法族: 无副题繁体名→繁简孪生")
    // 繁体+副题:括号族 + 繁简孪生都要在(封顶 6 装得下)
    let mixed = V.siblings(artist: "丁世光", title: "小師妹（Love Triangle）")
    expectEqual(mixed.count, 4, "写法族: 小師妹给 4 个候选")
    expectEqual(mixed.map(\.title).contains("小師妹(Love Triangle)"), true, "写法族: 半角无空格优先在列")
    expectEqual(mixed.map(\.title).contains("小师妹（Love Triangle）"), true, "写法族: 繁简孪生也在列")
    // 字形变体(麼 U+9EBC/麽 U+9EBD,2026-08-18 实测:70 条 scrobble 记在麽形下,
    // 括号/繁简候选全扑空——ICU t2s 两个都折到「么」,s2t 永远只生成「麼」,必须显式列表)
    let mo = V.siblings(artist: "丁世光", title: "愛在什麼地方都有（Love Is Everywhere）").map(\.title)
    expectEqual(mo.contains("愛在什麽地方都有(Love Is Everywhere)"), true,
                "写法族: 麼→麽 字形变体×半角括号(实测大头写法)")
    expectEqual(mo.count <= 6, true, "写法族: 麽族封顶 6,实际 \(mo.count)")
    expectEqual(V.siblings(artist: "X", title: "為你我受冷風吹").map(\.title).contains("爲你我受冷風吹"),
                true, "写法族: 无副题歌名也给字形变体(為/爲)")
}

// ---- PlayCountFold:写法索引的折叠键(2026-08-19,数据驱动合并的地基) ----
//
// 把历史上真实出现过的写法按这个键归族,查次数时按族查——取代猜枚举。断言覆盖实测
// 见过的全部分裂维度;「括号副题不折」是刻意取舍(括号常携带 Live/Remaster 版本信息)。
do {
    typealias F = PlayCountFold
    // 实测三形合一:全角麼 / 半角麽 / 简体小写半角(丁世光《愛在什麼地方都有》分裂案)
    let a = F.key(artist: "丁世光", title: "愛在什麼地方都有（Love Is Everywhere）")
    expectEqual(a, F.key(artist: "丁世光", title: "愛在什麽地方都有(Love Is Everywhere)"),
                "折叠键: 全角麼形 == 半角麽形")
    expectEqual(a, F.key(artist: "丁世光", title: "爱在什么地方都有(love is everywhere)"),
                "折叠键: == 简体小写半角形")
    // 双语拼接(R1):实测《月食 The Weeping Woman》30 次 vs《月食》6 次两族
    expectEqual(F.key(artist: "丁世光", title: "月食 The Weeping Woman"),
                F.key(artist: "丁世光", title: "月食"), "折叠键: CJK+拉丁双语拼接取 CJK 段")
    expectEqual(F.key(artist: "X", title: "P.S. 我愛你"),
                F.key(artist: "X", title: "我爱你"), "折叠键: 拉丁在前 CJK 在后也收敛")
    // 括号副题不折(版本信息)—— 与导出脚本同取舍
    expectNotEqual(F.foldTitle("一口(The Day You Left Me)"), F.foldTitle("一口"),
                   "折叠键: 括号副题不折")
    expectNotEqual(F.foldTitle("好的一天 (Live)"), F.foldTitle("好的一天"),
                   "折叠键: Live 版不并")
    // 空格/大小写/歌手繁简
    expectEqual(F.key(artist: "陶喆", title: "Susan 说"),
                F.key(artist: "陶喆", title: "susan说"), "折叠键: 空格与大小写")
    expectEqual(F.key(artist: "陳奕迅", title: "富士山下"),
                F.key(artist: "陈奕迅", title: "富士山下"), "折叠键: 歌手名繁简")
    // 段落交错的双语名不收敛(宁可漏合不错合)
    expectNotEqual(F.foldTitle("月食 The 月食 Woman"), F.foldTitle("月食"),
                   "折叠键: CJK/拉丁交错不折")

    // 再版噪音副题折叠(2026-08-19 用户实测:宇多田ヒカル Automatic 两本账)——
    // remaster 家族是同一份录音的目录学差异,折;真版本(Live/Remix)照旧分开。
    expectEqual(F.key(artist: "宇多田ヒカル", title: "Automatic (Remastered 2014)"),
                F.key(artist: "宇多田ヒカル", title: "Automatic"),
                "折叠键: (Remastered 2014) 并入本尊")
    expectEqual(F.foldTitle("Song (2014 Remaster)"), F.foldTitle("Song"),
                "折叠键: 年份在前的 Remaster 也并")
    expectEqual(F.foldTitle("Song (Remastered Version)"), F.foldTitle("Song"),
                "折叠键: Remastered Version 也并")
    expectEqual(F.foldTitle("月食 (Remastered)"), F.foldTitle("月食"),
                "折叠键: 中文歌名的再版噪音同样并")
    expectNotEqual(F.foldTitle("Song (Remix)"), F.foldTitle("Song"),
                   "折叠键: Remix 是真版本,不并")
    expectNotEqual(F.foldTitle("Song (Live 2014 Remaster)"), F.foldTitle("Song"),
                   "折叠键: 混着 Live 的副题不并(宁可漏合)")
    // 猜枚举兜底(索引未建成时)也要给纯拉丁歌名补「去副题」候选
    let autoSibs = PlayCountVariants.siblings(artist: "宇多田ヒカル",
                                              title: "Automatic (Remastered 2014)")
    expectEqual(autoSibs.contains { $0.title == "Automatic" }, true,
                "写法族: 纯拉丁 + 再版噪音副题给出去副题候选")

    // feat 客串署名家族(2026-08-19 第二波用户实测:王力宏《盖世英雄 (feat. 欧阳靖 &
    // 李岩)》第 2 次 vs《蓋世英雄》几十次)—— 署名是歌手信息不是版本,并入本尊。
    expectEqual(F.key(artist: "王力宏", title: "盖世英雄 (feat. 欧阳靖 & 李岩)"),
                F.key(artist: "王力宏", title: "蓋世英雄"),
                "折叠键: (feat. …) 并入本尊(含繁简)")
    expectEqual(F.foldTitle("完美的互动 (feat J-Lim & Rain)"), F.foldTitle("完美的互動"),
                "折叠键: 无点号的 feat 也并")
    expectEqual(F.foldTitle("Song (featuring X)"), F.foldTitle("Song"),
                "折叠键: featuring 全拼也并")
    expectEqual(F.foldTitle("Song (ft. X)"), F.foldTitle("Song"),
                "折叠键: ft. 缩写也并")
    expectNotEqual(F.foldTitle("Song (Feathers)"), F.foldTitle("Song"),
                   "折叠键: feat 开头的普通词不并")
    expectNotEqual(F.foldTitle("Song (feat.)"), F.foldTitle("Song"),
                   "折叠键: 空署名不并")

    // 补齐到参考实现 export-lastfm-tracks.py 的口径(2026-08-22)。三族都在那份
    // 2026-08-18 与用户逐对核定的规则里,Swift 侧此前漏搬 —— 不是新发明的规则。
    //
    // ① bonus track:用户报的原案。实测 Last.fm 两个实体「一路向北」14 次、
    //    「一路向北 (bonus track)」2 次,界面只显示 2。
    expectEqual(F.key(artist: "周杰倫", title: "一路向北 (bonus track)"),
                F.key(artist: "周杰伦", title: "一路向北"),
                "折叠键: (bonus track) 并入本尊(用户报的原案,含歌手繁简)")
    expectEqual(F.foldTitle("Song (Bonus Track)"), F.foldTitle("Song"),
                "折叠键: 大写 (Bonus Track) 同并")
    expectEqual(F.foldTitle("Song (Japanese Bonus Track)"), F.foldTitle("Song"),
                "折叠键: 带地区限定词的附加曲标记同并")
    expectEqual(F.foldTitle("Song (Bonus)"), F.foldTitle("Song"),
                "折叠键: 光写 (Bonus) 也并")
    // 白名单而不是 \w+ 的理由:带版本信息的必须挡住(宁可漏合)
    expectNotEqual(F.foldTitle("Song (Live Bonus Track)"), F.foldTitle("Song"),
                   "折叠键: 混着 Live 的附加曲标记不并")
    expectNotEqual(F.foldTitle("Song (Bonus Beats)"), F.foldTitle("Song"),
                   "折叠键: (Bonus Beats) 是混音,不并")
    // ② explicit:内容分级标记,无标记本尊通常就是这一版
    expectEqual(F.key(artist: "方大同", title: "无所谓 (Explicit)"),
                F.key(artist: "方大同", title: "無所謂"),
                "折叠键: (Explicit) 并入本尊(索引实测碰撞)")
    // 刻意不收 (Clean):消音版是另一份音频。索引里真有《Simple and Clean》,
    // 一旦哪天改成括号内子串匹配就会误伤它 —— 这两条断言就是那道栅栏。
    expectNotEqual(F.foldTitle("Song (Clean)"), F.foldTitle("Song"),
                   "折叠键: (Clean) 是另一份音频,不并")
    expectNotEqual(F.foldTitle("Song (Simple and Clean)"), F.foldTitle("Song"),
                   "折叠键: 副题里含 clean 的普通词不并")
    // ③ (with X):参考实现 T1 一直把 with 与 feat 并列。索引实测 7 例真碰撞
    expectEqual(F.key(artist: "周杰倫", title: "不該 (with aMEI)"),
                F.key(artist: "周杰倫", title: "不該"),
                "折叠键: (with X) 客串署名并入本尊(索引实测碰撞)")
    expectEqual(F.foldTitle("Toronto 2014 (with Mustafa)"), F.foldTitle("Toronto 2014"),
                "折叠键: 纯拉丁歌名的 (with X) 同并")
    // 「前缀后必须跟点/空格」那道守卫要同时挡住 without —— 少了它 (Without You) 会被剥
    expectNotEqual(F.foldTitle("Song (Without You)"), F.foldTitle("Song"),
                   "折叠键: (Without You) 不是署名,不并")
    expectNotEqual(F.foldTitle("Song (with)"), F.foldTitle("Song"),
                   "折叠键: with 后面空署名不并")
    // 参考实现「刻意不做」清单里的,这里也必须不折 —— 防后人顺手加进白名单
    expectNotEqual(F.foldTitle("Xscape (original version)"), F.foldTitle("Xscape"),
                   "折叠键: (original version) 是另一套制作,不并")
    expectNotEqual(F.foldTitle("Rock With You (single version)"), F.foldTitle("Rock With You"),
                   "折叠键: (single version) 单曲剪辑不并(用户未拍板)")
    expectNotEqual(F.foldTitle("愛情轉移(國)"), F.foldTitle("愛情轉移"),
                   "折叠键: (國) 语言标记不立通则(同名國/粵两版是真的两份录音)")
    // 猜枚举兜底同样要给附加曲标记补「去副题」候选(索引未建成时走这条)
    let bonusSibs = PlayCountVariants.siblings(artist: "周杰倫", title: "一路向北 (bonus track)")
    expectEqual(bonusSibs.contains { $0.title == "一路向北" }, true,
                "写法族: (bonus track) 给出去副题候选")

    // 剥掉目录学噪音之后不能让 R1 再把版本标记当译名吃掉(2026-08-22,补 bonus track
    // 那一族时用真索引实测出来的**回归**:方大同《悟空 2003 demo (bonus track)》
    // 剥完成 "悟空 2003 demo",R1 取 CJK 段 -> 并进《悟空》,Demo 是另一份录音)。
    expectNotEqual(F.key(artist: "方大同", title: "悟空 2003 demo (bonus track)"),
                   F.key(artist: "方大同", title: "悟空"),
                   "折叠键: 剥掉附加曲标记后 R1 不许把 Demo 版并进本尊")
    expectNotEqual(F.foldTitle("流沙 Live Version (Remastered)"), F.foldTitle("流沙"),
                   "折叠键: 派生串里的 Live Version 挡住 R1")
    // 但派生串**仍然要**走 R1 —— 这一条是真数据里存在的正例,别为了上面那条把它一起关掉
    expectEqual(F.key(artist: "丁世光", title: "低潮期 Tough Days (feat.葉喜兒)"),
                F.key(artist: "丁世光", title: "低潮期"),
                "折叠键: 剥掉 feat 后双语拼接名照旧收敛(实测正例)")
    // ---- 第三批(2026-08-22,用户拍板改口径)----
    // ⑥ R1 守卫**套到原串**:中文歌名的 Live/Demo 版不再被当译名收进录音室版。
    //    这一条此前反过来钉着「现状」(expectEqual),用户拍板后翻面 —— 见 foldTitle 注释。
    expectNotEqual(F.key(artist: "陶喆", title: "流沙 - Live"),
                   F.key(artist: "陶喆", title: "流沙"),
                   "折叠键: 中文歌名的 - Live 不再并进本尊")

    // ---- 第二批(2026-08-22,并行核实回来之后)----
    // ④ 破折号版本尾缀:参考实现 T2 的另一半(`Bad - 2012 Remaster = Bad`)。
    //    索引里 216 条 ` - ` 尾缀,只有 6 条能过 isCatalogNoiseSubtitle,4 例真并。
    expectEqual(F.key(artist: "Michael Jackson", title: "Bad - 2012 Remaster"),
                F.key(artist: "Michael Jackson", title: "Bad"),
                "折叠键: 破折号尾缀 - 2012 Remaster 并入本尊(索引实测碰撞)")
    expectEqual(F.foldTitle("Room 608 - Remastered"), F.foldTitle("Room 608"),
                "折叠键: 光写 - Remastered 也并")
    // 别把参考实现的 `\s*[-–]\s*` 照抄过来 —— 那个会把 Anti-Remastered 切成 Anti
    expectNotEqual(F.foldTitle("Anti-Remastered"), F.foldTitle("Anti"),
                   "折叠键: 破折号两侧必须有空白(Anti-Remastered 不许切)")
    // 其余 210 条破折号尾缀一条都不许动 —— 它们是真的不同录音
    expectNotEqual(F.foldTitle("Melody - Live"), F.foldTitle("Melody"),
                   "折叠键: - Live 不并(纯拉丁歌名)")
    expectNotEqual(F.foldTitle("Talking - Demo Version"), F.foldTitle("Talking"),
                   "折叠键: - Demo Version 不并")
    expectNotEqual(F.foldTitle("It's All Right With Me - Remastered 2006/Rudy Van Gelder Edition"),
                   F.foldTitle("It's All Right With Me"),
                   "折叠键: remaster 后面还跟别的词的尾缀不并(宁可漏合)")
    // 交替循环 + 剥完 trim 尾部连接符:两层一起掉,不留下 "x -"
    expectEqual(F.foldTitle("Song - 2012 Remaster (feat. Y)"), F.foldTitle("Song"),
                "折叠键: 破折号尾缀与括号副题交替剥(两层一起掉)")
    // 这一条才真正压在 trimTrailingJoiners 上:剥掉 (2012 Remaster) 之后剩 "Song -",
    // 而 dashSuffixSplit 要求破折号两侧都有空白、切不动它,不 trim 就落成 "song-"
    expectEqual(F.foldTitle("Song - (2012 Remaster)"), F.foldTitle("Song"),
                "折叠键: 剥完要擦掉本尊尾巴上的连接符")
    // ⑤ (with X) 头词黑名单:当下 0 命中,钉住是为了防将来爵士库那批 "with strings"
    expectEqual(F.foldTitle("不該 (with aMEI)"), F.foldTitle("不該"),
                "折叠键: 真人署名照旧折(黑名单不许误伤)")
    expectEqual(F.foldTitle("等你下课 (with 杨瑞代)"), F.foldTitle("等你下课"),
                "折叠键: 中文署名照旧折")
    expectNotEqual(F.foldTitle("Song (with strings)"), F.foldTitle("Song"),
                   "折叠键: (with strings) 是编配、另一份录音,不并")
    expectNotEqual(F.foldTitle("Song (with orchestra)"), F.foldTitle("Song"),
                   "折叠键: (with orchestra) 不并")
    expectNotEqual(F.foldTitle("Song (With or Without You)"), F.foldTitle("Song"),
                   "折叠键: (With or Without You) 是另一首歌的歌名词组,不并")
    expectNotEqual(F.foldTitle("Song (with backing vocals)"), F.foldTitle("Song"),
                   "折叠键: (with backing vocals) 不并")
    // feat 家族不受黑名单影响(它后面语法上只能跟表演者)
    expectEqual(F.foldTitle("Song (feat. The Weeknd)"), F.foldTitle("Song"),
                "折叠键: feat. 后面跟 The 照旧折(黑名单只管 with)")

    // 第三批续:R1 守卫全覆盖之后的连带断言
    expectNotEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音"),
                   "折叠键: 方括号 Live 尾缀也不并进本尊")
    expectNotEqual(F.foldTitle("飛機場的10:30 - Demo Version"), F.foldTitle("飛機場的10:30"),
                   "折叠键: - Demo Version 不并进本尊")
    expectNotEqual(F.foldTitle("Melody - Live"), F.foldTitle("Melody"),
                   "折叠键: 英文歌名的 - Live 照旧分开(中英口径现在一致)")
    // 两个重度退化键:多首**不同的歌**曾被折进同一族
    expectNotEqual(F.key(artist: "方大同", title: "All Night - Live版"),
                   F.key(artist: "方大同", title: "Ten Reasons - Live版"),
                   "折叠键: 三首 - Live版 不再焊成同一族")
    expectNotEqual(F.foldTitle("All Night - Live版"), F.foldTitle("Live版"),
                   "折叠键: - Live版 不再退化成光剩版本词")
    expectNotEqual(F.foldTitle("Something Stupid [Live 08] featuring 薛凱琪"),
                   F.foldTitle("薛凱琪"),
                   "折叠键: 方括号不在结尾时也不许退化成尾部人名")
    // ⑦ 版本尾缀分隔符归一:分隔符不携带信息,副题内容才携带
    // ⚠️ 裸场次标记**不**归一(2026-08-22 并行核实推翻了原设计):album.getinfo 实测
    //    方大同 21 条 `X - Live` 与《This Love Live 2007》21 首曲目完全双射,而 30 条
    //    `X (Live)` 只有 2 首在那张里 —— 两种写法是**两场不同的演唱会**,归一会错并。
    expectNotEqual(F.foldTitle("流沙 - Live"), F.foldTitle("流沙 (Live)"),
                   "折叠键: 裸 Live 不归一(两种写法可能是两场不同演唱会)")
    expectNotEqual(F.foldTitle("南音 [Live]"), F.foldTitle("南音 - Live"),
                   "折叠键: 裸 Live 的方括号形也不归一")
    // 但**带场次信息**的照旧归一 —— 那个内容真的标识了一场演出
    expectEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音 - Live 08"),
                "折叠键: 带场次信息的版本尾缀照旧归一")
    expectEqual(F.foldTitle("南音 - 15 Khalil Live in HK 2011"),
                F.foldTitle("南音 (15 Khalil Live in HK 2011)"),
                "折叠键: 具名演唱会尾缀照旧归一")
    // 两场不同演唱会绝不能并
    expectNotEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音 - Live"),
                   "折叠键: Live 08 与裸 Live 不并")
    expectEqual(F.foldTitle("沙灘 - 鋼琴版"), F.foldTitle("沙滩 (钢琴版)"),
                "折叠键: 中文版本词的分隔符也归一(整串以「版」收尾)")
    expectEqual(F.foldTitle("Rock With You - Single Version"),
                F.foldTitle("Rock With You (single version)"),
                "折叠键: single version 的分隔符归一")
    expectEqual(F.foldTitle("逗陣兄弟 - 獨唱版"), F.foldTitle("逗阵兄弟 (独唱版)"),
                "折叠键: 獨唱版 分隔符归一")
    expectNotEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音 [Timeless Live 2009]"),
                   "折叠键: 两场不同演唱会不并")
    // 译名尾缀要留给 R1 收敛,不能被分隔符归一截走
    expectEqual(F.foldTitle("月食 - The Weeping Woman"), F.foldTitle("月食"),
                "折叠键: 破折号接的是**译名**时照旧走 R1 收敛")
    // 单字中文歌名 + 英文尾缀靠 collapseBilingual 里 `han.count >= 2` 那道下限活着,
    // 不是靠版本守卫 —— 那条下限别动(并行核实点出来的)
    expectNotEqual(F.foldTitle("鬼 - Overture"), F.foldTitle("鬼"),
                   "折叠键: 单字中文歌名不被 R1 吞掉(han.count >= 2 下限)")
    // dashSuffixSplit 必须取**最后**一个分隔符:Foundation 里 .backwards 与
    // .regularExpression 同用时不生效,实测返回第一个匹配
    expectEqual(F.foldTitle("苏州河 - 慕容雪 - Mandarin Version"),
                F.foldTitle("苏州河 - 慕容雪 (Mandarin Version)"),
                "折叠键: 多破折号时取最后一个分隔符")
    // 中文最常用的 version 一词以「本」收尾,hasSuffix(\"版\") 接不住,要单独判
    expectEqual(F.foldTitle("你不知道的事 - 宋曉青版本"),
                F.foldTitle("你不知道的事 (宋晓青版本)"),
                "折叠键: 「…版本」也算版本尾缀")
    // 归一之后必须再剥一次目录学噪音,否则方括号 remaster 会从本尊拆出去
    expectEqual(F.foldTitle("一口 [Remastered 2014]"), F.foldTitle("一口"),
                "折叠键: 方括号 remaster 归一后被补剥掉,不从本尊拆出去")
    // `Live版` 是一个词,词表接不住 —— 靠「以 版 收尾」这条判据挡住 R1 的退化
    expectNotEqual(F.foldTitle("All Night - Live版"), F.foldTitle("Live版"),
                   "折叠键: Live版 靠「以 版 收尾」判据挡住 R1 退化")
    // ⑧ 罗马字歌手名折到中文本名(只作用在查族用的 familyKey 上)
    expectEqual(F.familyKey(artist: "David Tao", title: "找自己"),
                F.familyKey(artist: "陶喆", title: "找自己"),
                "查族键: David Tao 与 陶喆 同族")
    expectEqual(F.familyKey(artist: "Jay Chou", title: "不該"),
                F.familyKey(artist: "周杰倫", title: "不该"),
                "查族键: Jay Chou 与 周杰倫 同族(叠繁简)")
    expectEqual(F.familyKey(artist: "Hikaru Utada", title: "Automatic"),
                F.familyKey(artist: "宇多田光", title: "Automatic"),
                "查族键: 罗马字与汉字写法同族")
    expectEqual(F.familyKey(artist: "宇多田ヒカル", title: "Automatic"),
                F.familyKey(artist: "宇多田光", title: "Automatic"),
                "查族键: 片假名与汉字写法同族")
    // 别名匹配必须是**整串相等** —— 索引里真有 Count Basie,子串匹配会被 asi 命中
    expectNotEqual(F.familyKey(artist: "Count Basie", title: "X"),
                   F.familyKey(artist: "阿肆", title: "X"),
                   "查族键: 别名整串相等,Count Basie 不许被 asi 命中")
    expectNotEqual(F.familyKey(artist: "Fantasia", title: "X"),
                   F.familyKey(artist: "阿肆", title: "X"),
                   "查族键: Fantasia 也不许被 asi 命中(索引里真有这个艺人)")
    // 刻意剔掉的两条别名:Last.fm 侧是「同名多人」或混杂实体,理由见 romanizedArtistAliases
    expectNotEqual(F.familyKey(artist: "Jason Chan", title: "你瞒我瞒"),
                   F.familyKey(artist: "陳柏宇", title: "你瞒我瞒"),
                   "查族键: jasonchan 刻意不入表(Last.fm 标注同名多人)")
    expectNotEqual(F.familyKey(artist: "Kun", title: "Jasmine"),
                   F.familyKey(artist: "蔡徐坤", title: "Jasmine"),
                   "查族键: kun 刻意不入表(3 字符键 + 实体混杂)")
    // familyKey 仍要做合唱归首位(2026-08-20 那条能力不能丢)
    expectEqual(F.familyKey(artist: "Daniel Caesar & Mustafa", title: "Toronto 2014"),
                F.familyKey(artist: "Daniel Caesar", title: "Toronto 2014"),
                "查族键: 合唱 credit 仍归首位")
    // 表里没有的歌手不受影响;表里有的必须真被改写(否则等于没接上)
    expectEqual(F.familyKey(artist: "Michael Jackson", title: "Bad"),
                F.key(artist: "Michael Jackson", title: "Bad"),
                "查族键: 不在别名表里的歌手与 key 一致")
    expectNotEqual(F.familyKey(artist: "David Tao", title: "找自己"),
                   F.key(artist: "David Tao", title: "找自己"),
                   "查族键: 在表里的歌手必须真被改写")
    // 端到端:别名 + ArtistCredit 左词边界两个修法都到位,蛋堡才合得上
    expectEqual(F.familyKey(artist: "Soft Lipa", title: "偷偷"),
                F.familyKey(artist: "蛋堡", title: "偷偷"),
                "查族键: Soft Lipa 与 蛋堡 同族(要 ArtistCredit 边界守卫先修好)")
}

// ---- 署名行过滤第七轮(2026-08-16):带分隔符的中文标签 + 纯英文无冒号 ----
do {
    typealias E = LyricsSyncEngine
    // 用户报的两行,都出现在歌曲**末尾**
    expectEqual(E.matchesRoleWordCredit("录音师/录音室：王力宏/Homeboy Studios, Taipei, Taiwan"), true,
                "署名行: 标签含斜杠(录音师/录音室)")
    expectEqual(E.matchesEnglishCredit("Mixed by Wang Leehom at Homeboy Music Studios"), true,
                "署名行: 纯英文无冒号(Mixed by ...)")
    // 同形态的其它写法
    expectEqual(E.matchesRoleWordCredit("作词&作曲：某人"), true, "署名行: 标签含 &")
    expectEqual(E.matchesRoleWordCredit("混音、母带：某人"), true, "署名行: 标签含顿号")
    expectEqual(E.matchesEnglishCredit("Produced by Someone"), true, "署名行: Produced by")
    expectEqual(E.matchesEnglishCredit("Recorded at Abbey Road"), true, "署名行: Recorded at")

    // ⚠️ 不能误杀的:这些是真歌词
    expectEqual(E.matchesEnglishCredit("a song written by fate"), false, "真歌词: written by 出现在句中不算")
    expectEqual(E.matchesEnglishCredit("Music makes me lose control"), false, "真歌词: 以 Music 开头但没有 by/at")
    expectEqual(E.matchesRoleWordCredit("他说：我不走"), false, "真歌词: 带冒号的对白")
    expectEqual(E.matchesRoleWordCredit("曲婉婷："), false, "对唱标签: 冒号后没内容")
}

// ---- EnrichCacheReader.artistTitleKey:「最近播放」封面的本机兜底键(2026-08-14) ----
//
// 这个键两头用:建索引时喂的是**缓存 key 里已经归一化过**的歌名,查询时喂的是 Last.fm
// scrobble 里**播放器原样上报**的歌名。两头必须落到同一个字符串,带译名的那类歌名才能
// 命中本机封面 —— 否则这条兜底对整张《神經志 The Journal》这种"歌名带英文译名"的专辑
// 全部失效,而那正是 Last.fm 最容易缺图的一类。
do {
    let R = EnrichCacheReader.self
    expectEqual(R.artistTitleKey(artist: "陶喆", title: "聖誕之吻"), "陶喆|聖誕之吻",
                "封面兜底键: 基本形")
    // 大小写/首尾空白不算差异(跟 LastfmStatsService.playCountKey 同口径)
    expectEqual(R.artistTitleKey(artist: "  Prince ", title: " Kiss "), "prince|kiss",
                "封面兜底键: 去空白转小写")
    // 关键:两头喂不同拼法要落到同一个键
    expectEqual(
        R.artistTitleKey(artist: "丁世光", title: "不散的筵席（I Miss You）"),
        R.artistTitleKey(artist: "丁世光", title: "不散的筵席"),
        "封面兜底键: 带译名的原始歌名跟归一化后的歌名落到同一个键"
    )
    // 版本标记仍然要区分开 —— 现场版跟录音室版是两首,不该共用封面
    expectEqual(
        R.artistTitleKey(artist: "周杰伦", title: "告白气球 (Live)") != R.artistTitleKey(artist: "周杰伦", title: "告白气球"),
        true, "封面兜底键: 版本标记仍然区分"
    )
}

// ---- LyricsColumnWidths: 「歌词管理」可拖拽列宽的夹值逻辑(2026-08-05) ----
//
// 三条分隔条语义不对称:第 0 条(歌名|歌手)左边是弹性的歌名列,只能改「歌手」、由歌名被动
// 吸收;第 1/2 条是标准的"此消彼长、总宽不变"。夹值要同时守住三件事:每列不低于自己的下限、
// 歌名不低于 minTitle、单列不超过 maxColumn。

do {
    let W = LyricsColumnWidths.self
    let d = W.defaults
    // 一组够宽、好心算的输入。(调用方现在传的是"行内容宽度 + 三个列间距",chrome = 24;
    // 这里取 48 只是为了让下面几条上下限的算术好对,纯函数对 chrome 取值没有假设。)
    let total: CGFloat = 630, chrome: CGFloat = 48

    // 第 0 条:边界右移 = 歌名变宽 → 歌手变窄(减号方向不能搞反)
    expectEqual(
        W.dragged(from: d, divider: 0, dx: 20, totalWidth: total, chrome: chrome).artist,
        d.artist - 20, "列宽: 拖第0条向右 → 歌手变窄(歌名吸收)"
    )
    expectEqual(
        W.dragged(from: d, divider: 0, dx: -20, totalWidth: total, chrome: chrome).artist,
        d.artist + 20, "列宽: 拖第0条向左 → 歌手变宽"
    )
    // 第 0 条只动歌手,不该碰专辑/来源
    do {
        let r = W.dragged(from: d, divider: 0, dx: 30, totalWidth: total, chrome: chrome)
        expectEqual(r.album, d.album, "列宽: 拖第0条不影响专辑")
        expectEqual(r.source, d.source, "列宽: 拖第0条不影响来源")
    }
    // 下限:再怎么拖也不低于 minColumn
    expectEqual(
        W.dragged(from: d, divider: 0, dx: 9999, totalWidth: total, chrome: chrome).artist,
        W.minColumn, "列宽: 第0条拖到底停在列下限"
    )
    // 上限:歌名必须留住 minTitle —— 630-48-140-110-84 = 248,但单列上限 280 更宽松,取 248
    expectEqual(
        W.dragged(from: d, divider: 0, dx: -9999, totalWidth: total, chrome: chrome).artist,
        total - chrome - W.minTitle - d.album - d.source, "列宽: 第0条反向拖到底时歌名仍保住 minTitle"
    )
    // 可用宽度很小时上下限打角:结果必须仍 >= minColumn(不能返回比下限还小的值)
    expectEqual(
        W.dragged(from: d, divider: 0, dx: -9999, totalWidth: 200, chrome: chrome).artist >= W.minColumn,
        true, "列宽: 可用宽度过小时不返回小于下限的值"
    )
    // 还没量到可用宽度(totalWidth = 0,首帧或列表一行都没有)时仍然要拖得动:照常算
    // room 会得到负数,clamp 里 hi < lo 直接返回下限,表现成"一拖歌手就弹到最窄"
    expectEqual(
        W.dragged(from: d, divider: 0, dx: -20, totalWidth: 0, chrome: chrome).artist,
        d.artist + 20, "列宽: 尚未量到宽度时第0条仍按位移变宽"
    )
}

do {
    let W = LyricsColumnWidths.self
    let d = W.defaults
    let total: CGFloat = 630, chrome: CGFloat = 48

    // 第 1 条(歌手|专辑):此消彼长,两列之和不变 → 歌名宽度完全不受影响
    do {
        let r = W.dragged(from: d, divider: 1, dx: 25, totalWidth: total, chrome: chrome)
        expectEqual(r.artist, d.artist + 25, "列宽: 拖第1条向右 → 歌手变宽")
        expectEqual(r.album, d.album - 25, "列宽: 拖第1条向右 → 专辑同量变窄")
        expectEqual(r.artist + r.album, d.artist + d.album, "列宽: 第1条保持两列总宽不变(歌名不受影响)")
        expectEqual(r.source, d.source, "列宽: 拖第1条不影响来源")
    }
    // 第 1 条拖到底:专辑落到下限,总宽仍不变
    do {
        let r = W.dragged(from: d, divider: 1, dx: 9999, totalWidth: total, chrome: chrome)
        expectEqual(r.album, W.minColumn, "列宽: 第1条拖到底时专辑停在下限")
        expectEqual(r.artist + r.album, d.artist + d.album, "列宽: 第1条拖到底仍保持总宽不变")
    }
    // 第 2 条(专辑|来源):来源列有更高的下限(要放得下胶囊徽章)
    do {
        let r = W.dragged(from: d, divider: 2, dx: 9999, totalWidth: total, chrome: chrome)
        expectEqual(r.source, W.minSourceColumn, "列宽: 第2条拖到底时来源停在它专属的更高下限")
        expectEqual(r.album + r.source, d.album + d.source, "列宽: 第2条拖到底仍保持总宽不变")
    }
}

do {
    let W = LyricsColumnWidths.self
    let chrome: CGFloat = 48
    // fitted:窗口够宽时原样返回,不动用户存下来的值
    expectEqual(W.fitted(W.defaults, totalWidth: 900, chrome: chrome), W.defaults, "列宽: 窗口够宽时 fitted 原样返回")
    // headerWidth 还没量到(0)时也原样返回,首帧不会算出奇怪的宽度
    expectEqual(W.fitted(W.defaults, totalWidth: 0, chrome: chrome), W.defaults, "列宽: 尚未量到宽度时 fitted 不做收敛")
    // 三列都拖得很宽之后把窗口拖窄:必须等比收敛到"歌名刚好还有 minTitle"
    do {
        let wide = LyricsColumnWidths(artist: 240, album: 240, source: 200)
        let r = W.fitted(wide, totalWidth: 600, chrome: chrome)
        expectEqual(r.total <= 600 - chrome - W.minTitle + 0.001, true, "列宽: 变窄后收敛到歌名保住 minTitle")
        expectEqual(r.artist >= W.minColumn && r.album >= W.minColumn && r.source >= W.minSourceColumn,
                    true, "列宽: 收敛后每列仍不低于各自下限")
    }
    // 极窄到连三列下限都塞不下 → 全部回落下限(宁可挤窄歌名,也不让某列消失)
    do {
        let r = W.fitted(W.defaults, totalWidth: 240, chrome: chrome)
        expectEqual(r, LyricsColumnWidths(artist: W.minColumn, album: W.minColumn, source: W.minSourceColumn),
                    "列宽: 极窄时全部回落到各列下限")
    }
}

// 「列宽拖不动」的回归(2026-08-14)。
//
// 现场:侧栏实际渲染宽度约 725pt、行内容占 [11.5, 725],UserDefaults 里存的是
// 56 / 137.66796875 / 70,而截图逐像素量出来专辑列只有 56 —— 三列被恒定钳在各自下限,
// 往哪个方向拖都纹丝不动(拖动其实写进去了,只是渲染这一步把它抹平成同一组常量)。
//
// 根因不在这几个纯函数里,而在调用方喂进来的宽度:当时 totalWidth 取自另一个 @State
// (表头 .background 里 GeometryReader + onChange 量的 headerWidth),它停在首帧的窄值
// ≤218pt 再没更新过。现在只剩 rowContentBounds 一个几何输入(走 PreferenceKey,布局
// 每跑一遍都重报)。下面两条把"同一份数据、两种宽度"的结果各自钉死,免得以后再冒出
// 第二个测量、又悄悄退回这个状态。
do {
    let W = LyricsColumnWidths.self
    let stored = LyricsColumnWidths(artist: 56, album: 137.66796875, source: 70)
    let floors = LyricsColumnWidths(artist: W.minColumn, album: W.minColumn, source: W.minSourceColumn)

    // 修好之后:宽度取自行内容边界(725 - 11.5 ≈ 713),chrome 只剩三个 8pt 列间距
    expectEqual(W.fitted(stored, totalWidth: 713, chrome: 8 * 3), stored,
                "列宽: 按行内容宽度算时,存下来的列宽原样渲染")
    // 出问题时:宽度停在首帧的 218pt,budget 掉到三列下限之和以下 → 恒定输出下限,
    // 存进去的值完全影响不了画面,也就是用户看到的"拖不动"
    expectEqual(W.fitted(stored, totalWidth: 218, chrome: 36), floors,
                "列宽: 宽度测量失效时会被钳成常量(记录当时的错误现象)")
}

do {
    let W = LyricsColumnWidths.self
    // sanitized:挡住手改 UserDefaults / 老版本残留写进来的非法值,整组退回默认
    expectEqual(W.sanitized(W.defaults), W.defaults, "列宽: 合法值原样通过")
    expectEqual(W.sanitized(LyricsColumnWidths(artist: 0, album: 110, source: 84)), W.defaults, "列宽: 0 宽度整组退回默认")
    expectEqual(W.sanitized(LyricsColumnWidths(artist: -50, album: 110, source: 84)), W.defaults, "列宽: 负宽度整组退回默认")
    expectEqual(W.sanitized(LyricsColumnWidths(artist: 5000, album: 110, source: 84)), W.defaults, "列宽: 超过单列上限整组退回默认")
    expectEqual(W.sanitized(LyricsColumnWidths(artist: .nan, album: 110, source: 84)), W.defaults, "列宽: NaN 整组退回默认")
    expectEqual(W.sanitized(LyricsColumnWidths(artist: .infinity, album: 110, source: 84)), W.defaults, "列宽: 无穷大整组退回默认")
    // 来源列卡在普通下限与它专属下限之间(56~70)也算非法 —— 徽章会被截断
    expectEqual(W.sanitized(LyricsColumnWidths(artist: 96, album: 110, source: 60)), W.defaults, "列宽: 来源列低于专属下限整组退回默认")
}

// ---- LyricsSyncEngine: 署名行的结构化判定(2026-08-05) ----
//
// 上面那张关键词表已经补过至少两轮(两字全称 → 单字缩写 → "Arranged by:" 这种夹 by 的
// 写法),每次都是被漏判的真实数据打回来才加的,说明枚举法在这件事上收敛不了。补一条认
// "短汉字标签 + 冒号 + 内容"这个形状的规则,跟 collector 侧 genericHanCreditLineRe 对齐。
// 关键是**不能误杀真歌词**,所以下面正反两个方向都要覆盖。

do {
    let engine = LyricsSyncEngine()
    // 关键词表里没有的角色名(指挥/中提琴/母带),靠结构判定认出来
    let lrc = "[00:00.00]指挥：某人\n[00:01.00]中提琴：某人\n[00:02.00]母带工程师：某人\n[00:26.74]la la la\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 500)?.mainText, nil, "署名行(结构): 关键词表外的角色名也被判成署名行")
    expectEqual(engine.activeLine(atMs: 27000)?.mainText, "la la la", "署名行(结构): 真歌词不受影响")
    expectEqual(engine.allLines(idPrefix: "t").count, 1, "署名行(结构): 三行职员表全被剔除,只剩 1 行真歌词")
}

do {
    let engine = LyricsSyncEngine()
    // ⚠️ 反向:正常歌词里带冒号不能被误杀。这是收窄规则(只认汉字标签、上限 8 字、冒号后
    // 必须有非空白内容)真正要守住的东西——用宽松的 `^.{1,20}[:：].+` 会把这些全吃掉。
    let lrc = """
    [00:10.00]他说：我不走
    [00:20.00]1、2、3：走
    [00:30.00]Verse 1: hello
    [00:40.00]这是一句很长的歌词不是标签所以不该被当成署名行：后面还有内容
    """
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.activeLine(atMs: 11000)?.mainText, "他说：我不走", "署名行(结构): 对白式冒号不误杀")
    expectEqual(engine.activeLine(atMs: 21000)?.mainText, "1、2、3：走", "署名行(结构): 数字编号标签不误杀(只认汉字标签)")
    expectEqual(engine.activeLine(atMs: 31000)?.mainText, "Verse 1: hello", "署名行(结构): 英文场景标签不误杀")
    expectEqual(engine.allLines(idPrefix: "t").count, 4, "署名行(结构): 四句正常歌词一句都没被剔除")
}

do {
    // 边界:结构化规则要求"命中 ≥3 行 **且** 过半"。这两条各自单独都不够——
    // ① 只看比例:短曲里一句对白就过半;② 只看行数:长歌里三句对白就被误杀。
    let engine = LyricsSyncEngine()
    // 3 句对白 + 7 句正常歌词 = 命中 3 行达到下限,但只占 3/10 没过半 → 规则不启用,一句不删
    var lines = ["他说：走", "她说：不走", "我说：算了"]
    for i in 0..<7 { lines.append("普通歌词第\(i)句") }
    let lrc = lines.enumerated().map { "[00:\(String(format: "%02d", $0.offset + 10)).00]\($0.element)" }.joined(separator: "\n")
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.allLines(idPrefix: "t").count, 10, "署名行(结构): 命中够 3 行但没过半 → 规则不启用,10 句全留")
}

do {
    // 反过来:过半但不够 3 行 → 同样不启用。必须构造成"只有行数这一个条件不满足",否则
    // 测不出这一支——2 行里 1 行命中时 hits*2 > count 是 2 > 2 = false(代码用严格大于),
    // 两个条件同时不满足,断言就算把 `hits >= 3` 删掉也照样通过,等于空转。
    // 3 行里 2 行命中:4 > 3 过半成立,hits=2 < 3 不成立 → 恰好只卡在行数这一条。
    let engine = LyricsSyncEngine()
    let lrc = "[00:10.00]他说：走\n[00:20.00]她说：不走\n[00:30.00]普通歌词\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.allLines(idPrefix: "t").count, 3, "署名行(结构): 过半但不够 3 行 → 规则不启用,3 句全留")
}

do {
    // 审查确认的 IMPORTANT 的回归测试:对唱/口白类 LRC 把**每一句**都标成「男：/女：/合：」,
    // 形状 100% 命中结构正则,"命中 ≥3 行且过半"那道门反而天然被满足 → 整首歌被删空。
    // 说话人标签因此必须整体豁免(既不算 hits、也不会被删)。
    let engine = LyricsSyncEngine()
    let lrc = """
    [00:10.00]男：第一句
    [00:20.00]女：第二句
    [00:30.00]合：第三句
    [00:40.00]男：第四句
    [00:50.00]女：第五句
    """
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.allLines(idPrefix: "t").count, 5, "署名行(结构): 对唱标签(男/女/合)整份豁免,5 句一句不删")
    // 2026-08-14 起前缀不再画在界面上:它被剥进 side 字段用来做左右分栏(见 LyricDuet)。
    // 这条断言原来钉的是 "男：第一句" —— 那正是改动之前的行为(标记直接显示成歌词的一部分,
    // 当前行的逐字填色还会从"男："开始扫)。它保护的"对唱句不能被署名过滤器删掉"这层意思
    // 没变(上面那条 count == 5 才是),这里只是把展示形态更新到新行为。
    expectEqual(engine.activeLine(atMs: 11000)?.mainText, "第一句", "署名行(结构): 对唱句正常展示(前缀已剥)")
    expectEqual(engine.activeLine(atMs: 11000)?.side, .leading, "对唱: 男(先出现)靠左")
    expectEqual(engine.activeLine(atMs: 21000)?.side, .trailing, "对唱: 女(后出现)靠右")
    expectEqual(engine.activeLine(atMs: 31000)?.side, .center, "对唱: 合唱居中")
}

do {
    // 兜底闸门:万一判据出了没预料到的偏差、把整份都判成职员表,展示过滤也不许删空——
    // "整片空白/一直显示♪"比"多显示几行职员表"糟糕得多。用关键词表能全命中的一份来验
    // (关键词表是逐行无条件生效的,不受整份门控影响)。
    let engine = LyricsSyncEngine()
    let lrc = "[00:10.00]作词：甲\n[00:20.00]作曲：乙\n[00:30.00]编曲：丙\n"
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
    expectEqual(engine.allLines(idPrefix: "t").count, 3, "署名行: 会被删空时整份不删(宁可漏治,不可删空)")
}

// ---- LocalPlaybackSource: seek 之后丢弃陈旧位置读数(2026-08-05) ----
//
// 审查确认的 IMPORTANT:seek 发出去之后,在飞的那次 poll(子进程往返几十到几百毫秒)拿到的
// 是 seek **之前**的位置,落地后会被当成"真实 seek 跳变"硬重锚回旧位置——松手跳过去、一瞬间
// 又弹回来。除了作废在飞的 poll(pollGeneration),还需要这道判据兜住"seek 之后新发起、但
// 播放器状态还没跟上"的那些读数(Music.app 实测要 ~294ms 才切换)。

do {
    let f = LocalPlaybackSource.shouldRejectStalePositionAfterSeek
    // 从 30s 拖到 120s,读数还是 30s → 更靠近旧位置 → 丢弃
    expectEqual(f(30.2, 120, 30, 0.1), true, "seek 静默窗: 读数还在旧位置附近 → 丢弃")
    // 读数已经跟上目标 → 接受
    expectEqual(f(120.3, 120, 30, 0.1), false, "seek 静默窗: 读数已跟上目标 → 接受")
    // 窗口过了就一律接受,不能永久拒收(否则真的 seek 到别处就再也纠正不回来)
    expectEqual(f(30.2, 120, 30, 5.0), false, "seek 静默窗: 超出窗口后不再拦")
    // 小幅拖动:从 100s 拖到 100.5s,读数 100.0 更靠近旧位置 → 丢弃
    // (这一支很重要:Apple Music 是 preciseSource,servo 门槛只有 0.15s,不拦就会被
    //  snap 回旧位置,根本用不着超过 2s 的 seek 容差)
    expectEqual(f(100.0, 100.5, 100, 0.1), true, "seek 静默窗: 小幅拖动同样要拦")
    // 正好等距时不丢——拖动幅度极小时两者本来分不开,丢了反而卡住自愈
    expectEqual(f(75, 100, 50, 0.1), false, "seek 静默窗: 与新旧位置等距时不拦")
    // 负的 elapsed(时钟回跳)不拦
    expectEqual(f(30, 120, 30, -1), false, "seek 静默窗: 时间差为负时不拦")
}

// ---- MusicPlaybackController.seek: 参数格式化与夹值(2026-08-05) ----
//
// seek 的 I/O(发 AppleScript / 跑 media-control)没法在 selftest 里跑,但"传进去的数值
// 长什么样"是纯计算、而且是最容易出错的地方:直接插值 Double 可能吐出
// "2.2000000000000002" 这种长尾表示,拼进 AppleScript 源码里不保险。

do {
    let arg = MusicPlaybackController.seekArgument(forSeconds:)
    expectEqual(arg(2.2), "2.200", "seek: 浮点长尾被截成 3 位小数")
    expectEqual(arg(255.4567), "255.457", "seek: 四舍五入到毫秒精度")
    expectEqual(arg(0), "0.000", "seek: 0 正常")
    expectEqual(arg(-5), "0.000", "seek: 负值夹到 0")
    // 上界故意不夹(这一层不知道时长),原样透给播放器
    expectEqual(arg(99999.5), "99999.500", "seek: 上界不夹,原样透传")
    // 非有限值(比例算式里 0 除 0 之类)不能拼出 "nan"/"inf" 进 AppleScript
    expectEqual(arg(.nan), "0.000", "seek: NaN 退化成 0 而不是拼出 nan")
    expectEqual(arg(.infinity), "0.000", "seek: 无穷大退化成 0")
    // 钉住"小数点必须是点"。实测核实过 String(format:) 不带 locale 本来就不本地化,所以
    // 这条不是在防一个现存 bug,而是防以后有人顺手把 locale 改成 .current —— 那样在逗号
    // 小数点的区域会拼出 "2,200",AppleScript 直接语法错误。
    expectEqual(arg(2.2).contains(","), false, "seek: 小数点固定用点(拼进 AppleScript 不能是逗号)")
}

// ── 逐字数据退化时必须退回整行模式(2026-08-06) ──
// 实测过的真实形态:某些源给的 YRC 只包含开头的署名行,正文一行都没有;署名行被过滤后
// wordLines 只剩极少几行,而 activeLine 取的是"时间戳 <= 当前位置的最后一行",于是整首歌
// 从头到尾都停在那一行上。判据是覆盖率,不是"YRC 是否为空"。
do {
    let yrc = [
        "[60,900](60,400,0)特别的人 - 方大同",
        "[1110,600](1110,600,0)词：方大同",
        "[1760,600](1760,600,0)曲：方大同",
    ].joined(separator: "\n")
    var lrcLines: [String] = []
    for i in 0..<10 {
        lrcLines.append("[00:" + String(format: "%02d", i * 5) + ".000]第 " + String(i) + " 句歌词")
    }
    let lrc = lrcLines.joined(separator: "\n")

    let engine = LyricsSyncEngine()
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
    // 3 行逐字 vs 10 行整行 → 覆盖率不足,退回整行;45 秒处应命中第 9 句
    expectEqual(engine.activeLine(atMs: 45_000)?.plainText, "第 9 句歌词", "逐字数据退化时退回整行歌词")

    // 没有整行歌词可退时仍然用逐字数据(不能因为覆盖率判据把唯一的内容也否掉)
    let onlyWords = LyricsSyncEngine()
    onlyWords.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
    expectEqual(onlyWords.hasContent, true, "没有整行歌词时仍使用逐字数据")
}

// ---- 汇总 ----


// 2026-08-09 用户报的真实 bug:日文行里的汉字被按普通话读成了拼音。
// Any-Latin 对汉字一律出拼音,不看上下文是不是日语 —— 日文必须走形态分析。
expectEqual(
    Romanizer.romanize("火曜日の朝は", japanese: true)?.contains("kayou") ?? false, true,
    "Romanizer: 日文汉字要按日语读音(火曜日 → kayou…),不是拼音")
expectEqual(
    Romanizer.romanize("火曜日の朝は", japanese: true)?.contains("huǒ") ?? true, false,
    "Romanizer: 日文行里绝不能出现普通话拼音")
expectEqual(
    Romanizer.romanize("君のことが好きだから", japanese: true), "kimi no koto ga suki da kara",
    "Romanizer: 整句日文读音")
// 促音「っ」被 ICU 单独转写成字面的 "~tsu",必须合并成双写辅音,不能露给用户。
expectEqual(
    Romanizer.romanize("取った", japanese: true)?.contains("~tsu") ?? true, false,
    "Romanizer: 促音记号不能出现在结果里")
expectEqual(
    Romanizer.romanize("取った", japanese: true), "totta",
    "Romanizer: 促音合并成双写辅音")
// 非日文仍然走 Any-Latin —— 谚文/泰文/西里尔跟汉字没有交集,音译对它们本来就是对的。
expectEqual(
    Romanizer.romanize("사랑해") != nil, true, "Romanizer: 韩文仍然照常音译")
// 日文歌里夹的纯英文行不该被分词器加一堆空格当成"罗马音"
expectEqual(
    Romanizer.romanize("Baby I love you", japanese: true), nil,
    "Romanizer: 日文歌里的英文行没有罗马音可言")


// 逐词罗马音的分组:分词器的片段边界跟歌词源的逐字切分不一定对齐,分组必须两个方向都兜住。
do {
    func w(_ t: String, _ s: Int, _ d: Int) -> SyncedLyricWord {
        SyncedLyricWord(text: t, startMs: s, durationMs: d)
    }
    // 酷狗常见的切法:一个汉字/假名一个词。「いつか」在分词器眼里是一个词,必须并成一组。
    let words = [w("い", 0, 100), w("つ", 100, 100), w("か", 200, 100),
                 w("誰", 300, 100), w("か", 400, 100)]
    let groups = LyricsSyncEngine.buildWordGroups(
        words: words, line: "いつか誰か", japanese: true)
    expectEqual(groups != nil, true, "日文行该分得出词组")
    if let groups {
        // 每个词都必须**恰好**出现在一个组里,不能丢也不能重复 —— 丢了那个字就不显示了。
        let flat = groups.flatMap { g in g.words.map { $0.text } }.joined()
        expectEqual(flat, "いつか誰か", "分组必须完整覆盖原行、且不重复")
        expectEqual(groups.contains { $0.words.count > 1 }, true,
                    "「いつか」这种跨多个逐字词的读音必须并成一组")
        expectEqual(groups.contains { ($0.romanization ?? "").isEmpty == false }, true,
                    "至少要有一组标出读音")
        // 组内时间必须递增且覆盖到组尾,下面那行罗马音的填色进度才对
        for g in groups {
            expectEqual(g.endMs >= g.startMs, true, "组的结束时间不能早于开始时间")
        }
    }
    // 中文歌不该被标成拼音 —— japanese=false 时直接不给组。
    expectEqual(
        LyricsSyncEngine.buildWordGroups(
            words: [w("我", 0, 100), w("爱", 100, 100)], line: "我爱", japanese: false) == nil,
        true, "不是日文歌时不该分组(否则汉字会被标成拼音)")
}

// 助词 は/へ/を 读 wa/e/o,不是字面的 ha/he/wo —— Apple Music 标的是实际念法。
// 判据是"单独成词",词内部的同一个假名不能被改掉。
do {
    let cases: [(String, String, String)] = [
        ("今はまだ悲しい", "wa", "は 作助词该读 wa"),
        ("明日の今頃には", "wa", "には 里的 は 同样是助词"),
        ("本を読む", "o", "を 作助词该读 o(不是 wo)"),
        ("海へ行く", "e", "へ 作助词该读 e(不是 he)"),
    ]
    for (text, expect, label) in cases {
        let roma = Romanizer.romanize(text, japanese: true) ?? ""
        expectEqual(roma.split(separator: " ").contains(Substring(expect)), true,
                    "\(label):\(text) → \(roma)")
    }
    // 词**内部**的假名不能被误改 —— 「あなた」不该变成 「あな+wa」之类
    let anata = Romanizer.romanize("あなたはどこ", japanese: true) ?? ""
    expectEqual(anata.contains("anata"), true, "词内部的假名不能被助词规则改掉:\(anata)")
    expectEqual(anata.split(separator: " ").contains("wa"), true,
                "同一句里的助词 は 仍要改成 wa:\(anata)")
    // 固定语整词切出来,规则套不上,靠单列的表兜住
    let konnichiwa = Romanizer.romanize("こんにちは", japanese: true) ?? ""
    expectEqual(konnichiwa, "konnichiwa", "こんにちは 该读 konnichiwa,实际 \(konnichiwa)")
}

// 歌词源自带的假名标注:多音词该念哪个由标注说了算,而不是让分词器在合法读音里挑。
// 「明日」分词器给 asu、酷狗标注给 あした(Apple 也是 ashita)。
do {
    // 一句真实歌词 + 它真实的标注(2 表示这条读音覆盖两个汉字:明+日)
    let lrc = "[00:43.12]明日の今頃には\n[kana:2あした1いま1ごろ]"
    let ann = KanaAnnotation.parse(lrc: lrc)
    expectEqual(ann != nil, true, "带 [kana:] 的 LRC 该解析出标注")
    let marks = ann?.marks(forLine: "明日の今頃には") ?? []
    expectEqual(marks.count, 3, "这一句该有 3 处标注(明日/今/頃),实际 \(marks.count)")
    expectEqual(marks.first?.reading ?? "", "あした", "「明日」的标注读音该是 あした")
    expectEqual(marks.first?.utf16Length ?? 0, 2, "「明日」这条标注该覆盖两个字")

    let roma = Romanizer.romanize("明日の今頃には", japanese: true, marks: marks) ?? ""
    expectEqual(roma.contains("ashita"), true, "有标注时该读 ashita,实际 \(roma)")
    expectEqual(roma.contains("asu"), false, "有标注时不该再出现分词器的 asu:\(roma)")
    expectEqual(roma.split(separator: " ").contains("wa"), true,
                "助词规则仍要生效(は→wa):\(roma)")

    // 没有标注时退回分词器,行为不变
    let plain = Romanizer.romanize("明日の今頃には", japanese: true) ?? ""
    expectEqual(plain.isEmpty, false, "没有标注时仍要给得出读音")

    // 对不齐必须整份弃用 —— 标注条目覆盖 4 个字,这里只给 2 个字的量
    let bad = KanaAnnotation.parse(lrc: "[00:43.12]明日の今頃には\n[kana:2あした]")
    expectEqual(bad == nil, true, "覆盖字数对不上时必须整份弃用,不能半对半错地标歪")

    // 叠字符号 々 也算待标字符 —— 漏算它会从那里开始整体错位
    expectEqual(KanaAnnotation.needsAnnotation("々"), true, "々 必须算作待标字符")
    expectEqual(KanaAnnotation.needsAnnotation("明"), true, "汉字是待标字符")
    expectEqual(KanaAnnotation.needsAnnotation("の"), false, "假名不占标注条目")
}

// 一首歌开头那一堆制作人信息该被过滤掉 —— 2026-08-10 用户实报。原有的关键词表只收了
// 中文角色名和少数几个英文词,拉丁字母标签的整排漏网。
do {
    let lrc = """
    [00:00.00]First Love - 宇多田光 (宇多田ヒカル)
    [00:03.31]词：宇多田ヒカル
    [00:10.18]Strings Arrange：河野圭
    [00:11.84]Keyboards Programming：河野圭
    [00:17.53]Guitar：秋山浩徳
    [00:21.89]最後のキスは
    [00:26.89]タバコのflavorがした
    [00:32.17]ニガくてせつない香り
    [00:43.12]明日の今頃には
    """
    let engine = LyricsSyncEngine()
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                preferWordLevel: false,
                trackTitle: "First Love (Remastered 2014)", trackArtist: "宇多田ヒカル")
    let shown = engine.allLines(idPrefix: "t").compactMap { $0.line.plainText }
    expectEqual(shown.count, 4, "只该留下 4 行真歌词,实际留下 \(shown.count) 行:\(shown)")
    expectEqual(shown.first ?? "", "最後のキスは", "第一句该是真歌词,实际 \(shown.first ?? "")")
    for bad in ["Guitar", "Strings Arrange", "Keyboards", "词：", "First Love - "] {
        expectEqual(shown.contains { $0.contains(bad) }, false, "«\(bad)» 不该出现在歌词里")
    }

    // 反向:英文歌词里的半角冒号绝不能被当成署名删掉
    expectEqual(LyricsSyncEngine.looksLikeHeaderLine(
        "First Love", trackTitle: "First Love", trackArtist: "宇多田ヒカル"), false,
        "第一句歌词恰好就是歌名时不能删 —— 抬头必须同时含歌手名")
    let plain = """
    [00:01.00]Verse 1: here we go
    [00:02.00]I said: let's go
    [00:03.00]Baby you know
    """
    let e2 = LyricsSyncEngine()
    e2.load(lyrics: plain, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: false)
    expectEqual(e2.allLines(idPrefix: "t").count, 3,
                "英文歌词里带半角冒号的行一行都不能删")
}

// 歌词简繁切换。只改显示、不动原文,而且**绝不能碰日文**。
do {
    expectEqual(ChineseVariant.traditional.converted("这是一首简单的小情歌"),
                "這是一首簡單的小情歌", "简→繁")
    expectEqual(ChineseVariant.simplified.converted("這是一首簡單的小情歌"),
                "这是一首简单的小情歌", "繁→简")
    expectEqual(ChineseVariant.off.converted("这是一首简单的小情歌"),
                "这是一首简单的小情歌", "关掉时原样返回")

    // ⚠️ 日文汉字里有大量新字体(学/国/条),简繁转换会把它们改错 —— 带假名就一律不碰
    let jp = "明日の今頃には"
    expectEqual(ChineseVariant.traditional.converted(jp), jp, "日文行必须原样返回")
    let jp2 = "新しい歌 うたえるまで"
    expectEqual(ChineseVariant.traditional.converted(jp2), jp2, "含假名的行一律不转换")
    // 纯汉字的日文标题没有假名,兜不住是已知取舍,但至少中文歌要转对
    expectEqual(ChineseVariant.traditional.converted("头发"), "頭髮",
                "词组级转换要对(不是无脑逐字)")
    expectEqual(ChineseVariant.traditional.converted("只有你"), "只有你",
                "「只」在这里不该被转成「隻」")
    // 拉丁字母不受影响
    expectEqual(ChineseVariant.traditional.converted("First Love"), "First Love",
                "英文原样返回")
}

do {
    print("\n== 配置文件名识别(iCloud 换机链路) ==")
    typealias N = ConfigSnapshotName
    let real = "Lyrimuse-Config-2026-08-10-164500.json"
    expectEqual(N.realName(ofDirectoryEntry: real), real, "普通文件名原样认出")
    // 这一条是整条链路的命门:新电脑上那份配置几乎必然还没下载,只以占位符形态存在
    expectEqual(N.realName(ofDirectoryEntry: ".\(real).icloud"), real,
                "iCloud 未下载占位符要还原成真名")
    expectEqual(N.realName(ofDirectoryEntry: "Lyrimuse-Config-x.txt"), nil, "扩展名不对不认")
    expectEqual(N.realName(ofDirectoryEntry: "other.json"), nil, "别人的 json 不认")
    expectEqual(N.realName(ofDirectoryEntry: ".hidden.json"), nil,
                "只以点开头、不是 .icloud 占位符的隐藏文件不认")
    expectEqual(N.realName(ofDirectoryEntry: "Lyrimuse-Config-.json"), nil,
                "只有前后缀、没有时间戳的不算导出产物")
}

do {
    // 上面那组的另一半:名字认出来之后,还要判断"这份现在能不能直接读"。这一档判错的
    // 代价是 2026-08-24 用户在另一台机器上报的 bug —— 备份还没从 iCloud 下载下来时点
    // 「导入」,提示"等一会儿再试",但下载**从来没被发起过**,等多久都没用。
    print("\n== iCloud 备份能不能直接读(换机链路的另一半) ==")
    typealias R = ICloudFileReadiness
    expectEqual(R.isReadyToRead(downloadingStatus: .current, realPathExists: true), true,
                "已经是最新的本地副本 → 直接读")
    expectEqual(R.isReadyToRead(downloadingStatus: .notDownloaded, realPathExists: true), false,
                "dataless 占位(真名路径在、但还没下载)→ 先下载")
    expectEqual(R.isReadyToRead(downloadingStatus: .downloaded, realPathExists: true), false,
                "本地有旧副本、云端有更新 → 仍然先等最新那份")
    // ↓ 这条就是修的那一档。`.<真名>.icloud` 形态下真名路径压根不存在,查状态会抛错,
    //   原来无条件当"能读",于是跳过 startDownloadingUbiquitousItem、读一个不存在的路径。
    expectEqual(R.isReadyToRead(downloadingStatus: nil, realPathExists: false), false,
                "查不到状态且真名路径不存在 = iCloud 占位符,必须先下载")
    expectEqual(R.isReadyToRead(downloadingStatus: nil, realPathExists: true), true,
                "查不到状态但文件就在那儿 = 普通本地文件(Dropbox/手动拷贝),能直接读")
}

// ---- LogRedactor(诊断包脱敏) ----
//
// 这一组断言守的是一条会被贴进公开 GitHub issue 的输出:2026-08-13 实测坐实,诊断报告
// 末尾附的 collector 日志里带着 Last.fm API Key 原文。用例全部是合成的假密钥。
do {
    print("\n== 诊断日志脱敏 ==")
    typealias R = LogRedactor
    // 用例里的"密钥"都是合成串,长度贴着真实凭据(32/36/48)。
    let apiKey = "0123456789abcdef0123456789abcdef"
    let relayToken = "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT"
    let secrets = ["lastfmScrobbleAPIKey": apiKey, "stateRelayToken": relayToken]

    // 实测泄露的那一行的形状:Go *url.Error 把完整 URL 带进错误文本。
    let leaky = "2026/08/13 10:00:05 lastfmRecent: request failed: Get "
        + "\"https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=someone&api_key=\(apiKey)\""
    let cleaned = R.redactAll(leaky, secrets: secrets)
    expectEqual(cleaned.contains(apiKey), false, "值级脱敏:日志里的 API Key 原文必须消失")
    expectEqual(cleaned.contains("<redacted:lastfmScrobbleAPIKey>"), true,
                "脱敏后要留下字段名,排查时才知道那里原本是哪一项")
    expectEqual(cleaned.contains("user=someone"), true, "非敏感参数(用户名)要原样保留,否则报告没法读")
    expectEqual(cleaned.contains("audioscrobbler.com"), true, "host 要保留")

    // 第二层:配置里已经没有这把旧 key 了(用户换过),值级脱敏命中不了,靠正则兜住。
    let rotated = "Get \"https://ws.audioscrobbler.com/2.0/?api_key=deadbeefdeadbeefdeadbeefdeadbeef\""
    expectEqual(R.redactAll(rotated, secrets: [:]).contains("deadbeef"), false,
                "模式级脱敏:配置里已不存在的旧 key 也要打掉")

    // Bark 的 device key 长在 URL path 里,不是 query 参数——这是 alerter.go 那条尚未
    // 触发的同形状风险,两层都要能兜住。
    let bark = "notify push failed (platform=bark): Post \"https://api.day.app/SECRETDEVICEKEY123/t/b\": timeout"
    expectEqual(R.redactAll(bark, secrets: [:]).contains("SECRETDEVICEKEY123"), false,
                "路径型凭据(Bark device key)必须打掉")
    expectEqual(R.redactAll(bark, secrets: [:]).contains("api.day.app"), true, "Bark 的 host 保留")

    // 互为子串的两个凭据:必须先替换长的,否则长的会被切碎、漏出一截原文。
    let nested = "a=\(relayToken) b=\(relayToken + "SUFFIX")"
    let both = R.redact(nested, secrets: ["short": relayToken, "long": relayToken + "SUFFIX"])
    expectEqual(both.contains("SUFFIX"), false, "长短凭据互为前缀时,长的不能被切碎留下尾巴")

    // 过短的配置值不参与字面替换,否则普通日志词会被打成马赛克。
    let short = R.redact("platform=bark and the bark failed", secrets: ["notificationPlatform": "bark"])
    expectEqual(short.contains("bark and the bark"), true, "过短的配置值不该参与值级替换")

    expectEqual(R.redactAll("nothing sensitive here", secrets: secrets),
                "nothing sensitive here", "干净的行原样返回")
}

// 真机端到端校验:拿**这台机器上真实的** config.json + 真实的 collector 日志跑一遍,
// 断言脱敏后没有任何一个真实凭据残留。默认不跑 —— 它要读用户的真实密钥,跟
// lyrimuse-collector 的 simeval_test.go 用 SIMEVAL_DATA 把真实曲库 gate 住是同一个模式。
// 跑法:LYRIMUSE_REDACT_CHECK=1 swift run lyrimuse-selftest
// 全程只做比对,绝不打印任何密钥值(连长度以外的信息都不打)。
// ---- BackupDiscovery(跨目录找最新备份) ----
//
// 这是"换新 Mac 能不能一键恢复"的唯一入口,而它只在换机器时走一次、出错时没有现场可看,
// 所以用真实的临时目录做一次端到端。2026-08-13 用户问出的洞就在这条路上:备份放在
// Dropbox 的人,新机器上 UserDefaults 是空的、当前设置必然指向 iCloud,只按当前设置找
// 就什么都找不到。
do {
    print("\n== 跨目录探测备份 ==")
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("lyrimuse-backup-probe-\(ProcessInfo.processInfo.processIdentifier)")
    let iCloudish = root.appendingPathComponent("iCloudish/Lyrimuse")
    let dropboxish = root.appendingPathComponent("Dropboxish/Lyrimuse")
    let empty = root.appendingPathComponent("NothingHere/Lyrimuse")
    defer { try? fm.removeItem(at: root) }

    try? fm.createDirectory(at: iCloudish, withIntermediateDirectories: true)
    try? fm.createDirectory(at: dropboxish, withIntermediateDirectories: true)
    try? fm.createDirectory(at: empty, withIntermediateDirectories: true)

    let older = iCloudish.appendingPathComponent("Lyrimuse-Config-2026-08-01-120000.json")
    let newer = dropboxish.appendingPathComponent("Lyrimuse-Config-2026-08-13-160000.json")
    try? Data("{}".utf8).write(to: older)
    try? Data("{}".utf8).write(to: newer)
    // 显式钉住修改时间,不靠"写入顺序恰好决定 mtime"这种巧合。
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: older.path)
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: newer.path)

    // 候选顺序刻意把"当前设置指向的目录"(iCloudish)排在前面 —— 命中的必须是更新的那份,
    // 而不是排在前面的那份。
    let hit = BackupDiscovery.latest(in: [iCloudish, empty, dropboxish])
    expectEqual(hit?.url.lastPathComponent, "Lyrimuse-Config-2026-08-13-160000.json",
                "跨目录要取最新的那份,不是候选列表里排最前的")
    expectEqual(hit?.folder.lastPathComponent, "Lyrimuse", "要报出它所在的目录")
    expectEqual(hit?.folder.path, dropboxish.path, "目录必须是真正命中的那个(用于导入后对齐备份位置)")

    // 不存在的目录必须被跳过而不是让整次探测失败 —— 探测要翻好几个候选,大部分机器上
    // 大部分候选都不存在,那是常态。
    let missing = root.appendingPathComponent("DoesNotExist/Lyrimuse")
    let hit2 = BackupDiscovery.latest(in: [missing, iCloudish])
    expectEqual(hit2?.url.lastPathComponent, "Lyrimuse-Config-2026-08-01-120000.json",
                "候选里夹着不存在的目录时,其余目录照样要扫到")

    expectEqual(BackupDiscovery.latest(in: [empty, missing]) == nil, true, "都没有备份时返回 nil")

    // 目录里的无关文件不能被当成备份(认名规则归 ConfigSnapshotName,那边另有覆盖)。
    try? Data("{}".utf8).write(to: empty.appendingPathComponent("notes.txt"))
    try? Data("{}".utf8).write(to: empty.appendingPathComponent("other.json"))
    expectEqual(BackupDiscovery.latest(in: [empty]) == nil, true, "无关文件不算备份")
}

// ---- ImportPolicy(外来配置里的 relay 地址) ----
//
// 守的是"备份文件夹可以指向共享目录"之后新出现的那条路径:目录里的文件成了导入源,而
// state_relay_url 决定收听状态和 relay token 往哪台服务器发。
do {
    print("\n== 导入配置的地址校验 ==")
    typealias P = ImportPolicy
    expectEqual(P.isAcceptableRelayURL("https://np.yudaotor.me"), true, "https 放行")
    expectEqual(P.isAcceptableRelayURL("https://np.yudaotor.me/"), true, "https 带斜杠放行")
    expectEqual(P.isAcceptableRelayURL("  https://np.yudaotor.me  "), true, "两侧空白要先 trim")
    expectEqual(P.isAcceptableRelayURL("http://attacker.example.com"), false,
                "明文 http 发到公网必须拒绝(token 会跟着请求头一起走)")
    expectEqual(P.isAcceptableRelayURL("http://localhost:8787"), true, "本地调试放行")
    expectEqual(P.isAcceptableRelayURL("http://127.0.0.1:8787"), true, "回环 IP 放行")
    expectEqual(P.isAcceptableRelayURL("file:///etc/passwd"), false, "file: 拒绝")
    expectEqual(P.isAcceptableRelayURL("javascript:alert(1)"), false, "自定义 scheme 拒绝")
    expectEqual(P.isAcceptableRelayURL("np.yudaotor.me"), false, "没有 scheme 的裸 host 拒绝")
    expectEqual(P.isAcceptableRelayURL("https://"), false, "有 scheme 但没 host 拒绝")
    expectEqual(P.isAcceptableRelayURL(""), false, "空串在这里判 false,由调用方先行区分'没配置'")
}

// ---- writeSecurely(含凭据的文件必须落成 0600) ----
do {
    print("\n== 凭据文件权限 ==")
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lyrimuse-selftest-perm-\(ProcessInfo.processInfo.processIdentifier).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    // 先用普通 .atomic 写一次,证明默认权限确实是松的 —— 不然这条断言可能只是在
    // 复述当前 umask 恰好是什么。
    try? Data("{}".utf8).write(to: tmp, options: .atomic)
    let plain = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.posixPermissions]
        as? NSNumber)?.intValue ?? -1
    print("  普通 .atomic 写入的权限: \(String(plain, radix: 8))")

    try? FileManager.default.removeItem(at: tmp)
    try? Data("{}".utf8).writeSecurely(to: tmp)
    let secure = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.posixPermissions]
        as? NSNumber)?.intValue ?? -1
    expectEqual(secure, 0o600, "writeSecurely 落地的文件必须是 0600(实测普通写入是 \(String(plain, radix: 8)))")

    // 覆盖写一次:.atomic 换的是新 inode,权限得重新收紧,不能只在首次创建时对。
    try? Data("{\"a\":1}".utf8).writeSecurely(to: tmp)
    let rewritten = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.posixPermissions]
        as? NSNumber)?.intValue ?? -1
    expectEqual(rewritten, 0o600, "覆盖写之后权限仍须是 0600(.atomic 会换掉 inode)")
}

if ProcessInfo.processInfo.environment["LYRIMUSE_REDACT_CHECK"] == "1" {
    print("\n== 诊断脱敏真机校验 ==")
    let home = FileManager.default.homeDirectoryForCurrentUser
    let cfgURL = home.appendingPathComponent(".config/lyrimuse/config.json")
    let logURL = home.appendingPathComponent("Library/Logs/lyrimuse.log")

    guard let cfgData = try? Data(contentsOf: cfgURL),
          let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
          let logText = try? String(contentsOf: logURL, encoding: .utf8) else {
        failures += 1
        print("FAIL - 读不到真实 config.json 或日志,校验没跑成")
        exit(1)
    }

    // DiagnosticsExporter.recentCollectorLogLines(limit: 200) 复制的就是这个窗口。
    let window = logText.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init).suffix(200).joined(separator: "\n")

    // 只挑真正是凭据的字段,跟 ConfigStore.secretsForRedaction 的取舍保持一致。
    let credentialFields = ["listenbrainz_token", "state_relay_token", "lastfm_api_key",
                            "lastfm_scrobble_api_key", "lastfm_scrobble_secret",
                            "lastfm_scrobble_session_key", "bark_url",
                            "dingtalk_sign_secret", "feishu_sign_secret"]
    var secrets: [String: String] = [:]
    for f in credentialFields {
        if let v = cfg[f] as? String, !v.isEmpty { secrets[f] = v }
    }

    let before = secrets.filter { window.contains($0.value) }
    let cleaned = LogRedactor.redactAll(window, secrets: secrets)
    let after = secrets.filter { cleaned.contains($0.value) }

    print("  真实凭据字段数: \(secrets.count)")
    print("  脱敏前出现在导出窗口里的: \(before.count) 项 -> \(before.keys.sorted())")
    expectEqual(after.count, 0, "脱敏后不得有任何真实凭据残留(残留项: \(after.keys.sorted()))")
}


// ---- EnrichCacheMerge: 「歌词管理」写回缓存的合并规则(2026-08-14) ----
//
// 守的是一条**静默丢数据**的路径。「歌词管理」可以一直开着边听边整理,而 collector 在这期间
// 会往同一个文件写:新歌是新增 key,给已有歌补机翻译文/逐字/封面则是原地更新。窗口里的内存
// 快照只在开窗和点「刷新」时刷新,所以早先那种"整份覆盖写"会把这期间 collector 写的东西全
// 回滚掉。用户看到的第一个症状是"这首歌明明有翻译,列表里却没有译文标记" —— 那还只是显示层,
// 底下是真的在丢。
do {
    let base: [String: [String: Any]] = ["A|a|x": ["lyrics": "L"]]

    // ① 最要命的那一条:盘上的已有 key 被 collector 补了译文,而用户这次动的是**别的** key。
    //    那份译文必须活下来。
    let disk: [String: [String: Any]] = [
        "A|a|x": ["lyrics": "L", "lyrics_tr": "译文"],   // collector 刚补上的
        "B|b|y": ["lyrics": "N"],                        // collector 刚新增的一首
    ]
    var memory = base
    memory["C|c|z"] = ["lyrics": "C"]                    // 用户新采纳的一首
    let merged = EnrichCacheMerge.merge(
        disk: disk, memory: memory, edited: ["C|c|z"], deleted: [])
    expectEqual(merged["A|a|x"]?["lyrics_tr"] as? String, "译文",
                "EnrichCacheMerge: 用户没碰的 key,盘上新补的译文不能被回滚")
    expectEqual(merged["B|b|y"] != nil, true,
                "EnrichCacheMerge: 窗口开着期间 collector 新增的歌不能被抹掉")
    expectEqual(merged["C|c|z"]?["lyrics"] as? String, "C",
                "EnrichCacheMerge: 用户新采纳的内容要写进去")

    // ② 用户编辑过的 key:以内存为准,盘上的旧值必须被盖掉(否则用户的修改看着像没保存)。
    let edited = EnrichCacheMerge.merge(
        disk: ["A|a|x": ["lyrics": "盘上旧的"]],
        memory: ["A|a|x": ["lyrics": "用户改的"]],
        edited: ["A|a|x"], deleted: [])
    expectEqual(edited["A|a|x"]?["lyrics"] as? String, "用户改的",
                "EnrichCacheMerge: 用户编辑过的 key 以内存为准")

    // ③ 用户删掉的 key:即便盘上还在也要删 —— 这正是"删除"的意思,也是 collector 会在
    //    背后把它写回来的场景(它内存里还持有旧缓存)。
    let deleted = EnrichCacheMerge.merge(
        disk: ["A|a|x": ["lyrics": "L"]], memory: [:],
        edited: [], deleted: ["A|a|x"])
    expectEqual(deleted["A|a|x"] == nil, true,
                "EnrichCacheMerge: 用户删掉的 key 不能被盘上的版本复活")

    // ④ 先编辑、后删除同一个 key:删除赢。edited 里还留着它但内存里已经没有了。
    let editThenDelete = EnrichCacheMerge.merge(
        disk: ["A|a|x": ["lyrics": "L"]], memory: [:],
        edited: ["A|a|x"], deleted: ["A|a|x"])
    expectEqual(editThenDelete["A|a|x"] == nil, true,
                "EnrichCacheMerge: 编辑后又删除,结果是删除")
}

// ---- LaunchdPrintParser ----
//
// 样本取自 2026-08-15 在真机上抓的 `launchctl print gui/<uid>/<label>` 实际输出(见
// LaunchdJobState 里那张三态表),只保留跟解析有关的行。
do {
    // 真实输出里同时有这三种行,后两种都是**陷阱**:
    //   \t\tstate = active     嵌套在子结构里,不是 job 状态
    //   \tjob state = running  同一层缩进,但是另一个字段
    let runningOutput = """
    gui/502/com.lyrimuse.collector = {
    \tactive count = 1
    \tstate = running
    \tpid = 82285
    \tlast exit code = 0
    \tspawn type = daemon
    \tendpoints = {
    \t\t"com.example.socket" = {
    \t\t\tstate = active
    \t\t}
    \t}
    \tjob state = running
    }
    """
    expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: runningOutput),
                .running(pid: 82285), "Launchd: 在跑 → running(pid)")

    // 这就是原来那个 bug 的形状:退出码同样是 0,但进程根本不在。
    let notRunningOutput = """
    gui/502/com.lyrimuse.collector = {
    \tactive count = 0
    \tstate = not running
    \tlast exit code = 78
    }
    """
    expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: notRunningOutput),
                .registeredNotRunning(lastExitCode: 78),
                "Launchd: 注册了但没在跑 → 带上次退出码,不能当成在跑")

    // launchd 真正报退出码时带 sysexits 助记名:`78: EX_CONFIG`。实测抓到的形态,
    // 直接 Int32(...) 会返回 nil 把退出码吞掉。
    let exitCodeWithName = "gui/502/x = {\n\tstate = not running\n\truns = 1\n\tlast exit code = 78: EX_CONFIG\n}"
    expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: exitCodeWithName),
                .registeredNotRunning(lastExitCode: 78),
                "Launchd: `78: EX_CONFIG` 要解析出 78,不能吞掉")

    // launchd 对没退出过的 job 写的是 `(never exited)`,不是数字。
    let neverExited = "gui/502/x = {\n\tstate = not running\n\tlast exit code = (never exited)\n}"
    expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: neverExited),
                .registeredNotRunning(lastExitCode: nil),
                "Launchd: (never exited) 解析成 nil 而不是 0")

    // print 对未注册的 job 返回 113。
    expectEqual(LaunchdPrintParser.parse(printExitCode: 113, printOutput: ""),
                .notRegistered, "Launchd: 未注册 → notRegistered")

    // 陷阱一:只有嵌套的 state,顶层没有 —— 不能被当成 job 状态。
    let nestedOnly = "gui/502/x = {\n\tendpoints = {\n\t\tstate = active\n\t}\n}"
    expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: nestedOnly),
                .unknown, "Launchd: 嵌套的 state = active 不能被当成 job 状态")

    // 陷阱二:`job state` 跟 `state` 同一层缩进,前缀却不同 —— contains 会误判。
    let jobStateOnly = "gui/502/x = {\n\tjob state = running\n}"
    expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: jobStateOnly),
                .unknown, "Launchd: job state 不是 state,不能误认成在跑")

    // 认不出来就说认不出来,不要假装知道它没在跑。
    expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: "完全不认识的输出"),
                .unknown, "Launchd: 读不懂的输出 → unknown,不塌缩成未运行")

    expectEqual(LaunchdJobState.running(pid: 1).isRunning, true, "Launchd: running.isRunning")
    expectEqual(LaunchdJobState.registeredNotRunning(lastExitCode: 78).isRunning, false,
                "Launchd: 注册但没跑 isRunning=false")
    expectEqual(LaunchdJobState.unknown.isRunning, false, "Launchd: unknown 不算在跑")
}

// ---- KaraokeFill ----
//
// 逐字填色的数值部分。这段算法之前混在 LyricsOverlayView 里，每次改都只能盯着屏幕看
// 对不对；下面每一条都对应一个真出过的 bug。
do {
    func word(_ start: Int, _ dur: Int) -> SyncedLyricWord {
        SyncedLyricWord(text: "x", startMs: start, durationMs: dur)
    }
    func rounded(_ stops: [KaraokeFill.Stop]) -> [[Double]] {
        stops.map { [($0.location * 10000).rounded() / 10000, ($0.intensity * 10000).rounded() / 10000] }
    }

    // fillFraction 故意**不**夹到 [0,1]：夹住的话，一句里所有还没唱到的字都会得到 0，
    // 跟"刚好唱到最前一刻"无法区分，于是每个未唱字的开头都会冒出一小截高亮。
    expectEqual(KaraokeFill.fillFraction(for: word(1000, 500), atMs: 0) < 0, true,
                "KaraokeFill: 还没唱到的字必须给负数,不能夹成 0")
    expectEqual(KaraokeFill.fillFraction(for: word(1000, 500), atMs: 2000) > 1, true,
                "KaraokeFill: 早就唱完的字必须大于 1")
    expectEqual(KaraokeFill.fillFraction(for: word(1000, 500), atMs: 1250), 0.5,
                "KaraokeFill: 正中间是 0.5")

    // durationMs=0 的极短词（英文歌词常见）按下限算，否则瞬间 0→1 会很跳。
    expectEqual(KaraokeFill.fillFraction(for: word(0, 0), atMs: 40), 0.5,
                "KaraokeFill: durationMs=0 按 minWordDurationMs 下限算")

    // 离得远的字：整片暗色，不能有任何过渡带残留。
    expectEqual(rounded(KaraokeFill.stops(left: -0.5, right: -0.34)),
                [[0, 0], [1, 0]], "KaraokeFill: 还没唱到 → 整片暗色")
    // 唱完很久的字：整片亮色。
    expectEqual(rounded(KaraokeFill.stops(left: 1.2, right: 1.36)),
                [[0, 1], [1, 1]], "KaraokeFill: 早就唱完 → 整片亮色")

    // 正常中间态：亮 → 过渡 → 暗，四个分段点。
    expectEqual(rounded(KaraokeFill.stops(left: 0.2, right: 0.36)),
                [[0, 1], [0.2, 1], [0.36, 0], [1, 0]],
                "KaraokeFill: 中间态四个分段点")

    // 过渡带跨过左边界：0 这一点的强度要**现算**，不能硬写成 1 —— 否则 0 处同时存在
    // 强度 1 和过渡带算出的另一个值，渲染时互相抢占，边界会闪。
    expectEqual(rounded(KaraokeFill.stops(left: -0.05, right: 0.11)),
                [[0, 0.6875], [0.11, 0], [1, 0]],
                "KaraokeFill: 过渡带跨左边界时 0 处强度要现算")
    // 跨右边界同理。
    expectEqual(rounded(KaraokeFill.stops(left: 0.95, right: 1.11)),
                [[0, 1], [0.95, 1], [1, 0.6875]],
                "KaraokeFill: 过渡带跨右边界时 1 处强度要现算")

    // 全局不变式，扫一遍整个进度区间：
    //   ① location 单调不减 —— 这正是网页端"提前上色"那个 bug 的判据（渐变 stop 一旦
    //      逆序，渲染层会把它钳回去，视觉上表现为颜色跑到前面去了）
    //   ② location 始终落在 [0,1]
    //   ③ intensity 始终落在 [0,1]
    //   ④ 强度沿着位置单调不增（唱过的在左边，越往右越暗）
    var monotonic = true, inRange = true, intensityOK = true, intensityDesc = true
    for step in -30...130 {
        let fraction = Double(step) / 100
        let s = KaraokeFill.stops(left: fraction - KaraokeFill.wordEdgeSoftenBand,
                                  right: fraction + KaraokeFill.wordEdgeSoftenBand)
        for (i, stop) in s.enumerated() {
            if stop.location < 0 || stop.location > 1 { inRange = false }
            if stop.intensity < 0 || stop.intensity > 1 { intensityOK = false }
            if i > 0 {
                if stop.location < s[i - 1].location - 1e-12 { monotonic = false }
                if stop.intensity > s[i - 1].intensity + 1e-12 { intensityDesc = false }
            }
        }
    }
    expectEqual(monotonic, true, "KaraokeFill: stop 位置始终单调不减(逆序=提前上色)")
    expectEqual(inRange, true, "KaraokeFill: stop 位置始终在 [0,1]")
    expectEqual(intensityOK, true, "KaraokeFill: 强度始终在 [0,1]")
    expectEqual(intensityDesc, true, "KaraokeFill: 强度沿位置单调不增")
}

// ---- OverlayControlHitTest.windowLocalRect:SwiftUI 矩形 → AppKit 窗口本地 ----
//
// 2026-08-23 抽出来的:这套换算原先在控制器里抄了三遍(按钮矩形/控制热区/歌词热区),
// 而且三处都把结果**直接转成屏幕坐标存起来** —— 窗口一移动,SwiftUI 布局没变、
// PreferenceKey 不重发,存的屏幕坐标就还停在旧位置,按钮和热区当场失效
// (用户报的「移动之后按钮会失效」)。现在只存窗口本地坐标,判定时把鼠标点转进来。
do {
    let H = OverlayControlHitTest.self
    // y 翻转:SwiftUI 的 y 从顶部往下,AppKit 从底部往上
    expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 10, y: 0, width: 30, height: 20), windowHeight: 100),
                CGRect(x: 10, y: 80, width: 30, height: 20), "窗口本地: 贴顶的矩形翻到贴顶(y=80)")
    expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 10, y: 80, width: 30, height: 20), windowHeight: 100),
                CGRect(x: 10, y: 0, width: 30, height: 20), "窗口本地: 贴底的矩形翻到 y=0")
    // x 和尺寸不动
    expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 7, y: 30, width: 13, height: 5), windowHeight: 60).minX,
                7, "窗口本地: x 不变")
    expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 7, y: 30, width: 13, height: 5), windowHeight: 60).width,
                13, "窗口本地: 宽不变")
    // 翻两次回到原处 —— 换算是自逆的
    do {
        let a = CGRect(x: 4, y: 12, width: 20, height: 8)
        let once = H.windowLocalRect(swiftUI: a, windowHeight: 50)
        expectEqual(H.windowLocalRect(swiftUI: once, windowHeight: 50), a, "窗口本地: 翻两次回到原处")
    }
}

// ---- WrapLayoutMath ----
//
// 逐字歌词那个自动换行容器的几何。以前长在 LyricsOverlayView 里，改一次就只能盯屏幕看。
do {
    func sz(_ w: CGFloat, _ h: CGFloat = 10) -> CGSize { CGSize(width: w, height: h) }
    func rowIndices(_ rows: [WrapLayoutMath.Row]) -> [[Int]] { rows.map { $0.indices } }

    // 装得下就一行。
    expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(10), sz(10), sz(10)], maxWidth: 100, horizontalSpacing: 0)),
                [[0, 1, 2]], "WrapLayout: 装得下就一行")

    // 装不下就换行。
    expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(60), sz(60), sz(60)], maxWidth: 100, horizontalSpacing: 0)),
                [[0], [1], [2]], "WrapLayout: 装不下逐个换行")

    // 间距要算进"还装不装得下"里：3 个 30 宽 + 2 个 10 间距 = 110 > 100。
    expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(30), sz(30), sz(30)], maxWidth: 100, horizontalSpacing: 10)),
                [[0, 1], [2]], "WrapLayout: 间距要计入换行判断")

    // ⚠️ 单个元素本身就超宽时，必须独占一行且**保留**——这正是"长歌词行整行变成一串
    // 省略号"那个 bug 的修法。谁要是在这里加个"太宽就跳过"，这条会立刻红。
    expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(500)], maxWidth: 100, horizontalSpacing: 0)),
                [[0]], "WrapLayout: 单个超宽元素独占一行,不能被丢掉")
    expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(10), sz(500), sz(10)], maxWidth: 100, horizontalSpacing: 0)),
                [[0], [1], [2]], "WrapLayout: 超宽元素夹在中间也不丢")

    // 空输入不该炸，也不该造出一个空行。
    expectEqual(WrapLayoutMath.rows(sizes: [], maxWidth: 100, horizontalSpacing: 0).count, 0,
                "WrapLayout: 空输入没有行")

    // 行高取本行最高的那个；总高度 = 各行行高 + 行距。
    let twoRows = WrapLayoutMath.totalSize(
        sizes: [sz(60, 20), sz(60, 30)], maxWidth: 100, horizontalSpacing: 0, verticalSpacing: 5)
    expectEqual(twoRows, CGSize(width: 100, height: 55), "WrapLayout: 两行高度 = 20+30+5 行距")

    // 三种对齐：同一行内容宽 60、容器宽 100，剩 40 的空隙。
    func firstX(_ alignment: WrapLayoutMath.RowAlignment) -> CGFloat {
        WrapLayoutMath.placements(
            sizes: [sz(60)], bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            horizontalSpacing: 0, verticalSpacing: 0, rowAlignment: alignment
        ).first?.origin.x ?? -1
    }
    expectEqual(firstX(.leading), 0, "WrapLayout: leading 贴左")
    expectEqual(firstX(.center), 20, "WrapLayout: center 居中")
    expectEqual(firstX(.trailing), 40, "WrapLayout: trailing 贴右")

    // bounds 不是从原点开始时，位置要跟着平移（悬浮窗里就不是原点）。
    let offsetPlacement = WrapLayoutMath.placements(
        sizes: [sz(60)], bounds: CGRect(x: 7, y: 3, width: 100, height: 50),
        horizontalSpacing: 0, verticalSpacing: 0, rowAlignment: .leading).first
    expectEqual(offsetPlacement?.origin.x, 7, "WrapLayout: 位置跟随 bounds.minX")

    // 行内竖直居中：本行高 30，这个元素高 10，应该往下让 10。
    let vcenter = WrapLayoutMath.placements(
        sizes: [sz(10, 10), sz(10, 30)], bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
        horizontalSpacing: 0, verticalSpacing: 0, rowAlignment: .leading)
    expectEqual(vcenter.first?.origin.y, 10, "WrapLayout: 矮的元素在行内竖直居中")

    // 全局不变式：顺序保持、每个元素都被放置、不会超出 bounds 左边界、y 不倒退。
    var orderOK = true, allPlaced = true, noLeftOverflow = true, noOverlap = true
    for count in 1...12 {
        var sizes: [CGSize] = []
        for i in 0..<count {
            let w: CGFloat = CGFloat(20 + (i * 13) % 70)
            let h: CGFloat = CGFloat(10 + (i * 7) % 20)
            sizes.append(sz(w, h))
        }
        for alignment in [WrapLayoutMath.RowAlignment.leading, .center, .trailing] {
            let bounds = CGRect(x: 5, y: 5, width: 120, height: 500)
            let ps = WrapLayoutMath.placements(
                sizes: sizes, bounds: bounds, horizontalSpacing: 3, verticalSpacing: 2,
                rowAlignment: alignment)
            if ps.count != sizes.count { allPlaced = false }
            let indices: [Int] = ps.map { $0.index }
            if indices != Array(0..<sizes.count) { orderOK = false }
            for p in ps where p.origin.x < bounds.minX - 1e-9 { noLeftOverflow = false }
            // 不许有任何两个元素叠在一起。比"y 单调"强,也比它正确 —— 行内是**竖直
            // 居中**的,同一行里矮的元素 y 本来就比高的大,逐个比 y 会误判成倒退。
            for a in 0..<ps.count {
                for b in (a + 1)..<ps.count {
                    let ra = CGRect(origin: ps[a].origin, size: ps[a].size)
                    let rb = CGRect(origin: ps[b].origin, size: ps[b].size)
                    if ra.insetBy(dx: 1e-6, dy: 1e-6).intersects(rb.insetBy(dx: 1e-6, dy: 1e-6)) {
                        noOverlap = false
                    }
                }
            }
        }
    }
    expectEqual(allPlaced, true, "WrapLayout: 每个元素都要被放置,一个都不能少")
    expectEqual(orderOK, true, "WrapLayout: 顺序必须保持")
    expectEqual(noLeftOverflow, true, "WrapLayout: 不会跑到 bounds 左边界外")
    expectEqual(noOverlap, true, "WrapLayout: 任意两个元素都不重叠")

    // ---- contentBounds:文字真正占据的矩形(给「指针划过歌词才让开」当命中判据) ----
    //
    // 跟 totalSize 是两回事:那个恒返回 maxWidth(撑满是刻意的,对唱左右对齐要靠它),
    // 这个返回内容自己的包围盒。原来 hover 判据是整个窗口矩形,指针在歌词**附近**的
    // 空白处就触发淡出(2026-08-23 用户报的)。
    do {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 40)
        // 单行、宽 60:三种对齐分别贴左 / 居中 / 贴右
        let one = WrapLayoutMath.rows(sizes: [sz(60, 20)], maxWidth: 200, horizontalSpacing: 0)
        expectEqual(
            WrapLayoutMath.contentBounds(rows: one, bounds: bounds, verticalSpacing: 2, rowAlignment: .leading),
            CGRect(x: 0, y: 0, width: 60, height: 20), "内容矩形: 靠左时贴左缘")
        expectEqual(
            WrapLayoutMath.contentBounds(rows: one, bounds: bounds, verticalSpacing: 2, rowAlignment: .center),
            CGRect(x: 70, y: 0, width: 60, height: 20), "内容矩形: 居中时两边等分")
        expectEqual(
            WrapLayoutMath.contentBounds(rows: one, bounds: bounds, verticalSpacing: 2, rowAlignment: .trailing),
            CGRect(x: 140, y: 0, width: 60, height: 20), "内容矩形: 靠右时贴右缘")
        // 多行:宽度取最宽那行,高度含行距
        let two = WrapLayoutMath.rows(sizes: [sz(120, 20), sz(120, 20)], maxWidth: 150, horizontalSpacing: 0)
        expectEqual(two.count, 2, "内容矩形: 前置条件——两个 120 宽在 150 里装不下,折成两行")
        expectEqual(
            WrapLayoutMath.contentBounds(rows: two, bounds: CGRect(x: 0, y: 0, width: 150, height: 50),
                                         verticalSpacing: 2, rowAlignment: .leading),
            CGRect(x: 0, y: 0, width: 120, height: 42), "内容矩形: 多行取最宽行 + 行距计入高度")
        // bounds 原点非零时跟着平移
        expectEqual(
            WrapLayoutMath.contentBounds(rows: one, bounds: CGRect(x: 30, y: 7, width: 200, height: 40),
                                         verticalSpacing: 2, rowAlignment: .leading),
            CGRect(x: 30, y: 7, width: 60, height: 20), "内容矩形: 跟随 bounds 原点平移")
        // 退化输入不产生垃圾矩形
        expectEqual(
            WrapLayoutMath.contentBounds(rows: [], bounds: bounds, verticalSpacing: 2, rowAlignment: .center),
            .zero, "内容矩形: 没有行时返回 zero")
        // 内容比容器宽时钳到容器宽(不往外溢出,否则热区会盖到窗口之外)
        let wide = WrapLayoutMath.rows(sizes: [sz(300, 20)], maxWidth: 200, horizontalSpacing: 0)
        expectEqual(
            WrapLayoutMath.contentBounds(rows: wide, bounds: bounds, verticalSpacing: 2, rowAlignment: .leading).width,
            200, "内容矩形: 单个超宽子视图不让矩形溢出容器")
    }

}

// ---- OverlayPlacement ----
//
// 拔掉外接屏之后悬浮窗还找得回来吗。这台开发机只有一块内置屏，"两块屏拔掉一块"没法真机
// 复现，这些断言是唯一覆盖它的手段。
do {
    let mainScreen = CGRect(x: 0, y: 0, width: 1470, height: 900)
    let secondScreen = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
    let overlaySize = CGSize(width: 900, height: 166)

    // 窗口好端端待在主屏上：不该动它。
    let onMain = CGRect(origin: CGPoint(x: 285, y: 700), size: overlaySize)
    expectEqual(OverlayPlacement.repositionIfOffscreen(frame: onMain, screens: [mainScreen]) == nil, true,
                "OverlayPlacement: 窗口在屏内不动它")

    // 窗口在副屏上，两块屏都在：同样不该动。
    let onSecond = CGRect(origin: CGPoint(x: 1600, y: 100), size: overlaySize)
    expectEqual(
        OverlayPlacement.repositionIfOffscreen(frame: onSecond, screens: [mainScreen, secondScreen]) == nil, true,
        "OverlayPlacement: 窗口在副屏上、副屏还在,不动它")

    // 同一个窗口，副屏被拔掉 —— 这就是这次要修的场景。
    let rescued = OverlayPlacement.repositionIfOffscreen(frame: onSecond, screens: [mainScreen])
    expectEqual(rescued?.x, 570, "OverlayPlacement: 拔掉副屏后夹回主屏右边界内 (1470-900)")
    expectEqual(rescued?.y, 100, "OverlayPlacement: y 本来就在范围内,保持不变")

    // 保守判据：用户主动把窗口拖到边缘、只露一部分，是正常用法，不许"纠正"。
    // 露出 200pt 宽，远超 60pt 阈值。
    let mostlyOff = CGRect(origin: CGPoint(x: 1270, y: 700), size: overlaySize)
    expectEqual(OverlayPlacement.repositionIfOffscreen(frame: mostlyOff, screens: [mainScreen]) == nil, true,
                "OverlayPlacement: 只露一部分但够得着,不动它")

    // 只剩 30pt 露在屏内，低于 60pt 阈值 → 救回来。
    let slivered = CGRect(origin: CGPoint(x: 1440, y: 700), size: overlaySize)
    expectEqual(OverlayPlacement.repositionIfOffscreen(frame: slivered, screens: [mainScreen]) != nil, true,
                "OverlayPlacement: 只剩一丝可见时救回来")

    // 窗口比屏幕还宽：夹取不能把它推到右边界外面去（先 max 再 min 的顺序问题）。
    let tooWide = CGRect(x: 3000, y: 100, width: 2000, height: 166)
    let clampedWide = OverlayPlacement.clamped(frame: tooWide, into: mainScreen)
    expectEqual(clampedWide.x, 0, "OverlayPlacement: 比屏还宽时贴左边,不能被推出右边界")

    // 屏幕原点不是 (0,0) 时也要跟着走（多屏排列里副屏常有负坐标）。
    let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let strayFrame = CGRect(x: -5000, y: 0, width: 900, height: 166)
    expectEqual(OverlayPlacement.clamped(frame: strayFrame, into: leftScreen).x, -1920,
                "OverlayPlacement: 夹取跟随屏幕自己的原点,不假设从 0 开始")

    // 窗口比阈值还小时，阈值要退让到窗口尺寸，否则它永远判不出"可见"。
    let tiny = CGRect(x: 10, y: 10, width: 20, height: 10)
    expectEqual(OverlayPlacement.isSufficientlyVisible(frame: tiny, screens: [mainScreen]), true,
                "OverlayPlacement: 比阈值还小的窗口只要整个在屏内就算可见")

    // 一块屏都没有（理论上不会发生）时别崩、别乱动。
    expectEqual(OverlayPlacement.repositionIfOffscreen(frame: onMain, screens: []) == nil, true,
                "OverlayPlacement: 没有任何屏幕时不动")

    // 夹取结果跟原位置相同时不返回移动 —— 免得白白触发一次位置持久化。
    let exactlyAtEdge = CGRect(origin: CGPoint(x: 570, y: 100), size: overlaySize)
    expectEqual(OverlayPlacement.repositionIfOffscreen(frame: exactlyAtEdge, screens: [mainScreen]) == nil, true,
                "OverlayPlacement: 已经在合法位置时不发多余的移动")
}

// ---- OverlayPlacement:启动还原不许跨屏搬家(2026-08-21) ----
//
// 用户主诉"悬浮歌词经常在我主屏幕和副屏幕之间切换位置"的那条根因。几何全部取自这台机器的
// 真实读数,不是编的:
//   内置屏 visibleFrame = (0, 70, 1470, 853)      ← NSScreen.main
//   外接屏 visibleFrame = (-526, 956, 2560, 1440)
//   盘上锚点 np:overlayPositionTop = "849.0,1202.0"(x, 顶边),窗口宽 900、初始高 120
// 旧代码在 restoredOrigin 里把这个锚点无条件夹进 NSScreen.main.visibleFrame,于是每次启动
// 都把好端端待在外接屏上的窗口拽回内置屏 (570, 803);用户拖回去,下次启动再拽一次。
do {
    let builtIn = CGRect(x: 0, y: 70, width: 1470, height: 853)
    let external = CGRect(x: -526, y: 956, width: 2560, height: 1440)
    let size = CGSize(width: 900, height: 120)
    // 锚点存的是顶边,还原成 AppKit 的左下角 origin:1202 − 120 = 1082。
    let saved = CGRect(origin: CGPoint(x: 849, y: 1082), size: size)

    // 两块屏都在 → 原样保留,一个点都不许动(这是这次修的主判据)。
    let kept = OverlayPlacement.restored(frame: saved, screens: [builtIn, external])
    expectEqual(kept.origin.x, 849, "OverlayPlacement: 副屏上的锚点原样保留 x")
    expectEqual(kept.origin.y, 1082, "OverlayPlacement: 副屏上的锚点原样保留 y")
    expectEqual(kept.wasRescued, false, "OverlayPlacement: 看得见就不算救援")

    // 外接屏不在了(拔掉/休眠)→ 才允许借主屏摆,并且标记成"借来的"(调用方据此不写盘)。
    let rescued = OverlayPlacement.restored(frame: saved, screens: [builtIn])
    expectEqual(rescued.origin.x, 570, "OverlayPlacement: 一块屏都看不见时夹回主屏 (1470-900)")
    expectEqual(rescued.origin.y, 803, "OverlayPlacement: 一块屏都看不见时夹回主屏 (923-120)")
    expectEqual(rescued.wasRescued, true, "OverlayPlacement: 借屏落位必须标记出来")

    // 一块屏都枚举不到(理论上不会发生)→ 原样返回,别摆到凭空算出来的坐标上。
    let noScreens = OverlayPlacement.restored(frame: saved, screens: [])
    expectEqual(noScreens.origin.y, 1082, "OverlayPlacement: 没有屏幕时不动锚点")
    expectEqual(noScreens.wasRescued, false, "OverlayPlacement: 没有屏幕时不算救援")

    // hostVisibleFrame:窗口自身的钳制要按**它落在的那块屏**算,不是按 NSScreen.main。
    let host = OverlayPlacement.hostVisibleFrame(of: saved, screens: [builtIn, external])
    expectEqual(host?.minY, 956, "OverlayPlacement: 副屏上的窗口拿到副屏的可见区域")
    // 跨在两块屏之间时取相交面积大的那块:内置屏 200×23=4600,外接屏 200×144=28800。
    let straddling = CGRect(x: 0, y: 900, width: 200, height: 200)
    expectEqual(OverlayPlacement.hostVisibleFrame(of: straddling, screens: [builtIn, external])?.minY, 956,
                "OverlayPlacement: 跨屏时取相交面积更大的那块")
    // 一块都不沾 → nil,调用方据此"那就不夹了",而不是硬按主屏算把窗口往主屏方向推。
    let nowhere = CGRect(x: 9000, y: 9000, width: 100, height: 100)
    expectEqual(OverlayPlacement.hostVisibleFrame(of: nowhere, screens: [builtIn, external]) == nil, true,
                "OverlayPlacement: 不沾任何屏时没有可信边界")
}

// ---- ProcessRunner ----
//
// 跑真实子进程（/bin/echo、/bin/sleep、/usr/bin/yes），不是合成数据 —— 这里要验证的
// 恰恰是跟真实进程/管道打交道时的行为。
do {
    // 正常命令。
    let hello = ProcessRunner.run("/bin/echo", ["hello"], timeout: 5)
    expectEqual(hello?.status, 0, "ProcessRunner: 正常命令退出码 0")
    expectEqual(hello?.stdoutText, "hello\n", "ProcessRunner: 拿得到 stdout")
    expectEqual(hello?.timedOut, false, "ProcessRunner: 正常命令没有超时")
    expectEqual(hello?.succeeded, true, "ProcessRunner: succeeded")

    // 非零退出：跑了但失败，跟"没跑起来"是两回事。
    let failed = ProcessRunner.run("/bin/sh", ["-c", "exit 3"], timeout: 5)
    expectEqual(failed?.status, 3, "ProcessRunner: 非零退出码如实返回")
    expectEqual(failed?.succeeded, false, "ProcessRunner: 非零退出不算成功")

    // 可执行文件不存在 → nil（"根本没起来"），不是 status 非零。
    expectEqual(ProcessRunner.run("/nonexistent/binary", [], timeout: 5) == nil, true,
                "ProcessRunner: 起不来的命令返回 nil")

    // 超时：这是这个类型存在的全部理由。
    // 不加超时的话这一句会等满 10 秒 —— 而 Music.app 卡住时 osascript 会等 60 秒。
    let started = Date()
    let slept = ProcessRunner.run("/bin/sleep", ["10"], timeout: 1)
    let elapsed = Date().timeIntervalSince(started)
    expectEqual(slept?.timedOut, true, "ProcessRunner: 超时的命令标记 timedOut")
    expectEqual(slept?.succeeded, false, "ProcessRunner: 超时不算成功")
    expectEqual(elapsed < 5, true, "ProcessRunner: 超时后立刻返回,不等命令自己跑完")

    // 大输出不能死锁。管道缓冲区 64KB，写满之后子进程会阻塞在 write 上；如果先
    // waitUntilExit 再读管道，两边互相等 —— 这正是各调用点原来那个形状的隐患。
    // 1MB 远超缓冲区。
    let big = ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/yes ABCDEFGH | /usr/bin/head -c 1000000"], timeout: 20)
    expectEqual(big?.stdout.count, 1_000_000, "ProcessRunner: 1MB 输出完整读回,不死锁")
    expectEqual(big?.timedOut, false, "ProcessRunner: 大输出不该触发超时")

    // stderr 不该混进 stdout（丢 nullDevice，也不会因为没人读而把子进程卡住）。
    let noisy = ProcessRunner.run("/bin/sh", ["-c", "/bin/echo out; /bin/echo err >&2"], timeout: 5)
    expectEqual(noisy?.stdoutText, "out\n", "ProcessRunner: stderr 不混进 stdout")

    // 子进程往 stderr 狂写也不能卡住 —— nullDevice 不会满。
    let noisyBig = ProcessRunner.run(
        "/bin/sh", ["-c", "/usr/bin/yes ERRORLINE | /usr/bin/head -c 500000 >&2; /bin/echo done"], timeout: 20)
    expectEqual(noisyBig?.stdoutText, "done\n", "ProcessRunner: stderr 狂写不影响 stdout")
    expectEqual(noisyBig?.timedOut, false, "ProcessRunner: stderr 狂写不该超时")
}

// ---- 罗马音按语言开关 ----
do {
    // 文字判定。顺序是有讲究的，不能重排：
    expectEqual(Romanizer.script(of: "こんにちは"), .japanese, "Script: 假名 → 日文")
    expectEqual(Romanizer.script(of: "안녕하세요"), .korean, "Script: 谚文 → 韩文")
    expectEqual(Romanizer.script(of: "你对我笑一次"), .chinese, "Script: 纯汉字 → 中文")
    expectEqual(Romanizer.script(of: "Hello world"), .other, "Script: 拉丁 → other")
    // ⚠️ 日文歌里大量夹汉字。假名必须先判，否则整首日文歌会被判成中文 —— 那正是
    // 2026-08-04 修过的那个 bug 的形状。
    expectEqual(Romanizer.script(of: "受話器を取った君"), .japanese,
                "Script: 汉字+假名混排 → 日文,不能判成中文")
    // 韩文歌词里夹汉字（人名/成语）少见但存在。
    expectEqual(Romanizer.script(of: "그대 漢字"), .korean, "Script: 谚文+汉字 → 韩文")

    // 默认值必须等于"改成可配置之前的实际观感"：日韩有、中文没有。
    expectEqual(RomanizationScripts.default.contains(.japanese), true, "默认: 日文开")
    expectEqual(RomanizationScripts.default.contains(.korean), true, "默认: 韩文开")
    expectEqual(RomanizationScripts.default.contains(.chinese), false, "默认: 中文关")

    // ---- 引擎级：开关真的能挡住罗马音吗 ----
    func romanization(
        lyrics: String, roma: String, scripts: RomanizationScripts
    ) -> String? {
        let engine = LyricsSyncEngine()
        engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: roma, lyricsYRC: "",
                    romanizationScripts: scripts)
        return engine.activeLine(atMs: 1000)?.romanization
    }

    let jaLyrics = "[00:01.00]こんにちは"
    expectEqual(romanization(lyrics: jaLyrics, roma: "", scripts: [.japanese]) != nil, true,
                "开关: 日文开 → 客户端兜底出罗马音")
    expectEqual(romanization(lyrics: jaLyrics, roma: "", scripts: [.korean, .chinese]), nil,
                "开关: 日文关 → 没有罗马音")

    // ⚠️ 最要紧的一条：服务端给了 lyrics_roma 时，开关同样要管得住。
    // 只拦客户端兜底的话，恰好有服务端罗马音的歌照样会显示，开关就成了看运气的东西。
    let zhLyrics = "[00:01.00]你对我笑一次"
    let zhRoma = "[00:01.00]ni dui wo xiao yi ci"
    expectEqual(romanization(lyrics: zhLyrics, roma: zhRoma, scripts: [.chinese]),
                "ni dui wo xiao yi ci", "开关: 中文开 → 用服务端给的罗马音")
    expectEqual(romanization(lyrics: zhLyrics, roma: zhRoma, scripts: [.japanese, .korean]), nil,
                "开关: 中文关 → 连服务端给的罗马音也不显示")

    // ⚠️ 绝大多数中文歌**没有**服务端 lyrics_roma（网易云不给中文歌算），所以"打开中文"
    // 能不能出拼音，全看客户端兜底放不放行。2026-08-15 真机验证时就栽在这儿：开关打开了，
    // 但引擎里另有一道硬编码的闸把中文兜底挡死，用户看到的是"开了等于没开"。
    let zhFallback = romanization(lyrics: zhLyrics, roma: "", scripts: [.chinese])
    expectEqual(zhFallback != nil, true, "开关: 中文开 + 服务端没给 → 客户端兜底出拼音")
    expectEqual(romanization(lyrics: zhLyrics, roma: "", scripts: [.japanese]), nil,
                "开关: 中文关 + 服务端没给 → 依然没有")

    // 中文默认是关的，所以默认配置下中文歌不该有罗马音（哪怕服务端给了）。
    expectEqual(romanization(lyrics: zhLyrics, roma: zhRoma, scripts: .default), nil,
                "开关: 默认配置下中文歌没有罗马音")

    // 韩文。
    let koLyrics = "[00:01.00]안녕하세요"
    expectEqual(romanization(lyrics: koLyrics, roma: "", scripts: [.korean]) != nil, true,
                "开关: 韩文开 → 有罗马音")
    expectEqual(romanization(lyrics: koLyrics, roma: "", scripts: [.japanese]), nil,
                "开关: 韩文关 → 没有罗马音")

    // 拉丁/其它文字不受这三个开关管辖，行为跟历来一致（这里原文就是拉丁，
    // romanize 会因为"音译结果等于原文"返回 nil，不该因为开关而改变）。
    expectEqual(romanization(lyrics: "[00:01.00]Hello", roma: "", scripts: []), nil,
                "开关: 拉丁原文本来就没有罗马音")
    expectEqual(romanization(lyrics: "[00:01.00]Hello", roma: "[00:01.00]Hello", scripts: []),
                "Hello", "开关: other 文字不受三个语言开关管辖")

    // ---- 「整首歌 vs 一行」:中文歌引用日文词不该让整首歌都出日文注音(2026-08-24) ----
    //
    // 用户报「怎么中文也注音了」:《这样吧》是中文歌,但引用了三次「サヨナラ」。原来的
    // 判据是"整首歌出现过一个假名就算日文",于是每行汉字都走日语形态分析 ——
    // 「就从明天开始吧」出成了「就从 mei ten 开始 吧」(mei ten = 明天的日文音读)。

    // 判据本身:含假名的**行**占比。
    expectEqual(Romanizer.kanaLineRatio("你好\n世界"), 0, "行占比: 纯中文 0%")
    expectEqual(Romanizer.kanaLineRatio("你好\nサヨナラ\n世界\n再见"), 0.25, "行占比: 4 行里 1 行有假名")
    // 空行不计入分母(歌词里空行很多)。
    expectEqual(Romanizer.kanaLineRatio("你好\n\n   \nサヨナラ"), 0.5, "行占比: 空行不进分母")
    expectEqual(Romanizer.kanaLineRatio(""), 0, "行占比: 空文本 0,不除零")

    // 真实形状:《这样吧》75 行里 3 行含假名(4.0%)→ 不是日文歌。
    let zhWithJa = (Array(repeating: "就从明天开始吧", count: 72) + Array(repeating: "サヨナラ", count: 3))
        .joined(separator: "\n")
    expectEqual(Romanizer.looksJapanese(zhWithJa), true, "旧判据: 出现过假名 → 会误判成日文")
    expectEqual(Romanizer.looksJapaneseSong(zhWithJa), false, "新判据: 4% 的行有假名 → 不是日文歌")
    expectEqual(Romanizer.songScript(of: zhWithJa), .chinese, "整首: 引用日文词的中文歌仍是中文")
    // 真·中日混唱(陶喆《My Anata》18/44 = 40.9%)同样不算日文歌 —— 它的日文行靠**按行**
    // 判定拿到罗马字,不需要把整首歌算成日文(那会连中文行一起注音)。
    let mixed = (Array(repeating: "我的あなた", count: 18) + Array(repeating: "你对我笑一次", count: 26))
        .joined(separator: "\n")
    expectEqual(Romanizer.looksJapaneseSong(mixed), false, "整首: 41% 的行有假名仍不算日文歌")
    // 真日文歌:几乎每行都含假名。
    let jaSong = Array(repeating: "こんにちは世界", count: 30).joined(separator: "\n")
    expectEqual(Romanizer.looksJapaneseSong(jaSong), true, "整首: 日文歌行行有假名 → 是日文歌")
    expectEqual(Romanizer.songScript(of: jaSong), .japanese, "整首: 日文歌 → japanese")

    // 按行判定:有假名/谚文的行按自己算,**纯汉字**行才退回整首歌。
    expectEqual(Romanizer.script(ofLine: "サヨナラ", song: .chinese), .japanese,
                "按行: 中文歌里的假名行仍是日文")
    expectEqual(Romanizer.script(ofLine: "就从明天开始吧", song: .chinese), .chinese,
                "按行: 中文歌里的纯汉字行是中文")
    expectEqual(Romanizer.script(ofLine: "明日", song: .japanese), .japanese,
                "按行: 日文歌里的纯汉字行退回整首歌的判断(汉字读音中日歧义)")
    expectEqual(Romanizer.script(ofLine: "안녕", song: .japanese), .korean, "按行: 谚文行是韩文")
    expectEqual(Romanizer.script(ofLine: "Hello", song: .japanese), .other, "按行: 拉丁行不受管辖")

    // ---- 引擎级端到端:同一首歌里两种行各按各的开关 ----
    func romanizationAt(
        _ ms: Int, lyrics: String, scripts: RomanizationScripts
    ) -> String? {
        let engine = LyricsSyncEngine()
        engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                    romanizationScripts: scripts)
        return engine.activeLine(atMs: ms)?.romanization
    }
    // 《这样吧》的形状:大量中文行 + 三行「サヨナラ」。默认配置(日文开、中文关)。
    var songLines: [String] = []
    for i in 0..<24 {
        songLines.append(String(format: "[%02d:%02d.00]就从明天开始吧", i / 60, i % 60))
    }
    songLines.append("[00:30.00]サヨナラ")
    let zhSongWithJa = songLines.joined(separator: "\n")
    // 中文行:默认配置下中文关 → 一个字都不该注音(改动前它会出「就从 mei ten 开始 吧」)。
    expectEqual(romanizationAt(1_000, lyrics: zhSongWithJa, scripts: .default), nil,
                "端到端: 中文歌的中文行不注音(哪怕歌里引用了日文词)")
    // 同一首歌的日文行:日文开 → 照样出罗马字。这是「按行判」相对「按整首歌判」的全部价值。
    let jaLineRoma = romanizationAt(30_000, lyrics: zhSongWithJa, scripts: .default)
    expectEqual(jaLineRoma != nil, true, "端到端: 同一首歌里引用的日文行仍出罗马字")
    expectEqual(jaLineRoma?.contains("sayonara") ?? false, true,
                "端到端: 那一行的罗马字是 sayonara(实际 \(jaLineRoma ?? "nil"))")
    // 把中文也打开时,中文行出的必须是**拼音**、不是日文音读。
    let zhLineRoma = romanizationAt(1_000, lyrics: zhSongWithJa,
                                    scripts: [.japanese, .korean, .chinese])
    expectEqual(zhLineRoma?.contains("mei") ?? true, false,
                "端到端: 中文行开了注音也是拼音,不是日文音读 mei ten(实际 \(zhLineRoma ?? "nil"))")
    expectEqual(zhLineRoma?.contains("m\u{00ED}ng") ?? false, true,
                "端到端: 中文行的注音是带声调的拼音 m\u{00ED}ng(实际 \(zhLineRoma ?? "nil"))")
}

// ---- 计次规则(ScrobbleRule):必须与 collector 的 listenThreshold/minTrackSecs 一致 ----
do {
    // 短于 30s 不计次(minTrackSecs)。
    expectEqual(ScrobbleRule.thresholdFraction(durationMs: 29_000), nil, "计次: 29s 的曲目不计次")
    expectEqual(ScrobbleRule.thresholdFraction(durationMs: 0), nil,
                "计次: 时长未知画不出刻度(collector 仍会在 240s 计,见 ScrobbleRule 注释)")
    // 普通长度:一半处计次。
    expectEqual(ScrobbleRule.thresholdFraction(durationMs: 200_000), 0.5, "计次: 200s 的歌在一半处计次")
    // 长歌封顶 240s(capSecs):600s 的歌在 240/600 = 0.4 处计次,不用等一半。
    expectEqual(ScrobbleRule.thresholdFraction(durationMs: 600_000), 0.4, "计次: 长歌 4 分钟封顶")
    // 恰好 480s 是两条规则的分界:min(240, 240) 都是 0.5。
    expectEqual(ScrobbleRule.thresholdFraction(durationMs: 480_000), 0.5, "计次: 480s 处两规则相等")
}

// ---- 菜单栏跑马灯:像素级偏移 ----
do {
    // 一段固定的参数:滚 100pt，每秒 50pt（走完要 2 秒），首尾各停 1 秒。
    // 于是一个完整周期 = 1 + 2 + 1 = 4 秒。
    func offset(_ elapsed: Double) -> CGFloat {
        MenuBarMarquee.scrollOffset(
            elapsed: elapsed, maxOffset: 100, pointsPerSecond: 50, holdSeconds: 1)
    }

    // 装得下就不滚。这条最要紧：maxOffset<=0 时若不早退，下面的除法会算出无穷大。
    expectEqual(
        MenuBarMarquee.scrollOffset(
            elapsed: 5, maxOffset: 0, pointsPerSecond: 50, holdSeconds: 1), 0,
        "像素滚动: 装得下(maxOffset=0)就不滚")
    expectEqual(
        MenuBarMarquee.scrollOffset(
            elapsed: 5, maxOffset: -10, pointsPerSecond: 50, holdSeconds: 1), 0,
        "像素滚动: maxOffset 为负也不滚")
    // 速度非正是调用方算错了，退化成不滚，而不是除零。
    expectEqual(
        MenuBarMarquee.scrollOffset(
            elapsed: 5, maxOffset: 100, pointsPerSecond: 0, holdSeconds: 1), 0,
        "像素滚动: 速度为 0 不除零")

    // 开头停留：这一段是整个设计的重点，一句歌词最该看清的是开头。
    expectEqual(offset(0), 0, "像素滚动: 第 0 秒停在开头")
    expectEqual(offset(0.99), 0, "像素滚动: 停留期内一直在开头")
    // 停留一结束就开始走，且是连续的——按字符那版这里会直接跳一整个字。
    expectEqual(offset(1.5), 25, "像素滚动: 停留结束后匀速前进")
    expectEqual(offset(2.0), 50, "像素滚动: 走到一半")
    // 末尾必须夹住，不能因为浮点乘法多算出一点点而露出右边的空白。
    expectEqual(offset(3.0), 100, "像素滚动: 走到底正好是 maxOffset")
    expectEqual(offset(3.5), 100, "像素滚动: 末尾停留期停在最右")

    // 循环：一个周期之后回到开头。歌词通常几秒就换一句、走不完一整轮，这只是兜底，
    // 但不能卡在末尾不动。
    expectEqual(offset(4.0), 0, "像素滚动: 满一个周期回到开头")
    expectEqual(offset(5.5), 25, "像素滚动: 第二轮的位置跟第一轮一致")

    // 时钟回拨/传负数不能跳到奇怪的位置（CACurrentMediaTime 单调，但这函数是纯的，
    // 不该对调用方的取值做假设）。负数会被归一化到周期内的某个位置，那没问题——
    // 真正要守的不变式是**偏移永远落在 [0, maxOffset]**：小于 0 会让文字往右跑出窗口，
    // 大于 maxOffset 会在右边露出一条空白。
    var offsetOutOfRange = 0
    for i in -80 ... 400 {
        let v = offset(Double(i) / 20)
        if v < 0 || v > 100 { offsetOutOfRange += 1 }
    }
    expectEqual(offsetOutOfRange, 0, "像素滚动: 扫全区间(含负数/多个周期)偏移都在 [0,maxOffset]")

    // 同一时刻反复问必须得到同一个答案（这条保证了"偏移没变就不重画"那个优化是安全的）。
    expectEqual(offset(2.0), offset(2.0), "像素滚动: 纯函数,同输入同输出")
}

// ---- 菜单栏跑马灯:关键帧与逐帧采样必须描述同一段运动 ----
//
// 2026-08-16 菜单栏从 MenuBarExtra 换成自建 NSStatusItem 之后，滚动不再由计时器逐帧
// 驱动，而是把 scrollKeyframes 交给 Core Animation 去插值。换驱动方式最容易出的事故
// 不是"不动了"（那一眼就看得见），而是**悄悄变了观感**：停留时长、速度、循环点任何
// 一个抄错，滚动看起来都还挺正常，只是跟以前不一样了。
//
// 所以这里不去单独断言关键帧的几个数字，而是拿上面那个已经测透的 scrollOffset 当验收
// 标准：对关键帧做线性插值（CA 的 .linear 就是这么算的），逐点跟 scrollOffset 对答案。
do {
    let maxOffset: CGFloat = 100
    let pps: CGFloat = 50
    let hold = 1.0

    /// 验收标准：上面那个已经测透的逐帧采样函数，同一组参数。
    func offsetReference(_ elapsed: Double) -> CGFloat {
        MenuBarMarquee.scrollOffset(
            elapsed: elapsed, maxOffset: maxOffset, pointsPerSecond: pps, holdSeconds: hold)
    }

    guard let frames = MenuBarMarquee.scrollKeyframes(
        maxOffset: maxOffset, pointsPerSecond: pps, holdSeconds: hold) else {
        expectEqual(true, false, "关键帧: 该滚的参数却返回了 nil")
        fatalError("unreachable")
    }

    // 周期跟逐帧那版一致：停 1 + 走 2 + 停 1 = 4 秒。
    expectEqual(frames.duration, 4.0, "关键帧: 一个周期 4 秒")
    expectEqual(frames.keyTimes.count, frames.offsets.count,
                "关键帧: keyTimes 与 offsets 一一对应")
    expectEqual(frames.keyTimes[0], 0, "关键帧: 从 0 开始")
    expectEqual(frames.keyTimes[frames.keyTimes.count - 1], 1, "关键帧: 到 1 结束")
    // keyTimes 必须单调不减，否则 CA 的插值结果是未定义的。
    var monotonic = true
    for i in 1 ..< frames.keyTimes.count where frames.keyTimes[i] < frames.keyTimes[i - 1] {
        monotonic = false
    }
    expectEqual(monotonic, true, "关键帧: keyTimes 单调不减")

    // CA 的 .linear 插值：给定周期内的时刻，在相邻两个关键帧之间线性取值。
    func interpolate(_ elapsed: Double) -> CGFloat {
        var t = elapsed.truncatingRemainder(dividingBy: frames.duration)
        if t < 0 { t += frames.duration }
        let normalized = t / frames.duration
        for i in 1 ..< frames.keyTimes.count {
            let t0 = frames.keyTimes[i - 1], t1 = frames.keyTimes[i]
            guard normalized <= t1 else { continue }
            guard t1 > t0 else { return frames.offsets[i] }
            let ratio = (normalized - t0) / (t1 - t0)
            return frames.offsets[i - 1]
                + (frames.offsets[i] - frames.offsets[i - 1]) * CGFloat(ratio)
        }
        return frames.offsets[frames.offsets.count - 1]
    }

    // 扫两个完整周期，每 0.05 秒一个采样点，逐点跟 scrollOffset 对答案。
    var worstGap = 0.0
    var worstAt = 0.0
    for i in 0 ... 160 {
        let elapsed = Double(i) / 20
        let gap = abs(Double(interpolate(elapsed) - offsetReference(elapsed)))
        if gap > worstGap { worstGap = gap; worstAt = elapsed }
    }
    // 允许极小的浮点误差（两条路径的乘除顺序不同），但不能有真实的行为差异。
    expectEqual(worstGap < 0.001, true,
                "关键帧: 与逐帧采样处处一致(最大偏差 \(worstGap) 出现在 t=\(worstAt)s)")

    // 装得下 / 速度非正 → 没有可滚的东西，必须是 nil 而不是一条跑不起来的空动画。
    expectEqual(
        MenuBarMarquee.scrollKeyframes(maxOffset: 0, pointsPerSecond: 50, holdSeconds: 1) == nil,
        true, "关键帧: 装得下就没有动画")
    expectEqual(
        MenuBarMarquee.scrollKeyframes(maxOffset: 100, pointsPerSecond: 0, holdSeconds: 1) == nil,
        true, "关键帧: 速度为 0 不生成动画(也不除零)")

    // 不停留(hold=0)时首尾两个关键帧会重合在同一时刻——这是合法的，但 keyTimes 仍然
    // 必须单调不减，不能出现 0.0 之后跟着一个负数这类会让 CA 插值发疯的输入。
    guard let noHold = MenuBarMarquee.scrollKeyframes(
        maxOffset: 100, pointsPerSecond: 50, holdSeconds: 0) else {
        expectEqual(true, false, "关键帧: hold=0 不该返回 nil")
        fatalError("unreachable")
    }
    expectEqual(noHold.keyTimes, [0, 0, 1, 1], "关键帧: 不停留时首尾各自重合")
    expectEqual(noHold.duration, 2.0, "关键帧: 不停留时周期就是走完全程的时间")
}

// ---- 菜单栏逐字染色:填色边界路径与剩余关键帧 ----
//
// 2026-08-22 加(用户点名"像酷狗菜单栏歌词")。填色跟滚动同一套哲学:整行进程编成一条
// CA 关键帧,装好后主线程一帧都不碰。这里钉死三件事:路径构造对脏数据的钳制、词间空隙
// 的"平保持"语义、以及"从任意时刻起步"的剩余关键帧跟静态取值(karaokeFillX)自洽。
do {
    // 三个词:0-500ms 宽 10pt、500-1000ms 累计到 30pt、1200-1500ms 累计到 60pt。
    // 第二、三个词之间有 200ms 空隙(伴奏),边界应停在 30pt 不动。
    let words = [
        SyncedLyricWord(text: "甲", startMs: 0, durationMs: 500),
        SyncedLyricWord(text: "乙", startMs: 500, durationMs: 500),
        SyncedLyricWord(text: "丙", startMs: 1200, durationMs: 300),
    ]
    let path = MenuBarMarquee.karaokeFillPath(words: words, wordEndXs: [10, 30, 60])
    expectEqual(path.isEmpty, false, "填色路径: 正常输入不为空")
    var msMonotonic = true
    var xMonotonic = true
    for i in 1 ..< path.count {
        if path[i].ms <= path[i - 1].ms { msMonotonic = false }
        if path[i].x < path[i - 1].x { xMonotonic = false }
    }
    expectEqual(msMonotonic, true, "填色路径: 时间严格递增(词首尾相接也被钳开)")
    expectEqual(xMonotonic, true, "填色路径: 边界单调不减")
    expectEqual(path[path.count - 1].x, 60, "填色路径: 终点停在整句末端")

    // 静态取值:词中线性、词间空隙平保持、路径外取端点。
    expectEqual(MenuBarMarquee.karaokeFillX(atMs: -100, path: path), 0, "填色取值: 开唱前是 0")
    expectEqual(MenuBarMarquee.karaokeFillX(atMs: 250, path: path), 5, "填色取值: 词中线性插值")
    expectEqual(MenuBarMarquee.karaokeFillX(atMs: 1100, path: path), 30, "填色取值: 词间空隙停住")
    expectEqual(MenuBarMarquee.karaokeFillX(atMs: 9999, path: path), 60, "填色取值: 唱完停在末端")

    // 剩余关键帧:从 250ms(第一个词唱到一半)起步。
    guard let frames = MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 250, rate: 1) else {
        expectEqual(true, false, "填色关键帧: 行没唱完却返回了 nil")
        fatalError("unreachable")
    }
    expectEqual(frames.widths[0], 5, "填色关键帧: 起点就是此刻的静态取值")
    expectEqual(frames.keyTimes[0], 0, "填色关键帧: 从 0 开始")
    expectEqual(frames.keyTimes[frames.keyTimes.count - 1], 1, "填色关键帧: 到 1 结束")
    expectEqual(frames.duration, 1.25, "填色关键帧: 时长 = 剩余毫秒 ÷ 1000 ÷ 速率")
    var ktMonotonic = true
    for i in 1 ..< frames.keyTimes.count where frames.keyTimes[i] <= frames.keyTimes[i - 1] {
        ktMonotonic = false
    }
    expectEqual(ktMonotonic, true, "填色关键帧: keyTimes 严格递增")
    expectEqual(frames.widths[frames.widths.count - 1], 60, "填色关键帧: 终点全填")

    // 速率折算:2x 播放剩余动画减半。
    expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 250, rate: 2)?.duration,
                0.625, "填色关键帧: 速率参与折算")
    // 没有可动余量的三种情况都必须是 nil,别留一条跑不起来的动画。
    expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 1500, rate: 1) == nil,
                true, "填色关键帧: 已唱完返回 nil")
    expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 250, rate: 0) == nil,
                true, "填色关键帧: 暂停(速率 0)返回 nil")
    expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: [], nowMs: 0, rate: 1) == nil,
                true, "填色关键帧: 空路径返回 nil")

    // 脏数据:时间戳乱序/重叠(酷狗偶发)钳成递增,x 跟着钳单调 —— CA 收到相等的
    // keyTimes 插值结果未定义,这层钳制是硬保证。
    let dirty = [
        SyncedLyricWord(text: "a", startMs: 300, durationMs: 400),
        SyncedLyricWord(text: "b", startMs: 200, durationMs: 100), // 起点倒退,还比前词早结束
    ]
    let dirtyPath = MenuBarMarquee.karaokeFillPath(words: dirty, wordEndXs: [20, 15]) // x 也倒退
    var dirtyOK = true
    for i in 1 ..< dirtyPath.count {
        if dirtyPath[i].ms <= dirtyPath[i - 1].ms || dirtyPath[i].x < dirtyPath[i - 1].x {
            dirtyOK = false
        }
    }
    expectEqual(dirtyOK, true, "填色路径: 乱序/倒退的脏数据被钳成合法单调序列")
    // 词数与宽度数组对不上是调用方 bug,宁可不染也不崩。
    expectEqual(MenuBarMarquee.karaokeFillPath(words: words, wordEndXs: [10]).isEmpty, true,
                "填色路径: 词数与宽度数不一致返回空")
}

// ---- 菜单栏跑马灯:按这一句的停留时长配速 ----
//
// 2026-08-17 用户报的:"一句歌词比较长的时候滚动太慢，还没滚到底就切换到下一行了"。
// 根因是速度写死成每秒 4 个字，跟这一句实际能显示多久完全脱钩——句子越长越看不到后半截。
//
// 下面这组断言把"能不能滚完"这件事本身钉死：不是断言某个速度数字，而是断言
// **首停 + 走完全程 + 尾停 ≤ 这一句的停留时长**。
do {
    /// 一句中文歌词的典型参数：13pt 菜单栏字，一个汉字约 13pt 宽。
    let charWidth: CGFloat = 13
    /// 用户设的显示宽度（默认档位附近）。
    let windowWidth: CGFloat = 80

    /// 这一句画出来有多宽 → 要滚多远。
    func maxOffset(chars: Int) -> CGFloat { CGFloat(chars) * charWidth - windowWidth }

    /// **滚到末尾**要多久（首停 + 走完全程）。这才是"看不看得到整句"的判据 ——
    /// 尾停是走完之后停在末尾等着换句，它超出 dwell 是故意的（见 loopGuardSeconds）。
    func finishTime(chars: Int, dwell: Double?) -> Double {
        let offset = maxOffset(chars: chars)
        let p = MenuBarMarquee.pacing(
            maxOffset: offset, averageCharWidth: charWidth, dwellSeconds: dwell)
        return p.headHoldSeconds + Double(offset / p.pointsPerSecond)
    }

    /// 以最快可读速度（上限）走完全程要多久 —— 比这还短的停留时长，物理上就滚不完。
    func travelAtCap(chars: Int) -> Double {
        Double(maxOffset(chars: chars) / (MenuBarMarquee.maxCharsPerSecond * charWidth))
    }

    // 不知道停留多久 → 完全维持改动之前的行为（这条是防回归：菜单栏歌词在拿不到
    // 歌词时间轴的场景下不该突然变快）。
    let unknown = MenuBarMarquee.pacing(
        maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: nil)
    expectEqual(unknown.pointsPerSecond, MenuBarMarquee.baseCharsPerSecond * charWidth,
                "配速: 不知道停留时长时用基准速度")
    expectEqual(unknown.headHoldSeconds, MenuBarMarquee.baseHoldSeconds, "配速: 未知时首停 1.5 秒")
    expectEqual(unknown.tailHoldSeconds, MenuBarMarquee.baseHoldSeconds, "配速: 未知时尾停 1.5 秒")

    // 用户报的那一类：30 字的长句，只显示 4 秒。
    //
    // 改动之前：速度 52pt/s，走完 310pt 要 5.96 秒，加上开头那 1.5 秒共 7.46 秒 ——
    // 而这一句 4 秒就换掉了，只滚过大约四成，后半截永远看不到。
    expectEqual(finishTime(chars: 30, dwell: nil) > 4.0, true,
                "配速: 长句 + 固定速度确实滚不完（这就是被报的 bug）")
    expectEqual(finishTime(chars: 30, dwell: 4.0) <= 4.0 + 0.001, true,
                "配速: 30 字长句在 4 秒内滚得完（\(finishTime(chars: 30, dwell: 4.0)) 秒）")

    // 扫一片真实取值范围。判据不是"全都滚得完"——句子长到一定程度、时间短到一定程度，
    // 在**可读速度上限之内**physically 就是走不完。所以断言的是那条真正的不变式：
    // **只要在上限速度下走得完，就必须走完**。
    var missed: [String] = []
    for chars in [12, 18, 24, 30, 40, 60] {
        for dwell in [2.0, 2.5, 3.0, 4.0, 5.0, 8.0, 12.0] {
            guard travelAtCap(chars: chars) <= dwell else { continue } // 物理上不可能，跳过
            if finishTime(chars: chars, dwell: dwell) > dwell + 0.001 {
                missed.append("\(chars)字/\(dwell)秒")
            }
        }
    }
    expectEqual(missed, [], "配速: 只要上限速度内走得完就一定走完")

    // 句尾预留(2026-08-19 用户反馈"一到最后一个字就马上到下一句了"):时间允许时,
    // 滚动必须比换句**提前** tailReadSeconds 走完,让末尾几个字来得及读。
    // 30 字 / 6 秒:改动前 travel 吃满 dwell - head,恰好 6.0 秒走完、尾停为 0。
    expectEqual(finishTime(chars: 30, dwell: 6.0)
                    <= 6.0 - MenuBarMarquee.tailReadSeconds + 0.001, true,
                "配速: 时间允许时提前 \(MenuBarMarquee.tailReadSeconds) 秒滚完,句尾留得住"
                    + "(\(finishTime(chars: 30, dwell: 6.0)) 秒)")
    // 时间紧时尾停先让路(先于首停),整句可见仍然优先:2.1 秒里 30 字撞着上限刚好
    // 走得完,不能为了句尾预留把滚动挤到滚不完。
    expectEqual(finishTime(chars: 30, dwell: 2.1) <= 2.1 + 0.001, true,
                "配速: 时间紧时尾停让路,不挤掉滚动本身")

    // 停留时间很长的句子不该被拖快——那是现有观感，没人抱怨，不动它。
    let roomy = MenuBarMarquee.pacing(
        maxOffset: maxOffset(chars: 14), averageCharWidth: charWidth, dwellSeconds: 20)
    expectEqual(roomy.pointsPerSecond, MenuBarMarquee.baseCharsPerSecond * charWidth,
                "配速: 时间充裕时仍走基准速度，不会无谓地甩快")
    // 而且**只滚一轮**：走完就停在末尾等着换句，不会反复从头再来（那样很闹）。
    expectEqual(roomy.headHoldSeconds + Double(maxOffset(chars: 14) / roomy.pointsPerSecond)
                    + roomy.tailHoldSeconds >= 20, true,
                "配速: 时间充裕时一句只滚一轮，不会循环重来")

    // 首尾停顿必须跟着句子时长缩：一句只显示 2 秒时，照搬 1.5+1.5 等于根本没滚。
    let tight = MenuBarMarquee.pacing(
        maxOffset: maxOffset(chars: 30), averageCharWidth: charWidth, dwellSeconds: 2.0)
    expectEqual(tight.headHoldSeconds < 2.0, true, "配速: 短句的开头停顿不会吃光整句时间")

    // 速度有上限，不会为了滚完把字甩成残影。
    let absurd = MenuBarMarquee.pacing(
        maxOffset: maxOffset(chars: 120), averageCharWidth: charWidth, dwellSeconds: 2.0)
    expectEqual(absurd.pointsPerSecond <= MenuBarMarquee.maxCharsPerSecond * charWidth,
                true, "配速: 速度不超过每秒 12 个字的上限")
    // 而撞到上限之后它**确实滚不完** —— 这是明知的取舍，钉在这里免得以后被当成 bug 去"修"：
    // 比起把字甩成一片糊影，宁可少看几个字。
    expectEqual(finishTime(chars: 120, dwell: 2.0) > 2.0, true,
                "配速: 极端长句撞上限后滚不完（已知且接受的取舍）")
    // 这种情况下开头那一停必须让到 0 —— 一秒都不该浪费在"停着"上。
    expectEqual(absurd.headHoldSeconds, 0, "配速: 时间不够时开头那一停让到 0")

    // 停留时间短到连停顿都塞不下时，不能除以一个≈0 的数算出无穷大速度。
    let sliver = MenuBarMarquee.pacing(
        maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: 0.06)
    expectEqual(sliver.pointsPerSecond.isFinite && sliver.pointsPerSecond > 0, true,
                "配速: 停留时间极短也算得出有限速度")

    // 关键帧和逐帧采样在**首尾不等长**时也必须描述同一段运动（上一组只验了等长的情况）。
    let pacing = MenuBarMarquee.pacing(
        maxOffset: maxOffset(chars: 30), averageCharWidth: charWidth, dwellSeconds: 4.0)
    let offset = maxOffset(chars: 30)
    guard let frames = MenuBarMarquee.scrollKeyframes(
        maxOffset: offset, pointsPerSecond: pacing.pointsPerSecond,
        headHoldSeconds: pacing.headHoldSeconds, tailHoldSeconds: pacing.tailHoldSeconds) else {
        expectEqual(true, false, "配速: 该滚的参数却没有关键帧")
        fatalError("unreachable")
    }
    func interpolate(_ elapsed: Double) -> CGFloat {
        var t = elapsed.truncatingRemainder(dividingBy: frames.duration)
        if t < 0 { t += frames.duration }
        let normalized = t / frames.duration
        for i in 1 ..< frames.keyTimes.count {
            let t0 = frames.keyTimes[i - 1], t1 = frames.keyTimes[i]
            guard normalized <= t1 else { continue }
            guard t1 > t0 else { return frames.offsets[i] }
            let ratio = (normalized - t0) / (t1 - t0)
            return frames.offsets[i - 1] + (frames.offsets[i] - frames.offsets[i - 1]) * CGFloat(ratio)
        }
        return frames.offsets[frames.offsets.count - 1]
    }
    var worst = 0.0
    for i in 0 ... 200 {
        let elapsed = Double(i) / 25
        let reference = MenuBarMarquee.scrollOffset(
            elapsed: elapsed, maxOffset: offset, pointsPerSecond: pacing.pointsPerSecond,
            headHoldSeconds: pacing.headHoldSeconds, tailHoldSeconds: pacing.tailHoldSeconds)
        worst = max(worst, abs(Double(interpolate(elapsed) - reference)))
    }
    expectEqual(worst < 0.001, true, "配速: 首尾不等长时关键帧仍与逐帧采样一致(最大偏差 \(worst))")

    // ---- 提前量:开唱之前一步都不许滚(2026-08-24) ----
    //
    // 用户报的:「已经到下一行了,但是还没开始染色的时候不需要滚动,现在是会滚」。单行展示面
    // 会在上一句唱完、本句还没开唱之前就把本句亮出来(CompactLyricLead.revealMs,最长 5 秒),
    // 那段时间它是**没有染色**的;而 head 原来只看 baseHoldSeconds(1.5 秒),提前量一超过它,
    // 一句还没开唱的歌词就自己先滚起来了。实测提前量平均 0.90s、p90 1.75s、p95 3.03s
    // (12893 个行间隙),所以这不是边缘情况。
    //
    // 下面这组断言钉的是三件事:① 提前量之内绝不滚;② 提前量为 0 时逐字段维持旧行为;
    // ③ 扣掉提前量之后"能滚完就必须滚完"(提前量不能变成放弃滚完的借口)。

    /// 滚到末尾要多久(首停 + 走完全程),带提前量的版本。
    func finishTimeLed(chars: Int, dwell: Double?, lead: Double) -> Double {
        let offset = maxOffset(chars: chars)
        let p = MenuBarMarquee.pacing(
            maxOffset: offset, averageCharWidth: charWidth, dwellSeconds: dwell,
            leadInSeconds: lead)
        return p.headHoldSeconds + Double(offset / p.pointsPerSecond)
    }

    // ① 首停必须**至少**盖住提前量 —— 这就是"开唱之前不滚"落到参数上的形状。
    //    取值覆盖实测分布(中位 0.22、均值 0.90、p90 1.75、p95 3.03)和上限 5.0。
    var scrolledTooEarly: [String] = []
    var loopedTooSoon: [String] = []
    for lead in [0.0, 0.22, 0.9, 1.75, 3.03, 5.0] {
        for dwell in [2.0, 3.0, 4.0, 6.0, 12.0, 30.0] where dwell > lead {
            for chars in [12, 30, 60, 120] {
                let p = MenuBarMarquee.pacing(
                    maxOffset: maxOffset(chars: chars), averageCharWidth: charWidth,
                    dwellSeconds: dwell, leadInSeconds: lead)
                if p.headHoldSeconds + 1e-9 < lead {
                    scrolledTooEarly.append("\(chars)字/\(dwell)秒/提前\(lead)秒"
                        + "→首停\(p.headHoldSeconds)")
                }
                // 顺手钉住"一轮盖住整个显示窗口":提前量是折进首停的,而滚动动画
                // repeatCount = .infinity —— 一旦周期短于显示窗口,第二轮会在句子还在唱
                // 的时候把首停(现在含提前量,最长 5 秒)**再停一遍**,末尾几个字闪一下跳回
                // 开头。loopGuardSeconds 那条老约束在带提前量时同样不能破。
                let cycle = p.headHoldSeconds
                    + Double(maxOffset(chars: chars) / p.pointsPerSecond) + p.tailHoldSeconds
                if cycle + 1e-9 < dwell + MenuBarMarquee.loopGuardSeconds {
                    loopedTooSoon.append("\(chars)字/\(dwell)秒/提前\(lead)秒→周期\(cycle)")
                }
            }
        }
    }
    expectEqual(scrolledTooEarly, [], "配速: 提前量之内一步都不滚(首停 >= 提前量)")
    expectEqual(loopedTooSoon, [], "配速: 带提前量时一轮仍盖住显示窗口,不会在句中循环重停")

    // ② 提前量为 0 时必须跟改动前**逐字段**一致 —— 绝大多数换行(中位间隙 0.22s)靠这条
    //    保证观感没被顺手改掉;行级 LRC 的提前量恒为 0,整条也走这一档。
    var drifted: [String] = []
    for chars in [12, 30, 60] {
        for dwell in [nil, 2.0, 4.0, 8.0, 20.0] as [Double?] {
            let before = MenuBarMarquee.pacing(
                maxOffset: maxOffset(chars: chars), averageCharWidth: charWidth,
                dwellSeconds: dwell)
            let after = MenuBarMarquee.pacing(
                maxOffset: maxOffset(chars: chars), averageCharWidth: charWidth,
                dwellSeconds: dwell, leadInSeconds: 0)
            if before != after { drifted.append("\(chars)字/\(String(describing: dwell))") }
        }
    }
    expectEqual(drifted, [], "配速: 提前量为 0 时跟改动前逐字段一致")

    // ③ 扣掉提前量之后只要走得完就必须走完 —— 抬高 head 之后 travel 是从 dwell 里扣掉
    //    head 算的,所以不能滚的那段时间是**自动**从行程里去掉的,不会重蹈 2026-08-17
    //    那个"按偏大的 dwell 配速、长句只滚出开头一小截"的坑。
    var missedWithLead: [String] = []
    for chars in [12, 18, 24, 30, 40] {
        for lead in [0.22, 0.9, 1.75, 3.0] {
            for dwell in [3.0, 4.0, 6.0, 8.0, 12.0] {
                guard lead + travelAtCap(chars: chars) <= dwell else { continue } // 物理上不可能
                if finishTimeLed(chars: chars, dwell: dwell, lead: lead) > dwell + 0.001 {
                    missedWithLead.append("\(chars)字/\(dwell)秒/提前\(lead)秒")
                }
            }
        }
    }
    expectEqual(missedWithLead, [], "配速: 扣掉提前量之后能滚完的就一定滚完")

    // 一整轮(首停+行程+尾停)仍然覆盖整个显示窗口 —— 否则换句之前会先循环回开头,
    // 末尾几个字闪一下就跳走(loopGuardSeconds 那条老约束,提前量不能把它破掉)。
    let led = MenuBarMarquee.pacing(
        maxOffset: maxOffset(chars: 30), averageCharWidth: charWidth,
        dwellSeconds: 8.0, leadInSeconds: 5.0)
    expectEqual(led.headHoldSeconds, 5.0, "配速: 提前量 5 秒时首停就是 5 秒")
    expectEqual(led.headHoldSeconds + Double(maxOffset(chars: 30) / led.pointsPerSecond)
                    + led.tailHoldSeconds >= 8.0, true,
                "配速: 带提前量时一整轮仍覆盖显示窗口,不会在换句前循环回开头")

    // 不知道停留多久那条路(最后一句/拿不到时间轴)也要等到开唱 —— 它原来固定 1.5 秒。
    let unknownLed = MenuBarMarquee.pacing(
        maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: nil, leadInSeconds: 3.0)
    expectEqual(unknownLed.headHoldSeconds, 3.0, "配速: 停留时长未知时也要等到开唱才滚")

    // 脏数据:提前量比 revealMs 还长(上游时钟/时间轴出错)。head 是**死等**,不钳住的话
    // 一次脏数据就能把跑马灯钉死不动。
    let overlong = MenuBarMarquee.pacing(
        maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: 2.0, leadInSeconds: 9.0)
    expectEqual(overlong.headHoldSeconds, Double(CompactLyricLead.revealMs) / 1000,
                "配速: 提前量超出 revealMs 被钳住,不会把跑马灯钉死")
    expectEqual(overlong.pointsPerSecond.isFinite && overlong.pointsPerSecond > 0
                    && overlong.tailHoldSeconds >= 0, true,
                "配速: 提前量脏数据下参数仍然有限且非负")
    // 负数(时钟回拨)按 0 处理,不能算出负的首停。
    expectEqual(MenuBarMarquee.pacing(maxOffset: 300, averageCharWidth: charWidth,
                                      dwellSeconds: 4.0, leadInSeconds: -3.0),
                MenuBarMarquee.pacing(maxOffset: 300, averageCharWidth: charWidth,
                                      dwellSeconds: 4.0),
                "配速: 提前量为负(时钟回拨)时按 0 处理")

    // 带提前量的关键帧同样必须跟逐帧采样描述同一段运动 —— 上面两组只验了提前量为 0 的情况,
    // 而 CA 那边真正跑的就是这条关键帧。
    /// 关键帧线性插值(CA 的 .linear 就是这么算的)。刻意不跟上面那个同名 helper 合并:
    /// 它捕获的是上面那组 frames,而**同一个文件里已经有两个 interpolate**了,再抽一层
    /// 公共函数只会让"这条断言在验哪一组关键帧"更难看清。
    func interpolateLed(_ frames: MenuBarMarquee.ScrollKeyframes, _ elapsed: Double) -> CGFloat {
        var t = elapsed.truncatingRemainder(dividingBy: frames.duration)
        if t < 0 { t += frames.duration }
        let normalized = t / frames.duration
        for i in 1 ..< frames.keyTimes.count {
            let t0 = frames.keyTimes[i - 1], t1 = frames.keyTimes[i]
            guard normalized <= t1 else { continue }
            guard t1 > t0 else { return frames.offsets[i] }
            let ratio = (normalized - t0) / (t1 - t0)
            return frames.offsets[i - 1] + (frames.offsets[i] - frames.offsets[i - 1]) * CGFloat(ratio)
        }
        return frames.offsets[frames.offsets.count - 1]
    }
    guard let ledFrames = MenuBarMarquee.scrollKeyframes(
        maxOffset: maxOffset(chars: 30), pointsPerSecond: led.pointsPerSecond,
        headHoldSeconds: led.headHoldSeconds, tailHoldSeconds: led.tailHoldSeconds) else {
        expectEqual(true, false, "配速: 带提前量该滚的参数却没有关键帧")
        fatalError("unreachable")
    }
    var ledWorst = 0.0
    for i in 0 ... 400 {
        let elapsed = Double(i) / 25
        let reference = MenuBarMarquee.scrollOffset(
            elapsed: elapsed, maxOffset: maxOffset(chars: 30),
            pointsPerSecond: led.pointsPerSecond,
            headHoldSeconds: led.headHoldSeconds, tailHoldSeconds: led.tailHoldSeconds)
        ledWorst = max(ledWorst, abs(Double(interpolateLed(ledFrames, elapsed) - reference)))
    }
    expectEqual(ledWorst < 0.001, true,
                "配速: 带提前量时关键帧仍与逐帧采样一致(最大偏差 \(ledWorst))")
    // 提前量走完之前偏移必须**恒为 0**(这是"没染色不滚"最直接的形状)。
    var movedEarly: [String] = []
    for i in 0 ... 50 {
        let elapsed = 5.0 * Double(i) / 50
        let offset = MenuBarMarquee.scrollOffset(
            elapsed: elapsed, maxOffset: maxOffset(chars: 30),
            pointsPerSecond: led.pointsPerSecond,
            headHoldSeconds: led.headHoldSeconds, tailHoldSeconds: led.tailHoldSeconds)
        if offset != 0 { movedEarly.append("\(elapsed)s→\(offset)") }
    }
    expectEqual(movedEarly, [], "配速: 提前量 5 秒之内偏移恒为 0")
}

// ---- 署名行:关键词连写 ----
do {
    // 2026-08-15 用户实测漏网的形状：「词曲：蔡徐坤 KUN/Marco Bernardis/…」被当歌词
    // 显示在悬浮窗上。旧正则要求关键词紧跟冒号，而"词曲"是两个关键词连着写。
    let engine = LyricsSyncEngine()
    engine.load(
        lyrics: """
        [00:01.00]词曲：蔡徐坤 KUN/Marco Bernardis
        [00:02.00]作词作曲：某某某
        [00:03.00]词 曲 编：三个连写还带空格
        [00:04.00]他说：我不走
        [00:05.00]真正的歌词在这里
        [00:06.00]又一句歌词
        [00:07.00]再来一句
        [00:08.00]还有一句
        """,
        lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
    expectEqual(engine.activeLine(atMs: 1500)?.mainText, nil, "署名行: 「词曲：」连写被过滤")
    expectEqual(engine.activeLine(atMs: 2500)?.mainText, nil, "署名行: 「作词作曲：」被过滤")
    expectEqual(engine.activeLine(atMs: 3500)?.mainText, nil, "署名行: 「词 曲 编：」带空格连写被过滤")
    // ⚠️ 反例最要紧：带冒号的真歌词不能跟着一起被删掉。
    //
    // 后面那三句普通歌词是**必须**的，不是凑数：整份粒度的结构化规则(1~8 个汉字 + 冒号)
    // 在"命中 >= 3 行且过半"时才启用，而「他说：」正好长这个形状。只写 5 行的话署名行
    // 就把整份主导了，结构化规则一开，这句真歌词会被连坐删掉 —— 那是既有设计的取舍，
    // 不是这次要测的东西。补足真歌词行让比例回到真实歌曲的样子(一两行署名 + 一堆歌词)，
    // 这条断言才是在单独考"关键词连写"那一条规则。
    expectEqual(engine.activeLine(atMs: 4500)?.mainText, "他说：我不走",
                "署名行: 带冒号的真歌词不被误杀")
    expectEqual(engine.activeLine(atMs: 5500)?.mainText, "真正的歌词在这里", "署名行: 真歌词保留")
}

// ---- 地板量化源的前向棘轮 ----
do {
    typealias Tier = LocalPlaybackSource.PositionSourceTier
    func ratchet(_ reported: Double, _ predicted: Double, tier: Tier) -> Bool {
        LocalPlaybackSource.shouldRatchetForward(
            reported: reported, predicted: predicted, tier: tier)
    }
    // QQ 音乐实测的形状：新锚点比外推值靠前 1 秒（旧锚点被向下取整拖晚了）。
    expectEqual(ratchet(23.1, 22.1, tier: .noisyFloored), true, "棘轮: 前向 1s 立刻采纳")
    expectEqual(ratchet(22.4, 22.1, tier: .noisyFloored), true, "棘轮: 前向 0.3s(半个字)也采纳")
    // 反方向分不清是取整噪声还是真实回退，绝不能棘轮 —— 交给原有 EMA 路径。
    expectEqual(ratchet(21.5, 22.1, tier: .noisyFloored), false, "棘轮: 后向不采纳(交给 EMA)")
    // 同锚点外推的 ±2ms 漂移不值得重建锚点。
    expectEqual(ratchet(22.102, 22.1, tier: .noisyFloored), false, "棘轮: 毫米级漂移不触发")
    // 精确源(Apple Music)的读数本来就是真值，不适用"reported ≤ 真实位置"这条
    // 不等式，走原有 EMA。
    expectEqual(ratchet(23.1, 22.1, tier: .precise), false, "棘轮: 精确源不适用")
    // Spotify(cleanExtrapolated)的读数恒略**超前**真值(2026-08-18 实测),棘轮前提
    // 正好反着——只往前吸附会把位置锁在抖动上包络,2026-08-18 拆档时明确排除。
    expectEqual(ratchet(23.1, 22.1, tier: .cleanExtrapolated), false,
                "棘轮: Spotify 干净外推源不适用")
}

// ---- 署名行:连接词形态 ----
do {
    // 2026-08-16 用户实测漏网：「制作和编曲：方大同」「所有乐器和编程：Soulboy」显示在
    // 悬浮窗上。角色词之间夹着"和"，旧规则要求角色词紧挨连写就断了。
    // 只放两行署名 + 四行真歌词：结构化规则(要求命中主导整份)在这个比例下不启用，
    // 这里单独考的是关键词规则。
    let engine = LyricsSyncEngine()
    engine.load(
        lyrics: """
        [00:01.00]制作和编曲：方大同
        [00:02.00]所有乐器和编程：Soulboy
        [00:03.00]他说：我不走
        [00:04.00]真正的歌词
        [00:05.00]又一句歌词
        [00:06.00]再来一句
        """,
        lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
    expectEqual(engine.activeLine(atMs: 1500)?.mainText, nil, "署名行: 「制作和编曲：」被过滤")
    expectEqual(engine.activeLine(atMs: 2500)?.mainText, nil, "署名行: 「所有乐器和编程：」被过滤")
    expectEqual(engine.activeLine(atMs: 3500)?.mainText, "他说：我不走",
                "署名行: 连接词规则不误杀对白式冒号")
    expectEqual(engine.activeLine(atMs: 4500)?.mainText, "真正的歌词", "署名行: 真歌词保留")
}

// ---- 署名行:双字角色词(组合词,首尾都管) ----
do {
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("数字编辑：Jeff Li"), true,
                "角色词: 数字编辑(含「编辑」)")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("母带处理：Randy Merrill@Sterling Sound"), true,
                "角色词: 母带处理(含「母带」)")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("弦乐录制工程师：某某"), true,
                "角色词: 组合词自动覆盖,不用逐词补表")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("演唱：Jeremy McKinnon (A Day To Remember)、MAX、henry 刘宪华"), true,
                "角色词: 演唱(第八轮,2026-08-17 用户报的漏网)")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("原唱：张学友"), true, "角色词: 原唱")
    // 反例们:
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("他说：我不走"), false,
                "角色词: 对白式冒号不误杀")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("曲婉婷：好久不见"), false,
                "角色词: 歌手名标签(对唱)不误杀 —— 只认双字词,单字「曲」不算")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("回忆："), false,
                "角色词: 冒号后没内容(语气停顿)不算")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("这一句歌词很长很长超过八个字：也不算"), false,
                "角色词: 标签超过 8 字不像职员表")
    expectEqual(LyricsSyncEngine.matchesRoleWordCredit("Mixing：某某"), false,
                "角色词: 拉丁标签不归这条管(有 latin 规则)")
}

// ---- 封面取色:HSB 提亮 + 压饱和 ----
do {
    func accent(_ r: Double, _ g: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
        LocalPlaybackSource.brightenedAccent(r: r, g: g, b: b)
    }
    func brightness(_ c: (r: Double, g: Double, b: Double)) -> Double { max(c.r, max(c.g, c.b)) }
    func saturation(_ c: (r: Double, g: Double, b: Double)) -> Double {
        let mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b))
        return mx <= 0 ? 0 : (mx - mn) / mx
    }

    // 近黑封面：不再从压缩噪点里"抢救"色相 —— 旧实现会把 (2,1,3)/255 放大 11 倍，
    // 同一张黑封面每次取到的颜色都不一样。
    let nearBlack = accent(2/255, 1/255, 3/255)
    expectEqual(saturation(nearBlack) < 0.01, true, "取色: 近黑封面兜底成中性灰(无色相)")
    expectEqual(accent(0, 0, 0) == accent(2/255, 1/255, 3/255), true,
                "取色: 近黑结果稳定,不随噪点变化")

    // 够亮的颜色原样放行。
    let bright = accent(0.9, 0.4, 0.4)
    expectEqual(bright.r == 0.9 && bright.g == 0.4, true, "取色: 亮度够就不动它")

    // 暗色被提到下限；关键是饱和度**同时**被按比例压低（旧实现只提亮、饱和度不变，刺眼）。
    let darkRed = accent(0.30, 0.02, 0.02)
    expectEqual(abs(brightness(darkRed) - 0.62) < 0.001, true, "取色: 暗色提亮到下限 0.62")
    expectEqual(saturation(darkRed) < saturation((r: 0.30, g: 0.02, b: 0.02)), true,
                "取色: 提亮的同时压低饱和度(不刺眼)")

    // 色相必须守住：暗红提亮后仍是红,不能变色。
    expectEqual(darkRed.r > darkRed.g && darkRed.r > darkRed.b, true, "取色: 色相不漂移(红仍是红)")
    let darkBlue = accent(0.02, 0.05, 0.30)
    expectEqual(darkBlue.b > darkBlue.r && darkBlue.b > darkBlue.g, true, "取色: 蓝仍是蓝")
    let darkGreen = accent(0.03, 0.28, 0.05)
    expectEqual(darkGreen.g > darkGreen.r && darkGreen.g > darkGreen.b, true, "取色: 绿仍是绿")

    // 灰(无色相)提亮后仍是灰,不能凭空生出颜色。
    let darkGray = accent(0.2, 0.2, 0.2)
    expectEqual(saturation(darkGray) < 0.01, true, "取色: 灰提亮后仍是灰")

    // 全区间扫描：输出永远在 [0,1]，且亮度不低于下限。
    var bad = 0
    for i in 0 ... 20 {
        for j in 0 ... 20 {
            let c = accent(Double(i) / 20, Double(j) / 20, 0.5)
            if c.r < 0 || c.r > 1 || c.g < 0 || c.g > 1 || c.b < 0 || c.b > 1 { bad += 1 }
            if brightness(c) < 0.61 { bad += 1 }
        }
    }
    expectEqual(bad, 0, "取色: 全区间扫描输出合法且亮度达标")
}

// ---- 封面取色:深色背景的感知亮度地板(灵动岛) ----
// brightenedAccent 保的是 HSB brightness(RGB 最大分量),但人眼三通道敏感度差一个
// 数量级——饱和纯蓝 brightness 满格、luma 只有 0.07,原样过 0.62 的地板,贴在灵动岛
// 的深色背景上区分度差。accentForDarkBackdrop 在其结果之上再保一道 Rec.709 luma 下限。
do {
    func lift(_ r: Double, _ g: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
        LocalPlaybackSource.accentForDarkBackdrop(r: r, g: g, b: b)
    }
    func luma(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    // 动机本尊:纯蓝(HSB 亮度满格,旧地板完全不管)必须被提到感知亮度地板,
    // 且提亮走"混白"方向——蓝仍是最大分量(色相族不变),红绿等量上浮(不偏色)。
    let blue = lift(0, 0, 1)
    expectEqual(abs(luma(blue) - 0.62) < 0.001, true, "深背景取色: 纯蓝恰好提到 luma 地板")
    expectEqual(blue.b > blue.r && abs(blue.r - blue.g) < 0.001, true,
                "深背景取色: 混白提亮,蓝仍是蓝且不偏色")

    // 已经够亮的原样放行——暖色/浅色封面(luma 本来就高)完全不受这次改动影响。
    let warm = lift(0.9, 0.7, 0.4)
    expectEqual(warm == (r: 0.9, g: 0.7, b: 0.4), true, "深背景取色: luma 够高就一动不动")
    expectEqual(lift(1, 1, 1) == (r: 1.0, g: 1.0, b: 1.0), true, "深背景取色: 纯白不动(不除零)")

    // 全区间扫描:输出永远在 [0,1],且 luma 不低于地板。
    var bad = 0
    for i in 0 ... 20 {
        for j in 0 ... 20 {
            for k in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let c = lift(Double(i) / 20, Double(j) / 20, k)
                if c.r < 0 || c.r > 1 || c.g < 0 || c.g > 1 || c.b < 0 || c.b > 1 { bad += 1 }
                if luma(c) < 0.619 { bad += 1 }
            }
        }
    }
    expectEqual(bad, 0, "深背景取色: 全区间扫描输出合法且 luma 达标")
}

// ---- 封面取图:载荷曲目标识比对(2026-08-17) ----
//
// 用户报网易云云盘歌"沿用上一首的封面":切歌瞬间 get --now 可能整条还是上一首(旧标题+
// 旧封面),原实现拿到非 nil 就定案,把上一首的封面错挂到新歌上。修法是封面载荷带上自己的
// artist/title 算 trackKey,跟当前曲目对不上就按"系统侧还没更新完"重试。
do {
    // 推导必须跟快照那份逐字符一致——两处各写一份的话,一旦漂移,每首歌都会被误判成
    // "别的歌的封面"而永远显示占位。
    expectEqual(MediaControlSnapshot.trackKey(artist: "周杰伦", title: "以父之名"),
                "周杰伦|以父之名", "封面标识: trackKey 推导 artist|title")
    expectEqual(MediaControlSnapshot.trackKey(artist: nil, title: nil), "|",
                "封面标识: 字段缺失时退化为空段,不崩")

    expectEqual(LocalPlaybackSource.artworkKeyMatches("周杰伦|以父之名", "周杰伦|以父之名"),
                true, "封面标识: 同一首歌匹配")
    expectEqual(LocalPlaybackSource.artworkKeyMatches("周杰伦|以父之名", "周杰伦|一路向北"),
                false, "封面标识: 上一首的载荷必须判不匹配")
    // 大小写不敏感:media-control 对同一首歌报过大小写不一致的元数据("2 Bad"/"Scream"
    // 在 enrich 缓存踩过同源的坑),按敏感比对会把这类歌误判成别的歌、永远显示占位。
    expectEqual(LocalPlaybackSource.artworkKeyMatches("Michael Jackson|2 BAD", "Michael Jackson|2 Bad"),
                true, "封面标识: 大小写偏差算同一首")
}

// ---- 封面取色:桌面悬浮歌词按"跟描边够对比"调(2026-08-17) ----
//
// 这一组是为一次真实回归补的:08-16 把近黑封面兜底成 0.72 浅灰(为灵动岛的深色背景调的),
// 桌面悬浮歌词一起吃了这条规则,用户又开着不透明白描边 —— 浅灰字被白描边吃掉,压在浅色
// 窗口上几乎看不见(实测屏幕上最暗的不透明像素 #ADABA6,相对亮度 0.671,而描边是纯白)。
// 所以这里断言的核心不是"输出多亮",而是**输出跟描边的对比度达标**,以及"本来就达标的
// 颜色一动不动"——后者才是"别擅自改用户看惯的颜色"这条约束。
do {
    func fit(_ c: (Double, Double, Double), stroke: (Double, Double, Double),
             minContrast: Double = 3.0) -> (r: Double, g: Double, b: Double) {
        LocalPlaybackSource.accentAgainstStroke(
            r: c.0, g: c.1, b: c.2,
            strokeR: stroke.0, strokeG: stroke.1, strokeB: stroke.2,
            minContrast: minContrast)
    }
    func lum(_ c: (r: Double, g: Double, b: Double)) -> Double {
        LocalPlaybackSource.relativeLuminance(r: c.r, g: c.g, b: c.b)
    }
    func contrastWith(_ c: (r: Double, g: Double, b: Double),
                      _ stroke: (Double, Double, Double)) -> Double {
        LocalPlaybackSource.contrastRatio(
            lum(c), LocalPlaybackSource.relativeLuminance(r: stroke.0, g: stroke.1, b: stroke.2))
    }

    let white = (1.0, 1.0, 1.0)
    let black = (0.0, 0.0, 0.0)

    // 动机本尊:0.72 中性灰 + 不透明白描边,正是用户屏幕上那一幕。必须被压暗到达标。
    let grey = fit((0.72, 0.72, 0.72), stroke: white)
    expectEqual(contrastWith(grey, white) >= 2.99, true, "描边取色: 浅灰配白描边被压到达标")
    expectEqual(lum(grey) < LocalPlaybackSource.relativeLuminance(r: 0.72, g: 0.72, b: 0.72),
                true, "描边取色: 白描边下是往暗的方向调")

    // 近黑封面:噪点色相要被抹掉(三通道相等),但"它很暗"这个真信息要保留 ——
    // 不能像 brightenedAccent 那样连亮度一起换成固定浅灰。配白描边时本来就够对比,不动。
    let nearBlack = fit((2 / 255.0, 1 / 255.0, 3 / 255.0), stroke: white)
    expectEqual(abs(nearBlack.r - nearBlack.g) < 1e-9 && abs(nearBlack.g - nearBlack.b) < 1e-9,
                true, "描边取色: 近黑抹掉噪点色相变中性灰")
    expectEqual(nearBlack.r < 0.03, true, "描边取色: 近黑保留自己的暗度,不被抬成浅灰")

    // 够对比的颜色一动不动 —— 绝大多数封面走这条,不该擅自改色。
    let deep = (0.15, 0.10, 0.30)
    let untouched = fit(deep, stroke: white)
    expectEqual(untouched == (r: deep.0, g: deep.1, b: deep.2), true,
                "描边取色: 已经够对比就原样返回")

    // 描边反过来是黑的:该往亮的方向调,而不是继续压暗。
    let darkOnBlack = fit((0.12, 0.10, 0.08), stroke: black)
    expectEqual(contrastWith(darkOnBlack, black) >= 2.99, true, "描边取色: 暗色配黑描边被提亮到达标")
    expectEqual(lum(darkOnBlack) > LocalPlaybackSource.relativeLuminance(r: 0.12, g: 0.10, b: 0.08),
                true, "描边取色: 黑描边下是往亮的方向调")

    // 两侧都够不到时取端点里更好的那个,而不是返回一个"差一点点"的中间值。
    //
    // ⚠️ 默认的 3.0 **触发不到**这条分支:要两侧都够不到得同时满足 sl < 0.05(mc−1) 和
    // sl > 1.05/mc − 0.05,有解的条件是 mc > √21 ≈ 4.58。所以这里显式传 7.0 去测那条
    // 分支,别改回默认值——改回去这个断言会退化成在测另一条路径(第一版就是这么写错的)。
    let midStroke = (0.5, 0.5, 0.5)
    let onMid = fit((0.55, 0.52, 0.50), stroke: midStroke, minContrast: 7.0)
    let bestEndpoint = max(contrastWith((r: 0, g: 0, b: 0), midStroke),
                           contrastWith((r: 1, g: 1, b: 1), midStroke))
    expectEqual(abs(contrastWith(onMid, midStroke) - bestEndpoint) < 0.01, true,
                "描边取色: 够不到目标时取对比更好的端点")

    // 全区间扫描:输出永远合法,且只要目标可达就一定达标。
    var bad = 0, unreachable = 0
    for si in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let stroke = (si, si, si)
        let sl = LocalPlaybackSource.relativeLuminance(r: si, g: si, b: si)
        // 目标可达 = 黑或白至少有一个能跟这个描边拉到 3.0。
        let reachable = max(LocalPlaybackSource.contrastRatio(sl, 0),
                            LocalPlaybackSource.contrastRatio(sl, 1)) >= 3.0
        for i in 0 ... 12 {
            for j in 0 ... 12 {
                for k in [0.0, 0.5, 1.0] {
                    let c = fit((Double(i) / 12, Double(j) / 12, k), stroke: stroke)
                    if c.r < 0 || c.r > 1 || c.g < 0 || c.g > 1 || c.b < 0 || c.b > 1 { bad += 1 }
                    if reachable, contrastWith(c, stroke) < 2.99 { unreachable += 1 }
                }
            }
        }
    }
    expectEqual(bad, 0, "描边取色: 全区间扫描输出在 [0,1] 内")
    expectEqual(unreachable, 0, "描边取色: 全区间扫描只要够得到就一定达标")
}

// ---- 封面 URL:三个图源各自顶到最大那一档(2026-08-17 网易云 / 2026-08-24 QQ+Apple) ----
//
// 2026-08-17:用户报「歌词窗口里封面非常模糊」。根因是系统 Now Playing 给的封面只有
// 100×100(网易云客户端的限制),而那张卡最大 920px。替代图取自 collector 缓存的
// cover_url,但那个 URL 尾巴上带着给小图用的 `?param=600y600` —— 网易云那个参数
// **只降不升**,实测原生 800×800 的封面带上它就变 600×600。所以要原图必须把它摘掉。
//
// 2026-08-24:用户报「QQ 音乐这个封面很模糊」。QQ 音乐客户端报的系统封面是 300×300,
// 缓存里那张替代图当时也只有 300(QQ 源)/600(Apple 源)—— 顶到 820px 的卡上是 2.73×
// 和 1.37× 放大。这两个图源的尺寸档不在查询串里而在**路径**里,所以改路径:QQ 提到 800
// (实测天花板,1000/2000 都 404),Apple 提到 1200(实测要多大给多大)。
//
// 断言重点从"只对网易云动手"改成"只对**实测过**的形状动手":每个图源认死自己那一种
// URL 形状,形状对不上一个字都不许改 —— 改错了是 404、整张封面消失,比"软一点"糟得多。
do {
    func native(_ s: String) -> String {
        EnrichCacheReader.nativeSizedCoverURL(URL(string: s)!).absoluteString
    }

    // 网易云:param 摘掉,且整个查询串一起消失(不留一个尾巴上的 "?" ——
    // 那会让缓存把它当成另一个 key)。
    expectEqual(
        native("https://p1.music.126.net/abc==/1099.jpg?param=600y600"),
        "https://p1.music.126.net/abc==/1099.jpg",
        "封面URL: 网易云去掉 param")
    // 不同的 p1/p2/p4 子域都要认 —— 缓存里同一张图两种子域都出现过。
    expectEqual(
        native("https://p2.music.126.net/abc==/1099.jpg?param=300y300"),
        "https://p2.music.126.net/abc==/1099.jpg",
        "封面URL: p2 子域同样处理")
    // 本来就没有 param 的原样返回。
    expectEqual(
        native("https://p1.music.126.net/abc==/1099.jpg"),
        "https://p1.music.126.net/abc==/1099.jpg",
        "封面URL: 网易云本来没 param 就不动")
    // 还有别的参数时只摘 param,其余保留。
    expectEqual(
        native("https://p1.music.126.net/abc==/1099.jpg?param=600y600&x=1"),
        "https://p1.music.126.net/abc==/1099.jpg?x=1",
        "封面URL: 只摘 param，别的查询参数留着")

    // ---- QQ 音乐:路径里的尺寸档提到 800(2026-08-24) ----
    expectEqual(
        native("https://y.qq.com/music/photo_new/T002R300x300M0000017AN4b0vdUG1.jpg"),
        "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
        "封面URL: QQ 300 提到 800")
    expectEqual(
        native("https://y.qq.com/music/photo_new/T002R500x500M0000017AN4b0vdUG1.jpg"),
        "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
        "封面URL: QQ 500 提到 800")
    // 已经到顶就不动 —— 800 之上是 404,不许再往上试。
    expectEqual(
        native("https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg"),
        "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
        "封面URL: QQ 已经 800 就不动")
    // 比 800 还大的档(理论上不该出现)也不许被降回来。
    expectEqual(
        native("https://y.qq.com/music/photo_new/T002R1000x1000M000abc.jpg"),
        "https://y.qq.com/music/photo_new/T002R1000x1000M000abc.jpg",
        "封面URL: QQ 超过 800 的档不降回来")
    // 只换尺寸段,查询串一个字不碰(证明改的是路径、不是 param 那套)。
    expectEqual(
        native("https://y.qq.com/music/photo_new/T002R500x500M000.jpg?param=600y600"),
        "https://y.qq.com/music/photo_new/T002R800x800M000.jpg?param=600y600",
        "封面URL: QQ 只换尺寸段、查询串照留")
    // 歌手头像那个域名同一套规则(T001 前缀,实测也给 800)。
    expectEqual(
        native("https://y.gtimg.cn/music/photo_new/T001R300x300M000004UdEhN3Hb7vN_3.jpg"),
        "https://y.gtimg.cn/music/photo_new/T001R800x800M000004UdEhN3Hb7vN_3.jpg",
        "封面URL: QQ 歌手头像域名同样处理")
    // QQ 域名但不是图床路径 —— 不许动(歌曲页链接被误改就跳不过去了)。
    expectEqual(
        native("https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49"),
        "https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49",
        "封面URL: QQ 非图床路径不动")
    // 图床路径但没有尺寸段 —— 形状对不上就不动。
    expectEqual(
        native("https://y.qq.com/music/photo_new/mystery.jpg"),
        "https://y.qq.com/music/photo_new/mystery.jpg",
        "封面URL: QQ 图床但没有尺寸段就不动")

    // ---- Apple:末段 600x600bb.jpg 提到 1200(2026-08-24) ----
    expectEqual(
        native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600bb.jpg"),
        "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/1200x1200bb.jpg",
        "封面URL: Apple 600 提到 1200")
    expectEqual(
        native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/1200x1200bb.jpg"),
        "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/1200x1200bb.jpg",
        "封面URL: Apple 已经 1200 就不动")
    // 比目标档更大的不许降回来 —— 那是白扔已经拿到的分辨率。
    expectEqual(
        native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/2000x2000bb.jpg"),
        "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/2000x2000bb.jpg",
        "封面URL: Apple 2000 不降回 1200")
    // 末段不是 `<W>x<H>bb.<jpg|png>` 这一种形状的一律不动 —— 没实测过,改了可能 404。
    expectEqual(
        native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600sr.jpg"),
        "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600sr.jpg",
        "封面URL: Apple 非 bb 末段不动")
    expectEqual(
        native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600bb-60.jpg"),
        "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600bb-60.jpg",
        "封面URL: Apple 带裁切后缀的末段不动")
    // 仿冒 host 不算 Apple(判据是"等于或以 . 分隔的子域",同网易云那条)。
    expectEqual(
        native("https://evilmzstatic.com/image/thumb/a.jpg/600x600bb.jpg"),
        "https://evilmzstatic.com/image/thumb/a.jpg/600x600bb.jpg",
        "封面URL: 仿冒 Apple 域名不动")
    // host 后缀匹配不能被"看着像"的域名骗过去。
    expectEqual(
        native("https://evil-music.126.net.example.com/a.jpg?param=600y600"),
        "https://evil-music.126.net.example.com/a.jpg?param=600y600",
        "封面URL: 仿冒域名不算网易云")
    // 判据必须是"等于或以 . 分隔的子域":光 hasSuffix("music.126.net") 会把这个也算进去。
    expectEqual(
        native("https://evilmusic.126.net/a.jpg?param=600y600"),
        "https://evilmusic.126.net/a.jpg?param=600y600",
        "封面URL: 拼在一起的同后缀域名不算网易云")
}

// ---- 按日历天定义的缓存:跨零点必须作废(2026-08-17) ----
//
// 用户报「那年今日」昨天和今天显示同一份。根因是那张卡用 6 小时 TTL 判缓存,而 TTL 只
// 知道过了多少秒、不知道跨没跨过零点 —— 22:00 取到 8/16 那份,次日 02:00 再看 TTL 还没
// 到期,昨天那份就被挂在"今天"上。App 是常驻服务、跨天不重启,缓存时间戳又只在内存里,
// 所以这条一定会发生。这里盯住的就是"跨天优先于 TTL"这一点。
do {
    var cal = Calendar(identifier: .gregorian)
    // 固定时区,否则这组断言的结果会跟跑测试的机器在哪个时区有关。
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day,
                                      hour: hour, minute: minute))!
    }
    let sixHours: TimeInterval = 6 * 3600
    func needs(fetched: Date?, day: Date?, now: Date) -> Bool {
        DailyRefreshGate.needsRefresh(lastFetchedAt: fetched, cachedDay: day,
                                      now: now, ttl: sixHours, calendar: cal)
    }

    expectEqual(needs(fetched: nil, day: nil, now: at(8, 17, 10)), true,
                "跨天缓存: 从没取过要拉")

    // 同一天内 TTL 照常生效 —— 别把这条改坏了,不然每次露面都真发一轮请求
    // (那是三年 × 最多三页的量)。
    expectEqual(needs(fetched: at(8, 17, 10), day: at(8, 17, 10), now: at(8, 17, 14)), false,
                "跨天缓存: 同一天且 TTL 内不拉")
    expectEqual(needs(fetched: at(8, 17, 3), day: at(8, 17, 3), now: at(8, 17, 10)), true,
                "跨天缓存: 同一天但 TTL 到期要拉")

    // 本次修的就是这一条:只差 4 小时、TTL 远没到期,但已经是第二天了。
    expectEqual(needs(fetched: at(8, 16, 22), day: at(8, 16, 22), now: at(8, 17, 2)), true,
                "跨天缓存: 跨过零点即使 TTL 没到期也要拉")
    // 边界:同一天的 23:59 → 次日 00:00,只隔一分钟也算跨天。
    expectEqual(needs(fetched: at(8, 16, 23, 59), day: at(8, 16, 23, 59), now: at(8, 17, 0, 0)),
                true, "跨天缓存: 零点前后只差一分钟也算跨天")
    // 反向边界:同一天最早和最晚,不算跨天(只由 TTL 说了算)。
    expectEqual(needs(fetched: at(8, 17, 0, 0), day: at(8, 17, 0, 0), now: at(8, 17, 5, 59)),
                false, "跨天缓存: 同一天跨度再大也不算跨天")

    // 防御:两个字段本该同生同死,单独有一个时按"没有缓存"处理。
    expectEqual(needs(fetched: at(8, 17, 10), day: nil, now: at(8, 17, 11)), true,
                "跨天缓存: 缺 cachedDay 当作没缓存")
    expectEqual(needs(fetched: nil, day: at(8, 17, 10), now: at(8, 17, 11)), true,
                "跨天缓存: 缺 lastFetchedAt 当作没缓存")
}

// MARK: - 歌词时间轴偏移:基准(全部 / 按播放器,二选一)+ 单曲微调
//
// 2026-08-17 加全局偏移时补的,2026-08-21 补上「按播放器」那层。
//
// ⚠️ 播放器那层跟「全部」是**二选一、不相加**(2026-08-21 用户拍板改的语义:「不要和那个全部
// 相加,只有要么全部,要么单个」)。零值不落盘,所以"配过"="非零",调回 0 就是撤掉单独设置、
// 重新跟随「全部」。
//
// 真正容易写错的不是那个加法,而是几档之间的**独立性**:「重置这首歌」绝不能把设备侧的基准
// 一起抹掉(那是用户最不希望被连带清掉的东西),反过来改基准也不该动已经调好的单曲值;而按
// 播放器那层既不该被前两者连带,也**绝不能串台**(把浏览器那档套到 Apple Music 上)。
// LyricsOffsetStore 是 @MainActor,而这个文件的顶层代码是 nonisolated 的(所以
// trackKey 才特意标了 nonisolated,见那边的注释)。顶层代码本来就跑在主线程上,
// assumeIsolated 把这件事告诉编译器即可,不需要把整个 selftest 改成 async。
MainActor.assumeIsolated {
    let store = LyricsOffsetStore.shared
    let key = LyricsOffsetStore.trackKey(artist: "A", title: "T", lyrics: "[00:01.00]x", lyricsYRC: "")
    // 起点归零 —— 这个 store 落在 UserDefaults 上(selftest 是独立可执行文件,域是
    // lyrimuse-selftest,污染不到用户的 App;但那份 plist 跨运行持久,不清会读到上次的残留)。
    store.setGlobalOffset(0)
    store.reset(forKey: key, pinKey: "")
    for id in store.playerOffsets.keys { store.setPlayerOffset(0, forBundleID: id) }
    expectEqual(store.effectiveOffset(forKey: key), 0, "偏移: 各层都没调时是 0")

    store.setGlobalOffset(300)
    expectEqual(store.effectiveOffset(forKey: key), 300, "偏移: 只有全局基准时按它算")

    store.nudge(by: -100, forKey: key, pinKey: "")
    expectEqual(store.offset(forKey: key), -100, "偏移: 单曲微调独立记账")
    expectEqual(store.effectiveOffset(forKey: key), 200, "偏移: 生效值 = 全局 + 单曲")

    store.reset(forKey: key, pinKey: "")
    expectEqual(store.offset(forKey: key), 0, "偏移: 重置清掉单曲微调")
    expectEqual(store.globalOffsetMs, 300, "偏移: 重置不动全局基准")
    expectEqual(store.effectiveOffset(forKey: key), 300, "偏移: 重置后回到全局基准")

    store.setOffset(-250, forKey: key, pinKey: "")
    store.setGlobalOffset(-50)
    expectEqual(store.offset(forKey: key), -250, "偏移: 改全局基准不动单曲微调")
    expectEqual(store.effectiveOffset(forKey: key), -300, "偏移: 两个负值相加")

    // 空 key(从没拿到过曲目信息)不该被当成一首歌记账 —— 但全局基准跟曲目无关,照样生效
    store.setGlobalOffset(120)
    store.nudge(by: 500, forKey: "||", pinKey: "")
    expectEqual(store.offset(forKey: "||"), 0, "偏移: 空 key 不记账")
    expectEqual(store.effectiveOffset(forKey: "||"), 120, "偏移: 空 key 下全局基准仍然生效")

    // ---- 「按播放器」那一层(2026-08-21)----
    //
    // 2026-08-18 那版同名层的断言不适用:那是代码内部替 Spotify 猜的补偿(界面上看不见、
    // 重置不了,后来查明它补的偏差是自然切歌锚点超前、已由 naturalAdvanceCorrection 按曲
    // 根修,于是 08-20 连值一起删了),而这版是用户在设置页自己选播放器、自己调的值,连
    // UserDefaults 键都换了。旧断言也 revert 不回来 —— 那一层从头到尾只活在工作树里、
    // 从未提交(git log -S lyricsPlayerOffsetsJSON 只命中 3090fed,而它的父提交里根本没有)。
    //
    // Arc 用真实 bundle id(它就是这个功能的动机);对照播放器用枚举而不是字面量,枚举漂了
    // 断言跟着漂。注意 **Arc 不在 PlaybackPlayer 里** —— 它靠 TrustedPlayers 那份
    // bundleID→名字映射进来,所以这层的维度只能是 bundleID,换成枚举就把动机里那个 App
    // 挡在门外了。
    let arc = "company.thebrowser.Browser"
    let appleMusic = PlaybackPlayer.appleMusic.bundleIdentifier
    store.setGlobalOffset(0)
    store.reset(forKey: key, pinKey: "")

    expectEqual(store.playerOffset(forBundleID: nil), 0, "按播放器: 没有播放器身份时是 0")
    expectEqual(store.playerOffset(forBundleID: ""), 0, "按播放器: 空 bundle id 是 0")
    expectEqual(store.playerOffset(forBundleID: arc), 0, "按播放器: 没配过是 0")

    store.setPlayerOffset(800, forBundleID: arc)
    store.setGlobalOffset(100)
    store.setOffset(-50, forKey: key, pinKey: "")
    // 二选一:Arc 单独配过 → 只用它那档(800),「全部」那 100 完全不参与。
    expectEqual(store.baseOffsetMs(forBundleID: arc), 800, "按播放器: 配过就只用自己那档,不加全部")
    expectEqual(store.effectiveOffset(forKey: key, bundleID: arc), 750,
                "按播放器: 生效值 = 自己那档 + 单曲(800 - 50)")
    // 最要紧的一条:绝不串台。同一首歌换个播放器,Arc 那档一点都不许漏进去 —— 没单独配过的
    // 播放器退回「全部」那档。
    expectEqual(store.baseOffsetMs(forBundleID: appleMusic), 100, "按播放器: 没配过的退回全部那档")
    expectEqual(store.effectiveOffset(forKey: key, bundleID: appleMusic), 50,
                "按播放器: 换播放器不吃别人那档(100 - 50)")
    expectEqual(store.effectiveOffset(forKey: key), 50,
                "按播放器: 省略 bundleID 时用全部那档,不猜播放器")

    // 把单独那档调回 0 = 撤掉单独设置,重新跟随「全部」(零值不落盘,两件事是同一件)。
    store.setPlayerOffset(0, forBundleID: arc)
    expectEqual(store.baseOffsetMs(forBundleID: arc), 100, "按播放器: 调回 0 就重新跟随全部")

    // 负值同理:单独那档为负、全部为正,生效的只有单独那档。
    store.setGlobalOffset(300)
    store.setPlayerOffset(-200, forBundleID: arc)
    store.setOffset(-50, forKey: key, pinKey: "")
    expectEqual(store.effectiveOffset(forKey: key, bundleID: arc), -250,
                "按播放器: 单独那档为负时也不叠加全部(-200 - 50)")

    // 零值不落盘 —— 设置页那个下拉框靠"字典里有谁"来列"配过的播放器",留一个 0 进去就会
    // 多列一项;归零也是用户"我不要这档了"的唯一表达方式。
    store.setPlayerOffset(0, forBundleID: arc)
    expectEqual(store.playerOffsets[arc] == nil, true, "按播放器: 归零即从字典里删掉")

    // 落盘原文断言(照 pin 那边跨语言契约的范式):键名写错/被人"顺手"改回旧键,纯内存断言
    // 一律是绿的,而回归的表现是"用户为已修好的 bug 调出来的旧值复活、歌词反被拖慢",界面上
    // 完全看不出来。
    store.setPlayerOffset(640, forBundleID: arc)
    let playerJSON = UserDefaults.standard.string(forKey: "np:lyricsOffsetsByPlayerJSON") ?? ""
    expectEqual(playerJSON.contains(arc), true, "按播放器: 落盘在 np:lyricsOffsetsByPlayerJSON 里")
    expectEqual(playerJSON.contains("640"), true, "按播放器: 落盘的就是那个值")
    expectEqual(UserDefaults.standard.object(forKey: "np:lyricsPlayerOffsetsJSON") == nil, true,
                "按播放器: 08-18 那个旧键始终是空的(故意不复用)")

    // 收尾:别把测试值留在 UserDefaults 里
    store.setGlobalOffset(0)
    store.reset(forKey: key, pinKey: "")
    for id in store.playerOffsets.keys { store.setPlayerOffset(0, forBundleID: id) }
}

// ---- 歌词库备份归档(LyricsBackupArchive,2026-08-21)----
//
// 这一组里最要紧的是**文件名安全**:归档是一份外来文件(别人的机器、或被人手改过),而恢复
// 就是拿里面的名字去拼路径写文件。不挡住的话 "../../../.ssh/authorized_keys" 这种名字会把
// 内容写到歌词目录外面去。这类洞在单元测试里几秒钟就能钉住,靠肉眼 review 极容易放过。
do {
    typealias A = LyricsBackupArchive

    // sidecar 命名:同名同时间戳,只把 -Config- 换成 -Lyrics-。
    expectEqual(A.sidecarName(forConfigName: "Lyrimuse-Config-2026-08-21-181500.json"),
                "Lyrimuse-Lyrics-2026-08-21-181500.json.z",
                "歌词备份: sidecar 跟配置包同名同时间戳")
    // 用户在保存面板里改过名字(认不出规律)也要给出一个确定的名字,不能返回空。
    expectEqual(A.sidecarName(forConfigName: "我的备份.json").hasSuffix(".json.z"), true,
                "歌词备份: 认不出命名规律时也给一个确定的 sidecar 名")

    // ---- 文件名安全 ----
    expectEqual(A.sanitizedFileName("周杰伦 - 枫 - 十一月的萧邦.lrc") != nil, true,
                "歌词备份: 正常歌词文件名放行")
    expectEqual(A.sanitizedFileName("x.tr.lrc") != nil, true, "歌词备份: 译文后缀放行")
    expectEqual(A.sanitizedFileName("x.roma.lrc") != nil, true, "歌词备份: 罗马音后缀放行")
    expectEqual(A.sanitizedFileName("x.yrc") != nil, true, "歌词备份: 逐字后缀放行")
    // 目录穿越:三种形态都必须挡住。
    expectEqual(A.sanitizedFileName("../../.ssh/authorized_keys.lrc"), nil,
                "歌词备份: 带 ../ 的名字一律拒收")
    expectEqual(A.sanitizedFileName("sub/dir/x.lrc"), nil, "歌词备份: 带路径分隔符的拒收")
    // 名字里含 `..` **不再**拒收 —— 2026-08-21 实测:专辑名以句点结尾(陶喆《I'm O.K.》、
    // Wale《everything is a lot.》)导出的文件名天然长这样,那一版规则把它们**静默**踢出
    // 备份,一次漏掉 23 个文件而界面上什么都看不到。`..` 只有作为完整路径分量才危险,而带
    // 分隔符的名字上面那条已经拒了。
    expectEqual(A.sanitizedFileName("陶喆 - 天天 - I'm O.K..yrc") != nil, true,
                "歌词备份: 专辑名以句点结尾的文件名必须放行(实测漏备份 23 个)")
    expectEqual(A.sanitizedFileName("Wale - Watching Us - everything is a lot..lrc") != nil, true,
                "歌词备份: 同上,英文专辑名以句点结尾")
    expectEqual(A.sanitizedFileName("a..b.lrc") != nil, true, "歌词备份: 中间含 .. 的普通名字放行")
    // 但 `..` 作为完整分量、或以点开头的,照旧拒收。
    expectEqual(A.sanitizedFileName("..lrc"), nil, "歌词备份: 以点开头的照旧拒收")
    expectEqual(A.sanitizedFileName("\\tmp\\x.lrc"), nil, "歌词备份: 反斜杠也算路径分隔符")
    expectEqual(A.sanitizedFileName(".hidden.lrc"), nil, "歌词备份: 隐藏文件拒收")
    // 后缀白名单:歌词备份里不该有别的东西。
    expectEqual(A.sanitizedFileName("payload.sh"), nil, "歌词备份: 非歌词后缀拒收")
    expectEqual(A.sanitizedFileName("x.lrc.sh"), nil, "歌词备份: 后缀要在结尾,不能只是出现过")
    expectEqual(A.sanitizedFileName(""), nil, "歌词备份: 空名字拒收")
    // 单个文件名的文件系统上限,超了写入本来就会失败,提前挡掉。
    expectEqual(A.sanitizedFileName(String(repeating: "a", count: 260) + ".lrc"), nil,
                "歌词备份: 超长名字拒收")

    // ---- 恢复的账 ----
    let plan = A.plan(incoming: ["a.lrc", "b.yrc", "../evil.lrc", "c.lrc"],
                      existing: ["a.lrc", "z.lrc"])
    expectEqual(plan.added, ["b.yrc", "c.lrc"], "歌词备份: 目标目录没有的算新增")
    expectEqual(plan.overwritten, ["a.lrc"], "歌词备份: 已存在的算覆盖(恢复就是要盖)")
    expectEqual(plan.rejected, ["../evil.lrc"], "歌词备份: 不安全的名字进拒收账")
    // 目标目录里本来就有、而归档里没有的(z.lrc)一个都不许动 —— 恢复只写不删。
    expectEqual(plan.added.contains("z.lrc") || plan.overwritten.contains("z.lrc"), false,
                "歌词备份: 归档里没有的本机文件不受影响(只写不删)")
    // 顺序稳定:同一份归档两次恢复的账要一样(字典遍历顺序不稳,plan 内部排过序)。
    let again = A.plan(incoming: ["c.lrc", "../evil.lrc", "b.yrc", "a.lrc"],
                       existing: ["a.lrc", "z.lrc"])
    expectEqual(again, plan, "歌词备份: 输入顺序不影响结果")

    // ---- 磁盘格式契约 ----
    //
    // 字段名一改,旧机器导出的包在新版本上就解不出来 —— 而且是**静默**的:decode 失败只表现为
    // "这份备份不带歌词",用户不会收到任何报错,几千首歌的歌词和校正值就这么没跟过来。所以这里
    // 对**压缩后再解出来的 JSON 原文**断言字段名(照 pins 文件那条跨语言契约断言的范式)。
    let payload = A.Payload(at: "2026-08-21T10:00:00Z", device: "Mac",
                            files: ["周杰伦 - 枫.lrc": "[00:01.00]枫"],
                            pins: ["周杰伦|枫|十一月的萧邦": 1787296579])
    guard let archived = A.encode(payload) else {
        expectEqual(true, false, "歌词备份: encode 不该失败")
        exit(1)
    }
    // 压缩过的:zlib 头是 0x78,而明文 JSON 第一个字节是 '{'。
    expectEqual(archived.first != UInt8(ascii: "{"), true, "歌词备份: 归档是压缩过的")
    let plain = String(data: (try! (archived as NSData).decompressed(using: .zlib)) as Data,
                       encoding: .utf8) ?? ""
    for field in ["\"v\"", "\"at\"", "\"device\"", "\"files\"", "\"pins\""] {
        expectEqual(plain.contains(field), true, "歌词备份: 落盘 JSON 带 \(field) 字段")
    }
    // 往返不丢内容(尤其歌词正文里的换行和头部标签)。
    expectEqual(A.decode(archived), payload, "歌词备份: 压缩往返内容不变")
    // 明文 JSON 也要认 —— 手改过的包、或将来改成不压缩,都还能读出来。
    let raw = try! JSONEncoder().encode(payload)
    expectEqual(A.decode(raw), payload, "歌词备份: 未压缩的归档同样能读")
    // 完全不是归档的数据不能崩,返回 nil。
    expectEqual(A.decode(Data("not an archive".utf8)) == nil, true, "歌词备份: 垃圾数据返回 nil")
}

// ---- 「重新自动匹配」的采纳判定(LyricsRematchDecision,2026-08-21)----
//
// 五条分支里有两条是**不该动**的:当前源这一轮没应答(可能只是超时,换过去等于降级)、
// 这一轮的冠军没有逐字而现有的有(逐字是打分里最值钱的 +400,但取决于这一轮那个源有没有
// 把逐字接口给全 —— 实测同一首歌上一轮拿到 6887 字节 YRC、下一轮五个源一个逐字都没有)。
// 这两条失效时的表现不是报错,是"用户看得见的卡拉OK填色被悄悄弄没了",靠点按钮碰运气
// 验证不了,只能靠断言。
do {
    typealias D = LyricsRematchDecision
    // 正常换源。
    expectEqual(D.decide(decidable: true, winnerSource: "kugou", currentHasWordTiming: false,
                         winnerHasWordTiming: false, sameSource: false, sameLyrics: false,
                         sameWordTiming: false),
                .adopt, "重新匹配: 正常情况采纳冠军")

    // 当前源没应答 → 一步都不许动,而且要排在所有其它判定**之前**(哪怕冠军看起来很好)。
    expectEqual(D.decide(decidable: false, winnerSource: "kugou", currentHasWordTiming: false,
                         winnerHasWordTiming: true, sameSource: false, sameLyrics: false,
                         sameWordTiming: false),
                .keptNotDecidable, "重新匹配: 当前源没应答时不下结论")

    // 一个能用的候选都没有(空串)—— 绝不允许退回"取第一条"。
    expectEqual(D.decide(decidable: true, winnerSource: "", currentHasWordTiming: false,
                         winnerHasWordTiming: false, sameSource: false, sameLyrics: false,
                         sameWordTiming: false),
                .keptNoCandidate, "重新匹配: 没有冠军就什么都不动")

    // 逐字保护:现有的有逐字、冠军没有 → 保留。
    expectEqual(D.decide(decidable: true, winnerSource: "lrclib", currentHasWordTiming: true,
                         winnerHasWordTiming: false, sameSource: false, sameLyrics: false,
                         sameWordTiming: false),
                .keptWouldLoseWordTiming, "重新匹配: 不许把逐字换成整行")
    // 反向:现有的没逐字、冠军有 → 当然要换(这正是升级)。
    expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: false,
                         winnerHasWordTiming: true, sameSource: false, sameLyrics: false,
                         sameWordTiming: false),
                .adopt, "重新匹配: 从整行升级到逐字要换")
    // 两边都有逐字 → 正常比内容。
    expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: true,
                         winnerHasWordTiming: true, sameSource: false, sameLyrics: false,
                         sameWordTiming: false),
                .adopt, "重新匹配: 两边都有逐字时照常换")

    // 冠军跟现状逐项一致 → 一个字都不写(免得白白落盘 + 踢一次 collector 重启)。
    expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: true,
                         winnerHasWordTiming: true, sameSource: true, sameLyrics: true,
                         sameWordTiming: true),
                .unchanged, "重新匹配: 完全没变化时不写盘")
    // 同源但正文变了(那个源自己更新了歌词)→ 要换。
    expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: false,
                         winnerHasWordTiming: false, sameSource: true, sameLyrics: false,
                         sameWordTiming: true),
                .adopt, "重新匹配: 同源但正文更新了也要换")
    // 同源同正文、但逐字变了(上一轮没拿到逐字、这轮拿到了)→ 要换。
    expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: false,
                         winnerHasWordTiming: true, sameSource: true, sameLyrics: true,
                         sameWordTiming: false),
                .adopt, "重新匹配: 同源同正文但补上了逐字也要换")
}

// ---- 下拉框「作用于哪个播放器」的候选集(LyricsOffsetScope,2026-08-21)----
//
// 三条不变量各自只在特定用户状态下才暴露,所以必须钉:
//  ① 「自动识别」绝不能出现 —— 它的 bundleIdentifier 是空串,存进去会被 setPlayerOffset
//     静默丢掉(用户调了没反应、也没报错);
//  ② **配过偏移但已经不在信任名单里**的 App 仍然要列出来 —— 否则那个非零偏移就成了看不见、
//     改不动的隐形值(2026-08-18 那版按播放器偏移正是这么翻的车);
//  ③ 顺序稳定、无重复 —— 每组内部排序,不然字典遍历顺序会让下拉框每次启动乱跳。
do {
    let arc = "company.thebrowser.Browser"
    let uninstalled = "com.example.gone"
    let builtinCount = PlaybackPlayer.allCases.filter { $0 != .auto }.count

    let plain = LyricsOffsetScope.options(trusted: [:], configured: [], nowPlaying: nil)
    expectEqual(plain.count, builtinCount, "偏移作用域: 什么都没配时就是内置那几个")
    expectEqual(plain.contains(""), false, "偏移作用域: 「自动识别」的空 bundle id 绝不入列")
    expectEqual(plain.first, PlaybackPlayer.appleMusic.bundleIdentifier,
                "偏移作用域: 内置那组按枚举声明顺序")

    // 信任的未知播放器排在内置之后。
    let withTrusted = LyricsOffsetScope.options(trusted: [arc: "Arc"], configured: [], nowPlaying: nil)
    expectEqual(withTrusted.count, builtinCount + 1, "偏移作用域: 信任项追加在内置之后")
    expectEqual(withTrusted.last, arc, "偏移作用域: 信任项排在最后")

    // ② 已取消信任(或 App 卸了)但配过偏移 —— 必须仍然列出来。
    let orphan = LyricsOffsetScope.options(trusted: [:], configured: [uninstalled], nowPlaying: nil)
    expectEqual(orphan.contains(uninstalled), true,
                "偏移作用域: 配过偏移的即使不在信任名单也要列(不许有隐形值)")

    // 同一个 id 三组都命中时只出现一次。
    let dedup = LyricsOffsetScope.options(trusted: [arc: "Arc"], configured: [arc], nowPlaying: arc)
    expectEqual(dedup.filter { $0 == arc }.count, 1, "偏移作用域: 同一个 id 只出现一次")

    // 内置播放器出现在信任名单里(理论上不该发生)也不许重复。
    let am = PlaybackPlayer.appleMusic.bundleIdentifier
    let dupBuiltin = LyricsOffsetScope.options(trusted: [am: "Music"], configured: [am], nowPlaying: am)
    expectEqual(dupBuiltin.count, builtinCount, "偏移作用域: 内置项不会因为别的来源再来一遍")

    // 正在放的那个既不是内置也没被信任(刚发现、还没点信任)—— 也要能选到。
    let fresh = LyricsOffsetScope.options(trusted: [:], configured: [], nowPlaying: uninstalled)
    expectEqual(fresh.last, uninstalled, "偏移作用域: 正在放的那个即使还没被信任也能选")

    // nowPlaying 传空串(拿不到身份)不该塞一个空项进去。
    let blank = LyricsOffsetScope.options(trusted: [:], configured: [], nowPlaying: "")
    expectEqual(blank.count, builtinCount, "偏移作用域: nowPlaying 为空串时不入列")

    // builtInOrder 参数(2026-08-25 加,给设置页传 PlaybackPlayer.displayOrder 用——
    // 跟"选择播放器"图标网格同一套按系统语言排的顺序,同一批播放器在这个下拉框里不该是
    // 另一个顺序)。这里不依赖 displayOrder 本身(那是 App target 里读 AppSettings 的属性,
    // selftest 只链 LyrimuseCore,够不到),只验证参数**确实生效**:传一个跟 allCases
    // 不同的顺序,输出要跟着换,而不是内部悄悄还是按 allCases 排。
    let reordered = [PlaybackPlayer.spotify, .kugou, .netease, .qqMusic, .appleMusic, .auto]
    let customOrder = LyricsOffsetScope.options(builtInOrder: reordered, trusted: [:], configured: [], nowPlaying: nil)
    expectEqual(customOrder.first, PlaybackPlayer.spotify.bundleIdentifier,
                "偏移作用域: builtInOrder 参数生效,内置那组按传入的顺序排,不是 allCases 的声明顺序")
    expectEqual(customOrder.count, builtinCount, "偏移作用域: 换个顺序不影响内置那组的数量(.auto 仍被排除)")
}

// ---- 「已校准」名单:调过时间轴的歌不再被后台换歌词源(2026-08-20) ----
//
// 这个名单是 collector 侧 needsLyricsRescore/needsLyricsRetry 的第一道闸(见
// collector/lyricspins.go)。要守三件事:
//  ① 校正值非零就自动钉住、归零就自动解钉 —— 没有任何"记得手动打开开关"的步骤;
//  ② pin 的身份是**归一化 enrich key**、不含歌词内容指纹 —— 拿含指纹的 key 当身份等于
//     "内容一换 pin 也失效",正好把这条闸要防的事情放过去;
//  ③ 「清空全部时间轴校正」只清单曲这一层,全局基准**和按播放器那层**都不受连带。
MainActor.assumeIsolated {
    // ⚠️ 先把 pin 文件重定向到临时目录:它的真实路径跟正在运行的 App 共用同一份,而下面
    // 要覆盖 clearAllTrackOffsets()(内部会 removeAll)—— 不隔离就是把用户真实的已校准
    // 名单抹掉。必须排在任何一次 LyricsPinStore.shared 访问之前。
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lyrimuse-selftest-pins-\(ProcessInfo.processInfo.processIdentifier).json")
    LyricsPinStore.redirectForTesting(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = LyricsOffsetStore.shared
    let pins = LyricsPinStore.shared
    let pinKey = "已校准测试歌手|已校准测试歌名|已校准测试专辑"
    let keyA = LyricsOffsetStore.trackKey(
        artist: "已校准测试歌手", title: "已校准测试歌名", lyrics: "[00:01.00]甲", lyricsYRC: "")
    let keyB = LyricsOffsetStore.trackKey(
        artist: "已校准测试歌手", title: "已校准测试歌名", lyrics: "[00:02.00]乙", lyricsYRC: "")
    expectEqual(keyA == keyB, false, "已校准: 两份不同歌词内容的 offset key 本来就不同")
    expectEqual(pins.isPinned(pinKey), false, "已校准: 起点是干净的")

    store.nudge(by: 300, forKey: keyA, pinKey: pinKey)
    expectEqual(pins.isPinned(pinKey), true, "已校准: 调过偏移就自动钉住,不需要另外开开关")

    // 关键一条:同一首歌换了一份歌词内容 → 旧校正值查不到(这是既有设计,内容指纹变了),
    // 但 pin 仍然在 —— 它认的是"这首歌",不是"这一份内容"。pin 要是也跟着失效,后台就会
    // 继续换源、把用户下一次校准的成果再作废一次,这条闸等于没装。
    expectEqual(store.offset(forKey: keyB), 0, "已校准: 换内容后旧校正值查不到(既有设计)")
    expectEqual(pins.isPinned(pinKey), true, "已校准: 换歌词内容不该让 pin 失效")

    store.reset(forKey: keyA, pinKey: pinKey)
    expectEqual(pins.isPinned(pinKey), false, "已校准: 偏移归零就自动解钉")

    // 空 pinKey(拿不到 enrich key)时什么都不该钉 —— 否则会长出一条谁都匹配不上的记录。
    store.nudge(by: 100, forKey: keyA, pinKey: "")
    expectEqual(pins.count, 0, "已校准: 空 pinKey 不写名单")

    // 存量补钉:上一步刻意造出了「有校正值但没 pin」这个状态(等价于 pin 机制上线之前
    // 用户已经调好的那些歌)。播放到它时必须补上,否则最该保护的那批一条都不受保护。
    expectEqual(store.offset(forKey: keyA), 100, "补钉: 前提——这首有非零校正值却没 pin")
    store.backfillPinIfNeeded(forKey: keyA, pinKey: pinKey)
    expectEqual(pins.isPinned(pinKey), true, "补钉: 存量非零校正值会被补上 pin")

    // 校正值是 0 的歌绝不该被补钉 —— 那样全库每首歌都会进名单、后台升级整个停摆。
    store.reset(forKey: keyA, pinKey: pinKey)
    store.backfillPinIfNeeded(forKey: keyA, pinKey: pinKey)
    expectEqual(pins.count, 0, "补钉: 校正值为 0 不补钉")

    // ---- 「清空全部时间轴校正」----
    store.setGlobalOffset(700)
    store.setPlayerOffset(-300, forBundleID: "company.thebrowser.Browser")
    store.setOffset(-900, forKey: keyA, pinKey: pinKey)
    expectEqual(store.trackOffsetCount, 1, "清空: 计数跟着写入走")
    expectEqual(pins.isPinned(pinKey), true, "清空: 前提——这首已经钉住了")

    // 跨语言契约:这份文件由 Swift 写、由 collector(Go)读(lyricsPinsFile 的
    // `json:"version"` / `json:"pins"`)。字段名在 Swift 侧一改,Go 那边就静默读到空名单、
    // 整条闸失效而且没有任何报错 —— 所以这里对**磁盘上的原文**断言,不是对内存态。
    let onDisk = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
    expectEqual(onDisk.contains("\"version\""), true, "已校准: 落盘 JSON 带 version 字段(Go 侧靠它)")
    expectEqual(onDisk.contains("\"pins\""), true, "已校准: 落盘 JSON 带 pins 字段(Go 侧靠它)")
    expectEqual(onDisk.contains(pinKey), true, "已校准: 落盘 JSON 里就是归一化的 enrich key")

    store.clearAllTrackOffsets()
    expectEqual(store.offset(forKey: keyA), 0, "清空: 单曲校正值被清掉")
    expectEqual(store.trackOffsetCount, 0, "清空: 计数归零")
    expectEqual(pins.count, 0, "清空: pin 名单一并清掉(没有校正值就没有要保护的东西)")
    expectEqual(store.globalOffsetMs, 700, "清空: 绝不连带清掉全局基准(设备侧延迟)")
    expectEqual(store.playerOffset(forBundleID: "company.thebrowser.Browser"), -300,
                "清空: 也绝不连带清掉按播放器那层")

    // 收尾
    store.setGlobalOffset(0)
    for id in store.playerOffsets.keys { store.setPlayerOffset(0, forBundleID: id) }
}

// ---- 署名行:双语标签「汉字角色词 + 英文对照」(2026-08-19) ----
//
// 用户报陶喆《Stupid Pop Song》开头 13 行职员表一条都没滤掉。原因:label 取的是冒号前的
// 整段("制作人 Producer"),而原规则要求剔掉分隔符后**全是汉字**,拉丁字母一进来整条就
// 失败;而结构化那道闸(只在"整份被职员表主导"时才开)对这首也不成立 —— 13 行职员表
// 配三十多行真歌词,占不到半数。下面这批用的就是酷狗那份的原文。

do {
    let real = [
        "制作人 Producer：陶喆 David Tao",
        "曲 Composer：陶喆 David Tao",
        "词 Lyricist：陶喆 David Tao/葛大为",
        "编曲 Arrangement and programming：DT",
        "鼓 Drums：Ash Soan",
        "低音吉他 Bass：Paul Bushnell",
        "和声 Background vocals by：DT",
        "制作协力 Production Assistant：陈震豪 Evan Chen",
        "录音室 Recording Studio：新歌录音室 New Song Studios (Taipei)/The Windmill Studio, Norfolk (England)",
        "录音工程师 Recording Engineer：陈震豪 Evan Chen",
        "混音工程师 Mixing Engineer：Mick Guzauski",
        "混音录音室 Mixing Studio：Barking Doctor",
        "母带后期处理工程 Mastering Engineer：CB",
    ]
    for line in real {
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit(line), true,
                    "双语署名: \(line.prefix(12))…")
    }

    // 单字汉字头(「曲」「词」「鼓」)只有在**旁边有英文角色名**时才算 —— 把它们加进
    // creditRoleWords 会把真歌词里的对白吃掉(2026-08-16 踩过并回滚)。
    let notCredits = [
        "他：我不走",                       // 对白,单字说话人
        "妈妈 Mom：吃饭了",                  // 双语但英文不是角色名
        "我爱你 I love you：再见",            // 同上
        "爱情 Love Story：一场游戏",           // "Story" 不在角色名表里
        "曲：我们一起唱",                     // 汉字单字 + 没有英文对照 → 不认
    ]
    for line in notCredits {
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit(line), false,
                    "双语署名(不该命中): \(line.prefix(10))…")
    }

    // ---- 免词表的双语形状(第二轮:用户报「西塔琴 Coral sitar: Jamie Wilson」)----
    //
    // 乐器/职能名是开放集合,词表打不完。改成认形状,但要求整份 ≥2 行才生效。
    let shapeOnly = [
        "西塔琴 Coral sitar：Jamie Wilson",   // 用户报的原文
        "中提琴 Viola：Istvan Loga",
        "竖琴Harp：Michael Maganuco",
        "富鲁格号 Flugehorn: Gary Alesbrook",
        "电钢琴与管风琴 Keys/Organ：丁世光 Dean Ting",
        "词OP：北京大石音乐版权有限公司",
        "画 Painting by：叶喜儿 Ashlee Yip",
    ]
    for line in shapeOnly {
        expectEqual(LyricsSyncEngine.matchesBilingualCreditShape(line), true,
                    "双语形状: \(line.prefix(12))…")
    }
    // ⚠️ 真歌词反例(全库扫出来的唯一一类):行内注解 `(SL:` 让第一个冒号落在括号里,
    // 「冒号前」被当成标签。靠"标签里不许有括号 + 拉丁尾必须字母开头"两道守卫排掉。
    for line in [
        "我们让彼此难过(SL:那些到底算是谁的错) 都别争了",
        "那些伤害人的话(SL:那些只是气话其实我) 都别说了",
    ] {
        expectEqual(LyricsSyncEngine.matchesBilingualCreditShape(line), false,
                    "双语形状(真歌词不许命中): \(line.prefix(10))…")
    }
    // 对唱标注豁免:「男 Male:」这种真实存在,不能当署名删
    expectEqual(LyricsSyncEngine.matchesBilingualCreditShape("男 Male：我不走"), false,
                "双语形状: 说话人标签豁免")
    // 落单不算 —— 闸在 strippingCreditLines 那边,这里单独验形状函数本身照旧返回 true,
    // 端到端那一组负责验"只有 1 行时不会被删"。
    do {
        let lone = LyricsSyncEngine()
        lone.load(lyrics: "[00:01.00]妈妈 Mom：吃饭了\n[00:05.00]真的歌词一句\n[00:09.00]真的歌词两句\n",
                  lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(lone.allLines(idPrefix: "x").count, 3,
                    "双语形状: 整份只有 1 行这种形状时不删(闸门 ≥2)")
    }

    // 端到端:整份走一遍展示过滤,只剩真歌词那两句
    let engine = LyricsSyncEngine()
    var lrc = "[00:00.00]Stupid Pop Song - 陶喆\n"
    for (i, line) in real.enumerated() {
        lrc += "[00:\(String(format: "%02d", i + 1)).00]\(line)\n"
    }
    lrc += "[00:28.61]This is a stupid pop song 我想唱给你听\n"
    lrc += "[00:33.00]谁在乎明天会怎样\n"
    // 抬头那一行要靠曲名/歌手比对才认得出(见 looksLikeHeaderLine),所以这里必须把它们
    // 传进去 —— 真实调用路径也是这么传的。
    engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true,
                trackTitle: "Stupid Pop Song", trackArtist: "陶喆")
    let kept = engine.allLines(idPrefix: "t").compactMap { $0.line.mainText }
    expectEqual(kept, ["This is a stupid pop song 我想唱给你听", "谁在乎明天会怎样"],
                "双语署名: 端到端只剩两句真歌词(抬头 + 13 行职员表全滤掉)")
}

// ---- 末字填色必须在换行前填满(2026-08-19) ----
//
// 用户报「主动调过某首歌的歌词延迟之后,每句歌词最后一点不走完就下一句」。查下来跟偏移
// 无关(引擎判行和四处填色加的是同一个 offsetMs),是歌词数据本身:"填满"的时刻是
// 字.start+字.duration,"换行"的时刻是下一行的 timeMs,两个独立的数字。全库实测
// 667 首/37610 行:25.9% 正好相等、3.0% 真越过、12.2% 余量不足 120ms —— 合计约四成。

do {
    let lead = KaraokeFill.lineTailLeadMs      // 140
    let floorMs = KaraokeFill.minTailFillMs    // 120
    func words(_ specs: [(String, Int, Int)]) -> [SyncedLyricWord] {
        specs.map { SyncedLyricWord(text: $0.0, startMs: $0.1, durationMs: $0.2) }
    }
    func tail(_ ws: [SyncedLyricWord], _ next: Int?) -> [Int] {
        KaraokeFill.tailClamped(ws, nextLineStartMs: next).map(\.durationMs)
    }

    // 余量为 0(占全库 25.9%):末字填满与换行同一毫秒 → 压到换行前 lead
    expectEqual(tail(words([("a", 0, 500), ("b", 1000, 500)]), 1500), [500, 500 - lead],
                "末字: 余量为 0 的行压到换行前 \(lead)ms 填满")
    // 真越过(3.0%,中位 295ms):同样压到换行前 lead
    expectEqual(tail(words([("a", 1000, 1000)]), 1500), [1500 - lead - 1000],
                "末字: 越过下一行开始的照样压回来")
    // 越过太多:按下限兜住,不做成"啪"地跳满
    expectEqual(tail(words([("a", 1000, 1000)]), 1050), [floorMs],
                "末字: 压不下去时按 \(floorMs)ms 下限兜住")
    // 余量充足:一个字都不动
    expectEqual(tail(words([("a", 1000, 300)]), 2000), [300],
                "末字: 余量充足时原样不动")
    // 整首最后一句:没有"换行"这回事
    expectEqual(tail(words([("a", 1000, 5000)]), nil), [5000],
                "末字: 最后一句不压(没有下一行)")
    // 只动最后一个字,前面的一律不碰
    expectEqual(tail(words([("a", 0, 900), ("b", 900, 900), ("c", 1800, 900)]), 2700),
                [900, 900, 2700 - lead - 1800],
                "末字: 只压最后一个字,前面的原样")
    // duration 为 0 的极短词(英文歌词常见)走 minWordDurationMs,压缩不该把它压更短
    expectEqual(tail(words([("a", 1000, 0)]), 9000), [0],
                "末字: 零时长词余量充足时不动(填色本来就按 80ms 下限走)")
    // 空行不炸
    expectEqual(tail([], 1000), [], "末字: 空词数组安全返回")

    // 压完之后填色必须真的能到 1.0,而且比换行早
    let clamped = KaraokeFill.tailClamped(words([("a", 1000, 500)]), nextLineStartMs: 1500)
    let w = clamped[0]
    expectEqual(KaraokeFill.fillFraction(for: w, atMs: 1500 - lead) >= 1.0, true,
                "末字: 换行前 \(lead)ms 时填色已经到 1.0")
    expectEqual(KaraokeFill.fillFraction(for: w, atMs: 1500 - lead - 60) < 1.0, true,
                "末字: 再早 60ms 时还没填满(不是提前一大截就满)")
}

// ---- 歌词行状态的判定顺序(2026-08-19) ----
//
// 这条链的三处硬约束原本只写在三个 View 的注释里,誊了三遍还各自内联了一份实现。
// 顺序错了不编译报错、不崩,只会长期显示一句似是而非的状态(纯音乐永远"搜索歌词中…"),
// 所以拿断言钉住。

do {
    func d(words: Bool = false, line: Bool = false, ad: Bool = false, inst: Bool = false,
           noLyrics: Bool = false, netDown: Bool = false, content: Bool = false,
           playing: Bool = true) -> LyricsLineDisplay {
        LyricsLineDisplay.resolve(
            hasWordTiming: words, hasCurrentLine: line, isAdBreak: ad, isInstrumental: inst,
            hasNoLyrics: noLyrics, networkDown: netDown, hasLyricsContent: content,
            isPlaying: playing)
    }

    expectEqual(d(words: true, line: true, content: true), .words, "歌词行: 有逐字数据就唱")
    expectEqual(d(line: true, content: true), .plain, "歌词行: 只有整行文本走 plain")
    expectEqual(d(), .searching, "歌词行: 在放但还没有任何歌词 = 搜索中")
    expectEqual(d(playing: false), .idle, "歌词行: 没在放就什么都不显示")
    expectEqual(d(line: true, content: true, playing: false), .plain,
                "歌词行: 暂停时仍显示当前这一句")

    // 三条"必须排在谁前面"的硬约束
    expectEqual(d(inst: true), .instrumental, "歌词行: 纯音乐排在「搜索中」前(否则永远转圈)")
    expectEqual(d(ad: true), .adBreak, "歌词行: 广告排在「搜索中」前")
    expectEqual(d(noLyrics: true, netDown: true), .noLyrics,
                "歌词行: 「暂无歌词」排在「网络失败」前(搜完了确实没有)")
    expectEqual(d(netDown: true), .networkDown, "歌词行: 「网络失败」排在「搜索中」前")

    // 有词优先于一切状态 —— 跟另外三处展示面保持同一口径
    expectEqual(d(words: true, line: true, ad: true, inst: true, noLyrics: true), .words,
                "歌词行: 已经有逐字数据时状态位不抢戏")
    // 网络断了但歌词已经在手 = 照常显示,不该报错
    expectEqual(d(line: true, netDown: true, content: true), .plain,
                "歌词行: 歌词已在手时网络断了不影响显示")
}

// ---- 圆钮块的短按 / 长按 / 右键判定(2026-08-19) ----
//
// 菜单栏面板里那三个「歌词展示形态」的格子:短按 = 开关,长按或右键 = 展开它自己的快捷
// 设置。真正容易写错的只有一点 —— **长按已经触发过之后,松手不能再当短按用一次**
// (SwiftUI Button 的 action 认的就是松手,这也是那些格子不再用 Button 的原因)。

do {
    func run(_ events: [TilePressState.Event]) -> [TilePressState.Action] {
        var state = TilePressState()
        return events.map { state.handle($0) }
    }

    expectEqual(run([.down, .up]), [.none, .primary], "钮块: 按下松开 = 主动作")
    expectEqual(run([.down, .holdElapsed]), [.none, .secondary], "钮块: 按住到点 = 快捷设置")
    expectEqual(run([.down, .holdElapsed, .up]), [.none, .secondary, .none],
                "钮块: 长按之后松手不再补一次主动作")
    expectEqual(run([.secondaryClick]), [.secondary], "钮块: 右键直接进快捷设置")
    expectEqual(run([.down, .secondaryClick, .up]), [.none, .secondary, .none],
                "钮块: 左键按着时右键 = 只出快捷设置")
    expectEqual(run([.down, .dragOutside, .up]), [.none, .none, .none],
                "钮块: 拖出格子再松手什么都不做")
    expectEqual(run([.down, .dragOutside, .holdElapsed]), [.none, .none, .none],
                "钮块: 拖出去之后晚到的长按计时器不算")
    expectEqual(run([.down, .dragOutside, .dragInside, .up]), [.none, .none, .none, .primary],
                "钮块: 拖出去又拖回来,松手仍算主动作(跟原生按钮一致)")
    expectEqual(run([.down, .up, .up]), [.none, .primary, .none],
                "钮块: 同一轮不会放出两次主动作")
    expectEqual(run([.down, .up, .down, .up]), [.none, .primary, .none, .primary],
                "钮块: 下一轮按下重新计数")

    // 按压态视觉:按下亮、拖出去灭、拖回来又亮、长按到点即灭(此时快捷设置已经顶上来了)。
    var visual = TilePressState()
    _ = visual.handle(.down)
    expectEqual(visual.isPressing, true, "钮块: 按下进按压态")
    _ = visual.handle(.dragOutside)
    expectEqual(visual.isPressing, false, "钮块: 拖出格子退出按压态")
    _ = visual.handle(.dragInside)
    expectEqual(visual.isPressing, true, "钮块: 拖回格子重回按压态")
    _ = visual.handle(.holdElapsed)
    expectEqual(visual.isPressing, false, "钮块: 长按触发后退出按压态")
}

// ---- 「歌词显示」页分段的跨文件契约(2026-08-19) ----
//
// 菜单栏面板的「全部设置…」靠往一个 UserDefaults 键写这几个字符串,把设置窗口直接翻到
// 对应那一段。键名和取值必须跟 SettingsView 里 AppearanceSettingsTab.Section 的 rawValue
// 对得上 —— 对不上不会编译报错,只会表现成"长按灵动岛、设置窗口却停在悬浮歌词那一段"。
// 这里能钉住的是本侧这一半;另一半在那个 enum 上留了 ⚠️ 注释。

expectEqual(LyricsSurface.allCases.map(\.rawValue), ["overlay", "notch", "menuBar"],
            "形态: 三个取值与设置页分段一致")
expectEqual(LyricsSurface.appearanceSectionStorageKey, "settings:appearanceSection",
            "形态: 分段存储键名")
expectEqual(LyricsSurface.notch.appearanceSectionRawValue, "notch", "形态: 灵动岛 → notch 段")
expectEqual(LyricsSurface(rawValue: "menuBar"), .menuBar, "形态: rawValue 往回认得出来")
expectEqual(LyricsSurface(rawValue: "other"), nil, "形态: 「其它」段不属于任何一个形态")

// ---- 本地化:Localizable.xcstrings 是唯一真源,生成的 .strings 必须与它逐键逐值一致 ----
//
// 2026-08-17 迁移到 String Catalog(吸收自 boring.notch 审阅 B9):词条只在
// Localization/Localizable.xcstrings 里维护,两份 .lproj/Localizable.strings 是
// generate-strings.py 的生成物、随仓库一起提交 —— 终端用户 `swift build`/build.sh
// 完全不需要 Xcode(xcstringstool 只在完整 Xcode 里,CLT 没有)。
// 这道守卫盯的就是"改了 catalog 忘了重新生成"和"手改了生成物"两种漂移:
// 任何一边动了而另一边没跟上,这里立刻红,并指名去跑生成脚本。
//
// 用 #filePath 定位仓库内文件:文件真不在(目录挪了)就 FAIL 而不是静默跳过 ——
// 守卫自身失效也必须看得见。
do {
    // 生成物解析:一行一条 `"key" = "value";`。用 #/…/# 扩展定界符 —— 裸斜杠正则
    // 字面量在 5.9 工具链要开特性开关,扩展定界符不用。
    func stringsPairs(_ path: String) -> [String: String]? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        func unescape(_ s: Substring) -> String {
            s.replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        var pairs: [String: String] = [:]
        let pattern = #/^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/#
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if let m = line.firstMatch(of: pattern) {
                let key = unescape(m.1)
                // 同键后者静默覆盖前者,是排查不出来的那种坑 —— 当场红。
                if pairs[key] != nil { return nil }
                pairs[key] = unescape(m.2)
            }
        }
        return pairs
    }
    let sourcesDir = URL(fileURLWithPath: #filePath)    // …/Sources/lyrimuse-selftest/main.swift
        .deletingLastPathComponent()                    // …/Sources/lyrimuse-selftest
        .deletingLastPathComponent()                    // …/Sources
    let catalogPath = sourcesDir.deletingLastPathComponent()
        .appendingPathComponent("Localization/Localizable.xcstrings").path
    let resources = sourcesDir.appendingPathComponent("lyrimuse/Resources")

    struct CatalogPairs { var zh: [String: String] = [:]; var en: [String: String] = [:] }
    func catalogPairs(_ path: String) -> CatalogPairs? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["sourceLanguage"] as? String == "zh-Hans",
              let strings = obj["strings"] as? [String: Any], !strings.isEmpty
        else { return nil }
        var out = CatalogPairs()
        for (key, raw) in strings {
            let localizations = (raw as? [String: Any])?["localizations"] as? [String: Any]
            func value(_ lang: String) -> String? {
                (((localizations?[lang] as? [String: Any])?["stringUnit"]) as? [String: Any])?["value"] as? String
            }
            // 源语言允许省略(值即键,跟 generate-strings.py 同一条规则);英文缺翻译
            // 必须红 —— 静默回退成中文正是这套守卫要消灭的事故。
            out.zh[key] = value("zh-Hans") ?? key
            guard let en = value("en"), !en.isEmpty else { return nil }
            out.en[key] = en
        }
        return out
    }

    if let catalog = catalogPairs(catalogPath),
       let zhGen = stringsPairs(resources.appendingPathComponent("zh-hans.lproj/Localizable.strings").path),
       let enGen = stringsPairs(resources.appendingPathComponent("en.lproj/Localizable.strings").path) {
        expectEqual(catalog.zh.isEmpty, false, "本地化: catalog 解析出键")
        // 逐键逐值一致。两个方向的差集分别报,谁多谁少一目了然;值不同单独报。
        func diff(_ a: [String: String], _ b: [String: String], _ tag: String) {
            expectEqual(Set(a.keys).subtracting(b.keys).sorted(), [],
                        "本地化: catalog 有而 \(tag) 生成物缺的键(跑 Localization/generate-strings.py)")
            expectEqual(Set(b.keys).subtracting(a.keys).sorted(), [],
                        "本地化: \(tag) 生成物有而 catalog 缺的键(生成物只能由脚本生成,别手改)")
            let valueDiff = a.keys.filter { b[$0] != nil && a[$0] != b[$0] }.sorted()
            expectEqual(valueDiff, [], "本地化: \(tag) 生成物与 catalog 值不一致(跑 generate-strings.py)")
        }
        diff(catalog.zh, zhGen, "zh-hans")
        diff(catalog.en, enGen, "en")
    } else {
        expectEqual(true, false,
                    "本地化: catalog/生成物读不出来 —— 文件缺失、en 缺翻译、或生成物有重复键")
    }
}

// ---- 2026-08-20 歌词引擎性能审计落地的行为守卫 ----
do {
    // ① load() 入参指纹早退:同参第二次装载返回 false(整段跳过、缓存保住),任一参数
    //    变化恢复 true。
    let engine = LyricsSyncEngine()
    let lrc = "[00:01.00] hello world\n[00:05.00] second line\n[00:09.00] third line"
    expectEqual(engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: ""),
                true, "load 指纹: 首次装载返回 true")
    expectEqual(engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: ""),
                false, "load 指纹: 同参重复装载早退返回 false")
    expectEqual(engine.hasContent, true, "load 指纹: 早退后引擎内容原样保留")
    expectEqual(engine.load(lyrics: lrc, lyricsTr: "[00:01.00] 译文", lyricsRoma: "", lyricsYRC: ""),
                true, "load 指纹: 任一入参变化恢复全量装载")
    expectEqual(engine.load(lyrics: lrc, lyricsTr: "[00:01.00] 译文", lyricsRoma: "", lyricsYRC: "",
                            preferWordLevel: false),
                true, "load 指纹: preferWordLevel 变化也算内容变化")

    // ② tickQuery 与四个独立入口逐位一致(含单调推进和倒退 seek 两个方向 —— 单调窗口
    //    记忆化的验证失败路径必须正确回退全扫)。
    let engine2 = LyricsSyncEngine()
    engine2.load(
        lyrics: "[00:01.00] alpha\n[00:10.00] beta\n[00:30.00] gamma",
        lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
    // 采样点覆盖:第一句之前 / 各句内 / 长间奏(10s→30s 之间,gapWindow 会亮)/ 倒退。
    for ms in [0, 500, 1_500, 9_999, 12_000, 20_000, 31_000, 2_000, 500, 31_000, 1_500] {
        let r = engine2.tickQuery(atMs: ms)
        expectEqual(r.line, engine2.activeLine(atMs: ms), "tickQuery(\(ms)): line 与 activeLine 一致")
        expectEqual(r.nextText, engine2.upcomingLineText(afterMs: ms),
                    "tickQuery(\(ms)): nextText 与 upcomingLineText 一致")
        expectEqual(r.index, engine2.activeLineIndex(atMs: ms),
                    "tickQuery(\(ms)): index 与 activeLineIndex 一致")
        expectEqual(r.gapIndex, engine2.activeGapIndex(atMs: ms),
                    "tickQuery(\(ms)): gapIndex 与 activeGapIndex 一致")
    }
    expectEqual(engine2.tickQuery(atMs: 1_500).line?.plainText, "alpha", "tickQuery: 命中第一句")
    expectEqual(engine2.tickQuery(atMs: 12_000).line?.plainText, "beta", "tickQuery: 命中第二句")
    expectEqual(engine2.tickQuery(atMs: 0).index, nil, "tickQuery: 第一句之前 index 为 nil")

    // ③ nearestText(经 allLines 的译文贴合观察)改二分后的并列语义与旧线性扫一致:
    //    同距并列取时间戳更晚的那条;同时间戳重复取排在最后的那条。
    let engine3 = LyricsSyncEngine()
    engine3.load(
        lyrics: "[00:01.00] main line",
        // 300ms 与 1700ms 距 1000ms 同为 700(都在容差上),旧扫描后见者胜 → 取 late。
        lyricsTr: "[00:00.30] early\n[00:01.70] late",
        lyricsRoma: "", lyricsYRC: "")
    expectEqual(engine3.allLines(idPrefix: "t").first?.line.translation, "late",
                "nearestText 并列: 同距取时间戳更晚的那条(旧线性扫语义)")
    let engine4 = LyricsSyncEngine()
    engine4.load(
        lyrics: "[00:01.00] main line",
        lyricsTr: "[00:01.20] first\n[00:01.20] second",
        lyricsRoma: "", lyricsYRC: "")
    expectEqual(engine4.allLines(idPrefix: "t").first?.line.translation, "second",
                "nearestText 重复时间戳: 取排在最后的那条(旧线性扫语义)")
    let engine5 = LyricsSyncEngine()
    engine5.load(
        lyrics: "[00:01.00] main line",
        lyricsTr: "[00:02.50] too far",
        lyricsRoma: "", lyricsYRC: "")
    expectEqual(engine5.allLines(idPrefix: "t").first?.line.translation, nil,
                "nearestText 容差: 超过 700ms 不贴")

    // ③.5 说话人标签空行不抢近邻译文/罗马音(2026-08-23 用户截图坐实的真 bug):
    // 陶喆《All for Joy》原始数据实拍——「合：」独立成行(逐字里是「合」+「：」两个词,
    // 共享同一时间戳)、178ms 后紧跟真歌词行,译文只有一条、几乎贴着真歌词的时间戳
    // (6ms)但同样落在标签行的 700ms 容差内(174ms)。旧行为:两行各自"就近"命中同一条
    // 译文,连续两行显示同一句中文。
    let engineTag = LyricsSyncEngine()
    let tagYRC = "[121936,3302](121936,443,0)Crowds (122379,513,0)roaring (122892,173,0)fills (123065,485,0)the (123550,1688,0)atmosphere \n"
        + "[125676,178](125676,51,0)合(125727,127,0)：\n"
        + "[125856,6271](125856,967,0)Reminds (126823,275,0)me (127098,656,0)that (127754,733,0)games (128487,585,0)are (129072,794,0)more (129866,741,0)than (130607,1520,0)rules\n"
    engineTag.load(
        lyrics: "", lyricsTr: "[02:01.93]人群的咆哮充满了气氛\n[02:05.85]提醒我，游戏不仅仅是规则",
        lyricsRoma: "", lyricsYRC: tagYRC, preferWordLevel: true)
    let tagLines = engineTag.allLines(idPrefix: "t")
    // 2026-08-23 晚些时候改:这一行现在**根本不进歌词流**。
    //
    // 上面那段注释描述的是同一个 bug 的下游症状(标签行抢走了近邻译文),当时的修法是
    // isBareSpeakerTag —— 让它别抢,但那一行照样显示。真正的问题是它压根不是一句歌词:
    // 它带着自己的时间戳,到点就在屏幕上顶掉真歌词(全库实测 157 处,《等你下课》里
    // 一行「Gary」挂 23.3 秒)。现在 LyricDuet.planWords 认出"剥完为空"直接整行丢掉,
    // 抢译文的问题跟着一起没了。
    //
    // isBareSpeakerTag 保留不动,当第二道防线:LyricDuet 的整份判据认不出的标签
    // (比如整首只出现一次的人名),那一行仍会留在流里,那时还得靠它别去抢译文。
    expectEqual(tagLines.count, 2, "说话人标签: 「合：」独立成行不是歌词,整行丢掉")
    expectEqual(tagLines[0].line.plainText, "Crowds roaring fills the atmosphere ",
                "说话人标签: 标签前的真歌词不受影响")
    expectEqual(tagLines[1].line.plainText, "Reminds me that games are more than rules",
                "说话人标签: 标签后的真歌词补上原来标签行的位置")
    expectEqual(tagLines[1].line.translation, "提醒我，游戏不仅仅是规则",
                "说话人标签: 真歌词行照常拿到属于自己的译文")
    // side 是 nil 而不是 .center —— 这三行里只有「合」一个标记,认不出第二个身份,
    // 就没有"左右"可言(见 LyricDuet.hasEnoughIdentities)。丢行和定边是两件事:
    // 标记行照样丢掉(上面 count == 2),但整首退回"没有对唱信息"、各视图用自己的兜底。
    // 不这么做的话,只有一个合唱标记的歌会全程居中 —— 悬浮窗兜底本来就是居中(白做),
    // 歌词窗口却会从左对齐凭空变成居中(动了排版)。
    expectEqual(tagLines[1].line.side, nil, "说话人标签: 只认出一个身份时不判左右")

    // 反例:标签后面跟着真内容的行(「合：Hey hey ho ho」)不受影响,该有译文照样有——
    // isBareSpeakerTag 只认"冒号后完全没内容"这一种形状。
    let engineTaggedContent = LyricsSyncEngine()
    engineTaggedContent.load(
        lyrics: "[00:01.00]合：真的歌词内容", lyricsTr: "[00:01.20]真实的翻译",
        lyricsRoma: "", lyricsYRC: "")
    expectEqual(engineTaggedContent.allLines(idPrefix: "t").first?.line.translation, "真实的翻译",
                "说话人标签反例: 冒号后有真内容的行不受影响,照常匹配译文")

    // ④ plainText 存储化后语义不变:两种形态、以及"引擎构造时预拼"与"默认推导"一口径。
    let wordLine = SyncedLyricLine(
        romanization: nil, translation: nil, mainText: nil,
        words: [SyncedLyricWord(text: "ab", startMs: 0, durationMs: 100),
                SyncedLyricWord(text: "cd", startMs: 100, durationMs: 100)],
        wordGroups: nil, side: nil)
    expectEqual(wordLine.plainText, "abcd", "plainText 存储化: words 形态默认推导拼接")
    let mainLine2 = SyncedLyricLine(
        romanization: nil, translation: nil, mainText: "hello",
        words: nil, wordGroups: nil, side: nil)
    expectEqual(mainLine2.plainText, "hello", "plainText 存储化: mainText 形态原样")

    // ⑤ 整行读音与逐词分组共用同一次分词后,两条管线仍然等价:
    //    readingFromSegments(japaneseSegments(x)) ≡ romanize(x, japanese: true)。
    for text in ["今はまだ悲しい", "受話器を取った君", "明日の朝"] {
        let viaSegments = Romanizer.readingFromSegments(
            Romanizer.japaneseSegments(text), original: text)
        expectEqual(viaSegments, Romanizer.romanize(text, japanese: true),
                    "分词管线合一: \(text) 两条管线读音一致")
    }

    // ⑥ WrapLayoutMath 带 rows 的重载与原入口逐位一致(WrapLayout 壳缓存 rows 后走的
    //    是新重载,两条路径必须描述同一套排布)。
    let sizes = [CGSize(width: 40, height: 10), CGSize(width: 40, height: 12),
                 CGSize(width: 40, height: 10), CGSize(width: 90, height: 10)]
    let rows = WrapLayoutMath.rows(sizes: sizes, maxWidth: 100, horizontalSpacing: 2)
    expectEqual(
        WrapLayoutMath.totalSize(rows: rows, maxWidth: 100, verticalSpacing: 3),
        WrapLayoutMath.totalSize(sizes: sizes, maxWidth: 100, horizontalSpacing: 2, verticalSpacing: 3),
        "WrapLayoutMath: totalSize(rows:) 与原入口一致")
    expectEqual(
        WrapLayoutMath.placements(rows: rows, sizes: sizes,
                                  bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  horizontalSpacing: 2, verticalSpacing: 3, rowAlignment: .center),
        WrapLayoutMath.placements(sizes: sizes,
                                  bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  horizontalSpacing: 2, verticalSpacing: 3, rowAlignment: .center),
        "WrapLayoutMath: placements(rows:) 与原入口一致")

    // ⑥b wordGroupCache 按"首词时间戳+行文本"做 key:副歌重复句(同文本、不同时间)各自
    //    拿到自己的时间轴,不再共享第一次出现的词组(2026-08-20 对抗审查抓出的预存在 bug)。
    let engineDup = LyricsSyncEngine()
    engineDup.load(
        lyrics: "",
        lyricsTr: "", lyricsRoma: "",
        lyricsYRC: "[10000,2000](10000,500,0)い(10500,500,0)つ(11000,500,0)か\n"
            + "[30000,2000](30000,500,0)い(30500,500,0)つ(31000,500,0)か")
    let dupLines = engineDup.allLines(idPrefix: "dup")
    expectEqual(dupLines.count, 2, "重复句词组: 两行都在")
    expectEqual(dupLines.first?.line.wordGroups?.first?.startMs, 10000,
                "重复句词组: 第一次出现用自己的时间轴")
    expectEqual(dupLines.last?.line.wordGroups?.first?.startMs, 30000,
                "重复句词组: 第二次出现不再借用第一次的时间轴")

    // ⑥c parseTimestamp(2026-08-20 播放核心审计):formatter 静态化+顺序换成先试无小数秒
    //    (实测 media-control 恒无小数秒)后,两种形态都仍解析正确、垃圾串仍返回 nil。
    expectEqual(MediaControlClient.parseTimestamp("2026-08-20T10:00:00Z") != nil, true,
                "parseTimestamp: 无小数秒(常态)解析成功")
    expectEqual(MediaControlClient.parseTimestamp("2026-08-20T10:00:00.123Z") != nil, true,
                "parseTimestamp: 带小数秒兜底解析成功")
    expectEqual(MediaControlClient.parseTimestamp("not a date"), nil,
                "parseTimestamp: 垃圾串返回 nil")
    expectEqual(MediaControlClient.parseTimestamp(nil), nil, "parseTimestamp: nil 入参")
    expectEqual(MediaControlClient.parseTimestamp("2026-08-20T10:00:00Z"),
                MediaControlClient.parseTimestamp("2026-08-20T10:00:00.000Z"),
                "parseTimestamp: 两种写法的同一时刻解析相等")

    // ⑦ KaraokeFill 纯色快路径改静态常量后语义不变;裸起止版 fillFraction 与词版一致。
    expectEqual(KaraokeFill.stops(left: 1.2, right: 1.4), KaraokeFill.allSungStops,
                "KaraokeFill: left>=1 走全唱常量")
    expectEqual(KaraokeFill.stops(left: -0.4, right: -0.2), KaraokeFill.allUnsungStops,
                "KaraokeFill: right<=0 走未唱常量")
    let w = SyncedLyricWord(text: "x", startMs: 1000, durationMs: 40) // 40 < minWordDurationMs
    expectEqual(KaraokeFill.fillFraction(for: w, atMs: 1040),
                KaraokeFill.fillFraction(startMs: 1000, durationMs: 40, atMs: 1040),
                "KaraokeFill: 裸起止版 fillFraction 与词版一致(含短词下限)")
}

// ---- 「发现新播放器」判据(2026-08-22 用户报「没有通知机制」)----
//
// 两层:shouldOffer 是**卡片和通知共用**的(判据下沉到 Core 就是为了不让两边各抄一份),
// shouldAnnounce 在它之上加通知专属的四条。任一条松了就会变成骚扰或者「点了没反应」。
do {
    typealias A = UnknownPlayerAlert
    let now = Date()
    func offer(bundle: String = "com.google.Chrome", artist: String = "华晨宇",
               album: String = "异类", age: TimeInterval = 0, auto: Bool = true,
               accepted: Set<String> = []) -> Bool {
        A.shouldOffer(bundleID: bundle, artist: artist, album: album,
                      observedAt: now.addingTimeInterval(-age), isAutoDetect: auto, now: now,
                      isAccepted: { accepted.contains($0) })
    }
    // 用户报的原案
    expectEqual(offer(), true, "发现新播放器: 用户报的原案该提议信任")
    // ① 只在「自动识别」下
    expectEqual(offer(auto: false), false, "发现新播放器: 选了具体播放器时不提议")
    // ② 陈旧观察不提议(窗口跟设置页同一个数)
    expectEqual(offer(age: 14), true, "发现新播放器: 14 秒内算新鲜")
    expectEqual(offer(age: 16), false, "发现新播放器: 超过 15 秒的观察不提议")
    expectEqual(A.freshWindow, 15, "发现新播放器: 陈旧窗口必须是 15 秒(跟设置页对齐)")
    // ③ 歌手名和专辑名都非空,**trim 后**判空 —— 卡片原来写裸 isEmpty 是个既有 bug
    expectEqual(offer(album: ""), false, "发现新播放器: 专辑名空(YouTube 视频形状)不提议")
    expectEqual(offer(artist: ""), false, "发现新播放器: 歌手名空不提议")
    expectEqual(offer(album: "   "), false, "发现新播放器: 专辑名只有空白也算空(trim)")
    expectEqual(offer(artist: " \t "), false, "发现新播放器: 歌手名只有空白也算空(trim)")
    // ④ 已被接受的不提议
    expectEqual(offer(accepted: ["com.google.Chrome"]), false, "发现新播放器: 已信任的不提议")
    expectEqual(offer(bundle: ""), false, "发现新播放器: 空 bundle id 不提议")
    expectEqual(offer(bundle: "  "), false, "发现新播放器: 只有空白的 bundle id 不提议")
    expectEqual(offer(age: -5), true, "发现新播放器: 时钟回拨当新鲜,宁可多提示")
    // 内置五个播放器一律不提议(走真实的 isAccepted,名单传空)
    for player in PlaybackPlayer.allCases where player != .auto {
        expectEqual(A.shouldOffer(bundleID: player.bundleIdentifier, artist: "PRINCE",
                                  album: "Dirty Mind", observedAt: now, isAutoDetect: true,
                                  now: now,
                                  isAccepted: { TrustedPlayers.isAccepted($0, trusted: [:]) }),
                    false, "发现新播放器: 内置播放器不提议(\(player.rawValue))")
    }
    // **跨层不变量**:凡是我们提议信任的,用户点下去一定真的生效 ——
    // 把判据和 TrustedPlayers.notASong 永久绑在一起,将来任何一边单独改都会红
    expectEqual(TrustedPlayers.notASong(bundleID: "com.google.Chrome", artist: "华晨宇",
                                        album: "异类",
                                        trusted: ["com.google.Chrome": ""]),
                false, "发现新播放器: 提议信任的样本必须过得了 notASong 守卫")
    // 反向:Arc 放 YouTube 那份真实样本(artist=频道名、album 空)不该被提议
    expectEqual(offer(bundle: "company.thebrowser.Browser", artist: "Dream in reality",
                      album: ""), false, "发现新播放器: Arc YouTube 真实样本不提议")

    // ---- 第二层:通知专属 ----
    func announce(bundle: String = "com.google.Chrome", accepted: Set<String> = [],
                  hasName: Bool = true, stableFor: TimeInterval = 10, hits: Int = 5,
                  log: [String: A.AnnounceLog] = [:], at: Date = now) -> Bool {
        A.shouldAnnounce(bundleID: bundle, artist: "华晨宇", album: "异类", observedAt: at,
                         isAutoDetect: true, now: at,
                         isAccepted: { accepted.contains($0) },
                         hasDisplayName: hasName, stableFor: stableFor, stableHits: hits,
                         log: log)
    }
    expectEqual(announce(), true, "通知: 稳定 10 秒的新播放器该弹")
    // ⑤ 静音名单 —— 只影响"要不要弹",不影响"能不能信任"
    expectEqual(announce(bundle: "com.apple.podcasts"), false, "通知: 播客不弹(会被当歌打卡)")
    expectEqual(announce(bundle: "com.tencent.xinWeChat"), false, "通知: 微信不弹")
    expectEqual(A.mutedForAnnounce.contains("com.apple.Safari"), false,
                "通知: Safari 不在静音名单(放网页音乐跟 Chrome 一样正当)")
    // 静音名单**不**收窄卡片那一层
    expectEqual(A.shouldOffer(bundleID: "com.apple.podcasts", artist: "某节目", album: "某季",
                              observedAt: now, isAutoDetect: true, now: now,
                              isAccepted: { _ in false }),
                true, "通知: 静音名单里的 App 卡片照旧提议(想信任的人点得到)")
    // ⑥ 反查不到 App 名的不弹
    expectEqual(announce(hasName: false), false, "通知: 反查不到 App 名的不弹")
    // ⑦ 稳定性:时长和次数都要够
    expectEqual(announce(stableFor: 5.9), false, "通知: 稳定不足 6 秒不弹")
    expectEqual(announce(hits: 2), false, "通知: 观察不足 3 次不弹")
    expectEqual(announce(stableFor: 6, hits: 3), true, "通知: 刚好 6 秒 3 次就弹")
    expectEqual(A.stableWindow, 6, "通知: 稳定窗口 6 秒")
    expectEqual(A.stableHitsNeeded, 3, "通知: 稳定次数 3")
    // ⑧ 次数上限与冷却
    let day = A.announceCooldown
    expectEqual(announce(log: ["com.google.Chrome": .init(count: 1, lastAt: now)]), false,
                "通知: 刚提醒过,冷却期内不再弹")
    expectEqual(announce(log: ["com.google.Chrome": .init(count: 1, lastAt: now - day)],
                         at: now), true, "通知: 隔了一天可以再弹")
    expectEqual(announce(log: ["com.google.Chrome": .init(count: 3, lastAt: now - day * 9)]),
                false, "通知: 提醒满 3 次后永久停")
    expectEqual(A.maxAnnounces, 3, "通知: 上限 3 次(专注模式下可能一次都没看见)")
    expectEqual(announce(log: ["com.other.app": .init(count: 3, lastAt: now)]), true,
                "通知: 别的 App 提醒满了不影响这个")
    // 已信任的一律不弹(第一层就挡住了)
    expectEqual(announce(accepted: ["com.google.Chrome"]), false, "通知: 已信任的不弹")
}

// MARK: - 合唱 credit 归并(ArtistCredit,2026-08-20)
//
// 起因:同一首《Toronto 2014》两次收听在 Last.fm 上成了两个实体 —— Mac 照抄 Apple Music
// 的逐曲 credit「Daniel Caesar & Mustafa」,手机(iPhone→Last.fm→桥接)报的是主歌手
// 「Daniel Caesar」。后果是次数各记一本(两行都「第 1 次听」)、封面各挂一张(合唱实体挂
// 单曲封面)。这两组断言钉住用来归并的两条口径。
do {
    // ① 主歌手拆分:能拆才返回值,单人返回 nil(nil = "没有主歌手这回事")
    expectEqual(ArtistCredit.primary("Daniel Caesar & Mustafa"), "Daniel Caesar",
                "合唱 credit: & 分隔取第一位")
    expectEqual(ArtistCredit.primary("陶喆、卢广仲"), "陶喆", "合唱 credit: 顿号分隔")
    expectEqual(ArtistCredit.primary("UMI, 金泰亨"), "UMI", "合唱 credit: 逗号分隔")
    expectEqual(ArtistCredit.primary("Daniel Caesar feat. Mustafa"), "Daniel Caesar",
                "合唱 credit: feat. 也算多人")
    expectEqual(ArtistCredit.primary("Doja Cat (feat. SZA)"), "Doja Cat",
                "合唱 credit: 括号里的 feat. 一并切掉")
    expectEqual(ArtistCredit.primary("Daniel Caesar"), nil, "单人 credit: 返回 nil")
    // feat 家族要有**左词边界**(2026-08-22 实测出来的真 bug):`ft ` 会在词中命中,
    // 蛋堡的罗马字名 `Soft Lipa` 被切成 `So`,于是它跟 `蛋堡` 在查族键上永远合不上。
    expectEqual(ArtistCredit.primary("Soft Lipa"), nil,
                "合唱 credit: Soft Lipa 里的 ft 不是客串标记(实测真 bug)")
    expectEqual(ArtistCredit.primary("Daft Punk"), nil, "合唱 credit: Daft Punk 不许切成 Da")
    expectEqual(ArtistCredit.primary("Left Boy"), nil, "合唱 credit: Left Boy 不许切成 Le")
    expectEqual(ArtistCredit.primary("Craft Spells"), nil, "合唱 credit: Craft Spells 不许切")
    expectEqual(ArtistCredit.primary("Soft Machine"), nil, "合唱 credit: Soft Machine 不许切成 So")
    // 边界守卫不能把真的客串标记也挡掉
    expectEqual(ArtistCredit.primary("Soft Lipa feat. 蛋堡"), "Soft Lipa",
                "合唱 credit: 名字含 ft 的歌手,真 feat. 照旧切")
    expectEqual(ArtistCredit.primary("A ft. B"), "A", "合唱 credit: ft. 缩写照旧切")
    expectEqual(ArtistCredit.primary("A ft B"), "A", "合唱 credit: 无点号 ft 照旧切")
    expectEqual(ArtistCredit.primary("A (ft. B)"), "A", "合唱 credit: 括号里的 ft. 照旧切")
    expectEqual(ArtistCredit.primary(""), nil, "空串: 返回 nil")
    // 名字本身带 & 的组合不该被拆空(拆出来是空串时按"没有主歌手"处理)
    expectEqual(ArtistCredit.primary("& Friends"), nil, "以分隔符开头: 不返回空串")
    // `/` 单独一档:网易云式合 credit 要切,名字自带斜杠的不许切
    expectEqual(ArtistCredit.primary("陶喆/卢广仲"), "陶喆", "斜杠: 中文合 credit 要切")
    expectEqual(ArtistCredit.primary("K/DA, Madison Beer & (G)I-DLE"), "K/DA",
                "斜杠: 逗号先命中,K/DA 保持完整(真实历史里的一例)")
    expectEqual(ArtistCredit.primary("AC/DC"), nil, "斜杠: AC/DC 是一个艺人,不许劈成 AC")
    expectEqual(ArtistCredit.primary("K/DA"), nil, "斜杠: K/DA 同理不许劈成 K")
    // 归并键:多人归到第一位,单人原样
    expectEqual(ArtistCredit.mergeArtist("Daniel Caesar & Mustafa"), "Daniel Caesar",
                "归并歌手: 多人归第一位")
    expectEqual(ArtistCredit.mergeArtist("Daniel Caesar"), "Daniel Caesar",
                "归并歌手: 单人原样")
    // 两种 credit 写法必须落到同一个专辑共识键
    expectEqual(ArtistCredit.albumConsensusKey(artist: "Daniel Caesar & Mustafa",
                                               album: "NEVER ENOUGH (Bonus Version)"),
                ArtistCredit.albumConsensusKey(artist: "Daniel Caesar",
                                               album: "never enough (bonus version)"),
                "共识键: 合唱/主歌手两种写法 + 大小写差异折到同一个键")
    expectEqual(ArtistCredit.albumConsensusKey(artist: "Daniel Caesar", album: nil), nil,
                "共识键: 没有专辑名就没有共识(空专辑不共享封面)")

    // ② 同专辑共识封面:真实形态复刻 —— 4 行同专辑,3 行挂专辑封面、1 行(合唱实体)挂单曲封面
    let albumArt = URL(string: "https://lastfm.example/album.jpg")!
    let singleArt = URL(string: "https://lastfm.example/single.jpg")!
    let album = "NEVER ENOUGH (Bonus Version)"
    let rows: [(artist: String, album: String?, image: URL?)] = [
        ("Daniel Caesar & Mustafa", album, singleArt),
        ("Daniel Caesar", album, albumArt),
        ("Daniel Caesar", album, albumArt),
        ("Daniel Caesar", album, albumArt),
    ]
    let consensus = ArtistCredit.albumConsensusCovers(rows: rows)
    expectEqual(consensus[ArtistCredit.albumConsensusKey(artist: "Daniel Caesar", album: album)!],
                albumArt, "共识封面: 少数派(单曲封面)那一行被多数派纠正")
    // 每行各一张(合辑/逐曲封面)→ 没有共识,不许乱纠正
    let noConsensus = ArtistCredit.albumConsensusCovers(rows: [
        ("V.A.", "Compilation", URL(string: "https://lastfm.example/a.jpg")!),
        ("V.A.", "Compilation", URL(string: "https://lastfm.example/b.jpg")!),
    ])
    expectEqual(noConsensus.isEmpty, true, "共识封面: 一行一张时不产生共识")
    // 只有一行的专辑也不算共识(要求 ≥2 行一致)
    let single = ArtistCredit.albumConsensusCovers(rows: [("Solo", "One Track", albumArt)])
    expectEqual(single.isEmpty, true, "共识封面: 只有一行时不产生共识")
    // 没有图的行不参与
    let withNil = ArtistCredit.albumConsensusCovers(rows: [
        ("Daniel Caesar", album, nil),
        ("Daniel Caesar", album, albumArt),
        ("Daniel Caesar", album, albumArt),
    ])
    expectEqual(withNil.count, 1, "共识封面: 没有图的行不参与投票")
}

// MARK: - 缓存 key:结尾副题必须被剥掉(2026-08-20「歌词管理不自动定位」的根因)
//
// 用户报「进歌词管理不会自动定位到正在播的曲目」。实测:Apple Music 把这首报成
// 「Dynasties and Dystopia (from the series Arcane League of Legends)」,而缓存里那条 key
// 是剥掉副题的「Dynasties and Dystopia」(collector 的 enrichKey 剥的)。定位函数当时手拼
// "artist|title|album",精确匹配落空;而 looseKey 只折大小写/空格/繁简,**折不掉**这段副题,
// 兜底也接不住 —— 于是静默返回。这两条断言把"镜像函数必须剥、looseKey 必须剥不掉"钉住。
do {
    let artist = "Denzel Curry/GIZZLE/Bren Joy"
    let title = "Dynasties and Dystopia (from the series Arcane League of Legends)"
    let album = "Arcane League of Legends (Soundtrack from the Animated Series)"
    expectEqual(EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album),
                "Denzel Curry/GIZZLE/Bren Joy|Dynasties and Dystopia|"
                    + "Arcane League of Legends (Soundtrack from the Animated Series)",
                "缓存 key: 歌名结尾的 (from the series …) 副题被剥掉,专辑名原样保留")
    // looseKey 接不住这个差异 —— 这正是"必须用 normalizedKey 而不是手拼 + looseKey"的理由
    expectEqual(EnrichCacheKeys.looseKey("\(artist)|\(title)|\(album)")
                    == EnrichCacheKeys.looseKey(
                        EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)),
                false,
                "缓存 key: looseKey 折不掉结尾副题(所以手拼 key 连兜底都命不中)")
    // 版本限定词(Live/Remix 等)必须**保留** —— 那是另一次录音,不是副题噪音
    expectEqual(EnrichCacheKeys.normalizedTitle("Purple Rain (Live)"), "Purple Rain (Live)",
                "缓存 key: 版本限定词不剥")
}

// MARK: - looseKey 必须折平合 credit 分隔符(跟 collector 的 loosenEnrichKey 同步)
//
// 2026-08-20 用户报「歌词管理里同一首歌有两条」。根因:同一次播放里两条路径对多歌手串的
// 写法系统性不同 —— 播放器报 `A/B/C`,专辑预取从 Apple Music 曲目表拿到 `A & B & C`。
// 两侧的宽松键都得折平这一档,否则 collector 那边不再长重复条目,而这边(EnrichCacheReader
// 的兜底、歌词管理的定位)仍然对不上存量里的另一种写法。
do {
    expectEqual(
        EnrichCacheKeys.looseKey("VALORANT/Grabbitz/bbno$|Ticking Away|Ticking Away"),
        EnrichCacheKeys.looseKey("VALORANT & Grabbitz & bbno$|Ticking Away|Ticking Away"),
        "looseKey: 斜杠式与 & 式多歌手串判为同一首")
    expectEqual(
        EnrichCacheKeys.looseKey("陶喆、卢广仲|某首歌|某专辑"),
        EnrichCacheKeys.looseKey("陶喆/卢广仲|某首歌|某专辑"),
        "looseKey: 顿号与斜杠同折")
    // 原有两档(空格 / 繁简)不能被这次改动破坏
    expectEqual(
        EnrichCacheKeys.looseKey("丁世光|無名花香|背面是我"),
        EnrichCacheKeys.looseKey("丁世光|无名花香|背面是我"),
        "looseKey: 繁简仍然同折")
    // 折平分隔符不能把真的不同的歌并到一起
    expectEqual(
        EnrichCacheKeys.looseKey("K/DA|POP/STARS|POP/STARS")
            == EnrichCacheKeys.looseKey("K/DA|MORE|MORE"),
        false, "looseKey: 不同歌名仍然分开")
}

// MARK: - 中文歌不该因为署名行里的日文人名被判成日文(2026-08-20)
//
// 用户报「为什么中文歌也给我出罗马音,我没有开中文的,而且有些字有有些字没有」。
// 实测那首是泠鸢yousa《神的随波逐流》(中文翻唱),整首歌唯一的假名是这两行署名:
//   [00:07.69]词：れるりり
//   [00:15.38]曲：れるりり
// 而语言判定原来扫的是**原始** lyrics 字段(署名行也算),于是整首被判成日文 → 用户关着的
// 「中文」开关根本没机会说话(闸看的是整首歌的语言)→ 每行中文都被标东西:日语分词器
// 给得出读音的出日文读音(词典外的字原样留着,就是"有些字有有些字没有"),给不出的退到
// ICU 音译出拼音。下面用真实歌词片段钉住:开关只开日/韩时,这首歌一行罗马音都不该有。
do {
    let lyrics = """
    [00:00.00]泠鸢yousa - 神的随波逐流
    [00:07.69]词：れるりり
    [00:15.38]曲：れるりり
    [00:23.08]不知最近为什么总是不随心意
    [00:27.00]但我听说这是我最为珍贵的一个小特长
    [00:31.00]化作无穷的力量
    """
    let jaKoOnly: RomanizationScripts = [.japanese, .korean]

    let engine = LyricsSyncEngine()
    _ = engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                    trackTitle: "神的随波逐流", trackArtist: "泠鸢yousa",
                    romanizationScripts: jaKoOnly)
    let line = engine.activeLine(atMs: 27_500)
    expectEqual(line?.plainText, "但我听说这是我最为珍贵的一个小特长",
                "中文翻唱: 取到的是正文那一行(署名行已被过滤)")
    expectEqual(line?.romanization, nil,
                "中文翻唱: 署名行里的日文人名不该让整首歌变成日文 —— 中文开关关着就一行罗马音都没有")

    // 用户把「中文」也打开时,拼音照常出来(这条是设置本来的语义,不能被上面那道修复顺手关掉)。
    let engineZh = LyricsSyncEngine()
    _ = engineZh.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                      trackTitle: "神的随波逐流", trackArtist: "泠鸢yousa",
                      romanizationScripts: [.japanese, .korean, .chinese])
    expectEqual(engineZh.activeLine(atMs: 31_500)?.romanization != nil, true,
                "中文翻唱: 用户主动打开中文罗马音时照样给")

    // 真正的日文歌不能被这次改动误伤:正文里有假名,照旧判成日文、照旧给读音。
    let jpLyrics = """
    [00:00.00]作词：れるりり
    [00:05.00]火曜日の朝は
    [00:10.00]受話器を取った君
    """
    let jpEngine = LyricsSyncEngine()
    _ = jpEngine.load(lyrics: jpLyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                      trackTitle: "test", trackArtist: "test",
                      romanizationScripts: jaKoOnly)
    expectEqual(jpEngine.activeLine(atMs: 5_500)?.romanization != nil, true,
                "日文歌: 正文有假名,照旧判成日文并给读音")
}

// MARK: - 署名行第十轮:「标签 + 冒号 + 名字串」形状(2026-08-20)
//
// 用户报赵雷《成都》头部 13 行职员表里有 4 行漏到展示面上:
//   [00:09.28]钢琴：柳森    [00:10.60]箱琴：赵雷/喜子
//   [00:11.93]笛子：祝子    [00:17.23]童声：朵朵/天天
// 这几个乐器词不在 creditRoleWords 里,而结构化规则被"整份过半"那道闸拦着(13 行署名 vs
// 三十多行正文)。新规则收紧的是**冒号右边**:必须像人名/团名(不含虚词、每段 2~8 字),
// 而不是像已撤销的那次那样放宽位置 —— 那次正是被下面这些对白反例打回来的。
do {
    typealias E = LyricsSyncEngine
    // 正面:这四行就是用户截图里漏网的
    expectEqual(E.matchesNameListCreditShape("钢琴：柳森"), true, "名字串形状: 钢琴：柳森")
    expectEqual(E.matchesNameListCreditShape("箱琴：赵雷/喜子"), true, "名字串形状: 一个角色两个人")
    expectEqual(E.matchesNameListCreditShape("笛子：祝子"), true, "名字串形状: 笛子：祝子")
    expectEqual(E.matchesNameListCreditShape("童声：朵朵/天天"), true, "名字串形状: 童声：朵朵/天天")
    expectEqual(E.matchesNameListCreditShape("弦乐：亚洲爱乐国际乐团"), true, "名字串形状: 团体名(8 字)")
    expectEqual(E.matchesNameListCreditShape("弦乐编写：柳森"), true, "名字串形状: 四字组合标签")
    // 反面:全是历史上真被这条形状误杀过/差点误杀的真歌词
    expectEqual(E.matchesNameListCreditShape("他说：我不走"), false, "名字串形状: 对白(含「我」「不」)不认")
    expectEqual(E.matchesNameListCreditShape("她说：不走"), false, "名字串形状: 对白(含「不」)不认")
    expectEqual(E.matchesNameListCreditShape("我说：算了"), false, "名字串形状: 对白(含「了」)不认")
    expectEqual(E.matchesNameListCreditShape("他说：走"), false, "名字串形状: 右边只有一个字不认")
    expectEqual(E.matchesNameListCreditShape("曲婉婷：好久不见"), false, "名字串形状: 对唱标签+真歌词不认")
    expectEqual(E.matchesNameListCreditShape("男：亲爱的"), false, "名字串形状: 说话人标签豁免")
    expectEqual(E.matchesNameListCreditShape("Verse 1: hello"), false, "名字串形状: 拉丁标签不认")
    expectEqual(E.matchesNameListCreditShape("1、2、3：走"), false, "名字串形状: 数字标签不认")

    // 端到端:真实的《成都》头部(13 行职员表 + 真歌词),四行漏网的必须消失、真歌词必须留下
    let engine = LyricsSyncEngine()
    _ = engine.load(lyrics: """
    [00:00.00]成都 - 赵雷
    [00:01.32]词：赵雷
    [00:02.65]曲：赵雷
    [00:03.97]编曲：赵雷/喜子
    [00:05.30]制作人：赵雷/喜子/姜北生
    [00:06.63]BASS：张岭
    [00:07.95]鼓：贝贝
    [00:09.28]钢琴：柳森
    [00:10.60]箱琴：赵雷/喜子
    [00:11.93]笛子：祝子
    [00:13.26]弦乐编写：柳森
    [00:14.58]弦乐：亚洲爱乐国际乐团
    [00:15.91]和声：朱奇迹/赵雷/旭东
    [00:17.23]童声：朵朵/天天
    [00:24.00]让我掉下眼泪的
    [00:27.00]不止昨夜的酒
    [00:30.00]让我依依不舍的
    [00:33.00]不止你的温柔
    """, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
    trackTitle: "成都", trackArtist: "赵雷")
    let kept = engine.allLines(idPrefix: "cd").compactMap { $0.line.plainText }
    expectEqual(kept.count, 4, "成都: 13 行职员表 + 抬头全被过滤,只剩 4 句真歌词")
    expectEqual(kept.first, "让我掉下眼泪的", "成都: 第一句真歌词是它")
    expectEqual(kept.contains(where: { $0.contains("钢琴") || $0.contains("箱琴")
                    || $0.contains("笛子") || $0.contains("童声") }), false,
                "成都: 四行漏网的乐器署名已经过滤掉")
}

// MARK: - 署名行过滤:全库语料回归(2026-08-20)
//
// 语料 = 用户本机 enrich 缓存里的 **935 首 / 47626 行正文**,用 creditLineDropDecisions 全量
// 跑过一遍,再按"家族"抽样固化成下面两张表。
//
// 为什么要这套:署名行过滤今天已经补到第十轮,每一轮都是"为了多滤掉一类署名"而放宽判据,
// 而放宽的代价**从来不体现在被滤掉的行上,只体现在被误杀的正文上** —— 不测就没人发现。
// 这次跑语料当场抓到一整类真误杀:拉丁字母的说话人标签(Rain：/S:/A:/SL：/N.Chen：/Rap:)
// 连着后面的真歌词被整行删掉,29 行。
//
// ⚠️ 判据用 creditLineDropDecisions(整份进、每行出),不是单个匹配函数:整份闸门
// (双语 ≥2 行、名字串 ≥2 行、结构化 ≥3 行且过半)是这套规则的一半,只测单行函数测不到。
// 每条样本都放在**最恶劣但真实**的上下文里:旁边摆一段能同时打开"双语形状"和"名字串形状"
// 两道闸的署名块,再配 8 行普通歌词把"整份主导"那道闸关上(真实歌曲就是这个比例)。
do {
    typealias E = LyricsSyncEngine
    // 这四行既是真署名(自己都会被删),又把**两道整份闸同时打开** —— 故意的:
    //   前两行标签混着拉丁字母 → 打开"双语形状"闸;
    //   后两行标签是纯汉字     → 打开"名字串形状"闸(混拉丁的标签过不了它的纯汉字要求)。
    // 真实署名块本来就是两种写法混在一起,这也让下面每条 must-keep 都在"两道闸全开"的
    // 最恶劣环境里受检。
    // ⚠️ 后两行必须是**双字**标签:名字串那条规则要求标签至少两个汉字(单字是说话人标签的
    // 地盘),用「词：」「曲：」当 opener 打不开它的整份闸,断言会假绿/假红。
    let openers = ["词 Lyrics：某某某", "曲 Composer：某某某", "作词：某某某", "作曲：某某某"]
    let fillers = [
        "让我掉下眼泪的", "不止昨夜的酒", "余路还要走多久", "你攥着我的手",
        "分开总是在雨天", "一杯凉水一根烟", "谁能凭爱意要富士山私有", "夜色如水淹没了街",
    ]
    /// 把一行放进"真实歌曲"里,返回它删不删。
    func verdict(_ line: String) -> Bool {
        // 目标行放**最后**:第一行有专门的抬头规则(looksLikeHeaderLine),会污染判定。
        let doc = openers + fillers + [line]
        let drop = E.creditLineDropDecisions(doc, trackTitle: "测试曲", trackArtist: "测试歌手")
        return drop[doc.count - 1]
    }

    // ① 必须留下 —— 全库语料里真实出现过的正文/对唱/口白行(第二列是它在语料里出现的次数)
    let mustKeep: [(String, Int)] = [
        ("男：无所谓", 24),
        ("女：无所谓", 6),
        ("合：无所谓", 9),
        ("合：Hey hey ho ho", 8),
        ("合：因为我真的无所谓", 3),
        ("男：多少话也说不出", 3),
        ("女：有时想也想不通", 3),
        ("女：我真的Bae", 3),
        ("男：Khalil", 2),
        ("合：犯错", 2),
        ("钧：迫不及待看见我的未来", 18),
        ("宏：看见我的", 14),
        ("徐：我说男生的无所谓都是自以为", 4),
        ("岩：霸气傲中原 王者扬烽烟", 4),
        ("李：一个人的夜晚 谁和谁陪伴", 3),
        ("华：失去你的我比乞丐落魄", 2),
        ("方：是我闯祸 还是每个月的亲戚害了我", 2),
        ("黄：You are the apple of my eye", 2),
        ("王：不小心", 2),
        ("靖：我们大家的心声", 1),
        ("宏：呦 一位盖世英雄要上台了", 1),
        ("宏：Yeah come on come on", 2),
        ("Rain：给我大声地说我爱你", 12),
        ("Rain：정말 자신 있겠지", 2),
        ("S:只会让我不小心", 2),
        ("S:好想问你", 1),
        ("Rap:欢迎来到我的房间", 1),
        ("SL：啊把日期(給它)撕掉，", 1),
        ("N.Chen：（聽不懂...），", 1),
        ("A: one..two..three…..four", 2),
        ("B: Wu~", 4),
        ("A.B.C.D: Nananana nananana", 5),
        ("我们让彼此难过(SL:那些到底算是谁的错) 都别争了", 1),
        ("（女：Woo I'm sorry Woo So sorry）", 3),
        // 下面两条不是语料原文,是**为收漏网这一轮专门补的防误杀哨兵**:那一轮要放宽
        // "冒号右边是英文名"的长度上限,而英文句子跟英文人名在形状上极像,必须钉住。
        ("他说：I don't wanna go", 0),
        ("Rain：Baby I love you so much", 0),
        // 这两条是**第十一轮跑全库语料当场抓到的新误杀**:放宽"英文名段最长 30 字"之后,
        // 单字说话人标签 + 英文短句(里面没有停用词)被当成署名删掉。护栏是"名字串规则
        // 要求标签至少两个汉字",见 matchesNameListCreditShape。
        ("王：Hey hey ho ho", 2),
        ("靖：All yours baby", 2),
        // 下面 5 条同样来自第十一轮的全库 diff:它们在**第十轮**就已经被吃掉了
        // (单字说话人标签 + 干净短语,当时的 must-keep 样本没覆盖到这个形态),
        // 靠"标签至少两个汉字"这道护栏救回来。一并钉住。
        ("方：开个玩笑", 2), ("宏：盖世英雄到来", 2), ("王：Oh yeah", 2),
        ("华：喔 喔", 1), ("张：回到拉萨", 1),
    ]
    for (line, seen) in mustKeep {
        expectEqual(verdict(line), false, "语料回归(必须留下, 语料 \(seen) 次): \(line)")
    }

    // ② 必须删掉 —— 各家族的真实署名行(第二列是它属于哪一类,方便日后定位是哪条规则退化了)
    let mustDrop: [(String, String)] = [
        ("词：方大同", "中文单字标签"),
        ("曲：陶喆", "中文单字标签"),
        ("作曲 : 方大同", "半角冒号 + 空格"),
        ("编曲：陶喆", "中文双字标签"),
        ("制作人：赵雷/喜子/姜北生", "一个角色多个人"),
        ("钢琴：柳森", "乐器(第十轮补)"),
        ("箱琴：赵雷/喜子", "乐器(第十轮补)"),
        ("笛子：祝子", "乐器(第十轮补)"),
        ("童声：朵朵/天天", "乐器(第十轮补)"),
        ("弦乐：亚洲爱乐国际乐团", "团体名"),
        ("和声：朱奇迹/赵雷/旭东", "多人"),
        ("鼓：贝贝", "单字乐器"),
        ("BASS：张岭", "拉丁标签 + 全角冒号"),
        ("制作人 Producer：陶喆 David Tao", "双语标签"),
        ("曲 Composer：陶喆 David Tao", "双语标签(汉字头是单字)"),
        ("混音工程师 Mixing Engineer：Mick Guzauski", "双语组合词"),
        ("母带后期处理工程师 : Dave Collins", "长组合词 + 半角冒号"),
        ("制作协力 Production Assistant：陈震豪 Evan Chen", "双语组合词"),
        ("OP：月球唱片Retro Records CO LTD.", "版权归属"),
        ("SP：SMAP(BEIJING) CO.,LTD.", "版权归属"),
        ("Written by：Prince", "英文 by 写法"),
        ("Produced by：Sebastien Najand", "英文 by 写法"),
        ("Mixed by：Riot Games", "英文 by 写法"),
        ("Guitar：秋山浩徳", "拉丁角色名 + 日文人名"),
        ("未经著作权人许可不得翻录翻唱或使用", "版权声明(无冒号)"),
        ("版权声明：未经著作权人书面许可，任何人不得以任何方式使用（包括翻唱、翻录等）", "版权声明(带冒号)"),
        // ↓ 2026-08-20 第十一轮:上一轮拿全库语料统计出来的**仍然漏网**的 56 行,按家族收干净
        ("P - Line: 2016 北京享耳音乐文化有限公司Sure Recordings Culture Co., Ltd", "℗/© 版权行"),
        ("C - Line: 2016 北京享耳音乐文化有限公司Sure Recordings Culture Co., Ltd", "℗/© 版权行"),
        ("Protools编辑：Derrick Sepnio/Edward Chan/Kelvin Au/King Kong/Tsam Chan/Nick Wong", "标签混拉丁字母"),
        ("副唱：Bekuh BOOM", "表外角色 + 英文名"),
        ("竖琴：Michael Maganuco", "表外乐器 + 英文名"),
        ("长号：Matt Roberts", "表外乐器 + 英文名"),
        ("键盘乐器 DX7 and synths：Jeff Babko", "双语标签带型号"),
        ("键盘乐器 Keyboards (Piano and synth) by：吴庆隆 Goh Kheng Long", "双语标签带括号和 by"),
        ("中音萨克斯/次中音萨克斯/上低音萨克斯：孟庆泽", "一人身兼多职的长标签"),
        ("合作艺人：(G)I-DLE/Bea Miller/Wolftyla", "表外角色 + 多个英文名"),
        ("主唱：SOYEON of (G)I-DLE/MIYEON of (G)I-DLE/Bea Miller/Wolftyla", "表外角色 + 超长名单"),
        ("Additional Vocal Production by：Oscar Free", "英文角色短语 + by"),
    ]
    for (line, family) in mustDrop {
        expectEqual(verdict(line), true, "语料回归(必须删掉, \(family)): \(line)")
    }

    // ③ 抬头行单独测:它只在**第一行**生效,而且要求同时含曲名和歌手名
    let headerDoc = ["成都 - 赵雷"] + fillers
    expectEqual(E.creditLineDropDecisions(headerDoc, trackTitle: "成都", trackArtist: "赵雷").first,
                true, "语料回归: 抬头行「曲名 - 歌手」在第一行被删")
    let notHeaderDoc = fillers + ["成都 - 赵雷"]
    expectEqual(E.creditLineDropDecisions(notHeaderDoc, trackTitle: "成都", trackArtist: "赵雷").last,
                false, "语料回归: 同样的字样出现在中间不当抬头(多半是真歌词)")

    // ④ 永不删空:整份都长成署名的极端输入,一行都不许删(宁可漏治,不可整片空白)
    let allCredits = ["词：某某", "曲：某某", "编曲：某某", "制作人：某某"]
    expectEqual(E.creditLineDropDecisions(allCredits).contains(true), false,
                "语料回归: 整份都是署名时一行都不删(兜底闸门)")
}

// ==== MusicCatalogSearch:目录链接解析的纯函数(2026-08-22 歌词窗口菜单一族) ====
do {
    typealias S = MusicCatalogSearch
    // ① 请求 URL:参数齐全、term 是 歌手+歌名
    let u = S.searchURL(title: "轨迹", artist: "周杰伦", storefront: "cn")
    expectEqual(u != nil, true, "searchURL 能构造")
    if let u {
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func val(_ n: String) -> String? { q.first { $0.name == n }?.value }
        expectEqual(val("term"), "周杰伦 轨迹", "searchURL term=歌手+歌名")
        expectEqual(val("entity"), "song", "searchURL entity=song")
        expectEqual(val("country"), "cn", "searchURL country=店面")
    }
    // ② 挑选优先级:歌名+歌手双松匹配 > 只歌手 > 第一条
    func item(_ t: String, _ a: String) -> S.Item {
        S.Item(trackName: t, artistName: a, collectionName: nil,
               trackViewUrl: nil, artistViewUrl: nil, collectionViewUrl: nil)
    }
    let items = [item("别的歌", "别人"), item("轨迹 (Live)", "周杰伦"), item("随便", "周杰伦")]
    expectEqual(S.pickBest(items, title: "轨迹", artist: "周杰伦")?.trackName, "轨迹 (Live)",
                "pickBest: 双匹配优先(标题带版本后缀也认——互相包含)")
    let onlyArtist = [item("别的歌", "别人"), item("随便", "周杰伦")]
    expectEqual(S.pickBest(onlyArtist, title: "轨迹", artist: "周杰伦")?.trackName, "随便",
                "pickBest: 退而取歌手匹配")
    expectEqual(S.pickBest([item("A", "B")], title: "轨迹", artist: "周杰伦")?.trackName, "A",
                "pickBest: 再退第一条")
    expectEqual(S.pickBest([], title: "x", artist: "y") == nil, true, "pickBest: 空结果为 nil")
    // 「你的常听·歌手」跳转 title 传空串,只有"只歌手"分支在起作用——2026-08-23 用户
    // 实测点"Prince"跳到了"Prince & The Revolution",根因是旧版对艺人名也用互相包含
    // 的松匹配,单人艺人名恰好是合作艺人名的前缀。精确匹配必须优先于松匹配命中。
    let princeItems = [item("Purple Rain", "Prince & The Revolution"), item("Kiss", "Prince")]
    expectEqual(S.pickBest(princeItems, title: "", artist: "Prince")?.artistName, "Prince",
                "pickBest: 艺人精确匹配优先于松匹配(Prince 不应被 Prince & The Revolution 抢先)")
    let noExactMatch = [item("Purple Rain", "Prince & The Revolution")]
    expectEqual(S.pickBest(noExactMatch, title: "", artist: "Prince")?.artistName, "Prince & The Revolution",
                "pickBest: 精确匹配落空时仍退回松匹配")
    // ③ scheme 改写:只认 music.apple.com,其余拒绝(别把任意 https 泛化成 music://)
    expectEqual(S.musicSchemeURL("https://music.apple.com/cn/album/536108118")?.absoluteString,
                "music://music.apple.com/cn/album/536108118", "musicSchemeURL 改写")
    expectEqual(S.musicSchemeURL("https://example.com/x") == nil, true, "musicSchemeURL 拒绝外域")
    expectEqual(S.musicSchemeURL(nil) == nil, true, "musicSchemeURL nil 输入")
}

// MARK: - MarqueeMath:跑马灯溢出判定 + 右端渐隐带
//
// 2026-08-22 新增。用户报「灵动岛歌词有时候被封面挡住」——歌词行右边紧挨一枚 32pt 封面、
// 只隔 10pt,长歌词停在开头 hold 的那 1.1 秒里末端被硬切在那个间隙上,肉眼分不清是
// "裁掉了"还是"被封面盖住了"。修法是给那一端一条渐隐带,判据下沉到这里以便钉死边界。
do {
    typealias M = MarqueeMath

    // ① 溢出判定与 4pt 死区
    expectEqual(M.overflow(contentWidth: 400, containerWidth: 286), 114, "overflow: 正数=装不下")
    expectEqual(M.overflow(contentWidth: 200, containerWidth: 286), -86, "overflow: 负数=装得下")
    expectEqual(M.isOverflowing(contentWidth: 400, containerWidth: 286), true, "溢出")
    expectEqual(M.isOverflowing(contentWidth: 200, containerWidth: 286), false, "装得下")
    expectEqual(M.isOverflowing(contentWidth: 290, containerWidth: 286), false,
                "死区:只多 4pt 不算溢出(滚起来只是抖一下)")
    expectEqual(M.isOverflowing(contentWidth: 290.5, containerWidth: 286), true,
                "死区是严格大于 4pt")
    expectEqual(M.isOverflowing(contentWidth: 400, containerWidth: 0), false,
                "容器宽度还没测出来(首帧 0)时一律不算溢出——否则 distance 恒等于内容宽")

    // ② 渐隐带只在「溢出 + 停在开头」时给
    let fade: CGFloat = 10
    let lyricRow: CGFloat = 286   // 灵动岛稳态歌词区:360 - 32(padding) - 32(封面) - 10(间距)
    expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                    containerWidth: lyricRow, offset: 0), 10,
                "停在开头且溢出:给满宽渐隐——这正是用户看到「被封面挡住」的那一帧")
    expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                    containerWidth: lyricRow, offset: 114), 0,
                "滚到末端:必须不渐隐,否则真正的最后一个字被淡掉(信息损失,不是观感)")
    expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                    containerWidth: lyricRow, offset: 50), 0,
                "滚动途中不渐隐:文字在动,观感是滚过去而不是被挡住")
    expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 200,
                                    containerWidth: lyricRow, offset: 0), 0,
                "短歌词装得下:右端不能莫名淡出")
    expectEqual(M.trailingFadeWidth(configured: 0, contentWidth: 400,
                                    containerWidth: lyricRow, offset: 0), 0,
                "调用点没开渐隐(默认 0,顶行歌名/歌手走这条)")

    // ③ 容器被形态过渡插值到很窄时按一半封顶
    //    灵动岛收起态卡片 = notchWidth + 2*34 + 20;notchWidth=0 的屏上只有 88pt,
    //    歌词区在弹簧插值里会一路掠过十几 pt,不封顶那几帧整行会被渐隐糊掉。
    expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                    containerWidth: 14, offset: 0), 7,
                "极窄容器:渐隐带按容器一半封顶")
    expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                    containerWidth: 30, offset: 0), 10,
                "容器 30pt 已经容得下 10pt 渐隐带,不必封顶")
}

// MARK: - ProgressFillGeometry:歌词窗口进度条"已播段"的移出量
//
// 2026-08-22 新增。用户报「进度条有时候会变成方的,不是弧形」——根因是上一版用
// scaleEffect(x: f) 横向压缩满宽胶囊,把两端圆头一起压扁,f 越小越方。现在改成满宽 +
// offset 移出 + 固定胶囊裁剪,圆头形状与 f 无关。这里钉住那个移出量,尤其是两头的夹值。
do {
    typealias G = ProgressFillGeometry
    let w: CGFloat = 300

    // ① 常规刻度:可见宽 = 容器宽 × f,移出量是补数
    expectEqual(G.visibleWidth(containerWidth: w, fraction: 0.5), 150, "可见宽 = w×f")
    expectEqual(G.leadingOffset(containerWidth: w, fraction: 0.5), 150, "移出量 = w - 可见宽")
    expectEqual(G.visibleWidth(containerWidth: w, fraction: 1), 300, "播完:整条可见")
    expectEqual(G.leadingOffset(containerWidth: w, fraction: 1), 0, "播完:不移出")

    // ② 下限:f=0 也要留一个 4pt 见方的小圆点,不能缩没
    expectEqual(G.visibleWidth(containerWidth: w, fraction: 0), G.minimumVisibleWidth,
                "f=0 留下限那一小截")
    expectEqual(G.leadingOffset(containerWidth: w, fraction: 0), 296, "f=0 的移出量 = w - 4")
    // 用户截图那一档(3 分钟的歌播到 0:04,f≈0.022):真实可见宽 6.6pt,已超过下限
    expectEqual(G.visibleWidth(containerWidth: w, fraction: 0.022) > G.minimumVisibleWidth, true,
                "f≈0.022 时用真实宽度而不是下限")

    // ③ 越界的 fraction 一律夹回 [0,1],不靠调用点保证
    expectEqual(G.visibleWidth(containerWidth: w, fraction: -1), G.minimumVisibleWidth,
                "负 fraction 夹成 0")
    expectEqual(G.visibleWidth(containerWidth: w, fraction: 2), 300, "超 1 的 fraction 夹成 1")

    // ④ 退化容器:这层 min 是防 offset 变成正数把填充往右推、露出胶囊左半截
    expectEqual(G.visibleWidth(containerWidth: 2, fraction: 0), 2,
                "容器比下限还窄:可见宽夹到容器宽,不是 4")
    expectEqual(G.leadingOffset(containerWidth: 2, fraction: 0), 0,
                "退化容器的移出量必须 >= 0(负数会把填充往右推)")
    expectEqual(G.visibleWidth(containerWidth: 0, fraction: 0.5), 0, "容器宽 0(首帧):不画")
    expectEqual(G.leadingOffset(containerWidth: 0, fraction: 0.5), 0, "容器宽 0:移出量 0")

    // ⑤ 移出量恒非负 —— 这是 offset 方向正确的前提,扫一遍网格
    var negatives = 0
    for wi in [0, 1, 2, 4, 8, 120, 300, 900] as [CGFloat] {
        for fi in [-0.5, 0, 0.001, 0.022, 0.5, 0.999, 1, 1.5] as [CGFloat] {
            if G.leadingOffset(containerWidth: wi, fraction: fi) < 0 { negatives += 1 }
        }
    }
    expectEqual(negatives, 0, "移出量在 8×8 组容器宽/进度组合上恒非负")
}

// MARK: - HanVariants:繁简转换之外的异体字规范化
//
// 2026-08-22 新增。用户报「明明开了简体,歌词里还是看到繁体」——实例《开不了口 (Live)》:
// ICU 把 37 种字符全转对了,只剩「妳」没动而它出现 21 次。「妳」不是「你」的繁体,是异体字,
// ICU 和 OpenCC 的繁简表里都没有它(gocc 三张字典全库 grep 过,零条目)。
do {
    typealias V = ChineseVariant

    // ① 用户那一句的原文,端到端
    expectEqual(V.simplified.converted("整個畫面是妳 想妳想到睡不著"),
                "整个画面是你 想你想到睡不着",
                "《开不了口》那一句:繁体字和「妳」一起收拾干净")
    expectEqual(V.simplified.converted("今天的妳過的好不好"), "今天的你过的好不好",
                "妳 -> 你")
    expectEqual(V.simplified.converted("我一定會呵護著妳也逗妳笑"), "我一定会呵护着你也逗你笑",
                "一行里多个「妳」全部替换")

    // ② 表里其余四个字
    expectEqual(V.simplified.converted("祂與牠"), "他与它", "祂->他、牠->它")
    expectEqual(V.simplified.converted("細雨濛濛"), "细雨蒙蒙", "濛->蒙")
    expectEqual(V.simplified.converted("痲痺"), "麻痹", "痲->麻(痺 由 ICU 转)")

    // ③ 方向性:转繁体**绝不**反推异体字(简体只有「你」,反推要猜性别)
    expectEqual(V.traditional.converted("你"), "你", "转繁体不把「你」改成「妳」")
    expectEqual(V.traditional.converted("他"), "他", "转繁体不把「他」改成「祂」")
    expectEqual(V.traditional.converted("它"), "它", "转繁体不把「它」改成「牠」")
    // 转繁体该做的事照做
    expectEqual(V.traditional.converted("头发"), "頭髮", "转繁体本身不受这层影响")

    // ④ off 一律原样
    expectEqual(V.off.converted("整個畫面是妳"), "整個畫面是妳", "不转换:连异体字也不动")

    // ⑤ 日文守卫仍然优先 —— 含假名的整段一律不碰,免得把日文汉字写坏
    expectEqual(V.simplified.converted("妳の名前"), "妳の名前",
                "含假名:整段跳过,异体字表也不生效")

    // ⑥ 刻意**不**收的字:收了会造成误改
    expectEqual(V.simplified.converted("神祇"), "神祇", "「祇」不进表:神祇 vs 只 有歧义")
    expectEqual(V.simplified.converted("乾坤"), "乾坤", "「乾」由 ICU 按上下文保留,不进表")
    expectEqual(V.simplified.converted("我嘅"), "我嘅", "粤语字不是异体字,不能转")
    expectEqual(V.simplified.converted("咁樣"), "咁样", "粤语「咁」保留,「樣」照常转")

    // ⑦ 没命中时必须原样返回(快路径),纯拉丁/纯简体都不该被动
    expectEqual(V.simplified.converted("First Love"), "First Love", "纯拉丁不动")
    expectEqual(V.simplified.converted("这是一首简单的小情歌"), "这是一首简单的小情歌",
                "本来就是简体:原样")

    // ⑧ 表自身的约束:异体字不能映射到自己,也不能有链式映射(A->B 且 B->C)
    for (k, v) in HanVariants.toSimplified {
        expectEqual(k == v, false, "表里 \(k) 不能映射到自己")
        expectEqual(HanVariants.toSimplified[v] == nil, true,
                    "表里 \(k)->\(v) 的目标 \(v) 不能又是另一条的 key(链式映射)")
    }
    // 逐字替换的前提:ICU 对表里的 key 确实不做任何处理,否则两层会打架
    for k in HanVariants.toSimplified.keys {
        expectEqual(V.simplified.converted(String(k)), String(HanVariants.toSimplified[k]!),
                    "\(k) 单字过完整链路应得到规范字")
    }
}

// MARK: - CompactLyricLead:单行展示面「唱完就切到下一句」
//
// 2026-08-23 用户要求:灵动岛/菜单栏原来是"下一句开始才换行",想改成"这句唱完就切走",
// 好提前看到下一句跟唱。这套规则跟歌词窗口的 scrollLeadIndex **不是同一套**(那个服务
// 多行列表、间奏里有「•••」可停靠),两者的差别正是这些断言要钉住的东西。
do {
    typealias L = CompactLyricLead
    let reveal = L.revealMs   // 5000

    // ① 还在唱这一句 → 显示本行
    expectEqual(L.resolve(activeIdx: 3, posMs: 9_000, lineEndMs: 10_000, nextStartMs: 12_000),
                .line(3), "还没唱完:显示本行")

    // ② 短间隙(2s < reveal):唱完那一刻立刻切到下一句 —— 这就是用户要的主场景。
    //    实测该用户曲库里 97.7% 的行间隙 < 6s,绝大多数落这一档。
    expectEqual(L.resolve(activeIdx: 3, posMs: 10_000, lineEndMs: 10_000, nextStartMs: 12_000),
                .line(4), "短间隙:唱完即切到下一句")
    expectEqual(L.resolve(activeIdx: 3, posMs: 9_999, lineEndMs: 10_000, nextStartMs: 12_000),
                .line(3), "边界:差 1ms 还不算唱完")

    // ③ 长间奏(30s):唱完先切成 ♪,离下一句 reveal 毫秒时才亮出它。
    //    ——单行面没有「•••」那种可停靠的东西,已经唱完的句子不该继续占着那一行冒充"在唱"。
    expectEqual(L.resolve(activeIdx: 3, posMs: 10_000, lineEndMs: 10_000, nextStartMs: 40_000),
                .placeholder, "长间奏中段:♪")
    expectEqual(L.resolve(activeIdx: 3, posMs: 40_000 - reveal - 1, lineEndMs: 10_000, nextStartMs: 40_000),
                .placeholder, "边界:提前量窗口外还是 ♪")
    expectEqual(L.resolve(activeIdx: 3, posMs: 40_000 - reveal, lineEndMs: 10_000, nextStartMs: 40_000),
                .line(4), "边界:进入提前量窗口就亮出下一句")

    // ④ 保守边界 1:行级 LRC 不知道一行唱多久 → 一律不抢跑(维持"下一句开始才换"的旧行为)。
    //    猜早了会在人还在唱这句的时候把它换掉,比现状更糟。
    expectEqual(L.resolve(activeIdx: 3, posMs: 30_000, lineEndMs: nil, nextStartMs: 40_000),
                .line(3), "行级 LRC:不抢跑")

    // ⑤ 保守边界 2:最后一句(没有下一句)唱完也不切走 —— 切成 ♪ 只会让尾奏变空屏。
    expectEqual(L.resolve(activeIdx: 9, posMs: 99_000, lineEndMs: 10_000, nextStartMs: nil),
                .line(9), "最后一句:唱完仍显示它")

    // ⑥ 还没到第一句:维持现状(前奏里刻意不提前亮出第一句,那是另一个场景)
    expectEqual(L.resolve(activeIdx: -1, posMs: 500, lineEndMs: nil, nextStartMs: 3_000),
                .line(-1), "前奏:不动")

    // ⑦ displayDurationMs:菜单栏跑马灯的配速依据。
    //    这一项**必须**跟着显示窗口走 —— 沿用旧的「本句时间戳→下句时间戳」会在
    //    "长句 + 后面接长间奏"时把 dwell 算大,MenuBarMarquee.pacing 按它配速,
    //    句子会只滚出开头一小截就被换掉(比改动前更糟)。
    //    上一句 8s 唱完、本句 10s 开始、13s 唱完、下一句 40s 开始:
    //      出现 = max(8000, 10000-5000) = 8000;消失 = 13000(唱完即下场)→ 5000ms
    expectEqual(L.displayDurationMs(prevLineEndMs: 8_000, startMs: 10_000,
                                    lineEndMs: 13_000, nextStartMs: 40_000, fallbackEndMs: nil),
                5_000, "长间奏在后:窗口到唱完为止,不能算到下一句开始")
    //    短间隙:上一句 9.8s 唱完、本句 10s 开始、13s 唱完 → 出现 9800、消失 13000
    expectEqual(L.displayDurationMs(prevLineEndMs: 9_800, startMs: 10_000,
                                    lineEndMs: 13_000, nextStartMs: 14_000, fallbackEndMs: nil),
                3_200, "短间隙:出现于上一句唱完那一刻")
    //    长间奏在前:上一句 2s 就唱完、本句 10s 开始 → 出现被 reveal 夹在 5000
    expectEqual(L.displayDurationMs(prevLineEndMs: 2_000, startMs: 10_000,
                                    lineEndMs: 13_000, nextStartMs: 14_000, fallbackEndMs: nil),
                8_000, "长间奏在前:出现时刻被 revealMs 夹住,不会早于此")
    //    脏数据:上一句"唱完"比本句开始还晚 → 出现时刻不能算成晚于本句开始
    expectEqual(L.displayDurationMs(prevLineEndMs: 11_000, startMs: 10_000,
                                    lineEndMs: 13_000, nextStartMs: 14_000, fallbackEndMs: nil),
                3_000, "时间戳交叠:出现时刻夹到本句开始")
    //    行级 LRC:不知道唱完时刻 → 退回"下一句开始"
    expectEqual(L.displayDurationMs(prevLineEndMs: nil, startMs: 10_000,
                                    lineEndMs: nil, nextStartMs: 14_000, fallbackEndMs: nil),
                4_000, "行级 LRC:窗口退回下一句开始")
    //    最后一句:引擎不知道曲长,给 nil → 由 PlaybackCoordinator 退回既有公式
    expectEqual(L.displayDurationMs(prevLineEndMs: 9_000, startMs: 10_000,
                                    lineEndMs: 13_000, nextStartMs: nil, fallbackEndMs: nil),
                nil, "最后一句:引擎算不出,交给上层用曲目时长兜底")
    expectEqual(L.displayDurationMs(prevLineEndMs: 9_000, startMs: 10_000,
                                    lineEndMs: 13_000, nextStartMs: nil, fallbackEndMs: 30_000),
                21_000, "最后一句:给了曲末兜底就用它")

    // ⑧ leadInMs(2026-08-24):这一行**出现之后、开唱之前**那段"已显示但还没染色"的提前量。
    //    菜单栏跑马灯拿它当"起步前至少等多久" —— 用户报的「还没开始染色的时候不需要滚动,
    //    现在是会滚」就是这段时间里滚了。用例跟上面 ⑦ 一一对应,因为两者**必须**用同一个
    //    "出现"(appearMs):一个算窗口有多长、一个算窗口前半段有多长,漂了就是"提前量比
    //    整个窗口还长"。
    expectEqual(L.leadInMs(prevLineEndMs: 8_000, startMs: 10_000), 2_000,
                "提前量:上一句 8s 唱完、本句 10s 开唱 → 提前 2s")
    expectEqual(L.leadInMs(prevLineEndMs: 9_800, startMs: 10_000), 200,
                "提前量:短间隙就是那点间隙本身")
    expectEqual(L.leadInMs(prevLineEndMs: 2_000, startMs: 10_000), reveal,
                "提前量:长间奏在前时被 revealMs 夹住")
    expectEqual(L.leadInMs(prevLineEndMs: 11_000, startMs: 10_000), 0,
                "提前量:时间戳交叠(上一句'唱完'比本句开始还晚)时为 0,不出负数")
    expectEqual(L.leadInMs(prevLineEndMs: nil, startMs: 10_000), 0,
                "提前量:行级 LRC 恒为 0(resolve 对它从不抢跑),不会被无谓地推迟滚动")

    //    不变式:提前量 + 开唱到下场那段 == 整个显示窗口。两者共用 appearMs 就是为了这条。
    for (prevEnd, start, end) in [(8_000, 10_000, 13_000), (9_800, 10_000, 13_000),
                                  (2_000, 10_000, 13_000), (11_000, 10_000, 13_000)] {
        let window = L.displayDurationMs(prevLineEndMs: prevEnd, startMs: start,
                                         lineEndMs: end, nextStartMs: 40_000, fallbackEndMs: nil)
        expectEqual(L.leadInMs(prevLineEndMs: prevEnd, startMs: start) + (end - start), window,
                    "提前量 + 开唱到下场 == 整个显示窗口(prevEnd=\(prevEnd))")
    }
}

// MARK: - 提前量经引擎出到 TickResolution(2026-08-24)
//
// 上面那组只测了 CompactLyricLead 这个纯函数,测不到引擎**喂给它什么**。而 tickQuery 里
// 那句 `prevLineEndMs: gapLineEndMs(at: i - 1)` 的 `i - 1` 正是最容易写错的地方 ——
// 写成 `i` 编译一样过、纯函数断言一条都不会红,但提前量会恒等于 0(拿本行的结束当上一行的
// 结束),整个修复静默失效。所以这里从 YRC 一路测到 TickResolution。
do {
    // 三行逐字:第 0 行 10.0~11.0s、第 1 行 13.0~14.0s(与上一行隔 2.0s = 提前量)、
    // 第 2 行 30.0s(第 1 行后面接一段长间奏,所以第 1 行唱完就下场)。
    let yrc = "[10000,1000](10000,500,0)aa (10500,500,0)bb \n"
        + "[13000,1000](13000,500,0)cc (13500,500,0)dd \n"
        + "[30000,1000](30000,500,0)ee (30500,500,0)ff \n"
    let engine = LyricsSyncEngine()
    engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, preferWordLevel: true)

    // 第 0 行还在唱:显示本行,它前面没有行 → 提前量 0(不能因为"没有上一行"就算出负数)。
    let singing = engine.tickQuery(atMs: 10_500)
    expectEqual(singing.compactLine?.plainText, "aa bb ", "引擎提前量: 还在唱时显示本行")
    expectEqual(singing.compactLeadInMs, 0, "引擎提前量: 第一行没有上一行 → 0")

    // 第 0 行唱完(11.0s)→ 短间隙,立刻亮出第 1 行,但它 13.0s 才开唱 → 提前量 2000ms。
    // ⚠️ 这条就是 `i - 1` 的照妖镜:取成 `i` 会算成 leadInMs(prevEnd: 14000, start: 13000) = 0。
    let lead = engine.tickQuery(atMs: 11_500)
    expectEqual(lead.compactLine?.plainText, "cc dd ", "引擎提前量: 唱完即切到下一句")
    expectEqual(lead.compactLeadInMs, 2_000, "引擎提前量: 上一行 11.0s 唱完、本行 13.0s 开唱 → 2000ms")
    // 提前量是这一行**显示窗口的属性**,不是"还剩多久开唱" —— 窗口里任意时刻都是同一个值,
    // 否则 pacing 会随每次 refresh 变、把跑马灯反复打回开头。
    expectEqual(engine.tickQuery(atMs: 12_999).compactLeadInMs, 2_000,
                "引擎提前量: 窗口内恒定,不随播放位置递减")
    // 跟 dwell 同一个"出现"原点:2000(提前) + 1000(开唱到唱完) = 3000(整个显示窗口)。
    expectEqual(lead.compactDwellMs, 3_000, "引擎提前量: 显示窗口 = 提前量 + 开唱到下场")

    // 长间奏中段(第 1 行 14.0s 唱完、第 2 行 30.0s 才开始):♪ 占位,没有行也就没有提前量。
    let idle = engine.tickQuery(atMs: 20_000)
    expectEqual(idle.compactLine == nil && idle.compactPlaceholder, true, "引擎提前量: 长间奏中段是 ♪")
    expectEqual(idle.compactLeadInMs, nil, "引擎提前量: 没有可显示的行时为 nil")

    // 长间奏尾段(第 2 行开始前 5s 内)→ 亮出第 2 行,提前量被 revealMs 夹住。
    let capped = engine.tickQuery(atMs: 26_000)
    expectEqual(capped.compactLine?.plainText, "ee ff ", "引擎提前量: 进入提前量窗口亮出下一句")
    expectEqual(capped.compactLeadInMs, CompactLyricLead.revealMs,
                "引擎提前量: 长间奏在前时被 revealMs 夹住")

    // ---- 最后一句:曲长喂进来之后窗口也是**行常量**(2026-08-24) ----
    //
    // 不喂曲长时最后一句的 compactDwellMs 恒为 nil,上层退回 currentLineDwellSeconds ——
    // 那个值按 currentLineIndex 取行,提前量窗口里指的是**已唱完的上一句**(错基数),
    // 而且开唱那一刻 currentLineIndex 前进 → 值突变 → pacing 变 → 滚动被重装。首停含
    // 提前量,重装就等于把提前量**再等一遍**(最长 5 秒),最后一句可能整段唱完都不滚。
    // 所以这两条断言钉的是「同一句在开唱前后拿到同一个窗口」——它才是"不重装"的前提。
    let last = engine.tickQuery(atMs: 26_000, trackEndMs: 40_000)   // 第 2 行的提前量窗口内
    let lastSinging = engine.tickQuery(atMs: 30_500, trackEndMs: 40_000) // 同一行,已开唱
    // 出现 = max(第 1 行唱完 14000, 30000 − reveal 5000) = 25000;消失 = 曲末 40000。
    expectEqual(last.compactDwellMs, 15_000, "引擎提前量: 最后一句用曲末兜底算出窗口")
    expectEqual(lastSinging.compactDwellMs, last.compactDwellMs,
                "引擎提前量: 最后一句的窗口在开唱前后**不变**(否则 pacing 变→滚动重装→提前量白等两遍)")
    expectEqual(lastSinging.compactLeadInMs, last.compactLeadInMs,
                "引擎提前量: 最后一句的提前量在开唱前后也不变")
    // 不给曲长仍然退回 nil —— 这是上层兜底存在的唯一理由,别让它悄悄消失。
    expectEqual(engine.tickQuery(atMs: 26_000).compactDwellMs, nil,
                "引擎提前量: 不给曲长时最后一句仍算不出窗口(交给上层兜底)")
    // 非最后一句跟曲长无关,喂了也一样。
    expectEqual(engine.tickQuery(atMs: 11_500, trackEndMs: 40_000).compactDwellMs, 3_000,
                "引擎提前量: 非最后一句的窗口不受曲长影响")

    // 行级 LRC 一律不抢跑 → 提前量恒为 0,滚动行为一字不变。
    let lineLevel = LyricsSyncEngine()
    lineLevel.load(lyrics: "[00:10.00]aabb\n[00:13.00]ccdd\n", lyricsTr: "", lyricsRoma: "",
                   lyricsYRC: "")
    let lrcTick = lineLevel.tickQuery(atMs: 11_500)
    expectEqual(lrcTick.compactLine?.plainText, "aabb", "引擎提前量: 行级 LRC 不抢跑")
    expectEqual(lrcTick.compactLeadInMs, 0, "引擎提前量: 行级 LRC 提前量恒为 0")
}

// MARK: - 停播页:最近记录「第 N 次听」的换算(RecentPlayOrdinal,2026-08-24 从 UI 下沉)
do {
    // 站位的 playCountKey:跟真实那个(LastfmStatsService.playCountKey)同口径 —— 只
    // trim + 小写,**不折叠任何写法变体**。这正是测试的重点:表是按这把「不折叠」的尺子
    // 建的,而「比这一行更新的同曲收听」必须按 familyKey 的折叠族数,两把尺子不能混用。
    let key: (String, String) -> String = { a, t in
        (a.trimmingCharacters(in: .whitespaces) + "|" + t.trimmingCharacters(in: .whitespaces))
            .lowercased()
    }

    // 同一首歌连着听三次(列表倒序:最新在前),总数 10 → 10 / 9 / 8
    let three = [(artist: "方大同", title: "月亮代表我的心"),
                 (artist: "方大同", title: "月亮代表我的心"),
                 (artist: "方大同", title: "月亮代表我的心")]
    expectEqual(RecentPlayOrdinal.ordinals(rows: three,
                                           totals: [key("方大同", "月亮代表我的心"): 10],
                                           playCountKey: key),
                [10, 9, 8], "第 N 次听:同一首连听三次逐次递减")

    // 回归用户 2026-08-21 报的「第 15 次听下面紧跟第 21 次听」:同一首歌的两种写法在
    // 表里是两个不同的 playCountKey(各自存着**整族合并后**的同一个总数),但它们属于同
    // 一个折叠族 —— 按 playCountKey 去数「更新的同曲收听」会一次都减不掉,两行显示同一
    // 个 N。必须按 familyKey 数,后面那行才会 −1。
    let twoForms = [(artist: "周杰倫", title: "一路向北"),
                    (artist: "周杰伦", title: "一路向北")]
    expectEqual(RecentPlayOrdinal.ordinals(
        rows: twoForms,
        totals: [key("周杰倫", "一路向北"): 16, key("周杰伦", "一路向北"): 16],
        playCountKey: key),
                [16, 15], "第 N 次听:繁简两种写法同页时按折叠族递减,不是两行同一个 N")

    // 查不到总数 → nil(宁可不显示)
    expectEqual(RecentPlayOrdinal.ordinals(rows: [(artist: "无名", title: "无此曲")],
                                           totals: [:], playCountKey: key),
                [nil], "第 N 次听:表里没有这首就不显示")

    // 竞态:窗口里的同族收听比总数还多 → 算出 ≤0 的位置一律 nil,不显示「第 0 次」
    expectEqual(RecentPlayOrdinal.ordinals(rows: three,
                                           totals: [key("方大同", "月亮代表我的心"): 2],
                                           playCountKey: key),
                [2, 1, nil], "第 N 次听:算出 ≤0 时留空,不显示错的")
}

// MARK: - 停播页:收听总览的派生算术(IdleListeningStats,2026-08-24)
do {
    let cal = Calendar.current
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    let dayKey: (Date) -> String = { fmt.string(from: $0) }
    // 固定时刻,断言不随运行日漂移
    let today = Date(timeIntervalSince1970: 1_787_000_000)
    func off(_ n: Int) -> String { dayKey(cal.date(byAdding: .day, value: n, to: today)!) }

    let counts = [off(0): 5, off(-1): 3, off(-3): 7]
    expectEqual(IdleListeningStats.series(dailyCounts: counts, endingAt: today, days: 5,
                                          calendar: cal, dayKey: dayKey),
                [0, 7, 0, 3, 5], "走势序列:正序、缺的天补 0(桶只存非零天)")

    // 环比:前一个 7 天 100 → 最近 7 天 113
    let wow = IdleListeningStats.weekOverWeekDelta(
        dailyCounts: [off(-13): 100, off(-6): 113], today: today, calendar: cal, dayKey: dayKey)
    expectEqual(wow.map { Int(($0 * 100).rounded()) } ?? -999, 13, "环比:113 比 100 = +13%")
    expectEqual(IdleListeningStats.weekOverWeekDelta(
        dailyCounts: [off(-2): 5], today: today, calendar: cal, dayKey: dayKey) == nil,
                true, "环比:上一个 7 天为 0 时不给百分比(不显示 ∞/0%)")

    expectEqual(IdleListeningStats.dailyAverage(dailyCounts: ["a": 1, "b": 4])?.average, 3,
                "日均:5 ÷ 2 四舍五入")
    expectEqual(IdleListeningStats.dailyAverage(dailyCounts: ["a": 1, "b": 4])?.days, 2,
                "有记录天数 = 桶里的键数")
    expectEqual(IdleListeningStats.dailyAverage(dailyCounts: [:]) == nil, true,
                "空桶:算不出日均")

    // 走势图要按下标反查「这一根是哪天」(标峰值日期 / 悬停读数)。日期序列必须跟 series
    // **同一套对齐口径**,否则图上第 N 根和报出来的日期会错位。
    let ds = IdleListeningStats.days(endingAt: today, days: 5, calendar: cal)
    expectEqual(ds.count, 5, "日期序列:长度与 series 一致")
    expectEqual(ds.map(dayKey), (-4 ... 0).map(off), "日期序列:正序、末位是今天,与 series 对齐")

}

// MARK: - 停播页:选句(LyricQuotePicker,2026-08-24 用户报「经常只显示半句」后重做)
do {
    func L(_ ms: Int, _ t: String) -> LyricQuotePicker.Line {
        LyricQuotePicker.Line(timeMs: ms, text: t)
    }
    typealias Q = LyricQuotePicker

    // 核心回归:一句话被拆到两行上时必须并回来。单摆「我们」没有任何意义,
    // 这正是用户报的形状(LRC 的行是打轴单位、不是句子单位)。
    expectEqual(Q.phrases([L(20_000, "我们"), L(20_800, "都有难忘的回忆"),
                           L(28_000, "这一句自己就能站住不必再并")]),
                [["我们", "都有难忘的回忆"], ["这一句自己就能站住不必再并"]],
                "选句:碎片行并回整句,本身成话的行不动它")

    // 以悬挂词(在)结尾的行,并上下一行之后就完整了 —— 这是「修好」而不是「弃用」
    expectEqual(Q.phrases([L(0, "我把所有的回忆都留在"), L(9_000, "另一个夏天的午后阳光里")]),
                [["我把所有的回忆都留在", "另一个夏天的午后阳光里"]],
                "选句:悬挂结尾能并到下一行就并,不直接丢")

    // 并不上(整首只有这一行)时宁可整条弃用,绝不摆一句以「在」结尾的半句
    expectEqual(Q.phrases([L(0, "我把所有的回忆都留在")]), [],
                "选句:修不好的悬挂结尾整条弃用")

    // 以附着成分开头 = 这是被切下来的尾巴
    expectEqual(Q.phrases([L(0, "的时候我们都还很年轻啊")]), [],
                "选句:以「的」开头的尾巴不摆")

    // 噪音:段落标记 / 字符复读 / 整行括号伴唱
    expectEqual(Q.phrases([L(0, "Rap2："), L(1_000, "面面面面面"),
                           L(2_000, "（和声重复的伴唱）"), L(3_000, "这一句是正常的歌词内容")]),
                [["这一句是正常的歌词内容"]],
                "选句:段落标记/复读/括号伴唱全部挡掉")

    // 「歌名 - 歌手」被当正文存进来的抬头行。判据收得很窄:整行归一化后**正好等于**
    // 歌名+歌手才算,不能用「包含歌名」——那会把《成都》里「如果你正好在成都」一起杀掉。
    expectEqual(Q.phrases([L(0, "天气先生 - 方大同"), L(4_000, "这一句是正常的歌词内容")],
                          trackTitle: "天气先生", trackArtist: "方大同"),
                [["这一句是正常的歌词内容"]], "选句:抬头行挡掉,正常歌词留下")
    expectEqual(Q.phrases([L(0, "如果你正好在成都的街头走一走")], trackTitle: "成都"),
                [["如果你正好在成都的街头走一走"]], "选句:含歌名的正常歌词不能被误杀")

    // ⚠️ 一行带多个时间戳(副歌复用)时 LRCParser 按**文件顺序**各生成一条,数组并不按时间
    // 有序。不先排序,行间时间差会算出负数、断句全乱 —— 这条断言钉的就是「已经排过序」。
    expectEqual(Q.phrases([L(90_000, "副歌这一句在第二次出现"),
                           L(10_000, "开头这一句才是最早的"),
                           L(11_000, "紧跟着的短句")]),
                [["开头这一句才是最早的", "紧跟着的短句"], ["副歌这一句在第二次出现"]],
                "选句:先按时间排序再断句(多时间戳行不是有序的)")

    // 同一句在不同时间重复出现只留一条
    expectEqual(Q.phrases([L(0, "重复出现的同一句歌词"), L(20_000, "重复出现的同一句歌词")]),
                [["重复出现的同一句歌词"]], "选句:同文本去重")
}

// MARK: - 各平台跳转链接的纯判据(PlatformLinks,2026-08-24)
do {
    typealias P = PlatformLinks
    // 搜索兜底 vs 真·歌曲页。判据与 collector 的 isQQSearchFallbackURL 同源(qq.go:49-54)——
    // 把兜底链接当"这首歌的页面"给出去,用户点了会被丢到搜索结果页还得再点一次。
    expectEqual(P.isQQSearchFallback("https://y.qq.com/n/ryqq/search?w=%E7%A8%BB%E9%A6%99"), true,
                "QQ 链接:搜索兜底认得出来")
    expectEqual(P.isQQSearchFallback("https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49"), false,
                "QQ 链接:真·歌曲页不算兜底")
    expectEqual(P.isQQSearchFallback(""), false, "QQ 链接:空串不算兜底")

    expectEqual(P.qqAlbumURL(mid: "002B4bAK3AC0Cw")?.absoluteString,
                "https://y.qq.com/n/ryqq/albumDetail/002B4bAK3AC0Cw", "QQ 专辑页 URL")
    expectEqual(P.qqArtistURL(mid: "0025NhlN2yWrP4")?.absoluteString,
                "https://y.qq.com/n/ryqq/singer/0025NhlN2yWrP4", "QQ 歌手页 URL")
    expectEqual(P.qqAlbumURL(mid: "") == nil, true, "缺 mid 就不给链接(调用方据此隐藏入口)")

    // mid 形状闸。y.qq.com 是 SPA 空壳、**假 mid 也会 302**,服务端不校验 —— 链接对不对
    // 没有任何远端反馈,只能在本地把明显不是 mid 的东西挡掉。
    expectEqual(P.isPlausibleQQMid("002B4bAK3AC0Cw"), true, "mid 闸:正常 mid 通过")
    expectEqual(P.isPlausibleQQMid("abc/def"), false, "mid 闸:带斜杠的路径片段挡掉")
    expectEqual(P.isPlausibleQQMid("abc?x=1"), false, "mid 闸:带查询串挡掉")
    expectEqual(P.isPlausibleQQMid(String(repeating: "a", count: 33)), false, "mid 闸:超长挡掉")
    expectEqual(P.isPlausibleQQMid("a_b-c"), true, "mid 闸:下划线与短横线是合法字符")

    expectEqual(PlatformLinks(appleMusic: nil, qqSong: nil, qqAlbum: nil,
                              qqArtist: nil, neteaseSong: nil).isEmpty, true,
                "一个链接都没有时 isEmpty")
}

if failures == 0 {
    print("\nALL PASS")
} else {
    print("\n\(failures) FAILURE(S)")
}
exit(failures == 0 ? 0 : 1)
