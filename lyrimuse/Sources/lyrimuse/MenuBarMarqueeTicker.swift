import AppKit
import Combine
import Foundation
import LyrimuseCore
import QuartzCore

// 菜单栏歌词跑马灯的驱动器(2026-08-05 加)——把"现在该露出这一句的哪一段"算好、发布给
// MenuBarLabel 渲染。
//
// 为什么需要这么一个独立的驱动器,而不是在 MenuBarLabel 里用动画/TimelineView:
// MenuBarExtra 默认(.menu)样式的 label 挂不住 SwiftUI 的动画/生命周期修饰符(本会话
// 早先实测坐实 `.task` 从来不触发),但 label 会跟着它读的 @Published 值重新渲染。所以
// 节奏必须由模型侧提供 —— 详见 MenuBarMarquee 顶部注释。
//
// 生命周期完全自持:靠 Combine 订阅 AppSettings/PlaybackCoordinator 自己决定何时开停
// 计时器,不依赖任何视图的 onAppear/onDisappear(菜单栏 label 的生命周期本身就不可靠,
// 这是上面那条限制的同一个根源)。
//
// 2026-08-15 改成像素级滚动。原来是每 0.25 秒把窗口整体右移**一个字**,用户实测反馈
// "显得很卡顿" —— 那本质上是个 4fps 的动画,而且窗口按字符数固定、字符宽度却不相等,
// 每跳一次菜单栏项的宽度也跟着变,右边其它 App 的图标被顶得左右晃。现在需要滚的句子改走
// 一张固定宽度的模板图(见 MenuBarMarqueeRenderer),偏移按墙钟时间连续算。装得下的句子和
// 关掉滚动的情况仍旧发布纯文字,一帧图都不画。
@MainActor
final class MenuBarMarqueeTicker: ObservableObject {
    static let shared = MenuBarMarqueeTicker()

    // 装得下的整句 / 关掉滚动时的截断结果。滚动模式下它保持**整句**,只作 tooltip 和
    // 图片没画出来时的兜底。
    @Published private(set) var visibleText: String = ""
    // 需要滚的句子走这张图。nil = 这一句装得下、或者用户关掉了滚动 —— 那两种情况下
    // label 渲染 visibleText 就够了,不必为一张静止的图每秒醒 30 次。
    @Published private(set) var scrollImage: NSImage?

    // 滚动时的帧间隔。
    //
    // 2026-08-16 从 30fps 提到 60fps。原来注释写的是"30fps 足够平滑,再高只是白烧电",
    // 但用户仍然反馈卡。实测(离线基准,见 MenuBarMarqueeRenderer.PreparedLine)每帧成本
    // 从 0.057ms 降到 0.002ms 之后,60fps 每秒也只占主线程 0.1ms —— 比改动前的 30fps
    // 还便宜一个量级,所以"烧电"这条理由不再成立。
    //
    // ⚠️ 这不再是"每拍挪一个字"的节拍器(旧版 0.25 秒一拍),偏移完全按墙钟时间算,
    // 见 recompute()/MenuBarMarquee.scrollOffset。
    private static let frameInterval: TimeInterval = 1.0 / 60
    // 首尾各停 1.5 秒——跟旧版的 6 拍 × 0.25 秒完全一致,这一点观感没变:一句歌词最关键的
    // 往往是开头,一上来就滚会看不清。
    private static let holdSeconds: Double = 1.5
    // 滚动速度:每秒 4 个字,也跟旧版一致(旧版每 0.25 秒挪一个字)。区别只在于这 4 个字的
    // 宽度现在被摊到 30 帧里连续走完,而不是一格一格跳。
    private static let charsPerSecond: CGFloat = 4

    private var timer: Timer?
    // 这一句是什么时候开始显示的。偏移按"距这个时刻过去了多久"算,而不是累加帧数——
    // 计时器回调会被主线程上别的活儿(逐字高亮那套 60fps 重绘)推迟,累加式计帧会把这些
    // 延迟原样变成忽快忽慢的滚动,那正是"卡顿"的另一半来源。
    private var lineStartedAt: CFTimeInterval = CACurrentMediaTime()
    // 60fps 下相邻两帧的位移更小,阈值跟着收紧,否则会把该画的帧也滤掉。
    private var lastRenderedOffset: CGFloat = -1
    private var lastRenderedText: String = ""
    // 这一句的滚动参数算一次就够:它只跟"哪一句 + 显示宽度 + 滚动开关"有关,而那三样一变
    // 都会走 restartLine()。以前每帧都重算,里面有两次 NSString 文字测量(其中一次量的是
    // **整句**),30fps 下纯属白烧。
    private var cachedPlan: ScrollPlan?
    private var cancellables: [AnyCancellable] = []
    private var started = false

    private init() {}

    // AppDelegate 启动时调一次(跟 PlaybackCoordinator.start() 同一批)。
    func start() {
        guard !started else { return }
        started = true
        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared
        // 换句就从头开始滚——每一句都该先看清开头。用 removeDuplicates 是因为
        // currentLine 在同一句内部会因为逐字填色之外的原因被重新赋值(见
        // LocalPlaybackSource.fastTick 的"只在真的换行时才赋值"注释,那边已经防了大部分,
        // 这里再兜一层:纯文本一样就不算换句)。
        //
        // ⚠️ 每一条订阅都必须 .receive(on: RunLoop.main),不能直接 sink——2026-08-05
        // 实测坐实(这个坑这个项目此前已经踩过一次,见"暂停/无播放时隐藏"那次的结论):
        // @Published 的 publisher 是在 willSet 时机发射的,回调执行时属性本身还是**旧值**。
        // 下面这几个回调都不用发射值、而是转头去读 AppSettings/PlaybackCoordinator 的
        // 当前状态(syncTimer()/recompute() 内部都这么做),所以直接 sink 会读到旧值:
        // isPlayingNow 从 false 变 true 时 syncTimer() 读到的仍是 false,计时器永远
        // 启动不起来,表现就是"取窗算对了但完全不滚"。改到下一个 runloop 循环再跑,
        // 属性此时已经落定成新值。
        coordinator.$currentLine
            .map { $0?.plainText ?? "" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restartLine() }
            .store(in: &cancellables)
        // 这几个设置任何一个变了都要立刻重算/重新决定要不要跑计时器。
        settings.$showLyricsInMenuBar.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncTimer() }.store(in: &cancellables)
        // 宽度改了可能从"要滚"变成"装得下"(或者反过来),所以跟换句一样整个重来。
        // ⚠️ 订阅的必须是**现在真正在用的那个**设置(按点计的 maxWidth)。2026-08-15 把宽度
        // 从字数改成点时这里一度还挂在旧的 maxChars 上,后果是拖宽度滑杆完全不生效 ——
        // ScrollPlan 是按句缓存的,不 restartLine 就不会重算。
        settings.$menuBarLyricsMaxWidth.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restartLine() }.store(in: &cancellables)
        coordinator.$isPlayingNow.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncTimer() }.store(in: &cancellables)
        syncTimer()
    }

    /// 这一句从头开始滚(换句、改了滚动开关或显示宽度)。
    private func restartLine() {
        cachedPlan = nil
        lineStartedAt = CACurrentMediaTime()
        lastRenderedOffset = -1
        lastRenderedText = ""
        syncTimer()
    }

    // 只在真的需要滚的时候才让计时器跑:菜单栏歌词关着、没在播放、用户把滚动关了、或者
    // 当前这句本来就装得下,都没必要每帧唤醒一次。
    private func syncTimer() {
        let needed = AppSettings.shared.showLyricsInMenuBar
            && PlaybackCoordinator.shared.isPlayingNow
            && currentScrollPlan() != nil
        if needed {
            if timer == nil {
                // 必须挂 .common mode,否则菜单打开/拖拽悬浮窗时会停摆——跟
                // LocalPlaybackSource 的两个计时器同一个理由。
                let t = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.recompute()
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
        recompute()
    }

    /// 当前这一句要怎么滚。nil = 不用滚(关掉了、没歌词、或者整句本来就装得下)。
    private struct ScrollPlan {
        let text: String
        /// 窗口宽度 = 前 maxChars 个字的宽度。钉死它,菜单栏项的宽度才不会随内容伸缩。
        let windowWidth: CGFloat
        let maxOffset: CGFloat
        let pointsPerSecond: CGFloat
    }

    private func currentScrollPlan() -> ScrollPlan? {
        if let cachedPlan { return cachedPlan }
        let plan = computeScrollPlan()
        cachedPlan = plan
        return plan
    }

    private func computeScrollPlan() -> ScrollPlan? {
        let settings = AppSettings.shared
        let full = PlaybackCoordinator.shared.currentLine?.plainText ?? ""
        guard !full.isEmpty else { return nil }
        // 窗口宽度就是用户设的那个宽度,不再由"前 N 个字"换算 —— 见
        // AppSettings.menuBarLyricsMaxWidth 上的注释。
        let windowWidth = settings.menuBarLyricsMaxWidth
        let fullWidth = MenuBarMarqueeRenderer.width(of: full)
        // 差不到半个点就别滚了(滚也看不出来,白费一个 30fps 的计时器)。
        guard windowWidth > 0, fullWidth > windowWidth + 0.5 else { return nil }
        let averageCharWidth = fullWidth / CGFloat(full.count)
        return ScrollPlan(
            text: full,
            windowWidth: windowWidth,
            maxOffset: fullWidth - windowWidth,
            // 兜一个正数下限:宽度算出 0 的话速度也会是 0,scrollOffset 那边会当成"不滚"。
            pointsPerSecond: max(1, Self.charsPerSecond * averageCharWidth)
        )
    }

    /// 当前这一句排好版的整条长图。换句/改宽度时重建,其余时候一直复用。
    private var prepared: MenuBarMarqueeRenderer.PreparedLine?

    private func recompute() {
        let settings = AppSettings.shared
        let full = PlaybackCoordinator.shared.currentLine?.plainText ?? ""
        guard let plan = currentScrollPlan() else {
            // 不用滚:维持改动之前的行为(整句,超长就截断加省略号)。
            let next = full.isEmpty
                ? ""
                : MenuBarMarqueeRenderer.truncate(full, toWidth: settings.menuBarLyricsMaxWidth)
            // 只在真的变了才发布——装得下的整句不该白白触发菜单栏重渲染。
            if next != visibleText { visibleText = next }
            if scrollImage != nil { scrollImage = nil }
            prepared = nil
            return
        }
        let offset = MenuBarMarquee.scrollOffset(
            elapsed: CACurrentMediaTime() - lineStartedAt,
            maxOffset: plan.maxOffset,
            pointsPerSecond: plan.pointsPerSecond,
            holdSeconds: Self.holdSeconds
        )
        // 首尾停留那两段里偏移一动不动,每帧重画一张一模一样的图纯属浪费,还会让菜单栏
        // 白刷新一次。半个点以下的位移在屏幕上也看不出来。
        if plan.text == lastRenderedText, abs(offset - lastRenderedOffset) < 0.12 { return }
        lastRenderedText = plan.text
        lastRenderedOffset = offset
        // 整条长图只在**换句/换宽度**时排版一次,这一帧只从它身上裁一个窗口出来。
        // 见 MenuBarMarqueeRenderer.PreparedLine —— 原来每帧都重排整段文本,那是这条
        // 30fps 路径上最贵的一步,也正是用户反馈"还是有点卡"的来源。
        if prepared?.text != plan.text || prepared?.windowWidth != plan.windowWidth {
            prepared = MenuBarMarqueeRenderer.prepare(text: plan.text, width: plan.windowWidth)
        }
        if let prepared {
            scrollImage = MenuBarMarqueeRenderer.frame(prepared, offset: offset)
        } else {
            // 长图没建起来(极端情况:宽度算成 0、内存分配失败)时退回逐帧绘制,
            // 宁可慢也不要菜单栏上突然空一块。
            scrollImage = MenuBarMarqueeRenderer.image(
                text: plan.text, width: plan.windowWidth, offset: offset)
        }
        // 滚动模式下 visibleText 保持整句:tooltip 用它,图片万一没画出来也还有东西可显示。
        if visibleText != plan.text { visibleText = plan.text }
    }
}
