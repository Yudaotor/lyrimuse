import SwiftUI
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
        case .divider: return L10n.t("分隔线")
        }
    }

    /// 只在某些情况下才出现的键,编辑区悬停时说明。
    var conditionNote: String? {
        switch self {
        case .favorite: return L10n.t("播放器支持「喜欢」时才显示")
        case .lastfm: return L10n.t("连接 Last.fm 后才显示")
        default: return nil
        }
    }
}

/// 「展开时」浮层里快捷操作那排的编辑区(「快捷操作」开着时出现):上面一条深色条照灵动岛上的样子排着当前那排键,
/// 拖动换位置、悬停点 × 移掉;下面是还能加的键,点一下加进去(「关闭」在最右时加在它前面)。右键每一格有左移 / 右移 / 移除,
/// 给键盘和读屏用。排法存 `AppSettings.notchQuickActions`,规则在 Core `NotchQuickAction`。见 05 章决策 130。
@MainActor
struct NotchQuickActionsEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var dragging: Int?
    @State private var dragOffset: CGFloat = 0
    @State private var hovered: Int?

    static let buttonCell: CGFloat = 26
    static let dividerCell: CGFloat = 10
    static let spacing: CGFloat = 4

    var body: some View {
        if settings.notchExpandedShowsQuickActions {
            SettingsRowGroup(title: L10n.t("快捷操作按钮")) {
                VStack(alignment: .leading, spacing: 10) {
                    strip
                    Text(L10n.t("拖动调整顺序，悬停后点 × 移除"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    palette
                    if settings.notchQuickActions != NotchQuickAction.defaultLayout {
                        HStack {
                            Spacer()
                            Button(L10n.t("恢复默认")) {
                                withAnimation(.easeOut(duration: 0.18)) { settings.notchQuickActions = NotchQuickAction.defaultLayout }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private var layout: [NotchQuickAction] { settings.notchQuickActions }

    private func width(_ action: NotchQuickAction) -> CGFloat {
        action.isDivider ? Self.dividerCell : Self.buttonCell
    }

    /// 照灵动岛头部那排:深底、白字形、靠右排。
    private var strip: some View {
        HStack(spacing: Self.spacing) {
            Spacer(minLength: 0)
            if layout.isEmpty {
                Text(L10n.t("点下面的按钮加进来"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
            }
            ForEach(Array(layout.enumerated()), id: \.offset) { index, action in
                cell(action, index: index)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.88)))
        .animation(.easeOut(duration: 0.18), value: layout)
    }

    private func cell(_ action: NotchQuickAction, index: Int) -> some View {
        let isDragged = dragging == index
        return ZStack(alignment: .topTrailing) {
            Group {
                if action.isDivider {
                    Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 14)
                } else {
                    Image(systemName: action.symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: width(action), height: Self.buttonCell)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(hovered == index || isDragged ? 0.14 : 0)))
            if hovered == index, dragging == nil {
                Button {
                    remove(at: index)
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
        .offset(x: isDragged ? dragOffset : 0)
        .zIndex(isDragged ? 1 : 0)
        .scaleEffect(isDragged ? 1.08 : 1)
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        .help(action.conditionNote.map { "\(action.displayName) · \($0)" } ?? action.displayName)
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                dragging = index
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let target = NotchQuickAction.dropIndex(widths: layout.map { Double(width($0) + Self.spacing) },
                                                        dragged: index, offset: Double(value.translation.width))
                dragging = nil
                dragOffset = 0
                if target != index { settings.notchQuickActions = NotchQuickAction.moving(layout, from: index, to: target) }
            })
        .contextMenu {
            Button(L10n.t("左移")) { settings.notchQuickActions = NotchQuickAction.moving(layout, from: index, to: index - 1) }
                .disabled(index == 0)
            Button(L10n.t("右移")) { settings.notchQuickActions = NotchQuickAction.moving(layout, from: index, to: index + 1) }
                .disabled(index == layout.count - 1)
            Divider()
            Button(L10n.t("移除")) { remove(at: index) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.displayName)
    }

    private func remove(at index: Int) {
        guard layout.indices.contains(index) else { return }
        hovered = nil
        var next = layout
        next.remove(at: index)
        settings.notchQuickActions = next
    }

    private var palette: some View {
        let addable = NotchQuickAction.paletteOrder.filter { NotchQuickAction.canAdd($0, to: layout) }
        let full = layout.filter { !$0.isDivider }.count >= NotchQuickAction.maxButtons
        return VStack(alignment: .leading, spacing: 6) {
            Text(full ? String(format: L10n.t("最多 %d 个按钮"), NotchQuickAction.maxButtons) : L10n.t("可添加"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            WrapLayout(horizontalSpacing: 6, verticalSpacing: 6, rowAlignment: .leading) {
                ForEach(addable, id: \.self) { action in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            settings.notchQuickActions = NotchQuickAction.adding(action, to: layout)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: action.isDivider ? "minus" : action.symbolName)
                                .font(.system(size: 10, weight: .medium))
                                .rotationEffect(action.isDivider ? .degrees(90) : .zero)
                            Text(action.displayName).font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .help(action.conditionNote ?? action.displayName)
                }
            }
        }
    }
}
