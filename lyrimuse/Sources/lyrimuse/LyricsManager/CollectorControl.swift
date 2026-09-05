import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "collector-control")

// 统一收敛"改完共享文件、踢一脚重启 collector 让它重新读盘"这件事——EnrichCacheStore
// (歌词管理保存/删除)和 FeatureSettingsStore(功能开关保存)都要做同一件事,不各自
// 实现一份。
//
// 用 waitUntilExit()+terminationStatus 检查真实的成功/失败,不能只看 Process.run() 有
// 没有抛异常——那只能确认 launchctl 本身起得来,报不出"命令跑完了但其实失败了"(比如
// label 还没被 launchctl 加载过)这种情况。`launchctl kickstart -k` 本身只是给 launchd
// 发一条控制指令、不等目标进程完整启动完,同步等它退出不会明显卡住调用方。
public enum CollectorControl {
    public static let label = "com.lyrimuse.collector"

    /// 重启 collector,并**确认新进程真的起来了**才返回 true。
    ///
    /// 上面那段注释早就写明 `kickstart -k` 只是给 launchd 递一条控制指令、不等目标进程
    /// 启动完 —— 可它的退出码一直被当成"应用成功"返回给调用方(歌词管理保存/删除、功能
    /// 开关保存都拿它当准)。launchd 收下指令之后进程起不起得来是另一回事(二进制被换掉、
    /// LWCR 约束陈旧、配置让它一启动就退),那些情况下用户看到的是"已保存",实际什么都没
    /// 生效。
    ///
    /// 所以 kickstart 之后轮询真实状态。`-k` 是**先杀再起**,只看到"在跑"还不够——那可能
    /// 是还没被杀掉的旧进程,得等到 pid 变了才算数。
    private static let restartConfirmTimeout: TimeInterval = 3
    private static let restartPollInterval: TimeInterval = 0.15

    @discardableResult
    public static func restartAndWait() -> Bool {
        // 先记下旧 pid,用来判断看到的是不是同一个进程。
        var previousPid: Int32?
        if case .running(let pid) = CollectorServiceManager.state { previousPid = pid }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
        // 输出全丢:退出码就是要的全部信息。不设的话子进程继承 App 的 stderr,launchctl 的报错会
        // 原样漏进日志文件(2026-09-05 之前 App 和 collector 共用一份,那些行混在 collector 日志里,
        // 没有时间戳、没有来源,两天出现 59 次)。
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("launchctl kickstart failed to launch: \(String(describing: error), privacy: .public)")
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logger.error("launchctl kickstart exited with status \(process.terminationStatus)")
            return false
        }

        let deadline = Date().addingTimeInterval(restartConfirmTimeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: restartPollInterval)
            let state = CollectorServiceManager.state
            if case .running(let pid) = state {
                // pid 没变说明 `-k` 还没把旧进程杀掉,继续等。
                if let previousPid, pid == previousPid { continue }
                logger.info("collector restarted and confirmed running (pid \(pid))")
                return true
            }
        }

        // 超时:launchd 收下了指令,但这段时间里始终没看到一个新进程。
        logger.error("collector did not come back after kickstart — state=\(String(describing: CollectorServiceManager.state), privacy: .public)")
        return false
    }

    // 跟上面 restartAndWait() 是同一个操作,只是挪到后台线程跑——ConfigStore/
    // FeatureSettingsStore 这类需要在"设置"界面里展示"正在保存并应用…"这类真实过渡态
    // 的场景,如果直接在 MainActor 上同步调用 restartAndWait(),SwiftUI 连这一帧都还
    // 没来得及画出来、主线程就已经被 waitUntilExit() 占满,视觉上会像"点了保存瞬间就
    // 完成"——这不是真正意义上的加载反馈。restartAndWait() 本身不碰任何 MainActor
    // 隔离的状态(纯本地 Process 操作),可以安全地在后台 Task 里调用。
    public static func restartAndWaitAsync() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            restartAndWait()
        }.value
    }
}
