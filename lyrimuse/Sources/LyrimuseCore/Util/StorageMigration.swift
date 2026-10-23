import Darwin
import Foundation

/// 把旧布局搬成 `StorageLayout` 的新布局:旧目录收进数据目录、改写文件里存着的旧绝对路径、把缓存文件挪进缓存目录。
/// App 启动最早处调(`StorageMigrationRunner`),调用方保证引擎和别的 App 实例这时都没在跑。每一步都能重跑,没做完的下次启动接着做;
/// 任何时候都不删一份内容跟数据目录里不一样的旧文件。见 14 章决策 136。
public enum StorageMigration {
    public struct Outcome: Equatable, Sendable {
        public var movedRoot = false
        public var copiedRoot = false
        /// 合并时挪进数据目录的条目数(整个子目录挪过去算一条)。
        public var mergedItems = 0
        /// 合并时两边都有、内容不同的条目数。数据目录搬过(有标记)时以它为准,旧的那份留在 `keptLeftover` 里;没搬过(新装的)
        /// 时以旧目录为准,数据目录里被换下来的那份挪进 `replacedBackup`。
        public var conflicts = 0
        /// 合并时数据目录里被旧目录换下来的那些文件存到了哪(`backups/<时刻>-storage-migration-replaced`)。
        public var replacedBackup: String?
        /// 合并完旧目录还剩东西时,改名到的位置。
        public var keptLeftover: String?
        /// 改写旧路径之前,被改写的那些文件的原件存到了哪(`backups/<时刻>-storage-migration`)。
        public var rewriteBackup: String?
        public var rewrittenFiles = 0
        public var relocatedCaches = 0
        /// 这次在旧位置建了指向数据目录的软链接。
        public var madeCompatLink = false
        /// 这次删掉了到期的软链接。
        public var removedCompatLink = false
        /// 从旧目录旁边的 `<旧目录名>-backups/` 挪进数据目录 `backups/` 的引擎留底个数。
        public var movedEngineBackups = 0
        /// 从 `~/Library/Logs/` 挪进 `~/Library/Logs/Lyrimuse/` 的日志文件个数。
        public var relocatedLogs = 0
        public var failures: [String] = []

        public init() {}

        public var changedAnything: Bool {
            movedRoot || copiedRoot || mergedItems > 0 || keptLeftover != nil || rewrittenFiles > 0 || relocatedCaches > 0
                || relocatedLogs > 0
        }
    }

    /// 搬迁标记:记着从哪搬到哪、文件里的旧路径改写完没有。整份改名时动手之前写进旧目录、跟着一起走,中途崩溃下次启动照样
    /// 接着改写;合并时合并完再写进数据目录(合并没做完旧目录还在,下次启动会再合并一遍、再写)。它也是「这个数据目录搬过」的
    /// 凭据(`StorageLayout.activeDataDir`)。
    static let markerName = "lyrimuse-storage-migration.json"

    struct Marker: Codable, Equatable {
        var from: String
        var to: String
        var rewritePending: Bool
    }

    /// 有没有要做的。启动路径上每次都调:几十次 lstat 加一次小文件读。
    public static func isPending(
        _ roots: StorageLayout.Roots, cacheNames: [String] = StorageLayout.cacheFileNames,
        logNames: [String] = LogFiles.fileNames, now: Date = Date()
    ) -> Bool {
        if StorageLayout.hasLegacyToAbsorb(roots) || compatLinkExpired(roots, now: now) { return true }
        if !legacyEngineBackups(roots).isEmpty || !legacyLogs(roots, names: logNames).isEmpty { return true }
        let data = StorageLayout.activeDataDir(roots)
        if pendingRewrite(in: data) != nil { return true }
        return cacheNames.contains { StorageLayout.exists(data.appendingPathComponent($0)) }
    }

    /// `forceCopy` 只给 selftest 走跨卷那条路用。
    public static func run(
        _ roots: StorageLayout.Roots, cacheNames: [String] = StorageLayout.cacheFileNames, forceCopy: Bool = false,
        logNames: [String] = LogFiles.fileNames, now: Date = Date()
    ) -> Outcome {
        var outcome = Outcome()
        if compatLinkExpired(roots, now: now) {
            removeCompatLink(roots, &outcome)
        }
        if StorageLayout.hasLegacyToAbsorb(roots) {
            absorbLegacy(roots, forceCopy: forceCopy, &outcome)
        }
        let data = StorageLayout.activeDataDir(roots)
        if var pending = pendingRewrite(in: data) {
            if rewritePaths(in: data, from: pending.from, to: pending.to, &outcome) {
                pending.rewritePending = false
            }
            writeMarker(pending, in: data, &outcome)
        }
        absorbLegacyEngineBackups(roots, into: data, &outcome)
        relocateCaches(from: data, to: roots.caches, names: cacheNames, &outcome)
        relocateLogs(roots, names: logNames, &outcome)
        return outcome
    }

    /// 这个目录里还没做完的改写。标记写的目的地不是它(整份改名没成、标记还留在旧目录里)时不算:那时数据还在旧目录,
    /// 把里面的路径改成新目录的就全指错了。
    static func pendingRewrite(in data: URL) -> Marker? {
        guard let marker = readMarker(in: data), marker.rewritePending,
              URL(fileURLWithPath: marker.to).standardizedFileURL.path == data.standardizedFileURL.path else { return nil }
        return marker
    }

    // MARK: - 旧目录

    /// 数据目录里还没有 Lyrimuse 的数据(不存在、空的、或只有别的东西):空的先删掉,整份改名过去;同卷一次 `rename(2)`,
    /// 跨卷(`~/.config` 被链到别的盘)先拷进旁边的暂存目录、核对文件清单和大小再换上去,旧目录改名留着。数据目录已经有数据时
    /// 逐项合并(`mergeTree`),冲突听谁的看数据目录搬没搬过:搬过(有标记)→ 旧目录是之后又冒出来的残留,听数据目录的;没搬过
    /// → 数据目录是新版本新装出来的,旧目录是用户带来的(换机器时拷过来、dotfiles 工具铺的),听旧目录的。旧位置空出来后
    /// 留一个指向数据目录的软链接(`makeCompatLink`)。失败的那一步不动旧目录,下次启动重试。
    static func absorbLegacy(_ roots: StorageLayout.Roots, forceCopy: Bool, _ outcome: inout Outcome) {
        guard FileIO.createDirectory(roots.data.deletingLastPathComponent()) else {
            outcome.failures.append("create \(roots.data.deletingLastPathComponent().path)")
            return
        }
        let pending = Marker(from: roots.legacy.path, to: roots.data.path, rewritePending: true)
        if !StorageLayout.hasLyrimuseData(roots.data) {
            if StorageLayout.isDirectory(roots.data) { removeIfEffectivelyEmpty(roots.data) }
            if !StorageLayout.exists(roots.data) {
                writeMarker(pending, in: roots.legacy, &outcome)
                if !forceCopy, rename(roots.legacy.path, roots.data.path) == 0 {
                    outcome.movedRoot = true
                } else if forceCopy || errno == EXDEV {
                    outcome.copiedRoot = copyRoot(roots, &outcome)
                } else {
                    outcome.failures.append("rename \(roots.legacy.path): \(String(cString: strerror(errno)))")
                }
                if (outcome.movedRoot || outcome.copiedRoot), readMarker(in: roots.data) == nil {
                    writeMarker(pending, in: roots.data, &outcome)
                }
                makeCompatLink(roots, &outcome)
                return
            }
        }
        let legacyWins = !StorageLayout.exists(roots.data.appendingPathComponent(markerName))
        let replaced = roots.data.appendingPathComponent("backups/\(stamp(Date()))\(backupSuffix)\(replacedSuffix)")
        mergeTree(from: roots.legacy, into: roots.data, relative: "", legacyWins: legacyWins ? replaced : nil, &outcome)
        writeMarker(pending, in: roots.data, &outcome)
        pruneEmptyDirectories(roots.legacy)
        if StorageLayout.exists(roots.legacy) {
            let kept = roots.legacy.deletingLastPathComponent()
                .appendingPathComponent(roots.legacy.lastPathComponent + ".leftover-" + stamp(Date()))
            guard rename(roots.legacy.path, kept.path) == 0 else {
                outcome.failures.append("rename leftover: \(String(cString: strerror(errno)))")
                return
            }
            outcome.keptLeftover = kept.path
        }
        makeCompatLink(roots, &outcome)
    }

    // MARK: - 留给旧版本的软链接

    /// 搬完之后旧位置留一个指向数据目录的软链接,保留这么久:这段时间里装回旧版本(只认旧位置),读写的还是同一份数据。
    /// 到期在启动时删掉(`removeCompatLink`)。
    static let compatLinkRetention: TimeInterval = 30 * 24 * 3600

    /// 旧位置空出来时建软链接,内容是数据目录的绝对路径。建不成只记一条,不影响搬迁本身。
    static func makeCompatLink(_ roots: StorageLayout.Roots, _ outcome: inout Outcome) {
        guard !StorageLayout.exists(roots.legacy) else { return }
        if symlink(roots.data.path, roots.legacy.path) == 0 {
            outcome.madeCompatLink = true
        } else {
            outcome.failures.append("link \(roots.legacy.path): \(String(cString: strerror(errno)))")
        }
    }

    /// 软链接建了超过 `compatLinkRetention`(按链接本身的修改时刻,建好就不再变)。
    static func compatLinkExpired(_ roots: StorageLayout.Roots, now: Date) -> Bool {
        var st = stat()
        guard StorageLayout.isCompatLink(roots), lstat(roots.legacy.path, &st) == 0 else { return false }
        return now.timeIntervalSince1970 - TimeInterval(st.st_mtimespec.tv_sec) > compatLinkRetention
    }

    /// 删掉到期的软链接。装回过旧版本的话,它这段时间写进文件的路径(设备封面地址、歌词文件夹)是经软链接的旧路径,
    /// 删之前把改写重新挂上,接着的改写换成数据目录的;没装回过就是扫一遍、什么都不改。
    static func removeCompatLink(_ roots: StorageLayout.Roots, _ outcome: inout Outcome) {
        writeMarker(Marker(from: roots.legacy.path, to: roots.data.path, rewritePending: true), in: roots.data, &outcome)
        guard unlink(roots.legacy.path) == 0 else {
            outcome.failures.append("unlink \(roots.legacy.path): \(String(cString: strerror(errno)))")
            return
        }
        outcome.removedCompatLink = true
    }

    /// 把 `source` 里数据目录没有的条目挪过去(整个子目录不在就整个挪);两边都有的子目录往里递归;两边都有的文件内容一样就删掉旧的。
    /// 不一样时:`legacyWins` 为 nil 以数据目录为准、旧的原地留着;否则把数据目录那份挪进 `legacyWins` 下同一相对路径、旧的挪进来,
    /// 挪不走就当冲突留着。`.DS_Store` 和锁文件不算内容,冲突时直接删旧的。
    static func mergeTree(from source: URL, into target: URL, relative: String, legacyWins: URL?, _ outcome: inout Outcome) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: source.path) else {
            outcome.failures.append("list \(source.path)")
            return
        }
        for name in names {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            if !StorageLayout.exists(to) {
                if rename(from.path, to.path) == 0 {
                    outcome.mergedItems += 1
                } else if errno == EXDEV, FileIO.attempt("copy", from, { try FileManager.default.copyItem(at: from, to: to) }),
                          treeListing(from) == treeListing(to) {
                    _ = FileIO.remove(from)
                    outcome.mergedItems += 1
                } else {
                    outcome.failures.append("merge \(name): \(String(cString: strerror(errno)))")
                }
            } else if StorageLayout.isDirectory(from), StorageLayout.isDirectory(to) {
                let sub = relative.isEmpty ? name : relative + "/" + name
                mergeTree(from: from, into: to, relative: sub, legacyWins: legacyWins, &outcome)
            } else if name == ".DS_Store" || name.hasSuffix(".lock") || sameContents(from, to) {
                _ = FileIO.remove(from)
            } else {
                outcome.conflicts += 1
                guard let replaced = legacyWins else { continue }
                let aside = replaced.appendingPathComponent(relative.isEmpty ? name : relative + "/" + name)
                guard FileIO.createDirectory(aside.deletingLastPathComponent()), rename(to.path, aside.path) == 0 else {
                    outcome.failures.append("move aside \(name): \(String(cString: strerror(errno)))")
                    continue
                }
                outcome.replacedBackup = replaced.path
                if rename(from.path, to.path) != 0 {
                    outcome.failures.append("merge \(name): \(String(cString: strerror(errno)))")
                    _ = rename(aside.path, to.path)
                }
            }
        }
    }

    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard StorageLayout.isRegularFile(a), StorageLayout.isRegularFile(b),
              let x = FileIO.read(a, options: .alwaysMapped), let y = FileIO.read(b, options: .alwaysMapped) else { return false }
        return x == y
    }

    /// 自底向上删掉空目录(只剩 `.DS_Store` 的也算空)。
    static func pruneEmptyDirectories(_ dir: URL) {
        guard StorageLayout.isDirectory(dir), !StorageLayout.isSymlink(dir),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name != ".DS_Store" {
            pruneEmptyDirectories(dir.appendingPathComponent(name))
        }
        removeIfEffectivelyEmpty(dir)
    }

    static func removeIfEffectivelyEmpty(_ dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              names.allSatisfy({ $0 == ".DS_Store" }) else { return }
        for name in names { _ = FileIO.remove(dir.appendingPathComponent(name)) }
        rmdir(dir.path)
    }

    static func copyRoot(_ roots: StorageLayout.Roots, _ outcome: inout Outcome) -> Bool {
        let fm = FileManager.default
        let staging = roots.data.deletingLastPathComponent().appendingPathComponent(roots.data.lastPathComponent + ".incoming")
        _ = FileIO.remove(staging)
        do {
            try fm.copyItem(at: roots.legacy, to: staging)
        } catch {
            outcome.failures.append("copy: \(FileIO.describe(error))")
            _ = FileIO.remove(staging)
            return false
        }
        guard treeListing(roots.legacy) == treeListing(staging) else {
            outcome.failures.append("copy verification: file list or sizes differ")
            _ = FileIO.remove(staging)
            return false
        }
        guard rename(staging.path, roots.data.path) == 0 else {
            outcome.failures.append("rename staging: \(String(cString: strerror(errno)))")
            _ = FileIO.remove(staging)
            return false
        }
        let kept = roots.legacy.deletingLastPathComponent().appendingPathComponent(roots.legacy.lastPathComponent + ".migrated")
        if rename(roots.legacy.path, kept.path) != 0 {
            outcome.failures.append("rename old folder: \(String(cString: strerror(errno)))")
        }
        return true
    }

    /// 目录树里每一项的相对路径、类型和大小,核对拷贝用。
    static func treeListing(_ root: URL) -> [String: String] {
        var listing: [String: String] = [:]
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: root.path) else { return listing }
        for relative in subpaths {
            var st = stat()
            guard lstat(root.appendingPathComponent(relative).path, &st) == 0 else {
                listing[relative] = "missing"
                continue
            }
            switch st.st_mode & S_IFMT {
            case S_IFLNK: listing[relative] = "link"
            case S_IFDIR: listing[relative] = "dir"
            default: listing[relative] = "file \(st.st_size)"
            }
        }
        return listing
    }

    // MARK: - 文件里存着的旧路径

    /// 不进去看的子目录:歌词文本、正文小文件、决策留痕、设备封面、字体。里面不存数据目录的路径,文件却占了绝大多数
    /// (本机 7 万个文件里 6.8 万个),一份份读要一分多钟。`backups/` 是快照(含改写前的原件),原样留着。
    static let skippedDirectories: Set<String> = ["lyrics", "lyrimuse-lyrics-bodies", "lyrimuse-decisions", "artwork", "fonts", "backups"]

    /// 不看的扩展名:图片、视频、字体、歌词文本、崩溃报告、锁文件,里面不会存数据目录的路径;另有引擎一次性迁移留的
    /// `.bak`(几百 MB,30 天后引擎自己删,没有代码读它)。
    static let skippedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "webp", "gif", "mp4", "mov", "ttf", "otf", "ttc", "woff", "woff2",
        "lrc", "yrc", "ips", "lock", "bak",
    ]

    /// 设备封面的 `file://` 地址、自定义歌词目录这类存成绝对路径的值,在 enrich 缓存、歌曲实体、留底和备份里都有。
    /// 只换「旧目录 + `/`」和「旧目录 + `"`」两种写法(外加 JSON 把 `/` 转义成 `\/` 的写法),
    /// 别的以旧目录名开头的兄弟目录(如 `~/.config/lyrimuse-backups`)不碰。每份文件改写之前先把原件克隆进
    /// `backups/<时刻>-storage-migration/`(同一相对路径,APFS 上不占空间),克隆不成就不改这一份、留到下次;改完原子换上去、保留权限。
    static func rewritePaths(in dir: URL, from old: String, to new: String, _ outcome: inout Outcome) -> Bool {
        let pairs = replacementPairs(from: old, to: new)
        let backupRoot = dir.appendingPathComponent("backups/\(stamp(Date()))\(backupSuffix)")
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else {
            outcome.failures.append("enumerate \(dir.path)")
            return false
        }
        var ok = true
        for case let url as URL in walker {
            if walker.level == 1, skippedDirectories.contains(url.lastPathComponent),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                walker.skipDescendants()
                continue
            }
            guard !skippedExtensions.contains(url.pathExtension.lowercased()),
                  ![".DS_Store", markerName].contains(url.lastPathComponent) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  (values.fileSize ?? 0) < 2_000_000_000 else { continue }
            guard let data = FileIO.read(url, options: .alwaysMapped) else {
                outcome.failures.append("read \(url.lastPathComponent)")
                ok = false
                continue
            }
            guard let rewritten = replacingAll(in: data, pairs) else { continue }
            let relative = url.pathComponents.suffix(walker.level).joined(separator: "/")
            guard backupOriginal(url, relativePath: relative, into: backupRoot) else {
                outcome.failures.append("back up \(url.lastPathComponent) before rewriting")
                ok = false
                continue
            }
            outcome.rewriteBackup = backupRoot.path
            if replaceFile(url, with: rewritten) {
                outcome.rewrittenFiles += 1
            } else {
                outcome.failures.append("write \(url.lastPathComponent)")
                ok = false
            }
        }
        return ok
    }

    /// 改写前原件那份快照的目录名后缀;前面是 `yyyyMMdd-HHmmss`。
    static let backupSuffix = "-storage-migration"

    /// 合并时被换下来的那份的目录名再加的后缀(`StorageLayout.replacedBackups` 按它认),不按 `backupRetention` 清。
    static let replacedSuffix = "-replaced"

    /// 快照保留多久。过了就在启动时删掉(`pruneRewriteBackups`)。
    static let backupRetention: TimeInterval = 30 * 24 * 3600

    /// 把 `url` 克隆到 `root` 下的 `relativePath`;那里已经有一份(同一轮里更早存的原件)就留着它。
    static func backupOriginal(_ url: URL, relativePath: String, into root: URL) -> Bool {
        guard !relativePath.isEmpty else { return false }
        let target = root.appendingPathComponent(relativePath)
        if StorageLayout.exists(target) { return true }
        guard FileIO.createDirectory(target.deletingLastPathComponent()) else { return false }
        if clonefile(url.path, target.path, 0) == 0 { return true }
        return FileIO.attempt("copy", url) { try FileManager.default.copyItem(at: url, to: target) }
    }

    /// 删掉数据目录 `backups/` 里超过 `backupRetention` 的改写前快照(按目录名里的时刻算,认不出时刻的不动)。
    /// 每次启动都调,不用停引擎:引擎和 App 都不碰这些目录。
    @discardableResult
    public static func pruneRewriteBackups(in dataDir: URL, now: Date = Date()) -> Int {
        let backups = dataDir.appendingPathComponent("backups")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: backups.path) else { return 0 }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyyMMdd-HHmmss"
        var removed = 0
        for name in names where name.hasSuffix(backupSuffix) {
            guard let date = parser.date(from: String(name.dropLast(backupSuffix.count))),
                  now.timeIntervalSince(date) > backupRetention,
                  FileIO.remove(backups.appendingPathComponent(name)) else { continue }
            removed += 1
        }
        return removed
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func replacementPairs(from old: String, to new: String) -> [(Data, Data)] {
        func escaped(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "\\/") }
        return [
            (old + "/", new + "/"),
            (old + "\"", new + "\""),
            (escaped(old) + "\\/", escaped(new) + "\\/"),
            (escaped(old) + "\"", escaped(new) + "\""),
        ].map { (Data($0.0.utf8), Data($0.1.utf8)) }
    }

    /// 依次把每一对全部替换掉;一处都没有返回 nil。
    static func replacingAll(in data: Data, _ pairs: [(Data, Data)]) -> Data? {
        var current = data
        var changed = false
        for (needle, replacement) in pairs {
            guard let next = replacing(needle, with: replacement, in: current) else { continue }
            current = next
            changed = true
        }
        return changed ? current : nil
    }

    static func replacing(_ needle: Data, with replacement: Data, in data: Data) -> Data? {
        guard !needle.isEmpty, data.count >= needle.count else { return nil }
        var ranges: [Range<Int>] = []
        data.withUnsafeBytes { (hay: UnsafeRawBufferPointer) in
            needle.withUnsafeBytes { (pin: UnsafeRawBufferPointer) in
                guard let base = hay.baseAddress, let pinBase = pin.baseAddress else { return }
                var offset = 0
                while offset <= hay.count - pin.count,
                      let hit = memmem(base + offset, hay.count - offset, pinBase, pin.count) {
                    let start = base.distance(to: UnsafeRawPointer(hit))
                    ranges.append(start..<(start + pin.count))
                    offset = start + pin.count
                }
            }
        }
        guard !ranges.isEmpty else { return nil }
        var out = Data()
        out.reserveCapacity(data.count + ranges.count * max(0, replacement.count - needle.count))
        var cursor = 0
        for range in ranges {
            out.append(data[data.startIndex + cursor ..< data.startIndex + range.lowerBound])
            out.append(replacement)
            cursor = range.upperBound
        }
        out.append(data[(data.startIndex + cursor)...])
        return out
    }

    /// 同目录临时文件 + `rename(2)`,保留原文件的权限位(config.json 这类是 600)。
    static func replaceFile(_ url: URL, with data: Data) -> Bool {
        let fm = FileManager.default
        let permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).storage-rewrite-\(getpid())")
        guard FileIO.write(data, to: temp, options: []) else { return false }
        if let permissions {
            _ = try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        }
        guard rename(temp.path, url.path) == 0 else {
            _ = FileIO.remove(temp)
            return false
        }
        return true
    }

    // MARK: - 缓存

    /// 缓存目录里已有同名的以缓存目录的为准(引擎已经在往那边写),数据目录里那份删掉;跨卷改不了名也直接删,能重建。
    static func relocateCaches(from data: URL, to caches: URL, names: [String], _ outcome: inout Outcome) {
        let present = names.filter { StorageLayout.exists(data.appendingPathComponent($0)) }
        guard !present.isEmpty else { return }
        guard FileIO.createDirectory(caches) else {
            outcome.failures.append("create \(caches.path)")
            return
        }
        for name in present {
            let source = data.appendingPathComponent(name)
            let target = caches.appendingPathComponent(name)
            if !StorageLayout.exists(target), rename(source.path, target.path) == 0 {
                outcome.relocatedCaches += 1
            } else if FileIO.remove(source) {
                outcome.relocatedCaches += 1
            } else {
                outcome.failures.append("relocate \(name)")
            }
        }
    }

    // MARK: - 旧版本引擎在旁边留的备份

    /// 旧版本的引擎把歌曲实体同步前的留底放在旧目录旁边的 `<旧目录名>-backups/`(`<时刻>-song-entity`、
    /// `<时刻>-song-entity-manual`),现在的放数据目录的 `backups/`。只认这两种名字,那个目录里别的东西不碰。
    static func legacyBackupsDir(_ roots: StorageLayout.Roots) -> URL {
        roots.legacy.deletingLastPathComponent().appendingPathComponent(roots.legacy.lastPathComponent + "-backups")
    }

    public static func isEngineBackupName(_ name: String) -> Bool {
        for suffix in ["-song-entity", "-song-entity-manual"] where name.hasSuffix(suffix) {
            let stamp = Array(name.dropLast(suffix.count))
            return stamp.count == 15 && stamp[8] == "-"
                && stamp.enumerated().allSatisfy { $0.offset == 8 || ("0"..."9").contains($0.element) }
        }
        return false
    }

    static func legacyEngineBackups(_ roots: StorageLayout.Roots) -> [String] {
        let dir = legacyBackupsDir(roots)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { isEngineBackupName($0) && StorageLayout.isDirectory(dir.appendingPathComponent($0)) }.sorted()
    }

    /// 把旧版本引擎的留底挪进数据目录 `backups/`(那里已有同名的就加 `-old` 后缀),挪空了删掉那个目录。
    /// 同步状态文件 `lyrimuse-song-entity-share.json` 里记着第一份留底的路径,一起换成新位置(引擎只看它空不空,
    /// 不读那里的东西;换之前原件照样存一份)。
    static func absorbLegacyEngineBackups(_ roots: StorageLayout.Roots, into data: URL, _ outcome: inout Outcome) {
        let names = legacyEngineBackups(roots)
        guard !names.isEmpty else { return }
        let source = legacyBackupsDir(roots)
        let target = data.appendingPathComponent("backups")
        guard FileIO.createDirectory(target) else {
            outcome.failures.append("create \(target.path)")
            return
        }
        var moved: [(from: String, to: String)] = []
        for name in names {
            let from = source.appendingPathComponent(name)
            var to = target.appendingPathComponent(name)
            if StorageLayout.exists(to) { to = target.appendingPathComponent(name + "-old") }
            if StorageLayout.exists(to) {
                outcome.failures.append("move backup \(name): already in \(target.path)")
            } else if rename(from.path, to.path) == 0 {
                moved.append((from.path, to.path))
            } else if errno == EXDEV, FileIO.attempt("copy", from, { try FileManager.default.copyItem(at: from, to: to) }),
                      treeListing(from) == treeListing(to) {
                _ = FileIO.remove(from)
                moved.append((from.path, to.path))
            } else {
                outcome.failures.append("move backup \(name): \(String(cString: strerror(errno)))")
            }
        }
        outcome.movedEngineBackups = moved.count
        removeIfEffectivelyEmpty(source)
        let state = data.appendingPathComponent("lyrimuse-song-entity-share.json")
        guard !moved.isEmpty, let original = FileIO.read(state) else { return }
        var current = original
        for pair in moved {
            current = replacingAll(in: current, replacementPairs(from: pair.from, to: pair.to)) ?? current
        }
        guard current != original else { return }
        let backupRoot = data.appendingPathComponent("backups/\(stamp(Date()))\(backupSuffix)")
        guard backupOriginal(state, relativePath: state.lastPathComponent, into: backupRoot) else {
            outcome.failures.append("back up \(state.lastPathComponent) before rewriting")
            return
        }
        outcome.rewriteBackup = backupRoot.path
        if !replaceFile(state, with: current) {
            outcome.failures.append("write \(state.lastPathComponent)")
        }
    }

    // MARK: - 日志

    /// 旧位置(`~/Library/Logs/`)还在的日志文件名。那是共用目录,只认 `names` 里的普通文件。
    static func legacyLogs(_ roots: StorageLayout.Roots, names: [String]) -> [String] {
        names.filter { StorageLayout.isRegularFile(roots.legacyLogs.appendingPathComponent($0)) }
    }

    /// 挪进日志目录。那边已有同名的(装回过旧版本、又升级回来)以那边为准,旧位置那份改名成 `<名字>.previous-version`
    /// 放进去(盖掉更早的一份)。引擎这时已经停了;正写着的文件挪走也不丢,写的人下次打开才换到新位置。
    static func relocateLogs(_ roots: StorageLayout.Roots, names: [String], _ outcome: inout Outcome) {
        let present = legacyLogs(roots, names: names)
        guard !present.isEmpty else { return }
        guard FileIO.createDirectory(roots.logs) else {
            outcome.failures.append("create \(roots.logs.path)")
            return
        }
        for name in present {
            let source = roots.legacyLogs.appendingPathComponent(name)
            var target = roots.logs.appendingPathComponent(name)
            if StorageLayout.exists(target) {
                target = roots.logs.appendingPathComponent(name + ".previous-version")
                if StorageLayout.exists(target) { _ = FileIO.remove(target) }
            }
            if rename(source.path, target.path) == 0 {
                outcome.relocatedLogs += 1
            } else {
                outcome.failures.append("relocate log \(name): \(String(cString: strerror(errno)))")
            }
        }
    }

    // MARK: - 不进 Time Machine

    /// 数据目录里的备份不让 Time Machine 再备份一遍:`backups/`(改写前原件、歌曲实体留底、合并时换下来的)和顶层引擎迁移留的
    /// `*.bak`。它们是 APFS 克隆、本机不占空间,Time Machine 却当成完整文件各拷一份;真要找回,Time Machine 里本来就有
    /// 当时的原件。每次启动调,已经标过的不再写。
    @discardableResult
    public static func excludeBackupsFromTimeMachine(in dataDir: URL) -> Int {
        var targets: [URL] = []
        let backups = dataDir.appendingPathComponent("backups")
        if StorageLayout.isDirectory(backups) { targets.append(backups) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataDir.path)) ?? []
        targets += names.filter { $0.hasSuffix(".bak") }.map { dataDir.appendingPathComponent($0) }
            .filter { StorageLayout.isRegularFile($0) }
        var marked = 0
        for var url in targets {
            guard (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true else { continue }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            if FileIO.attempt("exclude from backup", url, { try url.setResourceValues(values) }) { marked += 1 }
        }
        return marked
    }

    // MARK: - 接连失败

    /// 启动时的搬迁接连没做完(有一步出错,或做到一半进程没了)的次数,记在缓存目录。接连 `maxAttempts` 次之后
    /// `attemptRetryInterval` 内不再试、也不停引擎,App 照常用 `StorageLayout.activeDataDir` 选出的目录:搬迁碰上没想到的情况时
    /// 不至于每次启动都卡在同一处。
    struct Attempts: Codable, Equatable {
        var count: Int
        var last: Date
    }

    static let attemptsName = "storage-migration-attempts.json"
    static let maxAttempts = 3
    static let attemptRetryInterval: TimeInterval = 24 * 3600

    public static func shouldSkipAttempt(caches: URL, now: Date = Date()) -> Bool {
        guard let attempts = FileIO.decodeJSON(Attempts.self, from: caches.appendingPathComponent(attemptsName)) else { return false }
        return attempts.count >= maxAttempts && now.timeIntervalSince(attempts.last) < attemptRetryInterval
    }

    /// 动手之前记一次;做完 `recordAttemptEnd`。中途进程没了,这一次就留在记录里。
    public static func recordAttemptStart(caches: URL, now: Date = Date()) {
        let url = caches.appendingPathComponent(attemptsName)
        let count = (FileIO.decodeJSON(Attempts.self, from: url)?.count ?? 0) + 1
        guard let data = try? JSONEncoder().encode(Attempts(count: count, last: now)) else { return }
        _ = FileIO.write(data, to: url)
    }

    /// 做完了(没有出错的步骤)清掉记录;出错的留着,算一次没做完。
    public static func recordAttemptEnd(caches: URL, succeeded: Bool) {
        let url = caches.appendingPathComponent(attemptsName)
        guard succeeded, StorageLayout.exists(url) else { return }
        _ = FileIO.remove(url)
    }

    // MARK: - 标记文件

    static func readMarker(in dir: URL) -> Marker? {
        FileIO.decodeJSON(Marker.self, from: dir.appendingPathComponent(markerName))
    }

    static func writeMarker(_ marker: Marker, in dir: URL, _ outcome: inout Outcome) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(marker),
              FileIO.write(data, to: dir.appendingPathComponent(markerName)) else {
            outcome.failures.append("write \(markerName)")
            return
        }
    }
}
