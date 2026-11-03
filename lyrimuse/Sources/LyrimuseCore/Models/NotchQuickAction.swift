import Foundation

/// 灵动岛展开卡头部右侧那排快捷操作里的一格:哪颗键、排在第几、在哪换行,用户在设置「展开时」浮层里自己排
/// (`np:notchQuickActions`,存 rawValue 数组)。画法和动作在 App 侧 `NotchLyricsView.trackInfoQuickActions`。
/// 放多少颗不设固定上限:每一行按头部此刻的宽度装(`capacity`),装不下的从这一行最左边起不画。
/// 见 05 章决策 130、131。
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
    /// 从这里起换到第二行。最多一个。
    case rowBreak = "row-break"

    /// 没自己排过时的那一排。
    public static let defaultLayout: [NotchQuickAction] = [
        .favorite, .searchLyrics, .toggleLyrics, .divider, .lastfm, .settings, .close,
    ]

    /// 最多几条分隔线。
    public static let maxDividers = 3

    /// 一颗键的命中宽(同 `NotchExpandedMetrics.trackInfoActionsHeight`)、一条分隔线连左右留白的宽、格与格之间的间距。
    /// App 侧画法(`NotchLyricsView.quickActionCell`)用的是同一组数,两处要一起改。
    public static let buttonWidth: Double = 22
    public static let dividerWidth: Double = 7
    public static let cellSpacing: Double = 2
    /// 歌名歌手那一列至少留多宽(约 8 个汉字);按钮行装不下时让的是按钮,不是这一列。
    public static let minTextWidth: Double = 120
    /// 头部里封面、文字、按钮行之间的间距(`trackInfoHeader` 的 HStack)。
    public static let headerSpacing: Double = 8

    /// 设置里「可添加」那一栏的顺序。
    public static let paletteOrder: [NotchQuickAction] = [
        .favorite, .searchLyrics, .toggleLyrics, .lyricsWindow, .lyricsManager, .shareLyrics,
        .toggleOverlay, .openPlayer, .lastfm, .settings, .close, .divider, .rowBreak,
    ]

    public var isDivider: Bool { self == .divider }
    /// 分隔线、换行这种不是键的格。
    public var isSeparator: Bool { self == .divider || self == .rowBreak }

    /// 存着的数组 → 排法:认不出的丢掉,同一颗键、换行只留第一次出现的,分隔线按上限截。
    /// 存的是空数组就是空排法(用户把键都移掉了);没存过用 `defaultLayout`。
    public static func layout(fromStored raw: [String]?) -> [NotchQuickAction] {
        guard let raw else { return defaultLayout }
        var seen = Set<NotchQuickAction>()
        var dividers = 0
        var out: [NotchQuickAction] = []
        for value in raw {
            guard let action = NotchQuickAction(rawValue: value) else { continue }
            if action.isDivider {
                guard dividers < maxDividers else { continue }
                dividers += 1
            } else {
                guard !seen.contains(action) else { continue }
                seen.insert(action)
            }
            out.append(action)
        }
        return out
    }

    /// 按换行拆成一行或两行(换行本身不在里面)。
    public static func rows(_ layout: [NotchQuickAction]) -> [[NotchQuickAction]] {
        guard let cut = layout.firstIndex(of: .rowBreak) else { return [layout] }
        return [Array(layout[..<cut]), Array(layout[(cut + 1)...]).filter { $0 != .rowBreak }]
    }

    /// 头部按几行留高度:换行两边都有键才是两行。只看排法,不看这一刻哪颗键能不能画、宽度够不够 ——
    /// 高度跟着开关走,不该因为换了一首没有「喜欢」的歌就抽一下。
    public static func rowCount(_ layout: [NotchQuickAction]) -> Int {
        rows(layout).filter { $0.contains { !$0.isSeparator } }.count >= 2 ? 2 : 1
    }

    /// 去掉落到头尾的分隔线和挨在一起的分隔线。
    public static func trimmedDividers(_ row: [NotchQuickAction]) -> [NotchQuickAction] {
        var out: [NotchQuickAction] = []
        for action in row where action != .rowBreak {
            if action.isDivider, out.last?.isDivider ?? true { continue }
            out.append(action)
        }
        if out.last?.isDivider == true { out.removeLast() }
        return out
    }

    /// 一行的宽。
    public static func width(of row: [NotchQuickAction]) -> Double {
        guard !row.isEmpty else { return 0 }
        let cells = row.reduce(0.0) { $0 + ($1.isDivider ? dividerWidth : buttonWidth) }
        return cells + Double(row.count - 1) * cellSpacing
    }

    /// 头部给按钮行留多宽:内容区宽减去封面、歌名歌手那一列的最小宽和它们之间的间距。
    public static func capacity(contentWidth: Double, showsArtwork: Bool, showsText: Bool, artworkSide: Double) -> Double {
        var used = 0.0
        if showsArtwork { used += artworkSide + headerSpacing }
        if showsText { used += minTextWidth + headerSpacing }
        return max(0, contentWidth - used)
    }

    /// 这一刻真正画出来的几行:`available` 为假的键(播放器没有「喜欢」、没连 Last.fm、广告期间的喜欢)拿掉,
    /// 头尾和挨着的分隔线去掉;一行宽过 `capacity` 就从这一行最左边起一格一格不画,直到装得下(最右边的 ✕ 留得最久)。
    /// 空行不出现。
    public static func visibleRows(_ layout: [NotchQuickAction], capacity: Double = .infinity,
                                   available: (NotchQuickAction) -> Bool) -> [[NotchQuickAction]] {
        rows(layout).compactMap { row in
            var kept = trimmedDividers(row.filter { $0.isDivider || available($0) })
            while !kept.isEmpty, width(of: kept) > capacity { kept = trimmedDividers(Array(kept.dropFirst())) }
            return kept.isEmpty ? nil : kept
        }
    }

    /// 还能不能再加这一格。
    public static func canAdd(_ action: NotchQuickAction, to layout: [NotchQuickAction]) -> Bool {
        if action.isDivider { return layout.filter(\.isDivider).count < maxDividers }
        return !layout.contains(action)
    }

    /// 加一格。键加到末尾,末尾是「关闭」时加在它前面(✕ 留在最右边上);换行加在第一条分隔线那里(两组各占一行),
    /// 没有分隔线就加在正中。加不了原样返回。
    public static func adding(_ action: NotchQuickAction, to layout: [NotchQuickAction]) -> [NotchQuickAction] {
        guard canAdd(action, to: layout) else { return layout }
        var out = layout
        if action == .rowBreak {
            out.insert(action, at: out.firstIndex(of: .divider) ?? out.count / 2)
        } else if action != .close, out.last == .close {
            out.insert(action, at: out.count - 1)
        } else {
            out.append(action)
        }
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

    /// 设置编辑区里拖动时落在第几格:`widths` 是每格的宽(含间距),`dragged` 是被拖那格,`offset` 是它中线相对起点挪了多少。
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
