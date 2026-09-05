import CoreGraphics

/// 「搜索候选歌词」那一排查询词输入框(歌名 / 歌手 / 专辑)怎么分宽度(2026-09-04)。
///
/// # 为什么不是等分
///
/// 原来三个 `TextField` 摆在 `HStack` 里,SwiftUI 把剩余宽度**均分**成三份。于是实测里
/// 常见的一幕是:歌手栏写着「PRINCE」六个字母、后面空着大半格,而旁边
/// 「Around the World in a Day (2025 Remaster)」和专辑名两栏双双被截断(用户反馈
/// 「这种搜索输入框放不下内容的情况帮我想想怎么优化」)。三栏的内容长度天然不对等
/// ——歌手名通常最短、专辑名常带一长串版本尾缀——均分等于把宽度分给了最不需要的那栏。
///
/// 所以按**各自想要多大**来分:短的只拿它需要的,省下来的给长的。
///
/// # 规则
///
/// 1. 总宽连「每栏都给到下限」都不够(窗口被拖到极窄)→ 平均分。这时谁也读不全,
///    平均分至少还是可预测的。
/// 2. 全部想要的加起来放得下 → 每栏先拿满,**多出来的平均分**给三栏(而不是全塞给最长
///    的那栏):输入框留一点余量,继续往里打字时不会一个字就顶到边。
/// 3. 放不下 → 按「想要多少」的比例分,但谁都不能低于下限;被下限托住的先钉死,剩下的
///    宽度再在其余栏之间按比例分,反复到稳定(water-filling)。少了这一步,一栏长得离谱
///    时另外两栏会被压成几个像素宽。
///
/// 纯函数,不碰 AppKit —— 度量文字宽度那一步在视图侧做(要拿到实际字体),这里只管
/// 「已知每栏想要多宽,总共这么宽,各分多少」这一道算术。selftest `lyrics-parsing` 组覆盖。
public enum LyricsQueryFieldLayout {
    /// - Parameters:
    ///   - desired: 每栏「装下自己的内容需要多宽」(视图侧按实际字体量出来的,含内边距)。
    ///   - available: 这一排能用的总宽度(已经扣掉栏间距)。
    ///   - minWidth: 每栏的下限,再挤也不能低于它。
    public static func widths(desired: [CGFloat], available: CGFloat, minWidth: CGFloat) -> [CGFloat] {
        let n = desired.count
        guard n > 0 else { return [] }
        guard available > 0 else { return Array(repeating: 0, count: n) }
        // 规则 1
        if available <= minWidth * CGFloat(n) {
            return Array(repeating: available / CGFloat(n), count: n)
        }
        // 规则 2。空栏(只有占位符)的 desired 可能比下限还小,先托到下限再谈。
        let base = desired.map { max($0, minWidth) }
        let baseSum = base.reduce(0, +)
        if baseSum <= available {
            let bonus = (available - baseSum) / CGFloat(n)
            return base.map { $0 + bonus }
        }
        // 规则 3
        var fixed = Array(repeating: false, count: n)
        var out = Array(repeating: CGFloat(0), count: n)
        while true {
            let free = (0..<n).filter { !fixed[$0] }
            guard !free.isEmpty else { break }
            let taken = (0..<n).filter { fixed[$0] }.reduce(CGFloat(0)) { $0 + out[$1] }
            let remaining = available - taken
            // 权重取 max(desired, 1):desired 全 0 时退化成等分,不至于除出 NaN。
            let weightSum = free.reduce(CGFloat(0)) { $0 + max(desired[$1], 1) }
            var clampedAny = false
            for i in free {
                let share = remaining * max(desired[i], 1) / weightSum
                if share < minWidth {
                    out[i] = minWidth
                    fixed[i] = true
                    clampedAny = true
                } else {
                    out[i] = share
                }
            }
            if !clampedAny { break }
        }
        return out
    }
}
