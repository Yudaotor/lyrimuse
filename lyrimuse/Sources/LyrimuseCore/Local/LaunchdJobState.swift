import Foundation

/// 一个 launchd job 的真实状态。
///
/// 存在的理由:`launchctl print` 的**退出码只说明这个 job 注册过没有**,跟进程有没有真的
/// 在跑毫无关系。2026-08-15 用一个一次性 job(跑 /usr/bin/true 立刻退出)实测:
///
///   | 场景                 | print 退出码 | state 字段        |
///   |----------------------|-------------|-------------------|
///   | 已注册 + 进程在跑     | 0           | `state = running` |
///   | 已注册 + 进程已退出   | **0**       | `state = not running` |
///   | 未注册               | 113         | (无输出)           |
///
/// 原来 `CollectorServiceManager.isRunning` 就是拿这个退出码当"在跑"用的,于是 collector
/// 在 KeepAlive 下崩溃重启循环时,设置页照样显示绿勾"运行中" —— 用户看到一切正常、歌词
/// 却一直不出来,没有任何线索。
public enum LaunchdJobState: Equatable, Sendable {
    /// launchd 里根本没有这个 job(没装,或已经 bootout)。
    case notRegistered
    /// 注册了,而且进程确实活着。
    case running(pid: Int32)
    /// 注册了,但此刻没有进程。KeepAlive 的 job 处于这个状态基本就是起不来/崩溃循环,
    /// `lastExitCode` 是它上次退出的状态码(launchd 报 `(never exited)` 时为 nil)。
    case registeredNotRunning(lastExitCode: Int32?)
    /// print 成功了,但输出里认不出 state 字段 —— launchd 换了输出格式之类。
    /// 单独留一档而不是并进"未运行":把"我知道它没跑"和"我读不懂"混为一谈,正是这次要修的
    /// 那类错误(拿一个不表示该含义的信号当结论用)。
    case unknown

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

extension LaunchdJobState: CustomStringConvertible {
    /// 给诊断报告和 os_log 用,固定英文 —— 诊断报告通篇是英文,而且这串是拿来贴给别人看
    /// 的,不该跟着界面语言变。用户可见的中文文案在 SettingsView 那边单独有一套。
    public var description: String {
        switch self {
        case .notRegistered:
            return "not registered"
        case .running(let pid):
            return "running (pid \(pid))"
        case .registeredNotRunning(let code):
            guard let code else { return "registered but not running (never exited)" }
            return "registered but not running (last exit code \(code))"
        case .unknown:
            return "unknown (launchctl print output not recognized)"
        }
    }
}

public enum LaunchdPrintParser {
    /// 解析 `launchctl print gui/<uid>/<label>` 的退出码 + stdout。
    ///
    /// ⚠️ 缩进是判据的一部分,不能用 `contains`。真实输出里同时存在这三种行:
    ///
    ///     \tstate = running          ← 顶层,要的就是这个
    ///     \t\tstate = active         ← 嵌套在子结构里,不是 job 状态
    ///     \tjob state = running      ← 同样一层缩进,但是**另一个字段**
    ///
    /// 所以只认行首恰好一个 tab 且紧跟 `state = ` 的那一行。
    public static func parse(printExitCode: Int32, printOutput: String) -> LaunchdJobState {
        guard printExitCode == 0 else { return .notRegistered }

        var stateValue: String?
        var pid: Int32?
        var lastExitCode: Int32?
        var sawLastExitCodeField = false

        for line in printOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            if let v = topLevelValue(of: "state", in: line) {
                stateValue = v
            } else if let v = topLevelValue(of: "pid", in: line) {
                pid = Int32(v)
            } else if let v = topLevelValue(of: "last exit code", in: line) {
                sawLastExitCodeField = true
                lastExitCode = parseExitCode(v)
            }
        }

        switch stateValue {
        case "running":
            // 正常情况下 running 必然带 pid;真缺了也不该退回"没在跑",state 字段本身
            // 才是权威,pid 只是附带信息。
            return .running(pid: pid ?? 0)
        case "not running", "waiting":
            return .registeredNotRunning(lastExitCode: sawLastExitCodeField ? lastExitCode : nil)
        case .some:
            return .unknown
        case nil:
            return .unknown
        }
    }

    /// `last exit code` 的值有三种真实形态,实测(2026-08-15,用一个 `sleep 1; exit 78` 的
    /// 一次性 job)全部见过:
    ///
    ///     last exit code = 0
    ///     last exit code = 78: EX_CONFIG      ← 带 sysexits 助记名
    ///     last exit code = (never exited)
    ///
    /// 第二种是这次差点漏掉的:直接 `Int32("78: EX_CONFIG")` 返回 nil,退出码会被静默吞掉,
    /// 界面上那句"带上次退出码"就永远兑现不了。取冒号之前那一段再解析。
    /// (顺带一提,退得太快的进程 launchd 还来不及记,那时报的就是 `(never exited)`。)
    private static func parseExitCode(_ raw: String) -> Int32? {
        let head = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
        return Int32(head.trimmingCharacters(in: .whitespaces))
    }

    /// 取"行首恰好一个 tab + `<key> = ` + 值"的值。多一层缩进(嵌套结构)或键名不完全相等
    /// (`job state`)都不算。
    private static func topLevelValue(of key: String, in line: Substring) -> String? {
        let prefix = "\t\(key) = "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
