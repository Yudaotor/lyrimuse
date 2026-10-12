import AppKit

/// 开窗时激活不激活 App。各开窗入口(设置、歌词管理、歌词窗口、搜索歌词小窗、引导)一律走 `activateApp()`,
/// 不直接调 `NSApp.activate`。
///
/// 深链带 `background=1` 时(本机验证用,见 14 章决策 98):接下来一小段时间里不激活 App,
/// 窗口建好后 `orderFrontRegardless()` 摆到最前、不当 key —— 用户正在别的 App 里打字,键盘焦点不被抢走。做法同启动时
/// 重开歌词窗口(07 章决策 123):accessory 策略下 `openWindow` 不激活也会把窗口建出来,只是不会自己到前台。
@MainActor
enum WindowActivation {
    private static var backgroundUntil: Date?

    /// 「后台开窗」那一小段:开窗入口里的激活被跳过。足够覆盖开窗入口里的异步一拍,又不至于让之后用户自己点的开窗也不激活。
    private static let backgroundWindow: TimeInterval = 2

    static var isBackground: Bool {
        guard let until = backgroundUntil else { return false }
        return Date() < until
    }

    static func beginBackground() {
        backgroundUntil = Date().addingTimeInterval(backgroundWindow)
    }

    static func activateApp() {
        guard !isBackground else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 后台开窗之后把那扇窗摆到最前(不当 key)。窗口是 SwiftUI 场景现建的,要等一拍,隔 0.25 秒找一次、最多两秒。
    /// `identifier` 认 SwiftUI `Window(id:)` 的场景 id(窗口标识里含它)和设置窗口。
    static func surface(identifier: String, attempt: Int = 0) {
        if let match = NSApp.windows.first(where: {
            $0.identifier?.rawValue.localizedCaseInsensitiveContains(identifier) == true
        }) {
            match.orderFrontRegardless()
            if match.isVisible { return }
        }
        guard attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { surface(identifier: identifier, attempt: attempt + 1) }
    }
}
