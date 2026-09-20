import SwiftUI

/// 间奏「•••」(Apple Music 歌词页同款)的呼吸圆点本体。悬浮歌词 / 歌词窗口共用同一份算法与
/// 视觉常数——呼吸曲线、点亮进度都是拿真机跟 AM 对拍量出来的（周期 7s、raised-cosine²、
/// 振幅 0.90~1.28、每颗点在间奏进度 i/3 之后点亮），两处各写一份必然慢慢跑偏，跟
/// `WordKaraokeGradient` 抽出来的理由同源。
///
/// 位置**不是**一个静态入参：呼吸和点亮进度都要跟着播放位置逐帧走，调用方传一个每帧现读的
/// 闭包（`currentPositionMs`），不要把某一刻的位置算好存成 `let` 传进来——那样只有调用方
/// 自己的 body 重新求值时才会更新，达不到跟逐字填色同一档的顺滑度。
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
