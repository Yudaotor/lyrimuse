import AppKit
import SwiftUI

/// 已经解好码的图片的内存缓存。
///
/// URLCache 只缓存**字节**:命中它省掉的是下载,省不掉"异步取出 + 解码"这一段,而
/// AsyncImage 无论如何都要先画一帧占位符再异步加载。于是每次视图重建(切换歌手/专辑/
/// 歌曲分段、卡片展开、列表翻页)都要闪一下默认头像 —— 图其实早在本地了(2026-08-12
/// 用户反馈"每次点到歌手 tab 都会先出默认头像")。
///
/// 这里存的是 NSImage,配合 CachedImage 在**构造时**同步取,命中就直接画,第一帧就是
/// 真图,一次占位符都不闪。
@MainActor
final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        // 显示只有 26×26,但存的是**原图**(Last.fm 的 large 是 174²、extralarge 300²,
        // 歌手头像更大),只限张数不限字节的话上限是不确定的几十 MB。两个上限都设:
        // 400 张封顶,同时按解码后的估算字节数封到 48MB(审阅指出只设 countLimit 的问题)。
        c.countLimit = 400
        c.totalCostLimit = 48 << 20
        return c
    }()

    /// 正在下载中的 URL → 共享的加载任务。没有它的话同一个 URL 出现在 N 行就是 N 个
    /// 并发请求 + N 次解码:URLCache 不合并并发的同 URL 请求(第一个还没写回,后面全 miss),
    /// 冷缓存时是真发 N 次网络(审阅坐实)。
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func store(_ image: NSImage, for url: URL) {
        // cost 用解码后的估算字节数(宽×高×4),NSCache 才有依据按字节淘汰
        let size = image.size
        let cost = max(1, Int(size.width * size.height * 4))
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    /// 取图:命中内存直接返回;否则同一个 URL 只发一次请求,其余调用方等同一个任务。
    func load(_ url: URL) async -> NSImage? {
        if let hit = image(for: url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task<NSImage?, Never> { await CachedImage<EmptyView>.loadForPrewarm(url) }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result { store(result, for: url) }
        return result
    }

    /// 预热:把一批 URL 提前解码进内存。给"启动后不久、页面还没打开"这个空窗用 ——
    /// 冷启动时 URLCache 里有字节但内存里没有解码结果,首屏第一帧仍会闪一下占位符
    /// (2026-08-12 用户反馈的另一半:"首次打开时会有一段时间默认")。提前热好,页面
    /// 打开时就是同步命中。
    ///
    /// 并发压到 4:这些都是本地磁盘缓存命中,不该跟别的启动工作抢带宽/CPU;真要有几张
    /// 没缓存的会走网络,慢一点也无所谓 —— 它只是预热,失败没有任何后果。
    func prewarm(_ urls: [URL]) {
        let missing = Array(Set(urls.filter { image(for: $0) == nil }))
        guard !missing.isEmpty else { return }
        Task { [weak self] in
            await withTaskGroup(of: (URL, NSImage?).self) { group in
                var index = 0
                func addNext() {
                    guard index < missing.count else { return }
                    let url = missing[index]
                    index += 1
                    group.addTask { [weak self] in
                        (url, await self?.load(url))
                    }
                }
                for _ in 0..<min(4, missing.count) { addNext() }
                for await (_, _) in group {
                    // load 内部已经写好缓存,这里只是把并发放到下一个
                    addNext()
                }
            }
        }
    }
}

/// AsyncImage 的替代品:内存里已有解码结果就**同步**画出来,否则退回异步加载(那一步
/// 仍然吃 URLCache 的磁盘缓存,不会重复下载)。
///
/// 跟 AsyncImage 的关键差别在 init:`_image` 用缓存里的值做初值,所以命中时连一帧
/// 占位符都不会出现。AsyncImage 做不到这件事 —— 它的加载永远从 nil 开始。
struct CachedImage<Placeholder: View>: View {
    private let url: URL?
    private let placeholder: () -> Placeholder
    @State private var image: NSImage?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { ImageMemoryCache.shared.image(for: $0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        // id: url —— 行被复用到另一首歌时要重新取(不然会留着上一首的图)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            // init 已经用缓存值做过初值:命中时这里再赋一次同样的对象,只会白白多触发
            // 一次 body 求值(@State 的 setter 不比较引用),所以先看有没有必要。
            if image != nil, ImageMemoryCache.shared.image(for: url) != nil { return }
            guard let loaded = await ImageMemoryCache.shared.load(url) else { return }
            // 迟到的结果如果对应的已经不是当前这个 url(行被复用了),就丢掉
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    /// 给 ImageMemoryCache.prewarm 用的入口(同一份加载逻辑,不另写一遍)。
    static func loadForPrewarm(_ url: URL) async -> NSImage? { await load(url) }

    /// 下载并解码。走 URLSession.shared —— 它吃 URLCache.shared(见 AppDelegate 里
    /// 调大的那份),所以本地已有字节时不会真的发请求。

    private static func load(_ url: URL) async -> NSImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return NSImage(data: data)
        } catch {
            return nil
        }
    }
}
