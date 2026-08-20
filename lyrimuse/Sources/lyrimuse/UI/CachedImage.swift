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

    /// 按用途分档(2026-08-20 性能审计):列表里 26~40pt 的小图和歌词窗口的高清封面
    /// 原来共用同一个"按原图存"的缓存 —— 一张网易云原生大图(3000² ≈ 36MB 解码后)
    /// 就能吃掉 48MB 预算的大半,把几百张列表缩略图挤出去,表现成列表滚动时缩略图
    /// 反复换入换出闪占位符。缩略档在解码时就降采样到 ≤256px(Retina 下 40pt 行高
    /// 也远够),cost 直接小两个数量级;原图档留给真需要分辨率的消费方(高清封面替代,
    /// 920pt@2x 需要 1840px,不能降)。
    enum Variant: String {
        case thumbnail // ≤256px,列表/头像/小封面
        case original  // 原图,高清封面替代

        var maxPixel: CGFloat? { self == .thumbnail ? 256 : nil }
    }

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // 缩略档单张 ≤256²×4 ≈ 256KB,48MB 能容下整个列表的量;原图档偶尔一两张大图
        // 挤占时,NSCache 按 cost 淘汰的也是"贵"的那几张,列表小图不再被连坐。
        c.countLimit = 400
        c.totalCostLimit = 48 << 20
        return c
    }()

    /// 失败负缓存(2026-08-20):失效/缺图的 URL 原来在每次视图重建时都重发一次真实
    /// 网络请求(URLCache 不缓存失败)。记一个短 TTL 的失败时刻,窗口内不再重试 ——
    /// 图源偶发抖动过后仍能自愈。
    private var failedAt: [URL: Date] = [:]
    private static let failureTTL: TimeInterval = 10 * 60
    private static let failureCap = 512

    /// 正在下载中的 URL → 共享的加载任务。没有它的话同一个 URL 出现在 N 行就是 N 个
    /// 并发请求 + N 次解码:URLCache 不合并并发的同 URL 请求(第一个还没写回,后面全 miss),
    /// 冷缓存时是真发 N 次网络(审阅坐实)。
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private static func key(_ url: URL, _ variant: Variant) -> NSString {
        (variant.rawValue + "|" + url.absoluteString) as NSString
    }

    func image(for url: URL, variant: Variant = .thumbnail) -> NSImage? {
        cache.object(forKey: Self.key(url, variant))
    }

    func store(_ image: NSImage, for url: URL, variant: Variant = .thumbnail) {
        // cost 用解码后的估算字节数(宽×高×4),NSCache 才有依据按字节淘汰
        let size = image.size
        let cost = max(1, Int(size.width * size.height * 4))
        cache.setObject(image, forKey: Self.key(url, variant), cost: cost)
        failedAt[url] = nil
    }

    /// 取图:命中内存直接返回;否则同一个 URL+档位只发一次请求,其余调用方等同一个任务。
    func load(_ url: URL, variant: Variant = .thumbnail) async -> NSImage? {
        if let hit = image(for: url, variant: variant) { return hit }
        if let failed = failedAt[url], Date().timeIntervalSince(failed) < Self.failureTTL {
            return nil
        }
        let flightKey = Self.key(url, variant) as String
        if let running = inFlight[flightKey] { return await running.value }
        let task = Task<NSImage?, Never> {
            await CachedImage<EmptyView>.loadForPrewarm(url, maxPixel: variant.maxPixel)
        }
        inFlight[flightKey] = task
        let result = await task.value
        inFlight[flightKey] = nil
        if let result {
            store(result, for: url, variant: variant)
        } else {
            if failedAt.count >= Self.failureCap { failedAt.removeAll() } // 粗暴够用:防无界增长
            failedAt[url] = Date()
        }
        return result
    }

    /// 预热:把一批 URL 提前解码进内存(缩略档 —— 预热的对象就是列表)。给"启动后不久、
    /// 页面还没打开"这个空窗用 —— 冷启动时 URLCache 里有字节但内存里没有解码结果,首屏
    /// 第一帧仍会闪一下占位符(2026-08-12 用户反馈的另一半:"首次打开时会有一段时间默认")。
    /// 提前热好,页面打开时就是同步命中。
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
///
/// 默认缩略档(所有列表/头像调用点要的都是小图);要原图的消费方显式传 .original。
struct CachedImage<Placeholder: View>: View {
    private let url: URL?
    private let variant: ImageMemoryCache.Variant
    private let placeholder: () -> Placeholder
    @State private var image: NSImage?

    init(url: URL?, variant: ImageMemoryCache.Variant = .thumbnail,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.variant = variant
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { ImageMemoryCache.shared.image(for: $0, variant: variant) })
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
            // ⚠️ 早退前必须把缓存值写回 @State(2026-08-20 对抗核实抓出的既有 bug):同一
            // 视图身份下 url 变化且新 url 恰好已在缓存时,image 里还是旧 url 的图——直接
            // return 会把错图一直挂到视图身份重建。同引用赋值的那次多余 body 求值靠下面
            // 的 !== 判断挡住。
            if image != nil, let hit = ImageMemoryCache.shared.image(for: url, variant: variant) {
                if image !== hit { image = hit }
                return
            }
            guard let loaded = await ImageMemoryCache.shared.load(url, variant: variant) else { return }
            // 迟到的结果如果对应的已经不是当前这个 url(行被复用了),就丢掉
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    /// 给 ImageMemoryCache 用的入口(同一份加载逻辑,不另写一遍)。
    static func loadForPrewarm(_ url: URL, maxPixel: CGFloat?) async -> NSImage? {
        await load(url, maxPixel: maxPixel)
    }

    /// 下载并解码。走 URLSession.shared —— 它吃 URLCache.shared(见 AppDelegate 里
    /// 调大的那份),所以本地已有字节时不会真的发请求。
    ///
    /// maxPixel 非 nil 时用 CGImageSource 缩略图管线在解码期就降采样 —— 只解到目标
    /// 尺寸,不把原图整张解出来再缩(那样峰值内存/CPU 还是原图的);拿不到缩略图
    /// (罕见格式)退回整图解码,行为不变。
    private static func load(_ url: URL, maxPixel: CGFloat?) async -> NSImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let maxPixel,
               let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: maxPixel,
               ] as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }
}
