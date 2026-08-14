import Foundation

/// 读 collector 落盘的状态文件(lyrimuse-collector-status.json)。
///
/// 眼下只有一件事:**这一轮歌词解析一无所获,是因为网络不通**。
///
/// 为什么需要这条通道:歌词全空时 collector 故意不写缓存(collector/enrich.go 里那句
/// "全空(可能网络抽风)不写入,下次再试,别把偶发失败钉死")——这个取舍是对的,但它让
/// 界面永远等不到结论:hasLyricsContent 一直 false,于是悬浮窗一直显示"搜索歌词中…"。
/// 用户看到的是"正在搜",实际是"没网,而且永远不会有结果"。
///
/// 这跟 currentTrackHasNoLyrics 解决的是同一类问题的另一半:那个回答"查过了,这首歌
/// 没有";这个回答"根本没查成"。两者都是为了不让界面无限期转圈。
///
/// 形制跟 LastfmMirrorStatus 一致(collector 写 / Swift 按 mtime 读),差别只在这份是
/// 播放热路径上每 2 秒问一次,所以 mtime 缓存不是优化而是必需 —— 不能每次都读盘解码。
public enum CollectorStatus {
    public struct Info: Decodable, Equatable, Sendable {
        public let networkDown: Bool
        public let at: Int64
    }

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-collector-status.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: Info?

    /// 当前状态;文件不存在/解析失败都是 nil(collector 有结果时会把文件删掉)。
    public static var current: Info? {
        lock.lock()
        defer { lock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
        return cached
    }

    /// 网络是不是不通。文件不在/读不懂一律当作"正常" —— 这个提示的作用是解释"为什么
    /// 一直没歌词",拿不准时**不该**替 collector 下这个结论。
    public static var networkLooksDown: Bool {
        current?.networkDown ?? false
    }
}
