import CoreGraphics

/// 灵动岛「收起时显示歌词」三档:顶行下面的歌词行 / 顶行两只耳朵之间 / 不显示。
///
/// 存成两个设置:`np:notchShowLyrics`(开关)+ `np:notchLyricsInTopRow`(开着时放在哪),同「进度线」那三档的存法。
/// 开关关着时不看第二个,所以旧配置不用改写:旧值开 = 歌词行、关 = 不显示。见 05 章决策 158。
public enum NotchLyricsPlacement: String, CaseIterable, Sendable {
    case belowRow
    case topRow
    case hidden

    public init(showsLyrics: Bool, inTopRow: Bool) {
        self = showsLyrics ? (inTopRow ? .topRow : .belowRow) : .hidden
    }

    /// 存回两个设置的值。`inTopRow` 为 nil 时不改那个设置:选「不显示」保留上次放在哪,快捷操作里再打开时回到原处。
    public var storage: (showsLyrics: Bool, inTopRow: Bool?) {
        switch self {
        case .belowRow: return (true, false)
        case .topRow: return (true, true)
        case .hidden: return (false, nil)
        }
    }

    /// 这块屏上实际怎么画。有刘海的屏顶行中间是硬件,选「顶行」时按不显示画;有一只耳朵放着当前句时(`currentLineInEar`)
    /// 歌词行和顶行都不再画当前句,一律按不显示。见 05 章决策 158、159。
    public func presentation(hasNotch: Bool, currentLineInEar: Bool) -> NotchLyricsPlacement {
        currentLineInEar || (self == .topRow && hasNotch) ? .hidden : self
    }
}

/// 一行歌词画哪一句。顶行歌词画当前句;单行歌词视图(`NotchLyricsView.singleLyricLine`)两种都能画,给定宽度由调用方定。
/// 耳朵模块「当前句」「下一句」也用它。
public enum NotchLyricLineKind: String, CaseIterable, Sendable {
    case current
    case next
}

/// 顶行歌词的几何:没有刘海的屏上,两只耳朵收到刚好放得下各自模块的宽度,中间那段给当前句。
///
/// 卡片高度不变(就是菜单栏高),宽度沿用稳态宽设置、不随句子变,不按菜单栏两侧已占的位置收窄(盖住的菜单和状态栏图标点不到);
/// 稳态宽太窄时抬到放得下 `minimumLyricWidth`。见 05 章决策 158、162。
public enum NotchTopRowLyrics {
    /// 中间那段至少这么宽才画,同菜单栏正中歌词的 `MenuBarCenterLayout.minimumSpan`。
    public static let minimumLyricWidth: CGFloat = MenuBarCenterLayout.minimumSpan
    /// 耳朵配了歌名 / 歌手 / 专辑时这只耳朵给这么宽:平时它们按 0 算下限、靠跑马灯兜底,顶行歌词把耳朵收到下限时会只剩音浪。
    public static let textEarWidth: CGFloat = 64

    public struct Fit: Equatable, Sendable {
        /// 稳态卡片的宽度。
        public let cardWidth: CGFloat
        /// 中间给歌词的那段宽度。
        public let lyricWidth: CGFloat
        public init(cardWidth: CGFloat, lyricWidth: CGFloat) {
            self.cardWidth = cardWidth
            self.lyricWidth = lyricWidth
        }
    }

    /// 卡片至少多宽才放得下:两只耳朵 + 两侧内边距 + 最窄的歌词段。
    public static func minimumCardWidth(earWidth: CGFloat, cardPadding: CGFloat) -> CGFloat {
        2 * earWidth + 2 * cardPadding + minimumLyricWidth
    }

    /// 稳态宽 `steadyWidth`(已过耳朵下限)抬到放得下最窄一段歌词之后的卡片宽和歌词段宽。
    public static func fit(steadyWidth: CGFloat, earWidth: CGFloat, cardPadding: CGFloat) -> Fit {
        let width = max(steadyWidth, minimumCardWidth(earWidth: earWidth, cardPadding: cardPadding))
        return Fit(cardWidth: width, lyricWidth: width - 2 * cardPadding - 2 * earWidth)
    }

    /// 关掉「两耳等宽」时一侧至少伸出中线多少:一只耳朵 + 内边距 + 最窄歌词段的一半。两只耳朵仍等宽(`earWidth`),
    /// 歌词段在卡片正中。
    public static func minimumSideWidth(earWidth: CGFloat, cardPadding: CGFloat) -> CGFloat {
        earWidth + cardPadding + minimumLyricWidth / 2
    }

    /// 关掉「两耳等宽」时的顶行歌词:两侧外露宽(从中线量)各抬到 `minimumSideWidth`。见 05 章决策 160。
    public static func fit(span: NotchEarSpan, earWidth: CGFloat, cardPadding: CGFloat) -> (span: NotchEarSpan, lyricWidth: CGFloat) {
        let floor = minimumSideWidth(earWidth: earWidth, cardPadding: cardPadding)
        let left = max(span.left, floor), right = max(span.right, floor)
        return (NotchEarSpan(left: left, right: right), left + right - 2 * cardPadding - 2 * earWidth)
    }
}
