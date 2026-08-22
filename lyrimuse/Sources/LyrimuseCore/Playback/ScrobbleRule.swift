import Foundation

/// 「这次播放什么时候算一次收听」的判定规则 —— **复刻 collector 的 listenThreshold /
/// minTrackSecs**(collector/main.go + poller.go),给 UI 画计次刻度用(歌词窗口进度条,
/// 2026-08-22)。两边必须保持一致:collector 是真正做记录的一方,这里只是把同一条规则
/// 画出来;规则演进时两处一起改。
///
/// ⚠️ UI 侧按「播放位置过线」近似判定,而 collector 数的是**实际播放秒数**(playedSecs)——
/// 用户往后拖进度条时两者会短暂不一致(位置过线了、实际没听够),这是展示层刻意接受的
/// 近似:刻度的意义是"过了这里这次播放就会被记录",不是记录本身的真值来源。
public enum ScrobbleRule {
    /// 计次上限秒数:长歌播满 4 分钟就算,不用等一半。
    public static let capSecs: Double = 240
    /// 短于这个的曲目不记收听(Last.fm/ListenBrainz 共同的最短曲长规则)。
    public static let minTrackSecs: Double = 30

    /// 计次点在整首歌里的比例位置(0~1)。nil = 画不出刻度:太短的曲目 collector 真的
    /// 不计(<30s);时长未知(0)时 collector **仍会**在播满 240s 时计,只是比例无从换算,
    /// UI 侧不画 —— 这一档是"画不出",不是"不计"(2026-08-22 审阅纠偏)。
    public static func thresholdFraction(durationMs: Int) -> Double? {
        let duration = Double(durationMs) / 1000
        guard duration >= minTrackSecs else { return nil }
        return min(duration / 2, capSecs) / duration
    }
}
