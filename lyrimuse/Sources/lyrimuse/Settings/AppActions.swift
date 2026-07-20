import Foundation

// `openSettings()`/`openWindow(id:)` 是 SwiftUI 的 @Environment action,只能在 View
// 的 body/修饰符链里访问——全局快捷键的回调(GlobalHotkeys.swift)不在任何 View
// 上下文里,没法直接调用。这个单例是两者之间的桥:在一个确定"整个 App 生命周期内
// 只会挂载一次"的 View 里(MenuBarLabel,见 MenuBarMenu.swift)捕获这两个 action,
// 存进这里;全局快捷键的回调通过这里间接调用。
@MainActor
final class AppActions {
    static let shared = AppActions()

    var openSettings: (() -> Void)?
    var openLyricsManager: (() -> Void)?
    var openOnboarding: (() -> Void)?

    private init() {}
}
