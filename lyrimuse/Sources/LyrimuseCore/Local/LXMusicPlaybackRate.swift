import Foundation

/// 洛雪配置里的播放速度(`config_v2.json` 的 `setting["player.playbackRate"]`)和改它的时刻。洛雪播放中途改速度只改音频元素、
/// 不重报系统会话,只有这里读得到新速度。改完 `saveDelaySecs` 秒才整份写盘(先写临时文件再改名),改的时刻按文件修改时间往前推;
/// 别的设置(音量等)也会整份重写这个文件,速度没变时沿用上次记的时刻。文件修改时间没变不重读。见 02 章决策 130。
public final class LXMusicPlaybackRate: @unchecked Sendable {
    public struct Setting: Equatable, Sendable {
        public let rate: Double
        public let changedAt: Date
        public init(rate: Double, changedAt: Date) {
            self.rate = rate
            self.changedAt = changedAt
        }
    }

    /// 洛雪渲染进程存速度那一步的防抖(`usePlaybackRate.ts` 的 `debounce(savePlaybackRate, 300)`)。
    public static let saveDelaySecs: TimeInterval = 0.3

    public static let shared = LXMusicPlaybackRate(
        configURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/lx-music-desktop/LxDatas/config_v2.json"))

    private let configURL: URL
    private let lock = NSLock()
    private var readModified: Date?
    private var setting: Setting?

    public init(configURL: URL) { self.configURL = configURL }

    public func current() -> Setting? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        if modified == readModified { return setting }
        readModified = modified
        guard let rate = Self.rate(in: FileIO.read(configURL)) else {
            setting = nil
            return nil
        }
        if setting?.rate != rate {
            setting = Setting(rate: rate, changedAt: modified.addingTimeInterval(-Self.saveDelaySecs))
        }
        return setting
    }

    /// 配置文件内容里的速度;没有这一项、不是正数时 nil。
    public static func rate(in data: Data?) -> Double? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let setting = object["setting"] as? [String: Any],
              let rate = (setting["player.playbackRate"] as? NSNumber)?.doubleValue, rate > 0 else { return nil }
        return rate
    }
}
