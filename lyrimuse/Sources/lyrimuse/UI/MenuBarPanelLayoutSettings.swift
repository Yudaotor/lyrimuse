import AppKit
import SwiftUI
import LyrimuseCore

// 「歌词显示 › 菜单栏 › 全部设置」末尾的「面板」组:一份按比例缩小的菜单栏面板网格,格子只画图标和名字,操作同面板的编辑
// 模式(拖动换位、右下角拉手换尺寸、「−」移除、从「可添加」加入,底栏加减和换顺序,恢复默认),另有右键菜单和 VoiceOver
// 动作。读写的是面板同一个 `AppSettings.menuBarPanelLayout`,哪边改另一边当场跟着变。编辑规则(拿掉用不了的格子再放回、
// 编辑网格几排、拖着对准哪个坑位、一步挪位)都在 Core `MenuBarPanelLayoutEditing.swift`,手势和画法是这里自己的。
// 见 06 章决策 111。

/// 「面板」组的内容。
struct MenuBarPanelLayoutRows: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var touchBar = TouchBarAvailability.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draggingTile: MenuBarPanelLayout.Tile?
    @State private var dragSize: MenuBarPanelLayout.Size = .small
    /// 按下的位置离格子左上角多远(拖着的那份跟着指针走时保持这个偏移)。
    @State private var dragGrab: CGSize = .zero
    @State private var dragPointer: CGPoint = .zero
    /// 开始拖那一刻的布局,预览都按它挤。
    @State private var dragBase: MenuBarPanelLayout?
    @State private var dragPreview: MenuBarPanelLayout?
    /// 上一次算预览时对准的坑位(同一格里晃不重排)。
    @State private var dragCell: [Int] = []
    @State private var resizingTile: MenuBarPanelLayout.Tile?
    @State private var resizeBase: MenuBarPanelLayout?
    @State private var resizeStored: MenuBarPanelLayout?
    /// 这次拖动不是按在拉手上开始的,整次都不当换尺寸。
    @State private var resizeMissed = false
    @State private var footerDragItem: MenuBarPanelLayout.FooterItem?
    @State private var footerDragOffset: CGFloat = 0
    @State private var footerRowWidth: CGFloat = 0
    @State private var lastfmStatus: DestinationStatus?
    @State private var discordStatus: DestinationStatus?

    /// 面板网格按六成缩:小号约 59 × 43,中号约 92 × 43;小号里图标加两行九号字放得下。
    static let scale: CGFloat = 0.6
    static let grid = PanelGridGeometry.menuBarPanel.scaled(scale)
    private static let cornerRadius = panelTileCornerRadius * scale
    private static let gridSpace = "settings-panel-grid"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                gridEditor
                addableColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footerEditor
            bottomRow
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.top, 2)
        .onAppear {
            lastfmStatus = destinationStatus(for: .lastfm, config: .shared, lastfmConnect: .shared,
                                             mirrorInfo: LastfmMirrorStatusWatcher.shared.info)
            discordStatus = destinationStatus(for: .discord, config: .shared, lastfmConnect: .shared, mirrorInfo: nil)
        }
    }

    // MARK: 可用性(同面板)

    /// 「触控栏歌词」只在有触控栏时、「今日收听」只在连着 Last.fm 时能用;用不了的不画、不占坑位,写回时放回原位,
    /// 判据同面板的 `tileAvailable`。
    private func tileAvailable(_ tile: MenuBarPanelLayout.Tile) -> Bool {
        switch tile {
        case .touchBar: return touchBar.isPresent
        case .todayListening: return LastfmStatsService.shared.isConnected
        default: return true
        }
    }

    private func footerItemAvailable(_ item: MenuBarPanelLayout.FooterItem) -> Bool {
        switch item {
        case .lastfm: return MenuBarPanelLayout.FooterItem.panelShows(lastfmStatus)
        case .discord: return MenuBarPanelLayout.FooterItem.panelShows(discordStatus)
        default: return true
        }
    }

    private var editLayout: MenuBarPanelLayout {
        settings.menuBarPanelLayout.splittingUnavailable(available: tileAvailable).layout
    }

    /// 改一次布局:走面板编辑同一个入口(`MenuBarPanelLayout.edited`),直接写设置,面板开着的话当场跟着排。
    private func edit(hiddenFrom: MenuBarPanelLayout? = nil, _ change: (inout MenuBarPanelLayout) -> Void) {
        let stored = settings.menuBarPanelLayout
        let layout = MenuBarPanelLayout.edited(stored, hiddenFrom: hiddenFrom, available: tileAvailable, change)
        guard layout != stored else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            settings.menuBarPanelLayout = layout
        }
    }

    // MARK: 网格

    private var gridEditor: some View {
        let layout = dragPreview ?? editLayout
        let rows = MenuBarPanelLayout.editingRows(shown: layout, base: dragBase ?? editLayout)
        let grid = Self.grid
        return ZStack(alignment: .topLeading) {
            ForEach(layout.emptySlots(rows: rows).map { $0.row * MenuBarPanelLayout.columns + $0.column }, id: \.self) { key in
                PanelEmptyCell(cornerRadius: Self.cornerRadius * 0.6)
                    .frame(width: grid.column, height: grid.rowHeight)
                    .offset(x: CGFloat(key % MenuBarPanelLayout.columns) * grid.columnStride,
                            y: CGFloat(key / MenuBarPanelLayout.columns) * grid.rowStride)
            }
            ForEach(layout.placements, id: \.tile) { p in
                editableTile(p)
            }
            draggedTileCopy
        }
        .frame(width: grid.width, height: grid.height(rows: rows), alignment: .topLeading)
        .coordinateSpace(name: Self.gridSpace)
        .simultaneousGesture(gridResizeGesture)
        .onDisappear { resetGestures() }
    }

    private func editableTile(_ p: MenuBarPanelLayout.Placement) -> some View {
        let frame = Self.grid.frame(p)
        let actions = tileActions(p)
        return PanelEditableTile(
            content: PanelLayoutMiniTile(tile: p.tile, size: p.size, cornerRadius: Self.cornerRadius)
                .frame(width: frame.width, height: frame.height),
            cornerRadius: Self.cornerRadius,
            resizing: resizingTile == p.tile,
            remove: { edit { $0.remove(p.tile) } },
            // 拉手上只挂一个什么都不做的拖动,挡住这一格的挪位置拖动;换尺寸归整块网格那一层(`gridResizeGesture`)。
            resizeGesture: AnyGesture(DragGesture(minimumDistance: 1).map { _ in () }),
            handleScale: Self.scale)
            .opacity(draggingTile == p.tile ? 0.3 : 1)
            .gesture(tileDragGesture(p))
            .contextMenu { PanelLayoutActionMenu(actions: actions) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(p.tile.panelTitle)
            .accessibilityValue(p.size.panelName)
            .accessibilityActions {
                ForEach(actions.filter { $0.checked != true }) { action in
                    Button(action.title, action: action.run)
                }
            }
            .offset(x: frame.minX, y: frame.minY)
    }

    /// 右键菜单和 VoiceOver 动作同一份:换尺寸、上下左右挪一步、移除。
    private func tileActions(_ p: MenuBarPanelLayout.Placement) -> [PanelLayoutAction] {
        let base = editLayout
        var actions = p.tile.sizes.map { size in
            PanelLayoutAction(id: "size-\(size.rawValue)", title: String(format: L10n.t("尺寸：%@"), size.panelName),
                              checked: size == p.size) {
                edit { $0.resize(p.tile, to: size) }
            }
        }
        for direction in MenuBarPanelLayout.NudgeDirection.allCases where base.canNudge(p.tile, direction) {
            actions.append(PanelLayoutAction(id: "nudge-\(direction.rawValue)", title: direction.panelTitle, divided: actions.count == p.tile.sizes.count) {
                edit { $0.nudge(p.tile, direction) }
            })
        }
        actions.append(PanelLayoutAction(id: "remove", title: L10n.t("移除"), divided: true) { edit { $0.remove(p.tile) } })
        return actions
    }

    /// 拖网格里的格子:跟着指针的是一份拷贝;对准的坑位压到别的格子就当场让开(同尺寸对齐的两格互换),松手落定。
    private func tileDragGesture(_ p: MenuBarPanelLayout.Placement) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                guard resizingTile == nil else { return }
                if draggingTile != p.tile {
                    let frame = Self.grid.frame(p)
                    draggingTile = p.tile
                    dragSize = p.size
                    dragGrab = CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY)
                    dragBase = editLayout
                    dragCell = []
                }
                dragPointer = value.location
                updateDragPreview()
            }
            .onEnded { _ in
                if let preview = dragPreview, preview != editLayout {
                    edit { $0 = preview }
                }
                draggingTile = nil
                dragBase = nil
                dragPreview = nil
                dragCell = []
            }
    }

    private func updateDragPreview() {
        guard let tile = draggingTile, let base = dragBase else { return }
        let origin = CGPoint(x: dragPointer.x - dragGrab.width, y: dragPointer.y - dragGrab.height)
        let cell = Self.grid.dragCell(base: base, size: dragSize, origin: origin, pointer: dragPointer,
                                      sideSlack: 10 * Self.scale)
        let key = cell.map { [$0.column, $0.row] } ?? [-1]
        guard key != dragCell else { return }
        dragCell = key
        let preview = base.dragPreview(of: tile, size: dragSize, at: cell, swap: true)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            dragPreview = preview
        }
    }

    /// 拖右下角拉手换尺寸:指针拉到哪就换到最接近的那一档,拖的同时就换;按开始拉那一刻的布局算,拉大挤开的格子缩回去
    /// 回到原位。挂在整块网格上、按按下的位置认是哪一格的拉手,理由同面板那一份(06 章决策 86)。
    private var gridResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                if resizingTile == nil {
                    guard !resizeMissed,
                          let hit = Self.grid.resizeHandleTile(at: value.startLocation, in: editLayout,
                                                               side: PanelResizeCorner.side * Self.scale) else {
                        resizeMissed = true
                        return
                    }
                    resizingTile = hit
                    resizeBase = editLayout
                    resizeStored = settings.menuBarPanelLayout
                }
                guard let tile = resizingTile, let base = resizeBase, let start = base.placement(of: tile) else { return }
                let target = Self.grid.resizedSize(origin: Self.grid.frame(start).origin, pointer: value.location,
                                                   allowed: tile.sizes)
                var resized = base
                resized.resize(tile, to: target)
                if resized != editLayout {
                    edit(hiddenFrom: resizeStored) { $0 = resized }
                }
            }
            .onEnded { _ in
                resizingTile = nil
                resizeBase = nil
                resizeStored = nil
                resizeMissed = false
            }
    }

    /// 视图被移走时 SwiftUI 不报拖动结束(抽屉收起、翻到别的分段),中间状态在这里清掉。
    private func resetGestures() {
        draggingTile = nil
        dragBase = nil
        dragPreview = nil
        dragCell = []
        resizingTile = nil
        resizeBase = nil
        resizeStored = nil
        resizeMissed = false
        footerDragItem = nil
        footerDragOffset = 0
    }

    @ViewBuilder private var draggedTileCopy: some View {
        if let tile = draggingTile {
            let size = Self.grid.size(dragSize)
            PanelLayoutMiniTile(tile: tile, size: dragSize, cornerRadius: Self.cornerRadius)
                .frame(width: size.width, height: size.height)
                .scaleEffect(reduceMotion ? 1 : 1.04)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .offset(x: dragPointer.x - dragGrab.width, y: dragPointer.y - dragGrab.height)
                .allowsHitTesting(false)
        }
    }

    // MARK: 可添加

    private var addableColumn: some View {
        let groups = editLayout.addableGroups(available: tileAvailable)
        return VStack(alignment: .leading, spacing: 6) {
            PanelEditCaption(title: L10n.t("可添加"))
            if groups.isEmpty {
                Text(L10n.t("都已添加"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            ForEach(groups, id: \.group) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.group.panelTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                    SettingsFlowRow(spacing: 5) {
                        ForEach(entry.tiles, id: \.self) { tile in
                            addableChip(tile)
                        }
                    }
                }
            }
        }
    }

    /// 「可添加」里的一格:点一下按小号放进第一个放得下的空位(没有小号的正在播放卡按加宽),同面板「可添加」点一格。
    private func addableChip(_ tile: MenuBarPanelLayout.Tile) -> some View {
        Button { edit { $0.add(tile, size: .small) } } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                SymbolImage(name: tile.panelSymbol, size: 10)
                    .foregroundStyle(.secondary)
                Text(tile.panelTitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SettingsGlassHoverButtonStyle(cornerRadius: 8))
        .contextMenu {
            Button(L10n.t("添加")) { edit { $0.add(tile, size: .small) } }
        }
        .accessibilityLabel(tile.panelTitle)
        .accessibilityAction(named: L10n.t("添加")) { edit { $0.add(tile, size: .small) } }
    }

    // MARK: 底栏

    /// 底栏那一排:按顺序摆,每项左上「−」;按住一项左右拖,松手按落点换到那一格;右键 / VoiceOver 左移、右移、移除;
    /// 「添加」加到最后。存下来的每一项都画(此刻用不了的调淡),同面板编辑页。
    private var footerEditor: some View {
        let items = settings.menuBarPanelLayout.footer
        let slot = footerRowWidth / CGFloat(max(items.count, 1))
        return VStack(alignment: .leading, spacing: 6) {
            PanelEditCaption(title: L10n.t("底栏"))
                .settingsSearchHighlight(title: L10n.t("底栏"))
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element) { index, item in
                        footerChip(item, actions: footerActions(item))
                            .opacity(footerItemAvailable(item) ? 1 : 0.45)
                            .frame(maxWidth: .infinity)
                            .offset(x: footerDragItem == item ? footerDragOffset : 0)
                            .zIndex(footerDragItem == item ? 1 : 0)
                            .gesture(DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    footerDragItem = item
                                    footerDragOffset = value.translation.width
                                }
                                .onEnded { value in
                                    let landed = (CGFloat(index) + 0.5) * slot + value.translation.width
                                    let target = min(max(Int(landed / max(slot, 1)), 0), items.count - 1)
                                    footerDragItem = nil
                                    footerDragOffset = 0
                                    guard target != index else { return }
                                    edit { $0.moveFooter(item, toPositionOf: items[target]) }
                                })
                    }
                    if items.isEmpty {
                        PanelEmptyCell(cornerRadius: 8)
                            .frame(height: 24)
                    }
                }
                .frame(maxWidth: .infinity)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { footerRowWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, now in footerRowWidth = now }
                    }
                }
                footerAddMenu
            }
        }
    }

    private func footerActions(_ item: MenuBarPanelLayout.FooterItem) -> [PanelLayoutAction] {
        let footer = settings.menuBarPanelLayout.footer
        var actions: [PanelLayoutAction] = []
        if footer.first != item {
            actions.append(PanelLayoutAction(id: "left", title: MenuBarPanelLayout.NudgeDirection.left.panelTitle) {
                edit { $0.nudgeFooter(item, by: -1) }
            })
        }
        if footer.last != item {
            actions.append(PanelLayoutAction(id: "right", title: MenuBarPanelLayout.NudgeDirection.right.panelTitle) {
                edit { $0.nudgeFooter(item, by: 1) }
            })
        }
        actions.append(PanelLayoutAction(id: "remove", title: L10n.t("移除"), divided: !actions.isEmpty) {
            edit { $0.removeFooter(item) }
        })
        return actions
    }

    private func footerChip(_ item: MenuBarPanelLayout.FooterItem, actions: [PanelLayoutAction]) -> some View {
        HStack(spacing: 4) {
            Image(systemName: item.panelSymbol).font(.system(size: 10))
            Text(item.panelTitle)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
        .help(item.panelTitle)
        .overlay(alignment: .topLeading) {
            PanelEditBadge(symbol: "minus", tint: Color(nsColor: .systemGray), label: L10n.t("移除")) {
                edit { $0.removeFooter(item) }
            }
            .scaleEffect(0.85)
            .offset(x: -4, y: -7)
        }
        .contextMenu { PanelLayoutActionMenu(actions: actions) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.panelTitle)
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title, action: action.run)
            }
        }
    }

    /// 底栏能加的几项(同面板「可添加」里底栏那一块:Last.fm、Discord 只在连着时有),加到最后;满了只说满了。
    private var footerAddMenu: some View {
        let layout = settings.menuBarPanelLayout
        let addable = layout.addableFooter.filter(footerItemAvailable)
        let entries: [SettingsGlassMenuEntry] = layout.footer.count >= MenuBarPanelLayout.maxFooterItems
            ? [.note(L10n.t("底栏已满"))]
            : addable.map { item in .action(item.panelTitle) { edit { $0.addFooter(item) } } }
        return SettingsGlassActionMenu(title: L10n.t("添加"), systemImage: "plus", height: 24, entries: entries)
            .disabled(addable.isEmpty)
    }

    // MARK: 恢复默认 / 去菜单栏里编辑

    private var bottomRow: some View {
        let hint = Text(L10n.t("拖动换位，拖右下角换尺寸"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        let buttons = HStack(spacing: 8) {
            // 直接写默认布局,不走 edit:那会把此刻用不了的格子按原位放回去,结果不等于默认(同面板那颗)。
            Button(L10n.t("恢复默认")) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    settings.menuBarPanelLayout = .default
                }
            }
            .disabled(settings.menuBarPanelLayout == .default)
            // 同深链 menubar-panel?quick=edit:弹出面板、直接进编辑。
            Button(L10n.t("在菜单栏里编辑…")) {
                MenuBarStatusItem.shared.togglePanelFromDeepLink(quick: nil, editing: true)
            }
        }
        .settingsGlassButtons()
        .controlSize(.small)
        .fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                hint.lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                hint.fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    buttons
                }
            }
        }
    }
}

/// 一条右键菜单项 / VoiceOver 动作。`checked` 非 nil 的画成勾选项(当前尺寸打勾,VoiceOver 不列已经是的那一档)。
struct PanelLayoutAction: Identifiable {
    let id: String
    let title: String
    var checked: Bool?
    /// 菜单里这一项前面画一道分隔线。
    var divided = false
    let run: () -> Void
}

/// 格子、底栏项的右键菜单,跟 VoiceOver 动作是同一份 `PanelLayoutAction` 列表。
struct PanelLayoutActionMenu: View {
    let actions: [PanelLayoutAction]

    var body: some View {
        ForEach(actions) { action in
            if action.divided { Divider() }
            if let checked = action.checked {
                Toggle(action.title, isOn: Binding(get: { checked }, set: { if $0 { action.run() } }))
            } else {
                Button(action.title, action: action.run)
            }
        }
    }
}

extension MenuBarPanelLayout.NudgeDirection {
    var panelTitle: String {
        switch self {
        case .up: return L10n.t("上移")
        case .down: return L10n.t("下移")
        case .left: return L10n.t("左移")
        case .right: return L10n.t("右移")
        }
    }
}

/// 缩小网格里的一格:只画图标和名字,不读播放状态;正在播放卡画一块封面占位和名字。
struct PanelLayoutMiniTile: View {
    let tile: MenuBarPanelLayout.Tile
    let size: MenuBarPanelLayout.Size
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.09))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .overlay { content.padding(.horizontal, 4).padding(.vertical, 3) }
    }

    @ViewBuilder private var content: some View {
        if tile == .nowPlaying {
            nowPlaying
        } else if size.rows == 2 {
            VStack(alignment: .leading, spacing: 0) {
                SymbolImage(name: tile.panelSymbol, size: 15)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                title(lines: 2)
            }
            .padding(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // 小号只有约 51 × 37 可画:名字连图标放不下就不画图标、名字占满,再放不下才缩字(法语、西语的「菜单栏歌词」要三行)。
            ViewThatFits(in: .vertical) {
                VStack(spacing: 1) {
                    SymbolImage(name: tile.panelSymbol, size: 11)
                        .foregroundStyle(.secondary)
                    title(lines: nil).fixedSize(horizontal: false, vertical: true)
                }
                title(lines: nil).fixedSize(horizontal: false, vertical: true)
                title(lines: 3)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 封面占位 + 名字:加宽时横排,大号时封面在上。
    @ViewBuilder private var nowPlaying: some View {
        let cover = RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.25)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 30, height: 30)
            .overlay { Image(systemName: "music.note").font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)) }
        if size == .wide {
            HStack(spacing: 8) {
                cover
                title(lines: 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                cover
                Spacer(minLength: 0)
                title(lines: 1)
            }
            .padding(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func title(lines: Int?) -> some View {
        Text(tile.panelTitle)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(lines)
            .minimumScaleFactor(0.75)
    }
}
