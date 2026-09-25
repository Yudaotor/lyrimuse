import Foundation

/// media-control 的 `--micros`:把 `duration` / `elapsedTime` / `elapsedTimeNow` / `timestamp` **替换**成
/// `durationMicros` / `elapsedTimeMicros` / `elapsedTimeNowMicros` / `timestampEpochMicros`(epoch 微秒)。
/// 不带它时 `timestamp` 是恒无小数秒的 ISO8601,锚点时刻只能靠
/// `MediaControlClient.estimatedAnchorInstant` 去估(见 docs/features/02「整秒时间戳的相位订正」)。
///
/// 下游全部按原键名读,所以解析入口统一换算回来。微秒时间戳写成 `@<epoch 微秒>` 字符串,由
/// `MediaControlClient.parseTimestamp` 解析;它同时是锚点身份(`anchorKey`)的一段,轮询与 stream
/// 两条路必须都经过这里构造,别各写一份格式。
public enum MediaControlMicros {
    public static let timestampPrefix = "@"

    /// 替换关系(微秒键, 原键)。
    static let replacedKeys: [(micros: String, plain: String)] = [
        ("durationMicros", "duration"),
        ("elapsedTimeMicros", "elapsedTime"),
        ("elapsedTimeNowMicros", "elapsedTimeNow"),
        ("timestampEpochMicros", "timestamp"),
    ]

    /// 四个时间键的解码:两种键名都认,统一成秒 / 原格式时间戳字符串。JSONDecoder 路径
    /// (轮询快照的 RawPayload)用它;stream 那条 JSONSerialization 路径用 `normalized`。
    public struct TimeFields: Decodable, Equatable {
        public let duration: Double?
        public let elapsedTime: Double?
        public let elapsedTimeNow: Double?
        public let timestamp: String?

        private enum CodingKeys: String, CodingKey {
            case duration, elapsedTime, elapsedTimeNow, timestamp
            case durationMicros, elapsedTimeMicros, elapsedTimeNowMicros, timestampEpochMicros
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            duration = try c.decodeIfPresent(Double.self, forKey: .duration)
                ?? MediaControlMicros.seconds(try c.decodeIfPresent(Double.self, forKey: .durationMicros))
            elapsedTime = try c.decodeIfPresent(Double.self, forKey: .elapsedTime)
                ?? MediaControlMicros.seconds(try c.decodeIfPresent(Double.self, forKey: .elapsedTimeMicros))
            elapsedTimeNow = try c.decodeIfPresent(Double.self, forKey: .elapsedTimeNow)
                ?? MediaControlMicros.seconds(try c.decodeIfPresent(Double.self, forKey: .elapsedTimeNowMicros))
            timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
                ?? MediaControlMicros.timestampString(try c.decodeIfPresent(Double.self, forKey: .timestampEpochMicros))
        }
    }

    public static func seconds(_ micros: Double?) -> Double? {
        micros.map { $0 / 1_000_000 }
    }

    public static func timestampString(_ epochMicros: Double?) -> String? {
        guard let epochMicros, epochMicros > 0 else { return nil }
        return timestampPrefix + String(Int64(epochMicros))
    }

    public static func date(fromTimestampString s: String) -> Date? {
        guard s.hasPrefix(timestampPrefix),
              let micros = Int64(s.dropFirst(timestampPrefix.count)), micros > 0
        else { return nil }
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000)
    }

    /// stream 载荷(JSONSerialization 解出的字典)的同一套换算。diff 行里值为 `NSNull` 表示
    /// "这个键被清掉了",原样换到原键上,由调用方按既有规则删除。原键已经存在时不覆盖。
    public static func normalized(_ payload: [String: Any]) -> [String: Any] {
        var out = payload
        for (microsKey, plainKey) in replacedKeys {
            guard let value = out.removeValue(forKey: microsKey), payload[plainKey] == nil else { continue }
            if value is NSNull {
                out[plainKey] = NSNull()
                continue
            }
            guard let micros = (value as? NSNumber)?.doubleValue else { continue }
            if plainKey == "timestamp" {
                if let s = timestampString(micros) { out[plainKey] = s }
            } else {
                out[plainKey] = micros / 1_000_000
            }
        }
        return out
    }

    /// 锚点时刻是不是精确值。整秒时间戳(不带 `--micros` 的旧格式)的小数部分恒为 0,只有它
    /// 需要 `estimatedAnchorInstant` 去估被抹掉的那段;精确值再估一次反而会凭空加上 0~1 秒。
    /// 微秒值恰好落在整秒上的概率是百万分之一,那时退回估算,误差上限跟旧格式相同。
    public static func isPrecise(_ timestamp: Date) -> Bool {
        let t = timestamp.timeIntervalSince1970
        return t != t.rounded(.down)
    }
}
