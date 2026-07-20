import Foundation

public struct SyncedLyricWord: Equatable {
    public let text: String
    // 真实起止时间戳(绝对播放位置,毫秒)——填色进度不在这里预烤成一个数字,改由 View 层
    // 用 TimelineView 按渲染帧频、从连续时钟直接现算 fillFraction。原来在这里预算好
    // fillFraction 再靠 20Hz tick 塞进 @Published 结构体、View 端用
    // .animation(.linear(duration:), value:) 补一段小动画的做法,在补间时长(60ms)比
    // tick 间隔(50ms)长时几乎总在上一段没放完就被重新触发——SwiftUI 对 .linear 这类
    // "不可合并"的曲线动画是把新旧两段位移矢量相加而不是从当前值接续,这正是逐字流转
    // 卡顿的结构性根源,不是调个补间时长能治本的。
    public let startMs: Int
    public let durationMs: Int
}

public struct SyncedLyricLine: Equatable {
    public let romanization: String?
    public let translation: String?
    public let mainText: String?         // 整行高亮时用(没有逐字数据)
    public let words: [SyncedLyricWord]? // 逐字高亮时用(有 yrc 数据)

    // 不关心逐字填色进度、只要这一行的纯文本时用(比如状态栏显示)——mainText/words
    // 两种形态只会有一个非空,按现有的判断顺序(有逐字数据优先逐字)取值。
    public var plainText: String? {
        if let mainText { return mainText }
        if let words, !words.isEmpty { return words.map(\.text).joined() }
        return nil
    }
}

// 按当前歌曲的四个歌词字段选基准 + 按外推位置算当前应该展示哪一行,算法照抄
// web/index.html 的 setLyrics()/syncLyrics():有 yrc(逐字)优先用,否则退化到 lyrics
// 整行;roma/tr 各自独立解析、用 700ms 容差的最近邻匹配贴到对应原文行。
public final class LyricsSyncEngine {
    private var baseLines: [LyricLine] = []
    private var wordLines: [LyricLineWords] = []
    private var romaLines: [LyricLine] = []
    private var trLines: [LyricLine] = []
    private var usingWords = false

    // 单曲歌词时间轴微调——毫秒,由 LyricsOffsetStore 按当前曲目 key 灌进来(见
    // LocalPlaybackSource/RelayPoller 的 reloadCurrentLyrics())。正数=歌词整体提前
    // (显示得比原始时间戳更早),负数=延后,0=不校正。只在这里(匹配的最后一步)统一加
    // 到查询位置上,activeLine/upcomingLineText 的调用方(20Hz fastTick)完全不用关心
    // 这件事,换歌时只要换一次 offsetMs 就对新歌词生效。
    public var offsetMs: Int = 0

    // 署名/制作人员这类噪声行(作词/作曲/编曲/制作人等,常见于 LRC 开头几秒),实测坐实:
    // 陶喆《上爱唱的歌》真实歌词从 00:26.74 才开始唱,前面 4 行是 [00:00~00:03] 这种挤在
    // 同一秒内的署名行——歌曲刚开始播放的头几秒,悬浮窗会显示"制作人：陶喆"这种字幕,
    // 乍看像是"没有歌词"。在喂进同步引擎之前(而不是显示时)就把这类行剔除,这样歌曲刚开
    // 播的那几秒会正确地判定成"还没到第一句真歌词"(退回♪占位符,双行预览提前露出第一句
    // 真歌词),而不是把署名行当成一句正常歌词展示出来。
    //
    // 单字缩写形式(词/曲/编/唱/录/混/监)另加一档——实测坐实:方大同《我不是农人》的
    // 酷狗(KRC)逐字数据把"作曲"缩写成"曲："、"作词"缩写成"词："(不是每个源都写全称),
    // 只有两字全称的这份正则完全逮不住,导致这类缩写署名行被当成真歌词播出来,用户反馈
    // "明明设置了带逐字的歌词,却没看到逐字效果"——不是同步没生效,是当前播的这一行内容
    // 本来就是署名行,不是真歌词,单字缩写又没被过滤掉。这是接入酷狗/QQ逐字源(2026-07-13
    // 同一天新增)之前从未出现过的新缺口——网易云的逐字数据里署名行一直是写全称的。
    //
    // "关键词 by：" 这种英文写法另加一档(可选的 `by`)——实测坐实:Michael Jackson 某些
    // 混音版(如 Earth Song (Hani's Club Experience))的酷狗 KRC 数据里,"Arranged by："
    // 后面跟着十来个混音/编曲人名(Michael Jackson/R.Kelly/Bruce Swedien/...),被当成
    // 逐字歌词的一整"行"时能拆出 30+ 个词——原来的正则要求关键词后紧跟冒号,"Arranged"
    // 和"："中间夹着"by"这个词直接把匹配打断,这类署名行完全没被过滤掉,当成正常歌词行
    // 展示,词数远超真实歌词的一行,表现成用户反馈的"整个桌面都是歌词"(WrapLayout 把
    // 三十多个词按正常字号自动换行,行数暴增,悬浮窗的动态高度——见
    // LyricsOverlayWindowController.updateHeight——被这一行硬撑到远超正常高度)。
    // 顺带补了"written"(Written by：)这个原来没在关键词表里的常见署名前缀。
    private static let creditLinePattern = try! NSRegularExpression(
        pattern: #"^(作词|作曲|编曲|制作人|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|词|曲|编|唱|录|混|监|OP|SP|lyrics|music|composed|produced|arranged|mixed|mastered|written)\s*(by\s*)?[:：]"#,
        options: [.caseInsensitive]
    )

    private static func isCreditLine(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return creditLinePattern.firstMatch(in: text, range: range) != nil
    }

    public init() {}

    public func load(lyrics: String, lyricsTr: String, lyricsRoma: String, lyricsYRC: String, preferWordLevel: Bool = true) {
        let yrc = preferWordLevel ? YRCParser.parse(lyricsYRC) : []
        usingWords = !yrc.isEmpty
        wordLines = usingWords ? yrc.filter { !Self.isCreditLine($0.words.map(\.text).joined()) } : []
        baseLines = usingWords ? [] : LRCParser.parse(lyrics).filter { !Self.isCreditLine($0.text) }
        romaLines = LRCParser.parse(lyricsRoma)
        trLines = LRCParser.parse(lyricsTr)
    }

    public var hasContent: Bool { usingWords ? !wordLines.isEmpty : !baseLines.isEmpty }

    private func nearestText(_ arr: [LyricLine], _ t: Int, tolerance: Int = 700) -> String? {
        var best: String?
        var bestDiff = tolerance
        for it in arr {
            let d = abs(it.timeMs - t)
            if d <= bestDiff { bestDiff = d; best = it.text }
        }
        return best
    }

    public func activeLine(atMs rawPosMs: Int) -> SyncedLyricLine? {
        let posMs = rawPosMs + offsetMs
        if usingWords {
            var idx = -1
            for (i, ln) in wordLines.enumerated() where ln.timeMs <= posMs { idx = i }
            guard idx >= 0 else { return nil }
            let ln = wordLines[idx]
            let words = ln.words.map { w in
                SyncedLyricWord(text: w.text, startMs: w.startMs, durationMs: w.durationMs)
            }
            return SyncedLyricLine(
                romanization: nearestText(romaLines, ln.timeMs),
                translation: nearestText(trLines, ln.timeMs),
                mainText: nil,
                words: words
            )
        }
        var idx = -1
        for (i, ln) in baseLines.enumerated() where ln.timeMs <= posMs { idx = i }
        guard idx >= 0 else { return nil }
        let ln = baseLines[idx]
        return SyncedLyricLine(
            romanization: nearestText(romaLines, ln.timeMs),
            translation: nearestText(trLines, ln.timeMs),
            mainText: ln.text,
            words: nil
        )
    }

    // 双行显示用:当前行的下一行纯文本预览,不需要逐字高亮细节(还没轮到它,不用算填色)。
    // 故意不要求 idx>=0——播放位置还没到第一句(idx=-1)时 nextIdx 自然等于 0,直接把
    // 第一句真歌词当预览提前露出来。署名行过滤上线后这个"还没到第一句"的窗口会变得
    // 更常见(署名行被剔除、真歌词往往要再等几十秒才开始),这时候提前露出第一句歌词
    // 比干等着更有用。
    public func upcomingLineText(afterMs rawPosMs: Int) -> String? {
        let posMs = rawPosMs + offsetMs
        if usingWords {
            var idx = -1
            for (i, ln) in wordLines.enumerated() where ln.timeMs <= posMs { idx = i }
            let nextIdx = idx + 1
            guard nextIdx < wordLines.count else { return nil }
            return wordLines[nextIdx].words.map(\.text).joined()
        }
        var idx = -1
        for (i, ln) in baseLines.enumerated() where ln.timeMs <= posMs { idx = i }
        let nextIdx = idx + 1
        guard nextIdx < baseLines.count else { return nil }
        return baseLines[nextIdx].text
    }
}
