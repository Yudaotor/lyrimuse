import SwiftUI

/// 编辑台调整条右端的读数(悬浮歌词、菜单栏的宽度条):宽度按 `widest`(这根条能到的最大值那一串)留,不写定值。
/// 定值在单位前带空格或单位更长的语言里放不下最大那几个数,会折成两行(俄语「1270 пт」);按读数本身的宽又会随位数跳。
/// 字号、等宽数字跟两根条原来的写法一致。
struct EditorStageReadout: View {
    let text: String
    let widest: String

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(widest).hidden()
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}
