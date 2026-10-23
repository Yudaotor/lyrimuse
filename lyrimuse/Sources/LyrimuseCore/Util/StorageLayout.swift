import Darwin
import Foundation

/// 数据目录和缓存目录放在哪、当前该用哪一个。见 14 章决策 136。
///
/// - 数据目录 `~/Library/Application Support/<bundle id>`:config.json、功能开关、设置镜像、歌词与手改、锁定、听歌记录、
///   待提交队列、备份、App 与引擎之间的请求 / 状态文件、单实例锁。
/// - 缓存目录 `~/Library/Caches/<bundle id>`:删了只会重新联网或重算的东西(`cacheFileNames`),另有动态封面和 Sparkle 的下载缓存。
/// - 旧目录 `~/.config/lyrimuse`:里面有数据、新目录里没有时(还没搬成)照旧用它,`StorageMigration` 在 App 启动时搬走或合并进来;
///   它是软链接时当成用户自己指定的位置,一直用、不搬。判断看目录里有没有 Lyrimuse 的数据,不看目录在不在:新目录可能是空的、
///   或被别的东西先建了出来。
///
/// 引擎侧同一套规则在 `lyrimuse-engine/paths.go`(`configDir()` / `cacheDir()`),App 经环境变量把算好的两个目录传过去。
public enum StorageLayout {
    public struct Roots: Equatable, Sendable {
        public let legacy: URL
        public let data: URL
        public let caches: URL

        public init(legacy: URL, data: URL, caches: URL) {
            self.legacy = legacy
            self.data = data
            self.caches = caches
        }
    }

    public static func roots(home: URL) -> Roots {
        Roots(
            legacy: home.appendingPathComponent(".config/\(LyrimuseIdentity.configDirName)"),
            data: home.appendingPathComponent("Library/Application Support/\(LyrimuseIdentity.bundleIdentifier)"),
            caches: home.appendingPathComponent("Library/Caches/\(LyrimuseIdentity.bundleIdentifier)"))
    }

    /// 当前该用的数据目录:旧目录是软链接 → 旧目录;旧目录不是目录 → 新目录;新目录搬过(有搬迁标记)→ 新目录(旧目录是
    /// 之后又冒出来的残留,下次启动合并进来);旧目录有数据、新目录没有 → 旧目录(还没搬);其余 → 新目录。
    public static func activeDataDir(_ roots: Roots) -> URL {
        if isSymlink(roots.legacy) { return roots.legacy }
        guard isDirectory(roots.legacy) else { return roots.data }
        if exists(roots.data.appendingPathComponent(StorageMigration.markerName)) { return roots.data }
        if hasLyrimuseData(roots.legacy) && !hasLyrimuseData(roots.data) { return roots.legacy }
        return roots.data
    }

    /// 旧位置有个真目录(不是软链接)要收进数据目录:还没搬,或者搬完之后又被旧版本、旧进程写出来的残留。
    public static func hasLegacyToAbsorb(_ roots: Roots) -> Bool {
        !isSymlink(roots.legacy) && isDirectory(roots.legacy)
    }

    /// 认 Lyrimuse 数据的几个文件:搬迁标记、账号配置、功能开关、歌词主缓存,有一个就算。引擎 `paths.go` 的
    /// `hasLyrimuseData` 同一份名单。
    public static let dataSignatureFiles = [
        StorageMigration.markerName, "config.json", "lyrimuse-features.json", "lyrimuse-enrich-cache.json",
    ]

    public static func hasLyrimuseData(_ dir: URL) -> Bool {
        dataSignatureFiles.contains { exists(dir.appendingPathComponent($0)) }
    }

    /// 存成值的绝对路径如果指在旧目录里(旧版本导出的备份、手写的配置),换成数据目录里同一个相对位置;别的原样返回。
    public static func mappingLegacyPath(_ path: String, roots: Roots, dataDir: URL) -> String {
        let legacy = roots.legacy.standardizedFileURL.path
        guard dataDir.standardizedFileURL.path != legacy else { return path }
        if path == legacy { return dataDir.path }
        guard path.hasPrefix(legacy + "/") else { return path }
        return dataDir.path + path.dropFirst(legacy.count)
    }

    /// 钥匙串保险箱条目的账号。数据目录在默认位置(新的或还没搬的旧的)时一律用旧目录的路径串:它只是个名字,
    /// 搬目录不改它,钥匙串就不用跟着迁,旧版本也读得到;另起一份数据目录跑的(测试、排查)按自己的路径隔开。
    /// 引擎侧 `credentialvault.go` 的 `credentialVaultAccount()` 同一条规则。
    public static func credentialAccount(dataDir: URL, roots: Roots) -> String {
        let path = dataDir.standardizedFileURL.path
        if path == roots.data.standardizedFileURL.path || path == roots.legacy.standardizedFileURL.path {
            return roots.legacy.standardizedFileURL.path
        }
        return path
    }

    /// 只放在缓存目录里的文件:删掉只会重新联网查一次或重算一遍,没有用户输入、历史、待发队列,也不是 App 与引擎之间的
    /// 请求 / 状态文件。名字带 cache、实际是权威数据的(enrich 缓存、设备封面 `artwork/`)不在这里。逐项依据见 14 章决策 136;
    /// 引擎侧写这些文件的地方都走 `cacheFilePath`,两边名单一致(selftest identity 组对账)。
    public static let cacheFileNames: [String] = [
        // 引擎写
        "lyrimuse-accent-words.json", "lyrimuse-amll-index.json", "lyrimuse-apple-album-hint-cache.json",
        "lyrimuse-apple-catalog-names.json", "lyrimuse-apple-storefront-artist-cache.json",
        "lyrimuse-apple-storefront-title-cache.json", "lyrimuse-applemusic-devtoken.json", "lyrimuse-artist-alias-cache.json",
        "lyrimuse-artist-avatar-cache.json", "lyrimuse-artist-identity-cache.json", "lyrimuse-artist-primary-cache.json",
        "lyrimuse-artist-regions.json", "lyrimuse-artwork-confirmed.json", "lyrimuse-clash-node-blocks.json",
        "lyrimuse-digest-artist-totals.json", "lyrimuse-feature-flags-logged.json", "lyrimuse-mb-recordings.json",
        "lyrimuse-motion-cover-cache.json", "lyrimuse-musixmatch-token.json", "lyrimuse-netease-names.json",
        "lyrimuse-platform-pages-cache.json", "lyrimuse-proxy-hint.json", "lyrimuse-qq-artist-name-cache.json",
        "lyrimuse-soda-track-cache.json", "lyrimuse-spotify-lyrics-index.json", "lyrimuse-artist-avatar-cache.json.lock",
        // App 写
        "lyrimuse-editorial-cache.json", "lyrimuse-lastfm-alias-baseline.json", "lyrimuse-lastfm-daily-heatmap.json",
        "lyrimuse-lastfm-history-checkpoint.json", "lyrimuse-lastfm-recent-pages.json", "lyrimuse-lastfm-stats-cache.json",
        "lyrimuse-lastfm-title-forms.json", "lyrimuse-library-digest.json",
    ]

    /// 诊断导出里的一行:用的是哪个数据目录,旧目录还在不在(没搬成、降级后又升级都会留下它)。
    public static func diagnosticLine(roots: Roots, active: URL, home: String = NSHomeDirectory()) -> String {
        let legacy = isSymlink(roots.legacy) ? "symlink" : isDirectory(roots.legacy) ? "present" : "absent"
        let display: (URL) -> String = { HomeFolderAccess.displayPath($0.path, home: home) }
        return "Data folder: \(display(active)) (old \(display(roots.legacy)): \(legacy))"
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    static func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }
}
