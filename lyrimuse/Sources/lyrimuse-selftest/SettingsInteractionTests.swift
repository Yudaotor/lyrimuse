import LyrimuseCore
import Foundation

// 设置页交互的纯逻辑:「顺序优先」歌词源列表的把手拖拽排序(滞回 / 让位 / 写回)。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里。

@MainActor
func runSettingsInteractionTests() {
    // ---- ReorderDrag(2026-09-05,借鉴清单 #53)----
    //
    // 数值都按真实的设置行来:行高约 35 + 分隔线 1 = 槛距 36;五行的静止中线 17.5 / 53.5 / 89.5 / 125.5 / 161.5。
    do {
        print("\n== 顺序优先列表拖拽排序 ==")
        typealias R = ReorderDrag
        let mids: [CGFloat] = (0..<5).map { 17.5 + 36 * CGFloat($0) }

        // 滞回:被拖第 1 行(中线 53.5)往下,越过第 2 行中线 89.5 还不换位,再多 6 才换;换位后往回抖 6 以内不退。
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 53.5), 1, "滞回: 没动 → 原位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 89.5 + 5.9), 1, "滞回: 越过邻行中线 5.9pt 还不换位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 89.5 + 6.1), 2, "滞回: 越过邻行中线 6.1pt 换位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 2, draggedMidY: 89.5 - 5.9), 2, "滞回: 换位后回抖 5.9pt 不退回(死区 2h)")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 2, draggedMidY: 89.5 - 6.1), 1, "滞回: 回抖超过 6pt 才退回")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: 89.5 - 5.9), 3, "滞回: 往上越过 5.9pt 不换")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: 89.5 - 6.1), 2, "滞回: 往上越过 6.1pt 换位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 500), 4, "滞回: 一帧连越多行到末位并夹住")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: -100), 0, "滞回: 往上连越到首位并夹住")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 89.5 + 0.1, hysteresis: 0), 2, "滞回: h=0 退化成过中线即换")
        expectEqual(R.targetIndex(rowMidYs: [10], source: 0, current: 0, draggedMidY: 999), 0, "滞回: 单行列表原地")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 9, current: 1, draggedMidY: 999), 1, "滞回: source 越界 → 保持 current")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 42, draggedMidY: 53.5), 1, "滞回: current 越界先夹进范围再按位置判(没动就回原位)")
        // 单向推进:一帧里只朝一个方向走。从 0 甩到底再在同一帧里不可能又退回。
        var t = 0
        for y in stride(from: 17.5, through: 200, by: 7) { t = R.targetIndex(rowMidYs: mids, source: 0, current: t, draggedMidY: CGFloat(y)) }
        expectEqual(t, 4, "滞回: 逐帧往下推进到底")
        var back = t
        for y in stride(from: 200, through: 0, by: -7) { back = R.targetIndex(rowMidYs: mids, source: 0, current: back, draggedMidY: CGFloat(y)) }
        expectEqual(back, 0, "滞回: 逐帧往上推进回顶")

        // 让位:被拖第 1 行去了 3,第 2、3 行各往上补一格(挪到上一行原中线,含分隔线),其余不动。
        expectEqual(R.displacement(row: 2, source: 1, target: 3, rowMidYs: mids), CGFloat(-36), "让位: 被越过的行往上挪一个槛距(含分隔线)")
        expectEqual(R.displacement(row: 3, source: 1, target: 3, rowMidYs: mids), CGFloat(-36), "让位: 目标位那行也往上")
        expectEqual(R.displacement(row: 4, source: 1, target: 3, rowMidYs: mids), CGFloat(0), "让位: 目标位之后的行不动")
        expectEqual(R.displacement(row: 0, source: 1, target: 3, rowMidYs: mids), CGFloat(0), "让位: 被拖行之前的行不动")
        expectEqual(R.displacement(row: 1, source: 1, target: 3, rowMidYs: mids), CGFloat(0), "让位: 被拖行自己不归这里管")
        expectEqual(R.displacement(row: 2, source: 3, target: 1, rowMidYs: mids), CGFloat(36), "让位: 往上拖时中间行往下挪")
        expectEqual(R.displacement(row: 1, source: 3, target: 1, rowMidYs: mids), CGFloat(36), "让位: 往上拖到的目标位那行往下")
        expectEqual(R.displacement(row: 2, source: 2, target: 2, rowMidYs: mids), CGFloat(0), "让位: 没换位一律 0")
        expectEqual(R.displacement(row: 7, source: 2, target: 4, rowMidYs: mids), CGFloat(0), "让位: 行下标越界 → 0")
        let uneven: [CGFloat] = [10, 50, 70]
        expectEqual(R.displacement(row: 1, source: 0, target: 2, rowMidYs: uneven), CGFloat(-40), "让位: 非均匀槛距按真实中线差(第一格)")
        expectEqual(R.displacement(row: 2, source: 0, target: 2, rowMidYs: uneven), CGFloat(-20), "让位: 非均匀槛距按真实中线差(第二格)")

        // 夹住 + 滞回叠加(2026-09-05 用户真机发现「拖不到第一个前面」就是这里漏测):位移夹在首尾中线之间后,
        // 首 / 末位必须仍然到得了。
        let toTop = R.clampedTranslation(-1000, source: 3, rowMidYs: mids)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: mids[3] + toTop), 0,
                    "首尾: 夹到顶之后要落到首位(原来差 6pt 永远到不了)")
        let toBottom = R.clampedTranslation(1000, source: 1, rowMidYs: mids)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: mids[1] + toBottom), 4,
                    "首尾: 夹到底之后要落到末位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: mids[0] + 0.3), 0, "首尾: 边界半点容差内算到顶")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: mids[0] + 1), 1, "首尾: 离顶 1pt 仍按滞回算(越过了第 2、1 行到第 1 位,还没到首位)")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 0, draggedMidY: mids[0] + 1), 0, "首尾: 到过顶之后回抖 1pt 留在首位(死区)")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 0, current: 0, draggedMidY: mids[0]), 0, "首尾: 首行静止在原位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 4, current: 4, draggedMidY: mids[4]), 4, "首尾: 末行静止在原位")
        // 逐帧从第 4 行拖到顶(每帧位移都先夹住):最终必须是 0。
        var top = 3
        for raw in stride(from: 0.0, through: -300, by: -5) {
            let tr = R.clampedTranslation(CGFloat(raw), source: 3, rowMidYs: mids)
            top = R.targetIndex(rowMidYs: mids, source: 3, current: top, draggedMidY: mids[3] + tr)
        }
        expectEqual(top, 0, "首尾: 逐帧夹住 + 滞回一路拖到顶必须落到首位")

        // 夹住:被拖行不出列表首尾。
        expectEqual(R.clampedTranslation(-1000, source: 2, rowMidYs: mids), mids[0] - mids[2], "夹住: 不出列表顶")
        expectEqual(R.clampedTranslation(1000, source: 2, rowMidYs: mids), mids[4] - mids[2], "夹住: 不出列表底")
        expectEqual(R.clampedTranslation(10, source: 2, rowMidYs: mids), CGFloat(10), "夹住: 范围内原样")
        expectEqual(R.clampedTranslation(10, source: 9, rowMidYs: mids), CGFloat(10), "夹住: source 越界原样返回")

        // 写回完整排列:x / y 是禁用源,槽位不动;可见顺序正是拖出来的顺序。
        let order = ["A", "x", "B", "C", "y", "D"]
        let enabled: Set<String> = ["A", "B", "C", "D"]
        let vis: (String) -> Bool = { enabled.contains($0) }
        expectEqual(R.moved(order, isVisible: vis, from: 3, to: 0), ["D", "x", "A", "B", "y", "C"], "写回: D 拖到首位,x/y 槽位不动")
        expectEqual(R.moved(order, isVisible: vis, from: 0, to: 3), ["B", "x", "C", "D", "y", "A"], "写回: A 拖到末位")
        expectEqual(R.moved(order, isVisible: vis, from: 1, to: 2), ["A", "x", "C", "B", "y", "D"], "写回: 相邻一步 = 箭头 swap 的结果")
        expectEqual(R.moved(order, isVisible: vis, from: 2, to: 2), order, "写回: 原地不动原样返回")
        expectEqual(R.moved(order, isVisible: vis, from: 7, to: 0), order, "写回: from 越界原样返回")
        expectEqual(R.moved(order, isVisible: vis, from: 0, to: 4), order, "写回: to 越界(可见只有 4 个)原样返回")
        expectEqual(R.moved(order, isVisible: vis, from: 3, to: 0).filter(vis), ["D", "A", "B", "C"], "写回: 可见顺序正是拖出来的顺序")
        expectEqual(Set(R.moved(order, isVisible: vis, from: 3, to: 0)), Set(order), "写回: 不丢不多")
        expectEqual(R.moved([1, 2, 3, 4], isVisible: { _ in true }, from: 3, to: 1), [1, 4, 2, 3], "写回: 全部可见 = 普通 move")
        var stepwise = order
        for (f, to) in [(3, 2), (2, 1), (1, 0)] { stepwise = R.moved(stepwise, isVisible: vis, from: f, to: to) }
        expectEqual(stepwise, R.moved(order, isVisible: vis, from: 3, to: 0), "写回: 三次相邻 swap 与一次拖拽结果一致(箭头与把手不打架)")
    }
}
