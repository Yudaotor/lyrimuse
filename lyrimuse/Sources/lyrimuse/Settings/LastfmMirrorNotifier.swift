import AppKit
import Combine
import LyrimuseCore
import OSLog
import UserNotifications

/// Last.fm 授权失效(引擎熔断、停止打卡)时的系统通知。
///
/// 红标只在菜单栏面板和设置里,不打开就不知道从哪天起没在打卡了。引擎没有通知权限,它只写状态文件
/// (`LastfmMirrorStatus`);这里从 App 启动起盯着 `LastfmMirrorStatusWatcher`,看到一次新的熔断就投递。
/// 同一次熔断(按状态文件里的 `at`)只弹一次,重启也不重弹;恢复后撤掉通知中心里那条。
@MainActor
final class LastfmMirrorNotifier {
    static let shared = LastfmMirrorNotifier()

    /// 通知的 category / 线程 / identifier。点通知时 `UnknownPlayerNotifier` 的 delegate 按它分流到 Last.fm 设置页。
    static let categoryID = "lastfm-mirror"
    /// 已经弹过的那一次熔断的 `at`。
    private static let notifiedAtKey = "np:lastfmMirrorNotifiedAt"

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
    private var cancellable: AnyCancellable?

    func start() {
        guard cancellable == nil else { return }
        cancellable = LastfmMirrorStatusWatcher.shared.$info
            .removeDuplicates()
            .sink { [weak self] info in
                Task { @MainActor in self?.handle(info) }
            }
    }

    private func handle(_ info: LastfmMirrorStatus.Info?) {
        guard let info else {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.categoryID])
            return
        }
        let defaults = UserDefaults.standard
        guard (defaults.object(forKey: Self.notifiedAtKey) as? NSNumber)?.int64Value != info.at else { return }
        defaults.set(NSNumber(value: info.at), forKey: Self.notifiedAtKey)
        Task { await deliver() }
    }

    private func deliver() async {
        guard await UnknownPlayerNotifier.shared.ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Last.fm"
        content.body = L10n.t("授权已失效，Scrobble 已暂停") + "\n" + L10n.t("点这里到设置里重新连接")
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = Self.categoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.categoryID, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.notice("announced lastfm mirror disabled")
        } catch {
            log.error("lastfm mirror announce failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
