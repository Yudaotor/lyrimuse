import AppKit
import LyrimuseCore

/// 「跟随播放器退出」(2026-09-03 新增,用户拍板逐播放器多选):勾选的播放器**全部**退出后,等一个宽限期再退出
/// Lyrimuse。判定与宽限常数在 LyrimuseCore.PlayerLinkage(selftest 钉着),这里只管 NSWorkspace 通知和计时。
///
/// - 退出经 `AppExit.request(.followedPlayerQuit)`:走正常终止流程,未保存的账号配置有机会落盘,日志
///   `exiting reason=followed_player_quit`。
/// - collector 不退:它是常驻服务,也是「跟随播放器启动」的执行者 —— 播放器再打开时正是它把 Lyrimuse 拉回来。
/// - 宽限内任一个绑定的播放器又启动就取消(播放器崩溃自动重启 / 手动重启 / Spotify 更新后重启);到点再核一遍
///   进程表,不信排队那一刻的结论。
/// - 设置 / 歌词管理 / 歌词窗口这类能成为 key 的窗口开着时不退:用户正在用 Lyrimuse 本身,不在他手上把 App
///   关掉。悬浮歌词和灵动岛是 NSPanel、不能成为 key,不算。
@MainActor
final class PlayerQuitWatcher {
    static let shared = PlayerQuitWatcher()

    private var observers: [NSObjectProtocol] = []
    private var pendingQuit: DispatchWorkItem?

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
        pendingQuit?.cancel()
        AppExit.logger.notice("followed player quit bundle=\(bundleID, privacy: .public) grace=\(PlayerLinkage.quitGraceSeconds, privacy: .public)s")
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fireIfStillDue() }
        }
        pendingQuit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerLinkage.quitGraceSeconds, execute: work)
    }

    private func playerLaunched(_ bundleID: String) {
        guard pendingQuit != nil, boundBundleIDs.contains(bundleID) else { return }
        pendingQuit?.cancel()
        pendingQuit = nil
        AppExit.logger.notice("followed player relaunched bundle=\(bundleID, privacy: .public); quit cancelled")
    }

    private func fireIfStillDue() {
        pendingQuit = nil
        let bound = boundBundleIDs
        // 宽限内又起来了 / 用户把设置改了 —— 到点按当下重算,不信排队那一刻的结论。
        guard !bound.isEmpty, bound.isDisjoint(with: Self.runningBundleIDs) else { return }
        if Self.userIsUsingLyrimuseWindows {
            AppExit.logger.notice("followed player quit skipped: a Lyrimuse window is open")
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
