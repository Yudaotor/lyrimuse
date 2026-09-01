import AppKit
import Combine
import LyrimuseCore

// "每块屏都显示灵动岛"这个模式的管理器:主实例(NotchLyricsWindowController.shared)照旧
// 贴在 targetScreen() 那块屏上,这里再给**其余每一块**屏各建一个钉死在那块屏上的副本。
//
// 为什么是"主 + 副本"而不是把主实例也收编成字典里的一员:`.shared` 这个单例被
// AppDelegate/SettingsView/MenuBarMenu/GlobalHotkeys 四处路由代码直接引用,而且它的
// 构造时机本身就是一条要小心维护的不变量(见 NotchLyricsWindowController 文件头那段:
// 只要在"经典"样式生效期间碰一下 `.shared`,就会凭空冒出一个胶囊)。把单例改造成
// 集合等于同时改动那四处路由和那条不变量,风险远大于这个功能本身的价值。
//
// ⚠️ 这个管理器**只在用户主动打开"所有屏幕"开关时才碰 `.shared`** —— refresh() 里读
// `.shared` 是为了知道主实例占了哪块屏(那块屏不能再建副本)。开关默认关闭,关闭时
// disabled 分支在读 `.shared` 之前就 return 了,不会破坏上面那条不变量。
@MainActor
enum NotchMirrorManager {
    /// 按显示器 UUID 存的副本。
    private static var mirrors: [String: NotchLyricsWindowController] = [:]
    private static var cancellables = Set<AnyCancellable>()
    private static var screenObserver: NSObjectProtocol?
    private static var started = false

    /// App 启动时调一次。之后偏好变化/屏幕插拔都由这里自己订阅处理。
    static func start() {
        guard !started else { return }
        started = true

        let settings = AppSettings.shared
        // ⚠️ 每个 sink 都用**参数值**,不在闭包里回头读 AppSettings:@Published 在 willSet
        // 时机发布,那一刻属性还是旧值(本项目已实测踩过)。所以下面不是简单地
        // `.sink { _ in refresh() }`,而是把新值显式传给 refresh(enabled:)。
        settings.$notchAllScreens
            .combineLatest(settings.$notchOverlayEnabled)
            .sink { allScreens, notchEnabled in
                MainActor.assumeIsolated {
                    refresh(enabled: allScreens && notchEnabled, notchEnabled: notchEnabled)
                }
            }
            .store(in: &cancellables)

        // 这几项副本没有自己的设置入口,变化时统一重新同步一遍。它们不影响"该不该有副本",
        // 只影响副本的状态,所以不参与上面那个 enabled 的计算。
        //
        // ⚠️ 三个参数值都必须显式传下去,不能 `.sink { _, _, _ in syncAll() }` 让下游回读
        // AppSettings —— 顶上那段 willSet 注释警告的坑,这个 sink 原来就原样踩着
        // (2026-08-19 核实):@Published 在 willSet 时机同步派发,sink 执行时存储属性还是
        // 旧值,于是镜像的宽度恒滞后一档、隐藏开关同步到翻转前的状态,直到下一次任一设置
        // 再变才追上。
        // ⚠️ 订的是 `notchHide*` —— 2026-09-01 起灵动岛有自己独立的一份「自动隐藏」设置,
        // 订到悬浮歌词那一份上,表现会是"在悬浮歌词页面拨开关,副屏的灵动岛镜像跟着变"。
        settings.$notchHideWhenNotPlaying
            .combineLatest(settings.$notchHideDuringScreenCapture, settings.$notchContentWidth)
            .sink { hide, capture, width in
                MainActor.assumeIsolated {
                    syncAll(hideWhenNotPlaying: hide, hideDuringCapture: capture,
                            contentWidth: width)
                }
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let s = AppSettings.shared
                refresh(enabled: s.notchAllScreens && s.notchOverlayEnabled)
            }
        }
    }

    /// 建立/销毁副本,使副本集合恰好等于「所有屏幕 − 主实例占的那块」。
    /// notchEnabled:触发源是开关 sink 时传参数值(willSet 窗口内回读是旧值,见 start()
    /// 里的注释);屏幕插拔那条路(通知回调,不在任何 willSet 窗口)回读即可传 nil。
    static func refresh(enabled: Bool, notchEnabled: Bool? = nil) {
        guard enabled else {
            teardownAll()
            return
        }
        // 主实例贴的那块屏不建副本,否则同一块屏上会有两个灵动岛严丝合缝地叠在一起
        // (肉眼看不出是两个,但 hover 只有上面那个响应,点播放按钮的手感会莫名其妙)。
        let primaryID = NotchLyricsWindowController.targetScreen().flatMap(ScreenIdentity.id(of:))
        var wanted = Set<String>()
        for screen in NSScreen.screens {
            guard let id = ScreenIdentity.id(of: screen), id != primaryID else { continue }
            wanted.insert(id)
        }

        for (id, mirror) in mirrors where !wanted.contains(id) {
            mirror.teardown()
            mirrors[id] = nil
        }
        for id in wanted where mirrors[id] == nil {
            // 钉屏 ID 走构造参数,不能建完再设 —— 理由见那个 init 上的注释。
            mirrors[id] = NotchLyricsWindowController(pinnedScreenID: id)
        }
        syncAll(notchEnabled: notchEnabled)
    }

    /// 非 nil 的参数 = 触发源正处于该字段的 willSet 窗口,必须用传入值;nil = 回读当前
    /// 存储值(安全)。透传给 NotchLyricsWindowController.syncStateFromSettings。
    private static func syncAll(
        notchEnabled: Bool? = nil,
        hideWhenNotPlaying: Bool? = nil,
        hideDuringCapture: Bool? = nil,
        contentWidth: CGFloat? = nil
    ) {
        for mirror in mirrors.values {
            mirror.syncStateFromSettings(
                notchEnabled: notchEnabled,
                hideWhenNotPlaying: hideWhenNotPlaying,
                hideDuringCapture: hideDuringCapture,
                contentWidth: contentWidth)
        }
    }

    private static func teardownAll() {
        for mirror in mirrors.values { mirror.teardown() }
        mirrors.removeAll()
    }
}
