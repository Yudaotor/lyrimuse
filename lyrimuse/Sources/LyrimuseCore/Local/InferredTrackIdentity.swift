import Foundation

/// 播放器没报歌手时,引擎按「歌名 + 时长」认出来的歌手和专辑(lyrimuse-engine/inferredidentity.go,见 03 章决策 32)。
///
/// 只给界面上的歌手位、专辑位用:查缓存、拼链接、打卡仍用播放器报的那份。
public struct InferredTrackIdentity: Equatable, Sendable {
    public let artist: String
    public let album: String

    public init(artist: String, album: String) {
        self.artist = artist
        self.album = album
    }

    /// 歌手位显示什么:播放器报了歌手、或者这一拍本来就有要显示的字时照旧;两样都空才用认出来的歌手。
    public static func displayArtist(playerArtist: String, display: String, inferred: InferredTrackIdentity?) -> String {
        guard playerArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, display.isEmpty, let inferred else { return display }
        return inferred.artist
    }

    /// 专辑位显示什么:规则同歌手位(播放器没报专辑、也没有 YouTube Music 登记的专辑 / 「MV」时才用认出来的专辑)。
    public static func displayAlbum(playerAlbum: String, display: String, inferred: InferredTrackIdentity?) -> String {
        guard playerAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, display.isEmpty, let inferred else { return display }
        return inferred.album
    }
}
