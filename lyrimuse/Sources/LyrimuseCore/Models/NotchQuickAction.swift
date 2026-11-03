import Foundation

/// 灵动岛展开卡头部右侧快捷操作里能放的东西:一颗键或一条分隔线。放在哪一格由 `NotchQuickSlots` 管,
/// 画法和动作在 App 侧 `NotchLyricsView.trackInfoQuickActions`。见 05 章决策 130～133。
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
    case previous
    case playPause = "play-pause"
    case next
    case shuffle
    case repeatMode = "repeat"
    case lyricsAdvance = "lyrics-advance"
    case lyricsDelay = "lyrics-delay"
    case lyricsOffsetReset = "lyrics-offset-reset"
    case menuBarLyrics = "menubar-lyrics"
    case hideAllLyrics = "hide-all-lyrics"
    case lockOverlay = "lock-overlay"
    /// 分组竖线,占一整格,可以放不止一条。
    case divider

    public var isDivider: Bool { self == .divider }

    /// 设置里「可添加」那一栏分几组。
    public enum PaletteGroup: CaseIterable, Sendable {
        case playback, lyrics, surfaces, other
    }

    /// 设置里「可添加」那一栏的顺序(组内按这个排)。
    public static let paletteOrder: [NotchQuickAction] = [
        .previous, .playPause, .next, .shuffle, .repeatMode, .favorite,
        .searchLyrics, .toggleLyrics, .lyricsAdvance, .lyricsDelay, .lyricsOffsetReset,
        .lyricsWindow, .lyricsManager, .shareLyrics, .toggleOverlay, .lockOverlay, .menuBarLyrics, .hideAllLyrics, .openPlayer,
        .lastfm, .settings, .close, .divider,
    ]

    public var paletteGroup: PaletteGroup {
        switch self {
        case .previous, .playPause, .next, .shuffle, .repeatMode, .favorite: return .playback
        case .searchLyrics, .toggleLyrics, .lyricsAdvance, .lyricsDelay, .lyricsOffsetReset: return .lyrics
        case .lyricsWindow, .lyricsManager, .shareLyrics, .toggleOverlay, .lockOverlay, .menuBarLyrics, .hideAllLyrics, .openPlayer:
            return .surfaces
        case .lastfm, .settings, .close, .divider: return .other
        }
    }

    /// 一格的宽(同 `NotchExpandedMetrics.trackInfoActionsHeight` 的命中尺寸)、格与格之间的间距。
    /// App 侧画法用的是同一组数,两处要一起改。
    public static let cellWidth: Double = 22
    public static let cellSpacing: Double = 2
    /// 歌名歌手那一列至少留多宽(约 8 个汉字);格子装不下时让的是格子,不是这一列。
    public static let minTextWidth: Double = 120
    /// 头部里封面、文字、按钮区之间的间距(`trackInfoHeader` 的 HStack)。
    public static let headerSpacing: Double = 8

    /// 头部给按钮区留多宽:内容区宽减去封面、歌名歌手那一列的最小宽和它们之间的间距。
    public static func capacity(contentWidth: Double, showsArtwork: Bool, showsText: Bool, artworkSide: Double) -> Double {
        var used = 0.0
        if showsArtwork { used += artworkSide + headerSpacing }
        if showsText { used += minTextWidth + headerSpacing }
        return max(0, contentWidth - used)
    }

    /// 这么宽一行能摆几格。
    public static func slotsThatFit(capacity: Double) -> Int {
        max(0, Int((capacity + cellSpacing) / (cellWidth + cellSpacing)))
    }
}

/// 快捷操作的格子:两行,每行固定一串格子,每格放一颗键、一条分隔线或空着(中间空着就是留白)。格子从**右边**数起
/// (`rows[r][0]` 是最右那格),跟灵动岛上这块靠右对齐一致:卡片变窄时少掉的是最左边那几格,右边的位置不挪。
/// 一颗键最多出现一次。存 `np:notchQuickActionSlots`(两个字符串数组,空格是 "")。见 05 章决策 132。
public struct NotchQuickSlots: Equatable, Sendable {
    public static let rowCount = 2
    /// 每行最多存几格。展开宽 800pt、关着封面时一行约 26 格,存 16 格够用;多出的格子不画。
    public static let slotsPerRow = 16

    public private(set) var rows: [[NotchQuickAction?]]

    /// 规整:补齐 / 截到两行、每行 `slotsPerRow` 格;同一颗键只留先出现的那格(第一行从右往左、再第二行)。
    public init(rows: [[NotchQuickAction?]]) {
        var seen = Set<NotchQuickAction>()
        var out: [[NotchQuickAction?]] = []
        for r in 0..<Self.rowCount {
            let source = r < rows.count ? rows[r] : []
            out.append((0..<Self.slotsPerRow).map { i -> NotchQuickAction? in
                guard i < source.count, let action = source[i] else { return nil }
                if action.isDivider { return action }
                guard !seen.contains(action) else { return nil }
                seen.insert(action)
                return action
            })
        }
        self.rows = out
    }

    /// 没自己排过时:第一行从右往左 关闭 · 设置 · Last.fm │ 显示歌词 · 搜索歌词 · 喜欢,第二行空着。
    public static let `default` = NotchQuickSlots(rows: [
        [.close, .settings, .lastfm, .divider, .toggleLyrics, .searchLyrics, .favorite],
    ])

    /// 读设置:有格子就用格子;没有时把旧的一串排法(`np:notchQuickActions`,从左往右、`row-break` 换行)换成格子,
    /// 每行靠右摆、顺序不变;都没有用默认。
    public static func fromStored(_ raw: [[String]]?, legacy: [String]?) -> NotchQuickSlots {
        if let raw {
            return NotchQuickSlots(rows: raw.map { $0.map { NotchQuickAction(rawValue: $0) } })
        }
        guard let legacy else { return .default }
        let cut = legacy.firstIndex(of: "row-break")
        let lines = cut.map { [Array(legacy[..<$0]), Array(legacy[($0 + 1)...])] } ?? [legacy]
        return NotchQuickSlots(rows: lines.map { line in
            line.compactMap { NotchQuickAction(rawValue: $0) }.reversed().map { Optional($0) }
        })
    }

    /// 存设置用的样子:空格写 ""。
    public var stored: [[String]] { rows.map { $0.map { $0?.rawValue ?? "" } } }

    /// 头部按几行留高度:第二行有东西就是两行。只看格子,不看这一刻哪颗键画得出来、宽度够不够 ——
    /// 高度跟着设置走,不因为换了一首没有「喜欢」的歌就抽一下。
    public var usedRowCount: Int { rows[1].contains { $0 != nil } ? 2 : 1 }

    /// 已经放进格子的键(分隔线不算)。
    public var placed: Set<NotchQuickAction> { Set(rows.joined().compactMap { $0 }.filter { !$0.isDivider }) }

    /// 第 `row` 行最左一格有东西的是第几格(从右数,0 起);整行空是 nil。
    public func lastFilled(row: Int) -> Int? { rows[row].lastIndex { $0 != nil } }

    /// 放进某一格,原来那格的东西被换掉。放的是已经在别处的键时,那一格清空(一颗键只出现一次)。
    public func placing(_ action: NotchQuickAction, row: Int, slot: Int) -> NotchQuickSlots {
        guard rows.indices.contains(row), rows[row].indices.contains(slot) else { return self }
        var next = rows
        if !action.isDivider {
            for r in next.indices { for i in next[r].indices where next[r][i] == action { next[r][i] = nil } }
        }
        next[row][slot] = action
        return NotchQuickSlots(rows: next)
    }

    public func clearing(row: Int, slot: Int) -> NotchQuickSlots {
        guard rows.indices.contains(row), rows[row].indices.contains(slot) else { return self }
        var next = rows
        next[row][slot] = nil
        return NotchQuickSlots(rows: next)
    }

    /// 把一格挪到另一格:目标格原来有东西就跟它对调。
    public func moving(fromRow: Int, fromSlot: Int, toRow: Int, toSlot: Int) -> NotchQuickSlots {
        guard rows.indices.contains(fromRow), rows[fromRow].indices.contains(fromSlot),
              rows.indices.contains(toRow), rows[toRow].indices.contains(toSlot) else { return self }
        var next = rows
        let moved = next[fromRow][fromSlot]
        next[fromRow][fromSlot] = next[toRow][toSlot]
        next[toRow][toSlot] = moved
        return NotchQuickSlots(rows: next)
    }

    /// 点一下「可添加」里的键:放进看得见的格子里第一个空的(第一行从右往左,再第二行);都满了原样返回。
    public func addingToFirstEmpty(_ action: NotchQuickAction, visibleSlots: Int) -> NotchQuickSlots {
        let limit = min(max(visibleSlots, 0), Self.slotsPerRow)
        for r in rows.indices {
            if let i = (0..<limit).first(where: { rows[r][$0] == nil }) { return placing(action, row: r, slot: i) }
        }
        return self
    }

    /// 灵动岛上这一行画什么,**从左往右**:看得见的那几格(`visibleSlots`,按宽度算)里,`available` 为假的键
    /// (播放器没有「喜欢」、没连 Last.fm、广告期间的喜欢)当空格画,保住别的键的位置;左边起头的空格不画(不占宽)。
    public func visibleRow(_ row: Int, visibleSlots: Int, available: (NotchQuickAction) -> Bool) -> [NotchQuickAction?] {
        guard rows.indices.contains(row) else { return [] }
        let count = min(max(visibleSlots, 0), Self.slotsPerRow)
        let cells = rows[row].prefix(count).map { action -> NotchQuickAction? in
            guard let action, action.isDivider || available(action) else { return nil }
            return action
        }
        return Array(cells.reversed().drop { $0 == nil })
    }
}
