import Foundation

/// 设置页「歌词 › 语言 › 文字」卡顶上那几句示例:日 / 韩 / 中三句样句,按此刻的读音语言、日语读音样式、繁简设置
/// 现算。读音走播放时同一套函数(`Romanizer.lineReading` / `Romanizer.kanaReading`),繁简走 `ChineseVariant.converted`。
/// 客户端没有粤拼(粤拼由引擎生成),所以没有粤语那一句。`groups` 把读音对到字上,分法跟歌词窗口的逐词标注同一个
/// `LyricsSyncEngine.buildWordGroups`(每个字当一个词,同歌词管理预览)。
public enum LyricsReadingSample {
    public struct Line: Equatable, Sendable {
        public let original: String
        /// nil = 这种语言没勾,不标读音。
        public let reading: String?
        /// 读音逐词标在字下面的分组;nil = 没标读音,或读音对不上字(界面退回整句读音写在原文下面)。
        public let groups: [LyricsRubyGroup]?

        public init(original: String, reading: String?, groups: [LyricsRubyGroup]? = nil) {
            self.original = original
            self.reading = reading
            self.groups = groups
        }
    }

    public static let japanese = "君の名前を呼ぶ"
    public static let korean = "사랑해요"
    public static let chinese = "后来的我们"

    public static func lines(scripts: RomanizationScripts, japaneseReading: JapaneseReadingStyle,
                             chineseVariant: ChineseVariant) -> [Line] {
        let jaSegments = scripts.contains(.japanese) ? Romanizer.japaneseSegments(japanese) : []
        let jaReading: String? = {
            guard scripts.contains(.japanese) else { return nil }
            if japaneseReading == .kana { return Romanizer.kanaReading(japanese, segments: jaSegments) }
            return Romanizer.lineReading(japanese, songLooksJapanese: true, songScript: .japanese, segments: jaSegments)
        }()
        let koReading = scripts.contains(.korean)
            ? Romanizer.lineReading(korean, songLooksJapanese: false, songScript: .korean, segments: []) : nil
        let zh = chineseVariant.converted(chinese)
        let zhReading = scripts.contains(.chinese)
            ? Romanizer.lineReading(zh, songLooksJapanese: false, songScript: .chinese, segments: []) : nil
        let jaGroups = jaReading == nil ? nil
            : rubyGroups(japanese) { LyricsSyncEngine.buildWordGroups(words: $0, line: japanese, japanese: true,
                                                                      segments: jaSegments, kana: japaneseReading == .kana) }
        let koGroups = koReading.flatMap { roma in
            rubyGroups(korean) { LyricsSyncEngine.buildWordGroups(words: $0, line: korean, japanese: false,
                                                                  koreanRomanization: roma) }
        }
        let zhGroups = zhReading.flatMap { roma in
            rubyGroups(zh) { LyricsSyncEngine.buildWordGroups(words: $0, line: zh, japanese: false, hanRomanization: roma) }
        }
        return [Line(original: japanese, reading: jaReading, groups: jaGroups),
                Line(original: korean, reading: koReading, groups: koGroups),
                Line(original: zh, reading: zhReading, groups: zhGroups)]
    }

    /// 每个字当一个词(时间只占位)交给 `build`,分好的组拼回原句才用,拼不回、或一组读音都没有时为 nil。
    private static func rubyGroups(_ line: String,
                                   build: ([SyncedLyricWord]) -> [SyncedLyricWordGroup]?) -> [LyricsRubyGroup]? {
        let words = line.enumerated().map { SyncedLyricWord(text: String($1), startMs: $0, durationMs: 1) }
        guard let groups = build(words)?.map({ LyricsRubyGroup(text: $0.words.map(\.text).joined(), romanization: $0.romanization) }),
              groups.map(\.text).joined() == line, groups.contains(where: { $0.romanization != nil })
        else { return nil }
        return groups
    }
}
