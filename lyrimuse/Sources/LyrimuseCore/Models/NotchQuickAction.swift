import Foundation

/// 灵动岛展开卡头部右侧那排快捷操作里的一格:哪颗键、排在第几,用户在设置「展开时」浮层里自己排
/// (`np:notchQuickActions`,存 rawValue 数组)。画法和动作在 App 侧 `NotchLyricsView.trackInfoQuickActions`。
/// 见 05 章决策 130。
public enum NotchQuickAction: String, CaseIterable, Codable, Sendable {
    case favorite
    case searchLyrics = "search-lyrics"
    case toggleLyrics = "toggle-lyrics"
    case lyricsWindow = "lyrics-window"
    case lyricsManager = "lyrics-manager"
    case shareLyrics = "share-lyrics"
    case toggleOverlay = "toggle-overlay"
    case openPlayer = "open-player"
    case lastfm
    case settings
    case close
    /// 分组竖线,可以放不止一条。
    case divider

    /// 没自己排过时的那一排。
    public static let defaultLayout: [NotchQuickAction] = [
        .favorite, .searchLyrics, .toggleLyrics, .divider, .lastfm, .settings, .close,
    ]

    /// 最多几颗键(分隔线不算):头部右侧跟歌名歌手共用一行,再多歌名就挤没了。
    public static let maxButtons = 8
    /// 最多几条分隔线。
    public static let maxDividers = 3

    /// 设置里「可添加」那一栏的顺序。
    public static let paletteOrder: [NotchQuickAction] = [
        .favorite, .searchLyrics, .toggleLyrics, .lyricsWindow, .lyricsManager, .shareLyrics,
        .toggleOverlay, .openPlayer, .lastfm, .settings, .close, .divider,
    ]

    public var isDivider: Bool { self == .divider }

    /// 存着的数组 → 排法:认不出的丢掉,同一颗键只留第一次出现的,键和分隔线各按上限截。
    /// 存的是空数组就是空排法(用户把键都移掉了);没存过用 `defaultLayout`。
    public static func layout(fromStored raw: [String]?) -> [NotchQuickAction] {
        guard let raw else { return defaultLayout }
        var seen = Set<NotchQuickAction>()
        var buttons = 0, dividers = 0
        var out: [NotchQuickAction] = []
        for value in raw {
            guard let action = NotchQuickAction(rawValue: value) else { continue }
            if action.isDivider {
                guard dividers < maxDividers else { continue }
                dividers += 1
            } else {
                guard !seen.contains(action), buttons < maxButtons else { continue }
                seen.insert(action)
                buttons += 1
            }
            out.append(action)
        }
        return out
    }

    /// 这一刻真正画出来的那排:`available` 为假的键(播放器没有「喜欢」、没连 Last.fm、广告期间的喜欢)拿掉,
    /// 再去掉落到头尾的分隔线和挨在一起的分隔线。
    public static func visible(_ layout: [NotchQuickAction], available: (NotchQuickAction) -> Bool) -> [NotchQuickAction] {
        var out: [NotchQuickAction] = []
        for action in layout where action.isDivider || available(action) {
            if action.isDivider, out.last?.isDivider ?? true { continue }
            out.append(action)
        }
        if out.last?.isDivider == true { out.removeLast() }
        return out
    }

    /// 还能不能再加这一格。
    public static func canAdd(_ action: NotchQuickAction, to layout: [NotchQuickAction]) -> Bool {
        if action.isDivider { return layout.filter(\.isDivider).count < maxDividers }
        return !layout.contains(action) && layout.filter { !$0.isDivider }.count < maxButtons
    }

    /// 加到末尾;末尾是「关闭」时加在它前面(✕ 留在最右边上)。加不了原样返回。
    public static func adding(_ action: NotchQuickAction, to layout: [NotchQuickAction]) -> [NotchQuickAction] {
        guard canAdd(action, to: layout) else { return layout }
        var out = layout
        if action != .close, out.last == .close { out.insert(action, at: out.count - 1) } else { out.append(action) }
        return out
    }

    /// 把第 `from` 格挪到第 `to` 格(按挪完之后的位置算),越界夹到两头。
    public static func moving(_ layout: [NotchQuickAction], from: Int, to: Int) -> [NotchQuickAction] {
        guard layout.indices.contains(from) else { return layout }
        var out = layout
        let item = out.remove(at: from)
        out.insert(item, at: min(max(to, 0), out.count))
        return out
    }

    /// 拖动时落在第几格:`widths` 是每格的宽(含间距),`dragged` 是被拖那格,`offset` 是它中线相对起点挪了多少。
    /// 中线越过邻格中线就换过去。
    public static func dropIndex(widths: [Double], dragged: Int, offset: Double) -> Int {
        guard widths.indices.contains(dragged) else { return dragged }
        var lefts: [Double] = []
        var x = 0.0
        for w in widths { lefts.append(x); x += w }
        let center = lefts[dragged] + widths[dragged] / 2 + offset
        var target = dragged
        for i in widths.indices where i != dragged {
            let mid = lefts[i] + widths[i] / 2
            if i < dragged, center < mid { target = min(target, i) }
            if i > dragged, center > mid { target = max(target, i) }
        }
        return target
    }
}
