import AppKit
import Combine
import LyrimuseCore
import OSLog

private let discordLogger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "discord")

/// Discord「正在听」:把正在放的歌写进 Discord 的状态(资料卡、好友列表)。默认关。
///
/// 规则在 `LyrimuseCore.DiscordPresence`(组 activity、暂停宽限)与 `DiscordPresenceGate`(节流、去重),连接在
/// `DiscordPresenceLink`(后台队列);这里是管道:盯播放协调器和设置,算出此刻该显示什么,经节流交给连接。
/// 只在连上之后发:开关打开时、连接断了时各连一次,之后每 `retryInterval` 试连一次;Discord 刚启动的那一阵每
/// `fastConnectInterval` 连一次。装没装、开没开只按 bundle id 问 LaunchServices(`DiscordPresence.desktopBundleIDs`),
/// 不枚举进程。App 退出时连接随之断开,Discord 自己清掉状态。
@MainActor
final class DiscordPresenceController: ObservableObject {
    static let shared = DiscordPresenceController()

    enum Status: Equatable {
        /// 功能关着。
        case off
        /// 开着,还没连上 Discord:卡在哪一步见 `DiscordPresence.Waiting`。
        case waiting(DiscordPresence.Waiting)
        case connected(user: DiscordUser?)
        /// Discord 拒绝了连接。
        case refused
    }

    @Published private(set) var status: Status = .off {
        didSet {
            if case .waiting(.connecting) = status {
                if connectingSince == nil { connectingSince = Date() }
            } else {
                connectingSince = nil
                if connectingStalled { connectingStalled = false }
            }
        }
    }
    /// Discord 开着,却过了 `stallThreshold` 还没连上(多半没登录):设置页据此提示登录或重开 Discord。
    @Published private(set) var connectingStalled = false
    private var connectingSince: Date?

    /// 没连上时多久再试一次,也是确认连接还在的间隔。
    static let retryInterval: TimeInterval = 30
    /// 换歌后等要联网的那几档封面最多这么久再发:第一份尽量就带上封面,问得慢也不卡住。
    static let coverWait: TimeInterval = 3
    /// 中继上暂时还没有这张(引擎在播放后才传)时,隔多久再问一次中继;最多再问 `relayRechecks` 次。
    static let relayRecheckInterval: TimeInterval = 20
    static let relayRechecks = 3
    /// Discord 刚启动时要过几秒才接受连接:这一阵每隔这么久连一次,连上或过了 `fastConnectWindow` 为止。
    static let fastConnectInterval: TimeInterval = 2
    static let fastConnectWindow: TimeInterval = 60
    /// Discord 开着、过了这么久还没连上,算卡住了。
    static let stallThreshold: TimeInterval = 20

    private lazy var link = DiscordPresenceLink(
        socketPaths: {
            DiscordIPC.socketPaths(in: [NSTemporaryDirectory(), ProcessInfo.processInfo.environment["TMPDIR"] ?? ""])
        },
        onStatus: { [weak self] linkStatus in
            Task { @MainActor in self?.linkStatusChanged(linkStatus) }
        },
        log: { message in discordLogger.notice("\(message, privacy: .public)") })
    private var gate = DiscordPresenceGate()
    private var observers: [AnyCancellable] = []
    /// 这一段暂停从什么时候开始;在放时为 nil。预览按它判暂停宽限期。
    private(set) var pausedSince: Date?
    /// 当前播放器归哪个 Discord 应用(`DiscordPresence.applicationID(forBundleID:webPlatformID:)`);连接、重连都按它。
    private var applicationID = DiscordPresence.applicationID
    /// 关掉一次加一,之前发出去的回执晚到时认得出来、不再算数。
    private var generation = 0
    /// 最近一份交给 Discord 的(`wanted`)和它实际显示的(`shown`:原样收下的、被拒后补发的精简版,或者都被拒、清掉了的 nil)。
    /// 节流判重认交出去的那份(不然被拒的那份每 4 秒重发一次),预览照实际显示的画。没连上、连接断了为 nil。
    private var delivered: (wanted: DiscordActivity?, shown: DiscordActivity?)?
    private var wakeTask: Task<Void, Never>?
    /// 当前这首的封面有到点要做的事(没问成的到点重查、中继上还没有的到点再问)时,到点叫一次刷新(`scheduleCoverWake`)。
    private var coverWakeTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var fastConnectTask: Task<Void, Never>?
    private var extras: TrackExtras?
    /// 要联网那几档封面的查询,按这首记住,一首只跑一次(见 `PresenceCover`)。
    private var coverLookups: [String: CoverLookup] = [:]
    /// 「暂时隐藏」到这个时刻(`hide(minutes:)`);没在隐藏时为 nil。记在 `hiddenUntilKey` 里,App 重启后接着隐藏。
    /// 见 12 章决策 43。
    @Published private(set) var hiddenUntil: Date?
    private var unhideTask: Task<Void, Never>?
    static let hiddenUntilKey = "np:discordHiddenUntil"

    func start() {
        guard observers.isEmpty else { return }
        let stored = UserDefaults.standard.double(forKey: Self.hiddenUntilKey)
        setHidden(until: stored > 0 ? Date(timeIntervalSince1970: stored) : nil)
        let playback = PlaybackCoordinator.shared
        let source = LocalPlaybackSource.shared
        let settings = AppSettings.shared
        // 暂停的时刻不防抖,宽限从真暂停那一刻算。
        observers.append(playback.$isPlayingSmoothed.removeDuplicates().sink { [weak self] playing in
            self?.pausedSince = playing ? nil : Date()
        })
        // 换歌时歌名、歌手、专辑先后各发一次,攒一下再算。
        let changes: [AnyPublisher<Void, Never>] = [
            signal(playback.$title), signal(playback.$artist), signal(playback.$displayArtist),
            signal(playback.$displayAlbum), signal(playback.$isPlayingSmoothed), signal(playback.$anchor),
            signal(playback.$isCurrentTrackAdBreak), signal(playback.$isRadioTalkBreak),
            signal(source.$spotifyArtworkURL), signal(source.$webPageArtworkURL), signal(source.$webPageVideoFrameURL),
            signal(source.$enrichContentVersion),
            signal(ConfigStore.shared.$stateRelayURL),
            signal(settings.$discordPresenceEnabled), signal(settings.$discordStatusDisplay),
            signal(settings.$discordKeepWhenPaused), signal(settings.$discordExcludedBundles),
            signal(settings.$discordBadge),
        ]
        // 去抖挂主队列、别挂 RunLoop.main:菜单开着时它不走,换歌后的状态要等菜单关了才更新(见 01 章决策 11)。
        observers.append(Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .filter(Self.isDiscordDesktop)
            .sink { [weak self] _ in self?.discordLaunched() })
        observers.append(workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .filter(Self.isDiscordDesktop)
            .sink { [weak self] _ in self?.discordTerminated() })
        refresh()
    }

    private func signal<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
        publisher.map { _ in () }.eraseToAnyPublisher()
    }

    private func refresh() {
        wakeTask?.cancel()
        wakeTask = nil
        let settings = AppSettings.shared
        guard settings.discordPresenceEnabled else {
            turnOff()
            return
        }
        let now = Date()
        if let hiddenUntil, now >= hiddenUntil {
            discordLogger.notice("hide ended on refresh, \(Int(now.timeIntervalSince(hiddenUntil)), privacy: .public)s late")
            setHidden(until: nil)
        }
        // 隐藏着时不组曲目,也就不去查封面。
        let track = hiddenUntil == nil ? currentTrack(now: now) : nil
        if status == .off {
            status = .waiting(desktopWaiting())
            link.connectIfNeeded(clientID: applicationID)
        }
        startRetryLoop()
        if track != nil {
            scheduleCoverWake(now: now)
        } else {
            coverWakeTask?.cancel()
            coverWakeTask = nil
        }
        if track != nil, let until = coverPendingUntil(now: now) {
            wake(at: until)
            return
        }
        let intent = DiscordPresence.intent(track: track, pausedSince: pausedSince,
                                            statusLine: settings.discordStatusDisplay,
                                            keepWhenPaused: settings.discordKeepWhenPaused,
                                            badge: settings.discordBadge, pausedText: L10n.t("已暂停"),
                                            pausedNameFormat: L10n.t("%@（已暂停）"),
                                            hiddenUntil: hiddenUntil, now: now)
        switch gate.decide(intent, now: now) {
        case .none:
            break
        case .wait(let until):
            wake(at: until)
        case .send(let activity):
            // 没连上不发:连接由开关、断线和重试那一拍负责,连上时会再算一遍。
            guard case .connected = status else { return }
            gate.didSend(activity, at: now)
            discordLogger.debug("presence \(activity == nil ? "clear" : "show", privacy: .public)")
            let sentGeneration = generation
            link.send(activity) { [weak self] delivery in
                Task { @MainActor in self?.sendFinished(delivery, wanted: activity, generation: sentGeneration) }
            }
        }
    }

    /// Discord 上现在挂着的那一份:连着时最近一次交给 Discord 的,被拒过的按它实际显示的(补发的精简版;都被拒、清掉了为 nil);
    /// 清空过、这条连接上还没发过、没连上为 nil。预览在暂停宽限期里画它:那段时间 Discord 上还是暂停前发出去的那份。
    var sentActivity: DiscordActivity? {
        guard case .connected = status, case .some(let sent) = gate.lastSent else { return nil }
        if let delivered, DiscordPresenceGate.sameContent(delivered.wanted, sent) { return delivered.shown }
        return sent
    }

    /// 这一份交给 Discord 时被拒过:返回它实际显示的那份(补发的精简版;都被拒、清掉了是 `.some(nil)`)。没被拒、或者最近
    /// 交出去的不是这一份时为 nil,照它本身画。预览用。
    func shownOnDiscord(insteadOf activity: DiscordActivity) -> DiscordActivity?? {
        guard case .connected = status, let delivered, delivered.shown != delivered.wanted,
              DiscordPresenceGate.sameContent(delivered.wanted, activity) else { return nil }
        return .some(delivered.shown)
    }

    /// 连接层回报这一份的结局。被拒过的记下实际显示的那份;断了的忘掉上次发的,连上后重发。
    private func sendFinished(_ delivery: DiscordPresenceLink.Delivery, wanted: DiscordActivity?,
                              generation sentGeneration: Int) {
        guard sentGeneration == generation else { return }
        switch delivery {
        case .shown(let shown):
            delivered = (wanted, shown)
            if shown != wanted {
                discordLogger.notice("presence refused, Discord shows \(shown == nil ? "nothing" : "the plain version", privacy: .public)")
            }
        case .lost:
            delivered = nil
            gate.forget()
        }
    }

    private func linkStatusChanged(_ linkStatus: DiscordPresenceLink.Status) {
        guard AppSettings.shared.discordPresenceEnabled else { return }
        let wasConnected: Bool
        if case .connected = status { wasConnected = true } else { wasConnected = false }
        switch linkStatus {
        case .connected(let user):
            fastConnectTask?.cancel()
            fastConnectTask = nil
            status = .connected(user: user)
            // 连上之后才去查要联网的那几档封面(没连上查了也用不上),这一首重算一遍。
            refresh()
        case .disconnected:
            gate.forget()
            delivered = nil
            status = .waiting(desktopWaiting())
            // 连着的时候断了(Discord 退出或重启):马上重连一次,重启的话不用等下一拍。
            if wasConnected { link.connectIfNeeded(clientID: applicationID) }
        case .rejected:
            gate.forget()
            delivered = nil
            status = .refused
        }
    }

    private func turnOff() {
        retryTask?.cancel()
        retryTask = nil
        fastConnectTask?.cancel()
        fastConnectTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        coverWakeTask?.cancel()
        coverWakeTask = nil
        guard status != .off else { return }
        generation += 1
        link.disconnect(clearing: true)
        gate = DiscordPresenceGate()
        delivered = nil
        status = .off
    }

    private func wake(at date: Date) {
        let delay = max(0, date.timeIntervalSinceNow) + 0.05
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func startRetryLoop() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.retryInterval))
                guard !Task.isCancelled else { return }
                self?.retryTick()
            }
        }
    }

    private func retryTick() {
        link.check()
        link.connectIfNeeded(clientID: applicationID)
        // 装上、打开、退出 Discord 不一定都有通知(从别处直接运行的副本就没有),每一拍顺手对一下。
        if case .waiting = status { status = .waiting(desktopWaiting()) }
        markStalledIfDue()
        refresh()
    }

    // MARK: - 暂时隐藏

    /// 从现在起 `minutes` 分钟内 Discord 上不显示,到点自己恢复。
    func hide(minutes: Int) {
        discordLogger.notice("hide for \(minutes, privacy: .public) min")
        setHidden(until: Date().addingTimeInterval(TimeInterval(max(1, minutes) * 60)))
        refresh()
    }

    /// 提前恢复显示。
    func unhide() {
        guard hiddenUntil != nil else { return }
        setHidden(until: nil)
        refresh()
    }

    /// 改隐藏到几点、记下来,到点那一拍恢复。已经过了的当没在隐藏。
    private func setHidden(until: Date?) {
        unhideTask?.cancel()
        unhideTask = nil
        guard let until, until > Date() else {
            if hiddenUntil != nil { hiddenUntil = nil }
            UserDefaults.standard.removeObject(forKey: Self.hiddenUntilKey)
            return
        }
        hiddenUntil = until
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.hiddenUntilKey)
        unhideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)), tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            discordLogger.notice("hide ended")
            self?.unhide()
        }
    }

    /// 「几点恢复」:跟界面语言走的时刻(22:13、10:13 PM)。
    static func restoreTimeText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: L10n.locale))
    }

    /// 隐藏时长的写法(15 分钟、1 小时),跟界面语言走。
    static func hideDurationText(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(L10n.locale))
    }

    // MARK: - Discord 桌面版

    /// 「打开 Discord」:打开装了的那个 Discord 桌面版,之后那一阵勤快点连。
    func openDiscord() {
        guard let url = desktopAppURL() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { discordLogger.error("open Discord failed: \(error.localizedDescription, privacy: .public)") }
        }
        startFastConnect()
    }

    /// 「重新连接」:Discord 开着却一直连不上时,马上再连一轮,卡住的提示先收起来。
    func reconnectNow() {
        guard case .waiting(.connecting) = status else { return }
        connectingSince = Date()
        connectingStalled = false
        link.connectIfNeeded(clientID: applicationID)
        startFastConnect()
    }

    private func discordLaunched() {
        guard AppSettings.shared.discordPresenceEnabled else { return }
        if case .waiting = status { status = .waiting(.connecting) }
        startFastConnect()
    }

    /// Discord 退出了:马上确认连接还在不在(断了会经 `linkStatusChanged` 报上来),没连着的直接改成「没打开」。
    private func discordTerminated() {
        guard AppSettings.shared.discordPresenceEnabled else { return }
        fastConnectTask?.cancel()
        fastConnectTask = nil
        link.check()
        if case .waiting = status { status = .waiting(desktopWaiting()) }
    }

    private func startFastConnect() {
        fastConnectTask?.cancel()
        fastConnectTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.fastConnectWindow)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(Self.fastConnectInterval))
                guard !Task.isCancelled, let self, AppSettings.shared.discordPresenceEnabled else { return }
                if case .connected = self.status { return }
                self.link.connectIfNeeded(clientID: self.applicationID)
                self.markStalledIfDue()
            }
        }
    }

    private func markStalledIfDue() {
        guard !connectingStalled, let since = connectingSince,
              Date().timeIntervalSince(since) >= Self.stallThreshold else { return }
        connectingStalled = true
    }

    private func desktopAppURL() -> URL? {
        DiscordPresence.desktopBundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    private func desktopWaiting() -> DiscordPresence.Waiting {
        let running = DiscordPresence.desktopBundleIDs.contains { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
        }
        return DiscordPresence.waiting(installed: desktopAppURL() != nil, running: running)
    }

    nonisolated private static func isDiscordDesktop(_ notification: Notification) -> Bool {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier.map(DiscordPresence.desktopBundleIDs.contains) ?? false
    }

    // MARK: - 此刻的曲目

    private func currentTrack(now: Date) -> DiscordPresence.Track? {
        guard let track = makeTrack(now: now, lookingUp: true) else { return nil }
        applicationID = track.applicationID
        return track
    }

    /// Discord 页预览用:此刻会发的那一首。不发起封面查询,也不改连接用的应用。
    func previewTrack(now: Date) -> DiscordPresence.Track? {
        makeTrack(now: now, lookingUp: false)
    }

    private func makeTrack(now: Date, lookingUp: Bool) -> DiscordPresence.Track? {
        let playback = PlaybackCoordinator.shared
        guard !playback.title.isEmpty, !playback.isCurrentTrackAdBreak, !playback.isRadioTalkBreak else { return nil }
        let reported = LocalPlaybackSource.shared.lastResolvedBundleID
        let host = BrowserPositionProbe.probeTargetBundleID(forReported: reported)
        if let host, AppSettings.shared.discordExcludedBundles.contains(host) { return nil }
        let extras = trackExtras(reportedBundleID: reported)
        let anchor = playback.anchor
        return DiscordPresence.Track(
            title: playback.title, artist: playback.displayArtist, album: playback.displayAlbum,
            playerName: playerName(host: host),
            coverURL: coverURL(for: extras, now: now, lookingUp: lookingUp), songURL: extras.songURL,
            // Apple Music 的歌手页缓存里没有,用按曲目 ID 查封面时顺带拿到的那个。
            artistURL: extras.artistURL ?? coverLookups[extras.coverKey]?.hit?.artistPage,
            positionMs: anchor.flatMap { $0.rate > 0 ? $0.extrapolatedPositionMs(now: now) : nil },
            durationMs: anchor?.durationMs ?? playback.currentDurationMs,
            applicationID: DiscordPresence.applicationID(forBundleID: reported, webPlatformID: playback.resolvedWebPlatformID))
    }

    /// 「正在听」后面的名字(`DiscordPresence.listeningName`):认得出的播放器、网页平台用界面上那个名字,信任列表里的 App
    /// 用存下的名字。
    private func playerName(host: String?) -> String? {
        let displayName: String? = {
            if let name = PlaybackCoordinator.shared.resolvedPlayerDisplayName { return name }
            guard let host else { return nil }
            if let stored = FeatureSettingsStore.shared.trustedPlayers[host], !stored.isEmpty { return stored }
            return FeatureSettingsStore.appDisplayName(forBundleID: host)
        }()
        return DiscordPresence.listeningName(bundleID: host, displayName: displayName)
    }

    // MARK: - 封面

    /// 这首的链接和不用联网的那几档封面(见 `PresenceCover` 的分档)。按这首的身份、缓存版本、播放器给的地址记一份,
    /// 别每次刷新都查缓存。
    private struct TrackExtras {
        let key: String
        let songURL: URL?
        let artistURL: URL?
        /// 第 1 档:当前播放器自己给的封面地址。
        let ownCover: URL?
        /// 第 4 档:设备封面在网上的同一张图、同一首在别的播放器记下的、缓存里认专辑的封面。
        let localCover: URL?
        /// 要联网的那几档;第 1 档有了、或者没有一样能查时为 nil。
        let coverRequest: PresenceCover.Request?
        /// 第 6 档:放的是视频(Kaset、YouTube Music 网页版)、没有专辑图时这支视频的截图;第 1 档有了为 nil。
        let videoFrame: URL?
        /// 这首在 `coverLookups` 里的键。
        let coverKey: String
    }

    private func trackExtras(reportedBundleID: String?) -> TrackExtras {
        let source = LocalPlaybackSource.shared
        let webPlatform = PlaybackCoordinator.shared.resolvedWebPlatformID
        let kasetCover = source.kasetArtworkURL
        let kasetVideo = source.kasetVideoID
        let videoFrame = source.kasetVideoFrameURL ?? source.webPageVideoFrameURL
        let appleTrackID = source.appleCatalogTrackID
        let relayBase = ConfigStore.shared.stateRelayURL
        let key = [reportedBundleID ?? "", webPlatform ?? "", source.artist, source.title, source.album,
                   source.enrichContentVersion.map { String($0.timeIntervalSince1970) } ?? "",
                   source.spotifyArtworkURL?.absoluteString ?? "", kasetCover?.absoluteString ?? "", kasetVideo ?? "",
                   source.webPageArtworkURL?.absoluteString ?? "", videoFrame?.absoluteString ?? "",
                   appleTrackID.map { String($0) } ?? "", relayBase]
            .joined(separator: "\n")
        if let extras, extras.key == key { return extras }
        let links = EnrichCacheReader.platformLinks(artist: source.artist, title: source.title, album: source.album)
        let song = links?.songWebLink(forPlayerBundleID: reportedBundleID, webPlatformID: webPlatform)
            ?? kasetVideo.flatMap { PlatformLinks.youtubeMusicWatchURL("https://music.youtube.com/watch?v=" + $0) }
        let playerCovers = EnrichCacheReader.playerCoverURLs(artist: source.artist, title: source.title, album: source.album)
        let own = source.spotifyArtworkURL ?? kasetCover ?? source.webPageArtworkURL
            ?? reportedBundleID.flatMap { playerCovers[$0] }
        // 缓存里的 cover_url 常是设备直送、存在本机的文件:不是 https 的不直接用,只拿来换中继上的地址。
        let cached = EnrichCacheReader.albumMatchedCoverURL(artist: source.artist, title: source.title, album: source.album)
        let otherPlayer = playerCovers.filter { $0.key != reportedBundleID }.sorted { $0.key < $1.key }.first?.value
        // 设备封面在网上的同一张图排最前:引擎核对过它跟缓存里这张设备封面是同一张图,没配中继也用得上。
        let publicCopy = EnrichCacheReader.publicCoverURL(artist: source.artist, title: source.title, album: source.album)
        let local = publicCopy ?? otherPlayer ?? (cached?.scheme?.lowercased() == "https" ? cached : nil)
        var request: PresenceCover.Request?
        if own == nil {
            let region = Locale.current.region?.identifier
            let albumRef = EnrichCacheReader.appleAlbumRef(artist: source.artist, title: source.title, album: source.album)
            let displayArtist = PlaybackCoordinator.shared.displayArtist
            let candidate = PresenceCover.Request(
                relayURL: RelayArtwork.publicURL(relayBase: relayBase, coverURL: cached),
                appleTrackID: appleTrackID, trackStorefronts: PresenceCover.trackStorefronts(region: region),
                albumRef: albumRef,
                albumStorefronts: AlbumEditorialNotes.storefronts(region: region, linkStorefront: albumRef?.storefront),
                artist: displayArtist.isEmpty ? source.artist : displayArtist, title: source.title, album: source.album,
                searchStorefront: region?.lowercased() ?? "us", wantsFallback: local == nil)
            request = candidate.isEmpty ? nil : candidate
        }
        let fresh = TrackExtras(
            key: key, songURL: song,
            artistURL: links?.artistWebLink(forPlayerBundleID: reportedBundleID, webPlatformID: webPlatform),
            ownCover: own, localCover: local, coverRequest: request, videoFrame: own == nil ? videoFrame : nil,
            coverKey: [reportedBundleID ?? "", source.artist, source.title, source.album].joined(separator: "\n"))
        extras = fresh
        return fresh
    }

    /// 这首用哪张封面。要联网的那几档只在连上 Discord 之后发起,查到了或者问成了却没有,这一首就不再查;没问成的
    /// (iTunes 冷却中、超时、限流)到 `CoverLookup.retryAt` 再查一轮;中继上暂时还没有的过一会儿再问。
    /// `lookingUp` 为 false 时只用已经查到的。
    private func coverURL(for extras: TrackExtras, now: Date, lookingUp: Bool) -> URL? {
        if lookingUp, extras.ownCover == nil, let request = extras.coverRequest, case .connected = status {
            if let lookup = coverLookups[extras.coverKey] {
                if lookup.finished, lookup.hit == nil, let retryAt = lookup.retryAt, now >= retryAt {
                    startCoverLookup(key: extras.coverKey, request: request, attempt: lookup.attempt + 1)
                } else {
                    recheckRelayIfDue(lookup, relay: request.relayURL, now: now)
                }
            } else {
                startCoverLookup(key: extras.coverKey, request: request, attempt: 0)
            }
        }
        return PresenceCover.pick(own: extras.ownCover, hit: coverLookups[extras.coverKey]?.hit, local: extras.localCover,
                                  videoFrame: extras.videoFrame)
    }

    /// 这首的封面第一轮还在查、没超过 `coverWait`:到这个时刻之前先不发。补查的那几轮不等:这一首早就发过了。
    private func coverPendingUntil(now: Date) -> Date? {
        guard let extras, extras.ownCover == nil, let lookup = coverLookups[extras.coverKey], !lookup.finished,
              lookup.attempt == 0 else {
            return nil
        }
        let until = lookup.startedAt.addingTimeInterval(Self.coverWait)
        return until > now ? until : nil
    }

    /// 当前这首的封面有到点要做的事 —— 没问成的那一轮到点重查(`CoverLookup.retryAt`)、中继上还没有的到点再问
    /// (`relayRecheckAt`)—— 时,到点叫一次刷新,不靠 30 秒那一拍顺带(那样要晚到最多 30 秒)。只看还没到点的:到了点的
    /// 这一拍 `coverURL` 已经办了。没连上、这首自己给了封面、没有要联网的那几档时不叫。
    private func scheduleCoverWake(now: Date) {
        coverWakeTask?.cancel()
        coverWakeTask = nil
        guard case .connected = status, let extras, extras.ownCover == nil, let request = extras.coverRequest,
              let lookup = coverLookups[extras.coverKey], lookup.finished else { return }
        var due: [Date] = []
        if lookup.hit == nil, let retryAt = lookup.retryAt { due.append(retryAt) }
        if request.relayURL != nil, lookup.hit?.tier != .relay, !lookup.relayChecking, lookup.relayChecksLeft > 0,
           let recheck = lookup.relayRecheckAt {
            due.append(recheck)
        }
        guard let at = due.filter({ $0 > now }).min() else { return }
        coverWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow) + 0.05))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// `attempt`:这一首第几轮查(第一轮是 0)。补查那一轮整条换掉上一轮的记录。
    private func startCoverLookup(key: String, request: PresenceCover.Request, attempt: Int) {
        if coverLookups.count >= 300 {
            coverLookups = coverLookups.filter { !$0.value.finished }
        }
        let lookup = CoverLookup(relayURL: request.relayURL, attempt: attempt)
        coverLookups[key] = lookup
        Task { [weak self] in
            let result = await PresenceCover.lookUp(request)
            lookup.finished = true
            if lookup.hit == nil { lookup.hit = result.hit }
            if result.relayMissing { lookup.relayRecheckAt = Date().addingTimeInterval(Self.relayRecheckInterval) }
            if result.unreached, lookup.hit == nil {
                lookup.retryAt = PresenceCover.retryAt(attempt: attempt, now: Date(),
                                                       cooldownEnds: ITunesSearchGate.shared.cooldownEnds())
            }
            let outcome = result.hit.map { "\($0.tier)" } ?? (result.unreached ? "unreached" : "none")
            discordLogger.debug("cover lookup #\(attempt, privacy: .public) \(outcome, privacy: .public)")
            self?.refresh()
        }
    }

    /// 中继上的本机封面晚到(缓存里的设备封面是这一轮查完之后才落下的),或者上次问时中继上还没有这张:再问一次中继。
    private func recheckRelayIfDue(_ lookup: CoverLookup, relay: URL?, now: Date) {
        guard lookup.finished, !lookup.relayChecking, lookup.hit?.tier != .relay, let relay else { return }
        if lookup.relayURL != relay {
            lookup.relayURL = relay
            lookup.relayChecksLeft = Self.relayRechecks
            lookup.relayRecheckAt = now
        }
        guard let due = lookup.relayRecheckAt, now >= due, lookup.relayChecksLeft > 0 else { return }
        lookup.relayChecksLeft -= 1
        lookup.relayChecking = true
        Task { [weak self] in
            let found = await RelayArtwork.exists(relay)
            lookup.relayChecking = false
            if found == true {
                lookup.hit = PresenceCover.Hit(url: relay, tier: .relay, artistPage: lookup.hit?.artistPage)
                lookup.relayRecheckAt = nil
                self?.refresh()
            } else if found == false {
                lookup.relayRecheckAt = Date().addingTimeInterval(Self.relayRecheckInterval)
                // 到点再问一次:刷新那一拍按它安排唤醒(`scheduleCoverWake`)。
                self?.refresh()
            } else {
                lookup.relayRecheckAt = nil
            }
        }
    }

    /// 一首歌那几档要联网的封面查到哪了。
    @MainActor
    private final class CoverLookup {
        let startedAt = Date()
        var finished = false
        var hit: PresenceCover.Hit?
        /// 问过的中继地址;缓存里的设备封面晚到时会变。
        var relayURL: URL?
        /// 中继上还没有这张时,到这个时刻再问;还能再问几次。
        var relayRecheckAt: Date?
        var relayChecksLeft = DiscordPresenceController.relayRechecks
        var relayChecking = false
        /// 这一首第几轮查(第一轮是 0)。
        let attempt: Int
        /// 这一轮没问成(不是那边没有)时,到这个时刻再查一轮(`PresenceCover.retryAt`)。
        var retryAt: Date?

        init(relayURL: URL?, attempt: Int) {
            self.relayURL = relayURL
            self.attempt = attempt
        }
    }
}
