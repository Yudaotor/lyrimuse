import Foundation

/// 「Last.fm 账号建议」里的一条:侧栏那一行的计数、建议页的每一行(仿系统设置「Apple 账户建议」)。纯值,单测见 LastfmTests。
public enum LastfmAccountSuggestion: Equatable, Sendable, Identifiable {
    /// 连接 Last.fm 那一趟没成功,带失败原因。
    case connectFailed(String)
    /// 授权失效(collector 熔断落了状态文件),Scrobble 已暂停。
    case authRevoked
    /// Last.fm 跟 Spotify 的连接让 Spotify 重复记或漏记。
    case spotify(LastfmSpotifyLink.PlayersRowHint)

    public var id: String {
        switch self {
        case .connectFailed: return "connect-failed"
        case .authRevoked: return "auth-revoked"
        case .spotify: return "spotify"
        }
    }

    /// 此刻有哪些建议,要紧的在前。连接失败和授权失效都要重新连接,只出一条,连接失败优先;授权失效只在本地还有 session key
    /// 时才算(断开之后留下的状态文件不算)。跟账号状态 `destinationStatus` 的判定同一个顺序。
    public static func current(connectFailure: String?, connected: Bool, authRevoked: Bool,
                               spotify: LastfmSpotifyLink.PlayersRowHint?) -> [LastfmAccountSuggestion] {
        var out: [LastfmAccountSuggestion] = []
        if let connectFailure {
            out.append(.connectFailed(connectFailure))
        } else if connected, authRevoked {
            out.append(.authRevoked)
        }
        if let spotify { out.append(.spotify(spotify)) }
        return out
    }
}
