import CoreGraphics
import Foundation

/// 封面里最鲜艳的那种颜色,调成深底上读得清的亮色。换歌翻牌那条歌名前的音符用它:封面平均色(强调色的来源)往往是
/// 一片灰米色,做点缀颜色不够。
///
/// 缩到 64×64,只看饱和度 ≥ 0.35、亮度 ≥ 0.3 的像素,按色相分 24 格、以「饱和度 × 亮度」加权,取最重的相邻三格的
/// 加权平均色;这些像素占不到 2% 就算没有(nil,调用方画白)。再把 HSL 饱和度夹进 0.6~0.92、亮度定在 0.74,最后跟
/// 强调色同一道对比修正:对「封面平均色 × (1 − 压暗)」那块估计底色拉开 4.5:1(`LocalPlaybackSource.accentAgainstStroke`)。
public enum ArtworkVividColor {
    public static let side = 64
    private static let minSaturation = 0.35
    private static let minBrightness = 0.3
    private static let hueBins = 24
    private static let minShare = 0.02
    private static let saturationRange: ClosedRange<Double> = 0.6...0.92
    private static let lightness = 0.74
    private static let minContrast = 4.5

    /// 居中裁方、高质量缩到 `side × side`(`ArtworkThumbnail.squareBitmap`)再取色。建不出来或没有够鲜艳的颜色返回 nil。
    public static func color(image: CGImage) -> (r: Double, g: Double, b: Double)? {
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
        return drawn ? color(rgba: rgba) : nil
    }

    /// `rgba`:逐像素 RGBA 各一字节(封面不透明,alpha 不看)。
    public static func color(rgba: [UInt8]) -> (r: Double, g: Double, b: Double)? {
        let pixels = rgba.count / 4
        guard pixels > 0 else { return nil }
        var weight = [Double](repeating: 0, count: hueBins)
        var hits = [Int](repeating: 0, count: hueBins)
        var sumR = [Double](repeating: 0, count: hueBins)
        var sumG = [Double](repeating: 0, count: hueBins)
        var sumB = [Double](repeating: 0, count: hueBins)
        var meanR = 0.0, meanG = 0.0, meanB = 0.0
        for pixel in 0..<pixels {
            let r = Double(rgba[pixel * 4]) / 255
            let g = Double(rgba[pixel * 4 + 1]) / 255
            let b = Double(rgba[pixel * 4 + 2]) / 255
            meanR += r
            meanG += g
            meanB += b
            let maxC = max(r, g, b), minC = min(r, g, b)
            let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
            guard saturation >= minSaturation, maxC >= minBrightness else { continue }
            let bin = Int(hue(r: r, g: g, b: b, maxC: maxC, minC: minC) * Double(hueBins)) % hueBins
            let k = saturation * maxC
            weight[bin] += k
            hits[bin] += 1
            sumR[bin] += r * k
            sumG[bin] += g * k
            sumB[bin] += b * k
        }
        var best = -1
        var bestWeight = 0.0
        for bin in 0..<hueBins {
            let w = weight[(bin + hueBins - 1) % hueBins] + weight[bin] + weight[(bin + 1) % hueBins]
            if w > bestWeight {
                bestWeight = w
                best = bin
            }
        }
        guard best >= 0 else { return nil }
        let window = [(best + hueBins - 1) % hueBins, best, (best + 1) % hueBins]
        guard Double(window.reduce(0) { $0 + hits[$1] }) / Double(pixels) >= minShare else { return nil }
        let rawR = window.reduce(0.0) { $0 + sumR[$1] } / bestWeight
        let rawG = window.reduce(0.0) { $0 + sumG[$1] } / bestWeight
        let rawB = window.reduce(0.0) { $0 + sumB[$1] } / bestWeight
        let hsl = toHSL(r: rawR, g: rawG, b: rawB)
        let saturation = min(max(hsl.s, saturationRange.lowerBound), saturationRange.upperBound)
        let lifted = fromHSL(h: hsl.h, s: saturation, l: lightness)
        let dim = (1 - LocalPlaybackSource.notchCoverArtOverlayOpacity) / Double(pixels)
        return LocalPlaybackSource.accentAgainstStroke(
            r: lifted.r, g: lifted.g, b: lifted.b,
            strokeR: meanR * dim, strokeG: meanG * dim, strokeB: meanB * dim,
            minContrast: minContrast)
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
