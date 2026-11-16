import Foundation

/// 歌词管理列表那张表格(App 侧 `LyricsManagerSongTable`)里选中、右键菜单按行号和 key 互换的规则。行号是表格里的第几行,
/// `key(row)` 给这一行的歌的 key,组头和越界给 nil。见 11 章决策 170。
public enum LyricsManagerListTable {
    /// 这几首各在第几行(组头不算)。key 不在列表里就没有对应的行。
    public static func rows(of keys: Set<String>, count: Int, key: (Int) -> String?) -> IndexSet {
        guard !keys.isEmpty else { return [] }
        var result = IndexSet()
        for row in 0..<max(count, 0) {
            if let k = key(row), keys.contains(k) { result.insert(row) }
        }
        return result
    }

    /// 这几行是哪几首;组头和越界的行不算。
    public static func keys(atRows rows: IndexSet, key: (Int) -> String?) -> Set<String> {
        var result = Set<String>()
        for row in rows {
            if let k = key(row) { result.insert(k) }
        }
        return result
    }

    /// 右键菜单作用于哪几首:点在选中区里是整个选区,点在没选中的歌上是那一首(选中不动),点在空白处(-1)或组头上是空集。
    public static func menuKeys(clickedRow: Int, selectedRows: IndexSet, key: (Int) -> String?) -> Set<String> {
        guard let clicked = key(clickedRow) else { return [] }
        return selectedRows.contains(clickedRow) ? keys(atRows: selectedRows, key: key) : [clicked]
    }

    /// 外层重算后表格要做的事。
    public enum Refresh: Equatable, Sendable {
        case none
        /// 数据还是那一份,行上画的东西变了(搜索词、校准名单、界面语言):只重画建着的那几行。
        case visibleRows
        /// 换了一份数据:整表重载,再按 key 把选中对回去。
        case reload
    }

    public static func refresh(sameData: Bool, rowInputsChanged: Bool) -> Refresh {
        if !sameData { return .reload }
        return rowInputsChanged ? .visibleRows : .none
    }
}
