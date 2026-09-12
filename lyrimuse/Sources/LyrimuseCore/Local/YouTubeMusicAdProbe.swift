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
/// ⚠️ 但「裸标题」在**换歌边界**上会单独误报(2026-09-08 实测,见 `badgeVerdict`):上一首刚结束到
/// 下一首 `<video>` 起播之间的两三秒,`document.title` 就是裸的「YouTube Music」,而 MediaSession 这时
/// 可能已经换成下一首了(18:07:19 抓到的边界样本:`0|0|1 title=[YouTube Music] vt=0.0`)。所以
/// "任一命中即广告"只用于 `gate`(拿不准就丢这一轮,下一轮自愈);**界面上写「广告中」**只认强信号
/// (ad-showing / 徽章),见 `badgeVerdict` / `cachedBadgeVerdict`。
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
    /// 返回 `a|b|c|slot|album`:前三个各为 0/1(ad-showing / 广告徽章 / 裸标题),第四段是
    /// **广告徽章上的计数**(2026-09-09 加,形如 `1/2`,取不到就是空串),最后一段是
    /// **页面上读到的专辑名**(2026-09-03 加,可能为空)。判定不在 JS 里做 —— 放在
    /// `parse(_:)` 里才跑得了单测。
    ///
    /// ⚠️ **专辑名必须放最后一段**:它是任意文本,理论上可以含 `|`。`parse` 因此按
    /// "最多切 5 段"来切,最后一段原样保留(含里面的 `|`)。2026-09-09 加计数段时它被插在
    /// 专辑名**前面**、不是追加在末尾,正是这个原因(评审时被指出:追加在后面要么拆坏
    /// 专辑名、要么从专辑名尾巴上偷走一段)。
    ///
    /// ⚠️ **计数在 JS 里就归一成 `1/2` 这种受限形状**,不回原始徽章文字 —— 徽章文字是
    /// 本地化的自由文本(中文「赞助商广告 1/2 ·」),原样回传会把 `|` 和换行的隐患带进来,
    /// 而这个文件的纪律是"专辑名之外的每一段都形状受限"。抓数字用
    /// 抓法是**语言无关的两步**(2026-09-09 当天第二版,用户追问「YT Music 不是中文的应该
    /// 也可以吧」——第一版只认斜杠,英文界面的 "Ad 1 of 2" 抓不到):
    ///
    ///  1. 先把**时间样式**的数字整段剔掉(`[0-9]+:[0-9]+`,全局)。徽章上常常还挂着「· 0:20」
    ///     这类剩余时长,不先剔掉的话第 2 步会把 `20 · 1` 当成一对。
    ///  2. 再抓「整数 + 1~12 个非数字 + 整数」(`([0-9]+)[^0-9]{1,12}([0-9]+)`),拼成 `1/2`。
    ///     中文「赞助商广告 1/2 ·」、英文 "Ad 1 of 2 ·"、德语 "Anzeige 1 von 2" 这类
    ///     「序号 + 一个词 + 总数」的写法一网打尽,不用为每种语言列词表。
    ///
    /// ⚠️ JS 里**双引号和反斜杠都不许出现**(整段要嵌进 AppleScript 的双引号串,selftest 两条
    /// 守卫盯着),所以写不了 `\d`、写不了正则字面量,只能 `new RegExp('…')`。
    ///
    /// 归一成 `1/2` 之后 Swift / Go 两侧的 parse 一个字都不用改,`AdSlot` 那三道合理性检查
    /// 继续兜底:日文 / 韩文「2件中1件目」这种**总数在前**的写法会解成 `2/1`,被"总数不小于
    /// 序号"挡掉 → 不显示。宁缺毋错。只播一条广告时徽章通常不带计数(「赞助商广告 ·」)、
    /// 或者只有时间(「广告 · 0:20」)→ 两种都是空串。
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
    var slotEl = document.querySelector('.ytp-ad-simple-ad-badge, .ytp-ad-badge');\
    var slot = '';\
    if (slotEl) { var st = String(slotEl.textContent || '').replace(new RegExp('[0-9]+:[0-9]+', 'g'), ''); var sm = st.match(new RegExp('([0-9]+)[^0-9]{1,12}([0-9]+)')); if (sm) { slot = sm[1] + '/' + sm[2]; } }\
    var t = (document.title || '').trim();\
    var bare = (t === 'YouTube Music') ? '1' : '0';\
    var bl = document.querySelectorAll('ytmusic-player-bar .byline a');\
    var album = '';\
    for (var i = 0; i < bl.length; i++) {\
    var h = bl[i].getAttribute('href') || '';\
    if (h.indexOf('browse/MPREb') >= 0) { album = (bl[i].textContent || '').trim(); break; }\
    }\
    return adShowing + '|' + badge + '|' + bare + '|' + slot + '|' + album;\
    })()
    """

    public static let hostMarker = "music.youtube.com"
    /// AppleScript `with timeout of N seconds` 的 N —— 把 Arc 那种"挂起不返回"变成一个
    /// 抓得住的错误(裸 `try` 抓不住挂起,只有它能)。
    public static let eventTimeoutSeconds = 4
    /// 整个 osascript 子进程的硬超时,兜最后一层。
    static let processTimeout: TimeInterval = 6
    /// 判定的**可读**有效期。音频歌曲的广告在 media-control 里是**独立的 now-playing 条目**
    /// (自己的 title/artist),换成广告身份就变了、缓存 key 自然失效,所以这个值只是兜"同一首歌
    /// 播很久"的情况,不需要很短。
    ///
    /// ⚠️ 但**音乐视频(MV)的前贴片广告不是独立条目**(2026-09-08 用户报「有视频的歌识别错了,
    /// 变成广告了」,Safari 播王子《Why You Wanna Treat Me So Bad?》当场坐实):前贴片在
    /// `#movie_player` 里放、MediaSession 元数据却一直是**这首歌自己的** —— collector 日志
    /// 08:30:22～08:30:37 三轮 `rejected as advertisement (王子 - Why You Wanna…)`,08:31:27 才
    /// `now playing`(正好是这 60 秒缓存到期后的第一轮)。也就是说同一个 key 下判定会从 ad 翻成
    /// song,"按曲目身份缓存是安全的"这条前提对 MV 不成立。**可读有效期仍是 60 秒**(读到一个
    /// 稍旧的 ad 判定总好过读到 nil —— nil 会让 `gate` fail-closed 把快照整条丢掉、广告中途
    /// UI 塌成"没有在播放"),但**再探一次的间隔**按判定分档,见 `refreshInterval(for:)`。
    public static let verdictMaxAge: TimeInterval = 60
    /// 判定是**广告**时,多久之后就该再问一次页面。广告一条只有 5～30 秒,前贴片放完页面就是
    /// 歌了 —— 5 秒一探,ad→song 的翻转最多晚 5 秒被看到(外加一次 ~0.2 秒的 AppleEvent 往返),
    /// 而不是等满 60 秒;代价是广告期间每 5 秒一次往返,广告本来就短,可以接受。
    public static let adRefreshInterval: TimeInterval = 5

    /// 判定是**歌**时的再探间隔。
    ///
    /// ⚠️ **必须严格小于 `verdictMaxAge`** —— 这是这两个量之间的不变量,selftest 钉着。
    /// 2026-09-11 之前这里就是 `verdictMaxAge` 本身(两个 60),于是下面 `refreshInterval`
    /// 注释里那句"两者之间的窄窗里 `cachedReading` 仍返回旧判定,不会出现 nil"对广告档成立、
    /// 对歌档**根本没有窄窗**:可读期与再探间隔同时到点,age 跨过 60 的那一拍必然同时满足
    /// ①`cachedReading` 刚过期返回 nil、②这一拍才开始**异步**重探(结果这一拍拿不到),
    /// 于是 `gate` fail-closed → 快照整条丢掉 → `clearIfWasPlaying()` → 三个展示面一起塌成
    /// "没有在播放"。也就是说**一首 album 为空的歌,每 60 秒就掉一次真空期**,不是只在
    /// 换曲/广告边界 —— 用户 2026-09-11 报的"广告之后几秒没有歌曲信息"只是最显眼的那一次。
    ///
    /// 真机日志坐实(2026-09-11,Safari 播 YT Music,`音樂頑童 - teachme` 那一首 253 秒):
    /// `local` 类别的 `snapshot failed` 出现在 15:57:45 / 15:58:17 / 15:59:19 / 16:00:20 /
    /// 16:01:22 / 16:02:24,间隔 60.2 / 62.1 / 62.2 / 62.2 秒 —— 与「60 秒可读期 + 一个 2 秒
    /// 轮询拍」严丝合缝,而那首歌全程正常播放(16:02:31 的锚点还在报 253.694s)。
    ///
    /// 45 秒留出 15 秒重叠窗:一次探测往返实测 ~187ms,15 秒足够它落地续期,稳态播放期间
    /// 判定因此**永不为 nil**。代价是一首 4 分钟的歌从 4 次 AppleEvent 变成 5 次。
    ///
    /// ⚠️ Go 侧(`ytmusicad.go`)**没有**这个问题、也不需要跟着改:那边 `ytmusicAdProbe` 是
    /// **同步**的,缓存过期就当场 `runYTMusicAdProbe` 阻塞探一次再返回,不存在"过期了但结果
    /// 还没到"的那一拍。这是 Swift 为了不卡住 UI 轮询而选择异步换来的副作用 —— 两边在
    /// **判据**上仍逐字一致(那才是必须同步改的),缓存/节流策略本来就各按各的执行模型。
    public static let songRefreshInterval: TimeInterval = 45

    /// 同一个 key 上距上次探测多久之后才**再探一次**(`kickIfNeeded` 的跳过条件)。跟
    /// `verdictMaxAge`(可读有效期)是两个量:判定是歌就 45 秒续期一次(稳态播放期间省掉持续的
    /// AppleEvent,又赶在 60 秒可读期到点前把判定换新);判定是广告就 5 秒一探,因为它随时会
    /// 翻成歌(MV 前贴片,见 `verdictMaxAge`)。两者之间的窄窗里 `cachedReading` 仍返回旧判定,
    /// 不会出现 nil —— **两档都必须真的留出这个窄窗**,理由见 `songRefreshInterval`。
    public static func refreshInterval(for verdict: Verdict) -> TimeInterval {
        switch verdict {
        case .ad: return adRefreshInterval
        case .song: return songRefreshInterval
        }
    }

    private let lock = NSLock()
    private var cachedKey: String?
    private var cachedReadingValue: Reading?
    private var cachedAt: Date?
    private var inFlightKey: String?
    /// 探针结果落地(缓存已更新)时的回调 —— `LocalPlaybackSource` 挂上"立刻 poll 一次",
    /// 不等下一拍 2s 轮询来消费(2026-09-11)。照 `SpotifyPositionProbe.setResultSink`
    /// 那条成熟先例:poll() 自己会核对曲目身份,消费那边还有 key 一道门,多查一次完全无害。
    ///
    /// 这一条治的是**换曲 / 广告边界那一拍**:新 key 下缓存必然是空的(`cachedReading` 按 key
    /// 比对),`gate` fail-closed 丢掉这一拍是设计如此,但丢完之后原本要干等一整个轮询周期才有
    /// 人拿探针刚探回来的结果。挂上它之后这段等待从"一拍"变成探针往返本身(~187ms)。
    /// 没挂 sink 就退化回旧行为(等下一拍),不会出错。
    private var resultSink: (@Sendable (_ key: String) -> Void)?

    private init() {}

    public func setResultSink(_ sink: @escaping @Sendable (_ key: String) -> Void) {
        lock.lock()
        resultSink = sink
        lock.unlock()
    }

    /// 一次探测读到的全部东西:判定 + 判定的强弱 + 页面上的专辑名。
    public struct Reading: Equatable, Sendable {
        public let verdict: Verdict
        /// 判定为广告时,是不是**强信号**撑起来的:播放器 class 含 `ad-showing`、或页面上有广告徽章元素。
        /// 只靠裸标题(`document.title == "YouTube Music"`)撑起来的广告判定是**弱**的,见 `badgeVerdict`。
        /// 判定为歌时恒 false。
        public let strongAd: Bool
        /// 页面 byline 里那个专辑链接的文字。读不到(广告期间、视频、页面结构变了)是空串。
        public let album: String
        /// 广告徽章上的「第几条 / 共几条」(2026-09-09)。一次插播可能连放两条,YouTube 自己
        /// 把它写在 `.ytp-ad-simple-ad-badge` 上(「赞助商广告 1/2 ·」)。读不到、只播一条、
        /// 英文界面、或者根本不是广告时是 nil —— **不编**。
        public let adSlot: AdSlot?

        /// `adSlot` 给默认值 nil:这个参数 2026-09-09 才加,默认值是为了让既有调用点
        /// (以及只关心判定的那些测试)一个字都不用改。
        public init(verdict: Verdict, strongAd: Bool, album: String, adSlot: AdSlot? = nil) {
            self.verdict = verdict
            self.strongAd = verdict == .ad && strongAd
            self.album = album
            self.adSlot = adSlot
        }
    }

    /// 一次插播里「这是第几条、一共几条」(2026-09-09)。
    ///
    /// 只从探针第四段那个受限形状(`1/2`)解出来,解不动就是 nil。三道合理性检查挡住
    /// "页面上别处的数字被误抓进来":序号至少 1、总数不小于序号、总数不超过 `maxTotal` ——
    /// 一次插播连放十几条不存在,真读到那种数字说明抓错了元素。
    public struct AdSlot: Equatable, Sendable {
        public static let maxTotal = 20
        public let index: Int
        public let total: Int

        public init?(rawPair: String) {
            let parts = rawPair.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let total = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  index >= 1, total >= index, total <= Self.maxTotal
            else { return nil }
            self.index = index
            self.total = total
        }

        public init(index: Int, total: Int) {
            self.index = index
            self.total = total
        }
    }

    /// 把探针的裸文本输出解成一次读数。纯函数,可单测。
    ///
    /// 形状不认识(空 / NOTFOUND / 段数不够 / 前三段非 0/1)一律返回 nil —— **不猜**,
    /// 让调用方走 fail-closed。
    ///
    /// ⚠️ 只切 5 段(`maxSplits: 4`):最后一段是专辑名,是任意文本、可能自带 `|`,原样保留。
    /// 段数**多于** 5 在这套切法下不存在。
    ///
    /// ⚠️ **只认 5 段,不给旧形状留兼容分支**(2026-09-09,这一点评审时先猜错、被 selftest
    /// 打回来才定的)。评审建议过"5 段=新形状、4 段=旧形状"两分支兜底,听起来稳妥,实际
    /// **做不到**:专辑名里自带 `|` 是明确支持的(`0|0|0|A|B` 这条守卫就是钉它的),那时旧形状
    /// 切出来也是 5 段、跟新形状**逐字同形**,于是 `A` 被当计数、`B` 被当专辑名 —— 守卫当场
    /// 变红。段数根本不足以区分两种形状,所以不猜:JS 与 parse 永远同版本同二进制,现行 JS
    /// (`omittingEmptySubsequences: false`)一定回 5 段,少于 5 段就是畸形输入,专辑名取不到、
    /// 计数也没有,但**前三段的判定照样解**(那三段的位置在任何形状里都没变过)。
    ///
    /// ⚠️ **计数段形状不对时不 fail-closed** —— 只把计数当没有,绝不让整条 Reading 回 nil。
    /// 前三段是**判定**,形状不对必须不猜;计数是**装饰**,拿它去连坐掉「广告中」的判定
    /// 就本末倒置了。真广告的第一拍常常是"ad-showing 已经起来、徽章还没渲染出来",
    /// 那时计数为空是**常态**不是异常。
    public static func parse(_ raw: String) -> Reading? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // AppleScript 有时把返回值再包一层双引号,脱掉。
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.contains("NOTFOUND") { return nil }
        let parts = s.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        var isAd = false
        var strongAd = false
        for (index, part) in parts.prefix(3).enumerated() {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "1":
                isAd = true
                // 前两段(ad-showing / 徽章)是强信号,第三段(裸标题)是弱信号 —— 见 badgeVerdict。
                if index < 2 { strongAd = true }
            case "0": break
            default: return nil // 形状不对,不做任何推断
            }
        }
        // 只认 5 段,理由见头注那条⚠️(4 段兼容做不到 —— 专辑名含 `|` 时两种形状同形)。
        let adSlot = parts.count == 5 ? AdSlot(rawPair: String(parts[3])) : nil
        let albumField: Substring? = parts.count == 5 ? parts[4] : nil
        // 专辑名里的换行压平:osascript 的输出是按行读的,真混进换行会让下游的日志/
        // 比较莫名其妙。压平在这儿做,不在 JS 里做 —— JS 那边写 `\s` 要用反斜杠,
        // 而整段 JS 嵌在 AppleScript 的双引号字符串里,反斜杠是那边的转义字符。
        let album = albumField
            .map {
                $0.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
        return Reading(verdict: isAd ? .ad : .song, strongAd: strongAd, album: album, adSlot: adSlot)
    }

    /// 「界面上该不该写『广告中』」看的判定 —— 跟 `gate` 吃的 `verdict` 是**两个口径**(2026-09-08,
    /// 用户报 Safari 播 YT Music 一首真歌整首「广告中」,见 02 章决策 #26):
    ///   - `.song` 原样;
    ///   - 强信号的 `.ad`(ad-showing / 徽章)原样;
    ///   - **只靠裸标题**撑起来的 `.ad` → nil(「拿不准」)。
    ///
    /// 为什么裸标题在这里不算数:换歌的那两三秒页面 `document.title` 会退成裸的「YouTube Music」
    /// (2026-09-08 18:07:19 抓到的边界样本:上一首刚结束、`<video>` 停在 0.0、标题已是「YouTube Music」),
    /// 而 MediaSession 这时可能已经换成了下一首 —— 此时若恰好探了一次(YT Music 首次发布元数据常常不带
    /// album,`trustedPlaybackRejected` 会踢探针),弱 `.ad` 就缓存到了**下一首歌的 key** 下;下一拍换曲按
    /// 当下判定定初值,整首真歌被贴上「广告中」。真广告期间三个信号 22/22 同时命中(见头注),裸标题从没
    /// 单独撑过一条真广告,所以只在**贴标签**这一路把它降成「拿不准」;`gate`(要不要采纳这条播放,
    /// collector 侧同款判据)仍按任一命中即广告 —— 那边误判成广告只是这一轮没采纳,下一轮就好。
    public static func badgeVerdict(_ reading: Reading?) -> Verdict? {
        guard let reading else { return nil }
        if reading.verdict == .ad, !reading.strongAd { return nil }
        return reading.verdict
    }

    /// `badgeVerdict` 接上缓存 —— `LocalPlaybackSource` 决定「广告中」时读这个,**不读** `cachedVerdict`。
    public func cachedBadgeVerdict(forKey key: String, now: Date = Date()) -> Verdict? {
        Self.badgeVerdict(cachedReading(forKey: key, now: now))
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
        // "新鲜"按判定分档:歌 60 秒,广告 5 秒 —— MV 的前贴片广告放完后同一个 key 会翻成歌,
        // 60 秒不再问就会把「广告中」多挂 60 秒(见 refreshInterval(for:))。
        if cachedKey == key, let at = cachedAt, let reading = cachedReadingValue,
           Date().timeIntervalSince(at) <= Self.refreshInterval(for: reading.verdict) {
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
            // 只有**真的写了缓存**才唤醒补查 —— 探测失败(nil)时缓存没变,补查那一拍还是
            // 读到同样的 nil、还是 fail-closed,白跑一次子进程。这一条同时也是自激循环的
            // 闸:补查 → kickIfNeeded 看到刚写的新鲜判定会直接跳过,不会再探。
            let sink = reading != nil ? self.resultSink : nil
            self.lock.unlock()
            // ⚠️ 在锁外调:sink 里是 `Task { @MainActor … poll() }`,而 poll 那条路会回头
            // 读这个探针的缓存(`cachedVerdict`/`cachedReading` 都要拿同一把锁)。
            sink?(key)
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
