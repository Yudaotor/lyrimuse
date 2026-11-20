/// 耳朵里的歌词模块:「歌词」(`alternating`)/「当前句」/「下一句」。耳朵模块枚举在 App 里,这里只放判据。
public enum NotchEarLyricModule: Sendable {
    case alternating
    case current
    case next
}

/// 两只耳朵各画哪一句。见 05 章决策 163。
///
/// 两耳都选「歌词」时按句子序号(这一面断好的段,从 0 起)分左右:偶数句在左耳、奇数句在右耳。正在唱(或已亮出、等着唱)的那句
/// 所在的耳朵画当前句,另一只画它后面那句;换句只是两只耳朵对调「当前 / 下一句」,每句从亮出到唱完都在同一只耳朵里。
/// 只有一只耳朵选「歌词」时它补另一只没画的那句:另一只是「当前句」就画下一句,否则画当前句。
public enum NotchEarLyricLines {
    /// 两耳都选「歌词」时当前句在不在左耳。
    ///
    /// 序号先认主行显示的那句(`shownIndex`);没有(前奏、长间奏的占位)时认最近开唱的那句(`lineIndex`),这时当前句那只耳朵画
    /// 占位,另一只是接下来那句,仍落在它自己的序号那侧。整首没有歌词(两者都没有、也没有下一句)时当前句放左耳。
    public static func currentOnLeft(shownIndex: Int?, lineIndex: Int?, hasFollowingLine: Bool) -> Bool {
        let base = shownIndex ?? lineIndex ?? (hasFollowingLine ? -1 : 0)
        return base >= 0 && base % 2 == 0
    }

    /// 灵动岛那一面此刻的歌词(`LyricsSyncEngine.SurfaceLyrics`)按副行那一档取主行显示的那句:副行开着认正在唱的那段
    /// (`showsCurrentLine` 为 false 时是够格的间奏,当作没有),关着认提前亮出的那句(`compactLineIndex`),同 `displayedLine`。
    public static func currentOnLeft(_ lyrics: LyricsSyncEngine.SurfaceLyrics, secondary: LyricSecondaryLine,
                                     showsCurrentLine: Bool) -> Bool {
        let shown = secondary.showsSecondaryRow ? (showsCurrentLine ? lyrics.lineIndex : nil) : lyrics.compactLineIndex
        let following = secondary.expandedNextLine(next: lyrics.nextText, afterCompact: lyrics.compactNextText)
        return currentOnLeft(shownIndex: shown, lineIndex: lyrics.lineIndex, hasFollowingLine: following != nil)
    }

    /// 左右耳各画哪一句;不是歌词模块的那只耳朵为 nil。
    public static func resolve(left: NotchEarLyricModule?, right: NotchEarLyricModule?,
                               currentOnLeft: Bool) -> (left: NotchLyricLineKind?, right: NotchLyricLineKind?) {
        func fixed(_ module: NotchEarLyricModule?) -> NotchLyricLineKind? {
            switch module {
            case .current: return .current
            case .next: return .next
            case .alternating, nil: return nil
            }
        }
        switch (left, right) {
        case (.alternating, .alternating):
            return currentOnLeft ? (.current, .next) : (.next, .current)
        case (.alternating, let other):
            return (other == .current ? .next : .current, fixed(other))
        case (let other, .alternating):
            return (fixed(other), other == .current ? .next : .current)
        default:
            return (fixed(left), fixed(right))
        }
    }

    /// 两耳都是「歌词」:轮流画,两份常驻切换。
    public static func alternates(left: NotchEarLyricModule?, right: NotchEarLyricModule?) -> Bool {
        left == .alternating && right == .alternating
    }

    /// 有没有一只耳朵在画当前句(两耳轮流时总有一只在画):有的话下面的歌词行、顶行歌词不再画当前句。
    public static func showsCurrentLine(left: NotchEarLyricModule?, right: NotchEarLyricModule?) -> Bool {
        let lines = resolve(left: left, right: right, currentOnLeft: true)
        return lines.left == .current || lines.right == .current
    }
}
