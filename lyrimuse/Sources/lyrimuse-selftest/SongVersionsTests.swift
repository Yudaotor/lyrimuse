import Foundation
import LyrimuseCore

// 歌词管理「同一首歌的其他写法」:列表、证据、拆开过的写法,以及跟引擎的接线(18 章决策 28)。
// 由 main.swift 的注册表按组调用。

@MainActor
func runSongVersionsTests() {
    typealias V = SongVersions
    let m = { (song: String, share: Int) in V.Membership(song: song, share: share) }

    // ---- 列表:同一首歌的其他写法按键排,共享组、直接相连的证据按固定顺序 ----
    do {
        let memberships = [
            "A|Song|One": m("s_1", 0), "A|Song|Two": m("s_1", 0), "A|Song|Three": m("s_1", 1),
            "B|Other|One": m("s_2", 0),
        ]
        let edges = [
            V.Edge(kind: "family", a: "A|Song|One", b: "A|Song|Two"),
            V.Edge(kind: "isrc", a: "A|Song|Two", b: "A|Song|One"),
            V.Edge(kind: "isrc", a: "A|Song|One", b: "A|Song|Two"),
            V.Edge(kind: "future_kind", a: "A|Song|Two", b: "A|Song|One"),
            V.Edge(kind: "netease_name", a: "A|Song|Two", b: "A|Song|One"),
            V.Edge(kind: "apple_song", a: "A|Song|One", b: "A|Song|Two"),
            V.Edge(kind: "lyrics", a: "A|Song|One", b: "A|Song|Two"),
            V.Edge(kind: "mb_recording", a: "A|Song|Two", b: "A|Song|One"),
            V.Edge(kind: "lyrics", a: "A|Song|Two", b: "A|Song|Three"),
        ]
        let listing = V.listing(key: "A|Song|One", memberships: memberships, edges: edges, splits: [])
        expectEqual(listing?.song, "s_1", "同一首歌的其他写法: 实体 id")
        expectEqual(listing?.rows.map(\.key), ["A|Song|Three", "A|Song|Two"], "同一首歌的其他写法: 不含自己、按键排、别的歌不进来")
        expectEqual(listing?.rows.last?.evidence, ["isrc", "mb_recording", "apple_song", "family", "lyrics", "netease_name", "future_kind"],
                    "同一首歌的其他写法: 证据去重,按固定顺序,不认识的排最后")
        expectEqual(listing?.rows.first?.evidence, [], "同一首歌的其他写法: 没有直接证据的是经由别的写法连着")
        expectEqual(listing?.rows.map(\.sharesLyrics), [false, true], "同一首歌的其他写法: 同一个共享组才算歌词共用")
        expectEqual(V.listing(key: "C|None|One", memberships: memberships, edges: [], splits: []) == nil, true,
                    "同一首歌的其他写法: 没有实体 id 的写法没有列表")
        expectEqual(V.listing(key: "B|Other|One", memberships: memberships, edges: [], splits: [])?.isEmpty, true,
                    "同一首歌的其他写法: 只有自己一条时是空的")
    }

    // ---- 拆开过的写法:一端在这首歌里、另一端不在;恢复合并传两边各自实体的全部写法 ----
    do {
        let memberships = [
            "A|Song|One": m("s_1", 0), "A|Song|Three": m("s_1", 0),
            "A|Song|Two": m("s_9", 0), "A|Song|Four": m("s_9", 0),
            "C|Lone|One": m("s_5", 0), "B|Else|One": m("s_7", 0),
        ]
        let splits = [
            ["A|Song|Four", "C|Lone|One"], ["A|Song|Two", "A|Song|Three"], ["A|Song|One", "A|Song|Two"],
            ["A|Song|Three", "A|Song|One"], ["X|Gone|One", "A|Song|One"], ["B|Else|One", "C|Lone|One"],
        ]
        let fromOne = V.listing(key: "A|Song|One", memberships: memberships, edges: [], splits: splits)
        expectEqual(fromOne?.splits.map(\.key), ["A|Song|Two"],
                    "拆开过的写法: 同一首歌内部的、缓存里已经没有的、跟这首无关的都不列")
        expectEqual(fromOne?.splits.first?.mergeKeys, ["A|Song|Four", "A|Song|One", "A|Song|Three", "A|Song|Two"],
                    "拆开过的写法: 恢复合并带上两边各自实体的全部写法")
        let fromTwo = V.listing(key: "A|Song|Two", memberships: memberships, edges: [], splits: splits)
        expectEqual(fromTwo?.splits.map(\.key), ["A|Song|One", "A|Song|Three", "C|Lone|One"],
                    "拆开过的写法: 从拆出去的那边看,列出原来那首的写法,连同这边别的写法拆开过的")
        expectEqual(fromTwo?.rows.map(\.key), ["A|Song|Four"], "拆开过的写法: 拆出去那边自己的实体照常列")
        let lone = V.listing(key: "C|Lone|One", memberships: memberships, edges: [], splits: splits)
        expectEqual(lone?.rows.isEmpty == true && lone?.isEmpty == false, true, "拆开过的写法: 只有拆开记录时也不算空")
    }

    // ---- 两份手改:原件(手改过或采纳的那份还在,不是副本、有正文)内容不止一份才算 ----
    do {
        let lrcA = "[00:01.00]甲\n", lrcB = "[00:01.00]乙\n"
        func c(_ key: String, manual: Bool = true, origin: String = "", sha: String? = nil, lyrics: String, yrc: String = "") -> V.ManualCandidate {
            V.ManualCandidate(key: key, manual: manual, origin: origin, pickSHA: sha, lyrics: lyrics, yrc: yrc)
        }
        expectEqual(V.manualConflict([c("A|S|2", lyrics: lrcB), c("A|S|1", lyrics: lrcA), c("A|S|3", origin: "A|S|1", lyrics: lrcA)]),
                    ["A|S|1", "A|S|2"], "两份手改: 两份原件内容不同,按键排,副本不算")
        expectEqual(V.manualConflict([c("A|S|1", lyrics: lrcA), c("A|S|2", lyrics: lrcA)]), [], "两份手改: 内容一样不算")
        expectEqual(V.manualConflict([c("A|S|1", lyrics: lrcA), c("A|S|2", lyrics: lrcA, yrc: "[1000,500](1000,500,0)甲")]),
                    ["A|S|1", "A|S|2"], "两份手改: 逐字歌词不同也算不同")
        expectEqual(V.manualConflict([c("A|S|1", lyrics: lrcA), c("A|S|2", manual: false, lyrics: lrcB)]), [], "两份手改: 没改过的不算")
        expectEqual(V.manualConflict([c("A|S|1", lyrics: lrcA), c("A|S|2", manual: false, sha: ManualPickLock.fingerprint(lyrics: lrcB), lyrics: lrcB)]),
                    ["A|S|1", "A|S|2"], "两份手改: 采纳的那份还在也算原件")
        expectEqual(V.manualConflict([c("A|S|1", lyrics: lrcA), c("A|S|2", manual: false, sha: ManualPickLock.fingerprint(lyrics: lrcA), lyrics: lrcB)]),
                    [], "两份手改: 采纳的那份已经被换掉不算")
        expectEqual(V.manualConflict([c("A|S|1", lyrics: lrcA), c("A|S|2", lyrics: "  \n")]), [], "两份手改: 没正文的不算")
    }

    // ---- 重新自动匹配:同组跟着换了几条,只认跑完的、同一首的那一轮 ----
    do {
        let json = #"{"id":"r1","key":"A|S|1","running":false,"startedAt":1,"updatedAt":2,"finishedAt":2,"result":{"outcome":"changed","followers":2}}"#
        let status = try? JSONDecoder().decode(LyricsRematch.Status.self, from: Data(json.utf8))
        expectEqual(status?.result?.followers, 2, "重新自动匹配: 解出跟着换的条数")
        expectEqual(LyricsRematch.followers(of: status, key: "A|S|1"), 2, "重新自动匹配: 同一首、跑完了")
        expectEqual(LyricsRematch.followers(of: status, key: "A|S|2"), 0, "重新自动匹配: 别的歌那一轮不算")
        let running = LyricsRematch.Status(id: "r1", key: "A|S|1", running: true, startedAt: 1, updatedAt: 2,
                                           result: LyricsRematch.Conclusion(outcome: "changed", followers: 3))
        expectEqual(LyricsRematch.followers(of: running, key: "A|S|1"), 0, "重新自动匹配: 还在跑的不算")
        expectEqual(LyricsRematch.followers(of: nil, key: "A|S|1"), 0, "重新自动匹配: 没有状态")
        let old = #"{"id":"r1","key":"A|S|1","running":false,"startedAt":1,"updatedAt":2,"result":{"outcome":"unchanged"}}"#
        expectEqual(LyricsRematch.followers(of: try? JSONDecoder().decode(LyricsRematch.Status.self, from: Data(old.utf8)), key: "A|S|1"), 0,
                    "重新自动匹配: 旧引擎没这个字段")
    }

    // ---- 收录的播放器:引擎记下的优先;没记时从播放器给的 id 推断(18 章决策 38)----
    do {
        let noted = V.players(entry: ["players": ["com.apple.Music", "com.spotify.client"], "kkbox_url": "https://www.kkbox.com/x"])
        expectEqual(noted.bundleIDs, ["com.apple.Music", "com.spotify.client"], "播放器: 记下的原样用")
        expectEqual(noted.inferred, false, "播放器: 记下的不算推断")
        let inferred = V.players(entry: ["spotify_track_id": "2TeLIzFBe3hxkPR5FIQZut", "kkbox_url": "https://www.kkbox.com/x",
                                         "amazon_url": "https://music.amazon.com/tracks/B0", "soda_url": "https://x", "youtube_music_url": "https://music.youtube.com/watch?v=a"])
        expectEqual(inferred.bundleIDs, [PlaybackPlayer.spotify.bundleIdentifier, PlaybackPlayer.kkbox.bundleIdentifier,
                                         PlaybackPlayer.amazonMusic.bundleIdentifier, PlaybackPlayer.soda.bundleIdentifier,
                                         PlaybackPlayer.kaset.bundleIdentifier], "播放器: 从播放器给的 id 推断")
        expectEqual(inferred.inferred, true, "播放器: 推断的标出来")
        let none = V.players(entry: ["apple_music_url": "https://music.apple.com/x", "players": [String]()])
        expectEqual(none.bundleIDs.isEmpty && !none.inferred, true, "播放器: 检索配的链接不算,没有就是空")
    }

    // ---- 原始写法:引擎的 reported 按 bundle id 排,缺的字段为空 ----
    do {
        let r = V.reportedNames(entry: ["reported": ["com.tencent.QQMusicMac": ["title": "偷笑 (Tou Xiao)", "artist": "方大同"],
                                                     "com.apple.Music": ["title": "偷笑\u{00A0}", "album": "爱爱爱"]]])
        expectEqual(r.map(\.bundleID), ["com.apple.Music", "com.tencent.QQMusicMac"], "原始写法: 按 bundle id 排")
        expectEqual(r.last?.title == "偷笑 (Tou Xiao)" && r.last?.album == "", true, "原始写法: 原样取、缺的为空")
        expectEqual(V.reportedNames(entry: [:]).isEmpty, true, "原始写法: 没有就是空")
    }

    // ---- 显示的行:走播放引擎,跟歌词窗口一样(抬头、署名、演唱者标注不算,时间减自带 offset、按 0.01 秒取整) ----
    do {
        func shown(_ lrc: String, yrc: String = "", title: String = "", artist: String = "",
                   aliases: [LRCParser.HeaderIdentity] = []) -> V.Shown {
            V.displayed(lyrics: lrc, yrc: yrc, title: title, artist: artist, aliases: aliases)
        }
        // 抬头、署名不显示,也不参与比对:两边写法不同(「作词：」对「词：」、抬头多一段英文名)照样算一样。
        let x = "[00:00.10]偷笑 - 方大同\n[00:00.20]作词：方大同\n[00:00.30]作曲：方大同\n[00:12.00]第一句歌词在这里\n[00:18.00]第二句歌词在这里\n"
        let y = "[00:00.00]偷笑 - 方大同 (Khalil Fong)\n[00:00.78]词：方大同\n[00:01.57]曲：方大同\n[00:12.00]第一句歌词在这里\n[00:18.00]第二句歌词在这里\n"
        let sx = shown(x, title: "偷笑", artist: "方大同"), sy = shown(y, title: "偷笑", artist: "Khalil Fong")
        expectEqual(sx.lines.map(\.text), ["第一句歌词在这里", "第二句歌词在这里"], "显示的行: 抬头、署名不算")
        expectEqual(sx == sy && V.compareLyrics(current: sx, other: sy).match == .identical, true, "显示的行: 只差抬头、署名的两份完全一致")
        // 抬头写的是同曲条目里另一个条目的歌名、歌手(播放器报英文名,歌词抬头写中文名):带上别的条目的写法才认得出。
        let poet = "[00:06.00]诗人的情人 - 方大同\n[00:09.92]缠绵是首诗\n[00:13.42]很容易迷失\n"
        expectEqual(shown(poet, title: "The Poet's Lover", artist: "Khalil Fong").lines.first?.text, "诗人的情人 - 方大同",
                    "显示的行: 只认这条自己的歌名歌手时,中文抬头认不出")
        expectEqual(shown(poet, title: "The Poet's Lover", artist: "Khalil Fong",
                          aliases: [LRCParser.HeaderIdentity(title: "诗人的情人", artist: "方大同")]).lines.map(\.text),
                    ["缠绵是首诗", "很容易迷失"], "显示的行: 同曲条目里别的写法的歌名歌手也认抬头")
        expectEqual(shown(poet, title: "The Poet's Lover", artist: "Khalil Fong",
                          aliases: [LRCParser.HeaderIdentity(title: "缠绵是首诗", artist: "方大同")]).lines.count, 3,
                    "显示的行: 别的写法也要歌名歌手两段都对上才删")
        func entry(_ json: String) -> EnrichCacheEntry { try! JSONDecoder().decode(EnrichCacheEntry.self, from: Data(json.utf8)) }
        let all = ["Khalil Fong|The Poet's Lover|This Love": entry(#"{"song":"s_1"}"#), "方大同|诗人的情人|爱爱爱": entry(#"{"song":"s_1"}"#),
                   "方大同|诗人的情人|愛愛愛": entry(#"{"song":"s_1"}"#), "别人|别的歌|": entry(#"{"song":"s_2"}"#)]
        expectEqual(EnrichCacheReader.headerAliases(song: "s_1", ownKey: "Khalil Fong|The Poet's Lover|This Love", in: all),
                    [LRCParser.HeaderIdentity(title: "诗人的情人", artist: "方大同")], "显示的行: 同曲条目的歌名歌手按写法键取、不含自己、去重")
        // 演唱者标注跟歌词窗口一样:行首的剥掉,独占一行的整行不算。
        let duet = "[00:16.02]周杰伦：\n[00:17.34]驯鹿的响铃 和雪花的相遇\n[00:20.93]杨瑞代：当作是我对你离开描绘的旋律\n"
            + "[00:24.47]周杰伦：柴火写了序 暖和童话的过去\n[00:33.37]杨瑞代：该不会是我的卡片（我的卡片）\n"
        expectEqual(shown(duet).lines.map(\.text),
                    ["驯鹿的响铃 和雪花的相遇", "当作是我对你离开描绘的旋律", "柴火写了序 暖和童话的过去", "该不会是我的卡片（我的卡片）"],
                    "显示的行: 演唱者标注剥掉,独占一行的不算")
        expectEqual(shown("[offset:500]\n[00:10.00]一句歌词\n[00:12.00]又一句歌词\n").lines.map(\.timeMs), [9500, 11500],
                    "显示的行: 时间减去自带的 offset")
        let lrc = "[00:18.70]Your butt is mine\n[00:20.85]Gonna tell you right\n"
        let yrc = "[18709,2000](18709,1000,0)Your (19709,500,0)butt (20209,300,0)is (20509,200,0)mine\n"
            + "[20853,2000](20853,500,0)Gonna (21353,500,0)tell (21853,500,0)you (22353,500,0)right\n"
        let worded = shown(lrc, yrc: yrc)
        expectEqual(worded.words.map(\.timeMs), [18700, 20850], "显示的行: 逐字的行首按 0.01 秒取整")
        expectEqual(worded.words.map(\.text) == worded.lines.map(\.text) && shown(lrc).words.isEmpty, true,
                    "显示的行: 逐字那份是引擎用逐字时显示的行,没有逐字歌词时为空")
        let fewWords = shown("[00:01.00]一\n[00:02.00]二\n[00:03.00]三\n[00:04.00]四\n[00:05.00]五\n", yrc: "[1000,500](1000,500,0)一\n")
        expectEqual(fewWords.words.isEmpty && fewWords.lines.count == 5, true, "显示的行: 逐字行太少、引擎退回整行时逐字那份为空")
        expectEqual(V.Shown(lines: [], words: worded.words).text, worded.words, "显示的行: 整行一句都没有时拿逐字的比")
    }

    // ---- 逐行对比:按字对齐,分行、繁简、标点空格、演唱者标注都不算词不一样;时间差不算进结论,块上另记 ----
    do {
        func shown(_ lrc: String, yrc: String = "") -> V.Shown { V.displayed(lyrics: lrc, yrc: yrc, title: "", artist: "") }
        let a = "[00:01.00]一句歌词\n[00:03.00]二句歌词\n[00:05.00]三句歌词\n"
        let same = V.compareLyrics(current: shown(a), other: shown(a))
        expectEqual(same.match, .identical, "逐行对比: 一样的完全一致")
        expectEqual(same.blocks.map(\.kind), [.same, .same, .same], "逐行对比: 一句一块")
        // 一份每句带演唱者标注、多一行独占的标注,句中多空格、括号全角,时间早零点一几秒。
        let plain = "[00:17.50]驯鹿的响铃和雪花的相遇\n[00:21.00]当作是我对你离开描绘的旋律\n[00:24.55]柴火写了序暖和童话的过去\n"
            + "[00:33.50]该不会是我的卡片 (我的卡片)\n"
        let labeled = "[00:16.02]周杰伦：\n[00:17.34]驯鹿的响铃 和雪花的相遇\n[00:20.93]杨瑞代：当作是我对你离开描绘的旋律\n"
            + "[00:24.47]周杰伦：柴火写了序 暖和童话的过去\n[00:33.37]杨瑞代：该不会是我的卡片（我的卡片）\n"
        let labels = V.compareLyrics(current: shown(plain), other: shown(labeled))
        expectEqual(labels.match, .sameText, "逐行对比: 只差演唱者标注、空格、全半角的算文字一致")
        expectEqual(labels.blocks.map(\.kind), [.same, .same, .same, .same], "逐行对比: 标注那行不占一块,四块都对得上")
        expectEqual(labels.shiftMs, -80, "逐行对比: 字全对得上的块里所选条目早多少,取中位数")
        // 一份繁体、三句并成一句、句首带 `v1：`,时间早不到 0.5 秒。
        let short = "[00:29.23]车子缓缓的开\n[00:30.98]你慢慢走来\n[00:32.63]我竟然看着你发呆\n"
            + "[00:35.78]你尴尬Say个Hi\n[00:37.38]没位坐下来\n[00:39.08]我想叫旁边的离开\n"
        let merged = "[00:28.79]v1：車子緩緩的開 你慢慢走來 我竟然看著你發呆\n[00:35.30]v1：你尷尬 say 個 hi 沒位坐下來 我想叫旁邊的離開\n"
        let reseg = V.compareLyrics(current: shown(short), other: shown(merged))
        expectEqual(reseg.match, .sameText, "逐行对比: 分行不同、繁简不同、大小写不同的算文字一致")
        expectEqual(reseg.blocks.map { [$0.current.count, $0.other.count] }, [[3, 1], [3, 1]], "逐行对比: 三句对一句并成一块")
        expectEqual(reseg.blocks.map(\.kind), [.resegmented, .resegmented], "逐行对比: 分行不同不算改了字")
        expectEqual(reseg.summary.scriptVariants, 2, "逐行对比: 繁简写法不同的块记下来")
        expectEqual(reseg.blocks.allSatisfy { $0.deltaMs == nil } && reseg.shiftMs == -440, true, "逐行对比: 差不到 0.5 秒的块不记时间差")
        // 只差时间:结论照样文字一致,差超过 0.5 秒的那块记下所选条目晚多少。
        let late = V.compareLyrics(current: shown(a), other: shown("[00:02.00]一句歌词\n[00:03.00]二句歌词\n[00:05.00]三句歌词\n"))
        expectEqual(late.match, .sameText, "逐行对比: 只差时间的算文字一致")
        expectEqual(late.blocks.map(\.deltaMs), [1000, nil, nil], "逐行对比: 时间差超过 0.5 秒的块记下所选条目晚多少")
        expectEqual(late.blocks.contains(where: \.differs), false, "逐行对比: 时间差不标成词不一样")
        // 改了字:只标那个字,两边都标。
        let changed = V.compareLyrics(current: shown(a), other: shown("[00:01.00]一句歌词\n[00:03.00]二句改词\n[00:05.00]三句歌词\n"))
        expectEqual(changed.match, .different, "逐行对比: 改了字的存在差异")
        expectEqual(changed.blocks.map(\.differs), [false, true, false], "逐行对比: 改了字的那块标出来")
        expectEqual(changed.blocks[1].currentMarks == [[2]] && changed.blocks[1].otherMarks == [[2]], true, "逐行对比: 只标改了的字")
        // 多一句、少一句。
        let longer = a + "[00:07.00]尾声呢喃\n"
        let extra = V.compareLyrics(current: shown(a), other: shown(longer))
        expectEqual(extra.match == .different && extra.extraLines == 1 && extra.missingLines == 0, true, "逐行对比: 只所选条目有的句子算多出来的")
        expectEqual(extra.blocks.last.map { $0.current.isEmpty && $0.other.map(\.text) == ["尾声呢喃"] && $0.differs }, true,
                    "逐行对比: 多出来的那句左边空着")
        let missing = V.compareLyrics(current: shown(longer), other: shown(a))
        expectEqual(missing.missingLines == 1 && missing.extraLines == 0, true, "逐行对比: 只当前条目有的句子算少的")
        // 整行一样、只有一份带逐字:不算完全一致。
        let lrc = "[00:18.70]Your butt is mine\n[00:20.85]Gonna tell you right\n"
        let yrc = "[18709,2000](18709,1000,0)Your (19709,500,0)butt (20209,300,0)is (20509,200,0)mine\n"
            + "[20853,2000](20853,500,0)Gonna (21353,500,0)tell (21853,500,0)you (22353,500,0)right\n"
        expectEqual(V.compareLyrics(current: shown(lrc, yrc: yrc), other: shown(lrc)).match, .sameText, "逐行对比: 只差逐字的算文字一致")
        expectEqual(V.compareLyrics(current: shown(a), other: shown("")).match, .different, "逐行对比: 一边没有显示的行时不算一致")
    }

    // ---- 两个文件:实体表按含这条写法的那首取证据,用户判断文件取拆开记录;缺了坏了都是空 ----
    do {
        let table = #"""
        {"version":1,"songs":{
          "s_1":{"variants":["A|Song|One","A|Song|Two"],"evidence":[{"kind":"isrc","a":"A|Song|One","b":"A|Song|Two","value":"X"},{"kind":"family"}]},
          "s_2":{"variants":["B|Other|One"]},
          "s_3":{"variants":["D|D|One","D|D|Two"],"evidence":[{"kind":"lyrics","a":"D|D|One","b":"D|D|Two"}]},
          "s_4":{"variants":["E|E|One","E|E|Two"],"evidence":[{"kind":"qq_song","a":"E|E|One","b":"E|E|Two"}]},
          "s_5":{"variants":["F|F|One","F|F|Two"],"evidence":[{"kind":"family","a":"F|F|One","b":"F|F|Two"}]}}}
        """#
        expectEqual(V.edges(tableData: Data(table.utf8), key: "A|Song|Two"),
                    [V.Edge(kind: "isrc", a: "A|Song|One", b: "A|Song|Two")], "实体表: 含这条写法的那首的证据,缺字段的边丢掉")
        expectEqual(V.edges(tableData: Data(table.utf8), key: "B|Other|One"), [], "实体表: 没有证据的一首")
        let countOnly = #"{"version":1,"songs":{"s_1":{"variants":["A","B"],"evidence":[{"kind":"apple_song","a":"A","b":"B","count_only":true}]}}}"#
        expectEqual(V.edges(tableData: Data(countOnly.utf8), key: "A").first?.countOnly, true, "实体表: 只用来合并播放次数的边标出来")
        expectEqual(V.strongKinds.isSubset(of: Set(V.evidenceOrder)), true, "强证据的种类都在证据种类里")
        expectEqual(["D|D|Two", "E|E|One", "F|F|Two"].map { V.edges(tableData: Data(table.utf8), key: $0).map(\.kind) },
                    [["lyrics"], ["qq_song"], ["family"]], "实体表: 每条写法取的都是含它的那一首")
        expectEqual(V.edges(tableData: Data(table.utf8), key: "C|None|One"), [], "实体表: 没收这条写法")
        expectEqual(V.edges(tableData: Data("{broken".utf8), key: "A|Song|One"), [], "实体表: 坏了是空")
        let user = #"{"version":1,"user_splits":[["A","B"],["A"],["C","C"],["","D"]],"future":true}"#
        expectEqual(V.splits(userData: Data(user.utf8)), [["A", "B"]], "用户判断文件: 只留成对、两端不同的")
        expectEqual(V.splits(userData: Data("{}".utf8)), [], "用户判断文件: 没有拆开记录")
        expectEqual(V.tableURL.lastPathComponent, "lyrimuse-song-entities.json", "实体表文件名")
        expectEqual(V.userURL.lastPathComponent, "lyrimuse-song-entity-user.json", "用户判断文件名")
    }

    // ---- 跟引擎对齐(契约):证据种类一一对应、每种都有文案;两个请求跟引擎的 op 同名;入口接上 ----
    do {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let engine = sources.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lyrimuse-engine")
        func read(_ base: URL, _ rel: String) -> String {
            (try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8)) ?? ""
        }
        let kindsBlock = read(engine, "songentity.go").components(separatedBy: "var songEvidenceKinds = map[string]songEvidenceKind{")
            .dropFirst().first?.components(separatedBy: "\n}").first ?? ""
        let names = kindsBlock.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.split(separator: ":").first.map(String.init)
        }
        var engineSources = ""
        for file in ["songentity.go", "songentityvariant.go", "songentitymb.go", "songentitynames.go", "songentityneteasenames.go"] {
            engineSources += read(engine, file)
        }
        func kindValue(_ name: String) -> String? {
            guard let r = engineSources.range(of: "\t\(name) = \"") ?? engineSources.range(of: "\t\(name)  *= \"", options: .regularExpression)
            else { return nil }
            return engineSources[r.upperBound...].split(separator: "\"").first.map(String.init)
        }
        let kinds = names.compactMap(kindValue)
        expectEqual(names.isEmpty, false, "其他写法(契约): 读到引擎的证据种类")
        expectEqual(kinds.count, names.count, "其他写法(契约): 引擎每种证据都找得到取值")
        expectEqual(Set(kinds), Set(V.evidenceOrder), "其他写法(契约): 证据种类跟引擎 songEvidenceKinds 一一对应")
        let strongNames = kindsBlock.split(separator: "\n").filter { $0.contains("strong: true") }.compactMap { line in
            line.trimmingCharacters(in: .whitespaces).split(separator: ":").first.map(String.init)
        }
        expectEqual(Set(strongNames.compactMap(kindValue)), V.strongKinds, "其他写法(契约): 强证据跟引擎 strong: true 的那几种一致")
        let sheet = read(sources, "lyrimuse/LyricsManager/SongVersionsSheet.swift")
        expectEqual(V.evidenceOrder.allSatisfy { sourceBytes(sheet, contain: "case \"\($0)\": return L10n.t(") }, true,
                    "其他写法(契约): 每种证据都有文案")
        let store = read(sources, "lyrimuse/LyricsManager/EnrichCacheStore.swift")
        let edit = read(engine, "enrichedit.go")
        expectEqual(sourceBytes(store, contain: "commit(\"split_song\", [\"keys\": keys])")
                    && sourceBytes(store, contain: "commit(\"unsplit_song\", [\"keys\": keys])")
                    && sourceBytes(edit, contain: "case \"split_song\":")
                    && sourceBytes(edit, contain: "case \"unsplit_song\":"), true,
                    "其他写法(契约): 拆开、恢复合并的请求跟引擎同名,参数用 keys")
        let manager = read(sources, "lyrimuse/LyricsManager/LyricsManagerView.swift")
        let playback = read(sources, "LyrimuseCore/Local/LocalPlaybackSource.swift")
        // 手改副本不算原件:「手动调整」筛选与删除确认只数原件,副本单独标;偏移借来的值标出借的是哪条(18 章决策 30)。
        let parts = read(sources, "lyrimuse/LyricsManager/LyricsManagerParts.swift")
        expectEqual(sourceBytes(manager, contain: "LyricsManagerStatus.Facts(kind: kind, isManual: s.isManualOriginal,")
                    && sourceBytes(manager, contain: "pending.contains($0.key) && $0.isManualOriginal }.count")
                    && sourceBytes(manager, contain: "picked.filter(\\.isManualOriginal).count")
                    && sourceBytes(manager, contain: "L10n.t(\"沿用同曲条目的修正\")")
                    && sourceBytes(parts, contain: "help: L10n.t(\"沿用同曲条目的人工修正\")"), true,
                    "其他写法(契约): 手改副本不算进人工修正,单独标出来")
        expectEqual(sourceBytes(store, contain: "manualOrigin: entry[\"lyrics_entity_origin\"] as? String ?? \"\",")
                    && sourceBytes(store, contain: "guard state != .neverPicked, (entry[\"lyrics_entity_origin\"] as? String ?? \"\").isEmpty else { continue }")
                    && sourceBytes(edit, contain: "res.Changed = manualLockOriginalsLocked(manualLockFlipsLocked(req.Value))"), true,
                    "其他写法(契约): 锁定开关的计数只数原件,App 本地统计跟引擎一样")
        expectEqual(sourceBytes(manager, contain: "offsetBorrowedFrom = LyricsOffsetStore.shared.borrowedOffsetSource(forKey: offsetKey, siblings: offsetSiblings)")
                    && sourceBytes(manager, contain: "borrowedFrom: offsetBorrowedFrom,")
                    && sourceBytes(parts, contain: "if let borrowedFrom {"), true,
                    "其他写法(契约): 偏移输入框标出借来的值")
        let settings = read(sources, "lyrimuse/Settings/FeatureSettingsStore.swift")
        let sheetSource = read(sources, "lyrimuse/LyricsManager/SongVersionsSheet.swift")
        expectEqual(sourceCount(sheetSource, "label: {\n            disclosureLabel("), 3, "其他写法(契约): 三处折叠区点标题文字也能展开")
        expectEqual(sourceBytes(store, contain: "commit(\"resolve_manual_conflict\", [\"key\": key])")
                    && sourceBytes(edit, contain: "case \"resolve_manual_conflict\":")
                    && sourceBytes(manager, contain: "manualConflictKeys = store.manualConflict(forKey: key)")
                    && sourceBytes(manager, contain: "if manualConflictKeys.count > 1 {")
                    && sourceHas(settings, "songEntityShareLyrics = f.songEntityShareLyrics ?? true\n        EnrichCacheReader.sharesEntityLyrics = songEntityShareLyrics")
                    && sourceBytes(settings, contain: "case songEntityShareLyrics = \"song_entity_share_lyrics\""), true,
                    "其他写法(契约): 两份手改的提示、统一请求、开关读法接上")
        expectEqual(sourceBytes(manager, contain: "instrumentalFollowsGroup ? L10n.t(\"；共用歌词的同曲条目也将一并更改\") : \"\"")
                    && sourceBytes(edit, contain: "keys = withShareGroupMatesLocked(keys)"), true,
                    "其他写法(契约): 标纯音乐作用到共享组,详情页的说明跟着说")
        let enrichEngine = read(engine, "enrich.go")
        expectEqual(sourceBytes(enrichEngine, contain: "Players []string `json:\"players,omitempty\"`")
                    && sourceBytes(store, contain: "let p = SongVersions.players(entry: entry)")
                    && sourceBytes(sheet, contain: "case .shared: return L10n.t(\"歌词同步\")")
                    && sourceBytes(sheet, contain: "case .own: return L10n.t(\"独立匹配\")")
                    && sourceBytes(sheet, contain: "case .split: return L10n.t(\"已拆分\")")
                    && sourceBytes(sheet, contain: "let shown = SongVersions.displayed(lyrics: facts.lyrics, yrc: facts.yrc, title: s.title, artist: s.artist, aliases: aliases)")
                    && sourceBytes(sheet, contain: "let comparison = current.map { SongVersions.compareLyrics(current: $0.shown, other: shown) }")
                    && sourceBytes(sheet, contain: "if v.lyricsKnown, current.lyricsKnown, v.match != .identical, !v.lyrics.isEmpty, !current.lyrics.isEmpty {")
                    && sourceBytes(sheet, contain: "let same = identical + sameText")
                    && sourceBytes(sheet, contain: "case .sameText: return L10n.t(\"文字一致\")")
                    && sourceBytes(playback, contain: "headerAliases: EnrichCacheReader.headerAliases(")
                    && sourceBytes(sheet, contain: "playerIcons(v, size: 22)") && sourceBytes(sheet, contain: "playerIcons(v, size: 18)")
                    && sourceBytes(sheet, contain: "players.insert(bundle, at: 0)")
                    && sourceBytes(sheet, contain: "if let playing = Self.nowPlayingKey, versions.contains(where: { $0.key == playing }) { return playing }")
                    && sourceBytes(sheet, contain: "return versions.first { $0.relation == .current }?.key ?? versions.first?.key")
                    && sourceBytes(manager, contain: "Text(String(format: L10n.t(\"播放器原始写法：%@\"), SongVersionsSheet.reportedLine(first)))"), true,
                    "其他写法(契约): 收录的播放器、三种关系、逐行对比接上,文字一致算一致")
        // 逐项对照:一边缺这一项不算不一样、不标红;原始写法不比;本机没放过的写法播放来源写「未播放过」(18 章决策 74)。
        expectEqual(sourceBytes(sheet, contain: "var differs: Bool { compared && !currentMissing && !otherMissing && current != other }")
                    && sourceBytes(sheet, contain: "let differing = rows.filter(\\.differs).count")
                    && sourceBytes(sheet, contain: "currentMissing: c.players.isEmpty, otherMissing: v.players.isEmpty")
                    && sourceBytes(sheet, contain: "currentMissing: c.durationSecs == nil, otherMissing: v.durationSecs == nil")
                    && sourceBytes(sheet, contain: "other: reportedText(v), compared: false)")
                    && sourceBytes(sheet, contain: "var neverPlayed: Bool { players.isEmpty && durationSecs == nil }")
                    && sourceBytes(sheet, contain: "return v.neverPlayed ? L10n.t(\"未播放过\") : L10n.t(\"未记录\")"), true,
                    "其他写法(契约): 逐项对照缺的一边不算不一样,原始写法不比,没放过的写「未播放过」")
        let rematchEngine = read(engine, "lyricsrematch.go")
        expectEqual(sourceBytes(manager, contain: "let followers = LyricsRematch.followers(of: LyricsRematch.current, key: key)")
                    && sourceBytes(rematchEngine, contain: "Followers int `json:\"followers,omitempty\"`"), true,
                    "其他写法(契约): 重新自动匹配的结论带上同组跟着换了几条")
        expectEqual(sourceBytes(manager, contain: "SongVersionsSheet(summary: summary, onOpen:")
                    && sourceBytes(manager, contain: "Button(L10n.t(\"同曲条目…\")) { showSongVersions = true }"), true,
                    "其他写法(契约): 详情页「⋯」菜单接上弹窗")
        expectEqual(sourceBytes(manager, contain: "let versions = store.songVersionCount(forKey: summary.key)")
                    && sourceHas(manager, "if versions > 1 {\n                Button { showSongVersions = true } label: {")
                    && sourceBytes(store, contain: "songVersionCounts[song, default: 0] += 1")
                    && sourceBytes(store, contain: "songVersionCounts = bundle.songVersionCounts"), true,
                    "其他写法(契约): 详情页概况那一行露出「同一首歌的 N 种写法」,随列表一起数")
        expectEqual(sourceHas(sheet, "if v.relation == .current {\n                overview(current)")
                    && sourceBytes(sheet, contain: "allVersionsTable(c)")
                    && sourceBytes(sheet, contain: "if !edges.isEmpty { evidenceSummary }"), true,
                    "其他写法(契约): 选中当前这条时右边是这首歌的概况(总览卡、当前这条的信息、全部写法一览、依据汇总)")
        expectEqual(sourceBytes(sheet, contain: "overviewCard(L10n.t(\"歌词一致性\"), lyricsOverview(c, others.filter { $0.relation != .split }))")
                    && sourceBytes(sheet, contain: "overviewCard(L10n.t(\"同步策略\"), syncOverview(others))")
                    && sourceBytes(sheet, contain: "if !EnrichCacheReader.sharesEntityLyrics {"), true,
                    "其他写法(契约): 概况两张卡跟对照页同名、说的是其他全部条目,关了歌词同步时同步策略写已关闭")
        expectEqual(sourceBytes(sheet, contain: "return v.match == .different ? .red : .green")
                    && sourceHas(sheet, "case .shared: return .green\n        case .own: return .red\n        case .split: return .secondary")
                    && sourceBytes(sheet, contain: "let relation: Relation = own == 0 ? .shared : .own")
                    && !sourceBytes(sheet, contain: "Color.orange.opacity(0.12)") && !sourceBytes(sheet, contain: ".purple"), true,
                    "其他写法(契约): 状态色一套(绿一样 / 同步、红不一样 / 不同步、灰比不了 / 已拆分),有独立匹配时同步策略数不跟的那几条")
        expectEqual(sourceHas(sheet, "case .identical: return \"checkmark.circle.fill\"\n        case .sameText: return \"equal.circle.fill\"\n        case .different: return \"xmark.circle.fill\"")
                    && sourceHas(sheet, "case .shared: return \"checkmark.circle.fill\"\n        case .own: return \"xmark.circle.fill\"")
                    && sourceBytes(sheet, contain: "statusDot(lyricsSymbol(v), lyricsColor(v), size: 11, label: lyricsVerdict(v))")
                    && sourceBytes(sheet, contain: "statusDot(lyricsSymbol(v), lyricsColor(v), size: 10, label: nil)")
                    && !sourceBytes(sheet, contain: "Circle().fill("), true,
                    "其他写法(契约): 列表、一览表的状态点带形状(勾 / 等号 / 叉 / 横杠),不只靠颜色")
    }
}
