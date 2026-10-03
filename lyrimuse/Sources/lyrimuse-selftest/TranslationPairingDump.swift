import CryptoKit
import Foundation
import LyrimuseCore

/// 译文 / 罗马音配对的全库回放:本机缓存里每一首有译文或罗马音的歌,按真实引擎加载,逐个显示行写出
/// 「key、来源、起点、原文、译文、罗马音」(制表符分隔)。改配对规则前后各跑一次、两份逐行比对。
/// 只在给了 `LYRIMUSE_PAIRING_DUMP=<输出文件>` 时跑(sync-engine 组里调用);缓存目录默认 `~/.config/lyrimuse`,
/// `LYRIMUSE_PAIRING_CONFIG_DIR` 可改。
func translationPairingDump(outPath: String) {
    let env = ProcessInfo.processInfo.environment
    let dir = env["LYRIMUSE_PAIRING_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.config/lyrimuse")
    guard let data = FileManager.default.contents(atPath: dir + "/lyrimuse-enrich-cache.json"),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        expectEqual(true, false, "配对回放: 读不到 \(dir)/lyrimuse-enrich-cache.json")
        return
    }
    let entries = (root["entries"] as? [String: [String: Any]]) ?? (root as? [String: [String: Any]]) ?? [:]
    func clean(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
    var out = ""
    var songs = 0
    for key in entries.keys.sorted() {
        guard let entry = entries[key] else { continue }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let bodyPath = dir + "/lyrimuse-lyrics-bodies/\(digest.prefix(32)).json"
        let body = FileManager.default.contents(atPath: bodyPath)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func field(_ name: String) -> String { (body[name] as? String) ?? (entry[name] as? String) ?? "" }
        let tr = field("lyrics_tr"), roma = field("lyrics_roma")
        guard !tr.isEmpty || !roma.isEmpty else { continue }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let engine = LyricsSyncEngine()
        engine.load(lyrics: field("lyrics"), lyricsTr: tr, lyricsRoma: roma, lyricsYRC: field("lyrics_yrc"),
                    trackTitle: parts.count > 1 ? parts[1] : "", trackArtist: parts.first ?? "")
        let source = clean(entry["lyrics_source"] as? String)
        for item in engine.allLines(idPrefix: "d") {
            out += "\(clean(key))\t\(source)\t\(item.timeMs)\t\(clean(item.line.plainText))\t"
                + "\(clean(item.line.translation))\t\(clean(item.line.romanization))\n"
        }
        songs += 1
    }
    do {
        try out.write(toFile: outPath, atomically: true, encoding: .utf8)
    } catch {
        expectEqual(true, false, "配对回放: 写不出 \(outPath)")
    }
    print("配对回放: \(songs) 首写进 \(outPath)")
}
