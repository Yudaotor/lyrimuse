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

    var body: some View {
        ScrollViewReader { scrollProxy in
            Group {
                if poller.allLines.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(Array(poller.allLines.enumerated()), id: \.element.id) { index, item in
                                lineView(item, distance: distance(for: index), isActive: item.id == activeID)
                                    .id(item.id)
                            }
                        }
                        .padding(.vertical, 60)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity)
                    }
                    // 只在真的展示歌词内容这个分支铺封面背景——emptyState 的
                    // ContentUnavailableView 用的是没法在这里覆盖的系统默认文字颜色,
                    // 铺在它背后会有前面注释说的可读性问题,直接不铺,维持系统默认背景。
                    .background(artworkBackground)
                }
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
        .frame(minWidth: 360, idealWidth: 460, minHeight: 480, idealHeight: 640)
        .background(LyricsWindowCapture(controller: windowController).frame(width: 0, height: 0))
    }

    private var activeID: String? {
        guard let idx = poller.currentLineIndex, poller.allLines.indices.contains(idx) else { return nil }
        return poller.allLines[idx].id
    }

    private func scrollToActiveLine(scrollProxy: ScrollViewProxy, animated: Bool) {
        guard let id = activeID else { return }
        if animated {
            withAnimation { scrollProxy.scrollTo(id, anchor: .center) }
        } else {
            scrollProxy.scrollTo(id, anchor: .center)
        }
    }

    // 距当前行的行数差——按下标算,不按内容(副歌重复句内容相同但下标不同,详见
    // LyricsSyncEngine.activeLineIndex 的注释)。nil(还没播到第一句)统一按"远"处理。
    private func distance(for index: Int) -> Int? {
        guard let activeIdx = poller.currentLineIndex else { return nil }
        return abs(index - activeIdx)
    }

    // Apple Music 歌词页的核心视觉语言是"按跟当前行的远近分档淡出",照抄这个项目自己
    // 已经在网页端(index.html .lrc-line/.lrc-near)验证过的三档不透明度,数值直接复用
    // 保持两端视觉语言一致:当前行 1.0、前后各一行 0.6、再远 0.35。
    private func lineOpacity(forDistance distance: Int?) -> Double {
        switch distance {
        case .some(0): return 1
        case .some(1): return 0.6
        default: return 0.35
        }
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
        if let data = poller.artworkData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .blur(radius: 60)
                .overlay(Color.black.opacity(0.45))
                .clipped()
                .animation(.easeInOut(duration: 0.5), value: data)
        }
    }

    // 完全没有歌词内容 vs "这首歌还没解析完、collector 后台正在搜"共用同一个
    // allLines.isEmpty,含义不一样,判断条件跟 LyricsOverlayView.mainLine 里的同一个
    // 分支保持一致(poller.hasLyricsContent 的注释详见 LocalPlaybackSource)。文案复用
    // 已有的本地化字符串,不新造。
    @ViewBuilder
    private var emptyState: some View {
        if poller.isCurrentTrackAdBreak {
            // 必须排在"还在搜索中"分支前面,理由跟 LyricsOverlayView.mainLine 一致,见
            // poller.isCurrentTrackAdBreak 定义处的注释。
            ContentUnavailableView(L10n.t("广告中"), systemImage: "megaphone")
        } else if poller.isCurrentTrackInstrumental {
            // 必须排在"还在搜索中"分支前面,理由跟 LyricsOverlayView.mainLine 一致,见
            // poller.isCurrentTrackInstrumental 定义处的注释。
            ContentUnavailableView(L10n.t("纯音乐"), systemImage: "waveform")
        } else if poller.isPlayingNow && !poller.hasLyricsContent {
            ContentUnavailableView(L10n.t("搜索歌词中…"), systemImage: "magnifyingglass")
        } else {
            ContentUnavailableView(L10n.t("无歌词"), systemImage: "text.quote")
        }
    }

    @ViewBuilder
    private func lineView(_ item: LyricsWindowLine, distance: Int?, isActive: Bool) -> some View {
        VStack(spacing: 4) {
            if settings.showRomanization, let roma = item.line.romanization {
                Text(roma)
                    .font(.system(size: 15))
                    .foregroundStyle(hasArtworkBackground ? Color.white.opacity(0.7) : Color.secondary)
            }
            mainText(item, isActive: isActive)
            if settings.showTranslation, let tr = item.line.translation {
                Text(tr)
                    .font(.system(size: 16))
                    .foregroundStyle(hasArtworkBackground ? Color.white.opacity(0.7) : Color.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .opacity(lineOpacity(forDistance: distance))
        // 当前行放大一档(1.04x)——同样照抄网页端 .lrc-line.active { transform:
        // scale(1.04) },减少动态效果的系统设置(reduceMotion)下跟网页
        // @media(prefers-reduced-motion) 的处理保持一致,直接不做缩放。
        .scaleEffect(isActive && !reduceMotion ? 1.04 : 1)
        .animation(.easeInOut(duration: 0.3), value: distance)
    }

    @ViewBuilder
    private func mainText(_ item: LyricsWindowLine, isActive: Bool) -> some View {
        // 非当前行的主文字颜色规则(见文件顶部注释里"例外"那段):有封面背景就固定用
        // 浅色,没有就吃系统 .primary。当前行逐字高亮"还没唱到"的部分不用这个——那是
        // WordKaraokeGradient 用 accentColor 自己算出的暗淡版本(见下面 gradient 调用),
        // 让整条当前行始终是同一个 accentColor 色调,只是亮度不同。
        let dimmedText: Color = hasArtworkBackground ? .white : .primary
        if isActive, let words = item.line.words {
            // 逐字高亮改用跟悬浮歌词(LyricsOverlayView)同一套软边渐变算法
            // (WordKaraokeGradient,见该文件顶部注释)——原来这里是二值判断(唱到/
            // 没唱到瞬间切换)+ 100ms 一档的 .periodic 采样,被指出观感不够丝滑,根源
            // 就是没有复用悬浮窗那套已经调好的连续渐变。换成同款 TimelineView(.animation)
            // 按渲染帧频现算,只有当前这一行会挂这个逐帧刷新的 TimelineView,不影响
            // 列表里其它行。
            TimelineView(.animation(paused: !poller.isPlayingNow)) { context in
                // 加上 currentLyricsOffsetMs,理由跟 LyricsOverlayView.mainLine 同一段
                // 注释——不加的话"当前词判定"和"填色进度"用的时间基准对不上,会出现填到
                // 一半就卡住的现象。
                let currentMs = (poller.anchor?.extrapolatedPositionMs(now: context.date) ?? 0) + poller.currentLyricsOffsetMs
                WrapLayout {
                    ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                        let fraction = WordKaraokeGradient.fillFraction(for: w, atMs: currentMs)
                        let band = WordKaraokeGradient.wordEdgeSoftenBand
                        Text(w.text)
                            .foregroundStyle(WordKaraokeGradient.gradient(fg: .accentColor, left: fraction - band, right: fraction + band))
                    }
                }
            }
            .font(.system(size: 30, weight: .bold))
        } else {
            // 字号也跟着当前/非当前分两档(30 / 24),不只是颜色/透明度——真正的 Apple
            // Music 歌词页当前行会明显更大,不是网页迷你卡片那种"字号不变、只变颜色"的
            // 简化版(网页 .lrc-main 空间太小放不下字号差异)。粗细统一用 .bold,不再
            // 像悬浮窗那样只有当前行加粗——网页端 .lrc-main 本身不论是否高亮都是
            // font-weight:700,这次直接照抄这个"整体粗体、靠字号+颜色+透明度分层"的
            // 处理。
            Text(item.line.plainText ?? "")
                .font(.system(size: isActive ? 30 : 24, weight: .bold))
                .foregroundStyle(isActive ? Color.accentColor : dimmedText)
        }
    }
}
