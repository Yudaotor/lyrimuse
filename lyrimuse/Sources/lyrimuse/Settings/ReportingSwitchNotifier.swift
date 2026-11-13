import AppKit
import LyrimuseCore
import OSLog
import UserNotifications

/// 播放器在出声、却一直没往系统 Now Playing 报会话,而它自己设置里有个开关会这样(`PlayerReportingDiagnostics.reportingSwitchCauses`)
/// 时,弹一次系统通知,写明可能是哪个开关。信号由 `LocalPlaybackSource` 持续 `ReportingSwitchHintTimer.hintAfterSeconds` 后发
/// (`reportingSwitchHintNotification`)。同一个播放器同一个版本只弹一次(`shouldHintReportingSwitch`),播放器更新后再弹;
/// 点通知把那个播放器叫到前台。见 02 章决策 259。
@MainActor
final class ReportingSwitchNotifier {
    static let shared = ReportingSwitchNotifier()

    /// 通知的 category / 线程。点通知时 `UnknownPlayerNotifier` 的 delegate 按它分流。
    static let categoryID = "reporting-switch"
    /// 通知 userInfo 里实际出声的 bundle id。
    static let bundleIDKey = "bundleID"
    /// 提示过的 bundle id → 当时的播放器版本。
    private static let hintedKey = "np:reportingSwitchHinted"

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: PlayerReportingDiagnostics.reportingSwitchHintNotification, object: nil, queue: .main
        ) { note in
            guard let bundleID = note.userInfo?[PlayerReportingDiagnostics.reportingSwitchBundleIDKey] as? String else { return }
            Task { @MainActor in ReportingSwitchNotifier.shared.handle(bundleID) }
        }
    }

    /// 标题、正文。只认 `reportingSwitchCauses` 里那几个。
    static func copy(for bundleID: String) -> (title: String, body: String)? {
        switch bundleID {
        case "com.tencent.QQMusicMac":
            return (L10n.t("读不到 QQ 音乐的播放信息"), L10n.t("可能是 QQ 音乐设置里没勾选「启用媒体键/远程控制事件」"))
        case QQIPadNowPlaying.bundleID:
            return (L10n.t("读不到 QQ 音乐的播放信息"), L10n.t("可能是 QQ 音乐 iPad 版设置里开了「允许多应用同时播放」"))
        case NetEaseIPadNowPlaying.bundleID:
            return (L10n.t("读不到网易云音乐的播放信息"), L10n.t("可能是网易云音乐 iPad 版设置里开了「允许与其他应用同时播放」"))
        default:
            return nil
        }
    }

    /// 在跑的那个的版本号;读不到为空串。
    private static func version(of bundleID: String) -> String {
        let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? ""
    }

    private func handle(_ bundleID: String) {
        guard let copy = Self.copy(for: bundleID) else { return }
        let version = Self.version(of: bundleID)
        let defaults = UserDefaults.standard
        var hinted = defaults.dictionary(forKey: Self.hintedKey) as? [String: String] ?? [:]
        guard PlayerReportingDiagnostics.shouldHintReportingSwitch(bundleID: bundleID, version: version, hinted: hinted) else {
            log.notice("reporting switch hint for \(bundleID, privacy: .public) \(version, privacy: .public) already shown")
            return
        }
        hinted[bundleID] = version
        defaults.set(hinted, forKey: Self.hintedKey)
        Task { await deliver(bundleID: bundleID, version: version, title: copy.title, body: copy.body) }
    }

    private func deliver(bundleID: String, version: String, title: String, body: String) async {
        guard await UnknownPlayerNotifier.shared.ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = Self.categoryID
        content.userInfo = [Self.bundleIDKey: bundleID]
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(Self.categoryID).\(bundleID)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.notice("announced reporting switch hint for \(bundleID, privacy: .public) \(version, privacy: .public)")
        } catch {
            log.error("reporting switch hint failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 点通知:把那个播放器叫到前台(开关在它自己的设置里);没在跑就打开它。
    static func openPlayer(bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
