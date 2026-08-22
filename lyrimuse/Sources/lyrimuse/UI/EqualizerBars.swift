import SwiftUI

// 灵动岛左耳歌名前面那几根"跳动的均衡条"——纯装饰性的播放指示器,不是真的频谱。
//
// ⚠️ 名字叫均衡条,但它跟音频数据没有任何关系,也不该有:拿到真实频谱需要 CoreAudio 抓
// 系统输出(要么装虚拟声卡,要么申请录屏/录音权限),对一个"显示歌词"的 App 来说代价完全
// 不成比例。被参考的那个 fork 的 README 宣称有频谱,读代码发现它的 visualizer.metal 根本
// 没进编译清单,实际画的也是随机动画 —— 这里不重复那种宣称,注释和 UI 文案都只说"播放
// 指示",不说"频谱"。
//
// 2026-08-22:条高的**振幅**改由逐字歌词时间轴调制(`amplitude` 闭包),所以它现在确实
// 跟着歌在动 —— 但驱动它的是"这一刻有没有字正在唱",不是音频。这是 lyrimuse 相对那类
// 抓音频的实现的便宜之处:逐字时间轴本来就在手上(LyricsSyncEngine 解析出的 words 带
// 真实起止毫秒),等于白拿一个跟人声同步的包络,零权限、零新数据源、零常驻音频线程。
// 形状(哪根跳多高)仍是伪随机 —— 那部分本来就不该假装有物理意义。
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
    /// 这一刻的"人声强度",0...1。在 TimelineView 的每个 tick 上求值一次(不是每帧 ——
    /// tick 频率仍是 `interval`,见下面的性能注释,**不要**为了更跟手去提高它)。
    ///
    /// 闭包而不是值:值只会在父 body 重算时更新,而父 body 的重算时机跟这个视图自己的
    /// tick 完全对不上,表现就是"唱了一整行条子的幅度纹丝不动"。闭包让它在 tick 那一刻
    /// 直读当下的播放状态,跟逐字填色那几处"闭包直读协调器、不经代理订阅"是同一个模式。
    ///
    /// 默认 `{ _ in 1 }` = 满幅,等价于加这个参数之前的行为。
    var amplitude: (Date) -> Double = { _ in 1 }

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
            // 每个 tick 求一次,四根条子共用 —— 它描述的是"此刻",跟是哪根条子无关。
            let amp = amplitude(context.date)
            HStack(alignment: .bottom, spacing: Self.spacing) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: Self.barWidth, height: height(bar: i, tick: tick, amplitude: amp))
                }
            }
            .frame(width: Self.width, height: Self.maxHeight, alignment: .bottom)
            // 补间时长只取间隔的一半(2026-08-19 性能审计):原来 duration == interval,
            // 上一次高度补间刚结束下一 tick 就到,首尾相接零空档 —— 播放期间这 4 根
            // 胶囊的尺寸动画 100% 时间在跑,把整个灵动岛窗口钉死在持续动画/持续合成
            // 状态(body 重算确实被 minimumInterval 压到了 3.6Hz,但合成频率仍是满帧)。
            // 减半后每个周期有一半时间完全静止,合成循环能间歇 idle;观感仍是跳动的条,
            // 只是每跳快一点、停一下 —— 反而更像"拍点"。
            .animation(.easeInOut(duration: Self.interval * 0.5), value: tick)
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
    private func height(bar: Int, tick: Int, amplitude: Double) -> CGFloat {
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
        // 振幅只压缩"能跳多高",不动地板 —— minHeight 那条线永远在,间奏/纯音乐时条子
        // 收敛成小幅晃动而不是趴平。趴平的观感是"坏了",而这个元件的职责是"告诉你还在放"。
        let scaled = unit * max(0, min(1, amplitude))
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * CGFloat(scaled)
    }
}
