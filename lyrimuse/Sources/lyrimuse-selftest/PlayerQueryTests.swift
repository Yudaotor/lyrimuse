import Foundation
import LyrimuseCore

/// collector 预解析要的播放器查询由 App 代跑(`PlayerQueryServer`):请求怎么判、几段固定脚本长什么样、契约键名。
/// 脚本的输出由 collector 解析,字段顺序与守卫两边一起钉(Go 侧 appquery_test.go 读源码对账)。
func runPlayerQueryTests() {
    typealias S = PlayerQueryServer
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let nowMs = Int64(now.timeIntervalSince1970 * 1000)
    func request(_ kind: String, count: Int? = nil, album: String? = nil, bundle: String? = nil, platform: String? = nil,
                 schema: Int = S.schema, id: String = "q1", ageSecs: Double = 0) -> S.Request {
        S.Request(schema: schema, id: id, kind: kind, count: count, album: album, bundleID: bundle, platform: platform,
                  writtenAtMs: nowMs - Int64(ageSecs * 1000))
    }
    let backslash = String(UnicodeScalar(UInt8(92)))
    let quote = String(UnicodeScalar(UInt8(34)))
    let newline = String(UnicodeScalar(UInt8(10)))

    // ---- 判请求:只认五种,参数逐项校验;契约版本不认识、没有 id、过期的不答 ----
    expectEqual(S.decide(request("apple_music_queue", count: 5), now: now), .run(.appleMusicQueue(count: 5)),
                "查询: Music 系统待播队列 5 首")
    for bad in [0, 21] {
        expectEqual(S.decide(request("apple_music_queue", count: bad), now: now), .fail("invalid count"),
                    "查询: 系统队列首数 \(bad) 超出 1...20")
    }
    expectEqual(S.decide(request("apple_music_queue"), now: now), .fail("invalid count"), "查询: 系统队列没给首数")
    expectEqual(S.decide(request("apple_music_upcoming", count: 5), now: now), .run(.appleMusicUpcoming(count: 5)),
                "查询: Music 待播 5 首")
    for bad in [0, 21] {
        expectEqual(S.decide(request("apple_music_upcoming", count: bad), now: now), .fail("invalid count"),
                    "查询: 待播首数 \(bad) 超出 1...20")
    }
    expectEqual(S.decide(request("apple_music_upcoming"), now: now), .fail("invalid count"), "查询: 待播没给首数")
    expectEqual(S.decide(request("apple_music_album_tracks", album: "范特西"), now: now),
                .run(.appleMusicAlbumTracks(album: "范特西")), "查询: 专辑曲目表")
    for bad in ["", String(repeating: "a", count: S.maxAlbumLength + 1), "A" + newline + "B"] {
        expectEqual(S.decide(request("apple_music_album_tracks", album: bad), now: now), .fail("invalid album"),
                    "查询: 专辑名空 / 过长 / 带控制字符的不跑(长度 \(bad.count))")
    }
    expectEqual(S.decide(request("spotify_shuffle"), now: now), .run(.spotifyShuffle), "查询: Spotify 随机")
    for platform in ["youtubeMusic", "spotifyWeb"] {
        expectEqual(S.decide(request("browser_queue", bundle: "com.apple.Safari", platform: platform), now: now),
                    .run(.browserQueue(bundleID: "com.apple.Safari", platformID: platform)), "查询: \(platform) 网页队列")
    }
    expectEqual(S.decide(request("browser_queue", bundle: "com.apple.Safari", platform: "soundcloud"), now: now),
                .fail("unsupported platform"), "查询: 不认识的网页平台")
    for bad in ["", "com.apple.Safari; ls", "com/apple"] {
        expectEqual(S.decide(request("browser_queue", bundle: bad, platform: "youtubeMusic"), now: now),
                    .fail("invalid bundle id"), "查询: bundle id 形状不对的不跑(\(bad))")
    }
    expectEqual(S.decide(request("run_script"), now: now), .fail("unsupported kind"), "查询: 不认识的种类答失败")
    expectEqual(S.decide(request("spotify_shuffle", schema: S.schema + 1), now: now), .ignore, "查询: 契约版本不认识不答")
    expectEqual(S.decide(request("spotify_shuffle", id: ""), now: now), .ignore, "查询: 没有 id 不答")
    expectEqual(S.decide(request("spotify_shuffle", ageSecs: S.requestMaxAge + 1), now: now), .ignore,
                "查询: 过期的请求不答(collector 早不等了)")
    expectEqual(S.decide(request("spotify_shuffle", ageSecs: S.requestMaxAge - 1), now: now), .run(.spotifyShuffle),
                "查询: 还在等的请求照答")

    // ---- AppleScript 字面量:先转义反斜杠,再转义双引号 ----
    expectEqual(S.appleScriptQuoted("Bad"), quote + "Bad" + quote, "转义: 普通文字只包一层引号")
    expectEqual(S.appleScriptQuoted("Live at " + quote + "Budokan" + quote),
                quote + "Live at " + backslash + quote + "Budokan" + backslash + quote + quote, "转义: 双引号")
    expectEqual(S.appleScriptQuoted("a" + backslash + "b"), quote + "a" + backslash + backslash + "b" + quote, "转义: 反斜杠")
    expectEqual(S.appleScriptQuoted(backslash + quote), quote + backslash + backslash + backslash + quote + quote,
                "转义: 反斜杠先转,双引号后转")

    // ---- 几段脚本:守卫都在 ----
    let albumScript = S.appleMusicAlbumTracksScript(album: "Live at " + quote + "Budokan" + quote)
    expectEqual(albumScript.hasPrefix("if application " + quote + "Music" + quote + " is not running then"), true,
                "专辑脚本: 先判 running,不把没开的 Music.app 拉起来")
    expectEqual(albumScript.contains("whose album is " + S.appleScriptQuoted("Live at " + quote + "Budokan" + quote)
                                     + " and media kind is song"), true, "专辑脚本: 专辑名转义后嵌入,只收 media kind 是 song 的")
    let upcomingScript = S.appleMusicUpcomingScript(count: 5)
    for needle in ["is not running then", "if player state is stopped then return", "if shuffle enabled then return",
                   "on error", "to (i + 5)"] {
        expectEqual(upcomingScript.contains(needle), true, "待播脚本: 要有 \(needle)")
    }
    expectEqual(S.spotifyShuffleScript.hasPrefix("if application " + quote + "Spotify" + quote + " is running then"), true,
                "Spotify 随机: 先判 running,不把它拉起来")

    // ---- 系统待播队列:App 跑加载器、问的是 Music.app,输出原样交给 collector(源码契约)----
    do {
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LyrimuseCore/Local")
        let server = (try? String(contentsOf: local.appendingPathComponent("PlayerQueryServer.swift"), encoding: .utf8)) ?? ""
        let probe = (try? String(contentsOf: local.appendingPathComponent("NowPlayingClientsProbe.swift"), encoding: .utf8)) ?? ""
        expectEqual(server.contains("case .appleMusicQueue(let count):")
                    && server.contains("NowPlayingClientsProbe.queue(forBundleID: PlaybackPlayer.appleMusic.bundleIdentifier"), true,
                    "系统待播队列(契约): 问的是 Music.app")
        expectEqual(probe.contains("[paths.script, paths.library, bundleID, " + quote + "queue=\\(count)" + quote + "]")
                    && probe.contains("return r.stdoutText"), true,
                    "系统待播队列(契约): 加载器带 queue=N,输出原样返回")
        expectEqual(S.Kind.allCases.count, 5, "查询: 五种,跟 collector 的 appQuery 常量一一对应")
    }

    // ---- 网页队列 JS:能嵌进 AppleScript,输出形状跟 collector 的解析对得上 ----
    for (platform, js) in [("youtubeMusic", S.youTubeMusicQueueJS), ("spotifyWeb", S.spotifyWebQueueJS)] {
        expectEqual(js.contains(quote) || js.contains(backslash), false, "\(platform) 队列 JS: 不能有双引号或反斜杠")
        expectEqual(js.contains("String.fromCharCode(31)") && js.contains("String.fromCharCode(30)"), true,
                    "\(platform) 队列 JS: 字段用 US、记录用 RS")
        expectEqual(js.contains("'NOTFOUND'"), true, "\(platform) 队列 JS: 找不到时返回 NOTFOUND")
        expectEqual(S.browserQueueSite(platformID: platform)?.js, js, "\(platform): 平台对上自己那段 JS")
    }
    expectEqual(S.youTubeMusicQueueJS.contains("watchEndpointMusicConfig"), true, "YouTube Music 队列 JS: 读出每一首的 musicVideoType")
    expectEqual(S.browserQueueSite(platformID: "youtubeMusic")?.hostMarker, YouTubeMusicAdProbe.hostMarker, "YouTube Music: 标签页域名")
    expectEqual(S.browserQueueSite(platformID: "spotifyWeb")?.hostMarker, SpotifyWebAdProbe.hostMarker, "Spotify 网页版: 标签页域名")

    // ---- 契约:文件名与 JSON 键名跟 collector 的 json tag 一致 ----
    expectEqual(S.requestFileName, "lyrimuse-player-query-request.json", "契约: 请求文件名")
    expectEqual(S.replyFileName, "lyrimuse-player-query-reply.json", "契约: 应答文件名")
    let collectorShaped: [String: Any] = ["schema": 1, "id": "123-1", "kind": "browser_queue", "bundle_id": "com.apple.Safari",
                                          "platform": "youtubeMusic", "written_at_ms": nowMs]
    let decoded = (try? JSONSerialization.data(withJSONObject: collectorShaped))
        .flatMap { try? JSONDecoder().decode(S.Request.self, from: $0) }
    expectEqual(decoded, request("browser_queue", bundle: "com.apple.Safari", platform: "youtubeMusic", id: "123-1"),
                "契约: 按 collector 写的键名解得开请求")
    let reply = S.Reply(schema: 1, id: "123-1", ok: true, output: "NOTFOUND", error: nil, writtenAtMs: nowMs)
    let replyKeys = (try? JSONEncoder().encode(reply))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        .map { Set($0.keys) } ?? []
    expectEqual(replyKeys.isSuperset(of: ["schema", "id", "ok", "output", "written_at_ms"]), true,
                "契约: 应答的键名是 collector 认的那几个(实际 \(replyKeys.sorted()))")
}
