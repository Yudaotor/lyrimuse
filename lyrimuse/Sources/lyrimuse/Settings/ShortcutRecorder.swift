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

        KeyboardShortcuts.setShortcut(shortcut, for: shortcutName)
        stopRecording()
        return nil
    }

    func refreshTitle() {
        if isRecording {
            title = L10n.t("请按下快捷键…")
        } else if let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) {
            title = "\(shortcut)"
        } else {
            title = L10n.t("点击录制")
        }
    }
}

private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    let name: KeyboardShortcuts.Name

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        ShortcutRecorderButton(name: name)
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.refreshTitle()
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
