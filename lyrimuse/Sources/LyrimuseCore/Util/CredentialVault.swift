import Foundation

/// 凭据保险箱:账号 token、推送地址与密钥、Apple Music 用户令牌存在登录钥匙串的一个条目里,不在 `config.json`
/// 和令牌文件里。App 读写,引擎只读(lyrimuse-engine/credentialvault.go)。
///
/// 两边都经 `/usr/bin/security` 读写(`KeychainCLI`),不用 `SecItem`:`SecItem` 建的条目只信任 App 自己,
/// 引擎去读会弹授权框;`security` 建的条目只信任这个 Apple 签名的程序,App 更新、换签名都不弹。
///
/// 条目:服务名 `<bundle id>.credentials`,账号见 `StorageLayout.credentialAccount`(默认位置一律是旧数据目录的路径串),
/// 内容是一份 JSON 的 base64:
/// `{"config": {<configKeys 里的键>: 值}, "channels": {<渠道 id>: {"url": …, "secret": …}}, "media_user_token": "…"}`。
/// 读配置时叠到文件上(`overlay`):文件里那一项缺失或为空才取保险箱的;文件里有值(旧版本写的、手改的、刚导入的)
/// 以文件为准,`ConfigStore` 读到时把它挪进钥匙串。叠法跟引擎 overlayCredentials 一致,两边读同一份
/// `lyrimuse-engine/testdata/credentialvault/overlay.json` 对拍。见 15 章决策 73。
public enum CredentialVault {
    /// `config.json` 里算凭据、存进保险箱的顶层键。跟引擎 credentialConfigKeys 逐项一致。
    public static let configKeys: Set<String> = [
        "listenbrainz_token", "state_relay_token",
        "lastfm_api_key", "lastfm_scrobble_api_key", "lastfm_scrobble_secret", "lastfm_scrobble_session_key",
        "bark_url", "notification_webhook_urls", "dingtalk_sign_secret", "feishu_sign_secret",
    ]
    public static let service = LyrimuseIdentity.bundleIdentifier + ".credentials"
    public static let configSection = "config"
    public static let channelsSection = "channels"
    public static let mediaUserTokenKey = "media_user_token"

    /// 保险箱叠到 `config.json` 的内容上:凭据键缺失或为空时取保险箱的,渠道按 id 补地址和密钥。
    public static func overlay(_ file: [String: Any], vault: [String: Any]) -> [String: Any] {
        var out = file
        for (key, value) in vault[configSection] as? [String: Any] ?? [:]
        where configKeys.contains(key) && isBlank(out[key]) && !isBlank(value) {
            out[key] = value
        }
        let saved = vault[channelsSection] as? [String: Any] ?? [:]
        if !saved.isEmpty, let channels = out["notification_channels"] as? [Any] {
            out["notification_channels"] = channels.map { item -> Any in
                guard var ch = item as? [String: Any], let id = ch["id"] as? String,
                      let entry = saved[id] as? [String: Any] else { return item }
                for field in ["url", "secret"] {
                    if let value = entry[field] as? String, !value.isEmpty, isBlank(ch[field]) { ch[field] = value }
                }
                return ch
            }
        }
        return out
    }

    /// 整份配置(凭据都在里面)拆成落盘的那份和保险箱的两段。落盘那份不带凭据键,渠道的地址写空串、不写密钥。
    public static func split(_ config: [String: Any]) -> (file: [String: Any], config: [String: Any], channels: [String: Any]) {
        var file = config
        var secrets: [String: Any] = [:]
        for key in configKeys {
            guard let value = file.removeValue(forKey: key) else { continue }
            if !isBlank(value) { secrets[key] = value }
        }
        var channelSecrets: [String: Any] = [:]
        if let channels = config["notification_channels"] as? [Any] {
            file["notification_channels"] = channels.map { item -> Any in
                guard var ch = item as? [String: Any], let id = ch["id"] as? String else { return item }
                var entry: [String: String] = [:]
                for field in ["url", "secret"] {
                    if let value = ch[field] as? String, !value.isEmpty { entry[field] = value }
                }
                if !entry.isEmpty { channelSecrets[id] = entry }
                ch["url"] = ""
                ch.removeValue(forKey: "secret")
                return ch
            }
        }
        return (file, secrets, channelSecrets)
    }

    /// `after` 比 `before` 少了凭据:某个凭据键由有值变成空,或两边都在的渠道的地址 / 密钥由有值变成空。
    public static func clearsCredential(from before: [String: Any], to after: [String: Any]) -> Bool {
        let old = split(before), new = split(after)
        if old.config.keys.contains(where: { new.config[$0] == nil }) { return true }
        let kept = Set((after["notification_channels"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["id"] as? String })
        for (id, value) in old.channels where kept.contains(id) {
            let was = value as? [String: String] ?? [:]
            let now = new.channels[id] as? [String: String] ?? [:]
            if was.keys.contains(where: { now[$0] == nil }) { return true }
        }
        return false
    }

    /// 文件里还躺着明文凭据(旧版本写的、导入的、手改的)。
    public static func hasPlaintext(_ file: [String: Any]) -> Bool {
        let (_, config, channels) = split(file)
        return !config.isEmpty || !channels.isEmpty
    }

    /// 缺失、空白字符串、空对象都算空。
    static func isBlank(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return true
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let d as [String: Any]: return d.isEmpty
        default: return false
        }
    }

    /// 条目里存的文本:键排序的 JSON 再 base64。base64 只有字母数字和 `+/=`,放进 `security -i` 那一行不用转义。
    public static func encode(_ vault: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(vault) else { throw KeychainCLI.Failure.badArgument }
        return try JSONSerialization.data(withJSONObject: vault, options: [.sortedKeys]).base64EncodedString()
    }

    public static func decode(_ text: String) -> [String: Any]? {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// 经 `/usr/bin/security` 读写钥匙串里的一个通用密码条目。
///
/// 写走 `security -i`,整条命令从标准输入喂进去,值不出现在进程参数里(`ps` 看不到)。`-i` 一行最多约 4096 字节,
/// 超了会把截断的值写进去再报错,所以超长的直接拒绝,写完还回读核对。钥匙串锁着时 `security` 会等用户解锁、
/// 一直不返回,每次调用都限时。
public struct KeychainCLI: Sendable {
    public enum Failure: Error, Equatable {
        case notLaunched
        case timedOut
        case failed(status: Int32)
        /// 整条写入命令超过 `maxCommandBytes`。
        case tooLong
        /// 服务名、账号、钥匙串路径里有 `"` 或换行,或值不是 base64 文本。
        case badArgument
        case readBackMismatch
        /// 读改写时原内容读不出来。
        case unreadable
    }

    /// `security -i` 一行的安全上限(实测 4096 处截断)。
    public static let maxCommandBytes = 4000
    /// `errSecItemNotFound`:没有这个条目。
    static let notFoundStatus: Int32 = 44

    public let service: String
    public let account: String
    /// 为 nil 时用默认搜索列表(登录钥匙串);测试指到临时钥匙串文件。
    public var keychain: String?
    public var executable = "/usr/bin/security"
    public var timeout: TimeInterval = 5

    public init(service: String, account: String, keychain: String? = nil) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    /// 条目的文本;没有这个条目返回 nil。
    public func read() throws -> String? {
        let result = try run(["find-generic-password", "-s", service, "-a", account, "-w"] + keychainArgument)
        if result.status == Self.notFoundStatus { return nil }
        guard result.status == 0 else { throw Failure.failed(status: result.status) }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 写入(有就覆盖)。`value` 只能是 base64 文本。
    public func write(_ value: String) throws {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) })
        else { throw Failure.badArgument }
        var parts = ["add-generic-password", "-U", "-s", try quoted(service), "-a", try quoted(account),
                     "-l", try quoted("Lyrimuse"), "-w", value]
        if let keychain { parts.append(try quoted(keychain)) }
        let line = parts.joined(separator: " ") + "\n"
        guard line.utf8.count <= Self.maxCommandBytes else { throw Failure.tooLong }
        let result = try run(["-i"], input: Data(line.utf8))
        guard result.status == 0 else { throw Failure.failed(status: result.status) }
        guard try read() == value else { throw Failure.readBackMismatch }
    }

    /// 删掉条目;本来就没有也算成功。
    public func delete() throws {
        let result = try run(["delete-generic-password", "-s", service, "-a", account] + keychainArgument)
        guard result.status == 0 || result.status == Self.notFoundStatus else { throw Failure.failed(status: result.status) }
    }

    private var keychainArgument: [String] { keychain.map { [$0] } ?? [] }

    private func quoted(_ s: String) throws -> String {
        guard !s.contains("\""), !s.contains("\n") else { throw Failure.badArgument }
        return "\"\(s)\""
    }

    private func run(_ arguments: [String], input: Data? = nil) throws -> ProcessRunner.Result {
        guard let result = ProcessRunner.run(executable, arguments, timeout: timeout, input: input) else {
            throw Failure.notLaunched
        }
        if result.timedOut { throw Failure.timedOut }
        return result
    }
}

/// App 这一侧的保险箱:整份读改写。只有 App 写这个条目,读到一次之后记在内存里,不再每次起 `security`。
public final class CredentialVaultStore: @unchecked Sendable {
    public static let shared = CredentialVaultStore(
        keychain: KeychainCLI(
            service: CredentialVault.service,
            account: StorageLayout.credentialAccount(dataDir: LyrimusePaths.configDir, roots: LyrimusePaths.storageRoots)),
        previousAccount: StorageLayout.previousCredentialAccount(dataDir: LyrimusePaths.configDir, roots: LyrimusePaths.storageRoots))

    public let keychain: KeychainCLI
    /// 同一服务名下以前用过的账号上的条目:新账号上没有条目时,第一次读把它搬过来(写到新账号、回读核对,再删掉它)。
    public let previous: KeychainCLI?
    private let lock = NSLock()
    private var cached: [String: Any]?

    public init(keychain: KeychainCLI, previousAccount: String? = nil) {
        self.keychain = keychain
        previous = previousAccount.flatMap { account in
            account == keychain.account ? nil : KeychainCLI(service: keychain.service, account: account, keychain: keychain.keychain)
        }
    }

    /// 保险箱内容;没有条目是空字典。读不出来(钥匙串锁着、超时、内容坏了)返回 nil,下次再读。
    public func load() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    /// 读改写。读不出来时抛错、一个字节不写:不知道原来有什么就不覆盖。改完是空的就删掉条目。返回写进去的内容。
    @discardableResult
    public func update(_ mutate: (inout [String: Any]) -> Void) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let contents = loadLocked() else { throw KeychainCLI.Failure.unreadable }
        return try writeLocked(contents, mutate)
    }

    /// 清掉账号凭据(`config`、`channels` 两段),Apple Music 令牌留着。条目读得出、内容解不开时整条删掉:
    /// 坏了的内容谁也用不上,不删的话 `update` 永远写不进去。钥匙串读不出(锁着、超时)时抛错、不碰条目。
    public func clearAccountCredentials() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let contents = loadLocked() else {
            // 读不出照旧抛;读得出才是内容坏了
            _ = try keychain.read()
            try keychain.delete()
            try previous?.delete()
            cached = [:]
            return
        }
        try writeLocked(contents) {
            $0[CredentialVault.configSection] = nil
            $0[CredentialVault.channelsSection] = nil
        }
    }

    @discardableResult
    private func writeLocked(_ loaded: [String: Any], _ mutate: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var contents = loaded
        mutate(&contents)
        contents = contents.filter { !CredentialVault.isBlank($0.value) }
        // 内容没变就不碰钥匙串:账号页每次自动保存都会走到这里(改的多半是非凭据字段),一次写入是两趟
        // `security` 子进程(写 + 回读核对),调用方常在主线程上。
        if NSDictionary(dictionary: contents).isEqual(to: loaded.filter { !CredentialVault.isBlank($0.value) }) {
            cached = contents
            return contents
        }
        if contents.isEmpty {
            try keychain.delete()
        } else {
            try keychain.write(try CredentialVault.encode(contents))
        }
        // 旧账号上残留的(搬的时候没删掉)不能留:新账号清空后下次读会把它当成没搬过的再搬回来。
        try? previous?.delete()
        cached = contents
        return contents
    }

    private func loadLocked() -> [String: Any]? {
        if let cached { return cached }
        let text: String?
        do { text = try keychain.read() } catch { return nil }
        guard let text else { return adoptPreviousLocked() }
        guard let contents = CredentialVault.decode(text) else { return nil }
        cached = contents
        return contents
    }

    /// 新账号上没有条目:旧账号上有就搬过来。旧条目读不出(锁着、超时)返回 nil,跟新条目读不出一样不让人覆盖;
    /// 旧条目内容坏了当没有。写新账号失败时照样用旧条目的内容、旧条目留着,下次读再搬。
    private func adoptPreviousLocked() -> [String: Any]? {
        let text: String?
        do { text = try previous?.read() } catch { return nil }
        guard let text, let contents = CredentialVault.decode(text) else {
            cached = [:]
            return [:]
        }
        if (try? keychain.write(text)) != nil {
            try? previous?.delete()
        }
        cached = contents
        return contents
    }
}
