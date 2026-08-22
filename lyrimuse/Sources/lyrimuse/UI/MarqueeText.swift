import LyrimuseCore
import SwiftUI

// 超长文字(歌名/歌词)靠自动滚动展示全部内容,而不是硬截断/省略号。测量内容真实宽度
// vs 容器宽度,只有真的溢出容器时才滚动,没溢出的短文字保持静止不动、不产生任何动画。
//
// 一轮是"停在开头→匀速滚到底→停在末尾→**瞬时**回到开头",不是无限单向卷动,不需要为了
// 卷动无缝衔接去复制一份内容拼接。回到开头这一步刻意不做补间 —— 那不只是观感取舍,
// 是换句时不出错的前提,理由写在 restart() 和滚动循环里那两段。
//
// id 参数控制"什么时候该重新测量、重新从头开始滚动"——歌词行内部逐字变色(由外面
// TimelineView 驱动)不应该打断/重置正在进行的滚动,那只是同一句歌词内部的高亮进度
// 在变,不是这一行内容本身换了;只有真的换了一句歌词、换了一首歌才应该重新开始。
// Swift 不支持泛型类型里放 static stored property,这两个纯常量挪到文件作用域。
let marqueePixelsPerSecond: Double = 24
let marqueeHoldDuration: Double = 1.1

struct MarqueeText<Content: View>: View {
    let id: AnyHashable
    /// **没溢出时**内容靠容器哪一边。溢出时一律 .leading,不受这个参数影响 —— 滚动是
    /// "从头开始往左推",内容比容器宽时靠右摆等于一上来就把开头几个字挂在容器外面。
    ///
    /// 2026-08-20 加。灵动岛右耳的歌手名原来是 `Spacer() + Text`(靠右贴着音浪),换成
    /// 跑马灯之后 GeometryReader 会占满可用宽度,短名字(绝大多数情况)就从右边跳到了
    /// 左边、跟音浪之间空出一大段。默认值保持 .leading,已有调用点行为不变。
    var restingAlignment: Alignment = .leading
    /// 内容溢出、而且此刻**停在开头**时,右端渐隐带的宽度(0 = 不渐隐,默认)。
    ///
    /// 2026-08-22 加。为什么需要它、为什么只在"停在开头"时给、为什么传宽度而不是
    /// gradient 的 stop —— 三条理由都写在 `MarqueeMath.trailingFadeWidth` 上,不重复。
    /// 目前只有灵动岛的**歌词行**传非 0:那一行右边紧挨一枚 32pt 封面,只隔 10pt,硬切口
    /// 落在那里肉眼分不清"被裁掉"和"被封面盖住"。顶行的歌名/歌手同样是硬切,但它们旁边
    /// 是刘海/音浪而不是封面,没有同样的误读风险,保持原样(要开就在调用点传值即可)。
    var edgeFadeWidth: CGFloat = 0
    @ViewBuilder let content: () -> Content

    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// 每次重新开始滚动就 +1。它本身不参与画面,只为了让归零那次赋值**一定**是一次真的
    /// 状态变化 —— 详见 restart() 里那段。
    @State private var generation: Int = 0
    @State private var scrollTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { outerProxy in
            content()
                .fixedSize(horizontal: true, vertical: false)
                // ⚠️ 这里**不能**用 PreferenceKey 把宽度传上去,尽管那是最常见的写法(本文件
                // 2026-08-16 之前正是那么写的,而且是个静默失效的真 bug)。
                //
                // 实测:GeometryReader 自己测得完全正确(打印 innerProxy.size.width = 428.5),
                // 但外面 .onPreferenceChange 收到的是 PreferenceKey 的 defaultValue 0,
                // **而且之后再也不会收到第二次** —— 于是 distance 恒为负,guard 直接 return,
                // 跑马灯永远不滚,超长内容被 .clipped() 硬裁掉。
                //
                // 触发条件很刁钻,这也是它藏了这么久的原因:content 是**单个 Text** 时,首次
                // 布局就有固有宽度,preference 第一次发布就是真值,一切正常;而 content 是
                // `HStack { ForEach { ... } }`(灵动岛的**逐字歌词**行就是这个形状,外面还套
                // 着 TimelineView)时,首次发布的是 0,后续的正确宽度再也没传上来。表现就是
                // "普通歌词会滚、逐字歌词不滚",而逐字歌词恰恰是这个 App 最主要的展示形态。
                //
                // 改成直接在 GeometryReader 里回写 @State,不经过 preference 那条链路。
                .background(
                    GeometryReader { innerProxy in
                        Color.clear
                            .onAppear { apply(content: innerProxy.size.width, container: outerProxy.size.width) }
                            .onChange(of: innerProxy.size.width) { _, w in
                                apply(content: w, container: outerProxy.size.width)
                            }
                    }
                )
                .offset(x: -offset)
                // 归零那一下必须**瞬时**,不能被任何补间接管(理由见 restart())。
                //
                // generation 每次 restart 都会变,这条修饰符就在那一刻把 offset 的变化钉成
                // "不补间";平时滚动的那两次 withAnimation 不碰 generation,不受它影响。
                //
                // ⚠️ 顺带一件要紧的事:generation 必须像这样**被 body 真的读到**。@State 的
                // 失效是按依赖追踪的 —— body 里没读的 @State 改了也不会触发重新求值,
                // 那样 restart() 里那次"关掉动画的归零"就等于没发生。
                .animation(nil, value: generation)
                // 垂直居中——GeometryReader 默认把内容摆在自己左上角,不居中的话文字
                // 会紧贴着这一整行的顶边。横向见 restingAlignment。
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: isOverflowing ? .leading : restingAlignment)
                // 容器变宽变窄(用户拖灵动岛/悬浮窗的宽度滑块)同样要重算,不然原来溢出的
                // 内容拖宽之后还在滚、或者反过来拖窄了不滚。
                .onChange(of: outerProxy.size.width) { _, w in
                    apply(content: contentWidth, container: w)
                }
                .onChange(of: id) {
                    // 换了一句歌词/一首歌:即使新内容宽度碰巧跟旧的一模一样(apply 会因此
                    // 跳过),滚动位置也必须回到起点重新开始。
                    restart()
                }
        }
        .clipped()
        // ⚠️ 无条件挂,不写成 `if fadeWidth > 0 { .mask(...) }`:那样渐隐带宽度归零的
        // 那一刻视图身份会变、整棵子树重建,正在跑的滚动动画会被打断。宽度为 0 时
        // gradient 那一段本身就是零宽,等效于没有 mask。
        .mask(fadeMask)
        .onDisappear { scrollTask?.cancel() }
    }

    /// 内容比容器宽出多少(负数=装得下)。判据本体在 Core(MarqueeMath),这里只转发 ——
    /// 分层边界的理由见 AGENTS.md「XxxxView.swift 里不放几何/数学」。
    private var overflow: CGFloat {
        MarqueeMath.overflow(contentWidth: contentWidth, containerWidth: containerWidth)
    }

    /// 值得滚吗。restart() 的启动判据和下面的对齐判据必须是同一份 —— 两处各写一遍就会
    /// 出现"在滚但按没溢出对齐"这种自相矛盾的状态。
    private var isOverflowing: Bool {
        MarqueeMath.isOverflowing(contentWidth: contentWidth, containerWidth: containerWidth)
    }

    /// 右端渐隐带当前宽度。offset 是**模型值**,这正是想要的:归零走
    /// `disablesAnimations` 的事务(渐隐带瞬时出现,跟文字瞬时归位同步),起步走
    /// `withAnimation(.linear)`(渐隐带跟着平滑收掉)。
    private var fadeWidth: CGFloat {
        MarqueeMath.trailingFadeWidth(configured: edgeFadeWidth,
                                      contentWidth: contentWidth,
                                      containerWidth: containerWidth,
                                      offset: offset)
    }

    /// 遮罩:左边一整块不透明 + 右端一条 black→clear 的渐隐带。渐隐带是 `.frame(width:)`
    /// 而不是 gradient 的 stop 位置,这样宽度变化可动画(理由见 MarqueeMath)。
    private var fadeMask: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fadeWidth)
        }
    }

    private func apply(content: CGFloat, container: CGFloat) {
        guard content != contentWidth || container != containerWidth else { return }
        contentWidth = content
        containerWidth = container
        restart()
    }

    private func restart() {
        scrollTask?.cancel()
        scrollTask = nil
        // ⚠️ 归零必须在**关掉动画的事务**里做,而且要保证这次赋值真的是一次状态变化。
        //
        // 2026-08-17 用户报的两个症状("换句时文字从右边滑回开头"、"有时候慢慢滚回到
        // 对应的位置")是同一个根因:`Task.cancel()` 停得掉下面那个 while 循环,却停不掉
        // **已经发出去的那条 SwiftUI 动画**。
        //
        // 回程那半段是 `withAnimation { offset = 0 }` —— 动画一发出,模型值当场就是 0 了,
        // 而屏幕上的文字还要滑 travelDuration 秒才回到位。若正好在这段时间里换句,
        // 老写法这里再写一次 `offset = 0` 属于"赋同一个值",SwiftUI 不会重新求值、更不会
        // 重新定向,那条回程动画于是继续跑 —— 把**新一句**的文字从半路慢慢挪回来。
        // 换句发生在去程途中则是另一半症状:从 distance 一路滑回 0。
        //
        // generation 就是为了破掉"赋同一个值"这件事:它每次都变,这次更新一定会发生,
        // 而 disablesAnimations 保证它是瞬时的。
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
            generation &+= 1
        }
        guard isOverflowing else { return }
        let distance = overflow
        let travelDuration = Double(distance) / marqueePixelsPerSecond
        scrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(marqueeHoldDuration * 1_000_000_000))
                if Task.isCancelled { return }
                withAnimation(.linear(duration: travelDuration)) { offset = distance }
                try? await Task.sleep(nanoseconds: UInt64(travelDuration * 1_000_000_000) + UInt64(marqueeHoldDuration * 1_000_000_000))
                if Task.isCancelled { return }
                // ⚠️ 回程是**瞬时**的,不是滑回去 —— 这一条不是审美选择,是正确性要求。
                //
                // 2026-08-17 实测(灵动岛换句瞬间连拍):老写法这里是
                // `withAnimation(.linear(duration: travelDuration)) { offset = 0 }`,
                // 动画一发出,**模型值当场就是 0**,而屏幕上的文字还要滑好几秒才回到位。
                // 若在这段时间里换句,restart() 里那次归零就是"赋同一个值" —— `.offset`
                // 的可动画数据没有变化,SwiftUI 没有任何理由去重新定向那条已经在跑的动画,
                // 于是它继续把**新一句**的文字从半路慢慢挪回来。抓到的帧里,新一句在换句
                // 后 0.17 秒仍缺着开头几个字,再过 0.4 秒才右移约 9.6pt(正好是
                // marqueePixelsPerSecond × 0.4)。第一版只在归零时关掉动画,治不了它 ——
                // 因为压根没触发那次更新。
                //
                // 改成瞬时归位之后,模型值只可能是两种:有动画在跑时是 distance、静止时是 0。
                // 于是换句归零必定是一次**真实**的值变化,老动画一定会被顶掉。
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { offset = 0 }
                try? await Task.sleep(nanoseconds: UInt64(marqueeHoldDuration * 1_000_000_000))
            }
        }
    }
}
