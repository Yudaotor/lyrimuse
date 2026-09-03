import LyrimuseCore
import Foundation

// 罗马音 / 分词 / 繁简与异体字。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runRomanizationTests() {
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
        // 2026-08-04 曾经把"中文"默认关掉,理由是纯中文歌曲(整首歌没有任何假名)被客户端
        // 兜底越权转成拼音展示是噪声(真实回归:方大同《叫我怎么说》)。2026-08-29 用户拍板
        // 改成拼音/日语/韩语/粤拼四项默认全开("开了总开关就该都看得到,不用逐项再勾一遍")——
        // 这里验证的是新默认下拼音确实会显示,不是重新引入那次回归;用户想要"没有拼音"的
        // 观感,现在的路径是关掉"拼音"这个子开关,不是指望默认值帮他们隐藏。
        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]你好\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.activeLine(atMs: 10000)?.romanization != nil, true,
                    "SyncEngine(罗马音兜底): 默认配置(拼音默认开)下纯中文歌曲现算出拼音")
        // 关掉拼音这个子开关时,回到 2026-08-04 那条回归本来要守住的行为:纯中文歌不现算拼音。
        let engineOff = LyricsSyncEngine()
        engineOff.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true,
                       romanizationScripts: [.japanese, .korean, .cantonese])
        expectEqual(engineOff.activeLine(atMs: 10000)?.romanization, nil,
                    "SyncEngine(罗马音兜底): 关掉拼音子开关后纯中文歌曲不现算拼音")
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

    // ---- HanScript:繁简孪生写法(2026-08-18) ----
    //
    // Last.fm 统计页「第 N 次听」的前提:scrobble 是本机播放的原样镜像,同一首歌从不同
    // 播放器放、报的歌名一繁一简,Last.fm 就记成两个曲目实体、两本分开的账(《我不是农人》
    // 11 次/《我不是農人》3 次,2026-08-18 用户截图坐实)。显示端拿孪生写法再查一次求和,
    // 这里锁死孪生写法的推导规则。⚠️ 它只用于发起查询,绝不用于显示或构造 key。
    do {
        typealias H = HanScript
        let t = H.siblingPair(artist: "方大同", title: "我不是農人")
        expectEqual(t?.artist ?? "", "方大同", "孪生写法: 繁→简 歌手同形不动")
        expectEqual(t?.title ?? "", "我不是农人", "孪生写法: 繁→简 歌名")
        let s = H.siblingPair(artist: "方大同", title: "我不是农人")
        expectEqual(s?.title ?? "", "我不是農人", "孪生写法: 简→繁(ICU 挑的候选)")
        let a = H.siblingPair(artist: "陳奕迅", title: "富士山下")
        expectEqual(a?.artist ?? "", "陈奕迅", "孪生写法: 歌手名也跟着转")
        expectEqual(a?.title ?? "", "富士山下", "孪生写法: 同形歌名不动")
        expectEqual(H.siblingPair(artist: "Taylor Swift", title: "Style") == nil, true,
                    "孪生写法: 纯拉丁没有孪生")
        expectEqual(H.sibling("方大同|我不是農人") ?? "", "方大同|我不是农人",
                    "孪生写法: 拼好的 key 整串转,分隔符不动")
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

    // ---- 韩语按空格切词的片段(2026-08-29):跟日语分词器形状一致,但来源是原文自带的空格 ----
    do {
        // 单词内部(谚文字符之间)ICU 不插空格,整个词是一个片段。
        let one = Romanizer.koreanSegments("안녕하세요", romanization: "annyeonghaseyo")
        expectEqual(one?.count, 1, "韩语片段: 单词(5 个谚文字符)→ 1 个片段,内部不拆")
        expectEqual(one?.first?.latin, "annyeonghaseyo", "韩语片段: 读音就是整个词的转写")
        expectEqual(one?.first?.utf16Start, 0, "韩语片段: 起点在行首")
        expectEqual(one?.first?.utf16Length, "안녕하세요".utf16.count, "韩语片段: 长度覆盖整个词")
        // 多词按空格切,词数与罗马字词数必须一一对应、顺序不变。
        let three = Romanizer.koreanSegments("나는 너를 사랑해", romanization: "naneun neoleul salanghae")
        expectEqual(three?.map(\.latin), ["naneun", "neoleul", "salanghae"], "韩语片段: 3 词对 3 词,顺序不变")
        // 词数对不上时放弃,不猜、不错位。
        expectEqual(
            Romanizer.koreanSegments("나는 너를 사랑해", romanization: "naneun salanghae") == nil,
            true, "韩语片段: 词数(2)与原文词数(3)对不上时放弃")
        expectEqual(Romanizer.koreanSegments("", romanization: "") == nil, true, "韩语片段: 空输入放弃")
    }

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
        // 中文歌不该被标成拼音 —— japanese=false 时直接不给组(也没传 hanRomanization)。
        expectEqual(
            LyricsSyncEngine.buildWordGroups(
                words: [w("我", 0, 100), w("爱", 100, 100)], line: "我爱", japanese: false) == nil,
            true, "不是日文歌时不该分组(否则汉字会被标成拼音)")

        // ---- 中文/粤语的逐字对齐(2026-08-29):按字数与音节数一一对应,不用分词器 ----
        let yueWords = [w("你", 0, 300), w("好", 300, 300)]
        let yueGroups = LyricsSyncEngine.buildWordGroups(
            words: yueWords, line: "你好", japanese: false, hanRomanization: "nei5 hou2")
        expectEqual(yueGroups?.count, 2, "粤语: 字数与音节数相等 → 一字一组")
        expectEqual(yueGroups?.map(\.romanization), ["nei5", "hou2"], "粤语: 每组的读音跟对应的字一一配对,不串位")
        expectEqual(yueGroups?.allSatisfy { $0.words.count == 1 } ?? false, true,
                    "粤语: 中文/粤语没有日语那种多字并一组的歧义,每组恰好一个字")

        // 字数与音节数对不上时(标点/词典缺字等边界情形)保守放弃,不猜、不硬凑、不错位。
        expectEqual(
            LyricsSyncEngine.buildWordGroups(
                words: [w("你", 0, 300), w("好", 300, 300), w("！", 600, 100)],
                line: "你好！", japanese: false, hanRomanization: "nei5 hou2") == nil,
            true, "粤语: 字数(3)与音节数(2)对不上时放弃分组,退回整行罗马音")

        // 日文优先于中文/粤语:同时给了 japanese=true 且行内确实有假名时,不该被 hanRomanization
        // 抢走(理论上调用方不会真的这么传,这里验证的是函数自身的优先级顺序稳)。
        let jaWords2 = [w("こ", 0, 100), w("ん", 100, 100)]
        let jaWithHan = LyricsSyncEngine.buildWordGroups(
            words: jaWords2, line: "こん", japanese: true, hanRomanization: "wrong wrong")
        expectEqual(jaWithHan?.first?.romanization != "wrong", true,
                    "日文行不该被 hanRomanization 顶替,分词器结果优先")

        // ---- 韩语的逐词对齐(2026-08-29):像日语一样可能"一个词横跨好几个逐字词" ----
        // 酷狗式逐字切分:「나는」被拆成「나」「는」两个逐字词,罗马字词汇"naneun"要标在
        // 这两个逐字词合起来的那一组上,不是各标半个词。
        let koWords = [w("나", 0, 150), w("는", 150, 150), w(" ", 300, 0),
                       w("너", 300, 150), w("를", 450, 150)]
        let koGroups = LyricsSyncEngine.buildWordGroups(
            words: koWords, line: "나는 너를", japanese: false, koreanRomanization: "naneun neoleul")
        expectEqual(koGroups != nil, true, "韩语: 词跨多个逐字词时也该分得出组")
        if let koGroups {
            let flat = koGroups.flatMap { g in g.words.map(\.text) }.joined()
            expectEqual(flat, "나는 너를", "韩语: 分组必须完整覆盖原行、不丢字不重复")
            expectEqual(koGroups.contains { $0.words.count > 1 }, true,
                        "韩语: 「나는」这种跨多个逐字词的词必须并成一组")
            expectEqual(koGroups.map { $0.romanization }.compactMap { $0 },
                        ["naneun", "neoleul"], "韩语: 两个词各自标对读音,不串位")
        }
        // 词数对不上时保守放弃。
        expectEqual(
            LyricsSyncEngine.buildWordGroups(
                words: [w("나", 0, 150), w("는", 150, 150)],
                line: "나는", japanese: false, koreanRomanization: "naneun neoleul") == nil,
            true, "韩语: 词数(1)与罗马字词数(2)对不上时放弃分组")
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

        // 2026-08-31 加:`affects` 是「简繁转换对这段文字有没有用」的**单一真源** —— 除了
        // converted() 自己的早退,还有两个显隐判据靠它(设置页的粘性 sawChineseLyrics、悬浮窗
        // 右键菜单的逐曲 currentLyricsSupportsChineseVariant)。这一组钉的正是那条不变量:
        // **affects 为真 ⟺ converted 真的会改动**。破了它就会出现"开关不见了、歌词还在被转"
        // (或者反过来"菜单在、点了没反应"),而这两种都是用户根本无从自查的状态。
        // 2026-08-31:厂牌/平台的宣传出品语(无冒号),见 LyricsSyncEngine.matchesPromoCreditLine。
    // 用户在歌曲末尾看到「网易云音乐特别企划“星辰集”出品」被当成一句歌词。
    //
    // ⚠️ 这一组里**真歌词那半边比命中那半边重要**。判据是拿这台机器上 156433 行真实歌词量的:
    // 只要求"以出品/呈现这类角色词结尾"会命中 8 条,其中 6 条是真歌词、全部栽在「呈现」上;
    // 加上"整行含平台/厂牌词"才收敛到 2 条、0 误杀。下面把那 6 条真歌词逐条钉住 —— 谁要是
    // 以后把平台词那道闸去掉(它对出品/出版/发行/企划确实是多余的),这 6 条会立刻失败。
    expectEqual(LyricsSyncEngine.matchesPromoCreditLine("网易云音乐特别企划“星辰集”出品"), true,
                "宣传出品语: 用户报的那一行")
    expectEqual(LyricsSyncEngine.matchesPromoCreditLine("索尼唱片出版"), true,
                "宣传出品语: 厂牌+出版")
    expectEqual(LyricsSyncEngine.matchesPromoCreditLine("网易云音乐特别企划“星辰集”出品。"), true,
                "宣传出品语: 尾部标点要先剥掉")
    for real in ["下一页结局已经慢慢呈现", "少一点 完美的呈现", "机械的唇语不太够呈现",
                 "让你画面一直呈现", "发光的立体呈现", "发光的 立体呈现"] {
        expectEqual(LyricsSyncEngine.matchesPromoCreditLine(real), false,
                    "真歌词不能被吃掉(以「呈现」结尾但没有平台词): \(real)")
    }
    // 有冒号的写法归上面那两条主力规则管,这条不重复判 —— 免得同一行两条规则各说各话。
    expectEqual(LyricsSyncEngine.matchesPromoCreditLine("出品方：众乐纪"), false,
                "带冒号的交给关键词表/结构化规则,这条不认")
    // 光有平台词、不以角色词结尾的真歌词,一条都不能碰。
    expectEqual(LyricsSyncEngine.matchesPromoCreditLine("你最爱听的唱片"), false,
                "含平台词但不以角色词结尾: 真歌词")

    expectEqual(ChineseVariant.affects("这是一首简单的小情歌"), true, "affects: 纯中文")
        expectEqual(ChineseVariant.affects("First Love"), false, "affects: 纯英文没有汉字")
        expectEqual(ChineseVariant.affects(""), false, "affects: 空串")
        expectEqual(ChineseVariant.affects("君の名は"), false, "affects: 含假名判为日文")
        // 韩文歌里的汉字:`Romanizer.songScript` 会把它判成 .korean(谚文排在汉字之前),但
        // converted() 并没有谚文守卫、照样会转 —— 所以 affects 必须为真,菜单才不会"藏起来
        // 但还在转"。这条正是不能拿 songScript 当显隐判据的原因。
        expectEqual(ChineseVariant.affects("사랑 头发 노래"), true,
                    "affects: 韩文含汉字仍会被转换,判据必须为真(不能用 songScript 代替)")
        // 而且是真的会被改 —— 这条坐实"按 songScript 隐藏菜单 = 藏起来了还在转"那个风险
        // 不是理论推演:songScript 把它判成 .korean,converted 却照转不误。
        expectEqual(ChineseVariant.traditional.converted("사랑 头发 노래"), "사랑 頭髮 노래",
                    "韩文里的简体汉字确实会被转成繁体(所以菜单不能按 songScript 藏)")

        // 不变量:**affects 为假 ⟹ converted 一定不动它**。
        // ⚠️ 反方向不成立,别写成双向 —— 「漢字」本来就是繁体,affects 为真但转繁是空操作。
        // (第一版就写成了双向,被这条用例当场打回,如实记在这里免得以后有人又"修正"回去。)
        for sample in ["这是一首简单的小情歌", "First Love", "君の名は", "사랑 头发 노래",
                       "头发", "漢字", ""] {
            if !ChineseVariant.affects(sample) {
                expectEqual(ChineseVariant.traditional.converted(sample), sample,
                            "affects 为假时 converted 必须原样返回: \(sample)")
                expectEqual(ChineseVariant.simplified.converted(sample), sample,
                            "affects 为假时 converted(简) 也必须原样返回: \(sample)")
            }
        }

        // 2026-09-02 加:「简繁转换」这一项的显隐判据。不变量从「菜单显示 ⟺ 转换真的会发生」
        // 收紧成「⟺ 转换真的会发生、**而且看得见**」—— 译文那一支必须乘上"译文正在显示"。
        //
        // 起因是用户报的真实一首:米津玄师《Petrichor》,正文纯日文(带假名,affects 判 false,
        // 对的),但 enrich 缓存里带一份中文机翻 lyrics_tr(lyrics_tr_source: machine),
        // 老判据无条件把译文算进来,于是一首日文歌的悬浮窗菜单里出现了「简繁转换」。
        typealias CV = LocalPlaybackSource
        let jpLine = "これは夢かもしれない 深く霧の立ちこめた場所で"
        let cnTr = "这可能是一场梦，在雾气弥漫的地方"
        expectEqual(CV.supportsChineseVariant(lyrics: jpLine, translation: cnTr,
                                              translationVisible: false), false,
                    "显隐: 日文正文+中文译文,译文没在显示 → 不给(用户报的那一条)")
        expectEqual(CV.supportsChineseVariant(lyrics: jpLine, translation: cnTr,
                                              translationVisible: true), true,
                    "显隐: 同一首歌,译文正在显示 → 要给(那时屏幕上确实有会被转的中文)")
        expectEqual(CV.supportsChineseVariant(lyrics: jpLine, translation: "",
                                              translationVisible: true), false,
                    "显隐: 日文歌没有译文,开着显示翻译也不给")
        // 正文那一支跟译文开关**完全无关** —— 中文歌任何时候都要给。
        for visible in [true, false] {
            expectEqual(CV.supportsChineseVariant(lyrics: "这是一首简单的小情歌",
                                                  translation: "", translationVisible: visible),
                        true, "显隐: 中文正文一律要给(译文显示=\(visible))")
        }
        // 韩文歌里的汉字仍然走正文那一支(理由同上面那组:converted 没有谚文守卫、照转不误),
        // 不能因为这次收紧顺手把它也关掉。
        expectEqual(CV.supportsChineseVariant(lyrics: "사랑 头发 노래", translation: "",
                                              translationVisible: false), true,
                    "显隐: 韩文含汉字仍走正文那一支")
        expectEqual(CV.supportsChineseVariant(lyrics: "", translation: "",
                                              translationVisible: true), false,
                    "显隐: 什么都没有时不给")
        // 兜底不变量:判据为真 ⟹ 屏幕上真的有一段会被 converted 改动的文字。
        for (lyrics, tr, visible) in [(jpLine, cnTr, false), (jpLine, cnTr, true),
                                      ("这是一首简单的小情歌", "", false), (jpLine, "", true)] {
            let shown = CV.supportsChineseVariant(lyrics: lyrics, translation: tr,
                                                  translationVisible: visible)
            let visiblyChanges =
                ChineseVariant.traditional.converted(lyrics) != lyrics
                || (visible && ChineseVariant.traditional.converted(tr) != tr)
            expectEqual(shown, visiblyChanges,
                        "显隐 ⟺ 屏幕上真的有东西会变: lyrics=\(lyrics.prefix(8)) visible=\(visible)")
        }
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

    do {
        // 上面那组的另一半:名字认出来之后,还要判断"这份现在能不能直接读"。这一档判错的
        // 代价是 2026-08-24 用户在另一台机器上报的 bug —— 备份还没从 iCloud 下载下来时点
        // 「导入」,提示"等一会儿再试",但下载**从来没被发起过**,等多久都没用。
        print("\n== iCloud 备份能不能直接读(换机链路的另一半) ==")
        typealias R = ICloudFileReadiness
        expectEqual(R.isReadyToRead(downloadingStatus: .current, realPathExists: true), true,
                    "已经是最新的本地副本 → 直接读")
        expectEqual(R.isReadyToRead(downloadingStatus: .notDownloaded, realPathExists: true), false,
                    "dataless 占位(真名路径在、但还没下载)→ 先下载")
        expectEqual(R.isReadyToRead(downloadingStatus: .downloaded, realPathExists: true), false,
                    "本地有旧副本、云端有更新 → 仍然先等最新那份")
        // ↓ 这条就是修的那一档。`.<真名>.icloud` 形态下真名路径压根不存在,查状态会抛错,
        //   原来无条件当"能读",于是跳过 startDownloadingUbiquitousItem、读一个不存在的路径。
        expectEqual(R.isReadyToRead(downloadingStatus: nil, realPathExists: false), false,
                    "查不到状态且真名路径不存在 = iCloud 占位符,必须先下载")
        expectEqual(R.isReadyToRead(downloadingStatus: nil, realPathExists: true), true,
                    "查不到状态但文件就在那儿 = 普通本地文件(Dropbox/手动拷贝),能直接读")
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

        // 默认值(2026-08-29 改):四项全开——总开关一旦打开,不该还要用户逐项勾选才看得到。
        expectEqual(RomanizationScripts.default.contains(.japanese), true, "默认: 日文开")
        expectEqual(RomanizationScripts.default.contains(.korean), true, "默认: 韩文开")
        expectEqual(RomanizationScripts.default.contains(.chinese), true, "默认: 拼音开")
        expectEqual(RomanizationScripts.default.contains(.cantonese), true, "默认: 粤拼开")

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

        // 拼音默认是开的(2026-08-29 起),所以默认配置下中文歌该有服务端给的罗马音。
        expectEqual(romanization(lyrics: zhLyrics, roma: zhRoma, scripts: .default),
                    "ni dui wo xiao yi ci", "开关: 默认配置下中文歌显示服务端给的罗马音")
        // 关掉拼音这一项时,哪怕服务端给了也不显示——跟中文默认关时的既有行为一致,
        // 只是现在默认值变了,行为本身没变。
        expectEqual(romanization(lyrics: zhLyrics, roma: zhRoma, scripts: [.japanese, .korean, .cantonese]),
                    nil, "开关: 单独关掉拼音 → 中文歌没有罗马音")

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

        // ---- 「整首歌 vs 一行」:中文歌引用日文词不该让整首歌都出日文注音(2026-08-24) ----
        //
        // 用户报「怎么中文也注音了」:《这样吧》是中文歌,但引用了三次「サヨナラ」。原来的
        // 判据是"整首歌出现过一个假名就算日文",于是每行汉字都走日语形态分析 ——
        // 「就从明天开始吧」出成了「就从 mei ten 开始 吧」(mei ten = 明天的日文音读)。

        // 判据本身:含假名的**行**占比。
        expectEqual(Romanizer.kanaLineRatio("你好\n世界"), 0, "行占比: 纯中文 0%")
        expectEqual(Romanizer.kanaLineRatio("你好\nサヨナラ\n世界\n再见"), 0.25, "行占比: 4 行里 1 行有假名")
        // 空行不计入分母(歌词里空行很多)。
        expectEqual(Romanizer.kanaLineRatio("你好\n\n   \nサヨナラ"), 0.5, "行占比: 空行不进分母")
        expectEqual(Romanizer.kanaLineRatio(""), 0, "行占比: 空文本 0,不除零")

        // 真实形状:《这样吧》75 行里 3 行含假名(4.0%)→ 不是日文歌。
        let zhWithJa = (Array(repeating: "就从明天开始吧", count: 72) + Array(repeating: "サヨナラ", count: 3))
            .joined(separator: "\n")
        expectEqual(Romanizer.looksJapanese(zhWithJa), true, "旧判据: 出现过假名 → 会误判成日文")
        expectEqual(Romanizer.looksJapaneseSong(zhWithJa), false, "新判据: 4% 的行有假名 → 不是日文歌")
        expectEqual(Romanizer.songScript(of: zhWithJa), .chinese, "整首: 引用日文词的中文歌仍是中文")
        // 真·中日混唱(陶喆《My Anata》18/44 = 40.9%)同样不算日文歌 —— 它的日文行靠**按行**
        // 判定拿到罗马字,不需要把整首歌算成日文(那会连中文行一起注音)。
        let mixed = (Array(repeating: "我的あなた", count: 18) + Array(repeating: "你对我笑一次", count: 26))
            .joined(separator: "\n")
        expectEqual(Romanizer.looksJapaneseSong(mixed), false, "整首: 41% 的行有假名仍不算日文歌")
        // 真日文歌:几乎每行都含假名。
        let jaSong = Array(repeating: "こんにちは世界", count: 30).joined(separator: "\n")
        expectEqual(Romanizer.looksJapaneseSong(jaSong), true, "整首: 日文歌行行有假名 → 是日文歌")
        expectEqual(Romanizer.songScript(of: jaSong), .japanese, "整首: 日文歌 → japanese")

        // 按行判定:有假名/谚文的行按自己算,**纯汉字**行才退回整首歌。
        expectEqual(Romanizer.script(ofLine: "サヨナラ", song: .chinese), .japanese,
                    "按行: 中文歌里的假名行仍是日文")
        expectEqual(Romanizer.script(ofLine: "就从明天开始吧", song: .chinese), .chinese,
                    "按行: 中文歌里的纯汉字行是中文")
        expectEqual(Romanizer.script(ofLine: "明日", song: .japanese), .japanese,
                    "按行: 日文歌里的纯汉字行退回整首歌的判断(汉字读音中日歧义)")
        expectEqual(Romanizer.script(ofLine: "안녕", song: .japanese), .korean, "按行: 谚文行是韩文")
        expectEqual(Romanizer.script(ofLine: "Hello", song: .japanese), .other, "按行: 拉丁行不受管辖")
        // 粤语汉字跟普通话汉字长得一模一样,只能靠 song 这个外部信号分派,不能靠文字本身
        // (2026-08-29 加,拼音/粤拼拆成两个开关之后才需要区分)。
        expectEqual(Romanizer.script(ofLine: "你好", song: .cantonese), .cantonese,
                    "按行: 粤语歌里的纯汉字行是粤语,不是中文")
        expectEqual(Romanizer.script(ofLine: "サヨナラ", song: .cantonese), .japanese,
                    "按行: 粤语歌里的假名行仍是日文(假名比 song 信号更确证)")

        // ---- 引擎级端到端:同一首歌里两种行各按各的开关 ----
        func romanizationAt(
            _ ms: Int, lyrics: String, scripts: RomanizationScripts, isCantonese: Bool = false
        ) -> String? {
            let engine = LyricsSyncEngine()
            engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                        romanizationScripts: scripts, songIsCantonese: isCantonese)
            return engine.activeLine(atMs: ms)?.romanization
        }
        // 《这样吧》的形状:大量中文行 + 三行「サヨナラ」。
        var songLines: [String] = []
        for i in 0..<24 {
            songLines.append(String(format: "[%02d:%02d.00]就从明天开始吧", i / 60, i % 60))
        }
        songLines.append("[00:30.00]サヨナラ")
        let zhSongWithJa = songLines.joined(separator: "\n")
        // 中文行:关掉拼音 → 一个字都不该注音(改动前它会出「就从 mei ten 开始 吧」)。这里
        // 刻意用显式 scripts 而不是 .default(2026-08-29 起默认全开,不能再靠默认值测"关"的
        // 行为),验证的是"按行判"本身,不是默认值。
        expectEqual(romanizationAt(1_000, lyrics: zhSongWithJa, scripts: [.japanese, .korean]), nil,
                    "端到端: 关掉拼音后中文歌的中文行不注音(哪怕歌里引用了日文词)")
        // 同一首歌的日文行:日文开 → 照样出罗马字。这是「按行判」相对「按整首歌判」的全部价值。
        let jaLineRoma = romanizationAt(30_000, lyrics: zhSongWithJa, scripts: [.japanese, .korean])
        expectEqual(jaLineRoma != nil, true, "端到端: 同一首歌里引用的日文行仍出罗马字")
        expectEqual(jaLineRoma?.contains("sayonara") ?? false, true,
                    "端到端: 那一行的罗马字是 sayonara(实际 \(jaLineRoma ?? "nil"))")
        // 把拼音也打开时,中文行出的必须是**拼音**、不是日文音读。
        let zhLineRoma = romanizationAt(1_000, lyrics: zhSongWithJa,
                                        scripts: [.japanese, .korean, .chinese])
        expectEqual(zhLineRoma?.contains("mei") ?? true, false,
                    "端到端: 中文行开了注音也是拼音,不是日文音读 mei ten(实际 \(zhLineRoma ?? "nil"))")
        expectEqual(zhLineRoma?.contains("m\u{00ED}ng") ?? false, true,
                    "端到端: 中文行的注音是带声调的拼音 m\u{00ED}ng(实际 \(zhLineRoma ?? "nil"))")

        // ---- 粤拼:粤语汉字跟普通话汉字长得一样,拼音/粤拼两个开关必须各管各的(2026-08-29) ----
        let yueLyrics = "[00:01.00]你好"
        let yueRoma = "[00:01.00]nei5 hou2"
        // 先确认:不告诉引擎这是粤语歌(isCantonese 默认 false)时,粤拼开关管不到它——
        // 复用最前面定义的 romanization(不带 isCantonese 入参,固定 false)。
        expectEqual(romanization(lyrics: yueLyrics, roma: yueRoma, scripts: [.cantonese]), nil,
                    "开关: 不告诉引擎这是粤语歌(isCantonese 默认 false)时,粤拼开关管不到它")
        func yueRomanization(scripts: RomanizationScripts, isCantonese: Bool) -> String? {
            let engine = LyricsSyncEngine()
            engine.load(lyrics: yueLyrics, lyricsTr: "", lyricsRoma: yueRoma, lyricsYRC: "",
                        romanizationScripts: scripts, songIsCantonese: isCantonese)
            return engine.activeLine(atMs: 1_000)?.romanization
        }
        expectEqual(yueRomanization(scripts: [.cantonese], isCantonese: true), "nei5 hou2",
                    "开关: 粤语歌 + 粤拼开 → 显示粤拼")
        // 同一首粤语歌,只开拼音、不开粤拼 → 不该显示(两个开关必须独立,不能"是中文字就通用")。
        expectEqual(yueRomanization(scripts: [.chinese], isCantonese: true), nil,
                    "开关: 粤语歌只开拼音不开粤拼 → 不显示")
        // 反过来:同样的汉字,不是粤语歌(isCantonese=false)时按拼音开关走,粤拼开关管不着它——
        // 哪怕 lyrics_roma 里存的其实是粤拼文本,只要引擎没被告知这是粤语歌,就按拼音开关判。
        expectEqual(yueRomanization(scripts: [.cantonese], isCantonese: false), nil,
                    "开关: 普通话歌(isCantonese=false)不受粤拼开关管辖")
        expectEqual(yueRomanization(scripts: [.chinese], isCantonese: false), "nei5 hou2",
                    "开关: 普通话歌走拼音开关")

        // ---- 逐字歌词的粤拼对齐:字要跟对应的音节配成一组,不是整行摆在下面(2026-08-29) ----
        do {
            let yueYRC = "[0,1000](0,500,0)你 (500,500,0)好 \n"
            let yueRomaLRC = "[00:00.00]nei5 hou2\n"
            let engine = LyricsSyncEngine()
            engine.load(lyrics: "", lyricsTr: "", lyricsRoma: yueRomaLRC, lyricsYRC: yueYRC,
                        preferWordLevel: true, romanizationScripts: [.cantonese], songIsCantonese: true)
            let line = engine.activeLine(atMs: 200)
            expectEqual(line?.wordGroups?.count, 2, "端到端: 粤语逐字歌词能对齐出两组(一字一音节)")
            expectEqual(line?.wordGroups?.map(\.romanization), ["nei5", "hou2"],
                        "端到端: 每个字底下的粤拼是自己对应的那个音节,不是整行拼接")
            // 关掉粤拼开关时退回没有 wordGroups——视图据此退回整行罗马音,不是逐字对齐。
            let engineOff = LyricsSyncEngine()
            engineOff.load(lyrics: "", lyricsTr: "", lyricsRoma: yueRomaLRC, lyricsYRC: yueYRC,
                           preferWordLevel: true, romanizationScripts: [.chinese], songIsCantonese: true)
            expectEqual(engineOff.activeLine(atMs: 200)?.wordGroups, nil,
                        "端到端: 关掉粤拼开关后逐字歌词不再对齐出词组")
        }

        // ---- 逐字歌词的韩语对齐(2026-08-29):酷狗式一个谚文字一个逐字词,要合并成"词"再对齐 ----
        do {
            // 「안녕」两个谚文字被切成两个逐字词(酷狗式一字一词、词间**没有**空格——
            // 这两个字本来就是同一个词的两个音节块,YRC 原文里紧挨着,不像"作词 "那种
            // 后面跟真实空格的整词),罗马字("annyeong")是整个词一份、不拆开,必须合并成
            // 一组才能对上,不能各标半个读音。
            let koYRC = "[0,1000](0,150,0)안(150,150,0)녕\n"
            let koRomaLRC = "[00:00.00]annyeong\n"
            let engine = LyricsSyncEngine()
            engine.load(lyrics: "", lyricsTr: "", lyricsRoma: koRomaLRC, lyricsYRC: koYRC,
                        preferWordLevel: true, romanizationScripts: [.korean])
            let line = engine.activeLine(atMs: 100)
            expectEqual(line?.wordGroups?.count, 1, "端到端: 韩语「안녕」两个逐字词合并成一组")
            expectEqual(line?.wordGroups?.first?.words.count, 2, "端到端: 那一组里包含两个逐字词")
            expectEqual(line?.wordGroups?.first?.romanization, "annyeong",
                        "端到端: 整组标的是这个词完整的罗马字,不是拆开的半个读音")
            // 关掉韩语罗马音开关后退回没有 wordGroups。
            let engineOff = LyricsSyncEngine()
            engineOff.load(lyrics: "", lyricsTr: "", lyricsRoma: koRomaLRC, lyricsYRC: koYRC,
                           preferWordLevel: true, romanizationScripts: [.japanese])
            expectEqual(engineOff.activeLine(atMs: 100)?.wordGroups, nil,
                        "端到端: 关掉韩语罗马音开关后逐字歌词不再对齐出词组")
        }
    }

    // MARK: - HanVariants:繁简转换之外的异体字规范化
    //
    // 2026-08-22 新增。用户报「明明开了简体,歌词里还是看到繁体」——实例《开不了口 (Live)》:
    // ICU 把 37 种字符全转对了,只剩「妳」没动而它出现 21 次。「妳」不是「你」的繁体,是异体字,
    // ICU 和 OpenCC 的繁简表里都没有它(gocc 三张字典全库 grep 过,零条目)。
    do {
        typealias V = ChineseVariant

        // ① 用户那一句的原文,端到端
        expectEqual(V.simplified.converted("整個畫面是妳 想妳想到睡不著"),
                    "整个画面是你 想你想到睡不着",
                    "《开不了口》那一句:繁体字和「妳」一起收拾干净")
        expectEqual(V.simplified.converted("今天的妳過的好不好"), "今天的你过的好不好",
                    "妳 -> 你")
        expectEqual(V.simplified.converted("我一定會呵護著妳也逗妳笑"), "我一定会呵护着你也逗你笑",
                    "一行里多个「妳」全部替换")

        // ② 表里其余四个字
        expectEqual(V.simplified.converted("祂與牠"), "他与它", "祂->他、牠->它")
        expectEqual(V.simplified.converted("細雨濛濛"), "细雨蒙蒙", "濛->蒙")
        expectEqual(V.simplified.converted("痲痺"), "麻痹", "痲->麻(痺 由 ICU 转)")

        // ③ 方向性:转繁体**绝不**反推异体字(简体只有「你」,反推要猜性别)
        expectEqual(V.traditional.converted("你"), "你", "转繁体不把「你」改成「妳」")
        expectEqual(V.traditional.converted("他"), "他", "转繁体不把「他」改成「祂」")
        expectEqual(V.traditional.converted("它"), "它", "转繁体不把「它」改成「牠」")
        // 转繁体该做的事照做
        expectEqual(V.traditional.converted("头发"), "頭髮", "转繁体本身不受这层影响")

        // ④ off 一律原样
        expectEqual(V.off.converted("整個畫面是妳"), "整個畫面是妳", "不转换:连异体字也不动")

        // ⑤ 日文守卫仍然优先 —— 含假名的整段一律不碰,免得把日文汉字写坏
        expectEqual(V.simplified.converted("妳の名前"), "妳の名前",
                    "含假名:整段跳过,异体字表也不生效")

        // ⑥ 刻意**不**收的字:收了会造成误改
        expectEqual(V.simplified.converted("神祇"), "神祇", "「祇」不进表:神祇 vs 只 有歧义")
        expectEqual(V.simplified.converted("乾坤"), "乾坤", "「乾」由 ICU 按上下文保留,不进表")
        expectEqual(V.simplified.converted("我嘅"), "我嘅", "粤语字不是异体字,不能转")
        expectEqual(V.simplified.converted("咁樣"), "咁样", "粤语「咁」保留,「樣」照常转")

        // ⑦ 没命中时必须原样返回(快路径),纯拉丁/纯简体都不该被动
        expectEqual(V.simplified.converted("First Love"), "First Love", "纯拉丁不动")
        expectEqual(V.simplified.converted("这是一首简单的小情歌"), "这是一首简单的小情歌",
                    "本来就是简体:原样")

        // ⑧ 表自身的约束:异体字不能映射到自己,也不能有链式映射(A->B 且 B->C)
        var selfMapped = 0, chained = 0
        for (k, v) in HanVariants.toSimplified {
            if k == v { selfMapped += 1 }
            if HanVariants.toSimplified[v] != nil { chained += 1 }
        }
        // ⚠️ 2026-09-03 起表是**生成**的(681 条,见 HanVariants 头注),所以这两条从"逐条
        // 断言"改成"计数断言" —— 逐条会往输出里灌一千多行 ok,而要守的东西一个数字就够:
        // 映射到自己 = 无意义条目;成链 = 逐字替换只跑一遍、结果取决于遍历顺序。
        expectEqual(selfMapped, 0, "异体字表: 没有映射到自己的条目")
        expectEqual(chained, 0, "异体字表: 没有链式映射(A->B 且 B->C)")
        expectEqual(HanVariants.toSimplified.count > 100, true,
                    "异体字表: 条目数量级正常(生成产物没读空)")

        // ⑨ 逐字替换的前提:ICU 对**它确实不转的那批 key**,整条链路的产物必须等于表里的
        //    规范字。只对这一批断言,不是对全表 —— 其余条目 ICU 自己就转掉了(它们留在表里
        //    是为 collector 侧的 OpenCC 缺口服务),拿它们断言等于在断言"ICU 和 OpenCC 对
        //    每个字的选择完全一致",那是另一件事、也不成立(实测有 5 个字 ICU 会转成更生僻
        //    的字形,见 09 章)。哪些 key 属于这一批是**生成时实测**出来的(han-icu-probe.swift)。
        var icuGapChecked = 0
        for k in HanVariants.icuGaps {
            guard let want = HanVariants.toSimplified[k] else { continue }
            icuGapChecked += 1
            if V.simplified.converted(String(k)) != String(want) {
                expectEqual(V.simplified.converted(String(k)), String(want),
                            "\(k) 单字过完整链路应得到规范字 \(want)")
            }
        }
        expectEqual(icuGapChecked > 50, true,
                    "异体字表: ICU 缺口那一批有被真的核过(\(icuGapChecked) 条)")

        // ⑩ ⚠️ 跨语言防漂:collector(Go)侧 `//go:embed` 读的是同一次生成写出的
        //    dictionary/HanVariants.txt。这里直接读那份产物逐字对账 —— 两侧数据不一致的后果
        //    很隐蔽:搜索词按一套折、界面显示按另一套折,同一首歌"搜得到但显示还是繁体"
        //    (或反过来),而两边代码各自看着都对。漏跑生成器同样会在这里露馅。
        let txtURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Sources/lyrimuse-selftest
            .deletingLastPathComponent()   // …/Sources
            .deletingLastPathComponent()   // …/lyrimuse
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("lyrimuse-collector/dictionary/HanVariants.txt")
        if let txt = try? String(contentsOf: txtURL, encoding: .utf8) {
            var fromFile: [Character: Character] = [:]
            for line in txt.split(separator: "\n") {
                if line.hasPrefix("#") { continue }
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard cols.count >= 2, cols[0].count == 1, cols[1].count == 1 else { continue }
                fromFile[cols[0].first!] = cols[1].first!
            }
            expectEqual(fromFile.count, HanVariants.toSimplified.count,
                        "异体字表/跨语言: .txt 与编译进 App 的表条目数一致(不一致就是漏跑生成器)")
            expectEqual(fromFile == HanVariants.toSimplified, true,
                        "异体字表/跨语言: .txt 与编译进 App 的表逐字一致")
        } else {
            expectEqual(false, true, "异体字表/跨语言: 读不到 lyrimuse-collector/dictionary/HanVariants.txt")
        }
    }

    // ---- 整份 LRC 的罗马音预生成(2026-09-03,lyrics-romanize helper 用的那条) ----
    //
    // 这条特性的前提是"预生成的产物必须跟 App 播放时现算的逐字一致" —— 两者共用
    // `Romanizer.lineReading`(见 SourceContractTests 里那条闸)。这里测的是外面那层:
    // 时间戳保不保得住、元信息行滤不滤得掉、什么时候该返回 nil。
    do {
        // 日文:汉字必须按**日语**读,不能落成拼音。「轍」→ tetsu(拼音是 zhé)。
        let ja = LyricsRomanization.romanizeLRC(
            "[00:17.88]雨と風の吹く\n[00:21.97]轍が続いて")
        expectEqual(ja?.contains("ame") ?? false, true,
                    "整份罗马音: 日文行要出罗马字(ame …)")
        expectEqual(ja?.contains("tetsu") ?? false, true,
                    "整份罗马音: 日文歌里的汉字按日语读(轍→tetsu),不是拼音 zhé")
        expectEqual(ja?.contains("[00:17.88]") ?? false, true,
                    "整份罗马音: 时间戳原样保留")
        expectEqual(ja?.split(separator: "\n").count, 2,
                    "整份罗马音: 两行输入两行输出")

        // 中文:走 ICU 拼音。
        let zh = LyricsRomanization.romanizeLRC("[00:01.00]我爱你")
        expectEqual(zh?.contains("[00:01.00]") ?? false, true, "整份罗马音: 中文行保留时间戳")
        // ⚠️ 断言里必须**带声调符号**。第一版写的是 contains("ai") —— 当场红了:ICU 出的是
        // 带调拼音 "wǒ ài nǐ",裸 "ai" 根本不在里面。这不是实现的问题,是断言写错了,记下来
        // 免得下次有人看到红以为要去改 Romanizer。
        expectEqual(zh, "[00:01.00]wǒ ài nǐ", "整份罗马音: 中文行出带声调的拼音")

        // 纯拉丁:没有任何信息增量,整份返回 nil。
        // ⚠️ 必须是 nil 而不是空串 —— 空的 lyrics_roma 会让 LyricsSyncEngine 的
        // `romaLines.isEmpty` 判据失真,反而**关掉**客户端兜底那条路,比没有更糟。
        expectEqual(LyricsRomanization.romanizeLRC("[00:01.00]I'll be there") == nil, true,
                    "整份罗马音: 纯拉丁歌词返回 nil,不是空串")
        expectEqual(LyricsRomanization.romanizeLRC("") == nil, true,
                    "整份罗马音: 空输入返回 nil")

        // 元信息行(没有时间戳)整行跳过,不能被当成歌词注音。
        let meta = LyricsRomanization.romanizeLRC(
            "[ti:最高品質]\n[ar:9m88]\n[00:07.78]有时候要懂得闭嘴")
        expectEqual(meta?.contains("[ti:") ?? true, false,
                    "整份罗马音: [ti:] 这类元信息行不产出罗马音")
        expectEqual(meta?.split(separator: "\n").count, 1,
                    "整份罗马音: 三行里只有带时间戳那一行产出")

        // CRLF(社区上传内容常见,酷狗尤其多)不能让读音里混进看不见的 \r。
        let crlf = LyricsRomanization.romanizeLRC("[00:01.00]我爱你\r\n[00:02.00]你爱我")
        expectEqual(crlf?.contains("\r") ?? true, false,
                    "整份罗马音: CRLF 输入的产物里不该残留 \\r")
        expectEqual(crlf?.split(separator: "\n").count, 2,
                    "整份罗马音: CRLF 两行要切得开(不然整份被当成一行)")
    }
}
