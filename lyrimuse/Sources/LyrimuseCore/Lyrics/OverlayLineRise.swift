import CoreGraphics

/// 悬浮歌词换句动画的时序与起步几何。时长和缓动照抄 LyricsX `KaraokeLyricsView.displayLrc`。
public enum OverlayLineRise {
    /// 新主句走上来(或原地淡入)的时长,缓动 cubic-bezier(0.4, 0, 0.2, 1)。
    public static let duration: Double = 0.25
    public static let curve: (x1: Float, y1: Float, x2: Float, y2: Float) = (0.4, 0, 0.2, 1)
    /// 旧的一句(连同读音、译文)原地淡完的时长,缓动 ease-out。
    public static let fadeOutDuration: Double = 0.12
    /// 新的下一句等走上来的那一句到位、后半程才淡入,缓动 ease-out。
    public static let lateInDelay: Double = 0.13
    public static let lateInDuration: Double = 0.12
    /// 走上来的那一句下面的读音、译文从透明渐显的时长,缓动同走上来那条;走到大半时已经全实。
    public static let tailFadeInDuration: Double = 0.15
    /// 走上来的那一句跟上一拍下一句那一格交叉淡化的时长(新主句淡入、旧下一句淡出),缓动同走上来那条。
    public static let crossfadeDuration: Double = 0.15

    /// 起步那一刻加在新主句那一格图层上的变换。那一格已经按终点摆好,起步时要看起来是以 `anchor`(终点那一格顶边上
    /// 按对齐取的一点)为中心缩到 `scale`、再整体挪 `offset`(从终点挪到上一拍下一句那一格)。图层变换绕图层自己的
    /// 锚点施加,锚点落在 `position`;三个点都在同一个坐标系里。结果 `v ↦ scale·v + t`,
    /// t = (1 − scale)(anchor − position) + offset。
    public static func startTransform(scale: CGFloat, anchor: CGPoint, position: CGPoint, offset: CGVector) -> CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                          tx: (1 - scale) * (anchor.x - position.x) + offset.dx,
                          ty: (1 - scale) * (anchor.y - position.y) + offset.dy)
    }

    /// 图层上的点 `point` 在变换 `transform`(绕锚点 `position` 施加)下画到哪里。
    public static func rendered(_ point: CGPoint, transform: CGAffineTransform, position: CGPoint) -> CGPoint {
        let v = CGPoint(x: point.x - position.x, y: point.y - position.y).applying(transform)
        return CGPoint(x: position.x + v.x, y: position.y + v.y)
    }
}
