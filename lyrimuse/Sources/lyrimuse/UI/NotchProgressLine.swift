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
/// 卡片不为它变高。位置口径、重画间隔、显隐曲线同底边那根(`NotchProgressLine`),重画间隔按半边的长度算。
///
/// 外框由调用方给成稳态卡片那么大(宽 = 稳态宽,高 = `earProgressHeight`),肩膀和底角从同一个外形取
/// (`NotchHangingShape.cornerMetrics`)。线贴着卡片外沿(线宽一半的内缩),只画已播的那段、不画底槽,颜色从上往下渐亮
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
    @ObservedObject private var corners = NotchCornerLive.shared

    static let thickness: CGFloat = 2.5
    /// 线心离卡片外沿的距离:半根线宽,线的外侧正好贴着外沿。
    static let inset: CGFloat = thickness / 2

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let corner = outline.shape(corners).cornerMetrics(in: rect)
            let path = NotchEarProgressPath(width: rect.width, height: rect.height, notchWidth: notchWidth,
                                            notchHeight: outline.notchHeight, shoulder: corner.shoulder,
                                            cardCornerRadius: corner.radius, inset: Self.inset)
            if let anchor, active, let total = durationMs, total > 0 {
                TimelineView(.periodic(from: .now, by: NotchProgressLineTiming.interval(durationMs: total, width: path.length))) { _ in
                    halves(path, width: rect.width,
                           fraction: NotchProgressLine.fraction(total: total, positionMs: anchor.extrapolatedPositionMs(now: Date())))
                }
            } else {
                halves(path, width: rect.width, fraction: NotchProgressLine.frozenFraction(
                    anchor: anchor, pausedPositionMs: pausedPositionMs, durationMs: durationMs))
            }
        }
    }

    @ViewBuilder
    private func halves(_ path: NotchEarProgressPath, width: CGFloat, fraction: Double?) -> some View {
        if let fraction {
            let played = ZStack {
                ForEach([false, true], id: \.self) { mirrored in
                    NotchEarProgressShape(path: path, width: width, mirrored: mirrored)
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

/// `NotchEarProgressPath` 画成路径;`mirrored` = 右半边(左右翻过来,同样从屏幕上沿起笔)。
struct NotchEarProgressShape: Shape {
    let path: NotchEarProgressPath
    let width: CGFloat
    let mirrored: Bool

    func path(in rect: CGRect) -> Path {
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
        guard mirrored else { return p }
        return p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0))
    }
}
