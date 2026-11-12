import Foundation
import LyrimuseCore

// 诊断包「Automation permission」「Accessibility / Full Disk Access」两段的判据。由 runOpsDiagnosticsTests 调用。
@MainActor
func permissionDiagnosticsChecks() {
    print("\n== 权限诊断 ==")
    typealias D = PermissionDiagnostics
    let music = PlaybackPlayer.appleMusic.bundleIdentifier

    // ---- 自动化:每家都有只读探测 ----
    do {
        let needing = PlaybackPlayer.allCases.filter(\.needsAutomationPermission)
        expectEqual(needing.filter { AutomationReadProbe.expressions(for: $0) == nil }.map(\.rawValue), [],
                    "自动化: 需要这项权限的播放器每家都有探测表达式")
        expectEqual(AutomationReadProbe.expressions(for: .qqMusic) == nil, true, "自动化: 不靠脚本接口的没有探测")
        let script = AutomationReadProbe.script(for: .appleMusic, bundleID: music) ?? ""
        expectEqual(script.contains("runningApplicationsWithBundleIdentifier(\"\(music)\")"), true, "自动化: 按进程号找播放器、不拉起")
        let commands = ["Application(\"", ".play(", ".pause(", ".playpause(", ".nextTrack(", ".previousTrack(", ".activate(", ".stop("]
        let offending = needing.compactMap { player -> String? in
            let source = AutomationReadProbe.script(for: player, bundleID: player.bundleIdentifier) ?? ""
            return commands.contains(where: source.contains) ? player.rawValue : nil
        }
        expectEqual(offending, [], "自动化: 不按名字发事件、不调改状态的命令")
    }

    // ---- 自动化:osascript 结果解析 ----
    do {
        typealias P = AutomationReadProbe
        func parse(_ text: String, status: Int32 = 0, timedOut: Bool = false) -> D.ReadProbe {
            P.parse(status: status, stdout: Data(text.utf8), timedOut: timedOut)
        }
        expectEqual(parse(#"{"state":"playing","title":true}"#), .ok(state: "playing", hasTitle: true), "探测: 读到")
        expectEqual(parse(#"{"state":"stopped","title":false}"#), .ok(state: "stopped", hasTitle: false), "探测: 没有曲目")
        expectEqual(parse(#"{"error":-1743}"#), .appleEventError(-1743), "探测: Apple Event 报错带码")
        expectEqual(parse(#"{"error":null}"#), .failed("script error without a code"), "探测: 报错没码")
        expectEqual(parse(#"{"notRunning":true}"#), .notRunning, "探测: 中途退了")
        expectEqual(parse("", timedOut: true), .timedOut, "探测: 超时")
        expectEqual(parse("", status: 1), .failed("osascript exit 1"), "探测: osascript 失败")
        expectEqual(parse("oops"), .failed("unreadable output"), "探测: 解不出来")
    }

    // ---- 自动化那一段 ----
    do {
        var probed: [String] = []
        func lines(_ selected: Set<PlaybackPlayer>, running: [PlaybackPlayer: String],
                   grants: [PlaybackPlayer: AutomationAlert.Grant], probe: D.ReadProbe = .ok(state: "playing", hasTitle: true))
            -> [String] {
            D.automationLines(selected: selected, runningBundleID: { running[$0] }, grant: { grants[$0] },
                              lastKnown: { $0 == .spotify ? .authorized : nil },
                              probe: { player, _ in probed.append(player.rawValue); return probe })
        }
        let one = lines([.appleMusic], running: [.appleMusic: music], grants: [.appleMusic: .authorized])
        expectEqual(one, ["== Automation permission (selected players) ==",
                          "- apple_music (\(music)): running | TCC: authorized | read probe: ok state=playing title=present"],
                    "自动化段: 在跑、已授权、读到")
        expectEqual(lines([.appleMusic], running: [.appleMusic: music], grants: [.appleMusic: .authorized],
                          probe: .appleEventError(-1743)).last?.hasSuffix("read probe: failed: not authorized (-1743)"), true,
                    "自动化段: 读取失败写原因")
        probed = []
        expectEqual(lines([.appleMusic], running: [.appleMusic: music], grants: [.appleMusic: .undetermined]).last?
                        .hasSuffix("TCC: not determined | read probe: skipped (not asked yet, a read would prompt)"), true,
                    "自动化段: 未决只报状态")
        expectEqual(lines([.appleMusic], running: [.appleMusic: music], grants: [.appleMusic: .denied]).last?
                        .hasSuffix("read probe: skipped (denied)"), true, "自动化段: 拒绝不探")
        expectEqual(lines([.appleMusic], running: [.appleMusic: music], grants: [:]).last?
                        .hasSuffix("TCC: query timed out (last known: none) | read probe: skipped"), true, "自动化段: 查询超时不探")
        expectEqual(lines([.spotify], running: [.spotify: "com.spotify.client"], grants: [:]).last?
                        .contains("TCC: query timed out (last known: authorized)"), true, "自动化段: 查询超时带上次结论")
        expectEqual(lines([.spotify], running: [:], grants: [:]).last,
                    "- spotify: not running | last known: authorized | read probe: skipped (not running)", "自动化段: 没在跑用上次结论")
        expectEqual(probed, [], "自动化段: 未决 / 拒绝 / 超时 / 没在跑都不发 Apple Event")
        expectEqual(lines([.qqMusic], running: [:], grants: [:]).last,
                    "(no selected or running player reads through its script interface)", "自动化段: 不靠脚本接口的不列")
        expectEqual(lines([.auto], running: [.vox: "com.coppertino.Vox"], grants: [.vox: .denied]).map { String($0.prefix(6)) },
                    ["== Aut", "Auto-d", "- vox "], "自动化段: 自动识别只加在跑的")
    }

    // ---- 辅助功能与完全磁盘访问那一段 ----
    do {
        let state = LocalCacheAccess.State(updatedAt: 1_800_000_000, denied: ["qq"], readable: ["netease"], unprotected: [])
        func lines(trusted: Bool, everGranted: Bool = false, engine: LocalCacheAccess.State? = state) -> [String] {
            D.accessLines(selected: [.qqMusic, .netease, .spotify], isRunning: { _ in false },
                          accessibilityTrusted: trusted, accessibilityEverGranted: everGranted,
                          appFullDiskAccess: false, fullDiskAccessEverGranted: true, engineState: engine)
        }
        let denied = lines(trusted: false, everGranted: true)
        expectEqual(denied.first, "== Accessibility / Full Disk Access (selected players) ==", "访问段: 段标题")
        expectEqual(denied.contains { $0.hasPrefix("Accessibility (Lyrimuse): NOT granted (was granted") }, true,
                    "访问段: 辅助功能授权过又没了")
        expectEqual(denied.contains { $0.hasPrefix("  - qq_music: reads and presses its shuffle") }, true, "访问段: QQ 的辅助功能用途")
        expectEqual(denied.contains { $0.hasPrefix("  - spotify") }, false, "访问段: 不需要的播放器不列")
        expectEqual(denied.filter { $0.hasPrefix("      without it: no favorite button") }.count, 1, "访问段: 没授权时写后果")
        expectEqual(lines(trusted: true).contains { $0.contains("without it: no shuffle") }, false, "访问段: 授权了不写后果")
        expectEqual(denied.contains("Full Disk Access (Lyrimuse app process): NOT granted (was granted on this Mac before: likely invalidated by an update or re-sign)"),
                    true, "访问段: App 进程那份")
        expectEqual(denied.contains { $0.hasPrefix("  - qq_music: engine reads its lyrics cache") && $0.hasSuffix("| engine: denied") }, true,
                    "访问段: 引擎被拒")
        expectEqual(denied.contains { $0.hasPrefix("  - netease_music: ") && $0.hasSuffix("| engine: readable") }, true, "访问段: 引擎读得到")
        expectEqual(denied.filter { $0.hasPrefix("      without it: its own cached lyrics") }.count, 1, "访问段: 只有被拒的写后果")
        expectEqual(lines(trusted: true, engine: nil).contains("Full Disk Access (engine): no state published (engine not running or not probed yet)"),
                    true, "访问段: 引擎没发布")
        expectEqual(D.engineVerdict("netease", state: .init(unprotected: ["netease"])), "not protected (no grant needed)",
                    "访问段: 非沙盒版不用授权")
        expectEqual(D.accessLines(selected: [.auto], isRunning: { $0 == .amazonMusic }, accessibilityTrusted: true,
                                  accessibilityEverGranted: true, appFullDiskAccess: true, fullDiskAccessEverGranted: true,
                                  engineState: nil).contains { $0.hasPrefix("  - amazon_music: reads the on-screen time") },
                    true, "访问段: 自动识别加在跑的")
    }
}
