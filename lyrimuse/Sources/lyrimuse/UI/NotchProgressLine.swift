import LyrimuseCore
import SwiftUI

/// 卡片底边那根进度线(「进度线」,`AppSettings.notchShowsProgressLine`),只在没展开时画:展开区有自己那条可拖的进度条。
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
                        line(width: width, fraction: fraction(total: total, positionMs: anchor.extrapolatedPositionMs(now: Date())))
                    }
                } else {
                    line(width: width, fraction: durationMs.flatMap { total in
                        (anchor?.extrapolatedPositionMs(now: Date()) ?? pausedPositionMs).map { fraction(total: total, positionMs: $0) }
                    })
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

    private func fraction(total: Int, positionMs: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(positionMs) / Double(total)))
    }

    /// 没展开那一态的底角圆角(两个圆角设置都是默认时按卡片高度算,同卡片外形)。
    private var bottomCornerRadius: CGFloat {
        let height = outline.collapsedHeight
        guard let profile = outline.corner(corners) else { return NotchOutline.proportionalRadius(height: height) }
        return profile.collapsed.radius(height: height, notchHeight: outline.notchHeight)
    }
}
