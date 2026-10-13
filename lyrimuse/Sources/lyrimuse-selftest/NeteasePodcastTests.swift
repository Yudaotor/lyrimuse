import Foundation
import LyrimuseCore

/// 网易云播客单集:从 `playingList` 认出当前这一条是单集、授权闸、文件缓存、接线契约。条目照真实文件的形状造
/// (单集的 `track` 没有 `artists`,主播在 `creator.nickname`)。
@MainActor
func runNeteasePodcastTests() {
    typealias Q = NeteasePodcastQueue
    func voice(_ name: String, host: String?, type: String = "voice") -> [String: Any] {
        var track: [String: Any] = ["name": name, "duration": 1_288_671, "programId": "3729609589"]
        if let host { track["creator"] = ["nickname": host, "anchor": true] }
        return ["resourceType": type, "text": "彼岸的音乐日记", "track": track]
    }
    func song(_ name: String, artist: String) -> [String: Any] {
        ["resourceType": "track", "track": ["name": name, "artists": [["name": artist]], "album": ["name": "专辑"]]]
    }
    func body(_ list: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["list": list])
    }

    // ---- 解析与匹配 ----
    do {
        let eps = Q.episodes(fromQueueJSON: body([
            voice("三首听了就泪目的经典老歌", host: "NJ彼岸"),
            voice("下载的那一集", host: "NJ彼岸", type: "downloadVoice"),
            voice("本地的一集", host: nil, type: "localVoice"),
            song("念想", artist: "喔喔"),
        ]))
        expectEqual(eps.map { Set($0.keys) }, ["三首听了就泪目的经典老歌", "下载的那一集", "本地的一集"],
                    "网易云播客: 只收三种单集条目,歌不收")
        let e = eps ?? [:]
        expectEqual(Q.contains(e, title: "三首听了就泪目的经典老歌", artist: "NJ彼岸"), true, "网易云播客: 歌名 + 主播对上")
        expectEqual(Q.contains(e, title: " 三首听了就泪目的经典老歌 ", artist: "nj彼岸"), true, "网易云播客: 两头空白、大小写不计")
        expectEqual(Q.contains(e, title: "三首听了就泪目的经典老歌", artist: "别人"), false,
                    "网易云播客: 同名但歌手不是主播(停着的旧列表里有同名单集)不算")
        expectEqual(Q.contains(e, title: "本地的一集", artist: "随便谁"), true, "网易云播客: 条目没记主播时只看歌名")
        expectEqual(Q.contains(e, title: "念想", artist: "喔喔"), false, "网易云播客: 歌不算")
        expectEqual(Q.episodes(fromQueueJSON: Data("{}".utf8)) == nil, true, "网易云播客: 不是队列文件的形状")
        expectEqual(Q.episodes(fromQueueJSON: Data("not json".utf8)) == nil, true, "网易云播客: 解析不了")
    }

    // ---- 读文件:只认网易云、授权闸、按 mtime 重读 ----
    do {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-selftest-netease-podcast-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try! body([voice("一集", host: "主播")]).write(to: url)
        func check(_ bundle: String? = Q.bundleID, title: String = "一集", readable: Bool = true) -> Bool {
            Q.isEpisode(bundleID: bundle, title: title, artist: "主播", queueURL: url, readable: readable)
        }
        expectEqual(check(), true, "网易云播客: 文件里有这一集")
        expectEqual(check("com.tencent.QQMusicMac"), false, "网易云播客: 别的播放器不看")
        expectEqual(check(readable: false), false, "网易云播客: 引擎没确认读得到网易云时不读(免得系统弹框)")
        expectEqual(check(title: "  "), false, "网易云播客: 歌名为空")
        try! body([song("一集", artist: "主播")]).write(to: url)
        let later = Date().addingTimeInterval(5)
        try! FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        expectEqual(check(), false, "网易云播客: 文件改写后重读(换成了歌单)")
        let missing = url.appendingPathExtension("missing")
        expectEqual(Q.isEpisode(bundleID: Q.bundleID, title: "一集", artist: "主播", queueURL: missing, readable: true), false,
                    "网易云播客: 文件不在")
    }

    // ---- 接线契约(扫源码)----
    do {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let client = (try? String(contentsOfFile: sources.appendingPathComponent("LyrimuseCore/Local/MediaControlClient.swift").path,
                                  encoding: .utf8)) ?? ""
        expectEqual(client.contains("guard artistless || neteasePodcastEpisode(bundleID: bundleID, snapshot: snapshot)\n                || spotifyContentNotMusic(bundleID: bundleID, snapshot: snapshot) else { return false }")
                        && client.contains("guard NeteasePodcastQueue.isEpisode(bundleID: bundleID, title: snapshot.title, artist: snapshot.artist) else {"),
                    true, "网易云播客 契约: 跟 KKBOX / Amazon 的播客走同一道「不是音乐」的闸")
        var calls = 0
        var rest = client[...]
        while let r = rest.range(of: "if playerContentNotMusic(") {
            calls += 1
            rest = rest[r.upperBound...]
        }
        expectEqual(calls, 4, "网易云播客 契约: 自动识别、多选两处、焦点回退四个入口都过这道闸")
    }
}
