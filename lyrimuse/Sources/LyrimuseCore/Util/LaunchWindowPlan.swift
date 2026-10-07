/// App 启动时自己要打开哪些窗口(14 章决策 62)。
///
/// 启动时会自己开的有三样:SwiftUI 在启动流程里按默认开出来的设置窗口、没走完的引导、上次退出时开着的歌词窗口
/// (07 章决策 72)。设置窗口不管开没开静默启动都当场关掉;「静默启动」开着时歌词窗口也不开,只留菜单栏图标,开机自启
/// 和手动打开一样对待。引导不受静默启动影响:首次设置没走完 App 用不起来,换电脑导入配置后重启接着走的也是它。
public struct LaunchWindowPlan: Equatable, Sendable {
    /// 设置窗口刚开出来时要不要当场关掉:启动流程还没走完、启动以来也没人要过设置窗口(深链、菜单),那这扇就是
    /// SwiftUI 按默认开的。别指望在 App 委托里实现 `applicationShouldOpenUntitledFile` 拦住它:SwiftUI 开这扇窗不问它。
    /// 场景上的 `defaultLaunchBehavior` 要 macOS 15 起,场景构建器又写不了 `#available` 的 else 分支。
    public static func dropsSettingsWindow(launching: Bool, requested: Bool) -> Bool {
        launching && !requested
    }

    /// 弹引导。
    public let showsOnboarding: Bool
    /// 照上次退出时的样子重开歌词窗口。
    public let reopensLyricsWindow: Bool
    /// 上次退出时歌词窗口开着、这次因为静默启动没开:把「开着」的记录改成没开,快捷键和下次启动才按实情判断。
    public let forgetsOpenLyricsWindow: Bool

    public init(silentLaunch: Bool, hasCompletedOnboarding: Bool, lyricsWindowWasOpen: Bool) {
        showsOnboarding = !hasCompletedOnboarding
        // 引导没走完时不开歌词窗口,别跟引导窗抢。
        let restorable = hasCompletedOnboarding && lyricsWindowWasOpen
        reopensLyricsWindow = restorable && !silentLaunch
        forgetsOpenLyricsWindow = restorable && silentLaunch
    }
}
