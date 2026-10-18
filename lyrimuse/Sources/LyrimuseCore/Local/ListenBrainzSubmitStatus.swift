import Foundation

/// 引擎落盘的 ListenBrainz 令牌被拒状态(`lyrimuse-lb-status.json`,引擎 lbstatus.go 写):只在令牌被拒时存在,
/// 提交成功一次、引擎启动都会删。形状两边一起改,样例在 shared/testdata/lb-status/,两边测试各读一遍。
public enum ListenBrainzSubmitStatus {
    public static let fileName = "lyrimuse-lb-status.json"
    /// 只认这个版本(引擎 lbStatusSchema),别的版本当作没有状态。
    public static let currentSchema = 1

    public struct Info: Decodable, Equatable, Sendable {
        public let schema: Int
        /// 目前只有 auth:令牌被拒(401 / 403)。
        public let kind: String
        public let status: Int
        /// 第一次被拒的时刻(unix 秒)。
        public let since: Int64

        public init(schema: Int, kind: String, status: Int, since: Int64) {
            self.schema = schema
            self.kind = kind
            self.status = status
            self.since = since
        }
    }

    /// 版本不认识、或者不是令牌被拒,都当作没有状态。
    public static func parse(_ data: Data) -> Info? {
        guard let info = try? JSONDecoder().decode(Info.self, from: data),
              info.schema == currentSchema, info.kind == "auth" else { return nil }
        return info
    }
}
