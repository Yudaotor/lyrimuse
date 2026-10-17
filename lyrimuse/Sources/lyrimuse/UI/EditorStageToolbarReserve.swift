import SwiftUI

/// 编辑台工具栏第一行右端那颗「重置 ▾」,五段编辑台(悬浮歌词 / 灵动岛 / 菜单栏 / 触控栏 / 歌词窗口)共用:
/// 跟左边入口同一种玻璃按钮(`editorToolbarButtonStyle`)、同高,点开是一条「恢复默认」加一条不可点的作用范围说明。
/// 范围说明必须在界面上写出来(各编辑台排除的东西不一样,不能只写在动作本体的注释里)。
struct EditorToolbarResetMenu: View {
    let scope: String
    let restore: () -> Void
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                Label(L10n.t("重置"), systemImage: "arrow.uturn.backward")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .editorToolbarButtonStyle()
        .fixedSize()
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            SettingsGlassMenuEntries(entries: [.action(L10n.t("恢复默认"), restore), .divider, .note(scope)]) {
                shown = false
            }
        }
    }
}

/// 灵动岛 / 菜单栏编辑台工具栏**第二行末尾的隐藏占位**,宽度跟第一行右端
/// 那颗「重置 ▾」逐像素相同,作用是让两行的按钮逐列对齐。悬浮歌词第二行五颗、第一行三颗,对不成列,不放
/// (放了只会把五颗的摘要一起压成「…」,19 章决策 19)。
///
/// 为什么这样就能对齐:同一行里的按钮**本来就是等宽的** —— 每颗按钮可伸缩的只有摘要那一截
/// (`.frame(maxWidth: 140)` + `.layoutPriority(-1)`),固定部分(图标 + 标题 + 间隔点)长得一样,
/// 于是余量被平分、一行里三四颗按钮自然一样宽。两行错位的唯一原因是第一行末尾多了「重置 ▾」:
/// 它占掉的那一截让第一行每颗按钮都比第二行窄一点。第二行补一份等宽占位,两行的弹性预算就
/// 一模一样,逐列对齐是这条等分规则自己的结果 —— 不需要 Grid,也不需要量宽度往回喂。
///
/// **必须 `.fixedSize()`**。离屏实测过可压缩的版本(不 `.fixedSize()`):它在有余量时也不肯
/// 占满那一截,两行照旧错位 —— 占位只有"不肯让"才叫占位。
///
/// **别改用 `Grid`**。SwiftUI 的 `Grid` 按**等份**分列、不按内容定宽:离屏实测 600pt 卡片列下
/// 三颗入口的摘要全被压成「…」,右边却还空着一大片,比现在差得多。
///
/// 代价(离屏实测:`ImageRenderer` 复刻三段工具栏,中英 × 499 / 515 / 530 / 600 四档卡片列宽):
/// 第二行的横向预算跟第一行一样少掉「重置 ▾」那一截(中文约 90pt / 英文约 97pt),亏空按既有
/// 规矩先吃摘要。中文全区间标题都不截;英文只有在卡片列 ≤515pt(窗口拖到 minWidth 760 那一档)
/// 时,灵动岛第二行最长的标题会截成「Expand…」—— 那一档的摘要本来就只剩省略号了。再往这两行
/// 加入口或把标题改长之前,按各自 `toolbar` 头注那笔账重新离屏量一遍。
struct EditorToolbarResetReserve: View {
    var body: some View {
        // 占位必须是**同一个控件**(`EditorToolbarResetMenu`):拿一个 Label 或定宽矩形来凑会差掉玻璃按钮的内边距。
        // 浮层内容不影响按钮宽度,范围说明传空串。
        EditorToolbarResetMenu(scope: "", restore: {})
            .hidden()
            .accessibilityHidden(true)
    }
}
