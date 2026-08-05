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

// ---- 菜单栏跑马灯取窗(2026-08-05) ----

do {
    // 装得下就原样返回,不滚动。
    expectEqual(MenuBarMarquee.window(text: "短句", maxChars: 10, step: 0, holdSteps: 6), "短句", "跑马灯: 装得下就整句显示")
    expectEqual(MenuBarMarquee.window(text: "短句", maxChars: 10, step: 99, holdSteps: 6), "短句", "跑马灯: 装得下时任何一拍都不变")

    let text = "0123456789" // 10 字,窗口 4 字 → maxOffset = 6
    // 开头停留阶段:前 holdSteps 拍都停在开头
    expectEqual(MenuBarMarquee.window(text: text, maxChars: 4, step: 0, holdSteps: 3), "0123", "跑马灯: 第 0 拍停在开头")
    expectEqual(MenuBarMarquee.window(text: text, maxChars: 4, step: 2, holdSteps: 3), "0123", "跑马灯: 停留阶段末尾仍在开头")
    // 滚动阶段:每拍右移一个字
    expectEqual(MenuBarMarquee.window(text: text, maxChars: 4, step: 3, holdSteps: 3), "1234", "跑马灯: 停留结束后开始滚动")
    expectEqual(MenuBarMarquee.window(text: text, maxChars: 4, step: 4, holdSteps: 3), "2345", "跑马灯: 每拍右移一个字")
    // 滚到末尾后停住(不会滚过头露出空白)
    expectEqual(MenuBarMarquee.window(text: text, maxChars: 4, step: 9, holdSteps: 3), "6789", "跑马灯: 滚到末尾停住")
    expectEqual(MenuBarMarquee.window(text: text, maxChars: 4, step: 11, holdSteps: 3), "6789", "跑马灯: 末尾停留阶段保持不动")
    // 一个完整周期后回到开头(cycle = 6 + 3*2 = 12)
    expectEqual(MenuBarMarquee.window(text: text, maxChars: 4, step: 12, holdSteps: 3), "0123", "跑马灯: 一个周期后回到开头")
    // 边界:窗口宽度非法/负数拍都不能崩
    expectEqual(MenuBarMarquee.window(text: text, maxChars: 0, step: 5, holdSteps: 3), "", "跑马灯: 宽度为 0 返回空串不崩")
    expectEqual(MenuBarMarquee.window(text: text, maxChars: 4, step: -1, holdSteps: 3).count, 4, "跑马灯: 负数拍也返回合法窗口")
    // 中文/emoji 按字符取窗,不能把一个字切成两半
    expectEqual(MenuBarMarquee.window(text: "一二三四五六", maxChars: 3, step: 0, holdSteps: 1), "一二三", "跑马灯: 中文按字符取窗")
    expectEqual(MenuBarMarquee.window(text: "😀😃😄😁😆", maxChars: 2, step: 0, holdSteps: 1), "😀😃", "跑马灯: emoji 不会被切碎")
    // holdSteps 传 0 也必须先露出开头(下限被夹到 1)——不夹的话第 0 拍就跳到 offset 1,
    // 整句第一个字永远看不到。
    expectEqual(MenuBarMarquee.window(text: "0123456789", maxChars: 4, step: 0, holdSteps: 0), "0123", "跑马灯: holdSteps=0 时开头仍会露出(不漏首字)")
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

// ---- LyricsColumnWidths: 「歌词管理」可拖拽列宽的夹值逻辑(2026-08-05) ----
//
// 三条分隔条语义不对称:第 0 条(歌名|歌手)左边是弹性的歌名列,只能改「歌手」、由歌名被动
// 吸收;第 1/2 条是标准的"此消彼长、总宽不变"。夹值要同时守住三件事:每列不低于自己的下限、
// 歌名不低于 minTitle、单列不超过 maxColumn。

do {
    let W = LyricsColumnWidths.self
    let d = W.defaults
    // 表头总宽 630(navigationSplitViewColumnWidth 的 ideal 值),chrome = 12*2 + 8*3 = 48
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

// ---- 汇总 ----

if failures == 0 {
    print("\nALL PASS")
} else {
    print("\n\(failures) FAILURE(S)")
}
exit(failures == 0 ? 0 : 1)
