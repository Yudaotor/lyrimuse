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

    /// 摘要只能整段取舍时(`EditorToolbarSummary`),把 `fill` 分好的这一行重新落到每颗实际画得出的那一档上,不让宽度空在
    /// 画不出东西的胶囊里:分档的那几颗在它们分到的总宽内挑一种组合,先让露出摘要的颗数最多,再让整句的颗数最多,再让
    /// 用掉的宽度最多(空白最少);剩下的均分给每一颗,整行照旧撑满。一行最多五六颗、每颗几档,逐个组合比一遍。
    /// `steps` 是每颗能画的几档宽度(由宽到窄,第一档是理想宽度,最后一档是只剩标题);空数组的那颗不分档、宽度照旧。
    /// 有一颗分到的比它最窄一档还窄(整行连标题都放不下、按底线比例缩过),整行照旧。
    public static func snap(_ widths: [CGFloat], steps: [[CGFloat]]) -> [CGFloat] {
        let tolerance: CGFloat = 0.5
        let stepped = widths.indices.filter { $0 < steps.count && !steps[$0].isEmpty }
        guard !stepped.isEmpty,
              stepped.allSatisfy({ widths[$0] + tolerance >= steps[$0].min() ?? 0 }) else { return widths }
        let budget = stepped.reduce(0) { $0 + widths[$1] } + tolerance
        var best: (score: (Int, Int, CGFloat), picks: [Int])?
        var picks = [Int](repeating: 0, count: stepped.count)
        func search(_ k: Int, used: CGFloat, shown: Int, whole: Int) {
            guard used <= budget else { return }
            guard k < stepped.count else {
                let score = (shown, whole, used)
                if best.map({ score > $0.score }) ?? true { best = (score, picks) }
                return
            }
            let options = steps[stepped[k]]
            for (j, width) in options.enumerated() {
                picks[k] = j
                search(k + 1, used: used + width,
                       shown: shown + (j < options.count - 1 ? 1 : 0), whole: whole + (j == 0 ? 1 : 0))
            }
        }
        search(0, used: 0, shown: 0, whole: 0)
        guard let best else { return widths }
        var result = widths
        for (k, i) in stepped.enumerated() { result[i] = steps[i][best.picks[k]] }
        let spare = (widths.reduce(0, +) - result.reduce(0, +)) / CGFloat(result.count)
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
