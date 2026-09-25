import Foundation

/// Last.fm 统计页「听得最多」榜单跟上一期比的名次升降。
///
/// 上一期 = 紧挨着本期之前、同样长的窗口,用 `user.getWeekly*Chart` 带起止时间取。按这三个长度取出的
/// 本期榜跟滚动榜(`user.getTop*` 的 7day / 1month / 12month)逐条一致,两期同口径。
/// collector `topartistscli.go` 的 `topArtistsPeriodSpan` 用同一组长度,两处必须同步改。
public enum ChartComparison {
    /// 时段(Last.fm 的 period 参数)对应的窗口长度;overall 没有上一期,返回 nil。
    public static func span(forPeriod period: String) -> TimeInterval? {
        switch period {
        case "7day": return 7 * 86_400
        case "1month": return 30 * 86_400
        case "12month": return 365 * 86_400
        default: return nil
        }
    }

    /// 本期结束于 `now` 时的上一期窗口。
    public static func previousWindow(span: TimeInterval, now: Date) -> (from: Date, to: Date) {
        (now.addingTimeInterval(-2 * span), now.addingTimeInterval(-span))
    }

    /// 专辑 / 歌曲榜的对齐键:署名歌手 + 名称,大小写不算差异。
    public static func key(artist: String, name: String) -> String {
        artist.lowercased() + "\u{1}" + name.lowercased()
    }

    /// 本期每一条在上一期榜里的名次(按键对齐,重复键取靠前的),上一期没有为 0。
    public static func previousRanks(current: [String], previous: [String]) -> [Int] {
        var rank: [String: Int] = [:]
        for (i, k) in previous.enumerated() where rank[k] == nil {
            rank[k] = i + 1
        }
        return current.map { rank[$0] ?? 0 }
    }

    /// 周榜响应(`weeklyalbumchart.album` / `weeklytrackchart.track`)按名次顺序取出对齐键和合计次数。
    /// 列表只有一条时 Last.fm 可能给对象不给数组,两种都认;形状不对返回 nil(当作上一期取数失败)。
    public static func parseWeeklyChart(_ json: [String: Any], container: String, item: String)
        -> (keys: [String], listens: Int)? {
        guard let box = json[container] as? [String: Any] else { return nil }
        var rows = (box[item] as? [[String: Any]]) ?? []
        if rows.isEmpty, let single = box[item] as? [String: Any] { rows = [single] }
        var keys: [String] = []
        var listens = 0
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty else { continue }
            let artist = (row["artist"] as? [String: Any])?["#text"] as? String ?? ""
            keys.append(key(artist: artist, name: name))
            listens += Int(row["playcount"] as? String ?? "") ?? 0
        }
        return (keys, listens)
    }
}

/// 一行的名次变化。`previousRank`:上一期名次,0 = 上一期榜里没有,nil = 这一档没有可比的上一期。
public enum ChartMovement: Equatable {
    case new
    case same
    case up(Int)
    case down(Int)

    public static func of(rank: Int, previousRank: Int?) -> ChartMovement? {
        guard let previous = previousRank else { return nil }
        if previous <= 0 { return .new }
        if previous == rank { return .same }
        return previous > rank ? .up(previous - rank) : .down(rank - previous)
    }

    /// 名次差超过这个数只显示「99+」:上一期排一百多名的歌这一期进了前十,具体数字没有比较意义。
    public static let maxShownStep = 99

    /// 箭头后面的数字;new / same 没有数字。
    public var stepText: String? {
        switch self {
        case .up(let n), .down(let n): return n > Self.maxShownStep ? "\(Self.maxShownStep)+" : "\(n)"
        case .new, .same: return nil
        }
    }
}
