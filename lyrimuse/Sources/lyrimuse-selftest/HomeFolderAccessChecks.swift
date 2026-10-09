import Foundation
import LyrimuseCore

/// 引擎要写的几处主目录位置(`HomeFolderAccess`,15 章决策 31)。在 `runOpsDiagnosticsTests` 里调用。
func homeFolderAccessChecks() {
    typealias A = HomeFolderAccess
    let me = getuid()

    // 判据:先看归谁,再看写不写得进,plist 另外不许组和其他用户可写。
    expectEqual(A.assess(ownerID: 0, ownerName: "root", mode: 0o755, isWritable: false, currentUID: me, isLaunchdPlist: false),
                .ownedBy("root"), "文件夹权限: 归别人的先报归属")
    expectEqual(A.assess(ownerID: 0, ownerName: nil, mode: 0o755, isWritable: true, currentUID: me, isLaunchdPlist: false),
                .ownedBy("uid 0"), "文件夹权限: 查不到用户名时报 uid")
    expectEqual(A.assess(ownerID: me, ownerName: "x", mode: 0o555, isWritable: false, currentUID: me, isLaunchdPlist: false),
                .notWritable, "文件夹权限: 归自己但写不进")
    expectEqual(A.assess(ownerID: me, ownerName: "x", mode: 0o100666, isWritable: true, currentUID: me, isLaunchdPlist: true),
                .writableByOthers(mode: 0o666), "文件夹权限: 别人也能写的 plist,只留权限位")
    expectEqual(A.assess(ownerID: me, ownerName: "x", mode: 0o666, isWritable: true, currentUID: me, isLaunchdPlist: false),
                nil, "文件夹权限: 普通位置别人能写不算问题")
    expectEqual(A.assess(ownerID: me, ownerName: "x", mode: 0o644, isWritable: true, currentUID: me, isLaunchdPlist: true),
                nil, "文件夹权限: 644 的 plist 没问题")

    // 真文件:不存在的跳过,只报有问题的。
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hfa-\(UUID().uuidString)")
    let readOnly = dir.appendingPathComponent("readonly")
    let writable = dir.appendingPathComponent("ok")
    let plist = dir.appendingPathComponent("x.plist")
    try? FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: writable, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: plist.path, contents: Data("x".utf8))
    try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: plist.path)
    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let findings = A.check([
        .init(path: writable.path),
        .init(path: dir.appendingPathComponent("missing").path),
        .init(path: readOnly.path),
        .init(path: "/"),
        .init(path: plist.path, isLaunchdPlist: true),
    ], currentUID: me)
    if me != 0 {
        expectEqual(findings, [
            .init(path: readOnly.path, problem: .notWritable),
            .init(path: "/", problem: .ownedBy("root")),
            .init(path: plist.path, problem: .writableByOthers(mode: 0o666)),
        ], "文件夹权限: 真文件上只报写不进、归 root、别人可写的 plist 三处")
    }

    // 修复命令:一处一行,路径单引号包住(含单引号也安全)。
    let command = A.fixCommand(for: [
        .init(path: "/Users/a/.config", problem: .ownedBy("root")),
        .init(path: "/Users/a/it's", problem: .notWritable),
        .init(path: "/Users/a/Library/LaunchAgents/x.plist", problem: .writableByOthers(mode: 0o666)),
    ], userName: "a")
    expectEqual(command.components(separatedBy: "\n"), [
        "sudo chown -R 'a':staff '/Users/a/.config' && chmod u+rwX '/Users/a/.config'",
        "sudo chown -R 'a':staff '/Users/a/it'\\''s' && chmod u+rwX '/Users/a/it'\\''s'",
        "chmod 644 '/Users/a/Library/LaunchAgents/x.plist'",
    ], "文件夹权限: 修复命令逐行、路径加引号")
    expectEqual(command.contains("#") || command.contains("!"), false,
                "文件夹权限: 修复命令不含 # 和 !(交互式 zsh 粘贴会出错)")

    // 诊断报告那几行与显示路径。
    expectEqual(A.diagnosticLines(for: [], checkedCount: 6), ["Folder access: ok (6 locations checked)"],
                "文件夹权限: 没问题时一行 ok")
    expectEqual(A.diagnosticLines(for: [.init(path: "/Users/a/.config", problem: .ownedBy("root"))], checkedCount: 6, home: "/Users/a"),
                ["Folder access: ~/.config is owned by root, not the current user"], "文件夹权限: 诊断行家目录写成 ~")
    expectEqual(A.displayPath("/Users/ab/x", home: "/Users/a"), "/Users/ab/x", "文件夹权限: 前缀相同的别的目录不缩写")

    // 清单:跟 Go 侧 homeFolderTargets 同一份,plist 只有一处、且就是引擎那份。
    let targets = A.targets
    expectEqual(targets.count, 6, "文件夹权限: 查 6 处")
    expectEqual(targets.filter(\.isLaunchdPlist).map(\.path),
                [LyrimusePaths.launchAgentPlist(label: LyrimuseIdentity.engineLaunchdLabel).path], "文件夹权限: 只按 plist 查引擎那份")
    expectEqual(targets.map(\.path).contains(LyrimusePaths.configDir.path)
                && targets.map(\.path).contains(LogFiles.engine.path)
                && targets.map(\.path).contains(LyrimusePaths.launchAgentsDir.path), true,
                "文件夹权限: 配置目录、引擎日志、LaunchAgents 都在清单里")

    // 两侧同步:Go 健康检查用的 label 跟 Swift 一致;装引擎时 plist 原子写并定成 644,bootstrap 失败记原话。
    let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let goSource = (try? String(contentsOfFile: repoRoot.appendingPathComponent(
        "lyrimuse-engine/healthcheckservice.go").path, encoding: .utf8)) ?? ""
    expectEqual(sourceBytes(goSource, contain: "const engineLaunchdLabel = \"\(LyrimuseIdentity.engineLaunchdLabel)\""), true,
                "文件夹权限: Go 健康检查的 launchd label 跟 Swift 一致")
    let manager = (try? String(contentsOfFile: repoRoot.appendingPathComponent(
        "lyrimuse/Sources/lyrimuse/Settings/EngineServiceManager.swift").path, encoding: .utf8)) ?? ""
    expectEqual(sourceBytes(manager, contain: "data.write(to: plistURL, options: .atomic)")
                && sourceBytes(manager, contain: "[.posixPermissions: 0o644], ofItemAtPath: plistURL.path"), true,
                "文件夹权限: 引擎 plist 原子写、显式 644")
    expectEqual(sourceBytes(manager, contain: "launchctl bootstrap exited with status"), true,
                "文件夹权限: bootstrap 失败把退出码和原话记进日志")
}
