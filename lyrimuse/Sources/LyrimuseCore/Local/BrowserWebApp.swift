import AppKit
import Foundation

/// Chromium 系浏览器(Chrome / Edge / Brave 等)「安装为 App」的网页应用。
///
/// 系统「正在播放」报的是网页应用壳自己的 bundle id:`<浏览器 bundle id>.app.<应用 id>`,应用 id 是 32 位 a–p;
/// 非默认个人资料的壳在应用 id 前多一段个人资料目录名加连字符(`com.google.Chrome.app.Profile-1-<应用 id>`)。
/// 壳只是个启动器,窗口和页面都在宿主浏览器里:页面脚本要发给宿主,宿主的脚本接口能列出网页应用那扇窗。
/// 壳的 Info.plist 用 `CrBundleIdentifier` 写明宿主。
///
/// 只有 `platformByAppID` 里登记的应用(scripts/gen-players.py 从 shared/players.json 生成,Go 侧 browserWebAppPlatforms
/// 同源)默认就认:按「宿主浏览器里配对了这个平台的网页版」对待,不用手动信任,也不看宿主浏览器的配对。
/// 没登记的网页应用照旧当作一个普通的未知 App。见 02 章决策 284。
public enum BrowserWebApp {
    /// 按规则拆出来的两段。`hostBundleID` 是 bundle id 的前半段,没跟壳的 Info.plist 核对过。
    public struct Shortcut: Equatable, Sendable {
        public let hostBundleID: String
        public let appID: String
        public init(hostBundleID: String, appID: String) {
            self.hostBundleID = hostBundleID
            self.appID = appID
        }
    }

    static let appIDLength = 32

    /// 按 `<浏览器 bundle id>.app.<可选的「个人资料-」><32 位 a–p>` 拆;不是这个形状返回 nil。纯函数,selftest 覆盖。
    public static func parse(_ bundleID: String?) -> Shortcut? {
        guard let bundleID, let marker = bundleID.range(of: ".app.", options: .backwards) else { return nil }
        let host = bundleID[..<marker.lowerBound]
        let tail = bundleID[marker.upperBound...]
        guard isBundleIDLike(host), tail.count >= appIDLength else { return nil }
        let appID = tail.suffix(appIDLength)
        guard appID.allSatisfy({ ("a"..."p").contains($0) }) else { return nil }
        let profile = tail.dropLast(appIDLength)
        if !profile.isEmpty {
            guard profile.last == "-",
                  profile.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return nil }
        }
        return Shortcut(hostBundleID: String(host), appID: String(appID))
    }

    private static func isBundleIDLike(_ s: Substring) -> Bool {
        guard let first = s.first, let last = s.last, first != ".", last != "." else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// 这个 bundle id 是登记过的网页应用 → 它的网页平台 id(`BrowserPositionProbe.supportedPlatforms` 的 id),否则 nil。
    /// 纯函数,不读盘。
    public static func platformID(of bundleID: String?) -> String? {
        parse(bundleID).flatMap { platformByAppID[$0.appID] }
    }

    /// 登记过的网页应用 → 页面脚本要发给的宿主浏览器。壳的 Info.plist 写了 `CrBundleIdentifier` 就以它为准,读不到用 bundle id
    /// 的前半段。别的 bundle id 返回 nil。壳的位置要问 LaunchServices,结果按 bundle id 缓存。
    public static func host(of bundleID: String?) -> String? {
        guard let bundleID, let shortcut = parse(bundleID), platformByAppID[shortcut.appID] != nil else { return nil }
        return resolvedHost(shortcut, declaredHost: declaredHost(ofShortcut: bundleID))
    }

    /// 上面那条的判据本体:壳声明的宿主非空就用它,否则用 bundle id 的前半段。纯函数,selftest 覆盖。
    public static func resolvedHost(_ shortcut: Shortcut, declaredHost: String?) -> String {
        let declared = (declaredHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return declared.isEmpty ? shortcut.hostBundleID : declared
    }

    // MARK: - 壳的 Info.plist

    static let declaredHostKey = "CrBundleIdentifier"
    /// 找不到壳(LaunchServices 还没登记它)时隔多久再问一次。
    static let missingShortcutRetry: TimeInterval = 60

    private static let cacheLock = NSLock()
    private static var declaredHostCache: [String: (host: String?, at: Date)] = [:]

    private static func declaredHost(ofShortcut bundleID: String, now: Date = Date()) -> String? {
        cacheLock.lock()
        if let hit = declaredHostCache[bundleID],
           hit.host != nil || now.timeIntervalSince(hit.at) < missingShortcutRetry {
            cacheLock.unlock()
            return hit.host
        }
        cacheLock.unlock()
        let host = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { infoPlist(ofAppAt: $0) }
            .flatMap { $0[declaredHostKey] as? String }
        cacheLock.lock()
        declaredHostCache[bundleID] = (host, now)
        cacheLock.unlock()
        return host
    }

    private static func infoPlist(ofAppAt appURL: URL) -> [String: Any]? {
        let url = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = FileIO.read(url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    // MARK: - 装了哪些

    /// 一个装在本机的网页应用壳。
    public struct Installed: Equatable, Sendable {
        public let bundleID: String
        public let hostBundleID: String
        public let platformID: String
    }

    /// Chromium 把网页应用的壳放在 `~/Applications/<浏览器名> Apps.localized/` 里。
    public static var defaultShortcutsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    /// 扫 `root` 下各个 `*.localized` 目录里的 `.app`,认出登记过的网页应用。只读每个壳的 Info.plist,不问 LaunchServices。
    /// 设置页「网页版」卡用它给只用网页应用、没配对过浏览器的人摆出宿主浏览器的权限状态。会读盘,别在主线程调。
    public static func installed(in root: URL = defaultShortcutsRoot) -> [Installed] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [Installed] = []
        for folder in folders where folder.pathExtension == "localized" {
            guard let apps = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for app in apps where app.pathExtension == "app" {
                guard let info = infoPlist(ofAppAt: app),
                      let bundleID = info["CFBundleIdentifier"] as? String,
                      let shortcut = parse(bundleID),
                      let platformID = platformByAppID[shortcut.appID]
                else { continue }
                out.append(Installed(bundleID: bundleID,
                                     hostBundleID: resolvedHost(shortcut, declaredHost: info[declaredHostKey] as? String),
                                     platformID: platformID))
            }
        }
        return out.sorted { $0.bundleID < $1.bundleID }
    }

    /// 按平台归拢宿主:平台 id → 宿主浏览器 bundle id 集合。纯函数,selftest 覆盖。
    public static func hostsByPlatform(_ apps: [Installed]) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for app in apps { out[app.platformID, default: []].insert(app.hostBundleID) }
        return out
    }
}
