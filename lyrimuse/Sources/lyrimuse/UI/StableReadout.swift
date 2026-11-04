import SwiftUI

/// 滑杆旁边的读数(编辑台的宽度条、菜单栏面板的几根滑杆):宽度按 `widest`(这根滑杆能到的最大值那一串)留,不写定值。
/// 定值在单位前带空格或单位更长的语言里放不下最大那几个数,会折成两行(俄语「1270 пт」);按读数本身的宽又会随位数跳。
struct StableReadout: View {
    let text: String
    let widest: String
    var font: Font = .system(size: 11, weight: .medium)

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(widest).hidden()
            Text(text)
        }
        .font(font)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}
