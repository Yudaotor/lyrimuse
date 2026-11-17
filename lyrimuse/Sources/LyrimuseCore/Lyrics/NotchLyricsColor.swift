import Foundation

/// 灵动岛歌词行的颜色:跟着灵动岛那一套强调色走、用户自己挑的一个颜色,或沿歌词流动的彩虹(`RainbowLyrics`)。
/// 只管歌词字,歌名、状态文字、音浪、进度线照旧跟强调色。见 05 章决策 120、153。
public enum NotchLyricsColor: String, CaseIterable, Sendable {
    case accent
    case custom
    case rainbow

    /// 存着的值认不出(或没存过)时用 `fallback`。
    public static func resolved(stored: String?, fallback: NotchLyricsColor) -> NotchLyricsColor {
        stored.flatMap(NotchLyricsColor.init(rawValue:)) ?? fallback
    }

    /// 「自定义」那一档的颜色:存着的 `#RRGGBB` / `#RRGGBBAA` 只取 RGB,字恒不透明;没选过(空串)或认不出时是白色。
    public static func customRGB(hex: String) -> (r: Double, g: Double, b: Double) {
        guard let c = LyricsWindowBackgroundLuma.parse(hex: hex) else { return (1, 1, 1) }
        return (c.r, c.g, c.b)
    }

    /// 「自定义」那一档未唱部分的颜色:自定义色打 `opacity` 这个折,感知亮度不低于白字打同一个折(同触控栏
    /// `TouchBarLyricsStyle.dimmedOnBlack`),深色、饱和的颜色未唱部分不沉进背景。结果按不透明色用。
    public static func customUnsungRGB(hex: String, opacity: Double) -> (r: Double, g: Double, b: Double) {
        let c = customRGB(hex: hex)
        return TouchBarLyricsStyle.dimmedOnBlack(r: c.r, g: c.g, b: c.b, opacity: opacity)
    }

    /// 展开时的多行歌词列表跟不跟这一档:自定义跟;彩虹不跟(列表是歌词窗口那套图层,不画彩虹),同强调色一样跟强调色。
    public var tintsExpandedLyricList: Bool { self == .custom }
}
