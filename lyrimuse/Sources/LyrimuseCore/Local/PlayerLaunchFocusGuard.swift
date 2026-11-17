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
    ///   - activatedIsLaunched: 成前台的是同一批被拉起的播放器之一(含它的别的版本)。
    ///   - activatedIsPrevious: 成前台的是拉起之前那个 App。
    ///   - activatedIsSelf: 成前台的是 Lyrimuse 自己(启动时设置窗口开了又关、用户点开它的窗口),不算切走。
    ///   - sinceLaunch: 离拉起过了几秒。
    ///   - sinceClick: 离最近一次按鼠标或改修饰键过了几秒。
    ///   - sinceKey: 离最近一次按键过了几秒。
    ///   - returnsSoFar: 成前台的这个播放器已经还过几次。
    ///   - previousAlive: 拉起之前那个 App 还在跑、没被隐藏。
    public static func verdict(activatedIsLaunched: Bool, activatedIsPrevious: Bool, activatedIsSelf: Bool = false,
                               sinceLaunch: TimeInterval, sinceClick: TimeInterval, sinceKey: TimeInterval, returnsSoFar: Int,
                               previousAlive: Bool) -> Verdict {
        guard sinceLaunch <= windowSeconds, previousAlive else { return .stop }
        if activatedIsPrevious || activatedIsSelf { return .keepWatching }
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

/// 同一批后台拉起的播放器共用的判定状态(纯值,selftest 覆盖)。一批里谁成了前台都算被拉起的:各自冷启动时自己跳前台,
/// 先跳的那个被还回去之后,后跳的那个照样要还;按单个播放器判的话,后跳的那个看到「别的 App 成了前台」就不再管了。
/// 每个播放器各自最多还 `LaunchFocusReturn.maxReturns` 次。见 02 章决策 274。
public struct LaunchFocusBatch: Equatable, Sendable {
    /// 每个元素是一个播放器的全部 bundle id(`PlayerBundleAliases.all(for:)`)。
    public let players: [Set<String>]
    public private(set) var returns: [Int]
    /// 最近一次不是被拉起的播放器成前台时,成前台的是 Lyrimuse 自己(而不是拉起之前那个 App)。
    /// 那时还前台先考虑还给 Lyrimuse(它有能当主窗口的窗口时)。
    public private(set) var lastHomeIsSelf = false

    public init(players: [[String]]) {
        self.players = players.map(Set.init)
        returns = Array(repeating: 0, count: players.count)
    }

    /// 全部 bundle id,不分播放器。
    public var allBundleIDs: Set<String> { players.reduce(into: []) { $0.formUnion($1) } }

    /// 这个 bundle id 是这批里第几个播放器;不是这批拉起的返回 nil。
    public func player(of bundleID: String?) -> Int? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return players.firstIndex { $0.contains(bundleID) }
    }

    /// 按 `LaunchFocusReturn.verdict` 判一次;判了还前台就给那个播放器记一次。
    public mutating func verdict(activatedBundleID: String?, activatedIsPrevious: Bool, activatedIsSelf: Bool,
                                 sinceLaunch: TimeInterval, sinceClick: TimeInterval, sinceKey: TimeInterval,
                                 previousAlive: Bool) -> LaunchFocusReturn.Verdict {
        let index = player(of: activatedBundleID)
        let verdict = LaunchFocusReturn.verdict(
            activatedIsLaunched: index != nil, activatedIsPrevious: activatedIsPrevious, activatedIsSelf: activatedIsSelf,
            sinceLaunch: sinceLaunch, sinceClick: sinceClick, sinceKey: sinceKey,
            returnsSoFar: index.map { returns[$0] } ?? 0, previousAlive: previousAlive)
        if verdict == .keepWatching { lastHomeIsSelf = activatedIsSelf }
        if verdict == .returnFocus, let index { returns[index] += 1 }
        return verdict
    }
}

/// 后台拉起播放器前调 `begin`:记下此刻的前台 App,窗口期内被拉起的播放器自己成了前台就按 `LaunchFocusBatch` 还回去。
/// 同一批拉起的几个播放器只调一次 `begin`,共用一个守卫。只用 `NSRunningApplication.activate`,不发按键。
@MainActor
public final class PlayerLaunchFocusGuard {
    private static var live: [ObjectIdentifier: PlayerLaunchFocusGuard] = [:]

    private var batch: LaunchFocusBatch
    private let previous: NSRunningApplication
    private let started = Date()
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    /// `players` 是这一批要拉起的播放器,每个元素是一个播放器的全部 bundle id(`PlayerBundleAliases.all(for:)`)。
    /// 前台是 Lyrimuse 自己时:`keepSelf` 为真(用户正在 Lyrimuse 的窗口里点)且有能当主窗口的窗口,还给 Lyrimuse;否则还给
    /// 屏幕上最上层那扇普通窗口的主人。启动那一刻 Lyrimuse 会短暂成为前台(设置窗口开了又关),那时还给自己只会把键盘焦点
    /// 交给一个没有窗口的 App。
    public static func begin(launching players: [[String]], keepSelf: Bool = false) {
        let batch = LaunchFocusBatch(players: players)
        let bundleIDs = batch.allBundleIDs
        guard !bundleIDs.isEmpty else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        var previous = front
        if front.processIdentifier == me, !(keepSelf && hasMainWindow()) {
            guard let below = topmostRegularApp(excluding: me, bundleIDs: bundleIDs) else {
                logger.notice("launch focus: no app to return to, not watching")
                return
            }
            previous = below
        }
        guard !bundleIDs.contains(previous.bundleIdentifier ?? "") else { return }
        let guardian = PlayerLaunchFocusGuard(batch: batch, previous: previous)
        live[ObjectIdentifier(guardian)] = guardian
        guardian.start()
        let name = previous.bundleIdentifier ?? "?"
        logger.notice("launch focus: watching, will return to \(name, privacy: .public)")
    }

    /// Lyrimuse 有能当主窗口的可见窗口(设置、歌词管理这类);菜单栏面板、悬浮歌词不算。
    private static func hasMainWindow() -> Bool {
        NSApplication.shared.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    /// 屏幕上从前往后第一扇普通层窗口所属的普通 App,跳过自己和要拉起的播放器。只读窗口的主人和层级,不要屏幕录制权限。
    private static func topmostRegularApp(excluding me: pid_t, bundleIDs: Set<String>) -> NSRunningApplication? {
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

    private init(batch: LaunchFocusBatch, previous: NSRunningApplication) {
        self.batch = batch
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
        let verdict = batch.verdict(
            activatedBundleID: app.bundleIdentifier,
            activatedIsPrevious: app.processIdentifier == previous.processIdentifier,
            activatedIsSelf: app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            sinceLaunch: sinceLaunch, sinceClick: sinceInput.click, sinceKey: sinceInput.key,
            previousAlive: !previous.isTerminated && !previous.isHidden)
        let name = app.bundleIdentifier ?? "?"
        let target = batch.lastHomeIsSelf && Self.hasMainWindow() ? NSRunningApplication.current : previous
        let prev = target.bundleIdentifier ?? "?"
        logger.notice("launch focus: \(name, privacy: .public) active after \(sinceLaunch, format: .fixed(precision: 2), privacy: .public)s, click \(sinceInput.click, format: .fixed(precision: 2), privacy: .public)s key \(sinceInput.key, format: .fixed(precision: 2), privacy: .public)s ago, return to \(prev, privacy: .public): \(String(describing: verdict), privacy: .public)")
        switch verdict {
        case .keepWatching: break
        case .stop: finish()
        case .returnFocus:
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
