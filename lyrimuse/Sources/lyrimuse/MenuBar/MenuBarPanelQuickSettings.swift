import AppKit
import SwiftUI
import LyrimuseCore

// 菜单栏面板里「长按 / 右键某个圆钮块 → 原地展开它自己的设置」这一套(用户提议)。
// 分三块:格子的鼠标路由(TileMouseRouter)、展开后那一小片设置(PanelQuickSettings)、
// 以及能翻到背面的那几格的界面元数据(PanelQuickTarget + LyricsSurface 扩展)。
// 面板本体在 MenuBarPanel.swift。
//
// 收哪些项的判据:**这一格自己的、调了立刻看得见的**旋钮。跨形态共用的(截屏时隐藏 /
// 暂停时隐藏,两个悬浮窗共用)和一次性设完就不动的(灵动岛显示在哪块屏)都不收 —— 前者
// 在两片快捷设置里各出现一次,改一处却动两个形态,面板这么小放不下解释;后者本来就该去
// 设置窗口。够不着的一律走底下那颗「全部设置…」,它会把设置窗口直接翻到对应那一段。
//
// **别把 `AppColorPicker` / `FontFamilyPicker` 这类自带 `.popover` 的控件搬进来**(歌词窗口
// 那格的颜色和字体因此只在设置页)。这片设置住在一扇 `.transient` 的 NSPopover 里:嵌套的
// 子 popover 是**另一扇窗**,点它就是"点在面板外面",面板会当场被收掉,子 popover 跟着一起
// 消失 —— 表现是"点一下颜色块,整个面板就没了"。判据仍然成立(颜色改了立刻看得见),
// 挡住的是控件形态;够不着的走底栏那颗「全部设置…」,不在行尾另写一句灰字解释。

// MARK: - 能翻到背面的那几格

/// 面板里长按 / 右键能翻出快捷设置的格子:三个展示形态各一格,外加「歌词窗口」那一格。
///
/// **歌词窗口不是一个 `LyricsSurface`,别为了少包一层就往那个枚举里塞第四个 case。**
/// 那个枚举的契约是"三个可以同时开着、各有常驻开关的展示形态"(见它的头注):歌词窗口是
/// 一扇按需打开的真窗口,没有开关。塞进去的话 `isEnabled`、面板的 `toggleAction`、设置搜索
/// 目录的 `surface(_:)` 都要多长一个永远为假 / 永远走不到的分支,而 `appearanceSectionRawValue`
/// 那条"前三个 rawValue 是跨文件契约"的约定也会被稀释。
///
/// 反过来,「歌词显示」页第四段的分段取值是现成的(`SettingsSearchCatalog.lyricsWindowSectionValue`,
/// selftest 钉着它认不回任何形态),所以底栏那颗「全部设置…」照样翻得过去。
enum PanelQuickTarget: Hashable {
    case surface(LyricsSurface)
    case lyricsWindow
}

@MainActor
extension PanelQuickTarget {
    /// 跟格子上那枚符号是同一个来源 —— 格子和它"翻过来的背面"用两个符号就不像同一块了。
    var symbolName: String {
        switch self {
        case .surface(let surface): return surface.symbolName
        case .lyricsWindow: return "text.quote"
        }
    }

    var panelTitle: String {
        switch self {
        case .surface(let surface): return surface.panelTitle
        case .lyricsWindow: return L10n.t("歌词窗口")
        }
    }

    /// 头部那枚图标要不要点亮。歌词窗口没有"开着"这个常驻状态(它是一扇按需打开的窗),
    /// 恒为假 —— 跟它在钮块网格里那一格 `on: false` 同一个口径。
    var isEnabled: Bool {
        switch self {
        case .surface(let surface): return surface.isEnabled
        case .lyricsWindow: return false
        }
    }

    /// 「歌词显示」页里对应那一段的分段取值,底栏那颗「全部设置…」拿它翻页。
    var appearanceSectionValue: String {
        switch self {
        case .surface(let surface): return surface.appearanceSectionRawValue
        case .lyricsWindow: return SettingsSearchCatalog.lyricsWindowSectionValue
        }
    }
}

@MainActor
extension LyricsSurface {
    /// 跟设置页「歌词显示」里同一个形态用的是同一个符号,别各挑一个。
    var symbolName: String {
        switch self {
        case .overlay: return "captions.bubble"
        case .notch: return "rectangle.topthird.inset.filled"
        case .menuBar: return "menubar.rectangle"
        }
    }

    var panelTitle: String {
        switch self {
        case .overlay: return L10n.t("悬浮歌词")
        // 「灵动岛歌词」而不是「灵动岛」:跟旁边两格
        // (悬浮歌词/菜单栏歌词)统一成"载体 + 歌词",三兄弟读起来才是同一层的东西;
        // 而且"灵动岛"单独出现像在说那块硬件,不像在说一个可开关的展示形态。
        // 设置页那张总开关卡用的也是这个词条,现在两处一致。
        case .notch: return L10n.t("灵动岛歌词")
        case .menuBar: return L10n.t("菜单栏歌词")
        }
    }

    /// 只读 AppSettings —— 面板渲染路径不许碰两个悬浮窗控制器的 `.shared`
    /// (见 MenuBarPanelView 头注那条不变量)。
    var isEnabled: Bool {
        switch self {
        case .overlay: return AppSettings.shared.classicOverlayEnabled
        case .notch: return AppSettings.shared.notchOverlayEnabled
        case .menuBar: return AppSettings.shared.showLyricsInMenuBar
        }
    }
}

// MARK: - 圆钮块的鼠标路由

/// 短按 = 格子的主动作,长按 / 右键 = 弹出这个功能的快捷设置。顺手把悬停也接过来。
///
/// 为什么这一层是 AppKit 而不是 SwiftUI:
///   * 长按:Button 的 action 认的是"松手",长按到点再松手会把主动作也放一遍;要压住它就得
///     另加一个 @State,而"压住了没有"取决于 SwiftUI 的手势仲裁,说不准。判定本身交给
///     LyrimuseCore.TilePressState(纯逻辑、selftest 覆盖),这里只翻译事件。
///   * 右键:SwiftUI 只给 `.contextMenu`,而那必须是一棵菜单 —— 给不出"右键直接展开"。
///   * 悬停:格子上盖了一层 NSView 之后,底下 SwiftUI 的 `.onHover` 未必还收得到(它靠
///     hosting view 的 tracking area),两种交互状态由同一个视图给出更省心。
struct TileMouseRouter: NSViewRepresentable {
    /// 长按多久算长按。0.35s:比系统双击间隔(~0.5s)短一点,手感上"按住不放"就出来了,
    /// 又不至于正常点一下都误判成长按。
    var holdSeconds: TimeInterval = 0.35
    var onPrimary: () -> Void
    var onSecondary: () -> Void
    var onPressingChange: (Bool) -> Void
    var onHoverChange: (Bool) -> Void
    /// 直接设在这层 NSView 上,不用 SwiftUI 的 `.help()` —— tooltip 是"指针底下那个 NSView"
    /// 的属性,而这一层盖住了整格,底下那个 SwiftUI 视图的 tooltip 根本轮不到出场。
    var toolTip: String?

    func makeNSView(context: Context) -> RouterView {
        let view = RouterView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: RouterView, context: Context) { apply(to: view) }

    private func apply(to view: RouterView) {
        view.holdSeconds = holdSeconds
        view.onPrimary = onPrimary
        view.onSecondary = onSecondary
        view.onPressingChange = onPressingChange
        view.onHoverChange = onHoverChange
        view.toolTip = toolTip
    }

    final class RouterView: NSView {
        var holdSeconds: TimeInterval = 0.35
        var onPrimary: (() -> Void)?
        var onSecondary: (() -> Void)?
        var onPressingChange: ((Bool) -> Void)?
        var onHoverChange: ((Bool) -> Void)?

        private var press = TilePressState()
        private var holdWork: DispatchWorkItem?
        /// 自己装的那一个悬停 tracking area。**必须**记住它、拆的时候只拆它,理由见
        /// updateTrackingAreas。
        private var hoverArea: NSTrackingArea?

        /// 菜单栏面板弹出时**不激活 App**,第一次点击必须当真事件用掉,不能被系统拿去激活窗口。
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// tooltip 的热区必须在**知道自己多大之后**重装一次。
        ///
        /// 用户连着两次报"悬停没提示",离屏跑出来的第二个原因(第一个见
        /// updateTrackingAreas):`NSView.toolTip` 的 setter 会按**当时的 bounds**装一个
        /// tracking rect,而 SwiftUI 的 NSViewRepresentable 是 `makeNSView()` 先给一个
        /// **frame 为 .zero** 的视图、真实尺寸等布局完才设 —— 于是热区被钉死成 0×0,
        /// 鼠标永远进不去。实测这个 rect **不会**自己跟上:改 frame 不刷、
        /// updateTrackingAreas 也不刷(它没带 .inVisibleRect),**只有把 toolTip 置 nil
        /// 再设回来**才会按新 bounds 重装。
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            guard let text = toolTip else { return }
            toolTip = nil
            toolTip = text
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // 只拆**自己**装的那一个,绝不 `trackingAreas.forEach(removeTrackingArea)`。
            //
            // 现象是"悬停没有 tooltip",离屏跑了一遍坐实:`NSView.toolTip` 不是
            // 一个纯属性,setter 会往这个视图上装一个 **owner = NSToolTipManager** 的
            // tracking area(实测 options=4225 = mouseEnteredAndExited|activeAlways|一个
            // 内部位)。那句"全拆"把系统这一个也拆掉了,tooltip 从此再不出现;而且**补设一次
            // toolTip 也救不回来** —— 值没变,AppKit 直接跳过,tracking area 不会重装。
            //
            // (顺带排除了另一个看着更像的怀疑:accessory App 弹面板时不激活成前台,
            // 会不会 tooltip 本来就不显示?不会 —— 系统那个 tracking area 自己带
            // activeAlways,跟这里选它同一个理由。)
            if let hoverArea { removeTrackingArea(hoverArea) }
            // .activeAlways 而不是 .activeInActiveApp:这个 App 是 accessory、从不激活成
            // 前台,后者收不到任何悬停。.inVisibleRect 让 rect 交给系统跟着尺寸走。
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }

        override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

        override func mouseDown(with event: NSEvent) {
            // 不调 super:默认实现把事件交给 nextResponder,那就等于没接。
            dispatch(press.handle(.down))
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.dispatch(self.press.handle(.holdElapsed))
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds, execute: work)
        }

        override func mouseDragged(with event: NSEvent) {
            let inside = isInside(event)
            // 拖出格子先把计时器掐掉:状态机那边虽然也会拒掉晚到的 holdElapsed,但让一个
            // 已经没用的定时任务继续排着没有意义。
            if !inside { holdWork?.cancel() }
            dispatch(press.handle(inside ? .dragInside : .dragOutside))
        }

        override func mouseUp(with event: NSEvent) {
            holdWork?.cancel()
            // 松手位置在格子外就当作拖出去了 —— 正常情况 mouseDragged 已经报过一次,
            // 这里是"整个拖拽过程一个 dragged 事件都没来"时的兜底。
            if !isInside(event) { dispatch(press.handle(.dragOutside)) }
            dispatch(press.handle(.up))
        }

        override func rightMouseDown(with event: NSEvent) {
            holdWork?.cancel()
            dispatch(press.handle(.secondaryClick))
        }

        /// 右键按下已经消化掉了,对应的松开也就地吃掉,不再往 nextResponder 传。
        override func rightMouseUp(with event: NSEvent) {}

        private func isInside(_ event: NSEvent) -> Bool {
            bounds.contains(convert(event.locationInWindow, from: nil))
        }

        private func dispatch(_ action: TilePressState.Action) {
            onPressingChange?(press.isPressing)
            switch action {
            case .none: break
            case .primary: onPrimary?()
            case .secondary: onSecondary?()
            }
        }
    }
}

// MARK: - 展开后的快捷设置

/// 长按 / 右键某个圆钮块之后,顶掉钮块网格出现在「正在播放」卡下面的这一小片设置。
///
/// 视觉上刻意跟圆钮块同一套(同样的圆角、同样的 quaternarySystemFill 底):它是那个格子
/// "翻过来的背面",不是另开一扇窗。
struct PanelQuickSettings: View {
    let target: PanelQuickTarget
    /// 头部那颗控件**直接复用格子自己的动作闭包** —— 同一件事在两处必须一模一样,尤其
    /// 菜单栏歌词那一个(它要先收面板再切,理由见 MenuBarPanelView.toggleAction)。
    /// 三个形态那里它是总开关,歌词窗口那里是一颗「打开」——那一格本来就是"按一下开一扇窗"。
    let action: () -> Void
    let back: () -> Void
    let close: () -> Void

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            VStack(spacing: 7) { rows }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            Divider().opacity(0.6)
            footer
        }
        .background(Color(nsColor: .quaternarySystemFill),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 头部(返回 + 身份 + 这个形态的总开关)

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("返回"))
            Image(systemName: target.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(target.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(target.panelTitle).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            headerControl
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
    }

    /// 头部右边那一颗。三个形态是总开关;歌词窗口没有"开不开"可配(它是一扇按需打开的真窗口,
    /// 见 `AppearanceSettingsTab` 第四段的注释),换成一颗「打开」—— 这块设置调的全是那扇窗里
    /// 看得见的东西,"先把它开着"正该摆在最上面。
    @ViewBuilder private var headerControl: some View {
        switch target {
        case .surface(let surface):
            // 开关的真值只从 AppSettings 读,set 一律转给 action() —— 那条闭包里才有资格
            // 碰窗口控制器。
            Toggle("", isOn: Binding(get: { surface.isEnabled }, set: { _ in action() }))
                .labelsHidden()
                .controlSize(.mini)
        case .lyricsWindow:
            Button(action: action) {
                Text(L10n.t("打开")).font(.system(size: 11))
            }
            .controlSize(.small)
            .help(L10n.t("打开歌词窗口"))
        }
    }

    // MARK: 各形态自己的旋钮

    @ViewBuilder private var rows: some View {
        switch target {
        case .surface(.overlay):
            sliderRow(L10n.t("字号"), value: $settings.fontSize, range: AppSettings.overlayFontSizeRange)
            sliderRow(L10n.t("宽度"), value: Binding(
                get: { settings.overlayWidth },
                set: { newValue in
                    settings.overlayWidth = newValue
                    // 关着的时候不碰控制器:没必要为一个看不见的窗口把它建出来
                    // (窗口本身不存在时 setWidth 也只是空转)。重新打开时 setVisible
                    // 会按持久化值把几何一并应用上。
                    if settings.classicOverlayEnabled {
                        LyricsOverlayWindowController.shared.setWidth(newValue)
                    }
                }
            ), range: OverlayEditorStage.widthRange, step: 10)
            // 「对齐方式」摆在宽度之后、锁定位置之前:它跟字号/宽度同属
            // "看一眼再决定"的排版旋钮,而锁定位置是窗口行为,归到最后。
            alignmentRow(selection: $settings.overlayDuetAlignmentOverride,
                         options: Array(OverlayDuetAlignmentOverride.allCases),
                         label: OverlayAlignmentSegmentedControl.label(for:))
            toggleRow(L10n.t("锁定位置"),
                      help: L10n.t("解锁后鼠标点击会穿到桌面上；拖动方式见设置里的「拖动前先长按」"),
                      isOn: Binding(
                        get: { settings.lockPosition },
                        set: { newValue in
                            settings.lockPosition = newValue
                            if settings.classicOverlayEnabled {
                                LyricsOverlayWindowController.shared.setLocked(newValue)
                            }
                        }))
        case .surface(.notch):
            row(L10n.t("风格")) {
                Picker("", selection: $settings.notchCardStyle) {
                    ForEach(NotchCardStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            notchWidthRow
            // 「显示歌词」(搬进这块面板)。绑定直接写 AppSettings 就够,
            // 不用像宽度那样再喊一次控制器:`NotchLyricsWindowController` 自己订阅着
            // `$notchShowLyrics`(见那边的 showLyricsObserver),值一变卡片就重排。
            //
            // 位置刻意紧挨着下面的「对齐方式」,跟设置页同序:那两项都是"歌词行自己的事",
            // 而上面的风格/宽度说的是整张卡。
            toggleRow(L10n.t("显示歌词"), isOn: $settings.notchShowLyrics)
            // **跟着 `notchShowLyrics` 一起显隐**,跟设置页那一行拉齐了。
            // 在此之前这里是故意不藏的,理由是"这块面板里没有「显示歌词」这一项,跟着藏就成了
            // 凭空少一行、看不出为什么"——那条理由随着上面这个开关搬进来已经不成立:关掉的
            // 原因现在就在它正上方一行,看得见,再留一个当下无效的排版旋钮反而是噪音。
            // (设置页的判据在 `NotchBehaviorRows.body` 里的 `if item == .showLyrics,
            //  settings.notchShowLyrics`,两处必须同进同出。)
            if settings.notchShowLyrics {
                alignmentRow(selection: $settings.notchLyricsAlignment,
                             options: LyricsRestingAlignment.notchOptions,
                             label: LyricsAlignmentSegmentedControl.label(for:))
                // 「副行」「字号」补。两样都是这块面板建好**之后**才加进
                // 设置页的(副行 09-06、字号 09-09),当时没回补到这里 —— 不是判过不该收:两者都
                // 正好是头注那条判据说的"这个形态自己的、调了立刻看得见的旋钮"(切到「译文」当场
                // 多一行字、字号拖一格主行当场变大)。
                //
                // 顺序跟设置页「歌词行」组一致(显示歌词 → 对齐方式 → 副行),字号来自「字体」组、
                // 排在这一段最后 —— 上面的风格/宽度说的是整张卡,这四行是"歌词行自己的事"。
                secondaryLineRow(selection: $settings.notchSecondaryLine)
                // 灵动岛的字号跟「副行」**互不影响**,不要照搬菜单栏那边的「由副行决定」:
                // 副行与展开预览固定 11pt、不随主行字号变,这正是 Core `NotchLyricRowMetrics`
                // 刻意的取舍(那边注释:"不跟着放大是为了让主行的字号范围不依赖副行开没开")。
                sliderRow(L10n.t("字号"), value: Binding(
                    get: { settings.notchFontSize },
                    set: { newValue in
                        // 相等守卫同设置页那根:拖动中大量等值赋值会白白广播 + 重算三个派生字体。
                        guard newValue != settings.notchFontSize else { return }
                        settings.notchFontSize = newValue
                    }
                ), range: Self.notchFontSizeRange)
            }
        case .surface(.menuBar):
            row(L10n.t("宽度模式")) {
                SettingsSegmentedControlHashable(
                    selection: $settings.menuBarLyricsWidthMode,
                    options: MenuBarLyricsWidthMode.allCases,
                    label: { mode in
                        switch mode {
                        case .fixed: return L10n.t("固定")
                        case .adaptive: return L10n.t("自适应")
                        }
                    }
                )
                .controlSize(.small)
            }
            sliderRow(L10n.t("最大宽度"), value: Binding(
                get: { Double(settings.menuBarLyricsWidth) },
                set: { settings.menuBarLyricsWidth = CGFloat(($0 / 10).rounded() * 10) }
            ), range: 80...600, step: 10)
            // **只在固定宽度模式下出现**,判据跟设置页那一行一字不差
            // (`MenuBarLayoutRows` 里那个 `if`)——自适应模式下那一格的宽度就等于文字宽度,
            // 没有多余空间,三个选项画出来一模一样(完整理由见 `LyricsRestingAlignment` 头注)。
            // 这里跟着藏是**说得通**的:「宽度模式」就在上面两行,原因看得见 —— 灵动岛那条
            // 现在也是同一个道理(「显示歌词」搬进面板后,它的对齐方式也跟着藏了),
            // 三个形态在这件事上口径一致:**藏一个旋钮的前提是把"为什么"摆在它上面**。
            if settings.menuBarLyricsWidthMode == .fixed {
                alignmentRow(selection: $settings.menuBarLyricsAlignment,
                             options: LyricsRestingAlignment.menuBarOptions,
                             label: LyricsAlignmentSegmentedControl.label(for:))
            }
            // 「副行」「字号」补,同灵动岛那两行 —— 都是这块面板建好之后才加进设置页的
            // (副行 09-06、字号 09-03),漏回补。顺序跟设置页一致:「副行」属「布局」组(排几行是版面),
            // 「字号」属「字体」组,排在它下面正好让下面那句「由副行决定」的原因就在上一行。
            secondaryLineRow(selection: $settings.menuBarSecondaryLine)
            menuBarFontSizeRow
            // **这一整段四行**(宽度模式 / 最大宽度 / 副行 / 字号)改的都是菜单栏那一项占多宽,
            // 而这张面板正锚在那一项上 —— 面板开着期间状态栏项不许重建(见 MenuBarStatusItem.present
            // 里的 panelIsOpen 分支),所以拖的时候菜单栏上不会当场变。明说一句,别让人以为拖了没反应。
            // (从"这两项"扩到四项:新加的副行会把一行变两行、字号连行高一起改,
            //  两者都要重建槽位,跟宽度那两项踩的是同一个分支。)
            Text(L10n.t("收起面板后生效"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .lyricsWindow:
            // 「背景」两行跟设置页那一段同序、同判据:方向只在渐变档出现(纯色没有方向可言),
            // 跟菜单栏「对齐方式」是同一条规矩 —— **藏一个旋钮的前提是把"为什么"摆在它上面**,
            // 这里"为什么"就是正上方那一行「样式」。
            row(L10n.t("样式")) {
                Picker("", selection: $settings.lyricsWindowBackgroundMode) {
                    Text(L10n.t("跟随封面")).tag(LyricsWindowBackgroundMode.artwork)
                    Text(L10n.t("纯色")).tag(LyricsWindowBackgroundMode.solid)
                    Text(L10n.t("渐变")).tag(LyricsWindowBackgroundMode.gradient)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            if settings.lyricsWindowBackgroundMode == .gradient {
                row(L10n.t("方向")) {
                    Picker("", selection: $settings.lyricsWindowGradientDirection) {
                        Text(L10n.t("从上到下")).tag(LyricsWindowGradientDirection.vertical)
                        Text(L10n.t("从左到右")).tag(LyricsWindowGradientDirection.horizontal)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            // 动态封面**当场生效**:PlaybackCoordinator 订阅着这个值、拨一下就重算一次
            // (见那边 `settings.$motionCoverEnabled` 那条 sink),不用等下一首。说明文字跟设置页
            // 那一行同一句词条。
            toggleRow(L10n.t("动态封面"),
                      help: L10n.t("仅部分专辑提供；低电量或「减弱动态效果」时自动暂停"),
                      isOn: $settings.motionCoverEnabled)
        }
    }

    // MARK: 滑杆区间

    /// 灵动岛主行字号的可调区间。真源在 Core(`NotchLyricRowMetrics.mainFontSizeRange`,11…17,
    /// 上限是"最大字号下两行 + 间距仍塞得进 44pt 行高"倒推出来的),跟设置页「字体」组那根读同一份,
    /// 别在这里写字面量。提成计算属性是因为 Swift 的区间运算符必须跟左操作数同一行,行内写下来超长。
    private static var notchFontSizeRange: ClosedRange<Double> {
        Double(NotchLyricRowMetrics.mainFontSizeRange.lowerBound)
            ... Double(NotchLyricRowMetrics.mainFontSizeRange.upperBound)
    }

    /// 菜单栏歌词字号的可调区间(10…16,上限由状态栏项 22pt 高推出)。同上,真源在
    /// `MenuBarMarqueeRenderer.fontSizeRange`。
    private static var menuBarFontSizeRange: ClosedRange<Double> {
        Double(MenuBarMarqueeRenderer.fontSizeRange.lowerBound)
            ... Double(MenuBarMarqueeRenderer.fontSizeRange.upperBound)
    }

    // MARK: 行组件(比设置页那套 SettingsRow 紧得多 —— 这里总宽只有 296pt)

    private func row<Control: View>(_ title: String, help: String? = nil,
                                   @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            control()
        }
        .frame(minHeight: 20)
        .modifier(OptionalHelp(text: help))
    }

    /// displayValue:读数要显示的不是设定值本身时给它(灵动岛宽度用 —— 真实宽度还要过一道
    /// "两只耳朵放得下按钮"的下限,报设定值会跟编辑台里那根条上的数字对不上,见
    /// `NotchEditorStage.effectiveWidth`)。不给就报设定值,其余两根滑杆行为一字未变。
    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double = 1,
                           displayValue: ((Double) -> Double)? = nil) -> some View {
        row(title) {
            HStack(spacing: 6) {
                // SteppedSlider 而不是原生带步长的构造器:后者会在轨道下面画一排刻度点
                // (「没有意义,不好看」)。这一根尤其明显 —— 面板总宽
                // 只有 296pt、滑杆 128pt,宽度那两根的刻度密到直接连成一条实线。
                SteppedSlider(value: value, in: range, step: step)
                    .controlSize(.mini)
                    .frame(width: 128)
                Text(String(format: L10n.t("%@pt"),
                            "\(Int(displayValue?(value.wrappedValue) ?? value.wrappedValue))"))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private func toggleRow(_ title: String, help: String? = nil,
                           isOn: Binding<Bool>) -> some View {
        row(title, help: help) {
            Toggle("", isOn: isOn).labelsHidden().controlSize(.mini)
        }
    }

    /// 灵动岛「宽度」—— **一行双滑块**:左边那只是稳态宽(没 hover 时多宽),右边那只是展开宽。
    ///
    /// ~09-14 之间这里是**两根单滑块**(「宽度」+「展开宽度」各占一行)。合并的由头是
    /// 这块面板同日补进「副行」「字号」之后灵动岛那格要到 7 行、比上面的「正在播放」卡还高;但
    /// 合并本身是**对的**而不只是省地方 —— 用户当初提这个功能时说的就是"设置一个上限和一个下限",
    /// 编辑台那根早已是 `RangeSlider`,只有这块面板一直拆着两根,同一件事在两个
    /// 入口长成两副样子。合完之后形态一致,读数也跟编辑台同一个口径(两者相等时只报一个数)。
    ///
    /// 两只滑块**共用** `usableWidthRangeOnCurrentScreen`,不再碰
    /// `usableExpandedWidthRangeOnCurrentScreen`(那个是给单滑块入口用的,下界 = 稳态真实宽)——
    /// "展开不许比稳态窄"改由 `RangeSlider` 内部的 `NotchWidthRangeDrag` 管,跟编辑台同一条路。
    ///
    /// 落盘仍走 `NotchEditorStage.commitWidths`(三个写入口唯一的落盘路径),且跟合并前一样
    /// **拖动中就落**:编辑台推迟到松手是因为它要在拖动期间切预览 chrome 的展开态,这块面板
    /// 没有预览、不需要那套本地 @State。
    private var notchWidthRow: some View {
        row(L10n.t("宽度")) {
            HStack(spacing: 6) {
                RangeSlider(
                    lower: settings.notchContentWidth,
                    upper: settings.notchExpandedContentWidth,
                    range: NotchEditorStage.usableWidthRangeOnCurrentScreen,
                    // step 仍然是 10:这根是兜底通路、旁边没有实时预览,粗一点反而好落值
                    // (编辑台那根是 2)。
                    step: 10, tint: .accentColor,
                    lowerLabel: L10n.t("灵动岛宽度"), upperLabel: L10n.t("灵动岛展开宽度"),
                    valueText: { String(format: L10n.t("%@pt"), "\(Int($0))") },
                    onChange: { steady, expanded in
                        NotchEditorStage.commitWidths(steady: steady, expanded: expanded)
                    },
                    onEditingChanged: { _ in })
                    // 高度不能省:`RangeSlider` 内部是 GeometryReader + `.frame(maxHeight: .infinity)`,
                    // 不钉高度它会把这一行撑到父容器那么高。16pt 跟旁边几根 `.controlSize(.mini)`
                    // 的 `SteppedSlider` 一边高。
                    .frame(width: 128, height: 16)
                Text(notchWidthValueText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .trailing)
                    // 读数是两只滑块的镜像、不是第三个可读元素:它们各自带着 accessibilityValue,
                    // 都进无障碍树 VoiceOver 会把同一个值读两遍(同编辑台那根)。
                    .accessibilityHidden(true)
            }
        }
    }

    /// 双滑块那一行的读数:口径跟编辑台 `widthValueText` 一致 —— 报的是**真实**宽度(过了
    /// "两只耳朵放得下"那道下限,所以跟设定值可能不等),两者相等(展开不加宽)时只报一个数。
    private var notchWidthValueText: String {
        let steady = Int(NotchEditorStage.effectiveWidth(baseWidth: settings.notchContentWidth))
        let expanded = Int(NotchEditorStage.effectiveExpandedWidth(
            steadyBase: settings.notchContentWidth,
            expandedBase: settings.notchExpandedContentWidth))
        if expanded == steady {
            return String(format: L10n.t("%@pt"), "\(steady)")
        }
        return String(format: L10n.t("%@–%@pt"), "\(steady)", "\(expanded)")
    }

    /// 「副行」行。灵动岛与菜单栏共用同一个四选一枚举(`LyricSecondaryLine`)和
    /// 同一套显示名,只是各存各的键 —— 所以只传 Binding,不像 `alignmentRow` 那样泛型化。
    /// 控件同「风格」「对齐方式」用 `.menu` 下拉,三条理由见 `alignmentRow` 头注(296pt 放不下
    /// 四档分段、分段控件按选中项重量宽度、这个文件已有的宽选项行就是 `.menu`)。
    private func secondaryLineRow(selection: Binding<LyricSecondaryLine>) -> some View {
        row(L10n.t("副行")) {
            Picker("", selection: selection) {
                ForEach(LyricSecondaryLine.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// 菜单栏「字号」行。三件事跟设置页那行(`MenuBarFontSizeRow`)一字不差,别在
    /// 这里简化:
    ///   ① 读的是**生效字号**(`MenuBarMarqueeRenderer.font.pointSize`)而不是存储值 —— 存 0 表示
    ///      "跟随系统",直接把 0 喂给滑杆滑块会跑到最左边;
    ///   ② 拖回系统字号那一格时**存 0** 而不是那个数字,这样没有单独的「跟随系统」按钮也保住语义;
    ///   ③ 相等守卫不能省:拖动中每个鼠标事件都调一次 set,量化后大量等值赋值照样广播
    ///      objectWillChange,而菜单栏那边订阅着这个值、每次都会 refresh()。
    ///
    /// 副行开着时两行字号由行高推出(10 / 9pt)、滑杆翻了也没效果 —— 跟设置页一样**行留着、把滑杆
    /// 换成一句灰字「由副行决定」**,不整行隐藏(那会变成"字号去哪了")。原因就在它正上方一行,
    /// 符合这块面板"停用/隐藏一个旋钮的前提是把为什么摆在它上面"那条(见菜单栏「对齐方式」处)。
    @ViewBuilder private var menuBarFontSizeRow: some View {
        row(L10n.t("字号")) {
            if settings.menuBarSecondaryLine.showsSecondaryRow {
                Text(L10n.t("由副行决定"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    SteppedSlider(value: Binding(
                        get: { Double(MenuBarMarqueeRenderer.font.pointSize) },
                        set: { newValue in
                            let range = MenuBarMarqueeRenderer.fontSizeRange
                            let quantized = min(max(CGFloat(newValue.rounded()), range.lowerBound),
                                                range.upperBound)
                            let stored: CGFloat =
                                quantized == MenuBarMarqueeRenderer.systemPointSize ? 0 : quantized
                            guard stored != settings.menuBarLyricsFontSize else { return }
                            settings.menuBarLyricsFontSize = stored
                        }
                    ), in: Self.menuBarFontSizeRange, step: 1)
                        .controlSize(.mini)
                        .frame(width: 128)
                    Text(String(format: L10n.t("%@pt"),
                                "\(Int(MenuBarMarqueeRenderer.font.pointSize))"))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    /// 「对齐方式」行。三个形态各一行,枚举不同(悬浮歌词是四档的
    /// `OverlayDuetAlignmentOverride`,灵动岛/菜单栏共用 `LyricsRestingAlignment`——
    /// 它也有了「自动」,但只有灵动岛提供,所以选项列表由调用方**显式**传(`notchOptions` /
    /// `menuBarOptions`),不再在这里 `allCases`),所以泛型化 + 标签用闭包传 —— 标签本身**一定要用
    /// 各自设置页那份 `label(for:)`**,不在这里另写:控件里叫「左对齐」而这儿叫「左」就是同一个值的
    /// 两种叫法(悬浮歌词那边为这件事专门把 label 提成了 static func)。
    ///
    /// 标题直接复用既有词条「对齐方式」,不新造 —— 跟设置页一字不差,也省一条要翻译的串。
    ///
    /// 用 `.pickerStyle(.menu)` 下拉,**不用分段控件**,三个理由:
    ///   ① 这块面板总宽只有 296pt。四档标签(自动/居中/左对齐/右对齐)按设置页那份手搓控件的
    ///      每档 56pt 下限算就要 220pt 以上,加标题和行内边距直接超;
    ///   ② macOS 把 SwiftUI 的分段 Picker 桥接成 `NSSegmentedControl`,而它**按当前选中段的
    ///      文字重新量宽度** —— 选哪个控件就多宽(设置页为这件事修了三轮才改成手搓,见
    ///      `LyricsAlignmentSegmentedControl` 头注)。在一块定宽面板里那是会把整行挤变形的;
    ///   ③ 这个文件里已有的宽选项行(灵动岛「风格」)用的就是 `.menu`,同一套语言。
    private func alignmentRow<Value: Hashable>(
        selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String
    ) -> some View {
        row(L10n.t("对齐方式")) {
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    // MARK: 底栏

    private var footer: some View {
        Button {
            close()
            // 一次性信箱把设置窗口翻到「歌词显示」页(见 AppActions.pendingSettingsSelection),
            // 再顺手把那一页停在这一格自己的分段上 —— 那边是 @AppStorage,直接写
            // UserDefaults 就行,窗口已经开着也会立刻跟着翻。
            UserDefaults.standard.set(target.appearanceSectionValue,
                                      forKey: LyricsSurface.appearanceSectionStorageKey)
            AppActions.shared.requestSettings(.tab(.appearance))
            AppActions.shared.openSettings?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gearshape").font(.system(size: 10.5))
                Text(L10n.t("全部设置…")).font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 只有真给了说明才挂 tooltip —— `.help("")` 会留一条空 tooltip。
struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}
