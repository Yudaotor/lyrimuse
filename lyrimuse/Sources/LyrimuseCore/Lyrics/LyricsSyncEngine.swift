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

    // genericHanCreditLinePattern 是上面那张关键词表的**结构化**补充,跟 collector 侧的
    // genericHanCreditLineRe(match.go)是同一条规则、同一个理由——上面那张表已经补过至少
    // 两轮(两字全称 → 单字缩写 → "Arranged by:" 这种夹 by 的写法),每次都是被漏判的真实
    // 数据打回来才加的,说明枚举法在这件事上收敛不了:角色名的取值空间(指挥/混音师/贝斯/
    // 中提琴/大提琴/母带工程师/和声编写……)本来就堵不完。
    //
    // 改成认"短汉字标签 + 冒号 + 内容"这个**形状**:1~8 个汉字紧跟冒号,大概率就是
    // "角色:姓名"的职员表格式,真正在唱的歌词句子极少长这个样子。
    //
    // 三个刻意的收窄,都是为了不误杀真歌词:
    // ① 只认汉字标签(不含数字/字母),避免误伤"1、2、3:"这类编号或英文场景标签;
    // ② 上限 8 个汉字,再长就不像标签了;
    // ③ 冒号后必须有非空白内容(\S),纯粹以冒号结尾的句子(真歌词里的语气停顿)不算。
    //
    // ⚠️ 不要照抄别人那种 `^.{1,20}\s*[:：]\s*.+` 的宽松写法:`.` 能匹配任何字符,会把
    // "他说:我不走"这类正常带冒号的歌词整行吃掉。
    private static let genericHanCreditLinePattern = try! NSRegularExpression(
        pattern: #"^\p{Han}{1,8}\s*[:：]\s*\S"#
    )

    private static func matchesKeywordCreditPattern(_ text: String) -> Bool {
        creditLinePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 对唱/口白类歌词的**说话人标签**——这些跟职员表标签形状完全一样("短汉字 + 冒号"),
    /// 但冒号后面跟的是真歌词正文,绝对不能删。
    ///
    /// ⚠️ 这份豁免名单是必须的,不是保险起见:这类 LRC 把**每一句**都标成「男：」「女：」
    /// 「合：」,形状 100% 命中结构正则,下面那道"命中 ≥3 行且过半"的门反而**天然被满足**
    /// ——门是为了区分"零星对白"和"整份职员表",可这种歌是"整份都带标签的真歌词",占比判据
    /// 根本分不开。实测用户自己库里《怎么了 (feat. 袁咏琳)》已经 34% 命中,离 50% 只差一步,
    /// 一旦过线就是整首歌被静默删空。
    private static let speakerLabels: Set<String> = [
        "男", "女", "合", "男合", "女合", "男女", "众", "齐",
        "白", "旁白", "念", "说", "对白", "口白",
        "男声", "女声", "合唱", "伴唱",
    ]

    private static func matchesStructuralCreditPattern(_ text: String) -> Bool {
        guard genericHanCreditLinePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
            return false
        }
        // 命中形状之后再看标签本身是不是说话人标签——是就豁免(既不算 hits、也不会被删)。
        guard let sep = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<sep].trimmingCharacters(in: .whitespaces)
        return !speakerLabels.contains(label)
    }

    /// 结构化规则该不该对**这一整份**歌词生效。
    ///
    /// ⚠️ 这道整份判定是必须的,不是保险起见。collector 侧同一条结构正则(match.go 的
    /// genericHanCreditLineRe)用在"整份候选要不要拒收"的**计数**上,误判一行无害;这边用在
    /// "这一行删不删"的**展示过滤**上,误判一行就是静默吞掉一句真歌词——同一条规则,爆炸
    /// 半径完全不同,不能原样搬。2026-08-05 补这条规则时,selftest 的反向用例当场抓到
    /// "他说：我不走"被误杀("他说"= 2 个汉字 + 冒号 + 内容,形状完全命中)。
    ///
    /// 判据:真正要治的病是"网易云给纯音乐/配乐类曲目返回一整份职员表当歌词",特征是**整份
    /// 都是这个形状**;而正常歌曲里的对白冒号只是零星一两句。所以要求命中行既达到绝对下限
    /// (≥3 行,一两句对白够不着),又占到半数以上(整份被主导)。两个条件缺一不可:只看比例,
    /// 一首只有 2 句歌词的短曲里一句对白就过半;只看行数,一首 50 行的歌里 3 句对白就被误杀。
    private static func shouldApplyStructuralCreditFilter(_ texts: [String]) -> Bool {
        guard !texts.isEmpty else { return false }
        let hits = texts.filter(matchesStructuralCreditPattern).count
        return hits >= 3 && hits * 2 > texts.count
    }

    /// 过滤掉署名/职员表行。关键词表逐行生效(它枚举的都是明确的角色名,误判空间很小);
    /// 结构化规则只在整份被主导时才生效,见 shouldApplyStructuralCreditFilter。
    private static func strippingCreditLines(_ texts: [String]) -> [Bool] {
        let useStructural = shouldApplyStructuralCreditFilter(texts)
        let drop = texts.map { text -> Bool in
            if matchesKeywordCreditPattern(text) { return true }
            return useStructural && matchesStructuralCreditPattern(text)
        }
        // 兜底闸门:展示过滤**永远不把整份删空**。走到这一步说明判据出了我没预料到的偏差
        // (某种全篇都长成职员表形状、但其实是真歌词的写法),此时"整片空白/一直显示♪"对用户
        // 来说比"多显示几行职员表"糟糕得多——宁可漏治,不可删空。跟 collector 侧
        // isCreditOnlyLRC 的"整份拒收"是两回事:那边拒收之后还有别的源可以顶上,这边删空了
        // 就真的什么都没有了。
        if drop.allSatisfy({ $0 }) && !texts.isEmpty {
            return texts.map { _ in false }
        }
        return drop
    }

    public init() {}

    public func load(lyrics: String, lyricsTr: String, lyricsRoma: String, lyricsYRC: String, preferWordLevel: Bool = true) {
        let yrc = preferWordLevel ? YRCParser.parse(lyricsYRC) : []
        // 过滤前先把整份的文本取出来判一次(结构化规则是整份粒度的,见
        // shouldApplyStructuralCreditFilter),不能像原来那样逐行独立 filter。
        //
        // 两种来源都先各自解析+过滤出来,再决定用哪个 —— 原来是"有 YRC 就一定用 YRC",
        // 而有些源给的逐字数据是**退化**的:2026-08-06 在用户缓存里实测到「方大同 - 特别的人」
        // 的 YRC 只有 10 行,其中 9 行被判成署名行(编曲/混音师/录制…),而同一首的 LRC 有
        // 105 行。**不是 10 行全是** —— strippingCreditLines 特意留了"整份都被判成署名就一行
        // 都不删"的兜底(见那个函数结尾),真要 10 行全中,反而一行都不会被过滤掉。
        // 过滤掉那 9 行之后 wordLines 只剩 1 行,而 activeLine 取的是"时间戳 <= 当前位置
        // 的最后一行"——于是整首歌从头到尾都卡在那一行上,悬浮歌词/灵动岛/歌词窗口全都
        // 一动不动,看起来像"这首歌的歌词坏了"。
        //
        // 判据是**覆盖率**而不是"YRC 是否为空":逐字行数不到整行歌词的一半就认为它没覆盖
        // 这首歌,退回整行模式(整行歌词是完整的,只是没有逐字填色)。LRC 本身为空时没得选,
        // 仍然用逐字数据。
        let parsedBase = LRCParser.parse(lyrics)
        let baseDrop = Self.strippingCreditLines(parsedBase.map(\.text))
        let filteredBase = zip(parsedBase, baseDrop).compactMap { $0.1 ? nil : $0.0 }
        var candidateWords: [LyricLineWords] = []
        if !yrc.isEmpty {
            let texts = yrc.map { $0.words.map(\.text).joined() }
            let drop = Self.strippingCreditLines(texts)
            candidateWords = zip(yrc, drop).compactMap { $0.1 ? nil : $0.0 }
        }
        usingWords = !candidateWords.isEmpty
            && (filteredBase.isEmpty || candidateWords.count * 2 >= filteredBase.count)
        if usingWords {
            wordLines = candidateWords
            baseLines = []
        } else {
            wordLines = []
            baseLines = filteredBase
        }
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
        let result = Romanizer.romanize(plainText, japanese: songLooksJapanese)
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
