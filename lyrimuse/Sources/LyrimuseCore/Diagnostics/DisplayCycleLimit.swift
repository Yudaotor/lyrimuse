import Foundation

/// AppKit 一轮显示周期里窗口被要求重做「更新约束 / 布局」的次数有上限(窗口里的视图数 + 1)。超了 AppKit 先抛
/// `NSGenericException`(「…already had more Update Constraints in Window passes than there are views in the window」),
/// 再由显示周期自己的 `@catch` 接住:`NSWindowAssertWhenDisplayCycleLimitReached` 为真(新 SDK 编的 App 默认为真)时
/// 多给 5 轮后重抛、进程崩溃;为假时记一行「Future marking as needing … might be ignored」,这一轮余下的标记丢掉,下一轮照常。
///
/// App 入口在任何窗口布局之前登记成假:AppKit 第一次读到这个开关后就缓存住,之后再登记不生效。见 15 章决策 109。
///
/// 接住之前 AppKit 抛的那个异常经过异常预处理器(`SwallowedExceptionGuard`),从说明文字里认出是哪种 pass、哪个窗口类、
/// 窗口编号,交给 App 设的 `onLimitReached` 记进遥测(14 章决策 196)。
public enum DisplayCycleLimit {
    public static let assertKey = "NSWindowAssertWhenDisplayCycleLimitReached"
    /// AppKit 那句说明的开头(两种写法都以它开头:超过视图数 / 超过固定轮数)。
    public static let reasonPrefix = "The window has been marked as needing another "
    /// 上报的 pass 取值。
    public static let passes = ["update-constraints", "layout", "display", "other"]

    public struct Event: Equatable, Sendable {
        /// `passes` 里的一个。
        public let pass: String
        /// 窗口的类名(`SwiftUI.AppKitWindow`、`lyrimuse.MenuBarPanelWindow` 这类),只留字母、数字、`_ . $`,最长 80。
        public let windowClass: String
        public let windowNumber: Int?

        public init(pass: String, windowClass: String, windowNumber: Int?) {
            self.pass = pass
            self.windowClass = windowClass
            self.windowNumber = windowNumber
        }
    }

    /// App 设一次:每次超限在主队列上回调一次。
    nonisolated(unsafe) public static var onLimitReached: (@Sendable (Event) -> Void)?

    /// 说明文字形如「…needing another Update Constraints in Window pass, but … in the window. \n<SwiftUI.AppKitWindow: 0x…>
    /// 0x28735 (165685) {{x, y}, {w, h}} en」;不是这句返回 nil。
    public static func parse(reason: String) -> Event? {
        guard reason.hasPrefix(reasonPrefix) else { return nil }
        let passName = reason.dropFirst(reasonPrefix.count).components(separatedBy: " pass").first ?? ""
        let pass = passName.contains("Update Constraints") ? "update-constraints"
            : passName.contains("Layout") ? "layout" : passName.contains("Display") ? "display" : "other"
        let description = reason.components(separatedBy: "\n").last ?? ""
        var windowClass = ""
        if let open = description.firstIndex(of: "<"), let colon = description[open...].firstIndex(of: ":") {
            windowClass = String(description[description.index(after: open)..<colon])
        }
        windowClass = String(windowClass.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_.$".contains($0)) }.prefix(80))
        var number: Int?
        if let open = description.firstIndex(of: "("), let close = description[open...].firstIndex(of: ")") {
            number = Int(description[description.index(after: open)..<close])
        }
        return Event(pass: pass, windowClass: windowClass.isEmpty ? "unknown" : windowClass, windowNumber: number)
    }

    /// 异常预处理器里调(主线程、正在抛异常):只认说明文字,别的挪到主队列下一拍,不在 AppKit 的布局里做事。
    public static func noteThrown(reason: String?) {
        guard let reason, let event = parse(reason: reason), let handler = onLimitReached else { return }
        DispatchQueue.main.async { handler(event) }
    }

    /// 登记进注册域:用户或调试时用命令行参数 / `defaults write` 设了真值的照旧以他们的为准。
    public static func registerNonAsserting(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [assertKey: false])
    }
}
