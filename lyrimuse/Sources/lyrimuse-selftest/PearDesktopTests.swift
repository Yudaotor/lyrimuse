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
}
