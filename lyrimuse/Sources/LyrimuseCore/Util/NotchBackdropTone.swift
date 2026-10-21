import CoreGraphics
import Foundation

/// 灵动岛「跟随封面」背景那张模糊图里较亮那部分的颜色:最亮 10% 像素的平均色(0~1,sRGB,压暗之前)。
/// 歌词落在封面亮区时,看得清看不清取决于这一块,不是整张图的均值。背景压暗多少(`overlayOpacity`)和
/// 字色的对比度检查都按它算。见 05 章决策 84。
public struct NotchBackdropTone: Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Rec.709 luma(gamma 空间),跟 `accentForDarkBackdrop` 的亮度地板同一个量法。
    public var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// 这张背景该叠多深的黑色压暗,见 `LocalPlaybackSource.notchCoverArtOverlayOpacity(brightLuma:)`。
    public var overlayOpacity: Double { LocalPlaybackSource.notchCoverArtOverlayOpacity(brightLuma: luma) }

    /// 取亮区时把图缩到的边长:模糊图本来就没有细节,24×24 足够分出亮区,解码量可以忽略。
    public static let sampleSide = 24

    /// 最亮的这一比例像素算「亮区」。
    public static let brightShare = 0.1

    /// RGBA 8 位像素(不透明图,预乘与否结果相同)里最亮 `brightShare` 的平均色。没有像素时为 nil。纯函数,selftest 覆盖。
    public static func bright(rgba: [UInt8]) -> NotchBackdropTone? {
        let count = rgba.count / 4
        guard count > 0 else { return nil }
        var pixels: [(luma: Double, r: Double, g: Double, b: Double)] = []
        pixels.reserveCapacity(count)
        for i in 0..<count {
            let r = Double(rgba[i * 4]) / 255, g = Double(rgba[i * 4 + 1]) / 255, b = Double(rgba[i * 4 + 2]) / 255
            pixels.append((0.2126 * r + 0.7152 * g + 0.0722 * b, r, g, b))
        }
        pixels.sort { $0.luma > $1.luma }
        let top = pixels.prefix(max(1, Int((Double(count) * brightShare).rounded())))
        let n = Double(top.count)
        return NotchBackdropTone(r: top.reduce(0) { $0 + $1.r } / n,
                                 g: top.reduce(0) { $0 + $1.g } / n,
                                 b: top.reduce(0) { $0 + $1.b } / n)
    }

    /// 把模糊图缩到 `sampleSide` 见方再取亮区。会解一次图,别在主线程调。
    public static func bright(cgImage: CGImage) -> NotchBackdropTone? {
        let side = sampleSide
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let buffer = UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: side * side * 4),
                                         count: side * side * 4)
        return bright(rgba: Array(buffer))
    }
}
