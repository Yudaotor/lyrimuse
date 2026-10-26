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
/// 展开 / 收回时线跟着外沿走,同时淡出 / 淡入(`fade`),不会停在终态的尺寸上横在变形的卡片中间。线贴着外沿(线宽一半的内缩),只画已播的那段、不画底槽,颜色从上往下渐亮
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

    static let thickness: CGFloat = 2.5
    /// 线心离卡片外沿的距离:半根线宽,线的外侧正好贴着外沿。
    static let inset: CGFloat = thickness / 2

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
        TimelineView(NotchEarLineSchedule(interval: NotchProgressLineTiming.interval(durationMs: total, width: length),
                                          paused: !ticking)) { _ in
            halves(card: shape, fraction: ticking
                   ? anchor.map { NotchProgressLine.fraction(total: total, positionMs: $0.extrapolatedPositionMs(now: Date())) }
                   : NotchProgressLine.frozenFraction(anchor: anchor, pausedPositionMs: pausedPositionMs,
                                                      durationMs: durationMs))
        }
    }

    @ViewBuilder
    private func halves(card: NotchHangingShape, fraction: Double?) -> some View {
        if let fraction {
            let played = ZStack {
                ForEach([false, true], id: \.self) { mirrored in
                    NotchEarProgressShape(card: card, notchWidth: notchWidth, notchHeight: outline.notchHeight,
                                          cardSize: cardSize, mirrored: mirrored)
                        .trim(from: 0, to: fraction)
                        .stroke(style: StrokeStyle(lineWidth: Self.thickness, lineCap: .round))
                }
            }
            let fill = LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .top, endPoint: .bottom)
            ZStack {
                fill.mask(played).blur(radius: 3).opacity(0.7)
                fill.mask(played)
            }
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
            p.addArc(center: CGPoint(x: 0, y: path.shoulderCenterY), radius: path.shoulderRadius,
                     startAngle: .radians(-Double(path.shoulderSweep)), endAngle: .zero, clockwise: false)
        }
        p.addLine(to: CGPoint(x: path.x, y: path.bottomY - r))
        p.addArc(center: CGPoint(x: path.x + r, y: path.bottomY - r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: path.endX, y: path.bottomY))
        let left = rect.midX - cardSize.width / 2
        let flip = mirrored ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: cardSize.width, ty: 0) : .identity
        return p.applying(flip.concatenating(CGAffineTransform(translationX: left, y: rect.minY)))
    }
}
