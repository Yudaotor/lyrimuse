import Foundation

/// Spotify Canvas 短片地址的形状闸。地址是引擎从 Spotify 客户端本机缓存里读出、记进条目 `spotify_canvas_url` 的那份
/// (lyrimuse-engine/spotifycanvas.go),只认 `https://canvaz.scdn.co/upload/…/<名>.cnvs.mp4`。纯函数,selftest 覆盖。
public enum SpotifyCanvas {
    public static func videoURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host == "canvaz.scdn.co",
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/upload/"), url.path.hasSuffix(".cnvs.mp4"),
              !url.path.contains("..") else { return nil }
        return url
    }
}
