import Foundation
import OSLog

/// 「所有对外请求」审计日志的统一出口——2026-08-26 用户明确要求"所有软件发出的对外
/// 请求全部都给我记录下日志"。App 侧真正发起网络请求的地方只有 6 处、分布在 5 个
/// 文件(`LastfmStatsService.request`/`LastfmAuthFlow` 的两处/`ListenBrainzTokenCheck.
/// validate`/`CachedImage.load`/`MusicCatalogSearch` 的两处),规模远小于 collector
/// (Go 侧),不需要一个像 `doHTTPTracked` 那样的运行期包装层——每个调用点各自在发起
/// 请求前后调一次 `record(...)` 就够了。
///
/// 安全设计跟 collector 侧 `networkobs.go` 的 `doHTTPTracked` 同一个原则:**日志行
/// 从源头就不含敏感参数**,不是"记完整 URL 再指望脱敏兜底"。调用方只传 `host`(不含
/// query string/path 的域名部分)和一个语义化的 `operation` 标签(调用方自己早就知道
/// 这次是要做什么——比如 Last.fm 的 `method` 参数名、或者"validate-token"这种自造的
/// 标签),从不接收也不记录完整 URL、请求头、请求体或响应体。`LogRedactor.swift`(同
/// 目录)是给已经存在的、可能带着敏感信息的旧日志正文在导出那一刻做的第二道兜底,这里
/// 的新日志行设计上不需要依赖它就是安全的。
///
/// 用一个独立的 os.Logger category("network-audit"),跟 `LastfmStatsService`(分类
/// "lastfm-stats")、`LastfmConnectController`(分类 "lastfm-connect")等现有分类分开,
/// 方便单独筛选;`DiagnosticsExporter.recentAppLogLines()` 按 subsystem(不按
/// category)查询,这个新分类的日志会自动出现在导出的诊断报告里,不需要额外接线。
public enum NetworkAuditLog {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "network-audit")

    /// 记一次对外请求的结果。
    ///
    /// - Parameters:
    ///   - service: 大类,比如 "lastfm"/"listenbrainz"/"itunes"/"image"——给日志分组用。
    ///   - operation: 具体在做什么,调用方自己起的语义化标签(比如 Last.fm 的 API
    ///     方法名 "track.getinfo",或者 "validate-token")。**绝不能是完整 URL**。
    ///   - host: 请求打到的域名(比如 "ws.audioscrobbler.com"),不含 path/query。
    ///   - statusCode: 成功拿到响应时的 HTTP 状态码;传输层失败(连不上/超时)时为 nil。
    ///   - durationMs: 从发起请求到拿到结果(或失败)经过的毫秒数。
    ///   - error: 失败时的错误;只用它的 `localizedDescription`(系统/URLSession 的
    ///     传输层错误文案,比如"连接超时",不会带出请求 URL 或凭据)。
    public static func record(service: String, operation: String, host: String,
                               statusCode: Int?, durationMs: Double, error: Error?) {
        if let error {
            logger.notice("\(service, privacy: .public) \(operation, privacy: .public) host=\(host, privacy: .public) FAILED after \(durationMs, privacy: .public)ms: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.notice("\(service, privacy: .public) \(operation, privacy: .public) host=\(host, privacy: .public) -> \(statusCode ?? -1, privacy: .public) (\(durationMs, privacy: .public)ms)")
        }
    }
}
