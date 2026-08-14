import Foundation

/// 逐字卡拉OK填色的**纯数值部分**:当前播放位置落在一个字内部的百分比,以及由它推出的
/// 渐变分段。不认识 SwiftUI —— 把这些数值变成 `LinearGradient` 是 UI 层那几行的事
/// (见 WordKaraokeGradient)。
///
/// 拆出来的理由:这段算法历史上反复出问题(填色提前跑到下一个字、边界上出现两个同位置
/// 不同色的 stop、fillFraction 该不该夹到 [0,1]),而每一次都只能靠盯着屏幕看——因为它
/// 混在 View 文件里,没有任何办法在没有屏幕的情况下问它一句"这个输入你算出什么"。
/// 现在它在 LyrimuseCore 里,`lyrimuse-selftest` 够得到,历史上修过的每个结论都钉成了
/// 断言。
public enum KaraokeFill {
    /// 逐字时长下限——只影响这一个词自己的填色速度,不改 startMs、不影响下一个词何时
    /// 开始。英文歌词(NetEase/QQ/酷狗给的逐字对齐)比中文更容易出现 durationMs==0 或
    /// 几十毫秒的极短词(介词/冠词一类),硬边界瞬间 0→1 在这种词密集的句子里会显得更"跳"。
    public static let minWordDurationMs = 80

    /// 过渡带半宽(fraction 单位)——真正需要柔化的只是"刚好唱到/刚好唱完"这个边界附近
    /// 一小段,不是整个 [0,1] 区间。
    public static let wordEdgeSoftenBand = 0.08

    /// 故意不夹到 [0,1]——如果夹住,"还没轮到、离真正唱到还有好几个字/好几句"的词会
    /// 全都被夹成跟"刚好唱到这个词最前一刻"相同的 0,调用方(stops)里的过渡带因此会
    /// 在每一个尚未唱到的词开头误算出一小截"已经唱过"的高亮。真正需要的裁剪在 stops
    /// 里按"过渡带跟 [0,1] 是否有交集"分情况处理。
    public static func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        let effectiveDuration = max(w.durationMs, minWordDurationMs)
        return Double(ms - w.startMs) / Double(effectiveDuration)
    }

    /// 渐变上的一个分段点。`intensity` 是"唱过的程度":1 = 前景色全强度,0 = 未唱到的暗色。
    /// 具体映射到什么颜色由 UI 层决定,这里不掺和。
    public struct Stop: Equatable, Sendable {
        public let location: Double
        public let intensity: Double

        public init(location: Double, intensity: Double) {
            self.location = location
            self.intensity = intensity
        }
    }

    /// 把过渡带 `[left, right]`(以这个字真实的、未夹过的进度为中心)转成渐变分段。
    ///
    /// 过渡带可能整段落在 [0,1] 之外:离真正唱到还很远的字(right<=0)、早就唱完很久的字
    /// (left>=1),两种都不需要渐变,直接给一整片纯色。只有过渡带真跟 [0,1] 有交集时,才在
    /// 被夹住的那一端**现算**准确的混合值(而不是硬编码成"已唱"或"未唱")——否则同一个
    /// 位置会出现两个不同颜色的 stop,渲染时其中一个被另一个抢占,边界上就会闪。
    public static func stops(left: Double, right: Double) -> [Stop] {
        if right <= 0 {
            return [Stop(location: 0, intensity: 0), Stop(location: 1, intensity: 0)]
        }
        if left >= 1 {
            return [Stop(location: 0, intensity: 1), Stop(location: 1, intensity: 1)]
        }
        // 过渡带内某个位置的强度:从 left 处的 1 线性降到 right 处的 0。
        func intensity(at x: Double) -> Double {
            let t = min(1, max(0, (x - left) / (right - left)))
            return 1 - t
        }
        var result: [Stop] = []
        if left > 0 {
            result.append(Stop(location: 0, intensity: 1))
            result.append(Stop(location: left, intensity: 1))
        } else {
            result.append(Stop(location: 0, intensity: intensity(at: 0)))
        }
        if right < 1 {
            result.append(Stop(location: right, intensity: 0))
            result.append(Stop(location: 1, intensity: 0))
        } else {
            result.append(Stop(location: 1, intensity: intensity(at: 1)))
        }
        return result
    }
}
