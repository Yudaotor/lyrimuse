import LyrimuseCore
import Foundation

// 停播页:第 N 次听换算 / 收听总览 / 选句 / 平台链接。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runIdlePageTests() {
    // MARK: - 停播页:最近记录「第 N 次听」的换算(RecentPlayOrdinal,从 UI 下沉)
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

        // 回归「第 15 次听下面紧跟第 21 次听」那个缺陷:同一首歌的两种写法在
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

    // MARK: - 最近记录:连续听同一首折成一组(RecentRepeatRuns)
    do {
        let rows = [(artist: "周深", title: "奔赴超无限"),
                    (artist: "周杰倫", title: "一路向北"),
                    (artist: "周杰伦", title: "一路向北"),   // 繁简两种写法:同一首
                    (artist: "周杰伦", title: "一路向北"),
                    (artist: "陶喆", title: "爱很简单"),
                    (artist: "周杰伦", title: "一路向北")]  // 中间隔了别的歌:另起一组
        expectEqual(RecentRepeatRuns.runs(rows: rows), [0..<1, 1..<4, 4..<5, 5..<6],
                    "连续同曲:按折叠族连续合并,繁简算同一首,隔开的不合并")
        expectEqual(RecentRepeatRuns.runs(rows: []), [], "连续同曲:空列表")
        expectEqual(RecentRepeatRuns.runs(rows: [(artist: "陶喆", title: "爱很简单")]), [0..<1],
                    "连续同曲:单行就是一个长度 1 的区间")
        expectEqual(RecentRepeatRuns.runs(rows: Array(repeating: (artist: "陶喆", title: "爱很简单"), count: 3)),
                    [0..<3], "连续同曲:整页都是同一首时只有一组")
    }

    // MARK: - 停播页:收听总览的派生算术(IdleListeningStats)
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

        // lastSevenDays:界面上「近 7 天」的数值从 API 的滚动 168 小时改成
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

        // todayCount:桶同步到昨天为止,今天那一格通常不存在。不补的话今天
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

    // MARK: - 停播页:选句(LyricQuotePicker,现象是「经常只显示半句」后重做)
    do {
        func L(_ ms: Int, _ t: String) -> LyricQuotePicker.Line {
            LyricQuotePicker.Line(timeMs: ms, text: t)
        }
        typealias Q = LyricQuotePicker

        // 核心回归:一句话被拆到两行上时必须并回来。单摆「我们」没有任何意义,
        // 这正是现象是的形状(LRC 的行是打轴单位、不是句子单位)。
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

        // 一行带多个时间戳(副歌复用)时 LRCParser 按**文件顺序**各生成一条,数组并不按时间
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

    // MARK: - 各平台跳转链接的纯判据(PlatformLinks)
    do {
        typealias P = PlatformLinks
        // 搜索兜底 vs 真·歌曲页。判据与引擎的 isQQSearchFallbackURL 同源(qq.go:49-54)——
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
        expectEqual(PlatformLinks(appleMusic: nil, qqSong: nil, qqAlbum: nil, qqArtist: nil, neteaseSong: nil,
                                  spotifySong: URL(string: "https://open.spotify.com/track/1")).isEmpty, false,
                    "只有 Spotify 曲目页也不算 isEmpty(2026-09-10 新字段要进判据)")

        // Spotify 曲目 ID 形状闸(与引擎的 spotifyTrackIDFromURI 同源:22 位 base62)。
        expectEqual(P.spotifyTrackURL(id: "1Xyo4u8uXC1ZmMpatF05PJ")?.absoluteString,
                    "https://open.spotify.com/track/1Xyo4u8uXC1ZmMpatF05PJ", "Spotify 曲目页 URL")
        expectEqual(P.spotifyTrackURL(id: "") == nil, true, "Spotify ID:空串不给链接")
        expectEqual(P.spotifyTrackURL(id: "missing value") == nil, true, "Spotify ID:脚本回声挡掉")
        expectEqual(P.spotifyTrackURL(id: "1Xyo4u8uXC1ZmMpatF05P") == nil, true, "Spotify ID:21 位挡掉")
        expectEqual(P.spotifyTrackURL(id: "1Xyo4u8uXC1ZmMpatF05P/") == nil, true, "Spotify ID:带斜杠挡掉")

        // 「网页」行只给当前播放器自己那个平台的歌曲页。
        let am = URL(string: "music://music.apple.com/cn/album/x/1?i=2")!
        let qq = URL(string: "https://y.qq.com/n/ryqq/songDetail/004Yi5BD3ksoAN")!
        let ne = URL(string: "https://music.163.com/song?id=277787")!
        let sp = URL(string: "https://open.spotify.com/track/1Xyo4u8uXC1ZmMpatF05PJ")!
        let all = PlatformLinks(appleMusic: am, qqSong: qq, qqAlbum: nil, qqArtist: nil, neteaseSong: ne, spotifySong: sp)
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.appleMusic.bundleIdentifier)?.url, am,
                    "网页行:Apple Music 播放 → Apple Music 曲目页")
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.appleMusic.bundleIdentifier)?.platform, .appleMusic,
                    "网页行:Apple Music 播放 → 平台身份也对")
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.qqMusic.bundleIdentifier)?.url, qq,
                    "网页行:QQ 音乐播放 → 只给 QQ 歌曲页")
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.netease.bundleIdentifier)?.url, ne,
                    "网页行:网易云播放 → 只给网易云歌曲页")
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.spotify.bundleIdentifier)?.url, sp,
                    "网页行:Spotify 原生播放 → Spotify 曲目页")
        expectEqual(all.songLink(forPlayerBundleID: "com.google.Chrome", webPlatformID: "spotifyWeb")?.platform, .spotify,
                    "网页行:浏览器里放 Spotify 网页版 → 按 Spotify 算(bundle id 是浏览器,靠平台 id 认)")
        expectEqual(all.songLink(forPlayerBundleID: "com.google.Chrome", webPlatformID: "youtubeMusic") == nil, true,
                    "网页行:YouTube Music 没存链接 → 整行不出现,不拿别的平台顶上")
        expectEqual(all.songLink(forPlayerBundleID: "com.google.Chrome") == nil, true,
                    "网页行:认不出在放哪个网页平台的浏览器 → nil")
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.kugou.bundleIdentifier) == nil, true,
                    "网页行:酷狗播放 → nil(引擎没存酷狗歌曲页;用户那张截图的场景)")
        let kkApp = P.kkboxAppURL(songPage: "https://www.kkbox.com/tw/tc/song/4s7gyziTOGRFhEcFQf")
        expectEqual(kkApp?.absoluteString, "kkbox://song/4s7gyziTOGRFhEcFQf#view", "KKBOX 歌曲页 → 进 App 的深链")
        expectEqual(P.kkboxAppURL(songPage: "https://www.kkbox.com/tw/tc/album/X") == nil, true, "KKBOX:不是 song 页挡掉")
        expectEqual(P.kkboxAppURL(songPage: "https://evil.example.com/tw/tc/song/X") == nil, true, "KKBOX:别的域名挡掉")
        expectEqual(P.kkboxAppURL(songPage: "") == nil, true, "KKBOX:空串不给链接")
        let withKK = PlatformLinks(appleMusic: am, qqSong: qq, qqAlbum: nil, qqArtist: nil, neteaseSong: ne, kkboxSong: kkApp)
        expectEqual(withKK.songLink(forPlayerBundleID: PlaybackPlayer.kkbox.bundleIdentifier)?.platform, .kkbox,
                    "网页行:KKBOX 播放 → 在 KKBOX 里打开这首")
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.kkbox.bundleIdentifier) == nil, true,
                    "网页行:KKBOX 播放但没存它的歌曲页 → nil,不拿别的平台顶上")
        expectEqual(all.songLink(forPlayerBundleID: nil) == nil, true, "网页行:还没认出播放器 → nil")
        expectEqual(all.songLink(forPlayerBundleID: "") == nil, true, "网页行:.auto 的空 bundle id → nil")
        // 播放器认得出、但这首歌在它那个平台上没链接:同样 nil,不退到别的平台。
        let noNetease = PlatformLinks(appleMusic: am, qqSong: qq, qqAlbum: nil, qqArtist: nil, neteaseSong: nil)
        expectEqual(noNetease.songLink(forPlayerBundleID: PlaybackPlayer.netease.bundleIdentifier) == nil, true,
                    "网页行:网易云播放但没有网易云链接(周杰伦那类版权下架)→ nil,不拿 QQ / AM 顶上")
        expectEqual(noNetease.songLink(forPlayerBundleID: PlaybackPlayer.spotify.bundleIdentifier) == nil, true,
                    "网页行:Spotify 播放但缓存里只有搜索页兜底、没有真 ID → nil")

        // 汽水歌曲页,以及各家的专辑页 / 歌手页:id 的形状闸与引擎同源(playercatalog.go playerCatalogIDOK、
        // kasetalbum.go ytmusicBrowseIDOK)。
        let soda = P.sodaTrackURL("https://music.douyin.com/qishui/share/track?track_id=7687935075879012369")
        expectEqual(soda?.absoluteString, "https://music.douyin.com/qishui/share/track?track_id=7687935075879012369",
                    "汽水歌曲页:数字曲目 id 认")
        for bad in ["https://music.douyin.com/qishui/share/track?track_id=", "https://music.douyin.com/qishui/share/track?track_id=1&x=2",
                    "https://evil.example.com/qishui/share/track?track_id=1", ""] {
            expectEqual(P.sodaTrackURL(bad) == nil, true, "汽水歌曲页:\(bad) 不认")
        }
        expectEqual(P.sodaAlbumURL(id: "7687934888654342145")?.absoluteString,
                    "https://music.douyin.com/qishui/share/album?album_id=7687934888654342145", "汽水专辑页 URL")
        expectEqual(P.sodaArtistURL(id: "6841932444073986049")?.absoluteString,
                    "https://music.douyin.com/qishui/share/artist?artist_id=6841932444073986049", "汽水歌手页 URL")
        expectEqual(P.sodaAlbumURL(id: "a") == nil, true, "汽水专辑 id:不是数字挡掉")
        expectEqual(P.kkboxAlbumAppURL(id: "DY_DcEg9I9ARV8260S")?.absoluteString, "kkbox://album/DY_DcEg9I9ARV8260S#view",
                    "KKBOX 专辑 → 进 App 的深链")
        expectEqual(P.kkboxArtistAppURL(id: "CpWsMZtnOiWI4EO-Ej")?.absoluteString, "kkbox://artist/CpWsMZtnOiWI4EO-Ej#view",
                    "KKBOX 歌手 → 进 App 的深链")
        expectEqual(P.kkboxAlbumAppURL(id: "a/b") == nil, true, "KKBOX id:带斜杠挡掉")
        expectEqual(P.kkboxArtistAppURL(id: "") == nil, true, "KKBOX id:空串不给链接")
        expectEqual(P.amazonAlbumURL(asin: "B0DVKJ3PKW")?.absoluteString, "https://music.amazon.com/albums/B0DVKJ3PKW",
                    "Amazon 专辑页 URL")
        expectEqual(P.amazonArtistURL(asin: "B001KX03JE")?.absoluteString, "https://music.amazon.com/artists/B001KX03JE",
                    "Amazon 歌手页 URL")
        expectEqual(P.amazonAlbumURL(asin: "b0dvkj3pkw") == nil, true, "Amazon ASIN:小写挡掉")
        expectEqual(P.spotifyAlbumURL(id: "1e8cp3UgVJORQmHWHjvRiq")?.absoluteString,
                    "https://open.spotify.com/album/1e8cp3UgVJORQmHWHjvRiq", "Spotify 专辑页 URL")
        expectEqual(P.spotifyArtistURL(id: "72NhFAGG5Pt91VbheJeEPG")?.absoluteString,
                    "https://open.spotify.com/artist/72NhFAGG5Pt91VbheJeEPG", "Spotify 歌手页 URL")
        expectEqual(P.spotifyArtistURL(id: "72NhFAGG5Pt91VbheJeEP") == nil, true, "Spotify id:21 位挡掉")
        expectEqual(P.youtubeMusicAlbumURL(browseID: "MPREb_OUh6Wf3kq7x")?.absoluteString,
                    "https://music.youtube.com/browse/MPREb_OUh6Wf3kq7x", "YouTube Music 专辑页 URL")
        expectEqual(P.youtubeMusicArtistURL(channelID: "UCZONOh3FvcD-a_b")?.absoluteString,
                    "https://music.youtube.com/channel/UCZONOh3FvcD-a_b", "YouTube Music 歌手页 URL")
        expectEqual(P.youtubeMusicAlbumURL(browseID: "VLPL123") == nil, true, "YouTube Music 专辑页:不是 MPREb_ 开头挡掉")
        expectEqual(P.youtubeMusicArtistURL(channelID: "UC") == nil, true, "YouTube Music 歌手页:只有前缀挡掉")
        expectEqual(P.youtubeMusicArtistURL(channelID: "UC1/../x") == nil, true, "YouTube Music 歌手页:带斜杠挡掉")
        let withSoda = PlatformLinks(appleMusic: am, qqSong: qq, qqAlbum: nil, qqArtist: nil, neteaseSong: ne, sodaSong: soda)
        expectEqual(withSoda.songLink(forPlayerBundleID: PlaybackPlayer.soda.bundleIdentifier)?.platform, .soda,
                    "网页行:汽水播放 → 汽水歌曲页")
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.soda.bundleIdentifier) == nil, true,
                    "网页行:汽水播放但没存它的歌曲页 → nil,不拿别的平台顶上")
        expectEqual(PlatformLinks(appleMusic: nil, qqSong: nil, qqAlbum: nil, qqArtist: nil, neteaseSong: nil,
                                  kkboxArtist: P.kkboxArtistAppURL(id: "CpWsMZtnOiWI4EO-Ej")).isEmpty, false,
                    "只有歌手页也不算 isEmpty")

        // 「⋯」菜单的 ↗ 只给落到浏览器的链接,进 App 的深链不带(07 章决策 110)。
        for (raw, web) in [("https://y.qq.com/n/ryqq/songDetail/0039MnYb0qxYhV", true), ("http://example.com/a", true),
                           ("kkbox://album/DY_DcEg9I9ARV8260S#view", false), ("music://music.apple.com/cn/album/1", false),
                           ("spotify:track:72NhFAGG5Pt91VbheJeEPG", false)] {
            expectEqual(P.opensInBrowser(URL(string: raw)!), web, "↗ 落点: \(raw)")
        }
        let window = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"), encoding: .utf8)) ?? ""
        expectEqual(window.isEmpty, false, "↗ 落点(契约): 读到源码")
        expectEqual(sourceBytes(window, contain: "MoreMenuRow(title: PlatformLinks.opensInBrowser(row.url) ? row.title + \" ↗\" : row.title) {"),
                    true, "↗ 落点(契约): 「⋯」菜单按链接判带不带 ↗,不是每行都拼")
        expectEqual(sourceBytes(window, contain: "\"kkbox-song\""), false,
                    "↗ 落点(契约): KKBOX 这首歌不在目录入口里另占一行(跟下面「在 KKBOX 中显示」同名)")
        expectEqual(sourceBytes(window, contain: "let song = platformLinks?.kkboxSong {\n                    NSWorkspace.shared.open(song)"),
                    true, "↗ 落点(契约): 「在 KKBOX 中显示」有歌曲深链时打开它")
    }
}
