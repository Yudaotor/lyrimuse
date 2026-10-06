import Foundation

/// 歌词窗口迷你尺寸逐字填色时「已唱」那一端的颜色(`np:lyricsWindowMiniKaraokeFill`,见 07 章决策 117)。
///
/// 只管当前行唱过的部分:没唱到的部分、其它行、没有逐字数据的行仍是文字颜色。非当前行按「整行已唱」画,
/// 填色颜色挂上去整列都会变成这个颜色,所以渲染那边只在当前行用它。
public enum LyricsWindowKaraokeFill: String, CaseIterable, Sendable {
    /// 跟文字颜色一样(默认)。
    case text
    /// 封面均值色,按歌词这一块底色的深浅调到看得清(`accent`)。
    case artwork
    /// 自己挑的颜色(`np:lyricsWindowMiniKaraokeFillColorHex`)。
    case custom

    /// 文字色的相对亮度过了这一点算浅色(底色深):跟黑、白两边对比度相等的那个亮度。
    public static let lightTextLuminance = 0.179

    /// 「跟随封面」用的颜色。底色深(文字是浅色)时走灵动岛那一套:HSB 亮度地板,再补感知亮度下限;
    /// 底色浅时压暗到跟白底的对比度够 3(`LocalPlaybackSource.accentAgainstStroke`)。纯函数,selftest 覆盖。
    public static func accent(r: Double, g: Double, b: Double, darkBackdrop: Bool) -> (r: Double, g: Double, b: Double) {
        if darkBackdrop {
            let lifted = LocalPlaybackSource.brightenedAccent(r: r, g: g, b: b)
            return LocalPlaybackSource.accentForDarkBackdrop(r: lifted.r, g: lifted.g, b: lifted.b)
        }
        return LocalPlaybackSource.accentAgainstStroke(r: r, g: g, b: b, strokeR: 1, strokeG: 1, strokeB: 1)
    }
}
