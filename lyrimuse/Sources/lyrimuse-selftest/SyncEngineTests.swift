import LyrimuseCore
import Foundation

// 歌词同步引擎:当前行 / 滚动 / 填色 / 提前量 / 对唱分栏。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runSyncEngineTests() {
    // ---- 间奏点(2026-08-19,歌词窗口的 Apple Music 式「•••」) ----
    do {
        let engine = LyricsSyncEngine()
        // 逐字:前奏 8s(≥5s → 标);第一句唱到 9s、第二句 25s 开始(静默 16s ≥ 6s → 标);
        // 第二句唱到 26s、第三句 28s 开始(静默 2s → 不标)。
        let yrc = "[8000,1000](8000,500,0)aa (8500,500,0)bb \n"
            + "[25000,1000](25000,500,0)cc (25500,500,0)dd \n"
            + "[28000,1000](28000,500,0)ee (28500,500,0)ff \n"
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, preferWordLevel: true)
        expectEqual(engine.gapMarkers().map(\.index), [-1, 0],
                    "间奏点: 前奏 + 第一句后各一个,静默太短的不标")
        expectEqual(engine.activeGapIndex(atMs: 3000), -1, "间奏点: 前奏进行中")
        expectEqual(engine.activeGapIndex(atMs: 8200), nil, "间奏点: 唱着的时候不算间奏(词尾余量)")
        expectEqual(engine.activeGapIndex(atMs: 15000), 0, "间奏点: 第一句唱完后的静默段")
        expectEqual(engine.activeGapIndex(atMs: 24700), nil, "间奏点: 下一句开始前 leadMs 先熄灭")
        // 行级 LRC 不知道一行唱多久:两句起点差 ≥15s 才标(宁可漏合,别在普通句间闪点)。
        let engine2 = LyricsSyncEngine()
        let lrc = "[00:01.00]aa\n[00:13.00]bb\n[00:40.00]cc\n"
        engine2.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: false)
        expectEqual(engine2.gapMarkers().map(\.index), [1], "间奏点(LRC): 只有 ≥15s 的起点差才标")
    }

    // ---- 滚动先于染色(2026-08-22,歌词窗口 AM 式提前滚动,tickQuery.scrollIndex) ----
    do {
        // 同上面间奏点块的时间轴:前奏 8s(标 -1、窗口熄于 7200);第一句 8~9s 唱完,
        // 第二句 25s 开始(长间奏,标 0、窗口 10200~24200);第二句 25~26s 唱完,
        // 第三句 28s 开始(短间隙 2s,不标)。
        let engine = LyricsSyncEngine()
        let yrc = "[8000,1000](8000,500,0)aa (8500,500,0)bb \n"
            + "[25000,1000](25000,500,0)cc (25500,500,0)dd \n"
            + "[28000,1000](28000,500,0)ee (28500,500,0)ff \n"
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, preferWordLevel: true)
        expectEqual(engine.tickQuery(atMs: 3000).scrollIndex, nil, "提前滚动: 前奏「•••」亮着时还不滚第一句")
        expectEqual(engine.tickQuery(atMs: 7500).scrollIndex, 0, "提前滚动: 前奏收尾 leadMs 先把第一句挪到常规锚位")
        expectEqual(engine.tickQuery(atMs: 8500).scrollIndex, 0, "提前滚动: 唱着的时候滚动锚=当前行")
        expectEqual(engine.tickQuery(atMs: 15000).scrollIndex, 0, "提前滚动: 长间奏点亮期间滚动停在「•••」,锚不动")
        expectEqual(engine.tickQuery(atMs: 24500).scrollIndex, 1, "提前滚动: 长间奏收尾 leadMs 先滚向下一句")
        expectEqual(engine.tickQuery(atMs: 25500).scrollIndex, 1, "提前滚动: 第二句唱着时锚=第二句")
        expectEqual(engine.tickQuery(atMs: 26500).scrollIndex, 2, "提前滚动: 短间隙里一唱完就滚向下一句")
        expectEqual(engine.tickQuery(atMs: 26500).index, 1, "提前滚动: 同一时刻染色下标还停在唱完的那行")
        expectEqual(engine.tickQuery(atMs: 28500).scrollIndex, 2, "提前滚动: 最后一行没有下一句,锚=当前行")
        // 行级 LRC 不知道一行唱到几点,短间隙不抢跑(两个下标恒等,行为与改动前一致)。
        let engine2 = LyricsSyncEngine()
        let lrc = "[00:01.00]aa\n[00:05.00]bb\n"
        engine2.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: false)
        expectEqual(engine2.tickQuery(atMs: 3000).scrollIndex, 0, "提前滚动(LRC): 行级不知道唱完时刻,不抢跑")
        expectEqual(engine2.tickQuery(atMs: 3000).index, 0, "提前滚动(LRC): 两个下标一致")
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

    // ---- LyricsSyncEngine: 热路径记忆化(2026-08-19 性能审计落地) ----
    // activeLine/upcomingLineText 按行下标缓存构建结果(20Hz 的 fastTick 约 99% 的调用命中
    // 同一行)。这里钉住两条不变量:①记忆化不改变语义 —— 行内反复查询、跨行、倒回都跟
    // 无缓存时逐字一致;②load() 换歌词内容后缓存必须失效 —— 新歌同一个下标是完全不同的
    // 内容,忘了失效会把上一首歌的行返回出去。

    do {
        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]第一句\n[00:20.00]第二句\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.activeLine(atMs: 12000)?.mainText, "第一句", "SyncEngine(记忆化): 首次查询正常构建")
        expectEqual(engine.activeLine(atMs: 13000)?.mainText, "第一句", "SyncEngine(记忆化): 同一行内反复查询命中缓存,内容不变")
        expectEqual(engine.activeLine(atMs: 21000)?.mainText, "第二句", "SyncEngine(记忆化): 跨到下一行后缓存随下标失效")
        expectEqual(engine.activeLine(atMs: 5000)?.mainText, nil, "SyncEngine(记忆化): 倒回第一句之前(下标 -1)同样正确")
        expectEqual(engine.upcomingLineText(afterMs: 12000), "第二句", "SyncEngine(记忆化): 下一行预览正常")
        expectEqual(engine.upcomingLineText(afterMs: 21000), nil, "SyncEngine(记忆化): 最后一行之后没有下一句")
        expectEqual(engine.upcomingLineText(afterMs: 12000), "第二句", "SyncEngine(记忆化): 倒回后下一行缓存随下标失效")
    }

    do {
        let engine = LyricsSyncEngine()
        engine.load(lyrics: "[00:10.00]旧歌词\n", lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.activeLine(atMs: 15000)?.mainText, "旧歌词", "SyncEngine(记忆化): 换歌前正常")
        expectEqual(engine.upcomingLineText(afterMs: 5000), "旧歌词", "SyncEngine(记忆化): 换歌前下一行预览正常")
        engine.load(lyrics: "[00:10.00]新歌词\n", lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.activeLine(atMs: 15000)?.mainText, "新歌词", "SyncEngine(记忆化): load 换内容后同一下标的行缓存必须失效")
        expectEqual(engine.upcomingLineText(afterMs: 5000), "新歌词", "SyncEngine(记忆化): load 换内容后下一行缓存同样失效")
    }

    // ---- KaraokeFill.lineFillSettledMs: 整行填色定格时刻(悬浮歌词行尾停表用) ----
    // 阈值 = startMs + 有效时长 × (1 + wordEdgeSoftenBand),整行取所有词/组的最大值。
    // 词:(1000, 500) → 1000 + ceil(500×1.08) = 1540;极短词吃 minWordDurationMs(80)地板:
    // (1000, 10) → 1000 + ceil(80×1.08) = 1087;逐词罗马音按整组伪词(跨度可能远大于单词)
    // 填色,组也要算进最大值,否则罗马音还在填、行就被提前定格。

    do {
        let w1 = SyncedLyricWord(text: "aa", startMs: 1000, durationMs: 500)
        let w2 = SyncedLyricWord(text: "bb", startMs: 1500, durationMs: 500)
        expectEqual(KaraokeFill.lineFillSettledMs(words: [w1], groups: nil), 1540,
                    "lineFillSettledMs: 单词阈值 = start + 时长×(1+软化带)")
        expectEqual(KaraokeFill.lineFillSettledMs(words: [SyncedLyricWord(text: "a", startMs: 1000, durationMs: 10)], groups: nil), 1087,
                    "lineFillSettledMs: 极短词按 minWordDurationMs 地板算")
        expectEqual(KaraokeFill.lineFillSettledMs(words: [w1, w2], groups: nil), 2040,
                    "lineFillSettledMs: 整行取所有词的最大值")
        let group = SyncedLyricWordGroup(id: 0, words: [w1, w2], romanization: "aabb")
        expectEqual(KaraokeFill.lineFillSettledMs(words: [w1, w2], groups: [group]), 2080,
                    "lineFillSettledMs: 整组伪词(跨度 1000)的阈值 2080 盖过词级最大值 2040")
    }

    // ---- LyricDuet: 对唱歌词的左右分栏(2026-08-14) ----
    //
    // 用例全部照真实数据写:演唱者信息是**塞在正文里的前缀**(男：/女：/合：),而且只有部分行
    // 带标记(《真爱等一下 (feat. 蔡健雅)》65 行里 22 行),其余按"一个标记管到下一个标记"延续。
    do {
        let D = LyricDuet.self

        // ---- splitLabel: 只认形状,不判断这个标签是不是演唱者 ----
        expectEqual(D.splitLabel("男：周末守着烤箱")?.label, "男", "对唱: 全角冒号识别")
        expectEqual(D.splitLabel("男：周末守着烤箱")?.rest, "周末守着烤箱", "对唱: 前缀从正文里剥掉")
        expectEqual(D.splitLabel("女: 偏爱年轻女伴")?.rest, "偏爱年轻女伴", "对唱: 半角冒号+空格")
        expectEqual(D.splitLabel("合：何时想戒掉流浪")?.label, "合", "对唱: 合唱标记")
        expectEqual(D.splitLabel("男声：测试")?.rest, "测试", "对唱: 标签整段取到冒号(男声 不是 男+声)")
        expectEqual(D.splitLabel("情人节也落单") == nil, true, "对唱: 无冒号的行没有标签")
        // 标签里不许有空白/标点 —— 这是"标签"跟"带冒号的歌词句子"唯一的形状差别
        expectEqual(D.splitLabel("Baby, I said: hello") == nil, true, "对唱: 含标点的长句不是标签")
        expectEqual(D.splitLabel("Chris Tucker: Oh man") == nil, true, "对唱: 含空格的全名不当标签(已知取舍)")
        expectEqual(D.splitLabel("一二三四五六七八九十一：x") == nil, true, "对唱: 标签超过 10 字不认")
        // prefixCount 以**原串**为准(逐字路径按它跨词剥),含冒号和冒号后的空格
        expectEqual(D.splitLabel("男：周末")?.prefixCount, 2, "对唱: prefixCount 含冒号")
        expectEqual(D.splitLabel("女: 偏爱")?.prefixCount, 3, "对唱: prefixCount 含冒号后空格")

        // ---- speakers(in:): 整份判定,已知声部词直通、人名要过闸 ----
        // 已知声部词单独出现就算数
        expectEqual(D.speakers(in: ["男：一", "女：二"]), Set(["男", "女"]), "对唱: 男/女 直接算演唱者")
        // 署名行不算 —— 「词/曲」既不是已知声部词,也过不了下面那道闸
        expectEqual(D.speakers(in: ["词：葛大为", "曲：陶喆/蔡健雅", "真歌词"]).isEmpty, true,
                    "对唱: 一次性的署名标签不算演唱者")
        // 人名标记:≥2 个不同 + 合计 ≥3 处 + 至少一个重复,三条都满足才算
        do {
            // 《圣诞星》的真实形态:周杰伦 x2 + 杨瑞代 x1
            let s = D.speakers(in: ["周杰伦：", "一", "杨瑞代：", "二", "周杰伦：", "三"])
            expectEqual(s, Set(["周杰伦", "杨瑞代"]), "对唱: 人名标记过闸(2 个/3 处/有重复)")
        }
        do {
            // 《好走不见》的真实形态:Rap x1 + Rap2 x1 —— 段落标记,只有 2 处,不该算
            let s = D.speakers(in: ["Rap：", "一", "Rap2：", "二"])
            expectEqual(s.isEmpty, true, "对唱: 只有 2 处的一次性标记不算")
        }
        do {
            // 《红尘客栈》的真实形态:5 个标签各 1 次 —— 职员表,每个角色只出现一次
            let s = D.speakers(in: ["执行制作：甲", "录音师：乙", "混音师：丙", "录音室：丁", "混音室：戊", "歌词"])
            expectEqual(s.isEmpty, true, "对唱: 都不重复的多标签是职员表,不是对唱")
        }
        do {
            // 《Wonderful Tonight》译文的真实形态:「我说」x3 +「然后她问我」x2 —— 计数够,
            // 但它们是叙事句不是名字,靠 nonNameCharacters 挡住
            let s = D.speakers(in: ["我说：是的", "然后她问我：好吗", "我说：好", "然后她问我：真的", "我说：真的"])
            expectEqual(s.isEmpty, true, "对唱: 含代词/动词的叙事标签不是演唱者")
        }
        do {
            // 漏网的乐器署名:计数可能凑够,但词根挡住
            let s = D.speakers(in: ["小号：涂", "小打击乐器组：Joni", "小号：涂"])
            expectEqual(s.isEmpty, true, "对唱: 乐器/职能词根不是演唱者")
        }
        do {
            // 串烧 Live 的真实形态(《大笨钟+暗号+彩虹+龙卷风 (Live)》):每首各带一份署名,
            // 于是「词」x4「曲」x4 —— 计数三条全过,只能靠 exactCreditLabels 在形状这层拦。
            // 这条是回归护栏:2026-08-23 第一版漏了单字署名词,全库扫描当场抓到两首串烧被误判。
            let s = D.speakers(in: [
                "词：方文山", "曲：周杰伦", "歌词一",
                "词：方文山", "曲：周杰伦", "歌词二",
                "词：黄俊郎", "曲：周杰伦", "歌词三",
                "词：方文山", "曲：周杰伦", "歌词四",
            ])
            expectEqual(s.isEmpty, true, "对唱: 串烧 Live 里重复出现的单字署名词不是演唱者")
        }
        do {
            // 反例:单字署名词只能**等值**排除 ——「曲」是姓,「曲婉婷」得照样认出来
            let s = D.speakers(in: ["曲婉婷：一", "李健：二", "曲婉婷：三"])
            expectEqual(s, Set(["曲婉婷", "李健"]), "对唱: 姓「曲」的人名不被单字署名词误杀")
        }
        do {
            // 整份闸是全份一起过的:真演唱者把门槛顶开之后,同一份里的署名残余不能跟着被收编。
            // 收编 = 拿到署名过滤豁免 = 那行既不被删、又被剥掉前缀,变成一行假歌词「某某」。
            // 2026-08-23 审查发现的活回归,回归护栏。
            let s = D.speakers(in: [
                "周杰伦：", "一", "阿信：", "二", "周杰伦：", "三",
                "和声：陈某某", "监制：李某某", "母带处理：王某某",
            ])
            expectEqual(s, Set(["周杰伦", "阿信"]),
                        "对唱: 真演唱者顶开门槛后,同份里的署名残余不被连带收编")
        }

        // 标记向后延续 + 按出现顺序分左右(不写死性别)
        do {
            let markers: [String?] = [nil, "男", nil, nil, "女", nil, "合", nil, "男"]
            let sides = D.sides(for: markers)
            expectEqual(sides[0], nil, "对唱: 第一个标记之前没有对唱信息(不是靠左)")
            expectEqual(sides[1], .leading, "对唱: 先出现的那位靠左")
            expectEqual(sides[2], .leading, "对唱: 标记向后延续")
            expectEqual(sides[3], .leading, "对唱: 标记继续延续")
            expectEqual(sides[4], .trailing, "对唱: 第二位靠右")
            expectEqual(sides[5], .trailing, "对唱: 第二位的延续")
            expectEqual(sides[6], .center, "对唱: 合唱居中")
            expectEqual(sides[7], .center, "对唱: 合唱也向后延续")
            expectEqual(sides[8], .leading, "对唱: 回到第一位仍然靠左")
        }
        // 女声先开口的歌:靠左的是**她**,不是按性别写死
        do {
            let sides = D.sides(for: ["女", "男"])
            expectEqual(sides[0], .leading, "对唱: 女声先开口时她靠左")
            expectEqual(sides[1], .trailing, "对唱: 后出现的男声靠右")
        }
        // 同义归并:同一位歌手的两种写法必须始终同侧(amll-ttml-db 提交规范的硬要求)
        do {
            expectEqual(D.identity(of: "男声"), "男", "对唱身份: 男声 归并成 男")
            expectEqual(D.identity(of: "男合"), "男", "对唱身份: 男合 归并成 男")
            expectEqual(D.identity(of: "Female"), "女", "对唱身份: Female 归并成 女")
            expectEqual(D.identity(of: "周杰伦"), "周杰伦", "对唱身份: 人名原样")
            let sides = D.sides(for: ["男", "男声", "女"])
            expectEqual(sides[0], .leading, "对唱身份: 男 靠左")
            expectEqual(sides[1], .leading, "对唱身份: 男声 跟 男 同一个人,还是靠左")
            expectEqual(sides[2], .trailing, "对唱身份: 女 才是第二位,靠右")
        }
        // 补齐 speakerLabels 缺的那 12 个 —— 它们此前既不被删也不被认,原样显示成脏行
        do {
            let s = D.speakers(in: ["旁白：从前有座山", "男：一", "女：二", "口白：完"])
            expectEqual(s.contains("旁白"), true, "对唱: 旁白 是认得的声部词")
            expectEqual(s.contains("口白"), true, "对唱: 口白 是认得的声部词")
            let sides = D.sides(for: ["旁白", "男", "女"])
            expectEqual(sides[0], .center, "对唱: 口白类居中,不占左右席位")
            expectEqual(sides[1], .leading, "对唱: 口白之后 男 仍是第一位")
            expectEqual(sides[2], .trailing, "对唱: 女 是第二位")
        }
        // 身份数下限:少于两个能分左右的身份,整首不判左右(丢行/剥前缀照旧,那是另一件事)
        do {
            expectEqual(D.sides(for: ["合", nil, "合"]).compactMap { $0 }.isEmpty, true,
                        "对唱: 只有合唱标记时没有左右可言")
            expectEqual(D.sides(for: ["男", nil, "男"]).compactMap { $0 }.isEmpty, true,
                        "对唱: 只有一位歌手时不判左右(否则单人歌在悬浮窗上会从居中变靠左)")
            expectEqual(D.sides(for: ["男", "合", "男"]).compactMap { $0 }.isEmpty, true,
                        "对唱: 一位歌手 + 合唱仍然不够两个身份")
            expectEqual(D.sides(for: ["v1", nil, "v2"])[2], .trailing,
                        "对唱: TTML 的匿名声部 v1/v2 是认得的身份")
            expectEqual(D.speakers(in: ["v1：一", "v2：二"]), Set(["v1", "v2"]),
                        "对唱: 匿名声部直通整份闸(agent 是上游权威标注)")
        }
        // 剥离与定边是两件事:身份不够也照样剥前缀、丢独占行
        do {
            let plan = D.plan(lineTexts: ["合：", "何时想戒掉流浪", "普通一行"])
            expectEqual(plan.dropped, [true, false, false], "对唱: 身份不够也照样丢掉独占标记行")
            expectEqual(plan.sides.compactMap { $0 }.isEmpty, true, "对唱: 但不判左右")
        }
        // group 不参与左右交替(AMLL 同款):「男-合-女」不能因为中间的合唱把侧算反
        do {
            let sides = D.sides(for: ["男", "合", "女", "合", "男"])
            expectEqual(sides[0], .leading, "对唱: 男 靠左")
            expectEqual(sides[1], .center, "对唱: 合 居中")
            expectEqual(sides[2], .trailing, "对唱: 合唱不打乱交替,女 仍是第二位靠右")
            expectEqual(sides[4], .leading, "对唱: 回到男 仍靠左")
        }
        // 整首没有标记的歌:全是 nil。这一条是**回归护栏** —— 混成 .leading 的话,悬浮窗上
        // 每一首普通歌都会从居中变成靠左。
        do {
            let sides = D.sides(for: [nil, nil, nil])
            expectEqual(sides.compactMap { $0 }.isEmpty, true, "对唱: 没有标记的歌全程无对唱信息")
        }
        // plan:剥正文 + 定边 + 标出该丢的行,一次算完
        do {
            let plan = D.plan(lineTexts: ["男：周末守着烤箱", "情人节也落单", "女：偏爱年轻女伴"])
            expectEqual(plan.texts, ["周末守着烤箱", "情人节也落单", "偏爱年轻女伴"], "对唱: plan 剥掉全部前缀")
            expectEqual(plan.sides, [.leading, .leading, .trailing], "对唱: plan 定边")
            expectEqual(plan.dropped, [false, false, false], "对唱: 行内前缀不丢行")
        }
        // 独占一行的标记(《说好不哭》的真实形态):剥完为空 → 整行丢掉,但**归属照样延续**
        do {
            let plan = D.plan(lineTexts: ["周杰伦：", "没有了联络", "阿信：", "电话开始躲", "周杰伦：", "你什么都没有"])
            expectEqual(plan.dropped, [true, false, true, false, true, false], "对唱: 独占标记行整行丢掉")
            expectEqual(plan.sides, [.leading, .leading, .trailing, .trailing, .leading, .leading],
                        "对唱: 独占标记的归属延续到下一个标记")
            expectEqual(plan.texts[1], "没有了联络", "对唱: 独占标记的下一行正文不受影响")
        }

        // ---- planWords: 逐字路径。标记在真实 YRC 里会被拆成好几个词 ----
        func w(_ start: Int, _ dur: Int, _ t: String) -> LyricWord {
            LyricWord(startMs: start, durationMs: dur, text: t)
        }
        do {
            // 《好好说再见》的真实形态:`(881,30)男` `(911,40)：` `(951,..)我` ——
            // 标记独立成词、冒号又是另一个词。旧实现只看第一个词,"男" 匹配不上 "男："。
            let lines = [
                LyricLineWords(timeMs: 881, words: [w(881, 30, "男"), w(911, 40, "："), w(951, 200, "我"), w(1151, 200, "爱")]),
                LyricLineWords(timeMs: 31038, words: [w(31038, 170, "女"), w(31208, 170, "："), w(31378, 200, "时"), w(31578, 200, "间")]),
            ]
            let plan = D.planWords(lines)
            expectEqual(plan.lines[0].words.map(\.text), ["我", "爱"], "对唱逐字: 标记独立成词也能剥掉")
            expectEqual(plan.lines[0].words[0].startMs, 951, "对唱逐字: 剥完首词的时间戳是真正第一个字的")
            expectEqual(plan.sides, [.leading, .trailing], "对唱逐字: 定边")
            expectEqual(plan.dropped, [false, false], "对唱逐字: 有正文的行不丢")
        }
        do {
            // 粘连形态:`男：周` 是一个词,扛着「周」的发声时间 —— 只能改文本,不能删词
            let lines = [
                LyricLineWords(timeMs: 21155, words: [w(21155, 180, "男：周"), w(21335, 320, "末")]),
                LyricLineWords(timeMs: 40310, words: [w(40310, 180, "女：偏"), w(40490, 320, "爱")]),
            ]
            let plan = D.planWords(lines)
            expectEqual(plan.lines[0].words.map(\.text), ["周", "末"], "对唱逐字: 粘连形态只改文本不删词")
            expectEqual(plan.lines[0].words[0].startMs, 21155, "对唱逐字: 粘连词保留原时间戳")
            expectEqual(plan.lines[0].words[0].durationMs, 180, "对唱逐字: 粘连词保留原时长")
        }
        do {
            // 人名逐字拆开 + 独占一行:`周` `杰` `伦` `：` 整行剥空 → 丢掉
            let lines = [
                LyricLineWords(timeMs: 24838, words: [w(24838, 154, "周"), w(24992, 204, "杰"), w(25196, 205, "伦"), w(25401, 255, "：")]),
                LyricLineWords(timeMs: 26499, words: [w(26499, 203, "没"), w(26702, 255, "有")]),
                LyricLineWords(timeMs: 113700, words: [w(113700, 200, "阿"), w(113900, 200, "信"), w(114100, 200, "：")]),
                LyricLineWords(timeMs: 114800, words: [w(114800, 200, "电"), w(115000, 200, "话")]),
                LyricLineWords(timeMs: 172200, words: [w(172200, 154, "周"), w(172354, 204, "杰"), w(172558, 205, "伦"), w(172763, 255, "：")]),
                LyricLineWords(timeMs: 173500, words: [w(173500, 200, "你"), w(173700, 200, "什")]),
            ]
            let plan = D.planWords(lines)
            expectEqual(plan.dropped, [true, false, true, false, true, false], "对唱逐字: 独占标记行整行丢掉")
            expectEqual(plan.sides, [.leading, .leading, .trailing, .trailing, .leading, .leading],
                        "对唱逐字: 人名标记的归属延续")
            expectEqual(plan.lines[1].words.map(\.text), ["没", "有"], "对唱逐字: 正文行不受影响")
        }
        do {
            // 回归护栏:普通歌(没有任何标记)逐字路径一个词都不能少
            let lines = [
                LyricLineWords(timeMs: 1000, words: [w(1000, 200, "情"), w(1200, 200, "人")]),
                LyricLineWords(timeMs: 2000, words: [w(2000, 200, "节"), w(2200, 200, "也")]),
            ]
            let plan = D.planWords(lines)
            expectEqual(plan.lines.map { $0.words.map(\.text) }, [["情", "人"], ["节", "也"]], "对唱逐字: 普通歌原样不动")
            expectEqual(plan.dropped, [false, false], "对唱逐字: 普通歌一行不丢")
            expectEqual(plan.sides.compactMap { $0 }.isEmpty, true, "对唱逐字: 普通歌没有对唱信息")
        }
    }

    // ---- KaraokeFill ----
    //
    // 逐字填色的数值部分。这段算法之前混在 LyricsOverlayView 里，每次改都只能盯着屏幕看
    // 对不对；下面每一条都对应一个真出过的 bug。
    do {
        func word(_ start: Int, _ dur: Int) -> SyncedLyricWord {
            SyncedLyricWord(text: "x", startMs: start, durationMs: dur)
        }
        func rounded(_ stops: [KaraokeFill.Stop]) -> [[Double]] {
            stops.map { [($0.location * 10000).rounded() / 10000, ($0.intensity * 10000).rounded() / 10000] }
        }

        // fillFraction 故意**不**夹到 [0,1]：夹住的话，一句里所有还没唱到的字都会得到 0，
        // 跟"刚好唱到最前一刻"无法区分，于是每个未唱字的开头都会冒出一小截高亮。
        expectEqual(KaraokeFill.fillFraction(for: word(1000, 500), atMs: 0) < 0, true,
                    "KaraokeFill: 还没唱到的字必须给负数,不能夹成 0")
        expectEqual(KaraokeFill.fillFraction(for: word(1000, 500), atMs: 2000) > 1, true,
                    "KaraokeFill: 早就唱完的字必须大于 1")
        expectEqual(KaraokeFill.fillFraction(for: word(1000, 500), atMs: 1250), 0.5,
                    "KaraokeFill: 正中间是 0.5")

        // durationMs=0 的极短词（英文歌词常见）按下限算，否则瞬间 0→1 会很跳。
        expectEqual(KaraokeFill.fillFraction(for: word(0, 0), atMs: 40), 0.5,
                    "KaraokeFill: durationMs=0 按 minWordDurationMs 下限算")

        // 离得远的字：整片暗色，不能有任何过渡带残留。
        expectEqual(rounded(KaraokeFill.stops(left: -0.5, right: -0.34)),
                    [[0, 0], [1, 0]], "KaraokeFill: 还没唱到 → 整片暗色")
        // 唱完很久的字：整片亮色。
        expectEqual(rounded(KaraokeFill.stops(left: 1.2, right: 1.36)),
                    [[0, 1], [1, 1]], "KaraokeFill: 早就唱完 → 整片亮色")

        // 正常中间态：亮 → 过渡 → 暗，四个分段点。
        expectEqual(rounded(KaraokeFill.stops(left: 0.2, right: 0.36)),
                    [[0, 1], [0.2, 1], [0.36, 0], [1, 0]],
                    "KaraokeFill: 中间态四个分段点")

        // 过渡带跨过左边界：0 这一点的强度要**现算**，不能硬写成 1 —— 否则 0 处同时存在
        // 强度 1 和过渡带算出的另一个值，渲染时互相抢占，边界会闪。
        expectEqual(rounded(KaraokeFill.stops(left: -0.05, right: 0.11)),
                    [[0, 0.6875], [0.11, 0], [1, 0]],
                    "KaraokeFill: 过渡带跨左边界时 0 处强度要现算")
        // 跨右边界同理。
        expectEqual(rounded(KaraokeFill.stops(left: 0.95, right: 1.11)),
                    [[0, 1], [0.95, 1], [1, 0.6875]],
                    "KaraokeFill: 过渡带跨右边界时 1 处强度要现算")

        // 全局不变式，扫一遍整个进度区间：
        //   ① location 单调不减 —— 这正是网页端"提前上色"那个 bug 的判据（渐变 stop 一旦
        //      逆序，渲染层会把它钳回去，视觉上表现为颜色跑到前面去了）
        //   ② location 始终落在 [0,1]
        //   ③ intensity 始终落在 [0,1]
        //   ④ 强度沿着位置单调不增（唱过的在左边，越往右越暗）
        var monotonic = true, inRange = true, intensityOK = true, intensityDesc = true
        for step in -30...130 {
            let fraction = Double(step) / 100
            let s = KaraokeFill.stops(left: fraction - KaraokeFill.wordEdgeSoftenBand,
                                      right: fraction + KaraokeFill.wordEdgeSoftenBand)
            for (i, stop) in s.enumerated() {
                if stop.location < 0 || stop.location > 1 { inRange = false }
                if stop.intensity < 0 || stop.intensity > 1 { intensityOK = false }
                if i > 0 {
                    if stop.location < s[i - 1].location - 1e-12 { monotonic = false }
                    if stop.intensity > s[i - 1].intensity + 1e-12 { intensityDesc = false }
                }
            }
        }
        expectEqual(monotonic, true, "KaraokeFill: stop 位置始终单调不减(逆序=提前上色)")
        expectEqual(inRange, true, "KaraokeFill: stop 位置始终在 [0,1]")
        expectEqual(intensityOK, true, "KaraokeFill: 强度始终在 [0,1]")
        expectEqual(intensityDesc, true, "KaraokeFill: 强度沿位置单调不增")
    }

    // ---- 末字填色必须在换行前填满(2026-08-19) ----
    //
    // 用户报「主动调过某首歌的歌词延迟之后,每句歌词最后一点不走完就下一句」。查下来跟偏移
    // 无关(引擎判行和四处填色加的是同一个 offsetMs),是歌词数据本身:"填满"的时刻是
    // 字.start+字.duration,"换行"的时刻是下一行的 timeMs,两个独立的数字。全库实测
    // 667 首/37610 行:25.9% 正好相等、3.0% 真越过、12.2% 余量不足 120ms —— 合计约四成。

    do {
        let lead = KaraokeFill.lineTailLeadMs      // 140
        let floorMs = KaraokeFill.minTailFillMs    // 120
        func words(_ specs: [(String, Int, Int)]) -> [SyncedLyricWord] {
            specs.map { SyncedLyricWord(text: $0.0, startMs: $0.1, durationMs: $0.2) }
        }
        func tail(_ ws: [SyncedLyricWord], _ next: Int?) -> [Int] {
            KaraokeFill.tailClamped(ws, nextLineStartMs: next).map(\.durationMs)
        }

        // 余量为 0(占全库 25.9%):末字填满与换行同一毫秒 → 压到换行前 lead
        expectEqual(tail(words([("a", 0, 500), ("b", 1000, 500)]), 1500), [500, 500 - lead],
                    "末字: 余量为 0 的行压到换行前 \(lead)ms 填满")
        // 真越过(3.0%,中位 295ms):同样压到换行前 lead
        expectEqual(tail(words([("a", 1000, 1000)]), 1500), [1500 - lead - 1000],
                    "末字: 越过下一行开始的照样压回来")
        // 越过太多:按下限兜住,不做成"啪"地跳满
        expectEqual(tail(words([("a", 1000, 1000)]), 1050), [floorMs],
                    "末字: 压不下去时按 \(floorMs)ms 下限兜住")
        // 余量充足:一个字都不动
        expectEqual(tail(words([("a", 1000, 300)]), 2000), [300],
                    "末字: 余量充足时原样不动")
        // 整首最后一句:没有"换行"这回事
        expectEqual(tail(words([("a", 1000, 5000)]), nil), [5000],
                    "末字: 最后一句不压(没有下一行)")
        // 只动最后一个字,前面的一律不碰
        expectEqual(tail(words([("a", 0, 900), ("b", 900, 900), ("c", 1800, 900)]), 2700),
                    [900, 900, 2700 - lead - 1800],
                    "末字: 只压最后一个字,前面的原样")
        // duration 为 0 的极短词(英文歌词常见)走 minWordDurationMs,压缩不该把它压更短
        expectEqual(tail(words([("a", 1000, 0)]), 9000), [0],
                    "末字: 零时长词余量充足时不动(填色本来就按 80ms 下限走)")
        // 空行不炸
        expectEqual(tail([], 1000), [], "末字: 空词数组安全返回")

        // 压完之后填色必须真的能到 1.0,而且比换行早
        let clamped = KaraokeFill.tailClamped(words([("a", 1000, 500)]), nextLineStartMs: 1500)
        let w = clamped[0]
        expectEqual(KaraokeFill.fillFraction(for: w, atMs: 1500 - lead) >= 1.0, true,
                    "末字: 换行前 \(lead)ms 时填色已经到 1.0")
        expectEqual(KaraokeFill.fillFraction(for: w, atMs: 1500 - lead - 60) < 1.0, true,
                    "末字: 再早 60ms 时还没填满(不是提前一大截就满)")
    }

    // ---- 歌词行状态的判定顺序(2026-08-19) ----
    //
    // 这条链的三处硬约束原本只写在三个 View 的注释里,誊了三遍还各自内联了一份实现。
    // 顺序错了不编译报错、不崩,只会长期显示一句似是而非的状态(纯音乐永远"搜索歌词中…"),
    // 所以拿断言钉住。

    do {
        func d(words: Bool = false, line: Bool = false, ad: Bool = false, inst: Bool = false,
               noLyrics: Bool = false, netDown: Bool = false, content: Bool = false,
               playing: Bool = true) -> LyricsLineDisplay {
            LyricsLineDisplay.resolve(
                hasWordTiming: words, hasCurrentLine: line, isAdBreak: ad, isInstrumental: inst,
                hasNoLyrics: noLyrics, networkDown: netDown, hasLyricsContent: content,
                isPlaying: playing)
        }

        expectEqual(d(words: true, line: true, content: true), .words, "歌词行: 有逐字数据就唱")
        expectEqual(d(line: true, content: true), .plain, "歌词行: 只有整行文本走 plain")
        expectEqual(d(), .searching, "歌词行: 在放但还没有任何歌词 = 搜索中")
        expectEqual(d(playing: false), .idle, "歌词行: 没在放就什么都不显示")
        expectEqual(d(line: true, content: true, playing: false), .plain,
                    "歌词行: 暂停时仍显示当前这一句")

        // 三条"必须排在谁前面"的硬约束
        expectEqual(d(inst: true), .instrumental, "歌词行: 纯音乐排在「搜索中」前(否则永远转圈)")
        expectEqual(d(ad: true), .adBreak, "歌词行: 广告排在「搜索中」前")
        expectEqual(d(noLyrics: true, netDown: true), .noLyrics,
                    "歌词行: 「暂无歌词」排在「网络失败」前(搜完了确实没有)")
        expectEqual(d(netDown: true), .networkDown, "歌词行: 「网络失败」排在「搜索中」前")

        // 有词优先于一切状态 —— 跟另外三处展示面保持同一口径
        expectEqual(d(words: true, line: true, ad: true, inst: true, noLyrics: true), .words,
                    "歌词行: 已经有逐字数据时状态位不抢戏")
        // 网络断了但歌词已经在手 = 照常显示,不该报错
        expectEqual(d(line: true, netDown: true, content: true), .plain,
                    "歌词行: 歌词已在手时网络断了不影响显示")
    }

    // ---- 2026-08-20 歌词引擎性能审计落地的行为守卫 ----
    do {
        // ① load() 入参指纹早退:同参第二次装载返回 false(整段跳过、缓存保住),任一参数
        //    变化恢复 true。
        let engine = LyricsSyncEngine()
        let lrc = "[00:01.00] hello world\n[00:05.00] second line\n[00:09.00] third line"
        expectEqual(engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: ""),
                    true, "load 指纹: 首次装载返回 true")
        expectEqual(engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: ""),
                    false, "load 指纹: 同参重复装载早退返回 false")
        expectEqual(engine.hasContent, true, "load 指纹: 早退后引擎内容原样保留")
        expectEqual(engine.load(lyrics: lrc, lyricsTr: "[00:01.00] 译文", lyricsRoma: "", lyricsYRC: ""),
                    true, "load 指纹: 任一入参变化恢复全量装载")
        expectEqual(engine.load(lyrics: lrc, lyricsTr: "[00:01.00] 译文", lyricsRoma: "", lyricsYRC: "",
                                preferWordLevel: false),
                    true, "load 指纹: preferWordLevel 变化也算内容变化")

        // ② tickQuery 与四个独立入口逐位一致(含单调推进和倒退 seek 两个方向 —— 单调窗口
        //    记忆化的验证失败路径必须正确回退全扫)。
        let engine2 = LyricsSyncEngine()
        engine2.load(
            lyrics: "[00:01.00] alpha\n[00:10.00] beta\n[00:30.00] gamma",
            lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        // 采样点覆盖:第一句之前 / 各句内 / 长间奏(10s→30s 之间,gapWindow 会亮)/ 倒退。
        for ms in [0, 500, 1_500, 9_999, 12_000, 20_000, 31_000, 2_000, 500, 31_000, 1_500] {
            let r = engine2.tickQuery(atMs: ms)
            expectEqual(r.line, engine2.activeLine(atMs: ms), "tickQuery(\(ms)): line 与 activeLine 一致")
            expectEqual(r.nextText, engine2.upcomingLineText(afterMs: ms),
                        "tickQuery(\(ms)): nextText 与 upcomingLineText 一致")
            expectEqual(r.index, engine2.activeLineIndex(atMs: ms),
                        "tickQuery(\(ms)): index 与 activeLineIndex 一致")
            expectEqual(r.gapIndex, engine2.activeGapIndex(atMs: ms),
                        "tickQuery(\(ms)): gapIndex 与 activeGapIndex 一致")
        }
        expectEqual(engine2.tickQuery(atMs: 1_500).line?.plainText, "alpha", "tickQuery: 命中第一句")
        expectEqual(engine2.tickQuery(atMs: 12_000).line?.plainText, "beta", "tickQuery: 命中第二句")
        expectEqual(engine2.tickQuery(atMs: 0).index, nil, "tickQuery: 第一句之前 index 为 nil")

        // ③ nearestText(经 allLines 的译文贴合观察)改二分后的并列语义与旧线性扫一致:
        //    同距并列取时间戳更晚的那条;同时间戳重复取排在最后的那条。
        let engine3 = LyricsSyncEngine()
        engine3.load(
            lyrics: "[00:01.00] main line",
            // 300ms 与 1700ms 距 1000ms 同为 700(都在容差上),旧扫描后见者胜 → 取 late。
            lyricsTr: "[00:00.30] early\n[00:01.70] late",
            lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine3.allLines(idPrefix: "t").first?.line.translation, "late",
                    "nearestText 并列: 同距取时间戳更晚的那条(旧线性扫语义)")
        let engine4 = LyricsSyncEngine()
        engine4.load(
            lyrics: "[00:01.00] main line",
            lyricsTr: "[00:01.20] first\n[00:01.20] second",
            lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine4.allLines(idPrefix: "t").first?.line.translation, "second",
                    "nearestText 重复时间戳: 取排在最后的那条(旧线性扫语义)")
        let engine5 = LyricsSyncEngine()
        engine5.load(
            lyrics: "[00:01.00] main line",
            lyricsTr: "[00:02.50] too far",
            lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine5.allLines(idPrefix: "t").first?.line.translation, nil,
                    "nearestText 容差: 超过 700ms 不贴")

        // ③.5 说话人标签空行不抢近邻译文/罗马音(2026-08-23 用户截图坐实的真 bug):
        // 陶喆《All for Joy》原始数据实拍——「合：」独立成行(逐字里是「合」+「：」两个词,
        // 共享同一时间戳)、178ms 后紧跟真歌词行,译文只有一条、几乎贴着真歌词的时间戳
        // (6ms)但同样落在标签行的 700ms 容差内(174ms)。旧行为:两行各自"就近"命中同一条
        // 译文,连续两行显示同一句中文。
        let engineTag = LyricsSyncEngine()
        let tagYRC = "[121936,3302](121936,443,0)Crowds (122379,513,0)roaring (122892,173,0)fills (123065,485,0)the (123550,1688,0)atmosphere \n"
            + "[125676,178](125676,51,0)合(125727,127,0)：\n"
            + "[125856,6271](125856,967,0)Reminds (126823,275,0)me (127098,656,0)that (127754,733,0)games (128487,585,0)are (129072,794,0)more (129866,741,0)than (130607,1520,0)rules\n"
        engineTag.load(
            lyrics: "", lyricsTr: "[02:01.93]人群的咆哮充满了气氛\n[02:05.85]提醒我，游戏不仅仅是规则",
            lyricsRoma: "", lyricsYRC: tagYRC, preferWordLevel: true)
        let tagLines = engineTag.allLines(idPrefix: "t")
        // 2026-08-23 晚些时候改:这一行现在**根本不进歌词流**。
        //
        // 上面那段注释描述的是同一个 bug 的下游症状(标签行抢走了近邻译文),当时的修法是
        // isBareSpeakerTag —— 让它别抢,但那一行照样显示。真正的问题是它压根不是一句歌词:
        // 它带着自己的时间戳,到点就在屏幕上顶掉真歌词(全库实测 157 处,《等你下课》里
        // 一行「Gary」挂 23.3 秒)。现在 LyricDuet.planWords 认出"剥完为空"直接整行丢掉,
        // 抢译文的问题跟着一起没了。
        //
        // isBareSpeakerTag 保留不动,当第二道防线:LyricDuet 的整份判据认不出的标签
        // (比如整首只出现一次的人名),那一行仍会留在流里,那时还得靠它别去抢译文。
        expectEqual(tagLines.count, 2, "说话人标签: 「合：」独立成行不是歌词,整行丢掉")
        expectEqual(tagLines[0].line.plainText, "Crowds roaring fills the atmosphere ",
                    "说话人标签: 标签前的真歌词不受影响")
        expectEqual(tagLines[1].line.plainText, "Reminds me that games are more than rules",
                    "说话人标签: 标签后的真歌词补上原来标签行的位置")
        expectEqual(tagLines[1].line.translation, "提醒我，游戏不仅仅是规则",
                    "说话人标签: 真歌词行照常拿到属于自己的译文")
        // side 是 nil 而不是 .center —— 这三行里只有「合」一个标记,认不出第二个身份,
        // 就没有"左右"可言(见 LyricDuet.hasEnoughIdentities)。丢行和定边是两件事:
        // 标记行照样丢掉(上面 count == 2),但整首退回"没有对唱信息"、各视图用自己的兜底。
        // 不这么做的话,只有一个合唱标记的歌会全程居中 —— 悬浮窗兜底本来就是居中(白做),
        // 歌词窗口却会从左对齐凭空变成居中(动了排版)。
        expectEqual(tagLines[1].line.side, nil, "说话人标签: 只认出一个身份时不判左右")

        // 反例:标签后面跟着真内容的行(「合：Hey hey ho ho」)不受影响,该有译文照样有——
        // isBareSpeakerTag 只认"冒号后完全没内容"这一种形状。
        let engineTaggedContent = LyricsSyncEngine()
        engineTaggedContent.load(
            lyrics: "[00:01.00]合：真的歌词内容", lyricsTr: "[00:01.20]真实的翻译",
            lyricsRoma: "", lyricsYRC: "")
        expectEqual(engineTaggedContent.allLines(idPrefix: "t").first?.line.translation, "真实的翻译",
                    "说话人标签反例: 冒号后有真内容的行不受影响,照常匹配译文")

        // ③.6 内容匹配优先于时间最近邻(2026-08-27,真实坐实:Prince《Christopher Tracy's
        // Parade》网易云的逐字(YRC)和整行(LRC)时间戳系统性漂移 0.7~3.2 秒——机器翻译
        // (lyrics_tr)忠实继承的是整行 LRC 的时间戳,播放时却拿逐字算出来的(漂移过的)
        // 时间去查译文,超过 nearestText 700ms 容差,大部分句子查不到译文。这里用等价的
        // 最小复现:主歌词行标在 1000ms,译文/罗马音精确复制同一个时间戳(collector 的
        // assembleTranslationLRC 保证这个性质——写出来的时间戳直接从源行抄,不是"接近"),
        // 逐字数据把同一句词标在 3000ms(漂移 2000ms,远超 700ms 容差)。旧逻辑会因为超容差
        // 返回 nil(前面 engine5 那组已经钉死这个行为不能变),内容匹配不看时间,只要
        // plainText 对得上就能查到。
        let engineDrift = LyricsSyncEngine()
        engineDrift.load(
            lyrics: "[00:01.00]drifted line",
            lyricsTr: "[00:01.00]漂移行的译文",
            lyricsRoma: "[00:01.00]piao yi hang de yi wen",
            lyricsYRC: "[3000,500](3000,300,0)drifted (3300,200,0)line",
            preferWordLevel: true)
        expectEqual(engineDrift.allLines(idPrefix: "t").first?.line.translation, "漂移行的译文",
                    "内容匹配: YRC/LRC 时间戳漂移超过容差时,按内容而不是时间找到译文")
        expectEqual(engineDrift.allLines(idPrefix: "t").first?.line.romanization, "piao yi hang de yi wen",
                    "内容匹配: 罗马音同理,按内容匹配不受时间漂移影响")

        // ③.6b 内容匹配要对"空白差异"免疫,不能只对逐字一致才生效(2026-09-01,真实坐实:
        // 陈奕迅《冲口而出 (Live)》"若你 想欣赏 有没有 金曲奖"这一行——真实缓存里主 LRC 用
        // NBSP(U+00A0)标换气停顿,YRC 逐字数据在同样的词组边界嵌的是普通空格,两边可读内容
        // 完全一样、只是空白字符种类不同;旧版 contentMatchKey 只用 trimmingCharacters 削两端,
        // 削不掉中间这几个空白,内容匹配因此 miss。更巧的是这一行的 YRC 起始时间比它在主 LRC
        // 里的时间戳晚 706ms——比 nearestText 的 700ms 容差多 6ms,时间兜底也刚好卡在门外,
        // 两条路同时失手,这一行才彻底没有罗马音(不是缺失,是两个近似匹配各差一点点)。这里用
        // 等价的最小复现还原这两个条件:主 LRC 行内嵌 NBSP;YRC 把同一句词标在漂移 706ms 之外
        // 的时间,词组边界改用普通空格。
        let engineNbspVsSpace = LyricsSyncEngine()
        engineNbspVsSpace.load(
            lyrics: "[00:01.000]若你\u{A0}想欣赏\u{A0}有没有\u{A0}金曲奖",
            lyricsTr: "",
            lyricsRoma: "[00:01.000]joek6 nei5 soeng2 jan1 soeng2 jau5 mut6 jau5 gam1 kuk1 zoeng2",
            lyricsYRC: "[1706,1100](1706,100,0)若(1806,100,0)你 (1906,100,0)想(2006,100,0)欣" +
                "(2106,100,0)赏 (2206,100,0)有(2306,100,0)没(2406,100,0)有 (2506,100,0)金" +
                "(2606,100,0)曲(2706,100,0)奖",
            preferWordLevel: true)
        let nbspLine = engineNbspVsSpace.allLines(idPrefix: "t").first?.line
        expectEqual(nbspLine?.romanization,
                    "joek6 nei5 soeng2 jan1 soeng2 jau5 mut6 jau5 gam1 kuk1 zoeng2",
                    "内容匹配: 主LRC用NBSP、YRC词组边界用普通空格时,内容匹配应无视空白差异命中罗马音")
        expectEqual(nbspLine?.wordGroups?.count, 11,
                    "内容匹配: 命中之后逐字对齐应正常生效(11字11音节严格一一对应,不退回整行)")

        // 反例:内容对不上(比如逐字重建出来的文本跟整行 LRC 字面不一致)时,内容匹配字典
        // 查不到,老老实实退回时间最近邻——这里查询时间(3000ms)漂移量超过容差,应仍是 nil,
        // 不能因为加了内容匹配就意外放宽了容差本身的语义。
        let engineDriftNoMatch = LyricsSyncEngine()
        engineDriftNoMatch.load(
            lyrics: "[00:01.00]completely different text",
            lyricsTr: "[00:01.00]漂移行的译文",
            lyricsRoma: "", lyricsYRC: "[3000,500](3000,300,0)drifted (3300,200,0)line",
            preferWordLevel: true)
        expectEqual(engineDriftNoMatch.allLines(idPrefix: "t").first?.line.translation, nil,
                    "内容匹配反例: 内容对不上时退回 nearestText,容差语义不受影响")

        // ④ plainText 存储化后语义不变:两种形态、以及"引擎构造时预拼"与"默认推导"一口径。
        let wordLine = SyncedLyricLine(
            romanization: nil, translation: nil, mainText: nil,
            words: [SyncedLyricWord(text: "ab", startMs: 0, durationMs: 100),
                    SyncedLyricWord(text: "cd", startMs: 100, durationMs: 100)],
            wordGroups: nil, side: nil)
        expectEqual(wordLine.plainText, "abcd", "plainText 存储化: words 形态默认推导拼接")
        let mainLine2 = SyncedLyricLine(
            romanization: nil, translation: nil, mainText: "hello",
            words: nil, wordGroups: nil, side: nil)
        expectEqual(mainLine2.plainText, "hello", "plainText 存储化: mainText 形态原样")

        // ⑤ 整行读音与逐词分组共用同一次分词后,两条管线仍然等价:
        //    readingFromSegments(japaneseSegments(x)) ≡ romanize(x, japanese: true)。
        for text in ["今はまだ悲しい", "受話器を取った君", "明日の朝"] {
            let viaSegments = Romanizer.readingFromSegments(
                Romanizer.japaneseSegments(text), original: text)
            expectEqual(viaSegments, Romanizer.romanize(text, japanese: true),
                        "分词管线合一: \(text) 两条管线读音一致")
        }

        // ⑥ WrapLayoutMath 带 rows 的重载与原入口逐位一致(WrapLayout 壳缓存 rows 后走的
        //    是新重载,两条路径必须描述同一套排布)。
        let sizes = [CGSize(width: 40, height: 10), CGSize(width: 40, height: 12),
                     CGSize(width: 40, height: 10), CGSize(width: 90, height: 10)]
        let rows = WrapLayoutMath.rows(sizes: sizes, maxWidth: 100, horizontalSpacing: 2)
        expectEqual(
            WrapLayoutMath.totalSize(rows: rows, maxWidth: 100, verticalSpacing: 3),
            WrapLayoutMath.totalSize(sizes: sizes, maxWidth: 100, horizontalSpacing: 2, verticalSpacing: 3),
            "WrapLayoutMath: totalSize(rows:) 与原入口一致")
        expectEqual(
            WrapLayoutMath.placements(rows: rows, sizes: sizes,
                                      bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      horizontalSpacing: 2, verticalSpacing: 3, rowAlignment: .center),
            WrapLayoutMath.placements(sizes: sizes,
                                      bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      horizontalSpacing: 2, verticalSpacing: 3, rowAlignment: .center),
            "WrapLayoutMath: placements(rows:) 与原入口一致")

        // ⑥b wordGroupCache 按"首词时间戳+行文本"做 key:副歌重复句(同文本、不同时间)各自
        //    拿到自己的时间轴,不再共享第一次出现的词组(2026-08-20 对抗审查抓出的预存在 bug)。
        let engineDup = LyricsSyncEngine()
        engineDup.load(
            lyrics: "",
            lyricsTr: "", lyricsRoma: "",
            lyricsYRC: "[10000,2000](10000,500,0)い(10500,500,0)つ(11000,500,0)か\n"
                + "[30000,2000](30000,500,0)い(30500,500,0)つ(31000,500,0)か")
        let dupLines = engineDup.allLines(idPrefix: "dup")
        expectEqual(dupLines.count, 2, "重复句词组: 两行都在")
        expectEqual(dupLines.first?.line.wordGroups?.first?.startMs, 10000,
                    "重复句词组: 第一次出现用自己的时间轴")
        expectEqual(dupLines.last?.line.wordGroups?.first?.startMs, 30000,
                    "重复句词组: 第二次出现不再借用第一次的时间轴")

        // ⑥c parseTimestamp(2026-08-20 播放核心审计):formatter 静态化+顺序换成先试无小数秒
        //    (实测 media-control 恒无小数秒)后,两种形态都仍解析正确、垃圾串仍返回 nil。
        expectEqual(MediaControlClient.parseTimestamp("2026-08-20T10:00:00Z") != nil, true,
                    "parseTimestamp: 无小数秒(常态)解析成功")
        expectEqual(MediaControlClient.parseTimestamp("2026-08-20T10:00:00.123Z") != nil, true,
                    "parseTimestamp: 带小数秒兜底解析成功")
        expectEqual(MediaControlClient.parseTimestamp("not a date"), nil,
                    "parseTimestamp: 垃圾串返回 nil")
        expectEqual(MediaControlClient.parseTimestamp(nil), nil, "parseTimestamp: nil 入参")
        expectEqual(MediaControlClient.parseTimestamp("2026-08-20T10:00:00Z"),
                    MediaControlClient.parseTimestamp("2026-08-20T10:00:00.000Z"),
                    "parseTimestamp: 两种写法的同一时刻解析相等")

        // ⑦ KaraokeFill 纯色快路径改静态常量后语义不变;裸起止版 fillFraction 与词版一致。
        expectEqual(KaraokeFill.stops(left: 1.2, right: 1.4), KaraokeFill.allSungStops,
                    "KaraokeFill: left>=1 走全唱常量")
        expectEqual(KaraokeFill.stops(left: -0.4, right: -0.2), KaraokeFill.allUnsungStops,
                    "KaraokeFill: right<=0 走未唱常量")
        let w = SyncedLyricWord(text: "x", startMs: 1000, durationMs: 40) // 40 < minWordDurationMs
        expectEqual(KaraokeFill.fillFraction(for: w, atMs: 1040),
                    KaraokeFill.fillFraction(startMs: 1000, durationMs: 40, atMs: 1040),
                    "KaraokeFill: 裸起止版 fillFraction 与词版一致(含短词下限)")
    }

    // ---- tickQuery.nextSide 独立于当前行分栏(2026-08-26,《All Night》悬浮窗"下一句预览"
    // 案)----
    //
    // 用户报:方大同/王诗安《All Night》副歌逐句男女交替,悬浮窗"下一句预览"却总是显示在
    // 当前这句的同一边,像是同一个人接着唱。根因是 nextLineText 的引擎本体 nextTextAt(现
    // nextAt)以前只取文字、不取 side——LyricsOverlayView 拿不到下一句自己的 side,只能借用
    // 当前行的 duetSide。这里钉住 tickQuery(...).nextSide 必须取**下一行自己的**标记,不能
    // 跟当前行 side 相等(除非两行真的同一位演唱者)。
    do {
        let engine = LyricsSyncEngine()
        // 形状照抄真实歌词:标记独占一行(唱完即丢,见 LyricDuet.plan 的 dropped),
        // 歌词紧跟在下一行——男/女交替,时间戳故意挨得很近(1s 一句),复刻原曲那段
        // "All night / U got to dance all night"高频切边的节奏。
        engine.load(
            lyrics: """
            [00:01.00]男：
            [00:02.00]All night
            [00:03.00]女：
            [00:04.00]U got to dance all night
            [00:05.00]男：
            [00:06.00]All night yeah
            """,
            lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        let onFirstMale = engine.tickQuery(atMs: 2_500)
        expectEqual(onFirstMale.line?.plainText, "All night",
                    "nextSide 案: 2.5s 命中第一句男声")
        expectEqual(onFirstMale.line?.side, .leading,
                    "nextSide 案: 首个出现的标记(男)排左边")
        expectEqual(onFirstMale.nextText, "U got to dance all night",
                    "nextSide 案: 下一句预览文字仍是女声那句(行为不变)")
        expectEqual(onFirstMale.nextSide, .trailing,
                    "nextSide 案: 下一句(女声)必须排右边,不能继承当前行(男声)的左边——" +
                    "这正是用户报的 bug:改之前悬浮窗会把它摆在跟当前句同一边")
        expectNotEqual(onFirstMale.line?.side, onFirstMale.nextSide,
                       "nextSide 案: 当前行与下一行演唱者不同,两者的 side 不该相等")

        // 5000ms 那行是被丢掉的独占标记(见上面加载的歌词),不占下标——上一句真歌词
        // (4000ms「U got to dance all night」)要撑到 6000ms 那句真歌词开始才让位,所以
        // 查询点必须晚于 6000ms,查 5500ms 命中的其实还是女声那句。
        let onSecondMale = engine.tickQuery(atMs: 6_500)
        expectEqual(onSecondMale.line?.plainText, "All night yeah",
                    "nextSide 案: 6.5s 命中第二句男声")
        expectEqual(onSecondMale.line?.side, .leading,
                    "nextSide 案: 同一身份(男)始终排在同一边")
        expectEqual(onSecondMale.nextSide, nil,
                    "nextSide 案: 最后一句之后没有下一行,nextSide 如实为 nil")

        // upcomingLineText(独立公开 API,PlaybackCoordinator 之外没人直接用 tickQuery 时的
        // 退路)必须跟 tickQuery.nextText 逐位一致——这条本来就在跑(见上面 2026-08-20 那个
        // do 块的②),这里只是确认重写 nextTextAt→nextAt 之后没有破坏它。
        expectEqual(engine.upcomingLineText(afterMs: 2_500), onFirstMale.nextText,
                    "nextSide 案: upcomingLineText 与 tickQuery.nextText 仍然一致")
    }

    // MARK: - CompactLyricLead:单行展示面「唱完就切到下一句」
    //
    // 2026-08-23 用户要求:灵动岛/菜单栏原来是"下一句开始才换行",想改成"这句唱完就切走",
    // 好提前看到下一句跟唱。这套规则跟歌词窗口的 scrollLeadIndex **不是同一套**(那个服务
    // 多行列表、间奏里有「•••」可停靠),两者的差别正是这些断言要钉住的东西。
    do {
        typealias L = CompactLyricLead
        let reveal = L.revealMs   // 5000

        // ① 还在唱这一句 → 显示本行
        expectEqual(L.resolve(activeIdx: 3, posMs: 9_000, lineEndMs: 10_000, nextStartMs: 12_000),
                    .line(3), "还没唱完:显示本行")

        // ② 短间隙(2s < reveal):唱完那一刻立刻切到下一句 —— 这就是用户要的主场景。
        //    实测该用户曲库里 97.7% 的行间隙 < 6s,绝大多数落这一档。
        expectEqual(L.resolve(activeIdx: 3, posMs: 10_000, lineEndMs: 10_000, nextStartMs: 12_000),
                    .line(4), "短间隙:唱完即切到下一句")
        expectEqual(L.resolve(activeIdx: 3, posMs: 9_999, lineEndMs: 10_000, nextStartMs: 12_000),
                    .line(3), "边界:差 1ms 还不算唱完")

        // ③ 长间奏(30s):唱完先切成 ♪,离下一句 reveal 毫秒时才亮出它。
        //    ——单行面没有「•••」那种可停靠的东西,已经唱完的句子不该继续占着那一行冒充"在唱"。
        expectEqual(L.resolve(activeIdx: 3, posMs: 10_000, lineEndMs: 10_000, nextStartMs: 40_000),
                    .placeholder, "长间奏中段:♪")
        expectEqual(L.resolve(activeIdx: 3, posMs: 40_000 - reveal - 1, lineEndMs: 10_000, nextStartMs: 40_000),
                    .placeholder, "边界:提前量窗口外还是 ♪")
        expectEqual(L.resolve(activeIdx: 3, posMs: 40_000 - reveal, lineEndMs: 10_000, nextStartMs: 40_000),
                    .line(4), "边界:进入提前量窗口就亮出下一句")

        // ④ 保守边界 1:行级 LRC 不知道一行唱多久 → 一律不抢跑(维持"下一句开始才换"的旧行为)。
        //    猜早了会在人还在唱这句的时候把它换掉,比现状更糟。
        expectEqual(L.resolve(activeIdx: 3, posMs: 30_000, lineEndMs: nil, nextStartMs: 40_000),
                    .line(3), "行级 LRC:不抢跑")

        // ⑤ 保守边界 2:最后一句(没有下一句)唱完也不切走 —— 切成 ♪ 只会让尾奏变空屏。
        expectEqual(L.resolve(activeIdx: 9, posMs: 99_000, lineEndMs: 10_000, nextStartMs: nil),
                    .line(9), "最后一句:唱完仍显示它")

        // ⑥ 还没到第一句:维持现状(前奏里刻意不提前亮出第一句,那是另一个场景)
        expectEqual(L.resolve(activeIdx: -1, posMs: 500, lineEndMs: nil, nextStartMs: 3_000),
                    .line(-1), "前奏:不动")

        // ⑦ displayDurationMs:菜单栏跑马灯的配速依据。
        //    这一项**必须**跟着显示窗口走 —— 沿用旧的「本句时间戳→下句时间戳」会在
        //    "长句 + 后面接长间奏"时把 dwell 算大,MenuBarMarquee.pacing 按它配速,
        //    句子会只滚出开头一小截就被换掉(比改动前更糟)。
        //    上一句 8s 唱完、本句 10s 开始、13s 唱完、下一句 40s 开始:
        //      出现 = max(8000, 10000-5000) = 8000;消失 = 13000(唱完即下场)→ 5000ms
        expectEqual(L.displayDurationMs(prevLineEndMs: 8_000, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: 40_000, fallbackEndMs: nil),
                    5_000, "长间奏在后:窗口到唱完为止,不能算到下一句开始")
        //    短间隙:上一句 9.8s 唱完、本句 10s 开始、13s 唱完 → 出现 9800、消失 13000
        expectEqual(L.displayDurationMs(prevLineEndMs: 9_800, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: 14_000, fallbackEndMs: nil),
                    3_200, "短间隙:出现于上一句唱完那一刻")
        //    长间奏在前:上一句 2s 就唱完、本句 10s 开始 → 出现被 reveal 夹在 5000
        expectEqual(L.displayDurationMs(prevLineEndMs: 2_000, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: 14_000, fallbackEndMs: nil),
                    8_000, "长间奏在前:出现时刻被 revealMs 夹住,不会早于此")
        //    脏数据:上一句"唱完"比本句开始还晚 → 出现时刻不能算成晚于本句开始
        expectEqual(L.displayDurationMs(prevLineEndMs: 11_000, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: 14_000, fallbackEndMs: nil),
                    3_000, "时间戳交叠:出现时刻夹到本句开始")
        //    行级 LRC:不知道唱完时刻 → 退回"下一句开始"
        expectEqual(L.displayDurationMs(prevLineEndMs: nil, startMs: 10_000,
                                        lineEndMs: nil, nextStartMs: 14_000, fallbackEndMs: nil),
                    4_000, "行级 LRC:窗口退回下一句开始")
        //    最后一句:引擎不知道曲长,给 nil → 由 PlaybackCoordinator 退回既有公式
        expectEqual(L.displayDurationMs(prevLineEndMs: 9_000, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: nil, fallbackEndMs: nil),
                    nil, "最后一句:引擎算不出,交给上层用曲目时长兜底")
        expectEqual(L.displayDurationMs(prevLineEndMs: 9_000, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: nil, fallbackEndMs: 30_000),
                    21_000, "最后一句:给了曲末兜底就用它")

        // ⑧ leadInMs(2026-08-24):这一行**出现之后、开唱之前**那段"已显示但还没染色"的提前量。
        //    菜单栏跑马灯拿它当"起步前至少等多久" —— 用户报的「还没开始染色的时候不需要滚动,
        //    现在是会滚」就是这段时间里滚了。用例跟上面 ⑦ 一一对应,因为两者**必须**用同一个
        //    "出现"(appearMs):一个算窗口有多长、一个算窗口前半段有多长,漂了就是"提前量比
        //    整个窗口还长"。
        expectEqual(L.leadInMs(prevLineEndMs: 8_000, startMs: 10_000), 2_000,
                    "提前量:上一句 8s 唱完、本句 10s 开唱 → 提前 2s")
        expectEqual(L.leadInMs(prevLineEndMs: 9_800, startMs: 10_000), 200,
                    "提前量:短间隙就是那点间隙本身")
        expectEqual(L.leadInMs(prevLineEndMs: 2_000, startMs: 10_000), reveal,
                    "提前量:长间奏在前时被 revealMs 夹住")
        expectEqual(L.leadInMs(prevLineEndMs: 11_000, startMs: 10_000), 0,
                    "提前量:时间戳交叠(上一句'唱完'比本句开始还晚)时为 0,不出负数")
        expectEqual(L.leadInMs(prevLineEndMs: nil, startMs: 10_000), 0,
                    "提前量:行级 LRC 恒为 0(resolve 对它从不抢跑),不会被无谓地推迟滚动")

        //    不变式:提前量 + 开唱到下场那段 == 整个显示窗口。两者共用 appearMs 就是为了这条。
        for (prevEnd, start, end) in [(8_000, 10_000, 13_000), (9_800, 10_000, 13_000),
                                      (2_000, 10_000, 13_000), (11_000, 10_000, 13_000)] {
            let window = L.displayDurationMs(prevLineEndMs: prevEnd, startMs: start,
                                             lineEndMs: end, nextStartMs: 40_000, fallbackEndMs: nil)
            expectEqual(L.leadInMs(prevLineEndMs: prevEnd, startMs: start) + (end - start), window,
                        "提前量 + 开唱到下场 == 整个显示窗口(prevEnd=\(prevEnd))")
        }
    }

    // MARK: - 提前量经引擎出到 TickResolution(2026-08-24)
    //
    // 上面那组只测了 CompactLyricLead 这个纯函数,测不到引擎**喂给它什么**。而 tickQuery 里
    // 那句 `prevLineEndMs: gapLineEndMs(at: i - 1)` 的 `i - 1` 正是最容易写错的地方 ——
    // 写成 `i` 编译一样过、纯函数断言一条都不会红,但提前量会恒等于 0(拿本行的结束当上一行的
    // 结束),整个修复静默失效。所以这里从 YRC 一路测到 TickResolution。
    do {
        // 三行逐字:第 0 行 10.0~11.0s、第 1 行 13.0~14.0s(与上一行隔 2.0s = 提前量)、
        // 第 2 行 30.0s(第 1 行后面接一段长间奏,所以第 1 行唱完就下场)。
        let yrc = "[10000,1000](10000,500,0)aa (10500,500,0)bb \n"
            + "[13000,1000](13000,500,0)cc (13500,500,0)dd \n"
            + "[30000,1000](30000,500,0)ee (30500,500,0)ff \n"
        let engine = LyricsSyncEngine()
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, preferWordLevel: true)

        // 第 0 行还在唱:显示本行,它前面没有行 → 提前量 0(不能因为"没有上一行"就算出负数)。
        let singing = engine.tickQuery(atMs: 10_500)
        expectEqual(singing.compactLine?.plainText, "aa bb ", "引擎提前量: 还在唱时显示本行")
        expectEqual(singing.compactLeadInMs, 0, "引擎提前量: 第一行没有上一行 → 0")

        // 第 0 行唱完(11.0s)→ 短间隙,立刻亮出第 1 行,但它 13.0s 才开唱 → 提前量 2000ms。
        // ⚠️ 这条就是 `i - 1` 的照妖镜:取成 `i` 会算成 leadInMs(prevEnd: 14000, start: 13000) = 0。
        let lead = engine.tickQuery(atMs: 11_500)
        expectEqual(lead.compactLine?.plainText, "cc dd ", "引擎提前量: 唱完即切到下一句")
        expectEqual(lead.compactLeadInMs, 2_000, "引擎提前量: 上一行 11.0s 唱完、本行 13.0s 开唱 → 2000ms")
        // 提前量是这一行**显示窗口的属性**,不是"还剩多久开唱" —— 窗口里任意时刻都是同一个值,
        // 否则 pacing 会随每次 refresh 变、把跑马灯反复打回开头。
        expectEqual(engine.tickQuery(atMs: 12_999).compactLeadInMs, 2_000,
                    "引擎提前量: 窗口内恒定,不随播放位置递减")
        // 跟 dwell 同一个"出现"原点:2000(提前) + 1000(开唱到唱完) = 3000(整个显示窗口)。
        expectEqual(lead.compactDwellMs, 3_000, "引擎提前量: 显示窗口 = 提前量 + 开唱到下场")

        // 长间奏中段(第 1 行 14.0s 唱完、第 2 行 30.0s 才开始):♪ 占位,没有行也就没有提前量。
        let idle = engine.tickQuery(atMs: 20_000)
        expectEqual(idle.compactLine == nil && idle.compactPlaceholder, true, "引擎提前量: 长间奏中段是 ♪")
        expectEqual(idle.compactLeadInMs, nil, "引擎提前量: 没有可显示的行时为 nil")

        // 长间奏尾段(第 2 行开始前 5s 内)→ 亮出第 2 行,提前量被 revealMs 夹住。
        let capped = engine.tickQuery(atMs: 26_000)
        expectEqual(capped.compactLine?.plainText, "ee ff ", "引擎提前量: 进入提前量窗口亮出下一句")
        expectEqual(capped.compactLeadInMs, CompactLyricLead.revealMs,
                    "引擎提前量: 长间奏在前时被 revealMs 夹住")

        // ---- 最后一句:曲长喂进来之后窗口也是**行常量**(2026-08-24) ----
        //
        // 不喂曲长时最后一句的 compactDwellMs 恒为 nil,上层退回 currentLineDwellSeconds ——
        // 那个值按 currentLineIndex 取行,提前量窗口里指的是**已唱完的上一句**(错基数),
        // 而且开唱那一刻 currentLineIndex 前进 → 值突变 → pacing 变 → 滚动被重装。首停含
        // 提前量,重装就等于把提前量**再等一遍**(最长 5 秒),最后一句可能整段唱完都不滚。
        // 所以这两条断言钉的是「同一句在开唱前后拿到同一个窗口」——它才是"不重装"的前提。
        let last = engine.tickQuery(atMs: 26_000, trackEndMs: 40_000)   // 第 2 行的提前量窗口内
        let lastSinging = engine.tickQuery(atMs: 30_500, trackEndMs: 40_000) // 同一行,已开唱
        // 出现 = max(第 1 行唱完 14000, 30000 − reveal 5000) = 25000;消失 = 曲末 40000。
        expectEqual(last.compactDwellMs, 15_000, "引擎提前量: 最后一句用曲末兜底算出窗口")
        expectEqual(lastSinging.compactDwellMs, last.compactDwellMs,
                    "引擎提前量: 最后一句的窗口在开唱前后**不变**(否则 pacing 变→滚动重装→提前量白等两遍)")
        expectEqual(lastSinging.compactLeadInMs, last.compactLeadInMs,
                    "引擎提前量: 最后一句的提前量在开唱前后也不变")
        // 不给曲长仍然退回 nil —— 这是上层兜底存在的唯一理由,别让它悄悄消失。
        expectEqual(engine.tickQuery(atMs: 26_000).compactDwellMs, nil,
                    "引擎提前量: 不给曲长时最后一句仍算不出窗口(交给上层兜底)")
        // 非最后一句跟曲长无关,喂了也一样。
        expectEqual(engine.tickQuery(atMs: 11_500, trackEndMs: 40_000).compactDwellMs, 3_000,
                    "引擎提前量: 非最后一句的窗口不受曲长影响")

        // 行级 LRC 一律不抢跑 → 提前量恒为 0,滚动行为一字不变。
        let lineLevel = LyricsSyncEngine()
        lineLevel.load(lyrics: "[00:10.00]aabb\n[00:13.00]ccdd\n", lyricsTr: "", lyricsRoma: "",
                       lyricsYRC: "")
        let lrcTick = lineLevel.tickQuery(atMs: 11_500)
        expectEqual(lrcTick.compactLine?.plainText, "aabb", "引擎提前量: 行级 LRC 不抢跑")
        expectEqual(lrcTick.compactLeadInMs, 0, "引擎提前量: 行级 LRC 提前量恒为 0")
    }
}
