import AppKit
import LyrimuseCore
import SwiftUI

/// 三段编辑台(悬浮歌词 / 灵动岛 / 菜单栏)工具栏入口按钮的**标签**:图标 + 标题 + 间隔点 + 当前值摘要。
///
/// 三段共用同一份:这三条工具栏吃的是同一笔横向预算、同一套压缩规则(见 04 章「两行按钮逐列对齐」
/// 与各 `toolbar` 头注的宽度账),各写一份的话任何一处微调都会让三段的胶囊内容悄悄错开。
///
/// 摘要的**内容**按"胶囊上读得完"来定:开关类只报数量(`SettingsToggleSummary`)、字体不报默认字体名、排版只报对齐、
/// 屏幕报短名 —— 中文在默认窗口宽度(卡片列 600pt)下每截约 55pt 放得下。限宽 + 单行 + 尾部省略 + `layoutPriority(-1)`
/// 只是兜底:用户自选的字体族名、外接显示器名、自存主题名长度不受控,英文和窄窗口下仍会压;负优先级让摘要在标题
/// 之前被压 —— 不加的话 SwiftUI 会把亏空按比例摊给按钮里所有文字,标题先被截成「风…」「屏…」。
struct EditorToolbarButtonLabel: View {
    let icon: String
    let title: String
    let summary: String
    /// 悬停说明里代替 `summary` 的整句(开关类摘要只报数量,这里列出开着的是哪几项)。不给就用 `summary`。
    var detail: String?
    /// 标题后面标「Beta」(`SettingsBetaBadge`);占的宽度从摘要那一截让出来。
    var beta = false
    /// 按内容分宽的那一行(`EditorToolbarContentWidthRow`)用:摘要的理想宽度就是文字本身的宽(上限仍是 `summaryWidth`),
    /// 那一行据此给每颗量宽。等分的行不传,理由见 `summaryWidth`。
    var fitsContent = false

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
            if beta { SettingsBetaBadge() }
            summaryView
                .frame(idealWidth: fitsContent ? nil : Self.summaryWidth, maxWidth: Self.summaryWidth, alignment: .leading)
                .clipped()
                .layoutPriority(-1)
        }
        // 悬停给出整句:摘要被压短或只报了数量时,不用点开浮层也知道是什么。
        .help(title + " · " + (detail ?? summary))
    }

    /// 摘要按「整段」取舍,不在一个值中间截断(只露半个词读不出是什么):放得下就整句;放不下就留开头几个
    /// 「 · 」分开的值、末尾加「…」;连第一个值都放不下就整截藏掉,只剩图标和标题。只有第一个值本身比摘要上限还长
    /// (用户自选的长字体名、长主题名,任何宽度下都放不全)才照旧按尾部截断。挑哪一档靠 `ViewThatFits` 比各档的
    /// 理想宽度,第一档是整句,所以按内容分宽那一行量到的理想宽度不变。见 04 章决策 87。
    private var summaryView: some View {
        let candidates = EditorToolbarSummary.candidates(summary)
        return ViewThatFits(in: .horizontal) {
            ForEach(candidates.indices, id: \.self) { index in
                summaryLine(candidates[index]).fixedSize()
            }
            EditorToolbarSummarySlot(
                hideBelow: Self.allowsTailTruncation(summary) ? EditorToolbarSummarySlot.hideBelow : .infinity
            ) {
                summaryLine(EditorToolbarSummary.parts(summary)[0])
            }
        }
    }

    private func summaryLine(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text("·")
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

extension EditorToolbarButtonLabel {
    /// 第一个值连同间隔点比摘要上限还宽:任何宽度下都放不全,只能截。
    static func allowsTailTruncation(_ summary: String) -> Bool {
        textWidth("· " + EditorToolbarSummary.parts(summary)[0]) > summaryWidth
    }
}

/// 一行工具栏胶囊按内容分宽(水位法):放得下时每颗按自己的理想宽度,放不下时摘要短的照旧拿满,亏空摊给最长的那几颗
/// (它们一样宽,先压摘要)。等分的话,摘要本来读得完的那颗也会陪着最长那颗被截。按钮的标签要传 `fitsContent: true`,
/// 否则理想宽度恒带着 140 的摘要,分不出长短。这一行不跟上一行逐列对齐。
///
/// 每颗压到「理想宽度 − 摘要可让的宽度」(`editorToolbarSummarySlack`)就不再压:再往下压截的是标题。
/// 所有按钮都到了这条底线还放不下(最窄卡片列下灵动岛第一行的英文、日文),才按底线的比例一起缩:亏空仍由摘要先吃,
/// 摘要窄过「…」时只露半个字。别给摘要加最小宽度去避开它:那样亏空转给标题,标题会被截到只剩「…」。
/// 按钮上没挂这个值的按 0 算,即不压。分完再按每颗摘要能画的几档落档(`EditorToolbarSummarySteps`、`EditorToolbarWidths.snap`):
/// 摘要整段藏掉或少掉末尾的值时,省下的宽度补给别的胶囊,不留在这颗里空着。
struct EditorToolbarContentWidthRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(available: proposal.width, subviews: subviews)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }
            .max() ?? 0
        return CGSize(width: widths.reduce(0, +) + gaps(subviews), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(available: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(subviews.count - 1, 0))
    }

    private func widths(available: CGFloat?, subviews: Subviews) -> [CGFloat] {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard let available else { return ideals }
        let floors = zip(subviews, ideals).map { $1 - max($0[EditorToolbarSummarySlack.self], 0) }
        let widths = EditorToolbarWidths.fill(ideals: ideals, floors: floors, room: available - gaps(subviews))
        let steps = zip(subviews, ideals).map { subview, ideal in subview[EditorToolbarSummarySteps.self].map { ideal - $0 } }
        return EditorToolbarWidths.snap(widths, steps: steps)
    }
}

/// 摘要最多能让出多少宽度:文字本身的宽(封顶 `summaryWidth`)减去压到底还留着的那一截。
struct EditorToolbarSummarySlack: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// 摘要能画的几档各比理想宽度窄多少(由少到多,第一档 0 是整句,最后一档是整截藏掉);空 = 不分档(长名字照旧连续截断)。
struct EditorToolbarSummarySteps: LayoutValueKey {
    static let defaultValue: [CGFloat] = []
}

/// 「· 当前值」放不下任何一整档时的那一截:分到的宽度低于 `hideBelow` 就整截不画(宽度报 0、外面 `.clipped()` 裁掉),
/// 按钮只剩图标和标题;够宽(只给放不全的长名字)才按尾部截断。
struct EditorToolbarSummarySlot: Layout {
    /// 长名字截断时的下限:间隔点、间距、省略号之外还能露十来个字母,露得更少就藏。
    static let hideBelow: CGFloat = 80

    /// 传 `.infinity` 就是一律藏。
    var hideBelow: CGFloat = Self.hideBelow

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        if (proposal.width ?? .infinity) < hideBelow {
            return CGSize(width: 0, height: child.sizeThatFits(.unspecified).height)
        }
        return child.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let width = bounds.width < hideBelow ? 0 : bounds.width
        child.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

extension EditorToolbarButtonLabel {
    /// 压到底时摘要那一截全让出来(连间隔点和它前面的间距,`EditorToolbarSummarySlot` 整截藏掉)。
    static let summaryFloor: CGFloat = -10

    /// 按工具栏的字号量摘要的宽,估出它能让出多少。字号跟各工具栏外层的 `.font(.system(size: 12))` 一致,改一处要一起改。
    static func summarySlack(_ summary: String) -> CGFloat {
        max(min(textWidth(summary), summaryWidth) - summaryFloor, 0)
    }

    /// 各档比理想宽度窄多少,给 `EditorToolbarContentWidthRow` 落档用:少掉末尾值的几档按文字差算、多留 1pt
    /// (量出来的跟实际排版差零点几 pt,宁可宽一点,别差一丝落到下一档);藏掉那一档同 `summarySlack`。长名字不分档。
    static func summarySteps(_ summary: String) -> [CGFloat] {
        guard !allowsTailTruncation(summary) else { return [] }
        let full = min(textWidth(summary), summaryWidth)
        let shorter = EditorToolbarSummary.candidates(summary).dropFirst().map { max(full - textWidth($0) - 1, 0) }
        return [0] + shorter + [summarySlack(summary)]
    }

    static func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}

extension View {
    /// 挂在 `EditorToolbarContentWidthRow` 里每颗按钮的最外层:告诉那一行这颗的摘要能让多少宽。
    func editorToolbarSummarySlack(_ summary: String) -> some View {
        layoutValue(key: EditorToolbarSummarySlack.self, value: EditorToolbarButtonLabel.summarySlack(summary))
            .layoutValue(key: EditorToolbarSummarySteps.self, value: EditorToolbarButtonLabel.summarySteps(summary))
    }
}
