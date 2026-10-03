import Foundation

/// 完整歌词窗口末尾那行「创作者：…」的名单。
///
/// collector 存的 Apple 名单(`EnrichCacheLyrics.songwriters`,取自 Apple TTML 的 `<songwriters>`)优先,
/// 跟 Music.app 显示的一致;没有时用歌词正文里被判成署名、标签是作词 / 作曲的那几行(`names(fromCreditLines:)`)。
public enum LyricSongwriters {
    /// 显示用的名单。
    public static func shown(apple: [String], credits: [String]) -> [String] {
        apple.isEmpty ? credits : apple
    }

    /// 从署名行里取作词 / 作曲者:按行序、行内按出现顺序,重名(不分大小写、不计空白)只留第一次。
    ///
    /// 传进来的必须是署名过滤已经判掉的行(`LyricsSyncEngine.creditLineDropDecisions`):这里只看标签,
    /// 「他：我不走」这种对白也长着「标签 + 冒号」的形状。认两种形状:「作词：甲/乙」(冒号半角全角都行,
    /// 标签可以带英文对照,如「词 Lyrics by：」),以及不带冒号的「Written by 甲 and 乙」。
    /// 编曲、制作、发行这些标签不算;同一行里接着写的下一个标签(「作词：甲 作曲：乙」)按另一行算。
    public static func names(fromCreditLines lines: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for line in lines {
            for name in namesInLine(line) {
                let key = String(name.lowercased().filter { !$0.isWhitespace })
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                out.append(name)
            }
        }
        return out
    }

    static func namesInLine(_ line: String) -> [String] {
        let text = line.trimmingCharacters(in: .whitespaces)
        if let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            let label = String(text[..<colon])
            var value = String(text[text.index(after: colon)...])
            var rest: String?
            if let next = nextLabelStart(in: value) {
                rest = String(value[next...])
                value = String(value[..<next])
            }
            let own = isSongwriterLabel(label) ? splitNames(value) : []
            return own + (rest.map(namesInLine) ?? [])
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = byPattern.firstMatch(in: text, range: range),
              let labelRange = Range(m.range(at: 1), in: text),
              let valueRange = Range(m.range(at: 2), in: text),
              isSongwriterLabel(String(text[labelRange]))
        else { return [] }
        return splitNames(String(text[valueRange]))
    }

    /// 不带冒号的「<角色> by <名单>」。
    private static let byPattern = try! NSRegularExpression(
        pattern: #"^(.{1,40}?)\s+by\s+(\S.*)$"#, options: [.caseInsensitive])

    /// 值里接着写的下一个「标签：」从哪儿开始(标签最多两段,如「曲 Composer：」),没有返回 nil。
    private static let nextLabelPattern = try! NSRegularExpression(
        pattern: #"\s+(?=(?:[^\s:：]{1,12}\s+)?[^\s:：]{1,12}\s*[:：])"#)

    private static func nextLabelStart(in value: String) -> String.Index? {
        let range = NSRange(value.startIndex..., in: value)
        guard let m = nextLabelPattern.firstMatch(in: value, range: range),
              let r = Range(m.range, in: value) else { return nil }
        return r.upperBound
    }

    /// 汉字标签(去掉分隔符和「中文 / 粤语」这类语种前缀之后)。
    private static let hanLabels: Set<String> = [
        "作词", "作詞", "词", "詞", "填词", "填詞", "词作", "詞作", "作词人", "作詞人",
        "作曲", "曲", "曲作", "谱曲", "譜曲", "作曲人", "作曲者",
        "词曲", "詞曲", "曲词", "曲詞", "作词作曲", "作詞作曲", "作曲作词", "作曲作詞", "词曲作者", "詞曲作者",
    ]

    private static let hanLanguagePrefixes = ["所有", "全部", "中文", "英文", "韩文", "韓文", "日文", "粤语", "粵語",
                                              "国语", "國語", "台语", "台語", "中", "英", "韩", "韓", "日"]

    /// 拉丁标签按词判:去掉 by / and / original 之后剩下的词都得在这张表里(「Music Producer」「Composition
    /// published by」「Music Arranged by」因此不算)。不收「song」:「Song：晴天」是歌名行。
    private static let latinRoleWords: Set<String> = [
        "lyrics", "lyric", "lyricist", "lyricists", "words",
        "composer", "composers", "composed", "compose", "composition", "music",
        "written", "writer", "writers", "songwriter", "songwriters", "songwriting",
    ]

    static func isSongwriterLabel(_ label: String) -> Bool {
        var s = label.trimmingCharacters(in: .whitespaces)
        // 「Rap词」「RAP词」
        if s.lowercased().hasPrefix("rap"), s.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
            s = String(s.dropFirst(3))
        }
        let han = String(s.filter { ch in
            ch.unicodeScalars.allSatisfy { $0.properties.isIdeographic } && !"和与與及".contains(ch)
        })
        if !han.isEmpty {
            if hanLabels.contains(han) { return true }
            for prefix in hanLanguagePrefixes where han.hasPrefix(prefix) {
                if hanLabels.contains(String(han.dropFirst(prefix.count))) { return true }
            }
            return false
        }
        let words = s.lowercased()
            .replacingOccurrences(of: "&", with: " ").replacingOccurrences(of: "＆", with: " ")
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0 != "by" && $0 != "and" && $0 != "original" }
        return !words.isEmpty && words.allSatisfy(latinRoleWords.contains)
    }

    /// 名单按 `/`、`|`、`、`、`+`、逗号、分号,以及两边带空格的 `&` / `and` 拆开;括号里的不拆(「X (Los Angeles, CA)」)。
    /// 「, Jr.」这类后缀接回前一个名字,「名字@厂牌」只留名字,末尾的「…」「...」去掉。
    static func splitNames(_ value: String) -> [String] {
        var s = value.trimmingCharacters(in: .whitespaces)
        for joiner in [" & ", " ＆ ", " and ", " And ", " AND "] {
            s = s.replacingOccurrences(of: joiner, with: "/")
        }
        var parts: [String] = []
        var current = ""
        var depth = 0
        for ch in s {
            if "([（【".contains(ch) {
                depth += 1
            } else if ")]）】".contains(ch) {
                depth = max(0, depth - 1)
            } else if depth == 0, nameSeparators.contains(ch) {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current)
        var out: [String] = []
        for part in parts {
            // 名单里夹着的「标签：名字」(「方大同/Rap：Ghost Style」)按一行重新认。
            if part.contains(where: { $0 == ":" || $0 == "：" }) {
                out += namesInLine(part)
                continue
            }
            var name = part
            if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
            name = name.trimmingCharacters(in: .whitespaces)
            while name.hasSuffix("…") || name.hasSuffix("...") {
                name = String(name.dropLast(name.hasSuffix("…") ? 1 : 3)).trimmingCharacters(in: .whitespaces)
            }
            if name.hasSuffix("."), let last = name.split(separator: " ").last, last.count > 3 {
                name.removeLast()
            }
            guard !name.isEmpty, name.count <= 64,
                  name.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if let prev = out.last, isNameSuffix(name) {
                out[out.count - 1] = prev + ", " + name
                continue
            }
            out.append(name)
        }
        return out
    }

    private static let nameSeparators: Set<Character> = ["/", "／", "|", "｜", "、", ",", "，", ";", "；", "+", "＋"]

    private static func isNameSuffix(_ s: String) -> Bool {
        ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"].contains(s.lowercased())
    }
}
