import Darwin
import Foundation

/// App 是不是从「不该长期跑的地方」启动的:磁盘映像里(推出映像后没换入的代码页读不到,进程以 SIGBUS 崩溃;映像只读,
/// 也收不到更新),或者系统的 App Translocation 临时位置(带隔离标记的 App 没被拖进「应用程序」就打开时,系统把它挂到
/// 一个随机的只读路径上跑,同样收不到更新)。判定、提示与否、搬运时用的两段 shell 都是纯函数,selftest 覆盖;
/// 弹窗与真的搬运在 App 的 `AppLocationPrompt`。见 15 章决策 110。
public enum AppLocation {
    public enum Kind: Equatable, Sendable {
        case normal
        /// 在这个挂载点的磁盘映像里。
        case diskImage(mountPoint: String)
        case translocated
    }

    /// App 所在卷要不要盯着卸载(`AppVolumeUnmountWatcher`):根卷不会被卸载,不盯。
    public static func watchesVolume(at path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path != "/"
    }

    /// 卸载通知里的卷是不是 App 所在的那个卷(按挂载点路径比,末尾斜杠、`.` 不算差别)。
    public static func isSameVolume(_ unmounting: URL?, _ volume: URL) -> Bool {
        guard let unmounting else { return false }
        return unmounting.standardizedFileURL.path == volume.standardizedFileURL.path
    }

    /// `volumePath`:App 所在卷的挂载点;`diskImageMountPoints`:`hdiutil info -plist` 列出的磁盘映像挂载点。
    /// 只读卷不一定是磁盘映像(只读的网络卷、恢复盘),两样都对上才算。
    public static func classify(bundlePath: String, volumeIsReadOnly: Bool, volumePath: String?,
                                diskImageMountPoints: [String]) -> Kind {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        guard volumeIsReadOnly, let volume = volumePath.map(trimmedSlash),
              diskImageMountPoints.map(trimmedSlash).contains(volume) else { return .normal }
        return .diskImage(mountPoint: volume)
    }

    /// 要不要弹:位置不对,而且用户没对这一版说过「不了」。
    public static func shouldPrompt(_ kind: Kind, declinedVersion: String?, currentVersion: String) -> Bool {
        kind != .normal && declinedVersion != currentVersion
    }

    /// `hdiutil info -plist` 里各个映像的挂载点(`images[].system-entities[].mount-point`)。
    public static func diskImageMountPoints(hdiutilInfoPlist data: Data) -> [String] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        return images.flatMap { image in
            ((image["system-entities"] as? [[String: Any]]) ?? []).compactMap { $0["mount-point"] as? String }
        }
    }

    /// 单引号包起来给 /bin/sh:里面的单引号写成 `'\''`。
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字符串字面量(`do shell script` 用):反斜杠、双引号转义。
    public static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 搬好之后重开:等这个进程退出,推出原来的磁盘映像(有的话;推不掉就算了),再执行 `launch`(平时是 `open` 新位置)。
    /// 由一个脱离出去的 `/bin/sh` 跑,本进程随后退出。
    public static func relaunchScript(waitingFor pid: Int32, detachMountPoint: String?, launch: String) -> String {
        var lines = ["while /bin/kill -0 \(pid) >/dev/null 2>&1; do /bin/sleep 0.2; done"]
        if let detachMountPoint { lines.append("/usr/bin/hdiutil detach \(shellQuote(detachMountPoint)) -quiet >/dev/null 2>&1") }
        lines.append(launch)
        return lines.joined(separator: "\n")
    }

    /// 要管理员权限时交给 `do shell script … with administrator privileges` 的那段:先拷到目标旁边的临时名字,
    /// 拷好了才把旧版挪进废纸篓、换上新的;哪一步失败就删掉临时那份、把旧版挪回来,不留半截。
    public static func privilegedMoveScript(source: String, destination: String, temporary: String, trashTarget: String) -> String {
        let s = shellQuote(source), d = shellQuote(destination), t = shellQuote(temporary), tr = shellQuote(trashTarget)
        return [
            "/usr/bin/ditto \(s) \(t) || { /bin/rm -rf \(t); exit 1; }",
            "if [ -e \(d) ]; then /bin/mv \(d) \(tr) || { /bin/rm -rf \(t); exit 1; }; fi",
            "/bin/mv \(t) \(d) || { /bin/rm -rf \(t); if [ -e \(tr) ]; then /bin/mv \(tr) \(d); fi; exit 1; }",
            "/usr/bin/xattr -dr com.apple.quarantine \(d) >/dev/null 2>&1",
            "exit 0",
        ].joined(separator: "\n")
    }

    /// 目标旁边的临时名字(同一个卷上,换进去是一次改名)。
    public static func temporaryName(for bundleName: String) -> String { ".\(bundleName).moving-\(UUID().uuidString)" }

    private static func trimmedSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// 把 App 包搬到一个目录里(不要管理员权限的那条路):先拷成目标旁边的临时名字,拷好了才把同名旧版挪进废纸篓
/// (`trash`)、再改名换上;哪一步失败都删掉临时那份,旧版挪走了就挪回来。换上之后去掉隔离标记:带着它从新位置打开,
/// 系统会再挂一次 App Translocation。
public struct AppBundleMover {
    public struct Result: Equatable, Sendable {
        public let destination: URL
        /// 被换下来的旧版去了哪(废纸篓里的路径);原来没有旧版是 nil。
        public let replaced: URL?
    }

    private let trash: (URL) throws -> URL

    /// `trash` 把一份旧版挪走、返回挪到了哪;默认进当前用户的废纸篓。
    public init(trash: @escaping (URL) throws -> URL = AppBundleMover.moveToTrash) {
        self.trash = trash
    }

    public static func moveToTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    /// 这个目录能不能直接写(不能就要走管理员授权)。
    public static func needsPrivileges(directory: URL, bundleName: String) -> Bool {
        let fm = FileManager.default
        let existing = directory.appendingPathComponent(bundleName).path
        return !fm.isWritableFile(atPath: directory.path) || (fm.fileExists(atPath: existing) && !fm.isDeletableFile(atPath: existing))
    }

    public func move(_ source: URL, into directory: URL) throws -> Result {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        let temporary = directory.appendingPathComponent(AppLocation.temporaryName(for: source.lastPathComponent))
        do {
            try fm.copyItem(at: source, to: temporary)
        } catch {
            FileIO.remove(temporary)
            throw error
        }
        var replaced: URL?
        if fm.fileExists(atPath: destination.path) {
            do {
                replaced = try trash(destination)
            } catch {
                FileIO.remove(temporary)
                throw error
            }
        }
        do {
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            FileIO.remove(temporary)
            if let replaced { FileIO.move(replaced, to: destination) }
            throw error
        }
        Self.removeQuarantine(destination)
        return Result(destination: destination, replaced: replaced)
    }

    /// 包里每个文件(含包本身)去掉 `com.apple.quarantine`;没有这个属性的跳过。
    public static func removeQuarantine(_ root: URL) {
        var paths = [root.path]
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            while let relative = walker.nextObject() as? String { paths.append(root.appendingPathComponent(relative).path) }
        }
        for path in paths { removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }
}
