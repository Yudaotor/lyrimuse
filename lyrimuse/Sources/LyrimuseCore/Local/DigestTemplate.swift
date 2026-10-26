import Foundation

/// 听歌报告的自定义内容(推送提醒页「推送内容」):标题、正文各一段模板,四档共用,用 `{占位符}` 取这一期的数。
/// 存在 features.json 的 `digest_template`(`{title, body}`),跟默认一样的那一段存成空串。真推送由引擎渲染(digesttemplate.go),
/// 这里是同一套规则,给编辑器和渠道预览用;两边对得上靠共用样例 shared/testdata/notify/template.json。
/// 用了自定义就按纯文本推,不套各平台的卡片排版。见 15 章决策 84。
public struct DigestTemplate: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String = "", body: String = "") {
        self.title = title
        self.body = body
    }

    public static let defaultTitle = "{title}"
    public static let defaultBody = "{body}"
    /// 每段最多留多少字(同引擎 digestTemplateMaxRunes)。
    public static let maxLength = 4000

    /// 认得的占位符,顺序就是编辑器里那一排的顺序(同引擎 digestPlaceholderNames)。
    public static let placeholders = [
        "title", "body", "summary", "plays", "prev_plays", "prev_label", "change", "duration",
        "top_artists", "top_albums", "top_tracks", "top_artist", "top_album", "top_track",
        "new_artists", "new_artist_names", "source", "from", "to", "link",
    ]

    /// 跟默认一样的那一段存成空;超长截断(同引擎 resolveDigestTemplate)。
    public static func resolved(title: String?, body: String?) -> DigestTemplate {
        func clean(_ raw: String?, _ fallback: String) -> String {
            let s = (raw ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            if s.trimmingCharacters(in: .whitespacesAndNewlines) == fallback { return "" }
            return s.count > maxLength ? String(s.prefix(maxLength)) : s
        }
        return DigestTemplate(title: clean(title, defaultTitle), body: clean(body, defaultBody))
    }

    /// 有没有自定义(标题、正文任一段)。
    public var isCustom: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 编辑器里显示的那一段:没自定义时显示默认的 `{title}` / `{body}`。
    public var editableTitle: String { title.isEmpty ? Self.defaultTitle : title }
    public var editableBody: String { body.isEmpty ? Self.defaultBody : body }

    /// 这一期每个占位符的值;取不到的是空串。
    public static func values(defaultTitle: String, defaultBody: String, stats s: NotificationPreview.Stats,
                              topN: Int) -> [String: String] {
        var v = Dictionary(uniqueKeysWithValues: placeholders.map { ($0, "") })
        v["title"] = defaultTitle
        v["body"] = defaultBody
        v["summary"] = NotificationPreview.summaryLine(s)
        v["plays"] = String(s.totalPlays)
        v["source"] = s.sourceName
        v["from"] = s.from
        v["to"] = s.to
        v["link"] = s.link
        if s.prevPlays > 0, !s.prevLabel.isEmpty, !s.truncated {
            v["prev_plays"] = String(s.prevPlays)
            v["prev_label"] = s.prevLabel
            let pct = Int((Double(s.totalPlays - s.prevPlays) * 100 / Double(s.prevPlays)).rounded())
            v["change"] = pct > 0 ? "↑\(pct)%" : pct < 0 ? "↓\(-pct)%" : "持平"
        }
        let minutes = s.totalDurationMs / 60000
        if minutes >= 60 {
            v["duration"] = "\(minutes / 60) 小时 \(minutes % 60) 分"
        } else if minutes > 0 {
            v["duration"] = "\(minutes) 分"
        }
        let n = DigestTopN.resolved(topN)
        func list(_ tallies: [NotificationPreview.Tally]) -> (lines: String, first: String) {
            let top = tallies.prefix(n).map { $0.sub.isEmpty ? ($0.name, $0.count) : ("\($0.sub) - \($0.name)", $0.count) }
            let lines = top.enumerated().map { "\($0.offset + 1). \($0.element.0)（\($0.element.1)）" }
            return (lines.joined(separator: "\n"), top.first?.0 ?? "")
        }
        (v["top_artists"], v["top_artist"]) = list(s.artists)
        (v["top_albums"], v["top_album"]) = list(s.albums)
        (v["top_tracks"], v["top_track"]) = list(s.tracks)
        if s.newArtists > 0 {
            v["new_artists"] = String(s.newArtists)
            v["new_artist_names"] = s.newArtistNames.joined(separator: "、")
        }
        return v
    }

    /// 按行替换:一行里认得的占位符全都取不到值时整行不写;认不得的 `{xxx}` 原样留着;首尾空行去掉(同引擎 renderDigestTemplateText)。
    public static func renderText(_ template: String, values: [String: String]) -> String {
        var out: [String] = []
        for line in template.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var known = 0, filled = 0
            var rendered = ""
            var rest = Substring(line)
            while let open = rest.firstIndex(of: "{") {
                rendered += rest[..<open]
                let afterOpen = rest.index(after: open)
                guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                    rendered += rest[open...]
                    rest = ""
                    break
                }
                let name = rest[afterOpen..<close]
                if !name.isEmpty, name.allSatisfy({ ("a"..."z").contains($0) || $0 == "_" }), let value = values[String(name)] {
                    known += 1
                    if !value.isEmpty { filled += 1 }
                    rendered += value
                    rest = rest[rest.index(after: close)...]
                } else {
                    // 不是占位符:只吐出这个「{」,从下一个字符接着找(同正则 \{([a-z_]+)\} 的匹配方式)。
                    rendered += "{"
                    rest = rest[afterOpen...]
                }
            }
            rendered += rest
            if known > 0 && filled == 0 { continue }
            while let last = rendered.last, last == " " || last == "\t" { rendered.removeLast() }
            out.append(rendered)
        }
        var text = out.joined(separator: "\n")
        while text.hasPrefix("\n") { text.removeFirst() }
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// 这一期实际推的标题和正文;哪一段没自定义、或者渲染出来是空的,那一段用默认(同引擎 renderDigestTemplate)。
    public func render(defaultTitle: String, defaultBody: String, stats: NotificationPreview.Stats,
                       topN: Int) -> (title: String, body: String) {
        let v = Self.values(defaultTitle: defaultTitle, defaultBody: defaultBody, stats: stats, topN: topN)
        var outTitle = defaultTitle, outBody = defaultBody
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let r = Self.renderText(title, values: v).replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !r.isEmpty { outTitle = r }
        }
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let r = Self.renderText(body, values: v)
            if !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { outBody = r }
        }
        return (outTitle, outBody)
    }
}
