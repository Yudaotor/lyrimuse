import AppKit
import ImageIO
import SwiftUI

// 设置页里那一小片「桌面」—— 真实壁纸的样图,以及取样/缩放它的那点缓存。
//
// (从 OverlayLyricsCanvas.swift 拆出来。那个文件里另一半是悬浮歌词在**顶部钉条**
//  里的简化渲染 `OverlayLyricsCanvas`,而钉条 `OverlayPreviewBar` 在悬浮歌词改成编辑台之后
//  就没有任何实例化点了 —— 两个一起删掉,只留下这一半:它有三个活着的消费方,见下。)

/// 一片「桌面」:真实壁纸的样图,读不到就退回表示透明的棋盘格。
///
/// 抽成独立视图是第七步的产物。在那之前这段代码只长在
/// `OverlayLyricsCanvas.desktopUnderlay` 里,而编辑台舞台在窗外另画了一份(按舞台宽度裁的
/// 壁纸 + 高斯虚化)。两份各按各的宽度做 scaledToFill,缩放比对不上,窗口边缘上能看到同一张
/// 壁纸出现两次——窗外那圈虚化当初就是为了藏这道接缝;更要命的是拖宽度调整条时窗内那份的
/// 缩放比跟着变,壁纸内容跟着呼吸。第七步之后整块编辑台只画**一张**(按舞台宽度),窗口那块
/// 把自己的关掉让它透上来,虚化跟着一起删了:接缝不存在了,自然也没什么要藏。
///
/// 两个消费方(钉条自带的那份 / 编辑台舞台那张)共用这一份实现,别在任何一侧再手搓一遍——
/// 尤其是棋盘格:格子大小/相位/配色只要有一处不同,两块画面一对比就露馅(第五步那版编辑台
/// 在读不到壁纸时宁可什么都不画,正是因为当时没有这么一份共用实现可用)。
@MainActor
struct OverlayDesktopSurface: View {
    @ObservedObject private var wallpaper = DesktopWallpaperImages.shared

    var body: some View {
        Group {
            switch wallpaper.sample {
            case .some(.some(let image)):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            case .some(.none):
                checkerboard
            case .none:
                Color.clear
            }
        }
        .onAppear { wallpaper.loadSample() }
    }

    private var checkerboard: some View {
        // 拿不到壁纸(读不到文件/没有权限)就退回棋盘格 —— 它至少明确表达了
        // 「这一块是透明的、透出的是底下的东西」,不会像纯色那样把人误导成不透明。
        Canvas { context, size in
            let cell: CGFloat = 8
            let cols = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            for row in 0 ..< rows {
                for col in 0 ..< cols where (row + col).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                        width: cell, height: cell)
                    context.fill(Path(rect), with: .color(.gray.opacity(0.22)))
                }
            }
        }
    }
}

/// 设置页预览垫的两张壁纸图(`DesktopWallpaperSample`、`DesktopWallpaperTopBand`),各在后台读一次,读完回主线程换上。
/// 壁纸文件可能在网络卷上、或是 iCloud 里没下载到本机的文件,打开就要等,不能在 body 里同步读。见 04 章决策 113。
/// 只读一次,换了壁纸要等下次启动。
@MainActor
final class DesktopWallpaperImages: ObservableObject {
    static let shared = DesktopWallpaperImages()

    /// nil = 还没读完(画空白);`.some(nil)` = 读过了、读不到(退回占位)。
    @Published private(set) var sample: NSImage??
    @Published private(set) var topBand: NSImage??
    private var sampleStarted = false
    private var topBandStarted = false
    private nonisolated static let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.wallpaper-images", qos: .userInitiated)

    private init() {}

    func loadSample() {
        guard !sampleStarted else { return }
        sampleStarted = true
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            sample = .some(nil)
            return
        }
        Self.queue.async {
            let thumb = DesktopWallpaperSample.thumbnail(url: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    DesktopWallpaperImages.shared.sample = .some(thumb.map {
                        // 点尺寸按 2x 折回去:占 640pt 宽(原图本来就不到 1280px 时按实际像素 / 2)。
                        NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / 2, height: CGFloat($0.height) / 2))
                    })
                }
            }
        }
    }

    func loadTopBand() {
        guard !topBandStarted else { return }
        topBandStarted = true
        // 菜单栏在主屏(第一块屏)上;`NSScreen.main` 是键盘焦点所在的屏,多屏时可能是另一块。
        guard let screen = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            topBand = .some(nil)
            return
        }
        let screenW = Double(screen.frame.width), screenH = Double(screen.frame.height)
        let backing = Double(screen.backingScaleFactor)
        Self.queue.async {
            let band = DesktopWallpaperTopBand.render(url: url, screenW: screenW, screenH: screenH, backing: backing)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    DesktopWallpaperImages.shared.topBand = .some(band.map {
                        NSImage(cgImage: $0.image, size: NSSize(width: screenW, height: $0.height))
                    })
                }
            }
        }
    }
}


/// 屏幕最上面那一条桌面:壁纸按它在带菜单栏那块屏幕上的铺法(等比铺满、居中)缩放之后,最上面
/// `bandHeight` 高、整屏宽的那一条,点尺寸就是屏幕上的点尺寸。菜单栏预览垫它,透出来的颜色才跟真菜单栏
/// 那一段对得上;别改回拿 `DesktopWallpaperSample` 按预览宽度放大 —— 那样露出的是壁纸上面四分之一,
/// 上深下浅的壁纸会浅出一大截。在后台读一次(`DesktopWallpaperImages.loadTopBand`)。见 06 章决策 77。
enum DesktopWallpaperTopBand {
    /// 留多高(pt)。要盖住菜单栏预览整块舞台(仿菜单栏条 + 下沿留白 + 宽度通道)。
    static let bandHeight: CGFloat = 96

    /// 读壁纸文件、画出那一条,哪个线程都能调;屏幕尺寸(点)和像素密度由调用方在主线程上取好。`height` 是这一条的点高。
    static func render(url: URL, screenW: Double, screenH: Double, backing: Double) -> (image: CGImage, height: Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }
        guard screenW > 0, screenH > 0 else { return nil }
        // 铺满屏幕时原图每个像素占几个点;解一张够屏幕像素密度的缩略图,原图更小就按原图。
        let pointsPerPixel = max(screenW / pixelWidth, screenH / pixelHeight)
        let longSide = max(pixelWidth, pixelHeight)
        let maxPixel = min(longSide, longSide * pointsPerPixel * backing)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // 缩略图里每个点几个像素;铺满后超出屏幕的部分两边各裁一半。
        let pixelsPerPoint = Double(thumb.width) / (pixelWidth * pointsPerPixel)
        let offsetX = (pixelWidth * pointsPerPixel - screenW) / 2
        let offsetY = (pixelHeight * pointsPerPixel - screenH) / 2
        let bandH = min(Double(bandHeight), screenH)
        let outW = Int((screenW * pixelsPerPoint).rounded()), outH = Int((bandH * pixelsPerPoint).rounded())
        guard outW > 0, outH > 0,
              let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // 画进一张只有这一条大的位图:`CGImage.cropping` 出来的图还攥着整张缩略图的像素。
        // CGContext 原点在左下:把缩略图往左挪 offsetX、顶边对齐到这一条的顶边。
        let drawW = Double(thumb.width), drawH = Double(thumb.height)
        let originX = -offsetX * pixelsPerPoint
        let originY = Double(outH) - (drawH - offsetY * pixelsPerPoint)
        ctx.interpolationQuality = .high
        ctx.draw(thumb, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))
        guard let band = ctx.makeImage() else { return nil }
        return (band, bandH)
    }
}

/// 预览里垫在悬浮歌词卡底下的那张桌面壁纸。
///
/// 只读一次(`DesktopWallpaperImages.loadSample`,在后台)并缩到预览用得着的尺寸:壁纸动辄几千像素,每次渲染都去读原图既慢又占内存。
/// 代价是换了壁纸要等下次启动才更新 —— 对一个"演示半透明效果"的垫底图来说够用了。
enum DesktopWallpaperSample {
    /// 缩到多宽(pt)。预览舞台的宽度在这附近,按 2x 出像素,Retina 上不糊。
    private static let targetWidth: CGFloat = 640

    /// 用 ImageIO 直接解出一张缩略图,原图从头到尾不整张解码、也不留在内存里。
    ///
    /// 原来是 `NSImage(contentsOf:)` + `NSImage(size:flipped:drawingHandler:)`:后者是**懒绘制**,
    /// 闭包攥着原图,每次需要重新光栅化都从原图再画一遍 —— 系统壁纸常见 6K,"缩到 640"
    /// 实际一个字节都没省下来。
    static func thumbnail(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }
        // 缩略图的上限按长边给;要的是"宽 = 640pt × 2",竖版壁纸长边是高,按比例换算。
        let wantWidth = min(pixelWidth, Double(targetWidth) * 2)
        let maxPixel = wantWidth * max(1, pixelHeight / pixelWidth)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
