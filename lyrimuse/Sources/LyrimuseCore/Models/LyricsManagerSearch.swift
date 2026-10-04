import Foundation

/// 歌词管理一族的搜索框(列表过滤、搜索候选歌词面板)真正拿去搜的那份关键词。框里打的内容不改,只在搜的时候用它。
public enum LyricsManagerSearch {
    /// 去掉首尾的空白(半角 / 全角空格、粘贴带进来的换行和制表符),中间的空格照留:「周 杰伦」跟「周杰伦」是两种写法。
    public static func query(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
