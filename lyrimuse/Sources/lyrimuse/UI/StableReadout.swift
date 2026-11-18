import SwiftUI

/// 滑杆旁边的读数:宽度按 `widest`(这根滑杆能到的最大值那一串)留,不写定值,单行不折。
/// 定值在单位前带空格或单位更长的语言里放不下最大那几个数,会折成两行(俄语「1270 пт」、各语言 13pt 的「100%」);
/// 按读数本身的宽又会随位数跳。`minWidth` 给同一张卡片里几根滑杆对齐用:放得下时宽度不变,放不下才撑开。
/// `font` 为 nil 时沿用外面的字号(设置页各行的读数跟行内其它文字同字号)。见 14 章决策 172、220。
struct StableReadout: View {
    let text: String
    let widest: String
    var font: Font? = .system(size: 11, weight: .medium)
    var minWidth: CGFloat = 0
    @Environment(\.font) private var inheritedFont

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear.frame(width: minWidth, height: 0)
            Text(widest).hidden()
            Text(text)
        }
        .font(font ?? inheritedFont)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    /// 「%@pt」读数的 `widest`:滑杆上界按读数同一种写法排出来。
    static func points(_ upperBound: Double) -> String {
        String(format: L10n.t("%@pt"), "\(Int(upperBound))")
    }

    /// 百分比读数的 `widest`:上界(已是百分数)排成「100%」。
    static func percent(_ upperBound: Double) -> String {
        "\(Int(upperBound.rounded()))%"
    }
}
