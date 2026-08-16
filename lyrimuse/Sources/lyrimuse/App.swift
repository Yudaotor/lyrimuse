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
            LyricsWindowView()
        }
        // 固定尺寸的一次性向导,不需要用户手动拖拽调整——.windowResizability(.contentSize)
        // 让窗口尺寸完全跟着 OnboardingView 自己声明的 .frame(width:height:) 走。
        Window(L10n.t("欢迎使用 Lyrimuse"), id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
    }
}
