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
//
// 真机(有物理刘海)实测坐实两个问题、这里改成常显、内容整体下移:
// 1) 最初"收起态空胶囊+hover 展开"的设计,真机上悬停才会显示,用户明确反馈"预期是
//    常显"——歌词类信息本来就需要随时可见,不该藏在 hover 后面,砍掉 hover 触发的
//    展开/收起这一层状态,永远渲染同一套内容。
// 2) 歌词文字这一行如果跟物理刘海本身占同一条 y 范围,会被刘海真实挡住一部分——物理
//    刘海是屏幕硬件层面真实不发光的区域,不是"渲染层级"问题,任何 App 都不可能把内容
//    "显示"在那个区域本身。真正可行的做法(参考 boring.notch/DynamicNotchKit 等真实
//    刘海companion 应用的通用做法):可读内容整体让到刘海下方那一条,刘海本身所在的
//    高度只留纯黑背景(视觉上跟物理刘海融为一体),不放任何文字/图标。
@MainActor
final class NotchLyricsWindowController: NSWindowController, ObservableObject {
    static let shared = NotchLyricsWindowController()

    @Published private(set) var isVisible: Bool = true
    @Published private(set) var hideWhenNotPlaying: Bool = false
    // 常显内容行(歌词)相对窗口顶部的偏移——正好等于刘海(或无刘海屏幕的兜底高度)
    // 本身的高度,这样歌词永远从刘海往下才开始画,不会被刘海真实挡住一部分。
    // NotchLyricsView 读这个属性给歌词行加 .padding(.top, contentTopInset)。
    @Published private(set) var contentTopInset: CGFloat = 32
    // 刘海本身的真实宽度(无真刘海时为 0)——播放控制按钮真机反馈要挪到刘海两侧
    // ("耳朵")那两条空间里,不能摆在刘海本身的 x 范围内,物理刘海是屏幕硬件层面真实
    // 不发光的区域,横向也会跟纵向一样把落在这个范围内的内容整个挡掉。NotchLyricsView
    // 读这个属性把顶部这一行让出中间 notchWidth 宽度的空当,按钮只放在左右两侧。
    @Published private(set) var notchWidth: CGFloat = 0

    // 没有真刘海的屏幕(比如 MacBook Air 全系不带刘海,只有 14"/16" MacBook Pro
    // 2021 起才有)退到的固定兜底高度:不是"关掉整个功能",是换一套不依赖真刘海几何
    // 形状的兜底样式,宽度沿用下面 contentSize 统一给的常显宽度。
    private static let fallbackNotchHeight: CGFloat = 32
    // 常显内容行(一行歌词 + 3 个播放控制按钮)的宽度/高度经验取值——窗口总高度 =
    // 刘海本身高度(或兜底高度)+ 这一行高度,让内容行完整落在刘海下方。
    private static let contentSize = NSSize(width: 360, height: 44)

    private var isPlayingObserver: AnyCancellable?
    private var screenParamsObserver: NSObjectProtocol?

    convenience init() {
        // 初始 contentRect 只是占位——真正的尺寸/位置由下面 recomputeGeometry() 按
        // 当前屏幕几何重新算一遍并 setFrame,这里传什么都会被立刻覆盖掉。
        let placeholder = NSSize(width: Self.contentSize.width, height: Self.fallbackNotchHeight + Self.contentSize.height)
        let panel = NotchLyricsWindow(contentRect: NSRect(origin: .zero, size: placeholder))
        self.init(window: panel)

        let hosting = NSHostingView(rootView: NotchLyricsView(controller: self))
        hosting.frame = NSRect(origin: .zero, size: placeholder)
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

    private func updateActualVisibility(isPlayingNow: Bool) {
        let shouldShow = isVisible && (!hideWhenNotPlaying || isPlayingNow)
        // orderFrontRegardless(),不是 orderFront(nil)——这个 App 是 .accessory 策略、
        // 从不激活成前台 App,参照的真实开源实现(NotchDrop/DynamicNotchKit)贴刘海用的
        // 都是这个,不看"当前是否是活跃 App"这个前提就把窗口调到最前。
        if shouldShow { window?.orderFrontRegardless() } else { window?.orderOut(nil) }
    }

    private struct NotchGeometry {
        // 刘海本身(或无刘海屏幕的兜底值)的高度——这一整条永远只留纯黑背景,不放
        // 任何文字/图标,常显内容行从这条高度往下才开始画,见 NotchLyricsView。
        let notchHeight: CGFloat
        let centerX: CGFloat
        // 刘海本身的真实宽度——无真刘海时为 0(没有需要横向避开的硬件区域,顶部这一行
        // 可以整条给按钮用)。
        let notchWidth: CGFloat
    }

    // 用 safeAreaInsets.top 判断这台屏幕有没有真刘海(>0 即有),用
    // auxiliaryTopLeftArea/auxiliaryTopRightArea(macOS 12 起的 API,这个项目部署
    // 目标是 14,肯定能用)量出刘海左右边界算出的真正中心点——不是简单假设刘海永远
    // 精确居中于整块屏幕,虽然实践中几乎总是如此。没有真刘海的屏幕退到固定兜底高度、
    // 水平居中于整块屏幕。
    private static func geometry(for screen: NSScreen) -> NotchGeometry {
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX {
            let centerX = (leftArea.maxX + rightArea.minX) / 2
            let notchWidth = rightArea.minX - leftArea.maxX
            return NotchGeometry(notchHeight: notchHeight, centerX: centerX, notchWidth: notchWidth)
        }
        return NotchGeometry(notchHeight: fallbackNotchHeight, centerX: screen.frame.midX, notchWidth: 0)
    }

    // 顶边固定贴在屏幕最顶端(screen.frame.maxY)、水平居中对齐刘海中心点、宽度固定
    // 为 contentSize.width、总高度 = 刘海高度 + 内容行高度——常显,不再有收起/展开
    // 两态,真机实测反馈"预期是常显"之后砍掉了 hover 触发的尺寸变化,这里也就不再
    // 需要 animate 参数所服务的那次过渡动画,只在外接显示器插拔等屏幕配置变化时重新
    // 算一遍。用 NSScreen.main(当前有键盘焦点/菜单栏所在的那块屏幕)而不是记忆某一块
    // 固定屏幕——多屏环境下,这跟"灵动岛只应该出现在当前主屏"这个直觉一致。
    private func recomputeGeometry(animate: Bool) {
        guard let window, let screen = NSScreen.main else { return }
        let geo = Self.geometry(for: screen)
        contentTopInset = geo.notchHeight
        notchWidth = geo.notchWidth
        let size = NSSize(width: Self.contentSize.width, height: geo.notchHeight + Self.contentSize.height)
        let frame = NSRect(
            x: geo.centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        window.setFrame(frame, display: true, animate: animate)
    }
}
