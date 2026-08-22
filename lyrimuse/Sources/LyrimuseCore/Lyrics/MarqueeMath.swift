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
    ///   分不清"文字被裁掉了"和"文字被封面盖住了"。用户报的「歌词被封面挡住」就是这个状态。
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
