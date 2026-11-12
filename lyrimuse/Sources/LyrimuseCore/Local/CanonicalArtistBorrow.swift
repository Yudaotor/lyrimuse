import Foundation

/// 歌词管理列表里没有 `canonical_artist` 的条目,借同一张专辑、同一个原始歌手写法下别的条目认出来的那个名字:同一张专辑里
/// 有的曲目外围补全补完了、有的还没补(或没补上),不借的话这张专辑按官方名和原始写法拆成两组。
/// 只在同一张专辑里借:单条认出来的名字对短写法不可靠(同叫一个英文名的不是同一个人),跨专辑借会把别人也改名。
/// 同一张专辑、同一写法认出了不止一个名字时谁都不借。见 11 章决策 119。
public enum CanonicalArtistBorrow {
    /// (原始写法, 专辑) 的归一键 → 唯一的 canonical(保留首见的原写法)。
    /// - Parameters:
    ///   - entries: 每条记录的(原始歌手写法, 专辑, canonical_artist);任一为空的跳过。
    ///   - key: 归一化函数,写法、专辑、canonical 都过它比较(折繁简、大小写)。
    public static func table(_ entries: [(artist: String, album: String, canonical: String)],
                             key: (String) -> String) -> [String: String] {
        table(entries.compactMap {
            input(slot: slotKey(artist: $0.artist, album: $0.album, key: key), canonical: $0.canonical, key: key)
        })
    }

    /// 一条有自己 canonical 的记录在借名表里那一份:槽位、原写法(去掉首尾空格)、归一后的写法。预先算好存着,
    /// 增量补读时重算借名表不用再逐条归一化。
    public struct Input: Equatable, Sendable {
        public let slot: String
        public let name: String
        public let norm: String

        public init(slot: String, name: String, norm: String) {
            self.slot = slot
            self.name = name
            self.norm = norm
        }
    }

    /// canonical 去掉首尾空格后为空、或者没有槽位时为 nil。
    public static func input(slot: String?, canonical: String, key: (String) -> String) -> Input? {
        let name = canonical.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let slot else { return nil }
        return Input(slot: slot, name: name, norm: key(name))
    }

    /// 同 `table(_:key:)`,输入已经算好槽位和归一写法。
    public static func table<S: Sequence>(_ inputs: S) -> [String: String] where S.Element == Input {
        var picked: [String: (name: String, norm: String)] = [:]
        var ambiguous: Set<String> = []
        for input in inputs where !ambiguous.contains(input.slot) {
            if let seen = picked[input.slot] {
                if seen.norm != input.norm {
                    picked[input.slot] = nil
                    ambiguous.insert(input.slot)
                }
            } else {
                picked[input.slot] = (input.name, input.norm)
            }
        }
        return picked.mapValues(\.name)
    }

    /// 这条记录列表里用的 canonical:自己有就用自己的,没有时按(写法, 专辑)查 `table`。
    public static func resolve(artist: String, album: String, own: String, table: [String: String],
                               key: (String) -> String) -> String {
        if !own.isEmpty { return own }
        guard let slot = slotKey(artist: artist, album: album, key: key) else { return "" }
        return table[slot] ?? ""
    }

    /// (写法, 专辑) 在 `table` 里的键;任一为空是 nil(这条不借也不被借)。
    public static func slotKey(artist: String, album: String, key: (String) -> String) -> String? {
        let artist = artist.trimmingCharacters(in: .whitespaces)
        let album = album.trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty, !album.isEmpty else { return nil }
        return key(artist) + "\u{1F}" + key(album)
    }
}
