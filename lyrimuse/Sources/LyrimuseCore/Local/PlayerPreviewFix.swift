import Foundation

/// 汽水音乐非会员「试听」的换算通道(collector 发布、App 只读)。
///
/// 试听时 MediaRemote 报的是**试听段自己的时间轴**:duration 是试听段长度(30 / 60s),elapsedTime
/// 从 0 起;而试听段是从整首歌中间截的一段(`preview.start`)。不换算的话进度条只有试听段那么长、
/// 歌词时间轴整段对不上。试听段信息要从汽水自己的缓存或搜索接口里拿 —— 读外部播放器数据是
/// collector 的活(见 `lyrimuse-collector/sodapreview.go`),这里只按它发布的结论换算。
///
/// 两边必须同时换:collector 已经用原曲口径去匹配歌词、写缓存,App 这边还按试听段显示的话,
/// 歌词时间轴和位置各说各话。
public enum PlayerPreviewFix {
    public struct State: Decodable, Equatable, Sendable {
        public var bundle: String
        public var title: String
        public var artist: String
        public var previewStart: Double
        public var previewDuration: Double
        public var fullDuration: Double

        public init(bundle: String, title: String, artist: String,
                    previewStart: Double, previewDuration: Double, fullDuration: Double) {
            self.bundle = bundle
            self.title = title
            self.artist = artist
            self.previewStart = previewStart
            self.previewDuration = previewDuration
            self.fullDuration = fullDuration
        }
    }

    /// 与 collector 的 `clientName+"-player-preview.json"` 逐字节一致。
    public static let stateURL = LyrimusePaths.configFile("lyrimuse-player-preview.json")
    /// 快照报的时长与试听段长度最多差多少还算同一段(与 collector 的 sodaPreviewDurationTolerance 一致)。
    public static let durationTolerance: Double = 1.5

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: State?

    /// 当前这条换算;文件不存在 / 解析失败都是 nil。按 mtime 缓存,同 `PlayerArtistFix.current`。
    public static var current: State? {
        lock.lock()
        defer { lock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: stateURL.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        return cached
    }

    /// 这份快照能不能套这条换算。纯函数,selftest 直接覆盖。
    ///
    /// 同一个播放器、同一首(曲名 + 歌手逐字相等,两边读的是同一份载荷),并且这一拍报的时长**还是**
    /// 试听段长度 —— 换歌、转成整首播放(开了会员 / 限免)都自然失效。
    public static func applies(_ state: State, to snapshot: MediaControlSnapshot) -> Bool {
        guard snapshot.bundleIdentifier == state.bundle, snapshot.title == state.title,
              snapshot.artist == state.artist, let duration = snapshot.duration,
              state.fullDuration > state.previewDuration
        else { return false }
        return abs(duration - state.previewDuration) <= durationTolerance
    }

    /// 把换算应用到快照上:时长换成整首,位置与原始锚点加上试听段起点。对不上就原样返回。
    public static func applied(
        to snapshot: MediaControlSnapshot?, state: State? = current
    ) -> MediaControlSnapshot? {
        guard let snapshot, let state, applies(state, to: snapshot) else { return snapshot }
        return snapshot.withPreviewOffset(start: state.previewStart, fullDuration: state.fullDuration)
    }
}
