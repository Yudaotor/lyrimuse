import SwiftUI
import UniformTypeIdentifiers
import LyrimuseCore

extension NotchQuickAction {
    /// 灵动岛上和设置编辑区里那颗键的字形。「喜欢」已喜欢时在灵动岛上换实心,不走这里。
    var symbolName: String {
        switch self {
        case .favorite: return "heart"
        case .searchLyrics: return "magnifyingglass"
        case .toggleLyrics: return "text.alignleft"
        case .lyricsWindow: return "text.quote"
        case .lyricsManager: return "list.bullet.rectangle"
        case .shareLyrics: return "square.and.arrow.up"
        case .toggleOverlay: return "captions.bubble"
        case .openPlayer: return "play.rectangle"
        case .lastfm: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        case .close: return "xmark"
        case .previous: return "backward.fill"
        case .playPause: return "playpause.fill"
        case .next: return "forward.fill"
        case .shuffle: return "shuffle"
        case .repeatMode: return "repeat"
        case .lyricsAdvance: return LyrimuseAction.lyricsAdvanceHotkey.iconName
        case .lyricsDelay: return LyrimuseAction.lyricsDelayHotkey.iconName
        case .lyricsOffsetReset: return LyrimuseAction.lyricsOffsetResetHotkey.iconName
        case .menuBarLyrics: return LyrimuseAction.toggleMenuBarLyricsHotkey.iconName
        case .hideAllLyrics: return LyrimuseAction.toggleAllLyricsHotkey.iconName
        case .lockOverlay: return "lock"
        case .divider: return "poweron"
        }
    }

    /// 设置编辑区里的名字。
    var displayName: String {
        switch self {
        case .favorite: return L10n.t("喜欢")
        case .searchLyrics: return L10n.t("搜索歌词")
        case .toggleLyrics: return L10n.t("显示歌词")
        case .lyricsWindow: return L10n.t("歌词窗口")
        case .lyricsManager: return L10n.t("歌词管理")
        case .shareLyrics: return L10n.t("分享歌词")
        case .toggleOverlay: return L10n.t("悬浮歌词")
        case .openPlayer: return L10n.t("切换到播放器")
        case .lastfm: return "Last.fm"
        case .settings: return L10n.t("设置")
        case .close: return L10n.t("关闭灵动岛歌词")
        case .previous: return L10n.t("上一首")
        case .playPause: return L10n.t("播放/暂停")
        case .next: return L10n.t("下一首")
        case .shuffle: return L10n.t("随机播放")
        case .repeatMode: return L10n.t("循环播放")
        case .lyricsAdvance: return L10n.t("歌词提前")
        case .lyricsDelay: return L10n.t("歌词延后")
        case .lyricsOffsetReset: return L10n.t("歌词偏移归零")
        case .menuBarLyrics: return L10n.t("菜单栏歌词")
        case .hideAllLyrics: return L10n.t("隐藏/恢复全部歌词")
        case .lockOverlay: return L10n.t("锁定位置")
        case .divider: return L10n.t("分隔线")
        }
    }

    /// 「可添加」里这一组的标题。
    static func paletteGroupTitle(_ group: PaletteGroup) -> String {
        switch group {
        case .playback: return L10n.t("播放控制")
        case .lyrics: return L10n.t("歌词")
        case .surfaces: return L10n.t("窗口与显示")
        case .other: return L10n.t("其他")
        }
    }

    /// 只在某些情况下才出现的键,编辑区悬停时说明。
    var conditionNote: String? {
        switch self {
        case .favorite: return L10n.t("播放器支持「喜欢」时才显示")
        case .lastfm: return L10n.t("连接 Last.fm 后才显示")
        case .shuffle, .repeatMode: return L10n.t("播放器支持随机和循环时才显示")
        case .lockOverlay: return L10n.t("悬浮歌词开着时才显示")
        default: return nil
        }
    }
}

/// 「展开时」浮层里快捷操作的编辑区(「快捷操作」开着时出现):上面一块深底照灵动岛的样子摆着两行格子,靠右对齐、从右边数起;
/// 下面「可添加」里的键拖进哪一格就放在哪一格(点一下放进第一个空格),格子之间拖动对调,拖回「可添加」或悬停点 × 清空,
/// 空着的格子就是留白。按现在的展开宽度看不见的格子画成灰的。右键每一格有「移除」,给键盘和读屏用。
/// 格子存 `AppSettings.notchQuickSlots`,规则在 Core `NotchQuickSlots`。见 05 章决策 132。
@MainActor
struct NotchQuickActionsEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hovered: Slot?
    @State private var dropTarget: Slot?

    struct Slot: Hashable { let row: Int; let index: Int }

    static let cell: CGFloat = 26
    static let spacing: CGFloat = 4

    private var slots: NotchQuickSlots { settings.notchQuickSlots }

    /// 按现在的展开宽度,一行看得见几格(同 `trackInfoQuickActions` 的算法)。稳态宽被耳朵下限顶上去时真实宽度比这里算的大,
    /// 这里只会少算、不会多算。
    private var visibleSlots: Int {
        let width = NotchWidthBounds.expandedWidth(steady: CGFloat(settings.notchContentWidth),
                                                   expandedSetting: CGFloat(settings.notchExpandedContentWidth))
        let capacity = NotchQuickAction.capacity(
            contentWidth: Double(width - 2 * NotchMetrics.expandedContentInset),
            showsArtwork: settings.notchExpandedShowsArtwork,
            showsText: settings.notchExpandedShowsTrackTitle || settings.notchExpandedShowsArtist || settings.notchExpandedShowsAlbum,
            artworkSide: Double(NotchExpandedMetrics.trackInfoArtworkSide))
        return min(NotchQuickAction.slotsThatFit(capacity: capacity), NotchQuickSlots.slotsPerRow)
    }

    /// 编辑区每行摆几格:看得见的格子,再加上放了东西却看不见的那几格(画成灰的),至少 1 格。
    private var shownSlots: Int {
        let filled = (0..<NotchQuickSlots.rowCount).compactMap { slots.lastFilled(row: $0) }.max().map { $0 + 1 } ?? 0
        return max(1, visibleSlots, filled)
    }

    private var hasHidden: Bool {
        (0..<NotchQuickSlots.rowCount).contains { (slots.lastFilled(row: $0) ?? -1) >= visibleSlots }
    }

    var body: some View {
        if settings.notchExpandedShowsQuickActions {
            SettingsRowGroup(title: L10n.t("快捷操作按钮")) {
                VStack(alignment: .leading, spacing: 10) {
                    grid
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("把下面的按钮拖进格子，格子可以留空"))
                        Text(String(format: L10n.t("按现在的展开宽度，每行 %d 格"), visibleSlots))
                        if hasHidden { Text(L10n.t("灰色的格子放不下，加宽展开卡片才会显示")) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    palette
                    if slots != .default {
                        HStack {
                            Spacer()
                            // 改格子不包 withAnimation:灵动岛那扇窗在同一拍里跟着改高度,带着动画事务进去会让托管视图
                            // 按动画改窗口尺寸、布局循环超限崩溃(05 章决策 134)。
                            Button(L10n.t("恢复默认")) { settings.notchQuickSlots = .default }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    /// 两行格子,照灵动岛:靠右排,最右是第 0 格。
    private var grid: some View {
        VStack(alignment: .trailing, spacing: Self.spacing) {
            ForEach(0..<NotchQuickSlots.rowCount, id: \.self) { row in
                HStack(spacing: Self.spacing) {
                    Spacer(minLength: 0)
                    ForEach((0..<shownSlots).reversed(), id: \.self) { index in
                        cell(Slot(row: row, index: index))
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.88)))
        .animation(.easeOut(duration: 0.15), value: slots)
    }

    private func cell(_ slot: Slot) -> some View {
        let action = slots.rows[slot.row][slot.index]
        let hidden = slot.index >= visibleSlots
        let targeted = dropTarget == slot
        return ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(action == nil ? (targeted ? 0.7 : 0.22) : 0),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(targeted ? 0.2 : (hovered == slot && action != nil ? 0.14 : 0)))
                if let action {
                    if action.isDivider {
                        Rectangle().fill(Color.white.opacity(hidden ? 0.12 : 0.3)).frame(width: 1, height: 14)
                    } else {
                        Image(systemName: action.symbolName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(hidden ? 0.28 : 0.85))
                    }
                }
            }
            .frame(width: Self.cell, height: Self.cell)
            .opacity(hidden && action == nil ? 0.45 : 1)
            if action != nil, hovered == slot {
                Button {
                    clear(slot)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.4))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .accessibilityLabel(L10n.t("移除"))
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = slot } else if hovered == slot { hovered = nil }
        }
        .help(help(for: action, hidden: hidden))
        .modifier(SlotDragSource(payload: action == nil ? nil : "slot:\(slot.row):\(slot.index)"))
        .onDrop(of: [UTType.plainText], isTargeted: Binding(
            get: { dropTarget == slot },
            set: { inside in if inside { dropTarget = slot } else if dropTarget == slot { dropTarget = nil } })) { providers in
            receive(providers) { payload in drop(payload, on: slot) }
        }
        .contextMenu {
            if action != nil { Button(L10n.t("移除")) { clear(slot) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action?.displayName ?? L10n.t("空格子"))
    }

    private func help(for action: NotchQuickAction?, hidden: Bool) -> String {
        guard let action else { return L10n.t("空格子") }
        if hidden { return "\(action.displayName) · \(L10n.t("展开宽度不够，放不下"))" }
        return action.conditionNote.map { "\(action.displayName) · \($0)" } ?? action.displayName
    }

    private func clear(_ slot: Slot) {
        hovered = nil
        settings.notchQuickSlots = slots.clearing(row: slot.row, slot: slot.index)
    }

    /// 拖进一格:「palette:<键>」放进去(已经在别处的键从原处挪过来),「slot:<行>:<格>」跟这一格对调。
    private func drop(_ payload: String, on slot: Slot) {
        let parts = payload.split(separator: ":").map(String.init)
        if parts.count == 2, parts[0] == "palette", let action = NotchQuickAction(rawValue: parts[1]) {
            settings.notchQuickSlots = slots.placing(action, row: slot.row, slot: slot.index)
        } else if parts.count == 3, parts[0] == "slot", let row = Int(parts[1]), let index = Int(parts[2]) {
            settings.notchQuickSlots = slots.moving(fromRow: row, fromSlot: index, toRow: slot.row, toSlot: slot.index)
        }
        dropTarget = nil
    }

    private func receive(_ providers: [NSItemProvider], _ handle: @escaping @MainActor (String) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString else { return }
            let payload = text as String
            Task { @MainActor in handle(payload) }
        }
        return true
    }

    private var palette: some View {
        let placed = slots.placed
        let addable = NotchQuickAction.paletteOrder.filter { $0.isDivider || !placed.contains($0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("可添加"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(NotchQuickAction.PaletteGroup.allCases, id: \.self) { group in
                    let items = addable.filter { $0.paletteGroup == group }
                    if !items.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(NotchQuickAction.paletteGroupTitle(group))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .frame(width: 64, alignment: .leading)
                            WrapLayout(horizontalSpacing: 6, verticalSpacing: 6, rowAlignment: .leading) {
                                ForEach(items, id: \.self) { action in paletteChip(action) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 格子里的键拖回这一栏就是移掉。
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
            receive(providers) { payload in
                let parts = payload.split(separator: ":").map(String.init)
                guard parts.count == 3, parts[0] == "slot", let row = Int(parts[1]), let index = Int(parts[2]) else { return }
                settings.notchQuickSlots = slots.clearing(row: row, slot: index)
            }
        }
    }

    /// 「可添加」里的一颗。不用 Button:按钮的点按会抢掉拖动手势,点一下和拖出去要同时成立。
    private func paletteChip(_ action: NotchQuickAction) -> some View {
        HStack(spacing: 4) {
            Image(systemName: action.isDivider ? "minus" : action.symbolName)
                .font(.system(size: 10, weight: .medium))
                .rotationEffect(action.isDivider ? .degrees(90) : .zero)
            Text(action.displayName).font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .contentShape(Capsule())
        .onTapGesture { settings.notchQuickSlots = slots.addingToFirstEmpty(action, visibleSlots: visibleSlots) }
        .help(action.conditionNote ?? action.displayName)
        .modifier(SlotDragSource(payload: "palette:\(action.rawValue)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.displayName)
        .accessibilityAddTraits(.isButton)
    }
}

/// 能拖的格子 / 键:拖出去的是一串文字(「palette:<键>」或「slot:<行>:<格>」),空格子不能拖。
private struct SlotDragSource: ViewModifier {
    let payload: String?

    func body(content: Content) -> some View {
        if let payload {
            content.onDrag { NSItemProvider(object: payload as NSString) }
        } else {
            content
        }
    }
}
