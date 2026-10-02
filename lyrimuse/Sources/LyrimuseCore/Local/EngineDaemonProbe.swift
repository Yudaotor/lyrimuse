import Darwin
import Foundation

/// 不起子进程地看一眼歌词引擎的常驻进程在不在,决定要不要再问 launchd(`launchctl print` 要起一个子进程)。
///
/// 常驻进程认法:进程名是引擎的名字(新名或兼容的旧名)、父进程是 launchd(pid 1)。App 自己起的一次性子命令
/// (healthcheck、search-lyrics 这些)进程名一样,但父进程是 App,不算。
public enum EngineDaemonProbe {
    /// 引擎常驻进程的 pid;没有返回 nil。一次 `proc_listallpids` 加每个进程一次 `proc_pidinfo`,亚毫秒级。
    public static func daemonPID(names: [String] = LyrimuseIdentity.engineProcessNames) -> Int32? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return nil }
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard let info = bsdInfo(pid) else { continue }
            if isDaemon(ppid: info.pbi_ppid, name: processName(info), names: names) { return pid }
        }
        return nil
    }

    /// 是不是引擎的常驻进程:父进程是 launchd、进程名在 `names` 里。纯函数,selftest 覆盖。
    /// 经兼容符号链接(旧名)启动的,内核记的是链接指向的文件名,照样认得出。
    public static func isDaemon(ppid: UInt32, name: String, names: [String]) -> Bool {
        ppid == 1 && names.contains(name)
    }

    /// 某个进程的进程名(同 `daemonPID` 的认法);进程不在了返回 nil。
    public static func processName(pid: Int32) -> String? {
        bsdInfo(pid).map(processName)
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// 进程名取 `pbi_name`(最长 31 个字符);它为空才退回 `pbi_comm`,那一栏只有 15 个字符,长名字会被截断、对不上。
    private static func processName(_ info: proc_bsdinfo) -> String {
        func text<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        }
        let name = text(info.pbi_name)
        return name.isEmpty ? text(info.pbi_comm) : name
    }

    /// 上次从 launchd 问到的结论还能不能用。纯函数,selftest 覆盖。
    ///
    /// 能沿用的只有两种:上次是在跑、这次看到的还是同一个 pid;上次没在跑(没注册 / 注册了没进程)、这次也没有
    /// 进程。pid 变了、冒出来、没了,或者离上次问已经满 `maxAge`,都要再问一次(崩溃循环时 launchd 记着的上次
    /// 退出码会变,得隔一阵重读)。上次读不懂(`unknown`)每次都问。
    public static func needsLaunchdQuery(last: LaunchdJobState?, secondsSinceQuery: TimeInterval?,
                                         daemonPID: Int32?, maxAge: TimeInterval) -> Bool {
        guard let last, let since = secondsSinceQuery, since >= 0, since < maxAge else { return true }
        switch last {
        case .running(let pid): return daemonPID != pid
        case .notRegistered, .registeredNotRunning: return daemonPID != nil
        case .unknown: return true
        }
    }
}
