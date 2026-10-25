import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

/// 灵动岛卡片里所有纯图标键的那一层壳:悬停时字形底下浮出一块 `tint` 14% 的圆角底、字形抬到全亮;按下底色加深到 24%、整颗缩到
/// 0.9,松手弹回。头部快捷操作四颗、空闲面板三颗、展开卡三键、耳朵三键全走这一份:同一张卡上的按钮反馈必须一致,不能一排会亮
/// 一排不会。
///
/// * 独立 View 而不是 modifier 函数,理由同菜单栏面板的 `ChipButton`:悬停状态要**每颗键自己**一份
///   `@State`;按下态从 `ButtonStyle.Configuration.isPressed` 读,不自己追手势。
/// * 反馈色用 `tint`(卡片的 `accentOrWhite`)的低透明度,不写死白/灰:强调色模式下底色跟字形同色系,
///   白字模式下就是白色 14%。跟菜单栏面板 `ChipStyle` 拿 `.primary` 低透明度是同一个思路,但这里不能用
///   `.primary` —— 卡片永远是深底,`.primary` 在浅色系统外观下是黑的。
/// * 悬停只改字形透明度和底色、**不改尺寸**:命中框恒 `hitSize`,底也画在这个框里,邻居一个像素不动
///   (同卡进度条那条「悬停变粗不许推动邻居」)。
/// * `reduceMotion` 下不补间,但保留变色和缩放本身 —— 它们是"点到了"的功能反馈,不是装饰(同歌词窗口
///   `TransportButtonStyle`)。
/// * SwiftUI 的 `.onHover` 在这扇从不激活 App 的窗口里收得到(同卡进度条 `hoveringScrubber` 早就靠它)。
///   设置页预览卡整块 `allowsHitTesting(false)`,那里不会亮 —— 预览上这块本来就是点开浮层的热区。
struct NotchIconButton: View {
    let systemName: String
    let glyphSize: CGFloat
    let hitSize: CGFloat
    let tint: Color
    /// 平时字形的不透明度(快捷操作 0.75 / 关着的「显示歌词」0.4 / 播放三键 1);悬停抬 0.25、封顶 1 ——
    /// 关着的那颗悬停到 0.65,仍读得出"这是关的",但看得出它在响应。
    let glyphOpacity: Double
    /// 静止时底色的透明度,见 `NotchIconButtonStyle.restingLevel`。随机 / 循环点亮时给一档。
    var restingLevel: Double = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering ? min(1, glyphOpacity + 0.25) : glyphOpacity))
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        // 圆角按命中框的比例取(22 → 6,18 → 5,15 → 4),跟歌词窗口 22pt 高的 `OffsetNudgeButton` 用 6 一致。
        .buttonStyle(NotchIconButtonStyle(tint: tint, cornerRadius: (hitSize * 0.27).rounded(),
                                          hovering: hovering, restingLevel: restingLevel))
        .onHover { hovering = $0 }
    }
}

struct NotchIconButtonStyle: ButtonStyle {
    let tint: Color
    let cornerRadius: CGFloat
    let hovering: Bool
    /// 静止时底色的透明度。纯图标键是 0(静止时没有底,悬停才浮出来);带文字的胶囊键(`NotchPillButton`)
    /// 给 0.12 —— 没有底的一句文字看起来是标签,不是键。悬停 / 按下在它之上再抬一档,三档单调递增。
    var restingLevel: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let level: Double = pressed ? max(0.24, restingLevel + 0.12)
            : (hovering ? max(0.14, restingLevel + 0.08) : restingLevel)
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(level))
            )
            // 悬停给的是"这里可按",按下要给"按到了":缩一点、底色再深一档。曲线同菜单栏面板 `ChipStyle`。
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.65), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

/// 「自己持有 hover 状态」的一层壳。
///
/// 为什么需要它:`artworkThumbnail` / `lyricsOffsetButton` 都是**函数**,同一个函数有多个调用点
/// (封面那份三处:耳朵 32pt、稳态歌词行、展开头部)。把 `@State private var hovering` 放进宿主
/// 视图,三处会共用同一个布尔值 —— 悬停耳朵那张会把展开头部那张一起点亮。壳把状态关进每个实例
/// 自己的身体里,调用点不用改成三个独立 struct。
struct HoverReveal<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

/// 封面缩略图的悬停 / 按下反馈。
///
/// **不能复用 `NotchIconButtonStyle`**:那份靠"图标背后浮出一层底色"给反馈,而这里的标签是
/// 一张**不透明的图**,背后画什么都看不见。所以在图**上面**叠一层白纱,同时把那圈描边抬亮
/// 一档 —— 描边因此从标签里搬进这个 style(它要随状态变,留在标签里只能是定值)。
///
/// **悬停不放大,只有按下才缩到 0.96**。放大会顶出容器:`artworkThumbnail` 最小的调用点是
/// 耳朵那档 32pt,外层是按 32pt 排的;缩小没有这个风险。这条跟 `lyricsOffsetButton` 上那条
/// "别撑高时间行"是同一个纪律 —— 这张卡的几何余量是算过账的,反馈只准在原地做。
struct NotchArtworkButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return configuration.label
            .overlay(shape.fill(.white.opacity(pressed ? 0.16 : (hovering ? 0.08 : 0))))
            .overlay(shape.strokeBorder(.white.opacity(pressed ? 0.5 : (hovering ? 0.38 : 0.18)),
                                        lineWidth: 0.5))
            .scaleEffect(pressed ? 0.96 : 1)
            // 曲线跟 NotchIconButtonStyle 一字不差 —— 同一张卡上两种键的手感不该有差别。
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.65), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

/// 带文字的胶囊键(首个用途是广告态那颗「跳过广告」)。悬停 / 按下反馈跟 `NotchIconButton`
/// 同一份 `NotchIconButtonStyle`,只多一层 12% 的静止底(理由见 `restingLevel`);高度跟快捷操作 / 三键
/// 同档 22pt,文字 11pt semibold —— 它跟那些图标键排在同一张卡上,不该比它们重。
struct NotchPillButton: View {
    let systemName: String
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 9.5, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint.opacity(hovering ? 1 : 0.85))
            .padding(.horizontal, 9)
            .frame(height: NotchExpandedMetrics.trackInfoActionsHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(NotchIconButtonStyle(tint: tint, cornerRadius: NotchExpandedMetrics.trackInfoActionsHeight / 2,
                                          hovering: hovering, restingLevel: 0.12))
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
