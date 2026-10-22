import AppKit
import Darwin

/// 按 bundle id 找播放器的进程号。`NSRunningApplication.runningApplications(withBundleIdentifier:)` 在后台线程偶尔返回空
/// (16 章「通用教训」第 8 条),这时按内核进程表再找一遍:LaunchServices 给出这个 bundle id 的 App 在哪,可执行文件在它
/// `Contents/MacOS/` 底下的进程就是它。没在跑为 nil。
public enum PlayerProcess {
    /// 同一个播放器的别的版本(`PlayerBundleAliases`)也算,本体优先。
    public static func pid(bundleID: String) -> pid_t? {
        let ids = PlayerBundleAliases.all(for: bundleID)
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                return app.processIdentifier
            }
        }
        for id in ids {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            if let pid = pids(executableUnder: url.resolvingSymlinksInPath().path + "/Contents/MacOS/").first { return pid }
        }
        return nil
    }

    /// 可执行文件路径以 `prefix` 开头的进程。
    public static func pids(executableUnder prefix: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.stride))
        guard n > 0 else { return [] }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return all.prefix(Int(n)).filter { pid in
            pid > 0 && proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasPrefix(prefix)
        }
    }
}
