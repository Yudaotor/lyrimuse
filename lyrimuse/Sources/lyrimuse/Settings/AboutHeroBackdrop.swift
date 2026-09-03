import SwiftUI

/// 关于页页头两侧的装饰层(2026-09-03,用户:「这两边的空白区域还可以加花吗」)。
///
/// 页头是居中的一列(图标 / 名字 / 版本 / 按钮),600pt 宽的卡片列里两侧各空出约 200pt 的白。这里铺
/// 两样东西:① 两团取自 App 图标配色(粉 / 桃黄)的柔光,左右各一,给页头一个"舞台";② 八个漂浮的
/// 音符 / 歌词符号(SF Symbols),很淡,按各自的周期上下慢慢浮动 —— 呼应 tagline 里的「Muse」,不
/// 抢图标和文字的注意力。
///
/// 三条约束:
/// - **不参与布局、不吃点击**:挂在页头 VStack 的 `.background` 上、`allowsHitTesting(false)`,页头
///   文字和按钮的位置一个像素都不变;对 VoiceOver 也不存在。
/// - **动效便宜且可关**:一个 `TimelineView(.animation)` 驱动全部符号(不是八个 repeatForever 动画各起
///   一条),帧率钉 30fps,偏移量是 sin(t) 算出来的纯函数;系统「减弱动态效果」开着时 timeline 暂停、
///   符号静止在各自的基准位。这一页不显示时视图不存在,不会在后台白跑。
/// - **颜色跟图标走**:粉 / 桃 / 黄 / 淡紫四色都取自 AppIcon,深浅外观都只靠透明度,不另写两套。
struct AboutHeroBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Glyph {
        let symbol: String
        /// 位置按页头宽高的比例给:页头宽度随窗口变(卡片列最多 600pt),用比例才能两侧都贴边。
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let tint: Color
        let opacity: Double
        /// 上下浮动一个来回的秒数与起始相位。各不相同,免得八个符号同步起落像在做操。
        let period: Double
        let phase: Double
        let rotation: Double
        let amplitude: CGFloat
    }

    // 取自 AppIcon 的四个色相。
    private static let pink = Color(red: 0.98, green: 0.60, blue: 0.74)
    private static let peach = Color(red: 0.99, green: 0.72, blue: 0.52)
    private static let yellow = Color(red: 0.97, green: 0.82, blue: 0.40)
    private static let lavender = Color(red: 0.72, green: 0.66, blue: 0.94)

    private static let glyphs: [Glyph] = [
        // 左侧:从上到下一大两小,再加一个"歌词行"符号呼应图标右半的三条线。
        Glyph(symbol: "music.note", x: 0.12, y: 0.20, size: 24, tint: pink, opacity: 0.42,
              period: 7.0, phase: 0.0, rotation: -14, amplitude: 5),
        Glyph(symbol: "music.quarternote.3", x: 0.25, y: 0.44, size: 18, tint: peach, opacity: 0.38,
              period: 8.5, phase: 1.3, rotation: 8, amplitude: 4),
        Glyph(symbol: "music.note", x: 0.06, y: 0.58, size: 14, tint: lavender, opacity: 0.40,
              period: 6.4, phase: 2.6, rotation: 12, amplitude: 3),
        Glyph(symbol: "text.alignleft", x: 0.19, y: 0.08, size: 15, tint: pink, opacity: 0.28,
              period: 9.2, phase: 4.0, rotation: -6, amplitude: 3),
        // 右侧:不跟左侧镜像,位置和大小都错开,看起来是"散落"而不是"对称排版"。
        Glyph(symbol: "music.note.list", x: 0.87, y: 0.16, size: 21, tint: peach, opacity: 0.40,
              period: 7.6, phase: 0.8, rotation: 10, amplitude: 4),
        Glyph(symbol: "music.note", x: 0.94, y: 0.42, size: 16, tint: pink, opacity: 0.40,
              period: 6.0, phase: 2.0, rotation: -10, amplitude: 4),
        Glyph(symbol: "music.quarternote.3", x: 0.77, y: 0.31, size: 14, tint: yellow, opacity: 0.45,
              period: 8.0, phase: 3.4, rotation: -4, amplitude: 3),
        Glyph(symbol: "quote.opening", x: 0.90, y: 0.58, size: 14, tint: lavender, opacity: 0.36,
              period: 9.6, phase: 5.1, rotation: 0, amplitude: 3),
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                // 两团柔光压在两侧偏上的位置,半径 150 + 模糊 24,离中间的图标(x = 0.5w)还有一段空,
                // 不会糊到图标本身的边缘描边上。
                glow(Self.pink, opacity: 0.22)
                    .position(x: width * 0.16, y: height * 0.34)
                // 右边用桃色不用黄色:离线渲染深色外观时黄色柔光压在深灰底上发闷、偏土,桃色两种外观都干净。
                glow(Self.peach, opacity: 0.22)
                    .position(x: width * 0.84, y: height * 0.30)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ForEach(Array(Self.glyphs.enumerated()), id: \.offset) { _, glyph in
                        let drift = reduceMotion ? 0 : glyph.amplitude * CGFloat(sin(t * 2 * .pi / glyph.period + glyph.phase))
                        Image(systemName: glyph.symbol)
                            .font(.system(size: glyph.size, weight: .medium))
                            .foregroundStyle(glyph.tint.opacity(glyph.opacity))
                            .rotationEffect(.degrees(glyph.rotation))
                            .position(x: width * glyph.x, y: height * glyph.y + drift)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // 符号要的是图形,钉住拉丁变体(text.alignleft 这类"文字造型"符号带本地化变体,理由见
        // SettingsRow 里同一句注释)。
        .environment(\.locale, Locale(identifier: "en"))
    }

    private func glow(_ color: Color, opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: 150))
            .frame(width: 300, height: 300)
            .blur(radius: 24)
    }
}
