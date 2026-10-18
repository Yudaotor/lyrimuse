import AppKit
import Combine
import LyrimuseCore
import OSLog
import UserNotifications

/// ListenBrainz 令牌被拒(引擎停发、收听进待重发队列)时的系统通知,做法同 `LastfmMirrorNotifier`。
///
/// 红标只在设置里,不打开就不知道从哪天起没在提交了;待重发队列攒满之后最老的会被挪进留档、不再自动重发。
/// 同一次被拒(按状态文件里的 `since`)只弹一次,重启也不重弹;恢复后撤掉通知中心里那条。
@MainActor
final class ListenBrainzAuthNotifier {
    static let shared = ListenBrainzAuthNotifier()

    /// 通知的 category / 线程 / identifier。点通知时 `UnknownPlayerNotifier` 的 delegate 按它分流到 ListenBrainz 设置页。
    static let categoryID = "listenbrainz-auth"
    /// 已经弹过的那一次被拒的 `since`。
    private static let notifiedSinceKey = "np:listenBrainzAuthNotifiedSince"

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
    private var cancellable: AnyCancellable?

    func start() {
        guard cancellable == nil else { return }
        cancellable = ListenBrainzSubmitStatusWatcher.shared.$info
            .removeDuplicates()
            .sink { [weak self] info in
                Task { @MainActor in self?.handle(info) }
            }
    }

    private func handle(_ info: ListenBrainzSubmitStatus.Info?) {
        guard let info else {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.categoryID])
            return
        }
        let defaults = UserDefaults.standard
        guard (defaults.object(forKey: Self.notifiedSinceKey) as? NSNumber)?.int64Value != info.since else { return }
        defaults.set(NSNumber(value: info.since), forKey: Self.notifiedSinceKey)
        Task { await deliver() }
    }

    private func deliver() async {
        guard await UnknownPlayerNotifier.shared.ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "ListenBrainz"
        content.body = L10n.t("令牌已失效，收听提交已暂停") + "\n" + L10n.t("点按此处前往设置重新连接")
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = Self.categoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.categoryID, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.notice("announced listenbrainz token rejected")
        } catch {
            log.error("listenbrainz token announce failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
