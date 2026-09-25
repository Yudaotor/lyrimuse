import CryptoKit
import Foundation

/// Last.fm 写接口的 `api_sig`:参数(不含 `format` / `callback`)按键名的字节序排序,拼成
/// key+value,末尾接 shared secret,取 MD5 十六进制。
///
/// 跟 collector `lastfm.go` 的 `sign()` 必须逐字节一致(那边用 `sort.Strings`,即 UTF-8 字节序,
/// 这里同样按字节比较,不用 `String` 的 `<`)。两边的单测断言同一组向量,改一处必须同步改另一处。
public enum LastfmSignature {
    public static func sign(_ params: [String: String], secret: String) -> String {
        let sorted = params.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        var s = ""
        for (k, v) in sorted {
            s += k + v
        }
        s += secret
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
