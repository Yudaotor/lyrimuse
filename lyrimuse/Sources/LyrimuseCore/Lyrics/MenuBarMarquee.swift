import CoreGraphics
import Foundation

// 菜单栏歌词的跑马灯取窗算法(2026-08-05 加,点子来自 FlowX/Kadxy/FlowX——它的菜单栏
// 歌词超宽时会横向滚动,而不是像我们原来那样直接截断成"前 N 个字…")。
//
// ⚠️ 为什么是"算出该显示哪一段文字"而不是"做一个滚动动画":MenuBarExtra 默认(.menu)
// 样式的 label 里挂不住 SwiftUI 的动画/生命周期修饰符——本会话早先实测坐实过 `.task`
// 挂在 MenuBarLabel 上从来不触发(详见当时排查系统翻译兜底那一轮的结论)。但 label 本身
// 确实会跟着它读的 @Published 值变化重新渲染(菜单栏歌词能跟着换句就是靠这个)。所以
// 这里反过来做:把"现在该露出哪一段"当成纯数据算出来、由模型层按节奏发布,label 只管
// 渲染一个普通字符串,完全不依赖任何视图侧的动画能力。
//
// 纯函数、无状态,selftest 直接覆盖。
public enum MenuBarMarquee {
    // 2026-08-15 删掉了原来那个按**字符**取窗的 window(text:maxChars:step:holdSteps:)。
    // 它每 0.25 秒整体平移一个字(等于 4fps),而且窗口按字符数固定、字符宽度却差着一倍
    // (中文 128pt vs 英文 65pt 同为 10 个字),菜单栏项因此跟着内容忽宽忽窄。取代它的是
    // 按像素连续平移:偏移由下面的 scrollOffset 算,取窗/截断由 MenuBarMarqueeRenderer
    // 按真实文字宽度做。两份实现不并存 —— 留着那个没人调的旧版只会让人以为还有第二条路。

    // ---- 像素级滚动 ----
    //
    // 2026-08-15 加。上面那个按字符取窗的版本用户实测"显得很卡顿",原因不是性能,是两件
    // 事叠在一起:
    //   1. 每 0.25 秒整体平移**一个字**,这是肉眼可辨的大跨度跳变,本质上就是 4fps 的动画;
    //   2. 窗口固定 maxChars 个**字符**,而字符的显示宽度并不相等(英文 'i' 和 'm' 差一倍、
    //      中文又比拉丁宽得多)。于是每跳一次,这段文字的像素宽度也跟着变 —— 菜单栏项宽度
    //      随之伸缩,把右边其它 App 的图标一起顶得左右晃。
    //
    // 所以改成:窗口宽度按**像素**钉死(菜单栏不再抖),文字在这个窗口里按像素连续平移
    // (真正的平滑)。渲染那一半必须落在 AppKit 那边(要测字宽、要画图),但"此刻该偏移多少"
    // 仍然是纯函数,留在这里给 selftest 覆盖。
    //
    // 一个完整周期跟按字符那版一致:先停 holdSeconds(开头最该看清)→ 匀速滚过 maxOffset →
    // 末尾再停 holdSeconds → 回到开头循环。
    //
    // 用「已过去的秒数」而不是「第几帧」当输入,是有意的:计时器回调会被主线程上别的活儿
    // (逐字高亮那套 60fps 的重绘)推迟,累加式计帧会把这些延迟原样变成忽快忽慢的滚动 ——
    // 那正是"卡顿"的另一半来源。按墙钟时间算,延迟只表现为丢帧,节奏始终是匀的。
    public static func scrollOffset(
        elapsed: Double, maxOffset: CGFloat, pointsPerSecond: CGFloat, holdSeconds: Double
    ) -> CGFloat {
        // 装得下(maxOffset<=0)就不滚。速度非正是调用方算错了,同样退化成不滚,不要除零。
        guard maxOffset > 0, pointsPerSecond > 0 else { return 0 }
        let hold = max(0, holdSeconds)
        let travel = Double(maxOffset / pointsPerSecond)
        let cycle = hold * 2 + travel
        // cycle 恒 > 0(travel > 0),不用防除零。
        var t = elapsed.truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle } // elapsed 传负数(时钟回拨)也不会跳到奇怪的位置
        if t < hold { return 0 }
        if t < hold + travel {
            // 夹一次上界:浮点乘法在末尾那一帧可能算出比 maxOffset 大一丁点,越界会露出
            // 右边的空白。
            return min(maxOffset, CGFloat(t - hold) * pointsPerSecond)
        }
        return maxOffset
    }
}
