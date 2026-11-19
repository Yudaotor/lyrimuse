import Foundation

/// Last.fm 错误归类:「key 被拒」(Last.fm 只接受订阅了 Last.fm Pro 的账号持有的 API key,重新连接没用)和
/// 「授权失效」(重新连接就好)分开,两者给用户的出路不同。
/// 判据跟引擎 lyrimuse-engine/lastfmkey.go 的 `classifyLastfmError` 逐条一致,改一边必须同步改另一边
/// (引擎侧 `TestLastfmErrorClassMatchesSwift` 比对 `knownCodes` 和 `proMessagePattern` 两处字面量)。见 12 章决策 100。
public enum LastfmErrorClass: Equatable, Sendable {
    case keyRejected
    case sessionInvalid
    case other
}

public enum LastfmErrorClassifier {
    /// Last.fm 官方错误表(https://www.last.fm/api/errorcodes)列出的码,1 和 19 写着不存在、表里没有 28。
    /// 403 带着这之外的码(或者干脆没有码)算「认不出的 403」。14(token 还没授权)实测就配 403,漏了会被报成要 Pro(12 章决策 100)。
    public static let knownCodes: Set<Int> = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 21, 22, 23, 24, 25, 26, 27, 29]
    /// message 里提到 Pro 或订阅就算 key 被拒,不管带的是哪个码。
    public static let proMessagePattern = #"(?i)\bpro\b|subscri"#

    /// 顺序:message 提到 Pro → 10 / 26 → 4 / 9 → 认不出的 403。`code` 为 0 表示应答里没有 error 码。
    public static func classify(httpStatus: Int, code: Int, message: String) -> LastfmErrorClass {
        if message.range(of: proMessagePattern, options: .regularExpression) != nil { return .keyRejected }
        switch code {
        case 10, 26: return .keyRejected
        case 4, 9: return .sessionInvalid
        default: break
        }
        if httpStatus == 403, !knownCodes.contains(code) { return .keyRejected }
        return .other
    }

    /// 引擎状态文件(lyrimuse-lastfm-status.json)说的是不是 key 被拒:有 `reason` 就按它(`key_rejected`);
    /// 旧版引擎写的文件没有 `reason`,按里面的 error 码和 HTTP 状态归类。
    public static func statusFileKeyRejected(reason: String?, error: Int, status: Int?, message: String) -> Bool {
        if let reason { return reason == "key_rejected" }
        return classify(httpStatus: status ?? 0, code: error, message: message) == .keyRejected
    }

    /// 从应答体里取 error 码和 message 再归类。应答体不是 JSON 时按没有码处理,只看 HTTP 状态。
    public static func classify(httpStatus: Int, body: Data) -> (LastfmErrorClass, code: Int, message: String) {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = obj?["error"] as? Int ?? 0
        let message = obj?["message"] as? String ?? ""
        return (classify(httpStatus: httpStatus, code: code, message: message), code, message)
    }
}
