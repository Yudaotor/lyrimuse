import SwiftUI

// 灵动岛左耳歌名前面那几根"跳动的均衡条"——纯装饰性的播放指示器,不是真的频谱。
//
// ⚠️ 名字叫均衡条,但它跟音频数据没有任何关系,也不该有:拿到真实频谱需要 CoreAudio 抓
// 系统输出(要么装虚拟声卡,要么申请录屏/录音权限),对一个"显示歌词"的 App 来说代价完全
// 不成比例。被参考的那个 fork 的 README 宣称有频谱,读代码发现它的 visualizer.metal 根本
// 没进编译清单,实际画的也是随机动画 —— 这里不重复那种宣称,注释和 UI 文案都只说"播放
// 指示",不说"频谱"。
//
// 性能:用 .animation(minimumInterval:) 而不是裸的 .animation。后者是每帧(60/120Hz)重算
// 一次 body,而这个视图常驻在屏幕顶端 —— 这个 App 已经有一条 20Hz 的逐字填色热路径了,
// 不该再挂一条更热的纯装饰路径上去。给了 minimumInterval 之后 0.28 秒才重算一次、换一个
// 目标高度,中间的过渡交给隐式动画在 Core Animation 那边跑(不经过 SwiftUI 重算)。
//
// ⚠️ 不能用 .periodic:它没有 paused 参数,暂停时条子会一直跳。
struct EqualizerBars: View {
    var color: Color
    var isPlaying: Bool

    /// 换一次高度的间隔。0.28s 是试出来的:再快就显得毛躁、跟音乐没关系的抖动感很强,
    /// 再慢就不像在"跳"。
    private static let interval: TimeInterval = 0.28
    private static let barCount = 4
    private static let barWidth: CGFloat = 2
    private static let spacing: CGFloat = 1.5
    private static let maxHeight: CGFloat = 10
    /// 静止时的高度。不取 0 —— 归零会让整排条子消失成一条线,暂停时看着像出了故障。
    private static let minHeight: CGFloat = 2.5

    static var width: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.interval, paused: !isPlaying)) { context in
            // 从时间戳算 tick 而不是自己维护一个自增计数器:TimelineView 在窗口不可见/
            // paused 期间不保证按时给点,自增计数器会随之漂移;从时间戳推则任何时候重建
            // 视图都能接上同一条序列。
            let tick = Int(context.date.timeIntervalSinceReferenceDate / Self.interval)
            HStack(alignment: .bottom, spacing: Self.spacing) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: Self.barWidth, height: height(bar: i, tick: tick))
                }
            }
            .frame(width: Self.width, height: Self.maxHeight, alignment: .bottom)
            .animation(.easeInOut(duration: Self.interval), value: tick)
            .animation(.easeInOut(duration: Self.interval), value: isPlaying)
        }
        .frame(width: Self.width, height: Self.maxHeight)
        // 装饰元素,读屏软件念"2.5、7、4、9"没有任何意义。
        .accessibilityHidden(true)
    }

    /// 确定性的伪随机高度。
    ///
    /// 不用 Double.random:那样同一个 tick 每次重算 body 都会得到不同结果,而 SwiftUI 重算
    /// body 的时机不由我们控制(父视图任何状态变化都可能带着重算一次),表现出来就是条子
    /// 在两次 tick 之间无缘无故抽一下。按 (bar, tick) 哈希出来的值则是纯函数,重算多少次
    /// 都是同一个高度。
    private func height(bar: Int, tick: Int) -> CGFloat {
        guard isPlaying else { return Self.minHeight }
        var h = UInt64(bitPattern: Int64(tick &* 31 &+ bar &* 7919))
        // splitmix64 的 finalizer——比取模/线性同余散得开,相邻 tick 不会连着出相近的值
        // (那看起来就是几根条子一起慢慢升降,而不是各跳各的)。
        h ^= h >> 30
        h = h &* 0xbf58_476d_1ce4_e5b9
        h ^= h >> 27
        h = h &* 0x94d0_49bb_1331_11eb
        h ^= h >> 31
        let unit = Double(h % 1000) / 1000.0
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * CGFloat(unit)
    }
}
