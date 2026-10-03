import Foundation

/// 「歌手来自哪里」卡的数据:collector 后台汇总好的缓存(`lyrimuse-artist-regions.json`,collector artistregions.go 写)。
/// 每个时段是歌手榜前若干位按 MusicBrainz 登记的所属国家或地区(不是出生地)加权汇总的结果。只读,不联网。
public enum ArtistRegions {
    public static let fileName = "lyrimuse-artist-regions.json"

    public struct Region: Decodable, Equatable, Sendable {
        /// ISO 3166-1 两位代码。
        public let code: String
        public let plays: Int
        public let artists: [String]

        enum CodingKeys: String, CodingKey { case code, plays, artists }

        // Go 把空切片编成 null;这里缺了按空,别让一行的名字列表让整份文件解析失败。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(String.self, forKey: .code)
            plays = try c.decodeIfPresent(Int.self, forKey: .plays) ?? 0
            artists = try c.decodeIfPresent([String].self, forKey: .artists) ?? []
        }
    }

    public struct Period: Decodable, Equatable, Sendable {
        /// 按歌手榜前多少位统计(collector artistRegionsTopArtists 写进文件的);老文件没写是 0。
        public let topArtists: Int
        /// 统计到的歌手合计播放次数(各地区 + pending + unresolved)。
        public let covered: Int
        /// 有 mbid、collector 还没查到的(「还在查」);查完会归进某个地区或 unresolved。
        public let pending: Int
        public let pendingArtists: [String]
        /// 没有 mbid、或查过但 MusicBrainz 没登记国家的(「未查到」)。
        public let unresolved: Int
        public let unresolvedArtists: [String]
        public let regions: [Region]

        enum CodingKeys: String, CodingKey {
            case covered, pending, unresolved, regions
            case topArtists = "top_artists"
            case pendingArtists = "pending_artists"
            case unresolvedArtists = "unresolved_artists"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            topArtists = try c.decodeIfPresent(Int.self, forKey: .topArtists) ?? 0
            covered = try c.decodeIfPresent(Int.self, forKey: .covered) ?? 0
            pending = try c.decodeIfPresent(Int.self, forKey: .pending) ?? 0
            pendingArtists = try c.decodeIfPresent([String].self, forKey: .pendingArtists) ?? []
            unresolved = try c.decodeIfPresent(Int.self, forKey: .unresolved) ?? 0
            unresolvedArtists = try c.decodeIfPresent([String].self, forKey: .unresolvedArtists) ?? []
            regions = try c.decodeIfPresent([Region].self, forKey: .regions) ?? []
        }
    }

    struct File: Decodable {
        var user: String?
        var periods: [String: Period]?
    }

    /// 键是 Last.fm 时段名(`1month` / `12month` / `overall`)。解析失败、或文件属于别的账号(换账号后 collector
    /// 还没重算)时返回空表。账号名不分大小写比较(Last.fm 用户名不分大小写)。
    public static func parse(_ data: Data, user: String) -> [String: Period] {
        guard let f = try? JSONDecoder().decode(File.self, from: data),
              let owner = f.user, owner.caseInsensitiveCompare(user) == .orderedSame
        else { return [:] }
        return f.periods ?? [:]
    }

    /// 收听时段卡的范围跟这张卡共用一套;对应的 Last.fm 时段名。collector artistRegionsPeriods 必须是同三档。
    public static func period(for span: ListeningHours.Span) -> String {
        switch span {
        case .month: return "1month"
        case .year: return "12month"
        case .overall: return "overall"
        }
    }

    public struct Row: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case region(String)
            /// 排在 `maxRegions` 之后的地区合在一起。
            case other
            /// collector 还没查到的那部分;全部查完这一行就不出。
            case pending
            /// 没有 mbid、或查过没登记国家的那部分。
            case unresolved
        }
        public let kind: Kind
        public let plays: Int
        public let artists: [String]
    }

    /// 卡上要画的行:前 `maxRegions` 个地区,其余并成「其他」,再是「还在查」,最后是「未查到」。次数为 0 的行不出。
    /// 「其他」的歌手取被并进去的那些地区各自播放最多的那位,按地区次序取前 `namesPerRow` 个。
    public static func rows(_ p: Period, maxRegions: Int = 6, namesPerRow: Int = 3) -> [Row] {
        var out = p.regions.prefix(maxRegions)
            .filter { $0.plays > 0 }
            .map { Row(kind: .region($0.code), plays: $0.plays, artists: $0.artists) }
        let rest = p.regions.dropFirst(maxRegions)
        let restPlays = rest.reduce(0) { $0 + $1.plays }
        if restPlays > 0 {
            out.append(Row(kind: .other, plays: restPlays,
                           artists: Array(rest.compactMap(\.artists.first).prefix(namesPerRow))))
        }
        if p.pending > 0 {
            out.append(Row(kind: .pending, plays: p.pending, artists: Array(p.pendingArtists.prefix(namesPerRow))))
        }
        if p.unresolved > 0 {
            out.append(Row(kind: .unresolved, plays: p.unresolved, artists: Array(p.unresolvedArtists.prefix(namesPerRow))))
        }
        return out
    }
}
