import AppKit
import SwiftUI
import Combine
import LyrimuseCore

/// 歌词窗口的**窄订阅代理**(2026-08-19 性能审计,五个展示面最后一个接上;完整机制见
/// OverlayPlayback 的注释)。这扇窗实读面本来就大(37 个 @Published 读约 24 个),代理的
/// 收益不在"滤掉大半",而在三处:① 滤掉它不读的高频源 —— currentLine/nextLineText 每句
/// 歌词各发一次,原来每句白打醒整窗 body 2~3 次;② soundVolume **故意不转发**,音量胶囊
/// 下沉成自持订阅的子视图(WindowVolumeCapsule),拖音量只失效那个小胶囊;③ 值类型逐条
/// removeDuplicates。anchor 入订阅(progressSection 要按锚点存在性分支,重锚低频);
/// 填色闭包里的 anchor/offset 仍直读协调器(TimelineView 按帧重跑,见 KaraokeWordText)。
@MainActor
private final class WindowPlayback: ObservableObject {
    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var isPlayingSmoothed = false
    @Published private(set) var currentLineIndex: Int?
    @Published private(set) var currentGapIndex: Int?
    @Published private(set) var allLines: [LyricsWindowLine] = []
    @Published private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published private(set) var currentLineFillSettled = true
    @Published private(set) var artworkData: Data?
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var highResArtworkImage: NSImage?
    @Published private(set) var windowBlurredArtworkImage: NSImage?
    @Published private(set) var anchor: ProgressAnchor?
    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?
    @Published private(set) var isFavorited: Bool?
    @Published private(set) var playbackMode: MusicPlaybackController.MusicPlaybackMode?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    // ---- 来自 AppSettings(只挑本窗口实读的两项) ----
    @Published private(set) var showRomanization = true
    @Published private(set) var showTranslation = false
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$isPlayingSmoothed.removeDuplicates().sink { [weak self] in self?.isPlayingSmoothed = $0 },
            p.$currentLineIndex.removeDuplicates().sink { [weak self] in self?.currentLineIndex = $0 },
            p.$currentGapIndex.removeDuplicates().sink { [weak self] in self?.currentGapIndex = $0 },
            p.$allLines.removeDuplicates().sink { [weak self] in self?.allLines = $0 },
            p.$lyricsGapMarkers.removeDuplicates().sink { [weak self] in self?.lyricsGapMarkers = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$artworkData.removeDuplicates().sink { [weak self] in self?.artworkData = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
            p.$windowBlurredArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.windowBlurredArtworkImage = $0 },
            p.$anchor.sink { [weak self] in self?.anchor = $0 },
            p.$pausedPositionMs.removeDuplicates().sink { [weak self] in self?.pausedPositionMs = $0 },
            p.$currentDurationMs.removeDuplicates().sink { [weak self] in self?.currentDurationMs = $0 },
            p.$isFavorited.removeDuplicates().sink { [weak self] in self?.isFavorited = $0 },
            p.$playbackMode.removeDuplicates().sink { [weak self] in self?.playbackMode = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            s.$showRomanization.removeDuplicates().sink { [weak self] in self?.showRomanization = $0 },
            s.$showTranslation.removeDuplicates().sink { [weak self] in self?.showTranslation = $0 },
        ]
    }
}

// 这个绿色按钮目前只会"放大铺满屏幕",点不出真正的原生全屏(独立 Space、隐藏菜单栏/
// Dock)——2026-08-01 实测排查过一整轮,不是这个窗口自己代码的问题:"歌词管理"这个
// 完全没碰过的既有窗口,按钮同样是 AXZoomButton 而不是 AXFullScreenButton(拿 TextEdit
// 一个正常支持全屏的窗口对比过,那边点了真的会全屏,AXFullScreen 从 false 变 true;
// 这两个窗口点了 AXFullScreen 恒为 false),说明这是这个 App 里所有 Window(id:) 场景
// 共有的表现,不是这一个视图的局部问题。
//
// ⚠️ 2026-08-16 订正:当时把原因归到"MenuBarExtra 作为主 Scene 的这整个 App"上,这个
// 归因是错的。菜单栏那一项这天换成了自建 NSStatusItem、MenuBarExtra 已经从 App.swift
// 里整个删掉,重新用 AX 查过这扇窗:绿色按钮仍然是 AXZoomButton、没有
// AXFullScreenButton、AXFullScreen 仍恒为 false。所以 MenuBarExtra 是被排除的第 4 个
// 假设,真正的原因还没找到。已经验证过并排除的
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
    /// 窗口此刻在不在屏幕上 —— App 激活刷新的可见性守卫用(Window 场景关闭后视图树
    /// 保活,onReceive 还会进来)。
    var isWindowVisible: Bool { window?.isVisible ?? false }
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
    // 不整对象订阅 PlaybackCoordinator/AppSettings —— 见 WindowPlayback 的注释。
    @StateObject private var playback = WindowPlayback()
    @StateObject private var windowController = LyricsWindowController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 这块屏一个点等于几个物理像素。外接 1x 显示器上 = 1,内建 Retina = 2 —— 逐字抬升
    // 的落点要按它对齐到整像素,见 karaokeRise。
    @Environment(\.displayScale) private var displayScale
    /// 封面的实际边长。控制排的图标大小和间距都按它算 —— 封面是随窗口缩放的,而按钮
    /// 原来是写死的字号,窄窗口下整排比左栏还宽、最左边那个模式键直接被裁在窗口外面
    /// (2026-08-09 用户截图),宽窗口下又显得过小、跟封面不成比例。
    @State private var artworkWidth: CGFloat = 0
    /// 鼠标悬在哪一行(行 id)。悬停的行不虚化、点一下跳到那一句。
    @State private var hoveredLineID: String?
    /// 歌词那一栏的实际宽度。字号按它算 —— 写死 28pt 的话窗口越拖越大、文字占的比例
    /// 越来越小,右边空出一大片(2026-08-09 用户对比 Apple Music 提的)。Apple Music 的
    /// 歌词字号是跟着窗口长的,这里照做,再夹进一个区间,不无限放大。
    @State private var lyricsColumnWidth: CGFloat = 0

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
                // ⚠️ 音量胶囊必须**浮在内容之上**,不能放进 .toolbar。
                //
                // 2026-08-09 用户反馈"这个玻璃效果好垃圾",对比 Apple Music 那个能透出背景
                // 暖色、边缘有光泽的胶囊。查了 Liquid Glass 的规则(见 LiquidGlassReference:
                // "Glass cannot sample other glass"、"Avoid Glass-on-Glass"、玻璃只用于
                // **浮在内容之上**的导航层),再做了一次对照实验:同一个胶囊同时放进工具栏和
                // 内容浮层,同一张截图里工具栏那个是灰扁色块、浮层那个透出了背后模糊封面的
                // 暖棕色。工具栏本身就是一层玻璃,玻璃采样不到玻璃,只能退化成不透明材质。
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 10) {
                        // 音量胶囊自持订阅(2026-08-19 性能审计):soundVolume 故意不进
                        // WindowPlayback 代理,拖音量只失效这个小胶囊,不再整窗重估。
                        WindowVolumeCapsule(onArtwork: hasArtworkBackground)
                        windowActionsCapsule(scrollProxy: scrollProxy)
                    }
                    .padding(.trailing, 18)
                    .padding(.top, 14)
                }
            }
            .onChange(of: playback.currentLineIndex) {
                scrollToActiveLine(scrollProxy: scrollProxy, animated: true)
            }
            .onChange(of: playback.currentGapIndex) {
                // 进入间奏 → 滚到那排「•••」(跟当前行同一个 0.35 锚位)。出间奏不用管:
                // 下一句开始时 currentLineIndex 变化,上面那条 onChange 自然把页面滚过去。
                if let g = playback.currentGapIndex, let id = gapRowID(g) {
                    withAnimation(Self.lineTransition) {
                        scrollProxy.scrollTo(id, anchor: Self.activeLineAnchor)
                    }
                }
            }
            .onChange(of: playback.allLines) {
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
        // 音量跟"喜欢""播放模式"共用同一批刷新时机,理由见下面那段注释。
        // "喜欢"状态不跟着 2 秒轮询走(每读一次要起一个 osascript 子进程,为一个几乎不变
        // 的布尔值那么干不值当),换歌时由 PlaybackCoordinator 刷一次。悬浮窗还借"控制排
        // 露出来"这个动作补刷,而这扇窗口是常显的、没有那个动作,所以换成:打开时刷一次,
        // 以及每次 App 重新变成前台时刷一次 —— 后者正好覆盖"用户刚切去 Music.app 点了
        // 心、再切回来"这条路径。
        .onAppear {
            PlaybackCoordinator.shared.refreshFavorited()
            PlaybackCoordinator.shared.refreshPlaybackMode()
            PlaybackCoordinator.shared.refreshVolume()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // 可见性守卫(2026-08-19 性能审计):Window 场景关闭后视图树/订阅仍保活,
            // 原来每次 App 激活(Cmd-Tab/点状态栏)都在关着的窗口背后白起最多 3 个
            // osascript 子进程。重开窗口时上面 onAppear 的全量刷新本来就会跑一遍。
            guard windowController.isWindowVisible else { return }
            PlaybackCoordinator.shared.refreshFavorited()
            PlaybackCoordinator.shared.refreshPlaybackMode()
            PlaybackCoordinator.shared.refreshVolume()
        }
    }

    private var activeID: String? {
        guard let idx = playback.currentLineIndex, playback.allLines.indices.contains(idx) else { return nil }
        return playback.allLines[idx].id
    }

    // Apple Music 歌词页把当前行定位在窗口偏上约 1/3 处(不是正中)——上面留少量已经
    // 唱过的行,下面留更多即将到来的行,2026-08-04 从 .center 改过来。
    private static let activeLineAnchor = UnitPoint(x: 0.5, y: 0.35)

    /// 换行时整页滚动 + 每行虚化/亮度/缩放变化,用**同一条**曲线、同一个时长 —— 原来滚动
    /// 用 withAnimation 的默认曲线、行样式用 easeInOut(0.3),两套动画各走各的,同一次换行
    /// 里页面和文字的节奏对不上,看起来就是"一顿一顿"。
    ///
    /// 用 .smooth(无回弹的弹簧)而不是 easeInOut:Apple Music 的歌词滚动是减速停下、末尾
    /// 不回弹,easeInOut 起步太"推"、收尾太硬。
    static let lineTransition: Animation = .smooth(duration: 0.45)

    private func scrollToActiveLine(scrollProxy: ScrollViewProxy, animated: Bool) {
        guard let id = activeID else { return }
        if animated {
            withAnimation(Self.lineTransition) {
                scrollProxy.scrollTo(id, anchor: Self.activeLineAnchor)
            }
        } else {
            scrollProxy.scrollTo(id, anchor: Self.activeLineAnchor)
        }
    }

    // ---- 右列:歌词滚动列表 / 占位态 --------------------------------------------

    /// 歌词正文字号。0.072 这个系数是量 Apple Music 歌词页截图反推的:它的歌词栏宽约
    /// 485pt、字号约 35pt。下界 22 保证窄窗口下还能读,上界 56 避免超宽屏上一行只放得下
    /// 三四个字。
    private var lyricFontSize: CGFloat {
        let w = lyricsColumnWidth > 0 ? lyricsColumnWidth : 460
        return min(56, max(22, w * 0.072))
    }
    // 罗马音/译文跟正文保持原来的比例(15/28、17/28),行间距同理(32/28)。
    private var romaFontSize: CGFloat { lyricFontSize * 0.54 }
    private var translationFontSize: CGFloat { lyricFontSize * 0.61 }
    private var lyricLineSpacing: CGFloat { lyricFontSize * 1.14 }

    @ViewBuilder
    private var rightPane: some View {
        if playback.allLines.isEmpty {
            emptyState
        } else {
            ScrollView {
                // 用 VStack 而不是 LazyVStack:歌词就几十行(这首 43 行),lazy 省不下什么,
                // 却会让带动画的 scrollTo 卡 —— 目标行没渲染过就没有尺寸,滚动动画得一边
                // 跑一边现算行高,表现就是换行时一顿一顿。全部一次性布好之后,滚动只是
                // 平移已经量好的内容。
                VStack(alignment: .leading, spacing: lyricLineSpacing) {
                    // 前奏的「•••」放在第一行之前(间奏点数据见 gapMarker/gapDotsRow)。
                    if let intro = gapMarker(-1), let firstID = playback.allLines.first?.id {
                        gapDotsRow(intro, id: "\(firstID)-intro")
                    }
                    ForEach(Array(playback.allLines.enumerated()), id: \.element.id) { index, item in
                        // .equatable():没有它,**每一行**都会跟着整页 body 重算一遍。
                        //
                        // 2026-08-14 用 sample 量到的:稳定播放期间主线程有 ~22% 的时间耗在
                        // NSHostingView.layout → ViewGraphRootValueUpdater.render 里,栈里能
                        // 看到 ForEachChild.updateValue → lineView,也就是几十行全在重建。
                        // LyricsWindowView 订阅的是整个 PlaybackCoordinator(二十来个
                        // @Published),任何一个变动都会重算 body;而行视图带闭包参数
                        // (onTap/onHover),函数值永远不相等,SwiftUI 自带的结构比较救不了,
                        // 必须显式给一个只比较**值输入**的 ==。
                        LyricsLineRow(
                            item: item,
                            distance: distance(for: index),
                            // 间奏进行中"当前"是那排「•••」,唱完的行不再保持活跃态。
                            isActive: item.id == activeID && playback.currentGapIndex == nil,
                            isHovered: hoveredLineID == item.id,
                            isPlaying: playback.isPlayingNow,
                            // 只给**当前行**传真实值,其余行恒 false —— settled 每行翻转
                            // 两次,全表行都跟着比较变化的话,一次翻转就是整表行重算。
                            fillSettled: item.id == activeID && playback.currentLineFillSettled,
                            fontSize: lyricFontSize,
                            romaFontSize: romaFontSize,
                            translationFontSize: translationFontSize,
                            onArtwork: hasArtworkBackground,
                            showRomanization: playback.showRomanization,
                            showTranslation: playback.showTranslation,
                            reduceMotion: reduceMotion,
                            displayScale: displayScale,
                            onHover: { inside in
                                if inside { hoveredLineID = item.id }
                                else if hoveredLineID == item.id { hoveredLineID = nil }
                            },
                            onTap: {
                                // 减去当前歌词偏移:引擎判定"现在是哪一行"时会把 offsetMs 加到
                                // 播放位置上(见 activeLine),这里不减回去的话,跳过去之后落在
                                // 的会是隔壁行。
                                PlaybackCoordinator.shared.seek(toMs: max(0, item.timeMs - PlaybackCoordinator.shared.currentLyricsOffsetMs))
                            }
                        )
                        .equatable()
                        .id(item.id)
                        // 这一行之后有间奏 → 插「•••」(不活跃时零高度不占位,见 gapDotsRow)。
                        if let g = gapMarker(index) {
                            gapDotsRow(g, id: "\(item.id)-gap")
                        }
                    }
                }
                // 间奏点的插入/移除(以及各行随之退暗一档)跟换行滚动同一条曲线。
                // 用 value 限定形而不是 withAnimation:只在进出间奏那一刻生效,
                // 不会波及各行叶子上逐帧跑的填色 TimelineView(上午面板那个坑)。
                .animation(Self.lineTransition, value: playback.currentGapIndex)
                .padding(.vertical, 88)
                .padding(.leading, 44)
                .padding(.trailing, 52)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { lyricsColumnWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in lyricsColumnWidth = w }
                }
            )
            // 上下边缘渐隐。
            //
            // 2026-08-09 用户反馈右上角那两个玻璃胶囊挡住歌词。挪走不如照 Apple Music 的
            // 做法:它的胶囊也在右上角、歌词也从底下滚过去,靠的是列表顶部有一段渐隐,
            // 文字在够到胶囊之前就已经淡掉了。
            //
            // 右上角本来也是最该放它们的位置 —— 当前行锚在从上往下 35% 处(activeLineAnchor),
            // 所以上方是**已经唱过的**行,下方是还没唱到、跟着唱时要预读的行。要挡也是挡
            // 上面那半。
            //
            // 顺带底边也渐隐:滚动列表被窗口边缘直切一刀本来就不好看。
            .mask(
                LinearGradient(
                    stops: [
                        // 顶部这一段要一直全透明到**胶囊下沿之后**才开始显现 —— 胶囊占了
                        // 内容区顶部约 7% 的高度,渐隐若从 0 就开始爬,滚到那里的文字仍有
                        // 一半不透明度,照样糊在胶囊上。
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.075),
                        .init(color: .black, location: 0.2),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
        }
    }

    // ---- 左列:封面 + 曲目信息 + 进度条 + 播放控制 --------------------------------

    private var playerPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 20)
            artworkCard
            trackInfoRow
                .padding(.top, 22)
            // 进度条子视图自持五个拖动/补间瞬态(2026-08-19 性能审计):1Hz 补间推进、
            // 拖动、悬停变粗的失效全部收敛在子树内,不再击穿整窗。
            WindowProgressSection(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                onArtwork: hasArtworkBackground)
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
                // 优先用高清替代:这张卡最大 460pt(Retina 下 920px),而系统 Now Playing
                // 给的封面可能只有 100×100(网易云客户端就是),放大 9 倍会明显糊。
                // highResArtworkImage 只在系统那份确实太小时才有值,见它的注释。
                if let nsImage = playback.highResArtworkImage ?? playback.artworkImage {
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
            .animation(.easeInOut(duration: 0.5), value: playback.artworkData)
            // 高清替代到货/撤掉同样交叉淡入(指针比较在这里是对的:每次到货都是新解码的
            // NSImage 实例)。
            .animation(.easeInOut(duration: 0.5), value: playback.highResArtworkImage)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(hasArtworkBackground ? 0.45 : 0.2), radius: 26, y: 12)
            // 封面随播放状态缩放(2026-08-19 用户要求,仿 Apple Music 歌词页):播放满幅、
            // 暂停缩到 78%,状态一眼可辨。scaleEffect 是渲染变换、不改布局 —— 下方
            // 歌名/进度条纹丝不动;放在 clipShape+shadow 之后,阴影跟着一起缩,观感同
            // Apple Music。用缓收版 isPlayingSmoothed 而不是 isPlayingNow:切歌间隙/
            // seek 的瞬时 false 会让封面每首歌之间都抖一下,0.5s 宽限正好吸掉,而暂停
            // 到收缩的那 0.5s 延迟无感。reduceMotion 下跳变不补间 —— 缩放本身是
            // "没在播放"的功能反馈,要保留,去掉的只是过渡。
            .scaleEffect(playback.isPlayingSmoothed ? 1 : 0.78, anchor: .center)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72),
                       value: playback.isPlayingSmoothed)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { artworkWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in artworkWidth = w }
                }
            )
    }

    private var trackInfoRow: some View {
        // 外层 HStack(2026-08-19 对齐 AM):文字块靠左,收藏/更多两颗圆钮贴右 ——
        // AM 歌词页就是这个排布。文字块可滚(MarqueeText),圆钮定宽不参与挤压。
        HStack(alignment: .center, spacing: 12) {
            trackInfoTexts
            Spacer(minLength: 8)
            titleSideButtons
        }
    }

    private var trackInfoTexts: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 放不下就滚,不再直接截断成 "Automatic (Remastered 20…" —— 这两行是这一栏
            // 唯一说明"现在放的是哪一版"的地方,截掉的恰好是版本后缀。
            // 显式给行高:MarqueeText 内部是 GeometryReader,纵向贪心,不定高会把整栏撑开。
            // 广告插播:歌名位写「广告中」,跟灵动岛(NotchLyricsView)和下面歌词区的空状态
            // (emptyStateSpec)用同一个判据、同一句文案。2026-08-19 用户报的就是这里 ——
            // 那两处早就处理了,只有这一行还在原样显示 Spotify 给的占位标题「—」,配上没有
            // 封面的占位图,整张卡看起来像是坏了。
            //
            // ⚠️ MarqueeText 的 id 必须用**显示串**而不是 playback.title:切进/切出广告时要
            // 重置跑马灯,用原标题的话 id 不变、滚动位置会带着上一条的进度(灵动岛那边
            // 同一个理由,见 NotchLyricsView 那段注释)。
            MarqueeText(id: displayTitle) {
                Text(displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(primaryTextColor)
            }
            .frame(height: 22)
            MarqueeText(id: displayArtistAlbum) {
                Text(displayArtistAlbum)
                    .font(.system(size: 17))
                    .foregroundStyle(secondaryTextColor)
            }
            .frame(height: 22)
        }
    }

    /// 标题右侧的 收藏(星)+ 更多(…)圆钮 —— Apple Music 歌词页同款位置与形态
    /// (2026-08-19 用户要求完全对齐:收藏从播放控制排挪上来;AM 现在的收藏就是星形,
    /// 心形是它的旧设计)。星只有 Apple Music 有(isFavorited 为 nil 不显示),
    /// 「…」始终在 —— 它装的是这扇窗自己的动作,与播放器无关。
    private var titleSideButtons: some View {
        HStack(spacing: 8) {
            if let favorited = playback.isFavorited {
                Button {
                    PlaybackCoordinator.shared.toggleFavorited()
                } label: {
                    circleIcon(favorited ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .help(L10n.t(favorited ? "取消喜欢" : "喜欢"))
            }
            Menu {
                Button(L10n.t("歌词管理…")) { AppActions.shared.openLyricsManager?() }
                Button(L10n.t("在播放器中打开")) { PlaybackCoordinator.shared.openResolvedPlayerApp() }
            } label: {
                // ⚠️ 这里只给**字形**,圆底画在 Menu 外面(下面那三行)。
                //
                // 2026-08-19 用户报「我们的『…』没有外面的圈」:原来这儿跟星星一样调
                // circleIcon(),但 macOS 的 Menu 在 .borderlessButton 样式下会把自定义 label
                // **压平成一张图**塞进它自己的控件单元里,label 上挂的 .background(圆底)
                // 一起被丢掉了(字形颜色也被控件接管,所以看着还比星星淡一档)。
                // 星星那边是普通 Button,同一份 circleIcon 就完好 —— 差别只在这层包装。
                //
                // 离屏渲染验不了这一处:ImageRenderer 压根不支持 Menu(实测渲出来是一块
                // 黄色的"不支持"占位),所以别再拿它去核对这个按钮。
                circleIconGlyph("ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // 不再 .fixedSize():让控件自己撑满 26×26,整个圆都是热区。原来 fixedSize
            // 之后控件只有字形那么大,圈的边缘点不动。
            .frame(width: 26, height: 26)
            .background(Circle().fill(circleIconFill))
            .contentShape(Circle())
        }
    }

    private func circleIcon(_ name: String) -> some View {
        circleIconGlyph(name)
            .frame(width: 26, height: 26)
            .background(Circle().fill(circleIconFill))
            .contentShape(Circle())
    }

    /// 圆底跟字形拆开:「…」那颗是 Menu,圆底只能画在 Menu 外面(见那边注释),
    /// 但两颗按钮的圆底必须是同一个值 —— 拆成一份常量,别在两处各写一遍。
    private var circleIconFill: Color {
        hasArtworkBackground ? Color.white.opacity(0.16) : Color.primary.opacity(0.08)
    }

    private func circleIconGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primaryTextColor.opacity(0.9))
    }

    // Apple Music 同款"歌手 — 专辑"一行(em dash),专辑缺失时只显示歌手。
    private var artistAlbumText: String {
        playback.album.isEmpty ? playback.artist : "\(playback.artist) — \(playback.album)"
    }

    /// 广告插播时歌名位显示的文案。判据 isCurrentTrackAdBreak 由 LocalPlaybackSource 给
    /// (字段启发式 + 同曲棘轮 + AppleScript `spotify url` 权威分类,见那边注释)。
    private var displayTitle: String {
        playback.isCurrentTrackAdBreak ? L10n.t("广告中") : playback.title
    }

    /// 广告插播时第二行**留空**,不展示广告物料的歌手/专辑名(用户 2026-08-19 拍板的口径,
    /// 跟灵动岛一致)。这不是多余的判断:广告有时会带全 artist/album 字段,不显式清掉的话
    /// 第二行会冒出广告主的名字。
    private var displayArtistAlbum: String {
        playback.isCurrentTrackAdBreak ? "" : artistAlbumText
    }


    // 控制排的尺寸全部从封面边长算出来,再夹进一个合理区间 —— 封面随窗口缩放,按钮
    // 写死尺寸就会在窄窗口下溢出被裁、在宽窗口下小得跟封面不成比例(2026-08-09 用户反馈)。
    // 夹值的上下界是按"最窄能用"和"再大就傻了"定的,不是等比无限放大。
    private var controlScale: CGFloat { artworkWidth > 0 ? artworkWidth : 300 }
    private func ctrl(_ ratio: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(hi, max(lo, controlScale * ratio))
    }

    private var playbackControls: some View {
        HStack(spacing: ctrl(0.115, 18, 48)) {
            shuffleButton
            Button {
                MusicPlaybackController.previousTrack()
            } label: {
                Image(systemName: "backward.fill").font(.system(size: ctrl(0.075, 15, 26)))
            }
            .help(L10n.t("上一首"))
            Button {
                MusicPlaybackController.playPause()
            } label: {
                Image(systemName: playback.isPlayingNow ? "pause.fill" : "play.fill")
                    .font(.system(size: ctrl(0.105, 21, 38)))
                    // 播放/暂停两个图标宽度不同,固定住避免两侧按钮跟着跳动
                    .frame(width: ctrl(0.12, 24, 44))
            }
            .help(L10n.t("播放/暂停"))
            Button {
                MusicPlaybackController.nextTrack()
            } label: {
                Image(systemName: "forward.fill").font(.system(size: ctrl(0.075, 15, 26)))
            }
            .help(L10n.t("下一首"))
            repeatButton
        }
        .buttonStyle(.plain)
        .foregroundStyle(primaryTextColor)
        .frame(maxWidth: .infinity)
    }

    /// 置顶 / 全屏 / 回到当前播放。
    ///
    /// 这三个原来是 .toolbar 里的 ToolbarItem。2026-08-09 搬出来的理由:工具栏的玻璃是
    /// 系统给的 .regular 磨砂档,我改不了它的材质,于是它永远是块不透明浅灰,跟旁边用
    /// .clear 的音量胶囊放在一起对比强烈。搬成浮层之后两组用同一档材质、同一套描边,
    /// 而且都能真的采样到背后的模糊封面。
    ///
    /// 顺带跟 Apple Music 更像了:它的窗口控件也是浮在内容上的胶囊,不是标题栏工具栏。
    private func windowActionsCapsule(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 14) {
            Button {
                windowController.toggleAlwaysOnTop()
            } label: {
                Image(systemName: windowController.isAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .frame(width: 16)
            }
            // 2026-08-02 补上——置顶/伪全屏这两个状态是"只在这次打开期间有效",不持久化
            // (见 LyricsWindowController 顶部注释),但按钮本身没有任何提示说明,习惯把它
            // 固定置顶的用户每次重开窗口都要重新点一次,容易被当成 bug。
            .help(
                (windowController.isAlwaysOnTop ? L10n.t("取消置顶") : L10n.t("置于最顶层"))
                    + " · " + L10n.t("这个状态只在本次打开这扇窗口期间有效，下次重新打开会恢复默认"))
            Button {
                windowController.toggle(reduceMotion: reduceMotion)
            } label: {
                Image(
                    systemName: windowController.isActive
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .font(.system(size: 12))
                .frame(width: 16)
            }
            .help(
                (windowController.isActive ? L10n.t("退出全屏") : L10n.t("进入全屏"))
                    + " · " + L10n.t("这个状态只在本次打开这扇窗口期间有效，下次重新打开会恢复默认"))
            Button {
                scrollToActiveLine(scrollProxy: scrollProxy, animated: true)
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 12))
                    .frame(width: 16)
            }
            .help(L10n.t("回到当前播放"))
        }
        .buttonStyle(.plain)
        // 图标跟着背景走:.clear 玻璃是透明的,背后是深色的模糊封面时 .secondary 会暗到
        // 快看不清 —— Apple Music 那两个胶囊上的图标也是白色系。
        .foregroundStyle(capsuleIconColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .clearGlassCapsule(
            rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
    }


    /// 随机(最左)/ 循环(最右)—— 按 Apple Music 歌词页的排布拆成两颗独立按钮
    /// (2026-08-19 用户要求完全对齐 AM;此前是一颗三态循环切换的「播放模式」钮 +
    /// 最右一颗心,收藏挪去了标题旁,见 titleSideButtons)。
    ///
    /// 底层仍是三态 playbackMode,两颗**互斥**:点亮随机=shuffle、点亮循环=repeatOne、
    /// 都不亮=list。AM 里随机和循环可以同时开,但脚本接口只有三态 —— 宁可少一个组合,
    /// 也不摆一个落不了地的开关。读不到模式(非 AM/Spotify、没权限)时不显示;定宽占位
    /// 保住播放键居中(两侧异步读出,不占位按钮排会在窗口打开后错开一瞬)。
    private var shuffleButton: some View {
        modeToggleButton(icon: "shuffle",
                         active: playback.playbackMode == .shuffle,
                         shown: playback.playbackMode != nil,
                         label: L10n.t("随机播放")) {
            PlaybackCoordinator.shared.setPlaybackMode(playback.playbackMode == .shuffle ? .list : .shuffle)
        }
    }

    /// Spotify 够不到单曲循环(脚本接口只有 repeating 布尔),这颗整个不显示、只占位。
    private var repeatButton: some View {
        modeToggleButton(icon: playback.playbackMode == .repeatOne ? "repeat.1" : "repeat",
                         active: playback.playbackMode == .repeatOne,
                         shown: playback.playbackMode != nil && PlaybackCoordinator.shared.playbackModeSupportsRepeatOne,
                         label: L10n.t("单曲循环")) {
            PlaybackCoordinator.shared.setPlaybackMode(playback.playbackMode == .repeatOne ? .list : .repeatOne)
        }
    }

    /// 点亮态:AM 同款「亮图标 + 一圈淡胶囊底」;熄灭态半透明。
    private func modeToggleButton(icon: String, active: Bool, shown: Bool, label: String,
                                  action: @escaping () -> Void) -> some View {
        Group {
            if shown {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(.system(size: ctrl(0.062, 13, 23)))
                        .opacity(active ? 1 : 0.55)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                active
                                    ? (hasArtworkBackground
                                        ? Color.white.opacity(0.22) : Color.primary.opacity(0.12))
                                    : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .help(label)
            }
        }
        .frame(width: ctrl(0.062, 13, 23) + 14)
    }

    // ---- 颜色:有封面背景时全窗白色系,没有时退回系统色(浅色外观可读性) ------------

    private var primaryTextColor: Color { hasArtworkBackground ? .white : .primary }
    /// 浮在内容上的那两个玻璃胶囊里的图标颜色。
    private var capsuleIconColor: Color {
        hasArtworkBackground ? .white.opacity(0.9) : .primary.opacity(0.75)
    }
    private var secondaryTextColor: Color { hasArtworkBackground ? .white.opacity(0.6) : .secondary }

    // 距当前行的行数差——按下标算,不按内容(副歌重复句内容相同但下标不同,详见
    // LyricsSyncEngine.activeLineIndex 的注释)。nil(还没播到第一句)统一按"远"处理。
    /// 视觉上真正有区别的最大行距。
    ///
    /// 不透明度 `max(0.35, 0.55 - d*0.05)` 到 d=4 就压到下限 0.35,模糊 `min(d*1.1, 4)`
    /// 到 d≈3.64 就封顶 —— 也就是说 d≥4 的行,**画出来一模一样**。
    ///
    /// 夹在这里的收益不是省几次乘法,而是让远处那几十行的 distance **不再变化**:
    /// LyricsLineRow 是 Equatable 的,输入没变就整行跳过重算,也不会去跑那条
    /// `.animation(value: distance)`。换行时真正需要重画/重跑动画的从"整表"缩到当前行
    /// 上下各 4 行。这一步是像素级等价的,不是拿观感换性能。
    private static let maxVisualDistance = 4

    private func distance(for index: Int) -> Int? {
        guard let activeIdx = playback.currentLineIndex else { return nil }
        // 间奏进行中整体退一档:此刻的"当前"是那排「•••」,唱完的那一行不该再保持
        // 全亮 —— Apple Music 间奏时上一句同样是退暗的。
        let gapPenalty = playback.currentGapIndex != nil ? 1 : 0
        return min(abs(index - activeIdx) + gapPenalty, Self.maxVisualDistance)
    }

    // ---- 间奏「•••」(2026-08-19,Apple Music 歌词页同款) --------------------------

    /// 间奏点按 index 建好的字典 —— gapMarker 被列表每行调一次,线性扫是 O(N×M);
    /// markers 只在换歌时变,这里作为计算属性每次 body 建一次 O(M)(M 通常个位数),
    /// 仍远优于 N×M。
    private var gapMarkersByIndex: [Int: LyricsGapMarker] {
        Dictionary(uniqueKeysWithValues: playback.lyricsGapMarkers.map { ($0.index, $0) })
    }

    private func gapMarker(_ index: Int) -> LyricsGapMarker? {
        gapMarkersByIndex[index]
    }

    /// 间奏活跃时滚动定位用的行 id(跟列表里 gapDotsRow 的 .id 拼法保持一致)。
    private func gapRowID(_ index: Int) -> String? {
        if index == -1 { return playback.allLines.first.map { "\($0.id)-intro" } }
        guard playback.allLines.indices.contains(index) else { return nil }
        return "\(playback.allLines[index].id)-gap"
    }

    /// 三颗呼吸圆点。不活跃时**整行不渲染**(零高度零开销,VStack 也不会为它多出一段
    /// 行距);间奏进行中在原位展开,三颗点随间奏进度依次点亮 —— 活跃判定在数据层
    /// (LocalPlaybackSource 20Hz 发布 currentGapIndex,进出间奏才变),同一时刻至多
    /// 一行在跑 TimelineView(0.5s 一档,足够点亮的节奏感,填色那种帧率在这里是浪费)。
    @ViewBuilder
    private func gapDotsRow(_ marker: LyricsGapMarker, id: String) -> some View {
        if playback.currentGapIndex == marker.index {
            // .animation(minimumInterval:paused:) 替代 .periodic(2026-08-19):节奏一样是
            // 0.5s 一档,但暂停时把表停掉 —— 暂停在间奏中时圆点亮度本来就定格(闭包里的
            // pausedPositionMs 兜底),表继续走只是白跑。
            TimelineView(.animation(minimumInterval: 0.5, paused: !playback.isPlayingNow)) { context in
                // 跟逐字填色同一套时间基准:外推位置 + 当前歌词偏移(间奏窗口是歌词
                // 原始时间轴,见 LyricsGapMarker 注释)。暂停时 anchor 为 nil,退回
                // 冻结位置,点就停在当下的亮度上。
                let pos = (playback.anchor?.extrapolatedPositionMs()
                    ?? playback.pausedPositionMs ?? marker.startMs)
                    + PlaybackCoordinator.shared.currentLyricsOffsetMs
                let span = max(1, marker.endMs - marker.startMs)
                let progress = min(1, max(0, Double(pos - marker.startMs) / Double(span)))
                HStack(spacing: lyricFontSize * 0.3) {
                    ForEach(0 ..< 3, id: \.self) { i in
                        Circle()
                            .fill(primaryTextColor)
                            .frame(width: lyricFontSize * 0.32, height: lyricFontSize * 0.32)
                            // 第 i 颗在间奏进行到 i/3 之后点亮,亮度平滑爬升。
                            .opacity(0.22 + 0.78 * min(1, max(0, progress * 3 - Double(i))))
                    }
                }
                // 亮度变化按 0.5s 步进到货,补一段柔和过渡就是"呼吸"。
                .animation(.easeInOut(duration: 0.45), value: Int(progress * 24))
            }
            .frame(height: lyricFontSize * 0.5)
            .id(id)
            .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: .leading)))
        }
    }

    // Apple Music 歌词页的景深:当前行完全清晰,其余行统一压到低不透明度、并随距离
    // 加重高斯模糊——非当前行之间的不透明度差异很小(0.50 → 0.35 缓降),远近感主要靠
    // 模糊量区分。nil(还没播到第一句)整页轻虚化,保持可读。

    // 距离越远、高斯模糊越重——1.1pt/行、封顶 4pt。2026-08-04 第一版按 1.6pt/行封顶
    // 6pt,用户对照 AM 同曲截图反馈"太糊了,后面几行都失真了"——AM 最远的可见行仍然
    // 认得出字形(模糊半径约为字号的 12~14%,6pt/28pt 是 21%),照它调轻。SwiftUI 的
    // .blur() 本身就是可动画属性,复用调用点已有的 .animation(value: distance)。

    private var hasArtworkBackground: Bool { playback.artworkData != nil }

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
        // 铺 PlaybackCoordinator 预烘焙的模糊图(2026-08-19 性能审计,与灵动岛同一根因的
        // 第二份烘焙,参数见 windowBlurredArtworkImage 声明处):原来这里挂
        // `.saturation(1.5).blur(radius: 72, opaque: true)` 活滤镜,~2040px 画布上播放期
        // 因逐字填色/滚动几乎每帧重合成、GPU 反复重跑大半径模糊。烘焙源已是
        // highResArtworkImage ?? artworkImage(高清替代优先的口径在数据层保持)。
        //
        // 压黑 22% 仍在视图层 —— 这一档是拿两类封面跟 AM 逐像素取样校准出来的(橙色饱和
        // 封面 raw B 0.72→AM 0.58、浅色封面 0.63→0.50,都精确等于压 22% 黑;自适应遮罩
        // 试过被否,AM 对同源封面就是固定一档,网页端才需要 canvas 自适应,两边故意不同,
        // 见 index.html computeArtScrim() 注释)。
        if let nsImage = playback.windowBlurredArtworkImage {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .overlay(Color.black.opacity(0.22))
                .clipped()
                // 换歌/高清替代到货都会产出新的烘焙图实例(NSImage 指针比较),一条过渡
                // 覆盖原来 artworkData 字节比较 + highRes 指针比较两条。
                .animation(.easeInOut(duration: 0.5), value: playback.windowBlurredArtworkImage)
        }
    }

    // 完全没有歌词内容 vs "这首歌还没解析完、collector 后台正在搜"共用同一个
    // allLines.isEmpty,含义不一样,判断条件跟 LyricsOverlayView.mainLine 里的同一个
    // 分支保持一致(playback.hasLyricsContent 的注释详见 LocalPlaybackSource)。文案复用
    // 已有的本地化字符串,不新造。
    // 广告/纯音乐两个分支必须排在"还在搜索中"前面,理由跟 LyricsOverlayView.mainLine
    // 一致,见 playback.isCurrentTrackAdBreak / isCurrentTrackInstrumental 定义处的注释。
    private var emptyStateSpec: (icon: String, text: String) {
        // 什么都没在放(播放列表放完/播放器退出)—— 这时候写"无歌词"是答非所问:不是这首歌
        // 没词,是压根没有"这首歌"。判据用曲名为空:停播时 LocalPlaybackSource 会把曲目信息
        // 一并清掉(见 clearIfWasPlaying),播放中/暂停中它一定非空。
        if playback.title.isEmpty { return ("music.note", L10n.t("没有在播放")) }
        if playback.isCurrentTrackAdBreak { return ("megaphone", L10n.t("广告中")) }
        if playback.isCurrentTrackInstrumental { return ("waveform", L10n.t("纯音乐")) }
        // 搜完确实没有 → 别再说"搜索中",理由见 playback.currentTrackHasNoLyrics。
        if playback.currentTrackHasNoLyrics { return ("text.badge.xmark", L10n.t("暂无歌词")) }
        // 断网:collector 什么都查不到,而"全空不写缓存"的守卫让 hasLyricsContent 永远
        // 是 false —— 不插这一档的话界面会一直显示"搜索歌词中…",而那句话在断网时永远
        // 不会有下文。排在"暂无歌词"之后:那是明确结论,比"此刻没网"更有信息量。
        if playback.collectorNetworkDown && !playback.hasLyricsContent {
            return ("wifi.slash", L10n.t("网络连接失败"))
        }
        if playback.isPlayingNow && !playback.hasLyricsContent { return ("magnifyingglass", L10n.t("搜索歌词中…")) }
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

    /// 这一行是不是把读音逐词标进正文了(标了就别再单独渲染一整行罗马音)。
}

// 一行歌词。
//
// 2026-08-14 从 LyricsWindowView 的几个 @ViewBuilder 方法里拆出来变成独立的 View struct,
// 起因是用户反馈"换行滚动时有卡顿/掉帧感"。用 sample 量到的现场:稳定播放期间主线程约
// 22% 的时间耗在 NSHostingView.layout → ViewGraphRootValueUpdater.render,栈里能看到
// ForEachChild.updateValue → lineView —— 也就是几十行歌词在跟着整页反复重建。
//
// 为什么原来会全表重建:LyricsWindowView 用 @ObservedObject 订阅了整个 PlaybackCoordinator
// (二十来个 @Published:封面、音量、播放模式、收藏状态、暂停位置…),其中任何一个变动都
// 会让整个 body 重算;方法形式的行视图没有独立身份,只能跟着一起重建。拆成 struct +
// Equatable 之后,只有输入真的变了的那几行才会重算 —— 换行时变的是当前行和它的邻居。
//
// Equatable 必须**手写**:行视图带 onTap/onHover 两个闭包参数,函数值永远不相等,
// SwiftUI 自带的结构化比较对带闭包的视图直接失效,只比较值输入才有意义。
private struct LyricsLineRow: View, Equatable {
    let item: LyricsWindowLine
    let distance: Int?
    let isActive: Bool
    let isHovered: Bool
    // 逐字填色的 TimelineView 用它决定要不要暂停。传值而不是在这里再订阅一次
    // PlaybackCoordinator —— 那样等于把刚拆掉的全量订阅又加回来。
    let isPlaying: Bool
    /// 当前行的填色是否已定格(2026-08-19,四个展示面同款行尾停表的本窗口版):传值给
    /// KaraokeLineText 停掉粗时钟 + isLive 判定 —— 非当前行恒 false(见调用点注释)。
    let fillSettled: Bool
    let fontSize: CGFloat
    let romaFontSize: CGFloat
    let translationFontSize: CGFloat
    let onArtwork: Bool
    let showRomanization: Bool
    let showTranslation: Bool
    let reduceMotion: Bool
    let displayScale: CGFloat
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    static func == (a: LyricsLineRow, b: LyricsLineRow) -> Bool {
        // item 只比 id:id 里带了曲目标识 + 行下标(见 LyricsWindowLine),同 id 必然同内容。
        a.item.id == b.item.id
            && a.distance == b.distance
            && a.isActive == b.isActive
            && a.isHovered == b.isHovered
            && a.isPlaying == b.isPlaying
            && a.fillSettled == b.fillSettled
            && a.fontSize == b.fontSize
            && a.romaFontSize == b.romaFontSize
            && a.translationFontSize == b.translationFontSize
            && a.onArtwork == b.onArtwork
            && a.showRomanization == b.showRomanization
            && a.showTranslation == b.showTranslation
            && a.reduceMotion == b.reduceMotion
            && a.displayScale == b.displayScale
    }

    private var secondaryTextColor: Color { onArtwork ? .white.opacity(0.6) : .secondary }

    /// 对唱歌词的左右分栏(见 LyricDuet)。
    ///
    /// nil = 这首歌没有演唱者标记(绝大多数歌),按这个窗口原本的排版走 —— 左对齐。
    private var side: LyricDuet.Side { item.line.side ?? .leading }

    private var alignment: Alignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var textAlignment: TextAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var rowAlignment: WrapLayout.RowAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var usesPerWordRomanization: Bool {
        isActive && showRomanization && item.line.wordGroups?.isEmpty == false
            && item.line.words != nil
    }

    // Apple Music 歌词页的景深:当前行完全清晰,其余行统一压到低不透明度、并随距离
    // 加重高斯模糊——非当前行之间的不透明度差异很小(0.50 → 0.35 缓降),远近感主要靠
    // 模糊量区分。nil(还没播到第一句)整页轻虚化,保持可读。
    private var lineOpacity: Double {
        guard let d = distance else { return 0.45 }
        if d == 0 { return 1 }
        return max(0.35, 0.55 - Double(d) * 0.05)
    }

    // 距离越远、高斯模糊越重——1.1pt/行、封顶 4pt。2026-08-04 第一版按 1.6pt/行封顶
    // 6pt,用户对照 AM 同曲截图反馈"太糊了,后面几行都失真了"——AM 最远的可见行仍然
    // 认得出字形(模糊半径约为字号的 12~14%,6pt/28pt 是 21%),照它调轻。SwiftUI 的
    // .blur() 本身就是可动画属性,复用调用点已有的 .animation(value: distance)。
    private var lineBlur: CGFloat {
        guard let d = distance else { return 2 }
        return min(CGFloat(d) * 1.1, 4)
    }

    var body: some View {
        VStack(alignment: alignment.horizontal, spacing: 6) {
            mainText
            // 罗马音在**下面**,跟 Apple Music 一致(原来在上面)。当前行如果分得出词组,
            // 读音已经逐词标进 mainText 里了,这里就不再重复一整行。
            if showRomanization, !usesPerWordRomanization, let roma = item.line.romanization {
                Text(roma)
                    .font(.system(size: romaFontSize, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
            }
            if showTranslation, let tr = item.line.translation {
                Text(tr)
                    .font(.system(size: translationFontSize, weight: .semibold))
                    .foregroundStyle(secondaryTextColor)
            }
        }
        // Apple Music 歌词是左对齐排版,2026-08-04 从居中改过来。对唱歌词按演唱者分左右
        // (2026-08-14),不带标记的歌 side 恒为 .leading,跟原来完全一致。
        .multilineTextAlignment(textAlignment)
        .frame(maxWidth: .infinity, alignment: alignment)
        .opacity(isHovered ? 1 : lineOpacity)
        // 模糊跟缩放一样受 reduceMotion 影响时直接关掉——虽然模糊本身不是"位移类"动效,
        // 但它是这套"聚焦感"视觉效果里跟缩放同一批的非必要装饰,减少动态效果的用户大概率
        // 也不想要这层模糊,统一用同一个开关关掉,不单独加一个新设置项。
        // 鼠标悬在哪一行,哪一行就恢复清晰 —— 跟 Apple Music 一样,让你能看清要跳去的是
        // 哪一句,再决定点不点。
        .blur(radius: (reduceMotion || isHovered) ? 0 : lineBlur)
        // 这里原来给当前行挂了 .scaleEffect(1.02)。删掉了 —— .scaleEffect 是**渲染后**
        // 的仿射变换:文字先按原字号栅格化,再整体拉大 1.02 倍,是个非整数倍重采样。在
        // Retina 上看不太出来,在 1x 外接屏上直接把**最该看清的那一行**糊掉:2026-08-10
        // 实测同一张截图里,当前行的字形边缘平均过渡宽度 1.48px,而同窗口里没做任何变换
        // 的左栏歌名只有 1.25px、歌手行 1.14px。
        //
        // 2% 的放大本来就几乎看不出来,而"当前行"的强调其实是另外三样在扛:满不透明度、
        // 零模糊、逐字填色。为了一个看不见的收益去糊掉正文,不划算。
        .animation(LyricsWindowView.lineTransition, value: distance)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        // 命中区要盖满整行(含左右空白),否则只有文字上才点得到
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var mainText: some View {
        // Apple Music 歌词页所有行同一字号同一字重(远近靠透明度+模糊区分,不靠字号),
        // 当前行的逐字填色也是"同色 35% → 全强度"的同色系渐变,不引入另一个强调色——
        // 2026-08-04 按截图一比一对照改过来(旧版是当前行 accentColor 30pt/其余 24pt)。
        // 有封面背景时这个"同色"是白色;没有封面时退回系统 .primary(白字在浅色外观的
        // 默认窗口背景上不可读,正确性优先),远近区分交给 lineOpacity。
        let base: Color = onArtwork ? .white : .primary
        if isActive, let words = item.line.words {
            KaraokeLineText(
                words: words,
                groups: showRomanization ? item.line.wordGroups : nil,
                base: base,
                isPlaying: isPlaying,
                fillSettled: fillSettled,
                fontSize: fontSize,
                romaFontSize: romaFontSize,
                reduceMotion: reduceMotion,
                displayScale: displayScale,
                rowAlignment: rowAlignment
            )
        } else {
            Text(item.line.plainText ?? "")
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(base)
        }
    }
}

// 当前行的逐字填色。
//
// 单独成 struct 的理由跟 LyricsLineRow 是同一个,但更硬:里面那个 TimelineView(.animation)
// 是**按渲染帧频**刷新的,写在整页视图的方法里,等于让整棵视图树每帧都被牵动一次。拆出来
// 之后逐帧失效只发生在这一行内部,列表其余几十行完全不参与。
private struct KaraokeLineText: View {
    let words: [SyncedLyricWord]
    let groups: [SyncedLyricWordGroup]?
    let base: Color
    let isPlaying: Bool
    /// 整行填色已定格(所有词/组越过过渡带,rise 也必然完成 —— rise 窗口 min(320, 词长)
    /// 早于 KaraokeFill.lineFillSettledMs 的阈值)。true 时粗时钟停表、isLive 全灭,
    /// 行尾/间奏/曲末不再 4Hz 重排版(2026-08-19;悬浮窗/灵动岛/面板同款停表)。
    /// ⚠️ 必须同时喂给 isLive:只停粗时钟的话 isLive 会冻结在 true,最后一个字的 30Hz
    /// 细时钟反而在整段间奏/outro 永动,比不停更糟(对抗核实抓出来的陷阱)。
    let fillSettled: Bool
    let fontSize: CGFloat
    let romaFontSize: CGFloat
    let reduceMotion: Bool
    let displayScale: CGFloat
    /// 对唱分栏:换行时行内也要跟着靠左/靠右/居中,否则右侧那句折下来的第二行会飘回左边。
    var rowAlignment: WrapLayout.RowAlignment = .leading

    /// 正在唱的那个字微微上浮 —— Apple Music 的逐字效果不只是填色,字本身会抬一下,
    /// 一行看下来像一道波沿着字往右走。
    ///
    /// 抬起来之后**保持**,直到这一行不再是当前行才整体落回(非当前行走纯文本分支,本来
    /// 就没有位移)。2026-08-10 先按"点头式"(抬一下再落回)做过一版,用户明确纠正过。
    ///
    /// 抬升过程用 sin(p·π/2):从 0 平滑升到 1、终点斜率为 0,停住时不会有"撞顶"感;
    /// 时长取固定 320ms(不超过这个字自己的时长,短音符不被拉长),跟音符按住多久无关。
    private static let riseWindowMs: Double = 320

    private func rise(_ w: SyncedLyricWord, atMs currentMs: Int) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let elapsed = Double(currentMs - w.startMs)
        guard elapsed > 0 else { return 0 } // 还没唱到这个字
        let window = min(Self.riseWindowMs, Double(max(1, w.durationMs)))
        let p = min(1, elapsed / window)
        // 抬到顶之后这个字会**停在那儿好几秒**。幅度收到最近的整数个**设备像素**:
        // 原来是 lyricFontSize * 0.07,28pt 下 = 1.96pt —— 在 1x 外接屏上就停在 1.96 个
        // 物理像素这种半吊子位置上,整行文字被垂直重采样、边缘一直糊着。
        let scale = max(1, displayScale)
        let amplitude = (fontSize * 0.07 * scale).rounded() / scale
        return -sin(p * .pi / 2) * amplitude
    }

    var body: some View {
        // ⚠️ 逐帧刷新的 TimelineView 挂在**每个字自己**身上,不是包住整行 —— 这是这个窗口
        // 最贵的一处开销,2026-08-14 用 sample 量出来的:
        //
        //   播放中:主线程 91.3% 忙,其中 67.4% 在 NSHostingView.layout,栈顶是
        //           LayoutEngineBox.sizeThatFits(WrapLayout 这个自定义 Layout)
        //   暂停后:2.4% 忙 —— TimelineView(.animation) 一停,开销整个消失
        //
        // 原因是原来 TimelineView 包在 WrapLayout **外面**:每一帧闭包重跑,整行的
        // `WrapLayout { ForEach(words) }` 就被重新构造一次,于是 Layout 协议的
        // sizeThatFits/placeSubviews 对**每一个字**重算一遍 —— 一秒 60~120 次。
        //
        // 而逐帧真正在变的只有两样:渐变填色的位置、以及字的上浮量(.offset,渲染期位移,
        // 不参与布局)。文字/字号/换行结果整行从头到尾都不变。把 TimelineView 下沉到叶子
        // 之后,WrapLayout 的子视图列表每帧都是同一份,布局不再被推翻,重算范围缩到单个
        // Text 的样式。
        //
        // ---- 2026-08-17 第二轮 ----
        //
        // 上面那次修对了"每帧重排版",但留下了另一半:一行十几个字 = 十几个各自独立、
        // **相位还互不对齐**的 30Hz 时钟,它们的并集几乎盖满每一个显示帧。再量一次
        // (歌词窗口开着、正在播放):主线程 85.8% 忙,调用链是
        //   NSDisplayCycleObserver → NSHostingView.layout() → ViewGraphRootValueUpdater
        //   .render → ViewGraph.beginNextUpdate → AG::Graph::value_set → propagate_dirty
        // ——beginNextUpdate 就是 TimelineView 的时钟在推进;画图(blur/CoreText/CGContext)
        // 加起来不到 1%。
        //
        // 关键观察:任一时刻**只有一个字在扫**。还没唱到的字填充恒为 0、已经唱过的恒为 1,
        // 都是静态的,却各自挂着一个满速时钟。所以这一层加一个 4Hz 的**粗时钟**,只用来
        // 判断每个字此刻是不是"正在扫"(以及给静态的字一个时间基准);只有正在扫的那个字
        // 才保留 30Hz 的细时钟。
        //
        // 粗时钟确实会让 WrapLayout 每秒重排 4 次(正是上面那段说的开销),但那是 4/120,
        // 换掉的是十几个满速时钟 —— 净赚。
        TimelineView(.animation(minimumInterval: Self.coarseInterval,
                                paused: !isPlaying || fillSettled)) { coarse in
            lineContent(coarseDate: coarse.date, coarseMs: currentMs(at: coarse.date))
        }
    }

    /// 粗时钟档位。0.25 秒足够判断"这个字是不是快到了/刚过去",而重排版的代价只有
    /// 满帧的 4/120。
    private static let coarseInterval: Double = 0.25

    /// 跟 KaraokeWordText 里用同一条公式(含歌词时间轴校准),否则"当前词判定"和"填色进度"
    /// 的时间基准会对不上。
    private func currentMs(at date: Date) -> Int {
        // ?? pausedPositionMs(2026-08-19 修):暂停时 anchor 被清成 nil、冻结位置在
        // pausedPositionMs —— 原来 `?? 0` 让暂停触发的那次重渲染把时间基准塌缩到 0,
        // 当前行所有已唱词硬跳回"未唱"态(35% 暗色+落回基线),整段暂停期保持错误画面。
        // 同文件 gapDotsRow 的时间基准一直是对的,这里对齐它。
        let coordinator = PlaybackCoordinator.shared
        return (coordinator.anchor?.extrapolatedPositionMs(now: date)
            ?? coordinator.pausedPositionMs ?? 0)
            + coordinator.currentLyricsOffsetMs
    }

    /// 这个字此刻要不要保留满速时钟。
    ///
    /// 窗口两头各放宽一档粗时钟 + 一点余量:粗时钟最长 0.25 秒才看一次,不放宽的话会
    /// 在字的开头漏掉最初几帧(表现是这个字"啪"地跳出一截填色而不是扫过去)。
    /// 末尾要把上浮那 320ms 也算进去 —— 填色满了之后字还在往上浮。
    private func isLive(_ w: SyncedLyricWord, atMs ms: Int) -> Bool {
        // 定格后一律不活(理由见 fillSettled 声明处的陷阱注释)。
        guard !fillSettled else { return false }
        let margin = Int(Self.coarseInterval * 1000) + 80
        let end = w.startMs + max(1, w.durationMs) + Int(Self.riseWindowMs)
        return ms >= w.startMs - margin && ms <= end + margin
    }

    /// WrapLayout 的内容身份(2026-08-20 性能审计):行文本/字号/罗马音形态都没变时,粗
    /// tick 的布局回合跳过整行 CoreText 重新测宽(见 WrapLayout.Cache 守卫注释)。这里的
    /// 字体是 .system(size:weight:.bold) 固定族,fontSize/romaFontSize 就是完整字体身份;
    /// 文本身份用 words 拼接(只有当前行走这条路,4Hz 一次,开销可忽略)。
    private var lineLayoutKey: AnyHashable {
        AnyHashable(WindowLineKey(
            text: words.map(\.text).joined(),
            hasGroups: groups?.isEmpty == false,
            fontSize: fontSize,
            romaFontSize: romaFontSize))
    }

    private struct WindowLineKey: Hashable {
        let text: String
        let hasGroups: Bool
        let fontSize: CGFloat
        let romaFontSize: CGFloat
    }

    @ViewBuilder
    private func lineContent(coarseDate: Date, coarseMs: Int) -> some View {
        WrapLayout(rowAlignment: rowAlignment, contentKey: lineLayoutKey) {
            if let groups, !groups.isEmpty {
                // 一组一列:上面这一组的字各自逐字填色,下面标这一组的读音,列宽取
                // 两者更宽的那个 —— 主文字的间距因此被读音撑开,跟 Apple 一样。
                ForEach(groups) { g in
                    // 组内左对齐:罗马音跟这一组的**第一个字**对齐,不是居中。
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            // indices 代替 Array(enumerated()):少一次每 tick 纯为当 id 的
                            // 数组物化(4Hz 粗时钟,顺手项)。
                            ForEach(g.words.indices, id: \.self) { i in
                                KaraokeWordText(word: g.words[i], base: base, isPlaying: isPlaying,
                                                isLive: isLive(g.words[i], atMs: coarseMs),
                                                staticDate: coarseDate,
                                                fontSize: fontSize, reduceMotion: reduceMotion,
                                                displayScale: displayScale)
                            }
                        }
                        if let roma = g.romanization {
                            // 读音按**整组**的进度填,不跟着组里单个字跳:拿整组的起止时间
                            // 造一个"伪字",复用同一套填色。
                            let romaWord = SyncedLyricWord(
                                text: roma, startMs: g.startMs,
                                durationMs: max(1, g.endMs - g.startMs))
                            KaraokeWordText(
                                word: romaWord,
                                base: base.opacity(0.75), isPlaying: isPlaying,
                                isLive: isLive(romaWord, atMs: coarseMs),
                                staticDate: coarseDate,
                                fontSize: romaFontSize, weight: .medium,
                                reduceMotion: reduceMotion, displayScale: displayScale,
                                rises: false // 读音不跟着抬,只有正文的字会浮起来
                            )
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 2)
                        }
                    }
                }
            } else {
                ForEach(words.indices, id: \.self) { i in
                    KaraokeWordText(word: words[i], base: base, isPlaying: isPlaying,
                                    isLive: isLive(words[i], atMs: coarseMs), staticDate: coarseDate,
                                    fontSize: fontSize, reduceMotion: reduceMotion,
                                    displayScale: displayScale)
                }
            }
        }
        .font(.system(size: fontSize, weight: .bold))
    }
}

/// 一个逐字填色的字(或一整组的罗马音)。自己挂 TimelineView,自己按帧算填色和上浮量。
///
/// 拆到这一层的理由见 KaraokeLineText.body 顶部那段实测记录:逐帧失效必须落在叶子上,
/// 落在容器上会把整行的自定义 Layout 每帧推翻重算。
private struct KaraokeWordText: View {
    let word: SyncedLyricWord
    let base: Color
    let isPlaying: Bool
    /// 这个字此刻是不是"正在被扫过"。false 就把满速时钟停掉 —— 还没唱到的字填充恒为 0、
    /// 唱过的恒为 1,都是静态画面,没有任何理由每秒醒 30 次(见 KaraokeLineText.body)。
    let isLive: Bool
    /// 时钟停着的时候拿它当时间基准。用**粗时钟**的时刻而不是被冻住的 context.date:
    /// 后者会停在这个字最后一次活跃的瞬间,一旦停早了,填色就会永远卡在 0.97 这种位置上。
    let staticDate: Date
    let fontSize: CGFloat
    var weight: Font.Weight = .bold
    let reduceMotion: Bool
    let displayScale: CGFloat
    var rises: Bool = true

    /// 抬升过程用 sin(p·π/2):从 0 平滑升到 1、终点斜率为 0,停住时不会有"撞顶"感;
    /// 时长取固定 320ms(不超过这个字自己的时长,短音符不被拉长)。抬起来之后**保持**,
    /// 直到这一行不再是当前行才整体落回(非当前行走纯文本分支,本来就没有位移)。
    private static let riseWindowMs: Double = 320

    private func rise(atMs currentMs: Int) -> CGFloat {
        guard rises, !reduceMotion else { return 0 }
        let elapsed = Double(currentMs - word.startMs)
        guard elapsed > 0 else { return 0 } // 还没唱到这个字
        let window = min(Self.riseWindowMs, Double(max(1, word.durationMs)))
        let p = min(1, elapsed / window)
        // 幅度收到最近的整数个**设备像素**:原来是字号 * 0.07,28pt 下 = 1.96pt —— 在 1x
        // 外接屏上就停在 1.96 个物理像素这种半吊子位置上,整行文字被垂直重采样、一直糊着。
        let scale = max(1, displayScale)
        let amplitude = (fontSize * 0.07 * scale).rounded() / scale
        return -sin(p * .pi / 2) * amplitude
    }

    var body: some View {
        // 刷新上限(30Hz)和它背后那次实测记在 WordKaraokeGradient.refreshInterval,
        // 三处逐字视图共用一份 —— 原来这个常量只有这里有,悬浮歌词和灵动岛因此漏掉了。
        // paused 多了一个 !isLive:没在扫的字不需要时钟(见 isLive 的注释)。整行十几个字
        // 里通常只有一个是活的,于是每秒的图形更新次数从"字数 × 30"降到"30"。
        TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                paused: !isPlaying || !isLive)) { context in
            // 直接读单例而不是 @ObservedObject:这个闭包本来就由 TimelineView 按帧驱动,
            // 不需要靠 Combine 通知触发;订阅了反而会把 PlaybackCoordinator 上那二十来个
            // @Published 的每一次变动都变成额外重算。
            let coordinator = PlaybackCoordinator.shared
            // 时钟停着时用粗时钟的时刻,理由见 staticDate。
            let date = isLive ? context.date : staticDate
            // 加上 currentLyricsOffsetMs,理由跟 LyricsOverlayView.mainLine 同一段注释 ——
            // 不加的话"当前词判定"和"填色进度"用的时间基准对不上,会填到一半卡住。
            // ?? pausedPositionMs:暂停基准兜底,理由见 KaraokeLineText.currentMs(2026-08-19)。
            let currentMs = (coordinator.anchor?.extrapolatedPositionMs(now: date)
                ?? coordinator.pausedPositionMs ?? 0)
                + coordinator.currentLyricsOffsetMs
            let fraction = WordKaraokeGradient.fillFraction(for: word, atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand
            Text(word.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(WordKaraokeGradient.gradient(
                    fg: base, left: fraction - band, right: fraction + band))
                // .offset 是渲染期位移,不参与布局 —— 字抬起来不会把整行的排版推歪。
                .offset(y: rise(atMs: currentMs))
        }
    }
}

// MARK: - 进度条(2026-08-19 性能审计拆出:瞬态自持,失效不击穿整窗)

private struct WindowProgressSection: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    let onArtwork: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 正在拖进度条时手指所在的比例(0~1);没在拖就是 nil。拖动期间进度条和时间文字都显示
    // 这个值而不是真实播放位置,松手才发 seek —— 见 progressBar 里的注释。
    // 用 @GestureState:手势被取消时会自动复位,不会像 @State 那样永久卡住(理由同上)。
    @GestureState private var scrubbingFraction: Double?
    // 进度条那一块的实际宽度,拖拽时换算比例用(见 progressBar 里为什么不用 GeometryReader 包)。
    @State private var scrubWidth: CGFloat = 0
    /// 光标是否停在进度条那一条上。跟灵动岛同一套反馈,只是这个窗口大一些、幅度可以稍大。
    @State private var hoveringScrubber = false
    /// 进度条真正画出来的进度。跟 fraction 分开存,是为了**自己决定什么时候补间**:
    /// 每秒一档的推进要补间(否则一跳一跳),而冷启动第一次赋值、以及窗口缩放引起的
    /// 宽度变化不能补间 —— 那正是"进度条从别的位置平移过来"的来源。
    @State private var shownFraction: Double = 0
    @State private var progressPrimed = false
    /// 进度条轨道粗细:悬停变粗、按住再粗一点。理由见 NotchLyricsView.scrubberHeight;
    /// 这个窗口没有灵动岛那种 40pt 的高度上限,所以幅度可以比它大 1pt。
    private var scrubberHeight: CGFloat {
        if scrubbingFraction != nil { return 7 }
        return hoveringScrubber ? 6 : 4
    }

    @ViewBuilder
    var body: some View {
        if let anchor {
            // 播放中:1 秒一档从锚点外推——4pt 高的进度条上,秒级步进配 .linear 补间在
            // 视觉上已经连续,不值得为它再挂一个逐帧刷新的 TimelineView(.animation)。
            TimelineView(.periodic(from: .now, by: 1)) { context in
                progressBar(
                    positionMs: anchor.extrapolatedPositionMs(now: context.date),
                    durationMs: anchor.durationMs,
                    // 播放中每过一墙钟秒,播放头前进多少毫秒(倍速播放时不是 1000)。
                    // 补间要用它把终点提前一秒,见 progressBar 里 onChange 的注释。
                    advancePerSecondMs: 1000 * anchor.rate)
            }
        } else if let paused = pausedPositionMs, let duration = durationMs, duration > 0 {
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

    private func progressBar(positionMs: Int, durationMs: Int, advancePerSecondMs: Double = 0) -> some View {
        // 拖动期间显示手指按住的位置,而不是真实播放位置——松手才真的发 seek。拖动中
        // 播放器还在按旧位置走,若这里显示真实位置,进度条会在手指底下往回跳。
        let shownMs = scrubbingFraction.map { Int($0 * Double(durationMs)) } ?? positionMs
        let fraction = durationMs > 0 ? min(1, max(0, Double(shownMs) / Double(durationMs))) : 0
        return VStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(primaryTextColor.opacity(0.25))
                    Capsule().fill(primaryTextColor.opacity(0.85))
                        // 进度用 shownFraction(自己驱动)而不是 fraction,补间由下面的
                        // onChange 显式决定 —— 挂 .animation(_:value: fraction) 那一版有两个
                        // 症状:冷启动时 fraction 从 0 一步跳到真实进度,被补成"滑过去";
                        // 缩放窗口时 g.size.width 变了,而这次宽度变化恰好落在每秒一次的
                        // 动画事务里,于是整条也跟着平移。现在这两种情况都直接赋值、不补间。
                        //
                        // ⚠️ 2026-08-17:这里原来是 `.frame(width: g.size.width * shownFraction)`,
                        // 也就是让**布局属性**跟着每秒一次的线性补间走 —— 补间是按显示帧
                        // 插值的,于是每一帧都要把整个 NSHostingView 重新布局一次。实测
                        // (歌词窗口开着、正在播放)这一条就吃掉了主线程的一大半:
                        //   双列(有这条进度条)61.4% 忙 / 单列(窄窗,播放器面板整块不显示)9.4% 忙
                        // 改成整条满宽 + 渲染期横向缩放:scaleEffect 不参与布局,补间只落在
                        // 变换矩阵上。
                        //
                        // 视觉上等价:条高只有 scrubberHeight(≈4pt),胶囊两端的圆头半径是
                        // 2pt,横向缩放会把圆头压成 x 半径 2f pt 的椭圆 —— 在 4pt 高、2x 屏
                        // 上这点差别看不出来。下限从 `max(4, …)` 换算成等效的缩放下限,
                        // 进度为 0 时仍留 4pt 的一小截,不会缩没。
                        .frame(width: max(4, g.size.width))
                        .scaleEffect(
                            x: g.size.width > 0
                                ? min(1, max(4 / g.size.width, shownFraction)) : 1,
                            y: 1, anchor: .leading)
                }
            }
            .frame(height: scrubberHeight)
            // reduceMotion 下仍然变粗(功能反馈,不是装饰),只是不补间。
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7),
                       value: scrubberHeight)
            .onHover { hoveringScrubber = $0 }
            .onAppear {
                shownFraction = fraction
                // 第一次渲染之后才允许补间:开窗那一下的赋值必须是瞬时的。
                DispatchQueue.main.async { progressPrimed = true }
            }
            .onChange(of: fraction) { _, f in
                let smooth = progressPrimed && !reduceMotion && scrubbingFraction == nil
                if smooth {
                    // 正常推进:1 秒一档,配 .linear 补间在视觉上就是连续的。
                    //
                    // ⚠️ 补间的终点必须是**一秒之后**的位置,不是刚算出来的这个当前位置。
                    // 2026-08-10 用户报"进度比 Apple Music 慢不到 1 秒",根因就在这里:
                    // 原来是 `shownFraction = f`,即用一秒时间从上一档"走到"刚拿到的这一档,
                    // 于是走到位的那一刻这个值已经旧了整整一秒 —— 稳态下 t+s 时刻条上显示的
                    // 是 pos(t-1+s),**恒定落后 1 秒**。这是把插值当外推用的经典错误:两档
                    // 采样之间做线性插值,画出来的永远是过去。
                    //
                    // 改成终点取 pos(t+1) 之后,[t, t+1] 这一秒里线性走过去,每一刻显示的
                    // 正好是 pos(t+s) —— 也就是当下的真实位置。
                    //
                    // 数据源本身不是问题:同一时刻实测 media-control 的 elapsedTimeNow 跟
                    // Apple Music 播放头只差 36~50ms,位置伺服的校正门槛也只有 0.15s。
                    let step = durationMs > 0 ? advancePerSecondMs / Double(durationMs) : 0
                    withAnimation(.linear(duration: 1)) { shownFraction = min(1, max(0, f + step)) }
                } else {
                    // 冷启动 / 拖动中 / 关了动效:直接到位。拖动时补间会让进度条追着
                    // 手指慢慢挪,手感发黏。
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { shownFraction = f }
                }
            }
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
                        // 只有这次手势的第一帧 state 才是 nil,拿它当"刚按下"的边沿信号
                        // 给一次触觉;放 onChanged 里会每帧都震。
                        if state == nil {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment, performanceTime: .now)
                        }
                        state = min(1, max(0, value.location.x / scrubWidth))
                    }
                    .onEnded { value in
                        guard durationMs > 0, scrubWidth > 0 else { return }
                        let f = min(1, max(0, value.location.x / scrubWidth))
                        PlaybackCoordinator.shared.seek(toMs: Int(f * Double(durationMs)))
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

    private var primaryTextColor: Color { onArtwork ? .white : .primary }
    private var secondaryTextColor: Color { onArtwork ? .white.opacity(0.6) : .secondary }
}

// MARK: - 音量胶囊(2026-08-19 性能审计拆出:soundVolume 只在这里订阅)

private struct WindowVolumeCapsule: View {
    let onArtwork: Bool
    @StateObject private var model = Model()

    /// 只订 soundVolume 的微型代理 —— 拖音量时的乐观发布(≈每帧一次)只失效这个
    /// ~92×16pt 的小胶囊,整窗 body 不再陪跑(WindowPlayback 故意不转发它)。
    @MainActor
    private final class Model: ObservableObject {
        @Published private(set) var soundVolume: Int?
        private var sub: AnyCancellable?
        init() {
            sub = PlaybackCoordinator.shared.$soundVolume.removeDuplicates()
                .sink { [weak self] in self?.soundVolume = $0 }
        }
    }

    private var capsuleIconColor: Color {
        onArtwork ? .white.opacity(0.9) : .primary.opacity(0.75)
    }
    private var hasArtworkBackground: Bool { onArtwork }

    /// 音量。调的是 **Music.app 自己的输出音量**(跟 Apple Music 那个滑杆同一个东西),
    /// 不是系统音量 —— 拖它不会影响别的 App 的声音。
    ///
    /// 跟"喜欢""播放模式"一样,只有 Apple Music 有这个概念,读不到就整个不显示(外面
    /// `if let volume = model.soundVolume` 那道判断)。
    ///
    /// 样式照着 Apple Music 那个玻璃胶囊做:左边一个静音开关、一条发丝分隔线、中间是
    /// **不带蓝色填充**的轨道加圆头滑块、右边一个跟着音量变的喇叭图标。系统 Slider 的
    /// 蓝色填充和小圆点在这里太"表单化",跟这扇窗口其余部分对不上。

    @ViewBuilder
    var body: some View {
        if let volume = model.soundVolume {
            HStack(spacing: 8) {
                Button {
                    PlaybackCoordinator.shared.toggleMute()
                } label: {
                    Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 11))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(volume == 0 ? L10n.t("取消静音") : L10n.t("静音"))
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: 14)
                volumeSlider(volume: volume)
                    .frame(width: 92, height: 16)
                Image(systemName: volumeLevelIcon(volume))
                    .font(.system(size: 11))
                    // 图标宽度随音量档位变化,固定住,不然整条控件会左右呼吸。
                    .frame(width: 16, alignment: .leading)
            }
            .foregroundStyle(capsuleIconColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .clearGlassCapsule(
                // 有封面背景时边缘走白色 —— 那一圈亮边正是"玻璃光泽"的来源;纯色底
                // (没有封面)下白边会显得脏,退回中性描边。
                rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
        }
    }

    private func volumeLevelIcon(_ v: Int) -> String {
        switch v {
        case 0: return "speaker.slash.fill"
        case 1...33: return "speaker.wave.1.fill"
        case 34...66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    /// 自绘滑杆。不用系统 Slider:那个的蓝色强调填充和小圆点是表单控件的样子,
    /// Apple Music 这个位置是"轨道 + 圆头滑块",而且已播部分只是比轨道稍亮一点。
    private func volumeSlider(volume: Int) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let f = min(1, max(0, Double(volume) / 100))
            // 滑块是**横向药丸**,不是圆点 —— 参考 Apple Music 那个控件,它明显比高要宽。
            let knob: CGFloat = 20
            let knobHeight: CGFloat = 13
            let travel = max(0, w - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.16)).frame(height: 4)
                Capsule().fill(Color.primary.opacity(0.45))
                    .frame(width: knob / 2 + travel * f, height: 4)
                Capsule()
                    .fill(Color.white)
                    .frame(width: knob, height: knobHeight)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: travel * f)
            }
            .frame(height: g.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 0:点一下就跳到那个位置,不用真的拖。
                // 换算时把滑块自身宽度扣掉,否则拖到最右也到不了 100。
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard travel > 0 else { return }
                        let x = min(travel, max(0, value.location.x - knob / 2))
                        PlaybackCoordinator.shared.setVolume(Int((x / travel * 100).rounded()))
                    }
            )
        }
    }
}
