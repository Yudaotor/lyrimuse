import Foundation

// 单曲歌词时间轴微调——记住"这首歌的歌词该提前/延后多少毫秒",按 trackKey("歌手|歌名",
// 跟 MediaControlSnapshot/NowPlayingState.trackKey 完全一致)持久化,下次播放同一首歌
// 自动生效,不用每次重新调。
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

    // trackKey 是 "歌手|歌名" 拼出来的,两边都是空字符串时(还没拿到过任何曲目信息)
    // 这个 key 毫无意义,不该被当成一个真实的"歌曲"持久化下去。
    private func isValid(_ key: String) -> Bool {
        !key.isEmpty && key != "|"
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
