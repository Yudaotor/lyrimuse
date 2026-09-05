import Foundation
import os

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
///   里都被 `with timeout of N seconds`(把"挂起"变成一个抓得住的 -1712 错误,2026-09-01
///   补 —— 裸 `try` **抓不住挂起**,只有它能)+ 裸 `try…end try`(吞掉错误,继续找下一个
///   标签页)+ `ProcessRunner` 的超时(最后杀掉子进程)一起兜住,最终对调用方表现一致:
///   探测失败、静默退回原有的
///   MediaRemote 逻辑(这是刻意的:探针只做加分项,拿不到就什么都不做,不能让它自己
///   变成新的故障点)。Edge 没有专门实测这一点,只验证过 AppleScript 词典和 Preferences
///   key 存在,失败方式假定接近 Chrome(比 Arc 改动小得多),但不是实测坐实的结论。
///   **没有提供脚本命令的浏览器(Firefox 等,
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
/// ## 2026-09-02 补:光"只用一次"还不够 —— 那一次还得**真的被采信**
///
/// 上面那套"一次性纠偏"落地之后,用真机日志坐实它**几乎从不生效**:连着三首歌
/// `neteaseDiag steady … ema=-0.197 / -0.206 / -0.226, snap=false`,而同期离屏逐帧量到的
/// 真实偏差是 0.7~0.9 秒(App 偏快)。**探针每次都测准了、每次都被扔掉。**
///
/// 病根是把一次性样本喂进了给**周期性噪声源**设计的闸门:`servoDecision` 对 `noisyFloored`
/// 是 alpha 0.3 / 门槛 1.0,单个样本最多把 EMA 推到 `0.3 × 误差` —— 要误差超过 **3.33 秒**
/// 才可能触发,而实测这档偏差只有 0.7~0.9 秒。修法见 `LocalPlaybackSource` 里
/// `groundTruthSnapToleranceSecs` 那条专门的重锚路径(门槛 0.30s,不走 EMA)。
///
/// 同一批还修掉了读数本身的系统性偏置:页面显示的是 `floor(真实位置)`(2026-09-02 用
/// media-control 暂停实测坐实:`elapsedTime=165.627` 而页面是 `165`),所以直接采信 `n`
/// 恒偏后、均值 −0.5 秒。现在补 `flooredMidpointBiasSecs = 0.5` 取区间中点,变成无偏估计。
///
/// 修法:探针只在**换歌后用一次**,把它当这首歌的"精确种子值"喂给 `resolvePositionSeconds`
/// (tier 按 `.noisyFloored` 处理,因为它确实就是整秒地板量化读数),让既有的 seek-跳变判定/
/// 棘轮/EMA 接管——命中一次大跳变就重锚(解决"换歌后进度偏慢"的原始问题),之后不再重复
/// 探测这首歌,把稳态精度交还给本来就更准的 `.cleanExtrapolated` 外推。见 `consumeCorrection`
/// 和 `kickIfNeeded` 里的一次性消费逻辑。
public final class BrowserPositionProbe: @unchecked Sendable {
    public static let shared = BrowserPositionProbe()
    private init() {}

    /// ⚠️ 这个类**长期一行日志都没有**(2026-09-02 补)。代价是真实的:那道退化守卫把整首歌
    /// 的纠偏全废掉了,而日志里查不到任何探针活动 —— 这**不能**当"它没跑"的证据,只能靠读
    /// 代码 + 量 media-control 反推。所以采信和弃用**两边都记**,弃用要带原因。
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "browserprobe")

    private static let probeTimeout: TimeInterval = 3

    /// 去掉"整秒下取整"的系统性偏置:页面显示的是 `floor(真实位置)`,所以真实位置均匀分布
    /// 在 `[n, n+1)`,取**中点**才是无偏估计;直接用 `n` 恒偏后、均值 −0.5 秒。
    ///
    /// ⚠️ "页面是 floor 不是 round" 是 **2026-09-02 实测坐实**的,不是假设:用 media-control
    /// 暂停(暂停那一刻 MediaRemote 会记下精确位置)抓到一个小数 ≥0.5 的样本 ——
    /// `elapsedTime=165.627` 而页面文字是 `165`(round 会是 166)。两个站点同源,YouTube Music
    /// 的 "M:SS" 同理。
    ///
    /// ⚠️ 加了这 0.5 之后,读数**不再满足**"reported ≤ 真实位置"—— 前向棘轮
    /// (`shouldRatchetForward`)的前提就是那条不等式。所以 `resolvePositionSeconds` 里
    /// 探针那一支必须排在棘轮**之前**、自成一条路径,不能落进棘轮。
    public static let flooredMidpointBiasSecs: Double = 0.5

    // MARK: - 探针值的可信度判据(2026-09-02 重写)

    /// ⚠️ **这里原来是一道拿 `snapshot.elapsedTime` 当参照物的"位置差"守卫。它是错的,已删。**
    ///
    /// 原判据 `abs(probed - reference) <= 8`,`reference` 传 MediaRemote 报的原始 `elapsedTime`。
    /// 而这个探针**存在的全部理由**就是"网页播放器的 MediaRemote 锚点是冻结的、`elapsedTime`
    /// 恒等于 0"(见类头注开头)。两者一凑,守卫就退化成 `probed <= 8` —— **只有页面真放在前
    /// 8 秒内的修正才会被采纳,过了第 8 秒一律弃用**;又因为消费是每首歌一次性的,整首歌都
    /// 跑在错的外推锚点上。现场:Chrome + music.youtube.com,`elapsedTime` 三次采样恒 0、
    /// `timestamp` 恒定不动,用户报「歌词进度不准」。加进去和被抓出来是**同一天**。
    ///
    /// ⚠️ 教训不是"参照物选错了",而是**任何拿 MediaRemote 位置当参照物的判据在这里都不成立**。
    /// 换成外推值也救不回来:探针最该出手的场合恰恰是"锚点本身就是错的"(冷启动时歌已经放到
    /// 两分钟、MediaRemote 报 0、锚点也从 0 起),那时外推值 ≈0 而探针读 120 —— 拿外推值当
    /// 参照会**恰好在它最该生效的场合**把它挡掉。
    ///
    /// 现在的判据不再问"这个值离某个参照物多远",改问两件**探针自己拿得出材料**的事:
    ///   ① 这个标签页放的是不是同一首歌(`pageDurationToleranceSecs`,在 JS 里比);
    ///   ② 这个标签页的钟有没有在走(`pageClockIsRunning`,两次采样)。
    /// 陈旧镜像标签页的特征恰恰是**它不动**(2026-09-02 实测:15 次采样一直读 7 秒),
    /// 这比"它离 MediaRemote 多远"直接得多,也不依赖任何一个我们不信任的数。

    /// 两次采样之间隔多久。
    ///
    /// ⚠️ 下界由**页面读数的量化精度**定死:探针读的是页面渲染的进度文字,只有整秒精度
    /// (见类头注),所以间隔必须 **> 1 秒**才能保证正常播放时 floor 至少 +1;否则"没前进"
    /// 分不出是"钟停了"还是"还没跨过整秒边界"。取 1.5 秒是给后台标签页的 1Hz 计时器节流
    /// 留一倍余量。
    ///
    /// ⚠️ 代价是**纠偏比原来晚约 1.5 秒落地**(一次探测变两次 + 中间等待)。可以接受:
    /// `consumeCorrection` 按 `rate * age` 补偿滞后,落地的**值**仍然是对的,晚的只是那一刻;
    /// 正常换下一首时未纠偏的位置本来也≈0,看不出差别 —— 真正吃到这 1.5 秒的只有"冷启动时
    /// 歌已经放到一半"这种场合,而那里本来就要等一次探测往返。
    public static let livenessGapSeconds: TimeInterval = 1.5

    /// 两次采样之间页面进度**有没有往前走**。纯函数,给 selftest 直接覆盖。
    ///
    /// ⚠️ 判据是"floor 有没有 +1",不是"增量 ≈ Δt × rate"。读数本来就是整秒地板量化的,
    /// 拿它去比一个连续量要给的容差大到没有区分力(Δt=1.5s 时增量只可能是 1 或 2);
    /// 而"有没有 +1"本身已经把"钟在走"和"钟停了"完全分开了。
    ///
    /// ⚠️ 两个已知的、**刻意选择**的失败方向,都往"不纠偏"倒:① 倍速 0.5x 时 1.5 秒只走
    /// 0.75 秒媒体时间,floor 可能不 +1 → 判否;② 用户往回拖进度条(second < first)→ 判否。
    /// 两种都只是这一轮不纠偏、下一轮重试,跟类头注里"暂停判据宁可退化成永远判暂停"是同一个
    /// 取向:宁可不纠偏,也不能采信一个读错了标签页的值。
    public static func pageClockIsRunning(first: Double, second: Double) -> Bool {
        second > first
    }

    /// 页面显示的总时长跟 MediaRemote 报的时长差多少之内算"同一首歌"。
    ///
    /// ⚠️ 这道判据在 **JS 里**比(见两条站点规则里的 `__EXPECT__`),不在 Swift 里 —— 差一首歌
    /// 的标签页要让 AppleScript 那两遍循环**继续往下找**,而不是整次探测就此失败。否则
    /// "陈旧镜像排在正在放的那个标签页前面"时,后者永远轮不到。
    ///
    /// 它挡的是"读到了另一份媒体":同一浏览器里的第二个 Spotify 标签页、YouTube Music 插的
    /// 广告(⚠️ 广告那行进度文字是**广告自己的**、而且**是在走的** —— `pageClockIsRunning`
    /// 对广告一路放行,只有时长对不上认得出来,别指望活性判据兜这个)。
    ///
    /// 容差 2 秒:页面显示的是 `floor(总时长)`,MediaRemote 给的是小数(实测 `duration=218.781`
    /// 对页面 `3:38`=218),固有差不到 1 秒,留一倍余量。
    ///
    /// ⚠️ 期望时长未知(传 0)或页面读不出总时长时**跳过这道检查**,不是判否 —— 失败方向保持
    /// "最坏也不过是回到没有这道检查的样子",不能让一个拿不到的字段把整个探针关掉。
    public static let pageDurationToleranceSecs: Double = 2

    /// 同一首歌最多探测几次。
    ///
    /// ⚠️ 为什么需要它(2026-09-02):判"钟没在走"可能是**瞬时**的 —— 页面在缓冲、标签页刚被
    /// 切到后台还没跑满一个计时周期。这类失败**不消费**那次一次性额度(判据在探针内部,拿不到
    /// 值就不写缓存,`consumeCorrection` 自然不会置 `consumedKey`),所以重试是自动的;但自动
    /// 重试没有上界就变成"整首歌每一轮都去 tell 一遍浏览器"。三次 + 退避是两头的折中:瞬时
    /// 抖动有得救,真读不到的标签页也不会被骚扰一整首歌。
    public static let maxProbeAttempts = 3
    /// 两次探测尝试之间至少隔多久(从上一次**结束**算起)。
    public static let probeRetryBackoffSecs: TimeInterval = 3

    /// 单条 `execute … javascript` / `do JavaScript` 的 **AppleEvent** 超时(秒)。
    ///
    /// ⚠️ 必须有,而且必须比 `probeTimeout` 小:这条命令会**永远挂着不返回**(见
    /// `activeTabExpression` 头注的 Arc 休眠标签页实测),AppleScript 的 `try` 抓不住挂起,
    /// 只有 `with timeout of N seconds` 能把它变成一个能被 `try` 抓住的错误(-1712)。
    /// 没有它的话,一个休眠标签页就能把整次探测的 3 秒预算吃光、后面真正在播放的标签页
    /// 根本轮不到。
    ///
    /// 探测循环里可能要连着跳过好几个休眠标签页,所以每条给 1 秒(活标签页实测 ~0.2 秒,
    /// 5 倍余量);自检只发一条命令、有整个 3 秒可用,给 2 秒更宽松。
    private static let probeEventTimeoutSeconds = 1
    private static let selfTestEventTimeoutSeconds = 2

    /// 「这个窗口此刻真正显示着的那个标签页」的 AppleScript 说明符 —— Chromium 系叫
    /// `active tab`(四字码 `acTa`,Arc/Chrome/Edge 三家一致),Safari 叫 `current tab`
    /// (`cTab`),**不同名**,2026-09-01 逐个从各自 bundle 里的 sdef 核对过。
    ///
    /// ⚠️ 为什么非它不可(2026-09-01 实测坐实,这是「检测没通过:no output」那个 bug 的根因):
    /// **Arc 会把非当前标签页休眠掉,对休眠标签页执行 JavaScript 会一直不返回**。同一时刻
    /// 同一台机器上实测:`execute (tab 1 of window 1) javascript "1+1"` 挂死(5 秒被杀,
    /// 零输出),`execute (active tab of window 1) javascript "1+1"` 123 毫秒返回 2;
    /// 当前标签页是第 10 个,它的**紧邻**第 9、11 个(同为 pinned)一样挂死。也就是说
    /// 「第一个窗口的第一个标签页」这个看起来最稳妥的取法,在 Arc 上几乎必然踩中休眠标签页。
    /// 标签页的 `loading`/`location` 属性都**判不出**它是不是休眠的(实测 `loading` 为
    /// false、`location` 为 pinned,照样挂),没有可用的前置判据,只能靠"取当前标签页"
    /// + `with timeout` 兜底。
    private static func activeTabExpression(
        family: BrowserAutomationPermission.Family, windowIndex: String
    ) -> String {
        switch family {
        case .chromium: return "active tab of window \(windowIndex)"
        case .safari:   return "current tab of window \(windowIndex)"
        }
    }

    /// 一个"网页音乐平台"的公开身份——设置页的"浏览器歌词同步"卡片按这份列表逐个渲染
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
    /// ⚠️ **别照抄另一个平台的规则**。两个站点实测下来"看着一样、其实处处不同":YouTube Music
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
    /// ⚠️ 脚本里的 `__EXPECT__` / `__TOL__` 两个占位符由 `buildAppleScript` 在拼进 AppleScript
    /// **之前**替换成数字(见 `pageDurationToleranceSecs`)。用占位符而不是给 `script` 改成
    /// 闭包,是为了让这张规则表继续是一张**纯数据**表 —— 加站点的人照抄一条就行,不用先搞懂
    /// 参数怎么传进来。⚠️ 替换必须在拼进 AppleScript 之前做,拼完再替换会撞上转义。
    private struct SiteRule {
        let platformID: String
        let urlContains: String
        let script: String
    }

    /// ⚠️ 顺序即优先级:`probeOnce` 按这个顺序试用户配对过的规则,**第一条拿到"确实在播放"
    /// 读数的就直接返回**。所以每条规则的暂停判据都必须靠谱 —— 一个开着但暂停的标签页如果
    /// 误报成"在播",会把它的陈旧位置安到另一个平台正在播的那首歌上。
    private static let siteRules: [SiteRule] = [
        SiteRule(platformID: "youtubeMusic", urlContains: "music.youtube.com", script: youtubeMusicScript),
        SiteRule(platformID: "spotifyWeb", urlContains: "open.spotify.com", script: spotifyWebScript),
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
      return cur + '|' + (paused ? '1' : '0');
    })()
    """

    /// Spotify 网页版(`open.spotify.com`)的播放进度。2026-09-01 在这台机器上对着真实播放
    /// 逐项实测,**没有一条是从 YouTube Music 那条规则推出来的** —— 两个站点差异比想象中大。
    ///
    /// ## 进度取自 `[data-testid=playback-position]` 的**文字**
    ///
    /// 形如 "2:18",只有当前位置(总时长在另一个元素 `playback-duration`,这里用不着)。
    ///
    /// ⚠️ **进度条里那个 `<input>` 是个陷阱,别用**。它长得特别像好东西:
    /// `[data-testid=playback-progressbar] input` 带 `value=145000 max=269340`,毫秒精度、
    /// max 还跟 media-control 报的 `duration=269.339773` 严丝合缝。但连打三拍实测是
    /// **140000 → 145000 → 145000**(5 秒一跳、而且滞后),同期文字是 2:18 → 2:22 → 2:25
    /// 一直在走 —— 那个 value 是给滑块用的节流状态,不是实时位置。照它写出来的进度会一顿一顿。
    ///
    /// ## 暂停判据:`document.title` 里有没有那个分隔符
    ///
    /// ⚠️ **不能用 `<video>.paused`** —— YouTube Music 那条规则就是这么判的,而 Spotify Web
    /// **页面里没有 `<video>` 也没有 `<audio>`**(`querySelector` 两个都返回 null,实测),
    /// 音频走的是别的路子。这条路直接断掉,必须另找。
    ///
    /// 逐个否掉的候选(都实测过):
    /// - 播放/暂停键的 `aria-label` —— **本地化**的(中文界面下播放中是「暂停」、暂停时是
    ///   「播放」),认它等于只支持中文。
    /// - `navigator.mediaSession.playbackState` —— Spotify 没设,恒为 `'none'`。
    /// - 按钮和它的祖先节点 —— 扫过三层,只有 `data-testid`,没有任何状态位。
    /// - 那个图标的 SVG `path` 的 `d` —— 播放中是两条竖杠、暂停时是三角形,确实是干净的
    ///   分水岭,但**认图标路径字符串太脆**,Spotify 换一版图标就悄悄失效。(顺带记一笔给
    ///   后人:想按"子路径个数"判的话别只数大写 `M` —— 暂停那条是
    ///   `M2.7 1a…z` + `m8 0a…z`,第二段是**小写** `m`,只数大写两边都是 1。)
    ///
    /// 最后用的是 `document.title`:播放中是 `歌名 • 歌手`,暂停时整个回落成静态的
    /// `Spotify - Web Player: Music for everyone`(实测原文,中文界面下这句仍是英文)。
    /// ⚠️ 判据只看**那个分隔符在不在**,不看任何一边的文案 —— 所以它不受本地化影响,也不受
    /// 那句英文将来改字影响。分隔符用 `String.fromCharCode(8226)` 拼(U+2022 圆点),不把
    /// 非 ASCII 字符直接写进这段嵌进 AppleScript 的源码里。
    ///
    /// ⚠️ 万一将来 Spotify 换掉标题格式,这里会退化成"永远判暂停" → 探针不出手 → 静默退回
    /// 既有的 MediaRemote 逻辑。这是**刻意选的失败方向**:宁可不纠偏,也不能把一个暂停
    /// 标签页的陈旧位置安到正在播的歌上。
    ///
    /// ## 位置文字支持 `M:SS` 和 `H:MM:SS` 两种
    ///
    /// 播客/长音频会走到三段式,YouTube Music 那条规则只认两段(它自己的元素也只会是两段)。
    /// 这里多认一种,成本一行、收益是播客不会静默失效。
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
      return cur + '|' + (paused ? '1' : '0');
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
    /// ⚠️ 两边对不上**不会编译报错**,只表现成用户看得见的断层:设置页把那个平台的卡片摆
    /// 出来、配对也配得上,而 `probeOnce` 找不到对应规则、永远不探测 —— "配好了却永远不
    /// 同步",正是这套东西最难被发现的那种坏法。
    public static var platformIDsWithSiteRules: Set<String> { Set(siteRules.map(\.platformID)) }

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
    // 有界重试的记账(2026-09-02,见 maxProbeAttempts):按曲目 key 计次,换歌清零。
    private var attemptKey: String?
    private var attemptCount = 0
    private var lastAttemptEndedAt: Date?
    private var platformBrowserPairsStorage: [String: Set<String>] = [:]
    /// 最近一次**探测成功**是在哪个浏览器上、命中了哪个平台的站点规则(2026-09-03)。
    /// 这是"这个浏览器此刻在放哪个网页音乐平台"最硬的证据 —— 它意味着我们刚从那个站点
    /// 自己的 DOM 里读到了一个**在走**的进度。给来源角标用,见 `playingPlatformID`。
    private var lastMatch: (bundleID: String, platformID: String, at: Date)?

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

    /// 这个(已解析代理进程之后的)bundle id 有没有被用户配对给指定平台——给
    /// `LocalPlaybackSource` 判断"网页版 Spotify 广告"用(2026-09-02):调用方需要传已经过
    /// `probeTargetBundleID` 解析的 host bundle id,跟 `kickIfNeeded`/`pairedPlatformIDs`
    /// 是同一份配对数据、同一把锁,不是另起一份判断逻辑。
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

    /// 这个浏览器此刻在放哪个网页音乐平台(nil = 不知道 / 不是网页播放器)。
    ///
    /// 2026-09-03 加,给菜单栏面板右上角那枚**来源角标**用:用户要求"确实是 YouTube Music
    /// 就别再显示浏览器图标了,浏览器里放 Spotify 就显示 Spotify,其余照旧显示浏览器"。
    ///
    /// ⚠️ 调用方传 media-control 报的原始 bundle id 就行,这里自己做代理别名解析
    /// (Safari 报 `com.apple.WebKit.GPU`,配对表里存的是 `com.apple.Safari` —— 这一步
    /// 漏掉的后果在 02 章记过一次:"配对了却永远不同步",而且一条日志都没有)。
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
    ///    (这台机器上 Safari / Arc 就是),只有这一档答得上来。
    /// 2. **只配对了一个平台** → 就当是它。这一档是**推断不是证据**,可能错:浏览器里放
    ///    别的、恰好也带齐 artist+album 的网页音源(播客站之类)时,角标会显示成那个平台。
    ///    代价是纯观感的 —— 角标点下去仍然是 `openResolvedPlayerApp()` 按 bundle id 唤浏览器,
    ///    行为一个字不变。收益是这一档覆盖了绝大多数人的实际配置(一个浏览器只配一个平台),
    ///    而且**不用等探测成功**就能显示对。同款推断在 `LocalPlaybackSource` 判"网页版
    ///    Spotify 广告"时已经用了(`isPaired(...platformID: "spotifyWeb")`),不是新开的口子。
    ///
    /// ⚠️ 第 1 档要求命中的平台**仍然在配对表里**:用户后来取消配对了,那条旧证据就不该
    /// 再作数(否则取消配对之后角标还挂着那个平台,而探测早就不跑了、永远刷新不掉)。
    public static func resolvePlayingPlatformID(
        pairedPlatformIDs: Set<String>, recentMatch: String?
    ) -> String? {
        if let recentMatch, pairedPlatformIDs.contains(recentMatch) { return recentMatch }
        return pairedPlatformIDs.count == 1 ? pairedPlatformIDs.first : nil
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
        let corrected = snapshot.seconds + Self.flooredMidpointBiasSecs + rate * age
        // ⚠️ **这一行跟 `probeAdvancing` 里那句"采信"不是一回事,两行都要有**(2026-09-03
        // 复量时暴露的日志盲区):"采信"打在**探针内部**(拿到一个可信读数、写进缓存),
        // 而这里才是**真的交给伺服逻辑用了**。同一首歌可能出现好几行"采信"却只有一行
        // "交出" —— 一次性额度(`consumedKey`)把后面几次挡在门外。只看"采信"会读成
        // "重锚了好几次",看不出这一拍的位置到底是探针给的还是外推的。
        Self.logger.notice("probe: handing off correction \(corrected, privacy: .public)s (reading \(snapshot.seconds, privacy: .public)s + midpoint + \(age, privacy: .public)s lag), per-track budget exhausted")
        return corrected
    }

    /// 换歌时清掉缓存——上一首歌的探测结果绝不能被当成这一首歌的位置用,也重新开放
    /// 这首新歌的一次性消费额度。也会让"正在飞的探测"的结果作废(generation 递增),
    /// 防止一份晚到的旧曲目探测结果污染新曲目。
    /// `from`/`to` 只用于日志(2026-09-03 加):`from` 为空说明**不是真换歌**,是快照变
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
        // ⚠️ 这一行是"同一首歌为什么又探了一次"的唯一线索(2026-09-03 加)。调用方是
        // `LocalPlaybackSource` 的 `if trackChanged`(`key != lastKey`),而 `lastKey`
        // **不只在真换歌时变** —— 快照变成 nil(播放器退出/stopped/系统 Now Playing 焦点
        // 被别的 App 抢走一次)那条路径会把它清成 "",下一拍就重新算一次"换歌"。所以
        // 一首歌中途出现多轮探测**不一定是 bug**,但必须能从日志里看出是哪一种。
        Self.logger.notice("probe: track key changed, reopening per-track probe budget (old=\(previousKey, privacy: .public) new=\(newKey, privacy: .public))")
    }

    /// 如果这个 bundle id 受支持、这首歌还没消费过一次探测结果、且当前没有正在飞的同
    /// 曲目探测,踢一次新的——异步、**不阻塞调用方**,结果就绪时写回 `cached` 供
    /// `consumeCorrection` 用。这首歌一旦被消费过一次就不再重新探测(见类头注),避免
    /// 稳态播放期间持续拿整秒精度的读数去覆盖本来更准的连续外推,也省下持续的 AppleEvent
    /// 往返开销。不等这次探测的结果,是刻意的:调用方(轮询循环)本身就是同步、高频跑的,
    /// 不能被一次上百毫秒的 AppleScript 往返卡住。
    public func kickIfNeeded(bundleIdentifier: String?, key: String, expectedDuration: Double) {
        // ⚠️ **先把「媒体代理进程」解析成宿主 App**(2026-09-02 修的真 bug)。Safari 播网页
        // 音频时 MediaRemote 报的是 `com.apple.WebKit.GPU`(解码跑在独立的 WebKit GPU 进程
        // 里,见 `TrustedPlayers.mediaProxyOwners`),而**配对表里存的、AppleScript 要 tell 的
        // 都是 `com.apple.Safari`**。不解析的话 `family(...)` 当场返回 nil、探测一次都不会
        // 发起 —— 表现是"配对了 Safari、卡片也在、却永远不同步",而且不报任何错。
        //
        // 准入那一侧(`TrustedPlayers.isAccepted`)2026-09-01 就补了这步别名解析,探针这侧
        // 一直漏着。⚠️ 两处都要解析:`family(...)` 和 `pairedPlatformIDs(...)` 都按宿主查,
        // 下面 `probeOnce` 拿去 `tell application id` 的也必须是宿主 —— 对
        // `com.apple.WebKit.GPU` 根本 tell 不动。
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
        // 有界重试(2026-09-02,见 `maxProbeAttempts`):探测失败**不消费**那次一次性额度,
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
        lock.unlock()

        Task.detached(priority: .utility) {
            let hit = await Self.probeAdvancing(
                bundleID: hostBundleID, family: family, platformIDs: platformIDs,
                expectedDuration: expectedDuration, attempt: attemptNumber)
            self.applyProbeResult(hit, key: key, generation: myGeneration,
                                  bundleID: hostBundleID)
        }
    }

    /// `lock`/`unlock` 直接写在 `Task.detached` 闭包体里,在 Swift 6 语言模式下是编译
    /// 错误(NSLock 的那两个方法不认为自己能安全地跨越 async 挂起点被调用)——拆成这个
    /// 普通同步函数,闭包里只是"调用"它,不在 async 上下文里直接摆弄锁,绕开这条限制。
    private func applyProbeResult(_ hit: ProbeHit?, key: String, generation myGeneration: Int,
                                  bundleID: String) {
        lock.lock()
        defer { lock.unlock() }
        // 退避从"上一次探测**结束**"算起,而不是从发起算起 —— 一次探测本身现在要花
        // 两次 osascript 往返 + `livenessGapSeconds`,按发起算等于没有退避。
        lastAttemptEndedAt = Date()
        guard myGeneration == generation else { return } // 换歌了,这份结果作废
        if inFlightKey == key { inFlightKey = nil }
        guard let hit else { return }
        cached = CachedResult(key: key, seconds: hit.seconds, capturedAt: Date())
        // ⚠️ 这一条**故意不受 generation 之外的任何作废影响**、也不按曲目 key 存:它回答的
        // 是"这个浏览器在放哪个平台",那件事跨曲目稳定,而位置纠偏是一首歌一次性的。
        // 存在同一个 lock 下,读在 `playingPlatformID`。
        lastMatch = (bundleID: bundleID, platformID: hit.platformID, at: Date())
    }

    // MARK: - 探测实现(全程跑在后台线程,调用方必须走 Task.detached)

    /// 只试用户为这个浏览器配对过的平台对应的站点规则——哪怕另一个平台的站点规则也能
    /// 匹配上当前打开的标签页,没配对过就不试,尊重用户的显式选择(见类头注)。
    /// 「这个浏览器现在到底能不能被驱动」的**功能性**自检(2026-09-01)。
    ///
    /// ⚠️ 存在的理由:Chromium 系那道 JS 开关的状态**读不出来** —— 它存在浏览器 profile 的
    /// `Preferences` 里,而别的 App 读那个目录要「完全磁盘访问权限」,这个 App 没有。于是
    /// 用户按指引手动开完之后,界面上永远显示「无法确认状态」,他没法确认自己做对没有
    /// (用户原话:「我现在已经手动去打开了,这个页面怎么回显?」)。
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
        /// ⚠️ 跟 `blocked` 分开,是因为它是另一种失败方式而不是同一件事的另一种说法:
        /// Chrome 那道开关关着时会**立刻**抛一句清清楚楚的错误(→ `blocked`),而 Arc
        /// 关着时**什么都不说、直接不回**(→ 这里)。当前标签页本身卡死(页面在跑死循环)
        /// 也会落进来,所以文案上只说"多半是开关没勾",不把它当成板上钉钉的结论。
        case noReply
        /// 其它失败(超时、TCC 没授权、语法错误…)。带上原始输出供 UI 显示。
        case failed(String)
    }

    /// ⚠️ 同步执行、会起一个 osascript 子进程,**别在主线程调**。
    public static func selfTest(bundleID: String, family: BrowserAutomationPermission.Family) -> SelfTestResult {
        guard BrowserAutomationPermission.isRunning(bundleID: bundleID) else { return .noTab }
        // 最小可行脚本:在第一个窗口**此刻显示着的那个标签页**里算 1+1。刻意不带任何 URL
        // 过滤 —— 自检要回答的是"驱不驱得动",跟用户此刻开着什么页面无关。
        //
        // ⚠️ 取的是 `active tab` 而**不是** `tab 1`(2026-09-01,这就是用户报的
        // 「检测没通过:no output」的根因,理由见 `activeTabExpression` 头注):Arc 把非当前
        // 标签页休眠掉,对休眠标签页执行 JavaScript 会**一直不返回**,于是一切正常的 Arc
        // 也会被这个自检判成失败。当前标签页是唯一能保证是活的那个。
        let tab = activeTabExpression(family: family, windowIndex: "1")
        let executeLine: String
        switch family {
        case .chromium: executeLine = "execute (\(tab)) javascript \"1+1\""
        case .safari:   executeLine = "do JavaScript \"1+1\" in \(tab)"
        }
        // ⚠️ 错误必须在 AppleScript 里用 `on error` 捞回 **stdout** —— `ProcessRunner.Result`
        // 不收 stderr,而浏览器回绝时那句关键提示正是走 stderr 的。捞回来才判得出"开关关着"
        // 和"别的失败"的区别。顺带把错误**号**也捞回来:-1712(AppleEvent 超时)要跟别的
        // 错误分开报,它的文案是本地化的、认不得,号是稳定的。
        //
        // ⚠️ `with timeout` 不能省:没有它时"浏览器不回"表现为 osascript 挂死到被
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
            // ⚠️ 这条**不是超时** —— `ProcessRunner.run` 只在"子进程根本没起来"时返回 nil,
            // 超时走的是 `result.timedOut`。旧版这里报 "timeout",报错方向是反的。
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
        // 而且 ⚠️ **认关键词不认整句** —— 那句提示是本地化过的,各语言都不一样。逐条实测出处:
        //   - Chrome/Edge(取自自己的 locale.pak):英文 "Executing JavaScript through
        //     AppleScript is turned off…",中文「通过 AppleScript 执行 JavaScript 的功能已关闭…」
        //     → 稳定锚点是 "AppleScript" + ("turned off" / 「已关闭」)。
        //   - Safari(2026-09-01 在这台机器上实测原样抄回来的):"You must enable 'Allow
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
    /// ⚠️ 两次采样必须是**两次独立的 osascript 运行**,不能在 AppleScript 里 `delay`:
    /// `probeTimeout` 是 3 秒硬超时,脚本里睡 1.5 秒会把预算吃掉一半、后面真正在播的标签页
    /// 又轮不到(跟 `activeTabExpression` 头注里休眠标签页吃预算是同一类账)。这里跑在
    /// `Task.detached` 的后台任务里,两次之间 `Task.sleep` 不占线程,是免费的。
    ///
    /// ⚠️ `flooredMidpointBiasSecs` 的 +0.5 由 `consumeCorrection` 统一补,**这里一次都不补**
    /// —— 它补的是"页面显示 floor"这个系统性偏置,跟采样几次无关,补两次就偏了半秒。
    /// 一次成功探测的产物:读到的秒数 + **是哪个平台的站点规则读到的**。
    /// 后者 2026-09-03 加,给来源角标用(见 `playingPlatformID`);位置那条链路只用前者。
    private struct ProbeHit {
        let seconds: Double
        let platformID: String
    }

    private static func probeAdvancing(
        bundleID: String, family: BrowserAutomationPermission.Family,
        platformIDs: Set<String>, expectedDuration: Double, attempt: Int
    ) async -> ProbeHit? {
        let expect = Int(expectedDuration.rounded())
        guard let first = probeOnce(bundleID: bundleID, family: family,
                                    platformIDs: platformIDs, expectedDuration: expectedDuration) else {
            logger.info("probe #\(attempt, privacy: .public): no tab produced a usable reading (expected duration \(expect, privacy: .public)s)")
            return nil
        }
        try? await Task.sleep(nanoseconds: UInt64(livenessGapSeconds * 1_000_000_000))
        guard let second = probeOnce(bundleID: bundleID, family: family,
                                     platformIDs: platformIDs, expectedDuration: expectedDuration) else {
            logger.info("probe #\(attempt, privacy: .public): second sample returned nothing, discarding \(first.seconds, privacy: .public)s")
            return nil
        }
        // ⚠️ 两拍必须落在**同一个平台**上(2026-09-03 补)。同时开着 YouTube Music 和
        // Spotify 网页版、而两边规则的优先级判定在两拍之间翻了个个儿时,拿 A 站的读数减
        // B 站的读数去判"进度在不在走"是没有意义的 —— 那个差值既可能碰巧为正(误采信一个
        // 属于另一首歌的位置),也可能碰巧为负(白白弃用一次真读数)。不同平台直接弃用。
        guard first.platformID == second.platformID else {
            logger.notice("probe #\(attempt, privacy: .public): samples landed on different platforms (\(first.platformID, privacy: .public) -> \(second.platformID, privacy: .public)), discarding")
            return nil
        }
        guard pageClockIsRunning(first: first.seconds, second: second.seconds) else {
            logger.notice("probe #\(attempt, privacy: .public): page position is not advancing (\(first.seconds, privacy: .public)s -> \(second.seconds, privacy: .public)s), discarding")
            return nil
        }
        logger.notice("probe #\(attempt, privacy: .public): accepting \(second.seconds, privacy: .public)s (previous \(first.seconds, privacy: .public)s, expected duration \(expect, privacy: .public)s, platform \(second.platformID, privacy: .public))")
        return second
    }

    private static func probeOnce(bundleID: String, family: BrowserAutomationPermission.Family, platformIDs: Set<String>, expectedDuration: Double) -> ProbeHit? {
        for rule in siteRules where platformIDs.contains(rule.platformID) {
            if let seconds = probe(bundleID: bundleID, family: family, rule: rule, expectedDuration: expectedDuration) {
                return ProbeHit(seconds: seconds, platformID: rule.platformID)
            }
        }
        return nil
    }

    private static func probe(bundleID: String, family: BrowserAutomationPermission.Family, rule: SiteRule, expectedDuration: Double) -> Double? {
        let appleScript = buildAppleScript(bundleID: bundleID, family: family, urlContains: rule.urlContains, script: rule.script, expectedDuration: expectedDuration)
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
    /// 求值的写法能用)。遇到第一个"确实在播放"(非 `NOTFOUND` 且非暂停)的就直接返回,
    /// 避免用户同时开着好几个同源标签页(比如两个 YouTube Music 页面)时读错。
    ///
    /// ⚠️ **先扫一遍各窗口的当前标签页,再扫其余标签页**(2026-09-01 加的第一遍循环)。
    /// 理由见 `activeTabExpression` 头注:Arc 会休眠非当前标签页,对休眠标签页执行
    /// JavaScript 会一直不返回、只能等 `with timeout` 把它踢掉,每踢一个就吃掉一秒预算。
    /// 用户开着几十个标签页是常态(实测这台机器 50 个),其中只要有两三个匹配得上 URL
    /// 又恰好是休眠的,整次探测的 3 秒就没了、真正在播放的那个根本轮不到。当前标签页是
    /// 唯一保证活着的,先试它 —— 而"正在放歌的那个标签页"很多时候就是当前标签页。
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
        bundleID: String, family: BrowserAutomationPermission.Family, urlContains: String,
        script rawScript: String, expectedDuration: Double
    ) -> String {
        // ⚠️ 占位符替换必须发生在**拼进 AppleScript 之前**(见 `SiteRule` 头注)。期望时长
        // 未知(<=0)时传 0 进去,JS 那边看见 0 就整条跳过时长检查 —— 失败方向是"退回没有
        // 这道检查的样子",不是"什么都探不到"。
        let expect = expectedDuration > 0 ? Int(expectedDuration.rounded()) : 0
        let script = rawScript
            .replacingOccurrences(of: "__EXPECT__", with: String(expect))
            .replacingOccurrences(of: "__TOL__", with: String(Int(pageDurationToleranceSecs)))
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
                set tabCount to count of tabs of window wi
                repeat with ti from 1 to tabCount
                    if (URL of tab ti of window wi) contains "\(urlContains)" then
                        try
                            with timeout of \(probeEventTimeoutSeconds) seconds
                                set r to \(executeLine)
                            end timeout
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
