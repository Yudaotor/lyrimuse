import AppKit
import LyrimuseCore

/// 小封面的**位图缓存**:把 `PlaybackCoordinator` 解好的封面 NSImage 按目标像素边长预先
/// 重采样成 CGImage(算法与理由见 `ArtworkThumbnail`),视图层用 `Image(decorative:scale:)` 逐像素贴。
/// 消费点:灵动岛 `artworkThumbnail`(左耳 / 歌词行末尾 / 展开头部三枚)、菜单栏面板 `coverView`
/// 44pt、Last.fm「正在播放」行 26pt 的本机位图兜底。歌词窗口 460pt 那张接近原生尺寸,不走这里。
///
/// key 是 (源图身份, 像素边长):同一张封面在三个尺寸各算一次;换歌换图后旧条目没用了,只保留最近
/// 三张源图的条目 —— 换歌时同时有旧歌正在显示的那张和新歌的低清 / 高清两张,少留一张就会把还在显示的
/// 旧图挤掉、回头又得重缩。条目里**持有**源图的强引用 —— `ObjectIdentifier` 在对象释放后会被新对象复用,
/// 不持有的话一张新封面可能撞上旧条目,画出上一首歌的图。像素边长用 pt × 显示倍率取整(2x / 3x 屏各自一份,
/// 外接 1x 屏也对),跟 `NotchIdleAppIcon` 同一套。
@MainActor
enum ArtworkThumbnailCache {
    private struct Entry {
        let source: NSImage
        var bitmaps: [Int: CGImage]
    }

    /// 最近放进来的在前。
    private static var entries: [Entry] = []
    private static let sourceLimit = 3
    /// 各消费点最近要过的像素边长(最近在前,最多 6 档):新封面一到按这几档在后台先缩(`prefetch`)。
    private static var recentSides: [Int] = []
    /// 正在后台缩的源图(持有强引用,理由同上)。
    private static var prefetching: [ObjectIdentifier: NSImage] = [:]

    /// 取 `image` 缩到 `pixelSide × pixelSide` 的位图;建不出来(理论上不会)返回 nil,调用方退回
    /// `Image(nsImage:).resizable()` 那条老路。
    static func bitmap(for image: NSImage, pixelSide: Int) -> CGImage? {
        guard pixelSide > 0 else { return nil }
        noteSide(pixelSide)
        if let index = entries.firstIndex(where: { $0.source === image }) {
            if let hit = entries[index].bitmaps[pixelSide] { return hit }
            guard let made = render(image, pixelSide: pixelSide) else { return nil }
            entries[index].bitmaps[pixelSide] = made
            return made
        }
        guard let made = render(image, pixelSide: pixelSide) else { return nil }
        insert(Entry(source: image, bitmaps: [pixelSide: made]))
        return made
    }

    /// 新封面一到就调(灵动岛换歌翻牌,见 05 章决策 70):按最近要过的几档像素边长在后台缩好放进缓存,
    /// 真画的时候直接命中。主线程只取一次 CGImage,重采样(从整张图缩下来,最费的那步)在后台;
    /// 第一次画之前还没缩完,`bitmap(for:pixelSide:)` 照旧当场缩。
    static func prefetch(_ image: NSImage) {
        let id = ObjectIdentifier(image)
        let have = entries.first(where: { $0.source === image })?.bitmaps ?? [:]
        let sides = recentSides.filter { have[$0] == nil }
        guard !sides.isEmpty, prefetching[id] == nil,
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        prefetching[id] = image
        Task.detached(priority: .userInitiated) {
            let made = sides.compactMap { side in
                ArtworkThumbnail.squareBitmap(from: source, pixelSide: side).map { (side, $0) }
            }
            await MainActor.run { store(made, for: id) }
        }
    }

    private static func store(_ made: [(Int, CGImage)], for id: ObjectIdentifier) {
        guard let image = prefetching.removeValue(forKey: id), !made.isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.source === image }) {
            for (side, bitmap) in made where entries[index].bitmaps[side] == nil {
                entries[index].bitmaps[side] = bitmap
            }
        } else {
            insert(Entry(source: image, bitmaps: Dictionary(made, uniquingKeysWith: { first, _ in first })))
        }
    }

    private static func insert(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > sourceLimit { entries.removeLast(entries.count - sourceLimit) }
    }

    private static func noteSide(_ side: Int) {
        guard recentSides.first != side else { return }
        recentSides.removeAll { $0 == side }
        recentSides.insert(side, at: 0)
        if recentSides.count > 6 { recentSides.removeLast(recentSides.count - 6) }
    }

    private static func render(_ image: NSImage, pixelSide: Int) -> CGImage? {
        // 不给 proposedRect / hints:让 AppKit 按整图挑最大那档表示,再交给 ArtworkThumbnail 缩——
        // 缩小走的是它的高质量重采样,不能让 AppKit 在这一步先按点尺寸挑一张小的。
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return ArtworkThumbnail.squareBitmap(from: source, pixelSide: pixelSide)
    }
}
