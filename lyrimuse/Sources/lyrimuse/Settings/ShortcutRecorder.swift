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
    private var windowResignObserver: NSObjectProtocol?
    private var isRecording = false {
        didSet { refreshTitle() }
    }
    // 清除按钮(见下面 ShortcutRecorderContainerView)的显隐跟这个按钮的标题在
    // refreshTitle() 里同一时刻一起刷新——2026-07-30 曾经改成用 SwiftUI
    // @State + NotificationCenter 广播驱动清除按钮的显隐,结果在这个 Form
    // (.formStyle(.grouped) 在 macOS 上是拿 List 实现的,行会被复用)里触发
    // 了行视图被错误复用:实测坐实"打开歌词管理"往后几行的 NSButton 全部
    // 报出同一个(是前一行的)位置,点哪一行都可能点到别的快捷键上,原来已经
    // 录好的组合还被误清空。根源是这个文件最上面就选定的思路——纯 NSView
    // 命令式控件,不吃 SwiftUI 那套响应式重渲染——清除按钮也必须照这个思路
    // 做,不能引入任何 @State/Combine 订阅,否则又会把这条列表重新变得不稳定。
    weak var clearButton: NSButton?

    init(name: KeyboardShortcuts.Name) {
        self.shortcutName = name
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(handleClick)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let windowResignObserver { NotificationCenter.default.removeObserver(windowResignObserver) }
    }

    // 固定宽度——不同状态下的文案("点击录制"/"请按下快捷键…"/某个具体组合符号串)
    // 长度差异很大,不固定宽度的话这一列 7 行会随录制状态跳来跳去。
    override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        size.width = max(size.width, 150)
        return size
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        guard let window else { return }
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

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func stopRecording() {
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

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
        // Option/Control 中至少一个,或者本身是功能键/媒体键(系统自动带上
        // .function 这个 flag)。
        let requiredModifiers = modifiers.subtracting(.shift).intersection([.command, .option, .control])
        guard
            !requiredModifiers.isEmpty || modifiers.contains(.function),
            let shortcut = KeyboardShortcuts.Shortcut(event: event)
        else {
            NSSound.beep()
            return nil
        }

        // 冲突检查(2026-08-31 加,见 ShortcutConflict)。在这之前录一个被系统占用的组合
        // 会"录制成功"但永远不触发,两个动作绑同一组合也不会被拦。
        //
        // ⚠️ 顺序:先 stopRecording()(把本地事件监听摘掉)再弹窗。反过来的话是在事件
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
            title = L10n.t("点击录制")
            clearButton?.isHidden = true
        }
    }
}

// 库自带的 Recorder 已经录进一个快捷键后,右侧会带一个可点的"×"用来清除;这里的替代
// 实现(ShortcutRecorderButton)原来只在"点击进入录制状态后按 Delete/Backspace"这一步
// 隐藏手势里做了清除(见上面 handle(_:) 里那个分支),没有任何可见控件——2026-07-30
// 用户实测反馈"没有清空这种按钮，现在没办法移除",补一个同样位置的"×"按钮。跟录制
// 按钮放进同一个 NSStackView,由 refreshTitle() 统一决定显隐,不用 SwiftUI
// @State/NotificationCenter 驱动(见 ShortcutRecorderButton.clearButton 注释,这条
// 路线已经在这个 Form 里踩过"行被错误复用"的坑)。
private final class ShortcutRecorderContainerView: NSView {
    let recordButton: ShortcutRecorderButton

    init(name: KeyboardShortcuts.Name) {
        let recordButton = ShortcutRecorderButton(name: name)
        self.recordButton = recordButton

        let clearButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.t("清除快捷键"))!,
            target: recordButton,
            action: #selector(ShortcutRecorderButton.clearShortcut)
        )
        clearButton.isBordered = false
        clearButton.bezelStyle = .regularSquare
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.toolTip = L10n.t("清除快捷键")
        recordButton.clearButton = clearButton

        super.init(frame: .zero)

        // 录制按钮必须拒绝被拉伸——2026-07-30 用户实测反馈"点击录制"那颗胶囊被拉成了
        // 铺满整行的长条:这个容器在 Form(.formStyle(.grouped))的 LabeledContent
        // 尾部内容位里,SwiftUI 会为它提出一个远比按钮实际需要的宽度,而下面这层
        // NSStackView 原来把 leading/trailing 都钉死在容器边缘,容器多宽、stack 就被
        // 撑多宽,recordButton 是 stack 里唯一没有固定宽度的排列子视图,于是把多出来的
        // 空间全部吃成了自己的拉伸——只固定 trailing(贴住行的右边缘,视觉上跟以前
        // "点击录制"紧贴右侧同一个位置),leading 只做"不小于"的下限,再显式把
        // recordButton 的水平 hugging/压缩阻力都提到 required,双重保证它只会保持
        // 自己文字需要的宽度,不会被撑开。
        recordButton.setContentHuggingPriority(.required, for: .horizontal)
        recordButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // "×"排在录制按钮**前面**。放在后面(库自带 Recorder 的做法)时,只有已录过快捷键
        // 的那几行才多出这颗按钮,而 stack 的 trailing 钉在行右缘 —— 于是那几行的录制
        // 胶囊被"×"往左顶,跟没录过的行对不齐,一列胶囊左右参差(2026-08-13 用户实测反馈)。
        // 挪到前面之后,胶囊右缘永远贴着同一条线,"×"出现或消失只影响它自己左边那点空隙。
        let stack = NSStackView(views: [clearButton, recordButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),
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
