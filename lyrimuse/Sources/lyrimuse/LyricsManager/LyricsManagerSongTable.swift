import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 歌词管理左侧的歌曲列表:自己管数据源的 NSTableView,行高固定 56,AppKit 只给看得见的那十几行建视图,行里画的还是
/// SwiftUI(`LyricsManagerSongRow`,每格一个复用的 NSHostingView)。数据换了一份就 `reloadData`,只是搜索词、校准名单、
/// 界面语言变了就只重画屏上的行。别换回 SwiftUI `List`:三万行时数据有一点变化它就要整表比对一秒以上(见 11 章决策 170)。
///
/// 选中经 `LyricsManagerListSelection` 双向同步:用户在表格上点选报上去,代码里改的选中按 key 换算成行号写回表格,屏幕外的
/// 行也当场对上。组头是一行选不中的条目(`shouldSelectRow`),方向键、Shift 连选、全选都跳过它。右键点一首没选中的歌,
/// 先把选中收到那一行再弹菜单(`LyricsManagerSongTableView.menu(for:)`)。
struct LyricsManagerSongTable: NSViewRepresentable {
    /// 列表的数据:不分组是一首一行,分组是组头和歌摊平成一层(见 11 章决策 70)。
    enum Entries {
        case flat([EnrichCacheStore.Summary])
        case grouped([LyricsManagerView.AlbumListEntry])

        var count: Int {
            switch self {
            case let .flat(rows): return rows.count
            case let .grouped(rows): return rows.count
            }
        }

        /// 这一行的歌的 key;组头和越界是 nil。
        func key(at row: Int) -> String? {
            switch self {
            case let .flat(rows):
                return rows.indices.contains(row) ? rows[row].key : nil
            case let .grouped(rows):
                guard rows.indices.contains(row), case let .song(summary) = rows[row] else { return nil }
                return summary.key
            }
        }

        /// 这一首在第几行;不在列表里是 nil。
        func row(of key: String) -> Int? {
            switch self {
            case let .flat(rows): return rows.firstIndex { $0.key == key }
            case let .grouped(rows): return rows.firstIndex { $0.id == key }
            }
        }

        /// 同一份数组(缓存盒里取出来的那份)才算没变,不逐条比。
        func isSameArray(as other: Entries) -> Bool {
            switch (self, other) {
            case let (.flat(a), .flat(b)): return Self.sameStorage(a, b)
            case let (.grouped(a), .grouped(b)): return Self.sameStorage(a, b)
            default: return false
            }
        }

        private static func sameStorage<T>(_ a: [T], _ b: [T]) -> Bool {
            a.count == b.count && a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pa.baseAddress == $0.baseAddress } }
        }
    }

    let entries: Entries
    /// 列表此刻在搜的关键词,行里命中的字高亮。
    let query: String
    let pins: [String: Int]
    let albumDisplayMap: [String: String]
    /// 行里的字是现取的界面语言,切换语言时屏上的行重画。
    let language: String
    let emphasis: LyricsManagerListEmphasis
    let nowPlaying: LyricsManagerListNowPlaying
    let selection: LyricsManagerListSelection
    let controller: LyricsManagerSongTableController
    /// 滚动条顶端让出的高度:分组时列表往上伸进标题行底下,滚动条从裁剪后的上沿开始(见 11 章决策 113、132)。
    let scrollerTopInset: CGFloat
    /// 右键菜单。参数是这一下作用于哪几首:点在选中区里是整个选区,点在没选中的行上是那一行,点在空白处或组头上是空集。
    let menu: (Set<String>) -> [LyricsManagerListMenuItem]
    /// 右键点没选中的歌时选中能不能跟过去:编辑里有没保存的修改时不跟,菜单照旧只作用于那一首,里面的动作换歌前先问。
    let rightClickMovesSelection: () -> Bool

    static let rowHeight: CGFloat = 56

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LyricsManagerSongTableView()
        let column = NSTableColumn(identifier: Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = Self.rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.backgroundColor = .clear
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerInsets = NSEdgeInsets(top: scrollerTopInset, left: 0, bottom: 0, right: 0)

        let coordinator = context.coordinator
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.bind(selection)
        controller.coordinator = coordinator
        coordinator.reload()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let old = coordinator.parent
        coordinator.parent = self
        controller.coordinator = coordinator
        if scroll.scrollerInsets.top != scrollerTopInset {
            scroll.scrollerInsets = NSEdgeInsets(top: scrollerTopInset, left: 0, bottom: 0, right: 0)
        }
        if selection !== old.selection { coordinator.bind(selection) }
        switch LyricsManagerListTable.refresh(
            sameData: entries.isSameArray(as: old.entries),
            rowInputsChanged: query != old.query || pins != old.pins || language != old.language) {
        case .reload: coordinator.reload()
        case .visibleRows: coordinator.refreshVisibleRows()
        case .none: break
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.unbind()
        if let table = coordinator.table {
            table.delegate = nil
            table.dataSource = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("song")
        static let cellID = NSUserInterfaceItemIdentifier("lyrics-manager-song")

        var parent: LyricsManagerSongTable
        weak var table: NSTableView?
        /// 代码在改表格(换数据、写回选中)期间表格报上来的选中不算用户点的,不往上报。
        private var applyingSelection = false
        private var selectionSink: AnyCancellable?

        init(_ parent: LyricsManagerSongTable) {
            self.parent = parent
        }

        func bind(_ selection: LyricsManagerListSelection) {
            // @Published 在赋值之前发:用发出来的值,别回头读 selection.keys。
            selectionSink = selection.$keys.sink { [weak self] keys in
                MainActor.assumeIsolated { self?.applySelection(keys) }
            }
        }

        func unbind() {
            selectionSink = nil
        }

        /// 整份数据换掉:重建屏上的行,再按 key 把选中对回去(行号全变了)。
        func reload() {
            guard let table else { return }
            applyingSelection = true
            table.reloadData()
            applyingSelection = false
            applySelection(parent.selection.keys)
        }

        /// 数据没换、行上画的东西变了(搜索词、校准名单、界面语言):只重画建着的那几行。
        func refreshVisibleRows() {
            table?.enumerateAvailableRowViews { rowView, row in
                (rowView.view(atColumn: 0) as? LyricsManagerSongCell)?.show(self.content(for: row))
            }
        }

        /// 选中按 key 换算成行号写回表格;跟表格上的一样就不动。用户在表格上点的报上来再经这里回来时,表格上的选中已经是这几首,
        /// 先比选中的那几行,不整表换算。
        func applySelection(_ keys: Set<String>) {
            guard let table else { return }
            let entries = parent.entries
            if LyricsManagerListTable.selectionMatches(keys, selectedRows: table.selectedRowIndexes, key: entries.key(at:)) { return }
            let rows = LyricsManagerListTable.rows(of: keys, count: entries.count, key: entries.key(at:))
            guard rows != table.selectedRowIndexes else { return }
            applyingSelection = true
            table.selectRowIndexes(rows, byExtendingSelection: false)
            applyingSelection = false
        }

        /// 右键点下去、菜单建出来之前:点在没选中的歌上就把选中收到那一行,照用户点选一样往上报(不设 applyingSelection)。
        func rightClicked(row: Int) {
            guard let table, let rows = LyricsManagerListTable.rightClickSelection(
                clickedRow: row, selectedRows: table.selectedRowIndexes,
                mayMoveSelection: parent.rightClickMovesSelection(), key: parent.entries.key(at:)) else { return }
            table.selectRowIndexes(rows, byExtendingSelection: false)
        }

        /// 右键点在第几行时菜单作用于哪几首(-1 是空白处)。
        func menuKeys(clickedRow: Int) -> Set<String> {
            guard let table else { return [] }
            return LyricsManagerListTable.menuKeys(clickedRow: clickedRow, selectedRows: table.selectedRowIndexes,
                                                   key: parent.entries.key(at:))
        }

        /// 把这一首滚到列表正中。行高固定,一次就落准;到了两头按能滚到的范围夹住。
        func center(_ key: String, animated: Bool) {
            guard let table, let scroll = table.enclosingScrollView, let row = parent.entries.row(of: key) else { return }
            let clip = scroll.contentView
            let rect = table.rect(ofRow: row)
            let proposed = NSRect(x: clip.bounds.minX, y: rect.midY - clip.bounds.height / 2,
                                  width: clip.bounds.width, height: clip.bounds.height)
            let origin = clip.constrainBoundsRect(proposed).origin
            guard origin != clip.bounds.origin else { return }
            guard animated else {
                clip.setBoundsOrigin(origin)
                scroll.reflectScrolledClipView(clip)
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: {
                scroll.reflectScrolledClipView(clip)
            }
        }

        func row(of key: String) -> Int? { parent.entries.row(of: key) }

        fileprivate func content(for row: Int) -> LyricsManagerSongCellContent {
            let kind: LyricsManagerSongCellContent.Kind
            switch parent.entries {
            case let .flat(rows):
                kind = rows.indices.contains(row) ? song(rows[row]) : .blank
            case let .grouped(rows):
                guard rows.indices.contains(row) else { kind = .blank; break }
                switch rows[row] {
                case let .header(group): kind = .header(album: group.album, artist: group.artist, count: group.items.count)
                case let .song(summary): kind = song(summary)
                }
            }
            return LyricsManagerSongCellContent(kind: kind, query: parent.query, emphasis: parent.emphasis,
                                                nowPlaying: parent.nowPlaying)
        }

        private func song(_ summary: EnrichCacheStore.Summary) -> LyricsManagerSongCellContent.Kind {
            .song(summary,
                  albumDisplayName: summary.isListedMV ? L10n.t("MV")
                      : LyricsManagerView.albumDisplay(summary.displayAlbum, in: parent.albumDisplayMap),
                  isPinned: parent.pins[summary.key] != nil)
        }

        // MARK: NSTableViewDataSource / Delegate

        func numberOfRows(in tableView: NSTableView) -> Int { parent.entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let content = content(for: row)
            if let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? LyricsManagerSongCell {
                cell.show(content)
                return cell
            }
            let cell = LyricsManagerSongCell(content: content)
            cell.identifier = Self.cellID
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            parent.entries.key(at: row) != nil
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let keys = LyricsManagerListTable.keys(atRows: table.selectedRowIndexes, key: parent.entries.key(at:))
            if keys != parent.selection.keys { parent.selection.keys = keys }
        }

        // MARK: NSMenuDelegate

        /// 右键菜单每次弹出前按点在哪一行现建。只看 clickedRow 和表格的选中;选中已在 `rightClicked(row:)` 里跟过去。
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            for item in parent.menu(menuKeys(clickedRow: table.clickedRow)) { menu.addItem(item.menuItem()) }
        }
    }
}

/// 外层拿表格做事的入口:交焦点、等表格装好、滚到某一行。表格建好后由 `LyricsManagerSongTable` 登记进来。放在 @State 里。
@MainActor
final class LyricsManagerSongTableController {
    fileprivate weak var coordinator: LyricsManagerSongTable.Coordinator?

    var table: NSTableView? { coordinator?.table }

    /// 这一首在列表第几行;不在列表里是 nil。
    func row(of key: String) -> Int? { coordinator?.row(of: key) }

    /// 把这一首滚到列表正中;不在列表里不动。
    func center(_ key: String, animated: Bool = true) {
        coordinator?.center(key, animated: animated)
    }

    /// 这一行右键菜单此刻的各项(调试深链核对菜单用),不弹出来、不改选中。
    func menuTitles(forRow row: Int) -> [String] {
        guard let coordinator else { return [] }
        return coordinator.parent.menu(coordinator.menuKeys(clickedRow: row)).map(\.debugTitle)
    }

    /// 往这一行中点造一次右键按下,走 AppKit 弹菜单前的同一条路(`menu(for:)` 定点在哪一行、跟选中、菜单按它现建),
    /// 返回菜单里的各项,不弹出来(调试深链用)。
    func rightClickTitles(row: Int) -> [String] {
        guard let table, let menu = table.menu, (0..<table.numberOfRows).contains(row) else { return [] }
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: table.window?.windowNumber ?? 0, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1),
              table.menu(for: event) === menu else { return [] }
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.map { $0.isSeparatorItem ? "-" : $0.isEnabled ? $0.title : "(\($0.title))" }
    }
}

/// 歌词管理列表的表格:右键按下、菜单建出来之前先让选中跟到点的那一行(见 `Coordinator.rightClicked(row:)`)。
final class LyricsManagerSongTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        (delegate as? LyricsManagerSongTable.Coordinator)?.rightClicked(row: row)
        return super.menu(for: event)
    }
}

/// 列表的一格:一个复用的 NSHostingView,换行时只换 rootView。
final class LyricsManagerSongCell: NSTableCellView {
    private let host: NSHostingView<LyricsManagerSongCellContent>

    init(content: LyricsManagerSongCellContent) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        host.sizingOptions = []
        // 行高 56 = 行内容 48 + 上下各 4(同 SwiftUI 列表 .inset 样式每行自带的那 8)。
        host.frame = bounds.insetBy(dx: 0, dy: 4)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        host.frame = bounds.insetBy(dx: 0, dy: 4)
    }

    func show(_ content: LyricsManagerSongCellContent) {
        host.rootView = content
    }
}

/// 一格里画什么:组头,或者一首歌。
struct LyricsManagerSongCellContent: View {
    enum Kind {
        case header(album: String, artist: String, count: Int)
        case song(EnrichCacheStore.Summary, albumDisplayName: String, isPinned: Bool)
        case blank
    }

    let kind: Kind
    let query: String
    let emphasis: LyricsManagerListEmphasis
    let nowPlaying: LyricsManagerListNowPlaying

    var body: some View {
        switch kind {
        case let .header(album, artist, count):
            // 组头贴着下面那组歌,上面空出来的那截把它跟上一组隔开(见 11 章决策 74)。
            LyricsManagerAlbumHeader(album: album, artist: artist, count: count)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case let .song(summary, albumDisplayName, isPinned):
            LyricsManagerSongListRow(summary: summary, albumDisplayName: albumDisplayName, query: query, isPinned: isPinned,
                                     emphasis: emphasis, nowPlaying: nowPlaying)
        case .blank:
            Color.clear
        }
    }
}

/// 列表的一行。强调色、正在播放自己从 emphasis、nowPlaying 读:换选中、换歌时只有屏上那几行重算(见 11 章决策 89、94)。
struct LyricsManagerSongListRow: View {
    let summary: EnrichCacheStore.Summary
    let albumDisplayName: String
    let query: String
    let isPinned: Bool
    @ObservedObject var emphasis: LyricsManagerListEmphasis
    @ObservedObject var nowPlaying: LyricsManagerListNowPlaying
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isNowPlaying = nowPlaying.key == summary.key
        let isEmphasized = emphasis.keys.contains(summary.key)
        LyricsManagerSongRow(
            summary: summary,
            albumDisplayName: albumDisplayName,
            query: query,
            isNowPlaying: isNowPlaying,
            isPinned: isPinned,
            isEmphasized: isEmphasized,
            artwork: isNowPlaying ? nowPlaying.artwork : nil,
            engineNotRunning: nowPlaying.engineNotRunning)
        // 行底铺了实心强调色:主色、次要色换成白字那一套,同系统列表的选中行(见 11 章决策 67)。
        .environment(\.colorScheme, isEmphasized ? .dark : colorScheme)
    }
}

/// 列表那一份选中(见 LyricsManagerView.listSelection)。
@MainActor
final class LyricsManagerListSelection: ObservableObject {
    @Published var keys: Set<String> = []
}

/// 选中、列表有键盘焦点的那几行(见 LyricsManagerSongRow.isEmphasized)。集合真的变了才发布。
@MainActor
final class LyricsManagerListEmphasis: ObservableObject {
    @Published private(set) var keys: Set<String> = []

    func update(_ keys: Set<String>) {
        if keys != self.keys { self.keys = keys }
    }
}

/// 正在放的那首在列表里是哪一行、播放器给的封面、歌词引擎在不在(占位行的状态文案)。各行自己读:换歌、封面晚一拍到的时候
/// 只有屏上那几行重算(见 11 章决策 94)。值真的变了才发布。
@MainActor
final class LyricsManagerListNowPlaying: ObservableObject {
    @Published private(set) var key: String?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var engineNotRunning = false

    func update(key: String?, artwork: NSImage?, engineNotRunning: Bool) {
        if key != self.key { self.key = key }
        if artwork !== self.artwork { self.artwork = artwork }
        if engineNotRunning != self.engineNotRunning { self.engineNotRunning = engineNotRunning }
    }
}

/// 列表右键菜单的一项。表格自己建 NSMenu(App 最低支持 macOS 14.0,`NSHostingMenu` 要 14.4)。
enum LyricsManagerListMenuItem {
    case action(String, enabled: Bool = true, perform: @MainActor () -> Void)
    case separator

    var debugTitle: String {
        switch self {
        case let .action(title, enabled, _): return enabled ? title : "(\(title))"
        case .separator: return "-"
        }
    }

    @MainActor
    func menuItem() -> NSMenuItem {
        switch self {
        case .separator:
            return .separator()
        case let .action(title, enabled, perform):
            let target = LyricsManagerMenuAction(perform)
            let item = NSMenuItem(title: title, action: #selector(LyricsManagerMenuAction.run), keyEquivalent: "")
            item.target = target
            // NSMenuItem 只弱引用 target,挂在 representedObject 上让它跟菜单项同生共死。
            item.representedObject = target
            item.isEnabled = enabled
            return item
        }
    }
}

private final class LyricsManagerMenuAction: NSObject {
    private let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }

    @MainActor @objc func run() { perform() }
}
