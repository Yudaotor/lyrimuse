import AppKit
import Combine
import LyrimuseCore
import OSLog
import UserNotifications

/// 系统媒体信息通道(MediaRemote,经 media-control)在本机不可用、而勾选的播放器里有没有替代路径的时候,弹一次系统通知。
///
/// 通道坏了时 Apple Music / Spotify / Kaset 会改为直接读取(`MediaControlClient.channelFallbackCandidates`),其余播放器
/// 读不到播放状态,歌词不动。原来只在设置页「播放器」那张卡下面写一句,不打开设置就不知道歌词为什么不动了。
/// 按系统版本只弹一次:通道多半是系统更新弄坏的,同一个系统版本上重启也不重弹,系统再更新一次会再提醒。
@MainActor
final class MediaChannelNotifier {
    static let shared = MediaChannelNotifier()

    /// 通知的 category / 线程 / identifier。点通知时 `UnknownPlayerNotifier` 的 delegate 按它分流到「播放器」设置页。
    static let categoryID = "media-channel"
    /// 已经弹过的那个系统版本。
    private static let notifiedOSKey = "np:mediaChannelNotifiedOS"

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
    private var cancellable: AnyCancellable?

    func start() {
        guard cancellable == nil else { return }
        cancellable = MediaControlHealth.shared.$state
            .removeDuplicates()
            .sink { [weak self] state in
                Task { @MainActor in self?.handle(state) }
            }
    }

    private func handle(_ state: MediaControlHealth.State) {
        guard case .unavailable = state else {
            if case .healthy = state {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.categoryID])
            }
            return
        }
        guard MediaControlClient.channelOutageAffects(selected: FeatureSettingsStore.shared.players) else { return }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.notifiedOSKey) != os else { return }
        defaults.set(os, forKey: Self.notifiedOSKey)
        Task { await deliver() }
    }

    private func deliver() async {
        guard await UnknownPlayerNotifier.shared.ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.t("系统媒体信息通道不可用")
        content.body = L10n.t("无法读取部分播放器的播放状态，其歌词无法随播放同步") + "\n" + L10n.t("点按此处查看受影响的播放器")
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = Self.categoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.categoryID, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.notice("announced media channel unavailable")
        } catch {
            log.error("media channel announce failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
