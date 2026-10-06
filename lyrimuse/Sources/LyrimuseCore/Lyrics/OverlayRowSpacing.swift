import CoreGraphics

/// 悬浮歌词卡片里主行下面几行各自离上一行多远:读音 / 译文 / 下一句各一项(「排版」浮层那三根滑杆,单位 pt)。
///
/// 每一项管的是**那一行顶上**的间距,那一行不显示时它也不占地方。前奏 / 间奏时卡片里是「•••」→ 下一句 →
/// 它的读音 → 它的译文,各行照样用各自那一项。
///
/// 读音有两种形态,一项设置管两种:整行读音是卡片里单独一行,间距就是设置值;逐词读音画在主行同一张位图里,
/// 原本紧贴主行,按设置值比默认值多出的那一截挪(`perWordReadingGap`)。默认值下两种排版都跟没有这项设置时一样。
/// 见 04 章决策 48。
public enum OverlayRowSpacing {
    /// 三项的默认值,也是卡片里各行原来的间距。
    public static let defaultValue: Double = 4
    /// 译文、下一句的可调范围。可以是负的:行框在字的上下各自带一截空白,设成 0 两行字之间看上去仍隔着不少。
    public static let range: ClosedRange<Double> = -8...20
    /// 读音的可调范围。下限比另外两项高:逐词读音再往上挪,会压到主行字底下的描边。
    public static let romanizationRange: ClosedRange<Double> = -4...20

    /// 存着的值夹回范围;不是有限数时按默认值。
    public static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 逐词读音跟主行之间多出来的距离(可以是负的):读音那一项比默认值多多少。整行读音那一行顶上的间距
    /// 正好也挪这么多,两种形态跟着同一个设置走同样的量。
    public static func perWordReadingGap(_ romanizationSpacing: Double) -> CGFloat {
        CGFloat(clamped(romanizationSpacing, to: romanizationRange) - defaultValue)
    }

    /// 三项里的哪一项。
    public enum Item: Hashable, Sendable {
        case romanization, translation, nextLine

        /// 这一项的可调范围。
        public var range: ClosedRange<Double> {
            self == .romanization ? OverlayRowSpacing.romanizationRange : OverlayRowSpacing.range
        }
    }

    /// 三项一组,每一项都已夹回自己的范围。
    public struct Values: Equatable, Sendable {
        public private(set) var romanization: Double
        public private(set) var translation: Double
        public private(set) var nextLine: Double

        public init(romanization: Double, translation: Double, nextLine: Double) {
            self.romanization = OverlayRowSpacing.clamped(romanization, to: Item.romanization.range)
            self.translation = OverlayRowSpacing.clamped(translation, to: Item.translation.range)
            self.nextLine = OverlayRowSpacing.clamped(nextLine, to: Item.nextLine.range)
        }

        /// 三项都是默认值。
        public static let standard = Values(
            romanization: OverlayRowSpacing.defaultValue, translation: OverlayRowSpacing.defaultValue,
            nextLine: OverlayRowSpacing.defaultValue)

        /// 按项取值 / 改值;改进来的值同样夹回那一项的范围。
        public subscript(item: Item) -> Double {
            get {
                switch item {
                case .romanization: return romanization
                case .translation: return translation
                case .nextLine: return nextLine
                }
            }
            set {
                let value = OverlayRowSpacing.clamped(newValue, to: item.range)
                switch item {
                case .romanization: romanization = value
                case .translation: translation = value
                case .nextLine: nextLine = value
                }
            }
        }

        /// 逐词读音跟主行之间多出来的距离,见 `OverlayRowSpacing.perWordReadingGap`。
        public var perWordReadingGap: CGFloat { OverlayRowSpacing.perWordReadingGap(romanization) }
    }
}
