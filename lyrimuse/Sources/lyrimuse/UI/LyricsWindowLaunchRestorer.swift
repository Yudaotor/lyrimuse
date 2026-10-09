import AppKit
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-window")

/// 启动时重开歌词窗口的 App 侧接线(07 章决策 72、123、124):时序与判定在 Core `LyricsWindowLaunchRestore`,
/// 这里开窗、核对、记日志。SceneActionRegistrar 在启动时调一次 `start`。
///
/// 每一次开都不激活 App(决策 123)。结局那行每次启动都记(notice,不放 debug):日志里一行都没有,
/// 就说明根本没走到重开。
@MainActor
enum LyricsWindowLaunchRestorer {
    private static var restore = LyricsWindowLaunchRestore()
    private static var openWindow: () -> Void = {}

    /// - Parameter openWindow: 置好启动重开的标记、让 SwiftUI 开那扇窗(环境 action 只在 SceneActionRegistrar 拿得到)。
    static func start(openWindow: @escaping () -> Void) {
        restore = LyricsWindowLaunchRestore()
        self.openWindow = openWindow
        DispatchQueue.main.asyncAfter(deadline: .now() + LyricsWindowLaunchRestore.firstDelay) {
            MainActor.assumeIsolated { step() }
        }
    }

    private static func step() {
        // 迷你被「暂停时隐藏」「全屏时隐藏」藏着也算上了屏,不重开(07 章决策 142)。
        let probe = LyricsWindowLaunchRestore.Probe(
            onScreen: LyricsMiniPanelAutoHide.shared.isHoldingPanel
                || (LyricsWindowSession.window.map { $0.isVisible || $0.isMiniaturized } ?? false),
            stillWanted: LyricsWindowSession.shouldReopenAtLaunch && !AppExit.isTerminating)
        switch restore.next(probe) {
        case .open(let checkAfter):
            let attempt = restore.attempts
            if attempt > 1 {
                let scene = currentScene
                logger.notice("launch restore: lyrics window not on screen, retrying attempt=\(attempt, privacy: .public) \(scene, privacy: .public)")
            }
            open()
            DispatchQueue.main.asyncAfter(deadline: .now() + checkAfter) {
                MainActor.assumeIsolated { step() }
            }
        case .finish(.restored(let attempts)):
            logger.notice("launch restore: lyrics window on screen attempts=\(attempts, privacy: .public)")
        case .finish(.stopped(let attempts)):
            logger.notice("launch restore: stopped, window closed or app exiting attempts=\(attempts, privacy: .public)")
        case .finish(.gaveUp(let attempts)):
            let scene = currentScene
            logger.error("launch restore: lyrics window still not on screen, giving up attempts=\(attempts, privacy: .public) \(scene, privacy: .public)")
        }
    }

    /// 窗口已经建出来、只是没上屏,就直接摆到最前;还没建出来才交给 SwiftUI 开。
    private static func open() {
        if let window = LyricsWindowSession.window {
            window.orderFrontRegardless()
        } else {
            openWindow()
        }
    }

    /// 没上屏时一并记下的现场:App 在不在前台、最前面是哪个 App、窗口是没建出来还是建出来没上屏、开机多久了。
    private static var currentScene: String {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        let window = LyricsWindowSession.window == nil ? "none" : "hidden"
        return "active=\(NSApp.isActive) frontmost=\(frontmost) window=\(window) uptime=\(Int(ProcessInfo.processInfo.systemUptime))"
    }
}
