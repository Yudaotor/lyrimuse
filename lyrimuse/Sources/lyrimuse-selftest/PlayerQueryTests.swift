import Foundation
import JavaScriptCore
import LyrimuseCore

/// 引擎预解析要的播放器查询由 App 代跑(`PlayerQueryServer`):请求怎么判、几段固定脚本长什么样、输出怎么整理成
/// 结构(`PlayerQueryTracks` / `PlayerQueryShuffle` / `PlayerQueryRepeat`)、契约键名。整理好的 JSON 交给引擎,键名两边一起钉
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

    // ---- 判请求:只认十种,参数逐项校验;契约版本不认识、没有 id、过期的不答 ----
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
    expectEqual(S.decide(request("vox_repeat"), now: now), .run(.voxRepeat), "查询: VOX 循环档")
    expectEqual(S.decide(request("pine_queue"), now: now), .run(.pineQueue), "查询: Pine 播放列表")
    expectEqual(S.decide(request("playback_mode", bundle: PlaybackPlayer.qqMusic.bundleIdentifier), now: now),
                .run(.playbackMode(.qqMusic)), "查询: 某一家的播放模式")
    expectEqual(S.decide(request("reamp_queue"), now: now), .run(.reampQueue), "查询: reAMP 播放列表")
    expectEqual(S.decide(request("foobar_queue"), now: now), .run(.foobarQueue), "查询: foobar2000 播放列表")
    expectEqual(S.decide(request("swinsian_queue"), now: now), .run(.swinsianQueue), "查询: Swinsian 播放队列")
    for bad in [nil, "com.example.none", PlaybackPlayer.kugou.bundleIdentifier, PlaybackPlayer.auto.bundleIdentifier] {
        expectEqual(S.decide(request("playback_mode", bundle: bad), now: now), .fail("unsupported player"),
                    "查询: 播放模式只问认得、能读模式的播放器(\(bad ?? "nil"))")
    }
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
                "查询: 过期的请求不答(引擎早不等了)")
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
    expectEqual(S.voxRepeatScript.hasPrefix("if application " + quote + "VOX" + quote + " is running then")
                && S.voxRepeatScript.hasSuffix("return repeat state"), true, "VOX 循环档: 先判 running,不把它拉起来")

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
                       "output.flatMap(PlayerQueryRepeat.parseVox)", "Self.osascript(Self.voxRepeatScript, timeout: Self.shuffleTimeout)",
                       "PinePlaylist.queueReply().flatMap { Self.encodedReply($0) }",
                       "MusicPlaybackController.playbackMode(for: player).flatMap { Self.encodedReply(PlayerQueryMode(mode: $0.mode.rawValue)) }",
                       "ReampPlaylist.queueReply().flatMap { Self.encodedReply($0) }",
                       "FoobarPlaylist.queueReply().flatMap { Self.encodedReply($0) }",
                       "output.map(site.parse)", "KasetPlayerInfo.queueReply(fromScriptOutput:"] {
            expectEqual(server.contains(needle), true, "查询(契约): 输出整理成结构再交(\(needle))")
        }
        expectEqual(S.Kind.allCases.count, 13, "查询: 十三种,跟引擎的 appQuery 常量一一对应")
    }

    // ---- 盯配置目录:原子写(临时文件改名)触发回调;目录本身删掉报告失效(09 章决策 175)----
    do {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-dirwatch-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let watchQueue = DispatchQueue(label: "selftest.directory-watch")
        let changed = DispatchSemaphore(value: 0), gone = DispatchSemaphore(value: 0)
        let watcher = DirectoryChangeWatcher(directory: dir, queue: watchQueue,
                                             onChange: { changed.signal() }, onGone: { gone.signal() })
        expectEqual(watcher != nil, true, "盯目录: 目录打得开")
        try? Data("{}".utf8).write(to: dir.appendingPathComponent("request.json"), options: .atomic)
        expectEqual(changed.wait(timeout: .now() + 2) == .success, true, "盯目录: 原子写触发回调")
        try? FileManager.default.removeItem(at: dir)
        expectEqual(gone.wait(timeout: .now() + 2) == .success, true, "盯目录: 目录删掉报告失效")
        withExtendedLifetime(watcher) {}
        expectEqual(DirectoryChangeWatcher(directory: dir, queue: watchQueue, onChange: {}, onGone: {}) == nil, true,
                    "盯目录: 目录不存在时返回 nil(调用方退回轮询)")
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

    // ---- YouTube Music 队列 JS 在两种执行环境下都读得到(02 章决策 285)----
    // JavaScriptCore 里搭一个假页面:队列元素的 `data` 只在「主环境」里看得见;插进页面的 <script> 只有带对了 nonce、
    // 内容是 Trusted Types 包过的才在主环境里跑。Safari 那种主环境直接读、不插脚本;Chromium 那种隔离环境经注入读回来。
    do {
        let fakePage = #"""
        var mainWorld = false, pageVisibleAlways = false, appended = 0, rawRejected = 0, policyFails = false;
        var attrs = {};
        function Item(d, sel, counterpart) { this._d = d; this._sel = sel; this._cp = counterpart; }
        Object.defineProperty(Item.prototype, 'data', { get: function() { return (pageVisibleAlways || mainWorld) ? this._d : undefined; } });
        Item.prototype.closest = function(sel) { return (sel === '#counterpart-renderer' && this._cp) ? {} : null; };
        Item.prototype.hasAttribute = function(n) { return n === 'selected' && this._sel; };
        function runs(t) { return { runs: [{ text: t }] }; }
        function song(title, artist, album, len, id, sel, mv) {
            return { title: runs(title), lengthText: runs(len), videoId: id, selected: sel,
                     longBylineText: { runs: [{ text: artist }, { text: ' • ' },
                                              { text: album, navigationEndpoint: { browseEndpoint: { browseId: 'MPREb_' + id } } }] },
                     navigationEndpoint: { watchEndpoint: { watchEndpointMusicSupportedConfigs: { watchEndpointMusicConfig: { musicVideoType: mv } } } } };
        }
        var items = [new Item(song('Song A', 'Artist A', 'Album A', '3:30', 'idA', true, 'MUSIC_VIDEO_TYPE_ATV'), true, false),
                     new Item(song('Song A (video)', 'Artist A', 'Album A', '3:31', 'idA2', false, 'MUSIC_VIDEO_TYPE_OMV'), false, true),
                     new Item(song('Song B', 'Artist B', 'Album B', '4:05', 'idB', false, 'MUSIC_VIDEO_TYPE_OMV'), false, false)];
        function Script() { this.nonce = ''; this._text = null; }
        Object.defineProperty(Script.prototype, 'textContent', { set: function(v) {
            if (!v || v.trusted !== true) { rawRejected++; throw new TypeError('requires TrustedScript'); }
            this._text = v.text; } });
        Script.prototype.remove = function() {};
        var de = { setAttribute: function(k, v) { attrs[k] = String(v); },
                   getAttribute: function(k) { return Object.prototype.hasOwnProperty.call(attrs, k) ? attrs[k] : null; },
                   removeAttribute: function(k) { delete attrs[k]; } };
        var document = {
            documentElement: de,
            head: { appendChild: function(s) {
                appended++;
                if (s.nonce !== 'page-nonce' || s._text === null) return;
                mainWorld = true;
                try { (0, eval)(s._text); } finally { mainWorld = false; }
            } },
            querySelectorAll: function(sel) { return sel === 'ytmusic-player-queue-item' ? items : []; },
            querySelector: function(sel) { return sel === 'script[nonce]' ? { nonce: 'page-nonce' } : null; },
            createElement: function() { return new Script(); }
        };
        var window = { trustedTypes: { createPolicy: function(name, rules) {
            if (policyFails) throw new TypeError('policy refused');
            return { createScript: function(x) { return { trusted: true, text: rules.createScript(x) }; } };
        } } };
        """#
        let want = [["1", "Song A", "Artist A", "Album A", "3:30", "idA", "MUSIC_VIDEO_TYPE_ATV"],
                    ["0", "Song B", "Artist B", "Album B", "4:05", "idB", "MUSIC_VIDEO_TYPE_OMV"]]
            .map { $0.joined(separator: "\u{1f}") }.joined(separator: "\u{1e}")
        func run(_ setup: String) -> (out: String, appended: Int32, rawRejected: Int32, attrsLeft: Int32) {
            guard let ctx = JSContext() else { return ("", -1, -1, -1) }
            ctx.evaluateScript(fakePage)
            ctx.evaluateScript(setup)
            let out = ctx.evaluateScript(S.youTubeMusicQueueJS)?.toString() ?? ""
            return (out, ctx.evaluateScript("appended")?.toInt32() ?? -1, ctx.evaluateScript("rawRejected")?.toInt32() ?? -1,
                    ctx.evaluateScript("Object.keys(attrs).length")?.toInt32() ?? -1)
        }
        let safari = run("pageVisibleAlways = true;")
        expectEqual(safari.out, want, "YouTube Music 队列 JS 主环境(Safari): 直接读 data,跳过替身")
        expectEqual(safari.appended, 0, "YouTube Music 队列 JS 主环境(Safari): 不往页面里插脚本")
        let chromium = run("")
        expectEqual(chromium.out, want, "YouTube Music 队列 JS 隔离环境(Chromium): 注入主环境读回同一份队列")
        expectEqual(chromium.appended, 1, "YouTube Music 队列 JS 隔离环境: 插一次脚本")
        expectEqual(chromium.rawRejected, 0, "YouTube Music 队列 JS 隔离环境: 脚本内容经 Trusted Types 策略包过")
        expectEqual(chromium.attrsLeft, 0, "YouTube Music 队列 JS 隔离环境: 带结果的属性读完删掉")
        let refused = run("policyFails = true;")
        expectEqual(refused.out, "NOTFOUND", "YouTube Music 队列 JS 隔离环境: 注入失败回 NOTFOUND")
        expectEqual(refused.attrsLeft, 0, "YouTube Music 队列 JS 隔离环境: 注入失败也不留属性")
        let empty = run("items = [];")
        expectEqual(empty.out, "NOTFOUND", "YouTube Music 队列 JS: 没有队列回 NOTFOUND")
        expectEqual(empty.appended, 0, "YouTube Music 队列 JS: 没有队列不插脚本")
        let wrapped = BrowserTabProbeScript.inPageWorld(core: "function(){ return 'x'; }", pageVisible: "false")
        expectEqual(wrapped.contains(quote) || wrapped.contains(backslash), false, "主环境包装: 不能有双引号或反斜杠")
    }

    // ---- 隔离环境里读不到的另几处(YouTube Music 视频身份 / 音量 / 随机,Spotify 网页版播放器状态 / 队列,02 章决策 286)----
    pageWorldReadTests()

    // ---- 输出整理成结构再交(PlayerQueryTracks / PlayerQueryShuffle):样例两侧共用,引擎只解 reply 那份 JSON ----
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

        // 键名:引擎按这些解(appquery.go 的 appQueryTrack / appQueryTracks)。
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
                    "Spotify 随机: 交给引擎的 JSON")

        expectEqual(["0", "1\n", "2"].map { PlayerQueryRepeat.parseVox($0)?.repeating }, ["off", "one", "all"],
                    "VOX 循环档: repeat state 0 / 1 / 2 → off / one / all")
        expectEqual(["", "3", "x"].map { PlayerQueryRepeat.parseVox($0) }, [nil, nil, nil],
                    "VOX 循环档: 没在跑(空输出)、认不出的值问不到")
        expectEqual(S.encodedReply(PlayerQueryRepeat(repeating: "all")), "{" + quote + "repeating" + quote + ":" + quote + "all" + quote + "}",
                    "VOX 循环档: 交给引擎的 JSON")
        expectEqual(S.encodedReply(PlayerQueryMode(mode: "repeatOne")), "{" + quote + "mode" + quote + ":" + quote + "repeatOne" + quote + "}",
                    "播放模式: 交给引擎的 JSON")
        // reAMP 播放列表:上次退出时存的 m3u,每个文件按认当前这首那一套换身份。
        typealias R = ReampPlaylist
        let m3u = ["#EXTM3U", "#EXTINF:60,Lyrimuse Test - Bilingual Lines", "/Users/x/Music/a.mp3", "", "  /Users/x/Music/b c.flac  ",
                   "file:///Users/x/Music/%E6%AD%8C.mp3", "http://radio.example/stream", "# 注释"].joined(separator: "\n")
        expectEqual(R.paths(m3u: m3u), ["/Users/x/Music/a.mp3", "/Users/x/Music/b c.flac", "/Users/x/Music/歌.mp3"],
                    "reAMP 列表: 绝对路径和 file:// 地址,注释、空行、网络地址跳过")
        expectEqual(R.paths(m3u: Array(repeating: "/a.mp3", count: R.maxTracks + 5).joined(separator: "\n")).count, R.maxTracks,
                    "reAMP 列表: 最多读 maxTracks 首")
        let tagged = LocalAudioFileTags(title: "稻香", artist: "周杰伦", album: "魔杰座", duration: 223.5)
        expectEqual(R.track(path: "/m/x.mp3", tags: tagged),
                    PinePlaylist.Track(title: "稻香", artist: "周杰伦", album: "魔杰座", duration: 223.5, file: "/m/x.mp3"),
                    "reAMP 列表: 有标签用标签,带精确时长和完整路径")
        let untagged = R.track(path: "/m/AJR - Karma.mp3", tags: LocalAudioFileTags(title: "", artist: "", album: "", duration: 200))
        expectEqual([untagged.artist, untagged.title, untagged.file], ["AJR", "Karma", "/m/AJR - Karma.mp3"],
                    "reAMP 列表: 没写歌名的按文件名拆(同 reAMP 报文件名时的拆法)")
        expectEqual(R.track(path: "/m/track08.mp3", tags: nil).title, "track08", "reAMP 列表: 读不出标签、拆不出歌手时歌名是去掉扩展名的文件名")
        expectEqual([.shuffle, .repeatAll, .list, .repeatOne, nil].map(R.repeating), ["shuffle", "all", "off", nil, nil],
                    "reAMP 列表: 菜单的档换成 shuffle / all / off")
        expectEqual(MusicPlaybackController.MusicPlaybackMode.allCases.map(\.rawValue), ["list", "shuffle", "repeatOne", "repeatAll"],
                    "播放模式: 原值就是交给引擎的写法(引擎 playerModeValues 一起改)")
    }

    // ---- 契约:文件名与 JSON 键名跟引擎的 json tag 一致 ----
    expectEqual(S.requestFileName, "lyrimuse-player-query-request.json", "契约: 请求文件名")
    expectEqual(S.replyFileName, "lyrimuse-player-query-reply.json", "契约: 应答文件名")
    let engineShaped: [String: Any] = ["schema": S.schema, "id": "123-1", "kind": "browser_queue", "bundle_id": "com.apple.Safari",
                                          "platform": "youtubeMusic", "written_at_ms": nowMs]
    let decoded = (try? JSONSerialization.data(withJSONObject: engineShaped))
        .flatMap { try? JSONDecoder().decode(S.Request.self, from: $0) }
    expectEqual(decoded, request("browser_queue", bundle: "com.apple.Safari", platform: "youtubeMusic", id: "123-1"),
                "契约: 按引擎写的键名解得开请求")
    let reply = S.Reply(schema: 1, id: "123-1", ok: true, output: "NOTFOUND", error: nil, writtenAtMs: nowMs)
    let replyKeys = (try? JSONEncoder().encode(reply))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        .map { Set($0.keys) } ?? []
    expectEqual(replyKeys.isSuperset(of: ["schema", "id", "ok", "output", "written_at_ms"]), true,
                "契约: 应答的键名是引擎认的那几个(实际 \(replyKeys.sorted()))")
}
