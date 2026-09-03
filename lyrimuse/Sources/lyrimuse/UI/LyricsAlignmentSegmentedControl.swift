import LyrimuseCore
import SwiftUI

/// 「对齐方式」用的分段控件 —— **菜单栏歌词和灵动岛歌词行共用这一份**。
///
/// 2026-09-03 从 `MenuBarEditorStage.swift` 搬到这里(原名
/// `MenuBarAlignmentSegmentedControl`),因为用户要求把这一项也加到灵动岛,而两边的选项、
/// 语义、标签文案逐字相同(见 `LyricsRestingAlignment`)。搬家而不是复制第三份:下面那两条
/// ⚠️ 记的都是**实测踩出来的**尺寸坑,复制一份就等于以后改尺寸要记得改三处。同"两个展示面
/// 共用一份视图"的既有先例 `AutoHideSettingsRows.swift`。
///
/// ⚠️ **刻意不用系统 `.pickerStyle(.segmented)`** —— 照 `OverlayAlignmentSegmentedControl`
/// (悬浮歌词那个同名设置)的解法搬过来,那边为这件事修了三轮:macOS 把 SwiftUI 的 Picker
/// 桥接成 `NSSegmentedControl`,而它按**当前选中段的文字**自己重新量宽度,于是"选了哪个
/// 选项、控件整体宽度就跟着变"。给子 `Text` 加 `.frame(minWidth:)` 不管用(AppKit 那层
/// 不读 SwiftUI 子视图的 frame),给 Picker 整体加 `.frame(minWidth:)` 也不管用。完整排查
/// 记录见 docs/features/04-desktop-overlay.md。
///
/// 这三个标签正好是不等宽的(左对齐/居中/右对齐 = 3/2/3 字,英文 Left-Aligned/Center/
/// Right-Aligned 差得更多),是那个 bug 的正射场景,所以直接用手搭的:每个选项固定
/// `minWidth`,尺寸只取决于这里写的数字。
///
/// ⚠️ `.fixedSize()` 是必需的、不是保险(同样抄自那边 2026-08-31 离屏渲染查出来的结论):
/// 这个控件在 `SettingsRow` 尾部插槽里,那一行有三个可伸缩成员(标题列/Spacer/本控件),
/// SwiftUI **均分**剩余宽度而不是"先按理想宽度发";均分份额小于理想宽度时控件被压到下限,
/// 英文标签("Left-Aligned" 长于 56pt)就会在**行里还剩一大截空白**的情况下被截成
/// "Left-Ali…"。
@MainActor
struct LyricsAlignmentSegmentedControl: View {
    @Binding var selection: LyricsRestingAlignment

    /// ⚠️ 不能存成 `static let`:`L10n.t` 要在每次取值时现算,存进 static let 等于把首次
    /// 访问时的语言冻在里面(切语言之后这几个标签不跟着变)——同 OverlayAlignment 那边。
    static func label(for option: LyricsRestingAlignment) -> String {
        switch option {
        case .leading: return L10n.t("左对齐")
        case .center: return L10n.t("居中")
        case .trailing: return L10n.t("右对齐")
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LyricsRestingAlignment.allCases, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(Self.label(for: option))
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
