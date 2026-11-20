import Foundation

// 「在某个浏览器里,找到匹配某个域名的标签页,在它上面跑一段 JS,把返回值拿回来」——
// 这件事的**唯一一份**实现(抽出来)。
//
// 抽出来的直接原因:`SpotifyWebAdProbe` 要跟 `YouTubeMusicAdProbe` 做一模一样的事,只是
// 域名和 JS 不同。而这段 AppleScript 模板里每一行都是踩出来的(下面逐条记着),复制第二份
// 等于把那些教训复制一份、然后等它们慢慢漂开。
//
// **不包括** `BrowserPositionProbe` 那一份。那边看着像,实际多两样东西:JS 里有
// `__EXPECT__`/`__TOL__` 占位符要在拼进 AppleScript **之前**替换,而且它按"用户配对过哪些
// 平台"逐条试多份站点规则(`siteRules`)、命中即返回。硬套进来会让这个函数长出两个只有
// 一个调用方用得上的参数。等第三个调用方出现、且形状真的一样时再说。
//
// ---- 这段模板里每一行的来历(别顺手简化掉任何一条) ----
//
//  * `tell application id "<bundleID>"` 而不是写死 App 显示名:对
//    Arc/Chrome/Edge/Safari 逐个实测坐实,不受"App 被改名 / 装了 Canary 之类的变体"影响。
//  * **先扫各窗口的当前标签页,再扫其余标签页**:Arc 会休眠非当前标签页,对休眠标签页执行
//    JavaScript 会一直不返回、只能等 `with timeout` 踢掉,每踢一个吃掉一秒预算。用户开几十个
//    标签页是常态(实测这台机器 50 个)。当前标签页是唯一保证活着的,而"正在放歌的那个"很多
//    时候就是它。
//  * `with timeout of N seconds` **不能省**:没有它时"浏览器不回"表现为 osascript 挂死到被
//    进程级超时杀掉,裸 `try` 抓不住挂起。
//  * 裸 `try … end try`:吞掉单个标签页的错误继续找下一个。数标签页那一步也包着:扫到一半有窗口被关、或者是个
//    没有标签页的非网页窗口时,不包的话整次脚本失败。
//  * **暂停的标签页排在后面**:JS 在视频暂停时给结果加 `PAUSED:` 前缀,模板把它记成备选、接着找在播的那一页,
//    都找完了才交回备选(去掉前缀)。开着好几个 YouTube Music 标签页时,排在前面的那页常常是暂停着、放着别的歌的,
//    拿它的读数判广告、补专辑名、复核跳过都会错;只有一个标签页时结果跟原来一样。引擎的 browsertab.go 同一份。
//    只剩暂停页时交回的备选不一定就是正在出声的那一页(普通 www.youtube.com 视频在放、YouTube Music 页暂停着),
//    所以 YouTube Music 的探针和网页版控制在 JS 里先核对页面标题(`YouTubeMusicAdProbe.titleGuardJS`),快照在放时广告探针
//    让暂停页只回一个认不出的 `STALE`(02 章决策 150)。
//  * Chromium 系和 Safari 的 JS 注入命令**不同名**(实测坐实,不是同一个词的两种
//    写法):Chromium 是 `execute (tab) javascript "…"`,Safari 是 `do JavaScript "…" in tab`。
//    窗口/标签枚举语法(`count of windows`/`tabs of window`/`URL of tab`)两边一致。
//  * 脚本**写进临时文件**再执行,不用 `osascript -e`:里面嵌着一整段 JS、JS 里又有单引号和
//    逗号,拿 -e 传要在 shell/exec 层再套一层引号,是本仓库明确记过的"多层引号把 payload
//    打坏"那类坑。写文件是零转义的。
//
// **调用方给的 JS 里不许出现双引号**。它整段要嵌进 AppleScript 的双引号字符串,而
// `execute … javascript` 会把返回值里已有的双引号**真的**转义成反斜杠(不是显示转义,是
// 字符串本身多了真实的 `\`),整段被二次转义之后拿去比 `contains` 会稳定判 false。
// 各探针的 selftest 都有一条守卫钉这件事。
public enum BrowserTabProbeScript {
    /// 把一段要读页面自己的 JS 属性的 JS 包成两种执行环境下都读得到的样子,返回整段 IIFE。
    ///
    /// Safari 的 `do JavaScript` 跑在页面主环境;Chromium 系的 `execute javascript` 跑在 AppleScript 专用的隔离环境:
    /// DOM 共用,页面挂在元素上的 JS 属性(Polymer 组件的 `data`、React 的 `__reactFiber…`、播放器元素的
    /// `getPlayerResponse`)在那里一律是 undefined。见 02 章决策 285。
    ///
    /// - Parameter core: JS 函数表达式(`function(){ … return 字符串; }`),在看得见页面属性的环境里调用它拿结果。
    /// - Parameter pageVisible: JS 表达式,当前环境已经看得见页面属性(或者根本用不着注入)时为真:这时直接调 `core`,
    ///   不往页面里插任何东西,Safari 走的就是这一条。
    ///
    /// 看不见时把 `core` 的源码(`Function.prototype.toString`)放进一个 `<script>` 插进页面再立刻移除:内联脚本同步跑在
    /// 主环境,结果写到 `<html>` 的 `pageWorldAttribute` 属性上,读回来后删掉。插脚本要过页面 CSP 的两道:脚本 nonce
    /// (抄页面已有脚本的 `nonce`)和 Trusted Types(建一个原样放行的策略 `lyrimuse-page-world`,建过就复用)。
    /// 任何一步失败回 `NOTFOUND`,跟读不到一样。`core` 和 `pageVisible` 同样不许有双引号和反斜杠。
    public static func inPageWorld(core: String, pageVisible: String) -> String {
        [
            "(function(){",
            "var core = \(core);",
            "if (\(pageVisible)) return core();",
            "var de = document.documentElement, key = '\(pageWorldAttribute)', out = null;",
            "de.removeAttribute(key);",
            "try {",
            "var tt = window.trustedTypes, pol = null;",
            "if (tt && tt.createPolicy) { pol = window.lyrimusePageWorldPolicy || (window.lyrimusePageWorldPolicy = tt.createPolicy('lyrimuse-page-world', { createScript: function(x){ return x; } })); }",
            "var src = 'try { document.documentElement.setAttribute(' + JSON.stringify(key) + ', String((' + core + ')())); } catch (e) {}';",
            "var s = document.createElement('script');",
            "var n = document.querySelector('script[nonce]');",
            "if (n && n.nonce) s.nonce = n.nonce;",
            "s.textContent = pol ? pol.createScript(src) : src;",
            "(document.head || de).appendChild(s);",
            "s.remove();",
            "out = de.getAttribute(key);",
            "} catch (e) {}",
            "de.removeAttribute(key);",
            "return out === null ? 'NOTFOUND' : out;",
            "})()",
        ].joined()
    }

    /// `inPageWorld` 从主环境带结果回来用的 `<html>` 属性名,读完就删。
    public static let pageWorldAttribute = "data-lyrimuse-page-world"

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
            set fallback to ""
            repeat with wi from 1 to winCount
                try
                    if (URL of \(activeTab)) contains "\(hostMarker)" then
                        with timeout of \(eventTimeoutSeconds) seconds
                            set r to \(executeActive)
                        end timeout
                        if r does not contain "NOTFOUND" then
                            if r starts with "PAUSED:" then
                                if fallback is "" then set fallback to text 8 thru -1 of r
                            else
                                return r
                            end if
                        end if
                    end if
                end try
            end repeat
            repeat with wi from 1 to winCount
                try
                    set tabCount to count of tabs of window wi
                on error
                    set tabCount to 0
                end try
                repeat with ti from 1 to tabCount
                    try
                        if (URL of tab ti of window wi) contains "\(hostMarker)" then
                            with timeout of \(eventTimeoutSeconds) seconds
                                set r to \(executeTab)
                            end timeout
                            if r does not contain "NOTFOUND" then
                                if r starts with "PAUSED:" then
                                    if fallback is "" then set fallback to text 8 thru -1 of r
                                else
                                    return r
                                end if
                            end if
                        end if
                    end try
                end repeat
            end repeat
            if fallback is not "" then return fallback
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
        guard FileIO.write(source, to: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let result = ProcessRunner.run("/usr/bin/osascript", [url.path],
                                             timeout: processTimeout),
              result.succeeded
        else { return nil }
        return result.stdoutText
    }
}
