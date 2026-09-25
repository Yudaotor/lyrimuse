import Foundation

/// Apple Music 用户令牌文件(`lyrimuse-applemusic-token.json`)的读取。App 侧的连接卡片读它;collector 侧
/// `applemusicUserTokenFile`(applemusic.go)读写同一个文件,字段两边同步改。
public enum AppleMusicTokenFile {
    /// Apple 的硬上限:令牌 6 个月,没有续期接口。cookie 没带过期时刻时按保存时间推算。
    public static let tokenLifetime: TimeInterval = 180 * 24 * 3600

    public struct Info: Equatable, Sendable {
        public let savedAt: Date
        /// 可能是空串:登录时没等到 itua cookie,collector 首次取词时问 Apple 补上。
        public let storefront: String
        public let expiresAt: Date
        /// collector 带着这份令牌被 Apple 拒过(401/403):过期或被吊销,要重连。
        public let rejected: Bool

        public init(savedAt: Date, storefront: String, expiresAt: Date, rejected: Bool) {
            self.savedAt = savedAt
            self.storefront = storefront
            self.expiresAt = expiresAt
            self.rejected = rejected
        }
    }

    /// 没有令牌 / 读不出返回 nil。`fileDate` 是文件修改时间:老格式没有 `saved_at` 时拿它兜底,
    /// 不能按「现在」算 —— 那样每次读都重新起算,永远不会提示续期。
    public static func parse(_ data: Data, fileDate: Date) -> Info? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["media_user_token"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let saved = seconds(obj["saved_at"]).map(Date.init(timeIntervalSince1970:)) ?? fileDate
        let expires = seconds(obj["expires_at"]).map(Date.init(timeIntervalSince1970:))
            ?? saved.addingTimeInterval(tokenLifetime)
        let rejectedAt = seconds(obj["rejected_at"])
        return Info(savedAt: saved,
                    storefront: (obj["storefront"] as? String) ?? "",
                    expiresAt: expires,
                    rejected: rejectedAt.map { $0 >= saved.timeIntervalSince1970 } ?? false)
    }

    /// 登录窗口落盘的内容。`expiresAt` 是 cookie 自带的过期时刻,没有就不写。
    public static func payload(token: String, storefront: String, savedAt: Date, expiresAt: Date?) -> [String: Any] {
        var out: [String: Any] = [
            "media_user_token": token,
            "storefront": storefront,
            "saved_at": Int(savedAt.timeIntervalSince1970),
        ]
        if let expiresAt { out["expires_at"] = Int(expiresAt.timeIntervalSince1970) }
        return out
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber, number.doubleValue > 0 else { return nil }
        return number.doubleValue
    }
}
