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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 三条弹簧,按"正在做哪件事"选。参数取自 boring.notch 调好的那三组,不是拍脑袋:
    ///
    ///  - **收起**(播放停了,歌词行卷回顶行):`dampingFraction 1.0` —— 临界阻尼、**不回弹**。
    ///    收起时哪怕一点点回弹,看着都像"没收干净又弹出来一截",特别扎眼。
    ///  - **展开**(hover 进来):`interactiveSpring 0.38 / 0.8` —— 对鼠标的直接反馈,要跟手。
    ///  - **其余**(开始播放弹出、以及 hover 移开收回那一档):`0.42 / 0.8`,留一点点过冲。
    ///
    /// ⚠️ 已知的一处名不副实,别照着注释想当然:`.animation(_:value:)` 是在值**变化后**
    /// 用新状态求值,所以"hover 移开"这一档跑到这里时 isExpanded 已经是 false,落在最后
    /// 那条 0.42 而不是 interactiveSpring。只看当前状态区分不出"刚从收起弹出"和"hover
    /// 移开",要分开就得再存一份上一帧的状态。实际差别是 response 0.42 vs 0.38、阻尼相同,
    /// 0.04 秒,肉眼看不出来 —— 所以没为它引入额外状态,但注释得写实话。
    ///
    /// reduceMotion 下返回 nil(直接跳到终态)。这不只是"少点花哨":收起/弹出是**尺寸**动画,
    /// 前庭敏感的人对这类大面积位移最不适应,而跳变不损失任何信息。跟进度条那处
    /// (NotchLyricsView.scrubberHeight)的取舍不同 —— 那边变粗是**功能反馈**,必须保留,
    /// 只去掉补间;这边整段动画本身就是纯观感,可以整个跳过。
    private var cardAnimation: Animation? {
        if reduceMotion { return nil }
        if controller.isCollapsed {
            return .spring(response: 0.45, dampingFraction: 1.0)
        }
        if controller.isExpanded {
            return .interactiveSpring(response: 0.38, dampingFraction: 0.8)
        }
        return .spring(response: 0.42, dampingFraction: 0.8)
    }

    /// 卡片宽度:收起态(没在播放)缩到「刘海 + 左右各一小段耳朵」。
    ///
    /// 此前恒定不缩,理由是"耳朵里有三个控制按钮,宽度一缩没地方放"。2026-08-19 设计
    /// 评审把三键挪进展开卡、右耳只剩一枚播放键之后,这条理由不复存在 —— 收起态那条
    /// 全宽黑带的宽度全是死空间(用户:"左右各自保留一点空间即可")。耳宽取
    /// NotchMetrics.collapsedEarWidth(左耳只放音浪,右耳只放小封面 —— 同日再收窄成
    /// iPhone 灵动岛式极简,见 collapsedRow),
    /// +20 对应 topRow 的水平 padding;min 兜底"刘海比用户设的内容宽度还宽"的怪配置。
    /// 稳态/展开仍是全宽:歌词行和展开区需要空间。宽度变化跟高度同一条弹簧(cardAnimation)。
    private var cardWidth: CGFloat {
        if controller.isCollapsed {
            return min(controller.steadyCardWidth,
                       controller.notchWidth + 2 * NotchMetrics.collapsedEarWidth + 20)
        }
        return controller.steadyCardWidth
    }

    /// 卡片当前高度。收起态只留顶行那一条,稳态多一行歌词,展开再多一块。
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
            // 三种形态切换用三条**不同**的弹簧,理由见 cardAnimation。
            .animation(cardAnimation, value: cardHeight)
            .animation(cardAnimation, value: cardWidth)
            // 收起/弹出时内容整块淡入淡出,由同一条弹簧驱动,跟尺寸变化同步。
            .animation(cardAnimation, value: controller.isCollapsed)
    }

    private func updateHover(inside: Bool) {
        // 触觉反馈:贴刘海的东西离光标很近但没有边框可循,给一下对齐反馈能让"我确实停在
        // 它上面了"变成可感知的事(Force Touch 触控板才有,其它设备是空操作)。
        // ⚠️ 在**进入的那一刻**就给,不等 setExpandedFromWindow 里那 0.2s 意图延迟兑现 ——
        // 拖到延迟之后就跟手感脱节了。所以这里自己记一下上一次的状态,只在边沿触发。
        if inside, !controller.isExpanded, !hoveringCard {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        // setExpandedFromWindow 也只在**边沿**上叫(2026-08-19):onContinuousHover 的
        // .active 对卡片内每次指针移动都回调,原来每个事件都调过去,而那边第一行无条件
        // cancel 掉还没兑现的 0.12s 展开意图再重排 —— 于是"进入延迟"实际从「指针停下」
        // 起算而不是「进入」起算(hoverEnterDelay 的调校注释按后者理解),指针在卡片上
        // 持续移动就一直不展开,顺带每个事件白做一次 WorkItem 取消+分配。边沿触发后
        // "进了又出净效果为零"的 cancel 语义不受影响(exit 边沿照样撤掉未兑现的 enter)。
        let changed = inside != hoveringCard
        hoveringCard = inside
        if changed { controller.setExpandedFromWindow(inside) }
    }
}
