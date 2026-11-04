import Foundation
import CoreGraphics

/// 菜单栏左键面板的格子布局,照 macOS 控制中心的摆法:网格一排 6 列,每个格子占定一块(左上角在第几列第几行、多大),
/// 中间可以空着;底栏藏了哪几项。6 列是为了一排正好放 3 个小号或 2 个中号(这块面板原来的两排就是这样)。正在播放卡也是
/// 其中一格。见 06 章决策 82、84、86、87。
///
/// 存成一串 JSON(`encoded()` / `decode(_:)`)。认不出的格子丢掉、认不出的尺寸退回中号、重复的留第一个、
/// 跟前面重叠或出了边界的挪到第一个放得下的空位;整串读不出来才退回默认。早先按顺序排、没有坑位的那种存法
/// (没有 col / row)和 4 列网格那一版的存法(没有 `grid: 6`)都按原来的先后依次放进第一个放得下的空位。卡片还不是格子时的
/// 存法(没有 `version: 2`)读回来把卡片补在最上面,别的格子整体往下挪两排。
public struct MenuBarPanelLayout: Equatable, Sendable {
    /// 能放进网格的格子。rawValue 是存盘和深链里的写法,别改。
    /// 只收会经常拿出来切的开关和动作;配一次就不再动的设置不做成格子(见 06 章决策 89)。
    public enum Tile: String, CaseIterable, Sendable {
        /// 正在播放卡:封面、歌名、歌词行、进度、走带。
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
        case hideAllLyrics = "hide-all-lyrics"
        case searchLyrics = "search-lyrics"
        case miniWindow = "mini-window"
        case fontLarger = "font-larger"
        case fontSmaller = "font-smaller"
        /// 早先按顺序排的存法里有个 `favorite`(已挪进走带一排、读到丢掉),这一格另起 `like`,别复用那个写法。
        case like
        case openPlayer = "open-player"
        case lyricsAdvance = "lyrics-advance"
        case lyricsDelay = "lyrics-delay"
        case lyricsOffsetReset = "lyrics-offset-reset"

        /// 「可添加」面板里归哪一组(按显示方式分)。
        public var group: TileGroup {
            switch self {
            case .nowPlaying, .like, .openPlayer: return .nowPlaying
            case .overlay, .lockPosition, .fontLarger, .fontSmaller: return .overlay
            case .notch: return .notch
            case .menuBar: return .menuBar
            case .lyricsWindow, .miniWindow: return .lyricsWindow
            case .touchBar: return .touchBar
            case .lyricsManager, .translation, .romanization, .hideAllLyrics, .searchLyrics, .lyricsAdvance, .lyricsDelay,
                 .lyricsOffsetReset:
                return .lyrics
            }
        }

        /// 这一格能用哪几档:正在播放卡只有大号(3×2,封面、歌名和三个走带键)和加宽(6×2,完整的卡片),别的格子小、中、大。
        public var sizes: [Size] {
            self == .nowPlaying ? [.large, .wide] : [.small, .medium, .large]
        }

        /// 要的那一档这一格没有时用哪一档。
        public var defaultSize: Size { self == .nowPlaying ? .wide : .medium }

        public func fitting(_ size: Size) -> Size { sizes.contains(size) ? size : defaultSize }
    }

    /// 「可添加」面板的分组,按这个顺序摆。见 06 章决策 89。
    public enum TileGroup: String, CaseIterable, Sendable {
        case nowPlaying, overlay, notch, menuBar, lyricsWindow, touchBar, lyrics
    }

    /// 小占 2 列(一排 3 个)、中占 3 列(一排 2 个)、大占 3 列 2 行,加宽占满一排 6 列、2 行(只给正在播放卡)。
    public enum Size: String, CaseIterable, Sendable {
        case small, medium, large, wide

        public var columns: Int {
            switch self {
            case .small: return 2
            case .medium, .large: return 3
            case .wide: return 6
            }
        }

        public var rows: Int { self == .large || self == .wide ? 2 : 1 }

        /// 这一档的格子左边能落在哪几列:小号 0 / 2 / 4(一排三个),中号、大号 0 / 3(一排两个),加宽 0。只落在这几列上,
        /// 挤来挤去也不会错开半格。
        public var alignedColumns: [Int] {
            Array(Swift.stride(from: 0, through: MenuBarPanelLayout.columns - columns, by: columns))
        }

        /// 离 `column` 最近的那一列(一样近取左边的)。
        public func alignedColumn(near column: Int) -> Int {
            alignedColumns.min { abs($0 - column) < abs($1 - column) } ?? 0
        }
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

    /// 底栏能放的几项,按用户排的顺序摆。「编辑」那一颗不在这里:它是改回来的唯一入口,不许藏。见 06 章决策 90。
    public enum FooterItem: String, CaseIterable, Sendable {
        case settings, lastfm, version
        case whatsNew = "whats-new"
        case feedback, about, quit
    }

    /// 底栏一排最多几项(「编辑」那颗另算)。
    public static let maxFooterItems = 5
    public static let defaultFooter: [FooterItem] = [.settings, .lastfm, .version]

    public static let columns = 6
    /// 存盘格式版本:2 起正在播放卡是格子。
    static let storageVersion = 2

    public private(set) var placements: [Placement]
    /// 底栏按顺序摆哪几项。
    public private(set) var footer: [FooterItem]

    /// 重复的格子留第一个;这一格没有的那一档换成它的默认档;出了边界、或跟前面的重叠的,挪到第一个放得下的空位。
    /// 底栏重复的留第一个,超过 `maxFooterItems` 的丢掉。
    public init(placements: [Placement], footer: [FooterItem] = MenuBarPanelLayout.defaultFooter) {
        self.placements = []
        var seen: Set<FooterItem> = []
        self.footer = Array(footer.filter { seen.insert($0).inserted }.prefix(Self.maxFooterItems))
        for var p in placements where !contains(p.tile) {
            p.size = p.tile.fitting(p.size)
            if fits(p, ignoring: nil) {
                self.placements.append(p)
            } else {
                add(p.tile, size: p.size)
            }
        }
    }

    /// 默认就是这块面板原来的样子:最上面加宽的正在播放卡,下面悬浮歌词、灵动岛、菜单栏歌词一排三个小号,歌词窗口、
    /// 歌词管理一排两个中号。触控栏歌词单起一排(没有触控栏时这一排收起,跟原来一模一样)。
    public static let `default` = MenuBarPanelLayout(placements: [
        Placement(tile: .nowPlaying, size: .wide, column: 0, row: 0),
        Placement(tile: .overlay, size: .small, column: 0, row: 2),
        Placement(tile: .notch, size: .small, column: 2, row: 2),
        Placement(tile: .menuBar, size: .small, column: 4, row: 2),
        Placement(tile: .lyricsWindow, size: .medium, column: 0, row: 3),
        Placement(tile: .lyricsManager, size: .medium, column: 3, row: 3),
        Placement(tile: .touchBar, size: .small, column: 0, row: 4),
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

    /// 编辑时画空坑位的地方:每一个空着的单格(一排 6 格)。
    public func emptySlots(rows: Int) -> [(column: Int, row: Int)] {
        var out: [(Int, Int)] = []
        for row in 0..<max(rows, 0) {
            for column in 0..<Self.columns where isEmpty(column: column, row: row) {
                out.append((column, row))
            }
        }
        return out
    }

    /// 「可添加」那一栏:不在网格里、此刻能用的格子,按 `Tile.allCases` 的顺序。
    public func addable(available: (Tile) -> Bool) -> [Tile] {
        Tile.allCases.filter { !contains($0) && available($0) }
    }

    /// 「可添加」按组排好:组按 `TileGroup.allCases`,组里按 `Tile.allCases`,空组不要。
    public func addableGroups(available: (Tile) -> Bool) -> [(group: TileGroup, tiles: [Tile])] {
        let tiles = addable(available: available)
        return TileGroup.allCases.compactMap { group in
            let inGroup = tiles.filter { $0.group == group }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }

    public mutating func remove(_ tile: Tile) {
        placements.removeAll { $0.tile == tile }
    }

    /// 拿掉 `tile` 的一份(这台 Mac 此刻用不了的格子,编辑时不画、不占坑位)。
    public func without(_ tile: Tile) -> MenuBarPanelLayout {
        var layout = self
        layout.remove(tile)
        return layout
    }

    /// 把编辑前拿掉的那一格放回原位;原位已经被别的格子占了、或已经在网格里,就不放(它回到「可添加」)。
    public func restoring(_ placement: Placement?) -> MenuBarPanelLayout {
        guard let placement, !contains(placement.tile), fits(placement, ignoring: nil) else { return self }
        var layout = self
        layout.placements.append(placement)
        return layout
    }

    /// 放进第一个放得下的空位(从上到下、从左到右);现有几排里放不下就放到最下面新起一排。已经在网格里就不动;
    /// 这一格没有这一档就用它的默认档。
    public mutating func add(_ tile: Tile, size: Size = .medium) {
        guard !contains(tile) else { return }
        placements.append(firstFit(tile, size: tile.fitting(size), fromRow: 0, column: 0))
    }

    /// 从 (row, column) 起往后(从左到右、从上到下)找第一个对得齐、放得下的位置;现有几排里都没有就新起一排。
    private func firstFit(_ tile: Tile, size: Size, fromRow startRow: Int, column startColumn: Int) -> Placement {
        let rows = rowCount()
        for row in max(startRow, 0)...max(rows, startRow) {
            for column in size.alignedColumns where row > startRow || column >= startColumn {
                let p = Placement(tile: tile, size: size, column: column, row: row)
                if fits(p, ignoring: nil) { return p }
            }
        }
        return Placement(tile: tile, size: size, column: 0, row: max(rows, startRow + 1))
    }

    /// 把 `tile` 以 `size` 放到左上角 (column, row)(列对齐到这一档能落的那几列),压到的格子让开:其余格子按从上到下、
    /// 从左到右的先后,原位放得下就不动,放不下的往后挪到第一个对得齐的空位,后面的跟着顺延(同控制中心编辑时的挤位)。
    /// `tile` 不在网格里就是新加进来。`swap`(拖动用;换尺寸不用):正好压在一个同尺寸、左上角对齐的格子上,而那一格放得进
    /// `tile` 原来的位置时两格互换,不往后挤;别的压到的格子先按跟落点的相对位置搬进 `tile` 空出来的那块(整块落在里面、
    /// 放得下才搬),搬不进的再往后顺延 —— 把加宽的卡片往下拖两排,就是卡片跟那两排整块对调。见 06 章决策 87。
    public func placing(_ tile: Tile, size wanted: Size, column: Int, row: Int, swap: Bool = false) -> MenuBarPanelLayout {
        let size = tile.fitting(wanted)
        let target = Placement(tile: tile, size: size, column: size.alignedColumn(near: column), row: max(row, 0))
        let others = placements.filter { $0.tile != tile }
        if swap, let current = placement(of: tile) {
            let hit = others.filter { $0.overlaps(target) }
            if hit.count == 1, let other = hit.first, other.size == size,
               other.column == target.column, other.row == target.row {
                var swapped = self
                for i in swapped.placements.indices {
                    if swapped.placements[i].tile == tile { swapped.placements[i] = target }
                    if swapped.placements[i].tile == other.tile {
                        swapped.placements[i].column = current.column
                        swapped.placements[i].row = current.row
                    }
                }
                return swapped
            }
        }
        let vacated = swap ? placement(of: tile) : nil
        var result = MenuBarPanelLayout(placements: [], footer: footer)
        result.placements = [target]
        for p in others.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            if result.fits(p, ignoring: nil) {
                result.placements.append(p)
                continue
            }
            if let vacated {
                let moved = Placement(tile: p.tile, size: p.size, column: p.column - target.column + vacated.column,
                                      row: p.row - target.row + vacated.row)
                if moved.column >= vacated.column, moved.row >= vacated.row,
                   moved.column + moved.size.columns <= vacated.column + vacated.size.columns,
                   moved.row + moved.size.rows <= vacated.row + vacated.size.rows,
                   result.fits(moved, ignoring: nil) {
                    result.placements.append(moved)
                    continue
                }
            }
            result.placements.append(result.firstFit(p.tile, size: p.size, fromRow: p.row, column: p.column))
        }
        // 存的先后照原来的,新加进来的放最后。
        var order: [Tile: Int] = [:]
        for (i, t) in (placements.map(\.tile) + [tile]).enumerated() where order[t] == nil { order[t] = i }
        result.placements.sort { (order[$0.tile] ?? 0) < (order[$1.tile] ?? 0) }
        return result
    }

    /// 拖动松手:落到 (column, row),压到的格子让开(同尺寸对齐的两格互换)。原地不动返回 false。
    @discardableResult
    public mutating func move(_ tile: Tile, toColumn column: Int, row: Int) -> Bool {
        guard let current = placement(of: tile) else { return false }
        let moved = placing(tile, size: current.size, column: column, row: row, swap: true)
        guard moved != self else { return false }
        self = moved
        return true
    }

    /// 换尺寸:左上角尽量不动(列对齐到这一档能落的那几列里最近的),压到的格子让开、往后顺延。这一格没有这一档返回 false。
    @discardableResult
    public mutating func resize(_ tile: Tile, to size: Size) -> Bool {
        guard tile.sizes.contains(size), let current = placement(of: tile) else { return false }
        guard current.size != size else { return true }
        self = placing(tile, size: size, column: current.column, row: current.row)
        return true
    }

    /// 底栏里没有的几项(「可添加」那块列它们)。
    public var addableFooter: [FooterItem] { FooterItem.allCases.filter { !footer.contains($0) } }

    /// 加到底栏最后;已经在、或底栏满了(`maxFooterItems`)就不加。
    public mutating func addFooter(_ item: FooterItem) {
        guard !footer.contains(item), footer.count < Self.maxFooterItems else { return }
        footer.append(item)
    }

    public mutating func removeFooter(_ item: FooterItem) {
        footer.removeAll { $0 == item }
    }

    /// 把 `item` 挪到 `other` 现在的位置(往右挪落在它后面,往左挪落在它前面)。
    public mutating func moveFooter(_ item: FooterItem, toPositionOf other: FooterItem) {
        guard item != other, let from = footer.firstIndex(of: item), let to = footer.firstIndex(of: other) else { return }
        footer.remove(at: from)
        footer.insert(item, at: to)
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
        /// 底栏按顺序摆的几项。没有这个键的是更早的存法:默认那三项去掉 `hiddenFooter` 里藏的。
        var footer: [String]?
        var hiddenFooter: [String]?
        /// 网格一排几列。没有这个键的是更早的存法(按顺序排的,或 4 列网格),坑位不作数。
        var grid: Int?
        /// 存盘格式版本(`storageVersion`)。没有的是正在播放卡还不是格子时存的。
        var version: Int?
    }

    public func encoded() -> String {
        let stored = Stored(
            tiles: placements.map {
                Stored.StoredTile(id: $0.tile.rawValue, size: $0.size.rawValue, col: $0.column, row: $0.row)
            },
            footer: footer.map(\.rawValue),
            hiddenFooter: nil,
            grid: Self.columns,
            version: Self.storageVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored), let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    public static func decode(_ json: String?) -> MenuBarPanelLayout {
        guard let data = json?.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .default }
        let hidden = Set((stored.hiddenFooter ?? []).compactMap(FooterItem.init(rawValue:)))
        let footer = stored.footer.map { $0.compactMap(FooterItem.init(rawValue:)) }
            ?? Self.defaultFooter.filter { !hidden.contains($0) }
        var layout = MenuBarPanelLayout(placements: [], footer: footer)
        guard stored.grid == Self.columns else {
            // 更早的存法:坑位不作数,按原来的先后(有坑位的按从上到下、从左到右)依次放进第一个空位。按顺序排的那种
            // 尺寸按长相换:它的中号、小号都是图标在上、名字在下的方块 = 现在的小号,大号是宽条 = 中号。
            let ordered = stored.tiles.enumerated().sorted {
                ($0.element.row ?? 0, $0.element.col ?? 0, $0.offset) < ($1.element.row ?? 0, $1.element.col ?? 0, $1.offset)
            }.map(\.element)
            layout.add(.nowPlaying)
            for raw in ordered {
                guard let tile = Tile(rawValue: raw.id) else { continue }
                let size: Size = raw.col == nil
                    ? (raw.size == "large" ? .medium : .small)
                    : (raw.size.flatMap(Size.init(rawValue:)) ?? .small)
                layout.add(tile, size: size)
            }
            return layout
        }
        // 正在播放卡还不是格子时存的:卡片补在最上面(加宽,跟原来一样),别的格子整体往下挪两排。这个版本以后存的没有卡片
        // 是用户自己移除的,不补。
        let shift = (stored.version ?? 1) < Self.storageVersion ? Size.wide.rows : 0
        if shift > 0 { layout.placements.append(Placement(tile: .nowPlaying, size: .wide, column: 0, row: 0)) }
        for raw in stored.tiles {
            guard let tile = Tile(rawValue: raw.id), !layout.contains(tile) else { continue }
            let size = tile.fitting(raw.size.flatMap(Size.init(rawValue:)) ?? .medium)
            let p = Placement(tile: tile, size: size, column: raw.col ?? -1, row: raw.row.map { $0 + shift } ?? -1)
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

    /// 菜单栏面板用的那一份:宽 316(面板 336 减两边各 10 的内边距),间距 9,行高取「两行高 = 三列宽」,大号(3×2)正好
    /// 是正方形,同控制中心的大块。小号约 99 × 72、中号约 153 × 72。见 06 章决策 88。
    public static let menuBarPanel: PanelGridGeometry = {
        let width: CGFloat = 316, spacing: CGFloat = 9
        let columns = CGFloat(MenuBarPanelLayout.columns)
        let column = (width - spacing * (columns - 1)) / columns
        let threeColumns = column * 3 + spacing * 2
        return PanelGridGeometry(width: width, rowHeight: (threeColumns - spacing) / 2, spacing: spacing)
    }()

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

    /// 拖右下角时指针在 `pointer`、格子左上角在 `origin`:往下过了一行和两行高度的中间是大号,往右过了小号和中号宽度的中间
    /// 是中号,其余小号。`allowed` 不是小、中、大三档(正在播放卡)时,挑右下角离指针最近的那一档。
    public func resizedSize(origin: CGPoint, pointer: CGPoint,
                            allowed: [MenuBarPanelLayout.Size] = [.small, .medium, .large]) -> MenuBarPanelLayout.Size {
        guard Set(allowed) == [.small, .medium, .large] else {
            func distance(_ s: MenuBarPanelLayout.Size) -> CGFloat {
                let corner = size(s)
                return hypot(pointer.x - origin.x - corner.width, pointer.y - origin.y - corner.height)
            }
            return allowed.min { distance($0) < distance($1) } ?? .small
        }
        let small = size(.small), medium = size(.medium), large = size(.large)
        if pointer.y - origin.y > (small.height + large.height) / 2 { return .large }
        return pointer.x - origin.x > (small.width + medium.width) / 2 ? .medium : .small
    }
}
