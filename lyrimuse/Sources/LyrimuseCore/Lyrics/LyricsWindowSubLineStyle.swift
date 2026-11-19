import Foundation

/// 歌词窗口完整尺寸(和照它画的网页歌词)读音行、译文行其中一行的字体、粗细、颜色,每项都能「跟随正文」。
/// 迷你「多行」共用同一份列表,一律按 `follow` 画。
///
/// 三项都跟随时,字体族、粗细、颜色跟没有这项设置时逐数相等(selftest 核对):字体同正文;粗细比正文细
/// `Line.followWeightSteps` 档;颜色按正文色调降透明度(`followColor`),逐词读音是正文色 × `perWordFollowOpacity`。
/// 见 07 章决策 217。
public struct LyricsWindowSubLineStyle: Equatable, Sendable {
    /// 读音行还是译文行。
    public enum Line: String, CaseIterable, Sendable {
        case romanization
        case translation

        /// 粗细跟随时比正文细几档(同迷你尺寸那一组,07 章决策 117)。
        public var followWeightSteps: Int {
            switch self {
            case .romanization: return OverlayFontWeight.lyricsWindowRomanizationSteps
            case .translation: return OverlayFontWeight.lyricsWindowTranslationSteps
            }
        }
    }

    /// 字体族:空串跟随正文,`systemFontFamily` 是系统字体,其余是族名。
    public var fontFamily: String
    /// 粗细;nil 跟随正文(比正文细 `Line.followWeightSteps` 档)。
    public var weight: OverlayFontWeight?
    /// 颜色 `#RRGGBB` / `#RRGGBBAA`;空串(或认不出来)跟随正文色。
    public var colorHex: String

    public init(fontFamily: String = "", weight: OverlayFontWeight? = nil, colorHex: String = "") {
        self.fontFamily = fontFamily
        self.weight = weight
        self.colorHex = colorHex
    }

    /// 三项都跟随正文。
    public static let follow = LyricsWindowSubLineStyle()

    /// 「系统字体」那一项存的值。空串已经是「跟随正文」,系统字体要另一个记号;不会是哪款真字体的族名。
    public static let systemFontFamily = "-apple-system"

    /// 白字、自定义正文色跟随时降到的不透明度:Apple 同窗口实测译文的亮度(07 章决策 87)。
    public static let followOpacity = 0.73
    /// 深色档跟随时用的黑的不透明度。
    public static let followDarkOpacity = 0.5
    /// 逐词读音(画在正文那一块里、跟着逐字填色)跟随时是正文色乘这个不透明度。
    public static let perWordFollowOpacity = 0.75

    public var isFollow: Bool { self == .follow }

    /// 画这一行用的字体族(交给 `NSFont.overlayFont`,空串 = 系统字体)。`main` 是正文的字体族。
    public func resolvedFontFamily(main: String) -> String {
        switch fontFamily {
        case "": return main
        case Self.systemFontFamily: return ""
        default: return fontFamily
        }
    }

    /// 画这一行用的粗细。`main` 是正文那一档。
    public func resolvedWeight(main: OverlayFontWeight, line: Line) -> OverlayFontWeight {
        weight ?? main.lighter(by: line.followWeightSteps)
    }

    /// 指定的颜色(sRGB 分量 0…1);跟随或认不出来时 nil。
    public var fixedColor: LyricsWindowSubLineColor.RGBA? {
        guard !colorHex.isEmpty, let c = LyricsWindowBackgroundLuma.parse(hex: colorHex) else { return nil }
        return .init(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    /// 整行读音、译文的颜色。指定了颜色时不看文字配色(自动 / 浅色 / 深色 / 自定义都用它),也不再降透明度。
    public func color(textTone: LyricsWindowTextColorMode.Tone) -> LyricsWindowSubLineColor {
        fixedColor.map { .fixed($0) } ?? Self.followColor(textTone)
    }

    /// 逐词读音的颜色:跟随时是正文色 × `perWordFollowOpacity`,不分配色;指定了颜色时同整行读音。
    public var perWordColor: LyricsWindowSubLineColor {
        fixedColor.map { .fixed($0) } ?? .textColor(opacity: Self.perWordFollowOpacity)
    }

    /// 跟随正文时整行读音、译文的颜色:三个钉死档按正文色降透明度,跟随系统前景色时用系统的次级色。
    public static func followColor(_ tone: LyricsWindowTextColorMode.Tone) -> LyricsWindowSubLineColor {
        switch tone {
        case .white: return .white(opacity: followOpacity)
        case .systemPrimary: return .systemSecondary
        case .dark: return .black(opacity: followDarkOpacity)
        case .custom: return .textColor(opacity: followOpacity)
        }
    }

    /// 指定的字体此刻不可用(导入字体删掉了、换机后没带过来)时按跟随正文;`available` 还没读到(nil)时原样。
    public func droppingMissingFont(available: Set<String>?) -> LyricsWindowSubLineStyle {
        guard let available, !fontFamily.isEmpty, fontFamily != Self.systemFontFamily,
              CustomFontFile.isMissing(fontFamily, available: available) else { return self }
        var next = self
        next.fontFamily = ""
        return next
    }
}

/// 读音行、译文行解析出来的颜色。App 换成具体颜色(SwiftUI `Color` / `NSColor`)。
public enum LyricsWindowSubLineColor: Equatable, Sendable {
    public struct RGBA: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    case white(opacity: Double)
    /// 系统的次级前景色(SwiftUI `.secondary`)。
    case systemSecondary
    case black(opacity: Double)
    /// 正文色乘这个不透明度。
    case textColor(opacity: Double)
    case fixed(RGBA)
}

/// 读音行、译文行两份(`LyricsWindowSubLineStyle`),和调试深链 / 设置读写用的六项。
public struct LyricsWindowSubLines: Equatable, Sendable {
    public var romanization: LyricsWindowSubLineStyle
    public var translation: LyricsWindowSubLineStyle

    public init(romanization: LyricsWindowSubLineStyle = .follow, translation: LyricsWindowSubLineStyle = .follow) {
        self.romanization = romanization
        self.translation = translation
    }

    /// 两行都全跟随。
    public static let follow = LyricsWindowSubLines()

    public var isFollow: Bool { self == .follow }

    public subscript(line: LyricsWindowSubLineStyle.Line) -> LyricsWindowSubLineStyle {
        get { line == .romanization ? romanization : translation }
        set {
            if line == .romanization { romanization = newValue } else { translation = newValue }
        }
    }

    /// 两行里指定的字体此刻不可用的,按跟随正文(`LyricsWindowSubLineStyle.droppingMissingFont`)。
    public func droppingMissingFonts(available: Set<String>?) -> LyricsWindowSubLines {
        LyricsWindowSubLines(romanization: romanization.droppingMissingFont(available: available),
                             translation: translation.droppingMissingFont(available: available))
    }

    /// 六项。原始值是调试深链里的参数名。
    public enum Item: String, CaseIterable, Sendable {
        case romanizationFont = "romanization-font"
        case romanizationWeight = "romanization-weight"
        case romanizationColor = "romanization-color"
        case translationFont = "translation-font"
        case translationWeight = "translation-weight"
        case translationColor = "translation-color"

        public var line: LyricsWindowSubLineStyle.Line {
            switch self {
            case .romanizationFont, .romanizationWeight, .romanizationColor: return .romanization
            case .translationFont, .translationWeight, .translationColor: return .translation
            }
        }

        /// 深链里的值 → 存着的样子(同 `subscript(item:)`):`follow` 一律是跟随(空串);字体另认 `system`;
        /// 粗细是 `OverlayFontWeight` 的原始值;颜色是 6 或 8 位十六进制(井号可省),存成 `#RRGGBBAA`。认不出来 nil。
        public func storedValue(fromQuery raw: String) -> String? {
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if text.lowercased() == "follow" { return "" }
            switch self {
            case .romanizationFont, .translationFont:
                return text.lowercased() == "system" ? LyricsWindowSubLineStyle.systemFontFamily : text
            case .romanizationWeight, .translationWeight:
                return OverlayFontWeight(rawValue: text.lowercased())?.rawValue
            case .romanizationColor, .translationColor:
                guard let c = LyricsWindowBackgroundLuma.parse(hex: text) else { return nil }
                func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
                return String(format: "#%02X%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b), byte(c.a))
            }
        }

        /// 存着的值 → 深链里的写法(`storedValue(fromQuery:)` 的反过来)。
        public func queryValue(stored: String) -> String {
            if stored.isEmpty { return "follow" }
            switch self {
            case .romanizationFont, .translationFont:
                return stored == LyricsWindowSubLineStyle.systemFontFamily ? "system" : stored
            case .romanizationWeight, .translationWeight:
                return stored
            case .romanizationColor, .translationColor:
                return stored.hasPrefix("#") ? String(stored.dropFirst()) : stored
            }
        }
    }

    /// 按项读写存着的字符串:字体族(空串跟随)、粗细原始值(空串跟随)、颜色(空串跟随)。认不出来的粗细按跟随。
    public subscript(item: Item) -> String {
        get {
            let style = self[item.line]
            switch item {
            case .romanizationFont, .translationFont: return style.fontFamily
            case .romanizationWeight, .translationWeight: return style.weight?.rawValue ?? ""
            case .romanizationColor, .translationColor: return style.colorHex
            }
        }
        set {
            var style = self[item.line]
            switch item {
            case .romanizationFont, .translationFont: style.fontFamily = newValue
            case .romanizationWeight, .translationWeight: style.weight = OverlayFontWeight(rawValue: newValue)
            case .romanizationColor, .translationColor: style.colorHex = newValue
            }
            self[item.line] = style
        }
    }

    /// 拿 `values` 里有的项盖掉自己的(调试深链)。
    public func overriding(_ values: [Item: String]) -> LyricsWindowSubLines {
        var next = self
        for (item, value) in values { next[item] = value }
        return next
    }
}
