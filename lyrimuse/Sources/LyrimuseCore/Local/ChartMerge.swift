import Foundation

/// Last.fm 榜单里的一行:所属歌手(歌手榜为空)、名称、次数。
public struct ChartRow: Equatable, Codable, Sendable {
    public let artist: String
    public let name: String
    public let playcount: Int

    public init(artist: String, name: String, playcount: Int) {
        self.artist = artist
        self.name = name
        self.playcount = playcount
    }
}

/// 歌曲榜、专辑榜里同一首歌 / 同一张专辑的不同写法并成一行。歌曲按「第 N 次听」那把尺子 `PlayCountFold.familyKey`
/// 判同一首(繁简、括号与 feat. 写法、再版尾巴、罗马字艺名与中文名、英文歌名与中文歌名),两处的次数是同一个口径;
/// 专辑按 `PlayCountFold.albumFamilyKey`。Live / Remix 这类另一份录音、不同歌手的同名歌仍是两首。见 12 章决策 27、28。
public enum ChartMerge {
    /// 合并前从 Last.fm 取的原始行数。同一首歌的另一种写法常排在一两百名开外,只取露出的那几十行并不全。
    public static let poolLimit = 500

    /// 并好的一行。显示成员里次数最多的那种写法(平手取先出现的,即 Last.fm 名次靠前的),次数相加;
    /// `variants` 是并进来的其它写法,保持输入的先后。
    public struct Merged: Equatable, Sendable {
        public let key: String
        public let artist: String
        public let name: String
        public let playcount: Int
        public let variants: [ChartRow]
    }

    /// 同一次合并里同一种写法只算一次键:折叠键要做几轮 NFKC 与繁简转换,一行一两百微秒,本期和上一期的行又大多相同。
    public final class KeyMemo {
        private let key: (ChartRow) -> String
        private var memo: [String: String] = [:]

        public init(key: @escaping (ChartRow) -> String) {
            self.key = key
        }

        /// 歌曲榜:同一首歌。
        public static func songs() -> KeyMemo {
            KeyMemo { PlayCountFold.familyKey(artist: $0.artist, title: $0.name) }
        }

        /// 专辑榜:同一张专辑。
        public static func albums() -> KeyMemo {
            KeyMemo { PlayCountFold.albumFamilyKey(artist: $0.artist, album: $0.name) }
        }

        public func callAsFunction(_ row: ChartRow) -> String {
            let raw = row.artist + "\u{1F}" + row.name
            if let hit = memo[raw] { return hit }
            let value = key(row)
            memo[raw] = value
            return value
        }
    }

    /// 合并后的一档榜单里的一行,带上一期名次:0 = 上一期没有,nil = 没有可比的上一期。
    public struct Ranked: Equatable, Sendable {
        public let row: Merged
        public let previousRank: Int?
    }

    /// 一档榜单:合并后取前 `limit` 行;上一期按同一把尺子合并、排名之后再对齐名次。
    /// `previous` 为 nil = 没有可比的上一期。本期和上一期共用一张记忆表。
    public static func chart(current: [ChartRow], previous: [ChartRow]?, limit: Int, key: KeyMemo) -> [Ranked] {
        let merged = Array(merge(current, key: key).prefix(limit))
        guard let previous else { return merged.map { Ranked(row: $0, previousRank: nil) } }
        let ranks = ChartComparison.previousRanks(current: merged.map(\.key), previous: merge(previous, key: key).map(\.key))
        return zip(merged, ranks).map { Ranked(row: $0, previousRank: $1) }
    }

    /// `rows` 按 Last.fm 名次给出。结果按合计次数降序,平手保持首次出现的先后。
    public static func merge(_ rows: [ChartRow], key: KeyMemo) -> [Merged] {
        var order: [String] = []
        var groups: [String: [ChartRow]] = [:]
        for row in rows {
            let k = key(row)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(row)
        }
        let merged = order.map { k -> Merged in
            let members = groups[k]!
            var shown = 0
            for i in members.indices where members[i].playcount > members[shown].playcount { shown = i }
            var variants = members
            let top = variants.remove(at: shown)
            return Merged(key: k, artist: top.artist, name: top.name,
                          playcount: members.reduce(0) { $0 + $1.playcount }, variants: variants)
        }
        return merged.enumerated()
            .sorted { a, b in
                a.element.playcount != b.element.playcount ? a.element.playcount > b.element.playcount : a.offset < b.offset
            }
            .map(\.element)
    }
}
