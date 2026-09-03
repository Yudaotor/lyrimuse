import AppKit
import Sparkle

// 检查更新——用 Sparkle(macOS 生态里事实标准的自动更新框架),不是自己手写"查 GitHub
// API+弹 Alert+跳转浏览器"那套(见本文件替换掉的旧 UpdateChecker.swift)。跟这个项目里
// ConfigStore.shared/AppSettings.shared 同样的单例访问风格——AppDelegate 启动时和
// "关于"页手动点的"检查更新"按钮都从这一个实例访问,不需要额外的桥接层。
//
// startingUpdater: true 让这个 controller 一初始化就启动 Sparkle 自己的 updater
// (按 Info.plist 里 SUEnableAutomaticChecks/SUFeedURL 的配置决定要不要做周期性
// 后台检查)。userDriverDelegate 传 nil——用 Sparkle 开箱即用的标准模态弹窗体验
// (SPUStandardUserDriver),**不做** "gentle reminders" 那种接管定时检查显示权的定制
// (2026-09-03 用户拍板不做:接管之后若自家提示没亮,用户直到下一版都收不到提醒,而真实
// 更新在本机又造不出来验)。
//
// updaterDelegate 自 2026-09-03 起接一个只**记状态**的桥(UpdaterDelegateBridge):Sparkle
// 发现/下载完/用户跳过/开始安装时把结论写进 `availableUpdate`,给菜单栏面板底栏那一格
// 显示「有新版本 vX.Y.Z」并一键拉起标准更新窗口用。它不改变 Sparkle 任何弹窗行为。
@MainActor
final class SparkleUpdaterManager: ObservableObject {
    static let shared = SparkleUpdaterManager()

    /// 已经查到、用户还没装上的那个新版本;nil = 没查到或已是最新。
    struct AvailableUpdate: Equatable {
        let version: String
        /// Sparkle 已把包下完(自动下载开着时),点开就是"重启安装"而不是"下载"。
        var downloaded: Bool
    }
    @Published private(set) var availableUpdate: AvailableUpdate?

    /// 当前 App 版本(Info.plist CFBundleShortVersionString,由 build.sh 写入)。
    static var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    let controller: SPUStandardUpdaterController
    private let bridge: UpdaterDelegateBridge

    private init() {
        let bridge = UpdaterDelegateBridge()
        self.bridge = bridge
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: bridge,
            userDriverDelegate: nil
        )
        // startingUpdater: true 的首次检查是异步排程的,不会在这一行之前回调,晚一步接线安全。
        bridge.onEvent = { [weak self] event in self?.handle(event) }
    }

    private func handle(_ event: UpdaterDelegateBridge.Event) {
        switch event {
        case .found(let version):
            if availableUpdate?.version != version {
                availableUpdate = AvailableUpdate(version: version, downloaded: false)
            }
        case .downloaded(let version):
            availableUpdate = AvailableUpdate(version: version, downloaded: true)
        case .notFound, .skipped, .willInstall:
            // 已是最新 / 用户点了「跳过此版本」(Sparkle 之后也不会再提它)/ 已开始安装
            // (马上重启)——三种情况底栏都不该再喊「有新版本」。
            if availableUpdate != nil { availableUpdate = nil }
        }
    }

    // 这两个开关**不**在 AppSettings 里另存一份。Sparkle 自己就把它们持久化在
    // UserDefaults(SUEnableAutomaticChecks / SUAutomaticallyUpdate),而它内部做周期
    // 检查时读的是它自己那份 —— 我们再存一份就有了两个真相,UI 显示的和实际生效的迟早
    // 对不上(比如 Sparkle 首次运行时弹的"要不要自动检查更新"对话框会直接改它那份,
    // 而我们这份完全不知情)。所以这里只做转发,objectWillChange 手动发一下让 UI 刷新。
    //
    // build.sh 写进 Info.plist 的 SUEnableAutomaticChecks 是**默认值**,用户改过之后
    // 以 UserDefaults 为准,两者不冲突。
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// ⚠️ 只在 automaticallyChecksForUpdates 为 true 时才有意义(Sparkle 的语义:
    /// 先有周期检查,才谈得上自动下载),UI 上因此把它做成从属行并跟着置灰。
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Sparkle 上次真正跑过一次检查(手动或周期)的时间;从没查过为 nil。给「关于」页「检查更新」
    /// 那一行的副标题用 —— 「自动检查」开着的人从这里能确认它真的在跑,而不是一个不知道生效没生效
    /// 的开关。Sparkle 自己把它存在 UserDefaults(SULastCheckTime),这里只是转发。
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    // 给"关于"页的手动"检查更新"按钮用——sender 传 nil 时 Sparkle 自己处理"检查中/
    // 已是最新/发现新版本"这几种状态的 UI 展示,不需要我们自己维护 loading 状态或者
    // 判断结果再手动弹 alert(旧 UpdateChecker.swift 那套手写逻辑才需要自己管这些)。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Sparkle 的 updater 委托是 ObjC 协议、回调不带 actor 隔离标注,单独一个 NSObject 来接,
/// 再把事件交回 @MainActor 的管理器。Sparkle 2 的 SPUUpdaterDelegate 回调都在主线程上,
/// assumeIsolated 成立。只实现"记状态"要用的五个回调,不改 Sparkle 任何决策
/// (不实现 mayPerformUpdateCheck / shouldProceedWithUpdate 之类会改变行为的)。
private final class UpdaterDelegateBridge: NSObject, SPUUpdaterDelegate {
    enum Event {
        case found(version: String)
        case downloaded(version: String)
        case notFound
        case skipped
        case willInstall
    }

    var onEvent: (@MainActor (Event) -> Void)?

    private func emit(_ event: Event) {
        MainActor.assumeIsolated { onEvent?(event) }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        emit(.found(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        emit(.notFound)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        emit(.downloaded(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        emit(.willInstall)
    }

    func updater(_ updater: SPUUpdater, userDidSkipThisVersion item: SUAppcastItem) {
        emit(.skipped)
    }
}
