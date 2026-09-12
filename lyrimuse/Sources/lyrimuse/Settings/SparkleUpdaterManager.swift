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
// 2026-09-12 起 updater 由这里直接建(`SPUUpdater(hostBundle:applicationBundle:userDriver:delegate:)`),
// 用户界面走自己的 `SoftwareUpdateDriver`:发现 / 下载 / 待装 / 安装中 / 失败全部画在设置窗口的
// 「软件更新」页(Settings/SoftwareUpdatePage.swift),一个 Sparkle 弹窗都不弹 —— 用户拍板照系统设置那页做,
// 见 14 章决策 #25。改版前是 `SPUStandardUpdaterController` + 标准模态窗(2026-09-03 当时决定不接管界面,
// 理由是"接管之后若自家提示没亮用户就收不到提醒";现在的兜底是:周期检查发现更新会亮侧栏「有软件更新可用」
// 与菜单栏面板底栏两处,Sparkle 自己的周期检查节拍一点没动)。Info.plist 里 SUEnableAutomaticChecks /
// SUFeedURL 仍决定要不要做周期性后台检查、读哪份 appcast。
//
// 页面那半边的状态机(`flow` / `pendingItem` / 攥着的 reply 闭包)见下面「软件更新页」一节;要点是**谁在等**:
//   - 周期检查(没人在页面上等)发现更新 → 记下来给侧栏 / 页面显示,立刻 dismiss 让 Sparkle 收工;
//   - 页面上点「检查更新」→ 找到后攥着 reply,「立即更新」才答 install,窗口关掉答 dismiss;
//   - 页面上点「立即更新 / 立即重启」而手里没有 reply(周期检查早就 dismiss 过)→ 再发一次检查,找到时自动答 install。
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
/// 「软件更新」页的进行态(2026-09-12)。只描述"正在发生什么";"有没有查到新版本"另看 `pendingItem`。
enum SoftwareUpdateFlow: Equatable {
    case idle
    case checking
    /// expected 为 nil = Sparkle 还没报总长度,画不定长进度条。
    case downloading(received: UInt64, expected: UInt64?)
    case extracting(progress: Double)
    case readyToInstall
    case installing(applicationTerminated: Bool)
    case failed(message: String)

    /// 窗口关掉也该继续跑的阶段(下载 / 解包 / 安装),关窗时不动它。
    var isBusyInBackground: Bool {
        switch self {
        case .downloading, .extracting, .installing: return true
        case .idle, .checking, .readyToInstall, .failed: return false
        }
    }
}

/// 「软件更新」页要显示的一次更新:从 Sparkle 的 `SUAppcastItem` 抄下页面要用的几项。
struct SoftwareUpdateItem: Equatable {
    let version: String
    /// enclosure 的字节数;0 = appcast 没写。
    let contentLength: UInt64
    let date: Date?
    /// 发版日志:appcast `<description>` 的 HTML(Sparkle 已按系统语言从两份 xml:lang 里挑好),或
    /// releaseNotesLink 下载回来的正文。
    var notesHTML: String?
    /// 说明是纯文本(appcast 标了 plain-text,或外挂说明是 text/plain),不走 HTML 解析。
    var notesArePlainText: Bool
    /// ⓘ 打开的页面:appcast 的 fullReleaseNotesLink / link,都没有就按 tag 拼 GitHub Release 页。
    let releaseURL: URL
    /// Sparkle 已把包下完解好(自动下载开着时的周期检查,或用户点过「退出时安装」),下一步就是重启安装。
    var downloaded: Bool

    init(appcastItem item: SUAppcastItem, downloaded: Bool) {
        version = item.displayVersionString
        contentLength = item.contentLength
        date = item.date
        notesHTML = item.itemDescription
        notesArePlainText = item.itemDescriptionFormat == "plain-text"
        releaseURL = item.fullReleaseNotesURL ?? item.infoURL
            ?? UpdateChannel.releasePageURL(displayVersion: item.displayVersionString)
        self.downloaded = downloaded
    }

    init(version: String, contentLength: UInt64, date: Date?, notesHTML: String?, notesArePlainText: Bool,
         releaseURL: URL, downloaded: Bool) {
        self.version = version
        self.contentLength = contentLength
        self.date = date
        self.notesHTML = notesHTML
        self.notesArePlainText = notesArePlainText
        self.releaseURL = releaseURL
        self.downloaded = downloaded
    }

    /// 预览钩子用的假条目(见 SparkleUpdaterManager.previewUpdateVersionKey):说明正文明说是预览。
    static func preview(version: String) -> SoftwareUpdateItem {
        SoftwareUpdateItem(version: version, contentLength: 12_800_000, date: Date(),
                           notesHTML: "<p>" + L10n.t("这是预览：真有新版本时这里显示发版日志") + "</p>",
                           notesArePlainText: false,
                           releaseURL: UpdateChannel.releasePageURL(displayVersion: version), downloaded: false)
    }
}

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

    // MARK: - 软件更新页(2026-09-12)

    /// 页面上正在发生的事。`.idle` 时看 `pendingItem`:有 = 查到了新版本等用户动手,没有 = 已是最新 / 还没查过。
    @Published private(set) var flow: SoftwareUpdateFlow = .idle
    /// Sparkle 最近一次查到、还没装上的那个版本(给「软件更新」页显示标题 / 大小 / 日期 / 发版日志)。
    /// 「已是最新」「跳过」「装好重启」都清掉。跟上面 `availableUpdate` 是同一件事的两个视角:那个给菜单栏
    /// 面板底栏(只要版本号),这个给页面(要全部细节)。
    @Published private(set) var pendingItem: SoftwareUpdateItem?
    /// 用户在「下完待装」那一步选了「退出时安装」,或周期检查已经把包下好(自动下载开着)—— Sparkle 会在
    /// App 退出时装,页面据此说明,并把按钮换成「立即重启」。
    @Published private(set) var installOnQuit = false
    /// 重启后 Sparkle 报「上一版装好了」时记下当前版本,页面说一句「已更新到 X」;只在这一次进程内有效。
    @Published private(set) var updatedToVersion: String?

    /// Sparkle 现在接不接受一次新检查(有会话在跑就不接受)。
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    /// 预览钩子(2026-09-12,用户要「模拟一下看看效果」):这台机器上
    /// `defaults write me.yudaotor.lyrimuse settings:previewUpdateVersion 1.7.0` 之后,设置窗口
    /// (侧栏「有软件更新可用」那行、「软件更新」页、「关于」页的副标题)就当真查到了 1.7.0 一样显示;
    /// `defaults delete … settings:previewUpdateVersion` 即恢复,重开设置窗口生效。只读 UserDefaults、
    /// 不碰 Sparkle,页面上的「立即更新」仍是真检查(会如实显示「已是最新版本」)。菜单栏面板底栏不吃
    /// 这个钩子,只认真值。用 `settings:` 前缀:机器状态,配置导出天然不带走(同 SettingsTab.lastTabStorageKey)。
    static let previewUpdateVersionKey = "settings:previewUpdateVersion"

    private var previewItem: SoftwareUpdateItem? {
        guard let version = UserDefaults.standard.string(forKey: Self.previewUpdateVersionKey),
              !version.isEmpty else { return nil }
        return SoftwareUpdateItem.preview(version: version)
    }

    /// 设置窗口该显示的「有新版本」:预览钩子优先,否则是 Sparkle 的真值。
    var shownItem: SoftwareUpdateItem? { previewItem ?? pendingItem }

    /// 页面上最近一次动作的意图,决定 Sparkle 回「找到了」时怎么答(见文件头注)。
    private enum PageIntent { case none, check, install }
    private var pageIntent: PageIntent = .none
    /// 攥着的 Sparkle 闭包。每个最多攥一份,答过 / 取消过就置 nil。
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var cancelCheck: (() -> Void)?
    private var cancelDownload: (() -> Void)?
    private var retryTerminating: (() -> Void)?

    /// 「立即更新」/「立即重启」。手里有 Sparkle 在等的 reply 就直接答 install;没有(周期检查早就 dismiss 过了)
    /// 就再发一次检查,found 里按 `.install` 意图自动答 —— 已经下好的包 Sparkle 会直接进安装。
    func installPendingUpdate() {
        if let reply = foundReply {
            foundReply = nil
            flow = pendingItem?.downloaded == true ? .readyToInstall : .downloading(received: 0, expected: nil)
            reply(.install)
            return
        }
        if let reply = readyReply {
            readyReply = nil
            reply(.install)
            return
        }
        guard canCheckForUpdates else { return }
        pageIntent = .install
        flow = .checking
        startCheck()
    }

    /// 「退出时安装」:包已经下好,Sparkle 在 App 退出时装(dismiss 在这一步的语义,见 SPUUserDriver.h)。
    func installOnQuitInstead() {
        guard let reply = readyReply else { return }
        readyReply = nil
        installOnQuit = true
        flow = .idle
        reply(.dismiss)
    }

    /// 「取消」:检查中 / 下载中可取消;其余阶段没有这颗按钮。
    func cancel() {
        switch flow {
        case .checking:
            cancelCheck?()
            cancelCheck = nil
            pageIntent = .none
            flow = .idle
        case .downloading:
            cancelDownload?()
            cancelDownload = nil
            // Sparkle 随后回 dismissed,那边再收尾;这里先把进度条撤掉。
            flow = .idle
        default:
            break
        }
    }

    /// 安装时 App 没能退出(被什么拦住了),再试一次。
    func retryTerminatingForInstall() {
        retryTerminating?()
    }

    /// 设置窗口关掉了:攥着的「找到了」不能一直不答(Sparkle 的会话会一直挂着,周期检查也进不来)——答 dismiss,
    /// 版本信息留着,下次打开页面照样显示;「下完待装」同理答 dismiss = 退出时安装。检查中的就取消。
    func settingsWindowClosed() {
        if let reply = foundReply {
            foundReply = nil
            reply(.dismiss)
        }
        if let reply = readyReply {
            readyReply = nil
            installOnQuit = true
            reply(.dismiss)
        }
        if case .checking = flow {
            cancelCheck?()
            cancelCheck = nil
            pageIntent = .none
        }
        if flow != .idle, !flow.isBusyInBackground { flow = .idle }
    }

    /// 把设置窗口翻到「软件更新」页并叫出来(信箱 + subject 两条路,见 AppActions.requestSettings)。
    func showUpdatePage() {
        AppActions.shared.requestSettings(.softwareUpdate)
        AppActions.shared.openSettings?()
    }

    private func clearSessionClosures() {
        foundReply = nil
        readyReply = nil
        cancelCheck = nil
        cancelDownload = nil
        retryTerminating = nil
    }

    private func handleDriver(_ event: SoftwareUpdateDriver.Event) {
        switch event {
        case .permissionRequest(let reply):
            // 首次运行「要不要自动检查」的问询:不弹窗,按设置页那个开关的当前值答;不发系统档案。
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticallyChecksForUpdates, sendSystemProfile: false))
        case .userInitiatedCheck(let cancel):
            cancelCheck = cancel
            flow = .checking
        case .found(let item, let state, let reply):
            cancelCheck = nil
            let downloaded = state.stage != .notDownloaded
            var next = SoftwareUpdateItem(appcastItem: item, downloaded: downloaded)
            // 同一版再次被找到时,上一次 releaseNotesLink 下回来的正文别丢。
            if next.notesHTML == nil, let kept = pendingItem, kept.version == next.version {
                next.notesHTML = kept.notesHTML
                next.notesArePlainText = kept.notesArePlainText
            }
            pendingItem = next
            updatedToVersion = nil
            switch pageIntent {
            case .install:
                pageIntent = .none
                flow = downloaded ? .readyToInstall : .downloading(received: 0, expected: nil)
                reply(.install)
            case .check:
                pageIntent = .none
                flow = .idle
                // 攥着不答:页面上「立即更新」才答 install,窗口关掉答 dismiss。
                foundReply = reply
            case .none:
                // 周期检查,没人在页面上等:记下来给侧栏 / 页面显示,立刻 dismiss 让 Sparkle 结束这一轮。
                // 自动下载开着时 stage 已是 downloaded,dismiss 之后 Sparkle 会在退出时装,页面据 installOnQuit 说明。
                flow = .idle
                if downloaded { installOnQuit = true }
                reply(.dismiss)
            }
        case .releaseNotes(let download):
            guard var item = pendingItem else { return }
            let encoding = Self.encoding(ianaName: download.textEncodingName)
            item.notesHTML = String(data: download.data, encoding: encoding) ?? String(decoding: download.data, as: UTF8.self)
            item.notesArePlainText = (download.mimeType ?? "").hasPrefix("text/plain")
            pendingItem = item
        case .releaseNotesFailed(let error):
            logger.notice("release notes download failed: \(error.localizedDescription, privacy: .public)")
        case .notFound(_, let acknowledge):
            cancelCheck = nil
            foundReply = nil
            pageIntent = .none
            pendingItem = nil
            installOnQuit = false
            flow = .idle
            acknowledge()
        case .failed(let error, let acknowledge):
            clearSessionClosures()
            pageIntent = .none
            flow = .failed(message: error.localizedDescription)
            acknowledge()
        case .downloadStarted(let cancel):
            cancelDownload = cancel
            flow = .downloading(received: 0, expected: nil)
        case .downloadExpectedLength(let expected):
            if case .downloading(let received, _) = flow {
                flow = .downloading(received: received, expected: expected)
            } else {
                flow = .downloading(received: 0, expected: expected)
            }
        case .downloadReceived(let length):
            if case .downloading(let received, let expected) = flow {
                flow = .downloading(received: received + length, expected: expected)
            }
        case .extractionStarted:
            cancelDownload = nil
            flow = .extracting(progress: 0)
        case .extractionProgress(let progress):
            flow = .extracting(progress: progress)
        case .readyToInstall(let reply):
            readyReply = reply
            pendingItem?.downloaded = true
            installOnQuit = false
            flow = .readyToInstall
        case .installing(let applicationTerminated, let retry):
            retryTerminating = retry
            isInstallingUpdate = true
            flow = .installing(applicationTerminated: applicationTerminated)
        case .installedAndRelaunched(_, let acknowledge):
            // 重启后的第一个回调:上一版装好了。页面说一句「已更新到 X」;此时手里不该还有任何待装的版本。
            updatedToVersion = Self.appVersionString
            pendingItem = nil
            installOnQuit = false
            flow = .idle
            acknowledge()
        case .dismissed:
            clearSessionClosures()
            if case .installing = flow { return }
            flow = .idle
        case .focusRequested:
            showUpdatePage()
        }
    }

    private static func encoding(ianaName: String?) -> String.Encoding {
        guard let name = ianaName else { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
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

    let updater: SPUUpdater
    private let driver: SoftwareUpdateDriver
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
        let driver = SoftwareUpdateDriver()
        self.driver = driver
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: bridge)
        self.updater = updater
        // start 排的首次周期检查是异步的,不会在下面两行之前回调,先建再接线安全。
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        driver.onEvent = { [weak self] event in self?.handleDriver(event) }
        do {
            try updater.start()
        } catch {
            logger.error("updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
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
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// ⚠️ 只在 automaticallyChecksForUpdates 为 true 时才有意义(Sparkle 的语义:
    /// 先有周期检查,才谈得上自动下载),UI 上因此把它做成从属行并跟着置灰。
    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Sparkle 上次真正跑过一次检查(手动或周期)的时间;从没查过为 nil。给「关于」页「检查更新」
    /// 那一行的副标题用 —— 「自动检查」开着的人从这里能确认它真的在跑,而不是一个不知道生效没生效
    /// 的开关。Sparkle 自己把它存在 UserDefaults(SULastCheckTime),这里只是转发。
    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    /// 用户发起的「检查更新」(「软件更新」页的按钮、菜单栏右键菜单、面板底栏)。先把设置窗口翻到
    /// 「软件更新」页再查 —— 检查中 / 已是最新 / 发现新版本都显示在那一页上,跟系统设置从菜单点「检查更新」
    /// 会落到软件更新面板一个意思;不再有 Sparkle 自己的弹窗。Sparkle 已有会话在跑(比如后台正在下载)时
    /// 它不接受新检查,这里同样不动,页面照旧显示进行中的状态。
    func checkForUpdates() {
        showUpdatePage()
        guard canCheckForUpdates else { return }
        pageIntent = .check
        flow = .checking
        startCheck()
    }

    /// 真正把检查交给 Sparkle。开着「接收测试版」时先(按 TTL)把 Release 列表刷一遍:地址是它开始检查那一刻
    /// 同步来问的,不先刷就可能拿着一小时前的答案去查。刷新最多等 10 秒(URLRequest 超时),失败就用
    /// 缓存 / 默认地址,不会卡死。
    private func startCheck() {
        guard AppSettings.shared.receiveBetaUpdates else {
            updater.checkForUpdates()
            return
        }
        Task {
            await refreshBetaFeed(force: false)
            updater.checkForUpdates()
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
                updater.checkForUpdatesInBackground()
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
