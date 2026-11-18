import Foundation
import LyrimuseCore
import ServiceManagement

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
        .init(path: "/Users/a/it's", problem: .notWritable, ownsTree: true),
        .init(path: "/Users/a/Library/LaunchAgents/x.plist", problem: .writableByOthers(mode: 0o666)),
    ], userName: "a")
    expectEqual(command.components(separatedBy: "\n"), [
        "sudo chown 'a':staff '/Users/a/.config' && chmod u+rwX '/Users/a/.config'",
        "sudo chown -R 'a':staff '/Users/a/it'\\''s' && chmod -R u+rwX '/Users/a/it'\\''s'",
        "chmod 644 '/Users/a/Library/LaunchAgents/x.plist'",
    ], "文件夹权限: 修复命令逐行、路径加引号;只有 Lyrimuse 自己的目录整棵改,共用目录只改这一层")
    expectEqual(A.targets.filter(\.ownsTree).map(\.path), [LyrimusePaths.configDir.path, LyrimusePaths.cachesDir.path, LogFiles.directory.path],
                "文件夹权限: 只有数据目录、缓存目录、日志目录算 Lyrimuse 整棵自己的(它们的上一层、~/Library/Logs、LaunchAgents 不 -R)")
    // # 和 ! 只能出现在单引号包住的路径里:交互式 zsh 粘贴时,引号外的 ! 会触发历史展开,词首的 # 在没开
    // interactive_comments 时报错。路径本身带这两个字符时也得成立,所以拿带它们的路径生成一遍,去掉引号里的部分再查。
    let tricky = A.fixCommand(for: [
        .init(path: "/Users/a/#tag!", problem: .ownedBy("root")),
        .init(path: "/Users/a/it's!", problem: .notWritable),
        .init(path: "/Users/a/Library/LaunchAgents/x#!.plist", problem: .writableByOthers(mode: 0o666)),
    ], userName: "a")
    let outsideQuotes = tricky.replacingOccurrences(of: "\\'", with: "")
        .replacingOccurrences(of: "'[^']*'", with: "", options: .regularExpression)
    expectEqual(outsideQuotes.contains("#") || outsideQuotes.contains("!"), false,
                "文件夹权限: 修复命令里的 # 和 ! 只出现在单引号包住的路径里(交互式 zsh 粘贴会出错)")
    expectEqual(tricky.contains("'/Users/a/#tag!'") && tricky.contains("'/Users/a/it'\\''s!'"), true,
                "文件夹权限: 带 # ! ' 的路径原样包在单引号里")

    // 诊断报告那几行与显示路径。
    expectEqual(A.diagnosticLines(for: [], checkedCount: 6), ["Folder access: ok (6 locations checked)"],
                "文件夹权限: 没问题时一行 ok")
    expectEqual(A.diagnosticLines(for: [.init(path: "/Users/a/.config", problem: .ownedBy("root"))], checkedCount: 6, home: "/Users/a"),
                ["Folder access: ~/.config is owned by root, not the current user"], "文件夹权限: 诊断行家目录写成 ~")
    expectEqual(A.displayPath("/Users/ab/x", home: "/Users/a"), "/Users/ab/x", "文件夹权限: 前缀相同的别的目录不缩写")

    // 清单:跟 Go 侧 homeFolderTargets 同一份,plist 只有一处、且就是引擎那份。
    let targets = A.targets
    expectEqual(targets.count, 9, "文件夹权限: 查 9 处")
    expectEqual(targets.filter(\.isLaunchdPlist).map(\.path),
                [LyrimusePaths.launchAgentPlist(label: LyrimuseIdentity.engineLaunchdLabel).path], "文件夹权限: 只按 plist 查引擎那份")
    expectEqual(targets.map(\.path).contains(LyrimusePaths.configDir.path)
                && targets.map(\.path).contains(LogFiles.engine.path)
                && targets.map(\.path).contains(LyrimusePaths.cachesDir.path)
                && targets.map(\.path).contains(LyrimusePaths.launchAgentsDir.path), true,
                "文件夹权限: 数据目录、缓存目录、引擎日志、LaunchAgents 都在清单里")

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

/// 引擎被「登录项与扩展 › 允许在后台」关掉时说清原因(`EngineBackgroundItem`,15 章决策 116)。在 `runOpsDiagnosticsTests` 里调用。
func engineBackgroundItemChecks() {
    typealias B = EngineBackgroundItem
    var asked = 0
    func blocks(running: Bool, override: Bool? = nil, _ status: SMAppService.Status) -> Bool {
        B.blocksEngine(engineRunning: running, override: override, status: { asked += 1; return status })
    }
    expectEqual(blocks(running: false, .requiresApproval), true, "后台项目: 没在跑、系统答 requiresApproval 才算被关")
    expectEqual([blocks(running: false, .enabled), blocks(running: false, .notRegistered), blocks(running: false, .notFound)],
                [false, false, false], "后台项目: enabled / notRegistered / notFound 都不算被关,照旧用原来的说法")
    asked = 0
    expectEqual(blocks(running: true, .requiresApproval), false, "后台项目: 引擎在跑就答否")
    expectEqual(asked, 0, "后台项目: 引擎在跑不问系统")
    expectEqual([blocks(running: true, override: true, .enabled), blocks(running: false, override: false, .requiresApproval)],
                [true, false], "后台项目: 调试注入有值时以它为准")
    expectEqual(B.describe(.requiresApproval).hasPrefix("requiresApproval"), true, "后台项目: 诊断导出写出 requiresApproval")

    let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lyrimuse")
    func app(_ name: String) -> String {
        (try? String(contentsOf: appDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
    let manager = app("Settings/EngineServiceManager.swift")
    expectEqual(sourceHas(manager, "SMAppService.statusForLegacyPlist(at: plistURL)"), true,
                "后台项目: 问的是引擎自己那份 plist 的登记状态")
    expectEqual(sourceHas(sourceBody("private static func install()", in: manager),
                          "backgroundItem=\\(backgroundItemStatusDescription, privacy: .public)"), true,
                "后台项目: 装完仍没跑起来时日志带上登记状态")
    let exporter = app("Settings/DiagnosticsExporter.swift")
    expectEqual(sourceHas(sourceBody("private static func stateLines(", in: exporter),
                          "lines.append(\"Engine background item: \\(engine.backgroundItem)\")"), true,
                "后台项目: 诊断导出有这一行")

    let settings = app("SettingsView.swift")
    let note = "L10n.t(\"已在「系统设置 › 通用 › 登录项与扩展」中关闭后台运行，歌词引擎无法启动\")"
    expectEqual(sourceHas(sourceBody("private var engineRows: some View", in: settings),
                          "if engineBlockedByBackgroundItem { SystemSettingsNote(text: \(note)) { EngineServiceManager.openLoginItemsSettings() } } else if !shownEngineState.isRunning, !engineFolderFindings.isEmpty {"),
                true, "后台项目: 设置播放器页先说这个原因、给打开系统设置的按钮,盖过文件夹和笼统的失败说明")
    expectEqual(sourceHas(settings, ".onReceive(playerHealth.$engineState.compactMap { $0 }) { latest in if latest != engineState { engineState = latest } refreshEngineFolderFindings() refreshEngineBackgroundItem() }"),
                true, "后台项目: 设置页跟着引擎状态心跳重查")
    expectEqual(sourceHas(settings, "if showsPearAPI { refreshPearAPI() } // 用户在系统设置里打开「允许在后台」时引擎状态不变、下面那条 onReceive 不触发,只能跟着这一拍重查。 refreshEngineBackgroundItem() }"),
                true, "后台项目: 设置页每拍重查(打开「允许在后台」时引擎状态不变,只靠状态变化重查会一直挂着)")
    let refresh = sourceBody("private func refreshEngineBackgroundItem()", in: settings)
    expectEqual(sourceHas(refresh, "EngineServiceManager.isBlockedByBackgroundItemSetting(engineRunning: running)")
                && sourceHas(refresh, "let reopened = engineBlockedByBackgroundItem engineBlockedByBackgroundItem = blocked if reopened, !engineState.isRunning, !isTogglingEngineService, AppSettings.shared.engineServiceEnabled { enableEngineService() }"),
                true, "后台项目: 用户在系统设置里打开后,引擎该跑没跑就再装一次")
    expectEqual(sourceHas(sourceBody("private func enableEngineService()", in: settings), "refreshEngineBackgroundItem()"), true,
                "后台项目: 设置页点「启用」之后重查")

    let onboarding = app("OnboardingView.swift")
    expectEqual(sourceHas(sourceBody("private func enableEngineService()", in: onboarding),
                          "EngineServiceManager.isBlockedByBackgroundItemSetting(engineRunning: running)")
                && sourceHas(onboarding, "if engineBlockedByBackgroundItem { VStack(alignment: .leading, spacing: 4) { Text(\(note))")
                && sourceHas(onboarding, "Button(L10n.t(\"打开系统设置\")) { EngineServiceManager.openLoginItemsSettings() }"), true,
                "后台项目: 首启引导启用失败时同样说这个原因、给按钮")
}
