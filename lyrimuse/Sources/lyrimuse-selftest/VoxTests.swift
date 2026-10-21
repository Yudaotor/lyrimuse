import Foundation
import LyrimuseCore

/// VOX:AppleScript 读数的解读、没写标签的文件名、乱码、精确时长、换歌那一拍的撕裂、系统那份「歌手 — 专辑」的拆法、
/// 脚本读不到时的退路(系统那份的锚点、按开着的文件认曲目、脚本封面、暂停时的轮询)、循环与音量、接线契约。读数样例照真机输出的形状造(地址是 `file:/…` 单斜杠、百分号编码,总时长整秒)。
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
        expectEqual(sourceHas(adapted, "return fetchVoxSnapshot() ?? VoxPlayerInfo.systemFallback(mediaControl)"), true,
                    "VOX 接线: 整份顶替,拿不到时退回系统那份、按开着的文件认这一首")
        let fetch = sourceBody("private static func fetchVoxSnapshot() -> MediaControlSnapshot? {", in: client)
        expectEqual(sourceHas(fetch, "VoxPlayerInfo.positionLagsTrackChange(previous: previous, current: VoxPlayerInfo.mark(reading))")
                    && sourceHas(fetch, "VoxPlayerInfo.remember(reading)"), true, "VOX 接线: 撕裂时重读,读完记下")
        let lost = sourceBody("private static func snapshotAfterFocusLost() -> MediaControlSnapshot? {", in: client)
        expectEqual(sourceHas(lost, "snapshot = VoxPlayerInfo.systemFallback(VoxPlayerInfo.probedSnapshot(")
                    && sourceHas(lost, "probed.snapshot, anchorTimestamp: probed.anchor.timestamp, pid: probed.anchor.processIdentifier, now: now))"),
                    true, "VOX 接线: 焦点回退按 bundle id 问到的那份补位置、按开着的文件认这一首")
        expectEqual(sourceHas(sourceBody("private static func readVox() -> VoxPlayerInfo.Reading? {", in: client),
                              "guard !SourceKnockout.isOut(.voxScript) else { return nil }"), true,
                    "VOX 接线: 拔腿开关能关掉脚本读数")
        let decode = sourceBody("init(from decoder: Decoder) throws {", in: sourceBody("private struct RawPayload: Decodable {", in: client))
        expectEqual(sourceHas(decode, "let anchor = VoxPlayerInfo.systemAnchor(")
                    && sourceHas(decode, "elapsedTime = anchor.elapsed") && sourceHas(decode, "elapsedTimeNow = anchor.elapsedNow")
                    && sourceHas(decode, "playbackRate = anchor.rate"), true, "VOX 接线: 系统那份解码时补锚点")
        let artwork = sourceBody("public static func fetchArtworkExplained(", in: client)
        expectEqual(sourceHas(artwork, "VoxPlayerInfo.artworkIdentity(title: raw.title, artist: raw.artist)")
                    && sourceHas(artwork, "PlayerArtistFix.correctedTrackKey(bundle: bundleID, artist: keyArtist, title: keyTitle)"),
                    true, "VOX 接线: 封面的曲目标识用拆好的歌手")
        expectEqual(sourceHas(artwork, "if channelFallback == .vox, let art = voxArtwork(tryingFolder: true) { return (art, nil) }")
                    && sourceHas(artwork, "if target.bundleID == VoxPlayerInfo.bundleID, let art = voxArtwork(tryingFolder: true) { return (art, nil) }")
                    && sourceHas(artwork, "if bundleID == VoxPlayerInfo.bundleID, let art = voxArtwork(tryingFolder: false) { return (art, nil) }"),
                    true, "VOX 接线: 通道坏了、焦点被占、系统那份没带图,封面都退到脚本那张和同目录的图")
        expectEqual(sourceHas(artwork, "guard !SourceKnockout.isOut(.systemArtwork), let imageData = artworkImageData(base64: raw.artworkData) else {"),
                    true, "VOX 接线: 拔腿开关能关掉系统那份封面")
        let probe = source("LyrimuseCore/Local/NowPlayingClientsProbe.swift")
        expectEqual(sourceHas(sourceBody("public static func artwork(forBundleID bundleID: String)", in: probe),
                              "VoxPlayerInfo.artworkIdentity(title: title, artist: artist)"), true,
                    "VOX 接线: 按 bundle id 取封面那条也换身份")
        let playback = source("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(sourceHas(playback, "? VoxPlayerInfo.currentFilePath(artist: snapshot.artist ?? \"\", title: snapshot.title ?? \"\")"),
                    true, "VOX 接线: 播放状态写当前文件,引擎据此读同名 .lrc 和内嵌歌词")
        let observe = sourceBody("private func startObservingPlayerInfoNotification() {", in: playback)
        expectEqual(sourceHas(observe, "forName: NSNotification.Name(VoxPlayerInfo.trackChangedNotification),")
                    && sourceHas(observe, "guard !SourceKnockout.isOut(.voxNotice) else { return }")
                    && sourceHas(observe, "self?.handlePlayerInfoChanged(freezeExtrapolation: false, stateSignal: false)"),
                    true, "VOX 接线: 换歌通知只当提前 poll 一次,不冻结外推")
        expectEqual(sourceHas(sourceBody("private func startStreamWatcher() {", in: playback),
                              "guard !SourceKnockout.isOut(.streamEvents) else { return }"), true, "VOX 接线: 拔腿开关能关掉事件流信号")
        expectEqual(sourceHas(sourceBody("private var desiredPollInterval: TimeInterval {", in: playback),
                              "Self.pollsFastWhilePaused(bundleID: lastSnapshot?.bundleIdentifier,"), true,
                    "VOX 接线: 暂停时的轮询档看 pollsFastWhilePaused")
        expectEqual(sourceHas(playback, "if newIsPlayingNow { pausedObservedAt = nil } else if pausedObservedAt == nil { pausedObservedAt = Date() }"),
                    true, "VOX 接线: 记下这一段暂停从什么时候起")
    }

    // ---- 系统那份的锚点(脚本读不到时位置靠它) ----
    do {
        func anchor(_ playing: Bool?, _ elapsed: Double?, _ now: Double?, _ rate: Double?, ts: Bool = true,
                    bundle: String = "com.coppertino.Vox") -> String {
            let a = V.systemAnchor(bundleID: bundle, playing: playing, elapsed: elapsed, elapsedNow: now, rate: rate, hasTimestamp: ts)
            func f(_ x: Double?) -> String { x.map { String($0) } ?? "nil" }
            return "\(f(a.elapsed))|\(f(a.elapsedNow))|\(f(a.rate))"
        }
        expectEqual(anchor(true, nil, nil, 1), "0.5|nil|1.0", "VOX 系统锚点: 开播 / 自然连播没报位置 → 那个时刻按已经放了 0.5 秒起算")
        expectEqual(anchor(true, nil, nil, 0), "0.5|nil|1.0", "VOX 系统锚点: 开播首帧速率 0 也当 1")
        expectEqual(anchor(true, nil, nil, 1, ts: false), "nil|nil|1.0", "VOX 系统锚点: 连时刻都没有不编")
        expectEqual(anchor(true, 8.26, 8.26, 0), "8.26|nil|1.0", "VOX 系统锚点: 恢复那份速率 0 → 当 1,冻结的外推值作废")
        expectEqual(anchor(true, 60, 61.5, 1), "60.0|61.5|1.0", "VOX 系统锚点: 跳转后那份正常,原样")
        expectEqual(anchor(false, 65.68, 70, 1), "65.68|70.0|1.0", "VOX 系统锚点: 暂停着原样")
        expectEqual(anchor(true, nil, nil, 0, bundle: "com.apple.Music"), "nil|nil|0.0", "VOX 系统锚点: 别的播放器原样")
    }

    // ---- 脚本读不到时按开着的文件认曲目 ----
    do {
        expectEqual(V.fileMatchesSystemTitle("Marjoram", tagsTitle: "Marjoram", fileName: "2010-09-Accident-Marjoram.mp3"), true,
                    "VOX 认文件: 歌名等于标签里的歌名")
        expectEqual(V.fileMatchesSystemTitle("happy boy.mp3", tagsTitle: "", fileName: "Happy Boy.mp3"), true,
                    "VOX 认文件: 没写标签,歌名是文件名的全小写")
        expectEqual(V.fileMatchesSystemTitle("\u{B4}\u{B8}\u{A4}\u{D1}", tagsTitle: "晴天", fileName: "b.mp3"), true,
                    "VOX 认文件: 系统那份是乱码、文件标签读成了正字,还原后对上")
        expectEqual(V.fileMatchesSystemTitle("Marjoram", tagsTitle: "Кибернетичекая эра", fileName: "next.mp3"), false,
                    "VOX 认文件: 提前打开的下一首不认")
        expectEqual(V.fileMatchesSystemTitle("", tagsTitle: "", fileName: ".mp3"), false, "VOX 认文件: 空歌名不认")

        func snap(_ json: String) -> MediaControlSnapshot {
            try! JSONDecoder().decode(MediaControlSnapshot.self, from: Data(json.utf8))
        }
        func line(_ s: MediaControlSnapshot) -> String { "\(s.artist ?? "")|\(s.title ?? "")|\(s.album ?? "")|\(s.duration.map { String($0) } ?? "nil")" }
        let tagged = snap(#"{"title":"Marjoram","artist":"Accident — Free Music Charts 2010","playing":true,"bundleIdentifier":"com.coppertino.Vox"}"#)
        let file = (path: "/m/2010-09-Accident-Marjoram.mp3",
                    tags: LocalAudioFileTags(title: "Marjoram", artist: "Accident", album: "Free Music Charts 2010", duration: 294.56))
        expectEqual(line(V.systemFallback(tagged, file: file)), "Accident|Marjoram|Free Music Charts 2010|294.56",
                    "VOX 退路: 按文件标签拆开歌手专辑,时长取文件的")
        let dashArtist = snap(#"{"title":"Song","artist":"A — Live — 2020","playing":true,"bundleIdentifier":"com.coppertino.Vox"}"#)
        let dashFile = (path: "/m/s.mp3", tags: LocalAudioFileTags(title: "Song", artist: "A — Live", album: "2020", duration: nil))
        expectEqual(line(V.systemFallback(dashArtist, file: dashFile)), "A — Live|Song|2020|nil",
                    "VOX 退路: 歌手名带「 — 」时按文件标签拆对")
        let dashAlbumFile = (path: "/m/s.mp3", tags: LocalAudioFileTags(title: "Song", artist: "A", album: "Live — 2020", duration: nil))
        expectEqual(line(V.systemFallback(dashArtist, file: dashAlbumFile)), "A|Song|Live — 2020|nil",
                    "VOX 退路: 专辑名带「 — 」时也按文件标签拆对(只按最后一个分隔拆会拆错)")
        let untagged = snap(#"{"title":"无标签 mezzamo - happy boy.mp3","artist":"","playing":true,"bundleIdentifier":"com.coppertino.Vox"}"#)
        let untaggedFile = (path: "/m/无标签 Mezzamo - Happy Boy.mp3", tags: LocalAudioFileTags(title: "", artist: "", album: "", duration: 61))
        let fromScript = V.identity(title: "无标签 mezzamo - happy boy.mp3", artist: "", album: "", filePath: untaggedFile.path)
        expectEqual(line(V.systemFallback(untagged, file: untaggedFile)), "\(fromScript.artist)|\(fromScript.title)|\(fromScript.album)|61.0",
                    "VOX 退路: 没写标签的文件跟脚本那条路认成同一份歌名歌手")

        let t = 1_792_599_144.15
        let probed = snap(#"{"title":"Marjoram","artist":"Accident","playing":true,"playbackRate":1,"bundleIdentifier":"com.coppertino.Vox"}"#)
        let clocked = V.probedSnapshot(probed, anchorTimestamp: t, pid: 22582, now: Date(timeIntervalSince1970: t + 5))
        expectEqual(clocked.elapsedTime.map { abs($0 - 5 - V.systemStartLeadSecs) < 0.001 }, true, "VOX 退路: 单问到的那份没报位置,按开播时刻起算、补上开播时刻晚的那一截")
        expectEqual(clocked.processIdentifier, 22582, "VOX 退路: 进程号从锚点补上")
        let other = snap(#"{"title":"x","playing":true,"bundleIdentifier":"com.apple.Music"}"#)
        expectEqual(V.probedSnapshot(other, anchorTimestamp: t, pid: 1, now: Date(timeIntervalSince1970: t + 5)).elapsedTime == nil,
                    true, "VOX 退路: 别的播放器原样")
    }

    // ---- 脚本里的封面、暂停时的轮询 ----
    do {
        expectEqual(V.artworkBelongs(rawTitle: "Marjoram", to: ("Marjoram", "/m/a.mp3")), true, "VOX 脚本封面: 同一首")
        expectEqual(V.artworkBelongs(rawTitle: "happy boy.mp3", to: ("Happy Boy", "/m/Happy Boy.mp3")), true,
                    "VOX 脚本封面: 没写标签,脚本报的是文件名全小写")
        expectEqual(V.artworkBelongs(rawTitle: "Next", to: ("Marjoram", "/m/a.mp3")), false, "VOX 脚本封面: 已经换歌了不要")
        expectEqual(V.artworkBelongs(rawTitle: "", to: ("Marjoram", nil)), false, "VOX 脚本封面: 没在跑 / 没有图")
        expectEqual(sourceHas(V.artworkScriptLines.joined(separator: "\n"), "is not running then return"), true,
                    "VOX 脚本封面: 先判在不在跑,不把它拉起来")

        typealias L = LocalPlaybackSource
        let vox = "com.coppertino.Vox"
        expectEqual(L.pollsFastWhilePaused(bundleID: vox, pausedFor: 5), true, "VOX 暂停轮询: 刚暂停按播放档问,事件流漏了也 2 秒内认出恢复")
        expectEqual(L.pollsFastWhilePaused(bundleID: vox, pausedFor: L.fastPausedPollWindow + 1), false, "VOX 暂停轮询: 停久了退回暂停档")
        expectEqual(L.pollsFastWhilePaused(bundleID: vox, pausedFor: nil), false, "VOX 暂停轮询: 没在暂停")
        expectEqual(L.pollsFastWhilePaused(bundleID: "com.apple.Music", pausedFor: 5), false, "VOX 暂停轮询: 别的播放器有自己的通知,不动")
    }
}
