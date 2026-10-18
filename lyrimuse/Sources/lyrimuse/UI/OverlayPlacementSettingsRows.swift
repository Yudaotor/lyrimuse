import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」的「位置」一项:自由 / 顶部居中 / 底部居中 三选一。
//
// 跟「排版」「行为」同一个模子:一份行组件(`OverlayPlacementSettingsRows`)给两个宿主 ——
//   ① 编辑台工具栏第二行那颗「位置」按钮点开的浮层(`OverlayEditorStage.toolbarButton`);
//   ② 「全部设置」抽屉里的「位置」组(`OverlayAllSettingsDrawer.placementGroup`)。
//
// 生效路径跟「行为」那三个开关不同:控制器**订阅** `AppSettings.overlayPlacementMode` 自己落位
// (屏幕 / Dock 变化时要反复重算,不能靠设置行"顺手调一下"),这里只写值,一个 `.shared` 都不碰。

/// 「位置」三选一铺满整宽,下面常显一段说明。不再是一行「位置」+ 尾部控件:两个宿主(浮层、抽屉组)的标题都已经叫「位置」,
/// 再来一行同名行是同一句话说两遍,三个选项还被挤到右边贴边。说明原来收在「?」里,改成常显,只说明选中的那一档。
@MainActor
struct OverlayPlacementSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRowGroup {
            SettingsRawRow {
                VStack(alignment: .leading, spacing: 8) {
                    OverlayPlacementSegmentedControl(selection: $settings.overlayPlacementMode, fillsWidth: true)
                    Text(placementHelp)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // 自绘的一行不会自动挂搜索高亮(只有 SettingsRow / SettingsCardHeader 会),手挂。
            .settingsSearchHighlight(title: L10n.t("位置"))
            // 标题和两档同一行、说明另起一行铺满:浮层宽 420,说明放在标题下面会被分段控件挤成一窄条。
            SettingsRawRow {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(L10n.t("所在屏幕"))
                        Spacer(minLength: 8)
                        SettingsPillSegmentedControl(
                            selection: $settings.overlayFollowsActiveScreen,
                            options: [false, true],
                            label: { $0 ? L10n.t("跟随当前窗口") : L10n.t("固定") },
                            minWidth: 56)
                    }
                    Text(settings.overlayFollowsActiveScreen
                         ? L10n.t("跟随当前使用的屏幕，位置保持不变")
                         : L10n.t("始终停留在所放置的屏幕"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsSearchHighlight(title: L10n.t("所在屏幕"))
        }
    }

    /// 只说明选中的那一档,一句话;三档一起列出来太长。
    private var placementHelp: String {
        switch settings.overlayPlacementMode {
        case .free: return L10n.t("可拖到任意位置")
        case .topCenter: return L10n.t("固定在菜单栏下方正中，无法拖动")
        case .bottomCenter: return L10n.t("固定在 Dock 上方正中，无法拖动")
        }
    }
}

/// 「位置」那一行的三选一(自由 / 顶部居中 / 底部居中)。
///
/// 外观是设计系统里的 `SettingsPillSegmentedControl`(跟「对齐方式」同一个),每档 `minWidth` 56;不用系统分段控件的理由
/// 见那个组件的头注。这里只留 `label(for:)`:工具栏摘要、悬浮窗右键菜单、无障碍播报都用这同一份叫法。
/// 歌词窗口那份 `LyricsAlignmentSegmentedControl` 还是手搭的同形状控件,改到那一段时再换。
@MainActor
struct OverlayPlacementSegmentedControl: View {
    @Binding var selection: OverlayPlacementMode
    /// 各档均分整行(「位置」浮层里铺满整宽);默认按理想宽度落位。
    var fillsWidth = false

    /// 不能存成 `static let`:`L10n.t` 要在每次取值时现算(切语言之后标签要跟着变)。
    /// 「行为」工具栏按钮的摘要(`OverlayEditorStage.behaviorSummary`)也读这份,两处一个口径。
    static func label(for mode: OverlayPlacementMode) -> String {
        switch mode {
        case .free: return L10n.t("自由")
        case .topCenter: return L10n.t("顶部居中")
        case .bottomCenter: return L10n.t("底部居中")
        }
    }

    var body: some View {
        SettingsPillSegmentedControl(
            selection: $selection,
            options: OverlayPlacementMode.allCases,
            label: Self.label(for:),
            minWidth: 56,
            fillsWidth: fillsWidth)
    }
}
