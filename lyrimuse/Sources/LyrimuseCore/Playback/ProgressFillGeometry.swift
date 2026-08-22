import CoreGraphics
import Foundation

/// 进度条"已播段"的几何。
///
/// 为什么是一个 Core 里的纯函数,而不是就地写在 View 里:这条填充的画法被改过两轮,
/// 两轮都是几何判断出错,而混在 `LyricsWindowView` 里时除了盯屏幕没有别的验证办法 ——
///
/// 1. 最早是 `.frame(width: w * f)`,让**布局属性**跟着每秒一次的线性补间走,于是每一
///    显示帧都要把整个 NSHostingView 重新布局一次。实测(歌词窗口开着、正在播放)光这
///    一条就吃掉主线程的一大半:双列 61.4% 忙 vs 单列 9.4% 忙(2026-08-17)。
/// 2. 改成 `.scaleEffect(x: f)` 之后性能对了,但横向缩放把胶囊两端的圆头一起压扁成
///    x 半径 (h/2)·f 的椭圆 —— 当时的注释断言"这么矮的条上看不出来",而那只在 f 接近
///    1 时成立。用户 2026-08-22 报「进度条有时候变成方的,不是弧形」,离线渲染逐列量
///    覆盖高度坐实 f=0.02 时两端剖面一路满高、就是个纯矩形。
///
/// 现在的画法两个约束同时满足:满宽胶囊 + `.offset(x: -inset)` 向左移出、外面按固定的
/// 满宽胶囊裁一次。随进度变的只有 offset(渲染变换,不参与布局,所以第 1 条的教训还在),
/// 而圆头形状跟进度完全无关(左端来自裁剪框的左圆头、右端来自填充自己的右圆头,所以
/// 第 2 条被根除)。这个类型只负责算那两个数,并让它们能被 selftest 钉住。
public enum ProgressFillGeometry {
    /// 进度为 0 时也要留下的一小截,免得整条缩没。取正方形一小点,视觉上是个圆点。
    public static let minimumVisibleWidth: CGFloat = 4

    /// 已播段的可见宽度。
    ///
    /// 夹在 `[min(容器宽, 4), 容器宽]`:下限保证 f=0 时留一个圆点;上限那层 `min` 是给
    /// **窗口比 4pt 还窄**这种退化情形兜的 —— 不夹的话下限会超过容器宽,算出来的 inset
    /// 变成负数,offset 就把填充往**右**推、露出胶囊左半边一段没头没尾的东西。
    public static func visibleWidth(containerWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        let raw = containerWidth * min(1, max(0, fraction))
        return min(containerWidth, max(minimumVisibleWidth, raw))
    }

    /// 满宽填充要往左移出多少(传给 `.offset(x: -这个值)`)。
    ///
    /// = 容器宽 - 可见宽。恒为非负:可见宽已经夹在容器宽以内。
    public static func leadingOffset(containerWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        return containerWidth - visibleWidth(containerWidth: containerWidth, fraction: fraction)
    }
}
