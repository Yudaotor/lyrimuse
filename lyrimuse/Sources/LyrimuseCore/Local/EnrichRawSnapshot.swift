import Foundation

/// 「歌词管理」内存里的整份快照(`EnrichCacheStore`):每条存一份 JSON 字节,读哪条现解哪条(一条约 2 KB)。本机一万条去掉主歌词后,
/// 留成字典对象占 61 MB,存字节占 27 MB。下标读写跟 `[String: [String: Any]]` 一样;
/// 别加遍历全部条目的接口 —— 那要把一万条都解一遍。有选定指纹(`manual_pick_sha`)的几条单独记着,锁定开关只看它们。
/// 见 11 章决策 95。
public struct EnrichRawSnapshot: Sendable {
    private var data: [String: Data] = [:]
    public private(set) var pickedKeys: Set<String> = []

    public init() {}

    public init(_ entries: [String: [String: Any]]) {
        data.reserveCapacity(entries.count)
        for (key, entry) in entries {
            self[key] = entry
        }
    }

    public var count: Int { data.count }
    public var keys: Dictionary<String, Data>.Keys { data.keys }
    public func contains(_ key: String) -> Bool { data[key] != nil }

    public subscript(key: String) -> [String: Any]? {
        get {
            data[key].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        set {
            guard let newValue, let bytes = try? JSONSerialization.data(withJSONObject: newValue) else {
                data[key] = nil
                pickedKeys.remove(key)
                return
            }
            // 按实际长度复制一份再存:JSONSerialization 给的 Data 带着扩容余量,直接存要多占近一倍。
            data[key] = bytes.withUnsafeBytes { Data($0) }
            if let sha = newValue["manual_pick_sha"] as? String, !sha.isEmpty {
                pickedKeys.insert(key)
            } else {
                pickedKeys.remove(key)
            }
        }
    }

    /// 有选定指纹的那几条。
    public var pickedEntries: [[String: Any]] { pickedKeys.compactMap { self[$0] } }
}
