import Foundation

/// 酷我在放时报给系统的进度比它实际出声早一截(`leadSecs`):开播、恢复、跳转之后都一样,播放中每 0.5 秒重发的锚点也带着这一截;
/// 暂停那一帧报的是停声的位置,不动。在放的锚点按这一截把时刻往后挪。它暂停时速率仍报 1,在不在放只认 `playing`。
/// 见 02 章决策 263。
public enum KuwoSessionAnchor {
    /// 在放的锚点比出声早多少秒。
    public static let leadSecs: Double = 0.14

    /// 这一帧锚点要往后挪多少秒:酷我在放的为 `leadSecs`,其余为 0。纯函数,selftest 覆盖。
    public static func lead(bundleID: String?, playing: Bool?) -> Double {
        bundleID == PlaybackPlayer.kuwo.bundleIdentifier && playing == true ? leadSecs : 0
    }

    /// 锚点时刻往后挪 `lead` 秒;不挪或时刻读不出时原样交回。纯函数,selftest 覆盖。
    public static func shifted(_ timestamp: String?, by lead: Double) -> String? {
        guard lead != 0, let timestamp, let at = MyGoSessionAnchor.seconds(timestamp) else { return timestamp }
        return MediaControlMicros.timestampString((at + lead) * 1_000_000) ?? timestamp
    }

    /// 按 bundle id 单问到的那份(焦点被别的 App 占着时)推到 `now` 的位置,同主路一样扣掉这一截;不是酷我在放、缺锚点为 nil。
    /// 纯函数,selftest 覆盖。
    public static func probedPosition(bundleID: String?, playing: Bool?, elapsed: Double?, anchorAt: Double?, rate: Double?,
                                      duration: Double?, now: Date) -> Double? {
        let lead = lead(bundleID: bundleID, playing: playing)
        guard lead > 0, let elapsed, let anchorAt else { return nil }
        let position = max(0, elapsed + (now.timeIntervalSince1970 - anchorAt - lead) * (rate ?? 1))
        guard let duration, duration > 0 else { return position }
        return min(position, duration)
    }
}
