import Foundation
import LyrimuseCore
import OSLog
import AppKit

// 一键导出诊断信息:collector 日志走 ~/Library/Logs/lyrimuse.log,App 自己
// 的日志全部走 os.Logger(系统统一日志),普通用户不会用 Console.app 去查。这个文件把
// 两边日志 + 关键状态(权限/常驻服务/各功能是否已配置)汇总成一份文本文件,方便不懂
// 技术的用户自己导出发过来排查问题。
//
// 安全上的硬约束:绝不能把 ConfigStore 里任何 token/secret 的原始值写进这份文件——这份
// 文件很可能被贴进公开的 GitHub issue。这条约束由**两道**独立的机制守着,缺一不可:
//
//  1. 结构化那一段(== State ==)只复用 ConfigStore 已有的 isXConfigured/xMissingHint()
//     这批只读布尔判断,不直接触碰 savedSnapshot 里的字段本身。
//  2. 附在报告末尾的两段**日志正文**统一过 redacted() → LogRedactor 脱敏。
//
// 第 2 条是 2026-08-13 补的,补之前这条约束实际上是**破的**:第 1 条只管结构化字段,而
// 报告末尾把 ~/Library/Logs/lyrimuse.log 的最后 200 行原样附上,凭据从日志正文里漏出去。
// 实测当时本机那 200 行内就有 3 处 Last.fm API Key 原文 —— 来源是 collector 打印 Go
// *url.Error 的原文,而它的 Error() 会带出完整 URL,api_key 就在 query string 里。
// 详见 LogRedactor 的注释。往这份报告里加任何新的日志段落,都必须一并套上 redacted()。
enum DiagnosticsExporter {
    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Lyrimuse-Diagnostics-\(formatter.string(from: Date())).txt"
    }

    // 只生成内容,不碰任何文件系统写入——存哪、怎么存交给调用方(SettingsView 用
    // NSSavePanel)。写入路径由用户自己在系统存储面板里确认,天然不会撞上桌面/文稿/
    // 下载三个目录可能存在的 TCC 保护,也跟这个项目里选歌词文件夹用 NSOpenPanel 是
    // 同一个思路。
    @MainActor
    static func buildReport() -> String {
        var lines: [String] = []

        lines.append("Lyrimuse Diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("== System ==")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
        lines.append("")

        lines.append("== State ==")
        let settings = AppSettings.shared
        let config = ConfigStore.shared
        lines.append("Automation permission: \(MusicAutomationPermission.check(askIfNeeded: false))")
        // 「当前认哪个播放器」是排查"检测不到播放/歌词出不来"时第一个要问的问题,而它有两层:
        // 用户在设置里选的(可能是"自动识别"),和这一刻实际被认下来的那个 bundle id。两层
        // 都要报——只报设置值的话,"自动识别"这一档等于什么都没说。
        lines.append("Player (setting): \(PlaybackPlayerPreference.current.rawValue)")
        // 标签写 "last detected" 而不是 "now":这个值来自最近一次成功的快照,而快照在停播/
        // 检测失效时不会被清掉,所以停播之后它仍然报最后一次识别到的播放器。读报告的人得
        // 知道这一点,否则会把陈旧值当成当下状态。
        lines.append("Player (last detected): \(PlaybackCoordinator.shared.resolvedPlayerDescription)")
        lines.append("Collector service enabled (setting): \(settings.collectorServiceEnabled)")
        lines.append("Collector service actually running: \(CollectorServiceManager.isRunning)")
        lines.append("App language: \(settings.appLanguage)")
        lines.append("Classic overlay enabled: \(settings.classicOverlayEnabled)")
        lines.append("Notch overlay enabled: \(settings.notchOverlayEnabled)")
        lines.append("ListenBrainz configured: \(config.isListenBrainzConfigured)")
        // 2026-07-29 起没有独立开关了,两边凭据都配好就自动生效,这里直接报告"是否真的
        // 在跑"而不是"Last.fm 侧凭据填了没"(后者单独看意义不大,还得对照上一行才知道
        // 有没有真的启用)。
        lines.append("Last.fm bridge active: \(config.lastfmBridgeMissingHint() == nil && config.isListenBrainzConfigured)")
        // lastfmMirrorMissingHint 2026-08-11 已删(开关自己就是配置入口,不再需要前置
        // 校验函数),它检查的三个字段里 sessionKey 是最后一步产物,单看它就等价。
        lines.append("Last.fm mirror configured: \(!config.lastfmScrobbleSessionKey.isEmpty)")
        lines.append("State relay configured: \(config.stateRelayMissingHint() == nil)")
        lines.append("Push notification configured: \(config.pushMissingHint() == nil)")
        lines.append("")

        lines.append("== App Log (last 24h, subsystem me.yudaotor.lyrimuse) ==")
        lines.append(contentsOf: redacted(recentAppLogLines()))
        lines.append("")

        lines.append("== Collector Log (last 200 lines) ==")
        lines.append(contentsOf: redacted(recentCollectorLogLines()))

        return lines.joined(separator: "\n")
    }

    // 只查这个 App 自己的 subsystem("me.yudaotor.lyrimuse",全部 Logger 调用点共用同一个
    // 值),不是整个系统日志——不需要额外权限,读的也只是自己写过的东西。scope 用
    // .system 而不是 .currentProcessIdentifier:后者只能看到"这次启动之后"的记录,诊断
    // "上次为什么崩了/上次启动出的问题"这种场景必须能看到上一次进程生命周期里的记录。
    /// 两段日志正文的**唯一**出口都要过这里,见 LogRedactor 的注释。
    ///
    /// 放在这一层而不是各自的取日志函数里,是为了让"报告里出现的每一行日志都脱过敏"这件事
    /// 只有一个地方可查、也只有一个地方会漏 —— 以后再加第三段日志(比如 Sparkle 的更新
    /// 日志),忘了套这个函数会很显眼。
    @MainActor
    private static func redacted(_ lines: [String]) -> [String] {
        let secrets = ConfigStore.shared.secretsForRedaction
        return lines.map { LogRedactor.redactAll($0, secrets: secrets) }
    }

    private static func recentAppLogLines(hours: Int = 24) -> [String] {
        guard let store = try? OSLogStore(scope: .system) else {
            return ["(could not open log store)"]
        }
        let position = store.position(date: Date().addingTimeInterval(-Double(hours) * 3600))
        let predicate = NSPredicate(format: "subsystem == %@", "me.yudaotor.lyrimuse")
        guard let entries = try? store.getEntries(at: position, matching: predicate) else {
            return ["(could not read log entries)"]
        }
        var lines: [String] = []
        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog else { continue }
            lines.append("\(logEntry.date) [\(logEntry.category)] \(logEntry.composedMessage)")
        }
        return lines.isEmpty ? ["(no entries in the last \(hours)h)"] : lines
    }

    private static func recentCollectorLogLines(limit: Int = 200) -> [String] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/lyrimuse.log")
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return ["(could not read \(path.path))"]
        }
        let allLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Array(allLines.suffix(limit))
    }
}
