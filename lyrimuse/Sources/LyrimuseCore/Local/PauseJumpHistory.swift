import Foundation

/// 暂停那一拍屏上位置跳了多少(`pause transition` 的 delta = 冻结值 − 暂停那一刻屏上位置),按播放器记最近几次。
///
/// 位置算对时暂停前后不该跳。同一个播放器的 delta 长期偏向一边,说明它的位置模型有系统偏差:暂停前整首偏快或偏慢,
/// 暂停一下才对齐。只记被暂停事件当场冻住的那几次(屏上位置是事件那一刻的),超过 `maxRecordedSecs` 的不记
/// (暂停中拖过 / 事件没跟上)。只用于诊断,不参与位置计算。见 02 章决策 223。
public struct PauseJumpHistory: Codable, Equatable, Sendable {
    public var deltasByBundleID: [String: [Double]] = [:]

    public init(deltasByBundleID: [String: [Double]] = [:]) {
        self.deltasByBundleID = deltasByBundleID
    }

    /// 每个播放器留最近这么多次。
    public static let capacity = 12
    /// 至少这么多次才下结论。
    public static let minSamples = 6
    /// 中位数偏离 0 超过这么多算偏向一边。真机上位置准的播放器 |delta| 多在 0.06 以内。
    public static let biasThresholdSecs = 0.1
    public static let maxRecordedSecs = 1.0

    /// 记一次;返回这一次是不是让这个播放器从「没偏」变成「偏向一边」(日志只在翻转那一下打)。
    @discardableResult
    public mutating func record(_ delta: Double, bundleID: String) -> Bool {
        guard abs(delta) <= Self.maxRecordedSecs else { return false }
        let wasBiased = isBiased(bundleID)
        var list = deltasByBundleID[bundleID] ?? []
        list.append(delta)
        if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        deltasByBundleID[bundleID] = list
        return !wasBiased && isBiased(bundleID)
    }

    public func median(_ bundleID: String) -> Double? {
        guard let list = deltasByBundleID[bundleID], !list.isEmpty else { return nil }
        let sorted = list.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    public func isBiased(_ bundleID: String) -> Bool {
        guard let list = deltasByBundleID[bundleID], list.count >= Self.minSamples, let median = median(bundleID) else { return false }
        return abs(median) > Self.biasThresholdSecs
    }

    /// 诊断报告里那几行。delta > 0 = 暂停时屏上往前跳(暂停前偏慢),< 0 = 往回跳(暂停前偏快)。
    public func diagnosticLines() -> [String] {
        guard !deltasByBundleID.isEmpty else { return ["Pause jumps: none recorded"] }
        var lines = ["Pause jumps (frozen − shown at the pause event, last \(Self.capacity) per player; > 0 = lyrics were behind):"]
        for bundleID in deltasByBundleID.keys.sorted() {
            guard let list = deltasByBundleID[bundleID], let median = median(bundleID) else { continue }
            let verdict = isBiased(bundleID) ? "  BIASED" : (list.count < Self.minSamples ? "  (too few)" : "")
            let recent = list.suffix(4).map { String(format: "%+.2f", $0) }.joined(separator: " ")
            lines.append(String(format: "  %@: n=%d median=%+.3fs recent=[%@]%@", bundleID, list.count, median, recent, verdict))
        }
        return lines
    }
}
