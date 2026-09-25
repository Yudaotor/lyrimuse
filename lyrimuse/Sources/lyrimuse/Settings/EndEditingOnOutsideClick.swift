import AppKit
import SwiftUI

/// 点到文本输入控件以外的地方时结束编辑,让输入框交出焦点。
///
/// AppKit 默认点空白处不会让输入框失焦,光标一直停在框里。这里给所在窗口挂一个本地
/// mouseDown 监听:正在编辑文本、而这次点击没落在任何文本输入控件上时,清掉第一响应者。
/// 事件本身原样放行,点到的按钮 / 开关 / 菜单照常响应。监听只认自己那扇窗的事件。
struct EndEditingOnOutsideClick: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ nsView: MonitorView, context: Context) {}

    final class MonitorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.endEditingIfOutside(event)
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func endEditingIfOutside(_ event: NSEvent) {
            guard let window, event.window === window,
                  let editor = window.firstResponder as? NSTextView, editor.isEditable,
                  let root = window.contentView?.superview ?? window.contentView
            else { return }
            let point = root.convert(event.locationInWindow, from: nil)
            if let hit = root.hitTest(point), Self.isInsideTextInput(hit) { return }
            window.makeFirstResponder(nil)
        }

        /// 点到的视图本身或它的某一层父视图是文本输入控件(单行框、密码框、搜索框、多行编辑区)。
        private static func isInsideTextInput(_ view: NSView) -> Bool {
            var current: NSView? = view
            while let candidate = current {
                if candidate is NSTextField || candidate is NSText { return true }
                current = candidate.superview
            }
            return false
        }
    }
}
