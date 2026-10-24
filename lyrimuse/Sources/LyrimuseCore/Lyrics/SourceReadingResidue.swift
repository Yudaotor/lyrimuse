import Foundation

/// 歌词源自带的读音里没转的原文片段(源的生成器读不出的汉字、简体字,行里夹着的别种文字)换成现算的读音,
/// 其余照源给的。只管显示,存的、导出的照旧是源给的那份。见 10 章决策 54。
public enum SourceReadingResidue {
    /// 源读音里算原文残留的字符:假名、谚文、汉字和 `WorldRomanization` 认得的文字(阿拉伯字母除外,
    /// 本地不现算)。片假名长音「ー」、中点「・」只跟在别的残留字符后面才算,单独出现是源写的长音记号。
    static func isResidue(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (0x3040...0x309F).contains(v) || (0x30A0...0x30FA).contains(v) || (0x30FD...0x30FF).contains(v)
            || (0x31F0...0x31FF).contains(v)
        {
            return true
        }
        if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) {
            return true
        }
        if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0x20000...0x3134F).contains(v)
        {
            return true
        }
        guard v >= 0x0370 else { return false }
        return WorldRomanization.Family.allCases.contains { $0 != .arabic && $0.contains(s) }
    }

    private static func continuesResidue(_ s: Unicode.Scalar) -> Bool {
        isResidue(s) || s.value == 0x30FC || s.value == 0x30FB || s.value == 0x200C || s.value == 0x200D
    }

    public static func containsResidue(_ source: String) -> Bool {
        source.unicodeScalars.contains(where: isResidue)
    }

    /// `reading` 给一段残留的读音,给不出(开关关着、现算不了)返回 nil,那一段照原样留着。
    /// 源那一行有拉丁字母、除残留以外全是 ASCII(不标声调的拼音、不标长音的罗马字)时,补进去的读音也去掉附加符号。
    /// 补进去的读音跟前后的字母、数字之间隔一个空格。只有附加符号的一段(挂在拉丁字母后面的点、元音符号)没有读音,去掉。
    public static func patched(_ source: String, reading: (String) -> String?) -> String {
        let scalars = Array(source.unicodeScalars)
        guard scalars.contains(where: isResidue) else { return source }
        let asciiOnly = scalars.contains { $0.isASCII && $0.properties.isAlphabetic }
            && scalars.allSatisfy { $0.isASCII || continuesResidue($0) || $0.properties.isWhitespace }
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            guard isResidue(scalars[i]) else {
                out.append(scalars[i])
                i += 1
                continue
            }
            var j = i + 1
            while j < scalars.count, continuesResidue(scalars[j]) { j += 1 }
            var run = String.UnicodeScalarView()
            run.append(contentsOf: scalars[i..<j])
            if run.allSatisfy(isMark) {
                i = j
                continue
            }
            let original = String(run)
            if var latin = reading(original)?.trimmingCharacters(in: .whitespaces), !latin.isEmpty,
                !containsResidue(latin)
            {
                if asciiOnly { latin = latin.folding(options: .diacriticInsensitive, locale: nil) }
                if let last = out.last, isWordCharacter(last) { out.append(" ") }
                out.append(contentsOf: latin.unicodeScalars)
                if j < scalars.count, isWordCharacter(scalars[j]) { out.append(" ") }
            } else {
                out.append(contentsOf: run)
            }
            i = j
        }
        return String(out)
    }

    private static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isWordCharacter(_ s: Unicode.Scalar) -> Bool {
        s.properties.isAlphabetic || s.properties.numericType != nil
    }
}
