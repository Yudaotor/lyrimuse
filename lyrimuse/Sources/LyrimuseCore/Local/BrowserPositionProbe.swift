import Foundation

/// 浏览器播放位置的地面真值探针(2026-08-30 加)。
///
/// ## 背景:为什么需要绕开 MediaRemote
///
/// 见 docs/features/02-playback-source.md「锚点冻结的源(网页播放器)三件事」一节:Arc
/// 这类网页播放器只要页面没调 `mediaSession.setPositionState()`,MediaRemote 报的锚点
/// 就是冻结的(`elapsedTime` 恒为 0、`timestamp` 恒等于会话创建时刻),而这个创建时刻比
/// 音频真实起点晚一截(页面先出声、后注册元信息)——于是整首歌的位置固定偏慢一截,幅度
/// 因页面加载/JS 初始化耗时而异,不是常数,那次调研已经明确否掉了"自动学一个偏移"这条路
/// (MediaRemote 不给站点信息、偏差连正负号都不固定)。
///
/// 2026-08-29 用户反馈"YouTube Music 换歌之后进度偏慢,1 秒误差都不能接受"——现有的
/// 手动按播放器配置时间轴偏移那套治标不治本(每首歌真实偏差都不一样)。这个类换一个思路:
/// 不猜偏移,直接问网页 DOM 要这首歌真实播放到第几秒,用 AppleScript 执行 JavaScript 读
/// 页面自己渲染的播放进度文字(不是 `<video>.currentTime`——YouTube Music 的"电台/续播"
/// 模式下那个字段是整个会话的累计时间、跨歌不清零,2026-08-29 实测坐实,不能当真值用)。
///
/// ## 覆盖范围与已知局限
///
/// - 目前做了 YouTube Music(`music.youtube.com`)一个站点。要支持别的网站往 `siteRules`
///   加一条规则即可——选择器/解析方式因站而异,没有通用方案,新增前得先像 YouTube Music
///   这样实测过该站点自己的 DOM 结构。
/// - 2026-08-31 从"只支持 Arc"扩到 Chromium 系全家(Arc/Chrome/Edge,见
///   `BrowserAutomationPermission.Family.chromium`——三家实测坐实同源于 Chromium 本体,
///   AppleScript 词典里的 `execute` 命令完全一致)+ Safari(WebKit,命令名不同,见
///   `buildAppleScript` 的 family 分支)。Bundle id 一律不写死成 App 名字,统一用
///   `tell application id "<bundleID>"`(实测坐实对三家 Chromium 系和 Safari 都有效,
///   不受"App 被改名/装了变体版本"影响)。
/// - 硬依赖每个浏览器自己那道"允许来自 Apple 事件的 JavaScript"开关(默认关闭,Chromium
///   系和 Safari 是两套完全独立的实现,检测/开启逻辑见 `BrowserAutomationPermission`)。
///   开关关着时的失败方式**因浏览器而异,2026-08-31 逐个实测坐实,两者都已兜住**:Arc
///   是 `execute … javascript` **挂起不返回**(必须靠 `probeTimeout` 硬超时杀掉);Chrome
///   则是**立刻**抛一个清晰的 AppleScript 错误("通过 AppleScript 执行 JavaScript 的
///   功能已关闭…"),根本不会挂——同源于 Chromium 不代表这类运行时行为细节也一致,Arc
///   作为重度魔改的分支可能少做了 Chrome 那层错误提示。两种失败方式在 `buildAppleScript`
///   里都被裸 `try…end try`(吞掉抛出的错误,继续找下一个标签页)和 `ProcessRunner` 的
///   超时(杀掉挂起的子进程)一起兜住,最终对调用方表现一致:探测失败、静默退回原有的
///   MediaRemote 逻辑(这是刻意的:探针只做加分项,拿不到就什么都不做,不能让它自己
///   变成新的故障点)。Edge 没有专门实测这一点,只验证过 AppleScript 词典和 Preferences
///   key 存在,失败方式假定接近 Chrome(比 Arc 改动小得多),但不是实测坐实的结论。
///   **不支持的浏览器内核(Firefox 等,
///   `BrowserAutomationPermission.family` 返回 nil)同理静默跳过**——不特意报"不支持",
///   原样退回既有的 MediaRemote/`resolvePositionSeconds` 逻辑,行为上跟这个探针压根
///   不存在时一样。
/// - 只在**单曲目、非跳曲**场景下有意义:换歌时缓存立刻作废(见 `trackChanged()`),
///   新曲目要等下一轮探测成功才有地面真值,这之前退回既有逻辑,不强求"换歌瞬间"也精确。
///
/// ## 2026-08-31 从"信任了就自动探测"改成"平台↔浏览器配对即开关"
///
/// 早期版本只要浏览器受支持(engine 有对应 family)、又在「已信任的其它播放器」名单里,
/// 就会对它自动探测——用户没有主动"打开这个功能"的动作,是隐式生效的。用户明确要求改成
/// 显式配对:设置里新增"浏览器歌词同步"卡片,按 `supportedPlatforms` 逐个平台列出已经
/// 配对的浏览器(可以给同一个平台配多个浏览器,比如平时用 Chrome、偶尔用 Arc),支持添加/
/// 移除配对。**没配对过的浏览器——哪怕已经信任、哪怕真的开着这个网站——完全不会触发
/// 探测**,不会发起任何 AppleScript 调用,行为上等同于这个探针压根不知道这个浏览器存在。
///
/// 配对数据(`platformBrowserPairs`)由 UI 层(AppDelegate 启动同步 + SettingsView 改动时)
/// 直接写这个类的公开属性,跟 `LocalPlaybackSource.romanizationScripts` 同一个"UI 推值进
/// LyrimuseCore 单例"的模式,不经过任何跨层依赖。
///
/// ## 2026-08-30 用户反馈"改完反而更差,有时候歌词进度会回退"——一次性纠偏,不持续覆盖
///
/// 最初版本(见 git 历史)一旦探测命中,`positionSeconds` 直接等于探针值、且强制
/// `didReanchor=true`,彻底跳过 `resolvePositionSeconds` 整套伺服/棘轮/EMA 逻辑,后续每一轮
/// (~0.9s 一次探测往返)都重复这个动作。背靠背实测(2026-08-30)坐实两件事:①往返耗时
/// 稳定 ~0.9s、不随连续调用堆积(不是队列积压);②探针读数来自页面渲染的"M:SS"文字,
/// 只有**整秒精度**——而 Arc 走 media-control 的 `elapsedTimeNow` 本身早就是连续、无量化、
/// ±0.05s 精度的干净外推(`positionSourceTier` 把 Arc 归在 `.cleanExtrapolated`,画像见该
/// 枚举注释)。用一个精度更粗的整秒值,每 ~0.9 秒就无条件替换一次已经很准的连续外推基准,
/// 必然出现"外推值已经走到 15.85s、下一份整秒探针读数是 15(或页面还没来得及把显示文字
/// 跳到 16)、基准被硬拽回 15"这种周期性回退——这正是 `resolvePositionSeconds` 里
/// `noisyFloored` 档(QQ音乐/网易云同款整秒地板量化源)那套前向棘轮 + EMA 门槛专门用来
/// 防的现象,但旧版实现完全绕开了那套保护。
///
/// 修法:探针只在**换歌后用一次**,把它当这首歌的"精确种子值"喂给 `resolvePositionSeconds`
/// (tier 按 `.noisyFloored` 处理,因为它确实就是整秒地板量化读数),让既有的 seek-跳变判定/
/// 棘轮/EMA 接管——命中一次大跳变就重锚(解决"换歌后进度偏慢"的原始问题),之后不再重复
/// 探测这首歌,把稳态精度交还给本来就更准的 `.cleanExtrapolated` 外推。见 `consumeCorrection`
/// 和 `kickIfNeeded` 里的一次性消费逻辑。
public final class BrowserPositionProbe: @unchecked Sendable {
    public static let shared = BrowserPositionProbe()
    private init() {}

    private static let probeTimeout: TimeInterval = 3

    /// 一个"网页音乐平台"的公开身份——设置页的"浏览器歌词同步"卡片按这份列表逐个渲染
    /// 平台分组,用户在每个分组下配对要用的浏览器。只有 `id`/`displayName`,不带任何探测
    /// 实现细节(那些在 `SiteRule` 里,是私有的)。
    public struct BrowserMusicPlatform: Identifiable, Equatable, Hashable, Sendable {
        public let id: String
        public let displayName: String
    }

    /// 目前唯一支持的平台。要新增网站:先像 YouTube Music 这样实测过该站点自己的 DOM
    /// 结构、写好对应的 `SiteRule`,再在这里加一条 `BrowserMusicPlatform`——两处的 `id`
    /// 必须一致(`SiteRule.platformID` 是配对生效的匹配键)。
    public static let supportedPlatforms: [BrowserMusicPlatform] = [
        BrowserMusicPlatform(id: "youtubeMusic", displayName: "YouTube Music")
    ]

    /// 一条站点规则:属于哪个平台 + URL 特征子串 + 怎么从页面里抠出"这首歌当前播放到
    /// 第几秒"。JS 源码**必须只用单引号做字符串字面量**——它要整段嵌进 AppleScript 的
    /// 双引号字符串里,用单引号能完全绕开转义(见 buildAppleScript),出错概率最低。
    private struct SiteRule {
        let platformID: String
        let urlContains: String
        let script: String
    }

    private static let siteRules: [SiteRule] = [
        SiteRule(platformID: "youtubeMusic", urlContains: "music.youtube.com", script: youtubeMusicScript)
    ]

    /// YouTube Music 的播放进度取自页面自己渲染的".time-info"文字(形如"0:57 / 4:04"),
    /// 不取 <video>.currentTime——"电台/续播"模式下那个字段是整个会话的累计时间,
    /// 2026-08-29 实测坐实(同一时刻 currentTime=516s 而这首歌本身时长只有 243s)。
    /// 顺带把 <video>.paused 也带出来,调用方用它排除"标签页开着但暂停/静音后台"的干扰。
    ///
    /// ⚠️ 返回值刻意**不用** JSON.stringify——2026-08-30 实测坐实一个大坑:`execute …
    /// javascript` 把 JS 返回的字符串再包一层 AppleScript 字符串时,会把字符串里已有的
    /// 双引号**真的**转义成反斜杠(不是打印时的显示转义,是字符串本身多了真实的 `\` 字符,
    /// 用 `r contains "\\"` 实测坐实),等于整段 JSON 被二次转义。拿这种结果去跟手写的
    /// `"\"found\":true"` 比较,`contains` 会稳定判 false——不是这里的 AppleScript
    /// 判断逻辑写错了,是双方对"这段文字里到底有没有反斜杠"完全对不上。规避办法就是让
    /// JS 返回值**从头到尾不含任何双引号**:改用 `"<seconds>|<pausedFlag>"` 这种竖线
    /// 分隔的裸文本,没有引号就没有二次转义可言。
    private static let youtubeMusicScript = """
    (function(){
      var el = document.querySelector('.time-info');
      if (!el) return 'NOTFOUND';
      var text = (el.textContent || '').trim();
      var parts = text.split('/');
      if (parts.length !== 2) return 'NOTFOUND';
      var cur = parts[0].trim().split(':');
      if (cur.length !== 2) return 'NOTFOUND';
      var minutes = parseInt(cur[0], 10);
      var secs = parseInt(cur[1], 10);
      if (isNaN(minutes) || isNaN(secs)) return 'NOTFOUND';
      var video = document.querySelector('video');
      var paused = video ? video.paused : false;
      return (minutes * 60 + secs) + '|' + (paused ? '1' : '0');
    })()
    """

    // MARK: - 缓存 + 换歌作废

    private struct CachedResult {
        let key: String
        let seconds: Double
        let capturedAt: Date
    }

    private let lock = NSLock()
    private var cached: CachedResult?
    private var inFlightKey: String?
    private var consumedKey: String?
    private var generation = 0
    private var platformBrowserPairsStorage: [String: Set<String>] = [:]

    /// 平台 id → 用户已配对(主动选过、允许对它探测)的浏览器 bundle id 集合。UI 层直接
    /// 写这个属性来更新配对(见类头注"平台↔浏览器配对即开关"),读写都过 `lock`——写者是
    /// 主线程(设置页用户操作),读者是 `kickIfNeeded`/`probeOnce` 所在的后台线程,两边
    /// 必须用同一把锁,不能假设"设置很少变就不用管并发"。
    public var platformBrowserPairs: [String: Set<String>] {
        get { lock.lock(); defer { lock.unlock() }; return platformBrowserPairsStorage }
        set { lock.lock(); platformBrowserPairsStorage = newValue; lock.unlock() }
    }

    /// 这个 bundle id 配对过哪些平台——没配对过任何平台的浏览器,`kickIfNeeded` 直接
    /// 短路返回,不发起任何探测。
    private func pairedPlatformIDs(forBundleID bundleID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var ids: Set<String> = []
        for (platformID, bundleIDs) in platformBrowserPairsStorage where bundleIDs.contains(bundleID) {
            ids.insert(platformID)
        }
        return ids
    }

    /// 取这首歌**唯一一次**的地面真值种子,外推到 `now` 这一刻(探针本身有约一次探测
    /// 往返的固有滞后,靠 `rate * age` 补上)。命中(非 nil)后立即标记这个 key 为已消费——
    /// 同一首歌之后再调用一律返回 nil,换下一首歌(`trackChanged()`)才会重新开放。
    ///
    /// 一次性是刻意的(2026-08-30,见类头注"一次性纠偏,不持续覆盖"):这个值只有整秒
    /// 精度,只适合当"换歌后立刻给个准种子"用,不适合当稳态下持续覆盖的真值——
    /// `resolvePositionSeconds` 自己的连续外推(`.cleanExtrapolated`)比它更准。
    ///
    /// 返回 nil 的情况:这首歌已经消费过一次 / 还没探测成功过 / 缓存的曲目跟当前曲目
    /// 对不上(换歌了)/ 缓存已经超过 `maxAge` 太旧——都应该原样退回既有的
    /// `resolvePositionSeconds` 逻辑(喂 `snapshot.elapsedTime`)。
    public func consumeCorrection(forKey key: String, rate: Double, now: Date, maxAge: TimeInterval = 6) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard consumedKey != key else { return nil }
        guard let snapshot = cached, snapshot.key == key else { return nil }
        let age = now.timeIntervalSince(snapshot.capturedAt)
        guard age >= 0, age <= maxAge else { return nil }
        consumedKey = key
        return snapshot.seconds + rate * age
    }

    /// 换歌时清掉缓存——上一首歌的探测结果绝不能被当成这一首歌的位置用,也重新开放
    /// 这首新歌的一次性消费额度。也会让"正在飞的探测"的结果作废(generation 递增),
    /// 防止一份晚到的旧曲目探测结果污染新曲目。
    public func trackChanged() {
        lock.lock()
        cached = nil
        inFlightKey = nil
        consumedKey = nil
        generation += 1
        lock.unlock()
    }

    /// 如果这个 bundle id 受支持、这首歌还没消费过一次探测结果、且当前没有正在飞的同
    /// 曲目探测,踢一次新的——异步、**不阻塞调用方**,结果就绪时写回 `cached` 供
    /// `consumeCorrection` 用。这首歌一旦被消费过一次就不再重新探测(见类头注),避免
    /// 稳态播放期间持续拿整秒精度的读数去覆盖本来更准的连续外推,也省下持续的 AppleEvent
    /// 往返开销。不等这次探测的结果,是刻意的:调用方(轮询循环)本身就是同步、高频跑的,
    /// 不能被一次上百毫秒的 AppleScript 往返卡住。
    public func kickIfNeeded(bundleIdentifier: String?, key: String) {
        guard let bundleIdentifier, let family = BrowserAutomationPermission.family(forBundleID: bundleIdentifier)
        else { return }
        // 没配对过任何平台——完全不发起探测(见类头注"配对即开关")。放在锁外面查是故意的:
        // `pairedPlatformIDs` 自己会拿锁,这里不需要跟下面 inFlightKey 的检查合并成一次
        // 加锁,提前 return 的路径越简单越好读。
        let platformIDs = pairedPlatformIDs(forBundleID: bundleIdentifier)
        guard !platformIDs.isEmpty else { return }
        lock.lock()
        guard inFlightKey != key, consumedKey != key else { lock.unlock(); return }
        inFlightKey = key
        let myGeneration = generation
        lock.unlock()

        Task.detached(priority: .utility) {
            let seconds = Self.probeOnce(bundleID: bundleIdentifier, family: family, platformIDs: platformIDs)
            self.applyProbeResult(seconds, key: key, generation: myGeneration)
        }
    }

    /// `lock`/`unlock` 直接写在 `Task.detached` 闭包体里,在 Swift 6 语言模式下是编译
    /// 错误(NSLock 的那两个方法不认为自己能安全地跨越 async 挂起点被调用)——拆成这个
    /// 普通同步函数,闭包里只是"调用"它,不在 async 上下文里直接摆弄锁,绕开这条限制。
    private func applyProbeResult(_ seconds: Double?, key: String, generation myGeneration: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard myGeneration == generation else { return } // 换歌了,这份结果作废
        if inFlightKey == key { inFlightKey = nil }
        guard let seconds else { return }
        cached = CachedResult(key: key, seconds: seconds, capturedAt: Date())
    }

    // MARK: - 探测实现(全程跑在后台线程,调用方必须走 Task.detached)

    /// 只试用户为这个浏览器配对过的平台对应的站点规则——哪怕另一个平台的站点规则也能
    /// 匹配上当前打开的标签页,没配对过就不试,尊重用户的显式选择(见类头注)。
    private static func probeOnce(bundleID: String, family: BrowserAutomationPermission.Family, platformIDs: Set<String>) -> Double? {
        for rule in siteRules where platformIDs.contains(rule.platformID) {
            if let seconds = probe(bundleID: bundleID, family: family, rule: rule) {
                return seconds
            }
        }
        return nil
    }

    private static func probe(bundleID: String, family: BrowserAutomationPermission.Family, rule: SiteRule) -> Double? {
        let appleScript = buildAppleScript(bundleID: bundleID, family: family, urlContains: rule.urlContains, script: rule.script)
        guard let tempURL = writeTempScript(appleScript) else { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let result = ProcessRunner.run("/usr/bin/osascript", [tempURL.path], timeout: probeTimeout),
              result.succeeded
        else { return nil }
        return parseSeconds(fromOsascriptOutput: result.stdoutText)
    }

    /// 一次 AppleScript 里做完"找标签页 + 执行脚本"两件事(不能分两次调用:标签页引用
    /// 存成变量再传进另一次 `tell` 会报 specifier 转换错误,2026-08-29 实测坐实——
    /// `execute`/`do JavaScript` 要的是**内联**说明符,只有 `tab i of window w` 这种当场
    /// 求值的写法能用)。按标签页顺序试,遇到第一个"确实在播放"(`found:true` 且非暂停)的
    /// 就直接返回,避免用户同时开着好几个同源标签页(比如两个 YouTube Music 页面)时读错。
    ///
    /// `tell application id "<bundleID>"`(而不是写死 App 显示名字符串)——2026-08-31 对
    /// Arc/Chrome/Edge/Safari 逐个实测坐实这个语法对四家都有效,不受"App 被改名/装了
    /// 变体版本(比如 Chrome Canary)"影响,比 `tell application "Google Chrome"` 更稳。
    ///
    /// Chromium 系和 Safari 的 JS 注入命令**不同名**(2026-08-31 实测坐实,不是同一个词
    /// 的两种写法):Chromium 系是 `execute (tab) javascript "…"`,Safari 是
    /// `do JavaScript "…" in tab`。两边窗口/标签枚举语法(`count of windows`/
    /// `tabs of window`/`URL of tab`)是一致的,只有这一行命令要按 family 分支。
    private static func buildAppleScript(
        bundleID: String, family: BrowserAutomationPermission.Family, urlContains: String, script: String
    ) -> String {
        let executeLine: String
        switch family {
        case .chromium:
            executeLine = "execute (tab ti of window wi) javascript \"\(script)\""
        case .safari:
            executeLine = "do JavaScript \"\(script)\" in tab ti of window wi"
        }
        return """
        tell application id "\(bundleID)"
            set winCount to count of windows
            repeat with wi from 1 to winCount
                set tabCount to count of tabs of window wi
                repeat with ti from 1 to tabCount
                    if (URL of tab ti of window wi) contains "\(urlContains)" then
                        try
                            set r to \(executeLine)
                            if r does not contain "NOTFOUND" and r does not contain "|1" then
                                return r
                            end if
                        end try
                    end if
                end repeat
            end repeat
            return "NOTFOUND"
        end tell
        """
    }

    private static func writeTempScript(_ source: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-browser-probe-\(UUID().uuidString).applescript")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// osascript 打印一个 AppleScript 字符串结果时会整体加一层引号——脚本约定返回值
    /// 是不含引号的裸文本(见 youtubeMusicScript 头注),所以这里只需要脱掉那层外层引号,
    /// 不需要处理任何内部转义。格式固定是 "<seconds>|<pausedFlag>",pausedFlag 非
    /// "0"(比如脚本失败时的 "NOTFOUND")一律当作解析失败,不猜。
    ///
    /// public 是为了给 lyrimuse-selftest 单测这段纯解析逻辑——真正调 AppleScript 的部分
    /// 依赖真实 Arc + 已打开的网页,没法在 CI/无 GUI 环境里稳定跑,只能靠这段解析逻辑的
    /// 单测兜底覆盖率,真实端到端行为已经在 2026-08-30 手动验证过。
    public static func parseSeconds(fromOsascriptOutput raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text.removeFirst()
            text.removeLast()
        }
        let parts = text.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, parts[1] == "0", let seconds = Double(parts[0]) else { return nil }
        return seconds
    }
}
