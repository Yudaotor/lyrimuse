import AppKit
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

    /// 用户自选的备份文件夹。为 nil 表示用默认的 iCloud Drive 那个。
    ///
    /// 2026-08-13 加。这一整套原来写死在 iCloud —— 但它压根没用 iCloud 的任何 API
    /// (没有 CloudKit、没有 NSUbiquitousKeyValueStore,那些都需要这个 ad-hoc 签名的 App
    /// 拿不到的 entitlement),只是往 `~/Library/Mobile Documents/com~apple~CloudDocs/`
    /// 底下写普通 JSON 文件而已。同步能力全部来自那个文件夹本身。
    ///
    /// 既然如此,换成任意一个用户指定的目录,这套逻辑一行都不用改就同时支持了 Dropbox /
    /// 坚果云 / OneDrive / Syncthing / 一个 git 工作副本 —— 一个设置项顶掉一堆各自对接。
    /// 这也是同类 App 的通行做法(Alfred 的 "Set preferences folder…"、Keyboard Maestro
    /// 的 "Start Syncing Macros" 都是让用户自己指目录,而不是内置某几家网盘)。
    ///
    /// 存的是**裸路径字符串**,没用 security-scoped bookmark:这个 App 非沙箱,拿到路径就
    /// 能读写。(沙箱 App 才需要 bookmark 来跨启动保留授权。)
    ///
    /// ⚠️ 这个键必须留在本机、不跟着配置搬家 —— 它是"这台机器上的一个路径",在新机器上
    /// 多半不存在。已加进 ConfigPortability.machineLocalDefaultsKeys。
    static let customFolderKey = "np:backupFolderPath"

    static var customFolderPath: String? {
        let raw = UserDefaults.standard.string(forKey: customFolderKey) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func setCustomFolder(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: customFolderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: customFolderKey)
        }
    }

    /// 现在用的是用户自选的目录,还是默认的 iCloud。UI 靠它决定那一行叫什么。
    static var usingCustomFolder: Bool { customFolderPath != nil }

    /// 导入完成后,把"备份文件夹"这个设置对齐到刚导入的那份备份的**来源目录**。
    ///
    /// 不做这一步会分裂:探测范围比写入范围大(见 searchFolders),所以新机器上很可能是从
    /// Dropbox 里那份恢复的,而 folderURL 仍然指着 iCloud —— 用户之后点"更新备份"会写去
    /// iCloud,于是他有两个半份备份,而且哪一份是新的取决于他上次点的是哪台机器。
    ///
    /// 来源恰好就是默认的 iCloud 目录时,清掉自选值而不是把 iCloud 路径存成"自选" ——
    /// 后者会让 UI 显示成"备份文件夹"、菜单里冒出一个没意义的"改回 iCloud"。
    static func adoptFolder(_ sourceFolder: URL) {
        let cloudDefault = cloudDocsURL.appendingPathComponent("Lyrimuse").standardizedFileURL
        let source = sourceFolder.standardizedFileURL
        if source == cloudDefault {
            if customFolderPath != nil { setCustomFolder(nil) }
            return
        }
        guard source != folderURL.standardizedFileURL else { return }
        setCustomFolder(source)
    }

    /// 备份文件夹。默认是 iCloud Drive 里的 Lyrimuse 目录(故意用 App 名字,用户在 Finder
    /// 里一眼认得出来);用户选过别的就用那个。
    static var folderURL: URL {
        if let path = customFolderPath { return URL(fileURLWithPath: path) }
        return cloudDocsURL.appendingPathComponent("Lyrimuse")
    }

    /// 这套 UI 能不能用。自选目录时看那个目录还在不在(用户可能把它删了、或者那是个已经
    /// 拔掉的外置盘);没自选过就是看用户开没开 iCloud Drive。不可用就整块不显示,而不是
    /// 给一个点了必然报错的按钮。
    static var isAvailable: Bool {
        if let path = customFolderPath { return isDirectory(atPath: path) }
        if FileManager.default.fileExists(atPath: cloudDocsURL.path) { return true }
        // 没开 iCloud Drive 也不该把这一栏整个藏掉 —— 那样"换个文件夹备份"这个功能对这批
        // 用户完全不可达(要用它,就得先能看见这一行)。只要机器上存在任何一个已知的云盘
        // 挂载点,就把这栏亮出来。
        return !knownCloudFolders().isEmpty
    }

    private static func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// 这台机器上能找到的第三方云盘根目录。
    ///
    /// `~/Library/CloudStorage/` 是 macOS 12 起 Dropbox / OneDrive / Google Drive / Box
    /// 这些客户端通过 File Provider 统一挂载的位置(子目录名形如 `Dropbox`、
    /// `OneDrive-Personal`、`GoogleDrive-someone@gmail.com`)。老版 Dropbox 客户端仍然用
    /// `~/Dropbox`,所以两处都看。
    ///
    /// 只列目录、不读内容,而且都在用户自己的家目录下 —— 非沙箱 App 读这些不需要 TCC 授权
    /// (Desktop/Documents/Downloads 那三个才需要)。
    private static func knownCloudFolders() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let subs = try? FileManager.default.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
            roots.append(contentsOf: subs.filter { isDirectory(atPath: $0.path) })
        }
        for legacy in ["Dropbox", "OneDrive"] {
            let url = home.appendingPathComponent(legacy)
            if isDirectory(atPath: url.path) { roots.append(url) }
        }
        return roots
    }

    /// 探测备份时要翻的**所有**目录,按"最可能是权威的那份"排在前面。
    ///
    /// 为什么探测的范围必须比写入的范围大:写入只写一个地方(`folderURL`),但**换新机器时,
    /// "备份在哪"这个信息本身存在旧机器的偏好里,新机器恰恰没有**。如果只按 folderURL 找,
    /// 一个把备份放在 Dropbox 的用户在新机器上首启时会什么都找不到 —— 因为新机器的
    /// UserDefaults 是空的,customFolderPath 必然是 nil,folderURL 于是回退到 iCloud。
    /// 这就是 2026-08-13 用户问出来的那个洞。
    static func searchFolders() -> [URL] {
        var out: [URL] = [folderURL]
        let cloudDefault = cloudDocsURL.appendingPathComponent("Lyrimuse")
        if !out.contains(cloudDefault) { out.append(cloudDefault) }
        for root in knownCloudFolders() {
            out.append(root.appendingPathComponent("Lyrimuse"))
        }
        // 去重但保持顺序
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// 建好文件夹再把它交出去,给保存面板当默认落点用。
    ///
    /// 必须先建:`NSSavePanel.directoryURL` 指向一个不存在的目录时会被系统**静默忽略**,
    /// 面板会退回上次用过的位置 —— 表现成"我明明设了默认存到 iCloud,怎么还是打开在
    /// 别处"。建不出来(iCloud 目录不可写等)就返回它本身,让面板自己去回退。
    static func preparedFolderURL() -> URL {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        ensureFolderIcon(at: folderURL)
        return folderURL
    }

    /// 给备份文件夹贴上 App 图标,在 Finder 一排蓝文件夹里能一眼认出来。
    ///
    /// macOS 存自定义图标的方式是在文件夹**内部**放一个隐藏文件,文件名是 `Icon` 加一个
    /// 回车符(`Icon\r`)。因为它就是目录里的一个普通文件,所以会跟着 iCloud/Dropbox 一起
    /// 同步 —— 新机器上那个文件夹同样带图标,不用各自再设一次。
    ///
    /// 它不会被备份探测误认:`ConfigSnapshotName` 只认 `Lyrimuse-Config-<时间>.json`
    /// (selftest 里有针对这个文件名的断言)。
    ///
    /// 图标取 `NSImage.applicationIconName` 而不是去 /Applications 里按路径读 —— 那是本
    /// 进程自己的图标,带全部分辨率,也不依赖 App 装在哪。
    static func ensureFolderIcon(at folder: URL) {
        // 已经有了就不再写。setIcon 会重写资源文件并触碰目录,而 preparedFolderURL 在每次
        // 导出/打开菜单时都会被调 —— 每次都写一遍等于每次都让同步服务认为这个文件夹变了。
        let marker = folder.appendingPathComponent("Icon\r")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        guard let icon = NSImage(named: NSImage.applicationIconName) else { return }
        let ok = NSWorkspace.shared.setIcon(icon, forFile: folder.path, options: [])
        logger.info("folder icon applied to \(folder.lastPathComponent, privacy: .public): \(ok, privacy: .public)")
    }

    /// 启动时调:文件夹**已经存在**才补图标,不为了贴个图标去创建一个用户还没用过的目录。
    static func ensureFolderIconIfPresent() {
        guard isAvailable else { return }
        let url = folderURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        ensureFolderIcon(at: url)
    }

    /// iCloud 里的一份配置。
    struct Snapshot {
        /// 指向真实文件名的 URL(即便磁盘上现在只是个未下载的占位符,这里也已经换成真名,
        /// 可以直接交给 `read(_:)`)。
        let url: URL
        /// 文件的修改时间 —— 用来排序"哪份最新"。
        let modifiedAt: Date
        /// 这份备份所在的目录。探测范围比写入范围大(见 searchFolders),所以找到的那份
        /// 未必来自当前的 folderURL —— 导入时要据此把备份文件夹一并切过去,否则用户从
        /// Dropbox 恢复完,之后的"更新备份"还是写去 iCloud,两边就分裂了。
        let folderURL: URL
        /// 配置里自报的导出时间/机器名(读文件内容才有,列目录阶段拿不到)。
        var exportedAt: Date?
        var deviceName: String?
    }

    // MARK: - 列目录

    /// 所有候选目录里最新的那一份配置。没有就返回 nil。
    ///
    /// 翻的是 `searchFolders()` 而不是单个 `folderURL` —— 理由见那边的注释(换新机器时
    /// "备份在哪"这个信息只存在旧机器上)。跨目录之间同样按修改时间比,取最新的一份。
    ///
    /// 只列目录、不读内容 —— 未下载的文件在这一步也能被看到(见
    /// `ConfigSnapshotName.realName(ofDirectoryEntry:)`),真正要读的时候才触发下载。
    static func latestSnapshot() -> Snapshot? {
        let folders = searchFolders()
        let hit = BackupDiscovery.latest(in: folders)
        // 记一笔"翻了几个目录、最后选中哪个"——这条链路(尤其是从 iCloud 之外的目录命中)
        // 只在换机器时走一次,出问题时没有现场可看,日志是唯一线索。目录名不敏感。
        logger.info("""
            snapshot scan: \(folders.count, privacy: .public) folder(s), \
            picked \(hit?.folder.lastPathComponent ?? "none", privacy: .public)
            """)
        let best = hit.map {
            Snapshot(url: $0.url, modifiedAt: $0.modifiedAt, folderURL: $0.folder)
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
    /// 判据本身(尤其"拿不到状态时怎么算"那一档,2026-08-24 修的就是它)是纯逻辑,抽在
    /// `ICloudFileReadiness` 里由自测覆盖 —— 这里只负责把两个事实查出来喂给它。
    static func isMaterialized(_ url: URL) -> Bool {
        var probe = url
        // 资源属性是带缓存的,轮询时不清缓存会一直读到第一次那个旧状态
        probe.removeCachedResourceValue(forKey: .ubiquitousItemDownloadingStatusKey)
        let status = (try? probe.resourceValues(
            forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        return ICloudFileReadiness.isReadyToRead(
            downloadingStatus: status,
            realPathExists: FileManager.default.fileExists(atPath: url.path))
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
        if case .data(let data) = await readOutcome(url, timeout: timeout) { return data }
        return nil
    }

    /// `read` 的完整结果。分出 `.downloading` 这一档是为了让界面能说实话:
    /// "已经在下了,等它下完"和"根本没能开始下"对用户是两件完全不同的事,而原来这两种
    /// 都返回 nil、界面一律提示"等一会儿再试" —— 后一种等到天荒地老也不会好
    /// (2026-08-24 用户在另一台机器上报的正是这个,病根见 `ICloudFileReadiness`)。
    enum ReadOutcome {
        case data(Data)
        /// 本机还没有这份文件,下载**已经发起**,但超时之前没下完。再点一次就行。
        case downloading
        /// 连下载都没能发起:没开 iCloud Drive、文件真的不在、或者这个目录不归 iCloud 管。
        case unavailable
    }

    static func readOutcome(_ url: URL, timeout: TimeInterval = 20) async -> ReadOutcome {
        if isMaterialized(url) {
            guard let data = await loadOffCallerThread(url) else { return .unavailable }
            return .data(data)
        }

        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            logger.notice("read: startDownloading failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }

        // 先等状态变成"已下载"再读,而不是直接读着等它物化 —— 直接读会把调用线程按在
        // 那儿直到下完,我们给的 timeout 就完全不起作用了。
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if isMaterialized(url) {
                guard let data = await loadOffCallerThread(url) else { return .unavailable }
                return .data(data)
            }
        }
        logger.notice("read: timed out waiting for iCloud download")
        return .downloading
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
            // 备份包里带着明文凭据。iCloud 那个父目录本身是 drwx------、本地已被兜住,
            // 收紧到 0600 主要是为了它被拷/移到别处之后仍然不松。
            try data.writeSecurely(to: url)
            return url
        } catch {
            logger.error("write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
