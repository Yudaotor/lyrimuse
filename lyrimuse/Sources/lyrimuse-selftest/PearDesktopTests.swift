import Foundation
import LyrimuseCore

/// Pear Desktop 的本机接口:配置文件怎么读、歌曲应答怎么解、跟系统会话那一首怎么对、队列怎么整理成 Kaset 那种回包、
/// MV / 播客怎么认,以及几处接线契约。样本形状照它 v3.12.0 的接口应答(`/api/v1/song`、`/api/v1/queue`)。
@MainActor
func runPearDesktopTests() {
    typealias API = PearDesktopAPI
    func data(_ s: String) -> Data { Data(s.utf8) }

    // ---- 配置 ----
    do {
        expectEqual(API.config(in: data(#"{"options":{"tray":false}}"#)), nil, "Pear 配置: 没开过插件时没有 api-server 那一段")
        let off = API.config(in: data(#"{"plugins":{"api-server":{"enabled":false,"port":26538}}}"#))
        expectEqual(off?.enabled, false, "Pear 配置: 关着")
        let on = API.config(in: data(#"{"plugins":{"api-server":{"enabled":true,"hostname":"0.0.0.0","port":"27000","authStrategy":"AUTH_AT_FIRST"}}}"#))
        expectEqual(on?.enabled == true && on?.port == 27000 && on?.needsToken == true, true, "Pear 配置: 端口也认字符串,首次请求时授权要令牌")
        expectEqual(on?.connectHost, "127.0.0.1", "Pear 配置: 监听所有网卡时连本机")
        expectEqual(on?.lanReachableWithoutToken, false, "Pear 配置: 要授权时不算局域网裸奔")
        let open = API.config(in: data(#"{"plugins":{"api-server":{"enabled":true,"hostname":"0.0.0.0","port":99999,"authStrategy":"NONE"}}}"#))
        expectEqual(open?.port == API.defaultPort && open?.needsToken == false && open?.lanReachableWithoutToken == true, true,
                    "Pear 配置: 端口越界退回默认;无需授权又监听所有网卡时提示局域网能控制")
        let local = API.config(in: data(#"{"plugins":{"api-server":{"enabled":true,"hostname":"127.0.0.1","authStrategy":"NONE"}}}"#))
        expectEqual(local?.lanReachableWithoutToken, false, "Pear 配置: 只监听本机时不提示")
        let lan = API.config(in: data(#"{"plugins":{"api-server":{"enabled":true,"hostname":"192.168.1.5"}}}"#))
        expectEqual(lan?.connectHost, "192.168.1.5", "Pear 配置: 只监听某个地址时连那个地址")
    }

    // ---- 歌曲应答 ----
    let songJSON = #"{"title":"青花瓷","alternativeTitle":"青花瓷","artist":"周杰倫","views":30871123,"imageSrc":"https://lh3.googleusercontent.com/x","isPaused":false,"songDuration":239,"elapsedSeconds":10,"url":"https://music.youtube.com/watch?v=Q8Tiz6INF7I","album":"我很忙","videoId":"Q8Tiz6INF7I","playlistId":"RDAMVMQ8Tiz6INF7I","mediaType":"AUDIO"}"#
    let song = API.song(from: data(songJSON))
    do {
        expectEqual(song?.videoID == "Q8Tiz6INF7I" && song?.album == "我很忙" && song?.duration == 239 && song?.isPaused == false, true,
                    "Pear 歌曲: videoId、专辑、时长、暂停")
        expectEqual(song?.isMusicVideo, false, "Pear 歌曲: AUDIO 明说是歌曲版")
        expectEqual(API.song(from: data(#"{"title":"x","videoId":"short"}"#)), nil, "Pear 歌曲: videoId 形状不对不收")
        expectEqual(API.song(from: nil), nil, "Pear 歌曲: 没有歌(204)")
        let mv = API.song(from: data(#"{"title":"晴天","artist":"周杰伦","album":null,"videoId":"DYptgVvkVLQ","mediaType":"ORIGINAL_MUSIC_VIDEO","songDuration":318}"#))
        expectEqual(mv?.isMusicVideo == true && mv?.album == nil, true, "Pear 歌曲: 官方 MV 是视频版,专辑 null 为 nil")
        expectEqual(API.song(from: data(#"{"title":"x","artist":"y","videoId":"DYptgVvkVLQ","mediaType":"USER_GENERATED_CONTENT"}"#))?.isMusicVideo,
                    true, "Pear 歌曲: 用户上传也是视频版")
        expectEqual(API.song(from: data(#"{"title":"x","artist":"y","videoId":"DYptgVvkVLQ","mediaType":"OTHER_VIDEO"}"#))?.isMusicVideo,
                    nil, "Pear 歌曲: 认不出类型的说不上来")
        let podcast = API.song(from: data(#"{"title":"Tell Me Lies | Official Podcast Episode 1 | Hulu","artist":"Hulu","videoId":"BPmPO4MDR0c","mediaType":"PODCAST_EPISODE","songDuration":2475}"#))
        expectEqual(podcast?.isPodcastEpisode, true, "Pear 歌曲: 播客单集")
    }

    // ---- 循环档与音量 ----
    do {
        typealias Mode = MusicPlaybackController.MusicPlaybackMode
        expectEqual([API.playbackMode(shuffle: false, repeatMode: "NONE"), API.playbackMode(shuffle: false, repeatMode: "ALL"),
                     API.playbackMode(shuffle: false, repeatMode: "ONE"), API.playbackMode(shuffle: true, repeatMode: "NONE")],
                    [Mode.list, .repeatAll, .repeatOne, .shuffle], "Pear 模式: 随机开关加循环档换成播放模式")
        expectEqual(API.playbackMode(shuffle: true, repeatMode: "ALL"), .shuffle, "Pear 模式: 随机和列表循环都开着时显示随机(同 Kaset)")
        expectEqual(API.playbackMode(shuffle: true, repeatMode: "ONE"), .repeatOne, "Pear 模式: 单曲循环优先")
        expectEqual(API.playbackMode(shuffle: nil, repeatMode: "NONE"), nil, "Pear 模式: 随机读不到为 nil")
        expectEqual(API.playbackMode(shuffle: false, repeatMode: nil), nil, "Pear 模式: 循环读不到为 nil")
        expectEqual(API.modeOptions, .all, "Pear 模式: 随机、列表循环、单曲循环都有(随机是能保持的开关,实测读回)")
        typealias Plan = API.ModePlan
        // 实测它按一下循环键:关 → 列表循环 → 单曲循环 → 关;`POST /shuffle` 是切换。
        expectEqual(API.modePlan(shuffle: false, repeatMode: "NONE", to: .repeatOne),
                    Plan(toggleShuffle: false, repeatPresses: 2, shuffle: false, repeatMode: "ONE"), "Pear 模式: 关到单曲循环按两下")
        expectEqual(API.modePlan(shuffle: false, repeatMode: "ONE", to: .repeatAll),
                    Plan(toggleShuffle: false, repeatPresses: 2, shuffle: false, repeatMode: "ALL"), "Pear 模式: 单曲到列表循环绕一圈按两下")
        expectEqual(API.modePlan(shuffle: false, repeatMode: "ALL", to: .repeatAll),
                    Plan(toggleShuffle: false, repeatPresses: 0, shuffle: false, repeatMode: "ALL"), "Pear 模式: 已经是这一档不按")
        expectEqual(API.modePlan(shuffle: false, repeatMode: "NONE", to: .shuffle),
                    Plan(toggleShuffle: true, repeatPresses: 0, shuffle: true, repeatMode: "NONE"), "Pear 模式: 开随机按一下随机键")
        expectEqual(API.modePlan(shuffle: false, repeatMode: "ONE", to: .shuffle),
                    Plan(toggleShuffle: true, repeatPresses: 1, shuffle: true, repeatMode: "NONE"), "Pear 模式: 开随机时关掉单曲循环")
        expectEqual(API.modePlan(shuffle: true, repeatMode: "ALL", to: .list),
                    Plan(toggleShuffle: true, repeatPresses: 0, shuffle: false, repeatMode: "ALL"), "Pear 模式: 关随机时列表循环留着(同 Kaset)")
        expectEqual(API.modePlan(shuffle: true, repeatMode: "NONE", to: .repeatOne),
                    Plan(toggleShuffle: true, repeatPresses: 2, shuffle: false, repeatMode: "ONE"), "Pear 模式: 开循环时关掉随机(互斥)")
        expectEqual(API.modePlan(shuffle: nil, repeatMode: "NONE", to: .shuffle), nil, "Pear 模式: 读不到随机不动")
        expectEqual(API.modePlan(shuffle: false, repeatMode: nil, to: .repeatAll), nil, "Pear 模式: 读不到循环不动")
        // 实测(写滑块 → 读回):10→2、30→8、50→20、55→24、80→55、90→74、100→100。
        let measured: [(slider: Int, read: Double)] = [(10, 2), (30, 8), (50, 20), (55, 24), (80, 55), (90, 74), (100, 100)]
        expectEqual(measured.allSatisfy { abs(API.sliderVolume(fromPlayerVolume: $0.read, muted: false) - $0.slider) <= 2 }, true,
                    "Pear 音量: 读数反算回滑块位置,跟实测写进去的差不过 2")
        expectEqual(API.sliderVolume(fromPlayerVolume: 40, muted: true), 0, "Pear 音量: 静音算 0")
        expectEqual(API.sliderVolume(fromPlayerVolume: 0, muted: false), 0, "Pear 音量: 0 还是 0")
        expectEqual(MusicPlaybackController.supportsExtendedControls(.pearDesktop) && MusicPlaybackController.supportsRepeatOne(.pearDesktop)
                    && MusicPlaybackController.supportsFavorite(.pearDesktop), true,
                    "Pear 控制: 有循环(含单曲)、音量和喜欢(赞是切换,能取消,实测)")
        expectEqual(PlaybackPlayer.pearDesktop.artistArrivesLate, true, "Pear: 换歌占位那一帧歌手为空,不采纳")
    }

    // ---- 广告 ----
    do {
        let next = API.Song(title: "青花瓷", artist: "周杰倫", album: "我很忙", videoID: "DxpndDEAqGk", mediaType: "AUDIO", duration: 239,
                            isPaused: false, elapsed: 0)
        func ad(_ title: String, everMatched: Bool = false, song: API.Song = next) -> Bool {
            API.looksLikeAd(systemTitle: title, systemArtist: "Google", systemDuration: 15.041, apiSong: song, everMatched: everMatched)
        }
        expectEqual(ad("Google AI Pro: Wrangle The Sunday Scaries"), true, "Pear 广告: 接口报接下来那首、系统会话报另一段(实测样本)")
        expectEqual(ad("青花瓷"), false, "Pear 广告: 就是接口那首不算")
        expectEqual(ad("稻香", everMatched: true), false, "Pear 广告: 换歌那一下系统还停在对上过的上一首,不算")
        // 暂停着的广告:接口那首报暂停、进度跟着广告走(实测 121 秒的广告停在 104 秒)。
        let paused = API.Song(title: "青花瓷", artist: "周杰倫", album: nil, videoID: "DxpndDEAqGk", mediaType: "AUDIO", duration: 239,
                              isPaused: true, elapsed: 104)
        expectEqual(ad("Love is a Gift—A Tiffany & Co. Holiday with Amanda Seyfried", song: paused), true,
                    "Pear 广告: 暂停着、进度跟着广告走的也算(实测样本)")
        expectEqual(API.adSettleSecs >= 1, true, "Pear 广告: 要连着像一阵才认,接口慢半拍时新歌不会被标成广告")
        expectEqual(API.song(from: data(#"{"title":"青花瓷","videoId":"DxpndDEAqGk","elapsedSeconds":3}"#))?.elapsed, 3, "Pear 歌曲: 读进度")
    }

    // ---- 跟系统会话那一首对不对得上 ----
    if let song {
        expectEqual(API.describes(song, title: " 青花瓷 ", artist: "周杰倫", duration: 239.4), true, "Pear 对曲: 歌名一样(去空白)")
        expectEqual(API.describes(song, title: "青花瓷 (Live)", artist: "周杰倫", duration: 240.5), true, "Pear 对曲: 歌名写法不同时歌手一样、时长差 2 秒内")
        expectEqual(API.describes(song, title: "青花瓷 (Live)", artist: "周杰倫", duration: 245), false, "Pear 对曲: 时长差远了不认")
        expectEqual(API.describes(song, title: "稻香", artist: "周杰倫", duration: nil), false, "Pear 对曲: 换了一首(接口还停在上一首)")
    }

    // ---- 队列 ----
    do {
        func byline(_ parts: [(String, String?)]) -> String {
            let runs = parts.map { text, page -> String in
                guard let page else { return #"{"text":"\#(text)"}"# }
                return #"{"text":"\#(text)","navigationEndpoint":{"browseEndpoint":{"browseId":"x","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"\#(page)"}}}}}"#
            }
            return #"{"runs":[\#(runs.joined(separator: ","))]}"#
        }
        func renderer(_ title: String, _ id: String, _ type: String, length: String, byline b: String, selected: Bool = false) -> String {
            #"{"title":{"runs":[{"text":"\#(title)"}]},"longBylineText":\#(b),"lengthText":{"runs":[{"text":"\#(length)"}]},"selected":\#(selected),"videoId":"\#(id)","navigationEndpoint":{"watchEndpoint":{"videoId":"\#(id)","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"\#(type)"}}}}}"#
        }
        let songByline = byline([("周杰倫", "MUSIC_PAGE_TYPE_ARTIST"), (" • ", nil), ("我很忙", "MUSIC_PAGE_TYPE_ALBUM"), (" • ", nil), ("2007", nil)])
        let duetByline = byline([("A", "MUSIC_PAGE_TYPE_ARTIST"), (" & ", nil), ("B", "MUSIC_PAGE_TYPE_ARTIST"), (" • ", nil), ("Album X", "MUSIC_PAGE_TYPE_ALBUM")])
        let mvByline = byline([("周杰伦", "MUSIC_PAGE_TYPE_ARTIST"), (" • ", nil), ("3000万次观看", nil)])
        let items = [
            #"{"playlistPanelVideoRenderer":\#(renderer("晴天", "DYptgVvkVLQ", "MUSIC_VIDEO_TYPE_OMV", length: "5:18", byline: mvByline))}"#,
            // 包在 wrapper 里、放的是歌曲版、带着视频版。
            #"{"playlistPanelVideoWrapperRenderer":{"primaryRenderer":{"playlistPanelVideoRenderer":\#(renderer("青花瓷", "Q8Tiz6INF7I", "MUSIC_VIDEO_TYPE_ATV", length: "3:59", byline: songByline, selected: true))},"counterpart":[{"counterpartRenderer":{"playlistPanelVideoRenderer":\#(renderer("青花瓷", "Z8Tiz6INF7Z", "MUSIC_VIDEO_TYPE_OMV", length: "4:10", byline: mvByline))}}]}}"#,
            // 包在 wrapper 里、放的是视频版、配对的是歌曲版。
            #"{"playlistPanelVideoWrapperRenderer":{"primaryRenderer":{"playlistPanelVideoRenderer":\#(renderer("Duet", "MVMVMVMVMV1", "MUSIC_VIDEO_TYPE_OMV", length: "1:02:03", byline: duetByline))},"counterpart":[{"counterpartRenderer":{"playlistPanelVideoRenderer":\#(renderer("Duet", "AUAUAUAUAU1", "MUSIC_VIDEO_TYPE_ATV", length: "3:00", byline: duetByline))}}]}}"#,
            #"{"automixPreviewVideoRenderer":{}}"#,
        ]
        let queue = data(#"{"items":[\#(items.joined(separator: ","))],"autoPlaying":false}"#)
        let reply = API.queueReply(queueJSON: queue, repeatMode: "ALL")
        expectEqual(reply?.currentIndex, 1, "Pear 队列: 当前这首是 selected 那一格")
        expectEqual(reply?.repeating, "all", "Pear 队列: 循环模式换成 Kaset 的写法")
        expectEqual(reply?.tracks.count, 4, "Pear 队列: 认不出的格子也占位,下标才对得上")
        expectEqual(reply?.tracks.first.map { [$0.title, $0.artist, $0.videoID ?? "", $0.audioVideoID ?? "", $0.album ?? "-"] },
                    ["晴天", "周杰伦", "DYptgVvkVLQ", "DYptgVvkVLQ", "-"], "Pear 队列: MV 没有专辑、没有配对时歌曲版就是自己")
        expectEqual(reply?.tracks[1].album, "我很忙", "Pear 队列: 专辑取跳到专辑页的那一段")
        expectEqual(reply?.tracks[1].duration, 239, "Pear 队列: 「3:59」换成秒")
        expectEqual(reply?.tracks[2].artist, "A & B", "Pear 队列: 歌手取第一个「 • 」之前的各段")
        expectEqual(reply?.tracks[2].audioVideoID, "AUAUAUAUAU1", "Pear 队列: 放视频版时歌曲版取配对那一个")
        expectEqual(reply?.tracks[2].duration, 3723, "Pear 队列: 「1:02:03」换成秒")
        expectEqual(reply?.tracks[3].title, "", "Pear 队列: 认不出的格子歌名为空")
        expectEqual(API.queueReply(queueJSON: data(#"{"items":[]}"#), repeatMode: nil), nil, "Pear 队列: 空队列不交")
        expectEqual(API.queueReply(queueJSON: queue, repeatMode: nil)?.repeating, "off", "Pear 队列: 读不到循环模式按不循环")
        expectEqual(API.queueReply(queueJSON: queue, repeatMode: "ONE")?.repeating, "one", "Pear 队列: 单曲循环")
        let encoded = reply.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expectEqual(encoded.contains(#""album":"我很忙""#) && encoded.contains(#""audio_video_id":"AUAUAUAUAU1""#), true,
                    "Pear 队列: 回包键名跟引擎 kasetQueueReply 一致(album、audio_video_id)")
    }

    // ---- MV 标记 ----
    do {
        func snap(_ bundleID: String, mv: Bool?) -> MediaControlSnapshot {
            let mark = mv.map { #","isMusicVideo":\#($0)"# } ?? ""
            return try! JSONDecoder().decode(MediaControlSnapshot.self, from: data(
                #"{"title":"青花瓷","artist":"周杰倫","album":"我很忙","bundleIdentifier":"\#(bundleID)"\#(mark)}"#))
        }
        let pear = PlaybackPlayer.pearDesktop.bundleIdentifier
        expectEqual(LocalPlaybackSource.snapshotSaysNotMusicVideo(snap(pear, mv: false)), true, "Pear MV: 接口说歌曲版,同一首从视频版切回时作废 MV")
        expectEqual(LocalPlaybackSource.snapshotSaysNotMusicVideo(snap(pear, mv: nil)), false, "Pear MV: 说不上来时不作废")
        expectEqual(LocalPlaybackSource.snapshotSaysNotMusicVideo(snap(PlaybackPlayer.appleMusic.bundleIdentifier, mv: false)), false,
                    "Pear MV: 别家照旧不认 false")
    }

    // ---- 接线契约 ----
    do {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LyrimuseCore/Local")
        func src(_ name: String) -> String { (try? String(contentsOf: core.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        let client = src("MediaControlClient.swift")
        expectEqual(sourceHas(sourceBody("private static func adaptedSnapshot(", in: client),
                              "if bundleID == PlaybackPlayer.pearDesktop.bundleIdentifier { return pearDesktopReading(mediaControl) }"), true,
                    "Pear 接线: 系统会话报 Pear 时按接口补(adaptedSnapshot)")
        expectEqual(sourceHas(sourceBody("private static func pearDesktopReading(", in: client),
                              "if song.isPodcastEpisode {\nsetSnapshotFailure(.targetNotPlayingMusic)\nreturn nil"), true,
                    "Pear 接线: 播客单集这一拍不报、不退回系统那份")
        let reading = sourceBody("private static func pearDesktopReading(", in: client)
        expectEqual(sourceHas(reading, "ad.isAd = true") && sourceHas(reading, "marked.isAd = false")
                    && sourceHas(reading, "case .undecided:\nsetSnapshotFailure(.targetNotPlayingMusic)\nreturn nil"), true,
                    "Pear 接线: 广告标广告、正片明说不是广告(广告态回落)、还没认准的压着不报")
        expectEqual(LocalPlaybackSource.adSharesTrackIdentity(bundleID: PlaybackPlayer.pearDesktop.bundleIdentifier), false,
                    "Pear 接线: 广告有自己的身份,播放状态如实写 ad(引擎不搜词、不记收听)")
        let source = src("LocalPlaybackSource.swift")
        expectEqual(sourceHas(source, "youtubeMusicVideoID: Self.youtubeMusicVideoID(bundleID: bundleID, trackKey: snapshot.trackKey),"), true,
                    "Pear 接线: 播放状态带上 Pear 的 videoId(引擎按它取歌词、拼链接)")
        expectEqual(sourceHas(source, "case PlaybackPlayer.pearDesktop.bundleIdentifier: return PearDesktopAPI.shared.videoID(forTrackKey: trackKey)"),
                    true, "Pear 接线: videoId 来自本机接口按曲目记下的那份")
        let server = src("PlayerQueryServer.swift")
        expectEqual(sourceHas(server, "case pearQueue = \"pear_queue\"") && sourceHas(server, "PearDesktopAPI.shared.queueReply().flatMap(Self.encodedQueueReply)"),
                    true, "Pear 接线: 引擎问队列由 App 经本机接口代读")
    }

    // ---- 赞 ----
    expectEqual([API.liked(fromState: "LIKE"), API.liked(fromState: "DISLIKE"), API.liked(fromState: "INDIFFERENT"), API.liked(fromState: nil)],
                [true, false, false, nil], "Pear 赞: 赞了才算喜欢,踩过算没赞,读不到为 nil")

    // ---- 在 Pear 中播放:搜歌、链接 ----
    do {
        // 照真机 `POST /api/v1/search` 应答缩下来的形状:热门结果是 MV(OMV),歌曲是音轨版(ATV),还有歌手、视频。
        func row(_ title: String, _ id: String?, _ type: String?) -> String {
            let vid = id.map { #","playlistItemData":{"videoId":"\#($0)"}"# } ?? ""
            let mvt = type.map { #","overlay":{"x":{"watchEndpoint":{"videoId":"\#(id ?? "")","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"\#($0)"}}}}}"# } ?? ""
            return #"{"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"\#(title)"}]}}}]\#(vid)\#(mvt)}}"#
        }
        let card = #"{"musicCardShelfRenderer":{"title":{"runs":[{"text":"晴天","navigationEndpoint":{"watchEndpoint":{"videoId":"DYptgVvkVLQ","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_OMV"}}}}}]}}}"#
        let rows = [card, row("周杰倫", nil, nil), row("晴天 (Live)", "LIVE0000000", "MUSIC_VIDEO_TYPE_ATV"),
                    row("晴天", "SJKoWAd5ySo", "MUSIC_VIDEO_TYPE_ATV"), row("晴天", "UGC00000000", "MUSIC_VIDEO_TYPE_UGC")]
        let search = data(#"{"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicShelfRenderer":{"contents":["# + rows.joined(separator: ",") + #"]}}]}}}}]}}}"#)
        expectEqual(API.songVideoID(inSearch: search, title: "晴天"), "SJKoWAd5ySo", "Pear 搜歌: 只认歌曲(音轨版),热门结果的 MV 和视频不拿,歌名完全一样的优先")
        expectEqual(API.songVideoID(inSearch: search, title: " 晴 天 "), "SJKoWAd5ySo", "Pear 搜歌: 歌名比较去空白")
        let liveOnly = data(#"{"contents":["# + row("晴天 (Live)", "LIVE0000000", "MUSIC_VIDEO_TYPE_ATV") + "]}")
        expectEqual(API.songVideoID(inSearch: liveOnly, title: "晴天"), "LIVE0000000", "Pear 搜歌: 没有完全一样的取以它开头的")
        expectEqual(API.songVideoID(inSearch: data(#"{"contents":["# + row("七里香", "QILIXIANG00", "MUSIC_VIDEO_TYPE_ATV") + "]}"),
                                    title: "晴天"), nil, "Pear 搜歌: 歌名对不上不拿")
        expectEqual(API.songVideoID(inSearch: data("not json"), title: "晴天"), nil, "Pear 搜歌: 读不懂为 nil")
        expectEqual(API.videoID(fromLink: URL(string: "kaset://play?v=SJKoWAd5ySo")), "SJKoWAd5ySo", "Pear 链接: Kaset 那种链接取 v")
        expectEqual(API.videoID(fromLink: URL(string: "https://music.youtube.com/watch?v=abc&list=x")), "abc", "Pear 链接: 网页链接取 v")
        expectEqual(API.videoID(fromLink: URL(string: "https://music.youtube.com/browse/x")), nil, "Pear 链接: 没有 v 为 nil")
    }

    // ---- 广告第几条 ----
    do {
        typealias Slot = YouTubeMusicAdProbe.AdSlot
        expectEqual(Slot(badgeText: "赞助商广告 2/2 · 2:29"), Slot(index: 2, total: 2), "Pear 广告计数: 去掉时长取两个数")
        expectEqual(Slot(badgeText: "Sponsored 1 of 2 ·"), Slot(index: 1, total: 2), "Pear 广告计数: 英文界面「1 of 2」")
        expectEqual(Slot(badgeText: "赞助商广告 · 0:15"), nil, "Pear 广告计数: 只有一条时没有计数")
        expectEqual(Slot(badgeText: "Ad 3/2"), nil, "Pear 广告计数: 序号大于总数不认")
    }

    // ---- 推送 ----
    do {
        typealias Push = PearDesktopPush
        expectEqual(Push.message(from: #"{"type":"PLAYER_STATE_CHANGED","isPlaying":true,"position":12.5}"#),
                    Push.Message(type: "PLAYER_STATE_CHANGED", isPlaying: true, position: 12.5), "Pear 推送: 解出类型、在不在放、进度")
        expectEqual(Push.message(from: "oops"), nil, "Pear 推送: 不是 JSON 为 nil")
        var t = Push.PositionTracker()
        let t0 = Date(timeIntervalSince1970: 1_000)
        func msg(_ type: String, playing: Bool? = nil, pos: Double? = nil) -> Push.Message { .init(type: type, isPlaying: playing, position: pos) }
        expectEqual(t.handle(msg("PLAYER_INFO", playing: true, pos: 10), at: t0), nil, "Pear 推送: 连上那份只记状态")
        expectEqual(t.handle(msg("POSITION_CHANGED", pos: 11), at: t0.addingTimeInterval(1)), nil, "Pear 推送: 每秒那条照常走不算拖")
        expectEqual(t.handle(msg("POSITION_CHANGED", pos: 12.4), at: t0.addingTimeInterval(2)), nil, "Pear 推送: 几百毫秒的抖动不算拖")
        expectEqual(t.handle(msg("POSITION_CHANGED", pos: 60), at: t0.addingTimeInterval(3)), .seeked, "Pear 推送: 进度跳了算拖")
        expectEqual(t.handle(msg("PLAYER_STATE_CHANGED", playing: false, pos: 60), at: t0.addingTimeInterval(4)),
                    .playState(playing: false), "Pear 推送: 暂停")
        expectEqual(t.handle(msg("POSITION_CHANGED", pos: 60), at: t0.addingTimeInterval(9)), nil, "Pear 推送: 暂停时进度不走不算拖")
        expectEqual(t.handle(msg("POSITION_CHANGED", pos: 30), at: t0.addingTimeInterval(10)), .seeked, "Pear 推送: 暂停时往回拖算拖")
        expectEqual(t.handle(msg("VIDEO_CHANGED", pos: 0), at: t0.addingTimeInterval(11)), .trackChanged, "Pear 推送: 换歌")
        expectEqual(t.handle(msg("VOLUME_CHANGED"), at: t0.addingTimeInterval(12)), nil, "Pear 推送: 音量这类不发")
    }

    // ---- 推送、计数、点歌的接线 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ name: String) -> String { (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        let api = src("LyrimuseCore/Local/PearDesktopAPI.swift")
        expectEqual(sourceHas(sourceBody("public func noteAppRunning(", in: api), "PearDesktopPush.shared.keepAlive(url: running ? pushURL() : nil)"),
                    true, "Pear 接线: 每拍维持推送连接,Pear 没开时断开")
        let source = src("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(sourceHas(source, "PearDesktopPush.shared.setEventHandler { [weak self] event in\nguard !SourceKnockout.isOut(.pearPush) else { return }"),
                    true, "Pear 接线: 推送叫播放源补查,拔腿开关能关掉")
        expectEqual(sourceHas(source, "? PearDesktopAdSkip.adSlot()"), true, "Pear 接线: Pear 的广告计数取跳广告门槛读到的徽章")
        let menu = src("lyrimuse/LastfmStatsSection.swift")
        expectEqual(sourceHas(menu, "if let pear = Self.pearTarget(links: links, track: track) {")
                    && sourceHas(sourceBody("fileprivate static func appLinksHaveMenu(", in: menu), "if pearTarget(links: links, track: track) != nil { return true }"),
                    true, "Pear 接线: 榜单右键给「在 Pear Desktop 中播放 / 稍后播放」,有它时这一行能弹菜单")
        expectEqual(sourceHas(sourceBody("fileprivate static func pearTarget(", in: menu), "PearDesktopAPI.shared.canControl()"), true,
                    "Pear 接线: 只在它开着、接口能用时出")
    }

    // ---- 跳过广告 ----
    do {
        typealias Skip = PearDesktopAdSkip
        let pear = PlaybackPlayer.pearDesktop.bundleIdentifier
        expectEqual(Skip.isPear(pear) && !Skip.isPear(nil) && !Skip.isPear(PlaybackPlayer.kaset.bundleIdentifier), true,
                    "Pear 跳广告: 只认 Pear 的 bundle id")
        expectEqual(YouTubeMusicAdSkipper.isKnownNonBrowser(reportedBundleID: pear), false,
                    "Pear 跳广告: 门槛轮询不把 Pear 当成「没有跳过键的非浏览器」收手")
        expectEqual(YouTubeMusicAdSkipper.isKnownNonBrowser(reportedBundleID: PlaybackPlayer.spotify.bundleIdentifier), true,
                    "Pear 跳广告: Spotify 桌面版照旧收手")
        expectEqual(Skip.gateRetryDelay(after: nil), Skip.notReadyRetryDelay, "Pear 跳广告: 树还没建好时按短间隔再探")
        expectEqual(Skip.gateRetryDelay(after: .never), Skip.notReadyRetryDelay, "Pear 跳广告: 键没出现时按短间隔再探")
        expectEqual(Skip.gateRetryDelay(after: .ready), YouTubeMusicAdProbe.adRefreshInterval, "Pear 跳广告: 键出现后按心跳盯")
        expectEqual(Skip.notReadyRetryDelay < YouTubeMusicAdProbe.adRefreshInterval, true,
                    "Pear 跳广告: 没有倒计时可读,靠短间隔让键放出来之后很快出现")

        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LyrimuseCore/Local")
        let skipper = (try? String(contentsOf: core.appendingPathComponent("YouTubeMusicAdSkipper.swift"), encoding: .utf8)) ?? ""
        expectEqual(sourceHas(sourceBody("public static func skip(reportedBundleID: String?) -> Outcome? {", in: skipper),
                              "if PearDesktopAdSkip.isPear(reportedBundleID) { return PearDesktopAdSkip.skip() }"), true,
                    "Pear 跳广告: 跳过动作先分给 Pear(它不能注入 JS)")
        expectEqual(sourceHas(sourceBody("public static func probeSkippability(reportedBundleID: String?) -> Skippability? {", in: skipper),
                              "if PearDesktopAdSkip.isPear(reportedBundleID) { return PearDesktopAdSkip.probe() }"), true,
                    "Pear 跳广告: 门槛探测先分给 Pear")
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lyrimuse/UI")
        func uiSrc(_ name: String) -> String { (try? String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        expectEqual(sourceHas(uiSrc("NotchPlayback.swift"), "|| PearDesktopAdSkip.isPear(LocalPlaybackSource.shared.lastResolvedBundleID))"), true,
                    "Pear 跳广告: 灵动岛那颗键对 Pear 的广告也有对象")
        let center = uiSrc("YouTubeMusicAdSkipCenter.swift")
        expectEqual(sourceHas(center, "Task.detached(priority: .utility) { PearDesktopAdSkip.releaseTree() }")
                    && sourceHas(center, "? PearDesktopAdSkip.gateRetryDelay(after: state)"), true,
                    "Pear 跳广告: 广告态结束关回辅助功能树;门槛间隔按 Pear 那一档")
        expectEqual(sourceHas(center, "if Task.isCancelled, PearDesktopAdSkip.isPear(bundleID) {")
                    && sourceHas(center, "if stopped { PearDesktopAdSkip.releaseTree() }"), true,
                    "Pear 跳广告: 收摊时还在跑的那次探测又开了树,探完补关")
    }
}
