import AppKit
import Combine
import LyrimuseCore

/// 给设置侧栏「播放器」项供警告徽标用的轻量监视器(2026-09-03)。
///
/// 播放器页(`PlayerSettingsTab`)自己维护着四个异常态,但都是页面私有 @State、只在那一页可见
/// 时刷新——用户停在「歌词」页时对"collector 挂了"毫无感知。这里把其中两条**硬故障**提出来,
/// 设置窗口开着的整个期间都盯着(`SettingsView` 的 onAppear/onDisappear 启停),判定规则在
/// Core 的 `PlayerHealth`(纯函数,selftest 钉住),这里只负责读值。
///
/// 成本:两项都**不能在主线程同步做**,一律下到后台线程,同一时刻最多一次在飞。
///  - 自动化权限查询是一次 `AEDeterminePermissionToAutomateTarget`(不弹窗)。⚠️ 这里原来写的
///    是「微秒级」—— **错的**。2026-09-03 真机 `sample` 抓栈:主线程在它底下的
///    `semaphore_wait_trap` 上等(跨进程问 tccd),设置窗开着 60 秒里 116 个采样、关着时 0 个;
///    独立脚本量 10 次:min 3.25ms / 中位 4.2ms / 首次 47.5ms。每 2s 一次、任何分页都在跑,
///    正好撞上用户点击那一下就是一帧掉帧 —— 对应用户报的「切分页**有时候**卡」。
///  - collector 状态要起一个 `launchctl print` 子进程——播放器页可见时本来就每 2s 起一次,
///    这里沿用同一节拍。
/// 刻意不进监视器的两项:collector 版本比对(要起 collector 子进程)、通知权限(不是播放器健康)。
@MainActor
final class PlayerHealthMonitor: ObservableObject {
    @Published private(set) var warnings: [PlayerHealth.Warning] = []

    /// 徽标的悬停说明;没有警告时为 nil(侧栏据此决定画不画徽标)。
    var warningText: String? {
        guard !warnings.isEmpty else { return nil }
        return warnings.map(Self.description).joined(separator: "；")
    }

    private var timer: AnyCancellable?
    private var activationObserver: AnyCancellable?
    private var refreshInFlight = false

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
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

    private func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        // 主线程能直接读的两项先读好(纯内存)。
        let appleMusicSelected = FeatureSettingsStore.shared.players.contains(.appleMusic)
        let collectorEnabled = AppSettings.shared.collectorServiceEnabled
        // 两次跨进程的查询(AE 权限 + launchctl)都下到后台;结果回到主 actor 再碰 self。
        // askIfNeeded 必须是 false——这里绝不能弹系统授权框。
        // Task { } 继承本类的 @MainActor 隔离,weak self 在这里解包不算"并发代码里引用捕获变量"
        // (原来整段包在 Task.detached 里、在 MainActor.run 闭包内解包,编译器会告警,Swift 6 是 error)。
        Task { [weak self] in
            let (automationDenied, collectorRunning) = await Task.detached(priority: .utility) {
                (MusicAutomationPermission.check(askIfNeeded: false) == .denied,
                 CollectorServiceManager.isRunning)
            }.value
            guard let self else { return }
            self.refreshInFlight = false
            let latest = PlayerHealth.warnings(.init(
                appleMusicSelected: appleMusicSelected, automationDenied: automationDenied,
                collectorServiceEnabled: collectorEnabled, collectorRunning: collectorRunning))
            if latest != self.warnings { self.warnings = latest }
        }
    }

    static func description(_ warning: PlayerHealth.Warning) -> String {
        switch warning {
        case .automationDenied: return L10n.t("Apple Music 自动化权限被拒，读不到播放状态")
        case .collectorNotRunning: return L10n.t("后台采集服务未运行，歌词不会更新")
        }
    }
}
