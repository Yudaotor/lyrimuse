import CoreGraphics
import CoreImage
import Foundation

/// 封面「感知指纹」(aHash):判断两张图像感知上是不是同一张封面。
///
/// 跟 collector 侧 `coverquality.go` 的 `coverFingerprint` 同一套算法(8×8 灰度网格、
/// 每格跟全图均值比,大于均值置 1)——两边各自独立实现,不要求逐位输出相同,只要求各自
/// 都能可靠判断"是不是同一张"(两边用各自的渲染管线取灰度值,数值域本来就不一样,没必要
/// 也没办法对齐位模式)。
///
/// 用途:动态封面下载完成之后,拿视频**中段**的真实一帧跟当前显示的封面比一次(见
/// `MotionCoverStore`)。这一步补的是 collector 那边够不到的坑——它只能比 Apple 给的
/// `previewFrame`,而那常常是视频最开头一帧;有些专辑的动态封面开场是"揭幕"特效(逐渐
/// 聚拢的九宫格拼贴一类),首帧跟静态封面天差地别,播到中段才收拢成跟封面一致的画面
/// (实测 Ariana Grande《Positions (Deluxe)》:首帧距离 41,视频中段距离 0)。collector
/// 拿不到解码后的视频帧,这一步只能放在能拿到本地视频文件的 App 侧做。
public enum CoverFingerprint {
    /// 判"同一张图"的汉明距离上限(满分 64)。跟 collector 侧
    /// `motionCoverFingerprintMaxDistance` 沿用同一个数值——算法同源(都是 8×8 Rec.601
    /// 亮度 aHash),校准依据(0～8 正例、17 起才是真反例)见那边注释的完整实测数据,这里
    /// 不重复。
    public static let motionCoverMaxDistance = 12

    private static let side = 8

    // CIContext 创建不便宜、且线程安全,进程级复用一份 —— 跟
    // LocalPlaybackSource.averageHexContext 同一个理由/写法。
    nonisolated(unsafe) private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// 算一张图的指纹。
    public static func hash(of image: CGImage) -> UInt64 {
        hash(of: CIImage(cgImage: image))
    }

    /// 缩到 8×8 灰度,每格跟全图均值比,大于均值置 1。
    ///
    /// 每一格单独起一次 `CIAreaAverage`(跟 `LocalPlaybackSource.computeAverageHex` 那处把
    /// 整张图塌缩成一个像素同一个技术,这里对 64 个子矩形各做一次)——必须让每个格子吃到
    /// 源图里对应区域的**全部**像素(箱式取平均),不能只采样一点,否则同一张图不同分辨率
    /// 的两个版本会算出差很远的指纹(跟 coverquality.go 头注同一段论证)。
    private static func hash(of ciImage: CIImage) -> UInt64 {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return 0 }
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return 0 }
        var cells = [Double](repeating: 0, count: side * side)
        for cy in 0..<side {
            for cx in 0..<side {
                let x0 = extent.minX + extent.width * CGFloat(cx) / CGFloat(side)
                let x1 = extent.minX + extent.width * CGFloat(cx + 1) / CGFloat(side)
                let y0 = extent.minY + extent.height * CGFloat(cy) / CGFloat(side)
                let y1 = extent.minY + extent.height * CGFloat(cy + 1) / CGFloat(side)
                let rect = CGRect(x: x0, y: y0, width: max(x1 - x0, 1), height: max(y1 - y0, 1))
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
                guard let output = filter.outputImage else { continue }
                var bitmap = [UInt8](repeating: 0, count: 4)
                context.render(
                    output, toBitmap: &bitmap, rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                // Rec.601 亮度,跟 collector coverFingerprint 同一套系数,理由同源(不是要
                // 对齐位模式,只是没必要另挑一套灰度公式)。
                cells[cy * side + cx] =
                    0.299 * Double(bitmap[0]) + 0.587 * Double(bitmap[1]) + 0.114 * Double(bitmap[2])
            }
        }
        let mean = cells.reduce(0, +) / Double(cells.count)
        var result: UInt64 = 0
        for (i, v) in cells.enumerated() where v > mean {
            result |= 1 << UInt64(i)
        }
        return result
    }

    /// 两个指纹的汉明距离(0…64)。
    public static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
