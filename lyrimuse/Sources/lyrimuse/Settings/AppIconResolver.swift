import AppKit
import LyrimuseCore
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
/// 取图标在后台(`AppIconCache`):`icon(forBundleID:)` 只给缓存里已经读好的,没有就派一次后台读、这次先给占位图。
/// 调用方的视图要观察 `AppIconCache.shared`,读好时跟着重画。
@MainActor
enum AppIconResolver {
    private static var cache: [String: NSImage] = [:]

    /// 读好了给图;还在后台读给 `AppIconCache.pendingPlaceholder`(透明的空图:那一格先空着,不先闪一下调用方的兜底);
    /// 确定取不到(没装、空 bundle id)给 nil,调用方照旧落到自己的兜底。
    static func icon(forBundleID bundleID: String) -> NSImage? {
        AppIconCache.shared.icon(forBundleID: bundleID)
    }

    /// 找到 .app、取系统给的图标、逐张画成位图。会同步等 LaunchServices 和 iconservicesagent,只在后台线程上调。
    ///
    /// 空字符串(比如 `PlaybackPlayer.auto` 没有唯一固定的目标 App)直接返回 nil,
    /// 不去问 NSWorkspace——那样问到的是"哪个 App 声明了处理空 bundle id",没有意义。
    nonisolated static func loadInstalledIcon(bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty, let url = PlayerBundleAliases.applicationURL(forBundleID: bundleID) else { return nil }
        return fullBleedLegacyIcon(appURL: url).map(fittedToIconGrid)
            ?? rasterizedRepresentations(of: NSWorkspace.shared.icon(forFile: url.path), maxPixels: 256)
    }

    /// build.sh 拷进 `Contents/Resources/` 的 `AppIcon.icns`(Info.plist 的 `CFBundleIconFile`),哪条线程上调都行。
    /// 不用 `NSApplication.applicationIconImage`:进程里第一次读要同步等 iconservicesagent。
    nonisolated static func bundledOwnIcon() -> NSImage? {
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    /// 把 `icon` 的每一张图按原来的点尺寸和像素画成位图,像素边长超过 `maxPixels` 的那几张不要。
    ///
    /// 系统给的 App 图标是一组 `NSISIconImageRep`(16～1024pt,各有 1x / 2x):画的时候才找 iconservicesagent 要那一档的图,
    /// 主线程上按一个没画过的尺寸第一次画同样要等它。逐张画成位图之后主线程只是贴图。点尺寸和像素跟原来一一对应,
    /// 显示时挑中的还是原来那一档:16 / 32pt 那几档的留边比大图窄,统一重采样成一组固定像素(`prerendered`)
    /// 会把小尺寸的图标画小一圈。哪条线程上调都行。
    nonisolated static func rasterizedRepresentations(of icon: NSImage, maxPixels: Int) -> NSImage {
        let image = NSImage(size: icon.size)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3) else { return icon }
        var seen = Set<String>()
        for rep in icon.representations {
            let width = rep.pixelsWide, height = rep.pixelsHigh
            guard width > 0, height > 0, max(width, height) <= maxPixels, rep.size.width > 0, rep.size.height > 0,
                  seen.insert("\(rep.size.width)x\(rep.size.height)@\(width)x\(height)").inserted,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            context.interpolationQuality = .high
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            rep.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            guard let cgImage = context.makeImage() else { continue }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            bitmap.size = rep.size
            image.addRepresentation(bitmap)
        }
        return image.representations.isEmpty ? icon : image
    }

    /// 只带老式 icns(没有 `CFBundleIconName`)、而且图铺满整张画布的 App,取它自己的 icns。
    /// 系统给这类图标套一层灰色圆角底板,原图缩在中间(Amazon Music 就是这样);其余情况返回 nil,
    /// 照旧用 NSWorkspace 的图标。
    private nonisolated static func fullBleedLegacyIcon(appURL: URL) -> NSImage? {
        guard let bundle = Bundle(url: appURL),
              bundle.object(forInfoDictionaryKey: "CFBundleIconName") == nil,
              let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let image = bundle.image(forResource: file)
        else { return nil }
        return isFullBleed(image) ? image : nil
    }

    /// 四条边的中点都不透明 = 图铺满画布、没按 macOS 图标网格留边。
    private nonisolated static func isFullBleed(_ image: NSImage) -> Bool {
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
    private nonisolated static func fittedToIconGrid(_ image: NSImage) -> NSImage {
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
    /// 512 像素的 PNG:缩到几十像素满是锯齿。最大 512 像素,够画到 256pt;这些图标最大画到 64pt。随包的 PNG 因此
    /// 最多 512 见方,再大用不上、只占安装包体积(见 15 章决策 33)。
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
    /// 那两次的先例:取自本机已安装 App 的 AppIcon.icns,sips 转 512×512 PNG,
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

/// 全进程共用的 App 图标缓存:播放器图标(按 bundle id)和 Lyrimuse 自己的图标都在后台读、逐张画成位图
/// (`AppIconResolver.rasterizedRepresentations`),回主线程才放进来,观察它的视图跟着重画。
///
/// 别在主线程上取 App 图标:`NSWorkspace.icon(forFile:)`、`NSApplication.applicationIconImage` 进程里第一次取,
/// 以及按一个没画过的尺寸第一次画系统给的图标,都要同步等 iconservicesagent,刚登录、系统还忙时能卡住好几秒
/// (14 章决策 211)。
///
/// 读在自己的 `loadQueue` 上(最多 2 个并发),别改成 `Task.detached`:那几次同步等 iconservicesagent 会占住 Swift 并发的
/// 协作线程(总数等于核数),勾了很多播放器时启动预热能把它们全占满,别处的后台读跟着排队。
///
/// 队列用 userInitiated,别降到 utility / background:iconservicesagent 按请求方的 QoS 生成各档图、读盘,
/// 它的缓存在 LaunchServices 登记变了(装、更新任何 App)之后整个作废,机器忙时 utility 档冷读一批图标会被压得很慢
/// (14 章决策 224)。
@MainActor
final class AppIconCache: ObservableObject {
    static let shared = AppIconCache()

    /// 还在后台读时给的占位:1×1 的透明图。调用方照常画它,那一格先空着,外面的 frame 照旧占位、布局不跳。
    static let pendingPlaceholder: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            image.addRepresentation(rep)
        }
        return image
    }()

    /// 没装的播放器隔多久再问一次:装上之后不用重启就换成真图标;重问期间照旧答「没有」,兜底图不闪。
    private static let missingRecheckInterval: TimeInterval = 30

    enum Lookup {
        case pending
        case missing
        case ready(NSImage)
    }

    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var own: NSImage?
    private var missingSince: [String: Date] = [:]
    /// 排着或正在读的那一次,按 bundle id;自家图标的 key 是 `ownKey`。
    private var inFlight: [String: Operation] = [:]
    private var ownRequested = false
    private static let ownKey = "lyrimuse.own-icon"
    /// 读好、还没发布的结果。一阵子里陆续回来的攒成一次发布:每发布一次,观察缓存的大页(设置页「播放器」、面板)
    /// 都整页重算,勾了很多播放器时启动预热会一个接一个地回来。
    private var stagedIcons: [String: NSImage] = [:]
    private var flushScheduled = false
    private static let publishDelay: TimeInterval = 0.3

    private static let loadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "lyrimuse.app-icons"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func lookup(bundleID: String) -> Lookup {
        guard !bundleID.isEmpty else { return .missing }
        if let hit = icons[bundleID] ?? stagedIcons[bundleID] { return .ready(hit) }
        if let since = missingSince[bundleID] {
            if Date().timeIntervalSince(since) > Self.missingRecheckInterval { load(bundleID, priority: .low) }
            return .missing
        }
        load(bundleID, priority: .veryHigh)
        return .pending
    }

    /// 同 `AppIconResolver.icon(forBundleID:)`。
    func icon(forBundleID bundleID: String) -> NSImage? {
        switch lookup(bundleID: bundleID) {
        case .ready(let image): return image
        case .pending: return Self.pendingPlaceholder
        case .missing: return nil
        }
    }

    /// Lyrimuse 自己的图标;还在读(或包里没有图标)时给占位。
    var ownIcon: NSImage {
        if let own { return own }
        loadOwnIcon(priority: .veryHigh)
        return Self.pendingPlaceholder
    }

    /// 启动后预热:Lyrimuse 自己的图标、`bundleIDs` 里的播放器。已经有了或正在读的不重派;排在视图当场要的后面。
    func prefetch(bundleIDs: [String]) {
        loadOwnIcon(priority: .normal)
        for bundleID in bundleIDs where !bundleID.isEmpty && icons[bundleID] == nil && stagedIcons[bundleID] == nil
            && missingSince[bundleID] == nil {
            load(bundleID, priority: .low)
        }
    }

    /// 启动后预热哪些播放器:勾选的具体播放器,和「上次播放」那首的播放器(停播时面板、迷你窗指的就是它);都没有时 Apple Music。
    /// 要读 features.json,在后台调。
    nonisolated static func prefetchBundleIDs() -> [String] {
        var ids = PlaybackPlayerPreference.selected.filter { $0 != .auto }.map(\.bundleIdentifier)
        if let last = PlaybackPlayerPreference.lastPlayedPlayerBundleID(), !ids.contains(last) { ids.append(last) }
        return ids.isEmpty ? [PlaybackPlayer.appleMusic.bundleIdentifier] : ids
    }

    private func load(_ bundleID: String, priority: Operation.QueuePriority) {
        enqueue(key: bundleID, priority: priority, read: { AppIconResolver.loadInstalledIcon(bundleID: bundleID) }) { cache, image in
            cache.stage(bundleID, image)
        }
    }

    /// 记下读的结果,攒一会儿再发布。头一次读到没装也要发布:那一格正画着占位图,得重画一次才落到调用方的兜底图;
    /// 本来就记着没装、重查还是没装的只更新时间,不发布(那一格已经是兜底图,发布只会让观察者整页白算一遍)。
    private func stage(_ bundleID: String, _ image: NSImage?) {
        if let image {
            missingSince[bundleID] = nil
            stagedIcons[bundleID] = image
        } else {
            let alreadyMissing = missingSince[bundleID] != nil
            missingSince[bundleID] = Date()
            if alreadyMissing { return }
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishDelay) {
            MainActor.assumeIsolated { AppIconCache.shared.publishStaged() }
        }
    }

    private func publishStaged() {
        flushScheduled = false
        guard !stagedIcons.isEmpty else {
            objectWillChange.send()
            return
        }
        icons.merge(stagedIcons) { _, staged in staged }
        stagedIcons = [:]
    }

    private func loadOwnIcon(priority: Operation.QueuePriority) {
        if ownRequested {
            if let queued = inFlight[Self.ownKey], queued.queuePriority.rawValue < priority.rawValue { queued.queuePriority = priority }
            return
        }
        ownRequested = true
        enqueue(key: Self.ownKey, priority: priority, read: {
            AppIconResolver.bundledOwnIcon().map { AppIconResolver.rasterizedRepresentations(of: $0, maxPixels: 512) }
        }) { cache, image in
            if let image { cache.own = image }
        }
    }

    /// 在 `loadQueue` 上跑 `read`,回主线程交给 `apply`。同一个 key 已经排着就不重派,只把优先级提上去(视图当场要的插到预热前面)。
    private func enqueue(key: String, priority: Operation.QueuePriority, read: @escaping @Sendable () -> NSImage?,
                         apply: @escaping @MainActor (AppIconCache, NSImage?) -> Void) {
        if let queued = inFlight[key] {
            if queued.queuePriority.rawValue < priority.rawValue { queued.queuePriority = priority }
            return
        }
        let operation = BlockOperation {
            let image = LoadedIcon(image: read())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let cache = AppIconCache.shared
                    cache.inFlight[key] = nil
                    apply(cache, image.image)
                }
            }
        }
        operation.queuePriority = priority
        inFlight[key] = operation
        Self.loadQueue.addOperation(operation)
    }
}

/// 后台读好的图标交回主线程:只在读的那条线程和主线程上各碰一次,不并发访问。
private struct LoadedIcon: @unchecked Sendable {
    let image: NSImage?
}

/// Lyrimuse 自己的图标,已经 `.resizable()`,外面照旧加 frame。读好之前那一格空着。
struct LyrimuseAppIconImage: View {
    @ObservedObject private var cache = AppIconCache.shared

    var body: some View {
        Image(nsImage: cache.ownIcon).resizable()
    }
}

/// 按 bundle id 画一个 App 的图标:读好了(含还在读时的透明占位图)交给 `icon`,没装交给 `fallback`。
///
/// 自己观察缓存、在自己的 body 里读,别改成在外层视图里读好再塞进子视图的 `@ViewBuilder` 闭包:外层观察缓存只能让外层重算,
/// 子视图存着的闭包只捕获了 bundle id、尺寸这类没变的值时,SwiftUI 判它没变、不重算那一格,图标读好了也一直是占位图(14 章决策 223)。
struct InstalledAppIcon<Icon: View, Fallback: View>: View {
    let bundleID: String
    let icon: (NSImage) -> Icon
    let fallback: () -> Fallback
    @ObservedObject private var cache = AppIconCache.shared

    init(bundleID: String, @ViewBuilder icon: @escaping (NSImage) -> Icon, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.bundleID = bundleID
        self.icon = icon
        self.fallback = fallback
    }

    var body: some View {
        if let image = AppIconResolver.icon(forBundleID: bundleID) {
            icon(image)
        } else {
            fallback()
        }
    }
}
