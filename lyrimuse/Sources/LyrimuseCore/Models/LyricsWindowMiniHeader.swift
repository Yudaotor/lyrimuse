import Foundation

/// 迷你尺寸歌词窗口顶部那一行要显示哪几样。
///
/// 只管**迷你尺寸**。完整尺寸的曲目信息在左栏(封面下面那块 `trackInfoRow`),是另一套排版,
/// 不吃这个设置。
///
/// 做成 OptionSet 而不是三个 Bool:三个 Bool 要三个 `Keys`、三个 `@Published`、三条订阅、
/// 三次 init 赋值,而它们永远一起读、一起写。位掩码只占一个存储键,加第四样(比如年份)也只是
/// 多一个 case。
///
/// 存进 UserDefaults 的是 `rawValue`(Int)。**位的值一旦定下就不能改**——改了等于把老用户存的
/// 选择错位解读(比如把"歌名+歌手"读成"歌手+专辑")。要废弃某一样就让那个位空着,别复用。
public struct LyricsWindowMiniHeaderFields: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let title = LyricsWindowMiniHeaderFields(rawValue: 1 << 0)
    public static let artist = LyricsWindowMiniHeaderFields(rawValue: 1 << 1)
    public static let album = LyricsWindowMiniHeaderFields(rawValue: 1 << 2)

    /// 默认「歌名 · 歌手」—— 就是加这颗设置之前写死的那两样,没碰过设置的人升级后观感不变。
    public static let `default`: LyricsWindowMiniHeaderFields = [.title, .artist]

    /// 渲染顺序固定:歌名 → 歌手 → 专辑。
    ///
    /// **不做成可排序的**:这一行是"这是哪首歌"的一句话交代,歌名在前是所有播放器的共识;
    /// 让它可排序只会多一份状态、多一处 UI,换不来什么。
    public static let orderedAll: [LyricsWindowMiniHeaderFields] = [.title, .artist, .album]

    /// 按固定顺序挑出要显示的那几样,空串(比如这首歌没有专辑名)自动跳过。
    ///
    /// 放在 Core 而不是视图里,是因为"选了但值是空"这条边界最容易漏 —— 漏了就会画出
    /// 「歌名 - 」这种尾巴挂着分隔符的行。selftest 钉着它。
    public func visibleValues(title: String, artist: String, album: String) -> [String] {
        visibleParts(title: title, artist: artist, album: album).map(\.value)
    }

    /// 同 `visibleValues`,每一段带上它是哪一样 —— 歌手 / 专辑那两段要各自接「看简介」的点击。
    public struct Part: Equatable, Sendable {
        public let field: LyricsWindowMiniHeaderFields
        public let value: String

        public init(field: LyricsWindowMiniHeaderFields, value: String) {
            self.field = field
            self.value = value
        }
    }

    public func visibleParts(title: String, artist: String, album: String) -> [Part] {
        let source: [LyricsWindowMiniHeaderFields: String] =
            [.title: title, .artist: artist, .album: album]
        return Self.orderedAll.compactMap { field in
            guard contains(field), let v = source[field] else { return nil }
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Part(field: field, value: trimmed)
        }
    }
}

/// 迷你顶部信息那一组占窗口宽度的百分之几(设置里「顶部信息 › 宽度」那根滑杆)。
///
/// 这一组按这个宽度摆、在窗口里居中,里面的内容再在这块里居中;放不下的那一行末尾省略号截断。
/// 设置页预览里那圈虚线框画的就是这块范围,拖滑杆时框跟着变宽变窄。
///
/// 这一组的上沿必须低于红绿灯和右上角悬停胶囊那条横带:上限能放到 100% 靠的就是这一点,
/// 把这一组往上挪就得把上限一起收回来。
public enum LyricsWindowMiniHeaderWidth {
    public static let percentRange: ClosedRange<Double> = 40...100
    public static let percentStep: Double = 5
    /// 默认 65%(默认 420 宽的迷你窗里约 273pt)。
    public static let defaultPercent: Double = 65

    /// 这一组实际给多宽。百分比先夹进范围:存坏的值、别的版本写进来的越界值都按边界算。
    public static func width(windowWidth: CGFloat, percent: Double) -> CGFloat {
        let p = min(max(percent, percentRange.lowerBound), percentRange.upperBound)
        return max(0, windowWidth) * CGFloat(p / 100)
    }
}

/// 迷你顶部信息那一组的基准字号 / 封面尺寸,以及它占窗口高度的百分之几(「顶部信息 › 高度」那根滑杆)。
///
/// 百分比按**三行都开着**(歌名 / 歌手那行 / 时间)时那叠文字的高度算:窗口高度 × 百分比 ÷ 基准高度
/// 得到一个倍率,字号、行距、封面边长、封面与文字的间距都乘它。关掉几行这一组跟着变矮,倍率不变 ——
/// 开关某一行时字不该忽大忽小。
public enum LyricsWindowMiniHeaderSize {
    public static let percentRange: ClosedRange<Double> = 8...25
    public static let percentStep: Double = 1
    /// 默认 14%:默认 320 高的迷你窗里倍率约 1,即下面这组基准尺寸。
    public static let defaultPercent: Double = 14

    /// 第一行(主角,一般是歌名)。
    public static let titleFontSize: CGFloat = 12
    /// 第二行(其余几样合成一行,一般是「歌手 — 专辑」)。
    public static let subtitleFontSize: CGFloat = 11
    public static let timeFontSize: CGFloat = 10
    public static let lineSpacing: CGFloat = 1
    /// 封面小图的边长区间。上限让它始终是"文字旁边的一枚小标记",不跟着三行文字长成一块方图;
    /// 下限是只剩一行时还认得出是什么图。
    public static let coverMinSide: CGFloat = 24
    public static let coverMaxSide: CGFloat = 32
    /// 封面小图和文字块之间的空。
    public static let coverGap: CGFloat = 8
    /// 行高按字号 × 1.3 估(SwiftUI 系统字的默认行高比例)。
    public static let lineHeightFactor: CGFloat = 1.3

    /// 三行都开着时那叠文字按基准尺寸估出来的高度,百分比拿它去比。
    public static var referenceHeight: CGFloat {
        (titleFontSize + subtitleFontSize + timeFontSize) * lineHeightFactor + 2 * lineSpacing
    }

    /// 倍率的范围:窗口拖得再矮,字也不小于基准的 0.8 倍;拖得再高,也不放到 3 倍以上。
    public static let scaleRange: ClosedRange<CGFloat> = 0.8...3

    /// 按窗口高度和百分比算倍率。百分比先夹进范围,存坏的值、别的版本写进来的越界值都按边界算。
    public static func scale(windowHeight: CGFloat, percent: Double) -> CGFloat {
        let p = min(max(percent, percentRange.lowerBound), percentRange.upperBound)
        let raw = max(0, windowHeight) * CGFloat(p / 100) / referenceHeight
        return min(max(raw, scaleRange.lowerBound), scaleRange.upperBound)
    }
}
