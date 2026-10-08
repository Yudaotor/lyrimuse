/// 悬浮歌词换句动画的时序。时长和缓动照抄 LyricsX `KaraokeLyricsView.displayLrc`。
public enum OverlayLineRise {
    /// 新主句走上来(或原地淡入)的时长,缓动 cubic-bezier(0.4, 0, 0.2, 1)。
    public static let duration: Double = 0.25
    public static let curve: (x1: Float, y1: Float, x2: Float, y2: Float) = (0.4, 0, 0.2, 1)
    /// 旧的一句(连同读音、译文)原地淡完的时长,缓动 ease-out。
    public static let fadeOutDuration: Double = 0.12
    /// 新的下一句等走上来的那一句到位、后半程才淡入,缓动 ease-out。
    public static let lateInDelay: Double = 0.13
    public static let lateInDuration: Double = 0.12
}
