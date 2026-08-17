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

// ---- LyricsOffsetStore: 校正值 key 要按"歌词内容"区分,不能只按歌手/歌名 ----

do {
    let keyA = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:10.00]第一句\n", lyricsYRC: "")
    let keyASame = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:10.00]第一句\n", lyricsYRC: "")
    let keyBDifferentLyrics = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:12.00]第一句(重新匹配的另一份歌词)\n", lyricsYRC: "")
    expectEqual(keyA, keyASame, "LyricsOffsetStore.trackKey: 同一首歌+同一份歌词内容,key 应该完全一致")
    expectEqual(keyA == keyBDifferentLyrics, false, "LyricsOffsetStore.trackKey: 同一首歌换了一份不同的歌词内容,key 应该不同")
}

// ---- MediaControlClient.spotifyPreloadDelta: gapless 预载分叉的取样判定 ----
// 2026-08-17 用户现行目击坐实:自动切歌(gapless)时 Spotify 的 playerPosition 时钟先于
// 真实出声启动(实测《星座》开播即 1.84s,MediaRemote 新锚点才 0.69s),整首歌恒偏快;
// 手动重播两源对齐。修法是在曲目开头量分叉、整首回扣 —— 这里钉死取样守卫。
do {
    // 用户目击的那个真实形状:开播时 playerPosition 1.84、新锚点 0.69 → 分叉 1.15,取样。
    expectEqual(MediaControlClient.spotifyPreloadDelta(truth: 1.84, freshAnchorNow: 0.69),
                1.84 - 0.69, "预载分叉: 目击的真实形状(1.15s)被取样")
    // 手动播放:两源对齐,分叉在噪声范围内 → 不取样,行为跟改动前完全一致。
    expectEqual(MediaControlClient.spotifyPreloadDelta(truth: 1.0, freshAnchorNow: 0.9),
                nil, "预载分叉: 两源对齐(手动播放)不取样")
    // 换歌瞬间 MediaRemote 锚点还挂着上一首:elapsedTimeNow 是个大值,分叉为负 → 排除。
    // (实测形状:playerPosition 0.02 vs 上一首残留的 30.3。)
    expectEqual(MediaControlClient.spotifyPreloadDelta(truth: 0.02, freshAnchorNow: 30.3),
                nil, "预载分叉: 陈旧锚点(负分叉)不取样")
    // App 中途启动看到的老歌:不在曲目开头,不回扣 —— 没有"出声起点"可参照。
    expectEqual(MediaControlClient.spotifyPreloadDelta(truth: 100, freshAnchorNow: 98.5),
                nil, "预载分叉: 曲目中段不取样")
    // 暂停中 elapsedTimeNow 还在走(实测),不能拿来量 → 调用方传 nil。
    expectEqual(MediaControlClient.spotifyPreloadDelta(truth: 2.0, freshAnchorNow: nil),
                nil, "预载分叉: 暂停态(无可信锚点)不取样")
    // 分叉大得离谱(>5s)更像数据错乱,不敢按预载解释。
    expectEqual(MediaControlClient.spotifyPreloadDelta(truth: 14.0, freshAnchorNow: 2.0),
                nil, "预载分叉: 超过 5s 的分叉不取样")
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
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: -1.2, preciseSource: true)
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
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: 0.205, preciseSource: true)
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
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, preciseSource: true)
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
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, preciseSource: false)
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
        let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: 1.5, preciseSource: false)
        ema = newEMA
        if snap { snapped = true; break }
    }
    expectEqual(snapped, true, "servoDecision(噪声源): 持续 1.5s 锁死偏差应最终被校正")
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

    // 剥前缀:全角/半角冒号都收
    expectEqual(D.splitMarker("男：周末守着烤箱").marker, "男", "对唱: 全角冒号识别")
    expectEqual(D.splitMarker("男：周末守着烤箱").text, "周末守着烤箱", "对唱: 前缀从正文里剥掉")
    expectEqual(D.splitMarker("女: 偏爱年轻女伴").text, "偏爱年轻女伴", "对唱: 半角冒号+空格")
    expectEqual(D.splitMarker("合：何时想戒掉流浪").marker, "合", "对唱: 合唱标记")
    // 长标记优先,否则 "男声" 会被 "男" 先吃掉、剩一个孤零零的 "声"
    expectEqual(D.splitMarker("男声：测试").text, "测试", "对唱: 长标记优先(男声 不是 男+声)")
    // 没标记的行原样返回
    expectEqual(D.splitMarker("情人节也落单").marker, nil, "对唱: 无标记行不动")
    expectEqual(D.splitMarker("情人节也落单").text, "情人节也落单", "对唱: 无标记行正文不变")
    // 署名行不能被误判成演唱者(词：/曲： 这类并非全都被署名过滤器滤掉)
    expectEqual(D.splitMarker("词：葛大为").marker, nil, "对唱: 署名行不算演唱者标记")
    expectEqual(D.splitMarker("曲：陶喆/蔡健雅").marker, nil, "对唱: 作曲署名不算演唱者标记")
    // 整行只有标记时不剥 —— 剥成空行会让这一行在界面上凭空消失
    expectEqual(D.splitMarker("男：").marker, nil, "对唱: 整行只有标记时不剥")
    // 逐字行的第一个词允许剥成空(调用方据此丢掉那个词)
    expectEqual(D.splitMarkerAllowingEmpty("男：").marker, "男", "对唱: 逐字首词允许剥成空")
    expectEqual(D.splitMarkerAllowingEmpty("男：周").text, "周", "对唱: 逐字首词剥完保留第一个字")

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
    // 整首没有标记的歌:全是 nil。这一条是**回归护栏** —— 混成 .leading 的话,悬浮窗上
    // 每一首普通歌都会从居中变成靠左。
    do {
        let sides = D.sides(for: [nil, nil, nil])
        expectEqual(sides.compactMap { $0 }.isEmpty, true, "对唱: 没有标记的歌全程无对唱信息")
    }
    // plan:剥正文 + 定边一次算完
    do {
        let plan = D.plan(lineTexts: ["男：周末守着烤箱", "情人节也落单", "女：偏爱年轻女伴"])
        expectEqual(plan.texts, ["周末守着烤箱", "情人节也落单", "偏爱年轻女伴"], "对唱: plan 剥掉全部前缀")
        expectEqual(plan.sides, [.leading, .leading, .trailing], "对唱: plan 定边")
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

    // Spotify:跳过单曲那一档
    expectEqual(Mode.list.next(allowsRepeatOne: false), .shuffle, "播放模式(无单曲): 列表→随机")
    expectEqual(Mode.shuffle.next(allowsRepeatOne: false), .list, "播放模式(无单曲): 随机→列表")
    // 起步档位恰好是单曲时(用户在 Apple Music 里开了单曲循环,再切到 Spotify 播放)也要能出来
    expectEqual(Mode.repeatOne.next(allowsRepeatOne: false), .list, "播放模式(无单曲): 单曲→列表")

    // 轮换闭合:连点下去不能卡在某一档出不来。
    //
    // ⚠️ 例外是"单曲档 + 不支持单曲"这一格:那是个**只能离开、回不去**的过渡态(用户在
    // Apple Music 里开着单曲循环、切到 Spotify 播放时可能读到它),回不去正是设计意图,
    // 不是卡住 —— 它能一步走掉(上面那条断言)就够了。第一版把它也算进"必须回到原点",
    // 断言直接红了,是断言写宽了,不是实现错了。
    for allows in [true, false] {
        for start in Mode.allCases {
            var cur = start
            var seen: [Mode] = []
            for _ in 0..<4 { cur = cur.next(allowsRepeatOne: allows); seen.append(cur) }
            let startIsUnreachable = !allows && start == .repeatOne
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
    func ratchet(_ reported: Double, _ predicted: Double, precise: Bool) -> Bool {
        LocalPlaybackSource.shouldRatchetForward(
            reported: reported, predicted: predicted, preciseSource: precise)
    }
    // QQ 音乐实测的形状：新锚点比外推值靠前 1 秒（旧锚点被向下取整拖晚了）。
    expectEqual(ratchet(23.1, 22.1, precise: false), true, "棘轮: 前向 1s 立刻采纳")
    expectEqual(ratchet(22.4, 22.1, precise: false), true, "棘轮: 前向 0.3s(半个字)也采纳")
    // 反方向分不清是取整噪声还是真实回退，绝不能棘轮 —— 交给原有 EMA 路径。
    expectEqual(ratchet(21.5, 22.1, precise: false), false, "棘轮: 后向不采纳(交给 EMA)")
    // 同锚点外推的 ±2ms 漂移不值得重建锚点。
    expectEqual(ratchet(22.102, 22.1, precise: false), false, "棘轮: 毫米级漂移不触发")
    // 精确源(Apple Music/Spotify)的读数本来就是真值，不适用"reported ≤ 真实位置"这条
    // 不等式，走原有 EMA。
    expectEqual(ratchet(23.1, 22.1, precise: true), false, "棘轮: 精确源不适用")
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

// MARK: - 歌词时间轴偏移:全局基准 + 单曲微调
//
// 2026-08-17 加全局偏移时补的。真正容易写错的不是那个加法,而是两层之间的**独立性**:
// 「重置这首歌」绝不能把设备侧的全局基准一起抹掉(那是用户最不希望被连带清掉的东西),
// 反过来改全局基准也不该动已经调好的单曲值。下面每一条都在守这件事。
// LyricsOffsetStore 是 @MainActor,而这个文件的顶层代码是 nonisolated 的(所以
// trackKey 才特意标了 nonisolated,见那边的注释)。顶层代码本来就跑在主线程上,
// assumeIsolated 把这件事告诉编译器即可,不需要把整个 selftest 改成 async。
MainActor.assumeIsolated {
    let store = LyricsOffsetStore.shared
    let key = LyricsOffsetStore.trackKey(artist: "A", title: "T", lyrics: "[00:01.00]x", lyricsYRC: "")
    // 起点归零 —— 这个 store 落在 UserDefaults 上,不清的话会读到上一次跑的残留
    store.setGlobalOffset(0)
    store.reset(forKey: key)
    expectEqual(store.effectiveOffset(forKey: key), 0, "偏移: 两层都没调时是 0")

    store.setGlobalOffset(300)
    expectEqual(store.effectiveOffset(forKey: key), 300, "偏移: 只有全局基准时按它算")

    store.nudge(by: -100, forKey: key)
    expectEqual(store.offset(forKey: key), -100, "偏移: 单曲微调独立记账")
    expectEqual(store.effectiveOffset(forKey: key), 200, "偏移: 生效值 = 全局 + 单曲")

    store.reset(forKey: key)
    expectEqual(store.offset(forKey: key), 0, "偏移: 重置清掉单曲微调")
    expectEqual(store.globalOffsetMs, 300, "偏移: 重置不动全局基准")
    expectEqual(store.effectiveOffset(forKey: key), 300, "偏移: 重置后回到全局基准")

    store.setOffset(-250, forKey: key)
    store.setGlobalOffset(-50)
    expectEqual(store.offset(forKey: key), -250, "偏移: 改全局基准不动单曲微调")
    expectEqual(store.effectiveOffset(forKey: key), -300, "偏移: 两个负值相加")

    // 空 key(从没拿到过曲目信息)不该被当成一首歌记账 —— 但全局基准跟曲目无关,照样生效
    store.setGlobalOffset(120)
    store.nudge(by: 500, forKey: "||")
    expectEqual(store.offset(forKey: "||"), 0, "偏移: 空 key 不记账")
    expectEqual(store.effectiveOffset(forKey: "||"), 120, "偏移: 空 key 下全局基准仍然生效")

    // 收尾:别把测试值留在 UserDefaults 里
    store.setGlobalOffset(0)
    store.reset(forKey: key)
}

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

if failures == 0 {
    print("\nALL PASS")
} else {
    print("\n\(failures) FAILURE(S)")
}
exit(failures == 0 ? 0 : 1)
