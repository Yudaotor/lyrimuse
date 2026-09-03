import LyrimuseCore
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
    /// 「暂停/无播放时隐藏」的退场动画(2026-09-02):整卡以刘海中心为锚 scale→0 并透明,
    /// 缩进刘海里。首版是"先播收起弹簧再走",用户目验后否掉——不要经过暂停收起态,直接从
    /// 正常大小缩到无;时长按用户"半秒太久、砍一半"的口径取 0.2s,ease-in(加速冲进刘海)。
    static let vanishDuration: TimeInterval = 0.2
    /// 控制器等这么久再 orderOut——比 vanishDuration 略长,让最后一帧真的落到 0。改动画时长
    /// 要连着改这里。
    static let vanishSettleDelay: TimeInterval = 0.25
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

    /// 卡片当前高度。收起态只留顶行那一条,稳态多一行歌词(用户关掉「显示歌词」时也不留),
    /// 展开再多一块。
    ///
    /// ⚠️ 公式本体在 `NotchChromeSource` 的协议扩展里 —— 设置页编辑台读的是同一份。
    /// 2026-08-31 之前这里和那边各写了一遍,而入参已经涨到四个;本章设计决策里那条
    /// "两处各自判断必然漂"说的就是这种地方。
    private var cardHeight: CGFloat { controller.cardHeight }

    /// 退场/回场动画:缩进刘海用 ease-in(vanishDuration);**回场瞬时,不做动画**。
    /// `.animation(_:value:)` 用变化后的新值求值,所以 isVanished 刚翻 true 走前者、
    /// 刚翻 false 走后者。reduceMotion 下一律 nil(控制器那边也不会进这条路)。
    ///
    /// ⚠️ **回场那一档 2026-09-03 从 `.spring(0.42, 0.8)` 改成 nil**,用户报「从广告变成歌
    /// 的时候灵动岛的封面是平移过来的,不是直接就切换了外观」。抓帧坐实(按窗口 ID 连拍
    /// 灵动岛那扇窗,24 帧/次):空档期卡片整个消失(连续 13 帧字节数完全相同),新歌开始时
    /// 只跨 1 帧就长回终态,中间那一帧卡片明显比终态窄、内容整体偏移 —— 那是
    /// `scaleEffect(0.001 → 1, anchor: .top)` 的中间态。卡片背景在 `.coverArt` 风格下就是
    /// 封面模糊图,整卡放大时封面跟着一起被重新缩放/裁切,观感就是"封面平移过来"。
    ///
    /// ⚠️ **退场那一档不动**:2026-09-02 用户明确要过「直接从正常大小缩小到无」,那是他点过
    /// 头的。回场这条弹簧是当时对称加上去的、没有单独的用户依据 —— 两个方向本来就不必对称:
    /// 退场是"东西要走了",给一点动画是交代;回场是"新歌来了",用户要的是立刻看到新外观。
    ///
    /// 2026-09-03 下午起回场由出场动画(下面 body 里的 keyframeAnimator,裁剪撑开、不缩放)负责,这里的
    /// nil 仍然正确、而且必须是 nil:scale 要瞬时回 1,渐显交给裁剪去做,两者叠加就又回到"封面被缩放"。
    private var vanishAnimation: Animation? {
        if reduceMotion { return nil }
        return controller.isVanished ? .easeIn(duration: Self.vanishDuration) : nil
    }

    /// 出场动画的起始几何:从真刘海两侧撑开、只露顶行。按当前卡片尺寸换算成比例(裁剪形状按比例画,
    /// 卡片在动画中途变尺寸也不会算错)。纯函数在 LyrimuseCore.NotchReveal,selftest 钉着边界。
    private var revealStartWidth: CGFloat {
        NotchReveal.startWidthFraction(notchWidth: controller.notchWidth, cardWidth: cardWidth)
    }
    private var revealStartHeight: CGFloat {
        NotchReveal.startHeightFraction(topRowHeight: controller.contentTopInset, cardHeight: cardHeight)
    }

    var body: some View {
        NotchLyricsView(controller: controller)
            .frame(width: cardWidth, height: cardHeight)
            // 出场动画「从刘海撑开」(2026-09-03,用户拍板):卡片「从无到有」露面时(冷启动 / 手动打开 /
            // 从刘海回场,由控制器的 revealGeneration 计数触发)播一遍 —— 裁剪区从真刘海宽、顶行高起,横向
            // 0.20s 撑到全宽,纵向按住 0.06s 后 0.24s 长到全高,内容 0.10s 后 0.16s 淡入,总 0.30s。
            //
            // ⚠️ 只裁剪、不缩放:同日上午用户报「封面平移过来」,根因是回场 scaleEffect(0.001 → 1) 让
            // 封面模糊底一起被重新缩放裁切;裁剪路线内容始终在终态位置,封面一个像素都不动。
            // ⚠️ initialValue 是终态:keyframeAnimator 首次出现时停在 initialValue、trigger 变了才动,
            // 若 initialValue 写成起始态,视图第一次出现会永远卡在一条细缝上。每条轨用 MoveKeyframe
            // 先跳到起始态再长满。reduceMotion 时 trigger 恒为 0,永不播,卡片始终是终态。
            .keyframeAnimator(initialValue: NotchRevealState.settled,
                              trigger: reduceMotion ? 0 : controller.revealGeneration) { card, state in
                card
                    .environment(\.notchRevealContentOpacity, state.contentOpacity)
                    .clipShape(NotchRevealShape(widthFraction: state.widthFraction,
                                                heightFraction: state.heightFraction))
            } keyframes: { _ in
                KeyframeTrack(\.widthFraction) {
                    MoveKeyframe(revealStartWidth)
                    SpringKeyframe(1, duration: NotchReveal.widthDuration,
                                   spring: Spring(response: 0.22, dampingRatio: 0.9))
                }
                KeyframeTrack(\.heightFraction) {
                    MoveKeyframe(revealStartHeight)
                    LinearKeyframe(revealStartHeight, duration: NotchReveal.heightDelay)
                    SpringKeyframe(1, duration: NotchReveal.heightDuration,
                                   spring: Spring(response: 0.26, dampingRatio: 0.85))
                }
                KeyframeTrack(\.contentOpacity) {
                    MoveKeyframe(0)
                    LinearKeyframe(0, duration: NotchReveal.contentDelay)
                    CubicKeyframe(1, duration: NotchReveal.contentDuration)
                }
            }
            // 「暂停/无播放时隐藏」的退场态:整卡以顶边中点(=刘海中心)为锚缩到无、同时透明,
            // 看起来是被吸进刘海;不取 0 而取 0.001,避开退化变换。尺寸(frame)不参与——
            // isCollapsed 在这个开关开着时不算暂停,卡片保持稳态尺寸,只有这个缩放在动。
            .scaleEffect(controller.isVanished ? 0.001 : 1, anchor: .top)
            .opacity(controller.isVanished ? 0 : 1)
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
            .animation(vanishAnimation, value: controller.isVanished)
    }

    private func updateHover(inside: Bool) {
        // 触觉反馈(2026-08-23 挪走):不再在这里"一进卡片边界就发",改到
        // NotchLyricsWindowController.setExpandedFromWindow 里卡片**真正展开**的那一刻
        // 才给——原来提前 hoverEnterDelay(0.12s)发,用户反馈"震动跟展开动作脱节、
        // 时机不对、还太强太突兀";现在跟视觉展开同步,反馈模式也换成更柔和的 .generic。
        //
        // setExpandedFromWindow 只在**边沿**上叫(2026-08-19):onContinuousHover 的
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
