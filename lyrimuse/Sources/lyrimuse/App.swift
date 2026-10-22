import SwiftUI

/// 入口在 `AppEntry`(StorageMigrationRunner.swift):先搬数据目录,再调这里的 `main()`。
struct LyrimuseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // 只为了让"歌词管理"这个 Window 的标题在手动切换语言时跟着重新解析——App.body
    // 原来不观察任何东西,加了才会在 appLanguage 变化时重新构造 Scene 树。
    @ObservedObject private var languageSettings: AppSettings

    init() {
        // 这是整个进程第一次碰 AppSettings.shared 的地方(比 applicationDidFinishLaunching 早):它的 init()
        // 末尾就按字体族名解析悬浮歌词 / 灵动岛的字体,用户导入的字体这时必须已经注册进 Core Text,否则静默
        // 落回系统字体、直到下次改字体设置才纠正(见 CustomFontStore 头注)。属性初值会在 init 体之前求值,
        // 所以不能写成 `= AppSettings.shared`。
        _ = CustomFontStore.shared
        HelpMenuFeedbackItem.installRemoval()
        _languageSettings = ObservedObject(wrappedValue: AppSettings.shared)
    }

    var body: some Scene {
        // 这里**没有** MenuBarExtra。状态栏那一项改成自建 NSStatusItem 了
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
        // 主菜单的「关于」「检查更新…」「帮助」跟状态栏菜单对齐,见 AppMainMenuCommands。
        .commands { AppMainMenuCommands() }
        // 工具栏样式**不在这里改**:`Settings` 场景把 NSWindow 的 toolbarStyle 钉成了
        // `.preference`(标题独占一行、整体居中),SwiftUI 的 `.windowToolbarStyle(.unified)`
        // 盖不住它(实测加了没有任何变化)。真正生效的那一处在 SettingsWindowConfigurator,
        // 直接写 NSWindow —— 理由与实测都在那边。
        Window(L10n.t("歌词管理"), id: "lyrics-manager") {
            LyricsManagerView()
        }
        .defaultSize(LyricsManagerView.defaultWindowSize)
        // 标题栏透明、内容铺到顶:红绿灯落在歌词管理的浮动侧栏里。别改成在 NSWindow 上手设,理由见
        // SheetWindowAffordances.swift 的 EmptyUnifiedToolbar。
        .windowStyle(.hiddenTitleBar)
        // 「搜索歌词…」独立窗口:悬浮窗 ⚙、菜单栏、快捷键、歌词窗口和歌词管理都开这一扇,点了只弹这一个搜索页面,
        // 不连带拉起别的窗口(见 LyricsQuickSearchWindow 头注)。
        Window(L10n.t("搜索歌词…"), id: "lyrics-quick-search") {
            LyricsQuickSearchWindow()
        }
        .defaultSize(LyricsSearchSheet.defaultSize)
        // 「窗口」菜单里不列这扇一次性小窗(开着时照样在底下的已打开窗口清单里)。
        .commandsRemoved()
        // 标题栏透明、内容铺到顶:红绿灯落在搜索面板的浮动侧栏里(LyricsSearchSheet.sidebar 顶上那一截)。
        // 别改成在 NSWindow 上手设,理由见 SheetWindowAffordances.swift 的 EmptyUnifiedToolbar。
        .windowStyle(.hiddenTitleBar)
        // 「分享歌词」独立窗口:歌词窗口「⋯ › 分享歌词…」和深链 lyrics-share 开它(见 LyricShareWindow 头注)。
        Window(L10n.t("分享歌词"), id: "lyrics-share") {
            LyricShareWindow()
        }
        .defaultSize(width: 860, height: 640)
        .commandsRemoved()
        // 正经的标题栏窗口(不是悬浮歌词/灵动岛那种无边框浮层),展示完整歌词并跟随
        // 播放自动滚动——见 UI/LyricsWindowView.swift 顶部注释。不加
        // .windowResizability:跟"歌词管理"这个 Window 一样,让它跟着默认的
        // .automatic 走,开关/位置/尺寸全部交给 SwiftUI+macOS 的窗口自动存档机制,
        // 不需要额外持久化代码。
        Window(L10n.t("歌词窗口"), id: "lyrics-window") {
            // 原生全屏「坏着」的真根因(探针实验坐实):**SwiftUI Window
            // 默认禁了全屏** —— 同一进程里纯 AppKit 探针窗绿键是 AXFullScreenButton、
            // 能真进全屏 Space,这扇 SwiftUI 窗却是 AXZoomButton。当年证伪的四个假设
            // (collectionBehavior/activationPolicy/LSUIElement/MenuBarExtra)都没碰到
            // 这层。
            // 这个修饰符在当前 SwiftUI 上**实测没生效**(挂上之后绿键仍是
            // AXZoomButton)——真正起效的是 AppKit 层对 collectionBehavior 的持续守护
            // (LyricsWindowController.enforceFullScreenCapability + didUpdate 观察,
            // SwiftUI 每个更新周期都会把标志复写掉,设一次不够)。修饰符仍保留:它是
            // 官方语义的表达,哪个版本 SwiftUI 修好了就能少一层对抗。
            if #available(macOS 15.0, *) {
                LyricsWindowScene().windowFullScreenBehavior(.enabled)
            } else {
                LyricsWindowScene()
            }
        }
        // 不要 SwiftUI 给这个场景自动加的「窗口」菜单项:它直接 openWindow、不分迷你还是完整,迷你开着时会再开一扇完整窗口。
        // 打开歌词窗口用 AppMainMenuCommands 里那一项(06 章决策 53)。
        .commandsRemoved()
        // AM 式顶部(对齐 Apple Music 视觉):无标题白条,背景一直通到窗顶、
        // 红绿灯悬浮在背景上。hiddenTitleBar = 标题栏透明 + 隐藏标题 + 内容全尺寸,
        // 一个修饰符抵三行 NSWindow 配置,而且在窗口显示前就生效(不闪白条)。
        // 伪全屏的进出逻辑相应简化:标题栏状态成了常驻,它只管红绿灯显隐和窗口帧
        // (见 LyricsWindowController.enter/exit)。
        .windowStyle(.hiddenTitleBar)
        // 固定尺寸的一次性向导,不需要用户手动拖拽调整——.windowResizability(.contentSize)
        // 让窗口尺寸完全跟着 OnboardingView 自己声明的 .frame(width:height:) 走。
        // .hiddenTitleBar 是给整窗玻璃底让路(玻璃要通到窗顶);标题文字由
        // OnboardingWindowBackground 设回可见,见那边的头注。
        Window(L10n.t("欢迎使用 Lyrimuse"), id: "onboarding") {
            OnboardingView()
        }
        // 引导不常驻「窗口」菜单,重来走「帮助 › 重新运行引导…」。
        .commandsRemoved()
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
