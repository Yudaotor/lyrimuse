import Combine
import Foundation
import LyrimuseCore

// 菜单栏歌词跑马灯的驱动器(2026-08-05 加)——把"现在该露出这一句的哪一段"算好、发布成
// 一个普通字符串,MenuBarLabel 直接渲染它。
//
// 为什么需要这么一个独立的驱动器,而不是在 MenuBarLabel 里用动画/TimelineView:
// MenuBarExtra 默认(.menu)样式的 label 挂不住 SwiftUI 的动画/生命周期修饰符(本会话
// 早先实测坐实 `.task` 从来不触发),但 label 会跟着它读的 @Published 值重新渲染。所以
// 节奏必须由模型侧提供 —— 详见 MenuBarMarquee 顶部注释。
//
// 生命周期完全自持:靠 Combine 订阅 AppSettings/PlaybackCoordinator 自己决定何时开停
// 计时器,不依赖任何视图的 onAppear/onDisappear(菜单栏 label 的生命周期本身就不可靠,
// 这是上面那条限制的同一个根源)。
@MainActor
final class MenuBarMarqueeTicker: ObservableObject {
    static let shared = MenuBarMarqueeTicker()

    // MenuBarLabel 唯一需要读的东西:当前这一拍该显示的文字。整句装得下时就是整句本身、
    // 恒定不变(不会产生多余刷新)。
    @Published private(set) var visibleText: String = ""

    // 每拍间隔 0.25 秒 = 每秒滚过 4 个字。再快中文就跟不上了(一个汉字信息量远大于一个
    // 拉丁字母),再慢又显得拖沓。
    private static let tickInterval: TimeInterval = 0.25
    // 首尾各停 6 拍(1.5 秒)——开头这一停很重要,一句歌词最关键的往往是开头,一上来就
    // 滚会看不清。
    private static let holdSteps = 6

    private var timer: Timer?
    private var step = 0
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
        // 启动不起来,表现就是"取窗算对了但 step 恒为 0、完全不滚"。改到下一个 runloop
        // 循环再跑,属性此时已经落定成新值。
        coordinator.$currentLine
            .map { $0?.plainText ?? "" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.step = 0
                self?.recompute()
            }
            .store(in: &cancellables)
        // 这几个设置任何一个变了都要立刻重算/重新决定要不要跑计时器。
        settings.$showLyricsInMenuBar.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncTimer() }.store(in: &cancellables)
        settings.$menuBarLyricsScroll.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.step = 0; self?.syncTimer() }.store(in: &cancellables)
        settings.$menuBarLyricsMaxChars.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }.store(in: &cancellables)
        coordinator.$isPlayingNow.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncTimer() }.store(in: &cancellables)
        syncTimer()
    }

    // 只在真的需要滚的时候才让计时器跑:菜单栏歌词关着、没在播放、或者用户把滚动关了,
    // 都没必要每 0.25 秒唤醒一次。
    private func syncTimer() {
        let settings = AppSettings.shared
        let needed = settings.showLyricsInMenuBar
            && settings.menuBarLyricsScroll
            && PlaybackCoordinator.shared.isPlayingNow
        if needed {
            if timer == nil {
                // 必须挂 .common mode,否则菜单打开/拖拽悬浮窗时会停摆——跟
                // LocalPlaybackSource 的两个计时器同一个理由。
                let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.step += 1
                        self.recompute()
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            timer?.invalidate()
            timer = nil
            step = 0
        }
        recompute()
    }

    private func recompute() {
        let settings = AppSettings.shared
        let full = PlaybackCoordinator.shared.currentLine?.plainText ?? ""
        let next: String
        if full.isEmpty {
            next = ""
        } else if settings.menuBarLyricsScroll {
            next = MenuBarMarquee.window(
                text: full,
                maxChars: settings.menuBarLyricsMaxChars,
                step: step,
                holdSteps: Self.holdSteps
            )
        } else {
            // 关掉滚动 → 维持改动之前的行为(超长就截断加省略号)。
            next = full.count > settings.menuBarLyricsMaxChars
                ? String(full.prefix(settings.menuBarLyricsMaxChars)) + "…"
                : full
        }
        // 只在真的变了才发布——装得下的整句/停留阶段的那几拍都不该白白触发菜单栏重渲染。
        if next != visibleText { visibleText = next }
    }
}
