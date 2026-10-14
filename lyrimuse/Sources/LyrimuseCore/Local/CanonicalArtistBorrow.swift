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
        var picked: [String: (name: String, norm: String)] = [:]
        var ambiguous: Set<String> = []
        for entry in entries {
            let canonical = entry.canonical.trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty, let slot = slotKey(artist: entry.artist, album: entry.album, key: key),
                  !ambiguous.contains(slot) else { continue }
            let norm = key(canonical)
            if let seen = picked[slot] {
                if seen.norm != norm {
                    picked[slot] = nil
                    ambiguous.insert(slot)
                }
            } else {
                picked[slot] = (canonical, norm)
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

    private static func slotKey(artist: String, album: String, key: (String) -> String) -> String? {
        let artist = artist.trimmingCharacters(in: .whitespaces)
        let album = album.trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty, !album.isEmpty else { return nil }
        return key(artist) + "\u{1F}" + key(album)
    }
}
