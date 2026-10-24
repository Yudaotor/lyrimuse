import Foundation

/// 歌词文件夹里逐字歌词写成的格式。值和文件后缀跟引擎 `lyrimuse-engine/lyricswordformat.go` 的 `lyricsWordFormat`
/// 一一对应;features.json 的 `lyrics_word_formats` 存这几个值,第一个是主格式(文件夹里以它为准),其余是另外多存的副本。
/// 缓存里一律是 YRC 语法,只有文件夹里那一份换格式。见 11 章决策 144。
public enum LyricsWordFormat: String, CaseIterable, Sendable {
    case yrc
    case ttml
    case qrc
    case krc
    case enhancedLRC = "enhanced-lrc"

    public var fileSuffix: String {
        switch self {
        case .yrc: ".yrc"
        case .ttml: ".ttml"
        case .qrc: ".qrc"
        case .krc: ".krc"
        case .enhancedLRC: ".enhanced.lrc"
        }
    }

    /// 设置里的名单去掉认不得的、重复的;一个都不剩时只写 YRC。同引擎 `resolveLyricsWordFormats`。
    public static func resolve(_ names: [String]?) -> [LyricsWordFormat] {
        var out: [LyricsWordFormat] = []
        for name in names ?? [] {
            if let f = LyricsWordFormat(rawValue: name), !out.contains(f) { out.append(f) }
        }
        return out.isEmpty ? [.yrc] : out
    }
}
