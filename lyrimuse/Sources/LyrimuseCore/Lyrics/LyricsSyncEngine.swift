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

    public init(text: String, startMs: Int, durationMs: Int) {
        self.text = text
        self.startMs = startMs
        self.durationMs = durationMs
    }
}

/// 一组「共享同一段罗马音」的逐字词。
///
/// Apple Music 的日文歌词是把罗马音标在**对应内容的正下方**、而不是整行堆在上面一行,
/// 而且罗马音跟着逐字一起填色。要做到这个,就得知道"这段读音对应原文的哪几个字"——
/// 分词器给的片段边界跟歌词源的逐字切分**不一定对齐**(酷狗常常一个汉字一个词,而
/// 「いつか」在分词器眼里是一个词),所以按片段把逐字词并成组:一组一列,列宽取
/// 「主文字」和「罗马音」里更宽的那个 —— Apple 那边日文行间距不均匀,正是被下面的罗马音
/// 撑开的。
public struct SyncedLyricWordGroup: Equatable, Identifiable {
    public let id: Int
    public let words: [SyncedLyricWord]
    public let romanization: String?

    public init(id: Int, words: [SyncedLyricWord], romanization: String?) {
        self.id = id
        self.words = words
        self.romanization = romanization
    }

    /// 这一组整体的起止,用来给下面那行罗马音算填色进度(跟着整组走,不跟着单个字跳)。
    public var startMs: Int { words.first?.startMs ?? 0 }
    public var endMs: Int { words.last.map { $0.startMs + $0.durationMs } ?? 0 }
}

public struct SyncedLyricLine: Equatable {
    public let romanization: String?
    public let translation: String?
    public let mainText: String?         // 整行高亮时用(没有逐字数据)
    public let words: [SyncedLyricWord]? // 逐字高亮时用(有 yrc 数据)
    /// 逐字词按读音分好的组,只有"这一行确实能标罗马音"时才非空。视图可以选择用它做
    /// Apple 那种逐词标注,拿不到时退回 `romanization` 那一整行。
    public let wordGroups: [SyncedLyricWordGroup]?
    /// 这一行摆在哪一边 —— 对唱歌词的左右分栏,见 LyricDuet。
    /// **nil = 这首歌没有演唱者标记**(或还没到第一个标记),不是"靠左";各视图按自己的
    /// 默认排版兜底(歌词窗口 `?? .leading`、悬浮窗 `?? .center`)。
    public var side: LyricDuet.Side?

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
    // 跟上面两个数组逐行对应的左右分栏结果(对唱歌词)。没有演唱者标记的歌全是 .leading。
    private var baseSides: [LyricDuet.Side?] = []
    private var wordSides: [LyricDuet.Side?] = []
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
    //
    // ⚠️ 关键词可以**连写**(那个 `+`),这是 2026-08-15 补的第四轮:「词曲：蔡徐坤 KUN/…」
    // 一路漏到悬浮窗上。原来的写法要求关键词紧跟冒号,而"词曲"是两个关键词连在一起,
    // "词"后面是"曲"不是冒号,于是整条不匹配。同形状的还有「作词作曲：」「词 曲 编：」。
    // 下面那条结构化规则本可以兜住它,但那条只在整份被职员表主导时才启用(见
    // shouldApplyStructuralCreditFilter),单独几行署名的歌就漏了。
    // 连写不会扩大误杀面:表里全是明确的角色名,连着出现只会更像署名行,不会更像歌词。
    //
    // 2026-08-16 第五轮:角色词之间允许夹**连接词**(和/与/及/、// /&),并允许"所有/全部"
    // 这类前缀量词 —— 「制作和编曲：方大同」「所有乐器和编程：Soulboy」整行漏到悬浮窗上。
    // 旧写法只允许角色词紧挨着连写("词曲"),中间一个"和"字就断了;"制作""编程""乐器"
    // 也一并补进表(此前只有"制作人")。结构分两段:第一个角色词打底,后面每一节是
    // "可选连接词 + 角色词",空白也当分隔("词 曲 编："仍然命中)。连接词后面必须再跟
    // 角色词才算数 —— "唱和："这种词后面没有角色词,回退到"唱"+冒号也对不上,不误杀。
    private static let creditLinePattern = try! NSRegularExpression(
        pattern: #"^(所有|全部)?\s*(作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|lyrics|music|composed|produced|arranged|mixed|mastered|written)(\s*(和|与|及|、|/|&|＆)?\s*(作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|lyrics|music|composed|produced|arranged|mixed|mastered|written))*\s*(by\s*)?[:：]"#,
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
    // 第六轮(2026-08-16):「数字编辑：Jeff Li」「母带处理：Randy Merrill@Sterling Sound」
    // 出现在歌曲**末尾**,角色词又是表外的。逐词追注定追不完(见上面"枚举法收敛不了"),
    // 这条改成**双字角色词包含判定**:标签侧(冒号前)是 1~8 个纯汉字、且包含任何一个
    // 双字角色词,就是职员表行 —— "数字编辑"包含"编辑"、"母带处理"包含"母带"和"处理",
    // 以后"XX编辑/XX制作/XX工程"这类组合词全都自动覆盖,不用再等用户报一个补一个。
    //
    // 跟上面关键词表的分工:那张表管**精确形态**(单字缩写"词曲编"、拉丁"composed by"、
    // 连接词串),这条管**组合词**。只收双字词、不收单字,是精度的关键:对唱标签是歌手名
    // ("曲婉婷："),单字"曲"会误杀它,双字词不会 —— 歌手名里嵌着完整双字角色词的概率
    // 可以忽略。
    private static let creditRoleWords: [String] = [
        "作词", "作曲", "编曲", "编辑", "编程", "制作", "监制", "混音", "母带", "处理",
        "录音", "录制", "和声", "吉他", "贝斯", "键盘", "弦乐", "乐器", "工程", "企划",
        "统筹", "发行", "出品", "演奏", "指挥", "后期", "音效", "版权", "鸣谢", "摄影",
        "设计", "封面",
    ]

    public static func matchesRoleWordCredit(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        // 冒号后必须有内容 —— 纯粹以冒号结尾的句子是真歌词里的语气停顿,不算。
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, (1...8).contains(label.count),
              label.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }
        return creditRoleWords.contains { label.contains($0) }
    }

    private static let genericHanCreditLinePattern = try! NSRegularExpression(
        pattern: #"^\p{Han}{1,8}\s*[:：]\s*\S"#
    )

    // 拉丁字母标签的职员表行。上面那张关键词表只收了中文角色名和少数几个英文词,于是
    // 「Guitar：秋山浩徳」「Keyboards Programming：河野圭」「Strings Arrange：河野圭」
    // 这些整排漏网 —— 2026-08-10 用户报的正是这个:一首歌开头一堆制作人信息照样显示。
    //
    // 判据不是"英文角色名"的枚举(枚举收敛不了,见 genericHanCreditLinePattern 那段),
    // 而是**全角冒号**这个形状:这类署名块来自中日文歌词源,标签用拉丁字母、冒号却是全角
    // 的「：」。英文歌词里出现全角冒号几乎不可能,所以这一条几乎没有误杀空间。
    // 实测:全库 537 行里精确命中那 6 行署名,零误伤。
    //
    // 半角冒号只在**冒号后面跟着中日文**时才认 —— 同样是"中日文源的署名块"这个信号,
    // 而英文歌词里的冒号("I said: let's go")后面不会跟汉字/假名。单靠半角冒号 + 拉丁
    // 标签是不敢删的:"Verse 1: ..." 这类真会出现在歌词里。
    private static let latinCreditFullWidthPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9 .&/'’\-]{0,28}：\s*\S"#
    )
    private static let latinCreditHalfWidthPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9 .&/'’\-]{0,28}:\s*\S*[\p{Han}\p{Hiragana}\p{Katakana}]"#
    )

    private static func matchesLatinCreditPattern(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        if latinCreditFullWidthPattern.firstMatch(in: text, range: r) != nil { return true }
        return latinCreditHalfWidthPattern.firstMatch(in: text, range: r) != nil
    }

    /// 歌词文件开头那行「曲名 - 歌手」抬头。它没有冒号,上面所有规则都够不着,但它同样
    /// 不是歌词 —— 用户看到的第一句就是它。
    ///
    /// 判据要求这一行**同时**含曲名和歌手名,而且必须是正文第一行。只看曲名是不行的:
    /// 很多歌的第一句歌词本来就是歌名(「First Love」)。歌手名对不上(抬头用罗马字而我们
    /// 记的是日文名)时宁可不删。
    public static func looksLikeHeaderLine(_ text: String, trackTitle: String, trackArtist: String) -> Bool {
        guard !trackTitle.isEmpty, !trackArtist.isEmpty else { return false }
        func norm(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        // 抬头写的常是**裸曲名**,而本地标签带着 "(Remastered 2014)" 这类后缀 —— 两边直接
        // 比会对不上(2026-08-10 第一版就栽在这儿,抬头一行没删掉)。去掉括号段再比一次。
        func stripBrackets(_ s: String) -> String {
            var out = "", depth = 0
            for c in s {
                if c == "(" || c == "[" || c == "（" || c == "［" { depth += 1 }
                else if c == ")" || c == "]" || c == "）" || c == "］" { depth = max(0, depth - 1) }
                else if depth == 0 { out.append(c) }
            }
            return out
        }
        let line = norm(text)
        let a = norm(trackArtist)
        guard !a.isEmpty, line.contains(a) else { return false }
        for candidate in [trackTitle, stripBrackets(trackTitle)] {
            let t = norm(candidate)
            guard !t.isEmpty, line.count > t.count else { continue }
            if line.contains(t) { return true }
        }
        return false
    }

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
    private static func strippingCreditLines(
        _ texts: [String], trackTitle: String = "", trackArtist: String = ""
    ) -> [Bool] {
        let useStructural = shouldApplyStructuralCreditFilter(texts)
        let drop = texts.enumerated().map { i, text -> Bool in
            if matchesKeywordCreditPattern(text) { return true }
            if matchesLatinCreditPattern(text) { return true }
            // 双字角色词判定跟关键词表一样逐行生效(不受"整份主导"闸门管):双字词的
            // 误杀面足够小,见 creditRoleWords 上的注释。
            if matchesRoleWordCredit(text) { return true }
            // 抬头只在第一行认 —— 别的位置出现同样的字样多半是真歌词。
            if i == 0, looksLikeHeaderLine(text, trackTitle: trackTitle, trackArtist: trackArtist) {
                return true
            }
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

    public func load(
        lyrics: String, lyricsTr: String, lyricsRoma: String, lyricsYRC: String,
        preferWordLevel: Bool = true, trackTitle: String = "", trackArtist: String = "",
        romanizationScripts: RomanizationScripts = .default
    ) {
        self.romanizationScripts = romanizationScripts
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
        let baseDrop = Self.strippingCreditLines(
            parsedBase.map(\.text), trackTitle: trackTitle, trackArtist: trackArtist)
        let filteredBase = zip(parsedBase, baseDrop).compactMap { $0.1 ? nil : $0.0 }
        var candidateWords: [LyricLineWords] = []
        if !yrc.isEmpty {
            let texts = yrc.map { $0.words.map(\.text).joined() }
            let drop = Self.strippingCreditLines(
                texts, trackTitle: trackTitle, trackArtist: trackArtist)
            candidateWords = zip(yrc, drop).compactMap { $0.1 ? nil : $0.0 }
        }
        usingWords = !candidateWords.isEmpty
            && (filteredBase.isEmpty || candidateWords.count * 2 >= filteredBase.count)
        if usingWords {
            // 对唱标记(男：/女：/合：)在逐字数据里跟第一个字粘在一起,共享同一个时间戳
            // ——只能改那个词的文本,不能整个删掉,它扛着第一个字的发声时间。见 LyricDuet。
            var markers: [String?] = []
            wordLines = candidateWords.map { ln in
                guard let first = ln.words.first else {
                    markers.append(nil)
                    return ln
                }
                let (marker, rest) = LyricDuet.splitMarkerAllowingEmpty(first.text)
                markers.append(marker)
                guard marker != nil else { return ln }
                var words = ln.words
                if rest.isEmpty {
                    // 标记单独成一个词,整个丢掉(它只占了标记本身那点时长)。
                    words.removeFirst()
                } else {
                    words[0] = LyricWord(startMs: first.startMs, durationMs: first.durationMs, text: rest)
                }
                return LyricLineWords(timeMs: ln.timeMs, words: words)
            }
            wordSides = LyricDuet.sides(for: markers)
            baseLines = []
            baseSides = []
        } else {
            let plan = LyricDuet.plan(lineTexts: filteredBase.map(\.text))
            wordLines = []
            wordSides = []
            baseLines = zip(filteredBase, plan.texts).map { LyricLine(timeMs: $0.0.timeMs, text: $0.1) }
            baseSides = plan.sides
        }
        romaLines = LRCParser.parse(lyricsRoma)
        trLines = LRCParser.parse(lyricsTr)
        // 罗马音客户端兜底该不该对这首歌的汉字生效——按"整首歌"粒度判一次(扫原始的
        // lyrics/lyricsYRC 两个字段,不是解析过滤后的 baseLines/wordLines,署名行也该
        // 算进这个判断:哪怕正文过滤掉了,一整首歌只要出现过假名就足以确证是日文),
        // 而不是逐行判断——理由见 Romanizer.looksJapanese 的调用点注释,极少数纯汉字的
        // 日文行不该被局部误判成中文。
        songLooksJapanese = Romanizer.looksJapanese(lyrics) || Romanizer.looksJapanese(lyricsYRC)
        // 整首歌的文字种类,给"按语言开关罗马音"用。判定粒度跟上面 songLooksJapanese
        // 完全一致(整首、扫原始字段),不逐行判 —— 同一个理由。
        songScript = Romanizer.script(of: lyrics.isEmpty ? lyricsYRC : lyrics)
        // 歌词源自带的假名标注(酷狗的 [kana:] 标签)。对不齐时 parse 返回 nil,读音自动
        // 退回形态分析 —— 见 KanaAnnotation 顶部注释里"半对半错比不标更糟"那段。
        kanaAnnotation = KanaAnnotation.parse(lrc: lyrics)
        // 换歌词内容清空——见 romanizationText() 的缓存注释,纯粹是内存卫生考虑(避免
        // 常年挂着的进程把每一句听过的歌词文本都无限期缓存下去),不清空也不会算错,
        // 只是没必要让它跨曲目继续增长。
        romanizerFallbackCache.removeAll()
        wordGroupCache.removeAll()
    }

    private var songLooksJapanese = false
    private var songScript: LyricScript = .other
    private var romanizationScripts: RomanizationScripts = .default

    /// 这首歌该不该标罗马音 —— 由它的文字种类和用户开关共同决定。
    /// `.other`(拉丁/泰文/西里尔…)不受管辖,始终允许,保持历来的行为。
    private var romanizationAllowed: Bool {
        guard let option = songScript.option else { return true }
        return romanizationScripts.contains(option)
    }
    private var kanaAnnotation: KanaAnnotation?

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
        // ⚠️ 这道闸必须在**服务端字段之前**。用户关掉某种语言的罗马音,意思是"别给我看",
        // 不是"别去现算" —— 只拦客户端兜底的话,服务端恰好给了 lyrics_roma 的那些歌照样
        // 会显示,开关就成了个看运气的东西。
        guard romanizationAllowed else { return nil }
        if let fromSource = nearestText(romaLines, timeMs) { return fromSource }
        guard romaLines.isEmpty else { return nil }
        // 这里原来有一道硬编码的闸:"含汉字、且整首歌不像日文 → 一律不兜底"。
        // 它解决的是 2026-08-04 那个真实 bug —— 中文歌被 ICU 音译成拼音展示,对中文读者
        // 是纯噪声(NetEase 本来就不给中文歌算 lyrics_roma,那本身就是"不需要"的信号)。
        //
        // 2026-08-15 删掉:那道闸表达的是"我们替用户决定中文不要拼音",而现在这件事由
        // 用户自己的开关表达(上面的 romanizationAllowed,中文默认关 —— 默认行为跟以前
        // 一模一样)。留着它的话,用户明明打开了中文罗马音却什么都不会发生:绝大多数中文歌
        // 没有服务端 lyrics_roma,能出拼音的唯一途径正是这里的客户端兜底。
        //
        // songLooksJapanese 仍然要传给 romanize() —— 它决定走日语形态分析还是 ICU 音译,
        // 那是另一回事(汉字在两种语言里读音完全不同,见 Romanizer.romanize 的注释)。
        if let cached = romanizerFallbackCache[plainText] { return cached }
        let result = Romanizer.romanize(
            plainText, japanese: songLooksJapanese,
            marks: kanaAnnotation?.marks(forLine: plainText) ?? [])
        romanizerFallbackCache[plainText] = result
        return result
    }

    // 行文本 → 词组。跟 romanizerFallbackCache 同样按行缓存:同一行在播放期间会被反复
    // 查询(20Hz 定位 + 每帧填色),分词是纯 CPU 活,不该每次重算。
    private var wordGroupCache: [String: [SyncedLyricWordGroup]?] = [:]

    /// 把逐字词按分词器的片段边界并成组,并给每组配上罗马音。
    ///
    /// 关键点是**整行一次性分词**再按 UTF-16 范围对回去,而不是逐词单独求读音 —— 日文
    /// 读音吃上下文,单独喂「明日」和放在句子里给出的读音可能不一样。
    ///
    /// 边界不对齐是常态:酷狗的逐字常常一个汉字一个词,而分词器眼里「いつか」是一个词。
    /// 所以一个片段横跨几个词时就把这几个词并成一组(下面那段罗马音标在整组底下);反过来
    /// 一个词里落进好几个片段时,把这些片段的读音拼起来给这一个词。
    private func wordGroups(for words: [SyncedLyricWord]) -> [SyncedLyricWordGroup]? {
        guard !words.isEmpty else { return nil }
        let line = words.map(\.text).joined()
        if let cached = wordGroupCache[line] { return cached }
        // 逐词读音只对日文产出(buildWordGroups 里 guard japanese),所以它受同一道
        // 按语言开关的管辖 —— 关掉日文罗马音之后,逐字歌词下面也不该再标读音。
        let result = Self.buildWordGroups(
            words: words, line: line, japanese: songLooksJapanese && romanizationAllowed,
            marks: kanaAnnotation?.marks(forLine: line) ?? [])
        wordGroupCache[line] = result
        return result
    }

    // nonisolated static:纯函数,不碰引擎自身状态,selftest 直接覆盖。
    public static func buildWordGroups(
        words: [SyncedLyricWord], line: String, japanese: Bool,
        marks: [KanaAnnotation.Mark] = []
    ) -> [SyncedLyricWordGroup]? {
        // 跟 romanizationText 同一道门:含汉字但整首歌看着不像日文时不敢标读音,那多半是
        // 中文歌,标出来会是拼音、不是用户要的东西。
        guard japanese, Romanizer.looksJapanese(line) else { return nil }
        let segs = Romanizer.japaneseSegments(line, marks: marks)
        guard !segs.isEmpty else { return nil }

        var starts: [Int] = []
        var cursor = 0
        for w in words {
            starts.append(cursor)
            cursor += w.text.utf16.count
        }

        var groups: [SyncedLyricWordGroup] = []
        var i = 0
        while i < words.count {
            var j = i
            var end = starts[j] + words[j].text.utf16.count
            // 有片段跨过这一组的右边界 → 把下一个词也吃进来,直到边界落在片段之间。
            var grew = true
            while grew {
                grew = false
                for seg in segs where seg.utf16Start < end && seg.utf16End > end {
                    guard j + 1 < words.count else { break }
                    j += 1
                    end = starts[j] + words[j].text.utf16.count
                    grew = true
                    break
                }
            }
            let start = starts[i]
            let latins = segs.filter { $0.utf16Start < end && $0.utf16End > start }.map(\.latin)
            groups.append(SyncedLyricWordGroup(
                id: groups.count,
                words: Array(words[i...j]),
                romanization: latins.isEmpty ? nil : Romanizer.joinLatin(latins)))
            i = j + 1
        }
        // 一组罗马音都配不上(整行都是拉丁字母之类)时当作没有,让视图退回原来的整行罗马音。
        return groups.contains { $0.romanization != nil } ? groups : nil
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
                words: words,
                wordGroups: wordGroups(for: words),
                side: wordSides.indices.contains(idx) ? wordSides[idx] : nil
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
            words: nil,
            wordGroups: nil,
            side: baseSides.indices.contains(idx) ? baseSides[idx] : nil
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
                    words: words,
                    wordGroups: wordGroups(for: words),
                    side: self.wordSides.indices.contains(i) ? self.wordSides[i] : nil
                )
                return LyricsWindowLine(id: "\(idPrefix)#\(i)", timeMs: ln.timeMs, line: line)
            }
        }
        return baseLines.enumerated().map { i, ln in
            let line = SyncedLyricLine(
                romanization: romanizationText(timeMs: ln.timeMs, plainText: ln.text),
                translation: nearestText(trLines, ln.timeMs),
                mainText: ln.text,
                words: nil,
                wordGroups: nil,
                side: self.baseSides.indices.contains(i) ? self.baseSides[i] : nil
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
