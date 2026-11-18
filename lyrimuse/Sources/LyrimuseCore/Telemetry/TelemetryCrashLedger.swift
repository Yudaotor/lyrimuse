import Foundation

/// 崩溃报告的发送记账:发过哪些(`Telemetry.reportID`)、哪天发了几条、排在最前面的那份连着几次碰上服务器出错。
/// App 的 `TelemetryService` 按 `Keys` 存在 UserDefaults(都是机器专属键),一轮发送走 `send`。见 14 章决策 230。
public struct TelemetryCrashLedger: Equatable, Sendable {
    public struct Keys: Sendable {
        /// 发过的报告,`[String]`,最多留 `Telemetry.sentCrashMemory` 条。
        public let sent: String
        /// `yyyy-MM-dd|条数`:那天发了几条。
        public let sentDay: String
        /// `报告键|次数`:排在最前面的那份连着几次碰上服务器出错。
        public let serverFailures: String

        public init(sent: String, sentDay: String, serverFailures: String) {
            self.sent = sent
            self.sentDay = sentDay
            self.serverFailures = serverFailures
        }
    }

    /// 一份报告发出去之后的结局。
    public enum Outcome: Equatable, Sendable {
        /// 2xx,收下了。
        case accepted
        /// 这一份本身不合格,重发也一样:记为发过,接着发下一份。
        case rejected
        /// 服务器出错:记一次,同一份连着 `maxServerFailures` 次就记为发过、跳过它。
        case serverError
        /// 连不上、限流、网关或基础设施拦下的:停下,下次再发。
        case later
    }

    /// 同一份连着这么多次碰上服务器出错,就跳过它,别让它一直挡着后面的(报告按修改时间从旧到新发,碰上要停的就停)。
    public static let maxServerFailures = 3

    public var sent: [String]
    public var sentDay: String?
    public var sentOnDay: Int
    public var failingID: String?
    public var failures: Int

    public init(sent: [String] = [], sentDay: String? = nil, sentOnDay: Int = 0, failingID: String? = nil, failures: Int = 0) {
        self.sent = sent
        self.sentDay = sentDay
        self.sentOnDay = sentOnDay
        self.failingID = failingID
        self.failures = failures
    }

    /// Worker(`telemetry-worker/src/index.js`)对负载不合格回 400、请求体超过上限回 413,这两个是这一份本身的问题。
    /// 其余 4xx(401 / 403 / 404 / 408 这类)来自网关或基础设施,跟这一份无关,别当成拒收:记为发过就永远不重发了。
    /// 503 是 Worker 按 IP 限流(或平台暂时不可用),也不算这一份的错。Worker 新回别的码时两处一起对。
    public static func outcome(status: Int?) -> Outcome {
        guard let status else { return .later }
        switch status {
        case 200..<300: return .accepted
        case 400, 413: return .rejected
        case 503: return .later
        case 500..<600: return .serverError
        default: return .later
        }
    }

    public func sentCount(on day: String) -> Int { sentDay == day ? sentOnDay : 0 }

    /// 按给的顺序发(调用方按修改时间从旧到新排好),发到当天上限、或碰上要等下次的为止。`post` 返回 HTTP 状态码,
    /// 没发出去为 nil;每份有了结果、记账变了就调一次 `save`。
    public mutating func send<Report>(_ reports: [(id: String, report: Report)], today: String,
                                      isolation: isolated (any Actor)? = #isolation,
                                      post: (Report) async -> Int?, save: (TelemetryCrashLedger) -> Void) async {
        for item in reports {
            guard sentCount(on: today) < Telemetry.maxCrashesPerDay else { return }
            if sent.contains(item.id) { continue }
            switch Self.outcome(status: await post(item.report)) {
            case .accepted:
                markSent(item.id)
                sentOnDay = sentCount(on: today) + 1
                sentDay = today
            case .rejected:
                markSent(item.id)
            case .serverError:
                failures = failingID == item.id ? failures + 1 : 1
                failingID = item.id
                guard failures >= Self.maxServerFailures else {
                    save(self)
                    return
                }
                markSent(item.id)
            case .later:
                return
            }
            save(self)
        }
    }

    private mutating func markSent(_ id: String) {
        sent = Array((sent + [id]).suffix(Telemetry.sentCrashMemory))
        if failingID == id {
            failingID = nil
            failures = 0
        }
    }

    public static func load(from defaults: UserDefaults, keys: Keys) -> TelemetryCrashLedger {
        var ledger = TelemetryCrashLedger(sent: defaults.stringArray(forKey: keys.sent) ?? [])
        if let (day, count) = split(defaults.string(forKey: keys.sentDay)) {
            ledger.sentDay = day
            ledger.sentOnDay = count
        }
        if let (id, count) = split(defaults.string(forKey: keys.serverFailures)) {
            ledger.failingID = id
            ledger.failures = count
        }
        return ledger
    }

    public func save(to defaults: UserDefaults, keys: Keys) {
        defaults.set(sent, forKey: keys.sent)
        if let sentDay { defaults.set("\(sentDay)|\(sentOnDay)", forKey: keys.sentDay) }
        if let failingID {
            defaults.set("\(failingID)|\(failures)", forKey: keys.serverFailures)
        } else {
            defaults.removeObject(forKey: keys.serverFailures)
        }
    }

    /// `前缀|数字`。
    private static func split(_ raw: String?) -> (String, Int)? {
        guard let parts = raw?.split(separator: "|"), parts.count == 2, let count = Int(parts[1]) else { return nil }
        return (String(parts[0]), count)
    }
}
