import Foundation
import os

/// App → collector 的「位置偏置」文件(2026-09-09,用户拍板「collector 复用 App 量出的偏置」)。
///
/// `LocalPlaybackSource` 给 Spotify 量出的锚点偏置(`posReportedBiasSecs`,见那边 resolvePositionSeconds
/// 的地面真值分支)只修了本机这几扇窗口;collector 推给状态中继(网页 / 飞书预览)的 progress 走的是
/// 同一条 media-control 外推,该慢多少还慢多少。两边各问一次 Spotify 是重复劳动,所以偏置一变
/// 就整份原子重写这个小 JSON,collector 每轮读一次、身份 / 锚点 / 时序全对得上就扣掉
/// (Go 侧 `positionbias.go`,字段名两边逐字节一致 —— selftest 与 Go 测试各有一份对称断言)。
///
/// 它是**状态**不是信号:collector 不删它;App 换歌 / 偏置清零时写 `bias_secs: 0`,而不是删文件,
/// 让"没有偏置"也是一份明确的最新记录。
public struct PositionBiasRecord: Codable, Equatable, Sendable {
    public var artist: String
    public var title: String
    public var bundleID: String
    /// 偏置对着的锚点(快照原始 anchorElapsedTime)。collector 用它判"Spotify 有没有换过锚点"。
    public var anchorElapsed: Double?
    /// 与 `LocalPlaybackSource.posReportedBiasSecs` 同符号:reported = raw − bias;负=锚点落后真声。
    public var biasSecs: Double
    public var writtenAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case artist, title
        case bundleID = "bundle_id"
        case anchorElapsed = "anchor_elapsed"
        case biasSecs = "bias_secs"
        case writtenAtMs = "written_at_ms"
    }

    public init(artist: String, title: String, bundleID: String, anchorElapsed: Double?, biasSecs: Double, writtenAtMs: Int64) {
        self.artist = artist
        self.title = title
        self.bundleID = bundleID
        self.anchorElapsed = anchorElapsed
        self.biasSecs = biasSecs
        self.writtenAtMs = writtenAtMs
    }

    /// 除写入时刻外全同 —— 决定"要不要再写一次"。
    public func sameContent(as other: PositionBiasRecord) -> Bool {
        artist == other.artist && title == other.title && bundleID == other.bundleID
            && anchorElapsed == other.anchorElapsed && biasSecs == other.biasSecs
    }
}

public enum PositionBiasFile {
    /// 跟 Go 侧 main.go 里 `clientName+"-position-bias.json"` 逐字节一致。
    public static let fileName = "lyrimuse-position-bias.json"
    public static var url: URL { LyrimusePaths.configFile(fileName) }
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "position-bias")

    /// 纯函数,selftest 直接覆盖:键按字母序、不带缩进,输出稳定可比。
    public static func encode(_ record: PositionBiasRecord) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(record)
    }

    /// 原子写(临时文件 + rename),collector 那边永远读到的是整份。失败只记日志 —— 这条链路是
    /// 网页那边的锦上添花,不能反过来影响本机窗口的位置。
    public static func write(_ record: PositionBiasRecord) {
        do {
            try encode(record).write(to: url, options: .atomic)
        } catch {
            logger.notice("position bias file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
