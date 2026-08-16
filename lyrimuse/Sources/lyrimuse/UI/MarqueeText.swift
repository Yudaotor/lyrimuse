import SwiftUI

// 超长文字(歌名/歌词)靠自动来回滚动展示全部内容,而不是硬截断/省略号。测量内容
// 真实宽度 vs 容器宽度,只有真的溢出容器时才滚动,没溢出的短文字保持静止不动、不
// 产生任何动画。滚动方式是"停顿→滚到底→停顿→滚回起点"来回滚动,不是无限单向卷动,
// 不需要为了卷动无缝衔接去复制一份内容拼接。
//
// id 参数控制"什么时候该重新测量、重新从头开始滚动"——歌词行内部逐字变色(由外面
// TimelineView 驱动)不应该打断/重置正在进行的滚动,那只是同一句歌词内部的高亮进度
// 在变,不是这一行内容本身换了;只有真的换了一句歌词、换了一首歌才应该重新开始。
// Swift 不支持泛型类型里放 static stored property,这两个纯常量挪到文件作用域。
let marqueePixelsPerSecond: Double = 24
let marqueeHoldDuration: Double = 1.1

struct MarqueeText<Content: View>: View {
    let id: AnyHashable
    @ViewBuilder let content: () -> Content

    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
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
                // 垂直居中——GeometryReader 默认把内容摆在自己左上角,不居中的话文字
                // 会紧贴着这一整行的顶边。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
        .onDisappear { scrollTask?.cancel() }
    }

    private func apply(content: CGFloat, container: CGFloat) {
        guard content != contentWidth || container != containerWidth else { return }
        contentWidth = content
        containerWidth = container
        restart()
    }

    private func restart() {
        scrollTask?.cancel()
        offset = 0
        let distance = contentWidth - containerWidth
        guard distance > 4, containerWidth > 0 else { return }
        let travelDuration = Double(distance) / marqueePixelsPerSecond
        scrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(marqueeHoldDuration * 1_000_000_000))
                if Task.isCancelled { return }
                withAnimation(.linear(duration: travelDuration)) { offset = distance }
                try? await Task.sleep(nanoseconds: UInt64(travelDuration * 1_000_000_000) + UInt64(marqueeHoldDuration * 1_000_000_000))
                if Task.isCancelled { return }
                withAnimation(.linear(duration: travelDuration)) { offset = 0 }
                try? await Task.sleep(nanoseconds: UInt64(travelDuration * 1_000_000_000))
            }
        }
    }
}
