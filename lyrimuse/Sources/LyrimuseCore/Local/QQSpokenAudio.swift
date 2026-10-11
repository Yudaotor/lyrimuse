import Foundation

/// QQ 音乐的这一条是不是有声书 / 有声节目。QQ 放它们时系统那份读数跟歌一模一样(主播报成歌手、这一集报成歌名、节目名报成
/// 专辑),本地曲库里也没有能分开的列,只能拿 songmid 问歌曲详情(`QQSongInfo.isSpokenAudio`,跟歌曲简介同一个接口)。
/// 判成有声节目的,字幕(QQ 给它配的逐字「AI智能字幕」)照常显示,但不当歌:引擎不发正在播放、不记收听、不预取,Discord
/// 不显示(见 `PlaybackStateFile.Track.spoken`)。结论按 songmid 记在内存里,一个 mid 只问一次;没问成的
/// `retryAfterFailureSecs` 之内不再问。见 02 章决策 118。
public final class QQSpokenAudio: @unchecked Sendable {
    public static let shared = QQSpokenAudio()

    private let lock = NSLock()
    private var known: [String: Bool] = [:]
    private var inFlight: Set<String> = []
    private var failedAt: [String: Date] = [:]

    /// 记住的结论最多这么多条,满了整个清掉(一首歌的 mid 一会儿再问一次的代价很小)。
    static let cacheLimit = 500
    /// 没问成之后多久再问。
    static let retryAfterFailureSecs: TimeInterval = 30

    public init() {}

    /// 记过的结论;没问过或者没问成为 nil。
    public func cached(mid: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return known[mid]
    }

    /// 问一次这个 mid 是不是有声节目,问到了回调结论(在后台线程)。已经在问、刚没问成的不再发,也不回调。
    public func classify(mid: String, now: Date = Date(), completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        if let verdict = known[mid] {
            lock.unlock()
            return completion(verdict)
        }
        if inFlight.contains(mid) || failedAt[mid].map({ now.timeIntervalSince($0) < Self.retryAfterFailureSecs }) == true {
            lock.unlock()
            return
        }
        inFlight.insert(mid)
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            let verdict = await QQSongInfo.fetchDetail(songMID: mid).flatMap(QQSongInfo.isSpokenAudio(fromDetail:))
            lock.lock()
            inFlight.remove(mid)
            if let verdict {
                if known.count >= Self.cacheLimit { known.removeAll() }
                known[mid] = verdict
                failedAt[mid] = nil
            } else {
                failedAt[mid] = Date()
            }
            lock.unlock()
            if let verdict { completion(verdict) }
        }
    }
}
