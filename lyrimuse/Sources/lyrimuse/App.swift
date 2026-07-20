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
        // 固定尺寸的一次性向导,不需要用户手动拖拽调整——.windowResizability(.contentSize)
        // 让窗口尺寸完全跟着 OnboardingView 自己声明的 .frame(width:height:) 走。
        Window(L10n.t("欢迎使用 Lyrimuse"), id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
    }
}
