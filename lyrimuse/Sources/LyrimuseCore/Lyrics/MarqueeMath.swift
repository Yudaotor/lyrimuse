import CoreGraphics
import Foundation

/// 跑马灯(MarqueeText)的纯几何判定。
///
/// 放进 Core 而不是留在 MarqueeText.swift 里:这类"差几个 pt 该不该动 / 该淡多宽"的判据
/// 历史上是 bug 温床(逐字歌词永远不滚、长行被压成一串省略号都是这一类),而混在 View 里
/// 除了盯屏幕没有别的验证办法。下沉之后 selftest 能把每条边界直接钉住。
public enum MarqueeMath {
    /// 内容比容器宽出多少(负数 = 装得下)。
    public static func overflow(contentWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        contentWidth - containerWidth
    }

    /// 值得滚的死区。差这么一点点滚起来只是抖一下,不如不动;留给测量误差。
    public static let deadZone: CGFloat = 4

    public static func isOverflowing(contentWidth: CGFloat, containerWidth: CGFloat) -> Bool {
        containerWidth > 0
            && overflow(contentWidth: contentWidth, containerWidth: containerWidth) > deadZone
    }

    /// 右端渐隐带该有多宽。
    ///
    /// 只在**内容溢出、而且此刻停在开头**(offset == 0)时给。这两个条件不是保守,是精确:
    ///
    /// - 停在开头的那 1.1 秒 hold(以及形态过渡里跑马灯被反复重排、压根还没起步的那段)是
    ///   唯一一个"文字静止、末端却被硬切"的状态。灵动岛歌词行的右边紧挨着一枚 32pt 封面、
    ///   之间只有 `NotchMetrics.artworkLyricSpacing`(10pt)间隙,硬切口正落在那里,肉眼
    ///   分不清"文字被裁掉了"和"文字被封面盖住了"。现象是「歌词被封面挡住」就是这个状态。
    /// - 滚到末端的 hold 反过来**不能**淡:那时文字末尾正好抵着边界,淡出会把真正的最后
    ///   一个字吃掉 —— 那是信息损失,不是观感取舍。
    /// - 滚动途中不淡也无所谓:文字在动,观感是"滚过去了",不像被挡住。
    ///
    /// 返回**宽度**而不是 gradient 的 stop 位置,是为了让它可动画:`LinearGradient` 的
    /// stops 不是 Animatable,改 stop 会突变;把渐隐带做成一个 `.frame(width:)` 的子视图,
    /// 宽度变化就自然跟着 `withAnimation` 平滑收缩(跑马灯一起步渐隐带随之收掉)。
    public static func trailingFadeWidth(configured: CGFloat,
                                         contentWidth: CGFloat,
                                         containerWidth: CGFloat,
                                         offset: CGFloat) -> CGFloat {
        guard configured > 0,
              offset == 0,
              isOverflowing(contentWidth: contentWidth, containerWidth: containerWidth) else { return 0 }
        // 容器窄到渐隐带能吃掉一半以上时按一半封顶 —— 收起/展开的形态过渡里容器宽度会
        // 一路插值到很小(灵动岛收起态卡片只有 notchWidth + 88),不封顶那几帧整行会被糊掉。
        return min(configured, containerWidth / 2)
    }
}

extension MarqueeMath {
    /// 匀速滚动的速度(点 / 秒)。`MarqueeText` 与 `LayerMarquee` 共用。
    public static let pointsPerSecond: Double = 24
    /// 停在开头、停在末尾的单位停顿(秒)。
    public static let holdDuration: Double = 1.1

    /// 装不下(超过死区)时的循环周期;装得下返回 nil。
    public static func cycle(contentWidth: CGFloat, containerWidth: CGFloat,
                             pointsPerSecond: Double = MarqueeMath.pointsPerSecond,
                             hold: Double = MarqueeMath.holdDuration) -> MarqueeCycle? {
        guard pointsPerSecond > 0,
              isOverflowing(contentWidth: contentWidth, containerWidth: containerWidth) else { return nil }
        let distance = overflow(contentWidth: contentWidth, containerWidth: containerWidth)
        return MarqueeCycle(distance: distance, travel: Double(distance) / pointsPerSecond, hold: hold)
    }
}

/// 循环跑马灯的一个周期:开头停 → 匀速滚到底 → 末尾停 → 瞬时回开头。
///
/// 节奏跟 `MarqueeText` 的滚动循环逐段一致:首轮开头停一个 `hold`;之后每轮开头停两个 `hold`(末尾停完瞬时归零后
/// 先停一个,下一轮开头再停一个)。周期按「开头停两个 `hold`」排,首轮从 `firstCycleTimeOffset` 起播,开头就只停一个。
/// 周期末到下一轮起点是一次瞬时归零:图层动画重复播放时从末帧回到首帧本来就不补间。
public struct MarqueeCycle: Equatable {
    /// 要滚的距离(点),> 0。
    public let distance: CGFloat
    /// 滚一遍的秒数。
    public let travel: Double
    /// 单位停顿(秒)。
    public let hold: Double

    public init(distance: CGFloat, travel: Double, hold: Double) {
        self.distance = distance
        self.travel = travel
        self.hold = hold
    }

    /// 每轮开头停多久(首轮见 `firstCycleTimeOffset`)。
    public var startHold: Double { 2 * hold }
    /// 一个周期的秒数。
    public var period: Double { startHold + travel + hold }
    /// 首轮从周期的这一刻起播。
    public var firstCycleTimeOffset: Double { hold }
    /// 四个关键帧在周期里的位置(0…1):周期起点、起滚、滚到底、周期末。
    public var keyTimes: [Double] { [0, startHold / period, (startHold + travel) / period, 1] }
    /// 同上四个时刻往左滚了多少(点)。
    public var offsets: [CGFloat] { [0, 0, distance, distance] }

    /// 两端渐隐带的关键帧。右端:开头停着时满宽,滚动中线性收到 0,末尾停着为 0(同 `MarqueeMath.trailingFadeWidth`
    /// 的规则)。左端见 `leadingFade`:停在开头时 0,滚出去多远淡多宽,到满宽封顶。
    public struct FadeKeyframes: Equatable {
        /// 0…1,跟 `keyTimes` 同一条时间线。
        public let keyTimes: [Double]
        public let leading: [CGFloat]
        public let trailing: [CGFloat]
    }

    /// 比滚动那四帧多一帧:左端在滚出 `leading` 那一刻长满、之后不变。只按四帧线性插值的话,左端要到滚到底才长满。
    public func fadeKeyframes(leading: CGFloat, trailing: CGFloat) -> FadeKeyframes {
        var times: [Double] = [0, startHold]
        var offsets: [CGFloat] = [0, 0]
        if leading > 0, leading < distance {
            times.append(startHold + travel * Double(leading / distance))
            offsets.append(leading)
        }
        times += [startHold + travel, period]
        offsets += [distance, distance]
        return FadeKeyframes(keyTimes: times.map { period > 0 ? $0 / period : 0 },
                             leading: offsets.map { leadingFade(forOffset: $0, full: leading) },
                             trailing: offsets.map { trailingFade(forOffset: $0, full: trailing) })
    }

    /// 周期里某一刻(秒,按周期取模)往左滚了多少。
    public func offset(at time: Double) -> CGFloat {
        let t = phase(time)
        if t <= startHold { return 0 }
        if t >= startHold + travel { return distance }
        return distance * CGFloat((t - startHold) / travel)
    }

    /// 滚到 `offset` 时左端渐隐带的宽度:停在开头时 0(第一个字贴着左缘、不淡),滚出去多远淡多宽,到 `full` 封顶。
    public func leadingFade(forOffset offset: CGFloat, full: CGFloat) -> CGFloat {
        min(max(offset, 0), max(full, 0))
    }

    /// 滚到 `offset` 时右端渐隐带的宽度。
    public func trailingFade(forOffset offset: CGFloat, full: CGFloat) -> CGFloat {
        guard distance > 0 else { return full }
        return full * (1 - min(max(offset / distance, 0), 1))
    }

    /// 停在 `offset` 上之后从周期的哪一刻接着播:开头(0.5pt 以内)按首轮起点,停一个 `hold` 再滚;末端(0.5pt 以内)
    /// 按末尾停顿的起点;中途按匀速反推。
    public func resumeTime(forOffset offset: CGFloat) -> Double {
        if offset < 0.5 { return firstCycleTimeOffset }
        if offset > distance - 0.5 { return startHold + travel }
        return startHold + travel * Double(offset / distance)
    }

    private func phase(_ time: Double) -> Double {
        guard period > 0 else { return 0 }
        let r = time.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }
}
