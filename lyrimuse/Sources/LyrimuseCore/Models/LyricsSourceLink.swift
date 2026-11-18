import Foundation

/// 歌词来源处的链接。只有要链回的源有(Megalobiz 条款要求;AMLL 链回 amll-ttml-db 仓库里那份 TTML):条目存着它的 https 页面
/// (引擎写的 `lyrics_source_url`)、
/// 或搜索候选带着它(`source_url`)时,歌词窗口简介和网页歌词简介的「来源」行、歌词管理详情的来源胶囊、搜索候选歌词面板的来源标、
/// 歌词版本对照表的「歌词来源」格做成可点的,点了用默认浏览器打开;别的源一律没有。
/// 见 09 章决策 386;AMLL 见 09 章决策 388。
public enum LyricsSourceLink {
    /// 源 → 它的歌词页所在的主机。存的地址不在这几个主机上(含 http、别的域名、别的端口)的不做链接。
    /// 引擎侧 megalobizPageURL、amllPageURL 同一口径,两边一起改。
    static let pageHosts: [String: Set<String>] = ["megalobiz": ["megalobiz.com", "www.megalobiz.com"], "amll": ["github.com"]]
    /// 源 → 地址路径必须以这几段开头(没列的源不限路径)。AMLL 只认 amll-ttml-db 仓库自己的页面,github.com 上别的仓库不认:
    /// 每段只有字母、数字和「._-」且不是「.」「..」,不带查询串和片段。
    static let pathPrefixes: [String: [String]] = ["amll": ["amll-dev", "amll-ttml-db"]]

    /// 这份歌词来源处该放的链接;source 不是要链回的源、没存地址或地址不对时为 nil。
    public static func url(source: String?, stored: String?) -> URL? {
        guard let source, let hosts = pageHosts[source],
              let raw = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme == "https", url.user == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), hosts.contains(host)
        else { return nil }
        if let prefix = pathPrefixes[source], !pathFits(url, raw: raw, prefix: prefix) { return nil }
        return url
    }

    private static func pathFits(_ url: URL, raw: String, prefix: [String]) -> Bool {
        guard url.query == nil, url.fragment == nil, !raw.contains("?"), !raw.contains("#"),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        else { return false }
        let segs = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segs.count > prefix.count, segs[0].isEmpty, Array(segs[1...prefix.count]) == prefix else { return false }
        return segs.dropFirst().allSatisfy { seg in
            !seg.isEmpty && seg != "." && seg != ".."
                && seg.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
        }
    }
}
