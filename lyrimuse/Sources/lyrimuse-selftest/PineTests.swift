import Foundation
import LyrimuseCore

/// Pine Player:系统那份歌手一栏的拆法、按开着的文件认曲目、整秒锚点换成准的位置(开播两份锚点、暂停恢复接上、进度条校准)、
/// 失焦时按快捷键认菜单项、接线契约。锚点与进度条跳格的时刻照真机录到的数(咔哒文件 2 秒一声,真起播在 935.206)。
@MainActor
func runPineTests() {
    typealias P = PinePlayerInfo
    typealias H = PinePlayhead

    // ---- 系统那份该是什么样 ----
    do {
        func tags(_ title: String, _ artist: String = "", _ album: String = "") -> LocalAudioFileTags {
            LocalAudioFileTags(title: title, artist: artist, album: album, duration: 40)
        }
        func fields(_ t: LocalAudioFileTags, _ name: String = "x.mp3") -> String {
            let f = P.systemFields(tags: t, fileName: name)
            return "\(f.title)|\(f.artist ?? "nil")"
        }
        expectEqual(fields(tags("Marjoram", "Accident", "Vert Bleu Noir")), "Marjoram|Accident\u{2219}Vert Bleu Noir",
                    "Pine 系统那份: 有专辑时拼成「歌手∙专辑」")
        expectEqual(fields(tags("Happy Boy", "Mezzamo")), "Happy Boy|Mezzamo", "Pine 系统那份: 没专辑只有歌手")
        expectEqual(fields(tags("Happy Boy")), "Happy Boy|Happy Boy", "Pine 系统那份: 没写歌手时歌手一栏填歌名")
        expectEqual(fields(tags(""), "无标签 Mezzamo - Happy Boy.mp3"), "无标签 Mezzamo - Happy Boy.mp3| ",
                    "Pine 系统那份: 没写标签时歌名是文件名、歌手一栏是空格")
        expectEqual(fields(tags("", "Mezzamo"), "a.mp3"), "a.mp3|nil", "Pine 系统那份: 只写了歌手的不定歌手一栏")
    }

    // ---- 在开着的文件里挑 ----
    do {
        let leaked: [(fileName: String, tags: LocalAudioFileTags)] = [
            ("只有歌名.mp3", LocalAudioFileTags(title: "Happy Boy", artist: "", album: "", duration: 40)),
            ("无标签 Mezzamo - Happy Boy.mp3", LocalAudioFileTags(title: "", artist: "", album: "", duration: 40)),
            ("有歌手没专辑.mp3", LocalAudioFileTags(title: "Happy Boy", artist: "Mezzamo", album: "", duration: 40)),
            ("歌手带破折号.mp3", LocalAudioFileTags(title: "Happy Boy", artist: "Mezzamo — Live", album: "Everything you", duration: 40)),
            ("big5-a.mp3", LocalAudioFileTags(title: "\u{C1}c\u{C5}\u{E9}\u{BA}q\u{A6}W\u{B4}\u{FA}\u{B8}\u{D5}",
                                              artist: "\u{B4}\u{FA}\u{B8}\u{D5}\u{BA}q\u{A4}\u{E2}", album: "", duration: 40)),
        ]
        expectEqual(P.pickFile(title: "Happy Boy", artist: "Mezzamo — Live\u{2219}Everything you", candidates: leaked), 3,
                    "Pine 挑文件: 同名几首里按歌手一栏认出带专辑的那首")
        expectEqual(P.pickFile(title: "Happy Boy", artist: "Mezzamo", candidates: leaked), 2, "Pine 挑文件: 只有歌手的那首")
        expectEqual(P.pickFile(title: "Happy Boy", artist: "Happy Boy", candidates: leaked), 0, "Pine 挑文件: 歌手一栏是歌名的那首")
        expectEqual(P.pickFile(title: "无标签 Mezzamo - Happy Boy.mp3", artist: " ", candidates: leaked), 1, "Pine 挑文件: 没写标签按文件名")
        expectEqual(P.pickFile(title: "\u{C1}c\u{C5}\u{E9}\u{BA}q\u{A6}W\u{B4}\u{FA}\u{B8}\u{D5}",
                               artist: "\u{B4}\u{FA}\u{B8}\u{D5}\u{BA}q\u{A4}\u{E2}", candidates: leaked), 4, "Pine 挑文件: 乱码原样比得上")
        expectEqual(P.pickFile(title: "Happy Boy", artist: "Someone Else", candidates: leaked), nil,
                    "Pine 挑文件: 歌手一栏都对不上、同名的又不止一个,不猜")
        expectEqual(P.pickFile(title: "Marjoram", artist: "Accident", candidates: [
            ("m.mp3", LocalAudioFileTags(title: "Marjoram", artist: "Accident", album: "Vert Bleu Noir", duration: 294)),
        ]), 0, "Pine 挑文件: 歌手一栏对不上但同名的只有一个,就是它")
    }

    // ---- 身份 ----
    do {
        func id(_ r: (title: String, artist: String, album: String)) -> String { "\(r.artist)|\(r.title)|\(r.album)" }
        expectEqual(id(P.identity(title: "Marjoram", artist: "Accident\u{2219}Vert Bleu Noir")), "Accident|Marjoram|Vert Bleu Noir",
                    "Pine 身份: 没找到文件时按「∙」拆出专辑")
        expectEqual(id(P.identity(title: "Happy Boy", artist: "Mezzamo — Live\u{2219}Everything you")),
                    "Mezzamo — Live|Happy Boy|Everything you", "Pine 身份: 歌手名里的「 — 」原样留着")
        expectEqual(id(P.identity(title: "Happy Boy", artist: "Happy Boy")), "|Happy Boy|", "Pine 身份: 歌手一栏是歌名 = 没写歌手")
        expectEqual(id(P.identity(title: "无标签 Mezzamo - Happy Boy.mp3", artist: " ")), "无标签 Mezzamo|Happy Boy|",
                    "Pine 身份: 没写标签按文件名去扩展名、按「 - 」拆")
        expectEqual(id(P.identity(title: "Track08.mp3", artist: " ")), "|Track08|", "Pine 身份: 没写标签、没有「 - 」")
        expectEqual(id(P.identity(title: "\u{C1}c\u{C5}\u{E9}\u{BA}q\u{A6}W\u{B4}\u{FA}\u{B8}\u{D5}",
                                  artist: "\u{B4}\u{FA}\u{B8}\u{D5}\u{BA}q\u{A4}\u{E2}")), "測試歌手|繁體歌名測試|",
                    "Pine 身份: Big5 乱码还原")
        let file = P.identity(tags: LocalAudioFileTags(title: "Happy Boy", artist: "", album: "", duration: 40), fileName: "只有歌名.mp3")
        expectEqual(id(file), id(P.identity(title: "Happy Boy", artist: "Happy Boy")), "Pine 身份: 按文件认和只拆这一栏写出同一份")
        let untagged = P.identity(tags: LocalAudioFileTags(title: "", artist: "", album: "", duration: 40),
                                  fileName: "无标签 Mezzamo - Happy Boy.mp3")
        expectEqual(id(untagged), id(P.identity(title: "无标签 Mezzamo - Happy Boy.mp3", artist: " ")),
                    "Pine 身份: 没写标签两条路一样")
        let big5 = P.identity(tags: LocalAudioFileTags(title: "\u{C1}c\u{C5}\u{E9}\u{BA}q\u{A6}W\u{B4}\u{FA}\u{B8}\u{D5}",
                                                       artist: "\u{B4}\u{FA}\u{B8}\u{D5}\u{BA}q\u{A4}\u{E2}", album: "", duration: 40),
                              fileName: "big5-a.mp3")
        expectEqual(id(big5), "測試歌手|繁體歌名測試|", "Pine 身份: 文件标签的乱码同样还原")
    }

    // ---- 位置:真机那一串锚点回放 ----
    do {
        let track = "Jay|稻香"
        func at(_ t: Double) -> Date { Date(timeIntervalSince1970: 1_792_642_000 + t) }
        func anchor(_ el: Double, _ t: Double, _ playing: Bool = true) -> H.Anchor {
            H.Anchor(track: track, elapsed: el, at: at(t), playing: playing)
        }
        func pos(_ c: H.Clock, _ t: Double) -> Double { H.position(c, now: at(t)).position }
        // 真位置:咔哒 2.0 在 937.206;恢复后 6.0 在 943.611;跳转后 62.0 在 951.016;再恢复后 68.0 在 962.151。
        var c = H.advance(nil, anchor: anchor(0, 933.399), now: at(933.5))
        expectEqual(c.kind, .start, "Pine 位置: 开播第一份锚点")
        expectEqual(H.position(c, now: at(934.5)).waiting, true, "Pine 位置: 第一份锚点停在 0、报在加载")
        expectEqual(H.position(c, now: at(934.5)).position, 0, "Pine 位置: 停住时位置是 0")
        expectEqual(H.wantsProgressBar(c, now: at(934.5)), false, "Pine 位置: 停住时不读进度条")
        c = H.advance(c, anchor: anchor(0, 935.151), now: at(935.3))
        expectEqual(c.holdUntil, nil, "Pine 位置: 第二份锚点一到不再停")
        expectEqual(abs(pos(c, 937.206) - 2) < 0.03, true, "Pine 位置: 从第二份锚点起算,开播段对真值 0.03 秒以内")
        expectEqual(H.wantsProgressBar(c, now: at(935.3)), true, "Pine 位置: 开播段要量进度条的差")
        c = H.calibrated(c, value: 1, at: at(935.956))
        expectEqual(abs((c.sliderBias ?? 0) - 0.245) < 0.01, true, "Pine 位置: 开播段量出进度条超前约 0.24 秒")
        expectEqual(abs(pos(c, 937.206) - 2) < 0.03, true, "Pine 位置: 开播段量差不动位置")

        c = H.advance(c, anchor: anchor(4, 939.721, false), now: at(939.9))
        expectEqual(c.kind, .paused, "Pine 位置: 暂停")
        expectEqual((c.pausedPosition ?? 0) >= 4 && (c.pausedPosition ?? 0) < 5, true, "Pine 位置: 停下的位置夹在报的那一秒里")
        var resumed = H.advance(c, anchor: anchor(4, 942.036), now: at(942.1))
        expectEqual(resumed.kind, .resume, "Pine 位置: 同一秒上恢复")
        expectEqual(abs(pos(resumed, 943.611) - 6) < 0.12, true, "Pine 位置: 没读进度条时恢复按暂停前的位置接上(0.12 秒以内)")
        expectEqual(pos(resumed, 943.611) - 6 > -0.45, true, "Pine 位置: 接上比整秒锚点(慢 0.42 秒)准")
        resumed = H.calibrated(resumed, value: 5, at: at(942.375))
        expectEqual(abs(pos(resumed, 943.611) - 6) < 0.03, true, "Pine 位置: 恢复后按这一段的差校准,0.03 秒以内")

        var seek = H.advance(resumed, anchor: anchor(60, 949.132), now: at(949.3))
        expectEqual(seek.kind, .seek, "Pine 位置: 跳转")
        expectEqual(abs(pos(seek, 951.016) - 62) < 0.5, true, "Pine 位置: 跳转后没校准先补半秒")
        seek = H.calibrated(seek, value: 61, at: at(950.001))
        expectEqual(abs(pos(seek, 951.016) - 62) < 0.06, true, "Pine 位置: 跳转后按进度条校准,0.06 秒以内")
        expectEqual(seek.precise, true, "Pine 位置: 校准过算量准的")

        var paused = H.advance(seek, anchor: anchor(60, 949.132, false), now: at(955.05))
        expectEqual(abs((paused.pausedPosition ?? 0) - (seek.base + 955.05 - 949.132)) < 0.001, true,
                    "Pine 位置: 停下前先报的那份(锚点没变)按此刻推,不夹进旧的整秒")
        paused = H.advance(paused, anchor: anchor(65, 955.183, false), now: at(955.3))
        expectEqual((paused.pausedPosition ?? 0) >= 65 && (paused.pausedPosition ?? 0) < 66, true,
                    "Pine 位置: 补报的停下位置夹进 65 那一秒")
        var again = H.advance(paused, anchor: anchor(65, 959.855), now: at(960))
        expectEqual(again.kind, .resume, "Pine 位置: 跳转之后的暂停恢复")
        expectEqual(abs(pos(again, 962.151) - 68) < 0.35, true, "Pine 位置: 没读进度条时接上,0.35 秒以内")
        again = H.calibrated(again, value: 66, at: at(960.136))
        expectEqual(abs(pos(again, 962.151) - 68) < 0.06, true, "Pine 位置: 跳转那段的差沿用到恢复,0.06 秒以内")
    }

    // ---- 位置:边界 ----
    do {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func anchor(_ track: String, _ el: Double, _ t: Double, _ playing: Bool = true) -> H.Anchor {
            H.Anchor(track: track, elapsed: el, at: t0.addingTimeInterval(t), playing: playing)
        }
        let only = H.advance(nil, anchor: anchor("a", 0, 0), now: t0)
        expectEqual(H.position(only, now: t0.addingTimeInterval(2.0)).waiting, true, "Pine 边界: 等第二份锚点最多 2.2 秒")
        expectEqual(H.position(only, now: t0.addingTimeInterval(3.0)).waiting, false, "Pine 边界: 等不到第二份按第一份走")
        expectEqual(abs(H.position(only, now: t0.addingTimeInterval(3.0)).position - 2.95) < 0.001, true,
                    "Pine 边界: 等不到第二份时从第一份起算")
        let late = H.advance(only, anchor: anchor("a", 0, 30), now: t0.addingTimeInterval(30))
        expectEqual(late.holdUntil != nil, true, "Pine 边界: 隔很久又一份 0 秒锚点是重新开播(上一首、单曲循环),再停一次")
        let joined = H.advance(nil, anchor: anchor("a", 87, 0), now: t0)
        expectEqual(joined.kind, .joined, "Pine 边界: 中途才看到")
        expectEqual(H.position(joined, now: t0).position, 87.5, "Pine 边界: 中途看到的补半秒")
        let joinedCal = H.calibrated(joined, value: 88, at: t0.addingTimeInterval(0.7))
        expectEqual(abs(joinedCal.base - (88 - H.joinedSliderBias - 0.7)) < 0.001, true, "Pine 边界: 中途看到的按估计的差校准")
        let wrong = H.calibrated(joined, value: 120, at: t0.addingTimeInterval(0.7))
        expectEqual(wrong.base, joined.base, "Pine 边界: 格值离锚点太远(不是这首的进度条)不采信")
        expectEqual(wrong.sliderDone, true, "Pine 边界: 不采信也记下读过,不再读")
        let other = H.advance(joined, anchor: anchor("b", 0, 5), now: t0.addingTimeInterval(5))
        expectEqual(other.kind, .start, "Pine 边界: 换歌")
        expectEqual(other.sliderBias, nil, "Pine 边界: 换歌后上一首那段的差作废")
        let pausedSeek = H.advance(H.advance(joinedCal, anchor: anchor("a", 90, 3, false), now: t0.addingTimeInterval(3)),
                                   anchor: anchor("a", 150, 8, false), now: t0.addingTimeInterval(8))
        expectEqual(pausedSeek.pausedPosition, 150.5, "Pine 边界: 暂停着跳转补半秒")
        expectEqual(pausedSeek.sliderBias, H.seekSliderBias, "Pine 边界: 暂停着跳转之后按跳转的差")
        let resumedFar = H.advance(pausedSeek, anchor: anchor("a", 150, 12), now: t0.addingTimeInterval(12))
        expectEqual(resumedFar.kind, .resume, "Pine 边界: 暂停着跳转后恢复")
        expectEqual(resumedFar.precise, false, "Pine 边界: 那个位置是补的,不算量准")
        let pausedJoined = H.advance(nil, anchor: anchor("d", 11, -3000, false), now: t0)
        let pausedToZero = H.advance(pausedJoined, anchor: anchor("d", 0, 5, false), now: t0.addingTimeInterval(5))
        expectEqual(pausedToZero.pausedPosition, 0, "Pine 边界: 暂停着才看到的那份不往后推(暂停着跳回开头)")
        let pausedToFloor = H.advance(pausedJoined, anchor: anchor("d", 40, 5, false), now: t0.addingTimeInterval(5))
        expectEqual(pausedToFloor.pausedPosition, 40.5, "Pine 边界: 暂停着才看到、再暂停着跳转,补半秒")
        expectEqual(pausedToFloor.running, false, "Pine 边界: 暂停着跳转后不算在走的那段")
        let pausedAtStart = H.advance(nil, anchor: anchor("c", 0, 0, false), now: t0)
        expectEqual(H.position(pausedAtStart, now: t0).position, 0, "Pine 边界: 停在开头的暂停锚点不补半秒")
        expectEqual(H.wantsProgressBar(pausedAtStart, now: t0), false, "Pine 边界: 暂停时不读进度条")
    }

    // ---- 循环:「重复模式」子菜单 ----
    do {
        typealias M = PineMenuControl
        expectEqual([0, 1, 2, 3, 4].map { M.mode(checkedIndex: $0) }, [.repeatAll, .repeatAll, .repeatOne, .list, nil],
                    "Pine 循环: 所有曲目、选中的列表都是列表循环,一首乐曲是单曲,无是关")
        expectEqual(M.indexToPress(for: .repeatOne, checkedIndex: 0), 2, "Pine 循环: 列表循环切单曲按第三项")
        expectEqual(M.indexToPress(for: .list, checkedIndex: 2), 3, "Pine 循环: 单曲切关按第四项")
        expectEqual(M.indexToPress(for: .repeatAll, checkedIndex: 3), 0, "Pine 循环: 关切列表循环按「所有曲目」")
        expectEqual(M.indexToPress(for: .repeatAll, checkedIndex: 1), nil, "Pine 循环: 「选中的列表」已经是列表循环,不按")
        expectEqual(M.indexToPress(for: .shuffle, checkedIndex: 0), nil, "Pine 循环: 没有随机")
        expectEqual(M.options, [.repeatAll, .repeatOne], "Pine 循环: 只给循环键,不给随机")
        expectEqual(MusicPlaybackController.supportsExtendedControls(.pinePlayer), true, "Pine 循环: 歌词窗口出循环键")
        expectEqual(MusicPlaybackController.supportsRepeatOne(.pinePlayer), true, "Pine 循环: 有单曲循环")
    }

    // ---- 失焦时的菜单项 ----
    do {
        let none = 1 << 3
        expectEqual(PlaybackMenuControl.command(forMenuKey: " ", modifiers: none, player: .pinePlayer), .playPause, "Pine 菜单: 空格是播放 / 暂停")
        expectEqual(PlaybackMenuControl.command(forMenuKey: "\u{F702}", modifiers: none, player: .pinePlayer), .previousTrack,
                    "Pine 菜单: 左方向键是上一首")
        expectEqual(PlaybackMenuControl.command(forMenuKey: "\u{F703}", modifiers: none, player: .pinePlayer), .nextTrack,
                    "Pine 菜单: 右方向键是下一首")
        expectEqual(PlaybackMenuControl.command(forMenuKey: "\u{F700}", modifiers: none, player: .pinePlayer), nil,
                    "Pine 菜单: 上方向键是音量,不认")
        expectEqual(PlaybackMenuControl.command(forMenuKey: " ", modifiers: 0, player: .pinePlayer), nil, "Pine 菜单: 带 ⌘ 的不认")
        expectEqual(PlaybackMenuControl.command(forMenuKey: " ", modifiers: none, player: .qqMusic), nil, "Pine 菜单: 别的播放器不按快捷键认")
        expectEqual(PlaybackMenuControl.players.contains(.pinePlayer), true, "Pine 菜单: 失焦时走菜单")
        expectEqual(MusicPlaybackController.controlRoute(
            exclusivelyAppleMusic: false, focusFallback: nil, focusHeldElsewhere: true, directQueryFallback: .pinePlayer,
            mediaControlCommand: "next-track"), .menuAccessibility(.pinePlayer, .nextTrack), "Pine 菜单: 焦点被占时下一首走菜单")
    }

    // ---- 接线契约 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func sourceText(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let client = sourceText("LyrimuseCore/Local/MediaControlClient.swift")
        expectEqual(sourceHas(client, "elapsedTime: amazonPosition ?? radioPosition ?? pine?.position ?? elapsed"), true,
                    "Pine 接线: 解码那一拍位置换成 PinePlayhead")
        expectEqual(sourceHas(client, "PlayerTitleSplit.applied(to: PinePlayerInfo.adapted(raw))"), true,
                    "Pine 接线: 曲目在公开出口换,主路径、焦点回退、通道坏了三条路都过")
        expectEqual(sourceHas(client, "snapshot = pineProbedSnapshot(probed.snapshot, anchor: probed.anchor, now: now)"), true,
                    "Pine 接线: 焦点回退那份同样换")
        expectEqual(sourceHas(client, "(keyTitle, keyArtist, filePath) = PinePlayerInfo.artworkIdentity(title: raw.title, artist: raw.artist)"),
                    true, "Pine 接线: 封面的曲目标识跟快照对得上")
        let info = sourceText("LyrimuseCore/Local/PinePlayerInfo.swift")
        expectEqual(sourceHas(info, "guard !SourceKnockout.isOut(.pineFile) else { return nil }"), true, "Pine 接线: 文件那条腿能拔")
        let head = sourceText("LyrimuseCore/Local/PinePlayhead.swift")
        expectEqual(sourceHas(head, "guard !SourceKnockout.isOut(.pineSlider), AXIsProcessTrusted() else { return false }"), true,
                    "Pine 接线: 进度条那条腿能拔、没权限不读")
        let probe = sourceText("LyrimuseCore/Local/NowPlayingClientsProbe.swift")
        expectEqual(sourceHas(probe, "(title, artist, _) = PinePlayerInfo.artworkIdentity(title: title, artist: artist)"), true,
                    "Pine 接线: 单问的封面同样换标识")
        expectEqual(LocalPlaybackSource.resumeReadingNeverLeads(bundleID: P.bundleID), true, "Pine 接线: 恢复那一拍不封顶")
        expectEqual(TornTrackHold.arrivesWhole(bundle: P.bundleID), true, "Pine 接线: 换歌整份到达")
        expectEqual(CoverArtReplacementGate.missingArtworkUsesMatchedCover(bundleID: P.bundleID), true,
                    "Pine 接线: 没封面时用匹配到的")
        expectEqual(PlaybackPlayer.pinePlayer.accessibilityUse, .refinesProgress, "Pine 接线: 辅助功能权限的用途")
        expectEqual(KnownPlaceholderArtwork.entries.contains {
            $0.player == P.bundleID && $0.byteCount == 49212 && $0.sha256Hex.hasPrefix("b71cf70491ffe471")
        }, true, "Pine 接线: 没封面时推的那张图标登记成占位图")
        expectEqual(sourceHas(client, "if bundleID == PinePlayerInfo.bundleID, KnownPlaceholderArtwork.isPlaceholder(imageData),"), true,
                    "Pine 接线: 系统那份是占位图时先找同目录的图")
    }
}
