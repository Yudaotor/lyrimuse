/// 悬浮歌词开着「下一句」时,下一句怎么排。
///
/// - `below`(默认):当前句在上,下一句缩小跟在下面;换句时下一句顶到上面。
/// - `alternate`:两句同字号,上一行靠左、下一行靠右;当前句按它在歌里的下标轮流占上下两行,唱完的那一行原地换成
///   再下一句,正在唱的那一行不动。不显示译文和整行读音(各行带一份会让窗口变成四行,只带当前句的又会让下一行跟着上下跳)。
///   前奏 / 间奏、没有下一句时照 `below` 排。见 04 章决策 89。
///   对唱也交替:左右用来分上下两行,不再按演唱者分(见 `effectiveAlignment`,04 章决策 96)。
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
    public static func alternatePlacement(
        arrangement: OverlayNextLineArrangement, showsNextLine: Bool, lineIndex: Int?,
        hasLine: Bool, hasNextLine: Bool
    ) -> AlternatePlacement? {
        guard arrangement == .alternate, showsNextLine, hasLine, hasNextLine,
              let lineIndex, lineIndex >= 0
        else { return nil }
        return AlternatePlacement(currentOnTop: lineIndex % 2 == 0)
    }

    /// 悬浮歌词实际按哪种「对齐方式」排。交错开着(且显示下一句)时「自动」当「居中」:整首都不按声部分左右、
    /// 不留对唱缩进,前奏、最后一句照 `below` 排的那几刻也一样,块不会在两种摆法之间横跳。
    /// 选了左 / 居中 / 右照用户选的。
    public static func effectiveAlignment(
        _ alignment: OverlayDuetAlignmentOverride, arrangement: OverlayNextLineArrangement, showsNextLine: Bool
    ) -> OverlayDuetAlignmentOverride {
        guard alignment == .automatic, arrangement == .alternate, showsNextLine else { return alignment }
        return .center
    }
}
