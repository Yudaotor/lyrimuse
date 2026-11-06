/// 悬浮歌词开着「下一句」时,下一句怎么排。
///
/// - `below`(默认):当前句在上,下一句缩小跟在下面;换句时下一句顶到上面。
/// - `alternate`:两句同字号,上一行靠左、下一行靠右;当前句按它在歌里的下标轮流占上下两行,唱完的那一行原地换成
///   再下一句,正在唱的那一行不动。不显示译文和整行读音(各行带一份会让窗口变成四行,只带当前句的又会让下一行跟着上下跳)。
///   对唱、前奏 / 间奏、没有下一句时照 `below` 排。见 04 章决策 89。
public enum OverlayNextLineArrangement: String, Codable, Hashable, CaseIterable, Sendable, Identifiable {
    case below
    case alternate

    public var id: Self { self }

    /// 交替排法这一刻的摆法。
    public struct AlternatePlacement: Equatable, Sendable {
        /// 当前句在上一行。
        public let currentOnTop: Bool

        public init(currentOnTop: Bool) {
            self.currentOnTop = currentOnTop
        }

        /// 当前句贴的那一边:上一行靠左、下一行靠右。
        public var currentSide: LyricDuet.Side { currentOnTop ? .leading : .trailing }
        /// 下一句贴的那一边。
        public var nextSide: LyricDuet.Side { currentOnTop ? .trailing : .leading }
    }

    /// 这一刻按交替排法怎么摆;nil = 照 `below` 排。
    ///
    /// `currentSide` / `nextSide` 是两句的真实声部(「对齐方式」不是「自动」时调用方传 nil:用户已经不按声部分左右了)。
    /// 任一句有声部就是对唱,左右已经用来分演唱者,不交替。
    public static func alternatePlacement(
        arrangement: OverlayNextLineArrangement, showsNextLine: Bool, lineIndex: Int?,
        hasLine: Bool, hasNextLine: Bool, currentSide: LyricDuet.Side?, nextSide: LyricDuet.Side?
    ) -> AlternatePlacement? {
        guard arrangement == .alternate, showsNextLine, hasLine, hasNextLine,
              let lineIndex, lineIndex >= 0, currentSide == nil, nextSide == nil
        else { return nil }
        return AlternatePlacement(currentOnTop: lineIndex % 2 == 0)
    }
}
