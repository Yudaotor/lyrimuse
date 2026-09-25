import Foundation

/// 灵动岛音浪(`EqualizerBars`)的柱高曲线:时间 + 条序 + 人声振幅 → 高度比例 0…1。
///
/// ## 形态:每根条子各走各的
///
/// 五根条子**没有**共同的节奏源 —— 每根是一条自己的连续曲线,频率由 `rate(bar:barCount:)`
/// 按条序拉开(最慢的那根比最快的慢一倍半以上,逐帧位移实测 0.020 对 0.053),所以同一
/// 时刻有的在往上爬、有的正慢慢沉下去,读出来是"一条条单独在动"。
///
/// **别加全组共享的驱动**(一条大家共用的包络 / 脉冲串,再让每根在它上下浮动):那样
/// 五根条子会同时顶起、同时压低,整组一起一顿一顿地抽,比各走各的更难看。实测那种写法
/// 逐帧位移会到 0.082(这里是 0.037)、柱间落差压到 0.31(这里 0.41)——数字上"整齐"了,
/// 观感是整排在痉挛。
///
/// ## 运动:平滑,不打击
///
/// 两条频率不成简单整数比的正弦叠加,上升沿和下降沿一样缓。
///
/// **别换成"快速冲顶 + 指数泄放"的非对称脉冲**:那是音频表头的手感,放在这个尺寸的
/// 装饰件上就是一直在抽搐。参照实现给合成兜底用的也是这种对称正弦(频率 5.2 / 9.7,
/// 跟这里同一量级),只有它真的接到音频时才走非对称包络。
///
/// ## 地板:条子永远是一根,不是一个点
///
/// `floorLevel` 把整条曲线抬离 0。**别把地板放回 0**:那时低谷的条子会缩成一枚比条宽
/// 还矮的小胶囊,而邻居正顶到上限,逐帧抓窗看是"一根顶天、旁边几个点",像出了故障。
/// 实测无地板时有 16.6% 的时间条高在满量程的 12% 以下。
///
/// ## 仍然是时间的纯函数
///
/// 不维护累加器:`TimelineView` 在窗口不可见 / paused 期间不保证按时给点,累加器会漂,
/// 而时间戳任何时候重建视图都接得上同一条曲线。`Double.random` 同理不能用 —— 同一时刻
/// 重算 body 会得到不同结果,表现为无缘无故抽动。
///
/// 放在 LyrimuseCore 是为了让 selftest 钉住那几条不变量(地板、上界、各根速度拉得开、
/// 逐帧位移落在"活着但不抽"的区间里)。
public enum EqualizerBarCurve {
    // MARK: - 常数

    /// 曲线的地板。条子最矮时仍有满量程的三成,看着还是一根短棍而不是一个点。见头注。
    public static let floorLevel: Double = 0.30

    /// 最慢 / 最快那根条子的速度倍率。两端拉开一倍半以上,才看得出"每根有自己的节奏";
    /// 收成 1.0…1.0 的话五根只差相位,会一起呈现肉眼可辨的整齐推进。
    public static let rateSlowest: Double = 0.60
    public static let rateFastest: Double = 1.60

    /// 叠加的两条正弦的基频(rad/s 的系数)与权重。两个频率不成简单整数比,叠加的周期
    /// 长到肉眼认不出重复;单条正弦会让条子呈现规律的来回摆。
    public static let frequencyA: Double = 5.2
    public static let frequencyB: Double = 9.7
    public static let weightA: Double = 0.6
    public static let weightB: Double = 0.4

    /// 每根条子的相位偏移,按**黄金角**(≈2.39996 rad)递推。等分相位会让条子呈现肉眼
    /// 可辨的"波浪依次推过去";黄金角是最不成简单分数比的分割,**任意根数**都不会出现
    /// 相位重合或整齐推进。用公式而不是手写数组:调根数不用连带重挑相位。
    public static func phase(bar: Int) -> Double { Double(bar) * 2.399963 }

    // MARK: - 曲线

    /// 某根条子的速度倍率,在 `rateSlowest`…`rateFastest` 之间按条序线性铺开。
    public static func rate(bar: Int, barCount: Int) -> Double {
        guard barCount > 1 else { return 1 }
        let t = Double(min(max(0, bar), barCount - 1)) / Double(barCount - 1)
        return rateSlowest + (rateFastest - rateSlowest) * t
    }

    /// 某根条子此刻的形状值 0…1(还没乘人声振幅,也还没抬地板)。
    public static func shape(bar: Int, barCount: Int, time: Double) -> Double {
        guard time.isFinite else { return 0.5 }
        let r = rate(bar: bar, barCount: barCount)
        let p = phase(bar: bar)
        let a = sin(time * frequencyA * r + p) * 0.5 + 0.5
        let b = sin(time * frequencyB * r + p * 1.7) * 0.5 + 0.5
        return a * weightA + b * weightB
    }

    /// 最终高度比例(0…1)。`amplitude` 是人声包络(`VocalEnvelope`),只压缩"能跳多高"。
    ///
    /// **乘完再夹**,别先把 amplitude 夹到 1:起音那一拍 `VocalEnvelope` 给到 1.25,
    /// 先夹会把这个瞬态整个吃掉 —— 乘完再夹的效果是起音那一刻更多条子顶到上限然后回落,
    /// 而高度永远不超过上限。
    public static func level(bar: Int, barCount: Int, time: Double, amplitude: Double) -> Double {
        let unit = floorLevel + (1 - floorLevel) * shape(bar: bar, barCount: barCount, time: time)
        return min(1, max(0, unit * max(0, amplitude)))
    }

    // MARK: - 关键帧

    /// 从 `start`(`timeIntervalSinceReferenceDate` 口径的秒)起每隔 `step` 秒取一个点、共 `count` 个,
    /// 返回每根条子的高度比例序列(`[bar][i]`)。`amplitude(t)` 在每个时刻求一次、所有条子共用 ——
    /// 跟原来每个 tick 求一次的口径一致。
    ///
    /// 给 `EqualizerBars` 预先排好一段、整段交给 Core Animation 播:曲线和人声包络都是时间的纯函数,
    /// 未来几秒的值现在就算得出来,不必让主线程每秒醒 30 次现算。
    public static func keyframes(barCount: Int, start: Double, step: Double, count: Int,
                                 amplitude: (Double) -> Double) -> [[Double]] {
        guard barCount > 0, count > 0, step > 0 else { return [] }
        var out = Array(repeating: [Double](), count: barCount)
        for b in 0..<barCount { out[b].reserveCapacity(count) }
        for i in 0..<count {
            let t = start + Double(i) * step
            let amp = amplitude(t)
            for b in 0..<barCount {
                out[b].append(level(bar: b, barCount: barCount, time: t, amplitude: amp))
            }
        }
        return out
    }
}
