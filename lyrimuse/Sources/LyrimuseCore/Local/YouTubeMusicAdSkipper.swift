import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "ytmusic-skip")

/// 「替用户按下 YouTube Music 里**平台已经放出来**的那颗『跳过广告』键」(2026-09-08,灵动岛广告态改版的一部分,
/// 用户拍板「选用可以跳过广告的方案」)。
///
/// ## 分工:门槛在 JS,动作在辅助功能
///
/// * **门槛**(`skipJS`,注入页面、只读):`#movie_player` 处于 `ad-showing` **且**跳过键(`.ytp-ad-skip-button-modern`
///   等)**有尺寸** —— 也就是 YouTube 自己已经把「跳过」放出来的那一刻(可跳过广告的第 5 秒起)。不可跳过的广告、
///   前 5 秒,一律原样回报「还不能跳过」,什么都不动。
/// * **动作**(`AccessibilitySkipPress`):对那颗键做一次辅助功能 `AXPress`。WebKit 把它当真实用户点击处理 ——
///   这是下面那一长串 JS 尝试全部失败之后唯一走得通的路(真机 22:17 坐实:AXPress success,1.5s 后广告走了)。
///   要用户给 App 授「辅助功能」权限;没授时回 `.needsAccessibility`,由 UI 弹系统对话框 + 横幅说明。
/// * **复核**(`verifyJS`):按完等 `verifyDelay` 再探一次,广告真走了才回 `.skipped`。
///
/// ## JS 这一侧能做的都试过了(2026-09-08 一天五版,真机日志 `ytmusic-skip` 类别)
///
/// 首版裸 `.click()`;第二版完整指针事件序列;第三版四种 DOM 点法(mousemove 唤出控件 + `pointerType: mouse`
/// 序列 / 发给文字节点 / `focus()+click()` / 键盘 Enter)逐个试逐个复核;第四版调播放器自己的 API
/// `onAdUxClicked('skip-button', <id>)` —— **全部** `verify=STILL`,广告视频时间逐秒照走(20:07、20:15、20:25
/// 三条广告)。结论:这个播放器的跳过键只认真实用户输入(`isTrusted` 那一类检查)。第五版按用户拍板改成
/// 「跳过键有尺寸时把 `<video>.currentTime` 拨到 `duration`」—— 真机(21:59,八次)**广告从头重放**:seek 一落,
/// 视频时间归 0、徽章仍是 1/2,等于把 20 秒广告再看一遍,比不动更糟,当场撤掉;顺带暴露 `adAdvanced` 那条
/// "视频时间倒回 = 跳到下一条了"的判据是错的(重放也倒回),已删,只认徽章翻页 / 离开广告态。
/// **JS 注入这条路到此为止**:DOM 事件、播放器 API、seek 三类都不认。所以 JS 只留"看门"(有没有放出跳过键、
/// 还剩几秒、广告徽章 / 视频时间供复核),按键交给 `AccessibilitySkipPress`(第六版,见那个文件头注)。
///
/// ## 跑在哪、怎么跑
///
/// 跟 `YouTubeMusicAdProbe` 同一条通道:`BrowserTabProbeScript.run` 在配对过的浏览器里按域名找到
/// YT Music 标签页、注入一段 JS、拿回返回值(那段 AppleScript 模板里每一行的来历见那个文件的头注)。
/// 一次往返 ~0.2s、会阻塞,调用方自己放到后台线程。
///
/// ⚠️ **JS 里不许出现双引号,也别用反斜杠**(它整段要嵌进 AppleScript 的双引号字符串,双引号的问题见
/// `BrowserTabProbeScript` 头注;反斜杠会先被 AppleScript 当转义序列吃掉,`\\s` `\\d` 这类正则写不出来 ——
/// 用 `[0-9]` / `String.fromCharCode` 绕),selftest 钉着。
///
/// ⚠️ 多标签页:模板对每个匹配域名的标签页依次执行,返回值**不含** `NOTFOUND` 就停下来。所以这段 JS
/// 对"有播放器但此刻不在广告态"的标签页也回 `NOTFOUND`,让搜索继续到真正在放广告的那一页 ——
/// 代价是分不清"广告刚结束"和"没有标签页",两种情况对用户的反馈是同一句(见 `Outcome.notFound`)。
///
/// ## 真机抓到的页面长什么样(2026-09-08,Safari,只读 DOM 监控)
///
/// 广告开始后 5 秒内:`#preskip-component.ytp-ad-preview-slot` 里 `.ytp-ad-preview-text-modern` 写着
/// 「你可以在 N 秒后 跳转到视频」,跳过键 `BUTTON.ytp-ad-skip-button-modern.ytp-button` 在 DOM 里但 0×0。
/// 5 秒后:按钮 87×36;它的容器因为播放器 `ytp-autohide`(控件自动隐藏)opacity 0 —— 有尺寸但看不见。
/// 广告徽章 `.ytp-ad-simple-ad-badge` 写着「赞助商广告 1/2 ·」—— 一次插播可能连放两条,跳过第一条之后
/// 播放器**仍在** `ad-showing`,只是徽章翻成 2/2、`video.currentTime` 归零(复核认这种"跳到下一条了",见 `adAdvanced`)。
///
/// ## 做完要复核
///
/// 动完等 `verifyDelay` 再探一次(`verifyJS`):播放器离开广告态、或徽章翻页(1/2 → 2/2)→ `.skipped`;
/// 同一条广告还在走 → `.clickedNoEffect`,用户看到「没能跳过这条广告」而不是一片安静。每一步记日志。
public enum YouTubeMusicAdSkipper {
    public enum Outcome: Equatable, Sendable {
        /// 按下去了,而且复核时广告已经走了(播放器离开广告态,或翻到了插播里的下一条)。
        case skipped
        /// 播放器在放广告,但跳过键还没出现 / 没有尺寸 —— 平台还没允许跳过。`secondsUntilSkippable` 是页面上
        /// 「N 秒后可跳过」那个数(读得到才有;不可跳过的广告没有这个提示,是 nil)。
        case notYetSkippable(secondsUntilSkippable: Int?)
        /// 按下去了(或按不下去),复核时同一条广告仍在放。
        case clickedNoEffect
        /// 没有任何一个 YT Music 标签页处于广告态(广告刚结束、标签页关了、页面结构变了都归这里)。
        case notFound
        /// 门槛过了,但 App 没有「辅助功能」权限,按不了。UI 层弹系统授权对话框 + 横幅。
        case needsAccessibility
        /// 门槛过了、权限也有,但 YT Music 标签页不是它那扇窗口的**当前**标签页 —— 后台标签页不在 AX 树里,按不到。
        case tabNotFrontmost
    }

    /// 门槛脚本的返回。
    public enum ClickResult: Equatable, Sendable {
        /// 跳过键有尺寸、可以按了。`desc` 那颗键的 tag.class(只为日志);`badge` 当时的广告徽章文字(如「赞助商广告 1/2 ·」)、
        /// `videoTime` 当时广告视频走到的整秒 —— 两者给复核用来认"翻到下一条了"。
        case skippable(desc: String, badge: String, videoTime: Int)
        case notYet(seconds: Int?)
        case notFound
    }

    /// 复核脚本的返回。
    public enum VerifyResult: Equatable, Sendable {
        /// 播放器仍在广告态;带当时的徽章与视频时间,跟动作时的比。
        case still(badge: String, videoTime: Int)
        /// 有播放器、不在广告态。
        case clear
        case notFound
    }

    /// 门槛脚本(**只读**,不动页面)。返回值形状:
    ///   `SKIPPABLE|<tag>.<class>|<徽章文字>|<视频整秒>` / `NOTYET|<秒数或空>` / `NOTFOUND`。
    /// 找**有尺寸**的跳过键(选择器按 YouTube 播放器近几年的几套命名都列上,真机抓到的是 `.ytp-ad-skip-button-modern`;
    /// 按钮在 DOM 里提前就存在、只是 0×0,光 `querySelector` 命中不等于平台允许了),找不到就回 NOTYET。
    /// ⚠️ 这段脚本不派事件、不碰 `video.currentTime`(前五版试过的都在这儿,见类头注),selftest 钉着;选择器列表
    /// 跟 `AccessibilitySkipPress.skipButtonClassPrefixes` 同源。
    public static let skipJS = """
    (function(){\
    var p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');\
    if (!p) return 'NOTFOUND';\
    if ((p.className || '').indexOf('ad-showing') < 0) return 'NOTFOUND';\
    var badgeEl = document.querySelector('.ytp-ad-simple-ad-badge, .ytp-ad-badge');\
    var badge = badgeEl ? String(badgeEl.textContent || '').trim() : '';\
    var v = p.querySelector('video');\
    var vt = v ? Math.floor(v.currentTime) : -1;\
    var sel = ['.ytp-skip-ad-button', '.ytp-ad-skip-button-modern', '.ytp-ad-skip-button', '.ytp-ad-skip-button-slot button', '.ytp-ad-skip-button-container button', '.ytp-skip-ad button', 'button[id^=skip-button]'];\
    var b = null;\
    for (var i = 0; i < sel.length && !b; i++) {\
    var list = p.querySelectorAll(sel[i]);\
    for (var j = 0; j < list.length; j++) {\
    var rr = list[j].getBoundingClientRect();\
    if (rr.width > 0 && rr.height > 0) { b = list[j]; break; }\
    }\
    }\
    if (!b) {\
    var prev = document.querySelector('.ytp-ad-preview-text-modern, .ytp-preview-ad__text, .ytp-ad-preview-text, .ytp-ad-preview-container');\
    var m = prev ? String(prev.textContent || '').match(/[0-9]+/) : null;\
    return 'NOTYET|' + (m ? m[0] : '');\
    }\
    var desc = b.tagName + '.' + String(b.className || '').split(' ').join('.');\
    return 'SKIPPABLE|' + desc + '|' + badge + '|' + vt;\
    })()
    """

    /// 复核脚本:动完之后播放器还在不在广告态。`STILL|<徽章>|<视频整秒>` / `CLEAR` / `NOTFOUND`。
    /// 多标签页时 `CLEAR` 也会让模板停在这一页 —— 复核只关心"刚动的那一页"。
    public static let verifyJS = """
    (function(){\
    var p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');\
    if (!p) return 'NOTFOUND';\
    if ((p.className || '').indexOf('ad-showing') < 0) return 'CLEAR';\
    var badgeEl = document.querySelector('.ytp-ad-simple-ad-badge, .ytp-ad-badge');\
    var badge = badgeEl ? String(badgeEl.textContent || '').trim() : '';\
    var v = p.querySelector('video');\
    var vt = v ? Math.floor(v.currentTime) : -1;\
    return 'STILL|' + badge + '|' + vt;\
    })()
    """

    /// 动完到复核之间等多久。页面切正片 / 切下一条广告要一两百毫秒;等太短会把成功误判成没生效,等太长用户等横幅。
    public static let verifyDelay: TimeInterval = 0.8

    public static func parseClick(_ raw: String) -> ClickResult? {
        let parts = fields(raw)
        switch parts.first {
        case "SKIPPABLE":
            guard parts.count >= 4 else { return nil }
            return .skippable(desc: parts[1], badge: parts[2], videoTime: Int(parts[3]) ?? -1)
        case "NOTYET":
            return .notYet(seconds: parts.count > 1 ? Int(parts[1]) : nil)
        case "NOTFOUND":
            return .notFound
        default:
            return nil
        }
    }

    public static func parseVerify(_ raw: String) -> VerifyResult? {
        let parts = fields(raw)
        switch parts.first {
        case "STILL":
            guard parts.count >= 3 else { return nil }
            return .still(badge: parts[1], videoTime: Int(parts[2]) ?? -1)
        case "CLEAR": return .clear
        case "NOTFOUND": return .notFound
        default: return nil
        }
    }

    /// 「按了之后广告走了没」的判据(纯函数,selftest 钉着):播放器离开广告态算走了;仍在广告态但**徽章文字变了**
    /// (「1/2」→「2/2」)也算 —— 那是跳过了这一条、插播里的下一条接上了。⚠️ **视频时间倒回不算**:第五版 seek 那次
    /// 真机坐实,YouTube 对被 seek 的广告是从头重放(时间归 0、徽章不变),按"倒回 = 下一条了"会把重放误报成跳过。
    /// 徽章为空时只认离开广告态。`videoTime` 仍带着,只为日志。
    public static func adAdvanced(afterClick click: ClickResult, verify: VerifyResult) -> Bool {
        switch verify {
        case .clear, .notFound:
            return true
        case .still(let badge, _):
            guard case .skippable(_, let gateBadge, _) = click else { return false }
            return !badge.isEmpty && !gateBadge.isEmpty && badge != gateBadge
        }
    }

    /// 切字段:先脱 AppleScript 偶尔包上的一层双引号(同 `YouTubeMusicAdProbe.parse`),再按 `|` 切。
    private static func fields(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }

    /// 此刻这条「广告中」是不是 **YT Music 网页广告** —— 只有它是,「跳过广告」才有对象(Spotify 的广告
    /// 没有可点的东西)。判据 = 探针对这条曲目身份的**强信号**判定为广告(`cachedBadgeVerdict`:播放器
    /// 含 `ad-showing` 或页面有 `.ytp-ad-*` 徽章;只靠裸标题撑起来的读数是 nil,不算)。
    ///
    /// 只读缓存、不探页面:缓存由 `LocalPlaybackSource.apply()` 在「广告中」亮着时每拍踢一次探针来刷
    /// (广告态 5 秒一探),这里读到的最多旧 5 秒。可读有效期 60 秒,过期是 nil —— 对这个判据 nil 就是
    /// false,按钮消失,不会误显示。MV 的前贴片广告(`ad-showing` 为真、元数据却是正片的)同样是 `.ad`,
    /// 那颗键对它同样有效 —— 它确实是一条广告。
    public static func isYouTubeMusicAd(artist: String, title: String, now: Date = Date()) -> Bool {
        let key = YouTubeMusicAdProbe.trackKey(artist: artist, title: title)
        return YouTubeMusicAdProbe.shared.cachedBadgeVerdict(forKey: key, now: now) == .ad
    }

    /// 跑一次:门槛 → AXPress → 复核。同步、会阻塞(两次 AppleEvent 往返 + 一次 AX 遍历 + `verifyDelay`,正常 ~1.2s,
    /// 极端 6s 超时),调用方放后台;调用方自己保证**同一时刻只跑一份**(`NotchPlayback.skipAdInFlight`)—— 真机日志里
    /// 用户连按几下,几份并行的 run 交错,各自的复核读到的是别人按完的页面。nil = 连门槛脚本都没跑成(不是浏览器 /
    /// 没有自动化权限 / osascript 超时或非零退出)。
    ///
    /// `reportedBundleID` 是 media-control 报上来的那个(浏览器的媒体代理进程可能是
    /// `com.apple.WebKit.GPU` 之类),先按 `probeTargetBundleID` 折回浏览器本尊,再按 bundle 认方言 ——
    /// 跟 `YouTubeMusicAdProbe.kickIfNeeded` 同一条路。
    public static func skip(reportedBundleID: String?) -> Outcome? {
        guard let host = BrowserPositionProbe.probeTargetBundleID(forReported: reportedBundleID),
              !host.isEmpty,
              let family = BrowserAutomationPermission.family(forBundleID: host)
        else {
            logger.info("skip: no browser family for bundle \(reportedBundleID ?? "nil", privacy: .public)")
            return nil
        }
        guard let out = run(js: skipJS, host: host, family: family, label: "ytmusic-skip") else {
            logger.info("skip: script did not run (osascript failed / timed out)")
            return nil
        }
        guard let click = parseClick(out) else {
            logger.info("skip: unparseable output \(out, privacy: .public)")
            return nil
        }
        switch click {
        case .notYet(let seconds):
            logger.info("skip: not yet skippable (\(seconds.map(String.init) ?? "?", privacy: .public)s)")
            return .notYetSkippable(secondsUntilSkippable: seconds)
        case .notFound:
            logger.info("skip: no ad-showing player")
            return .notFound
        case .skippable(let desc, let badge, let videoTime):
            let press = AccessibilitySkipPress.press(browserBundleID: host, hostMarker: YouTubeMusicAdProbe.hostMarker)
            switch press {
            case .notTrusted:
                logger.info("skip: gate open (\(desc, privacy: .public)) but no accessibility trust")
                return .needsAccessibility
            case .webAreaNotFound:
                logger.info("skip: gate open but no YT Music web area in the AX tree (tab not frontmost?)")
                return .tabNotFrontmost
            case .buttonNotFound, .pressFailed, .browserNotRunning:
                // `.browserNotRunning` 理论上到不了这儿(门槛脚本刚刚才在那个浏览器里跑通),留着是为了
                // 编译期就把新增的失败态逼着处理掉;真出现了归"没能跳过",详情在 ytmusic-skip 日志里。
                logger.info("skip: gate open but AX press failed: \(String(describing: press), privacy: .public)")
                return .clickedNoEffect
            case .pressed(let pressedDesc):
                Thread.sleep(forTimeInterval: verifyDelay)
                let verifyRaw = run(js: verifyJS, host: host, family: family, label: "ytmusic-skip-verify")
                let verify = verifyRaw.flatMap(parseVerify)
                logger.info("skip: pressed \(pressedDesc, privacy: .public) (dom \(desc, privacy: .public)) badge=\(badge, privacy: .public) t=\(videoTime) → verify=\(verifyRaw ?? "nil", privacy: .public)")
                if let verify, adAdvanced(afterClick: click, verify: verify) { return .skipped }
                return .clickedNoEffect
            }
        }
    }

    // MARK: - 「那颗键该不该出现」(2026-09-11,用户:「如果当前广告不支持跳过的话就不要显示那个跳过的按钮」)

    /// 这条广告此刻能不能跳。
    ///
    /// 在此之前灵动岛那颗「跳过广告」只看"是不是 YT Music 的广告"就画出来了,于是**不可跳过的广告**上
    /// 也挂着一颗键,按下去只换来一句「这条广告还不能跳过」—— 一颗永远按不动的键比没有更糟。现在多问
    /// 一句页面:跳过键放出来没有。
    public enum Skippability: Equatable, Sendable {
        /// 跳过键已经在页面上、有尺寸 —— 按了真能跳。
        case ready
        /// 页面写着「N 秒后可跳过」:这条广告可跳,但还没到时候。
        case after(seconds: Int)
        /// 既没有跳过键、也没有倒计时提示 —— 这条广告平台不给跳。
        case never
        /// 没有标签页处于广告态(广告刚结束 / 标签页关了 / 页面结构变了)。
        case notInAd
    }

    /// 门槛脚本的返回 → `Skippability`。纯映射,selftest 钉着。
    ///
    /// ⚠️ `notYet(nil)` 才是「不给跳」:页面上那句「你可以在 N 秒后 跳转到视频」是**可跳过广告独有**的,
    /// 不可跳过的广告压根没有这个元素(真机 2026-09-08 抓过 DOM,见头注)。所以"读不到秒数"不是"读失败",
    /// 是"这条广告没有跳过这回事"。
    public static func skippability(from click: ClickResult) -> Skippability {
        switch click {
        case .skippable: return .ready
        case .notYet(let seconds): return seconds.map { .after(seconds: $0) } ?? .never
        case .notFound: return .notInAd
        }
    }

    /// UI 该不该画那颗键。
    ///
    /// ⚠️ **nil(门槛脚本压根没跑成)按"画"处理** —— 这是刻意的 fail-**open**,跟这个文件里其它地方的
    /// fail-closed 纪律相反,理由:脚本跑不成的原因(不是浏览器 / 没有自动化权限 / osascript 超时)对用户
    /// 是**不可见**的,这时候把键也藏了,用户看到的是"这个功能没了",连一句可诊断的话都拿不到;画出来、
    /// 按下去至少会得到「没能跳过这条广告」并走那条既有的反馈路径。真正要藏的是"页面明确告诉我们不给跳"
    /// 这一种(`.never`),以及"还没到点"(`.after`)和"广告已经结束"(`.notInAd`)。
    public static func showsSkipButton(_ state: Skippability?) -> Bool {
        guard let state else { return true }
        return state == .ready
    }

    /// 广告刚开头**先快探几拍**的轮数与间隔(2026-09-11)。
    ///
    /// 真机时间线(只读抓的,用户没碰鼠标):`t+0.2 never` → `t+5.4 after(1)` → `t+8.4 ready`。
    /// 第一拍的 `never` 不是"这条广告不给跳",是**页面那一刻还没渲染出**跳过键 / 「N 秒后可跳过」
    /// 那个预览元素;而按 5 秒心跳等下一拍,白白把提示推迟到第 8 秒之后 —— YouTube 通常第 5 秒就把
    /// 键放出来,用户在前 8 秒看到的是"没反应"(2026-09-11 用户原话:「还没有展开时,它并没有实时更新
    /// 这个图标」,当时我先怀疑视图失效,探针证明 body 在模型翻转后 20ms 就画上了,晚的是模型本身)。
    ///
    /// 所以头几拍按 1.2s 探:`t+0.2 / 1.4 / 2.6 / 3.8` 里总有一拍读到倒计时,读到之后就精确等到点
    /// (`.after` 那一档),提示落在第 5~6 秒 —— 跟页面真正放出键的时刻对齐。代价是每条广告多两三次
    /// AppleEvent 往返(~0.2s 一次,只在开头),换来的是提示不再迟到三秒。过了 `fastStartRounds`
    /// 之后的 `never` 才当真,退回 5 秒心跳。
    public static let fastStartRounds = 4
    public static let fastStartDelay: TimeInterval = 1.2

    /// 广告期间每隔多久再探一次门槛。`round` 从 0 起(第 0 次就是刚起轮询那一拍)。
    ///
    /// `.after(n)` 那一档直接等到点(多给 0.4s 让页面把键渲染出来)—— 不这么做就得干等下一个心跳,
    /// 一条 5 秒倒计时的广告最坏要到第 10 秒键才出现,而整条广告可能就 15 秒。`.never` 分两段:
    /// 开头 `fastStartRounds` 拍按 `fastStartDelay` 快探(见上),之后退回 5 秒心跳,跟
    /// `YouTubeMusicAdProbe.adRefreshInterval` 同一个节奏。`.ready` 也继续心跳 —— 一次插播可能连放
    /// 两条(徽章 1/2 → 2/2),第一条给跳、第二条不给,不盯着就会留一枚指向不存在的键的提示。
    /// 上限 20 秒挡住页面给出离谱数字。
    public static func gateRetryDelay(after state: Skippability, round: Int = .max) -> TimeInterval {
        switch state {
        case .after(let seconds): return min(max(Double(seconds), 1), 20) + 0.4
        case .never: return round < fastStartRounds ? fastStartDelay : YouTubeMusicAdProbe.adRefreshInterval
        case .ready: return YouTubeMusicAdProbe.adRefreshInterval
        case .notInAd: return 0   // 调用方这一档直接收摊,不再排下一次
        }
    }

    /// 一条广告最多探多少次门槛(兜底,挡住"广告态卡着不走"时无限往返)。5 秒一次 × 12 = 一分钟,
    /// 比任何一条插播都长。
    public static let gateMaxRounds = 12

    /// 门槛探测的**短缓存**(2026-09-11)。
    ///
    /// 灵动岛是**每块屏一份**(`NotchMirrorManager` 给每块屏建一个完整的 `NotchLyricsWindowController`,
    /// 各自一份 `NotchPlayback`),于是同一条广告会有 N 份轮询按同一个节奏起跳 —— 真机日志里每行都出现
    /// 两次就是这么来的(当时第二份是设置页的编辑台预览,已另行修掉)。这一份缓存让同一拍里的后来者直接
    /// 复用结果,不对浏览器多发 AppleEvent。TTL 取 1.5s:远小于 5s 心跳(不会让心跳读到陈旧值),
    /// 又足够盖住"几个实例几乎同时起跳"这一拍。
    private static let gateCacheTTL: TimeInterval = 1.5
    private static let gateCacheLock = NSLock()
    private static var gateCache: (state: Skippability, host: String, at: Date)?

    /// 探一次门槛:**只跑那段只读 JS,不按键、不复核**。同步阻塞(一次 AppleEvent 往返 ~0.2s),
    /// 调用方放后台线程。nil = 脚本没跑成(不是浏览器 / 没有自动化权限 / osascript 超时或非零退出)。
    ///
    /// 跟 `skip(reportedBundleID:)` 共用同一段 `skipJS` 和同一条通道 —— 判据只有一份,
    /// "键出现没有"不会在"画不画"和"按不按得动"两处各判一次、慢慢长歪。
    public static func probeSkippability(reportedBundleID: String?) -> Skippability? {
        guard let host = BrowserPositionProbe.probeTargetBundleID(forReported: reportedBundleID),
              !host.isEmpty,
              let family = BrowserAutomationPermission.family(forBundleID: host)
        else {
            logger.info("gate: no browser family for bundle \(reportedBundleID ?? "nil", privacy: .public)")
            return nil
        }
        gateCacheLock.lock()
        let cached = gateCache
        gateCacheLock.unlock()
        if let cached, cached.host == host, Date().timeIntervalSince(cached.at) < gateCacheTTL {
            return cached.state
        }
        guard let out = run(js: skipJS, host: host, family: family, label: "ytmusic-skip-gate") else {
            logger.info("gate: script did not run (host \(host, privacy: .public))")
            return nil
        }
        guard let click = parseClick(out) else {
            logger.info("gate: unparseable output \(out, privacy: .public)")
            return nil
        }
        let state = skippability(from: click)
        // 这条路以前一行日志都没有,于是"按钮该出现却没出现"根本无从排查(2026-09-11 用户报"展开态下
        // 按钮不会自己刷出来"时坐实:日志里一片空白,只能靠猜)。每次探一次记一行,够看清时间线。
        logger.info("gate: \(String(describing: state), privacy: .public) (host \(host, privacy: .public))")
        gateCacheLock.lock()
        gateCache = (state, host, Date())
        gateCacheLock.unlock()
        return state
    }

    private static func run(js: String, host: String, family: BrowserAutomationPermission.Family, label: String) -> String? {
        BrowserTabProbeScript.run(
            bundleID: host, family: family,
            hostMarker: YouTubeMusicAdProbe.hostMarker, js: js,
            eventTimeoutSeconds: YouTubeMusicAdProbe.eventTimeoutSeconds,
            processTimeout: YouTubeMusicAdProbe.processTimeout,
            label: label)
    }
}
