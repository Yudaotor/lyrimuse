import AppKit

/// 灵动岛没有曲目时左耳那枚 App 图标的**位图缓存**(2026-09-07,用户报「左边那个图标很有锯齿感」)。
///
/// 第一版直接 `Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()` 缩到 26pt:
/// `.icns` 里最大那张 1024px 位图被 SwiftUI 一步缩到 ~52px,走的是普通线性采样 —— 二十倍的
/// 缩放没有面积平均,圆角与音符边缘就是一圈台阶。这里改成**按目标像素尺寸预先光栅化一次**:
/// 在 px×px 的 CoreGraphics 位图上用 `.high` 插值把源图画进去(AppKit 会按目标像素挑最合适的
/// 那档位图再缩,Lanczos 级别的重采样把边缘摊平),视图层拿 `Image(decorative:scale:)` 逐像素
/// 贴上去、不再有任何运行期缩放。同一个像素边长只算一次;图标在进程生命周期内不会变,缓存
/// 不需要失效。key 用像素边长而不是 pt:2x / 3x 屏各自一份,外接 1x 屏也对。
///
/// 2026-09-11 起同一套光栅化也给「发现新播放器」提示用:被动提示挂着时左耳换成**那个播放器**的图标
/// (`NotchIdleEarIconHost`),同样的 26pt、同样的锯齿问题,所以走同一个函数,只是源图换成
/// `AppIconResolver.icon(forBundleID:)`、缓存 key 多一段 bundle id。
@MainActor
enum NotchIdleAppIcon {
    private static var cache: [String: CGImage] = [:]

    /// `pixelSide` = pt 边长 × 显示倍率,取整。取不到位图(理论上不会)返回 nil,调用方退回原图。
    static func bitmap(pixelSide: Int) -> CGImage? {
        guard let source = NSApplication.shared.applicationIconImage else { return nil }
        return bitmap(of: source, cacheKey: "app", pixelSide: pixelSide)
    }

    /// 任意一张 App 图标按目标像素边长预先光栅化一次。`cacheKey` 区分源图(App 图标在进程生命周期内不变,
    /// 按 bundle id 分开缓存即可),像素边长再叠进 key:2x / 3x 屏各自一份。
    static func bitmap(of source: NSImage, cacheKey: String, pixelSide: Int) -> CGImage? {
        guard pixelSide > 0 else { return nil }
        let key = "\(cacheKey)@\(pixelSide)"
        if let hit = cache[key] { return hit }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelSide, height: pixelSide, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        gc.imageInterpolation = .high
        source.draw(in: CGRect(x: 0, y: 0, width: pixelSide, height: pixelSide),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        cache[key] = image
        return image
    }
}
