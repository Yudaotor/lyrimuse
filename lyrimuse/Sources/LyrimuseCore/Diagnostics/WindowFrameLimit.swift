import Foundation

/// AppKit 设窗口帧时的上限断言:`-[NSWindow _reallySetFrame:]` 要求帧落在 ±2^31 之内(开关 `NSWindowAssertFrameLimits`,
/// 新 SDK 默认开),越界(无穷、NaN、超大)由断言处理器抛 `NSInternalInconsistencyException`,进程中止。系统崩溃报告里
/// 只有「abort() called」和一串系统帧,看不出是哪扇窗口、要设成多大。
///
/// 异常预处理器(`SwallowedExceptionGuard`)在抛的当场认出这句断言,把窗口种类(窗口标识符,SwiftUI 场景窗口就是场景 id;
/// 没有标识符写 `none`)、类名、要设的帧和当前的帧写进 `notesDirectory` 下按进程号命名的小文件。下次扫崩溃报告时
/// (`attachNote`),同一进程号、异常栈里有 `_reallySetFrame:` 的那份报告把这一行补进 `terminationReasons`,诊断导出和
/// 遥测都带上。只记种类和数字,不记标题之类的内容。不改断言本身:照旧崩。见 15 章决策 130。
public enum WindowFrameLimit {
    public static let exceptionName = "NSInternalInconsistencyException"
    /// 断言原文里的条件开头(`CGRectContainsRect(CGRectMake((CGFloat)INT_MIN, …), frame)`)。
    public static let assertionMarker = "CGRectContainsRect(CGRectMake((CGFloat)INT_MIN"
    /// 崩溃报告异常栈里抛这句断言的那一帧。
    public static let throwSiteSymbol = "-[NSWindow _reallySetFrame:]"
    public static let notePrefix = "window frame limit: "
    /// 说明文件跟崩溃报告的修改时间最多差多少还算同一次(进程号会复用)。
    public static let noteMatchWindow: TimeInterval = 600
    /// 说明文件留多久;过了就删。
    public static let noteMaxAge: TimeInterval = 30 * 86_400
    static let maxNotesPerProcess = 20

    public struct Event: Equatable, Sendable {
        /// 断言原文里 `self=<类名: 地址>` 的类名,只留字母、数字、`_ . $`,最长 80。
        public let windowClass: String
        public let windowAddress: UInt?
        /// 要设的帧,原文里 `frame=` 之后那段,只留数字和 `inf` / `nan` 这类写法,最长 80。
        public let frame: String

        public init(windowClass: String, windowAddress: UInt?, frame: String) {
            self.windowClass = windowClass
            self.windowAddress = windowAddress
            self.frame = frame
        }
    }

    /// App 启动时设一次;nil 时不写说明文件。只在主线程上读。
    nonisolated(unsafe) public static var notesDirectory: URL?
    nonisolated(unsafe) private static var notesWritten = 0

    /// 原文形如「Invalid parameter not satisfying: CGRectContainsRect(CGRectMake((CGFloat)INT_MIN, …), frame).
    /// self=<SwiftUI.AppKitWindow: 0x7a588e8600> frame={{nan, 274}, {inf, 450}}」;不是这句返回 nil。
    public static func parse(name: String, reason: String?) -> Event? {
        guard name == exceptionName, let reason, reason.contains(assertionMarker) else { return nil }
        var windowClass = ""
        var address: UInt?
        if let open = reason.range(of: "self=<"), let colon = reason[open.upperBound...].range(of: ": 0x") {
            windowClass = String(reason[open.upperBound..<colon.lowerBound])
            address = UInt(String(reason[colon.upperBound...].prefix { $0.isHexDigit }), radix: 16)
        }
        var frame = ""
        if let start = reason.range(of: " frame=", options: .backwards) {
            frame = String(reason[start.upperBound...])
        }
        return Event(windowClass: sanitizedName(windowClass) ?? "unknown", windowAddress: address,
                     frame: sanitizedFrame(frame) ?? "unknown")
    }

    /// 写进 `terminationReasons` 的那一行。
    public static func noteLine(_ event: Event, identifier: String?, currentFrame: String?) -> String {
        "\(notePrefix)window=\(sanitizedName(identifier) ?? "none") class=\(event.windowClass) frame=\(event.frame)"
            + " current=\(sanitizedFrame(currentFrame) ?? "unknown")"
    }

    /// 异常预处理器里调(主线程、正在抛异常)。不能带主线程隔离,窗口经 KVC 找,不碰 `MainActor` 的属性。
    public static func noteThrown(name: String, reason: String?) {
        guard let directory = notesDirectory, notesWritten < maxNotesPerProcess,
              let event = parse(name: name, reason: reason) else { return }
        notesWritten += 1
        let window = event.windowAddress.flatMap(liveWindow(address:))
        let identifier = window?.value(forKey: "identifier") as? String
        let current = (window?.value(forKey: "frame") as? NSValue).map { NSStringFromRect($0.rectValue) }
        write(noteLine(event, identifier: identifier, currentFrame: current), pid: getpid(), in: directory)
    }

    /// 地址是断言原文里 `self` 的那扇窗口:只在本进程的窗口列表里按地址比对,不把原文里的地址当指针用。
    static func liveWindow(address: UInt) -> NSObject? {
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.value(forKey: "sharedApplication") as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject] else { return nil }
        return windows.first { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) == address }
    }

    public static func noteURL(pid: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("\(pid).txt")
    }

    public static func write(_ line: String, pid: Int32, in directory: URL) {
        FileIO.createDirectory(directory)
        FileIO.write(line, to: noteURL(pid: Int(pid), in: directory))
    }

    /// 报告是这句断言崩的(异常栈里有 `_reallySetFrame:`)、同一进程号留了说明、说明跟报告的修改时间差在
    /// `noteMatchWindow` 以内,就把说明那一行放到 `terminationReasons` 最前面。补上了返回 true。
    @discardableResult
    public static func attachNote(to summary: inout CrashReportSummary, in directory: URL, reportModified: Date) -> Bool {
        guard let pid = summary.pid,
              summary.exceptionFrames.contains(where: { $0.symbol == throwSiteSymbol }) else { return false }
        let url = noteURL(pid: pid, in: directory)
        guard let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              abs(reportModified.timeIntervalSince(written)) <= noteMatchWindow,
              let text = FileIO.readString(url) else { return false }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(notePrefix), !summary.terminationReasons.contains(line) else { return false }
        summary.terminationReasons.insert(line, at: 0)
        return true
    }

    /// 删掉留了超过 `noteMaxAge` 的说明文件。扫崩溃报告时顺带调,不在主线程上调。
    public static func pruneNotes(in directory: URL, now: Date = Date()) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in items where url.pathExtension == "txt" {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(date) > noteMaxAge else { continue }
            try? fm.removeItem(at: url)
        }
    }

    static func sanitizedName(_ text: String?) -> String? {
        guard let text else { return nil }
        let kept = String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_.$-".contains($0)) }.prefix(80))
        return kept.isEmpty ? nil : kept
    }

    static func sanitizedFrame(_ text: String?) -> String? {
        guard let text else { return nil }
        let kept = String(text.filter { "0123456789.,{} -+einfaINFA".contains($0) }.prefix(80))
            .trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? nil : kept
    }
}
