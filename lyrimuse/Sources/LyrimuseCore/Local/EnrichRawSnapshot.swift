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
            guard let newValue, let bytes = SafeSerialization.jsonData(newValue) else {
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

    /// 存一条现成的 JSON 字节(缓存文件里切出来的那段,`EnrichIndexDiff.split`),不解了再编:三万条重编一遍要一秒多 CPU。
    /// `entry` 是同一段字节解出来的字典,只用来判选定指纹;调用方保证两者一致。
    public mutating func setEncoded(_ bytes: Data, forKey key: String, entry: [String: Any]) {
        data[key] = bytes
        if let sha = entry["manual_pick_sha"] as? String, !sha.isEmpty {
            pickedKeys.insert(key)
        } else {
            pickedKeys.remove(key)
        }
    }

    /// 读盘拼快照:条目已经解成字典(`entries`),缓存文件里切出来的原文在 `encoded`。`dropMainLyrics` 不改、也没被叠加条目
    /// 换掉(不在 `reencode` 里)的直接存原文,其余拿掉主歌词再编。结果跟 `EnrichRawSnapshot(dropMainLyrics 之后的 entries)` 逐条读出来一样。
    public static func assemble(entries: [String: [String: Any]], encoded: [String: Data],
                                reencode: Set<String>) -> EnrichRawSnapshot {
        var out = EnrichRawSnapshot()
        out.data.reserveCapacity(entries.count)
        for (key, entry) in entries {
            if !reencode.contains(key), let bytes = encoded[key], !EnrichCacheSlim.mainLyricsDroppable(entry) {
                out.setEncoded(bytes, forKey: key, entry: entry)
            } else {
                out[key] = EnrichCacheSlim.droppingMainLyrics(entry)
            }
        }
        return out
    }

    /// 有选定指纹的那几条。
    public var pickedEntries: [[String: Any]] { pickedKeys.compactMap { self[$0] } }
}
