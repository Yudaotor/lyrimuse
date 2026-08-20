import Foundation

/// 三种「歌词展示形态」:桌面悬浮歌词 / 灵动岛 / 菜单栏歌词。
///
/// 它们在 AppSettings 里是三个各自独立的开关(classicOverlayEnabled / notchOverlayEnabled /
/// showLyricsInMenuBar),互不排斥、可以同时开着 —— 这个枚举**不是**那三个开关的替代,
/// 只是给"要对哪一个形态做某件事"这种路由代码一个能穷举、能测的载体。
///
/// 放进 LyrimuseCore 的唯一理由是下面那个存储键:菜单栏面板的快捷设置要能把设置窗口
/// 直接翻到对应那一段,而"翻到哪一段"是靠一个 UserDefaults 键传的(设置页那边是
/// @AppStorage)。键名和三个取值因此是**跨文件契约**,共用一份、别再各写一遍字面量。
public enum LyricsSurface: String, CaseIterable, Hashable, Sendable {
    case overlay
    case notch
    case menuBar

    /// 「歌词显示」页当前停在哪一段。写它 = 下次打开设置窗口就停在这一段;设置窗口已经
    /// 开着时也会立刻跟着翻页 —— 那边的 @AppStorage 观察的就是 UserDefaults 本身。
    public static let appearanceSectionStorageKey = "settings:appearanceSection"

    /// 这个形态在「歌词显示」页里对应的分段取值。
    ///
    /// ⚠️ 必须跟 SettingsView.swift 里 `AppearanceSettingsTab.Section` 的 rawValue 一字
    /// 不差(那边是 `case overlay, notch, menuBar` 的自动 rawValue)。对不上不会编译报错,
    /// 只会表现成"长按灵动岛,设置窗口却停在悬浮歌词那一段"。
    public var appearanceSectionRawValue: String { rawValue }
}
