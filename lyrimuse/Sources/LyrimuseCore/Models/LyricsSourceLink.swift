import Foundation

/// 歌词来源处的链接。只有条款要求显示时链回的源有(Megalobiz):条目存着它自己的 https 歌词页(引擎写的 `lyrics_source_url`)时,
/// 歌词窗口简介和网页歌词简介的「来源」行、歌词管理详情的来源胶囊做成可点的,点了用默认浏览器打开;别的源一律没有。
/// 见 09 章决策 386。
public enum LyricsSourceLink {
    /// 源 → 它的歌词页所在的主机。存的地址不在这几个主机上(含 http、别的域名)的不做链接。
    static let pageHosts: [String: Set<String>] = ["megalobiz": ["megalobiz.com", "www.megalobiz.com"]]

    /// 这份歌词来源处该放的链接;source 不是要链回的源、没存地址或地址不对时为 nil。
    public static func url(source: String?, stored: String?) -> URL? {
        guard let source, let hosts = pageHosts[source],
              let raw = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme == "https", url.user == nil,
              let host = url.host?.lowercased(), hosts.contains(host)
        else { return nil }
        return url
    }
}
