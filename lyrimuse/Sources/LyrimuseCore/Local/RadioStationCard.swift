import Foundation
import os

/// 电台的「台名 + 台标」(2026-09-11,用户:「口白期间,可以恢复到原本电台的封面以及名字」)。
///
/// # 系统在口白期间什么都不给
///
/// 2026-09-11 抓了一整段口白(01:06:41 歌放完 → 01:07:42 下一首,共 61 秒):事件流里**一条都没有**,
/// 曲名/歌手/封面字节(sha1 `b5a9481f`)全程不动。也就是说口白期间没有任何"这是电台"的新信息可取 ——
/// 界面上留着的就是上一首歌的卡片。`radioStationHash` 是个不透明串,AppleScript 那边
/// `current stream title` / `current playlist` 全是 missing value,Apple 目录也查不到电台。
///
/// # 唯一的来源:开台那一刻
///
/// 电台刚起播时会先推一张**台卡**:`artist` 为空、`title` 就是台名,持续几十秒(实测开台到第一首歌
/// 之间 33.4 秒)。三次实测:
///
/// | 时刻 | artist | title |
/// |---|---|---|
/// | 2026-09-10 23:18:15 | 空 | `NCT 127` |
/// | 2026-09-10 早先 | 空 | `YEONJUN` |
/// | 2026-09-11 00:26:50 | 空 | `petal radio` |
///
/// ⚠️ 2026-09-11 订正:这张表原先把两列写反了(记成 title 空、artist 是台名)。判据是
/// `anchorKey` = `歌手|歌名|elapsed|时间戳`,日志里的 `|NCT 127|0.000|…` 第一段空 = **没有歌手**;
/// 歌词缓存里那 6 条 `|petal radio|`(key 是 `歌手|歌名|专辑`)同样坐实第一段是空的。
/// 判据仍取"**两者之一为空**"(真歌不可能缺其中任何一个),所以代码本身两种形态都认、不受这次订正影响。
///
/// 这张卡按 `radioStationHash` 记下来,口白期间拿它替换界面上的曲名与封面。抓不到就退回原样
/// (还显示上一首)—— 宁可保持现状,也不要编一个台名出来。
public struct RadioStationCard: Codable, Equatable, Sendable {
    /// 这张卡属于哪个台。换台就作废 —— 上一个台的名字扣在新台头上比不显示更糟。
    public var stationHash: String
    public var name: String
    /// 台标原始字节(媒体控制给的就是 JPEG/PNG 字节)。可能为空:台卡那一拍不一定带图,
    /// 封面往往在几百毫秒后单独发一次(2026-09-10 实测 artworkData 是独立一行)。
    public var artwork: Data?

    enum CodingKeys: String, CodingKey {
        case stationHash = "station_hash"
        case name
        case artwork
    }

    public init(stationHash: String, name: String, artwork: Data?) {
        self.stationHash = stationHash
        self.name = name
        self.artwork = artwork
    }
}

public enum RadioStationCardFile {
    public static let fileName = "lyrimuse-radio-station.json"
    public static var url: URL { LyrimusePaths.configFile(fileName) }
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "radio-clock")

    /// 台名再长也是一行字;超过这个长度基本可以断定认错了(比如把一整段口播文案当台名)。
    public static let maxNameLength = 80

    /// 这一份快照是不是"台卡"。纯函数,selftest 直接覆盖。
    ///
    /// 判据:电台 + 台标哈希非空 + 曲名/歌手**恰好一个**为空。两个都在 = 真歌;两个都空 = 加载中的
    /// 空载荷(实测开台头几百毫秒有这种),都不是台卡。
    public static func stationName(isRadio: Bool, stationHash: String?, title: String?, artist: String?) -> String? {
        guard isRadio, let stationHash, !stationHash.isEmpty else { return nil }
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let a = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.isEmpty != a.isEmpty else { return nil }
        let name = t.isEmpty ? a : t
        guard name.count <= maxNameLength else { return nil }
        return name
    }

    /// 这张卡能不能用在当前这个台上。纯函数,selftest 直接覆盖。
    public static func card(_ card: RadioStationCard?, forStation hash: String?) -> RadioStationCard? {
        guard let card, let hash, !hash.isEmpty, card.stationHash == hash else { return nil }
        return card
    }

    public static func encode(_ card: RadioStationCard) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(card)
    }

    public static func load() -> RadioStationCard? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RadioStationCard.self, from: data)
    }

    /// 原子写。只在"台卡内容真的变了"时调用(见 LocalPlaybackSource.noteRadioStationCard)——
    /// 台标字节有一百多 KB,不能每拍刷盘。
    public static func write(_ card: RadioStationCard) {
        do {
            try encode(card).write(to: url, options: .atomic)
        } catch {
            logger.notice("radio station card write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
