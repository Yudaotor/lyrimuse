import Foundation

/// 全量重新扫库跳过的「再搜也不会有」的空歌词条目,collector 侧 `lyricsretryskip.go` 的镜像。
///
/// 界面「全量重新扫库」那一行的「N 首」要跟 collector 真会扫的条数逐条对得上(见 `LyricsFullScan.tier`),
/// 所以这两条判据两边必须同步改。手动「重试无歌词条目」不受它们影响,那个数不用它。
public enum LyricsRetrySkip {
    /// 没歌手没专辑的空条目,补空失败几次后自动路径不再碰。同 collector `lyricsNoAnchorGiveUpCount`。
    public static let noAnchorGiveUpCount = 3
    /// 同一个身份字段下另一个字段至少几个不同值才算污染。同 collector `lyricsPollutedMinVariants`。
    public static let pollutedMinVariants = 3

    /// 带空格的分隔符,同 collector `trustedTitleSeps`。
    static let separators = [" - ", " – ", " — ", " － "]

    /// 没歌手、没专辑,补空已经失败够次数了。
    public static func noAnchorGaveUp(artist: String, album: String, fillCount: Int) -> Bool {
        artist.trimmingCharacters(in: .whitespaces).isEmpty
            && album.trimmingCharacters(in: .whitespaces).isEmpty
            && fillCount >= noAnchorGiveUpCount
    }

    /// 能不能在某个带空格的分隔符处拆成两段、两段都有字母或数字 —— collector `trustedSplitCandidates`
    /// 非空的同一个判据。
    public static func hasSplit(_ s: String) -> Bool {
        for sep in separators {
            var searchStart = s.startIndex
            while let r = s.range(of: sep, range: searchStart..<s.endIndex) {
                if hasLetterOrDigit(s[s.startIndex..<r.lowerBound]) && hasLetterOrDigit(s[r.upperBound...]) {
                    return true
                }
                searchStart = s.index(after: r.lowerBound)
            }
        }
        return false
    }

    private static func hasLetterOrDigit(_ s: Substring) -> Bool {
        s.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    public struct Row: Sendable {
        public let key, artist, title, album: String
        /// 没歌词、没人工修正、没确证纯音乐。
        public let isEmpty: Bool
        public init(key: String, artist: String, title: String, album: String, isEmpty: Bool) {
            self.key = key
            self.artist = artist
            self.title = title
            self.album = album
            self.isEmpty = isEmpty
        }
    }

    /// 结构上是「一个字段装身份、另一个字段放歌词」留下的空歌词条目,判据同 collector `lyricsPollutedKeys`:
    /// 同一张专辑下,某个字段完全一样且能拆成两段,另一个字段出现 `pollutedMinVariants` 个以上不同值。
    public static func pollutedKeys(_ rows: [Row]) -> Set<String> {
        var byTitle: [String: (variants: Set<String>, keys: [String])] = [:]
        var byArtist: [String: (variants: Set<String>, keys: [String])] = [:]
        for row in rows {
            if hasSplit(row.title) {
                let gk = row.title + "|" + row.album
                byTitle[gk, default: ([], [])].variants.insert(row.artist)
                if row.isEmpty { byTitle[gk, default: ([], [])].keys.append(row.key) }
            }
            if hasSplit(row.artist) {
                let gk = row.artist + "|" + row.album
                byArtist[gk, default: ([], [])].variants.insert(row.title)
                if row.isEmpty { byArtist[gk, default: ([], [])].keys.append(row.key) }
            }
        }
        var out = Set<String>()
        for group in Array(byTitle.values) + Array(byArtist.values) where group.variants.count >= pollutedMinVariants {
            out.formUnion(group.keys)
        }
        return out
    }
}
