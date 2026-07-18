import AppKit
import SwiftUI
import Combine
import DesktopLyricsCore

// 灵动岛/刘海样式悬浮歌词的窗口控制器——跟 LyricsOverlayWindowController 平行、完全
// 独立的第二套实现(两种样式互斥、各自独立的窗口控制器,不去改造经典那一套让它同时
// 兼容两种形态,那样的改造复杂度和风险都更高)。跟经典悬浮窗最大的行为差异:
// 1) 位置是算出来的、贴死在屏幕顶部居中,不支持用户拖拽(见 NotchLyricsWindow 里
//    isMovableByWindowBackground = false),所以没有"锁定位置"这个概念,也不需要
//    像经典悬浮窗那样持久化位置。
// 2) 收起态(默认)只是刘海本身(或无刘海屏幕的兜底胶囊)大小;展开态靠鼠标 hover
//    触发(NotchLyricsView 的 .onHover),展开态里播放控制按钮直接常驻,不用像经典
//    悬浮窗那样再叠一层"展开后还要再单独 hover 一次才出现控制按钮"——用户明确要求
//    "展开本身就已经代表用户正在看着它"。
//
// 极其重要的一条不变量,贯穿 AppDelegate/SettingsView/MenuBarMenu 三处外部路由代码:
// 这个类是 `static let shared`,真正引用到 `.shared` 才会执行 init() 建窗口——而
// init() 里订阅 PlaybackCoordinator.$isPlayingNow 的这个 Combine sink,在订阅的
// 一瞬间就会用当下的 isVisible(默认 true)触发一次 updateActualVisibility→
// orderFront。也就是说,只要有任何代码在"经典"样式生效期间不小心引用了
// `NotchLyricsWindowController.shared`(哪怕只是拿来读一下属性),这个没人要的
// 灵动岛胶囊就会凭空出现在屏幕顶部。三处外部路由代码因此都必须做到:只有在
// settings.overlayStyle == "notch" 的分支里才会出现 `.shared` 这个词——尤其
// MenuBarMenu.swift,不能像"同时持有两个控制器的 @ObservedObject"这种最直白的写法
// 那样两个都摸一遍。
@MainActor
final class NotchLyricsWindowController: NSWindowController, ObservableObject {
    static let shared = NotchLyricsWindowController()

    @Published private(set) var isVisible: Bool = true
    @Published private(set) var hideWhenNotPlaying: Bool = false
    // 收起/展开——由 NotchLyricsView 的 onHover 驱动,同时决定窗口实际尺寸
    // (recomputeGeometry)和视图内容(NotchLyricsView 读这个属性切换渲染)。
    @Published private(set) var isExpanded: Bool = false

    // 没有真刘海的屏幕(这台开发机就是——MacBook Air 全系不带刘海,只有 14"/16"
    // MacBook Pro 2021 起才有)退到的固定兜底尺寸:水平居中贴顶的小胶囊,不是"关掉
    // 整个功能",是换一套不依赖真刘海几何形状的兜底样式。
    private static let collapsedFallbackSize = NSSize(width: 180, height: 32)
    // 展开态要能放下一行歌词文字 + 3 个播放控制按钮的经验取值——这台机器没有真刘海,
    // 没法拿真机效果反复比对微调,先给一个看起来合理的尺寸,观感不够再改。
    private static let expandedSize = NSSize(width: 360, height: 44)

    private var isPlayingObserver: AnyCancellable?
    private var screenParamsObserver: NSObjectProtocol?

    convenience init() {
        // 初始 contentRect 只是占位——真正的尺寸/位置由下面 recomputeGeometry() 按
        // 当前屏幕几何重新算一遍并 setFrame,这里传什么都会被立刻覆盖掉。
        let panel = NotchLyricsWindow(contentRect: NSRect(origin: .zero, size: Self.collapsedFallbackSize))
        self.init(window: panel)

        let hosting = NSHostingView(rootView: NotchLyricsView(controller: self))
        hosting.frame = NSRect(origin: .zero, size: Self.collapsedFallbackSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        recomputeGeometry(animate: false)

        // 外接显示器插拔/切换分辨率时,"这台屏幕有没有真刘海"这个前提可能整个变了
        // (外接显示器基本不会有刘海)——重新算一遍,思路照抄经典悬浮窗
        // LyricsOverlayWindowController.restoredOrigin() 里"配置可能变了、需要重新
        // 夹回可见区域"那段既有处理。系统触发的几何变化不需要过渡动画,直接跳变。
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recomputeGeometry(animate: false) }
        }

        // 跟 LyricsOverlayWindowController 同一个坑同一个修法:sink 闭包里必须用参数
        // 里收到的 isPlaying,不能在闭包内另外去读 PlaybackCoordinator.shared.
        // isPlayingNow 这个存储属性——@Published 的 willSet 在真正写入新值*之前*就
        // 已经发布,这个时间点读存储属性拿到的是上一次的旧值,细节见
        // LyricsOverlayWindowController.swift 同一处注释,不重复展开。
        isPlayingObserver = PlaybackCoordinator.shared.$isPlayingNow.sink { [weak self] isPlaying in
            self?.updateActualVisibility(isPlayingNow: isPlaying)
        }
    }

    deinit {
        if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingNow)
    }

    // 跟经典悬浮窗共用同一个"暂停/无播放时隐藏"设置项(AppSettings.hideWhenNotPlaying),
    // 不新增独立开关——两种样式各自独立调用这个方法应用同一个设置值。
    func setHideWhenNotPlaying(_ hide: Bool) {
        hideWhenNotPlaying = hide
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingNow)
    }

    // 跟经典悬浮窗共用同一个"截屏/录屏时隐藏"设置项(AppSettings.hideDuringScreenCapture),
    // 不新增独立开关——两种样式各自独立调用这个方法应用同一个设置值。
    func setHiddenFromCapture(_ hidden: Bool) {
        window?.sharingType = hidden ? .none : .readWrite
    }

    // NotchLyricsView 的 .onHover 调这个——不用 withAnimation 包一层,跟经典悬浮窗
    // LyricsOverlayWindowController.updateHeight() 一样直接用 NSWindow.setFrame
    // (animate:) 这个 AppKit 原生的窗口级动画,不是 SwiftUI 那套 transaction 动画。
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        recomputeGeometry(animate: true)
    }

    private func updateActualVisibility(isPlayingNow: Bool) {
        let shouldShow = isVisible && (!hideWhenNotPlaying || isPlayingNow)
        if shouldShow { window?.orderFront(nil) } else { window?.orderOut(nil) }
    }

    private struct NotchGeometry {
        let size: NSSize
        let centerX: CGFloat
    }

    // 用 safeAreaInsets.top 判断这台屏幕有没有真刘海(>0 即有),用
    // auxiliaryTopLeftArea/auxiliaryTopRightArea(macOS 12 起的 API,这个项目部署
    // 目标是 14,肯定能用)量出刘海本身的真实宽度、以及左右边界算出的真正中心点——
    // 不是简单假设刘海永远精确居中于整块屏幕,虽然实践中几乎总是如此。没有真刘海
    // (这台开发机肯定如此——MacBook Air 全系不带刘海)时退到固定尺寸的胶囊,水平
    // 居中于整块屏幕。
    private static func geometry(for screen: NSScreen) -> NotchGeometry {
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX {
            let width = rightArea.minX - leftArea.maxX
            let centerX = (leftArea.maxX + rightArea.minX) / 2
            return NotchGeometry(size: NSSize(width: width, height: notchHeight), centerX: centerX)
        }
        return NotchGeometry(size: collapsedFallbackSize, centerX: screen.frame.midX)
    }

    // 顶边固定贴在屏幕最顶端(screen.frame.maxY),展开态往下+左右对称撑开——跟真实
    // 灵动岛的动画方向一致,收起态的中心点(centerX)在展开前后保持不变,不会跑出
    // 屏幕。用 NSScreen.main(当前有键盘焦点/菜单栏所在的那块屏幕)而不是记忆某一块
    // 固定屏幕——多屏环境下,这跟"灵动岛只应该出现在当前主屏"这个直觉一致。
    private func recomputeGeometry(animate: Bool) {
        guard let window, let screen = NSScreen.main else { return }
        let geo = Self.geometry(for: screen)
        let size = isExpanded
            ? NSSize(width: max(geo.size.width, Self.expandedSize.width), height: max(geo.size.height, Self.expandedSize.height))
            : geo.size
        let frame = NSRect(
            x: geo.centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        window.setFrame(frame, display: true, animate: animate)
    }
}
