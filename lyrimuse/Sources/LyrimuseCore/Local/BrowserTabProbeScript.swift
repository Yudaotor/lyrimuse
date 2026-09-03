import Foundation

// 「在某个浏览器里,找到匹配某个域名的标签页,在它上面跑一段 JS,把返回值拿回来」——
// 这件事的**唯一一份**实现(2026-09-03 抽出来)。
//
// 抽出来的直接原因:`SpotifyWebAdProbe` 要跟 `YouTubeMusicAdProbe` 做一模一样的事,只是
// 域名和 JS 不同。而这段 AppleScript 模板里每一行都是踩出来的(下面逐条记着),复制第二份
// 等于把那些教训复制一份、然后等它们慢慢漂开。
//
// ⚠️ **不包括** `BrowserPositionProbe` 那一份。那边看着像,实际多两样东西:JS 里有
// `__EXPECT__`/`__TOL__` 占位符要在拼进 AppleScript **之前**替换,而且它按"用户配对过哪些
// 平台"逐条试多份站点规则(`siteRules`)、命中即返回。硬套进来会让这个函数长出两个只有
// 一个调用方用得上的参数。等第三个调用方出现、且形状真的一样时再说。
//
// ---- 这段模板里每一行的来历(别顺手简化掉任何一条) ----
//
//  * `tell application id "<bundleID>"` 而不是写死 App 显示名:2026-08-31 对
//    Arc/Chrome/Edge/Safari 逐个实测坐实,不受"App 被改名 / 装了 Canary 之类的变体"影响。
//  * **先扫各窗口的当前标签页,再扫其余标签页**:Arc 会休眠非当前标签页,对休眠标签页执行
//    JavaScript 会一直不返回、只能等 `with timeout` 踢掉,每踢一个吃掉一秒预算。用户开几十个
//    标签页是常态(实测这台机器 50 个)。当前标签页是唯一保证活着的,而"正在放歌的那个"很多
//    时候就是它。
//  * `with timeout of N seconds` **不能省**:没有它时"浏览器不回"表现为 osascript 挂死到被
//    进程级超时杀掉,裸 `try` 抓不住挂起。
//  * 裸 `try … end try`:吞掉单个标签页的错误继续找下一个。
//  * Chromium 系和 Safari 的 JS 注入命令**不同名**(2026-08-31 实测坐实,不是同一个词的两种
//    写法):Chromium 是 `execute (tab) javascript "…"`,Safari 是 `do JavaScript "…" in tab`。
//    窗口/标签枚举语法(`count of windows`/`tabs of window`/`URL of tab`)两边一致。
//  * 脚本**写进临时文件**再执行,不用 `osascript -e`:里面嵌着一整段 JS、JS 里又有单引号和
//    逗号,拿 -e 传要在 shell/exec 层再套一层引号,是本仓库明确记过的"多层引号把 payload
//    打坏"那类坑。写文件是零转义的。
//
// ⚠️ **调用方给的 JS 里不许出现双引号**。它整段要嵌进 AppleScript 的双引号字符串,而
// `execute … javascript` 会把返回值里已有的双引号**真的**转义成反斜杠(不是显示转义,是
// 字符串本身多了真实的 `\`),整段被二次转义之后拿去比 `contains` 会稳定判 false。
// 各探针的 selftest 都有一条守卫钉这件事。
public enum BrowserTabProbeScript {
    /// 拼出那段 AppleScript。公开只为让各探针的 selftest 能对它做文本断言。
    ///
    /// - Parameter hostMarker: 标签页 URL 要包含的域名片段(如 `music.youtube.com`)。
    /// - Parameter js: 要执行的 JS(不许含双引号,见类头注)。
    /// - Parameter eventTimeoutSeconds: 单条 AppleEvent 的 `with timeout` 秒数。
    public static func build(
        bundleID: String, family: BrowserAutomationPermission.Family,
        hostMarker: String, js: String, eventTimeoutSeconds: Int
    ) -> String {
        let activeTab: String
        let executeActive: String
        let executeTab: String
        switch family {
        case .chromium:
            activeTab = "active tab of window wi"
            executeActive = "execute (active tab of window wi) javascript \"\(js)\""
            executeTab = "execute (tab ti of window wi) javascript \"\(js)\""
        case .safari:
            activeTab = "current tab of window wi"
            executeActive = "do JavaScript \"\(js)\" in current tab of window wi"
            executeTab = "do JavaScript \"\(js)\" in tab ti of window wi"
        }
        return """
        tell application id "\(bundleID)"
            set winCount to count of windows
            repeat with wi from 1 to winCount
                try
                    if (URL of \(activeTab)) contains "\(hostMarker)" then
                        with timeout of \(eventTimeoutSeconds) seconds
                            set r to \(executeActive)
                        end timeout
                        if r does not contain "NOTFOUND" then
                            return r
                        end if
                    end if
                end try
            end repeat
            repeat with wi from 1 to winCount
                set tabCount to count of tabs of window wi
                repeat with ti from 1 to tabCount
                    try
                        if (URL of tab ti of window wi) contains "\(hostMarker)" then
                            with timeout of \(eventTimeoutSeconds) seconds
                                set r to \(executeTab)
                            end timeout
                            if r does not contain "NOTFOUND" then
                                return r
                            end if
                        end if
                    end try
                end repeat
            end repeat
            return "NOTFOUND"
        end tell
        """
    }

    /// 跑一次,返回 osascript 的裸输出。失败(写不出临时文件 / 起不来 / 非零退出)一律 nil,
    /// 由调用方按 fail-closed 处理。
    ///
    /// - Parameter label: 临时文件名里的标识(便于 `ls /var/folders/...` 时认出是谁留下的)。
    public static func run(
        bundleID: String, family: BrowserAutomationPermission.Family,
        hostMarker: String, js: String, eventTimeoutSeconds: Int,
        processTimeout: TimeInterval, label: String
    ) -> String? {
        let source = build(bundleID: bundleID, family: family, hostMarker: hostMarker,
                           js: js, eventTimeoutSeconds: eventTimeoutSeconds)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-\(label)-\(UUID().uuidString).applescript")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let result = ProcessRunner.run("/usr/bin/osascript", [url.path],
                                             timeout: processTimeout),
              result.succeeded
        else { return nil }
        return result.stdoutText
    }
}
