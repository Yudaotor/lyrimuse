import Darwin
import Foundation

/// 这台 Mac 此刻有没有一块触控栏(真机,或者 Xcode 的触控栏模拟器开着)。判据只此一份:`TouchBarAvailability`
/// 照着判,selftest 钉着。不按机型查表,只认系统此刻在不在驱动一块触控栏。
///
/// 分两层看:
/// 1. 系统的 ControlStrip 在不在跑。它由 launchd 在系统匹配到触控栏时拉起(`com.apple.touchbar.matching`),
///    没在跑就一定没有,而且不用再往下问 —— 下一层要连 TouchBarServer,那是按需启动、起来就不退的守护进程,
///    在没有触控栏的 Mac 上问一次就白白叫起来一个。
/// 2. 在跑,再看 DFRFoundation 报告的主触控栏还在不在:模拟器关掉之后 ControlStrip 不退,只有这一项会变空。
///    这一项查不了(接口缺了)时按「有」算,只靠第一层判。
public enum TouchBarPresence {
    public static func isPresent(controlStripRunning: Bool, touchBarReported: Bool?) -> Bool {
        guard controlStripRunning else { return false }
        return touchBarReported ?? true
    }
}

/// 系统的 ControlStrip 进程在不在跑。只问内核进程表,不经 LaunchServices:读 `NSRunningApplication` 的属性会同步问
/// launchservicesd,没有 bundle id 的那几十个每读一次问一次,主线程上会卡住(17 章决策 60)。会碰内核进程表,别在主线程调。
public enum ControlStripProcess {
    public static let executablePath = "/System/Library/CoreServices/ControlStrip.app/Contents/MacOS/ControlStrip"

    public enum Probe: Equatable, Sendable {
        case running(pid_t)
        case notRunning
        /// 进程表读不出来:沿用上一次的结论。
        case unknown
    }

    /// `known`:上一次找到的进程号,还是它就不再翻整张表。
    public static func probe(known: pid_t?) -> Probe {
        probe(executablePath: executablePath, known: known)
    }

    /// 可执行文件是 `path` 的那个进程。先认 `known`,不是再按进程名(路径最后一段,内核只留前 16 字节)挑候选、逐个核路径。
    public static func probe(executablePath path: String, known: pid_t?) -> Probe {
        if let known, executablePath(of: known) == path { return .running(known) }
        let name = String(decoding: (path as NSString).lastPathComponent.utf8.prefix(Int(MAXCOMLEN)), as: UTF8.self)
        guard let candidates = pids(command: name) else { return .unknown }
        return candidates.first { executablePath(of: $0) == path }.map(Probe.running) ?? .notRunning
    }

    /// 内核进程表里进程名是 `command` 的进程;表读不出来为 nil。一次 sysctl,不逐个查进程。
    public static func pids(command: String) -> [pid_t]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            size += size / 8
            var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            guard sysctl(&mib, u_int(mib.count), &table, &size, nil, 0) == 0 else {
                if errno == ENOMEM { continue }
                return nil
            }
            return table.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { entry in
                let comm = withUnsafeBytes(of: entry.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return comm == command ? entry.kp_proc.p_pid : nil
            }
        }
        return nil
    }

    /// 进程的可执行文件路径;进程不在或读不到为 nil。
    public static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
