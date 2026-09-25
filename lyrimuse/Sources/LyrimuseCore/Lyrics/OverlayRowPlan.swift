import Foundation

/// 悬浮歌词一帧里各行怎么排:每一行显示什么、动不动、怎么动。视图(`LyricsOverlayView`)只照着
/// 结果画,判据都收在这里,由 selftest 的真值表钉住。
public enum OverlayRowPlan {
    /// 一行怎么动。
    public enum Motion: Equatable, Sendable {
        /// 换行模式:放不下就折行,不滚。
        case wrap
        /// 跟唱:图层按逐字时间轴滚(只给带逐字数据的当前行)。
        case follow
        /// 按这一行的显示时长配速(图层)。
        case paced
        /// 不滚:放不下从开头显示、末尾截断。给还没轮到唱的内容。
        case still
        /// 固定速度的跑马灯。滚动模式下拿不到时间窗口时的退路(设置页示例行)。
        case marquee
    }

    public struct Row: Equatable, Sendable {
        public let text: String
        public let motion: Motion

        public init(text: String, motion: Motion) {
            self.text = text
            self.motion = motion
        }
    }

    public struct Input: Sendable {
        public var overflow: OverlayLineOverflow
        /// 这一帧有没有当前行。没有 = 前奏 / 间奏「•••」,下方显示的是接下来那句。
        public var hasLine: Bool
        public var lineHasWords: Bool
        public var lineHasWordGroups: Bool
        public var lineRomanization: String?
        public var lineTranslation: String?
        /// 当前行是设置页的示例行(没有真实的时间轴)。
        public var isPreviewLine: Bool
        /// 拿得到当前行的显示窗口(`LyricDisplayWindow`)。
        public var hasTimingWindow: Bool
        public var showRomanization: Bool
        public var showTranslation: Bool
        public var showNextLinePreview: Bool
        public var nextText: String?
        public var nextRomanization: String?
        public var nextTranslation: String?
        public var nextHasWordGroups: Bool

        public init(
            overflow: OverlayLineOverflow, hasLine: Bool, lineHasWords: Bool = false,
            lineHasWordGroups: Bool = false, lineRomanization: String? = nil, lineTranslation: String? = nil,
            isPreviewLine: Bool = false, hasTimingWindow: Bool = false,
            showRomanization: Bool = false, showTranslation: Bool = false, showNextLinePreview: Bool = false,
            nextText: String? = nil, nextRomanization: String? = nil, nextTranslation: String? = nil,
            nextHasWordGroups: Bool = false
        ) {
            self.overflow = overflow
            self.hasLine = hasLine
            self.lineHasWords = lineHasWords
            self.lineHasWordGroups = lineHasWordGroups
            self.lineRomanization = lineRomanization
            self.lineTranslation = lineTranslation
            self.isPreviewLine = isPreviewLine
            self.hasTimingWindow = hasTimingWindow
            self.showRomanization = showRomanization
            self.showTranslation = showTranslation
            self.showNextLinePreview = showNextLinePreview
            self.nextText = nextText
            self.nextRomanization = nextRomanization
            self.nextTranslation = nextTranslation
            self.nextHasWordGroups = nextHasWordGroups
        }
    }

    public struct Plan: Equatable, Sendable {
        /// 当前行的主歌词怎么动;nil = 没有当前行。
        public var main: Motion?
        /// 当前行的读音逐词标在每个词底下(整行罗马音那一行随之不出现)。
        public var perWordRomanization: Bool
        /// 整行罗马音那一行。没有当前行时是接下来那句的。
        public var romanization: Row?
        /// 译文那一行。没有当前行时是接下来那句的。
        public var translation: Row?
        /// 下一句预览。
        public var next: Row?
        /// 没有当前行时,接下来那句的读音逐词标在它底下。
        public var nextPerWordRomanization: Bool
    }

    public static func resolve(_ i: Input) -> Plan {
        let scroll = i.overflow == .scroll
        let perWord = i.hasLine && i.showRomanization && i.lineHasWordGroups
        let nextPerWord = !i.hasLine && i.showRomanization && i.nextHasWordGroups
        // 按时长配速只给真实的当前行:示例行没有时间轴,没有当前行时那几行是还没唱的内容。
        let paced = scroll && i.hasLine && !i.isPreviewLine && i.hasTimingWindow
        let fallback: Motion = scroll ? .marquee : .wrap

        func secondary(_ text: String?) -> Row? {
            guard let text else { return nil }
            if paced { return Row(text: text, motion: .paced) }
            // 没有当前行时这几行属于接下来那句,还没轮到唱,滚动模式下不动。
            if !i.hasLine && scroll { return Row(text: text, motion: .still) }
            return Row(text: text, motion: fallback)
        }

        let main: Motion?
        if !i.hasLine {
            main = nil
        } else if i.lineHasWords {
            main = scroll ? .follow : .wrap
        } else {
            main = paced ? .paced : fallback
        }

        let romanization: Row? = (i.showRomanization && !perWord && !nextPerWord)
            ? secondary(i.hasLine ? i.lineRomanization : i.nextRomanization) : nil
        let translation: Row? = i.showTranslation
            ? secondary(i.hasLine ? i.lineTranslation : i.nextTranslation) : nil
        // 下一句永远是还没唱的内容:滚动模式下不动,换行模式照旧折行。
        let next: Row? = i.showNextLinePreview
            ? i.nextText.map { Row(text: $0, motion: scroll ? .still : .wrap) } : nil

        return Plan(main: main, perWordRomanization: perWord, romanization: romanization,
                    translation: translation, next: next, nextPerWordRomanization: nextPerWord)
    }
}
