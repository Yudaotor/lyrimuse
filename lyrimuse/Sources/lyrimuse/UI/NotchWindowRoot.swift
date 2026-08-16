import SwiftUI

// 真窗口里装 NotchLyricsView 的那一层壳。
//
// 2026-08-16 之前没有这一层:窗口本身随收起/稳态/展开三种形态反复 setFrame,卡片永远
// 等于窗口。改成"窗口常驻最大尺寸,卡片在里面自己变大变小"之后,多出来的这一层负责
// 两件事:把卡片钉成当前该有的尺寸、贴顶居中摆好,以及给尺寸变化配一条弹簧动画。
//
// 这么改的收益:
// 1. **开合是真的动画**。NSWindow.setFrame(animate:) 那条路要么瞬间跳变(现状),要么
//    用 AppKit 自己那条时长固定、曲线不可换的过渡;放进 SwiftUI 之后可以用弹簧,而且
//    仍然跟手(interactiveSpring 的响应时间比一次 hover 停顿短得多)。
// 2. **投影终于画得出来**。hover 时那圈 .shadow 以前被窗口边界硬裁掉了——窗口紧贴卡片
//    外沿,阴影没有地方可画。现在窗口比卡片大一圈,阴影落在透明区里。
// 3. 不必再在每次形态切换时手动同步 NSHostingView 的 frame(那是 setFrame 那条路留下的
//    补丁,见 NotchLyricsWindowController.hostingView 上的注释)。
//
// ⚠️ 这一层多出来的那片透明区域**绝对不能**加任何 background/contentShape:窗口 level 是
// .screenSaver(在系统菜单栏之上),透明区正压着菜单栏那一条。实测(2026-08-16,拿同样
// flag 的探针窗口盖住一个普通窗口再投一次点击)确认:纯透明区域的点击会穿透到下面的窗口;
// 但只要给它加一层哪怕完全透明的 Color.clear.contentShape(Rectangle()),点击就会被这个
// 窗口吞掉 —— 那意味着用户点不动被盖住的那一段菜单栏。这是这次重构唯一的真风险点。
struct NotchWindowRoot: View {
    @ObservedObject var controller: NotchLyricsWindowController
    /// 光标上一次是不是在卡片上 —— 只为了让触觉反馈在"进入"那一下触发一次,不是状态源。
    @State private var hoveringCard = false

    /// 卡片当前宽度:收起态是物理刘海本身的宽度,其余是设置里那个宽度(过一遍耳朵下限)。
    private var cardWidth: CGFloat {
        controller.isCollapsed ? controller.collapsedCardWidth : controller.steadyCardWidth
    }

    /// 卡片当前高度。收起态只有刘海那一条,稳态多一行歌词,展开再多一块。
    private var cardHeight: CGFloat {
        if controller.isCollapsed { return controller.contentTopInset }
        return controller.contentTopInset
            + NotchMetrics.compactRowHeight
            + (controller.isExpanded ? NotchMetrics.expandedExtraHeight : 0)
    }

    var body: some View {
        NotchLyricsView(controller: controller)
            .frame(width: cardWidth, height: cardHeight)
            // 命中形状显式钉成卡片这个矩形,hover 判定就挂在**卡片本身**上。
            //
            // ⚠️ 两条都是实测出来的,别改回去:
            // 1. 挂在外层那个撑满窗口的容器上**收不到 hover** —— 那个容器自己没有任何
            //    可命中的内容,SwiftUI 不会给它装跟踪区域,光标压在卡片上也一个事件都不来。
            // 2. 不加 contentShape 而直接用 NotchLyricsView 自带的 .onHover,触发范围会比
            //    卡片大一圈(预览那边早记录过同一现象)。窗口没改之前这无害,现在卡片下面是
            //    一大片透明区,大一圈就等于"鼠标还在用户自己的窗口上,灵动岛自己展开了"。
            // contentShape 只盖卡片这一块,不碰透明区,所以不影响那片区域的点击穿透。
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active: updateHover(inside: true)
                case .ended: updateHover(inside: false)
                }
            }
            // 贴顶 + 水平居中。窗口本身是按刘海中心点摆的,所以"在窗口里居中"就等于
            // "对齐刘海中心",跟改动前 setFrame 算出来的位置是同一个结果。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // 展开/收起用同一条弹簧。response 取得比 hover 的意图延迟(0.2s)还短,
            // 保证"动画"不会变成"迟钝"——这个卡片的开合是对鼠标的直接反馈。
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: cardHeight)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: cardWidth)
    }

    private func updateHover(inside: Bool) {
        // 触觉反馈:贴刘海的东西离光标很近但没有边框可循,给一下对齐反馈能让"我确实停在
        // 它上面了"变成可感知的事(Force Touch 触控板才有,其它设备是空操作)。
        // ⚠️ 在**进入的那一刻**就给,不等 setExpandedFromWindow 里那 0.2s 意图延迟兑现 ——
        // 拖到延迟之后就跟手感脱节了。所以这里自己记一下上一次的状态,只在边沿触发。
        if inside, !controller.isExpanded, !hoveringCard {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        hoveringCard = inside
        controller.setExpandedFromWindow(inside)
    }
}
