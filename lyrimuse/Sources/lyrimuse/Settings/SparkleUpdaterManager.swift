import AppKit
import LyrimuseCore
import OSLog
import Sparkle

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "updates")

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
//
// 2026-09-05 起这个桥多接两个**会改 Sparkle 决策**的委托,只为「接收测试版更新」这一个开关
// (AppSettings.receiveBetaUpdates,用户拍板):
//   - feedURLString(for:):开关开着 → 返回版本最高的那个 Release(含预发布)自己 tag 目录下的
//     appcast;关着 → nil,Sparkle 退回 Info.plist 的 `releases/latest/download/appcast.xml`
//     (GitHub 的 latest 不含 prerelease,所以正式用户永远看不到测试版)。
//   - allowedChannels(for:):开关开着 → {"beta"};关着 → 空集。预发布 appcast 的 item 都带
//     <sparkle:channel>beta</sparkle:channel>,这是第二道保险。
// 为什么必须自己挑 appcast、以及 Sparkle 版本比较器对 "-beta.N" 的实测行为,见 Core
// `UpdateChannel` / `ReleaseVersion` 头注与 15 章决策 11。
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
    /// Sparkle 已经开始安装更新(willInstallUpdate 回调过)—— 接下来那次进程终止是它发起的重启。
    /// 给 AppExit 在 applicationShouldTerminate 里把原因记成 sparkle_install 用。
    private(set) var isInstallingUpdate = false

    /// 「接收测试版更新」开着时 Sparkle 该读的 appcast(见文件头注);nil = 还没查到 / 查失败 / 开关关着,
    /// 都退回 Info.plist 默认地址。落一份在 UserDefaults:启动后 Sparkle 的首次周期检查可能先于
    /// Release 列表查回来,用上一次的结果总比退回正式版强。
    @Published private(set) var betaFeedURL: URL?
    private var betaFeedFetchedAt: Date?
    /// 失败 / 限流后的最早重试时刻。只在内存里:重启本来就该再试一次。
    private var betaRetryNotBefore: Date?
    private var betaInflight: Task<Void, Never>?
    private static let betaFeedURLKey = "betaFeedURL"

    /// 当前 App 版本(Info.plist CFBundleShortVersionString,由 build.sh 写入)。
    static var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    let controller: SPUStandardUpdaterController
    private let bridge: UpdaterDelegateBridge

    private init() {
        let bridge = UpdaterDelegateBridge()
        self.bridge = bridge
        if let stored = UserDefaults.standard.string(forKey: Self.betaFeedURLKey), let url = URL(string: stored) {
            betaFeedURL = url
        }
        // 两个 provider 在 controller 起 updater **之前**接好,而且**不捕获 self**(此时 controller 还没初始化,
        // Swift 不许闭包碰 self):地址直接读 UserDefaults 里那份缓存 —— fetchReleases 每次写它,关开关时删它,
        // 跟 `betaFeedURL` 这个给 UI 看的属性始终同步。这样 Sparkle 无论在哪一刻来问都答得上。
        bridge.feedURLProvider = {
            guard AppSettings.shared.receiveBetaUpdates else { return nil }
            return UserDefaults.standard.string(forKey: SparkleUpdaterManager.betaFeedURLKey)
        }
        bridge.allowedChannelsProvider = {
            AppSettings.shared.receiveBetaUpdates ? [UpdateChannel.betaChannelName] : []
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: bridge,
            userDriverDelegate: nil
        )
        // startingUpdater: true 的首次检查是异步排程的,不会在这一行之前回调,晚一步接线安全。
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        if AppSettings.shared.receiveBetaUpdates {
            Task { await refreshBetaFeed(force: false) }
        }
    }

    private func handle(_ event: UpdaterDelegateBridge.Event) {
        switch event {
        case .found(let version):
            if availableUpdate?.version != version {
                availableUpdate = AvailableUpdate(version: version, downloaded: false)
            }
        case .downloaded(let version):
            availableUpdate = AvailableUpdate(version: version, downloaded: true)
        case .willInstall:
            isInstallingUpdate = true
            if availableUpdate != nil { availableUpdate = nil }
        case .notFound, .skipped:
            // 已是最新 / 用户点了「跳过此版本」(Sparkle 之后也不会再提它)/ 已开始安装
            // (马上重启,上面那个分支)——三种情况底栏都不该再喊「有新版本」。
            if availableUpdate != nil { availableUpdate = nil }
        case .cycleFinished:
            // 一轮检查跑完顺手把 Release 列表刷新一下(按 TTL,不是每次都发),下一轮周期检查拿到的
            // 就是新的地址 —— 周期检查是 Sparkle 自己排的,没有别的钩子能在它之前刷新。
            if AppSettings.shared.receiveBetaUpdates {
                Task { await refreshBetaFeed(force: false) }
            }
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
    //
    // 开着「接收测试版」时先(按 TTL)把 Release 列表刷一遍再交给 Sparkle:地址是它开始检查那一刻
    // 同步来问的,不先刷就可能拿着一小时前的答案去查。刷新最多等 10 秒(URLRequest 超时),
    // 失败就用缓存 / 默认地址,不会卡死这颗按钮。
    func checkForUpdates() {
        guard AppSettings.shared.receiveBetaUpdates else {
            controller.checkForUpdates(nil)
            return
        }
        Task {
            await refreshBetaFeed(force: false)
            controller.checkForUpdates(nil)
        }
    }

    /// AppSettings.receiveBetaUpdates 的 didSet 调进来:开 → 立刻查一遍 Release 列表并在后台跑一次检查
    /// (checkForUpdatesInBackground 只在真有更新时才弹窗),让开关有即时反馈;关 → 清掉地址缓存,
    /// 下一次检查回到默认的 latest。关掉不会把已装的测试版退回正式版 —— Sparkle 只往高版本走,
    /// 要等下一个版本号更高的正式版。
    func betaChannelPreferenceChanged(enabled: Bool) {
        if enabled {
            Task {
                await refreshBetaFeed(force: true)
                controller.updater.checkForUpdatesInBackground()
            }
        } else {
            betaFeedURL = nil
            betaFeedFetchedAt = nil
            UserDefaults.standard.removeObject(forKey: Self.betaFeedURLKey)
            logger.notice("beta channel off, feed back to default")
        }
    }

    /// 查一次 Release 列表、更新 `betaFeedURL`。判据(要不要发、怎么解析、挑哪一份)全在 Core `UpdateChannel`,
    /// 这里只剩 URLSession、审计日志、缓存。请求形状与限流退避照 GitHubStarsService 那套。
    private func refreshBetaFeed(force: Bool) async {
        if !force, !UpdateChannel.shouldRefresh(now: Date(), fetchedAt: betaFeedFetchedAt, retryNotBefore: betaRetryNotBefore) {
            return
        }
        if let betaInflight {
            await betaInflight.value
            return
        }
        let task = Task { await self.fetchReleases() }
        betaInflight = task
        await task.value
        betaInflight = nil
    }

    private func fetchReleases() async {
        let url = UpdateChannel.releasesAPIURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lyrimuse/\(Self.appVersionString)", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode
            NetworkAuditLog.record(service: "github", operation: "releases", host: url.host ?? "api.github.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            if status == 403 || status == 429 {
                betaRetryNotBefore = GitHubStars.retryDate(now: Date(), rateLimitReset: http?.value(forHTTPHeaderField: "X-RateLimit-Reset"))
                logger.notice("releases: http \(status ?? -1, privacy: .public), backing off")
                return
            }
            guard status == 200, let releases = UpdateChannel.parseReleases(data) else {
                betaRetryNotBefore = Date().addingTimeInterval(UpdateChannel.failureBackoff)
                logger.notice("releases: http \(status ?? -1, privacy: .public) or parse failed, keeping cached feed")
                return
            }
            betaFeedFetchedAt = Date()
            betaRetryNotBefore = nil
            let chosen = UpdateChannel.betaFeedURL(releases: releases)
            if chosen != betaFeedURL {
                betaFeedURL = chosen
                if let chosen {
                    UserDefaults.standard.set(chosen.absoluteString, forKey: Self.betaFeedURLKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.betaFeedURLKey)
                }
            }
            logger.info("releases: newest=\(UpdateChannel.newestRelease(releases)?.tag ?? "-", privacy: .public) feed=\(chosen?.lastPathComponent ?? "default", privacy: .public)")
        } catch {
            NetworkAuditLog.record(service: "github", operation: "releases", host: url.host ?? "api.github.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            betaRetryNotBefore = Date().addingTimeInterval(UpdateChannel.failureBackoff)
        }
    }
}

/// Sparkle 的 updater 委托是 ObjC 协议、回调不带 actor 隔离标注,单独一个 NSObject 来接,
/// 再把事件交回 @MainActor 的管理器。Sparkle 2 的 SPUUpdaterDelegate 回调都在主线程上,
/// assumeIsolated 成立。
///
/// 实现的回调分两类:「记状态」五个(found / notFound / downloaded / willInstall / skipped)加一个
/// 「一轮跑完」(didFinishUpdateCycle,只用来触发 Release 列表按 TTL 刷新);「改决策」两个
/// (feedURLString / allowedChannels),只为「接收测试版更新」那个开关,具体语义见文件头注。
/// 仍然**不实现** mayPerformUpdateCheck / shouldProceedWithUpdate 之类会拦截 Sparkle 流程的。
private final class UpdaterDelegateBridge: NSObject, SPUUpdaterDelegate {
    enum Event {
        case found(version: String)
        case downloaded(version: String)
        case notFound
        case skipped
        case willInstall
        case cycleFinished
    }

    var onEvent: (@MainActor (Event) -> Void)?
    /// 返回 nil = 让 Sparkle 用 Info.plist / defaults 里的默认地址。
    var feedURLProvider: (@MainActor () -> String?)?
    var allowedChannelsProvider: (@MainActor () -> Set<String>)?

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

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        emit(.cycleFinished)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feedURLProvider?() ?? nil }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { allowedChannelsProvider?() ?? [] }
    }
}
