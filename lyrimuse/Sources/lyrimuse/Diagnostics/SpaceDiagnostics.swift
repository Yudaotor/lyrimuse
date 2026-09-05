import AppKit
import os

/// 「切到别的 App 的全屏 Space 就被弹回桌面」这个用户报告的临时诊断探针(2026-09-03)。
///
/// ## 为什么需要它
///
/// 这个症状排查到现在,**所有既有日志都是空的** —— 用户复现的那一刻 App 一条日志都没打。
/// 已经用只读手段排除掉的:不是灵动岛、不是经典悬浮歌词(用户分别单独关掉后仍复现)、
/// 不是 `applicationShouldHandleReopen`(复现时段内一次都没触发)、不是 App 被重启
/// (pid 全程未变)、也**不是 Lyrimuse 抢焦点**(用 `lsappinfo front` 每 120ms 采样,
/// 整段时间它一次都没成为最前台)。唯一确定的必要条件是:**设置/歌词管理/歌词窗口这类
/// 普通窗口开着**;用户把它们全关掉之后就不弹了。
///
/// 也就是说,拽 Space 的动作发生在一条**不打日志的路径**上。这个类就是去补那条日志:
/// 把「Space 变了」「App 活跃态变了」「窗口成了 key」「窗口的 collectionBehavior 被重写」
/// 这四类事件按同一条时间线记下来,复现一次就能看出是谁先动的。
///
/// ⚠️ **这是临时诊断代码,定位到根因之后应当整个删掉**(连同 `AppDelegate` 里那行
/// `SpaceDiagnostics.start()` 和 `LyricsWindowController.enforceFullScreenCapability`
/// 里那行计数)。留着的成本不只是噪声:`report` 里会遍历所有窗口读 `isOnActiveSpace`,
/// 那是一次 WindowServer 往返。
@MainActor
enum SpaceDiagnostics {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "spacediag")
    private static var started = false

    /// `enforceFullScreenCapability` 的写入计数。⚠️ **不逐次打日志**:那个函数挂在
    /// `NSWindow.didUpdateNotification` 上,歌词窗口跟着播放滚动时更新周期一刻不停,
    /// 逐次打会把日志淹掉、也会自己变成性能问题。改成计数 + 由 Space/激活事件顺带报出来,
    /// 这样看到的是「上一次事件到这一次之间写了多少回」,正是要判的那个量。
    private static var fullScreenCapabilityWrites = 0

    static func noteFullScreenCapabilityWrite() {
        fullScreenCapabilityWrites += 1
    }

    static func start() {
        guard !started else { return }
        started = true
        logger.notice("spacediag: probe started (temporary diagnostics, remove once the cause is found)")

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { report("Space 变了") }
        }
        // 谁在最前台 —— 用户侧用 lsappinfo 采样看到的是「弹回桌面时前台变成访达」,
        // 这里从 App 内部再记一份,两边能对时间线。
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .localizedName ?? "?"
            MainActor.assumeIsolated { report("别的 App 被激活: \(app)") }
        }

        let nc = NotificationCenter.default
        let appEvents: [(Notification.Name, String)] = [
            (NSApplication.didBecomeActiveNotification, "本 App 变活跃"),
            (NSApplication.didResignActiveNotification, "本 App 失去活跃"),
        ]
        for (name, label) in appEvents {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    report(label)
                    // ⚠️ **调用栈是这一轮的核心证据**(2026-09-03 第二版):真机日志坐实
                    // 「切到飞书全屏 → 1.8 秒后 Lyrimuse 自己被激活 → Space 被拽回」,
                    // 而那一刻既没有 reopen、也没有点击。先 App 激活、再窗口成 key,是
                    // `NSApp.activate(ignoringOtherApps:)` 的签名动作 —— 但全仓十几个调用点
                    // 逐个读代码判「需不需要用户点击」已经漏过一次,所以改成让它自报家门。
                    //
                    // `NSApp.activate` 在多数路径上是**同步**投递 didBecomeActive 的,所以
                    // 这个栈里应该能看到真正的调用方;万一只有 AppKit 的帧,那说明激活是
                    // 系统侧发起的(而不是本 App 调的),那也是一个决定性的结论。
                    if name == NSApplication.didBecomeActiveNotification {
                        let frames = Thread.callStackSymbols
                            .prefix(24)
                            .map { $0.replacingOccurrences(of: "  ", with: " ") }
                            .joined(separator: " ⏎ ")
                        logger.notice("spacediag: became-active call stack | \(frames, privacy: .public)")
                    }
                }
            }
        }
        // 窗口成为 key 是「系统把某扇窗带到前台」的直接信号 —— 如果拽 Space 的是某扇
        // 普通窗口被 order 到前面,这一条会先亮。
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let title = (note.object as? NSWindow)?.title ?? "(无标题)"
            MainActor.assumeIsolated { report("窗口成为 key: \(title)") }
        }
    }

    /// 把当下的窗口分布整个拍一张:每扇窗在不在当前 Space、可不可见、collectionBehavior
    /// 是什么。⚠️ 一行一扇窗会太长,压成一行紧凑串。
    private static func report(_ reason: String) {
        let writes = fullScreenCapabilityWrites
        fullScreenCapabilityWrites = 0
        var parts: [String] = []
        for w in NSApp.windows where w.isVisible || w.isOnActiveSpace {
            let t = w.title.isEmpty ? "(无标题)" : w.title
            parts.append("[\(t) vis=\(w.isVisible ? 1 : 0) onActive=\(w.isOnActiveSpace ? 1 : 0) lvl=\(w.level.rawValue) cb=\(w.collectionBehavior.rawValue)]")
        }
        let dump = parts.joined(separator: " ")
        logger.notice("spacediag: \(reason, privacy: .public) | active=\(NSApp.isActive ? 1 : 0) | cb rewrites=\(writes, privacy: .public) | \(dump, privacy: .public)")
    }
}
