import CryptoKit
import Foundation

/// Apple Music 用户令牌文件(`lyrimuse-applemusic-token.json`):App 的登录窗口写、连接卡片读,引擎只读
/// (`applemusicUserTokenFile`,applemusic.go)。引擎对这份令牌的观察(问到的店面、被 Apple 拒过)记在它自己的
/// `lyrimuse-applemusic-status.json`,按令牌指纹认,`parse` 把两份合起来。字段两边同步改。
public enum AppleMusicTokenFile {
    /// Apple 的硬上限:令牌 6 个月,没有续期接口。cookie 没带过期时刻时按保存时间推算。
    public static let tokenLifetime: TimeInterval = 180 * 24 * 3600
    /// 引擎的观察记在这份文件里(applemusic.go `applemusicStatusPath`)。
    public static let engineStatusFileName = "lyrimuse-applemusic-status.json"

    /// 令牌 SHA-256 的前 8 字节,16 位小写十六进制;只用来认「是不是同一份令牌」。跟引擎
    /// `applemusicTokenFingerprint` 逐字一致(两侧单测钉同一个值)。
    public static func fingerprint(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public struct Info: Equatable, Sendable {
        public let savedAt: Date
        /// 可能是空串:登录时没等到 itua cookie,引擎首次取词时问 Apple 补上。
        public let storefront: String
        public let expiresAt: Date
        /// 引擎带着这份令牌被 Apple 拒过(401/403):过期或被吊销,要重连。
        public let rejected: Bool

        public init(savedAt: Date, storefront: String, expiresAt: Date, rejected: Bool) {
            self.savedAt = savedAt
            self.storefront = storefront
            self.expiresAt = expiresAt
            self.rejected = rejected
        }
    }

    /// 没有令牌 / 读不出返回 nil。`fileDate` 是文件修改时间:老格式没有 `saved_at` 时拿它兜底,
    /// 不能按「现在」算 —— 那样每次读都重新起算,永远不会提示续期。`engineStatus` 是引擎那份状态文件,
    /// 指纹对得上才算:令牌文件没记店面时用它问到的店面;被拒时刻不早于这次保存,就是失效。
    public static func parse(_ data: Data, fileDate: Date, engineStatus: Data? = nil) -> Info? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["media_user_token"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let savedAtField = seconds(obj["saved_at"])
        let saved = savedAtField.map(Date.init(timeIntervalSince1970:)) ?? fileDate
        let expires = seconds(obj["expires_at"]).map(Date.init(timeIntervalSince1970:))
            ?? saved.addingTimeInterval(tokenLifetime)
        let rejectedAt = seconds(obj["rejected_at"])
        // 令牌文件自己带的 rejected_at(老文件里会有)照旧认。没有 saved_at 的老文件拿文件时间兜底,而写进 rejected_at
        // 那一下把文件时间推到了它之后,比不出先后:有 rejected_at 就算被拒(重新登录会写新格式)。
        var rejected = rejectedAt.map { at in savedAtField == nil || at >= saved.timeIntervalSince1970 } ?? false
        var storefront = (obj["storefront"] as? String) ?? ""
        if let status = engineStatus.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
           status["token_fp"] as? String == fingerprint(token) {
            if storefront.trimmingCharacters(in: .whitespaces).isEmpty, let noted = status["storefront"] as? String {
                storefront = noted
            }
            if let at = seconds(status["rejected_at"]), at >= saved.timeIntervalSince1970 {
                rejected = true
            }
        }
        return Info(savedAt: saved,
                    storefront: storefront,
                    expiresAt: expires,
                    rejected: rejected)
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
