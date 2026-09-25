import Foundation

/// App 与 collector 共享的限流窗口,collector 侧 `sharedcooldown.go` 的镜像。
///
/// 两个进程共用一个出口 IP,都会打 iTunes 和 Last.fm 的读接口。一边撞到限流,另一边接着打只会
/// 被一起限,所以这几个接口的停手窗口写进一个共享文件,两边发请求前都看一眼。文件名、键的写法
/// (主机 + 路径,同 collector 出站闸的端点键)、JSON 形状三处必须两边一起改,selftest contracts
/// 组守着。
///
/// 文件形状:`{"endpoints":{"itunes.apple.com/search":1790253000.5}}`,值是窗口截止的 Unix 秒。
/// 写入是读 - 合并 - 原子替换,两个进程同时写可能丢掉对方刚写的一条,丢了只是那一边少停一个窗口。
public enum OutboundCooldowns {
    public static let fileName = "lyrimuse-outbound-cooldowns.json"
    public static let itunesSearchKey = "itunes.apple.com/search"
    public static let lastfmKey = "ws.audioscrobbler.com/2.0/"

    private struct File: Codable {
        var endpoints: [String: Double]
    }

    /// 去掉过期的,key 取两者较晚的截止时刻。同 collector `mergeSharedCooldown`。
    public static func merge(_ existing: [String: Double], key: String, until: Date, now: Date) -> [String: Double] {
        let nowSecs = now.timeIntervalSince1970
        var out = existing.filter { $0.value > nowSecs }
        let u = until.timeIntervalSince1970
        if u > (out[key] ?? 0) { out[key] = u }
        return out
    }

    /// 这个端点的窗口截止时刻;没有或已过期返回 nil。
    public static func until(_ endpoints: [String: Double], key: String, now: Date) -> Date? {
        guard let secs = endpoints[key] else { return nil }
        let until = Date(timeIntervalSince1970: secs)
        return until > now ? until : nil
    }

    public static func decode(_ data: Data) -> [String: Double] {
        (try? JSONDecoder().decode(File.self, from: data))?.endpoints ?? [:]
    }

    public static func encode(_ endpoints: [String: Double]) -> Data? {
        try? JSONEncoder().encode(File(endpoints: endpoints))
    }
}

/// 共享文件的读写。读有 1 秒缓存(按 mtime 判断要不要重读),每个请求都问一次也不会每次 stat。
public final class OutboundCooldownStore: @unchecked Sendable {
    public static let shared = OutboundCooldownStore(url: LyrimusePaths.configFile(OutboundCooldowns.fileName))

    private let url: URL
    private let lock = NSLock()
    private var cache: [String: Double] = [:]
    private var readAt: Date = .distantPast
    private var mtime: Date?

    public init(url: URL) {
        self.url = url
    }

    public func activeUntil(_ key: String, now: Date = Date()) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if now.timeIntervalSince(readAt) >= 1 {
            readAt = now
            let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if m == nil {
                cache = [:]
                mtime = nil
            } else if m != mtime {
                mtime = m
                cache = (try? Data(contentsOf: url)).map(OutboundCooldowns.decode) ?? [:]
            }
        }
        return OutboundCooldowns.until(cache, key: key, now: now)
    }

    public func publish(_ key: String, until: Date, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let existing = (try? Data(contentsOf: url)).map(OutboundCooldowns.decode) ?? [:]
        let merged = OutboundCooldowns.merge(existing, key: key, until: until, now: now)
        guard let data = OutboundCooldowns.encode(merged) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        cache = merged
        readAt = now
        mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
