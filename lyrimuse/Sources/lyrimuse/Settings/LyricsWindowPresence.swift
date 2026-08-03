import AppKit

// 全局常量(不是 LyricsWindowPresence 的 static 成员)——纯 String 字面量,不需要
// MainActor 隔离,这样才能在下面 NotificationCenter 回调闭包的 guard 里直接读取而不
// 触发"从 Sendable 闭包引用 actor 隔离静态属性"的编译警告(闭包本体在真正碰
// self.isOpen 之前才需要 MainActor.assumeIsolated,guard 这一步不需要)。
private let lyricsWindowID = "lyrics-window"

// "歌词窗口"(Window(id: "lyrics-window"))的开关状态跟悬浮歌词/灵动岛歌词不一样——
// 那两个是 AppSettings 里持久化的布尔值,App 启动时 AppDelegate 显式按这个值决定要不要
// setVisible(true);"歌词窗口"从来没有这样一个持久化布尔值,它的开合完全交给 SwiftUI
// Window(id:) 自己的窗口自动存档机制管(见 App.swift 那个场景处的注释)。这个单例只是
// 给"歌词展示"设置页里想放一个 Toggle 的需求补一层"现在这扇窗口是不是开着"的只读
// 状态——不是新引入一个持久化开关,纯粹是运行时观测,不写盘。
//
// 用全局(object: nil)的 NSWindow 通知 + identifier 过滤,而不是像 LyricsWindowView 里
// 的 LyricsWindowController 那样"先拿到具体这扇窗口实例再挂观察者"——这个类活在
// SettingsView 所在的完全不同的窗口/视图树里,构造这一刻"歌词窗口"可能压根还没被
// 打开过、没有实例可拿,只能等它第一次出现在 NSApp.windows 里再说。实测坐实
// window.identifier?.rawValue 确实等于 Window(id:) 声明时用的那个字符串"lyrics-window"
// (2026-08-01 加这个功能时用临时 Logger 探针验证过,不是凭印象假设的)。
@MainActor
final class LyricsWindowPresence: ObservableObject {
    static let shared = LyricsWindowPresence()

    @Published private(set) var isOpen: Bool

    private init() {
        // 单例第一次被访问时(通常是设置页 AppearanceSettingsTab 出现时)才构造——这时
        // "歌词窗口"有可能已经开着(比如用户先从菜单打开了它,再去开设置页),用
        // NSApp.windows 现查一次当前真实状态当初始值,不能无条件从 false 开始。
        isOpen = NSApp.windows.contains { $0.identifier?.rawValue == lyricsWindowID }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? NSWindow)?.identifier?.rawValue == lyricsWindowID else { return }
            MainActor.assumeIsolated { self?.isOpen = true }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? NSWindow)?.identifier?.rawValue == lyricsWindowID else { return }
            MainActor.assumeIsolated { self?.isOpen = false }
        }
    }
}
