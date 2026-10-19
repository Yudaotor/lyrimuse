import Foundation

/// 副屏网页的诊断浮层:网页发 `{"stats":1}` / `{"stats":0}` 开关,开着时 App 每秒给它发一条这一尺寸的出帧、码率、提前量
/// `{"type":"stats",…}`,跟网页自己算的到帧、上屏、余量、解码拼在一起显示。推画面的那台的日志看副屏的人拿不到,浮层截一张图
/// 就能看出卡在哪一段。关着时不发。见 19 章决策 35。
public enum WebLyricsStats {
    public static func parseToggle(_ payload: Data) -> Bool? {
        guard payload.count <= 64,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let flag = object["stats"] as? NSNumber else { return nil }
        switch flag.doubleValue {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    /// 视频流才有码率、编码器码率、排队(毫秒);逐帧 JPEG 给 nil,网页不显示那几项。
    public static func message(renderFps: Int, bitRate: Int?, encoderBitRate: Int?, queueMs: Int?, leadMs: Int,
                               leadTargetMs: Int, dropped: Int) -> String {
        var object: [String: Any] = ["type": "stats", "fps": renderFps, "lead": leadMs, "target": leadTargetMs, "drop": dropped]
        if let bitRate { object["kbps"] = bitRate / 1000 }
        if let encoderBitRate { object["enc"] = encoderBitRate / 1000 }
        if let queueMs { object["queue"] = queueMs }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"type\":\"stats\"}" }
        return text
    }
}
