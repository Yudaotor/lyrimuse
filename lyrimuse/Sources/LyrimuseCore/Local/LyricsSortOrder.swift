import Foundation

/// 「歌词管理」列表排序的**纯逻辑**部分。
///
/// 为什么放在 LyrimuseCore 而不是留在 `LyricsManagerView.swift`:比较器原来是那个文件里
/// 一个 `private enum` 的方法,`lyrimuse-selftest` 只依赖 LyrimuseCore、够不到它,于是这套
/// 规则(哪一档优先、平局怎么断、缺失值排哪儿)一直没有任何自动化覆盖 —— 2026-09-02 用户
/// 报「排序有时候选了不生效」,查下来正是这类"逻辑对但在某些数据形状下退化成静默无操作"
/// 的问题,靠肉眼看列表发现不了。搬到 Core 之后跟 `EnrichCacheKeys` 同一个待遇:视图层只
/// 负责把 Summary 映射成 `LyricsSortKey`,规则本身可被 selftest 逐档钉住。
///
/// 视图层的展示枚举(带中文 rawValue 的那个 `LyricsSortOption`)不搬,它绑着 Picker、
/// 属于 UI;它只把自己翻译成这里的 `LyricsSortOrder`。
/// 排序需要看的全部字段。视图层从 `EnrichCacheStore.Summary` 一次性映射出来,之后比较器
/// 只做廉价的字符串/日期比较(Summary 里那几个 norm* 字段本来就是为这个预算好的)。
public struct LyricsSortKey: Sendable, Equatable {
    /// toSimplified(primaryArtist(展示歌手名)).lowercased() —— 归一化过的歌手键。
    /// 用它而不是展示字符串,是为了让同一位歌手因为原始标签繁简/大小写不同被拆成两条
    /// 记录时仍然挨在一起(见 Summary.displayArtist 的注释)。
    public let normPrimaryArtist: String
    /// toSimplified(album).lowercased()。
    public let normAlbum: String
    /// 原始曲名,只用来断最后的平局(不参与升降序反转)。
    public let title: String
    /// 曲名的小写副本,「歌名 A→Z/Z→A」比的是它。
    public let searchTitleLower: String
    /// 来源的**展示名**(已本地化,如"网易云音乐"),由视图层算好传进来。
    public let sourceDisplayName: String
    /// 这条有没有歌词来源(`lyrics_source` 非空)。跟 sourceDisplayName 分开存,是因为
    /// 空来源的展示名是「无来源」这样一个正常字符串,单看它分不出"这是一个来源"还是
    /// "这条没有来源"。
    public let hasSource: Bool
    /// 歌词内容上次真的变过是什么时候(导出歌词文件的 mtime);nil = 磁盘上没有这条的
    /// 歌词文件。详见 `EnrichCacheStore.Summary.lyricsUpdatedAt`。
    public let lyricsUpdatedAt: Date?
    /// 这条记录上次被解析出来的时刻(缓存里的 `ts`)。**只作次级键**,见
    /// `LyricsSortOrder` 里 updated/source 两档的注释。
    public let resolvedAt: Date?

    public init(
        normPrimaryArtist: String,
        normAlbum: String,
        title: String,
        searchTitleLower: String,
        sourceDisplayName: String,
        hasSource: Bool,
        lyricsUpdatedAt: Date?,
        resolvedAt: Date?
    ) {
        self.normPrimaryArtist = normPrimaryArtist
        self.normAlbum = normAlbum
        self.title = title
        self.searchTitleLower = searchTitleLower
        self.sourceDisplayName = sourceDisplayName
        self.hasSource = hasSource
        self.lyricsUpdatedAt = lyricsUpdatedAt
        self.resolvedAt = resolvedAt
    }
}

/// 排序方式。只有"点名的那个字段"会因升/降序反转,没点名的次序键恒按升序断平局——跟
/// Finder"按修改时间降序"仍然按文件名升序断平局是同一个道理,不是把整条元组一起倒过来
/// (那样会连带把断平局的顺序也搅乱,观感上像是"随机")。
public enum LyricsSortOrder: Sendable, Equatable {
    case defaultOrder
    case title(ascending: Bool)
    case artist(ascending: Bool)
    case album(ascending: Bool)
    case source(ascending: Bool)
    case updated(ascending: Bool)

    /// 严格弱序比较器。
    public func less(_ a: LyricsSortKey, _ b: LyricsSortKey) -> Bool {
        switch self {
        case .defaultOrder:
            break

        case .title(let ascending):
            if a.searchTitleLower != b.searchTitleLower {
                return ascending
                    ? a.searchTitleLower < b.searchTitleLower
                    : a.searchTitleLower > b.searchTitleLower
            }

        case .artist(let ascending):
            if a.normPrimaryArtist != b.normPrimaryArtist {
                return ascending
                    ? a.normPrimaryArtist < b.normPrimaryArtist
                    : a.normPrimaryArtist > b.normPrimaryArtist
            }

        case .album(let ascending):
            if a.normAlbum != b.normAlbum {
                return ascending ? a.normAlbum < b.normAlbum : a.normAlbum > b.normAlbum
            }

        case .source(let ascending):
            // ⚠️ 无来源的行**两个方向都排最后**,不是按「无来源」这个展示名参与字母序。
            // 跟下面 updated 档对"没有时间戳"的处置同一个取舍:用户按来源排是想看
            // "哪些来自网易云 / 哪些来自 QQ",一串没有来源的行占住列表开头对这个问题
            // 没有任何回答。
            switch (a.hasSource, b.hasSource) {
            case (true, false):
                return true
            case (false, true):
                return false
            case (true, true):
                if a.sourceDisplayName != b.sourceDisplayName {
                    return ascending
                        ? a.sourceDisplayName < b.sourceDisplayName
                        : a.sourceDisplayName > b.sourceDisplayName
                }
            case (false, false):
                // 都没有来源 → 同一个尾块。块内改按"上次被解析的时刻"排,而不是退回歌手
                // 字母序 —— 否则一旦当前视图里全是无来源的行(「仅无歌词」筛选就是这种
                // 形状:2026-09-02 实测本机 14 条命中,`lyrics_source` 全为空),这一档
                // 排序会**整体退化成默认排序**,用户看到的就是"选了没反应"。
                if let r = Self.compareOptional(a.resolvedAt, b.resolvedAt, ascending: ascending) {
                    return r
                }
            }

        case .updated(let ascending):
            switch (a.lyricsUpdatedAt, b.lyricsUpdatedAt) {
            case (nil, nil):
                // 都没有歌词文件 → 同一个尾块,块内按 resolvedAt 排(理由同 source 档)。
                // 这批行按定义永远拿不到 mtime(export 会跳过没歌词的条目),所以块内
                // 不给一个别的时间键的话,这一档对它们**永远**是空操作。
                if let r = Self.compareOptional(a.resolvedAt, b.resolvedAt, ascending: ascending) {
                    return r
                }
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (x?, y?):
                // 没有歌词文件的行**两个方向都排最后**,不是当成"最早"。"旧→新"里把它们
                // 塞到最前面在技术上说得通(未知≈很久以前),但用户按更新时间排是想看
                // "最近动过什么 / 最久没动过什么",一串没歌词的空行占住列表开头对这两个
                // 问题都没有回答。跟 Finder 把无日期项收在末尾同一个取舍。
                if x != y { return ascending ? x < y : x > y }
            }
        }
        return Self.fallbackLess(a, b)
    }

    /// 可空日期的比较:两边都有且不等 → 按方向比;缺失的一律排最后(**两个方向都一样**,
    /// 跟"没有歌词文件的行排最后"同一条理由)。返回 nil = 这一档分不出胜负,交给下一档。
    static func compareOptional(_ a: Date?, _ b: Date?, ascending: Bool) -> Bool? {
        switch (a, b) {
        case (nil, nil):
            return nil
        case (nil, _):
            return false
        case (_, nil):
            return true
        case let (x?, y?):
            if x == y { return nil }
            return ascending ? x < y : x > y
        }
    }

    /// 最后一档平局:恒按 (歌手, 专辑, 歌名) 升序,不随点名字段的升降序反转。
    static func fallbackLess(_ a: LyricsSortKey, _ b: LyricsSortKey) -> Bool {
        (a.normPrimaryArtist, a.normAlbum, a.title)
            < (b.normPrimaryArtist, b.normAlbum, b.title)
    }
}
