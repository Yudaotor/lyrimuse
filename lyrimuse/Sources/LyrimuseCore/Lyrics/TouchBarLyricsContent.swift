import Foundation

/// 触控栏歌词那一格此刻显示什么。判据只此一份:`TouchBarLyricsController` 照着摆,selftest 钉着。
///
/// 取单行展示面那一份(`compactLine` / `compactShowsPlaceholder`,提前亮出下一句的规则见 `CompactLyricLead`),
/// 不按宽度断句:这一格比菜单栏宽得多,放不下的整句交给图层滚动。副行开着时主行改取正在唱的那一句,见
/// `resolve(secondary:…)`。
///
/// 跟菜单栏(`MenuBarSlotPolicy.displayText`)的两处不同:暂停时照样显示;歌名前不加 ♪(左边挨着封面)。
/// 取舍见 17 章。
public enum TouchBarLyricsContent: Equatable {
    /// 一句歌词。带逐字时间轴时逐字填色、跟着唱到的字滚动;没有时整行一个颜色,按显示时长配速滚动。
    case lyric(SyncedLyricLine)
    /// 有词,此刻在前奏 / 间奏里,离下一句还早。
    case interlude
    /// 这首没歌词或还在找:歌名和歌手,按 `trackSeparator` 连起来(缺一个就只显示另一个)。
    case track(String)
    /// 广告插播。广告自己的标题不显示。
    case adBreak
    /// 没有曲目。
    case idle

    /// 歌名和歌手之间的分隔。
    public static let trackSeparator = " — "

    /// 是不是歌词句。只有歌词句的滚动跟着歌词时间轴走;歌名、广告、间奏没有时间轴可对,
    /// 滚动起点由展示的那一方自己定(触控栏:看得见的那一刻)。
    public var isLyric: Bool {
        if case .lyric = self { return true }
        return false
    }

    /// 优先级:广告 > 歌词句 > 间奏 > 歌名 > 空。只有空白字符的行不算歌词句。
    public static func resolve(
        compactLine: SyncedLyricLine?, showsPlaceholder: Bool,
        title: String, artist: String, isAdBreak: Bool
    ) -> TouchBarLyricsContent {
        if isAdBreak { return .adBreak }
        if let line = compactLine, let text = line.plainText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .lyric(line)
        }
        if showsPlaceholder { return .interlude }
        let parts = [title, artist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? .idle : .track(parts.joined(separator: trackSeparator))
    }

    /// 带「副行」设置的版本;副行关着时同上一个 `resolve`。
    ///
    /// 副行开着时主行认**正在唱的那一句**(`currentLine`),不再提前亮出下一句 —— 同灵动岛 / 菜单栏
    /// (`LyricSecondaryLine.displayedLine`):副行的译文 / 读音是这一句的、「下一句」是这一句的下一句,主行抢跑的话
    /// 提前量那几秒里两行对不上号。够格的间奏(`inMarkedInterlude`)里当作没有当前句、显示间奏占位
    /// (`LyricSecondaryLine.currentLine(_:inMarkedInterlude:)`),不够格的句间空档照旧留着上一句;前奏里还没有
    /// 当前句,同单行时一样显示歌名。
    public static func resolve(
        secondary: LyricSecondaryLine,
        compactLine: SyncedLyricLine?, showsPlaceholder: Bool,
        currentLine: SyncedLyricLine?, inMarkedInterlude: Bool,
        title: String, artist: String, isAdBreak: Bool
    ) -> TouchBarLyricsContent {
        guard secondary.showsSecondaryRow else {
            return resolve(compactLine: compactLine, showsPlaceholder: showsPlaceholder,
                           title: title, artist: artist, isAdBreak: isAdBreak)
        }
        let shown = LyricSecondaryLine.currentLine(currentLine, inMarkedInterlude: inMarkedInterlude)
        return resolve(compactLine: secondary.displayedLine(compactLine: compactLine, currentLine: shown),
                       showsPlaceholder: currentLine != nil && inMarkedInterlude,
                       title: title, artist: artist, isAdBreak: isAdBreak)
    }

    /// 副行那一行的字;nil = 这一刻没有(那一行留空,主行不挪位置)。取值同灵动岛 / 菜单栏
    /// (`LyricSecondaryLine.secondaryText`),当前句就是主行那一句;间奏、前奏、没歌词时没有当前句,只有「下一句」
    /// 可能有字。广告、没曲目时没有。副行关着时恒为 nil。
    public func secondaryText(_ secondary: LyricSecondaryLine, nextLineText: String?) -> String? {
        switch self {
        case .adBreak, .idle: return nil
        case .lyric(let line): return secondary.secondaryText(currentLine: line, nextLineText: nextLineText)
        case .interlude, .track: return secondary.secondaryText(currentLine: nil, nextLineText: nextLineText)
        }
    }
}

/// 这一档从歌词时间轴上哪一毫秒起显示。没有逐字时间轴的整行、歌名这些从这一刻起按显示时长配速滚动
/// (`OverlayScrollingLyricRow.PacedWindow`)。触控栏本体和设置页那块预览各记一份。
public struct TouchBarDisplayStart: Equatable {
    public private(set) var content: TouchBarLyricsContent?
    public private(set) var lineIndex: Int?
    public private(set) var sinceMs = 0

    public init() {}

    /// 换了一档、或者行下标变了(连着两句同样的词也各从头滚),从此刻算起;往回拖进度、拖到起点之前时,
    /// 起点跟着挪到此刻(不然要干等到原来那一刻才开始滚)。
    public mutating func update(content: TouchBarLyricsContent, lineIndex: Int?, nowMs: Int) {
        if content != self.content || lineIndex != self.lineIndex {
            self.content = content
            self.lineIndex = lineIndex
            sinceMs = nowMs
        } else if nowMs < sinceMs {
            sinceMs = nowMs
        }
    }

    /// 歌名、广告、间奏只滚一轮,看不见的时候可能早就滚完了:变成看得见的那一刻从此刻重新起滚。
    /// 歌词句不动,它按歌词时间轴算,什么时候看都对得上。
    public mutating func restartIfNotLyric(nowMs: Int) {
        if content?.isLyric == false { sinceMs = nowMs }
    }
}
