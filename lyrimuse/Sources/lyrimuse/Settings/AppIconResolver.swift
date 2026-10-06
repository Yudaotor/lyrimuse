import AppKit
import SwiftUI

/// 按 bundle identifier 查真实 App 图标——NSWorkspace 找到 .app 再取图标,最好认,还不用
/// 自带任何商标素材(改图标时定的取图标原则,见调用点)。
///
/// 从三处各自维护的同一段逻辑收拢到这里:「正在播放」面板来源角标
/// (原 `PlaybackCoordinator.resolvedPlayerIcon` 自己那份 `playerIconCache`)、引导页选
/// 播放器的图标卡片(`PlayerChoiceCard`)、设置页"已信任的其它播放器"列表。三处各写一遍、
/// 其中两处各自还维护一份独立缓存——统一到这一个地方,一份缓存全进程共用,免得三份实现
/// 慢慢长歪(其中一处忘了处理某种边界情况,另外两处不会跟着改)。
///
/// App 图标在进程生命周期内不会变,查一次够用一辈子,缓存不需要失效。
@MainActor
enum AppIconResolver {
    private static var cache: [String: NSImage] = [:]

    /// 空字符串(比如 `PlaybackPlayer.auto` 没有唯一固定的目标 App)直接返回 nil,
    /// 不去问 NSWorkspace——那样问到的是"哪个 App 声明了处理空 bundle id",没有意义。
    static func icon(forBundleID bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = fullBleedLegacyIcon(appURL: url).map(fittedToIconGrid)
            ?? NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }

    /// 只带老式 icns(没有 `CFBundleIconName`)、而且图铺满整张画布的 App,取它自己的 icns。
    /// 系统给这类图标套一层灰色圆角底板,原图缩在中间(Amazon Music 就是这样);其余情况返回 nil,
    /// 照旧用 NSWorkspace 的图标。
    private static func fullBleedLegacyIcon(appURL: URL) -> NSImage? {
        guard let bundle = Bundle(url: appURL),
              bundle.object(forInfoDictionaryKey: "CFBundleIconName") == nil,
              let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let image = bundle.image(forResource: file)
        else { return nil }
        return isFullBleed(image) ? image : nil
    }

    /// 四条边的中点都不透明 = 图铺满画布、没按 macOS 图标网格留边。
    private static func isFullBleed(_ image: NSImage) -> Bool {
        let n = 64
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        let edges = [(1, n / 2), (n - 2, n / 2), (n / 2, 1), (n / 2, n - 2)]
        return edges.allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.8 }
    }

    /// 铺满的图按 macOS 图标网格摆:1024 的画布里居中一块 824 的连续圆角方块(圆角 185.4),
    /// 跟别的 App 图标同样大小、同样的留边和圆角。
    private static func fittedToIconGrid(_ image: NSImage) -> NSImage {
        let side: CGFloat = 1024, body: CGFloat = 824
        let rect = CGRect(x: (side - body) / 2, y: (side - body) / 2, width: body, height: body)
        let clip = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: rect).cgPath
        return prerendered(size: NSSize(width: side, height: side)) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.addPath(clip)
            ctx.clip()
            image.draw(in: rect)
        }
    }

    /// 把一张图预先画成 16～512 像素的一组位图(点尺寸都是 `size`),显示时按实际像素挑最接近的那张。
    ///
    /// 不用按需绘制的 `NSImage(size:flipped:drawingHandler:)`:SwiftUI 只按布局尺寸把它画一次(24pt 画成 48×48
    /// 像素),`scaleEffect` 放大的是这张小图,Discord 预览里放大 1.22 倍的播放器角标就糊了。也不直接用随包那张
    /// 512 或 1024 像素的 PNG:缩到几十像素满是锯齿。最大 512 像素,够画到 256pt;这些图标最大画到 64pt。
    /// 画布用 Display P3:广色域的图(系统给的 App 图标就是)画进 sRGB 会发灰。
    nonisolated static func prerendered(size: NSSize, draw: (CGRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        let longest = max(size.width, size.height)
        guard longest > 0, let space = CGColorSpace(name: CGColorSpace.displayP3) else { return image }
        for pixels in [16, 32, 64, 128, 256, 512] {
            let scale = CGFloat(pixels) / longest
            guard let context = CGContext(
                data: nil, width: max(1, Int((size.width * scale).rounded())),
                height: max(1, Int((size.height * scale).rounded())), bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            context.scaleBy(x: scale, y: scale)
            context.interpolationQuality = .high
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            draw(CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            guard let cgImage = context.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = size
            image.addRepresentation(rep)
        }
        return image
    }

    /// 随包的品牌图(Contents/Resources/ 里的 PNG)照原样预先画好,见上一个函数。
    nonisolated static func prerendered(_ image: NSImage) -> NSImage {
        prerendered(size: image.size) { image.draw(in: $0) }
    }

    /// 装不了 App 就没图标可查时的兜底:随 App 一起打包的静态品牌图。
    ///
    /// 现象是:换一台只装了 Apple Music/QQ 音乐的机器,「播放器」卡片网格里
    /// 网易云音乐/酷狗音乐/Spotify 全变成了一个纯色块+SF Symbol 音符,"看着都跟坏了一样"。
    /// 根因是 `PlayerChoiceCard` 原来直接把 `icon(forBundleID:)` 查不到(=这台机器没装那个
    /// App)当"没图标"处理,退回占位——但这几个播放器的品牌图标本身跟"这台机器装没装"没
    /// 关系,是固定的。跟 `SettingsView.swift` 里 `platformIcon`(YouTube Music/Spotify 网页
    /// 播放器卡)同一个思路、同一批已经打包进 Contents/Resources/ 的 PNG(/
    /// 那两次的先例:取自本机已安装 App 的 AppIcon.icns,sips 转 1024×1024 PNG,
    /// 不是从网上抓的品牌资源)——网易云音乐/酷狗音乐/QQ 音乐这三张是这次新加的
    /// (NeteaseIcon.png/KugouIcon.png/QQMusicIcon.png),Spotify 直接复用已有的
    /// SpotifyIcon.png,不用再拷一份。
    ///
    /// 用 `Bundle.main`(不是 `Bundle.module`)加载——理由跟 `platformIcon` 那边一致:
    /// 资源是 build.sh 拷进 Contents/Resources/ 的,不是走 SwiftPM 的资源打包机制。
    static func icon(bundledResourceName name: String) -> NSImage? {
        let key = "bundled:" + name
        if let cached = cache[key] { return cached }
        guard let path = Bundle.main.path(forResource: name, ofType: "png"),
              let loaded = NSImage(contentsOfFile: path) else { return nil }
        // 打包图取自那个 App 的 icns,铺满的那种(AmazonMusicIcon)同样按图标网格摆,跟装了时一个样子。
        let image = isFullBleed(loaded) ? fittedToIconGrid(loaded) : prerendered(loaded)
        cache[key] = image
        return image
    }
}
