import Foundation
import os

/// 浏览器播放位置的地面真值探针:用 AppleScript 让浏览器执行一小段 JavaScript,读页面自己渲染的播放进度。
///
/// ## 为什么要绕开 MediaRemote
///
/// 网页播放器只要页面没调 `mediaSession.setPositionState()`,MediaRemote 报的锚点就是冻结的(`elapsedTime` 恒为 0、
/// `timestamp` 恒等于会话创建时刻),而创建时刻比音频真实起点晚一截(页面先出声、后注册元信息),整首歌的位置固定偏慢一截。
/// 幅度因页面加载/JS 初始化耗时而异、连正负号都不固定,MediaRemote 也不给站点信息,学不出一个固定偏移。见 02 章「锚点冻结的源
/// (网页播放器)三件事」。进度读页面文字,不读 YouTube Music 的 `<video>.currentTime`:"电台/续播"模式下那个字段是整个会话的
/// 累计时间、跨歌不清零(跟整秒文字对得上时另交一份精确读数,见 youtubeMusicScript 头注)。
///
/// ## 覆盖范围与已知局限
///
/// - 站点:`supportedPlatforms` 里那几个。要支持别的网站往 `siteRules` 加一条规则;选择器/解析方式因站而异,新增前得先实测
///   该站点自己的 DOM 结构。
/// - 浏览器:Chromium 系(Arc/Chrome/Edge,见 `BrowserAutomationPermission.Family.chromium`,AppleScript 词典里的 `execute`
///   命令一致)+ Safari(WebKit,命令名不同,见 `buildAppleScript` 的 family 分支)。一律用 `tell application id "<bundleID>"`,
///   不写死 App 名字。没有脚本命令的浏览器(Firefox 等,`BrowserAutomationPermission.family` 返回 nil)静默跳过,行为上跟这个
///   探针不存在时一样。
/// - 硬依赖每个浏览器自己那道"允许来自 Apple 事件的 JavaScript"开关(默认关闭,检测/开启逻辑见 `BrowserAutomationPermission`)。
///   开关关着时的失败方式因浏览器而异:Arc 的 `execute … javascript` 挂起不返回,Chrome 立刻抛一个 AppleScript 错误("通过
///   AppleScript 执行 JavaScript 的功能已关闭…");Edge 没实测过,假定接近 Chrome。`buildAppleScript` 用 `with timeout of N seconds`
///   (把挂起变成抓得住的 -1712 错误,裸 `try` 抓不住挂起)+ 裸 `try…end try`(吞掉错误、继续找下一个标签页)+ `ProcessRunner`
///   的超时(最后杀掉子进程)一起兜住,对调用方都表现成探测失败、静默退回原有的 MediaRemote 逻辑:探针只做加分项,不能让它
///   自己变成新的故障点。
/// - 换歌时缓存立刻作废(见 `trackChanged()`),新曲目要等下一轮探测成功才有地面真值,这之前退回既有逻辑。
///
/// ## 平台与浏览器配对即开关
///
/// 设置里「网页版」卡片按 `supportedPlatforms` 逐个平台列出配对的浏览器(同一个平台可以配多个浏览器)。没配对过的浏览器(哪怕
/// 已经信任、哪怕真的开着这个网站)完全不会触发探测,不会发起任何 AppleScript 调用。配对数据(`platformBrowserPairs`)由 UI 层
/// (启动时 + 设置里改配对时)直接写这个类的公开属性,跟 `LocalPlaybackSource.romanizationScripts` 同一个"UI 推值进
/// LyrimuseCore 单例"的模式。见 02 章「「网页播放器」卡:平台 ↔ 浏览器配对」。
///
/// ## 一次性纠偏,不持续覆盖
///
/// 探针只在换歌后用一次,把它当这首歌的"精确种子值"交给 `resolvePositionSeconds`,之后不再探测这首歌(见 `consumeCorrection`
/// 和 `kickIfNeeded`)。不能每一轮(~0.9s 一次探测往返)都让 `positionSeconds` 直接等于探针值:整秒读数只有整秒精度,而 Arc 走
/// media-control 的 `elapsedTimeNow` 是连续、±0.05s 精度的干净外推(`positionSourceTier` 归在 `.cleanExtrapolated`),直接替换
/// 会让这个更准的基准每 ~0.9 秒被粗精度值拽回。
///
/// 那一次也不走伺服的 EMA 闸门:`servoDecision` 对 `noisyFloored` 是 alpha 0.3 / 门槛 1.0,是给周期性噪声源设计的,单个样本要
/// 误差超过 3.33 秒才可能触发。重锚走 `LocalPlaybackSource.groundTruthSnapToleranceSecs` 那条专门路径(门槛 0.30s,不走 EMA)。
/// 整秒读数的取整偏置见 `flooredMidpointBiasSecs`。
public final class BrowserPositionProbe: @unchecked Sendable {
    public static let shared = BrowserPositionProbe()
    private init() {}

    /// 采信和弃用两边都记,弃用要带原因:不然探针被哪道判据整首废掉时,日志里看不出来。见 02 章「怎么查这个探针」。
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "browserprobe")

    private static let probeTimeout: TimeInterval = 3

    /// 去掉"整秒下取整"的系统性偏置:页面显示的是 `floor(真实位置)`,真实位置均匀分布在 `[n, n+1)`,取中点才是无偏估计;
    /// 直接用 `n` 恒偏后、均值 −0.5 秒。页面是 floor 不是 round:暂停那一刻 MediaRemote 记下 `elapsedTime=165.627`,页面文字是
    /// `165`(round 会是 166)。
    ///
    /// 加了这 0.5 之后,读数不再满足"reported ≤ 真实位置",而前向棘轮(`shouldRatchetForward`)的前提就是那条不等式。所以
    /// `resolvePositionSeconds` 里探针那一支必须排在棘轮之前、自成一条路径,不能落进棘轮。
    public static let flooredMidpointBiasSecs: Double = 0.5

    /// `<video>.currentTime` 比页面整秒文字最多领先这么多,才算同一个钟(见 youtubeMusicScript 第四段)。
    /// 文字是 `floor(currentTime)`、渲染滞后 ≤0.05s,正常领先落在 [0, 1.05);电台 / 续播的累计时间
    /// 差着整首歌长,远在窗口外。
    public static let currentTimeSlackSecs: Double = 1.25

    /// 精确读数(`currentTime`)跟我们的外推差多少以内不动(见 `LocalPlaybackSource.groundTruthSnapToleranceSecs`,
    /// 那个 0.30 是给整秒读数的)。实测 Safari 里 media-control 外推与 `currentTime` 逐拍差 0.001s。
    public static let preciseSnapToleranceSecs: Double = 0.1

    // MARK: - 探针值的可信度判据

    /// **别拿任何 MediaRemote 报的位置(如 `snapshot.elapsedTime`)或外推值当这个探针的
    /// 校验参照物**:网页播放器的 MediaRemote 锚点本身是冻结的(见类头注开头),拿它当参照
    /// 会在锚点错得最厉害的场合(冷启动、歌已经放到两分钟、MediaRemote/外推都报 0)正好把
    /// 探针挡掉——那恰恰是探针最该生效的场合。
    ///
    /// 判据不问"这个值离某个参照物多远",问两件**探针自己拿得出材料**的事:
    ///   ① 这个标签页放的是不是同一首歌(`pageDurationToleranceSecs`,在 JS 里比);
    ///   ② 这个标签页的钟有没有在走(`pageClockIsRunning`,两次采样)。
    /// 陈旧镜像标签页的特征恰恰是**它不动**(实测:15 次采样一直读 7 秒),
    /// 这比"它离 MediaRemote 多远"直接得多,也不依赖任何一个我们不信任的数。

    /// 两次采样之间隔多久。
    ///
    /// 下界由页面读数的量化精度定死:读的是页面渲染的进度文字,只有整秒精度,所以间隔必须 > 1 秒才能保证正常播放时 floor
    /// 至少 +1;否则"没前进"分不出是"钟停了"还是"还没跨过整秒边界"。取 1.5 秒是给后台标签页的 1Hz 计时器节流留一倍余量。
    ///
    /// 代价是纠偏晚约 1.5 秒落地(一次探测变两次采样 + 中间等待)。落地的值仍然是对的(`consumeCorrection` 按 `rate * age`
    /// 补偿滞后),晚的只是那一刻;正常换下一首时未纠偏的位置本来也≈0,真正吃到这 1.5 秒的只有"冷启动时歌已经放到一半"这种场合。
    public static let livenessGapSeconds: TimeInterval = 1.5

    /// 两次采样之间页面进度**有没有往前走**。纯函数,给 selftest 直接覆盖。
    ///
    /// 判据是"floor 有没有 +1",不是"增量 ≈ Δt × rate"。读数本来就是整秒地板量化的,
    /// 拿它去比一个连续量要给的容差大到没有区分力(Δt=1.5s 时增量只可能是 1 或 2);
    /// 而"有没有 +1"本身已经把"钟在走"和"钟停了"完全分开了。
    ///
    /// 两个已知的、**刻意选择**的失败方向,都往"不纠偏"倒:① 倍速 0.5x 时 1.5 秒只走
    /// 0.75 秒媒体时间,floor 可能不 +1 → 判否;② 用户往回拖进度条(second < first)→ 判否。
    /// 两种都只是这一轮不纠偏、下一轮重试,跟 spotifyWebScript 头注里暂停判据的失败方向是同一个
    /// 取向:宁可不纠偏,也不能采信一个读错了标签页的值。
    public static func pageClockIsRunning(first: Double, second: Double) -> Bool {
        second > first
    }

    /// 页面显示的总时长跟 MediaRemote 报的时长差多少之内算"同一首歌"。
    ///
    /// 这道判据在 JS 里比(见两条站点规则里的 `__EXPECT__`),不在 Swift 里:差一首歌的标签页要让 AppleScript 那两遍循环继续往下找,
    /// 而不是整次探测就此失败,否则"陈旧镜像排在正在放的那个标签页前面"时,后者永远轮不到。
    ///
    /// 它挡的是"读到了另一份媒体":同一浏览器里的第二个 Spotify 标签页、YouTube Music 插的广告(广告那行进度文字是广告自己的、
    /// 而且是在走的,`pageClockIsRunning` 对广告一路放行,只有时长对不上认得出来,别指望活性判据兜这个)。
    ///
    /// 容差 2 秒:页面显示的是 `floor(总时长)`,MediaRemote 给的是小数(`duration=218.781` 对页面 `3:38`=218),固有差不到 1 秒,
    /// 留一倍余量。
    ///
    /// 期望时长未知(传 0)或页面读不出总时长时跳过这道检查,不是判否:最坏也不过是回到没有这道检查的样子,不能让一个拿不到的
    /// 字段把整个探针关掉。
    public static let pageDurationToleranceSecs: Double = 2

    /// 同一首歌最多探测几次。
    ///
    /// 为什么需要它:判"钟没在走"可能是**瞬时**的 —— 页面在缓冲、标签页刚被
    /// 切到后台还没跑满一个计时周期。这类失败**不消费**那次一次性额度(判据在探针内部,拿不到
    /// 值就不写缓存,`consumeCorrection` 自然不会置 `consumedKey`),所以重试是自动的;但自动
    /// 重试没有上界就变成"整首歌每一轮都去 tell 一遍浏览器"。三次 + 退避是两头的折中:瞬时
    /// 抖动有得救,真读不到的标签页也不会被骚扰一整首歌。
    public static let maxProbeAttempts = 3
    /// 两次探测尝试之间至少隔多久(从上一次**结束**算起)。
    public static let probeRetryBackoffSecs: TimeInterval = 3

    /// 单条 `execute … javascript` / `do JavaScript` 的 **AppleEvent** 超时(秒)。
    ///
    /// 必须有,而且必须比 `probeTimeout` 小:这条命令会**永远挂着不返回**(见
    /// `activeTabExpression` 头注的 Arc 休眠标签页实测),AppleScript 的 `try` 抓不住挂起,
    /// 只有 `with timeout of N seconds` 能把它变成一个能被 `try` 抓住的错误(-1712)。
    /// 没有它的话,一个休眠标签页就能把整次探测的 3 秒预算吃光、后面真正在播放的标签页
    /// 根本轮不到。
    ///
    /// 探测循环里可能要连着跳过好几个休眠标签页,所以每条给 1 秒(活标签页实测 ~0.2 秒,
    /// 5 倍余量);自检只发一条命令、有整个 3 秒可用,给 2 秒更宽松。
    private static let probeEventTimeoutSeconds = 1
    private static let selfTestEventTimeoutSeconds = 2

    /// 「这个窗口此刻真正显示着的那个标签页」的 AppleScript 说明符:Chromium 系叫 `active tab`(四字码 `acTa`,Arc/Chrome/Edge
    /// 三家一致),Safari 叫 `current tab`(`cTab`),不同名,逐个从各自 bundle 里的 sdef 核对过。
    ///
    /// 非它不可:Arc 会把非当前标签页休眠掉,对休眠标签页执行 JavaScript 会一直不返回(`execute (tab 1 of window 1) javascript
    /// "1+1"` 挂到被杀,同一时刻 `execute (active tab of window 1) javascript "1+1"` 123 毫秒返回 2),当前标签页的邻居一样挂死。
    /// 「第一个窗口的第一个标签页」这种看起来最稳妥的取法,在 Arc 上几乎必然踩中休眠标签页。标签页的 `loading`/`location`
    /// 属性都判不出它是不是休眠的,没有可用的前置判据,只能靠"取当前标签页" + `with timeout` 兜底。
    private static func activeTabExpression(
        family: BrowserAutomationPermission.Family, windowIndex: String
    ) -> String {
        switch family {
        case .chromium: return "active tab of window \(windowIndex)"
        case .safari:   return "current tab of window \(windowIndex)"
        }
    }

    /// 一个"网页音乐平台"的公开身份——设置里的「网页版」卡片按这份列表逐个渲染
    /// 平台分组,用户在每个分组下配对要用的浏览器。只有 `id`/`displayName`,不带任何探测
    /// 实现细节(那些在 `SiteRule` 里,是私有的)。
    public struct BrowserMusicPlatform: Identifiable, Equatable, Hashable, Sendable {
        public let id: String
        public let displayName: String
    }

    /// 目前支持的平台。要新增网站:先像下面这两个一样**实测过该站点自己的 DOM 结构**、写好
    /// 对应的 `SiteRule`,再在这里加一条 `BrowserMusicPlatform`——两处的 `id` 必须一致
    /// (`SiteRule.platformID` 是配对生效的匹配键)。
    ///
    /// **别照抄另一个平台的规则**。两个站点实测下来"看着一样、其实处处不同":YouTube Music
    /// 的进度在 `.time-info`(形如 "0:57 / 4:04",带斜杠)、暂停靠 `<video>.paused` 判;
    /// Spotify Web 的进度在 `[data-testid=playback-position]`(只有当前位置、没有总时长)、
    /// **页面里压根没有 `<video>` 也没有 `<audio>`**,暂停只能另找判据。见
    /// `spotifyWebScript` 头注。
    public static let supportedPlatforms: [BrowserMusicPlatform] = [
        BrowserMusicPlatform(id: "youtubeMusic", displayName: "YouTube Music"),
        BrowserMusicPlatform(id: "spotifyWeb", displayName: "Spotify"),
    ]

    /// 一条站点规则:属于哪个平台 + URL 特征子串 + 怎么从页面里抠出"这首歌当前播放到
    /// 第几秒"。JS 源码**必须只用单引号做字符串字面量**——它要整段嵌进 AppleScript 的
    /// 双引号字符串里,用单引号能完全绕开转义(见 buildAppleScript),出错概率最低。
    ///
    /// 脚本里的 `__EXPECT__` / `__TOL__` 两个占位符由 `buildAppleScript` 在拼进 AppleScript
    /// **之前**替换成数字(见 `pageDurationToleranceSecs`)。用占位符而不是给 `script` 改成
    /// 闭包,是为了让这张规则表继续是一张**纯数据**表 —— 加站点的人照抄一条就行,不用先搞懂
    /// 参数怎么传进来。 替换必须在拼进 AppleScript 之前做,拼完再替换会撞上转义。
    private struct SiteRule {
        let platformID: String
        let urlContains: String
        let script: String
    }

    /// 顺序即优先级:`probeOnce` 按这个顺序试用户配对过的规则,**第一条拿到"确实在播放"
    /// 读数的就直接返回**。所以每条规则的暂停判据都必须靠谱 —— 一个开着但暂停的标签页如果
    /// 误报成"在播",会把它的陈旧位置安到另一个平台正在播的那首歌上。
    private static let siteRules: [SiteRule] = [
        SiteRule(platformID: "youtubeMusic", urlContains: "music.youtube.com", script: youtubeMusicScript),
        SiteRule(platformID: "spotifyWeb", urlContains: "open.spotify.com", script: spotifyWebScript),
    ]

    /// YouTube Music 的播放进度取自页面自己渲染的".time-info"文字(形如"0:57 / 4:04"),不取 <video>.currentTime:"电台/续播"
    /// 模式下那个字段是整个会话的累计时间(同一时刻 currentTime=516s,这首歌本身只有 243s)。顺带把 <video>.paused 也带出来,
    /// 调用方用它排除"标签页开着但暂停/静音后台"的干扰。
    ///
    /// 返回值不用 JSON.stringify:`execute … javascript` 把 JS 返回的字符串再包一层 AppleScript 字符串时,会把已有的双引号真的
    /// 转义成反斜杠(字符串本身多了 `\` 字符),拿它去跟手写的 `"\"found\":true"` 比较会稳定判 false。所以 JS 返回值从头到尾
    /// 不含双引号,用 `"<seconds>|<pausedFlag>"` 这种竖线分隔的裸文本。
    ///
    /// 第三段:封面地址,取页面 `navigator.mediaSession.metadata.artwork` 的最后一张(最大的那张)。音轨版本是曲库的方形
    /// 专辑图(`*.googleusercontent.com`),MV 是视频截图,解析时只认前者(`KasetPlayerInfo.coverArtworkURL`)。
    ///
    /// 第四段:精确读数 `@<currentTime>,<Date.now() 毫秒>`。前缀 `@` 不能省:AppleScript 那层靠 `r does not contain "|1"`
    /// 认暂停,不带前缀时 `||160.8…` 这种以 1 开头的读数会被当成暂停整条扔掉。`currentTime` 只有在跟整秒文字对得上
    /// (`0 ≤ currentTime − 文字秒数 < currentTimeSlackSecs`)时才交出,电台 / 续播那种累计时间差着整首歌长,落不进这个窗口,
    /// 自动退回整秒读数。时间戳在 JS 里取,是读数那一刻的墙钟:osascript 的往返时间不算进读数的年龄。
    ///
    /// 第五段:视频身份 `#<videoId>,<musicVideoType>`(读不到就空)。取自 `#movie_player.getPlayerResponse()`,给 MV 时间轴
    /// 换算用(`LocalPlaybackSource.noteBrowserVideo`)。前缀 `#` 同样是为了不让 AppleScript 那层的 `|1` 暂停判据撞上以 1 开头的
    /// videoId。
    private static let youtubeMusicScript = """
    (function(){
      var el = document.querySelector('.time-info');
      if (!el) return 'NOTFOUND';
      var text = (el.textContent || '').trim();
      var parts = text.split('/');
      if (parts.length !== 2) return 'NOTFOUND';
      function toSecs(s) {
        var f = s.trim().split(':');
        if (f.length < 2 || f.length > 3) return -1;
        var n = 0;
        for (var i = 0; i < f.length; i++) {
          var v = parseInt(f[i], 10);
          if (isNaN(v)) return -1;
          n = n * 60 + v;
        }
        return n;
      }
      var cur = toSecs(parts[0]);
      var total = toSecs(parts[1]);
      if (cur < 0 || total < 0) return 'NOTFOUND';
      if (__EXPECT__ > 0 && Math.abs(total - __EXPECT__) > __TOL__) return 'NOTFOUND';
      var video = document.querySelector('video');
      var paused = video ? video.paused : false;
      var precise = '';
      if (video && !paused) {
        var ct = video.currentTime;
        var lead = ct - cur;
        if (lead >= 0 && lead < __CT_SLACK__) precise = '@' + ct.toFixed(3) + ',' + Date.now();
      }
      var art = '';
      try {
        var md = navigator.mediaSession && navigator.mediaSession.metadata;
        var arts = md && md.artwork;
        if (arts && arts.length) art = String(arts[arts.length - 1].src || '');
        if (art.indexOf('|') >= 0) art = '';
      } catch (e) {}
      var ident = '';
      try {
        var mp = document.querySelector('#movie_player');
        var pr = (mp && mp.getPlayerResponse) ? mp.getPlayerResponse() : null;
        var vd = pr && pr.videoDetails;
        if (vd && vd.videoId) ident = '#' + vd.videoId + ',' + (vd.musicVideoType || '');
      } catch (e) {}
      return cur + '|' + (paused ? '1' : '0') + '|' + art + '|' + precise + '|' + ident;
    })()
    """

    /// Spotify 网页版(`open.spotify.com`)的播放进度。跟 YouTube Music 那条规则差异很大,没有一条能照搬。
    ///
    /// ## 进度取自 `[data-testid=playback-position]` 的文字
    ///
    /// 形如 "2:18",只有当前位置(总时长在另一个元素 `playback-duration`,这里用不着)。
    ///
    /// 进度条里那个 `<input>` 别用:`[data-testid=playback-progressbar] input` 带 `value=145000 max=269340`,看着是毫秒精度,
    /// 但它是给滑块用的节流状态,5 秒一跳而且滞后(同期文字一直在走),照它写出来的进度会一顿一顿。
    ///
    /// ## 暂停判据:`document.title` 里有没有那个分隔符
    ///
    /// 不能用 `<video>.paused`:Spotify Web 页面里没有 `<video>` 也没有 `<audio>`。别的候选也都不行:
    /// - 播放/暂停键的 `aria-label` 是本地化的(中文界面下播放中是「暂停」),认它等于只支持一种语言。
    /// - `navigator.mediaSession.playbackState`:Spotify 没设,恒为 `'none'`。
    /// - 按钮和它的祖先节点(扫过三层)只有 `data-testid`,没有任何状态位。
    /// - 图标 SVG `path` 的 `d` 能分开播放/暂停,但认图标路径字符串太脆,Spotify 换一版图标就悄悄失效。
    ///
    /// `document.title` 播放中是 `歌名 • 歌手`,暂停时整个回落成静态的 `Spotify - Web Player: Music for everyone`(中文界面下
    /// 这句仍是英文)。判据只看那个分隔符在不在,不看任何一边的文案,所以不受本地化影响,也不受那句英文将来改字影响。分隔符用
    /// `String.fromCharCode(8226)` 拼(U+2022 圆点),不把非 ASCII 字符直接写进这段嵌进 AppleScript 的源码里。
    ///
    /// 万一将来 Spotify 换掉标题格式,这里会退化成"永远判暂停" → 探针不出手 → 静默退回既有的 MediaRemote 逻辑。这是刻意选的
    /// 失败方向:宁可不纠偏,也不能把一个暂停标签页的陈旧位置安到正在播的歌上。
    ///
    /// ## 位置文字支持 `M:SS` 和 `H:MM:SS` 两种
    ///
    /// 播客/长音频会走到三段式,YouTube Music 那条规则只认两段(它自己的元素也只会是两段)。
    ///
    /// 第三段:封面地址。`now-playing-widget` 里 `img[data-testid=cover-art-image]` 的 src 是 Spotify 图床 300 档
    /// (`ab67616d0000e1a3…`,webp),同一 hash 换成 `82c1` 就是 2000×2000 的原图,是页面上唯一一份身份精确的封面来源(Safari 经
    /// MediaSession 交给系统的那份是 640×640、同一张图,但没有地址)。地址随读数一起回传,`parseReading` 解析、`setArtworkSink`
    /// 交出去,跟原生客户端 `SpotifyPositionProbe` 的 `artwork url` 走同一条下游(`LocalPlaybackSource.spotifyArtworkURL`)。
    /// 曲目 ID 页面上拿不到:`context-item-link` 指向 `/album/<id>`、`context-item-info-artist` 指向 `/artist/<id>`,没有
    /// `/track/` 链接,所以真曲目链接 / LB 字段那一路只覆盖原生客户端。YouTube Music 的脚本第三段是页面 mediaSession 里的专辑图
    /// (见 youtubeMusicScript 头注),解析按"有就用、没有就 nil"处理。
    private static let spotifyWebScript = """
    (function(){
      function toSecs(s) {
        var f = s.trim().split(':');
        if (f.length < 2 || f.length > 3) return -1;
        var n = 0;
        for (var i = 0; i < f.length; i++) {
          var v = parseInt(f[i], 10);
          if (isNaN(v)) return -1;
          n = n * 60 + v;
        }
        return n;
      }
      var el = document.querySelector('[data-testid=playback-position]');
      if (!el) return 'NOTFOUND';
      var cur = toSecs(el.textContent || '');
      if (cur < 0) return 'NOTFOUND';
      if (__EXPECT__ > 0) {
        var dEl = document.querySelector('[data-testid=playback-duration]');
        var total = dEl ? toSecs(dEl.textContent || '') : -1;
        if (total >= 0 && Math.abs(total - __EXPECT__) > __TOL__) return 'NOTFOUND';
      }
      var sep = ' ' + String.fromCharCode(8226) + ' ';
      var paused = document.title.indexOf(sep) < 0;
      var img = document.querySelector('[data-testid=now-playing-widget] img[data-testid=cover-art-image]');
      var art = img ? (img.currentSrc || img.src || '') : '';
      return cur + '|' + (paused ? '1' : '0') + '|' + art;
    })()
    """

    /// MediaRemote 报上来的 bundle id → **真正能被 AppleScript 驱动的那个 App**。
    ///
    /// 绝大多数情况原样返回;只有"媒体代理进程"要换成它的宿主(目前只有一条实测登记过的:
    /// `com.apple.WebKit.GPU` → `com.apple.Safari`,见 `TrustedPlayers.mediaProxyOwners`)。
    /// 纯函数,给 selftest 钉住这条跨层不变量 —— 漏了它的后果是"配对了 Safari 却永远不
    /// 同步",一条日志都不会有。
    public static func probeTargetBundleID(forReported bundleID: String?) -> String? {
        TrustedPlayers.mediaProxyOwner(of: bundleID) ?? bundleID
    }

    /// 「哪些平台真的有站点规则」—— 只为把 `supportedPlatforms` 和 `siteRules` 的 id 契约
    /// 钉进 selftest 而公开(`siteRules` 本身是私有的,规则实现不该外泄)。
    ///
    /// 两边对不上**不会编译报错**,只表现成用户看得见的断层:设置页把那个平台的卡片摆
    /// 出来、配对也配得上,而 `probeOnce` 找不到对应规则、永远不探测 —— "配好了却永远不
    /// 同步",正是这套东西最难被发现的那种坏法。
    public static var platformIDsWithSiteRules: Set<String> { Set(siteRules.map(\.platformID)) }

    // MARK: - 缓存 + 换歌作废

    private struct CachedResult {
        let key: String
        let seconds: Double
        let capturedAt: Date
        /// true = `seconds` 是 `currentTime`、`capturedAt` 是 JS 读它那一刻;false = 整秒文字、osascript 返回那一刻。
        let isPrecise: Bool
    }

    /// 交给伺服的一次性纠偏。`isPrecise` 决定下游按哪种精度用它(门槛、要不要折进偏置)。
    public struct Correction: Equatable, Sendable {
        public let seconds: Double
        public let isPrecise: Bool
        public init(seconds: Double, isPrecise: Bool) {
            self.seconds = seconds
            self.isPrecise = isPrecise
        }
    }

    private let lock = NSLock()
    private var cached: CachedResult?
    private var inFlightKey: String?
    private var consumedKey: String?
    /// 上一次交出去的是不是精确读数。恢复后只有它值得再探一次:整秒读数 ±0.5s,比恢复锚点本身还粗。
    private var consumedWasPrecise = false
    private var generation = 0
    // 有界重试的记账(见 maxProbeAttempts):按曲目 key 计次,换歌清零。
    private var attemptKey: String?
    private var attemptCount = 0
    private var lastAttemptEndedAt: Date?
    /// 最近一次拖动进度的时刻(见 `discardReadings(before:)`)。这之前发起的探测回来也不采信。
    private var seekBarrier: Date?
    private var platformBrowserPairsStorage: [String: Set<String>] = [:]
    /// 最近一次**探测成功**是在哪个浏览器上、命中了哪个平台的站点规则。
    /// 这是"这个浏览器此刻在放哪个网页音乐平台"最硬的证据 —— 它意味着我们刚从那个站点
    /// 自己的 DOM 里读到了一个**在走**的进度。给来源角标用,见 `playingPlatformID`。
    private var lastMatch: (bundleID: String, platformID: String, at: Date)?
    /// 页面顺带交出的封面地址的去向(见 spotifyWebScript 头注)。由 LocalPlaybackSource 启动时挂上;
    /// 没挂就丢掉。同一把锁下读写。
    private var artworkSink: (@Sendable (_ key: String, _ url: URL) -> Void)?

    public func setArtworkSink(_ sink: @escaping @Sendable (_ key: String, _ url: URL) -> Void) {
        lock.lock()
        artworkSink = sink
        lock.unlock()
    }

    /// YouTube Music 网页版页面上的专辑图的去向(见 youtubeMusicScript 第三段)。跟 Spotify 网页版那条分开:那张接的是原生
    /// 客户端同一条下游(原图档替代),这张只给 App 外面用。同 artworkSink:LocalPlaybackSource 启动时挂上,同一把锁下读写。
    private var pageArtworkSink: (@Sendable (_ key: String, _ url: URL) -> Void)?

    public func setPageArtworkSink(_ sink: @escaping @Sendable (_ key: String, _ url: URL) -> Void) {
        lock.lock()
        pageArtworkSink = sink
        lock.unlock()
    }

    /// YouTube Music 网页版放的是视频、页面上没有专辑图时,这支视频的截图(`Reading.videoFrameURL`)的去向,只给 Discord 状态
    /// 兜底。同 pageArtworkSink:LocalPlaybackSource 启动时挂上,同一把锁下读写。
    private var pageVideoFrameSink: (@Sendable (_ key: String, _ url: URL) -> Void)?

    public func setPageVideoFrameSink(_ sink: @escaping @Sendable (_ key: String, _ url: URL) -> Void) {
        lock.lock()
        pageVideoFrameSink = sink
        lock.unlock()
    }

    /// 页面顺带交出的视频身份的去向(见 youtubeMusicScript 第五段)。同 artworkSink:由 LocalPlaybackSource
    /// 启动时挂上,没挂就丢掉,同一把锁下读写。
    private var videoSink: (@Sendable (_ key: String, _ video: VideoIdentity) -> Void)?

    public func setVideoSink(_ sink: @escaping @Sendable (_ key: String, _ video: VideoIdentity) -> Void) {
        lock.lock()
        videoSink = sink
        lock.unlock()
    }

    /// 平台 id → 用户已配对(主动选过、允许对它探测)的浏览器 bundle id 集合。UI 层直接
    /// 写这个属性来更新配对(见类头注"平台与浏览器配对即开关"),读写都过 `lock`——写者是
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

    /// 这个(已解析代理进程之后的)bundle id 有没有被用户配对给指定平台——给
    /// `LocalPlaybackSource` 判断"网页版 Spotify 广告"用:调用方需要传已经过
    /// `probeTargetBundleID` 解析的 host bundle id,跟 `kickIfNeeded`/`pairedPlatformIDs`
    /// 是同一份配对数据、同一把锁,不是另起一份判断逻辑。
    /// 配对关系写进 features.json 的样子(给引擎看,见 FeatureFlagsFile.browserPlatformPairs):没有浏览器的平台
    /// 不写、浏览器按字母排,同一份配对每次编码都一样,没变就不会白写一次盘。纯函数,selftest 覆盖。
    public static func mirroredPairs(_ pairs: [String: Set<String>]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (platformID, bundleIDs) in pairs where !platformID.isEmpty {
            let list = bundleIDs.filter { !$0.isEmpty }.sorted()
            if !list.isEmpty { out[platformID] = list }
        }
        return out
    }

    public func isPaired(bundleID: String?, platformID: String) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return pairedPlatformIDs(forBundleID: bundleID).contains(platformID)
    }

    /// 「最近一次探测命中」这条证据的保质期。
    ///
    /// 15 分钟是按**证据什么时候会过期**取的,不是拍的:探测在每次换歌时都会重新发起
    /// (`kickIfNeeded` 按曲目 key 记账),所以正常听歌时这条记录每几分钟就刷新一次;
    /// 只有"暂停很久"或"换成了一个没有站点规则的网页音源"才会让它变旧。前者过期后退回
    /// 下面那条配对推断(结论多半还是对的),后者正是该退回浏览器图标的场景。
    public static let matchedPlatformMaxAge: TimeInterval = 15 * 60

    /// 这个浏览器此刻在放哪个网页音乐平台(nil = 不知道 / 不是网页播放器)。给菜单栏面板右上角的来源角标用:
    /// 确实是 YouTube Music / Spotify 就显示平台,其余照旧显示浏览器。
    ///
    /// 调用方传 media-control 报的原始 bundle id 就行,这里自己做代理别名解析(Safari 报 `com.apple.WebKit.GPU`,
    /// 配对表里存的是 `com.apple.Safari`;漏掉这一步就会配对了却永远不同步,而且一条日志都没有)。
    public func playingPlatformID(forBundleID bundleID: String?, now: Date = Date()) -> String? {
        guard let host = Self.probeTargetBundleID(forReported: bundleID), !host.isEmpty else {
            return nil
        }
        lock.lock()
        var recent: String?
        if let lastMatch, lastMatch.bundleID == host {
            let age = now.timeIntervalSince(lastMatch.at)
            if age >= 0, age <= Self.matchedPlatformMaxAge { recent = lastMatch.platformID }
        }
        var paired: Set<String> = []
        for (platformID, bundleIDs) in platformBrowserPairsStorage where bundleIDs.contains(host) {
            paired.insert(platformID)
        }
        lock.unlock()
        return Self.resolvePlayingPlatformID(pairedPlatformIDs: paired, recentMatch: recent)
    }

    /// 上面那条的判据本体(纯函数,selftest 覆盖)。
    ///
    /// **证据优先,推断兜底**,两档:
    ///
    /// 1. **最近一次探测真的命中过某个平台** → 就是它。这是硬证据:探测成功意味着我们在
    ///    那个站点的页面里读到了一个**在走**的进度条。一个浏览器同时配对了两个平台时
    ///    (这台机器上 Safari / Arc 就是),只有这一档答得上来。暂停着的歌进度探测不跑,
    ///    这条证据由 `identifyIfNeeded` 按页面报的标题补上。
    /// 2. **只配对了一个平台** → 就当是它。这一档是**推断不是证据**,可能错:浏览器里放
    ///    别的、恰好也带齐 artist+album 的网页音源(播客站之类)时,角标会显示成那个平台。
    ///    代价是纯观感的 —— 角标点下去仍然是 `openResolvedPlayerApp()` 按 bundle id 唤浏览器,
    ///    行为一个字不变。收益是这一档覆盖了绝大多数人的实际配置(一个浏览器只配一个平台),
    ///    而且**不用等探测成功**就能显示对。同款推断在 `LocalPlaybackSource` 判"网页版
    ///    Spotify 广告"时已经用了(`isPaired(...platformID: "spotifyWeb")`),不是新开的口子。
    ///
    /// 第 1 档要求命中的平台**仍然在配对表里**:用户后来取消配对了,那条旧证据就不该
    /// 再作数(否则取消配对之后角标还挂着那个平台,而探测早就不跑了、永远刷新不掉)。
    public static func resolvePlayingPlatformID(
        pairedPlatformIDs: Set<String>, recentMatch: String?
    ) -> String? {
        if let recentMatch, pairedPlatformIDs.contains(recentMatch) { return recentMatch }
        return pairedPlatformIDs.count == 1 ? pairedPlatformIDs.first : nil
    }

    // MARK: - 暂停时认平台

    /// 「认平台」按曲目 key 记账:每首歌最多问一次,问没问到都算。和 `lastMatch` 同一把锁。
    private var identifyKey: String?

    /// 暂停着的浏览器播放:认出是哪个网页平台在放这首歌,补上 `lastMatch`。
    ///
    /// 进度探测只在**播放中**跑,而且只认**在走**的进度条(暂停的标签页直接跳过),所以一首
    /// 一直停着的歌留不下任何证据;App 重启又会清掉内存里那条旧证据。浏览器同时配对了两个
    /// 平台时 `resolvePlayingPlatformID` 只能靠那条证据,于是 Safari 里 YouTube Music 暂停着,
    /// 面板角标却画成 Safari。
    ///
    /// 判据是页面的 `navigator.mediaSession.metadata.title`:系统「正在播放」的标题本来就是
    /// 页面经它报上来的,暂停时也还在。两个平台的标签页各自停着一首歌是常态(实测 Safari:
    /// YouTube Music 停在当前这首,Spotify 网页版停在另一首),所以不看「有没有这个站的标签页」,
    /// 看哪一边报的标题**就是当前这首**,规则见 `platformMatchingTitle`。
    ///
    /// 只在真有歧义时才发起:配对了两个及以上平台、又没有未过期的证据。每首歌一次、失败不重试 ——
    /// 认不出来的代价只是角标画浏览器图标,不值得反复 tell。
    public func identifyIfNeeded(bundleIdentifier: String?, key: String, title: String) {
        guard !title.isEmpty,
              let host = Self.probeTargetBundleID(forReported: bundleIdentifier),
              let family = BrowserAutomationPermission.family(forBundleID: host)
        else { return }
        let platformIDs = pairedPlatformIDs(forBundleID: host)
        guard platformIDs.count >= 2 else { return }
        let startedAt = Date()
        lock.lock()
        if let lastMatch, lastMatch.bundleID == host,
           startedAt.timeIntervalSince(lastMatch.at) <= Self.matchedPlatformMaxAge {
            lock.unlock()
            return
        }
        guard identifyKey != key else { lock.unlock(); return }
        identifyKey = key
        lock.unlock()

        let rules = Self.siteRules.filter { platformIDs.contains($0.platformID) }
        Task.detached(priority: .utility) {
            let script = Self.buildIdentifyScript(bundleID: host, family: family, rules: rules)
            guard let tempURL = Self.writeTempScript(script) else { return }
            defer { try? FileManager.default.removeItem(at: tempURL) }
            guard let result = ProcessRunner.run("/usr/bin/osascript", [tempURL.path], timeout: Self.probeTimeout),
                  result.succeeded
            else {
                Self.logger.notice("identify: could not read page titles from \(host, privacy: .public)")
                return
            }
            let pages = Self.parseIdentifyOutput(result.stdoutText)
            guard let platformID = Self.platformMatchingTitle(title, pages: pages) else {
                Self.logger.notice("identify: no single platform reports the current title (\(pages.count, privacy: .public) tabs)")
                return
            }
            self.recordIdentified(platformID: platformID, bundleID: host, key: key, startedAt: startedAt)
        }
    }

    /// 锁不能在 `Task.detached` 闭包里直接拿(同 `applyProbeResult` 头注)。换了歌(`identifyKey`
    /// 已经是别的)或者这期间进度探测留下了更新的证据,这份结果就不写。
    private func recordIdentified(platformID: String, bundleID: String, key: String, startedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard identifyKey == key else { return }
        if let lastMatch, lastMatch.bundleID == bundleID, lastMatch.at >= startedAt { return }
        lastMatch = (bundleID: bundleID, platformID: platformID, at: Date())
        Self.logger.notice("identify: paused page on \(platformID, privacy: .public) reports the current title")
    }

    /// 一枚标签页报上来的 mediaSession 标题。
    public struct PageTitle: Equatable, Sendable {
        public let platformID: String
        public let title: String
        public init(platformID: String, title: String) {
            self.platformID = platformID
            self.title = title
        }
    }

    /// 哪个平台的标签页报的标题就是当前这首。恰好一个平台对得上才算;两边都对得上(同一首歌两边
    /// 都开着)或都对不上,不下结论。比较前去掉首尾空白和反斜杠(`execute javascript` 会把返回值里的
    /// 引号转义成真的 `\"`,见 `youtubeMusicScript` 头注),大小写不敏感,其余逐字相等 —— 这里要的是
    /// 「就是这首」,不做模糊匹配。
    public static func platformMatchingTitle(_ title: String, pages: [PageTitle]) -> String? {
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
                .lowercased()
        }
        let want = norm(title)
        guard !want.isEmpty else { return nil }
        let hits = Set(pages.filter { norm($0.title) == want }.map(\.platformID))
        return hits.count == 1 ? hits.first : nil
    }

    /// 解析 `buildIdentifyScript` 的输出:一行一枚标签页,`<platformID>:<title>`。标题为空的行
    /// (页面没设 mediaSession)丢掉。
    public static func parseIdentifyOutput(_ raw: String) -> [PageTitle] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty,
                  !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return PageTitle(platformID: String(parts[0]), title: String(parts[1]))
        }
    }

    /// 读 mediaSession 标题的 JS。只用单引号(理由同 `SiteRule` 头注);标题里的换行换成空格,
    /// 免得一枚标签页在输出里占两行。
    private static let mediaSessionTitleScript = "(function(){var m=navigator.mediaSession&&navigator.mediaSession.metadata;var t=m&&m.title?m.title:'';return t.split(String.fromCharCode(10)).join(' ').split(String.fromCharCode(13)).join(' ');})()"

    /// 扫一遍所有窗口的所有标签页,URL 对得上某条规则的就读一次标题,每枚一行输出。只读属性、
    /// 不动播放;休眠标签页靠逐事件 `with timeout` 踢掉(同 `buildAppleScript`)。
    private static func buildIdentifyScript(
        bundleID: String, family: BrowserAutomationPermission.Family, rules: [SiteRule]
    ) -> String {
        let execute: String
        switch family {
        case .chromium: execute = "execute (tab ti of window wi) javascript \"\(mediaSessionTitleScript)\""
        case .safari:   execute = "do JavaScript \"\(mediaSessionTitleScript)\" in tab ti of window wi"
        }
        let checks = rules.map { rule in
            """
                            if u contains "\(rule.urlContains)" then
                                with timeout of \(probeEventTimeoutSeconds) seconds
                                    set r to \(execute)
                                end timeout
                                set out to out & "\(rule.platformID):" & r & linefeed
                            end if
            """
        }.joined(separator: "\n")
        return """
        tell application id "\(bundleID)"
            set out to ""
            repeat with wi from 1 to count of windows
                set tabCount to 0
                try
                    set tabCount to count of tabs of window wi
                end try
                repeat with ti from 1 to tabCount
                    try
                        set u to URL of tab ti of window wi
        \(checks)
                    end try
                end repeat
            end repeat
            return out
        end tell
        """
    }

    /// 用户拖了进度条:丢掉拖动之前抓到的读数,在飞的那次回来也不采信(见 seekBarrier)。缓存的读数最长认 6 秒、按
    /// `rate × age` 往前外推 —— 不丢的话,拖动后 1.2 秒的保护窗口一过就会被消费,位置被拽回拖动之前。
    public func discardReadings(before moment: Date) {
        lock.lock()
        defer { lock.unlock() }
        seekBarrier = moment
        if let snapshot = cached, snapshot.capturedAt < moment { cached = nil }
    }

    /// 取这首歌唯一一次的地面真值种子,外推到 `now` 这一刻(探针本身有约一次探测往返的固有滞后,靠 `rate * age` 补上)。
    /// 命中(非 nil)后立即标记这个 key 为已消费:同一首歌之后再调用一律返回 nil,换下一首歌(`trackChanged()`)才会重新开放。
    /// 一次性的理由见类头注「一次性纠偏,不持续覆盖」。
    ///
    /// 返回 nil 的情况:这首歌已经消费过一次 / 还没探测成功过 / 缓存的曲目跟当前曲目对不上(换歌了)/ 缓存已经超过 `maxAge`
    /// 太旧,都原样退回既有的 `resolvePositionSeconds` 逻辑(喂 `snapshot.elapsedTime`)。
    public func consumeCorrection(forKey key: String, rate: Double, now: Date, maxAge: TimeInterval = 6) -> Correction? {
        lock.lock()
        defer { lock.unlock() }
        guard consumedKey != key else { return nil }
        guard let snapshot = cached, snapshot.key == key else { return nil }
        let age = now.timeIntervalSince(snapshot.capturedAt)
        guard age >= 0, age <= maxAge else { return nil }
        consumedKey = key
        consumedWasPrecise = snapshot.isPrecise
        let corrected = snapshot.seconds + (snapshot.isPrecise ? 0 : Self.flooredMidpointBiasSecs) + rate * age
        // **这一行跟 `probeAdvancing` 里那句"采信"不是一回事,两行都要有**(
        // 复量时暴露的日志盲区):"采信"打在**探针内部**(拿到一个可信读数、写进缓存),
        // 而这里才是**真的交给伺服逻辑用了**。同一首歌可能出现好几行"采信"却只有一行
        // "交出" —— 一次性额度(`consumedKey`)把后面几次挡在门外。只看"采信"会读成
        // "重锚了好几次",看不出这一拍的位置到底是探针给的还是外推的。
        Self.logger.notice("probe: handing off correction \(corrected, privacy: .public)s (reading \(snapshot.seconds, privacy: .public)s\(snapshot.isPrecise ? " precise" : " + midpoint", privacy: .public) + \(age, privacy: .public)s lag), per-track budget exhausted")
        return Correction(seconds: corrected, isPrecise: snapshot.isPrecise)
    }

    /// 换歌时清掉缓存——上一首歌的探测结果绝不能被当成这一首歌的位置用,也重新开放
    /// 这首新歌的一次性消费额度。也会让"正在飞的探测"的结果作废(generation 递增),
    /// 防止一份晚到的旧曲目探测结果污染新曲目。
    /// `from`/`to` 只用于日志:`from` 为空说明**不是真换歌**,是快照变
    /// nil(播放器退出 / stopped / 系统 Now Playing 焦点被抢)把 `lastKey` 清成了 "" 之后
    /// 重新接上 —— 这两种情况在旧日志里长得一模一样,而它们该不该算 bug 完全不同。
    public func trackChanged(from previousKey: String = "-", to newKey: String = "-") {
        lock.lock()
        cached = nil
        inFlightKey = nil
        consumedKey = nil
        generation += 1
        // 重试预算也跟着换歌重置 —— 上一首用完三次,不能让这一首一次都探不了。
        attemptKey = nil
        attemptCount = 0
        lastAttemptEndedAt = nil
        lock.unlock()
        // 这一行是"同一首歌为什么又探了一次"的唯一线索。调用方是
        // `LocalPlaybackSource` 的 `if trackChanged`(`key != lastKey`),而 `lastKey`
        // **不只在真换歌时变** —— 快照变成 nil(播放器退出/stopped/系统 Now Playing 焦点
        // 被别的 App 抢走一次)那条路径会把它清成 "",下一拍就重新算一次"换歌"。所以
        // 一首歌中途出现多轮探测**不一定是 bug**,但必须能从日志里看出是哪一种。
        Self.logger.notice("probe: track key changed, reopening per-track probe budget (old=\(previousKey, privacy: .public) new=\(newKey, privacy: .public))")
    }

    /// 整秒读数能不能拿来纠这个浏览器报的位置。Safari 的媒体进程不能:它的 media-control 锚点逐首、逐次状态变化
    /// 都按页面自己的钟重发(与 YouTube Music 的 `currentTime` 逐拍差 0.001s),而页面文字在后台标签页里两秒才刷一次、
    /// 比真实位置晚 2~3s,整秒读数只会把准的位置拉偏。精确读数不受这条限制。纯函数,selftest 直接覆盖。
    public static func floorReadingApplies(reportedBundleID: String?) -> Bool {
        reportedBundleID != MediaControlClient.safariMediaProcessBundleID
    }

    /// 同一首歌从暂停恢复:再开放一次探测额度。恢复锚点是按"按下播放"那一刻打的,出声要是卡了一下,
    /// 页面的钟就比锚点晚这一截、而播放器要到下一次状态变化才重发(数据见 02 章「Safari 上的 YouTube Music」)。只重开这首已经消费过、而且交出的是精确读数的 key;正在飞的那次照常落地。
    public func reopenAfterResume(key: String) {
        lock.lock()
        guard consumedKey == key, consumedWasPrecise else { lock.unlock(); return }
        consumedKey = nil
        cached = nil
        attemptKey = nil
        attemptCount = 0
        lastAttemptEndedAt = nil
        lock.unlock()
        Self.logger.notice("probe: resumed, reopening per-track probe budget (key=\(key, privacy: .public))")
    }

    /// 这首歌(`key`)发起过几次探测,换歌清零。发起那一刻同步计数,不等探测跑完。
    public func probeAttempts(forKey key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptKey == key ? attemptCount : 0
    }

    /// 如果这个 bundle id 受支持、这首歌还没消费过一次探测结果、且当前没有正在飞的同
    /// 曲目探测,踢一次新的——异步、**不阻塞调用方**,结果就绪时写回 `cached` 供
    /// `consumeCorrection` 用。这首歌一旦被消费过一次就不再重新探测(见类头注),避免
    /// 稳态播放期间持续拿整秒精度的读数去覆盖本来更准的连续外推,也省下持续的 AppleEvent
    /// 往返开销。不等这次探测的结果,是刻意的:调用方(轮询循环)本身就是同步、高频跑的,
    /// 不能被一次上百毫秒的 AppleScript 往返卡住。
    public func kickIfNeeded(bundleIdentifier: String?, key: String, expectedDuration: Double) {
        // 先把「媒体代理进程」解析成宿主 App:Safari 播网页音频时 MediaRemote 报的是 `com.apple.WebKit.GPU`(解码跑在独立的
        // WebKit GPU 进程里,见 `TrustedPlayers.mediaProxyOwners`),而配对表里存的、AppleScript 要 tell 的都是 `com.apple.Safari`。
        // 不解析的话 `family(...)` 返回 nil、探测一次都不会发起,表现是"配对了 Safari、卡片也在、却永远不同步",而且不报任何错。
        // `family(...)`、`pairedPlatformIDs(...)` 和下面 `probeOnce` 的 `tell application id` 都要用宿主;准入那一侧
        // (`TrustedPlayers.isAccepted`)做同样的解析。
        guard let hostBundleID = Self.probeTargetBundleID(forReported: bundleIdentifier),
              let family = BrowserAutomationPermission.family(forBundleID: hostBundleID)
        else { return }
        // 没配对过任何平台——完全不发起探测(见类头注"配对即开关")。放在锁外面查是故意的:
        // `pairedPlatformIDs` 自己会拿锁,这里不需要跟下面 inFlightKey 的检查合并成一次
        // 加锁,提前 return 的路径越简单越好读。
        let platformIDs = pairedPlatformIDs(forBundleID: hostBundleID)
        guard !platformIDs.isEmpty else { return }
        lock.lock()
        guard inFlightKey != key, consumedKey != key else { lock.unlock(); return }
        // 有界重试(见 `maxProbeAttempts`):探测失败**不消费**那次一次性额度,
        // 所以重试是自动发生的 —— 这里只给它一个上界和退避,别让一个读不到的标签页被整首歌
        // 每一轮都 tell 一遍。
        if attemptKey != key {
            attemptKey = key
            attemptCount = 0
            lastAttemptEndedAt = nil
        }
        guard attemptCount < Self.maxProbeAttempts else { lock.unlock(); return }
        if let last = lastAttemptEndedAt,
           Date().timeIntervalSince(last) < Self.probeRetryBackoffSecs {
            lock.unlock()
            return
        }
        attemptCount += 1
        let attemptNumber = attemptCount
        inFlightKey = key
        let myGeneration = generation
        let startedAt = Date()
        lock.unlock()

        Task.detached(priority: .utility) {
            let (hit, miss) = await Self.probeAdvancing(
                bundleID: hostBundleID, family: family, platformIDs: platformIDs,
                expectedDuration: expectedDuration, attempt: attemptNumber)
            if let miss { self.noteMissOnce(key: key, miss) }
            self.applyProbeResult(hit, key: key, generation: myGeneration,
                                  bundleID: hostBundleID, startedAt: startedAt)
        }
    }

    /// `lock`/`unlock` 直接写在 `Task.detached` 闭包体里,在 Swift 6 语言模式下是编译
    /// 错误(NSLock 的那两个方法不认为自己能安全地跨越 async 挂起点被调用)——拆成这个
    /// 普通同步函数,闭包里只是"调用"它,不在 async 上下文里直接摆弄锁,绕开这条限制。
    private func applyProbeResult(_ hit: ProbeHit?, key: String, generation myGeneration: Int,
                                  bundleID: String, startedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard myGeneration == generation else { return } // 换歌了,这份结果作废
        // 退避从"上一次探测**结束**"算起,而不是从发起算起 —— 一次探测本身现在要花
        // 两次 osascript 往返 + `livenessGapSeconds`,按发起算等于没有退避。记在代次校验之后:上一首晚到的结果
        // 不该给新歌的第一次探测加上退避(换歌后头一次纠偏正是最要紧的那次)。
        lastAttemptEndedAt = Date()
        if inFlightKey == key { inFlightKey = nil }
        guard let hit else { return }
        // 拖动之前发起的探测:读的是拖动之前的位置,采信了会把屏上位置拽回去。
        if let barrier = seekBarrier, startedAt < barrier { return }
        // 精确读数的年龄从 JS 读数那一刻算;读数时刻晚于现在(两边钟不可能差这么多,多半是解析出了岔子)就不用它。
        if let precise = hit.precise, precise.readAt <= Date() {
            cached = CachedResult(key: key, seconds: precise.seconds, capturedAt: precise.readAt, isPrecise: true)
        } else {
            cached = CachedResult(key: key, seconds: hit.seconds, capturedAt: Date(), isPrecise: false)
        }
        // 这一条**故意不受 generation 之外的任何作废影响**、也不按曲目 key 存:它回答的
        // 是"这个浏览器在放哪个平台",那件事跨曲目稳定,而位置纠偏是一首歌一次性的。
        // 存在同一个 lock 下,读在 `playingPlatformID`。
        lastMatch = (bundleID: bundleID, platformID: hit.platformID, at: Date())
        // 封面地址只在这次读数被采信(同一首、页面的钟在走)时交出去 —— 跟位置那份读数同一道可信度门。
        // sink 自己只是派一个 Task,不阻塞,在锁下调无妨。
        if let art = hit.artworkURL {
            if hit.platformID == "youtubeMusic" { pageArtworkSink?(key, art) } else { artworkSink?(key, art) }
        } else if hit.platformID == "youtubeMusic", let frame = hit.videoFrameURL {
            pageVideoFrameSink?(key, frame)
        }
        if let video = hit.video { videoSink?(key, video) }
    }

    // MARK: - 探测实现(全程跑在后台线程,调用方必须走 Task.detached)

    /// 只试用户为这个浏览器配对过的平台对应的站点规则——哪怕另一个平台的站点规则也能
    /// 匹配上当前打开的标签页,没配对过就不试,尊重用户的显式选择(见类头注)。
    /// 「这个浏览器现在到底能不能被驱动」的**功能性**自检。
    ///
    /// 存在的理由:Chromium 系那道 JS 开关的状态**读不出来** —— 它存在浏览器 profile 的
    /// `Preferences` 里,而别的 App 读那个目录要「完全磁盘访问权限」,这个 App 没有。于是
    /// 用户按指引手动开完之后,界面上永远显示「无法确认状态」,他没法确认自己做对没有
    /// (「我现在已经手动去打开了,这个页面怎么回显?」)。
    ///
    /// 这里换一条不依赖那个权限的判据:**直接试着执行一小段 JavaScript**。成不成功就是
    /// 用户真正关心的那件事本身,比读配置文件更贴近事实 —— 配置文件写着"开"但浏览器没重启
    /// 时其实还没生效,而这个自检会如实失败。
    ///
    /// 需要的前提只有两个,而且都是用户已经在这张气泡里看得见的:①系统自动化(TCC)授权;
    /// ②那个浏览器开着、至少有一个标签页。
    public enum SelfTestResult: Equatable {
        case ok
        /// 浏览器没在跑,或者一个窗口/标签页都没有 —— 没法试,不代表开关没开。
        case noTab
        /// 浏览器明确回绝了:那道 JS 开关还关着。Chromium 系会在错误里带上自己那句提示。
        case blocked
        /// 命令发到了、浏览器收下了,但**一直不回**(AppleEvent 超时 -1712)。
        /// 跟 `blocked` 分开,是因为它是另一种失败方式而不是同一件事的另一种说法:
        /// Chrome 那道开关关着时会**立刻**抛一句清清楚楚的错误(→ `blocked`),而 Arc
        /// 关着时**什么都不说、直接不回**(→ 这里)。当前标签页本身卡死(页面在跑死循环)
        /// 也会落进来,所以文案上只说"多半是开关没勾",不把它当成板上钉钉的结论。
        case noReply
        /// 其它失败(超时、TCC 没授权、语法错误…)。带上原始输出供 UI 显示。
        case failed(String)
    }

    /// 同步执行、会起一个 osascript 子进程,**别在主线程调**。
    public static func selfTest(bundleID: String, family: BrowserAutomationPermission.Family) -> SelfTestResult {
        guard BrowserAutomationPermission.isRunning(bundleID: bundleID) else { return .noTab }
        // 最小可行脚本:在第一个窗口**此刻显示着的那个标签页**里算 1+1。刻意不带任何 URL
        // 过滤 —— 自检要回答的是"驱不驱得动",跟用户此刻开着什么页面无关。
        //
        // 取的是 `active tab` 而**不是** `tab 1`(理由见 `activeTabExpression` 头注):
        // Arc 把非当前标签页休眠掉,对休眠标签页执行 JavaScript 会**一直不返回**,于是一切
        // 正常的 Arc 也会被这个自检判成失败。当前标签页是唯一能保证是活的那个。
        let tab = activeTabExpression(family: family, windowIndex: "1")
        let executeLine: String
        switch family {
        case .chromium: executeLine = "execute (\(tab)) javascript \"1+1\""
        case .safari:   executeLine = "do JavaScript \"1+1\" in \(tab)"
        }
        // 错误必须在 AppleScript 里用 `on error` 捞回 **stdout** —— `ProcessRunner.Result`
        // 不收 stderr,而浏览器回绝时那句关键提示正是走 stderr 的。捞回来才判得出"开关关着"
        // 和"别的失败"的区别。顺带把错误**号**也捞回来:-1712(AppleEvent 超时)要跟别的
        // 错误分开报,它的文案是本地化的、认不得,号是稳定的。
        //
        // `with timeout` 不能省:没有它时"浏览器不回"表现为 osascript 挂死到被
        // `ProcessRunner` 硬杀,stdout 空空如也,最后 UI 上显示成一句什么都没说的
        // 「检测没通过:no output」—— 用户看见的就是那句。
        let source = """
        tell application id "\(bundleID)"
            if (count of windows) is 0 then return "NOWINDOW"
            if (count of tabs of window 1) is 0 then return "NOWINDOW"
            try
                with timeout of \(selfTestEventTimeoutSeconds) seconds
                    return "OK:" & ((\(executeLine)) as text)
                end timeout
            on error errMsg number errNum
                return "ERR:" & errNum & ":" & errMsg
            end try
        end tell
        """
        guard let tempURL = writeTempScript(source) else { return .failed("cannot write script") }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let result = ProcessRunner.run("/usr/bin/osascript", [tempURL.path], timeout: probeTimeout) else {
            // 这条**不是超时** —— `ProcessRunner.run` 只在"子进程根本没起来"时返回 nil,
            // 超时走的是 `result.timedOut`。
            return .failed("osascript didn't start")
        }
        // AppleEvent 超时兜不住时(osascript 自己卡在别的地方)的最后一道:进程被硬杀,
        // stdout 是空的 —— 那也是"一直不回",别再让它掉进 "no output"。
        if result.timedOut { return .noReply }
        var out = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("\""), out.hasSuffix("\""), out.count >= 2 { out.removeFirst(); out.removeLast() }
        if out == "NOWINDOW" { return .noTab }
        if out.hasPrefix("OK:") { return .ok }
        guard out.hasPrefix("ERR:") else {
            return .failed(out.isEmpty ? "osascript exit \(result.status), no output" : out)
        }
        // "ERR:<号>:<文案>" —— 文案里可能还有冒号,所以只切第一个。
        let body = String(out.dropFirst(4))
        let pieces = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let errNumber = pieces.count == 2 ? Int(pieces[0].trimmingCharacters(in: .whitespaces)) : nil
        let err = pieces.count == 2 ? String(pieces[1]) : body
        if errNumber == -1712 { return .noReply }
        // 判据一(最硬,**完全不看文案**):那道开关我们自己读得到、而且读到的是关着的。
        // Safari 走 `CFPreferences`,一定读得到;Chromium 系在 Preferences 文件读得到时
        // 也算数(读不到是 `.unknown`,落不进这里)。既然命令确实发到了浏览器手上、它报了错,
        // 而开关又确实关着,那就是"被那道开关挡住"没跑了,不需要去猜那句本地化文案。
        if BrowserAutomationPermission.status(forBundleID: bundleID) == .disabled { return .blocked }
        // 判据二:读不到开关状态时(Chromium 系没有完全磁盘访问权限的常态)只能认文案,
        // 而且 **认关键词不认整句** —— 那句提示是本地化过的,各语言都不一样。逐条实测出处:
        //   - Chrome/Edge(取自自己的 locale.pak):英文 "Executing JavaScript through
        //     AppleScript is turned off…",中文「通过 AppleScript 执行 JavaScript 的功能已关闭…」
        //     → 稳定锚点是 "AppleScript" + ("turned off" / 「已关闭」)。
        //   - Safari(在这台机器上实测原样抄回来的):"You must enable 'Allow
        //     JavaScript from Apple Events' in the Developer section of Safari Settings to use
        //     'do JavaScript'."(错误号 8)—— 注意它说的是 **Apple Events** 而不是 AppleScript,
        //     上面那组锚点一个都对不上,所以必须单列一条。那句话本身在 dyld 共享缓存里,
        //     抠不出各语言原文,只能认 "apple event" 这个跨语言都会出现的产品名。
        //     实践中 Safari 走判据一就拦下了,这条只是保险。
        let lower = err.lowercased()
        if lower.contains("applescript"),
           lower.contains("turned off") || err.contains("已关闭") || lower.contains("disabled") {
            return .blocked
        }
        if lower.contains("apple event"), lower.contains("javascript") {
            return .blocked
        }
        return .failed(err)
    }

    /// 两次采样,中间隔 `livenessGapSeconds`,要求页面进度**真的在走**才采信
    /// (判据见 `pageClockIsRunning`)。返回**第二个**样本 —— 它更新,而 `applyProbeResult`
    /// 记的 `capturedAt` 也是这一刻,`consumeCorrection` 的 `rate * age` 补偿才对得上。
    ///
    /// 两次采样必须是**两次独立的 osascript 运行**,不能在 AppleScript 里 `delay`:
    /// `probeTimeout` 是 3 秒硬超时,脚本里睡 1.5 秒会把预算吃掉一半、后面真正在播的标签页
    /// 又轮不到(跟 `activeTabExpression` 头注里休眠标签页吃预算是同一类账)。这里跑在
    /// `Task.detached` 的后台任务里,两次之间 `Task.sleep` 不占线程,是免费的。
    ///
    /// `flooredMidpointBiasSecs` 的 +0.5 由 `consumeCorrection` 统一补,**这里一次都不补**
    /// —— 它补的是"页面显示 floor"这个系统性偏置,跟采样几次无关,补两次就偏了半秒。
    /// 一次成功探测的产物:读到的秒数 + **是哪个平台的站点规则读到的**。
    /// 后者加,给来源角标用(见 `playingPlatformID`);位置那条链路只用前者。
    private struct ProbeHit {
        let seconds: Double
        let platformID: String
        /// 页面顺带交出的封面地址(Spotify 网页版、YouTube Music 网页版的规则给,见两份脚本头注)。
        let artworkURL: URL?
        let precise: PreciseReading?
        let video: VideoIdentity?
        /// 没有封面地址、放的是视频时这支视频的截图(见 `Reading.videoFrameURL`)。
        let videoFrameURL: URL?
    }

    /// 探测最常见的两种落空(一个标签页都没读到 / 第二拍没读到)。按曲目各记一次,见 `noteMissOnce`。
    private enum ProbeMiss: Hashable {
        case noTab(expectedDuration: Int)
        case secondSampleEmpty(first: Double)

        var kind: String {
            switch self {
            case .noTab: return "noTab"
            case .secondSampleEmpty: return "secondSampleEmpty"
            }
        }
    }

    /// 按曲目只记一次的落空日志记到了哪首、记过哪几种。和 `lock` 同一把锁。
    private var loggedMissKey: String?
    private var loggedMissKinds: Set<String> = []

    /// `.notice` 才落盘(`.info` 只在内存里);每首歌每种落空只记一次,有界重试的后几次不再刷。
    private func noteMissOnce(key: String, _ miss: ProbeMiss) {
        lock.lock()
        if loggedMissKey != key {
            loggedMissKey = key
            loggedMissKinds = []
        }
        let fresh = loggedMissKinds.insert(miss.kind).inserted
        lock.unlock()
        guard fresh else { return }
        switch miss {
        case .noTab(let expect):
            Self.logger.notice("probe: no tab produced a usable reading (expected duration \(expect, privacy: .public)s, key=\(key, privacy: .public))")
        case .secondSampleEmpty(let first):
            Self.logger.notice("probe: second sample returned nothing, discarding \(first, privacy: .public)s (key=\(key, privacy: .public))")
        }
    }

    private static func probeAdvancing(
        bundleID: String, family: BrowserAutomationPermission.Family,
        platformIDs: Set<String>, expectedDuration: Double, attempt: Int
    ) async -> (ProbeHit?, ProbeMiss?) {
        let expect = Int(expectedDuration.rounded())
        guard let first = probeOnce(bundleID: bundleID, family: family,
                                    platformIDs: platformIDs, expectedDuration: expectedDuration) else {
            return (nil, .noTab(expectedDuration: expect))
        }
        try? await Task.sleep(nanoseconds: UInt64(livenessGapSeconds * 1_000_000_000))
        guard let second = probeOnce(bundleID: bundleID, family: family,
                                     platformIDs: platformIDs, expectedDuration: expectedDuration) else {
            return (nil, .secondSampleEmpty(first: first.seconds))
        }
        // 两拍必须落在**同一个平台**上。同时开着 YouTube Music 和
        // Spotify 网页版、而两边规则的优先级判定在两拍之间翻了个个儿时,拿 A 站的读数减
        // B 站的读数去判"进度在不在走"是没有意义的 —— 那个差值既可能碰巧为正(误采信一个
        // 属于另一首歌的位置),也可能碰巧为负(白白弃用一次真读数)。不同平台直接弃用。
        guard first.platformID == second.platformID else {
            logger.notice("probe #\(attempt, privacy: .public): samples landed on different platforms (\(first.platformID, privacy: .public) -> \(second.platformID, privacy: .public)), discarding")
            return (nil, nil)
        }
        guard pageClockIsRunning(first: first.seconds, second: second.seconds) else {
            logger.notice("probe #\(attempt, privacy: .public): page position is not advancing (\(first.seconds, privacy: .public)s -> \(second.seconds, privacy: .public)s), discarding")
            return (nil, nil)
        }
        logger.notice("probe #\(attempt, privacy: .public): accepting \(second.seconds, privacy: .public)s (previous \(first.seconds, privacy: .public)s, currentTime \(second.precise?.seconds ?? -1, privacy: .public), expected duration \(expect, privacy: .public)s, platform \(second.platformID, privacy: .public))")
        return (second, nil)
    }

    private static func probeOnce(bundleID: String, family: BrowserAutomationPermission.Family, platformIDs: Set<String>, expectedDuration: Double) -> ProbeHit? {
        for rule in siteRules where platformIDs.contains(rule.platformID) {
            if let reading = probe(bundleID: bundleID, family: family, rule: rule, expectedDuration: expectedDuration) {
                return ProbeHit(seconds: reading.seconds, platformID: rule.platformID,
                                artworkURL: reading.artworkURL, precise: reading.precise, video: reading.video,
                                videoFrameURL: reading.videoFrameURL)
            }
        }
        return nil
    }

    private static func probe(bundleID: String, family: BrowserAutomationPermission.Family, rule: SiteRule, expectedDuration: Double) -> Reading? {
        let appleScript = buildAppleScript(bundleID: bundleID, family: family, urlContains: rule.urlContains, script: rule.script, expectedDuration: expectedDuration)
        guard let tempURL = writeTempScript(appleScript) else { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let result = ProcessRunner.run("/usr/bin/osascript", [tempURL.path], timeout: probeTimeout),
              result.succeeded
        else { return nil }
        return parseReading(fromOsascriptOutput: result.stdoutText)
    }

    /// 一次 AppleScript 里做完"找标签页 + 执行脚本"两件事(不能分两次调用:标签页引用存成变量再传进另一次 `tell` 会报 specifier
    /// 转换错误,`execute`/`do JavaScript` 要的是内联说明符,只有 `tab i of window w` 这种当场求值的写法能用)。遇到第一个"确实在
    /// 播放"(非 `NOTFOUND` 且非暂停)的就直接返回,避免用户同时开着好几个同源标签页(比如两个 YouTube Music 页面)时读错。
    ///
    /// 先扫一遍各窗口的当前标签页,再扫其余标签页。理由见 `activeTabExpression` 头注:Arc 会休眠非当前标签页,对休眠标签页执行
    /// JavaScript 会一直不返回、只能等 `with timeout` 把它踢掉,每踢一个就吃掉一秒预算。开着几十个标签页是常态,其中只要有两三个
    /// 匹配得上 URL 又恰好是休眠的,整次探测的 3 秒就没了。当前标签页是唯一保证活着的,先试它,而正在放歌的那个标签页很多时候就是
    /// 当前标签页。
    ///
    /// 用 `tell application id "<bundleID>"` 而不是写死 App 显示名字符串,不受"App 被改名/装了变体版本(比如 Chrome Canary)"影响。
    ///
    /// Chromium 系和 Safari 的 JS 注入命令不同名:Chromium 系是 `execute (tab) javascript "…"`,Safari 是 `do JavaScript "…" in tab`。
    /// 两边窗口/标签枚举语法(`count of windows`/`tabs of window`/`URL of tab`)一致,只有这一行命令要按 family 分支。
    private static func buildAppleScript(
        bundleID: String, family: BrowserAutomationPermission.Family, urlContains: String,
        script rawScript: String, expectedDuration: Double
    ) -> String {
        // 占位符替换必须发生在**拼进 AppleScript 之前**(见 `SiteRule` 头注)。期望时长
        // 未知(<=0)时传 0 进去,JS 那边看见 0 就整条跳过时长检查 —— 失败方向是"退回没有
        // 这道检查的样子",不是"什么都探不到"。
        let expect = expectedDuration > 0 ? Int(expectedDuration.rounded()) : 0
        let script = rawScript
            .replacingOccurrences(of: "__EXPECT__", with: String(expect))
            .replacingOccurrences(of: "__TOL__", with: String(Int(pageDurationToleranceSecs)))
            .replacingOccurrences(of: "__CT_SLACK__", with: String(currentTimeSlackSecs))
        let activeTab = activeTabExpression(family: family, windowIndex: "wi")
        let executeLine: String
        let executeActiveLine: String
        switch family {
        case .chromium:
            executeLine = "execute (tab ti of window wi) javascript \"\(script)\""
            executeActiveLine = "execute (\(activeTab)) javascript \"\(script)\""
        case .safari:
            executeLine = "do JavaScript \"\(script)\" in tab ti of window wi"
            executeActiveLine = "do JavaScript \"\(script)\" in \(activeTab)"
        }
        return """
        tell application id "\(bundleID)"
            set winCount to count of windows
            repeat with wi from 1 to winCount
                try
                    if (URL of \(activeTab)) contains "\(urlContains)" then
                        with timeout of \(probeEventTimeoutSeconds) seconds
                            set r to \(executeActiveLine)
                        end timeout
                        if r does not contain "NOTFOUND" and r does not contain "|1" then
                            return r
                        end if
                    end if
                end try
            end repeat
            repeat with wi from 1 to winCount
                -- 取 URL / 数标签页也要在 try 里:扫到一半关掉一枚标签页、或者某页 URL 是空值,都会抛错,
                -- 没接住的话整次探测直接失败(BrowserTabProbeScript 那份模板同样这么包)。
                set tabCount to 0
                try
                    set tabCount to count of tabs of window wi
                end try
                repeat with ti from 1 to tabCount
                    try
                        if (URL of tab ti of window wi) contains "\(urlContains)" then
                            with timeout of \(probeEventTimeoutSeconds) seconds
                                set r to \(executeLine)
                            end timeout
                            if r does not contain "NOTFOUND" and r does not contain "|1" then
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

    private static func writeTempScript(_ source: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-browser-probe-\(UUID().uuidString).applescript")
        return FileIO.write(source, to: url) ? url : nil
    }

    /// 「把正在放歌的那枚标签页翻到台前」的 AppleScript。URL 特征与进度探测同一份
    /// (`urlContains`),两遍扫描的顺序也同 `buildAppleScript`:先扫各窗口**当前**标签页
    /// (放歌的那枚多半就是用户正在看的这枚),再扫其余标签页。命中后做三件事:选中那枚
    /// 标签页(Chromium `active tab index` / Safari `current tab`,两个词不同名,同
    /// `buildAppleScript` 那条实测结论)、把它所在窗口的 `index` 提到 1、`activate` 整个
    /// App。只翻页,不动播放状态。一次成功返回 "OK",一枚匹配的标签页都没有返回
    /// "NOTFOUND"(不抛错)。不执行 JavaScript,没有休眠标签页挂起的风险,不需要逐事件
    /// `with timeout`。
    private static func buildRevealScript(
        bundleID: String, family: BrowserAutomationPermission.Family, urlContains: String
    ) -> String {
        let activeTab = activeTabExpression(family: family, windowIndex: "wi")
        let selectTab: String
        switch family {
        // Arc 没有 `active tab index`(整段编译不过),用 select,见 BrowserTabFocus.arcBundleID。
        case .chromium where bundleID == BrowserTabFocus.arcBundleID: selectTab = "select tab ti of window wi"
        case .chromium: selectTab = "set active tab index of window wi to ti"
        case .safari:   selectTab = "set current tab of window wi to tab ti of window wi"
        }
        return """
        tell application id "\(bundleID)"
            repeat with wi from 1 to count of windows
                try
                    if (URL of \(activeTab)) contains "\(urlContains)" then
                        set index of window wi to 1
                        activate
                        return "OK"
                    end if
                end try
            end repeat
            repeat with wi from 1 to count of windows
                set tabCount to 0
                try
                    set tabCount to count of tabs of window wi
                end try
                repeat with ti from 1 to tabCount
                    try
                        if (URL of tab ti of window wi) contains "\(urlContains)" then
                            \(selectTab)
                            set index of window wi to 1
                            activate
                            return "OK"
                        end if
                    end try
                end repeat
            end repeat
            return "NOTFOUND"
        end tell
        """
    }

    /// 点「来源角标」/「在 XX 中显示」时,网页播放器(YouTube Music / Spotify 网页版)的
    /// 跳转落点:把正在放歌的那枚浏览器标签页翻到台前。网页平台的"对应播放器页面"是**一枚
    /// 标签页**而不是整个浏览器 —— 只激活 App 的话,浏览器多半本来就是前台 App(歌就是在它
    /// 里面放的),用户看到的就是"点了没反应"。
    ///
    /// URL 判据与进度探测同一份 `siteRules`;能走到这里的调用方都是角标已经认出平台的情形,
    /// 配对与自动化授权必然已齐(探测已经在跑),不需要新门槛。
    ///
    /// 同步执行、起一个 osascript 子进程,**别在主线程调**(同 `selfTest`)。
    /// - Returns: 翻到了没有。false(没找到标签页 / 脚本失败 / 超时)由调用方兜底 ——
    ///   退回整 App 激活,不比没有这条差。
    ///
    /// `bundleID` 收的是 MediaRemote 上报的原值,这里先折回宿主(`probeTargetBundleID`):
    /// Safari 报的是 `com.apple.WebKit.GPU`,不折回的话 `family` 为 nil、也 tell 不动。
    public static func revealPlayingTab(bundleID: String, platformID: String) -> Bool {
        guard let host = probeTargetBundleID(forReported: bundleID),
              let rule = siteRules.first(where: { $0.platformID == platformID }),
              let family = BrowserAutomationPermission.family(forBundleID: host)
        else { return false }
        let appleScript = buildRevealScript(bundleID: host, family: family, urlContains: rule.urlContains)
        guard let tempURL = writeTempScript(appleScript) else { return false }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let result = ProcessRunner.run("/usr/bin/osascript", [tempURL.path], timeout: probeTimeout),
              result.succeeded
        else { return false }
        let revealed = result.stdoutText.contains("OK")
        logger.notice("reveal tab platform=\(platformID, privacy: .public) bundle=\(host, privacy: .public) ok=\(revealed, privacy: .public)")
        return revealed
    }

    /// osascript 打印一个 AppleScript 字符串结果时会整体加一层引号——脚本约定返回值
    /// 是不含引号的裸文本(见 youtubeMusicScript 头注),所以这里只需要脱掉那层外层引号,
    /// 不需要处理任何内部转义。格式固定是 "<seconds>|<pausedFlag>",pausedFlag 非
    /// "0"(比如脚本失败时的 "NOTFOUND")一律当作解析失败,不猜。
    ///
    /// public 是为了给 lyrimuse-selftest 单测这段纯解析逻辑——真正调 AppleScript 的部分
    /// 依赖真实 Arc + 已打开的网页,没法在 CI/无 GUI 环境里稳定跑,只能靠这段解析逻辑的
    /// 单测兜底覆盖率,真实端到端行为已经在手动验证过。
    public static func parseSeconds(fromOsascriptOutput raw: String) -> Double? {
        parseReading(fromOsascriptOutput: raw)?.seconds
    }

    /// 一次成功读数:秒数 + 页面顺带交出的封面地址(没有就 nil)+ 精确读数(没有就 nil)。
    public struct Reading: Equatable, Sendable {
        public let seconds: Double
        public let artworkURL: URL?
        public let precise: PreciseReading?
        public let video: VideoIdentity?
        /// 没有封面地址(放的是视频,第三段是视频截图)、又认出了视频身份时,这支视频的截图(`KasetPlayerInfo.videoFrameURL`),
        /// 只给 Discord 状态兜底。
        public let videoFrameURL: URL?
        public init(seconds: Double, artworkURL: URL?, precise: PreciseReading? = nil, video: VideoIdentity? = nil,
                    videoFrameURL: URL? = nil) {
            self.seconds = seconds
            self.artworkURL = artworkURL
            self.precise = precise
            self.video = video
            self.videoFrameURL = videoFrameURL
        }
    }

    /// 页面正在放的那支视频(YouTube Music 规则的第五段)。`musicVideoType` 读不到时为 nil。
    public struct VideoIdentity: Equatable, Sendable {
        public let videoID: String
        public let musicVideoType: String?
        public init(videoID: String, musicVideoType: String?) {
            self.videoID = videoID
            self.musicVideoType = musicVideoType
        }
    }

    /// 解析第五段 `#<videoId>,<musicVideoType>`。videoId 必须是 YouTube 的 11 位 ID 形状,否则整段作废。
    public static func parseVideoIdentity(_ raw: Substring) -> VideoIdentity? {
        guard raw.hasPrefix("#") else { return nil }
        let fields = raw.dropFirst().split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let id = fields.first.map(String.init), id.count == 11,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        let type = fields.count == 2 && !fields[1].isEmpty ? String(fields[1]) : nil
        return VideoIdentity(videoID: id, musicVideoType: type)
    }

    /// 页面媒体元素的 `currentTime` 和读它那一刻的墙钟(见 youtubeMusicScript 第四段)。
    public struct PreciseReading: Equatable, Sendable {
        public let seconds: Double
        public let readAt: Date
        public init(seconds: Double, readAt: Date) {
            self.seconds = seconds
            self.readAt = readAt
        }
    }

    /// 解析规则(从 parseSeconds 扩出来):`<seconds>|<pausedFlag>[|<artworkURL>[|@<currentTime>,<epochMs>[|#<videoId>,<type>]]]`。
    /// 第二段非 "0"(暂停 / "NOTFOUND")整条作废、不猜;第三段可选,只认 Spotify 图床形状的地址
    /// (`SpotifyArtworkURL.parse`)和 YouTube Music 曲库的方形专辑图(`KasetPlayerInfo.coverArtworkURL`),别的一律 nil(不是专辑图、
    /// 又认出了第五段的视频身份时,另给这支视频的截图 `videoFrameURL`,只给 Discord 状态兜底);第四段可选,是 YouTube Music 的精确读数,形状不对就当没有、
    /// 整秒读数照旧成立。纯函数,selftest 直接覆盖。
    public static func parseReading(fromOsascriptOutput raw: String) -> Reading? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text.removeFirst()
            text.removeLast()
        }
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[1] == "0", let seconds = Double(parts[0]) else { return nil }
        let artwork = parts.count >= 3
            ? SpotifyArtworkURL.parse(String(parts[2])) ?? KasetPlayerInfo.coverArtworkURL(String(parts[2])) : nil
        var precise: PreciseReading?
        if parts.count >= 4, parts[3].hasPrefix("@") {
            let fields = parts[3].dropFirst().split(separator: ",")
            if fields.count == 2, let ct = Double(fields[0]), ct >= 0,
               let ms = Double(fields[1]), ms > 0 {
                precise = PreciseReading(seconds: ct, readAt: Date(timeIntervalSince1970: ms / 1000))
            }
        }
        let video = parts.count >= 5 ? parseVideoIdentity(parts[4]) : nil
        let frame = artwork == nil && video != nil
            ? KasetPlayerInfo.videoFrameURL(videoID: video?.videoID, reportedArtwork: parts.count >= 3 ? String(parts[2]) : nil)
            : nil
        return Reading(seconds: seconds, artworkURL: artwork, precise: precise, video: video, videoFrameURL: frame)
    }
}
