import Foundation

/// Apple Music 没有专辑简介 / 歌手简介时的兜底:Last.fm 官方接口 `album.getInfo` 的 `wiki`、`artist.getInfo` 的 `bio`;
/// 歌曲简介(Apple Music 不给单曲写介绍)用 `track.getInfo` 的 `wiki`
/// (纯函数,selftest 钉着;请求走 App 侧 `LastfmStatsService` 那条带限速与退避的通道)。
///
/// 正文是 Last.fm 用户编写的百科,按 CC BY-SA 授权 —— 展示时要注明出处(简介卡片底部「来自 Last.fm」)。
/// 正文末尾固定带一段 `<a href="…">Read more on Last.fm</a>. User-contributed text is available under the Creative
/// Commons By-SA License; additional terms may apply.`,出处已由卡片注明,这一段从 `<a` 起整段去掉。
///
/// 语言:界面是中文时先要 `lang=zh`,拿到空正文再要默认(英文)那份;其余界面只要默认那份。
public enum LastfmEditorialInfo {
    /// 解析结果。`.none` = Last.fm 明确没有(条目存在但没有正文);形状不对是 nil(不记结论,下次再试)。
    public enum Parsed: Equatable, Sendable {
        case text(String)
        case none
    }

    /// 界面语言 → 该先要的 `lang` 参数。nil = 只要默认那份。
    public static func preferredLang(uiLanguage: String) -> String? {
        uiLanguage.lowercased().hasPrefix("zh") ? "zh" : nil
    }

    /// `artist.getInfo` 的响应 → 歌手简介。
    public static func artistBio(from json: [String: Any]) -> Parsed? {
        guard let artist = json["artist"] as? [String: Any] else { return nil }
        guard let bio = artist["bio"] as? [String: Any] else { return Parsed.none }
        return body(bio)
    }

    /// `album.getInfo` 的响应 → 专辑介绍。没有 `wiki` 字段就是没有介绍。
    public static func albumWiki(from json: [String: Any]) -> Parsed? {
        guard let album = json["album"] as? [String: Any] else { return nil }
        guard let wiki = album["wiki"] as? [String: Any] else { return Parsed.none }
        return body(wiki)
    }

    /// `track.getInfo` 的响应 → 歌曲介绍。没有 `wiki` 字段就是没有介绍(抽样外文歌 24 首里 10 首有,中文歌 16 首里 1 首)。
    public static func trackWiki(from json: [String: Any]) -> Parsed? {
        guard let track = json["track"] as? [String: Any] else { return nil }
        guard let wiki = track["wiki"] as? [String: Any] else { return Parsed.none }
        return body(wiki)
    }

    private static func body(_ node: [String: Any]) -> Parsed {
        for key in ["content", "summary"] {
            let text = cleaned((node[key] as? String) ?? "")
            if !text.isEmpty { return .text(text) }
        }
        return .none
    }

    /// 去掉末尾「Read more on Last.fm / 授权声明」那一段,去掉其余 HTML 标签,解常见 HTML 实体,压掉首尾空白。
    ///
    /// 从**最后一个**链接截:正文中间也可能有内嵌链接(提到别的歌手、专辑),从第一个截会把后面的正文整段丢掉。
    public static func cleaned(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: "<a href=", options: .backwards) { text = String(text[..<range.lowerBound]) }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // `&amp;` 放最后:先解它的话 `&amp;lt;` 会被多解一层。
        let entities = [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")]
        for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
