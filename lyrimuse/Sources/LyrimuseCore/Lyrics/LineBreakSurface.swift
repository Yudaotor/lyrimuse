import Foundation

/// 按宽度重新断句(`LineBreakOptions`,见 08 章决策 25)的一个展示面:悬浮歌词、灵动岛、菜单栏这三个形态,加上触控栏。
/// 各面报各自的宽度预算、各断各的(`LyricsSyncEngine.surfaceTick`)。
///
/// 跟 `LyricsSurface` 分开:那个枚举同时是「歌词显示」页的分段、设置搜索的分组和菜单栏面板那排磁贴(前三个 rawValue
/// 是跨文件契约),触控栏一个都进不去;断句只要知道「是哪一个面」。前三个跟它同名,`init(_:)` 对得上。
public enum LineBreakSurface: String, CaseIterable, Hashable, Sendable {
    case overlay
    case notch
    case menuBar
    case touchBar

    public init(_ surface: LyricsSurface) {
        switch surface {
        case .overlay: self = .overlay
        case .notch: self = .notch
        case .menuBar: self = .menuBar
        }
    }
}
