import Foundation

/// 此刻显示的是哪个播放器自家那份(`LocalPlaybackSource.currentPlayerLyricsShown`)。
public struct PlayerLyricsShown: Equatable, Sendable {
    public let bundleID: String
    public let source: String
    /// 那份相对主歌词的中位偏移(毫秒),正数 = 那份整体晚。
    public let shiftMs: Int

    public init(bundleID: String, source: String, shiftMs: Int) {
        self.bundleID = bundleID
        self.source = source
        self.shiftMs = shiftMs
    }
}

/// 引擎按播放器记的「在它里面放时改用它自家平台那份」(enrichEntry.PlayerLyrics,playerlyrics.go)。同一首歌在不同平台常是
/// 不同母版,时间轴整体差一两秒,主歌词只对得上其中一份音频。每一项绑着引擎比对时主歌词的指纹,主歌词换了就不用。
/// 正文为空的一项是「比对过、对齐了」,不换。见 08 章决策 65。
public struct PlayerLyricsVersion: Decodable, Equatable, Sendable {
    public let mainFingerprint: String
    public let source: String
    public let lyrics: String
    public let lyricsYRC: String
    public let lyricsTr: String
    public let lyricsTrLang: String
    public let lyricsBG: String
    /// 这份相对主歌词的中位偏移(毫秒),正数 = 这份整体晚。
    public let shiftMs: Int

    enum CodingKeys: String, CodingKey {
        case mainFingerprint = "main_fp"
        case source, lyrics
        case lyricsYRC = "yrc"
        case lyricsTr = "tr"
        case lyricsTrLang = "tr_lang"
        case lyricsBG = "bg"
        case shiftMs = "shift_ms"
    }

    public init(mainFingerprint: String, source: String, lyrics: String, lyricsYRC: String = "", lyricsTr: String = "",
                lyricsTrLang: String = "", lyricsBG: String = "", shiftMs: Int = 0) {
        self.mainFingerprint = mainFingerprint
        self.source = source
        self.lyrics = lyrics
        self.lyricsYRC = lyricsYRC
        self.lyricsTr = lyricsTr
        self.lyricsTrLang = lyricsTrLang
        self.lyricsBG = lyricsBG
        self.shiftMs = shiftMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mainFingerprint = try c.decodeIfPresent(String.self, forKey: .mainFingerprint) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics) ?? ""
        lyricsYRC = try c.decodeIfPresent(String.self, forKey: .lyricsYRC) ?? ""
        lyricsTr = try c.decodeIfPresent(String.self, forKey: .lyricsTr) ?? ""
        lyricsTrLang = try c.decodeIfPresent(String.self, forKey: .lyricsTrLang) ?? ""
        lyricsBG = try c.decodeIfPresent(String.self, forKey: .lyricsBG) ?? ""
        shiftMs = try c.decodeIfPresent(Int.self, forKey: .shiftMs) ?? 0
    }

    /// 在 bundleID 这个播放器里放时该换用的那份:有这一项、正文不空、比对时的主歌词就是现在这份(指纹对得上)。纯函数,selftest 覆盖。
    public static func chosen(_ versions: [String: PlayerLyricsVersion], bundleID: String?, lyrics: String,
                              lyricsYRC: String) -> PlayerLyricsVersion? {
        guard let bundleID, let v = versions[bundleID], !v.lyrics.isEmpty,
              v.mainFingerprint == LyricSpeakerTags.fingerprint(lyrics: lyrics, lyricsYRC: lyricsYRC) else { return nil }
        return v
    }
}
