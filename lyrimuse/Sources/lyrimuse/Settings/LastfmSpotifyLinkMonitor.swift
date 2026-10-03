import AppKit
import Combine
import Foundation
import LyrimuseCore
import OSLog
import UserNotifications

/// 盯 Last.fm 账号在 Last.fm 网站上连没连 Spotify(判据与状态在 `LastfmSpotifyLink`),得出此刻该提示哪一种(`hint`):
/// Last.fm 账号页的「建议」分组、侧栏「Last.fm 账号建议」那一行和它的页面都据它。「Scrobble 的播放器」那一排里有 Spotify、
/// Spotify 被排除了、连接又过期时另外弹一次系统通知 —— 那时 Spotify 上放的歌两边都不记,别处看不出来。
///
/// 只在连着 Last.fm、开着 Scrobble 时查。启动 1 分钟后查第一次,之后每小时看一眼,`LastfmSpotifyLink.checkDue` 说该查才发
/// 请求(距上次查成超过一天、换了账号、或按上次的结论此刻该弹通知);打开 Last.fm 账号页时距上次超过一小时也查一次。查不成
/// 保留上一次的结论。同一次过期只弹一次,重启不重弹;不再成立时撤掉通知中心里那条。点了建议里去 Last.fm 网站的按钮之后,
/// 10 分钟内每次回到 App 都重查一次(`recheckWhenBack`),在那边断开或重连完回来,提示就跟着变。
@MainActor
final class LastfmSpotifyLinkMonitor: ObservableObject {
    static let shared = LastfmSpotifyLinkMonitor()

    /// 通知的 category / 线程 / identifier。点通知时 `UnknownPlayerNotifier` 的 delegate 按它分流到 Last.fm 设置页。
    nonisolated static let categoryID = "lastfm-spotify-link"
    /// 已经弹过的那一次过期的到期时间(秒)。
    private static let announcedKey = "np:lastfmSpotifyExpiryAnnounced"
    private static let firstCheckDelay: Duration = .seconds(60)
    private static let tickInterval: TimeInterval = 3600
    private static let dailyMaxAge: TimeInterval = 86_400
    private static let settingsMaxAge: TimeInterval = 3600
    private static let recheckWindow: TimeInterval = 600

    struct Check: Equatable {
        let user: String
        let expiry: Date?
        let at: Date
    }

    /// 最近一次查成的结果。
    @Published private(set) var lastCheck: Check?
    /// 此刻该提示哪一种;不用提示时为 nil。查询结果、勾选、播放器选择、Scrobble 开关、账号任一变化都重算,每小时那一拍
    /// 也重算(到期是按时间推算的)。
    @Published private(set) var hint: LastfmSpotifyLink.PlayersRowHint?

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lastfm")
    private var timer: Timer?
    private var inflight = false
    private var settingsObserver: AnyCancellable?
    private var activationObserver: AnyCancellable?
    /// 这个时刻之前,每次回到 App 都重查一次。
    private var recheckUntil: Date?

    /// 当前账号此刻的连接状态。没连 Last.fm、关着 Scrobble、或还没查成过时为 nil。
    var link: LastfmSpotifyLink? {
        guard let check = lastCheck, check.user == currentUser() else { return nil }
        return LastfmSpotifyLink(expiry: check.expiry, now: Date())
    }

    /// Spotify 在不在「Scrobble 的播放器」那一排里(跟设置页同一套候选)。不在就既不提示也不弹通知。
    static func spotifyListed() -> Bool {
        let features = FeatureSettingsStore.shared
        return PlayerLinkage.listed(selectedPlayers: features.players, installed: InstalledPlayersCache.current())
            .contains(.spotify)
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue(maxAge: Self.dailyMaxAge) }
        }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            self?.checkIfDue(maxAge: Self.dailyMaxAge)
        }
        // 勾选、播放器选择、Scrobble 开关、账号一变:提示跟着重算,通知不成立了就撤。objectWillChange 在改之前发,延一拍再读。
        settingsObserver = FeatureSettingsStore.shared.objectWillChange
            .merge(with: ConfigStore.shared.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshHint()
                    self?.syncNotification(announce: false)
                }
            }
        activationObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.appBecameActive() }
            }
    }

    /// 建议里那两个去 Last.fm 网站的按钮点下去时调。
    func recheckWhenBack() {
        recheckUntil = Date().addingTimeInterval(Self.recheckWindow)
    }

    private func appBecameActive() {
        guard let until = recheckUntil else { return }
        guard Date() < until else {
            recheckUntil = nil
            return
        }
        checkIfDue(maxAge: 0)
    }

    /// 打开 Last.fm 账号页时调。
    func refreshIfStale() {
        checkIfDue(maxAge: Self.settingsMaxAge)
    }

    private func checkIfDue(maxAge: TimeInterval) {
        defer { refreshHint() }
        guard let user = currentUser() else {
            if lastCheck != nil { lastCheck = nil }
            removeDelivered()
            return
        }
        let now = Date()
        let previous = lastCheck?.user == user ? lastCheck : nil
        let wouldAnnounce = previous.map { announcement(for: LastfmSpotifyLink(expiry: $0.expiry, now: now)) != nil } ?? false
        guard !inflight,
              LastfmSpotifyLink.checkDue(lastChecked: previous?.at, now: now, maxAge: maxAge, wouldAnnounce: wouldAnnounce)
        else { return }
        inflight = true
        Task { [weak self] in
            let fetched = await LastfmStatsService.shared.fetchUserInfo()
            guard let self else { return }
            self.inflight = false
            guard let fetched, fetched.user == user, self.currentUser() == user else { return }
            let check = Check(user: user, expiry: LastfmSpotifyLink.expiry(user: fetched.info), at: Date())
            if previous?.expiry != check.expiry || previous == nil {
                let stamp = check.expiry.map { String(Int64($0.timeIntervalSince1970)) } ?? "none"
                self.log.notice("lastfm spotify link checked expiry=\(stamp, privacy: .public)")
            }
            self.lastCheck = check
            self.refreshHint()
            self.syncNotification(announce: true)
        }
    }

    private func currentUser() -> String? {
        guard !ConfigStore.shared.lastfmScrobbleSessionKey.isEmpty,
              FeatureSettingsStore.shared.lastfmMirrorScrobble else { return nil }
        return LastfmStatsService.shared.credentialUser
    }

    private func refreshHint() {
        let next = Self.spotifyListed() ? link?.playersRowHint(spotifyExcluded: spotifyExcluded) : nil
        if next != hint { hint = next }
    }

    /// 那一排里有 Spotify、而且被排除了。
    private var spotifyExcluded: Bool {
        Self.spotifyListed()
            && FeatureSettingsStore.shared.lastfmExcludedBundles.contains(PlaybackPlayer.spotify.bundleIdentifier)
    }

    private func announcement(for link: LastfmSpotifyLink) -> Int64? {
        let announced = (UserDefaults.standard.object(forKey: Self.announcedKey) as? NSNumber)?.int64Value
        return link.expiryToAnnounce(spotifyExcluded: spotifyExcluded, announced: announced)
    }

    /// 通知跟着当前结论走:不成立了(重连了、又勾上了 Spotify)就撤掉;成立、这次过期还没弹过、而且是刚查成的结论
    /// (`announce`)才弹。还没查成过时维持现状:「不知道」不等于「不成立」,启动时别把上次弹的那条撤了。
    private func syncNotification(announce: Bool) {
        guard let link else { return }
        guard case .expiredWhileExcluded = link.playersRowHint(spotifyExcluded: spotifyExcluded) else {
            removeDelivered()
            return
        }
        guard announce, let stamp = announcement(for: link) else { return }
        UserDefaults.standard.set(NSNumber(value: stamp), forKey: Self.announcedKey)
        Task { await deliver() }
    }

    private func removeDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.categoryID])
    }

    private func deliver() async {
        guard await UnknownPlayerNotifier.shared.ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Last.fm"
        content.body = L10n.t("与 Spotify 的连接已过期，Spotify 上放的歌没有记到 Last.fm") + "\n" + L10n.t("点这里到设置里查看")
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = Self.categoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.categoryID, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.notice("announced lastfm spotify link expired")
        } catch {
            log.error("lastfm spotify link announce failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension LastfmSpotifyLink.PlayersRowHint {
    /// 那一行建议的标题。
    var headline: String {
        switch self {
        case .doubleScrobble: return L10n.t("Spotify 每首会记两次")
        case .expiredWhileExcluded: return L10n.t("Spotify 上放的歌没有记到 Last.fm")
        }
    }
}
