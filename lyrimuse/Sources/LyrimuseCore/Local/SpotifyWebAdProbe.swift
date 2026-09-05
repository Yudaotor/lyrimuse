import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "spotifyad")

// 「浏览器里的 Spotify 网页版此刻在放广告还是歌」——问页面本身(2026-09-03)。
//
// ---- 为什么需要它:原生 Spotify 好好的,网页版的广告却让整个 UI 消失 30 秒 ----
//
// Spotify 网页版广告的字段形状(2026-09-03 现场抓的真实样本,同一批广告 6 次采样一致):
//
//     title="广告"   artist=""   album=""   duration≈30s
//
// **artist 是空的**,而 `MediaControlClient.trustedPlaybackRejected` 里那道
// `guard !artist.isEmpty else { return true }` 短路会在任何页面复核之前把它整条丢掉。
// 后果是广告那 30 秒 App 手上一条播放数据都没有:菜单栏塌回小图标、灵动岛/悬浮窗一起消失,
// 广告完了再弹回来(2026-09-03 03:23 的日志里 `slot rebuild: icon(38.5) -> fixed(...)` 就是
// 这一幕)。原生 Spotify 客户端不受那道闸约束(内置播放器直接豁免),所以它一直是好的 ——
// **只有浏览器里的 Spotify 掉在这个洞里**。
//
// 这跟 YouTube Music 那次(见 02 章第 16 条)是同一类问题、同一个解法方向,但**判据完全不同**:
//   * YT Music 广告的 artist 是**广告主频道名、非空**,跟"真歌但没报专辑名"在字段上分不开,
//     所以那边要问页面才知道是不是广告;
//   * Spotify 网页版广告的 artist **是空的**,字段形状本身已经很像广告了 —— 这里问页面是为了
//     **确认**(positive evidence),免得把"浏览器里随便一个没有歌手名的网页音频"也当成广告
//     放进来贴上「广告中」。
//
// ---- 判据:四个 data-testid,任一命中即广告 ----
//
// 2026-09-03 现场抓的对照样本(Safari + open.spotify.com,同一张专辑连播):
//
//     4 次歌曲态(三年二班 / 東風破 / 妳聽得到 / 同一種調調)  → 0|0|0|0
//     6 次广告态(跨 3 条连续广告,Uber「第 1 个,共 3 个」)  → 1|1|1|1
//
// 用 `data-testid` 而不是文字,因为**跟语言无关** —— 页面上那些「广告 • 第 1 个,共 3 个」
// 是跟着界面语言走的,英文界面下就成了 "Advertisement"。
//
// ⚠️ **不能用 `[data-testid*=ad]` 这种子串匹配**:歌曲态里就有 `add-button`(里面含 "ad"),
// 会稳定误判成广告。必须逐个精确匹配。同理别把页脚那个 `Tailored Advertising Opt-out`
// (aria-label)算进来 —— 它在歌曲态也一直在。
//
// ⚠️ **判据只用"广告在场"这种正向标记**,不用"标题里没有 ` • `"或"曲目链接缺失"这类**缺失**
// 型信号:页面加载/切歌的一瞬间它们同样成立,会在真歌上闪出「广告中」。这跟 YT Music 那边
// 刻意保留一条"裸标题"兜底不同 —— 那边的调用语境是"拿不准就丢掉"(fail-closed,误判只损失
// 这一轮),这里的调用语境是"拿不准就维持现状(丢掉)",而误判的代价是**在真歌上贴广告标签**。
//
// ---- 生命周期:异步 kick + 读缓存,绝不阻塞 ----
//
// 跟 `YouTubeMusicAdProbe` 完全一样:`kickIfNeeded` 后台起一次 osascript,结果按**曲目身份**
// 进缓存;`cachedVerdict` 只读缓存。代价是新曲目的第一轮拿不到判定 —— 那一轮按 fail-closed
// 丢掉(也就是维持改动前的行为),下一轮就好。
//
// ---- 为什么 collector(Go)侧没有对应实现 ----
//
// 跟 YT Music 那次一样、方向相同:Go 那一侧的职责是"别把广告打卡上去",而它**现在就已经拒**
// (`trustedPlaybackNotASong` 见 artist 为空直接拒,连复核都不用)。给它加一份探针只会多一次
// AppleScript 往返、得到同一个"拒"。**Swift 放行并标记、Go 照旧拒**,这条不对称是有意的。
public final class SpotifyWebAdProbe: @unchecked Sendable {
    public static let shared = SpotifyWebAdProbe()

    public enum Verdict: Equatable, Sendable {
        case ad
        case song
    }

    /// 拿到判定之后该怎么办。只有两个出口 —— 这里不像 YT Music 那样有 `acceptAsSong`:
    /// 走到这条路上的播放**本来就要被丢掉**(歌手名为空),判定说"是歌"并不能让它变成一首
    /// 可以采纳的歌(一首真歌不会没有歌手名;那多半是别的网页音频)。所以这里只回答一件事:
    /// **要不要作为广告放行**。
    public enum Gate: Equatable, Sendable {
        /// 放行,并由 `LocalPlaybackSource.isCurrentTrackAdBreak` 标成广告驱动 UI。
        case acceptAsAd
        /// 照旧丢掉(维持改动前的行为)。
        case reject
    }

    /// ⚠️ 判定**缺失**(还没探到 / 超时 / 页面上找不到播放器)一律 reject —— 刻意的
    /// fail-closed:最坏情况是"Spotify 网页广告仍然让 UI 塌一下",也就是改动前的样子,
    /// 而不是"在一首真歌上贴了广告标签"。
    public static func gate(verdict: Verdict?) -> Gate {
        verdict == .ad ? .acceptAsAd : .reject
    }

    /// 值不值得为这条播放去问一次页面。**只有 artist 为空这一档**才问 —— 那正是下面那道
    /// 短路要丢掉、而 Spotify 网页广告恰好落在的形状。
    ///
    /// ⚠️ 这个门槛不是"省一点性能"的优化,是**避免跟 YT Music 那条探针互相踩**:artist 非空、
    /// album 为空那一档是 YT Music 探针的领地(`trustedPlaybackRejected` 里那一段),两条探针
    /// 都对同一个浏览器发 AppleEvent 会让配对了两个平台的浏览器(这台机器上 Safari / Arc)
    /// 每一轮多背一次 osascript 往返。
    ///
    /// ⚠️ 如果哪天 Spotify 改成"广告也报歌手名",这一档就不会命中、广告会退回被丢掉的老样子
    /// (不会误判,只是没修好)。下面 selftest 钉着当前这个形状,真变了会有断言先红。
    public static func fieldShapeNeedsProbe(title: String?, artist: String?) -> Bool {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let a = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && a.isEmpty
    }

    /// ⚠️ JS 源码里**不许出现双引号**(理由见 `BrowserTabProbeScript` 头注),也别用反斜杠 ——
    /// 它整段要嵌进 AppleScript 的双引号字符串,而反斜杠是 AppleScript 那边的转义字符。
    ///
    /// 返回 `a|b|c|d`(各为 0/1),顺序即下面 `parse` 的顺序。判定不在 JS 里做 —— 放在
    /// `parse(_:)` 里才跑得了单测。
    ///
    /// CSS 属性选择器里的值**不加引号**是可以的:这四个 testid 都是合法的 CSS 标识符
    /// (字母/数字/连字符,不以数字开头)。加引号只能加单引号,而单引号已经被 JS 字符串占了。
    public static let probeJS = """
    (function(){\
    var w = document.querySelector('[data-testid=now-playing-widget]');\
    if (!w) return 'NOTFOUND';\
    function h(id){ return document.querySelector('[data-testid=' + id + ']') ? '1' : '0'; }\
    return h('ad-controls') + '|' + h('context-item-info-ad-subtitle') + '|'\
    + h('ad-countdown-timer') + '|' + h('ad-link');\
    })()
    """

    public static let hostMarker = "open.spotify.com"
    /// AppleScript `with timeout of N seconds` 的 N。跟 YT Music 那条同值 —— 同一台机器、
    /// 同一批浏览器,没有理由给两个不同的耐心。
    public static let eventTimeoutSeconds = 4
    /// 整个 osascript 子进程的硬超时,兜最后一层。
    static let processTimeout: TimeInterval = 6
    /// 判定的有效期。广告在 media-control 里是**独立的 now-playing 条目**(自己的
    /// title/artist),换成广告身份缓存 key 自然失效,所以这个值只兜"同一条广告播很久"。
    static let verdictMaxAge: TimeInterval = 60

    private let lock = NSLock()
    private var cachedKey: String?
    private var cachedVerdictValue: Verdict?
    private var cachedAt: Date?
    private var inFlightKey: String?

    private init() {}

    /// 把探针的裸文本输出解成判定。纯函数,可单测。
    ///
    /// 形状不认识(空 / NOTFOUND / 字段数不对 / 非 0/1)一律返回 nil —— **不猜**,让调用方
    /// 走 fail-closed。
    public static func parse(_ raw: String) -> Verdict? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // AppleScript 有时把返回值再包一层双引号,脱掉。
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.contains("NOTFOUND") { return nil }
        let parts = s.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var isAd = false
        for part in parts {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "1": isAd = true
            case "0": break
            default: return nil // 形状不对,不做任何推断
            }
        }
        return isAd ? .ad : .song
    }

    /// 只读缓存,**绝不阻塞**。nil = 还没探到 / 已过期 / 换了曲目。
    public func cachedVerdict(forKey key: String, now: Date = Date()) -> Verdict? {
        lock.lock()
        defer { lock.unlock() }
        guard cachedKey == key, let verdict = cachedVerdictValue, let at = cachedAt else { return nil }
        let age = now.timeIntervalSince(at)
        guard age >= 0, age <= Self.verdictMaxAge else { return nil }
        return verdict
    }

    /// 异步踢一次探测,不等结果。同一个 key 同时只有一次在飞。
    ///
    /// 准入判据跟 `YouTubeMusicAdProbe.kickIfNeeded` / `BrowserPositionProbe.kickIfNeeded`
    /// 一致,含那步**媒体代理别名解析**(Safari 播网页音频时 MediaRemote 报的是
    /// `com.apple.WebKit.GPU`,要换回宿主 `com.apple.Safari` 才 tell 得动)—— 而 Spotify
    /// 网页版最常见的宿主恰恰就是 Safari,漏了这一步这个探针会**一次都不发起**、且不报错。
    public func kickIfNeeded(bundleIdentifier: String?, key: String) {
        guard let hostBundleID = BrowserPositionProbe.probeTargetBundleID(forReported: bundleIdentifier),
              let family = BrowserAutomationPermission.family(forBundleID: hostBundleID)
        else { return }
        lock.lock()
        if inFlightKey == key {
            lock.unlock()
            return
        }
        if cachedKey == key, let at = cachedAt, Date().timeIntervalSince(at) <= Self.verdictMaxAge,
           cachedVerdictValue != nil {
            lock.unlock()
            return
        }
        inFlightKey = key
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let verdict = Self.probeOnce(bundleID: hostBundleID, family: family)
            self.lock.lock()
            if self.inFlightKey == key { self.inFlightKey = nil }
            // nil 不进缓存:那多半是"这一下没读到"(超时/标签页刚好在切),下一轮该重试,
            // 缓存住它等于把一次偶发失败按整条广告的时长放大。
            if let verdict {
                self.cachedKey = key
                self.cachedVerdictValue = verdict
                self.cachedAt = Date()
                if verdict == .ad {
                    // notice 级:这是"我们主动把一条广告放行并标成了广告",排查
                    // "为什么这 30 秒显示的是广告中"时这一行是唯一的现场。
                    logger.notice("spotify web: classified as advertisement, passing through and flagging")
                }
            }
            self.lock.unlock()
        }
    }

    private static func probeOnce(bundleID: String, family: BrowserAutomationPermission.Family) -> Verdict? {
        guard let out = BrowserTabProbeScript.run(
            bundleID: bundleID, family: family, hostMarker: hostMarker, js: probeJS,
            eventTimeoutSeconds: eventTimeoutSeconds, processTimeout: processTimeout,
            label: "spotify-ad")
        else { return nil }
        return parse(out)
    }

    /// 拼出那段 AppleScript。公开只为把契约钉进 selftest,运行入口是
    /// `kickIfNeeded` / `cachedVerdict` 两个。
    public static func buildAppleScript(bundleID: String, family: BrowserAutomationPermission.Family) -> String {
        BrowserTabProbeScript.build(bundleID: bundleID, family: family, hostMarker: hostMarker,
                                    js: probeJS, eventTimeoutSeconds: eventTimeoutSeconds)
    }

    /// 曲目身份。跟 `YouTubeMusicAdProbe.trackKey` 同一个构造方式(`artist \0 title`)——
    /// 广告是独立的 now-playing 条目,换成广告身份 key 自然失效。
    public static func trackKey(artist: String?, title: String?) -> String {
        let a = (artist ?? "").trimmingCharacters(in: .whitespaces)
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        return a + "\u{0}" + t
    }
}
