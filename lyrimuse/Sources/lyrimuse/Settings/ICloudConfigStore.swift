import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "icloud-config")

/// 把导出的配置放进 iCloud Drive 里一个固定文件夹,换新电脑时自动找出来。
///
/// ## 为什么不用 Apple 官方那两套 iCloud API
///
/// `url(forUbiquityContainerIdentifier:)`(iCloud 容器)和 `NSUbiquitousKeyValueStore`
/// (专为"同步少量设置"设计)都需要 `com.apple.developer.ubiquity-container-identifiers`
/// 这类 entitlement,而 entitlement 要真实 Team ID + 描述文件才会被系统认。Lyrimuse 是
/// **ad-hoc 签名**(`Signature=adhoc`、`TeamIdentifier=not set`、entitlements 为空,
/// 2026-08-10 对 /Applications/Lyrimuse.app 实测),两套都用不了。
///
/// 剩下能走的只有第三条:**非沙盒 App 把 iCloud Drive 当普通路径读写**——
/// `~/Library/Mobile Documents/com~apple~CloudDocs/Lyrimuse/`。很多非 App Store 的
/// 独立 App 就是这么做的。代价是拿不到容器级的同步事件,只能自己按需查下载状态(见下面
/// `read(_:)`)。
///
/// ## 只做"搬家",不做"持续同步"
///
/// 2026-08-10 跟用户确认过的范围:导出时默认落到 iCloud、新机器首次启动时探测到就问一句
/// 要不要导入。**没有**两台机器实时保持一致那套东西 —— 那需要处理"两边同时改了同一项",
/// 而 iCloud Drive 遇到冲突可能自己挑一个版本还不通知(Apple 官方文档承认这点),在一份
/// 带账号 token 的配置上静默丢数据是不可接受的。Alfred 官方也明确不推荐用 iCloud 同步
/// 它的偏好(推荐 Dropbox),原因同源。
///
/// 因为只搬家,所以文件名保留导出时的时间戳(`Lyrimuse-Config-<时间>.json`)、一份一份
/// 攒着当历史,探测时取**最新的那一份**,而不是往一个固定文件名上反复覆盖。
enum ICloudConfigStore {
    /// iCloud Drive 根。这个目录不存在就说明用户根本没开 iCloud Drive。
    private static var cloudDocsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    /// 我们在 iCloud Drive 里的文件夹。故意用 App 名字,用户在 Finder 里一眼认得出来。
    static var folderURL: URL { cloudDocsURL.appendingPathComponent("Lyrimuse") }

    /// 用户开了 iCloud Drive 吗。没开就整块 UI 都不显示,而不是给一个点了会报错的按钮。
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: cloudDocsURL.path)
    }

    /// 建好文件夹再把它交出去,给保存面板当默认落点用。
    ///
    /// 必须先建:`NSSavePanel.directoryURL` 指向一个不存在的目录时会被系统**静默忽略**,
    /// 面板会退回上次用过的位置 —— 表现成"我明明设了默认存到 iCloud,怎么还是打开在
    /// 别处"。建不出来(iCloud 目录不可写等)就返回它本身,让面板自己去回退。
    static func preparedFolderURL() -> URL {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    /// iCloud 里的一份配置。
    struct Snapshot {
        /// 指向真实文件名的 URL(即便磁盘上现在只是个未下载的占位符,这里也已经换成真名,
        /// 可以直接交给 `read(_:)`)。
        let url: URL
        /// 文件的修改时间 —— 用来排序"哪份最新"。
        let modifiedAt: Date
        /// 配置里自报的导出时间/机器名(读文件内容才有,列目录阶段拿不到)。
        var exportedAt: Date?
        var deviceName: String?
    }

    // MARK: - 列目录

    /// iCloud 文件夹里最新的一份配置。没有就返回 nil。
    ///
    /// 只列目录、不读内容 —— 未下载的文件在这一步也能被看到(见
    /// `ConfigSnapshotName.realName(ofDirectoryEntry:)`),真正要读的时候才触发下载。
    static func latestSnapshot() -> Snapshot? {
        guard isAvailable else { return nil }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]) else { return nil }

        var best: Snapshot?
        for entry in entries {
            // 认文件名的规则(含 iCloud 未下载占位符 `.<真名>.icloud`)在
            // ConfigSnapshotName 里,那边有自测覆盖。
            guard let name = ConfigSnapshotName.realName(ofDirectoryEntry: entry.lastPathComponent)
            else { continue }
            let real = folderURL.appendingPathComponent(name)
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || modified > best!.modifiedAt {
                best = Snapshot(url: real, modifiedAt: modified)
            }
        }
        guard var found = best else { return nil }
        // 只在文件**已经下载到本机**时才读内容补充自报信息。
        //
        // 不能无条件 `Data(contentsOf:)`:2026-08-10 实测(brctl evict 造出真占位符)——
        // 读一个未下载的文件会触发**透明物化**,也就是当场去 iCloud 下载并**阻塞调用线程**
        // 直到下完(那次小文件用了 1.06s,网络差时可以是几十秒)。而这个方法是在设置页
        // .onAppear、以及启动探测里同步调的,一卡就是整个界面卡住。
        //
        // isMaterialized 用的资源属性查询本身不会触发下载(同次实测:已下载 → Current,
        // 逐出后 → NotDownloaded,两次都是立即返回)。
        if isMaterialized(found.url), let data = try? Data(contentsOf: found.url) {
            let meta = metadata(in: data)
            found.exportedAt = meta.exportedAt
            found.deviceName = meta.deviceName
        }
        return found
    }

    /// 从配置内容里取出自报的导出时间和机器名。解析失败一律返回空,不抛错 ——
    /// 这两个字段只用来把提示写得具体一点,拿不到也不该妨碍导入。
    static func metadata(in data: Data) -> (exportedAt: Date?, deviceName: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let date = (obj["exportedAt"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return (date, obj["deviceName"] as? String)
    }

    /// 这个文件现在能不能直接读,而**不会**触发下载。
    ///
    /// 拿不到状态就当能读 —— 那说明它不是 iCloud 在管的文件(比如用户手动往这个文件夹里
    /// 拷进来的本地文件),读它本来就是立即返回。
    static func isMaterialized(_ url: URL) -> Bool {
        var probe = url
        // 资源属性是带缓存的,轮询时不清缓存会一直读到第一次那个旧状态
        probe.removeCachedResourceValue(forKey: .ubiquitousItemDownloadingStatusKey)
        guard let status = (try? probe.resourceValues(
            forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        else { return true }
        return status == .current
    }

    // MARK: - 读

    /// 读一份配置。文件可能还没从 iCloud 下载下来,那就先触发下载再等它到位。
    ///
    /// 这是"直接把 iCloud Drive 当普通路径用"必须自己承担的一步,而且实测下来跟直觉相反:
    /// 对未下载的文件 `Data(contentsOf:)` **不会失败**,它会触发透明物化 —— 当场去下载并
    /// 把调用线程按在那儿直到下完(2026-08-10 用 brctl evict 造出真占位符实测:151 字节的
    /// 小文件也要 1.06s)。所以不能"读读看,失败再说",那等于把超时控制交了出去。
    ///
    /// 正确顺序是:先查状态(查状态本身不触发下载),没下载就
    /// `startDownloadingUbiquitousItem` 发起,再自己轮询等它变成 `.current`,最后才读。
    ///
    /// 超时就放弃并返回 nil(调用方据此提示"iCloud 还没同步下来,过一会再试"),不无限等
    /// —— iCloud 卡住是常态,不能让用户对着一个转不完的圈。
    static func read(_ url: URL, timeout: TimeInterval = 20) async -> Data? {
        if isMaterialized(url) { return await loadOffCallerThread(url) }

        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            logger.notice("read: startDownloading failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // 先等状态变成"已下载"再读,而不是直接读着等它物化 —— 直接读会把调用线程按在
        // 那儿直到下完,我们给的 timeout 就完全不起作用了。
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if isMaterialized(url) { return await loadOffCallerThread(url) }
        }
        logger.notice("read: timed out waiting for iCloud download")
        return nil
    }

    /// 把真正读盘那一下挪离调用者所在的线程。
    ///
    /// 调用方(启动探测)是 @MainActor 的,`async` 本身并不会让函数体换线程 —— 不显式
    /// 切走的话,读盘仍然发生在主线程上。
    private static func loadOffCallerThread(_ url: URL) async -> Data? {
        await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
    }

    // MARK: - 写

    /// 把一份配置写进 iCloud 文件夹,返回写到哪儿了。失败返回 nil。
    @discardableResult
    static func write(_ data: Data, filename: String) -> URL? {
        guard isAvailable else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: folderURL, withIntermediateDirectories: true)
            let url = folderURL.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            logger.error("write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
