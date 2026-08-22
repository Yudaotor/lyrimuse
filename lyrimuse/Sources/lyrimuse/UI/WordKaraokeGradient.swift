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

    /// 逐字填色的刷新上限,逐帧重算式的逐字视图(悬浮歌词/灵动岛)共用。
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

    /// 歌词窗口专用档:60Hz(2026-08-21 五轮定稿)。这台面板 60Hz,窗口字号大(~50pt),
    /// 30Hz 下扫色边缘每步 ~10px 可感知;窗口的失效面经多轮审计已收窄到单个活跃词的叶子
    /// (见 LyricsWindowView.KaraokeWordText),60Hz 的代价约为悬浮窗整行 30Hz 的一小部分。
    /// ⚠️ 排程式(withAnimation 交给渲染管线插值)在 macOS 上实测**不可用**:SCK 逐帧探针
    /// 量得窗口只以 ~20Hz 提交(系统对长时程慢动画自动降档,无 API 干预;对照组悬浮窗
    /// TimelineView 30Hz 准点)——20Hz×14px 步进正是"卡顿感"本体。TimelineView 的频率
    /// 受控、实测准点,所以窗口回到逐帧重算,只是档位开到面板满刷新率。
    static let windowRefreshInterval: Double = 1.0 / 60.0

    // 已唱过的部分是 fg 全强度,未唱到的部分是同一个 fg 的 35% 透明度,没有单独的
    // "进度色"参数。用渐变整体当文字颜色,而不是叠两层 Text + GeometryReader 手算裁剪
    // 宽度——渐变的 stop 位置直接由调用方每帧算出的真实进度决定,不需要额外插值。
    // 非 private(2026-08-21):歌词窗口的排程式填色(两层 Text + mask,见
    // LyricsWindowView.KaraokeWordText)不再用这里的渐变,但暗色档必须跟这三处保持
    // 同一个数,直接引用同一份常量。
    static let dimOpacity: Double = 0.35

    static func gradient(fg: Color, left: Double, right: Double) -> LinearGradient {
        let stops = KaraokeFill.stops(left: left, right: right).map { stop in
            Gradient.Stop(
                color: fg.opacity(dimOpacity + stop.intensity * (1 - dimOpacity)),
                location: stop.location)
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    /// 一种前景色对应的**跨帧稳定**渐变素材(2026-08-20 性能审计)。
    ///
    /// 问题形状:三个整行 TimelineView 展示面(悬浮窗/灵动岛/菜单栏面板)每帧对每个词
    /// 现造 stops 数组 + LinearGradient(+AnyShapeStyle 装箱),而一行里任一时刻只有 ~1 个
    /// 词的过渡带真跟 [0,1] 相交 —— 其余词全是纯色态,输出与上一帧逐位相同。LinearGradient/
    /// AnyShapeStyle 含堆引用,SwiftUI 对 foregroundStyle 的判等走 memcmp,每帧新分配的
    /// 实例必不相等,~95% 的纯色词因此每帧被迫重走样式失效。这里把 dim(全未唱)/full
    /// (全唱过)两个纯色渐变按 fg 缓存成**同一份实例**跨帧复用,引用相等直接走快路径;
    /// 只有真在过渡带里的那个词才现算渐变。
    struct Palette {
        let fg: Color
        let dimStyle: AnyShapeStyle
        let fullStyle: AnyShapeStyle

        init(fg: Color) {
            self.fg = fg
            let dim = fg.opacity(WordKaraokeGradient.dimOpacity)
            dimStyle = AnyShapeStyle(LinearGradient(
                colors: [dim, dim], startPoint: .leading, endPoint: .trailing))
            fullStyle = AnyShapeStyle(LinearGradient(
                colors: [fg, fg], startPoint: .leading, endPoint: .trailing))
        }

        /// 纯色两端复用缓存实例,过渡带现算 —— 判据与 KaraokeFill.stops 的快路径完全一致。
        func style(left: Double, right: Double) -> AnyShapeStyle {
            if right <= 0 { return dimStyle }
            if left >= 1 { return fullStyle }
            return AnyShapeStyle(WordKaraokeGradient.gradient(fg: fg, left: left, right: right))
        }
    }

    // 小容量线性缓存,按 fg 相等命中(Color 不 Hashable,条目也就三五个:悬浮窗前景色、
    // 其 75% 罗马音色、灵动岛 accent、面板 .primary)。主线程专用(所有调用点都在
    // 视图 body/TimelineView 闭包里)。
    @MainActor private static var paletteCache: [Palette] = []

    @MainActor static func palette(fg: Color) -> Palette {
        if let hit = paletteCache.first(where: { $0.fg == fg }) { return hit }
        let p = Palette(fg: fg)
        paletteCache.append(p)
        // 换色场景(封面取色逐曲变)会让旧条目失去引用价值,别让它无限长。
        if paletteCache.count > 8 { paletteCache.removeFirst() }
        return p
    }
}
