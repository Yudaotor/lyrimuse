import Foundation

/// 前奏/间奏「•••」三颗呼吸圆点的曲线。四个展示面(悬浮歌词 / 歌词窗口 / 灵动岛 / 菜单栏)
/// 共用这一份 —— 前三面走 SwiftUI 的 `LyricsGapDotsView`,菜单栏那一面是 CALayer 手排
/// (状态栏项里没有活的 SwiftUI 视图可挂,见 `MenuBarScrollingLabel` 头注),**视图搬不过去,
/// 曲线必须搬**,否则两套渲染的呼吸节奏迟早各漂各的。
///
/// 常数都是拿真机跟 Apple Music 歌词页对拍量出来的:整体同步放大缩小(不是错峰的打字提示器
/// 波浪)、周期 7s、raised-cosine 平方逼近"停留久、鼓得快"的心跳感。
///
/// **相位与进度都从播放位置算,不从 wall clock 算**:暂停时位置冻住,三颗点就跟着冻住;
/// 拿系统时钟跑循环的话暂停了还在呼吸,而且跟同屏另一个展示面对不上拍。
public enum GapDotsCurve {
    public static let dotCount = 3

    /// 呼吸周期(毫秒)。
    public static let breathePeriodMs = 7000.0
    /// 呼吸的最小倍率与振幅。**下限不取 1.0 以下太多**:停留最久的正是贴地那一段,
    /// 尺寸太小会看不清是个圆。
    public static let breatheMin = 0.90
    public static let breatheSpan = 0.38

    /// 还没轮到的那几颗点的不透明度地板,以及点亮之后再爬升的幅度。地板不取 0 —— 三颗点
    /// 要一直看得见是三颗,点亮进度是叠在上面的第二层信号。
    public static let opacityFloor = 0.22
    public static let opacitySpan = 0.78

    /// 这一刻在这段间奏里走了多少,0…1。
    public static func progress(posMs: Int, startMs: Int, endMs: Int) -> Double {
        let span = max(1, endMs - startMs)
        return min(1, max(0, Double(posMs - startMs) / Double(span)))
    }

    /// 呼吸倍率,`breatheMin`…`breatheMin + breatheSpan`。`reduceMotion` 为真时恒 1
    /// (系统「减弱动态效果」开着就不呼吸,只留点亮进度)。
    public static func breathe(atMs posMs: Int, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion else { return 1 }
        let phase = Double(posMs).truncatingRemainder(dividingBy: breathePeriodMs) / breathePeriodMs
        let raised = pow(0.5 - 0.5 * cos(2 * .pi * phase), 2)
        return breatheMin + breatheSpan * raised
    }

    /// 第 `dot` 颗点此刻的不透明度。第 i 颗在间奏进行到 i/3 之后开始点亮,亮度平滑爬升。
    public static func opacity(dot: Int, progress: Double) -> Double {
        let lit = min(1, max(0, progress * Double(dotCount) - Double(dot)))
        return opacityFloor + opacitySpan * lit
    }

    /// 某颗点从 `fromMs` 到间奏结束的亮度关键帧 `(ms, opacity)`,线性插值即精确:progress 线性于时间,
    /// `opacity(dot:progress:)` 只在 progress = dot/n、(dot+1)/n 处折一下。给 `LyricsGapDotsView` 交给
    /// Core Animation 播(关键帧之间 CA 线性插值)。`fromMs` 已到或过了结束时间时返回空。
    public static func opacityKeyframes(dot: Int, startMs: Int, endMs: Int, fromMs: Double) -> [(ms: Double, opacity: Double)] {
        let end = Double(endMs)
        guard fromMs < end else { return [] }
        let span = Double(max(1, endMs - startMs))
        let n = Double(dotCount)
        var times: [Double] = [fromMs]
        for p in [Double(dot) / n, Double(dot + 1) / n] {
            let t = Double(startMs) + p * span
            if t > fromMs && t < end { times.append(t) }
        }
        times.append(end)
        return times.map { t in
            (t, opacity(dot: dot, progress: progress(posMs: Int(t.rounded()), startMs: startMs, endMs: endMs)))
        }
    }
}
