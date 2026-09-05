import LyrimuseCore
import Foundation

// Last.fm:第 N 次听 / 写法族 / 分页 / 计次规则 / 最近记录 feed。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runLastfmTests() {
    // ---- 「第 N 次听」的作废判据:按最新一条收听的时刻,而不是页内出现次数(2026-08-21) ----
    //
    // 用户报「第 15 次听下面紧跟着第 21 次听」。根因:原来只按页内出现次数判作废,而连播同一
    // 首歌时这一页很快被它占满 —— 新的挤进来、旧的挤出去,页内次数**不再增长**,缓存总数于是
    // 永久冻结(实测冻在 15,真实合计 22 = 园游会 10 + 園遊會 12 两个 Last.fm 实体),而实时行
    // 是每次换歌现取的、显示 21。完整推导见 PlayCountRecency 的注释。
    do {
        typealias R = PlayCountRecency
        func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
        let k = "周杰倫|园游会"

        // 同一个 key 多条 → 取**最新**那条(不是第一条也不是最后一条)
        expectEqual(R.newest([(k, at(1000)), (k, at(3000)), (k, at(2000))])[k], at(3000),
                    "次数作废: 取同曲最新那条的时刻")

        // 页内条数**饱和**时仍然分辨得出"多听了一次" —— 这正是原判据漏掉的那一类:
        // 两批都是 3 条(条数没变),但最新时刻从 3000 前进到 4000
        let before = R.newest([(k, at(1000)), (k, at(2000)), (k, at(3000))])
        let after = R.newest([(k, at(2000)), (k, at(3000)), (k, at(4000))])
        expectEqual(before[k], at(3000), "次数作废: 前一批的最新时刻")
        expectEqual(after[k]! > before[k]!, true,
                    "次数作废: 条数不变(3→3)但最新时刻前进 → 必须判成过期(原判据在这里失效)")

        // date 为 nil 的跳过(「正在播放」那条:还没落库、不在 userplaycount 里)
        expectEqual(R.newest([(k, at(5000)), (k, nil)])[k], at(5000), "次数作废: 无时间戳的条目不参与")
        expectEqual(R.newest([(k, nil)]).isEmpty, true, "次数作废: 只有无时间戳条目时不产出基线")
        // 不同 key 各自记账(两个写法在 Last.fm 上确实是两个实体)
        expectEqual(R.newest([(k, at(100)), ("周杰倫|園遊會", at(200))]).count, 2,
                    "次数作废: 两个写法各自一条")
    }

    // ---- 「第 N 次听」判据③:页内自相矛盾(2026-08-22) ----
    //
    // 判据①②都要跟上一轮比,而基线只在内存、次数表却持久化 —— App 重启后基线被重设成
    // 「当下」,那首歌不再被播一次就永远等不到作废。用户实测:缓存冻在 3、真实 12,那一页有
    // 11 行《开不了口 (live)》,视图侧减法把后 8 行全算成 ≤0,整片空白且不自愈。
    // 这一条只看当下这一页站不站得住,无状态,重启后第一轮就生效。
    do {
        typealias R = PlayCountRecency
        func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
        let now = at(10_000)
        let throttle: TimeInterval = 300

        // 用户那一幕:页内 11 行 vs 缓存 3 → 缓存必错。本进程还没问过(nil)→ 立刻作废,
        // 这正是"重启后第一轮就质疑一次"。
        expectEqual(R.contradicted(onPage: 11, cachedTotal: 3, lastFetched: nil,
                                   now: now, recheckAfter: throttle), true,
                    "判据③: 页内 11 行 > 缓存 3 且从没问过 → 作废")
        // 页内数 <= 缓存总数 = 没有矛盾。等号也不算 —— 缓存里是"到此刻为止的总数",
        // 页内正好看见这么多次是完全自洽的。
        expectEqual(R.contradicted(onPage: 3, cachedTotal: 3, lastFetched: nil,
                                   now: now, recheckAfter: throttle), false,
                    "判据③: 页内 3 行 = 缓存 3 → 自洽,不作废")
        expectEqual(R.contradicted(onPage: 2, cachedTotal: 12, lastFetched: nil,
                                   now: now, recheckAfter: throttle), false,
                    "判据③: 页内比缓存少 → 不作废")
        // 节流:Last.fm 自己的 userplaycount 滞后几分钟,刚问过就再问是每轮白发请求
        expectEqual(R.contradicted(onPage: 11, cachedTotal: 3, lastFetched: at(9_800),
                                   now: now, recheckAfter: throttle), false,
                    "判据③: 200s 前刚问过(< 300s 节流) → 这一轮不重取")
        expectEqual(R.contradicted(onPage: 11, cachedTotal: 3, lastFetched: at(9_700),
                                   now: now, recheckAfter: throttle), true,
                    "判据③: 距上次 300s 到点 → 重取")
        // 节流只在真有矛盾时才轮得到判 —— 没矛盾的话多久没问过都不该作废
        expectEqual(R.contradicted(onPage: 1, cachedTotal: 99, lastFetched: at(0),
                                   now: now, recheckAfter: throttle), false,
                    "判据③: 无矛盾时,再久没问过也不作废")
    }

    // ---- 「第 N 次听」判据④:距离上次验证太久,不看页内次数(2026-08-29) ----
    //
    // 真实案例:方大同《ORANGe MOON》缓存冻结在 1,直接查 Last.fm track.getInfo 核实
    // 真实 userplaycount = 31。根因是判据③的第一道闸 `onPage > cachedTotal`:这首歌很久
    // 没被主动播放,这次只是又听了一次重新出现在页面上,onPage=1 恰好没有超过冻住的旧值 1,
    // ③直接判"没问题"、压根不会走到"上次验证是多久以前"这一步。这条判据不依赖页内次数,
    // 只问时间,补上这个盲区。
    do {
        typealias R = PlayCountRecency
        func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
        let now = at(1_000_000)
        let maxAge: TimeInterval = 24 * 60 * 60

        // 从没验证过(nil)→ 无条件过期,宁可多查一次
        expectEqual(R.stale(lastFetched: nil, now: now, maxAge: maxAge), true,
                    "判据④: 从没验证过(nil) → 过期")
        // 刚验证过 → 不过期
        expectEqual(R.stale(lastFetched: at(1_000_000 - 60), now: now, maxAge: maxAge), false,
                    "判据④: 1 分钟前刚验证过 → 不过期")
        // 恰好到点(>=)→ 过期;差一点没到 → 不过期(边界值两侧都要对)
        expectEqual(R.stale(lastFetched: at(1_000_000 - 24 * 60 * 60), now: now, maxAge: maxAge), true,
                    "判据④: 恰好 24 小时前验证过 → 过期(>= 边界)")
        expectEqual(R.stale(lastFetched: at(1_000_000 - 24 * 60 * 60 + 1), now: now, maxAge: maxAge), false,
                    "判据④: 差 1 秒不到 24 小时 → 还不过期")
        // ⚠️ 核心场景:即使页内次数(1)没有超过缓存总数(旧值 1),只要验证时刻够久,判据④
        // 依然要能独立地判定过期——它完全不看这两个数字,这条断言就是在确认这一点
        // (跟判据③形成对比:同样的 onPage=1/cachedTotal=1,contradicted 会判 false)。
        expectEqual(R.contradicted(onPage: 1, cachedTotal: 1, lastFetched: nil,
                                   now: now, recheckAfter: 300), false,
                    "对比: 判据③在 onPage=1/cachedTotal=1 时判'没问题'(这正是它的盲点)")
        expectEqual(R.stale(lastFetched: at(1_000_000 - 2 * 24 * 60 * 60), now: now, maxAge: maxAge), true,
                    "判据④: 同样的场景,只看时间就能判过期,不受 onPage/cachedTotal 影响")
    }

    // ---- nowPlayingCount 追赶 trackPlayCounts(2026-08-24) ----
    //
    // 用户实测(《Controversy》):换歌那一刻 nowPlayingCount 取到 16(显示 17),trackPlayCounts
    // 随后追到 27(显示 28)——nowPlayingCount 没有任何自愈机制,永远停在 17,直到下一次换歌。
    // 这组用例钉住"只能涨、不能跌"的取舍。
    do {
        typealias R = PlayCountRecency
        // 正题:trackPlayCounts 学到了更高的总数 → 采纳,+1 换算成显示值
        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 27), 28,
                    "nowPlayingCount 追赶: 27+1=28,比当前 17 高 → 采纳")
        // 还没显示过(nil,理论上不该发生在这条路径,但当 0 处理不炸)
        expectEqual(R.reconciledNowPlayingCount(current: nil, freshTotal: 5), 6,
                    "nowPlayingCount 追赶: current 为 nil 时按 0 比较")
        // ⚠️ 只能涨、不能跌 —— 新数字更低时必须按兵不动,不能让显示的数字倒退
        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 10), nil,
                    "nowPlayingCount 追赶: 新总数更低 → 不采纳,返回 nil")
        // 等于当前值:没有新信息,不该触发一次无意义的写入(SwiftUI 不必要的重渲染)
        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 16), nil,
                    "nowPlayingCount 追赶: 换算后与当前相等 → 不采纳")
        // 差 1 也要涨 —— 阈值判断用的是 > 不是 >=,别把等于的情况错判成"该涨"
        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 17), 18,
                    "nowPlayingCount 追赶: 新总数比换算前的 total 还高一点 → 仍要涨")
    }

    // ---- LastfmRecentTracksPage:合并历史扫描的分页解析(2026-08-25) ----
    //
    // ensureTitleFormsIndex(写法索引)和 refreshDailyCounts(热力图)原来各自写了一遍这段
    // 解析,合并成一次扫描后收成一份纯函数。这组用例钉住合并前两处分别覆盖到的行为:
    // 单条时 track 是对象不是数组的怪癖、nowPlaying 行没有 uts 但仍要产出 Row(供写法
    // 索引收割)、totalPages 解析、响应形状不对时返回 nil。
    do {
        typealias P = LastfmRecentTracksPage

        func trackObj(name: String, artist: String, uts: String? = nil, nowPlaying: Bool = false) -> [String: Any] {
            var t: [String: Any] = ["name": name, "artist": ["#text": artist]]
            if nowPlaying {
                t["@attr"] = ["nowplaying": "true"]
            } else if let uts {
                t["date"] = ["uts": uts]
            }
            return t
        }

        func page(_ tracks: Any, totalPages: String = "1") -> [String: Any] {
            ["recenttracks": ["@attr": ["totalPages": totalPages], "track": tracks]]
        }

        // 多条:正常数组
        do {
            let json = page([
                trackObj(name: "开不了口", artist: "周杰倫", uts: "1700000000"),
                trackObj(name: "夜曲", artist: "周杰倫", nowPlaying: true),
            ], totalPages: "5")
            let result = P.parse(json)
            expectEqual(result?.totalPages, 5, "历史扫描解析: totalPages")
            expectEqual(result?.rows.count, 2, "历史扫描解析: 两行都产出 Row")
            expectEqual(result?.rows[0], .init(artist: "周杰倫", title: "开不了口", uts: 1_700_000_000),
                        "历史扫描解析: 落库的行带 uts")
            expectEqual(result?.rows[1].uts, nil,
                        "历史扫描解析: nowPlaying 行 uts 为 nil,但仍产出 Row(供写法索引收割)")
        }

        // 单条:Last.fm 的怪癖——track 是对象不是数组
        do {
            let json = page(trackObj(name: "十年", artist: "陳奕迅", uts: "1600000000"))
            let result = P.parse(json)
            expectEqual(result?.rows.count, 1, "历史扫描解析: 单条 track 是对象也要解出来")
            expectEqual(result?.rows.first?.title, "十年", "历史扫描解析: 单条对象的字段对得上")
        }

        // 畸形行:有 date 但 uts 不是合法数字 —— 仍产出 Row(供收割),uts 为 nil
        do {
            let json = page([["name": "畸形", "artist": ["#text": "X"], "date": ["uts": "not-a-number"]]])
            let result = P.parse(json)
            expectEqual(result?.rows.first?.uts, nil, "历史扫描解析: uts 解析失败时为 nil,不是整行丢弃")
            expectEqual(result?.rows.first?.artist, "X", "历史扫描解析: 畸形行仍保留 artist/title 供收割")
        }

        // 响应形状不对:调用方应视为这一页失败
        expectEqual(P.parse(["unexpected": 1]) == nil, true, "历史扫描解析: 缺 recenttracks 返回 nil")
        expectEqual(P.parse(["recenttracks": ["track": []]]) == nil, true, "历史扫描解析: 缺 @attr 返回 nil")

        // 空列表(账号没有任何 scrobble):不是错误,是"这一页零行"
        let empty = P.parse(page([]))
        expectEqual(empty?.rows.count, 0, "历史扫描解析: 空 track 数组产出零行,不是 nil")

        // 缺 name/artist 的行整条丢弃,不产出半残的 Row
        let missingField = P.parse(page([["artist": ["#text": "只有歌手没有歌名"]]]))
        expectEqual(missingField?.rows.count, 0, "历史扫描解析: 缺 name 的行整条丢弃")
    }

    // ---- Last.fm GET query 的双重编码(2026-08-22) ----
    //
    // 端点会对 query value 多解一次码(第二遍是 form-urlencoded 口径,`+` 当空格),所以
    // `+` 和 `%` 必须各多编一层。实测:track=…%2B… → error 6 Track not found;
    // track=…%252B… → 命中 userplaycount=2。用真实存在的乐队 `+44` 独立验证过是端点级行为。
    // URLComponents.queryItems 走的 urlQueryAllowed **放行 `+`**,正是这个坑的入口。
    do {
        typealias Q = LastfmQuery
        expectEqual(Q.escape("夜曲+窃爱 (Live)"),
                    "%E5%A4%9C%E6%9B%B2%252B%E7%AA%83%E7%88%B1%20%28Live%29",
                    "lastfm query: 加号编成 %252B(实测这一串才命中)")
        expectEqual(Q.escape("+44"), "%252B44", "lastfm query: 乐队名 +44")
        // 百分号同理要多编一层:服务端解两遍才还原成字面 %
        expectEqual(Q.escape("100%"), "100%2525", "lastfm query: 百分号编成 %2525")
        // 顺序守卫:先换 % 再换 + —— 反过来的话 %2B 里的 % 会被再啃一遍变成 %2525 2B
        expectEqual(Q.escape("a+b%c"), "a%252Bb%2525c", "lastfm query: 加号与百分号同时出现")
        // 不含这两个字符的 value 必须跟标准编码逐字节相同 —— 这是"对既有请求零影响"的依据
        expectEqual(Q.escape("开不了口 (live)"),
                    "%E5%BC%80%E4%B8%8D%E4%BA%86%E5%8F%A3%20%28live%29",
                    "lastfm query: 不含 +/% 时与标准编码一致")
        expectEqual(Q.escape("Beyond"), "Beyond", "lastfm query: 纯 ASCII 原样")
        // 空格用 %20 而不是 +(用 + 会被第二遍解码当成空格,结果碰巧也对,但两侧口径要一致)
        expectEqual(Q.escape("a b").contains("+"), false, "lastfm query: 空格不编成加号")
        expectEqual(Q.queryString([("method", "track.getinfo"), ("track", "+44")]),
                    "method=track.getinfo&track=%252B44", "lastfm query: 拼串按传入顺序")
    }

    // ---- PlayCountVariants:「第 N 次听」的写法孪生族(2026-08-18,括号风格分裂实测) ----
    //
    // 丁世光《神经志》实测:`一口（The Day You Left Me）`全角 2 次/`一口(The Day You Left
    // Me)`半角无空格 25 次/`一口`1 次——Last.fm 按写法各记各的账,合并要把整族都问到。
    do {
        typealias V = PlayCountVariants
        let full = V.siblings(artist: "丁世光", title: "一口（The Day You Left Me）").map(\.title)
        expectEqual(full.contains("一口(The Day You Left Me)"), true, "写法族: 全角→半角无空格")
        expectEqual(full.contains("一口 (The Day You Left Me)"), true, "写法族: 全角→半角带空格")
        expectEqual(full.contains("一口"), true, "写法族: 全角→纯中文名")
        expectEqual(full.contains("一口（The Day You Left Me）"), false, "写法族: 不含本尊")
        expectEqual(full.count <= 6, true, "写法族: 封顶 6 个,实际 \(full.count)")
        // 半角无空格(历史大头写法)反向也要能生成全角
        let half = V.siblings(artist: "丁世光", title: "一口(The Day You Left Me)").map(\.title)
        expectEqual(half.contains("一口（The Day You Left Me）"), true, "写法族: 半角→全角")
        // 纯 ASCII 歌名(E.T./Simon)从不分裂,零候选零请求
        expectEqual(V.siblings(artist: "丁世光", title: "E.T.").isEmpty, true, "写法族: 纯 ASCII 零候选")
        expectEqual(V.siblings(artist: "丁世光", title: "Simon").isEmpty, true, "写法族: Simon 零候选")
        // 纯英文 feat 副题:只补一个「去副题」候选,不生成全角/半角括号族(那套只为
        // 含汉字歌名)。(2026-08-19 第二波推翻了此前"各来源写法一致、零候选"的假设 ——
        // 实测同一首歌带/不带 feat 后缀两本账,见 isCatalogNoiseSubtitle。)
        let featSibs = V.siblings(artist: "MJ", title: "Scream (feat. Janet Jackson)")
        expectEqual(featSibs.map(\.title), ["Scream"], "写法族: 纯英文 feat 副题只给去副题候选")
        // 无副题的繁体歌名仍然给繁简孪生
        let han = V.siblings(artist: "方大同", title: "我不是農人")
        expectEqual(han.first?.title ?? "", "我不是农人", "写法族: 无副题繁体名→繁简孪生")
        // 繁体+副题:括号族 + 繁简孪生都要在(封顶 6 装得下)
        let mixed = V.siblings(artist: "丁世光", title: "小師妹（Love Triangle）")
        expectEqual(mixed.count, 4, "写法族: 小師妹给 4 个候选")
        expectEqual(mixed.map(\.title).contains("小師妹(Love Triangle)"), true, "写法族: 半角无空格优先在列")
        expectEqual(mixed.map(\.title).contains("小师妹（Love Triangle）"), true, "写法族: 繁简孪生也在列")
        // 字形变体(麼 U+9EBC/麽 U+9EBD,2026-08-18 实测:70 条 scrobble 记在麽形下,
        // 括号/繁简候选全扑空——ICU t2s 两个都折到「么」,s2t 永远只生成「麼」,必须显式列表)
        let mo = V.siblings(artist: "丁世光", title: "愛在什麼地方都有（Love Is Everywhere）").map(\.title)
        expectEqual(mo.contains("愛在什麽地方都有(Love Is Everywhere)"), true,
                    "写法族: 麼→麽 字形变体×半角括号(实测大头写法)")
        expectEqual(mo.count <= 6, true, "写法族: 麽族封顶 6,实际 \(mo.count)")
        expectEqual(V.siblings(artist: "X", title: "為你我受冷風吹").map(\.title).contains("爲你我受冷風吹"),
                    true, "写法族: 无副题歌名也给字形变体(為/爲)")
    }

    // ---- PlayCountFold:写法索引的折叠键(2026-08-19,数据驱动合并的地基) ----
    //
    // 把历史上真实出现过的写法按这个键归族,查次数时按族查——取代猜枚举。断言覆盖实测
    // 见过的全部分裂维度;「括号副题不折」是刻意取舍(括号常携带 Live/Remaster 版本信息)。
    do {
        typealias F = PlayCountFold
        // 实测三形合一:全角麼 / 半角麽 / 简体小写半角(丁世光《愛在什麼地方都有》分裂案)
        let a = F.key(artist: "丁世光", title: "愛在什麼地方都有（Love Is Everywhere）")
        expectEqual(a, F.key(artist: "丁世光", title: "愛在什麽地方都有(Love Is Everywhere)"),
                    "折叠键: 全角麼形 == 半角麽形")
        expectEqual(a, F.key(artist: "丁世光", title: "爱在什么地方都有(love is everywhere)"),
                    "折叠键: == 简体小写半角形")
        // 双语拼接(R1):实测《月食 The Weeping Woman》30 次 vs《月食》6 次两族
        expectEqual(F.key(artist: "丁世光", title: "月食 The Weeping Woman"),
                    F.key(artist: "丁世光", title: "月食"), "折叠键: CJK+拉丁双语拼接取 CJK 段")
        expectEqual(F.key(artist: "X", title: "P.S. 我愛你"),
                    F.key(artist: "X", title: "我爱你"), "折叠键: 拉丁在前 CJK 在后也收敛")
        // 括号副题不折(版本信息)—— 与导出脚本同取舍
        expectNotEqual(F.foldTitle("一口(The Day You Left Me)"), F.foldTitle("一口"),
                       "折叠键: 括号副题不折")
        expectNotEqual(F.foldTitle("好的一天 (Live)"), F.foldTitle("好的一天"),
                       "折叠键: Live 版不并")
        // 空格/大小写/歌手繁简
        expectEqual(F.key(artist: "陶喆", title: "Susan 说"),
                    F.key(artist: "陶喆", title: "susan说"), "折叠键: 空格与大小写")
        expectEqual(F.key(artist: "陳奕迅", title: "富士山下"),
                    F.key(artist: "陈奕迅", title: "富士山下"), "折叠键: 歌手名繁简")
        // 段落交错的双语名不收敛(宁可漏合不错合)
        expectNotEqual(F.foldTitle("月食 The 月食 Woman"), F.foldTitle("月食"),
                       "折叠键: CJK/拉丁交错不折")

        // 再版噪音副题折叠(2026-08-19 用户实测:宇多田ヒカル Automatic 两本账)——
        // remaster 家族是同一份录音的目录学差异,折;真版本(Live/Remix)照旧分开。
        expectEqual(F.key(artist: "宇多田ヒカル", title: "Automatic (Remastered 2014)"),
                    F.key(artist: "宇多田ヒカル", title: "Automatic"),
                    "折叠键: (Remastered 2014) 并入本尊")
        expectEqual(F.foldTitle("Song (2014 Remaster)"), F.foldTitle("Song"),
                    "折叠键: 年份在前的 Remaster 也并")
        expectEqual(F.foldTitle("Song (Remastered Version)"), F.foldTitle("Song"),
                    "折叠键: Remastered Version 也并")
        expectEqual(F.foldTitle("月食 (Remastered)"), F.foldTitle("月食"),
                    "折叠键: 中文歌名的再版噪音同样并")
        expectNotEqual(F.foldTitle("Song (Remix)"), F.foldTitle("Song"),
                       "折叠键: Remix 是真版本,不并")
        expectNotEqual(F.foldTitle("Song (Live 2014 Remaster)"), F.foldTitle("Song"),
                       "折叠键: 混着 Live 的副题不并(宁可漏合)")
        // 猜枚举兜底(索引未建成时)也要给纯拉丁歌名补「去副题」候选
        let autoSibs = PlayCountVariants.siblings(artist: "宇多田ヒカル",
                                                  title: "Automatic (Remastered 2014)")
        expectEqual(autoSibs.contains { $0.title == "Automatic" }, true,
                    "写法族: 纯拉丁 + 再版噪音副题给出去副题候选")

        // feat 客串署名家族(2026-08-19 第二波用户实测:王力宏《盖世英雄 (feat. 欧阳靖 &
        // 李岩)》第 2 次 vs《蓋世英雄》几十次)—— 署名是歌手信息不是版本,并入本尊。
        expectEqual(F.key(artist: "王力宏", title: "盖世英雄 (feat. 欧阳靖 & 李岩)"),
                    F.key(artist: "王力宏", title: "蓋世英雄"),
                    "折叠键: (feat. …) 并入本尊(含繁简)")
        expectEqual(F.foldTitle("完美的互动 (feat J-Lim & Rain)"), F.foldTitle("完美的互動"),
                    "折叠键: 无点号的 feat 也并")
        expectEqual(F.foldTitle("Song (featuring X)"), F.foldTitle("Song"),
                    "折叠键: featuring 全拼也并")
        expectEqual(F.foldTitle("Song (ft. X)"), F.foldTitle("Song"),
                    "折叠键: ft. 缩写也并")
        expectNotEqual(F.foldTitle("Song (Feathers)"), F.foldTitle("Song"),
                       "折叠键: feat 开头的普通词不并")
        expectNotEqual(F.foldTitle("Song (feat.)"), F.foldTitle("Song"),
                       "折叠键: 空署名不并")

        // 补齐到参考实现 export-lastfm-tracks.py 的口径(2026-08-22)。三族都在那份
        // 2026-08-18 与用户逐对核定的规则里,Swift 侧此前漏搬 —— 不是新发明的规则。
        //
        // ① bonus track:用户报的原案。实测 Last.fm 两个实体「一路向北」14 次、
        //    「一路向北 (bonus track)」2 次,界面只显示 2。
        expectEqual(F.key(artist: "周杰倫", title: "一路向北 (bonus track)"),
                    F.key(artist: "周杰伦", title: "一路向北"),
                    "折叠键: (bonus track) 并入本尊(用户报的原案,含歌手繁简)")
        expectEqual(F.foldTitle("Song (Bonus Track)"), F.foldTitle("Song"),
                    "折叠键: 大写 (Bonus Track) 同并")
        expectEqual(F.foldTitle("Song (Japanese Bonus Track)"), F.foldTitle("Song"),
                    "折叠键: 带地区限定词的附加曲标记同并")
        expectEqual(F.foldTitle("Song (Bonus)"), F.foldTitle("Song"),
                    "折叠键: 光写 (Bonus) 也并")
        // 白名单而不是 \w+ 的理由:带版本信息的必须挡住(宁可漏合)
        expectNotEqual(F.foldTitle("Song (Live Bonus Track)"), F.foldTitle("Song"),
                       "折叠键: 混着 Live 的附加曲标记不并")
        expectNotEqual(F.foldTitle("Song (Bonus Beats)"), F.foldTitle("Song"),
                       "折叠键: (Bonus Beats) 是混音,不并")
        // ② explicit:内容分级标记,无标记本尊通常就是这一版
        expectEqual(F.key(artist: "方大同", title: "无所谓 (Explicit)"),
                    F.key(artist: "方大同", title: "無所謂"),
                    "折叠键: (Explicit) 并入本尊(索引实测碰撞)")
        // 刻意不收 (Clean):消音版是另一份音频。索引里真有《Simple and Clean》,
        // 一旦哪天改成括号内子串匹配就会误伤它 —— 这两条断言就是那道栅栏。
        expectNotEqual(F.foldTitle("Song (Clean)"), F.foldTitle("Song"),
                       "折叠键: (Clean) 是另一份音频,不并")
        expectNotEqual(F.foldTitle("Song (Simple and Clean)"), F.foldTitle("Song"),
                       "折叠键: 副题里含 clean 的普通词不并")
        // ③ (with X):参考实现 T1 一直把 with 与 feat 并列。索引实测 7 例真碰撞
        expectEqual(F.key(artist: "周杰倫", title: "不該 (with aMEI)"),
                    F.key(artist: "周杰倫", title: "不該"),
                    "折叠键: (with X) 客串署名并入本尊(索引实测碰撞)")
        expectEqual(F.foldTitle("Toronto 2014 (with Mustafa)"), F.foldTitle("Toronto 2014"),
                    "折叠键: 纯拉丁歌名的 (with X) 同并")
        // 「前缀后必须跟点/空格」那道守卫要同时挡住 without —— 少了它 (Without You) 会被剥
        expectNotEqual(F.foldTitle("Song (Without You)"), F.foldTitle("Song"),
                       "折叠键: (Without You) 不是署名,不并")
        expectNotEqual(F.foldTitle("Song (with)"), F.foldTitle("Song"),
                       "折叠键: with 后面空署名不并")
        // 参考实现「刻意不做」清单里的,这里也必须不折 —— 防后人顺手加进白名单
        expectNotEqual(F.foldTitle("Xscape (original version)"), F.foldTitle("Xscape"),
                       "折叠键: (original version) 是另一套制作,不并")
        expectNotEqual(F.foldTitle("Rock With You (single version)"), F.foldTitle("Rock With You"),
                       "折叠键: (single version) 单曲剪辑不并(用户未拍板)")
        expectNotEqual(F.foldTitle("愛情轉移(國)"), F.foldTitle("愛情轉移"),
                       "折叠键: (國) 语言标记不立通则(同名國/粵两版是真的两份录音)")
        // 猜枚举兜底同样要给附加曲标记补「去副题」候选(索引未建成时走这条)
        let bonusSibs = PlayCountVariants.siblings(artist: "周杰倫", title: "一路向北 (bonus track)")
        expectEqual(bonusSibs.contains { $0.title == "一路向北" }, true,
                    "写法族: (bonus track) 给出去副题候选")

        // 剥掉目录学噪音之后不能让 R1 再把版本标记当译名吃掉(2026-08-22,补 bonus track
        // 那一族时用真索引实测出来的**回归**:方大同《悟空 2003 demo (bonus track)》
        // 剥完成 "悟空 2003 demo",R1 取 CJK 段 -> 并进《悟空》,Demo 是另一份录音)。
        expectNotEqual(F.key(artist: "方大同", title: "悟空 2003 demo (bonus track)"),
                       F.key(artist: "方大同", title: "悟空"),
                       "折叠键: 剥掉附加曲标记后 R1 不许把 Demo 版并进本尊")
        expectNotEqual(F.foldTitle("流沙 Live Version (Remastered)"), F.foldTitle("流沙"),
                       "折叠键: 派生串里的 Live Version 挡住 R1")
        // 但派生串**仍然要**走 R1 —— 这一条是真数据里存在的正例,别为了上面那条把它一起关掉
        expectEqual(F.key(artist: "丁世光", title: "低潮期 Tough Days (feat.葉喜兒)"),
                    F.key(artist: "丁世光", title: "低潮期"),
                    "折叠键: 剥掉 feat 后双语拼接名照旧收敛(实测正例)")
        // ---- 第三批(2026-08-22,用户拍板改口径)----
        // ⑥ R1 守卫**套到原串**:中文歌名的 Live/Demo 版不再被当译名收进录音室版。
        //    这一条此前反过来钉着「现状」(expectEqual),用户拍板后翻面 —— 见 foldTitle 注释。
        expectNotEqual(F.key(artist: "陶喆", title: "流沙 - Live"),
                       F.key(artist: "陶喆", title: "流沙"),
                       "折叠键: 中文歌名的 - Live 不再并进本尊")

        // ---- 第二批(2026-08-22,并行核实回来之后)----
        // ④ 破折号版本尾缀:参考实现 T2 的另一半(`Bad - 2012 Remaster = Bad`)。
        //    索引里 216 条 ` - ` 尾缀,只有 6 条能过 isCatalogNoiseSubtitle,4 例真并。
        expectEqual(F.key(artist: "Michael Jackson", title: "Bad - 2012 Remaster"),
                    F.key(artist: "Michael Jackson", title: "Bad"),
                    "折叠键: 破折号尾缀 - 2012 Remaster 并入本尊(索引实测碰撞)")
        expectEqual(F.foldTitle("Room 608 - Remastered"), F.foldTitle("Room 608"),
                    "折叠键: 光写 - Remastered 也并")
        // 别把参考实现的 `\s*[-–]\s*` 照抄过来 —— 那个会把 Anti-Remastered 切成 Anti
        expectNotEqual(F.foldTitle("Anti-Remastered"), F.foldTitle("Anti"),
                       "折叠键: 破折号两侧必须有空白(Anti-Remastered 不许切)")
        // 其余 210 条破折号尾缀一条都不许动 —— 它们是真的不同录音
        expectNotEqual(F.foldTitle("Melody - Live"), F.foldTitle("Melody"),
                       "折叠键: - Live 不并(纯拉丁歌名)")
        expectNotEqual(F.foldTitle("Talking - Demo Version"), F.foldTitle("Talking"),
                       "折叠键: - Demo Version 不并")
        expectNotEqual(F.foldTitle("It's All Right With Me - Remastered 2006/Rudy Van Gelder Edition"),
                       F.foldTitle("It's All Right With Me"),
                       "折叠键: remaster 后面还跟别的词的尾缀不并(宁可漏合)")
        // 交替循环 + 剥完 trim 尾部连接符:两层一起掉,不留下 "x -"
        expectEqual(F.foldTitle("Song - 2012 Remaster (feat. Y)"), F.foldTitle("Song"),
                    "折叠键: 破折号尾缀与括号副题交替剥(两层一起掉)")
        // 这一条才真正压在 trimTrailingJoiners 上:剥掉 (2012 Remaster) 之后剩 "Song -",
        // 而 dashSuffixSplit 要求破折号两侧都有空白、切不动它,不 trim 就落成 "song-"
        expectEqual(F.foldTitle("Song - (2012 Remaster)"), F.foldTitle("Song"),
                    "折叠键: 剥完要擦掉本尊尾巴上的连接符")
        // ⑤ (with X) 头词黑名单:当下 0 命中,钉住是为了防将来爵士库那批 "with strings"
        expectEqual(F.foldTitle("不該 (with aMEI)"), F.foldTitle("不該"),
                    "折叠键: 真人署名照旧折(黑名单不许误伤)")
        expectEqual(F.foldTitle("等你下课 (with 杨瑞代)"), F.foldTitle("等你下课"),
                    "折叠键: 中文署名照旧折")
        expectNotEqual(F.foldTitle("Song (with strings)"), F.foldTitle("Song"),
                       "折叠键: (with strings) 是编配、另一份录音,不并")
        expectNotEqual(F.foldTitle("Song (with orchestra)"), F.foldTitle("Song"),
                       "折叠键: (with orchestra) 不并")
        expectNotEqual(F.foldTitle("Song (With or Without You)"), F.foldTitle("Song"),
                       "折叠键: (With or Without You) 是另一首歌的歌名词组,不并")
        expectNotEqual(F.foldTitle("Song (with backing vocals)"), F.foldTitle("Song"),
                       "折叠键: (with backing vocals) 不并")
        // feat 家族不受黑名单影响(它后面语法上只能跟表演者)
        expectEqual(F.foldTitle("Song (feat. The Weeknd)"), F.foldTitle("Song"),
                    "折叠键: feat. 后面跟 The 照旧折(黑名单只管 with)")

        // 第三批续:R1 守卫全覆盖之后的连带断言
        expectNotEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音"),
                       "折叠键: 方括号 Live 尾缀也不并进本尊")
        expectNotEqual(F.foldTitle("飛機場的10:30 - Demo Version"), F.foldTitle("飛機場的10:30"),
                       "折叠键: - Demo Version 不并进本尊")
        expectNotEqual(F.foldTitle("Melody - Live"), F.foldTitle("Melody"),
                       "折叠键: 英文歌名的 - Live 照旧分开(中英口径现在一致)")
        // 两个重度退化键:多首**不同的歌**曾被折进同一族
        expectNotEqual(F.key(artist: "方大同", title: "All Night - Live版"),
                       F.key(artist: "方大同", title: "Ten Reasons - Live版"),
                       "折叠键: 三首 - Live版 不再焊成同一族")
        expectNotEqual(F.foldTitle("All Night - Live版"), F.foldTitle("Live版"),
                       "折叠键: - Live版 不再退化成光剩版本词")
        expectNotEqual(F.foldTitle("Something Stupid [Live 08] featuring 薛凱琪"),
                       F.foldTitle("薛凱琪"),
                       "折叠键: 方括号不在结尾时也不许退化成尾部人名")
        // ⑦ 版本尾缀分隔符归一:分隔符不携带信息,副题内容才携带
        // ⚠️ 裸场次标记**不**归一(2026-08-22 并行核实推翻了原设计):album.getinfo 实测
        //    方大同 21 条 `X - Live` 与《This Love Live 2007》21 首曲目完全双射,而 30 条
        //    `X (Live)` 只有 2 首在那张里 —— 两种写法是**两场不同的演唱会**,归一会错并。
        expectNotEqual(F.foldTitle("流沙 - Live"), F.foldTitle("流沙 (Live)"),
                       "折叠键: 裸 Live 不归一(两种写法可能是两场不同演唱会)")
        expectNotEqual(F.foldTitle("南音 [Live]"), F.foldTitle("南音 - Live"),
                       "折叠键: 裸 Live 的方括号形也不归一")
        // 但**带场次信息**的照旧归一 —— 那个内容真的标识了一场演出
        expectEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音 - Live 08"),
                    "折叠键: 带场次信息的版本尾缀照旧归一")
        expectEqual(F.foldTitle("南音 - 15 Khalil Live in HK 2011"),
                    F.foldTitle("南音 (15 Khalil Live in HK 2011)"),
                    "折叠键: 具名演唱会尾缀照旧归一")
        // 两场不同演唱会绝不能并
        expectNotEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音 - Live"),
                       "折叠键: Live 08 与裸 Live 不并")
        expectEqual(F.foldTitle("沙灘 - 鋼琴版"), F.foldTitle("沙滩 (钢琴版)"),
                    "折叠键: 中文版本词的分隔符也归一(整串以「版」收尾)")
        expectEqual(F.foldTitle("Rock With You - Single Version"),
                    F.foldTitle("Rock With You (single version)"),
                    "折叠键: single version 的分隔符归一")
        expectEqual(F.foldTitle("逗陣兄弟 - 獨唱版"), F.foldTitle("逗阵兄弟 (独唱版)"),
                    "折叠键: 獨唱版 分隔符归一")
        expectNotEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音 [Timeless Live 2009]"),
                       "折叠键: 两场不同演唱会不并")
        // 译名尾缀要留给 R1 收敛,不能被分隔符归一截走
        expectEqual(F.foldTitle("月食 - The Weeping Woman"), F.foldTitle("月食"),
                    "折叠键: 破折号接的是**译名**时照旧走 R1 收敛")
        // 单字中文歌名 + 英文尾缀靠 collapseBilingual 里 `han.count >= 2` 那道下限活着,
        // 不是靠版本守卫 —— 那条下限别动(并行核实点出来的)
        expectNotEqual(F.foldTitle("鬼 - Overture"), F.foldTitle("鬼"),
                       "折叠键: 单字中文歌名不被 R1 吞掉(han.count >= 2 下限)")
        // dashSuffixSplit 必须取**最后**一个分隔符:Foundation 里 .backwards 与
        // .regularExpression 同用时不生效,实测返回第一个匹配
        expectEqual(F.foldTitle("苏州河 - 慕容雪 - Mandarin Version"),
                    F.foldTitle("苏州河 - 慕容雪 (Mandarin Version)"),
                    "折叠键: 多破折号时取最后一个分隔符")
        // 中文最常用的 version 一词以「本」收尾,hasSuffix(\"版\") 接不住,要单独判
        expectEqual(F.foldTitle("你不知道的事 - 宋曉青版本"),
                    F.foldTitle("你不知道的事 (宋晓青版本)"),
                    "折叠键: 「…版本」也算版本尾缀")
        // 归一之后必须再剥一次目录学噪音,否则方括号 remaster 会从本尊拆出去
        expectEqual(F.foldTitle("一口 [Remastered 2014]"), F.foldTitle("一口"),
                    "折叠键: 方括号 remaster 归一后被补剥掉,不从本尊拆出去")
        // `Live版` 是一个词,词表接不住 —— 靠「以 版 收尾」这条判据挡住 R1 的退化
        expectNotEqual(F.foldTitle("All Night - Live版"), F.foldTitle("Live版"),
                       "折叠键: Live版 靠「以 版 收尾」判据挡住 R1 退化")
        // ⑧ 歌手写法归并只作用在查族用的 familyKey 上,且**没有手写表**(2026-09-04 起):表由
        // LocalArtistAliases.derive 从本机数据推出来再灌进来。这里用一份最小的 MusicBrainz 缓存夹具
        // 复现旧静态表覆盖过的形态,证明"去掉手工表之后能力没丢"。
        typealias LA = LocalArtistAliases
        let mb = LA.MusicBrainzCaches(
            aliasCache: ["Crowd Lu": "卢广仲", "Khalil Fong": "方大同"],
            identityZh: ["Soft Lipa": "蛋堡"],
            primaryAliases: ["陶喆": ["David Tao"], "周杰伦": ["Jay Chou", "ジェイ・チョウ", "K"],
                             "宇多田ヒカル": ["Hikaru Utada", "Utada", "宇多田光"],
                             "Count Basie": [], "Fantasia": [], "阿肆": ["A Si"]])
        let artistTable = LA.derive(caches: mb, entries: [])
        F.setLocalArtistAliases(artistTable)
        defer { F.setLocalArtistAliases([:]) }
        expectEqual(F.familyKey(artist: "David Tao", title: "找自己"),
                    F.familyKey(artist: "陶喆", title: "找自己"),
                    "查族键: David Tao 与 陶喆 同族(MusicBrainz 别名)")
        expectEqual(F.familyKey(artist: "Jay Chou", title: "不該"),
                    F.familyKey(artist: "周杰倫", title: "不该"),
                    "查族键: Jay Chou 与 周杰倫 同族(叠繁简)")
        expectEqual(F.familyKey(artist: "Hikaru Utada", title: "Automatic"),
                    F.familyKey(artist: "宇多田光", title: "Automatic"),
                    "查族键: 罗马字与汉字写法同族")
        expectEqual(F.familyKey(artist: "宇多田ヒカル", title: "Automatic"),
                    F.familyKey(artist: "宇多田光", title: "Automatic"),
                    "查族键: 片假名与汉字写法同族")
        expectEqual(F.familyKey(artist: "Soft Lipa", title: "偷偷"),
                    F.familyKey(artist: "蛋堡", title: "偷偷"),
                    "查族键: Soft Lipa 与 蛋堡 同族(identity 缓存的 zh;要 ArtistCredit 边界守卫先修好)")
        expectEqual(F.familyKey(artist: "Khalil Fong & Fiona Sit", title: "Oasis"),
                    F.familyKey(artist: "方大同", title: "Oasis"),
                    "查族键: 合唱串先归首位再查别名(Khalil Fong & Fiona Sit → Khalil Fong → 方大同)")
        // 过短的别名不用:去空格后不足 3 个字符的(`K` 这种)撞上别的艺人的概率太高
        expectEqual(F.familyKey(artist: "K", title: "X"), F.key(artist: "K", title: "X"),
                    "查族键: 1 字符的 MusicBrainz 别名 K 不入表")
        // 别名匹配是**整串相等**:索引里真有 Count Basie / Fantasia,不许被 asi 命中
        expectNotEqual(F.familyKey(artist: "Count Basie", title: "X"),
                       F.familyKey(artist: "阿肆", title: "X"),
                       "查族键: 别名整串相等,Count Basie 不许被 asi 命中")
        expectNotEqual(F.familyKey(artist: "Fantasia", title: "X"),
                       F.familyKey(artist: "阿肆", title: "X"),
                       "查族键: Fantasia 也不许被 asi 命中(索引里真有这个艺人)")
        expectEqual(F.familyKey(artist: "A Si", title: "X"), F.familyKey(artist: "阿肆", title: "X"),
                    "查族键: A Si(去空格后 asi,3 字符,刚够)与 阿肆 同族")
        // familyKey 仍要做合唱归首位(2026-08-20 那条能力不能丢)
        expectEqual(F.familyKey(artist: "Daniel Caesar & Mustafa", title: "Toronto 2014"),
                    F.familyKey(artist: "Daniel Caesar", title: "Toronto 2014"),
                    "查族键: 合唱 credit 仍归首位")
        // 表里没有的歌手不受影响;表里有的必须真被改写(否则等于没接上)
        expectEqual(F.familyKey(artist: "Michael Jackson", title: "Bad"),
                    F.key(artist: "Michael Jackson", title: "Bad"),
                    "查族键: 不在别名表里的歌手与 key 一致")
        expectNotEqual(F.familyKey(artist: "David Tao", title: "找自己"),
                       F.key(artist: "David Tao", title: "找自己"),
                       "查族键: 在表里的歌手必须真被改写")

        // ⑨ 歌名维度的罗马字/译名别名(2026-08-29 起有,2026-09-04 起同样没有手写表):由
        // EnrichTitleAliases.derive 从本机缓存推出来再灌进来。这里直接灌一份结果,只测 familyKey 的
        // 接线与安全约束;推断本身在下面「第三层歌名别名」那组测。
        F.setLocalTitleAliases(["方大同": ["lovelovelove": "爱爱爱", "nanyin": "南音", "blackhole": "黑洞里"]])
        defer { F.setLocalTitleAliases([:]) }
        expectEqual(F.familyKey(artist: "方大同", title: "Love Love Love"),
                    F.familyKey(artist: "方大同", title: "爱爱爱"),
                    "查族键: 方大同《Love Love Love》与《爱爱爱》同族")
        expectEqual(F.familyKey(artist: "Khalil Fong", title: "Love Love Love"),
                    F.familyKey(artist: "方大同", title: "愛愛愛"),
                    "查族键: 罗马字歌手名 + 译名歌名,两层别名叠加也要同族")
        // ⚠️ 核心安全约束:这张表必须按(歌手,歌名)登记,不能是全局 title->title——
        // 王力宏名下真实存在一首同样叫《Love Love Love》的歌,跟方大同《爱爱爱》毫不相干。
        expectNotEqual(F.familyKey(artist: "王力宏", title: "Love Love Love"),
                       F.familyKey(artist: "方大同", title: "爱爱爱"),
                       "查族键: 王力宏《Love Love Love》不该被牵连进方大同《爱爱爱》")
        expectEqual(F.familyKey(artist: "王力宏", title: "Love Love Love"),
                    F.key(artist: "王力宏", title: "Love Love Love"),
                    "查族键: 王力宏这首歌不在别名表覆盖范围内,应与 key 一致(未被改写)")
        expectEqual(F.familyKey(artist: "某歌手", title: "爱爱爱"),
                    F.key(artist: "某歌手", title: "爱爱爱"),
                    "查族键: 不在表里的歌手名下同名歌曲不受影响")
        expectEqual(F.familyKey(artist: "方大同", title: "nanyin"),
                    F.familyKey(artist: "方大同", title: "南音"),
                    "查族键: 方大同《nanyin》与《南音》同族")
        expectEqual(F.familyKey(artist: "方大同", title: "南音"),
                    F.key(artist: "方大同", title: "南音"),
                    "查族键: 用中文本名查询时不会被错误地二次改写")
        expectEqual(F.familyKey(artist: "Khalil Fong", title: "Black Hole"),
                    F.familyKey(artist: "方大同", title: "黑洞裡"),
                    "查族键: 罗马字歌手名 + 英文歌名,叠加繁体写法也要同族")
        expectEqual(F.familyKey(artist: "方大同", title: "Weather Report"),
                    F.key(artist: "方大同", title: "Weather Report"),
                    "查族键: 没被推出别名的歌(Weather Report 61 s 过场曲,时长证伪)不受影响")
    }

    // ---- 歌名别名的两层查找:本机推断表 优先于 自动发现表(setDiscoveredTitleAliases) ----
    do {
        typealias F = PlayCountFold
        defer { F.setDiscoveredTitleAliases([:]); F.setLocalTitleAliases([:]) }

        F.setDiscoveredTitleAliases(["测试歌手": ["testsong": "测试歌曲"]])
        expectEqual(F.familyKey(artist: "测试歌手", title: "TestSong"),
                    F.familyKey(artist: "测试歌手", title: "测试歌曲"),
                    "发现表: 注入的映射能让 familyKey 同族")
        expectEqual(F.familyKey(artist: "别的歌手", title: "TestSong"),
                    F.key(artist: "别的歌手", title: "TestSong"),
                    "发现表: 只在登记的歌手键下生效,不会牵连同名歌名的其它歌手")
        // 本机推断表(同歌曲 id / 时长+歌词,证据硬)优先于发现表(Last.fm 整秒时长撞相等,弱)
        F.setLocalTitleAliases(["测试歌手": ["testsong": "另一首歌"]])
        expectEqual(F.familyKey(artist: "测试歌手", title: "TestSong"),
                    F.familyKey(artist: "测试歌手", title: "另一首歌"),
                    "别名查找: 本机推断表与发现表撞键时本机表优先")
    }

    // ---- 计次规则(ScrobbleRule):必须与 collector 的 listenThreshold/minTrackSecs 一致 ----
    do {
        // 短于 30s 不计次(minTrackSecs)。
        expectEqual(ScrobbleRule.thresholdFraction(durationMs: 29_000), nil, "计次: 29s 的曲目不计次")
        expectEqual(ScrobbleRule.thresholdFraction(durationMs: 0), nil,
                    "计次: 时长未知画不出刻度(collector 仍会在 240s 计,见 ScrobbleRule 注释)")
        // 普通长度:一半处计次。
        expectEqual(ScrobbleRule.thresholdFraction(durationMs: 200_000), 0.5, "计次: 200s 的歌在一半处计次")
        // 长歌封顶 240s(capSecs):600s 的歌在 240/600 = 0.4 处计次,不用等一半。
        expectEqual(ScrobbleRule.thresholdFraction(durationMs: 600_000), 0.4, "计次: 长歌 4 分钟封顶")
        // 恰好 480s 是两条规则的分界:min(240, 240) 都是 0.5。
        expectEqual(ScrobbleRule.thresholdFraction(durationMs: 480_000), 0.5, "计次: 480s 处两规则相等")
    }

    // MARK: - LastfmRecentFeed(collector 落盘的最近记录 feed,2026-09-03)
    //
    // 字段名是跟 Go 侧 lastfmfeed.go 的契约;样本 JSON 照 Go 那边 TestWriteLastfmRecentFeedShape
    // 写出来的形状手抄(歌名合成)。
    do {
        let sample = """
        {"username":"KhalilChan3","fetchedAt":1800000000,"total":24271,
         "nowPlaying":{"artist":"A","title":"Now","album":"NP","image":"l-np.png"},
         "tracks":[{"artist":"B","title":"One","album":"Alb","image":"xl1.png","uts":1700000100},
                   {"artist":"C","title":"Two","uts":1700000000}]}
        """
        let feed = LastfmRecentFeed.decode(Data(sample.utf8))
        expectEqual(feed?.username, "KhalilChan3", "feed: username")
        expectEqual(feed?.total, 24271, "feed: total")
        expectEqual(feed?.nowPlaying?.title, "Now", "feed: now-playing 行")
        expectEqual(feed?.nowPlaying?.uts, nil, "feed: now-playing 行没有 uts")
        expectEqual(feed?.tracks.count, 2, "feed: 已完成两条")
        expectEqual(feed?.tracks[1].album, nil, "feed: album 缺省为 nil")
        expectEqual(feed?.tracks[0].uts, 1700000100, "feed: uts 解成秒")
        expectEqual(LastfmRecentFeed.decode(Data("{\"tracks\":[]}".utf8)), nil, "feed: 缺必填字段 → nil")

        let at = Date(timeIntervalSince1970: 1800000000)
        expectEqual(feed?.isFresh(now: at.addingTimeInterval(179)), true, "feed: 3 分钟内算活着")
        expectEqual(feed?.isFresh(now: at.addingTimeInterval(180)), false, "feed: 满 3 分钟算陈旧")
        expectEqual(feed?.isFresh(now: at.addingTimeInterval(-5)), false, "feed: 时间戳在未来(时钟回拨)不算活着")

        expectEqual(LastfmRecentFeed.totalPages(total: 24271, pageSize: 20), 1214, "feed: 总页数向上取整(跟网页 1214 页一致)")
        expectEqual(LastfmRecentFeed.totalPages(total: 40, pageSize: 20), 2, "feed: 整除")
        expectEqual(LastfmRecentFeed.totalPages(total: 0, pageSize: 20), 1, "feed: 0 条也至少 1 页")

        // 今天的派生:todayStart=1000。
        // ① 窗口盖住整天(最旧一行 900 < 1000):数窗口里 ≥1000 的行,精确。
        let r1 = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200, 1100, 900, 800], todayStart: 1000,
                                             bucketToday: 99, syncedThrough: 0)
        expectEqual(r1.count, 3, "today: 窗口盖住整天 → 数窗口")
        expectEqual(r1.exact, true, "today: 窗口盖住整天 → 精确")
        // ② 窗口盖不住(全是今天的 50 首),但日桶今天同步到 1150:桶 40 + 晚于 1150 的 2 行。
        let r2 = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200, 1100, 1050], todayStart: 1000,
                                             bucketToday: 40, syncedThrough: 1150)
        expectEqual(r2.count, 42, "today: 日桶 + 同步后新行")
        expectEqual(r2.exact, true, "today: 日桶今天同步过 → 精确")
        // ②' 日桶今天没有条目(nil 当 0)但同步过:只算同步后的行。
        let r2b = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200], todayStart: 1000,
                                              bucketToday: nil, syncedThrough: 1100)
        expectEqual(r2b.count, 2, "today: 桶为 nil 当 0")
        // ③ 两者都不行:窗口全是今天、日桶停在昨天 → 只给下界、不精确。
        let r3 = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200, 1100, 1050], todayStart: 1000,
                                             bucketToday: nil, syncedThrough: 500)
        expectEqual(r3.count, 4, "today: 退化成下界")
        expectEqual(r3.exact, false, "today: 日桶停在昨天 → 不精确,调用方补一个请求")
        // ④ 空 feed(新账号)+ 今天同步过:0。
        let r4 = LastfmRecentFeed.todayCount(rowUTS: [], todayStart: 1000, bucketToday: nil, syncedThrough: 1200)
        expectEqual(r4.count, 0, "today: 空窗口")
        expectEqual(r4.exact, true, "today: 空窗口但今天同步过 → 精确 0")
    }

    // MARK: - LastfmPageComposer(按绝对位置拼页,2026-09-03)
    //
    // 行用整数模拟(值 = 这条记录的身份),身份闭包直接 String(值)。
    do {
        typealias C = LastfmPageComposer
        typealias S = LastfmPageComposer.Source<Int>
        let ident: (Int) -> String = { String($0) }

        // 起点换算:抓第 3 页时总数 100,现在 103 → 多了 3 条,第 3 页的旧起点 40 现在是 43。
        expectEqual(C.firstPosition(page: 3, pageSize: 20, totalAtFetch: 100, totalNow: 103), 43, "拼页: 总数涨 3 → 起点下移 3")
        expectEqual(C.firstPosition(page: 1, pageSize: 20, totalAtFetch: 100, totalNow: 100), 0, "拼页: 没涨 → 原位")
        expectEqual(C.firstPosition(page: 2, pageSize: 20, totalAtFetch: 100, totalNow: 99), nil, "拼页: 总数变小(删过记录)→ 这份来源作废")

        // feed 给位置 0..49(值 0..49);一个抓取时总数 100、现在 103 的第 3 页缓存(旧位置 40..59
        // 的值 43..62,因为那时的位置 i 对应现在的记录 i+3)。要拼现在的第 3 页 = 位置 40..59。
        let feed = S(firstPosition: 0, rows: Array(0 ..< 50))
        let cachedP3 = S(firstPosition: 43, rows: Array(43 ..< 63))
        expectEqual(C.compose(page: 3, pageSize: 20, total: 103, sources: [feed, cachedP3], identity: ident),
                    Array(40 ..< 60), "拼页: feed 的 40..49 + 缓存页下移后的 50..59 拼齐")
        // 只有 feed:第 2 页(20..39)拼得齐,第 3 页(40..59)有洞 → nil。
        expectEqual(C.compose(page: 2, pageSize: 20, total: 103, sources: [feed], identity: ident),
                    Array(20 ..< 40), "拼页: 只靠 feed 拼第 2 页")
        expectEqual(C.compose(page: 3, pageSize: 20, total: 103, sources: [feed], identity: ident),
                    nil, "拼页: 有洞 → nil,交给网络")
        // 最后一页不满 20 行按 total 截。
        let tail = S(firstPosition: 40, rows: Array(40 ..< 45))
        expectEqual(C.compose(page: 3, pageSize: 20, total: 45, sources: [tail], identity: ident),
                    Array(40 ..< 45), "拼页: 最后一页只有 5 行")
        // 超出范围的页 → nil;total 0 → nil。
        expectEqual(C.compose(page: 4, pageSize: 20, total: 45, sources: [tail], identity: ident), nil, "拼页: 页码越界")
        expectEqual(C.compose(page: 1, pageSize: 20, total: 0, sources: [feed], identity: ident), nil, "拼页: 空账号")
        // 错位检测:总数涨了 3,但其中一条是手机迟到同步**插进 feed 窗口之下**的——比它新的那段
        // 记录真实只下移了 2,缓存页按"下移 3"铺过来就整体偏一格:它的第 8 条(真实记录 49)落到
        // 位置 50,而 feed 的位置 49 已经是记录 49 → 同一条出现两次 → 判错位 → nil。
        let misaligned = S(firstPosition: 43, rows: Array(42 ..< 62))
        expectEqual(C.compose(page: 3, pageSize: 20, total: 103, sources: [feed, misaligned], identity: ident),
                    nil, "拼页: 同一条记录出现两次 → 判错位 → nil")
        // 先到先占:两份来源同一位置不同值时,排前面的赢(调用方按新鲜度排序)。
        let newer = S(firstPosition: 40, rows: [1000, 1001])
        let older = S(firstPosition: 40, rows: [2000, 2001] + Array(42 ..< 60))
        expectEqual(C.compose(page: 3, pageSize: 20, total: 103, sources: [newer, older], identity: ident)?.prefix(2).map { $0 },
                    [1000, 1001], "拼页: 同一位置以排前面的来源为准")
        // 负起点的来源(理论上不该出现)整份跳过,不崩。
        expectEqual(C.compose(page: 1, pageSize: 20, total: 30, sources: [S(firstPosition: -5, rows: Array(0 ..< 30)), S(firstPosition: 0, rows: Array(0 ..< 20))], identity: ident),
                    Array(0 ..< 20), "拼页: 负起点来源被跳过")
    }

    // MARK: - OnThisDayPlanner / ListeningMilestones(那年今日计划 + 收听足迹,2026-09-03)
    do {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let fmt = DateFormatter()
        fmt.calendar = cal; fmt.timeZone = cal.timeZone; fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let key: (Date) -> String = { fmt.string(from: $0) }
        let today = fmt.date(from: "2026-09-03")!.addingTimeInterval(3600 * 13) // 当天 13:00

        // 计划:去年当天有 → 天窗口;前年当天无、那周有 → 周窗口;3 年前整段都无 → 不发。
        let buckets: [String: Int] = ["2025-09-03": 5, "2024-09-01": 2, "2024-09-06": 7, "2023-08-20": 3]
        let plan = OnThisDayPlanner.plan(today: today, years: 3, dailyCounts: buckets, synced: true, dayKey: key)
        expectEqual(plan.map { "\($0.yearsAgo):\($0.span.rawValue):\($0.expected ?? -1)" },
                    ["1:1:5", "2:7:9"], "那年今日计划: 天有就发天、天空周有就发周、都空不发")
        expectEqual(plan.map { key($0.from) }, ["2025-09-03", "2024-08-31"], "那年今日计划: 周窗口从 -3 天起")
        expectEqual(plan.map { key($0.to) }, ["2025-09-04", "2024-09-07"], "那年今日计划: 窗口终点是开区间的次日 0 点")
        // 日桶没同步过:退回老办法,三年只看当天、都发、expected 未知。
        let blind = OnThisDayPlanner.plan(today: today, years: 3, dailyCounts: [:], synced: false, dayKey: key)
        expectEqual(blind.map { "\($0.yearsAgo):\($0.span.rawValue):\($0.expected == nil)" },
                    ["1:1:true", "2:1:true", "3:1:true"], "那年今日计划: 日桶未同步 → 三年当天全发")
        expectEqual(OnThisDayPlanner.plan(today: today, years: 3, dailyCounts: [:], synced: true, dayKey: key).isEmpty,
                    true, "那年今日计划: 日桶同步过且全空 → 零请求")

        // 足迹:2026-08-30 ~ 09-02 连续四天,09-03(今天)还没记录 → 当前连续 4;最长 5(08-10~08-14)。
        var days: [String: Int] = [:]
        for d in ["2026-08-10", "2026-08-11", "2026-08-12", "2026-08-13", "2026-08-14"] { days[d] = 10 }
        for d in ["2026-08-30", "2026-08-31", "2026-09-01", "2026-09-02"] { days[d] = 20 }
        days["2026-08-12"] = 209 // 单日最高
        days["2023-01-05"] = 7   // 起点
        days["2023-09-02"] = 40  // 往年同期(1/1~9/3 之内)
        days["2023-12-25"] = 99  // 往年同期之外
        days["2025-11-01"] = 3   // 2025 年有记录但不在同期区间 → 往年同期该跳过 2025 取 2023
        let s = ListeningMilestones.summarize(dailyCounts: days, today: today, calendar: cal, dayKey: key)
        expectEqual(s.firstDay, "2023-01-05", "足迹: 起点是最早一天")
        expectEqual(s.daysSinceFirst, 1338, "足迹: 从起点到今天含两端的天数")
        expectEqual(s.recordedDays, 13, "足迹: 有记录天数 = 非零天数")
        expectEqual(s.peak, .init(day: "2026-08-12", count: 209), "足迹: 单日最高")
        expectEqual(s.currentStreak, 4, "足迹: 今天还没记录时从昨天起算连续")
        expectEqual(s.longestStreak, 5, "足迹: 最长连续")
        expectEqual(s.longestStreakEnd, "2026-08-14", "足迹: 最长连续的最后一天")
        expectEqual(s.yearToDate, 50 + 80 + 209 - 10, "足迹: 今年至今合计")
        expectEqual(s.priorYearSameSpan?.year, 2023, "足迹: 往年同期取最近一个同期有记录的年份(跳过 2025)")
        expectEqual(s.priorYearSameSpan?.count, 47, "足迹: 往年同期只算 1/1~今天月日之内(12-25 不算)")
        // 今天有记录时连续从今天起算。
        var days2 = days; days2["2026-09-03"] = 1
        expectEqual(ListeningMilestones.summarize(dailyCounts: days2, today: today, calendar: cal, dayKey: key).currentStreak,
                    5, "足迹: 今天有记录 → 连续含今天")
        expectEqual(ListeningMilestones.summarize(dailyCounts: [:], today: today, calendar: cal, dayKey: key),
                    .init(firstDay: nil, daysSinceFirst: nil, recordedDays: 0, peak: nil, currentStreak: 0,
                          longestStreak: 0, longestStreakEnd: nil, yearToDate: 0, priorYearSameSpan: nil),
                    "足迹: 空日桶全零")
        // 里程碑步长。
        expectEqual(ListeningMilestones.nextMilestone(total: 24300).target, 25000, "里程碑: 万级按 1000")
        expectEqual(ListeningMilestones.nextMilestone(total: 24300).remaining, 700, "里程碑: 还差")
        expectEqual(ListeningMilestones.nextMilestone(total: 25000).target, 26000, "里程碑: 正好在整点 → 下一个")
        expectEqual(ListeningMilestones.nextMilestone(total: 4321).target, 4500, "里程碑: 千级按 500")
        expectEqual(ListeningMilestones.nextMilestone(total: 42).target, 100, "里程碑: 百以内按 100")
    }

    // ---- 「那边没有次数」结论的退避重探(2026-09-03) ----
    //
    // 陳綺貞《慢歌 3》16:36 落库,五次查 userplaycount 都是 0,过了 15 分钟宽限那一轮把它永久钉进
    // playCountUnavailable、随快照落盘,重启也不重问 —— 而 Last.fm 网页那边已经显示 1 次。
    // 现在"没有"带时间戳:1 h → 6 h → 24 h 封顶,到期重探;拿到正数整套清掉(那部分在
    // LastfmStatsService,这里只钉日程表)。
    do {
        typealias B = PlayCountUnavailableBackoff
        let h = 3600.0
        expectEqual(B.delay(strikes: 1), 1 * h, "次数退避: 第 1 次判没有 → 1 小时后重探")
        expectEqual(B.delay(strikes: 2), 6 * h, "次数退避: 第 2 次 → 6 小时")
        expectEqual(B.delay(strikes: 3), 24 * h, "次数退避: 第 3 次 → 24 小时")
        expectEqual(B.delay(strikes: 9), 24 * h, "次数退避: 之后封顶 24 小时,不再增长")
        expectEqual(B.delay(strikes: 0), 1 * h, "次数退避: 非法的 0 次按第 1 档")
        let t0 = Date(timeIntervalSince1970: 1_788_424_564) // 那条 scrobble 的时刻
        expectEqual(B.isDue(markedAt: t0, strikes: 1, now: t0.addingTimeInterval(59 * 60)), false,
                    "次数退避: 59 分钟还不到期")
        expectEqual(B.isDue(markedAt: t0, strikes: 1, now: t0.addingTimeInterval(60 * 60)), true,
                    "次数退避: 满 1 小时到期(闭区间)")
        expectEqual(B.isDue(markedAt: t0, strikes: 2, now: t0.addingTimeInterval(5 * h)), false,
                    "次数退避: 第 2 次之后 5 小时不到期")
        expectEqual(B.isDue(markedAt: t0, strikes: 2, now: t0.addingTimeInterval(6 * h)), true,
                    "次数退避: 第 2 次之后 6 小时到期")
        expectEqual(B.isDue(markedAt: t0, strikes: 3, now: t0.addingTimeInterval(23 * h)), false,
                    "次数退避: 封顶档 23 小时不到期")
        expectEqual(B.isDue(markedAt: t0, strikes: 7, now: t0.addingTimeInterval(24 * h)), true,
                    "次数退避: 封顶档 24 小时到期")
        expectEqual(B.isDue(markedAt: t0, strikes: 1, now: t0.addingTimeInterval(-10)), false,
                    "次数退避: 时钟倒退(now 早于记录时刻)不算到期")
    }

    // ---- 「第 N 次听」合并明细:为什么并进来 + 跨写法合并/编号(2026-09-04) ----
    //
    // 弹框上半段每种写法旁边挂的原因标签,由 PlayCountFoldExplainer 沿 PlayCountFold 的真实折叠
    // 步骤逐级比对得出 —— 标签跟规则对不上会比没有标签更误导,所以每一档各钉一条真实分裂形态
    // (全部取自 12 章 §7 记录过的用户实测案例)。
    do {
        typealias E = PlayCountFoldExplainer
        func r(_ a: (String, String), _ b: (String, String)) -> [PlayCountFoldReason] {
            E.reasons(base: (artist: a.0, title: a.1), variant: (artist: b.0, title: b.1))
        }
        expectEqual(r(("Prince", "Call My Name"), ("Prince", "Call My Name")), [],
                    "合并原因: 写法完全一致 → 空")
        expectEqual(r(("Prince", "Call My Name"), ("Prince", "Call my name")), [.caseOrSpacing],
                    "合并原因: 只差大小写 → 大小写/空格")
        expectEqual(r(("Prince", "Call My Name"), ("Prince", "CallMyName")), [.caseOrSpacing],
                    "合并原因: 只差空格 → 大小写/空格")
        expectEqual(r(("丁世光", "一口(The Day You Left Me)"), ("丁世光", "一口（The Day You Left Me）")), [.fullwidth],
                    "合并原因: 全角括号 → 全角/半角(丁世光《一口》实测)")
        expectEqual(r(("盧廣仲", "我不是农人"), ("盧廣仲", "我不是農人")), [.hanScript],
                    "合并原因: 繁简 → 繁简(《我不是农人》11/3 实测)")
        expectEqual(r(("宇多田ヒカル", "Automatic"), ("宇多田ヒカル", "Automatic (Remastered 2014)")), [.catalogNoise],
                    "合并原因: Remaster 副题 → 目录学噪音")
        expectEqual(r(("王力宏", "蓋世英雄"), ("王力宏", "盖世英雄 (feat. 欧阳靖 & 李岩)")), [.catalogNoise],
                    "合并原因: 繁简 + feat 副题 → 报**更深**的那一档(目录学噪音),不是两个都报")
        expectEqual(r(("方大同", "沙滩 (钢琴版)"), ("方大同", "沙滩 - 钢琴版")), [.versionSuffix],
                    "合并原因: 同一个版本尾缀、分隔符不同 → 版本尾缀写法")
        // 裸 `Live` 刻意**不**归一(两种分隔符实测指向两场不同的演唱会,见 ambiguousConcertMarkers),
        // 所以这两种写法压根不是一族、明细里不会同时出现;真要问也只能是 other —— 钉住这个取舍,
        // 免得哪天有人为了让标签"好看"把它归进版本尾缀那一档。
        expectEqual(r(("方大同", "流沙 (Live)"), ("方大同", "流沙 - Live")), [.other],
                    "合并原因: 裸 Live 的两种分隔符不是一族 → other")
        expectEqual(r(("陳綺貞", "月食"), ("陳綺貞", "月食 The Weeping Woman")), [.bilingualTitle],
                    "合并原因: 双语拼接名 → 双语歌名(《月食》30/6 实测)")
        expectEqual(r(("Daniel Caesar", "Toronto 2014"), ("Daniel Caesar & Mustafa", "Toronto 2014")), [.artistCredit],
                    "合并原因: 合唱署名归首位 → 合唱署名")
        PlayCountFold.setLocalArtistAliases(["davidtao": "陶喆"])
        expectEqual(r(("陶喆", "普通朋友"), ("David Tao", "普通朋友")), [.artistAlias],
                    "合并原因: 罗马字歌手(本机推断的歌手别名表)→ 歌手别名")
        PlayCountFold.setLocalArtistAliases([:])
        expectEqual(r(("陶喆", "普通朋友"), ("David Tao", "普通朋友")), [.other],
                    "合并原因: 没有别名表时 David Tao 与 陶喆 对不上任何一档 → other")
        PlayCountFold.setLocalTitleAliases(["方大同": ["lovelovelove": "爱爱爱"]])
        expectEqual(r(("方大同", "爱爱爱"), ("方大同", "Love Love Love")), [.titleAlias],
                    "合并原因: 歌名别名表(本机推断)→ 歌名别名")
        PlayCountFold.setLocalTitleAliases([:])
        expectEqual(r(("周杰倫", "園遊會"), ("周杰伦 & 派伟俊", "园游会")), [.artistCredit, .hanScript],
                    "合并原因: 歌手、歌名各差一档 → 两条,歌手在前")
        expectEqual(r(("Prince", "Call My Name"), ("Prince", "Kiss")), [.other],
                    "合并原因: 压根不是一族的(规则演进留的缝)→ 报 other,不藏")

        // 专辑名维度(同一个 Last.fm 条目下专辑名分裂,《晴天》葉惠美/叶惠美 实测)
        expectEqual(E.albumReason(base: "葉惠美", variant: "叶惠美"), .hanScript, "专辑名原因: 繁简")
        expectEqual(E.albumReason(base: "First Love", variant: "First Love (Remastered 2014)"), .catalogNoise,
                    "专辑名原因: Remaster 标注 → 目录学噪音")
        expectEqual(E.albumReason(base: "八度空间", variant: "八度空间"), nil, "专辑名原因: 相同 → nil")
        expectEqual(E.albumReason(base: nil, variant: "八度空间"), nil, "专辑名原因: 一方没有专辑名 → 不判")
        // 对不上任何一档 = 就是两张不同的专辑(原专辑 vs 精选集 / 另一语言的专辑名),不是写法差异,
        // 不挂标签 —— 跟写法族那层的 .other 语义刻意不同(2026-09-04 用户问「其他折叠规则这里指的是什么」)
        expectEqual(E.albumReason(base: "葉惠美", variant: "范特西"), nil, "专辑名原因: 两张不同的专辑 → nil,不挂标签")
        expectEqual(E.albumReason(base: "心中的日月", variant: "Shangri-la"), nil,
                    "专辑名原因: 同一张专辑的另一语言名 → 也判不出来,nil(没有专辑别名表,接受)")
    }
    do {
        typealias M = PlayCountBreakdownMath
        func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
        func v(_ artist: String, _ title: String, total: Int, isSelf: Bool = false,
               _ times: [Double], failed: Bool = false) -> M.VariantInput {
            .init(artist: artist, title: title, total: total, isSelf: isSelf,
                  reasons: isSelf ? [] : [.hanScript],
                  plays: times.map { (date: at($0), album: nil) }, failed: failed)
        }

        // 两种写法各自拉完:合计 = 各自之和,编号从合计往下、按时间倒序
        let two = M.build([
            v("周杰倫", "园游会", total: 3, isSelf: true, [3000, 2000, 1000]),
            v("周杰倫", "園遊會", total: 2, [2500, 500]),
        ])
        expectEqual(two.total, 5, "合并明细: 两种写法合计 3 + 2")
        expectEqual(two.plays.map { $0.date.timeIntervalSince1970 }, [3000, 2500, 2000, 1000, 500],
                    "合并明细: 合并后按时间倒序,不管输入顺序")
        expectEqual(two.plays.map(\.variantIndex), [0, 1, 0, 0, 1], "合并明细: 每条记得自己属于哪种写法")
        expectEqual(two.ordinals, [5, 4, 3, 2, 1], "合并明细: 全部拉完时每行都编号")
        expectEqual(two.ordinalCutoff, nil, "合并明细: 全部拉完 → 没有编号截止")
        expectEqual(two.canLoadOlder, false, "合并明细: 全部拉完 → 不给「加载更早的」")
        expectEqual(two.variants.map(\.reasons), [[], [.hanScript]], "合并明细: 本尊无原因,孪生带原因")

        // 跨写法同一时刻**不去重**(2026-09-05 撤掉第一版的去重):卢广仲《Boring》实测 `卢广仲` 13 条 +
        // `Crowd Lu` 5 条里 4 对同一分钟——是同一次收听被两台设备各 scrobble 一次,Last.fm 上 18 条都真实
        // 计数,行上的 18 也是这么加的;去重会制造假的"两边不一致"。同一写法内部同一时刻的多条用 dup 区分。
        let dup = M.build([
            v("卢广仲", "Boring", total: 3, isSelf: true, [3000, 2000, 2000]),
            v("Crowd Lu", "Boring", total: 3, [3000, 2000, 100]),
        ])
        expectEqual(dup.total, 6, "合并明细: 合计 = 各写法 total 之和,同秒的双端重复照数")
        expectEqual(dup.plays.count, 6, "合并明细: 列表原样列出全部 6 条")
        expectEqual(dup.plays.map(\.variantIndex), [0, 1, 0, 0, 1, 1],
                    "合并明细: 同秒两条并排(本尊在前),色点各归各的写法")
        expectEqual(Set(dup.plays.map(\.id)).count, 6, "合并明细: 同刻多条靠 dup 序号区分身份")
        expectEqual(dup.ordinals, [6, 5, 4, 3, 2, 1], "合并明细: 编号连续,跟 Last.fm 的计数一致")

        // 有写法没拉完:比它已拉到的最旧一条更早的位置不编号(中间可能藏着它没拉到的收听)
        let partial = M.build([
            v("A", "x", total: 300, isSelf: true, [5000, 3000]),   // 没拉完,最旧已拉 3000
            v("A", "X", total: 2, [4000, 1000]),                    // 拉完了
        ])
        expectEqual(partial.ordinalCutoff, at(3000), "合并明细: 截止 = 没拉完那种写法已拉到的最旧一条")
        expectEqual(partial.total, 302, "合并明细: 合计仍按各写法 total 算")
        expectEqual(partial.ordinals, [302, 301, 300, nil], "合并明细: 截止之后的行照常编号,之前的留空")
        expectEqual(partial.canLoadOlder, true, "合并明细: 有没拉完的 → 给「加载更早的」")
        // 两种都没拉完 → 取较晚的那个截止
        let both = M.build([
            v("A", "x", total: 300, isSelf: true, [5000, 3000]),
            v("A", "X", total: 300, [4000, 3500]),
        ])
        expectEqual(both.ordinalCutoff, at(3500), "合并明细: 多种都没拉完 → 截止取最晚的")

        // 某写法取数失败:留在清单里、合计不算它、整体不编号(宁可不编号,不编错)
        let failed = M.build([
            v("A", "x", total: 2, isSelf: true, [2000, 1000]),
            v("A", "X", total: 0, [], failed: true),
        ])
        expectEqual(failed.hasFailure, true, "合并明细: 失败的写法保留在清单里")
        expectEqual(failed.total, 2, "合并明细: 合计不含失败的写法")
        expectEqual(failed.ordinals, [nil, nil], "合并明细: 有写法失败 → 全部不编号")
        expectEqual(failed.canLoadOlder, false, "合并明细: 失败的写法不算「还能加载」")
        expectEqual(failed.variants[1].exhausted, false, "合并明细: 失败的写法永远不算拉完")

        // total 为 0 的本尊(用户点的那行 Last.fm 说没有):空明细、不崩
        let empty = M.build([v("A", "x", total: 0, isSelf: true, [])])
        expectEqual(empty.total, 0, "合并明细: 本尊 0 次 → 合计 0")
        expectEqual(empty.ordinals, [], "合并明细: 没有条目就没有编号")

        // 专辑名分组:同一写法下按专辑名数条数,条数降序、同数按名字;空/纯空白专辑名归成 nil 一组;
        // 只数这一写法自己的记录(2026-09-04 用户指出《晴天》葉惠美/叶惠美 两种专辑名要看得见)
        let albums = M.build([
            .init(artist: "周杰倫", title: "晴天", total: 6, isSelf: true, reasons: [], plays: [
                (date: at(6000), album: "葉惠美"), (date: at(5000), album: "叶惠美"),
                (date: at(4000), album: "葉惠美"), (date: at(3000), album: " "),
                (date: at(2000), album: "叶惠美"), (date: at(1000), album: "葉惠美"),
            ]),
            .init(artist: "周杰伦", title: "晴天", total: 1, isSelf: false, reasons: [.hanScript],
                  plays: [(date: at(500), album: "范特西")]),
        ])
        expectEqual(albums.albumGroups(variantIndex: 0).map { ($0.album ?? "∅") + ":\($0.count)" },
                    ["葉惠美:3", "叶惠美:2", "∅:1"],
                    "专辑分组: 按条数降序,空白专辑名归 nil 一组")
        expectEqual(albums.albumGroups(variantIndex: 1).map { ($0.album ?? "∅") + ":\($0.count)" }, ["范特西:1"],
                    "专辑分组: 只数这一写法自己的记录")
        expectEqual(M.build([v("A", "x", total: 2, isSelf: true, [2000, 1000])]).albumGroups(variantIndex: 0).count, 1,
                    "专辑分组: 全部没有专辑名 → 只有 nil 一组(界面据此不画子行)")
    }

    // ---- 第三层歌名别名:从本机 enrich 缓存推「英文歌名 → 中文歌名」(2026-09-04) ----
    //
    // 用户点开方大同《Oasis》的合并明细问「能不能把中文对应的歌名也合并进来」。本机缓存里
    // `Khalil Fong|Oasis|梦想家 The Dreamer` 与 `方大同|那沙漠里的水|梦想家 The Dreamer` 各自独立解析,
    // 都落到网易云 id 2635125902、时长 161 s —— 这比 Last.fm 整秒 duration 撞相等硬得多。
    do {
        typealias A = EnrichTitleAliases
        func e(_ artist: String, _ title: String, netease: String? = nil, qq: String? = nil, dur: Double? = nil) -> A.Entry {
            .init(artist: artist, title: title, neteaseURL: netease, qqMusicURL: qq, durationSecs: dur)
        }
        let ne = "https://music.163.com/song?id=2635125902"

        expectEqual(A.songIDs(neteaseURL: ne, qqMusicURL: nil), ["netease:2635125902"], "本机别名: 网易云 id 解析")
        expectEqual(A.songIDs(neteaseURL: "https://music.163.com/#/song?id=42&x=1", qqMusicURL: nil), ["netease:42"],
                    "本机别名: 带 # 路由的网易云地址也认")
        expectEqual(A.songIDs(neteaseURL: nil, qqMusicURL: "https://y.qq.com/n/ryqq/songDetail/002lChJY23SXj7"), ["qq:002lChJY23SXj7"],
                    "本机别名: QQ songDetail 的 mid")
        expectEqual(A.songIDs(neteaseURL: nil, qqMusicURL: "https://y.qq.com/n/ryqq/search?w=Khalil+Fong+Oasis"), [],
                    "本机别名: QQ 搜索页地址不是身份")
        expectEqual(A.songIDs(neteaseURL: "https://open.spotify.com/search/x", qqMusicURL: nil), [],
                    "本机别名: 别的平台的地址不认")

        // 本案:两条不同写法(连歌手写法都不同:Khalil Fong 是罗马字别名)落到同一个网易云 id。
        // 歌手别名同样没有手写表 —— 这里先灌一份本机推断结果(推断本身在下一组测)。
        PlayCountFold.setLocalArtistAliases(["khalilfong": "方大同"])
        defer { PlayCountFold.setLocalArtistAliases([:]) }
        let oasis = A.derive([
            e("Khalil Fong", "Oasis", netease: ne, dur: 161.000022),
            e("方大同", "那沙漠里的水", netease: ne, dur: 161),
            e("方大同", "那沙漠里的水", netease: ne, dur: 161), // 另一张专辑名的同一条,不影响
        ])
        expectEqual(oasis, ["方大同": ["oasis": "那沙漠里的水"]], "本机别名: Oasis → 那沙漠里的水(歌手键折到中文本名)")
        // 灌进 PlayCountFold 之后,两种写法成一族;原因标签两端各一条
        PlayCountFold.setLocalTitleAliases(oasis)
        expectEqual(PlayCountFold.familyKey(artist: "Khalil Fong", title: "Oasis"),
                    PlayCountFold.familyKey(artist: "方大同", title: "那沙漠里的水"),
                    "本机别名: 灌入后 familyKey 相等 → 查次数按一族合并")
        expectEqual(PlayCountFoldExplainer.reasons(base: (artist: "Khalil Fong", title: "Oasis"),
                                                   variant: (artist: "方大同", title: "那沙漠里的水")),
                    [.artistAlias, .titleAlias], "本机别名: 明细里的原因标签 = 歌手别名 + 歌名别名")
        PlayCountFold.setLocalTitleAliases([:])
        expectEqual(PlayCountFold.familyKey(artist: "Khalil Fong", title: "Oasis")
                    == PlayCountFold.familyKey(artist: "方大同", title: "那沙漠里的水"), false,
                    "本机别名: 清空后不再同族(别让这条测试的状态漏给别的断言)")

        // 闸 1:同一个 id 被匹配给两首不同的中文歌 → 整组不采纳
        expectEqual(A.derive([
            e("方大同", "Oasis", netease: ne), e("方大同", "那沙漠里的水", netease: ne), e("方大同", "梦想家", netease: ne),
        ]), [:], "本机别名: 中文侧不唯一 → 不采纳")
        // 闸 2:两侧都有时长且差太多 → 不采纳;一侧缺时长 → 只凭 id 采纳
        expectEqual(A.derive([e("方大同", "Oasis", netease: ne, dur: 161), e("方大同", "那沙漠里的水", netease: ne, dur: 240)]), [:],
                    "本机别名: 时长差 79 s → 不采纳")
        expectEqual(A.derive([e("方大同", "Oasis", netease: ne, dur: 161), e("方大同", "那沙漠里的水", netease: ne, dur: 163)]),
                    ["方大同": ["oasis": "那沙漠里的水"]], "本机别名: 时长差 2 s 在容差内")
        expectEqual(A.derive([e("方大同", "Oasis", netease: ne), e("方大同", "那沙漠里的水", netease: ne, dur: 161)]),
                    ["方大同": ["oasis": "那沙漠里的水"]], "本机别名: 一侧没时长 → 只凭 id")
        // 闸 3:同一个英文键从两个 id 组推出不同的中文名 → 两条都撤
        expectEqual(A.derive([
            e("方大同", "Oasis", netease: ne), e("方大同", "那沙漠里的水", netease: ne),
            e("方大同", "Oasis", qq: "https://y.qq.com/n/ryqq/songDetail/AAA"), e("方大同", "绿洲", qq: "https://y.qq.com/n/ryqq/songDetail/AAA"),
        ]), [:], "本机别名: 同一英文键指向两个不同中文名 → 撤")
        // 「是不是中文名」按主标题判:副题里的一个「版」字 / 一个客串人名不算
        expectEqual(A.isHanTitled("Ten Reasons (Live版)"), false, "本机别名: 副题里的「版」不算中文名")
        expectEqual(A.isHanTitled("All for Joy (feat. 关诗敏)"), false, "本机别名: 客串署名里的汉字不算中文名")
        expectEqual(A.isHanTitled("一口(The Day You Left Me)"), true, "本机别名: 主标题是中文、副题英文 → 中文名")
        expectEqual(A.isHanTitled("刻在我心底的名字 (Your Name Engraved Herein) - 電影<刻在你心底的名字>主題曲"), true,
                    "本机别名: 两层副题剥完主标题是中文 → 中文名")
        expectEqual(A.isHanTitled("Ru Guo Ai"), false, "本机别名: 拼音是英文侧")
        // 实测抓到的两个坑(2026-09-04 用真实缓存预演):
        let qqA = "https://y.qq.com/n/ryqq/songDetail/003CDIpG2rBZbT"
        expectEqual(A.derive([e("方大同", "Ten Reasons", qq: qqA), e("方大同", "Ten Reasons (Live版)", qq: qqA)]), [:],
                    "本机别名: 录音室版与 Live 版落到同一个 QQ mid 不构成别名(歌词源分不清版本)")
        expectEqual(A.derive([e("陶喆", "All for Joy", netease: "https://music.163.com/song?id=26425115"),
                              e("陶喆", "All for Joy (feat. 关诗敏)", netease: "https://music.163.com/song?id=26425115")]), [:],
                    "本机别名: 折叠键本来就相等 → 不产出空转别名")
        expectEqual(A.derive([e("陶喆", "I Like It (Ballad Version)", netease: "https://music.163.com/song?id=150540"),
                              e("陶喆", "What Is Love", netease: "https://music.163.com/song?id=150540"),
                              e("陶喆", "我喜欢(Ballad Version)", netease: "https://music.163.com/song?id=150540")]), [:],
                    "本机别名: 英文侧两个不同歌名落到同一 id → 至少一条配错,整组不采纳")
        // 只认英文 → 中文:同 id 下全是中文写法(繁简)不产出别名——那本来就由折叠键管
        expectEqual(A.derive([e("方大同", "小小虫", netease: ne), e("方大同", "小小蟲", netease: ne)]), [:],
                    "本机别名: 中文↔中文不产出(折叠键已经管了)")
        // 中文侧的繁简两种写法折到同一键 → 仍算唯一,照常产出(实测 Playful ↔ 玩乐/玩樂)
        expectEqual(A.derive([e("方大同", "Playful", netease: ne), e("方大同", "玩乐", netease: ne), e("方大同", "玩樂", netease: ne)]),
                    ["方大同": ["playful": "玩乐"]], "本机别名: 中文侧繁简两写法算一种,取字典序最小的原始写法")
        expectEqual(A.derive([e("方大同", "Oasis", netease: ne), e("方大同", "Oasis (Live)", netease: ne)]), [:],
                    "本机别名: 没有中文侧 → 不产出")
        // 不同歌手名下同一个 id 互不干扰;歌手写法经合唱归首位 + 罗马字折中文后才分桶
        expectEqual(A.derive([e("陶喆", "Oasis", netease: ne), e("方大同", "那沙漠里的水", netease: ne)]), [:],
                    "本机别名: 不同歌手不成组")
        expectEqual(A.derive([e("Khalil Fong & 王力宏", "Oasis", netease: ne), e("方大同", "那沙漠里的水", netease: ne)]),
                    ["方大同": ["oasis": "那沙漠里的水"]], "本机别名: 合唱首位 + 罗马字别名之后同一桶")
    }

    // ---- 歌名别名 E2:时长 + 歌词都对得上(2026-09-04 下午,取代手写表 titleAliasesByArtist 的最后一步) ----
    //
    // 旧静态表那 7 条(Black Hole / Small Insects / Black & White / Write A Song For You / Twenty Three /
    // Love Love Love / Nanyin)的英文条目在本机缓存里**都没有**平台 id(早期解析没落链接),E1 够不着;
    // 它们两侧都有播放器时长(毫秒级吻合)和歌词。把它们当回归样本:去掉手工表之后必须还能推出来。
    do {
        typealias A = EnrichTitleAliases
        // 同一份歌词的两种来源形态:一份简体 LRC 带署名行,一份繁体、行切分不同、带逐字标签
        let lrcHans = """
        [ti:黑洞里]
        [ar:方大同]
        [00:00.50]作词 : 方大同
        [00:01.00]作曲 : 方大同
        [00:12.10]我在黑洞里 找不到出口
        [00:18.30]你说的话 像光一样穿过
        [00:24.00]黑洞里没有时间 只有你的声音
        [00:31.20]我一直往前走 走不到尽头
        [00:38.00]黑洞里没有时间 只有你的声音
        """
        let lrcHant = """
        [00:12.10]<0,300>我<300,300>在<600,300>黑洞裡
        [00:14.00]找不到出口
        [00:18.30]你說的話 像光一樣穿過
        [00:24.00]黑洞裡沒有時間
        [00:26.00]只有你的聲音
        [00:31.20]我一直往前走 走不到盡頭
        [00:38.00]黑洞裡沒有時間 只有你的聲音
        """
        let other = """
        [00:10.00]今天天气很好 我们去公园散步
        [00:15.00]阳光洒在草地上 微风吹过树梢
        [00:20.00]你笑着说这就是幸福 简单而美好
        [00:25.00]我们手牵着手 走过每一个路口
        """
        expectEqual(A.lyricsBody(lrcHans).hasPrefix("我在黑洞里找不到出口"), true, "E2: 正文剥掉头标签/时间戳/署名行")
        expectEqual(A.lyricsSimilarity(A.lyricsBody(lrcHans), A.lyricsBody(lrcHant)) >= A.lyricsSimilarityMin, true,
                    "E2: 繁简 + 行切分不同 + 逐字标签 → 相似度仍过线")
        expectEqual(A.lyricsSimilarity(A.lyricsBody(lrcHans), A.lyricsBody(other)) < 0.2, true,
                    "E2: 两首不同的歌相似度很低")

        func e(_ artist: String, _ title: String, dur: Double?, resolved: Double? = nil, lyrics: String?) -> A.Entry {
            .init(artist: artist, title: title, neteaseURL: nil, qqMusicURL: nil, durationSecs: dur,
                  resolvedDurationSecs: resolved, lyrics: lyrics)
        }
        // 本案形态:Black Hole 213.586666 / 黑洞里 213.586,两边歌词是同一首(一简一繁)
        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586666, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.586, lyrics: lrcHant),
                              e("方大同", "黑洞裡", dur: 213.586, lyrics: lrcHant)]),
                    ["方大同": ["blackhole": "黑洞裡"]], "E2: 时长毫秒级吻合 + 歌词同一首 → 推出(繁简两条中文写法算一种,原始写法取字典序最小的「裡」)")
        // 歌手写法不同时要靠歌手别名表分到同一桶:表为空就分不到一起,推不出来(这是对的——没有证据说
        // Khalil Fong 就是方大同);灌了表就能推
        expectEqual(A.derive([e("Khalil Fong", "Black Hole", dur: 213.586666, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.586, lyrics: lrcHant)]), [:],
                    "E2: 歌手别名表为空时 Khalil Fong 与 方大同 不在一桶,不推")
        expectEqual(A.derive([e("Khalil Fong", "Black Hole", dur: 213.586666, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.586, lyrics: lrcHant)],
                             artistKey: { LocalArtistAliases.canonicalArtistKey($0, table: ["khalilfong": "方大同"]) }),
                    ["方大同": ["blackhole": "黑洞里"]], "E2: 传入刚推出的歌手表 → 同桶,推出")
        // 整秒精度的一侧:224 vs 224.499 仍在 0.6 s 容差内(Twenty Three ↔ 才二十三 实测)
        expectEqual(A.derive([e("方大同", "Twenty Three", dur: 224, lyrics: lrcHans),
                              e("方大同", "才二十三", dur: 224.498992919922, lyrics: lrcHant)]),
                    ["方大同": ["twentythree": "才二十三"]], "E2: 一侧整秒精度,差 0.5 s 仍采纳")
        // 三个条件缺一不可
        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 215, lyrics: lrcHant)]), [:],
                    "E2: 时长差 1.4 s → 不采纳(歌词再像也不行)")
        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, lyrics: lrcHans),
                              e("方大同", "公园", dur: 213.586, lyrics: other)]), [:],
                    "E2: 时长相等但歌词是两首歌 → 不采纳")
        expectEqual(A.derive([e("方大同", "Black Hole", dur: nil, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.586, lyrics: lrcHant)]), [:],
                    "E2: 一侧没有时长 → 不采纳(E2 必须两侧都有)")
        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, lyrics: nil),
                              e("方大同", "黑洞里", dur: 213.586, lyrics: lrcHant)]), [:],
                    "E2: 一侧没有歌词 → 不采纳")
        // 歌词可信闸:Weather Report 61 s 过场曲配上了 271 s 那首的词 → 这条的歌词不可信,不参与
        expectEqual(A.derive([e("方大同", "Weather Report", dur: 61.08, resolved: 271.5, lyrics: lrcHans),
                              e("方大同", "天气先生", dur: 61.08, lyrics: lrcHant)]), [:],
                    "E2: 播放器时长与所配歌词时长差 210 s → 歌词不可信,不采纳")
        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, resolved: 214, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.586, resolved: 213, lyrics: lrcHant)]),
                    ["方大同": ["blackhole": "黑洞里"]], "E2: 所配歌词时长接近 → 可信,照常采纳")
        // 中文候选带版本尾缀的不要:别把英文录音室版并进中文 Live 版
        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, lyrics: lrcHans),
                              e("方大同", "黑洞里 (Live)", dur: 213.586, lyrics: lrcHant)]), [:],
                    "E2: 中文候选带 (Live) 尾缀 → 不采纳")
        // 精度分档:两侧都是毫秒级小数时差 0.3 s 就不算接近(配错词的两首歌时长天然接近,实测差 1 s 那档是错配高发区)
        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.9, lyrics: lrcHant)]), [:],
                    "E2: 两侧都是毫秒级、差 0.3 s → 不采纳(同一份录音差不到 0.01 s)")
        // 同脚本只连"等长且恰好一个字不同":你/妳 这种字形差异成一类,英文名 + 两个中文写法三种写法并到一起;
        // 代表 = 含汉字 → 本机条目多 → 字典序
        expectEqual(A.derive([e("方大同", "Write A Song For You", dur: 197.273696, lyrics: lrcHans),
                              e("方大同", "为你写的歌", dur: 197.273, lyrics: lrcHant),
                              e("方大同", "为妳写的歌", dur: 197.274002, lyrics: lrcHant),
                              e("方大同", "为妳写的歌", dur: 197.274002, lyrics: lrcHant)]),
                    ["方大同": ["writeasongforyou": "为妳写的歌", "为你写的歌": "为妳写的歌"]],
                    "E2: 英文名 + 你/妳 两种中文写法成一类,代表取条目最多的中文写法")
        expectEqual(A.derive([e("方大同", "阿拉斯加海湾", dur: 200.5, lyrics: lrcHans),
                              e("方大同", "阿拉斯加海湾伴奏", dur: 200.5, lyrics: lrcHans)]), [:],
                    "E2: 同脚本、不是单字差异(多出「伴奏」)→ 不连,哪怕时长歌词全一样")
        // 英文歌词的相似度必须按词切:两首不同的英文歌字母二元组大面积重合,词元三元组几乎不重合
        let eng1 = """
        [00:10.00]It's close to midnight and something evil's lurking in the dark
        [00:15.00]Under the moonlight you see a sight that almost stops your heart
        [00:20.00]You try to scream but terror takes the sound before you make it
        [00:25.00]You start to freeze as horror looks you right between the eyes
        """
        let eng2 = """
        [00:10.00]Tell me will you keep the faith when the night is long and the road is rough
        [00:15.00]Hold on to the dream and never let it go although the world may say enough
        [00:20.00]Keep the faith and you will find the light that leads you home again
        [00:25.00]Every step you take is one step closer to the day you win
        """
        expectEqual(A.lyricsSimilarity(A.lyricsBody(eng1), A.lyricsBody(eng2)) < 0.1, true,
                    "E2: 两首不同的英文歌按词元三元组比 → 几乎不重合")
        expectEqual(A.derive([e("Michael Jackson", "Thriller", dur: 357.75, lyrics: eng1),
                              e("Michael Jackson", "驚悚", dur: 357.75, lyrics: eng2)]), [:],
                    "E2: 时长相同但歌词是两首歌 → 不采纳(实测 Keep the Faith / Thriller 都是 5:57)")
    }

    // ---- 歌手写法归并的通用推断(LocalArtistAliases,2026-09-04,取代手写表 romanizedArtistAliases) ----
    do {
        typealias LA = LocalArtistAliases
        typealias A = EnrichTitleAliases
        func e(_ artist: String, _ title: String, netease: String) -> A.Entry {
            .init(artist: artist, title: title, neteaseURL: "https://music.163.com/song?id=" + netease, qqMusicURL: nil, durationSecs: nil)
        }
        // MusicBrainz 三份缓存各给一条,方向不限:alias-cache 原始→中文;identity zh;primary 中文→[英文别名]
        let mb = LA.MusicBrainzCaches(
            aliasCache: ["Crowd Lu": "卢广仲"],
            identityZh: ["Soft Lipa": "蛋堡"],
            primaryAliases: ["周杰伦": ["Jay Chou", "Zhou Jie Lun"], "Will Pan": ["潘瑋柏", "Wilber Pan"]])
        let t = LA.derive(caches: mb, entries: [])
        expectEqual(t["crowdlu"], "卢广仲", "歌手别名: alias-cache 原始标签 → 中文")
        expectEqual(t["softlipa"], "蛋堡", "歌手别名: identity 缓存的 zh")
        expectEqual(t["jaychou"], "周杰伦", "歌手别名: primary 缓存(中文键 → 英文别名)反向也能推")
        expectEqual(t["zhoujielun"], "周杰伦", "歌手别名: 同一块里的每个别名都指向代表")
        expectEqual(t["willpan"], "潘瑋柏", "歌手别名: primary 缓存(英文键 → 中文别名)代表选含汉字那个")
        expectEqual(t["wilberpan"], "潘瑋柏", "歌手别名: 英文键的其它英文别名也指向中文代表")
        expectEqual(t["卢广仲"], nil, "歌手别名: 代表自己不入表")
        expectEqual(t["michaeljackson"], nil, "歌手别名: 没有证据的歌手不入表")

        // 共享歌曲 id:≥ 2 个不同 id 才算;单个不算(方大同 ↔ 王诗安 那种合唱撞一首)
        let two = LA.derive(caches: .init(), entries: [
            e("David Tao", "Regular friends", netease: "150623"), e("陶喆", "普通朋友", netease: "150623"),
            e("David Tao", "Let's Fall in Love", netease: "150560"), e("陶喆", "讨厌红楼梦", netease: "150560"),
            e("方大同", "特别的人", netease: "9001"), e("王诗安", "特别的人 (合唱)", netease: "9001"),
        ])
        expectEqual(two["davidtao"], "陶喆", "歌手别名: 两种写法共享 2 个 id → 同一人,代表取含汉字的")
        expectEqual(two["王诗安"], nil, "歌手别名: 只共享 1 个 id 不算")
        expectEqual(two["方大同"], nil, "歌手别名: 只共享 1 个 id 不算(另一侧)")
        // 代表的选择:都含汉字时取本机曲目数最多的写法;繁简同键不需要别名
        let rep = LA.derive(caches: .init(aliasCache: ["Crowd Lu": "卢广仲"]), entries: [
            e("盧廣仲", "a", netease: "1"), e("盧廣仲", "b", netease: "2"), e("盧廣仲", "c", netease: "3"),
            e("卢广仲", "d", netease: "4"), e("Crowd Lu", "e", netease: "5"),
        ])
        expectEqual(rep["crowdlu"], "盧廣仲", "歌手别名: 代表取本机曲目最多的汉字写法(繁体 3 首 > 简体 1 首)")
        expectEqual(rep["卢广仲"], nil, "歌手别名: 繁简本来就同一个键,不需要别名")
        // MusicBrainz 缓存里的合唱串 / 带逗号的乐队名不当边的端点:归首位会切出碎片(`Earth, Wind & Fire`
        // → `Earth`),拿碎片连边就是乱连(实测推出 earth → アース)
        let duet = LA.derive(caches: .init(aliasCache: ["Khalil Fong & Fiona Sit": "方大同",
                                                       "Earth, Wind & Fire": "アース、ウインド&ファイアー"]), entries: [])
        expectEqual(duet["khalilfong"], nil, "歌手别名: 缓存里的合唱串不当边(首位歌手另有 primary/共现证据)")
        expectEqual(duet["earth"], nil, "歌手别名: 带逗号的乐队名不当边,不产出 earth 这种碎片映射")
        // 短别名不用
        let short = LA.derive(caches: .init(primaryAliases: ["周杰伦": ["K", "Jay"]]), entries: [])
        expectEqual(short["k"], nil, "歌手别名: 1 字符别名不用")
        expectEqual(short["jay"], "周杰伦", "歌手别名: 3 字符别名(去空格后)刚够,整串匹配")
        // canonicalArtistKey(table:) 跟 PlayCountFold 那把尺子一致
        PlayCountFold.setLocalArtistAliases(two)
        expectEqual(LA.canonicalArtistKey("David Tao & 蔡健雅", table: two), PlayCountFold.canonicalArtistKey("David Tao & 蔡健雅"),
                    "歌手别名: 传表版与全局版的 canonicalArtistKey 一致")
        PlayCountFold.setLocalArtistAliases([:])
    }
}
