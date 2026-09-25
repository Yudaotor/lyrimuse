import SwiftUI

/// 三段编辑台(悬浮歌词 / 灵动岛 / 菜单栏)工具栏入口按钮的**标签**:图标 + 标题 + 间隔点 + 当前值摘要。
///
/// 三段共用同一份:这三条工具栏吃的是同一笔横向预算、同一套压缩规则(见 04 章「两行按钮逐列对齐」
/// 与各 `toolbar` 头注的宽度账),各写一份的话任何一处微调都会让三段的胶囊内容悄悄错开。
///
/// 摘要**必须**限宽 + 单行 + 尾部省略 + `layoutPriority(-1)`:它是派生值,内容里有显示器名、
/// 用户装的字体族名这种长度完全不受控的串;负优先级让它在标题之前被压 —— 不加的话 SwiftUI 会把
/// 亏空按比例摊给按钮里所有文字,标题先被截成「风…」「屏…」,入口的名字没了、摘要却还留着半截。
struct EditorToolbarButtonLabel: View {
    let icon: String
    let title: String
    let summary: String

    /// 图标那一格的宽度 —— **定宽,而且必须定宽**:这批图标的本征宽度在 13~15pt 之间不等,
    /// 不定宽的话同一列胶囊的标题起笔前后差 2.5pt。
    ///
    /// **别改成取最大值 15**。这两行的横向预算是负的(亏空已经全压在摘要上),多占的 2pt
    /// 会直接开始吃标题:离屏实测最窄卡片列(499pt)英文下,15 会把灵动岛第二行「Lyric Line」
    /// 截成「Lyric Li…」。13 是这批图标里最窄的那几枚的本征宽度,更宽的左右各溢出 1pt
    /// (不裁剪、仍落在按钮内边距里),这一格因此**一点预算都不多占**。
    static let iconWidth: CGFloat = 13

    /// 摘要那一截的宽度上限,同时也是它的**理想宽度**。
    ///
    /// **理想宽度必须跟上限一样大,别只写 `maxWidth`**。一行之内的按钮是等宽的(余量被 HStack
    /// 平分),而 `.bordered` 按钮是按标签的**理想尺寸**摆标签、再把它在按钮里居中 —— 摘要短到
    /// 标签用不满按钮时,整块内容(图标带着文字一起)就往右挪半格,同一行里长摘要和短摘要的胶囊
    /// 内容因此对不齐(实测差 5pt)。给足理想宽度,标签就永远"想要"比按钮更宽、恒被压到按钮宽、
    /// 贴着左边摆,富余留在摘要那一截的右侧。
    static let summaryWidth: CGFloat = 140

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                // 图标锁死拉丁语区,理由同 SettingsRow:部分"字母造型"的 SF Symbol 带
                // CJK 变体,中文界面下会被渲染成汉字。
                .environment(\.locale, Locale(identifier: "en"))
                .frame(width: Self.iconWidth)
            Text(title)
                .lineLimit(1)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(idealWidth: Self.summaryWidth, maxWidth: Self.summaryWidth, alignment: .leading)
                .layoutPriority(-1)
        }
    }
}
