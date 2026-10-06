import Foundation
import os

/// 切歌补偿补过的那份锚点:App 重启后同一个锚点接着补(见 `MediaControlClient.restoredStartCorrection`、
/// 02 章决策 104)。只留最近一份,整份原子重写。
public struct AnchorStartCorrectionRecord: Codable, Equatable, Sendable {
    public var bundleID: String
    /// `MediaControlClient.anchorKey`:歌手|歌名|原始位置|原始时间戳,逐字比对。
    public var anchorKey: String
    /// 补进位置的秒数(正 = 锚点比真声晚,读数要加)。
    public var correctionSecs: Double
    public var writtenAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case anchorKey = "anchor_key"
        case correctionSecs = "correction_secs"
        case writtenAtMs = "written_at_ms"
    }

    public init(bundleID: String, anchorKey: String, correctionSecs: Double, writtenAtMs: Int64) {
        self.bundleID = bundleID
        self.anchorKey = anchorKey
        self.correctionSecs = correctionSecs
        self.writtenAtMs = writtenAtMs
    }
}

public enum AnchorStartCorrectionFile {
    public static let fileName = "lyrimuse-anchor-start-correction.json"
    public static var url: URL { LyrimusePaths.configFile(fileName) }
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "position-bias")

    /// 纯函数,selftest 直接覆盖:键按字母序、不带缩进。
    public static func encode(_ record: AnchorStartCorrectionRecord) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(record)
    }

    /// 解析失败当没有。纯函数,selftest 直接覆盖。
    public static func decode(_ data: Data) -> AnchorStartCorrectionRecord? {
        try? JSONDecoder().decode(AnchorStartCorrectionRecord.self, from: data)
    }

    /// 不存在 / 解析失败都当没有。
    public static func read() -> AnchorStartCorrectionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// 原子写(临时文件 + rename)。失败只记日志:接不回只是重启后那一首偏一点。
    public static func write(_ record: AnchorStartCorrectionRecord) {
        do {
            try encode(record).write(to: url, options: .atomic)
        } catch {
            logger.notice("anchor start correction write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
