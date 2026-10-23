import AppKit

// 「封面当图标」(`AppSettings.menuBarIconShowsArtwork`):菜单栏图标换成正在放的这首的专辑封面。
// 两处用到:图标独占那一格(`MenuBarStatusItem.showIcon`)和歌词旁那枚进度图标(`MenuBarProgressIcon`)。
// 没封面、广告期间画所选款式的图标。
//
// 占位尺寸只跟开关有关、跟这一刻有没有封面无关:封面是换歌后异步到的,尺寸跟着变的话每首歌多一次
// 状态栏项重建(见 `MenuBarStatusItem.present` 头注)。开着时这一格按款式图标和封面方块两者取大,
// 两种内容都在里面居中。「图标大小」(`MenuBarIconSize`)对字形和封面方块按同一比例缩放。
@MainActor
enum MenuBarIconArtwork {
    /// 「标准」大小下封面方块的边长,跟 SF 款 15pt 的字形、旁边系统图标一个量级。
    static let side: CGFloat = 16
    static let cornerRadius: CGFloat = 3.5
    /// 歌词旁那枚进度图标里还没放到的那一截封面的不透明度。
    static let unplayedOpacity: CGFloat = 0.35
    /// 预缩小图的边长(像素):3x 屏也够用。
    private static let thumbnailPixels = 64

    /// 这一刻要画的封面原图;nil = 开关关着 / 没封面 / 广告。口径同面板小封面:高清替代优先、先取预缩小的那张。
    static func currentSource() -> NSImage? {
        guard AppSettings.shared.menuBarIconShowsArtwork else { return nil }
        let p = PlaybackCoordinator.shared
        guard !p.isCurrentTrackAdBreak else { return nil }
        return p.highResArtworkThumbnail ?? p.highResArtworkImage ?? p.artworkImage
    }

    /// 图标那一格的尺寸。关着时就是款式图标自己的尺寸。
    static func footprint(style: MenuBarIconStyle, showsArtwork: Bool, size: MenuBarIconSize) -> CGSize {
        let glyph = MenuBarIconStyle.cachedImage(for: style, size: size).size
        guard showsArtwork else { return glyph }
        let tile = side * size.scale
        return CGSize(width: max(glyph.width, tile), height: max(glyph.height, tile))
    }

    /// 封面方块在 `canvas` 里的位置(居中)。
    static func tileRect(in canvas: CGSize, size: MenuBarIconSize) -> CGRect {
        let tile = side * size.scale
        return CGRect(x: (canvas.width - tile) / 2, y: (canvas.height - tile) / 2, width: tile, height: tile)
    }

    /// 把封面画进 `rect`(圆角裁切,圆角随方块边长等比)。`ctx` 是不翻转的坐标系。
    static func draw(_ thumbnail: CGImage, in ctx: CGContext, rect: CGRect, alpha: CGFloat) {
        let radius = cornerRadius * rect.width / side
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high
        ctx.draw(thumbnail, in: rect)
        ctx.restoreGState()
    }

    /// 图标独占那一格贴的整张图(彩色,不是模板图):`footprint` 大小,封面居中。缓存最近一张:
    /// refresh 换句就跑一次,每次给按钮一张新图等于每句重画一次。
    static func iconImage(source: NSImage, style: MenuBarIconStyle, size: MenuBarIconSize) -> NSImage? {
        let footprint = footprint(style: style, showsArtwork: true, size: size)
        if let cachedIcon, cachedIcon.source === source, cachedIcon.footprint == footprint,
           cachedIcon.size == size { return cachedIcon.image }
        guard let thumbnail = thumbnail(of: source) else { return nil }
        let image = NSImage(size: footprint, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            draw(thumbnail, in: ctx, rect: tileRect(in: footprint, size: size), alpha: 1)
            return true
        }
        cachedIcon = (source, footprint, size, image)
        return image
    }

    private static var cachedIcon: (source: NSImage, footprint: CGSize, size: MenuBarIconSize, image: NSImage)?

    /// 封面裁成正方形(按短边居中)、缩到 `thumbnailPixels`。只缓存最近一张:换歌才换图,
    /// 而原图可能是 1400~3000px 的高清图,每次重画都从它缩不划算。
    static func thumbnail(of source: NSImage) -> CGImage? {
        if let cached, cached.source === source { return cached.thumbnail }
        let made = makeThumbnail(source)
        cached = made.map { (source, $0) }
        return made
    }

    private static var cached: (source: NSImage, thumbnail: CGImage)?

    private static func makeThumbnail(_ source: NSImage) -> CGImage? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }
        let short = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - short) / 2, y: (cg.height - short) / 2, width: short, height: short)
        guard let square = cg.cropping(to: crop) else { return nil }
        let px = min(thumbnailPixels, short)
        guard let ctx = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: px, height: px))
        return ctx.makeImage()
    }
}
