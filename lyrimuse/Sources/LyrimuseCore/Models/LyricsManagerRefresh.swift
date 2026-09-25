import Foundation

/// 「歌词管理」开着时多久问一次磁盘:列表是开窗那一刻的快照,而 collector 在窗口开着期间会持续往缓存里写
/// (新歌是新增条目,补机翻译文 / 逐字时间轴是原地更新)。
///
/// 每一拍(视图那边 2 / 5 秒一轮)都调一次 `EnrichCacheStore.reload(onlyIfChanged: true)` 本身不贵 —— 文件没变
/// 只是一次 stat;真的变了才重新解析(约 0.7 秒,期间新旧两份快照短暂并存)。所以闲着的时候放慢到
/// `idleInterval` 一次,只有「正在搜的占位行等着被顶替」和「补空扫描在跑」这两种要紧跟的情况才每拍都问。
public enum LyricsManagerRefresh {
    public static let idleInterval: TimeInterval = 30

    /// - Parameters:
    ///   - busy: 有占位行在等、或补空扫描在跑。
    ///   - sinceLastIdle: 距离上一次「闲时」询问过了多久。
    public static func shouldPoll(busy: Bool, sinceLastIdle: TimeInterval) -> Bool {
        busy || sinceLastIdle >= idleInterval
    }
}
