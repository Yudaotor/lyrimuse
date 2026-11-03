import CoreGraphics

/// 编辑台工具栏一行按内容分宽(`EditorToolbarContentWidthRow`)的分法。见 04 章决策 80。
public enum EditorToolbarWidths {
    /// 每颗拿 min(理想宽度, max(底线, 水位)),水位取恰好把 `room` 填满的那个值:放得下时各拿理想宽度、富余均分给每一颗
    /// (整行撑满,左右边缘跟上一行和下面的卡片对齐;不分的话这一行比容器窄、被居中,两头各缩进一截),
    /// 放不下时短的照旧拿满、亏空摊给最长的那几颗,每颗最多压到底线。底线加起来都放不下,才按底线的比例一起缩。
    /// 底线比理想宽度大、或没给底线的,按理想宽度算(不压)。
    public static func fill(ideals: [CGFloat], floors: [CGFloat], room: CGFloat) -> [CGFloat] {
        let room = max(room, 0)
        let total = ideals.reduce(0, +)
        guard total > room else {
            guard !ideals.isEmpty else { return ideals }
            let spare = (room - total) / CGFloat(ideals.count)
            return ideals.map { $0 + spare }
        }
        let floors = ideals.indices.map { i in min(max(i < floors.count ? floors[i] : ideals[i], 0), ideals[i]) }
        let floorTotal = floors.reduce(0, +)
        guard floorTotal < room else {
            let scale = floorTotal > 0 ? room / floorTotal : 0
            return floors.map { $0 * scale }
        }
        func filled(_ level: CGFloat) -> [CGFloat] {
            zip(ideals, floors).map { min($0, max($1, level)) }
        }
        var low: CGFloat = 0
        var high = ideals.max() ?? 0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if filled(mid).reduce(0, +) > room { high = mid } else { low = mid }
        }
        return filled(low)
    }

    /// 摘要只能整段取舍时(`EditorToolbarSummary`),把 `fill` 分到的宽度落到每颗实际画得出的那一档上,省下来的宽度不空着:
    /// 先按「再升一档要多少」从少到多补给差一点的那几颗,补不动了剩下的均分给每一颗(整行照旧撑满)。
    /// `steps` 是每颗能画的几档宽度(由宽到窄,第一档是理想宽度,最后一档是只剩标题);空数组的那颗不分档、宽度照旧。
    /// 分到的宽度比最窄一档还窄(整行连标题都放不下)也照旧。
    public static func snap(_ widths: [CGFloat], steps: [[CGFloat]]) -> [CGFloat] {
        var result = widths
        var freed: CGFloat = 0
        for i in result.indices where i < steps.count && !steps[i].isEmpty {
            guard let step = steps[i].first(where: { $0 <= result[i] + 0.5 }), step < result[i] else { continue }
            freed += result[i] - step
            result[i] = step
        }
        guard freed > 0 else { return result }
        while true {
            let upgrades = result.indices.compactMap { i -> (index: Int, cost: CGFloat)? in
                guard i < steps.count, let next = steps[i].last(where: { $0 > result[i] + 0.5 }) else { return nil }
                return (i, next - result[i])
            }
            guard let best = upgrades.filter({ $0.cost <= freed }).min(by: { $0.cost < $1.cost }) else { break }
            result[best.index] += best.cost
            freed -= best.cost
        }
        let spare = freed / CGFloat(max(result.count, 1))
        return result.map { $0 + spare }
    }
}

/// 工具栏胶囊上「· 当前值」放不下时能退到的几档(`EditorToolbarButtonLabel`):按「 · 」分开的值整段取舍,不在一个值中间截断。
/// 见 04 章决策 87。
public enum EditorToolbarSummary {
    public static let separator = " · "

    public static func parts(_ summary: String) -> [String] {
        summary.components(separatedBy: separator)
    }

    /// 由长到短:整句,再依次少掉末尾一个值、加「…」。
    public static func candidates(_ summary: String) -> [String] {
        let parts = parts(summary)
        return [summary] + (1..<parts.count).reversed().map { parts[0..<$0].joined(separator: separator) + "…" }
    }
}
