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
            ), range: 420...1000, step: 10)
            toggleRow(L10n.t("锁定位置"),
                      help: L10n.t("解锁后鼠标点击会穿到桌面上；长按住悬浮歌词不放才能拖动它"),
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
            sliderRow(L10n.t("宽度"), value: Binding(
                get: { settings.notchContentWidth },
                set: { newValue in
                    settings.notchContentWidth = newValue
                    if settings.notchOverlayEnabled {
                        NotchLyricsWindowController.shared.applyContentWidthSetting()
                    }
                }
            ), range: 260...500, step: 10)
        case .menuBar:
            row(L10n.t("宽度模式")) {
                Picker("", selection: $settings.menuBarLyricsWidthMode) {
                    Text(L10n.t("固定")).tag(MenuBarLyricsWidthMode.fixed)
                    // 跟设置页同一个标签 —— 那边打了 Beta,这边不打就等于放了一条"没有警告
                    // 的入口"(见 SettingsView.menuBarCard)。
                    Text(L10n.t("自适应（Beta）")).tag(MenuBarLyricsWidthMode.adaptive)
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

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double = 1) -> some View {
        row(title) {
            HStack(spacing: 6) {
                Slider(value: value, in: range, step: step)
                    .controlSize(.mini)
                    .frame(width: 128)
                Text(String(format: L10n.t("%@pt"), "\(Int(value.wrappedValue))"))
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
