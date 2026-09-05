import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lastfm-breakdown")

/// 「第 N 次听」合并明细的取数(2026-09-04)。一个弹框一个实例,弹出时建、关掉即弃,不缓存 ——
/// 这是用户主动点开的一次性核对,每次都该看到 Last.fm 此刻的账,而不是上次点开时的快照。
///
/// 取法:`LastfmStatsService.playCountFamily` 给出本尊 + 查次数时真正问过的那批孪生写法,每种
/// 写法各查一页 `user.getTrackScrobbles`(limit 200,并发,走同一个限速队列、interactive 优先级),
/// 合成 `PlayCountBreakdown`。绝大多数歌一轮就拉完;几百次的歌由「加载更早的」按写法逐页补。
///
/// 取数**失败**的写法不静默丢:那会让「合并了哪些」这个清单缺一项而用户毫无察觉 —— 正好违背这个
/// 弹框的目的。失败的写法留在清单里标出来,合计不算它,编号整体停掉(见 PlayCountBreakdown.Variant.failed)。
/// 请求成功但 `total == 0` 的写法才是真的「不存在」(索引未建成时退回的猜枚举会有这种),不显示。
@MainActor
final class PlayCountBreakdownLoader: ObservableObject {
    enum State: Equatable { case loading, loaded, failed }

    static let pageSize = 200

    let artist: String
    let title: String

    @Published private(set) var state: State = .loading
    @Published private(set) var breakdown: PlayCountBreakdown?
    @Published private(set) var loadingOlder = false

    /// 各写法的累积输入(跨「加载更早的」几轮),`build` 每次从这里整份重算。
    private var inputs: [PlayCountBreakdownMath.VariantInput] = []
    /// 各写法已拉到第几页(0 = 还没拉过/失败)。
    private var pagesFetched: [Int] = []

    init(artist: String, title: String) {
        self.artist = artist
        self.title = title
    }

    func load() async {
        state = .loading
        let family = LastfmStatsService.shared.playCountFamily(artist: artist, title: title)
        let base = family[0]
        // 并发拉每种写法的第一页。结果按 index 归位,顺序不依赖谁先回来。
        var pages = [LastfmStatsService.TrackScrobblesPage?](repeating: nil, count: family.count)
        await withTaskGroup(of: (Int, LastfmStatsService.TrackScrobblesPage?).self) { group in
            for (i, member) in family.enumerated() {
                group.addTask { @MainActor in
                    (i, await LastfmStatsService.shared.fetchTrackScrobbles(
                        artist: member.artist, title: member.title, page: 1, limit: Self.pageSize))
                }
            }
            for await (i, page) in group { pages[i] = page }
        }
        var built: [PlayCountBreakdownMath.VariantInput] = []
        var fetched: [Int] = []
        for (i, member) in family.enumerated() {
            let isSelf = i == 0
            guard let page = pages[i] else {
                // 本尊都没拿到 → 整个弹框失败态(没有主体可展示);孪生失败 → 留一行标出来。
                if isSelf {
                    logger.error("breakdown: self fetch failed for \(member.artist, privacy: .public) - \(member.title, privacy: .public)")
                    state = .failed
                    return
                }
                built.append(.init(artist: member.artist, title: member.title, total: 0, isSelf: false,
                                   reasons: PlayCountFoldExplainer.reasons(base: base, variant: member),
                                   plays: [], failed: true))
                fetched.append(0)
                continue
            }
            // 真的没有这个条目(猜枚举里不存在的写法)—— 不是合并进来的东西,不列。本尊 0 次也照列:
            // 用户点的就是它,空着比消失好懂。
            if !isSelf && page.total == 0 { continue }
            built.append(.init(artist: member.artist, title: member.title, total: page.total, isSelf: isSelf,
                               reasons: isSelf ? [] : PlayCountFoldExplainer.reasons(base: base, variant: member),
                               plays: page.plays))
            fetched.append(1)
        }
        inputs = built
        pagesFetched = fetched
        breakdown = PlayCountBreakdownMath.build(inputs)
        state = .loaded
        logger.notice("breakdown: \(base.artist, privacy: .public) - \(base.title, privacy: .public) → \(built.count, privacy: .public) variants, \(self.breakdown?.plays.count ?? 0, privacy: .public) plays loaded, total \(self.breakdown?.total ?? 0, privacy: .public)")
    }

    /// 给每个还没拉完的写法再拉一页。串行、按写法顺序 —— 这是用户点了才发生的补页,不值得并发。
    func loadOlder() async {
        guard !loadingOlder, let current = breakdown, current.canLoadOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        for (i, variant) in current.variants.enumerated() where !variant.failed && !variant.exhausted {
            let next = pagesFetched[i] + 1
            guard let page = await LastfmStatsService.shared.fetchTrackScrobbles(
                artist: variant.artist, title: variant.title, page: next, limit: Self.pageSize)
            else { continue } // 这一页没拿到:原地不动,下次再点再试;不把这一写法标成 failed
            inputs[i].plays.append(contentsOf: page.plays)
            // total 以最新一页为准(期间可能又 scrobble 了一次)。
            inputs[i].total = page.total
            pagesFetched[i] = next
        }
        breakdown = PlayCountBreakdownMath.build(inputs)
    }
}
