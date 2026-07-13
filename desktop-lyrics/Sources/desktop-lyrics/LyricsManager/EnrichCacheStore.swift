import Foundation
import os

private let logger = Logger(subsystem: "com.chenyuhao.applemusic-desktop-lyrics", category: "lyrics-manager")

// 歌词管理窗口的数据层。跟 EnrichCacheReader(单条只读查询)不同,这里要读写整个缓存
// 文件——collector(Go)是这个文件的唯一真源,自己在内存里维护整个 map,每次存盘都是
// "把整个内存 map 序列化覆盖写"(collector/enrich.go 的 saveEnrichCache()),不是增量
// 合并。所以这里每次改完必须做两件事:①先把改动落盘;②立刻踢一脚重启 collector(跟
// 这个 session 手动清缓存用的是同一套 `launchctl kickstart` 手法),让 collector 从
// 磁盘重新加载——不这么做的话,只要用户还在听歌,collector 随时可能因为解析别的曲目
// 而触发一次自己的存盘,用内存里那份"没看到这次改动"的旧状态整个覆盖回磁盘,悄悄撤销
// 刚做的修改。代价是每次保存/删除都会让 collector 短暂重启一次,"现在播放"推送有个
// 小间隙——个人工具偶尔手动操作这个代价可以接受,换来的是不用给 collector 另开一个
// 常驻 HTTP/IPC 接口。
//
// 用 JSONSerialization 而不是 Codable 读写整个文件:enrichEntry(collector/enrich.go)
// 目前有十几个字段,如果 Swift 侧用一个只声明"我关心的几个字段"的 Codable 结构体去
// 解码整个文件、改完再编码回去,**每一条**(不只是被编辑的那条)都会被这个窄结构体
// 悄悄丢掉它没声明的字段——这是会破坏其它上百条数据的严重 bug,而且 Go 那边字段以后
// 还可能再加。改用 [String: [String: Any]] 原始字典,只对被编辑/删除的那一条 key 做
// 字典级别的增删改,其它条目、以及被编辑条目里没碰过的字段,原样保留、逐字节不变。
@MainActor
public final class EnrichCacheStore: ObservableObject {
    public static let shared = EnrichCacheStore()

    public struct Summary: Identifiable {
        public var id: String { key }
        public let key: String
        public let artist: String
        public let title: String
        public let album: String
        public let lyricsSource: String
        public let hasWordTiming: Bool
        public let isManual: Bool
        public let hasLyrics: Bool
    }

    @Published public private(set) var summaries: [Summary] = []
    @Published public private(set) var lastError: String?

    private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/applemusic-nowplaying/applemusic-nowplaying-enrich-cache.json")
    private static let collectorLabel = "com.chenyuhao.applemusic-nowplaying"

    private var raw: [String: [String: Any]] = [:]

    private init() {}

    public func reload() {
        guard let data = try? Data(contentsOf: Self.cacheURL) else {
            raw = [:]
            summaries = []
            lastError = "读取缓存文件失败"
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            raw = [:]
            summaries = []
            lastError = "解析缓存文件失败"
            return
        }
        raw = obj
        lastError = nil
        rebuildSummaries()
    }

    // key 的拼法是 collector 那边的 "歌手|歌名|专辑"(见 collector/enrich.go:93)。
    // 只按前两个 "|" 分,专辑名里偶尔出现的 "|" 不会把切分打乱(艺人/歌名本身含 "|"
    // 这种更罕见的情况不额外处理)。
    private static func splitKey(_ key: String) -> (artist: String, title: String, album: String)? {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    private func rebuildSummaries() {
        summaries = raw.keys.compactMap { key -> Summary? in
            guard let parts = Self.splitKey(key) else { return nil }
            let entry = raw[key] ?? [:]
            let lyrics = entry["lyrics"] as? String ?? ""
            return Summary(
                key: key,
                artist: parts.artist,
                title: parts.title,
                album: parts.album,
                lyricsSource: entry["lyrics_source"] as? String ?? "",
                hasWordTiming: !(entry["lyrics_yrc"] as? String ?? "").isEmpty,
                isManual: entry["manual_lyrics"] as? Bool ?? false,
                hasLyrics: !lyrics.isEmpty
            )
        }.sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
    }

    public func detail(for key: String) -> (lyrics: String, tr: String, roma: String) {
        let entry = raw[key] ?? [:]
        return (
            entry["lyrics"] as? String ?? "",
            entry["lyrics_tr"] as? String ?? "",
            entry["lyrics_roma"] as? String ?? ""
        )
    }

    public func saveEdit(key: String, lyrics: String, tr: String, roma: String) {
        var entry = raw[key] ?? [:]
        entry["lyrics"] = lyrics
        entry["lyrics_tr"] = tr
        entry["lyrics_roma"] = roma
        entry["manual_lyrics"] = true
        raw[key] = entry
        persistAndRestart()
        rebuildSummaries()
    }

    // 只清掉逐字时间轴,保留整行歌词——用户发现某首歌的逐字对不上、想退回整行显示,
    // 不用整条删掉重新解析(重新解析很可能又抓到同一份不准的 yrc)。
    public func removeWordTiming(key: String) {
        var entry = raw[key] ?? [:]
        entry.removeValue(forKey: "lyrics_yrc")
        raw[key] = entry
        persistAndRestart()
        rebuildSummaries()
    }

    public func delete(key: String) {
        raw.removeValue(forKey: key)
        persistAndRestart()
        rebuildSummaries()
    }

    private func persistAndRestart() {
        guard JSONSerialization.isValidJSONObject(raw) else {
            lastError = "内部数据不是合法 JSON,已放弃保存"
            logger.error("raw dict is not valid JSON, aborting save")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: raw)
            try data.write(to: Self.cacheURL, options: .atomic)
        } catch {
            lastError = "写入缓存文件失败: \(error.localizedDescription)"
            logger.error("write failed: \(String(describing: error), privacy: .public)")
            return
        }
        restartCollector()
    }

    // 跟 collector/build.sh 重启自己用的是同一条命令——collector 启动时会完整重新读盘,
    // 这一脚踢下去就能保证它的内存状态跟磁盘上刚写的内容一致,不会有竞态。
    private func restartCollector() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.collectorLabel)"]
        do {
            try process.run()
            logger.info("restarted collector via launchctl kickstart")
        } catch {
            lastError = "重启 collector 失败: \(error.localizedDescription)"
            logger.error("launchctl kickstart failed: \(String(describing: error), privacy: .public)")
        }
    }
}
