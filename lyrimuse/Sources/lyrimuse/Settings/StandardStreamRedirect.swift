import Darwin
import Foundation
import LyrimuseCore

/// 把本进程的 stdout / stderr 追加到 `LogFiles.appStderr`(~/Library/Logs/lyrimuse-app.log)。
///
/// 2026-09-05 之前这件事由 LaunchAgent plist 的 StandardOutPath / StandardErrorPath 替我们做;2026-09-06
/// 「开机启动」改成系统登录项(LoginItemManager 头注)后 App 由 LaunchServices 起,launchd 不再接管这两个
/// 流,双击打开的那份本来也从没有过 —— 所以搬进进程内自己做,任何来路启动的 App 都有同一份。
/// 文件里正常情况下几乎是空的(App 的日志走 os.Logger),能落进来的只有 Swift 运行时的 fatal 信息、
/// 子进程漏出的 stderr 这类"本不该有"的东西,正因为如此排查崩溃时它最有用;诊断导出附最后 100 行。
///
/// 两条边界:
///  - stderr 是终端(`isatty`)时**不**重定向 —— 开发时 `swift run` / 直接跑二进制要在终端里看到输出;
///  - 只装一次,`O_APPEND` 追加不截断,跟当年 launchd 的行为一致(它也是追加)。
enum StandardStreamRedirect {
    private static var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        guard isatty(STDERR_FILENO) == 0 else { return }
        let url = LogFiles.appStderr
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
    }
}
