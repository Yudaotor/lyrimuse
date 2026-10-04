import LyrimuseCore
import Foundation

// Last.fm:第 N 次听 / 写法族 / 分页 / 计次规则 / 最近记录 feed。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runLastfmTests() {
    // ---- 授权成功后桥接用户名(lastfm_user)跟不跟着换 ----
    do {
        let adopt = LastfmBridgeUser.shouldAdoptAuthorized
        expectEqual(adopt("", ""), true, "桥接用户名: 没填过 → 用授权账号")
        expectEqual(adopt("", "old"), true, "桥接用户名: 没填过(之前授权过)→ 用授权账号")
        expectEqual(adopt("Old", "old"), true, "桥接用户名: 就是上次授权的账号(大小写不计)→ 换成新账号")
        expectEqual(adopt("manual", "old"), false, "桥接用户名: 填的是别的账号 → 保留")
        expectEqual(adopt("manual", ""), false, "桥接用户名: 之前没授权过、手填过 → 保留")
    }

    // ---- 「第 N 次听」的作废判据:按最新一条收听的时刻,而不是页内出现次数 ----
    //
    // 页内出现次数在连播同一首歌时会饱和 —— 新的挤进来、旧的挤出去,页内次数**不再增长**,
    // 不能拿来判断要不要作废旧计次。完整推导见 PlayCountRecency 的注释。
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

    // ---- 「第 N 次听」判据③:页内自相矛盾 ----
    //
    // 判据①②都要跟上一轮比,而基线只在内存、次数表却持久化 —— App 重启后基线被重设成
    // 「当下」,那首歌不再被播一次就永远等不到作废。实测:缓存冻在 3、真实 12,那一页有
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

    // ---- 「第 N 次听」判据④:距离上次验证太久,不看页内次数 ----
    //
    // 根因是判据③的第一道闸 `onPage > cachedTotal`,只能抓"缓存明显偏小"的情况
    // (比如缓存冻结在 1、服务端真实是 31 这种量级差):这首歌很久没被主动播放,这次
    // 只是又听了一次重新出现在页面上,onPage=1 恰好没有超过冻住的旧值 1,③直接判
    // "没问题"、压根不会走到"上次验证是多久以前"这一步。这条判据不依赖页内次数,
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
        // 核心场景:即使页内次数(1)没有超过缓存总数(旧值 1),只要验证时刻够久,判据④
        // 依然要能独立地判定过期——它完全不看这两个数字,这条断言就是在确认这一点
        // (跟判据③形成对比:同样的 onPage=1/cachedTotal=1,contradicted 会判 false)。
        expectEqual(R.contradicted(onPage: 1, cachedTotal: 1, lastFetched: nil,
                                   now: now, recheckAfter: 300), false,
                    "对比: 判据③在 onPage=1/cachedTotal=1 时判'没问题'(这正是它的盲点)")
        expectEqual(R.stale(lastFetched: at(1_000_000 - 2 * 24 * 60 * 60), now: now, maxAge: maxAge), true,
                    "判据④: 同样的场景,只看时间就能判过期,不受 onPage/cachedTotal 影响")
    }

    // ---- nowPlayingCount 追赶 trackPlayCounts ----
    //
    // 实测(《Controversy》):换歌那一刻 nowPlayingCount 取到 16(显示 17),trackPlayCounts
    // 随后追到 27(显示 28)——nowPlayingCount 没有任何自愈机制,永远停在 17,直到下一次换歌。
    // 这组用例钉住"只能涨、不能跌"的取舍。
    do {
        typealias R = PlayCountRecency
        // 这一组的 currentPlayCounted 全传 false = "这一次还没落库",也就是
        // 之前唯一存在的那条路径,行为必须逐字不变(下面第二组管已落库的情形)。
        // 正题:trackPlayCounts 学到了更高的总数 → 采纳,+1 换算成显示值
        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 27, currentPlayCounted: false), 28,
                    "nowPlayingCount 追赶: 27+1=28,比当前 17 高 → 采纳")
        // 还没显示过(nil,理论上不该发生在这条路径,但当 0 处理不炸)
        expectEqual(R.reconciledNowPlayingCount(current: nil, freshTotal: 5, currentPlayCounted: false), 6,
                    "nowPlayingCount 追赶: current 为 nil 时按 0 比较")
        // 只能涨、不能跌 —— 新数字更低时必须按兵不动,不能让显示的数字倒退
        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 10, currentPlayCounted: false), nil,
                    "nowPlayingCount 追赶: 新总数更低 → 不采纳,返回 nil")
        // 等于当前值:没有新信息,不该触发一次无意义的写入(SwiftUI 不必要的重渲染)
        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 16, currentPlayCounted: false), nil,
                    "nowPlayingCount 追赶: 换算后与当前相等 → 不采纳")
        // 差 1 也要涨 —— 阈值判断用的是 > 不是 >=,别把等于的情况错判成"该涨"
        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 17, currentPlayCounted: false), 18,
                    "nowPlayingCount 追赶: 新总数比换算前的 total 还高一点 → 仍要涨")
    }

    // ---- 当前这次播放已经落库时不再 +1 ----
    //
    // 第一次听的歌**必然**中招:正是这次 scrobble 让它第一次出现在最近记录里,新 key
    // 无条件取数,必定撞在"已入账、还在播"的窗口上,把同一次收听算两遍。
    do {
        typealias R = PlayCountRecency
        // 正题:总数已经含这一次 → 不加那个 1,维持原数字
        expectEqual(R.reconciledNowPlayingCount(current: 1, freshTotal: 1, currentPlayCounted: true), nil,
                    "已落库: 1+0=1 与当前相等 → 不动(改之前这里会抬到 2)")
        // 听过 5 次的老歌正在听第 6 次:换歌时取到 5 显示 6,过门槛后总数变 6 → 仍是 6
        expectEqual(R.reconciledNowPlayingCount(current: 6, freshTotal: 6, currentPlayCounted: true), nil,
                    "已落库: 老歌过门槛后总数追平显示值 → 不动")
        // 收回本次会话里已经多算出来的那一次 —— 否则"只能涨"会把错数字永久焊住
        expectEqual(R.reconciledNowPlayingCount(current: 2, freshTotal: 1, currentPlayCounted: true), 1,
                    "已落库: 显示 2 而权威值是 1 → 收回多算的那一次")
        // 但只收回**恰好一次**:再低的跌幅只可能是 Last.fm 返回了陈旧值,采纳会来回闪
        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 10, currentPlayCounted: true), nil,
                    "已落库: 跌幅超过一次 → 不采纳(陈旧值,实测过 16 vs 27 那种)")
        // 连播同一首:第二遍落库后总数 2 → 直接涨到 2(换歌那一刻的取数被 key 守卫挡住了)
        expectEqual(R.reconciledNowPlayingCount(current: 1, freshTotal: 2, currentPlayCounted: true), 2,
                    "已落库: 连播第二遍 → 照常涨")
        // freshTotal 0 且已落库:算出来是 0,不该显示"第 0 次听"
        expectEqual(R.reconciledNowPlayingCount(current: nil, freshTotal: 0, currentPlayCounted: true), nil,
                    "已落库: 换算成 0 → 不采纳,没有第 0 次听")
    }

    // ---- currentPlayIsScrobbled: 这次播放落库没有 ----
    do {
        typealias R = PlayCountRecency
        func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
        let start = at(1_000_000)
        // Last.fm 的 scrobble 时间戳记的是**开播时刻**,所以两者本该几乎相等
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: start, playStart: start), true,
                    "落库判定: 时刻完全相等 → 就是这一次")
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: at(1_000_003), playStart: start), true,
                    "落库判定: 差几秒(锚点外推/时钟偏差)仍算这一次")
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: at(1_000_119), playStart: start), true,
                    "落库判定: 119 秒仍在 120 秒容差内")
        // 几天前听过同一首歌那条记录,绝不能被当成这一次
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: at(1_000_000 - 3 * 24 * 60 * 60),
                                             playStart: start), false,
                    "落库判定: 几天前的旧记录不算这一次")
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: at(1_000_121), playStart: start), false,
                    "落库判定: 超出容差 → 不算")
        // 两个 nil 都按"不知道"处理 = 退回 +1 的老行为,宁可多算也不凭空少算
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: nil, playStart: start), false,
                    "落库判定: 这首歌还没有任何已落库记录 → 按没入账算")
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: start, playStart: nil), false,
                    "落库判定: 没有播放锚点 → 按没入账算")
    }

    // ---- LastfmHistoryPaging:历史扫描换页大小时页码按条数换算 ----
    do {
        typealias H = LastfmHistoryPaging
        expectEqual(H.pageSize % H.fallbackPageSize, 0, "历史分页: 小页整除大页,换页大小才换算得出同一个起点")
        expectEqual(H.page(1, convertingFrom: 1000, to: 200), 1, "历史分页: 第 1 页失败 → 小页第 1 页")
        expectEqual(H.page(3, convertingFrom: 1000, to: 200), 11, "历史分页: 大页第 3 页从第 2001 条起 = 小页第 11 页")
        expectEqual(H.page(3, convertingFrom: 1000, to: 300), nil, "历史分页: 不整除时不换算")
        expectEqual(H.page(0, convertingFrom: 1000, to: 200), nil, "历史分页: 页码从 1 起")
        expectEqual(H.shouldCheckpoint(afterPage: 2, limit: 1000), true, "历史分页: 大页每 2 页落断点")
        expectEqual(H.shouldCheckpoint(afterPage: 3, limit: 1000), false, "历史分页: 大页单数页不落断点")
        expectEqual(H.shouldCheckpoint(afterPage: 10, limit: 200), true, "历史分页: 小页(旧断点)仍是每 10 页")
        expectEqual(H.shouldCheckpoint(afterPage: 15, limit: 200), false, "历史分页: 小页第 15 页不落断点")
    }

    // ---- LastfmRecentTracksPage:合并历史扫描的分页解析 ----
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

    // ---- Last.fm GET query 的双重编码 ----
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

    // ---- LastfmSignature:授权 / 喜欢用的 api_sig ----
    //
    // 跟引擎 lastfmsign_test.go 是同一组向量:两边各算各的签名,任一处的排序或编码分叉,
    // 对应那一侧就红。签错的表现是 Last.fm 报 error 13(Invalid method signature),连不上账号。
    do {
        typealias S = LastfmSignature
        expectEqual(S.sign(["method": "auth.getsession", "api_key": "KEY", "token": "TOK"], secret: "SECRET"),
                    "7159147741f8ad64a31b34b8a529be00", "lastfm 签名: auth.getsession")
        expectEqual(S.sign(["method": "track.love", "artist": "周杰倫", "track": "晴天", "api_key": "KEY", "sk": "SK"],
                           secret: "SECRET"),
                    "937db1b27d3985a7c3b885731c6f2964", "lastfm 签名: 中文值按 UTF-8 字节拼")
        expectEqual(S.sign(["artist[0]": "A", "artist[10]": "B", "artist[2]": "C", "method": "track.scrobble",
                            "api_key": "KEY", "sk": "SK"], secret: "SECRET"),
                    "5659761ac217b49797f2e0103d7866aa", "lastfm 签名: 键名按字节序,artist[10] 在 artist[2] 前")
        expectEqual(S.sign(["method": "auth.getsession", "api_key": "KEY", "token": "TOK", "format": "json", "callback": "cb"],
                           secret: "SECRET"),
                    "7159147741f8ad64a31b34b8a529be00", "lastfm 签名: format / callback 不进签名,整包传进来也签得对")
    }

    // ---- LastfmImage:图片字段取哪一张、万能占位星当没有 ----
    do {
        typealias I = LastfmImage
        let star = "https://lastfm.freetls.fastly.net/i/u/174s/\(I.placeholderHash).png"
        func img(_ size: String, _ url: String) -> [String: Any] { ["size": size, "#text": url] }
        expectEqual(I.pick([img("small", "s"), img("large", "L"), img("extralarge", "XL")]), "L",
                    "lastfm 图: 有 large 取 large")
        expectEqual(I.pick([img("small", "s"), img("extralarge", "XL")]), "XL", "lastfm 图: 没 large 退 extralarge")
        expectEqual(I.pick([img("small", "s"), img("medium", "M")]), "M", "lastfm 图: 都没有退最后一项")
        expectEqual(I.pick([img("large", star)]), nil, "lastfm 图: 占位星当没有图")
        expectEqual(I.pick([img("large", ""), img("extralarge", "XL")]), "XL",
                    "lastfm 图: large 是空串退 extralarge(跟引擎同规则)")
        expectEqual(I.pick([img("large", ""), img("extralarge", ""), img("mega", "MG")]), "MG",
                    "lastfm 图: 前两档都是空串退最后一项")
        expectEqual(I.pick([img("small", ""), img("large", ""), img("extralarge", "")]), nil,
                    "lastfm 图: 全是空串就是没有图")
        expectEqual(I.pick([] as [[String: Any]]), nil, "lastfm 图: 空数组")
        expectEqual(I.pick("not an array"), nil, "lastfm 图: 形状不对")
        expectEqual(I.pick(nil), nil, "lastfm 图: 缺字段")
        expectEqual(I.usable("https://x/a.png"), "https://x/a.png", "lastfm 图: 现成 URL 原样")
        expectEqual(I.usable(star), nil, "lastfm 图: 现成 URL 是占位星")
        expectEqual(I.usable(""), nil, "lastfm 图: 空串")
        expectEqual(I.usable(nil), nil, "lastfm 图: nil")
    }

    // ---- LastfmRecentRows:最近记录逐行解析 + 重复序号 ----
    //
    // dup 是行 id 的一部分:只在「同一时刻 + 同一首歌」之间编号。换成整表行号的话,每来一条新
    // scrobble 后面所有行的 id 全变,列表会被当成整张替换、滚动位置被顶回去。
    do {
        typealias R = LastfmRecentRows
        func track(_ title: String, _ artist: String, uts: String?, album: String? = nil,
                   image: String? = nil) -> [String: Any] {
            var t: [String: Any] = ["name": title, "artist": ["#text": artist]]
            if let uts { t["date"] = ["uts": uts] }
            if let album { t["album"] = ["#text": album] }
            if let image { t["image"] = [["size": "large", "#text": image]] }
            return t
        }
        let star = "https://x/\(LastfmImage.placeholderHash).png"
        let json: [String: Any] = ["recenttracks": ["track": [
            track("Now", "A", uts: nil),
            track("Song", "A", uts: "1700000100", album: "Al", image: "https://x/a.png"),
            track("Song", "A", uts: "1700000100"),
            track("Song", "A", uts: "1700000000", image: star),
            track("", "A", uts: "1699999999"),
        ]]]
        let rows = R.parse(json)
        expectEqual(rows.count, 4, "最近记录: 没有曲名的行跳过")
        expectEqual(rows.first?.uts, nil, "最近记录: 正在播放那行没有时间")
        expectEqual(rows.map(\.dup), [0, 0, 1, 0], "最近记录: 同一时刻同一首歌才递增序号")
        expectEqual(rows[1], R.Row(dup: 0, title: "Song", artist: "A", album: "Al", image: "https://x/a.png",
                                   uts: 1_700_000_100), "最近记录: 字段齐全")
        expectEqual(rows[3].image, nil, "最近记录: 占位星当没有图")
        // 新 scrobble 插在最前面,已有行的 dup 不变(id 稳定)
        var grown = json
        grown["recenttracks"] = ["track": [track("Song", "A", uts: "1700000200")]
            + ((json["recenttracks"] as? [String: Any])?["track"] as? [[String: Any]] ?? [])]
        expectEqual(R.parse(grown).dropFirst().map(\.dup), rows.map(\.dup), "最近记录: 头部新增一条,旧行序号不变")
        // 只有一条时 Last.fm 给的是对象不是数组(同 LastfmRecentTracksPage):照样解出这一条。
        expectEqual(R.parse(["recenttracks": ["track": ["name": "Solo"]]]).map(\.title), ["Solo"],
                    "最近记录: track 是单个对象时解出这一条")
        expectEqual(R.parse(["recenttracks": ["track": "garbage"]]).isEmpty, true,
                    "最近记录: track 既不是数组也不是对象时返回空")
        expectEqual(R.parse([:]).isEmpty, true, "最近记录: 缺字段")
    }

    // ---- LastfmRequestGate:App 侧 Last.fm 限速队列的放行顺序与冷却 ----
    do {
        typealias G = LastfmRequestGate
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var g = G()
        g.enqueue(1, .background, now: t0)
        g.enqueue(2, .background, now: t0)
        g.enqueue(3, .interactive, now: t0)
        g.enqueue(4, .interactive, now: t0)
        var order: [Int] = []
        while let id = g.popNext() { order.append(id) }
        expectEqual(order, [3, 4, 1, 2], "限速队列: 前台先走,同一优先级按排队顺序")
        expectEqual(g.isEmpty, true, "限速队列: 放完即空")
        expectEqual(g.popNext(), nil, "限速队列: 空队列取不到")

        var c = G()
        expectEqual(c.waitBeforeRelease(now: t0), 0, "限速队列: 没有冷却不用等")
        c.extendCooldown(until: t0.addingTimeInterval(60))
        c.extendCooldown(until: t0.addingTimeInterval(10))
        expectEqual(c.waitBeforeRelease(now: t0), 60, "限速队列: 冷却只往后推,较早的不覆盖较晚的")
        c.adoptSharedCooldown(t0.addingTimeInterval(90))
        expectEqual(c.waitBeforeRelease(now: t0), 90, "限速队列: 共享窗口更晚就并入")
        c.adoptSharedCooldown(nil)
        expectEqual(c.waitBeforeRelease(now: t0), 90, "限速队列: 共享窗口没有期限时不动")
        expectEqual(c.waitBeforeRelease(now: t0.addingTimeInterval(100)), 0, "限速队列: 过了冷却期不用等")

        var idle = G()
        expectEqual(idle.interactiveIdle(for: 30, now: t0), true, "限速队列: 从没有前台请求算安静")
        idle.enqueue(1, .background, now: t0)
        expectEqual(idle.interactiveIdle(for: 30, now: t0), true, "限速队列: 后台排队不打断安静")
        idle.enqueue(2, .interactive, now: t0)
        expectEqual(idle.interactiveIdle(for: 30, now: t0.addingTimeInterval(29)), false, "限速队列: 前台 30 秒内排过队")
        expectEqual(idle.interactiveIdle(for: 30, now: t0.addingTimeInterval(30)), true, "限速队列: 满 30 秒才算安静")

        // 传输失败退避:连续 3 次才开始冷却;冷却期内再失败不跳级;过了冷却再失败升一级;拿到响应清零。
        var net = G()
        expectEqual(net.noteTransportFailure(now: t0), nil, "传输退避: 第 1 次失败不冷却")
        expectEqual(net.noteTransportFailure(now: t0), nil, "传输退避: 第 2 次失败不冷却")
        expectEqual(net.noteTransportFailure(now: t0), 15, "传输退避: 连续第 3 次失败冷却 15 秒")
        expectEqual(net.waitBeforeRelease(now: t0), 15, "传输退避: 整条队列一起等")
        expectEqual(net.noteTransportFailure(now: t0.addingTimeInterval(5)), nil,
                    "传输退避: 同一批在途请求在冷却期内接着失败,不跳级")
        expectEqual(net.noteTransportFailure(now: t0.addingTimeInterval(16)), 30, "传输退避: 冷却过后试探还是失败,升到 30 秒")
        for step in 0..<10 { _ = net.noteTransportFailure(now: t0.addingTimeInterval(1_000 + Double(step) * 1_000)) }
        expectEqual(net.noteTransportFailure(now: t0.addingTimeInterval(20_000)), 300, "传输退避: 封顶 5 分钟")
        net.noteResponse()
        expectEqual(net.noteTransportFailure(now: t0.addingTimeInterval(30_000)), nil, "传输退避: 拿到响应后计数清零,重新数 3 次")
        expectEqual(G.isTransportFailure(URLError(.timedOut)), true, "传输退避: 超时算链路失败")
        expectEqual(G.isTransportFailure(URLError(.cancelled)), false, "传输退避: 取消不算")
    }

    // ---- AuditSummaryWindow:高频请求的审计按分钟汇总 ----
    do {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        var w = AuditSummaryWindow(start: t0)
        expectEqual(w.add(durationMs: 3, now: t0), nil, "审计汇总: 窗口内不出行")
        expectEqual(w.add(durationMs: 9, now: t0.addingTimeInterval(20)), nil, "审计汇总: 不满 60 秒不出行")
        expectEqual(w.add(durationMs: 120, now: t0.addingTimeInterval(59)), nil, "审计汇总: 59 秒仍在窗口里")
        expectEqual(w.add(durationMs: 5, now: t0.addingTimeInterval(61)), "count=3 p50_ms=9 max_ms=120 span_s=61",
                    "审计汇总: 满 60 秒的下一次调用结算旧窗口")
        expectEqual(w.durations, [5], "审计汇总: 这一次记进新窗口")
        var idleWindow = AuditSummaryWindow(start: t0)
        expectEqual(idleWindow.add(durationMs: 4, now: t0.addingTimeInterval(500)), nil,
                    "审计汇总: 空窗口隔了很久才来第一次,从这一次开新窗口,不出空汇总")
    }

    // ---- ChartComparison / ChartMovement:「听得最多」榜单跟上一期比的名次升降 ----
    //
    // 上一期是紧挨着本期之前、同样长的窗口;三个长度跟引擎 topArtistsPeriodSpan 同一组。
    do {
        typealias C = ChartComparison
        typealias M = ChartMovement
        expectEqual(C.span(forPeriod: "7day"), 7 * 86_400, "榜单升降: 近 7 天")
        expectEqual(C.span(forPeriod: "1month"), 30 * 86_400, "榜单升降: 近 30 天(跟 Last.fm 1month 滚动榜同口径)")
        expectEqual(C.span(forPeriod: "12month"), 365 * 86_400, "榜单升降: 近一年")
        expectEqual(C.span(forPeriod: "overall"), nil, "榜单升降: 全部没有上一期")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let w = C.previousWindow(span: 7 * 86_400, now: now)
        expectEqual(w.to, now.addingTimeInterval(-7 * 86_400), "榜单升降: 上一期结束于本期开始")
        expectEqual(w.from, now.addingTimeInterval(-14 * 86_400), "榜单升降: 上一期同样长")

        let cur = [C.key(artist: "Prince", name: "Bambi"), C.key(artist: "prince", name: "3121"),
                   C.key(artist: "A", name: "New Song")]
        let prev = [C.key(artist: "PRINCE", name: "3121"), C.key(artist: "X", name: "Y"), C.key(artist: "Prince", name: "BAMBI"),
                    C.key(artist: "Prince", name: "Bambi")]
        expectEqual(C.previousRanks(current: cur, previous: prev), [3, 1, 0],
                    "榜单升降: 按歌手+名称对齐,大小写不算差异,重复取靠前,上一期没有为 0")
        expectEqual(C.key(artist: "A", name: "B") == C.key(artist: "AB", name: ""), false,
                    "榜单升降: 歌手和名称之间有分隔,拼接不会撞键")

        let albums: [String: Any] = ["weeklyalbumchart": ["album": [
            ["name": "Xscape", "playcount": "12", "artist": ["#text": "Michael Jackson"]],
            ["name": "", "playcount": "3", "artist": ["#text": "Nobody"]],
            ["name": "15", "playcount": "5", "artist": ["#text": "方大同"]],
        ]]]
        let parsed = C.parseWeeklyChart(albums, container: "weeklyalbumchart", item: "album")
        expectEqual(parsed?.keys, [C.key(artist: "Michael Jackson", name: "Xscape"), C.key(artist: "方大同", name: "15")],
                    "榜单升降: 周榜按名次取对齐键,没有名称的行跳过")
        expectEqual(parsed?.listens, 17, "榜单升降: 合计次数(判上一期有没有收听)")
        let single: [String: Any] = ["weeklyartistchart": ["artist": ["name": "Alpha", "playcount": "4"]]]
        expectEqual(C.parseWeeklyChart(single, container: "weeklyartistchart", item: "artist")?.keys,
                    [C.key(artist: "", name: "Alpha")], "榜单升降: 只有一条时是对象也认")
        let empty: [String: Any] = ["weeklytrackchart": ["track": [] as [Any]]]
        expectEqual(C.parseWeeklyChart(empty, container: "weeklytrackchart", item: "track")?.listens, 0,
                    "榜单升降: 上一期没有收听 = 合计 0,不是解析失败")
        expectEqual(C.parseWeeklyChart(["error": 6], container: "weeklytrackchart", item: "track") == nil, true,
                    "榜单升降: 形状不对当作取数失败")

        expectEqual(M.of(rank: 3, previousRank: nil), nil, "榜单升降: 没有可比的上一期不显示")
        expectEqual(M.of(rank: 3, previousRank: 0), .new, "榜单升降: 上一期没进榜 = 新")
        expectEqual(M.of(rank: 3, previousRank: 3), .same, "榜单升降: 名次没变")
        expectEqual(M.of(rank: 2, previousRank: 5), .up(3), "榜单升降: 前进 3 名")
        expectEqual(M.of(rank: 5, previousRank: 2), .down(3), "榜单升降: 后退 3 名")
        expectEqual(M.up(3).stepText, "3", "榜单升降: 数字")
        expectEqual(M.up(99).stepText, "99", "榜单升降: 99 照常显示")
        expectEqual(M.up(157).stepText, "99+", "榜单升降: 超过 99 显示 99+")
        expectEqual(M.new.stepText, nil, "榜单升降: 新没有数字")
    }

    // ---- ChartVisibleRows / ArtistTopTracks:「听得最多」显示更多与歌手展开行 ----
    do {
        typealias R = ChartVisibleRows
        expectEqual(R.choices, [10, 25, 50], "榜单条数: 档位 Top 10 / 25 / 50")
        expectEqual(R.choices.max(), R.fetchLimit, "榜单条数: 最大一档等于一次取的条数")
        expectEqual(R.clamped(25), 25, "榜单条数: 档位内的值原样用")
        expectEqual(R.clamped(30), 10, "榜单条数: 不在档位里的偏好值退回 10")

        typealias A = ArtistTopTracks
        expectEqual(A.isCollaboration("Prince & The Revolution"), true, "歌手展开: 合唱署名要标出来")
        expectEqual(A.isCollaboration("Michael Jackson、克里夫兰管弦乐团"), true, "歌手展开: 顿号分隔的合唱")
        expectEqual(A.isCollaboration("Drake feat. Rihanna"), true, "歌手展开: feat. 署名")
        expectEqual(A.isCollaboration("周杰伦"), false, "歌手展开: 只是繁简不同的单人写法不标")
        expectEqual(A.isCollaboration("Anderson .Paak"), false, "歌手展开: 单人名字里的空格不算")

        let line = #"{"rows":{"周杰倫":{"tracks":[{"name":"晴天","artist":"周杰伦","playCount":30}],"trackCount":3,"playCount":43}},"complete":true,"partial":true}"#
        let batch = ArtistTracksBatch.parse(Data(line.utf8))
        expectEqual(batch?.partial, true, "歌手展开: 第 1 页那行带 partial")
        expectEqual(batch?.rows["周杰倫"]?.tracks.first?.artist, "周杰伦", "歌手展开: 保留原始署名")
        expectEqual(batch?.rows["周杰倫"]?.trackCount, 3, "歌手展开: 共几首")
        let final = ArtistTracksBatch.parse(Data(#"{"rows":{},"complete":false}"#.utf8))
        expectEqual(final?.partial, false, "歌手展开: 没有 partial 字段 = 最终结果")
        expectEqual(final?.complete, false, "歌手展开: complete=false 时共几首是下限")
        expectEqual(ArtistTracksBatch.parse(Data("time=... level=INFO".utf8)) == nil, true, "歌手展开: 不是 JSON 的行跳过")

        typealias Q = ArtistTracksQueue
        var q = Q()
        expectEqual(q.submit(.init(period: "12month", full: false, force: false)), true, "歌手展开排队: 空闲时直接跑")
        expectEqual(q.submit(.init(period: "12month", full: false, force: false)), false, "歌手展开排队: 同一时段在跑就不再跑")
        expectEqual(q.queued == nil, true, "歌手展开排队: 正在跑的已经够用,不排")
        expectEqual(q.submit(.init(period: "12month", full: true, force: false)), false, "歌手展开排队: 在跑第 1 页时点开,排一个全部分页")
        expectEqual(q.queued?.full, true, "歌手展开排队: 排的是全部分页")
        expectEqual(q.submit(.init(period: "7day", full: false, force: false)), false, "歌手展开排队: 切时段只排不并发")
        expectEqual(q.queued?.period, "7day", "歌手展开排队: 只留最后一个请求")
        expectEqual(q.loadingPeriods, ["12month", "7day"], "歌手展开排队: 在跑的和排着的都算正在读取")
        expectEqual(q.submit(.init(period: "7day", full: false, force: true)), false, "歌手展开排队: 同时段再来")
        expectEqual(q.queued?.force, true, "歌手展开排队: 带上最新的 force")
        let next = q.finish()
        expectEqual(next?.period, "7day", "歌手展开排队: 跑完交出排着的那个")
        expectEqual(q.running == nil && q.queued == nil && q.loadingPeriods.isEmpty, true, "歌手展开排队: 交出后清空")
        var q2 = Q()
        _ = q2.submit(.init(period: "1month", full: false, force: false))
        _ = q2.submit(.init(period: "12month", full: true, force: false))
        _ = q2.submit(.init(period: "12month", full: false, force: false))
        expectEqual(q2.queued?.full, true, "歌手展开排队: 同时段排着的全部分页要求不被后来的预取冲掉")
        expectEqual(q2.finish()?.full, true, "歌手展开排队: 交出的仍是全部分页")
    }

    // ---- ChartLinkIndex / ChartSummary:「听得最多」右键进 App 打开与卡底概况 ----
    do {
        let idx = ChartLinkIndex.build([
            .init(key: "Prince|I Wanna Be Your Lover|Prince",
                  appleMusicURL: "https://music.apple.com/us/album/prince/1234?i=5678",
                  spotifyTrackID: "6jYG3Ys8OUrB3S7m1LcPo6", kkboxURL: nil),
            .init(key: "Prince|Sexy Dancer|Prince", appleMusicURL: nil, spotifyTrackID: nil, kkboxURL: nil),
            .init(key: "方大同/薛凯琪|复刻回忆|复刻回忆",
                  appleMusicURL: "https://music.apple.com/cn/album/x/42?i=43", spotifyTrackID: nil, kkboxURL: nil),
            .init(key: "Prince|Kiss|Parade", appleMusicURL: nil, spotifyTrackID: "bad-id", kkboxURL: nil),
        ])
        let track = idx.links(kind: .track, artist: "Prince", name: "I Wanna Be Your Lover")
        expectEqual(track?.appleMusic?.absoluteString, "music://music.apple.com/us/album/prince/1234?i=5678",
                    "榜单进 App: 歌曲的 Apple Music 链接改写成 music://")
        expectEqual(track?.spotify?.absoluteString, "spotify:track:6jYG3Ys8OUrB3S7m1LcPo6", "榜单进 App: Spotify 曲目深链")
        expectEqual(idx.links(kind: .track, artist: "prince", name: "i wanna be your lover") == track, true,
                    "榜单进 App: 歌手 / 歌名大小写不计")
        expectEqual(idx.links(kind: .track, artist: "Prince", name: "Sexy Dancer") == nil, true,
                    "榜单进 App: 没有任何进 App 链接的歌不给菜单项")
        expectEqual(idx.links(kind: .track, artist: "Prince", name: "Kiss") == nil, true,
                    "榜单进 App: 不是合法 Spotify 曲目 ID 的不收")
        expectEqual(idx.links(kind: .album, artist: "Prince", name: "Prince")?.appleMusic?.absoluteString,
                    "music://music.apple.com/us/album/x/1234", "榜单进 App: 专辑页由曲目链接里的专辑 ID 换算")
        expectEqual(idx.links(kind: .artist, artist: "Prince", name: "")?.artistAlbum,
                    AlbumEditorialNotes.AlbumRef(id: 1234, storefront: "us"), "榜单进 App: 歌手取一张 Apple Music 专辑")
        expectEqual(idx.links(kind: .track, artist: "方大同", name: "复刻回忆")?.appleMusic != nil, true,
                    "榜单进 App: 合唱署名按主歌手也能查到")
        expectEqual(idx.links(kind: .artist, artist: "陶喆", name: "") == nil, true, "榜单进 App: 缓存里没有的歌手不给")

        // 榜单行是 Last.fm 上的写法(常是繁体),缓存键是引擎写的(多是简体)。
        let han = ChartLinkIndex.build([
            .init(key: "方大同|因为你|15", appleMusicURL: "https://music.apple.com/cn/album/x/11?i=12",
                  spotifyTrackID: nil, kkboxURL: nil),
            .init(key: "陶喆|不爱|太美丽", appleMusicURL: "https://music.apple.com/cn/album/x/21?i=22",
                  spotifyTrackID: nil, kkboxURL: nil),
            .init(key: "陶喆|不愛|太美麗", appleMusicURL: "https://music.apple.com/tw/album/x/31?i=32",
                  spotifyTrackID: nil, kkboxURL: nil),
            .init(key: "陈柏宇|你瞒我瞒|Close Up - EP", appleMusicURL: "https://music.apple.com/cn/album/x/41?i=42",
                  spotifyTrackID: nil, kkboxURL: nil),
            .init(key: "方大同|JTW西游记|JTW西游记", appleMusicURL: "https://music.apple.com/cn/album/x/51?i=52",
                  spotifyTrackID: nil, kkboxURL: nil),
        ])
        expectEqual(han.links(kind: .track, artist: "方大同", name: "因為你")?.appleMusic?.absoluteString,
                    "music://music.apple.com/cn/album/x/11?i=12", "榜单进 App: 繁体写法查得到简体缓存那条")
        expectEqual(han.links(kind: .track, artist: "陶喆", name: "不爱")?.appleMusic?.absoluteString,
                    "music://music.apple.com/cn/album/x/21?i=22", "榜单进 App: 两种写法都在缓存里时简体行用简体那条")
        expectEqual(han.links(kind: .track, artist: "陶喆", name: "不愛")?.appleMusic?.absoluteString,
                    "music://music.apple.com/tw/album/x/31?i=32", "榜单进 App: 两种写法都在缓存里时繁体行用繁体那条")
        expectEqual(han.links(kind: .track, artist: "方大同", name: "因為愛") == nil, true,
                    "榜单进 App: 繁简归一不把别的歌认成这首")
        expectEqual(han.links(kind: .track, artist: "王力宏", name: "因為你") == nil, true,
                    "榜单进 App: 繁简归一不跨歌手")
        let alias: (String) -> String? = { ["Jason Chan": "陳柏宇", "Khalil Fong": "方大同", "陳柏宇": "陳柏宇"][$0] }
        expectEqual(han.links(kind: .track, artist: "Jason Chan", name: "你瞒我瞒") == nil, true,
                    "榜单进 App: 英文名不给别名时查不到")
        expectEqual(han.links(kind: .track, artist: "Jason Chan", name: "你瞒我瞒", aliasArtist: alias)?.appleMusic?.absoluteString,
                    "music://music.apple.com/cn/album/x/41?i=42", "榜单进 App: 英文名按歌手别名换成中文名再查")
        expectEqual(han.links(kind: .track, artist: "陳柏宇", name: "你瞞我瞞", aliasArtist: alias)?.appleMusic != nil, true,
                    "榜单进 App: 别名跟行名相同时照常按繁简归一查")
        expectEqual(han.links(kind: .album, artist: "Khalil Fong", name: "JTW西遊記", aliasArtist: alias)?.appleMusic?.absoluteString,
                    "music://music.apple.com/cn/album/x/51", "榜单进 App: 专辑行也按歌手别名查")
        expectEqual(han.links(kind: .artist, artist: "Khalil Fong", name: "", aliasArtist: alias)?.artistAlbum,
                    AlbumEditorialNotes.AlbumRef(id: 51, storefront: "cn"), "榜单进 App: 歌手行也按歌手别名查")
        expectEqual(han.links(kind: .album, artist: "Khalil Fong", name: "JTW西遊記") == nil, true,
                    "榜单进 App: 专辑行不给别名时查不到")

        // QQ 音乐:缓存只存 songmid,点击时换数字 ID 拼 qqmusicmac:// playsong。
        expectEqual(PlatformLinks.qqSongMID(songPage: "https://y.qq.com/n/ryqq/songDetail/003Jg0u947uwNr"), "003Jg0u947uwNr",
                    "QQ 播放: 从歌曲页取 songmid")
        expectEqual(PlatformLinks.qqSongMID(songPage: "https://y.qq.com/n/ryqq/search?w=%E5%A4%AA%E5%A4%9A"), nil,
                    "QQ 播放: 搜索兜底链接不算")
        expectEqual(PlatformLinks.qqSongMID(songPage: "https://y.qq.com/n/ryqq/songDetail/a/b"), nil, "QQ 播放: 多段路径不算")
        expectEqual(PlatformLinks.qqSongMID(songPage: "https://y.qq.com/n/ryqq/songDetail/"), nil, "QQ 播放: 空 mid 不算")
        expectEqual(PlatformLinks.qqSongMID(songPage: "https://example.com/n/ryqq/songDetail/003Jg0u947uwNr"), nil,
                    "QQ 播放: 别的域名不算")
        let qqIdx = ChartLinkIndex.build([
            .init(key: "吴若希|越难越爱|", appleMusicURL: nil, spotifyTrackID: nil, kkboxURL: nil,
                  qqMusicURL: "https://y.qq.com/n/ryqq/songDetail/003Jg0u947uwNr"),
            .init(key: "群星|太多|烧的时尚", appleMusicURL: nil, spotifyTrackID: nil, kkboxURL: nil,
                  qqMusicURL: "https://y.qq.com/n/ryqq/search?w=x"),
        ])
        expectEqual(qqIdx.links(kind: .track, artist: "吴若希", name: "越难越爱")?.qqSongMID, "003Jg0u947uwNr",
                    "QQ 播放: 只有 QQ 歌曲页的歌也进右键表")
        expectEqual(qqIdx.links(kind: .track, artist: "群星", name: "太多") == nil, true, "QQ 播放: 只有搜索兜底的歌不给菜单")
        typealias QQ = QQSongPlayLink
        expectEqual(QQ.lookupURL(mid: "003Jg0u947uwNr")?.absoluteString,
                    "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=003Jg0u947uwNr",
                    "QQ 播放: 查数字 ID 的接口")
        expectEqual(QQ.lookupURL(mid: "a/b"), nil, "QQ 播放: 不像 mid 的不查")
        expectEqual(QQ.parse(Data(#"{"code":0,"data":[{"id":613725928,"type":0,"mid":"003Jg0u947uwNr"}]}"#.utf8)),
                    QQ.Song(id: 613725928, type: 0), "QQ 播放: 取 id 和 type")
        expectEqual(QQ.parse(Data(#"{"code":0,"data":[{"id":5,"type":11}]}"#.utf8))?.type, 11, "QQ 播放: type 照接口给的")
        expectEqual(QQ.parse(Data(#"{"code":-1,"data":[{"id":5,"type":0}]}"#.utf8)), nil, "QQ 播放: code 不是 0 不认")
        expectEqual(QQ.parse(Data(#"{"code":0,"data":[]}"#.utf8)), nil, "QQ 播放: 没有条目不认")
        expectEqual(QQ.parse(Data(#"{"code":0,"data":[{"id":0,"type":0}]}"#.utf8)), nil, "QQ 播放: id 为 0 不认")
        expectEqual(QQ.parse(Data("not json".utf8)), nil, "QQ 播放: 不是 JSON 不认")
        expectEqual(QQ.playURL(QQ.Song(id: 613725928, type: 0))?.absoluteString,
                    "qqmusicmac://QQMusic/?version==1173&&from==y.qq.com&&cmd_count==1&&cmd_0==playsong&&id_0==613725928&&songtype_0==0&&info_0==&&quality_0==quality",
                    "QQ 播放: playsong 链接用 == 和 && 分隔")
        expectEqual(QQ.playURL(QQ.Song(id: 0, type: 0)), nil, "QQ 播放: id 不是正数不拼")

        expectEqual(ChartSummary.topShare(counts: [50, 30, 20], total: 400), 25, "榜单概况: 前 N 名占比四舍五入")
        expectEqual(ChartSummary.topShare(counts: [10], total: nil), nil, "榜单概况: 总次数没取到不显示占比")
        expectEqual(ChartSummary.topShare(counts: [10], total: 0), nil, "榜单概况: 总次数为 0 不显示占比")
        expectEqual(ChartSummary.topShare(counts: [120], total: 100), 100, "榜单概况: 两个接口的数对不齐时封顶 100")

        typealias P = ArtistPlatformPages
        let mb = #"{"relations":[{"url":{"resource":"https://open.spotify.com/album/1C2h7mLntPSeVYciMRTF4a"}},{"url":{"resource":"https://open.spotify.com/artist/3fMbdgg4jU18AjLCKBhRSm"}},{"url":{"resource":"https://music.apple.com/us/artist/michael-jackson/32940"}},{"url":{"resource":"https://www.deezer.com/artist/259"}}]}"#
        let pages = P.parse(Data(mb.utf8))
        expectEqual(pages.spotify?.absoluteString, "spotify:artist:3fMbdgg4jU18AjLCKBhRSm", "歌手平台页: 取 Spotify 歌手页、跳过专辑链接")
        expectEqual(pages.appleMusic?.absoluteString, "music://music.apple.com/us/artist/michael-jackson/32940",
                    "歌手平台页: Apple Music 歌手页改写成 music://")
        let bad = #"{"relations":[{"url":{"resource":"https://open.spotify.com/artist/short"}},{"url":{"resource":"https://music.apple.com/us/album/x/1"}}]}"#
        expectEqual(P.parse(Data(bad.utf8)), P.Pages(), "歌手平台页: 不合法的 Spotify ID、Apple 专辑页都不收")
        expectEqual(P.parse(Data("not json".utf8)), P.Pages(), "歌手平台页: 返回不是 JSON 时什么都不给")
        expectEqual(P.lookupURL(mbid: "F27EC8DB-af05-4f36-916e-3d57f91ecf5e")?.absoluteString,
                    "https://musicbrainz.org/ws/2/artist/f27ec8db-af05-4f36-916e-3d57f91ecf5e?inc=url-rels&fmt=json",
                    "歌手平台页: 查询地址带 url-rels")
        expectEqual(P.lookupURL(mbid: "../x") == nil, true, "歌手平台页: 不是 mbid 形状的不拼地址")
        let ids = ["周杰倫": "a1", "Prince": "b2"]
        expectEqual(P.mbid(for: "周杰倫", in: ids), "a1", "歌手平台页: 按行名原样查 mbid")
        expectEqual(P.mbid(for: "prince ", in: ids), "b2", "歌手平台页: 忽略大小写与首尾空白")
        expectEqual(P.mbid(for: "陶喆", in: ids) == nil, true, "歌手平台页: 身份缓存里没有的歌手不给")

        typealias C = PlatformPagesCache
        expectEqual(C.albumKey(artist: " Michael Jackson ", album: "Xscape (Deluxe)"), "michael jackson|xscape (deluxe)",
                    "平台页缓存: 专辑键跟引擎 platformAlbumKey 同一个算法")
        let file = #"{"updated":1,"artists":{"mb-mj":{"spotify":"3fMbdgg4jU18AjLCKBhRSm","apple":"https://music.apple.com/us/artist/michael-jackson/32940","checked":1},"mb-none":{"checked":1}},"albums":{"michael jackson|dangerous":{"spotify":"0oX4SealMgNXrvRDhqqOKg","checked":1},"方大同|15":{"checked":1}},"tracks":{"prince|sexy dancer":{"spotify":"3KgByVmDzMkOXwtbqbqjBn","checked":1},"prince|nowhere":{"checked":1}}}"#
        let cache = C.parse(Data(file.utf8))
        expectEqual(cache.artistPages(mbid: "mb-mj")?.spotify?.absoluteString, "spotify:artist:3fMbdgg4jU18AjLCKBhRSm",
                    "平台页缓存: 歌手 Spotify 深链")
        expectEqual(cache.artistPages(mbid: "mb-mj")?.appleMusic?.absoluteString,
                    "music://music.apple.com/us/artist/michael-jackson/32940", "平台页缓存: 歌手 Apple Music 页改写成 music://")
        expectEqual(cache.artistPages(mbid: "mb-none") == nil, true, "平台页缓存: 查过但没登记的歌手不给")
        expectEqual(cache.albumSpotify(artist: "Michael Jackson", album: "Dangerous")?.absoluteString,
                    "spotify:album:0oX4SealMgNXrvRDhqqOKg", "平台页缓存: 专辑按大小写不计的键查到 Spotify 专辑深链")
        expectEqual(cache.albumSpotify(artist: "方大同", album: "15") == nil, true, "平台页缓存: 没登记 Spotify 的专辑不给")
        expectEqual(cache.trackSpotify(artist: "Prince", title: "Sexy Dancer")?.absoluteString,
                    "spotify:track:3KgByVmDzMkOXwtbqbqjBn", "平台页缓存: 歌曲按同一套键查到 Spotify 曲目深链")
        expectEqual(cache.trackSpotify(artist: "Prince", title: "Nowhere") == nil, true, "平台页缓存: 查过没对上的歌不给")
        expectEqual(C.parse(Data("oops".utf8)).albumSpotify(artist: "a", album: "b") == nil, true, "平台页缓存: 文件坏了当空表")
    }

    // ---- PlayCountVariants:「第 N 次听」的写法孪生族(括号风格分裂实测) ----
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
        // 含汉字歌名)。(第二波推翻了此前"各来源写法一致、零候选"的假设 ——
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
        // 字形变体(麼 U+9EBC/麽 U+9EBD,实测:70 条 scrobble 记在麽形下,
        // 括号/繁简候选全扑空——ICU t2s 两个都折到「么」,s2t 永远只生成「麼」,必须显式列表)
        let mo = V.siblings(artist: "丁世光", title: "愛在什麼地方都有（Love Is Everywhere）").map(\.title)
        expectEqual(mo.contains("愛在什麽地方都有(Love Is Everywhere)"), true,
                    "写法族: 麼→麽 字形变体×半角括号(实测大头写法)")
        expectEqual(mo.count <= 6, true, "写法族: 麽族封顶 6,实际 \(mo.count)")
        expectEqual(V.siblings(artist: "X", title: "為你我受冷風吹").map(\.title).contains("爲你我受冷風吹"),
                    true, "写法族: 无副题歌名也给字形变体(為/爲)")
    }

    // ---- PlayCountFold:写法索引的折叠键(数据驱动合并的地基) ----
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

        // 再版噪音副题折叠(实测:宇多田ヒカル Automatic 两本账)——
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

        // feat 客串署名家族(第二波实测:王力宏《盖世英雄 (feat. 欧阳靖 &
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

        // 补齐到参考实现 export-lastfm-tracks.py 的口径。三族都在那份
        // 与用户逐对核定的规则里,Swift 侧此前漏搬 —— 不是新发明的规则。
        //
        // ① bonus track:原案。实测 Last.fm 两个实体「一路向北」14 次、
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

        // 剥掉目录学噪音之后不能让 R1 再把版本标记当译名吃掉(补 bonus track
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
        // ---- 第三批----
        // ⑥ R1 守卫**套到原串**:中文歌名的 Live/Demo 版不再被当译名收进录音室版。
        //    这一条此前反过来钉着「现状」(expectEqual),后翻面 —— 见 foldTitle 注释。
        expectNotEqual(F.key(artist: "陶喆", title: "流沙 - Live"),
                       F.key(artist: "陶喆", title: "流沙"),
                       "折叠键: 中文歌名的 - Live 不再并进本尊")

        // ---- 第二批(并行核实回来之后)----
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
        // 裸场次标记**不**归一(并行核实推翻了原设计):album.getinfo 实测
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
        // ⑧ 歌手写法归并只作用在查族用的 familyKey 上,且**没有手写表**:表由
        // LocalArtistAliases.derive 从本机数据推出来再灌进来。这里用一份最小的 MusicBrainz 缓存
        // 夹具还原这个归并形态,确认覆盖得到。
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
        // familyKey 仍要做合唱归首位(那条能力不能丢)
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

        // ⑨ 歌名维度的罗马字/译名别名(有,同样没有手写表):由
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
        // 核心安全约束:这张表必须按(歌手,歌名)登记,不能是全局 title->title——
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

    // MARK: - LastfmRecentFeed(引擎落盘的最近记录 feed)
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
                                             countedToday: 99, countedThrough: 0)
        expectEqual(r1.count, 3, "today: 窗口盖住整天 → 数窗口")
        expectEqual(r1.exact, true, "today: 窗口盖住整天 → 精确")
        // ② 窗口盖不住(全是今天的 50 首),但日桶今天同步到 1150:桶 40 + 晚于 1150 的 2 行。
        let r2 = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200, 1100, 1050], todayStart: 1000,
                                             countedToday: 40, countedThrough: 1150)
        expectEqual(r2.count, 42, "today: 日桶 + 同步后新行")
        expectEqual(r2.exact, true, "today: 日桶今天同步过 → 精确")
        // ②' 日桶今天没有条目(nil 当 0)但同步过:同步后的 1 行,不低于窗口里今天的 2 行。
        let r2b = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200], todayStart: 1000,
                                              countedToday: nil, countedThrough: 1200)
        expectEqual(r2b.count, 2, "today: 桶为 nil 当 0,不低于窗口里今天的行数")
        expectEqual(r2b.exact, true, "today: 桶为 nil 但窗口够得着 → 精确")
        // ②'' 日桶同步到 1100 记了 10 首,窗口最旧一行是 1200:1100~1200 之间谁都没数到,
        //      不能当成 10 + 窗口行数的精确值。
        let r2c = LastfmRecentFeed.todayCount(rowUTS: [1400, 1300, 1200], todayStart: 1000,
                                              countedToday: 10, countedThrough: 1100)
        expectEqual(r2c.exact, false, "today: 窗口跟已知计数之间有空档 → 不精确")
        expectEqual(r2c.count, 3, "today: 有空档时只给窗口里的下界")
        // ②''' 最旧一行正好落在 countedThrough 上:没有空档,那一行已经算在已知计数里。
        let r2d = LastfmRecentFeed.todayCount(rowUTS: [1400, 1300, 1200], todayStart: 1000,
                                              countedToday: 10, countedThrough: 1200)
        expectEqual(r2d.count, 12, "today: 边界那一行不重复计")
        expectEqual(r2d.exact, true, "today: 窗口够得着已知计数 → 精确")
        // ③ 两者都不行:窗口全是今天、日桶停在昨天 → 只给下界、不精确。
        let r3 = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200, 1100, 1050], todayStart: 1000,
                                             countedToday: nil, countedThrough: 500)
        expectEqual(r3.count, 4, "today: 退化成下界")
        expectEqual(r3.exact, false, "today: 日桶停在昨天 → 不精确,调用方补一个请求")
        // ④ 空 feed(新账号)+ 今天同步过:0。
        let r4 = LastfmRecentFeed.todayCount(rowUTS: [], todayStart: 1000, countedToday: nil, countedThrough: 1200)
        expectEqual(r4.count, 0, "today: 空窗口")
        expectEqual(r4.exact, true, "today: 空窗口但今天同步过 → 精确 0")
    }

    // MARK: - LastfmPageComposer(按绝对位置拼页)
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

    // MARK: - ListeningHours(收听时段)
    do {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let fmt = DateFormatter()
        fmt.calendar = cal; fmt.timeZone = cal.timeZone; fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let key: (Date) -> String = { fmt.string(from: $0) }
        let today = fmt.date(from: "2026-09-27")!.addingTimeInterval(3600 * 18) // 周日 18:00
        func row(_ pairs: [Int: Int]) -> [Int] {
            var r = [Int](repeating: 0, count: ListeningHours.hoursPerDay)
            for (h, n) in pairs { r[h] = n }
            return r
        }
        let hourly: [String: [Int]] = [
            "2026-09-27": row([21: 5]),        // 周日
            "2026-09-21": row([8: 3]),         // 周一
            "2026-08-29": row([10: 1]),        // 周六,近 30 天的第一天
            "2026-08-28": row([23: 4]),        // 周五,刚好在近 30 天外
            "2026-08-01": row([16: 10]),       // 周六
            "2026-07-01": [1, 2, 3],           // 长度不对,整行忽略
        ]
        let month = ListeningHours.summarize(hourly: hourly, span: .month, today: today, calendar: cal, dayKey: key)
        expectEqual(month?.total, 9, "收听时段: 近 30 天含今天、含第 30 天、不含第 31 天")
        expectEqual(month?.peakHour, 21, "收听时段: 近 30 天最常听的钟点")
        expectEqual(month?.weekdays, [3, 0, 0, 0, 0, 1, 5], "收听时段: 星期几周一在前")
        expectEqual(month?.peakWeekday, 6, "收听时段: 近 30 天听得最多是周日")
        expectEqual(month?.quietestHour, 0, "收听时段: 并列最少取最早的钟点")
        let all = ListeningHours.summarize(hourly: hourly, span: .overall, today: today, calendar: cal, dayKey: key)
        expectEqual(all?.total, 23, "收听时段: 全部")
        expectEqual(all?.peakHour, 16, "收听时段: 全部的最常听钟点")
        expectEqual(all?.peakWeekday, 5, "收听时段: 全部里周六最多")
        expectEqual(ListeningHours.summarize(hourly: ["2025-01-01": row([9: 2])], span: .month, today: today,
                                             calendar: cal, dayKey: key) == nil,
                    true, "收听时段: 范围内一次都没有 → nil")
        let tie = ListeningHours.summarize(hourly: ["2026-09-26": row([9: 2, 20: 2])], span: .month, today: today,
                                           calendar: cal, dayKey: key)
        expectEqual(tie?.peakHour, 9, "收听时段: 并列最多取最早的钟点")
    }

    // MARK: - ArtistRegions(歌手来自哪里)
    do {
        let json = """
        {"user":"KhalilChan3","periods":{"1month":{"top_artists":200,"covered":100,"pending":2,"pending_artists":["林宥嘉"],"unresolved":8,"unresolved_artists":["Valorant"],
          "regions":[{"code":"US","plays":40,"artists":["Prince","Michael Jackson","Musiq"]},
                     {"code":"TW","plays":20,"artists":["陶喆"]},{"code":"HK","plays":10,"artists":["方大同"]},
                     {"code":"CN","plays":7,"artists":["丁世光"]},{"code":"JP","plays":5,"artists":["宇多田ヒカル"]},
                     {"code":"KR","plays":4,"artists":["aespa"]},{"code":"GB","plays":3,"artists":["Adele"]},
                     {"code":"CA","plays":3,"artists":["Daniel Caesar"]},{"code":"FR","plays":0,"artists":[]}]},
          "overall":{"covered":5}}}
        """.data(using: .utf8)!
        let parsed = ArtistRegions.parse(json, user: "khalilchan3")
        expectEqual(parsed.keys.sorted(), ["1month", "overall"], "歌手地区: 账号名不分大小写")
        expectEqual(ArtistRegions.parse(json, user: "someone").isEmpty, true, "歌手地区: 别的账号的文件不认")
        expectEqual(ArtistRegions.parse(Data("{}".utf8), user: "x").isEmpty, true, "歌手地区: 没记账号的文件不认")
        expectEqual(parsed["overall"]?.regions.isEmpty, true, "歌手地区: 缺字段按空")
        expectEqual(parsed["1month"]?.topArtists, 200, "歌手地区: 按歌手榜前多少位统计,照引擎写进文件的")
        expectEqual(parsed["overall"]?.topArtists, 0, "歌手地区: 文件里没写位数按 0(卡底那句说明不显示)")
        let rows = ArtistRegions.rows(parsed["1month"]!)
        expectEqual(rows.map(\.kind), [.region("US"), .region("TW"), .region("HK"), .region("CN"), .region("JP"),
                                       .region("KR"), .other, .pending, .unresolved], "歌手地区: 前 6 个地区 + 其他 + 还在查 + 未查到")
        expectEqual(rows[7].artists, ["林宥嘉"], "歌手地区: 还在查列引擎给的名字")
        expectEqual(rows[6].plays, 6, "歌手地区: 其他 = 第 7 名起的合计(次数 0 的不算)")
        expectEqual(rows[6].artists, ["Adele", "Daniel Caesar"], "歌手地区: 其他列各地区第一位")
        expectEqual(rows[8].artists, ["Valorant"], "歌手地区: 未查到列引擎给的名字")
        expectEqual(ArtistRegions.period(for: .year), "12month", "歌手地区: 范围对到 Last.fm 时段名")
        let nullNames = Data(#"{"user":"u","periods":{"1month":{"covered":3,"regions":[{"code":"US","plays":3,"artists":null}]}}}"#.utf8)
        expectEqual(ArtistRegions.parse(nullNames, user: "u")["1month"]?.regions.first?.plays, 3,
                    "歌手地区: 名字列表是 null 时这一行照样读出来")
        expectEqual(ArtistRegions.rows(ArtistRegions.parse(nullNames, user: "u")["1month"]!).map(\.kind), [.region("US")],
                    "歌手地区: 全部查完(没有 pending)就不出「还在查」")
    }

    // MARK: - 目录学噪音副题(共用样例:引擎按同一口径决定收听记到 Last.fm 的哪一条)
    do {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/testdata/catalog-noise-subtitles.json")
        let sample = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String]] } ?? [:]
        let noise = sample["noise"] ?? [], notNoise = sample["not_noise"] ?? []
        expectEqual(noise.count > 10 && notNoise.count > 10, true, "副题样例: 读到了共用样例")
        expectEqual(noise.filter { !PlayCountVariants.isCatalogNoiseSubtitle($0) }, [], "副题样例: 这些是噪音(剥掉)")
        expectEqual(notNoise.filter { PlayCountVariants.isCatalogNoiseSubtitle($0) }, [], "副题样例: 这些不是噪音(留着)")
    }

    // MARK: - OnThisDayPlanner / ListeningMilestones(那年今日计划 + 收听足迹)
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

        // 足迹:~ 09-02 连续四天,09-03(今天)还没记录 → 当前连续 4;最长 5(08-10~08-14)。
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

    // ---- 「那边没有次数」结论的退避重探 ----
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

    // ---- 次数记账三态:字段缺失 ≠ 那边是 0 ----
    //
    // `userplaycount` **字段缺失**(Last.fm 的按用户计数是另一次后端查询,高并发下会静默
    // 缺字段)不等于"那边回答 0 次"——混为一谈会把一次抖动写成定论、随快照落盘,而进了
    // 「那边没有」名单的行连 `···` 占位都不画,看起来就是"这行天生没有次数"。
    do {
        typealias O = PlayCountOutcome
        func c(_ ok: Bool, _ n: Int?, _ old: Bool) -> O {
            O.classify(requestSucceeded: ok, reportedCount: n, rowIsOldEnough: old)
        }
        // ① 本次修复的那一条:请求成功、行也够老,但响应没带 userplaycount → 不许记定论
        expectEqual(c(true, nil, true), .unanswered,
                    "次数三态: 成功返回但没带 userplaycount → 没答上来,不记进「那边没有」")
        // ② 那边真的回答 0,且行够老 → 这才是定论
        expectEqual(c(true, 0, true), .definitivelyNone,
                    "次数三态: 够老的行拿到 0 → 那边确实没有")
        // ③ 已知坑:刚 scrobble 完的 0 是"还没并账",不是答案(playCountZeroGraceSecs)
        expectEqual(c(true, 0, false), .unanswered,
                    "次数三态: 行还太新,0 不算数(Last.fm 还没并账)")
        // ④ 正数照常记,新老都一样
        expectEqual(c(true, 18, true), .counted(18), "次数三态: 拿到正数就记(够老的行)")
        expectEqual(c(true, 1, false), .counted(1), "次数三态: 拿到正数就记(刚 scrobble 的行也算)")
        // ⑤ 请求本身失败(超时/限流)一律没答上来 —— 带回来的数无论是什么都不该被采信
        expectEqual(c(false, nil, true), .unanswered, "次数三态: 请求失败 → 没答上来")
        expectEqual(c(false, 0, true), .unanswered, "次数三态: 请求失败时的 0 不算定论")
        expectEqual(c(false, 5, true), .unanswered, "次数三态: 请求失败时的正数也不采信")
        // ⑥ error 6 那条路:调用方传 reportedCount: 0 —— "压根没这个实体"跟"0 次"是同一个答案,
        //    必须仍是定论,否则本机那 7 首有声书章节会每轮重问、永不收敛(的原始动机)
        expectEqual(c(true, 0, true), .definitivelyNone,
                    "次数三态: error 6(按 0 传入)仍是定论,不能退化成每轮重问")
    }

    // ---- 「第 N 次听」合并明细:为什么并进来 + 跨写法合并/编号 ----
    //
    // 弹框上半段每种写法旁边挂的原因标签,由 PlayCountFoldExplainer 沿 PlayCountFold 的真实折叠
    // 步骤逐级比对得出 —— 标签跟规则对不上会比没有标签更误导,所以每一档各钉一条真实分裂形态
    // (全部取自 12 章 §7 记录过的实测案例)。
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
        // 不挂标签 —— 跟写法族那层的 .other 语义刻意不同(挂上去会让人以为是折叠规则并的)
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

        // 跨写法同一时刻**不去重**:卢广仲《Boring》实测 `卢广仲` 13 条 +
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
        // 只数这一写法自己的记录(《晴天》葉惠美/叶惠美两种专辑名要看得见)
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

    // ---- 第三层歌名别名:从本机 enrich 缓存推「英文歌名 → 中文歌名」 ----
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
        // 实测抓到的两个坑(用真实缓存预演):
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
        // 中文侧的繁简两种写法折到同一键 → 仍算唯一,照常产出(实测 Playful 与 玩乐/玩樂)
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

    // ---- 歌名别名 E2:时长 + 歌词都对得上(下午,取代手写表 titleAliasesByArtist 的最后一步) ----
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
        // 整秒精度的一侧:224 vs 224.499 仍在 0.6 s 容差内(Twenty Three 与 才二十三 实测)
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

    // ---- 歌手写法归并的通用推断(LocalArtistAliases，取代手写表 romanizedArtistAliases) ----
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

        // 共享歌曲 id:≥ 2 个不同 id 才算;单个不算(方大同 与 王诗安 那种合唱撞一首)
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

    // ---- 热力图截断判据(LastfmHeatmapTruncation)----
    //
    // 判截断就会清空按天计数、重跑一百多页的首次全量:误判的代价是白扫一遍,漏判是热力图一直只剩最近几天。
    do {
        typealias H = LastfmHeatmapTruncation
        expectEqual(H.looksTruncated(dailyTotal: 3_124, reportedTotal: 24_327, rescanAttempted: false), true,
                    "热力图截断: 实测那次(3,124 vs 24,327)判截断")
        expectEqual(H.looksTruncated(dailyTotal: 24_300, reportedTotal: 24_327, rescanAttempted: false), false,
                    "热力图截断: 只差几十条是正常的")
        expectEqual(H.looksTruncated(dailyTotal: 70, reportedTotal: 100, rescanAttempted: false), false,
                    "热力图截断: 正好七成不算截断")
        expectEqual(H.looksTruncated(dailyTotal: 69, reportedTotal: 100, rescanAttempted: false), true,
                    "热力图截断: 不到七成算截断")
        expectEqual(H.looksTruncated(dailyTotal: 0, reportedTotal: 100, rescanAttempted: false), true,
                    "热力图截断: 一条都没有算截断")
        expectEqual(H.looksTruncated(dailyTotal: 0, reportedTotal: nil, rescanAttempted: false), false,
                    "热力图截断: 总数还没取到不判")
        expectEqual(H.looksTruncated(dailyTotal: 0, reportedTotal: 0, rescanAttempted: false), false,
                    "热力图截断: 总数为 0 不判")
        expectEqual(H.looksTruncated(dailyTotal: 3_124, reportedTotal: 24_327, rescanAttempted: true), false,
                    "热力图截断: 这次启动已经重扫过一轮就不再判(免得每 15 分钟重扫一遍)")
    }

    // ---- 本机别名表的重算节流(契约) ----
    // 每次缓存版本推进都整份重算的话,补搜 / 全量扫库期间一个核心断断续续满载(每首约 13 秒推进一次,
    // 一次重算几秒 CPU)。缓存变化那条路必须经节流入口,不能直接调 refreshLocalAliases。
    do {
        let src = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lyrimuse/Settings/LastfmStatsService.swift"),
            encoding: .utf8)) ?? ""
        expectEqual(src.contains("if titleFormsLoaded { scheduleLocalAliasRefreshAfterCacheChange() }"), true,
                    "别名节流: 缓存变化走节流入口")
        expectEqual(src.contains("if titleFormsLoaded { refreshLocalAliases(rebuildFamilies: true) }"), false,
                    "别名节流: 没有绕过节流直接重算的缓存变化路径")
    }

    // ---- 右键链接只在统计区在屏上时算(契约) ----
    // 整份建链接索引要几百毫秒主线程,而本机缓存播放中几秒就变一次;设置是 Settings {} 场景、关窗不卸载视图,
    // 不拦的话关着窗也每变一次缓存重建一次。
    do {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let service = (try? String(contentsOf: base.appendingPathComponent("lyrimuse/Settings/LastfmStatsService.swift"),
                                   encoding: .utf8)) ?? ""
        let section = (try? String(contentsOf: base.appendingPathComponent("lyrimuse/LastfmStatsSection.swift"),
                                   encoding: .utf8)) ?? ""
        expectEqual(service.contains("private func refreshChartAppLinks() {\n        guard chartAppLinksOnScreen else { return }"),
                    true, "右键链接: 统计区不在屏上时不算")
        expectEqual(section.contains(".onChange(of: windowVisible) { _, visible in stats.setChartAppLinksOnScreen(visible) }"),
                    true, "右键链接: 设置窗口看不看得见报给服务")
        expectEqual(section.contains(".onDisappear { stats.setChartAppLinksOnScreen(false) }"), true,
                    "右键链接: 统计区卸载时报不在屏上")
        expectEqual(section.contains("if let mid = links?.qqSongMID, Self.isInstalled(.qqMusic) {")
                        && section.contains("|| (links.qqSongMID != nil && Self.isInstalled(.qqMusic))"), true,
                    "右键链接: QQ 音乐那项只在装了 QQ 音乐时出,有它的行才挂菜单")
        expectEqual(section.contains(#"NetworkAuditLog.record(service: "qq", operation: "song.detail""#), true,
                    "右键链接: 查 QQ 数字歌曲 ID 记对外请求日志")
        expectEqual(section.contains("await launchQQMusicIfNeeded()\n            NSWorkspace.shared.open(url)"), true,
                    "右键链接: QQ 音乐没开着时先启动好再发链接")
    }

    // ---- Last.fm 账号连没连 Spotify(spotify_expiry_estimate,见 LastfmSpotifyLink)----
    do {
        func user(_ json: String) -> [String: Any] {
            ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
        }
        let at = Date(timeIntervalSince1970: 1_767_225_600)
        let expiry = LastfmSpotifyLink.expiry(user:)
        expectEqual(expiry(user(##"{"name":"x","registered":{"unixtime":"1037793040","#text":1037793040}}"##)), nil,
                    "Spotify 连接: 没有这个字段 → 没连")
        expectEqual(expiry(user(##"{"spotify_expiry_estimate":{"unixtime":"1767225600","#text":1767225600}}"##)), at,
                    "Spotify 连接: unixtime 是字符串")
        expectEqual(expiry(user(##"{"spotify_expiry_estimate":{"unixtime":"1767225600"}}"##)), at,
                    "Spotify 连接: 只有字符串 unixtime")
        expectEqual(expiry(user(##"{"spotify_expiry_estimate":{"unixtime":1767225600}}"##)), at,
                    "Spotify 连接: unixtime 是数字")
        expectEqual(expiry(user(##"{"spotify_expiry_estimate":{"#text":1767225600}}"##)), at,
                    "Spotify 连接: 只有 #text 也认")
        expectEqual(expiry(user(##"{"spotify_expiry_estimate":"1767225600"}"##)), at,
                    "Spotify 连接: 直接给时间戳也认")
        expectEqual(expiry(user(##"{"spotify_expiry_estimate":{"unixtime":"0"}}"##)), nil, "Spotify 连接: 0 不算")
        expectEqual(expiry(user(##"{"spotify_expiry_estimate":{"unixtime":""}}"##)), nil, "Spotify 连接: 空串不算")
        expectEqual(expiry(user(##"{"spotify_expiry_estimate":{}}"##)), nil, "Spotify 连接: 空对象不算")

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let later = now.addingTimeInterval(86_400), earlier = now.addingTimeInterval(-86_400)
        expectEqual(LastfmSpotifyLink(expiry: nil, now: now), .notLinked, "Spotify 连接: 没有到期时间 → 没连")
        expectEqual(LastfmSpotifyLink(expiry: later, now: now), .linked(expires: later), "Spotify 连接: 到期在后 → 连着")
        expectEqual(LastfmSpotifyLink(expiry: earlier, now: now), .expired(at: earlier), "Spotify 连接: 到期在前 → 过期")
        expectEqual(LastfmSpotifyLink(expiry: now, now: now), .expired(at: now), "Spotify 连接: 正好到点算过期")

        let linked = LastfmSpotifyLink.linked(expires: later), expired = LastfmSpotifyLink.expired(at: earlier)
        expectEqual(linked.playersRowHint(spotifyExcluded: false), .doubleScrobble, "Spotify 提示: 连着又勾着 → 每首记两次")
        expectEqual(linked.playersRowHint(spotifyExcluded: true), nil, "Spotify 提示: 连着、已排除 → 不提示")
        expectEqual(expired.playersRowHint(spotifyExcluded: true), .expiredWhileExcluded(at: earlier),
                    "Spotify 提示: 已排除、连接过期 → 两边都不记")
        expectEqual(expired.playersRowHint(spotifyExcluded: false), nil, "Spotify 提示: 过期但勾着 → 这边在记,不提示")
        expectEqual(LastfmSpotifyLink.notLinked.playersRowHint(spotifyExcluded: false), nil, "Spotify 提示: 没连、勾着 → 不提示")
        expectEqual(LastfmSpotifyLink.notLinked.playersRowHint(spotifyExcluded: true), nil, "Spotify 提示: 没连、已排除 → 不提示")

        let stamp = Int64(earlier.timeIntervalSince1970)
        expectEqual(expired.expiryToAnnounce(spotifyExcluded: true, announced: nil), stamp, "Spotify 通知: 已排除、过期、没弹过 → 弹")
        expectEqual(expired.expiryToAnnounce(spotifyExcluded: true, announced: stamp), nil, "Spotify 通知: 同一次过期只弹一次")
        expectEqual(expired.expiryToAnnounce(spotifyExcluded: true, announced: stamp - 15_552_000), stamp,
                    "Spotify 通知: 弹过的是上一次过期 → 这次再弹")
        expectEqual(expired.expiryToAnnounce(spotifyExcluded: false, announced: nil), nil, "Spotify 通知: 勾着 Spotify → 不弹")
        expectEqual(linked.expiryToAnnounce(spotifyExcluded: true, announced: nil), nil, "Spotify 通知: 还连着 → 不弹")

        let due = LastfmSpotifyLink.checkDue
        expectEqual(due(nil, now, 86_400, false), true, "Spotify 查询: 没查成过 → 查")
        expectEqual(due(now.addingTimeInterval(-3_600), now, 86_400, false), false, "Spotify 查询: 一小时前查过 → 不查")
        expectEqual(due(now.addingTimeInterval(-86_400), now, 86_400, false), true, "Spotify 查询: 满一天 → 查")
        expectEqual(due(now.addingTimeInterval(-60), now, 86_400, true), true, "Spotify 查询: 要弹通知 → 先重查确认")
        expectEqual(due(now.addingTimeInterval(60), now, 86_400, false), true, "Spotify 查询: 时钟倒退 → 查")
    }

    // ---- 「Last.fm 账号建议」排哪几条(见 LastfmAccountSuggestion)----
    do {
        let spotify = LastfmSpotifyLink.PlayersRowHint.doubleScrobble
        let current = LastfmAccountSuggestion.current
        expectEqual(current(nil, true, false, nil), [], "账号建议: 什么事都没有 → 没有建议")
        expectEqual(current("超时", false, false, nil), [.connectFailed("超时")], "账号建议: 连接失败,还没连上也要出")
        expectEqual(current("超时", true, true, nil), [.connectFailed("超时")], "账号建议: 连接失败和授权失效只出一条重新连接")
        expectEqual(current(nil, true, true, nil), [.authRevoked], "账号建议: 授权失效")
        expectEqual(current(nil, false, true, nil), [], "账号建议: 断开后留下的状态文件不算")
        expectEqual(current(nil, true, false, spotify), [.spotify(spotify)], "账号建议: Spotify 那条")
        expectEqual(current(nil, true, true, spotify), [.authRevoked, .spotify(spotify)], "账号建议: 要紧的在前")
    }

    // ---- Spotify 连接提示的接线(契约) ----
    // 判据都在上面测了;这几处接线断了,提示和通知就静默不出。
    do {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ rel: String) -> String {
            (try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8)) ?? ""
        }
        expectEqual(src("lyrimuse/AppDelegate.swift").contains("LastfmSpotifyLinkMonitor.shared.start()"), true,
                    "Spotify 连接(契约): 启动时开始盯")
        expectEqual(src("lyrimuse/Settings/UnknownPlayerNotifier.swift")
                        .contains("category == LastfmSpotifyLinkMonitor.categoryID"), true,
                    "Spotify 连接(契约): 点通知分流到 Last.fm 账号页")
        let tab = src("lyrimuse/AccountLinkingTab.swift")
        let card = tab.range(of: "private var lastfmProfileCard: some View {")?.upperBound
        let cardEnd = tab.range(of: "private var lastfmProfileStatusLine: some View {")?.lowerBound
        let body = card.flatMap { start in cardEnd.map { String(tab[start..<$0]) } } ?? ""
        let groupStart = tab.range(of: "private var lastfmSuggestionsGroup: some View {")?.upperBound
        let group = groupStart.map { String(tab[$0...].prefix(700)) } ?? ""
        expectEqual(group.contains("if let hint = spotifyLink.hint {") && group.contains("LastfmSpotifySuggestionRow(hint: hint)")
                        && tab.contains("lastfmProfileCard\n                        lastfmSuggestionsGroup"), true,
                    "Spotify 连接(契约): 建议在页头卡下面单独一组")
        let settingsView = src("lyrimuse/SettingsView.swift")
        expectEqual(settingsView.contains("if !suggestions.items.isEmpty {")
                        && settingsView.contains("LastfmSuggestionsSidebarRow(count: suggestions.items.count)\n                    .tag(SettingsSidebarItem.lastfmSuggestions)"),
                    true, "Spotify 连接(契约): 侧栏有建议时多一行「Last.fm 账号建议」")
        expectEqual(src("lyrimuse/Settings/SettingsSidebarChrome.swift").contains("SidebarAlertDot"), false,
                    "账号建议(契约): 头像上不再挂标记")
        let suggestionsFile = src("lyrimuse/Settings/LastfmAccountSuggestions.swift")
        let wizardAt = suggestionsFile.range(of: "AppActions.shared.requestLastfmWizard()")?.lowerBound
        let jumpAt = suggestionsFile.range(of: "AppActions.shared.requestSettings(.account(.lastfm))")?.lowerBound
        expectEqual(wizardAt != nil && jumpAt != nil && wizardAt! < jumpAt!, true, "账号建议(契约): 重新连接切到 Last.fm 页并请求打开向导")
        expectEqual(tab.contains(".onReceive(AppActions.shared.lastfmWizardRequests)")
                        && tab.contains("if AppActions.shared.pendingLastfmWizard {"), true,
                    "账号建议(契约): Last.fm 页收到请求就打开向导(开着收广播、新建时读信箱)")
        expectEqual(settingsView.contains("case .lastfmSuggestions: LastfmSuggestionsPage()"), true,
                    "Spotify 连接(契约): 那一行点进建议页")
        expectEqual(body.contains("LastfmSpotifyLinkMonitor.shared.refreshIfStale()"), true,
                    "Spotify 连接(契约): 打开账号页时按需重查")
        let row = src("lyrimuse/Settings/LastfmAccountSuggestions.swift")
        expectEqual(row.contains("Button(L10n.t(\"只让 Lyrimuse 记…\")) { openLastfmApplications() }"), true,
                    "Spotify 连接(契约): 重复记那一行能去 Last.fm 断开")
        expectEqual(row.contains("LastfmSpotifyLinkMonitor.shared.recheckWhenBack()\n        NSWorkspace.shared.open("), true,
                    "Spotify 连接(契约): 去网站之前登记回来重查")
        expectEqual(src("lyrimuse/Settings/LastfmSpotifyLinkMonitor.swift")
                        .contains(".publisher(for: NSApplication.didBecomeActiveNotification)"), true,
                    "Spotify 连接(契约): 回到 App 时重查")
    }
}
