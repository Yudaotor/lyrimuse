import Foundation

/// 简介正文的排版收拾,网易云、QQ 音乐几个来源共用。
enum EditorialText {
    /// 一行一段:去掉每行首尾空白和空行,段与段之间空一行(网易云歌手介绍的总述就是一段占一行)。
    static func paragraphs(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// 保留原文的分行:每行去掉首尾空白(含全角空格的段首缩进),连续的空行并成一个,首尾的空行去掉。
    /// 按 `Character.isNewline` 切:`\r\n` 在 Swift 里是一个字符,按它切不会多出一个空行。
    static func lines(_ raw: String) -> String {
        var out: [String] = []
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                out.append(text)
            } else if out.last?.isEmpty == false {
                out.append("")
            }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// 只有中文写的介绍(网易云、QQ 音乐):只在中文界面(简体、繁体)问。
    static func isChineseUI(_ uiLanguage: String) -> Bool {
        uiLanguage.lowercased().hasPrefix("zh")
    }

    /// 这几家的正文是简体:繁体界面(`zh-Hant`)转成繁体,别的界面原样。
    static func localized(_ text: String, uiLanguage: String) -> String {
        uiLanguage.lowercased().hasPrefix("zh-hant") ? ChineseVariantConversion.toTraditional(text) : text
    }
}
