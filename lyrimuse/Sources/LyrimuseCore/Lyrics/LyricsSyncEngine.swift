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

// 供"歌词窗口"(完整可滚动歌词列表,跟悬浮窗/灵动岛那种只看当前一句不是一回事)用——
// activeLine(atMs:)/upcomingLineText(afterMs:) 都只查询单个时间点对应的一句,这里要的
// 是整首歌全部行一次性拿出来。id 不用裸的行下标:同一首歌换成下一首后,如果新旧两份
// 数组在相同下标位置渲染出内容不同的行,SwiftUI 的 ForEach 会尝试把旧行"变形"成新行
// 而不是干净地整体替换,换歌瞬间会有肉眼可见的串行/闪烁——调用方(LocalPlaybackSource)
// 应该把这个 id 拼上当前曲目的标识(比如已有的 currentOffsetKey),保证换歌后 id 集合
// 整体不同,ForEach 才会做一次干净的整体替换。
public struct LyricsWindowLine: Identifiable, Equatable {
    public let id: String
    public let timeMs: Int
    public let line: SyncedLyricLine
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
    // LocalPlaybackSource 的 reloadCurrentLyrics())。正数=歌词整体提前
    // (显示得比原始时间戳更早),负数=延后,0=不校正。只在这里(匹配的最后一步)统一加
    // 到查询位置上,activeLine/upcomingLineText 的调用方(20Hz fastTick)完全不用关心
    // 这件事,换歌时只要换一次 offsetMs 就对新歌词生效。
    public var offsetMs: Int = 0

    // 署名/制作人员这类噪声行(作词/作曲/编曲/制作人等,常见于 LRC 开头几秒)在喂进
    // 同步引擎之前(而不是显示时)就剔除——这样歌曲刚开始播放、真歌词还没开始的那几秒
    // 会正确判定成"还没到第一句真歌词"(退回♪占位符,双行预览提前露出第一句真歌词),
    // 而不是把署名行当成一句正常歌词展示出来。
    //
    // 正则要覆盖三种写法,分别对应不同来源的实际格式:两字全称(作词/作曲等,网易云常见)、
    // 单字缩写(词/曲/编/唱/录/混/监,酷狗 KRC 数据常把"作曲"缩写成"曲："、"作词"缩写成
    // "词：",只认全称的正则会漏判)、以及"关键词 by："这种英文写法(可选的 `by`,酷狗 KRC
    // 混音版署名常见,比如"Arranged by："中间夹着"by"的写法要求关键词紧跟冒号的正则会
    // 漏判,导致整行十几个人名被当成一整行歌词展示,词数远超真实歌词,把悬浮窗的动态高度
    // ——见 LyricsOverlayWindowController.updateHeight——撑到远超正常高度)。
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
        // 罗马音客户端兜底该不该对这首歌的汉字生效——按"整首歌"粒度判一次(扫原始的
        // lyrics/lyricsYRC 两个字段,不是解析过滤后的 baseLines/wordLines,署名行也该
        // 算进这个判断:哪怕正文过滤掉了,一整首歌只要出现过假名就足以确证是日文),
        // 而不是逐行判断——理由见 Romanizer.looksJapanese 的调用点注释,极少数纯汉字的
        // 日文行不该被局部误判成中文。
        songLooksJapanese = Romanizer.looksJapanese(lyrics) || Romanizer.looksJapanese(lyricsYRC)
        // 换歌词内容清空——见 romanizationText() 的缓存注释,纯粹是内存卫生考虑(避免
        // 常年挂着的进程把每一句听过的歌词文本都无限期缓存下去),不清空也不会算错,
        // 只是没必要让它跨曲目继续增长。
        romanizerFallbackCache.removeAll()
    }

    private var songLooksJapanese = false

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

    // 罗马音字段的服务端来源 + 客户端兜底组合——romaLines 完全为空(这首歌整体就没有
    // 服务端罗马音)时才现算兜底,不在"这一行没匹配上、但别的行有"这种局部空档里现算:
    // 那种情况混着展示"服务端标注的几行"+"现算兜底的几行"观感会不一致,不如保持现状
    // (那一行没有罗马音)交给下面 700ms 容差本身已经算合理的判断。
    //
    // ⚠️ 2026-08-04 实测排查坐实的真实性能回归:activeLine(atMs:) 由
    // LocalPlaybackSource.fastTick() 以 20Hz 调用,每次都会重新算一遍这一行的
    // romanization——没有服务端罗马音的歌(比如纯英文歌词)会在每一次 tick 都重新跑一遍
    // Romanizer.romanize() 的 ICU 音译,而不是只在真的换到新的一行时才算一次,导致主线程
    // 20 次/秒白白做重复的字符串音译运算,表现成"本地悬浮窗/歌词窗口进度肉眼可见地比
    // 网页端(走的是完全不同的一套外推逻辑,不受这里影响)慢、跟不上播放进度"。按
    // plainText 记忆化:同一句歌词文本只在第一次真正算一遍,之后的 19/20 次 tick 直接
    // 命中缓存,不再重复调用这个开销不小的字符串变换。
    private var romanizerFallbackCache: [String: String?] = [:]

    private func romanizationText(timeMs: Int, plainText: String) -> String? {
        if let fromSource = nearestText(romaLines, timeMs) { return fromSource }
        guard romaLines.isEmpty else { return nil }
        // 2026-08-04 实测排查坐实的真实 bug:含汉字的行只在"整首歌确认是日文"
        // (songLooksJapanese)时才允许兜底——纯中文歌曲(没有假名)没有这层限制的话,
        // 汉字会被 ICU 音译成拼音展示,对中文读者是纯噪声(NetEase 本来就不给中文歌曲
        // 算 lyrics_roma,这本身就是"不需要罗马音"的信号,客户端兜底不该越权覆盖这个
        // 判断)。不含汉字的行(韩文谚文/泰文/西里尔字母等)没有这层混淆,始终允许。
        if Romanizer.containsHan(plainText) && !songLooksJapanese { return nil }
        if let cached = romanizerFallbackCache[plainText] { return cached }
        let result = Romanizer.romanize(plainText)
        romanizerFallbackCache[plainText] = result
        return result
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
                romanization: romanizationText(timeMs: ln.timeMs, plainText: words.map(\.text).joined()),
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
            romanization: romanizationText(timeMs: ln.timeMs, plainText: ln.text),
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

    // "歌词窗口"用:整首歌全部行一次性拿出来,构造方式跟 activeLine(atMs:) 完全一致
    // (同一个 nearestText 贴罗马音/译文),只是对每一行都做一次,而不是只对查询命中的
    // 那一行做。idPrefix 由调用方传入(通常是当前曲目的标识,比如 currentOffsetKey),
    // 拼进每个 id 里——见 LyricsWindowLine 的类型注释,这是为了让 SwiftUI 在换歌时做
    // 一次干净的整体替换,而不是逐行"变形"旧内容。
    public func allLines(idPrefix: String) -> [LyricsWindowLine] {
        if usingWords {
            return wordLines.enumerated().map { i, ln in
                let words = ln.words.map { w in
                    SyncedLyricWord(text: w.text, startMs: w.startMs, durationMs: w.durationMs)
                }
                let line = SyncedLyricLine(
                    romanization: romanizationText(timeMs: ln.timeMs, plainText: words.map(\.text).joined()),
                    translation: nearestText(trLines, ln.timeMs),
                    mainText: nil,
                    words: words
                )
                return LyricsWindowLine(id: "\(idPrefix)#\(i)", timeMs: ln.timeMs, line: line)
            }
        }
        return baseLines.enumerated().map { i, ln in
            let line = SyncedLyricLine(
                romanization: romanizationText(timeMs: ln.timeMs, plainText: ln.text),
                translation: nearestText(trLines, ln.timeMs),
                mainText: ln.text,
                words: nil
            )
            return LyricsWindowLine(id: "\(idPrefix)#\(i)", timeMs: ln.timeMs, line: line)
        }
    }

    // "歌词窗口"用:跟 activeLine(atMs:) 扫的是同一个数组、加同一个 offsetMs 校正,
    // 只是返回下标而不是内容——故意不用"拿 activeLine 的内容去 allLines() 里找相同
    // 内容的下标"这种实现,副歌重复句会有多个内容相同的行,内容匹配选不准具体是哪一次
    // 出现,必须像这里一样直接按时间戳扫下标。
    public func activeLineIndex(atMs rawPosMs: Int) -> Int? {
        let posMs = rawPosMs + offsetMs
        if usingWords {
            var idx = -1
            for (i, ln) in wordLines.enumerated() where ln.timeMs <= posMs { idx = i }
            return idx >= 0 ? idx : nil
        }
        var idx = -1
        for (i, ln) in baseLines.enumerated() where ln.timeMs <= posMs { idx = i }
        return idx >= 0 ? idx : nil
    }
}
