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
    @State private var offset: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { outerProxy in
            content()
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { innerProxy in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: innerProxy.size.width)
                    }
                )
                .offset(x: -offset)
                // 垂直居中——GeometryReader 默认把内容摆在自己左上角,不居中的话文字
                // 会紧贴着这一整行的顶边。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .onPreferenceChange(MarqueeWidthKey.self) { width in
                    contentWidth = width
                    restart(containerWidth: outerProxy.size.width)
                }
                .onChange(of: id) {
                    restart(containerWidth: outerProxy.size.width)
                }
        }
        .clipped()
        .onDisappear { scrollTask?.cancel() }
    }

    private func restart(containerWidth: CGFloat) {
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

struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
