import LyrimuseCore
import SwiftUI

/// 卡片底边那根进度线(「进度线」选「底边」,`AppSettings.notchShowsProgressLine`),只在没展开时画:展开区有自己那条可拖的进度条。
///
/// 位置口径同耳朵里的时间(锚点外推 ?? 暂停冻结位置),时长未知时整根不画。线一秒只走一两个点,按「走半个点」的间隔排表
/// (`NotchProgressLineTiming.interval`),不逐帧重算;没有锚点(暂停)或窗口看不见时不排表,静态画冻结值。
/// 左右按卡片底角的圆角让开,线只画在底边的直线段上。
struct NotchProgressLine: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    let tint: Color
    /// 窗口此刻看不看得见(`notchCardLayerActive`)。
    let active: Bool
    let outline: NotchCardOutline
    @ObservedObject private var corners = NotchCornerLive.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let thickness: CGFloat = 1.5

    /// 线显隐的透明度曲线。线不跟着卡片底边动,停在稳态底边的高度上:藏起来(展开、收起)不补间、立刻藏;露出来(回到稳态)
    /// 等卡片快收完再淡入,不横在还没收完的内容上。
    static func fade(showing: Bool, reduceMotion: Bool) -> Animation? {
        guard showing, !reduceMotion else { return nil }
        return .easeOut(duration: 0.14).delay(0.2)
    }

    var body: some View {
        GeometryReader { proxy in
            let inset = bottomCornerRadius + 2
            let width = max(0, proxy.size.width - inset * 2)
            Group {
                if let anchor, active, let total = durationMs, total > 0 {
                    TimelineView(.periodic(from: .now, by: NotchProgressLineTiming.interval(durationMs: total, width: width))) { _ in
                        line(width: width, fraction: Self.fraction(total: total, positionMs: anchor.extrapolatedPositionMs(now: Date())))
                    }
                } else {
                    line(width: width, fraction: Self.frozenFraction(anchor: anchor, pausedPositionMs: pausedPositionMs,
                                                                     durationMs: durationMs))
                }
            }
            .frame(width: width)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : NotchEarProgressLine.tintChange, value: tint)
        }
        .frame(height: Self.thickness)
    }

    @ViewBuilder
    private func line(width: CGFloat, fraction: Double?) -> some View {
        if let fraction {
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.16))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: width * fraction)
            }
        }
    }

    static func fraction(total: Int, positionMs: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(positionMs) / Double(total)))
    }

    /// 不排表时画的那一格:锚点外推 ?? 暂停冻结位置;时长未知时 nil(整根不画)。
    static func frozenFraction(anchor: ProgressAnchor?, pausedPositionMs: Int?, durationMs: Int?) -> Double? {
        durationMs.flatMap { total in
            (anchor?.extrapolatedPositionMs(now: Date()) ?? pausedPositionMs).map { fraction(total: total, positionMs: $0) }
        }
    }

    /// 没展开那一态的底角圆角(两个圆角设置都是默认时按卡片高度算,同卡片外形)。
    private var bottomCornerRadius: CGFloat {
        let height = outline.collapsedHeight
        guard let profile = outline.corner(corners) else { return NotchOutline.proportionalRadius(height: height) }
        return profile.collapsed.radius(height: height, notchHeight: outline.notchHeight)
    }
}

/// 「进度线」选「耳朵」时那根线:沿卡片外沿从屏幕上沿往下、绕过底角走到刘海(`NotchEarProgressPath`),左右两半同时走。
/// 卡片不为它变高。位置口径、重画间隔同底边那根(`NotchProgressLine`),重画间隔按半边的长度算。
///
/// 卡片内部一上来就按终态尺寸布局,变形动画只在外层(`NotchWindowRoot` 的尺寸弹簧和裁剪)逐帧插值,所以形状不能靠
/// `path(in:)` 拿到的矩形:卡片尺寸作为形状的可动画值(`NotchEarProgressShape.cardSize`)传进去,跟同一次弹簧逐帧插值,
/// 路径按它算、在矩形里水平居中贴顶,跟卡片外形重合。肩膀和底角跟卡片外形读同一处(`NotchHangingShape.cornerMetrics`)。
/// 展开 / 收回时线跟着外沿走,同时淡出 / 淡入(`fade`),不会停在终态的尺寸上横在变形的卡片中间。线贴着外沿(往外多伸 `overshoot`、被卡片外形裁掉),只画已播的那段、不画底槽,颜色从上往下渐亮
/// (上端淡进菜单栏),底下垫一层同色的淡光晕,看起来是卡片的边亮起来,不是另描的一圈框。
struct NotchEarProgressLine: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    let tint: Color
    /// 窗口此刻看不看得见(`notchCardLayerActive`)。
    let active: Bool
    let outline: NotchCardOutline
    let notchWidth: CGFloat
    /// 卡片此刻的目标尺寸(`cardWidth` × `cardHeight`)。
    let cardSize: CGSize
    @ObservedObject private var corners = NotchCornerLive.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 暂停(没有锚点或锚点冻住)时整根线的透明度。
    static let pausedOpacity: Double = 0.45
    /// 换封面时线的颜色渐变过去(同换歌掉歌名那枚音符)。
    static let tintChange: Animation = .easeInOut(duration: 0.35)

    /// 卡片里露出来的线宽。
    static let thickness: CGFloat = 2.5
    /// 线往卡片外沿外面多伸出去的宽度,被卡片外形裁掉。外沿那圈半透明像素里只有线色、没有卡片底色,不会描出一圈暗边。
    static let overshoot: CGFloat = 1
    static let strokeWidth: CGFloat = thickness + overshoot
    /// 线心离卡片外沿的距离。
    static let inset: CGFloat = thickness - strokeWidth / 2

    /// 线显隐的透明度曲线。线跟着外沿变形,所以两头都补间:藏起来(展开、收起)跟着卡片长开淡掉,
    /// 露出来(回到稳态)跟着卡片收拢淡入。
    static func fade(showing: Bool, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return showing ? .easeOut(duration: 0.28) : .easeOut(duration: 0.16)
    }

    // 只有一个 TimelineView,停表靠时间表(`NotchEarLineSchedule.paused`),别写成「在走 / 停着」两个分支:显隐一切换
    // 分支就换了视图身份,新插进来的那份直接落在终态尺寸上,线不跟着外沿变形。
    var body: some View {
        let shape = outline.shape(corners)
        let total = durationMs ?? 0
        let ticking = anchor != nil && active && total > 0
        let length = NotchEarProgressShape.geometry(size: cardSize, card: shape, notchWidth: notchWidth,
                                                    notchHeight: outline.notchHeight).length
        let paused = anchor.map(\.isFrozen) ?? true
        TimelineView(NotchEarLineSchedule(interval: NotchProgressLineTiming.interval(durationMs: total, width: length),
                                          paused: !ticking)) { _ in
            let fraction = ticking
                ? anchor.map { NotchProgressLine.fraction(total: total, positionMs: $0.extrapolatedPositionMs(now: Date())) }
                : NotchProgressLine.frozenFraction(anchor: anchor, pausedPositionMs: pausedPositionMs, durationMs: durationMs)
            halves(card: shape, fraction: fraction)
                // 换歌、跳进度时线滑过去;平时一拍拍往前走不补间(`NotchEarProgressMotion.jumpKey`)。
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45),
                           value: NotchEarProgressMotion.jumpKey(anchor: anchor, now: Date()))
                .animation(reduceMotion ? nil : Self.tintChange, value: tint)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
            $0.opacity(paused ? Self.pausedOpacity : 1)
        }
    }

    // 线直接用纯色描边、上淡下实靠一层静态的透明度遮罩,别把颜色写进渐变里再拿线当遮罩:那样换封面时颜色不补间,硬切。
    @ViewBuilder
    private func halves(card: NotchHangingShape, fraction: Double?) -> some View {
        if let fraction {
            let played = ZStack {
                ForEach([false, true], id: \.self) { mirrored in
                    NotchEarProgressShape(card: card, notchWidth: notchWidth, notchHeight: outline.notchHeight,
                                          cardSize: cardSize, mirrored: mirrored)
                        .trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round))
                }
            }
            ZStack {
                played.blur(radius: 3).opacity(0.7)
                played
            }
            .mask(LinearGradient(colors: [.white.opacity(0.85), .white], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// 耳朵那根线的重画时间表:在走时每 `interval` 一拍,停着时只有开头一拍。
struct NotchEarLineSchedule: TimelineSchedule {
    let interval: TimeInterval
    let paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        return AnyIterator {
            defer { next = paused ? nil : next?.addingTimeInterval(interval) }
            return next
        }
    }
}

/// `NotchEarProgressPath` 画成路径。几何按 `cardSize` 算,它是可动画值,尺寸弹簧里逐帧插值,线跟着卡片外沿走;
/// 画在矩形里水平居中、贴顶(卡片在窗口里也是这么摆的)。`mirrored` = 右半边(左右翻过来,同样从屏幕上沿起笔)。
struct NotchEarProgressShape: Shape {
    let card: NotchHangingShape
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var cardSize: CGSize
    let mirrored: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cardSize.width, cardSize.height) }
        set { cardSize = CGSize(width: newValue.first, height: newValue.second) }
    }

    static func geometry(size: CGSize, card: NotchHangingShape, notchWidth: CGFloat,
                         notchHeight: CGFloat) -> NotchEarProgressPath {
        let corner = card.cornerMetrics(in: CGRect(origin: .zero, size: size))
        return NotchEarProgressPath(width: size.width, height: size.height, notchWidth: notchWidth, notchHeight: notchHeight,
                                    shoulder: corner.shoulder, cardCornerRadius: corner.radius,
                                    inset: NotchEarProgressLine.inset)
    }

    func path(in rect: CGRect) -> Path {
        let path = Self.geometry(size: cardSize, card: card, notchWidth: notchWidth, notchHeight: notchHeight)
        let r = path.cornerRadius
        var p = Path()
        p.move(to: CGPoint(x: path.startX, y: 0))
        if path.shoulderRadius > 0 {
            p.addFlattenedArc(center: CGPoint(x: 0, y: path.shoulderCenterY), radius: path.shoulderRadius,
                              from: .radians(-Double(path.shoulderSweep)), to: .zero)
        }
        p.addLine(to: CGPoint(x: path.x, y: path.bottomY - r))
        p.addFlattenedArc(center: CGPoint(x: path.x + r, y: path.bottomY - r), radius: r,
                          from: .degrees(180), to: .degrees(90))
        p.addLine(to: CGPoint(x: path.endX, y: path.bottomY))
        let left = rect.midX - cardSize.width / 2
        let flip = mirrored ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: cardSize.width, ty: 0) : .identity
        return p.applying(flip.concatenating(CGAffineTransform(translationX: left, y: rect.minY)))
    }
}
