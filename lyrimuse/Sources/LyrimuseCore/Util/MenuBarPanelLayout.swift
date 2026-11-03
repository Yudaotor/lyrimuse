import Foundation
import CoreGraphics

/// 菜单栏左键面板的布局:钮块网格里放哪些格子、什么顺序、多大,底部藏了哪几项。见 06 章决策 82。
///
/// 存成一串 JSON(`encoded()` / `decode(_:)`)。认不出的格子丢掉、认不出的尺寸退回中号、重复的只留第一个,
/// 一处坏数据不把整个布局清空;整串读不出来才退回默认。默认布局就是这块面板一直以来的样子。
public struct MenuBarPanelLayout: Equatable, Sendable {
    /// 能放进网格的格子。rawValue 是存盘和深链里的写法,别改。
    public enum Tile: String, CaseIterable, Sendable {
        case overlay
        case notch
        case menuBar = "menubar"
        case lyricsWindow = "lyrics-window"
        /// 只在这台 Mac 此刻有触控栏时画出来;放着不画、也不进「可添加」。
        case touchBar = "touchbar"
        case lyricsManager = "lyrics-manager"
        case translation
        case romanization
        case lockPosition = "lock-position"
        case favorite
        case shuffle
        case repeatMode = "repeat"
    }

    public enum Size: String, CaseIterable, Sendable {
        case small, medium, large

        /// 一排 `rowUnits` 份:小 3(一排四个)、中 4(一排三个)、大 8(两个中号那么宽)。
        public var units: Int {
            switch self {
            case .small: return 3
            case .medium: return 4
            case .large: return 8
            }
        }

        /// 编辑时点尺寸角标的下一档。
        public var next: Size {
            switch self {
            case .small: return .medium
            case .medium: return .large
            case .large: return .small
            }
        }
    }

    public struct Slot: Equatable, Hashable, Sendable {
        public var tile: Tile
        public var size: Size
        public init(tile: Tile, size: Size) {
            self.tile = tile
            self.size = size
        }
    }

    /// 底部那一排能藏的几项。「编辑」那一颗不在这里:它是改回来的唯一入口,不许藏。
    public enum FooterItem: String, CaseIterable, Sendable {
        case settings, lastfm, version
    }

    public static let rowUnits = 12

    public var slots: [Slot]
    public var hiddenFooter: Set<FooterItem>

    public init(slots: [Slot], hiddenFooter: Set<FooterItem> = []) {
        var seen = Set<Tile>()
        self.slots = slots.filter { seen.insert($0.tile).inserted }
        self.hiddenFooter = hiddenFooter
    }

    public static let `default` = MenuBarPanelLayout(
        slots: [Tile.overlay, .notch, .menuBar, .lyricsWindow, .touchBar, .lyricsManager]
            .map { Slot(tile: $0, size: .medium) })

    public var tiles: [Tile] { slots.map(\.tile) }

    public func contains(_ tile: Tile) -> Bool { slots.contains { $0.tile == tile } }

    public func size(of tile: Tile) -> Size? { slots.first { $0.tile == tile }?.size }

    /// 「可添加」那一栏:不在网格里、此刻能用的格子,按 `Tile.allCases` 的顺序。
    public func addable(available: (Tile) -> Bool) -> [Tile] {
        Tile.allCases.filter { !contains($0) && available($0) }
    }

    public mutating func remove(_ tile: Tile) {
        slots.removeAll { $0.tile == tile }
    }

    /// 加到最后,中号。已经在网格里就不动。
    public mutating func add(_ tile: Tile, size: Size = .medium) {
        guard !contains(tile) else { return }
        slots.append(Slot(tile: tile, size: size))
    }

    public mutating func setSize(_ size: Size, for tile: Tile) {
        guard let i = slots.firstIndex(where: { $0.tile == tile }) else { return }
        slots[i].size = size
    }

    /// 拖动中指针进了 `target` 那一格:被拖的格子挪到 `target` 现在的位置,中间的依次让一位。
    public mutating func move(_ tile: Tile, onto target: Tile) {
        guard tile != target,
              let from = slots.firstIndex(where: { $0.tile == tile }),
              let to = slots.firstIndex(where: { $0.tile == target }) else { return }
        let slot = slots.remove(at: from)
        slots.insert(slot, at: to)
    }

    public mutating func setFooter(_ item: FooterItem, shown: Bool) {
        if shown { hiddenFooter.remove(item) } else { hiddenFooter.insert(item) }
    }

    /// 按顺序装排:这一排放不下下一格就换行。没排满的一排由视图按份数等比撑满。
    public static func rows(_ slots: [Slot]) -> [[Slot]] {
        rowRanges(units: slots.map(\.size.units)).map { Array(slots[$0]) }
    }

    /// 同 `rows`,只按份数排,返回每一排的下标区间(视图的 `Layout` 用它)。
    public static func rowRanges(units: [Int]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var used = 0
        for (i, u) in units.enumerated() {
            if i > start, used + u > rowUnits {
                ranges.append(start..<i)
                start = i
                used = 0
            }
            used += u
        }
        if start < units.count { ranges.append(start..<units.count) }
        return ranges
    }

    /// 一排里每一格的宽:扣掉间距后按份数分。没排满的一排同样分满整行(默认布局第二排两格各占一半就是这么来的)。
    public static func widths(units: [Int], rowWidth: CGFloat, spacing: CGFloat) -> [CGFloat] {
        let total = units.reduce(0, +)
        guard total > 0 else { return [] }
        let usable = max(0, rowWidth - spacing * CGFloat(units.count - 1))
        return units.map { usable * CGFloat($0) / CGFloat(total) }
    }

    // MARK: 存盘

    private struct Stored: Codable {
        struct StoredSlot: Codable {
            var id: String
            var size: String?
        }
        var tiles: [StoredSlot]
        var hiddenFooter: [String]?
    }

    public func encoded() -> String {
        let stored = Stored(
            tiles: slots.map { Stored.StoredSlot(id: $0.tile.rawValue, size: $0.size.rawValue) },
            hiddenFooter: FooterItem.allCases.filter { hiddenFooter.contains($0) }.map(\.rawValue))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored), let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    public static func decode(_ json: String?) -> MenuBarPanelLayout {
        guard let data = json?.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .default }
        let slots = stored.tiles.compactMap { raw -> Slot? in
            guard let tile = Tile(rawValue: raw.id) else { return nil }
            return Slot(tile: tile, size: raw.size.flatMap(Size.init(rawValue:)) ?? .medium)
        }
        let footer = Set((stored.hiddenFooter ?? []).compactMap(FooterItem.init(rawValue:)))
        return MenuBarPanelLayout(slots: slots, hiddenFooter: footer)
    }
}

/// 编辑面板时拖动格子的判定:指针此刻落在哪一格上、要不要换位。
public enum PanelGridDrag {
    /// 指针进了另一格才换位;还停在上一次换过位的那一格里不再换。大小不一的格子换位后指针常常落在
    /// 刚让过来的那一格上,不加这一条会在两格之间来回换。
    /// - frames:各格此刻的位置(同一坐标系)。
    /// - lastTarget:上一次换位时指针进的那一格,指针离开它之后清空(由调用方按返回值更新)。
    /// 返回 (要换到哪一格, 新的 lastTarget)。
    public static func step<ID: Hashable>(pointer: CGPoint, dragged: ID, frames: [ID: CGRect],
                                          lastTarget: ID?) -> (moveOnto: ID?, lastTarget: ID?) {
        let hit = frames.first { $0.key != dragged && $0.value.contains(pointer) }?.key
        guard let hit else {
            // 指针在格子之间的缝里或者回到自己那一格:上一次进的那格已经离开了。
            return (nil, nil)
        }
        if hit == lastTarget { return (nil, lastTarget) }
        return (hit, hit)
    }
}
