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
    // 从计算属性改成存储属性:引擎构造行时本来就为 romanizationText 拼过同一份
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
        // 靠 nil 才能显示占位音符(对抗审查抓出的口径差)。
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

    /// 这一行的**整行**形态:逐字数据抹掉、正文落到 `mainText`,译文 / 罗马音 / 声部原样保留。
    ///
    /// 给"这个展示面关了卡拉OK效果"用(悬浮歌词 / 灵动岛 / 菜单栏各有一颗开关):
    /// 展示面在自己的消费点把行压成这个形态,后面的渲染就自然走它本来就有的"这首歌没有逐字
    /// 数据"那条路 —— 不用在每个渲染分支里再判一次开关。
    ///
    /// `wordGroups` 必须一起清:它是按读音分组的逐字词,悬浮歌词的逐词罗马音标注拿它里面的
    /// `words` 逐个做卡拉OK填色(`wordText(_:atMs:)`);只清 `words` 不清它,填色会从另一条路
    /// 漏回来。罗马音退回整行的 `romanization`。
    ///
    /// 本来就是整行的行原样返回(`==` 语义不变,`removeDuplicates` 照常工作)。
    public var lineLevel: SyncedLyricLine {
        guard words != nil || wordGroups != nil else { return self }
        return SyncedLyricLine(
            romanization: romanization, translation: translation,
            mainText: mainText ?? plainText, words: nil, wordGroups: nil,
            side: side, plainText: plainText)
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

/// 歌词间奏点(歌词窗口的 Apple Music 式「•••」呼吸圆点)。
/// index == -1 表示前奏(第一句之前),其余表示"这一行唱完之后"。start/end 是这段间奏
/// 的活跃窗口,**歌词原始时间轴**(offsetMs 校正前)—— 视图侧比较时要用
/// 外推位置 + currentLyricsOffsetMs,跟逐字填色同一套时间基准。
public struct LyricsGapMarker: Equatable, Identifiable {
    public let index: Int
    public let startMs: Int
    public let endMs: Int
    public var id: Int { index }
}

/// 一段间奏窗口的边界,不带 index——悬浮歌词兜底(`rawActiveGapWindow`)只需要知道
/// "此刻这段窗口从哪到哪",不需要 `LyricsGapMarker` 那个用来在歌词窗口列表里定位插入点的 index。
public struct LyricsGapWindow: Equatable {
    public let startMs: Int
    public let endMs: Int
    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }

    /// 这段窗口够不够格算「间奏」—— 歌词窗口的门槛版标记(`gapMarkers()`)里有没有同一段。
    /// 两版窗口的起点是同一个式子(`gapWindow(after:applyMinimumDuration:)`,只有终点差一段
    /// 熄灭余量),按起点认。悬浮歌词拿它决定句间空档要不要把上一句换成「•••」。
    public func isMarked(in markers: [LyricsGapMarker]) -> Bool {
        markers.contains { $0.startMs == startMs }
    }
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

    /// 内容匹配用的"歌词原文 → 译文/罗马音"字典。见 load() 里构建它
    /// 那一段的注释——解决的是逐字(YRC)算出来的行时间戳跟服务端整行 LRC(译文/罗马音
    /// 就是照这份 LRC 的时间戳生成的)对同一句词标的时间不一致、超出 nearestText 700ms
    /// 容差导致查不到译文的问题。查找时按内容优先,查不到才退回 nearestText 时间最近邻。
    private var trTextByPlainText: [String: String] = [:]
    private var romaTextByPlainText: [String: String] = [:]

    /// 内容匹配 key:去掉**全部**空白(不止两端),含 NBSP(U+00A0)等 Unicode 空白变体——
    /// 不是只用 `.trimmingCharacters(in: .whitespaces)`。各家源在词组之间垫的空白字符
    /// 不统一(有的用 NBSP 标记换气停顿,有的用普通空格),`trimmingCharacters` 只削两端、
    /// 削不掉中间的差异,这里比较的是"是不是同一句唱词的内容",字词之间要不要留白纯粹是
    /// 排版习惯,不是内容的一部分。
    ///
    /// 再放宽到**只留字母和数字、统一小写**:标点符号(全角/半角括号等)同样是各家源的
    /// 排版细节,跟空白一样不该参与内容比对——collector 侧配对 LRC与YRC 行的
    /// normTimelineText 同样只留字母数字,这里跟它同一口径。大小写也折掉(同一句词一边
    /// "U're" 一边 "u're" 不该算两句)。只留字母数字后两句本来只差标点的词会撞同一个
    /// 键——那两句的译文本来就该一样,`uniquingKeysWith` 取后者,不是问题。
    private static func contentMatchKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

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
    // 关键词可以**连写**(那个 `+`):「词曲：」这类两个角色词紧挨着也要认得出来,
    // 不能要求关键词紧跟冒号。下面那条结构化规则(shouldApplyStructuralCreditFilter)
    // 只在整份被职员表主导时才启用,单独几行署名的歌需要这条兜底。
    // 连写不会扩大误杀面:表里全是明确的角色名,连着出现只会更像署名行,不会更像歌词。
    //
    // 角色词之间允许夹**连接词**(和/与/及/、// /&),并允许"所有/全部"这类前缀量词。
    // 结构分两段:第一个角色词打底,后面每一节是"可选连接词 + 角色词",空白也当分隔
    // ("词 曲 编："仍然命中)。连接词后面必须再跟角色词才算数——"唱和："这种词后面没有
    // 角色词,回退到"唱"+冒号也对不上,不误杀。
    private static let creditLinePattern = try! NSRegularExpression(
        pattern: #"^(所有|全部|中文|英文|韩文|日文|粤语|中|英|韩|日)?\s*(唱片公司|发行公司|出品公司|专辑|翻译|作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|P\s*-\s*Line|C\s*-\s*Line|℗|©|lyrics|music|composed|produced|arranged|mixed|mastered|written)(\s*(和|与|及|、|/|&|＆)?\s*(唱片公司|发行公司|出品公司|专辑|翻译|作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|lyrics|music|composed|produced|arranged|mixed|mastered|written))*\s*(by\s*)?[:：]"#,
        options: [.caseInsensitive]
    )

    // genericHanCreditLinePattern 是上面那张关键词表的**结构化**补充,跟 collector 侧的
    // genericHanCreditLineRe(match.go)是同一条规则、同一个理由——角色名的取值空间
    // (指挥/混音师/贝斯/中提琴/大提琴/母带工程师/和声编写……)枚举法堵不完,这条规则
    // 认的是"短汉字标签+冒号+内容"这个形状,不逐词维护。
    //
    // 改成认"短汉字标签 + 冒号 + 内容"这个**形状**:1~8 个汉字紧跟冒号,大概率就是
    // "角色:姓名"的职员表格式,真正在唱的歌词句子极少长这个样子。
    //
    // 三个刻意的收窄,都是为了不误杀真歌词:
    // ① 只认汉字标签(不含数字/字母),避免误伤"1、2、3:"这类编号或英文场景标签;
    // ② 上限 8 个汉字,再长就不像标签了;
    // ③ 冒号后必须有非空白内容(\S),纯粹以冒号结尾的句子(真歌词里的语气停顿)不算。
    //
    // 不要照抄别人那种 `^.{1,20}\s*[:：]\s*.+` 的宽松写法:`.` 能匹配任何字符,会把
    // "他说:我不走"这类正常带冒号的歌词整行吃掉。
    // 这条改成**双字角色词包含判定**:标签侧(冒号前)是 1~8 个纯汉字、且包含任何一个
    // 双字角色词,就是职员表行 —— "数字编辑"包含"编辑"、"母带处理"包含"母带"和"处理",
    // "XX编辑/XX制作/XX工程"这类组合词因此自动覆盖,不用逐词维护表。
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
        // 刻意**不收**「合唱」——对唱歌词里「合唱：」是分声部标记,后面跟的是真歌词,
        // 收了就是误杀(人名后接冒号也可能是对唱标签,不是署名,道理相同)。
        "演唱", "原唱", "翻唱",
        // 日文源的头部标注(収録/主題歌/片頭曲/片尾曲/挿入歌等)。本地缓存目前几乎全是
        // 华语、零样本命中,收这些词风险很低:它们做不了歌词句子,而且这条规则本来就要求
        // "标签全是汉字+紧跟冒号"。
        //
        // 只收**汉字**形态。假名(アニメ)进不来:matchesRoleWordCredit 要求标签
        // isIdeographic,片假名不满足。日文里更常见的「TVアニメ「XXX」オープニングテーマ」
        // 这种**不带冒号**的整行标注这里**没有覆盖**,本地零样本,不凭空猜。
        "収録", "収録", "主題", "片頭", "片尾", "挿入",
        // 简体对应写法(简繁互认由下面 matchesRoleWordCredit 里的 HanScript 兜,但
        // 「収」「挿」是日文新字体、不在简繁对照表里,仍要显式列)。
        "收录", "主题", "片头", "插入",
        // 同类工具的过滤表也收了这几个,同样是"带冒号才算"的安全形态。
        "歌手", "歌曲", "歌词",
        // 乐器/角色类标签。表里已有吉他/贝斯/键盘/弦乐/和声,这里补齐其余常见乐器——
        // 逐词枚举收敛不了,真正的通用解法是下面 matchesNameListCreditShape,这里
        // 只兜"整首只有一行署名"的场合(那条规则要求整份 ≥2 行才启用)。
        "钢琴", "箱琴", "笛子", "童声", "口琴", "二胡", "琵琶", "古筝", "长笛", "提琴",
        "唢呐", "手鼓", "打击", "合成", "采样", "编写", "小号", "萨克",
        // 刻意**不收**「主唱」「合作」:它们更可能被用作对唱/口白的说话人标签,
        // 交给 matchesNameListCreditShape 的整份闸去收更安全,单行关键词匹配容易误杀。
        "竖琴", "长号", "副唱", "和音", "三和",
        // 提醒「著作」不收窄成别的判据的话会误杀真歌词(方大同《放不过自己》「自我执著作怪」
        // 这句里含「著作」二字但没有冒号)——matchesRoleWordCredit 要求标签后必须紧跟冒号,
        // 所以收这个词不会误伤它,这条真歌词已经进 selftest 当反向哨兵钉着。
        "著作", "推广",
        // 「指导」「总监」「策划」「导演」这类词带冒号时几乎全是署名,不带冒号的多是真歌词
        // (如「进入你梦里 指导你演戏」)——正好被"标签后必须紧跟冒号"这道门分开。
        // 刻意**不收**「顾问」:它在本仓语料里只在真歌词中出现过(「当你的时尚顾问」),
        // 虽然没有冒号时进不了这条规则的门,但表里不该躺着一个只见于真歌词的词。
        // 这张表有**两个**消费点,加词时两边都要想:除了下面 matchesRoleWordCredit 的"标签含
        // 词 + 冒号"之外,englishCreditPattern 也把整张表 join 进正则当**可选中文前缀**
        // (「编曲 Arrangement by …」那条)——加「导演」同时也让「导演 Directed by X」这类
        // 走英文规则。所以"零误杀"必须用整份入口 creditLineDropDecisions 差分来证,不能只看冒号规则。
        // 全库差分时按 isNewline 切行——酷狗源里有 CRLF 数据,`split(separator: "\n")`
        // 会把整份当一行,验证加词零误杀时别用它切行。
        "指导", "总监", "策划", "导演",
    ]

    /// 标签里允许出现的分隔符——一个人身兼两职时标签会写成"录音师/录音室"、"作词/作曲"、
    /// "混音&母带",中间的符号让"标签全是汉字"这条判定直接失败。把它们剔掉再判,而不是
    /// 放宽成"允许任意非汉字"(那会把英文场景标签也放进来)。
    private static let creditLabelSeparators = CharacterSet(charactersIn: "/／、&＆·・和与及,，")

    /// 标签尾巴上那段**英文对照**里出现的角色名。
    ///
    /// 只在"汉字头 + 拉丁尾"的双语标签里当第二判据用(见 matchesRoleWordCredit):汉字头是
    /// 「曲」「词」「鼓」这种单字时,表里那些双字词一个都够不着,而把单字加进 creditRoleWords
    /// 会把真歌词里的对白吃掉(「他：我不走」那一类,已经踩过一次并回滚)。
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
        // 两道守卫,都是拿真实歌词库量出来的(42880 行):
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
    /// 为什么需要它:靠词表永远在打地鼠。用户先报「制作人 Producer」那一批,补了
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

    /// 标签独占一行的双语署名:「录音室 Recording Studio：」冒号后为空,值换到了下一行。
    ///
    /// 冒号后为空的行别处一律不认(真歌词里「我对你说：」是语气停顿),所以这里只认**双语标签、
    /// 且英文半边本身就是角色名**(`englishRoleNounPattern`)的那一种 —— 纯中文标签哪怕含角色词
    /// (「我的制作人说：」)也不认。紧跟的值那一行由 `looksLikeCreditValueLine` 判,在
    /// `strippingCreditLines` 里连带删。
    public static func matchesLabelOnlyBilingualCredit(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last, last == ":" || last == "：" else { return false }
        let label = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
        let (han, latin) = splitBilingualLabel(label)
        guard !latin.isEmpty else { return false }
        let core = han.components(separatedBy: creditLabelSeparators).joined()
        guard (1...10).contains(core.count),
              core.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }),
              !speakerLabels.contains(core)
        else { return false }
        let range = NSRange(latin.startIndex..., in: latin)
        return englishRoleNounPattern.firstMatch(in: latin, range: range) != nil
    }

    /// 紧跟在「标签独占一行」后面的那一行像不像它的值:自己没有冒号(否则它是下一条署名,归别的
    /// 规则),且带名单的分隔符或括号注解(`Retro Records Studio (BJ)/Barzilay Studio (LA)`)。
    /// 两样都没有的多半是真歌词 —— 只删标签行,不连带它。
    static func looksLikeCreditValueLine(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(":"), !t.contains("：") else { return false }
        return t.contains(where: { "/／、,，&＆(（".contains($0) })
    }

    public static func matchesRoleWordCredit(_ text: String) -> Bool {
        // 分隔符加了「·」(U+00B7 中间点)——部分 QQ 音乐 KRC 转出来的署名块不用冒号
        // 分隔标签和值,用的是「·」。只加在这条规则(冒号后面还要过角色词表这道关,误杀面
        // 跟冒号版本同一个量级),不加进 matchesBilingualCreditShape/matchesNameListCreditShape
        // 那两条**不查角色词表**的免词表规则——「·」在真歌词里(「爱·恨」这类风格化写法)
        // 出现的概率比冒号高得多,不能不加角色词锚点就跟着放宽。
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" || $0 == "·" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        // 冒号后必须有内容 —— 纯粹以冒号结尾的句子是真歌词里的语气停顿,不算。
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // 「汉字角色词 + 英文对照」的双语标签(酷狗/QQ 的中文曲库很常见):
        // 「制作人 Producer：陶喆」「鼓 Drums：Ash Soan」。
        //
        // label 取的是冒号前的整段(如"制作人 Producer"),下面那条判定要求剔掉分隔符后
        // 全是汉字——拉丁字母一进来整条就会失败,所以先拆出汉字/拉丁两段分别处理。
        let (hanLabel, latinLabel) = splitBilingualLabel(String(label))
        // 长度按**剔掉分隔符之后**算:"录音师/录音室"有 7 个字符,但真正的标签内容是 6 个汉字。
        var core = hanLabel.components(separatedBy: creditLabelSeparators).joined()
        // 标签里混着拉丁字母/型号/括号时,只看**汉字那一部分**。
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
        // 一次就行。加:调研同类工具时看到的做法是把繁简两种写法都手工列进默认表,
        // 那份表因此长了一倍还容易漏(有「作詞」也有「作词」,但「録音」就只有「录音」)。
        let forms = [core, HanScript.sibling(core)].compactMap { $0 }
        if creditRoleWords.contains(where: { word in forms.contains { $0.contains(word) } }) {
            return true
        }
        // 汉字头没命中,但旁边那段英文对照本身就是明确的角色名 —— 见 englishRoleNounPattern。
        guard !latinLabel.isEmpty else { return false }
        let range = NSRange(latinLabel.startIndex..., in: latinLabel)
        return englishRoleNounPattern.firstMatch(in: latinLabel, range: range) != nil
    }

    /// 「这个行首标签本身像不像职员表里的角色名」—— `matchesRoleWordCredit` 的**只看标签**版。
    ///
    /// 存在的理由:`LyricDuet.plausibleSpeakerName` 要否决长得像角色名的说话人标签,而它手上
    /// 只有标签、没有冒号后面那段内容;`matchesRoleWordCredit` 要求「标签 + 冒号 + 非空内容」
    /// 三件齐全(冒号后什么都没有的是真歌词里的语气停顿),直接拿光秃秃一个标签去问恒为 false。
    /// 拼一段占位内容再问,判据就跟过滤那边逐字同源,不必另写一份词表。
    public static func labelLooksLikeCreditRole(_ label: String) -> Bool {
        matchesRoleWordCredit(label + "：" + creditRoleLabelProbeRest)
    }

    /// 只为凑满上面那道「冒号后必须有内容」。内容本身不参与判定 —— `matchesRoleWordCredit`
    /// 看的是冒号**左边**。
    private static let creditRoleLabelProbeRest = "某某"

    /// 纯英文的职员表行,**没有冒号**那一类("Mixed by X" / "Produced by X" / "Recorded
    /// at Y"这类习惯写法)。
    ///
    /// 收窄到不误杀真歌词:必须**整行以角色词开头**(不是出现在句中),角色词后面必须紧跟
    /// by 或 at,再后面必须还有内容。英文歌词里"written by"之类出现在行首、且后面跟人名的
    /// 概率极低;而真出现在句中的("a song written by fate")不会被这条吃掉。
    ///
    /// 加了个**可选的**中文角色词前缀(复用 creditRoleWords,不新开一张表):署名行有时
    /// 前面缀着中文角色词(如"编曲 Arrangement by …"),不是纯英文起句,`^\s*` 之后直接
    /// 要求英文角色词的话汉字字符会把锚点卡死。真歌词不可能以这些角色词起句、紧接着又跟
    /// 一个英文角色词+by,加上可选前缀不扩大误杀面。
    ///
    /// `arranged` 补成 `arranged|arrangement`——「Arrangement by X」是名词形态的署名
    /// 写法,跟已有的「Arranged by X」动词形态并存。
    ///
    /// 中文前缀后面接的 `\p{Han}{0,4}`:creditRoleWords 只收了词根(「制作」),没有单独收
    /// 「制作人」这个复合词,alternation 精确命中「制作」2 个字后剩下的「人」会卡在紧跟着
    /// 要求的 `\s*` 前面导致整条 regex 失配。matchesRoleWordCredit 那边靠 `contains` 语义
    /// 天然免疫这个问题,这里换成宽松放过最多 4 个额外汉字来兜——上限参考
    /// matchesRoleWordCredit 里"标签超过 8 字不像职员表"同一个量级的克制,不放到没有上限。
    private static let englishCreditPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:\#(creditRoleWords.joined(separator: "|")))\p{Han}{0,4}\s*)?(mixed|mastered|produced|written|composed|arranged|arrangement|recorded|engineered|performed|lyrics|music|vocals?|guitars?|bass|drums|keyboards?|strings|programming|artwork|photography|design)\b[^\n]{0,20}?\s+(by|at)\s+\S"#,
        options: [.caseInsensitive]
    )

    public static func matchesEnglishCredit(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return englishCreditPattern.firstMatch(in: text, range: range) != nil
    }

    private static let genericHanCreditLinePattern = try! NSRegularExpression(
        pattern: #"^\p{Han}{1,8}\s*[:：]\s*\S"#
    )

    // 拉丁字母标签的职员表行(「Guitar：秋山浩徳」「Keyboards Programming：河野圭」
    // 这类)。上面那张关键词表只收了中文角色名和少数几个英文词,覆盖不到。
    //
    // 判据不是"英文角色名"的枚举(枚举收敛不了,见 genericHanCreditLinePattern 那段),
    // 而是**全角冒号**这个形状:这类署名块来自中日文歌词源,标签用拉丁字母、冒号却是全角
    // 的「：」。英文歌词里出现全角冒号几乎不可能,所以这一条几乎没有误杀空间。
    //
    // 半角冒号只在**冒号后面跟着中日文**时才认 —— 同样是"中日文源的署名块"这个信号,
    // 而英文歌词里的冒号("I said: let's go")后面不会跟汉字/假名。单靠半角冒号 + 拉丁
    // 标签是不敢删的:"Verse 1: ..." 这类真会出现在歌词里。标签长度上限 40。
    private static let latinCreditFullWidthPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9 .&/'’()\-]{0,40}：\s*\S"#
    )
    // 半角那条:CJK 不必紧跟在冒号后的第一个词里 —— ℗/© 版权行常见的形态是数字年份紧跟
    // 冒号、汉字标签隔了一段距离才出现(如「P - Line: 2016 北京…」),不能要求紧跟。
    private static let latinCreditHalfWidthPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9 .&/'’()\-]{0,40}:[^\p{Han}\p{Hiragana}\p{Katakana}]{0,24}[\p{Han}\p{Hiragana}\p{Katakana}]"#
    )

    /// 冒号右边像不像"一句话"(而不是一串名字)。给拉丁标签那条规则当否决闸。
    ///
    /// 加,修的是一整类**真歌词被误杀**:拉丁字母的**说话人标签**长得跟拉丁
    /// 角色名一模一样,而这条规则原来只看"拉丁标签 + 冒号"这个形状、完全不看右边。
    /// 拿全库 935 首(47626 行正文)跑回归语料挖出来的实例:
    ///
    ///     Rain：给我大声地说我爱你      ×12   —— 「Rain」是歌手名,后面是真歌词
    ///     Rain：정말 자신 있겠지         ×2
    ///     S:只会让我不小心 / S:好想问你       —— 「S」是对唱声部标记
    ///     SL：啊把日期(給它)撕掉，
    ///     N.Chen：（聽不懂...），
    ///     Rap:欢迎来到我的房间
    ///
    /// 那条规则当初的实测是"全库 537 行里精确命中 6 行署名、零误伤"——样本小了两个数量级。
    ///
    /// 判据(命中任一即认为是句子、放它过去):
    ///  - 含中文虚词(nonNameChars:的了是不我你他她…)—— 人名里不会有;
    ///  - 含谚文且至少两个空格 —— 韩文人名是 2~4 个字连写,不会带两个空格;
    ///  - 以句末标点收尾(。！？…)。
    /// 反过来,「Guitar：秋山浩徳」「Written by：Prince」「Choir：The Hong Kong Children's
    /// Choir」「P/C：2020 Riot Games」这些右边全是干净的人名/团体名,照旧判成署名。
    /// 英文里"人名/团体名不会是"的词。跟 nonNameChars 是同一个思路的拉丁版。
    ///
    /// 上一轮的句子否决只看中文虚词,于是**英文对白**照样被当署名删掉
    /// —— 加语料哨兵时当场抓到:`Rain：Baby I love you so much` 是真歌词,却因为
    /// 「拉丁标签 + 全角冒号」这个形状被整行吃掉。
    ///
    /// 刻意**不收** the/and/of/a/at/by/for/in/on/with:它们大量出现在真实署名里
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
        // 不能按"所有非字母数字"切:「(G)I-DLE/Bea Miller/Wolftyla」那样会切出一个孤立的
        // "i",而 "i" 是停用词 —— 于是真署名被当成句子放过去(语料里
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

    /// 国际标准录音码(ISRC)那一行。
    ///
    /// 形如 `ISRC TWB870211301` / `ISRC: TW-B87-02-11301`。它**没有冒号也没有角色词**,
    /// 上面那一整排以"角色+冒号"为形状的规则一条都够不着;结构性过滤同样够不着(它要冒号)。
    /// 判据是 ISRC 这个词 + 它固定的 12 位编码形状(2 位国家码 + 3 位登记者 + 2 位年份 +
    /// 5 位序号),歌词里不可能出现,所以不设否决闸。
    private static let isrcPattern = try! NSRegularExpression(
        pattern: #"^ISRC[\s:：-]*[A-Za-z]{2}[-\s]?[A-Za-z0-9]{3}[-\s]?\d{2}[-\s]?\d{5}\b"#,
        options: [.caseInsensitive]
    )

    /// 「英文角色名 : 拉丁人名」——半角冒号、而且冒号右边**没有**中日文的那一档署名行。
    ///
    /// 为什么现有两条拉丁规则都够不着:全角那条要求冒号是「：」;半角那条要求冒号右边出现
    /// 中日文(`latinCreditHalfWidthPattern`)——那个要求是**故意**的,它的注释写着"单靠
    /// 半角冒号 + 拉丁标签是不敢删的:`Verse 1: ...` 这类真会出现在歌词里"。同一份歌词里
    /// `Executive Producer : 林暐哲` 被删掉、`Publisher : Sam Duann` 留下来,差别就在这儿。
    ///
    /// 所以这一条**不放宽形状,只收窄标签**:标签必须落在一张"绝不会当段落标记用"的英文
    /// 角色名白名单里。
    ///
    /// 白名单**刻意不收** chorus / verse / bridge / intro / outro / hook / rap / refrain
    /// ——那几个正是段落标记,后面跟的是真歌词,收了就是成片误杀。乐器与声部名(guitar / vocals /
    /// drums / bass / piano…)不进这张白名单:它们只在标签**整个**由角色词组成时才认,见
    /// `matchesLatinRoleWordLabel`。
    private static let latinRoleColonPattern = try! NSRegularExpression(
        pattern: #"^(?:executive\s+|assistant\s+|co-)?"#
            + #"(producers?|production|publishers?|labels?|composers?|lyricists?|"#
            + #"arrang(?:er|ement|ed)|engineers?|engineering|studios?|"#
            + #"mixing|mixed|mastering|mastered|recording|recorded|"#
            + #"orchestra|conductor|photograph(?:y|er)|artwork|design(?:er)?|director)"#
            + #"\s*:\s*\S"#,
        options: [.caseInsensitive]
    )

    /// 标签**整个**由英文角色词组成 + 冒号 + 右边非空(`Vocals: Harry Styles`、
    /// `Drum Programming: Kid Harpoon`、`Lead & Background Vocals : Michael Jackson`)。
    ///
    /// 标签里**每一个词**都必须在下面两张表里,且至少有一个核心词。段落标记(chorus / verse /
    /// bridge / intro / outro / hook / rap / refrain)和人名都不在表里,天然放过;`solo`、`fx`
    /// 这类单独做标签有歧义的只收在修饰词表里,不能单独成立。只判形状,右边像不像一句话由
    /// `matchesLatinCreditPattern` 统一否决。
    private static let latinRoleCoreWords: Set<String> = [
        "vocal", "vocals", "vox", "guitar", "guitars", "bass", "drums", "keyboard", "keyboards", "keys",
        "synth", "synths", "synthesizer", "synthesizers", "piano", "percussion", "programming",
        "strings", "horns", "brass", "organ", "engineer", "engineers", "mixing", "mastering",
        "recording", "editing", "production", "producer", "producers", "arrangement", "arranger",
        "arrangers", "cello", "violin", "violins", "viola", "flute", "trumpet", "trombone", "saxophone",
        "sax", "clarinet", "harp", "harmonica", "whistle", "glockenspiel", "ukulele", "banjo", "mandolin",
        "accordion",
    ]
    private static let latinRoleModifierWords: Set<String> = [
        "lead", "background", "backing", "additional", "rhythm", "electric", "acoustic", "upright",
        "digital", "audio", "drum", "solo", "fx", "noise", "assistant", "executive", "co", "by",
    ]

    public static func matchesLatinRoleWordLabel(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 60, !rest.isEmpty,
              label.allSatisfy({ ($0.isASCII && $0.isLetter) || " &/,-".contains($0) })
        else { return false }
        let words = label.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: " &/,-"))
            .filter { !$0.isEmpty && $0 != "and" }
        return !words.isEmpty
            && words.allSatisfy { latinRoleCoreWords.contains($0) || latinRoleModifierWords.contains($0) }
            && words.contains { latinRoleCoreWords.contains($0) }
    }

    private static func matchesLatinCreditPattern(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        let shapeHit = latinCreditFullWidthPattern.firstMatch(in: text, range: r) != nil
            || latinCreditHalfWidthPattern.firstMatch(in: text, range: r) != nil
            // 白名单角色名 + 半角冒号 + 拉丁人名(见 latinRoleColonPattern)。
            // 它跟上面两条共用下面那道"右边像不像一句话"的否决闸。
            || latinRoleColonPattern.firstMatch(in: text, range: r) != nil
            || matchesLatinRoleWordLabel(text)
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
        // 比会对不上(就栽在这儿,抬头一行没删掉)。去掉括号段再比一次。
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
        // 判据**不能**写成"任一个歌名段出现在行内即可"。全库扫描
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
            // 一度对两侧都去括号,当场被这条原有 selftest 用例打回来。
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
    // 全库扫描实测:郭顶《飞行器的执行周期》整张专辑(10 首)的末行都是
    // 「未经著作权人许可不得翻录翻唱或使用」,一条都没被滤掉。
    //
    // 判据用"关键短语必须成对出现"而不是单个词:光有「未经」可能是真歌词(「未经允许的
    // 心动」),必须同时出现"未经/不得/版权/权利"这类法务词与"许可/翻录/翻唱/复制/授权/
    // 保留"里的一个,才认。英文那条同理只认成句的 All rights reserved 之类。
    //
    // 声明还有**反过来说**的一档:「【本音乐作品已获得正版授权】」「已通过「腾讯音乐·启明星」
    // 获得官方翻唱授权」「(本作品已经过词曲著作权利方授权)」—— 说的是"我拿到了授权",
    // 一个未经/不得/版权所有/保留权利都没有,上面几档一条都够不着;它同样没有冒号,也不是
    // 角色词开头,所以只能并进这条。判据照旧成对:取得类动词(获得/取得/经过/通过/已获/
    // 获授)或「正版/正式/独家/官方」,再加「授权」二字,光秃秃一个「授权」不认。
    // 拿本机 21285 份歌词、1284501 行量过:这一档捞起 5 行、全部是真的授权声明,0 误杀;
    // 语料里含「授权」二字的行没有一行是真歌词,这是它误杀空间极小的原因。繁体写法
    // (獲得/經過/授權)一并收下,本机语料里还没出现过。
    private static let copyrightNoticePattern = try! NSRegularExpression(
        pattern: #"(未经[^。]{0,12}(许可|授权|同意))|(不得(翻录|翻唱|复制|转载|使用|下载))|(版权所有)|(保留(所有)?权利)|(all rights reserved)|(unauthor(i[sz]ed)? (copying|reproduction|duplication))|((已获|已獲|获得|獲得|取得|经过|經過|通过|通過|获授|獲授)[^。]{0,10}授[权權])|((正版|正式|独家|獨家|官方)授[权權])"#,
        options: [.caseInsensitive]
    )

    /// 整行只有符号/标点的行(实测到过单独一行 `-`)。它不是歌词,也不是署名,就是分隔用的
    /// 排版残渣;逐行规则里没有任何一条够得着它。
    ///
    /// 判据故意写成"去掉标点/符号/空白之后什么都不剩",而不是枚举符号:这样破折号、省略号、
    /// 全角波浪线、下划线一次覆盖完。 不能把它并进"整行括号注释"一起治 —— 那一类
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

    /// 厂牌/平台的**宣传出品语**,没有冒号 —— 「网易云音乐特别企划“星辰集”出品」
    /// (用户在歌曲末尾看到它被当成一句歌词)。
    ///
    /// 为什么现有规则一条都够不着:上面那两条主力(creditLinePattern 的关键词表、
    /// genericHanCreditLinePattern 的结构化"短标签+冒号")**都要求冒号**,而这种宣传语是一句
    /// 完整的话、根本没有冒号。这不是"再补一个角色词"能解决的形状,所以另起一条,跟
    /// matchesCopyrightNotice / matchesDateStampLine 同属"无冒号、靠形状锚定"那一档。
    ///
    /// 判据是**两个条件同时成立**:去掉尾部标点引号后以出品/出版/发行/企划/呈现/呈献结尾,
    /// **并且**整行里出现平台/厂牌词。
    ///
    /// 平台词那半边不是保险起见,是**必需**的。拿这台机器上 156433 行真实歌词量过:
    ///   - 只要求"以角色词结尾":命中 8 条不同的行,其中 **6 条是真歌词**,全部栽在「呈现」上
    ///     ——「下一页结局已经慢慢呈现」「少一点 完美的呈现」「机械的唇语不太够呈现」
    ///     「让你画面一直呈现」「发光的立体呈现」「发光的 立体呈现」。
    ///   - 加上平台词:命中 2 条,`网易云音乐特别企划“星辰集”出品` 和 `索尼唱片出版`,
    ///     两条都是真的署名,**0 误杀**。
    /// 那 6 条真歌词没有一条含平台词,这正是这道闸有效的原因。
    ///
    /// 平台词对**出品/出版/发行/企划**这四个来说,在当前语料上是多余的(不加也是 0 误杀)。
    /// 仍然要求它,是因为两个方向的代价不对称:漏掉一条宣传语只是多显示一行,而误杀一条真歌词
    /// 是**静默地把用户的歌词吃掉**(这个文件 :793 一带已经为同一条理由写过一次)。代价是
    /// 「星辰集出品」这种不带平台名的写法会漏——那是刻意选的方向。
    ///
    /// 也刻意**不**按"是不是最后一行"来判。这个文件里 :980 那段【已撤销】记着:按位置从两头
    /// 扩张的做法上次把「他说：我不走」吃掉了,回退掉了。位置在这里也确实没用——实测把范围
    /// 收到末尾两行,那 6 条「呈现」误杀只减到 1 条,靠位置救不回来。
    private static let promoRoleTailPattern = try! NSRegularExpression(
        pattern: #"(出品|出版|发行|企划|呈现|呈献)$"#
    )
    private static let promoLabelPattern = try! NSRegularExpression(
        pattern: #"网易云音乐|网易音乐|QQ ?音乐|酷狗|酷我|腾讯音乐|环球|索尼|华纳|摩登天空|唱片|娱乐|传媒|文化|厂牌|Records|Entertainment"#,
        options: [.caseInsensitive]
    )
    /// 尾部要剥掉的标点/引号/括号 —— 「…“星辰集”出品」结尾干净,但「…出品。」「…出品）」
    /// 这类同样要认出来。
    private static let promoTrailingTrim = CharacterSet.punctuationCharacters
        .union(.symbols)
        .union(.whitespacesAndNewlines)

    public static func matchesPromoCreditLine(_ text: String) -> Bool {
        // 有冒号的写法交给上面那两条主力规则,这里只管没有冒号的 —— 不重复判定,也避免
        // 两条规则对同一行给出不同结论时难查是谁干的。
        guard !text.contains(":"), !text.contains("：") else { return false }
        let tail = String(text.unicodeScalars.reversed()
            .drop { promoTrailingTrim.contains($0) }.reversed().map(Character.init))
        guard !tail.isEmpty else { return false }
        let tailRange = NSRange(tail.startIndex..., in: tail)
        guard promoRoleTailPattern.firstMatch(in: tail, range: tailRange) != nil else { return false }
        let full = NSRange(text.startIndex..., in: text)
        return promoLabelPattern.firstMatch(in: text, range: full) != nil
    }

    /// 音乐平台盖在歌词里的**水印 / 推广语**:「『听歌就在中国酷狗*星曜计划』」
    /// 「本字幕由酷狗AI语音识别技术生成」「QQ音乐·银河计划x幻音方舟」「联合『酷狗音乐人 • 星曜计划』」。
    ///
    /// 为什么上面那条 `matchesPromoCreditLine` 够不着:它要求整行以 出品/出版/发行/企划/
    /// 呈现/呈献 收尾,而这类水印是一句完整的广告语,收尾是「计划」「生成」「幻音方舟」,
    /// 一个都不沾;其余规则各要冒号 / 角色词 / 版权标记,也都够不着。
    ///
    /// 判据只有两条:整行含**音乐平台自己的品牌名**,且整行没有冒号(有冒号的归那一整排
    /// "角色 + 冒号"的规则,不重复判定,分工同 `matchesPromoCreditLine`)。
    ///
    /// 品牌词表里**只放平台的名字**,绝不放「唱片 / 娱乐 / 传媒 / 文化 / Records /
    /// Entertainment」这类行业通名 —— 隔壁 `promoLabelPattern` 里两者是混在一起的,那也正是
    /// 它必须再要一个"角色词收尾"当第二判据才敢删的原因。拿本机 1101697 行量过:含行业通名、
    /// 没有冒号的行有 165 种,里面「你最爱听的唱片」「我只是进了这圈子叫娱乐」「Put on your
    /// records and regret me」全是真歌词;换成只认品牌名,同一份语料只剩 **11 种 34 行,全部
    /// 是平台水印,0 误杀**。所以这条不再设第二道闸 —— 再加一条就得把 8 种水印一起放掉。
    ///
    /// 剩下的敞口是歌词里点名某个平台(说唱报品牌那种写法),当前语料一例都没有。真遇到了
    /// 再按语料收窄,别先把判据放软去迎合想象中的写法:一软就退回 165 种那个量级。
    private static let platformBrandPattern = try! NSRegularExpression(
        pattern: #"酷狗|酷我|网易云音乐|網易雲音樂|QQ ?音[乐樂]|腾讯音乐|騰訊音樂|咪咕|汽水音[乐樂]"#,
        options: [.caseInsensitive]
    )

    public static func matchesPlatformWatermarkLine(_ text: String) -> Bool {
        guard !text.contains(":"), !text.contains("：") else { return false }
        let full = NSRange(text.startIndex..., in: text)
        return platformBrandPattern.firstMatch(in: text, range: full) != nil
    }

    /// 反盗版**口号** —— `〖盗版者必不火歌〗` 这类。
    ///
    /// 跟 `matchesCopyrightNotice` 不是一回事:那条认的是成句的**法务声明**(未经…许可 /
    /// 不得翻录 / 版权所有 / 已获得…授权),这一句一个法务词都没有,它是喊话。跟
    /// `matchesPlatformWatermarkLine` 也不是一回事:那条锚在平台品牌名上,这句里没有品牌名。
    ///
    /// 判据两条同时成立:整行被一对全角括号**完整**包住(内部不再出现同种括号),且里面出现
    /// 一个反盗版词(盗版 / 侵权 / 维权 / 必究 / 举报 / 翻版,含繁体写法)。
    ///
    /// **括号那半边不是保险,是精度的全部来源**。拿本机 1101697 行量过:含「盗版」二字的
    /// 真歌词有两行 —— `盗版是怎么回事` `盗版这怎么回事`,都没有括号;光按词删就会把它们
    /// 吃掉,加上"整行被括号包住"这道形状,同一份语料里只剩这一条口号。代价是不带括号的
    /// 口号会漏,那是刻意选的方向(漏治只多显示一行,误杀是静默吞掉一句真歌词)。
    ///
    /// 也刻意**不**靠括号种类本身:`〖〗` 在整份语料里只出现在这一行,但 `【】「」『』` 在真
    /// 歌词里到处都是(日文歌成串的引号台词),按括号种类分档只会换一种形态的误杀。
    private static let antiPiracyWordPattern = try! NSRegularExpression(
        pattern: #"盗版|盜版|侵权|侵權|维权|維權|必究|举报|舉報|翻版"#
    )

    public static func matchesAntiPiracySloganLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pairs: [(Character, Character)] = [
            ("〖", "〗"), ("【", "】"), ("『", "』"), ("「", "」"),
            ("（", "）"), ("(", ")"), ("［", "］"), ("〔", "〕"),
        ]
        guard let pair = pairs.first(where: { trimmed.first == $0.0 && trimmed.last == $0.1 })
        else { return false }
        let inner = String(trimmed.dropFirst().dropLast())
        guard !inner.contains(pair.0), !inner.contains(pair.1) else { return false }
        return antiPiracyWordPattern.firstMatch(
            in: inner, range: NSRange(inner.startIndex..., in: inner)) != nil
    }

    /// 交代这份歌词**从哪来**的说明行,三种形状,各自都没有冒号、没有角色词收尾、不一定带平台品牌名,
    /// 上面的规则一条都够不着:
    ///  - AI 生成字幕的水印:「本字幕由AI语音对齐技术生成」「本字幕由TME AI技术生成」。带平台名的写法
    ///    `matchesPlatformWatermarkLine` 已经认,这里认的是「字幕由…技术生成」这个句式本身。
    ///  - 公司供词:「由某某有限公司提供」,整行以「由」起、以「公司提供」收。
    ///  - 采样 / 改编出处:「Contains an interpolation of "X" written by …」「Contains samples from …」,
    ///    整行以 contains 起句。英文署名规则要求角色词在句首,这句的 written by 在句中。
    ///
    /// 三条都锚在整句句式上,不是关键词:「提供」「生成」「contains」单独出现在真歌词里很常见。
    /// 全库量化见 08 章第二十三轮。
    private static let provenanceNoticePatterns: [NSRegularExpression] = [
        #"字幕由.{0,24}(技术|技術)生成"#,
        #"^由.{1,30}(公司|Co\.?,? ?Ltd\.?)提供$"#,
        #"^contains (an? )?(interpolations?|samples?|elements?) (of|from)\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    public static func matchesProvenanceNoticeLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return provenanceNoticePatterns.contains { $0.firstMatch(in: trimmed, range: range) != nil }
    }

    /// 版权/免责声明行——见 copyrightNoticePattern 上的注释。
    public static func matchesCopyrightNotice(_ text: String) -> Bool {
        copyrightNoticePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 带**版权标记**的著作权行 —— 「著作权人：+© 2019、赋音乐」(用户在
    /// 方大同《白发》的悬浮窗上看到它;那首歌 12 行职员表里只有这一行漏网)。
    ///
    /// 为什么现有规则一条都够不着,而且是**四条各差一点**,这才值得单开一条:
    ///  - creditLinePattern 的关键词表里其实**有**「©」「℗」,但那条正则是 `^` 锚定的,
    ///    只认版权标记开头的行;这一行开头是汉字标签「著作权人」;
    ///  - matchesRoleWordCredit 要求标签里含一个双字角色词,而「著作」当时不在表里
    ///    (这一轮一并补进 creditRoleWords 了,见那边第十四轮的注释);
    ///  - matchesNameListCreditShape 这条免词表规则形状本来是命中的(标签 4 个汉字、右侧
    ///    「+© 2019」「赋音乐」正好两段),卡在右侧的字符集校验上:`+` 和 `©` 既不是汉字
    ///    也不是字母数字。刻意**不**放宽那道校验 —— 逐段的字符集是那条规则唯一的精度
    ///    来源(它没有词表锚点,只有"整份 ≥2 行"这一道闸),为一个版权标记就把符号放进去,
    ///    换来的覆盖面还不如单独写这一条;
    ///  - matchesCopyrightNotice 认的是「未经…许可」「不得翻录」这类**成句**的法务声明,
    ///    这一行只有标记 + 年份 + 公司名,一个法务词都没有。
    ///
    /// 判据:整行同时出现 ①版权/录音版权标记(© ℗ 及其圆圈变体,或加括号的 (C)/(P))
    /// 和 ②一个四位年份。跟位置、冒号、标签形状全都无关 —— 所以「℗ 2016 北京享耳音乐」
    /// 这种没有冒号、没有汉字标签的写法一并覆盖,不用再等下一个形态被报上来。
    ///
    /// 误杀面:拿这台机器上 4579 份歌词、233128 行正文量过 —— 版权标记在整个语料里
    /// **总共只出现 1 次**,就是这一行;加括号的 (C)/(P) 形态 0 次。真歌词里不会出现版权
    /// 标记,这是这条规则几乎没有误杀空间的原因。
    ///
    /// 年份那半边在当前语料上是**冗余**的(光看标记也是 0 误杀)。仍然要求它,理由跟
    /// matchesPromoCreditLine 里那段完全一样:漏掉一行只是多显示一行,误杀一行是**静默
    /// 吞掉用户的一句歌词**,两个方向的代价不对称。
    private static let copyrightMarks: Set<Character> = ["©", "℗", "Ⓒ", "Ⓟ", "ⓒ", "ⓟ"]
    private static let parenCopyrightPattern = try! NSRegularExpression(
        pattern: #"\(\s*[CP]\s*\)"#, options: [.caseInsensitive])
    private static let fourDigitYearPattern = try! NSRegularExpression(
        pattern: #"(?:19|20)\d{2}"#)

    public static func matchesCopyrightMarkLine(_ text: String) -> Bool {
        let full = NSRange(text.startIndex..., in: text)
        guard fourDigitYearPattern.firstMatch(in: text, range: full) != nil else { return false }
        if text.contains(where: { copyrightMarks.contains($0) }) { return true }
        return parenCopyrightPattern.firstMatch(in: text, range: full) != nil
    }

    /// 纯日期戳注解行,没有冒号也没有角色词("July 18, 2012 at 5:25 PM")。这类日期戳
    /// 常见于早年手工整理的 LRC/KRC:词曲作者在职员表最前面顺手记一句"写于哪年哪天几点"。
    ///
    /// 判据收得很紧,首尾锚定:整行必须**只**是"英文月份 日, 年份",可选再跟一段
    /// "at 时:分 AM/PM"——真歌词几乎不可能长这个形状,不需要额外的整份阈值兜底。
    private static let dateStampPattern = try! NSRegularExpression(
        pattern: #"^(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\.?\s+\d{1,2},\s*\d{4}(\s+at\s+\d{1,2}:\d{2}\s*[ap]m)?$"#,
        options: [.caseInsensitive]
    )

    /// 见 `isrcPattern`。
    public static func matchesISRCLine(_ text: String) -> Bool {
        isrcPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func matchesDateStampLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return dateStampPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }


    /// internal(不是 private):LyricDuet 拿它来否决"长得像角色名"的说话人标签,
    /// 复用同一张词表,免得两边各维护一份还对不齐。
    static func matchesKeywordCreditPattern(_ text: String) -> Bool {
        creditLinePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 对唱/口白类歌词的**说话人标签**——这些跟职员表标签形状完全一样("短汉字 + 冒号"),
    /// 但冒号后面跟的是真歌词正文,绝对不能删。
    ///
    /// 这份豁免名单是必须的,不是保险起见:这类 LRC 把**每一句**都标成「男：」「女：」
    /// 「合：」,形状 100% 命中结构正则,下面那道"命中 ≥3 行且过半"的门反而**天然被满足**
    /// ——门是为了区分"零星对白"和"整份职员表",可这种歌是"整份都带标签的真歌词",占比判据
    /// 根本分不开。实测用户自己库里《怎么了 (feat. 袁咏琳)》已经 34% 命中,离 50% 只差一步,
    /// 一旦过线就是整首歌被静默删空。
    private static let speakerLabels: Set<String> = [
        "男", "女", "合", "男合", "女合", "男女", "众", "齐",
        "白", "旁白", "念", "说", "对白", "口白",
        "男声", "女声", "合唱", "伴唱",
    ]

    private static func matchesStructuralCreditPattern(
        _ text: String, exemptions: Set<String> = []
    ) -> Bool {
        guard genericHanCreditLinePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
            return false
        }
        // 命中形状之后再看标签本身是不是说话人标签——是就豁免(既不算 hits、也不会被删)。
        //
        // exemptions 是**这一首歌**认出来的演唱者标签(LyricDuet.speakers),跟上面那份写死的
        // speakerLabels 是两回事:那份管「男/女/合」这类通用声部词,这份管人名/艺名 ——
        // 「巨炮：」「杭盖：」形状跟职员表一模一样,只有放在整首歌里数过才知道它在唱歌。
        guard let sep = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<sep].trimmingCharacters(in: .whitespaces)
        return !speakerLabels.contains(label) && !exemptions.contains(String(label))
    }

    /// 结构化规则该不该对**这一整份**歌词生效。
    ///
    /// 这道整份判定是必须的,不是保险起见。collector 侧同一条结构正则(match.go 的
    /// genericHanCreditLineRe)用在"整份候选要不要拒收"的**计数**上,误判一行无害;这边用在
    /// "这一行删不删"的**展示过滤**上,误判一行就是静默吞掉一句真歌词——同一条规则,爆炸
    /// 半径完全不同,不能原样搬。补这条规则时,selftest 的反向用例当场抓到
    /// "他说：我不走"被误杀("他说"= 2 个汉字 + 冒号 + 内容,形状完全命中)。
    ///
    /// 判据:真正要治的病是"网易云给纯音乐/配乐类曲目返回一整份职员表当歌词",特征是**整份
    /// 都是这个形状**;而正常歌曲里的对白冒号只是零星一两句。所以要求命中行既达到绝对下限
    /// (≥3 行,一两句对白够不着),又占到半数以上(整份被主导)。两个条件缺一不可:只看比例,
    /// 一首只有 2 句歌词的短曲里一句对白就过半;只看行数,一首 50 行的歌里 3 句对白就被误杀。
    private static func shouldApplyStructuralCreditFilter(
        _ texts: [String], exemptions: Set<String> = []
    ) -> Bool {
        guard !texts.isEmpty else { return false }
        // 豁免行既不被删、也**不算 hits**。两者缺一不可:只做前者的话,一首「每句都带人名
        // 标记」的对唱歌(《好好说再见》53 行里 40 行)会靠这些行把闸门顶过线,连累同一份里
        // 真正长成这个形状的**歌词**句子(selftest 里那句「他说：我不走」)跟着被删。
        let hits = texts.filter { matchesStructuralCreditPattern($0, exemptions: exemptions) }.count
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
    /// 实测赵雷《成都》:头部 13 行职员表里 4 行漏网(钢琴/箱琴/笛子/
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
        // 标签:剔掉分隔符后必须全是汉字。上限 20(从 10 放宽 ——
        // 语料里「中音萨克斯/次中音萨克斯/上低音萨克斯：孟庆泽」剔掉分隔符是 16 个汉字)。
        let labelCore = String(label).components(separatedBy: creditLabelSeparators).joined()
        // 标签至少**两个**汉字(轮补的护栏):单字标签正是说话人标签的地盘 ——
        // 「王：」「靖：」「钧：」「宏：」「男/女/合：」后面跟的是真歌词。而单字的角色词
        // (词/曲/编/唱/录/混/监/鼓)早就在关键词表里逐行生效,不靠这条免词表规则。
        //
        // 这条护栏是拿全库语料抓出来的:一旦放宽"英文名段最长 30 字",
        // 「王：Hey hey ho ho」「靖：All yours baby」被当成署名删掉(英文短句里没有停用词,
        // 句子否决拦不住),而它们跟已在 must-keep 里的「合：Hey hey ho ho」是同一首歌的同一类行。
        guard (2...20).contains(labelCore.count),
              labelCore.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }
        let segments = rest.components(separatedBy: nameListSeparators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 右侧:不能像一句话。中文虚词/英文停用词/句末标点三条都在这一个函数里
        // (跟拉丁标签那条规则共用同一道否决,别再各写一份)。
        //
        // 这道闸只在**单段**(标签后面只有一个名字,没有 `/、&,` 这类名单
        // 分隔符)时才生效。`latinCreditRestLooksLikeSentence` 按单字扫 `nonNameChars`,
        // 真实姓名可能恰好含着停用词字——多段(≥2)本身就是够强的结构信号:歌词几乎不会
        // 写成"甲/乙/丙"这种斜杠并列的短句,段数够多时改成只靠下面逐段的长度/字符集校验
        // 把关。单段时这道闸还留着,防的是「他说：我不走」这类真对白——单个短句混进来,
        // 没有"多人并列"这个结构信号能兜底,必须继续拦。
        guard segments.count >= 2 || !latinCreditRestLooksLikeSentence(rest) else { return false }
        // 段数/长度上限按书写系统分档:中文名 2~8 字,英文名/团体名长得多
        // (`Michael Maganuco` 16、`SOYEON of (G)I-DLE` 18),不能一刀切按中文名的长度算。
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

    /// 「整行被括号包住 + 内部用 `/` 分隔成 ≥3 段人名」这个形状 —— 演唱/和声/制作的参与者
    /// 名单(如 `(Natalia Cheung/Hung Man Ting/Edan Yau/…/Hin Chan)`)。
    ///
    /// 为什么上面一整排规则一条都够不着:这行**既没有角色词、也没有冒号** ——
    /// `matchesNameListCreditShape` 第一句就 `guard let colon` 退出;关键词表 / 双字角色词 /
    /// `matchesEnglishCredit` 都要角色词;版权 / ISRC / 日期戳 / 宣传语各认各的标记;而结构化
    /// 规则要"≥3 行命中且过半",这份里长成这样的行只有一行,闸门根本不开。
    ///
    /// 判据(拿本机全库 10,799 份 LRC、543,555 行歌词量出来的):
    ///  1. 整行 trim 后被一对括号包住,且内部不再出现同种括号(排除 `(a) 某某 (b)` 这类);
    ///  2. 内部按 `/` 切成 **≥3 段** —— 这是精度的全部来源,见下;
    ///  3. 每段 2~30 字符、只由汉字/字母/数字/空格/`'’.-` 组成,且一个 `nonNameChars` 都不含。
    ///
    /// **2 段绝不能收**,这是实证不是保守:全库里用 `/` 分隔的括号行,2 段共 12 行、
    /// **全是真歌词**(Prince《Girls & Boys》的 `(U were dancing so hard/strong)`
    /// `(U won't resist it/to it)` 及其译文,两个版本各一份);而 ≥3 段共 4 行、**全是署名**
    /// (本次这首 11 段、`(Slow Rabbit/Misha/YEONJUN/PXPILLON)` 4 段、
    /// `(Kanata Okajima/dyvahh/LUZY/JISOO/MOMOKA/Yuika)` 6 段)。"歌词里写 A/B 表示两个词
    /// 可替换"是真实写法,并列到三个以上就不是了。
    ///
    /// 分隔符**只认 `/`**,不收 `、&,，` —— 收了逗号会把 `(Straight up, straight up,
    /// straight up)`、`(Let go, let go, let go)`、`(Ooh, yeah)` 这类和声整片吃掉(同一份语料
    /// 里,按逗号也算分隔符时 ≥2 段的括号行有 453 行,绝大多数是真歌词)。
    ///
    /// **只治带括号的**:不带括号的裸名单(`A/B/C`)刻意没进这一条 —— 当前语料里一例都没有,
    /// 而去掉括号这个强信号后误杀面要大得多。真遇到了再按语料加,别凭想象扩形状。
    ///
    /// 逐行生效(不受"整份主导"闸门管),理由同关键词表:这个形状在 543,555 行里只命中 4 行、
    /// 无一误伤,误判空间已经被"≥3 段 + 每段都像人名"压到极小。
    public static func matchesParenNameListCreditShape(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pairs: [(Character, Character)] = [("(", ")"), ("（", "）")]
        guard let pair = pairs.first(where: { trimmed.first == $0.0 && trimmed.last == $0.1 })
        else { return false }
        let inner = trimmed.dropFirst().dropLast()
        // 内部不能再出现同种括号:`(和声) 某某 (和声)` 首尾也长这样,但它不是一整块名单。
        guard !inner.contains(pair.0), !inner.contains(pair.1) else { return false }
        let segments = inner.components(separatedBy: CharacterSet(charactersIn: "/／"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard segments.count >= 3 else { return false }
        return segments.allSatisfy { seg in
            (2...30).contains(seg.count)
                && !seg.contains(where: { nonNameChars.contains($0) })
                && seg.unicodeScalars.allSatisfy { u in
                    u.properties.isIdeographic || CharacterSet.alphanumerics.contains(u)
                        || " '’.-".unicodeScalars.contains(u)
                }
        }
    }

    /// 测试接缝:把一整份行文本过一遍署名行过滤,返回"这一行删不删"。
    ///
    /// 存在的理由:整份闸门(≥2 行、过半…)是这套规则的一半,只测单行匹配函数测不到它;
    /// 而从 `allLines()` 的输出反推"哪行被删了"会被另外两件事污染 —— 对唱标记会被
    /// LyricDuet 从正文里剥掉、一行多时间戳会被展开成多行,两者都让"文本对不上"却不是
    /// 过滤造成的(拿全库 925 首做回归语料时踩到,误判出上百条"被误杀的真歌词")。
    /// 直接曝光这一层,语料统计和单测都拿它当唯一判据。
    public static func creditLineDropDecisions(
        _ texts: [String], trackTitle: String = "", trackArtist: String = "",
        speakerExemptions: Set<String> = []
    ) -> [Bool] {
        strippingCreditLines(
            texts, trackTitle: trackTitle, trackArtist: trackArtist,
            speakerExemptions: speakerExemptions)
    }

    /// 过滤掉署名/职员表行。关键词表逐行生效(它枚举的都是明确的角色名,误判空间很小);
    /// 结构化规则只在整份被主导时才生效,见 shouldApplyStructuralCreditFilter。
    private static func strippingCreditLines(
        _ texts: [String], trackTitle: String = "", trackArtist: String = "",
        speakerExemptions: Set<String> = []
    ) -> [Bool] {
        let useStructural = shouldApplyStructuralCreditFilter(texts, exemptions: speakerExemptions)
        // 免词表的双语形状:整份 ≥2 行才认(理由见 matchesBilingualCreditShape)。
        let bilingualHits = texts.filter(matchesBilingualCreditShape).count
        let useBilingualShape = bilingualHits >= 2
        // 免词表的「标签 + 名字串」形状:同样整份 ≥2 行才认(理由见 matchesNameListCreditShape)。
        let nameListHits = texts.filter(matchesNameListCreditShape).count
        let useNameListShape = nameListHits >= 2
        var base = texts.enumerated().map { i, text -> Bool in
            // 演唱者标签行一律放行。放在所有规则**最前面**,而不是只补进
            // 结构化那一条:人名标签同时够得着好几条规则,逐条打补丁迟早漏。
            //
            // 独占一行的标记(`周杰伦：` 后面什么都没有)也走这里保留下来 —— 它确实不该
            // 显示,但该由 LyricDuet 按"剥完为空"丢掉,不是由署名过滤删:两者判据不同,
            // 让署名过滤兼这个职,等于把"这行是不是署名"和"这行有没有正文"混成一件事。
            if let (label, _, _) = LyricDuet.splitLabel(text), speakerExemptions.contains(label) {
                return false
            }
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
            // 带版权标记的著作权行(「著作权人：+© 2019、赋音乐」「℗ 2016 北京享耳音乐」)。
            // 跟上面那条"成句的法务声明"不是一回事:那条认法务词,这条认版权标记 + 年份,
            // 见 matchesCopyrightMarkLine(那里记着四条现有规则各差在哪一步)。
            if matchesCopyrightMarkLine(text) { return true }
            // 纯日期戳注解("July 18, 2012 at 5:25 PM")——同样没有冒号也不是角色词开头,
            // 见 dateStampPattern。
            if matchesDateStampLine(text) { return true }
            // 国际标准录音码行(`ISRC TWB870211301`)——没有冒号、也不是角色词开头,
            // 上面所有以"角色+冒号"为形状的规则都够不着,见 isrcPattern。
            if matchesISRCLine(text) { return true }
            // 括号包着的一串 `/` 分隔人名(`(A/B/C/…)`)——参与者名单,同样既没角色词也没冒号,
            // 见 matchesParenNameListCreditShape(那里记着"2 段是真歌词、≥3 段才是署名"
            // 这条分界是拿全库 543,555 行量出来的)。
            if matchesParenNameListCreditShape(text) { return true }
            // 厂牌/平台的宣传出品语(「网易云音乐特别企划"星辰集"出品」)——同样没有冒号,
            // 见 matchesPromoCreditLine(那里记着平台词这道闸是拿 15 万行真实歌词量出来的,
            // 不加会误杀 6 条含「呈现」的真歌词)。
            if matchesPromoCreditLine(text) { return true }
            // 平台水印(「『听歌就在中国酷狗*星曜计划』」)——同样没有冒号,而且不以角色词
            // 收尾,上面那条宣传语规则够不着,见 matchesPlatformWatermarkLine。
            if matchesPlatformWatermarkLine(text) { return true }
            // 反盗版口号(「〖盗版者必不火歌〗」)——没有法务词也没有品牌名,上面两条都够不着,
            // 见 matchesAntiPiracySloganLine。
            if matchesAntiPiracySloganLine(text) { return true }
            // 字幕 / 供词 / 采样出处这类来源说明,见 matchesProvenanceNoticeLine。
            if matchesProvenanceNoticeLine(text) { return true }
            // 整行只有符号(单独一行 `-` 之类),见 isSymbolOnlyLine。
            if isSymbolOnlyLine(text) { return true }
            // 抬头只在第一行认 —— 别的位置出现同样的字样多半是真歌词。
            if i == 0, looksLikeHeaderLine(text, trackTitle: trackTitle, trackArtist: trackArtist) {
                return true
            }
            return useStructural && matchesStructuralCreditPattern(text, exemptions: speakerExemptions)
        }
        // 标签独占一行的双语署名,连同紧跟的值那一行(见 matchesLabelOnlyBilingualCredit)。
        // 写回 base,下面的夹心补漏也看得到这两行。
        for i in texts.indices where !base[i] && matchesLabelOnlyBilingualCredit(texts[i]) {
            if let (label, _, _) = LyricDuet.splitLabel(texts[i]), speakerExemptions.contains(label) { continue }
            base[i] = true
            if i + 1 < texts.count, !base[i + 1], looksLikeCreditValueLine(texts[i + 1]) {
                base[i + 1] = true
            }
        }
        // 夹心补漏:**前后都**被上面那些规则判成署名的那一行,自己也是署名 —— 哪怕它的标签
        // 一张表都没收。治的是"逐词枚举收不住"这个根问题:单字乐器(「箫：水玥儿」,双字角色词
        // 那条规则按设计不收单字)、罕见职务(「项目协力：」「爱尔兰哨笛：」「音频助理：」)、
        // 繁体写法(「編曲：」),以及词表**刻意不收**的「合唱：」「独白：」「男声：」——
        // 那几个词单独出现时可能是对唱分声部标记,夹在两条已确认署名之间时不可能是。
        //
        // 这**不是**下面【已撤销】那条「从头尾向内扩展署名块」。那条只要求**一侧**连着
        // 署名块,于是紧跟在头部署名后面的第一句真歌词(selftest 钉着的「他说：我不走」)被
        // 吃掉;这条要求**两侧都是**,而那句后面跟的是真歌词,条件不成立。判据的强弱差就在
        // 这一个「都」字上,放宽成一侧立刻退化成已经被否决过的那条。
        //
        // 形状判据复用 matchesStructuralCreditPattern:它自带说话人标签豁免(写死的
        // 男/女/合,加上这首歌自己认出来的演唱者名),所以对唱歌不会因为这条多丢一行。
        //
        // 只读上一轮的结果(base),不吃自己的输出 —— 连着两行未知标签时不做链式扩散。
        // 多漏治一行,远好过多吃一句真歌词,跟整份闸门那道安全阀同一个取向。
        var drop = base
        for i in base.indices.dropFirst().dropLast() where !base[i] {
            guard base[i - 1], base[i + 1] else { continue }
            guard matchesStructuralCreditPattern(texts[i], exemptions: speakerExemptions) else { continue }
            drop[i] = true
        }
        // 兜底闸门:展示过滤**永远不把整份删空**。走到这一步说明判据出了我没预料到的偏差
        // (某种全篇都长成职员表形状、但其实是真歌词的写法),此时"整片空白/一直显示♪"对用户
        // 来说比"多显示几行职员表"糟糕得多——宁可漏治,不可删空。跟 collector 侧
        // isCreditOnlyLRC 的"整份拒收"是两回事:那边拒收之后还有别的源可以顶上,这边删空了
        // 就真的什么都没有了。
        //
        // 考虑过收窄成"只在结构化规则参与时才触发",被 selftest 里那条
        // "作词：甲/作曲：乙/编曲：丙"(纯关键词表命中、跟结构化规则完全无关)的既有回归
        // 测试原样打回来——这道闸就是设计成"不管靠哪条规则,100% 就是不删",不是结构化
        // 规则的专属保险。丁世光《背面是我》专辑的纯配乐 Interlude(《Presentness》
        // 《Bygone》)整首歌就是清一色职员表,踩到这道闸走的正是"这份候选压根不该被
        // 当成有效歌词收下"这条路——那是 collector 侧 isCreditOnlyLRC(整份拒收,拒了
        // 还有别的源/标记纯音乐兜底)该管的事,不该在展示层为了这一种情况反过来削弱这道
        // 保护全库的安全阀。
        if drop.allSatisfy({ $0 }) && !texts.isEmpty {
            return texts.map { _ in false }
        }
        return drop
    }

    // 【已撤销】"从头尾向内扩展署名块"(照搬 YRC 解析那一套)写过又删掉。
    //
    // 想法本身没错:噪声天然聚在头尾两段连续区。但在 YRC 上敢这么做是因为 **YRC 格式自带
    // credit 块标记**,那是在读标记、不是在猜;LRC 没有这个标记,只能拿"结构化形状"顶替,
    // 而那一步就是猜。实际后果:selftest 里那句紧跟在头部署名后面的真对白「他说：我不走」
    // 当场被吃掉 —— 形状 100% 命中,而它是这首歌的第一句歌词。
    //
    // 试过用"标签在整份里出现 <= 2 次"当护栏(对唱说话人标签必然反复出现),挡不住:一次性
    // 的对白同样只出现一次。而且这条规则在用户全库 508 首里**一条都没多滤到**,收益为零、
    // 风险实测存在,不值当。要重做的话,方向是**用时间戳**(署名块贴在 0~5 秒、真歌词有前奏
    // 间隔)而不是文本形状。


    public init() {}

    /// load 的 7 个入参的完整快照。它们是 load 输出的**全部**输入(load 不读引擎其它
    /// 状态),快照相等 到 解析/过滤/派生状态必然相等 到 可以整段跳过。
    private struct LoadFingerprint: Equatable {
        let lyrics, lyricsTr, lyricsRoma, lyricsYRC: String
        let trackTitle, trackArtist: String
        let romanizationScripts: RomanizationScripts
        let songIsCantonese: Bool
    }
    private var loadedFingerprint: LoadFingerprint?

    /// 返回值:内容真的变了吗(false = 入参与上次完全一致,整段跳过)。
    ///
    /// 早退闸:enrich 缓存是全库单文件,collector 给**别的歌**写盘
    /// (专辑预取/译文回填/重打分)也会 bump mtime,调用方(reloadCurrentLyrics)按 mtime
    /// 失效就会带着一字未变的入参反复调进来 —— 原来每次都全量重跑解析+署名过滤,还把
    /// romanizer/wordGroup/segments 三个按行缓存无条件清空,让 20Hz 路径和 allLines 再
    /// 全部重算一遍(日文逐字歌一次 10-40ms 主线程,正撞上 30Hz 填色渲染)。字符串 == 在
    /// 相等时要逐字节比,但几十 KB 也只是 µs 级,相对省下的毫秒级重算完全值得。
    /// 入参全等时**保住**全部缓存——输入相等则派生状态必然相等,比"清了也不会算错"更强。
    @discardableResult
    public func load(
        lyrics: String, lyricsTr: String, lyricsRoma: String, lyricsYRC: String,
        trackTitle: String = "", trackArtist: String = "",
        romanizationScripts: RomanizationScripts = .default, songIsCantonese: Bool = false
    ) -> Bool {
        let fingerprint = LoadFingerprint(
            lyrics: lyrics, lyricsTr: lyricsTr, lyricsRoma: lyricsRoma, lyricsYRC: lyricsYRC,
            trackTitle: trackTitle, trackArtist: trackArtist,
            romanizationScripts: romanizationScripts, songIsCantonese: songIsCantonese)
        if fingerprint == loadedFingerprint { return false }
        loadedFingerprint = fingerprint
        self.romanizationScripts = romanizationScripts
        // 逐字时间轴先过一遍合法性归一化(LyricTimelineNormalizer):字起点早于行首 /
        // 落在下一行开始之后的小偏差夹回来,乱序或偏差太大的行退化成均匀扫过。放在署名过滤之前——
        // 归一化要看相邻行的时间戳,得在完整的行列表上做。每次加载只记一行汇总日志。
        // 逐字数据**始终**解析。之前有个入参对应设置页那颗全局「卡拉OK效果」,
        // 关掉就在这里丢弃 YRC、四个展示面一起退成整行;现在"要不要逐字填色"是悬浮歌词 / 灵动岛 /
        // 菜单栏各自的开关,由各展示面在消费点把行压成整行(`SyncedLyricLine.lineLevel`),
        // 引擎不再替任何一个面做这个决定。
        let normalizedYRC = LyricTimelineNormalizer.normalize(YRCParser.parse(lyricsYRC))
        let yrc = normalizedYRC.lines
        LyricTimelineNormalizer.logSummary(normalizedYRC.report, track: trackTitle)
        // 过滤前先把整份的文本取出来判一次(结构化规则是整份粒度的,见
        // shouldApplyStructuralCreditFilter),不能像原来那样逐行独立 filter。
        //
        // 两种来源都先各自解析+过滤出来,再决定用哪个 —— 不能无条件"有 YRC 就一定用
        // YRC":有些源给的逐字数据是**退化**的,只有寥寥几行、其中大半又被署名过滤判掉
        // (strippingCreditLines 对"整份都被判成署名"留了兜底,不会一行不剩,但退化到只剩
        // 一两行时,activeLine 取"时间戳 <= 当前位置的最后一行"会让整首歌卡在那一行上不动,
        // 看起来像歌词坏了)。
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
        // 演唱者标签要在署名过滤**之前**认出来,再回头当豁免喂给它 —— 顺序不能反:
        // 「每句都带标记」的对唱歌天然满足署名过滤"命中 ≥3 行且过半"的闸门,先过滤就是
        // 整首被删空(这也正是 speakerLabels 那份写死名单当初存在的理由,现在人名走同一条路)。
        let baseTexts = parsedBase.map(\.text)
        let baseSpeakers = LyricDuet.speakers(in: baseTexts)
        // 正文两条路径(整行 / 逐字)各自认出来的演唱者标签的并集,下面剥译文和罗马音用。
        var allSpeakers = baseSpeakers
        let baseDrop = Self.strippingCreditLines(
            baseTexts, trackTitle: trackTitle, trackArtist: trackArtist,
            speakerExemptions: baseSpeakers)
        let filteredBase = zip(parsedBase, baseDrop).compactMap { $0.1 ? nil : $0.0 }
        // 被判成署名的那些**时间戳**。译文/罗马音跟着它走,见下面 romaLines/trLines 的注释。
        var creditTimesMs = Set(zip(parsedBase, baseDrop).compactMap { $0.1 ? $0.0.timeMs : nil })
        var candidateWords: [LyricLineWords] = []
        if !yrc.isEmpty {
            // 逐字侧单独认一遍:同一首歌 .lrc 和 .yrc 的标记未必一致(实测《说好不哭》
            // 两份都有,但也见过只有一份带标记的)。
            let texts = yrc.map { $0.words.map(\.text).joined() }
            let wordSpeakers = LyricDuet.speakers(in: texts)
            // 译文/罗马音要拿这一份去剥标签,而这两样**未必**跟着 LRC 走:只有逐字数据的
            // 条目 baseTexts 是空的,baseSpeakers 也就是空集。两边并起来才不会漏。
            allSpeakers.formUnion(wordSpeakers)
            let drop = Self.strippingCreditLines(
                texts, trackTitle: trackTitle, trackArtist: trackArtist,
                speakerExemptions: wordSpeakers)
            candidateWords = zip(yrc, drop).compactMap { $0.1 ? nil : $0.0 }
            creditTimesMs.formUnion(zip(yrc, drop).compactMap { $0.1 ? $0.0.timeMs : nil })
        }
        usingWords = !candidateWords.isEmpty
            && (filteredBase.isEmpty || candidateWords.count * 2 >= filteredBase.count)
        // 对唱标记的剥离(见 LyricDuet)。两条路径都会剥掉行首标记、给出每行摆哪一边,
        // 并且把**独占一行的标记**(`[00:24.83]周杰伦：` 这种,剥完什么都不剩)整行丢掉 ——
        // 它带着自己的时间戳,不丢就是屏幕上凭空多出一句词(实测《等你下课》里一行「Gary」
        // 会挂 23.3 秒)。
        //
        // 过滤 sides 只能 filter+map,**不能用 compactMap**:元素本身就是 `Side?`,
        // 「第一个标记之前的行」正常值就是 nil,compactMap 会把它们连同被丢掉的行一起
        // 摘掉,sides 就比 lines 短一截、整条对唱归属集体错位一格。
        if usingWords {
            let plan = LyricDuet.planWords(candidateWords)
            let kept = zip(zip(plan.lines, plan.sides), plan.dropped).filter { !$0.1 }
            wordLines = kept.map { $0.0.0 }
            wordSides = kept.map { $0.0.1 }
            baseLines = []
            baseSides = []
        } else {
            let plan = LyricDuet.plan(lineTexts: filteredBase.map(\.text))
            wordLines = []
            wordSides = []
            let kept = zip(zip(zip(filteredBase, plan.texts), plan.sides), plan.dropped)
                .filter { !$0.1 }
            baseLines = kept.map { LyricLine(timeMs: $0.0.0.0.timeMs, text: $0.0.0.1) }
            baseSides = kept.map { $0.0.1 }
        }
        // 译文和罗马音也要剥掉演唱者标签(理由见 LyricDuet.strippingKnownLabel):这两条
        // 是独立于正文的路径,`plan`/`planWords` 剥标签那一步它们走不到,不在这儿剥就没人剥。
        //
        // 署名行这两条也要跟着丢,但判据**不是重跑一遍署名过滤,而是认正文已经判掉的那些
        // 时间戳** —— collector 的 assembleTranslationLRC 把每条译文/罗马音的时间戳原样从
        // 正文那一行抄过来(见下面 trTextByPlainText 的注释),所以"正文这一行是署名"直接就是
        // "它的译文/罗马音也是署名",不需要再判一次。
        //
        // 别把署名过滤直接跑在译文/罗马音的**文字**上,两个方向都会错(拿本机 7084 份
        // 附属文件 / 339098 行量过):
        //  - **漏的才是大头**:罗马音里的署名是拼音/粤拼(`qū： fāng dà tóng`、`zuò cí :
        //    fāng wén shān`),汉字角色词表一条都够不着 —— 这类光靠文字判会漏掉 12970 行,
        //    而认时间戳全都接得住。
        //  - **同时还会吃真歌词**:译文/罗马音里说话人标签被一起音译成 `hap6 ：`(合)、
        //    `naam4 ：`(男)、`Rap：`、`Y：`,形状跟署名一模一样,而 `allSpeakers` 是从**汉字**
        //    正文认出来的、对不上这些音译标签;真按文字判会多删 257 行,其中绝大多数是真歌词
        //    (`hap6 ： go1 jiu4 zai3`、`这就是我的命运：用一生去补偿`)。
        //
        // 同一个时间戳上如果还留着一行真歌词(整行和逐字两条路径都算),这个戳就不算署名 ——
        // 留下来的那行真歌词的译文/罗马音正挂在上面,丢了就是白丢一行。实测本机 7210 首里
        // 有 86 处这种撞车(多数是 `[00:00.00]` 上抬头行和第一句挤在一起)。
        creditTimesMs.subtract(filteredBase.map(\.timeMs))
        creditTimesMs.subtract(candidateWords.map(\.timeMs))
        romaLines = LRCParser.parse(lyricsRoma).filter { !creditTimesMs.contains($0.timeMs) }.map {
            LyricLine(timeMs: $0.timeMs, text: LyricDuet.strippingKnownLabel($0.text, speakers: allSpeakers))
        }
        trLines = LRCParser.parse(lyricsTr).filter { !creditTimesMs.contains($0.timeMs) }.map {
            LyricLine(timeMs: $0.timeMs, text: LyricDuet.strippingKnownLabel($0.text, speakers: allSpeakers))
        }
        // 内容匹配字典(查找细节见类头 trTextByPlainText 的注释)。用
        // filteredBase 而不是上面的 baseLines 属性——usingWords 为真时 baseLines 会被
        // 清空(供非逐字模式展示用,这里只是借它的"整行 LRC 解析结果"这份数据,跟
        // usingWords 无关,两者刻意不共用同一个数组)。
        //
        // 配对靠**精确** timeMs 相等,不是 nearestText 那种带容差的最近邻——collector 的
        // assembleTranslationLRC 生成译文/罗马音时,每一条写出来的时间戳都是原样从
        // filteredBase 对应那一行的 timeMs 抄过去的,不是"接近",是同一个数字。所以能
        // 100% 精确配对,不需要猜。
        //
        // 键用原文(未经 LyricDuet 去说话人标记),对唱歌的带标记行匹配不上时会自然退回
        // 下面 translationText/romanizationText 里原有的 nearestText 兜底——不是新 bug,
        // 是维持这些行原来就有的行为不变,只是它们享受不到这次内容匹配带来的提升。
        do {
            let trByTime = Dictionary(trLines.map { ($0.timeMs, $0.text) }, uniquingKeysWith: { _, new in new })
            let romaByTime = Dictionary(romaLines.map { ($0.timeMs, $0.text) }, uniquingKeysWith: { _, new in new })
            trTextByPlainText = Dictionary(
                filteredBase.compactMap { line -> (String, String)? in
                    let key = Self.contentMatchKey(line.text)
                    guard !key.isEmpty, let tr = trByTime[line.timeMs], !tr.isEmpty else { return nil }
                    return (key, tr)
                }, uniquingKeysWith: { _, new in new })
            romaTextByPlainText = Dictionary(
                filteredBase.compactMap { line -> (String, String)? in
                    let key = Self.contentMatchKey(line.text)
                    guard !key.isEmpty, let roma = romaByTime[line.timeMs], !roma.isEmpty else { return nil }
                    return (key, roma)
                }, uniquingKeysWith: { _, new in new })
            // 逐字数据偶尔把相邻两句整行并成一行,它的键是两句键拼起来的:单句键查不到,
            // nearestText 又会挂上其中一句、甚至别的句子的译文。单句键登记完之后再补相邻两句的
            // 拼接键,已有同名键的不覆盖(真实单句永远优先)。见决策 18。
            Self.addAdjacentPairKeys(into: &trTextByPlainText, lines: filteredBase, byTime: trByTime)
            Self.addAdjacentPairKeys(into: &romaTextByPlainText, lines: filteredBase, byTime: romaByTime)
        }
        // 罗马音该不该对这首歌生效、以及汉字按哪种语言读 —— 都按"整首歌"粒度判一次
        // (不逐行判:极少数纯汉字的日文行会被局部误判成中文,见 Romanizer.romanize 的注释)。
        //
        // 判定样本是**过滤掉署名行之后的正文**,不是原始的 lyrics/lyricsYRC 字段。
        //
        // 不能扫原始字段(含署名行)来判——中文歌的署名行里带日文原作者名是常态(如
        // 「词：れるりり」这类),若把署名行也算进"是否出现过假名",会把纯中文的翻唱歌
        // 误判成日文整首,连累用户关着的"中文罗马音"开关完全不起作用(闸看的是整首歌的
        // 语言),每一行中文的字都被按日语分词器强行注音。
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
        // 判据是**含假名的行占比**,不是"出现过假名没有"(改,理由见
        // Romanizer 里「整首歌 vs 一行」那段:中文歌引用一个日文词就会被整首判成日文,
        // 于是每行汉字都出日文音读)。这个整首歌级别的标记**只**给纯汉字行兜底用。
        songLooksJapanese = Romanizer.looksJapaneseSong(contentSample)
            || Romanizer.looksJapaneseSong(contentWordSample)
            || (contentSample.isEmpty && contentWordSample.isEmpty
                && (Romanizer.looksJapaneseSong(lyrics) || Romanizer.looksJapaneseSong(lyricsYRC)))
        // 整首歌的文字种类,给"按语言开关罗马音"兜底用(逐行判不出来的纯汉字行)。
        // 粒度/样本跟上面完全一致。
        songScript = Romanizer.songScript(of: scriptSample)
        // 粤语汉字跟普通话汉字长得一模一样,songScript(of:) 纯靠文字分析永远只会判成
        // .chinese——粤语这一档必须由调用方喂进来的外部信号(collector 的 SongLanguage
        // 真值)覆盖,不能指望从歌词文字里分析出来。只在判成 .chinese 时才覆盖:已经因为
        // 假名/谚文判成日文/韩文的行(比如粤语歌里引用了一句日文)不该被这个信号打断。
        if songScript == .chinese, songIsCantonese {
            songScript = .cantonese
        }
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
        cachedNextSide = nil
        cachedNextRomanization = nil
        cachedNextTranslation = nil
        cachedNextWordGroups = nil
        cachedLeadIdx = Int.min
        cachedLeadLine = nil
        lastScanIdx = Int.min
        return true
    }

    private var songLooksJapanese = false
    private var songScript: LyricScript = .other
    private var romanizationScripts: RomanizationScripts = .default

    /// **这一行**该不该标罗马音 —— 由它的文字种类和用户开关共同决定。
    /// `.other`(拉丁/泰文/西里尔…)不受管辖,始终允许,保持历来的行为。
    ///
    /// 从"按整首歌"改成"按行":一首中文歌里引用的日文行(《这样吧》里的
    /// 「サヨナラ」)该按**日文**开关走、出罗马字,而同一首歌的中文行该按**中文**开关走
    /// (默认关 → 不显示)。按整首歌判做不到这件事,只能二选一:要么中文行被塞注音
    ///,要么中日混唱歌(陶喆《My Anata》,41% 的行是日文)的日文行
    /// 一起丢掉罗马音。判定本身在 Romanizer.script(ofLine:song:)。
    private func romanizationAllowed(for line: String) -> Bool {
        guard let option = Romanizer.script(ofLine: line, song: songScript).option else {
            return true
        }
        return romanizationScripts.contains(option)
    }

    /// 这一行里的**中文片段**要不要换回原文 —— 只对混排行(行内既有假名又有汉字)有意义。
    ///
    /// 上面那道 `romanizationAllowed` 管的是整行:见到假名就确证这一行是日文,整行归
    /// **日文**开关。但混排行里的中文片段不是日文,`Romanizer.japaneseSegments` 默认把它们
    /// 渲染成拼音(见 `HanRunReading`)——日文开关开着、拼音开关关着时那份拼音照样被整行
    /// 放出去,拼音开关就落空了。判真时片段按 `.original` 渲染,只留日文片段的罗马字。
    ///
    /// 整首歌像日文时不适用:那种歌里的汉字读的是日语音读(`applyCodeSwitchFallback`
    /// 本来就只在 `!songLooksJapanese` 时跑),本来就归日文开关,跟拼音无关。
    /// 粤语歌的汉字片段查粤拼那一档 —— 判据跟 `script(ofLine:song:)` 对纯汉字行的分派
    /// 一致(汉字本身分不出普通话还是粤语,只能信 songScript 这个外部信号)。
    private func masksHanRuns(in line: String) -> Bool {
        guard !songLooksJapanese, Romanizer.looksJapanese(line), Romanizer.containsHan(line)
        else { return false }
        return !romanizationScripts.contains(songScript == .cantonese ? .cantonese : .chinese)
    }
    private var kanaAnnotation: KanaAnnotation?

    public var hasContent: Bool { usingWords ? !wordLines.isEmpty : !baseLines.isEmpty }

    /// 说话人标签独立成行、冒号后没有真内容(如「合：」,YRC 里逐字数据把标签拆成
    /// 「合」+「：」两个字、共享同一个时间戳,见 usingWords 分支的注释)——
    /// 对拍坐实的真 bug:这类标签行往往只有一百多毫秒,紧挨着后面那句真歌词(同一次
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
    ///
    /// 加内容匹配优先:先按这一行的原文精确查 trTextByPlainText(不依赖
    /// 任何时间戳,天然不受 YRC/LRC 时间基准不一致影响),查不到(对唱歌被剥过说话人
    /// 标记的行、或这行内容跟服务端 LRC 字面对不上)才退回原来的 nearestText 时间
    /// 最近邻——两条路都保留,内容匹配只是优先级更高的一条更准的路径。
    /// 把相邻两句整行的拼接键登记进内容匹配字典,值是两句各自的译文 / 罗马音用空格连起来
    /// (只有一句有就只用那一句)。已有同名键的不覆盖。
    static func addAdjacentPairKeys(into dict: inout [String: String], lines: [LyricLine], byTime: [Int: String]) {
        guard lines.count >= 2 else { return }
        for i in 0..<(lines.count - 1) {
            let a = contentMatchKey(lines[i].text), b = contentMatchKey(lines[i + 1].text)
            guard !a.isEmpty, !b.isEmpty, dict[a + b] == nil else { continue }
            let parts = [byTime[lines[i].timeMs], byTime[lines[i + 1].timeMs]]
                .compactMap { $0 }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            dict[a + b] = parts.joined(separator: " ")
        }
    }

    private func translationText(timeMs: Int, plainText: String) -> String? {
        guard !Self.isBareSpeakerTag(plainText) else { return nil }
        if let byContent = trTextByPlainText[Self.contentMatchKey(plainText)] {
            return byContent
        }
        return nearestText(trLines, timeMs)
    }

    private func nearestText(_ arr: [LyricLine], _ t: Int, tolerance: Int = 700) -> String? {
        // 数组按 timeMs 升序(LRCParser.parse 尾部 sorted),二分找插入点、只比较左右邻居——
        // 复杂度 O(log n),避免 allLines 构建时每行都线性扫一遍。
        // 语义:`d <= bestDiff` 是后见者胜 —— 同距并列取时间戳更晚的那条,同时间戳重复取
        // 排在最后的那条(selftest 对拍钉着这条不变式)。
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
            // arr[lo-1] 已是"timeMs <= t 里最后一条"——同时间戳重复天然取最后一条。
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
    // 实测排查坐实的真实性能回归:activeLine(atMs) 由
    // LocalPlaybackSource.fastTick() 以 20Hz 调用,每次都会重新算一遍这一行的
    // romanization——没有服务端罗马音的歌(比如纯英文歌词)会在每一次 tick 都重新跑一遍
    // Romanizer.romanize() 的 ICU 音译,而不是只在真的换到新的一行时才算一次,导致主线程
    // 20 次/秒白白做重复的字符串音译运算,表现成"本地悬浮窗/歌词窗口进度肉眼可见地比
    // 网页端(走的是完全不同的一套外推逻辑,不受这里影响)慢、跟不上播放进度"。按
    // plainText 记忆化:同一句歌词文本只在第一次真正算一遍,之后的 19/20 次 tick 直接
    // 命中缓存,不再重复调用这个开销不小的字符串变换。
    private var romanizerFallbackCache: [String: String?] = [:]

    private func romanizationText(timeMs: Int, plainText: String) -> String? {
        // 这道闸必须在**服务端字段之前**。用户关掉某种语言的罗马音,意思是"别给我看",
        // 不是"别去现算" —— 只拦客户端兜底的话,服务端恰好给了 lyrics_roma 的那些歌照样
        // 会显示,开关就成了个看运气的东西。
        guard romanizationAllowed(for: plainText) else { return nil }
        // 同一个"标签行抢近邻词条"的坑,见 isBareSpeakerTag 的注释——罗马音跟译文共用
        // 同一套 nearestText+700ms 容差,症状对称。
        guard !Self.isBareSpeakerTag(plainText) else { return nil }
        // 混排行要把中文片段换回原文时,源自带/预生成那份整行罗马音用不了:它是**完整版**
        // (生成侧一律按拼音渲染中文片段、不看开关 —— 开关随时能改,按开关生成的话用户
        // 一打开拼音,存量几千首就得全部回补),而且是拼好的一整个字符串,事后切不出
        // 哪一段对应中文片段。这种行绕过整段来源查找,直接现算一份过滤过的。
        // 代价是这一行的展示跟导出的 `.roma.lrc` 不一致 —— 那正是"生成完整、展示按开关
        // 过滤"这条分工的应有之义。
        if !masksHanRuns(in: plainText) {
            // 内容匹配优先,理由跟 translationText 那段一致(同一个 trTextByPlainText/
            // romaTextByPlainText 的建法,对称处理)。
            if let byContent = romaTextByPlainText[Self.contentMatchKey(plainText)] {
                return byContent
            }
            if let fromSource = nearestText(romaLines, timeMs) { return fromSource }
            guard romaLines.isEmpty else { return nil }
        }
        // 这里原来有一道硬编码的闸:"含汉字、且整首歌不像日文 → 一律不兜底"。
        // 它解决的是那个真实 bug —— 中文歌被 ICU 音译成拼音展示,对中文读者
        // 是纯噪声(NetEase 本来就不给中文歌算 lyrics_roma,那本身就是"不需要"的信号)。
        //
        // 删掉:那道闸表达的是"我们替用户决定中文不要拼音",而现在这件事由
        // 用户自己的开关表达(上面的 romanizationAllowed,中文默认关 —— 默认行为跟以前
        // 一模一样)。留着它的话,用户明明打开了中文罗马音却什么都不会发生:绝大多数中文歌
        // 没有服务端 lyrics_roma,能出拼音的唯一途径正是这里的客户端兜底。
        //
        // songLooksJapanese 仍然要传给 romanize() —— 它决定走日语形态分析还是 ICU 音译,
        // 那是另一回事(汉字在两种语言里读音完全不同,见 Romanizer.romanize 的注释)。
        if let cached = romanizerFallbackCache[plainText] { return cached }
        // 日文行的整行读音从 segmentsCache 派生,与 wordGroups 共用同一次分词(
        // 性能审计:原来这里走 Romanizer.romanize→japaneseReading 自建一个 CFStringTokenizer,
        // 与 buildWordGroups 的 japaneseSegments 对同一行各分一遍词,日文歌 allLines 构建的
        // 分词次数直接翻倍)。两条路径的读音优先级完全一致(particleLatin > 假名标注 > 分词器
        // 转写 > 原文,尾部同走 mergeSokuon,见 Romanizer.readingFromSegments),selftest 有
        // 两者一致的断言。派生不出读音(整行拉丁/读音等于原文)时照 romanize 的原语义退到
        // ICU 音译。
        // 判定阶梯本体在 `Romanizer.lineReading`(从这里提出去),**不准在这里
        // 再写一份**:collector 侧的 `lyrics-romanize` helper 预生成 `lyrics_roma` 时走的
        // 是同一个函数,两份实现一旦漂开,同一首歌"装了缓存"和"现算"的读音就会不一样,而且
        // 不报错、只表现成用户偶尔觉得"某句罗马音怎么变了"。selftest 有闸。
        //
        // `cachedJapaneseSegments(for:)` 作为 @autoclosure 传进去,只有真的走日语分支时才
        // 求值 —— 惰性跟提取之前一模一样。
        let result = Romanizer.lineReading(
            plainText,
            songLooksJapanese: songLooksJapanese,
            segments: cachedJapaneseSegments(for: plainText))
        romanizerFallbackCache[plainText] = result
        return result
    }

    // 行文本 → 分词片段。romanizationText(整行读音兜底)和 wordGroups(逐词罗马音)各要
    // 一份同一行的分词结果,原来各自跑一遍 CFStringTokenizer —— 这里按行缓存一份共用。
    // 两个消费方的启用门**不一样**(wordGroups 要求行内有假名,整行读音只要有汉字即可,
    // 见 buildWordGroups 的 guard),所以缓存必须放在两道门之前、由各自的门决定用不用,
    // 不能拿 wordGroupCache 的结果互相顶替 —— 纯汉字的日文行那样会把整行罗马音弄丢。
    private var segmentsCache: [String: [Romanizer.JapaneseSegment]] = [:]

    /// 缓存 key 只有行文本,而片段读音还取决于 `romanizationScripts`(见 masksHanRuns)——
    /// 靠的是开关改了必然走 `load()`:它是 `LoadFingerprint` 的一部分,指纹不等就整段重跑,
    /// 这三个按行缓存一起清空。别把开关从 load 的入参里挪走,那会让这份缓存跨开关变化存活。
    private func cachedJapaneseSegments(for line: String) -> [Romanizer.JapaneseSegment] {
        if let cached = segmentsCache[line] { return cached }
        let segs = Romanizer.japaneseSegments(
            line, marks: kanaAnnotation?.marks(forLine: line) ?? [],
            songLooksJapanese: songLooksJapanese,
            hanRuns: masksHanRuns(in: line) ? .original : .latin)
        segmentsCache[line] = segs
        return segs
    }

    // 行文本 → 词组。跟 romanizerFallbackCache 同样按行缓存:同一行在播放期间会被反复
    // 查询(20Hz 定位 + 每帧填色),分词是纯 CPU 活,不该每次重算。
    private var wordGroupCache: [String: [SyncedLyricWordGroup]?] = [:]

    /// 把逐字词按读音分好组,并给每组配上罗马音——日文按分词器的片段边界并组,中文/粤语
    /// 按字数一一对应(见 buildWordGroups 的分支注释)。
    ///
    /// 日文关键点是**整行一次性分词**再按 UTF-16 范围对回去,而不是逐词单独求读音 ——
    /// 日文读音吃上下文,单独喂「明日」和放在句子里给出的读音可能不一样。
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
        // 时间轴 —— 逐词罗马音那一组从一开始就显示成已唱满(对抗审查抓出的
        // 预存在 bug,非本轮引入;segmentsCache/romanizerFallbackCache 只存文本派生物、
        // 与时间无关,仍按纯文本共享)。
        let key = "\(words[0].startMs)|\(line)"
        if let cached = wordGroupCache[key] { return cached }
        // 逐词读音受同一道按语言开关的管辖 —— 关掉某种语言的罗马音之后,逐字歌词下面
        // 也不该再标读音。哪种语言能真的标出来(日文分词 / 中文粤语一字一音节)由
        // buildWordGroups 内部按 segments/hanRomanization 是否非空决定。
        let allowed = romanizationAllowed(for: line)
        // 分词结果与 romanizationText 共用 segmentsCache;门先于分词,门不开就不白分。
        let segments: [Romanizer.JapaneseSegment]? =
            (allowed && Romanizer.looksJapanese(line)) ? cachedJapaneseSegments(for: line) : nil
        // 中文/粤语/韩语的逐字(逐词)对齐:只在这一行确证不是日文行时
        // (segments 为 nil,日文优先)才取整行罗马音——直接复用 romanizationText 那套
        // "内容匹配优先 + 时间兜底 + ICU 现算兜底"完整优先级链,不能自己另起一份简化版,
        // 否则两处一旦命中不一致,画面上会出现"整行罗马音"跟"逐字/逐词罗马音"文字对不上
        // 的诡异情况。哪种语言真能标出来(字数/词数对不对得上)由 buildWordGroups 内部判定。
        var hanRoma: String?
        var koreanRoma: String?
        if allowed, segments == nil {
            let script = Romanizer.script(ofLine: line, song: songScript)
            if script == .chinese || script == .cantonese {
                hanRoma = romanizationText(timeMs: words[0].startMs, plainText: line)
            } else if script == .korean {
                koreanRoma = romanizationText(timeMs: words[0].startMs, plainText: line)
            }
        }
        let result = Self.buildWordGroups(
            words: words, line: line, japanese: allowed,
            marks: kanaAnnotation?.marks(forLine: line) ?? [],
            segments: segments, hanRomanization: hanRoma, koreanRomanization: koreanRoma,
            songLooksJapanese: songLooksJapanese)
        wordGroupCache[key] = result
        return result
    }

    // nonisolated static:纯函数,不碰引擎自身状态,selftest 直接覆盖。
    //
    // 三条独立路径,互斥,按优先级尝试:
    // - 日文:分词器切出变长片段,片段跟逐字词的边界不对齐时把几个词并成一组
    //   (见 mergeSegmentsIntoWordGroups)——「いつか」分词器眼里是一个词,逐字数据却
    //   常常一字一词。
    // - 中文/粤语(hanRomanization):汉字没有"一个字对应半个词"的歧义,
    //   collector 生成拼音/粤拼时就是**严格一字一音节、空格分隔**(见 jyutping.go
    //   toJyutpingLine 的注释),不需要分词,直接按下标一一配对(空白词不算字、
    //   不占音节,见下面那段);字数与音节数对不上
    //   (标点/多字词等边界情形)时保守放弃,让视图退回整行罗马音,不猜、不硬凑。
    // - 韩语(koreanRomanization):跟日语一样可能有"一个词横跨好几个
    //   逐字词"的情况(酷狗式逐字切分一个谚文字一个词很常见),但韩语原文本来就按
    //   空格分词、罗马字转写保留同样的空格(见 Romanizer.koreanSegments 的实测注释),
    //   不需要跟日语一样现分词,片段直接从空格切出来,复用同一套合并算法。
    public static func buildWordGroups(
        words: [SyncedLyricWord], line: String, japanese: Bool,
        marks: [KanaAnnotation.Mark] = [],
        segments: [Romanizer.JapaneseSegment]? = nil,
        hanRomanization: String? = nil,
        koreanRomanization: String? = nil,
        songLooksJapanese: Bool = true
    ) -> [SyncedLyricWordGroup]? {
        if japanese, Romanizer.looksJapanese(line) {
            // segments 非 nil 时是调用方(引擎的 segmentsCache)预分好的同一行结果,别再分一遍。
            let segs = segments ?? Romanizer.japaneseSegments(
                line, marks: marks, songLooksJapanese: songLooksJapanese)
            return mergeSegmentsIntoWordGroups(words: words, segs: segs)
        }
        if let hanRomanization, !hanRomanization.isEmpty {
            let tokens = hanRomanization.split(separator: " ", omittingEmptySubsequences: true)
            // 空白词不参与配对。酷狗一类的逐字数据会把句中的空格切成一个
            // **独立的零时长词**,而粤拼/拼音行里空格只是音节分隔符、不产出任何音节:
            //   [149664,8560](149664,768,0)随…(151192,1496,0)荡(152688,0,0) (152688,792,0)多…
            //   ceoi4 cyu3 dong6 do1 bing1 laang5 Wooh
            // 前者 9 个词(两个是纯空格)、后者 7 个音节,按 words.count 直接比永远差这几个,
            // 整行退回整行罗马音——《喜欢你 (G.E.M.重生版)》36 行正文里 12 行栽在这上面
            // (全库扫描: 199 首粤拼歌 8395 行中 28 行)。空格不是字,本来就不该
            // 占一个音节的位置。 空白词只是不配音节,**不能从 groups 里丢掉**:它们得
            // 原样留着占位,否则画出来的词与词之间就没了那个空格(退回整行的那条路同样
            // 把空格当一个词画)。
            let sungIndices = words.indices.filter {
                !words[$0].text.trimmingCharacters(in: .whitespaces).isEmpty
            }
            guard tokens.count == sungIndices.count, !sungIndices.isEmpty else { return nil }
            var romaByIndex: [Int: String] = [:]
            for (i, token) in zip(sungIndices, tokens) { romaByIndex[i] = String(token) }
            return words.indices.map { i in
                SyncedLyricWordGroup(id: i, words: [words[i]], romanization: romaByIndex[i])
            }
        }
        if let koreanRomanization, !koreanRomanization.isEmpty,
           let segs = Romanizer.koreanSegments(line, romanization: koreanRomanization)
        {
            return mergeSegmentsIntoWordGroups(words: words, segs: segs)
        }
        return nil
    }

    /// 把"片段"(带 UTF16 范围和读音)跟逐字词按边界合并成组——日语/韩语共用同一套算法,
    /// 片段是怎么来的(分词器 vs 按空格切词)对这段逻辑透明,它只关心 UTF16 范围。
    ///
    /// 边界不对齐是常态:酷狗的逐字常常一个字一个词,而片段(日语的词/韩语的空格分词)
    /// 可能横跨好几个逐字词。所以一个片段跨过这一组的右边界时就把下一个词也吃进来
    /// (下面那段罗马音标在整组底下);反过来一个词里落进好几个片段时,把这些片段的
    /// 读音拼起来给这一个词。
    private static func mergeSegmentsIntoWordGroups(
        words: [SyncedLyricWord], segs: [Romanizer.JapaneseSegment]
    ) -> [SyncedLyricWordGroup]? {
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
            let joined = latins.isEmpty ? nil : Romanizer.joinLatin(latins)
            // 组里混进的纯拉丁词(中日韩歌词夹的英文单词)读音就是它自己 —— 跟原文一模一样
            // 没有信息增量,不该占一行重复自己。这条判据在整行罗马音那一层本来就有
            // (Romanizer.readingFromSegments 的 `joined != text`),这里是把它下沉到逐词这一级——
            // 混合语言行整行判据不会触发(韩文部分读音确实不同),必须逐组各自比对。
            let groupText = words[i...j].map(\.text).joined().trimmingCharacters(in: .whitespaces)
            let romanization = (joined == groupText) ? nil : joined
            groups.append(SyncedLyricWordGroup(
                id: groups.count,
                words: Array(words[i...j]),
                romanization: romanization))
            i = j + 1
        }
        // 一组罗马音都配不上(整行都是拉丁字母之类)时当作没有,让视图退回原来的整行罗马音。
        return groups.contains { $0.romanization != nil } ? groups : nil
    }

    // ---- 20Hz 热路径的两级省功(性能审计落地) --------------------------
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
    private var cachedNextSide: LyricDuet.Side?
    /// 前奏/间奏「•••」下方那句(没有当前行陪衬时)要按正常行的规格展示罗马音/译文——
    /// 随 text/side 同一次记忆化,不额外多扫一遍数组。
    private var cachedNextRomanization: String?
    private var cachedNextTranslation: String?
    private var cachedNextWordGroups: [SyncedLyricWordGroup]?
    // 单行展示面的「领先行」独立占一个槽:它跟 activeIdx 只在提前量窗口里
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

    // ③(审计追加)定位扫描的单调窗口记忆化:播放位置单调推进,~99% 的 tick
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
    /// 同一次定位,原来四个入口各自独立调 activeIndexCorrected 从头扫一遍(
    /// 审计:同一 tick 内 3/4 是纯重复)。这里下标只算一次,几个值一起返回。
    public struct TickResolution {
        public let index: Int?
        /// 歌词窗口的**滚动锚**下标 —— AM 的滚动先于染色(对拍):一句
        /// 唱完、下一句还没开始的空档里,页面已经滚到下一句的位置,只是还没给它染色。
        /// 染色/加粗/虚化仍看 index,滚动看这个;非空档时刻两者相等。语义见
        /// scrollLeadIndex(activeIdx:posMs:)。
        public let scrollIndex: Int?
        public let line: SyncedLyricLine?
        /// 单行展示面(灵动岛 / 菜单栏)该显示的那一行 —— 跟 line 的区别是**唱完就切走**:
        /// 本行唱完之后它指向下一句(提前量,给跟唱用),长间奏中段则是 nil。规则与两条
        /// 保守边界见 CompactLyricLead。
        ///
        /// 跟 scrollIndex 不是一回事,别合并:那个服务多行列表(间奏里有「•••」可停靠,
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
        /// compactLine **出现之后、开唱之前**那段"已显示但还没染色"的提前量(毫秒),
        /// nil = 没有可显示的行。菜单栏跑马灯拿它当"起步前至少等多久" —— 没染色就不该滚,
        /// 算法与理由见 CompactLyricLead.leadInMs。跟 compactDwellMs 同一个"出现"原点。
        public let compactLeadInMs: Int?
        public let nextText: String?
        /// 下一行摆在哪一边(见 SyncedLyricLine.side)。**独立于 `line.side` 算**——对唱歌
        /// 交替演唱时,下一句的演唱者往往跟当前句不是同一位,不能假定它继承当前行的边。
        public let nextSide: LyricDuet.Side?
        /// 下一行的罗马音/译文——跟 `line?.romanization`/`line?.translation` 同一对查找函数、
        /// 同一套语言/标签闸算出来的,不是简化版。`line` 为 nil(前奏/间奏「•••」下方没有
        /// 当前行陪衬)时,那句其实是接下来的第一句本身,该按正常行的规格展示这两项。
        public let nextRomanization: String?
        public let nextTranslation: String?
        /// 下一行的逐词分组(同 `SyncedLyricLine.wordGroups`,同一个 `wordGroups(for:line:)` 算出来)。
        /// `line` 为 nil 时悬浮歌词拿它把罗马音标到每个词底下,跟这一句变成当前行之后的排版一致。
        public let nextWordGroups: [SyncedLyricWordGroup]?
        public let gapIndex: Int?
        /// `gapIndex` 的不设门槛版本(见 `gapWindow(after:applyMinimumDuration:)`)——`line`
        /// 为 nil 时悬浮歌词拿它兜底画「•••」,不看这段间隔够不够格进歌词窗口的 `gapMarkers()`。
        public let rawGapWindow: LyricsGapWindow?
    }

    /// - Parameter trackEndMs: 这首歌有多长(毫秒)。**只**给最后一句的显示窗口兜底 ——
    ///   引擎自己不知道曲长,不给的话最后一句的 compactDwellMs 恒为 nil,得由上层退回
    ///   `currentLineDwellSeconds`。那条退路有两个毛病(审出):① 它按
    ///   `currentLineIndex` 取行,而提前量窗口里那是**已经唱完的上一句** —— 拿错基数;
    ///   ② 它的值在开唱那一刻(currentLineIndex 前进)会**突变**,于是 pacing 变、
    ///   plan 变、滚动被重装 —— 而首停含提前量,重装等于把提前量再等一遍,最后一句可能
    ///   整段唱完都不滚。喂进曲长之后最后一句的窗口也是行常量,这两件事一起消失。
    public func tickQuery(atMs rawPosMs: Int, trackEndMs: Int? = nil) -> TickResolution {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        let gap: Int?
        if let window = gapWindow(after: idx), posMs >= window.start, posMs < window.end {
            gap = idx
        } else {
            gap = nil
        }
        // 不设门槛的原始窗口,给悬浮歌词兜底用(见 TickResolution.rawGapWindow 头注)——
        // 跟 `gap` 各自独立算一遍(不是"gap 为 nil 时才算":门槛只影响 gap,不影响这个)。
        let rawGap: LyricsGapWindow?
        if let window = gapWindow(after: idx, applyMinimumDuration: false), posMs >= window.start, posMs < window.end {
            rawGap = LyricsGapWindow(startMs: window.start, endMs: window.end)
        } else {
            rawGap = nil
        }
        // 单行展示面的取词:跟上面的 index/scrollIndex 共用同一次定位,不再扫一遍数组。
        let compact = CompactLyricLead.resolve(
            activeIdx: idx, posMs: posMs,
            lineEndMs: gapLineEndMs(at: idx),
            nextStartMs: gapLineStartMs(at: idx + 1))
        let compactLine: SyncedLyricLine?
        let compactPlaceholder: Bool
        let compactDwellMs: Int?
        let compactLeadInMs: Int?
        switch compact {
        case .line(let i):
            compactLine = leadLineAt(i)
            compactPlaceholder = false
            // fallbackEndMs 只在最后一句用得上(见 displayDurationMs 的 vanish 三级兜底)。
            // 调用方给了曲长就用它 —— 见 trackEndMs 那段:不给的话最后一句要走上层那条
            // 错基数、还会在开唱那一刻突变的退路。
            compactDwellMs = gapLineStartMs(at: i).flatMap { start in
                CompactLyricLead.displayDurationMs(
                    prevLineEndMs: gapLineEndMs(at: i - 1),
                    startMs: start,
                    lineEndMs: gapLineEndMs(at: i),
                    nextStartMs: gapLineStartMs(at: i + 1),
                    fallbackEndMs: trackEndMs)
            }
            compactLeadInMs = gapLineStartMs(at: i).map { start in
                CompactLyricLead.leadInMs(prevLineEndMs: gapLineEndMs(at: i - 1), startMs: start)
            }
        case .placeholder:
            compactLine = nil
            compactPlaceholder = true
            compactDwellMs = nil
            compactLeadInMs = nil
        }
        let next = nextAt(idx + 1)
        return TickResolution(
            index: idx >= 0 ? idx : nil,
            scrollIndex: scrollLeadIndex(activeIdx: idx, posMs: posMs),
            line: lineAt(idx),
            compactLine: compactLine,
            compactPlaceholder: compactPlaceholder,
            compactDwellMs: compactDwellMs,
            compactLeadInMs: compactLeadInMs,
            nextText: next.text,
            nextSide: next.side,
            nextRomanization: next.romanization,
            nextTranslation: next.translation,
            nextWordGroups: next.wordGroups,
            gapIndex: gap,
            rawGapWindow: rawGap)
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
        nextAt(activeIndexCorrected(rawPosMs + effectiveOffsetMs) + 1).text
    }

    /// upcomingLineText 的按下标本体(记忆化缓存所在)。tickQuery 与 upcomingLineText 共用。
    ///
    /// 连同 side 一起返回:下一句预览要能独立于当前行分栏——对唱歌交替
    /// 演唱时,下一句的演唱者常常跟当前句不是同一位,悬浮窗此前把预览文字摆在跟当前句
    /// 同一边,视觉上像是同一个人接着唱下一句。side 取自跟 text 同一份 wordSides/baseSides
    /// (跟 wordLines/baseLines 逐下标对齐,见 LyricDuet.planWords/plan 的产出),不是猜的。
    private func nextAt(_ nextIdx: Int) -> (text: String?, side: LyricDuet.Side?, romanization: String?, translation: String?,
                                            wordGroups: [SyncedLyricWordGroup]?) {
        // 按下一行下标记忆化,理由同 activeLine 的缓存注释 —— 逐字路径的 map+join 拼接
        // 原来每个 tick 都重做一遍,拼的却是几十秒不变的同一句。
        if nextIdx == cachedNextIdx {
            return (cachedNextText, cachedNextSide, cachedNextRomanization, cachedNextTranslation, cachedNextWordGroups)
        }
        let text: String?
        let side: LyricDuet.Side?
        let timeMs: Int?
        if usingWords {
            text = nextIdx < wordLines.count ? wordLines[nextIdx].words.map(\.text).joined() : nil
            side = nextIdx < wordSides.count ? wordSides[nextIdx] : nil
            timeMs = nextIdx < wordLines.count ? wordLines[nextIdx].timeMs : nil
        } else {
            text = nextIdx < baseLines.count ? baseLines[nextIdx].text : nil
            side = nextIdx < baseSides.count ? baseSides[nextIdx] : nil
            timeMs = nextIdx < baseLines.count ? baseLines[nextIdx].timeMs : nil
        }
        // 跟 buildLine 共用同一对查找函数、同一套语言/标签闸——这一句一旦变成当前行,
        // 罗马音/译文该长什么样在这里就先算好了,不是另一套简化规则。
        var romanization: String?
        var translation: String?
        if let text, let timeMs {
            romanization = romanizationText(timeMs: timeMs, plainText: text)
            translation = translationText(timeMs: timeMs, plainText: text)
        }
        cachedNextIdx = nextIdx
        cachedNextText = text
        cachedNextSide = side
        cachedNextRomanization = romanization
        // 逐词分组跟 buildLine 同一个函数;时间戳只影响填色,这里只拿来排版,不用做末字压缩。
        var groups: [SyncedLyricWordGroup]?
        if usingWords, let text, nextIdx >= 0, nextIdx < wordLines.count {
            let words = wordLines[nextIdx].words.map {
                SyncedLyricWord(text: $0.text, startMs: $0.startMs, durationMs: $0.durationMs)
            }
            groups = wordGroups(for: words, line: text)
        }
        cachedNextTranslation = translation
        cachedNextWordGroups = groups
        return (text, side, romanization, translation, groups)
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

    // ---- 间奏点(歌词窗口的 Apple Music 式「•••」) --------------------

    /// 间奏判定参数。逐字歌词知道每一行唱到几点(最后一个词的结束),真实静默 ≥ minGapMs
    /// 才算间奏;行级 LRC 不知道一行唱多久,只能保守地要求两句**起点**差 ≥
    /// minPlainIntervalMs(一句歌词很少唱超过 15 秒),并假定前一句最多唱了间隔的三分之一
    /// (封顶 8 秒)。前奏单独一档:第一句开始得晚于 minIntroMs 才配一个间奏点。
    /// 窗口两端留余量:词尾后 tailMarginMs 才亮(别跟收尾的余音抢),下一句前 leadMs
    /// 熄灭(给滚动/换行让路)——leadMs 这道余量只在 `applyMinimumDuration=true`(歌词窗口)
    /// 时生效,悬浮歌词的不设门槛路径没有"下一句滚入"这回事,提前熄灭只会在熄灭到
    /// `currentLine` 真正非 nil 之间空出一段静默,见 `gapWindow(after:applyMinimumDuration:)`。
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
    /// `applyMinimumDuration` 默认 true(`GapRule` 那几道门槛,决定"值不值得在歌词窗口插一整排
    /// 三点/记进 `gapMarkers()`",连带控制 leadMs 熄灭余量)——传 false 跳过门槛+leadMs,只算
    /// geometry 本身、窗口尾部顶到下一句真正开始的时刻。悬浮歌词的兜底要这个:它没有"沿用
    /// 上一行继续显示"这条退路(`currentLine` 一旦为 nil 就必须画点什么),leadMs 这段熄灭余量
    /// 在这里只会在"点熄灭"和"下一句真正出现(`currentLine` 变回非 nil 的那一刻)"之间空出
    /// 一段静态占位的间隙——见 `rawActiveGapWindow`。
    public func gapWindow(after index: Int, applyMinimumDuration: Bool = true) -> (start: Int, end: Int)? {
        let leadMs = applyMinimumDuration ? GapRule.leadMs : 0
        if index == -1 {
            guard let first = gapLineStartMs(at: 0) else { return nil }
            // 前奏从「播放位置 0 对应的歌词时间」算起:总偏移为负(MV 扣掉片头、用户往后调)时,
            // 开头那段歌词时间是负的,窗口从 0 开始就接不住,悬浮窗会落到兜底的静态「♪」。
            let start = min(0, effectiveOffsetMs)
            if applyMinimumDuration { guard first - start >= GapRule.minIntroMs else { return nil } }
            return (start, max(start, first - leadMs))
        }
        guard let start = gapLineStartMs(at: index),
              let next = gapLineStartMs(at: index + 1) else { return nil }
        if let end = gapLineEndMs(at: index) {
            if applyMinimumDuration { guard next - end >= GapRule.minGapMs else { return nil } }
            return (end + GapRule.tailMarginMs, next - leadMs)
        }
        if applyMinimumDuration { guard next - start >= GapRule.minPlainIntervalMs else { return nil } }
        let assumedEnd = start + min((next - start) / 3, GapRule.plainAssumedSingingCapMs)
        return (assumedEnd, next - leadMs)
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

    /// `activeGapIndex` 的不设门槛版本,悬浮歌词兜底专用(见 `gapWindow(after:applyMinimumDuration:)`
    /// 头注)。`currentLine` 为 nil 时——在正常有歌词的歌里这只发生在还没唱到第一句——
    /// 这个函数给出此刻真实所在的窗口,不管它够不够格进 `gapMarkers()`。
    public func rawActiveGapWindow(atMs rawPosMs: Int) -> LyricsGapWindow? {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        guard let window = gapWindow(after: idx, applyMinimumDuration: false),
              posMs >= window.start, posMs < window.end else { return nil }
        return LyricsGapWindow(startMs: window.start, endMs: window.end)
    }
}
