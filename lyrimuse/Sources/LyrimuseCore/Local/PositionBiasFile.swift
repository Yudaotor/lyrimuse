import Foundation
import os

/// App 自己的「位置偏置」记录:`LocalPlaybackSource` 给 Spotify 量出的偏置(`posReportedBiasSecs`)一变就整份
/// 原子重写这个小 JSON,App 重启后第一拍读回来接着用(见 `LocalPlaybackSource.restorablePlayerClockBias`)。
///
/// 它是**状态**不是信号:换歌 / 偏置清零时写 `bias_secs: 0`,而不是删文件,让"没有偏置"也是一份明确的最新记录。
public struct PositionBiasRecord: Codable, Equatable, Sendable {
    public var artist: String
    public var title: String
    public var bundleID: String
    /// 偏置对着的锚点(快照原始 anchorElapsedTime);nil = 播放器自己的钟,只有这一档会被接回。
    public var anchorElapsed: Double?
    /// 与 `LocalPlaybackSource.posReportedBiasSecs` 同符号:reported = raw − bias;负=锚点落后真声。
    public var biasSecs: Double
    public var writtenAtMs: Int64
    /// 写这份记录那一刻 App 算出的位置(秒)。App 重启后接回偏置时拿它核"从那以后一直连续在放"
    /// (见 `LocalPlaybackSource.restorablePlayerClockBias`)。旧文件没有这个键 = nil。
    public var positionSecs: Double?

    enum CodingKeys: String, CodingKey {
        case artist, title
        case bundleID = "bundle_id"
        case anchorElapsed = "anchor_elapsed"
        case biasSecs = "bias_secs"
        case writtenAtMs = "written_at_ms"
        case positionSecs = "position_secs"
    }

    public init(artist: String, title: String, bundleID: String, anchorElapsed: Double?, biasSecs: Double, writtenAtMs: Int64,
                positionSecs: Double? = nil) {
        self.artist = artist
        self.title = title
        self.bundleID = bundleID
        self.anchorElapsed = anchorElapsed
        self.biasSecs = biasSecs
        self.writtenAtMs = writtenAtMs
        self.positionSecs = positionSecs
    }

    /// 除写入时刻与那一刻的位置外全同 —— 决定"要不要再写一次"。
    public func sameContent(as other: PositionBiasRecord) -> Bool {
        artist == other.artist && title == other.title && bundleID == other.bundleID
            && anchorElapsed == other.anchorElapsed && biasSecs == other.biasSecs
    }
}

public enum PositionBiasFile {
    public static let fileName = "lyrimuse-position-bias.json"
    public static var url: URL { LyrimusePaths.configFile(fileName) }
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "position-bias")

    /// 纯函数,selftest 直接覆盖:键按字母序、不带缩进,输出稳定可比。
    public static func encode(_ record: PositionBiasRecord) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(record)
    }

    /// 读最近一份记录;不存在 / 解析失败都当没有。App 自己只在重启后第一拍读一次
    /// (接着用上一个进程量的偏置,见 `LocalPlaybackSource.restorablePlayerClockBias`)。
    public static func read() -> PositionBiasRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PositionBiasRecord.self, from: data)
    }

    /// 原子写(临时文件 + rename),读到的永远是整份。失败只记日志 —— 接不回偏置只是重启后那一首偏一点,
    /// 不能反过来影响本机窗口的位置。
    public static func write(_ record: PositionBiasRecord) {
        do {
            try encode(record).write(to: url, options: .atomic)
        } catch {
            logger.notice("position bias file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
