import Foundation

/// 「整字典读写」的 JSON 配置文件(`config.json` / `lyrimuse-features.json`)的纯逻辑部分:读盘分三态、
/// 合并、序列化、写盘。App 侧两个 Store(ConfigStore / FeatureSettingsStore)只剩 `@MainActor` 外壳、
/// 字段映射和文案。
///
/// 2026-09-05 加。此前两个 Store 各自 `try? Data(contentsOf:)` + `try? JSONSerialization`,把「文件不存在」
/// 和「文件在、但解析不出」当同一件事:都落成空字典 + 字段初值,下一次保存把 14 个字段(或一份默认开关)
/// **整个写回去**。config.json 只要被手改 / 搬家 / 导入弄出一个 JSON 语法错误,启动后各账号显示为空,
/// 用户随手在任意一栏输入、点一次「断开 Last.fm」、或 Last.fm 授权成功,就用一整套空串覆盖原文件 ——
/// Last.fm session key / ListenBrainz token / relay token,连带 `api_root` / `log_level` 这些 App 不管
/// 的字段一起丢。collector 侧(Go)逐字段容错且从不写回这两个文件,风险只在 Swift 写入方。
///
/// 所以读盘分**三态**,而不是「读到了 / 没读到」两态:
///   - `missing`:文件不存在。首次保存允许直接创建(全新机器走的就是这条)。
///   - `loaded`:读到并解析成 JSON 对象。
///   - `corrupt`:文件在,但读不出 / 不是合法 JSON / 顶层不是对象。这份文件里有什么我们一无所知,
///     保存等于把它整个覆盖 —— 所以 `save` **拒绝**,直到用户修好文件、或明确放弃它
///     (`quarantineCorruptFile`:挪到旁边而不是删掉,里面可能还有能手工抢救的凭据)。
///
/// 「写失败不污染内存」:`save(fields:)` 是合并 → 序列化 → 写盘 → **成功之后**才把合并结果记为 `raw`、
/// 把状态推进到 `loaded`;任何一步抛错 self 原样不动,调用方的「已保存快照」自然也不推进,下一次保存
/// 重试整份。原来 ConfigStore.persistFile 是先改字典再写盘 —— 那时字典只是写缓冲、没造成实害,但这个
/// 顺序一旦被哪次重构当成「内存已同步」就是坑,这里把顺序钉死。
///
/// 放在 Core 而不是留在 Store 里:纯逻辑放进 Core 才能被 selftest 拿真实的临时目录钉住(ops-diagnostics
/// 组「配置文件三态读写」);两个 Store 在 app target,selftest 碰不到。
public struct JSONConfigDocument {
    public enum LoadState: Equatable {
        /// 文件不存在。
        case missing
        /// 读到并解析成 JSON 对象。
        case loaded
        /// 文件在但不可用。`reason` 是给日志 / 界面的一句英文技术描述(Foundation 的错误文本或这里的固定
        /// 短语),**不含文件内容** —— config.json 里是凭据。
        case corrupt(reason: String)
    }

    public enum Failure: Error, Equatable {
        /// 磁盘上那份文件加载时判定为损坏,拒绝覆盖。
        case refusedCorruptFile(reason: String)
        /// 合并后的字典里混进了 JSONSerialization 写不出去的类型(编程错误,不是用户数据的问题)。
        case notSerializable
    }

    /// `parseObject` 的失败原因。单独成类型只是为了让 `Result` 有个 `Error` 可放。
    public struct ParseFailure: Error, Equatable {
        public let reason: String
        public init(reason: String) { self.reason = reason }
    }

    public let url: URL
    /// 磁盘上那份对象的内存镜像(全部键,含这个版本不认识的)。只在 `load` / `save` 成功时变。
    public private(set) var raw: [String: Any]
    public private(set) var state: LoadState

    public init(url: URL, raw: [String: Any] = [:], state: LoadState = .missing) {
        self.url = url
        self.raw = raw
        self.state = state
    }

    public var isCorrupt: Bool {
        if case .corrupt = state { return true }
        return false
    }

    public var corruptReason: String? {
        if case .corrupt(let reason) = state { return reason }
        return nil
    }

    // MARK: 读

    /// 读盘。永不抛错:读不出 / 解析失败全部编码进 `state`,调用方按三态各自处理。
    public static func load(url: URL) -> JSONConfigDocument {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return JSONConfigDocument(url: url, raw: [:], state: .missing)
        }
        if isDirectory.boolValue {
            return JSONConfigDocument(url: url, raw: [:], state: .corrupt(reason: "path is a directory"))
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return JSONConfigDocument(url: url, raw: [:], state: .corrupt(reason: "unreadable: \(describe(error))"))
        }
        switch parseObject(data) {
        case .success(let object):
            return JSONConfigDocument(url: url, raw: object, state: .loaded)
        case .failure(let failure):
            return JSONConfigDocument(url: url, raw: [:], state: .corrupt(reason: failure.reason))
        }
    }

    /// 字节 → 顶层 JSON 对象。空文件、非法 JSON、顶层是数组 / 标量都算失败。
    public static func parseObject(_ data: Data) -> Result<[String: Any], ParseFailure> {
        if data.isEmpty { return .failure(ParseFailure(reason: "empty file")) }
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .failure(ParseFailure(reason: "not valid JSON: \(describe(error))"))
        }
        guard let object = any as? [String: Any] else {
            return .failure(ParseFailure(reason: "top-level JSON is not an object"))
        }
        return .success(object)
    }

    // MARK: 写

    /// 已知键以 `fields` 为准 —— `fields` 里没有的已知键从文件里**删掉**(遗留迁移字段「这台机器往后不再写它」
    /// 的语义靠这条),其余键原样保留(这个版本不认识的字段写一次就没了,是 2026-08-13 修过的老 bug)。
    /// `knownKeys` 不给就取 `fields.keys`,即「给了什么就覆盖什么、别的都留着」。
    public func merging(fields: [String: Any], knownKeys: Set<String>? = nil) -> [String: Any] {
        let known = knownKeys ?? Set(fields.keys)
        var merged = raw.filter { !known.contains($0.key) }
        for (key, value) in fields { merged[key] = value }
        return merged
    }

    /// 字典 → 带缩进、键排序的字节。键排序是为了两次保存之间 diff 干净(iCloud 备份 / 手工比对都受益)。
    public static func serialize(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw Failure.notSerializable }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// 合并 → 序列化 → 写盘 → 成功后才更新 `raw` / `state`。
    ///
    /// - `secure`:true 走 `writeSecurely`(原子写 + 0600,凭据文件必须);false 普通原子写。
    /// - 抛 `Failure.refusedCorruptFile`:磁盘上那份是坏的,一个字节都没碰。
    /// - 抛 `Failure.notSerializable` 或文件系统错误:同样一个字节都没碰、self 不变。
    public mutating func save(fields: [String: Any], knownKeys: Set<String>? = nil, secure: Bool) throws {
        if case .corrupt(let reason) = state {
            throw Failure.refusedCorruptFile(reason: reason)
        }
        let merged = merging(fields: fields, knownKeys: knownKeys)
        let data = try Self.serialize(merged)
        if secure {
            try data.writeSecurely(to: url)
        } else {
            try data.write(to: url, options: .atomic)
        }
        raw = merged
        state = .loaded
    }

    /// 调用方在对象层面之上又发现文件不可用(比如字段类型对不上、按类型解不出来)时把状态降成损坏 ——
    /// 从此 `save` 一样拒绝。只能从 `loaded` 降,`missing` 没有文件可言。
    public mutating func markCorrupt(reason: String) {
        guard state == .loaded else { return }
        raw = [:]
        state = .corrupt(reason: reason)
    }

    /// 用户明确放弃坏文件:把它挪到旁边(`<文件名>.corrupt-<yyyyMMdd-HHmmss>`)而**不是删掉** —— 里面可能
    /// 还有能手工抢救的凭据;然后状态归 `missing`,下一次 `save` 直接重建。非损坏状态下什么都不做、返回 nil。
    @discardableResult
    public mutating func quarantineCorruptFile(now: Date = Date()) throws -> URL? {
        guard isCorrupt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let fm = FileManager.default
        var destination = url.appendingPathExtension("corrupt-\(stamp)")
        var counter = 1
        while fm.fileExists(atPath: destination.path) {
            destination = url.appendingPathExtension("corrupt-\(stamp)-\(counter)")
            counter += 1
        }
        try fm.moveItem(at: url, to: destination)
        raw = [:]
        state = .missing
        return destination
    }

    /// 错误 → 一句话。优先 `NSDebugDescription`(JSONSerialization 把「第几行第几列遇到什么字符」放在这里,
    /// 比 localizedDescription 那句「格式不正确」有用得多),它只含一个字符和位置,不会把文件内容带出来。
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let debug = ns.userInfo[NSDebugDescriptionErrorKey] as? String, !debug.isEmpty {
            return debug
        }
        return ns.localizedDescription
    }
}
