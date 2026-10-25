import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

// 顶部两个角是直角、只有底部两个角带圆角的卡片形状——SwiftUI 的 RoundedRectangle
// 只支持四角统一圆角,`UnevenRoundedRectangle` 又要 macOS 26 起才有(这个项目部署
// 目标是 14),手写一个 Shape 直接按四段直线+两段圆弧画出这个轮廓,不依赖新 API。
// 不加 private:「外观」页的灵动岛预览(NotchPreviewBar)要用同一个形状画预览卡,
// 复制一份轮廓代码只会让两边慢慢漂开。
/// 顶行以下某一块内容"此刻是不是可见的那份"(NotchLyricsView.cardBodyLayer):可见 = 正常;藏着 = 透明、不吃点击、
/// 对读屏隐藏,并通过环境值 `notchCardLayerActive` 让里面的 TimelineView 停表。四件事收在一处,免得哪一块漏一件。
///
/// 这里的透明度**自带曲线,刻意不跟卡片那条尺寸弹簧**(`NotchWindowRoot.cardAnimation`)。弹簧驱动
/// opacity 的问题是尾巴长:0.38s 的行程里有相当一段淡出的那份和淡入的那份都停在 0.4~0.6,而两份分别
/// 落在相差一个展开头部高度(纵向)、相差两个卡片宽(横向)的位置上 —— 屏幕上同时挂着同一句歌词的两个
/// 错位半透明副本,视觉系统会把它积分成「一个东西斜着滑过去」。这条曲线用 `.animation(_:body:)` 只套在透明度上,
/// 位置仍跟弹簧、跟卡片边缘同步走。别换成 `.animation(_:value:)`:那会把位置也一起从弹簧手里接走(连同延迟),
/// 卡片变宽变窄时这一块停在旧的横向位置上,一露出来就横着滑一下(05 章决策 94)。
///
/// `staggered` = 顶替我的那一份落在别处(判据见 cardBodyLayer 里那行)。为真时淡入要等淡出走完再开始,
/// 任何一刻画面上只有一份歌词,位移感消失;为假时两份逐像素重合,同步淡化本来就看不出来,再错开反而
/// 会白闪一下。别把延迟写成无条件的。
///
/// 时长按「短于卡片弹簧、总长不超过它」取:淡出 0.10 + 淡入 0.14 = 0.24s,卡片那条 response 0.38 的弹簧
/// 还在长,所以新那份淡入时卡片早已长过它的落点、不会被外层裁剪切掉半截。reduceMotion 下一律 nil
/// (直接跳变),跟 cardAnimation 同一个取舍 —— 这一段动画纯属观感,跳过不损失任何信息。
struct NotchCardLayerActive: ViewModifier {
    var active: Bool
    /// 顶替这一块的那一份是不是落在别处。默认 false:空闲面板那类"压根没有对家"的块用不上错开。
    var staggered: Bool = false
    /// 这一块半透明地压在正在变形的卡片上时合成跟不上(多行歌词:几十行、几百个字块的图层树):淡入等卡片长得差不多了
    /// 再开始,淡出缩短,让它可见的那几帧跟尺寸弹簧的大段行程错开。见 05 章决策 94。
    var waitsForResize: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let fadeOutDuration: TimeInterval = 0.10
    static let fadeInDuration: TimeInterval = 0.14
    static let resizeSettleDelay: TimeInterval = 0.22
    static let quickFadeOutDuration: TimeInterval = 0.05

    /// `.animation(_:value:)` 用变化**后**的新状态求值,所以这里按 `active` 分出入场两条
    /// (同 `NotchWindowRoot.cardAnimation` 的写法)。
    private var fade: Animation? {
        if reduceMotion { return nil }
        if active {
            let curve = Animation.easeOut(duration: Self.fadeInDuration)
            if waitsForResize { return curve.delay(Self.resizeSettleDelay) }
            return staggered ? curve.delay(Self.fadeOutDuration) : curve
        }
        return .easeIn(duration: waitsForResize ? Self.quickFadeOutDuration : Self.fadeOutDuration)
    }

    func body(content: Content) -> some View {
        // 与外层的值取「与」,不覆盖:外层是窗口看不看得见(NotchWindowRoot 给)。
        content
            .transformEnvironment(\.notchCardLayerActive) { $0 = $0 && active }
            // 曲线只套在透明度上,位置照跟卡片那条弹簧(见头注)。
            .animation(fade) { $0.opacity(active ? 1 : 0) }
                .accessibilityHidden(!active)
    }
}

/// 卡片自己那道外形裁剪,可按宿主关掉(理由见 NotchLyricsView.body 末尾与 EnvironmentValues.notchHostClipsCard)。
/// `enabled` 对某个宿主是常量;运行期切换会换分支、重建 content 子树。
struct NotchCardClip: ViewModifier {
    var enabled: Bool
    var outline: NotchCardOutline
    /// 圆角从这里取、由这一层自己观察,拖圆角滑杆时只重算这道裁剪(见 `NotchCornerLive`)。
    @ObservedObject private var live = NotchCornerLive.shared

    init(enabled: Bool, outline: NotchCardOutline) {
        self.enabled = enabled
        self.outline = outline
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.clipShape(outline.shape(live))
        } else {
            content
        }
    }
}

/// 挂在屏幕上沿的卡片外形:顶边贴死屏幕顶、底部两角圆角。
///
/// 两种用法:
///  - `.card(notchHeight:corner:)`:灵动岛卡片本身,尺寸照机器刘海走 —— 底部圆角默认随高度(`NotchOutline.bottomRadius`,
///    用户设了「圆角 / 展开圆角」时按 `NotchCornerProfile`),
///    顶边两侧各一道内凹的「肩膀」(`NotchOutline.shoulder`,按刘海高度),轮廓不越出矩形。卡片、出场裁剪、编辑台里拖宽度时
///    那圈虚线**都用这一个**,三处各写一份迟早会对不上。
///  - `NotchHangingShape(bottomCornerRadius:)`:固定圆角、没有肩膀,给设置页里缩小画的示意图用。
struct NotchHangingShape: Shape {
    /// 固定圆角(示意图用);nil = 按 `corner` 或按高度自适应。
    var bottomCornerRadius: CGFloat?
    /// 肩膀按哪个刘海高度算;nil = 没有肩膀。
    var notchHeight: CGFloat?
    /// 「圆角 / 展开圆角」的两态规则(`NotchCardOutline.corner`);nil = 默认,按高度自适应。
    var corner: NotchCornerProfile?

    static func card(notchHeight: CGFloat, corner: NotchCornerProfile? = nil) -> NotchHangingShape {
        NotchHangingShape(bottomCornerRadius: nil, notchHeight: notchHeight, corner: corner)
    }

    init(bottomCornerRadius: CGFloat?, notchHeight: CGFloat? = nil, corner: NotchCornerProfile? = nil) {
        self.bottomCornerRadius = bottomCornerRadius
        self.notchHeight = notchHeight
        self.corner = corner
    }

    func path(in rect: CGRect) -> Path {
        let s = notchHeight.map { NotchOutline.shoulder(width: rect.width, height: rect.height, notchHeight: $0) } ?? 0
        let bodyWidth = rect.width - 2 * s
        // 圆角只由这一帧的矩形决定(按高度挑 / 混合规则),尺寸动画里自然连续,不靠插值。
        let r: CGFloat
        if let fixed = bottomCornerRadius {
            r = min(fixed, bodyWidth / 2, rect.height / 2)
        } else if let corner {
            r = NotchOutline.clampedCornerRadius(corner.radius(height: rect.height), height: rect.height,
                                                 bodyWidth: bodyWidth, shoulder: s)
        } else {
            r = NotchOutline.bottomRadius(height: rect.height, bodyWidth: bodyWidth)
        }
        let left = rect.minX + s
        let right = rect.maxX - s
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        if s > 0 {
            // 右肩:圆心在主体外侧,从顶边弯进右侧边 —— 内凹。
            path.addArc(center: CGPoint(x: rect.maxX, y: rect.minY + s), radius: s,
                        startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true)
        }
        path.addLine(to: CGPoint(x: right, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: right - r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: left + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: left + r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        if s > 0 {
            path.addLine(to: CGPoint(x: left, y: rect.minY + s))
            path.addArc(center: CGPoint(x: rect.minX, y: rect.minY + s), radius: s,
                        startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        }
        path.closeSubpath()
        return path
    }
}
