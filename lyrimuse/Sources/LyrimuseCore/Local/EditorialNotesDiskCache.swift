import Foundation

/// 简介各来源的结论落盘:`lyrimuse-editorial-cache.json`,App 写、App 读,纯缓存(删了只是重新联网问)。
///
/// 每条记一个键(调用方拼:界面语言 + 来源 + 那一家的 id)、结论和取到的时刻。结论是值的 JSON;`nil` = 那一家明确没有。
/// 有正文的 `foundTTL` 后再问,明确没有的 `missingTTL` 后再问;没问成(网络、限流、形状不对)调用方不记。过期的读不出来,
/// 读文件、存盘时顺手丢掉;条目超过 `maxEntries` 时丢最早取到的。见 18 章决策 54。
public final class EditorialNotesDiskCache {
    public static let foundTTL: TimeInterval = 30 * 86_400
    public static let missingTTL: TimeInterval = 7 * 86_400
    public static let maxEntries = 20_000
    static let version = 1

    public static var defaultURL: URL { LyrimusePaths.configFile("lyrimuse-editorial-cache.json") }

    struct Entry: Codable, Equatable, Sendable {
        /// 值的 JSON;nil = 明确没有。
        var v: String?
        /// 取到的时刻(Unix 秒)。
        var at: Double
        /// 按「明确没有」算期限(值本身在,但里面要的那段正文没有)。
        var m: Bool?

        var missing: Bool { v == nil || m == true }

        func expired(_ now: Date) -> Bool {
            now.timeIntervalSince1970 - at >= (missing ? EditorialNotesDiskCache.missingTTL : EditorialNotesDiskCache.foundTTL)
        }
    }

    struct File: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    /// 从盘上读到的内容(可以在后台读完再交给用它的那个线程)。
    public struct Contents: Sendable {
        let entries: [String: Entry]
        public static let empty = Contents(entries: [:])
    }

    private var entries: [String: Entry]
    public private(set) var dirty = false

    public var count: Int { entries.count }

    /// 读不到、解不开、版本对不上都当空的(只是重新联网问);过期的不要。
    public static func read(_ url: URL, now: Date = Date()) -> Contents {
        guard let file = FileIO.decodeJSON(File.self, from: url), file.version == version else { return .empty }
        return Contents(entries: file.entries.filter { !$0.value.expired(now) })
    }

    public init(_ contents: Contents = .empty) { entries = contents.entries }

    /// 后读到的盘上内容并进来:这边已经记着的(读盘期间刚取到的)留着。
    public func merge(_ contents: Contents) {
        for (k, e) in contents.entries where entries[k] == nil {
            entries[k] = e
        }
    }

    /// `.none` = 没记过或已过期;`.some(nil)` = 明确没有;`.some(v)` = 记着的值。值解不开当没记过。
    public func lookup<V: Decodable>(_ key: String, as _: V.Type, now: Date = Date()) -> V?? {
        guard let e = entries[key], !e.expired(now) else { return .none }
        guard let json = e.v else { return .some(nil) }
        guard let data = json.data(using: .utf8), let value = try? JSONDecoder().decode(V.self, from: data) else { return .none }
        return .some(value)
    }

    /// 记一条结论:`value` 为 nil = 明确没有;`missing` 为 true 时值照存、期限按明确没有算。值编不出来时不记。
    public func store<V: Encodable>(_ key: String, _ value: V?, missing: Bool = false, now: Date = Date()) {
        var json: String?
        if let value {
            guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
            json = text
        }
        entries[key] = Entry(v: json, at: now.timeIntervalSince1970, m: missing && json != nil ? true : nil)
        dirty = true
    }

    /// 要写盘的那一份:在用它的线程上取(`takeSnapshot`),整份 JSON 编码(`encoded()`,上限 2 万条)放到写盘的队列上做。
    public struct Snapshot: Sendable {
        let entries: [String: Entry]

        public func encoded() -> Data? {
            try? JSONEncoder().encode(File(version: EditorialNotesDiskCache.version, entries: entries))
        }
    }

    /// 要写盘的内容:去掉过期的,超过上限时丢最早取到的。没改过返回 nil。
    public func takeSnapshot(now: Date = Date()) -> Snapshot? {
        guard dirty else { return nil }
        var kept = entries.filter { !$0.value.expired(now) }
        if kept.count > Self.maxEntries {
            let drop = kept.sorted { $0.value.at < $1.value.at }.prefix(kept.count - Self.maxEntries).map(\.key)
            drop.forEach { kept.removeValue(forKey: $0) }
        }
        entries = kept
        dirty = false
        return Snapshot(entries: kept)
    }

    /// `takeSnapshot` 之后马上编码(测试和不在意主线程的调用方用)。
    public func snapshotForSave(now: Date = Date()) -> Data? { takeSnapshot(now: now)?.encoded() }

    /// 写盘没成:下一次存盘照样整份写(取快照时已经清了脏标记)。
    public func markDirty() { dirty = true }

    /// 原子写盘(先写临时文件再换名),目录不在就建。失败由 `FileIO` 记一次、返回 false。
    @discardableResult
    public static func write(_ data: Data, to url: URL) -> Bool {
        FileIO.createDirectory(url.deletingLastPathComponent()) && FileIO.write(data, to: url)
    }
}
