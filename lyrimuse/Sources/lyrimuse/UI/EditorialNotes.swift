import AppKit
import Combine
import LyrimuseCore
import OSLog
import SwiftUI

/// 专辑简介 / 歌手简介 / 歌曲简介的一张卡片:标题 + 副标题 + 若干「标签:值」+ 正文。
struct EditorialCard: Equatable {
    enum Kind: Equatable {
        case album, artist, song

        /// 能点开这一类简介的那段文字给辅助功能的提示。
        var openHint: String {
            switch self {
            case .album: return L10n.t("查看专辑简介")
            case .artist: return L10n.t("查看歌手简介")
            case .song: return L10n.t("查看歌曲简介")
            }
        }
    }

    /// 正文从哪来。Last.fm 的是 CC BY-SA 授权的用户百科,YouTube Music 给的是维基百科条目(同样 CC BY-SA),网易云、QQ 音乐、
    /// 汽水音乐的是它们家的介绍,这几种卡片底部都注明出处。
    enum Source: Equatable {
        case appleMusic, lastfm, netease, qqMusic, soda, youtubeMusic

        /// 卡片底部那一行出处;Apple Music 的不注明。YouTube Music 那一路的正文是维基百科的,注明维基百科。
        var attribution: String? {
            switch self {
            case .appleMusic: return nil
            case .lastfm: return L10n.t("来自 Last.fm")
            case .netease: return L10n.t("来自网易云音乐")
            case .qqMusic: return L10n.t("来自 QQ 音乐")
            case .soda: return L10n.t("来自汽水音乐")
            case .youtubeMusic: return L10n.t("来自维基百科")
            }
        }
    }

    struct Fact: Equatable, Hashable {
        let label: String
        let value: String
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let facts: [Fact]
    let text: String
    var source: Source = .appleMusic
}

/// 当前曲目的专辑简介、歌手简介与歌曲简介(灵动岛展开态点歌名 / 专辑名 / 歌手名、歌词窗口点歌名和「歌手 — 专辑」
/// 那一行的两段、「⋯ › 显示歌曲简介 / 显示歌手简介 / 显示专辑简介」)。
///
/// 入口**只在有简介时可点**,所以要在点之前就知道:有消费方挂着(`retain`)时,每次换歌(停稳 0.6s 后)预取。
///   - 专辑:专辑 ID 取自 enrich 缓存里的 `apple_music_url`,请求专辑公开页一次,同时拿到简介和署名歌手。先问
///     系统地区的店面,404 再问链接自带的店面(`AlbumEditorialNotes.storefronts`);
///   - 歌手:从署名里挑出这首歌的歌手(`AlbumEditorialNotes.pickArtist`);这首自己的专辑页给不出时,从同歌手在
///     缓存里的别的专辑页找,按专辑 ID 升序最多试 3 张,对上一张就停。再按给出专辑页的那个店面请求歌手公开页
///     拿简介;出生日期 / 类型只有 Apple Music API 给,引擎缓存的 developer token 有效时顺带取,没有就不显示那两行。
/// **Apple Music 明确没有时退到 Last.fm**(`album.getInfo` 的 wiki / `artist.getInfo` 的 bio,见 `LastfmEditorialInfo`):
/// 只在 Apple 那条路**确定**没有(没有专辑链接 / 公开页没有简介 / 歌手页没有简介 / 同歌手的专辑都对不上)时才问,
/// Apple 请求失败或 enrich 缓存还没加载好不算;要连着 Last.fm 账号(用它的 API key)。按「歌手|专辑」「歌手」记结论。
/// **另有网易云一路**(`NeteaseEditorialInfo`):这首在缓存里的网易云歌曲页 → 歌曲详情里的署名和所在专辑 → 歌手介绍 /
/// 专辑介绍(专辑要跟正在放的对得上)。只在中文界面问(它的介绍只有中文),排在 Last.fm 前面;前一个明确没有才问下一个,
/// 没问成就停在那儿,下次再试。按歌曲 ID、歌手 ID、专辑 ID 记结论。
/// **还有汽水音乐、YouTube Music 两路**:用汽水放过的歌,缓存里有汽水给的专辑 / 歌手 ID,直接取它的介绍(`SodaEditorialInfo`,
/// 只在中文界面问、排在网易云前面);YouTube Music 的专辑 / 歌手介绍是维基百科条目,按界面语言给、没有时退英文
/// (`YouTubeMusicEditorialInfo`),所有界面语言都问,排在 Last.fm 前面。中文界面:汽水 → 网易云 → YouTube Music → Last.fm;
/// 别的界面:YouTube Music → Last.fm。按分享页地址、专辑 ID / 「歌手|专辑」、频道 ID 记结论。
/// **歌曲简介没有 Apple 那一档**(Apple Music 不给单曲写介绍):中文界面先问 QQ 音乐(`QQSongInfo`,这首在缓存里的
/// QQ 歌曲页 → 歌曲详情里的「简介」),再问 Last.fm `track.getInfo`;别的界面只问 Last.fm。按 songmid、「歌手|歌名」记结论。
/// 专辑按专辑 ID、歌手按歌手 ID 记住结果,同一个只取一次;所有店面都 404 记成「没有」,本次运行不再问;
/// 网络失败 / 页面形状不对不记,下次换歌 / 消费方再来时重试。同一张专辑 / 同一位歌手在飞时不重复发,
/// 请求回来时已经换歌,就按此刻在放的曲目再查一次(命中刚记下的结果,不多发请求)。
/// 没有消费方时一个请求都不发。
@MainActor
final class EditorialNotesStore: ObservableObject {
    static let shared = EditorialNotesStore()
    /// 真正发请求、拿到结论时各一行 notice;缓存命中与跳过走 debug,展开灵动岛不落盘。
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "editorial")

    /// 当前曲目的专辑 / 歌手 / 歌曲简介。nil = 没有 / 还没取到;入口可不可点只看它。
    @Published private(set) var album: EditorialCard?
    @Published private(set) var artist: EditorialCard?
    @Published private(set) var song: EditorialCard?

    func card(_ kind: EditorialCard.Kind) -> EditorialCard? {
        switch kind {
        case .album: return album
        case .artist: return artist
        case .song: return song
        }
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
                self.song = nil
            }
            .store(in: &cancellables)
        // 去抖挂主队列、别挂 RunLoop.main:菜单开着时它不走,那时换的歌要等菜单关了才取简介(见 01 章决策 11)。
        track
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] t in self?.refresh(t) }
            .store(in: &cancellables)
        // enrich 缓存换了内容(启动后第一次加载完、引擎给这首补上了 apple_music_url):按新内容重查一次,
        // 之前因为「还没有」记下的找不到作废。
        LocalPlaybackSource.shared.$enrichContentVersion
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
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
    /// 换歌时 enrich 里还没有 `apple_music_url` 的曲目,引擎补上之后靠这一下变可点。
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
        // 歌曲简介没有 Apple 那一档,直接走兜底链(结论都记着,重查时同步命中,不闪)。
        song = nil
        fallback(.song, track)
        // enrich 缓存在主线程读(同歌词窗口「⋯」菜单的平台链接):缓存加载好之后是 µs 级。
        guard let ref = EnrichCacheReader.appleAlbumRef(artist: track.artist, title: track.title,
                                                        album: track.album) else {
            Self.logger.debug("no apple album for current track; artist via siblings")
            album = nil
            fallback(.album, track)
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
            if self.album == nil { self.fallback(.album, track) }
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
            if let known {
                loadArtist(known, for: track)
            } else {
                artist = nil
                fallback(.artist, track)
            }
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
            if currentKey == track.key {
                artist = nil
                fallback(.artist, track)
            }
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
            if cached == nil { fallback(.artist, track) }
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
            guard self.currentKey == track.key else { return self.refreshCurrent() }
            self.artist = card
            if card == nil { self.fallback(.artist, track) }
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

    // MARK: - 兜底(Apple Music 明确没有时)

    /// Apple Music 明确没有这张专辑 / 这位歌手的简介:中文界面依次问汽水、网易云、YouTube Music、Last.fm;别的界面问
    /// YouTube Music、Last.fm(汽水、网易云的介绍只有中文,`NeteaseEditorialInfo.isUsable`;YouTube Music 按界面语言给)。
    /// 歌曲简介没有 Apple 那一档:中文界面先问 QQ 音乐、
    /// 再问 Last.fm;别的界面只问 Last.fm(QQ 的简介同样只有中文)。
    private func fallback(_ kind: EditorialCard.Kind, _ track: Track) {
        let language = L10n.current
        let order: [EditorialCard.Source]
        switch kind {
        case .album, .artist:
            order = NeteaseEditorialInfo.isUsable(uiLanguage: language)
                ? [.soda, .netease, .youtubeMusic, .lastfm] : [.youtubeMusic, .lastfm]
        case .song:
            order = QQSongInfo.isUsable(uiLanguage: language) ? [.qqMusic, .lastfm] : [.lastfm]
        }
        fallback(kind, track, via: order[...])
    }

    /// 前一个来源明确没有才问下一个;没问成(网络、限流、形状不对)那个来源不回调,链条停在这儿,下次换歌 / 消费方再来时重试。
    /// 没连 Last.fm 账号就跳过它(问不了,不是没问成)。取到的卡片只在那一栏还空着时放上去。
    private func fallback(_ kind: EditorialCard.Kind, _ track: Track, via sources: ArraySlice<EditorialCard.Source>) {
        guard let source = sources.first else { return }
        let next: (EditorialCard?) -> Void = { [weak self] card in
            guard let self else { return }
            guard let card else { return self.fallback(kind, track, via: sources.dropFirst()) }
            switch kind {
            case .album: if self.album == nil { self.album = card }
            case .artist: if self.artist == nil { self.artist = card }
            case .song: if self.song == nil { self.song = card }
            }
        }
        switch (source, kind) {
        case (.lastfm, _) where !LastfmStatsService.shared.isConnected:
            fallback(kind, track, via: sources.dropFirst())
        case (.lastfm, .album): lastfmAlbum(track, then: next)
        case (.lastfm, .artist): lastfmArtist(track, then: next)
        case (.lastfm, .song): lastfmSong(track, then: next)
        case (.netease, .album): neteaseAlbum(track, then: next)
        case (.netease, .artist): neteaseArtist(track, then: next)
        case (.qqMusic, .song): qqSong(track, then: next)
        case (.soda, .album): sodaAlbum(track, then: next)
        case (.soda, .artist): sodaArtist(track, then: next)
        case (.youtubeMusic, .album): youtubeMusicAlbum(track, then: next)
        case (.youtubeMusic, .artist): youtubeMusicArtist(track, then: next)
        // 这一类在这个来源上没有(网易云、汽水、YouTube Music 不给单曲写介绍,QQ 这一路只问歌曲),Apple Music 在兜底链之前就问过了。
        case (.netease, .song), (.soda, .song), (.youtubeMusic, .song), (.qqMusic, .album), (.qqMusic, .artist), (.appleMusic, _):
            fallback(kind, track, via: sources.dropFirst())
        }
    }

    // MARK: - Last.fm

    /// 按「album|歌手|专辑」「artist|歌手」「track|歌手|歌名」(`cleanTag`)记结论;值为 nil = Last.fm 明确没有。
    private var lastfmCards: [String: EditorialCard?] = [:]
    private var lastfmInFlight: Set<String> = []

    private func lastfmAlbum(_ track: Track, then: @escaping (EditorialCard?) -> Void) {
        let artistName = track.artist, albumName = track.album
        guard !artistName.isEmpty, !albumName.isEmpty else { return then(nil) }
        let key = "album|\(EnrichCacheKeys.cleanTag(artistName))|\(EnrichCacheKeys.cleanTag(albumName))"
        lastfmCard(key: key, method: "album.getInfo", variants: [["artist": artistName, "album": albumName]], for: track,
                   parse: LastfmEditorialInfo.albumWiki(from:)) { text in
            EditorialCard(kind: .album, title: albumName, subtitle: artistName, facts: [], text: text, source: .lastfm)
        } apply: { card in
            then(card)
        }
    }

    private func lastfmArtist(_ track: Track, then: @escaping (EditorialCard?) -> Void) {
        let artistName = track.artist
        guard !artistName.isEmpty else { return then(nil) }
        let key = "artist|\(EnrichCacheKeys.cleanTag(artistName))"
        lastfmCard(key: key, method: "artist.getInfo", variants: [["artist": artistName]], for: track,
                   parse: LastfmEditorialInfo.artistBio(from:)) { text in
            EditorialCard(kind: .artist, title: artistName, subtitle: "", facts: [], text: text, source: .lastfm)
        } apply: { card in
            then(card)
        }
    }

    /// 歌曲:`track.getInfo` 的 wiki。多人署名的歌按完整署名没有正文时,再按第一位歌手问一次(`ArtistCredit.primary`):
    /// Last.fm 的单曲百科多挂在主唱名下(实测《The Life of a Showgirl》按「Taylor Swift & Sabrina Carpenter」没有、
    /// 按「Taylor Swift」有),「Selena Gomez & The Scene」这类组合名又只有按完整署名才有 —— 所以完整署名先问。
    private func lastfmSong(_ track: Track, then: @escaping (EditorialCard?) -> Void) {
        let artistName = track.artist, title = track.title
        guard !artistName.isEmpty, !title.isEmpty else { return then(nil) }
        var variants = [["artist": artistName, "track": title]]
        if let primary = ArtistCredit.primary(artistName), primary != artistName {
            variants.append(["artist": primary, "track": title])
        }
        let key = "track|\(EnrichCacheKeys.cleanTag(artistName))|\(EnrichCacheKeys.cleanTag(title))"
        lastfmCard(key: key, method: "track.getInfo", variants: variants, for: track,
                   parse: LastfmEditorialInfo.trackWiki(from:)) { text in
            EditorialCard(kind: .song, title: title, subtitle: artistName, facts: [], text: text, source: .lastfm)
        } apply: { card in
            then(card)
        }
    }

    /// 记过结论就地套用;没有就问一次。回来时已经换歌,按当前曲目重查(命中刚记下的结论,不多发请求)。
    /// 失败(没连 Last.fm 账号 / 网络 / 形状不对)不记,下次换歌 / 消费方再来时重试。
    private func lastfmCard(key: String, method: String, variants: [[String: String]], for track: Track,
                            parse: @escaping ([String: Any]) -> LastfmEditorialInfo.Parsed?,
                            make: @escaping (String) -> EditorialCard,
                            apply: @escaping (EditorialCard?) -> Void) {
        if let known = lastfmCards[key] {
            apply(known)
            return
        }
        guard !lastfmInFlight.contains(key) else { return }
        lastfmInFlight.insert(key)
        let lang = LastfmEditorialInfo.preferredLang(uiLanguage: L10n.current)
        Self.logger.notice("lastfm fallback \(method, privacy: .public) lang \(lang ?? "default", privacy: .public)")
        Task { [weak self] in
            let text = await Self.lastfmText(method: method, variants: variants, lang: lang, parse: parse)
            guard let self else { return }
            self.lastfmInFlight.remove(key)
            guard let text else { return }
            let card = text.isEmpty ? nil : make(text)
            self.lastfmCards[key] = .some(card)
            Self.logger.notice("lastfm fallback \(method, privacy: .public): \(card == nil ? "none" : "\(text.count) chars", privacy: .public)")
            guard self.currentKey == track.key else { return self.refreshCurrent() }
            apply(card)
        }
    }

    /// nil = 没问成;"" = Last.fm 明确没有。参数按组依次问,前一组明确没有(没有这个条目、或者条目没有正文)才问下一组;
    /// 每组先问 `lang`(中文界面),正文为空再问默认那份。
    private static func lastfmText(method: String, variants: [[String: String]], lang: String?,
                                   parse: ([String: Any]) -> LastfmEditorialInfo.Parsed?) async -> String? {
        let langs: [String?] = lang.map { [$0, nil] } ?? [nil]
        for extra in variants {
            for candidate in langs {
                var params = extra
                params["autocorrect"] = "1"
                if let candidate { params["lang"] = candidate }
                guard let result = await LastfmStatsService.shared.fetchEditorialInfo(method: method, extra: params) else { return nil }
                if result.notFound { break }
                guard let json = result.json, let parsed = parse(json) else { return nil }
                if case .text(let text) = parsed { return text }
            }
        }
        return ""
    }

    // MARK: - 汽水音乐

    /// 汽水分享页地址 → 名字 + 介绍(正文已按界面转好繁简;正文为 nil = 汽水明确没有)。
    private var sodaIntros: [URL: SodaEditorialInfo.Intro] = [:]
    private var sodaInFlight: Set<URL> = []

    /// 专辑:缓存里这首的汽水专辑页(用汽水放过才有,ID 是汽水给的)→ 专辑介绍。卡片标题、副标题用播放器报的专辑名和歌手。
    /// 没有汽水专辑页、汽水没有介绍都算明确没有,回调 nil 交给下一个来源;没问成不回调。
    private func sodaAlbum(_ track: Track, then: @escaping (EditorialCard?) -> Void) {
        let links = EnrichCacheReader.platformLinks(artist: track.artist, title: track.title, album: track.album)
        guard let page = links?.sodaAlbum, !track.album.isEmpty else { return then(nil) }
        withSodaIntro(page, for: track) { intro in
            then(intro.text.map {
                EditorialCard(kind: .album, title: track.album, subtitle: track.artist, facts: [], text: $0, source: .soda)
            })
        }
    }

    /// 歌手:缓存里这首的汽水歌手页 → 歌手介绍。卡片标题用汽水写的歌手名(没有才用播放器报的)。
    private func sodaArtist(_ track: Track, then: @escaping (EditorialCard?) -> Void) {
        let links = EnrichCacheReader.platformLinks(artist: track.artist, title: track.title, album: track.album)
        guard let page = links?.sodaArtist else { return then(nil) }
        withSodaIntro(page, for: track) { intro in
            then(intro.text.map {
                EditorialCard(kind: .artist, title: intro.name ?? track.artist, subtitle: "", facts: [], text: $0, source: .soda)
            })
        }
    }

    /// 这一页的介绍:记过就地回调;没有就问一次。回来时已经换歌,按当前曲目重查(命中刚记下的,不多发请求)。
    /// 繁体界面转成繁体(`SodaEditorialInfo.localized`)。
    private func withSodaIntro(_ page: URL, for track: Track, _ body: @escaping (SodaEditorialInfo.Intro) -> Void) {
        if let known = sodaIntros[page] { return body(known) }
        guard !sodaInFlight.contains(page) else { return }
        sodaInFlight.insert(page)
        let language = L10n.current
        Self.logger.notice("soda intro \(page.absoluteString, privacy: .public)")
        Task { [weak self] in
            let fetched = await Task.detached(priority: .utility) {
                await SodaEditorialInfo.fetchIntro(page: page)
            }.value
            guard let self else { return }
            self.sodaInFlight.remove(page)
            guard let fetched else { return }
            let intro = SodaEditorialInfo.Intro(name: fetched.name,
                                                text: fetched.text.map { SodaEditorialInfo.localized($0, uiLanguage: language) })
            self.sodaIntros[page] = intro
            Self.logger.notice("soda intro \(page.absoluteString, privacy: .public): \(intro.text.map { "\($0.count) chars" } ?? "none", privacy: .public)")
            guard self.currentKey == track.key else { return self.refreshCurrent() }
            body(intro)
        }
    }

    // MARK: - YouTube Music(维基百科)

    /// 一张专辑在 YouTube Music 上的结论:维基介绍(界面语言那版,没有时英文版;都没有为 nil)和署名歌手。
    private struct YouTubeMusicAlbum: Sendable {
        let description: String?
        let artists: [YouTubeMusicEditorialInfo.Artist]
    }

    /// 一次专辑查询问成了;`album` 为 nil = 搜不到对得上的专辑。
    private struct YouTubeMusicAlbumLookup: Sendable {
        let album: YouTubeMusicAlbum?
    }

    /// 「界面语言|专辑 ID」或「界面语言|search|歌手|专辑」→ 这张专辑;值为 nil = 搜过了,没有对得上的专辑。
    private var youtubeMusicAlbums: [String: YouTubeMusicAlbum?] = [:]
    /// 在飞的专辑查询 → 等它的那几路(各记着是为哪首要的)。专辑、歌手两路都要它(歌手 ID 从专辑页的署名来),同网易云的
    /// 歌曲详情:后到的那一路排队等,不丢。
    private var youtubeMusicAlbumWaiters: [String: [(key: String, body: (YouTubeMusicAlbum?) -> Void)]] = [:]
    /// 「界面语言|频道 ID」→ 歌手的维基介绍;值为 nil = 明确没有。
    private var youtubeMusicArtistTexts: [String: String?] = [:]
    private var youtubeMusicArtistsInFlight: Set<String> = []
    /// YouTube Music 上一次问不通的时刻。国内网络常年连不上 YouTube:照别的来源「没问成就停在那儿」的规矩,这一路会把排在
    /// 后面的 Last.fm 永远挡住,每次重查还要等满超时。所以它问不通时这一轮当没有、交给下一个来源(不记结论),之后
    /// `youtubeMusicRetryAfter` 内都不再问;过了再试,问通了清掉。
    private var youtubeMusicUnreachableSince: Date?
    private static let youtubeMusicRetryAfter: TimeInterval = 600

    /// 还在问不通之后的冷却期里。
    private var youtubeMusicCoolingDown: Bool {
        guard let since = youtubeMusicUnreachableSince else { return false }
        return Date().timeIntervalSince(since) < Self.youtubeMusicRetryAfter
    }

    /// 专辑:这张专辑在 YouTube Music 上的维基介绍。卡片标题、副标题用播放器报的专辑名和歌手。没有对得上的专辑、没有维基
    /// 介绍都算明确没有,回调 nil 交给下一个来源;没问成不回调。
    private func youtubeMusicAlbum(_ track: Track, then: @escaping (EditorialCard?) -> Void) {
        withYouTubeMusicAlbum(track) { album in
            then(album?.description.map {
                EditorialCard(kind: .album, title: track.album, subtitle: track.artist, facts: [], text: $0, source: .youtubeMusic)
            })
        }
    }

    /// 歌手:缓存里播放器给的歌手 ID(用 Kaset / YouTube Music 网页版放的);没有就取对上的那张专辑页署名里的这位
    /// (名字对不上时,专辑只有一位署名就是他,同 Apple 那一路)→ 歌手页的维基介绍。不单独按名字搜歌手。
    private func youtubeMusicArtist(_ track: Track, then: @escaping (EditorialCard?) -> Void) {
        let links = EnrichCacheReader.platformLinks(artist: track.artist, title: track.title, album: track.album)
        if let channel = YouTubeMusicEditorialInfo.channelID(fromArtistPage: links?.youtubeMusicArtist) {
            return withYouTubeMusicArtistText(channel, for: track) { text in
                then(text.map {
                    EditorialCard(kind: .artist, title: track.artist, subtitle: "", facts: [], text: $0, source: .youtubeMusic)
                })
            }
        }
        withYouTubeMusicAlbum(track) { [weak self] album in
            let credits = album?.artists ?? []
            guard let artist = credits.first(where: { YouTubeMusicEditorialInfo.artistMatches($0.name, playingArtist: track.artist) })
                ?? (credits.count == 1 ? credits[0] : nil) else { return then(nil) }
            self?.withYouTubeMusicArtistText(artist.channelID, for: track) { text in
                then(text.map {
                    EditorialCard(kind: .artist, title: artist.name, subtitle: "", facts: [], text: $0, source: .youtubeMusic)
                })
            }
        }
    }

    /// 这首的专辑在 YouTube Music 上的结论:记过就地回调;在飞就排进等它的队;都没有就查一次 —— 缓存里有播放器给的专辑 ID
    /// 就直接取专辑页,没有就按「歌手 专辑」搜(`YouTubeMusicEditorialInfo.pickAlbum`)。没有专辑名、搜不到对得上的都回调 nil
    /// (明确没有);没问成不回调。回来时队里有为别的曲目要的(已经换歌),按当前曲目重查,否则挨个回调。
    private func withYouTubeMusicAlbum(_ track: Track, _ body: @escaping (YouTubeMusicAlbum?) -> Void) {
        let links = EnrichCacheReader.platformLinks(artist: track.artist, title: track.title, album: track.album)
        let knownID = YouTubeMusicEditorialInfo.browseID(fromAlbumPage: links?.youtubeMusicAlbum)
        guard knownID != nil || (!track.album.isEmpty && !track.artist.isEmpty), !youtubeMusicCoolingDown else { return body(nil) }
        let hl = YouTubeMusicEditorialInfo.descriptionHL(uiLanguage: L10n.current)
        let key = hl + "|" + (knownID ?? "search|\(EnrichCacheKeys.cleanTag(track.artist))|\(EnrichCacheKeys.cleanTag(track.album))")
        if let known = youtubeMusicAlbums[key] { return body(known) }
        let waiter = (key: track.key, body: body)
        guard youtubeMusicAlbumWaiters[key] == nil else {
            youtubeMusicAlbumWaiters[key]?.append(waiter)
            return
        }
        youtubeMusicAlbumWaiters[key] = [waiter]
        let artist = track.artist, album = track.album
        Self.logger.notice("youtube music album \(knownID ?? "via search", privacy: .public) hl \(hl, privacy: .public)")
        Task { [weak self] in
            let lookup = await Task.detached(priority: .utility) {
                await Self.lookUpYouTubeMusicAlbum(knownID: knownID, artist: artist, album: album, hl: hl)
            }.value
            guard let self else { return }
            let waiting = self.youtubeMusicAlbumWaiters.removeValue(forKey: key) ?? []
            if let lookup {
                self.youtubeMusicUnreachableSince = nil
                self.youtubeMusicAlbums[key] = .some(lookup.album)
                Self.logger.notice("youtube music album: \(lookup.album.map { "\($0.description?.count ?? 0) chars, \($0.artists.count) artists" } ?? "no match", privacy: .public)")
            } else {
                self.youtubeMusicUnreachableSince = Date()
                Self.logger.notice("youtube music album unreachable; skipping youtube music for a while")
            }
            guard waiting.allSatisfy({ $0.key == self.currentKey }) else { return self.refreshCurrent() }
            waiting.forEach { $0.body(lookup?.album) }
        }
    }

    /// 查一张专辑:有专辑 ID 直接取专辑页;没有就按「歌手 专辑」搜,搜索的界面语言按歌手名的文字取(`searchHL`),
    /// 对不上再按日文搜一次(`retryHL`)。专辑页按界面语言取,没有维基介绍再取英文版的介绍。nil = 哪一步没问成。
    nonisolated private static func lookUpYouTubeMusicAlbum(knownID: String?, artist: String, album: String,
                                                            hl: String) async -> YouTubeMusicAlbumLookup? {
        var browseID = knownID
        if browseID == nil {
            var searchHL = YouTubeMusicEditorialInfo.searchHL(artist: artist, album: album)
            for attempt in 0..<2 {
                guard let hits = await YouTubeMusicEditorialInfo.searchAlbums(query: artist + " " + album, hl: searchHL)
                else { return nil }
                browseID = YouTubeMusicEditorialInfo.pickAlbum(hits, playingAlbum: album, playingArtist: artist)?.browseID
                guard browseID == nil, attempt == 0,
                      let retry = YouTubeMusicEditorialInfo.retryHL(firstHL: searchHL, hits: hits, playingArtist: artist)
                else { break }
                searchHL = retry
            }
        }
        guard let browseID else { return YouTubeMusicAlbumLookup(album: nil) }
        guard let page = await YouTubeMusicEditorialInfo.fetchAlbumPage(browseID: browseID, hl: hl) else { return nil }
        var description = page.description
        if description == nil, hl != "en" {
            guard let english = await YouTubeMusicEditorialInfo.fetchAlbumPage(browseID: browseID, hl: "en") else { return nil }
            description = english.description
        }
        return YouTubeMusicAlbumLookup(album: YouTubeMusicAlbum(description: description, artists: page.artists))
    }

    /// 歌手页的维基介绍:记过就地回调;没有就问一次。回来时已经换歌,按当前曲目重查(命中刚记下的,不多发请求)。
    private func withYouTubeMusicArtistText(_ channelID: String, for track: Track, then: @escaping (String?) -> Void) {
        let hl = YouTubeMusicEditorialInfo.descriptionHL(uiLanguage: L10n.current)
        let key = hl + "|" + channelID
        if let known = youtubeMusicArtistTexts[key] { return then(known) }
        guard !youtubeMusicCoolingDown else { return then(nil) }
        guard !youtubeMusicArtistsInFlight.contains(key) else { return }
        youtubeMusicArtistsInFlight.insert(key)
        Self.logger.notice("youtube music artist \(channelID, privacy: .public) hl \(hl, privacy: .public)")
        Task { [weak self] in
            let fetched = await Task.detached(priority: .utility) {
                await Self.youTubeMusicArtistText(channelID: channelID, hl: hl)
            }.value
            guard let self else { return }
            self.youtubeMusicArtistsInFlight.remove(key)
            guard let fetched else {
                self.youtubeMusicUnreachableSince = Date()
                Self.logger.notice("youtube music artist unreachable; skipping youtube music for a while")
                guard self.currentKey == track.key else { return self.refreshCurrent() }
                return then(nil)
            }
            self.youtubeMusicUnreachableSince = nil
            let text = fetched.isEmpty ? nil : fetched
            self.youtubeMusicArtistTexts[key] = .some(text)
            Self.logger.notice("youtube music artist \(channelID, privacy: .public): \(text.map { "\($0.count) chars" } ?? "none", privacy: .public)")
            guard self.currentKey == track.key else { return self.refreshCurrent() }
            then(text)
        }
    }

    /// nil = 没问成;"" = 明确没有(界面语言那版、英文版都没有维基介绍 —— 英文界面常是频道自己的宣传语,不算)。
    nonisolated private static func youTubeMusicArtistText(channelID: String, hl: String) async -> String? {
        for lang in hl == "en" ? ["en"] : [hl, "en"] {
            guard let parsed = await YouTubeMusicEditorialInfo.fetchArtistDescription(channelID: channelID, hl: lang)
            else { return nil }
            if case .text(let text) = parsed { return text }
        }
        return ""
    }

    // MARK: - QQ 音乐

    /// QQ 歌曲 mid → 简介正文(已按界面转好繁简);值为 nil = QQ 明确没有这首的简介。
    private var qqSongTexts: [String: String?] = [:]
    private var qqSongsInFlight: Set<String> = []

    /// 歌曲:缓存里这首的 QQ 音乐歌曲页 → 歌曲详情里的「简介」。卡片标题、副标题用播放器报的歌名和歌手。缓存里没有
    /// QQ 歌曲页(搜索页兜底不算)、QQ 没有这首或者没有简介都算明确没有,回调 nil 交给下一个来源;没问成不回调。
    private func qqSong(_ track: Track, then: @escaping (EditorialCard?) -> Void) {
        let links = EnrichCacheReader.platformLinks(artist: track.artist, title: track.title, album: track.album)
        guard let mid = links?.qqSong.flatMap({ PlatformLinks.qqSongMID(songPage: $0.absoluteString) }) else { return then(nil) }
        withQQSongText(mid: mid, for: track) { text in
            then(text.map {
                EditorialCard(kind: .song, title: track.title, subtitle: track.artist, facts: [], text: $0, source: .qqMusic)
            })
        }
    }

    /// 这首的简介:记过就地回调;没有就问一次。回来时已经换歌,按当前曲目重查(命中刚记下的,不多发请求)。
    /// 繁体界面转成繁体(`QQSongInfo.localized`)。
    private func withQQSongText(mid: String, for track: Track, then: @escaping (String?) -> Void) {
        if let known = qqSongTexts[mid] { return then(known) }
        guard !qqSongsInFlight.contains(mid) else { return }
        qqSongsInFlight.insert(mid)
        let language = L10n.current
        Self.logger.notice("qq intro for song \(mid, privacy: .public)")
        Task { [weak self] in
            let parsed = await Task.detached(priority: .utility) {
                await QQSongInfo.fetchIntro(songMID: mid)
            }.value
            guard let self else { return }
            self.qqSongsInFlight.remove(mid)
            guard let parsed else { return }
            var text: String?
            if case .text(let raw) = parsed { text = QQSongInfo.localized(raw, uiLanguage: language) }
            self.qqSongTexts[mid] = .some(text)
            Self.logger.notice("qq intro \(mid, privacy: .public): \(text.map { "\($0.count) chars" } ?? "none", privacy: .public)")
            guard self.currentKey == track.key else { return self.refreshCurrent() }
            then(text)
        }
    }

    // MARK: - 网易云

    /// 网易云歌曲 ID → 歌曲详情(署名 + 所在专辑);专辑、歌手两路都用,同一首只问一次。
    private var neteaseSongs: [Int64: NeteaseEditorialInfo.Song] = [:]
    /// 在飞的歌曲详情 → 等它的那几路,各记着是为哪首要的。换歌后专辑、歌手常一前一后退到网易云要同一首,后到的那路
    /// 排队等它:照别的请求那样「在飞就不回调」,那一路就停在半路,这首的另一张卡片出不来。
    private var neteaseSongWaiters: [Int64: [(key: String, body: (NeteaseEditorialInfo.Song) -> Void)]] = [:]
    /// 网易云歌手 ID → 简介卡片;值为 nil = 网易云明确没有这位的介绍。
    private var neteaseCards: [Int64: EditorialCard?] = [:]
    /// 网易云专辑 ID → 介绍正文(已按界面转好繁简);值为 nil = 网易云明确没有这张的介绍。
    private var neteaseAlbumTexts: [Int64: String?] = [:]
    private var neteaseArtistsInFlight: Set<Int64> = []
    private var neteaseAlbumsInFlight: Set<Int64> = []

    /// 缓存里这首的网易云歌曲 ID;没有网易云歌曲页为 nil。
    private func neteaseSongID(_ track: Track) -> Int64? {
        let links = EnrichCacheReader.platformLinks(artist: track.artist, title: track.title, album: track.album)
        return NeteaseEditorialInfo.songID(fromSongPage: links?.neteaseSong)
    }

    /// 歌手:歌曲详情里的署名,挑对上当前歌手的那一位(同 Apple 那一路,`AlbumEditorialNotes.pickArtist`)→ 他的介绍。
    /// 缓存里没有网易云歌曲页、署名对不上、网易云没有介绍都算明确没有,回调 nil 交给下一个来源;没问成不回调。
    private func neteaseArtist(_ track: Track, then: @escaping (EditorialCard?) -> Void) {
        guard let songID = neteaseSongID(track) else { return then(nil) }
        withNeteaseSong(songID: songID, for: track) { [weak self] song in
            guard let link = AlbumEditorialNotes.pickArtist(song.artists, localArtist: track.artist) else { return then(nil) }
            self?.withNeteaseCard(link, for: track, then: then)
        }
    }

    /// 专辑:歌曲详情里的所在专辑,要跟正在放的对得上(`NeteaseEditorialInfo.Album.matches`)→ 它的介绍。卡片的标题、
    /// 副标题用播放器报的专辑名和歌手,同 Last.fm 那一路。缓存里没有网易云歌曲页、专辑对不上、网易云没有介绍都算明确没有,
    /// 回调 nil 交给下一个来源;没问成不回调。
    private func neteaseAlbum(_ track: Track, then: @escaping (EditorialCard?) -> Void) {
        guard let songID = neteaseSongID(track) else { return then(nil) }
        withNeteaseSong(songID: songID, for: track) { [weak self] song in
            guard let album = song.album, album.matches(playing: track.album) else { return then(nil) }
            self?.withNeteaseAlbumText(album, for: track) { text in
                then(text.map {
                    EditorialCard(kind: .album, title: track.album, subtitle: track.artist, facts: [], text: $0, source: .netease)
                })
            }
        }
    }

    /// 这首的歌曲详情:记过就地回调;在飞就排进等它的队;都没有就问一次。回来时队里有为别的曲目要的(已经换歌),
    /// 就按当前曲目重查(命中刚记下的,不多发请求),否则挨个回调。
    private func withNeteaseSong(songID: Int64, for track: Track,
                                 _ body: @escaping (NeteaseEditorialInfo.Song) -> Void) {
        if let known = neteaseSongs[songID] { return body(known) }
        let waiter = (key: track.key, body: body)
        guard neteaseSongWaiters[songID] == nil else {
            neteaseSongWaiters[songID]?.append(waiter)
            return
        }
        neteaseSongWaiters[songID] = [waiter]
        Self.logger.notice("netease song detail \(songID, privacy: .public)")
        Task { [weak self] in
            let song = await Task.detached(priority: .utility) {
                await NeteaseEditorialInfo.fetchSong(songID: songID)
            }.value
            guard let self else { return }
            let waiting = self.neteaseSongWaiters.removeValue(forKey: songID) ?? []
            guard let song else { return }
            self.neteaseSongs[songID] = song
            guard waiting.allSatisfy({ $0.key == self.currentKey }) else { return self.refreshCurrent() }
            waiting.forEach { $0.body(song) }
        }
    }

    /// 这张专辑的介绍:记过就地回调;没有就问一次。繁体界面转成繁体(`NeteaseEditorialInfo.localized`)。
    private func withNeteaseAlbumText(_ album: NeteaseEditorialInfo.Album, for track: Track,
                                      then: @escaping (String?) -> Void) {
        if let known = neteaseAlbumTexts[album.id] { return then(known) }
        guard !neteaseAlbumsInFlight.contains(album.id) else { return }
        neteaseAlbumsInFlight.insert(album.id)
        let albumID = album.id, language = L10n.current
        Self.logger.notice("netease description for album \(albumID, privacy: .public)")
        Task { [weak self] in
            let parsed = await Task.detached(priority: .utility) {
                await NeteaseEditorialInfo.fetchAlbumDescription(albumID: albumID)
            }.value
            guard let self else { return }
            self.neteaseAlbumsInFlight.remove(albumID)
            guard let parsed else { return }
            var text: String?
            if case .text(let raw) = parsed { text = NeteaseEditorialInfo.localized(raw, uiLanguage: language) }
            self.neteaseAlbumTexts[albumID] = .some(text)
            Self.logger.notice("netease description \(albumID, privacy: .public): \(text.map { "\($0.count) chars" } ?? "none", privacy: .public)")
            guard self.currentKey == track.key else { return self.refreshCurrent() }
            then(text)
        }
    }

    /// 这位歌手的介绍:记过就地回调;没有就问一次。繁体界面转成繁体(`NeteaseEditorialInfo.localized`)。
    private func withNeteaseCard(_ link: AlbumEditorialNotes.ArtistLink, for track: Track,
                                 then: @escaping (EditorialCard?) -> Void) {
        if let known = neteaseCards[link.id] { return then(known) }
        guard !neteaseArtistsInFlight.contains(link.id) else { return }
        neteaseArtistsInFlight.insert(link.id)
        let language = L10n.current
        Self.logger.notice("netease introduction for artist \(link.id, privacy: .public)")
        Task { [weak self] in
            let parsed = await Task.detached(priority: .utility) {
                await NeteaseEditorialInfo.fetchIntroduction(artistID: link.id)
            }.value
            guard let self else { return }
            self.neteaseArtistsInFlight.remove(link.id)
            guard let parsed else { return }
            var card: EditorialCard?
            if case .text(let text) = parsed {
                card = EditorialCard(kind: .artist, title: link.name, subtitle: "", facts: [],
                                     text: NeteaseEditorialInfo.localized(text, uiLanguage: language), source: .netease)
            }
            self.neteaseCards[link.id] = .some(card)
            Self.logger.notice("netease introduction \(link.id, privacy: .public): \(card.map { "\($0.text.count) chars" } ?? "none", privacy: .public)")
            guard self.currentKey == track.key else { return self.refreshCurrent() }
            then(card)
        }
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
            // Last.fm 的正文是 CC BY-SA 授权的用户百科,出处必须注明;网易云、QQ 音乐的是它们家的介绍,同样注明。
            if let attribution = card.source.attribution {
                Text(attribution)
                    .font(.system(size: 10))
                    .foregroundStyle(secondary)
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
