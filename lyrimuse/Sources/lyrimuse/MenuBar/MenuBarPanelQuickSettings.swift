import AppKit
import SwiftUI
import LyrimuseCore

// 菜单栏面板里「长按 / 右键某个圆钮块 → 原地展开它自己的设置」这一套(2026-08-19 用户提议)。
// 分三块:格子的鼠标路由(TileMouseRouter)、展开后那一小片设置(PanelQuickSettings)、
// 以及三种形态的界面元数据(LyricsSurface 扩展)。面板本体在 MenuBarPanel.swift。
//
// 收哪些项的判据:**这个形态自己的、调了立刻看得见的**旋钮。跨形态共用的(截屏时隐藏 /
// 暂停时隐藏,两个悬浮窗共用)和一次性设完就不动的(灵动岛显示在哪块屏)都不收 —— 前者
// 在两片快捷设置里各出现一次,改一处却动两个形态,面板这么小放不下解释;后者本来就该去
// 设置窗口。够不着的一律走底下那颗「全部设置…」,它会把设置窗口直接翻到对应那一段。

// MARK: - 三种形态的界面元数据

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
        // 「灵动岛歌词」而不是「灵动岛」(2026-08-19 用户要求):跟旁边两格
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

        /// ⚠️ tooltip 的热区必须在**知道自己多大之后**重装一次。
        ///
        /// 2026-08-19 用户连着两次报"悬停没提示",离屏跑出来的第二个原因(第一个见
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
            // ⚠️ 只拆**自己**装的那一个,绝不 `trackingAreas.forEach(removeTrackingArea)`。
            //
            // 2026-08-19 用户报"悬停没有 tooltip",离屏跑了一遍坐实:`NSView.toolTip` 不是
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
    let surface: LyricsSurface
    /// 头部那个开关**直接复用格子自己的动作闭包** —— 同一个开关在两处必须一模一样,尤其
    /// 菜单栏歌词那一个(它要先收面板再切,理由见 MenuBarPanelView.toggleAction)。
    let toggle: () -> Void
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
            Image(systemName: surface.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(surface.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(surface.panelTitle).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            // 开关的真值只从 AppSettings 读,set 一律转给 toggle() —— 那条闭包里才有资格
            // 碰窗口控制器。
            Toggle("", isOn: Binding(get: { surface.isEnabled }, set: { _ in toggle() }))
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
    }

    // MARK: 各形态自己的旋钮

    @ViewBuilder private var rows: some View {
        switch surface {
        case .overlay:
            sliderRow(L10n.t("字号"), value: $settings.fontSize, range: 14...36)
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
            // 「对齐方式」摆在宽度之后、锁定位置之前(2026-09-03 补):它跟字号/宽度同属
            // "看一眼再决定"的排版旋钮,而锁定位置是窗口行为,归到最后。
            alignmentRow(selection: $settings.overlayDuetAlignmentOverride,
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
        case .notch:
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
            // ⚠️ 区间走 `NotchEditorStage.usableWidthRangeOnCurrentScreen`,别在这里另写一份
            // 字面量。理由同悬浮歌词那根:一处能产生别处够不到的值,用户下次一动另一根滑杆就会
            // 被弹回去,表现是"我调好的宽度自己变了"。
            // 用 usable 而不是存储层的 `widthRange`:下界含这台机器的"耳朵下限",低于它的值
            // 拖了卡片也不动(2026-08-31)。step 仍然是 10:这根是兜底通路、旁边没有实时预览,
            // 粗一点反而好落值(编辑台那根是 2)。
            sliderRow(L10n.t("宽度"), value: Binding(
                get: { settings.notchContentWidth },
                set: { newValue in
                    settings.notchContentWidth = newValue
                    if settings.notchOverlayEnabled {
                        NotchLyricsWindowController.shared.applyContentWidthSetting()
                    }
                }
            ), range: NotchEditorStage.usableWidthRangeOnCurrentScreen, step: 10,
               displayValue: { NotchEditorStage.effectiveWidth(baseWidth: $0) })
            // 2026-09-03 补。⚠️ 这里**不跟着 `notchShowLyrics` 显隐**,跟设置页那一行不同:
            // 设置页里「显示歌词」就在它上一行,关掉时这一行消失,原因看得见;而这块面板里
            // 没有「显示歌词」这一项,跟着藏就成了"凭空少一行、看不出为什么"。关掉歌词的人
            // 本来也不会来点「灵动岛歌词」这个格子调排版,留着一个当下无效的旋钮,代价比
            // 一个无法解释的消失小。
            alignmentRow(selection: $settings.notchLyricsAlignment,
                         label: LyricsAlignmentSegmentedControl.label(for:))
        case .menuBar:
            row(L10n.t("宽度模式")) {
                Picker("", selection: $settings.menuBarLyricsWidthMode) {
                    Text(L10n.t("固定")).tag(MenuBarLyricsWidthMode.fixed)
                    // 跟设置页同一个标签 —— 两处必须同进同出,否则就成了"一条带警告、
                    // 一条不带"的两个入口。2026-09-01 设置页那边按用户要求去掉了 Beta
                    // 字样,这里跟着去掉(那次是 selftest 的"源码用了但 catalog 里没有的键"
                    // 守卫把这处漏改逮出来的 —— 光改设置页会让这里指向一个已删的词条)。
                    Text(L10n.t("自适应")).tag(MenuBarLyricsWidthMode.adaptive)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }
            sliderRow(L10n.t("最大宽度"), value: Binding(
                get: { Double(settings.menuBarLyricsWidth) },
                set: { settings.menuBarLyricsWidth = CGFloat(($0 / 10).rounded() * 10) }
            ), range: 80...600, step: 10)
            // 2026-09-03 补。⚠️ **只在固定宽度模式下出现**,判据跟设置页那一行一字不差
            // (`MenuBarLayoutRows` 里那个 `if`)——自适应模式下那一格的宽度就等于文字宽度,
            // 没有多余空间,三个选项画出来一模一样(完整理由见 `LyricsRestingAlignment` 头注)。
            // 这里跟着藏是**说得通**的:「宽度模式」就在上面两行,原因看得见 —— 跟灵动岛那条
            // 「不跟着 notchShowLyrics 藏」的取舍不矛盾,区别正在于原因看不看得见。
            if settings.menuBarLyricsWidthMode == .fixed {
                alignmentRow(selection: $settings.menuBarLyricsAlignment,
                             label: LyricsAlignmentSegmentedControl.label(for:))
            }
            // 这两项改的是菜单栏那一项占多宽,而这张面板正锚在那一项上 —— 面板开着期间
            // 状态栏项不许重建(见 MenuBarStatusItem.present 里的 panelIsOpen 分支),
            // 所以拖的时候菜单栏上不会当场变。明说一句,别让人以为拖了没反应。
            Text(L10n.t("收起面板后生效"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                // (2026-09-02 用户点名「没有意义,不好看」)。这一根尤其明显 —— 面板总宽
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

    /// 「对齐方式」行(2026-09-03)。三个形态各一行,枚举不同(悬浮歌词是四档的
    /// `OverlayDuetAlignmentOverride`,灵动岛/菜单栏是三档的 `LyricsRestingAlignment`),
    /// 所以泛型化 + 标签用闭包传 —— 标签本身**一定要用各自设置页那份 `label(for:)`**,
    /// 不在这里另写:控件里叫「左对齐」而这儿叫「左」就是同一个值的两种叫法(悬浮歌词那边
    /// 为这件事专门把 label 提成了 static func)。
    ///
    /// 标题直接复用既有词条「对齐方式」,不新造 —— 跟设置页一字不差,也省一条要翻译的串。
    ///
    /// ⚠️ 用 `.pickerStyle(.menu)` 下拉,**不用分段控件**,三个理由:
    ///   ① 这块面板总宽只有 296pt。四档标签(自动/居中/左对齐/右对齐)按设置页那份手搓控件的
    ///      每档 56pt 下限算就要 220pt 以上,加标题和行内边距直接超;
    ///   ② macOS 把 SwiftUI 的分段 Picker 桥接成 `NSSegmentedControl`,而它**按当前选中段的
    ///      文字重新量宽度** —— 选哪个控件就多宽(设置页为这件事修了三轮才改成手搓,见
    ///      `LyricsAlignmentSegmentedControl` 头注)。在一块定宽面板里那是会把整行挤变形的;
    ///   ③ 这个文件里已有的宽选项行(灵动岛「风格」)用的就是 `.menu`,同一套语言。
    private func alignmentRow<Value: Hashable & CaseIterable>(
        selection: Binding<Value>, label: @escaping (Value) -> String
    ) -> some View where Value.AllCases: RandomAccessCollection {
        row(L10n.t("对齐方式")) {
            Picker("", selection: selection) {
                ForEach(Value.allCases, id: \.self) { option in
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
            // 再顺手把那一页停在这个形态自己的分段上 —— 那边是 @AppStorage,直接写
            // UserDefaults 就行,窗口已经开着也会立刻跟着翻。
            UserDefaults.standard.set(surface.appearanceSectionRawValue,
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
