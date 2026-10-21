import Foundation
import LyrimuseCore

/// VOX:AppleScript 读数的解读、没写标签的文件名、乱码、精确时长、换歌那一拍的撕裂、系统那份「歌手 — 专辑」的拆法、
/// 循环与音量、接线契约。读数样例照真机输出的形状造(地址是 `file:/…` 单斜杠、百分号编码,总时长整秒)。
@MainActor
func runVoxTests() {
    typealias V = VoxPlayerInfo
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let playingJSON = #"{"title":"Fade Away","artist":"Jamie Rumley","album":"Fade Away (Acoustic Single)","duration":220,"playing":true,"playbackRate":1,"isMusicApp":true,"bundleIdentifier":"com.coppertino.Vox","fileURL":"file:/Users/u/Music/%E6%B5%8B%E8%AF%95/2010-01-Jamie-Rumley-Fade-Away.mp3","uniqueID":"x-coredata://0F2B/VXCustomTrack/p2","elapsedTime":32.4699}"#

    // ---- 解析 ----
    do {
        let r = V.reading(fromScriptOutput: Data(playingJSON.utf8), capturedAt: t0, fileDuration: { _ in 220.290612 })
        expectEqual(r?.snapshot.title, "Fade Away", "VOX 读数: 歌名")
        expectEqual(r?.snapshot.artist, "Jamie Rumley", "VOX 读数: 歌手只有歌手,不带专辑")
        expectEqual(r?.snapshot.album, "Fade Away (Acoustic Single)", "VOX 读数: 专辑")
        expectEqual(r?.snapshot.elapsedTime, 32.4699, "VOX 读数: 位置")
        expectEqual(r?.snapshot.playing, true, "VOX 读数: 在放")
        expectEqual(r?.snapshot.bundleIdentifier, "com.coppertino.Vox", "VOX 读数: bundle id")
        expectEqual(r?.snapshot.capturedAt, t0, "VOX 读数: 读到的时刻按调用返回那一刻")
        expectEqual(r?.snapshot.duration, 220.290612, "VOX 读数: 时长用文件的精确值,脚本只报整秒")
        expectEqual(r?.filePath, "/Users/u/Music/测试/2010-01-Jamie-Rumley-Fade-Away.mp3", "VOX 读数: 当前文件路径解出百分号编码")
        expectEqual(r?.uniqueID, "x-coredata://0F2B/VXCustomTrack/p2", "VOX 读数: 资料库标识")
        let mismatch = V.reading(fromScriptOutput: Data(playingJSON.utf8), capturedAt: t0, fileDuration: { _ in 300 })
        expectEqual(mismatch?.snapshot.duration, 220, "VOX 读数: 文件时长对不上(差 1.5 秒以上)照用脚本的")
        expectEqual(V.reading(fromScriptOutput: Data("null".utf8), capturedAt: t0) == nil, true, "VOX 读数: 没在跑 / 停住(null)")
        expectEqual(V.reading(fromScriptOutput: Data(), capturedAt: t0) == nil, true, "VOX 读数: 空输出")
        let paused = playingJSON.replacingOccurrences(of: #""playing":true,"playbackRate":1"#, with: #""playing":false,"playbackRate":0"#)
        expectEqual(V.reading(fromScriptOutput: Data(paused.utf8), capturedAt: t0, fileDuration: { _ in nil })?.snapshot.playing,
                    false, "VOX 读数: 暂停")
    }

    // ---- 文件地址 ----
    do {
        expectEqual(V.filePath(fromTrackURL: "file:/Users/u/a%20b/c.mp3"), "/Users/u/a b/c.mp3", "VOX 文件: file:/ 单斜杠")
        expectEqual(V.filePath(fromTrackURL: "file:///Users/u/c.flac"), "/Users/u/c.flac", "VOX 文件: file:/// 也认")
        expectEqual(V.filePath(fromTrackURL: "https://example.com/stream"), nil, "VOX 文件: 不是本地文件")
        expectEqual(V.filePath(fromTrackURL: ""), nil, "VOX 文件: 空")
        expectEqual(V.filePath(fromTrackURL: nil), nil, "VOX 文件: 读不到")
    }

    // ---- 身份:没写标签的文件名、乱码 ----
    do {
        func id(_ title: String, _ artist: String = "", _ album: String = "", path: String?) -> String {
            let r = V.identity(title: title, artist: artist, album: album, filePath: path)
            return "\(r.artist)|\(r.title)|\(r.album)"
        }
        expectEqual(id("无标签 mezzamo - happy boy.mp3", path: "/m/无标签 Mezzamo - Happy Boy.mp3"), "无标签 Mezzamo|Happy Boy|",
                    "VOX 身份: 没写标签 → 文件名原样的大小写,按第一个「 - 」拆")
        expectEqual(id("track08.mp3", path: "/m/Track08.mp3"), "|Track08|", "VOX 身份: 没写标签、没有「 - 」只去扩展名")
        expectEqual(id("happy boy", path: "/m/只有歌名.mp3"), "|happy boy|", "VOX 身份: 只写了歌名的照用标签(歌名不是文件名)")
        expectEqual(id("Happy Boy", "Mezzamo — Live", "Everything you", path: "/m/x.mp3"), "Mezzamo — Live|Happy Boy|Everything you",
                    "VOX 身份: 有标签原样")
        expectEqual(id("x.mp3", "Mezzamo", path: "/m/x.mp3"), "Mezzamo|x.mp3|", "VOX 身份: 有歌手不当没写标签")
        expectEqual(id("\u{B4}\u{B8}\u{A4}\u{D1}", "\u{A9}P\u{AA}N\u{AD}\u{DB}", path: "/m/b.mp3"), "周杰倫|晴天|",
                    "VOX 身份: Big5 标签的乱码还原")
        expectEqual(id("Kickstart My Heart", "Mötley Crüe", path: "/m/k.mp3"), "Mötley Crüe|Kickstart My Heart|",
                    "VOX 身份: 带重音的西文不当乱码")
    }

    // ---- 精确时长 ----
    do {
        expectEqual(V.preciseDuration(reported: 220, file: 220.290612), 220.290612, "VOX 时长: 文件跟整秒对得上")
        expectEqual(V.preciseDuration(reported: 220, file: 300), nil, "VOX 时长: 对不上不用文件的")
        expectEqual(V.preciseDuration(reported: 0, file: 40.0), 40.0, "VOX 时长: 脚本没报时用文件的")
        expectEqual(V.preciseDuration(reported: 220, file: nil), nil, "VOX 时长: 读不到文件")
        expectEqual(V.preciseDuration(reported: 220, file: 0), nil, "VOX 时长: 文件读出 0 不用")
    }

    // ---- 换歌那一拍的撕裂 ----
    do {
        let prev = V.Mark(trackID: "p1", elapsed: 52.0, playing: true, at: t0)
        func lags(_ id: String, _ elapsed: Double, after: Double, previous: V.Mark? = prev) -> Bool {
            V.positionLagsTrackChange(previous: previous, current: V.Mark(trackID: id, elapsed: elapsed, playing: true,
                                                                        at: t0 + after))
        }
        expectEqual(lags("p2", 52.4, after: 0.4), true, "VOX 撕裂: 换了歌、位置是上一首走过来的")
        expectEqual(lags("p2", 0.27, after: 0.4), false, "VOX 撕裂: 新歌在开头")
        expectEqual(lags("p1", 52.4, after: 0.4), false, "VOX 撕裂: 没换歌")
        expectEqual(lags("p2", 120, after: 0.4), false, "VOX 撕裂: 换歌后位置跟上一首对不上(点播时带了起点)")
        expectEqual(lags("p2", 52.4, after: 0.4, previous: V.Mark(trackID: "p1", elapsed: 52, playing: false, at: t0)), false,
                    "VOX 撕裂: 上一次是暂停着的")
        expectEqual(lags("p2", 52.4, after: 0.4, previous: nil), false, "VOX 撕裂: 第一次读")
    }

    // ---- 系统那份会话的「歌手 — 专辑」 ----
    do {
        func split(_ artist: String, _ title: String, known: (String, String, String)?) -> String {
            let r = V.splitSystemArtist(artist, title: title, known: known.map { (title: $0.0, artist: $0.1, album: $0.2) })
            return "\(r.artist)|\(r.album)"
        }
        expectEqual(split("Jamie Rumley — Fade Away (Acoustic Single)", "Fade Away",
                          known: ("Fade Away", "Jamie Rumley", "Fade Away (Acoustic Single)")),
                    "Jamie Rumley|Fade Away (Acoustic Single)", "VOX 系统会话: 照最近一次读数拆")
        expectEqual(split("Mezzamo — Live — Everything you", "Happy Boy", known: ("Happy Boy", "Mezzamo — Live", "Everything you")),
                    "Mezzamo — Live|Everything you", "VOX 系统会话: 歌手名本身带「 — 」也照读数拆对")
        expectEqual(split("A — Live — 2020", "T", known: ("T", "A", "Live — 2020")), "A|Live — 2020",
                    "VOX 系统会话: 专辑名带「 — 」时照读数拆,不按最后一个分隔")
        expectEqual(split("Mezzamo — Live — Everything you", "Happy Boy", known: nil), "Mezzamo — Live|Everything you",
                    "VOX 系统会话: 没有读数时按最后一个「 — 」拆")
        expectEqual(split("A — B", "T", known: ("T", "A — B", "")), "A — B|", "VOX 系统会话: 读数里歌手就是这一整串(没有专辑)")
        expectEqual(split("Mezzamo", "Happy Boy", known: nil), "Mezzamo|", "VOX 系统会话: 没有专辑时只有歌手")
        expectEqual(split("Jamie Rumley — X", "Other", known: ("Fade Away", "Jamie Rumley", "X")), "Jamie Rumley|X",
                    "VOX 系统会话: 读数不是同一首时按分隔拆")
        expectEqual(V.systemArtistSeparator, " \u{2014} ", "VOX 系统会话: 分隔是前后带空格的 em dash")
        let system = MediaControlSnapshot.forReplay(title: "Fade Away", artist: "Jamie Rumley — Fade Away (Acoustic Single)",
                                                    duration: nil, elapsedTime: nil, playing: true,
                                                    bundleIdentifier: "com.coppertino.Vox", anchorElapsedTime: nil)
        let fixed = V.splittingSystemArtist(system)
        expectEqual("\(fixed?.artist ?? "")|\(fixed?.album ?? "")", "Jamie Rumley|Fade Away (Acoustic Single)",
                    "VOX 系统会话: 快照拆成歌手、专辑")
        let other = MediaControlSnapshot.forReplay(title: "T", artist: "A — B", duration: nil, elapsedTime: nil, playing: true,
                                                   bundleIdentifier: "com.apple.Music", anchorElapsedTime: nil)
        expectEqual(V.splittingSystemArtist(other)?.artist, "A — B", "VOX 系统会话: 别的播放器不动")
        let withAlbum = MediaControlSnapshot.forReplay(title: "T", artist: "A — B", album: "C", duration: nil, elapsedTime: nil,
                                                       playing: true, bundleIdentifier: "com.coppertino.Vox",
                                                       anchorElapsedTime: nil)
        expectEqual(V.splittingSystemArtist(withAlbum)?.artist, "A — B", "VOX 系统会话: 已经有专辑(脚本读数)不动")
    }

    // ---- 取封面那份载荷换成快照同一份身份 ----
    do {
        let known = (title: "Happy Boy", artist: "无标签 Mezzamo", path: Optional("/m/无标签 Mezzamo - Happy Boy.mp3"))
        let untagged = V.artworkIdentity(title: "无标签 mezzamo - happy boy.mp3", artist: " ", known: known)
        expectEqual("\(untagged.artist ?? "")|\(untagged.title ?? "")|\(untagged.path ?? "")",
                    "无标签 Mezzamo|Happy Boy|/m/无标签 Mezzamo - Happy Boy.mp3", "VOX 封面: 没写标签时按文件名认出是读数那首")
        let tagged = V.artworkIdentity(title: "Fade Away", artist: "Jamie Rumley — Single",
                                       known: (title: "Fade Away", artist: "Jamie Rumley", path: "/m/f.mp3"))
        expectEqual("\(tagged.artist ?? "")|\(tagged.path ?? "")", "Jamie Rumley|/m/f.mp3", "VOX 封面: 同一首用读数的歌手和文件")
        let stranger = V.artworkIdentity(title: "Other", artist: "B — Album", known: (title: "Fade Away", artist: "A", path: "/m/f.mp3"))
        expectEqual("\(stranger.artist ?? "")|\(stranger.path ?? "-")", "B|-", "VOX 封面: 不是读数那首只拆歌手、不给文件")
    }

    // ---- 循环与音量 ----
    do {
        typealias C = MusicPlaybackController
        expectEqual([0, 1, 2, 3].map { C.voxPlaybackMode(repeatState: $0) }, [.list, .repeatOne, .repeatAll, nil],
                    "VOX 循环: repeat state 0/1/2 → 列表 / 单曲 / 列表循环,别的值认不出")
        expectEqual(C.MusicPlaybackMode.allCases.map { C.voxRepeatState(for: $0) }, [0, nil, 1, 2],
                    "VOX 循环: 档位 → repeat state,随机没有")
        expectEqual(C.voxModeOptions.contains(.shuffle), false, "VOX 循环: 随机读不出,不给这颗键")
        expectEqual(C.voxModeOptions.canRepeat && C.voxModeOptions.contains(.repeatOne), true, "VOX 循环: 列表循环、单曲循环都有")
        expectEqual(C.supportsExtendedControls(.vox) && C.supportsRepeatOne(.vox) && !C.supportsFavorite(.vox), true,
                    "VOX 扩展控制: 有模式和音量、有单曲循环、没有喜欢")
    }

    // ---- 归档与判据 ----
    do {
        let b = PlaybackPlayer.vox.bundleIdentifier
        expectEqual(LocalPlaybackSource.positionSourceTier(forBundleID: b), .precise, "VOX 档位: AppleScript 位置,precise")
        expectEqual(PlaybackPlayer.vox.automationUse, .readsTrack, "VOX 权限: 曲目和位置整份靠脚本接口")
        expectEqual(TornTrackHold.arrivesWhole(bundle: b), true, "VOX 撕裂守卫: 整份读来,不按撕裂快照按住")
        expectEqual(LocalPlaybackSource.resumeReadingNeverLeads(bundleID: b), true,
                    "VOX 恢复: 脚本读数不会超前,恢复那一拍原样采信、不按冻结值加信号时长削")
        expectEqual(CoverArtReplacementGate.missingArtworkUsesMatchedCover(bundleID: b), true,
                    "VOX 封面: 文件没嵌封面时用匹配到的那张")
        expectEqual(CoverArtReplacementGate.systemNeverHasArtwork(bundleID: b), false, "VOX 封面: 嵌了封面系统那份带着")
        expectEqual(MediaControlClient.pollSnapshotTimeout(fallbackPlayer: .vox),
                    MediaControlClient.pollSnapshotTimeout(fallbackPlayer: .appleMusic), "VOX 超时: 有字典,用短的那档(同 Apple Music)")
    }

    // ---- 接线契约 ----
    do {
        let script = V.script
        expectEqual(sourceHas(script, "V.trackurl()"), true, "VOX 脚本: 当前文件用 JXA 的名字 trackurl")
        expectEqual(script.contains("V.trackUrl()"), false, "VOX 脚本: 写成 trackUrl 会报 -1708")
        let read = script.range(of: "reading.elapsedTime = V.currentTime()")
        let built = script.range(of: "const reading = {")
        expectEqual(read != nil && built != nil && read!.lowerBound > built!.lowerBound, true, "VOX 脚本: 位置最后读")
        expectEqual(sourceHas(script, "if (state !== 0 && state !== 1) return JSON.stringify(null);"), true,
                    "VOX 脚本: 停住(-1)当没在放")
        expectEqual(sourceHas(MediaControlClient.appleScriptServerScript, "vox: () =>"), true, "VOX 脚本: 常驻 osascript 认 vox 请求")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let client = source("LyrimuseCore/Local/MediaControlClient.swift")
        let adapted = sourceBody("private static func adaptedSnapshot(", in: client)
        expectEqual(sourceHas(adapted, "return fetchVoxSnapshot() ?? VoxPlayerInfo.splittingSystemArtist(mediaControl)"), true,
                    "VOX 接线: 整份顶替,拿不到时退回系统那份并拆开歌手专辑")
        let fetch = sourceBody("private static func fetchVoxSnapshot() -> MediaControlSnapshot? {", in: client)
        expectEqual(sourceHas(fetch, "VoxPlayerInfo.positionLagsTrackChange(previous: previous, current: VoxPlayerInfo.mark(reading))")
                    && sourceHas(fetch, "VoxPlayerInfo.remember(reading)"), true, "VOX 接线: 撕裂时重读,读完记下")
        let lost = sourceBody("private static func snapshotAfterFocusLost() -> MediaControlSnapshot? {", in: client)
        expectEqual(sourceHas(lost, "snapshot = VoxPlayerInfo.splittingSystemArtist(probed.snapshot)"), true,
                    "VOX 接线: 焦点回退按 bundle id 问到的那份也拆开歌手专辑")
        let artwork = sourceBody("public static func fetchArtworkExplained(", in: client)
        expectEqual(sourceHas(artwork, "VoxPlayerInfo.artworkIdentity(title: raw.title, artist: raw.artist)")
                    && sourceHas(artwork, "PlayerArtistFix.correctedTrackKey(bundle: bundleID, artist: keyArtist, title: keyTitle)"),
                    true, "VOX 接线: 封面的曲目标识用拆好的歌手")
        let probe = source("LyrimuseCore/Local/NowPlayingClientsProbe.swift")
        expectEqual(sourceHas(sourceBody("public static func artwork(forBundleID bundleID: String)", in: probe),
                              "VoxPlayerInfo.artworkIdentity(title: title, artist: artist)"), true,
                    "VOX 接线: 按 bundle id 取封面那条也换身份")
        let playback = source("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(sourceHas(playback, "? VoxPlayerInfo.currentFilePath(artist: snapshot.artist ?? \"\", title: snapshot.title ?? \"\")"),
                    true, "VOX 接线: 播放状态写当前文件,引擎据此读同名 .lrc 和内嵌歌词")
    }
}
