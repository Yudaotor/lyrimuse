import Foundation
import os

/// 缓存目录超出磁盘预算时按修改时间删最旧的,删到预算以内。列目录、读大小和修改时间、删文件都在自己的串行队列上做,
/// `request()` 当场返回,调用方不等结果。动态封面和 Spotify Canvas 每下完一份就请求一次。
///
/// 请求合并:排着队、还没开始跑时再来的请求并进那一次;已经开始跑了再来的,在后面另排一次(开跑前先清标记),
/// 所以并发下载时不会重复跑,也不会漏掉跑的过程中刚落盘的那一份。见 03 章决策 73。
public final class CacheBudgetPruner: @unchecked Sendable {
    public let directory: URL
    public let budgetBytes: Int64
    /// 计入预算的扩展名。
    public let extensions: Set<String>
    /// 见到就删的扩展名(中途失败留下的临时文件,预算不数它们、永远删不到)。
    public let orphanExtensions: Set<String>
    private let label: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var scheduled = false
    private var completedRuns = 0
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "cache-prune")

    /// `queue` 只给测试换(挂起它就能看请求怎么合并)。
    public init(label: String, directory: URL, budgetBytes: Int64, extensions: Set<String>,
                orphanExtensions: Set<String> = [], queue: DispatchQueue? = nil) {
        self.label = label
        self.directory = directory
        self.budgetBytes = budgetBytes
        self.extensions = extensions
        self.orphanExtensions = orphanExtensions
        self.queue = queue ?? DispatchQueue(label: "me.yudaotor.lyrimuse.cache-prune.\(label)", qos: .utility)
    }

    /// 排一次清理;已经排着、还没开始的就不再排。
    public func request() {
        lock.lock()
        let already = scheduled
        scheduled = true
        lock.unlock()
        guard !already else { return }
        queue.async { [self] in
            lock.lock()
            scheduled = false
            lock.unlock()
            prune()
            lock.lock()
            completedRuns += 1
            lock.unlock()
        }
    }

    /// 跑完了几次。
    public var runs: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedRuns
    }

    /// 等已经排进队列的清理跑完(测试用)。
    public func waitUntilIdle() {
        queue.sync {}
    }

    private func prune() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in items {
            if orphanExtensions.contains(url.pathExtension) {
                try? fm.removeItem(at: url)
                continue
            }
            guard extensions.contains(url.pathExtension),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let size = Int64(values.fileSize ?? 0)
            files.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > budgetBytes else { return }
        var removed = 0
        var removedBytes: Int64 = 0
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > budgetBytes else { break }
            guard (try? fm.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            removed += 1
            removedBytes += file.size
        }
        Self.logger.info("\(self.label, privacy: .public): pruned \(removed, privacy: .public) files, \(removedBytes / 1024, privacy: .public)KB")
    }
}
