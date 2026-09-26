import CoreGraphics

/// 悬浮歌词「调整宽度」模式下拖窗口左右边缘改宽度的几何。窗口控制器只负责收鼠标事件、把结果
/// 设到窗口上,判据和算式都在这里,由 selftest 钉住。
public enum OverlayWidthDrag {
    public enum Edge: Equatable, Sendable {
        case leading
        case trailing
    }

    /// 窗口左右两侧各多宽算「边缘」(点)。只在窗口**里面**:窗口外的点击属于下层 App。
    public static let edgeBand: CGFloat = 10

    /// 窗口本地坐标(左下原点)里的一点落在哪条可拖的边上;不在任何一条上返回 nil。
    /// 窗口很窄时每侧最多占四分之一宽,中间始终留出不算边缘的一段。
    public static func edge(at point: CGPoint, windowSize: CGSize, band: CGFloat = edgeBand) -> Edge? {
        guard windowSize.width > 0, windowSize.height > 0,
              point.x >= 0, point.x <= windowSize.width,
              point.y >= 0, point.y <= windowSize.height else { return nil }
        let b = min(band, windowSize.width / 4)
        if point.x <= b { return .leading }
        if point.x >= windowSize.width - b { return .trailing }
        return nil
    }

    /// 拖动中的新 frame(屏幕坐标,左下原点)。
    ///
    /// - `symmetric == false`(自由位置):拖哪条边动哪条边,对边不动。
    /// - `symmetric == true`(顶部 / 底部居中预设):中心不动、两边对称伸缩,位置仍是居中。
    /// 宽度夹进 `widthRange`、取整;再受 `visibleFrame` 限制 —— 被拖的边不越过可见区,对称时
    /// 整扇窗不超出可见区宽度。两条上限冲突时 `widthRange` 的下限优先(窗口不会窄于下限)。
    /// y 与高度原样沿用 `start`,调用方按当前高度覆盖。
    public static func resizedFrame(
        start: CGRect, edge: Edge, deltaX: CGFloat, symmetric: Bool,
        widthRange: ClosedRange<CGFloat>, visibleFrame: CGRect?
    ) -> CGRect {
        let growth = edge == .trailing ? deltaX : -deltaX
        let wanted = start.width + (symmetric ? 2 * growth : growth)
        var upper = widthRange.upperBound
        if let v = visibleFrame {
            let room: CGFloat
            if symmetric {
                room = v.width
            } else {
                room = edge == .trailing ? v.maxX - start.minX : start.maxX - v.minX
            }
            upper = min(upper, room)
        }
        let width = max(widthRange.lowerBound, min(upper, wanted)).rounded()
        var x: CGFloat
        if symmetric {
            x = start.midX - width / 2
            if let v = visibleFrame {
                x = max(v.minX, min(x, v.maxX - width))
            }
        } else {
            x = edge == .trailing ? start.minX : start.maxX - width
        }
        return CGRect(x: x, y: start.minY, width: width, height: start.height)
    }
}
