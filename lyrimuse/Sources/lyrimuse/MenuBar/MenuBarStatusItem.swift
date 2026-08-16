import AppKit
import Combine
import LyrimuseCore

// 状态栏兜底图标——正式 App 图标(音符+三条歌词横线)的简笔剪影版,不是系统 SF Symbol。
// 不能直接把正式图标(带渐变背景/高光/阴影)缩小塞进状态栏——那样会糊成一团色块。
// 状态栏图标用纯剪影(`isTemplate = true`),系统会自动按明暗/悬停状态重新上色,不需要
// 分别做浅色/深色两份。这份 PNG(Resources/MenuBarIconTemplate.png)是照同一比例重新
// 画的矢量线稿,不是从正式图标里抠像素抠出来的——正式图标背景是浅粉/浅橙渐变,跟白色
// 符干很接近,直接阈值抠图边缘会发虚。
private let menuBarIconImage: NSImage = {
    // 用 Bundle.main 而不是 Bundle.module——SwiftPM 生成的 Bundle.module 访问器在别的
    // 机器上会直接 fatalError 崩溃(原因见 L10n.swift 顶部注释)。这份 PNG 由 build.sh
    // 直接拷进 Contents/Resources/。
    let image: NSImage = {
        guard let path = Bundle.main.path(forResource: "MenuBarIconTemplate", ofType: "png"),
              let image = NSImage(contentsOfFile: path) else {
            // 找不到就退回系统符号兜底,不让状态栏图标位置裸奔成空白——正常情况下这个
            // 分支不会走到,build.sh 已经把这份 PNG 拷进 Contents/Resources/ 了,跟
            // Localizable.strings 是同一套查找路径。
            return NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil) ?? NSImage()
        }
        return image
    }()
    image.isTemplate = true
    // 14×14 不是随手挑的:MenuBarExtra 时代这个图标是 SwiftUI 的
    // `.frame(width: 14, height: 14)` + aspectRatio(.fit) 画出来的,这里照抄同一个尺寸,
    // 换掉 MenuBarExtra 之后状态栏图标的大小跟以前**一模一样**,用户看不出换过。
    image.size = NSSize(width: 14, height: 14)
    return image
}()

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

    private override init() { super.init() }

    /// AppDelegate 启动时调一次。
    func start() {
        guard !started else { return }
        started = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            // 退化路径(showStaticText)用按钮自己画文字时的字体,跟图层那条路画图用的是
            // 同一个 —— 两条路之间切换时字号不能跳。
            button.font = MenuBarMarqueeRenderer.font
            scrollingLabel.frame = button.bounds
            scrollingLabel.autoresizingMask = [.width, .height]
            scrollingLabel.isHidden = true
            button.addSubview(scrollingLabel)
        }
        item.menu = menuController.makeMenu(
            onHighlightChange: { [weak self] on in
                self?.scrollingLabel.setHighlighted(on)
            })

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
        settings.$menuBarLyricsWidth.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        coordinator.$isPlayingNow.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)

        refresh()
    }

    // MARK: - 决定现在该显示什么

    private func refresh() {
        guard let button = statusItem?.button else { return }
        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared
        let text = coordinator.currentLine?.plainText ?? ""
        guard settings.showLyricsInMenuBar, coordinator.isPlayingNow, !text.isEmpty else {
            showIcon(button)
            return
        }
        // "装得下还是要滚"这个判定跟设置页那条预览共用同一个函数,两边不可能漂 ——
        // 见 MenuBarMarqueeRenderer.Presentation。
        switch MenuBarMarqueeRenderer.presentation(
            for: text,
            windowWidth: settings.menuBarLyricsWidth,
            // 让长句子在换到下一句之前滚完,而不是永远按固定速度爬。
            dwellSeconds: coordinator.currentLineDwellSeconds
        ) {
        case .text(let visible):
            showStaticText(button, visible: visible, full: text)
        case .fixed(let lineText, let windowWidth, let pacing):
            showFixedWidth(button, text: lineText, windowWidth: windowWidth, pacing: pacing)
        }
    }

    /// 没开菜单栏歌词 / 没在播放 / 还没解析出这一句:固定图标。
    private func showIcon(_ button: NSStatusBarButton) {
        scrollingLabel.clear()
        button.image = menuBarIconImage
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = nil
        button.setAccessibilityLabel(L10n.t("Lyrimuse"))
    }

    /// 退化路径:宽度被设成 0 或更小,画不出格子,交给按钮自己画一段截断文字。
    /// 正常情况走不到这里(滑杆下限 80pt),留着是不想让极端配置变成一块空白。
    private func showStaticText(_ button: NSStatusBarButton, visible: String, full: String) {
        scrollingLabel.clear()
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
