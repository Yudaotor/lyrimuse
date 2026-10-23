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
        /// 合并时两边都有、内容不同的条目数:以数据目录为准,旧的那份留在 `keptLeftover` 里。
        public var conflicts = 0
        /// 合并完旧目录还剩东西时,改名到的位置。
        public var keptLeftover: String?
        public var rewrittenFiles = 0
        public var relocatedCaches = 0
        public var failures: [String] = []

        public init() {}

        public var changedAnything: Bool {
            movedRoot || copiedRoot || mergedItems > 0 || keptLeftover != nil || rewrittenFiles > 0 || relocatedCaches > 0
        }
    }

    /// 搬迁标记:记着从哪搬到哪、文件里的旧路径改写完没有。动手之前就写好(整份改名时写进旧目录、跟着一起走;合并时写进
    /// 数据目录),中途崩溃下次启动照样接着改写。它也是「这个数据目录搬过」的凭据(`StorageLayout.activeDataDir`)。
    static let markerName = "lyrimuse-storage-migration.json"

    struct Marker: Codable, Equatable {
        var from: String
        var to: String
        var rewritePending: Bool
    }

    /// 有没有要做的。启动路径上每次都调:几十次 lstat 加一次小文件读。
    public static func isPending(_ roots: StorageLayout.Roots, cacheNames: [String] = StorageLayout.cacheFileNames) -> Bool {
        if StorageLayout.hasLegacyToAbsorb(roots) { return true }
        let data = StorageLayout.activeDataDir(roots)
        if readMarker(in: data)?.rewritePending == true { return true }
        return cacheNames.contains { StorageLayout.exists(data.appendingPathComponent($0)) }
    }

    /// `forceCopy` 只给 selftest 走跨卷那条路用。
    public static func run(
        _ roots: StorageLayout.Roots, cacheNames: [String] = StorageLayout.cacheFileNames, forceCopy: Bool = false
    ) -> Outcome {
        var outcome = Outcome()
        if StorageLayout.hasLegacyToAbsorb(roots) {
            absorbLegacy(roots, forceCopy: forceCopy, &outcome)
        }
        let data = StorageLayout.activeDataDir(roots)
        if var pending = readMarker(in: data), pending.rewritePending {
            if rewritePaths(in: data, from: pending.from, to: pending.to, &outcome) {
                pending.rewritePending = false
            }
            writeMarker(pending, in: data, &outcome)
        }
        relocateCaches(from: data, to: roots.caches, names: cacheNames, &outcome)
        return outcome
    }

    // MARK: - 旧目录

    /// 数据目录里还没有 Lyrimuse 的数据(不存在、空的、或只有别的东西):空的先删掉,整份改名过去;同卷一次 `rename(2)`,
    /// 跨卷(`~/.config` 被链到别的盘)先拷进旁边的暂存目录、核对文件清单和大小再换上去,旧目录改名留着。数据目录已经有数据
    /// (搬过之后旧目录又冒出来,或新目录里先被放了东西)时逐项合并(`mergeTree`)。失败的那一步不动旧目录,下次启动重试。
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
                return
            }
        }
        writeMarker(pending, in: roots.data, &outcome)
        mergeTree(from: roots.legacy, into: roots.data, &outcome)
        pruneEmptyDirectories(roots.legacy)
        guard StorageLayout.exists(roots.legacy) else { return }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let kept = roots.legacy.deletingLastPathComponent()
            .appendingPathComponent(roots.legacy.lastPathComponent + ".leftover-" + stamp.string(from: Date()))
        if rename(roots.legacy.path, kept.path) == 0 {
            outcome.keptLeftover = kept.path
        } else {
            outcome.failures.append("rename leftover: \(String(cString: strerror(errno)))")
        }
    }

    /// 把 `source` 里数据目录没有的条目挪过去(整个子目录不在就整个挪);两边都有的子目录往里递归;两边都有的文件内容一样就删掉旧的,
    /// 不一样就以数据目录为准、旧的原地留着。`.DS_Store` 和锁文件不算内容,冲突时直接删旧的。
    static func mergeTree(from source: URL, into target: URL, _ outcome: inout Outcome) {
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
                mergeTree(from: from, into: to, &outcome)
            } else if name == ".DS_Store" || name.hasSuffix(".lock") || sameContents(from, to) {
                _ = FileIO.remove(from)
            } else {
                outcome.conflicts += 1
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
    /// (本机 7 万个文件里 6.8 万个),一份份读要一分多钟。
    static let skippedDirectories: Set<String> = ["lyrics", "lyrimuse-lyrics-bodies", "lyrimuse-decisions", "artwork", "fonts"]

    /// 不看的扩展名:图片、视频、字体、歌词文本、崩溃报告、锁文件,里面不会存数据目录的路径;另有引擎一次性迁移留的
    /// `.bak`(几百 MB,30 天后引擎自己删,没有代码读它)。
    static let skippedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "webp", "gif", "mp4", "mov", "ttf", "otf", "ttc", "woff", "woff2",
        "lrc", "yrc", "ips", "lock", "bak",
    ]

    /// 设备封面的 `file://` 地址、自定义歌词目录这类存成绝对路径的值,在 enrich 缓存、歌曲实体、留底和备份里都有。
    /// 只换「旧目录 + `/`」和「旧目录 + `"`」两种写法(外加 JSON 把 `/` 转义成 `\/` 的写法),
    /// 别的以旧目录名开头的兄弟目录(如 `~/.config/lyrimuse-backups`)不碰。每份文件改完原子换上去、保留权限。
    static func rewritePaths(in dir: URL, from old: String, to new: String, _ outcome: inout Outcome) -> Bool {
        let pairs = replacementPairs(from: old, to: new)
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
            if replaceFile(url, with: rewritten) {
                outcome.rewrittenFiles += 1
            } else {
                outcome.failures.append("write \(url.lastPathComponent)")
                ok = false
            }
        }
        return ok
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
