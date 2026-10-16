import Foundation

/// 播放器报的专辑名是占位、不是一张专辑:咪咕把没归进专辑的歌记在「单曲发行」名下(洛雪列表里那一条的 albumId 是 1),播放器
/// 给这些歌的图是歌手照片,不当封面用(`LXMusicOpenAPI.ownCoverURL`、`EnrichCacheReader.playerCovers`)。跟引擎
/// placeholderalbum.go 同一份名单(那边的单测对着这里核)。见 03 章决策 54。
public enum PlaceholderAlbum {
    static let names: Set<String> = ["单曲发行"]

    /// 这个专辑名是占位名(去掉首尾空白比)。纯函数,selftest 覆盖。
    public static func contains(_ album: String?) -> Bool {
        guard let album else { return false }
        return names.contains(album.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
