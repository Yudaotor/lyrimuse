import AppKit
import LyrimuseCore
import OSLog
import UserNotifications

/// 「发现新播放器」的 macOS 系统通知。
///
/// 2026-08-22 用户报:「识别到新的播放器,但我自己不知道要去这里信任,目前没有一个通知机制」。
/// 在这之前唯一的发现路径是设置页那张卡,而它只在那个播放器**此刻正在报 Now Playing**
/// 时才出现 —— 不主动打开设置页就永远看不到。用户明确选了「只做系统通知,不要菜单栏那部分」。
///
/// ## 分层
///
/// 判据全部在 `LyrimuseCore.UnknownPlayerAlert`(纯函数,selftest 覆盖),这里只负责管道:
/// 轮询取观察值、稳定性计数、授权、投递、处理按钮、落盘去重。UserNotifications 的调用
/// **一律留在 app target** —— selftest 只依赖 LyrimuseCore,把 UN 拖进去会让它一 import 就有
/// 崩的可能(`UNUserNotificationCenter.current()` 在没有 bundle 的进程里会抛
/// `bundleProxyForCurrentProcess is nil`)。
///
/// ## 这个 bundle 到底能不能发通知(2026-08-22 实测取证)
///
/// 三个看着可疑的条件叠在一起 —— ad-hoc 签名(`codesign -dv`: `Signature=adhoc`、
/// `TeamIdentifier=not set`)、launchd **直接 exec** `Contents/MacOS/lyrimuse`(不经 `open`)、
/// Info.plist 里 `LSUIElement=true` —— 但这台机器上三条都有跑通的先例:
///  - JetBrains Toolbox 的 LaunchAgent plist 跟 Lyrimuse **逐字段同形**(同样直接 exec
///    `Contents/MacOS/`),通知授权 `auth=7`;
///  - Chromium / chrome-for-testing 都是 ad-hoc 签名、TeamIdentifier 未设,同样 `auth=7`;
///  - `lsappinfo info <lyrimuse pid>` 能拿到 bundleID + bundle path + **checkin time** ——
///    这正是 `bundleProxyForCurrentProcess` 需要的东西,而且不是靠 `open` 拿到的。
/// 结论:本地通知不走 APNs,不需要开发者证书/公证/entitlements,Info.plist 一个键都不用加。
/// ⚠️ 但 `interruptionLevel` 的 `.timeSensitive` / `.critical` 需要 entitlement,ad-hoc 拿不到,
/// **别写** —— 默认的 `.active` 够用。
@MainActor
final class UnknownPlayerNotifier: NSObject {
    static let shared = UnknownPlayerNotifier()

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")

    static let categoryID = "unknown-player"
    static let trustActionID = "unknown-player.trust"
    /// 通知 userInfo 里携带 bundle id 的键。
    ///
    /// ⚠️ 处理按钮时**必须**从这里读,绝不能回头去读 `MediaControlClient.lastUngatedNowPlaying`:
    /// 通知可能在通知中心躺了几小时,那时焦点早换人了 —— 读现值会「点 Chrome 的旧通知,
    /// 结果信任了 QuickTime」。
    static let bundleIDKey = "bundleID"

    /// 已提醒记录。存 UserDefaults 而不是 features.json:那份是 collector 也在读的共享文件,
    /// 把高频后台时间戳塞进去会污染 isDirty / 底部保存栏的语义(而且 collector 侧只读不写,
    /// 别自己造出第二个写者)。
    ///
    /// ⚠️ 这个键**必须**在 ConfigPortability.machineLocalDefaultsKeys 里 —— 它跟
    /// `np:hasShownOverlayDragHint` 是完全同一类「这台机器提示过没有」。跟着备份搬去新机器
    /// 的后果是:新机器上装了同一个播放器却永不提示,而新机器恰恰最需要提示。
    private static let logKey = "np:unknownPlayerNotices"

    // 稳定性门槛的状态:只留内存。进程重启重数 6 秒,代价可忽略。
    private var pendingBundleID: String?
    private var pendingSince: Date?
    private var pendingHits = 0

    private var timer: Timer?
    private var askedAuthorization = false

    // MARK: - 启动

    /// 注册 category(带按钮)+ 设 delegate。**必须在启动阶段调**:
    ///  - `setNotificationCategories` 是**整表替换**,通知投递时 categoryIdentifier 在当前表里
    ///    查不到的话,通知照样显示但**按钮不出现**,而且不报错;
    ///  - delegate 设晚了,冷启动时用户点按钮的回调会丢。
    func registerCategory() {
        // ⚠️ **只放一个 action**。macOS 的规则:1 个 action 直接渲染成一个可见按钮,
        // 2 个及以上就折叠成「选项 ∨」下拉、要多点一下才看得到
        // (2026-08-22 用户报「这里可以直接把按钮选项放在外面吗,不要在选项里面点进去了」)。
        // 原来那个「忽略」按钮的处理逻辑本来就是空的(纯 dismiss),而划掉/点通知上的 ×
        // 一样能关掉 —— 去掉它零功能损失,换来按钮直接可见。
        // 想再加第二个动作之前先想清楚:那会把这个按钮重新折进「选项」里。
        let trust = UNNotificationAction(
            identifier: Self.trustActionID, title: L10n.t("加入信任列表"),
            options: [.authenticationRequired])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [trust],
            intentIdentifiers: [], options: [])
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([category])
    }

    /// 开始盯。5 秒一拍 —— 只是**读**一个已经被主轮询填好的静态变量,不起子进程
    /// (记录那一笔挂在 LocalPlaybackSource 既有的 media-control 调用上)。
    /// 不用 2 秒:未知播放器被闸挡掉时 App 自身是空闲态、主轮询本来就退到 10 秒一拍,
    /// 这里跟得再紧也没有更新的数据。
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 1
    }

    // MARK: - 一拍

    private func tick() {
        guard let seen = MediaControlClient.lastUngatedNowPlaying else {
            resetPending(); return
        }
        let features = FeatureSettingsStore.shared
        // 第一层判据(跟设置页那张卡共用)。不过就把稳定性计数清零 —— 计数只对
        // 「一直是同一个、一直够格」的观察累积。
        guard UnknownPlayerAlert.shouldOffer(
            bundleID: seen.bundleID, artist: seen.artist, album: seen.album,
            observedAt: seen.at, isAutoDetect: features.player == .auto, now: Date(),
            isAccepted: { TrustedPlayers.isAccepted($0) })
        else { resetPending(); return }

        if pendingBundleID != seen.bundleID {
            pendingBundleID = seen.bundleID
            pendingSince = Date()
            pendingHits = 0
        }
        pendingHits += 1
        let stableFor = pendingSince.map { Date().timeIntervalSince($0) } ?? 0

        guard UnknownPlayerAlert.shouldAnnounce(
            bundleID: seen.bundleID, artist: seen.artist, album: seen.album,
            observedAt: seen.at, isAutoDetect: true, now: Date(),
            isAccepted: { TrustedPlayers.isAccepted($0) },
            hasDisplayName: FeatureSettingsStore.appDisplayName(forBundleID: seen.bundleID) != nil,
            stableFor: stableFor, stableHits: pendingHits, log: loadLog())
        else { return }

        Task { await announce(seen) }
    }

    private func resetPending() {
        pendingBundleID = nil
        pendingSince = nil
        pendingHits = 0
    }

    // MARK: - 投递

    private func announce(_ seen: MediaControlClient.UngatedNowPlaying) async {
        guard await ensureAuthorized() else { return }
        // 授权对话框可能开了好几秒,期间用户完全可能已经在设置页点了信任 —— 投递前再查一次。
        guard !TrustedPlayers.isAccepted(seen.bundleID) else { return }
        let name = FeatureSettingsStore.appDisplayName(forBundleID: seen.bundleID) ?? seen.bundleID
        let what = [seen.artist, seen.title].filter { !$0.isEmpty }.joined(separator: " - ")

        let content = UNMutableNotificationContent()
        content.title = L10n.t("检测到新的播放器")
        content.subtitle = name
        content.body = what.isEmpty ? seen.bundleID
            : String(format: L10n.t("正在放：%@"), what)
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.bundleIDKey: seen.bundleID]
        // 同一个 App 多个未信任播放器时在通知中心归一组,不刷屏
        content.threadIdentifier = Self.categoryID
        content.sound = .default

        // identifier 固定成 "unknown-player.<bundleID>":系统对同 id 是**替换**而不是追加。
        // AppDelegate 的互杀逻辑有 3 秒窗口、两个实例都在轮询,固定 id 天然去重。
        let request = UNNotificationRequest(
            identifier: "\(Self.categoryID).\(seen.bundleID)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            recordAnnounced(seen.bundleID)
            log.notice("announced unknown player \(seen.bundleID, privacy: .public)")
        } catch {
            log.error("announce failed for \(seen.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 授权。**在第一次真的有东西要通知的那一刻才请求** —— 授权只有一次机会
    /// (状态一旦变成 .denied,后续 requestAuthorization 立刻返回、再也不弹框),启动时
    /// 无脑请求会让用户在完全不知道这是干什么用的时候随手点「不允许」,这个功能就永久废了。
    /// 此刻用户正在放歌,上下文明确。
    private func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            guard !askedAuthorization else { return false }
            askedAuthorization = true
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.notice("notification authorization granted=\(granted, privacy: .public)")
                return granted
            } catch {
                log.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        default:
            // .denied —— 别反复请求(不会再弹框),设置页那一行会告诉用户去哪打开。
            log.notice("notification not authorized (status=\(settings.authorizationStatus.rawValue, privacy: .public))")
            return false
        }
    }

    /// 这个 App 已经被信任了 → 把还挂在通知中心的那条撤掉。
    /// 别让「要不要信任 Chrome」在通知中心挂几天。
    func dismissDelivered(bundleID: String) {
        let id = "\(Self.categoryID).\(bundleID)"
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - 落盘

    private func loadLog() -> [String: UnknownPlayerAlert.AnnounceLog] {
        guard let raw = UserDefaults.standard.string(forKey: Self.logKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                [String: UnknownPlayerAlert.AnnounceLog].self, from: data)
        else { return [:] }
        return decoded
    }

    private func recordAnnounced(_ bundleID: String) {
        var log = loadLog()
        let previous = log[bundleID]?.count ?? 0
        log[bundleID] = .init(count: previous + 1, lastAt: Date())
        // 存成 JSON **字符串**(不是 Data):`defaults read` 看得懂,排查时不用写代码
        guard let data = try? JSONEncoder().encode(log),
              let text = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(text, forKey: Self.logKey)
    }

    // MARK: - 诊断(设置页那一行用)

    /// 当前授权状态。设置页只在 `.denied` 时显示那一行提示 ——
    /// 用户选了「只做系统通知、不要菜单栏兜底」,权限被拒时这个功能会**完全静默**,
    /// 而用户会理解成「它没检测到」,所以这个状态必须在界面上说出来。
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

extension UnknownPlayerNotifier: UNUserNotificationCenterDelegate {
    /// ⚠️ App 前台时系统默认**不显示**横幅。而这个 App 默认是前台的
    /// (Info.plist 写着 LSUIElement=true,但 AppDelegate 运行时按 showInDock 把
    /// activationPolicy 翻成了 .regular,默认开),所以少了这个方法,「用户正开着设置页
    /// 找这个功能」的时候反而收不到通知。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
            .notice("willPresent fired")
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
            .notice("didReceive action=\(response.actionIdentifier, privacy: .public)")
        // ⚠️ 第一件事:告诉 AppDelegate「这次激活是点通知来的」。
        // 系统点通知时会先激活 App,那会触发 applicationShouldHandleReopen —— 它是为
        // 「点 Dock 图标开歌词窗口」写的,不拦住就会连带弹出歌词窗口
        // (2026-08-22 用户报「点击通知怎么还打开了歌词窗口」)。那边把开窗延后了 0.3 秒
        // 专等这一下取消。
        // 只管设标记 —— AppDelegate 那边会查两次(进 reopen 时 + 真要开窗前)。
        // ⚠️ 别改回 `(NSApp.delegate as? AppDelegate)?.…`:那个转型在
        // @NSApplicationDelegateAdaptor 下拿不到我们的 AppDelegate,实测无声失败。
        await MainActor.run {
            AppActions.shared.suppressLyricsOnReopenUntil = Date().addingTimeInterval(2)
            Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
                .notice("suppress-lyrics flag set")
        }
        let info = response.notification.request.content.userInfo
        guard let bundleID = info[Self.bundleIDKey] as? String, !bundleID.isEmpty else { return }
        switch response.actionIdentifier {
        case Self.trustActionID:
            await Self.trust(bundleID)
        case UNNotificationDefaultActionIdentifier:
            // 点通知正文 → 直接停在设置页的「播放器」那一栏(发现卡和已信任列表都在那儿),
            // 不能只调 openSettings() —— 那样只是把窗口叫出来、落在上次那一栏。
            //
            // requestSettings 必须**先**调:它两条路一起走(信箱管"窗口还没建出来"、
            // subject 管"窗口已经开着"),信箱那条靠 SettingsView 的 .onAppear 消费,
            // 晚于 openSettings 就赶不上那一次 onAppear。见 AppActions.requestSettings。
            // NSApp.activate 也要:通知点击时 App 可能还不是活跃状态,而 .accessory 策略下
            // (用户关了「在 Dock 中显示」)不先激活就"点了没反应"。
            await MainActor.run {
                AppActions.shared.requestSettings(.tab(.player))
                NSApp.activate(ignoringOtherApps: true)
                AppActions.shared.openSettings?()
            }
        default:
            break
        }
    }

    private static func trust(_ bundleID: String) async {
        // 通知可能躺了很久 —— 写之前再查一遍,别把一个已经信任(或已被内置覆盖)的再写一遍。
        guard !TrustedPlayers.isAccepted(bundleID) else { return }
        await FeatureSettingsStore.shared.trust(bundleID: bundleID)
        await MainActor.run { UnknownPlayerNotifier.shared.dismissDelivered(bundleID: bundleID) }
    }
}
