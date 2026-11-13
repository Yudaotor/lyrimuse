import AppKit

/// 让一扇窗的 styleMask 一直带着某几位:被摘掉就在下一拍补回。
///
/// SwiftUI `Settings` 场景的窗口,每次内容的最小 / 最大尺寸变了(`NSHostingView.updateConstraints` →
/// `AppKitWindowController.hostingView(_:didUpdateMinSize:maxSize:)`)都会重写 styleMask、摘掉 `.resizable`,
/// 所以只在挂进窗口时插一次留不住;场景上加 `.windowResizability(...)` 也改不了它。见 14 章决策 193。
///
/// 补回挪到下一拍,别在 KVO 回调里当场写:摘位发生在约束更新阶段,当场改 styleMask 等于在布局中途再改窗口。
/// 同一拍里被摘几次只补一次。
public final class WindowStyleMaskKeeper {
    public let required: NSWindow.StyleMask
    private var observation: NSKeyValueObservation?
    private weak var window: NSWindow?
    private var restorePending = false
    private let schedule: (@escaping () -> Void) -> Void

    /// `schedule` 决定补回在哪一拍执行,默认主队列下一拍。
    public init(required: NSWindow.StyleMask,
                schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.required = required
        self.schedule = schedule
    }

    /// 同一扇窗只挂一次;换了窗就改盯新的那扇。挂上时先插一次。
    public func attach(to window: NSWindow) {
        guard window !== self.window else { return }
        self.window = window
        window.styleMask.insert(required)
        observation = window.observe(\.styleMask) { [weak self] window, _ in
            self?.styleMaskChanged(window)
        }
    }

    private func styleMaskChanged(_ window: NSWindow) {
        guard !window.styleMask.isSuperset(of: required), !restorePending else { return }
        restorePending = true
        schedule { [weak self, weak window] in
            guard let self else { return }
            self.restorePending = false
            guard let window, window === self.window else { return }
            window.styleMask.insert(self.required)
        }
    }
}
