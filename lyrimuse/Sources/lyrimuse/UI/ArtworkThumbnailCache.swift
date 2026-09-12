import AppKit
import LyrimuseCore

/// 小封面的**位图缓存**(2026-09-09):把 `PlaybackCoordinator` 解好的封面 NSImage 按目标像素边长预先
/// 重采样成 CGImage(算法与理由见 `ArtworkThumbnail`),视图层用 `Image(decorative:scale:)` 逐像素贴。
/// 消费点:灵动岛 `artworkThumbnail`(左耳 / 歌词行末尾 / 展开头部三枚)、菜单栏面板 `coverView`
/// 44pt、Last.fm「正在播放」行 26pt 的本机位图兜底。歌词窗口 460pt 那张接近原生尺寸,不走这里。
///
/// key 是 (源图身份, 像素边长):同一张封面在三个尺寸各算一次;换歌换图后旧条目没用了,只保留最近
/// 两张源图的条目(高清替代先到 / 后到会让同一首歌有两张图交替,留两张避免来回重算)。条目里**持有**
/// 源图的强引用 —— `ObjectIdentifier` 在对象释放后会被新对象复用,不持有的话一张新封面可能撞上旧条目,
/// 画出上一首歌的图。像素边长用 pt × 显示倍率取整(2x / 3x 屏各自一份,外接 1x 屏也对),跟
/// `NotchIdleAppIcon` 同一套。
@MainActor
enum ArtworkThumbnailCache {
    private struct Entry {
        let source: NSImage
        var bitmaps: [Int: CGImage]
    }

    /// 最近使用在前;最多两张源图。
    private static var entries: [Entry] = []

    /// 取 `image` 缩到 `pixelSide × pixelSide` 的位图;建不出来(理论上不会)返回 nil,调用方退回
    /// `Image(nsImage:).resizable()` 那条老路。
    static func bitmap(for image: NSImage, pixelSide: Int) -> CGImage? {
        guard pixelSide > 0 else { return nil }
        if let index = entries.firstIndex(where: { $0.source === image }) {
            if let hit = entries[index].bitmaps[pixelSide] { return hit }
            guard let made = render(image, pixelSide: pixelSide) else { return nil }
            entries[index].bitmaps[pixelSide] = made
            return made
        }
        guard let made = render(image, pixelSide: pixelSide) else { return nil }
        entries.insert(Entry(source: image, bitmaps: [pixelSide: made]), at: 0)
        if entries.count > 2 { entries.removeLast(entries.count - 2) }
        return made
    }

    private static func render(_ image: NSImage, pixelSide: Int) -> CGImage? {
        // 不给 proposedRect / hints:让 AppKit 按整图挑最大那档表示,再交给 ArtworkThumbnail 缩——
        // 缩小走的是它的高质量重采样,不能让 AppKit 在这一步先按点尺寸挑一张小的。
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return ArtworkThumbnail.squareBitmap(from: source, pixelSide: pixelSide)
    }
}
