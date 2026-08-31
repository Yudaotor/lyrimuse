import Combine
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
    var openLyricsWindow: (() -> Void)?
    var openOnboarding: (() -> Void)?
    /// 唤出「搜索歌词…」独立小窗(2026-08-30,悬浮窗 ⚙ 快捷菜单用)——**不是**歌词窗口
    /// 那个 `.sheet(item:)`(那个要求歌词窗口先开着,用户明确要求"只弹搜索页面,不用
    /// 拉起歌词窗口")。这是它自己独立的一扇 `Window(id: "lyrics-quick-search")`(见
    /// App.swift),`LyricsQuickSearchWindow` 是根内容,自己在 `.task` 里现查一次当前
    /// 曲目——跟上面三个 open* 同一个理由,在 MenuBarSceneActions.swift 的锚点视图里
    /// 捕获 `openWindow(id:)` 这个环境 action。
    var openLyricsQuickSearch: (() -> Void)?

    /// 「搜索歌词…」小窗**已经开着**(没被真的关掉,只是被别的窗口挡住/切到后台)时的
    /// 那一半信号——跟上面 `selectionRequests` 是同一个坑的同一个修法(2026-08-31 用户报
    /// "已经切歌了,点开搜索页面看到的还是上一首"):`LyricsQuickSearchWindow` 的
    /// `.task { loadContext() }` 只在这扇 `Window(id:)` 场景**新建**那一次跑一遍,窗口没被
    /// 真关掉时再点一次「搜索歌词…」只是把已经存在的那个视图实例带到前台,`.task` 不会
    /// 重跑,`context` 还停在第一次打开时查到的那首歌。每次调用 `openLyricsQuickSearch`
    /// 时都往这里 send 一下,`LyricsQuickSearchWindow` 用 `.onReceive` 订阅、收到就重新
    /// `loadContext()`——窗口首次新建那次由 `.task` 兜底(视图还没挂载,订阅还没建立,这次
    /// send 会落空,但不需要它,`.task` 本来就会查一遍),两条路合起来才是"点这个按钮一定
    /// 看到当前这首歌"。
    let quickSearchRefreshRequests = PassthroughSubject<Void, Never>()

    // 2026-07-29 新增:Onboarding 的 Last.fm 介绍步骤想直接跳到设置窗口的 Last.fm
    // 详情页,而不是打开设置后还要用户自己再点一次侧边栏。SettingsView 自己管理
    // `selection` 这份 @State,外部没有别的办法在它已经存在的情况下改写这份状态——
    // 借这个字段当一次性信箱:调用方先写入目标,再调 openSettings(),SettingsView 的
    // .onAppear 读到就消费掉(读完置 nil),避免下次正常打开设置窗口时被这次的残留值
    // 顶掉用户当前正打算看的分类。
    var pendingSettingsSelection: SettingsSidebarItem?

    /// 「设置窗口已经开着」时的那一半(2026-08-19 加)。
    ///
    /// 上面那个信箱只被 SettingsView 的 `.onAppear` 消费,而 .onAppear **只在窗口新建那一次
    /// 跑** —— 窗口已经开着(或视图还活着只是窗口被关过)时点"去 Last.fm 那一页",信箱里的
    /// 值没人读,表现就是"设置打开了,但页没跳"。而且那份没被消费的残留还会在下一次真正
    /// 新建窗口时冒出来,把用户当时想看的分类顶掉。用户报的「有时候没定向到 Last.fm 页面」
    /// 就是这一对症状。
    let selectionRequests = PassthroughSubject<SettingsSidebarItem, Never>()

    /// 请求设置窗口停在某个分类。**两条路一起走,缺一不可**:信箱管"窗口还没建出来"、
    /// subject 管"窗口已经开着"。所有调用方都必须走这个方法,别再直接写那个字段。
    ///
    /// 把窗口叫出来仍由调用方各自负责 —— 有的要先 NSApp.activate(见 OnboardingView),
    /// 有的走 AppActions.openSettings,这里不替它们决定。
    func requestSettings(_ item: SettingsSidebarItem) {
        pendingSettingsSelection = item
        selectionRequests.send(item)
    }

    /// 「这段时间内的 reopen 别开歌词窗口」—— 点系统通知时用。
    ///
    /// 2026-08-22:点通知会连带弹出歌词窗口(applicationShouldHandleReopen 是为「点 Dock
    /// 图标开歌词窗口」写的,系统激活 App 时也会走到它)。第一版试过在通知回调里
    /// `(NSApp.delegate as? AppDelegate)?.cancel...` —— **实测无声失败**,那是全仓唯一一处
    /// NSApp.delegate 用法,SwiftUI 的 @NSApplicationDelegateAdaptor 下这个转型拿不到我们的
    /// AppDelegate(日志里那行 suppressed 从来没出现过就是证据)。所以状态放这里 ——
    /// 这个单例存在的意义本来就是"reopen 处理器和别处互相到不了"这类桥接。
    var suppressLyricsOnReopenUntil: Date?

    private init() {}
}
