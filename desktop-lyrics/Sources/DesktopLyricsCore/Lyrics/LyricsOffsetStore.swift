import Foundation
import CryptoKit

// 单曲歌词时间轴微调——记住"这首歌的这份歌词该提前/延后多少毫秒",按 trackKey 持久化,
// 下次播放同一首歌、同一份歌词内容时自动生效,不用每次重新调。
//
// key 故意不是单纯的"歌手|歌名"(那样同一首歌换了一份歌词内容——重新匹配到别的源、
// 手动在「歌词管理」编辑过、酷狗/QQ/网易云来回切换——校正值会被错误地继续套用在新歌词
// 上,新歌词的时间轴基准很可能完全不一样)。key 额外拼上这份歌词内容(lyrics+逐字 yrc
// 两个字段一起)算出来的一段短哈希,内容变了 key 自然跟着变,旧的校正值不会被误用到新
// 内容上——不需要显式失效旧记录,只是查不到而已(旧记录留在字典里不清,量很小,
// 跟 EnrichCacheReader 那份"设计上永久不清理"的既有取舍一致)。
//
// 故意跟 EnrichCacheStore(歌词内容缓存)彻底分开存——那份缓存的"清空全部缓存"清的是
// 解析出来的歌词内容,这里存的是用户自己手动校准出来的时间校正值,是更宝贵的个人偏好,
// 不该被"清缓存"这类操作连带清掉。
//
// 跟 AppSettings.customColorThemes 同样的持久化选择:字典编码成 JSON 字符串存进
// UserDefaults(不是裸 Data blob),`defaults read` 还能看懂内容方便调试。
@MainActor
public final class LyricsOffsetStore {
    public static let shared = LyricsOffsetStore()

    private static let defaultsKey = "np:lyricsOffsetsByTrackJSON"

    private var offsets: [String: Int]

    private init() {
        offsets = Self.load()
    }

    // 统一在这里拼 key,调用方(LocalPlaybackSource/RelayPoller)不用各自实现一遍哈希
    // 逻辑。歌词内容(lyrics/lyricsYRC)都还没解析出来时——新歌/纯音乐/还没轮到 enrich——
    // 指纹段留空,key 退化成"歌手|歌名|",不影响生成一个可用但"内容未知"的 key。
    // 故意标 nonisolated——纯函数,不碰 offsets 这份实例状态,不需要 MainActor 隔离,
    // 也方便 selftest(跑在 main.swift 顶层、非 async 上下文)直接调用。
    public nonisolated static func trackKey(artist: String, title: String, lyrics: String, lyricsYRC: String) -> String {
        "\(artist)|\(title)|\(contentFingerprint(lyrics: lyrics, lyricsYRC: lyricsYRC))"
    }

    private nonisolated static func contentFingerprint(lyrics: String, lyricsYRC: String) -> String {
        let combined = lyrics + "\u{1}" + lyricsYRC
        guard combined != "\u{1}" else { return "" }
        let digest = SHA256.hash(data: Data(combined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    public func offset(forKey key: String) -> Int {
        guard isValid(key) else { return 0 }
        return offsets[key] ?? 0
    }

    @discardableResult
    public func nudge(by deltaMs: Int, forKey key: String) -> Int {
        let newValue = offset(forKey: key) + deltaMs
        set(newValue, forKey: key)
        return newValue
    }

    public func reset(forKey key: String) {
        set(0, forKey: key)
    }

    // 直接赋一个绝对值——供"歌词管理"里那个输入框用(用户自己敲一个具体的秒数),跟
    // nudge() 的"在现有值上累加"是两种不同的调用方式,内部走的还是同一个 set()。
    public func setOffset(_ ms: Int, forKey key: String) {
        set(ms, forKey: key)
    }

    // key 是 "歌手|歌名|内容指纹" 拼出来的,三段都是空字符串时(还没拿到过任何曲目信息)
    // 这个 key 毫无意义,不该被当成一个真实的"歌曲"持久化下去。
    private func isValid(_ key: String) -> Bool {
        !key.replacingOccurrences(of: "|", with: "").isEmpty
    }

    private func set(_ ms: Int, forKey key: String) {
        guard isValid(key) else { return }
        if ms == 0 {
            offsets.removeValue(forKey: key)
        } else {
            offsets[key] = ms
        }
        persist()
    }

    private func persist() {
        guard
            let data = try? JSONEncoder().encode(offsets),
            let json = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(json, forKey: Self.defaultsKey)
    }

    private static func load() -> [String: Int] {
        guard
            let json = UserDefaults.standard.string(forKey: defaultsKey),
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else {
            return [:]
        }
        return decoded
    }
}
