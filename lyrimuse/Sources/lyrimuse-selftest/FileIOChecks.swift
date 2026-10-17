import Foundation
import LyrimuseCore

/// 文件读写的统一出口 `FileIO`,以及「别对文件读写写裸 try?」的守卫(15 章决策 32)。在 `runOpsDiagnosticsTests` 里调用。
func fileIOChecks() {
    // ---- 只记一次 ----
    expectEqual(FileIO.shouldReport("write /a", signature: "E1", previous: [:]), true, "FileIO: 第一次失败要记")
    expectEqual(FileIO.shouldReport("write /a", signature: "E1", previous: ["write /a": "E1"]), false,
                "FileIO: 同一路径同一种错误不再记")
    expectEqual(FileIO.shouldReport("write /a", signature: "E2", previous: ["write /a": "E1"]), true,
                "FileIO: 错误换了要再记")
    expectEqual(FileIO.shouldReport("read /a", signature: "E1", previous: ["write /a": "E1"]), true,
                "FileIO: 同一路径换一种操作单独算")

    // ---- 错误写成固定英文 ----
    let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                         userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
    expectEqual(FileIO.describe(denied), "NSCocoaErrorDomain 513 (errno 13: Permission denied)", "FileIO: 带上 errno 和系统说明")
    let corrupt = DecodingError.keyNotFound(
        AnyKey("pins"), .init(codingPath: [AnyKey("file")], debugDescription: "x"))
    expectEqual(FileIO.describe(corrupt), "DecodingError keyNotFound pins at file", "FileIO: 解码错误带出错位置")

    // ---- 「文件不存在」读、删时不算失败 ----
    expectEqual(FileIO.isNoSuchFile(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)), true,
                "FileIO: 读不到文件算不存在")
    expectEqual(FileIO.isNoSuchFile(denied), false, "FileIO: 没权限不算不存在")

    // ---- 真文件 ----
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileio-\(UUID().uuidString)")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("ro").path)
        try? FileManager.default.removeItem(at: dir)
    }
    let file = dir.appendingPathComponent("a.json")
    expectEqual(FileIO.read(file), nil, "FileIO: 不存在的文件读成 nil")
    expectEqual(FileIO.write(Data("{}".utf8), to: dir.appendingPathComponent("missing/b.json")), false,
                "FileIO: 写进不存在的目录报失败")
    expectEqual(FileIO.createDirectory(dir), true, "FileIO: 建目录")
    expectEqual(FileIO.createDirectory(dir), true, "FileIO: 目录已存在也算成功")
    expectEqual(FileIO.write("{\"x\":1}", to: file), true, "FileIO: 写文本")
    expectEqual(FileIO.decodeJSON([String: Int].self, from: file), ["x": 1], "FileIO: 读出来按 JSON 解")
    expectEqual(FileIO.write("not json", to: file), true, "FileIO: 覆盖写")
    expectEqual(FileIO.decodeJSON([String: Int].self, from: file), nil, "FileIO: 解不开读成 nil")
    let readOnly = dir.appendingPathComponent("ro")
    _ = FileIO.createDirectory(readOnly)
    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    if getuid() != 0 {
        expectEqual(FileIO.write("x", to: readOnly.appendingPathComponent("c.txt")), false, "FileIO: 写不进的目录报失败")
    }
    expectEqual(FileIO.move(file, to: dir.appendingPathComponent("moved.json")), true, "FileIO: 搬文件")
    expectEqual(FileIO.remove(dir.appendingPathComponent("moved.json")), true, "FileIO: 删文件")
    expectEqual(FileIO.remove(dir.appendingPathComponent("moved.json")), true, "FileIO: 删不存在的文件也算成功")

    // ---- 守卫:App 和 Core 里不许对文件读写写裸 try? ----
    // 读文件、写文件、建目录、搬 / 拷 / 换文件都要走 FileIO(或自己 do/catch 记日志),失败才留得下痕迹。
    // 删文件不在此列:清理临时文件失败不影响功能。按语句扫:含 try? 的那一行,连同括号没配平的续行和以 `.` 开头的
    // 链式续行(`try? x\n    .write(to:`)拼成一句再比,换行拆开的写法也认;整行注释跳过。
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let banned = [
        #"try\?[^\n]*\.write\(to(File)?:"#,
        #"try\?[^\n]*\bcreateDirectory\("#,
        #"try\?[^\n]*(?<!re)moveItem\("#,
        #"try\?[^\n]*\b(copyItem|replaceItem(At)?)\("#,
        #"try\?\s*(Data|String)\(contentsOf:"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    /// lines[start] 起的一句:括号没配平就接着拼下一行,下一行以 `.` 开头(链式调用)也拼上,最多看 6 行。
    func statement(_ lines: [String], from start: Int) -> String {
        var text = lines[start]
        var depth = text.filter { $0 == "(" }.count - text.filter { $0 == ")" }.count
        var next = start + 1
        while next < lines.count, next - start <= 6 {
            let following = lines[next].trimmingCharacters(in: .whitespaces)
            guard depth > 0 || following.hasPrefix(".") else { break }
            text += " " + following
            depth += following.filter { $0 == "(" }.count - following.filter { $0 == ")" }.count
            next += 1
        }
        return text
    }
    func isBanned(_ code: String) -> Bool {
        let range = NSRange(code.startIndex..., in: code)
        return banned.contains(where: { $0.firstMatch(in: code, range: range) != nil })
    }
    // 扫描规则自己的样例:换行拆开的链式写法要认得,同一行里 try? 之后没有文件写入的不算。
    expectEqual(isBanned(statement(["try? text", "    .write(to: url, atomically: true, encoding: .utf8)"], from: 0)), true,
                "文件读写走 FileIO: 换行拆开的 try? … .write(to:) 也认")
    expectEqual(isBanned(statement(["try? FileManager.default", "    .createDirectory(at: url, withIntermediateDirectories: true)"], from: 0)),
                true, "文件读写走 FileIO: 链式换行的 createDirectory 也认")
    expectEqual(isBanned(statement(["let x = try? decoder.decode(T.self, from: data)", "file.write(to: url)"], from: 0)), false,
                "文件读写走 FileIO: 下一句不是续行,不拼进来")
    var offenders: [String] = []
    var scannedFiles: [String: Int] = [:]
    for target in ["LyrimuseCore", "lyrimuse"] {
        let root = sources.appendingPathComponent(target)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "FileIO.swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scannedFiles[target, default: 0] += 1
            guard sourceBytes(text, contain: "try?") else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, code) in lines.enumerated() {
                guard code.contains("try?"), !code.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                if isBanned(statement(lines, from: index)) {
                    offenders.append("\(target)/\(url.path.replacingOccurrences(of: root.path + "/", with: "")):\(index + 1)")
                }
            }
        }
    }
    // 目录读不到、或者文件一个都没读出来时,下面那条「没有违规」是空跑出来的绿。
    expectEqual((scannedFiles["LyrimuseCore"] ?? 0) > 20 && (scannedFiles["lyrimuse"] ?? 0) > 50, true,
                "文件读写走 FileIO: 两个 target 都扫到了源文件(LyrimuseCore \(scannedFiles["LyrimuseCore"] ?? 0) 个、lyrimuse \(scannedFiles["lyrimuse"] ?? 0) 个)")
    expectEqual(offenders, [], "文件读写走 FileIO: 这些地方对文件读写写了裸 try?,失败会完全无声")
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
