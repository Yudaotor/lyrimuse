import SwiftUI

/// 间奏「•••」(Apple Music 歌词页同款)的呼吸圆点本体。悬浮歌词 / 歌词窗口 / 灵动岛共用
/// 这一个视图;菜单栏那一面用不了 SwiftUI(状态栏项里没有活的视图可挂,见
/// `MenuBarScrollingLabel` 头注),它自己用 CALayer 排三颗点,但**曲线走同一份
/// `GapDotsCurve`**(LyrimuseCore,selftest 钉住)——视图搬不过去,常数不能也跟着各写一份。
///
/// ## 动画交给 Core Animation
///
/// 原来是 30Hz `TimelineView` 每拍现算三颗点的亮度与缩放:这个视图挂在灵动岛 / 悬浮歌词 / 歌词窗口里,
/// 间奏期间它每拍都带着整扇窗口走一遍布局 + 显示列表 + 图层提交(跟逐字填色搬图层之前同一个问题)。
/// 现在两条曲线都是**播放位置的纯函数**、间奏的起止时间又是已知的,于是一次排好交给渲染服务:
///   - 点亮进度:随时间线性推进,`opacity(dot:progress:)` 在 progress = i/3、(i+1)/3 处折一下 ——
///     每颗点 4 个关键帧就是精确的,不用采样;
///   - 呼吸:`breathe(atMs:)` 以 `breathePeriodMs` 为周期,排一个周期(30 点/秒)无限循环,按此刻的
///     位置对齐相位。三颗点同步放大缩小(AM 的样子),各绕自己的中心。
/// 重装时机:起止时间 / 在播 / 可见 / 减弱动态效果变了,以及每 3 秒对一次表(拖动进度 / 锚点重发会让
/// 位置跳一下,偏差超过 250ms 就按新位置重排)。暂停 / 看不见时摘掉动画、定格在此刻的样子。
///
/// 位置入参仍是闭包(`currentPositionMs`):装动画、对表时各现读一次,不再每帧调。
struct LyricsGapDotsView: View {
    let startMs: Int
    let endMs: Int
    let dotSize: CGFloat
    let spacing: CGFloat
    let color: Color
    let isPlaying: Bool
    let isVisible: Bool
    let reduceMotion: Bool
    /// 每帧现读一次位置,入参是这一帧 `TimelineView` 的 `context.date`——两处调用方各自决定
    /// 要不要拿它当 `extrapolatedPositionMs(now:)` 的显式基准,签名照旧,不强改调用方已有的取值方式。
    let currentPositionMs: (Date) -> Int

    var body: some View {
        TimelineView(.animation(paused: !isPlaying || !isVisible)) { context in
            let pos = currentPositionMs(context.date)
            let span = max(1, endMs - startMs)
            let progress = min(1, max(0, Double(pos - startMs) / Double(span)))
            // 呼吸:AM 的三点是整体同步放大缩小,不是错峰的打字提示器波浪;暂停时随
            // pos 冻结的外推值一起冻结,不是独立于播放进度的 wall-clock 循环。周期 7~8 秒、
            // raised-cosine 平方逼近"停留久、鼓得快"的心跳感,振幅 0.90~1.28(不对称:
            // 停留最久的那段贴地尺寸太小会看不清是个圆,详细推导见 LyricsWindowView.gapDotsRow
            // 抽出前的原注释)。
            let breathePeriodMs = 7000.0
            let breathePhase = Double(pos).truncatingRemainder(dividingBy: breathePeriodMs) / breathePeriodMs
            let breatheRaised = pow(0.5 - 0.5 * cos(2 * .pi * breathePhase), 2)
            let breathe = reduceMotion ? 1 : 0.90 + 0.38 * breatheRaised
            HStack(spacing: spacing) {
                ForEach(0 ..< 3, id: \.self) { i in
                    Circle()
                        .fill(color)
                        .frame(width: dotSize, height: dotSize)
                        // 第 i 颗在间奏进行到 i/3 之后点亮,亮度平滑爬升。
                        .opacity(0.22 + 0.78 * min(1, max(0, progress * 3 - Double(i))))
                        .scaleEffect(breathe)
                }
            }
        }
    }
}
