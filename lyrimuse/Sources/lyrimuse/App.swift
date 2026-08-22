import SwiftUI

@main
struct LyrimuseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // 只为了让"歌词管理"这个 Window 的标题在手动切换语言时跟着重新解析——App.body
    // 原来不观察任何东西,加了才会在 appLanguage 变化时重新构造 Scene 树。
    @ObservedObject private var languageSettings = AppSettings.shared

    var body: some Scene {
        // ⚠️ 这里**没有** MenuBarExtra。状态栏那一项 2026-08-16 改成自建 NSStatusItem 了
        // (MenuBar/MenuBarStatusItem.swift,由 AppDelegate 启动),因为 MenuBarExtra 是把
        // label 快照成一张图塞进状态栏按钮的,视图侧没有活的图层可以挂动画,滚动歌词只能
        // 每帧换图、顺滑度受主线程调度摆布 —— 详见 MenuBarScrollingLabel 顶部那段实测。
        //
        // 下面这几扇窗仍然是 SwiftUI 场景,**故意不一起搬走**:Settings 场景顺带提供了
        // "Lyrimuse ▸ 设置… ⌘," 那个主菜单项(在 Dock 中显示时才有主菜单),Window(id:)
        // 也白拿了位置/尺寸的自动存档。打开它们需要的环境 action 由一扇隐藏的锚点窗口
        // 捕获,见 MenuBar/MenuBarSceneActions.swift。
        Settings {
            SettingsView()
        }
        Window(L10n.t("歌词管理"), id: "lyrics-manager") {
            LyricsManagerView()
        }
        // 正经的标题栏窗口(不是悬浮歌词/灵动岛那种无边框浮层),展示完整歌词并跟随
        // 播放自动滚动——见 UI/LyricsWindowView.swift 顶部注释。不加
        // .windowResizability:跟"歌词管理"这个 Window 一样,让它跟着默认的
        // .automatic 走,开关/位置/尺寸全部交给 SwiftUI+macOS 的窗口自动存档机制,
        // 不需要额外持久化代码。
        Window(L10n.t("歌词窗口"), id: "lyrics-window") {
            // 原生全屏「坏着」的真根因(2026-08-21 探针实验坐实):**SwiftUI Window
            // 默认禁了全屏** —— 同一进程里纯 AppKit 探针窗绿键是 AXFullScreenButton、
            // 能真进全屏 Space,这扇 SwiftUI 窗却是 AXZoomButton。当年证伪的四个假设
            // (collectionBehavior/activationPolicy/LSUIElement/MenuBarExtra)都没碰到
            // 这层。
            // ⚠️ 这个修饰符在当前 SwiftUI 上**实测没生效**(挂上之后绿键仍是
            // AXZoomButton)——真正起效的是 AppKit 层对 collectionBehavior 的持续守护
            // (LyricsWindowController.enforceFullScreenCapability + didUpdate 观察,
            // SwiftUI 每个更新周期都会把标志复写掉,设一次不够)。修饰符仍保留:它是
            // 官方语义的表达,哪个版本 SwiftUI 修好了就能少一层对抗。
            if #available(macOS 15.0, *) {
                LyricsWindowView().windowFullScreenBehavior(.enabled)
            } else {
                LyricsWindowView()
            }
        }
        // AM 式顶部(2026-08-21 用户对照 AM 要求):无标题白条,背景一直通到窗顶、
        // 红绿灯悬浮在背景上。hiddenTitleBar = 标题栏透明 + 隐藏标题 + 内容全尺寸,
        // 一个修饰符抵三行 NSWindow 配置,而且在窗口显示前就生效(不闪白条)。
        // 伪全屏的进出逻辑相应简化:标题栏状态成了常驻,它只管红绿灯显隐和窗口帧
        // (见 LyricsWindowController.enter/exit)。
        .windowStyle(.hiddenTitleBar)
        // 固定尺寸的一次性向导,不需要用户手动拖拽调整——.windowResizability(.contentSize)
        // 让窗口尺寸完全跟着 OnboardingView 自己声明的 .frame(width:height:) 走。
        Window(L10n.t("欢迎使用 Lyrimuse"), id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
    }
}
