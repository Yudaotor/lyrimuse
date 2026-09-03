import Foundation

/// 灵动岛音浪的**人声包络**:给定播放位置和当前行的逐字数据,算出此刻的振幅(0…1.25)。
/// 纯函数、纯数值,`lyrimuse-selftest` 钉住形状;UI 层(`EqualizerBars`)只拿它去缩放双正弦曲线。
///
/// ## 2026-09-02 之前是三档阶跃
///
/// 字内 1、字间空档 0.6、没有逐字 1(`NotchLyricsView.vocalAmplitude`)。两轮用户反馈
///(「机械感」08-23、「不够动感」09-01)都是靠调求值频率 / 最大高度 / 正弦频率解决的,包络本身
/// 一直是阶跃。05 章还记着一次失败尝试:按字的已唱比例做连续插值,结果每一跳更平均、反而更不像
/// 跟着人声——**字内稳态不该动**,那次动的正是它。
///
/// ## 现在:字内稳态不变,只加两样东西
///
///   1. **起音脉冲**:字开始那一刻 `1 + onsetBoost`,按 `attackMs` 指数衰回 1。lyrimuse 手上的
///      `word.startMs` 是比任何频谱分析都准的人声 onset(歌词源逐字对齐的产物),这是伪频谱相对
///      抓音频的实现的便宜之处——白拿一个跟人声同步的瞬态,零权限、零音频线程。
///   2. **换气泄放**:字与字之间的空档不再瞬间掉到 0.6,而是从 1 按 `releaseMs` 指数泄到
///      `gapFloor`。回落慢于上升,这是「像在听」而不是「在抖」的来源(参照实现是上升系数 0.65、
///      回落 0.28 的非对称一阶平滑,按 33ms 一帧换算约 30ms / 100ms;这里放宽到 80 / 250——
///      12.5Hz 求值下 80ms 攻击正好落进一次采样,250ms 泄放能被看见三四拍)。
///
/// 仍然是**时间的纯函数**、不维护累加器:`EqualizerBars` 那边的取舍是「TimelineView 在窗口不可见
/// 期间不保证按时给点,累加器会漂,时间戳任何时候都接得上同一条曲线」,这里沿用。
///
/// 输出可以大于 1(起音那一拍最高 1.25):`EqualizerBars.height` 是**乘完曲线再夹**到 [0,1],
/// 于是起音那一刻更多条子顶到 16pt 上限、然后回落——那就是 kick,高度永远不会超过上限。
/// 求值频率刻意不动(12.5Hz):80ms 攻击配 80ms 采样间隔够用,提频会碰 2026-08-19 的性能红线。
///
/// 四个常数都是起点,按真机手感调;`releaseMs` 别超过 300——上一行的尾巴不能盖住下一行
/// 第一个字的起音。
public enum VocalEnvelope {
    /// 起音瞬态的额外幅度。
    public static let onsetBoost = 0.25
    /// 起音瞬态的指数衰减时间常数(毫秒)。
    public static let attackMs = 80.0
    /// 换气泄放的指数时间常数(毫秒)。
    public static let releaseMs = 250.0
    /// 字间空档的地板。听感上换气是"弱"而不是"停"。
    public static let gapFloor = 0.6
    /// 没有逐字数据时的幅度——取 1 是刻意的:那是加这套机制之前的行为,整行模式和纯音乐
    /// 不该因为"拿不到字"就显得比有词的时候更蔫。
    public static let idleAmplitude = 1.0

    /// `words` 是当前行的逐字(按 startMs 升序,LyricsSyncEngine 的输出就是);`posMs` 是叠加好
    /// 偏移的播放位置。行首第一个字之前没有"上一字终点"可泄放,按地板算。
    public static func amplitude(atMs posMs: Int, words: [SyncedLyricWord]) -> Double {
        guard !words.isEmpty else { return idleAmplitude }
        var lastEndBefore: Int? = nil
        for w in words {
            let end = w.startMs + max(0, w.durationMs)
            if posMs >= w.startMs && posMs < end {
                let sinceOnset = Double(posMs - w.startMs)
                return 1 + onsetBoost * exp(-sinceOnset / attackMs)
            }
            if end <= posMs {
                lastEndBefore = max(lastEndBefore ?? end, end)
            }
        }
        guard let lastEnd = lastEndBefore else { return gapFloor }
        let sinceRelease = Double(posMs - lastEnd)
        return gapFloor + (1 - gapFloor) * exp(-sinceRelease / releaseMs)
    }
}
