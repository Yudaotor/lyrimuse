import Foundation

// LogFiles(两侧日志文件的落点)2026-09-05 挪到 Util/LyrimuseIdentity.swift,跟配置目录、launchd label 一起按变体派生。

/// collector 日志行的时间戳解析(2026-09-05)。
///
/// collector 侧 2026-09-05 从 stdlib `log` 换成 `log/slog` 之后,每行以 `time=2026-09-05T00:00:00.000Z `
/// 开头(UTC、RFC 3339 毫秒、显式 Z);之前的行是 Go `log.LstdFlags | log.LUTC` 的 `2026/09/04 15:49:15 `
/// (UTC 但不带任何标记 —— 极易被当成本地时间读错,换格式的动机之一)。归档的 `.old` 文件和迁移前
/// 写下的行仍是老格式,所以两种都认。诊断导出按时间窗口取 collector 日志
/// (`DiagnosticsExporter.recentCollectorLogLines`)靠它找窗口起点;放进 Core 是为了让 selftest 能钉住
/// 两种格式各按 UTC 解析。
///
/// 解析不出返回 nil:外部进程漏进这份文件的 stderr(比如 launchctl 的报错)、Go 运行时 panic 的
/// 堆栈行都没有时间戳,调用方跳过它们即可。
public enum CollectorLogLine {
    private static let slogFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let legacyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func timestamp(of line: String) -> Date? {
        if line.hasPrefix("time=") {
            let token = line.dropFirst("time=".count).prefix { $0 != " " }
            return slogFormatter.date(from: String(token))
        }
        // 老格式前 19 个字符正好是时间戳。用 utf8 长度判短行,避免 `count` 在长行上走一遍。
        guard line.utf8.count >= 19 else { return nil }
        return legacyFormatter.date(from: String(line.prefix(19)))
    }
}
