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

    private init() {}
}
