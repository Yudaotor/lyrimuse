import Foundation

/// 一行歌词的显示窗口:从本句时间戳到下一句时间戳,最后一句到曲末。
///
/// 按时长配速的滚动(悬浮歌词没有逐字时间轴的行与副行、菜单栏双排)都读它。悬浮歌词和
/// `PlaybackCoordinator.currentLineDwellSeconds` 共用这一份,别在调用方各写一遍。
public struct LyricDisplayWindow: Equatable, Sendable {
    /// 本句开始显示的时刻(歌词时间轴毫秒)。
    public let startMs: Int
    /// 会显示多久。nil = 算不出来:最后一句且不知道曲长,或时间戳异常(乱序 / 重复)导致
    /// 窗口不到 `minDwellMs` —— 调用方拿它做除数,别返回 0 或负数。
    public let dwellMs: Int?

    public init(startMs: Int, dwellMs: Int?) {
        self.startMs = startMs
        self.dwellMs = dwellMs
    }

    /// 窗口短于这个就当算不出来。
    public static let minDwellMs = 50

    /// - Parameter index: 当前行下标;nil 或越界返回 nil(没有当前行)。
    /// - Parameter starts: 每一行的时间戳(毫秒),与行一一对应。
    /// - Parameter trackDurationMs: 曲长,只给最后一句兜底。
    public static func of<C: RandomAccessCollection>(
        index: Int?, starts: C, trackDurationMs: Int?
    ) -> LyricDisplayWindow? where C.Element == Int, C.Index == Int {
        guard let index, starts.indices.contains(index) else { return nil }
        let start = starts[index]
        let end = starts.indices.contains(index + 1) ? starts[index + 1] : trackDurationMs
        let dwell = end.map { $0 - start }.flatMap { $0 > minDwellMs ? $0 : nil }
        return LyricDisplayWindow(startMs: start, dwellMs: dwell)
    }
}
