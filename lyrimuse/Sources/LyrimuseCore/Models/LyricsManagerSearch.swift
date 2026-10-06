import Foundation

/// 歌词管理一族的搜索框(列表过滤、搜索候选歌词面板)真正拿去搜的那份关键词。框里打的内容不改,只在搜的时候用它。
public enum LyricsManagerSearch {
    /// 去掉首尾的空白(半角 / 全角空格、粘贴带进来的换行和制表符),中间的空格照留:「周 杰伦」跟「周杰伦」是两种写法。
    public static func query(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 列表按相关度排时的档次,越小越靠前:歌名开头命中 0、歌名里命中 1、歌手命中 2、专辑命中 3;都不命中为 nil。
    /// 传进来的都是小写的那份,命中的口径跟列表过滤一样(`String.contains`)。
    public static func relevance(query: String, title: String, artists: [String], album: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        if title.hasPrefix(query) { return 0 }
        if title.contains(query) { return 1 }
        if artists.contains(where: { $0.contains(query) }) { return 2 }
        if album.contains(query) { return 3 }
        return nil
    }

    /// `text` 里命中 `query` 的每一段(不分大小写、互不重叠),给列表行的高亮用。
    public static func matchRanges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let found = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
            guard !found.isEmpty else { break }
            out.append(found)
            start = found.upperBound
        }
        return out
    }
}
