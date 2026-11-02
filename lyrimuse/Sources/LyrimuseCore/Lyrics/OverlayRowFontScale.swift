import Foundation

/// 悬浮歌词卡片里读音 / 译文 / 下一句的字号,按主句字号的比例(「字体」那一组「副行」三根滑杆)。
///
/// 存比例不存点数:主句字号变了(滑杆、快捷键放大缩小)三行按同一比例跟着变。上限 1:副行不比主句大。
/// 对唱里换到另一侧声部的下一句照旧按主句字号画,不吃这一项。见 04 章决策 81。
public enum OverlayRowFontScale {
    /// 三项共用的可调范围。
    public static let range: ClosedRange<Double> = 0.4...1
    /// 滑杆每一格。
    public static let step: Double = 0.05

    /// 三项里的哪一项。
    public enum Item: Hashable, Sendable, CaseIterable {
        case romanization, translation, nextLine

        /// 默认比例,也是加这项设置前写死的比例。
        public var defaultValue: Double {
            self == .romanization ? 0.65 : 0.7
        }
    }

    /// 存着的值夹回范围;不是有限数时按那一项的默认值。
    public static func clamped(_ value: Double, item: Item) -> Double {
        guard value.isFinite else { return item.defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 读数:占主句字号的百分比(「65%」)。
    public static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// 三项一组,每一项都已夹回范围。
    public struct Values: Equatable, Sendable {
        public private(set) var romanization: Double
        public private(set) var translation: Double
        public private(set) var nextLine: Double

        public init(romanization: Double, translation: Double, nextLine: Double) {
            self.romanization = OverlayRowFontScale.clamped(romanization, item: .romanization)
            self.translation = OverlayRowFontScale.clamped(translation, item: .translation)
            self.nextLine = OverlayRowFontScale.clamped(nextLine, item: .nextLine)
        }

        /// 三项都是默认值。
        public static let standard = Values(
            romanization: Item.romanization.defaultValue, translation: Item.translation.defaultValue,
            nextLine: Item.nextLine.defaultValue)

        /// 按项取值。
        public subscript(item: Item) -> Double {
            switch item {
            case .romanization: return romanization
            case .translation: return translation
            case .nextLine: return nextLine
            }
        }
    }
}
