import Foundation

/// 一次主线程卡顿(`MainThreadWatchdog` 报「unresponsive」)的概况,跟着那一天的活动随心跳发出。
/// 只有分档、枚举值和调用栈帧(系统库符号、Lyrimuse 自己的偏移),不带歌名、路径和账号。见 14 章决策 183。
public struct TelemetryHang: Codable, Equatable, Sendable {
    /// 卡了多久:`durationBuckets` 之一;还没恢复(随后被强制退出、或这一条写进去时还卡着)是 `unrecovered`。
    public var duration: String
    /// 卡住时 App 已经醒着跑了多久(不含睡眠),`elapsedBuckets` 之一。
    public var sinceLaunch: String
    /// 离上一次系统唤醒多久;启动以来没睡过为 nil。
    public var sinceWake: String?
    /// 最近一次放歌的播放器(`Telemetry.playerTag`)。
    public var player: String?
    /// 卡住前开着的窗口(`windowTags` 里的取值)。
    public var windows: [String]
    /// 系统温度状态:nominal / fair / serious / critical。
    public var thermal: String
    /// 采样到的主线程调用栈:最深的几帧,再接最深的几个 Lyrimuse 自己的帧,都按从深到浅排;没采样时为空。
    public var stack: [TelemetryCrash.Frame]

    public init(duration: String = TelemetryHang.unrecovered, sinceLaunch: String, sinceWake: String?, player: String? = nil,
                windows: [String], thermal: String, stack: [TelemetryCrash.Frame] = []) {
        self.duration = duration
        self.sinceLaunch = sinceLaunch
        self.sinceWake = sinceWake
        self.player = player
        self.windows = windows
        self.thermal = thermal
        self.stack = stack
    }

    enum CodingKeys: String, CodingKey {
        case duration, sinceLaunch = "since_launch", sinceWake = "since_wake", player, windows, thermal, stack
    }

    public static let unrecovered = "unrecovered"
    /// Worker(telemetry-worker/src/index.js 的 HANG_DURATIONS / HANG_ELAPSED / HANG_WINDOWS / HANG_THERMAL)认的取值,两处一起改。
    public static let durationBuckets = ["5-10s", "10-30s", "30s+", unrecovered]
    public static let elapsedBuckets = ["<1m", "1-10m", "10-60m", "1-6h", "6h+"]
    public static let thermalStates = ["nominal", "fair", "serious", "critical"]
    /// 前面几个是 SwiftUI 场景 id(窗口标识里含它,设置窗口的标识里含 `Settings`);`menubar-panel` 是菜单栏面板。
    public static let windowTags = ["settings", "lyrics-manager", "lyrics-window", "lyrics-quick-search", "lyrics-share",
                                    "whats-new", "onboarding", "menubar-panel"]
    /// 栈里最多几帧:最深的 `leafFrames` 帧 + 最深的 `ownFrames` 个自家帧。
    public static let leafFrames = 3, ownFrames = 3
    public static let symbolLimit = 200

    public static func durationBucket(seconds: TimeInterval) -> String {
        seconds < 10 ? "5-10s" : seconds < 30 ? "10-30s" : "30s+"
    }

    public static func elapsedBucket(seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "<1m"
        case ..<600: return "1-10m"
        case ..<3600: return "10-60m"
        case ..<21_600: return "1-6h"
        default: return "6h+"
        }
    }

    public static func thermalTag(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    /// 窗口标识 → `windowTags` 里的取值;认不出的不报。
    public static func windowTag(identifier: String) -> String? {
        if identifier == "menubar-panel" { return identifier }
        return windowTags.first { $0 != "menubar-panel" && identifier.localizedCaseInsensitiveContains($0) }
    }

    public static func windowTags(identifiers: [String]) -> [String] {
        Array(Set(identifiers.compactMap(windowTag(identifier:)))).sorted()
    }

    /// 从 `/usr/bin/sample` 的输出里取主线程最重的那条调用路径:最深的 `leafFrames` 帧,再接路径上最深的 `ownFrames` 个
    /// `executable` 自己的帧(前面已经取到的不重复),都按从深到浅排。发版包剥了符号,自家帧只有偏移(跟崩溃摘要的
    /// `imageOffset` 同一口径,用发版符号包能还原);有符号的(本机构建)带符号。找不到主线程时返回空。
    public static func mainThreadStack(fromSample text: String, executable: String) -> [TelemetryCrash.Frame] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let graph = lines.firstIndex(where: { $0.hasPrefix("Call graph:") }) else { return [] }
        let threads = lines[(graph + 1)...].indices.filter { lines[$0].contains("Thread_") && countColumn(lines[$0]) != nil }
        guard let header = threads.first(where: { lines[$0].contains("com.apple.main-thread") }) ?? threads.first,
              var column = countColumn(lines[header]) else { return [] }
        // 调用图按深度优先排,每个节点的子节点按样本数从多到少:紧跟着、缩进更深的那一行就是最重的子节点。
        var path: [TelemetryCrash.Frame] = []
        var i = header + 1
        while i < lines.count, let next = countColumn(lines[i]), next > column {
            if let frame = frame(lines[i]) { path.append(frame) }
            column = next
            i += 1
        }
        let deepestFirst = Array(path.reversed())
        var picked = Array(deepestFirst.prefix(leafFrames))
        let own = deepestFirst.dropFirst(leafFrames).filter { $0.image == executable }.prefix(ownFrames)
        picked.append(contentsOf: own)
        return picked
    }

    /// 行里样本数开始的那一列(`+ ! : |` 和空格是缩进);不是调用图的行返回 nil。
    private static func countColumn(_ line: Substring) -> Int? {
        var column = 0
        for ch in line {
            if ch == " " || ch == "+" || ch == "!" || ch == ":" || ch == "|" { column += 1; continue }
            return ch.isNumber ? column : nil
        }
        return nil
    }

    /// `1542 -[NSApplication run]  (in AppKit) + 396  [0x186a8290c]`、
    /// `1542 ???  (in lyrimuse)  load address 0x10022c000 + 0x8f9648  [0x100b25648]`。
    private static func frame(_ line: Substring) -> TelemetryCrash.Frame? {
        var start = line.startIndex
        while start < line.endIndex, !line[start].isNumber { start = line.index(after: start) }
        while start < line.endIndex, line[start].isNumber { start = line.index(after: start) }
        while start < line.endIndex, line[start] == " " { start = line.index(after: start) }
        let body = line[start...]
        guard let open = body.range(of: "  (in ") else { return nil }
        let symbol = String(body[..<open.lowerBound])
        let afterImage = body[open.upperBound...]
        guard let close = afterImage.firstIndex(of: ")") else { return nil }
        let image = String(afterImage[..<close])
        var offset: Int?
        if let load = afterImage.range(of: "load address "), let plus = afterImage[load.upperBound...].range(of: " + 0x") {
            let hex = afterImage[plus.upperBound...].prefix { $0.isHexDigit }
            offset = Int(hex, radix: 16)
        }
        let known = symbol != "???" && !symbol.isEmpty
        return TelemetryCrash.Frame(image: String(Telemetry.redactPaths(image).prefix(Telemetry.crashImageLimit)),
                                    symbol: known ? String(Telemetry.redactPaths(symbol).prefix(symbolLimit)) : nil,
                                    offset: known ? nil : offset)
    }
}

/// 认系统睡过没有:不含睡眠的运行时长(`systemUptime`)跟含睡眠的单调时钟两次之间走得不一样多,差出来的就是睡着的那段。
/// 看门狗每一拍喂一次。
public struct WakeDetector: Equatable, Sendable {
    /// 两拍之间差出这么多才算睡过(定时器本身的抖动、App Nap 推迟两边都一样,不会差出来)。
    public static let minimumSleep: TimeInterval = 10

    public private(set) var lastWakeUptime: TimeInterval?
    private var last: (uptime: TimeInterval, continuous: TimeInterval)?

    public init() {}

    public static func == (a: WakeDetector, b: WakeDetector) -> Bool {
        a.lastWakeUptime == b.lastWakeUptime && a.last?.uptime == b.last?.uptime && a.last?.continuous == b.last?.continuous
    }

    public mutating func observe(uptime: TimeInterval, continuous: TimeInterval) {
        if let last, (continuous - last.continuous) - (uptime - last.uptime) >= Self.minimumSleep {
            lastWakeUptime = uptime
        }
        last = (uptime, continuous)
    }

    /// 含睡眠的单调时钟(秒)。
    public static var continuousNow: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}
