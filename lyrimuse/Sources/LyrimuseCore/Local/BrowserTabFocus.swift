import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "ytmusic-skip")

/// 把正在放广告的 YT Music 标签页**临时**设成它那扇窗口的当前标签页,按完跳过键再切回去。
///
/// 为什么要切:跳过键只认真实用户输入,唯一走得通的是辅助功能 `AXPress`(见 `AccessibilitySkipPress`),
/// 而 Safari / Chromium 只把每扇窗口的**当前**标签页挂进 AX 树,后台标签页按不到。门槛那段只读 JS
/// 在后台标签页里照样跑得通,所以"能跳了"是知道的,缺的只是按键那一下够不着。
///
/// 切的边界(`avoidFrontWindow`):浏览器就是用户此刻在用的 App、而那个标签页又在它最前面那扇窗口里时
/// **不切** —— 那是用户正在看的页面,切走一秒会打断阅读或输入,回 `.frontWindow`。其余情形(浏览器在后台、
/// 或者标签页在另一扇窗口里)切过去按完再切回来,只改那扇窗口的当前标签页,不激活浏览器、不动窗口顺序。
///
/// 切回去之前先确认那扇窗口的当前标签页**还是**我们切过去的那个:用户在这一两秒里自己点了别的标签页,
/// 就不替他切回旧的那个。
///
/// 通道同 `BrowserTabProbeScript`:AppleScript 写进临时文件交给 osascript,JS 里不许出现双引号和反斜杠。
public enum BrowserTabFocus {
    public enum Result: Equatable, Sendable {
        /// 那个标签页本来就是它那扇窗口的当前标签页,不用切。
        case alreadyCurrent
        /// 切过去了。`windowID` 是那扇窗口的 AppleScript id,`previousIndex` 是切之前的当前标签页序号,
        /// `tabIndex` 是 YT Music 那一页的序号 —— 切回去时用。
        case switched(windowID: Int, previousIndex: Int, tabIndex: Int)
        /// 标签页在用户正在看的那扇窗口里,不切。
        case frontWindow
        /// 没有哪个 YT Music 标签页处于广告态。
        case notFound
    }

    /// 认"正在放广告的那一页":`#movie_player` 挂着 `ad-showing`。只读。
    public static let adTabJS = "(function(){var p=document.querySelector('#movie_player');return (p&&p.classList.contains('ad-showing'))?'AD':'NOAD';})()"

    public static func focusScript(bundleID: String, family: BrowserAutomationPermission.Family,
                                   hostMarker: String, avoidFrontWindow: Bool, eventTimeoutSeconds: Int) -> String {
        let executeTab: String
        let currentIndex: String
        let switchTab: String
        switch family {
        case .chromium:
            executeTab = "execute (tab ti of window wi) javascript \"\(adTabJS)\""
            currentIndex = "active tab index of window wi"
            switchTab = "set active tab index of window wi to ti"
        case .safari:
            executeTab = "do JavaScript \"\(adTabJS)\" in tab ti of window wi"
            currentIndex = "index of current tab of window wi"
            switchTab = "set current tab of window wi to tab ti of window wi"
        }
        return """
        tell application id "\(bundleID)"
            set winCount to count of windows
            repeat with wi from 1 to winCount
                set tabCount to 0
                try
                    set tabCount to count of tabs of window wi
                end try
                repeat with ti from 1 to tabCount
                    try
                        if (URL of tab ti of window wi) contains "\(hostMarker)" then
                            with timeout of \(eventTimeoutSeconds) seconds
                                set r to \(executeTab)
                            end timeout
                            if r is "AD" then
                                set curIdx to \(currentIndex)
                                if curIdx is ti then return "ALREADY"
                                if \(avoidFrontWindow ? "true" : "false") and wi is 1 then return "FRONTWINDOW"
                                set wid to id of window wi
                                \(switchTab)
                                return "SWITCHED|" & wid & "|" & curIdx & "|" & ti
                            end if
                        end if
                    end try
                end repeat
            end repeat
            return "NOTFOUND"
        end tell
        """
    }

    public static func restoreScript(bundleID: String, family: BrowserAutomationPermission.Family,
                                     windowID: Int, previousIndex: Int, tabIndex: Int) -> String {
        let body: String
        switch family {
        case .chromium:
            body = "if (active tab index of w) is \(tabIndex) then set active tab index of w to \(previousIndex)"
        case .safari:
            body = "if (index of current tab of w) is \(tabIndex) then set current tab of w to tab \(previousIndex) of w"
        }
        return """
        tell application id "\(bundleID)"
            try
                set w to window id \(windowID)
                \(body)
            end try
            return "OK"
        end tell
        """
    }

    /// 切换脚本的返回 → `Result`。纯函数,selftest 钉着。先脱 AppleScript 偶尔包上的一层双引号。
    public static func parse(_ raw: String) -> Result? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { s = String(s.dropFirst().dropLast()) }
        let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "ALREADY": return .alreadyCurrent
        case "FRONTWINDOW": return .frontWindow
        case "NOTFOUND": return .notFound
        case "SWITCHED":
            guard parts.count == 4, let w = Int(parts[1]), let prev = Int(parts[2]), let ti = Int(parts[3]) else { return nil }
            return .switched(windowID: w, previousIndex: prev, tabIndex: ti)
        default: return nil
        }
    }

    /// 找到正在放广告的 YT Music 标签页,需要就切过去。同步阻塞(一次 AppleEvent 往返),调用方放后台。
    /// nil = 脚本没跑成或返回看不懂。
    public static func focusAdTab(bundleID: String, family: BrowserAutomationPermission.Family,
                                  avoidFrontWindow: Bool) -> Result? {
        let source = focusScript(bundleID: bundleID, family: family, hostMarker: YouTubeMusicAdProbe.hostMarker,
                                 avoidFrontWindow: avoidFrontWindow,
                                 eventTimeoutSeconds: YouTubeMusicAdProbe.eventTimeoutSeconds)
        guard let out = runScript(source, label: "ytmusic-focus") else {
            logger.notice("focus: script did not run")
            return nil
        }
        let result = parse(out)
        logger.notice("focus: \(out.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public) avoidFront=\(avoidFrontWindow, privacy: .public)")
        return result
    }

    /// 切回去(那扇窗口的当前标签页还是 YT Music 那一页时才切)。
    public static func restore(bundleID: String, family: BrowserAutomationPermission.Family,
                               windowID: Int, previousIndex: Int, tabIndex: Int) {
        let source = restoreScript(bundleID: bundleID, family: family, windowID: windowID,
                                   previousIndex: previousIndex, tabIndex: tabIndex)
        let ok = runScript(source, label: "ytmusic-restore") != nil
        logger.notice("focus: restore window \(windowID) tab \(previousIndex) ok=\(ok, privacy: .public)")
    }

    private static func runScript(_ source: String, label: String) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-\(label)-\(UUID().uuidString).applescript")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let result = ProcessRunner.run("/usr/bin/osascript", [url.path],
                                             timeout: YouTubeMusicAdProbe.processTimeout),
              result.succeeded
        else { return nil }
        return result.stdoutText
    }
}
