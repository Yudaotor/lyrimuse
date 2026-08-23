import Foundation

// 对唱歌词的左右分栏 —— Apple Music 歌词页上那种"男声靠左、女声靠右"的排版。
//
// 数据从哪来:中文歌词源**把演唱者写在正文里当前缀**,不是独立字段(Apple 自己用的是
// TTML 的 ttm:agent,每句都有明确归属,那个源我们拿不到)。实测用户库里有**两种**写法,
// 缺一不可:
//
//   ① 行内前缀 —— 标记跟本行歌词同一行:
//        [00:21.15]男：周末守着烤箱
//        [00:25.88]情人节也落单          ← 没有前缀,归属沿用上一个标记
//   ② 独占一行 —— 标记自己占一行,歌词在下一行(实测比 ① 还多):
//        [00:24.83]周杰伦：
//        [00:26.49]没有了联络 后来的生活
//
// "一个标记管到下一个标记"是中文歌词的通行写法,所以往后延续是**读法**,不是猜测。
//
// 2026-08-23 大改。改之前只认 ① 且只认「男/女/合」这一小撮词,实测全库 938 个歌词文件里
// **只有 2 首歌真的有对唱效果**(《真爱等一下》《醉》),而且纯属巧合 —— 只有这两首的逐字
// 数据恰好是"标记跟第一个字粘成一个词"的形态。三个各自独立的漏洞:
//
//   A. **逐字路径只看第一个词**。真实 YRC 里标记会被拆开:`(881,30,0)男` `(931,20,0)：`
//      甚至 `(24838,154,0)周` `(24992,204,0)杰` `(25196,205,0)伦` `(25401,255,0)：`。
//      只看首词就永远匹配不上 `男：`。13 首带标记的歌**全部**有逐字数据,于是全部走这条路,
//      11 首直接归零(《好好说再见》LRC 里 40 个标记,走到这里剩 0 个)。
//   B. **独占一行的标记被当成没有标记**(旧 splitMarker 的 allowEmptyRest:false),
//      全库 165 处一处都不生效;更糟的是那一行还带着自己的时间戳留在歌词流里当一句词显示
//      ——实测 25 处停留超过 1 秒,《等你下课》里一行「Gary」在屏幕上挂 23.3 秒。
//   C. **只认男/女/合,不认人名**。实测库里的演唱者标记有 周杰伦/Jay/Gary/阿信/方大同/
//      杭盖/王力宏/杨瑞代/CT/MJ/巨炮/Lara/徐/黄/方/杰伦……人名才是更常见的写法。
//
// ⚠️ 逐字时间轴里剥前缀**不能按词删**:标记可能只占某个词的前半截(`男：周`),那个词扛着
// 「周」的发声时间。只能按**字符数**从词序列前端剥(见 strippingPrefix),剥到一半的词改文本、
// 保留时间戳。
public enum LyricDuet {
    /// 一行歌词摆在哪一边。
    public enum Side: String, Equatable, Sendable {
        case leading
        case trailing
        /// 合唱(两人一起)。UI 上居中,跟任何一边都区分得开。
        case center
    }

    // MARK: - 词表

    /// 明确的声部词。这些词本身没有别的意思,**单独出现就算数**,不用过下面那道整份闸。
    ///
    /// ⚠️ 这份名单必须**覆盖** LyricsSyncEngine.speakerLabels(署名过滤的豁免名单)。
    /// 两边曾经不一致:那边豁免了「男合/女合/男女/众/齐/白/旁白/念/说/对白/口白/伴唱」
    /// 这 12 个,这边一个都不认 —— 于是这些行既不会被当署名删掉(豁免了)、也不会被当
    /// 说话人剥掉前缀,原样显示成「旁白：」这种脏行。2026-08-23 补齐。
    private static let soloMarkers = [
        "男声", "女声", "男合", "女合", "男", "女", "Male", "Female", "M", "F",
    ]
    private static let groupMarkers = [
        "合唱", "齐唱", "伴唱", "男女", "合", "众", "齐",
        "白", "旁白", "念", "说", "对白", "口白",
        "Both", "All", "Duet", "Chorus", "Together",
    ]

    /// 匿名声部标记 —— 给结构化歌词源(TTML 的 `ttm:agent="v1"`)用。
    ///
    /// TTML 里演唱者只有一个 id、没有名字也没有性别,转成我们的前缀形态时就原样写 `v1：`。
    /// 收进已知词表是为了让它**直通整份闸** —— agent 是上游人工标注的权威信息,不该再拿
    /// 「≥2 个不同标签 + ≥3 处 + 有重复」那套为民间夹带设计的启发式去二次判它。
    private static let anonymousMarkers = (1...8).flatMap { ["v\($0)", "V\($0)"] }

    private static let groupMarkerSet = Set(groupMarkers)
    private static let knownMarkerSet = Set(soloMarkers + groupMarkers + anonymousMarkers)

    /// 同一位歌手的不同写法归成同一个身份。
    ///
    /// 不做归并的话「男」和「男声」会各占一个 order 席位,被当成两位不同的歌手 ——
    /// 「男 → 女 → 男声」会排成 左 → 右 → 左(第 3 位 %2==0),看着对,纯属运气;
    /// 「男 → 男声 → 女」就排成 左 → 右 → 左,同一个人被拆到两边。
    /// amll-ttml-db 的提交规范把这条写成硬要求:同一演唱者在同一首歌里必须始终同侧。
    private static let canonicalMarker: [String: String] = [
        "男声": "男", "男合": "男", "Male": "男", "M": "男",
        "女声": "女", "女合": "女", "Female": "女", "F": "女",
    ]

    private static func isGroup(_ marker: String) -> Bool { groupMarkerSet.contains(marker) }

    /// 把标记归一成"身份键"。已知声部词走上面那张表;人名原样返回。
    public static func identity(of marker: String) -> String { canonicalMarker[marker] ?? marker }

    // MARK: - 行首标签拆分

    /// 冒号左边**不允许**出现的字符:空白和标点。
    ///
    /// 这道限制是"标签"和"带冒号的歌词句子"之间唯一的形状差别。代价是像
    /// `Chris Tucker: Oh man!` 这种带空格的全名认不出来 —— 实测《You Rock My World》里
    /// 全名只各出现 1 次、缩写 `CT:`/`MJ:` 各 5 次,认缩写已经覆盖主体;放开空格换来的是
    /// 一整类英文歌词句子("Baby: I told you")被误判,不划算。
    private static let labelBreakers: Set<Character> = [
        " ", "\t", "\u{3000}",
        "，", ",", "。", ".", "！", "!", "？", "?", "；", ";",
        "（", "(", "）", ")", "[", "]", "【", "】", "「", "」", "、", "…", "—", "-",
        "\"", "'", "“", "”", "‘", "’",
    ]

    private static let maxLabelCount = 10

    /// 拆出行首的「标签 + 冒号」。
    ///
    /// **只认形状,不判断这个标签是不是演唱者** —— 那是 speakers(in:) 的整份判定要做的事,
    /// 两件事分开是这次重写的关键:旧版把"认得的词"和"是不是标记"揉在一个词表里,于是想
    /// 支持人名就只能整个放开,一放开就把「词：方文山」这类署名行也吞进来。
    ///
    /// prefixCount 是标签连同冒号、以及冒号后紧跟的空白在**原串**里占掉的字符数 ——
    /// 逐字路径按这个数字从词序列前端剥(见 strippingPrefix),所以它必须以原串为准,
    /// 不能拿 trim 过的串去算。
    public static func splitLabel(_ text: String) -> (label: String, rest: String, prefixCount: Int)? {
        var idx = text.startIndex
        // 跳过行首空白(有些源会在时间戳后面留一个空格)。
        while idx < text.endIndex, text[idx].isWhitespace { idx = text.index(after: idx) }
        let labelStart = idx
        var count = 0
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "：" || ch == ":" { break }
            if labelBreakers.contains(ch) { return nil }
            count += 1
            if count > maxLabelCount { return nil }
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex, count > 0 else { return nil }
        let label = String(text[labelStart..<idx])
        var after = text.index(after: idx) // 跳过冒号
        while after < text.endIndex, text[after].isWhitespace { after = text.index(after: after) }
        let prefixCount = text.distance(from: text.startIndex, to: after)
        return (label, String(text[after...]), prefixCount)
    }

    // MARK: - 未知标签的形状闸

    /// 人名标签里**绝不会出现**的字:代词、虚词、动词、语气词。
    ///
    /// 这是把"演唱者"和"叙事/对白句"分开的那道闸。实测挡住的真实例子:
    /// 《Wonderful Tonight》译文里的「我说：」「然后她问我：」(各出现 2~3 次,光靠重复
    /// 次数是挡不住的)、《P. Control》译文里的「她说：」「这位女子说：」。
    private static let nonNameCharacters: Set<Character> = Set(
        "我你他她它们的了着过吗呢吧啊呀哦嗯不没很就都也还又再和跟与及说问答讲道是有在会要能可想觉得看听之乎者然后最先但而且或如果因为所以这那些")

    /// 乐器/职能名的词根。署名行过滤(LyricsSyncEngine 那套)是**逐行**判的,漏网的那些
    /// 会在这里第二次被挡下来 —— 实测漏到这一层的有:乌克丽丽、喇叭、录音工程、数字编辑、
    /// 母带处理、Mellotron、Scratch、Beatbox、第一小提琴、执行制作……
    ///
    /// 跟 LyricsSyncEngine 的角色词表刻意**不共用**:那份表管的是"这行要不要删",误判会
    /// 静默吞掉真歌词;这份表管的是"这个标签算不算演唱者",误判只是少分个栏。爆炸半径不同,
    /// 这边可以放心写宽。
    private static let instrumentRoots = [
        "琴", "鼓", "号", "笛", "箫", "筝", "胡", "铃", "钹", "提琴", "吉他", "贝斯",
        "弦乐", "打击", "合成", "口琴", "竖琴", "单簧", "双簧", "萨克斯", "定音", "电子",
        "乐器", "乐团", "乐队", "编曲", "录音", "混音", "制作", "母带", "工程", "监制",
        "演出", "数字", "执行", "统筹", "企划", "发行", "出品", "作词", "作曲",
        "Scratch", "Beatbox", "Mellotron", "Sample", "Programming",
    ]

    /// **整个标签正好是这个词**才算署名 —— 只能等值比,不能包含比。
    ///
    /// 这批是单字/短词署名标签(「词：方文山」「曲：周杰伦」),用包含判定会当场误杀真人名:
    /// 「曲」是姓(曲婉婷)、「监」在名字里也出现得了。LyricsSyncEngine 那份角色词表出于
    /// 同样的理由"刻意只收双字不收单字",这里换个方式把单字补回来。
    ///
    /// 为什么非补不可(2026-08-23 实测抓到的真误判):**串烧 Live 里署名行会重复出现** ——
    /// 《夜曲+窃爱 (Live)》两首各带一份署名,于是「词」x2「曲」x2;
    /// 《大笨钟+暗号+彩虹+龙卷风 (Live)》四首串烧,「词」x4「曲」x4。两者都满足
    /// "≥2 个不同标签 + ≥3 处 + 至少一个重复",整份判据拦不住,只能在形状这一层拦。
    private static let exactCreditLabels: Set<String> = [
        "词", "詞", "曲", "编", "編", "唱", "录", "錄", "混", "监", "監", "译", "譯",
        "词曲", "詞曲", "原唱", "演唱", "歌手", "出品", "发行", "發行", "策划", "策劃",
        "翻唱", "原曲", "歌名", "歌曲", "专辑", "專輯", "标题", "標題", "歌词", "歌詞",
        "OP", "SP", "Vocal", "Lyrics", "Music", "Composer", "Arranger", "Producer",
    ]

    /// 未知标签得先长得像个名字,才有资格进入下面的计数。
    ///
    /// ⚠️ 这道形状闸必须够狠,因为下面那道整份闸是**全份一起过**的:一旦某个真演唱者把
    /// 门槛顶开,同一份里其它"长得像名字"的标签会跟着一起被收编。收编的后果不只是多分一
    /// 个栏 —— 它还会拿到署名过滤的豁免(strippingCreditLines 第一条就放行演唱者标签),
    /// 于是「和声：某某」既不会被删、又被剥掉前缀,变成一行看起来像歌词的「某某」。
    /// 2026-08-23 审查发现的活回归,靠这里的角色词否决堵住。
    private static func plausibleSpeakerName(_ label: String) -> Bool {
        if label.isEmpty || label.count > maxLabelCount { return false }
        if exactCreditLabels.contains(label) { return false }
        if exactCreditLabels.contains(label.capitalized) { return false }
        // 复用署名过滤那张角色词表(和声/监制/母带/翻译…),不再自己重复枚举。
        // 它天然放过真人名:「曲婉婷：」里「曲」虽是角色词,但正则要求它后面紧跟冒号或
        // 另一个角色词,「婉」两者都不是,整条匹配失败 —— 这正是我们想要的行为。
        if LyricsSyncEngine.matchesKeywordCreditPattern(label + "：") { return false }
        if label.contains(where: { nonNameCharacters.contains($0) }) { return false }
        // 纯数字/纯符号不是名字(「2000瓦：」这种)。
        if !label.contains(where: { $0.isLetter || $0.unicodeScalars.first?.properties.isIdeographic == true }) {
            return false
        }
        let lowered = label.lowercased()
        for root in instrumentRoots where lowered.contains(root.lowercased()) { return false }
        return true
    }

    // MARK: - 整份判定

    /// 未知标签要过的整份闸:≥2 个不同标签、合计 ≥3 处、且至少一个重复出现。
    ///
    /// 三个条件各挡一类东西,缺一不可(数字都是拿用户全库 938 个歌词文件跑出来的):
    /// - **≥2 个不同**:对唱至少两个人。挡掉《PRINCE - Love》里孤零零一个「精神富足时话由心生：」。
    /// - **合计 ≥3 处**:挡掉《好走不见》的「Rap：」+「Rap2：」(段落标记,各 1 次)、
    ///   《早上好》的「小号：」+「小打击乐器组：」(漏网署名)。
    /// - **至少一个重复**:这是最有力的一条。职员表里每个角色只出现一次
    ///   (词 1 次、曲 1 次、编曲 1 次…),而演唱者必然反复开口。挡掉《红尘客栈》那串
    ///   「执行制作/录音师/混音师/录音室/混音室」(5 个标签、5 处,但每个都只 1 次)。
    ///
    /// 实测结果:接受 20 个文件(15 首独立歌曲)全部是真对唱,拒绝的 20 个全部是署名残余
    /// 或一次性标记 —— 零误判、零漏判。
    private static let minDistinctUnknown = 2
    private static let minUnknownOccurrences = 3
    private static let minUnknownRepeat = 2

    /// 这份歌词里,哪些行首标签是演唱者。
    ///
    /// ⚠️ 必须拿**署名行过滤之前**的原始行来算,而且算出来的结果要回头喂给署名行过滤当
    /// 豁免名单(见 LyricsSyncEngine.strippingCreditLines 的 speakerExemptions):
    /// 「每一句都带人名标记」的歌(《好好说再见》53 行里 40 行)天然满足署名过滤那道
    /// "命中 ≥3 行且过半"的闸门,不豁免就是整首被删空。
    public static func speakers(in lineTexts: [String]) -> Set<String> {
        var known = Set<String>()
        var unknownCounts: [String: Int] = [:]
        for text in lineTexts {
            guard let (label, _, _) = splitLabel(text) else { continue }
            if knownMarkerSet.contains(label) {
                known.insert(label)
            } else if plausibleSpeakerName(label) {
                unknownCounts[label, default: 0] += 1
            }
        }
        var speakers = known
        if unknownCounts.count >= minDistinctUnknown,
           unknownCounts.values.reduce(0, +) >= minUnknownOccurrences,
           unknownCounts.values.contains(where: { $0 >= minUnknownRepeat })
        {
            speakers.formUnion(unknownCounts.keys)
        }
        // ⚠️ 这里**不加**"至少两个身份"的门槛。认出是说话人标记(→ 剥前缀、丢掉独占行、
        // 拿到署名过滤豁免)和判定左右,是两件独立的事:一首只在副歌标了「合：」的歌,
        // 那几行照样不该显示,但它没有"左右"可言。门槛加在 sides(for:) 里。
        return speakers
    }

    /// 至少要认出**两个能分左右的身份**,这一份才谈得上左右。
    ///
    /// 归并之后算(男/男声/男合 是同一个人),而且合唱类不算 —— 它天生居中、不占左右席位。
    /// 只认出一个身份时整首退回"没有对唱信息":
    /// - 只有「合」的歌,原来是"第一个合唱标记之后全程居中",而悬浮窗的 nil 兜底本来就是
    ///   居中 —— 等于白做,还顺带把歌词窗口从左对齐改成了居中,凭空动了排版。
    /// - 只有一位歌手的歌(TTML 规范要求**单人歌也要标** `ttm:agent="v1"`,所以这是常态),
    ///   原来会全程 `.leading`;歌词窗口兜底恰好也是 leading 看不出来,但悬浮窗兜底是
    ///   居中 —— 每一首单人歌都会莫名其妙从居中变成靠左。
    private static func hasEnoughIdentities(_ speakers: Set<String>) -> Bool {
        var solo = Set<String>()
        for m in speakers where !isGroup(m) { solo.insert(identity(of: m)) }
        return solo.count >= 2
    }

    // MARK: - 定边

    /// 给整首歌逐行定边。
    ///
    /// - 标记**向后延续**到下一个标记(见类型注释里那段真实数据)。
    /// - 左右按标记**首次出现的顺序**分,不写死性别:先出现的那位靠左。这样人名前缀也能用,
    ///   而且遇到"女声先开口"的歌不会莫名把她推到右边。
    /// - 合唱类一律居中。
    /// - 第一个标记出现之前的行(前奏,以及整首都没有标记的歌)是 **nil = 没有对唱信息**,
    ///   不是 leading。这个区分很要紧:歌词窗口的默认排版是左对齐、悬浮窗的默认排版是
    ///   居中,把"没信息"和"左边那位"混成同一个值,悬浮窗上每一首普通歌都会莫名其妙从
    ///   居中变成靠左。各视图自己决定 nil 时用什么(`?? .leading` / `?? .center`)。
    public static func sides(for markers: [String?]) -> [Side?] {
        guard hasEnoughIdentities(Set(markers.compactMap { $0 })) else {
            return markers.map { _ in nil }
        }
        var order: [String] = [] // 已出现过的独唱标记,按首次出现排
        var current: Side?
        var out: [Side?] = []
        out.reserveCapacity(markers.count)
        for marker in markers {
            if let marker {
                if isGroup(marker) {
                    current = .center
                } else {
                    // 按**身份**排席位,不是按标记原文 —— 见 canonicalMarker。
                    let marker = identity(of: marker)
                    if !order.contains(marker) { order.append(marker) }
                    // 第 1 位靠左、第 2 位靠右;第 3 位及以后(极少见)回到左边,
                    // 总比凭空造出第三种排版好。
                    current = (order.firstIndex(of: marker) ?? 0) % 2 == 0 ? .leading : .trailing
                }
            }
            out.append(current)
        }
        return out
    }

    // MARK: - 整行路径

    /// 一次算完:逐行剥掉标记、给出每行摆哪一边、以及**哪几行该整行丢掉**。
    ///
    /// dropped 是这次重写新加的:独占一行的标记(`[00:24.83]周杰伦：`)剥完什么都不剩,
    /// 它不是一句歌词,不该占着自己的时间戳在屏幕上显示。调用方按 dropped 过滤掉这些行。
    public static func plan(lineTexts texts: [String]) -> (texts: [String], sides: [Side?], dropped: [Bool]) {
        let speakerSet = speakers(in: texts)
        var outTexts: [String] = []
        var markers: [String?] = []
        var dropped: [Bool] = []
        outTexts.reserveCapacity(texts.count)
        markers.reserveCapacity(texts.count)
        dropped.reserveCapacity(texts.count)
        for text in texts {
            guard let (label, rest, _) = splitLabel(text), speakerSet.contains(label) else {
                outTexts.append(text)
                markers.append(nil)
                dropped.append(false)
                continue
            }
            outTexts.append(rest)
            markers.append(label)
            dropped.append(rest.isEmpty)
        }
        return (outTexts, sides(for: markers), dropped)
    }

    // MARK: - 逐字路径

    /// 从词序列前端剥掉 count 个字符,可以跨词。
    ///
    /// 剥到一半的词**改文本、保留时间戳** —— 它扛着后半截字的发声时间(`男：周` 里的「周」)。
    /// 整个被剥完的词才丢掉。
    static func strippingPrefix(_ words: [LyricWord], count: Int) -> [LyricWord] {
        var remaining = count
        var out = words
        while remaining > 0, let first = out.first {
            let len = first.text.count
            if len <= remaining {
                remaining -= len
                out.removeFirst()
            } else {
                let kept = String(first.text.dropFirst(remaining))
                out[0] = LyricWord(startMs: first.startMs, durationMs: first.durationMs, text: kept)
                remaining = 0
            }
        }
        // 剥完可能剩个前导空格词。
        while let first = out.first, first.text.trimmingCharacters(in: .whitespaces).isEmpty {
            out.removeFirst()
        }
        return out
    }

    /// 逐字版的 plan。
    ///
    /// ⚠️ 判定必须在**整行拼起来**的文本上做,不能只看第一个词 —— 这正是重写前那个让 11 首歌
    /// 归零的 bug:真实 YRC 里 `男：` 是 `男` + `：` 两个词,`周杰伦：` 是四个词。
    public static func planWords(_ lines: [LyricLineWords]) -> (lines: [LyricLineWords], sides: [Side?], dropped: [Bool]) {
        let joined = lines.map { $0.words.map(\.text).joined() }
        let speakerSet = speakers(in: joined)
        var outLines: [LyricLineWords] = []
        var markers: [String?] = []
        var dropped: [Bool] = []
        outLines.reserveCapacity(lines.count)
        markers.reserveCapacity(lines.count)
        dropped.reserveCapacity(lines.count)
        for (line, text) in zip(lines, joined) {
            guard let (label, rest, prefixCount) = splitLabel(text), speakerSet.contains(label) else {
                outLines.append(line)
                markers.append(nil)
                dropped.append(false)
                continue
            }
            let stripped = strippingPrefix(line.words, count: prefixCount)
            outLines.append(LyricLineWords(timeMs: line.timeMs, words: stripped))
            markers.append(label)
            dropped.append(rest.isEmpty || stripped.isEmpty)
        }
        return (outLines, sides(for: markers), dropped)
    }
}
