import SwiftUI
import LyrimuseCore

// 逐字卡拉OK的"软边渐变"算法,从 LyricsOverlayView(悬浮歌词)抽出来给"歌词窗口"
// (LyricsWindowView)复用——两边都需要同一套"当前播放位置在这个字内部的百分比,套一条
// 带过渡带的渐变"计算,原来只有悬浮窗一份实现,"歌词窗口"曾经图省事另写过一套二值
// (唱到/没唱到瞬间切换、100ms 一档采样)的简化版,被指出观感不够丝滑——根源就是没有
// 复用这套已经调好的连续渐变算法,现在两边共用同一份,不再各自维护、也不会再有观感
// 不一致的问题。外层容器/描边这些跟具体窗口形态相关的处理各自留在各自的 View 里。
enum WordKaraokeGradient {
    // 逐字时长下限——只影响这一个词自己的填色速度,不改 startMs、不影响下一个词何时
    // 开始。英文歌词(NetEase/QQ/酷狗给的逐字对齐)比中文更容易出现 durationMs==0 或
    // 几十毫秒的极短词(介词/冠词一类),硬边界瞬间 0→1 在这种词密集的句子里会显得更"跳"。
    static let minWordDurationMs = 80
    // 过渡带半宽(fraction 单位)——真正需要柔化的只是"刚好唱到/刚好唱完"这个边界附近
    // 一小段,不是整个 [0,1] 区间。
    static let wordEdgeSoftenBand = 0.08

    // 故意不夹到 [0,1]——如果夹住,"还没轮到、离真正唱到还有好几个字/好几句"的词会
    // 全都被夹成跟"刚好唱到这个词最前一刻"相同的 0,调用方(gradient)里的过渡带因此会
    // 在每一个尚未唱到的词开头误算出一小截"已经唱过"的高亮。真正需要的裁剪挪到
    // gradient 里,按"过渡带跟 [0,1] 是否有交集"分情况处理。
    static func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        let effectiveDuration = max(w.durationMs, minWordDurationMs)
        return Double(ms - w.startMs) / Double(effectiveDuration)
    }

    // 用渐变整体当文字颜色,而不是叠两层 Text + GeometryReader 手算裁剪宽度——渐变的
    // stop 位置直接由调用方每帧算出的真实进度决定,不需要额外插值。已唱过的部分是 fg
    // 全强度,未唱到的部分是同一个 fg 的 35% 透明度,没有单独的"进度色"参数。
    static func gradient(fg: Color, left: Double, right: Double) -> LinearGradient {
        let dim = fg.opacity(0.35)
        if right <= 0 {
            return LinearGradient(colors: [dim, dim], startPoint: .leading, endPoint: .trailing)
        }
        if left >= 1 {
            return LinearGradient(colors: [fg, fg], startPoint: .leading, endPoint: .trailing)
        }
        // 过渡带 [left, right] 以这个字真实的(未夹到 [0,1] 的)进度为中心,可能整段落在
        // [0,1] 之外——离真正唱到还很远的字(right<=0,上面已经处理)、或者早就唱完很久
        // 的字(left>=1,上面已经处理),两种都不需要渐变。只有过渡带真正跟 [0,1] 有交集
        // 时才需要在夹住的那一端现算准确的混合色(而不是硬编码"已唱"/"未唱"两个端值),
        // 避免同一位置出现两个不同颜色的 stop 时被其中一个"抢占"。
        func blended(at x: Double) -> Color {
            let t = min(1, max(0, (x - left) / (right - left)))
            return fg.opacity(1 - t * 0.65) // 0.65 = 1 - 0.35,在 full 和 dim(0.35)之间线性混
        }
        var stops: [Gradient.Stop] = []
        if left > 0 {
            stops.append(.init(color: fg, location: 0))
            stops.append(.init(color: fg, location: left))
        } else {
            stops.append(.init(color: blended(at: 0), location: 0))
        }
        if right < 1 {
            stops.append(.init(color: dim, location: right))
            stops.append(.init(color: dim, location: 1))
        } else {
            stops.append(.init(color: blended(at: 1), location: 1))
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }
}
