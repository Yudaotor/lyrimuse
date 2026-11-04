import AppKit
import SwiftUI
import LyrimuseCore

// 菜单栏面板钮块网格的编辑零件:编辑时每格外面那一层(「−」、右下角拉手、悬停)、空坑位、小标题。格子本身(KnobTile)
// 和每一格接什么动作在 MenuBarPanel.swift;坑位、落点、换尺寸的规则在 Core 的 `MenuBarPanelLayout` / `PanelGridGeometry`。
// 见 06 章决策 84。

private struct PanelTileSizeKey: EnvironmentKey {
    static let defaultValue = MenuBarPanelLayout.Size.medium
}

private struct PanelTileEditingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 格子按哪一档画(小、中:图标在上、名字在下;大:图标在左上、名字在左下)。
    var panelTileSize: MenuBarPanelLayout.Size {
        get { self[PanelTileSizeKey.self] }
        set { self[PanelTileSizeKey.self] = newValue }
    }

    /// 在编辑布局:格子不接点按 / 长按(手势归编辑那一层的拖动和角标)。
    var panelTileEditing: Bool {
        get { self[PanelTileEditingKey.self] }
        set { self[PanelTileEditingKey.self] = newValue }
    }
}

/// 格子的圆角,三档一样:跟右下角那道拉手的弧同心(弧半径 + 离边距离),拉手才贴着格子的圆角走,同控制中心。
let panelTileCornerRadius: CGFloat = PanelResizeCorner.radius + PanelResizeCorner.inset

extension MenuBarPanelLayout.Size {
    var panelName: String {
        switch self {
        case .small: return L10n.t("小")
        case .medium: return L10n.t("中")
        case .large: return L10n.t("大")
        }
    }
}

/// 编辑时套在一格外面的那一层:左上「−」,悬停时右下角露出一道弧形拉手(同控制中心),拖它换尺寸。
/// 悬停状态存在这一格自己身上:存在面板上的话,指针每划过一格整块面板都要重算一遍。
/// `onHover` 挂在最外层(连拉手一起算):挂在内容上的话,指针一挪到拉手上内容就报「离开」,拉手跟着藏起来、点不到。
struct PanelEditableTile<Content: View>: View {
    let content: Content
    let cornerRadius: CGFloat
    /// 正在拖这一格的拉手(拖动中指针离开格子,拉手也留着)。
    let resizing: Bool
    let remove: () -> Void
    let resizeGesture: AnyGesture<Void>
    @State private var hovering = false

    var body: some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                PanelEditBadge(symbol: "minus", tint: Color(nsColor: .systemGray), label: L10n.t("移除"), action: remove)
                    .offset(x: -4, y: -4)
            }
            .overlay(alignment: .bottomTrailing) {
                PanelResizeCorner(cornerRadius: cornerRadius, visible: hovering || resizing)
                    .gesture(resizeGesture)
            }
            .onHover { hovering = $0 }
    }
}

/// 右下角那道弧形拉手,同控制中心编辑时那一道:贴着右下角的一整段四分之一圆弧(半径 22、离边 4、线宽 5,白色带一点影),
/// 整块 34pt 见方都能按。指针不换样子,悬停时弧线亮出来就是提示。
/// 藏起来时只把弧线调透明,可按的那块一直在:整个视图透明度为 0 时 SwiftUI 不再把点击交给它。
struct PanelResizeCorner: View {
    let cornerRadius: CGFloat
    let visible: Bool

    private static let side: CGFloat = 34
    static let radius: CGFloat = 22
    static let inset: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width - Self.inset - Self.radius, y: size.height - Self.inset - Self.radius)
            var path = Path()
            path.addArc(center: center, radius: Self.radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 0.5)
        .opacity(visible ? 1 : 0)
        .frame(width: Self.side, height: Self.side)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}

/// 编辑时空着的坑位:一块淡淡的格子(同控制中心编辑时的空位)。
struct PanelEmptyCell: View {
    var body: some View {
        RoundedRectangle(cornerRadius: panelTileCornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .accessibilityHidden(true)
    }
}

/// 编辑时压在格子角上的圆形小键:移除(−)、添加(+)。
struct PanelEditBadge: View {
    let symbol: String
    let tint: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(tint))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 编辑页里「可添加」「底栏」这类小标题。
struct PanelEditCaption: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

extension MenuBarPanelLayout.FooterItem {
    var panelTitle: String {
        switch self {
        case .settings: return L10n.t("设置")
        case .lastfm: return "Last.fm"
        case .version: return L10n.t("版本号")
        }
    }
}
