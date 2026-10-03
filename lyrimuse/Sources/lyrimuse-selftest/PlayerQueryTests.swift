import Foundation
import LyrimuseCore

/// collector 预解析要的播放器查询由 App 代跑(`PlayerQueryServer`):请求怎么判、几段固定脚本长什么样、输出怎么整理成
/// 结构(`PlayerQueryTracks` / `PlayerQueryShuffle`)、契约键名。整理好的 JSON 交给 collector,键名两边一起钉
/// (样例 shared/testdata/player-query/,Go 侧 appquery_test.go 读源码对账)。
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
    expectEqual(S.decide(request("kaset_queue"), now: now), .run(.kasetQueue), "查询: Kaset 待播队列")
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

    // ---- 每种查询的输出都先整理成结构再交;系统待播队列问的是 Music.app(源码契约)----
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
                    "系统待播队列(契约): 加载器带 queue=N,输出交回给 PlayerQueryTracks 整理")
        for needle in ["output.map(PlayerQueryTracks.appleMusicSystemQueue)", "output.map(PlayerQueryTracks.appleMusicUpcoming)",
                       "output.map(PlayerQueryTracks.appleMusicAlbumTracks)", "output.flatMap(PlayerQueryShuffle.parse)",
                       "output.map(site.parse)", "KasetPlayerInfo.queueReply(fromScriptOutput:"] {
            expectEqual(server.contains(needle), true, "查询(契约): 输出整理成结构再交(\(needle))")
        }
        expectEqual(S.Kind.allCases.count, 6, "查询: 六种,跟 collector 的 appQuery 常量一一对应")
    }

    // ---- 网页队列 JS:能嵌进 AppleScript,输出形状跟 PlayerQueryTracks 的解析对得上 ----
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

    // ---- 输出整理成结构再交(PlayerQueryTracks / PlayerQueryShuffle):样例两侧共用,collector 只解 reply 那份 JSON ----
    do {
        typealias T = PlayerQueryTracks
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/testdata/player-query")
        func sample(_ name: String) -> [String: Any] {
            (try? Data(contentsOf: dir.appendingPathComponent(name + ".json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        func records(_ sample: [String: Any]) -> String {
            ((sample["records"] as? [[String]]) ?? []).map { $0.joined(separator: "\u{1f}") }.joined(separator: "\u{1e}") + "\n"
        }
        func loaderOutput(_ sample: [String: Any]) -> String {
            sample["loader_output"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        let parsers: [(String, ([String: Any]) -> T)] = [
            ("apple-music-queue", { T.appleMusicSystemQueue(loaderOutput($0)) }),
            ("apple-music-upcoming", { T.appleMusicUpcoming(($0["script_output"] as? String) ?? "") }),
            ("apple-music-album-tracks", { T.appleMusicAlbumTracks(($0["script_output"] as? String) ?? "") }),
            ("youtube-music-queue", { T.youTubeMusicQueue(records($0)) }),
            ("spotify-web-queue", { T.spotifyWebQueue(records($0)) }),
        ]
        for (name, parse) in parsers {
            let s = sample(name)
            let want = s["reply"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(T.self, from: $0) }
            let got = parse(s)
            expectEqual(want != nil && got == want, true, "整理输出(\(name)): 跟共用样例的 reply 一致")
            let roundTrip = S.encodedReply(got).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
            expectEqual(roundTrip == got, true, "整理输出(\(name)): 编码后再解回来不变")
        }
        let ytRaw = records(sample("youtube-music-queue"))
        expectEqual(S.browserQueueSite(platformID: "youtubeMusic")?.parse(ytRaw) == T.youTubeMusicQueue(ytRaw), true,
                    "整理输出: YouTube Music 平台配的是它自己的解析")
        let spRaw = records(sample("spotify-web-queue"))
        expectEqual(S.browserQueueSite(platformID: "spotifyWeb")?.parse(spRaw) == T.spotifyWebQueue(spRaw), true,
                    "整理输出: Spotify 网页版平台配的是它自己的解析")

        // 键名:collector 按这些解(appquery.go 的 appQueryTrack / appQueryTracks)。
        let full = T(current: T.Track(title: "a", artist: "b", album: "c", duration: 1, selected: true, videoID: "v",
                                      musicVideo: true, uri: "u"))
        let keys = S.encodedReply(full).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        expectEqual((keys?["current"] as? [String: Any]).map { Set($0.keys) } ?? [],
                    ["title", "artist", "album", "duration", "selected", "video_id", "music_video", "uri"], "整理输出: 曲目的键名")
        expectEqual(keys.map { Set($0.keys) } ?? [], ["current", "tracks"], "整理输出: 外层的键名")

        // 守卫拦下 / 没在跑 / 读不到:交一份空的,不算失败(脚本照常跑完了)。
        for empty in ["", "\n", "   \n"] {
            expectEqual(T.appleMusicUpcoming(empty), T(), "Music 待播: 空输出(守卫拦下)交空的")
        }
        expectEqual(T.appleMusicSystemQueue("null\n"), T(), "系统待播队列: 加载器报 null 交空的")
        expectEqual(T.appleMusicSystemQueue("not json"), T(), "系统待播队列: 不是 JSON 交空的")
        expectEqual(T.appleMusicAlbumTracks(""), T(), "专辑曲目: Music.app 没在跑交空表")
        expectEqual(T.youTubeMusicQueue("NOTFOUND"), T(), "YouTube Music 队列: 没有这个网站的标签页")
        expectEqual(T.spotifyWebQueue("NOTFOUND"), T(), "Spotify 网页版队列: 找不到播放器接口")
        expectEqual(T.spotifyWebQueue("只有两段\u{1f}x"), T(), "Spotify 网页版队列: 当前这首解不开就整份不信")

        // MV 跟歌词窗口用同一个判定(MusicVideoTimeline.isMusicVideoType):官方 MV、用户上传算,歌曲版、读不到不算。
        let mv = T.youTubeMusicQueue(["0", "A", "x", "", "3:00", "v", "MUSIC_VIDEO_TYPE_OMV"].joined(separator: "\u{1f}")
                                     + "\u{1e}" + ["0", "B", "x", "", "3:00", "w", "MUSIC_VIDEO_TYPE_ATV"].joined(separator: "\u{1f}"))
        expectEqual(mv.tracks.map(\.musicVideo), [true, nil], "YouTube Music 队列: MV 按 isMusicVideoType 认")

        // 浏览器输出的外层引号:Chromium 系整段包一层、里面的双引号转义过,剥掉并还原;Safari 原样,以引号开头的歌名不削。
        let wrapped = quote + ["I Knew It - From " + backslash + quote + "Toy Story 5" + backslash + quote, "Taylor Swift", "x",
                               "1000", "u"].joined(separator: "\u{1f}") + quote
        expectEqual(T.spotifyWebQueue(wrapped).current?.title, "I Knew It - From " + quote + "Toy Story 5" + quote,
                    "浏览器输出: 包了一层的剥掉并还原")
        let heroes = [quote + "Heroes" + quote, "David Bowie", quote + "Heroes" + quote, "371000", "u"]
            .joined(separator: "\u{1f}") + newline
        expectEqual(T.spotifyWebQueue(heroes).current?.title, quote + "Heroes" + quote, "浏览器输出: 以引号开头的歌名不削")

        // AppleScript 实数文本跟随系统地区:德 / 法 / 俄等地区下小数点是逗号,≥10000 还会变科学计数
        // (osascript -AppleLocale de_DE 实测的形状)。
        for (text, want) in [("243.826", 243.826), ("243,826", 243.826), ("3,25\n", 3.25), ("25,0", 25.0),
                             ("1,23455E+4", 12345.5), ("1.23455E+4", 12345.5), ("208", 208.0)] {
            expectEqual(T.appleScriptReal(text), want, "AppleScript 实数: \(text)")
        }
        for bad in ["", "x", "missing value"] {
            expectEqual(T.appleScriptReal(bad), nil, "AppleScript 实数: \(bad) 解不出")
        }

        expectEqual(PlayerQueryShuffle.parse("true\n"), PlayerQueryShuffle(shuffling: true), "Spotify 随机: 开着")
        expectEqual(PlayerQueryShuffle.parse("false"), PlayerQueryShuffle(shuffling: false), "Spotify 随机: 关着")
        expectEqual(PlayerQueryShuffle.parse(""), nil, "Spotify 随机: 没在跑(空输出)问不到")
        expectEqual(S.encodedReply(PlayerQueryShuffle(shuffling: true)), "{" + quote + "shuffling" + quote + ":true}",
                    "Spotify 随机: 交给 collector 的 JSON")
    }

    // ---- 契约:文件名与 JSON 键名跟 collector 的 json tag 一致 ----
    expectEqual(S.requestFileName, "lyrimuse-player-query-request.json", "契约: 请求文件名")
    expectEqual(S.replyFileName, "lyrimuse-player-query-reply.json", "契约: 应答文件名")
    let collectorShaped: [String: Any] = ["schema": S.schema, "id": "123-1", "kind": "browser_queue", "bundle_id": "com.apple.Safari",
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
