import AppKit
import Darwin

/// 按 bundle id 找 App 的进程号、判它在不在跑。`NSRunningApplication` 两头都不可靠:后台线程上偶尔返回空(16 章「通用
/// 教训」第 8 条),刚退出的那一份又可能还留在表里(02 章决策 194)。所以它给出的进程号先滤掉已结束的、再问内核还在不在;
/// 一个都没有时按内核进程表再找一遍:LaunchServices 给出这个 bundle id 的 App 在哪,可执行文件在它 `Contents/MacOS/`
/// 底下的进程就是它。
///
/// 找到过的进程号连同它的可执行文件路径按 bundle id 记下,下次先用内核核它(还活着、路径没变)就直接交回,不再问
/// LaunchServices:`runningApplications(withBundleIdentifier:)` 对在跑的 App 每调一次、新对象第一次读进程号,各同步等
/// launchservicesd 一次,主线程上每拍都问会在 App 起停、它最忙时卡住。没在跑的 App 那一问不出进程。见 02 章决策 262。
public enum PlayerProcess {
    /// 同一个播放器的别的版本(`PlayerBundleAliases`)也算,本体优先;另一个程序的那几个(`otherClients`)不算:要进程号的都是按本体的
    /// 菜单、界面或开着的文件做事。这个播放器眼下的会话是另一个程序报的(两个版本都开着、在放的是 iPad 版)时也为 nil,不然会去读写
    /// 本体菜单里的喜欢、播放模式,控制也按到本体上。没在跑为 nil。`excludingPID`:刚报退出的那个进程,退出通知到的那一刻它可能
    /// 还没被回收。见 02 章决策 204。
    public static func pid(bundleID: String, excludingPID gone: pid_t? = nil) -> pid_t? {
        guard !sessionIsOtherClient(bundleID: bundleID) else { return nil }
        let ids = PlayerBundleAliases.all(for: bundleID, includingOtherClients: false)
        return firstPID(ids: ids, excludingPID: gone)
    }

    /// 这个播放器最近那份会话是另一个程序(`PlayerBundleAliases.otherClients`)报的。
    public static func sessionIsOtherClient(bundleID: String) -> Bool {
        otherClient(reporting: MediaControlClient.reportingClient(forBundleID: PlayerBundleAliases.canonical(bundleID))) != nil
    }

    /// `client` 是另一个程序的那几个之一时原样交回,否则 nil。纯函数,selftest 覆盖。
    public static func otherClient(reporting client: String?) -> String? {
        client.flatMap { PlayerBundleAliases.otherClients.contains($0) ? $0 : nil }
    }

    /// 这个 bundle id 有没有活着的进程。`includingAliases` 为 false 时只认这一个 bundle id(查自动化权限这类按 bundle id
    /// 记账的场合)。
    public static func isRunning(bundleID: String, includingAliases: Bool = true, excludingPID gone: pid_t? = nil) -> Bool {
        firstPID(ids: includingAliases ? PlayerBundleAliases.all(for: bundleID) : [bundleID], excludingPID: gone) != nil
    }

    /// 只认这一个 bundle id(不展开别的版本、不看会话是谁报的)的进程号,没在跑为 nil。诊断包列各版本各自在不在跑用。
    public static func pid(exactBundleID bundleID: String) -> pid_t? {
        bundleID.isEmpty ? nil : firstPID(ids: [bundleID], excludingPID: nil)
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
            if let pid = knownPID(bundleID: id, excludingPID: gone) { return pid }
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            if let pid = firstUsable(apps.map { ($0.processIdentifier, $0.isTerminated) }, excludingPID: gone, isAlive: isAlive) {
                remember(pid, bundleID: id)
                return pid
            }
        }
        for id in ids {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            if let pid = pids(executableUnder: url.resolvingSymlinksInPath().path + "/Contents/MacOS/").first(where: { $0 != gone }) {
                remember(pid, bundleID: id)
                return pid
            }
        }
        return nil
    }

    private static let knownLock = NSLock()
    private static var known: [String: (pid: pid_t, path: String)] = [:]

    /// 上次为这个 bundle id 找到的进程:不是要剔掉的那个、内核里它的可执行文件还是记下的那个才算;对不上就忘掉。
    private static func knownPID(bundleID: String, excludingPID gone: pid_t?) -> pid_t? {
        knownLock.lock()
        let entry = known[bundleID]
        knownLock.unlock()
        guard let entry else { return nil }
        if let pid = verifiedPID(entry, excludingPID: gone, executablePath: ControlStripProcess.executablePath(of:)) { return pid }
        knownLock.lock()
        if known[bundleID]?.pid == entry.pid { known[bundleID] = nil }
        knownLock.unlock()
        return nil
    }

    /// 记下的进程还能不能用:不是 `gone`、可执行文件路径跟记下时一样(进程不在了读不出路径,进程号被别的程序重用时路径不同)。
    /// 纯函数(读路径由调用方给),selftest 覆盖。
    public static func verifiedPID(_ entry: (pid: pid_t, path: String), excludingPID gone: pid_t?,
                                   executablePath: (pid_t) -> String?) -> pid_t? {
        entry.pid != gone && executablePath(entry.pid) == entry.path ? entry.pid : nil
    }

    /// 记下这个 bundle id 的进程号和它此刻的可执行文件路径;读不出路径就不记。selftest 也用它造一条记录。
    public static func remember(_ pid: pid_t, bundleID: String) {
        guard let path = ControlStripProcess.executablePath(of: pid) else { return }
        knownLock.lock()
        known[bundleID] = (pid, path)
        knownLock.unlock()
    }

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t
    /// 系统把子进程算到哪个 App 头上用的函数(活动监视器把 WebKit 的媒体进程算到宿主头上用的也是它)。私有符号,按名字取
    /// (`bitPattern: -2` 即 `RTLD_DEFAULT`);取不到为 nil。
    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    /// 系统里取得到查负责进程的那个函数。
    public static var canResolveResponsiblePID: Bool { responsiblePIDFunction != nil }

    /// 系统把这个进程算在哪个进程头上(负责进程,没有宿主的就是它自己);查不到为 nil。一次系统调用,不问 LaunchServices。
    public static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard pid > 0, let responsible = responsiblePIDFunction else { return nil }
        let owner = responsible(pid)
        return owner > 0 ? owner : nil
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

/// 工作区起停通知(`didLaunchApplicationNotification` / `didTerminateApplicationNotification`)说的是哪个 App:先读通知自带的
/// `NSApplicationBundleIdentifier` / `NSApplicationProcessIdentifier`(普通值),没有才读 `NSRunningApplication` 的属性。那个对象
/// 的属性第一次读要同步问 launchservicesd,起停通知又正赶上它最忙的时候。见 02 章决策 262。
public enum WorkspaceAppNote {
    public static func bundleID(_ note: Notification) -> String? {
        if let id = note.userInfo?["NSApplicationBundleIdentifier"] as? String { return id }
        return (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    public static func pid(_ note: Notification) -> pid_t? {
        if let pid = (note.userInfo?["NSApplicationProcessIdentifier"] as? NSNumber)?.int32Value { return pid }
        return (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    }
}
