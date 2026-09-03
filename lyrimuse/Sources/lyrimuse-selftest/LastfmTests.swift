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
        // ⑧ 罗马字歌手名折到中文本名(只作用在查族用的 familyKey 上)
        expectEqual(F.familyKey(artist: "David Tao", title: "找自己"),
                    F.familyKey(artist: "陶喆", title: "找自己"),
                    "查族键: David Tao 与 陶喆 同族")
        expectEqual(F.familyKey(artist: "Jay Chou", title: "不該"),
                    F.familyKey(artist: "周杰倫", title: "不该"),
                    "查族键: Jay Chou 与 周杰倫 同族(叠繁简)")
        expectEqual(F.familyKey(artist: "Hikaru Utada", title: "Automatic"),
                    F.familyKey(artist: "宇多田光", title: "Automatic"),
                    "查族键: 罗马字与汉字写法同族")
        expectEqual(F.familyKey(artist: "宇多田ヒカル", title: "Automatic"),
                    F.familyKey(artist: "宇多田光", title: "Automatic"),
                    "查族键: 片假名与汉字写法同族")
        // 别名匹配必须是**整串相等** —— 索引里真有 Count Basie,子串匹配会被 asi 命中
        expectNotEqual(F.familyKey(artist: "Count Basie", title: "X"),
                       F.familyKey(artist: "阿肆", title: "X"),
                       "查族键: 别名整串相等,Count Basie 不许被 asi 命中")
        expectNotEqual(F.familyKey(artist: "Fantasia", title: "X"),
                       F.familyKey(artist: "阿肆", title: "X"),
                       "查族键: Fantasia 也不许被 asi 命中(索引里真有这个艺人)")
        // 刻意剔掉的两条别名:Last.fm 侧是「同名多人」或混杂实体,理由见 romanizedArtistAliases
        expectNotEqual(F.familyKey(artist: "Jason Chan", title: "你瞒我瞒"),
                       F.familyKey(artist: "陳柏宇", title: "你瞒我瞒"),
                       "查族键: jasonchan 刻意不入表(Last.fm 标注同名多人)")
        expectNotEqual(F.familyKey(artist: "Kun", title: "Jasmine"),
                       F.familyKey(artist: "蔡徐坤", title: "Jasmine"),
                       "查族键: kun 刻意不入表(3 字符键 + 实体混杂)")
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
        // 端到端:别名 + ArtistCredit 左词边界两个修法都到位,蛋堡才合得上
        expectEqual(F.familyKey(artist: "Soft Lipa", title: "偷偷"),
                    F.familyKey(artist: "蛋堡", title: "偷偷"),
                    "查族键: Soft Lipa 与 蛋堡 同族(要 ArtistCredit 边界守卫先修好)")

        // ⑨ 歌名维度的罗马字/译名别名(titleAliasesByArtist,2026-08-29):
        // "Love Love Love" 其实就是方大同《爱爱爱》,之前简繁能合并、这种译名合不了。
        expectEqual(F.familyKey(artist: "方大同", title: "Love Love Love"),
                    F.familyKey(artist: "方大同", title: "爱爱爱"),
                    "查族键: 方大同《Love Love Love》与《爱爱爱》同族")
        expectEqual(F.familyKey(artist: "Khalil Fong", title: "Love Love Love"),
                    F.familyKey(artist: "方大同", title: "愛愛愛"),
                    "查族键: 罗马字歌手名 + 译名歌名,两层别名叠加也要同族")
        // ⚠️ 核心安全约束:这张表必须按(歌手,歌名)登记,不能是全局 title->title——
        // 王力宏名下真实存在一首同样叫《Love Love Love》的歌,跟方大同《爱爱爱》毫不相干,
        // 不能被这张表牵连着一起合并。
        expectNotEqual(F.familyKey(artist: "王力宏", title: "Love Love Love"),
                       F.familyKey(artist: "方大同", title: "爱爱爱"),
                       "查族键: 王力宏《Love Love Love》不该被牵连进方大同《爱爱爱》")
        expectEqual(F.familyKey(artist: "王力宏", title: "Love Love Love"),
                    F.key(artist: "王力宏", title: "Love Love Love"),
                    "查族键: 王力宏这首歌不在别名表覆盖范围内,应与 key 一致(未被改写)")
        // 别的歌手唱的《爱爱爱》(如果存在)不该被这张表反向牵连——表只认「方大同」这个
        // 歌手键下的这一条歌名,不是全局的「爱爱爱」身份。
        expectEqual(F.familyKey(artist: "某歌手", title: "爱爱爱"),
                    F.key(artist: "某歌手", title: "爱爱爱"),
                    "查族键: 不在表里的歌手名下同名歌曲不受影响")

        // "nanyin" 其实就是《南音》——跟"Love Love Love"同一批加的第二条映射,起因是这首歌
        // 在另一个独立系统(match.go 的 isProbablyWrongLanguageLyrics,歌词候选打分)里已经
        // 核实过确实是同一首歌,而本地写法索引证实 方大同|nanyin 与 方大同|南音 是两个真实
        // 独立记账的桶。
        expectEqual(F.familyKey(artist: "方大同", title: "nanyin"),
                    F.familyKey(artist: "方大同", title: "南音"),
                    "查族键: 方大同《nanyin》与《南音》同族")
        // 用中文本名"南音"作为输入时,查表(内层键是 foldTitle 折出来的"nanyin")查不到,
        // 不会被二次替换或改写——familyKey 应该跟 key 一致,行为不受影响。
        expectEqual(F.familyKey(artist: "方大同", title: "南音"),
                    F.key(artist: "方大同", title: "南音"),
                    "查族键: 用中文本名查询时不会被错误地二次改写")

        // "Black Hole" 其实就是《黑洞里》——2026-08-29 用户指出,上一版"批量核实近 60 首
        // 纯英文曲目、查网易云/QQ/酷狗/LRCLIB 官方标题都是英文"的核实方法被证明是错的方向:
        // 那几个平台的官方标题跟用户自己 Last.fm 历史里真实出现过的写法是两件不相关的事。
        // 直接查 Last.fm track.getInfo 坐实:黑洞里(简体)+黑洞裡(繁体,已经靠简繁折叠自动
        // 合并)约 40 次,Black Hole 独立 1 次,从没被合并过。
        expectEqual(F.familyKey(artist: "方大同", title: "Black Hole"),
                    F.familyKey(artist: "方大同", title: "黑洞里"),
                    "查族键: 方大同《Black Hole》与《黑洞里》同族")
        expectEqual(F.familyKey(artist: "Khalil Fong", title: "Black Hole"),
                    F.familyKey(artist: "方大同", title: "黑洞裡"),
                    "查族键: 罗马字歌手名 + 英文歌名,叠加繁体写法也要同族")

        // 后续四条(2026-08-29 同一批,三步核实法:专辑曲目单定位候选 + Last.fm 真实次数
        // 交叉验证 + 时长比对排除假阳性——见 titleAliasesByArtist 声明处注释)。
        expectEqual(F.familyKey(artist: "方大同", title: "Small Insects"),
                    F.familyKey(artist: "方大同", title: "小小蟲"),
                    "查族键: 方大同《Small Insects》与《小小蟲》同族")
        expectEqual(F.familyKey(artist: "方大同", title: "Black & White"),
                    F.familyKey(artist: "方大同", title: "黑白"),
                    "查族键: 方大同《Black & White》与《黑白》同族")
        expectEqual(F.familyKey(artist: "方大同", title: "Write A Song For You"),
                    F.familyKey(artist: "方大同", title: "為妳寫的歌"),
                    "查族键: 方大同《Write A Song For You》与《為妳寫的歌》同族")
        expectEqual(F.familyKey(artist: "方大同", title: "Twenty Three"),
                    F.familyKey(artist: "方大同", title: "才二十三"),
                    "查族键: 方大同《Twenty Three》与《才二十三》同族")
        // 反面案例:同一批核实里差点被误判的 Weather Report / 天氣先生——次数都不小、专辑
        // 序号紧邻,但时长完全不同(61s 过场 vs 271s 完整歌曲),是两首不同的歌,不该合并。
        // 这两个字符串本来就没有登记进表,这条断言钉住"不会被想当然地合并"。
        expectEqual(F.familyKey(artist: "方大同", title: "Weather Report"),
                    F.key(artist: "方大同", title: "Weather Report"),
                    "查族键: Weather Report 不该被误合并进天氣先生(时长证伪的反例)")

        // 表外的歌名/歌手组合不受影响。⚠️ 这条只能证明"某一首没被登记的歌不受影响",
        // **不能**倒推成"别的没登记的英文曲目就一定没有中文对应"——Black Hole 那次的教训
        // 正是想当然地把"查过几个平台标题"当成了"查过用户真实数据",详见上面两条注释。
        expectEqual(F.familyKey(artist: "方大同", title: "Moon River"),
                    F.key(artist: "方大同", title: "Moon River"),
                    "查族键: 方大同没登记别名的其它歌(如翻唱曲目)不受影响")
    }

    // ---- 写法别名自动发现:动态表注入(setDiscoveredTitleAliases,2026-08-29) ----
    // titleAliasesByArtist 是编译进二进制的静态表,发现表是运行时可增长的第二张 ——
    // 这里只测"注入机制本身"(优先级、per-artist 隔离、不污染静态表覆盖范围),扫描算法
    // 本身(discoverTitleAliasesIfNeeded)在 App 侧,牵涉网络/文件 I/O,不在 selftest 覆盖。
    do {
        typealias F = PlayCountFold
        // 全局可变状态,用完必须清空——否则会污染其它 do 块里"这首歌不受影响"的断言
        // (那些断言隐含假设发现表是空的)。
        defer { F.setDiscoveredTitleAliases([:]) }

        F.setDiscoveredTitleAliases(["测试歌手": ["testsong": "测试歌曲"]])
        expectEqual(F.familyKey(artist: "测试歌手", title: "TestSong"),
                    F.familyKey(artist: "测试歌手", title: "测试歌曲"),
                    "发现表: 注入的映射能让 familyKey 同族")
        // per-artist 隔离:同样的歌名折叠键,换一个不在表里的歌手就不受影响。
        expectEqual(F.familyKey(artist: "别的歌手", title: "TestSong"),
                    F.key(artist: "别的歌手", title: "TestSong"),
                    "发现表: 只在登记的歌手键下生效,不会牵连同名歌名的其它歌手")
        // 静态表优先:方大同「lovelovelove→爱爱爱」已经在静态表里登记,即便发现表对同一个
        // 歌手键+同一个折叠键给出不同的值,查询结果也应该采信静态表(人工核定 > 算法发现)。
        F.setDiscoveredTitleAliases(["方大同": ["lovelovelove": "某个错误的歌名"]])
        expectEqual(F.familyKey(artist: "方大同", title: "Love Love Love"),
                    F.familyKey(artist: "方大同", title: "爱爱爱"),
                    "发现表: 与静态表撞键时静态表优先,不被发现表覆盖")
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
}
