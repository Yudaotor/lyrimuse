import Foundation

/// 「前进 / 后退」的浏览历史 —— 走过的位置序列 + 当前停在第几个。
///
/// 纯值语义,不认 SwiftUI,所以 selftest 直接覆盖得到;界面那半只剩两颗按钮的
/// `disabled` 与 `action`。做成泛型而不是写死设置窗那个 `SettingsSidebarItem`:
/// 这条逻辑跟"元素是什么"毫无关系,而 `SettingsSidebarItem` 住在 App target、
/// Core 不认识它(selftest 也只依赖 Core)。
///
/// 语义对着 macOS「系统设置」逐条抄:
///   · 后退回到上一个位置、前进再走回来;
///   · **从历史中间跳去一个新位置时,前面那一截被截断**(同浏览器);
///   · 重复进入当前这一个位置不产生新记录(点侧栏里已经亮着的那一行);
///   · 起点用 `seed` 种,它不让后退键变成可点 —— "打开就在这儿"不是一次跳转。
public struct NavigationHistory<Item: Hashable> {
    /// 走过的位置,从旧到新。
    public private(set) var items: [Item] = []
    /// 当前停在 `items` 的第几个。空历史是 -1(不是 0:0 会让 `canGoBack` 的边界判断
    /// 依赖 `items` 是否为空,两处判据迟早漂开)。
    public private(set) var index: Int = -1
    /// 封顶,别让一次长会话把它撑成无限长。砍掉队头时索引跟着往前挪一格。
    public let capacity: Int

    public init(capacity: Int = 64) {
        precondition(capacity >= 2, "历史至少要能放下「上一个 + 当前」两项")
        self.capacity = capacity
    }

    public var current: Item? {
        index >= 0 && index < items.count ? items[index] : nil
    }

    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < items.count - 1 }

    /// 种下起点。窗口刚出现时调一次:此刻这一页是"打开就在这儿",不是一次跳转,所以
    /// 它只当第 0 项 —— 不这么种的话,刚打开就有一颗能点的后退键,退回一个从没露过面的页面。
    /// 传 nil(还什么都没选中)就是清空。
    public mutating func seed(_ item: Item?) {
        if let item {
            items = [item]
            index = 0
        } else {
            items = []
            index = -1
        }
    }

    /// 记一次跳转。返回**是否真的记了** —— 已经停在这一个位置时不记(点侧栏里已经亮着
    /// 的那一行不该产生一条后退记录)。
    @discardableResult
    public mutating func record(_ item: Item) -> Bool {
        if current == item { return false }
        // 从中间跳走 → 前面那一截作废。先截断再 append,否则 index 会指错。
        if index >= 0, index < items.count - 1 {
            items.removeSubrange((index + 1)...)
        }
        items.append(item)
        index = items.count - 1
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
            index = items.count - 1
        }
        return true
    }

    /// 后退一格,返回该切过去的位置;退不动就是 nil(调用方据此不动 selection)。
    public mutating func goBack() -> Item? {
        guard canGoBack else { return nil }
        index -= 1
        return items[index]
    }

    /// 前进一格,返回该切过去的位置;进不动就是 nil。
    public mutating func goForward() -> Item? {
        guard canGoForward else { return nil }
        index += 1
        return items[index]
    }
}
