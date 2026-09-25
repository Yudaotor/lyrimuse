import Foundation

/// collector `toSimplifiedT2S`(t2s.go)的 Swift 移植:OpenCC 词组表最长匹配,词组没命中查单字表,
/// 单字表也没有再查异体字表(HanVariants),都没有原样保留。
///
/// 只给「两侧必须算出同一个结果」的匹配用(`EnrichCacheKeys.looseKey`)。界面显示的简繁转换仍走
/// ICU(`ChineseVariant`),两者不要混用:ICU 按上下文取舍,跟 collector 的结果对不上。
///
/// 两侧必须同步改的约束:
///   - 按 Unicode 标量(Go 的 rune)走,词组表的 key 用 `[Unicode.Scalar]` 比较,不用 `String`:
///     Swift 的 `String ==` 按规范等价比较(CJK 兼容表意字符与统一汉字判成相等),Go 按字节;
///   - 词组从最长往下试到 2 个字,先词组后单字、单字表没有才查异体字表;
///   - 表由 scripts/gen-opencc-t2s.py 从 collector 那两份 .txt 生成,每个 key 只取第一候选。
public enum OpenCCT2S {
    private struct Tables {
        let characters: [Unicode.Scalar: [Unicode.Scalar]]
        let phrases: [[Unicode.Scalar]: [Unicode.Scalar]]
        let phraseStarts: Set<Unicode.Scalar>
        let maxPhraseLen: Int
        /// 异体字表按标量取 key,理由同词组表(`HanVariants.toSimplified` 的 key 是 Character)。
        let variants: [Unicode.Scalar: [Unicode.Scalar]]
    }

    private static let tables: Tables = {
        func parse(_ text: String) -> [([Unicode.Scalar], [Unicode.Scalar])] {
            text.unicodeScalars.split(separator: "\n").compactMap { line in
                guard let tab = line.firstIndex(of: "\t") else { return nil }
                return (Array(line[line.startIndex..<tab]), Array(line[line.index(after: tab)...]))
            }
        }
        var characters: [Unicode.Scalar: [Unicode.Scalar]] = [:]
        for (k, v) in parse(OpenCCT2STable.characters) where k.count == 1 {
            characters[k[0]] = v
        }
        var phrases: [[Unicode.Scalar]: [Unicode.Scalar]] = [:]
        var starts = Set<Unicode.Scalar>()
        var maxLen = 0
        for (k, v) in parse(OpenCCT2STable.phrases) where !k.isEmpty {
            phrases[k] = v
            starts.insert(k[0])
            maxLen = max(maxLen, k.count)
        }
        var variants: [Unicode.Scalar: [Unicode.Scalar]] = [:]
        for (k, v) in HanVariants.toSimplified {
            let ks = Array(k.unicodeScalars)
            if ks.count == 1 { variants[ks[0]] = Array(v.unicodeScalars) }
        }
        return Tables(characters: characters, phrases: phrases, phraseStarts: starts, maxPhraseLen: maxLen,
                      variants: variants)
    }()

    /// 单字表条目(selftest 对账用)。
    public static var characterEntries: [Unicode.Scalar: [Unicode.Scalar]] { tables.characters }
    /// 词组表条目(selftest 对账用)。
    public static var phraseEntries: [[Unicode.Scalar]: [Unicode.Scalar]] { tables.phrases }

    public static func toSimplified(_ s: String) -> String {
        let t = tables
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if t.phraseStarts.contains(scalars[i]) {
                var l = min(t.maxPhraseLen, scalars.count - i)
                var matched = false
                while l >= 2 {
                    if let repl = t.phrases[Array(scalars[i..<(i + l)])] {
                        out.append(contentsOf: repl)
                        i += l
                        matched = true
                        break
                    }
                    l -= 1
                }
                if matched { continue }
            }
            let u = scalars[i]
            if let repl = t.characters[u] {
                out.append(contentsOf: repl)
            } else if let std = t.variants[u] {
                out.append(contentsOf: std)
            } else {
                out.append(u)
            }
            i += 1
        }
        return String(out)
    }
}
