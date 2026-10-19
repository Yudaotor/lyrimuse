import AppKit
import SwiftUI

/// 给滚动视图做边缘渐隐的遮罩:渐隐只作用在内容区,最右边滚动条那一条整条不透明。
/// `.mask` 挂在 ScrollView 上时滚动条也在被遮的范围里,直接用渐隐当遮罩会把滚动条的两端一起淡掉(见 11 章决策 133)。
struct ScrollerSafeMask<Fade: View>: View {
    @ViewBuilder var fade: () -> Fade

    var body: some View {
        HStack(spacing: 0) {
            fade()
            Rectangle()
                .frame(width: NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle))
        }
    }
}
