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

    // ---- 歌词逐句对照:按先后对齐、空行不算,标出文字不同的行,时间差取文字相同那些行的中位数 ----
    do {
        let a = "[00:01.00]一\n[00:02.00]\n[00:03.00]二\n[00:05.00]三\n"
        let b = "[00:01.50]一\n[00:03.50]二改\n[00:05.50]三\n[00:07.00]四\n"
        func shown(_ text: String) -> [LyricLine] { V.displayedLines(text, title: "", artist: "") }
        let d = V.lyricDiff(current: shown(a), other: shown(b))
        expectEqual(d.rows.map(\.differs), [false, true, false, true], "逐句对照: 空行不算,改了的、多出来的标出来")
        expectEqual(d.differentLines, 2, "逐句对照: 不同的行数")
        expectEqual(d.shiftMs, 500, "逐句对照: 文字相同那些行晚多少")
        expectEqual(d.rows.last?.current == nil && d.rows.last?.other?.text == "四", true, "逐句对照: 一边没有的那行")
        expectEqual(V.lyricDiff(current: shown(a), other: shown(a)).differentLines, 0, "逐句对照: 一样的没有不同")
        expectEqual(V.lyricDiff(current: shown("[00:01.00]甲\n"), other: shown("[00:02.00]乙\n")).shiftMs == nil, true, "逐句对照: 没有相同的行就不算时间差")
        // 抬头、署名不显示,也不参与比对:两边写法不同(「作词：」对「词：」、抬头多一段英文名)照样算一样。
        let x = "[00:00.10]偷笑 - 方大同\n[00:00.20]作词：方大同\n[00:00.30]作曲：方大同\n[00:12.00]第一句歌词在这里\n[00:18.00]第二句歌词在这里\n"
        let y = "[00:00.00]偷笑 - 方大同 (Khalil Fong)\n[00:00.78]词：方大同\n[00:01.57]曲：方大同\n[00:12.00]第一句歌词在这里\n[00:18.00]第二句歌词在这里\n"
        let sx = V.displayedLines(x, title: "偷笑", artist: "方大同"), sy = V.displayedLines(y, title: "偷笑", artist: "Khalil Fong")
        expectEqual(sx.map(\.text), ["第一句歌词在这里", "第二句歌词在这里"], "逐句对照: 抬头、署名不算")
        expectEqual(sx == sy && V.lyricDiff(current: sx, other: sy).differentLines == 0, true, "逐句对照: 只差抬头、署名的两份算一样")
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
        let kinds = names.compactMap { name -> String? in
            guard let r = engineSources.range(of: "\t\(name) = \"") ?? engineSources.range(of: "\t\(name)  *= \"", options: .regularExpression)
            else { return nil }
            return engineSources[r.upperBound...].split(separator: "\"").first.map(String.init)
        }
        expectEqual(names.isEmpty, false, "其他写法(契约): 读到引擎的证据种类")
        expectEqual(kinds.count, names.count, "其他写法(契约): 引擎每种证据都找得到取值")
        expectEqual(Set(kinds), Set(V.evidenceOrder), "其他写法(契约): 证据种类跟引擎 songEvidenceKinds 一一对应")
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
        // 手改副本不算原件:「手动调整」筛选与删除确认只数原件,副本单独标;偏移借来的值标出借的是哪条(18 章决策 30)。
        let parts = read(sources, "lyrimuse/LyricsManager/LyricsManagerParts.swift")
        expectEqual(sourceBytes(manager, contain: "LyricsManagerStatus.Facts(kind: kind, isManual: s.isManualOriginal,")
                    && sourceBytes(manager, contain: "pending.contains($0.key) && $0.isManualOriginal }.count")
                    && sourceBytes(manager, contain: "picked.filter(\\.isManualOriginal).count")
                    && sourceBytes(manager, contain: "L10n.t(\"沿用同一首歌的修正\")")
                    && sourceBytes(parts, contain: "help: L10n.t(\"沿用同一首歌的人工修正\")"), true,
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
        expectEqual(sourceBytes(store, contain: "commit(\"resolve_manual_conflict\", [\"key\": key])")
                    && sourceBytes(edit, contain: "case \"resolve_manual_conflict\":")
                    && sourceBytes(manager, contain: "manualConflictKeys = store.manualConflict(forKey: key)")
                    && sourceBytes(manager, contain: "if manualConflictKeys.count > 1 {")
                    && sourceBytes(settings, contain: "EnrichCacheReader.sharesEntityLyrics = document.raw[\"song_entity_share_lyrics\"] as? Bool ?? false"), true,
                    "其他写法(契约): 两份手改的提示、统一请求、开关读法接上")
        expectEqual(sourceBytes(manager, contain: "instrumentalFollowsGroup ? L10n.t(\"；同一首歌共用歌词的其他写法也会一起改\") : \"\"")
                    && sourceBytes(edit, contain: "keys = withShareGroupMatesLocked(keys)"), true,
                    "其他写法(契约): 标纯音乐作用到共享组,详情页的说明跟着说")
        let enrichEngine = read(engine, "enrich.go")
        expectEqual(sourceBytes(enrichEngine, contain: "Players []string `json:\"players,omitempty\"`")
                    && sourceBytes(store, contain: "let p = SongVersions.players(entry: entry)")
                    && sourceBytes(sheet, contain: "case .shared: return L10n.t(\"歌词同步\")")
                    && sourceBytes(sheet, contain: "case .own: return L10n.t(\"独立匹配\")")
                    && sourceBytes(sheet, contain: "case .split: return L10n.t(\"已拆分\")")
                    && sourceBytes(sheet, contain: "let diff = SongVersions.lyricDiff(current: c.shownLines, other: v.shownLines)")
                    && sourceBytes(sheet, contain: "&& shownLines == current.shownLines && shownWords == current.shownWords"), true,
                    "其他写法(契约): 收录的播放器、三种关系、逐句对照接上")
        let rematchEngine = read(engine, "lyricsrematch.go")
        expectEqual(sourceBytes(manager, contain: "let followers = LyricsRematch.followers(of: LyricsRematch.current, key: key)")
                    && sourceBytes(rematchEngine, contain: "Followers int `json:\"followers,omitempty\"`"), true,
                    "其他写法(契约): 重新自动匹配的结论带上同组跟着换了几条")
        expectEqual(sourceBytes(manager, contain: "SongVersionsSheet(summary: summary, onOpen:")
                    && sourceBytes(manager, contain: "Button(L10n.t(\"同曲条目…\")) { showSongVersions = true }"), true,
                    "其他写法(契约): 详情页「⋯」菜单接上弹窗")
        expectEqual(sourceBytes(manager, contain: "let versions = store.songVersionCount(forKey: summary.key)")
                    && sourceBytes(manager, contain: "if versions > 1 {\n                Button { showSongVersions = true } label: {")
                    && sourceBytes(store, contain: "songVersionCounts[song, default: 0] += 1")
                    && sourceBytes(store, contain: "songVersionCounts = bundle.songVersionCounts"), true,
                    "其他写法(契约): 详情页概况那一行露出「同一首歌的 N 种写法」,随列表一起数")
        expectEqual(sourceBytes(sheet, contain: "if v.relation == .current {\n                overview(current)")
                    && sourceBytes(sheet, contain: "allVersionsTable(c)")
                    && sourceBytes(sheet, contain: "if !edges.isEmpty { evidenceSummary }"), true,
                    "其他写法(契约): 选中当前这条时右边是这首歌的概况(总览卡、当前这条的信息、全部写法一览、依据汇总)")
    }
}
