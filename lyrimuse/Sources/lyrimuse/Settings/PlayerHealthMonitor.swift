import AppKit
import Combine
import LyrimuseCore

/// 给设置侧栏「播放器」项供警告徽标用的轻量监视器。
///
/// 播放器页(`PlayerSettingsTab`)自己维护着四个异常态,但都是页面私有 @State、只在那一页可见
/// 时刷新——用户停在「歌词」页时对"引擎挂了"毫无感知。这里把其中两条**硬故障**提出来,
/// 外加权限卡里那两项(完全磁盘访问被拒、缺辅助功能),状态源跟权限卡同一份(`FullDiskAccessPermission` /
/// `AccessibilityPermission`,读的是引擎发布的文件与一次系统调用,主线程直接读),
/// 设置窗口开着的整个期间都盯着(`SettingsView` 的 onAppear/onDisappear 启停),判定规则在
/// Core 的 `PlayerHealth`(纯函数,selftest 钉住),这里只负责读值。
///
/// 成本:两项都**不能在主线程同步做**,一律下到后台线程,同一时刻最多一次在飞。
/// - 自动化权限查询是一次 `AEDeterminePermissionToAutomateTarget`(不弹窗)。 它不是微秒级:
///    真机 `sample` 抓栈,主线程在它底下的 `semaphore_wait_trap` 上等(跨进程问 tccd),
///    独立脚本量 10 次:min 3.25ms / 中位 4.2ms / 首次 47.5ms。每 2s 一次、任何分页都在跑,
///    正好撞上用户点击那一下就会掉一帧。
///  - 引擎状态的权威来源是 `launchctl print`,要起一个子进程。每拍先用 `EngineDaemonProbe` 看一眼
///    常驻进程(不起子进程):还是上次那个 pid、或者照旧没有进程,就沿用上次 launchd 的结论,最多沿用
///    `launchdRecheckSeconds`;进程变了(启停服务、崩溃重启)才再问。页面直接用这里发布的 `engineState`。
///
/// 只在设置窗口**看得见**时跑:`SettingsView` 按窗口可见性启停(被挡住 / 最小化时 stop,重新看得见时
/// start,start 会先补查一次)。计时器带误差,让系统合并唤醒。
/// 刻意不进监视器的两项:引擎版本比对(要起引擎子进程)、通知权限(不是播放器健康)。
@MainActor
final class PlayerHealthMonitor: ObservableObject {
    @Published private(set) var warnings: [PlayerHealth.Warning] = []
    /// 自动化权限被拒的那几家,徽标说明里点名用。
    @Published private(set) var automationDeniedPlayers: [PlaybackPlayer] = []
    /// 完全磁盘访问被拒 / 缺辅助功能的那几家,同上。
    @Published private(set) var fullDiskAccessDeniedPlayers: [PlaybackPlayer] = []
    @Published private(set) var accessibilityMissingPlayers: [PlaybackPlayer] = []
    /// 最近一次读到的引擎服务状态;nil = 还没读过。播放器页那张卡片直接用它。
    @Published private(set) var engineState: LaunchdJobState?

    /// 徽标的悬停说明;没有警告时为 nil(侧栏据此决定画不画徽标)。
    var warningText: String? {
        guard !warnings.isEmpty else { return nil }
        return warnings.map(description).joined(separator: "；")
    }

    private var timer: AnyCancellable?
    private var activationObserver: AnyCancellable?
    private var refreshInFlight = false
    /// 上一次真的问 launchd 的时刻(`systemUptime`);nil = 还没问过。
    private var lastLaunchdQueryAt: TimeInterval?
    /// 常驻进程看着没变时,launchd 的结论最多沿用这么久。
    static let launchdRecheckSeconds: TimeInterval = 60

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.publish(every: 2, tolerance: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }
        // 用户切去系统设置改权限再切回来,不等下一拍。
        activationObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer = nil
        activationObserver = nil
    }

    /// 立刻查一次(页面刚出现时调)。在飞时不重复起。引擎状态照样按 `EngineDaemonProbe` 的规则决定沿用还是再问 launchd;
    /// 要权威结论的(启停服务的按钮)自己等 `EngineServiceManager.waitForPendingOperations()`。
    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        // 主线程能直接读的先读好:要查权限的那几家 = 当前选择需要自动化权限的 ∩ 本机装了
        // (同设置页权限卡那份列表,见 `PlayerHealth.automationDeniedPlayers`)。
        let selection = FeatureSettingsStore.shared.players
        let permissions = PlayerAutomationPermissions.shared
        let targets = PlayerHealth.automationDeniedPlayers(
            selection: selection, isInstalled: permissions.isInstalled, isDenied: { _ in true })
        let engineEnabled = AppSettings.shared.engineServiceEnabled
        let fullDisk = FullDiskAccessPermission.shared
        fullDisk.refresh()
        let fullDiskVisible = fullDisk.visiblePlayers(for: selection)
        let fullDiskDenied = PlayerHealth.fullDiskAccessDeniedPlayers(visible: fullDiskVisible, grant: fullDisk.grant(fullDiskVisible))
        let accessibility = AccessibilityPermission.shared
        accessibility.refresh()
        let accessibilityMissing = PlayerHealth.accessibilityMissingPlayers(
            visible: accessibility.visiblePlayers(for: selection), trusted: accessibility.trusted)
        // 两次跨进程的查询都下到后台:launchctl 在 Task.detached 里,AE 权限走
        // `MusicAutomationPermission.status`(专用线程 + 超时,超时当"没被拒");结果回到主 actor
        // 再碰 self。askIfNeeded 必须是 false——这里绝不能弹系统授权框。
        // Task { } 继承本类的 @MainActor 隔离,weak self 在这里解包不算"并发代码里引用捕获变量"
        // (原来整段包在 Task.detached 里、在 MainActor.run 闭包内解包,编译器会告警,Swift 6 是 error)。
        let lastState = engineState
        let lastQueryAt = lastLaunchdQueryAt
        let maxAge = Self.launchdRecheckSeconds
        Task { [weak self] in
            let (engine, queriedAt) = await Task.detached(priority: .utility) { () -> (LaunchdJobState, TimeInterval?) in
                let now = ProcessInfo.processInfo.systemUptime
                if let lastState, !EngineDaemonProbe.needsLaunchdQuery(
                    last: lastState, secondsSinceQuery: lastQueryAt.map { now - $0 },
                    daemonPID: EngineDaemonProbe.daemonPID(), maxAge: maxAge) {
                    return (lastState, nil)
                }
                return (EngineServiceManager.state, now)
            }.value
            var denied: Set<PlaybackPlayer> = []
            for player in targets {
                if await MusicAutomationPermission.status(bundleID: player.bundleIdentifier, askIfNeeded: false) == .denied {
                    denied.insert(player)
                }
            }
            guard let self else { return }
            self.refreshInFlight = false
            if let queriedAt { self.lastLaunchdQueryAt = queriedAt }
            if engine != self.engineState { self.engineState = engine }
            let deniedPlayers = targets.filter { denied.contains($0) }
            if deniedPlayers != self.automationDeniedPlayers { self.automationDeniedPlayers = deniedPlayers }
            if fullDiskDenied != self.fullDiskAccessDeniedPlayers { self.fullDiskAccessDeniedPlayers = fullDiskDenied }
            if accessibilityMissing != self.accessibilityMissingPlayers { self.accessibilityMissingPlayers = accessibilityMissing }
            let latest = PlayerHealth.warnings(.init(
                automationDeniedPlayers: deniedPlayers,
                engineServiceEnabled: engineEnabled, engineRunning: engine.isRunning,
                fullDiskAccessDeniedPlayers: fullDiskDenied, accessibilityMissingPlayers: accessibilityMissing))
            if latest != self.warnings { self.warnings = latest }
        }
    }

    func description(_ warning: PlayerHealth.Warning) -> String {
        switch warning {
        case .automationDenied:
            return String(format: L10n.t("%@ 的自动化权限被拒绝，无法读取播放状态"), names(automationDeniedPlayers))
        case .engineNotRunning: return L10n.t("歌词引擎未运行，歌词不会更新")
        case .fullDiskAccessDenied:
            return String(format: L10n.t("没有完全磁盘访问权限，无法读取 %@ 的本机歌词"), names(fullDiskAccessDeniedPlayers))
        case .accessibilityMissing:
            return String(format: L10n.t("没有辅助功能权限，无法校准 %@ 的播放进度"), names(accessibilityMissingPlayers))
        }
    }

    private func names(_ players: [PlaybackPlayer]) -> String {
        let formatter = ListFormatter()
        formatter.locale = L10n.locale
        return formatter.string(from: players.map(\.displayName)) ?? ""
    }
}
