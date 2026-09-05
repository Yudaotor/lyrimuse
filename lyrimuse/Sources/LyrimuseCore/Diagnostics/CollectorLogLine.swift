import Foundation

/// 两侧日志文件的落点。唯一口径:LoginItemManager 写 plist、DiagnosticsExporter 读文件、
/// uninstall.sh 的清理列表(那边是 shell,手工同步)都按这里。
public enum LogFiles {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// collector 常驻进程的日志(launchd 的 StandardErrorPath,也是 collector 自己打开并按大小轮转的那份)。
    public static var collector: URL { home.appendingPathComponent("Library/Logs/lyrimuse.log") }

    /// App 进程由 launchd 拉起时的 stdout / stderr(2026-09-05 起单独一份;此前跟 collector 共用
    /// `lyrimuse.log`,两个进程两种格式两种时区混在一个文件里,launchctl 子进程漏出来的报错也
    /// 分不清是谁的)。正常情况下几乎是空的 —— App 的日志走 os.Logger;能落进来的只有 Swift
    /// 运行时的 fatal 信息、被子进程漏出的 stderr 这类"本不该有"的东西,正因为如此它排查崩溃时最有用。
    public static var appStderr: URL { home.appendingPathComponent("Library/Logs/lyrimuse-app.log") }
}

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
