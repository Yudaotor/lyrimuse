import LyrimuseCore
import SwiftUI

/// 出场动画每一帧的三个量:可见宽度比例、可见高度比例、内容透明度。`settled` = 终态(全露、内容全显),
/// 也是 keyframeAnimator 的 initialValue —— 视图第一次出现时不播、trigger 变了才从起始态长起(见 NotchWindowRoot)。
struct NotchRevealState {
    var widthFraction: CGFloat
    var heightFraction: CGFloat
    var contentOpacity: Double

    static let settled = NotchRevealState(widthFraction: 1, heightFraction: 1, contentOpacity: 1)
}

/// 出场动画用的裁剪形状:卡片顶部居中的一块「挂着的胶囊」—— 宽 = 卡宽 × widthFraction、高 = 卡高 ×
/// heightFraction、顶边贴刘海,外形就是 `NotchHangingShape.card`(圆角按可见矩形的尺寸算,肩膀按刘海高度、
/// 可见矩形太小时收小)。
/// 终态 (1, 1) 与 `NotchLyricsView` 自己那道 `NotchHangingShape.card` 完全重合 —— 所以
/// 真窗口里**只留这一道**:`NotchWindowRoot` 通过环境值 `notchHostClipsCard` 让卡片自己那道
/// 不再裁(两层同形状的 mask 在尺寸动画里每帧各重设一次路径,是白付的),平时这道裁剪就是卡片的外形。
///
/// 用 clipShape 而不是 mask:mask 要把整卡渲染成一张离屏纹理再合成,而这扇窗口播放期间逐字高亮每帧都在
/// 重绘,常驻多一道离屏就是每帧的税;clipShape 是路径裁剪,常驻成本可忽略。也**不能**在动画结束后换成
/// "不裁剪"的另一个分支 —— 分支切换会让 SwiftUI 重建 NotchLyricsView、丢掉它的全部 @State(跑马灯位置等)。
struct NotchRevealShape: Shape {
    var widthFraction: CGFloat
    var heightFraction: CGFloat
    var notchHeight: CGFloat
    /// 同 `NotchHangingShape.card` 的 `corner`(`NotchCardOutline.corner`)。
    var corner: NotchCornerProfile?

    func path(in rect: CGRect) -> Path {
        let width = rect.width * min(1, max(0, widthFraction))
        let height = rect.height * min(1, max(0, heightFraction))
        let visible = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
        return NotchHangingShape.card(notchHeight: notchHeight, corner: corner).path(in: visible)
    }
}

/// 真窗口挂 `NotchRevealShape` 的那一层;设置页编辑台的预览卡片挂同一个(两个比例取终态),外形、描边、投影跟真窗口一致。
/// 圆角从 `NotchCornerLive` 取、由这一层自己观察:拖圆角滑杆时只重算这道裁剪,
/// `NotchWindowRoot` 和整张卡片都不跟着重算。
///
/// 1x 屏上卡片外面再垫一圈柔边(`NotchLowResEdgeShadow`):一个点只有一个像素,圆角的抗锯齿过渡带只有一像素宽,深色卡片压在
/// 浅色菜单栏上看得出台阶。2x 屏上不画。见 05 章决策 114。
///
/// 展开态再加发丝描边和浅投影(`NotchCardEdge`),只在 `expanded` 时显出来,收起态、稳态不画。描边和投影跟裁剪是同一个形状值,
/// 出场、展开收回、退场缩放都一起走。投影落在卡片外,窗口四周要留出 `NotchCardEdge.windowMargin`(控制器 `recomputeGeometry`)。
struct NotchRevealClip: ViewModifier {
    var widthFraction: CGFloat
    var heightFraction: CGFloat
    var outline: NotchCardOutline
    var expanded: Bool
    @ObservedObject private var live = NotchCornerLive.shared
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(widthFraction: CGFloat, heightFraction: CGFloat, outline: NotchCardOutline, expanded: Bool) {
        self.widthFraction = widthFraction
        self.heightFraction = heightFraction
        self.outline = outline
        self.expanded = expanded
    }

    func body(content: Content) -> some View {
        let shape = NotchRevealShape(widthFraction: widthFraction, heightFraction: heightFraction,
                                     notchHeight: outline.notchHeight, corner: outline.corner(live))
        let lowRes = displayScale < 1.5
        let fade = NotchCardEdge.fade(showing: expanded, reduceMotion: reduceMotion)
        content.clipShape(shape)
            .background {
                if lowRes {
                    NotchLowResEdgeShadow(shape: shape)
                }
                // 曲线只套在透明度上,形状照跟卡片那条尺寸弹簧。
                NotchCardEdgeShadow(shape: shape, lowRes: lowRes)
                    .animation(fade) { $0.opacity(expanded ? 1 : 0) }
            }
            .overlay {
                NotchCardKeyline(shape: shape)
                    .animation(fade) { $0.opacity(expanded ? 1 : 0) }
            }
    }
}

/// 展开态卡片边缘的参数。见 05 章决策 150。
enum NotchCardEdge {
    /// 窗口在卡片左右、下方多留的透明余量,装得下投影的外沿;贴屏幕顶的那一边不留。
    static let windowMargin: CGFloat = 24
    /// 内侧发丝高光(白)与外侧勾边(黑)的透明度,各占卡片外沿内外 0.5pt。
    static let keylineOpacity: Double = 0.16
    static let outlineOpacity: Double = 0.35
    /// 1x 屏上外侧勾边要叠在 `NotchLowResEdgeShadow` 上,降到这么多,两层合起来不成一道硬黑边。
    static let lowResOutlineOpacity: Double = 0.12
    /// 两层投影:贴边一层 + 环境一层,略向下。
    static let shadows: [(radius: CGFloat, opacity: Double, y: CGFloat)] = [(1, 0.25, 1), (7, 0.28, 3)]
    /// 从卡片顶边(屏幕上沿)往下量:描边在 `strokeFade` 内、投影在 `shadowFade` 内从无渐到全显,不沿屏幕上沿、刘海和菜单栏走。
    static let strokeFade: ClosedRange<CGFloat> = 3...28
    static let shadowFade: ClosedRange<CGFloat> = 14...42

    /// 淡入跟展开同长,淡出短一些:收回时卡片先缩,投影不该拖在后面。
    static func fade(showing: Bool, reduceMotion: Bool) -> Animation? {
        if reduceMotion { return nil }
        return showing ? .easeOut(duration: 0.2) : .easeIn(duration: 0.12)
    }
}

/// 卡片外面那一层:两层投影加外侧勾边,把卡片本身那块挖掉,只留外面 —— 磨砂玻璃是半透明的,垫在底下会把卡片里面压暗。
struct NotchCardEdgeShadow: View {
    let shape: NotchRevealShape
    let lowRes: Bool

    var body: some View {
        ZStack {
            ZStack {
                ForEach(NotchCardEdge.shadows.indices, id: \.self) { i in
                    let layer = NotchCardEdge.shadows[i]
                    shape.fill(Color.black.opacity(layer.opacity))
                        .blur(radius: layer.radius)
                        .offset(y: layer.y)
                }
            }
            .mask(alignment: .top) { NotchTopFadeMask(fade: NotchCardEdge.shadowFade, outset: NotchCardEdge.windowMargin) }
            shape.stroke(Color.black.opacity(lowRes ? NotchCardEdge.lowResOutlineOpacity : NotchCardEdge.outlineOpacity),
                         lineWidth: 1)
                .mask(alignment: .top) { NotchTopFadeMask(fade: NotchCardEdge.strokeFade, outset: NotchCardEdge.windowMargin) }
        }
        .mask(NotchOutsideShape(inner: shape, outset: NotchCardEdge.windowMargin * 2).fill(style: FillStyle(eoFill: true)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 卡片里面贴着外沿的那圈发丝高光:1pt 描边裁到卡片里,剩里侧 0.5pt。
struct NotchCardKeyline: View {
    let shape: NotchRevealShape

    var body: some View {
        shape.stroke(Color.white.opacity(NotchCardEdge.keylineOpacity), lineWidth: 1)
            .clipShape(shape)
            .mask(alignment: .top) { NotchTopFadeMask(fade: NotchCardEdge.strokeFade, outset: 0) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 从顶边往下按点数量的渐显遮罩:`fade` 下界以上全透明、上界以下全显,中间线性过渡;左右和下方多铺 `outset`,盖住画到卡片外的部分。
/// 卡片比渐变段还矮时(收起态)贴顶排、多出来的往下溢,别改成居中。
struct NotchTopFadeMask: View {
    let fade: ClosedRange<CGFloat>
    let outset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: fade.lowerBound)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fade.upperBound - fade.lowerBound)
            Color.black
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, -outset)
        .padding(.bottom, -outset)
    }
}

/// 卡片外形外面那圈柔边:同形状填黑、模糊,再把卡片本身那块挖掉。只留外面那一圈,半透明的风格(磨砂玻璃)里面不被压暗。
/// 形状跟裁剪是同一个值,出场、展开收回、退场缩放都一起走。
struct NotchLowResEdgeShadow: View {
    let shape: NotchRevealShape

    static let radius: CGFloat = 0.6
    static let opacity: Double = 0.55

    var body: some View {
        shape.fill(Color.black.opacity(Self.opacity))
            .blur(radius: Self.radius)
            .mask(NotchOutsideShape(inner: shape).fill(style: FillStyle(eoFill: true)))
            .allowsHitTesting(false)
    }
}

/// `inner` 外面的那一圈(外扩 `outset` 的矩形减去 `inner`,奇偶填充)。`outset` 要盖得住被遮的那层画到卡片外的范围。
struct NotchOutsideShape: Shape {
    let inner: NotchRevealShape
    var outset: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -outset, dy: -outset))
        path.addPath(inner.path(in: rect))
        return path
    }
}

private struct NotchRevealContentOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

private struct NotchHostClipsCardKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NotchCardLayerActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 出场动画期间内容(顶行 / 歌词行 / 展开区)的透明度,背景不受影响 —— 先看到卡片形状长出来,再看到字。
    /// 默认 1;只有 `NotchWindowRoot` 在动画那 0.3s 里改它,设置页编辑台等别的宿主永远是 1。
    var notchRevealContentOpacity: Double {
        get { self[NotchRevealContentOpacityKey.self] }
        set { self[NotchRevealContentOpacityKey.self] = newValue }
    }

    /// 宿主是否已经替卡片裁好了外形。`NotchWindowRoot` 和设置页编辑台都设 true:它们挂在卡片外面的那道
    /// `NotchRevealShape`(`NotchRevealClip`)终态就是 `NotchHangingShape.card`,`NotchLyricsView` 再裁一遍是重复的一层 mask,
    /// 尺寸动画期间每帧多重设一次路径,抗锯齿的边缘还会被乘两次、比真窗口细一圈。默认 false —— 没有这层壳的宿主,卡片自己裁。
    /// 这个值对某个宿主是**常量**,不要在运行期切换:`NotchLyricsView` 按它选 clipShape 分支,切换会
    /// 重建子树、丢掉跑马灯等 @State。
    var notchHostClipsCard: Bool {
        get { self[NotchHostClipsCardKey.self] }
        set { self[NotchHostClipsCardKey.self] = newValue }
    }

    /// 这一块内容此刻是不是真的看得见:根上 = 窗口可见(`NotchWindowRoot` 按 occlusionState 给),
    /// `cardBodyLayer` 里每一层再与「是不是可见的那份」取与(`NotchCardLayerActive`)。
    /// 逐字填色 / 跟唱滚动 / 迷你进度条 / 倒计时 / 音浪 / 时间模块按它停表。
    /// 只能在**层内的子视图**里读才拿得到层的值(`NotchLayerActiveReader`),在 `NotchLyricsView`
    /// 自己的属性上读到的永远是根上的值。默认 true —— 编辑台等别的宿主不受影响。
    var notchCardLayerActive: Bool {
        get { self[NotchCardLayerActiveKey.self] }
        set { self[NotchCardLayerActiveKey.self] = newValue }
    }
}
