import Foundation

/// 一份 macOS 崩溃报告(`~/Library/Logs/DiagnosticReports/*.ips`)的摘要,诊断导出的「Recent Crash Reports」段用
/// (2026-09-06,借鉴清单 #31)。
///
/// .ips 是两段 JSON 拼在一个文件里:第一行是摘要(app_name / app_version / bug_type / timestamp / bundleID …),
/// 换行之后是完整正文(procName / procPath / bundleInfo / exception / termination / faultingThread / threads /
/// usedImages …)。这里只挑排查用得上的字段,**termination 排在帧前面**:本机 7 份真实报告里 6 份是启动期 DYLD
/// 「Library missing」、1 份是 Launch Constraint Violation,故障线程一帧都没有,能说明问题的只有 termination 的
/// indicator / reasons / details。帧只在有的时候附,最多 `maxFrames` 帧。
///
/// 解析必须宽容:.ips 的结构随 macOS 版本变;两段任一坏了就只用另一段(parseNotes 记下哪段没解出来),两段都坏
/// 返回 nil(调用方退成一行说明)。纯逻辑、不碰文件系统——目录扫描与读文件在 App 侧 DiagnosticsExporter,这里的
/// 三种样本(DYLD 缺库 / 签名约束 / 带帧的 EXC_BAD_ACCESS)由 selftest ops-diagnostics 组钉着。
public struct CrashReportSummary: Equatable {
    public struct Frame: Equatable {
        public var imageName: String?
        public var symbol: String?
        public var imageOffset: Int?
        public var sourceFile: String?
        public var sourceLine: Int?

        public init(imageName: String? = nil, symbol: String? = nil, imageOffset: Int? = nil,
                    sourceFile: String? = nil, sourceLine: Int? = nil) {
            self.imageName = imageName
            self.symbol = symbol
            self.imageOffset = imageOffset
            self.sourceFile = sourceFile
            self.sourceLine = sourceLine
        }
    }

    /// 故障线程最多附多少帧。启动期崩溃通常零帧;真正的崩溃前十几帧足够定位到哪个模块。
    public static let maxFrames = 15

    public var fileName: String
    public var processName: String?
    public var processPath: String?
    public var bundleIdentifier: String?
    public var version: String?
    public var buildVersion: String?
    public var bugType: String?
    public var timestamp: String?
    public var osVersion: String?
    public var exceptionType: String?
    public var exceptionSignal: String?
    public var terminationNamespace: String?
    public var terminationIndicator: String?
    public var terminationReasons: [String] = []
    public var terminationDetails: [String] = []
    public var faultingThreadIndex: Int?
    public var frames: [Frame] = []
    public var totalFrames = 0
    /// 哪一段没解出来("header unreadable" / "body unreadable"),写进报告让读的人知道信息不全。
    public var parseNotes: [String] = []

    public init(fileName: String) {
        self.fileName = fileName
    }

    // MARK: - 解析

    public static func parse(fileName: String, data: Data) -> CrashReportSummary? {
        guard !data.isEmpty else { return nil }
        // 第一行 = 摘要;之后 = 正文。
        var header: [String: Any]?
        var body: [String: Any]?
        if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            header = parseObject(Data(data[data.startIndex..<newline]))
            body = parseObject(Data(data[data.index(after: newline)...]))
            if header == nil && body == nil {
                // 也许整份就是一个(多行的)JSON 对象,没有摘要行——结构变了也不至于全丢。
                body = parseObject(data)
            }
        } else if let single = parseObject(data) {
            // 只有一行:看它长得像正文(有 procName / threads / termination)还是像摘要。
            if looksLikeBody(single) { body = single } else { header = single }
        }
        guard header != nil || body != nil else { return nil }

        var summary = CrashReportSummary(fileName: fileName)
        if header == nil { summary.parseNotes.append("header unreadable") }
        if body == nil { summary.parseNotes.append("body unreadable") }

        if let header {
            summary.processName = header["app_name"] as? String
            summary.version = header["app_version"] as? String
            summary.buildVersion = header["build_version"] as? String
            summary.bugType = stringish(header["bug_type"])
            summary.timestamp = header["timestamp"] as? String
            summary.osVersion = header["os_version"] as? String
            summary.bundleIdentifier = header["bundleID"] as? String
        }
        if let body {
            summary.processName = (body["procName"] as? String) ?? summary.processName
            summary.processPath = body["procPath"] as? String
            if let info = body["bundleInfo"] as? [String: Any] {
                summary.bundleIdentifier = (info["CFBundleIdentifier"] as? String) ?? summary.bundleIdentifier
                summary.version = (info["CFBundleShortVersionString"] as? String) ?? summary.version
                summary.buildVersion = (info["CFBundleVersion"] as? String) ?? summary.buildVersion
            }
            if summary.bugType == nil { summary.bugType = stringish(body["bug_type"]) }
            if summary.timestamp == nil { summary.timestamp = body["captureTime"] as? String }
            if summary.osVersion == nil, let os = body["osVersion"] as? [String: Any] {
                let parts = [os["train"] as? String, (os["build"] as? String).map { "(\($0))" }].compactMap { $0 }
                if !parts.isEmpty { summary.osVersion = parts.joined(separator: " ") }
            }
            if let exception = body["exception"] as? [String: Any] {
                summary.exceptionType = exception["type"] as? String
                summary.exceptionSignal = exception["signal"] as? String
            }
            if let termination = body["termination"] as? [String: Any] {
                summary.terminationNamespace = termination["namespace"] as? String
                summary.terminationIndicator = termination["indicator"] as? String
                summary.terminationReasons = stringList(termination["reasons"])
                summary.terminationDetails = stringList(termination["details"])
            }
            let faulting = intish(body["faultingThread"])
            summary.faultingThreadIndex = faulting
            let images = (body["usedImages"] as? [[String: Any]]) ?? []
            if let threads = body["threads"] as? [[String: Any]], let index = faulting,
               index >= 0, index < threads.count,
               let rawFrames = threads[index]["frames"] as? [[String: Any]] {
                summary.totalFrames = rawFrames.count
                summary.frames = rawFrames.prefix(maxFrames).map { raw in
                    var frame = Frame()
                    if let imageIndex = intish(raw["imageIndex"]), imageIndex >= 0, imageIndex < images.count {
                        frame.imageName = images[imageIndex]["name"] as? String
                    }
                    frame.symbol = raw["symbol"] as? String
                    frame.imageOffset = intish(raw["imageOffset"])
                    frame.sourceFile = raw["sourceFile"] as? String
                    frame.sourceLine = intish(raw["sourceLine"])
                    return frame
                }
            }
        }
        return summary
    }

    private static func looksLikeBody(_ object: [String: Any]) -> Bool {
        object["procName"] != nil || object["threads"] != nil || object["termination"] != nil
    }

    private static func parseObject(_ data: Data) -> [String: Any]? {
        guard data.contains(where: { $0 > 0x20 }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func stringish(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func intish(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap { stringish($0) } }
        if let single = stringish(value) { return [single] }
        return []
    }

    // MARK: - 归属与挑选

    /// 是不是本 App 家族(App 本体或它包里的 collector)的报告。
    ///
    /// 文件名前缀只能粗筛(别的 App 也可能有叫 collector 的进程),这里按正文再确认:进程名是 App 可执行名或
    /// "collector";正文带 bundle id 的(App 本体)必须等于本变体;正文带 procPath 的,路径必须落在
    /// 「<显示名>.app/Contents/」里 —— 正式版与 Dev 的显示名不同,互不混入(macOS 会把家目录里的路径改写成
    /// `/Users/USER/*/…`,包名那一段仍然在)。
    public func belongsToApp(executableName: String, bundleIdentifier: String, appDisplayName: String) -> Bool {
        guard let name = processName?.lowercased(),
              name == executableName.lowercased() || name == "collector" else { return false }
        if let id = self.bundleIdentifier, id != bundleIdentifier { return false }
        if let path = processPath, !path.contains("/\(appDisplayName).app/Contents/") { return false }
        return true
    }

    /// 每个进程各取最近 N 份:collector 走 KeepAlive 崩溃循环时会刷出一串报告,总共取 N 会把 App 那一份挤掉。
    /// 同一进程内按时间戳倒序(同格式字符串,字典序即时间序;没有时间戳退到文件名,它也带时间);进程按名字排,
    /// 结果稳定。
    public static func select(_ reports: [CrashReportSummary], perProcessLimit: Int) -> [CrashReportSummary] {
        var byProcess: [String: [CrashReportSummary]] = [:]
        for report in reports {
            byProcess[report.processName?.lowercased() ?? "?", default: []].append(report)
        }
        var out: [CrashReportSummary] = []
        for key in byProcess.keys.sorted() {
            let sorted = byProcess[key]!.sorted { ($0.timestamp ?? $0.fileName) > ($1.timestamp ?? $1.fileName) }
            out.append(contentsOf: sorted.prefix(max(0, perProcessLimit)))
        }
        return out
    }

    // MARK: - 渲染

    /// 报告里的文本行。第一行是文件名,后面缩进两格;帧再缩进两格。
    public func renderLines() -> [String] {
        var out: [String] = []
        out.append("- \(fileName)")
        var head: [String] = []
        if let timestamp { head.append("time: \(timestamp)") }
        var process = processName ?? "?"
        if let version {
            process += " \(version)"
            if let buildVersion, buildVersion != version { process += " (\(buildVersion))" }
        }
        head.append("process: \(process)")
        if let bugType { head.append("bug_type: \(bugType)") }
        if let osVersion { head.append("os: \(osVersion)") }
        out.append("  " + head.joined(separator: " · "))
        if let processPath { out.append("  path: \(processPath)") }
        if let bundleIdentifier { out.append("  bundle: \(bundleIdentifier)") }
        if exceptionType != nil || exceptionSignal != nil {
            out.append("  exception: " + [exceptionType, exceptionSignal].compactMap { $0 }.joined(separator: " · "))
        }
        if terminationNamespace != nil || terminationIndicator != nil {
            out.append("  termination: " + [terminationNamespace, terminationIndicator].compactMap { $0 }.joined(separator: " · "))
        }
        for reason in terminationReasons { out.append("  reason: \(reason)") }
        for detail in terminationDetails { out.append("  detail: \(detail)") }
        if let index = faultingThreadIndex {
            if frames.isEmpty {
                out.append("  faulting thread \(index): no frames recorded")
            } else {
                out.append("  faulting thread \(index): showing \(frames.count) of \(totalFrames) frames")
                for (position, frame) in frames.enumerated() {
                    var line = String(format: "    %2d  ", position) + (frame.imageName ?? "?")
                    if let symbol = frame.symbol { line += "  \(symbol)" }
                    if let offset = frame.imageOffset { line += " + \(offset)" }
                    if let file = frame.sourceFile {
                        line += "  (\(file)" + (frame.sourceLine.map { ":\($0)" } ?? "") + ")"
                    }
                    out.append(line)
                }
            }
        }
        if !parseNotes.isEmpty { out.append("  note: " + parseNotes.joined(separator: "; ")) }
        return out
    }
}
