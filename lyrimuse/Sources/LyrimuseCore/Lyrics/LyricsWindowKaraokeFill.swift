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

    /// 调完的颜色在 CIELAB 里的彩度低于它,就按封面色调把彩度抬到它,明度不动(07 章决策 127)。
    /// 有颜色的封面调完都在它上面,原样不动。
    public static let minChroma = 24.0
    /// 封面均值色的彩度低于它算中性(纯灰、纯白、近黑):色相不可信,改用 `accent` 的 `fallback`。
    public static let neutralChroma = 3.0
    /// `fallback` 也是中性色(系统强调色选了石墨)时用的颜色,同自定义颜色的默认值 #FC3C44。
    public static let neutralFallback: (r: Double, g: Double, b: Double) = (0xFC / 255.0, 0x3C / 255.0, 0x44 / 255.0)

    /// 「跟随封面」用的颜色。底色深(文字是浅色)时走灵动岛那一套:HSB 亮度地板,再补感知亮度下限;
    /// 底色浅时压暗到跟白底的对比度够 3(`LocalPlaybackSource.accentAgainstStroke`)。调完彩度不够
    /// `minChroma` 的按封面色调抬上去;封面是中性色时改用 `fallback`(App 传系统强调色)。纯函数,selftest 覆盖。
    public static func accent(
        r: Double, g: Double, b: Double, darkBackdrop: Bool,
        fallback: (r: Double, g: Double, b: Double) = neutralFallback
    ) -> (r: Double, g: Double, b: Double) {
        var source = (r: r, g: g, b: b)
        if lab(r: r, g: g, b: b).chroma < neutralChroma {
            source = lab(r: fallback.r, g: fallback.g, b: fallback.b).chroma < neutralChroma ? neutralFallback : fallback
        }
        let hue = lab(r: source.r, g: source.g, b: source.b).hue
        let base = backdropAdjusted(source, darkBackdrop: darkBackdrop)
        let adjusted = lab(r: base.r, g: base.g, b: base.b)
        guard adjusted.chroma < minChroma else { return base }
        let lifted = inGamut(l: adjusted.l, chroma: minChroma, hue: hue)
        guard darkBackdrop else { return lifted }
        return LocalPlaybackSource.accentForDarkBackdrop(r: lifted.r, g: lifted.g, b: lifted.b)
    }

    private static func backdropAdjusted(
        _ c: (r: Double, g: Double, b: Double), darkBackdrop: Bool
    ) -> (r: Double, g: Double, b: Double) {
        if darkBackdrop {
            let lifted = LocalPlaybackSource.brightenedAccent(r: c.r, g: c.g, b: c.b)
            return LocalPlaybackSource.accentForDarkBackdrop(r: lifted.r, g: lifted.g, b: lifted.b)
        }
        return LocalPlaybackSource.accentAgainstStroke(r: c.r, g: c.g, b: c.b, strokeR: 1, strokeG: 1, strokeB: 1)
    }

    // MARK: - CIELAB(D65,sRGB)

    /// sRGB(gamma)→ CIELAB 的明度、彩度、色相角(度)。明度只由相对亮度决定,只改彩度不改对比度。
    public static func lab(r: Double, g: Double, b: Double) -> (l: Double, chroma: Double, hue: Double) {
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let x = 0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb
        let y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
        let z = 0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb
        let fx = f(x / whiteX), fy = f(y), fz = f(z / whiteZ)
        let a = 500 * (fx - fy), bb = 200 * (fy - fz)
        let hue = atan2(bb, a) * 180 / .pi
        return (116 * fy - 16, (a * a + bb * bb).squareRoot(), hue < 0 ? hue + 360 : hue)
    }

    /// 明度、色相不变,彩度从 `chroma` 往下找 sRGB 放得下的最大值。彩度 0(灰)总放得下。
    private static func inGamut(l: Double, chroma: Double, hue: Double) -> (r: Double, g: Double, b: Double) {
        if let c = rgb(l: l, chroma: chroma, hue: hue) { return c }
        var lo = 0.0, hi = chroma
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if rgb(l: l, chroma: mid, hue: hue) != nil { lo = mid } else { hi = mid }
        }
        return rgb(l: l, chroma: lo, hue: hue) ?? (0, 0, 0)
    }

    /// CIELAB → sRGB(gamma),出了色域返回 nil。
    private static func rgb(l: Double, chroma: Double, hue: Double) -> (r: Double, g: Double, b: Double)? {
        let h = hue * .pi / 180
        let fy = (l + 16) / 116
        let fx = fy + chroma * cos(h) / 500
        let fz = fy - chroma * sin(h) / 200
        let x = finv(fx) * whiteX, y = finv(fy), z = finv(fz) * whiteZ
        let lr = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let lg = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let lb = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        let tolerance = 1e-9
        guard [lr, lg, lb].allSatisfy({ $0 >= -tolerance && $0 <= 1 + tolerance }) else { return nil }
        return (gamma(lr), gamma(lg), gamma(lb))
    }

    private static let whiteX = 0.95047
    private static let whiteZ = 1.08883

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ c: Double) -> Double {
        let v = min(1, max(0, c))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func f(_ t: Double) -> Double {
        t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116
    }

    private static func finv(_ t: Double) -> Double {
        t * t * t > 216.0 / 24389 ? t * t * t : (116 * t - 16) * 27 / 24389
    }
}
