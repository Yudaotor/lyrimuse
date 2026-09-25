import AppKit
import Combine
import LyrimuseCore
import OSLog
import SwiftUI

/// 专辑简介 / 歌手简介的一张卡片:标题 + 副标题 + 若干「标签:值」+ 正文。
struct EditorialCard: Equatable {
    enum Kind: Equatable { case album, artist }

    struct Fact: Equatable, Hashable {
        let label: String
        let value: String
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let facts: [Fact]
    let text: String
}

/// 当前曲目的 Apple Music 专辑简介与歌手简介(灵动岛展开态点专辑名 / 歌手名、歌词窗口点「歌手 — 专辑」
/// 那一行的两段、「⋯ › 显示专辑简介 / 显示歌手简介」)。
///
/// 入口**只在有简介时可点**,所以要在点之前就知道:有消费方挂着(`retain`)时,每次换歌(停稳 0.6s 后)预取。
///   - 专辑:专辑 ID 取自 enrich 缓存里的 `apple_music_url`,请求专辑公开页一次,同时拿到简介和署名歌手。先问
///     系统地区的店面,404 再问链接自带的店面(`AlbumEditorialNotes.storefronts`);
///   - 歌手:从署名里挑出这首歌的歌手(`AlbumEditorialNotes.pickArtist`);这首自己的专辑页给不出时,从同歌手在
///     缓存里的别的专辑页找,按专辑 ID 升序最多试 3 张,对上一张就停。再按给出专辑页的那个店面请求歌手公开页
///     拿简介;出生日期 / 类型只有 Apple Music API 给,collector 缓存的 developer token 有效时顺带取,没有就不显示那两行。
/// 专辑按专辑 ID、歌手按歌手 ID 记住结果,同一个只取一次;所有店面都 404 记成「没有」,本次运行不再问;
/// 网络失败 / 页面形状不对不记,下次换歌 / 消费方再来时重试。同一张专辑 / 同一位歌手在飞时不重复发,
/// 请求回来时已经换歌,就按此刻在放的曲目再查一次(命中刚记下的结果,不多发请求)。
/// 没有消费方时一个请求都不发。
@MainActor
final class EditorialNotesStore: ObservableObject {
    static let shared = EditorialNotesStore()
    /// 真正发请求、拿到结论时各一行 notice;缓存命中与跳过走 debug,展开灵动岛不落盘。
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "editorial")

    /// 当前曲目的专辑 / 歌手简介。nil = 没有 / 还没取到;入口可不可点只看它。
    @Published private(set) var album: EditorialCard?
    @Published private(set) var artist: EditorialCard?

    func card(_ kind: EditorialCard.Kind) -> EditorialCard? {
        kind == .album ? album : artist
    }

    /// 取到的专辑页与给出它的店面。
    private struct FetchedAlbum {
        let page: AlbumEditorialNotes.AlbumPage
        let storefront: String
    }

    /// 兜底找到的歌手与该问哪个店面。
    private struct ResolvedArtist {
        let link: AlbumEditorialNotes.ArtistLink
        let storefront: String
    }

    /// 值为 nil = 所有店面都 404,这张专辑没有公开页。
    private var albumPages: [Int64: FetchedAlbum?] = [:]
    /// 值为 nil = 查过了,这位歌手没有简介。
    private var artistCards: [Int64: EditorialCard?] = [:]
    /// 按歌手名(`cleanTag`)记住兜底找到的歌手;值为 nil = 找过了,找不到。
    private var artistLinks: [String: ResolvedArtist?] = [:]
    private var albumsInFlight: Set<Int64> = []
    private var artistsInFlight: Set<Int64> = []
    private var demand = 0
    /// 最近一次要的是哪首歌。换歌后晚到的结果按它判断:不直接用,改按当前曲目重查。
    private var currentKey = ""
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let p = PlaybackCoordinator.shared
        let track = Publishers.CombineLatest3(p.$artist, p.$title, p.$album)
            .map { Track(artist: $0, title: $1, album: $2) }
            .removeDuplicates()
        // 换歌那一刻先撤掉上一首的简介,入口立即变回不可点;预取等曲目停稳再发。
        // sink 只用参数值:@Published 在 willSet 时机发布,回读 PlaybackCoordinator 拿到的是旧值。
        track
            .sink { [weak self] t in
                guard let self, t.key != self.currentKey else { return }
                self.currentKey = t.key
                self.album = nil
                self.artist = nil
            }
            .store(in: &cancellables)
        track
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] t in self?.refresh(t) }
            .store(in: &cancellables)
        // enrich 缓存换了内容(启动后第一次加载完、collector 给这首补上了 apple_music_url):按新内容重查一次,
        // 之前因为「还没有」记下的找不到作废。
        LocalPlaybackSource.shared.$enrichContentVersion
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.artistLinks = self.artistLinks.filter { $0.value != nil }
                self.refreshCurrent()
            }
            .store(in: &cancellables)
    }

    /// 消费方开始需要简介(灵动岛开着「显示专辑 / 歌手」、歌词窗口出现)。与 `release` 成对。
    func retain() {
        demand += 1
        refreshCurrent()
    }

    func release() {
        demand = max(0, demand - 1)
    }

    /// 按此刻在放的曲目重查一次(缓存命中是 µs 级)。消费方在「要用了」的时刻叫:灵动岛展开、「⋯」菜单打开 ——
    /// 换歌时 enrich 里还没有 `apple_music_url` 的曲目,collector 补上之后靠这一下变可点。
    func refreshCurrent() {
        let p = PlaybackCoordinator.shared
        refresh(Track(artist: p.artist, title: p.title, album: p.album))
    }

    private func refresh(_ track: Track) {
        guard demand > 0, !track.title.isEmpty else {
            Self.logger.debug("refresh skipped: demand \(self.demand, privacy: .public) title empty \(track.title.isEmpty, privacy: .public)")
            return
        }
        currentKey = track.key
        // enrich 缓存在主线程读(同歌词窗口「⋯」菜单的平台链接):缓存加载好之后是 µs 级。
        guard let ref = EnrichCacheReader.appleAlbumRef(artist: track.artist, title: track.title,
                                                        album: track.album) else {
            Self.logger.debug("no apple album for current track; artist via siblings")
            album = nil
            resolveArtistFromSiblings(track)
            return
        }
        withAlbumPage(ref) { [weak self] fetched in
            guard let self else { return }
            guard self.currentKey == track.key else { return self.refreshCurrent() }
            self.album = fetched?.page.notes.map {
                EditorialCard(kind: .album, title: $0.title.isEmpty ? track.album : $0.title,
                              subtitle: $0.subtitle, facts: [], text: $0.text)
            }
            if let fetched, let link = AlbumEditorialNotes.pickArtist(fetched.page.artists, localArtist: track.artist) {
                self.loadArtist(ResolvedArtist(link: link, storefront: fetched.storefront), for: track)
            } else {
                self.resolveArtistFromSiblings(track)
            }
        }
    }

    /// 这首歌自己的专辑页给不出歌手(没有 apple_music_url,或署名对不上)时:从同歌手在缓存里的别的专辑页
    /// 拿歌手 ID(`EnrichCacheReader.appleAlbumRefs(forArtist:)`)。按歌手记住结论,同一位只找一次。
    private func resolveArtistFromSiblings(_ track: Track) {
        let name = EnrichCacheKeys.cleanTag(track.artist)
        guard !name.isEmpty else {
            artist = nil
            return
        }
        if let known = artistLinks[name] {
            if let known { loadArtist(known, for: track) } else { artist = nil }
            return
        }
        // 缓存还没加载好:这次先不显示,也不记成找不到(加载完会经 enrichContentVersion 再来)。
        guard let refs = EnrichCacheReader.appleAlbumRefs(forArtist: track.artist, limit: 3) else {
            Self.logger.debug("siblings: enrich cache not loaded yet")
            artist = nil
            return
        }
        trySiblings(refs[...], name: name, track: track)
    }

    /// 依次问同歌手的别的专辑页,署名里对上这位歌手就停;都对不上(或都没有公开页)才记成找不到。
    /// 中途请求失败 / 在飞:不记,链条就此停下,下次再来。
    private func trySiblings(_ refs: ArraySlice<AlbumEditorialNotes.AlbumRef>, name: String, track: Track) {
        guard let ref = refs.first else {
            Self.logger.debug("siblings: no album credits this artist")
            artistLinks[name] = .some(nil)
            if currentKey == track.key { artist = nil }
            return
        }
        withAlbumPage(ref) { [weak self] fetched in
            guard let self else { return }
            guard let fetched, let link = AlbumEditorialNotes.pickArtist(fetched.page.artists, localArtist: track.artist) else {
                return self.trySiblings(refs.dropFirst(), name: name, track: track)
            }
            let resolved = ResolvedArtist(link: link, storefront: fetched.storefront)
            self.artistLinks[name] = resolved
            guard self.currentKey == track.key else { return self.refreshCurrent() }
            self.loadArtist(resolved, for: track)
        }
    }

    /// 专辑页:记过结论(取到 / 没有)就地回调;没有就请求一次,取到或确认没有时回调。
    /// 同一张在飞时不重复发、这次不回调 —— 在飞的那一次回来时若已换歌,它的回调会按当前曲目重查。
    private func withAlbumPage(_ ref: AlbumEditorialNotes.AlbumRef, _ body: @escaping (FetchedAlbum?) -> Void) {
        if let known = albumPages[ref.id] {
            body(known)
            return
        }
        guard !albumsInFlight.contains(ref.id) else { return }
        albumsInFlight.insert(ref.id)
        let storefronts = AlbumEditorialNotes.storefronts(region: Self.region, linkStorefront: ref.storefront)
        Self.logger.notice("fetch album \(ref.id, privacy: .public) storefronts \(storefronts.joined(separator: ","), privacy: .public)")
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await AlbumEditorialNotes.fetchAlbumPage(albumID: ref.id, storefronts: storefronts)
            }.value
            guard let self else { return }
            self.albumsInFlight.remove(ref.id)
            let fetched: FetchedAlbum?
            switch result {
            case .found(let page, let storefront):
                fetched = FetchedAlbum(page: page, storefront: storefront)
            case .missing:
                Self.logger.notice("album \(ref.id, privacy: .public) has no page in \(storefronts.joined(separator: ","), privacy: .public)")
                fetched = nil
            case .failed:
                return
            }
            self.albumPages[ref.id] = .some(fetched)
            body(fetched)
        }
    }

    private func loadArtist(_ resolved: ResolvedArtist, for track: Track) {
        let link = resolved.link
        if let cached = artistCards[link.id] {
            artist = cached
            return
        }
        guard !artistsInFlight.contains(link.id) else { return }
        artistsInFlight.insert(link.id)
        let storefront = resolved.storefront
        let token = AppleMusicDeveloperToken.cached()
        Self.logger.notice("fetch artist \(link.id, privacy: .public) storefront \(storefront, privacy: .public)")
        Task { [weak self] in
            async let bio = Self.fetchBio(artistID: link.id, storefront: storefront)
            async let facts = Self.fetchFacts(artistID: link.id, storefront: storefront, token: token)
            let (text, extra) = await (bio, facts)
            guard let self else { return }
            self.artistsInFlight.remove(link.id)
            // 歌手页没取成:不记,下次再试。取成了但没有简介(含这个店面没有这位歌手的页面):记成 nil。
            guard let text else { return }
            let card = text.isEmpty ? nil : Self.artistCard(name: link.name, bio: text, facts: extra)
            self.artistCards[link.id] = card
            if self.currentKey == track.key { self.artist = card } else { self.refreshCurrent() }
        }
    }

    nonisolated private static func fetchBio(artistID: Int64, storefront: String) async -> String? {
        await AlbumEditorialNotes.fetchArtistBio(artistID: artistID, storefront: storefront)
    }

    nonisolated private static func fetchFacts(artistID: Int64, storefront: String,
                                               token: String?) async -> AlbumEditorialNotes.ArtistFacts? {
        guard let token else { return nil }
        return await AlbumEditorialNotes.fetchArtistFacts(artistID: artistID, storefront: storefront, token: token)
    }

    private static func artistCard(name: String, bio: String,
                                   facts: AlbumEditorialNotes.ArtistFacts?) -> EditorialCard {
        var rows: [EditorialCard.Fact] = []
        if let facts {
            if let born = facts.bornOrFormed {
                rows.append(.init(label: L10n.t(facts.isGroup ? "成立时间" : "出生日期"), value: born))
            }
            if !facts.genres.isEmpty {
                rows.append(.init(label: L10n.t("类型"), value: facts.genres.joined(separator: " · ")))
            }
        }
        return EditorialCard(kind: .artist, title: name, subtitle: "", facts: rows, text: bio)
    }

    /// 系统地区,跟「前往专辑」同一口径。店面的最终顺序见 `AlbumEditorialNotes.storefronts`。
    private static var region: String? { Locale.current.region?.identifier }

    private struct Track: Equatable {
        let artist: String
        let title: String
        let album: String
        var key: String { "\(artist)\u{1F}\(title)\u{1F}\(album)" }
    }
}

/// 一张简介卡片的内容:标题 + 副标题 + 「标签:值」几行 + 正文(可选中复制)。灵动岛浮框与歌词窗口面板共用,
/// 背景与外框由宿主各自加。
struct EditorialNotesContent: View {
    let card: EditorialCard
    let primary: Color
    let secondary: Color
    var maxTextHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primary)
                    .lineLimit(2)
                if !card.subtitle.isEmpty {
                    Text(card.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
            if !card.facts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.facts, id: \.self) { fact in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(secondary)
                            Text(fact.value)
                                .font(.system(size: 12))
                                .foregroundStyle(primary)
                        }
                    }
                }
            }
            // 高度要确定:灵动岛浮框按 fittingSize 量高,`ScrollView` + `maxHeight` 在那里量出来会被压扁。
            // 所以不长就整段排,长了才放进固定高度的滚动区。
            if card.text.count > Self.scrollThreshold {
                ScrollView(.vertical, showsIndicators: false) { paragraph(card.text) }
                    .frame(height: maxTextHeight)
            } else {
                paragraph(card.text)
            }
        }
    }

    /// 超过这么多字才滚动。400 字在 320pt 宽、12pt 字下约 16 行,再长就会顶出屏幕下沿。
    private static let scrollThreshold = 400

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(primary.opacity(0.9))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
