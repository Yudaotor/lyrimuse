import AppKit
import LyrimuseCore

/// 歌词窗口「…」菜单里那些直接执行的行(Apple Music 的资料库 / 减少推荐 / 前往专辑与歌手、各平台页、在播放器中显示)
/// 背后的状态和动作。歌词窗口和网页歌词副屏各持一份,两边同一套行为(19 章决策 8)。
@MainActor
final class LyricsMoreMenuModel: ObservableObject {
    /// 「添加到资料库」行的即时状态:此前点完静默关面板,成功/本来就在库/
    /// 失败三种结局全都看不出差别(实测"点了没反应"那次就是歌 7 月已在库、duplicate
    /// 静默 no-op)。现在开菜单时异步查一次"已在库?",点击后行内走 添加中→已添加/失败,
    /// 全程不关菜单。
    enum LibraryAddState: Equatable {
        case idle, alreadyInLibrary, adding, added, failed, removing, removeFailed
    }

    struct PlatformRow: Identifiable, Equatable {
        let id: String
        let title: String
        let url: URL
    }

    /// 目录页跳转的去处:专辑 / 艺人 / 曲目(停播页「最近听过」行点击要的是曲目页)。
    enum CatalogTarget { case album, artist, track }

    @Published private(set) var libraryAddState: LibraryAddState = .idle
    /// 「减少推荐」是否已生效(同上一批的反馈缺口):开菜单时读回 disliked,行上带勾;
    /// 点击在 减少/撤销 之间切换 —— AM 自己的菜单也是勾选态可再点撤销。
    @Published private(set) var suggestLessApplied = false
    /// 这首歌在各平台的跳转目标。零网络,全是引擎早就存进 enrich 缓存的字段;开菜单/换曲时读一次。
    @Published private(set) var platformLinks: PlatformLinks?
    /// 菜单状态代际:每次 刷新(开菜单/菜单开着换曲) +1。异步任务(回查/添加)落地前
    /// 核对自己出发时的代际,不同代际=过期结果直接丢弃 —— 防止上一首歌的在途结果
    /// 贴到新曲的菜单上(审阅抓的跨曲竞态)。
    private var generation = 0
    /// 本次菜单会话内用户是否已手动切过「减少推荐」:切过之后,后到的回查结果不许再
    /// 覆盖它(回查读的是开菜单那一刻的旧值,覆盖=抹掉用户刚点的勾)。
    private var suggestLessUserToggled = false
    /// 「减少推荐」写操作串行链:快速连点时两个 detached task 之间本无顺序保证,
    /// 后点的先执行会让终态与 UI 相反 —— 每次写先 await 上一次,保证按点击序生效。
    private var suggestLessSerialTask: Task<Void, Never>?

    /// 当前播放器是不是 Apple Music —— Apple Music 专属菜单项(资料库/减少推荐/前往
    /// 专辑·艺人)的显示条件。
    static var isAppleMusicPlayer: Bool {
        PlaybackCoordinator.shared.resolvedPlayerBundleID == PlaybackPlayer.appleMusic.bundleIdentifier
    }

    /// 把 AM 两个状态行刷新到真实值(开菜单时 + 菜单开着换曲时;只读查询,不触发授权
    /// 弹窗 —— 弹窗只该出现在用户显式点动作的时候)。代际 +1 让所有在途异步结果作废。
    func refresh(title: String, artist: String, album: String) {
        generation += 1
        let generation = generation
        libraryAddState = .idle
        suggestLessApplied = false
        suggestLessUserToggled = false
        // 平台链接的加载必须放在下面那道 `isAppleMusicPlayer` 早退**之前** ——
        // 非 AM 播放器(QQ/网易云)正是要用它的那一档,放在早退之后等于永远不加载。
        // 在主线程直接读:EnrichCacheReader 只许在主线程用(静态缓存没有锁,后台线程调它就是跟轮询并发
        // 改同一批字典),缓存已加载时这次读取是 µs 级。
        platformLinks = title.isEmpty ? nil : EnrichCacheReader.platformLinks(artist: artist, title: title, album: album)
        guard Self.isAppleMusicPlayer else { return }
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: false) else { return }
            let inLibrary = MusicPlaybackController.currentTrackIsInLibrary()
            let disliked = MusicPlaybackController.currentTrackDisliked()
            await MainActor.run {
                // 换曲/重开菜单后这批结果已经是别的歌的,直接丢弃
                guard generation == self.generation else { return }
                // 查询期间用户可能已点了"添加"(adding/added),别把进行中的状态盖掉
                if inLibrary == true, self.libraryAddState == .idle { self.libraryAddState = .alreadyInLibrary }
                // 同理:用户已手动切过勾,后到的旧值不许再覆盖(审阅 D1)
                if let disliked, !self.suggestLessUserToggled { self.suggestLessApplied = disliked }
            }
        }
    }

    /// 点「添加到资料库」:添加中→已添加/失败,不关菜单。成功与否**不信 duplicate 的
    /// 返回值** —— 它对"已在库静默 no-op"也报 ok,事后重新读回
    /// 资料库才算数;读回本身失败(nil)时才退回信命令返回值。
    func addToLibrary() {
        libraryAddState = .adding
        let generation = generation
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run {
                    if generation == self.generation { self.libraryAddState = .failed }
                }
                return
            }
            let commandOK = MusicPlaybackController.addCurrentTrackToLibrary()
            let verified = MusicPlaybackController.currentTrackIsInLibrary()
            await MainActor.run {
                // 关菜单→换曲→重开 后落地的旧结局不能贴到新曲的行上(审阅 D2c)
                guard generation == self.generation else { return }
                self.libraryAddState = (verified ?? commandOK) ? .added : .failed
            }
        }
    }

    /// 点「从资料库删除」:删除中→回 idle(行翻回「添加到资料库」即反馈)/删除失败。
    /// 与添加同款纪律:成败不信命令返回值,事后读回资料库(目标=不在库)才算数。
    /// 删除不可撤销:等授权弹窗期间换了歌,删掉的就是下一首。脚本里按点下去那一刻的歌名再核一次。
    func removeFromLibrary(expectedTitle: String) {
        libraryAddState = .removing
        let generation = generation
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run {
                    if generation == self.generation { self.libraryAddState = .removeFailed }
                }
                return
            }
            let commandOK = MusicPlaybackController.removeCurrentTrackFromLibrary(expectedName: expectedTitle)
            let verified = MusicPlaybackController.currentTrackIsInLibrary()
            await MainActor.run {
                guard generation == self.generation else { return }
                let gone = verified.map { !$0 } ?? commandOK
                self.libraryAddState = gone ? .idle : .removeFailed
            }
        }
    }

    /// 「减少推荐」:不关菜单,勾的出现/消失就是反馈。乐观更新,AppleScript 那头失败
    /// 也只是勾跟真实状态短暂不一致,下次开菜单会读回纠正。
    /// 带上点下去那一刻的歌名:排队 / 等授权期间换了歌,就不去改下一首的「减少推荐」。
    func toggleSuggestLess(expectedTitle: String) {
        suggestLessUserToggled = true
        let newValue = !suggestLessApplied
        suggestLessApplied = newValue
        let previous = suggestLessSerialTask
        suggestLessSerialTask = Task.detached(priority: .userInitiated) {
            await previous?.value
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else { return }
            MusicPlaybackController.setDisliked(newValue, expectedName: expectedTitle)
        }
    }

    /// 当前播放器那一个平台的目录入口。AM 走它自己那套(前往专辑/前往艺人,经 iTunes
    /// Search),所以这里只管非 AM。
    var platformRows: [PlatformRow] {
        guard !Self.isAppleMusicPlayer, let links = platformLinks else { return [] }
        let bundleID = PlaybackCoordinator.shared.resolvedPlayerBundleID
        var out: [PlatformRow] = []
        if bundleID == PlaybackPlayer.qqMusic.bundleIdentifier {
            if let u = links.qqSong { out.append(.init(id: "qq-song", title: L10n.t("QQ 音乐歌曲页"), url: u)) }
            if let u = links.qqAlbum { out.append(.init(id: "qq-album", title: L10n.t("QQ 音乐专辑页"), url: u)) }
            if let u = links.qqArtist { out.append(.init(id: "qq-artist", title: L10n.t("QQ 音乐歌手页"), url: u)) }
        } else if bundleID == PlaybackPlayer.netease.bundleIdentifier {
            // 网易云只给歌曲页:它的专辑页、歌手页不登录看不到内容(07 章决策 107)。
            if let u = links.neteaseSong { out.append(.init(id: "ne-song", title: L10n.t("网易云音乐歌曲页"), url: u)) }
        } else if bundleID == PlaybackPlayer.soda.bundleIdentifier {
            if let u = links.sodaSong { out.append(.init(id: "soda-song", title: L10n.t("汽水音乐歌曲页"), url: u)) }
            if let u = links.sodaAlbum { out.append(.init(id: "soda-album", title: L10n.t("汽水音乐专辑页"), url: u)) }
            if let u = links.sodaArtist { out.append(.init(id: "soda-artist", title: L10n.t("汽水音乐歌手页"), url: u)) }
        } else if bundleID == PlaybackPlayer.kugou.bundleIdentifier {
            if let u = links.kugouSong { out.append(.init(id: "kugou-song", title: L10n.t("酷狗音乐歌曲页"), url: u)) }
        } else if bundleID == PlaybackPlayer.kkbox.bundleIdentifier {
            // KKBOX 的是进 App 的深链(见 PlatformLinks.kkboxAlbumAppURL),文案跟上面几条浏览器页不同。这首歌本身走菜单里
            // 「在 KKBOX 中显示」那一行(有歌曲深链时打开它),别在这里再加一行同名的。
            if let u = links.kkboxAlbum { out.append(.init(id: "kkbox-album", title: L10n.t("在 KKBOX 中显示专辑"), url: u)) }
            if let u = links.kkboxArtist { out.append(.init(id: "kkbox-artist", title: L10n.t("在 KKBOX 中显示歌手"), url: u)) }
        } else if bundleID == PlaybackPlayer.spotify.bundleIdentifier {
            // 浏览器里的网页;在 Spotify 客户端里跳到这首的是下面「在 Spotify 中显示」那条。
            if let u = links.spotifySong { out.append(.init(id: "spotify-song", title: L10n.t("Spotify 歌曲页"), url: u)) }
            if let u = links.spotifyAlbum { out.append(.init(id: "spotify-album", title: L10n.t("Spotify 专辑页"), url: u)) }
            if let u = links.spotifyArtist { out.append(.init(id: "spotify-artist", title: L10n.t("Spotify 歌手页"), url: u)) }
        } else if bundleID == PlaybackPlayer.amazonMusic.bundleIdentifier {
            if let u = links.amazonSong { out.append(.init(id: "amazon-song", title: L10n.t("Amazon Music 歌曲页"), url: u)) }
            if let u = links.amazonAlbum { out.append(.init(id: "amazon-album", title: L10n.t("Amazon Music 专辑页"), url: u)) }
            if let u = links.amazonArtist { out.append(.init(id: "amazon-artist", title: L10n.t("Amazon Music 歌手页"), url: u)) }
        } else if bundleID == PlaybackPlayer.kaset.bundleIdentifier {
            // 落到浏览器的网页,不是 Kaset 自己的深链(那条一打开就开始放,见 PlatformLinks.youtubeMusicSong)。
            if let u = links.youtubeMusicSong { out.append(.init(id: "ytm-song", title: L10n.t("YouTube Music 歌曲页"), url: u)) }
            if let u = links.youtubeMusicAlbum { out.append(.init(id: "ytm-album", title: L10n.t("YouTube Music 专辑页"), url: u)) }
            if let u = links.youtubeMusicArtist { out.append(.init(id: "ytm-artist", title: L10n.t("YouTube Music 歌手页"), url: u)) }
        }
        return out
    }

    /// 平台页这一行的标题:落到浏览器的带 ↗、进 App 的深链(KKBOX)不带。↗ 是如实告知落点,按链接本身判,
    /// 别写成每行都拼(07 章决策 110)。
    static func title(of row: PlatformRow) -> String {
        PlatformLinks.opensInBrowser(row.url) ? row.title + " ↗" : row.title
    }

    /// 「在 XX 中显示」:Apple Music 走 reveal(在 Music 里定位选中当前曲目,流媒体曲目也可用);
    /// Spotify 原生客户端走 `spotify:track:<id>` 深链跳到曲目页(SpotifyReveal;网页版的播放器 bundle 是浏览器,
    /// 不进这支);KKBOX 有歌曲深链时打开它(`kkbox://song/<id>#view`,跳到这首的页面、不播放);其它走
    /// openResolvedPlayer —— 原生播放器激活该 App,网页平台翻到正在放歌的那枚标签页。
    func revealInPlayer() {
        let bundleID = PlaybackCoordinator.shared.resolvedPlayerBundleID
        if Self.isAppleMusicPlayer {
            Self.runAppleMusicAction { MusicPlaybackController.revealCurrentTrack() }
        } else if bundleID == PlaybackPlayer.spotify.bundleIdentifier {
            SpotifyReveal.revealCurrentTrack { PlaybackCoordinator.shared.openResolvedPlayerApp() }
        } else if bundleID == PlaybackPlayer.kkbox.bundleIdentifier, let song = platformLinks?.kkboxSong {
            NSWorkspace.shared.open(song)
        } else {
            PlaybackCoordinator.shared.openResolvedPlayer()
        }
    }

    /// Apple Music 专属菜单动作的统一外壳:权限确认 + 后台线程执行(AppleScript 会阻塞,
    /// 不能在主线程跑)。失败静默 —— 与 toggleFavorited 的宽松约定一致,这些都不是核心
    /// 路径,权限被拒时 checkAppleMusicSafely 自己会弹一次系统授权框。
    static func runAppleMusicAction(_ action: @escaping @Sendable () -> Void) {
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else { return }
            action()
        }
    }

    /// 「你的常听」榜单里点一行:与 openCatalogPage 同一条跳转管线(iTunes Search 解析 → music:// 原生跳页)。
    /// 查不到 / 没有对应页面时响一声:点了之后什么都不发生,分不清是没找到还是还在找。
    static func openChartEntry(_ entry: LastfmStatsService.ChartEntry, kind: LastfmStatsService.ChartKind) {
        Task.detached(priority: .userInitiated) {
            let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
            let title: String
            let artist: String
            switch kind {
            case .tracks, .albums:
                title = entry.name
                artist = entry.detail
            case .artists:
                // 传 artist 而不是 title:搜索 term 拼出来一样,但 pickBest 的"只歌手匹配"
                // 分支才会激活,优先挑该歌手演唱的歌再取 artistViewUrl —— 传 title 的话
                // 两个优选分支全死路、退化成拿第一条,恰好以歌手名为歌名的别人的歌会把
                // 跳转带偏(审阅)。
                title = ""
                artist = entry.name
            }
            guard let item = await MusicCatalogSearch.resolve(
                title: title, artist: artist, storefront: storefront) else {
                await MainActor.run { NSSound.beep() }
                return
            }
            let https: String?
            switch kind {
            case .tracks: https = item.trackViewUrl
            case .albums: https = item.collectionViewUrl ?? item.trackViewUrl
            case .artists: https = item.artistViewUrl
            }
            guard let url = MusicCatalogSearch.musicSchemeURL(https) else {
                await MainActor.run { NSSound.beep() }
                return
            }
            // Music.app 没在跑时先等它真正启动完,理由见 openCatalogPage 同一处注释。
            await MusicAutomationPermission.ensureMusicAppRunning()
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }

    /// 前往专辑/前往艺人:iTunes Search API 按 歌名+歌手+系统店面 解析目录链接,经
    /// music:// scheme 让 Music.app 原生跳页(机制与踩坑见 MusicCatalogSearch 注释)。
    /// 曲目字段由调用方传进来:停播页那几块要跳的是历史行,不是「当前播放」(停播时它是空的)。
    ///
    /// 专辑页先用缓存里这首的 Apple Music 链接(引擎按目录锚点 / 时长核对过的那一条)换算,不联网;
    /// 缓存里没有(调用方没给专辑名、这首没解析出 Apple Music 链接)才按歌名搜。艺人页、曲目页照旧搜。
    static func openCatalogPage(title: String, artist: String, album: String = "", target: CatalogTarget) {
        guard !title.isEmpty || !artist.isEmpty else { return }
        // EnrichCacheReader 是 @MainActor 的,在起后台任务之前读。
        let cachedAlbumPage = target == .album
            ? MusicCatalogSearch.albumPage(
                fromTrackURL: EnrichCacheReader.platformLinks(artist: artist, title: title, album: album)?.appleMusic?.absoluteString)
            : nil
        Task.detached(priority: .userInitiated) {
            var url = cachedAlbumPage
            if url == nil {
                let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
                guard let item = await MusicCatalogSearch.resolve(
                    title: title, artist: artist, storefront: storefront) else {
                    await MainActor.run { NSSound.beep() }
                    return
                }
                let https: String?
                switch target {
                case .album: https = item.collectionViewUrl ?? item.trackViewUrl
                case .artist: https = item.artistViewUrl
                case .track: https = item.trackViewUrl ?? item.collectionViewUrl
                }
                url = MusicCatalogSearch.musicSchemeURL(https)
            }
            // 查不到就响一声,同榜单条目:点了没反应会被当成按钮坏了。
            guard let url else {
                await MainActor.run { NSSound.beep() }
                return
            }
            // Music.app 没在跑时直接 open(music://…) 会被 LaunchServices 吞掉(冷启动走到
            // 能接 Apple Event 之前 URL 就丢了),表现成「App 打开了但停在上次退出的页面」。
            await MusicAutomationPermission.ensureMusicAppRunning()
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }
}
