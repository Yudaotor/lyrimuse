import Foundation

/// 分段比例条的几何(2026-09-06,设置页「歌词 → 管理」歌词库统计的 `SettingsProportionBar` 用)。
///
/// 放 Core 而不是跟 View 放一起:App target 不可被 selftest 引用,而这个算法改错了**完全不报错**
/// —— 只是某一段凭空消失、或者整条比可用宽度长出几 pt 被裁掉尾巴,肉眼都未必看得出。
///
/// 规则:
///   - 值为 0 的段不参与(调用方先过滤掉;这里收到 0 就按 0 宽返回,不抬到下限);
///   - 非零段至少 `minWidth` 宽 —— 真实数据里 3,669 首中 9 首纯文本只占 0.25%,按比例在 540pt
///     里只有 1.3pt,视觉上等于没有;
///   - 抬到下限多占的宽度从**最宽的一段**里扣回,各段之和(加缝隙)恒等于可用宽度,不溢出也不留尾巴;
///   - 段数多到"每段都给下限"都装不下时,下限退化成 `usable / count`(纯比例),不硬撑到溢出。
public enum ProportionBar {
    public static func widths(values: [Int], available: Double, gap: Double, minWidth: Double) -> [Double] {
        guard !values.isEmpty, available > 0 else { return values.map { _ in 0 } }
        let usable = max(available - gap * Double(values.count - 1), 0)
        let total = Double(values.reduce(0, +))
        guard total > 0, usable > 0 else { return values.map { _ in 0 } }
        var widths = values.map { usable * Double($0) / total }
        let floor = min(minWidth, usable / Double(values.count))
        var deficit = 0.0
        for index in widths.indices where values[index] > 0 && widths[index] < floor {
            deficit += floor - widths[index]
            widths[index] = floor
        }
        guard deficit > 0 else { return widths }
        // 从最宽的段扣。它扣完还不够(极端:全是小段)时继续找下一个最宽的扣,直到扣完或没得扣。
        var remaining = deficit
        var candidates = widths.indices.sorted { widths[$0] > widths[$1] }
        while remaining > 0, let index = candidates.first {
            candidates.removeFirst()
            let room = widths[index] - floor
            guard room > 0 else { continue }
            let take = min(room, remaining)
            widths[index] -= take
            remaining -= take
        }
        return widths
    }
}
