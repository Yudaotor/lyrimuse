import Foundation
import CoreGraphics

/// 菜单栏左键面板的格子布局,照 macOS 控制中心:一排 4 个正方形坑位,每个格子占定一块(左上角在第几列第几行、多大),
/// 中间可以空着;底栏藏了哪几项。见 06 章决策 82、84、85。
///
/// 存成一串 JSON(`encoded()` / `decode(_:)`)。认不出的格子丢掉、认不出的尺寸退回中号、重复的留第一个、
/// 跟前面重叠或出了边界的挪到第一个放得下的空位;整串读不出来才退回默认。早先按顺序排、没有坑位的那种存法
/// (没有 col / row)和网格列数不同的那几版存法(`grid` 不是 4)都按原来的先后依次放进第一个放得下的空位。
public struct MenuBarPanelLayout: Equatable, Sendable {
    /// 能放进网格的格子。rawValue 是存盘和深链里的写法,别改。
    public enum Tile: String, CaseIterable, Sendable {
        /// 正在播放卡(封面、歌名、进度、走带),同控制中心的「正在播放」模块。
        case nowPlaying = "now-playing"
        case overlay
        case notch
        case menuBar = "menubar"
        case lyricsWindow = "lyrics-window"
        /// 只在这台 Mac 此刻有触控栏时画出来;没有时坑位照占着,也不进「可添加」。
        case touchBar = "touchbar"
        case lyricsManager = "lyrics-manager"
        case translation
        case romanization
        case lockPosition = "lock-position"

        /// 这一格能用哪几档。正在播放卡只有大号(2×2,同控制中心那块)和加宽(4×2,完整的卡片),别的格子小、中、大。
        public var sizes: [Size] {
            self == .nowPlaying ? [.large, .wide] : [.small, .medium, .large]
        }

        /// 「可添加」点进来时用哪一档。
        public var defaultSize: Size { self == .nowPlaying ? .wide : .medium }
    }

    /// 小 1×1(圆)、中 2×1(胶囊)、大 2×2、加宽 4×2(列 × 行),同控制中心。加宽只给正在播放卡。
    public enum Size: String, CaseIterable, Sendable {
        case small, medium, large, wide

        public var columns: Int {
            switch self {
            case .small: return 1
            case .medium, .large: return 2
            case .wide: return 4
            }
        }

        public var rows: Int { self == .large || self == .wide ? 2 : 1 }
    }

    public struct Placement: Equatable, Hashable, Sendable {
        public var tile: Tile
        public var size: Size
        public var column: Int
        public var row: Int
        public init(tile: Tile, size: Size, column: Int, row: Int) {
            self.tile = tile
            self.size = size
            self.column = column
            self.row = row
        }

        func covers(column c: Int, row r: Int) -> Bool {
            (column..<column + size.columns).contains(c) && (row..<row + size.rows).contains(r)
        }

        func overlaps(_ other: Placement) -> Bool {
            column < other.column + other.size.columns && other.column < column + size.columns
                && row < other.row + other.size.rows && other.row < row + size.rows
        }
    }

    /// 底部那一排能藏的几项。「编辑」那一颗不在这里:它是改回来的唯一入口,不许藏。
    public enum FooterItem: String, CaseIterable, Sendable {
        case settings, lastfm, version
    }

    public static let columns = 4

    public private(set) var placements: [Placement]
    public var hiddenFooter: Set<FooterItem>

    /// 重复的格子留第一个;出了边界、或跟前面的重叠的,挪到第一个放得下的空位。
    public init(placements: [Placement], hiddenFooter: Set<FooterItem> = []) {
        self.placements = []
        self.hiddenFooter = hiddenFooter
        for p in placements where !contains(p.tile) {
            if fits(p, ignoring: nil) {
                self.placements.append(p)
            } else {
                add(p.tile, size: p.size)
            }
        }
    }

    /// 默认:最上面是加宽的正在播放卡(跟原来面板顶上那张一样);下面照控制中心左上角那一块 —— 三种歌词展示形态是同级的
    /// 三个开关,竖着排成左边一列胶囊(同 Wi‑Fi、蓝牙、隔空投送),右边歌词窗口、歌词管理两个圆一排,触控栏歌词的圆在下面
    /// (没有触控栏时那个坑位空着)。
    public static let `default` = MenuBarPanelLayout(placements: [
        Placement(tile: .nowPlaying, size: .wide, column: 0, row: 0),
        Placement(tile: .overlay, size: .medium, column: 0, row: 2),
        Placement(tile: .notch, size: .medium, column: 0, row: 3),
        Placement(tile: .menuBar, size: .medium, column: 0, row: 4),
        Placement(tile: .lyricsWindow, size: .small, column: 2, row: 2),
        Placement(tile: .lyricsManager, size: .small, column: 3, row: 2),
        Placement(tile: .touchBar, size: .small, column: 2, row: 3),
    ])

    public var tiles: [Tile] { placements.map(\.tile) }

    public func contains(_ tile: Tile) -> Bool { placements.contains { $0.tile == tile } }

    public func placement(of tile: Tile) -> Placement? { placements.first { $0.tile == tile } }

    public func size(of tile: Tile) -> Size? { placement(of: tile)?.size }

    /// 占到第几行为止(行数)。`including` 只数这几格(面板平时只数画得出来的格子,没画的那几排收起来)。
    public func rowCount(including: (Tile) -> Bool = { _ in true }) -> Int {
        placements.filter { including($0.tile) }.map { $0.row + $0.size.rows }.max() ?? 0
    }

    /// 这个位置放不放得下:不出左右边界、行不为负,不跟别的格子(`ignoring` 那一格除外)重叠。
    public func fits(_ p: Placement, ignoring: Tile?) -> Bool {
        guard p.column >= 0, p.row >= 0, p.column + p.size.columns <= Self.columns else { return false }
        return !placements.contains { $0.tile != ignoring && $0.tile != p.tile && $0.overlaps(p) }
    }

    public func isEmpty(column: Int, row: Int) -> Bool {
        !placements.contains { $0.covers(column: column, row: row) }
    }

    /// 编辑时画空坑位(淡圆)的地方:空着的每一格。
    public func emptySlots(rows: Int) -> [(column: Int, row: Int)] {
        var out: [(Int, Int)] = []
        for row in 0..<max(rows, 0) {
            for column in Swift.stride(from: 0, to: Self.columns, by: Size.small.columns)
            where (column..<column + Size.small.columns).allSatisfy({ isEmpty(column: $0, row: row) }) {
                out.append((column, row))
            }
        }
        return out
    }

    /// 「可添加」那一栏:不在网格里、此刻能用的格子,按 `Tile.allCases` 的顺序。
    public func addable(available: (Tile) -> Bool) -> [Tile] {
        Tile.allCases.filter { !contains($0) && available($0) }
    }

    public mutating func remove(_ tile: Tile) {
        placements.removeAll { $0.tile == tile }
    }

    /// 放进第一个放得下的空位(从上到下、从左到右);现有几排里放不下就放到最下面新起一排。已经在网格里就不动;
    /// 这一格没有这一档就用它的默认档。
    public mutating func add(_ tile: Tile, size: Size? = nil) {
        guard !contains(tile) else { return }
        let wanted = size ?? tile.defaultSize
        placements.append(firstFit(tile, size: tile.sizes.contains(wanted) ? wanted : tile.defaultSize))
    }

    private func firstFit(_ tile: Tile, size: Size) -> Placement {
        let rows = rowCount()
        for row in 0...rows {
            for column in 0...(Self.columns - size.columns) {
                let p = Placement(tile: tile, size: size, column: column, row: row)
                if fits(p, ignoring: nil) { return p }
            }
        }
        return Placement(tile: tile, size: size, column: 0, row: rows)
    }

    /// 拖动松手要落到哪里:左上角对准 (column, row)。空着就直接放;正好压在一个同尺寸的格子上就两格互换;
    /// 都不行返回 nil(弹回原位)。左右越界的先夹回网格里。
    public func dropTarget(for tile: Tile, column: Int, row: Int) -> (placement: Placement, swapWith: Tile?)? {
        guard let current = placement(of: tile) else { return nil }
        let clamped = Placement(tile: tile, size: current.size,
                                column: min(max(column, 0), Self.columns - current.size.columns),
                                row: max(row, 0))
        if clamped.column == current.column, clamped.row == current.row { return nil }
        if fits(clamped, ignoring: nil) { return (clamped, nil) }
        let hit = placements.filter { $0.tile != tile && $0.overlaps(clamped) }
        guard hit.count == 1, let other = hit.first, other.size == current.size,
              other.column == clamped.column, other.row == clamped.row else { return nil }
        return (clamped, other.tile)
    }

    /// 执行 `dropTarget` 给出的落点。落不下返回 false、布局不变。
    @discardableResult
    public mutating func move(_ tile: Tile, toColumn column: Int, row: Int) -> Bool {
        guard let current = placement(of: tile), let target = dropTarget(for: tile, column: column, row: row) else {
            return false
        }
        if let other = target.swapWith, let j = placements.firstIndex(where: { $0.tile == other }) {
            placements[j].column = current.column
            placements[j].row = current.row
        }
        guard let i = placements.firstIndex(where: { $0.tile == tile }) else { return false }
        placements[i] = target.placement
        return true
    }

    /// 换尺寸:左上角不动;右边放不下(出界或压到别的格子)就往左挪,挪到放得下为止。这一格没有这一档、或都放不下,
    /// 返回 false、布局不变。
    @discardableResult
    public mutating func resize(_ tile: Tile, to size: Size) -> Bool {
        guard tile.sizes.contains(size), let i = placements.firstIndex(where: { $0.tile == tile }) else { return false }
        let current = placements[i]
        guard current.size != size else { return true }
        for column in stride(from: current.column, through: 0, by: -1) {
            let p = Placement(tile: tile, size: size, column: column, row: current.row)
            if fits(p, ignoring: tile) {
                placements[i] = p
                return true
            }
        }
        return false
    }

    public mutating func setFooter(_ item: FooterItem, shown: Bool) {
        if shown { hiddenFooter.remove(item) } else { hiddenFooter.insert(item) }
    }

    // MARK: 存盘

    private struct Stored: Codable {
        struct StoredTile: Codable {
            var id: String
            var size: String?
            var col: Int?
            var row: Int?
        }
        var tiles: [StoredTile]
        var hiddenFooter: [String]?
        /// 网格一排几列。不是现在这个数的(没有这个键的按顺序存法,或 6 列那一版)坑位不作数。
        var grid: Int?
        /// 2 起正在播放卡也是网格里的一格;更早的存法里没有它,读回来时补在最上面。
        var version: Int?
    }

    public func encoded() -> String {
        let stored = Stored(
            tiles: placements.map {
                Stored.StoredTile(id: $0.tile.rawValue, size: $0.size.rawValue, col: $0.column, row: $0.row)
            },
            hiddenFooter: FooterItem.allCases.filter { hiddenFooter.contains($0) }.map(\.rawValue),
            grid: Self.columns, version: Self.storageVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored), let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    static let storageVersion = 2

    public static func decode(_ json: String?) -> MenuBarPanelLayout {
        guard let data = json?.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .default }
        var layout = decodePlacements(stored)
        // 正在播放卡变成格子之前存下的布局:卡片原来固定在网格上面,补回最上面(加宽),别的格子整体往下挪两排。
        if (stored.version ?? 1) < storageVersion, !layout.contains(.nowPlaying) {
            let shifted = layout.placements.map {
                Placement(tile: $0.tile, size: $0.size, column: $0.column, row: $0.row + Size.wide.rows)
            }
            layout.placements = [Placement(tile: .nowPlaying, size: .wide, column: 0, row: 0)] + shifted
        }
        return layout
    }

    private static func decodePlacements(_ stored: Stored) -> MenuBarPanelLayout {
        let footer = Set((stored.hiddenFooter ?? []).compactMap(FooterItem.init(rawValue:)))
        var layout = MenuBarPanelLayout(placements: [], hiddenFooter: footer)
        guard stored.grid == Self.columns else {
            // 列数不同的存法:坑位不作数,按原来的先后(有坑位的按从上到下、从左到右)依次放进第一个空位。按顺序排的那种
            // 尺寸按长相换:它的中号、小号都是图标在上、名字在下的方块 = 现在的小号,大号是宽条 = 中号。
            let ordered = stored.tiles.enumerated().sorted {
                ($0.element.row ?? 0, $0.element.col ?? 0, $0.offset) < ($1.element.row ?? 0, $1.element.col ?? 0, $1.offset)
            }.map(\.element)
            for raw in ordered {
                guard let tile = Tile(rawValue: raw.id) else { continue }
                let size: Size? = raw.col == nil
                    ? (raw.size == "large" ? .medium : .small)
                    : raw.size.flatMap(Size.init(rawValue:))
                layout.add(tile, size: size)
            }
            return layout
        }
        for raw in stored.tiles {
            guard let tile = Tile(rawValue: raw.id), !layout.contains(tile) else { continue }
            let storedSize = raw.size.flatMap(Size.init(rawValue:))
            let size = storedSize.flatMap { tile.sizes.contains($0) ? $0 : nil } ?? tile.defaultSize
            let p = Placement(tile: tile, size: size, column: raw.col ?? -1, row: raw.row ?? -1)
            if layout.fits(p, ignoring: nil) {
                layout.placements.append(p)
            } else {
                layout.add(tile, size: size)
            }
        }
        return layout
    }
}

/// 面板网格的几何:列宽、行高、间距,格子在哪、拖着的格子对准哪个坑位、拖右下角落到哪一档。
public struct PanelGridGeometry: Equatable, Sendable {
    public var width: CGFloat
    public var rowHeight: CGFloat
    public var spacing: CGFloat

    public init(width: CGFloat, rowHeight: CGFloat, spacing: CGFloat) {
        self.width = width
        self.rowHeight = rowHeight
        self.spacing = spacing
    }

    /// 一列多宽(列之间隔 `spacing`)。
    public var column: CGFloat {
        (width - spacing * CGFloat(MenuBarPanelLayout.columns - 1)) / CGFloat(MenuBarPanelLayout.columns)
    }

    public var columnStride: CGFloat { column + spacing }
    public var rowStride: CGFloat { rowHeight + spacing }

    public func height(rows: Int) -> CGFloat {
        rows > 0 ? CGFloat(rows) * rowStride - spacing : 0
    }

    public func size(_ s: MenuBarPanelLayout.Size) -> CGSize {
        CGSize(width: CGFloat(s.columns) * columnStride - spacing, height: CGFloat(s.rows) * rowStride - spacing)
    }

    public func frame(column c: Int, row: Int, size s: MenuBarPanelLayout.Size) -> CGRect {
        CGRect(origin: CGPoint(x: CGFloat(c) * columnStride, y: CGFloat(row) * rowStride), size: size(s))
    }

    public func frame(_ p: MenuBarPanelLayout.Placement) -> CGRect {
        frame(column: p.column, row: p.row, size: p.size)
    }

    /// 拖着的格子左上角此刻在 `origin`,对准的是哪个坑位(四舍五入到最近的列和行)。
    public func nearestCell(to origin: CGPoint) -> (column: Int, row: Int) {
        (Int((origin.x / columnStride).rounded()), Int((origin.y / rowStride).rounded()))
    }

    /// 拖右下角时指针在 `pointer`、格子左上角在 `origin`:落到这一格能用的几档里,右下角离指针最近的那一档。
    public func resizedSize(origin: CGPoint, pointer: CGPoint,
                            allowed: [MenuBarPanelLayout.Size]) -> MenuBarPanelLayout.Size {
        let dx = pointer.x - origin.x, dy = pointer.y - origin.y
        return allowed.min {
            let a = size($0), b = size($1)
            return abs(a.width - dx) + abs(a.height - dy) < abs(b.width - dx) + abs(b.height - dy)
        } ?? .small
    }
}
