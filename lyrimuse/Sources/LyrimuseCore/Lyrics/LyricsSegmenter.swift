import CoreGraphics
import Foundation

/// 一个展示面给断句用的宽度预算:这个面每一行最多多宽、按它的字体量一段文字多宽。`key` 描述宽度、字体和
/// 显示哪几行,相同就不重新断句(量宽函数本身没法比较)。
///
/// 宽度都是**文字本身**能占的宽:描边预留、演唱者标记之外的固定留白由调用方先扣掉。
public struct LineLayoutBudget {
    public struct Row {
        public let maxWidth: CGFloat
        public let measure: (String) -> CGFloat

        public init(maxWidth: CGFloat, measure: @escaping (String) -> CGFloat) {
            self.maxWidth = maxWidth
            self.measure = measure
        }
    }

    /// 逐词读音(读音标在每个词底下):一组的宽 = 词宽与「读音宽 + 两侧留白」的较大者。
    public struct WordRomanization {
        public let measure: (String) -> CGFloat
        public let sidePadding: CGFloat

        public init(measure: @escaping (String) -> CGFloat, sidePadding: CGFloat) {
            self.measure = measure
            self.sidePadding = sidePadding
        }
    }

    public let key: AnyHashable
    /// 主行。
    public let main: Row
    /// 带对唱声部(左 / 右)的行,每一行都再少这么多(演唱者标记)。
    public let sidedInset: CGFloat
    /// 这一段排成「下一句」时那一行;nil = 这个面不显示下一句。
    public let preview: Row?
    /// 译文那一行;nil = 不显示。
    public let translation: Row?
    /// 整行罗马音那一行;nil = 不显示。有逐词读音的行不量它(那时整行罗马音不出现)。
    public let romanization: Row?
    /// 逐词读音;nil = 这个面不画逐词读音。
    public let wordRomanization: WordRomanization?

    public init(key: AnyHashable, main: Row, sidedInset: CGFloat = 0, preview: Row? = nil,
                translation: Row? = nil, romanization: Row? = nil,
                wordRomanization: WordRomanization? = nil) {
        self.key = key
        self.main = main
        self.sidedInset = sidedInset
        self.preview = preview
        self.translation = translation
        self.romanization = romanization
        self.wordRomanization = wordRomanization
    }

    public init(key: AnyHashable, maxWidth: CGFloat, measure: @escaping (String) -> CGFloat) {
        self.init(key: key, main: Row(maxWidth: maxWidth, measure: measure))
    }

    /// 同一份预算,量宽函数套上缓存:断一首歌时同一个词、同一句要量很多遍。缓存只活在这一份副本里。
    public func memoized() -> LineLayoutBudget {
        func cached(_ f: @escaping (String) -> CGFloat) -> (String) -> CGFloat {
            final class Box { var values: [String: CGFloat] = [:] }
            let box = Box()
            return { text in
                if let v = box.values[text] { return v }
                let v = f(text)
                box.values[text] = v
                return v
            }
        }
        func cachedRow(_ r: Row?) -> Row? { r.map { Row(maxWidth: $0.maxWidth, measure: cached($0.measure)) } }
        return LineLayoutBudget(
            key: key, main: Row(maxWidth: main.maxWidth, measure: cached(main.measure)), sidedInset: sidedInset,
            preview: cachedRow(preview), translation: cachedRow(translation), romanization: cachedRow(romanization),
            wordRomanization: wordRomanization.map { WordRomanization(measure: cached($0.measure), sidePadding: $0.sidePadding) })
    }
}

/// 单行展示面按宽度断句的两件事,各自一个开关。都关着时每一行原样一段。
public struct LineBreakOptions: Equatable, Hashable, Sendable {
    /// 放不下一行的句子拆开。开着时各面的每一行都放得下,不折行、不滚动。
    public var splitsLongLines: Bool
    /// 连续几句很短的并成一句,合完放得下一行才并。
    public var mergesShortLines: Bool

    public init(splitsLongLines: Bool = false, mergesShortLines: Bool = false) {
        self.splitsLongLines = splitsLongLines
        self.mergesShortLines = mergesShortLines
    }

    public static let off = LineBreakOptions()
    public static let all = LineBreakOptions(splitsLongLines: true, mergesShortLines: true)
    public var isActive: Bool { splitsLongLines || mergesShortLines }
}

/// 单行展示面按宽度重新断句:放不下一行的句子拆成几段,连续几句很短的并成一句,保证主行、译文、罗马音、
/// 下一句预览每一行都放得下(只要一个字放得下)。纯函数,引擎(LyricsSyncEngine)按每个展示面的预算各算
/// 一份。规则与取舍见 08 章决策 25、30。
public enum LyricsSegmenter {
    public struct Line {
        public let startMs: Int
        /// 下一行开始的时刻;最后一行为 nil。只有逐行时间的句子拆开时,按它估每段几点开唱。
        public let nextStartMs: Int?
        public let text: String
        /// 逐字词;nil = 只有逐行时间。
        public let words: [SyncedLyricWord]?
        /// 逐词读音的分组(只在这个面画逐词读音时给)。依次覆盖 `words` 时拆开不在组中间断。
        public let groups: [SyncedLyricWordGroup]?
        /// 一段词(拆出来的一段、合成的一句)显示时怎么分组:必须跟引擎给那一段算逐词读音的是同一个函数,
        /// 量出来的宽才是画出来的宽。nil = 这个面不画逐词读音。
        public let groupsFor: (([SyncedLyricWord], String) -> [SyncedLyricWordGroup]?)?
        /// 这一句的译文 / 整行罗马音(这个面显示那一行时才给)。
        public let translation: String?
        public let romanization: String?
        public let side: LyricDuet.Side?
        /// 唱完的时刻(逐字行含背景人声;逐行歌词是句末标记);没有是 nil。
        public let sungEndMs: Int?
        /// 跟下一行真重叠的行不参与合并(它在单行展示面上另有退化形态)。
        public let mergeable: Bool
        /// 这一行后面紧跟着一段间奏点,不跨过去合并。
        public let gapAfter: Bool

        public init(startMs: Int, nextStartMs: Int? = nil, text: String, words: [SyncedLyricWord]?,
                    groups: [SyncedLyricWordGroup]? = nil,
                    groupsFor: (([SyncedLyricWord], String) -> [SyncedLyricWordGroup]?)? = nil,
                    translation: String? = nil,
                    romanization: String? = nil, side: LyricDuet.Side?, sungEndMs: Int?,
                    mergeable: Bool, gapAfter: Bool) {
            self.startMs = startMs
            self.nextStartMs = nextStartMs
            self.text = text
            self.words = words
            self.groups = groups
            self.groupsFor = groupsFor
            self.translation = translation
            self.romanization = romanization
            self.side = side
            self.sungEndMs = sungEndMs
            self.mergeable = mergeable
            self.gapAfter = gapAfter
        }
    }

    /// 一句拆开后的一段。
    public struct Part: Equatable {
        public let index: Int
        public let count: Int
        public let startMs: Int
        /// 这一段的词。`estimated` 时是只有逐行时间的句子按宽度估出来的时刻,只用来定段的起点,不拿去填色。
        public let words: [SyncedLyricWord]
        public let estimated: Bool
        /// 逐词读音按组拆时,每组有几个词(依次覆盖 `words`)。
        public let groupSizes: [Int]?
        public let groupRomanizations: [String?]?
        /// 这一段自己的译文 / 罗马音;nil = 整句的那一行放得下,每段都显示整句的。
        public let translation: String?
        public let romanization: String?

        public init(index: Int, count: Int, startMs: Int, words: [SyncedLyricWord], estimated: Bool,
                    groupSizes: [Int]? = nil, groupRomanizations: [String?]? = nil,
                    translation: String? = nil, romanization: String? = nil) {
            self.index = index
            self.count = count
            self.startMs = startMs
            self.words = words
            self.estimated = estimated
            self.groupSizes = groupSizes
            self.groupRomanizations = groupRomanizations
            self.translation = translation
            self.romanization = romanization
        }

        public var text: String { words.map(\.text).joined() }
    }

    /// 一段显示单位:第 firstLine…lastLine 行并成的一句;`part` 非 nil 时是第 firstLine 行拆开后的一段。
    public struct Segment: Equatable {
        public let firstLine: Int
        public let lastLine: Int
        public let part: Part?

        public init(firstLine: Int, lastLine: Int, part: Part? = nil) {
            self.firstLine = firstLine
            self.lastLine = lastLine
            self.part = part
        }
    }

    /// 这一句停留不到这么久才考虑跟下一句合并。
    public static let mergeShortDwellMs = 2000
    /// 被并进来的下一句自己停留不超过这么久:长句不往短句上接。
    public static let mergeNextMaxDwellMs = 3500
    /// 「很短的一句」:停留不到 mergeShortDwellMs、而且不超过这么多字(displayWidth)。相邻两句里至少有一句是
    /// 这样的才合并,两句完整的句子只是唱得快,不往一起粘。
    public static let mergeTinyMaxWidth = 4
    /// 合完从第一句开始到最后一句唱完不超过这么久。
    public static let mergeMaxSpanMs = 5000
    /// 一句最多拆成几段。到这个数还放不下,说明一行窄得放不下几个字,不再往下拆。
    public static let maxParts = 12
    /// 只有逐行时间的句子,估时长时每个词(汉字一个字算一个)最多给这么久:句子后面拖着一段没标间奏的空白时,
    /// 后半句不至于被估到很晚才出来。
    public static let estimatedMaxMsPerToken = 600
    /// 量出来的宽度比上限多不到这么多也算放得下(浮点误差)。
    static let fitTolerance: CGFloat = 0.5

    /// 每一行原样一段:不重新断句时用。
    public static func identity(lineCount: Int) -> [Segment] {
        (0..<lineCount).map { Segment(firstLine: $0, lastLine: $0) }
    }

    /// 按需取第 k 行;k 越界返回 nil。
    public typealias LineProvider = (Int) -> Line?

    public static func segments(_ lines: [Line], budget original: LineLayoutBudget,
                                options: LineBreakOptions = .all) -> [Segment] {
        guard original.main.maxWidth > 0, options.isActive else { return identity(lineCount: lines.count) }
        let budget = original.memoized()
        let provider: LineProvider = { lines.indices.contains($0) ? lines[$0] : nil }
        var out: [Segment] = []
        var i = 0
        while i < lines.count {
            let segs = step(from: i, line: provider, budget: budget, options: options)
            out += segs
            i = (segs.last?.lastLine ?? i) + 1
        }
        return out
    }

    /// 从第 i 行断出下一组段:放不下的一句拆成的几段,或者从第 i 行起并成的一句(可能就是它自己)。只往后看
    /// 合并要看的那几行,所以从头一组一组往后断,断好的段不会因为后面的行变。`budget` 应先 `memoized()`。
    /// 不拆时放不下的句子原样一段(由各面自己折行或滚动);不并时每句一段。
    public static func step(from i: Int, line: LineProvider, budget: LineLayoutBudget,
                            options: LineBreakOptions = .all) -> [Segment] {
        guard let first = line(i) else { return [] }
        if !fits(line, i...i, budget: budget) {
            if options.splitsLongLines, let parts = split(first, budget: budget) {
                return parts.map { Segment(firstLine: i, lastLine: i, part: $0) }
            }
            return [Segment(firstLine: i, lastLine: i)]
        }
        guard options.mergesShortLines else { return [Segment(firstLine: i, lastLine: i)] }
        var j = i
        while canMerge(line, from: i, through: j, budget: budget) { j += 1 }
        return [Segment(firstLine: i, lastLine: j)]
    }

    // MARK: - 放不放得下

    private static func isSided(_ side: LyricDuet.Side?) -> Bool { side == .leading || side == .trailing }

    private static func limit(_ row: LineLayoutBudget.Row, side: LyricDuet.Side?, budget: LineLayoutBudget) -> CGFloat {
        row.maxWidth - (isSided(side) ? budget.sidedInset : 0)
    }

    /// 主行宽:逐词相加(图层行这样排)和整串量(菜单栏、行级歌词这样排)取较大者;逐词读音按组量(组宽 = 词宽
    /// 与读音宽 + 两侧留白的较大者)。断句判「放不放得下」和悬浮歌词算对唱留白(`LyricsOverlayView.cardNaturalWidth`)
    /// 用的是这同一个量法,两处不一致的话,留白会把贴满一行的句子末尾挤到下一行。
    public static func mainWidth(words: [SyncedLyricWord]?, groups: [SyncedLyricWordGroup]?, text: String,
                                 measure: (String) -> CGFloat,
                                 wordRomanization: LineLayoutBudget.WordRomanization?) -> CGFloat {
        let whole = measure(text)
        guard let words, !words.isEmpty else { return whole }
        if let groups, let wr = wordRomanization {
            let sum = groups.reduce(CGFloat(0)) { acc, g in
                let w = g.words.reduce(CGFloat(0)) { $0 + measure($1.text) }
                return acc + max(w, wr.measure(g.romanization ?? " ") + wr.sidePadding * 2)
            }
            return max(sum, whole)
        }
        return max(words.reduce(CGFloat(0)) { $0 + measure($1.text) }, whole)
    }

    private static func mainWidth(words: [SyncedLyricWord]?, groups: [SyncedLyricWordGroup]?, text: String,
                                  budget: LineLayoutBudget) -> CGFloat {
        mainWidth(words: words, groups: groups, text: text, measure: budget.main.measure,
                  wordRomanization: budget.wordRomanization)
    }

    static func joinedWords(_ lines: [Line]) -> [SyncedLyricWord]? {
        var out: [SyncedLyricWord] = []
        for k in lines.indices {
            guard var ws = lines[k].words else { return nil }
            if k < lines.count - 1, let tail = ws.last, tail.text.last?.isWhitespace != true {
                ws[ws.count - 1] = SyncedLyricWord(text: tail.text + " ", startMs: tail.startMs, durationMs: tail.durationMs)
            }
            out += ws
        }
        return out
    }

    static func joinedText(_ values: [String?]) -> String? {
        let parts = values.compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// 几行并成一句时的文字,跟引擎拼的一致:逐字句按词接(句间补的空格已在词里),行级句用空格连。
    static func mergedText(_ lines: [Line], words: [SyncedLyricWord]?) -> String {
        words.map { $0.map(\.text).joined() } ?? lines.map(\.text).joined(separator: " ")
    }

    /// 第 range 这几行并成一句(或就是一句)时,这个面上的每一行是不是都放得下。
    static func fits(_ line: LineProvider, _ range: ClosedRange<Int>, budget: LineLayoutBudget) -> Bool {
        let ls = range.compactMap(line)
        guard ls.count == range.count, let first = ls.first else { return false }
        let side = first.side
        let words = joinedWords(ls)
        let text = mergedText(ls, words: words)
        var groups: [SyncedLyricWordGroup]?
        if budget.wordRomanization != nil {
            if range.count == 1 {
                groups = first.groups
            } else if let words, let f = first.groupsFor {
                groups = f(words, text)
            }
        }
        let mainLimit = limit(budget.main, side: side, budget: budget) + fitTolerance
        guard mainWidth(words: words, groups: groups, text: text, budget: budget) <= mainLimit else { return false }
        if let row = budget.preview, row.measure(text) > limit(row, side: side, budget: budget) + fitTolerance {
            return false
        }
        if let row = budget.translation, let tr = joinedText(ls.map(\.translation)),
           row.measure(tr) > limit(row, side: side, budget: budget) + fitTolerance {
            return false
        }
        if let row = budget.romanization, groups == nil, let ro = joinedText(ls.map(\.romanization)),
           row.measure(ro) > limit(row, side: side, budget: budget) + fitTolerance {
            return false
        }
        return true
    }

    /// 组 [f, j] 能不能再并进第 j+1 句。第 j+1 句的停留按下一句的起点算;它是最后一句时按它唱完的时刻算,
    /// 行级歌词的最后一句没有句末标记就不知道停多久,不并。
    static func canMerge(_ line: LineProvider, from f: Int, through j: Int, budget: LineLayoutBudget) -> Bool {
        guard let a = line(j), let b = line(j + 1), let head = line(f),
              let bEnd = line(j + 2)?.startMs ?? b.sungEndMs else { return false }
        let dwellA = b.startMs - a.startMs, dwellB = bEnd - b.startMs
        guard dwellA < mergeShortDwellMs, dwellB < mergeNextMaxDwellMs else { return false }
        let tinyA = displayWidth(a.text) <= mergeTinyMaxWidth
        let tinyB = dwellB < mergeShortDwellMs && displayWidth(b.text) <= mergeTinyMaxWidth
        guard tinyA || tinyB else { return false }
        guard a.side == b.side, !a.gapAfter, a.mergeable, b.mergeable else { return false }
        guard (a.words == nil) == (b.words == nil) else { return false }
        guard (b.sungEndMs ?? bEnd) - head.startMs <= mergeMaxSpanMs else { return false }
        return fits(line, f...(j + 1), budget: budget)
    }

    // MARK: - 拆

    /// 拆开时的一个单位:一个词(逐词读音时是一组),或者行级歌词按文字切出来的一截。
    private struct Unit {
        var words: [SyncedLyricWord]
        var romanization: String?
        var width: CGFloat
        var text: String { words.map(\.text).joined() }
    }

    /// 把一句拆成每行都放得下的最少段数。拆不出来(一个字都放不下)返回 nil。
    static func split(_ line: Line, budget: LineLayoutBudget) -> [Part]? {
        let side = line.side
        let mainLimit = limit(budget.main, side: side, budget: budget)
        guard mainLimit > 0 else { return nil }
        let estimated = line.words == nil
        let words = line.words ?? estimatedWords(line, measure: budget.main.measure)
        guard !words.isEmpty else { return nil }
        let groupMode = budget.wordRomanization != nil && line.groups != nil
            && line.groups!.reduce(0, { $0 + $1.words.count }) == words.count
        var groupUnits: [Unit] = []
        if groupMode, let groups = line.groups, let wr = budget.wordRomanization {
            var offset = 0
            groupUnits = groups.map { g in
                let ws = Array(words[offset..<(offset + g.words.count)])
                offset += g.words.count
                let w = ws.reduce(CGFloat(0)) { $0 + budget.main.measure($1.text) }
                return Unit(words: ws, romanization: g.romanization,
                            width: max(w, wr.measure(g.romanization ?? " ") + wr.sidePadding * 2))
            }
        }
        var units: [Unit] = []
        for w in words {
            let width = budget.main.measure(w.text)
            if width > mainLimit + fitTolerance {
                units += exploded(w, measure: budget.main.measure)
            } else {
                units.append(Unit(words: [w], romanization: nil, width: width))
            }
        }
        let translationLimit = budget.translation.map { limit($0, side: side, budget: budget) }
        let romanizationLimit = budget.romanization.map { limit($0, side: side, budget: budget) }
        let translationNeedsSplit = budget.translation.flatMap { row in
            line.translation.map { row.measure($0) > translationLimit! + fitTolerance }
        } ?? false
        let romanizationTooWide = budget.romanization.flatMap { row in
            line.romanization.map { row.measure($0) > romanizationLimit! + fitTolerance }
        } ?? false
        let shownGroups = groupMode ? line.groups : (estimated ? nil : line.groupsFor?(words, line.text))
        // 硬切只给这一句自己的字(主行、下一句那一行)放不下的时候;放得下、要拆只是因为译文 / 罗马音时,断不开就
        // 把放不下的那一行截断(见末尾),不硬切词。
        let textFits = mainWidth(words: words, groups: shownGroups, text: line.text, budget: budget)
            <= mainLimit + fitTolerance
            && (budget.preview.map { $0.measure(line.text) <= limit($0, side: side, budget: budget) + fitTolerance } ?? true)

        /// `grouped`:单位就是逐词读音的一组,段内沿用这些组;否则每段显示时重新分组(groupsFor),按那样量。
        /// `hard`:false 只断在能断的地方;true 硬切(各段仍求等宽),再不行逐行装满。
        func attempt(_ units: [Unit], grouped: Bool, hard: Bool) -> [Part]? {
            guard units.count >= 2 else { return nil }
            let spaceWidth = budget.main.measure(" ")
            let widths = units.map(\.width)
            let trailing = units.map { $0.text.last?.isWhitespace == true ? spaceWidth : 0 }
            let natural: [CGFloat?] = units.indices.map { c in
                c == 0 ? nil : cutPenalty(after: units[c - 1].text, before: units[c].text)
            }
            let forced: [CGFloat?] = units.indices.map { c in c == 0 ? nil : (natural[c] ?? 1) }

            /// 按这组切点出各段;有一行放不下返回 nil。`balanced`:译文 / 罗马音也按各段等宽切(段数多时改为逐行装满)。
            func build(_ starts: [Int], balanced: Bool) -> [Part]? {
                let parts = starts.count
                let ranges = starts.indices.map { k in starts[k]..<(k + 1 < starts.count ? starts[k + 1] : units.count) }
                let partUnits = ranges.map { r in trimmed(Array(units[r])) }
                let partTexts = partUnits.map { $0.flatMap(\.words).map(\.text).joined() }
                let partGroups = zip(partUnits, partTexts).map { us, text -> [SyncedLyricWordGroup]? in
                    grouped
                        ? us.map { SyncedLyricWordGroup(id: 0, words: $0.words, romanization: $0.romanization) }
                        : (estimated ? nil : line.groupsFor?(us.flatMap(\.words), text))
                }
                for k in partUnits.indices {
                    let ws = partUnits[k].flatMap(\.words)
                    guard mainWidth(words: ws, groups: partGroups[k], text: partTexts[k], budget: budget)
                        <= mainLimit + fitTolerance else { return nil }
                }
                if let row = budget.preview {
                    let previewLimit = limit(row, side: side, budget: budget) + fitTolerance
                    guard partTexts.allSatisfy({ row.measure($0) <= previewLimit }) else { return nil }
                }
                func companion(_ text: String, _ row: LineLayoutBudget.Row, _ maxWidth: CGFloat) -> [String]? {
                    balanced ? spreadText(text, parts: parts, row: row, maxWidth: maxWidth)
                             : packText(text, parts: parts, row: row, maxWidth: maxWidth)
                }
                var translations: [String]?
                if translationNeedsSplit, let row = budget.translation, let tr = line.translation {
                    guard let t = companion(tr, row, translationLimit!) else { return nil }
                    translations = t
                }
                // 整行罗马音那一行只在这一段没有逐词读音时出现。
                let romanizationRowShown = budget.wordRomanization == nil || partGroups.contains { $0 == nil }
                var romanizations: [String]?
                if romanizationTooWide, romanizationRowShown, let row = budget.romanization, let ro = line.romanization {
                    guard let r = companion(ro, row, romanizationLimit!) else { return nil }
                    romanizations = r
                }
                return partUnits.indices.map { k in
                    let us = partUnits[k]
                    let ws = us.flatMap(\.words)
                    return Part(
                        index: k, count: partUnits.count,
                        startMs: k == 0 ? line.startMs : (ws.first?.startMs ?? line.startMs),
                        words: ws, estimated: estimated,
                        groupSizes: grouped ? us.map(\.words.count) : nil,
                        groupRomanizations: grouped ? us.map(\.romanization) : nil,
                        translation: translations?[k], romanization: romanizations?[k])
                }
            }

            // 段数至少要把总宽装下(每段末尾的空白不算宽),更少的不用试。
            let bare = widths.reduce(0, +) - trailing.reduce(0, +)
            let fewest = max(2, Int((bare / max(mainLimit, 1)).rounded(.up)))
            if fewest <= min(maxParts, units.count) {
                for parts in fewest...min(maxParts, units.count) {
                    guard let starts = balancedCuts(widths: widths, trailing: trailing,
                                                    penalties: hard ? forced : natural,
                                                    parts: parts, maxWidth: mainLimit) else { continue }
                    if let built = build(starts, balanced: true) { return built }
                }
            }
            guard hard else { return nil }
            // maxParts 段还放不下(整首挤在一行这类):不再求各段等宽,逐行装满。
            if let starts = packedCuts(widths: widths, trailing: trailing, penalties: natural, maxWidth: mainLimit),
               starts.count > 1, let built = build(starts, balanced: false) {
                return built
            }
            return nil
        }
        // 几种切法依次试:先都只断在能断的地方,都不行再按同样的顺序硬切。
        var tried: [(units: [Unit], grouped: Bool)] = []
        func soft(_ units: [Unit], grouped: Bool) -> [Part]? {
            tried.append((units, grouped))
            return attempt(units, grouped: grouped, hard: false)
        }
        if groupMode, let parts = soft(groupUnits, grouped: true) { return parts }
        // 画逐词读音的句子按组拆不开(整句只标成一个词,或者组跟词对不上):按字切开、整句重新分一次组,再按组拆。
        if let wr = budget.wordRomanization, let regroup = line.groupsFor, !estimated {
            let charWords = words.flatMap { w in exploded(w, measure: budget.main.measure).flatMap(\.words) }
            if let groups = regroup(charWords, line.text), groups.reduce(0, { $0 + $1.words.count }) == charWords.count {
                var offset = 0
                let regrouped = groups.map { g -> Unit in
                    let ws = Array(charWords[offset..<(offset + g.words.count)])
                    offset += g.words.count
                    let w = ws.reduce(CGFloat(0)) { $0 + budget.main.measure($1.text) }
                    return Unit(words: ws, romanization: g.romanization,
                                width: max(w, wr.measure(g.romanization ?? " ") + wr.sidePadding * 2))
                }
                if let parts = soft(regrouped, grouped: true) { return parts }
            }
        }
        if let parts = soft(units, grouped: false) { return parts }
        // 按词断不出来(词太少、整句只标成一个词、源里一个词跨了空格、译文要的段数比词多):主行按字切开再试。
        let chars = words.flatMap { exploded($0, measure: budget.main.measure) }
        if chars.count > units.count, let parts = soft(chars, grouped: false) { return parts }
        if !textFits {
            for t in tried {
                if let parts = attempt(t.units, grouped: t.grouped, hard: true) { return parts }
            }
        }
        // 主行自己放得下、只是在能断的地方切不出来(一个词配了一大串译文 / 罗马音):主行整句一段,放不下的那一行截断。
        guard textFits else { return nil }
        let romanizationRowShown = budget.wordRomanization == nil || shownGroups == nil
        return [Part(
            index: 0, count: 1, startMs: line.startMs, words: words, estimated: estimated,
            translation: translationNeedsSplit ? line.translation.flatMap { tr in
                budget.translation.map { truncated(tr, row: $0, maxWidth: translationLimit!) }
            } : nil,
            romanization: romanizationTooWide && romanizationRowShown ? line.romanization.flatMap { ro in
                budget.romanization.map { truncated(ro, row: $0, maxWidth: romanizationLimit!) }
            } : nil)]
    }

    /// 截到放得下为止,末尾补「…」。
    static func truncated(_ text: String, row: LineLayoutBudget.Row, maxWidth: CGFloat) -> String {
        guard row.measure(text) > maxWidth + fitTolerance else { return text }
        let chars = Array(text)
        func candidate(_ n: Int) -> String {
            String(chars[0..<n]).trimmingCharacters(in: .whitespaces) + "…"
        }
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if row.measure(candidate(mid)) <= maxWidth + fitTolerance { lo = mid } else { hi = mid - 1 }
        }
        return candidate(lo)
    }

    /// 一段首尾的空白去掉(首单位的前导空白、末单位的尾随空白)。
    private static func trimmed(_ units: [Unit]) -> [Unit] {
        var us = units
        if var first = us.first, let w = first.words.first {
            first.words[0] = SyncedLyricWord(text: String(w.text.drop { $0.isWhitespace }),
                                             startMs: w.startMs, durationMs: w.durationMs)
            us[0] = first
        }
        if var last = us.last, let w = last.words.last {
            let text = String(w.text.reversed().drop { $0.isWhitespace }.reversed())
            last.words[last.words.count - 1] = SyncedLyricWord(text: text, startMs: w.startMs, durationMs: w.durationMs)
            us[us.count - 1] = last
        }
        return us
    }

    /// 一个词按字切开,时间按字数平分。字与字之间能不能断照 `cutPenalty`:拉丁 / 谚文字母之间只有硬切,
    /// 词里自带的空白、标点、连字符和中日韩字之间照常能断(整句只标成一个词时,词就是整句)。
    private static func exploded(_ word: SyncedLyricWord, measure: (String) -> CGFloat) -> [Unit] {
        let chars = Array(word.text)
        guard chars.count > 1 else {
            return [Unit(words: [word], romanization: nil, width: measure(word.text))]
        }
        return chars.indices.map { k in
            let start = word.startMs + word.durationMs * k / chars.count
            let end = word.startMs + word.durationMs * (k + 1) / chars.count
            let text = String(chars[k])
            return Unit(words: [SyncedLyricWord(text: text, startMs: start, durationMs: end - start)],
                        romanization: nil, width: measure(text))
        }
    }

    /// 只有逐行时间的句子:按文字切成词(汉字 / 假名 / 谚文一个字一个),每个词几点开唱按它前面文字的宽度
    /// 占整句的比例估。
    static func estimatedWords(_ line: Line, measure: (String) -> CGFloat) -> [SyncedLyricWord] {
        let tokens = textTokens(line.text)
        guard !tokens.isEmpty else { return [] }
        var end = line.sungEndMs ?? line.nextStartMs ?? (line.startMs + estimatedMaxMsPerToken * tokens.count)
        end = min(end, line.startMs + estimatedMaxMsPerToken * tokens.count)
        let span = max(tokens.count, end - line.startMs)
        let widths = tokens.map { max(measure($0), 0.01) }
        let total = widths.reduce(0, +)
        var acc: CGFloat = 0
        var out: [SyncedLyricWord] = []
        for (k, t) in tokens.enumerated() {
            let start = line.startMs + Int((CGFloat(span) * acc / total).rounded(.down))
            acc += widths[k]
            let stop = line.startMs + Int((CGFloat(span) * acc / total).rounded(.down))
            out.append(SyncedLyricWord(text: t, startMs: start, durationMs: max(1, stop - start)))
        }
        return out
    }

    /// 把一段文字切成词:连续的非空白、非中日韩字符是一个词(带上后面的空白),中日韩字一个字一个。
    static func textTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var buf = ""
        var bufEndsWithSpace = false
        var bufEndsWithCJK = false
        for ch in text {
            if ch.isWhitespace {
                buf.append(ch)
                bufEndsWithSpace = true
                continue
            }
            let cjk = ch.unicodeScalars.first.map(isCJK) ?? false
            if !buf.isEmpty && (cjk || bufEndsWithSpace || bufEndsWithCJK) {
                tokens.append(buf)
                buf = ""
            }
            buf.append(ch)
            bufEndsWithSpace = false
            bufEndsWithCJK = cjk
        }
        if !buf.isEmpty { tokens.append(buf) }
        return tokens
    }

    /// 主行拆成 parts 段时,译文 / 罗马音那一行跟着切:切成放得下的最少段数(不超过 parts),按顺序摊到主行的
    /// 各段上(段数少于 parts 时相邻几段显示同一截)。切不出来返回 nil。
    static func spreadText(_ text: String, parts: Int, row: LineLayoutBudget.Row, maxWidth: CGFloat) -> [String]? {
        for q in 2...max(2, parts) where q <= parts {
            guard let pieces = splitText(text, parts: q, row: row, maxWidth: maxWidth) else { continue }
            return (0..<parts).map { pieces[$0 * q / parts] }
        }
        return nil
    }

    /// 逐行装满:每段装到放不下为止,断在这一段里最后一个能断的地方(没有就硬断)。返回每段起点;有一个单位
    /// 自己就放不下返回 nil。
    static func packedCuts(widths: [CGFloat], trailing: [CGFloat], penalties: [CGFloat?],
                           maxWidth: CGFloat) -> [Int]? {
        let n = widths.count
        var prefix = [CGFloat](repeating: 0, count: n + 1)
        for k in 0..<n { prefix[k + 1] = prefix[k] + widths[k] }
        func partWidth(_ a: Int, _ c: Int) -> CGFloat { prefix[c] - prefix[a] - trailing[c - 1] }
        var starts = [0]
        var a = 0
        while a < n {
            guard partWidth(a, a + 1) <= maxWidth + fitTolerance else { return nil }
            var c = a + 1
            while c < n, partWidth(a, c + 1) <= maxWidth + fitTolerance { c += 1 }
            if c == n { break }
            var cut = c
            while cut > a + 1, penalties[cut] == nil { cut -= 1 }
            if penalties[cut] == nil { cut = c }
            starts.append(cut)
            a = cut
        }
        return starts
    }

    /// 译文 / 罗马音逐行装满(主行也是逐行装满的时候用),段数不超过 parts,按顺序摊到主行各段上。
    static func packText(_ text: String, parts: Int, row: LineLayoutBudget.Row, maxWidth: CGFloat) -> [String]? {
        let tokens = textTokens(text).flatMap { t -> [String] in
            row.measure(t) > maxWidth + fitTolerance ? t.map(String.init) : [t]
        }
        guard !tokens.isEmpty else { return nil }
        let spaceWidth = row.measure(" ")
        let widths = tokens.map(row.measure)
        let trailing = tokens.map { $0.last?.isWhitespace == true ? spaceWidth : 0 }
        let penalties: [CGFloat?] = tokens.indices.map { c in
            c == 0 ? nil : cutPenalty(after: tokens[c - 1], before: tokens[c])
        }
        guard let starts = packedCuts(widths: widths, trailing: trailing, penalties: penalties, maxWidth: maxWidth),
              starts.count <= parts else { return nil }
        let q = starts.count
        let pieces = starts.indices.map { i -> String in
            let end = i + 1 < q ? starts[i + 1] : tokens.count
            return tokens[starts[i]..<end].joined().trimmingCharacters(in: .whitespaces)
        }
        guard pieces.allSatisfy({ row.measure($0) <= maxWidth + fitTolerance }) else { return nil }
        return (0..<parts).map { pieces[$0 * q / parts] }
    }

    /// 没有时间的一行文字(译文 / 罗马音)切成 parts 段、每段都放得下;切不出来返回 nil。
    static func splitText(_ text: String, parts: Int, row: LineLayoutBudget.Row, maxWidth: CGFloat) -> [String]? {
        var tokens = textTokens(text)
        var glued = [Bool](repeating: false, count: tokens.count)
        // 一个词比整行还宽就按字切开,切口只在别处断不开时用。
        var k = 0
        while k < tokens.count {
            if row.measure(tokens[k]) > maxWidth + fitTolerance, tokens[k].count > 1 {
                let chars = tokens[k].map(String.init)
                tokens.replaceSubrange(k...k, with: chars)
                glued.replaceSubrange(k...k, with: [false] + [Bool](repeating: true, count: chars.count - 1))
                k += chars.count
            } else {
                k += 1
            }
        }
        guard tokens.count >= parts else { return nil }
        let spaceWidth = row.measure(" ")
        let widths = tokens.map(row.measure)
        let trailing = tokens.map { $0.last?.isWhitespace == true ? spaceWidth : 0 }
        let natural: [CGFloat?] = tokens.indices.map { c in
            guard c > 0, !glued[c] else { return nil }
            return cutPenalty(after: tokens[c - 1], before: tokens[c])
        }
        let forced: [CGFloat?] = tokens.indices.map { c in c == 0 ? nil : (natural[c] ?? 1) }
        for penalties in [natural, forced] {
            guard let starts = balancedCuts(widths: widths, trailing: trailing, penalties: penalties,
                                            parts: parts, maxWidth: maxWidth) else { continue }
            let out = starts.indices.map { i -> String in
                let end = i + 1 < starts.count ? starts[i + 1] : tokens.count
                return tokens[starts[i]..<end].joined().trimmingCharacters(in: .whitespaces)
            }
            if out.allSatisfy({ row.measure($0) <= maxWidth + fitTolerance }) { return out }
        }
        return nil
    }

    /// 把 n 个单位切成 parts 段、每段宽不超过 maxWidth:各段宽度越接近越好,断点代价(`penalties[c]` = 在第 c 个
    /// 单位前面断,nil = 不能断)越小越好。返回每段从第几个单位开始(第一个恒为 0);切不出来返回 nil。
    static func balancedCuts(widths: [CGFloat], trailing: [CGFloat], penalties: [CGFloat?],
                             parts: Int, maxWidth: CGFloat) -> [Int]? {
        let n = widths.count
        guard parts >= 1, parts <= n else { return nil }
        var prefix = [CGFloat](repeating: 0, count: n + 1)
        for k in 0..<n { prefix[k + 1] = prefix[k] + widths[k] }
        func partWidth(_ a: Int, _ c: Int) -> CGFloat { prefix[c] - prefix[a] - trailing[c - 1] }
        let target = partWidth(0, n) / CGFloat(parts)
        let scale = max(maxWidth, 1)
        let inf = CGFloat.infinity
        var cost = [[CGFloat]](repeating: [CGFloat](repeating: inf, count: n + 1), count: parts + 1)
        var parent = [[Int]](repeating: [Int](repeating: -1, count: n + 1), count: parts + 1)
        cost[0][0] = 0
        for k in 1...parts {
            // 前 c 个单位切成 k 段:c 至少 k 个,后面还得留够 parts - k 段各一个。
            for c in k...(n - (parts - k)) {
                // 从 c 往前找这一段的起点:越往前越宽,超宽就不用再往前了。
                for a in stride(from: c - 1, through: k - 1, by: -1) {
                    let w = partWidth(a, c)
                    guard w <= maxWidth + fitTolerance else { break }
                    let prev = cost[k - 1][a]
                    guard prev.isFinite else { continue }
                    var p: CGFloat = 0
                    if a > 0 {
                        guard let pen = penalties[a] else { continue }
                        p = pen
                    }
                    let d = (w - target) / scale
                    let total = prev + d * d + p
                    if total < cost[k][c] {
                        cost[k][c] = total
                        parent[k][c] = a
                    }
                }
            }
        }
        guard cost[parts][n].isFinite else { return nil }
        var starts: [Int] = []
        var c = n
        for k in stride(from: parts, through: 1, by: -1) {
            let a = parent[k][c]
            starts.append(a)
            c = a
        }
        return starts.reversed()
    }

    /// 在两个词之间断开的代价;nil = 不能断(拉丁词、谚文词中间,下一段会以标点开头)。
    public static func cutPenalty(after previous: String, before next: String) -> CGFloat? {
        guard let last = previous.unicodeScalars.last, let first = next.unicodeScalars.first else { return 0 }
        // 标点不放到下一段开头。
        if sentencePunctuation.contains(first) { return nil }
        if CharacterSet.whitespacesAndNewlines.contains(last) {
            let beforeSpace = previous.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last
            if let p = beforeSpace, sentencePunctuation.contains(p) { return 0 }
            return 0.05
        }
        if sentencePunctuation.contains(last) { return 0 }
        if CharacterSet.whitespacesAndNewlines.contains(first) { return 0.05 }
        // 连字符后面能断,比空格差一点;谚文按空格分词,一个词的几个音节之间不断。两条都同悬浮歌词换行
        // (`WrapLayoutMath.breakOpportunities`)。
        if last == "-", CharacterSet.alphanumerics.contains(first) { return 0.1 }
        if isHangul(last) && isHangul(first) { return nil }
        if isCJK(last) || isCJK(first) { return 0.15 }
        return nil
    }

    static let sentencePunctuation = CharacterSet(charactersIn: ",.!?;:、，。！？；：…")

    static func isHangul(_ scalar: Unicode.Scalar) -> Bool { (0xAC00...0xD7AF).contains(scalar.value) }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3040...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xAC00...0xD7AF).contains(v)
    }

    /// 字数:汉字 / 假名 / 谚文一个字算 1,其余按空白分开的词算 1(只算带字母或数字的词)。判「很短的一句」用。
    public static func displayWidth(_ text: String) -> Int {
        var width = 0
        var inWord = false
        var wordHasAlnum = false
        for scalar in text.unicodeScalars {
            let cjk = isCJK(scalar)
            if cjk || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if inWord, wordHasAlnum { width += 1 }
                inWord = false
                wordHasAlnum = false
                if cjk { width += 1 }
                continue
            }
            inWord = true
            if CharacterSet.alphanumerics.contains(scalar) { wordHasAlnum = true }
        }
        if inWord, wordHasAlnum { width += 1 }
        return width
    }
}
