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

    /// 这块屏上实际怎么画。有刘海的屏顶行中间是硬件,选「顶行」时按不显示画。
    public func presentation(hasNotch: Bool) -> NotchLyricsPlacement {
        self == .topRow && hasNotch ? .hidden : self
    }
}

/// 一行歌词画哪一句。顶行歌词画当前句;单行歌词视图(`NotchLyricsView.singleLyricLine`)两种都能画,给定宽度由调用方定。
public enum NotchLyricLineKind: String, CaseIterable, Sendable {
    case current
    case next
}

/// 顶行歌词的几何:没有刘海的屏上,两只耳朵收到刚好放得下各自模块的宽度,中间那段给当前句。
///
/// 卡片高度不变(就是菜单栏高),宽度沿用稳态宽设置、不随句子变;上限按菜单栏两侧已占的位置夹(`maxCardWidth`),
/// 卡片在 `.screenSaver` 层且接点击,宽过去会挡住菜单和状态栏图标。放不下 `minimumLyricWidth` 时这一档不画。见 05 章决策 158。
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

    /// 稳态宽 `steadyWidth`(已过耳朵下限)按上限 `maxCardWidth` 夹过之后的卡片宽和歌词段宽;nil = 放不下,这一档不画。
    /// `maxCardWidth` 为 nil 时不夹(没有菜单栏读数可用,比如编辑台预览)。
    public static func fit(steadyWidth: CGFloat, earWidth: CGFloat, cardPadding: CGFloat, maxCardWidth: CGFloat?) -> Fit? {
        let floor = minimumCardWidth(earWidth: earWidth, cardPadding: cardPadding)
        var width = max(steadyWidth, floor)
        if let maxCardWidth {
            guard maxCardWidth >= floor else { return nil }
            width = min(width, maxCardWidth)
        }
        return Fit(cardWidth: width, lyricWidth: width - 2 * cardPadding - 2 * earWidth)
    }

    /// 以 `centerX` 居中的卡片最宽多少才不压到菜单栏两侧已占的位置:`span` 是 `MenuBarCenterLayout.usableSpan` 给的那一段
    /// (已经各让开 `clearance`)。中线落在 `span` 外、或 `span` 为 nil(两侧挤得放不下)时是 0。
    public static func maxCardWidth(centerX: CGFloat, span: ClosedRange<CGFloat>?) -> CGFloat {
        guard let span else { return 0 }
        return max(0, 2 * min(centerX - span.lowerBound, span.upperBound - centerX))
    }
}
