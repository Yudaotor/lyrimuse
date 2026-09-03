import LyrimuseCore
import Foundation

// 停播页:第 N 次听换算 / 收听总览 / 选句 / 平台链接。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runIdlePageTests() {
    // MARK: - 停播页:最近记录「第 N 次听」的换算(RecentPlayOrdinal,2026-08-24 从 UI 下沉)
    do {
        // 站位的 playCountKey:跟真实那个(LastfmStatsService.playCountKey)同口径 —— 只
        // trim + 小写,**不折叠任何写法变体**。这正是测试的重点:表是按这把「不折叠」的尺子
        // 建的,而「比这一行更新的同曲收听」必须按 familyKey 的折叠族数,两把尺子不能混用。
        let key: (String, String) -> String = { a, t in
            (a.trimmingCharacters(in: .whitespaces) + "|" + t.trimmingCharacters(in: .whitespaces))
                .lowercased()
        }

        // 同一首歌连着听三次(列表倒序:最新在前),总数 10 → 10 / 9 / 8
        let three = [(artist: "方大同", title: "月亮代表我的心"),
                     (artist: "方大同", title: "月亮代表我的心"),
                     (artist: "方大同", title: "月亮代表我的心")]
        expectEqual(RecentPlayOrdinal.ordinals(rows: three,
                                               totals: [key("方大同", "月亮代表我的心"): 10],
                                               playCountKey: key),
                    [10, 9, 8], "第 N 次听:同一首连听三次逐次递减")

        // 回归用户 2026-08-21 报的「第 15 次听下面紧跟第 21 次听」:同一首歌的两种写法在
        // 表里是两个不同的 playCountKey(各自存着**整族合并后**的同一个总数),但它们属于同
        // 一个折叠族 —— 按 playCountKey 去数「更新的同曲收听」会一次都减不掉,两行显示同一
        // 个 N。必须按 familyKey 数,后面那行才会 −1。
        let twoForms = [(artist: "周杰倫", title: "一路向北"),
                        (artist: "周杰伦", title: "一路向北")]
        expectEqual(RecentPlayOrdinal.ordinals(
            rows: twoForms,
            totals: [key("周杰倫", "一路向北"): 16, key("周杰伦", "一路向北"): 16],
            playCountKey: key),
                    [16, 15], "第 N 次听:繁简两种写法同页时按折叠族递减,不是两行同一个 N")

        // 查不到总数 → nil(宁可不显示)
        expectEqual(RecentPlayOrdinal.ordinals(rows: [(artist: "无名", title: "无此曲")],
                                               totals: [:], playCountKey: key),
                    [nil], "第 N 次听:表里没有这首就不显示")

        // 竞态:窗口里的同族收听比总数还多 → 算出 ≤0 的位置一律 nil,不显示「第 0 次」
        expectEqual(RecentPlayOrdinal.ordinals(rows: three,
                                               totals: [key("方大同", "月亮代表我的心"): 2],
                                               playCountKey: key),
                    [2, 1, nil], "第 N 次听:算出 ≤0 时留空,不显示错的")
    }

    // MARK: - 停播页:收听总览的派生算术(IdleListeningStats,2026-08-24)
    do {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dayKey: (Date) -> String = { fmt.string(from: $0) }
        // 固定时刻,断言不随运行日漂移
        let today = Date(timeIntervalSince1970: 1_787_000_000)
        func off(_ n: Int) -> String { dayKey(cal.date(byAdding: .day, value: n, to: today)!) }

        let counts = [off(0): 5, off(-1): 3, off(-3): 7]
        expectEqual(IdleListeningStats.series(dailyCounts: counts, endingAt: today, days: 5,
                                              calendar: cal, dayKey: dayKey),
                    [0, 7, 0, 3, 5], "走势序列:正序、缺的天补 0(桶只存非零天)")

        // 环比:前一个 7 天 100 → 最近 7 天 113
        let wow = IdleListeningStats.weekOverWeekDelta(
            dailyCounts: [off(-13): 100, off(-6): 113], today: today, calendar: cal, dayKey: dayKey)
        expectEqual(wow.map { Int(($0 * 100).rounded()) } ?? -999, 13, "环比:113 比 100 = +13%")
        expectEqual(IdleListeningStats.weekOverWeekDelta(
            dailyCounts: [off(-2): 5], today: today, calendar: cal, dayKey: dayKey) == nil,
                    true, "环比:上一个 7 天为 0 时不给百分比(不显示 ∞/0%)")

        // TitleAliasEvidence(2026-08-30 加):跨语言歌名别名自动发现的证据门槛。
        // 用例全部取自真实产出的错误,不编数据 —— 判据原来只有"同歌手 + duration 精确相等
        // + 候选唯一",而 Last.fm 的 duration 是整秒,实测 40% 的歌与同歌手另一首同时长。
        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "", albumA: "BADモード",
            mbidB: "", albumB: "Deep River"), false,
            "别名证据:专辑明确不同就否决(宇多田「Time」被判成相隔 20 年的「SAKURAドロップス」)")
        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "", albumA: "橙月", mbidB: "", albumB: "橙月"), true,
            "别名证据:专辑相同则放行")
        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "", albumA: "", mbidB: "", albumB: "Deep River"), true,
            "别名证据:专辑缺失时这一档给不出结论,放行(退回 duration+唯一性)")
        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "abc-123", albumA: "A", mbidB: "abc-123", albumB: "B"), true,
            "别名证据:mbid 相同是最强证据,专辑不同也放行(同一 recording 可挂不同发行)")
        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "abc-123", albumA: "A", mbidB: "xyz-999", albumB: "B"), false,
            "别名证据:mbid 不同不构成放行,仍按专辑否决")
        // 专辑名比较走 foldTitle,不是裸字符串相等 —— 繁简/全半角本来就是同一张专辑。
        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "", albumA: "太平盛世", mbidB: "", albumB: "太平盛世 "), true,
            "别名证据:专辑名按 foldTitle 折叠后比较(空白差异不算不同)")

        // lastSevenDays(2026-08-30 加):界面上「近 7 天」的数值从 API 的滚动 168 小时改成
        // 这个自然日对齐口径,为的是跟紧挨着的环比百分比同源(两处显示同一个名字的数字,
        // 口径必须一致)。
        expectEqual(IdleListeningStats.lastSevenDays(
            dailyCounts: [off(0): 5, off(-1): 3, off(-6): 7, off(-7): 999],
            today: today, calendar: cal, dayKey: dayKey),
                    15, "近7天:只数今天往回 7 个自然日(第 8 天的 999 不计入)")
        expectEqual(IdleListeningStats.lastSevenDays(
            dailyCounts: [off(-1): 3], today: today, todayCount: 20,
            calendar: cal, dayKey: dayKey),
                    23, "近7天:今天那一格用实时值补(桶里没有今天)")
        expectEqual(IdleListeningStats.lastSevenDays(
            dailyCounts: [off(0): 999, off(-1): 3], today: today, todayCount: 20,
            calendar: cal, dayKey: dayKey),
                    23, "近7天:今天以实时值为准,不跟桶里的值相加")

        // todayCount(2026-08-30 加):桶同步到昨天为止,今天那一格通常不存在。不补的话今天
        // 被当成 0 计进最近 7 天,把环比系统性拉低——走势图早就在补这一格,这里以前没补。
        expectEqual(IdleListeningStats.weekOverWeekDelta(
            dailyCounts: [off(-13): 100, off(-6): 100], today: today,
            calendar: cal, dayKey: dayKey).map { Int(($0 * 100).rounded()) } ?? -999,
                    0, "环比:不传 todayCount 时今天算 0(维持旧行为)")
        expectEqual(IdleListeningStats.weekOverWeekDelta(
            dailyCounts: [off(-13): 100, off(-6): 100], today: today, todayCount: 20,
            calendar: cal, dayKey: dayKey).map { Int(($0 * 100).rounded()) } ?? -999,
                    20, "环比:补上今天的实时值(100+20 比 100 = +20%)")
        // 只盖今天那一格,历史那些天桶里是权威的,不能被顺手改掉。
        expectEqual(IdleListeningStats.weekOverWeekDelta(
            dailyCounts: [off(-13): 100, off(-6): 100, off(0): 999], today: today, todayCount: 20,
            calendar: cal, dayKey: dayKey).map { Int(($0 * 100).rounded()) } ?? -999,
                    20, "环比:今天那一格以实时值为准,不是跟桶里的值相加")

        expectEqual(IdleListeningStats.dailyAverage(dailyCounts: ["a": 1, "b": 4])?.average, 3,
                    "日均:5 ÷ 2 四舍五入")
        expectEqual(IdleListeningStats.dailyAverage(dailyCounts: ["a": 1, "b": 4])?.days, 2,
                    "有记录天数 = 桶里的键数")
        expectEqual(IdleListeningStats.dailyAverage(dailyCounts: [:]) == nil, true,
                    "空桶:算不出日均")

        // 走势图要按下标反查「这一根是哪天」(标峰值日期 / 悬停读数)。日期序列必须跟 series
        // **同一套对齐口径**,否则图上第 N 根和报出来的日期会错位。
        let ds = IdleListeningStats.days(endingAt: today, days: 5, calendar: cal)
        expectEqual(ds.count, 5, "日期序列:长度与 series 一致")
        expectEqual(ds.map(dayKey), (-4 ... 0).map(off), "日期序列:正序、末位是今天,与 series 对齐")

    }

    // MARK: - 停播页:选句(LyricQuotePicker,2026-08-24 用户报「经常只显示半句」后重做)
    do {
        func L(_ ms: Int, _ t: String) -> LyricQuotePicker.Line {
            LyricQuotePicker.Line(timeMs: ms, text: t)
        }
        typealias Q = LyricQuotePicker

        // 核心回归:一句话被拆到两行上时必须并回来。单摆「我们」没有任何意义,
        // 这正是用户报的形状(LRC 的行是打轴单位、不是句子单位)。
        expectEqual(Q.phrases([L(20_000, "我们"), L(20_800, "都有难忘的回忆"),
                               L(28_000, "这一句自己就能站住不必再并")]),
                    [["我们", "都有难忘的回忆"], ["这一句自己就能站住不必再并"]],
                    "选句:碎片行并回整句,本身成话的行不动它")

        // 以悬挂词(在)结尾的行,并上下一行之后就完整了 —— 这是「修好」而不是「弃用」
        expectEqual(Q.phrases([L(0, "我把所有的回忆都留在"), L(9_000, "另一个夏天的午后阳光里")]),
                    [["我把所有的回忆都留在", "另一个夏天的午后阳光里"]],
                    "选句:悬挂结尾能并到下一行就并,不直接丢")

        // 并不上(整首只有这一行)时宁可整条弃用,绝不摆一句以「在」结尾的半句
        expectEqual(Q.phrases([L(0, "我把所有的回忆都留在")]), [],
                    "选句:修不好的悬挂结尾整条弃用")

        // 以附着成分开头 = 这是被切下来的尾巴
        expectEqual(Q.phrases([L(0, "的时候我们都还很年轻啊")]), [],
                    "选句:以「的」开头的尾巴不摆")

        // 噪音:段落标记 / 字符复读 / 整行括号伴唱
        expectEqual(Q.phrases([L(0, "Rap2："), L(1_000, "面面面面面"),
                               L(2_000, "（和声重复的伴唱）"), L(3_000, "这一句是正常的歌词内容")]),
                    [["这一句是正常的歌词内容"]],
                    "选句:段落标记/复读/括号伴唱全部挡掉")

        // 「歌名 - 歌手」被当正文存进来的抬头行。判据收得很窄:整行归一化后**正好等于**
        // 歌名+歌手才算,不能用「包含歌名」——那会把《成都》里「如果你正好在成都」一起杀掉。
        expectEqual(Q.phrases([L(0, "天气先生 - 方大同"), L(4_000, "这一句是正常的歌词内容")],
                              trackTitle: "天气先生", trackArtist: "方大同"),
                    [["这一句是正常的歌词内容"]], "选句:抬头行挡掉,正常歌词留下")
        expectEqual(Q.phrases([L(0, "如果你正好在成都的街头走一走")], trackTitle: "成都"),
                    [["如果你正好在成都的街头走一走"]], "选句:含歌名的正常歌词不能被误杀")

        // ⚠️ 一行带多个时间戳(副歌复用)时 LRCParser 按**文件顺序**各生成一条,数组并不按时间
        // 有序。不先排序,行间时间差会算出负数、断句全乱 —— 这条断言钉的就是「已经排过序」。
        expectEqual(Q.phrases([L(90_000, "副歌这一句在第二次出现"),
                               L(10_000, "开头这一句才是最早的"),
                               L(11_000, "紧跟着的短句")]),
                    [["开头这一句才是最早的", "紧跟着的短句"], ["副歌这一句在第二次出现"]],
                    "选句:先按时间排序再断句(多时间戳行不是有序的)")

        // 同一句在不同时间重复出现只留一条
        expectEqual(Q.phrases([L(0, "重复出现的同一句歌词"), L(20_000, "重复出现的同一句歌词")]),
                    [["重复出现的同一句歌词"]], "选句:同文本去重")
    }

    // MARK: - 各平台跳转链接的纯判据(PlatformLinks,2026-08-24)
    do {
        typealias P = PlatformLinks
        // 搜索兜底 vs 真·歌曲页。判据与 collector 的 isQQSearchFallbackURL 同源(qq.go:49-54)——
        // 把兜底链接当"这首歌的页面"给出去,用户点了会被丢到搜索结果页还得再点一次。
        expectEqual(P.isQQSearchFallback("https://y.qq.com/n/ryqq/search?w=%E7%A8%BB%E9%A6%99"), true,
                    "QQ 链接:搜索兜底认得出来")
        expectEqual(P.isQQSearchFallback("https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49"), false,
                    "QQ 链接:真·歌曲页不算兜底")
        expectEqual(P.isQQSearchFallback(""), false, "QQ 链接:空串不算兜底")

        expectEqual(P.qqAlbumURL(mid: "002B4bAK3AC0Cw")?.absoluteString,
                    "https://y.qq.com/n/ryqq/albumDetail/002B4bAK3AC0Cw", "QQ 专辑页 URL")
        expectEqual(P.qqArtistURL(mid: "0025NhlN2yWrP4")?.absoluteString,
                    "https://y.qq.com/n/ryqq/singer/0025NhlN2yWrP4", "QQ 歌手页 URL")
        expectEqual(P.qqAlbumURL(mid: "") == nil, true, "缺 mid 就不给链接(调用方据此隐藏入口)")

        // mid 形状闸。y.qq.com 是 SPA 空壳、**假 mid 也会 302**,服务端不校验 —— 链接对不对
        // 没有任何远端反馈,只能在本地把明显不是 mid 的东西挡掉。
        expectEqual(P.isPlausibleQQMid("002B4bAK3AC0Cw"), true, "mid 闸:正常 mid 通过")
        expectEqual(P.isPlausibleQQMid("abc/def"), false, "mid 闸:带斜杠的路径片段挡掉")
        expectEqual(P.isPlausibleQQMid("abc?x=1"), false, "mid 闸:带查询串挡掉")
        expectEqual(P.isPlausibleQQMid(String(repeating: "a", count: 33)), false, "mid 闸:超长挡掉")
        expectEqual(P.isPlausibleQQMid("a_b-c"), true, "mid 闸:下划线与短横线是合法字符")

        expectEqual(PlatformLinks(appleMusic: nil, qqSong: nil, qqAlbum: nil,
                                  qqArtist: nil, neteaseSong: nil).isEmpty, true,
                    "一个链接都没有时 isEmpty")
    }
}
