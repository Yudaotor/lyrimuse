import Foundation

/// 设置页「歌词 › 语言 › 文字」卡顶上那几句示例:日 / 韩 / 中三句样句,按此刻的读音语言、日语读音样式、繁简设置
/// 现算。读音走播放时同一套函数(`Romanizer.lineReading` / `Romanizer.kanaReading`),繁简走 `ChineseVariant.converted`。
/// 客户端没有粤拼(粤拼由引擎生成),所以没有粤语那一句。
public enum LyricsReadingSample {
    public struct Line: Equatable, Sendable {
        public let original: String
        /// nil = 这种语言没勾,不标读音。
        public let reading: String?

        public init(original: String, reading: String?) {
            self.original = original
            self.reading = reading
        }
    }

    public static let japanese = "君の名前を呼ぶ"
    public static let korean = "사랑해요"
    public static let chinese = "后来的我们"

    public static func lines(scripts: RomanizationScripts, japaneseReading: JapaneseReadingStyle,
                             chineseVariant: ChineseVariant) -> [Line] {
        let jaReading: String? = {
            guard scripts.contains(.japanese) else { return nil }
            let segments = Romanizer.japaneseSegments(japanese)
            if japaneseReading == .kana { return Romanizer.kanaReading(japanese, segments: segments) }
            return Romanizer.lineReading(japanese, songLooksJapanese: true, songScript: .japanese, segments: segments)
        }()
        let koReading = scripts.contains(.korean)
            ? Romanizer.lineReading(korean, songLooksJapanese: false, songScript: .korean, segments: []) : nil
        let zh = chineseVariant.converted(chinese)
        let zhReading = scripts.contains(.chinese)
            ? Romanizer.lineReading(zh, songLooksJapanese: false, songScript: .chinese, segments: []) : nil
        return [Line(original: japanese, reading: jaReading), Line(original: korean, reading: koReading),
                Line(original: zh, reading: zhReading)]
    }
}
