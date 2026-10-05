import LyrimuseCore
import SwiftUI

/// 「歌词显示 › 触控栏」那一段「显示封面」「显示播放控制」下面那一行「位置」的控件:摆在歌词左边还是右边
/// (`TouchBarSide`,两项各管各的)。跟别处从属行里的二选一一样用下拉菜单(同歌词窗口背景的「方向」)。
struct TouchBarSidePicker: View {
    @Binding var selection: TouchBarSide

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(TouchBarSide.allCases, id: \.self) { side in
                Text(side.displayName).tag(side)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}
