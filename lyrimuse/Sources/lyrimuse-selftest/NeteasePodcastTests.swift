import Foundation
import LyrimuseCore

/// 网易云播客单集:按引擎写的单集名单认出当前这一条是单集、名单缓存、接线契约;App 不读别的 App 的容器。
@MainActor
func runNeteasePodcastTests() {
    typealias Q = NeteasePodcastQueue
    func state(_ episodes: [[String: String]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["updatedAt": 1, "episodes": episodes])
    }

    // ---- 解析与匹配 ----
    do {
        let eps = Q.episodes(fromStateJSON: state([
            ["title": "三首听了就泪目的经典老歌", "host": "NJ彼岸"],
            ["title": "下载的那一集", "host": "NJ彼岸"],
            ["title": "本地的一集", "host": ""],
            ["title": "  ", "host": "空名字"],
        ]))
        expectEqual(eps.map { Set($0.keys) }, ["三首听了就泪目的经典老歌", "下载的那一集", "本地的一集"],
                    "网易云播客: 名单里的单集都收,空名字不收")
        let e = eps ?? [:]
        expectEqual(Q.contains(e, title: "三首听了就泪目的经典老歌", artist: "NJ彼岸"), true, "网易云播客: 歌名 + 主播对上")
        expectEqual(Q.contains(e, title: " 三首听了就泪目的经典老歌 ", artist: "nj彼岸"), true, "网易云播客: 两头空白、大小写不计")
        expectEqual(Q.contains(e, title: "三首听了就泪目的经典老歌", artist: "别人"), false,
                    "网易云播客: 同名但歌手不是主播(停着的旧列表里有同名单集)不算")
        expectEqual(Q.contains(e, title: "本地的一集", artist: "随便谁"), true, "网易云播客: 条目没记主播时只看歌名")
        expectEqual(Q.contains(e, title: "念想", artist: "喔喔"), false, "网易云播客: 名单里没有的不算")
        expectEqual(Q.episodes(fromStateJSON: state([])) == [:], true, "网易云播客: 空名单(读得到列表、里面没有单集)")
        expectEqual(Q.episodes(fromStateJSON: Data("{}".utf8)) == nil, true, "网易云播客: 不是名单文件的形状")
        expectEqual(Q.episodes(fromStateJSON: Data("not json".utf8)) == nil, true, "网易云播客: 解析不了")
    }

    // ---- 读名单:只认网易云、按 mtime 重读、名单不在就不认 ----
    do {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-selftest-netease-episodes-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try! state([["title": "一集", "host": "主播"]]).write(to: url)
        func check(_ bundle: String? = Q.bundleID, title: String = "一集") -> Bool {
            Q.isEpisode(bundleID: bundle, title: title, artist: "主播", stateURLs: [url])
        }
        expectEqual(check(), true, "网易云播客: 名单里有这一集")
        expectEqual(check("com.tencent.QQMusicMac"), false, "网易云播客: 别的播放器不看")
        expectEqual(check(title: "  "), false, "网易云播客: 歌名为空")
        try! state([]).write(to: url)
        let later = Date().addingTimeInterval(5)
        try! FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        expectEqual(check(), false, "网易云播客: 名单改写后重读(列表换成了歌)")
        let missing = url.appendingPathExtension("missing")
        expectEqual(Q.isEpisode(bundleID: Q.bundleID, title: "一集", artist: "主播", stateURLs: [missing]), false,
                    "网易云播客: 名单不在(没授权、引擎没在跑)就不认")

        let iPad = url.appendingPathExtension("ipad")
        defer { try? FileManager.default.removeItem(at: iPad) }
        try! state([["title": "卖酱香饼和当老师，哪个更有前途？", "host": "网易每日轻松一刻"]]).write(to: iPad)
        expectEqual(Q.isEpisode(bundleID: Q.bundleID, title: "卖酱香饼和当老师，哪个更有前途？", artist: "网易每日轻松一刻",
                                stateURLs: [missing, iPad]), true,
                    "网易云播客: Mac 版名单不在时 iPad 版名单里有这一集也认")
        expectEqual(Q.isEpisode(bundleID: Q.bundleID, title: "一集", artist: "主播", stateURLs: [url, iPad]), false,
                    "网易云播客: 两份名单都没有就不认")
        let same = Date().addingTimeInterval(-60)
        try! state([["title": "甲集", "host": "甲"]]).write(to: url)
        try! state([["title": "乙集", "host": "乙"]]).write(to: iPad)
        for file in [url, iPad] { try! FileManager.default.setAttributes([.modificationDate: same], ofItemAtPath: file.path) }
        expectEqual([Q.isEpisode(bundleID: Q.bundleID, title: "甲集", artist: "甲", stateURLs: [url]),
                     Q.isEpisode(bundleID: Q.bundleID, title: "乙集", artist: "乙", stateURLs: [iPad])], [true, true],
                    "网易云播客: 两份名单各缓存各的(大小、修改时间一样也不串)")
        expectEqual(Q.stateURLs.map(\.lastPathComponent), ["lyrimuse-netease-episodes.json", "lyrimuse-netease-ipad-episodes.json"],
                    "网易云播客: 默认认 Mac 版和 iPad 版两份名单(文件名跟引擎写的一致)")
    }

    // ---- 接线契约(扫源码)----
    do {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let client = (try? String(contentsOfFile: sources.appendingPathComponent("LyrimuseCore/Local/MediaControlClient.swift").path,
                                  encoding: .utf8)) ?? ""
        expectEqual(sourceHas(client, "guard artistless || neteasePodcastEpisode(bundleID: bundleID, snapshot: snapshot)\n                || spotifyContentNotMusic(bundleID: bundleID, snapshot: snapshot)\n")
                        && client.contains("guard NeteasePodcastQueue.isEpisode(bundleID: bundleID, title: snapshot.title, artist: snapshot.artist) else {"),
                    true, "网易云播客 契约: 跟 KKBOX / Amazon 的播客走同一道「不是音乐」的闸")
        var calls = 0
        var rest = client[...]
        while let r = rest.range(of: "if playerContentNotMusic(") {
            calls += 1
            rest = rest[r.upperBound...]
        }
        expectEqual(calls, 4, "网易云播客 契约: 自动识别、多选两处、焦点回退四个入口都过这道闸")

        // App 是前台进程:没有完全磁盘访问时读别的 App 的沙盒容器,系统会弹「想访问其他 App 的数据」。
        // 读播放器容器里的文件只放在引擎里(引擎被拒时系统不弹框),App 只读引擎写到自己配置目录里的结论。
        var offenders: [String] = []
        var scanned = 0
        for target in ["LyrimuseCore", "lyrimuse"] {
            let root = sources.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard let text = try? String(contentsOfFile: root.appendingPathComponent(rel).path, encoding: .utf8) else { continue }
                scanned += 1
                guard sourceBytes(text, contain: "Containers") else { continue }
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && (line.contains("Library/Containers") || line.contains("Group Containers")) {
                    offenders.append("\(target)/\(rel):\(i + 1)")
                }
            }
        }
        expectEqual(scanned > 70, true, "容器读取 契约: 两个 target 都扫到了源文件(\(scanned) 个)")
        expectEqual(offenders, [], "容器读取 契约: App 不读别的 App 的沙盒容器(会弹「想访问其他 App 的数据」),交给引擎读")
    }
}
