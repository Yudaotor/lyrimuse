import AppKit
import ApplicationServices
import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "ytmusic-skip")

/// 用 macOS **辅助功能 API** 按下浏览器网页里 YouTube 播放器的「跳过广告」键(2026-09-08)。
///
/// ## 为什么是它
///
/// `YouTubeMusicAdSkipper` 从 JS 里试遍了"按那颗键"的办法(裸 `click()`、完整指针事件序列、四种 DOM 点法、
/// 播放器 API `onAdUxClicked`、seek 到结尾)—— 真机全部无效,YouTube 的跳过键只认**真实用户输入**。WebKit 对
/// 辅助功能的 `AXPress` 是按真实用户动作处理的(派出来的点击 `isTrusted == true`),这是不装浏览器扩展、不把
/// Safari 拉到前台的前提下唯一走得通的路。2026-09-08 22:17 真机试验(终端进程持辅助功能权限,对 Safari 里那颗
/// `AXButton title=[跳过]` 执行 AXPress):`success`,1.5s 后播放器离开 `ad-showing`、视频切到正片 1.2/230s。
///
/// ## 找哪颗键
///
/// Safari / Chromium 都把**当前标签页**的网页挂在窗口的 AX 树里(`AXWebArea`,带 `AXURL`);后台标签页不在树里 ——
/// 所以 YT Music 标签页不是它那扇窗口的当前标签页时找不到 web area,回 `.webAreaNotFound`,由调用方提示用户切过去。
/// 在 URL 含 `music.youtube.com` 的 web area 里找 `AXButton`,**按 DOM class 认**(`AXDOMClassList` 含
/// `ytp-ad-skip-button…` / `ytp-skip-ad-button…`,跟 `YouTubeMusicAdSkipper.skipJS` 的选择器同源)—— 不按标题文字,
/// 标题跟着 YouTube 界面语言走(跳过 / Skip / 略過 / スキップ…)。标题只做兜底(`skipButtonTitles`)。
///
/// ## 权限
///
/// 要用户在「系统设置 → 隐私与安全性 → 辅助功能」里勾上 Lyrimuse。`isTrusted` 为 false 时不动手、回 `.notTrusted`,
/// 由调用方 `promptForTrust()` 弹系统那个"想要控制这台电脑"的对话框 + 横幅说明。⚠️ **ad-hoc 签名的构建(build.sh
/// `codesign --sign -`)每次重装 cdhash 都变**,TCC 存的是按 cdhash 的 designated requirement —— 重装之后设置里那个勾
/// 还在,但 `AXIsProcessTrusted()` 回 false,要用户把勾**取消再勾上**。发布包同样是 ad-hoc(这台机器没有签名证书),
/// 所以每次升级之后第一次按「跳过广告」都会再提示一次。这是签名方式的限制,不是 bug;换 Developer ID 签名才能根治。
///
/// 只读遍历 + 对一颗按钮做一次 `AXPress`,不动别的元素、不改焦点、不把浏览器拉到前台。
public enum AccessibilitySkipPress {
    public enum Outcome: Equatable, Sendable {
        /// 按下去了(`desc` 是那颗键的 class / 标题,只为日志)。按下去不等于跳过了 —— 调用方另行复核。
        case pressed(desc: String)
        /// App 没有辅助功能权限。
        case notTrusted
        /// YT Music 标签页不是任何一扇窗口的当前标签页(后台标签页不在 AX 树里),或者这个浏览器压根
        /// 不把网页挂进 AX 树(Chromium 系要先设 `AXManualAccessibility`,见 press 头注)。
        case webAreaNotFound
        /// 那个浏览器此刻没在跑 —— 跟"树里找不到"是两件事,提示给用户的话也不一样
        /// (2026-09-11 拆开:此前两者同归 `.webAreaNotFound`,于是浏览器没在跑时也提示"把标签页切到前面",
        /// 而真正的排查线索一个字都没留下)。
        case browserNotRunning
        /// web area 找到了,但里面没有跳过键(广告刚结束 / 页面结构变了)。
        case buttonNotFound
        /// `AXUIElementPerformAction` 返回了错误码。
        case pressFailed(code: Int32)
    }

    /// 跳过键的 DOM class 前缀,跟 `YouTubeMusicAdSkipper.skipJS` 里的选择器同源(那边是 `.ytp-ad-skip-button-modern`
    /// / `.ytp-ad-skip-button` / `.ytp-skip-ad-button`…),改一边要改另一边,selftest 钉着两边对得上。
    public static let skipButtonClassPrefixes = ["ytp-ad-skip-button", "ytp-skip-ad-button"]
    /// 按标题兜底(class 读不到时)。只列实测见过的几种界面语言。
    public static let skipButtonTitles = ["跳过", "略過", "Skip", "スキップ", "건너뛰기"]

    /// 一组 DOM class 里有没有跳过键的(纯函数,selftest 钉着)。⚠️ 排除 `…-slot` / `…-container` / `…-text` /
    /// `…-icon` 这些包裹 / 子元素 —— 它们的 class 同样以那个前缀开头,但不是 `<button>`;AX 树里它们多半不是 AXButton,
    /// 这里再挡一道。
    public static func matchesSkipClass(_ classes: [String]) -> Bool {
        classes.contains { cls in
            skipButtonClassPrefixes.contains { prefix in
                guard cls.hasPrefix(prefix) else { return false }
                let rest = cls.dropFirst(prefix.count)
                return rest.isEmpty || rest == "-modern" || rest.hasPrefix("-icon-")
            }
        }
    }

    public static func matchesSkipTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return skipButtonTitles.contains { t == $0 || t.hasPrefix($0 + " ") }
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹系统的授权对话框(macOS 自己会带「打开系统设置」按钮)。已授权时什么都不弹。
    public static func promptForTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 找不到网页区域时**隔多久再试一次**(2026-09-11)。
    ///
    /// WebKit 的网页 AX 树是**按需建**的:进程里没有辅助功能客户端时压根不建,来了客户端才开始建、而且是
    /// 异步的。表现就是"刚给完授权那一下第一次按,树里什么都没有;隔一会儿再按就好了" —— 真机 2026-09-11
    /// 撞上:App 报 no web area 的同一时刻,另一个早就持有权限的进程用**逐字相同的遍历**能在 depth=6 找到
    /// 那块 `AXWebArea`。查询本身也会偶发 `kAXErrorCannotComplete`(浏览器忙、AX 消息超时)。
    /// 一次 250ms 的重试把这两种瞬态都盖住,代价是失败路径多等 0.25s(成功路径一分不多)。
    public static let webAreaRetryDelay: TimeInterval = 0.25

    /// 在 `browserBundleID` 那个浏览器的当前标签页里找 YT Music 的跳过键并按一下。同步,遍历 ~10ms 量级
    /// (找不到网页区域时多一次 `webAreaRetryDelay` 的重试)。
    public static func press(browserBundleID: String, hostMarker: String) -> Outcome {
        guard isTrusted else { return .notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browserBundleID).first else {
            logger.info("ax: browser \(browserBundleID, privacy: .public) not running")
            return .browserNotRunning
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var webArea = locateWebArea(appElement, hostMarker: hostMarker)
        if webArea == nil {
            // 热身重试,见 webAreaRetryDelay。
            Thread.sleep(forTimeInterval: webAreaRetryDelay)
            webArea = locateWebArea(appElement, hostMarker: hostMarker)
        }
        guard let webArea else {
            // ⚠️ 失败时把**看到了什么**记下来 —— 此前只有一句"没找到",而这条链路上"没找到"至少有四种
            // 成因(后台标签页 / Chromium 不挂网页树 / AX 查询超时 / 折错了浏览器),一句话里看不出是哪种。
            let windows = children(appElement).filter { role($0) == "AXWindow" }
            var urls: [String] = []
            for window in windows { collectWebAreaURLs(window, depth: 0, into: &urls) }
            logger.info("""
                ax: no web area for \(hostMarker, privacy: .public) in \(browserBundleID, privacy: .public)                 (pid \(app.processIdentifier), windows=\(windows.count),                 webAreas=\(urls.count): \(urls.joined(separator: " | "), privacy: .public))
                """)
            return .webAreaNotFound
        }
        guard let button = findSkipButton(webArea, depth: 0) else { return .buttonNotFound }
        let desc = describe(button)
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else {
            logger.info("ax: press failed \(result.rawValue) on \(desc, privacy: .public)")
            return .pressFailed(code: result.rawValue)
        }
        return .pressed(desc: desc)
    }

    // MARK: - AX 遍历

    private static let maxDepth = 60

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func role(_ element: AXUIElement) -> String {
        (attribute(element, kAXRoleAttribute) as? String) ?? ""
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// 遍历所有顶层 `AXWindow` 找命中的网页区域。抽出来是因为热身重试要跑第二遍同样的事。
    private static func locateWebArea(_ appElement: AXUIElement, hostMarker: String) -> AXUIElement? {
        for window in children(appElement) where role(window) == "AXWindow" {
            if let hit = findWebArea(window, hostMarker: hostMarker, depth: 0) { return hit }
        }
        return nil
    }

    /// 只为诊断:把树里所有 `AXWebArea` 的 URL 收上来(host 部分就够判"是不是那一页",别把整条带参数的
    /// 地址写进日志)。
    private static func collectWebAreaURLs(_ element: AXUIElement, depth: Int, into out: inout [String]) {
        guard depth <= maxDepth else { return }
        if role(element) == "AXWebArea" {
            let raw = (attribute(element, "AXURL") as? URL)?.absoluteString
                ?? (attribute(element, "AXURL") as? String) ?? "(无 AXURL)"
            out.append(URL(string: raw)?.host ?? String(raw.prefix(40)))
            return
        }
        for child in children(element) { collectWebAreaURLs(child, depth: depth + 1, into: &out) }
    }

    private static func findWebArea(_ element: AXUIElement, hostMarker: String, depth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        if role(element) == "AXWebArea" {
            let url = (attribute(element, "AXURL") as? URL)?.absoluteString
                ?? (attribute(element, "AXURL") as? String) ?? ""
            return url.contains(hostMarker) ? element : nil
        }
        for child in children(element) {
            if let hit = findWebArea(child, hostMarker: hostMarker, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func findSkipButton(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        if role(element) == "AXButton" {
            let classes = (attribute(element, "AXDOMClassList") as? [String]) ?? []
            if matchesSkipClass(classes) { return element }
            if classes.isEmpty, matchesSkipTitle((attribute(element, kAXTitleAttribute) as? String) ?? "") {
                return element
            }
        }
        for child in children(element) {
            if let hit = findSkipButton(child, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func describe(_ element: AXUIElement) -> String {
        let classes = ((attribute(element, "AXDOMClassList") as? [String]) ?? []).joined(separator: ".")
        let title = (attribute(element, kAXTitleAttribute) as? String) ?? ""
        return "AXButton[\(title)].\(classes)"
    }
}
