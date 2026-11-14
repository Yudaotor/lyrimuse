import Foundation

/// AppKit 一轮显示周期里窗口被要求重做「更新约束 / 布局」的次数有上限(窗口里的视图数 + 1)。超了 AppKit 先抛
/// `NSGenericException`(「…already had more Update Constraints in Window passes than there are views in the window」),
/// 再由显示周期自己的 `@catch` 接住:`NSWindowAssertWhenDisplayCycleLimitReached` 为真(新 SDK 编的 App 默认为真)时
/// 多给 5 轮后重抛、进程崩溃;为假时记一行「Future marking as needing … might be ignored」,这一轮余下的标记丢掉,下一轮照常。
///
/// App 入口在任何窗口布局之前登记成假:AppKit 第一次读到这个开关后就缓存住,之后再登记不生效。见 15 章决策 109。
public enum DisplayCycleLimit {
    public static let assertKey = "NSWindowAssertWhenDisplayCycleLimitReached"

    /// 登记进注册域:用户或调试时用命令行参数 / `defaults write` 设了真值的照旧以他们的为准。
    public static func registerNonAsserting(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [assertKey: false])
    }
}
