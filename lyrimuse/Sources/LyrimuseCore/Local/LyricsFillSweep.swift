import Foundation

/// App ⇄ collector 的「补空扫描」通道(2026-09-05,见 collector/lyricsfillsweep.go 头注)。
///
/// 背景:collector 给空歌词条目再搜一轮的补空路径,设计上只在这首歌**再次被播放**时触发;
/// 「歌词管理」里躺着的存量空条目用户不重播就永远不会动。这条通道让用户在窗口里主动要一轮:
///   - 请求:往 `lyrimuse-lyrics-fill-request.txt` 写一份纯文本(一行 `all` / 一行 `cancel` /
///     每行一个缓存 key),collector 2 秒内读到就消费掉(删文件)并开一轮——形制同「停止搜索」
///     那份 `lyrimuse-enrich-cancel-request.txt`(LyricsManagerView.cancelPlaceholderSearch)。
///   - 进度:collector 把这一轮的进度写到 `lyrimuse-lyrics-fill-status.json`,这里按 mtime 读
///     (同 CollectorStatus)。文件不存在 = 这个进程还没跑过任何一轮。
///
/// collector 没在跑时请求文件会一直留着,下次它起来先清掉(setLyricsFillPaths)——不会把
/// 上一次进程的请求当成新请求执行。
public enum LyricsFillSweep {
    public struct Info: Decodable, Equatable, Sendable {
        public let running: Bool
        public let manual: Bool
        public let total: Int
        public let done: Int
        public let filled: Int
        public let current: String?
        public let startedAt: Int64
        public let updatedAt: Int64
        public let finishedAt: Int64?
        public let cancelled: Bool?

        public init(running: Bool, manual: Bool, total: Int, done: Int, filled: Int, current: String?,
                    startedAt: Int64, updatedAt: Int64, finishedAt: Int64?, cancelled: Bool?) {
            self.running = running
            self.manual = manual
            self.total = total
            self.done = done
            self.filled = filled
            self.current = current
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.finishedAt = finishedAt
            self.cancelled = cancelled
        }
    }

    static let requestURL = LyrimusePaths.configFile("lyrimuse-lyrics-fill-request.txt")
    static let statusURL = LyrimusePaths.configFile("lyrimuse-lyrics-fill-status.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: Info?

    /// 最近一轮的进度;文件不存在/解析失败都是 nil。
    public static var current: Info? {
        lock.lock()
        defer { lock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: statusURL.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = (try? Data(contentsOf: statusURL)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
        return cached
    }

    /// 请求文件的内容——纯函数,selftest 覆盖(collector 侧 parseLyricsFillRequest 是它的读方)。
    /// keys 为空 = 全部;非空 = 只这些。key 原样写,一行一个;含换行的 key 不存在
    /// (EnrichCacheKeys 由 media tag 拼成,tag 里不会有换行)。
    public static func requestBody(keys: [String]) -> String {
        if keys.isEmpty { return "all\n" }
        return keys.joined(separator: "\n") + "\n"
    }

    /// 要一轮补空:keys 为空 = 全部符合条件的空条目。返回写文件是否成功。
    @discardableResult
    public static func request(keys: [String]) -> Bool {
        (try? requestBody(keys: keys).write(to: requestURL, atomically: true, encoding: .utf8)) != nil
    }

    /// 停掉正在跑的这一轮。
    @discardableResult
    public static func requestCancel() -> Bool {
        (try? "cancel\n".write(to: requestURL, atomically: true, encoding: .utf8)) != nil
    }
}
