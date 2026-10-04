import Foundation
import LyrimuseCore

/// Kaset:AppleScript `get player info` 的解读、在走 / 广告 / 加载 / 卡住的判定、署名清理、跟系统那份怎么取舍、
/// 接线契约。读数样例照真实输出的形状造(署名带连接词、专辑一栏是歌单名、数字带长尾小数)。
@MainActor
func runKasetTests() {
    typealias K = KasetPlayerInfo
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let playingJSON = #"{"currentTrack":{"album":"1980年代西洋金曲精选","artist":"Eurythmics, 、, Annie Lennox, 和, Dave Stewart","artworkURL":"https:\/\/i.ytimg.com\/vi\/qeMFqkcPYcg\/hqdefault.jpg","duration":215,"name":"Sweet Dreams (Are Made Of This)","videoId":"qeMFqkcPYcg"},"duration":214.84100000000001,"isPaused":false,"isPlaying":true,"likeStatus":"none","muted":false,"position":18.478585754000001,"repeating":"off","shuffling":false,"volume":100}"#
    func reading(pos: Double, playing: Bool = true, paused: Bool = false, vid: String? = "v1") -> K.Reading {
        K.Reading(title: "T", artist: "A", videoID: vid, duration: 200, position: pos, isPlaying: playing, isPaused: paused)
    }

    // ---- 解析 ----
    do {
        let r = K.reading(fromJSON: Data(playingJSON.utf8))
        expectEqual(r?.title, "Sweet Dreams (Are Made Of This)", "Kaset 读数: 曲名")
        expectEqual(r?.videoID, "qeMFqkcPYcg", "Kaset 读数: videoId")
        expectEqual(r?.duration, 214.84100000000001, "Kaset 读数: 时长取网页 video 的,不取元数据里的整数秒")
        expectEqual(r?.position, 18.478585754000001, "Kaset 读数: 位置")
        expectEqual(r?.isPlaying == true && r?.isPaused == false, true, "Kaset 读数: 播放状态")
        let loading = #"{"currentTrack":{"artist":"Van Halen","duration":243,"name":"Jump (45 Version)","videoId":"SwYN7mTi6HM"},"duration":0,"isPaused":false,"isPlaying":false,"position":0}"#
        expectEqual(K.reading(fromJSON: Data(loading.utf8))?.duration, 243, "Kaset 读数: 网页时长还是 0 时退回元数据里的")
        expectEqual(K.reading(fromJSON: Data()) == nil, true, "Kaset 读数: 没在跑(脚本回空串)")
        expectEqual(K.reading(fromJSON: Data(#"{"isPlaying":false,"position":0}"#.utf8)) == nil, true, "Kaset 读数: 没有当前曲目")
        expectEqual(K.reading(fromJSON: Data(#"{"currentTrack":{"name":"  "},"isPlaying":true}"#.utf8)) == nil, true,
                    "Kaset 读数: 曲名为空不算一首")

        // 脚本输出:读数夹在 info 里,读到的时刻用脚本在读数调用返回时记的,不用子进程结束那一刻。
        func output(readAtMs: Double) -> Data {
            try! JSONSerialization.data(withJSONObject: ["readAtMs": readAtMs, "info": playingJSON])
        }
        let now = t0 + 0.2
        let parsed = K.parseScriptOutput(output(readAtMs: t0.timeIntervalSince1970 * 1000), now: now)
        expectEqual(parsed?.reading.videoID, "qeMFqkcPYcg", "Kaset 脚本输出: 读数原样解出")
        expectEqual(parsed?.readAt, t0, "Kaset 脚本输出: 读到的时刻取脚本记的那一刻")
        expectEqual(K.parseScriptOutput(output(readAtMs: (t0 - 60).timeIntervalSince1970 * 1000), now: now)?.readAt, now,
                    "Kaset 脚本输出: 时刻离此刻太远(墙钟被调过)就按此刻算")
        expectEqual(K.parseScriptOutput(Data(), now: now) == nil, true, "Kaset 脚本输出: 没在跑(空串)")
    }

    // ---- 在不在走:广告 / 加载 / 卡住都不算 ----
    do {
        expectEqual(K.isAdvancing(reading(pos: 12.5), lastMove: nil, now: t0), true, "Kaset 在走: 报在放、位置非 0")
        expectEqual(K.isAdvancing(reading(pos: 12.5, playing: false, paused: true), lastMove: nil, now: t0), false, "Kaset 在走: 暂停")
        expectEqual(K.isAdvancing(reading(pos: 0), lastMove: nil, now: t0), false, "Kaset 在走: 报在放、位置是 0 = 广告或开播缓冲")
        expectEqual(K.isAdvancing(reading(pos: 0, playing: false), lastMove: nil, now: t0), false, "Kaset 在走: 加载中")
        let seen = K.LastMove(videoID: "v1", position: 12.5, seenAt: t0)
        expectEqual(K.isAdvancing(reading(pos: 12.5), lastMove: seen, now: t0 + 0.6), true,
                    "Kaset 在走: 同一个值才读到 0.6 秒,还在网页两次推送之间")
        expectEqual(K.isAdvancing(reading(pos: 12.5), lastMove: seen, now: t0 + 2), false, "Kaset 在走: 同一首位置 2 秒没动 = 卡住")
        expectEqual(K.isAdvancing(reading(pos: 12.5, vid: "v2"), lastMove: seen, now: t0 + 2), true,
                    "Kaset 在走: 换了一首、恰好同一个位置值,不算卡住")
        expectEqual(K.isAdvancing(reading(pos: 13.0), lastMove: seen, now: t0 + 2), true, "Kaset 在走: 位置动了")
        let first = K.nextMove(after: nil, reading: reading(pos: 12.5), at: t0)
        expectEqual(first, seen, "Kaset 位置变化: 头一次读到就记下")
        expectEqual(K.nextMove(after: first, reading: reading(pos: 12.5), at: t0 + 2), first, "Kaset 位置变化: 没动就留着第一次读到的时刻")
        expectEqual(K.nextMove(after: first, reading: reading(pos: 13.0), at: t0 + 2).seenAt, t0 + 2, "Kaset 位置变化: 动了就换成这一次")
        expectEqual(K.nextMove(after: first, reading: reading(pos: 12.5, vid: "v2"), at: t0 + 2).videoID, "v2",
                    "Kaset 位置变化: 换了一首就换成这一次")
    }

    // ---- 广告:报在放、位置 0、时长还是元数据里的 ----
    do {
        let adJSON = #"{"currentTrack":{"artist":"Van Halen","duration":243,"name":"Jump (45 Version)","videoId":"SwYN7mTi6HM"},"duration":243,"isPaused":false,"isPlaying":true,"position":0}"#
        let startJSON = #"{"currentTrack":{"artist":"Cyndi Lauper","duration":267,"name":"Girls Just Want To Have Fun","videoId":"PIb6AZdTr-A"},"duration":266.741,"isPaused":false,"isPlaying":true,"position":0}"#
        let ad = K.reading(fromJSON: Data(adJSON.utf8))!
        let start = K.reading(fromJSON: Data(startJSON.utf8))!
        expectEqual(ad.playerDuration == 243 && ad.trackDuration == 243, true, "Kaset 广告: 两层时长都解出来")
        expectEqual(K.isAd(ad), true, "Kaset 广告: 报在放 + 位置 0 + 时长等于元数据里的 = 广告")
        expectEqual(K.isAd(start), false, "Kaset 广告: 开播缓冲那半秒时长已经是网页的,不算")
        func r(pos: Double, playing: Bool, paused: Bool = false) -> K.Reading {
            K.Reading(title: "T", artist: "A", videoID: "v", duration: 243, position: pos, isPlaying: playing, isPaused: paused,
                      playerDuration: 243, trackDuration: 243)
        }
        expectEqual(K.isAd(r(pos: 0, playing: false)), false, "Kaset 广告: 加载中不算")
        expectEqual(K.isAd(r(pos: 0, playing: false, paused: true)), false, "Kaset 广告: 暂停不算")
        expectEqual(K.isAd(r(pos: 3, playing: true)), false, "Kaset 广告: 位置在走不算")
        expectEqual(K.snapshot(ad, lastMove: nil, capturedAt: t0).isAd, true, "Kaset 广告: 快照标广告")
        expectEqual(K.snapshot(ad, lastMove: nil, capturedAt: t0).isWaitingToPlay, true, "Kaset 广告: 广告期间位置不走")
        expectEqual(K.snapshot(reading(pos: 12.5), lastMove: nil, capturedAt: t0).isAd, false, "Kaset 广告: 正片在走 = 明确不是广告")
        expectEqual(K.snapshot(reading(pos: 0, playing: false), lastMove: nil, capturedAt: t0).isAd == nil, true,
                    "Kaset 广告: 加载中说不上来")
        typealias L = LocalPlaybackSource
        expectEqual(L.adBreakByFields(isSpotifyNative: false, title: "Jump", artist: "Van Halen", album: "",
                                      youTubeMusicVerdict: nil, spotifyWebVerdict: nil, playerSaysAd: true), true,
                    "Kaset 广告: 播放器说是广告就亮「广告中」")
        expectEqual(L.playerAdVerdict(false), .song, "Kaset 广告: 正片在走折成 .song")
        expectEqual(L.nextAdBreakState(previous: true, isNewTrack: false, adByFields: false,
                                       pageVerdict: L.playerAdVerdict(false)), false,
                    "Kaset 广告: 前贴片过了、正片在走,「广告中」撤掉")
        expectEqual(L.nextAdBreakState(previous: true, isNewTrack: false, adByFields: false,
                                       pageVerdict: L.playerAdVerdict(nil)), true,
                    "Kaset 广告: 说不上来(加载 / 卡住)时保持")
        expectEqual(L.adSharesTrackIdentity(bundleID: PlaybackPlayer.kaset.bundleIdentifier), true,
                    "Kaset 广告: 广告跟正片共用身份,不写进播放状态")
        expectEqual(L.adSharesTrackIdentity(bundleID: PlaybackPlayer.spotify.bundleIdentifier), false,
                    "Kaset 广告: 别的播放器的广告照旧写进播放状态")
    }

    // ---- 广告倒计时:Kaset 的广告跟接下来那首歌共用身份,按广告自己的时长算 ----
    do {
        let at = t0
        let own = AdCountdown.next(isAdBreak: true, sharesIdentity: true, adDuration: 15.04, adElapsed: 2.3, capturedAt: at,
                                   previous: .track, sameTrack: false)
        expectEqual(own, .own(AdBreakClock(durationMs: 15040, positionMs: 2300, capturedAt: at)), "广告倒计时: Kaset 按广告自己的时长与进度")
        expectEqual(AdCountdown.next(isAdBreak: true, sharesIdentity: true, adDuration: nil, adElapsed: nil, capturedAt: at + 2,
                                     previous: own, sameTrack: true), own, "广告倒计时: 同一首这一拍没读到,沿用上一拍那只表")
        expectEqual(AdCountdown.next(isAdBreak: true, sharesIdentity: true, adDuration: nil, adElapsed: nil, capturedAt: at,
                                     previous: own, sameTrack: false), .unknown, "广告倒计时: 换了一首又读不到,不画")
        expectEqual(AdCountdown.next(isAdBreak: true, sharesIdentity: true, adDuration: nil, adElapsed: nil, capturedAt: at,
                                     previous: .track, sameTrack: true), .unknown, "广告倒计时: Kaset 拿不到广告时长,不拿歌的时长凑数")
        expectEqual(AdCountdown.next(isAdBreak: true, sharesIdentity: false, adDuration: nil, adElapsed: nil, capturedAt: at,
                                     previous: .track, sameTrack: true), .track, "广告倒计时: 广告本身是一首曲目的播放器照旧按曲目算")
        expectEqual(AdCountdown.next(isAdBreak: false, sharesIdentity: true, adDuration: 15, adElapsed: 1, capturedAt: at,
                                     previous: own, sameTrack: true), .track, "广告倒计时: 不在广告里恢复成按曲目")
        let clock = AdBreakClock(durationMs: 15040, positionMs: 2300, capturedAt: at)
        expectEqual(clock.positionMs(now: at + 1.5), 3800, "广告倒计时: 按墙钟往后推")
        expectEqual(clock.positionMs(now: at + 60), 15040, "广告倒计时: 不超过时长")
        expectEqual(clock.positionMs(now: at - 1), 2300, "广告倒计时: 墙钟往回不倒退")
        // 快照:看网页判成广告才带广告自己的时长与进度。
        let preroll = K.Reading(title: "給我ㄧ首歌的時間", artist: "周杰倫", videoID: "v", duration: 254, position: 0, isPlaying: true,
                                isPaused: false, playerDuration: 254, trackDuration: 254)
        let fromWeb = K.snapshot(preroll, lastMove: nil, capturedAt: t0, webMedia: K.WebMedia(duration: 6.02, isPlaying: true, elapsed: 2.4))
        expectEqual(fromWeb.adDuration == 6.02 && fromWeb.adElapsed == 2.4, true, "广告倒计时: 看网页判成广告时快照带上广告时长与进度")
        let fromReading = K.snapshot(preroll, lastMove: nil, capturedAt: t0)
        expectEqual(fromReading.isAd == true && fromReading.adDuration == nil, true, "广告倒计时: 按读数自己认的广告没有广告时长")
        let sessionsJSON = #"[{"bundleIdentifier":"com.apple.WebKit.GPU","processIdentifier":7685,"responsibleProcessIdentifier":692,"duration":15.04,"elapsedTime":3.3,"playing":true}]"#
        let sessions = (try? JSONDecoder().decode([NowPlayingClientsProbe.ClientSession].self, from: Data(sessionsJSON.utf8))) ?? []
        expectEqual(K.webMedia(in: sessions, kasetPID: 692)?.elapsed, 3.3, "广告倒计时: 网页那份带着此刻的进度")
    }

    // ---- 位置:在走时用内嵌网页那份会话的播放时钟 ----
    do {
        // Kaset 读数 120.70(晚一点),网页那份会话的锚点 100.0 @ t0−20.9、速率 1。
        let reading = K.Reading(title: "說了再見", artist: "周杰倫", videoID: "Wlwk9osZ9Mc", duration: 282.73, position: 120.70,
                                isPlaying: true, isPaused: false, playerDuration: 282.7335, trackDuration: 283)
        func web(anchor: Double? = 100, ago: Double = 20.9, rate: Double? = 1, duration: Double = 282.7335, playing: Bool = true) -> K.WebMedia {
            K.WebMedia(duration: duration, isPlaying: playing, elapsed: nil, anchorElapsed: anchor, anchorAt: t0 - ago, rate: rate)
        }
        expectEqual(K.webClockPosition(reading, web: web(), at: t0).map { abs($0 - 120.9) < 0.0001 }, true,
                    "Kaset 网页时钟: 锚点外推到这一拍,比 Kaset 的读数超前 0.2 秒,用它")
        expectEqual(K.webClockPosition(reading, web: web(ago: 60), at: t0) == nil, true, "Kaset 网页时钟: 锚点没跟上(超前几十秒),不用")
        expectEqual(K.webClockPosition(reading, web: web(ago: 20.2), at: t0) == nil, true, "Kaset 网页时钟: 落后读数半秒,不用")
        expectEqual(K.webClockPosition(reading, web: web(anchor: 120.8, ago: 3, rate: 0), at: t0) == nil, true, "Kaset 网页时钟: 速率 0(停着),不用")
        expectEqual(K.webClockPosition(reading, web: web(anchor: nil), at: t0) == nil, true, "Kaset 网页时钟: 没有锚点,不用")
        expectEqual(K.webClockPosition(reading, web: web(duration: 15.04), at: t0) == nil, true, "Kaset 网页时钟: 网页在放广告,不用")
        expectEqual(K.webClockPosition(reading, web: web(playing: false), at: t0) == nil, true, "Kaset 网页时钟: 网页没在放,不用")
        let moving = K.LastMove(videoID: "Wlwk9osZ9Mc", position: 119.70, seenAt: t0 - 2)
        let precise = K.snapshot(reading, lastMove: moving, capturedAt: t0, clockPosition: 120.9)
        expectEqual(precise.elapsedTime == 120.9 && precise.positionIsPrecise == true, true, "Kaset 网页时钟: 在走时快照用它、标精确")
        let stuck = K.LastMove(videoID: "Wlwk9osZ9Mc", position: 120.70, seenAt: t0 - 2)
        let stalled = K.snapshot(reading, lastMove: stuck, capturedAt: t0, clockPosition: 120.9)
        expectEqual(stalled.elapsedTime == 120.70 && stalled.positionIsPrecise == nil, true, "Kaset 网页时钟: 没在走不用")
        let session = #"[{"bundleIdentifier":"com.apple.WebKit.GPU","processIdentifier":7685,"responsibleProcessIdentifier":692,"duration":282.7335,"elapsedTime":120.9,"anchorElapsedTime":100,"timestamp":1800000000,"playbackRate":1,"playing":true}]"#
        let parsed = K.webMedia(in: (try? JSONDecoder().decode([NowPlayingClientsProbe.ClientSession].self, from: Data(session.utf8))) ?? [],
                                kasetPID: 692)
        expectEqual(parsed?.anchorElapsed == 100 && parsed?.anchorAt == Date(timeIntervalSince1970: 1_800_000_000) && parsed?.rate == 1, true,
                    "Kaset 网页时钟: 会话的锚点三项解出来")
    }

    // ---- 喜欢 / 随机 / 循环 / 音量 ----
    do {
        // 真机读数的形状(《說了再見》那一拍)。
        let info = #"{"currentTrack":{"name":"說了再見","videoId":"Wlwk9osZ9Mc"},"duration":283,"isPaused":false,"isPlaying":true,"likeStatus":"none","muted":false,"position":120.7,"repeating":"off","shuffling":false,"volume":100}"#
        expectEqual(K.controls(fromJSON: Data(info.utf8)), K.Controls(liked: false, shuffling: false, repeating: "off", volume: 100),
                    "Kaset 控件: 喜欢 / 随机 / 循环 / 音量解出来")
        expectEqual(K.controls(fromJSON: Data(#"{"likeStatus":"liked","shuffling":true,"repeating":"one","volume":35}"#.utf8)),
                    K.Controls(liked: true, shuffling: true, repeating: "one", volume: 35), "Kaset 控件: 赞过")
        expectEqual(K.controls(fromJSON: Data(#"{"likeStatus":"disliked"}"#.utf8))?.liked, false, "Kaset 控件: 点了踩不算喜欢")
        expectEqual(K.controls(fromJSON: Data("not json".utf8)) == nil, true, "Kaset 控件: 不是 JSON")
        typealias MPC = MusicPlaybackController
        expectEqual(MPC.kasetPlaybackMode(shuffling: false, repeating: "off"), .list, "Kaset 模式: 都关是列表")
        expectEqual(MPC.kasetPlaybackMode(shuffling: true, repeating: "off"), .shuffle, "Kaset 模式: 随机")
        expectEqual(MPC.kasetPlaybackMode(shuffling: false, repeating: "all"), .repeatAll, "Kaset 模式: 列表循环")
        expectEqual(MPC.kasetPlaybackMode(shuffling: true, repeating: "one"), .repeatOne, "Kaset 模式: 单曲循环优先于随机")
        expectEqual(MPC.kasetPlaybackMode(shuffling: true, repeating: "all"), .shuffle, "Kaset 模式: 随机优先于列表循环(同 Apple Music)")
        expectEqual(MPC.kasetPlaybackMode(shuffling: nil, repeating: "off") == nil, true, "Kaset 模式: 读不到就不显示")
        let toOne = MPC.kasetPlaybackModeScript(for: .repeatOne)
        expectEqual(toOne.contains("if (Boolean(info.shuffling) !== false) K.toggleShuffle();")
                        && toOne.contains(#"const target = "one";"#) && toOne.contains("K.cycleRepeat();"), true,
                    "Kaset 模式脚本: 单曲循环 = 关随机、循环按到 one")
        let toShuffle = MPC.kasetPlaybackModeScript(for: .shuffle)
        expectEqual(toShuffle.contains("if (Boolean(info.shuffling) !== true) K.toggleShuffle();")
                        && toShuffle.contains(#"const target = info.repeating === "one" ? "off" : info.repeating;"#), true,
                    "Kaset 模式脚本: 随机 = 开随机、只关单曲循环(列表循环留着)")
        expectEqual(MPC.kasetPlaybackModeScript(for: .repeatAll).contains(#"const target = "all";"#), true, "Kaset 模式脚本: 列表循环")
    }

    // ---- 封面:Kaset 报的地址,只要方形专辑图,换成大图那一档 ----
    do {
        expectEqual(K.coverArtworkURL("https://yt3.googleusercontent.com/D10mQ1XvIKZo-fV3N-MCa8O=w544-h544-l90-rj")?.absoluteString,
                    "https://yt3.googleusercontent.com/D10mQ1XvIKZo-fV3N-MCa8O=w1200-h1200-l90-rj", "Kaset 封面: 专辑图换成 1200 那一档")
        expectEqual(K.coverArtworkURL("https://lh3.googleusercontent.com/abc=w60-h60-s-l90-rj")?.absoluteString,
                    "https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj", "Kaset 封面: 小图的参数一样换")
        expectEqual(K.coverArtworkURL("https://i.ytimg.com/vi/ZLldhJXp7iw/hq720.jpg?sqp=-oaymwEKCNUGEN8DIABIWg") == nil, true,
                    "Kaset 封面: 视频截图不当封面")
        expectEqual(K.coverArtworkURL("https://yt3.googleusercontent.com/abc") == nil, true, "Kaset 封面: 没有尺寸参数的不要")
        expectEqual(K.coverArtworkURL("https://example.com/abc=w544-h544-l90-rj") == nil, true, "Kaset 封面: 别的域名带同样的参数也不认")
        expectEqual(K.coverArtworkURL("http://yt3.googleusercontent.com/abc=w544-h544") == nil, true, "Kaset 封面: 只认 https")
        expectEqual(K.coverArtworkURL(nil) == nil, true, "Kaset 封面: 没有地址")
        let withArt = #"{"currentTrack":{"artist":"周杰倫","duration":254,"name":"愛琴海","videoId":"ZLldhJXp7iw","artworkURL":"https:\/\/i.ytimg.com\/vi\/ZLldhJXp7iw\/hq720.jpg"},"duration":254,"isPaused":false,"isPlaying":true,"position":12}"#
        expectEqual(K.reading(fromJSON: Data(withArt.utf8))?.artworkURL, "https://i.ytimg.com/vi/ZLldhJXp7iw/hq720.jpg",
                    "Kaset 读数: 封面地址原样解出")
        expectEqual(K.reading(fromJSON: Data(withArt.utf8))?.withIdentity(title: "x", artist: "y").artworkURL,
                    "https://i.ytimg.com/vi/ZLldhJXp7iw/hq720.jpg", "Kaset 读数: 换身份时封面地址带着")
    }

    // ---- 广告:看内嵌网页此刻在放什么(前贴片时 Kaset 还报加载;两首之间的广告期间它还报着上一首、停在结尾)----
    do {
        // 系统里各 App 报的会话(helper 输出的形状):Kaset 自己那份、Safari 的 WebKit 媒体进程那份、Kaset 的那份。
        let sessionsJSON = #"[{"bundleIdentifier":"com.sertacozercan.Kaset","processIdentifier":692,"responsibleProcessIdentifier":692,"playing":true,"title":"給我ㄧ首歌的時間","isMusicApp":true},{"bundleIdentifier":"com.apple.WebKit.GPU","processIdentifier":10556,"responsibleProcessIdentifier":693,"duration":596.2,"elapsedTime":12,"playing":true,"title":""},{"bundleIdentifier":"com.apple.WebKit.GPU","processIdentifier":7685,"responsibleProcessIdentifier":692,"duration":6,"elapsedTime":0.3,"playing":true,"title":""}]"#
        let sessions = (try? JSONDecoder().decode([NowPlayingClientsProbe.ClientSession].self, from: Data(sessionsJSON.utf8))) ?? []
        expectEqual(sessions.count, 3, "Kaset 网页媒体: 各 App 的会话解出来")
        expectEqual(K.webMedia(in: sessions, kasetPID: 692), K.WebMedia(duration: 6, isPlaying: true, elapsed: 0.3),
                    "Kaset 网页媒体: 按负责进程认 Kaset 的那份,不拿 Safari 的")
        expectEqual(K.webMedia(in: sessions, kasetPID: 999) == nil, true, "Kaset 网页媒体: 没有 Kaset 的那份")
        // 真机录音(《給我ㄧ首歌的時間》前面一段 6 秒的广告):Kaset 先报加载、再报在放,位置都是 0,两层时长都是 254;
        // 网页那边先放 6 秒那段,再换成 254 秒的正片。
        func r(pos: Double, playing: Bool, player: Double? = 254, track: Double? = 254) -> K.Reading {
            K.Reading(title: "給我ㄧ首歌的時間", artist: "周杰倫", videoID: "v", duration: player ?? track, position: pos,
                      isPlaying: playing, isPaused: false, playerDuration: player, trackDuration: track)
        }
        let adMedia = K.WebMedia(duration: 6, isPlaying: true), songMedia = K.WebMedia(duration: 254, isPlaying: true)
        expectEqual(K.adByWebMedia(r(pos: 0, playing: false), web: adMedia), true, "Kaset 网页媒体: 还在加载,网页已经在放 6 秒那段 = 广告")
        expectEqual(K.adByWebMedia(r(pos: 0, playing: true), web: songMedia), false, "Kaset 网页媒体: 网页换成这首了 = 正片在缓冲")
        expectEqual(K.adByWebMedia(r(pos: 0, playing: true), web: K.WebMedia(duration: 6, isPlaying: false)) == nil, true,
                    "Kaset 网页媒体: 网页没在放,说不上来")
        expectEqual(K.adByWebMedia(r(pos: 0, playing: true), web: K.WebMedia(duration: nil, isPlaying: true)) == nil, true,
                    "Kaset 网页媒体: 网页那段时长还没出来,说不上来")
        expectEqual(K.adByWebMedia(r(pos: 0, playing: true, player: 392, track: 196), web: K.WebMedia(duration: 392.4, isPlaying: true)),
                    false, "Kaset 网页媒体: 元数据时长对不上、网页那层对得上(放的是 MV)也算这首")
        // 两首之间的广告:Kaset 还报着上一首、停在结尾、报在放。
        let ended = K.Reading(title: "晴天", artist: "周杰倫", videoID: "q", duration: 269.65, position: 269.6, isPlaying: true,
                              isPaused: false, playerDuration: 269.65, trackDuration: 270)
        let stuck = K.LastMove(videoID: "q", position: 269.6, seenAt: t0)
        let between = K.snapshot(ended, lastMove: stuck, capturedAt: t0 + 2, webMedia: K.WebMedia(duration: 30, isPlaying: true))
        expectEqual(between.isAd, true, "Kaset 广告: 还报着上一首、停在结尾,网页在放别的 = 两首之间的广告")
        expectEqual(between.isWaitingToPlay, true, "Kaset 广告: 两首之间的广告期间也算在等")
        expectEqual(K.snapshot(ended, lastMove: stuck, capturedAt: t0 + 2,
                               webMedia: K.WebMedia(duration: 269.65, isPlaying: false)).isAd == nil, true,
                    "Kaset 广告: 停在结尾、网页也停了,说不上来(不当广告)")
        expectEqual(K.snapshot(r(pos: 0, playing: false), lastMove: nil, capturedAt: t0, webMedia: adMedia).isAd, true,
                    "Kaset 广告: 前贴片时 Kaset 还报加载,网页已经在放广告")
        expectEqual(K.snapshot(r(pos: 0, playing: true), lastMove: nil, capturedAt: t0, webMedia: songMedia).isAd, false,
                    "Kaset 广告: 正片缓冲那一拍两层时长恰好相等,看网页不误判成广告")
        expectEqual(K.snapshot(r(pos: 0, playing: true), lastMove: nil, capturedAt: t0).isAd, true,
                    "Kaset 广告: 网页那边问不到时照旧按读数自己认")
        expectEqual(K.snapshot(r(pos: 12.5, playing: true), lastMove: nil, capturedAt: t0, webMedia: adMedia).isAd, false,
                    "Kaset 广告: 位置在走就是正片")
        // 真机录音:《西西里》开播那一拍元数据还是 230 秒,网页放的正片 234 秒;MV 比元数据长一倍。
        expectEqual(K.adByWebMedia(r(pos: 0, playing: false, player: 230, track: 230), web: K.WebMedia(duration: 234, isPlaying: true)),
                    false, "Kaset 网页媒体: 元数据还没更新、差几秒,算这首")
        expectEqual(K.adByWebMedia(r(pos: 0, playing: false, player: 196, track: 196), web: K.WebMedia(duration: 392.4, isPlaying: true))
                        == nil, true, "Kaset 网页媒体: 网页那段比这首长(放的是更长的 MV),说不上来,不当广告")
        expectEqual(K.adByWebMedia(r(pos: 0, playing: false, player: 100, track: 100), web: K.WebMedia(duration: 60, isPlaying: true))
                        == nil, true, "Kaset 网页媒体: 没短到一半,说不上来")
    }

    // ---- 署名 ----
    do {
        expectEqual(K.cleanedArtist("Eurythmics, 、, Annie Lennox, 和, Dave Stewart"), "Eurythmics, Annie Lennox, Dave Stewart",
                    "Kaset 署名: 中文界面混进来的连接词去掉")
        expectEqual(K.cleanedArtist("Shakira, y, Bizarrap"), "Shakira, Bizarrap", "Kaset 署名: 别的语言的连接词同样去掉")
        expectEqual(K.cleanedArtist("The Police"), "The Police", "Kaset 署名: 单个艺人原样")
        expectEqual(K.cleanedArtist("Daryl Hall & John Oates"), "Daryl Hall & John Oates", "Kaset 署名: 名字里本来就有 & 的不拆")
        expectEqual(K.cleanedArtist("A, B"), "A, B", "Kaset 署名: 两个艺人原样")
        expectEqual(K.cleanedArtist("和, 周杰伦, 方文山"), "和, 周杰伦, 方文山", "Kaset 署名: 排在头上的不动(可能真叫这个名字)")

        // 同一首歌网页加载好之后换了写法:沿用最先报的那份;时长对不上、歌名也换成别的照收新的。
        func credit(_ title: String, _ artist: String, vid: String? = "mQLzR5V2Z9c",
                    player: Double? = 152.4, track: Double? = 152) -> K.Reading {
            K.Reading(title: title, artist: artist, videoID: vid, duration: player ?? track, position: 3, isPlaying: true,
                      isPaused: false, playerDuration: player, trackDuration: track)
        }
        let opening = K.steadyIdentity(credit("Love Bomb", "Jhené Aiko, 和, Ab-Soul"), first: nil)
        expectEqual(opening.title == "Love Bomb" && opening.artist == "Jhené Aiko, 和, Ab-Soul", true, "Kaset 身份: 开播那份原样用")
        let web = K.steadyIdentity(credit("Love Bomb", "Jhené Aiko和Ab-Soul"), first: opening.first)
        expectEqual(web.artist, "Jhené Aiko, 和, Ab-Soul", "Kaset 身份: 同一首中途换的署名写法不跟")
        expectEqual(web.first, opening.first, "Kaset 身份: 记住的还是最先那份")
        expectEqual(K.snapshot(credit("Love Bomb", "Jhené Aiko和Ab-Soul").withIdentity(title: web.title, artist: web.artist),
                               lastMove: nil, capturedAt: t0).artist,
                    "Jhené Aiko, Ab-Soul", "Kaset 身份: 沿用的那份照样清理,跟预解析的缓存键一致")
        let uploaded = K.steadyIdentity(credit("Jhené Aiko - Love Bomb (Official Video)", "Jhené Aiko和Ab-Soul"), first: opening.first)
        expectEqual(uploaded.title == "Love Bomb" && uploaded.artist == "Jhené Aiko, 和, Ab-Soul" && uploaded.first == opening.first, true,
                    "Kaset 身份: 歌名换成视频标题(歌手前缀 + 括号)仍是同一首,沿用最先那份")
        let queued = K.steadyIdentity(credit("黑白 [Timeless Live 2009]", "方大同", vid: "7VKSdwYke9o", player: nil, track: 246), first: nil)
        let original = K.steadyIdentity(credit("Black And White [Timeless Live 2009]", "Khalil Fong", vid: "7VKSdwYke9o",
                                               player: 245.3, track: 246), first: queued.first)
        expectEqual(original.title == "黑白 [Timeless Live 2009]" && original.artist == "方大同" && original.first == queued.first, true,
                    "Kaset 身份: 换成网页上的原文写法、时长对得上,是同一段录音,沿用队列那份")
        let loading = K.steadyIdentity(credit("Jhené Aiko - Ark to Agartha", "Jhené Aiko", player: nil, track: 152), first: opening.first)
        expectEqual(loading.title == "Love Bomb" && loading.first == opening.first, true, "Kaset 身份: 网页时长还没出来先按住")
        let longVideo = K.steadyIdentity(credit("Jhené Aiko - Love Bomb (Official Video)", "Jhené Aiko和Ab-Soul", player: 201.5, track: 152),
                                         first: opening.first)
        expectEqual(longVideo.title, "Love Bomb", "Kaset 身份: 视频版更长、但歌名是同一首的写法,照样沿用")
        let retitled = K.steadyIdentity(credit("Jhené Aiko - Ark to Agartha", "Jhené Aiko", player: 392.4, track: 196), first: opening.first)
        expectEqual(retitled.title == "Jhené Aiko - Ark to Agartha" && retitled.artist == "Jhené Aiko", true,
                    "Kaset 身份: 时长对不上、歌名也换成别的,照收新的")
        expectEqual(retitled.first?.title, "Jhené Aiko - Ark to Agartha", "Kaset 身份: 换成别的改记新的那份")
        expectEqual(K.sameRecording(credit("x", "y", player: 245.3, track: 246)), true, "Kaset 录音: 网页时长跟元数据整数秒对得上")
        expectEqual(K.sameRecording(credit("x", "y", player: 392.4, track: 196)), false, "Kaset 录音: 差太多不是同一段")
        expectEqual(K.sameRecording(credit("x", "y", player: nil, track: 196)) == nil, true, "Kaset 录音: 网页时长还没出来说不上来")

        // 开播那份按队列补:App 在一首歌中途起来时第一拍已经是网页上的写法。
        let queue = #"{"currentIndex":2,"tracks":[{"name":"才二十三","artist":"方大同","videoId":"Cr1VjUDSp_0"},"# +
            #"{"name":" 黑白 [Timeless Live 2009] ","artist":"方大同","videoId":"7VKSdwYke9o","duration":246}]}"#
        let seeded = K.queueFirstReport(fromQueueJSON: Data(queue.utf8), videoID: "7VKSdwYke9o")
        expectEqual(seeded, K.FirstReport(videoID: "7VKSdwYke9o", title: "黑白 [Timeless Live 2009]", artist: "方大同"),
                    "Kaset 开播那份: 按队列里这一格补,歌名去首尾空白")
        let artQueue = #"{"currentIndex":1,"tracks":[{"name":"西西里","artist":"周杰倫","videoId":"QuGHsAP8yG0","duration":234,"# +
            #""artworkURL":"https://yt3.googleusercontent.com/D10mQ1XvIKZo-fV3N-MCa8O=w544-h544-l90-rj"}]}"#
        expectEqual(K.queueFirstReport(fromQueueJSON: Data(artQueue.utf8), videoID: "QuGHsAP8yG0")?.artworkURL,
                    "https://yt3.googleusercontent.com/D10mQ1XvIKZo-fV3N-MCa8O=w544-h544-l90-rj", "Kaset 开播那份: 带上队列里这一格的封面")
        expectEqual(K.queueFirstReport(fromQueueJSON: Data(queue.utf8), videoID: "qUUBDOL-09k") == nil, true,
                    "Kaset 开播那份: 队列里没有这首不补")
        expectEqual(K.queueFirstReport(fromQueueJSON: Data(), videoID: "7VKSdwYke9o") == nil, true, "Kaset 开播那份: 读不到队列不补")
        let restarted = K.steadyIdentity(credit("Black And White [Timeless Live 2009]", "Khalil Fong", vid: "7VKSdwYke9o",
                                                player: 245.03, track: 246), first: seeded)
        expectEqual(restarted.title == "黑白 [Timeless Live 2009]" && restarted.artist == "方大同", true,
                    "Kaset 开播那份: 中途起来时按队列那份,不跟网页上的写法")
        let next = K.steadyIdentity(credit("Love Bomb", "Jhené Aiko和Ab-Soul", vid: "AJ--JpOmlog"), first: opening.first)
        expectEqual(next.artist, "Jhené Aiko和Ab-Soul", "Kaset 身份: 换了 videoId 是另一首")
        let blank = K.steadyIdentity(credit("Love Bomb", "Jhené Aiko和Ab-Soul"),
                                     first: K.steadyIdentity(credit("Love Bomb", ""), first: nil).first)
        expectEqual(blank.artist, "Jhené Aiko和Ab-Soul", "Kaset 身份: 最先那份署名是空的不沿用")
        let noID = K.steadyIdentity(credit("Love Bomb", "Jhené Aiko和Ab-Soul", vid: nil), first: opening.first)
        expectEqual(noID.artist == "Jhené Aiko和Ab-Soul" && noID.first == nil, true, "Kaset 身份: 没有 videoId 原样、不记")

        // 同一首的两种歌名写法。
        expectEqual(K.sameSongTitle("Jhené Aiko - I Don't Mind (Official Audio)", "I Don't Mind", artist: "Jhené Aiko"), true,
                    "Kaset 歌名: 歌手前缀 + 结尾括号去掉后相同")
        expectEqual(K.sameSongTitle("Like, Whatever（合作音乐人：Tyga）", "Jhené Aiko - Like, Whatever (feat. Tyga) [Official Video]",
                                    artist: "Jhené Aiko"), true, "Kaset 歌名: 全角括号、多重括号一起去")
        expectEqual(K.sameSongTitle("Nami\u{2019}s Haiku", "Nami's Haiku", artist: "Jhené Aiko"), true, "Kaset 歌名: 弯直引号不分")
        expectEqual(K.sameSongTitle("Jhené Aiko & Ab-Soul - Love Bomb", "Love Bomb", artist: "Jhené Aiko, 和, Ab-Soul"), true,
                    "Kaset 歌名: 前缀以第一位歌手开头就算歌手前缀")
        expectEqual(K.sameSongTitle("Someone Else - Love Bomb", "Love Bomb", artist: "Jhené Aiko"), false,
                    "Kaset 歌名: 破折号前不是这位歌手,不当前缀去")
        expectEqual(K.sameSongTitle("Jhené Aiko - Ark to Agartha", "Break", artist: "Jhené Aiko"), false, "Kaset 歌名: 换了一首不算")
        expectEqual(K.sameSongTitle("(Interlude)", "Interlude", artist: "A"), false, "Kaset 歌名: 整个歌名都在括号里的不去")
        expectEqual(K.sameSongTitle("Children of the Sun 太陽之子", "太陽之子", artist: "周杰伦"), true,
                    "Kaset 歌名: 前面多一段别的语言的歌名,原名按词完整出现在里面")
        expectEqual(K.sameSongTitle("太陽之子", "Children of the Sun 太陽之子", artist: "周杰伦"), true, "Kaset 歌名: 两边顺序不论")
        expectEqual(K.sameSongTitle("晴天 Sunny Day", "晴天", artist: "周杰伦"), true, "Kaset 歌名: 两个汉字的原名也算")
        expectEqual(K.sameSongTitle("Children of the Sun", "Sun", artist: "周杰伦"), false, "Kaset 歌名: 太短的不按包含认")
        expectEqual(K.sameSongTitle("Sunshine Days", "Sunshine Day", artist: "A"), false, "Kaset 歌名: 词不完整不算包含")
        // 真机:《太陽之子》广告放完、正片一开始改成网页写法,网页放的是 418 秒的 MV,队列元数据是 298 秒。
        let sunQueued = K.steadyIdentity(credit("太陽之子", "周杰伦", vid: "9N9MEXaXSDk", player: nil, track: 298), first: nil)
        let sunWeb = K.steadyIdentity(credit("Children of the Sun 太陽之子", "周杰伦", vid: "9N9MEXaXSDk", player: 418.14, track: 298),
                                      first: sunQueued.first)
        expectEqual(sunWeb.title == "太陽之子" && sunWeb.first == sunQueued.first, true,
                    "Kaset 身份: 时长对不上,但歌名是原名加一段别的语言,还是同一首,沿用开播那份")
    }

    // ---- 快照 ----
    do {
        let r = K.reading(fromJSON: Data(playingJSON.utf8))!
        let s = K.snapshot(r, lastMove: nil, capturedAt: t0)
        expectEqual(s.album == nil, true, "Kaset 快照: 专辑一栏是歌单名,不用")
        expectEqual(s.artist, "Eurythmics, Annie Lennox, Dave Stewart", "Kaset 快照: 署名清理过")
        expectEqual(s.bundleIdentifier, PlaybackPlayer.kaset.bundleIdentifier, "Kaset 快照: 认作 Kaset")
        expectEqual(s.playing == true && s.playbackRate == 1 && s.isWaitingToPlay == false, true, "Kaset 快照: 在走")
        expectEqual(s.elapsedTime, 18.478585754000001, "Kaset 快照: 位置原样")
        expectEqual(s.capturedAt, t0, "Kaset 快照: 读数时刻记下")
        expectEqual(s.anchorElapsedTime == nil, true, "Kaset 快照: 读的是播放器自己的钟,没有系统锚点")
        let ad = K.snapshot(reading(pos: 0), lastMove: nil, capturedAt: t0)
        expectEqual(ad.playing == false && ad.playbackRate == 0 && ad.isWaitingToPlay == true, true,
                    "Kaset 快照: 广告 / 开播缓冲 = 停着、等着开始")
        let paused = K.snapshot(reading(pos: 30, playing: false, paused: true), lastMove: nil, capturedAt: t0)
        expectEqual(paused.playing == false && paused.isWaitingToPlay == false, true, "Kaset 快照: 暂停不算等着开始")
        let stalled = K.snapshot(reading(pos: 30), lastMove: K.LastMove(videoID: "v1", position: 30, seenAt: t0), capturedAt: t0 + 3)
        expectEqual(stalled.playing == false && stalled.isWaitingToPlay == true, true, "Kaset 快照: 卡住 = 停着、等着恢复")
    }

    // ---- 待播队列:整理成引擎那份(样例两侧共用)----
    do {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/testdata/kaset-queue")
        let input = (try? Data(contentsOf: dir.appendingPathComponent("script-output.json"))) ?? Data()
        let want = (try? Data(contentsOf: dir.appendingPathComponent("reply.json")))
            .flatMap { try? JSONDecoder().decode(K.QueueReply.self, from: $0) }
        let got = K.queueReply(fromScriptOutput: input)
        expectEqual(want != nil && got == want, true, "Kaset 队列: 整理结果跟共用样例 reply.json 一致")
        expectEqual(got?.currentIndex, 1, "Kaset 队列: 当前这首的下标换成从 0 起")
        expectEqual(got?.tracks.map(\.artist).contains("Eurythmics, Annie Lennox, Dave Stewart"), true,
                    "Kaset 队列: 署名跟快照同一套清理")
        let reencoded = got.flatMap { PlayerQueryServer.encodedQueueReply($0) }.map { Data($0.utf8) }
            .flatMap { try? JSONDecoder().decode(K.QueueReply.self, from: $0) }
        expectEqual(reencoded == got, true, "Kaset 队列: 编码后再解回来不变")
        let noCurrent = #"{"queue":"{\"currentIndex\":0,\"tracks\":[{\"name\":\"A\",\"artist\":\"B\"}]}","info":"{}"}"#
        expectEqual(K.queueReply(fromScriptOutput: Data(noCurrent.utf8))?.currentIndex == nil, true, "Kaset 队列: 没有当前曲目")
        expectEqual(K.queueReply(fromScriptOutput: Data(noCurrent.utf8))?.repeating, "off", "Kaset 队列: 读不到循环模式按关")
        expectEqual(K.queueReply(fromScriptOutput: Data()) == nil, true, "Kaset 队列: 没在跑(空串)")
        let paired = #"{"queue":"{\"currentIndex\":1,\"tracks\":[{\"name\":\"Break\",\"artist\":\"Jhené Aiko\",\"videoId\":\"AJ--JpOmlog\",\"audioVideoId\":\"ot0WzesOp6I\"}]}","info":"{}"}"#
        expectEqual(K.queueReply(fromScriptOutput: Data(paired.utf8))?.tracks.first?.audioVideoID, "ot0WzesOp6I",
                    "Kaset 队列: 音轨版本的 videoId 原样交出(专辑只登记在它上面)")
        expectEqual(K.queueReply(fromScriptOutput: Data(#"{"queue":"{\"tracks\":[]}","info":"{}"}"#.utf8)) == nil, true,
                    "Kaset 队列: 空队列")
    }

    // ---- 界面专辑位 ----
    do {
        typealias L = LocalPlaybackSource
        expectEqual(L.displayAlbum(album: "Westside Whimsy", youtubeMusicAlbum: "Other", isMusicVideo: true, musicVideoLabel: "MV"),
                    "Westside Whimsy", "专辑位: 播放器报了就照报")
        expectEqual(L.displayAlbum(album: "", youtubeMusicAlbum: "Westside Whimsy", isMusicVideo: true, musicVideoLabel: "MV"),
                    "Westside Whimsy", "专辑位: 没报时用 YouTube Music 登记的,先于「MV」")
        expectEqual(L.displayAlbum(album: "", youtubeMusicAlbum: "", isMusicVideo: true, musicVideoLabel: "MV"), "MV",
                    "专辑位: 都没有、是 MV 写「MV」")
        expectEqual(L.displayAlbum(album: "", youtubeMusicAlbum: "", isMusicVideo: false, musicVideoLabel: "MV"), "",
                    "专辑位: 都没有留空")
        expectEqual(L.albumOrListed(album: "未来", youtubeMusicAlbum: "Wonderland"), "未来", "给人看的专辑: 播放器报了就用它")
        expectEqual(L.albumOrListed(album: "", youtubeMusicAlbum: "未来"), "未来", "给人看的专辑: 没报时用 YouTube Music 登记的")
        expectEqual(L.albumOrListed(album: "", youtubeMusicAlbum: ""), "", "给人看的专辑: 两样都没有才空")
    }

    // ---- 歌曲页:YouTube Music 网页 ----
    do {
        let ok = PlatformLinks.youtubeMusicWatchURL("https://music.youtube.com/watch?v=OMOGaugKpzs")
        expectEqual(ok?.absoluteString, "https://music.youtube.com/watch?v=OMOGaugKpzs", "Kaset 歌曲页: 11 位 videoId 认")
        for bad in ["https://music.youtube.com/watch?v=OMOGaugKpz", "https://music.youtube.com/watch?v=OMOGaugKpzs&list=x",
                    "https://www.youtube.com/watch?v=OMOGaugKpzs", "kaset://play?v=OMOGaugKpzs", ""] {
            expectEqual(PlatformLinks.youtubeMusicWatchURL(bad) == nil, true, "Kaset 歌曲页: \(bad) 不认")
        }
        let links = PlatformLinks(appleMusic: nil, qqSong: nil, qqAlbum: nil, qqArtist: nil, neteaseSong: nil, youtubeMusicSong: ok)
        expectEqual(links.songLink(forPlayerBundleID: PlaybackPlayer.kaset.bundleIdentifier)?.platform, .youtubeMusic,
                    "Kaset 歌曲页: 用 Kaset 放时简介面板给 YouTube Music 那条")
        expectEqual(links.songLink(forPlayerBundleID: PlaybackPlayer.appleMusic.bundleIdentifier) == nil, true,
                    "Kaset 歌曲页: 别的播放器不拿它顶上")
        expectEqual(links.isEmpty, false, "Kaset 歌曲页: 只有它也算有链接")
        expectEqual(MediaControlClient.kasetVideoID(forTrackKey: "nobody|nothing") == nil, true, "Kaset 歌曲页: 没读到过的那首没有 videoId")
        expectEqual(PlatformLinks.kasetPlayURL(watchURL: "https://music.youtube.com/watch?v=OMOGaugKpzs")?.absoluteString,
                    "kaset://play?v=OMOGaugKpzs", "Kaset 播放深链: 由歌曲页换算")
        expectEqual(PlatformLinks.kasetPlayURL(watchURL: "https://music.youtube.com/watch?v=OMOGaugKpz") == nil, true,
                    "Kaset 播放深链: 形状不对不给")
        let chart = ChartLinkIndex.build([ChartLinkIndex.Row(
            key: "The Police|Every Breath You Take|", appleMusicURL: nil, spotifyTrackID: nil, kkboxURL: nil,
            youtubeMusicURL: "https://music.youtube.com/watch?v=OMOGaugKpzs")])
            .links(kind: .track, artist: "The Police", name: "Every Breath You Take")
        expectEqual(chart?.kaset?.absoluteString, "kaset://play?v=OMOGaugKpzs", "Kaset 播放深链: 榜单那一行带上")
    }

    // ---- 跟别的来源怎么取舍 ----
    do {
        let other = MediaControlSnapshot.forReplay(title: "X", artist: "Y", duration: 200, elapsedTime: 10, playing: false,
                                                   bundleIdentifier: PlaybackPlayer.appleMusic.bundleIdentifier, anchorElapsedTime: nil)
        let otherPlaying = MediaControlSnapshot.forReplay(title: "X", artist: "Y", duration: 200, elapsedTime: 10, playing: true,
                                                          bundleIdentifier: PlaybackPlayer.appleMusic.bundleIdentifier, anchorElapsedTime: nil)
        let kPlaying = K.snapshot(reading(pos: 12.5), lastMove: nil, capturedAt: t0)
        let kPaused = K.snapshot(reading(pos: 12.5, playing: false, paused: true), lastMove: nil, capturedAt: t0)
        let kWaiting = K.snapshot(reading(pos: 0), lastMove: nil, capturedAt: t0)
        expectEqual(MediaControlClient.kasetWins(over: nil, kaset: kPaused), true, "Kaset 取舍: 别的来源什么都没有,暂停着的也报")
        expectEqual(MediaControlClient.kasetWins(over: other, kaset: kPaused), false, "Kaset 取舍: 别的播放器暂停着、它也暂停着,不换")
        expectEqual(MediaControlClient.kasetWins(over: other, kaset: kPlaying), true, "Kaset 取舍: 别的暂停着、它在放,换过去")
        expectEqual(MediaControlClient.kasetWins(over: other, kaset: kWaiting), true, "Kaset 取舍: 它正要放(加载 / 广告),换过去")
        expectEqual(MediaControlClient.kasetWins(over: otherPlaying, kaset: kPlaying), false, "Kaset 取舍: 别的在放,听系统的")
    }

    // ---- 封面:系统那份恒为空,用缓存里匹配到的 ----
    do {
        typealias G = CoverArtReplacementGate
        let id = PlaybackPlayer.kaset.bundleIdentifier
        expectEqual(G.systemNeverHasArtwork(bundleID: id), true, "Kaset 封面: 系统会话里从来没有封面")
        expectEqual(G.systemNeverHasArtwork(bundleID: PlaybackPlayer.appleMusic.bundleIdentifier), false,
                    "Kaset 封面: 别的播放器不算")
        expectEqual(G.reason(width: 0, height: 0, lowResThreshold: 300, systemNeverHasArtwork: true), .playerHasNoArtwork,
                    "Kaset 封面: 没有系统图时去找缓存里的")
        expectEqual(G.reason(width: 0, height: 0, lowResThreshold: 300) == nil, true,
                    "Kaset 封面: 别的播放器没有系统图照旧显示占位音符")
        expectEqual(G.accepts(candidateWidth: 1200, candidateHeight: 1200, systemWidth: 0, reason: .playerHasNoArtwork), true,
                    "Kaset 封面: 方形的替代图换上")
        expectEqual(G.accepts(candidateWidth: 1280, candidateHeight: 720, systemWidth: 0, reason: .playerHasNoArtwork), false,
                    "Kaset 封面: 不是封面形状的不换")
    }

    // ---- 登记与分派 ----
    do {
        let id = PlaybackPlayer.kaset.bundleIdentifier
        expectEqual(LocalPlaybackSource.positionSourceTier(forBundleID: id), .noisyFloored,
                    "Kaset 登记: 位置只会晚不会早,归 noisyFloored")
        expectEqual(PlaybackPlayer.kaset.needsAutomationPermission, true, "Kaset 登记: 读数走 AppleScript,要自动化权限")
        expectEqual(PlaybackPlayer.kaset.nativeLyricSource, "lyricfind", "Kaset 登记: 同源歌词是 YouTube Music 自己那份")
        expectEqual(LocalPlaybackSource.acceptsSeek(bundleID: id), true, "Kaset 登记: media-control 的跳转它响应")
        expectEqual(MusicPlaybackController.controlRoute(exclusivelyAppleMusic: false, focusFallback: .kaset), .kasetScript,
                    "Kaset 分派: 焦点回退到它时播放控制发 AppleScript")
        expectEqual(MediaControlClient.channelFallbackCandidates(selected: [.kaset]), [.kaset], "Kaset 分派: 通道坏了也直接问它")
        expectEqual(MediaControlClient.directQueryPlayer(forBundleID: id), .kaset, "Kaset 分派: 焦点被占时能直接问到它")
    }

    // ---- 接线契约(扫源码)----
    do {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ rel: String) -> String {
            (try? String(contentsOfFile: sources.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
        }
        let client = src("LyrimuseCore/Local/MediaControlClient.swift")
        let adapted = ["        case PlaybackPlayer.kaset.bundleIdentifier:",
                       "            // 跟 Spotify 一样暂停态也问:系统那份连歌名都可能是上一首的(见 KasetPlayerInfo 头注)。",
                       "            return fetchKasetSnapshot() ?? mediaControl"].joined(separator: "\n")
        expectEqual(client.contains(adapted), true, "Kaset 契约: 认出是它之后整份换成 AppleScript 那份,暂停态也换")
        expectEqual(client.contains("case .kaset: snapshot = fetchKasetSnapshot()"), true, "Kaset 契约: 焦点回退问它自己")
        expectEqual(client.contains("let steady = KasetPlayerInfo.steadyIdentity(raw, first: first)")
                        && client.contains("let reading = raw.withIdentity(title: steady.title, artist: steady.artist)"), true,
                    "Kaset 契约: 出快照之前先过 steadyIdentity")
        expectEqual(client.contains("let web = reading.isPaused || KasetPlayerInfo.isAdvancing(reading, lastMove: lastMove, now: readAt)")
                        && client.contains("? nil : kasetWebMedia()")
                        && client.contains("capturedAt: readAt, webMedia: web,")
                        && src("LyrimuseCore/Local/NowPlayingClientsProbe.swift").contains("[paths.script, paths.library], timeout: timeout)")
                        && src("../native/nowplaying-clients/nowplaying-clients.m").contains("if (one) [all addObject:withProcess(one, c)];"),
                    true, "Kaset 契约: 报在放(或加载)、位置没动时才问内嵌网页在放什么;helper 给每份会话带上负责进程")
        expectEqual(client.contains("KasetPlayerInfo.coverArtworkURL(steady.first?.artworkURL) ?? KasetPlayerInfo.coverArtworkURL(reading.artworkURL)")
                        && client.contains("kasetLastArtwork = artwork.map { (snapshot.identityKey, $0) }")
                        && client.contains(#"NetworkAuditLog.record(service: "image", operation: "kaset.artwork""#)
                        && src("LyrimuseCore/Local/LocalPlaybackSource.swift").contains(
                            "? MediaControlClient.kasetArtwork(forTrackKey: expectedKey) : MediaControlClient.fetchArtwork()"),
                    true, "Kaset 契约: 封面用它自己报的那张(队列那张优先),下载记对外请求,取图时按播放器分流")
        let controller = src("LyrimuseCore/Local/MusicPlaybackController.swift")
        expectEqual(controller.contains(#"if (liked() !== \(value)) K.likeTrack();"#)
                        && controller.contains(#"return runKasetJXACapturing(kasetPlaybackModeScript(for: mode)) == "ok""#)
                        && controller.contains(#"K.setVolume(\(v));"#), true,
                    "Kaset 契约: 喜欢先看再按、模式按脚本切、音量走 set volume")
        expectEqual(src("LyrimuseCore/Local/LocalPlaybackSource.swift").contains(
                        "isAdBreak: nextAd, sharesIdentity: Self.adSharesTrackIdentity(bundleID: snapshot.bundleIdentifier),")
                        && src("lyrimuse/PlaybackCoordinator.swift").contains(#"s.$adCountdown.assign(to: \.adCountdown, on: self),"#)
                        && src("lyrimuse/UI/NotchLyricsView.swift").contains("switch playback.adCountdown {"), true,
                    "Kaset 契约: 广告倒计时按播放源给的来源画(Kaset 用广告自己的表)")
        expectEqual(client.contains("? kasetWebClockPosition(reading, at: readAt) : nil")
                        && src("LyrimuseCore/Local/LocalPlaybackSource.swift").contains(
                            "if snapshot.positionIsPrecise == true {\n                    usedBrowserProbe = true\n                    browserProbePrecise = true"), true,
                    "Kaset 契约: 在走时位置用网页时钟,播放源当精确真值采信")
        expectEqual(client.contains("if let id = raw.videoID, !id.isEmpty, first?.videoID != id {")
                        && client.contains("first = queuedFirstReport(videoID: id) ?? first"), true,
                    "Kaset 契约: 新歌第一拍按队列补开播那份")
        expectEqual(src("lyrimuse/UI/LyricsWindowView.swift").contains(
            "album: LocalPlaybackSource.albumOrListed(album: album, youtubeMusicAlbum: listedAlbum),")
                        && src("lyrimuse/LyricsManager/LyricsQuickSearchWindow.swift").contains(
            "album: LocalPlaybackSource.albumOrListed(album: album, youtubeMusicAlbum: LocalPlaybackSource.shared.youtubeMusicAlbum),"),
                    true, "Kaset 契约: 两个搜歌词入口没报专辑时预填登记的专辑")
        let store = src("lyrimuse/LyricsManager/EnrichCacheStore.swift")
        expectEqual(store.contains(#"youtubeMusicAlbum: (entry["youtube_music_album"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "")"#)
                        && store.contains("normAlbum: toSimplified(displayAlbum).lowercased(),")
                        && store.contains("searchAlbumLower: displayAlbum.lowercased()")
                        && store.contains("albumMap[s.normAlbum] = s.displayAlbum"), true,
                    "Kaset 契约: 歌词管理的列表、筛选、排序、搜索按给人看的专辑")
        let manager = src("lyrimuse/LyricsManager/LyricsManagerView.swift")
        expectEqual(manager.contains(": albumDisplay(summary.displayAlbum),")
                        && manager.contains("album: summary.displayAlbum,")
                        && manager.contains(": albumDisplay(summary.displayAlbum))")
                        && manager.contains("displayAlbum: displayAlbum,"), true,
                    "Kaset 契约: 歌词管理的列表行、详情、搜歌词预填、占位行用给人看的专辑")
        expectEqual(src("lyrimuse/LyricsManager/LyricsDecisionSheet.swift").contains(
            "if !summary.displayAlbum.isEmpty { lines.append(summary.displayAlbum) }"), true, "Kaset 契约: 决策面板表头用给人看的专辑")
        expectEqual(src("lyrimuse/UI/NotchLyricsView.swift").contains(
            "tappable: !playback.album.isEmpty || !playback.youtubeMusicAlbum.isEmpty"), true,
                    "Kaset 契约: 灵动岛专辑行有登记的专辑时也可点开简介")
        expectEqual(src("LyrimuseCore/Local/EnrichCacheReader.swift").contains(#"case youtubeMusicMV = "youtube_music_mv""#)
                        && src("LyrimuseCore/Local/LocalPlaybackSource.swift").contains(
                            "&& EnrichCacheReader.youtubeMusicIsMV(artist: newArtist, title: newTitle, album: newAlbum)")
                        && src("LyrimuseCore/Local/LocalPlaybackSource.swift").contains("if youtubeMusicIsMV { youtubeMusicIsMV = false }"), true,
                    "Kaset 契约: 条目里判成 MV 版本的,播放源每拍读出来、停播清掉")
        expectEqual(src("lyrimuse/PlaybackCoordinator.swift").contains("isMusicVideo: isMusicVideo || listedMV,"), true,
                    "Kaset 契约: 判成 MV 版本的专辑位写「MV」")
        expectEqual(store.contains(#"isListedMV: displayAlbum.isEmpty && (entry["youtube_music_mv"] as? Bool ?? false),"#)
                        && manager.contains(#"albumDisplayName: summary.isListedMV ? L10n.t("MV") : albumDisplay(summary.displayAlbum),"#)
                        && manager.contains(#"Text(summary.isListedMV ? L10n.t("MV") : albumDisplay(summary.displayAlbum))"#), true,
                    "Kaset 契约: 歌词管理的列表和详情给 MV 版本写「MV」")
        let playback = src("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(playback.contains("? EnrichCacheReader.youtubeMusicAlbum(artist: newArtist, title: newTitle, album: newAlbum) ?? \"\" : \"\"")
                        && playback.contains("if newListedAlbum != youtubeMusicAlbum { youtubeMusicAlbum = newListedAlbum }"),
                    true, "Kaset 契约: 播放器没报专辑时每拍从缓存取 YouTube Music 登记的专辑")
        expectEqual(playback.contains("if !youtubeMusicAlbum.isEmpty { youtubeMusicAlbum = \"\" }"), true,
                    "Kaset 契约: 停播时一起清掉")
        expectEqual(src("LyrimuseCore/Local/EnrichCacheReader.swift").contains(#"case youtubeMusicAlbum = "youtube_music_album""#),
                    true, "Kaset 契约: 缓存条目的键名跟引擎一致")
        expectEqual(src("lyrimuse/PlaybackCoordinator.swift").contains(
            "LocalPlaybackSource.displayAlbum(album: album, youtubeMusicAlbum: listed, isMusicVideo: isMusicVideo || listedMV,"),
                    true, "Kaset 契约: 界面专辑位按 displayAlbum 取")
        expectEqual(client.contains("if snapshot == nil, player != .kaset {"), true,
                    "Kaset 契约: 焦点回退不拿系统按 bundle id 存的那份(换歌后常停在上一首)")
        expectEqual(client.contains("if players.contains(.auto) { return heldAcrossPlayerGap(preferringPlayingKaset(fetchAutoDetectedSnapshot())) }"), true,
                    "Kaset 契约: 自动识别时系统那边没在放就问它")
        expectEqual(client.contains("return heldAcrossPlayerGap(players.contains(.kaset) ? preferringPlayingKaset(selected) : selected)"), true,
                    "Kaset 契约: 勾了它的多选同样问,没勾的不问")
        expectEqual(client.contains("if !players.contains(.auto), !players.contains(.kaset) { forgetKasetPreference() }"), true,
                    "Kaset 契约: 设置不认 Kaset 时清掉顶替记录(播放控制别再发给它)")
        let control = client.range(of: "public static func focusControlTarget() -> PlaybackPlayer? {")
            .map { String(client[$0.upperBound...].prefix(260)) } ?? ""
        expectEqual(control.contains("if kasetPreferred { return .kaset }"), true, "Kaset 契约: 顶替系统那边时播放控制直接发给它")
        expectEqual(src("lyrimuse/LastfmStatsSection.swift").contains(
            #"if let url = links?.kaset, Self.isInstalled(.kaset) {"#), true, "Kaset 契约: 榜单右键「在 Kaset 中播放」只在装了 Kaset 时出")
        expectEqual(src("lyrimuse/UI/LyricsWindowView.swift").contains(#"L10n.t("YouTube Music 歌曲页")"#), true,
                    "Kaset 契约: 歌词窗口「⋯」给 YouTube Music 歌曲页")
        let source = src("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(source.contains("if isPlayingNow || lastSnapshot?.isWaitingToPlay == true { return PollInterval.playing }"), true,
                    "Kaset 契约: 等着开始时轮询留在播放中的节拍")
        expectEqual(source.contains("ad: isCurrentTrackAdBreak && !Self.adSharesTrackIdentity(bundleID: bundleID), positionSecs: positionSecs,"),
                    true, "Kaset 契约: 前贴片广告不写进播放状态(引擎会把整首当广告)")
        expectEqual(source.contains("playerSaysAd: snapshot.isAd)") && source.contains(
            "pageVerdict: isSpotifyNative ? nil : Self.playerAdVerdict(snapshot.isAd) ?? youTubeMusicVerdict)"), true,
                    "Kaset 契约: 广告结论接进「广告中」状态机,正片在走时能回落")
    }
}
