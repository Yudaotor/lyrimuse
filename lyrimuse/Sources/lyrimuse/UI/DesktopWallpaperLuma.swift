import AppKit
import ImageIO
import LyrimuseCore
import os

/// 当前桌面壁纸的平均相对亮度。
///
/// 歌词窗口的自定义背景色带不透明度时,窗口本体是透明的,颜色后面透出来的是桌面 —— 文字该用白字还是深色字,
/// 得看颜色跟**壁纸**混出来有多亮,按窗口底色算会在「深色外观 + 浅色壁纸」下配出看不见的白字。
/// 读的是壁纸文件本身(`NSWorkspace.desktopImageURL`),不截屏、不需要屏幕录制权限;代价是盖在壁纸上的
/// 别的窗口算不进来。
///
/// 壁纸文件可能在网络卷上、或是 iCloud 里没下载到本机的文件,stat 和打开都可能等几十秒,所以查修改时间和解码
/// 都在一条串行队列上做,主线程只查缓存:还没读到时 `luma(for:)` 返回 nil(调用方按系统外观估计),读完回主线程
/// 记下,亮度跟原来不一样才发布一次,订阅它的视图重算字色。别把 stat 或解码挪回 `luma(for:)` 里同步做。见 07 章决策 218。
///
/// 这个值在歌词窗口的 body 里每次重算都会被问好几遍:每块屏幕的壁纸地址(问一次要跨进程)和每个地址的亮度
/// 都缓存,最多 5 秒回去核对一次有没有换壁纸(同一个地址同时只排一次),其余时候只是两次字典查找。
/// 解码用 ImageIO 的缩略图,不整张解开几千像素的原图。
@MainActor
final class DesktopWallpaperLuma: ObservableObject {
    static let shared = DesktopWallpaperLuma()

    /// 读到的亮度有变化(或调试替身换了)时加一,只用来让订阅的视图重算。
    @Published private(set) var revision = 0

    private struct Entry {
        var modified: Date?
        var luma: Double?
        var checkedAt: Date
    }

    private var cache: [URL: Entry] = [:]
    private var pending: Set<URL> = []
    private var wallpaperURLs: [CGDirectDisplayID: (url: URL?, checkedAt: Date)] = [:]
    private static let recheckInterval: TimeInterval = 5
    private nonisolated static let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.wallpaper-luma", qos: .userInitiated)
    private nonisolated static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "wallpaper-luma")

    /// `debug/wallpaper-luma`:所有屏幕都当作壁纸是这个文件,后台读之前先等 `delay` 秒。不落盘。
    private var debugOverride: (url: URL, delay: TimeInterval)?
    /// `debug/state` 用:解过几次文件、最近一次读的结果。
    private var reads = 0
    private var lastRead: [String: Any]?

    private init() {}

    /// nil = 还没读完,或读不到(拿不到屏幕、壁纸地址,或者文件解不开),调用方按系统外观估计。
    func luma(for screen: NSScreen?) -> Double? {
        guard let screen = screen ?? NSScreen.main else { return nil }
        let now = Date()
        guard let url = wallpaperURL(for: screen, now: now) else { return nil }
        let entry = cache[url]
        if entry.map({ now.timeIntervalSince($0.checkedAt) >= Self.recheckInterval }) ?? true {
            refresh(url, known: entry)
        }
        return entry?.luma
    }

    private func wallpaperURL(for screen: NSScreen, now: Date) -> URL? {
        if let debugOverride { return debugOverride.url }
        guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return NSWorkspace.shared.desktopImageURL(for: screen)
        }
        if let known = wallpaperURLs[display], now.timeIntervalSince(known.checkedAt) < Self.recheckInterval { return known.url }
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        wallpaperURLs[display] = (url, now)
        return url
    }

    /// 在后台核对修改时间,变了(或第一次)才解码。`known` 是缓存里现有的那条,修改时间没变就只续期。
    private func refresh(_ url: URL, known: Entry?) {
        guard pending.insert(url).inserted else { return }
        let knownModified = known?.modified
        let hasKnown = known != nil
        let delay = debugOverride?.url == url ? debugOverride?.delay ?? 0 : 0
        Self.queue.async {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let modified = FileIO.modificationDate(url)
            guard !hasKnown || modified != knownModified else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { DesktopWallpaperLuma.shared.finish(url, modified: modified, read: nil) }
                }
                return
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let luma = Self.averageLuma(of: url)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let onMain = Thread.isMainThread
            let lumaText = luma.map { String(format: "%.3f", $0) } ?? "nil"
            let msText = String(format: "%.1f", ms)
            Self.logger.notice("wallpaper luma read file=\(url.lastPathComponent, privacy: .public) luma=\(lumaText, privacy: .public) ms=\(msText, privacy: .public) main=\(onMain, privacy: .public)")
            let read = Read(luma: luma, ms: ms, onMain: onMain)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DesktopWallpaperLuma.shared.finish(url, modified: modified, read: read) }
            }
        }
    }

    private struct Read: Sendable {
        let luma: Double?
        let ms: Double
        let onMain: Bool
    }

    /// `read` 为 nil = 修改时间没变、没解码,只续期。
    private func finish(_ url: URL, modified: Date?, read: Read?) {
        pending.remove(url)
        let now = Date()
        guard let read else {
            cache[url]?.checkedAt = now
            return
        }
        let previous = cache[url]
        cache[url] = Entry(modified: modified, luma: read.luma, checkedAt: now)
        reads += 1
        lastRead = ["file": url.lastPathComponent, "luma": read.luma.map { $0 as Any } ?? NSNull(),
                    "ms": (read.ms * 10).rounded() / 10, "onMainThread": read.onMain]
        if previous?.luma != read.luma { revision &+= 1 }
    }

    /// `debug/wallpaper-luma?path=…&delay-ms=…`:换成读这个文件(nil = 换回真壁纸),清掉它的缓存让下次重读。
    func setDebugOverride(path: String?, delayMs: Int) {
        if let path {
            let url = URL(fileURLWithPath: path)
            cache[url] = nil
            debugOverride = (url, Double(delayMs) / 1000)
        } else {
            debugOverride = nil
        }
        revision &+= 1
    }

    /// `debug/state` 的 `wallpaperLuma`:缓存里各个壁纸文件读到的亮度、还在后台读的、最近一次解码。
    var debugState: [String: Any] {
        ["override": debugOverride.map { $0.url.path as Any } ?? NSNull(),
         "entries": cache.map { url, entry in
             ["file": url.lastPathComponent, "luma": entry.luma.map { $0 as Any } ?? NSNull()] as [String: Any]
         },
         "pending": pending.map(\.lastPathComponent),
         "reads": reads,
         "lastRead": lastRead.map { $0 as Any } ?? NSNull()]
    }

    /// 缩到 16×16 以内再按 sRGB 线性化后的相对亮度取平均。不碰界面,在后台队列上调。
    ///
    /// 用 `FromImageIfAbsent` 而不是 `FromImageAlways`:后者无视文件里内嵌的缩略图、把整张壁纸完整解一遍
    /// (6K 的 HEIC 动态壁纸几十到上百毫秒),而 16 像素的平均亮度用内嵌缩略图就够了,没有才解原图。
    nonisolated static func averageLuma(of url: URL) -> Double? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 16,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * linear(pixels[i]) + 0.7152 * linear(pixels[i + 1]) + 0.0722 * linear(pixels[i + 2])
        }
        return total / Double(width * height)
    }
}
