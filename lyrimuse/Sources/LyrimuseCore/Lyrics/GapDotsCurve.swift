import Foundation

/// 前奏/间奏「•••」三颗呼吸圆点的曲线。悬浮歌词 / 灵动岛 / 菜单栏共用上半部分 —— 前两面走
/// SwiftUI 的 `LyricsGapDotsView`,菜单栏那一面是 CALayer 手排(状态栏项里没有活的 SwiftUI 视图
/// 可挂,见 `MenuBarScrollingLabel` 头注),**视图搬不过去,曲线必须搬**,否则两套渲染的呼吸节奏
/// 迟早各漂各的。歌词窗口走下半部分 `window*` 那一份(同一个视图,`.window` 样式)。
///
/// 上半部分的常数拿真机跟 Apple Music 歌词页对拍量出来:整体同步放大缩小(不是错峰的打字提示器
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

    /// 第 `dot` 颗点此刻点亮了多少,0…1:第 i 颗在间奏进行到 i/3 之后开始,到 (i+1)/3 满。
    public static func lit(dot: Int, progress: Double) -> Double {
        min(1, max(0, progress * Double(dotCount) - Double(dot)))
    }

    /// 第 `dot` 颗点此刻的不透明度。第 i 颗在间奏进行到 i/3 之后开始点亮,亮度平滑爬升。
    public static func opacity(dot: Int, progress: Double) -> Double {
        opacityFloor + opacitySpan * lit(dot: dot, progress: progress)
    }

    /// 某颗点从 `fromMs` 到间奏结束的亮度关键帧 `(ms, opacity)`,线性插值即精确:progress 线性于时间,
    /// `opacity(dot:progress:)` 只在 progress = dot/n、(dot+1)/n 处折一下。给 `LyricsGapDotsView` 交给
    /// Core Animation 播(关键帧之间 CA 线性插值)。`fromMs` 已到或过了结束时间时返回空。
    public static func opacityKeyframes(dot: Int, startMs: Int, endMs: Int, fromMs: Double) -> [(ms: Double, opacity: Double)] {
        keyframes(dot: dot, startMs: startMs, endMs: endMs, fromMs: fromMs) { opacity(dot: dot, progress: $0) }
    }

    /// 关键帧时刻只看点亮进度在哪儿折(i/3、(i+1)/3),跟地板取多少无关;两种亮度共用这一份。
    private static func keyframes(dot: Int, startMs: Int, endMs: Int, fromMs: Double,
                                  opacityAt: (Double) -> Double) -> [(ms: Double, opacity: Double)] {
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
            (t, opacityAt(progress(posMs: Int(t.rounded()), startMs: startMs, endMs: endMs)))
        }
    }

    // MARK: - 歌词窗口

    /// 歌词窗口的三颗点照 Apple Music 歌词页同窗口录屏:按间奏进度逐颗点亮,还没轮到的点更淡(07 章决策 105);
    /// 大小另走一条曲线(07 章决策 91)。排版尺寸是最小那一档,倍率在 1…`windowPeakScale` 之间:出现时 `windowAppearScale`,
    /// `windowAppearMs` 内涨到顶;之后以 `windowBreathePeriodMs` 为周期从顶上缓缓缩到 1 再涨回;
    /// 离结束 `windowSwellMs` 起涨回顶,停在顶上等收起。
    public static let windowPeakScale = 1.35
    public static let windowAppearScale = 1.19
    public static let windowAppearMs = 1500.0
    public static let windowBreathePeriodMs = 8000.0
    public static let windowSwellMs = 1000.0
    /// 涨回顶在 `windowSwellMs` 这一段的哪个比例处到位。
    private static let windowSwellReach = 0.85

    /// 歌词窗口还没轮到的点的不透明度:Apple 同窗口录屏里停在歌曲开头时,前奏三颗都约为 12% 的白。
    public static let windowOpacityFloor = 0.12

    /// 歌词窗口第 `dot` 颗点此刻的不透明度:点亮进度同 `opacity(dot:progress:)`,地板换成 `windowOpacityFloor`。
    public static func windowOpacity(dot: Int, progress: Double) -> Double {
        windowOpacityFloor + (1 - windowOpacityFloor) * lit(dot: dot, progress: progress)
    }

    /// `windowOpacity` 的关键帧,时刻同 `opacityKeyframes`。
    public static func windowOpacityKeyframes(dot: Int, startMs: Int, endMs: Int, fromMs: Double) -> [(ms: Double, opacity: Double)] {
        keyframes(dot: dot, startMs: startMs, endMs: endMs, fromMs: fromMs) { windowOpacity(dot: dot, progress: $0) }
    }

    /// 歌词窗口三颗点此刻的倍率。`reduceMotion` 为真时恒 1。
    public static func windowScale(atMs posMs: Double, startMs: Int, endMs: Int, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion else { return 1 }
        let peak = windowPeakScale
        let t = max(0, posMs - Double(startMs))
        var scale: Double
        if t < windowAppearMs {
            let k = t / windowAppearMs
            scale = windowAppearScale + (peak - windowAppearScale) * (1 - (1 - k) * (1 - k))
        } else {
            let phase = (t - windowAppearMs) / windowBreathePeriodMs
            scale = 1 + (peak - 1) * (0.5 + 0.5 * cos(2 * .pi * phase))
        }
        let remaining = Double(endMs) - posMs
        if remaining < windowSwellMs {
            let k = min(1, max(0, (1 - remaining / windowSwellMs) / windowSwellReach))
            scale += (peak - scale) * k * k * (3 - 2 * k)
        }
        return scale
    }

    /// 第 `dot` 颗点在倍率 `scale` 下横向要挪多少(跟 `dotSize` 同单位):每颗绕自己的中心放大,
    /// 两侧的再往外挪,点与点的间隙不变,整组绕中间那颗张开。
    public static func windowOffset(dot: Int, scale: Double, dotSize: Double) -> Double {
        (Double(dot) - Double(dotCount - 1) / 2) * (scale - 1) * dotSize
    }
}
