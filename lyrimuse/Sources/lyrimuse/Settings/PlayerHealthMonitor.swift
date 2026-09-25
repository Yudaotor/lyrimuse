import AppKit
import Combine
import LyrimuseCore

/// 给设置侧栏「播放器」项供警告徽标用的轻量监视器。
///
/// 播放器页(`PlayerSettingsTab`)自己维护着四个异常态,但都是页面私有 @State、只在那一页可见
/// 时刷新——用户停在「歌词」页时对"collector 挂了"毫无感知。这里把其中两条**硬故障**提出来,
/// 设置窗口开着的整个期间都盯着(`SettingsView` 的 onAppear/onDisappear 启停),判定规则在
/// Core 的 `PlayerHealth`(纯函数,selftest 钉住),这里只负责读值。
///
/// 成本:两项都**不能在主线程同步做**,一律下到后台线程,同一时刻最多一次在飞。
/// - 自动化权限查询是一次 `AEDeterminePermissionToAutomateTarget`(不弹窗)。 它不是微秒级:
///    真机 `sample` 抓栈,主线程在它底下的 `semaphore_wait_trap` 上等(跨进程问 tccd),
///    独立脚本量 10 次:min 3.25ms / 中位 4.2ms / 首次 47.5ms。每 2s 一次、任何分页都在跑,
///    正好撞上用户点击那一下就会掉一帧。
///  - collector 状态要起一个 `launchctl print` 子进程。播放器页原来自己也每 2s 起一次、查的是同一件事;
///    现在页面直接用这里发布的 `collectorState`,整个设置窗口只剩这一路。
///
/// 只在设置窗口**看得见**时跑:`SettingsView` 按窗口可见性启停(被挡住 / 最小化时 stop,重新看得见时
/// start,start 会先补查一次)。计时器带误差,让系统合并唤醒。
/// 刻意不进监视器的两项:collector 版本比对(要起 collector 子进程)、通知权限(不是播放器健康)。
@MainActor
final class PlayerHealthMonitor: ObservableObject {
    @Published private(set) var warnings: [PlayerHealth.Warning] = []
    /// 自动化权限被拒的那几家,徽标说明里点名用。
    @Published private(set) var automationDeniedPlayers: [PlaybackPlayer] = []
    /// 最近一次读到的 collector 服务状态;nil = 还没读过。播放器页那张卡片直接用它。
    @Published private(set) var collectorState: LaunchdJobState?

    /// 徽标的悬停说明;没有警告时为 nil(侧栏据此决定画不画徽标)。
    var warningText: String? {
        guard !warnings.isEmpty else { return nil }
        return warnings.map(description).joined(separator: "；")
    }

    private var timer: AnyCancellable?
    private var activationObserver: AnyCancellable?
    private var refreshInFlight = false

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

    /// 立刻查一次(页面刚出现、刚启停过服务时调)。在飞时不重复起。
    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        // 主线程能直接读的先读好:要查权限的那几家 = 当前选择需要自动化权限的 ∩ 本机装了
        // (同设置页权限卡那份列表,见 `PlayerHealth.automationDeniedPlayers`)。
        let selection = FeatureSettingsStore.shared.players
        let permissions = PlayerAutomationPermissions.shared
        let targets = PlayerHealth.automationDeniedPlayers(
            selection: selection, isInstalled: permissions.isInstalled, isDenied: { _ in true })
        let collectorEnabled = AppSettings.shared.collectorServiceEnabled
        // 两次跨进程的查询都下到后台:launchctl 在 Task.detached 里,AE 权限走
        // `MusicAutomationPermission.status`(专用线程 + 超时,超时当"没被拒");结果回到主 actor
        // 再碰 self。askIfNeeded 必须是 false——这里绝不能弹系统授权框。
        // Task { } 继承本类的 @MainActor 隔离,weak self 在这里解包不算"并发代码里引用捕获变量"
        // (原来整段包在 Task.detached 里、在 MainActor.run 闭包内解包,编译器会告警,Swift 6 是 error)。
        Task { [weak self] in
            let collector = await Task.detached(priority: .utility) {
                CollectorServiceManager.state
            }.value
            var denied: Set<PlaybackPlayer> = []
            for player in targets {
                if await MusicAutomationPermission.status(bundleID: player.bundleIdentifier, askIfNeeded: false) == .denied {
                    denied.insert(player)
                }
            }
            guard let self else { return }
            self.refreshInFlight = false
            if collector != self.collectorState { self.collectorState = collector }
            let deniedPlayers = targets.filter { denied.contains($0) }
            if deniedPlayers != self.automationDeniedPlayers { self.automationDeniedPlayers = deniedPlayers }
            let latest = PlayerHealth.warnings(.init(
                automationDeniedPlayers: deniedPlayers,
                collectorServiceEnabled: collectorEnabled, collectorRunning: collector.isRunning))
            if latest != self.warnings { self.warnings = latest }
        }
    }

    func description(_ warning: PlayerHealth.Warning) -> String {
        switch warning {
        case .automationDenied:
            let names = ListFormatter()
            names.locale = L10n.locale
            let list = names.string(from: automationDeniedPlayers.map(\.displayName)) ?? ""
            return String(format: L10n.t("%@ 的自动化权限被拒，读不到播放状态"), list)
        case .collectorNotRunning: return L10n.t("后台采集服务未运行，歌词不会更新")
        }
    }
}
