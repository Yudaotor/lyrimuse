import Foundation

/// 「歌词管理」详情页时间轴偏移输入框里敲的秒数。
public enum LyricsOffsetInput {
    /// 收的范围:±10 分钟。
    public static let limitMs = 600_000

    /// 换成毫秒:去掉首尾空白后按小数解析;解析不了、不是有限数(`nan`、`inf`)或者超出 ±`limitMs` 时为 nil,调用方把
    /// 输入框改回当前值、不写入。别直接 `Int(秒 * 1000)`:不是有限数或者大到装不进 Int 时进程会崩(见 11 章决策 92)。
    public static func milliseconds(from text: String) -> Int? {
        guard let seconds = Double(text.trimmingCharacters(in: .whitespaces)), seconds.isFinite else { return nil }
        let ms = (seconds * 1000).rounded()
        guard abs(ms) <= Double(limitMs) else { return nil }
        return Int(ms)
    }
}
