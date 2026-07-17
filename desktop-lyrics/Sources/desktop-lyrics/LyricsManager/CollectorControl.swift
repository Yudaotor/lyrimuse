import Foundation
import os

private let logger = Logger(subsystem: "com.chenyuhao.applemusic-desktop-lyrics", category: "collector-control")

// 统一收敛"改完共享文件、踢一脚重启 collector 让它重新读盘"这件事——EnrichCacheStore
// (歌词管理保存/删除)和 FeatureSettingsStore(功能开关保存)都要做同一件事,不各自
// 实现一份。
//
// 之前 EnrichCacheStore 里的版本是 fire-and-forget:只检查 Process.run() 有没有抛异常
// (launchctl 本身起不起得来),不等真正执行完、不看退出码——报不出"launchctl 命令跑完了
// 但其实失败了"(比如 label 还没被 launchctl 加载过)这种情况。这里补上
// waitUntilExit()+terminationStatus 检查,返回真实的成功/失败。`launchctl kickstart -k`
// 本身只是给 launchd 发一条控制指令、不等目标进程完整启动完,同步等它退出不会明显卡住
// 调用方。
public enum CollectorControl {
    public static let label = "com.chenyuhao.applemusic-nowplaying"

    @discardableResult
    public static func restartAndWait() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
        do {
            try process.run()
        } catch {
            logger.error("launchctl kickstart failed to launch: \(String(describing: error), privacy: .public)")
            return false
        }
        process.waitUntilExit()
        let ok = process.terminationStatus == 0
        if ok {
            logger.info("restarted collector via launchctl kickstart")
        } else {
            logger.error("launchctl kickstart exited with status \(process.terminationStatus)")
        }
        return ok
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
