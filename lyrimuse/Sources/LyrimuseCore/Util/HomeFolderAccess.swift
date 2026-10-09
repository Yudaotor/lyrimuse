import Foundation

/// 歌词引擎要写的几处主目录位置是否归当前用户、写得进去:配置目录、LaunchAgents、日志目录、引擎日志、引擎的 plist。
///
/// 任何一处不归自己或写不进,引擎就装不上或起不来,而系统给的只有一句笼统的 `Bootstrap failed: 5` 或退出码 78。
/// 启动时记日志、诊断报告、设置页「歌词引擎」卡片都读这一份结论。见 15 章决策 31。
public enum HomeFolderAccess {
    public enum Problem: Equatable, Sendable {
        /// 属于别的用户(常见是 root)。
        case ownedBy(String)
        /// 归自己,但没有写权限。
        case notWritable
        /// 组或其他用户也能写。launchd 拒收这样的 plist,`bootstrap` 报 5、不注册。
        case writableByOthers(mode: Int)
    }

    public struct Target: Equatable, Sendable {
        public let path: String
        /// 是 launchd 读的 plist:除了归自己、写得进,还不许组和其他用户可写。
        public let isLaunchdPlist: Bool

        public init(path: String, isLaunchdPlist: Bool = false) {
            self.path = path
            self.isLaunchdPlist = isLaunchdPlist
        }
    }

    public struct Finding: Equatable, Sendable {
        public let path: String
        public let problem: Problem

        public init(path: String, problem: Problem) {
            self.path = path
            self.problem = problem
        }
    }

    /// 要查的位置。路径一律从 `LyrimusePaths` / `LogFiles` 取。
    public static var targets: [Target] {
        [
            Target(path: LyrimusePaths.configDir.deletingLastPathComponent().path),
            Target(path: LyrimusePaths.configDir.path),
            Target(path: LyrimusePaths.launchAgentsDir.path),
            Target(path: LogFiles.engine.deletingLastPathComponent().path),
            Target(path: LogFiles.engine.path),
            Target(path: LyrimusePaths.launchAgentPlist(label: LyrimuseIdentity.engineLaunchdLabel).path,
                   isLaunchdPlist: true),
        ]
    }

    /// 一处位置有没有问题。纯函数,selftest 覆盖。
    public static func assess(
        ownerID: UInt32, ownerName: String?, mode: Int, isWritable: Bool, currentUID: UInt32, isLaunchdPlist: Bool
    ) -> Problem? {
        if ownerID != currentUID { return .ownedBy(ownerName ?? "uid \(ownerID)") }
        if !isWritable { return .notWritable }
        if isLaunchdPlist, mode & 0o022 != 0 { return .writableByOthers(mode: mode & 0o777) }
        return nil
    }

    /// 逐个查,只返回有问题的。不存在的跳过:还没建过是正常的,App 和引擎用到时自己建。
    public static func check(_ targets: [Target] = targets, currentUID: UInt32 = getuid()) -> [Finding] {
        let fm = FileManager.default
        return targets.compactMap { target in
            guard fm.fileExists(atPath: target.path),
                  let attrs = try? fm.attributesOfItem(atPath: target.path),
                  let ownerID = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value,
                  let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
            else { return nil }
            let problem = assess(
                ownerID: ownerID, ownerName: attrs[.ownerAccountName] as? String, mode: mode,
                isWritable: fm.isWritableFile(atPath: target.path), currentUID: currentUID,
                isLaunchdPlist: target.isLaunchdPlist)
            return problem.map { Finding(path: target.path, problem: $0) }
        }
    }

    /// 修好这些问题的终端命令,一处一行,给设置页「复制修复命令」用。归别人或写不进的整棵改回当前用户、补上自己的读写;
    /// 只是别人也能写的 plist 收回成 644。命令在 zsh 和 bash 里粘贴即可运行(不含 `#` 和 `!`)。
    public static func fixCommand(for findings: [Finding], userName: String = NSUserName()) -> String {
        findings.map { finding in
            let path = shellQuoted(finding.path)
            switch finding.problem {
            case .ownedBy, .notWritable:
                return "sudo chown -R \(shellQuoted(userName)):staff \(path) && chmod u+rwX \(path)"
            case .writableByOthers:
                return "chmod 644 \(path)"
            }
        }.joined(separator: "\n")
    }

    /// 诊断报告里的那几行,固定英文(诊断报告通篇英文)。路径里的家目录写成 `~`。
    public static func diagnosticLines(for findings: [Finding], checkedCount: Int, home: String = NSHomeDirectory()) -> [String] {
        guard !findings.isEmpty else { return ["Folder access: ok (\(checkedCount) locations checked)"] }
        return findings.map { finding in
            let path = displayPath(finding.path, home: home)
            switch finding.problem {
            case .ownedBy(let owner): return "Folder access: \(path) is owned by \(owner), not the current user"
            case .notWritable: return "Folder access: \(path) is not writable"
            case .writableByOthers(let mode):
                return "Folder access: \(path) is writable by others (mode \(String(mode, radix: 8))); launchd refuses it"
            }
        }
    }

    /// 家目录开头的路径写成 `~/…`,给界面和诊断报告看。
    public static func displayPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
