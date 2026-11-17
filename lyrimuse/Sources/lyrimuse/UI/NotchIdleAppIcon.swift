import AppKit
import LyrimuseCore
import SwiftUI

/// 灵动岛没有曲目时左耳那枚 App 图标的**位图缓存**(现象是「左边那个图标很有锯齿感」)。
///
/// 别直接 `Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()` 缩到 26pt:
/// `.icns` 里最大那张 1024px 位图被 SwiftUI 一步缩到 ~52px,走的是普通线性采样 —— 二十倍的
/// 缩放没有面积平均,圆角与音符边缘就是一圈台阶。这里改成**按目标像素尺寸预先光栅化一次**:
/// 在 px×px 的 CoreGraphics 位图上用 `.high` 插值把源图画进去(AppKit 会按目标像素挑最合适的
/// 那档位图再缩,Lanczos 级别的重采样把边缘摊平),视图层拿 `Image(decorative:scale:)` 逐像素
/// 贴上去、不再有任何运行期缩放。同一个像素边长只算一次;图标在进程生命周期内不会变,缓存
/// 不需要失效。key 用像素边长而不是 pt:2x / 3x 屏各自一份,外接 1x 屏也对。
///
/// 同一套光栅化也给「发现新播放器」提示用:被动提示挂着时左耳换成**那个播放器**的图标
/// (`NotchIdleEarIconHost`),同样的 26pt、同样的锯齿问题,所以走同一个函数,只是源图换成
/// `AppIconResolver.icon(forBundleID:)`、缓存 key 多一段 bundle id。Lyrimuse 自己那枚走 `NotchOwnAppIcon`。
@MainActor
enum NotchIdleAppIcon {
    private static var cache: [String: CGImage] = [:]

    /// 任意一张 App 图标按目标像素边长预先光栅化一次。`cacheKey` 区分源图(App 图标在进程生命周期内不变,
    /// 按 bundle id 分开缓存即可),像素边长再叠进 key:2x / 3x 屏各自一份。
    static func bitmap(of source: NSImage, cacheKey: String, pixelSide: Int) -> CGImage? {
        // 占位图不进缓存:按 bundle id 缓存下来,读好之后也一直是空的。
        guard pixelSide > 0, source !== AppIconCache.pendingPlaceholder else { return nil }
        let key = "\(cacheKey)@\(pixelSide)"
        if let hit = cache[key] { return hit }
        guard let image = rasterize(source, pixelSide: pixelSide) else { return nil }
        cache[key] = image
        return image
    }

    /// 把 `source` 画进 px×px 的位图。只碰传进来的图和自己建的画布,哪条线程上调都行。
    nonisolated static func rasterize(_ source: NSImage, pixelSide: Int) -> CGImage? {
        guard pixelSide > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
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
        return ctx.makeImage()
    }
}

/// Lyrimuse 自己的图标(没有曲目时左耳那枚):包里的 `AppIcon.icns` 在后台读、按像素边长光栅化,好了回主线程放进
/// `bitmaps`,观察它的视图跟着重画;还没好时 `bitmap(pixelSide:)` 返回 nil,那一格先空着。
///
/// 别在主线程上读 `NSApplication.applicationIconImage`:进程里第一次读要同步等 iconservicesagent 回话,
/// 刚登录、系统还忙的机器上能卡住十几秒(05 章决策 154)。
@MainActor
final class NotchOwnAppIcon: ObservableObject {
    static let shared = NotchOwnAppIcon()

    @Published private(set) var bitmaps: [Int: CGImage] = [:]
    /// 每个像素边长只派一次后台读;读不出来(包里没有图标)就一直空着,不反复派。
    private var reads: [Int: SingleFlightBackgroundRead<CGImage?>] = [:]

    /// 有就返回;没有就派一次后台读,这次返回 nil。
    func bitmap(pixelSide: Int) -> CGImage? {
        if let hit = bitmaps[pixelSide] { return hit }
        guard pixelSide > 0, reads[pixelSide] == nil else { return nil }
        let read = SingleFlightBackgroundRead<CGImage?>()
        reads[pixelSide] = read
        read.start(priority: .userInitiated, read: {
            AppIconResolver.bundledOwnIcon().flatMap { NotchIdleAppIcon.rasterize($0, pixelSide: pixelSide) }
        }) { [weak self] image in
            if let image { self?.bitmaps[pixelSide] = image }
        }
        return nil
    }
}

/// `NotchOwnAppIcon` 的那一格:位图到了才画,之前空着(外面的 frame 照旧占位,布局不跳)。
struct NotchOwnAppIconImage: View {
    @ObservedObject private var icon = NotchOwnAppIcon.shared
    let pixelSide: Int
    let scale: CGFloat

    var body: some View {
        if let bitmap = icon.bitmap(pixelSide: pixelSide) {
            Image(decorative: bitmap, scale: scale)
        }
    }
}
