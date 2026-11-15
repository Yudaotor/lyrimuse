import Foundation

// 关窗后放下窗口里那块重的内容(ClosedWindowContent,见 15 章决策 112):摆回去再收尾的写法、两个开窗入口、用上它的窗口。
// 由 settings-ui 组调用。

@MainActor
func runClosedWindowContentContracts() {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lyrimuse")
    func read(_ path: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let helper = read("UI/ClosedWindowContent.swift")
    let begin = sourceBody("private func beginReshow(", in: helper)
    let finish = sourceBody("private func finishReshow()", in: helper)
    expectEqual(sourceHas(finish, "r.window.close()") && !sourceHas(finish, "orderOut"), true,
                "关窗放内容: 摆回去之后用 close() 收尾,不用 orderOut(否则下次开窗不触发 onAppear、内容一直是占位)")
    let animOff = begin.range(of: "window.animationBehavior = .none")
    let alphaZero = begin.range(of: "window.alphaValue = 0")
    expectEqual(animOff != nil && alphaZero != nil && animOff!.lowerBound < alphaZero!.lowerBound
                && sourceHas(begin, "window.ignoresMouseEvents = true") && sourceHas(begin, "window.orderBack(nil)"), true,
                "关窗放内容: 先关窗口动画再透明、不接鼠标,再摆回窗口列表")
    expectEqual(sourceHas(finish, "r.window.animationBehavior = r.animation")
                && sourceHas(finish, "r.window.alphaValue = r.alpha"), true,
                "关窗放内容: 收尾还原透明度和窗口动画")
    // 开窗入口先把正摆回去的窗口收尾,再判「已在屏」、再开窗:不然这次开窗被随后收尾的 close() 关掉。
    for (path, signature, check) in [
        ("Settings/WindowActivation.swift", "static func openScene(", "if surfaceIfOnScreen(identifier) { return }"),
        ("MenuBar/MenuBarSceneActions.swift", "static func presentSettings(", #"if WindowActivation.surfaceIfOnScreen("settings") { return }"#),
    ] {
        let body = sourceBody(signature, in: read(path))
        let finishAt = body.range(of: "ClosedWindowContent.finishPendingReshows()")
        let checkAt = body.range(of: check)
        expectEqual(finishAt != nil && checkAt != nil && finishAt!.lowerBound < checkAt!.lowerBound, true,
                    "关窗放内容: \(signature) 开窗前先收尾正摆回去的窗口")
    }
    // 根视图上含这一句记账的那一处 onAppear / onDisappear 的函数体。
    func hook(_ opener: String, containing marker: String, in view: String) -> String {
        var rest = view[...]
        while let r = rest.range(of: opener) {
            let body = sourceBody(opener, in: rest[r.lowerBound...])
            if sourceHas(body, marker) { return body }
            rest = rest[r.upperBound...]
        }
        return ""
    }
    // 每扇窗:根视图、开窗那一处 onAppear 里的标志句、关窗那一处 onDisappear 里的标志句、关窗时要做的事。
    let cases: [(file: String, root: String, who: String, appear: String, disappear: String, extra: [String])] = [
        ("SettingsView.swift", "struct SettingsView: View {", "settings",
         #"AuxiliaryWindowActivation.windowDidAppear("settings")"#,
         #"AuxiliaryWindowActivation.windowDidDisappear("settings")"#,
         ["closedContent.release(windowSurface.window)"]),
    ]
    for c in cases {
        let view = sourceBody(c.root, in: read(c.file))
        let appear = hook(".onAppear {", containing: c.appear, in: view)
        let disappear = hook(".onDisappear {", containing: c.disappear, in: view)
        let firstAppear = appear.dropFirst(".onAppear {".count).trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("guard closedContent.windowAppeared() else { return }")
        let firstDisappear = disappear.dropFirst(".onDisappear {".count).trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("guard closedContent.windowDisappeared() else { return }")
        expectEqual(firstAppear && firstDisappear, true,
                    "关窗放内容(\(c.who)): 开关窗记账之前先过闸,摆回去 / 收尾那两下不算开关窗")
        let missing = c.extra.filter { !sourceHas(disappear, $0) }
        expectEqual(missing.isEmpty && sourceHas(view, ".releasedWhenWindowClosed(closedContent)"), true,
                    "关窗放内容(\(c.who)): 关窗时内容换成占位(漏了 \(missing))")
    }
}
