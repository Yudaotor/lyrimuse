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
        expectEqual(sourceBytes(manager, contain: "SongVersionsSheet(summary: summary, onOpen:")
                    && sourceBytes(manager, contain: "Button(L10n.t(\"同一首歌的其他写法…\")) { showSongVersions = true }"), true,
                    "其他写法(契约): 详情页「⋯」菜单接上弹窗")
    }
}
