import SwiftUI

/// 「通用 → 菜单栏与 Dock」里挑菜单栏图标的那 12 格。
///
/// **不带预览**,别再加回仿菜单栏那块编辑台(壁纸底 + 苹果标 + wifi/电池/时钟、
/// 上面摆所选那款的本体、图标动画开着就挂 `MenuBarLiveIconView` 真的动、下面 caption 常驻款名)。
/// 菜单栏就在屏幕顶上,选哪款抬头就看得见,不需要在设置页里再仿一条。所以这里只剩 12 格。
///
/// 12 格一行排开、每格正方形,宽度均分整行、最大 `maxTile`。用写死的 `HStack`,不用 LazyHGrid / LazyVGrid:
/// Lazy 容器在窗口不可见时不铺格子,表现是整块空白。选中样式跟播放器页方块格的强调色那一档一致
/// (`CompactTileChrome` 的 `accent`)。
@MainActor
struct MenuBarIconPicker: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let maxTile: CGFloat = 44
    private static let spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(MenuBarIconStyle.allCases) { style in
                chip(style)
            }
        }
        .frame(maxWidth: Self.maxTile * CGFloat(MenuBarIconStyle.allCases.count)
                   + Self.spacing * CGFloat(MenuBarIconStyle.allCases.count - 1))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("菜单栏图标"))
    }

    /// 一格。`.template` 让它跟在菜单栏上一样只按 alpha 上色,否则深色外观下是一团黑。
    private func chip(_ style: MenuBarIconStyle) -> some View {
        let selected = settings.menuBarIconStyle == style
        return Button {
            settings.menuBarIconStyle = style
        } label: {
            MenuBarIconChip(style: style, selected: selected)
        }
        .buttonStyle(.plain)
        .help(style.displayName)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 一格的外观:正方形圆角块。选中 = 强调色淡底 + 强调色描边、图标用强调色;未选 = 细描边;悬停加一层淡灰。
private struct MenuBarIconChip: View {
    let style: MenuBarIconStyle
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Image(nsImage: MenuBarIconStyle.cachedImage(for: style))
            .renderingMode(.template)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background {
                ZStack {
                    if selected {
                        shape.fill(Color.accentColor.opacity(0.09))
                        shape.strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                    } else {
                        shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    }
                    shape.fill(Color.primary.opacity(hovering && !selected ? 0.05 : 0))
                }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}
