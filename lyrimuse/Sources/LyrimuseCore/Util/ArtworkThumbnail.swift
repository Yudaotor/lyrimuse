import CoreGraphics
import Foundation

/// 小尺寸封面缩略图的**重采样**(2026-09-09,用户圈图:「这个灵动岛小图怎么和大图长得不一样,上面有黑斑,
/// 并且展开的时候黑斑还会动」——陶喆《I'm O.K.》,一张黄底黑点的半调网点封面)。
///
/// ## 症状的来路
///
/// 各处小封面原来都是 `Image(nsImage:).resizable().scaledToFill()` 直接缩:600px 的源图被 Core Animation
/// 一步缩到 46px(左耳 23pt @2x),走的是普通线性采样 —— 十三倍的缩放**没有面积平均**,每个目标像素只看
/// 源图里一两个点。对普通照片这只是糊一点;对半调网点(黑点阵列)这是**摩尔纹**:黑点阵的频率跟采样网格
/// 打拍,拍出来的就是几块跟原图毫无关系的大黑斑。展开 / 收起动画里卡片尺寸每帧变、这枚缩略图落在亚像素
/// 上的相位跟着变,黑斑的位置于是"会动"。离屏复现(scratchpad thumbtest,同一张封面缩到 46px):
/// 线性采样两帧相位差 0.37px 黑斑图案全换;`.high` 重采样后跟大图一致(网点被平均成灰调)。
///
/// ## 修法
///
/// 跟 `NotchIdleAppIcon`(2026-09-07 修左耳 App 图标锯齿)同一招:**按目标像素尺寸预先光栅化一次**,
/// 在 px×px 的 CoreGraphics 位图上用 `.high` 插值把源图画进去(Lanczos 级别的重采样,大比例缩小时做面积
/// 平均),视图层拿 `Image(decorative:scale:)` 逐像素贴上去、不再有任何运行期缩放 —— 相位不再变,黑斑
/// 既不会有、也不会动。这里是纯函数部分(CGImage → CGImage),放 Core 是为了让 selftest 能拿一张合成的
/// 1px 黑白棋盘格直接断言"缩出来是灰的、不是黑白噪点";按 NSImage 缓存那层在 App target
/// (`ArtworkThumbnailCache`)。
///
/// 耗时:600px JPEG 源缩到 46 / 64 / 88px 各约 4~9ms(含解码,scratchpad thumbtime 实测),每张封面
/// 每个尺寸只算一次;歌词窗口那张 460pt 大图接近原生尺寸,不走这里。
public enum ArtworkThumbnail {
    /// aspect-fill(居中裁成正方形)+ 高质量重采样,输出 `pixelSide × pixelSide` 的 sRGB 位图。
    /// 源图非正方形时裁掉长边两头,跟视图层原来 `.scaledToFill()` + 方形 `.frame` + `clipShape` 的
    /// 可见区域一致。任何一步建不出来返回 nil,调用方退回原来的运行期缩放。
    public static func squareBitmap(from source: CGImage, pixelSide: Int) -> CGImage? {
        guard pixelSide > 0, source.width > 0, source.height > 0 else { return nil }
        let w = source.width, h = source.height
        let side = min(w, h)
        let square: CGImage
        if side == w && side == h {
            square = source
        } else {
            let crop = CGRect(x: CGFloat((w - side) / 2), y: CGFloat((h - side) / 2),
                              width: CGFloat(side), height: CGFloat(side))
            guard let cropped = source.cropping(to: crop) else { return nil }
            square = cropped
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelSide, height: pixelSide, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: CGFloat(pixelSide), height: CGFloat(pixelSide)))
        return ctx.makeImage()
    }
}
