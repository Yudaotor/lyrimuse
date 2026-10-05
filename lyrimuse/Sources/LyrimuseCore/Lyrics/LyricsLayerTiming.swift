import Foundation

/// 歌词窗口图层列表的时间轴:逐字填色、上浮、长音强调这几条「播放位置的纯函数」排成 Core Animation 的动画参数,
/// 装好之后由渲染服务逐帧插值、主线程不再参与。播放位置一律是歌词时间轴毫秒(含歌词偏移);换成墙钟秒 = 毫秒差 ÷ 1000 ÷ 速率。
/// 曲线本身不在这里:填色是 `KaraokeFill`,上浮是 `KaraokeLift`,强调是 `LyricsWordEmphasis`,这里只负责排时间。
public enum LyricsLayerTiming {
    /// 软边中心在词宽里的取值范围:中心 = −band 时整个词未唱、= 1 + band 时整个词唱完(`KaraokeFill.stops` 的两端快路径)。
    public static var unsungCenter: Double { -KaraokeFill.wordEdgeSoftenBand }
    public static var sungCenter: Double { 1 + KaraokeFill.wordEdgeSoftenBand }

    /// 一个词(或逐词罗马音那一组)的填色:软边中心对时间线性地从 `unsungCenter` 走到 `sungCenter`。
    public struct FillTrack: Equatable, Sendable {
        /// 走到 `unsungCenter` 那一刻离此刻多少墙钟秒;负数 = 已经开始走了。
        public let beginOffset: Double
        /// 从 `unsungCenter` 走到 `sungCenter` 要多少墙钟秒。
        public let duration: Double
    }

    /// `fillFraction` 对时间线性:中心 = (ms − 开始) ÷ 有效时长。中心从 −band 走到 1 + band,对应
    /// 开始前 band 个有效时长到唱完后 band 个有效时长。
    public static func fillTrack(startMs: Int, durationMs: Int, nowMs: Int, rate: Double) -> FillTrack {
        let effective = Double(max(durationMs, KaraokeFill.minWordDurationMs))
        let band = KaraokeFill.wordEdgeSoftenBand
        let r = rate > 0 ? rate : 1
        return FillTrack(beginOffset: (Double(startMs) - band * effective - Double(nowMs)) / 1000 / r,
                         duration: (1 + 2 * band) * effective / 1000 / r)
    }

    /// 某一刻软边中心的位置,夹在 [`unsungCenter`, `sungCenter`](两端之外画面不再变)。停着、定格、非当前行都用它画静态。
    public static func fillCenter(startMs: Int, durationMs: Int, atMs ms: Int) -> Double {
        let f = KaraokeFill.fillFraction(startMs: startMs, durationMs: durationMs, atMs: ms)
        return min(sungCenter, max(unsungCenter, f))
    }

    /// 一个会动的元素(整个词,或长音强调逐字形错开时的一个字形)此刻的姿态:往上抬多少(点,向上为正)、
    /// 绕锚点放大多少倍、辉光多亮。
    public struct Pose: Equatable, Sendable {
        public var lift: Double
        public var scale: Double
        public var glow: Double

        public init(lift: Double, scale: Double, glow: Double) {
            self.lift = lift
            self.scale = scale
            self.glow = glow
        }

        public static let rest = Pose(lift: 0, scale: 1, glow: 0)
    }

    /// 元素的动法:上浮从 `riseStartMs` 起走 `KaraokeLift` 那条曲线,高度 `amplitude`;`emphasis` 非 nil 时在这之上叠
    /// 长音强调(整词那版 `glyph` 为 nil,逐字形那版给出第几个字形、共几个)。
    public struct Motion: Equatable, Sendable {
        public var riseStartMs: Double
        public var amplitude: Double
        public var emphasis: LyricsWordEmphasis.Span?
        public var glyph: (index: Int, count: Int)?

        public init(riseStartMs: Double, amplitude: Double, emphasis: LyricsWordEmphasis.Span? = nil,
                    glyph: (index: Int, count: Int)? = nil) {
            self.riseStartMs = riseStartMs
            self.amplitude = amplitude
            self.emphasis = emphasis
            self.glyph = glyph
        }

        public static func == (a: Motion, b: Motion) -> Bool {
            a.riseStartMs == b.riseStartMs && a.amplitude == b.amplitude && a.emphasis == b.emphasis
                && a.glyph?.index == b.glyph?.index && a.glyph?.count == b.glyph?.count
        }

        /// 这一刻的姿态,跟 SwiftUI 版逐帧那份(`KaraokeWordText`)同一个算式:上浮 = 曲线进度 × 幅度,再加强调的额外上浮
        /// (同一个幅度);放大与辉光只在强调窗口里有。
        public func pose(atMs ms: Double) -> Pose {
            let rise = KaraokeLift.progress(elapsedMs: ms - riseStartMs) * amplitude
            guard let emphasis else { return Pose(lift: rise, scale: 1, glow: 0) }
            let f: LyricsWordEmphasis.Frame
            if let glyph {
                f = LyricsWordEmphasis.glyphFrame(for: emphasis, glyph: glyph.index, of: glyph.count, atMs: Int(ms.rounded()))
            } else {
                f = LyricsWordEmphasis.frame(for: emphasis, atMs: Int(ms.rounded()))
            }
            return Pose(lift: rise + f.extraLift * amplitude, scale: f.scale, glow: f.glow)
        }

        /// 姿态还在变的时段(歌词时间轴毫秒):上浮从起点走满 `KaraokeLift.durationMs`,强调走到词尾;之前之后都是常量。
        public var activeRangeMs: ClosedRange<Double> {
            var end = riseStartMs + Double(KaraokeLift.durationMs)
            var start = riseStartMs
            if let emphasis {
                start = min(start, Double(emphasis.startMs))
                end = max(end, Double(emphasis.endMs))
            }
            return start...end
        }
    }

    /// 把一段姿态变化采样成关键帧。`beginOffset`/`duration` 是墙钟秒(同 `FillTrack`),`keyTimes` 在 0…1。
    /// 曲线都是光滑的,按每秒 `samplesPerSecond` 个点采样、关键帧之间线性插值,误差远小于一个像素。
    public struct PoseTrack: Equatable, Sendable {
        public let beginOffset: Double
        public let duration: Double
        public let keyTimes: [Double]
        public let poses: [Pose]
    }

    public static let samplesPerSecond = 60.0

    /// `motion` 从此刻往后还在变的那一段排成关键帧;已经走完(此刻在变化段之后)返回 nil,画终态即可。
    /// 变化段开始得早于此刻时只排此刻之后那一截:关键帧从此刻的姿态起。
    public static func poseTrack(_ motion: Motion, nowMs: Int, rate: Double) -> PoseTrack? {
        let range = motion.activeRangeMs
        let now = Double(nowMs)
        guard now < range.upperBound else { return nil }
        let from = max(now, range.lowerBound)
        let lengthMs = range.upperBound - from
        guard lengthMs > 0 else { return nil }
        let r = rate > 0 ? rate : 1
        let count = max(2, Int((lengthMs / 1000 * samplesPerSecond).rounded(.up)) + 1)
        var keyTimes: [Double] = []
        var poses: [Pose] = []
        keyTimes.reserveCapacity(count)
        poses.reserveCapacity(count)
        for i in 0..<count {
            let k = Double(i) / Double(count - 1)
            keyTimes.append(k)
            poses.append(motion.pose(atMs: from + k * lengthMs))
        }
        return PoseTrack(beginOffset: (from - now) / 1000 / r, duration: lengthMs / 1000 / r,
                         keyTimes: keyTimes, poses: poses)
    }
}
