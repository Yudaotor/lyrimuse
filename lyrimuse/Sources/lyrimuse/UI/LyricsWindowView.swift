import AppKit
import SwiftUI
import LyrimuseCore

// 这个绿色按钮目前只会"放大铺满屏幕",点不出真正的原生全屏(独立 Space、隐藏菜单栏/
// Dock)——2026-08-01 实测排查过一整轮,不是这个窗口自己代码的问题:"歌词管理"这个
// 完全没碰过的既有窗口,按钮同样是 AXZoomButton 而不是 AXFullScreenButton(拿 TextEdit
// 一个正常支持全屏的窗口对比过,那边点了真的会全屏,AXFullScreen 从 false 变 true;
// 这两个窗口点了 AXFullScreen 恒为 false),说明这是"MenuBarExtra 作为主 Scene 的这整个
// App"里所有 Window(id:) 场景共有的表现,不是这一个视图的局部问题。已经验证过并排除的
// 方向:①window.collectionBehavior 加 .fullScreenPrimary(用 rawValue 位掩码确认过真的
// 生效,菜单栏"显示"菜单里也确实多出"进入全屏幕"这一项);②NSApp.activationPolicy
// 切到 .regular(用户自己"在 Dock 中显示"这项本来就是开着的,全程确认过 activationPolicy
// 就是 .regular,不存在切换时机问题);③Info.plist 的 LSUIElement 改成 false(临时改过
// build.sh 重新构建验证,同样无效,已改回)。三个假设逐一用真机验证证伪,不是没试就
// 放弃。真正卡住的那一步是"进入全屏幕"这个菜单命令点了也确实不生效(不只是按钮图标不
// 对),指向比这几个属性更深的层面,没有再继续往下猜——参见对话记录里跟用户的讨论。
//
// 用户选择的替代方案:不追求真正的原生全屏,做一个"伪全屏"——工具栏按钮触发,手动把
// 窗口 setFrame 撑满整个屏幕(不是 visibleFrame,是含菜单栏/Dock 那块区域在内的完整
// 屏幕范围,配合下面的 presentationOptions 一起用)、隐藏标题栏和三个红黄绿按钮、拿
// NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock] 这个官方 API 让菜单栏/
// Dock 跟真全屏一样悬停才弹出——不是真的切换 Space,但视觉效果接近,而且完全不依赖
// 上面那个已经证实卡死的原生全屏机制,退出路径(按钮再点一次/Esc)完全在自己掌控中,
// 稳定可靠。
//
// LyricsWindowController 管这一整套跟真实 NSWindow 打交道的状态(伪全屏 + 置于最
// 顶层),是个 ObservableObject 而不是纯 NSView 内部状态——工具栏按钮需要跟着
// isActive/isAlwaysOnTop 换图标/文案,SwiftUI 侧需要能观察到。用
// LyricsWindowCapture(下面的 NSViewRepresentable)拿到真实 NSWindow 交给它,
// 复用跟 LyricsOverlayWindowController.shared 类似的"独立于 View 生命周期的状态持有者"
// 思路,但这里不是单例——每个 LyricsWindowView 实例自己持有一个,反正这个窗口场景本身
// 是 App 内单例 Window(id:),不会有多份内容同时需要各自独立状态。
@MainActor
private final class LyricsWindowController: ObservableObject {
    @Published private(set) var isActive = false
    // 置于最顶层——跟伪全屏是两回事,不互斥(可以同时开)。用 NSWindow.level 而不是
    // collectionBehavior:.floating 是标准的"漂浮在普通窗口之上"层级,系统里很多类似
    // 功能(画中画、计算器"始终置顶"一类第三方 App)都是这么做的。不持久化——每次
    // 重新打开这个窗口都从"不置顶"开始,跟伪全屏状态同一个"只在这次打开期间有效"的
    // 处理原则,没有额外加一个 UserDefaults 存档的必要性。
    @Published private(set) var isAlwaysOnTop = false

    private weak var window: NSWindow?
    private var savedFrame: NSRect?
    private var escapeMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?

    // 只在窗口第一次挂上来时调一次,拿到真实 NSWindow 存住弱引用,同时挂两个兜底:
    // ① 窗口关闭就强制退出伪全屏——不然用户在伪全屏状态下直接关闭这个窗口,
    // presentationOptions 全局状态(菜单栏/Dock 隐藏)会一直挂着不清,污染到 App 里其它
    // 窗口甚至其它 App 的观感,必须在窗口消失前无条件复原。
    // ② 窗口失去 key 状态(不关闭,只是用户切到 App 内其它窗口,比如设置页/歌词管理)
    // 也退出伪全屏——2026-08-02 实测排查过一轮:presentationOptions 是 NSApplication
    // 级别的进程级全局状态,不跟哪一扇具体窗口绑定,只在①这个窗口关闭时才清理是不够的:
    // 用户在这个窗口开着伪全屏、切去操作另一扇窗口时,菜单栏/Dock 会跟着继续隐藏,
    // 那扇窗口反而变得不好用(找不到菜单栏)。真全屏(其它 App 常见的那种)在这种场景下
    // 是"焦点窗口所在的那个 Space 单独隐藏菜单栏",别的窗口不受影响;这里没有真的 Space
    // 隔离,只能退而求其次——失去焦点就整个退出伪全屏,不去做"记住哪些窗口該保持全屏"
    // 这类更复杂的模拟。置顶状态不需要类似兜底——window.level 是这个 NSWindow 实例自己
    // 的属性,窗口一关就随实例一起没了,也不受切换焦点影响,不会像 presentationOptions
    // 那样是进程级的全局状态、需要显式清理。
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forceExit() }
        }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forceExit() }
        }
    }

    func toggleAlwaysOnTop() {
        guard let window else { return }
        isAlwaysOnTop.toggle()
        window.level = isAlwaysOnTop ? .floating : .normal
    }

    func toggle(reduceMotion: Bool) {
        if isActive {
            exit(animate: !reduceMotion)
        } else {
            enter(animate: !reduceMotion)
        }
    }

    private func enter(animate: Bool) {
        guard let window, let screen = window.screen ?? NSScreen.main, !isActive else { return }
        savedFrame = window.frame
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.styleMask.insert(.fullSizeContentView)
        // .autoHideMenuBar 单独用没有效果——文档要求两个一起设,菜单栏才会真的让出空间、
        // 悬停到顶部才重新弹出(实测坐实,不是随手加的)。
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        window.setFrame(screen.frame, display: true, animate: animate)
        isActive = true
        // Esc 退出——伪全屏状态下用户的第一直觉,跟真全屏的既有习惯一致。用局部事件
        // 监听(跟 ShortcutRecorderButton 同款手法),不是全局热键。
        //
        // ⚠️ NSEvent.addLocalMonitorForEvents 是"发给本 App 任意窗口"级别的钩子,不是
        // 按窗口过滤的——2026-08-02 实测排查坐实:早先这里的注释错误地写着"只在这个
        // 窗口是第一响应者时才拦截",但回调体内其实完全没有做这个判断,导致用户在这个
        // 窗口伪全屏时,切去 App 内另一扇窗口(比如设置页的"存为新配色主题"弹窗)按 Esc
        // 想做别的操作(取消弹窗),会被这里无条件 return nil 吞掉——目标窗口收不到这次
        // Esc,后台这扇窗口反而莫名退出了全屏。现在显式判断 self?.window?.isKeyWindow,
        // 不是当前 key window 就放行事件(return event),不拦截、也不触发 exit。跟上面
        // attach() 里新增的 didResignKeyNotification 兜底是两道独立防线:那道处理"切走
        // 焦点后主动退出全屏"这个状态清理,这里处理"这次具体的 Esc 按键该不该被这个
        // 监听器吞掉",避免依赖两个异步通知的到达顺序。
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53, self?.window?.isKeyWindow == true else { return event } // 53 = kVK_Escape
            self?.exit(animate: true)
            return nil
        }
    }

    private func exit(animate: Bool) {
        guard let window, isActive else { return }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        NSApp.presentationOptions = []
        if let savedFrame {
            window.setFrame(savedFrame, display: true, animate: animate)
        }
        window.styleMask.remove(.fullSizeContentView)
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        savedFrame = nil
        isActive = false
    }

    // 窗口关闭/失去焦点时的无条件复原——跟上面 exit(animate:) 的区别是不需要动画(前者
    // 窗口马上就没了,后者用户已经在看别的窗口,过渡动画没有意义,反而显得拖沓)。
    private func forceExit() {
        guard isActive else { return }
        exit(animate: false)
    }

    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    }
}

private struct LyricsWindowCapture: NSViewRepresentable {
    let controller: LyricsWindowController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                controller.attach(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            controller.attach(window)
        }
    }
}
//
// "歌词窗口"(2026-07-31 新增):正经的标题栏窗口,展示当前歌曲完整歌词并跟随播放
// 自动滚动高亮当前行——跟悬浮歌词(LyricsOverlayView)/灵动岛歌词(NotchLyricsView)
// 那种"只看当前一句"的无边框浮层是完全不同的形态,不复用它们的 AppSettings 主题
// (foregroundColor/textStrokeEnabled/fontFamilyName/fontSize/overlayWidth 这些是为了
// 在任意桌面背景上保持可读性专门调的),默认用系统原生颜色(.primary/.secondary,自动
// 跟随浅色/深色模式),风格更接近"歌词管理"窗口而不是悬浮窗。
//
// 例外:拿到当前曲目的封面图时(见 PlaybackCoordinator.artworkData),背景会铺一层
// 模糊+压暗的封面(Apple Music 歌词页最标志性的元素),这时候文字底下不再是纯系统
// 窗口背景,如果继续吃 .primary/.secondary,浅色系统外观下会变成"深色文字配深色模糊
// 照片"、基本看不清——所以只要有封面数据,主/罗马音/译文这三行文字统一切到固定的浅色
// (不跟随系统深浅色),拿不到封面(还没换过一次歌、这次 Now Playing 会话本来没有封面
// 数据)时维持原来的纯系统色,不会出现"有时候看得清有时候看不清"的中间态。
//
// 自动滚动 + 手动回归的交互思路直接照抄 LyricsManagerView.focusCurrentlyPlaying 的
// 按钮点子:工具栏放一个"回到当前播放",不试图自动侦测"用户是不是正在手动往回翻歌词"
// ——那需要 SwiftUI 较新的 scrollPosition(id:) 读写观察机制,这个项目目前完全没有
// 用过,没能真机验证它跟这里用的 ScrollViewReader.scrollTo 混用是否稳定;这次先用
// LyricsManagerView 已经验证过的简单方案:自动跟随永远生效,用户想往回看就手动滚,
// 看完点"回到当前播放"跳回去。如果实际用起来觉得"被拽回去"太打扰,再考虑加那套更
// 复杂的侦测逻辑。
struct LyricsWindowView: View {
    @ObservedObject private var poller = PlaybackCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var windowController = LyricsWindowController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 正在拖进度条时手指所在的比例(0~1);没在拖就是 nil。拖动期间进度条和时间文字都显示
    // 这个值而不是真实播放位置,松手才发 seek —— 见 progressBar 里的注释。
    // 用 @GestureState:手势被取消时会自动复位,不会像 @State 那样永久卡住(理由同上)。
    @GestureState private var scrubbingFraction: Double?
    // 进度条那一块的实际宽度,拖拽时换算比例用(见 progressBar 里为什么不用 GeometryReader 包)。
    @State private var scrubWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { scrollProxy in
            GeometryReader { geo in
                // 2026-08-04 按 Apple Music 歌词页一比一重做:左列是封面卡片+曲目信息+
                // 进度条+播放控制,右列是左对齐的大字歌词。左列只在窗口够宽时显示——
                // 老版本竖长窗口的存档尺寸(~460pt)下硬塞两列会挤成一团,退化成只有
                // 歌词的单列,跟 Apple Music 自己把窗口拖窄时的行为一致。
                let showPlayerPane = geo.size.width >= 640
                HStack(spacing: 0) {
                    if showPlayerPane {
                        playerPane
                            .frame(width: min(geo.size.width * 0.42, 460))
                            .frame(maxHeight: .infinity)
                    }
                    rightPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(artworkBackground)
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        windowController.toggleAlwaysOnTop()
                    } label: {
                        Label(
                            windowController.isAlwaysOnTop ? L10n.t("取消置顶") : L10n.t("置于最顶层"),
                            systemImage: windowController.isAlwaysOnTop ? "pin.fill" : "pin"
                        )
                    }
                    // 2026-08-02 补上——置顶/伪全屏这两个状态是"只在这次打开期间有效",
                    // 不持久化(见 LyricsWindowController 顶部注释),但按钮本身没有任何
                    // 提示说明,习惯把它固定置顶的用户每次重开窗口都要重新点一次,容易
                    // 被当成 bug。这里用 .help() 补一句悬停提示,不需要额外的 UI 元素。
                    .help(L10n.t("这个状态只在本次打开这扇窗口期间有效，下次重新打开会恢复默认"))
                }
                ToolbarItem {
                    Button {
                        windowController.toggle(reduceMotion: reduceMotion)
                    } label: {
                        Label(
                            windowController.isActive ? L10n.t("退出全屏") : L10n.t("进入全屏"),
                            systemImage: windowController.isActive
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                    .help(L10n.t("这个状态只在本次打开这扇窗口期间有效，下次重新打开会恢复默认"))
                }
                ToolbarItem {
                    Button {
                        scrollToActiveLine(scrollProxy: scrollProxy, animated: true)
                    } label: {
                        Label(L10n.t("回到当前播放"), systemImage: "location.fill")
                    }
                }
            }
            .onChange(of: poller.currentLineIndex) {
                scrollToActiveLine(scrollProxy: scrollProxy, animated: true)
            }
            .onChange(of: poller.allLines) {
                // 换歌/歌词内容重新加载:新旧两份数组的 id 前缀完全不同(见
                // LyricsWindowLine 类型注释),等新内容渲染出来后跳到新歌当前行——
                // 还没到第一句时 activeID 是 nil,scrollToActiveLine 直接不做任何事,
                // 列表自然停在顶部。
                DispatchQueue.main.async {
                    scrollToActiveLine(scrollProxy: scrollProxy, animated: false)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    scrollToActiveLine(scrollProxy: scrollProxy, animated: false)
                }
            }
        }
        // 2026-08-04 从竖长阅读面板改成 Apple Music 歌词页同款的横向双列比例。窗口尺寸
        // 由系统状态恢复机制记忆,老用户第一次打开还是旧的竖长尺寸(此时按上面的宽度
        // 判断退化成单列),手动拖宽一次之后就会记住新比例。
        .frame(minWidth: 520, idealWidth: 1020, minHeight: 480, idealHeight: 660)
        .background(LyricsWindowCapture(controller: windowController).frame(width: 0, height: 0))
        // 见 AuxiliaryWindowActivation 注释——.accessory 策略下临时借一个 Dock 图标,
        // 方便 Cmd-Tab 切回这扇正经标题栏窗口(这个窗口本来就设计成"跟随播放持续显示",
        // 用户中途切去别的 App 很常见)。
        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }
        .onDisappear { AuxiliaryWindowActivation.windowDidDisappear() }
        // "喜欢"状态不跟着 2 秒轮询走(每读一次要起一个 osascript 子进程,为一个几乎不变
        // 的布尔值那么干不值当),换歌时由 PlaybackCoordinator 刷一次。悬浮窗还借"控制排
        // 露出来"这个动作补刷,而这扇窗口是常显的、没有那个动作,所以换成:打开时刷一次,
        // 以及每次 App 重新变成前台时刷一次 —— 后者正好覆盖"用户刚切去 Music.app 点了
        // 心、再切回来"这条路径。
        .onAppear { poller.refreshFavorited() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            poller.refreshFavorited()
        }
    }

    private var activeID: String? {
        guard let idx = poller.currentLineIndex, poller.allLines.indices.contains(idx) else { return nil }
        return poller.allLines[idx].id
    }

    // Apple Music 歌词页把当前行定位在窗口偏上约 1/3 处(不是正中)——上面留少量已经
    // 唱过的行,下面留更多即将到来的行,2026-08-04 从 .center 改过来。
    private static let activeLineAnchor = UnitPoint(x: 0.5, y: 0.35)

    private func scrollToActiveLine(scrollProxy: ScrollViewProxy, animated: Bool) {
        guard let id = activeID else { return }
        if animated {
            withAnimation { scrollProxy.scrollTo(id, anchor: Self.activeLineAnchor) }
        } else {
            scrollProxy.scrollTo(id, anchor: Self.activeLineAnchor)
        }
    }

    // ---- 右列:歌词滚动列表 / 占位态 --------------------------------------------

    @ViewBuilder
    private var rightPane: some View {
        if poller.allLines.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    ForEach(Array(poller.allLines.enumerated()), id: \.element.id) { index, item in
                        lineView(item, distance: distance(for: index), isActive: item.id == activeID)
                            .id(item.id)
                    }
                }
                .padding(.vertical, 88)
                .padding(.leading, 44)
                .padding(.trailing, 52)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // ---- 左列:封面 + 曲目信息 + 进度条 + 播放控制 --------------------------------

    private var playerPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 20)
            artworkCard
            trackInfoRow
                .padding(.top, 22)
            progressSection
                .padding(.top, 14)
            playbackControls
                .padding(.top, 20)
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 48)
    }

    private var artworkCard: some View {
        // Color.clear 先撑出 1:1 的方形框、图片以 scaledToFill 铺进去再裁圆角——不能
        // 直接对 Image 用 scaledToFill(没有外框约束时它会按原始比例撑开布局)。
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let nsImage = poller.artworkImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(hasArtworkBackground ? Color.white.opacity(0.1) : Color.primary.opacity(0.06))
                        Image(systemName: "music.note")
                            .font(.system(size: 44))
                            .foregroundStyle(secondaryTextColor)
                    }
                }
            }
            // 动画收在 overlay 内容上,而不是挂在整张卡片的最外层。
            //
            // 挂在最外层时,这个 0.5s 的动画作用域会覆盖卡片自身的几何——只要有别的状态在
            // 同一个更新事务里改变了布局(2026-08-05 实测坐实的那次:anchor 到达让进度条那
            // 一行插进 VStack,整个左栏跟着重排),这次布局位移就会被它一起 animate 成缓慢
            // 飘移,表现成"进度条从上面飘下来"。它要动画的本来只是"换歌时封面图交叉淡入"
            // 这一件事,不该有能力动画到版式。
            .animation(.easeInOut(duration: 0.5), value: poller.artworkData)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(hasArtworkBackground ? 0.45 : 0.2), radius: 26, y: 12)
    }

    private var trackInfoRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(poller.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
            Text(artistAlbumText)
                .font(.system(size: 17))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
        }
    }

    // Apple Music 同款"歌手 — 专辑"一行(em dash),专辑缺失时只显示歌手。
    private var artistAlbumText: String {
        poller.album.isEmpty ? poller.artist : "\(poller.artist) — \(poller.album)"
    }

    @ViewBuilder
    private var progressSection: some View {
        if let anchor = poller.anchor {
            // 播放中:1 秒一档从锚点外推——4pt 高的进度条上,秒级步进配 .linear 补间在
            // 视觉上已经连续,不值得为它再挂一个逐帧刷新的 TimelineView(.animation)。
            TimelineView(.periodic(from: .now, by: 1)) { context in
                progressBar(positionMs: anchor.extrapolatedPositionMs(now: context.date), durationMs: anchor.durationMs)
            }
        } else if let paused = poller.pausedPositionMs, let duration = poller.currentDurationMs, duration > 0 {
            // 暂停:显示冻结位置(anchor 此时是 nil,见 pausedPositionMs 定义处注释)。
            progressBar(positionMs: paused, durationMs: duration)
        } else {
            // 什么位置数据都还没有(刚打开窗口、poller 还没读到第一份快照)时**占住同样的
            // 空间**,而不是整块不渲染。
            //
            // 2026-08-05 用户反馈"首次进入时进度条会从上面飘下来到对应位置"的根因就在这里:
            // 原来这个分支什么都不渲染,等 anchor 到达才把这一行插进 playerPane 的 VStack,
            // 于是整个左栏的 Spacer 重新分配、上下内容各自位移十几 pt;而这块布局变化恰好
            // 落在 artworkCard 那条 0.5s easeInOut 动画的同一个更新事务里,被它一起animate
            // 成了"缓慢飘移"。占住位之后布局从第一帧起就是终态,插入这件事本身不再发生。
            //
            // .hidden() 保留布局、不参与命中测试;durationMs 传 0,progressBar 里的手势有
            // `durationMs > 0` 守卫,不会误发 seek。
            progressBar(positionMs: 0, durationMs: 0).hidden()
        }
    }

    private func progressBar(positionMs: Int, durationMs: Int) -> some View {
        // 拖动期间显示手指按住的位置,而不是真实播放位置——松手才真的发 seek。拖动中
        // 播放器还在按旧位置走,若这里显示真实位置,进度条会在手指底下往回跳。
        let shownMs = scrubbingFraction.map { Int($0 * Double(durationMs)) } ?? positionMs
        let fraction = durationMs > 0 ? min(1, max(0, Double(shownMs) / Double(durationMs))) : 0
        return VStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(primaryTextColor.opacity(0.25))
                    Capsule().fill(primaryTextColor.opacity(0.85))
                        .frame(width: max(4, g.size.width * fraction))
                }
                // 拖动期间不要补间动画:那 1 秒的 .linear 会让进度条追着手指慢慢挪,手感发黏。
                .animation(reduceMotion || scrubbingFraction != nil ? nil : .linear(duration: 1), value: fraction)
            }
            .frame(height: 4)
            // 命中区**只覆盖进度条这一行**,不含下面的时间行。原来把手势挂在整个 VStack 上,
            // 于是点右侧那个"剩余时间"文字就等于 seek 到 ~95%(把这首歌跳过去)、点左侧已播
            // 时间则从头重播——那两个看起来是纯静态标签的文字,点一下就毁掉当前播放。
            //
            // 上下各撑 9pt 让 4pt 的条好按,再用**等量负 padding** 把布局高度抵消回去:
            // 这块 AM 风格的间距是逐像素对着截图调过的,不能因为要加命中区就长高 18pt。
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .padding(.vertical, -9)
            // 量宽度的 background 和手势必须挂在**同一个**视图上,location.x 与 scrubWidth
            // 才在同一个坐标系里。不把它包进 GeometryReader:那个是贪心的,会撑满可用空间。
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { scrubWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in scrubWidth = w }
                }
            )
            .gesture(
                // minimumDistance: 0 让"点一下就跳"也能用,不用真的拖开一段距离。
                //
                // 用 @GestureState 而不是 @State 存拖动位置:SwiftUI 在手势被**取消**时
                // (拖动过程中宿主子树被移出层级,比如这首歌播完/被暂停,进度条所在的条件
                // 分支整块被摘掉)不会调 onEnded,用 @State 的话 scrubbingFraction 会永久
                // 停在最后一次 onChanged 的值,进度条和两个时间文字从此冻结、补间动画也被
                // 永久关掉,只有再完整拖一次才自愈。@GestureState 在手势结束或取消时自动
                // 复位成初始值,天然没有这个问题。
                DragGesture(minimumDistance: 0)
                    .updating($scrubbingFraction) { value, state, _ in
                        guard durationMs > 0, scrubWidth > 0 else { return }
                        state = min(1, max(0, value.location.x / scrubWidth))
                    }
                    .onEnded { value in
                        guard durationMs > 0, scrubWidth > 0 else { return }
                        let f = min(1, max(0, value.location.x / scrubWidth))
                        poller.seek(toMs: Int(f * Double(durationMs)))
                    }
            )
            HStack {
                Text(Self.formatTime(ms: shownMs))
                Spacer()
                Text("-" + Self.formatTime(ms: max(0, durationMs - shownMs)))
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(secondaryTextColor)
        }
    }

    private static func formatTime(ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        return "\(totalSeconds / 60):" + String(format: "%02d", totalSeconds % 60)
    }

    private var playbackControls: some View {
        HStack(spacing: 44) {
            // 左边这个是**占位**,不是第二颗心:跟右边那颗等宽,让播放/暂停键无论有没有心
            // 都停在正中。没有它的话,心一出现整排就整体左移半个按钮宽 —— 而 isFavorited
            // 是异步读出来的(refreshFavorited 里起 osascript 子进程),那次位移正好落在
            // 窗口刚打开的一瞬间,很扎眼;切到非 Apple Music 的播放器时也会再抖一次。
            favoriteButton.hidden()
            Button {
                MusicPlaybackController.previousTrack()
            } label: {
                Image(systemName: "backward.fill").font(.system(size: 22))
            }
            .help(L10n.t("上一首"))
            Button {
                MusicPlaybackController.playPause()
            } label: {
                Image(systemName: poller.isPlayingNow ? "pause.fill" : "play.fill")
                    .font(.system(size: 30))
                    .frame(width: 34) // 播放/暂停两个图标宽度不同,固定住避免两侧按钮跟着跳动
            }
            .help(L10n.t("播放/暂停"))
            Button {
                MusicPlaybackController.nextTrack()
            } label: {
                Image(systemName: "forward.fill").font(.system(size: 22))
            }
            .help(L10n.t("下一首"))
            favoriteButton
        }
        .buttonStyle(.plain)
        .foregroundStyle(primaryTextColor)
        .frame(maxWidth: .infinity)
    }

    /// 「喜欢」——对应 Apple Music 里那颗心(脚本字典里的 favorited)。
    ///
    /// 跟悬浮窗那颗是同一份状态、同一个开关(PlaybackCoordinator.isFavorited /
    /// toggleFavorited),两处点哪个都一样,权限检查和乐观更新都在 coordinator 里做。
    ///
    /// 只有 Apple Music 有"喜欢"这个概念,所以 isFavorited 为 nil(在播的是别的播放器、
    /// 或者自动化权限还没拿到)时这里是空的,而不是显示一颗永远点不亮的心 —— 跟悬浮窗
    /// 同一个判断。宽度固定住,理由见 playbackControls 里那个占位。
    private var favoriteButton: some View {
        Group {
            if let favorited = poller.isFavorited {
                Button {
                    poller.toggleFavorited()
                } label: {
                    Image(systemName: favorited ? "heart.fill" : "heart")
                        .font(.system(size: 20))
                }
                .foregroundStyle(favorited ? Color.red : primaryTextColor)
                .help(L10n.t(favorited ? "取消喜欢" : "喜欢"))
            }
        }
        .frame(width: 22)
    }

    // ---- 颜色:有封面背景时全窗白色系,没有时退回系统色(浅色外观可读性) ------------

    private var primaryTextColor: Color { hasArtworkBackground ? .white : .primary }
    private var secondaryTextColor: Color { hasArtworkBackground ? .white.opacity(0.6) : .secondary }

    // 距当前行的行数差——按下标算,不按内容(副歌重复句内容相同但下标不同,详见
    // LyricsSyncEngine.activeLineIndex 的注释)。nil(还没播到第一句)统一按"远"处理。
    private func distance(for index: Int) -> Int? {
        guard let activeIdx = poller.currentLineIndex else { return nil }
        return abs(index - activeIdx)
    }

    // Apple Music 歌词页的景深:当前行完全清晰,其余行统一压到低不透明度、并随距离
    // 加重高斯模糊——非当前行之间的不透明度差异很小(0.50 → 0.35 缓降),远近感主要靠
    // 模糊量区分。nil(还没播到第一句)整页轻虚化,保持可读。
    private func lineOpacity(forDistance distance: Int?) -> Double {
        guard let d = distance else { return 0.45 }
        if d == 0 { return 1 }
        return max(0.35, 0.55 - Double(d) * 0.05)
    }

    // 距离越远、高斯模糊越重——1.1pt/行、封顶 4pt。2026-08-04 第一版按 1.6pt/行封顶
    // 6pt,用户对照 AM 同曲截图反馈"太糊了,后面几行都失真了"——AM 最远的可见行仍然
    // 认得出字形(模糊半径约为字号的 12~14%,6pt/28pt 是 21%),照它调轻。SwiftUI 的
    // .blur() 本身就是可动画属性,复用调用点已有的 .animation(value: distance)。
    private func lineBlur(forDistance distance: Int?) -> CGFloat {
        guard let d = distance else { return 2 }
        return min(CGFloat(d) * 1.1, 4)
    }

    private var hasArtworkBackground: Bool { poller.artworkData != nil }

    // Apple Music 歌词页最标志性的元素:当前封面模糊放大铺满、压一层半透明黑提升文字
    // 可读性。data 解码失败(损坏的图片数据,理论上不该发生,fetchArtwork() 已经在
    // Data(base64Encoded:) 这一步失败就返回 nil 了,这里只是再兜一层)时同样什么都不画,
    // 退回系统默认背景,不留一个突兀的纯色占位块。
    //
    // 故意不加 .ignoresSafeArea()——加了之后这层背景会一路铺到标题栏底下(实测坐实:
    // 2026-08-01 用户反馈"歌词窗口"标题栏文字"有时候会不明显"),系统标题栏文字颜色是
    // 按"标题栏本该是不透明系统材质"这个假设算的,被我们自己这层深色模糊图顶到底下之后
    // 撞色、对比度不够。去掉这个修饰符,背景就只填满 ScrollView 自己的内容区域(标题栏
    // 下方),不需要额外裁剪——ScrollView 的 frame 本来就已经是"标题栏以下的可用区域",
    // 内部 LazyVStack 的上下 60pt padding 不影响 ScrollView 自身、也就不影响这层
    // .background() 铺的范围。
    @ViewBuilder
    private var artworkBackground: some View {
        if let nsImage = poller.artworkImage {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                // 2026-08-04 按 Apple Music 截图重调:它的背景是亮而饱和的(饱和度拉高、
                // 只压一层不重的黑),不是旧版那种压 45% 黑的暗色调。blur 的 opaque: true
                // 让模糊不采样边缘外的透明区,避免四周一圈发暗的镶边——不需要再放大图片
                // 去遮。
                //
                // 22% 这一档是拿两类封面跟 AM 逐像素取样校准出来的(不是拍脑袋):橙色
                // 饱和封面 raw B 0.72→AM 显示 0.58、浅色封面 0.63→0.50,都精确等于
                // "压 22% 黑"。中途试过按封面亮度自适应加重遮罩(0.12+0.36×lum),实测
                // 浅色封面被压到 0.41、比 AM 明显更暗,已回退——AM 对同源(Apple 官方
                // 封面,跟这里 media-control 拿到的是同一张)就是固定一档,不自适应;
                // 网页端因为封面源不同(网易云/QQ 版本亮度分布不一样)才需要那套 canvas
                // 自适应归一,两边故意不同,见 index.html computeArtScrim() 注释。
                .saturation(1.5)
                .blur(radius: 72, opaque: true)
                .overlay(Color.black.opacity(0.22))
                .clipped()
                // 动画触发键仍用原始字节 poller.artworkData(Data 是按字节比较的 Equatable),
                // 保持跟改用解码缓存之前逐字节相同的判定语义 —— artworkImage 是 NSObject,
                // == 退化成指针比较,语义上不等价。跟灵动岛那边同一套写法。
                .animation(.easeInOut(duration: 0.5), value: poller.artworkData)
        }
    }

    // 完全没有歌词内容 vs "这首歌还没解析完、collector 后台正在搜"共用同一个
    // allLines.isEmpty,含义不一样,判断条件跟 LyricsOverlayView.mainLine 里的同一个
    // 分支保持一致(poller.hasLyricsContent 的注释详见 LocalPlaybackSource)。文案复用
    // 已有的本地化字符串,不新造。
    // 广告/纯音乐两个分支必须排在"还在搜索中"前面,理由跟 LyricsOverlayView.mainLine
    // 一致,见 poller.isCurrentTrackAdBreak / isCurrentTrackInstrumental 定义处的注释。
    private var emptyStateSpec: (icon: String, text: String) {
        if poller.isCurrentTrackAdBreak { return ("megaphone", L10n.t("广告中")) }
        if poller.isCurrentTrackInstrumental { return ("waveform", L10n.t("纯音乐")) }
        if poller.isPlayingNow && !poller.hasLyricsContent { return ("magnifyingglass", L10n.t("搜索歌词中…")) }
        return ("text.quote", L10n.t("无歌词"))
    }

    @ViewBuilder
    private var emptyState: some View {
        let spec = emptyStateSpec
        if hasArtworkBackground {
            // 封面背景上 ContentUnavailableView 的系统默认文字颜色没法覆盖(深色模糊图
            // 上的浅色外观深色文字基本看不清),换成自绘的白色版本,条件跟系统版共用
            // emptyStateSpec。
            VStack(spacing: 12) {
                Image(systemName: spec.icon).font(.system(size: 40))
                Text(spec.text).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(spec.text, systemImage: spec.icon)
        }
    }

    @ViewBuilder
    private func lineView(_ item: LyricsWindowLine, distance: Int?, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.showRomanization, let roma = item.line.romanization {
                Text(roma)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
            }
            mainText(item, isActive: isActive)
            if settings.showTranslation, let tr = item.line.translation {
                Text(tr)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(secondaryTextColor)
            }
        }
        // Apple Music 歌词是左对齐排版,2026-08-04 从居中改过来。
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(lineOpacity(forDistance: distance))
        // 模糊跟缩放一样受 reduceMotion 影响时直接关掉——虽然模糊本身不是"位移类"动效,
        // 但它是这套"聚焦感"视觉效果里跟缩放同一批的非必要装饰,减少动态效果的用户大概率
        // 也不想要这层模糊,统一用同一个开关关掉,不单独加一个新设置项。
        .blur(radius: reduceMotion ? 0 : lineBlur(forDistance: distance))
        // 当前行只轻微放大(1.02x)——Apple Music 全行同一字号,当前行靠亮度/清晰度+
        // 一点点缩放"浮起"。anchor 用 .leading:左对齐排版下从行首往右生长,不是从中心
        // 向两边(那样行首会跟着左右移动)。
        .scaleEffect(isActive && !reduceMotion ? 1.02 : 1, anchor: .leading)
        .animation(.easeInOut(duration: 0.3), value: distance)
    }

    @ViewBuilder
    private func mainText(_ item: LyricsWindowLine, isActive: Bool) -> some View {
        // Apple Music 歌词页所有行同一字号同一字重(远近靠透明度+模糊区分,不靠字号),
        // 当前行的逐字填色也是"同色 35% → 全强度"的同色系渐变,不引入另一个强调色——
        // 2026-08-04 按截图一比一对照改过来(旧版是当前行 accentColor 30pt/其余 24pt)。
        // 有封面背景时这个"同色"是白色;没有封面时退回系统 .primary(白字在浅色外观的
        // 默认窗口背景上不可读,正确性优先),远近区分交给 lineOpacity。
        let base: Color = hasArtworkBackground ? .white : .primary
        if isActive, let words = item.line.words {
            // 逐字高亮用跟悬浮歌词(LyricsOverlayView)同一套软边渐变算法
            // (WordKaraokeGradient,见该文件顶部注释),TimelineView(.animation)
            // 按渲染帧频现算,只有当前这一行会挂这个逐帧刷新的 TimelineView,不影响
            // 列表里其它行。
            TimelineView(.animation(paused: !poller.isPlayingNow)) { context in
                // 加上 currentLyricsOffsetMs,理由跟 LyricsOverlayView.mainLine 同一段
                // 注释——不加的话"当前词判定"和"填色进度"用的时间基准对不上,会出现填到
                // 一半就卡住的现象。
                let currentMs = (poller.anchor?.extrapolatedPositionMs(now: context.date) ?? 0) + poller.currentLyricsOffsetMs
                WrapLayout(rowAlignment: .leading) {
                    ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                        let fraction = WordKaraokeGradient.fillFraction(for: w, atMs: currentMs)
                        let band = WordKaraokeGradient.wordEdgeSoftenBand
                        Text(w.text)
                            .foregroundStyle(WordKaraokeGradient.gradient(fg: base, left: fraction - band, right: fraction + band))
                    }
                }
            }
            .font(.system(size: 28, weight: .bold))
        } else {
            Text(item.line.plainText ?? "")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(base)
        }
    }
}
