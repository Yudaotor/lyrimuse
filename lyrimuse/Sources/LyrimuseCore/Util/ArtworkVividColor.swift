import CoreGraphics
import Foundation

/// 封面里有彩色的那部分取一种颜色,调成深底上看得清的颜色。换歌翻牌那条歌名前的音符、灵动岛进度线用它:封面平均色
/// (强调色的来源)往往是一片灰米色,做点缀颜色不够。
///
/// 缩到 64×64,只看饱和度 ≥ 0.35、亮度 ≥ `Tone.minBrightness` 的像素,按色相分 24 格加权(`Tone.weighsBrightness`),
/// 取最重的连续 `2 × Tone.hueSpread + 1` 格的加权平均色;这些像素占不到 2% 就算没有(nil,调用方画白)。封面大部分没有
/// 颜色时(`Tone.neutralShare`)不挑点缀色,取整张的平均色、只留一点冷暖。再按 `Tone`
/// 定 HSL 饱和度和亮度,最后跟强调色同一道对比修正:对「封面平均色 × (1 − 压暗)」那块估计底色拉开 `Tone.minContrast`
/// (`LocalPlaybackSource.accentAgainstStroke`)。压暗跟卡片背景同一个量法(`NotchBackdropTone.overlayOpacity`,亮封面压得
/// 更深),别写成固定的 `notchCoverArtOverlayOpacity`:白封面上会把底色估亮一倍,颜色被往白里提成粉彩。
public enum ArtworkVividColor {
    public static let side = 64
    private static let minSaturation = 0.35
    private static let hueBins = 24
    private static let minShare = 0.02
    /// 彩度(最大通道 − 最小通道)不到这么多的像素算没有颜色:黑、白、灰,和只染了一层色调的暗部。
    private static let neutralChroma = 0.12
    /// 封面大部分没有颜色时,平均色的 HSL 饱和度最多留这么多:暖棕调的暗照片是暖灰,不是棕。
    private static let neutralMaxSaturation = 0.2

    /// 取到色相之后调成什么样。
    public struct Tone: Equatable, Sendable {
        /// 取色相时看最重格两侧各几格。
        public var hueSpread: Int
        public var minBrightness: Double
        /// 按「饱和度 × 亮度」加权(偏向最亮最艳的那一小块);否则只按饱和度(偏向占地方最多的那片颜色)。
        public var weighsBrightness: Bool
        public var saturationRange: ClosedRange<Double>
        public var lightness: Double
        public var minContrast: Double
        /// 没有颜色的像素(`neutralChroma`)占到这么多时,取整张的平均色(饱和度最多 `neutralMaxSaturation`、亮度 `lightness`),
        /// 不挑点缀色:黑白、灰调、暗底配一小块彩色的封面,线是灰的。nil = 不做这一步。见 05 章决策 115。
        public var neutralShare: Double? = nil

        /// 音符色:封面里最鲜艳的那种色相(相邻三格、按饱和度 × 亮度),深底上读得清的亮色(饱和度 0.6~0.92、
        /// 亮度 0.74、对比 4.5:1)。
        public static let note = Tone(hueSpread: 1, minBrightness: 0.3, weighsBrightness: true,
                                      saturationRange: 0.6...0.92, lightness: 0.74, minContrast: 4.5)
        /// 进度线:封面大片的那种色相(连续 7 格即 105°、只按饱和度、暗到 0.15 的像素也算),蓝紫混洋红的封面取到紫,
        /// 不是最亮的那块洋红。饱和度 0.6~0.75、亮度在纯色那一档(0.5)。对比只留 2:1:提亮是往白里混,3:1 在中灰的
        /// 封面底上就会把红提成粉色;2:1 只在真快看不见时(深蓝在黑底上)提一点。
        public static let deep = Tone(hueSpread: 3, minBrightness: 0.15, weighsBrightness: false,
                                      saturationRange: 0.6...0.75, lightness: 0.5, minContrast: 2, neutralShare: 0.85)
    }

    /// 居中裁方、高质量缩到 `side × side`(`ArtworkThumbnail.squareBitmap`)再取色。建不出来或没有够鲜艳的颜色返回 nil。
    public static func color(image: CGImage, tone: Tone = .note) -> (r: Double, g: Double, b: Double)? {
        guard let small = ArtworkThumbnail.squareBitmap(from: image, pixelSide: side),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(small, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? color(rgba: rgba, tone: tone) : nil
    }

    /// `rgba`:逐像素 RGBA 各一字节(封面不透明,alpha 不看)。
    public static func color(rgba: [UInt8], tone: Tone = .note) -> (r: Double, g: Double, b: Double)? {
        let pixels = rgba.count / 4
        guard pixels > 0 else { return nil }
        var colored: [ColoredPixel] = []
        var meanR = 0.0, meanG = 0.0, meanB = 0.0
        var neutral = 0
        for pixel in 0..<pixels {
            let r = Double(rgba[pixel * 4]) / 255
            let g = Double(rgba[pixel * 4 + 1]) / 255
            let b = Double(rgba[pixel * 4 + 2]) / 255
            meanR += r
            meanG += g
            meanB += b
            let maxC = max(r, g, b), minC = min(r, g, b)
            if maxC - minC < neutralChroma { neutral += 1 }
            let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
            guard saturation >= minSaturation, maxC >= tone.minBrightness else { continue }
            let bin = Int(hue(r: r, g: g, b: b, maxC: maxC, minC: minC) * Double(hueBins)) % hueBins
            colored.append(ColoredPixel(r: r, g: g, b: b, weight: tone.weighsBrightness ? saturation * maxC : saturation,
                                        bin: bin))
        }
        let lifted: (r: Double, g: Double, b: Double)
        if let share = tone.neutralShare, Double(neutral) / Double(pixels) >= share {
            let hsl = toHSL(r: meanR / Double(pixels), g: meanG / Double(pixels), b: meanB / Double(pixels))
            lifted = fromHSL(h: hsl.h, s: min(hsl.s, neutralMaxSaturation), l: tone.lightness)
        } else {
            guard let window = heaviestWindow(colored, spread: tone.hueSpread),
                  Double(window.hits) / Double(pixels) >= minShare else { return nil }
            let hsl = toHSL(r: window.sumR / window.weight, g: window.sumG / window.weight, b: window.sumB / window.weight)
            let saturation = min(max(hsl.s, tone.saturationRange.lowerBound), tone.saturationRange.upperBound)
            lifted = fromHSL(h: hsl.h, s: saturation, l: tone.lightness)
        }
        let overlay = NotchBackdropTone.bright(rgba: rgba)?.overlayOpacity ?? LocalPlaybackSource.notchCoverArtOverlayOpacity
        let dim = (1 - overlay) / Double(pixels)
        return LocalPlaybackSource.accentAgainstStroke(
            r: lifted.r, g: lifted.g, b: lifted.b,
            strokeR: meanR * dim, strokeG: meanG * dim, strokeB: meanB * dim,
            minContrast: tone.minContrast)
    }

    /// 过了饱和度、亮度两道门的像素。
    private struct ColoredPixel {
        var r, g, b, weight: Double
        var bin: Int
    }

    /// 选中的连续几格:加权和、像素数。
    private struct HueWindow {
        var weight = 0.0, sumR = 0.0, sumG = 0.0, sumB = 0.0
        var hits = 0
    }

    /// 按色相分 `hueBins` 格加权,取最重的连续 `2 × spread + 1` 格。一个像素都没有返回 nil。
    private static func heaviestWindow(_ colored: [ColoredPixel], spread: Int) -> HueWindow? {
        var weight = [Double](repeating: 0, count: hueBins)
        for p in colored { weight[p.bin] += p.weight }
        let spread = min(max(spread, 0), (hueBins - 1) / 2)
        func bins(around bin: Int) -> [Int] {
            (-spread...spread).map { (bin + $0 + hueBins) % hueBins }
        }
        var best = -1
        var bestWeight = 0.0
        for bin in 0..<hueBins {
            let w = bins(around: bin).reduce(0.0) { $0 + weight[$1] }
            if w > bestWeight {
                bestWeight = w
                best = bin
            }
        }
        guard best >= 0 else { return nil }
        let inWindow = Set(bins(around: best))
        var window = HueWindow()
        for p in colored where inWindow.contains(p.bin) {
            window.weight += p.weight
            window.sumR += p.r * p.weight
            window.sumG += p.g * p.weight
            window.sumB += p.b * p.weight
            window.hits += 1
        }
        return window
    }

    /// 色相,0..<1。
    private static func hue(r: Double, g: Double, b: Double, maxC: Double, minC: Double) -> Double {
        let delta = maxC - minC
        guard delta > 0 else { return 0 }
        let h: Double
        switch maxC {
        case r: h = (g - b) / delta + (g < b ? 6 : 0)
        case g: h = (b - r) / delta + 2
        default: h = (r - g) / delta + 4
        }
        return h / 6
    }

    private static func toHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        guard maxC > minC else { return (0, 0, l) }
        let delta = maxC - minC
        let s = l > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC)
        return (hue(r: r, g: g, b: b, maxC: maxC, minC: minC), s, l)
    }

    private static func fromHSL(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t.truncatingRemainder(dividingBy: 1)
            if t < 0 { t += 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }
}
