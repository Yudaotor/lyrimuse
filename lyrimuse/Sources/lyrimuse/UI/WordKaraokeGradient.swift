import SwiftUI
import LyrimuseCore

// 逐字卡拉OK"软边渐变"的 **SwiftUI 绑定层**:把 KaraokeFill 算好的分段变成
// LinearGradient。悬浮歌词(LyricsOverlayView)、灵动岛(NotchLyricsView)、歌词窗口
// (LyricsWindowView)三处共用同一份,不再各自维护、也不会有观感不一致的问题。
//
// 算法本体在 LyrimuseCore/Lyrics/KaraokeFill.swift —— 这里只剩"分段 → 颜色"的映射,
// 薄到没有任何判断逻辑,所以它是**故意不测**的那一层(能测的都在 Core 那边被 selftest
// 钉住了)。外层容器/描边这些跟具体窗口形态相关的处理各自留在各自的 View 里。
enum WordKaraokeGradient {
    // 转发给算法本体,免得三处调用点都要多 import 一层 / 记两个名字。
    static let minWordDurationMs = KaraokeFill.minWordDurationMs
    static let wordEdgeSoftenBand = KaraokeFill.wordEdgeSoftenBand

    static func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        KaraokeFill.fillFraction(for: w, atMs: ms)
    }

    /// 逐字填色的刷新上限,三处逐字视图(悬浮歌词/灵动岛/歌词窗口)共用。
    ///
    /// 不用裸 `.animation`(=显示器刷新率,这台机器上是 ProMotion 120Hz):2026-08-14 用
    /// sample 实测,播一首有逐字歌词的歌时主线程**跑满 100%**(idle 采样数为 0),全部耗在
    /// 每帧重建整行 Text 的 DisplayList 上 —— 一行十几二十个字,每个字一个带渐变的 Text,
    /// 一秒 120 次。主线程被占死之后,真正让人有"卡顿感"的是**换行时那段滚动动画**没有
    /// 主线程时间可用,一顿一顿。
    ///
    /// 30Hz 对一道横向扫过的填色边缘完全够看(电影是 24),但把这一块的成本直接砍到 1/4,
    /// 换来的是滚动/淡入淡出这些**整页**动画重新流畅。这是一笔明确的取舍,不是抠细节。
    ///
    /// ⚠️ 2026-08-15 补:这个上限原本只加在歌词窗口上,悬浮歌词和灵动岛漏掉了整整一天 ——
    /// 而常驻显示的恰恰是悬浮窗。补齐时**只改帧率、没有下沉 TimelineView**,理由见
    /// LyricsOverlayView.mainLine 里对应的那段注释。
    static let refreshInterval: Double = 1.0 / 30.0

    // 已唱过的部分是 fg 全强度,未唱到的部分是同一个 fg 的 35% 透明度,没有单独的
    // "进度色"参数。用渐变整体当文字颜色,而不是叠两层 Text + GeometryReader 手算裁剪
    // 宽度——渐变的 stop 位置直接由调用方每帧算出的真实进度决定,不需要额外插值。
    private static let dimOpacity: Double = 0.35

    static func gradient(fg: Color, left: Double, right: Double) -> LinearGradient {
        let stops = KaraokeFill.stops(left: left, right: right).map { stop in
            Gradient.Stop(
                color: fg.opacity(dimOpacity + stop.intensity * (1 - dimOpacity)),
                location: stop.location)
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }
}
