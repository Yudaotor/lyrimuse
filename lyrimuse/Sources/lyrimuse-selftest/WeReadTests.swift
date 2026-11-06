import Foundation
import LyrimuseCore

// 微信读书听书:系统会话的歌手栏装的是正在念的那一小段原文,每段带着新锚点重发一次(PlayerSubtitles)。
func runWeReadTests() {
    typealias S = PlayerSubtitles
    typealias Line = PlayerSubtitles.Line
    let weread = PlaybackPlayer.weread.bundleIdentifier

    // ---- 并进一句 ----
    do {
        let base = [Line(ms: 346_140, text: "在一所教堂中，他看见一尊栩栩如生的圣"),
                    Line(ms: 349_590, text: "母像，大受感动，便去寻访这圣像的雕塑")]
        expectEqual(S.recorded(base, text: "师，拜在他门下学徒", ms: 353_040).map(\.ms), [346_140, 349_590, 353_040],
                    "微信读书字幕: 新的一段按起点接在后面")
        expectEqual(S.recorded(base, text: "  ", ms: 353_040), base, "微信读书字幕: 空的一段不记")
        expectEqual(S.recorded(base, text: "母像，大受感动，便去寻访这圣像的雕塑", ms: 351_200), base,
                    "微信读书字幕: 暂停恢复时原样重发正在念的那段,不再记一遍")
        expectEqual(S.recorded(base, text: "母像，大受感动，便去寻访这圣像的雕塑", ms: 349_750), base,
                    "微信读书字幕: 同一段重发、起点只差零点几秒,不动")
        expectEqual(S.recorded(base, text: "母像，大受感动", ms: 349_750).map(\.text),
                    ["在一所教堂中，他看见一尊栩栩如生的圣", "母像，大受感动"],
                    "微信读书字幕: 起点挨得很近、文字不同,换成新的那段")
        expectEqual(S.recorded(base, text: "书名平淡而又冗长", ms: 10_000).map(\.ms), [10_000, 346_140, 349_590],
                    "微信读书字幕: 往回拖之后念到的段按起点插到前面")
        expectEqual(S.recorded(base, text: "x", ms: -1), base, "微信读书字幕: 负的起点不记")
        let full = (0..<S.maxLines).map { Line(ms: $0 * 1000, text: "第\($0)段") }
        let more = S.recorded(full, text: "最新一段", ms: S.maxLines * 1000)
        expectEqual([more.count, more.first?.ms ?? -1, more.last?.ms ?? -1], [S.maxLines, 1000, S.maxLines * 1000],
                    "微信读书字幕: 超过上限丢最早的")
    }

    // ---- 拼 LRC ----
    expectEqual(S.lrc([Line(ms: 321_250, text: "可正因为太过平常了"), Line(ms: 6_045_500, text: "第二\n行")]),
                "[05:21.25]可正因为太过平常了\n[100:45.50]第二 行",
                "微信读书字幕: 拼成 LRC,一句一行、文字里的换行压成空格,超过一百分钟照写")
    expectEqual(S.lrc([]), "", "微信读书字幕: 没收到时是空的")

    // ---- 快照进来的第一层 ----
    do {
        func snap(_ bundleID: String, artist: String, album: String, title: String, anchor: Double) -> MediaControlSnapshot {
            let json = #"{"title":"\#(title)","artist":"\#(artist)","album":"\#(album)","bundleIdentifier":"\#(bundleID)","#
                + #""anchorElapsedTime":\#(anchor),"elapsedTime":\#(anchor),"playing":true,"playbackRate":1,"duration":362.381}"#
            return try! JSONDecoder().decode(MediaControlSnapshot.self, from: Data(json.utf8))
        }
        let first = S.adapted(snap(weread, artist: "可正因为太过平常了", album: "雪国", title: "16 雪国 第16集", anchor: 321.25))
        let second = S.adapted(snap(weread, artist: "反倒让岛村感到出乎意外", album: "雪国", title: "16 雪国 第16集", anchor: 323.75))
        expectEqual([first?.artist, second?.artist], ["雪国", "雪国"], "微信读书字幕: 歌手换成书名,身份不随字幕变")
        expectEqual(first?.trackKey, second?.trackKey, "微信读书字幕: 两段字幕是同一集")
        let key = S.trackKey(album: "雪国", title: "16 雪国 第16集")
        expectEqual(S.lines(forKey: key), [Line(ms: 321_250, text: "可正因为太过平常了"), Line(ms: 323_750, text: "反倒让岛村感到出乎意外")],
                    "微信读书字幕: 每一拍把歌手栏收成一段、起点是那一拍的锚点")
        let lyrics = S.lyrics(bundleID: weread, album: "雪国", title: "16 雪国 第16集")
        expectEqual([lyrics?.lyrics, lyrics.map { String($0.resolved) }], ["[05:21.25]可正因为太过平常了\n[05:23.75]反倒让岛村感到出乎意外", "true"],
                    "微信读书字幕: 这一集的歌词就是收到的字幕")
        expectEqual([S.adapted(snap(weread, artist: "杨武能", album: "雪国", title: "16 雪国 第16集", anchor: 370))?.duration,
                     S.adapted(snap(weread, artist: "反倒让岛村感到出乎意外", album: "雪国", title: "16 雪国 第16集", anchor: 323.75))?.duration],
                    [370, 362.381], "微信读书字幕: 念到报的时长之后,时长抬到锚点(不然位置封顶、后面的字幕显示不出来);没超的不动")
        let revision = S.revision
        _ = S.adapted(snap(weread, artist: "第一段", album: "雪国", title: "17 雪国 第17集", anchor: 0))
        expectEqual([S.lines(forKey: key).count, S.lines(forKey: S.trackKey(album: "雪国", title: "17 雪国 第17集")).count], [0, 1],
                    "微信读书字幕: 换了一集从头记")
        expectEqual(S.revision > revision, true, "微信读书字幕: 换集、来新字幕都让 revision 变")
        let apple = PlaybackPlayer.appleMusic.bundleIdentifier
        expectEqual(S.adapted(snap(apple, artist: "周杰倫", album: "我很忙", title: "青花瓷", anchor: 3))?.artist, "周杰倫",
                    "微信读书字幕: 别家的快照原样放行")
        expectEqual(S.lyrics(bundleID: apple, album: "我很忙", title: "青花瓷") == nil, true, "微信读书字幕: 别家照旧查缓存")
    }

    // ---- 只按 players.json 的字段认 ----
    expectEqual(PlaybackPlayer.allCases.filter(\.subtitlesInArtist), [.weread], "微信读书字幕: 歌手栏装字幕的只有微信读书")

    // ---- 接线 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let source = src("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(sourceHas(source, "let found = PlayerSubtitles.lyrics(bundleID: snapshot.bundleIdentifier, album: snapshot.album, title: snapshot.title)\n?? EnrichCacheReader.lookup("),
                    true, "微信读书字幕: 重载歌词先问收到的字幕,再查缓存")
        expectEqual(sourceHas(source, "refreshSpokenAudio()\nrefreshPlayerSubtitles()")
                    && sourceHas(source, "guard revision != playerSubtitlesRevision else { return }\nplayerSubtitlesRevision = revision\nreloadCurrentLyrics()"),
                    true, "微信读书字幕: 每拍收尾见到新字幕就重载歌词")
        expectEqual(sourceHas(source, "if PlayerSubtitles.carriesSubtitles(bundleID: snapshot.bundleIdentifier) {\napplySpokenAudio(true, mid: \"subtitles\")"),
                    true, "微信读书字幕: 一开播就按有声内容处理(不推 Discord、播放状态写有声)")
        let quitWatcher = src("lyrimuse/Settings/PlayerQuitWatcher.swift")
        expectEqual(sourceHas(quitWatcher, "DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)")
                    && sourceHas(quitWatcher, "for app in NSWorkspace.shared.runningApplications { watchExit(of: app) }")
                    && sourceHas(quitWatcher, "MainActor.assumeIsolated { self?.exited(bundleID, pid: pid) }"),
                    true, "微信读书: iPad 版退出时系统不发退出通知,跟随退出另按进程号盯")
    }
}
