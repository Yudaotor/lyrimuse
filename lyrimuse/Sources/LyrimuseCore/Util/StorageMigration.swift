import Darwin
import Foundation

/// 把旧布局搬成 `StorageLayout` 的新布局:旧目录整份搬到数据目录、改写文件里存着的旧绝对路径、把缓存文件挪进缓存目录。
/// App 启动最早处调(`StorageMigrationRunner`),调用方保证引擎这时没在跑。每一步都能重跑,没做完的下次启动接着做。见 14 章决策 136。
public enum StorageMigration {
    public struct Outcome: Equatable, Sendable {
        public var movedRoot = false
        public var copiedRoot = false
        public var rewrittenFiles = 0
        public var relocatedCaches = 0
        public var failures: [String] = []

        public init() {}

        public var changedAnything: Bool { movedRoot || copiedRoot || rewrittenFiles > 0 || relocatedCaches > 0 }
    }

    /// 搬完根目录后写在数据目录里:记着从哪搬到哪、文件里的旧路径改写完没有。改写没完成时下次启动接着改。
    static let markerName = "lyrimuse-storage-migration.json"

    struct Marker: Codable, Equatable {
        var from: String
        var to: String
        var rewritePending: Bool
    }

    /// 有没有要做的。启动路径上每次都调:几十次 lstat 加一次小文件读。
    public static func isPending(_ roots: StorageLayout.Roots, cacheNames: [String] = StorageLayout.cacheFileNames) -> Bool {
        if StorageLayout.needsRootMove(roots) { return true }
        let data = StorageLayout.activeDataDir(roots)
        if readMarker(in: data)?.rewritePending == true { return true }
        return cacheNames.contains { StorageLayout.exists(data.appendingPathComponent($0)) }
    }

    /// `forceCopy` 只给 selftest 走跨卷那条路用。
    public static func run(
        _ roots: StorageLayout.Roots, cacheNames: [String] = StorageLayout.cacheFileNames, forceCopy: Bool = false
    ) -> Outcome {
        var outcome = Outcome()
        var marker: Marker?
        if StorageLayout.needsRootMove(roots) {
            marker = moveRoot(roots, forceCopy: forceCopy, &outcome)
        }
        let data = StorageLayout.activeDataDir(roots)
        if marker == nil { marker = readMarker(in: data) }
        if var pending = marker, pending.rewritePending {
            if rewritePaths(in: data, from: pending.from, to: pending.to, &outcome) {
                pending.rewritePending = false
            }
            writeMarker(pending, in: data, &outcome)
        }
        relocateCaches(from: data, to: roots.caches, names: cacheNames, &outcome)
        return outcome
    }

    // MARK: - 根目录

    /// 同卷一次 `rename(2)`;跨卷(`~/.config` 被链到别的盘)时先整份拷进旁边的暂存目录、核对文件清单和大小,再换上去,
    /// 旧目录改名留着不删。任何一步失败都不动旧目录,返回 nil,下次启动重试。
    static func moveRoot(_ roots: StorageLayout.Roots, forceCopy: Bool, _ outcome: inout Outcome) -> Marker? {
        guard FileIO.createDirectory(roots.data.deletingLastPathComponent()) else {
            outcome.failures.append("create \(roots.data.deletingLastPathComponent().path)")
            return nil
        }
        if !forceCopy, rename(roots.legacy.path, roots.data.path) == 0 {
            outcome.movedRoot = true
        } else if forceCopy || errno == EXDEV {
            guard copyRoot(roots, &outcome) else { return nil }
            outcome.copiedRoot = true
        } else {
            outcome.failures.append("rename \(roots.legacy.path): \(String(cString: strerror(errno)))")
            return nil
        }
        let marker = Marker(from: roots.legacy.path, to: roots.data.path, rewritePending: true)
        writeMarker(marker, in: roots.data, &outcome)
        return marker
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
