import CoreGraphics
import Foundation

/// 歌词窗口完整尺寸(和照它画的网页歌词)歌词列表的排版与景深调节:字号缩放、读音 / 译文大小、行间距、读音 / 译文间距、
/// 未唱 / 已唱变暗、模糊。迷你「多行」共用同一份列表,一律按 `standard` 画。
///
/// 每一项存百分数。全是默认值时字号、副行字号、行距、行内间距、各行不透明度和模糊半径跟没有这项设置时逐数相等
/// (selftest 逐数核对)。间距三项是「比默认多出多少个字号的百分之几」,可以是负的;别的项是倍数或占正文字号的比例。
/// 见 07 章决策 216。
public struct LyricsWindowListTuning: Equatable, Sendable {
    /// 九项。原始值是调试深链里的参数名。
    public enum Item: String, CaseIterable, Sendable {
        case fontScale = "font-scale"
        case romanizationSize = "romanization-size"
        case translationSize = "translation-size"
        case lineSpacing = "line-spacing"
        case romanizationGap = "romanization-gap"
        case translationGap = "translation-gap"
        case upcomingDim = "upcoming-dim"
        case pastDim = "past-dim"
        case blur

        /// 可调范围(百分数)。
        public var range: ClosedRange<Double> {
            switch self {
            case .fontScale: return 60...150
            case .romanizationSize, .translationSize: return 30...100
            case .lineSpacing: return -50...100
            case .romanizationGap: return -10...50
            case .translationGap: return -20...50
            case .upcomingDim, .pastDim: return 0...150
            case .blur: return 0...200
            }
        }

        /// 滑杆每一格。
        public var step: Double {
            switch self {
            case .fontScale, .upcomingDim, .pastDim, .blur: return 5
            default: return 1
            }
        }

        /// 默认值,也是加这项设置前写死的那个数。
        public var defaultPercent: Double {
            switch self {
            case .fontScale, .upcomingDim, .pastDim, .blur: return 100
            case .romanizationSize: return 54
            case .translationSize: return 57
            case .lineSpacing, .romanizationGap, .translationGap: return 0
            }
        }

        /// 间距三项的读数带正负号(「+10%」「−5%」),别的项照常(「120%」)。
        public var isSignedOffset: Bool {
            self == .lineSpacing || self == .romanizationGap || self == .translationGap
        }

        /// 改它要整张列表重新排版画字;景深三项只改各行透明度和模糊,不重建。
        public var rebuildsList: Bool {
            self != .upcomingDim && self != .pastDim && self != .blur
        }

        /// 存着的值夹回范围;不是有限数时按默认值。
        public func clamped(_ value: Double) -> Double {
            guard value.isFinite else { return defaultPercent }
            return min(max(value, range.lowerBound), range.upperBound)
        }

        /// 读数:「120%」,间距三项「+10%」「0%」「−5%」。
        public func percentText(_ value: Double) -> String {
            let n = Int(value.rounded())
            guard isSignedOffset, n != 0 else { return "\(n)%" }
            return n > 0 ? "+\(n)%" : "\u{2212}\(-n)%"
        }
    }

    private var percents: [Item: Double]

    public init(_ percents: [Item: Double] = [:]) {
        var all: [Item: Double] = [:]
        for item in Item.allCases {
            all[item] = item.clamped(percents[item] ?? item.defaultPercent)
        }
        self.percents = all
    }

    /// 九项都是默认值。
    public static let standard = LyricsWindowListTuning()

    /// 按项取百分数 / 改百分数;改进来的值夹回那一项的范围。
    public subscript(item: Item) -> Double {
        get { percents[item] ?? item.defaultPercent }
        set { percents[item] = item.clamped(newValue) }
    }

    /// 拿 `overrides` 里有的项盖掉自己的(设置页拖滑杆途中的草稿)。
    public func overriding(_ overrides: [Item: Double]) -> LyricsWindowListTuning {
        var next = self
        for (item, value) in overrides { next[item] = value }
        return next
    }

    public var isStandard: Bool { self == .standard }

    // MARK: - 排版

    /// 行内各块(正文、读音、译文)之间原本的间距,同 `LyricsLayerRowStyle.blockSpacing`。
    public static let blockSpacing: CGFloat = 6
    /// 译文上方原本多留的距离(正文字号的倍数,07 章决策 87)。
    public static let translationExtraGap: CGFloat = 0.12
    /// 行间距原本是 0.98 倍字号(07 章决策 87 前后的 AM 对拍)。
    public static let baseLineSpacingEm: CGFloat = 0.98

    /// 正文字号:自动算出的字号(`LyricsWindowTypography.listFontSize`,含下限 22)整体乘缩放倍数。
    public func fontSize(auto: CGFloat) -> CGFloat {
        auto * CGFloat(self[.fontScale] / 100)
    }

    /// 整行读音的字号,`fontSize` 是正文字号。逐词读音同一个字号。
    public func romanizationFontSize(_ fontSize: CGFloat) -> CGFloat {
        fontSize * CGFloat(self[.romanizationSize] / 100)
    }

    public func translationFontSize(_ fontSize: CGFloat) -> CGFloat {
        fontSize * CGFloat(self[.translationSize] / 100)
    }

    /// 行间距比默认多出几倍字号(可以是负的)。换句错开按它修正行高(`LyricsLineStagger`)。
    public var extraLineSpacingEm: CGFloat { CGFloat(self[.lineSpacing] / 100) }

    /// 相邻两句之间的距离。
    public func lineSpacing(_ fontSize: CGFloat) -> CGFloat {
        fontSize * (Self.baseLineSpacingEm + extraLineSpacingEm)
    }

    /// 整行读音顶上离正文多远;不小于 0。
    public func romanizationGap(_ fontSize: CGFloat) -> CGFloat {
        max(0, Self.blockSpacing + fontSize * CGFloat(self[.romanizationGap] / 100))
    }

    /// 逐词读音原本紧贴正文,按读音间距比默认多出的那一截挪(可以是负的);整行读音挪同样的量。
    public func perWordRomanizationOffset(_ fontSize: CGFloat) -> CGFloat {
        fontSize * CGFloat(self[.romanizationGap] / 100)
    }

    /// 译文顶上离上一块(正文或读音)多远;不小于 0。
    public func translationGap(_ fontSize: CGFloat) -> CGFloat {
        max(0, Self.blockSpacing + fontSize * (Self.translationExtraGap + CGFloat(self[.translationGap] / 100)))
    }

    // MARK: - 景深

    /// 景深三项,交给 `LyricsWindowDepth`。
    public var depth: LyricsWindowDepth.Tuning {
        LyricsWindowDepth.Tuning(upcomingDim: self[.upcomingDim] / 100, pastDim: self[.pastDim] / 100,
                                 blur: self[.blur] / 100)
    }

    /// 只看排版那几项(改了要重建列表);景深三项归默认。
    public var layoutOnly: LyricsWindowListTuning {
        var t = self
        for item in Item.allCases where !item.rebuildsList { t[item] = item.defaultPercent }
        return t
    }
}

/// 图层版歌词列表(`LyricsLayerListView.apply`)这一拍要不要重排各行的位置。换歌、改字号 / 副行大小 / 行内间距时整张重建,
/// 建好之后整体重排,不经这里;行间距不进重建,只改各行之间的距离,要在这里认出来,不然暂停时拖「行间距」滑杆列表不动。
public enum LyricsListRelayout: Equatable, Sendable {
    case none
    /// 滚动锚或间奏变了:按换句 / 整页那几种过渡滚过去(各行位置一并按此刻的行间距重算)。
    case anchor
    /// 只有行间距变了:当场重算各行位置、无动画滚回锚点。
    case geometry

    /// 判断要用的那几样。
    public struct Inputs: Equatable, Sendable {
        public var scrollLineIndex: Int?
        public var currentGapIndex: Int?
        public var lineSpacing: CGFloat

        public init(scrollLineIndex: Int?, currentGapIndex: Int?, lineSpacing: CGFloat) {
            self.scrollLineIndex = scrollLineIndex
            self.currentGapIndex = currentGapIndex
            self.lineSpacing = lineSpacing
        }
    }

    /// 上一拍 `previous`(还没有时 nil)到这一拍 `next` 该怎么重排。
    public static func between(previous: Inputs?, next: Inputs) -> LyricsListRelayout {
        guard let previous else { return .none }
        if previous.scrollLineIndex != next.scrollLineIndex || previous.currentGapIndex != next.currentGapIndex {
            return .anchor
        }
        return previous.lineSpacing != next.lineSpacing ? .geometry : .none
    }
}
