import AppKit
import LyrimuseCore

/// 「跟随播放器退出」:勾选的播放器**全部**退出后,等一个宽限期再退出
/// Lyrimuse。判定与宽限常数在 LyrimuseCore.PlayerLinkage(selftest 钉着),这里只管 NSWorkspace 通知和计时。
///
/// - 退出经 `AppExit.request(.followedPlayerQuit)`:走正常终止流程,未保存的账号配置有机会落盘,日志
///   `exiting reason=followed_player_quit`。
/// - collector 不退:它是常驻服务,也是「跟随播放器启动」的执行者 —— 播放器再打开时正是它把 Lyrimuse 拉回来。
/// - 宽限内任一个绑定的播放器又启动就取消(播放器崩溃自动重启 / 手动重启 / Spotify 更新后重启);到点再核一遍
///   进程表,不信排队那一刻的结论。
/// - 设置 / 歌词管理 / 歌词窗口这类能成为 key 的窗口开着时先不退:用户正在用 Lyrimuse 本身,不在他手上把 App
///   关掉。悬浮歌词和灵动岛是 NSPanel、不能成为 key,不算。这一次**只是推迟**:记下 `deferredForWindows`,
///   之后有窗口关掉 / 最小化就再等 `windowGoneGraceSeconds` 重判一次(原来是直接放弃,之后关掉窗口
///   Lyrimuse 也一直开着)。
@MainActor
final class PlayerQuitWatcher {
    static let shared = PlayerQuitWatcher()

    private var observers: [NSObjectProtocol] = []
    private var pendingQuit: DispatchWorkItem?
    /// 到点那一刻被 Lyrimuse 自己的窗口挡下了,等窗口关掉再判。
    private var deferredForWindows = false

    /// 窗口关掉之后再等多久重判。留一点余量给"关掉设置、紧接着从菜单栏打开歌词窗口"这种连续操作,
    /// 不在两扇窗交接的空当里把 App 退掉。
    private static let windowGoneGraceSeconds: TimeInterval = 2

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let bundleID = Self.bundleID(from: note) else { return }
            MainActor.assumeIsolated { self?.playerTerminated(bundleID) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let bundleID = Self.bundleID(from: note) else { return }
            MainActor.assumeIsolated { self?.playerLaunched(bundleID) }
        })
        // 被窗口挡下的那一次退出,靠这两条通知接回来。willClose 发出时窗口还算可见,所以不在这里当场判,
        // 而是排一次延迟重判(到点时 fireIfStillDue 会重新看窗口)。
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lyrimuseWindowGone() }
            })
        }
    }

    private static func bundleID(from note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    /// 此刻真正生效的绑定(用户勾的 ∩ 当前候选),换成 bundle id。
    private var boundBundleIDs: Set<String> {
        let bound = PlayerLinkage.effective(AppSettings.shared.quitWithPlayers,
                                            selectedPlayers: FeatureSettingsStore.shared.players)
        return Set(bound.map(\.bundleIdentifier)).subtracting([""])
    }

    private static var runningBundleIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private func playerTerminated(_ bundleID: String) {
        guard PlayerLinkage.shouldQuit(terminatedBundleID: bundleID,
                                       boundBundleIDs: boundBundleIDs,
                                       runningBundleIDs: Self.runningBundleIDs) else { return }
        AppExit.logger.notice("followed player quit bundle=\(bundleID, privacy: .public) grace=\(PlayerLinkage.quitGraceSeconds, privacy: .public)s")
        scheduleCheck(after: PlayerLinkage.quitGraceSeconds)
    }

    private func scheduleCheck(after seconds: TimeInterval) {
        pendingQuit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fireIfStillDue() }
        }
        pendingQuit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func playerLaunched(_ bundleID: String) {
        guard pendingQuit != nil || deferredForWindows, boundBundleIDs.contains(bundleID) else { return }
        pendingQuit?.cancel()
        pendingQuit = nil
        deferredForWindows = false
        AppExit.logger.notice("followed player relaunched bundle=\(bundleID, privacy: .public); quit cancelled")
    }

    /// 有窗口关掉 / 最小化了。只有之前被窗口挡下过、而且眼下没有别的重判在排队时才排一次。
    private func lyrimuseWindowGone() {
        guard deferredForWindows, pendingQuit == nil else { return }
        scheduleCheck(after: Self.windowGoneGraceSeconds)
    }

    private func fireIfStillDue() {
        pendingQuit = nil
        deferredForWindows = false
        let bound = boundBundleIDs
        // 宽限内又起来了 / 用户把设置改了 —— 到点按当下重算,不信排队那一刻的结论。
        guard !bound.isEmpty, bound.isDisjoint(with: Self.runningBundleIDs) else { return }
        if Self.userIsUsingLyrimuseWindows {
            deferredForWindows = true
            AppExit.logger.notice("followed player quit deferred: a Lyrimuse window is open")
            return
        }
        AppExit.request(.followedPlayerQuit)
    }

    private static var userIsUsingLyrimuseWindows: Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.canBecomeKey
                && !(window is LyricsOverlayWindow) && !(window is NotchLyricsWindow)
        }
    }
}
