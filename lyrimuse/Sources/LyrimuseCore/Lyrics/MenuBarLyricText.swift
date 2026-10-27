import Foundation

/// 菜单栏那一格主行显示什么字:原文、只显示译文,还是原文后面接着译文排成一行。见 06 章决策 70。
public enum MenuBarLyricText {
    public enum Mode: Equatable, Sendable {
        /// 原文(副行另起一行,或者不显示)。
        case original
        /// 「显示内容」选「译文」:主行是这一句的译文,没有译文的句子显示原文。单行、字号照常。
        case translationOnly
        /// 「副行」选「译文(同一行)」:原文后面接分隔符和译文,排成一行。单行、字号照常。
        case inlineTranslation
    }

    /// 原文和同一行译文之间的分隔。
    public static let inlineSeparator = "  ·  "

    /// 同一行里的译文(含分隔符)画多淡,跟两行时译文副行同一档(`MenuBarLyricRows.secondaryOpacity`)。
    public static var inlineTranslationOpacity: Double { Double(MenuBarLyricRows.secondaryOpacity(for: .translation)) }

    public static func mode(translationOnly: Bool, secondary: LyricSecondaryLine, inline: Bool) -> Mode {
        if translationOnly { return .translationOnly }
        return secondary == .translation && inline ? .inlineTranslation : .original
    }

    /// 实际按哪种副行排版:两种译文排法都是单行(`.off`),主行取单行那一句(`compactLine`)、字号照常。
    public static func layoutSecondary(mode: Mode, secondary: LyricSecondaryLine) -> LyricSecondaryLine {
        mode == .original ? secondary : .off
    }

    /// 这一句在主行上的文字。`translationStart`:同一行排法里译文那段(含分隔符)从第几个 UTF-16 单元起,
    /// 其余情况 nil。没有译文时两种译文排法都只给原文;原文从右往左时不拼(两种书写方向排进同一行,顺序会乱),也只给原文。
    public static func text(plainText: String, translation: String?, mode: Mode) -> (text: String, translationStart: Int?) {
        let translated = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let translated, !translated.isEmpty else { return (plainText, nil) }
        switch mode {
        case .original:
            return (plainText, nil)
        case .translationOnly:
            return (translated, nil)
        case .inlineTranslation:
            guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !LyricTextDirection.isRightToLeft(plainText) else { return (plainText, nil) }
            return (plainText + inlineSeparator + translated, (plainText as NSString).length)
        }
    }
}
