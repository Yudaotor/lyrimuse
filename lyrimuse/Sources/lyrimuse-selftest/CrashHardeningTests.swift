import AppKit
import Foundation
import LyrimuseCore

/// 从遥测崩溃举一反三的防护:会抛 Objective-C 异常的读管道 / 序列化 / 取子串换成不抛的写法,布局回调里改尺寸的地方
/// 加像素容差、回差和封顶。见 15 章决策 105。
func runCrashHardeningTests() {
    print("\n== 读管道不抛异常 ==")
    do {
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        try? pipe.fileHandleForWriting.write(contentsOf: Data("abc".utf8))
        expectEqual(PipeRead.chunk(fd: fd), Data("abc".utf8), "PipeRead.chunk: 读到现有数据")
        try? pipe.fileHandleForWriting.close()
        expectEqual(PipeRead.chunk(fd: fd).isEmpty, true, "PipeRead.chunk: 写端关了按结尾")
        expectEqual(PipeRead.toEnd(pipe.fileHandleForReading).isEmpty, true, "PipeRead.toEnd: 已到结尾返回空")
        // 句柄已经关掉:availableData、连 fileDescriptor 都抛 NSFileHandleOperationException。事先取好的描述符这时读出 EBADF,应返回空。
        let closed = Pipe()
        let closedFD = closed.fileHandleForReading.fileDescriptor
        try? closed.fileHandleForReading.close()
        expectEqual(PipeRead.chunk(fd: closedFD).isEmpty, true, "PipeRead.chunk: 描述符已关返回空、不抛")
        expectEqual(PipeRead.chunk(fd: -1).isEmpty, true, "PipeRead.chunk: 无效描述符返回空")
        expectEqual(PipeRead.toEnd(closed.fileHandleForReading).isEmpty, true, "PipeRead.toEnd: 句柄已关返回空、不抛")
    }

    print("\n== 序列化前先查合法 ==")
    expectEqual(SafeSerialization.jsonData(["a": 1]) != nil, true, "jsonData: 合法对象照常序列化")
    expectEqual(SafeSerialization.jsonData(["d": Date()]) == nil, true, "jsonData: 含 Date 返回 nil、不抛")
    expectEqual(SafeSerialization.jsonData(["x": Double.nan]) == nil, true, "jsonData: 含 NaN 返回 nil、不抛")
    expectEqual((try? SafeSerialization.jsonDataThrowing(["d": Data()])) == nil, true, "jsonDataThrowing: 含 Data 抛 Swift 错误")
    expectEqual(SafeSerialization.isJSONValue(Date()), false, "isJSONValue: Date 不行")
    expectEqual(SafeSerialization.isJSONValue("s"), true, "isJSONValue: 字符串可以")
    expectEqual(SafeSerialization.isPropertyListValue(NSNull()), false, "isPropertyListValue: NSNull 不行")
    expectEqual(SafeSerialization.isPropertyListValue([1, NSNull()] as [Any]), false, "isPropertyListValue: 数组里夹 NSNull 不行")
    expectEqual(SafeSerialization.isPropertyListValue(["k": [1, 2]] as [String: Any]), true, "isPropertyListValue: 普通字典可以")

    print("\n== 读颜色分量不抛异常 ==")
    do {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2)))
        expectEqual(pattern.usingColorSpace(.sRGB) == nil, true, "前提:图案色转不到 sRGB")
        let c = pattern.sRGBOrWhite
        expectEqual([c.redComponent, c.greenComponent, c.blueComponent], [1, 1, 1], "sRGBOrWhite: 图案色退回 sRGB 白,读分量不抛")
        expectEqual(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1).sRGBOrWhite.greenComponent, 0.4, "sRGBOrWhite: 普通颜色照常转")
    }

    print("\n== 越界不取子串 ==")
    let ns = "あいう" as NSString
    expectEqual(ns.substringIfInBounds(location: 1, length: 2), "いう", "substringIfInBounds: 范围内照取")
    expectEqual(ns.substringIfInBounds(location: 2, length: 2), nil, "substringIfInBounds: 越过结尾 nil")
    expectEqual(ns.substringIfInBounds(location: 2, length: -1), nil, "substringIfInBounds: 负长度 nil")
    expectEqual(ns.substringIfInBounds(location: 3, length: 0), "", "substringIfInBounds: 结尾处空串")

    print("\n== 布局回差与封顶 ==")
    expectEqual(LayoutHysteresis.ceilToPixels(366.3, scale: 2), 366.5, "ceilToPixels: 2x 向上取到 0.5")
    expectEqual(LayoutHysteresis.ceilToPixels(366.3, scale: 1), 367, "ceilToPixels: 1x 向上取整")
    expectEqual(LayoutHysteresis.differsByPixel(CGSize(width: 100, height: 100), CGSize(width: 100.3, height: 100), scale: 2),
                false, "differsByPixel: 不到一个像素不算变")
    expectEqual(LayoutHysteresis.differsByPixel(CGSize(width: 100, height: 100), CGSize(width: 100.5, height: 100), scale: 2),
                true, "differsByPixel: 差一个像素算变")
    expectEqual(LayoutHysteresis.isWide(width: 899, wasWide: false, threshold: 900), false, "isWide: 窄版没到阈值仍窄")
    expectEqual(LayoutHysteresis.isWide(width: 900, wasWide: false, threshold: 900), true, "isWide: 到阈值变宽")
    expectEqual(LayoutHysteresis.isWide(width: 890, wasWide: true, threshold: 900), true, "isWide: 宽版在回差带里保持宽")
    expectEqual(LayoutHysteresis.isWide(width: 883, wasWide: true, threshold: 900), false, "isWide: 掉出回差带变窄")
    expectEqual(SettingsWindowHeight.minimum(visibleHeight: nil), 690, "SettingsWindowHeight: 不知道屏幕按设计值")
    expectEqual(SettingsWindowHeight.minimum(visibleHeight: 900), 690, "SettingsWindowHeight: 大屏按设计值")
    expectEqual(SettingsWindowHeight.minimum(visibleHeight: 700), 648, "SettingsWindowHeight: 小屏封顶到可用高度减标题栏")
    expectEqual(SettingsWindowHeight.minimum(visibleHeight: 300), 400, "SettingsWindowHeight: 再小也有下限")
    expectEqual(SettingsWindowHeight.ideal(visibleHeight: 700), 648, "SettingsWindowHeight: 理想高度同样封顶、不小于最小高度")
    expectEqual(SettingsWindowHeight.ideal(visibleHeight: 1000), 720, "SettingsWindowHeight: 大屏理想高度按设计值")

    print("\n== 接线(源码) ==")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ rel: String) -> String { (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
    // 旧的会抛异常的读法、序列化写法不许再出现(selftest 自己和 PipeRead / SafeSerialization 本体除外)。
    let fm = FileManager.default
    var offenders: [String] = []
    if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let url as URL in walker where url.pathExtension == "swift" {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !rel.hasPrefix("lyrimuse-selftest/"), !rel.hasSuffix("PipeRead.swift"),
                  !rel.hasSuffix("SafeSerialization.swift"), !rel.hasSuffix("JSONConfigDocument.swift") else { continue }
            let text = source(rel)
            for line in text.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                // MediaControlClient 里嵌的 JXA 脚本(`input.availableData`)跑在 osascript 进程里,不算。
                if code.hasPrefix("//") || code.contains("input.availableData") { continue }
                if code.contains(".availableData") || code.contains("readDataToEndOfFile()")
                    || code.contains("JSONSerialization.data(withJSONObject") || code.contains("usingColorSpace(.sRGB) ?? .white") {
                    offenders.append(rel)
                    break
                }
            }
        }
    }
    expectEqual(offenders.sorted(), [String](), "旧读法 / 不查合法的 JSON 序列化 / 退回灰度白:都换成 PipeRead / SafeSerialization / sRGBOrWhite")
    let portability = source("lyrimuse/Settings/ConfigPortability.swift")
    expectEqual(sourceHas(portability, "guard SafeSerialization.isPropertyListValue(value) else {")
                && sourceHas(portability, "guard SafeSerialization.isJSONValue(value) else {"), true,
                "配置导入跳过非属性列表值、导出跳过非 JSON 值")
    let panel = source("lyrimuse/MenuBar/MenuBarPanel.swift")
    expectEqual(sourceHas(panel, "guard !reportingFittingSize else { return }")
                && sourceHas(panel, "guard LayoutHysteresis.differsByPixel(fitting, bounds.size, scale: scale) else { return }"), true,
                "菜单栏面板:按像素比尺寸、摆窗口时不重入")
    expectEqual(sourceHas(source("lyrimuse/SettingsView.swift"), "minHeight: SettingsWindowHeight.minimum(visibleHeight: NSScreen.main?.visibleFrame.height)"),
                true, "设置窗口:最小高度按屏幕可用高度封顶")
    let mini = source("lyrimuse/UI/LyricsMiniPanel.swift")
    expectEqual(sourceHas(mini, "host.sizingOptions = []\npanel.contentMinSize = LyricsMiniPanel.minimumContentSize"), true,
                "迷你面板:最小尺寸自己设,不让 SwiftUI 在布局回调里改面板")
    expectEqual(sourceHas(source("lyrimuse/LyricsManager/SheetWindowAffordances.swift"),
                          "guard probe.minSize != minSize else { return }"), true,
                "弹窗下限:没变不改窗口,变了挪到下一拍")
    expectEqual(sourceHas(source("lyrimuse/MenuBar/AppMainMenu.swift"), "RunLoop.main.perform(inModes: [.common]) {"), true,
                "帮助菜单:不在插项通知里当场删项")
    expectEqual(sourceHas(source("lyrimuse/UI/LyricsLayerList.swift"), "type.responds(to: selector),"), true,
                "私有 CAFilter:先问认不认这个类方法")
    expectEqual(sourceHas(source("lyrimuse/MenuBar/MenuBarSceneActions.swift"), "host.sizingOptions = []"), true,
                "隐藏锚点窗口:不按内容改尺寸")

    print("\n== 从磁盘映像 / 临时位置运行:判定、脚本、搬运 ==")
    do {
        typealias L = AppLocation
        expectEqual(L.classify(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Lyrimuse.app", volumeIsReadOnly: true,
                               volumePath: "/", diskImageMountPoints: []), .translocated, "位置: App Translocation 路径")
        expectEqual(L.classify(bundlePath: "/Volumes/Lyrimuse/Lyrimuse.app", volumeIsReadOnly: true, volumePath: "/Volumes/Lyrimuse/",
                               diskImageMountPoints: ["/Volumes/Other", "/Volumes/Lyrimuse"]), .diskImage(mountPoint: "/Volumes/Lyrimuse"),
                    "位置: 只读卷又是磁盘映像的挂载点(末尾斜杠不影响)")
        expectEqual(L.classify(bundlePath: "/Volumes/Share/Lyrimuse.app", volumeIsReadOnly: true, volumePath: "/Volumes/Share",
                               diskImageMountPoints: ["/Volumes/Lyrimuse"]), .normal, "位置: 只读但不是磁盘映像(网络卷)不算")
        expectEqual(L.classify(bundlePath: "/Volumes/RW/Lyrimuse.app", volumeIsReadOnly: false, volumePath: "/Volumes/RW",
                               diskImageMountPoints: ["/Volumes/RW"]), .normal, "位置: 可写的映像(自己挂的读写映像)不算")
        expectEqual(L.classify(bundlePath: "/Applications/Lyrimuse.app", volumeIsReadOnly: false, volumePath: "/System/Volumes/Data",
                               diskImageMountPoints: []), .normal, "位置: 应用程序文件夹")
        expectEqual(L.shouldPrompt(.normal, declinedVersion: nil, currentVersion: "1.14.0"), false, "提示: 位置没问题不问")
        expectEqual(L.shouldPrompt(.translocated, declinedVersion: nil, currentVersion: "1.14.0"), true, "提示: 没说过不了就问")
        expectEqual(L.shouldPrompt(.diskImage(mountPoint: "/Volumes/L"), declinedVersion: "1.14.0", currentVersion: "1.14.0"), false,
                    "提示: 这一版说过不了就不再问")
        expectEqual(L.shouldPrompt(.diskImage(mountPoint: "/Volumes/L"), declinedVersion: "1.13.0", currentVersion: "1.14.0"), true,
                    "提示: 换了新版本再问一次")
        let info: [String: Any] = ["images": [
            ["image-path": "/Users/u/Downloads/Lyrimuse.dmg", "system-entities": [["dev-entry": "/dev/disk9"],
                                                                                 ["dev-entry": "/dev/disk9s1", "mount-point": "/Volumes/Lyrimuse"]]],
            ["image-path": "/x.dmg", "system-entities": [["mount-point": "/Volumes/X Y"]]],
        ]]
        let plist = (try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)) ?? Data()
        expectEqual(L.diskImageMountPoints(hdiutilInfoPlist: plist), ["/Volumes/Lyrimuse", "/Volumes/X Y"], "hdiutil info: 取各映像的挂载点")
        expectEqual(L.diskImageMountPoints(hdiutilInfoPlist: Data("not a plist".utf8)), [], "hdiutil info: 读不懂就是空")
        expectEqual(L.shellQuote("it's a b"), "'it'\\''s a b'", "shell 引号: 单引号拆开转义")
        expectEqual(L.appleScriptLiteral("a\"b\\c"), "\"a\\\"b\\\\c\"", "AppleScript 字面量: 双引号、反斜杠转义")
        let relaunch = L.relaunchScript(waitingFor: 42, detachMountPoint: "/Volumes/L y", launch: "/usr/bin/open '/Applications/Lyrimuse.app'")
        expectEqual(relaunch.split(separator: "\n").map(String.init),
                    ["while /bin/kill -0 42 >/dev/null 2>&1; do /bin/sleep 0.2; done",
                     "/usr/bin/hdiutil detach '/Volumes/L y' -quiet >/dev/null 2>&1", "/usr/bin/open '/Applications/Lyrimuse.app'"],
                    "重开: 等进程退出 → 推出映像 → 打开新位置")
        expectEqual(L.relaunchScript(waitingFor: 1, detachMountPoint: nil, launch: "x").contains("hdiutil"), false, "重开: 不在映像里就不推")

        // 授权那段脚本不用管理员权限也能在临时目录里真跑:换上新版、旧版进「废纸篓」、失败不留半截。
        let scratch = fm.temporaryDirectory.appendingPathComponent("lyrimuse-app-move-\(getpid())-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        func makeApp(_ dir: URL, _ content: String) {
            try? fm.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try? Data(content.utf8).write(to: dir.appendingPathComponent("Contents/marker"))
        }
        func marker(_ dir: URL) -> String? { (try? String(contentsOf: dir.appendingPathComponent("Contents/marker"), encoding: .utf8)) }
        let appSource = scratch.appendingPathComponent("src it's/Lyrimuse.app"), apps = scratch.appendingPathComponent("Apps"),
            trash = scratch.appendingPathComponent("Trash")
        makeApp(appSource, "new")
        makeApp(apps.appendingPathComponent("Lyrimuse.app"), "old")
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        func runScript(_ src: URL) -> Int32 {
            ProcessRunner.run("/bin/sh", ["-c", L.privilegedMoveScript(
                source: src.path, destination: apps.appendingPathComponent("Lyrimuse.app").path,
                temporary: apps.appendingPathComponent(L.temporaryName(for: "Lyrimuse.app")).path,
                trashTarget: trash.appendingPathComponent("Lyrimuse 1.app").path)], timeout: 10)?.status ?? -1
        }
        expectEqual(runScript(appSource), 0, "授权脚本: 成功退出")
        expectEqual(marker(apps.appendingPathComponent("Lyrimuse.app")), "new", "授权脚本: 换上新版")
        expectEqual(marker(trash.appendingPathComponent("Lyrimuse 1.app")), "old", "授权脚本: 旧版挪进废纸篓,不是覆盖")
        try? fm.removeItem(at: trash.appendingPathComponent("Lyrimuse 1.app"))
        expectEqual(runScript(scratch.appendingPathComponent("missing/Lyrimuse.app")) != 0, true, "授权脚本: 来源拷不了就失败退出")
        expectEqual(marker(apps.appendingPathComponent("Lyrimuse.app")), "new", "授权脚本: 失败时目标原样不动")
        expectEqual(((try? fm.contentsOfDirectory(atPath: apps.path)) ?? []).sorted(), ["Lyrimuse.app"], "授权脚本: 失败不留临时那份")

        // 不要权限的那条:注入的废纸篓是临时目录。
        let apps2 = scratch.appendingPathComponent("Apps2"), trash2 = scratch.appendingPathComponent("Trash2")
        try? fm.createDirectory(at: apps2, withIntermediateDirectories: true)
        try? fm.createDirectory(at: trash2, withIntermediateDirectories: true)
        _ = appSource.appendingPathComponent("Contents/marker").path.withCString { setxattr($0, "com.apple.quarantine", "0081;0;x;", 9, 0, 0) }
        let mover = AppBundleMover(trash: { url in
            let target = trash2.appendingPathComponent(url.lastPathComponent)
            try fm.moveItem(at: url, to: target)
            return target
        })
        let fresh = try? mover.move(appSource, into: apps2)
        expectEqual(fresh?.replaced == nil && marker(apps2.appendingPathComponent("Lyrimuse.app")) == "new", true, "搬运: 原来没有旧版")
        let quarantined = apps2.appendingPathComponent("Lyrimuse.app/Contents/marker").path.withCString { getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) }
        expectEqual(quarantined < 0, true, "搬运: 换上之后去掉隔离标记")
        makeApp(appSource, "newer")
        let again = try? mover.move(appSource, into: apps2)
        expectEqual(again?.replaced?.lastPathComponent, "Lyrimuse.app", "搬运: 旧版交给废纸篓")
        expectEqual(marker(apps2.appendingPathComponent("Lyrimuse.app")) == "newer" && marker(trash2.appendingPathComponent("Lyrimuse.app")) == "new",
                    true, "搬运: 新版换上、旧版在废纸篓里")
        struct TrashFailed: Error {}
        let stuck = AppBundleMover(trash: { _ in throw TrashFailed() })
        makeApp(appSource, "newest")
        expectEqual((try? stuck.move(appSource, into: apps2)) == nil, true, "搬运: 旧版挪不走就失败")
        expectEqual(marker(apps2.appendingPathComponent("Lyrimuse.app")) == "newer"
                    && ((try? fm.contentsOfDirectory(atPath: apps2.path)) ?? []).sorted() == ["Lyrimuse.app"], true,
                    "搬运: 失败时旧版原样、不留临时那份")
        let prompt = source("lyrimuse/Settings/AppLocationPrompt.swift")
        expectEqual(sourceHas(sourceBody("@MainActor static func runAtLaunch()", in: prompt), "UserDefaults.standard.set(currentVersion, forKey: declinedVersionKey)")
                    && sourceHas(prompt, "if activate { NSApplication.shared.activate(ignoringOtherApps: true) }"), true,
                    "提示(契约): 选不了记下这一版")
        expectEqual(sourceHas(sourceBody("func applicationWillFinishLaunching(_ notification: Notification)", in: source("lyrimuse/AppDelegate.swift")),
                              "AppLocationPrompt.runAtLaunch() terminateOlderInstances()"), true,
                    "提示(契约): 在请走旧实例之前问(移走要从新位置重开,别先关掉在跑的那份)")
    }
}
