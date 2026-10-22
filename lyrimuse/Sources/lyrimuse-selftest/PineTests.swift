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
        let untagged = LocalAudioFileTags(title: "", artist: "", album: "", duration: 40)
        let twoCopies: [(fileName: String, tags: LocalAudioFileTags)] = [
            ("无标签 Mezzamo - Happy Boy.mp3", untagged), ("只有歌名.mp3", leaked[0].tags), ("无标签 Mezzamo - Happy Boy.mp3", untagged),
        ]
        expectEqual(P.pickFile(title: "无标签 Mezzamo - Happy Boy.mp3", artist: " ", candidates: twoCopies), 2,
                    "Pine 挑文件: 两个目录里的同名文件都开着时取后打开的那个")
        expectEqual(P.pickFile(title: "无标签 Mezzamo - Happy Boy", artist: "无标签 Mezzamo", candidates: leaked), 1,
                    "Pine 挑文件: 没写标签、它解析过文件名之后的写法(不带扩展名、歌手一栏是「 - 」前面那段)")
        expectEqual(P.fileMatches(title: "无标签 Mezzamo - Happy Boy", artist: "别人", tags: untagged,
                                  fileName: "无标签 Mezzamo - Happy Boy.mp3"), false, "Pine 挑文件: 解析过的写法歌手一栏也要对上")
        expectEqual(P.keepingLastOccurrence(["a", "b", "a", "c"]), ["b", "a", "c"], "Pine 挑文件: 同一个文件开过两次,按后开的那次排")
        expectEqual(P.pickFile(title: "Marjoram", artist: "Accident", candidates: [
            ("m.mp3", LocalAudioFileTags(title: "Marjoram", artist: "Accident", album: "Vert Bleu Noir", duration: 294)),
        ]), 0, "Pine 挑文件: 歌手一栏对不上但同名的只有一个,就是它")
        let marjoram: [(fileName: String, tags: LocalAudioFileTags)] = [
            ("m.mp3", LocalAudioFileTags(title: "Marjoram", artist: "Accident", album: "Vert Bleu Noir", duration: 294)),
        ]
        expectEqual([P.pickFile(title: "Marjoram", artist: "Accident", duration: 294, candidates: marjoram),
                     P.pickFile(title: "Marjoram", artist: "Someone", duration: 180, candidates: marjoram)], [0, nil],
                    "Pine 挑文件: 只按歌名对上时时长也要对上,别的歌手的同名歌(放过的文件还开着)不认")
        expectEqual([P.unreadableMatch(title: "Hi", fileNames: ["Highway.wma"]), P.unreadableMatch(title: "Hi", fileNames: ["03 - Hi.wma"]),
                     P.unreadableMatch(title: "晴天", fileNames: ["周杰伦 - 晴天.wv"]), P.unreadableMatch(title: "晴天", fileNames: ["晴天娃娃.wv"])],
                    [nil, 0, 0, nil], "Pine 挑文件: 短歌名要在文件名里整段出现")
        expectEqual(P.unreadableMatch(title: "天际线", fileNames: ["天际线-wma.wma", "别的.ape", "天际线-tta.tta"]), 2,
                    "Pine 挑文件: 读不出标签的按文件名含歌名认,取后开的")
        expectEqual(P.unreadableMatch(title: "未命名.wma", fileNames: ["未命名.wma"]), 0, "Pine 挑文件: 没写标签那种写法(带扩展名)照样认")
        expectEqual(P.unreadableMatch(title: "Skyline", fileNames: ["天际线-wma.wma"]), nil, "Pine 挑文件: 文件名不含歌名的不认")
        expectEqual(P.unreadableMatch(title: "4 Bits Cúbicos [Jeremy Flagelo - Diego Psardi]", fileNames: ["05. 4 Bits Cúbicos.dsf"]), 0,
                    "Pine 挑文件: 歌名比文件名长(后面挂着参演者),去掉曲号的文件名在歌名里也算")
        expectEqual(P.unreadableMatch(title: "Cu\u{0301}bicos", fileNames: ["03 - Cúbicos.ape"]), 0, "Pine 挑文件: Unicode 写法不同照样认")
        expectEqual(P.unreadableMatch(title: "Intro", fileNames: ["01 - INTRO.ape"]), 0, "Pine 挑文件: 不分大小写")
        expectEqual(P.unreadableMatch(title: "Abc Song", fileNames: ["ab.ape", "07.ape"]), nil, "Pine 挑文件: 太短的文件名、只有曲号的不拿来套歌名")
        let sky = LocalAudioFileTags(title: "天际线", artist: "天际的红日", album: "天际线", duration: 20)
        expectEqual(P.pickOpenFile(title: "天际线", artist: "天际的红日\u{2219}天际线",
                                   files: [("天际线-alac.m4a", sky), ("天际线-wma.wma", nil)]), 1,
                    "Pine 挑文件: 同一首另有读得出标签的旧文件开着,取后打开的读不出标签的那个")
        expectEqual(P.pickOpenFile(title: "天际线", artist: "天际的红日\u{2219}天际线",
                                   files: [("天际线-wma.wma", nil), ("天际线-alac.m4a", sky)]), 1, "Pine 挑文件: 后打开的是读得出标签的就取它")
        expectEqual(P.pickOpenFile(title: "天际线", artist: "天际的红日\u{2219}天际线",
                                   files: [("别的.mp3", LocalAudioFileTags(title: "别的", artist: "谁", album: "", duration: 3)), ("无关.wma", nil)]), nil,
                    "Pine 挑文件: 都对不上不认")
        expectEqual([P.radioShaped(bundleID: P.bundleID, title: "radio", artist: " ", duration: nil),
                     P.radioShaped(bundleID: P.bundleID, title: "radio", artist: " ", duration: 0),
                     P.radioShaped(bundleID: P.bundleID, title: "radio", artist: " ", duration: 9.223372036854776e18),
                     P.radioShaped(bundleID: P.bundleID, title: "环境音", artist: " ", duration: 36_000),
                     P.radioShaped(bundleID: P.bundleID, title: "pine-http-test.mp3", artist: " ", duration: 14),
                     P.radioShaped(bundleID: P.bundleID, title: "稻香", artist: "周杰伦\u{2219}魔杰座", duration: nil),
                     P.radioShaped(bundleID: "com.coppertino.Vox", title: "radio", artist: " ", duration: nil)],
                    [true, true, true, false, false, false, false],
                    "Pine 网络电台: 歌手一栏空、没有时长(或报 Int64 最大值)的像电台;十小时的本地文件、网络上的文件、写了歌手的、别家的都不算")
        expectEqual(P.openFileExtensions.isSuperset(of: ["mka", "caf", "wma", "ape"]), true, "Pine 挑文件: 它能放的 mka、caf 也算音频文件")
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
        expectEqual(id(untagged), id(P.identity(title: "无标签 Mezzamo - Happy Boy", artist: "无标签 Mezzamo")),
                    "Pine 身份: 它解析过文件名之后的写法也是同一首(中途改写不算换歌)")
        expectEqual(id(P.identity(title: "Track08", artist: "Track08")), "|Track08|", "Pine 身份: 解析过、文件名里没有「 - 」")
        let big5 = P.identity(tags: LocalAudioFileTags(title: "\u{C1}c\u{C5}\u{E9}\u{BA}q\u{A6}W\u{B4}\u{FA}\u{B8}\u{D5}",
                                                       artist: "\u{B4}\u{FA}\u{B8}\u{D5}\u{BA}q\u{A4}\u{E2}", album: "", duration: 40),
                              fileName: "big5-a.mp3")
        expectEqual(id(big5), "測試歌手|繁體歌名測試|", "Pine 身份: 文件标签的乱码同样还原")
    }

    // ---- 出口换曲目时带过去的标记 ----
    do {
        let json = #"{"title":"Happy Boy","artist":"Happy Boy","duration":40,"elapsedTime":0,"playing":false,"playbackRate":0,"isMusicApp":true,"bundleIdentifier":"com.digipine.pineplayer"}"#
        var raw = try! JSONDecoder().decode(MediaControlSnapshot.self, from: Data(json.utf8))
        raw.isWaitingToPlay = true
        raw.republishDueBy = Date(timeIntervalSince1970: 1_800_000_002)
        raw.positionIsPrecise = true
        let out = P.adapted(raw)
        expectEqual(out?.artist, "", "Pine 出口: 曲目照换(没写歌手)")
        expectEqual(out?.isWaitingToPlay, true, "Pine 出口: 在加载带过去(不然按暂停档 6 秒才轮询)")
        expectEqual(out?.republishDueBy, raw.republishDueBy, "Pine 出口: 补查时刻带过去")
        expectEqual(out?.positionIsPrecise, true, "Pine 出口: 精确读数带过去")
    }

    // ---- 别的版本按本体认 ----
    do {
        let pro = "com.digipine.pineplayer.pro", origin = "com.digipine.pineplayer.origin"
        expectEqual([PlayerBundleAliases.canonical(pro), PlayerBundleAliases.canonical(origin)], [P.bundleID, P.bundleID],
                    "Pine 别名: Pro、Pro the Origin 的 bundle id 换成免费版的")
        expectEqual(PlayerBundleAliases.canonical(PlaybackPlayer.spotify.bundleIdentifier), PlaybackPlayer.spotify.bundleIdentifier,
                    "Pine 别名: 别家原样不动")
        expectEqual(PlayerBundleAliases.all(for: P.bundleID), [P.bundleID, origin, pro], "Pine 别名: 找进程时本体在前、别名跟着")
        expectEqual(PlayerBundleAliases.all(for: pro), [P.bundleID, origin, pro], "Pine 别名: 从别名查也是同一组")
        expectEqual(PlayerBundleAliases.all(for: PlaybackPlayer.vox.bundleIdentifier), [PlaybackPlayer.vox.bundleIdentifier],
                    "Pine 别名: 没有别名的播放器只有它自己")
        expectEqual(MediaControlClient.reportingPlayerBundleID(pro, owner: nil), P.bundleID, "Pine 别名: 系统报上来的 Pro 一进来就当免费版")
    }

    // ---- 网络流报的无限时长 ----
    do {
        func snap(_ duration: String) -> MediaControlSnapshot {
            try! JSONDecoder().decode(MediaControlSnapshot.self, from: Data("{\"title\":\"radio\",\"duration\":\(duration)}".utf8))
        }
        expectEqual([snap("9.223372036854776e18").trackDuration, snap("0").trackDuration, snap("-1").trackDuration],
                    [nil, nil, nil], "无限时长: Int64 最大值那么长、0、负数都当没有时长")
        expectEqual([snap("223.5").trackDuration, snap("36000").trackDuration], [223.5, 36000], "无限时长: 真实曲长原样给,十小时的也是")
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
        let looping = H.advance(H.advance(nil, anchor: anchor("e", 39, 0), now: t0), anchor: anchor("e", 1, 41), now: t0.addingTimeInterval(41))
        let restarted = H.advance(looping, anchor: anchor("e", 0, 41.67), now: t0.addingTimeInterval(41.7))
        expectEqual(restarted.holdUntil, nil, "Pine 边界: 循环回到开头(先报 1 秒、再报 0 秒)时 0 秒那份当第二份,不停住")
        expectEqual(restarted.kind, .start, "Pine 边界: 循环回到开头算开播")
        let late = H.advance(only, anchor: anchor("a", 0, 30), now: t0.addingTimeInterval(30))
        expectEqual(late.holdUntil != nil, true, "Pine 边界: 隔很久又一份 0 秒锚点是重新开播(上一首、单曲循环),再停一次")
        let pairSecond = H.advance(only, anchor: anchor("a", 0, 1), now: t0.addingTimeInterval(1))
        expectEqual([H.isNewStart(from: nil, to: only), H.isNewStart(from: only, to: pairSecond), H.isNewStart(from: only, to: only),
                     H.isNewStart(from: only, to: late), H.isNewStart(from: looping, to: restarted)], [true, false, false, true, true],
                    "Pine 开播次数: 第一份算一次,第二份、同一份不算,隔很久重新开播、循环回到开头各算一次")
        let joined = H.advance(nil, anchor: anchor("a", 87, 0), now: t0)
        expectEqual(joined.kind, .joined, "Pine 边界: 中途才看到")
        expectEqual(H.position(joined, now: t0).position, 87.5, "Pine 边界: 中途看到的补半秒")
        let joinedCal = H.calibrated(joined, value: 88, at: t0.addingTimeInterval(0.7))
        expectEqual(abs(joinedCal.base - (88 - H.joinedSliderBias - 0.7)) < 0.001, true, "Pine 边界: 中途看到的按估计的差校准")
        let wrong = H.calibrated(joined, value: 120, at: t0.addingTimeInterval(0.7))
        expectEqual(wrong.base, joined.base, "Pine 边界: 格值离锚点太远(不是这首的进度条)不采信")
        expectEqual(wrong.sliderDone, true, "Pine 边界: 不采信也记下读过,不再读")
        expectEqual(H.advance(joinedCal, anchor: anchor("a", 87, 0.02), now: t0.addingTimeInterval(1)), joinedCal,
                    "Pine 边界: 同一份锚点时刻差几十毫秒(单问到的那份)算同一份,这一段量过的差不丢")
        expectEqual(H.advance(joinedCal, anchor: anchor("a", 87, 0.3), now: t0.addingTimeInterval(1)) != joinedCal, true,
                    "Pine 边界: 时刻差得多的是另一份锚点")
        let misled = H.advance(H.advance(nil, anchor: anchor("f", 0, 0), now: t0), anchor: anchor("f", 0, 0.5),
                               now: t0.addingTimeInterval(0.5))
        let misledCal = H.calibrated(misled, value: 1, at: t0.addingTimeInterval(0.9))
        expectEqual(misledCal.sliderBias, H.startSliderBias, "Pine 边界: 开播段量出的差不对时按典型的差")
        expectEqual(abs(H.position(misledCal, now: t0.addingTimeInterval(0.9)).position - (1 - H.startSliderBias)) < 0.001, true,
                    "Pine 边界: 开播锚点不准时按进度条把开播位置补过来")
        let misledFar = H.calibrated(misled, value: 9, at: t0.addingTimeInterval(0.9))
        expectEqual(misledFar.base, misled.base, "Pine 边界: 按进度条推出的开播位置离锚点太远不采信")
        expectEqual(misledFar.sliderBias, nil, "Pine 边界: 不采信时不记差")
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
        let pausedRunning = H.advance(joinedCal, anchor: anchor("a", 90, 3, false), now: t0.addingTimeInterval(3))
        expectEqual(pausedRunning.running, true, "Pine 边界: 正常暂停之后还是这一段的表")
        let pausedAgain = H.advance(pausedRunning, anchor: anchor("a", 90, 10, false), now: t0.addingTimeInterval(10))
        expectEqual([abs((pausedAgain.pausedPosition ?? 0) - (pausedRunning.pausedPosition ?? 0)) < 0.001, pausedAgain.running], [true, true],
                    "Pine 边界: 停着隔几秒又来一份同一秒的暂停锚点,停下的位置不往后推、还是这一段")
        let reopened = H.advance(pausedRunning, anchor: anchor("a", 0, 500, false), now: t0.addingTimeInterval(500))
        expectEqual(reopened.pausedPosition, 0, "Pine 边界: 暂停着重开同一个文件先报的那份停在 0 秒,不按上一段往后推")
        let pausedEarly = H.advance(only, anchor: anchor("a", 0, 0.8, false), now: t0.addingTimeInterval(0.8))
        expectEqual(pausedEarly.pausedPosition, 0, "Pine 边界: 开播还在停住时暂停,停在 0 秒")
        let pausedInFirstSecond = H.advance(pairSecond, anchor: anchor("a", 0, 1.6, false), now: t0.addingTimeInterval(1.6))
        expectEqual(abs((pausedInFirstSecond.pausedPosition ?? 0) - 0.55) < 0.001, true, "Pine 边界: 第一秒里暂停,按这一段推")
        let resumedInFirstSecond = H.advance(pausedInFirstSecond, anchor: anchor("a", 0, 4), now: t0.addingTimeInterval(4))
        expectEqual([resumedInFirstSecond.kind == .resume, resumedInFirstSecond.holdUntil == nil,
                     abs(H.position(resumedInFirstSecond, now: t0.addingTimeInterval(5)).position - 1.55) < 0.001], [true, true, true],
                    "Pine 边界: 第一秒里暂停再恢复(报 0 秒)接着停下的位置走,不当重新开播停住")
        expectEqual(H.advance(reopened, anchor: anchor("a", 0, 501), now: t0.addingTimeInterval(501)).kind, .start,
                    "Pine 边界: 暂停着重开同一个文件再开播,照旧算开播")
        let pausedAtStart = H.advance(nil, anchor: anchor("c", 0, 0, false), now: t0)
        expectEqual(H.position(pausedAtStart, now: t0).position, 0, "Pine 边界: 停在开头的暂停锚点不补半秒")
        expectEqual(H.wantsProgressBar(pausedAtStart, now: t0), false, "Pine 边界: 暂停时不读进度条")
    }

    // ---- 位置:循环回到开头(14 秒的咔哒文件、列表只有这一首、重复所有曲目) ----
    do {
        let t0 = Date(timeIntervalSince1970: 1_792_676_760)
        func anchor(_ el: Double, _ t: Double, _ playing: Bool = true) -> H.Anchor {
            H.Anchor(track: "loop", elapsed: el, at: t0.addingTimeInterval(t), playing: playing)
        }
        func at(_ t: Double) -> Date { t0.addingTimeInterval(t) }
        let first = H.advance(nil, anchor: anchor(0, 6.600), now: at(6.7), duration: 14)
        let started = H.advance(first, anchor: anchor(0, 8.362), now: at(8.4), duration: 14)
        expectEqual(started.holdUntil, nil, "Pine 循环开头: 开播两份锚点照旧")
        let looped = H.advance(started, anchor: anchor(0, 22.533), now: at(22.6), duration: 14)
        expectEqual([looped.kind == .start, looped.holdUntil == at(22.533), H.position(looped, now: at(23)).waiting], [true, true, false],
                    "Pine 循环开头: 结尾附近只来一份 0 秒锚点是循环回来的,不停住")
        expectEqual(H.isNewStart(from: started, to: looped), true, "Pine 循环开头: 算一次开播")
        let loopCal = H.calibrated(looped, value: 3, at: at(25.17))
        expectEqual(loopCal.sliderBias, H.startSliderBias, "Pine 循环开头: 开播锚点只有一份,按典型的差")
        expectEqual(abs(loopCal.base - (3 - H.startSliderBias - 2.637)) < 0.001, true, "Pine 循环开头: 按进度条补开播位置")
        expectEqual(H.advance(looped, anchor: anchor(0, 23.2), now: at(23.3), duration: 14).holdUntil, nil,
                    "Pine 循环开头: 之后又来一份 0 秒锚点当第二份")
        let oneOnly = H.advance(loopCal, anchor: anchor(1, 37.193), now: at(37.3), duration: 14)
        expectEqual([oneOnly.kind == .seek, oneOnly.sliderBias == H.startSliderBias], [true, true],
                    "Pine 循环开头: 只来一份 1 秒锚点照跳转算,进度条按开播那段超前")
        let midTrack = H.advance(started, anchor: anchor(0, 13), now: at(13.1), duration: 14)
        expectEqual(abs((midTrack.holdUntil?.timeIntervalSince(at(13)) ?? 0) - H.startHoldSecs) < 0.001, true, "Pine 循环开头: 离结尾还远的 0 秒锚点是重新开播,照旧停住")
        let stale = H.advance(started, anchor: anchor(0, 130), now: at(130.1), duration: 14)
        expectEqual(abs((stale.holdUntil?.timeIntervalSince(at(130)) ?? 0) - H.startHoldSecs) < 0.001, true,
                    "Pine 循环开头: 早就放完、没收到暂停锚点的旧表不认循环,照旧停住")
        let midSeek = H.advance(started, anchor: anchor(1, 13), now: at(13.1), duration: 14)
        expectEqual(midSeek.sliderBias, H.seekSliderBias, "Pine 循环开头: 离结尾还远跳到 1 秒是跳转")
        let fullStartCal = H.calibrated(started, value: 1, at: at(8.95))
        expectEqual(fullStartCal.base, started.base, "Pine 循环开头: 两份开播锚点都到的那段量差不动位置")
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
        expectEqual(sourceHas(client, "|| PinePlayerInfo.isNetworkRadio(snapshot)"), true, "Pine 接线: 网络电台当不是歌")
        expectEqual([sourceHas(sourceText("LyrimuseCore/Local/PlayerProcess.swift"), "let ids = PlayerBundleAliases.all(for: bundleID)"),
                     sourceHas(sourceText("LyrimuseCore/Local/NowPlayingClientsProbe.swift"), "for id in PlayerBundleAliases.inProbeOrder(for: bundleID) {"),
                     sourceHas(sourceText("LyrimuseCore/Local/PlayerPickerLayout.swift"),
                               "PlayerBundleAliases.applicationURL(forBundleID: player.bundleIdentifier) != nil")],
                    [true, true, true], "Pine 别名: 找进程、单问会话、判装没装都把别名试一遍")
        expectEqual([sourceHas(client, "guard let bundleID = raw.bundleIdentifier.map(PlayerBundleAliases.canonical), artworkBundleIDMatches(bundleID, players: players) else {"),
                     sourceHas(sourceText("LyrimuseCore/Local/NowPlayingClientsProbe.swift"), "\"/usr/bin/perl\", [paths.script, paths.library, id, \"artwork\"]"),
                     sourceHas(sourceText("lyrimuse/Settings/AccessibilityPermission.swift"), "PlayerBundleAliases.isInstalled(player)"),
                     sourceHas(sourceText("lyrimuse/AppDelegate.swift"), "let playerURL = PlayerBundleAliases.applicationURL(forBundleID: player.bundleIdentifier)")],
                    [true, true, true, true], "Pine 别名: 封面载荷换成本体的 id、单问封面也试别名、辅助功能那一行和启动播放器认别的版本")
        let local = sourceText("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual([sourceHas(local, "if playing, snapshot.trackDuration == nil {"), sourceHas(local, "if playing, let duration = snapshot.trackDuration {")],
                    [true, true], "无限时长: 建进度锚点前按 trackDuration 判(换成毫秒整数不溢出)")
        let info = sourceText("LyrimuseCore/Local/PinePlayerInfo.swift")
        expectEqual(sourceHas(info, "guard !SourceKnockout.isOut(.pineFile) else { return nil }"), true, "Pine 接线: 文件那条腿能拔")
        expectEqual(sourceHas(info, ".map { (path: $0, tags: cachedTags(path: $0)) }")
                    && sourceHas(info, "pickOpenFile(title: title, artist: artist, duration: duration, files:"), true,
                    "Pine 接线: 开着的文件按路径和修改时间缓存标签,挑文件带上系统报的时长")
        expectEqual(sourceHas(sourceText("LyrimuseCore/Local/PineMenuControl.swift"), "return MenuBarAX.press(sub[index])"), true,
                    "Pine 接线: 循环菜单项灰着时不按、不报成功")
        expectEqual(sourceHas(info, "let key = title + \"\\u{1F}\" + artist + \"\\u{1F}\" + String(PinePlayhead.startCount)"), true,
                    "Pine 接线: 同一首换了文件再放要重挑")
        let head = sourceText("LyrimuseCore/Local/PinePlayhead.swift")
        expectEqual(sourceHas(head, "if isNewStart(from: s, to: next) { starts.withLock { $0 += 1 } }"), true, "Pine 接线: 每次开播记一次")
        expectEqual(sourceHas(head, "(attribute(element, kAXValueAttribute) as? NSNumber).flatMap { Int(exactly: $0.doubleValue.rounded()) }")
                    && sourceHas(head, "duration > 0, duration < ProgressBar.maxDuration, startSampling("), true,
                    "Pine 接线: 进度条读到 NaN / 超大值不 trap,电台那种时长不去找进度条")
        expectEqual(sourceHas(head, "defer { sampling.withLock { $0 = false } }")
                    && sourceHas(head, "AXUIElementSetMessagingTimeout(bar, 0.25)"), true,
                    "Pine 接线: 读完写回再放开采样;滑块元素也设短超时")
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
