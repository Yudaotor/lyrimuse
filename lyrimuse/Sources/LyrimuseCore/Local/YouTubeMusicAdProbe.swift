import Foundation

/// 「浏览器里这条 YouTube Music 播放是广告还是一首歌」的探针(2026-09-02)。
///
/// ## 为什么需要它
///
/// 在此之前,浏览器里播 YouTube Music **压根不会被识别**(用户原话「为什么我现在用 chrome
/// 播放的 YouTube music 不能识别到」)。根因不是 bug,是 `TrustedPlayers.notASong` 那道
/// 防视频守卫:信任的非内置播放器,artist 或 album 有一个为空就整条丢掉。而 YouTube Music
/// 经 MediaSession 报出来的 album **常常是空的**,于是被当成"浏览器里的视频"挡在门外。
///
/// ⚠️ 是"常常"不是"总是"(2026-09-02 实测订正,初版注释把它写成了"恒为空"):同一个
/// Chrome 里播 YT Music,「死神」「September」的 album 是空的,而「Bad」报的是
/// `The Essential Michael Jackson`。所以这不是"YT Music 一律进不来",而是"看运气"——
/// 报了专辑名的那些歌本来就能进,这条复核是给报不出来的那些兜底。
///
/// 那道守卫本身是对的(2026-08-21 定,album 是四份真实样本里唯一 100% 分得开歌与视频的
/// 字段),它的注释当时就写明了代价:「电台/单曲场景下真音乐 App 若不报专辑名会被误挡……
/// 宁可漏认,不要把视频写进永久收听历史」。YouTube Music 正好踩在这个代价上。
///
/// ## 为什么不能简单地"给 music.youtube.com 免检 album"
///
/// 因为 album 那一条**同时也在挡广告**。2026-09-02 抓了两条真实广告(media-control 与
/// 页面 JS 同一时刻成对采样):
///
///     title=「Liese Jelly to Bubble 全新登場!染髮新革命」 artist=KAO Hong Kong          album="" dur=30.021
///     title=「趁早把握出生頭3年腦部發育黃金期…」          artist=香港美贊臣 Mead Johnson album="" dur=20.001
///
/// **artist 是非空的**(广告主的频道名)。免检 album 之后这两条会畅通无阻地被当成
/// "KAO Hong Kong 的一首歌"。
///
/// ## 判据:问页面本身,不猜字段
///
/// 同一批成对采样里,**22 个连续样本、横跨两条不同广告**:
///
///                               广告期间            真歌期间
///     播放器 class 含 ad-showing  22/22 命中           0
///     广告徽章元素存在             22/22 命中           0
///     document.title            「YouTube Music」   「歌名 | YouTube Music」
///
/// 三个信号都读、**任一命中就算广告**(不取多数):误判成广告只是这一轮没识别(下一轮
/// 自我纠正),误判成歌是把广告永久写进 Last.fm。
///
/// ⚠️ **这套判据跟 collector 侧 `ytmusicad.go` 是同一份,两边必须同时改** —— 跟
/// `TrustedPlayers.notASong` / `trustedPlaybackNotASong` 那一对是同样的关系(Go 和 Swift
/// 各跑一份、共享同一条语义)。selftest 里有断言钉住 JS 里那几个标志串。
///
/// ## 为什么是「异步 kick + 读缓存」,不是同步问一次
///
/// 调用方(`MediaControlClient`)整个类型是**同步**的、按轮询高频跑,不能被一次
/// AppleScript 往返卡住(真机实测 ~187ms)。所以照 `BrowserPositionProbe` 那套成熟范式:
/// `kickIfNeeded` 异步踢一次、结果写回缓存,`cachedVerdict` 只读缓存、绝不阻塞。
///
/// 代价是**新曲目的第一轮拿不到判定** —— 此时按 fail-closed 拒掉,下一轮就好。跟
/// `BrowserPositionProbe` 类头注里"换歌时缓存立刻作废,新曲目要等下一轮探测成功"是同一个
/// 取舍,也是同一个量级的延迟。
public final class YouTubeMusicAdProbe: @unchecked Sendable {
    public static let shared = YouTubeMusicAdProbe()

    public enum Verdict: Equatable, Sendable {
        case ad
        case song
    }

    /// 「这条来自信任浏览器、基础守卫要拒的播放,到底怎么处置」——三条出口收成一个纯函数。
    ///
    /// 收成函数是为了能被 selftest 钉住:真正的调用点 `MediaControlClient
    /// .trustedPlaybackRejected` 是 `private static`,selftest(独立 target)看不见,而这
    /// 三条出口里有一条是 2026-09-02 才**特意改掉**的(见 `.acceptAsAd`),没有覆盖的话
    /// 谁都不知道它哪天被改回去。
    public enum Gate: Equatable, Sendable {
        /// 放行,当一首歌处理。
        case acceptAsSong
        /// 放行,但**标成广告**。
        ///
        /// ⚠️ 2026-09-02 改:这一档原来是 `reject`(跟广告一起丢掉),用户报「chrome 上播
        /// YouTube Music 的广告也想像 Spotify 那样显示出来是广告」。丢掉之后 UI 拿不到
        /// 任何东西 —— 一段 30 秒广告期间灵动岛/悬浮窗会整个塌成"没有在播放",广告完了
        /// 再弹回来,而不是像 Spotify 那样安静地显示「广告中」。
        ///
        /// **放行不等于会被记录**:Swift 侧一行 scrobble 都不发(`track.scrobble` /
        /// `submit-listens` 全在 collector 的 lastfm.go / lb.go),提交 listen 是 collector
        /// 独立那条路的事,那边由 `ytmusicad.go` + `system.go` 自己拦着,不受这里影响。
        /// 这也正是 Spotify 广告一直以来的形态:快照照常流进来、由
        /// `LocalPlaybackSource.isCurrentTrackAdBreak` 标成广告驱动 UI,打卡在别处拦。
        /// ⚠️ 于是 Swift 与 Go 在**这一层**上是**故意不对称**的(Go 拒、Swift 放行标记),
        /// 跟基础判据 `notASong` / `trustedPlaybackNotASong` 那对"必须逐字一致"不同 ——
        /// 改这里之前先读懂这个区别。
        case acceptAsAd
        /// 丢掉。
        case reject
    }

    /// UI 侧的口径:**只有 `.ad` 才点亮「广告中」**。
    ///
    /// ⚠️ 这条跟 `gate` 的 fail-closed 方向**正好相反**,不能顺手共用同一个判断:
    ///   - `gate` 服务的是"要不要采纳这条播放",拿不准(判定缺失)时**当广告处理**丢掉 ——
    ///     漏认一首歌只是这一轮没识别,认错一条广告是永久写进收听历史。
    ///   - 这一条服务的是"要不要在界面上说这是广告",拿不准时**必须当成不是广告** ——
    ///     探针会真的超时(osascript 卡住、浏览器没给自动化权限,实测发生过),那时判定是
    ///     缺失的;若跟着 `gate` 的口径走,就会在一首**真歌**上打「广告中」。
    ///
    /// 一句话:丢弃可以宁枉勿纵,贴标签必须宁纵勿枉。
    public static func showsAdBadge(verdict: Verdict?) -> Bool {
        verdict == .ad
    }

    /// 基础守卫已经判"不是一首歌"之后,再决定怎么处置。纯函数,可单测。
    ///
    ///   - artist 为空 → 一律 reject,**不看判定**。真曲目必有歌手,顺带省掉一次 AppleEvent。
    ///   - 判定缺失(还没探到)→ reject。刻意的 fail-closed:宁可这一轮没识别,下一轮就好。
    ///   - 其余按判定走。
    public static func gate(artist: String?, verdict: Verdict?) -> Gate {
        let trimmed = (artist ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .reject }
        switch verdict {
        case .song: return .acceptAsSong
        case .ad: return .acceptAsAd
        case nil: return .reject
        }
    }

    /// ⚠️ 跟 `ytmusicad.go` 的 `ytmusicAdProbeJS` 是**同一份判据**,改一边必须改另一边。
    ///
    /// ⚠️ JS 源码里**不许出现双引号**:它整段要嵌进 AppleScript 的双引号字符串,而
    /// `execute … javascript` 会把返回值里已有的双引号**真的**转义成反斜杠(不是显示
    /// 转义,是字符串本身多了真实的 `\`),整段被二次转义之后拿去比 `contains` 会稳定判
    /// false。`BrowserPositionProbe.youtubeMusicScript` 为此专门放弃了 JSON.stringify,
    /// 改用竖线分隔的裸文本;这里照抄同一条纪律。
    ///
    /// 返回 `a|b|c|album`:前三个各为 0/1(ad-showing / 广告徽章 / 裸标题),第四段是
    /// **页面上读到的专辑名**(2026-09-03 加,可能为空)。判定不在 JS 里做 —— 放在
    /// `parse(_:)` 里才跑得了单测。
    ///
    /// ⚠️ **专辑名必须放最后一段**:它是任意文本,理论上可以含 `|`。`parse` 因此按
    /// "最多切 4 段"来切,第四段原样保留(含里面的 `|`)。
    ///
    /// ⚠️ 找专辑用**遍历 + indexOf**,不用 CSS 属性选择器 `a[href*=...]`:选择器里那个值
    /// 含 `/`,不加引号不是合法 CSS 标识符,而加引号只能加单引号 —— 单引号又已经被外面
    /// 那层 JS 字符串占了(JS 里只许用单引号,见上面那条⚠️)。遍历没有这个死结。
    /// 认专辑靠 `browse/MPREb` 这个前缀:YouTube Music 的**专辑** browse id 一律以
    /// `MPREb_` 开头,歌手链接是 `channel/UC…`,所以这一条既跟语言无关(不受 byline 里
    /// 「2026年」这类本地化后缀影响),也不会把歌手/播放量误当成专辑。
    ///
    /// ⚠️ 下面这一组(`probeJS` / `hostMarker` / `eventTimeoutSeconds` / `parse` /
    /// `buildAppleScript`)是 `public` **只为把这套判据的契约钉进 selftest**(selftest 是
    /// 独立 target,看不见 internal)。同 `BrowserPositionProbe.platformIDsWithSiteRules`
    /// 那条先例。真正的运行入口只有 `kickIfNeeded` / `cachedVerdict` 两个。
    public static let probeJS = """
    (function(){\
    var p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');\
    var hasTime = !!document.querySelector('.time-info');\
    if (!p && !hasTime) return 'NOTFOUND';\
    var cls = p ? (p.className || '') : '';\
    var adShowing = cls.indexOf('ad-showing') >= 0 ? '1' : '0';\
    var badge = document.querySelector('.ytp-ad-badge, .ytp-ad-simple-ad-badge, .ytp-ad-text, .ytp-ad-preview-container') ? '1' : '0';\
    var t = (document.title || '').trim();\
    var bare = (t === 'YouTube Music') ? '1' : '0';\
    var bl = document.querySelectorAll('ytmusic-player-bar .byline a');\
    var album = '';\
    for (var i = 0; i < bl.length; i++) {\
    var h = bl[i].getAttribute('href') || '';\
    if (h.indexOf('browse/MPREb') >= 0) { album = (bl[i].textContent || '').trim(); break; }\
    }\
    return adShowing + '|' + badge + '|' + bare + '|' + album;\
    })()
    """

    public static let hostMarker = "music.youtube.com"
    /// AppleScript `with timeout of N seconds` 的 N —— 把 Arc 那种"挂起不返回"变成一个
    /// 抓得住的错误(裸 `try` 抓不住挂起,只有它能)。
    public static let eventTimeoutSeconds = 4
    /// 整个 osascript 子进程的硬超时,兜最后一层。
    static let processTimeout: TimeInterval = 6
    /// 判定的有效期。广告在 media-control 里是**独立的 now-playing 条目**(自己的
    /// title/artist),换成广告身份就变了、缓存 key 自然失效,所以这个值只是兜"同一首歌
    /// 播很久"的情况,不需要很短。
    static let verdictMaxAge: TimeInterval = 60

    private let lock = NSLock()
    private var cachedKey: String?
    private var cachedReadingValue: Reading?
    private var cachedAt: Date?
    private var inFlightKey: String?

    private init() {}

    /// 一次探测读到的全部东西:判定 + 页面上的专辑名。
    public struct Reading: Equatable, Sendable {
        public let verdict: Verdict
        /// 页面 byline 里那个专辑链接的文字。读不到(广告期间、视频、页面结构变了)是空串。
        public let album: String

        public init(verdict: Verdict, album: String) {
            self.verdict = verdict
            self.album = album
        }
    }

    /// 把探针的裸文本输出解成一次读数。纯函数,可单测。
    ///
    /// 形状不认识(空 / NOTFOUND / 段数不够 / 前三段非 0/1)一律返回 nil —— **不猜**,
    /// 让调用方走 fail-closed。
    ///
    /// ⚠️ 只切 4 段(`maxSplits: 3`):第四段是专辑名,是任意文本、可能自带 `|`,
    /// 原样保留。段数**多于** 4 在这套切法下不存在,所以旧版那条"4 段就判形状不对"的
    /// 断言 2026-09-03 随之作废(selftest 里那一行同日改掉)。
    public static func parse(_ raw: String) -> Reading? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // AppleScript 有时把返回值再包一层双引号,脱掉。
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.contains("NOTFOUND") { return nil }
        let parts = s.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        var isAd = false
        for part in parts.prefix(3) {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "1": isAd = true
            case "0": break
            default: return nil // 形状不对,不做任何推断
            }
        }
        // 专辑名里的换行压平:osascript 的输出是按行读的,真混进换行会让下游的日志/
        // 比较莫名其妙。压平在这儿做,不在 JS 里做 —— JS 那边写 `\s` 要用反斜杠,
        // 而整段 JS 嵌在 AppleScript 的双引号字符串里,反斜杠是那边的转义字符。
        let album = parts.count == 4
            ? parts[3].replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return Reading(verdict: isAd ? .ad : .song, album: album)
    }

    /// 该不该拿探针读到的专辑名去补上游那份 —— 以及补成什么。nil = 不动上游那份。
    ///
    /// 2026-09-03 加。起因是用户报「YouTube Music 播一张专辑的时候,第一首歌怎么不上送
    /// 专辑名」。当场抓的实测(两张不同专辑、四个采样)坐实了这件事,而且**是 YouTube Music
    /// 自己的疏漏,不是这条链路丢的**:
    ///
    /// | 队列位置 | 曲名 | 页面 byline 上的专辑 | `mediaSession.album` |
    /// |---|---|---|---|
    /// | #0 | Reasons, i love you | Reasons, i love you | **空** |
    /// | #1 | Not enough seasons | Reasons, i love you | 有 |
    /// | #2 | Be kind to myself | Reasons, i love you | 有 |
    /// | #0(另一张) | Heavy on Me | **Already Gone** | **空** |
    ///
    /// 机制:YT Music 开一条新队列时,在专辑上下文解析出来**之前**就把 MediaSession 元数据
    /// 设好了,之后不再刷新这一首 —— 所以页面上后来有了专辑名,MediaSession 里那份却永远
    /// 停在空。第二首起队列数据已经在手,就带上了。
    /// ⚠️ 最后那一行是**关键反例**:它证明规律是"队列第一首",不是我们一度猜的"专辑名跟
    /// 曲名相同就去重"(那张专辑名和曲名并不一样,照样是空)。别再往回猜那个。
    ///
    /// 三条同时成立才替换:
    ///   - 上游报的是空(**非空一律不动** —— 上游那份是权威,探针只补缺,不做纠正);
    ///   - 探针读到了非空;
    ///   - 这一条被判定成**歌**。广告没有专辑,而广告期间页面上那条 byline 读到的多半是
    ///     上一首歌的残留 —— 补上去等于给广告安一个别人的专辑名。
    public static func albumPatch(reported: String?, reading: Reading?) -> String? {
        guard (reported ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let reading, reading.verdict == .song else { return nil }
        let album = reading.album.trimmingCharacters(in: .whitespaces)
        return album.isEmpty ? nil : album
    }

    /// 只读缓存,**绝不阻塞**。返回 nil = 还没探到 / 已过期 / 换了曲目,调用方按
    /// fail-closed 处理。
    public func cachedReading(forKey key: String, now: Date = Date()) -> Reading? {
        lock.lock()
        defer { lock.unlock() }
        guard cachedKey == key, let reading = cachedReadingValue, let at = cachedAt else { return nil }
        let age = now.timeIntervalSince(at)
        guard age >= 0, age <= Self.verdictMaxAge else { return nil }
        return reading
    }

    /// `cachedReading` 的判定那一半 —— 广告闸那几个调用点只关心这个。
    public func cachedVerdict(forKey key: String, now: Date = Date()) -> Verdict? {
        cachedReading(forKey: key, now: now)?.verdict
    }

    /// 异步踢一次探测,不等结果。同一个 key 同时只有一次在飞。
    ///
    /// 不支持脚本命令的浏览器(Firefox 等)、非浏览器、以及 Safari 的媒体代理进程解析不出
    /// 宿主时,一次 AppleEvent 都不发起 —— 跟 `BrowserPositionProbe.kickIfNeeded` 的准入
    /// 判据一致(含那步"先把媒体代理进程解析成宿主 App"的别名解析,Safari 少了它会静默
    /// 一次都不探)。
    public func kickIfNeeded(bundleIdentifier: String?, key: String) {
        guard let hostBundleID = BrowserPositionProbe.probeTargetBundleID(forReported: bundleIdentifier),
              let family = BrowserAutomationPermission.family(forBundleID: hostBundleID)
        else { return }
        lock.lock()
        if inFlightKey == key {
            lock.unlock()
            return
        }
        // 已经有这个 key 的新鲜判定就不用再探(省掉稳态播放期间持续的 AppleEvent 往返)。
        if cachedKey == key, let at = cachedAt, Date().timeIntervalSince(at) <= Self.verdictMaxAge,
           cachedReadingValue != nil {
            lock.unlock()
            return
        }
        inFlightKey = key
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let reading = Self.probeOnce(bundleID: hostBundleID, family: family)
            self.lock.lock()
            if self.inFlightKey == key { self.inFlightKey = nil }
            // nil 不进缓存:那多半是"这一下没读到"(超时/标签页刚好在切),下一轮该重试,
            // 缓存住它等于把一次偶发失败按整首歌的时长放大。
            if let reading {
                self.cachedKey = key
                self.cachedReadingValue = reading
                self.cachedAt = Date()
            }
            self.lock.unlock()
        }
    }

    /// 换歌时清掉 —— 上一首的判定绝不能被当成这一首的用。
    public func trackChanged() {
        lock.lock()
        cachedKey = nil
        cachedReadingValue = nil
        cachedAt = nil
        inFlightKey = nil
        lock.unlock()
    }

    private static func probeOnce(bundleID: String, family: BrowserAutomationPermission.Family) -> Reading? {
        guard let out = BrowserTabProbeScript.run(
            bundleID: bundleID, family: family, hostMarker: hostMarker, js: probeJS,
            eventTimeoutSeconds: eventTimeoutSeconds, processTimeout: processTimeout,
            label: "ytmusic-ad")
        else { return nil }
        return parse(out)
    }

    /// 逐项照 `BrowserPositionProbe.buildAppleScript` 的写法:`tell application id`(不写死
    /// App 名字)、先扫各窗口当前标签页再退回全量扫描、每次执行都套 `with timeout` +
    /// 裸 `try…end try`。
    /// 保留这个入口只为两件事:①它的文本契约已经被 selftest 钉住(用 tell application id、
    /// 按域名过滤标签页、两处执行点都套 with timeout、有 NOTFOUND 兜底);②读代码的人从这个
    /// 类点进去就能看到脚本长什么样。模板本体 2026-09-03 抽到 `BrowserTabProbeScript` ——
    /// `SpotifyWebAdProbe` 要跑一模一样的东西,只是域名和 JS 不同,复制第二份等于把那些踩出来的
    /// 教训复制一份再等它们漂开。抽取当天用 harness 逐字节比对过:两种方言的输出跟抽取前
    /// 完全相同(chromium 2769 字符 / safari 2763 字符)。
    public static func buildAppleScript(bundleID: String, family: BrowserAutomationPermission.Family) -> String {
        BrowserTabProbeScript.build(bundleID: bundleID, family: family, hostMarker: hostMarker,
                                    js: probeJS, eventTimeoutSeconds: eventTimeoutSeconds)
    }

    /// 曲目身份 —— 跟 collector 侧 `trustedPlaybackRejected` 用的 key 同一个构造方式
    /// (`artist \0 title`),两边都按"广告是独立的 now-playing 条目"这条来失效缓存。
    public static func trackKey(artist: String?, title: String?) -> String {
        let a = (artist ?? "").trimmingCharacters(in: .whitespaces)
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        return a + "\u{0}" + t
    }
}
