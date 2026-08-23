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
    // 两种形态只会有一个非空,按判断顺序(有逐字数据优先逐字)取值。
    // 2026-08-20 从计算属性改成存储属性:引擎构造行时本来就为 romanizationText 拼过同一份
    // words.map(\.text).joined(),而消费方(菜单栏 refresh/各 body 重估)每次访问都重新
    // map+join 同一句纯属分配 churn —— 构造时存一次,访问变 O(1)。
    public let plainText: String?

    /// `plainText` 传 nil 时按老计算属性的口径推导(mainText 优先于 words 拼接)——引擎的
    /// 构造点都显式传预拼好的值,这个默认路径只服务少数手写构造(如 selftest,所以 public)。
    public init(romanization: String?, translation: String?, mainText: String?,
                words: [SyncedLyricWord]?, wordGroups: [SyncedLyricWordGroup]?,
                side: LyricDuet.Side?, plainText: String? = nil) {
        self.romanization = romanization
        self.translation = translation
        self.mainText = mainText
        self.words = words
        self.wordGroups = wordGroups
        self.side = side
        // 显式传入的空串退回推导链:引擎对 words==[] 的行(对唱标记单独成词被整个删掉)
        // 预拼出来是 "",而旧计算属性对这种行返回 nil —— 灵动岛的 `plainText ?? "♪"`
        // 靠 nil 才能显示占位音符(2026-08-20 对抗审查抓出的口径差)。
        if let plainText, !plainText.isEmpty {
            self.plainText = plainText
        } else if let mainText {
            self.plainText = mainText
        } else if let words, !words.isEmpty {
            self.plainText = words.map(\.text).joined()
        } else {
            self.plainText = nil
        }
    }
}

// 供"歌词窗口"(完整可滚动歌词列表,跟悬浮窗/灵动岛那种只看当前一句不是一回事)用——
// activeLine(atMs:)/upcomingLineText(afterMs:) 都只查询单个时间点对应的一句,这里要的
// 是整首歌全部行一次性拿出来。id 不用裸的行下标:同一首歌换成下一首后,如果新旧两份
// 数组在相同下标位置渲染出内容不同的行,SwiftUI 的 ForEach 会尝试把旧行"变形"成新行
// 而不是干净地整体替换,换歌瞬间会有肉眼可见的串行/闪烁——调用方(LocalPlaybackSource)
// 应该把这个 id 拼上当前曲目的标识(比如已有的 currentOffsetKey),保证换歌后 id 集合
// 整体不同,ForEach 才会做一次干净的整体替换。
extension CharacterSet {
    /// 汉字 + 假名。给 LyricsSyncEngine 的抬头分段判定用(见 scriptRuns)。
    static let hanLike: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "\u{3040}"..."\u{30FF}")   // 平假名 + 片假名
        s.insert(charactersIn: "\u{3400}"..."\u{4DBF}")   // 扩展 A
        s.insert(charactersIn: "\u{4E00}"..."\u{9FFF}")   // 基本区
        s.insert(charactersIn: "\u{F900}"..."\u{FAFF}")   // 兼容表意
        return s
    }()
}

public struct LyricsWindowLine: Identifiable, Equatable {
    public let id: String
    public let timeMs: Int
    public let line: SyncedLyricLine
}

/// 歌词间奏点(2026-08-19,歌词窗口的 Apple Music 式「•••」呼吸圆点)。
/// index == -1 表示前奏(第一句之前),其余表示"这一行唱完之后"。start/end 是这段间奏
/// 的活跃窗口,**歌词原始时间轴**(offsetMs 校正前)—— 视图侧比较时要用
/// 外推位置 + currentLyricsOffsetMs,跟逐字填色同一套时间基准。
public struct LyricsGapMarker: Equatable, Identifiable {
    public let index: Int
    public let startMs: Int
    public let endMs: Int
    public var id: Int { index }
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

    /// 这份歌词**自己带的** `[offset:]`(LRC 格式标准的字段,见 `LRCParser.parseOffsetMs`),
    /// load() 时从内容里解析,用户碰不到。
    ///
    /// 跟 `offsetMs` **分开存**而不是加进去:那个是用户手调的值(全局/按播放器/单曲三层的
    /// 合成结果,由 LyricsOffsetStore 灌进来),这个是歌词内容的属性。混在一起的后果是换一份
    /// 歌词时旧的 LRC offset 会残留在用户那层里,而且用户在设置页看到的数字会莫名其妙多出
    /// 几百毫秒。分开之后还有一个实际好处:万一某个源的符号约定跟规范相反,用户用单曲微调
    /// 抵消掉即可,不需要我们去猜哪个源该取反。
    public private(set) var lrcOffsetMs: Int = 0

    /// 实际用于定位的总偏移。**所有**查询入口都必须用它,不能再直接用 `offsetMs`。
    public var effectiveOffsetMs: Int { offsetMs + lrcOffsetMs }

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
        pattern: #"^(所有|全部|中文|英文|韩文|日文|粤语|中|英|韩|日)?\s*(唱片公司|发行公司|出品公司|专辑|翻译|作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|P\s*-\s*Line|C\s*-\s*Line|℗|©|lyrics|music|composed|produced|arranged|mixed|mastered|written)(\s*(和|与|及|、|/|&|＆)?\s*(唱片公司|发行公司|出品公司|专辑|翻译|作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|lyrics|music|composed|produced|arranged|mixed|mastered|written))*\s*(by\s*)?[:：]"#,
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
        // 第八轮(2026-08-17):用户报「演唱：Jeremy McKinnon (A Day To Remember)、MAX、
        // henry 刘宪华」漏网。⚠️ 刻意**不收**「合唱」——对唱歌词里「合唱：」是分声部
        // 标记,后面跟的是真歌词,收了就是误杀(同「曲婉婷：好久不见」那条反例的道理)。
        "演唱", "原唱", "翻唱",
        // 第九轮(2026-08-18):日文源的头部标注。调研 LyricsX 的默认过滤表时发现它收了
        // 一整类我们完全没覆盖的词(収録/主題歌/片頭曲/片尾曲/挿入歌/アニメ),那是它拿真实
        // 日文歌词数据攒出来的。本地缓存里目前一条都没有(几乎全是华语),所以这是**提前**
        // 填坑而不是修实测漏判 —— 收进来几乎零风险:这些词做不了歌词句子,而且这条规则
        // 本来就要求"标签全是汉字 + 紧跟冒号"。
        //
        // ⚠️ 只收**汉字**形态。假名(アニメ)进不来:matchesRoleWordCredit 要求标签
        // isIdeographic,片假名不满足。日文里更常见的「TVアニメ「XXX」オープニングテーマ」
        // 这种**不带冒号**的整行标注这里**没有覆盖**,本地零样本,不凭空猜。
        "収録", "収録", "主題", "片頭", "片尾", "挿入",
        // 简体对应写法(简繁互认由下面 matchesRoleWordCredit 里的 HanScript 兜,但
        // 「収」「挿」是日文新字体、不在简繁对照表里,仍要显式列)。
        "收录", "主题", "片头", "插入",
        // LyricsX 也收了这几个,同样是"带冒号才算"的安全形态。
        "歌手", "歌曲", "歌词",
        // 第十轮(2026-08-20):用户报赵雷《成都》头部 13 行职员表里有 4 行漏到展示面上 ——
        // 「钢琴：柳森」「箱琴：赵雷/喜子」「笛子：祝子」「童声：朵朵/天天」。表里本来有
        // 吉他/贝斯/键盘/弦乐/和声,偏偏没有这几样乐器。补的同时也别只补这四个(那就是
        // 这个文件自己写明「收敛不了」的老路),真正的通用解法是下面那条
        // matchesNameListCreditShape ——这里补词只为兜住"整首只有一行署名"的场合
        // (那条规则要求整份 ≥2 行才启用)。
        "钢琴", "箱琴", "笛子", "童声", "口琴", "二胡", "琵琶", "古筝", "长笛", "提琴",
        "唢呐", "手鼓", "打击", "合成", "采样", "编写", "小号", "萨克",
        // 第十一轮(2026-08-20,全库语料统计):这几个也是表外乐器/角色。刻意**不收**
        // 「主唱」「合作」:它们更可能被用作对唱/口白的说话人标签,而那两类署名在真实
        // 数据里总是成片出现,交给 matchesNameListCreditShape 的整份闸去收更安全。
        "竖琴", "长号", "副唱", "和音", "三和",
    ]

    /// 标签里允许出现的分隔符。第七轮(2026-08-16)加的:用户报「录音师/录音室：王力宏/
    /// Homeboy Studios, Taipei, Taiwan」没被滤掉 —— 一个人身兼两职时标签会写成
    /// "录音师/录音室"、"作词/作曲"、"混音&母带",中间那个符号让"标签全是汉字"这条判定
    /// 直接失败。把它们剔掉再判,而不是放宽成"允许任意非汉字"(那会把英文场景标签也放进来)。
    private static let creditLabelSeparators = CharacterSet(charactersIn: "/／、&＆·・和与及,，")

    /// 标签尾巴上那段**英文对照**里出现的角色名。
    ///
    /// 只在"汉字头 + 拉丁尾"的双语标签里当第二判据用(见 matchesRoleWordCredit):汉字头是
    /// 「曲」「词」「鼓」这种单字时,表里那些双字词一个都够不着,而把单字加进 creditRoleWords
    /// 会把真歌词里的对白吃掉(「他：我不走」那一类,2026-08-16 已经踩过一次并回滚)。
    /// 有英文对照在旁边,歧义就没了 —— 「曲 Composer：」不可能是对白。
    private static let englishRoleNounPattern = try! NSRegularExpression(
        pattern: #"\b(producers?|composers?|lyricists?|lyrics|arrang(?:er|ement|ed)|"#
            + #"engineers?|engineering|studios?|drums?|bass|guitars?|keyboards?|strings|"#
            + #"vocals?|chorus|programming|mixing|mixed|mastering|mastered|recording|recorded|"#
            + #"assistant|producti?on|publisher|label|orchestra|conductor|percussion|piano|"#
            + #"synth(?:esizer)?|sax(?:ophone)?|trumpet|violin|cello|harmonica|"#
            + #"photograph(?:y|er)|artwork|design(?:er)?|mv|director)\b"#,
        options: [.caseInsensitive]
    )

    /// 把双语标签拆成「汉字头」和「拉丁尾」。拆不出干净的两段时原样返回(拉丁尾为空),
    /// 让调用方走原来那条纯汉字的路。
    ///
    /// 判据刻意收紧:拉丁尾只允许字母/空白/少量标点(不许出现数字、汉字),长度 ≤ 40 —— 它
    /// 应该是"Recording Studio""Background vocals by"这种角色名对照,不是一整句话。
    private static func splitBilingualLabel(_ label: String) -> (han: String, latin: String) {
        var han = ""
        var idx = label.startIndex
        while idx < label.endIndex {
            let ch = label[idx]
            let isHan = ch.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
            let isSep = ch.unicodeScalars.allSatisfy { creditLabelSeparators.contains($0) }
            guard isHan || isSep else { break }
            han.append(ch)
            idx = label.index(after: idx)
        }
        let tail = label[idx...].trimmingCharacters(in: .whitespaces)
        guard !han.isEmpty, !tail.isEmpty, tail.count <= 40 else { return (label, "") }
        // ⚠️ 两道守卫,都是拿真实歌词库量出来的(2026-08-19,42880 行):
        //
        // 1. 标签里不许有括号。命中的反例是真歌词行「我们让彼此难过(SL:那些到底算是谁的错)
        //    都别争了」—— 第一个冒号落在行内注解 `(SL:` 里面,于是"冒号前"被当成标签,
        //    汉字头 7 个字、拉丁尾 "(SL" 全都符合形状。括号出现在冒号之前,几乎总意味着
        //    这个冒号属于某个行内注解,而不是标签分隔符。
        // 2. 拉丁尾必须以**字母**开头。同一件事的第二种说法,两条互相兜底。
        let brackets = CharacterSet(charactersIn: "()（）[]【】{}〔〕")
        guard !label.unicodeScalars.contains(where: { brackets.contains($0) }),
              tail.first?.isLetter == true
        else { return (label, "") }
        let allowed = CharacterSet.letters.union(.whitespaces)
            .union(CharacterSet(charactersIn: "&/.,'()-＆"))
        guard tail.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              tail.unicodeScalars.allSatisfy({ !$0.properties.isIdeographic })
        else { return (label, "") }
        return (han, tail)
    }

    /// 双语标签的**免词表**形状:汉字头 + 拉丁尾 + 冒号 + 值,不要求命中任何角色词表。
    ///
    /// 为什么需要它:靠词表永远在打地鼠。2026-08-19 用户先报「制作人 Producer」那一批,补了
    /// 词表;紧接着又报「西塔琴 Coral sitar: Jamie Wilson」—— 西塔琴不在汉字表里、sitar 也
    /// 不在英文表里。全库扫下来这类"两边词表都不认"的双语署名有 51 行,涉及中提琴/竖琴/长号/
    /// 富鲁格号/电钢琴/管风琴/说唱/画/词OP/合成器/小号/萨克斯风/钢片琴/特雷门/大键琴/西塔琴/
    /// 笛子/二胡/古筝… 乐器和职能名是**开放集合**,枚举不完。
    ///
    /// 所以改成认**形状**。但形状比词表松,必须配一道闸(见 strippingCreditLines 里的
    /// bilingualHits):**整份里至少 2 行**是这个形状才生效 —— 署名块从来不会只有孤零零
    /// 一行,而万一真有一句歌词长成这样,它落单就不会被吃掉。
    public static func matchesBilingualCreditShape(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return false }
        let (han, latin) = splitBilingualLabel(String(label))
        guard !latin.isEmpty else { return false }
        let core = han.components(separatedBy: creditLabelSeparators).joined()
        guard !core.isEmpty, (1...10).contains(core.count),
              core.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }
        // 说话人标签豁免走同一份名单(「男 Male:」这种对唱标注真实存在)。
        return !speakerLabels.contains(core)
    }

    public static func matchesRoleWordCredit(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        // 冒号后必须有内容 —— 纯粹以冒号结尾的句子是真歌词里的语气停顿,不算。
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // 「汉字角色词 + 英文对照」的双语标签(酷狗/QQ 的中文曲库很常见):
        // 「制作人 Producer：陶喆」「鼓 Drums：Ash Soan」。
        //
        // 2026-08-19 用户报陶喆《Stupid Pop Song》开头 13 行职员表全都漏过去 —— 原因就在
        // 这儿:label 取的是冒号前的整段("制作人 Producer"),而下面那条判定要求**剔掉
        // 分隔符后全是汉字**,拉丁字母一进来整条就失败了。而结构化规则(那个只在"整份被
        // 职员表主导"时才开的闸)也救不了这首:14 行职员表 + 三十多行真歌词,占不到半数。
        let (hanLabel, latinLabel) = splitBilingualLabel(String(label))
        // 长度按**剔掉分隔符之后**算:"录音师/录音室"有 7 个字符,但真正的标签内容是 6 个汉字。
        var core = hanLabel.components(separatedBy: creditLabelSeparators).joined()
        // 标签里混着拉丁字母/型号/括号时,只看**汉字那一部分**(2026-08-20 第十一轮)。
        // 语料里的漏网形态:「Protools编辑：…」(拉丁在前、汉字在后,splitBilingualLabel 只认
        // 汉字头+拉丁尾)、「键盘乐器 DX7 and synths：…」、「键盘乐器 Keyboards (Piano and
        // synth) by：…」。判据仍然落在汉字角色词上,只是不再要求"标签必须全是汉字"。
        // 前提:标签的非汉字部分必须是字母/数字/空格/括号这类**标注性**内容,不能像句子
        // (否则「Oh 我说：」这种真歌词的标签会被放进来 —— 那种情况汉字部分也命不中角色词,
        // 双保险)。
        if !core.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }) || core.isEmpty {
            let hanOnly = String(label).unicodeScalars
                .filter { $0.properties.isIdeographic }
                .map(Character.init)
            let nonHanOK = String(label).unicodeScalars.allSatisfy { u in
                u.properties.isIdeographic || CharacterSet.alphanumerics.contains(u)
                    || " ./&()'’-：:".unicodeScalars.contains(u)
            }
            if nonHanOK, !hanOnly.isEmpty { core = String(hanOnly) }
        }
        // 上限仍然是 10:放宽到 20 会撞既有断言「标签超过 8 字不像职员表」(长句子里嵌一个
        // 角色词就会被当署名)。真正的长标签(「中音萨克斯/次中音萨克斯/上低音萨克斯：」)
        // 交给 matchesNameListCreditShape —— 它有整份 ≥2 行的闸,放宽长度是安全的。
        // 纯拉丁标签也**不在这条管**(既有断言钉着分工),归 matchesLatinCreditPattern。
        guard !rest.isEmpty, (1...10).contains(core.count), !core.isEmpty,
              core.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }
        // 繁体标签(「作詞」「編曲」「主題歌」)不再需要在表里双写一份 —— 转成孪生写法再比
        // 一次就行。2026-08-18 加:调研 LyricsX 时看到它是把繁简两种写法都手工列进默认表的,
        // 那份表因此长了一倍还容易漏(它有「作詞」也有「作词」,但「録音」就只有「录音」)。
        let forms = [core, HanScript.sibling(core)].compactMap { $0 }
        if creditRoleWords.contains(where: { word in forms.contains { $0.contains(word) } }) {
            return true
        }
        // 汉字头没命中,但旁边那段英文对照本身就是明确的角色名 —— 见 englishRoleNounPattern。
        guard !latinLabel.isEmpty else { return false }
        let range = NSRange(latinLabel.startIndex..., in: latinLabel)
        return englishRoleNounPattern.firstMatch(in: latinLabel, range: range) != nil
    }

    /// 纯英文的职员表行,**没有冒号**那一类。
    ///
    /// 第七轮(2026-08-16)加的:用户报歌曲末尾的「Mixed by Wang Leehom at Homeboy Music
    /// Studios」没被滤掉。上面两条规则都要求有冒号,而英文署名的习惯写法是
    /// "Mixed by X" / "Produced by X" / "Recorded at Y",一个冒号都没有。
    ///
    /// 收窄到不误杀真歌词:必须**整行以角色词开头**(不是出现在句中),角色词后面必须紧跟
    /// by 或 at,再后面必须还有内容。英文歌词里"written by"之类出现在行首、且后面跟人名的
    /// 概率极低;而真出现在句中的("a song written by fate")不会被这条吃掉。
    private static let englishCreditPattern = try! NSRegularExpression(
        pattern: #"^\s*(mixed|mastered|produced|written|composed|arranged|recorded|engineered|performed|lyrics|music|vocals?|guitars?|bass|drums|keyboards?|strings|programming|artwork|photography|design)\b[^\n]{0,20}?\s+(by|at)\s+\S"#,
        options: [.caseInsensitive]
    )

    public static func matchesEnglishCredit(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return englishCreditPattern.firstMatch(in: text, range: range) != nil
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
    // 标签上限 2026-08-20 从 28 放到 40:语料里「Additional Vocal Production by：Oscar Free」
    // 标签本身就 30 个字符,原来那条长度上限直接把它挡在门外。
    private static let latinCreditFullWidthPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9 .&/'’()\-]{0,40}：\s*\S"#
    )
    // 半角那条:CJK 不必紧跟在冒号后的第一个词里 —— 语料里「P - Line: 2016 北京享耳音乐…」
    // 的第一个词是年份,原来的 `\S*` 跨不过那个空格,整类 ℗/© 版权行(20 行)因此漏网。
    private static let latinCreditHalfWidthPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9 .&/'’()\-]{0,40}:[^\p{Han}\p{Hiragana}\p{Katakana}]{0,24}[\p{Han}\p{Hiragana}\p{Katakana}]"#
    )

    /// 冒号右边像不像"一句话"(而不是一串名字)。给拉丁标签那条规则当否决闸。
    ///
    /// 2026-08-20 加,修的是一整类**真歌词被误杀**:拉丁字母的**说话人标签**长得跟拉丁
    /// 角色名一模一样,而这条规则原来只看"拉丁标签 + 冒号"这个形状、完全不看右边。
    /// 拿全库 935 首(47626 行正文)跑回归语料挖出来的实例:
    ///
    ///     Rain：给我大声地说我爱你      ×12   ← 「Rain」是歌手名,后面是真歌词
    ///     Rain：정말 자신 있겠지         ×2
    ///     S:只会让我不小心 / S:好想问你       ← 「S」是对唱声部标记
    ///     SL：啊把日期(給它)撕掉，
    ///     N.Chen：（聽不懂...），
    ///     Rap:欢迎来到我的房间
    ///
    /// 那条规则当初的实测是"全库 537 行里精确命中 6 行署名、零误伤"——样本小了两个数量级。
    ///
    /// 判据(命中任一即认为是句子、放它过去):
    ///  - 含中文虚词(nonNameChars:的了是不我你他她…)—— 人名里不会有;
    ///  - 含谚文且至少两个空格 —— 韩文人名是 2~4 个字连写,不会带两个空格;
    ///  - 以句末标点收尾(，。！？…)。
    /// 反过来,「Guitar：秋山浩徳」「Written by：Prince」「Choir：The Hong Kong Children's
    /// Choir」「P/C：2020 Riot Games」这些右边全是干净的人名/团体名,照旧判成署名。
    /// 英文里"人名/团体名不会是"的词。跟 nonNameChars 是同一个思路的拉丁版。
    ///
    /// 2026-08-20 第十一轮补。上一轮的句子否决只看中文虚词,于是**英文对白**照样被当署名删掉
    /// —— 加语料哨兵时当场抓到:`Rain：Baby I love you so much` 是真歌词,却因为
    /// 「拉丁标签 + 全角冒号」这个形状被整行吃掉。
    ///
    /// ⚠️ 刻意**不收** the/and/of/a/at/by/for/in/on/with:它们大量出现在真实署名里
    /// (`SOYEON of (G)I-DLE`、`The Hong Kong Children's Choir`、`Additional Vocal
    /// Production by`),收了就把真署名放过去。只收代词/系动词/否定/常见谓语。
    private static let nonNameWordsLatin: Set<String> = [
        "i", "im", "i'm", "you", "you're", "youre", "we", "we're", "he", "she", "they",
        "me", "my", "your", "our", "am", "is", "are", "was", "were", "be", "been",
        "do", "dont", "don't", "doesnt", "doesn't", "did", "can", "cant", "can't",
        "will", "wont", "won't", "not", "never", "gonna", "wanna", "gotta",
        "love", "know", "feel", "need", "want", "say", "said", "tell", "come",
        "go", "going", "gone", "let", "lets", "let's", "get", "got", "make", "made",
        "why", "how", "when", "where", "what", "who", "yeah", "oh", "ooh",
    ]

    static func latinCreditRestLooksLikeSentence(_ rest: String) -> Bool {
        if rest.contains(where: { nonNameChars.contains($0) }) { return true }
        // 英文句子:按**空白**切词,再剥掉词首尾的标点,比整词。
        //
        // ⚠️ 不能按"所有非字母数字"切:「(G)I-DLE/Bea Miller/Wolftyla」那样会切出一个孤立的
        // "i",而 "i" 是停用词 —— 于是真署名被当成句子放过去(2026-08-20 语料里
        // 「合作艺人：(G)I-DLE/…」「主唱：SOYEON of (G)I-DLE/…」正是这么漏的)。
        let punct = CharacterSet(charactersIn: "()[]{}'’\"“”,.!?;:/&-_~…")
        let words = rest.lowercased()
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: punct) }
            .filter { !$0.isEmpty }
        if words.contains(where: { nonNameWordsLatin.contains($0) }) { return true }
        if rest.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }),
           rest.filter({ $0 == " " }).count >= 2 { return true }
        if let last = rest.last, "，。！？!?…；;".contains(last) { return true }
        return false
    }

    private static func matchesLatinCreditPattern(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        let shapeHit = latinCreditFullWidthPattern.firstMatch(in: text, range: r) != nil
            || latinCreditHalfWidthPattern.firstMatch(in: text, range: r) != nil
        guard shapeHit else { return false }
        // 形状命中之后再看右边像不像一句话 —— 见 latinCreditRestLooksLikeSentence。
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return !latinCreditRestLooksLikeSentence(rest)
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
        // 判据是**形状 + 等值**,不是"歌名出现在行内":整行必须能切成两段,一段(去掉括号
        // 后)正好等于歌名、另一段含歌手名。
        //
        // 2026-08-18 两轮才定成这样。第一版写的是"任一个歌名段出现在行内即可",全库扫描
        // 看着漂亮(45 条抬头抓到 34、首末行零误伤),但 selftest 的反向用例当场抓到
        // 「新的经典 蛋堡 x Jabberloop」——那是蛋堡《经典!》的**真歌词**,歌名「经典」和歌手
        // 「蛋堡」都在行里,于是整句被判成抬头。它恰好不在首行才没出事(抬头只在首行判),
        // 纯属运气。展示过滤误杀一行就是静默吞掉一句真歌词,不能靠运气。
        //
        // 换成等值判定之后,真歌词天然不成立(句子里总有别的词),而抬头这个格式本身就是
        // 「歌名 - 歌手」两段结构。代价是少数写法抓不到(歌名里自带多个连字符、或者压根
        // 没有分隔符的抬头),那是刻意的:宁可漏治,不可删空。
        for (lhs, rhs) in headerSplitCandidates(text) {
            // 歌名侧要**去括号后等值**(抬头写裸歌名,本地标签常带 "(Remastered)" 后缀);
            // 歌手侧只做 contains,而且**用原文不去括号** —— 抬头里歌手名经常就写在括号里
            // (「First Love - 宇多田光 (宇多田ヒカル)」,本地标签记的是括号里那个写法)。
            // 2026-08-18 一度对两侧都去括号,当场被这条原有 selftest 用例打回来。
            let leftTitle = norm(stripBracketsForHeaderMatch(lhs))
            let rightTitle = norm(stripBracketsForHeaderMatch(rhs))
            let leftRaw = norm(lhs), rightRaw = norm(rhs)
            guard !leftRaw.isEmpty, !rightRaw.isEmpty else { continue }
            let titles = Set(headerTitleForms(trackTitle).map(norm)).subtracting([""])
            let artists = headerMatchVariants(of: trackArtist).map(norm).filter { !$0.isEmpty }
            // 两种摆法都有:「歌名 - 歌手」和「歌手 - 歌名」。
            if titles.contains(leftTitle), artists.contains(where: { rightRaw.contains($0) }) { return true }
            if titles.contains(rightTitle), artists.contains(where: { leftRaw.contains($0) }) { return true }
        }
        return false
    }

    /// 把一行切成"抬头的两段"的所有候选切法。
    ///
    /// 先试**带空格的** " - "(抬头最常见的写法);只有它唯一出现时才用,这样
    /// 「W-H-Y - 王力宏」这种歌名自带连字符的也能正确切开。带空格的没有或不唯一时,
    /// 退回"整行只有一个裸连字符"的情形(「陳柏宇-最後的擁抱」)。
    private static func headerSplitCandidates(_ text: String) -> [(String, String)] {
        for sep in [" - ", " – ", " — "] {
            let parts = text.components(separatedBy: sep)
            if parts.count == 2 { return [(parts[0], parts[1])] }
        }
        let dashes: Set<Character> = ["-", "–", "—"]
        guard text.filter({ dashes.contains($0) }).count == 1,
              let idx = text.firstIndex(where: { dashes.contains($0) })
        else { return [] }
        return [(String(text[text.startIndex..<idx]), String(text[text.index(after: idx)...]))]
    }

    /// 歌名可以长成的样子:原样、去括号、按字形切出的段(双语拼接靠它),各自加简繁孪生。
    /// **不设长度下限** —— 上面是等值判定,一两个字的歌名(「追」「GF」)不会因此误杀。
    private static func headerTitleForms(_ s: String) -> [String] {
        var out = [s, stripBracketsForHeaderMatch(s)]
        out.append(contentsOf: scriptRuns(stripBracketsForHeaderMatch(s)))
        var seen = Set<String>()
        var result: [String] = []
        for raw in out {
            let p = raw.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty, seen.insert(p).inserted else { continue }
            result.append(p)
            if let sib = HanScript.sibling(p), seen.insert(sib).inserted { result.append(sib) }
        }
        return result
    }

    /// 把标签拆成"可以单独比对"的若干段——整串、去括号、按分隔符拆出的每一段、按字形
    /// (汉字段 / 拉丁段)切出的每一段,以及每一段的简繁孪生写法。只给抬头判定用。
    ///
    /// 长度下限是刻意分开的:汉字段 ≥2 字,拉丁段 ≥4 字。拉丁段放宽到 2 会把 "The"/"You"
    /// 这类冠词代词当成歌名段,而英文歌词里几乎必然出现,那就成了误杀机器。
    private static func headerMatchVariants(of s: String) -> [String] {
        var pieces: [String] = []
        let separators = CharacterSet(charactersIn: "&/、,，;；|-–—")
        for base in [s, stripBracketsForHeaderMatch(s)] where !base.isEmpty {
            pieces.append(base)
            let flattened = base.replacingOccurrences(
                of: "feat.", with: "/", options: .caseInsensitive)
            pieces.append(contentsOf: flattened.components(separatedBy: separators))
            pieces.append(contentsOf: scriptRuns(base))
        }
        var out: [String] = []
        var seen = Set<String>()
        for raw in pieces {
            let p = raw.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty, longEnoughForHeaderMatch(p) else { continue }
            if seen.insert(p).inserted { out.append(p) }
            if let sib = HanScript.sibling(p), seen.insert(sib).inserted { out.append(sib) }
        }
        return out
    }

    /// 汉字段和拉丁段各自的长度下限,见 headerMatchVariants 的注释。
    private static func longEnoughForHeaderMatch(_ s: String) -> Bool {
        let han = s.unicodeScalars.filter { CharacterSet.hanLike.contains($0) }.count
        if han > 0 { return han >= 2 }
        return s.filter { $0.isLetter || $0.isNumber }.count >= 4
    }

    /// 按字形把一段文本切成"连续汉字/假名"和"连续拉丁"两类子串——双语拼接的标签
    /// (「日出 The Dawn」「月食 The Weeping Woman」)靠它拆开。
    private static func scriptRuns(_ s: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var currentIsHan: Bool?
        for ch in s {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { runs.append(current) }
                current = ""; currentIsHan = nil
                continue
            }
            let isHan = ch.unicodeScalars.allSatisfy { CharacterSet.hanLike.contains($0) }
            if let was = currentIsHan, was != isHan {
                if !current.isEmpty { runs.append(current) }
                current = ""
            }
            currentIsHan = isHan
            current.append(ch)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func stripBracketsForHeaderMatch(_ s: String) -> String {
        var out = "", depth = 0
        for c in s {
            if c == "(" || c == "[" || c == "（" || c == "［" { depth += 1 }
            else if c == ")" || c == "]" || c == "）" || c == "］" { depth = max(0, depth - 1) }
            else if depth == 0 { out.append(c) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // 版权/免责声明行。跟职员表不是一回事:它**没有冒号**,上面所有以"角色+冒号"为形状的
    // 规则全都够不着,所以要单独一条。
    //
    // 2026-08-18 全库扫描实测:郭顶《飞行器的执行周期》整张专辑(10 首)的末行都是
    // 「未经著作权人许可不得翻录翻唱或使用」,一条都没被滤掉。
    //
    // 判据用"关键短语必须成对出现"而不是单个词:光有「未经」可能是真歌词(「未经允许的
    // 心动」),必须同时出现"未经/不得/版权/权利"这类法务词与"许可/翻录/翻唱/复制/授权/
    // 保留"里的一个,才认。英文那条同理只认成句的 All rights reserved 之类。
    private static let copyrightNoticePattern = try! NSRegularExpression(
        pattern: #"(未经[^。]{0,12}(许可|授权|同意))|(不得(翻录|翻唱|复制|转载|使用|下载))|(版权所有)|(保留(所有)?权利)|(all rights reserved)|(unauthor(i[sz]ed)? (copying|reproduction|duplication))"#,
        options: [.caseInsensitive]
    )

    /// 整行只有符号/标点的行(实测到过单独一行 `-`)。它不是歌词,也不是署名,就是分隔用的
    /// 排版残渣;逐行规则里没有任何一条够得着它。
    ///
    /// 判据故意写成"去掉标点/符号/空白之后什么都不剩",而不是枚举符号:这样破折号、省略号、
    /// 全角波浪线、下划线一次覆盖完。⚠️ 不能把它并进"整行括号注释"一起治 —— 那一类
    /// (`（開心啊）`)里有真歌词。
    /// 标点+符号+空白的并集,一次查询顶原来三次(CharacterSet.contains 每次都是一趟
    /// ObjC 桥接,strippingCreditLines 对每行每字符跑,合并是纯赚)。
    private static let symbolOnlyIgnorable: CharacterSet =
        CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)

    public static func isSymbolOnlyLine(_ text: String) -> Bool {
        // 单遍 + 早退:出现任何"真内容"字符立刻 false(绝大多数歌词行第一个字符就退出),
        // 不再 filter 物化一个数组。语义与旧实现逐位一致:旧的 `trimmed(.whitespaces)
        // 非空` ⟺ 存在不属于 .whitespaces 的字符(注意 .whitespaces 不含换行,与
        // ignorable 里的 .whitespacesAndNewlines 刻意不同,这是旧行为,别"顺手统一")。
        var sawNonWhitespace = false
        for scalar in text.unicodeScalars {
            if !symbolOnlyIgnorable.contains(scalar) { return false }
            if !sawNonWhitespace, !CharacterSet.whitespaces.contains(scalar) {
                sawNonWhitespace = true
            }
        }
        return sawNonWhitespace
    }

    /// 版权/免责声明行——见 copyrightNoticePattern 上的注释。
    public static func matchesCopyrightNotice(_ text: String) -> Bool {
        copyrightNoticePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
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

    /// 冒号右侧**绝不会出现在人名/团名里**的字:虚词、代词、否定、语气词。
    ///
    /// 这是 matchesNameListCreditShape 的精度来源,也是它跟已撤销的那次"按位置扩展署名块"
    /// (见本文件末尾那段【已撤销】)最本质的区别:那次放宽的是**位置**,形状照旧只看
    /// "短汉字标签 + 冒号",于是「他说：我不走」当场被吃掉;这次收紧的是**右侧内容** ——
    /// 「我不走」里有「我」「不」,「算了」里有「了」,一个都过不去,而「柳森」「赵雷/喜子」
    /// 「亚洲爱乐国际乐团」全是干净的名字。
    ///
    /// 只收这一类"名字里不可能有"的字,不做词表:角色名的取值空间堵不完(这是第十轮了),
    /// 但"人名里不会出现的虚词"是个稳定得多的小集合。
    private static let nonNameChars = Set("的了是不我你他她它们在也都就很没着过吗呢吧啊呀什么谁别把被让这那要会能又再却但而已经没有想")

    /// 冒号右侧的分隔符(一个角色多个人:「赵雷/喜子」「朵朵、天天」)。
    private static let nameListSeparators = CharacterSet(charactersIn: "/／、&＆,，")

    /// 「汉字标签 + 冒号 + 一串名字」这个形状 —— 职员表里最常见、也最难用词表堵完的那种。
    ///
    /// 2026-08-20 第十轮加。实测赵雷《成都》:头部 13 行职员表里 4 行漏网(钢琴/箱琴/笛子/
    /// 童声不在 creditRoleWords 里),而结构化规则被"整份过半"那道闸拦着(13 行署名 vs
    /// 三十多行正文,占不到半数)。往词表里继续加词是这个文件自己判定过"收敛不了"的路。
    ///
    /// 判据三条,缺一不可:
    ///  1. 标签侧:1~10 个汉字(允许「弦乐编写」这类组合、允许 `/` 之类分隔符),不是说话人标签;
    ///  2. 右侧:总长 ≤14,按 `/、&,` 切成 1~4 段,每段 2~8 个字符、只由汉字/拉丁字母组成;
    ///  3. 右侧一个 nonNameChars 都不含 —— 这条是精度的全部来源,见那个集合的注释。
    ///
    /// 启用门是"整份 ≥2 行命中"(跟 matchesBilingualCreditShape 同款):一整首歌里孤零零
    /// 一行长成这样,更可能是真歌词(「妈妈：晚安」),职员表从来是成片出现的。
    public static func matchesNameListCreditShape(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !rest.isEmpty, !speakerLabels.contains(String(label)) else { return false }
        // 标签:剔掉分隔符后必须全是汉字。上限 20(2026-08-20 第十一轮从 10 放宽 ——
        // 语料里「中音萨克斯/次中音萨克斯/上低音萨克斯：孟庆泽」剔掉分隔符是 16 个汉字)。
        let labelCore = String(label).components(separatedBy: creditLabelSeparators).joined()
        // 标签至少**两个**汉字(2026-08-11 轮补的护栏):单字标签正是说话人标签的地盘 ——
        // 「王：」「靖：」「钧：」「宏：」「男/女/合：」后面跟的是真歌词。而单字的角色词
        // (词/曲/编/唱/录/混/监/鼓)早就在关键词表里逐行生效,不靠这条免词表规则。
        //
        // 这条护栏是拿全库语料抓出来的:上一版放宽"英文名段最长 30 字"之后,
        // 「王：Hey hey ho ho」「靖：All yours baby」被当成署名删掉(英文短句里没有停用词,
        // 句子否决拦不住),而它们跟已在 must-keep 里的「合：Hey hey ho ho」是同一首歌的同一类行。
        guard (2...20).contains(labelCore.count),
              labelCore.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }
        // 右侧:不能像一句话。中文虚词/英文停用词/句末标点三条都在这一个函数里
        // (第十一轮起跟拉丁标签那条规则共用同一道否决,别再各写一份)。
        guard !latinCreditRestLooksLikeSentence(rest) else { return false }
        let segments = rest.components(separatedBy: nameListSeparators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 段数/长度上限按书写系统分档(第十一轮):中文名 2~8 字,英文名/团体名长得多
        // (`Michael Maganuco` 16、`SOYEON of (G)I-DLE` 18),原来一刀切 8 字 + 总长 14
        // 把整批英文署名挡在门外(语料里 56 行漏网大半是这个原因)。
        guard rest.count <= 60, (1...6).contains(segments.count) else { return false }
        return segments.allSatisfy { seg in
            let hasLatin = seg.unicodeScalars.contains { CharacterSet.letters.contains($0) && !$0.properties.isIdeographic }
            let limit = hasLatin ? 30 : 8
            return (2...limit).contains(seg.count)
                && seg.unicodeScalars.allSatisfy { u in
                    u.properties.isIdeographic || CharacterSet.alphanumerics.contains(u)
                        || " ()'’.-".unicodeScalars.contains(u)
                }
        }
    }

    /// 测试接缝:把一整份行文本过一遍署名行过滤,返回"这一行删不删"。
    ///
    /// 存在的理由:整份闸门(≥2 行、过半…)是这套规则的一半,只测单行匹配函数测不到它;
    /// 而从 `allLines()` 的输出反推"哪行被删了"会被另外两件事污染 —— 对唱标记会被
    /// LyricDuet 从正文里剥掉、一行多时间戳会被展开成多行,两者都让"文本对不上"却不是
    /// 过滤造成的(2026-08-20 拿全库 925 首做回归语料时踩到,误判出上百条"被误杀的真歌词")。
    /// 直接曝光这一层,语料统计和单测都拿它当唯一判据。
    public static func creditLineDropDecisions(
        _ texts: [String], trackTitle: String = "", trackArtist: String = ""
    ) -> [Bool] {
        strippingCreditLines(texts, trackTitle: trackTitle, trackArtist: trackArtist)
    }

    /// 过滤掉署名/职员表行。关键词表逐行生效(它枚举的都是明确的角色名,误判空间很小);
    /// 结构化规则只在整份被主导时才生效,见 shouldApplyStructuralCreditFilter。
    private static func strippingCreditLines(
        _ texts: [String], trackTitle: String = "", trackArtist: String = ""
    ) -> [Bool] {
        let useStructural = shouldApplyStructuralCreditFilter(texts)
        // 免词表的双语形状:整份 ≥2 行才认(理由见 matchesBilingualCreditShape)。
        let bilingualHits = texts.filter(matchesBilingualCreditShape).count
        let useBilingualShape = bilingualHits >= 2
        // 免词表的「标签 + 名字串」形状:同样整份 ≥2 行才认(理由见 matchesNameListCreditShape)。
        let nameListHits = texts.filter(matchesNameListCreditShape).count
        let useNameListShape = nameListHits >= 2
        let drop = texts.enumerated().map { i, text -> Bool in
            if useBilingualShape, matchesBilingualCreditShape(text) { return true }
            if useNameListShape, matchesNameListCreditShape(text) { return true }
            if matchesKeywordCreditPattern(text) { return true }
            if matchesLatinCreditPattern(text) { return true }
            // 双字角色词判定跟关键词表一样逐行生效(不受"整份主导"闸门管):双字词的
            // 误杀面足够小,见 creditRoleWords 上的注释。
            if matchesRoleWordCredit(text) { return true }
            // 纯英文、没有冒号的那类("Mixed by X at Y")。同样逐行生效:它要求整行以角色词
            // 开头且紧跟 by/at,误杀面很小。
            if matchesEnglishCredit(text) { return true }
            // 版权/免责声明("未经著作权人许可不得翻录翻唱或使用")——没有冒号,上面几条
            // 以"角色+冒号"为形状的规则一条都够不着,见 copyrightNoticePattern。
            if matchesCopyrightNotice(text) { return true }
            // 整行只有符号(单独一行 `-` 之类),见 isSymbolOnlyLine。
            if isSymbolOnlyLine(text) { return true }
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

    // 【已撤销】"从头尾向内扩展署名块"(借鉴 Lyricify 的 YRC 解析)2026-08-18 写过又删掉。
    //
    // 想法本身没错:噪声天然聚在头尾两段连续区。但 Lyricify 敢这么做是因为 **YRC 格式自带
    // credit 块标记**,它是在读标记、不是在猜;LRC 没有这个标记,只能拿"结构化形状"顶替,
    // 而那一步就是猜。实际后果:selftest 里那句紧跟在头部署名后面的真对白「他说：我不走」
    // 当场被吃掉 —— 形状 100% 命中,而它是这首歌的第一句歌词。
    //
    // 试过用"标签在整份里出现 <= 2 次"当护栏(对唱说话人标签必然反复出现),挡不住:一次性
    // 的对白同样只出现一次。而且这条规则在用户全库 508 首里**一条都没多滤到**,收益为零、
    // 风险实测存在,不值当。要重做的话,方向是**用时间戳**(署名块贴在 0~5 秒、真歌词有前奏
    // 间隔)而不是文本形状。


    public init() {}

    /// load 的 8 个入参的完整快照。它们是 load 输出的**全部**输入(load 不读引擎其它
    /// 状态),快照相等 ⇒ 解析/过滤/派生状态必然相等 ⇒ 可以整段跳过。
    private struct LoadFingerprint: Equatable {
        let lyrics, lyricsTr, lyricsRoma, lyricsYRC: String
        let preferWordLevel: Bool
        let trackTitle, trackArtist: String
        let romanizationScripts: RomanizationScripts
    }
    private var loadedFingerprint: LoadFingerprint?

    /// 返回值:内容真的变了吗(false = 入参与上次完全一致,整段跳过)。
    ///
    /// 早退闸(2026-08-20 性能审计):enrich 缓存是全库单文件,collector 给**别的歌**写盘
    /// (专辑预取/译文回填/重打分)也会 bump mtime,调用方(reloadCurrentLyrics)按 mtime
    /// 失效就会带着一字未变的入参反复调进来 —— 原来每次都全量重跑解析+署名过滤,还把
    /// romanizer/wordGroup/segments 三个按行缓存无条件清空,让 20Hz 路径和 allLines 再
    /// 全部重算一遍(日文逐字歌一次 10-40ms 主线程,正撞上 30Hz 填色渲染)。字符串 == 在
    /// 相等时要逐字节比,但几十 KB 也只是 µs 级,相对省下的毫秒级重算完全值得。
    /// 入参全等时**保住**全部缓存——输入相等则派生状态必然相等,比"清了也不会算错"更强。
    @discardableResult
    public func load(
        lyrics: String, lyricsTr: String, lyricsRoma: String, lyricsYRC: String,
        preferWordLevel: Bool = true, trackTitle: String = "", trackArtist: String = "",
        romanizationScripts: RomanizationScripts = .default
    ) -> Bool {
        let fingerprint = LoadFingerprint(
            lyrics: lyrics, lyricsTr: lyricsTr, lyricsRoma: lyricsRoma, lyricsYRC: lyricsYRC,
            preferWordLevel: preferWordLevel, trackTitle: trackTitle, trackArtist: trackArtist,
            romanizationScripts: romanizationScripts)
        if fingerprint == loadedFingerprint { return false }
        loadedFingerprint = fingerprint
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
        // 这份歌词自己带的 [offset:]。先看 LRC 正文,为 0 再看 YRC —— 酷狗那两首非零的
        // 实测里,.lrc 和 .yrc 两份文件头部都带着同一个值(KRC 母版转出来的两种形态),
        // 所以逐字模式同样要吃它;整行为空、只有逐字的条目也才有得可取。
        lrcOffsetMs = {
            let fromBase = LRCParser.parseOffsetMs(lyrics)
            return fromBase != 0 ? fromBase : LRCParser.parseOffsetMs(lyricsYRC)
        }()
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
        // 罗马音该不该对这首歌生效、以及汉字按哪种语言读 —— 都按"整首歌"粒度判一次
        // (不逐行判:极少数纯汉字的日文行会被局部误判成中文,见 Romanizer.romanize 的注释)。
        //
        // ⚠️ 判定样本是**过滤掉署名行之后的正文**,不是原始的 lyrics/lyricsYRC 字段。
        //
        // 2026-08-20 改。原来刻意扫原始字段、把署名行一并算进去,理由写的是"一整首歌只要
        // 出现过假名就足以确证是日文"。这条在**中文翻唱**上翻车得很彻底:中文歌的署名行里
        // 带日文原作者名是常态。实测泠鸢yousa《神的随波逐流》——整首歌唯一的假名就是
        // 「词：れるりり」「曲：れるりり」两行署名,正文全中文,于是 songScript 被判成日文、
        // 用户关着的"中文罗马音"开关根本没机会说话(闸看的是整首歌的语言),每一行中文都被
        // 标了东西:日语分词器给得出读音的行出日文读音(「化作无穷的力量」→
        // 「ka saku 无穷 teki rikiryou」,词典外的「无穷」原样留着),给不出的退到 ICU 音译
        // 出拼音(「但我听说这是我最为珍贵的一个」→「dàn wǒ tīngshuō…」)—— 同一首歌里
        // 两种形态混着出,正是用户报的"有些字有有些字没有"。
        //
        // 用正文判还有一层好处:署名行本来就不是"这首歌唱的是什么语言"的证据,它说的是
        // "谁写的"。真正的日文歌正文里假名遍地,判定结果不变。
        let contentSample = filteredBase.map(\.text).joined(separator: "\n")
        let contentWordSample = candidateWords
            .map { $0.words.map(\.text).joined() }
            .joined(separator: "\n")
        // 两份正文都空(压根没歌词)时退回原始字段:没有正文可判时,原始字段是唯一的信息。
        let scriptSample: String = {
            if !contentSample.isEmpty { return contentSample }
            if !contentWordSample.isEmpty { return contentWordSample }
            return lyrics.isEmpty ? lyricsYRC : lyrics
        }()
        songLooksJapanese = Romanizer.looksJapanese(contentSample)
            || Romanizer.looksJapanese(contentWordSample)
            || (contentSample.isEmpty && contentWordSample.isEmpty
                && (Romanizer.looksJapanese(lyrics) || Romanizer.looksJapanese(lyricsYRC)))
        // 整首歌的文字种类,给"按语言开关罗马音"用。粒度/样本跟上面完全一致。
        songScript = Romanizer.script(of: scriptSample)
        // 歌词源自带的假名标注(酷狗的 [kana:] 标签)。对不齐时 parse 返回 nil,读音自动
        // 退回形态分析 —— 见 KanaAnnotation 顶部注释里"半对半错比不标更糟"那段。
        kanaAnnotation = KanaAnnotation.parse(lrc: lyrics)
        // 换歌词内容清空——见 romanizationText() 的缓存注释,纯粹是内存卫生考虑(避免
        // 常年挂着的进程把每一句听过的歌词文本都无限期缓存下去),不清空也不会算错,
        // 只是没必要让它跨曲目继续增长。
        romanizerFallbackCache.removeAll()
        wordGroupCache.removeAll()
        segmentsCache.removeAll()
        // 换歌词内容后,按下标记忆化的"当前行/下一行"缓存必须一并失效 —— 新歌的同一个
        // 下标对应的是完全不同的内容,忘了这一步会把上一首歌的行当成这一首的返回出去。
        cachedActiveIdx = Int.min
        cachedActiveLine = nil
        cachedNextIdx = Int.min
        cachedNextText = nil
        cachedLeadIdx = Int.min
        cachedLeadLine = nil
        lastScanIdx = Int.min
        return true
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

    /// 说话人标签独立成行、冒号后没有真内容(如「合：」,YRC 里逐字数据把标签拆成
    /// 「合」+「：」两个字、共享同一个时间戳,见 usingWords 分支的注释)——2026-08-23
    /// 用户截图坐实的真 bug:这类标签行往往只有一百多毫秒,紧挨着后面那句真歌词(同一次
    /// "合唱开始"标注),`nearestText` 的 700ms 容差下两行都会独立地就近认领同一条翻译/
    /// 罗马音,视觉上连续两行显示同一句中文——真正拥有这条词条的是后面那句真歌词
    /// (时间戳几乎重合,天然更近),标签行本身在译文/罗马音源文件里根本没有对应词条。
    /// 复用 speakerLabels(职员表过滤那份豁免名单,同一个"合/男/女/…"集合),但这里用途
    /// 相反:那边判定"这行该不该被当署名删掉",这里判定"这行有没有资格去抢一条近邻词条"。
    private static func isBareSpeakerTag(_ text: String) -> Bool {
        guard let sep = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<sep].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: sep)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty && speakerLabels.contains(String(label))
    }

    /// nearestText(trLines,...) 的统一入口——四处直接调用点全部改走这里,理由见
    /// isBareSpeakerTag 的注释。
    private func translationText(timeMs: Int, plainText: String) -> String? {
        guard !Self.isBareSpeakerTag(plainText) else { return nil }
        return nearestText(trLines, timeMs)
    }

    private func nearestText(_ arr: [LyricLine], _ t: Int, tolerance: Int = 700) -> String? {
        // 数组按 timeMs 升序(LRCParser.parse 尾部 sorted),二分找插入点、只比较左右邻居 ——
        // 原来是全量线性扫,allLines 构建时被每行调两次,O(n×m)(2026-08-20 性能审计)。
        // 语义与旧线性扫逐位一致(selftest 对拍):旧写法 `d <= bestDiff` 是后见者胜 ——
        // 同距并列取时间戳更晚的那条,同时间戳重复取排在最后的那条。
        guard !arr.isEmpty else { return nil }
        // upperBound:第一个 timeMs > t 的下标。
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].timeMs > t { hi = mid } else { lo = mid + 1 }
        }
        var best: String?
        var bestDiff = tolerance
        if lo > 0 {
            // arr[lo-1] 已是"timeMs <= t 里最后一条"——同时间戳重复天然取最后 ✓。
            let d = t - arr[lo - 1].timeMs
            if d <= bestDiff { bestDiff = d; best = arr[lo - 1].text }
        }
        if lo < arr.count {
            let d = arr[lo].timeMs - t
            if d <= bestDiff {
                // 右侧同时间戳的重复也要取最后一条(旧扫描后见者胜)。
                var r = lo
                while r + 1 < arr.count, arr[r + 1].timeMs == arr[lo].timeMs { r += 1 }
                best = arr[r].text
            }
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
        // 同一个"标签行抢近邻词条"的坑,见 isBareSpeakerTag 的注释——罗马音跟译文共用
        // 同一套 nearestText+700ms 容差,症状对称。
        guard !Self.isBareSpeakerTag(plainText) else { return nil }
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
        // 日文行的整行读音从 segmentsCache 派生,与 wordGroups 共用同一次分词(2026-08-20
        // 性能审计:原来这里走 Romanizer.romanize→japaneseReading 自建一个 CFStringTokenizer,
        // 与 buildWordGroups 的 japaneseSegments 对同一行各分一遍词,日文歌 allLines 构建的
        // 分词次数直接翻倍)。两条路径的读音优先级完全一致(particleLatin > 假名标注 > 分词器
        // 转写 > 原文,尾部同走 mergeSokuon,见 Romanizer.readingFromSegments),selftest 有
        // 两者一致的断言。派生不出读音(整行拉丁/读音等于原文)时照 romanize 的原语义退到
        // ICU 音译。
        let result: String?
        if songLooksJapanese,
            Romanizer.looksJapanese(plainText) || Romanizer.containsHan(plainText),
            let reading = Romanizer.readingFromSegments(
                cachedJapaneseSegments(for: plainText), original: plainText)
        {
            result = reading
        } else {
            result = Romanizer.romanize(plainText, japanese: false)
        }
        romanizerFallbackCache[plainText] = result
        return result
    }

    // 行文本 → 分词片段。romanizationText(整行读音兜底)和 wordGroups(逐词罗马音)各要
    // 一份同一行的分词结果,原来各自跑一遍 CFStringTokenizer —— 这里按行缓存一份共用。
    // ⚠️ 两个消费方的启用门**不一样**(wordGroups 要求行内有假名,整行读音只要有汉字即可,
    // 见 buildWordGroups 的 guard),所以缓存必须放在两道门之前、由各自的门决定用不用,
    // 不能拿 wordGroupCache 的结果互相顶替 —— 纯汉字的日文行那样会把整行罗马音弄丢。
    private var segmentsCache: [String: [Romanizer.JapaneseSegment]] = [:]

    private func cachedJapaneseSegments(for line: String) -> [Romanizer.JapaneseSegment] {
        if let cached = segmentsCache[line] { return cached }
        let segs = Romanizer.japaneseSegments(
            line, marks: kanaAnnotation?.marks(forLine: line) ?? [])
        segmentsCache[line] = segs
        return segs
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
    /// `line` 由调用方传入(= words.map(\.text).joined()):activeLine/allLines 本来就要为
    /// romanizationText 拼这一份,这里复用,别再拼第二遍。
    private func wordGroups(for words: [SyncedLyricWord], line: String) -> [SyncedLyricWordGroup]? {
        guard !words.isEmpty else { return nil }
        // 缓存 key 必须带上时间身份(首词 startMs),不能只按行文本:词组里内嵌**绝对**
        // 时间戳,副歌重复句(同文本、不同时间)只按文本缓存会让第二次出现拿到第一次的
        // 时间轴 —— 逐词罗马音那一组从一开始就显示成已唱满(2026-08-20 对抗审查抓出的
        // 预存在 bug,非本轮引入;segmentsCache/romanizerFallbackCache 只存文本派生物、
        // 与时间无关,仍按纯文本共享)。
        let key = "\(words[0].startMs)|\(line)"
        if let cached = wordGroupCache[key] { return cached }
        // 逐词读音只对日文产出(buildWordGroups 里 guard japanese),所以它受同一道
        // 按语言开关的管辖 —— 关掉日文罗马音之后,逐字歌词下面也不该再标读音。
        let japanese = songLooksJapanese && romanizationAllowed
        // 分词结果与 romanizationText 共用 segmentsCache;门先于分词,门不开就不白分。
        let segments: [Romanizer.JapaneseSegment]? =
            (japanese && Romanizer.looksJapanese(line)) ? cachedJapaneseSegments(for: line) : nil
        let result = Self.buildWordGroups(
            words: words, line: line, japanese: japanese,
            marks: kanaAnnotation?.marks(forLine: line) ?? [],
            segments: segments)
        wordGroupCache[key] = result
        return result
    }

    // nonisolated static:纯函数,不碰引擎自身状态,selftest 直接覆盖。
    public static func buildWordGroups(
        words: [SyncedLyricWord], line: String, japanese: Bool,
        marks: [KanaAnnotation.Mark] = [],
        segments: [Romanizer.JapaneseSegment]? = nil
    ) -> [SyncedLyricWordGroup]? {
        // 跟 romanizationText 同一道门:含汉字但整首歌看着不像日文时不敢标读音,那多半是
        // 中文歌,标出来会是拼音、不是用户要的东西。
        guard japanese, Romanizer.looksJapanese(line) else { return nil }
        // segments 非 nil 时是调用方(引擎的 segmentsCache)预分好的同一行结果,别再分一遍。
        let segs = segments ?? Romanizer.japaneseSegments(line, marks: marks)
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

    // ---- 20Hz 热路径的两级省功(2026-08-19 性能审计落地) --------------------------
    //
    // ① 定位扫描提前 break:baseLines/wordLines 都按 timeMs 升序(LRCParser/YRCParser
    //    解析时排序),越过 posMs 之后剩余迭代必然无效,原来的 `for … where` 写法会把
    //    整个数组扫到尾。
    // ② 构建结果按行下标记忆化:activeLine 每次调用都全量重建 SyncedLyricLine(词数组
    //    map、两次整行字符串拼接、罗马音/译文各一次最近邻扫描),而 fastTick 以 20Hz 调它,
    //    换行几秒才发生一次 —— 约 99% 的 tick 构建完即被调用方的 != 比较丢弃。下标没变
    //    直接返回上一次的同一个实例,构建和深比较(String/Array 共享存储走同一性快路径)
    //    一起塌缩掉。缓存只在 load()(换歌词内容)时失效;offsetMs 只影响"落在哪一行"
    //    的判定、不影响某一行的内容,所以偏移变化天然安全 —— 下标照新偏移重算,内容命中
    //    同一下标就还是同一份。
    private var cachedActiveIdx = Int.min
    private var cachedActiveLine: SyncedLyricLine?
    private var cachedNextIdx = Int.min
    private var cachedNextText: String?
    // 单行展示面的「领先行」独立占一个槽(2026-08-23):它跟 activeIdx 只在提前量窗口里
    // 不同(下标差 1),共用一个槽的话那段时间里两个下标每 tick 互相踢缓存,上面那段注释
    // 描述的塌缩("约 99% 的 tick 构建完即被丢弃")就整个失效 —— 而 lineAt 的构建正是
    // tailClamped + wordGroups + 两次最近邻扫描,20Hz 跑两遍是这个仓库栽过的那类
    // 热路径回归。失效点跟上面两组一致(load() 里一起清)。
    private var cachedLeadIdx = Int.min
    private var cachedLeadLine: SyncedLyricLine?

    /// 最后一个 timeMs <= posMs 的行下标,没有则 -1。数组必须按 timeMs 升序。
    private static func lastIndex(atOrBefore posMs: Int, times: (Int) -> Int, count: Int) -> Int {
        var idx = -1
        for i in 0 ..< count {
            if times(i) > posMs { break }
            idx = i
        }
        return idx
    }

    // ③(2026-08-20 审计追加)定位扫描的单调窗口记忆化:播放位置单调推进,~99% 的 tick
    //   落在上次命中行的 [timeMs[idx], timeMs[idx+1]) 窗口内,O(1) 验证即返回,不必每次
    //   从下标 0 重扫。验证失败(seek/换行/offset 变化)回退全量扫,语义不变。Int.min =
    //   无效(load() 时与 cachedActiveIdx 同点失效)。
    private var lastScanIdx = Int.min

    private func activeIndexCorrected(_ posMs: Int) -> Int {
        let count = usingWords ? wordLines.count : baseLines.count
        let time: (Int) -> Int =
            usingWords ? { self.wordLines[$0].timeMs } : { self.baseLines[$0].timeMs }
        if lastScanIdx >= -1, lastScanIdx < count {
            // 窗口两端:idx == -1 表示"还没到第一行"(下界天然成立);idx == count-1 表示
            // 最后一行(上界天然成立)。
            let lowOK = lastScanIdx == -1 || time(lastScanIdx) <= posMs
            let highOK = lastScanIdx + 1 >= count || time(lastScanIdx + 1) > posMs
            if lowOK && highOK { return lastScanIdx }
        }
        let idx = Self.lastIndex(atOrBefore: posMs, times: time, count: count)
        lastScanIdx = idx
        return idx
    }

    public func activeLine(atMs rawPosMs: Int) -> SyncedLyricLine? {
        lineAt(activeIndexCorrected(rawPosMs + effectiveOffsetMs))
    }

    /// activeLine 的按下标本体(记忆化缓存所在)。tickQuery 与 activeLine 共用。
    private func lineAt(_ idx: Int) -> SyncedLyricLine? {
        if idx == cachedActiveIdx { return cachedActiveLine }
        let line = buildLine(idx)
        cachedActiveIdx = idx
        cachedActiveLine = line
        return line
    }

    /// 单行展示面的「领先行」取词(见 CompactLyricLead)。绝大多数时刻它等于 activeIdx,
    /// 直接吃 active 那个槽;只有在提前量窗口里才落到自己的槽上。
    private func leadLineAt(_ idx: Int) -> SyncedLyricLine? {
        if idx == cachedActiveIdx { return cachedActiveLine }
        if idx == cachedLeadIdx { return cachedLeadLine }
        let line = buildLine(idx)
        cachedLeadIdx = idx
        cachedLeadLine = line
        return line
    }

    /// lineAt / leadLineAt 共用的构建本体(不碰缓存)。
    private func buildLine(_ idx: Int) -> SyncedLyricLine? {
        let line: SyncedLyricLine?
        if idx < 0 {
            line = nil
        } else if usingWords {
            let ln = wordLines[idx]
            // 末字的填色终点压到"换行前一点",理由见 KaraokeFill.tailClamped(实测约四成的行
            // 会出现"最后一点不走完就换行")。必须在 wordGroups 之前做 —— 逐词罗马音那一组
            // 的填色跟着同一份时长走。
            let words = KaraokeFill.tailClamped(
                ln.words.map { w in
                    SyncedLyricWord(text: w.text, startMs: w.startMs, durationMs: w.durationMs)
                },
                nextLineStartMs: idx + 1 < wordLines.count ? wordLines[idx + 1].timeMs : nil)
            // 整行文本只拼一次:romanizationText / wordGroups / plainText 三个消费方共用。
            let joined = words.map(\.text).joined()
            line = SyncedLyricLine(
                romanization: romanizationText(timeMs: ln.timeMs, plainText: joined),
                translation: translationText(timeMs: ln.timeMs, plainText: joined),
                mainText: nil,
                words: words,
                wordGroups: wordGroups(for: words, line: joined),
                side: wordSides.indices.contains(idx) ? wordSides[idx] : nil,
                plainText: joined
            )
        } else {
            let ln = baseLines[idx]
            line = SyncedLyricLine(
                romanization: romanizationText(timeMs: ln.timeMs, plainText: ln.text),
                translation: translationText(timeMs: ln.timeMs, plainText: ln.text),
                mainText: ln.text,
                words: nil,
                wordGroups: nil,
                side: baseSides.indices.contains(idx) ? baseSides[idx] : nil,
                plainText: ln.text
            )
        }
        return line
    }

    /// fastTick(20Hz)的打包查询:当前行/下一句预览/行下标/间奏下标要的是同一个 posMs 的
    /// 同一次定位,原来四个入口各自独立调 activeIndexCorrected 从头扫一遍(2026-08-20
    /// 审计:同一 tick 内 3/4 是纯重复)。这里下标只算一次,几个值一起返回。
    public struct TickResolution {
        public let index: Int?
        /// 歌词窗口的**滚动锚**下标 —— AM 的滚动先于染色(2026-08-22 用户对拍):一句
        /// 唱完、下一句还没开始的空档里,页面已经滚到下一句的位置,只是还没给它染色。
        /// 染色/加粗/虚化仍看 index,滚动看这个;非空档时刻两者相等。语义见
        /// scrollLeadIndex(activeIdx:posMs:)。
        public let scrollIndex: Int?
        public let line: SyncedLyricLine?
        /// 单行展示面(灵动岛 / 菜单栏)该显示的那一行 —— 跟 line 的区别是**唱完就切走**:
        /// 本行唱完之后它指向下一句(提前量,给跟唱用),长间奏中段则是 nil。规则与两条
        /// 保守边界见 CompactLyricLead。
        ///
        /// ⚠️ 跟 scrollIndex 不是一回事,别合并:那个服务多行列表(间奏里有「•••」可停靠,
        /// 所以窗口结束前才领先),这个服务单行(没地方停,已经唱完的句子不该继续占着)。
        public let compactLine: SyncedLyricLine?
        /// compactLine == nil 的两种成因要分开:这个为 true 表示"本行唱完了、下一句还早"
        /// (调用方画 ♪);为 false 表示压根还没有可显示的行(还没到第一句/没歌词),那种
        /// 空态由调用方各自既有的分支接管(搜索中/无歌词/广告…)。
        public let compactPlaceholder: Bool
        /// compactLine **总共会显示多久**(毫秒),nil = 算不出来。菜单栏跑马灯拿它配速 ——
        /// 显示窗口跟 currentLineDwellSeconds 那套不一样了,用错会让长句在长间奏前滚不完
        /// (比改动前更糟)。算法与理由见 CompactLyricLead.displayDurationMs。
        public let compactDwellMs: Int?
        public let nextText: String?
        public let gapIndex: Int?
    }

    public func tickQuery(atMs rawPosMs: Int) -> TickResolution {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        let gap: Int?
        if let window = gapWindow(after: idx), posMs >= window.start, posMs < window.end {
            gap = idx
        } else {
            gap = nil
        }
        // 单行展示面的取词:跟上面的 index/scrollIndex 共用同一次定位,不再扫一遍数组。
        let compact = CompactLyricLead.resolve(
            activeIdx: idx, posMs: posMs,
            lineEndMs: gapLineEndMs(at: idx),
            nextStartMs: gapLineStartMs(at: idx + 1))
        let compactLine: SyncedLyricLine?
        let compactPlaceholder: Bool
        let compactDwellMs: Int?
        switch compact {
        case .line(let i):
            compactLine = leadLineAt(i)
            compactPlaceholder = false
            // fallbackEndMs 传 nil:引擎不知道曲目时长。最后一句因此算不出 dwell,
            // 由 PlaybackCoordinator.compactDwellSeconds 退回既有公式(那边有曲目时长)。
            compactDwellMs = gapLineStartMs(at: i).flatMap { start in
                CompactLyricLead.displayDurationMs(
                    prevLineEndMs: gapLineEndMs(at: i - 1),
                    startMs: start,
                    lineEndMs: gapLineEndMs(at: i),
                    nextStartMs: gapLineStartMs(at: i + 1),
                    fallbackEndMs: nil)
            }
        case .placeholder:
            compactLine = nil
            compactPlaceholder = true
            compactDwellMs = nil
        }
        return TickResolution(
            index: idx >= 0 ? idx : nil,
            scrollIndex: scrollLeadIndex(activeIdx: idx, posMs: posMs),
            line: lineAt(idx),
            compactLine: compactLine,
            compactPlaceholder: compactPlaceholder,
            compactDwellMs: compactDwellMs,
            nextText: nextTextAt(idx + 1),
            gapIndex: gap)
    }

    /// 滚动锚下标(TickResolution.scrollIndex 的本体):空档里指向下一行,其余时刻等于
    /// activeIdx。三种空档:
    /// ① 短间隙(没有「•••」间奏点):逐字歌词知道这一行唱到几点(最后一个词的结束),
    ///    唱完即滚。行级 LRC 不知道一行唱多久,不抢跑 —— 维持"下一句开始才滚"的既有行为。
    /// ② 长间奏(有「•••」):点亮期间滚动停在「•••」那排(由 gapIndex 驱动,这里锚
    ///    不动),窗口结束(下一句前 leadMs)才指向下一句 —— AM 的点先收起、下一句移到
    ///    常规锚位、开唱时只染色不再滚动。
    /// ③ 前奏(-1 号间奏点):同②,倒计时结束先把第一句从开场位(0.52)挪到常规锚位。
    ///    没有 -1 号间奏点的歌(前奏 <5s)不抢跑,第一句开始时正常滚。
    private func scrollLeadIndex(activeIdx idx: Int, posMs: Int) -> Int? {
        if idx < 0 {
            if let w = gapWindow(after: -1), posMs >= w.end, gapLineCount > 0 { return 0 }
            return nil
        }
        guard idx + 1 < gapLineCount else { return idx }
        if let w = gapWindow(after: idx) {
            return posMs >= w.end ? idx + 1 : idx
        }
        if let end = gapLineEndMs(at: idx), posMs >= end { return idx + 1 }
        return idx
    }

    // 双行显示用:当前行的下一行纯文本预览,不需要逐字高亮细节(还没轮到它,不用算填色)。
    // 故意不要求 idx>=0——播放位置还没到第一句(idx=-1)时 nextIdx 自然等于 0,直接把
    // 第一句真歌词当预览提前露出来。署名行过滤上线后这个"还没到第一句"的窗口会变得
    // 更常见(署名行被剔除、真歌词往往要再等几十秒才开始),这时候提前露出第一句歌词
    // 比干等着更有用。
    public func upcomingLineText(afterMs rawPosMs: Int) -> String? {
        nextTextAt(activeIndexCorrected(rawPosMs + effectiveOffsetMs) + 1)
    }

    /// upcomingLineText 的按下标本体(记忆化缓存所在)。tickQuery 与 upcomingLineText 共用。
    private func nextTextAt(_ nextIdx: Int) -> String? {
        // 按下一行下标记忆化,理由同 activeLine 的缓存注释 —— 逐字路径的 map+join 拼接
        // 原来每个 tick 都重做一遍,拼的却是几十秒不变的同一句。
        if nextIdx == cachedNextIdx { return cachedNextText }
        let text: String?
        if usingWords {
            text = nextIdx < wordLines.count ? wordLines[nextIdx].words.map(\.text).joined() : nil
        } else {
            text = nextIdx < baseLines.count ? baseLines[nextIdx].text : nil
        }
        cachedNextIdx = nextIdx
        cachedNextText = text
        return text
    }

    // "歌词窗口"用:整首歌全部行一次性拿出来,构造方式跟 activeLine(atMs:) 完全一致
    // (同一个 nearestText 贴罗马音/译文),只是对每一行都做一次,而不是只对查询命中的
    // 那一行做。idPrefix 由调用方传入(通常是当前曲目的标识,比如 currentOffsetKey),
    // 拼进每个 id 里——见 LyricsWindowLine 的类型注释,这是为了让 SwiftUI 在换歌时做
    // 一次干净的整体替换,而不是逐行"变形"旧内容。
    public func allLines(idPrefix: String) -> [LyricsWindowLine] {
        if usingWords {
            return wordLines.enumerated().map { i, ln in
                // 跟 activeLine 走同一份末字压缩 —— 歌词窗口和悬浮窗必须看到同一条时间轴,
                // 否则同一句在两处填色进度不一样。
                let words = KaraokeFill.tailClamped(
                    ln.words.map { w in
                        SyncedLyricWord(text: w.text, startMs: w.startMs, durationMs: w.durationMs)
                    },
                    nextLineStartMs: i + 1 < self.wordLines.count ? self.wordLines[i + 1].timeMs : nil)
                let joined = words.map(\.text).joined()
                let line = SyncedLyricLine(
                    romanization: romanizationText(timeMs: ln.timeMs, plainText: joined),
                    translation: translationText(timeMs: ln.timeMs, plainText: joined),
                    mainText: nil,
                    words: words,
                    wordGroups: wordGroups(for: words, line: joined),
                    side: self.wordSides.indices.contains(i) ? self.wordSides[i] : nil,
                    plainText: joined
                )
                return LyricsWindowLine(id: "\(idPrefix)#\(i)", timeMs: ln.timeMs, line: line)
            }
        }
        return baseLines.enumerated().map { i, ln in
            let line = SyncedLyricLine(
                romanization: romanizationText(timeMs: ln.timeMs, plainText: ln.text),
                translation: translationText(timeMs: ln.timeMs, plainText: ln.text),
                mainText: ln.text,
                words: nil,
                wordGroups: nil,
                side: self.baseSides.indices.contains(i) ? self.baseSides[i] : nil,
                plainText: ln.text
            )
            return LyricsWindowLine(id: "\(idPrefix)#\(i)", timeMs: ln.timeMs, line: line)
        }
    }

    // "歌词窗口"用:跟 activeLine(atMs:) 扫的是同一个数组、加同一个 offsetMs 校正,
    // 只是返回下标而不是内容——故意不用"拿 activeLine 的内容去 allLines() 里找相同
    // 内容的下标"这种实现,副歌重复句会有多个内容相同的行,内容匹配选不准具体是哪一次
    // 出现,必须像这里一样直接按时间戳扫下标。
    public func activeLineIndex(atMs rawPosMs: Int) -> Int? {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        return idx >= 0 ? idx : nil
    }

    // ---- 间奏点(2026-08-19,歌词窗口的 Apple Music 式「•••」) --------------------

    /// 间奏判定参数。逐字歌词知道每一行唱到几点(最后一个词的结束),真实静默 ≥ minGapMs
    /// 才算间奏;行级 LRC 不知道一行唱多久,只能保守地要求两句**起点**差 ≥
    /// minPlainIntervalMs(一句歌词很少唱超过 15 秒),并假定前一句最多唱了间隔的三分之一
    /// (封顶 8 秒)。前奏单独一档:第一句开始得晚于 minIntroMs 才配一个间奏点。
    /// 窗口两端留余量:词尾后 tailMarginMs 才亮(别跟收尾的余音抢),下一句前 leadMs
    /// 熄灭(给滚动/换行让路)。
    public enum GapRule {
        public static let minGapMs = 6000
        public static let minIntroMs = 5000
        public static let minPlainIntervalMs = 15000
        public static let tailMarginMs = 1200
        public static let leadMs = 800
        public static let plainAssumedSingingCapMs = 8000
    }

    private var gapLineCount: Int { usingWords ? wordLines.count : baseLines.count }

    private func gapLineStartMs(at index: Int) -> Int? {
        if usingWords {
            return wordLines.indices.contains(index) ? wordLines[index].timeMs : nil
        }
        return baseLines.indices.contains(index) ? baseLines[index].timeMs : nil
    }

    /// 这一行唱完的时间:逐字取最后一个词的结束;行级不可知,给 nil。
    private func gapLineEndMs(at index: Int) -> Int? {
        guard usingWords, wordLines.indices.contains(index),
              let last = wordLines[index].words.last else { return nil }
        return last.startMs + last.durationMs
    }

    /// 第 index 行之后(index == -1 为前奏)的间奏活跃窗口。nil = 这里没有值得标记的间奏。
    public func gapWindow(after index: Int) -> (start: Int, end: Int)? {
        if index == -1 {
            guard let first = gapLineStartMs(at: 0), first >= GapRule.minIntroMs else { return nil }
            return (0, first - GapRule.leadMs)
        }
        guard let start = gapLineStartMs(at: index),
              let next = gapLineStartMs(at: index + 1) else { return nil }
        if let end = gapLineEndMs(at: index) {
            guard next - end >= GapRule.minGapMs else { return nil }
            return (end + GapRule.tailMarginMs, next - GapRule.leadMs)
        }
        guard next - start >= GapRule.minPlainIntervalMs else { return nil }
        let assumedEnd = start + min((next - start) / 3, GapRule.plainAssumedSingingCapMs)
        return (assumedEnd, next - GapRule.leadMs)
    }

    /// 整首歌全部间奏点(含前奏的 -1)。纯由时间轴决定,换歌/换词源后重算一次即可。
    public func gapMarkers() -> [LyricsGapMarker] {
        var out: [LyricsGapMarker] = []
        if let w = gapWindow(after: -1) {
            out.append(LyricsGapMarker(index: -1, startMs: w.start, endMs: w.end))
        }
        for i in 0 ..< max(0, gapLineCount - 1) {
            if let w = gapWindow(after: i) {
                out.append(LyricsGapMarker(index: i, startMs: w.start, endMs: w.end))
            }
        }
        return out
    }

    /// 此刻在不在某个间奏里(返回间奏点的 index,-1 = 前奏)。offsetMs 校正跟
    /// activeLine 同一处、同一方向 —— 这里已经加过,内部不能再调 activeLineIndex。
    public func activeGapIndex(atMs rawPosMs: Int) -> Int? {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        guard let window = gapWindow(after: idx) else { return nil }
        return (posMs >= window.start && posMs < window.end) ? idx : nil
    }
}
