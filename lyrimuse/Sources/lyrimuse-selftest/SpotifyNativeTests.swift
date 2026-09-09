import LyrimuseCore
import Foundation

// Spotify 原生客户端本机数据面(2026-09-09):图床地址识别与换档、通知里的广告分类提示、位置探针输出解析。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计数不中断)。

@MainActor
func runSpotifyNativeTests() {
    // ---- SpotifyArtworkURL:识别 / 换档 / 下载顺序 / URI 分类 ----
    // 地址与 hash 都是 2026-09-09 真机上 AppleScript 与 oEmbed 给出的真实值。
    do {
        let raw = "https://i.scdn.co/image/ab67616d0000b273bb54dde68cd23e2a268ae0f5"
        let url = SpotifyArtworkURL.parse(raw)
        expectEqual(url?.absoluteString, raw, "图床: AppleScript 给的 640 档地址原样通过")
        expectEqual(SpotifyArtworkURL.parse(" \(raw)\n")?.absoluteString, raw, "图床: 首尾空白与换行剔掉")
        expectEqual(SpotifyArtworkURL.parse("https://image-cdn-fa.spotifycdn.com/image/ab67616d00001e02b6d9a4fbb0bd49f0f034aead") != nil,
                    true, "图床: oEmbed 那个 CDN 域名(*.spotifycdn.com)也认")
        expectEqual(SpotifyArtworkURL.parse("missing value"), nil, "图床: 本地文件的 artwork url 是 missing value → nil")
        expectEqual(SpotifyArtworkURL.parse(""), nil, "图床: 空串 → nil")
        expectEqual(SpotifyArtworkURL.parse("http://i.scdn.co/image/ab67616d0000b273bb54dde68cd23e2a268ae0f5"), nil, "图床: 非 https → nil")
        expectEqual(SpotifyArtworkURL.parse("https://evil.example/image/ab67616d0000b273bb54dde68cd23e2a268ae0f5"), nil, "图床: 别的主机 → nil")
        expectEqual(SpotifyArtworkURL.parse("https://i.scdn.co/other/ab67616d0000b273bb54dde68cd23e2a268ae0f5"), nil, "图床: 路径前缀不对 → nil")
        expectEqual(SpotifyArtworkURL.parse("https://i.scdn.co/image/ab67616d0000b273zz"), nil, "图床: hash 形状不对 → nil")
        expectEqual(SpotifyArtworkURL.parse("https://notspotifycdn.com/image/ab67616d0000b273bb54dde68cd23e2a268ae0f5"), nil,
                    "图床: 光是以 spotifycdn.com 结尾的裸域不算(要带点分隔的子域)")
        if let url {
            expectEqual(SpotifyArtworkURL.variant(url, .original)?.absoluteString,
                        "https://i.scdn.co/image/ab67616d000082c1bb54dde68cd23e2a268ae0f5", "换档: b273 → 82c1(原图)")
            expectEqual(SpotifyArtworkURL.variant(url, .small)?.absoluteString,
                        "https://i.scdn.co/image/ab67616d00001e02bb54dde68cd23e2a268ae0f5", "换档: b273 → 1e02(300)")
            expectEqual(SpotifyArtworkURL.variant(url, .large)?.absoluteString, raw, "换档: 换回自己是恒等")
            expectEqual(SpotifyArtworkURL.downloadCandidates(for: url).map(\.absoluteString),
                        ["https://i.scdn.co/image/ab67616d000082c1bb54dde68cd23e2a268ae0f5", raw],
                        "下载顺序: 原图优先、640 兜底")
        }
        expectEqual(SpotifyArtworkURL.variant(URL(string: "https://p2.music.126.net/x.jpg")!, .original), nil,
                    "换档: 不是 Spotify 图床 → nil,别把别家 URL 改坏")
        expectEqual(SpotifyArtworkURL.isTrackURI("spotify:track:0H5iEzn4EWoevLeB60ZJfj"), true, "URI: 真曲目")
        expectEqual(SpotifyArtworkURL.isTrackURI("spotify:ad:abc"), false, "URI: 广告不取封面")
        expectEqual(SpotifyArtworkURL.isTrackURI("spotify:local:a:b:c:1"), false, "URI: 本地文件不取封面")
        expectEqual(SpotifyArtworkURL.isTrackURI("spotify:episode:abc"), false, "URI: 播客节目不取封面")
    }

    // ---- SpotifyNotificationHint:构造 / 分类 / 与快照核对 ----
    // 键名与样例值来自 Spotify.app 二进制字符串表 + 2026-09-09 真机通知(Taylor Swift《Lavender Haze》)。
    do {
        let info: [AnyHashable: Any] = [
            "Track ID": "spotify:track:5jQI2r1RdgtuT8S3iG8zFC", "Name": "Lavender Haze", "Artist": "Taylor Swift",
            "Album": "Midnights", "Player State": "Playing", "Playback Position": 70.33, "Duration": 202395,
        ]
        let hint = SpotifyNotificationHint(userInfo: info)
        expectEqual(hint?.trackID, "spotify:track:5jQI2r1RdgtuT8S3iG8zFC", "通知提示: 读 Track ID")
        expectEqual(hint?.isAd, false, "通知提示: 曲目不是广告")
        expectEqual(hint?.matches(title: "Lavender Haze", artist: "Taylor Swift"), true, "通知提示: 与快照逐字对上")
        expectEqual(hint?.matches(title: " lavender haze ", artist: "TAYLOR SWIFT"), true, "通知提示: 大小写 / 首尾空白不计")
        expectEqual(hint?.matches(title: "Lavender Haze", artist: "Taylor Swift, Ice Spice"), true, "通知提示: 多歌手拼接写法允许前缀关系")
        expectEqual(hint?.matches(title: "Lavender Haze", artist: ""), true, "通知提示: 快照歌手为空只看歌名")
        expectEqual(hint?.matches(title: "Anti-Hero", artist: "Taylor Swift"), false, "通知提示: 歌名对不上就不是这首")
        expectEqual(hint?.matches(title: "Lavender Haze", artist: "Someone Else"), false, "通知提示: 同名不同人不算")
        expectEqual(hint?.matches(title: nil, artist: "Taylor Swift"), false, "通知提示: 快照没有歌名不匹配")
        expectEqual(SpotifyNotificationHint(userInfo: ["Name": "x"]) == nil, true, "通知提示: 没有 Track ID → nil")
        expectEqual(SpotifyNotificationHint(userInfo: ["Track ID": "  "]) == nil, true, "通知提示: Track ID 全空白 → nil")
        expectEqual(SpotifyNotificationHint(userInfo: nil) == nil, true, "通知提示: 没有 userInfo → nil")
        let ad = SpotifyNotificationHint(userInfo: ["Track ID": "spotify:ad:1234", "Name": "Spotify", "Artist": ""])
        expectEqual(ad?.isAd, true, "通知提示: spotify:ad: 前缀是广告")
        expectEqual(ad?.matches(title: "Spotify", artist: "Some Advertiser"), true, "通知提示: 广告一侧歌手为空也只看歌名")
        let empty = SpotifyNotificationHint(trackID: "spotify:track:x", name: "", artist: "a")
        expectEqual(empty.matches(title: "", artist: "a"), false, "通知提示: 两边歌名都空不算匹配")
        expectEqual(SpotifyNotificationHint(trackID: "spotify:episode:x", name: "n", artist: "a").isAd, false, "通知提示: 播客节目不是广告")
    }

    // ---- SpotifyPositionProbe.parseProbeOutput ----
    do {
        typealias P = SpotifyPositionProbe
        let art = "https://i.scdn.co/image/ab67616d0000b273bb54dde68cd23e2a268ae0f5"
        let ok = P.parseProbeOutput("123456|spotify:track:5jQI2r1RdgtuT8S3iG8zFC|\(art)\n")
        expectEqual(ok?.position, 123.456, "探针输出: 毫秒整数 → 秒")
        expectEqual(ok?.uri, "spotify:track:5jQI2r1RdgtuT8S3iG8zFC", "探针输出: 第二段是 URI")
        expectEqual(ok?.artworkURL?.absoluteString, art, "探针输出: 第三段是图床地址")
        let adOut = P.parseProbeOutput("2000|spotify:ad:abc|missing value")
        expectEqual(adOut?.position, 2.0, "探针输出: 广告也有位置")
        expectEqual(adOut?.uri, "spotify:ad:abc", "探针输出: 广告 URI 原样带回")
        expectEqual(adOut?.artworkURL, nil, "探针输出: missing value 不是地址")
        expectEqual(P.parseProbeOutput("12.5")?.position, 12.5, "探针输出: 旧形态(裸秒数)仍能解析")
        expectEqual(P.parseProbeOutput("") == nil, true, "探针输出: 空串(Spotify 没在跑)→ nil")
        expectEqual(P.parseProbeOutput("   \n") == nil, true, "探针输出: 只有空白 → nil")
        expectEqual(P.parseProbeOutput("abc|x|y") == nil, true, "探针输出: 位置解析不出来 → 整条作废")
        expectEqual(P.parseProbeOutput("1500|")?.uri, nil, "探针输出: URI 为空当没有")
        expectEqual(P.parseProbeOutput("1500|spotify:track:x|https://evil.example/x")?.artworkURL, nil, "探针输出: 别家主机的地址不收")
    }
}
