import Foundation
import CoreGraphics

/// 「顺序优先」歌词源列表把手拖拽排序的纯逻辑(2026-09-05):目标位滞回判定、让位位移、松手后写回完整
/// 排列。视图层(SettingsView 的 LyricsSettingsTab)只做手势与渲染。
///
/// 三件事都是纯函数,放 Core 是为了 selftest 能钉住(settings-ui 组):
///   - `targetIndex`:被拖的行现在该占哪个槽。判据是被拖行的**中线**越过邻行中线再多 `hysteresis`
///     才换位 —— 两个方向各留余量,形成 2h 的死区,指针在两行交界抖动不会来回换位;一帧内可以连越
///     多行(快速甩动),但只朝一个方向推进。
///   - `displacement`:其余行为被拖行让位时该挪多远。挪的是**槛距**(挪到相邻行原来的中线),不是行高 ——
///     行与行之间还有分隔线,按行高挪会差一条线的高度、越挪越歪。
///   - `moved`:松手后把可见列表(只含启用源)的新顺序写回完整排列,**禁用源的槽位不动**。跟上下箭头
///     的相邻 swap 语义一致:禁用源再次启用时回到它原来的相对位置;若用「摘出再插回」,禁用源会跟着
///     被拖的行漂移,箭头挪和拖拽挪对同一份数据给出不同结果。
///
/// 坐标全部来自视图层在**拖拽开始那一刻**对各行中线的一次性快照(卡片容器的命名坐标空间),拖拽期间
/// 不重新量:让位动画进行中量到的是半路的位置。滚轮把列表滚走会让快照失效,这是已知限制,松手即恢复。
public enum ReorderDrag {
    /// 默认滞回量。这套行高约 35pt,6pt 约是行高的六分之一:足以吃掉手抖,又不会让「刚过中线还不换位」
    /// 被察觉成迟钝。
    public static let defaultHysteresis: CGFloat = 6

    /// 被拖行现在该占的槽位。
    /// - rowMidYs:各可见行**静止时**的中线,按列表顺序(递增)。
    /// - source:被拖行在列表里的原下标。
    /// - current:上一帧算出的目标位(开始时 = source)。
    /// - draggedMidY:被拖行此刻的中线(原中线 + 位移)。
    /// 输入不合法(单行 / source 越界)时原样返回 current。
    public static func targetIndex(rowMidYs: [CGFloat], source: Int, current: Int, draggedMidY: CGFloat,
                                   hysteresis: CGFloat = defaultHysteresis) -> Int {
        let n = rowMidYs.count
        guard n > 1, rowMidYs.indices.contains(source) else { return current }
        // 首尾特判(2026-09-05 用户真机发现「拖不到第一个前面」):被拖行的位移被 clampedTranslation 夹在首尾
        // 中线之间,永远到不了「越过首行中线再多 h」,首位 / 末位就成了死角 —— 夹住和滞回各自都对,叠在一起
        // 就错了。到达边界直接落到首 / 末位:边界处指针再也推不动,不存在来回换位,滞回在这里没有意义。
        // 留半点容差,frame 不是整数时浮点加减不一定精确回到边界值。
        if draggedMidY <= rowMidYs[0] + 0.5 { return 0 }
        if draggedMidY >= rowMidYs[n - 1] - 0.5 { return n - 1 }
        // 其余行(不含被拖行)按原顺序;目标位 t 的含义是「被拖行排在 others 的前 t 个之后」。
        let others = rowMidYs.indices.filter { $0 != source }.map { rowMidYs[$0] }
        var t = min(max(current, 0), n - 1)
        // 往下:越过紧邻下方那行的中线再多 h。
        while t < n - 1, draggedMidY > others[t] + hysteresis { t += 1 }
        // 往上:越过紧邻上方那行的中线再多 h。刚往下推进过的话这里的条件必然不成立,一帧只朝一个方向。
        while t > 0, draggedMidY < others[t - 1] - hysteresis { t -= 1 }
        return t
    }

    /// 第 `row` 行为让位该挪多远(正数向下)。被拖行自己返回 0(它跟着指针走,不归这里管)。
    public static func displacement(row: Int, source: Int, target: Int, rowMidYs: [CGFloat]) -> CGFloat {
        guard row != source, rowMidYs.indices.contains(row), rowMidYs.indices.contains(source) else { return 0 }
        if source < row, row <= target {
            // 被拖行往下走,中间这些行往上补一格:挪到上一行原来的中线。
            return rowMidYs[row - 1] - rowMidYs[row]
        }
        if target <= row, row < source {
            // 被拖行往上走,中间这些行往下让一格。
            return rowMidYs[row + 1] - rowMidYs[row]
        }
        return 0
    }

    /// 把被拖行的位移夹在列表首尾中线之间,行不会被拖出列表。
    public static func clampedTranslation(_ translation: CGFloat, source: Int, rowMidYs: [CGFloat]) -> CGFloat {
        guard let first = rowMidYs.first, let last = rowMidYs.last, rowMidYs.indices.contains(source) else {
            return translation
        }
        let mid = rowMidYs[source]
        return min(max(translation, first - mid), last - mid)
    }

    /// 松手:把可见列表里 `from` → `to` 的一次移动写回完整排列,不可见(禁用)的槽位不动。
    /// `to` 是被拖行在可见列表里的**最终**下标。下标越界或原地不动时原样返回。
    public static func moved<Element>(_ order: [Element], isVisible: (Element) -> Bool, from: Int, to: Int) -> [Element] {
        var visible = order.filter(isVisible)
        guard visible.indices.contains(from), visible.indices.contains(to), from != to else { return order }
        let item = visible.remove(at: from)
        visible.insert(item, at: to)
        var result = order
        var k = 0
        for i in result.indices where isVisible(result[i]) {
            result[i] = visible[k]
            k += 1
        }
        return result
    }
}
