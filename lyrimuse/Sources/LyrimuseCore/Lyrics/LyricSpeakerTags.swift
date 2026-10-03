import CryptoKit
import Foundation

/// collector 的 `lyrics_speakers`(lyricspeakers.go):Musixmatch 的演唱者标注换算到当前正文上,每一行是谁唱的。
/// 指纹对得上时,把 `v1：` / `v2：` / `合：` 补到对应行开头,交给现成的对唱分栏(`LyricDuet`);正文变了指纹就对不上,
/// 整份不用。标记只补在送进引擎的那份正文上,缓存原文不动。
public struct LyricSpeakerTags: Decodable, Equatable, Sendable {
    /// 这份标注对应的正文指纹,见 `fingerprint(lyrics:lyricsYRC:)`。
    public let forFingerprint: String
    /// 跟 `lyrics` 按原文行号一一对应(切法见 `lines(of:)`),值是 v1…v4、合 或空串。
    public let lrc: [String]
    /// 跟 `lyrics_yrc` 按原文行号一一对应。
    public let yrc: [String]

    enum CodingKeys: String, CodingKey {
        case forFingerprint = "for"
        case lrc, yrc
    }

    public init(forFingerprint: String, lrc: [String], yrc: [String]) {
        self.forFingerprint = forFingerprint
        self.lrc = lrc
        self.yrc = yrc
    }

    /// 形状不对时不抛错、当成一份对不上任何正文的空标注:它跟整条缓存条目一起解码,抛错会让那一条连歌词都读不出来。
    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        forFingerprint = (try? c?.decode(String.self, forKey: .forFingerprint)) ?? ""
        lrc = (try? c?.decodeIfPresent([String].self, forKey: .lrc)) ?? []
        yrc = (try? c?.decodeIfPresent([String].self, forKey: .yrc)) ?? []
    }

    /// 去掉开头 BOM 的 lyrics + "\u{1}" + 去掉开头 BOM 的 yrc 的 SHA256,取前 12 位十六进制。必须跟 collector 的
    /// `lyricSpeakersFingerprint` 逐字节同一算法(两边各有一条同输入同输出的测试)。
    public static func fingerprint(lyrics: String, lyricsYRC: String) -> String {
        let combined = strippingLeadingBOM(lyrics) + "\u{1}" + strippingLeadingBOM(lyricsYRC)
        let digest = SHA256.hash(data: Data(combined.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// 指纹对得上时返回补好标记的两份正文,对不上原样返回。
    public func applied(lyrics: String, lyricsYRC: String) -> (lyrics: String, lyricsYRC: String) {
        guard !forFingerprint.isEmpty, forFingerprint == Self.fingerprint(lyrics: lyrics, lyricsYRC: lyricsYRC) else {
            return (lyrics, lyricsYRC)
        }
        return (Self.tagging(lyrics, with: lrc, yrc: false), Self.tagging(lyricsYRC, with: yrc, yrc: true))
    }

    /// 按原文行补标记。行数跟标注对不上、或一行都不用补时原样返回。LRC 补在行首那几个时间戳之后;YRC 在行头之后
    /// 补一个零时长的词 `(行始,0,0)v1：`,跟 collector 解析 TTML 时写对唱前缀是同一个形状(buildYRCLine)。
    static func tagging(_ text: String, with labels: [String], yrc: Bool) -> String {
        let lines = Self.lines(of: text)
        guard lines.count == labels.count, labels.contains(where: { !$0.isEmpty }) else { return text }
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for (line, label) in zip(lines, labels) {
            guard !label.isEmpty else {
                out.append(line)
                continue
            }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if yrc {
                guard let m = yrcHead.firstMatch(in: line, range: range) else {
                    out.append(line)
                    continue
                }
                let start = ns.substring(with: m.range(at: 1))
                out.append(ns.substring(to: m.range.upperBound) + "(\(start),0,0)\(label)：" + ns.substring(from: m.range.upperBound))
            } else {
                guard let m = lrcStamps.firstMatch(in: line, range: range) else {
                    out.append(line)
                    continue
                }
                out.append(ns.substring(to: m.range.upperBound) + "\(label)：" + ns.substring(from: m.range.upperBound))
            }
        }
        return out.joined(separator: "\n")
    }

    /// 跟 collector `splitLyricLines` 同一种切法:CRLF、CR 都当换行,空行也算一行。按 Unicode 标量切 ——
    /// Swift 默认把 CRLF 当成一个字素簇,按 Character 切会跟 Go 切出不同的行数。
    public static func lines(of text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if !previousCR {
                    lines.append(String(current))
                    current = String.UnicodeScalarView()
                }
                previousCR = false
            } else if scalar == "\r" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                previousCR = true
            } else {
                current.append(scalar)
                previousCR = false
            }
        }
        lines.append(String(current))
        return lines
    }

    private static func strippingLeadingBOM(_ s: String) -> String {
        guard s.unicodeScalars.first == "\u{FEFF}" else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.drop(while: { $0 == "\u{FEFF}" })))
    }

    /// 行首连续的 LRC 时间戳,跟 collector 的 `lrcTimestampRe` 同一形状。
    private static let lrcStamps = try! NSRegularExpression(pattern: #"^(?:\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\])+"#)
    /// YRC 的行头 `[行始,行长]`,跟 collector 的 `yrcLineTimeRegex` 同一形状。
    private static let yrcHead = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
}
