import SwiftUI

@main
struct LyrimuseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // 只为了让"歌词管理"这个 Window 的标题在手动切换语言时跟着重新解析——App.body
    // 原来不观察任何东西,加了才会在 appLanguage 变化时重新构造 Scene 树。
    @ObservedObject private var languageSettings = AppSettings.shared

    var body: some Scene {
        // 用 content:label: 形式而不是固定标题+图标——状态栏显示当前歌词这个设置项
        // 开着时,label 要能动态换成歌词文字(见 MenuBarLabel)。
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarLabel()
        }
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
