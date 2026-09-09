import Foundation

/// Spotify 图床地址的识别与换档(2026-09-09)。
///
/// 原生客户端的 AppleScript `artwork url of current track` 返回
/// `https://i.scdn.co/image/ab67616d0000b273<24 位十六进制>`:固定前缀 `ab67616d0000` 之后那 4 个字符是
/// **尺寸档**,同一张图换档位就是换尺寸。2026-09-09 拿真实 hash 对着两个 CDN 域名
/// (`i.scdn.co` / `image-cdn-fa.spotifycdn.com`)实测,两边结果一致:
///
/// | 档位 | 实测尺寸 |
/// |---|---|
/// | `4851` | 64×64 |
/// | `1e02` | 300×300(oEmbed 的 thumbnail_url 给的就是这一档) |
/// | `b273` | 640×640(AppleScript 默认给的这一档) |
/// | `82c1` | 原图,三张分别是 800 / 1425 / 2000 |
///
/// 原图那档尺寸不定,所以调用方拿它当"第一候选"、取不到再退 640(见 downloadCandidates)。
/// 判据全部收在这里、selftest 直接覆盖;`SpotifyPositionProbe` / `PlaybackCoordinator` 只调用、不自己拼字符串。
public enum SpotifyArtworkURL {
    public enum Variant: String, CaseIterable, Sendable {
        case tiny = "4851"
        case small = "1e02"
        case large = "b273"
        case original = "82c1"
    }

    /// 只认这两类主机:`i.scdn.co`,以及 `*.spotifycdn.com`。后者判"以 `.spotifycdn.com` 结尾且前面还有
    /// 东西",不用裸 hasSuffix(理由同 EnrichCacheReader 里网易云那条:`evilspotifycdn.com` 也会被裸
    /// hasSuffix 放进来)。
    static let exactHosts: Set<String> = ["i.scdn.co"]
    static let hostSuffix = ".spotifycdn.com"
    /// 路径形状:`/image/ab67616d0000` + 4 位档位 + 十六进制 hash。
    static let pathPrefix = "/image/ab67616d0000"
    /// hash 至少这么长才算(实测 24 位;留余量但别把明显不是 hash 的东西放进来)。
    static let minHashLength = 16

    /// 解析 AppleScript 回来的字符串。不是 https / 主机不对 / 路径形状不对 → nil
    /// (本地文件的 `artwork url` 是 `missing value`,同样落到 nil)。
    public static func parse(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let url = URL(string: s),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), isSpotifyImageHost(host),
              components(ofPath: url.path) != nil
        else { return nil }
        return url
    }

    public static func isSpotifyImageHost(_ host: String) -> Bool {
        exactHosts.contains(host) || (host.hasSuffix(hostSuffix) && host.count > hostSuffix.count)
    }

    /// 把路径拆成 (档位, hash)。形状不对 → nil。
    static func components(ofPath path: String) -> (variant: String, hash: String)? {
        guard path.hasPrefix(pathPrefix) else { return nil }
        let rest = path.dropFirst(pathPrefix.count)
        guard rest.count >= 4 + minHashLength else { return nil }
        let variant = String(rest.prefix(4))
        let hash = String(rest.dropFirst(4))
        guard isHex(variant), isHex(hash) else { return nil }
        return (variant, hash)
    }

    private static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    /// 同一张图换档位。不是 Spotify 图床地址 → nil(别把别家 URL 改坏)。
    public static func variant(_ url: URL, _ v: Variant) -> URL? {
        guard let host = url.host?.lowercased(), isSpotifyImageHost(host),
              let parts = components(ofPath: url.path),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        comps.path = pathPrefix + v.rawValue + parts.hash
        return comps.url
    }

    /// 高清替代的下载顺序:原图优先,取不到退 640。地址已经是 640 档时第二项就是它自己;去重后可能只剩一项。
    public static func downloadCandidates(for url: URL) -> [URL] {
        var out: [URL] = []
        for v in [Variant.original, .large] {
            if let u = variant(url, v), !out.contains(u) { out.append(u) }
        }
        return out
    }

    /// `spotify url` / `id` 的前缀分类:只有真曲目才值得去取封面 —— 广告的 `artwork url` 是广告物料图,
    /// 本地文件没有图床图,播客节目拿到的是节目图。
    public static func isTrackURI(_ uri: String) -> Bool {
        uri.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("spotify:track:")
    }
}
