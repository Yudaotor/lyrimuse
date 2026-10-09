import Foundation
import OSLog

/// 读写本机文件的统一出口:失败一律记进 `file-io` 这一类日志,排查时按它一条 grep 找全。
///
/// - 读:文件不存在是常态(还没写过、刚被清掉),不记;没权限、读出错、JSON 解不开都记。
/// - 写、建目录、搬文件:失败都记。
/// - 同一路径、同一种操作、同一种错误只记第一次,轮询读写的状态文件不会刷屏;这一路径的这种操作成功一次之后,
///   再失败会重新记。
///
/// 别再对写文件、建目录、搬文件、读文件写裸 `try?`:失败会完全无声(selftest ops-diagnostics 组「文件读写走 FileIO」守着)。
/// 删临时文件这类清理可以照旧 `try?`。见 15 章决策 32。
public enum FileIO {
    static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "file-io")
    private static let lock = NSLock()
    /// 「操作 + 路径」→ 上一次记过的错误。只在失败路径和「之前失败过」时碰。
    nonisolated(unsafe) private static var reported: [String: String] = [:]

    // MARK: 读

    /// 读整个文件。不存在返回 nil、不记;别的错误记一次后返回 nil。
    public static func read(_ url: URL, options: Data.ReadingOptions = []) -> Data? {
        do {
            let data = try Data(contentsOf: url, options: options)
            succeeded("read", url)
            return data
        } catch {
            if !isNoSuchFile(error) { failed("read", url, error) }
            return nil
        }
    }

    /// 按 UTF-8 读整个文件,规则同 `read`。
    public static func readString(_ url: URL) -> String? {
        guard let data = read(url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            failed("decode", url, CocoaError(.fileReadInapplicableStringEncoding))
            return nil
        }
        return text
    }

    /// 读文件再按 JSON 解码。不存在返回 nil、不记;读不出、解不开记一次后返回 nil。
    public static func decodeJSON<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard let data = read(url) else { return nil }
        return decodeJSON(type, from: data, source: url, decoder: decoder)
    }

    /// 已经读到手的文件内容按 JSON 解码,解不开按 `source` 这个路径记一次。
    public static func decodeJSON<T: Decodable>(
        _ type: T.Type, from data: Data, source url: URL, decoder: JSONDecoder = JSONDecoder()
    ) -> T? {
        do {
            let value = try decoder.decode(type, from: data)
            succeeded("decode", url)
            return value
        } catch {
            failed("decode", url, error)
            return nil
        }
    }

    // MARK: 写

    /// 写文件,默认原子写。失败记一次、返回 false。
    @discardableResult
    public static func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) -> Bool {
        attempt("write", url) { try data.write(to: url, options: options) }
    }

    /// 按 UTF-8 写文本,原子写。
    @discardableResult
    public static func write(_ text: String, to url: URL) -> Bool {
        write(Data(text.utf8), to: url)
    }

    /// 建目录(含中间层),已经存在算成功。
    @discardableResult
    public static func createDirectory(_ url: URL) -> Bool {
        attempt("mkdir", url) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    /// 搬文件。
    @discardableResult
    public static func move(_ source: URL, to destination: URL) -> Bool {
        attempt("move", destination) { try FileManager.default.moveItem(at: source, to: destination) }
    }

    /// 删文件或目录。不存在算成功、不记。
    @discardableResult
    public static func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            succeeded("remove", url)
            return true
        } catch {
            if isNoSuchFile(error) { return true }
            failed("remove", url, error)
            return false
        }
    }

    /// 包住一段会抛错的文件操作:失败按 `operation` + `url` 记一次、返回 false。给 `writeSecurely`、`setAttributes`
    /// 这类上面没覆盖到的写法用。
    @discardableResult
    public static func attempt(_ operation: String, _ url: URL, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            succeeded(operation, url)
            return true
        } catch {
            failed(operation, url, error)
            return false
        }
    }

    // MARK: 记账

    /// 一次失败该不该记:同一「操作 + 路径」上一次记过的就是这个错误,就不再记。纯逻辑,selftest 覆盖。
    public static func shouldReport(_ key: String, signature: String, previous: [String: String]) -> Bool {
        previous[key] != signature
    }

    static func failed(_ operation: String, _ url: URL, _ error: Error) {
        let key = operation + " " + url.path
        let signature = describe(error)
        lock.lock()
        let report = shouldReport(key, signature: signature, previous: reported)
        if report { reported[key] = signature }
        lock.unlock()
        guard report else { return }
        let path = HomeFolderAccess.displayPath(url.path)
        logger.error("file-io: \(operation, privacy: .public) failed path=\(path, privacy: .public) error=\(signature, privacy: .public)")
    }

    private static func succeeded(_ operation: String, _ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !reported.isEmpty else { return }
        reported.removeValue(forKey: operation + " " + url.path)
    }

    /// 错误写成固定英文:错误域、错误码,底层有 POSIX errno 时带上 errno 和系统说明;解码错误带上出错位置。
    /// 不用 `localizedDescription`,它跟着系统语言变,也会带上整条路径。
    public static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            return "DecodingError " + decodingSummary(decoding)
        }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        let posix = ns.domain == NSPOSIXErrorDomain
            ? ns : (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0 : nil }
        if let posix {
            text += " (errno \(posix.code): \(String(cString: strerror(Int32(posix.code)))))"
        }
        return text
    }

    private static func decodingSummary(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            return keys.isEmpty ? "<root>" : keys.joined(separator: ".")
        }
        switch error {
        case .typeMismatch(_, let context): return "typeMismatch at \(path(context))"
        case .valueNotFound(_, let context): return "valueNotFound at \(path(context))"
        case .keyNotFound(let key, let context): return "keyNotFound \(key.stringValue) at \(path(context))"
        case .dataCorrupted(let context): return "dataCorrupted at \(path(context))"
        @unknown default: return "unknown"
        }
    }

    /// 「文件不存在」:读、删时是常态,不记。写进一个不存在的目录也报这一类,所以只在读、删时这样判。
    public static func isNoSuchFile(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }
}
