import Foundation
import LyrimuseCore

/// Audirvana:脚本读数的解法(斜杠也编码的地址、没写标签的文件、精确位置、整秒时长换文件时长)、封面归属、播放控制脚本、
/// 控制通路、接线契约。读数照真机读到的写法。
@MainActor
func runAudirvanaTests() {
    typealias I = AudirvanaPlayerInfo
    typealias C = MusicPlaybackController
    let at = Date(timeIntervalSince1970: 1_794_300_400)

    // ---- 当前地址 ----
    do {
        let real = "file://%2FUsers%2Fchenyuhao%2FMusic%2FLyrimuse%E6%B5%8B%E8%AF%95%2FMyGo%2F%E9%99%88%E5%A5%95%E8%BF%85%20-%20%E6%B5%AE%E5%A4%B8.mp3"
        expectEqual(I.filePath(fromTrackURL: real), "/Users/chenyuhao/Music/Lyrimuse测试/MyGo/陈奕迅 - 浮夸.mp3",
                    "Audirvana 地址: 斜杠也编码的那种整段解码")
        expectEqual(I.filePath(fromTrackURL: "file:///m/a%20b.flac"), "/m/a b.flac", "Audirvana 地址: 标准写法也认")
        expectEqual(I.filePath(fromTrackURL: "file://localhost/m/a.flac"), "/m/a.flac", "Audirvana 地址: 带 localhost 的也认")
        expectEqual([I.filePath(fromTrackURL: "https://streaming.qobuz.com/x"), I.filePath(fromTrackURL: ""),
                     I.filePath(fromTrackURL: nil), I.filePath(fromTrackURL: "file://")], [nil, nil, nil, nil],
                    "Audirvana 地址: 流媒体、空的、只有前缀的都不是本地文件")
    }

    // ---- 身份 ----
    do {
        let untagged = I.identity(title: "无标签 Mezzamo - Happy Boy", artist: "", album: "",
                                  filePath: "/m/无标签 Mezzamo - Happy Boy.mp3")
        expectEqual([untagged.title, untagged.artist, untagged.album], ["Happy Boy", "无标签 Mezzamo", ""],
                    "Audirvana 身份: 没写标签的文件按第一个「 - 」拆成歌手和歌名")
        let plain = I.identity(title: "MyGo Click A", artist: "", album: "", filePath: "/m/MyGo Click A.wav")
        expectEqual([plain.title, plain.artist], ["MyGo Click A", ""], "Audirvana 身份: 文件名里没有「 - 」就整个当歌名")
        let tagged = I.identity(title: "A - B", artist: "歌手", album: "专辑", filePath: "/m/A - B.mp3")
        expectEqual([tagged.title, tagged.artist, tagged.album], ["A - B", "歌手", "专辑"],
                    "Audirvana 身份: 有歌手的不拆")
        let renamed = I.identity(title: "Song - Title", artist: "", album: "", filePath: "/m/other.mp3")
        expectEqual([renamed.title, renamed.artist], ["Song - Title", ""],
                    "Audirvana 身份: 歌名不是文件名(写了歌名没写歌手)不拆")
    }

    // ---- 读数 ----
    do {
        func json(_ s: String) -> Data { Data(s.utf8) }
        let playing = I.reading(fromScriptOutput: json(#"{"title":"浮夸","artist":"陈奕迅","album":"Solidays 新曲+精选","duration":285,"playing":true,"url":"file://%2Fm%2Ffukua.mp3","position":3.726802721088}"#),
                                capturedAt: at, fileDuration: { $0 == "/m/fukua.mp3" ? 284.6 : nil })
        expectEqual(playing?.snapshot.title, "浮夸", "Audirvana 读数: 歌名")
        expectEqual(playing?.snapshot.album, "Solidays 新曲+精选", "Audirvana 读数: 专辑")
        expectEqual(playing?.snapshot.duration, 284.6, "Audirvana 读数: 整秒时长换成文件读出的精确时长")
        expectEqual(playing?.snapshot.elapsedTime, 3.726802721088, "Audirvana 读数: 位置原样用")
        expectEqual([playing?.snapshot.playing, playing?.snapshot.positionIsPrecise], [true, true],
                    "Audirvana 读数: 在放时位置标精确")
        expectEqual(playing?.snapshot.capturedAt, at, "Audirvana 读数: 记下读数时刻")
        expectEqual(playing?.snapshot.isMusicApp, true, "Audirvana 读数: 标成有效快照(poll 只收 isMusicApp 为 true 的)")
        expectEqual(playing?.snapshot.bundleIdentifier, "com.audirvana.Audirvana-Studio", "Audirvana 读数: 记成它报的")
        expectEqual(playing?.filePath, "/m/fukua.mp3", "Audirvana 读数: 带当前文件")
        let paused = I.reading(fromScriptOutput: json(#"{"title":"MyGo Click B","artist":"","album":"","duration":26,"playing":false,"url":"file://%2Fm%2FMyGo%20Click%20B.wav","position":5.636281179138}"#),
                               capturedAt: at, fileDuration: { _ in nil })
        expectEqual([paused?.snapshot.playing, paused?.snapshot.positionIsPrecise], [false, nil],
                    "Audirvana 读数: 暂停着不标精确")
        expectEqual([paused?.snapshot.artist, paused?.snapshot.album], [nil, nil], "Audirvana 读数: 空歌手、空专辑交 nil")
        expectEqual(paused?.snapshot.duration, 26, "Audirvana 读数: 文件读不到时长就用它报的整秒")
        let farFile = I.reading(fromScriptOutput: json(#"{"title":"X","artist":"Y","album":"","duration":200,"playing":true,"url":"file:///m/x.mp3","position":1}"#),
                                capturedAt: at, fileDuration: { _ in 120 })
        expectEqual(farFile?.snapshot.duration, 200, "Audirvana 读数: 文件时长跟它报的对不上时照用它报的")
        expectEqual(I.reading(fromScriptOutput: json("null"), capturedAt: at) == nil, true, "Audirvana 读数: 停住、没在跑回 null")
        expectEqual(I.reading(fromScriptOutput: json(#"{"title":"X","playing":true,"url":""}"#), capturedAt: at) == nil, true,
                    "Audirvana 读数: 没有位置不认")
        expectEqual(I.reading(fromScriptOutput: json(#"{"title":" ","playing":true,"url":"","position":1}"#), capturedAt: at) == nil,
                    true, "Audirvana 读数: 歌名空白不认")
        let stream = I.reading(fromScriptOutput: json(#"{"title":"Song","artist":"A","album":"","duration":0,"playing":true,"url":"https://x/y","position":2}"#),
                               capturedAt: at)
        expectEqual([stream?.filePath == nil, stream?.snapshot.duration == nil], [true, true],
                    "Audirvana 读数: 流媒体没有文件,时长 0 当没报")
    }

    // ---- 卡住时退避 ----
    do {
        expectEqual([I.stalled(succeeded: false, elapsed: 10.0, timeout: 5), I.stalled(succeeded: false, elapsed: 4.6, timeout: 5),
                     I.stalled(succeeded: false, elapsed: 0.2, timeout: 5), I.stalled(succeeded: true, elapsed: 6, timeout: 5)],
                    [true, true, false, false],
                    "Audirvana 退避: 没问成又等到超时才算卡住;很快回 null(没在跑、停住)、慢但问成了都不算")
        expectEqual(I.stallBackoffSecs >= 10, true, "Audirvana 退避: 卡住后隔一段再问,别每拍都等满超时")
    }

    // ---- 封面归属 ----
    do {
        expectEqual([I.artworkBelongs(rawTitle: "浮夸", to: ("浮夸", "/m/a.mp3")),
                     I.artworkBelongs(rawTitle: "无标签 Mezzamo - Happy Boy", to: ("Happy Boy", "/m/无标签 Mezzamo - Happy Boy.mp3")),
                     I.artworkBelongs(rawTitle: "别的歌", to: ("浮夸", "/m/a.mp3")),
                     I.artworkBelongs(rawTitle: "", to: ("浮夸", nil))], [true, true, false, false],
                    "Audirvana 封面: 脚本回的歌名是记下的这首(拆过的按文件名认)才用,换了歌、没有图都不用")
        let origin = "com.audirvana.Audirvana-Origin"
        expectEqual(I.artworkScriptLines(appID: origin).contains("if application id \"\(origin)\" is not running then return \"\""),
                    true, "Audirvana 封面: 先判在不在跑,不把它拉起来")
        expectEqual(I.artworkScriptLines(appID: origin).contains("tell application id \"\(origin)\""), true,
                    "Audirvana 封面: 问的是此刻在跑的那个版本(Origin)")
    }

    // ---- 播放控制 ----
    do {
        let tell = "if application id \"com.audirvana.Audirvana-Studio\" is not running then return \"\"\ntell application id \"com.audirvana.Audirvana-Studio\" to "
        expectEqual([I.controlScript("toggle-play-pause", arguments: []), I.controlScript("play", arguments: []),
                     I.controlScript("pause", arguments: []), I.controlScript("next-track", arguments: []),
                     I.controlScript("previous-track", arguments: [])],
                    [tell + "playpause", tell + "resume", tell + "pause", tell + "next track", tell + "previous track"],
                    "Audirvana 控制: 各指令对上字典里的命令")
        expectEqual(I.controlScript("seek", arguments: ["21.5"]), tell + "set player position to 21.500",
                    "Audirvana 控制: 跳转写带小数的秒数")
        expectEqual(I.controlScript("pause", arguments: [], appID: "com.audirvana.Audirvana-Origin"),
                    "if application id \"com.audirvana.Audirvana-Origin\" is not running then return \"\"\ntell application id \"com.audirvana.Audirvana-Origin\" to pause",
                    "Audirvana 控制: 开着的是 Origin 就发给 Origin,先判在不在跑")
        expectEqual(I.editionBundleIDs, ["com.audirvana.Audirvana-Studio", "com.audirvana.Audirvana-Origin"],
                    "Audirvana 版本: Studio、Origin 两个都认,Studio 在前")
        expectEqual(PlayerBundleAliases.canonical("com.audirvana.Audirvana-Origin"), "com.audirvana.Audirvana-Studio",
                    "Audirvana 版本: Origin 登记成别名,找进程、判装没装、启动时也认它")
        expectEqual(I.script.contains("for (const id of [\"com.audirvana.Audirvana-Studio\", \"com.audirvana.Audirvana-Origin\"])"), true,
                    "Audirvana 版本: 读数脚本两个版本都找")
        expectEqual([I.controlScript("seek", arguments: []), I.controlScript("seek", arguments: ["-1"]),
                     I.controlScript("seek", arguments: ["nan"]), I.controlScript("set-shuffle", arguments: [])],
                    [nil, nil, nil, nil], "Audirvana 控制: 没给秒数、负数、非数、字典里没有的动作都不发")
        expectEqual(C.controlRoute(exclusivelyAppleMusic: false, focusFallback: .audirvana, mediaControlCommand: "seek"),
                    .audirvanaScript, "Audirvana 控制: 顶替系统那边时跳转也发它的脚本")
        expectEqual(C.controlRoute(exclusivelyAppleMusic: false, focusFallback: .audirvana, mediaControlCommand: "toggle-play-pause"),
                    .audirvanaScript, "Audirvana 控制: 播放暂停发它的脚本")
        expectEqual(C.controlRoute(exclusivelyAppleMusic: false, focusFallback: .audirvana, mediaControlCommand: "set-shuffle"),
                    .mediaControl, "Audirvana 控制: 它没有的动作不走它的脚本")
        expectEqual([MediaControlClient.controlScriptTarget(kasetPreferred: false, lxMusicPreferred: false, audirvanaPreferred: true,
                                                            holdingAcrossGap: false, scriptTarget: nil),
                     MediaControlClient.controlScriptTarget(kasetPreferred: false, lxMusicPreferred: false, audirvanaPreferred: true,
                                                            holdingAcrossGap: true, scriptTarget: .spotify)],
                    [.audirvana, .spotify], "Audirvana 控制: 顶替时发给它;切歌间隙保持着别家时照回退目标发")
    }

    // ---- 接线契约 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func code(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let client = code("LyrimuseCore/Local/MediaControlClient.swift")
        let body = sourceBody("private static func preferringAudirvana(", in: client)
        expectEqual(sourceHas(body, "if !asked, AudirvanaPlayerInfo.runningBundleID() != nil, let reading = readAudirvanaSnapshot(),"),
                    true, "Audirvana 契约: 只在它开着时才发 Apple Event(不拉起它、不凭空弹权限框)")
        expectEqual(sourceHas(body, "if wanted, found?.playing != true, found?.bundleIdentifier != AudirvanaPlayerInfo.bundleID {"),
                    true, "Audirvana 契约: 系统那边有别家在放就不问它")
        expectEqual(sourceHas(client, "let withAudirvana = preferringAudirvana(withKaset, wanted: audirvanaWanted)")
                        && sourceHas(client, "if !audirvanaWanted { forgetAudirvanaPreference() }"),
                    true, "Audirvana 契约: 多选勾了它也问,设置不认它时清掉顶替记录")
        let read = sourceBody("private static func readAudirvanaSnapshot(", in: client)
        expectEqual(sourceHas(read, "guard !backingOff, !SourceKnockout.isOut(.audirvanaScript) else { return nil }")
                        && sourceHas(read, "audirvanaRetryAt = Date().addingTimeInterval(AudirvanaPlayerInfo.stallBackoffSecs)"),
                    true, "Audirvana 契约: 问它卡住后退避一段,不让常驻 osascript 每拍被杀重启")
        expectEqual(sourceHas(client, "audirvana: () => \\(AudirvanaPlayerInfo.script),"), true,
                    "Audirvana 契约: 读数走常驻 osascript")
        expectEqual(sourceHas(sourceBody("public static func fetchSnapshotWithProvenance(", in: client), "audirvanaAskedThisRound = false"),
                    true, "Audirvana 契约: 每拍入口清零「问过了」")
        expectEqual(I.script.contains("A.eventTypesReported = \"TrackChanged\"")
                        && I.script.contains("JSON.stringify(null)") && I.script.contains("runningApplicationsWithBundleIdentifier"),
                    true, "Audirvana 契约: 脚本先判在不在跑,每个进程第一次读时打开换歌通知")
        let source = code("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(sourceHas(source, "forName: NSNotification.Name(AudirvanaPlayerInfo.noticeName),")
                        && sourceHas(source, "guard !SourceKnockout.isOut(.audirvanaNotice) else { return }\nMainActor.assumeIsolated { self?.handlePlayerInfoChanged(freezeExtrapolation: false, stateSignal: false) }"),
                    true, "Audirvana 契约: 通知只当提前读一次的信号(换歌那条报的状态不可信)")
        expectEqual(sourceHas(source, ": bundleID == AudirvanaPlayerInfo.bundleID\n? AudirvanaPlayerInfo.currentFilePath("), true,
                    "Audirvana 契约: 播放状态带上当前文件(引擎读同名 .lrc 和内嵌歌词)")
        expectEqual(sourceHas(source, "guard let result = MediaControlClient.audirvanaArtwork(forTrackKey: expectedKey) else {"), true,
                    "Audirvana 契约: 封面用它脚本给的那张")
        expectEqual([LocalPlaybackSource.resumeReadingNeverLeads(bundleID: I.bundleID), LocalPlaybackSource.learnsAnchorLag(bundleID: I.bundleID),
                     CoverArtReplacementGate.missingArtworkUsesMatchedCover(bundleID: I.bundleID)], [true, false, true],
                    "Audirvana 判据: 恢复那一拍原样采信、不学锚点滞后、没封面时用匹配到的那张")
        expectEqual(PlaybackPlayer.audirvana.automationUse, .readsTrack, "Audirvana 判据: 曲目整份靠自动化权限")
    }

    // ---- 随机、循环、音量(主窗口播放条上的控件) ----
    do {
        typealias X = AudirvanaControls
        expectEqual([X.shuffleOn(description: "Shuffle Playback Button: Active"),
                     X.shuffleOn(description: "Shuffle Playback Button: Not active"),
                     X.shuffleOn(description: "Shuffle Playback Button"),
                     X.shuffleOn(description: "Loop Playback Button: Not active")], [true, false, nil, nil],
                    "Audirvana 随机: 按描述后缀认开关,「Not active」也以「Active」结尾、先判它")
        expectEqual([X.loop(description: "Loop Playback Button: Not active"),
                     X.loop(description: "Loop Playback Button: Set to Repeat All"),
                     X.loop(description: "Loop Playback Button: Set to Repeat One"),
                     X.loop(description: "Loop Playback Button: Something"),
                     X.loop(description: "Shuffle Playback Button: Not active")], [.off, .all, .one, nil, nil],
                    "Audirvana 循环: 三档按描述后缀认,认不出的为 nil")
        let order: [X.Loop] = [.off, .all, .one]
        var presses: [Int] = []
        for from in order { for to in order { presses.append(X.presses(from: from, to: to)) } }
        expectEqual(presses, [0, 1, 2, 2, 0, 1, 1, 2, 0], "Audirvana 循环: 按一下换一档,三档轮转")
        expectEqual([X.mode(shuffle: false, loop: .off), X.mode(shuffle: false, loop: .all), X.mode(shuffle: false, loop: .one),
                     X.mode(shuffle: true, loop: .off), X.mode(shuffle: true, loop: .all)],
                    [.list, .repeatAll, .repeatOne, .shuffle, .shuffle],
                    "Audirvana 模式: 随机开着就是随机,否则按循环档")
        let roundTrip = C.MusicPlaybackMode.allCases.map { m -> C.MusicPlaybackMode in
            let t = X.target(for: m)
            return X.mode(shuffle: t.shuffle, loop: t.loop)
        }
        expectEqual(roundTrip, C.MusicPlaybackMode.allCases, "Audirvana 模式: 切到哪一档读回来就是哪一档")
        expectEqual([X.target(for: .repeatAll).shuffle, X.target(for: .shuffle).loop == .off], [false, true],
                    "Audirvana 模式: 点亮循环就关随机,选随机就关循环")
        expectEqual(C.supportsExtendedControls(.audirvana) && C.supportsRepeatOne(.audirvana) && !C.supportsFavorite(.audirvana),
                    true, "Audirvana 能力: 随机、两种循环、音量,没有喜欢(收藏键按了不生效)")
        expectEqual(PlaybackPlayer.audirvana.accessibilityUse, .adjustsModeAndVolume,
                    "Audirvana 权限: 只为随机、循环、音量要辅助功能,播放控制走脚本")
        let controller = String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("LyrimuseCore/Local/MusicPlaybackController.swift"))) ?? Data(), as: UTF8.self)
        expectEqual(sourceHas(sourceBody("public static func setPlaybackMode(", in: controller), "case .audirvana:\nreturn AudirvanaControls.setMode(mode)")
                        && sourceHas(sourceBody("public static func setSoundVolume(", in: controller), "case .audirvana:\nreturn AudirvanaControls.setVolume(v)")
                        && sourceHas(sourceBody("public static func soundVolume(", in: controller), "case .audirvana:\nreturn AudirvanaControls.readVolume()")
                        && sourceHas(sourceBody("public static func playbackMode(", in: controller), "case .audirvana:\nreturn AudirvanaControls.readMode()"),
                    true, "Audirvana 契约: 模式、音量的读写都走 AudirvanaControls")
        let controls = String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("LyrimuseCore/Local/AudirvanaControls.swift"))) ?? Data(), as: UTF8.self)
        expectEqual(sourceHas(controls, "== \"MainWindow\" {") && sourceHas(controls, "AudirvanaPlayerInfo.runningBundleID()"),
                    true, "Audirvana 契约: 只找在跑的那个版本的主窗口")
        expectEqual(sourceHas(sourceBody("public static func setMode(", in: controls),
                              "return shuffleOn(description: description(shuffleKey)) == want.shuffle && loop(description: description(loopKey)) == want.loop"),
                    true, "Audirvana 契约: 按完读回描述到了目标档才算成")
    }
}
