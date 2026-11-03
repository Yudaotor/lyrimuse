import SwiftUI
import LyrimuseCore

// 菜单栏面板钮块网格的排版件和编辑布局用的小零件。格子本身(KnobTile)和每一格接什么动作在 MenuBarPanel.swift;
// 布局数据、装排规则、拖动判定在 Core 的 `MenuBarPanelLayout` / `PanelGridDrag`。见 06 章决策 82。

/// 这一格占一排里的几份(`MenuBarPanelLayout.Size.units`)。
struct PanelTileUnits: LayoutValueKey {
    static let defaultValue = MenuBarPanelLayout.Size.medium.units
}

/// 钮块网格:按份数一排排装(`MenuBarPanelLayout.rowRanges`),每排按份数分满整行,行高取这一排最高的那格。
struct PanelTileGrid: Layout {
    var spacing: CGFloat = 9

    private func rows(width: CGFloat, subviews: Subviews) -> [(range: Range<Int>, widths: [CGFloat], height: CGFloat)] {
        let units = subviews.map { $0[PanelTileUnits.self] }
        return MenuBarPanelLayout.rowRanges(units: units).map { range in
            let widths = MenuBarPanelLayout.widths(units: Array(units[range]), rowWidth: width, spacing: spacing)
            let height = zip(range, widths).map { i, w in
                subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            }.max() ?? 0
            return (range, widths, height)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 316
        let laid = rows(width: width, subviews: subviews)
        guard !laid.isEmpty else { return CGSize(width: width, height: 0) }
        let height = laid.map(\.height).reduce(0, +) + spacing * CGFloat(laid.count - 1)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (i, w) in zip(row.range, row.widths) {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: w, height: row.height))
                x += w + spacing
            }
            y += row.height + spacing
        }
    }
}

private struct PanelTileSizeKey: EnvironmentKey {
    static let defaultValue = MenuBarPanelLayout.Size.medium
}

private struct PanelTileEditingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 格子按哪一档画(小:只有图标;中:图标在上、名字在下;大:图标在左、名字在右)。
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

/// 编辑时各格在网格坐标里的位置,拖动判定指针落在哪一格用。
struct PanelTileFramesKey: PreferenceKey {
    static let defaultValue: [MenuBarPanelLayout.Tile: CGRect] = [:]
    static func reduce(value: inout [MenuBarPanelLayout.Tile: CGRect], nextValue: () -> [MenuBarPanelLayout.Tile: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 编辑时压在格子角上的圆形小键:移除(−)、添加(+)、换尺寸。
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

extension MenuBarPanelLayout.Size {
    var panelName: String {
        switch self {
        case .small: return L10n.t("小")
        case .medium: return L10n.t("中")
        case .large: return L10n.t("大")
        }
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
