import DesktopLyricsCore
import Foundation

// 手写的极简断言跑法:这台机器没有完整 Xcode,XCTest/Testing 两个测试框架都用不了
// ("no such module"),所以用普通可执行 target + assert 风格的比较代替,`swift run
// desktop-lyrics-selftest` 跑一遍即可,失败时进程以非零状态码退出。所有用例都是合成
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
// 字形簇,split(separator:"\n") 按 Character 比较匹配不上,曾导致整份文本切不开、
// tagRegex(无 ^ 锚点)在这"一整行"里找到多个时间戳,但方括号剥离只对整份文本做了一次,
// 于是每个时间戳都各自生成一条 LyricLine、text 却全部是同一份"整首歌拼在一起"的巨大
// 字符串——实测坐实为用户反馈的"酷狗歌词整个桌面都是歌词"的真正根因(2026-07-14)。
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

expectEqual(
    YRCParser.parse("[5000,1000](5000,500,0)second\n[1000,1000](1000,500,0)first\n").map(\.timeMs),
    [1000, 5000],
    "YRC: 输出按时间排序(输入乱序)"
)

expectEqual(YRCParser.parse(""), [], "YRC: 空输入")

// 见上面 LRCParser 同一处注释——CRLF 换行曾让 YRCParser 更彻底地失败:整份文本切不开后,
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

// ---- LyricsOffsetStore: 校正值 key 要按"歌词内容"区分,不能只按歌手/歌名 ----

do {
    let keyA = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:10.00]第一句\n", lyricsYRC: "")
    let keyASame = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:10.00]第一句\n", lyricsYRC: "")
    let keyBDifferentLyrics = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:12.00]第一句(重新匹配的另一份歌词)\n", lyricsYRC: "")
    expectEqual(keyA, keyASame, "LyricsOffsetStore.trackKey: 同一首歌+同一份歌词内容,key 应该完全一致")
    expectEqual(keyA == keyBDifferentLyrics, false, "LyricsOffsetStore.trackKey: 同一首歌换了一份不同的歌词内容,key 应该不同")
}

// ---- 汇总 ----

if failures == 0 {
    print("\nALL PASS")
} else {
    print("\n\(failures) FAILURE(S)")
}
exit(failures == 0 ? 0 : 1)
