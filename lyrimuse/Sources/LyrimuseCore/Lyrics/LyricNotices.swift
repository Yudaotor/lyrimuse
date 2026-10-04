import Foundation

/// 歌词源塞进歌词里的声明行(版权 / 授权 / 译文版权 / 来源说明)。规则本体在 shared/lyric-notices.json,
/// 由 scripts/gen-lyric-notices.py 生成 `LyricNotices+Generated.swift`,引擎读同一份
/// (lyricnotices_generated.go)。改规则改那份 JSON,别在这里或 Go 那边单独加。
///
/// 两个作用面:`body` 是 App 显示正文时的署名过滤(`LyricsSyncEngine.strippingCreditLines` 调 `matchesBody`),
/// `translation` 是引擎清洗译文轨(Go 侧 isTranslationNotice)。这里两面都编译,selftest 与 go test
/// 跑同一批例句。
public enum LyricNotices {
    struct Rule {
        let id: String
        let pattern: String
        let ignoreCase: Bool
        let translation: Bool
        let body: Bool
    }

    private struct Compiled {
        let rule: Rule
        let regex: NSRegularExpression
    }

    /// 编不过的规则跳过、不崩:一条坏规则不该让 App 起不来。selftest 要求 `compiledCount == ruleCount`。
    private static let compiled: [Compiled] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern, options: rule.ignoreCase ? [.caseInsensitive] : []))
            .map { Compiled(rule: rule, regex: $0) }
    }

    public static var ruleCount: Int { rules.count }
    public static var compiledCount: Int { compiled.count }

    /// 正文里这一行是不是源塞进来的声明。
    public static func matchesBody(_ text: String) -> Bool {
        matches(text) { $0.body }
    }

    /// 译文里这一行是不是源塞进来的声明(引擎侧 isTranslationNotice 的同一面)。
    public static func matchesTranslation(_ text: String) -> Bool {
        matches(text) { $0.translation }
    }

    /// 单条规则命不命中;没有这条规则是 nil。例句测试用。
    public static func matches(_ text: String, rule id: String) -> Bool? {
        guard let c = compiled.first(where: { $0.rule.id == id }) else { return nil }
        return hit(c.regex, trimmed(text))
    }

    /// 命中这一行的规则 id,例句测试报错用。
    public static func matchingRules(_ text: String) -> [String] {
        let t = trimmed(text)
        return compiled.filter { hit($0.regex, t) }.map(\.rule.id)
    }

    /// 比较前去掉首尾空白:有几条规则锚在整行上。
    private static func matches(_ text: String, where scope: (Rule) -> Bool) -> Bool {
        let t = trimmed(text)
        return compiled.contains { scope($0.rule) && hit($0.regex, t) }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hit(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
