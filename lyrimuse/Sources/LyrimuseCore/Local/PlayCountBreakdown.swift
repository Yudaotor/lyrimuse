import Foundation

/// 「第 N 次听」点开后的合并明细(2026-09-04):这一族由哪几种写法(= 几个 Last.fm 条目)凑成、
/// 各自几次、合并后逐次的时刻。纯数据 + 纯函数,网络取数在 App 侧(PlayCountBreakdownLoader,
/// 每种写法各查 `user.getTrackScrobbles`——那个接口按精确写法匹配,天然一桶一种写法)。
///
/// 为什么不直接用行上的数:行上的 N 来自 `track.getinfo autocorrect=1` 按写法族求和
/// (LastfmStatsService.resolvePlayCounts),中间过程(哪几种写法、各多少)算完就丢了;而这个
/// 弹框的目的恰恰是把过程摊开给用户核对。两条路径算出的合计不相等时界面直接标出来 ——
/// 那正是「Last.fm 自己 autocorrect 并了一种我们折叠规则没认的写法」或反过来的信号。
public struct PlayCountBreakdown: Equatable {
    public struct Variant: Equatable, Identifiable {
        public let artist: String
        public let title: String
        /// Last.fm 报的这一写法的总 scrobble 数(`@attr.total`)。取数失败时为 0 且 `failed = true`。
        public let total: Int
        /// 是不是用户点的那一行自己的写法(本尊)。
        public let isSelf: Bool
        public let reasons: [PlayCountFoldReason]
        /// 已经拉到本地的条数。分页,每页最多 200。
        public let loaded: Int
        /// 这一写法一次都没取到(网络失败)。它的 total 未知,合计里不算它,编号也整体停掉
        /// (见 `ordinalCutoff`)—— 宁可不编号,不编错号。
        public let failed: Bool

        public var id: String { artist.lowercased() + "|" + title.lowercased() }
        /// 全部拉完了(取数失败的永远算没拉完)。
        public var exhausted: Bool { !failed && loaded >= total }
        public init(artist: String, title: String, total: Int, isSelf: Bool,
                    reasons: [PlayCountFoldReason], loaded: Int, failed: Bool) {
            self.artist = artist
            self.title = title
            self.total = total
            self.isSelf = isSelf
            self.reasons = reasons
            self.loaded = loaded
            self.failed = failed
        }
    }

    public struct Play: Equatable, Identifiable {
        public let date: Date
        /// 属于 `variants` 里第几种写法。
        public let variantIndex: Int
        public let album: String?
        /// 同一写法、同一时刻的第几条(双端同时 scrobble 那种罕见重复,几乎恒为 0)。
        public let dup: Int
        public var id: String { "\(date.timeIntervalSince1970)|\(variantIndex)|\(dup)" }

        public init(date: Date, variantIndex: Int, album: String?, dup: Int) {
            self.date = date
            self.variantIndex = variantIndex
            self.album = album
            self.dup = dup
        }
    }

    /// 本尊在前,其余按 App 侧给的顺序(写法索引里的真实写法)。
    public let variants: [Variant]
    /// 全部写法的 scrobble 合在一起按时间**倒序**(最新在前);不去重,理由见 PlayCountBreakdownMath.build。
    public let plays: [Play]
    /// 编号只对这一刻(含)之后的行有效:某写法还没拉完时,比它已拉到的最旧一条更早的位置无法
    /// 确定「第几次」(那中间可能还有它没拉到的收听)。nil = 全部拉完,每一行都能编号。
    public let ordinalCutoff: Date?

    /// 各写法次数之和 —— 跟行上的 N 对账用。
    public var total: Int { variants.reduce(0) { $0 + $1.total } }
    public var canLoadOlder: Bool { variants.contains { !$0.failed && !$0.exhausted } }
    public var hasFailure: Bool { variants.contains { $0.failed } }

    /// 同一种写法(= 同一个 Last.fm 条目)下,已拉到的记录按**专辑名**分组(2026-09-04 用户指出:
    /// 《晴天》23 次里一半挂「葉惠美」一半挂「叶惠美」,这也是一种"写法不同",清单里得看得见)。
    /// 专辑不进 Last.fm 的曲目身份、也不进我们的折叠键,所以它只能从逐条记录里数出来 —— 数的是
    /// **已拉到的**那些:写法拉完时就是真实分布,没拉完时是下界(界面据 `exhausted` 决定标不标
    /// "至少")。按条数降序、同数按专辑名,结果确定。没有专辑名的记录归成 `album == nil` 一组。
    public struct AlbumGroup: Equatable {
        public let album: String?
        public let count: Int
        public init(album: String?, count: Int) {
            self.album = album
            self.count = count
        }
    }

    public func albumGroups(variantIndex: Int) -> [AlbumGroup] {
        var counts: [String?: Int] = [:]
        for p in plays where p.variantIndex == variantIndex {
            let key = p.album?.trimmingCharacters(in: .whitespaces)
            counts[key.flatMap { $0.isEmpty ? nil : $0 }, default: 0] += 1
        }
        return counts.map { AlbumGroup(album: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return ($0.album ?? "") < ($1.album ?? "")
            }
    }

    /// 每一行是「第几次」,与 `plays` 等长;编不出来(在 cutoff 之前、或算出 ≤ 0)的位置为 nil。
    /// 列表倒序,所以第 i 行(0 起)= 合计 − i。
    public var ordinals: [Int?] {
        let total = total
        return plays.enumerated().map { i, p in
            if let cutoff = ordinalCutoff, p.date < cutoff { return nil }
            let n = total - i
            return n > 0 ? n : nil
        }
    }

    public init(variants: [Variant], plays: [Play], ordinalCutoff: Date?) {
        self.variants = variants
        self.plays = plays
        self.ordinalCutoff = ordinalCutoff
    }
}

public enum PlayCountBreakdownMath {
    /// App 侧喂进来的一种写法:身份 + Last.fm 报的总数 + 已拉到的那些条。
    public struct VariantInput {
        public var artist: String
        public var title: String
        public var total: Int
        public var isSelf: Bool
        public var reasons: [PlayCountFoldReason]
        public var plays: [(date: Date, album: String?)]
        public var failed: Bool

        public init(artist: String, title: String, total: Int, isSelf: Bool,
                    reasons: [PlayCountFoldReason], plays: [(date: Date, album: String?)],
                    failed: Bool = false) {
            self.artist = artist
            self.title = title
            self.total = total
            self.isSelf = isSelf
            self.reasons = reasons
            self.plays = plays
            self.failed = failed
        }
    }

    /// 把各写法的分页结果合成一份明细。
    ///
    /// **每条 scrobble 都原样保留,不做跨写法"同一时刻去重"**(2026-09-05 撤掉)。第一版假设"同一秒同一
    /// 个账号只可能有一条 scrobble",把后一种写法里与前一种写法同秒的条当作 Last.fm 大小写不敏感返回的
    /// 同一条剔掉——用户点开卢广仲《Boring》后对账那行报「行上按 18 次计,明细合计 16 次」,查 Last.fm
    /// 网页坐实那个假设不成立:`卢广仲|Boring` 13 条、`Crowd Lu|Boring` 5 条,其中 4 对**同一分钟**——
    /// 是同一次收听被两台设备各 scrobble 了一次(Mac 报中文名,iPhone 侧 FastScrobbler 报罗马字名),
    /// 在 Last.fm 上是 18 条真实存在、各自计数的记录,行上的 18 也正是这么加出来的。去重等于替 Last.fm
    /// 改账,还制造了一个假的"两边不一致"。现在明细如实列出:同秒两条并排、色点不同,用户一眼能看出
    /// 是双端重复。同一写法内部同一时刻的多条用 `Play.dup` 区分身份。
    public static func build(_ inputs: [VariantInput]) -> PlayCountBreakdown {
        var variants: [PlayCountBreakdown.Variant] = []
        var plays: [PlayCountBreakdown.Play] = []
        // 编号截止:没拉完的写法里,已拉到的最旧一条;取各写法里**最晚**的那个(任何一个没拉完
        // 的写法都可能在它自己的截止之前藏着没拉到的条)。有写法一条都没拉到(失败)→ 整体不编号。
        var cutoff: Date?
        for (index, input) in inputs.enumerated() {
            var dupCount: [TimeInterval: Int] = [:]
            for p in input.plays {
                let uts = p.date.timeIntervalSince1970
                let dup = dupCount[uts, default: 0]
                dupCount[uts] = dup + 1
                plays.append(.init(date: p.date, variantIndex: index, album: p.album, dup: dup))
            }
            let variant = PlayCountBreakdown.Variant(
                artist: input.artist, title: input.title, total: input.total, isSelf: input.isSelf,
                reasons: input.reasons, loaded: input.plays.count, failed: input.failed)
            variants.append(variant)
            if !variant.exhausted {
                let oldestLoaded = input.plays.map(\.date).min() ?? Date.distantFuture
                cutoff = max(cutoff ?? .distantPast, oldestLoaded)
            }
        }
        // 倒序;同一时刻按写法顺序(本尊在前)再按 dup,结果确定、不依赖输入顺序。
        plays.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.variantIndex != $1.variantIndex { return $0.variantIndex < $1.variantIndex }
            return $0.dup < $1.dup
        }
        return PlayCountBreakdown(variants: variants, plays: plays, ordinalCutoff: cutoff)
    }
}
