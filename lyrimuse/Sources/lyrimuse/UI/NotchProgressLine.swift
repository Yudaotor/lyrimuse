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
    /// 这根线此刻该不该露出来(`showsEarProgressLine`)。线头亮点是原生图层,外层的淡出管不到它,按这个自己淡。
    let visible: Bool
    @ObservedObject private var corners = NotchCornerLive.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 暂停(没有锚点或锚点冻住)时整根线的透明度。
    static let pausedOpacity: Double = 0.45

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
        let paused = anchor.map(\.isFrozen) ?? true
        TimelineView(NotchEarLineSchedule(interval: NotchProgressLineTiming.interval(durationMs: total, width: length),
                                          paused: !ticking)) { _ in
            let fraction = ticking
                ? anchor.map { NotchProgressLine.fraction(total: total, positionMs: $0.extrapolatedPositionMs(now: Date())) }
                : NotchProgressLine.frozenFraction(anchor: anchor, pausedPositionMs: pausedPositionMs, durationMs: durationMs)
            ZStack {
                halves(card: shape, fraction: fraction)
                if let fraction {
                    NotchEarProgressHead(card: shape, notchWidth: notchWidth, notchHeight: outline.notchHeight,
                                         cardSize: cardSize, fraction: fraction, tint: tint,
                                         breathing: ticking && !paused && !reduceMotion,
                                         opacity: visible ? (paused ? Self.pausedOpacity : 1) : 0,
                                         reduceMotion: reduceMotion)
                }
            }
            // 换歌、跳进度时线和亮点滑过去;平时一拍拍往前走不补间(`NotchEarProgressMotion.jumpKey`)。
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45),
                       value: NotchEarProgressMotion.jumpKey(anchor: anchor, now: Date()))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
            $0.opacity(paused ? Self.pausedOpacity : 1)
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

/// 「耳朵」进度线的线头:一颗小白点、外面一圈同色淡光,位置按同一条路径算(`NotchEarProgressPath.point(atFraction:)`)。
///
/// 两颗点是 Core Animation 图层,动效全由图层自己做,App 平时不重画:呼吸(透明度来回)交给渲染进程循环跑;显隐、暂停变暗、
/// 变形 / 跳进度时的位移也是图层动画。别改成 SwiftUI 做呼吸(按帧算亮度、或循环的隐式动画):都要逐帧重算,常驻时 CPU
/// 明显变高(见 05 章决策 111)。外层给线做的淡出管不到原生视图,所以透明度由这里自己按同样的时长做(`opacity` 传目标值)。
struct NotchEarProgressHead: NSViewRepresentable {
    let card: NotchHangingShape
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let cardSize: CGSize
    let fraction: Double
    let tint: Color
    let breathing: Bool
    /// 目标透明度:藏着 0、暂停时 `NotchEarProgressLine.pausedOpacity`、其余 1。
    let opacity: Double
    let reduceMotion: Bool

    func makeNSView(context: Context) -> NotchEarHeadView { NotchEarHeadView() }

    func updateNSView(_ view: NotchEarHeadView, context: Context) {
        let geometry = NotchEarProgressShape.geometry(size: cardSize, card: card, notchWidth: notchWidth,
                                                      notchHeight: notchHeight)
        view.update(path: geometry, fraction: CGFloat(fraction), cardWidth: cardSize.width, tint: NSColor(tint),
                    breathing: breathing, opacity: Float(opacity), reduceMotion: reduceMotion)
    }
}

/// 两侧线头各一组图层(淡光 + 白点)。不接鼠标。
final class NotchEarHeadView: NSView {
    private let container = CALayer()
    private let halos = [CALayer(), CALayer()]
    private let cores = [CALayer(), CALayer()]
    private static let haloRadius: CGFloat = 5
    private static let coreRadius: CGFloat = 1.6
    private static let pulseKey = "pulse"
    /// 线头一次挪得超过这么多(pt)就滑过去(变形、跳进度),小于它是正常往前走、直接挪。
    private static let slideThreshold: CGFloat = 3
    private var path: NotchEarProgressPath?
    private var fraction: CGFloat = 0
    private var cardWidth: CGFloat = 0
    private var breathing = false
    private var reduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        container.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "sublayers": NSNull()]
        layer?.addSublayer(container)
        for (dot, radius) in zip(halos + cores, [Self.haloRadius, Self.haloRadius, Self.coreRadius, Self.coreRadius]) {
            dot.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            dot.cornerRadius = radius
            dot.opacity = 0.8
            dot.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull()]
            container.addSublayer(dot)
        }
        cores.forEach { $0.backgroundColor = NSColor.white.cgColor }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        CATransaction.commit()
        place()
    }

    /// 两种滑法:卡片变形(宽度变了)时走直线,跟着外沿往外 / 往回;同一张卡上跳进度时沿路径走(按路径取一串点),
    /// 走直线会从卡片中间斜穿过去。藏着时也滑:收回时亮点从展开那一刻的位置一边淡入一边滑回来,直接跳过去会在还没收拢的
    /// 卡片中间先冒出来。第一次摆(还没有位置)直接放。
    func update(path: NotchEarProgressPath, fraction: CGFloat, cardWidth: CGFloat, tint: NSColor, breathing: Bool,
                opacity: Float, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        let old = self.path.map { ($0, self.fraction) }
        let morphed = cardWidth != self.cardWidth
        self.path = path
        self.fraction = fraction
        self.cardWidth = cardWidth
        halos.forEach { $0.backgroundColor = tint.withAlphaComponent(tint.alphaComponent * 0.45).cgColor }
        if let old, !reduceMotion {
            let from = old.0.point(atFraction: old.1), to = path.point(atFraction: fraction)
            if morphed {
                place(slide: .straight)
            } else if hypot(to.x - from.x, to.y - from.y) > Self.slideThreshold {
                place(slide: .alongPath(from: old.1))
            } else {
                place(slide: nil)
            }
        } else {
            place(slide: nil)
        }
        fade(to: opacity)
        setBreathing(breathing)
    }

    private enum Slide {
        case straight
        case alongPath(from: CGFloat)
    }

    /// 卡片在本视图里水平居中、贴顶(同线的 `NotchEarProgressShape`);图层坐标原点在左下,y 要翻过来。
    private func place(slide: Slide? = nil) {
        guard let path else { return }
        let left = bounds.midX - cardWidth / 2
        func screen(_ p: CGPoint, mirrored: Bool) -> CGPoint {
            CGPoint(x: left + (mirrored ? cardWidth - p.x : p.x), y: bounds.height - p.y)
        }
        let head = path.point(atFraction: fraction)
        for (i, mirrored) in [false, true].enumerated() {
            let to = screen(head, mirrored: mirrored)
            for dot in [halos[i], cores[i]] {
                switch slide {
                case .straight:
                    let anim = CABasicAnimation(keyPath: "position")
                    anim.fromValue = NSValue(point: dot.presentation()?.position ?? dot.position)
                    anim.toValue = NSValue(point: to)
                    anim.duration = 0.4
                    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    dot.add(anim, forKey: "slide")
                case .alongPath(let start):
                    let steps = 24
                    let anim = CAKeyframeAnimation(keyPath: "position")
                    anim.values = (0...steps).map { k in
                        let f = start + (fraction - start) * CGFloat(k) / CGFloat(steps)
                        return NSValue(point: screen(path.point(atFraction: f), mirrored: mirrored))
                    }
                    anim.duration = 0.45
                    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    dot.add(anim, forKey: "slide")
                case nil:
                    break
                }
                dot.position = to
            }
        }
    }

    /// 时长同线:藏 0.16 秒、露 0.28 秒,暂停变暗 / 恢复 0.35 秒(`NotchEarProgressLine.fade`、`pausedOpacity`)。
    private func fade(to target: Float) {
        guard container.opacity != target else { return }
        let from = container.presentation()?.opacity ?? container.opacity
        let duration: Double = target == 0 ? 0.16 : (from == 0 ? 0.28 : 0.35)
        if !reduceMotion {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = from
            anim.toValue = target
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.add(anim, forKey: "fade")
        }
        container.opacity = target
    }

    private func setBreathing(_ on: Bool) {
        guard on != breathing || (on && cores[0].animation(forKey: Self.pulseKey) == nil) else { return }
        breathing = on
        for dot in halos + cores {
            dot.removeAnimation(forKey: Self.pulseKey)
            guard on else { continue }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.55
            pulse.toValue = 1
            pulse.duration = NotchEarProgressMotion.pulsePeriod / 2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: Self.pulseKey)
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
