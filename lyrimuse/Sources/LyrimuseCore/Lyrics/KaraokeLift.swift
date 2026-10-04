import Foundation

/// 歌词窗口里正在唱的词往上浮的曲线和高度(07 章决策 82)。参数照 Apple Music 实测拟合:不管词唱多长,
/// 都是同一条阻尼弹簧(固有频率 3.65 rad/s、阻尼比 0.9)从开唱那一刻起浮 —— 起步慢慢加速,
/// 约 0.44 秒到一半、0.93 秒到九成,`durationMs` 时到顶,之后保持。
public enum KaraokeLift {
    /// 浮起高度,按字号比例。
    public static let amplitudeEm = 0.06
    /// 从开唱到浮到顶的毫秒数。弹簧在这一刻约到 99%,整条曲线按它归一,到点正好是 1。
    public static let durationMs = 1400

    private static let omega = 3.65
    private static let damping = 0.9

    /// 开唱后 `elapsedMs` 毫秒时浮起的比例:开唱前是 0,到 `durationMs` 起恒为 1,中间一路往上
    /// (阻尼比 0.9 的弹簧第一次越过终点要到 1.97 秒,`durationMs` 之内不回头)。
    public static func progress(elapsedMs: Double) -> Double {
        guard elapsedMs > 0 else { return 0 }
        guard elapsedMs < Double(durationMs) else { return 1 }
        return spring(seconds: elapsedMs / 1000) / spring(seconds: Double(durationMs) / 1000)
    }

    /// 一行里每个字都浮到顶的那一刻(歌词时间轴毫秒):最后一个词唱完,再走一整段上浮。
    /// 长音词逐字形错开时最后一个字形也在词尾之前起浮(见 `LyricsWordEmphasis.glyphWindow`),包在里面。
    public static func lineSettledMs(words: [SyncedLyricWord]) -> Int {
        (words.map { $0.startMs + max(1, $0.durationMs) }.max() ?? 0) + durationMs
    }

    private static func spring(seconds t: Double) -> Double {
        let decay = damping * omega
        let wd = omega * (1 - damping * damping).squareRoot()
        return 1 - exp(-decay * t) * (cos(wd * t) + decay / wd * sin(wd * t))
    }
}
