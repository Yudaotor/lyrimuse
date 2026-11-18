import Foundation

// 关窗后放下窗口里那块重的内容(ClosedWindowContent,见 15 章决策 112):摆回去再收尾的写法、两个开窗入口、延后到锁屏再拆、用上它的窗口。
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
    // 拆得慢的窗口等锁屏 / 显示器睡眠再拆:启动时装好触发,拆的那一段告诉卡顿探针,收尾时结束;重开过就作废。
    let triggers = sourceBody("static func installDeferredReleaseTriggers()", in: helper)
    expectEqual(sourceHas(triggers, #"forName: Notification.Name("com.apple.screenIsLocked")"#)
                && sourceHas(triggers, "forName: NSWorkspace.screensDidSleepNotification")
                && sourceHas(read("AppDelegate.swift"), "ClosedWindowContent.installDeferredReleaseTriggers()"), true,
                "关窗放内容: 启动时装好锁屏、显示器睡眠两个触发")
    let fire = sourceBody("private func fireDeferred(", in: helper)
    let fireBeginAt = fire.range(of: "beginExpectedStall()")
    let prepareAt = fire.range(of: "prepare?()")
    expectEqual(sourceHas(begin, "if reshowIsDeferred { beginExpectedStall() }")
                && sourceHas(finish, "endExpectedStall()")
                && fireBeginAt != nil && prepareAt != nil && fireBeginAt!.lowerBound < prepareAt!.lowerBound
                && sourceHas(sourceBody("private func beginExpectedStall()", in: helper), "MainThreadWatchdog.shared.beginExpectedStall(")
                && sourceHas(sourceBody("private func endExpectedStall()", in: helper), "MainThreadWatchdog.shared.endExpectedStall()"), true,
                "关窗放内容: 延后拆的那一段(从清缓存的 prepare 起)告诉卡顿探针是有意的,收尾时结束")
    expectEqual(sourceHas(begin, "if reshow == nil { endExpectedStall() }"), true,
                "关窗放内容: 摆回去之前窗口已经重新开着、不拆了,先开的预期停顿当场结束")
    expectEqual(sourceHas(fire, "guard let window = deferredWindow, !window.isVisible else {")
                && sourceHas(sourceBody("func windowAppeared() -> Bool", in: helper), "cancelDeferred()"), true,
                "关窗放内容: 锁屏时窗口已经重新开着就不拆,重开时作废登记")
    // 歌词管理的筛选缓存在根视图上、攥着整份摘要:拆之前原地清每个字段;关着时 filtered 不再往里填。
    let manager = read("LyricsManager/LyricsManagerView.swift")
    let cacheClass = sourceBody("private final class FilteredCache {", in: manager)
    let clear = sourceBody("func clear() {", in: cacheClass)
    var cacheFields: [String] = []
    if let re = try? NSRegularExpression(pattern: #"(?m)^\s*var (\w+)"#) {
        for m in re.matches(in: cacheClass, range: NSRange(cacheClass.startIndex..., in: cacheClass)) {
            if let r = Range(m.range(at: 1), in: cacheClass) { cacheFields.append(String(cacheClass[r])) }
        }
    }
    let uncleared = cacheFields.filter { !sourceHas(clear, "\($0) = ") }
    expectEqual(cacheFields.count >= 20 && uncleared.isEmpty, true,
                "关窗放内容: 歌词管理 FilteredCache.clear() 清掉每个字段(漏了 \(uncleared))")
    expectEqual(sourceHas(sourceBody("private var filtered: [EnrichCacheStore.Summary] {", in: manager),
                          "if closedContent.released { return [] }"), true,
                "关窗放内容: 歌词管理关着时 filtered 返回空、不往缓存里填")
    // 每扇窗:根视图、开窗那一处 onAppear 里的标志句、关窗那一处 onDisappear 里的标志句、关窗时要做的事。
    let cases: [(file: String, root: String, who: String, appear: String, disappear: String, extra: [String])] = [
        ("SettingsView.swift", "struct SettingsView: View {", "settings",
         #"AuxiliaryWindowActivation.windowDidAppear("settings")"#,
         #"AuxiliaryWindowActivation.windowDidDisappear("settings")"#,
         ["closedContent.release(windowSurface.window)"]),
        ("LyricsManager/LyricsManagerView.swift", "struct LyricsManagerView: View {", "lyrics-manager",
         #"AuxiliaryWindowActivation.windowDidAppear("lyrics-manager")"#,
         #"AuxiliaryWindowActivation.windowDidDisappear("lyrics-manager")"#,
         ["closedContent.releaseLater(windowSurface.window) { cache.clear() }"]),
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
