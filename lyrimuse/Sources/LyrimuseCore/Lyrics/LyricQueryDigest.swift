import Foundation

/// 把「这一轮实际问过哪些查询词」压成可读的分组(2026-09-12,借鉴清单 V1 的续篇)。
///
/// **为什么需要这一层**:V1 落地当天用户就报「这部分可读性很差」。真实案例
/// (宇多田光《Beautiful World (Da Capo Version) [Instrumental]》)一轮问了 9 组词,
/// 逐条平铺出来是这样:
///
///     · Utada - Beautiful World (Da Capo Version) [Instrumental]（首轮）
///     · Hikaru Utada - Beautiful World (Da Capo Version) [Instrumental]（别名轮：补缺席的源 → 只问 网易云音乐、QQ音乐、LRCLIB、Musixmatch、AMLL、酷我音乐、咪咕音乐）
///     · 宇多田ヒカル - Beautiful World (Da Capo Version) [Instrumental]（别名轮：补缺席的源 → 只问 网易云音乐、QQ音乐、LRCLIB、…）
///     …再来六行一模一样的后缀
///
/// 屏幕上 20 多个视觉行,而**真正的信息只有「曲名没变,换了 9 个歌手名」**:曲名重复 9 遍、
/// 那串七个源的名单重复 8 遍。噪音淹掉了信号。
///
/// 压法两条:
///   1. **全部记录曲名相同**时把曲名提到顶上说一次(`sharedTitle`),组内只列歌手名 ——
///      曲名变过(标题反查轮)时 `sharedTitle` 为 nil,曲名并回每一条里,不丢信息。
///   2. **按「来路 + 源名单」分组**,组内歌手名拼成一行。那串源名单于是每组只出现一次。
///
/// ⚠️ **分组不排序**,保持首次出现的顺序 —— 先问什么、后问什么本身就是要复盘的信息
/// (首轮问的对不对、别名轮是被什么触发的)。组内歌手名同理按出现顺序,只去重。
public struct LyricQueryRound: Sendable, Equatable {
    public let artist: String
    public let title: String
    /// 来路,空 = 首轮。取值全集见 collector 的 `lyricQueryReason*`(querylog.go)。
    public let reason: String
    /// 这一轮只问了这几个源;空 = 没有限制。
    public let sources: [String]

    public init(artist: String, title: String, reason: String, sources: [String]) {
        self.artist = artist
        self.title = title
        self.reason = reason
        self.sources = sources
    }
}

/// 组内的一条查询词。**刻意不在这里拼成一个字符串** —— 「歌手 - 曲名」那种拼法是
/// 展示决定,不该由 Core 定:2026-09-12 用户截图报「需要能看出来分别是歌名、歌手、专辑」,
/// 正是拼在一起之后谁也认不出谁(那次是 `米津玄師 · 米津玄師、宇多田ヒカル` —— 分隔符
/// 跟歌手名里本来就有的顿号混成一片,读不出这是几个名字)。View 拿到字段自己加标签。
public struct LyricQueryPair: Sendable, Equatable {
    public let artist: String
    /// 曲名。`LyricQueryDigest.sharedTitle` 非空(曲名全程没变、已提到顶上说过一次)时
    /// 为空串;曲名变过、或这一轮压根没有曲名时才有值。
    public let title: String

    public init(artist: String, title: String) {
        self.artist = artist
        self.title = title
    }
}

/// 一组「同一个来路 + 同一份源名单」的查询词。
public struct LyricQueryGroup: Sendable, Equatable, Identifiable {
    public var id: String { reason + "\u{1F}" + sources.joined(separator: ",") }
    public let reason: String
    public let sources: [String]
    /// 组内每一条。
    public let queries: [LyricQueryPair]

    public init(reason: String, sources: [String], queries: [LyricQueryPair]) {
        self.reason = reason
        self.sources = sources
        self.queries = queries
    }
}

public struct LyricQueryDigest: Sendable, Equatable {
    /// 全部记录的曲名都一样时给出它(提到顶部说一次);不一样、或压根没有曲名时为 nil。
    public let sharedTitle: String?
    public let groups: [LyricQueryGroup]
    /// 原始记录条数(压缩前),给「实际问过 N 组」那句话用 —— 压缩不该让人以为只问了两次。
    public let total: Int

    public init(sharedTitle: String?, groups: [LyricQueryGroup], total: Int) {
        self.sharedTitle = sharedTitle
        self.groups = groups
        self.total = total
    }

    /// 去重压缩之后实际还剩几条查询词。跟 `total`(压缩前的原始条数)刻意分开 ——
    /// 界面上显示的是 `total`(不该让人以为只问了两次),这个只给测试核对去重效果。
    public var queriesFlatCount: Int { groups.reduce(0) { $0 + $1.queries.count } }
}

public enum LyricQueryDigestBuilder {
    public static func build(_ rounds: [LyricQueryRound]) -> LyricQueryDigest {
        guard !rounds.isEmpty else {
            return LyricQueryDigest(sharedTitle: nil, groups: [], total: 0)
        }
        // 曲名是不是自始至终没变过。空曲名不参与"共享"判断——一条空、一条有,那就是不同。
        let titles = Set(rounds.map(\.title))
        let shared: String? = (titles.count == 1 && !(titles.first ?? "").isEmpty) ? titles.first : nil

        var order: [String] = []                 // 组的首次出现顺序
        var byKey: [String: LyricQueryGroup] = [:]
        for r in rounds {
            let key = r.reason + "\u{1F}" + r.sources.joined(separator: ",")
            // 曲名全程没变时组内不带曲名(顶上已经说过一次);变过就每条都带上,不丢信息。
            let pair = LyricQueryPair(artist: r.artist, title: shared == nil ? r.title : "")
            if var g = byKey[key] {
                // 组内去重:同一组里同一条查询词重复出现没有信息量(collector 侧的相邻去重
                // 只挡得住**相邻**的重复,跨轮撞上的挡不住)。
                guard !g.queries.contains(pair) else { continue }
                g = LyricQueryGroup(reason: g.reason, sources: g.sources, queries: g.queries + [pair])
                byKey[key] = g
            } else {
                order.append(key)
                byKey[key] = LyricQueryGroup(reason: r.reason, sources: r.sources, queries: [pair])
            }
        }
        return LyricQueryDigest(sharedTitle: shared,
                                groups: order.compactMap { byKey[$0] },
                                total: rounds.count)
    }
}
