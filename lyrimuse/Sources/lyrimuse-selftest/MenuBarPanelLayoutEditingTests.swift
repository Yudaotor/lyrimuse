import Foundation
import CoreGraphics
import LyrimuseCore

// 菜单栏面板编辑规则抽成共用之后(Core `MenuBarPanelLayoutEditing.swift`,面板编辑模式和设置窗口「面板」组都走它):
//   1. 抽之前面板里那几段写法原样留在这里当参照,同一串随机操作两边逐步比 `encoded()`,一个字节不差;
//   2. 一步挪位、底栏挪位、缩小网格的几何;
//   3. 源码契约:面板和设置窗口都经共用入口改布局,设置窗口的右键菜单和 VoiceOver 动作是同一份清单、覆盖同样的操作。
// 见 06 章决策 111。

func checkMenuBarPanelLayoutEditing() {
    typealias L = MenuBarPanelLayout
    typealias Tile = MenuBarPanelLayout.Tile

    // ---- 1. 跟抽之前的面板写法逐字节比 ----

    func referenceWithoutUnavailable(_ layout: L, available: (Tile) -> Bool) -> (layout: L, hidden: [L.Placement]) {
        let hidden = layout.placements.filter { !available($0.tile) }
        return (hidden.reduce(layout) { $0.without($1.tile) }, hidden)
    }
    func referenceUpdate(_ stored: L, hiddenFrom: L?, available: (Tile) -> Bool, _ change: (inout L) -> Void) -> L {
        let split = referenceWithoutUnavailable(stored, available: available)
        let hidden = hiddenFrom.map { referenceWithoutUnavailable($0, available: available).hidden } ?? split.hidden
        var layout = split.layout
        change(&layout)
        layout = hidden.reduce(layout) { $0.restoring($1) }
        return layout
    }
    func referenceDrag(_ base: L, tile: Tile, size: L.Size, grid: PanelGridGeometry, pointer: CGPoint, grab: CGSize,
                       swap: Bool) -> (key: [Int], preview: L?) {
        let origin = CGPoint(x: pointer.x - grab.width, y: pointer.y - grab.height)
        let cell = grid.nearestCell(to: origin)
        let column = size.alignedColumn(near: cell.column)
        let outside = origin.y > grid.height(rows: base.rowCount() + 1) || pointer.x < -10 || pointer.x > grid.width + 10
        let key = outside ? [-1] : [column, max(cell.row, 0)]
        let preview: L? = outside
            ? (base.contains(tile) ? base : nil)
            : base.placing(tile, size: size, column: column, row: cell.row, swap: swap && base.contains(tile))
        return (key, preview)
    }
    func referenceHandle(_ layout: L, grid: PanelGridGeometry, at point: CGPoint, side: CGFloat) -> Tile? {
        layout.placements.first { p in
            let frame = grid.frame(p)
            return CGRect(x: frame.maxX - side, y: frame.maxY - side, width: side, height: side).contains(point)
        }?.tile
    }

    var seed: UInt64 = 0x5EED_0D06
    func next(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(max(bound, 1)))
    }
    let grid = PanelGridGeometry.menuBarPanel
    let tiles = Tile.allCases
    var stored = L.default
    stored.add(.todayListening, size: .bar)
    stored.add(.translation, size: .small)
    var mismatches: [String] = []
    var history: [L] = [stored]
    var dragMismatches = 0
    var handleMismatches = 0
    var rowsMismatches = 0
    var nonTrivial = 0
    for step in 0..<3000 {
        // 用不了的格子每隔一阵换一种:没有触控栏、没连 Last.fm、两样都没有、都有。
        let mode = (step / 50) % 4
        let available: (Tile) -> Bool = { tile in
            switch tile {
            case .touchBar: return mode == 3 || mode == 1
            case .todayListening: return mode == 3 || mode == 0
            default: return true
            }
        }
        let shown = stored.splittingUnavailable(available: available).layout
        if shown.encoded() != referenceWithoutUnavailable(stored, available: available).layout.encoded() {
            mismatches.append("第 \(step) 步拿掉用不了的格子")
        }
        let tile = tiles[next(tiles.count)]
        let size = tile.sizes[next(tile.sizes.count)]
        let change: (inout L) -> Void
        var hiddenFrom: L? = nil
        switch next(9) {
        case 0, 1:
            // 拖动松手:网格里的一格或新拖进来的一格,指针可能拖出网格。
            let dragSize = shown.size(of: tile) ?? tile.fitting(.small)
            // 竖直方向撒在网格高度再往下两排以内,拖出网格下沿那一带常落到。
            let reach = Int(grid.height(rows: shown.rowCount() + 2)) + 60
            let pointer = CGPoint(x: CGFloat(next(400)) - 40, y: CGFloat(next(reach)) - 20)
            let grab = CGSize(width: CGFloat(next(60)), height: CGFloat(next(40)))
            let swap = shown.contains(tile)
            let reference = referenceDrag(shown, tile: tile, size: dragSize, grid: grid, pointer: pointer, grab: grab, swap: swap)
            let origin = CGPoint(x: pointer.x - grab.width, y: pointer.y - grab.height)
            let cell = grid.dragCell(base: shown, size: dragSize, origin: origin, pointer: pointer)
            let key = cell.map { [$0.column, $0.row] } ?? [-1]
            let preview = shown.dragPreview(of: tile, size: dragSize, at: cell, swap: swap)
            if key != reference.key || preview?.encoded() != reference.preview?.encoded() { dragMismatches += 1 }
            change = { if let preview { $0 = preview } }
        case 2:
            change = { $0.resize(tile, to: size) }
        case 3:
            // 拉拉手:用不了的格子按开始拉那一刻的布局放回(取前几步的一份,原位可能已经被占)。
            hiddenFrom = history[max(history.count - 1 - next(6), 0)]
            change = { $0.resize(tile, to: size) }
        case 4:
            change = { $0.remove(tile) }
        case 5, 6:
            change = { $0.add(tile, size: .small) }
        case 7:
            let items = L.FooterItem.allCases
            let item = items[next(items.count)]
            let other = items[next(items.count)]
            switch next(3) {
            case 0: change = { $0.addFooter(item) }
            case 1: change = { $0.removeFooter(item) }
            default: change = { $0.moveFooter(item, toPositionOf: other) }
            }
        default:
            change = { _ = $0.move(tile, toColumn: next(6), row: next(8)) }
        }
        // `change` 里有的分支会再取随机数,两边各跑一遍会取到不同的数,先定下来再比。
        var probe = shown
        change(&probe)
        let fixed: (inout L) -> Void = { $0 = probe }
        let before = stored
        let new = L.edited(stored, hiddenFrom: hiddenFrom, available: available, fixed)
        let old = referenceUpdate(stored, hiddenFrom: hiddenFrom, available: available, fixed)
        if new.encoded() != old.encoded() { mismatches.append("第 \(step) 步") }
        stored = new
        history.append(stored)
        if stored != before { nonTrivial += 1 }
        let base = stored.splittingUnavailable(available: available).layout
        if L.editingRows(shown: probe, base: base) != max(probe.rowCount(), base.rowCount()) + 1 { rowsMismatches += 1 }
        for p in base.placements {
            let f = grid.frame(p)
            let point = CGPoint(x: f.maxX - CGFloat(next(40)), y: f.maxY - CGFloat(next(40)))
            if grid.resizeHandleTile(at: point, in: base, side: 34) != referenceHandle(base, grid: grid, at: point, side: 34) {
                handleMismatches += 1
            }
        }
    }
    expectEqual(mismatches, [], "面板编辑共用: 3000 步随机编辑,写回的布局跟抽之前的面板写法逐字节一样")
    expectEqual(dragMismatches, 0, "面板编辑共用: 拖动对准的坑位和挤好的预览跟抽之前一样(含拖出网格)")
    expectEqual(rowsMismatches, 0, "面板编辑共用: 编辑网格的排数跟抽之前一样")
    expectEqual(handleMismatches, 0, "面板编辑共用: 按在哪一格的拉手上跟抽之前一样")
    expectEqual(nonTrivial > 1000, true, "面板编辑共用: 随机操作大多真的改了布局(实际 \(nonTrivial) 步),比的不是一串原样")

    // ---- 2. 一步挪位、底栏挪位、缩小网格 ----

    var layout = L.default
    expectEqual(layout.nudge(.notch, .right), true, "面板挪位: 中间的小号往右一步")
    expectEqual(layout.placement(of: .notch).map { [$0.column, $0.row] } == [4, 2]
                    && layout.placement(of: .menuBar).map { [$0.column, $0.row] } == [2, 2], true,
                "面板挪位: 右边同尺寸的那格跟它互换")
    layout = L.default
    expectEqual(layout.nudge(.overlay, .left), false, "面板挪位: 最左一列不能再往左,布局不变")
    expectEqual(layout, L.default, "面板挪位: 挪不动时不改")
    expectEqual(layout.nudge(.nowPlaying, .up), false, "面板挪位: 第一排不能再往上")
    expectEqual(L.default.canNudge(.menuBar, .right), false, "面板挪位: 最右的小号不能再往右")
    expectEqual(L.default.canNudge(.lyricsManager, .left), true, "面板挪位: 右边的中号能往左")
    layout = L.default
    expectEqual(layout.nudge(.nowPlaying, .down), true, "面板挪位: 加宽卡片往下一步(两排)")
    expectEqual(layout.placement(of: .nowPlaying)?.row, 2, "面板挪位: 卡片下移两排")
    expectEqual(layout.placement(of: .overlay)?.row == 0 && layout.placement(of: .lyricsWindow)?.row == 1, true,
                "面板挪位: 下面那两排整块搬上去(同拖动的整块对调)")
    var overlapFree = true
    var probeLayout = L.default
    for direction in [L.NudgeDirection.down, .right, .up, .left, .down, .down, .right] {
        for tile in probeLayout.tiles { probeLayout.nudge(tile, direction) }
        let ps = probeLayout.placements
        for i in ps.indices {
            for j in ps.indices where i < j {
                let a = ps[i], b = ps[j]
                if a.column < b.column + b.size.columns && b.column < a.column + a.size.columns
                    && a.row < b.row + b.size.rows && b.row < a.row + a.size.rows { overlapFree = false }
            }
            if !ps[i].size.alignedColumns.contains(ps[i].column) { overlapFree = false }
        }
    }
    expectEqual(overlapFree, true, "面板挪位: 一串挪位之后格子不重叠、都落在对得齐的列上")

    var footer = L.default
    expectEqual(footer.nudgeFooter(.settings, by: 1), true, "底栏挪位: 第一项往右一位")
    expectEqual(footer.footer, [.lastfm, .settings, .version], "底栏挪位: 跟右边那项换位")
    expectEqual(footer.nudgeFooter(.lastfm, by: -1), false, "底栏挪位: 第一项不能再往左")
    expectEqual(footer.nudgeFooter(.version, by: 1), false, "底栏挪位: 最后一项不能再往右")
    expectEqual(footer.nudgeFooter(.quit, by: 1), false, "底栏挪位: 不在底栏里的不动")
    expectEqual(footer.nudgeFooter(.version, by: -1) && footer.footer == [.lastfm, .version, .settings], true,
                "底栏挪位: 最后一项往左一位")

    let small = PanelGridGeometry.menuBarPanel.scaled(0.6)
    let p = L.Placement(tile: .lyricsManager, size: .medium, column: 3, row: 3)
    let big = PanelGridGeometry.menuBarPanel.frame(p)
    let scaledFrame = small.frame(p)
    expectEqual(abs(scaledFrame.minX - big.minX * 0.6) < 0.001 && abs(scaledFrame.width - big.width * 0.6) < 0.001
                    && abs(scaledFrame.height - big.height * 0.6) < 0.001 && abs(small.height(rows: 5) - grid.height(rows: 5) * 0.6) < 0.001,
                true, "缩小网格: 位置、大小、总高都按同一比例缩")
    expectEqual(small.dragCell(base: L.default, size: .small, origin: CGPoint(x: small.columnStride * 4.2, y: small.rowStride * 2.1),
                               pointer: CGPoint(x: small.columnStride * 4.6, y: 0), sideSlack: 6).map { [$0.column, $0.row] },
                [4, 2], "缩小网格: 拖动按缩小后的列宽、行高认坑位")
    let belowGrid = grid.height(rows: L.default.rowCount() + 1)
    expectEqual(grid.dragCell(base: L.default, size: .small, origin: CGPoint(x: 0, y: belowGrid + 1), pointer: CGPoint(x: 10, y: 0)) == nil
                    && grid.dragCell(base: L.default, size: .small, origin: CGPoint(x: 0, y: belowGrid - 1), pointer: CGPoint(x: 10, y: 0)) != nil,
                true, "拖动坑位: 格子左上角过了最下面那排空位就算拖出网格")
    expectEqual(small.dragCell(base: L.default, size: .small, origin: .zero, pointer: CGPoint(x: small.width + 7, y: 0), sideSlack: 6) == nil,
                true, "缩小网格: 指针出了网格右边 sideSlack 以外算拖出去")

    // ---- 3. 源码契约 ----

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ rel: String) -> String { (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
    let panel = source("lyrimuse/MenuBar/MenuBarPanel.swift")
    let settingsFile = source("lyrimuse/UI/MenuBarPanelLayoutSettings.swift")
    let stage = source("lyrimuse/UI/MenuBarEditorStage.swift")
    expectEqual(panel.isEmpty || settingsFile.isEmpty || stage.isEmpty, false, "面板编辑共用: 三个文件都读得到(读不到 = 挪了)")

    expectEqual(sourceHas(panel, "playback.panelLayout.splittingUnavailable(available: tileAvailable).layout")
                && sourceHas(panel, "let layout = MenuBarPanelLayout.edited(stored, hiddenFrom: hiddenFrom, available: tileAvailable, change)")
                && sourceHas(panel, "let rows = MenuBarPanelLayout.editingRows(shown: layout, base: dragBase ?? editLayout)")
                && sourceHas(panel, "let cell = Self.grid.dragCell(base: base, size: dragSize, origin: origin, pointer: dragPointer)")
                && sourceHas(panel, "let preview = base.dragPreview(of: tile, size: dragSize, at: cell, swap: swap)")
                && sourceHas(panel, "Self.grid.resizeHandleTile(at: point, in: editLayout, side: PanelResizeCorner.side)")
                && !panel.contains("withoutUnavailable"), true,
                "面板编辑共用: 面板编辑模式经 Core 共用入口拿掉 / 放回用不了的格子、算排数、拖动坑位与预览、认拉手")
    expectEqual(sourceHas(panel, "MenuBarPanelLayout.FooterItem.panelShows(discordStatus)")
                && sourceHas(panel, "MenuBarPanelLayout.FooterItem.panelShows(lastfmStatus)")
                && sourceHas(settingsFile, "case .lastfm: return MenuBarPanelLayout.FooterItem.panelShows(lastfmStatus)"), true,
                "面板编辑共用: 底栏 Last.fm、Discord 出不出现,面板和设置窗口同一个判据")

    let drawerBody = sourceBody("struct MenuBarAllSettingsDrawer: View {", in: stage)
    expectEqual(sourceHas(drawerBody, "SettingsGroupCard(title: L10n.t(\"行为\")) { MenuBarBehaviorRows() }\nSettingsGroupCard(title: L10n.t(\"面板\")) { MenuBarPanelLayoutRows() }\nresetRow")
                && sourceHas(drawerBody, "L10n.t(\"行为\"),\nL10n.t(\"面板\")])"), true,
                "设置面板组: 菜单栏「全部设置」抽屉末尾一组「面板」,折叠时的组名也列上")

    let rows = sourceBody("struct MenuBarPanelLayoutRows: View {", in: settingsFile)
    let editBody = sourceBody("private func edit(hiddenFrom: MenuBarPanelLayout? = nil, _ change: (inout MenuBarPanelLayout) -> Void) {", in: rows)
    expectEqual(sourceHas(editBody, "let stored = settings.menuBarPanelLayout\nlet layout = MenuBarPanelLayout.edited(stored, hiddenFrom: hiddenFrom, available: tileAvailable, change)")
                && sourceHas(editBody, "settings.menuBarPanelLayout = layout"), true,
                "设置面板组: 改布局经面板同一个入口,写的是面板读的那个设置")
    // 写设置只有两处:edit 里那一处和「恢复默认」;别的操作都得走 edit。
    let writes = rows.components(separatedBy: "settings.menuBarPanelLayout = ").count - 1
    expectEqual(writes == 2 && sourceHas(rows, "settings.menuBarPanelLayout = .default\n}\n}\n.disabled(settings.menuBarPanelLayout == .default)")
                && !rows.contains("AppSettings.shared.menuBarPanelLayout ="), true,
                "设置面板组: 写设置只有 edit 和「恢复默认」两处(恢复默认直接写默认布局,不把用不了的格子放回去)")
    expectEqual(sourceHas(rows, "let cell = Self.grid.dragCell(base: base, size: dragSize, origin: origin, pointer: dragPointer,")
                && sourceHas(rows, "let preview = base.dragPreview(of: tile, size: dragSize, at: cell, swap: true)")
                && sourceHas(rows, "if let preview = dragPreview, preview != editLayout {\nedit { $0 = preview }")
                && sourceHas(rows, ".simultaneousGesture(gridResizeGesture)")
                && sourceHas(rows, "let hit = Self.grid.resizeHandleTile(at: value.startLocation, in: editLayout,")
                && sourceHas(rows, "allowed: tile.sizes)")
                && sourceHas(rows, "edit(hiddenFrom: resizeStored) { $0 = resized }")
                && sourceHas(rows, "remove: { edit { $0.remove(p.tile) } },")
                && sourceHas(rows, "Button { edit { $0.add(tile, size: .small) } } label: {")
                && sourceHas(rows, "edit { $0.moveFooter(item, toPositionOf: items[target]) }")
                && sourceHas(rows, ".action(item.panelTitle) { edit { $0.addFooter(item) } }"), true,
                "设置面板组: 拖动换位、拉手换尺寸、「−」移除、点可添加、底栏拖动换序和添加都经 edit 写同一个设置")
    expectEqual(sourceHas(rows, "MenuBarStatusItem.shared.togglePanelFromDeepLink(quick: nil, editing: true)"), true,
                "设置面板组: 「在菜单栏里编辑…」同深链 menubar-panel?quick=edit")

    // 右键菜单和 VoiceOver 动作是同一份清单,清单覆盖换尺寸、四个方向挪位、移除(底栏:左移、右移、移除)。
    let tileActions = sourceBody("private func tileActions(_ p: MenuBarPanelLayout.Placement) -> [PanelLayoutAction] {", in: rows)
    expectEqual(sourceHas(tileActions, "p.tile.sizes.map { size in") && sourceHas(tileActions, "edit { $0.resize(p.tile, to: size) }")
                && sourceHas(tileActions, "for direction in MenuBarPanelLayout.NudgeDirection.allCases where base.canNudge(p.tile, direction) {")
                && sourceHas(tileActions, "edit { $0.nudge(p.tile, direction) }")
                && sourceHas(tileActions, "edit { $0.remove(p.tile) }"), true,
                "设置面板组: 格子的动作清单有换尺寸、上下左右挪一步、移除")
    let footerActions = sourceBody("private func footerActions(_ item: MenuBarPanelLayout.FooterItem) -> [PanelLayoutAction] {", in: rows)
    expectEqual(sourceHas(footerActions, "edit { $0.nudgeFooter(item, by: -1) }") && sourceHas(footerActions, "edit { $0.nudgeFooter(item, by: 1) }")
                && sourceHas(footerActions, "edit { $0.removeFooter(item) }"), true,
                "设置面板组: 底栏项的动作清单有左移、右移、移除")
    let tileView = sourceBody("private func editableTile(_ p: MenuBarPanelLayout.Placement) -> some View {", in: rows)
    let chipView = sourceBody("private func footerChip(_ item: MenuBarPanelLayout.FooterItem, actions: [PanelLayoutAction]) -> some View {", in: rows)
    expectEqual(sourceHas(tileView, "let actions = tileActions(p)") && sourceHas(tileView, ".contextMenu { PanelLayoutActionMenu(actions: actions) }")
                && sourceHas(tileView, ".accessibilityActions {\nForEach(actions.filter { $0.checked != true }) { action in\nButton(action.title, action: action.run)")
                && sourceHas(rows, "footerChip(item, actions: footerActions(item))")
                && sourceHas(chipView, ".contextMenu { PanelLayoutActionMenu(actions: actions) }")
                && sourceHas(chipView, ".accessibilityActions {\nForEach(actions) { action in\nButton(action.title, action: action.run)"), true,
                "设置面板组: 格子、底栏项的右键菜单和 VoiceOver 动作取同一份清单(VoiceOver 不列已经是的那一档)")
    let menu = sourceBody("struct PanelLayoutActionMenu: View {", in: settingsFile)
    expectEqual(sourceHas(menu, "ForEach(actions) { action in") && !menu.contains("filter"), true,
                "设置面板组: 右键菜单把清单里每一项都列出来")
}
