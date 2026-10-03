import Foundation

/// Last.fm 账号在 Last.fm 网站上连没连 Spotify。连着时 Spotify 自己把收听记到 Last.fm;Spotify 大约每 6 个月断一次第三方
/// 连接,断了不提示。判据是 `user.getinfo` 的 `spotify_expiry_estimate`:连着才有,值是连接的预计到期时间,过期后字段还在、
/// 时间在过去。Last.fm 官方文档里没有这个字段,形状跟 `registered` 一样(`{"unixtime": "…", "#text": …}`,unixtime 可能是
/// 字符串也可能是数字)。见 12 章决策 20。
public enum LastfmSpotifyLink: Equatable, Sendable {
    case notLinked
    case linked(expires: Date)
    case expired(at: Date)

    /// 到期时间正好是此刻也算过期。
    public init(expiry: Date?, now: Date) {
        guard let expiry else {
            self = .notLinked
            return
        }
        self = expiry > now ? .linked(expires: expiry) : .expired(at: expiry)
    }

    /// `user.getinfo` 应答里 `user` 那一层的到期时间。没有这个字段、或解不出一个正的时间戳时为 nil。
    public static func expiry(user: [String: Any]) -> Date? {
        guard let raw = user["spotify_expiry_estimate"] else { return nil }
        if let object = raw as? [String: Any] {
            return timestamp(object["unixtime"]) ?? timestamp(object["#text"])
        }
        return timestamp(raw)
    }

    private static func timestamp(_ value: Any?) -> Date? {
        let seconds: Double?
        switch value {
        case let number as NSNumber: seconds = number.doubleValue
        case let text as String: seconds = Double(text.trimmingCharacters(in: .whitespaces))
        default: seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 「Scrobble 的播放器」的勾选跟这条连接对不上时的提示(Last.fm 账号页「建议」分组里的那一条)。
    public enum PlayersRowHint: Equatable, Sendable {
        /// 连着 Spotify、这里也勾着 Spotify:每首记两次。
        case doubleScrobble
        /// 这里排除了 Spotify、连接又过期了:Spotify 上放的歌哪边都不记。
        case expiredWhileExcluded(at: Date)
    }

    /// 调用方先确认那一排里有 Spotify;`spotifyExcluded` = Spotify 在排除集合里。
    public func playersRowHint(spotifyExcluded: Bool) -> PlayersRowHint? {
        switch self {
        case .notLinked: return nil
        case .linked: return spotifyExcluded ? nil : .doubleScrobble
        case .expired(let at): return spotifyExcluded ? .expiredWhileExcluded(at: at) : nil
        }
    }

    /// 系统通知只为 `expiredWhileExcluded` 弹,同一次过期(按到期时间)只弹一次。返回这次要记下的到期时间(秒),不用弹为 nil。
    public func expiryToAnnounce(spotifyExcluded: Bool, announced: Int64?) -> Int64? {
        guard case .expiredWhileExcluded(let at) = playersRowHint(spotifyExcluded: spotifyExcluded) else { return nil }
        let stamp = Int64(at.timeIntervalSince1970)
        return stamp == announced ? nil : stamp
    }

    /// 要不要再问一次 Last.fm:还没查成过、上次查成已超过 `maxAge`(或时钟倒退到它之前)、或者按上次的结论此刻就要弹通知
    /// —— 弹之前先重查确认,用户可能已经在 Last.fm 上重新连接过。
    public static func checkDue(lastChecked: Date?, now: Date, maxAge: TimeInterval, wouldAnnounce: Bool) -> Bool {
        guard let lastChecked else { return true }
        let age = now.timeIntervalSince(lastChecked)
        return wouldAnnounce || age < 0 || age >= maxAge
    }
}
