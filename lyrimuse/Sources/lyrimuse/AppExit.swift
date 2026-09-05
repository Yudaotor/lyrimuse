import AppKit
import OSLog

/// App 进程的退出出口(2026-09-03):每一条退出路径在真正终止前都打一行
///
///     exiting reason=<code>
///
/// 形态固定、原因码英文 snake_case、可 grep(collector 侧同款前缀见 exitreason.go;规则在 AGENTS.md
/// 「容易踩的具体坑 → 退出路径」)。排「App 为什么自己退了」时,诊断导出里 grep 这个前缀就够,不用再
/// 对着 launchd 状态和崩溃报告猜。
///
/// 三条路都汇到 `applicationShouldTerminate`,所以日志在那里打、只打一次:
/// - **自己发起的**退出(菜单「退出」、配置变更后重启)先经 `request(_:)` 登记原因再 terminate;
/// - **外部发起的**(⌘Q、Dock 右键退出、AppleScript、新实例请走旧实例)没有登记,兜底记 `external_request`;
///   Sparkle 装更新时的重启由 `SparkleUpdaterManager.isInstallingUpdate` 认出来,记 `sparkle_install`;
/// - **SIGTERM**(launchctl kickstart -k / bootout、uninstall.sh)AppKit 默认直接死、连 delegate 都不叫。
///   这里装一个 DispatchSource 把它改成登记 `sigterm` 后走正常 terminate —— 顺带让
///   `applicationShouldTerminate` 里那次未保存配置的落盘也有机会跑到(以前 SIGTERM 把它连同进程一起带走)。
///
/// 崩溃不在此列(崩溃报告管);一次性子进程(lyrics-translate 等)不在此列。
/// 所有主动 terminate 只准经 `request(_:)`,selftest contracts 组守着。
enum AppExit {
    enum Reason: String {
        case menuQuit = "menu_quit"
        case restartAfterConfigChange = "restart_after_config_change"
        /// 新实例请走旧实例:记在**请走的那一侧**(见 logTerminatingOlderInstance);被请走的那份进程自己
        /// 只知道"有人叫我退",在它的 applicationShouldTerminate 里落成 external_request。
        case olderInstanceReplaced = "older_instance_replaced"
        case sparkleInstall = "sparkle_install"
        /// 「跟随播放器退出」宽限到点(PlayerQuitWatcher)。
        case followedPlayerQuit = "followed_player_quit"
        case sigterm = "sigterm"
        case externalRequest = "external_request"
    }

    /// 生命周期日志分类。走 Logger 不走 NSLog:DiagnosticsExporter.recentAppLogLines() 按 subsystem 查,
    /// NSLog 查不到。
    static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lifecycle")

    @MainActor private static var pendingReason: Reason?
    @MainActor private static var sigtermSource: DispatchSourceSignal?

    /// 自己发起的退出都走这里:登记原因,再交给 AppKit 的正常终止流程(会回到 applicationShouldTerminate)。
    @MainActor static func request(_ reason: Reason) {
        pendingReason = reason
        NSApp.terminate(nil)
    }

    /// `applicationShouldTerminate` 的第一件事。登记过的原因优先;没有就按信号推断。
    @MainActor static func logTermination(sparkleInstalling: Bool) {
        let reason = pendingReason ?? (sparkleInstalling ? .sparkleInstall : .externalRequest)
        pendingReason = nil
        logger.notice("exiting reason=\(reason.rawValue, privacy: .public)")
    }

    /// 新实例请走旧实例(AppDelegate.terminateOlderInstances)那一侧的日志:记的是"谁、为什么请走了谁"。
    static func logTerminatingOlderInstance(pid: pid_t, forced: Bool) {
        logger.notice("terminating older instance pid=\(pid, privacy: .public) reason=\(Reason.olderInstanceReplaced.rawValue, privacy: .public) forced=\(forced, privacy: .public)")
    }

    /// 把 SIGTERM 从"进程当场死"改成"登记 sigterm 后走正常 terminate"。在 applicationWillFinishLaunching
    /// 里装,越早越好。
    @MainActor static func installSigtermHandler() {
        // 先让默认处置忽略它,DispatchSource 才收得到;不这么做 handler 装上之前信号一来进程就没了。
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { request(.sigterm) }
        }
        source.resume()
        sigtermSource = source
    }
}
