import Foundation

/// 灵动岛音浪(`EqualizerBars`)的柱高映射:双正弦给出的 0…1 "形状值" → 高度比例。
///
/// 2026-09-03 加(借鉴清单 #22 的取舍结果)。原来是线性映射;用户想要「小幅晃动压平、大幅拉伸」的
/// 动感,但被参考的那种 ease-in 曲线会把均值压掉两成、贴地时间翻三倍(模拟:满幅均值 9.25 → 7.38pt,
/// <4pt 的时间 7.7% → 21.7%),跟 2026-09-01 用户两次反馈「幅度太小」正好反向;逐柱固定上限轮廊
/// 则会画出一个静止形状,跟黄金角相位「任意根数都不出现整齐推进」的既有决定冲突,两者都没采用。
///
/// 这里用的是 smoothstep(3u² − 2u³):0.5 处不动、两端向外推 —— 均值不变(仍 9.25pt),顶满
/// (>15pt)的时间 5% → 12%,贴地 8% → 15%,起音那一拍更容易顶到头、换气更明显地缩下去。
/// 放在 LyrimuseCore 是为了让 selftest 钉住三条不变量:端点不动、中点不动、单调。
public enum EqualizerBarCurve {
    /// smoothstep:f(0)=0、f(0.5)=0.5、f(1)=1,单调递增;0.5 以下被压低、以上被抬高。
    public static func contrast(_ unit: Double) -> Double {
        let u = min(1, max(0, unit))
        return u * u * (3 - 2 * u)
    }

    /// 最终高度比例(0…1):先过对比曲线,再乘人声包络振幅,最后夹到 1。
    /// **乘完再夹**(2026-09-02 的既有决定):起音脉冲给到 1.25 时要能顶到上限,先夹会把脉冲吃掉。
    public static func level(unit: Double, amplitude: Double) -> Double {
        min(1, contrast(unit) * max(0, amplitude))
    }
}
