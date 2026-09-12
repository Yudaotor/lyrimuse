import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

/// 灵动岛的**窄订阅代理**(2026-08-19 性能审计落地,与悬浮歌词的 OverlayPlayback 同款
/// 模式,那边的注释讲了完整机制,这里不重复):PlaybackCoordinator 36 个 @Published 灵动岛
/// 实读约 17 个、AppSettings 47 个只读 2 个,整对象订阅会让歌词窗口拖音量、设置页无关
/// 滑杆这类写入以鼠标事件频率打醒整卡 body(含封面背景/跑马灯/音浪),开多屏镜像再按
/// 屏数翻倍。只转发实读字段,值类型一律 removeDuplicates。
///
/// ⚠️ sink 只用参数值,不回读源属性(@Published willSet 时机,回读是旧值)。
///
/// anchor 例外地**入订阅**(跟悬浮窗不同):灵动岛的 progressSection 要在 body 里判断
/// 「有没有锚点」决定进度条走播放态还是暂停态分支,而 LocalPlaybackSource 只在首锚/换歌/
/// seek/倍速变化时才重建锚点(稳定播放期间不赋值),它本身就是低频源,订阅无害。
/// currentLyricsOffsetMs 仍由逐字填色的 TimelineView 闭包直读协调器,不入订阅。
@MainActor
private final class NotchPlayback: ObservableObject {
    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    /// 只有「专辑」这个耳朵模块读它(2026-08-31 加)。窄订阅的纪律没变:多订一个字段是因为
    /// 真的有人读,不是"顺手都订上"。
    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var currentLine: SyncedLyricLine?
    /// 歌词行**主行**画哪一句(2026-09-06 起是合成值,不再直接等于 PlaybackCoordinator 的
    /// compactLine):
    ///   - 副行关着(单行面):取 `compactLine` —— 唱完就切走、提前亮出下一句给跟唱用,规则见
    ///     CompactLyricLead / 05 章决策 11;
    ///   - 副行开着(不管显示的是下一句、译文还是罗马音):取 `currentLine` —— 跟悬浮歌词同一套语义,
    ///     唱完停在填满的样子直到下一句开始。副行是「下一句」时尤其不能再提前切:那会变成两行同一句;
    ///     选译文 / 罗马音时副行显示的是**当前句**的译文 / 罗马音,主行若提前切到下一句,两行就对不上号;
    ///   - 「卡拉OK效果」关着时再压成整行(`lineLevel`),渲染分支不用改,自然落到 `.plain` 那一档。
    /// `currentLine` 本身仍单独保留 —— 均衡器条子跟的是"此刻在唱哪个字",那是 currentLine 的语义,
    /// 不能跟"屏幕上显示哪一句"混。
    @Published private(set) var displayLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?
    /// 副行的文本(2026-09-06,`AppSettings.notchSecondaryLine` 四选一):下一句 / 当前句译文 /
    /// 当前句罗马音,取不到就是 nil(这一行留空、高度不变,不让卡片一首一首跳)。`.off` 恒为 nil。
    /// 罗马音走 `SyncedLyricLine.romanization`,跟悬浮歌词同一来源(服务端 lyrics_roma 优先、
    /// 客户端 Romanizer 兜底、`romanizationScripts` 语言门控都在引擎侧做完了),这里不再判一遍。
    @Published private(set) var secondaryText: String?
    /// 副行选项本身,视图据此决定歌词行走单行排法还是双行排法。⚠️ 初值必须是
    /// `AppSettings.defaultNotchSecondaryLine`,理由同下面 `lyricsAlignment` 那条。
    @Published private(set) var secondaryLine: LyricSecondaryLine = AppSettings.defaultNotchSecondaryLine
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    /// 电台口白(2026-09-11):这一刻在放的不是歌,台里在说话。语义与 `isCurrentTrackAdBreak` 平行。
    @Published private(set) var isRadioTalkBreak = false
    @Published private(set) var radioStationName: String?
    @Published private(set) var radioStationImage: NSImage?
    /// 这条广告是插播里的第几条 / 一共几条(2026-09-09,用户要求「广告中,还剩几个广告」
    /// 显示出来)。只有 YT Music 网页广告给得出;拿不到是 nil,那一段整个不画 —— 同
    /// 「时长未知不画倒计时」那条纪律,不编数字。语义见 `LocalPlaybackSource.currentAdSlot`。
    @Published private(set) var currentAdSlot: YouTubeMusicAdProbe.AdSlot? = nil
    @Published private(set) var currentLineFillSettled = true
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var highResArtworkImage: NSImage?
    // ⚠️ **这里刻意没有 `motionCoverFile`**(2026-09-10 撤掉)。灵动岛这一面的封面只画静态图 ——
    // 动态封面只留在歌词窗口那张 460pt 的大卡上。理由见 artworkThumbnail 上方那段。
    // `PlaybackCoordinator.motionCoverFile` 本身还在(歌词窗口在用),别顺手把它一起删了。
    @Published private(set) var blurredArtworkImage: NSImage?
    @Published private(set) var anchor: ProgressAnchor?
    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?
    /// 灵动岛几乎所有前景元素的颜色:音浪、歌名、歌手、歌词(含逐字染色的调色板)、三个
    /// 播放键、进度条、瞬态横幅 —— 全卡 16 处 `accentOrWhite` 都是它。取到封面主色就用,
    /// 否则白(用 notchAccentColor 而非 artworkAccentColor 的理由见
    /// PlaybackCoordinator.notchAccentColor 注释)。两个输入在这里预组合成单个去重值,
    /// 任何一个变了才发一次。
    ///
    /// ⚠️ **"要不要跟封面走"这件事由 `notchCardStyle == .coverArt` 决定**(2026-08-31 改)。
    /// 在此之前它读的是 `AppSettings.followsCoverArt` —— 那是**桌面悬浮歌词**「配色」组里的
    /// 开关,而它的两个 UI 入口(设置页悬浮歌词段、悬浮窗上那个 ⚙ 快捷菜单)都挂在悬浮歌词上。
    /// 于是只开灵动岛的用户根本够不到这个决定自己整卡颜色的开关;更糟的是灵动岛「风格」里
    /// **已经有一个叫「跟随封面」的选项**(指背景铺封面模糊图),同样四个字、两件事,去那儿找
    /// 只会找错。现在两者合并成一件事:选「跟随封面」= 这张卡整体跟着封面走(背景是模糊封面、
    /// 前景是封面主色);选另外三种风格 = 前景恒为白。灵动岛因此不多一个开关,也不再受悬浮歌词
    /// 那边任何设置影响。
    /// (取不到封面主色时 `notchAccentColor` 为 nil,自动落回白色 —— 跟 `.coverArt` 背景在
    ///  没有封面时退回 darkGradient 是同一种兜底,不需要额外分支。)
    @Published private(set) var accent: Color = .white
    // ---- 来自 AppSettings ----
    // 灵动岛只读这一项:它既决定卡片背景(见 NotchCardStyle.fill / backgroundLayer),
    // 也决定前景取不取封面主色(折进上面的 accent)。
    @Published private(set) var notchCardStyle: NotchCardStyle = .coverArt
    /// 稳态/展开那一行两只耳朵各显示什么(见 NotchEarModule)。
    @Published private(set) var leftEar: NotchEarModule = .title
    @Published private(set) var rightEar: NotchEarModule = .artist
    /// 歌词行末尾那枚封面缩略图要不要显示、贴哪一边(2026-09-01)。走这里现读而不是
    /// `NotchChromeSource` 协议——它只影响 `lyricRowContent` 内部的 HStack 排列,不影响
    /// 卡片高度/宽度,理由同 `notchCardStyle`/`leftEar`/`rightEar`(那几个也只影响渲染)。
    @Published private(set) var lyricRowShowsArtwork: Bool = true
    @Published private(set) var lyricRowArtworkPosition: NotchLyricRowArtworkPosition = .right
    /// 装得下的短句靠哪边(2026-09-03)。同上走这里现读:它只改 `MarqueeText` 静止时的
    /// 对齐锚点和展开态「下一句」那一行的 frame 对齐,不影响卡片任何一个尺寸。
    /// ⚠️ 初值必须是 `AppSettings.defaultNotchLyricsAlignment`,不能另写一个字面量 ——
    /// 这个 `@Published` 的初值和 `AppSettings.init()` 的 fallback 是同一件事,写两份就会
    /// 在"订阅还没首次投递"的那一帧闪一下另一个方向。
    @Published private(set) var lyricsAlignment: LyricsRestingAlignment =
        AppSettings.defaultNotchLyricsAlignment
    /// 灵动岛歌词的字体(2026-09-09,设置页「字体」组):主行 / 主行同字号细一档(广告态倒计时)/ 副行与展开区
    /// 「下一句」预览。同上走这里现读:只改字形,不改卡片任何一个尺寸(字号上限由 Core 倒推、保证两行仍塞进 44,
    /// 见 `NotchLyricRowMetrics`)。初值直接读 `AppSettings.shared` 已算好的派生值,不另抄一份字面量。
    @Published private(set) var mainFont: Font = AppSettings.shared.notchMainFont
    @Published private(set) var mainDetailFont: Font = AppSettings.shared.notchMainDetailFont
    @Published private(set) var secondaryFont: Font = AppSettings.shared.notchSecondaryFont
    /// 副行开着时主行那一格给多高(`lyricTextColumn`):随字号走,公式只在 Core 一份。
    @Published private(set) var mainLineHeight: CGFloat =
        NotchLyricRowMetrics.mainLineHeight(fontSize: CGFloat(AppSettings.shared.notchFontSize))
    /// 下一句的对唱声部(2026-09-07,「对齐方式 · 自动」用)。跟 `nextLineText` 一样直接镜像
    /// `PlaybackCoordinator.nextLineSide` —— 悬浮歌词那边同一个来源、同一条"下一句不假定跟当前句
    /// 同一边"的理由(见 `LyricsOverlayView.nextLineDuetSide`)。当前句的声部不另镜像,`displayLine.side`
    /// 本来就在。
    @Published private(set) var nextLineSide: LyricDuet.Side?

    /// 「对齐方式」落到三个消费点上的**确定**方向(2026-09-07 加「自动」后从直接读 `swiftUIAlignment`
    /// 改过来的):非自动三档原样;「自动」按声部 —— 主行按 `displayLine.side`,展开态「下一句」按
    /// `nextLineSide`,副行看它显示的是谁的内容(下一句跟下一句走,译文 / 罗马音是当前句的,跟主行走)。
    /// 三个消费点**必须**读这三个值、不许再直接读 `playback.lyricsAlignment.swiftUIAlignment`(selftest 源码
    /// 契约钉着):这个仓库为"同一个视觉属性漏改一条路径"付过代价,见 `LyricsRestingAlignment.swiftUIAlignment` 注释。
    var mainLyricAlignment: Alignment {
        lyricsAlignment.resolved(duetSide: displayLine?.side).swiftUIAlignment
    }
    var nextLineAlignment: Alignment {
        lyricsAlignment.resolved(duetSide: nextLineSide).swiftUIAlignment
    }
    var secondaryLyricAlignment: Alignment {
        secondaryLine == .nextLine ? nextLineAlignment : mainLyricAlignment
    }

    /// 「跳过广告」有没有对象(2026-09-08):广告中,**且**这条广告是 YT Music 网页广告(探针强信号判定,
    /// 见 `YouTubeMusicAdSkipper.isYouTubeMusicAd`)。计算属性、不另发布:`isCurrentTrackAdBreak` 翻成 true
    /// 的那一拍正是探针把 `.ad` 写进缓存的那一拍(`LocalPlaybackSource.apply()` 读的是同一份缓存),视图
    /// 因 `isCurrentTrackAdBreak` 重估时读到的就是它;广告期间那份缓存每 5 秒被刷一次。Spotify 广告
    /// (原生 / 网页)的 YT 判定恒 nil,键不出现。
    var canSkipAd: Bool {
        isCurrentTrackAdBreak && YouTubeMusicAdSkipper.isYouTubeMusicAd(artist: artist, title: title)
            && adSkipAvailable
    }

    /// 页面上那颗「跳过」键此刻放出来没有(2026-09-11,用户:「如果当前广告不支持跳过的话就不要显示那个
    /// 跳过的按钮」)。
    ///
    /// 在此之前 `canSkipAd` 只问"是不是 YT Music 的广告",于是**不可跳过**的广告上也挂着一颗键,按下去
    /// 只换来一句「这条广告还不能跳过」—— 一颗永远按不动的键比没有更糟。这个值由 `adSkipGate()` 在广告
    /// 期间探页面得到(`YouTubeMusicAdSkipper.probeSkippability`,只读、不按键)。
    ///
    /// ⚠️ 必须是 `@Published`,不能做成计算属性去读某份缓存:倒计时那 5 秒过完、键刚放出来的那一刻,
    /// 广告态这一格**没有任何别的东西在变**(「还剩 0:21」那截自己排了一张 `TimelineView`,只重画它自己
    /// 那一小块),计算属性不会被重估,键就一直不出现。
    ///
    /// 初值 false:没问过页面之前不画键 —— 但"问不出来"(脚本跑不成)会被 `showsSkipButton` 判成**画**,
    /// 见那边那条 fail-open。
    @Published private(set) var adSkipAvailable = false

    /// 这一轮广告的门槛轮询。广告结束 / 换歌就取消。
    private var adSkipGateTask: Task<Void, Never>?

    /// 广告开始时起一轮门槛轮询;广告结束时收摊。由 `isCurrentTrackAdBreak` 那条订阅驱动。
    ///
    /// 节奏见 `YouTubeMusicAdSkipper.gateRetryDelay(after:)`:倒计时那一档等到点再问(否则最坏要等满
    /// 一个 5 秒心跳,而整条广告可能就 15 秒),其余走 5 秒心跳 —— 一次插播可能连放两条(徽章 1/2 → 2/2),
    /// 第一条不给跳、第二条给跳,所以问出 `.never` **也要**继续心跳,不能问出一次就收摊。
    /// 门槛轮询自己的日志(跟 Core 那一侧同一个 category,时间线连得上)。
    static let skipGateLogger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "ytmusic-skip")

    /// ⚠️ **由 `NotchLyricsView` 按 `controller.isAdBreakNow` 驱动,不挂在上面那条 `$isCurrentTrackAdBreak`
    /// 订阅上**(2026-09-11 改)。两者对真窗口是同一件事,但**预览 chrome 的 `isAdBreakNow` 恒 false**
    /// (`NotchEditorStage`),而 `NotchPlayback` 在预览里照样订阅真的 `PlaybackCoordinator` —— 挂在订阅上
    /// 的话,设置页只要开着,那块编辑台预览就会跟着真广告每 5 秒对用户的浏览器发一次 AppleScript。
    /// 真机日志坐实过(每一行都打了两遍),而"预览不该产生任何副作用"是这个仓库既有的纪律
    /// (同 `controlsDidBecomeVisible` 在预览里是空实现)。
    func syncAdSkipGate(adBreak: Bool) {
        NotchPlayback.skipGateLogger.info("gate: adBreak \(adBreak, privacy: .public) → \(adBreak ? "start" : "stop", privacy: .public)")
        adSkipGateTask?.cancel()
        adSkipGateTask = nil
        guard adBreak else {
            if adSkipAvailable { adSkipAvailable = false }
            return
        }
        adSkipAvailable = false
        let bundleID = LocalPlaybackSource.shared.lastResolvedBundleID
        adSkipGateTask = Task.detached(priority: .utility) { [weak self] in
            for round in 0 ..< YouTubeMusicAdSkipper.gateMaxRounds {
                if Task.isCancelled { return }
                let state = YouTubeMusicAdSkipper.probeSkippability(reportedBundleID: bundleID)
                let shows = YouTubeMusicAdSkipper.showsSkipButton(state)
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    if self.adSkipAvailable != shows {
                        self.adSkipAvailable = shows
                        NotchPlayback.skipGateLogger.info(
                            "gate: adSkipAvailable -> \(shows, privacy: .public) (state \(String(describing: state), privacy: .public))")
                    }
                }
                // 脚本没跑成(nil)就别再往返了:原因(不是浏览器 / 没授权 / 超时)不会在几秒内自己变好,
                // 而这一档已经按 fail-open 把键画出来了,用户按下去会走既有那条反馈路径。
                guard let state, state != .notInAd else { return }
                try? await Task.sleep(for: .seconds(YouTubeMusicAdSkipper.gateRetryDelay(after: state, round: round)))
            }
        }
    }

    /// 一次「跳过广告」正在跑(点 + 复核,约 1～3s)。期间再点忽略、键压淡 —— 第三版真机日志里用户连按几下,
    /// 几份并行的 run 交错,各自的复核读到的是别人点完的页面,横幅也叠着闪。
    @Published private(set) var skipAdInFlight = false

    /// 去点 YT Music 页面自己的「跳过广告」按钮。点 + 复核两次 AppleEvent 往返加 0.8s 等页面切换(正常 ~1.2s,
    /// 极端 6s 超时),放后台线程;结果回主线程用歌词行上的瞬态横幅回报(跟音量提示同一条通道):
    ///   * 点到了且复核广告已走 → 只给一下触觉(页面随即切正片,灵动岛按换曲流程自己刷新);
    ///   * 按钮还没出现 → 页面上读得到「N 秒后可跳过」就说「N 秒后可跳过」,读不到(不可跳过的广告)说
    ///     「这条广告还不能跳过」;
    ///   * 点了没生效 / 没有标签页在放广告 / 脚本没跑成 → 「没能跳过这条广告」。
    /// **每一种结果都有反馈**(2026-09-08 第二版):首版"点到了就只给触觉",用户真机遇到"点了页面没动、灵动岛也
    /// 一片安静"—— 触觉在 Mac 上几乎察觉不到,一颗键按下去没有任何可见反应是最坏的交互。
    /// 不套 `controlButton` 那层 Apple Music 自动化权限守卫:这是浏览器自动化,权限在 `BrowserAutomationPermission`
    /// 那一套里,没权限时 osascript 直接失败、走「没能跳过」那句。
    func skipAd() {
        guard !skipAdInFlight else { return }
        skipAdInFlight = true
        let bundleID = LocalPlaybackSource.shared.lastResolvedBundleID
        Task.detached(priority: .userInitiated) {
            let outcome = YouTubeMusicAdSkipper.skip(reportedBundleID: bundleID)
            await MainActor.run { [weak self] in
                self?.skipAdInFlight = false
                NotchPlayback.reportSkipOutcome(outcome)
            }
        }
    }

    private static func reportSkipOutcome(_ outcome: YouTubeMusicAdSkipper.Outcome?) {
        switch outcome {
        case .skipped?:
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        case .notYetSkippable(let seconds)?:
            let text = seconds.map { String(format: L10n.t("%@ 秒后可跳过"), String($0)) } ?? L10n.t("这条广告还不能跳过")
            NotchTransientCenter.shared.show(.init(icon: "forward.end", text: text, progress: nil))
        case .needsAccessibility?:
            // 系统自己那个"想要控制这台电脑"的对话框(带「打开系统设置」)+ 横幅说明为什么。ad-hoc 签名每次重装 cdhash
            // 都变,设置里的勾会失效,这一句在每次升级后第一次按时都会再见一次,见 AccessibilitySkipPress 头注。
            AccessibilitySkipPress.promptForTrust()
            NotchTransientCenter.shared.show(.init(icon: "hand.raised", text: L10n.t("跳过广告需要「辅助功能」权限"), progress: nil),
                                             for: 2.4)
        case .tabNotFrontmost?:
            NotchTransientCenter.shared.show(.init(icon: "macwindow", text: L10n.t("把 YouTube Music 标签页切到前面再试"), progress: nil),
                                             for: 2.4)
        case .clickedNoEffect?, .notFound?, nil:
            NotchTransientCenter.shared.show(.init(icon: "megaphone", text: L10n.t("没能跳过这条广告"), progress: nil))
        }
    }
    /// 展开区时间行中间要不要显示「歌词时间轴微调」(2026-09-01)。同上走这里现读——只影响
    /// `NotchScrubber` 内部时间行怎么排,不影响卡片高度,理由见
    /// `AppSettings.notchExpandedShowsLyricsOffset` 上面那条⚠️。
    @Published private(set) var showsLyricsOffsetControls: Bool = false
    /// 这首歌的歌词时间轴校正值(毫秒)+ 每次点击的步长——菜单栏面板那颗微调控件读的是
    /// 同一对值(`PlaybackCoordinator.trackLyricsOffsetMs`/`AppSettings.lyricsOffsetStepMs`),
    /// 这里镜像一份是因为 `NotchScrubber` 是 `private struct`、靠参数传值(不直接订阅
    /// PlaybackCoordinator/AppSettings),得有人先把值取到手。
    @Published private(set) var trackLyricsOffsetMs: Int = 0
    @Published private(set) var lyricsOffsetStepMs: Int = 200
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$currentLine.removeDuplicates().sink { [weak self] in self?.currentLine = $0 },
            // 主行画哪一句(见 displayLine 的注释):副行关着取 compactLine(唱完就切),副行开着取
            // currentLine(跟悬浮歌词同一套语义)。「卡拉OK效果」关着时再把**要画的那一行**压成整行
            // (`SyncedLyricLine.lineLevel`,2026-09-06):歌词行的逐字填色按 `displayLine?.words` 走,
            // 压成整行之后自然落到 `.plain` 那一档,渲染分支不用改。`currentLine` **不**压 —— 它只给
            // 均衡器条子当"此刻在唱哪个字"的节拍,那是跟着人声动的律动、不是染色,关掉卡拉OK填色不该
            // 让条子一起哑掉。
            Publishers.CombineLatest4(p.$compactLine, p.$currentLine, s.$notchLyricsKaraoke, s.$notchSecondaryLine)
                .map { compact, current, karaoke, secondary -> SyncedLyricLine? in
                    let line = secondary.showsSecondaryRow ? current : compact
                    return karaoke ? line : line?.lineLevel
                }
                .removeDuplicates()
                .sink { [weak self] in self?.displayLine = $0 },
            // 副行文本(2026-09-06):按四选一取下一句 / 当前句译文 / 当前句罗马音,空白算没有。
            Publishers.CombineLatest3(p.$currentLine, p.$nextLineText, s.$notchSecondaryLine)
                .map { current, next, secondary -> String? in
                    // 取值规则在 Core(`LyricSecondaryLine.secondaryText`),菜单栏副行读的是同一份。
                    secondary.secondaryText(currentLine: current, nextLineText: next)
                }
                .removeDuplicates()
                .sink { [weak self] in self?.secondaryText = $0 },
            s.$notchSecondaryLine.removeDuplicates().sink { [weak self] in self?.secondaryLine = $0 },
            p.$nextLineText.removeDuplicates().sink { [weak self] in self?.nextLineText = $0 },
            p.$nextLineSide.removeDuplicates().sink { [weak self] in self?.nextLineSide = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$isRadioTalkBreak.removeDuplicates().sink { [weak self] in self?.isRadioTalkBreak = $0 },
            p.$radioStationName.removeDuplicates().sink { [weak self] in self?.radioStationName = $0 },
            p.$radioStationImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.radioStationImage = $0 },
            p.$currentAdSlot.removeDuplicates().sink { [weak self] in self?.currentAdSlot = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
            p.$blurredArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.blurredArtworkImage = $0 },
            // 锚点本身低频(见类型注释),不去重(ProgressAnchor 非 Equatable,每次重锚
            // 也确实都是新值)。
            p.$anchor.sink { [weak self] in self?.anchor = $0 },
            p.$pausedPositionMs.removeDuplicates().sink { [weak self] in self?.pausedPositionMs = $0 },
            p.$currentDurationMs.removeDuplicates().sink { [weak self] in self?.currentDurationMs = $0 },
            // ⚠️ 2026-08-31:第二个输入从**悬浮歌词那边的** `followsCoverArt` 换成了灵动岛
            // 自己的 `notchCardStyle`。理由见 accent 的注释。
            Publishers.CombineLatest(p.$notchAccentColor, s.$notchCardStyle)
                .map { accent, style in style == .coverArt ? (accent ?? .white) : .white }
                .removeDuplicates()
                .sink { [weak self] in self?.accent = $0 },
            s.$notchCardStyle.removeDuplicates().sink { [weak self] in self?.notchCardStyle = $0 },
            s.$notchLeftEar.removeDuplicates().sink { [weak self] in self?.leftEar = $0 },
            s.$notchRightEar.removeDuplicates().sink { [weak self] in self?.rightEar = $0 },
            s.$notchLyricRowShowsArtwork.removeDuplicates().sink { [weak self] in self?.lyricRowShowsArtwork = $0 },
            s.$notchLyricRowArtworkPosition.removeDuplicates().sink { [weak self] in self?.lyricRowArtworkPosition = $0 },
            s.$notchLyricsAlignment.removeDuplicates().sink { [weak self] in self?.lyricsAlignment = $0 },
            // 字体三件(2026-09-09):派生 Font 不是 Equatable,不去重 —— 上游只在三个输入之一真变时才重算,本来就低频。
            s.$notchMainFont.sink { [weak self] in self?.mainFont = $0 },
            s.$notchMainDetailFont.sink { [weak self] in self?.mainDetailFont = $0 },
            s.$notchSecondaryFont.sink { [weak self] in self?.secondaryFont = $0 },
            s.$notchFontSize.removeDuplicates()
                .map { NotchLyricRowMetrics.mainLineHeight(fontSize: CGFloat($0)) }
                .removeDuplicates()
                .sink { [weak self] in self?.mainLineHeight = $0 },
            s.$notchExpandedShowsLyricsOffset.removeDuplicates().sink { [weak self] in self?.showsLyricsOffsetControls = $0 },
            p.$trackLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.trackLyricsOffsetMs = $0 },
            s.$lyricsOffsetStepMs.removeDuplicates().sink { [weak self] in self?.lyricsOffsetStepMs = $0 },
        ]
    }
}

// 用 AnyShapeStyle 抹掉三种截然不同的 ShapeStyle 具体类型(纯色/材质/渐变),让
// NotchHangingShape.fill(_:) 能用同一个属性统一接收,不需要写三份 if/switch 分支
// 各自调用不同重载的 .fill()。
extension NotchEarModule {
    /// ⚠️ 不能存成 `static let`/常量字典:`L10n.t` 要在每次取值时现算,存进去等于把首次访问
    /// 时的语言冻在里面(同 OverlayAlignmentSegmentedControl.label(for:) 那条)。
    var displayName: String {
        switch self {
        case .title: return L10n.t("歌名")
        case .artist: return L10n.t("歌手")
        case .album: return L10n.t("专辑")
        case .artwork: return L10n.t("封面")
        case .controls: return L10n.t("播放控制")
        case .elapsed: return L10n.t("已播时长")
        case .remaining: return L10n.t("剩余时长")
        case .none: return L10n.t("不显示")
        }
    }

    /// 这个模块要不要每秒重算一次(时间类才要)。用它把 TimelineView 圈在真正需要的那一格里 ——
    /// 顶行原本完全不随播放进度重绘,给不需要的模块也套一个周期时钟纯属白付。
    var isClock: Bool { self == .elapsed || self == .remaining }

    /// 这个模块塞进一只耳朵里**最少**要多宽。不含朝刘海那侧的 `earNotchInset`,也不含右耳
    /// 外缘那簇音浪 —— 那两样由 `NotchLyricsWindowController.minEarWidth(...)` 加。
    ///
    /// ⚠️ 判据是"**再窄就真的被裁**",不是"再窄就不好看"。宽度滑杆的下界完全按它算
    /// (`NotchLyricsWindowController.contentWidth`),往上多给一个 pt 就是替用户把岛的下限
    /// 抬高一个 pt —— 而这一整轮(2026-08-31)用户连提三次的都是同一件事:
    /// 「左右耳占用了很大空间」「支持调到更小」「这里还有很多位置,把最小调整为刚好放得下
    /// 一个封面,或者刚好放得下一个音浪就好」。
    ///
    /// ⚠️ **歌名 / 歌手 / 专辑给 0,这是有意的**。它们跑马灯,窄了只是滚得更勤、再窄就是
    /// 什么都不显示,**不会坏** —— 所以它们压根不该参与决定下限。第一版给过 24pt("可读窗口
    /// 还剩两个汉字"),那是拿"好看"当"会坏"用:它把默认配置(歌名/歌手)的下界钉在 300,而
    /// 用户看着 300pt 下那两个词旁边的空白说"这里还有很多位置"。给 0 之后,默认配置的下界
    /// 落到跟「不显示/不显示」同一个数(这台机器 251)—— 那时下限完全由右耳外缘那簇音浪撑着,
    /// 正是用户说的"刚好放得下一个音浪"。**代价说清楚**:拖到最底那一格,右耳的文字会被音浪
    /// 挤成 0 宽(左耳还剩 20pt 在滚)。这是滑杆上肉眼可见的连续过程,不是突变,用户想要文字
    /// 就往回拖两格 —— 把这个选择留给用户,而不是替他把区间截掉。
    ///
    /// 剩下三类是真的会被裁的,数字都是 2026-08-31 离屏实测:
    ///   - 三键 = 命中框 15 + 18 + 15,`spacing: 0`(见 `earControls` 的横向账)= **48**
    ///   - 时间 = 11.5pt 等宽数字下 "-12:34" / "-88:88" 实测 **39.0**
    ///   - 封面 = `NotchMetrics.earArtworkSide` 现算,**不给估计值**(这台机器菜单栏 32 → 22pt)
    func minEarContentWidth(contentTopInset: CGFloat) -> CGFloat {
        switch self {
        case .none, .title, .artist, .album: return 0
        case .controls: return 48
        case .artwork: return NotchMetrics.earArtworkSide(contentTopInset: contentTopInset)
        // ⚠️ 时间**不能**靠跑马灯兜底 —— 一秒一跳的数字滚起来根本读不了,所以这一档必须
        // 真的放得下。超过一小时的曲目("-1:23:45" 实测 50.1pt)在最窄处仍会滚:那是极少数,
        // 不值得为它把所有人的下限再抬 11pt。
        case .elapsed, .remaining: return 39
        }
    }

    /// 主要信息给 semibold + 更高不透明度,次要信息压一档。**样式跟着模块走、不跟着哪只耳朵走**:
    /// 把歌名换到右耳时它还是那个最显眼的东西,不会因为换了个位置就变次要。
    /// (这也正是改动前的样子:左耳歌名 semibold/0.85、右耳歌手 medium/0.6。)
    var isPrimary: Bool { self == .title }
}

extension NotchLyricRowArtworkPosition {
    var displayName: String {
        switch self {
        case .left: return L10n.t("左")
        case .right: return L10n.t("右")
        }
    }
}

extension LyricSecondaryLine {
    /// 「副行」四选一在设置页里的标签。「不显示 / 译文 / 罗马音」三个词跟悬浮歌词那边同键复用,
    /// 只有「下一句」是新键。
    var displayName: String {
        switch self {
        case .off: return L10n.t("不显示")
        case .nextLine: return L10n.t("下一句")
        case .translation: return L10n.t("译文")
        case .romanization: return L10n.t("罗马音")
        }
    }
}

extension NotchCardStyle {
    var displayName: String {
        switch self {
        case .solidBlack: return L10n.t("纯黑")
        case .frostedGlass: return L10n.t("磨砂玻璃")
        case .darkGradient: return L10n.t("深色渐变")
        case .coverArt: return L10n.t("跟随封面")
        }
    }

    // .coverArt 的真实渲染(封面模糊图)是在 NotchLyricsView.backgroundLayer 里单独
    // 处理的(ShapeStyle 表达不了 .blur()/.overlay() 这类 View 修饰符,没法塞进这个
    // AnyShapeStyle 里),这里给它的返回值只是"没有封面数据时的兜底"/"万一有别处意外
    // 读到这个属性"的合理默认——跟 darkGradient 用同一个值,不代表 .coverArt 的
    // 实际效果,不要在其它地方依赖这条分支来渲染 .coverArt。
    var fill: AnyShapeStyle {
        switch self {
        case .solidBlack:
            return AnyShapeStyle(Color.black)
        case .frostedGlass:
            return AnyShapeStyle(.thickMaterial)
        case .darkGradient, .coverArt:
            // 从左上到右下过渡,比纯黑多一点点冷色调层次感,又不像磨砂玻璃那样会透出
            // 桌面背景色。
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(hexWithAlpha: "#1C1A24FF", fallback: .black),
                        Color(hexWithAlpha: "#14212AFF", fallback: .black),
                        Color(hexWithAlpha: "#10161CFF", fallback: .black),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

// 灵动岛样式的内容视图。稳态(不 hover)常显"歌名+播放控制+当前歌词逐字高亮+专辑封面"
// 整套,hover 时在下面多展开一块"下一句歌词预览+迷你进度条"作为补充信息(参考 boring.notch
// 等实现的分层思路:稳态给完整基本信息,hover 给深化信息)。
//
// 分两/三行:
// - 顶行(高度 = controller.contentTopInset,等于刘海本身/无刘海屏幕的兜底值):物理
//   刘海是屏幕硬件层面真实不发光的区域,横向落在刘海宽度(controller.notchWidth)范围内
//   的内容会被真实挡掉,这一行中间让出 notchWidth 宽度的空当。空当里唯一的内容是一枚
//   **故意让硬件挡住**的品牌胶囊彩蛋(notchSeam,2026-09-03):只在截屏/录屏/投屏时露面。
//   左耳放歌名,右耳放 3 个播放控制按钮。
// - 歌词行:逐字高亮跟随播放进度扫过,技术上跟 LyricsOverlayView.mainLine 是同一套原理
//   (TimelineView 按渲染帧频现算 fillFraction+渐变着色),但不复用那份实现——这里没有
//   WrapLayout(单行不换行,超长直接硬裁),前景色固定白色,复杂度明显小一截,直接写一份
//   简化版更清楚,不值得为了复用去抽象共享代码。这一行的尾端(也就是稳态下卡片的右下角)
//   放一枚专辑封面小图,见 artworkThumbnail。
// - hover 展开时才出现的第三行:下一句歌词预览 + 一条迷你进度条。
//
// 整个卡片形状故意只在底部两个角做圆角、顶部两个角是直角(NotchHangingShape)——顶部
// 紧贴屏幕/刘海本身那条边,视觉上应该是直接从刘海"长出来"、跟屏幕顶边严丝合缝,而不是
// 一个悬空的、四角都带圆角的胶囊。
//
// 背景用磨砂玻璃(.thickMaterial,配 NotchLyricsWindow 里固定的 .darkAqua 外观)。刘海
// 本身所在的那一段空当(顶行中间)物理上不会显示任何像素,渲染成什么都无所谓,不需要跟
// 其余部分区别对待。
/// 灵动岛卡片的固定尺寸。
///
/// 放在泛型视图**外面**有两个原因:泛型类型不能有 static stored property(编译器直接
/// 拒绝);而且预览那边(SectionPreviewBars)要用同样的数值算容器高度,单独一个命名空间
/// 比从视图里翻出来更直白。
///
/// ⚠️ 跟 NotchLyricsWindowController 里的同名常量是同一套几何的两处描述,改一处要改两处。
enum NotchMetrics {
    /// 稳态歌词行的高度。真源在 Core 的 `NotchLyricRowMetrics.rowHeight`(2026-09-06 下沉,让 selftest
    /// 能钉"主行 + 副行 ≤ 行高"这条不变量),这里只是转发,调用点仍只需要认识 NotchMetrics 这一个入口。
    static var compactRowHeight: CGFloat { NotchLyricRowMetrics.rowHeight }
    /// 副行开着时歌词格里两行的高度与间距(2026-09-06):默认字号下 15 + 3 + 13 = 31,竖直居中塞进 44,上下各余 6.5。
    /// 同上转发 Core;改任何一个数都要先看 `twoLineStackHeight ≤ rowHeight` 那条 selftest。
    /// ⚠️ 主行那一格的高度 2026-09-09 起**随字号走**(`NotchPlayback.mainLineHeight`,公式只在 Core
    /// `NotchLyricRowMetrics.mainLineHeight(fontSize:)`),这里刻意不再提供一个"默认字号"的静态值 ——
    /// 留着它,下一个人会拿它去排版、在非默认字号下把主行裁掉一截。
    static var secondaryLyricLineHeight: CGFloat { NotchLyricRowMetrics.secondaryLineHeight }
    static var secondaryLineSpacing: CGFloat { NotchLyricRowMetrics.lineSpacing }
    /// 展开区的最大高度 / 按内容算的实际高度 —— 实现在 LyrimuseCore 的
    /// NotchExpandedMetrics(那边有完整的推导注释和 selftest 断言),这里只是转发,
    /// 让调用点仍然只需要认识 NotchMetrics 这一个入口。
    ///
    /// ⚠️ 2026-09-01 加了 `trackInfoHeight`/`hasLyricPreviewPossible` 之后:**以后再往
    /// `NotchExpandedMetrics` 加一个决定展开区高度的入参,这两个转发函数(以及
    /// `NotchLyricsWindowController.expandedExtraHeight`)都要跟着加**,同时别忘了在
    /// `NotchLyricsWindowController` 加一条对应的设置订阅——漏了订阅的表现不是崩,是
    /// "改完设置卡片高度纹丝不动,直到下次触发别的几何重算才追上",很难联想到订阅上。
    static func expandedExtraHeightMax(
        hasLyricPreviewPossible: Bool = true, hasControlsPossible: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        NotchExpandedMetrics.maxHeight(
            hasLyricPreviewPossible: hasLyricPreviewPossible, hasControlsPossible: hasControlsPossible,
            trackInfoHeight: trackInfoHeight)
    }

    static func expandedExtraHeight(
        hasLyricPreview: Bool, hasScrubber: Bool, hasControls: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        NotchExpandedMetrics.height(
            hasLyricPreview: hasLyricPreview, hasScrubber: hasScrubber, hasControls: hasControls,
            trackInfoHeight: trackInfoHeight)
    }

    /// 曲目信息头部(封面 + 歌名/歌手/专辑三个文字开关 + 右侧快捷操作)的高度。
    static func expandedTrackInfoHeight(
        showsArtwork: Bool, showsTitle: Bool, showsArtist: Bool, showsAlbum: Bool, showsActions: Bool = false
    ) -> CGFloat {
        NotchExpandedMetrics.trackInfoHeight(
            showsArtwork: showsArtwork, showsTitle: showsTitle, showsArtist: showsArtist, showsAlbum: showsAlbum,
            showsActions: showsActions)
    }

    // 曲目信息头部渲染(而非高度算术)要用到的几个尺寸,同样只转发 NotchExpandedMetrics
    // 那份定义,不重复写字面量。
    static var trackInfoSpacing: CGFloat { NotchExpandedMetrics.trackInfoSpacing }
    static var trackInfoTopSpacing: CGFloat { NotchExpandedMetrics.trackInfoTopSpacing }
    static var trackInfoArtworkSide: CGFloat { NotchExpandedMetrics.trackInfoArtworkSide }
    static var trackInfoLineSpacing: CGFloat { NotchExpandedMetrics.trackInfoLineSpacing }
    static var trackInfoActionsHeight: CGFloat { NotchExpandedMetrics.trackInfoActionsHeight }
    /// 没有曲目时 hover 展开只长出的那一块(`idleExpandedPanel`)的高度,同样只转发 Core 那份定义。
    static var idleExpandedPanelHeight: CGFloat { NotchExpandedMetrics.idlePanelHeight }

    // 收起态(没在播放)单侧耳宽:左耳只放音浪(约 14pt 宽)、右耳只放一枚小封面
    // (2026-08-19 用户拍板的 iPhone 灵动岛式极简形态,歌名/播放键都收进 hover 展开卡),
    // 34 = 内容 + 两侧呼吸空间。用在 NotchWindowRoot.cardWidth 的收起分支。
    static let collapsedEarWidth: CGFloat = 34
    // 以下同样是被泛型限制赶出来的固定尺寸(理由见类型注释)。
    // minWordDurationMs/wordEdgeSoftenBand 已随 wordGradient 收编进 WordKaraokeGradient
    // (2026-08-20)——别在这里再留一份"看着在生效"的死常量,将来改 KaraokeFill 会静默失真。
    static let artworkLyricSpacing: CGFloat = 10
    /// 歌词行右端渐隐带的宽度(2026-08-22 加,用户报「歌词有时候被封面挡住」)。
    ///
    /// 跟 artworkLyricSpacing 同为 10pt 不是巧合:渐隐带的作用就是把"硬切口紧贴封面"
    /// 这 10pt 间隙里的突变摊开成一段过渡。13pt 半粗体下约合 1.5 个拉丁字符,再宽会开始
    /// 吃掉能读的内容。完整判据(为什么只在停在开头时给)见 MarqueeMath.trailingFadeWidth。
    static let lyricEdgeFadeWidth: CGFloat = 10
    static let artworkCornerRadius: CGFloat = 5
    /// 两只耳朵**朝刘海那一侧**的内缩(2026-08-20 用户要求"歌手不要那么紧贴真实刘海")。
    ///
    /// 顶行的排布是「左耳 + 刘海宽的空当 + 右耳」严丝合缝地铺满,于是右耳的左边界正好
    /// 压在物理刘海的右沿上:装不下的歌手名(跑马灯,从左起)第一个字就贴着刘海黑边,
    /// 长歌名尤其明显(实测 "VALORANT/Grabbitz/bbno$")。左耳同理 —— 长歌名会一直顶到
    /// 刘海左沿。这 6pt 只吃进耳朵内部,不改耳宽、不动外缘的音浪/卡片边距,
    /// 代价是跑马灯可用宽度少 6pt(更容易触发滚动,而滚动本来就是长名字的正解)。
    static let earNotchInset: CGFloat = 6
    /// 卡片左右两侧的内边距(`topRow` 末尾那句 `.padding(.horizontal:)`)。
    ///
    /// ⚠️ 这是**单侧**值。三处按它算:那两句 padding、耳宽公式 `(卡片宽 − 刘海宽 − 2×它) / 2`、
    /// 以及宽度下限 `NotchLyricsWindowController.contentWidth`。2026-08-31 之前三处各写一份
    /// 字面量(10 / 20 / 20),提成常量是因为下限现在要跟着耳朵配置现算,再抄一份必然漂。
    static let cardHorizontalPadding: CGFloat = 10
    /// 耳朵里「可配模块」与外缘那簇音浪之间的间距(2026-08-31 之前叫 rightEarContentSpacing——
    /// 音浪贴哪只耳朵可配之后,两只耳朵都用得到这个间距,改成不带方位的名字)。同样要进宽度
    /// 下限的账(见 `minEarWidth`)。
    static let earWaveSpacing: CGFloat = 5
    /// 耳朵里那枚封面的边长(收起态右耳那枚、稳态耳朵配成「封面」时那枚,同一档)。
    ///
    /// ⚠️ **三处必须用这一份**:两处渲染 + 一处宽度下限(`NotchEarModule.minEarContentWidth`)。
    /// 下限要是按一个"够宽的估计值"给,选了封面的耳朵就会白占几个 pt —— 而这一整轮改动
    /// (2026-08-31)要消掉的正是这种白占。
    /// 上限 32 那一档是歌词行末尾那枚,不走这里(耳朵只有 contentTopInset 那么高,放不下 32)。
    static func earArtworkSide(contentTopInset: CGFloat) -> CGFloat { max(16, contentTopInset - 10) }
    /// 没有曲目时左耳里那枚 App 图标的边长(2026-09-07)。比封面那一档**大 4pt**:macOS 的 App 图标
    /// 位图自带约 12% 的透明外边(1024 画布里圆角方块只占 824),同一边长下它看起来比封面缩了一圈,
    /// 补 4pt 让肉眼看到的方块跟封面那枚差不多大;上限钉在顶行高减 4,矮刘海机型上不顶到边。
    /// 不进宽度下限的账:它只在没有曲目时出现,而且比任何模块都窄(≤ 26pt)。
    static func earAppIconSide(contentTopInset: CGFloat) -> CGFloat {
        min(contentTopInset - 4, earArtworkSide(contentTopInset: contentTopInset) + 4)
    }

    /// 广告期间左耳那枚喇叭的**字号**(2026-09-09)。SF Symbol 按字号渲染、不是按边长,所以这里
    /// 给的不是 side —— 取封面那一档边长的 0.56 倍(约 13pt),视觉重量跟它要替代的那枚 23pt
    /// 封面小图接近,又不至于在只有一个符号时显得过重。下界 11 兜住极矮刘海。
    static func earAdIconSize(contentTopInset: CGFloat) -> CGFloat {
        max(11, earArtworkSide(contentTopInset: contentTopInset) * 0.56)
    }
}

/// NotchLyricsView 需要从"承载它的那个东西"那里知道的全部几何/状态 —— 一共就这几项。
///
/// 抽成协议是为了让**同一份视图**既能装进真窗口,也能装进「外观」页的预览里。
/// 预览曾经是另写的一份简化渲染(一个圆角矩形 + 一行居中文字),那跟真实灵动岛差得远:
/// 真的那个有左耳歌名、右耳三个播放控制、中间给物理刘海让出的空当、歌词行末尾的封面
/// 缩略图、以及 hover 才展开的第三行。两份渲染必然越漂越远,不如让预览用真的那一份。
@MainActor
protocol NotchChromeSource: ObservableObject {
    /// 收起态(没在播放且没 hover):窗口缩到刘海本身大小,内容整套摘掉。
    var isCollapsed: Bool { get }
    var isExpanded: Bool { get }
    /// 物理刘海的宽度,顶行中间要给它让出空当。无刘海屏幕是 0。
    var notchWidth: CGFloat { get }
    var contentTopInset: CGFloat { get }
    /// 卡片稳态 / 展开态的**真实**宽(经耳朵下限与「展开 ≥ 稳态」)。歌词行按形态各自定宽、以卡片中心为锚,
    /// 换形态时在原地交叉淡入淡出而不是跟着卡片边沿平移(2026-09-06,见 `NotchLyricsView.lyricRowSlot`)。
    /// 真窗口是控制器 recomputeGeometry 算出的那两个数;编辑台由 NotchEditorStage 用同一套公式算好推进来。
    var steadyCardWidth: CGFloat { get }
    var expandedCardWidth: CGFloat { get }
    /// 展开区里那行"下一句歌词预览"会不会渲染 —— 决定要不要给它留高度。
    /// 曲目级信号(这首歌有没有歌词),不是"此刻有没有下一句",理由见
    /// NotchMetrics.expandedExtraHeight 的注释。
    var expandedShowsLyricPreview: Bool { get }
    /// 展开区里那条迷你进度条会不会渲染(= 这首歌有没有时长)。
    var expandedShowsScrubber: Bool { get }
    /// 此刻有没有一首曲目(有歌名/歌手,或者正在放广告)。
    ///
    /// 决定歌词行整行要不要渲染 —— 压根没有曲目时那一行是**全空**的(两个占位 ♪ 已经
    /// 按同一个判据留白了),44pt 白占着正是用户 2026-08-21 说的"占用空间"。
    /// 刻意不看"在不在播":暂停中仍然有曲目,歌名/歌词/封面都该照常显示。
    var hasTrack: Bool { get }
    /// 此刻在放的是不是广告(2026-09-08)。决定展开态**头部整块不画**(见 `showsExpandedTrackInfo`):
    /// 广告期间歌名位只会写「广告中」、歌手/专辑一律留空(`metadataText` 的既有规矩),四颗快捷键里
    /// 「搜索歌词」「显示歌词」无物可指 —— 画出来就是一块只有一个灰词的空头部,正是用户 2026-09-08
    /// 圈图说的「太呆了」。广告态的状态文字与倒计时改由歌词行接管(`adStatusColumn`)。
    /// 真窗口 = 控制器镜像的 `isAdBreakNow`(它同时也是 `isCollapsed` 的第三个输入);预览恒 false。
    var isAdBreakNow: Bool { get }
    /// 用户要不要看歌词行(`AppSettings.notchShowLyrics`)。关掉时卡片只剩顶行那一条,
    /// 退化成贴着刘海的状态栏。
    ///
    /// ⚠️ 走 chrome 而不是让视图直接读 AppSettings:卡片高度(NotchWindowRoot)和内容渲染
    /// (NotchLyricsView)必须用同一个值,而 NotchWindowRoot 只观察 controller、不观察
    /// AppSettings(那是 2026-08-19 性能审计定的:别让无关设置写入打醒整卡)。真窗口那一侧
    /// 由控制器订阅设置后 @Published 出来,预览那一侧现读即可。
    var showsLyrics: Bool { get }
    /// 要不要显示播放指示条(音浪)。同上,走 chrome 不直接读 AppSettings——它同时影响
    /// 渲染(NotchLyricsView.topRow)和宽度下限(NotchLyricsWindowController.minEarWidth)。
    var showsEqualizer: Bool { get }
    /// 音浪贴哪只耳朵的外缘。同上。
    var equalizerEar: NotchEqualizerEar { get }
    /// 用户要不要看展开区那行「下一句歌词预览」(`AppSettings.notchExpandedShowsNextLine`)。
    /// 跟 `expandedShowsLyricPreview`(这首歌有没有下一句)是两回事,两者都成立才画,见
    /// `showsExpandedLyricPreview`。同上,走 chrome 不直接读 AppSettings。
    var expandedShowsNextLine: Bool { get }
    /// 用户要不要看展开区那排播放控制键(`AppSettings.notchExpandedShowsControls`)。
    /// 跟 `expandedShowsNextLine`/`expandedShowsScrubber` 不一样的是:控制键不看曲目级
    /// 数据信号(播放/暂停/上一首/下一首任何时候都能点),纯粹是一个用户开关,不需要像
    /// `showsExpandedLyricPreview` 那样跟"这首歌有没有下一句"再取一次交集——这个属性
    /// 本身就是渲染判据,不用另包一层。
    var expandedShowsControls: Bool { get }
    /// 展开区「曲目信息头部」四个独立开关(封面/歌名/歌手/专辑),同上均走 chrome 现读设置。
    /// ⚠️ 这枚封面(`expandedTrackInfoShowsArtwork`)**不是**歌词行末尾那枚
    /// (`lyricRowShowsArtwork`/`lyricRowArtworkPosition`,走 `NotchPlayback` 而不是这个
    /// 协议)——两枚封面是独立开关,可以同时开,详见 `AppSettings.notchExpandedShowsArtwork`
    /// 上面那段⚠️的落点简史。
    var expandedTrackInfoShowsArtwork: Bool { get }
    var expandedTrackInfoShowsTitle: Bool { get }
    var expandedTrackInfoShowsArtist: Bool { get }
    var expandedTrackInfoShowsAlbum: Bool { get }
    /// 头部右侧那排「快捷操作」(搜索歌词 / 显示歌词 │ 设置 / 关闭,2026-09-07)要不要画。
    /// 跟头部四项同一条链路:它参与头部高度(`max` 里的第三块),所以必须走"镜像 + 重算几何"。
    var expandedShowsQuickActions: Bool { get }
    func setExpanded(_ expanded: Bool)
    /// 快捷操作里那颗 ✕:关掉「灵动岛歌词」总开关。真窗口走 `setVisible(false)`(跟设置页开关、菜单栏
    /// 面板同一个唯一入口),预览里是空实现 —— 预览卡整块 `allowsHitTesting(false)`,本来也点不到。
    func closeFromQuickAction()
}

extension NotchChromeSource {
    /// 那一行「正在播放」的歌词行(`lyricRow`,44pt 高)到底画不画 —— 用户关掉「显示歌词」时
    /// 稳态确实该隐藏(退化成贴着刘海的状态栏,这是那个开关本来的意思);但**展开之后必须
    /// 照常画**(2026-08-31 实测坐实的回归:第一版只放开了「下一句预览」这一行,忘了这一行
    /// 也被同一个开关挡着,表现是"展开后有下一句、却看不到正在播放的当前行"这种更怪的
    /// 半吊子状态——用户原话「展开只有一行歌词了，正在播放的那行被你搞没了」)。跟
    /// `showsExpandedLyricPreview` 同一个道理:展开是用户主动选的动作,不该被"平时不想被
    /// 歌词挡视线"这个理由连累。高度预留(`cardHeight`)和实际渲染(NotchLyricsView 的
    /// `if controller.showsLyricRow`)必须用同一个值。
    var showsLyricRow: Bool { hasTrack && (showsLyrics || isExpanded) }

    /// 展开区里那行「下一句歌词预览」到底画不画 —— 只看这首歌**有没有歌词**,不受
    /// 「显示歌词」那个开关影响(2026-08-31 用户要求:关掉稳态那一条歌词行之后,指向展开的
    /// 效果得跟开着歌词时完全一样)。`showsLyrics` 只管稳态那 44pt 的行(见 `showsLyricRow`),
    /// 不该连带影响展开区——展开是用户主动选的动作,他既然已经点开了,就不该因为"平时不想被
    /// 歌词挡视线"这个理由被拿掉。高度预留和实际渲染必须读同一个值,否则要么多留一行的空白、
    /// 要么把它裁掉半截。
    ///
    /// `expandedShowsNextLine`(2026-09-01)是这个功能第一次有用户开关:以前无条件跟着
    /// `expandedShowsLyricPreview` 这个曲目级数据出现,现在两者都成立才画。别把它塞进
    /// `NotchMetrics.expandedExtraHeight` 的入参列表——那会让"这一段到底该不该占高度"有
    /// 两个真源(一个在这里判、一个在 height() 里判),这里判完的**结果**才是 height() 该吃
    /// 的唯一输入。
    var showsExpandedLyricPreview: Bool { expandedShowsLyricPreview && expandedShowsNextLine }

    /// 展开区「曲目信息头部」到底画不画——只要四个开关(封面/歌名/歌手/专辑)有一个开着,
    /// 且此刻有曲目(没曲目时四者都是空的,画一块空头部没有意义,理由同
    /// `showsLyricRow` 对 `hasTrack` 的处理),且**不在广告中**(2026-09-08:广告期间头部能画的只有
    /// 一个灰词「广告中」+ 两颗没对象的快捷键,整块让位,状态由歌词行接管,见 `isAdBreakNow`)。
    /// 广告态切换只改这里的算术、不改窗口几何 —— 窗口常驻最大尺寸(`expandedExtraHeightMax`),
    /// 跟 `hasTrack` 那条空闲面板路一样不需要 `recomputeGeometry`。
    var showsExpandedTrackInfo: Bool {
        hasTrack && !isAdBreakNow
            && (expandedTrackInfoShowsArtwork || expandedTrackInfoShowsTitle
                || expandedTrackInfoShowsArtist || expandedTrackInfoShowsAlbum
                // 快捷操作是头部的第五项(2026-09-07):四项全关、只开它时头部就是一条按钮行。
                || expandedShowsQuickActions)
    }

    /// 曲目信息头部按当前设置算出来的高度,`0` = 不画(见 `showsExpandedTrackInfo`)。
    /// 单独抽出来是因为 `cardHeight` 和 `NotchLyricsWindowController.expandedExtraHeight`
    /// 都要用同一个值——两处各自现算的话,当天早些时候「左右耳」那次教训会原样重演一遍。
    var expandedTrackInfoHeight: CGFloat {
        guard showsExpandedTrackInfo else { return 0 }
        return NotchMetrics.expandedTrackInfoHeight(
            showsArtwork: expandedTrackInfoShowsArtwork,
            showsTitle: expandedTrackInfoShowsTitle,
            showsArtist: expandedTrackInfoShowsArtist,
            showsAlbum: expandedTrackInfoShowsAlbum,
            showsActions: expandedShowsQuickActions)
    }

    /// 曲目信息头部要占的**总**高度(内容本身 + 上下各一份间距)——头部现在是独立渲染在
    /// 歌词行**之上**的一块(2026-09-01 用户要求"新字段都在最上面,歌词行/下一句挪到
    /// 最下面"),不再是 `expandedContent` 内部的第一个子视图,所以它自己的 `.frame(height:)`
    /// 得包含"离下面歌词行的间距"这一截——跟 `NotchExpandedMetrics` 里
    /// `lyricPreviewBlock`/`scrubberBlock` 那种"值本身含尾随间距"是同一个惯例。
    /// `expandedContent` 自己那份 `NotchMetrics.expandedExtraHeight(...)` 调用因此永远传
    /// `trackInfoHeight: 0`——这部分高度已经在这里算过一次,不能算两次。
    ///
    /// ⚠️ **上面那份间距**是 2026-09-01 同一天补的第二轮:第一版只留了尾随间距,头部紧挨在
    /// 上面的 topRow 下面、零间距,用户报"标题首行贴到上面边了"。跟 `NotchExpandedMetrics.height`
    /// 的注释同步——两份间距都在 `trackInfoSpacing * 2` 里算过,渲染那侧
    /// (`NotchLyricsView.trackInfoHeader`)只需要在内容顶部真的加一次 `.padding(.top:)`
    /// 把上面那份"用出来",不需要在这里再调这个函数的返回值分配比例。
    var expandedTrackInfoHeaderHeight: CGFloat {
        let height = expandedTrackInfoHeight
        return height > 0 ? height + NotchMetrics.trackInfoTopSpacing + NotchMetrics.trackInfoSpacing : 0
    }

    /// 卡片当前高度 —— **全仓唯一一份公式**,真窗口(NotchWindowRoot)和设置页编辑台
    /// (NotchEditorStage)都读它。
    ///
    /// ⚠️ 2026-08-31 抽出来的:在此之前这个公式在那两处各写了一遍,而它的入参一路从 1 个
    /// (isCollapsed)涨到 4 个(再加 hasTrack / isExpanded 那一组 / showsLyrics)。本章
    /// 设计决策里早写过同类教训:"两处各自判断必然漂,而漂的表现是行不见了高度还留着、
    /// 或反过来把行裁掉半截"。加第四个入参那天正好把它收成一份。
    var cardHeight: CGFloat {
        if isCollapsed { return contentTopInset }
        // 没有曲目(2026-09-07,决策 #31):展开只长出「空闲面板」那一块。此前走下面的通式 ——
        // 歌词行本来就被 hasTrack 守着不留,但展开区照常按"三键 + 进度条"留 59～76pt,而那块内容
        // (`cardBodyLayer`)整个被 hasTrack 挡掉,结果 hover 上去长出一大块什么都没有的黑;用户报
        // 「没有播放的展开状态不是很友好」。高度预留与实际渲染(`idleExpandedPanel` 的 frame)读同一个值。
        if !hasTrack {
            return contentTopInset + (isExpanded ? NotchMetrics.idleExpandedPanelHeight : 0)
        }
        return contentTopInset
            // 稳态歌词行要不要留高度,见 showsLyricRow(展开时哪怕关着「显示歌词」也要留)。
            + (showsLyricRow ? NotchMetrics.compactRowHeight : 0)
            + (isExpanded
               ? NotchMetrics.expandedExtraHeight(
                   hasLyricPreview: showsExpandedLyricPreview,
                   hasScrubber: expandedShowsScrubber,
                   hasControls: expandedShowsControls,
                   trackInfoHeight: expandedTrackInfoHeight)
               : 0)
    }
}

struct NotchLyricsView<Chrome: NotchChromeSource>: View {
    @ObservedObject var controller: Chrome
    /// 「发现新播放器」提示的状态源(2026-09-11)。**这里不订阅**(不是 @ObservedObject),只往下传给两个宿主
    /// 子视图(`NotchIdleEarIconHost` / `NotchIdlePanelHost`)各自订阅 —— 同 NotchTransientCenter 那条纪律,
    /// 提示挂上 / 撤掉只失效那一块。默认是惰性替身(编辑台预览永远看不到提示),真窗口传 `.shared`。
    var prompt: NotchUnknownPlayerPrompt = .inert
    // 不整对象订阅 PlaybackCoordinator/AppSettings —— 见 NotchPlayback 的注释。
    // NotchTransientCenter 也不在这里订阅:banner 只被歌词行消费,订阅下沉到
    // NotchTransientHost 子视图,横幅出现/消失只失效那一行,不打醒整卡。
    // 进度条拖动的三个交互状态(@GestureState/宽度/悬停)同理下沉进 NotchScrubber ——
    // 原来挂在这里,拖动时每个指针事件都整卡重估。
    @StateObject private var playback = NotchPlayback()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 出场动画期间内容的透明度(NotchWindowRoot 在那 0.3s 里改,默认 1)。只作用于内容 VStack,
    /// 背景层不受影响 —— 先看到卡片形状从刘海长出来、再看到字,见 NotchRevealShape 头注。
    @Environment(\.notchRevealContentOpacity) private var revealContentOpacity
    /// 宿主是否已替卡片裁好外形(真窗口 true / 编辑台 false),见 EnvironmentValues.notchHostClipsCard。
    @Environment(\.notchHostClipsCard) private var hostClipsCard
    /// 这一块内容此刻是不是可见的那份(见 cardBodyLayer);藏着的那份停掉逐字填色的表。
    @Environment(\.notchCardLayerActive) private var cardLayerActive
    /// 这块内容所在显示器的像素倍率 —— 只给 `idleAppIcon` 算"要几像素的位图"用(2026-09-07)。
    @Environment(\.displayScale) private var displayScale
    /// 快捷操作里此刻被指到的那颗键(2026-09-09,见 `QuickActionTooltipOverlay`);nil = 指针不在任何一颗上。
    @State private var hoveredQuickAction: QuickActionHint?
    /// 真正画出来的那一条。跟 `hoveredQuickAction` 分开存是为了那 260ms 的首次延迟(扫过一排键时
    /// 不该一路闪气泡);存整个 hint 而不只是文案,是因为气泡要**定位到那颗键**,文案和落点必须同源。
    @State private var shownQuickActionTooltip: QuickActionHint?

    // 稳态歌词行的固定高度——跟 NotchLyricsWindowController.contentSize.height 保持
    // 一致(两个文件都描述同一个窗口的几何,这点数值耦合是设计使然,不值得为两个常量
    // 专门抽一个共享类型)。展开时窗口总高度会多出 expandedExtraHeight,这部分空间全部
    // 交给下面的展开内容,歌词行本身高度不跟着变。


    var body: some View {
        GeometryReader { proxy in
            // topRow 外层还有 .padding(.horizontal, 10)(左右各 10pt),这里要把这 20pt
            // 也算进去,否则「两只耳朵 + 刘海空当」正好等于 proxy.size.width 之后再叠加
            // padding,会让 topRow 的实际宽度比 GeometryReader 分配的宽度多出整整 20pt:
            // ZStack 会跟着这个更宽的子视图一起变宽,导致背景形状 NotchHangingShape 收到
            // 的 rect 比窗口真实宽度多 20pt,只有当这多出来的 20pt 沿某一侧溢出时,那一侧
            // 的底部圆角才会显示为直角(圆角计算本身没错,只是形状宽度比窗口多算了一截,
            // 超出边界的部分被窗口硬裁掉,裁到的正好是圆弧那一小段)。
            let earWidth = max(0, (proxy.size.width - controller.notchWidth
                                   - NotchMetrics.cardHorizontalPadding * 2) / 2)
            ZStack(alignment: .top) {
                backgroundLayer(size: proxy.size)
                // 收起态铺一层纯黑盖住卡片样式自己的底(2026-08-19 用户要求):没在播放时
                // 卡片就是挂在真刘海边上的一小块,深色渐变/磨砂/封面模糊底在真刘海的
                // 纯黑旁边都是"看得出来的一块灰"——收起就该和机器刘海一个颜色,融为一体。
                // 用 opacity 而不是 if/else 换填充:跟卡片收放同一条弹簧渐变,不硬切。
                // 2026-09-06 从 `NotchHangingShape.fill(.black)` 改成纯 `Color`:形状填充是 CG 路径
                // 光栅化、卡片每变一次尺寸就重画一遍整卡,而 `Color` 只是一层 backgroundColor;
                // 圆角交给外层那道统一的 clipShape(理由同 backgroundLayer 里的打底层)。
                // 2026-09-07 加上**压根没有曲目**这一档(用户圈图:关了「暂停时收起」的机器上,没放歌时
                // 卡片按稳态尺寸挂着、底还是深色渐变/封面兜底那块灰,「整体颜色也要和真实刘海保持一致,
                // 完全融合在一起」):没有曲目就没有封面可跟、没有内容要衬,底色只剩"像不像刘海"一个
                // 标准 —— 跟收起态同一个理由,只是收起态还要求缩尺寸,这里尺寸由 collapsesWhenPaused 管、
                // 底色不再看它。hover 展开时同样黑底(没曲目时展开区本来就是空的)。
                // 2026-09-09 再加**广告期间**这一档(用户圈图:「广告时候的灵动岛的配色帮我设置为
                // 和机器刘海一样的纯黑色」):理由跟上面没有曲目那一档同构 —— 广告没有封面可跟
                // (`accent` 退回默认冷色、`coverArt` 风格退回那块灰),底色于是既衬不了内容、也
                // 代表不了这一刻在放什么,只剩"像不像刘海"一个标准。广告一结束自动退回原风格,
                // 跟着同一条弹簧渐变淡回去,不硬切。
                Color.black
                    .opacity(controller.isCollapsed || isIdleNoTrack || controller.isAdBreakNow ? 1 : 0)
                // 刘海空当里的品牌胶囊(notchSeam)直接钉在 ZStack 顶部**居中**,不再画在顶行的 HStack 里
                // (2026-09-06,用户报「暂停状态展开的动画会把中间那个 Lyrimuse 图案漏出来一会」)。
                // 逐帧抓窗坐实:当时顶行是 collapsedRow / topRow 两个视图在 VStack 里整行互换,SwiftUI 对
                // "正在离场的那一行"按它离场时的耳宽(34pt)布局、对"刚插入的那一行"按目标耳宽(146.5pt)
                // 布局,两行都从卡片左沿起排 —— 于是各自那枚胶囊一枚偏左 ~15pt、一枚偏右 ~100pt,都跑出了
                // 刘海的遮挡范围,在屏幕上"漏出来一会"(帧 2～13,约 200ms)。胶囊挂在 ZStack 上,位置只由
                // ZStack 的居中对齐决定,跟耳朵怎么换、怎么长都无关。同日随后顶行也收成了一个持久的 HStack
                // (见 topRow 头注),整行互换本身已不存在,但胶囊仍留在这里 —— 它本来就不属于哪只耳朵。
                // 顶行里原来放胶囊的位置只留同宽的空当(notchGap)。
                notchSeam
                    .frame(height: controller.contentTopInset)
                    .opacity(revealContentOpacity)
                // 收起态(没在播放、没 hover)卡片缩到刘海大小,这里把常显内容整套摘掉而不是
                // 指望卡片太小自然裁掉——避免文字/按钮在收缩过程中被挤压变形,收起就是纯粹
                // 一块背景,跟真实刘海融为一体。
                //
                // ⚠️ 但"摘掉"不能是硬切。2026-08-16 之前这里没有 transition,内容在收起的
                // 第一帧就整块消失,而卡片还要再花 0.45 秒缩回去 —— 观感是"字先没了,黑块才
                // 慢慢收",两段动作对不上。加一个跟卡片同一条弹簧驱动的淡出 + 轻微上缩
                // (anchor 在顶部,因为卡片是从顶边往上收的),内容就跟着卡片一起"被吸回刘海"。
                VStack(spacing: 0) {
                    // 顶行占菜单栏那一条高度,收起后跟菜单栏齐平、不额外占屏。两种形态:
                    // 收起(没在播放)= iPhone 灵动岛式极简(左耳封面、右耳音浪,2026-08-19
                    // 用户拍板,歌名/播放键都收进 hover 展开卡);稳态/展开 = 歌名 + 播放键。
                    // ⚠️ 两种形态是**同一个** topRow 按 isCollapsed 换耳朵里的内容,不是两个视图
                    // 在这里 if/else 互换(2026-09-06 起,理由见 topRow 头注)。
                    topRow(earWidth: earWidth)
                        .frame(height: controller.contentTopInset)
                    // 顶行以下的一切(曲目信息头部 / 歌词行 / 展开区)2026-09-06 起**不在这个 VStack 里**,
                    // 而是作为外层 ZStack 的 overlay 各自定宽、定 y、以卡片中心为锚(见 cardBodyLayer)。
                    // 卡片的高度本来就由 NotchChromeSource.cardHeight 给 NotchWindowRoot 钉死,不靠这里堆出来。
                }
                // 出场动画的内容淡入(2026-09-03):值来自 NotchWindowRoot 的 keyframeAnimator,
                // 平时恒为 1;背景层不套它,所以卡片形状先长出来、字后到。
                .opacity(revealContentOpacity)
                // 卷进顶行:锚点放顶部,内容一边淡出一边往上缩,跟卡片高度收缩同一条弹簧。
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }
            // 顶行以下的内容(曲目信息头部 / 两份歌词行变体 / 展开区)作为 ZStack 的 **overlay**、顶部居中,
            // 理由见 cardBodyLayer。
            // ⚠️ 必须是 overlay 而不是 ZStack 的子视图:展开宽那些在稳态下比卡片宽,做子视图会把 ZStack
            // 撑到展开宽,而 GeometryReader 把内容摆在左上角 —— 整卡内容右移 (展开宽 − 稳态宽) / 2
            // (2026-09-06 逐帧抓窗撞到过两次:第一次是歌词行的定宽容器,第二次就是这里)。overlay 不参与
            // 父布局,居中对齐的参照始终是卡片本身。
            //
            // ⚠️ hasTrack 这一条(2026-08-21)必须跟 NotchChromeSource.cardHeight 里那个同款判断成对出现:
            // 压根没有曲目时歌词行是**全空**的,44pt 白占着就是用户报的"占用空间"。一处改一处不改的表现是
            // "行不见了高度还留着"或反过来把行裁掉半截。
            .overlay(alignment: .top) {
                if !controller.isCollapsed, controller.hasTrack {
                    cardBodyLayer
                        // 出场动画的内容淡入(2026-09-03):值来自 NotchWindowRoot 的 keyframeAnimator,平时恒为 1。
                        .opacity(revealContentOpacity)
                } else if !controller.isCollapsed {
                    // 没有曲目:hover 展开只长出一块「空闲面板」(2026-09-07,决策 #31),高度与
                    // `NotchChromeSource.cardHeight` 的 !hasTrack 分支读同一个值。跟 cardBodyLayer 里
                    // 各块同一套做法 —— 常驻、定宽、定 y、只切透明度(NotchCardLayerActive),稳态下
                    // 它透明地挂在顶行下面、被外层裁剪裁掉,展开时在最终位置原地淡入。
                    // 有「发现新播放器」的信任提议挂着时(2026-09-11,决策 #37)这一块换成提议的变体,
                    // 同高同排法,由宿主子视图自己订阅、自己切,见 NotchIdlePanelHost。
                    NotchIdlePanelHost(prompt: prompt, tint: accentOrWhite) { idleExpandedPanel }
                        .frame(width: controller.expandedCardWidth,
                               height: NotchMetrics.idleExpandedPanelHeight, alignment: .top)
                        .padding(.top, controller.contentTopInset)
                        .modifier(NotchCardLayerActive(active: controller.isExpanded))
                        .opacity(revealContentOpacity)
                }
            }
            // 展开态内容(下一句预览+进度条)本身没有另外裁一次形状——如果只让背景那一层
            // fill 是圆角、前景内容不跟着裁,内容溢出圆角边界时会带着直角"戳"出卡片轮廓。
            // 这里对整个 ZStack 统一裁一次,保证任何内容都不会越出这个卡片的真实外轮廓。
            // 2026-09-06 起背景打底层与收起态黑罩都是不带形状的纯色,底部圆角**只**靠这一道
            // (或宿主那道,见下)—— 别再把它们改回 NotchHangingShape.fill,那是每帧重画整卡。
            //
            // 宿主已经在卡片外面裁过同一个形状时(真窗口的 NotchWindowRoot,那道 NotchRevealShape
            // 终态与这里重合)这一道就省掉:两层 mask 在尺寸动画里每帧各重设一次路径,是白付的。
            // 这个环境值对某个宿主是常量(见其 doc),分支不会在运行期切换、不会重建子树。
            .modifier(NotchCardClip(enabled: !hostClipsCard))
        }
        // 「跳过广告」那颗键的门槛轮询,起停挂在这里(2026-09-11)。
        //
        // ⚠️ 判据是 **chrome 的 `isAdBreakNow`**,不是 `playback.isCurrentTrackAdBreak` —— 两者对真窗口
        // 是同一件事,但预览 chrome 的 `isAdBreakNow` 恒 false,而 `NotchPlayback` 在预览里照样订阅真的
        // `PlaybackCoordinator`:挂在后者上的话,设置页只要开着,那块编辑台预览就会跟着真广告每 5 秒对
        // 用户的浏览器发一次 AppleScript(真机日志坐实过 —— 每一行都打了两遍)。理由同
        // `controlsDidBecomeVisible` 在预览里是空实现:预览不产生副作用。
        //
        // `.onAppear` 那一下是为了"窗口刚出现时已经在放广告"这种情形 —— `onChange` 只在值变化时触发。
        .onAppear { playback.syncAdSkipGate(adBreak: controller.isAdBreakNow) }
        .onChange(of: controller.isAdBreakNow) { _, on in playback.syncAdSkipGate(adBreak: on) }
        // 一次性诊断(2026-09-11,用户报「稳态那枚提示不实时更新,展开一次才出来」)。
        // 问题只可能落在两处:body 压根没被这次翻转叫醒(那 onChange 也不会响),或者 body 看见了、
        // 但三道门里有一条此刻是假的(那 canSkipAd 响、hint 不响)。两条探针正好把这两种分开。
        .onChange(of: playback.canSkipAd) { _, value in
            NotchPlayback.skipGateLogger.info("""
                view: canSkipAd=\(value, privacy: .public) expanded=\(controller.isExpanded, privacy: .public)                 showsLyrics=\(controller.showsLyrics, privacy: .public) hint=\(showsAdSkipHint, privacy: .public)
                """)
        }
        .onChange(of: showsAdSkipHint) { _, value in
            NotchPlayback.skipGateLogger.info("view: adSkipHint=\(value, privacy: .public)")
        }
        // 2026-08-16 删掉了这里原来那个 .onHover。它覆盖的范围比卡片大一圈(预览那边
        // 早就记录过同一个现象),窗口改成常驻最大尺寸之后这变成了实打实的 bug:鼠标划过
        // 卡片下方的透明区也会展开。命中判定和触觉反馈都移到 NotchWindowRoot,那里拿
        // 精确坐标跟卡片矩形直接比;预览那边本来就走自己的 onContinuousHover。
        // hover 时给卡片一点投影,让它从桌面/窗口背景上"浮起来"。收起态不给 —— 那时它
        // 假装自己是刘海的一部分,投影会立刻暴露这是个窗口。
        // 2026-08-17 去掉了展开态那圈投影。它本来的用意是"hover 时让卡片从背景上浮起来",
        // 但实际观感是整个卡片外侧糊着一层灰 —— 灵动岛的设计语言是**从刘海长出来**,
        // 不是一张悬空的卡片,投影反而把这件事拆穿了。
        //
        // ⚠️ 将来如果要把投影加回来,窗口**必须**按投影半径留出四周余量,否则阴影会被
        // 窗口的矩形边界硬裁,在底部两个圆角外侧留下两块直角的深色残影(2026-08-17 用户
        // 报过一次"左右角怎么还有个虚的直角",离线渲染对照复现确认就是这个)。当时的
        // 修法是把窗口宽高各加一圈,见 NotchLyricsWindowController.recomputeGeometry ——
        // 投影既然撤了,那圈余量也跟着撤了,别只加回投影不加余量。
    }

    // 2026-08-02 新增"跟随封面"背景——跟"歌词窗口"的 artworkBackground(LyricsWindowView.swift)
    // 完全同一套效果(封面整图放大、高斯模糊、压一层半透明黑),只是缩小到灵动岛胶囊
    // 尺寸;封面数据本来就已经在转发给 PlaybackCoordinator 供"歌词窗口"用,这里直接复用
    // 同一个数据源,不需要新开一条取图链路。读的是解码缓存 playback.artworkImage 而不是
    // 原始字节,理由见 PlaybackCoordinator.artworkImage 的注释。
    //
    // ShapeStyle(NotchCardStyle.fill)表达不了 .blur()/.overlay() 这类 View 修饰符,
    // 所以 .coverArt 这个风格不走"给 NotchHangingShape 填色"这条路,改成在背景层直接
    // 塞一张 Image。
    //
    // ⚠️ .scaledToFill() 之后、.clipShape 之前必须显式钉一次 .frame(width:height:)
    // ——2026-08-02 实测排查坐实(用像素级采样确认过,不是肉眼被模糊柔化骗了),踩了
    // 三版才找对根因:
    // 第一版完全没裁——四个角全变直角。
    // 第二版换成 `.clipped()`——`.clipped()` 只会裁成矩形,压根不认识
    //   NotchHangingShape 这个"顶直角、底圆角"的形状,自然还是直角。
    // 第三版改成 `.clipShape(NotchHangingShape(...))` 直接套在 Image 上,以为这样
    //   总该认得形状了,肉眼截图看起来也像是圆角——但对左下角做像素级采样(逐行扫描
    //   card 区域与背景的分界线 x 坐标,检查是否随 y 增大而右移)后发现分界线纹丝不动,
    //   证明那次"看起来圆"其实是模糊本身的柔和渐变骗了肉眼,底层裁剪仍然是直角。
    // 真正原因是本文件顶部 topRow/earWidth 那处注释描述过的同一类问题:
    // `.scaledToFill()`(即 aspectRatio(contentMode: .fill))为了保证"图片撑满、
    // 不留缝隙"而向布局系统请求一个可能比 ZStack 实际可见尺寸更大的 frame(维持宽高比
    // 需要在某个方向溢出、裁掉多余部分)。`.clipShape` 是按它**紧邻**的上一个 View
    // 的 frame 算 `path(in rect:)` 的,而不是按外层 GeometryReader/窗口的真实尺寸——
    // 如果这张 Image 协商到的 frame 比灵动岛胶囊本身大一圈,NotchHangingShape 画出来的
    // 圆角就落在了这个偏大的矩形边缘,而不是胶囊真正的可见边缘,可见区域里看到的只是
    // 这个偏大矩形的中间一截,自然还是直角。修法:`.scaledToFill()` 之后先用
    // `.frame(width: size.width, height: size.height)` 把协商结果显式钉回胶囊真正的
    // 尺寸(GeometryReader 的 proxy.size,从 body 传进来),`.clipShape` 才会在正确的
    // 边界上计算圆角。
    //
    // 没有封面数据(这首歌还没解析出封面/collector 还没查到/本来就没有)时退回
    // NotchCardStyle.darkGradient 的固定渐变——不会露出空白背景,也不需要用户在"没有
    // 封面"和"其它三个固定风格"之间多做一次选择。
    //
    // 模糊半径比"歌词窗口"artworkBackground 的 60 小得多——那边画布常年好几百 pt 高,
    // 60pt 模糊半径只占画布的一小部分,还能看出封面本身的色块层次;灵动岛稳态高度只有
    // 76pt、宽度 360pt(约 4.7:1 的又矮又宽比例),照搬同一个绝对数值相对尺寸夸张太多,
    // 2026-08-02 实测排查坐实:哪怕换一张色彩很丰富的封面(比如粉色玩具马配红白条纹的
    // 封面),灵动岛这里也会被抹成跟其它封面几乎分不出来的统一深灰色,颜色信息基本损失
    // 殆尽,违背了"跟随封面颜色"这个功能本身的目的。调小到 20——仍然是明显的"模糊",
    // 但能留住封面主色调之间可辨认的差异。
    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        // 优先用高清替代(highResArtworkImage):系统那份对网易云永远只有 100×100,云盘
        // 没匹配上的歌还是灰底音符占位图 —— 缓存里解析到真封面时背景该铺真封面。nil 时
        // 回落系统那份,跟歌词窗口封面卡同一套取舍(见 highResArtworkImage 的注释)。
        // 铺的是 PlaybackCoordinator 预烘焙好的模糊图(2026-08-19 性能审计落地),不再在
        // 视图层挂 .blur(radius: 20) 活滤镜 —— 那是合成期滤镜,这个窗口播放期间因逐字
        // 填色/音浪/跑马灯几乎永动,GPU 每次重合成都对同一张图重算同一个模糊。烘焙源在
        // 数据层就是 highResArtworkImage ?? artworkImage(高清替代优先的口径不变),且
        // clampedToExtent 让边缘实心 —— 原来靠打底层遮的羽化带不复存在,打底层保留只为
        // 烘焙空窗(封面刚到、模糊图晚几十 ms)兜底。
        if playback.notchCardStyle == .coverArt,
           let image = playback.blurredArtworkImage {
            ZStack {
                // 不透明打底,烘焙空窗期(封面刚到、模糊图晚几十 ms)先露它,见上。
                //
                // ⚠️ 是一块**纯色**,不是 darkGradient 那道渐变,也不套 NotchHangingShape(2026-09-06
                // 动画性能专项):这一层平时整个压在封面模糊图底下、一个像素都看不见,却在 hover
                // 展开/收起时随卡片尺寸每帧重画 —— Time Profiler 实测(4 次 hover 展开)主线程
                // 24% 的忙时是 CoreGraphics 在给这道看不见的渐变做 rgba64 轴向着色
                // (`ripc_DrawShading` → `rgba64_shade_axial_RGB`,964×382px 每帧一遍)。纯色的
                // `Color` 视图落成一个只有 backgroundColor 的 CALayer,尺寸变化零重画;底部圆角由
                // 外层 ZStack 那道统一的 clipShape 负责,这里不必再裁。颜色取渐变的中间一档。
                Color(hexWithAlpha: "#14212AFF", fallback: .black)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    // 数值跟 PlaybackCoordinator 算 accentForCoverArtBackground 时估算
                    // 背景亮度用的是同一个常量(LocalPlaybackSource.
                    // notchCoverArtOverlayOpacity)——两处对不上,文字对比度的估算就会
                    // 跟实际渲染出来的背景脱节。
                    .overlay(Color.black.opacity(LocalPlaybackSource.notchCoverArtOverlayOpacity))
                    // 这里原来还有一道 `.clipShape(NotchHangingShape)`(决策 5 那三版排查的产物)。
                    // 2026-09-06 拿掉:body 末尾已对整个 ZStack 统一裁同一个形状、同一个 rect(后加
                    // 的,见那里的注释),这道是重复的 —— 而每道 clipShape 都是一层 mask,尺寸动画
                    // 期间每帧要重设路径(`updateClipShapes`/`MaskLayer.setClips` 占 SwiftUI 渲染
                    // 时间的约四分之一)。上面那次 `.frame(width:height:)` 钉尺寸仍然必要:
                    // scaledToFill 协商出的偏大 frame 不钉回来,外层裁剪同样会裁在错的边界上。
                    // 换歌/高清替代到货都会产出一张**新的**烘焙图实例(NSImage 指针比较),
                    // 一条过渡覆盖原来 artworkData 字节比较 + highRes 指针比较两条 ——
                    // 顺带省掉原来每次 body 对几十~几百 KB Data 的逐字节 memcmp。
                    .animation(.easeInOut(duration: 0.5), value: playback.blurredArtworkImage)
            }
        } else {
            NotchHangingShape(bottomCornerRadius: 20)
                .fill(playback.notchCardStyle.fill)
        }
    }

    /// 压根没有曲目。读 controller 那一份而不是自己再从 playback 算一遍 —— 卡片高度
    /// (NotchWindowRoot.cardHeight)也要用同一个判据决定歌词行占不占 44pt,两处各算一遍
    /// 必然漂,而漂的表现是"行不见了但高度还留着"或反过来把行裁掉半截。
    /// 跟菜单栏面板的同名属性是同一套语义(MenuBarPanel.isIdleNoTrack)。
    private var isIdleNoTrack: Bool { !controller.hasTrack }

    /// 刘海空当(物理刘海遮挡处)里的品牌胶囊彩蛋(2026-09-03,借鉴清单 #17,用户拍板)。
    ///
    /// 肉眼永远看不到——那块被硬件挡死;只在截全屏 / 录屏 / 投屏或镜像到无刘海显示器时
    /// 露出来,像给刘海贴了个牌子。两个条件缺一不画:
    ///  - `notchWidth > 0`:无刘海屏幕的兜底几何和外接屏上的镜像副本都是 0,画了就真的能
    ///    看见,那就不是彩蛋而是一块白疤。
    ///  - `hasTrack`:会议里没放歌、灵动岛停在空闲黑块时,共享画面顶上不该挂着牌子(用户
    ///    选了"只在有曲目时画",而不是参考实现那种常驻)。
    /// 「截屏/录屏时隐藏」开着时整窗不进截图,不必另加开关。高度按顶行让 8pt 边、夹在
    /// 14～22pt(矮刘海机型顶行可能不到 26pt)。装饰元素,读屏不念。
    /// 顶行中间刘海那一段的**占位**:只有宽度,什么都不画。胶囊本体(notchSeam)自 2026-09-06 起钉在 body 的
    /// ZStack 顶部居中(理由见那里),顶行只需要把这段宽度让出来。
    private var notchGap: some View {
        Spacer(minLength: 0).frame(width: controller.notchWidth)
    }

    private var notchSeam: some View {
        ZStack {
            if controller.notchWidth > 0, controller.hasTrack {
                Text(verbatim: "Lyrimuse")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(seamTextColor)
                    .padding(.horizontal, 9)
                    .frame(height: min(22, max(14, controller.contentTopInset - 8)))
                    .background {
                        // 底色跟灵动岛当前主色走(同歌名/音浪那份 accent),上半截叠一层淡白渐变
                        // 加 0.5pt 浅描边当光泽——纯色胶囊贴在纯黑刘海里像一块色卡,加点高光才
                        // 读得出"是个立体的牌子"(2026-09-03 用户要求"颜色跟着灵动岛走,稍微
                        // 加一点光泽有区分度")。
                        Capsule().fill(accentOrWhite)
                            .overlay {
                                Capsule().fill(LinearGradient(
                                    colors: [.white.opacity(0.42), .white.opacity(0.10), .clear],
                                    startPoint: .top, endPoint: .center))
                            }
                            .overlay { Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5) }
                    }
                    .accessibilityHidden(true)
            }
        }
        .frame(width: controller.notchWidth)
    }

    /// 胶囊字色按底色的 WCAG 相对亮度选黑/白:亮度 > 0.179(黑白两侧对比度相等的临界点)
    /// 时黑字更清楚,否则白字。复用 LocalPlaybackSource 描边取色那套亮度公式,别再写一份。
    private var seamTextColor: Color {
        guard let ns = NSColor(accentOrWhite).usingColorSpace(.sRGB) else { return .black }
        let lum = LocalPlaybackSource.relativeLuminance(
            r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
        return lum > 0.179 ? .black : .white
    }

    /// 播放指示条(音浪)是不是配给了这只耳朵,而且这只耳朵没选控制键——三键本身已经在
    /// 报播放状态(播放时画 ⏸),音浪摆在旁边是同一件事说两遍,而且窄宽度下(耳朵最窄
    /// 70pt,减内缩 6 之后 64pt)刚好放得下三键的 48pt,再挤进音浪的 14+5 就超了。这是
    /// "音浪贴这只耳朵外缘"唯一的例外,跟哪只耳朵无关。
    private func showsEqualizer(on side: NotchEqualizerEar, module: NotchEarModule) -> Bool {
        controller.showsEqualizer && controller.equalizerEar == side && module != .controls
    }

    private var equalizerBars: some View {
        EqualizerBars(color: accentOrWhite, isPlaying: playback.isPlayingNow,
                      amplitude: Self.vocalAmplitude(at:))
    }

    /// 顶行 —— 收起态与稳态/展开态**共用这一个 HStack**(2026-09-06 起)。
    ///
    /// 此前是两个视图 `collapsedRow` / `topRow` 在 VStack 里按 isCollapsed 整行互换。逐帧抓窗坐实了
    /// 那样做的代价(用户报「暂停状态展开的动画会把中间那个 Lyrimuse 图案漏出来一会」,见 body 里
    /// notchSeam 那段注释):整行互换时 SwiftUI 对**离场的那一行**按离场时的耳宽布局、对**刚插入
    /// 的那一行**按目标耳宽布局,两行都从卡片左沿起排,于是 hover 展开的头 ~200ms 里两行的内容各在
    /// 错的位置上淡入淡出 —— 胶囊漏出刘海只是最显眼的一例,耳朵里的音浪 / 文字同样在错位。
    ///
    /// 现在顶行是一个**持久**的 HStack,两只耳朵的 `.frame(width: earWidth)` 随卡片连续动画;收起/稳态
    /// 之间变的只是"这只耳朵此刻显示哪个模块、音浪在不在这侧"两个**值**:
    ///  - 收起:左耳固定封面、右耳固定音浪(2026-08-19 用户拍板的 iPhone 灵动岛式极简,歌名/播放键都
    ///    收进 hover 展开卡);
    ///  - 稳态/展开:按设置(`leftEar` / `rightEar` / 音浪贴哪侧)。
    /// 两种形态下模块相同时(比如用户本来就左耳封面、右耳音浪)视图身份完全不变 —— 连淡入淡出都没有,
    /// 封面和音浪只是跟着耳朵边沿平移;模块不同时,切换发生在**耳朵内部**、贴着耳朵外缘,不再整行错位。
    /// 音浪在暂停时是静止的矮条(EqualizerBars 自己按 isPlaying 处理),收起态的封面是"刚才在放什么"的
    /// 余韵;没封面时左耳留空,不画占位方块(理由同 artworkThumbnail)。
    ///
    /// 布局细节两条,收起与稳态**一致**、不随状态变:朝刘海那一侧内缩 `earNotchInset`(2026-08-20 用户
    /// 要求「歌手不要那么紧贴真实刘海」;收起态 34pt 的耳朵减掉 6 还剩 28,放得下 23pt 的封面 / 14pt
    /// 的音浪);左耳内容靠左外缘、右耳靠右外缘(05 章「指示条贴外缘,收放切换时不横跳」)。
    private func topRow(earWidth: CGFloat) -> some View {
        let collapsed = controller.isCollapsed
        let leftModule: NotchEarModule = collapsed ? .artwork : playback.leftEar
        let rightModule: NotchEarModule = collapsed ? .none : playback.rightEar
        let equalizerOnLeft = !collapsed && showsEqualizer(on: .left, module: playback.leftEar)
        let equalizerOnRight = collapsed || showsEqualizer(on: .right, module: playback.rightEar)
        return HStack(spacing: 0) {
            // 左耳:模块 + (可选)音浪。音浪贴哪只耳朵可配之后(2026-08-31,原来写死在右耳),
            // 这里跟下面右耳是完全对称的结构——只是音浪在外缘,外缘在左耳是"最左",
            // 所以音浪排在模块**前面**(下面右耳反过来,音浪排在模块后面)。
            // `.none` 不渲染(它是一条空的跑马灯,在 HStack 里会把音浪推到另一头去;要"贴外缘"
            // 靠的是外面那句 .frame(maxWidth:alignment:))。
            HStack(spacing: NotchMetrics.earWaveSpacing) {
                if equalizerOnLeft {
                    equalizerBars
                }
                // 压根没有曲目时左耳固定画 App 图标(2026-09-07 用户要求「左侧显示我们的图标」),
                // 不看配置:这时候除「播放控制」外每个模块都是空的(歌名/歌手/专辑/时长在 metadataText /
                // clockText 里对 isIdleNoTrack 一律回空串,封面为 nil 整块不画),左耳原本就是一片
                // 空白 —— 图标占的是这片空白,不是抢走谁的位置;左耳配了「播放控制」的,没有曲目时
                // 三键也无物可控,一并让位。有曲目的那一刻它让回配置的模块。
                if isIdleNoTrack {
                    // 2026-09-11 起经 idleEarIcon 再包一层:有「发现新播放器」的信任提议挂着时换成那个播放器的图标。
                    idleEarIcon(alignment: .leading)
                } else if controller.isAdBreakNow {
                    // 广告期间左耳那枚喇叭(2026-09-09,用户圈图:「在左耳那边加上一个广告的标识
                    // 图标」)。**不看配置、也不看这一格原本有没有内容**。这一档当天走了三步:
                    // 第一版做成"只占空白"(为了不推翻 09-08「广告期间封面位保留播放器给的图」
                    // 那条拍板)→ 问用户"要不要任何广告都固定显示",答"任何"→ 他随后又扩成
                    // 「只要识别到是广告的话,封面部分都用这个替代」。所以 09-08 那条拍板**整条**
                    // 被他自己推翻了,不止左耳:全 App 四个当前曲目封面位(左耳、歌词行末尾、
                    // 歌词窗口封面卡、菜单栏面板那枚)广告期间一律让位给同一枚喇叭,清单与
                    // "为什么灵动岛展开头部那枚不用改"见 05 章「广告态」⑦。
                    //
                    // 让位的代价说清楚:左耳配了「播放控制」的用户,广告期间那三颗键会被这枚图标
                    // 顶掉 —— 可接受,因为 hover 展开卡的进度条下方本来就有一整排三键(广告期间
                    // 照旧渲染,见 adStatusColumn 头注),能力没丢,只是位置变了。这跟决策 #30
                    // (没有曲目时左耳固定画 App 图标、配了播放控制的一并让位)是同一个取舍。
                    // 收起态自动一并覆盖:上面 `leftModule` 在收起时固定是 `.artwork`。
                    adBreakEarIcon(alignment: .leading)
                } else if leftModule != .none {
                    earContent(leftModule, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 内缩必须在 .frame(width:) **之前** —— 之后加等于把耳朵整体变宽 6pt,
            // 三段就不再严丝合缝铺满,背景形状/刘海空当会跟着错位。
            .padding(.trailing, NotchMetrics.earNotchInset)
            .frame(width: earWidth)

            // 刘海本身的空当——物理硬件不发光区域。那枚肉眼看不见的彩蛋(notchSeam)2026-09-06 起
            // **不画在这一行里**,而是钉在 body 的 ZStack 顶部居中,这里只留空当的宽度(理由见 notchGap)。
            notchGap

            // 右耳:模块 + (可选)音浪(2026-08-19 设计评审的终形,用户逐步拍板;
            // 2026-08-31 从"音浪固定贴右耳"改成可配置贴哪只耳朵/要不要显示):控制键全部
            // 退场 —— 岛是 hover 展开的,光标到达耳朵之前岛已经展开,完整三键就在展开卡
            // 的进度条下方(见 expandedContent),耳朵里再留一枚播放键是重复目标。默认配置
            // (左歌名、右歌手 + 音浪贴右耳)因此跟改动前逐像素一致——只是现在两者都能关/换边。
            HStack(spacing: NotchMetrics.earWaveSpacing) {
                if rightModule != .none {
                    earContent(rightModule, alignment: .trailing)
                }
                if equalizerOnRight {
                    equalizerBars
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, NotchMetrics.earNotchInset) // 理由同左耳,见 earNotchInset
            .frame(width: earWidth)
        }
        .padding(.horizontal, NotchMetrics.cardHorizontalPadding)
    }

    // MARK: - 耳朵里的可配模块

    /// 一只耳朵里画什么。`alignment` 是**耳朵**的属性(左耳靠左、右耳靠右),不是模块的。
    ///
    /// ⚠️ 三条约束,每条都对应本仓一处既有做法:
    ///
    /// ① **只有时间类模块才套 `TimelineView`。** 顶行原本完全不随播放进度重绘,给歌名/歌手/
    ///    专辑也套一个时钟纯属白付(这个仓库为"整卡跟着高频源重绘"做过一整轮性能审计,见
    ///    NotchPlayback 的头注)。
    ///
    /// ② **没有锚点就不排表**,静态画冻结值 —— 照搬本仓既有的**存在性门**(`NotchScrubber`
    ///    和歌词窗口那条进度都是 `if let anchor` 才挂表)。暂停/没在播放时 `LocalPlaybackSource`
    ///    会把 anchor 置 nil,于是这一格退回 `pausedPositionMs` 的冻结读数、一次表都不排。
    ///    ⚠️ 这条不是可选优化:设置页那块编辑台渲染的是**同一份**视图,而它的替身 chrome 把
    ///    `hasTrack` 写死 true、`isCollapsed` 写死 false —— 没有这道门,只要有人把耳朵配成时间类,
    ///    设置页开着就会每秒空转一次,哪怕根本没在放歌。
    ///
    /// ③ **周期起点按锚点对齐到"曲目位置的整秒"**,步长按倍速取 `1/rate`(见
    ///    `NotchTimeFormat.clockSchedule`)。钉在**墙钟**整秒上是不行的:曲目位置的整秒边界跟
    ///    墙钟整秒无关,两者的相位差在一条锚点的生命周期里是**常量** —— 也就是说 hover 展开时
    ///    耳朵可能整首歌都比正下方那条迷你进度条**慢 1 秒**(耳朵 1:23、进度条 1:24 长期并排),
    ///    而不是偶尔闪一下。对齐之后两处读数同源同相。
    ///    ⚠️ 别顺手把 `clockText` 里的 `Date()` 换成 `context.date`:对齐之后 tick 恰好落在边界上,
    ///    用调度时刻采样有可能因为亚毫秒取整读回旧的那一秒;实际派发比调度晚几毫秒,`Date()`
    ///    反而落在边界的正确一侧。
    @ViewBuilder
    private func earContent(_ module: NotchEarModule, alignment: Alignment) -> some View {
        switch module {
        case .artwork:
            earArtwork(alignment: alignment)
        case .controls:
            earControls(alignment: alignment)
        case .elapsed, .remaining:
            if let anchor = playback.anchor {
                TimelineView(NotchTimeFormat.clockSchedule(for: anchor)) { _ in
                    earText(clockText(module), module: module, alignment: alignment)
                }
            } else {
                earText(clockText(module), module: module, alignment: alignment)
            }
        case .title, .artist, .album, .none:
            earText(metadataText(module), module: module, alignment: alignment)
        }
    }

    /// 耳朵里那枚封面小图(2026-08-31)。
    ///
    /// ⚠️ 尺寸走**收起态那一枚**的公式(`contentTopInset − 10`,约 23pt),**不是**歌词行末尾
    /// 那枚 32pt 的:耳朵只有 `contentTopInset` 那么高,32pt 塞进来上下一点余量都不剩。当年
    /// 「封面放不进耳朵」的实测结论(见 artworkThumbnail 上方)量的正是 32pt 那一档。
    ///
    /// 没有封面数据时**整块不画**(不摆占位方块)—— 跟歌词行末尾那枚同一个取舍,理由见那边。
    @ViewBuilder
    private func earArtwork(alignment: Alignment) -> some View {
        if let image = radioTalkStation?.image ?? playback.highResArtworkImage ?? playback.artworkImage {
            artworkThumbnail(
                image,
                side: NotchMetrics.earArtworkSide(contentTopInset: controller.contentTopInset))
                .frame(maxWidth: .infinity, alignment: alignment)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
        }
    }

    /// 广告期间左耳那枚喇叭(2026-09-09)。
    ///
    /// 符号沿用 `adStatusColumn` 和「没能跳过这条广告」瞬态横幅里的同一枚 `megaphone.fill` ——
    /// 同一件事在这张卡上不该出现两种画法。前景色也跟那一行同口径(`accentOrWhite` 七成不透明
    /// + 同一道投影);广告期间底已经是纯黑(见 body 里那层 `Color.black`),七成白在纯黑上足够清楚。
    ///
    /// 不接点击:它是个状态标记,不是按钮 —— 广告期间真正能点的那件事(「跳过广告」)有自己的键,
    /// 在展开卡的状态行右侧,见 `adStatusColumn`。读屏也不念(装饰元素):同一行的「广告中 · 还剩
    /// 0:20」已经把这件事说清楚了,再念一遍是重复。
    @ViewBuilder
    private func adBreakEarIcon(alignment: Alignment) -> some View {
        let side = NotchMetrics.earAdIconSize(contentTopInset: controller.contentTopInset)
        let hint = showsAdSkipHint
        HStack(spacing: side * 0.22) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: side, weight: .semibold))
            if hint {
                // 比喇叭小一号、再淡一点:它是**附注**(这条广告能跳),不是这一格的主语(在放广告)。
                // 符号跟展开卡那颗「跳过广告」键同一枚 `forward.end.fill` —— 同一件事在这张卡上
                // 不该出现两种画法(同喇叭那条)。
                // 0.78:喇叭 ~13pt 时这枚约 10pt,跟悬浮窗那排非主按钮的 10.5pt 同量级(那是这个
                // 仓库验过的"小到不挡视线、又还认得出"的下界),再小就开始糊成一个点。
                Image(systemName: "forward.end.fill")
                    .font(.system(size: side * 0.78, weight: .semibold))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(accentOrWhite.opacity(0.7))
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        .frame(maxWidth: .infinity, alignment: alignment)
        // 喇叭本身是装饰(同一行的「广告中 · 还剩 0:20」已经说清楚了);带上提示之后这一组就有了
        // 独立信息 —— 稳态下它**是**读屏用户唯一能知道"这条能跳"的地方,所以这时候要念。
        .accessibilityHidden(!hint)
        .accessibilityLabel(hint ? L10n.t("这条广告可以跳过") : "")
    }

    /// 稳态下要不要在左耳那枚喇叭旁边补一枚「可跳过」提示(2026-09-11,用户:「这个按钮目前只在展开
    /// 状态有;帮我在灵动岛歌词行那里也加一个,虽然移动上去就展开了,但是可以起到提示可以跳过的作用」)。
    ///
    /// 两道门,都是"别把同一件事说两遍":
    ///  ① **展开态不画** —— 那时 `adStatusColumn` 右端就是那颗真的「跳过广告」键,再加一枚图标是重复。
    ///  ② **稳态歌词行画得出来时也不画** —— 开着「显示歌词」的人,稳态那份 `lyricRow` 渲染的就是
    ///     `adStatusColumn`(带真键),同理重复。关着的人稳态只剩顶行,那枚喇叭是广告这件事在卡上
    ///     唯一的落点,提示只能挂在它旁边(用户正是这一档:`notchShowLyrics = 0`)。
    ///
    /// 刻意**只是个标记、不接点击**:稳态下指针一压上来卡片就展开了,这一格根本没有"被点到"的时机,
    /// 做成按钮只会是又一段永不触发的死代码(同喇叭那条、同悬浮窗那排按钮为什么不是 Button)。
    private var showsAdSkipHint: Bool {
        playback.canSkipAd && !controller.isExpanded && !controller.showsLyrics
    }

    /// 没有曲目时左耳里的 App 图标(2026-09-07,用户圈图要的「左侧显示我们的图标」)。
    ///
    /// 图标取 `NSApplication.shared.applicationIconImage`(bundle 里的 AppIcon.icns),但**不**直接
    /// `Image(nsImage:).resizable()` 缩 —— 第一版这么做,用户当天就报「很有锯齿感」:1024px 那档位图被
    /// SwiftUI 一步线性采样到 ~52px,圆角和音符边缘全是台阶。现在按「pt 边长 × 显示倍率」预先光栅化
    /// 一次(`NotchIdleAppIcon.bitmap`,高质量重采样、按像素边长缓存),`Image(decorative:scale:)` 逐像素
    /// 贴上去,运行期零缩放。不裁圆角、不描边、不投影 —— 它自己就是一枚带圆角方块的 macOS 图标,再套
    /// 一层 `artworkThumbnail` 那圈处理会把它的形状裁掉一截。
    ///
    /// 只是一个"我在这儿"的标记,不接点击:没有曲目时点它能做的事(打开歌词窗口 / 设置)在
    /// hover 展开卡和菜单栏里都有,这里再接一遍是重复目标;读屏也不念(装饰元素)。
    /// 尺寸见 `NotchMetrics.earAppIconSide`。
    @ViewBuilder
    private func idleAppIcon(alignment: Alignment) -> some View {
        let side = NotchMetrics.earAppIconSide(contentTopInset: controller.contentTopInset)
        let scale = max(1, displayScale)
        Group {
            if let bitmap = NotchIdleAppIcon.bitmap(pixelSide: Int((side * scale).rounded())) {
                Image(decorative: bitmap, scale: scale)
            } else {
                // 理论上到不了:CGContext 建不出来才会 nil。退回原图,至少有东西。
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityHidden(true)
    }

    /// 耳朵里那一排播放控制键(2026-08-31 用户点名要加)。
    ///
    /// ⚠️ 尺寸沿用 `controlButton` 的 `primary` 两档**默认值**(侧键 glyph 9.5 / 命中 15,
    /// 播放键 11 / 18)—— 那正是 2026-08-19 把三键从耳朵挪进展开卡之前、耳朵里用的那一档,
    /// 默认值从那次搬家起就一直留在代码里没有调用方,现在重新有了。展开卡里那一排是 22pt,
    /// 比这里大一号,是刻意的(那儿是真正会被点的地方)。
    ///
    /// 横向账(min 宽度下也要放得下):三键 15+18+15 = 48pt,`spacing: 0` —— 命中框本身就比
    /// 图标大一圈(15 的框装 9.5 的图标,两侧各 2.75pt),再加间距会白白撑宽。而耳朵最窄是
    /// **70pt**(`NotchLyricsWindowController.minEarWidth`,宽度滑杆的下界就是按它算的),
    /// 减掉朝刘海那侧 6pt 的内缩还有 64pt,放得下。右耳还要再减音浪那 14pt + 5pt 间距 = 45pt
    /// —— 放不下,所以右耳选控制键时**音浪让位**(见 topRow 那段⚠️)。
    private func earControls(alignment: Alignment) -> some View {
        HStack(spacing: 0) {
            controlButton("backward.fill") { MusicPlaybackController.previousTrack() }
            controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill", primary: true) {
                // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
                PlaybackCoordinator.shared.userTogglePlayPause()
            }
            controlButton("forward.fill") { MusicPlaybackController.nextTrack() }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    /// 三个元数据模块的取值。
    ///
    /// ⚠️ 三条既有规矩原样保留,别在加模块时顺手丢掉:
    ///   ① **广告插播**:歌名位写「广告中」,不展示广告物料的名字(2026-08-19 用户拍板);
    ///      歌手/专辑在广告期间一律留空 —— 广告没有"歌手"可言,画上去是假信息。
    ///   ② **压根没有曲目时留白**,不摆 ♪(2026-08-21 用户要求"那个无意义的音符不要占位置")。
    ///   ③ 歌名为空时的 ♪ 兜底只在"有曲目但拿不到歌名"这种边角才到得了,保留。
    private func metadataText(_ module: NotchEarModule) -> String {
        if isIdleNoTrack { return "" }
        let isAd = playback.isCurrentTrackAdBreak
        // 口白(2026-09-11,用户:「口白期间,可以恢复到原本电台的封面以及名字」):歌名位换成台名,
        // 歌手/专辑留空 —— 理由跟广告那条一模一样,口白没有"歌手"可言,画上去是假信息。
        // 抓不到台卡(`radioTalkStation` 为 nil)就整条不生效,还显示上一首,见 RadioStationCard。
        let station = radioTalkStation
        switch module {
        case .title:
            if isAd { return L10n.t("广告中") }
            if let station { return station.name }
            return playback.title.isEmpty ? "♪" : playback.title
        case .artist: return (isAd || station != nil) ? "" : playback.artist
        case .album: return (isAd || station != nil) ? "" : playback.album
        // 非文本模块不走这条路(见 earContent 的分发),这里只是把 switch 补齐。
        case .artwork, .controls, .elapsed, .remaining, .none: return ""
        }
    }

    /// 口白期间顶替曲目卡的台名 / 台标。抓不到台卡就是 nil —— 那时一切照旧(还显示上一首),
    /// 宁可保持现状也不要编一个台名出来,判据与实测见 `RadioStationCard`。
    private var radioTalkStation: (name: String, image: NSImage?)? {
        guard playback.isRadioTalkBreak, let name = playback.radioStationName, !name.isEmpty else { return nil }
        return (name, playback.radioStationImage)
    }

    /// 已播 / 剩余。位置口径跟卡片里那条迷你进度条同源:锚点外推 ?? 暂停冻结位置;歌词时间轴
    /// 偏移**不适用**(那是歌词的事,不是播放进度的事,别顺手加上去)。时长未知(播客/流)时
    /// 剩余算不出来,整块留白而不是画个 `--:--` 占位 —— 不为拿不到的数据编一个占位符,跟预览
    /// 那条"不编造假进度"是同一个态度。
    ///
    /// ⚠️ 同源**不等于**逐帧同值,两处已知的差:
    ///   - **拖动进度条时**:进度条画的是拖到哪儿(它自己的 `@GestureState`,私有),耳朵画的仍是
    ///     真实播放位置。不把拖动状态提上来是刻意的 —— 那要么把私有手势状态提到整卡这一层
    ///     (整卡跟着每个指针事件重估,正是那轮性能审计修掉的东西),要么再拉一条通道。
    ///   - **剩余时长的时长来源**:这里用 `playback.currentDurationMs`,进度条用 `anchor.durationMs`。
    ///     正常一致,但这是第二个可漂的点,改任一处时对一下另一处。
    ///
    /// ⚠️ **广告插播时照常显示**,不套用 `metadataText` 那条"广告期间歌手/专辑留空"的规矩:
    /// 位置和时长在广告期间是播放器对广告物料的真实读数,不是假信息;清空反而会让耳朵跟正下方
    /// 那条进度条自相矛盾。
    private func clockText(_ module: NotchEarModule) -> String {
        guard !isIdleNoTrack else { return "" }
        guard let position = playback.anchor?.extrapolatedPositionMs(now: Date())
                ?? playback.pausedPositionMs else { return "" }
        switch module {
        case .elapsed:
            return NotchTimeFormat.mmss(ms: position)
        case .remaining:
            guard let total = playback.currentDurationMs, total > 0 else { return "" }
            return "-" + NotchTimeFormat.mmss(ms: max(0, total - position))
        default:
            return ""
        }
    }

    /// 耳朵里那一行字。跑马灯的 id 用**显示串**本身 —— 换了内容才重新测量/重新开始滚动。
    ///
    /// ⚠️ 等宽数字**只给时间类**。给歌名/歌手/专辑也套上的话,带数字的名字("M83"、
    /// "24K Magic")字形会被静默改掉 —— 而这次改造的前提是"默认配置跟改动前逐像素一致"。
    /// 时间类必须套:不套的话每秒跳一格数字宽度就变、整行跟着抖。
    /// 条件收进 **Font 值本身**(`Font.monospacedDigit()` 返回 Font),不走 `if/else` 也不走
    /// `ViewModifier` + `AnyView`:那两种都会在视图树上多一层类型/身份变化,而这里变的只是
    /// 一个字体属性。(2026-08-31 一度写成 `ConditionalMonospacedDigit` 那样一个 modifier,
    /// 附的理由是"避免分支切换整块重建" —— 那个理由是假的:`isClock` 一变,上面 `earContent`
    /// 的分支本来就先换了,子树无论如何都要重建。)
    private func earText(_ text: String, module: NotchEarModule, alignment: Alignment) -> some View {
        let base = Font.system(size: 11.5, weight: module.isPrimary ? .semibold : .medium)
        return MarqueeText(id: text, restingAlignment: alignment) {
            Text(text)
                .font(module.isClock ? base.monospacedDigit() : base)
                .foregroundStyle(accentOrWhite.opacity(module.isPrimary ? 0.85 : 0.6))
                .lineLimit(1)
        }
    }

    // 封面小图跟歌词之间的间距。

    // 32pt 是"在 44pt 高的歌词行里上下各留 6pt"倒推出来的观感取值,夹在 [16, 32] 之间:
    // 上限避免歌词行万一变高就把封面撑得比歌词本身还抢眼(歌词才是这个产品的主体),
    // 下限保证行高万一变矮,方块也不会缩到看不出是一张封面。
    private static func artworkSide(rowHeight: CGFloat) -> CGFloat {
        max(16, min(32, rowHeight - 12))
    }

    // 歌词行尾端(卡片右下角)那枚专辑封面小图(2026-08-05 新增)。
    //
    // 位置选在这里而不是顶行歌名左边:顶行左耳的可用宽度是 (窗口宽 - 刘海宽 - 20) / 2,
    // 默认 360pt 宽配实测 179pt 刘海只有 80.5pt,放进一枚小图连间距要占掉四分之一以上,
    // 歌名被挤得只剩 50 多 pt——实机看过就是放不下。歌词行是整条 360pt(去掉左右各 16pt
    // padding 还有 328pt)、行高 44pt,同一枚封面在这里能做到 32pt 见方而只占掉歌词
    // 12.8% 的宽度,视觉上也正好落在卡片右下角这个空着的位置上。
    //
    // 稳态下这里就是卡片的右下角;hover 展开时下面会再长出"下一句预览+进度条"那一块,
    // 封面保持钉在歌词行内不动(不跟着卡片底边往下跑),避免鼠标一进一出封面就上下跳。
    //
    // 没有封面数据时不画占位方块、直接连位置一起不占:灵动岛没在播放时是收起态,播放中
    // 绝大多数曲目都拿得到封面(拿不到的是本来没有封面的播客/取图失败这类少数情况),
    // 为这种少数情况长期锁掉一块位置画一个空方块不值得。这不会导致换歌时"封面消失再
    // 出现"式的布局跳动——换歌那一刻旧封面会一直留着直到新封面取回来(见
    // LocalPlaybackSource 的 scheduleArtworkStaleTimeout/artworkRetryDelays,那是
    // 2026-08-05 修"切歌白屏"时定下来的行为),只有"启动后第一首"和"这首歌真的没有封面"
    // 两种情况才会真的发生一次宽度增减。
    //
    // ⚠️ `.scaledToFill()` 之后、`.clipShape` 之前必须显式钉一次 `.frame(width:height:)`
    // ——同 backgroundLayer 上面那一大段注释里踩过三版才找对的坑,不重复展开。
    //
    // 描边 + 投影是给"卡片背景可能是浅色"兜底:磨砂玻璃风格会透出桌面颜色,浅色壁纸下
    // 一张浅色封面直接贴上去边界会糊成一片,一圈极淡的白描边能把方块轮廓钉住。
    /// side:不给就按歌词行那一档(32pt)。耳朵里那枚要小一号,理由见 earArtwork。
    ///
    /// 图**不在运行期缩**(2026-09-09,用户圈图:「这个灵动岛小图怎么和大图长得不一样,上面有黑斑,并且
    /// 展开的时候黑斑还会动」):`Image(nsImage:).resizable().scaledToFill()` 把 600px 的封面一步缩到 46px
    /// 走的是线性采样、没有面积平均,半调网点封面(陶喆《I'm O.K.》黄底黑点)缩出来是一片摩尔纹黑斑,
    /// 而且随展开动画里的亚像素相位一帧一个样。改成按目标像素边长预先重采样一次(`ArtworkThumbnailCache`
    /// → `ArtworkThumbnail.squareBitmap`,`.high` 插值),`Image(decorative:scale:)` 逐像素贴,跟左耳
    /// App 图标(`NotchIdleAppIcon`,决策 #30)同一招。裁方(aspect-fill 居中裁)也挪进位图里做,
    /// 所以这里不再 `.scaledToFill()`;`.frame` 仍钉一次,`clipShape` 才按这枚的尺寸裁圆角(见上)。
    /// 悬停 / 按下反馈 2026-09-11 补(用户:「目前这几处的悬浮动效还没做好」)。状态由
    /// `HoverReveal` 持有而不是放在本视图上 —— 理由见那个壳的注释(这是函数,三处调用点共用)。
    private func artworkThumbnail(_ image: NSImage, side: CGFloat? = nil) -> some View {
        let side = side ?? Self.artworkSide(rowHeight: NotchMetrics.compactRowHeight)
        return HoverReveal { hovering in
            artworkButton(image, side: side, hovering: hovering)
        }
    }

    /// 封面键的本体。拆成单独一个函数只为**不给下面这四十行整体缩进**:壳套在外面、本体原位不动,
    /// diff 就只有签名和 buttonStyle 两行(这个文件同时有别的会话在改,小 diff 是硬要求)。
    private func artworkButton(_ image: NSImage, side: CGFloat, hovering: Bool) -> some View {
        let scale = max(1, displayScale)
        // 点封面 → 打开歌词窗口(2026-08-19 用户要求)。走 AppActions 统一入口,激活
        // 时序(先 NSApp.activate 再 openWindow)在注册处已处理,跟快捷键/菜单/面板同路。
        return Button {
            AppActions.shared.openLyricsWindow?()
        } label: {
            Group {
                if let bitmap = ArtworkThumbnailCache.bitmap(for: image, pixelSide: Int((side * scale).rounded())) {
                    Image(decorative: bitmap, scale: scale)
                } else {
                    // 理论上到不了:CGContext 建不出来才会 nil。退回运行期缩放,至少有图。
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
                .frame(width: side, height: side)
                // ⚠️ **这一格只画静态封面,不许再叠动态封面那一层**(2026-09-10 用户拍板撤掉,
                // 原话:「帮我把灵动岛上的封面全部改为静态的吧,只有歌词窗口的保留;因为灵动岛
                // 上的效果不是很好」)。
                //
                // 2026-09-09 落地时这里确实叠过一层 `MotionCoverView`(只在展开态、过 reduceMotion
                // 闸)。撤掉的理由是**尺寸**,不是实现:这一格最大也就 NotchMetrics.trackInfoArtworkSide
                // 这个量级(耳朵那档只有 32pt),Apple 的 motion artwork 是给整张专辑封面设计的
                // 慢镜头,缩到这么小基本只剩一片蠕动的色块,看不出画的是什么 —— 用户实机看完的
                // 判断。歌词窗口那张 460pt 的卡不受影响,那才是它该出现的地方(03 章第 6 节)。
                //
                // 别"顺手"加回来:加回来就要重新论证这个尺寸下动效能不能看清,而那已经实测过一次了。
                .clipShape(RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous))
                // ⚠️ 那圈 0.18 白描边搬进了 `NotchArtworkButtonStyle` —— 它现在要随悬停 / 按下
                // 抬亮(0.18 → 0.38 → 0.5),留在标签里只能是定值。
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        }
        .buttonStyle(NotchArtworkButtonStyle(cornerRadius: NotchMetrics.artworkCornerRadius,
                                             hovering: hovering))
        .help(L10n.t("打开歌词窗口"))
    }

    // 用歌词这一行纯文本(不含逐字填色进度)当 MarqueeText 的 id——换到新的一句歌词才
    // 重新测量/重新开始滚动,同一句歌词内部逐字变色的高频刷新(TimelineView 那部分)
    // 不应该打断正在进行的滚动。
    // 有瞬态提示(改歌词偏移/调音量)时,这一行让位给提示条,提示到期再换回歌词。
    // 只盖歌词行、不动卡片高度和顶行控件 —— 提示是"顺带说一句",不该让整块卡片跳一下。
    /// 顶行以下的全部内容:曲目信息头部、歌词行(两份定宽变体)、展开区。每一块都**常驻、定宽、定 y、
    /// 以卡片中心为锚**,展开 / 收回只切它们的透明度 —— 稳态那份歌词行原地淡出,展开态的头部 / 歌词行 /
    /// 展开区在**各自的最终位置**淡入(2026-09-06,用户报「展开的时候歌词这些都是平移过去的,它并不是
    /// 一个重新出现的过程」)。
    ///
    /// 此前这些都是 VStack 里吃满卡片宽的行:卡片从稳态宽长到展开宽时,靠左的歌词 / 歌名跟着卡片左沿
    /// 一路向左滑一百多 pt,头部插进来时歌词行还同时往下滑。用户要的是"原地淡出、在新位置淡入"。
    ///
    /// 为什么是**常驻 + 透明度**,而不是 if/else 换视图或把行留在 VStack 里:同日逐帧抓窗试过三版
    /// (if/else 直接放 VStack、放进定宽 overlay 容器、只把歌词行挪出来),正在过渡的那份或新插进来的那份
    /// 都跟着卡片左沿滑 —— SwiftUI 对进出场视图怎么摆,跟持久视图不是一套规则,而且不透明。反过来,
    /// **持久**视图被居中对齐这件事已经被刘海胶囊(notchSeam)逐帧验证过:卡片怎么长,中心一像素不动。
    /// 所以全部做成持久视图,位置交给居中布局(overlay alignment .top = 顶部居中),自己只动 opacity
    /// (跟卡片同一条弹簧)。竖直位置各自写死为常量:头部贴顶行;稳态歌词行贴顶行,展开歌词行再往下让出
    /// 头部高度(`expandedTrackInfoHeaderHeight`,没头部时为 0);展开区在展开歌词行之下。没有任何一块
    /// 的 frame 在动画里改值,所以没有平移。
    ///
    /// 守则:① 藏着的那份**必须**停表 —— 逐字填色与迷你进度条的 TimelineView 都按环境值
    /// `notchCardLayerActive` 暂停,否则 30Hz 热路径翻倍(2026-08-19 性能审计盯住的那条);跑马灯只是一个
    /// 睡着的 Task,不管。② 藏着的一律 `allowsHitTesting(false)`(里面有封面按钮、播放键、校准键)且对读屏
    /// 隐藏 —— 都收在 `NotchCardLayerActive` 这一个修饰器里。③ 两个宽度从 chrome 拿(协议
    /// `steadyCardWidth` / `expandedCardWidth`),不能用 GeometryReader 的现值。④ 「显示歌词」关着时稳态
    /// 那份歌词行不建(那时稳态本来没有歌词行,`showsLyricRow` 的语义),展开那份照常。⑤ 这一层里**不准**
    /// 出现 `.animation(_:value:)` 这类会随时间反复触发的隐式动画 —— 音浪那次(EqualizerBars 头注)证明它
    /// 会在卡片尺寸弹簧中途把作用域里的位置也接管走。⑥ 高度算术仍以 NotchChromeSource.cardHeight /
    /// NotchMetrics.expandedExtraHeight 为唯一真源,这里的 y 只是把同一组量按顺序加起来。
    private var cardBodyLayer: some View {
        let expanded = controller.isExpanded
        let top = controller.contentTopInset
        let headerHeight = controller.expandedTrackInfoHeaderHeight
        // ⚠️ 必须是**显式**的 ZStack(alignment: .top),不能让 @ViewBuilder 直接吐一个 TupleView 再在外面套
        // .opacity:套了修饰符的 TupleView 是一个视图,里面几块按**居中**叠,外面 overlay 的 .top 只管这一个整体
        // —— 第一版就是这样,稳态下最高的那块(展开区)把整体撑到 220pt、居中后歌词行被顶到卡片上方裁没了,
        // 展开态头部落到了卡片中段(2026-09-06 逐帧抓窗当场看见)。
        return ZStack(alignment: .top) {
            // 曲目信息头部(歌名/歌手/专辑,2026-09-01):画在歌词行**之上**——用户原话"新加的这些字段元素都是
            // 在最上面,然后歌词行和下一行歌词这些都放在最下面"。只在展开时可见:展开是用户主动选的动作。
            if controller.showsExpandedTrackInfo {
                trackInfoHeader
                    .frame(width: controller.expandedCardWidth, height: headerHeight, alignment: .top)
                    .padding(.top, top)
                    .modifier(NotchCardLayerActive(active: expanded))
            }
            // 用户关掉「显示歌词」时稳态没有歌词行(2026-08-31)——但展开时哪怕关着也要照常画,见 showsLyricRow
            // 的注释(2026-08-31 回归:第一版漏了展开这一档,表现是"展开后有下一句预览、却看不到正在播放的当前行")。
            if controller.showsLyrics {
                lyricRow
                    .frame(width: controller.steadyCardWidth, height: NotchMetrics.compactRowHeight)
                    .padding(.top, top)
                    .modifier(NotchCardLayerActive(active: !expanded))
            }
            lyricRow
                .frame(width: controller.expandedCardWidth, height: NotchMetrics.compactRowHeight)
                .padding(.top, top + headerHeight)
                .modifier(NotchCardLayerActive(active: expanded))
            // 展开区**完全不**受「显示歌词」开关影响(2026-08-31 用户要求):它是够到播放控制和进度条的唯一入口,
            // 而且用户主动指向展开这个动作本身就说明他现在想看更多 —— 连里面那行下一句预览也照常画。
            expandedContent
                .frame(width: controller.expandedCardWidth)
                .padding(.top, top + headerHeight + NotchMetrics.compactRowHeight)
                .modifier(NotchCardLayerActive(active: expanded))
        }
    }

    private var lyricRow: some View {
        // NotchTransientCenter 的订阅下沉在 NotchTransientHost 子视图里 —— 横幅出现/
        // 消失(音量连调时每档一次)只失效歌词行,不再打醒整卡 body。
        NotchTransientHost(tint: accentOrWhite) {
            lyricRowContent
        }
    }

    private var lyricRowContent: some View {
        HStack(spacing: NotchMetrics.artworkLyricSpacing) {
            // 封面贴左还是贴右可配(2026-09-01,`notchLyricRowShowsArtwork` /
            // `notchLyricRowArtworkPosition`,见 NotchPlayback 的注释)——2026-08-10 之前
            // 用户曾要求去掉这个开关、固定显示,这次重开开关必须保住"默认贴右、默认开"
            // 这条既有行为,不能让升级上来的用户发现封面凭空挪位或消失。
            if playback.lyricRowArtworkPosition == .left { lyricRowArtwork }
            // restingAlignment = 「对齐方式」(2026-09-03)。只管**装得下**的短句靠哪边:
            // 溢出的句子 MarqueeText 一律按 .leading 起滚(理由见那个参数的注释,靠右摆等于
            // 一上来就把开头几个字挂在容器外面),所以这一项在长句上天然无效果 —— 跟菜单栏
            // 同名设置是同一条语义,help 文案里说明了。
            //
            // ⚠️ 对齐的参照系是**歌词这一格**,不是整张卡:封面是这个 HStack 的兄弟,它占掉的
            // 那 42pt(32 封面 + 10 间距)不在 MarqueeText 的容器里。所以开着封面选「居中」时,
            // 文字是在"除封面之外的剩余宽度"里居中、相对整卡略偏封面对侧。这是刻意的 ——
            // 要相对整卡居中就得把封面改成 overlay 叠在歌词上,那会直接违反上面那段
            // `.animation(nil, value:)` 治的"封面遮挡歌词"(2026-08-22 用户报的真 bug)。
            // 广告插播(2026-09-08):这一格整个换成「📣 广告中 · 还剩 0:21   [跳过广告]」,不走歌词那套
            // (副行 / 跑马灯 / 逐字染色对广告全无意义)。分流放在这一层而不是 `mainLyricLine` 的那个
            // 「广告中」分支里,因为倒计时和跳过键要占满这一格的宽度,而那个分支只是一段文字。
            Group {
                if playback.isCurrentTrackAdBreak {
                    adStatusColumn
                } else {
                    lyricTextColumn
                }
            }
            // MarqueeText 内层是 GeometryReader(没有固有尺寸、能吃下任何被提议的宽度),
            // HStack 会先给定尺寸的封面分配它那 32pt,剩下的宽度都留给歌词。这里仍然显式
            // 写一次 maxWidth: .infinity 把"歌词吃掉剩余宽度"这个意图钉死,不依赖
            // GeometryReader 在 stack 里的隐式伸缩行为。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if playback.lyricRowArtworkPosition == .right { lyricRowArtwork }
        }
        .padding(.horizontal, 16)
        // ⚠️ 封面**在场性**的变化必须是瞬时的,不能落进任何补间 —— 这是用户报的
        // 「歌词被封面挡住」里真·遮挡的那一半(2026-08-22,最小复现对照实验坐实)。
        //
        // 机制:封面是这个 HStack 的**条件兄弟**。它从不在场变在场时,SwiftUI 把它当结构性
        // 插入 —— 新插入的视图**一帧就落在终态位置**;而歌词那一侧的 frame(以及跟着 frame
        // 走的 MarqueeText 内部那个 .clipped() 边界)是被**动画平滑收缩**的,要花整条弹簧
        // 才从"没有封面时"的宽度收到"有封面时"的宽度。这段时间里歌词被裁到更靠右的旧边界,
        // 那一截字正好画在已经就位的封面**底下** —— HStack 里靠后的兄弟盖在前面的上面。
        //
        // 独立最小复现(SwiftUI,同构的 HStack + GeometryReader/.clipped 弹性子 + 32pt 定宽
        // 兄弟,弹簧刻意放慢到 3s 便于逐帧抓):封面到位那一帧文字右边界仍停在旧位置(623px),
        // 要 4 帧才收到终态 603px,90 帧里 25 帧文字被压在封面底下;加上这一行 .animation(nil,)
        // 之后同样 90 帧 **0** 帧遮挡,四次插入全部一帧到位。
        //
        // 触发窗口:必须"封面在场性变化"和某条活动动画落进**同一次** SwiftUI 更新 —— 把两者
        // 错开 300ms 的第三版复现同样是 0/90。现实里够得着这个窗口的有两处:
        // NotchWindowRoot 挂在整棵子树上的三条 .animation(cardAnimation, value:)
        // (cardWidth/cardHeight/isCollapsed),以及 NotchTransientHost 自己那条 0.18s。
        // 而封面确实会真的离场再回来:换歌后取图迟迟不来时 LocalPlaybackSource 的
        // scheduleArtworkStaleTimeout 会在 3s 后把 artworkData 清成 nil,重试成功再填回来。
        //
        // 为什么不用别的修法:给封面留永久占位能根治,但那要一直吃掉 42pt 歌词宽度,与
        // artworkThumbnail 上面那段"没有封面就连位置一起不占"的决定直接冲突;给它加
        // .transition 淡入也不行 —— 淡入到不透明的过程中 clip 边界照旧滞后,只是把遮挡
        // 从"实心"变成"半透明"。封面出现/消失本来就是一次宽度**跳变**,补间只会制造不同步。
        //
        // ⚠️ 2026-09-01 加了显示开关之后,这里的 value 必须是"封面这一刻实际占不占位"这个
        // **合成**布尔(开关 && 有数据),不能只看数据——开关关着时数据端的有无变化不该
        // 触发任何布局動作,但如果只 key 数据端,`.animation(nil,)` 会在开关关闭期间对
        // 一个根本不影响布局的信号误判"没变化"而放行别的动画,反而在开关重新打开的
        // 那一刻可能撞上活动动画的同一次更新窗口——虽然实测未必能复现,但没有理由把
        // 判据故意做窄。
        .animation(nil, value: !lyricRowArtworkPresent)
    }

    /// 广告插播时歌词那一格的内容(2026-09-08,用户圈出广告态展开卡:「有什么好 ui 调整吗,目前这样太呆了」,
    /// 随后拍板「选用可以跳过广告的方案」):
    ///
    ///     📣 广告中 · 还剩 0:21                              [⏭ 跳过广告]
    ///
    /// * 左边是这一态**唯一有信息量**的东西:还要多久结束。改前它只藏在展开区时间行右下角的 `-0:21` 里,
    ///   而卡片上「广告中」写了两遍(头部歌名位 + 这里),两处都是一个不动的灰词。倒计时按 1Hz 走
    ///   (`adCountdown`),跟耳朵里的时间模块同一套调度(`NotchTimeFormat.clockSchedule`,相位对齐到曲目
    ///   位置的整秒,跟正下方进度条同源同相),暂停时冻结、时长未知时不编数字。图标跟歌词窗口空态那档
    ///   同一枚 `megaphone`。字号 / 七成不透明 / 投影跟 `mainLyricLine` 里那个「广告中」分支逐字相同 ——
    ///   稳态(不展开)时这一行也是这一格,用户看到的是同一句话变成了带倒计时的版本,不是一套新版式。
    /// * 右边那颗「跳过广告」只在 `playback.canSkipAd` 时出现:广告中 **且** 这是 YT Music 网页广告
    ///   (`YouTubeMusicAdSkipper.isYouTubeMusicAd`,探针强信号)**且页面此刻真的放出了跳过键**
    ///   (`adSkipAvailable`,2026-09-11 用户要求「如果当前广告不支持跳过的话就不要显示那个跳过的按钮」——
    ///   在此之前不可跳过的广告上也挂着一颗按下去只回一句「这条广告还不能跳过」的键)。Spotify 的广告
    ///   没有可点的东西,不给键。点了去点页面自己的跳过按钮(`NotchPlayback.skipAd`,不做拖到结尾那种
    ///   绕过),结果用瞬态横幅回报。
    /// * 头部在广告期间整块不画(`showsExpandedTrackInfo`),所以这一行就是展开卡最上面那一行。封面位
    ///   (左耳 / 歌词行末尾那枚)09-08 拍板是「保留播放器给的图」,09-09 被用户整条推翻——广告期间全 App
    ///   四个封面位都让位给同一枚 `megaphone.fill`(`adBreakArtworkTile` 等,清单见 05 章「广告态」⑦);
    ///   这一列自己不画封面,不受那次改动影响。
    private var adStatusColumn: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 11, weight: .semibold))
                // 字体跟歌词主行同一份派生值(2026-09-09):这一格就是歌词那一格换了内容,用户换了字体后它不该
                // 突然变回系统字体。倒计时那截同字号、细一档(`mainDetailFont`),保住原来 semibold / medium 的主次。
                Text(L10n.t("广告中"))
                    .font(playback.mainFont)
                adSlotText
                    .font(playback.mainDetailFont)
                adCountdown
                    .font(playback.mainDetailFont)
            }
            .foregroundStyle(accentOrWhite.opacity(0.7))
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .lineLimit(1)
            Spacer(minLength: 0)
            if playback.canSkipAd {
                NotchPillButton(systemName: "forward.end.fill", title: L10n.t("跳过广告"), tint: accentOrWhite) {
                    playback.skipAd()
                }
                // 正在跑(点 + 复核)时压淡、不接第二下,理由见 `NotchPlayback.skipAdInFlight`。
                .opacity(playback.skipAdInFlight ? 0.45 : 1)
                .disabled(playback.skipAdInFlight)
            }
        }
    }

    /// 「· 还剩 0:21」。位置口径同 `clockText`:锚点外推 ?? 暂停冻结位置;时长未知就整个不画(不为拿不到的
    /// 数据编占位)。TimelineView 只在这一层可见(`cardLayerActive`)且有锚点时才排表 —— 收起态 / 编辑台预览
    /// 都不该有一张每秒空转的表(理由同 `earContent` 时间模块那条 ⚠️)。采样用 `Date()` 而不是
    /// `context.date`,理由见 `earContent` 头注第 ③ 条。
    @ViewBuilder
    private var adCountdown: some View {
        if let total = playback.currentDurationMs, total > 0 {
            if let anchor = playback.anchor, cardLayerActive {
                TimelineView(NotchTimeFormat.clockSchedule(for: anchor)) { _ in
                    Text(adRemainingText(total: total, position: anchor.extrapolatedPositionMs(now: Date())))
                }
            } else if let position = playback.anchor?.extrapolatedPositionMs(now: Date()) ?? playback.pausedPositionMs {
                Text(adRemainingText(total: total, position: position))
            }
        }
    }

    private func adRemainingText(total: Int, position: Int) -> String {
        "· " + String(format: L10n.t("还剩 %@"), NotchTimeFormat.mmss(ms: max(0, total - position)))
    }

    /// 「这是插播里的第几条」(2026-09-09,用户:「广告中,还剩几个广告可以在灵动岛上展开显示
    /// 出来吗」)。排在「广告中」和倒计时之间,连起来读是「广告中 · 1/2 · 还剩 0:20」。
    ///
    /// 字号跟倒计时同一档(`mainDetailFont`,主行同字号细一档),两段都是"广告中"这句话的
    /// 补充说明,不该有各自的字重。
    ///
    /// **写成 `1/2` 而不是「还剩 1 条」**(用户在两个方案里选的前者):它跟 YouTube 自己
    /// 徽章上的写法逐字一致,用户在页面上看到什么、在灵动岛上就看到什么,不用在心里做减法;
    /// 而且纯数字对不需要新增本地化文案。
    ///
    /// 拿不到就整段不画 —— 只有 YT Music 网页广告给得出这个数,Spotify 恒 nil,YT Music 英文
    /// 界面(`Ad 1 of 2`)也抓不到。宁可少一段,不编。
    @ViewBuilder
    private var adSlotText: some View {
        if let slot = playback.currentAdSlot {
            Text(verbatim: "· \(slot.index)/\(slot.total)")
        }
    }

    /// 歌词这一格:副行关着就是改动前那一行 `MarqueeText`(逐像素不变);副行开着(2026-09-06,
    /// 用户拍板方案二)就在它下面再放一行 11pt 的副行,两行 + 3pt 间距 = 31pt,竖直居中塞进
    /// 44pt 的行里,**行高不变** —— 这是选方案二而不是叠行方案的全部理由:不动 `cardHeight`、
    /// 编辑台舞台常量、出场动画这片高度体系(05 章决策 22)。
    /// 主行那一格的高度 2026-09-09 起随「字号」走(`playback.mainLineHeight`,11…17pt → 13…19pt),两行最多 35pt,
    /// 仍在 44 里、上下各余 ≥ 4pt —— 字号范围就是按这条倒推的,Core 有 selftest 钉着。
    @ViewBuilder
    private var lyricTextColumn: some View {
        if playback.secondaryLine.showsSecondaryRow {
            VStack(alignment: .leading, spacing: NotchMetrics.secondaryLineSpacing) {
                mainLyricLine
                    .frame(height: playback.mainLineHeight)
                secondaryLyricLine
                    .frame(height: NotchMetrics.secondaryLyricLineHeight)
            }
        } else {
            mainLyricLine
        }
    }

    /// 主行本体(原 `lyricRowContent` 里那段 `MarqueeText`,搬出来只是给副行让位)。
    /// restingAlignment 与 edgeFadeWidth 的理由见 `lyricRowContent` 里紧挨着 `lyricTextColumn` 的那段注释。
    private var mainLyricLine: some View {
        MarqueeText(id: playback.displayLine?.plainText ?? "",
                    restingAlignment: playback.mainLyricAlignment,
                    edgeFadeWidth: NotchMetrics.lyricEdgeFadeWidth) {
            lyricContent
        }
        // 字体 / 粗细 / 字号三件由设置决定(2026-09-09),默认推出来就是原来的 13pt semibold。里面那几个状态占位
        // 文字(纯音乐 / 暂无歌词 / …)和逐字染色的每个字都从这里继承字体,不各自再写。
        .font(playback.mainFont)
    }

    /// 副行:下一句 / 当前句译文 / 当前句罗马音(由 `NotchPlayback.secondaryText` 按设置选好)。
    /// **不滚动**:装不下就尾部省略号 —— 主行已经是一条跑马灯,两条同时动太乱;而且它是"提前看一眼"
    /// 的辅助信息,不是要逐字跟唱的正文。对齐跟主行吃同一个「对齐方式」设置(展开态那行「下一句」
    /// 预览也是,selftest 钉着 `swiftUIAlignment` 的接线处数)。取不到内容时留空不缩高。
    /// 三档透明度沿用悬浮歌词那三行的口径(下一句那边 40%,这里 45% —— 11pt 在深底上再淡就看不清了;
    /// 译文 75%、罗马音 60% 照抄)。
    private var secondaryLyricLine: some View {
        Text(playback.secondaryText ?? "")
            // 固定 11pt、比主行细一档,只跟主行的字体族与粗细(2026-09-09,理由见 NotchLyricRowMetrics.secondaryFontSize)。
            .font(playback.secondaryFont)
            .foregroundStyle(accentOrWhite.opacity(secondaryLineOpacity))
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: playback.secondaryLyricAlignment)
    }

    private var secondaryLineOpacity: Double {
        switch playback.secondaryLine {
        case .off, .nextLine: return 0.45
        case .translation: return 0.75
        case .romanization: return 0.6
        }
    }

    /// 歌词行末尾(或开头)那枚封面缩略图,2026-08-05 就有、2026-08-10 到 2026-09-01 之间
    /// 固定显示,现在受 `notchLyricRowShowsArtwork` 开关控制。没有封面数据(没曲目/取图
    /// 失败)或开关关着时都不画占位方块,理由见 `artworkThumbnail` 上面那段。
    @ViewBuilder
    private var lyricRowArtwork: some View {
        if playback.lyricRowShowsArtwork {
            if controller.isAdBreakNow {
                // 广告期间这一格换成广告标识(2026-09-09,用户:「只要识别到是广告的话,封面部分
                // 都用这个替代」)—— 播放器在广告时给的图是广告物料的缩略图,不是"这一刻在听
                // 什么"的封面,四个封面位统一让位给同一枚喇叭。开关(`notchLyricRowShowsArtwork`)
                // 仍然管这一格在不在:关了就还是不画,广告不该把用户关掉的东西请回来。
                adBreakArtworkTile(side: Self.artworkSide(rowHeight: NotchMetrics.compactRowHeight))
            } else if let image = radioTalkStation?.image ?? playback.highResArtworkImage ?? playback.artworkImage {
                artworkThumbnail(image)
            }
        }
    }

    /// 广告期间顶替封面的那枚方块(2026-09-09)。外框跟 `artworkThumbnail` 逐项对齐(同一个
    /// 圆角、同一道 0.5pt 白描边、同一层投影),这样广告开始/结束时这一格只是内容换了、
    /// 几何一点不动;里面是跟状态行、跟左耳同一枚 `megaphone.fill`。
    /// 不接点击:`artworkThumbnail` 那枚点了会打开歌词窗口,而广告没有歌词可看。
    private func adBreakArtworkTile(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous)
            .fill(.white.opacity(0.10))
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: "megaphone.fill")
                    .font(.system(size: side * 0.44, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .accessibilityHidden(true)
    }

    /// 上面那枚封面此刻是不是真的占着一个位置——给 `.animation(nil, value:)` 当判据用,
    /// 见那一行的注释。
    private var lyricRowArtworkPresent: Bool {
        // 广告期间那枚替代方块同样占着这个位置(见 lyricRowArtwork),判据要跟着算上,
        // 否则 `.animation(nil, value:)` 会以为这一格是空的、放行一次不该有的布局动画。
        playback.lyricRowShowsArtwork
            && (controller.isAdBreakNow || (playback.highResArtworkImage ?? playback.artworkImage) != nil)
    }

    private var lyricContent: some View {
        Group {
            if let words = playback.displayLine?.words, !words.isEmpty {
                // 帧率上限见 WordKaraokeGradient.refreshInterval。跟悬浮歌词一样,这里也
                // 保持"TimelineView 包住整行"而不下沉到每个字 —— 外层同样套着
                // .compositingGroup()+.shadow(),理由见 LyricsOverlayView.mainLine 那段。
                //
                // paused 的第二个条件(2026-08-19 性能审计落地,与悬浮窗同款):这一行填完
                // 之后到下一行开始之前(行尾/间奏/曲末)视觉零变化,把表停掉;换行时
                // currentLine 赋值触发 body 重估,表自然恢复。
                // `!cardLayerActive`(2026-09-06):这一行现在有两份变体常驻,藏着的那份必须停表,见 cardBodyLayer。
                TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                        paused: !playback.isPlayingNow || playback.currentLineFillSettled
                                            || !cardLayerActive)) { context in
                    // 加上 currentLyricsOffsetMs,理由跟 LyricsOverlayView.mainLine 同一段
                    // 注释——不加的话"当前词判定"和"填色进度"用的时间基准对不上,会出现填到
                    // 一半就卡住的现象。anchor/offset 直读协调器不经代理订阅:这个闭包按帧
                    // 重跑,每帧读到的都是最新值(同悬浮窗的取舍,见 NotchPlayback 注释)。
                    // ?? pausedPositionMs:暂停基准兜底(2026-08-19,四个展示面同款,理由见
                    // LyricsOverlayView.mainLine 同位置注释)。
                    let currentMs = (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: context.date)
                        ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
                        + PlaybackCoordinator.shared.currentLyricsOffsetMs
                    // 渐变素材每帧只取一次,纯色词跨帧复用同一实例(2026-08-20 性能审计,
                    // 见 WordKaraokeGradient.Palette 注释)。
                    let palette = WordKaraokeGradient.palette(fg: accentOrWhite)
                    HStack(spacing: 0) {
                        // indices 而不是 Array(enumerated()):后者每帧物化一个新数组纯为
                        // 当 id,Range 零分配,下标当 id 与原 offset 语义一致。
                        ForEach(words.indices, id: \.self) { i in
                            wordText(words[i], atMs: currentMs, palette: palette)
                        }
                    }
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                }
            } else if playback.isCurrentTrackAdBreak {
                // 同 LyricsOverlayView.mainLine 的区分,必须排在"还在搜索中"分支前面,
                // 见 PlaybackCoordinator.isCurrentTrackAdBreak 定义处的注释。
                // 2026-09-08 起广告态在 `lyricRowContent` 那一层就分流到 `adStatusColumn` 了,这个分支
                // 正常到不了;留着当兜底(顺序契约不变),别删。
                Text(L10n.t("广告中"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.isRadioTalkBreak {
                // 电台口白(2026-09-11):这首歌已经放完、台里在说话。必须排在"还在搜索中"之前,
                // 理由同上面那条广告分支 —— 口白期间元数据还停在上一首,不拦就会显示成
                // 「搜索歌词中…」。收歌词的判定在 LocalPlaybackSource.radioTrackFinished。
                Text(L10n.t("口白"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.isCurrentTrackInstrumental {
                // 同 LyricsOverlayView.mainLine 的区分,必须排在"还在搜索中"分支前面,
                // 见 PlaybackCoordinator.isCurrentTrackInstrumental 定义处的注释。
                Text(L10n.t("纯音乐"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.currentTrackHasNoLyrics {
                // 搜完了、确实一句都没有,同 LyricsOverlayView.mainLine 的同名分支——
                // 必须排在下面那个"搜索歌词中…"前面。
                Text(L10n.t("暂无歌词"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.collectorNetworkDown && !playback.hasLyricsContent {
                // 顺序理由同 LyricsOverlayView.mainLine 里那段:必须排在"搜索歌词中…"
                // 之前、"暂无歌词"之后。
                Text(L10n.t("网络连接失败"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.isPlayingNow && !playback.hasLyricsContent {
                // 同 LyricsOverlayView.mainLine 的区分:currentLine==nil 可能是"还没解析
                // 出这首歌的歌词"(collector 后台搜索中,见 PlaybackCoordinator.hasLyricsContent 注释),
                // 不能跟"这首歌真没歌词/正在间奏"共用同一个♪占位符。
                Text(L10n.t("搜索歌词中…"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else {
                // ♪ 是**间奏**占位符(在播、有歌词、只是这一刻不在任何一句上)—— 那种
                // 情况下它是有意义的,保留。但压根没有曲目时它什么都不代表,留白
                // (2026-08-21 用户要求)。上面那一长串 else-if 已经把广告/纯音乐/无歌词/
                // 断网/搜索中都各自接走了,能落到这里的空态只剩"没有曲目"。
                // displayLine 为 nil 的成因这里天然合流:单行面的长间奏中段(唱完了、下一句还早)、
                // "这一刻不在任何一句上"、以及副行开着时的前奏(currentLine 还没到第一句),都该是 ♪。
                Text(playback.displayLine?.plainText ?? (isIdleNoTrack ? "" : "♪"))
                    .foregroundStyle(accentOrWhite)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            }
        }
        .lineLimit(1)
    }

    // 逐字时长下限/过渡带宽度跟 LyricsOverlayView 用同一组经验取值(80ms/0.08),这两个
    // 数字本身是"看起来顺眼"的调校结果,不是从歌词数据推导出来的,两处保持一致没有坏处。
    //
    // 2026-08-20 起填色渐变收编到 WordKaraokeGradient 共享实现 —— 这里原来自带一份
    // wordGradient(数学与共享版逐项一致:dim=0.35、过渡带混合 1-t*0.65),收编后三个
    // 整行 TimelineView 展示面共享同一份纯色渐变缓存(见 Palette 注释),不再逐词现造。
    private func wordText(
        _ w: SyncedLyricWord, atMs currentMs: Int, palette: WordKaraokeGradient.Palette
    ) -> some View {
        let fraction = WordKaraokeGradient.fillFraction(for: w, atMs: currentMs)
        let band = WordKaraokeGradient.wordEdgeSoftenBand
        return Text(w.text)
            .foregroundStyle(palette.style(left: fraction - band, right: fraction + band))
    }

    /// 灵动岛里几乎所有前景元素的颜色。
    ///
    /// 复用桌面悬浮歌词那条既有语义:只有「跟随封面取色」开着、且这首歌真的取到了主色时
    /// 才用它,否则维持原来的白 —— 灵动岛贴在刘海下,底色是纯黑或封面模糊图,白色是那里
    /// 最稳的选择,不该在用户没要求时擅自换掉。
    ///
    /// 用的是 notchAccentColor 而不是 artworkAccentColor:后者只保了 HSB 亮度下限
    /// (brightenedAccent),饱和冷色(纯蓝 luma 0.07)能原样通过,贴在灵动岛永远深色的
    /// 背景上区分度差;前者在此之上又保了一道感知亮度下限,专为深色背景调的
    /// (见 LocalPlaybackSource.accentForDarkBackdrop)。提亮在数据层做完,这里直接用。
    ///
    /// 2026-08-16 补完:此前只有歌词正文和进度条填充吃它,顶行歌名、五种状态占位文字、
    /// 下一句预览、进度条底槽、时间文字、播放控制按钮全是写死的白。后果不只是"不够统一"
    /// —— 状态文字跟正常歌词**在同一个 Group 里**,于是同一行会出现"有歌词时跟着封面色、
    /// 一旦变成「暂无歌词」就突然跳回白"的闪动。现在除了封面缩略图的描边(那处是刻意的,
    /// 见 artworkThumbnail 注释:磨砂玻璃风格下要给浅色封面兜一圈可见轮廓),其余都走这里。
    /// 灵动岛音浪的振幅:这一刻有没有字正在唱。
    ///
    /// 输入全部直读 `PlaybackCoordinator.shared`,**不经窄代理订阅** —— 跟同文件里逐字填色
    /// 那个 TimelineView 闭包同一个取舍(见 lyricRow 里 currentMs 那段注释):锚点重建会打醒
    /// 整卡 body,而这里只需要"调用那一刻的快照"。
    ///
    /// 形状由 `VocalEnvelope`(LyrimuseCore,selftest 覆盖)决定:字内稳态 1 + 起音脉冲、字间从 1
    /// 指数泄放到 0.6、没有逐字 1。2026-09-02 之前是三档阶跃,历史与取舍见 VocalEnvelope 头注
    ///(含 05 章那次「按已唱比例插值反而更不像人声」的失败尝试——字内稳态刻意不动)。
    /// 这里只剩"读协调器快照、算位置、交给 Core":XxxxView 里不放数学,是仓库的分层边界。
    private static func vocalAmplitude(at date: Date) -> Double {
        let coordinator = PlaybackCoordinator.shared
        guard let words = coordinator.currentLine?.words, !words.isEmpty else {
            return VocalEnvelope.idleAmplitude
        }
        // 位置口径必须跟逐字填色完全一致(锚点外推 → 暂停冻结值兜底 → 叠加生效偏移),
        // 否则条子跟高亮的字对不上,那比不跟着动更奇怪。
        let posMs = (coordinator.anchor?.extrapolatedPositionMs(now: date)
            ?? coordinator.pausedPositionMs ?? 0)
            + coordinator.currentLyricsOffsetMs
        return VocalEnvelope.amplitude(atMs: posMs, words: words)
    }


    private var accentOrWhite: Color {
        // 组合逻辑(风格是不是「跟随封面」× 动态主色)已下沉进 NotchPlayback.accent 预组合
        // 去重,这里只是个语义化的别名。
        // (2026-08-31 之前那个"×"左边是悬浮歌词的 followsCoverArt 开关,见 accent 的注释。)
        playback.accent
    }

    // hover 展开时多出来的这一块——下一句歌词预览 + 迷你进度条,用来强化"这是个歌词类
    // 产品"而不是退化成通用媒体控制器;进度条属于"有余量就加"的加分项。
    //
    // ⚠️ 曲目信息头部(歌名/歌手/专辑)**不在这里**——2026-09-01 一度是这个 VStack 的第一个
    // 子视图,用户报"信息夹在两行歌词之间",要求挪到歌词行**之上**,现在是 body 里
    // lyricRow 前面一个独立的 `trackInfoHeader` 块(见 body 那段注释)。这里因此永远传
    // `trackInfoHeight: 0`——那部分高度已经在 `expandedTrackInfoHeaderHeight` 那份独立
    // 的 `.frame(height:)` 里算过一次。
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ⚠️ `showsExpandedLyricPreview` 这一条跟下面 .frame(height:) 里留不留这行的高度
            // 是**同一个值**(协议扩展里那份),别在这里换成别的判据。
            if controller.showsExpandedLyricPreview, !nextLineDisplayText.isEmpty {
                Text(nextLineDisplayText)
                    // 跟副行同一个派生字体(2026-09-09):它俩是同一类"辅助的下一句",字号不随主行变、粗细细一档。
                    .font(playback.secondaryFont)
                    .foregroundStyle(accentOrWhite.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 「对齐方式」也管这一行(2026-09-03)。**不能只改主歌词行**:那样选了
                    // 「居中」之后主行居中、这一行还贴着左边,看起来就是没做完 —— 这个仓库
                    // 正是为"同一个视觉属性漏改一条路径"付过代价的(见 swiftUIAlignment 注释)。
                    //
                    // ⚠️ 用**这一行自己**的 `.frame(maxWidth:.infinity, alignment:)`,而不是
                    // 去改外层 `VStack(alignment:)`:那个 VStack 里还有进度条和播放键,而
                    // 下面那两条 `.padding(.bottom,)`/`.frame(height:)` 的高度算术是跟
                    // `NotchExpandedMetrics` 对账的(注释里记着"两处一个开一个不开必然对不上"),
                    // 动 VStack 的对齐属性等于把这一项的影响面从"一行文字"扩到整块布局。
                    // Text 撑满整行宽之后它自己的 leading 对齐导线就落在容器左边缘,VStack 那
                    // 一侧看到的仍是原来的形状;`.lineLimit(1)` 也保证高度不变。
                    .frame(maxWidth: .infinity,
                           alignment: playback.nextLineAlignment)
            }

            // 进度条独立成 NotchScrubber 子视图(拖动状态自持 + 30Hz 帧率上限),见其注释。
            NotchScrubber(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                isPlayingNow: playback.isPlayingNow,
                tint: accentOrWhite,
                // 广告期间不画「− 歌词 0.0s +」(2026-09-08):广告没有歌词,校准无物可校。
                showsLyricsOffsetControls: playback.showsLyricsOffsetControls && !playback.isCurrentTrackAdBreak,
                trackLyricsOffsetMs: playback.trackLyricsOffsetMs,
                lyricsOffsetStepMs: playback.lyricsOffsetStepMs)

            // 完整三键(2026-08-19 设计评审,从右耳挪进来):岛是 hover 展开的,真正的
            // 点击全发生在展开态 —— 控制就该在展开卡里、进度条下方居中,跟菜单栏面板
            // 卡片同一套设计语言(进度条 + 居中三键),目标也大得多(22pt vs 耳朵里 15pt)。
            //
            // 2026-09-01 加了 `expandedShowsControls` 开关——关掉后这排键不画,理由见
            // `NotchChromeSource.expandedShowsControls` 的注释(不是唯一入口,`NotchEarModule`
            // 本来就有「播放控制」这个选项)。
            if controller.expandedShowsControls {
                HStack(spacing: 34) {
                    controlButton("backward.fill", glyphSize: 11.5, hitSize: 22) {
                        MusicPlaybackController.previousTrack()
                    }
                    controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill",
                                  glyphSize: 14, hitSize: 22) {
                        // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
                        PlaybackCoordinator.shared.userTogglePlayPause()
                    }
                    controlButton("forward.fill", glyphSize: 11.5, hitSize: 22) {
                        MusicPlaybackController.nextTrack()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        // 10pt 底边距是 `NotchExpandedMetrics.controlsBlock`(35 = 22 键高 + 10 底边距 +
        // 3pt 余量)的一部分,关掉播放控制键之后这一整块(含底边距)在高度算术里都不占
        // 地方了(见 height(...) 的 hasControls 分支),渲染这侧必须跟着不加,否则算出来的
        // 高度比实际渲染矮 10pt,会把上面的内容顶出去一截、被 `.frame(alignment: .top)`
        // 裁掉底部——两处一个开一个不开,必然对不上。⚠️ 代价:关掉控制键但进度条/下一句
        // 预览还开着时,最后一个元素少了这 10pt 专属边距,只剩它自己那份"间距4"贴底(比如
        // 进度条时间行离底边只剩 4pt,不是 10pt)——比专属边距紧一些,但不会被裁,这是
        // 接受的取舍,不值得为这一种组合另开一条独立的常量。
        .padding(.bottom, controller.expandedShowsControls ? 10 : 0)
        // ⚠️ maxWidth: .infinity 是必须的,不是随手加的保险。
        //
        // 不钉这一下,这一块的宽度就跟着**内容**走。播放时里面有进度条,进度条用
        // GeometryReader 会自己撑满,于是整块占满整行、歌词预览自然贴左;而暂停时进度条
        // 那一段整个不渲染(它挂在 playback.anchor 上,暂停后 anchor 为 nil),VStack 里只
        // 剩一句歌词预览,这一块就缩成那行字那么宽 —— 再被外层 VStack 默认的**居中**
        // 对齐推到正中间。表现就是"暂停时下一句歌词跑到中间、播放时又靠左"
        // (2026-08-17 用户报)。撑满 + topLeading 之后,两种状态下它都在同一个位置。
        // (分两个 .frame:maxWidth 走的是弹性那个重载,height 走固定尺寸那个,
        // 混在一次调用里编译不过。)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 高度跟 NotchWindowRoot.cardHeight **走同一个函数、同一组入参**(都读 controller
        // 上那两个曲目级标志)—— 两处各自判断的话必然漂,而漂的表现是卡片和内容差一截:
        // 要么底部多一条空隙,要么最下面那排三键被裁掉。
        .frame(height: NotchMetrics.expandedExtraHeight(
            hasLyricPreview: controller.showsExpandedLyricPreview,
            hasScrubber: controller.expandedShowsScrubber,
            hasControls: controller.expandedShowsControls,
            trackInfoHeight: 0), alignment: .top)
    }

    /// 曲目信息头部:封面 + 歌名/歌手/专辑,四项独立开关(2026-09-01)。解决的缺口:两只
    /// 耳朵都配成非文本模块(比如「剩余时长」)时,hover 展开也看不出这是哪首歌。
    ///
    /// ⚠️ **封面落点反复过**——最初设计里就带一枚,用户看过效果后指出"跟歌词行末尾已有的
    /// 那枚封面重复了",要求并回那一枚(`lyricRowContent` 里的 `artworkThumbnail`,受
    /// `notchLyricRowShowsArtwork`/`notchLyricRowArtworkPosition` 控制,走 `NotchPlayback`
    /// 镜像,不在这个协议里);过了几轮之后用户又要求"在展开态里面多增加一个显示封面",
    /// 重新给头部配上**自己**的一枚(`expandedTrackInfoShowsArtwork`,这个协议里),这次
    /// 没有位置四选一——固定贴文字块左边,用户参照图就是"封面居左+文字居右"。两枚封面因此
    /// 是两个独立开关,理论上能同时开(一枚在歌词行末尾、一枚在头部左边),不算矛盾。
    @ViewBuilder
    private var trackInfoHeader: some View {
        if controller.showsExpandedTrackInfo {
            HStack(spacing: 8) {
                trackInfoArtwork
                trackInfoTextStack
                trackInfoQuickActions
            }
                // 悬浮提示挂在**整行**上、不挂在那排按钮上:气泡要收敛在卡片里,而"卡片内容区有多宽"
                // 只有这一层的 GeometryReader 量得到(按钮排自己只有 100pt 宽)。见 `QuickActionTooltipOverlay`。
                .modifier(QuickActionTooltipOverlay(hovered: hoveredQuickAction,
                                                    shown: $shownQuickActionTooltip,
                                                    tint: accentOrWhite, edge: .bottom))
                // 左内边距**跟下面歌词行的首字对齐**,不是跟上面 topRow 对齐——2026-09-01
                // 同一天先按 topRow 的 NotchMetrics.cardHorizontalPadding(10pt)对齐过一版,
                // 用户看完又改口"和下面的歌词首字左对齐更好看",所以这里改成跟
                // lyricRowContent/expandedContent 同一个 16pt(那两处也是这个字面量,不是
                // 巧合——都在描述"歌词那一列文字的左边界"这同一件事)。这会导致跟 topRow
                // 不对齐(10 vs 16,差 6pt),这是用户明确的取舍,不是遗漏。
                .padding(.horizontal, 16)
                // 顶部间距(2026-09-01,同一天第二轮):头部紧挨在 topRow 下面,原来零间距,
                // 用户报"标题首行贴到上面边了"。这份间距已经在
                // `expandedTrackInfoHeaderHeight`/`NotchExpandedMetrics.height` 的高度算术
                // 里算过(`trackInfoSpacing * 2`,一份在上一份在下),这里只是真的把"上面
                // 那份"实现成看得见的留白——`.frame(alignment: .top)` 会把这段 padding 之后
                // 的内容继续钉在分配到的那块高度顶部,不会把它推到底部去。
                .padding(.top, NotchMetrics.trackInfoTopSpacing)
        }
    }

    /// 头部里的封面缩略图,复用 `artworkThumbnail`(点击打开歌词窗口的行为跟着一起继承)。
    /// 没有封面数据(没曲目/取图失败)时不画占位方块——跟 `lyricRowContent` 末尾那枚同一个
    /// 惯例(`@ViewBuilder` 的 `if let` 不满足时直接产出零视图,HStack 自然收缩)。
    @ViewBuilder
    private var trackInfoArtwork: some View {
        if controller.expandedTrackInfoShowsArtwork,
           let image = playback.highResArtworkImage ?? playback.artworkImage {
            artworkThumbnail(image, side: NotchMetrics.trackInfoArtworkSide)
        }
    }

    /// 头部里的歌名/歌手/专辑三行,复用 `metadataText`——跟耳朵里那三个文本模块走同一份
    /// 广告插播/空曲目规则(广告中歌名写「广告中」、歌手专辑留空),不重新定义一套。
    ///
    /// `.frame(maxWidth: .infinity, alignment: .leading)` 是必须的:没有它,`.lineLimit(1)`
    /// 的 `Text` 在 VStack 里只会按内容天然宽度收缩,压根不会触发截断——这一块需要一个
    /// 明确的宽度提议才截得断长歌名/长专辑名。
    private var trackInfoTextStack: some View {
        VStack(alignment: .leading, spacing: NotchMetrics.trackInfoLineSpacing) {
            if controller.expandedTrackInfoShowsTitle {
                Text(metadataText(.title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.9))
            }
            if controller.expandedTrackInfoShowsArtist {
                Text(metadataText(.artist))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accentOrWhite.opacity(0.6))
            }
            if controller.expandedTrackInfoShowsAlbum {
                Text(metadataText(.album))
                    .font(.system(size: 9))
                    .foregroundStyle(accentOrWhite.opacity(0.4))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 头部右侧那排「快捷操作」(2026-09-07,用户圈出头部右边那块空地:「塞进一些按钮进去?比如
    /// 关闭灵动岛的按钮,打开设置的按钮,搜索歌词的按钮,调整是否显示歌词的按钮」)。
    ///
    /// 排法照悬浮歌词那排控制胶囊(`LyricsOverlayView.playbackControls`):**对这首歌的操作 │ 窗口级
    /// 操作**,中间一条细竖线分组,✕ 放最右最边上 —— 搜索歌词 · 显示歌词 │ 设置 · 关闭。四颗都是
    /// 22pt 命中格(跟下面播放控制三键同一档,`NotchExpandedMetrics.trackInfoActionsHeight`),
    /// 字形 11pt,颜色跟卡上其它图标一样走 `accentOrWhite`、压到七成五 —— 这排是"手边的入口",
    /// 不该比歌名重。
    ///
    /// 四颗键的语义(用户 2026-09-07 拍板):
    ///   * 搜索歌词 → `AppActions.openLyricsQuickSearch`,跟悬浮歌词 ⚙ 菜单的「搜索歌词…」同一扇小窗。
    ///     头部本来就要求 `hasTrack`,所以不用像那边一样再按"有没有歌"决定显隐。
    ///   * 显示歌词 → 切 `AppSettings.notchShowLyrics`(稳态那 44pt 歌词行的开关)。**展开态里看不出
    ///     变化**(展开永远画歌词行,见 `showsLyricRow`),关着时字形压淡到四成、tooltip 换成「显示歌词」,
    ///     让"现在是关的"当场可辨;收回稳态才看得出效果。状态读 `controller.showsLyrics`(控制器的镜像),
    ///     不另订阅 AppSettings。
    ///   * 设置 → 直接翻到 设置 › 歌词显示 › 灵动岛,照抄 `OverlayQuickSettingsMenu.openMoreSettings` 那三行。
    ///   * 关闭 → 关掉「灵动岛歌词」**总开关**(`closeFromQuickAction` → `setVisible(false)`),跟悬浮歌词
    ///     那颗 ✕ 同一个意思;再打开走菜单栏面板 / 设置 / 快捷键。备选的"只收起这一次"被否:hover 展开
    ///     本来移开指针就收,那颗键等于没用。
    ///
    /// 不套 `controlButton` 那层"先查 Apple Music 自动化权限"的守卫:四个动作跟播放控制毫不相干,
    /// 借那层守卫会引入一个跟按钮语义不匹配的隐藏依赖(跟悬浮歌词的锁定键同一条理由)。
    @ViewBuilder
    private var trackInfoQuickActions: some View {
        if controller.expandedShowsQuickActions {
            HStack(spacing: 2) {
                quickActionButton("magnifyingglass", label: L10n.t("搜索歌词…")) {
                    AppActions.shared.openLyricsQuickSearch?()
                }
                quickActionButton("text.alignleft",
                                  label: controller.showsLyrics ? L10n.t("隐藏歌词") : L10n.t("显示歌词"),
                                  dimmed: !controller.showsLyrics) {
                    AppSettings.shared.notchShowLyrics.toggle()
                }
                // 分组线:前两颗是"对这首歌 / 这行歌词"的操作,后两颗是"这块卡片"的操作。
                Rectangle()
                    .fill(accentOrWhite.opacity(0.18))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 3)
                quickActionButton("gearshape.fill", label: L10n.t("设置…")) { openNotchSettingsPage() }
                quickActionButton("xmark", label: L10n.t("关闭灵动岛歌词")) {
                    controller.closeFromQuickAction()
                }
            }
            .frame(height: NotchMetrics.trackInfoActionsHeight)
        }
    }

    /// 「设置…」快捷键的动作:直接翻到 设置 › 歌词显示 › 灵动岛,照抄 `OverlayQuickSettingsMenu.openMoreSettings`
    /// 那三行。抽成函数是因为头部快捷操作与空闲面板各有一颗(2026-09-07)。
    private func openNotchSettingsPage() {
        UserDefaults.standard.set(LyricsSurface.notch.appearanceSectionRawValue,
                                  forKey: LyricsSurface.appearanceSectionStorageKey)
        AppActions.shared.requestSettings(.tab(.appearance))
        AppActions.shared.openSettings?()
    }

    /// 没有曲目时左耳那一格(2026-09-11,决策 #37):平时是 `idleAppIcon`;有「发现新播放器」的信任提议挂着时
    /// 换成**那个播放器**的图标 + 右上角一粒小圆点 —— 收起态下这是提示存在的唯一线索(用户要的"更明显一点"
    /// 里被动的那一半;主动的那一半是卡片自己撑开一次,见 NotchUnknownPlayerPrompt)。切换与订阅都在宿主
    /// 子视图里,这里只把尺寸账(同 idleAppIcon:`earAppIconSide` × 显示倍率)交下去。
    private func idleEarIcon(alignment: Alignment) -> some View {
        NotchIdleEarIconHost(prompt: prompt,
                             side: NotchMetrics.earAppIconSide(contentTopInset: controller.contentTopInset),
                             scale: max(1, displayScale), alignment: alignment) {
            idleAppIcon(alignment: alignment)
        }
    }

    /// 没有曲目时 hover 展开出来的那一块(2026-09-07,用户报「没有播放的展开状态目前看起来不是很友好」)。
    ///
    /// 改前的样子:`cardHeight` 照有曲目的通式给展开区留"三键 + 进度条"的 59～76pt,而那块内容整个被
    /// `hasTrack` 挡掉 —— hover 上去长出一大块什么都没有的黑。现在只长出这一块,排法照曲目信息头部
    /// (`trackInfoHeader`):左边两行字、右边一排 22pt 图标键,左内边距同样是歌词那一列的 16pt,上面留
    /// `trackInfoTopSpacing`,下面留 `idlePanelBottomSpacing`(它贴底,4pt 太紧)—— 有曲目和没曲目时
    /// 展开出来的是"同一个位置上的同一种东西",不是两套版式。
    ///
    /// 文案与动作全部复用歌词窗口停播页那套(`IdleStandbyView.noTrackHero` / `IdlePlaybackActions`):
    /// 「没有在播放」+「在 X 播放任意歌曲,歌词会自动出现」;第一颗键 AM / Spotify 是「继续播放」(三段式,
    /// 失败兜底激活 App),其它播放器没有 AppleScript、只给「打开 X」。后两颗是「设置…」「关闭灵动岛歌词」,
    /// 跟头部快捷操作同款、同分组线 —— 但**不看** `expandedShowsQuickActions` 那个开关:那开关管的是"头部
    /// 右侧那块空地要不要塞按钮",而这里的键是空闲面板存在的全部理由,关掉就只剩两行字。不放「搜索歌词」
    /// 「显示歌词」:没有曲目,两者都无物可指。左耳那枚 App 图标已经在顶行上,这里不再画第二枚。
    ///
    /// 不套 `controlButton` 那层"先查 Apple Music 自动化权限"的守卫:`IdlePlaybackActions.resume` 自己会查
    /// (AM 那条走 `checkAppleMusicSafely`),「打开 X」压根不需要权限。
    private var idleExpandedPanel: some View {
        let player = IdlePlaybackActions.player
        let canResume = IdlePlaybackActions.canResume(player)
        let name = player.displayName
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: NotchMetrics.trackInfoLineSpacing) {
                Text(L10n.t("没有在播放"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.9))
                // 提示句不点名播放器(2026-09-07 用户:「这里不应该强调 Apple Music,改为播放器」)——
                // 灵动岛这句是泛指,不像歌词窗口停播页那句要跟旁边「打开 X」按钮对上;右边那颗键的
                // tooltip 仍带具体名字(那是一个具体动作的目标)。
                Text(L10n.t("在播放器里播放任意歌曲，歌词会自动出现"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accentOrWhite.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                quickActionButton(canResume ? "play.fill" : "arrow.up.forward.app",
                                  label: canResume ? L10n.t("继续播放") : String(format: L10n.t("打开 %@"), name)) {
                    if canResume {
                        IdlePlaybackActions.resume(player: player)
                    } else {
                        IdlePlaybackActions.openPlayerApp(player)
                    }
                }
                // 分组线,同头部快捷操作:左边是"对播放器做什么",右边是"对这块卡片做什么"。
                Rectangle()
                    .fill(accentOrWhite.opacity(0.18))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 3)
                quickActionButton("gearshape.fill", label: L10n.t("设置…")) { openNotchSettingsPage() }
                quickActionButton("xmark", label: L10n.t("关闭灵动岛歌词")) {
                    controller.closeFromQuickAction()
                }
            }
            .frame(height: NotchMetrics.trackInfoActionsHeight)
        }
        // 同一份提示,但**往上**弹:这块面板贴着卡片底(下面只剩 idlePanelBottomSpacing 那 10pt),
        // 气泡往下会被窗口硬裁;往上是顶行,空闲态那儿只有一枚 App 图标,盖一下无妨。
        .modifier(QuickActionTooltipOverlay(hovered: hoveredQuickAction,
                                            shown: $shownQuickActionTooltip,
                                            tint: accentOrWhite, edge: .top))
        .padding(.horizontal, 16)
        .padding(.top, NotchMetrics.trackInfoTopSpacing)
    }

    /// 快捷操作里的一颗图标键。`label` 当读屏标签,同时喂给自绘的悬浮提示(见 `QuickActionTooltipOverlay`)
    /// —— 这几颗都是纯图标,没有文字。悬停 / 按下反馈在 `NotchIconButton` 里(2026-09-07 加,跟三键同一份)。
    ///
    /// ⚠️ `.help(label)` 2026-09-09 撤掉了:系统 tooltip 在这扇窗上一次都没弹过,理由与替代方案见
    /// `QuickActionTooltipOverlay` 的头注。
    private func quickActionButton(_ systemName: String, label: String, dimmed: Bool = false,
                                   action: @escaping () -> Void) -> some View {
        NotchIconButton(systemName: systemName, glyphSize: 11, hitSize: NotchMetrics.trackInfoActionsHeight,
                        tint: accentOrWhite, glyphOpacity: dimmed ? 0.4 : 0.75, action: action)
            // 指针进出这颗键。离开时**只在"记着的还是自己"时**才清 —— 相邻两颗键的 enter/exit
            // 到达顺序没有保证,少了这道守卫会出现 B 刚记上就被 A 那条迟到的 exit 抹掉。
            .onHover { inside in
                if inside {
                    hoveredQuickAction = QuickActionHint(key: systemName, text: label)
                } else if hoveredQuickAction?.key == systemName {
                    hoveredQuickAction = nil
                }
            }
            // 「显示 / 隐藏歌词」那颗点完 `label` 就变,但指针没动、`onHover` 不会再来一次 —— 不同步
            // 的话气泡会停在点之前那句,而这颗键的状态本来就靠这句提示交代(05 章决策 28)。
            .onChange(of: label) { _, newLabel in
                if hoveredQuickAction?.key == systemName {
                    hoveredQuickAction = QuickActionHint(key: systemName, text: newLabel)
                }
            }
            // 把自己的位置报给上面那层,气泡靠它对准这颗键 —— 几何交给 SwiftUI 算,不在别处照着
            // 「22 + spacing 2 + 分隔线」再手写一份坐标(那种两处各算一份的数迟早会漂)。
            .anchorPreference(key: QuickActionAnchorKey.self, value: .bounds) { [systemName: $0] }
            .accessibilityLabel(label)
    }

    private var nextLineDisplayText: String {
        playback.nextLineText ?? ""
    }

    // ⚠️ 必须用 checkForCurrentPlayerSafely(异步),不能用同步版本——理由跟
    // LyricsOverlayView.swift 同名方法的注释一致:同步版本在还没问过时会直接触达有据
    // 可查、可能永久挂起主线程的系统 API。权限不够时用 NSSound.beep() 给一个"没有
    // 生效"的听觉反馈(2026-08-02 补上,跟另外两处播放控制入口保持一致),不静默无声。
    /// glyphSize/hitSize 显式给时优先(展开卡里的三键要比耳朵里的大一号,2026-08-19),
    /// 不给就沿用 primary 的两档旧尺寸(耳朵那一个)。
    private func controlButton(_ systemName: String, primary: Bool = false,
                               glyphSize: CGFloat? = nil, hitSize: CGFloat? = nil,
                               action: @escaping () -> Void) -> some View {
        let glyph = glyphSize ?? (primary ? 11 : 9.5)
        let hit = hitSize ?? (primary ? 18 : 15)
        return NotchIconButton(systemName: systemName, glyphSize: glyph, hitSize: hit,
                               tint: accentOrWhite, glyphOpacity: 1) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                action()
            }
        }
    }
}

/// 快捷操作那排键上此刻被指到的那一颗。`key` 用 SF Symbol 名(每颗键都不重复、且**不随状态变**),
/// `text` 是要弹的那句 —— 「显示 / 隐藏歌词」那颗的文案会跟着开关翻,所以两者得分开存:靠 key 认人,
/// 靠 text 显示(见 `quickActionButton` 里那条 `onChange`)。
private struct QuickActionHint: Equatable {
    let key: String
    let text: String
}

/// 快捷操作那排图标键的悬浮文案提示(2026-09-09,用户:「帮我灵动岛展开状态的这几个按钮,悬浮上面加
/// 一个对应的文案提示」)。
///
/// ⚠️ **不能靠 `.help()`** —— 那行代码 2026-09-07 起就写在 `quickActionButton` 里、注释还写着「label
/// 同时当 tooltip 和读屏标签」,但它一次都没弹过:AppKit 的 tooltip(`NSToolTipManager`)只在**前台
/// App** 的窗口上显示,而 lyrimuse 是 LSUIElement、灵动岛这扇 `.nonactivatingPanel` 又刻意不激活 App
/// (见 `NotchLyricsWindow.canBecomeKey` 那段)—— 用户 hover 的时候前台是他正在用的那个 App,小黄框
/// 永远不会来。跟悬浮歌词那排图标 2026-08 删掉 `.help()` 属同一类死代码(那边的成因是窗口点击穿透、
/// 连 hover 都收不到)。所以这里自绘,并把 `.help()` 一并撤掉:留着的话哪天 App 恰好在前台,系统气泡
/// 会跟自绘的这个一起弹两个。
///
/// **落点对准那颗键**:头部那排往**下**弹(下面是歌词行)、空闲面板那排往**上**弹(它贴着卡片底,
/// `idlePanelBottomSpacing` 只剩 10pt,往下会被窗口硬裁 —— 窗口恒按 `cardHeight` 开,放不进就是裁掉,
/// 不会自己长高)。第一版把气泡钉在按钮排**左侧**固定位置,离线渲染一看就废了:指到最右那颗 ✕ 时
/// 气泡出现在最左边、跟高亮的键隔着四个图标,"这句话说的是哪颗"当场断掉。
///
/// 位置怎么来的:每颗键用 `anchorPreference` 把自己的 bounds 报上来(见 `quickActionButton`),这里
/// `proxy[anchor]` 取回来 —— **几何交给 SwiftUI 算**,不在这儿照着「22 + spacing 2 + 分隔线 1 + 6」
/// 再手写一份坐标(那种两处各算一份的数迟早会漂,同 `cardHeight` 与内容高度共用一个函数的理由)。
/// 挂在**整行**上而不是那排按钮上,是因为要把气泡收敛在卡片内:按钮排自己只有 100pt 宽,量不到
/// "内容区还剩多少"。气泡尺寸靠一层 `GeometryReader` 回填(同 `NotchScrubber` 量宽度的老办法),
/// 量到之前不显示 —— 否则第一帧会按半宽 0 定位、然后跳一下。
///
/// `overlay` 不参与布局,邻居一个像素不动(同 `NotchIconButton` 那条「悬停不许推动邻居」);整层
/// `allowsHitTesting(false)`,气泡不拦下面歌词行 / 顶行的点击。底色**破例用黑**、不用这张卡惯用的
/// `tint` 低透明度:它得**盖住**底下的歌词才读得清,而 tint 低透明度是透的;卡片永远深底(纯黑 /
/// 深色渐变 / 封面模糊),黑底气泡不突兀。
///
/// 时序照系统 tooltip 的手感:**首次悬停等 `initialDelayMs`** 再弹(扫过一排键时不该一路闪)、
/// **已经弹着时换键立即换字**。`shown` 与 `hovered` 因此是两个 state,不是一个。
private struct QuickActionTooltipOverlay: ViewModifier {
    let hovered: QuickActionHint?
    @Binding var shown: QuickActionHint?
    let tint: Color
    /// 气泡贴在那颗键的哪一侧。
    let edge: VerticalEdge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 气泡自己量出来的尺寸(见下面那层 preference)。**只用来收敛边界**,不是显示的前提 ——
    /// 量不到时走 `fallbackHeight` 那条降级路,气泡照画,只是不夹边;拿它当前提就变成
    /// "量不到 → 永远不显示"的全有全无。
    @State private var bubbleSize: CGSize = .zero

    private static let gap: CGFloat = 5
    /// 首次悬停到弹出的延迟。**跟系统 tooltip 在这个 App 里的延迟同一档** —— `AppDelegate` 把
    /// `NSInitialToolTipDelay` 注册成了 150(系统默认 1～1.5s "太长,容易被误以为悬浮提示没工作"),
    /// 自绘的这份要是另取一个数,同一个 App 里就有两种悬浮提示、两种手感。
    private static let initialDelayMs = 150
    /// 还没量到时的估算高度:11pt 字 + 上下各 3pt 内边距,离线量过就是 20。垂直位置对得上比
    /// 夹边重要 —— 差一点会压在键上。
    private static let fallbackHeight: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(QuickActionAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let shown, let anchor = anchors[shown.key] {
                        let key = proxy[anchor]
                        let half = bubbleSize.width / 2
                        let height = bubbleSize.height > 0 ? bubbleSize.height : Self.fallbackHeight
                        bubble(shown.text)
                            // 量自己多宽多高,回填给上面收敛用。走 preference 而不是
                            // `onAppear`:preference 是布局的产物,不靠视图生命周期的回调
                            // (同 `SettingsPopoverShell` 量浮层高度那份)。
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(key: QuickActionBubbleSizeKey.self,
                                                           value: g.size)
                                }
                            )
                            .position(
                                // 对准键的中心,再夹进内容区 —— 最右那颗 ✕ 的气泡不夹的话会溢出
                                // 卡片、被那道圆角裁掉半句话。
                                x: min(max(key.midX, half), max(half, proxy.size.width - half)),
                                y: edge == .bottom
                                    ? key.maxY + Self.gap + height / 2
                                    : key.minY - Self.gap - height / 2)
                    }
                }
                // 收在 overlay 里面接:气泡的 preference 只要传到同一层的这个祖先,不用穿出
                // overlay 边界。
                .onPreferenceChange(QuickActionBubbleSizeKey.self) { bubbleSize = $0 }
                .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: shown)
            .task(id: hovered) {
                guard let hovered else {
                    shown = nil
                    return
                }
                if shown == nil {
                    try? await Task.sleep(for: .milliseconds(Self.initialDelayMs))
                    if Task.isCancelled { return }
                }
                shown = hovered
            }
            // 兜底:这块内容整个走掉时别把气泡的状态留在身上(展开/收起走的是透明度、不会 disappear,
            // 真正会走的是切屏幕镜像 / 关灵动岛那种整树重建)。
            .onDisappear { shown = nil }
    }

    /// 气泡本体。字形 11pt medium、`tint` **全亮** —— 它是"要读的那句话",不该比旁边 0.75 的图标还淡
    /// (同日「合并明细」那一列专辑名的教训:次要 ≠ 该看不清)。
    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    // 0.78 而不是更轻的一档:卡片底可以是**封面模糊**(亮封面时那块底是浅的),
                    // 离线渲染过 0.62 那版 —— 底下的字会从气泡里透出来。它的活儿是盖住,不是透。
                    .fill(Color.black.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tint.opacity(0.14))
                    )
            )
            .fixedSize()
    }
}

/// 气泡量出来的尺寸,只给 `QuickActionTooltipOverlay` 收敛边界用。
private struct QuickActionBubbleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 那排键各自的位置(键名 → bounds),`quickActionButton` 报上来、`QuickActionTooltipOverlay` 取用。
private struct QuickActionAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 灵动岛卡片里**所有纯图标键**的那一层壳(2026-09-07,用户:「帮我给灵动岛上那几个按钮加上悬浮高亮的
/// 效果……现在移动上去都没有什么反馈」):悬停时字形底下浮出一块 `tint` 14% 的圆角底、字形抬到全亮;
/// 按下底色加深到 24%、整颗缩到 0.9,松手弹回。头部快捷操作四颗、空闲面板三颗、展开卡三键、耳朵三键
/// 全走这一份 —— 同一张卡上的按钮反馈必须一致,不能一排会亮一排不会(用户点名的是快捷操作那排,三键
/// 一起改是因为它们就在同一张展开卡里、同一档 22pt 命中框,只改一排等于把不一致做进去)。
///
/// * 独立 View 而不是 modifier 函数,理由同菜单栏面板的 `ChipButton`:悬停状态要**每颗键自己**一份
///   `@State`;按下态从 `ButtonStyle.Configuration.isPressed` 读,不自己追手势。
/// * 反馈色用 `tint`(卡片的 `accentOrWhite`)的低透明度,不写死白/灰:强调色模式下底色跟字形同色系,
///   白字模式下就是白色 14%。跟菜单栏面板 `ChipStyle` 拿 `.primary` 低透明度是同一个思路,但这里不能用
///   `.primary` —— 卡片永远是深底,`.primary` 在浅色系统外观下是黑的。
/// * 悬停只改字形透明度和底色、**不改尺寸**:命中框恒 `hitSize`,底也画在这个框里,邻居一个像素不动
///   (同卡进度条 2026-08-19 那条「悬停变粗不许推动邻居」的教训)。
/// * `reduceMotion` 下不补间,但保留变色和缩放本身 —— 它们是"点到了"的功能反馈,不是装饰(同歌词窗口
///   `TransportButtonStyle`)。
/// * SwiftUI 的 `.onHover` 在这扇从不激活 App 的窗口里收得到(同卡进度条 `hoveringScrubber` 早就靠它)。
///   设置页预览卡整块 `allowsHitTesting(false)`,那里不会亮 —— 预览上这块本来就是点开浮层的热区。
private struct NotchIconButton: View {
    let systemName: String
    let glyphSize: CGFloat
    let hitSize: CGFloat
    let tint: Color
    /// 平时字形的不透明度(快捷操作 0.75 / 关着的「显示歌词」0.4 / 播放三键 1);悬停抬 0.25、封顶 1 ——
    /// 关着的那颗悬停到 0.65,仍读得出"这是关的",但看得出它在响应。
    let glyphOpacity: Double
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering ? min(1, glyphOpacity + 0.25) : glyphOpacity))
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        // 圆角按命中框的比例取(22 → 6,18 → 5,15 → 4),跟歌词窗口 22pt 高的 `OffsetNudgeButton` 用 6 一致。
        .buttonStyle(NotchIconButtonStyle(tint: tint, cornerRadius: (hitSize * 0.27).rounded(),
                                          hovering: hovering))
        .onHover { hovering = $0 }
    }
}

private struct NotchIconButtonStyle: ButtonStyle {
    let tint: Color
    let cornerRadius: CGFloat
    let hovering: Bool
    /// 静止时底色的透明度。纯图标键是 0(静止时没有底,悬停才浮出来);带文字的胶囊键(`NotchPillButton`)
    /// 给 0.12 —— 没有底的一句文字看起来是标签,不是键。悬停 / 按下在它之上再抬一档,三档单调递增。
    var restingLevel: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let level: Double = pressed ? max(0.24, restingLevel + 0.12)
            : (hovering ? max(0.14, restingLevel + 0.08) : restingLevel)
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(level))
            )
            // 悬停给的是"这里可按",按下要给"按到了":缩一点、底色再深一档。曲线同菜单栏面板 `ChipStyle`。
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.65), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

/// 「自己持有 hover 状态」的一层壳(2026-09-11)。
///
/// 为什么需要它:`artworkThumbnail` / `lyricsOffsetButton` 都是**函数**,同一个函数有多个调用点
/// (封面那份三处:耳朵 32pt、稳态歌词行、展开头部)。把 `@State private var hovering` 放进宿主
/// 视图,三处会共用同一个布尔值 —— 悬停耳朵那张会把展开头部那张一起点亮。壳把状态关进每个实例
/// 自己的身体里,调用点不用改成三个独立 struct。
private struct HoverReveal<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

/// 封面缩略图的悬停 / 按下反馈(2026-09-11,用户:「目前这几处的悬浮动效还没做好,做一下」)。
///
/// ⚠️ **不能复用 `NotchIconButtonStyle`**:那份靠"图标背后浮出一层底色"给反馈,而这里的标签是
/// 一张**不透明的图**,背后画什么都看不见。所以改成在图**上面**叠一层白纱,同时把那圈描边抬亮
/// 一档 —— 描边因此从标签里搬进这个 style(它要随状态变,留在标签里只能是定值)。
///
/// ⚠️ **悬停不放大,只有按下才缩到 0.96**。放大会顶出容器:`artworkThumbnail` 最小的调用点是
/// 耳朵那档 32pt,外层是按 32pt 排的;缩小没有这个风险。这条跟 `lyricsOffsetButton` 上那条
/// "别撑高时间行"是同一个纪律 —— 这张卡的几何余量是算过账的,反馈只准在原地做。
private struct NotchArtworkButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return configuration.label
            .overlay(shape.fill(.white.opacity(pressed ? 0.16 : (hovering ? 0.08 : 0))))
            .overlay(shape.strokeBorder(.white.opacity(pressed ? 0.5 : (hovering ? 0.38 : 0.18)),
                                        lineWidth: 0.5))
            .scaleEffect(pressed ? 0.96 : 1)
            // 曲线跟 NotchIconButtonStyle 一字不差 —— 同一张卡上两种键的手感不该有差别。
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.65), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

/// 带文字的胶囊键(2026-09-08,首个用途是广告态那颗「跳过广告」)。悬停 / 按下反馈跟 `NotchIconButton`
/// 同一份 `NotchIconButtonStyle`,只多一层 12% 的静止底(理由见 `restingLevel`);高度跟快捷操作 / 三键
/// 同档 22pt,文字 11pt semibold —— 它跟那些图标键排在同一张卡上,不该比它们重。
private struct NotchPillButton: View {
    let systemName: String
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 9.5, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint.opacity(hovering ? 1 : 0.85))
            .padding(.horizontal, 9)
            .frame(height: NotchMetrics.trackInfoActionsHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(NotchIconButtonStyle(tint: tint, cornerRadius: NotchMetrics.trackInfoActionsHeight / 2,
                                          hovering: hovering, restingLevel: 0.12))
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}


/// 歌词行上「瞬态横幅盖歌词」这层壳,单独订阅 NotchTransientCenter(2026-08-19 性能
/// 审计落地):banner 只被这一行消费,原来订阅挂在 NotchLyricsView 根上,音量连调时每档
/// 一次的 @Published 变化会打醒整卡 body(含封面背景/跑马灯/音浪)。下沉之后横幅出现/
/// 消失只失效这一行。
private struct NotchTransientHost<Fallback: View>: View {
    @ObservedObject private var transients = NotchTransientCenter.shared
    let tint: Color
    @ViewBuilder let fallback: () -> Fallback

    init(tint: Color, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.tint = tint
        self.fallback = fallback
    }

    var body: some View {
        ZStack {
            if let banner = transients.banner {
                NotchTransientRow(banner: banner, tint: tint)
                    .transition(.opacity)
            } else {
                fallback()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: transients.banner)
    }
}

/// 展开卡里的进度条 + 时间行,独立子视图(2026-08-19 性能审计落地,两件事):
/// ① 拖动的三个交互状态(@GestureState/测宽/悬停)在这里自持 —— 原来挂在
///    NotchLyricsView 根上,拖动时每个指针事件(60~120Hz)都整卡重估,实际要变的只有
///    这十来个视图;
/// ② TimelineView 补上 minimumInterval —— 原来是全仓唯一没封帧率上限的 .animation
///    时刻表(正是 2026-08-15 那次「只给窗口加了上限,这里和灵动岛漏了」同款失误的
///    残留),hover 展开+播放中按显示器刷新率(ProMotion 120Hz)驱动一条每秒只走
///    ~1.8pt、时间文字每秒才变一次的进度条。30Hz 与其余三处逐字填色同一口径。
///
/// 两种数据来源,跟「歌词窗口」的 progressSection 同一套三态口径:
///  - **播放中**:anchor 在,按帧从锚点外推;
///  - **暂停**:anchor 被清成 nil(见 PlaybackCoordinator.pausedPositionMs 的注释),
///    改用冻结位置 + 曲目时长照常显示,无 TimelineView。
/// ⚠️ 暂停这一档是 2026-08-17 补的:在那之前一暂停整条进度条凭空消失,顺带让展开区
/// 失去撑宽度的内容(「暂停时下一句歌词跑到中间」的根源,见 expandedContent 末尾注释)。
private struct NotchScrubber: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    let isPlayingNow: Bool
    let tint: Color
    /// 「歌词时间轴微调」(2026-09-01,菜单栏面板同款功能的灵动岛入口)要不要塞进时间行
    /// 中间——三项都是纯渲染参数,理由见 `NotchPlayback.showsLyricsOffsetControls` 上面
    /// 那条注释(不影响卡片几何,不走 `NotchChromeSource`)。
    let showsLyricsOffsetControls: Bool
    let trackLyricsOffsetMs: Int
    let lyricsOffsetStepMs: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 所在的展开区此刻是不是可见的(NotchLyricsView.cardBodyLayer):展开区常驻、稳态下藏着,藏着时停表。
    @Environment(\.notchCardLayerActive) private var cardLayerActive

    // 正在拖进度条时手指所在的比例(0~1);没在拖就是 nil。
    // 用 @GestureState:手势被取消时(拖动中这块条件分支被摘掉)自动复位,@State 会永久卡住。
    @GestureState private var scrubbingFraction: Double?
    // 进度条那一块的实际宽度,拖拽换算比例用。
    @State private var scrubWidth: CGFloat = 0
    /// 光标是否停在进度条那一小条上(只影响它自己的粗细,跟卡片展开无关)。
    @State private var hoveringScrubber = false

    var body: some View {
        if let anchor, anchor.durationMs > 0 {
            TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                    paused: !isPlayingNow || !cardLayerActive)) { context in
                // 拖动期间显示手指按住的位置,而不是外推出的真实位置——否则进度条会在
                // 手指底下被 TimelineView 每帧拉回去。松手才真的发 seek。
                let currentMs = scrubbingFraction.map { Int($0 * Double(anchor.durationMs)) }
                    ?? anchor.extrapolatedPositionMs(now: context.date)
                scrubberAndTimes(currentMs: currentMs, durationMs: anchor.durationMs)
            }
        } else if let paused = pausedPositionMs,
                  let duration = durationMs, duration > 0 {
            // 暂停态不需要 TimelineView —— 位置是冻住的,没有随时间推进这回事。
            let currentMs = scrubbingFraction.map { Int($0 * Double(duration)) } ?? paused
            scrubberAndTimes(currentMs: currentMs, durationMs: duration)
        }
    }

    /// 进度条本体 + 下面那行时间。播放态和暂停态共用,只是 currentMs/durationMs 的来源不同。
    private func scrubberAndTimes(currentMs: Int, durationMs: Int) -> some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let fraction = min(1, max(0, Double(currentMs) / Double(durationMs)))
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.18))
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: proxy.size.width * fraction)
                }
                // 变粗只发生在下面那个**恒定高度的槽**里(垂直居中),布局上不占多一分 ——
                // 原来 .frame(height: scrubberHeight) 直接参与布局,悬停 3→5 那 2pt 会把
                // 时间行和三键整块往下推一下(2026-08-19 用户报"移到进度条上按钮会位移")。
                .frame(height: scrubberHeight)
                .frame(maxHeight: .infinity)
                // reduceMotion 下仍然变粗(那是功能反馈,不是装饰),只是不补间。
                .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7),
                           value: scrubberHeight)
            }
            // 布局槽恒为最粗形态(拖动中的 6pt)的高度,悬停/拖动只改槽内的条,不动邻居。
            .frame(height: 6)
            // 命中区**只覆盖进度条这一行**,不含下面的时间行——原来挂在整块上,
            // 点右侧"剩余时间"文字就等于 seek 到 ~94%(把这首歌跳过去)。
            // 上下各撑 8pt 让 3pt 的条好按,再用等量负 padding 抵消布局:
            // 展开区高度是写死的 expandedExtraHeight(alignment .top),
            // 长高一点就把时间行裁掉。
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .padding(.vertical, -8)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { scrubWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in scrubWidth = w }
                }
            )
            .onHover { hoveringScrubber = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($scrubbingFraction) { value, state, _ in
                        guard scrubWidth > 0 else { return }
                        // state 只有**这次手势的第一帧**才是 nil(@GestureState
                        // 的初始值),拿它当"刚按下"的边沿信号给一次触觉 ——
                        // 放 onChanged 里会每帧都震。
                        if state == nil {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment, performanceTime: .now)
                        }
                        state = min(1, max(0, value.location.x / scrubWidth))
                    }
                    .onEnded { value in
                        guard scrubWidth > 0 else { return }
                        let f = min(1, max(0, value.location.x / scrubWidth))
                        PlaybackCoordinator.shared.seek(toMs: Int(f * Double(durationMs)))
                    }
            )
            HStack {
                Text(Self.timeString(ms: currentMs))
                Spacer()
                // 「歌词时间轴微调」(2026-09-01):中间这一截以前一直空着(两个时间数字
                // 中间的 Spacer),塞进跟菜单栏面板同一份功能的灵动岛入口——见
                // `AppSettings.notchExpandedShowsLyricsOffset` 上面那条⚠️,两个 Spacer
                // 各占一半剩余空间,把中间那截天然居中,关掉开关时跟改动前逐字一样
                // (只剩一个 Spacer)。
                if showsLyricsOffsetControls {
                    lyricsOffsetControls
                    Spacer()
                }
                Text("-" + Self.timeString(ms: max(0, durationMs - currentMs)))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint.opacity(0.4))
            .monospacedDigit()
        }
    }

    // MARK: - 歌词时间轴微调(2026-09-01,菜单栏面板 `MenuBarPanel.offsetControls` 同款功能)

    /// 「− 歌词±0.5s +」。⚠️ 按钮尺寸刻意收窄到跟这一行本身的高度(9pt 字号撑出来的行高,
    /// `NotchExpandedMetrics.scrubberBlock` 里"时间行 11"那个常量)齐平,**不能**照抄菜单栏
    /// 面板那份 16×14——那边的行高本来就是被 14pt 的按钮撑出来的(见
    /// `MenuBarPanel.offsetButton` 的注释,那个面板没有这份高度预算的约束);这里按钮比
    /// 这一行本身的高度高,会把整个时间行顶出 `expandedContent` 预留的高度,被
    /// `.frame(alignment: .top)` 从底部裁掉一截。这也是这个开关全程不进
    /// `NotchExpandedMetrics`/`NotchChromeSource` 那套几何链路的前提——按钮必须真的不
    /// 长高这一行,不是"大概率不会",尺寸因此比菜单栏那份小一档。
    private var lyricsOffsetControls: some View {
        HStack(spacing: 3) {
            lyricsOffsetButton("minus", help: nudgeHelp(L10n.t("延后"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: -lyricsOffsetStepMs)
            }
            offsetReadout
            lyricsOffsetButton("plus", help: nudgeHelp(L10n.t("提前"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: lyricsOffsetStepMs)
            }
        }
    }

    /// 「歌词 +0.5s」/「歌词 0.0s」——值是**这首歌**那一部分,跟菜单栏面板 `offsetText`
    /// 同一个理由(不含设置里的全局基准,归零操作对应的是这个数字清零)。
    private var offsetText: String {
        "\(L10n.t("歌词")) \(AppSettings.signedSeconds(ms: trackLyricsOffsetMs))s"
    }

    /// 中间那块数值。⚠️ **定宽**:数值从「0.0」变到「+10.2」时,两侧的 − / + 不许跟着移位
    /// (2026-09-11 用户要求「歌词偏移调整之后不要改变 -+ 的位置」)。
    ///
    /// 做法是拿**最宽的那个变体**当隐形垫片撑出宽度、真文案叠在上面居中 —— `.hidden()` 仍然
    /// 参与布局,宽度由垫片说了算。为什么不写死一个 pt 宽度:「歌词」这个前缀是本地化的(en 是
    /// "Lyrics"、繁体是「歌詞」),写死的宽度换个语言就不对;垫片跟真文案共用同一份
    /// `L10n.t("歌词")`,三种语言都自动成立。
    ///
    /// `.monospacedDigit()` 管另一半:等宽数字让「+0.2」→「+0.8」这种同位数变化也不抖。
    /// 偏移**没有上下界**(`LyricsOffsetStore.nudge` 不 clamp),真调到 ±100s 就靠
    /// `minimumScaleFactor` 把字缩一点,而不是把按钮推走 —— 位置稳定优先于字号。
    private var offsetReadout: some View {
        let canReset = trackLyricsOffsetMs != 0
        return HoverReveal { hovering in
            // ⚠️ 垫片必须**独占尺寸**、真文案走 `.overlay`。**写成 ZStack 是错的**:ZStack 的宽度
            // 取最宽的那个子视图,真文案照样能把它撑大 —— 离屏实测(NSHostingView.fittingSize):
            // ZStack 版在两位整数秒时 46 → 51/52pt、「+100.0s」到 58pt,极差 12pt,等于没修;
            // overlay 版七种数值全是 46pt,极差 0.00pt。`minimumScaleFactor` 只在宽度**被约束**
            // 时才介入,而 ZStack 压根没约束它;overlay 的尺寸由父视图说了算、反过来撑不大父视图,
            // 所以约束是真的存在,超长值走缩放而不是推走按钮。
            Text(offsetWidthTemplate)
                .hidden()
                .overlay {
                    Text(offsetText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .monospacedDigit()
                // 这块是可点的(点击归零),所以也该有悬停反馈;底色语言跟两侧的 − / + 同一档
                // (NotchIconButtonStyle 的 hover 也是 0.14)。归零无意义时(值本来就是 0)不亮。
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tint.opacity(canReset && hovering ? 0.14 : 0))
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canReset else { return }
                    PlaybackCoordinator.shared.resetLyricsOffset()
                }
                .modifier(OptionalHelp(text: canReset ? L10n.t("点击归零") : nil))
        }
    }

    /// 撑宽度用的最宽变体:符号 + **一位**整数 + 一位小数。
    ///
    /// ⚠️ 为什么不预留两位整数(`+10.2s`):那样静止态(`0.0s`)会永久多出 12pt 空隙、− / + 被推得
    /// 离数字明显更远(实测 40pt → 52pt);收成一位只多 6pt(40 → 46)。而歌词偏移调到 ±10 秒
    /// 这首歌的词已经完全对不上了,不值得为这个量级常驻一份空隙。真超过就由
    /// `minimumScaleFactor(0.7)` 把字缩一点(`+10.2s` 需要 50pt/46pt ≈ 0.92,远在 0.7 之内,
    /// 缩了也看不出来),**宽度仍然恒定** —— 位置稳定是硬要求,字号不是。
    /// 这个"缩而不是推"只有在 `offsetReadout` 用 overlay(而不是 ZStack)时才成立,见那边的 ⚠️。
    private var offsetWidthTemplate: String {
        "\(L10n.t("歌词")) +2.2s"
    }

    private func nudgeHelp(_ verb: String) -> String {
        "\(verb) \(AppSettings.formattedSeconds(ms: lyricsOffsetStepMs))\(L10n.t("秒"))"
    }

    /// ⚠️ 悬停 / 按下的底色**只能画在 10×11 这个标签尺寸上**(2026-09-11 补反馈时的约束)。
    /// 这一行的高度是 9pt 字号撑出来的(见 `lyricsOffsetControls` 上面那段),键只要比行高一点,
    /// 就会把时间行顶出 `expandedContent` 预留的高度、被 `.frame(alignment: .top)` 从底部裁掉。
    /// `NotchIconButtonStyle` 正好满足:它的 background 不改布局尺寸,press 的 scaleEffect 只缩
    /// 不放。**别**改成用 padding 把底色撑大 —— 那等于把这颗键的高度交还给布局。
    ///
    /// 负 padding 刻意留在 `HoverReveal` **外面**:壳把 `.onHover` 挂在它收到的那份内容上,而
    /// 那份内容到 `.contentShape(Rectangle())` 为止是**扩过的 20×21**。这样"能按到的范围"和
    /// "会亮的范围"是同一块;把负 padding 挪进去,hover 就缩回 10×11、按得到却不亮。
    private func lyricsOffsetButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        HoverReveal { hovering in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .semibold))
                    .frame(width: 10, height: 11)
            }
            .buttonStyle(NotchIconButtonStyle(tint: tint, cornerRadius: 3, hovering: hovering))
            // 命中区上下左右各扩 5pt,跟上面进度条命中区同一个技巧:padding 撑开
            // contentShape,再用等量负 padding 抵消对布局尺寸的影响——按钮本身画多小,
            // 手指/鼠标能按到的范围都不因此缩水,但不会把这一行的实际高度撑高。
            .padding(5)
            .contentShape(Rectangle())
        }
        .padding(-5)
        .modifier(OptionalHelp(text: help))
    }

    /// 进度条轨道的粗细:悬停变粗一点、真按住再粗一点。
    ///
    /// 这条轨道稳态只有 3pt,手指压上去几乎看不见自己有没有抓住 —— 它已经为此配了一圈
    /// 上下各 8pt 的隐形命中区(见 gesture 那段注释),但那是"能不能按到"的问题,这里补的是
    /// "有没有按到"的**反馈**。
    ///
    /// ⚠️ 幅度必须克制。参考实现是 5→9pt(+4),但那是在一个高得多的面板里;灵动岛展开区
    /// 总共只有 expandedExtraHeight,进度条 + 3pt 间距 + 时间行已经占掉大半,
    /// 再长 4pt 会把时间行往下挤出可见区。3→5→6 是量过余量之后的取值。
    private var scrubberHeight: CGFloat {
        if scrubbingFraction != nil { return 6 }
        return hoveringScrubber ? 5 : 3
    }

    private static func timeString(ms: Int) -> String { NotchTimeFormat.mmss(ms: ms) }
}

/// `m:ss` —— 迷你进度条底下那行时间和「已播/剩余时长」两个耳朵模块共用一份。
///
/// 抽出来是因为 2026-08-31 加耳朵模块时差点在 NotchLyricsView 里再写一份:同一个卡片上两处
/// 时间格式不一样(一处补前导零、一处不补)是那种没人会当 bug 报、但看着就是不对劲的东西。
enum NotchTimeFormat {
    /// 拿不到锚点时那条秒表的兜底起点。
    /// ⚠️ 放在这里而不是 NotchLyricsView 里:那是个泛型类型(`<Chrome: NotchChromeSource>`),
    /// Swift 不允许泛型类型有 static 存储属性。
    static let clockEpoch = Date(timeIntervalSince1970: 0)

    /// 时间类耳朵模块那条秒表的时刻表 —— **相位对齐到"曲目位置正好走到整秒"的那个墙钟时刻**,
    /// 步长按倍速取 `1/rate`。
    ///
    /// 为什么不能直接钉在墙钟整秒上(`from: clockEpoch`):曲目位置 p(t) = progressMs + 走过的时间,
    /// 它的整秒边界跟墙钟整秒**没有任何关系**,两者的相位差 φ 由 seek/换歌那一刻的锚点定死、
    /// 在这条锚点的整个生命周期里是**常量**。于是 hover 展开时,耳朵可能**整首歌**都比正下方那条
    /// 迷你进度条(30Hz,同一份 `mmss`)慢 1 秒 —— 耳朵 1:23、进度条 1:24 长期并排杵着,
    /// 而不是偶尔闪一下。按锚点均匀分布,期望约一半时间在错位。
    ///
    /// ⚠️ 只读 `fetchedAt`/`progressMs`/`rate` 这些**低频**字段,不碰 `Date()` —— 相位在 body
    /// 反复重估之间因此是稳定的,不会退回"每次重绘都把时钟相位重挪一次"那个问题。
    static func clockSchedule(for anchor: ProgressAnchor) -> PeriodicTimelineSchedule {
        guard anchor.rate > 0 else { return .periodic(from: clockEpoch, by: 1) }
        let ref = anchor.fetchedAt
        let posAtRef = Double(anchor.extrapolatedPositionMs(now: ref))
        let msToBoundary = 1000 - posAtRef.truncatingRemainder(dividingBy: 1000)
        return .periodic(from: ref.addingTimeInterval(msToBoundary / 1000 / anchor.rate),
                         by: 1 / anchor.rate)
    }

    static func mmss(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// 顶部两个角是直角、只有底部两个角带圆角的卡片形状——SwiftUI 的 RoundedRectangle
// 只支持四角统一圆角,`UnevenRoundedRectangle` 又要 macOS 26 起才有(这个项目部署
// 目标是 14),手写一个 Shape 直接按四段直线+两段圆弧画出这个轮廓,不依赖新 API。
// 不加 private:「外观」页的灵动岛预览(NotchPreviewBar)要用同一个形状画预览卡,
// 复制一份轮廓代码只会让两边慢慢漂开。
/// 顶行以下某一块内容"此刻是不是可见的那份"(NotchLyricsView.cardBodyLayer):可见 = 正常;藏着 = 透明、不吃点击、
/// 对读屏隐藏,并通过环境值 `notchCardLayerActive` 让里面的 TimelineView 停表。四件事收在一处,免得哪一块漏一件。
struct NotchCardLayerActive: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.notchCardLayerActive, active)
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}

/// 卡片自己那道外形裁剪,可按宿主关掉(理由见 NotchLyricsView.body 末尾与 EnvironmentValues.notchHostClipsCard)。
/// `enabled` 对某个宿主是常量;运行期切换会换分支、重建 content 子树。
struct NotchCardClip: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.clipShape(NotchHangingShape(bottomCornerRadius: 20))
        } else {
            content
        }
    }
}

struct NotchHangingShape: Shape {
    var bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(bottomCornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}


// MARK: - 「发现新播放器」的两个宿主(2026-09-11,决策 #37)

/// 收起态左耳那一格的宿主:平时是 fallback(`idleAppIcon`,Lyrimuse 自己的图标);`NotchUnknownPlayerPrompt`
/// 挂着信任提议时换成**那个播放器**的图标 + 右上角一粒小圆点。订阅下沉到这里,提议挂上 / 撤掉只失效这一格
///(同 `NotchTransientHost` 那条 2026-08-19 性能审计纪律)。
///
/// 图标走 `AppIconResolver.icon(forBundleID:)`(跟菜单栏面板那枚来源角标、设置页「已信任的其它播放器」列表
/// 同一份缓存),再经 `NotchIdleAppIcon.bitmap(of:cacheKey:pixelSide:)` 按像素预先光栅化 —— 跟 App 图标那枚
/// 同一个锯齿问题、同一个解法。反查不到图标(App 装在非常规位置)时退回 fallback:提议本身还在,hover 展开
/// 照样能看到、能点,只是收起态少了那条线索。
///
/// 小圆点**破例用红**、不走这张卡的 tint:它是"有事等你处理"的角标,不是内容装饰 —— Dock / 系统通知的角标
/// 就是红的,换成 tint 在「跟随封面取色」下会变成一粒随机颜色的点,读不出"未处理"的意思。外面描 1pt 黑边,
/// 跟图标的浅色边角分开(卡片底本来就是纯黑,黑边等于一圈留白)。
private struct NotchIdleEarIconHost<Fallback: View>: View {
    @ObservedObject private var prompt: NotchUnknownPlayerPrompt
    let side: CGFloat
    let scale: CGFloat
    let alignment: Alignment
    @ViewBuilder let fallback: () -> Fallback

    init(prompt: NotchUnknownPlayerPrompt, side: CGFloat, scale: CGFloat, alignment: Alignment,
         @ViewBuilder fallback: @escaping () -> Fallback) {
        self.prompt = prompt
        self.side = side
        self.scale = scale
        self.alignment = alignment
        self.fallback = fallback
    }

    /// 圆点直径。7pt 在 26pt 的图标角上是 iOS 角标那个量级,再小看不见、再大盖住图标一角。
    /// (泛型类型里放不了 static 存储属性,所以是计算属性。)
    private static var badgeSide: CGFloat { 7 }

    var body: some View {
        if let offer = prompt.offer,
           let icon = AppIconResolver.icon(forBundleID: offer.bundleID),
           let bitmap = NotchIdleAppIcon.bitmap(of: icon, cacheKey: offer.bundleID,
                                                pixelSide: Int((side * scale).rounded())) {
            Image(decorative: bitmap, scale: scale)
                .frame(width: side, height: side)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.red)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                        .frame(width: Self.badgeSide, height: Self.badgeSide)
                        // 往角外挪一点:压在图标圆角上而不是整颗落在图标里面,角标的惯例。
                        .offset(x: 2, y: -2)
                }
                .frame(maxWidth: .infinity, alignment: alignment)
                .accessibilityLabel(L10n.t("检测到新的播放器") + " " + offer.displayName)
                .transition(.opacity)
        } else {
            fallback()
        }
    }
}

/// 没有曲目时 hover 展开出来那一块的宿主:平时是 fallback(`idleExpandedPanel`,「没有在播放」+ 三颗键);
/// `NotchUnknownPlayerPrompt` 挂着信任提议时换成:
///
///     检测到新的播放器                                [✓ 加入信任列表] [×]
///     Podcasts · 正在放:热可可 - 28. …
///
/// 排法、字号、行距、按钮档位**逐项照抄** `idleExpandedPanel`(左边两行字按头部歌名 / 歌手两档行高,右边一排
/// 22pt 键,同样的 16pt 左右内边距与 `trackInfoTopSpacing`)—— 高度必须跟它**一样**:`NotchChromeSource.cardHeight`
/// 的 `!hasTrack` 分支只认 `idlePanelHeight` 一个数,这里若高一截就被窗口硬裁、矮一截就底下留空。第一行只用
/// 通知那条现成的标题键,播放器名挪到第二行行首(`名字 · 正在放:…`),不新造带占位符的词条 —— 本地化表是四份
/// 手写文件 + 一份 xcstrings 真源,加一条键要动五个文件、且 xcstrings 多会话并发改会丢更新(11 章有记录)。
///
/// 「加入信任列表」是文字胶囊键(`NotchPillButton`,跟广告态那颗「跳过广告」同款):这颗键要是做成纯图标,用户
/// 得先猜它是什么才敢点 —— 提议信任是个有后果的动作(信任之后这个 App 的播放会进 Last.fm / ListenBrainz),
/// 文案必须摆在明面上。× 是"这次别烦我"(`NotchUnknownPlayerPrompt.dismiss`,同一段播放里不再挂),纯图标 +
/// 自绘悬浮提示(`QuickActionTooltipOverlay`,`.help()` 在这扇窗上永远不弹,理由见那个类型的头注)。
///
/// 这一块自己**不**读 `hasTrack` / `isExpanded`:它跟 `idleExpandedPanel` 一样只在没有曲目时被外层挂上,
/// 稳态下透明地待在顶行下面、展开时原地淡入,那套由外层的 `NotchCardLayerActive` 管。
private struct NotchIdlePanelHost<Fallback: View>: View {
    @ObservedObject private var prompt: NotchUnknownPlayerPrompt
    let tint: Color
    @ViewBuilder let fallback: () -> Fallback

    /// × 的悬浮提示状态,跟 `NotchLyricsView.hoveredQuickAction` / `shownQuickActionTooltip` 是同一套两段式
    ///(首次 150ms 才弹、已弹着时立即换字),这一块是独立视图,得自己存一份。
    @State private var hoveredAction: QuickActionHint?
    @State private var shownTooltip: QuickActionHint?

    init(prompt: NotchUnknownPlayerPrompt, tint: Color, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.prompt = prompt
        self.tint = tint
        self.fallback = fallback
    }

    var body: some View {
        if let offer = prompt.offer {
            unknownPlayerPanel(offer)
                .transition(.opacity)
        } else {
            fallback()
        }
    }

    /// × 那颗键在悬浮提示登记表里的 key(同 quickActionButton:用 SF Symbol 名)。泛型里放不了 static 存储属性。
    private static var dismissKey: String { "xmark" }

    private func unknownPlayerPanel(_ offer: NotchUnknownPlayerPrompt.Offer) -> some View {
        let dismissLabel = L10n.t("关闭")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: NotchMetrics.trackInfoLineSpacing) {
                Text(L10n.t("检测到新的播放器"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.9))
                Text(offer.displayName + " · " + String(format: L10n.t("正在放：%@"), offer.nowPlayingText))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                NotchPillButton(systemName: "checkmark.shield.fill", title: L10n.t("加入信任列表"), tint: tint) {
                    prompt.trust()
                }
                NotchIconButton(systemName: Self.dismissKey, glyphSize: 11, hitSize: NotchMetrics.trackInfoActionsHeight,
                                tint: tint, glyphOpacity: 0.75) {
                    prompt.dismiss()
                }
                // 下面三样照抄 NotchLyricsView.quickActionButton:进出登记 / 位置上报 / 读屏标签。
                .onHover { inside in
                    if inside {
                        hoveredAction = QuickActionHint(key: Self.dismissKey, text: dismissLabel)
                    } else if hoveredAction?.key == Self.dismissKey {
                        hoveredAction = nil
                    }
                }
                .anchorPreference(key: QuickActionAnchorKey.self, value: .bounds) { [Self.dismissKey: $0] }
                .accessibilityLabel(dismissLabel)
            }
            .frame(height: NotchMetrics.trackInfoActionsHeight)
        }
        // 气泡往上弹:这块面板贴着卡片底,理由同 idleExpandedPanel 那处。
        .modifier(QuickActionTooltipOverlay(hovered: hoveredAction, shown: $shownTooltip, tint: tint, edge: .top))
        .padding(.horizontal, 16)
        .padding(.top, NotchMetrics.trackInfoTopSpacing)
    }
}
