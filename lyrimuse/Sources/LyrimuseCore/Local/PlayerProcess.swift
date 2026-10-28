import AppKit
import Darwin

/// 按 bundle id 找 App 的进程号、判它在不在跑。`NSRunningApplication` 两头都不可靠:后台线程上偶尔返回空(16 章「通用
/// 教训」第 8 条),刚退出的那一份又可能还留在表里(02 章决策 194)。所以它给出的进程号先滤掉已结束的、再问内核还在不在;
/// 一个都没有时按内核进程表再找一遍:LaunchServices 给出这个 bundle id 的 App 在哪,可执行文件在它 `Contents/MacOS/`
/// 底下的进程就是它。
public enum PlayerProcess {
    /// 同一个播放器的别的版本(`PlayerBundleAliases`)也算,本体优先;另一个程序的那几个(`otherClients`)不算:要进程号的都是按本体的
    /// 菜单、界面或开着的文件做事。没在跑为 nil。`excludingPID`:刚报退出的那个进程,退出通知到的那一刻它可能还没被回收。
    public static func pid(bundleID: String, excludingPID gone: pid_t? = nil) -> pid_t? {
        let ids = PlayerBundleAliases.all(for: bundleID, includingOtherClients: false)
        return firstPID(ids: ids, excludingPID: gone)
    }

    /// 这个 bundle id 有没有活着的进程。`includingAliases` 为 false 时只认这一个 bundle id(查自动化权限这类按 bundle id
    /// 记账的场合)。
    public static func isRunning(bundleID: String, includingAliases: Bool = true, excludingPID gone: pid_t? = nil) -> Bool {
        firstPID(ids: includingAliases ? PlayerBundleAliases.all(for: bundleID) : [bundleID], excludingPID: gone) != nil
    }

    /// 内核看这个进程还在(没权限发信号也算在)。
    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// `NSRunningApplication` 报上来的候选里第一个能用的:没结束、不是刚退出的那个、内核里还在。纯函数(存活判断由调用方给),
    /// selftest 覆盖。
    public static func firstUsable(_ candidates: [(pid: pid_t, isTerminated: Bool)], excludingPID gone: pid_t?,
                                   isAlive: (pid_t) -> Bool) -> pid_t? {
        candidates.first { !$0.isTerminated && $0.pid != gone && isAlive($0.pid) }?.pid
    }

    private static func firstPID(ids: [String], excludingPID gone: pid_t?) -> pid_t? {
        for id in ids {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            if let pid = firstUsable(apps.map { ($0.processIdentifier, $0.isTerminated) }, excludingPID: gone, isAlive: isAlive) {
                return pid
            }
        }
        for id in ids {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            if let pid = pids(executableUnder: url.resolvingSymlinksInPath().path + "/Contents/MacOS/").first(where: { $0 != gone }) {
                return pid
            }
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
