import AppKit
import os

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "launch-focus")

/// 后台拉起播放器(`activates = false`)后,它冷启动时自己跳到前台,就把前台还给拉起之前那个 App 的纯判定。
/// 每次有 App 成了前台问一次。见 02 章决策 273。
public enum LaunchFocusReturn {
    /// 从拉起算多久之内还管。
    public static let windowSeconds: TimeInterval = 30
    /// 一次拉起最多还几次,防止跟反复抢前台的 App 拉锯。
    public static let maxReturns = 3
    /// 成前台之前这么久之内按过鼠标或改过修饰键(点程序坞、点它的窗口、⌘Tab),按用户自己切过去算。
    public static let clickSeconds: TimeInterval = 1.5
    /// 成前台之前这么久之内按过键(聚焦搜索、启动器里回车打开),按用户自己切过去算。比 `clickSeconds` 短:
    /// 用户正打着字时被抢,还是要还回去。
    public static let keySeconds: TimeInterval = 0.5

    public enum Verdict: Equatable {
        /// 把前台还给拉起之前那个 App,接着盯。
        case returnFocus
        /// 这次不动,接着盯。
        case keepWatching
        /// 不再管这次拉起。
        case stop
    }

    /// - Parameters:
    ///   - activatedIsLaunched: 成前台的是被拉起的播放器(含它的别的版本)。
    ///   - activatedIsPrevious: 成前台的是拉起之前那个 App。
    ///   - sinceLaunch: 离拉起过了几秒。
    ///   - sinceClick: 离最近一次按鼠标或改修饰键过了几秒。
    ///   - sinceKey: 离最近一次按键过了几秒。
    ///   - returnsSoFar: 这次拉起已经还过几次。
    ///   - previousAlive: 拉起之前那个 App 还在跑、没被隐藏。
    public static func verdict(activatedIsLaunched: Bool, activatedIsPrevious: Bool, sinceLaunch: TimeInterval,
                               sinceClick: TimeInterval, sinceKey: TimeInterval, returnsSoFar: Int,
                               previousAlive: Bool) -> Verdict {
        guard sinceLaunch <= windowSeconds, previousAlive else { return .stop }
        if activatedIsPrevious { return .keepWatching }
        // 用户切到了别的 App:拉起之前那个已经不是他要回去的地方。
        guard activatedIsLaunched else { return .stop }
        guard sinceClick >= clickSeconds, sinceKey >= keySeconds else { return .stop }
        guard returnsSoFar < maxReturns else { return .stop }
        return .returnFocus
    }

    /// 最近一次按鼠标(左、右、其他键)或改修饰键、最近一次按键,各离现在几秒。
    public static func secondsSinceUserInput() -> (click: TimeInterval, key: TimeInterval) {
        func since(_ type: CGEventType) -> TimeInterval {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
        }
        return ([.leftMouseDown, .rightMouseDown, .otherMouseDown, .flagsChanged].map(since).min() ?? .infinity, since(.keyDown))
    }
}

/// 后台拉起播放器前调 `begin`:记下此刻的前台 App,窗口期内被拉起的播放器自己成了前台就按 `LaunchFocusReturn` 还回去。
/// 只用 `NSRunningApplication.activate`,不发按键。
@MainActor
public final class PlayerLaunchFocusGuard {
    private static var live: [ObjectIdentifier: PlayerLaunchFocusGuard] = [:]

    private let bundleIDs: Set<String>
    private let previous: NSRunningApplication
    private let started = Date()
    private var returns = 0
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    /// `bundleIDs` 是要拉起的那个播放器的全部 bundle id(`PlayerBundleAliases.all(for:)`)。前台是 Lyrimuse 自己时:
    /// `keepSelf` 为真(用户正在 Lyrimuse 的窗口里点)且有能当主窗口的窗口,还给 Lyrimuse;否则还给屏幕上最上层那扇
    /// 普通窗口的主人。启动那一刻 Lyrimuse 会短暂成为前台(设置窗口开了又关),那时还给自己只会把键盘焦点交给一个没有窗口的 App。
    public static func begin(launching bundleIDs: [String], keepSelf: Bool = false) {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        var previous = front
        if front.processIdentifier == me,
           !(keepSelf && NSApplication.shared.windows.contains(where: { $0.isVisible && $0.canBecomeMain })) {
            guard let below = topmostRegularApp(excluding: me, bundleIDs: bundleIDs) else {
                logger.notice("launch focus: no app to return to, not watching")
                return
            }
            previous = below
        }
        guard !bundleIDs.contains(previous.bundleIdentifier ?? "") else { return }
        let guardian = PlayerLaunchFocusGuard(bundleIDs: Set(bundleIDs), previous: previous)
        live[ObjectIdentifier(guardian)] = guardian
        guardian.start()
        let name = previous.bundleIdentifier ?? "?"
        logger.notice("launch focus: watching, will return to \(name, privacy: .public)")
    }

    /// 屏幕上从前往后第一扇普通层窗口所属的普通 App,跳过自己和要拉起的播放器。只读窗口的主人和层级,不要屏幕录制权限。
    private static func topmostRegularApp(excluding me: pid_t, bundleIDs: [String]) -> NSRunningApplication? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  !bundleIDs.contains(app.bundleIdentifier ?? "") else { continue }
            return app
        }
        return nil
    }

    private init(bundleIDs: Set<String>, previous: NSRunningApplication) {
        self.bundleIDs = bundleIDs
        self.previous = previous
    }

    private func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: LaunchFocusReturn.windowSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func activated(_ app: NSRunningApplication?) {
        guard let app else { return }
        let sinceInput = LaunchFocusReturn.secondsSinceUserInput()
        let sinceLaunch = Date().timeIntervalSince(started)
        let verdict = LaunchFocusReturn.verdict(
            activatedIsLaunched: bundleIDs.contains(app.bundleIdentifier ?? ""),
            activatedIsPrevious: app.processIdentifier == previous.processIdentifier,
            sinceLaunch: sinceLaunch, sinceClick: sinceInput.click, sinceKey: sinceInput.key, returnsSoFar: returns,
            previousAlive: !previous.isTerminated && !previous.isHidden)
        let name = app.bundleIdentifier ?? "?"
        let prev = previous.bundleIdentifier ?? "?"
        logger.notice("launch focus: \(name, privacy: .public) active after \(sinceLaunch, format: .fixed(precision: 2), privacy: .public)s, click \(sinceInput.click, format: .fixed(precision: 2), privacy: .public)s key \(sinceInput.key, format: .fixed(precision: 2), privacy: .public)s ago, previous \(prev, privacy: .public): \(String(describing: verdict), privacy: .public)")
        switch verdict {
        case .keepWatching: break
        case .stop: finish()
        case .returnFocus:
            returns += 1
            let target = previous
            // activate 是同步的跨进程调用,机器忙时一次要零点几秒,别压在主线程上。直接激活被系统拒掉时,
            // 改用以眼下在前台的播放器为发起方激活(协作激活要求发起方是当前前台 App)。
            DispatchQueue.global(qos: .userInitiated).async {
                let begun = Date()
                var how = "direct"
                var ok = target.activate(options: [])
                if !ok, #available(macOS 14.0, *) {
                    how = "from-player"
                    ok = target.activate(from: app, options: [])
                }
                let took = Date().timeIntervalSince(begun)
                logger.notice("launch focus: returned to \(prev, privacy: .public) via \(how, privacy: .public) ok=\(ok, privacy: .public) in \(took, format: .fixed(precision: 2), privacy: .public)s")
            }
        }
    }

    private func finish() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
        Self.live[ObjectIdentifier(self)] = nil
    }
}
