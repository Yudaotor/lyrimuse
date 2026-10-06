import Foundation

/// 位图里哪几列有墨迹(透明度不为 0)。各行的透明度按位或进一行,再找头尾两个非 0 的列。
public enum BitmapInk {
    /// `alphaOffset`:透明度在一个像素里的第几个字节(单通道 0;RGBA 透明度在后 3)。整张全透明返回 nil。
    public static func columns(in bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                               bytesPerPixel: Int, alphaOffset: Int) -> Range<Int>? {
        guard width > 0, height > 0, bytes.count >= (height - 1) * bytesPerRow + width * bytesPerPixel else { return nil }
        var any = [UInt8](repeating: 0, count: width)
        any.withUnsafeMutableBufferPointer { acc in
            for y in 0..<height {
                let row = y * bytesPerRow + alphaOffset
                for x in 0..<width { acc[x] |= bytes[row + x * bytesPerPixel] }
            }
        }
        guard let first = any.firstIndex(where: { $0 != 0 }), let last = any.lastIndex(where: { $0 != 0 }) else { return nil }
        return first..<(last + 1)
    }
}
