import Foundation
import zlib

/// 「歌词管理」内存里的**精简条目**:主缓存的一条去掉四块大正文(`lyrics_yrc` / `lyrics_tr` /
/// `lyrics_roma` / `plain_lyrics`),记上校验值和「有哪几块正文」。形状跟 collector 给播放那一侧写的
/// 精简索引(`lyrimuse-enrich-index.json`,见 collector enrichindex.go)逐字段一致,所以索引可以直接当
/// 精简快照用;主歌词 `lyrics` 留着(批量锁定 / 解锁、时间轴偏移的内容指纹都要它)。
///
/// ## 为什么
///
/// 开着「歌词管理」App 常驻约 700 MB:`JSONSerialization` 把整份 107 MB 主缓存解成几十万个
/// NSString / NSDictionary(Malloc Small 538 MB),而列表只用元数据和「有没有逐字 / 译文 / 罗马音 /
/// 纯文本」四个布尔,正文只有点开某一首、或改某一首时才要。
///
/// ## 规矩(改动路径的安全网在 `EnrichCacheStore`)
///
///   - 精简条目靠 `body_crc` 这个键认出来;没有正文(校验值 0)的条目本来就没什么可去,原样留着。
///   - 用到正文前先 `hydrate`:读正文小文件,校验值对得上才补回;对不上就回主缓存取这一条。
///   - 写盘前每一条都 `stripMarkers`;被改过的精简条目先从盘上那条 `restoreBodies`,绝不把缺正文的
///     条目写回主缓存(那等于删掉用户的逐字 / 译文)。
public enum EnrichCacheSlim {
    public static let crcKey = "body_crc"
    public static let fieldsKey = "body_fields"
    public static let bodiesDirectoryName = "lyrimuse-lyrics-bodies"
    /// 精简时去掉的四块正文。
    public static let strippedFields = ["lyrics_yrc", "lyrics_tr", "lyrics_roma", "plain_lyrics"]

    /// `body_fields` 位图,跟 collector `enrichBodyFields` 一致。`known` 恒置位:老版本索引没有这个字段,
    /// 「有校验值却没有位图」就认出是老索引、不拿它当精简快照(它的四个布尔全是假的)。
    public struct Fields: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let yrc = Fields(rawValue: 1)
        public static let tr = Fields(rawValue: 2)
        public static let roma = Fields(rawValue: 4)
        public static let plain = Fields(rawValue: 8)
        public static let known = Fields(rawValue: 128)
    }

    public static func isSlim(_ entry: [String: Any]) -> Bool { entry[crcKey] != nil }

    public static func storedCRC(_ entry: [String: Any]) -> UInt32? {
        (entry[crcKey] as? NSNumber)?.uint32Value
    }

    /// 五个正文字段的校验值,跟 collector `enrichBodyCRC` 逐位一致(字段之间 0x00 隔开、全空为 0、
    /// 算出 0 记成 1)。只对完整条目有意义。
    public static func bodyCRC(_ entry: [String: Any]) -> UInt32 {
        let parts = ["lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc", "plain_lyrics"]
            .map { entry[$0] as? String ?? "" }
        if parts.allSatisfy(\.isEmpty) { return 0 }
        var c = crc32(0, nil, 0)
        var zero: UInt8 = 0
        for part in parts {
            var s = part
            s.withUTF8 { buf in
                if let base = buf.baseAddress { c = crc32(c, base, uInt(buf.count)) }
            }
            c = crc32(c, &zero, 1)
        }
        let v = UInt32(truncatingIfNeeded: c)
        return v == 0 ? 1 : v
    }

    /// 这一条有哪几块正文:精简条目看位图,完整条目看字段本身。
    public static func presentFields(_ entry: [String: Any]) -> Fields {
        if isSlim(entry) { return Fields(rawValue: (entry[fieldsKey] as? NSNumber)?.intValue ?? 0) }
        var f: Fields = []
        func has(_ k: String) -> Bool { !((entry[k] as? String) ?? "").isEmpty }
        if has("lyrics_yrc") { f.insert(.yrc) }
        if has("lyrics_tr") { f.insert(.tr) }
        if has("lyrics_roma") { f.insert(.roma) }
        if has("plain_lyrics") { f.insert(.plain) }
        return f
    }

    /// 精简一条完整条目;没有正文的原样返回。
    public static func slim(_ entry: [String: Any]) -> [String: Any] {
        if isSlim(entry) { return entry }
        let crc = bodyCRC(entry)
        guard crc != 0 else { return entry }
        var out = entry
        out[fieldsKey] = NSNumber(value: presentFields(entry).union(.known).rawValue)
        for k in strippedFields { out.removeValue(forKey: k) }
        out[crcKey] = NSNumber(value: crc)
        return out
    }

    /// 拿正文小文件把精简条目补成完整条目;校验值对不上是 nil(调用方回主缓存取)。补回的是正文小文件里的原样内容。
    ///
    /// 校验值认两种口径:collector 写的(`body.crc`,跟索引那条一致),以及「每块正文去掉开头一个 U+FEFF」之后
    /// 算的 —— `JSONSerialization` 解字符串时会吞掉开头的一个 U+FEFF(JSONDecoder 与 Go 都保留),而酷狗歌词
    /// 常以它开头(本机 8102 条里 1167 条),所以从主缓存解出来再 `slim` 的条目,校验值是后一种。
    public static func hydrate(_ entry: [String: Any], body: EnrichCacheBody) -> [String: Any]? {
        guard isSlim(entry), let crc = storedCRC(entry),
              body.crc == crc || bodyCRC(jsonSerializationView(body)) == crc else { return nil }
        var out = stripMarkers(entry)
        let pairs: [(String, String?)] = [("lyrics_yrc", body.lyricsYRC), ("lyrics_tr", body.lyricsTr),
                                          ("lyrics_roma", body.lyricsRoma), ("plain_lyrics", body.plainLyrics)]
        for (k, v) in pairs {
            if let v, !v.isEmpty { out[k] = v }
        }
        return out
    }

    /// 正文小文件本身自洽:按内容重算的校验值 = 文件里记的。JSONDecoder 解出来的是原样内容(开头的 U+FEFF
    /// 也在),跟 collector 写文件时算的是同一份字节。
    public static func isSelfConsistent(_ body: EnrichCacheBody) -> Bool {
        body.crc != 0 && bodyCRC(["lyrics": body.lyrics ?? "", "lyrics_tr": body.lyricsTr ?? "",
                                  "lyrics_roma": body.lyricsRoma ?? "", "lyrics_yrc": body.lyricsYRC ?? "",
                                  "plain_lyrics": body.plainLyrics ?? ""]) == body.crc
    }

    /// 正文小文件跟精简条目记的校验值对不上、但文件自洽:条目那一版比小文件旧 —— collector 先写小文件、再写
    /// 主缓存,手上这份快照正好是中间那一刻之前的。小文件是新的那份,拿它补,主歌词也换成小文件里的。
    /// 不自洽(没写完 / 坏了)是 nil。
    ///
    /// 主缓存现在也是精简格式(见 collector enrichindex.go),「对不上就回主缓存取完整那条」这条退路已经取不到
    /// 正文了,所以这一步要在它前面。
    public static func adoptNewerBody(_ entry: [String: Any], body: EnrichCacheBody) -> [String: Any]? {
        guard isSlim(entry), isSelfConsistent(body) else { return nil }
        var out = stripMarkers(entry)
        let pairs: [(String, String?)] = [("lyrics", body.lyrics), ("lyrics_yrc", body.lyricsYRC),
                                          ("lyrics_tr", body.lyricsTr), ("lyrics_roma", body.lyricsRoma),
                                          ("plain_lyrics", body.plainLyrics)]
        for (k, v) in pairs {
            if let v, !v.isEmpty { out[k] = v } else { out.removeValue(forKey: k) }
        }
        return out
    }

    /// 精简条目的四块正文从另一份完整条目(盘上 / 主缓存里的那一条)取;其余字段一律以精简条目为准。
    /// 已经是完整条目的原样返回。
    public static func restoreBodies(_ entry: [String: Any], from full: [String: Any]?) -> [String: Any] {
        guard isSlim(entry) else { return entry }
        var out = stripMarkers(entry)
        for k in strippedFields {
            if let v = full?[k] as? String, !v.isEmpty { out[k] = v }
        }
        return out
    }

    /// 正文小文件按 `JSONSerialization` 会解出来的样子(每块去掉开头一个 U+FEFF)摆成条目,只用来算校验值。
    static func jsonSerializationView(_ body: EnrichCacheBody) -> [String: Any] {
        func strip(_ s: String?) -> String {
            guard let s else { return "" }
            return s.unicodeScalars.first == "\u{FEFF}" ? String(s.unicodeScalars.dropFirst()) : s
        }
        return ["lyrics": strip(body.lyrics), "lyrics_tr": strip(body.lyricsTr), "lyrics_roma": strip(body.lyricsRoma),
                "lyrics_yrc": strip(body.lyricsYRC), "plain_lyrics": strip(body.plainLyrics)]
    }

    public static func stripMarkers(_ entry: [String: Any]) -> [String: Any] {
        guard entry[crcKey] != nil || entry[fieldsKey] != nil else { return entry }
        var out = entry
        out.removeValue(forKey: crcKey)
        out.removeValue(forKey: fieldsKey)
        return out
    }

    /// 一整份索引能不能直接当精简快照:每一条有校验值的都带着位图(老版本 collector 写的没有)。
    public static func indexHasFields(_ index: [String: [String: Any]]) -> Bool {
        !index.values.contains { $0[crcKey] != nil && $0[fieldsKey] == nil }
    }
}
