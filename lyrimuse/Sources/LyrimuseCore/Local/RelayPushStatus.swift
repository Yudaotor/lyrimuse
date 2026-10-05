import Foundation

/// 引擎落盘的网页推送健康度(`lyrimuse-relay-status.json`,引擎 relaystatus.go 写):只在推不出去时存在,推成功一次、
/// 引擎启动、中继地址或令牌改了都会删。形状两边一起改,样例在 shared/testdata/relay-status/,两边测试各读一遍。
public enum RelayPushStatus {
    public static let fileName = "lyrimuse-relay-status.json"
    /// 只认这个版本(引擎 relayStatusSchema),别的版本当作没有状态。
    public static let currentSchema = 1

    public struct Info: Decodable, Equatable, Sendable {
        public let schema: Int
        /// auth / not_found / rejected / server / network,见引擎 relayFailureKind。
        public let kind: String
        /// HTTP 状态码;没拿到响应(network)时没有。
        public let status: Int?
        /// 这一串失败从什么时候开始(unix 秒)。
        public let since: Int64

        public init(schema: Int, kind: String, status: Int?, since: Int64) {
            self.schema = schema
            self.kind = kind
            self.status = status
            self.since = since
        }
    }

    public enum Problem: Equatable, Sendable {
        case token
        case address
        case rejected(Int)
        case server(Int)
        case network
    }

    /// 设置页该怎么报。
    public enum Verdict: Equatable, Sendable {
        case ok
        /// 配置错了(令牌、地址、被拒),一出现就报红:不改配置永远推不出去。
        case misconfigured(Problem)
        /// 中继暂时出错或连不上,持续 `transientGrace` 以上才报橙:一两次超时引擎会自己退避重试。
        case unreachable(Problem)
    }

    public static let transientGrace: TimeInterval = 10 * 60

    public static func parse(_ data: Data) -> Info? {
        guard let info = try? JSONDecoder().decode(Info.self, from: data), info.schema == currentSchema else { return nil }
        return info
    }

    public static func verdict(_ info: Info?, now: Date) -> Verdict {
        guard let info else { return .ok }
        switch info.kind {
        case "auth": return .misconfigured(.token)
        case "not_found": return .misconfigured(.address)
        case "rejected": return .misconfigured(.rejected(info.status ?? 0))
        default:
            let problem: Problem = info.kind == "server" ? .server(info.status ?? 0) : .network
            let failingFor = now.timeIntervalSince1970 - TimeInterval(info.since)
            return failingFor >= transientGrace ? .unreachable(problem) : .ok
        }
    }
}
