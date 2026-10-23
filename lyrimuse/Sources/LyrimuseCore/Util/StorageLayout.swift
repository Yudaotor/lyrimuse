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

    /// 认 Lyrimuse 数据的几个文件:搬迁标记、账号配置、功能开关、偏好镜像、歌词主缓存、听歌记录,有一个就算(刚装好、
    /// 没连账号也没放过歌的,至少有偏好镜像)。引擎 `paths.go` 的 `hasLyrimuseData` 同一份名单。
    public static let dataSignatureFiles = [
        StorageMigration.markerName, "config.json", "lyrimuse-features.json", "lyrimuse-app-settings.json",
        "lyrimuse-enrich-cache.json", "lyrimuse-listens.jsonl",
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

    /// 钥匙串保险箱条目的账号(钥匙串访问里「账户」那一栏)。数据目录在默认位置(新的或还没搬的旧的)时一律用新数据目录的路径串;
    /// 另起一份数据目录跑的(测试、排查)按自己的路径隔开。引擎侧 `credentialvault.go` 的 `credentialVaultAccount()` 同一条规则。
    public static func credentialAccount(dataDir: URL, roots: Roots) -> String {
        let path = dataDir.standardizedFileURL.path
        return isDefaultDataDir(path, roots: roots) ? roots.data.standardizedFileURL.path : path
    }

    /// 默认位置以前用过的账号(旧目录的路径串):那里有条目就搬到 `credentialAccount`。另起的数据目录没有。见 15 章决策 73。
    /// 引擎侧 `previousCredentialVaultAccount()` 同一条规则。
    public static func previousCredentialAccount(dataDir: URL, roots: Roots) -> String? {
        isDefaultDataDir(dataDir.standardizedFileURL.path, roots: roots) ? roots.legacy.standardizedFileURL.path : nil
    }

    private static func isDefaultDataDir(_ path: String, roots: Roots) -> Bool {
        path == roots.data.standardizedFileURL.path || path == roots.legacy.standardizedFileURL.path
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
        let kept = keptOldFolders(roots) + replacedBackups(in: active)
        let keptText = kept.isEmpty ? "" : "; kept from migration: " + kept.map { display($0) }.joined(separator: ", ")
        return "Data folder: \(display(active)) (old \(display(roots.legacy)): \(legacy)\(keptText))"
    }

    /// 合并时数据目录里被用户带来的旧目录换下来的那些文件(`backups/<时刻>-storage-migration-replaced`)。
    public static func replacedBackups(in dataDir: URL) -> [URL] {
        let backups = dataDir.appendingPathComponent("backups")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        return names.filter { $0.hasSuffix(StorageMigration.backupSuffix + StorageMigration.replacedSuffix) }.sorted()
            .map { backups.appendingPathComponent($0) }
    }

    /// 搬迁留下没删的旧目录:跨卷复制后改名的 `<旧目录名>.migrated`、合并时有冲突改名的 `<旧目录名>.leftover-<时刻>`。
    public static func keptOldFolders(_ roots: Roots) -> [URL] {
        let parent = roots.legacy.deletingLastPathComponent()
        let name = roots.legacy.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.filter { $0 == name + ".migrated" || $0.hasPrefix(name + ".leftover-") }.sorted()
            .map { parent.appendingPathComponent($0) }
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    public static func isDirectory(_ url: URL) -> Bool {
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
