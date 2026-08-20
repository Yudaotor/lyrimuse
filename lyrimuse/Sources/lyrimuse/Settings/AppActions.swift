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

    private init() {}
}
