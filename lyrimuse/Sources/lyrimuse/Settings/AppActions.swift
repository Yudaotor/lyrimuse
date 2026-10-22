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
    /// 只开场景那扇完整尺寸的歌词窗口(激活 App),不按形态分流:出迷你时用(07 章决策 133)。别的地方一律走 `openLyricsWindow`。
    var openLyricsWindowScene: (() -> Void)?
    var openOnboarding: (() -> Void)?
    /// 把「搜索歌词…」独立窗口叫出来(`Window(id: "lyrics-quick-search")`,见 App.swift),不用先开歌词窗口。跟上面三个 open*
    /// 同一个理由,在 MenuBarSceneActions.swift 的锚点视图里捕获 `openWindow(id:)` 这个环境 action。只经下面两个入口调,
    /// 它们先定好搜哪一首(`lyricsSearchTarget`)。
    var presentLyricsSearchWindow: (() -> Void)?

    /// 唤出「搜索歌词…」窗口搜正在放的那首(悬浮窗 ⚙、菜单栏、快捷键、歌词窗口、灵动岛共用)。
    var openLyricsQuickSearch: (() -> Void)? {
        guard let present = presentLyricsSearchWindow else { return nil }
        return { [weak self] in
            self?.lyricsSearchTarget = nil
            present()
        }
    }

    /// 「搜索歌词…」小窗**已经开着**(没被真的关掉,只是被别的窗口挡住/切到后台)时的
    /// 那一半信号——跟上面 `selectionRequests` 是同一个坑的同一个修法(现象是
    /// "已经切歌了,点开搜索页面看到的还是上一首"):`LyricsQuickSearchWindow` 的
    /// `.task { loadContext() }` 只在这扇 `Window(id:)` 场景**新建**那一次跑一遍,窗口没被
    /// 真关掉时再点一次「搜索歌词…」只是把已经存在的那个视图实例带到前台,`.task` 不会
    /// 重跑,`context` 还停在第一次打开时查到的那首歌。每次调用 `openLyricsQuickSearch`
    /// 时都往这里 send 一下,`LyricsQuickSearchWindow` 用 `.onReceive` 订阅、收到就重新
    /// `loadContext()`——窗口首次新建那次由 `.task` 兜底(视图还没挂载,订阅还没建立,这次
    /// send 会落空,但不需要它,`.task` 本来就会查一遍),两条路合起来才是"点这个按钮一定
    /// 看到当前这首歌"。
    let quickSearchRefreshRequests = PassthroughSubject<Void, Never>()

    /// 把「分享歌词」窗口叫出来(`Window(id: "lyrics-share")`,见 App.swift),在 MenuBarSceneActions.swift 的锚点视图里捕获。
    var presentLyricShareWindow: (() -> Void)?
    /// 窗口已经开着时再点「分享歌词…」只会把它带到前台,靠这一下按正在放的那首重取(同 `quickSearchRefreshRequests`)。
    let lyricShareRefreshRequests = PassthroughSubject<Void, Never>()

    /// 「搜索歌词…」窗口要搜的那一首:歌词管理按选中那首开时是它(`openLyricsSearch(for:)`),别的入口开时是 nil = 正在放的
    /// 那首。每次打开由入口定好,窗口读的时候不清:新开的窗口 `.task` 和 `quickSearchRefreshRequests` 两条路都会读一遍,
    /// 读一次就清的话后一次读到 nil,又换回正在放的那首。
    private(set) var lyricsSearchTarget: LyricsSearchTarget?

    func openLyricsSearch(for target: LyricsSearchTarget) {
        guard let present = presentLyricsSearchWindow else { return }
        lyricsSearchTarget = target
        present()
    }

    /// 「搜索歌词…」窗口里采纳成功(带写回的 key)、「重新自动匹配」有了结论。歌词管理开着同一首时据此重载编辑框、挂结论。
    let lyricsSearchApplied = PassthroughSubject<String, Never>()
    let lyricsSearchRematched = PassthroughSubject<LyricsSearchRematchResult, Never>()

    /// 「重新运行引导…」要从头再来:回到第一页、清掉走过的进度、重放开场。引导窗口已经开着时 `openOnboarding`
    /// 只是把它带到前台,靠这一下补上;窗口是新开的,开场由它自己进门时放(同 `quickSearchRefreshRequests` 的做法)。
    /// 授权后把引导带回前台那条路只调 `openOnboarding`,不发这个。见 14 章决策 109。
    let onboardingRestartRequests = PassthroughSubject<Void, Never>()

    /// 歌词管理里弹「同曲条目」面板(`lyrimuse://lyrics-manager/song-versions[?key=…][&evidence=1][&compare=…]`)。同上两条路:信箱管
    /// 窗口刚建出来(LyricsManagerView 读完缓存、自动定位过正在放的那首之后取),subject 管已经开着。信箱记着请求时刻,只认 60 秒
    /// 以内的:窗口没开出来时请求一直留着,下次开窗会冒出这个面板。都走 `requestSongVersions(key:showEvidence:compare:)`。
    var pendingSongVersions: (key: String?, showEvidence: Bool, compare: String?, at: Date)?
    let songVersionsRequests = PassthroughSubject<Void, Never>()

    func requestSongVersions(key: String?, showEvidence: Bool, compare: String? = nil) {
        pendingSongVersions = (key, showEvidence, compare, Date())
        songVersionsRequests.send()
    }

    // 新增:Onboarding 的 Last.fm 介绍步骤想直接跳到设置窗口的 Last.fm
    // 详情页,而不是打开设置后还要用户自己再点一次侧边栏。SettingsView 自己管理
    // `selection` 这份 @State,外部没有别的办法在它已经存在的情况下改写这份状态——
    // 借这个字段当一次性信箱:调用方先写入目标,再调 openSettings(),SettingsView 的
    // .onAppear 读到就消费掉(读完置 nil),避免下次正常打开设置窗口时被这次的残留值
    // 顶掉用户当前正打算看的分类。
    var pendingSettingsSelection: SettingsSidebarItem?

    /// 「设置窗口已经开着」时的那一半。
    ///
    /// 上面那个信箱只被 SettingsView 的 `.onAppear` 消费,而 .onAppear **只在窗口新建那一次
    /// 跑** —— 窗口已经开着(或视图还活着只是窗口被关过)时点"去 Last.fm 那一页",信箱里的
    /// 值没人读,表现就是"设置打开了,但页没跳"。而且那份没被消费的残留还会在下一次真正
    /// 新建窗口时冒出来,把用户当时想看的分类顶掉。现象是「有时候没定向到 Last.fm 页面」
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

    /// 「Last.fm 账号建议」里点「重新连接…」:要 Last.fm 页把连接向导打开(向导是那一页的 sheet)。同 requestSettings 两条路
    /// 一起走:信箱管那一页还没建出来(从建议页切过去),subject 管那一页已经开着。
    var pendingLastfmWizard = false
    let lastfmWizardRequests = PassthroughSubject<Void, Never>()

    func requestLastfmWizard() {
        pendingLastfmWizard = true
        lastfmWizardRequests.send()
    }

    /// 「这段时间内的 reopen 别开歌词窗口」—— 点系统通知时用。
    ///
    /// 点通知会连带弹出歌词窗口(applicationShouldHandleReopen 是为「点 Dock
    /// 图标开歌词窗口」写的,系统激活 App 时也会走到它)。 别在通知回调里写
    /// `(NSApp.delegate as? AppDelegate)?.cancel...` —— **实测无声失败**,那是全仓唯一一处
    /// NSApp.delegate 用法,SwiftUI 的 @NSApplicationDelegateAdaptor 下这个转型拿不到我们的
    /// AppDelegate(日志里那行 suppressed 从来没出现过就是证据)。所以状态放这里 ——
    /// 这个单例存在的意义本来就是"reopen 处理器和别处互相到不了"这类桥接。
    var suppressLyricsOnReopenUntil: Date?

    private init() {}
}
