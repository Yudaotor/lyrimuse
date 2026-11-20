import Foundation
import CoreGraphics

// 菜单栏面板编辑模式和设置窗口「面板」组共用的编辑规则:编辑时拿掉此刻用不了的格子、写回时放回原位,编辑网格画几排,
// 拖着一格对准哪个坑位、挤好是什么样子,按在哪一格的拉手上,右键 / VoiceOver 的一步挪位。两边各写自己的手势和画法,
// 规则只在这里。见 06 章决策 111。

extension MenuBarPanelLayout {
    /// 拿掉 `available` 判为用不了的格子,连同它们原来的位置一起交回(写回时按原位放回)。
    public func splittingUnavailable(available: (Tile) -> Bool) -> (layout: MenuBarPanelLayout, hidden: [Placement]) {
        let hidden = placements.filter { !available($0.tile) }
        return (hidden.reduce(self) { $0.without($1.tile) }, hidden)
    }

    /// 编辑时改一次布局:先拿掉 `stored` 里此刻用不了的格子,在剩下的上面改,改完把它们放回原位(原位被占了就不放,
    /// 能用时它回到「可添加」)。`hiddenFrom`:用不了的格子按这份布局里的原位放回(拉拉手换尺寸时传开始拉那一刻的,
    /// 中间压到过的格子缩回去还能回来)。
    public static func edited(_ stored: MenuBarPanelLayout, hiddenFrom: MenuBarPanelLayout? = nil,
                              available: (Tile) -> Bool,
                              _ change: (inout MenuBarPanelLayout) -> Void) -> MenuBarPanelLayout {
        let split = stored.splittingUnavailable(available: available)
        let hidden = hiddenFrom.map { $0.splittingUnavailable(available: available).hidden } ?? split.hidden
        var layout = split.layout
        change(&layout)
        return hidden.reduce(layout) { $0.restoring($1) }
    }

    /// 编辑网格画几排:此刻画的(`shown`,拖动中是挤好的预览)和拖动开始那一刻的(`base`)取多的,最下面再多留一整排空位。
    public static func editingRows(shown: MenuBarPanelLayout, base: MenuBarPanelLayout) -> Int {
        max(shown.rowCount(), base.rowCount()) + 1
    }

    /// 拖着 `tile`(按 `size` 这一档)对准 `cell` 时挤好的样子:压到的格子让开、往后顺延,`swap` 时同尺寸对齐的两格互换
    /// (只对已经在网格里的格子)。`cell` 为 nil(拖出了网格):网格里的格子弹回原位,新格子不加(nil)。
    public func dragPreview(of tile: Tile, size: Size, at cell: (column: Int, row: Int)?, swap: Bool) -> MenuBarPanelLayout? {
        guard let cell else { return contains(tile) ? self : nil }
        return placing(tile, size: size, column: cell.column, row: cell.row, swap: swap && contains(tile))
    }

    /// 右键菜单 / VoiceOver 动作里一步挪位的方向。
    public enum NudgeDirection: String, CaseIterable, Sendable {
        case up, down, left, right
    }

    /// 一步挪位:左右挪一个格子宽(落在这一档对得齐的列上),上下挪一个格子高(往上最多挪到第一排),压到的格子让开,
    /// 跟拖动松手同一套挤位(同尺寸对齐的两格互换)。到了边上、或挪完跟原来一样,返回 false、不改。
    @discardableResult
    public mutating func nudge(_ tile: Tile, _ direction: NudgeDirection) -> Bool {
        guard let p = placement(of: tile) else { return false }
        var column = p.column
        var row = p.row
        switch direction {
        case .left: column -= p.size.columns
        case .right: column += p.size.columns
        case .up: row = max(row - p.size.rows, 0)
        case .down: row += p.size.rows
        }
        guard column >= 0, column + p.size.columns <= Self.columns, column != p.column || row != p.row else { return false }
        return move(tile, toColumn: column, row: row)
    }

    /// 这一步挪不挪得动(菜单项、VoiceOver 动作据此灰着或不列)。
    public func canNudge(_ tile: Tile, _ direction: NudgeDirection) -> Bool {
        var copy = self
        return copy.nudge(tile, direction)
    }

    /// 底栏里 `item` 往左(负)或往右(正)挪 `offset` 位。挪不动(到头了、不在底栏里)返回 false、不改。
    @discardableResult
    public mutating func nudgeFooter(_ item: FooterItem, by offset: Int) -> Bool {
        guard offset != 0, let from = footer.firstIndex(of: item), footer.indices.contains(from + offset) else { return false }
        moveFooter(item, toPositionOf: footer[from + offset])
        return true
    }
}

extension PanelGridGeometry {
    /// 按比例缩的一份:列宽、行高、间距一起缩,格子长宽比和面板上一样(设置窗口里那份缩小的面板网格)。
    public func scaled(_ factor: CGFloat) -> PanelGridGeometry {
        PanelGridGeometry(width: width * factor, rowHeight: rowHeight * factor, spacing: spacing * factor)
    }

    /// 拖着一格(左上角在 `origin`,网格坐标)对准的坑位:列对齐到 `size` 这一档能落的列,行不小于 0。指针出了网格左右
    /// `sideSlack` 以外,或格子拖到 `base` 最下面那排空位再往下,算拖出了网格(nil)。
    public func dragCell(base: MenuBarPanelLayout, size: MenuBarPanelLayout.Size, origin: CGPoint, pointer: CGPoint,
                         sideSlack: CGFloat = 10) -> (column: Int, row: Int)? {
        let cell = nearestCell(to: origin)
        let outside = origin.y > height(rows: base.rowCount() + 1) || pointer.x < -sideSlack || pointer.x > width + sideSlack
        return outside ? nil : (size.alignedColumn(near: cell.column), max(cell.row, 0))
    }

    /// 按在哪一格的拉手上(格子右下角 `side` 见方那一块),没有返回 nil。
    public func resizeHandleTile(at point: CGPoint, in layout: MenuBarPanelLayout, side: CGFloat) -> MenuBarPanelLayout.Tile? {
        layout.placements.first { p in
            let f = frame(p)
            return CGRect(x: f.maxX - side, y: f.maxY - side, width: side, height: side).contains(point)
        }?.tile
    }
}
