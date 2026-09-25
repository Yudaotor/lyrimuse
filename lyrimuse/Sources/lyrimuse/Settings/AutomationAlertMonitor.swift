import AppKit
import LyrimuseCore

/// 菜单栏菜单顶部那一行「自动化权限未开启」的数据源。要不要提示由 `AutomationAlert`
/// (LyrimuseCore)决定,这里只负责读运行期事实。
///
/// 菜单每次弹出时同步重建,而权限查询是跨进程调用(`MusicAutomationPermission.status`,
/// 专用线程 + 超时),所以查询在后台定期做,菜单只读 `alert` 这份缓存。
@MainActor
final class AutomationAlertMonitor: ObservableObject {
    static let shared = AutomationAlertMonitor()

    struct Alert: Equatable {
        let player: PlaybackPlayer
        let grant: AutomationAlert.Grant
    }

    @Published private(set) var alert: Alert?

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var inFlight = false
    private static let interval: TimeInterval = 30

    private init() {}

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// 立刻查一次。菜单弹出时也调:这一次显示的仍是上一次的结果,结果回来后下一次弹出就是新的。
    /// 没在播、或在播的这家不需要这份权限时直接清掉,不发查询。
    func refresh() {
        guard !inFlight else { return }
        let playing = PlaybackCoordinator.shared.isPlayingNow
            ? PlaybackPlayer.builtin(forBundleID: LocalPlaybackSource.shared.lastResolvedBundleID) : nil
        guard let playing, playing.needsAutomationPermission else {
            if alert != nil { alert = nil }
            return
        }
        inFlight = true
        Task { [weak self] in
            let status = await MusicAutomationPermission.status(
                bundleID: playing.bundleIdentifier, askIfNeeded: false)
            guard let self else { return }
            self.inFlight = false
            if status == .authorized { AutomationGrantMemory.record(playing) }
            let grant = status.map(Self.grant)
            let next = AutomationAlert.player(
                toAlert: playing, grant: grant,
                everAuthorized: AutomationGrantMemory.everAuthorized(playing)
            ).flatMap { player in grant.map { Alert(player: player, grant: $0) } }
            if next != self.alert { self.alert = next }
        }
    }

    /// 菜单那一行点下去:被拒只能去系统设置改;未决(授权作废)可以直接再要一次系统弹窗。
    func resolve() {
        guard let alert else { return }
        switch alert.grant {
        case .denied:
            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
        case .undetermined, .authorized:
            PlayerAutomationPermissions.shared.request(alert.player, launchIfNeeded: false)
        }
    }

    private static func grant(_ status: MusicAutomationPermissionStatus) -> AutomationAlert.Grant {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .undetermined
        }
    }
}

/// 这台机器曾经授权过哪几个播放器的自动化权限。`AutomationAlert` 靠它区分「从没问过」和
/// 「App 更新 / 重签名后授权作废」。属于机器状态:配置导出时排除
/// (`ConfigPortability.machineLocalDefaultsKeys`)。
enum AutomationGrantMemory {
    static let defaultsKey = "np:automationEverAuthorized"

    static func record(_ player: PlaybackPlayer) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        guard ids.insert(player.rawValue).inserted else { return }
        UserDefaults.standard.set(ids.sorted(), forKey: defaultsKey)
    }

    static func everAuthorized(_ player: PlaybackPlayer) -> Bool {
        (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).contains(player.rawValue)
    }
}
