import AppKit
import Carbon.HIToolbox
import SwiftUI
import KeyboardShortcuts

// 替换 KeyboardShortcuts 库自带的 Recorder——库自带的 RecorderCocoa 是 NSSearchField
// 子类(真正的可编辑文本框),只要它是第一响应者,AppKit 就会把它接入系统的文字输入/
// 输入法(IME)管线;当前活跃输入法是第三方中文输入法(如微信输入法拼音)时,敲下的
// 按键组合会被输入法当成"正在拼词"拦截去合成候选字,根本到不了 RecorderCocoa 自己那个
// 判断"这是不是一个快捷键"的本地事件监听器——于是不管按什么组合,要么框里毫无反应,
// 要么冒出一个不相干的汉字候选字,快捷键永远录不进去。这是库本身(3.0.1)从未修过的
// 问题,升级解决不了。
//
// 参考 MASShortcut(另一个广泛使用的开源快捷键录制库)的做法:它的录制控件是纯
// NSView/NSButton,根本不是文本输入控件——NSResponder.inputContext 默认就是 nil,
// 系统输入法子系统只会盯着"当前第一响应者的 inputContext 是不是一个真的文字输入
// 上下文"来决定要不要接管按键,纯 NSButton 从架构上就没有这个入口,不需要额外
// "关掉输入法"这一步,天然对任何输入法免疫。这里照抄这个思路,而不是想办法在
// NSSearchField 上关闭输入法。
final class ShortcutRecorderButton: NSButton {
    private let shortcutName: KeyboardShortcuts.Name
    private var eventMonitor: Any?
    /// 录制中点了这颗按钮以外的地方就收尾:本地按键监视器管整个 App,不收的话去别的输入框打字,每个字都被吞掉、响一声。
    private var clickMonitor: Any?
    private var windowResignObserver: NSObjectProtocol?
    private var isRecording = false {
        didSet { refreshTitle() }
    }
    // 清除按钮(见下面 ShortcutRecorderContainerView)的显隐跟这个按钮的标题在
    // refreshTitle 里同一时刻一起刷新——曾经改成用 SwiftUI
    // @State + NotificationCenter 广播驱动清除按钮的显隐,结果在这个 Form
    // (.formStyle(.grouped) 在 macOS 上是拿 List 实现的,行会被复用)里触发
    // 了行视图被错误复用:"打开歌词管理"往后几行的 NSButton 全部
    // 报出同一个(是前一行的)位置,点哪一行都可能点到别的快捷键上,原来已经
    // 录好的组合还被误清空。根源是这个文件最上面就选定的思路——纯 NSView
    // 命令式控件,不吃 SwiftUI 那套响应式重渲染——清除按钮也必须照这个思路
    // 做,不能引入任何 @State/Combine 订阅,否则又会把这条列表重新变得不稳定。
    weak var clearButton: NSButton?
    private var isHovering = false {
        didSet { if oldValue != isHovering { needsDisplay = true } }
    }
    private var hoverArea: NSTrackingArea?

    init(name: KeyboardShortcuts.Name) {
        self.shortcutName = name
        super.init(frame: .zero)
        // 外观整个自己画(`draw(_:)`):没设是一圈细线 +「未设置」,指针压上去换成「点按录制」,
        // 已设是一颗胶囊里排着每个键的小键帽。`title` 照样维护,只给辅助功能读。
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(handleClick)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let windowResignObserver { NotificationCenter.default.removeObserver(windowResignObserver) }
    }

    // 宽度有下限——不同状态下的文案(「未设置」/「请按下快捷键…」/一串键帽)长度差异很大,
    // 不给下限的话一列录制框会随录制状态跳来跳去。快捷键页是两列排,下限不能再大,
    // 再大一列放不下「显示/隐藏灵动岛歌词」这类标题。
    static let minimumWidth: CGFloat = 112
    static let height: CGFloat = 24
    /// 已设时胶囊右端留给清除「×」的位置(「×」是容器里另一颗按钮,叠在这里)。
    static let clearSlot: CGFloat = 20

    override var intrinsicContentSize: CGSize {
        var width = Self.minimumWidth
        if !isRecording, let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) {
            width = max(width, Self.keycapsWidth(Self.keyTokens(shortcut)) + Self.clearSlot + 16)
        }
        return CGSize(width: width, height: Self.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// 一个组合拆成键帽:打头的修饰键符号各一颗,剩下的(主键,可能是「F1」「Space」这种多字符)一颗。
    static func keyTokens(_ shortcut: KeyboardShortcuts.Shortcut) -> [String] {
        var rest = Substring("\(shortcut)")
        var tokens: [String] = []
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            tokens.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { tokens.append(String(rest)) }
        return tokens
    }

    private static let keycapFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let keycapHeight: CGFloat = 17
    private static let keycapGap: CGFloat = 3

    private static func keycapWidths(_ tokens: [String]) -> [CGFloat] {
        tokens.map { max(keycapHeight, ($0 as NSString).size(withAttributes: [.font: keycapFont]).width + 10) }
    }

    private static func keycapsWidth(_ tokens: [String]) -> CGFloat {
        keycapWidths(tokens).reduce(0, +) + keycapGap * CGFloat(max(0, tokens.count - 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let accent = NSColor.controlAccentColor
        if isRecording {
            accent.withAlphaComponent(0.1).setFill()
            capsule.fill()
            accent.setStroke()
            capsule.lineWidth = 1.5
            capsule.stroke()
            drawCentered(L10n.t("请按下快捷键…"), color: accent, in: bounds)
        } else if let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            capsule.fill()
            NSColor.separatorColor.setStroke()
            capsule.lineWidth = 0.5
            capsule.stroke()
            var area = bounds
            area.size.width -= Self.clearSlot
            drawKeycaps(Self.keyTokens(shortcut), in: area)
        } else if isHovering {
            accent.withAlphaComponent(0.08).setFill()
            capsule.fill()
            accent.withAlphaComponent(0.55).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
            drawCentered(L10n.t("点按录制"), color: accent, in: bounds)
        } else {
            NSColor.separatorColor.setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
            drawCentered(L10n.t("未设置"), color: .tertiaryLabelColor, in: bounds)
        }
    }

    private func drawCentered(_ text: String, color: NSColor, in area: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2),
                                withAttributes: attrs)
    }

    private func drawKeycaps(_ tokens: [String], in area: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.keycapFont, .foregroundColor: NSColor.labelColor]
        let widths = Self.keycapWidths(tokens)
        var x = max(area.minX + 8, area.midX - Self.keycapsWidth(tokens) / 2)
        for (token, width) in zip(tokens, widths) {
            let cap = NSRect(x: x, y: area.midY - Self.keycapHeight / 2, width: width, height: Self.keycapHeight)
            let path = NSBezierPath(roundedRect: cap, xRadius: 4, yRadius: 4)
            NSColor.white.withAlphaComponent(dark ? 0.14 : 0.9).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            let size = (token as NSString).size(withAttributes: attrs)
            (token as NSString).draw(at: NSPoint(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2),
                                     withAttributes: attrs)
            x += width + Self.keycapGap
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        // 录到一半被移出窗口(切到别的设置页、搜索跳走):照样收尾。不收的话录制时挂上的「暂停全局快捷键」
        // 没人撤,所有快捷键一直失效到下一次完整录完或重启。
        guard let window else {
            stopRecording()
            return
        }
        // 录制到一半切走窗口(比如 Cmd+Tab 切到别的 App)不该让按钮一直卡在"请按下
        // 快捷键…"——回来时应该看到的是正常状态,不是一个假装还在监听、其实早就
        // 收不到按键的僵死状态。
        windowResignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
            self?.stopRecording()
        }
    }

    @objc private func handleClick() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    /// 正在录制的那一颗。同时只许一颗在录:点了 A 再点 B,两颗都显示「请按下快捷键…」,按下的组合只有一颗收得到,
    /// 另一颗就一直卡在录制态。
    private static weak var activeRecorder: ShortcutRecorderButton?

    private func startRecording() {
        if let other = Self.activeRecorder, other !== self { other.stopRecording() }
        Self.activeRecorder = self
        // 录制期间关掉全局快捷键(同 KeyboardShortcuts 库自带录制器的做法):不关的话按到已经分给别的动作的
        // 组合,那个动作会真的执行,而且 Carbon 热键可能把这次 keyDown 吞掉,下面的撞键提示就走不到。
        GlobalHotkeys.setPaused(true, for: .recording)
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // 点在自己身上交给 handleClick(再点一下 = 结束录制);点在别处收尾,事件照常放行。
            let inside = event.window === self.window
                && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            if !inside { self.stopRecording() }
            return event
        }
    }

    /// 可以不带修饰键单独录的键:F1–F35(同 KeyboardShortcuts 库的 `NSEvent.SpecialKey.isFunctionKey`,
    /// 那个是库内部的、这里用不到)。不能按 `.function` 标志判:方向键和导航键也带它。
    private static let functionKeys: Set<NSEvent.SpecialKey> = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18,
        .f19, .f20, .f21, .f22, .f23, .f24, .f25, .f26, .f27, .f28, .f29, .f30, .f31, .f32, .f33, .f34, .f35,
    ]

    private func stopRecording() {
        if Self.activeRecorder === self {
            Self.activeRecorder = nil
            GlobalHotkeys.setPaused(false, for: .recording)
        }
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // 口径同 KeyboardShortcuts 库(NSEvent.modifiers):去掉 capsLock / numericPad / function。
        // 方向键、Home/End、PageUp/PageDown、⌦ 都自带 .function(方向键还带 .numericPad),
        // 留着的话下面「没有修饰键」的判断对它们全都不成立 —— ⌦ 清不掉快捷键,单按 ← 也能录成全局热键。
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        if modifiers.isEmpty, Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return nil
        }

        if modifiers.isEmpty, Int(event.keyCode) == kVK_Tab {
            // 故意把事件原样放行——让 Tab 正常把焦点移到下一个控件,不吞掉它。
            stopRecording()
            return event
        }

        if modifiers.isEmpty,
           event.specialKey == .delete || event.specialKey == .deleteForward || event.specialKey == .backspace {
            KeyboardShortcuts.setShortcut(nil, for: shortcutName)
            stopRecording()
            return nil
        }

        // 跟库原本的规则一致:单独一个 Shift 不算数(没法用),必须搭配 Command/
        // Option/Control 中至少一个,或者本身是 F1–F35(见 functionKeys)。
        let requiredModifiers = modifiers.subtracting(.shift).intersection([.command, .option, .control])
        guard
            !requiredModifiers.isEmpty || event.specialKey.map(Self.functionKeys.contains) == true,
            let shortcut = KeyboardShortcuts.Shortcut(event: event)
        else {
            NSSound.beep()
            return nil
        }

        // 冲突检查(加,见 ShortcutConflict)。在这之前录一个被系统占用的组合
        // 会"录制成功"但永远不触发,两个动作绑同一组合也不会被拦。
        //
        // 顺序:先 stopRecording()(把本地事件监听摘掉)再弹窗。反过来的话是在事件
        // 监听闭包里起模态会话,重入。present 内部还会再推迟一个 runloop 回合,双重保证。
        if let conflict = ShortcutConflict.check(shortcut, event: event, recording: shortcutName) {
            let window = self.window
            stopRecording()
            ShortcutConflict.present(conflict, over: window)
            return nil
        }

        KeyboardShortcuts.setShortcut(shortcut, for: shortcutName)
        stopRecording()
        return nil
    }

    @objc func clearShortcut() {
        KeyboardShortcuts.setShortcut(nil, for: shortcutName)
        refreshTitle()
    }

    func refreshTitle() {
        if isRecording {
            title = L10n.t("请按下快捷键…")
            clearButton?.isHidden = true
        } else if let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) {
            title = "\(shortcut)"
            clearButton?.isHidden = false
        } else {
            title = L10n.t("点按录制")
            clearButton?.isHidden = true
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

// 已录进快捷键时胶囊右端那颗可点的"×",用来清除(录制态里按 Delete/Backspace 也能清,但那是隐藏手势)。
// 它是容器里叠在录制按钮右端的另一颗 NSButton,显隐由 refreshTitle() 统一决定,不用 SwiftUI
// @State/NotificationCenter 驱动(见 ShortcutRecorderButton.clearButton 注释)。
private final class ShortcutRecorderContainerView: NSView {
    let recordButton: ShortcutRecorderButton

    /// 「×」的图,各行共用一张。读屏标签挂在按钮上(跟着界面语言),图里不带。
    private static let clearSymbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))!

    init(name: KeyboardShortcuts.Name) {
        let recordButton = ShortcutRecorderButton(name: name)
        self.recordButton = recordButton

        // 不用 `NSButton(image:target:action:)`:它按默认的带边框样式 sizeToFit 一次,一颗约 1ms,快捷键页每次
        // 打开要建二十颗;尺寸反正由下面的约束钉成 14×14(14 章决策 112)。
        let clearButton = NSButton(frame: .zero)
        clearButton.isBordered = false
        clearButton.bezelStyle = .regularSquare
        clearButton.image = Self.clearSymbol
        clearButton.imagePosition = .imageOnly
        clearButton.target = recordButton
        clearButton.action = #selector(ShortcutRecorderButton.clearShortcut)
        clearButton.setAccessibilityLabel(L10n.t("清除快捷键"))
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.toolTip = L10n.t("清除快捷键")
        recordButton.clearButton = clearButton

        super.init(frame: .zero)

        // 录制按钮必须拒绝被拉伸:SwiftUI 给这个容器的宽度常常远比按钮需要的宽,只钉 trailing
        // (贴住行的右缘,一列胶囊右缘对齐),leading 只做"不小于"的下限,再把录制按钮的水平
        // hugging/压缩阻力提到 required。「×」叠在胶囊里面,出现或消失都不改胶囊的位置。
        recordButton.setContentHuggingPriority(.required, for: .horizontal)
        recordButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recordButton)
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            recordButton.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            recordButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            recordButton.topAnchor.constraint(equalTo: topAnchor),
            recordButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            clearButton.trailingAnchor.constraint(equalTo: recordButton.trailingAnchor, constant: -5),
            clearButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 14),
            clearButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        recordButton.refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    let name: KeyboardShortcuts.Name

    func makeNSView(context: Context) -> ShortcutRecorderContainerView {
        ShortcutRecorderContainerView(name: name)
    }

    func updateNSView(_ nsView: ShortcutRecorderContainerView, context: Context) {
        nsView.recordButton.refreshTitle()
    }
}

/// 快捷键录制控件——外观/调用方式跟 KeyboardShortcuts.Recorder 一致(标题 + name:),
/// 只是底层换成不吃输入法的 NSButton 实现,见上面 ShortcutRecorderButton 的注释。
struct ShortcutRecorder: View {
    private let title: String
    private let name: KeyboardShortcuts.Name

    init(_ title: String, name: KeyboardShortcuts.Name) {
        self.title = title
        self.name = name
    }

    var body: some View {
        LabeledContent(title) {
            ShortcutRecorderRepresentable(name: name)
        }
    }
}

/// 只有录制按钮、不带标签的版本。给"标题已经由外层行自己画了"的场合用(见
/// SettingsDesignSystem.swift 的 SettingsRow)——直接把上面那个带 LabeledContent 的版本
/// 套 .labelsHidden() 也能藏掉文字,但 LabeledContent 在 Form 之外的布局行为不好预期
/// (它仍然会参与"标签列对齐"那套逻辑),不如直接暴露里面的控件本体。
struct ShortcutRecorderControl: View {
    let name: KeyboardShortcuts.Name

    var body: some View {
        ShortcutRecorderRepresentable(name: name)
    }
}
