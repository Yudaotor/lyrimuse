import SwiftUI

/// 「通用 → 菜单栏与 Dock」里挑菜单栏图标的那 12 格(2026-09-04 从 `SettingsView.menuBarIconChoice`
/// 搬出来,2026-09-05 定型)。
///
/// ⚠️ **不带预览**。2026-09-04 第一版是一块编辑台:仿菜单栏(壁纸底 + 苹果标 + wifi/电池/时钟)
/// 上摆所选那款的本体、律动开着就挂 `MenuBarLiveIconView` 真的动、下面 caption 常驻款名。
/// 装机实拍、两帧 diff 都验过是真在动 —— 但用户看完的原话是「我不想这块」(指仿菜单栏预览
/// 和它下面那行小字)。所以这里只剩 12 格,预览那套别再长回来:菜单栏就在屏幕顶上,选哪款
/// 抬头就看得见,不需要在设置页里再仿一条。
///
/// 从 LazyVGrid 换成写死 2×6 的 `Grid`:格子数固定是 12,不需要"按内容自适应";而 Lazy 容器在
/// 窗口不可见时不铺格子,这一页此前实拍过一次"图标那块整片空白"。
@MainActor
struct MenuBarIconPicker: View {
    @ObservedObject private var settings = AppSettings.shared

    /// 一格 44×28。比原先 LazyVGrid 里的 42×26 略大:原来十二格挤在一条行里,格子小显得像一串
    /// 小按钮;现在两行六列摆开,可以松一点。
    private static let chipSize = CGSize(width: 44, height: 28)
    private static let chipsPerRow = 6

    /// 整块在卡里**居中**(2026-09-05 用户原话「这些图标给我排居中」)。它是这张卡里唯一一块
    /// 不是"标题在左、控件在右"形状的东西,靠左摆的话右边空出大半行;居中之后读成一块独立的
    /// 调色板。宿主那边因此**不做** insetToText —— 空出图标列再居中,中轴会往右偏半个图标列。
    var body: some View {
        let styles = MenuBarIconStyle.allCases
        Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(stride(from: 0, to: styles.count, by: Self.chipsPerRow)), id: \.self) { start in
                GridRow {
                    ForEach(styles[start ..< min(start + Self.chipsPerRow, styles.count)]) { style in
                        chip(style)
                    }
                }
            }
        }
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
            Image(nsImage: MenuBarIconStyle.cachedImage(for: style))
                .renderingMode(.template)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: Self.chipSize.width, height: Self.chipSize.height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(style.displayName)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
