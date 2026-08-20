import AppKit
import Combine
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "menubar-item")

// 状态栏兜底图标(没在放歌 / 关掉菜单栏歌词时显示的那个):音符 + 三条歌词横线,
// 跟正式 App 图标同一个构图。纯剪影(`isTemplate = true`),系统按明暗/悬停自动上色,
// 不用分别做浅色深色两份。
//
// ---- 为什么是"SF Symbol 的音符 + 自己画的三条线",而不是一张 PNG ----
//
// 2026-08-17 用户报"图标怎么变成这个鬼样子了,这么小"。量下来是两次缩小**乘在了一起**:
//   * 2026-07-20 那次(commit 579f8b3)为了让图标别比旁边的系统图标大,做了两件事 ——
//     重新生成一张四周带内边距的 PNG,**并且**把显示尺寸从 16 缩到 14;
//   * 而那张 PNG 里字形只占画布的 61% 宽 / **42% 高**(实测:36×36 的画布,字形只有
//     22×15,上下各留了 10 px 空白)。
// 两者相乘,字形的实际视觉高度只剩 14 × 0.42 ≈ 5.9pt,而菜单栏里系统图标的字形普遍在
// 13pt 上下 —— 看着就是"小了一大圈"。
//
// 光把显示尺寸调大治不了本:字形只占 42% 高,要让它到 13pt,画布得 31pt,菜单栏
// (thickness 22pt)根本放不下。而那张 PNG 的字形本身只有 22×15 像素,放大必糊 ——
// 位图这条路走到头了,只能矢量。
//
// 于是拆成两半各交给合适的人画:
//   * **音符**用 SF Symbol `music.note` —— 造型(圆头在左下、符干、右上一面旗)跟原来那张
//     一模一样,但它是矢量的,且跟系统自带图标共用同一套视觉重量,天然"合群"。
//     不用 `music.note.list`:那个是三条线在**左**、音符在右,跟这里的构图正好左右相反。
//   * **三条歌词横线**自己画 —— 三个圆角矩形而已,不存在画不准的风险,还能保住
//     "音符在左、歌词线在右"这个原有构图。
// 菜单栏那个图标(没在显示歌词时才出现)长什么样、有哪几款可选、以及选型标准,
// 全在 MenuBarIconStyle 里。

// 菜单栏那一项的总控(2026-08-16 加,取代 MenuBarExtra + MenuBarLabel + MenuBarMarqueeTicker)。
//
// 为什么不再用 MenuBarExtra:它把 label **快照成一张图**塞进状态栏按钮(探针读出来的
// 实况),视图侧没有活的图层,滚动只能靠"每帧换一张图"驱动,顺滑度受主线程调度摆布。
// 自建 NSStatusItem 之后拿到真的 NSView/CALayer,滚动交给 Core Animation ——
// 详见 MenuBarScrollingLabel 顶部那段实测记录。
//
// 这个类同时接管了原来 MenuBarMarqueeTicker 的活,但**没有计时器了**:它只在"换句 /
// 改宽度 / 开关变化 / 播放状态变化"这四件事发生时算一次该显示什么,然后交给
// 三条互斥的展示路径之一。滚动那条路装完动画就撒手。
//
// 生命周期自持:靠 Combine 订阅 AppSettings/PlaybackCoordinator,不依赖任何视图的
// onAppear —— 状态栏这一项从 App 启动到退出一直都在。
@MainActor
final class MenuBarStatusItem: NSObject {
    static let shared = MenuBarStatusItem()

    private var statusItem: NSStatusItem?
    private let scrollingLabel = MenuBarScrollingLabel()
    private let menuController = MenuBarStatusMenu()
    private var cancellables: [AnyCancellable] = []
    private var started = false
    /// 上一次用过的透明占位图(见 spacerImage)。只存一张:尺寸只在用户拖设置里那根
    /// 宽度滑杆时才变,同一时刻用得上的永远只有一个。
    /// (顺带绕开一件事:NSSize 直到 macOS 15 才 Hashable,拿它当字典键会在 14 上报警告。)
    private var spacer: (size: NSSize, image: NSImage)?
    /// 图标的"活体"渲染层(播放时所有款式都能动,见 MenuBarLiveIconView 头注)。
    /// 何时动/停由这里的展示状态决定,怎么动全在视图里 —— 全部 CA 驱动,
    /// 这个类保住了"没有计时器"的承诺。
    private let liveIconView = MenuBarLiveIconView()
    /// 左键面板(2026-08-19,「控制中心风」,见 MenuBarPanel.swift)。右键仍是完整菜单。
    private let panelController = MenuBarPanelController()

    private override init() { super.init() }

    /// AppDelegate 启动时调一次。
    func start() {
        guard !started else { return }
        started = true

        // 这里**不**预建状态栏项:末尾那次 refresh() 会让它以正确的形态+宽度出生
        // (macOS 26 只认出生宽度,见 buttonForDisplayClass 头注)。原来"先 variableLength
        // 出生、refresh 再拆掉重建"等于启动就白白多一次邻居重排。
        panelController.onVisibilityChange = { [weak self] on in
            self?.scrollingLabel.setHighlighted(on)
            self?.liveIconView.setHighlighted(on)
            self?.setPanelOpen(on)
        }

        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared
        // ⚠️ 每一条订阅都必须 .receive(on: RunLoop.main),不能直接 sink —— 这个项目已经
        // 实测踩过两次:@Published 的 publisher 在 **willSet** 时机发射,回调执行时属性
        // 本身还是**旧值**。下面这些回调都不用发射值、而是转头去读 AppSettings/
        // PlaybackCoordinator 的当前状态(refresh() 内部这么做),直接 sink 会读到旧值:
        // isPlayingNow 从 false 变 true 时 refresh() 读到的仍是 false,菜单栏永远不显示
        // 歌词。挪到下一个 runloop 循环再跑,属性此时已经落定成新值。
        coordinator.$currentLine
            .map { $0?.plainText ?? "" }
            // 同一句内部会因为逐字填色之外的原因被重新赋值,纯文本一样就不算换句 ——
            // 不去重的话滚动会被反复打回开头。
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        settings.$showLyricsInMenuBar.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 宽度改了可能从"要滚"变成"装得下"(或者反过来)。
        //
        // ⚠️ 订阅的必须是**现在真正在用的那个**设置。2026-08-15 把宽度从字数改成点时
        // 这里一度还挂在旧的 maxChars 上,后果是拖宽度滑杆完全不生效。
        //
        // debounce 而不是 receive(on:):宽度变化现在会触发状态栏项**重建**(macOS 26
        // 原地改 length 不给邻居重排,见 buttonForDisplayClass),拖滑杆时每个中间值都
        // 重建一次就是一场重排风暴。停手 250ms 后按最终值重建一次。
        // (debounce 本身也把回调推迟到了下一个 runloop 之后,willSet 旧值坑照样躲开。)
        settings.$menuBarLyricsWidth.dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 同理:切固定/自适应会改变**当前这一句**该走哪条显示路径,不能等下一次换句
        // 才生效 —— 那样用户在设置里点一下,菜单栏上看着像没反应。
        settings.$menuBarLyricsWidthMode.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 换图标样式要立刻看到 —— 用户是在设置里一个个点着挑的,等下次换歌才生效
        // 等于挑不了。
        settings.$menuBarIconStyle.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 「随播放律动」开关拨动要立刻生效 —— 用户就是盯着菜单栏拨的。
        settings.$menuBarIconAnimates.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        coordinator.$isPlayingNow.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)

        refresh()
    }

    /// 把按钮的全套装配(字体/两个内容子视图/点击路由)应用到一个状态栏项上。
    /// start() 首次建项和 rebuildStatusItem() 重建都走这里,保证两处一字不差。
    private func attachButtonChrome(to item: NSStatusItem) {
        // 位置要在系统的状态栏排序记忆里保持同一身份,重建后才不会跳位。
        item.autosaveName = "lyrimuse-status-item"
        guard let button = item.button else { return }
        // 退化路径(showStaticText)用按钮自己画文字时的字体,跟图层那条路画图用的是
        // 同一个 —— 两条路之间切换时字号不能跳。
        button.font = MenuBarMarqueeRenderer.font
        scrollingLabel.removeFromSuperview()
        scrollingLabel.frame = button.bounds
        scrollingLabel.autoresizingMask = [.width, .height]
        scrollingLabel.isHidden = true
        button.addSubview(scrollingLabel)
        liveIconView.removeFromSuperview()
        liveIconView.frame = button.bounds
        liveIconView.autoresizingMask = [.width, .height]
        button.addSubview(liveIconView)
        // 2026-08-19 起不再把菜单常挂在 item.menu 上(挂着=任何点击都弹菜单):
        // 左键弹「控制中心风」面板,右键(或 ⌃左键)才弹完整菜单 —— 弹菜单时临时挂上、
        // 弹完摘掉(见 popUpFullMenu)。
        button.target = self
        button.action = #selector(statusButtonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 当前展示形态("icon"/"text"/"fixed")。形态或槽宽一变,项就整个拆掉重建
    /// (见 present 头注),这里只是重建判定的缓存键之一。
    private var displayClass = ""

    /// 歌词固定宽度态的槽宽:窗口宽 + 系统内边距(实测健康态 160 → 178)。
    private static let fixedSlotPadding: CGFloat = 18

    /// 两次重建之间的最小静默间隔,兼作歌词间隙的收缩观察窗(见 present 头注)。
    /// 卡死的那次实测两发相隔 1.1s,取 3s 留余量。
    private static let rebuildQuietSecs: TimeInterval = 3
    private var lastRebuildAt = Date.distantPast
    private var pendingRefresh: DispatchWorkItem?

    /// 左键面板(popover)开着没有。开着期间**一律不重建**状态栏项 —— 详见 present()
    /// 里那段分支。收起时补一次 refresh(),把期间挡下来的几何变化一次性落地。
    private var panelIsOpen = false

    private func setPanelOpen(_ open: Bool) {
        panelIsOpen = open
        // notice 级:面板开合要能跟上面那些 slot rebuild 日志对到同一条时间线上 ——
        // "面板自己消失了"这类问题只有对上时间线才看得出是谁拆了锚点。
        logger.notice("panel \(open ? "opened" : "closed", privacy: .public)")
        if !open { refresh() }
    }
    /// 本轮收缩观察窗的起点。⚠️ 必须记住起点而不是每次给满窗:推迟的重跑走的还是
    /// refresh() → present(),不记起点的话每次重算都重新发满一个观察窗,收缩被无限
    /// 顺延 —— 暂停后槽永远缩不回去(实现当天差点带着这个 bug 部署)。
    /// 目标不再是收缩(歌词回来了 / 几何已一致 / 用户手动关开关)时清零。
    private var collapseObserveBegan: Date?

    /// 把"形态 cls、槽宽 length、内容 render"呈现到状态栏上。macOS 26 菜单栏的两条
    /// 实测铁律(2026-08-19,六轮排查 AX 全图 + 像素截图坐实):
    ///
    /// 1. **只在项出生那一刻**按当时的宽度给邻居排位 —— 事后换 image、原地改 length、
    ///    重踢 length,邻居一概不让位(加宽=歌词压到别家图标头上,收窄=留个空椭圆)。
    ///    所以形态或槽宽的**任何**变化都整项重建,且出生就带显式 length,绝不留直赋
    ///    捷径(第六轮用户"只是把菜单设置重改了一下就不正常"=命中当时仅剩的宽度直赋)。
    /// 2. **重建不能连发**:单次重建从未观察到排坏,但两次重建相隔 ~1s(实测 1.1s 的
    ///    歌词间隙收放、或用户连着改几项设置)会把**邻居的像素**晾在旧位置上不动 ——
    ///    此时 AX 账面已是新位置(AX 全图看着完全健康!),屏幕像素却是旧布局,歌词
    ///    画在新槽里正好压到邻居的残影头上,且这个错位**保持住不自愈**,直到下一次
    ///    从容的重排才恢复。验证这条 bug 只能靠**截图像素**,AX 会说谎。
    ///
    /// 所以这里对几何变化做节流:距上次重建不足 rebuildQuietSecs 就先换内容、把几何
    /// 变化推迟到静默窗之后(推迟期间目标又变了就合并成最新目标);歌词间隙/暂停的
    /// 收缩额外恒等一个观察窗(collapseDelay)——间隙常在 1~2s 内结束,歌词回来时
    /// 几何目标恢复原样,这对"缩了又扩"的重建就整个省掉了,期间图标居中画在还没缩
    /// 的宽槽里顶着。
    ///
    /// 重建/推迟各落一条 notice 级日志(info 不落盘,上次排查就是因此拿不到现场):
    /// 再出错位,`/usr/bin/log show --predicate 'subsystem == "me.yudaotor.lyrimuse"
    /// && category == "menubar-item"'` 能对出完整时间线。
    private func present(class cls: String, length: CGFloat, collapseDelay: TimeInterval,
                         interim: ((NSStatusBarButton) -> Void)? = nil,
                         render: (NSStatusBarButton) -> Void) {
        // 每次都从最新状态重算目标,历史挂起的目标一律作废。
        pendingRefresh?.cancel()
        pendingRefresh = nil

        let needsRebuild: Bool
        if let item = statusItem {
            needsRebuild = cls != displayClass || item.length != length
        } else {
            needsRebuild = true
        }
        guard needsRebuild else {
            collapseObserveBegan = nil
            if let button = statusItem?.button { render(button) }
            return
        }

        // ⚠️ 面板开着时把几何变化整个挡下来。状态栏这一项的按钮**就是那张 popover 的锚点
        // 视图**,而重建 = removeStatusItem + 新建一项,等于把锚连根拔掉:轻则面板当场自己
        // 消失(用户手还在上面),重则内容按新槽宽画出去、槽却还是旧宽度,歌词压到左边邻居
        // 的图标上(2026-08-19 用户报过这一幕,当时只当成"面板开着切开关"的个例,用调用侧
        // 先收面板绕过去了 —— 触发源其实不止那一个:自适应宽度模式下**每换一句**都改槽宽,
        // 歌词间隙/暂停的收缩也改,面板开着时这些都会踩到)。
        //
        // 不排期补做,交给 setPanelOpen(false) 收面板那一刻的 refresh() —— 面板还开着就
        // 重建这件事本身没有安全的时机。期间内容照旧就地换(目标是图标才换,理由同下面
        // 那条推迟分支),歌词最多晚到面板收起。
        if panelIsOpen, statusItem != nil {
            logger.notice("slot rebuild suppressed (panel open): \(self.displayClass, privacy: .public) -> \(cls, privacy: .public)(\(length, privacy: .public))")
            // 内容不等几何(2026-08-19 补,与下面推迟分支对齐):目标是图标就地画;目标是
            // 歌词就按当前(被锚住不许动的)槽宽画一版过渡 —— renderInterimLyrics 只改
            // button 内容、零重建零碰锚点,面板开着时调用同样安全。原来 text/fixed 直接
            // return,自适应宽度模式下面板开着期间状态栏歌词会冻在旧句(当时注释里"歌词
            // 最多晚到面板收起"的取舍,在 interim 机制就绪后已无必要)。
            if let button = statusItem?.button {
                if cls == "icon" { render(button) } else { interim?(button) }
            }
            return
        }

        if statusItem != nil {
            let now = Date()
            let observeRemaining: TimeInterval
            if collapseDelay > 0 {
                let began = collapseObserveBegan ?? now
                collapseObserveBegan = began
                observeRemaining = max(0, collapseDelay - now.timeIntervalSince(began))
            } else {
                collapseObserveBegan = nil
                observeRemaining = 0
            }
            let delay = max(observeRemaining, Self.rebuildQuietSecs - now.timeIntervalSince(lastRebuildAt))
            if delay > 0 {
                // debug 级(2026-08-19 降噪):推迟是自适应模式的**常态**节流路径,每换一句
                // 都走到,notice 级会让它逐句落盘。错位排查真正要对时间线的是"重建何时
                // 执行"(下面那条,3s 至多一次,保持 notice);推迟细节要看时开 debug 采集。
                logger.debug("slot rebuild deferred \(delay, privacy: .public)s: \(self.displayClass, privacy: .public) -> \(cls, privacy: .public)(\(length, privacy: .public))")
                // 推迟的只是**几何**,内容不等(2026-08-19 用户反馈"3s 延迟之后歌词
                // 有时不及时更新"——自适应模式逐句都是几何变化,内容跟着几何一起等
                // 就是逐句都可能晚 3s):目标是图标就把图标画进还没变的槽里(图标在
                // 任意槽宽下都居中,见 showIcon);目标是歌词就按**当前槽宽**先画一版
                // 过渡(interim,装得下居中静止、装不下就地滚),槽宽跟上后 refresh
                // 会按目标重画。
                if let button = statusItem?.button {
                    if cls == "icon" {
                        render(button)
                    } else {
                        interim?(button)
                    }
                }
                let work = DispatchWorkItem { [weak self] in self?.refresh() }
                pendingRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05, execute: work)
                return
            }
        }

        collapseObserveBegan = nil
        logger.notice("slot rebuild: \(self.displayClass, privacy: .public)(\(self.statusItem?.length ?? -1, privacy: .public)) -> \(cls, privacy: .public)(\(length, privacy: .public))")
        rebuildStatusItem(length: length)
        displayClass = cls
        lastRebuildAt = Date()
        if let button = statusItem?.button { render(button) }
    }

    private func rebuildStatusItem(length: CGFloat) {
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        let item = NSStatusBar.system.statusItem(withLength: length)
        statusItem = item
        attachButtonChrome(to: item)
    }

    // MARK: - 点击路由

    @objc private func statusButtonClicked() {
        guard let button = statusItem?.button else { return }
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            popUpFullMenu()
        } else {
            panelController.toggle(relativeTo: button)
        }
    }

    /// 把完整菜单按老样子弹出来:临时挂到 item.menu 上借 performClick 的原生弹出
    /// (位置/反白/键盘导航都是系统行为),弹完立刻摘掉,不然下次左键也变成菜单。
    private func popUpFullMenu() {
        guard let item = statusItem else { return }
        let menu = menuController.makeMenu(
            onHighlightChange: { [weak self] on in
                self?.scrollingLabel.setHighlighted(on)
                self?.liveIconView.setHighlighted(on)
            })
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: - 决定现在该显示什么

    private func refresh() {
        guard started else { return }
        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared
        let text = coordinator.currentLine?.plainText ?? ""
        let lyricsActive = coordinator.isPlayingNow && !text.isEmpty

        // 没开菜单栏歌词 / 没在播放 / 当前句为空:收回小图标槽。槽宽 = 当前图标款式的
        // 图宽 + 系统内边距,跟歌词态同一套"出生就带显式宽度"规则(2026-08-19 第五轮:
        // variableLength + 图片事后设 = 踩"出生后不重排",收不回去留大缺口)。
        //
        // 收缩观察窗只给"开关开着但此刻没词"(歌词间隙/暂停/广告,常在 1~2s 内结束);
        // 用户手动关开关是明确意图,立刻缩回(仍受重建静默节流保护)。
        guard settings.showLyricsInMenuBar, lyricsActive else {
            let iconWidth = MenuBarIconStyle.cachedImage(for: settings.menuBarIconStyle).size.width
            present(class: "icon", length: iconWidth + Self.fixedSlotPadding,
                    collapseDelay: settings.showLyricsInMenuBar ? Self.rebuildQuietSecs : 0) {
                showIcon($0)
            }
            return
        }
        // "装得下还是要滚"这个判定跟设置页那条预览共用同一个函数,两边不可能漂 ——
        // 见 MenuBarMarqueeRenderer.Presentation。
        switch MenuBarMarqueeRenderer.presentation(
            for: text,
            windowWidth: settings.menuBarLyricsWidth,
            // 让长句子在换到下一句之前滚完,而不是永远按固定速度爬。
            dwellSeconds: coordinator.currentLineDwellSeconds,
            widthMode: settings.menuBarLyricsWidthMode
        ) {
        case .text(let visible):
            // 自适应态:槽宽跟着这一句的文字宽走 —— 每次变宽都是一次重建
            // (macOS 26 下这是唯一能让邻居让位的做法,见 present 头注)。
            let w = MenuBarMarqueeRenderer.width(of: visible) + Self.fixedSlotPadding
            present(class: "text", length: w, collapseDelay: 0,
                    interim: { [weak self] in self?.renderInterimLyrics($0, text: text) }) {
                showStaticText($0, visible: visible, full: text)
            }
        case .fixed(let lineText, let windowWidth, let pacing):
            present(class: "fixed", length: windowWidth + Self.fixedSlotPadding, collapseDelay: 0,
                    interim: { [weak self] in self?.renderInterimLyrics($0, text: text) }) {
                showFixedWidth($0, text: lineText, windowWidth: windowWidth, pacing: pacing)
            }
        }
    }

    /// 几何变化被推迟期间的过渡渲染:把**最新**这句歌词按当前(还没变的)槽宽画出来,
    /// 让内容永远实时、只有槽宽在等静默窗。装得下→居中静止;装不下→在当前槽里滚。
    /// 只在当前已是歌词槽(text/fixed)时有意义 —— 当前是图标槽(38pt)时不硬塞:
    /// 20pt 的窗里滚歌词只会闪成一条缝,保持图标到重建(首句最多晚一个静默窗,只发生
    /// 在"收缩后 3s 内歌词又回来"的边缘场景)。
    private func renderInterimLyrics(_ button: NSStatusBarButton, text: String) {
        guard displayClass == "text" || displayClass == "fixed", let item = statusItem else { return }
        let usable = item.length - Self.fixedSlotPadding
        guard usable > 0 else { return }
        // widthMode 固定传 .fixed:过渡期间槽宽就是钉死的(它正是"还没让改"的那个宽),
        // 按固定宽语义排版;等重建后 refresh 会按用户真实的模式/宽度重画。
        switch MenuBarMarqueeRenderer.presentation(
            for: text, windowWidth: usable,
            dwellSeconds: PlaybackCoordinator.shared.currentLineDwellSeconds,
            widthMode: .fixed
        ) {
        case .text(let visible):
            showStaticText(button, visible: visible, full: text)
        case .fixed(let lineText, let win, let pacing):
            showFixedWidth(button, text: lineText, windowWidth: win, pacing: pacing)
        }
    }

    /// 没开菜单栏歌词 / 没在播放 / 还没解析出这一句:图标(槽位由 showIconSlot 管,
    /// 这里只管内容)。静态图靠按钮自己居中,活体渲染靠 MenuBarLiveIconView.layout()
    /// 按 bounds 居中,两条路都天然适应槽宽。
    /// 「随播放律动」开着且正在播放时走活体渲染:按钮里只放一张撑尺寸的透明占位图
    /// (footprint 跟静态款逐像素一致),真身画在 liveIconView 的图层上,动画全部
    /// 交给 Core Animation(见 MenuBarLiveIconView 头注)。其余情况就是一张静态模板图。
    private func showIcon(_ button: NSStatusBarButton) {
        scrollingLabel.clear()
        let settings = AppSettings.shared
        let style = settings.menuBarIconStyle
        let staticImage = MenuBarIconStyle.cachedImage(for: style)
        if settings.menuBarIconAnimates, PlaybackCoordinator.shared.isPlayingNow {
            button.image = spacerImage(width: staticImage.size.width,
                                       height: staticImage.size.height)
            liveIconView.frame = button.bounds
            liveIconView.present(style: style)
        } else {
            liveIconView.clear()
            button.image = staticImage
        }
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = nil
        button.setAccessibilityLabel(L10n.t("Lyrimuse"))
    }

    /// 退化路径:宽度被设成 0 或更小,画不出格子,交给按钮自己画一段截断文字。
    /// 正常情况走不到这里(滑杆下限 80pt),留着是不想让极端配置变成一块空白。
    private func showStaticText(_ button: NSStatusBarButton, visible: String, full: String) {
        scrollingLabel.clear()
        liveIconView.clear()
        button.image = nil
        // imagePosition 是按钮上的**持久**属性,滚动那条路会把它设成 .imageOnly(那边靠
        // 一张透明占位图撑宽度、文字画在图层上),这里显式改回来,让"这一模式只有文字"
        // 这件事写在代码里,而不是靠别处的残留值。
        //
        // ⚠️ 老实说一句:实测(2026-08-16 离线位图探针,逐像素数非透明占比)**不改也能画出
        // 文字** —— image 为 nil 时 AppKit 会无视 .imageOnly 照样画 title,两种写法的
        // 渲染结果和按钮宽度完全一样。所以这一行不是在修一个看得见的 bug,是不想把
        // "两个模式之间靠遗留状态碰巧对上"这件事留在代码里。
        button.imagePosition = .noImage
        button.title = visible
        // tooltip 始终给完整这一行:"想看全文就悬停"这条出路在三种模式下都在。
        button.toolTip = full
        button.setAccessibilityLabel(full)
    }

    /// 正常路径:这一格恒占 windowWidth,文字画在图层上。装得下就静止(pacing == nil),
    /// 装不下就交给 Core Animation 滚。
    ///
    /// ⚠️ 装得下的句子**也**走这里,不走 button.title —— 这正是"固定宽度"的实现点。
    /// button.title 那条路的宽度跟着文字走(实测同一首歌连着三句是 231/145/207pt),
    /// 长短句来回切时菜单栏项就会伸缩、把右边的图标顶得左右晃(2026-08-17 用户反馈)。
    private func showFixedWidth(_ button: NSStatusBarButton, text: String, windowWidth: CGFloat,
                                pacing: MenuBarMarquee.ScrollPacing?) {
        liveIconView.clear()
        // ⚠️ 这张**全透明**的占位图是整个固定宽度方案的支点,不是残留:variableLength 的
        // 状态栏项按 button.image 的尺寸算自己该占多宽。给它一张宽度恒为 windowWidth 的
        // 空图,这一项的 footprint 就跟内容彻底脱钩了,而且不用去猜系统给状态栏按钮留了
        // 多少内边距(那是算不出来的,只能让 AppKit 自己算)。
        // 图本身没有任何像素,画上去什么都看不见,真正的文字在 scrollingLabel 那一层。
        button.image = spacerImage(
            width: windowWidth, height: MenuBarMarqueeRenderer.lineHeight)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = text
        // 图层上的文字读屏软件读不到,这里显式补上这一行歌词。
        button.setAccessibilityLabel(text)

        scrollingLabel.frame = button.bounds
        scrollingLabel.present(text: text, windowWidth: windowWidth, pacing: pacing)
    }

    private func spacerImage(width: CGFloat, height: CGFloat) -> NSImage {
        let size = NSSize(width: ceil(width), height: ceil(height))
        if let spacer, spacer.size == size { return spacer.image }
        // drawingHandler 里什么都不画,只 return true —— 得到的是一张有正确尺寸、
        // 但完全透明的图。
        let image = NSImage(size: size, flipped: false) { _ in true }
        image.isTemplate = true
        spacer = (size, image)
        return image
    }
}
