import CryptoKit
import Foundation

/// 一份主歌词正文的指纹:按播放器存的那份(`PlayerLyricsVersion`)记着比对时的主歌词指纹,对得上才换用。
public enum LyricsBodyFingerprint {
    /// 去掉开头 BOM 的 lyrics + "\u{1}" + 去掉开头 BOM 的 yrc 的 SHA256,取前 12 位十六进制。必须跟引擎的
    /// `lyricsBodyFingerprint`(playerlyrics.go)逐字节同一算法(两边各有一条同输入同输出的测试)。
    public static func of(lyrics: String, lyricsYRC: String) -> String {
        let combined = strippingLeadingBOM(lyrics) + "\u{1}" + strippingLeadingBOM(lyricsYRC)
        let digest = SHA256.hash(data: Data(combined.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    private static func strippingLeadingBOM(_ s: String) -> String {
        guard s.unicodeScalars.first == "\u{FEFF}" else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.drop(while: { $0 == "\u{FEFF}" })))
    }
}
