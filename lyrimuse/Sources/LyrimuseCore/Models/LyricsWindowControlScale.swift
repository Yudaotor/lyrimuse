import CoreGraphics

/// 歌词窗口完整尺寸(和照它画的网页歌词)里能点的那些控件放大到百分之几(设置里「控件大小」那根滑杆):播放控制那一排、
/// 歌名旁的圆钮、右下那排按钮一起按 `factor(percent:)` 放大;歌词、封面、排版比例不变。窗口投到手机这类小屏上时
/// 按钮太小、点不准,往大调。见 07 章决策 195、196。
public enum LyricsWindowControlScale {
    public static let percentRange: ClosedRange<Double> = 100...200
    public static let percentStep: Double = 5
    public static let defaultPercent: Double = 100

    /// 百分比换成倍数。先夹进范围:存坏的值、别的版本写进来的越界值都按边界算。
    public static func factor(percent: Double) -> CGFloat {
        guard percent.isFinite else { return 1 }
        return CGFloat(min(max(percent, percentRange.lowerBound), percentRange.upperBound) / 100)
    }
}

/// 播放控制那一排(随机 | 上一首 播放 下一首 | 循环)的尺寸。各档按左栏宽度(封面边长)算再夹值,
/// 再乘上「控件大小」的倍数;一排放不下时倍数自动收小,最小收到 1(100% 原样)。
/// 歌词窗口 `playbackControls` 和网页歌词 `WebLyricsControlsLayout` 共用这一份,两边不各写一遍。
public struct LyricsTransportMetrics: Equatable, Sendable {
    /// 实际用上的倍数(请求的倍数被一排的宽度收过之后)。
    public let factor: CGFloat
    public let modeFontSize: CGFloat
    public let skipFontSize: CGFloat
    public let playFontSize: CGFloat
    /// 播放 / 暂停那一格的定宽(两个字形宽度不同,固定住两侧按钮不跳)。
    public let playCellWidth: CGFloat
    /// 上一首 / 播放 / 下一首之间的间距。只按倍数增量的一半放大:键变大要紧,空隙不用跟着一样大。
    public let spacing: CGFloat

    /// 随机 / 循环那一格的定宽(字号 + 8,字形在格里居中)。
    public var modeCellWidth: CGFloat { modeFontSize + 8 }

    /// 上 / 下一首字形宽与字号之比(`backward.fill` 实排 1.48~1.54,取大的那头)。只用来估一排放不放得下。
    static let skipGlyphRatio: CGFloat = 1.54
    /// 随机 / 循环跟主三键之间至少留的空(同歌词窗口两个 `Spacer(minLength: 12)`)。
    static let sideGap: CGFloat = 12

    public init(width w: CGFloat, requested: CGFloat = 1) {
        func ctrl(_ ratio: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, w * ratio)) }
        let mode = ctrl(0.043, 11, 18)
        let skip = ctrl(0.060, 13, 25)
        let play = ctrl(0.079, 17, 33)
        let cell = ctrl(0.10, 22, 38)
        let gap = ctrl(0.116, 18, 48)
        // 一排宽 = 两格模式键(字号 × f + 8)+ 两侧最小空 + 两颗上 / 下一首 + 播放格 + 两个间距(gap × (1 + f) / 2),
        // 整理成 fixed + perUnit × f,反解出放得下的最大倍数。
        let fixed = 2 * 8 + 2 * Self.sideGap + gap
        let perUnit = 2 * mode + 2 * Self.skipGlyphRatio * skip + cell + gap
        let fit = perUnit > 0 ? (w - fixed) / perUnit : 1
        let f = max(1, min(max(requested, 1), fit))
        factor = f
        modeFontSize = mode * f
        skipFontSize = skip * f
        playFontSize = play * f
        playCellWidth = cell * f
        spacing = gap * (1 + (f - 1) / 2)
    }
}
