import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」的「位置」一项(2026-09-11,GitHub issue #5「可否增加底部在 Dock 栏之上
// 水平居中对齐选项」):自由 / 顶部居中 / 底部居中 三选一。
//
// 跟「排版」「行为」同一个模子:一份行组件(`OverlayPlacementSettingsRows`)给两个宿主 ——
//   ① 编辑台工具栏第二行那颗「位置 ▾」点开的浮层(`OverlayPlacementPopover`);
//   ② 「全部设置」抽屉里的「位置」组(`OverlayAllSettingsDrawer.placementGroup`)。
// 当天上午它先是「行为」浮层里的第一行,用户看过之后要求「这个位置的配置项也给上面放一个」——
// 抽屉分组跟工具栏一一对应是 2026-09-07 定下的规矩,于是从「行为」里整个搬出来单开。
//
// 生效路径跟「行为」那三个开关不同:控制器**订阅** `AppSettings.overlayPlacementMode` 自己落位
// (屏幕 / Dock 变化时要反复重算,不能靠设置行"顺手调一下"),这里只写值,一个 `.shared` 都不碰。

/// 「位置」那一行。只有这一行,不再套分隔线;宿主决定放哪。
@MainActor
struct OverlayPlacementSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "dock.rectangle",
            title: L10n.t("位置"),
            help: L10n.t("自由：拖到任意位置。\n顶部居中 / 底部居中：贴着菜单栏下方 / Dock 上方水平居中，屏幕或 Dock 变化时自动对齐；此时窗口不可拖动。")
        ) {
            OverlayPlacementSegmentedControl(selection: $settings.overlayPlacementMode)
        }
    }
}

/// 「位置」那一行的三选一(自由 / 顶部居中 / 底部居中)。
///
/// 长相、尺寸照抄 `OverlayAlignmentSegmentedControl`(同文件夹 OverlayStyleSettingsRows.swift):
/// 手搭的分段按钮、每档 `minWidth` 56、选中垫 accent 底 —— 不用系统 `.pickerStyle(.segmented)`
/// 的理由那边写了三轮排查(macOS 把它桥成 NSSegmentedControl,按选中段的文字重新量宽,
/// "选了哪档控件整体宽度就跟着变")。这是第三份同形状的控件(另一份是
/// `LyricsAlignmentSegmentedControl`),各自绑不同的枚举;要改尺寸记得三处一起。
///
/// ⚠️ `.fixedSize()`:同那两份 —— 在 `SettingsRow` 尾部插槽里,标题列 / Spacer / 本控件三个可伸缩
/// 成员**均分**亏空,不钉住的话英文 "Bottom Center" 会在行里还剩空白时先被截成 "Bottom Ce…"。
@MainActor
struct OverlayPlacementSegmentedControl: View {
    @Binding var selection: OverlayPlacementMode

    /// ⚠️ 不能存成 `static let`:`L10n.t` 要在每次取值时现算(切语言之后标签要跟着变)。
    /// 「行为」工具栏按钮的摘要(`OverlayEditorStage.behaviorSummary`)也读这份,两处一个口径。
    static func label(for mode: OverlayPlacementMode) -> String {
        switch mode {
        case .free: return L10n.t("自由")
        case .topCenter: return L10n.t("顶部居中")
        case .bottomCenter: return L10n.t("底部居中")
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OverlayPlacementMode.allCases, id: \.self) { mode in
                let isSelected = selection == mode
                Button {
                    selection = mode
                } label: {
                    Text(Self.label(for: mode))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(minWidth: 56)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .fixedSize()
    }
}

/// 编辑台工具栏第二行那颗「位置 ▾」点开的浮层。宽度跟「行为」同 420:一行「位置」+ ⓘ + 三档分段
/// (英文 Free / Top Center / Bottom Center 三档合计约 230pt)绰绰有余,取同宽只是让第二行三颗浮层
/// 看起来是一套。
@MainActor
struct OverlayPlacementPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("位置"), width: 420) {
            OverlayPlacementSettingsRows()
        }
    }
}
