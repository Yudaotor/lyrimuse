import CoreGraphics
import Foundation

/// 首启引导第一页的开场:灵动岛弹开唱一句、桌面歌词同步,歌词化成光点吸回灵动岛,刘海滴出光球落成图标。
/// 见 14 章决策 109。
///
/// 整段按时间算:界面层(`OnboardingIntroView`)每帧拿开场开始后的秒数来问这里每样东西此刻的进度,自己不存中间状态。
/// 各部分因此永远同步(扫光走到哪根弦就拨哪根、光点什么时候到灵动岛),「跳过」只是不再画它。
/// 时间点和缓动曲线照设计稿定稿版(`Lyrimuse资料/13-设计稿-设置与引导/` 下的引导动效样稿)。
public enum OnboardingIntro {
    // MARK: - 缓动

    /// CSS 的 `cubic-bezier(x1, y1, x2, y2)`,同 WebKit `UnitBezier` 的解法:先按 x 反解参数 t,再取 y。
    public struct Curve: Sendable {
        private let cx, bx, ax, cy, by, ay: Double

        public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            cx = 3 * x1
            bx = 3 * (x2 - x1) - cx
            ax = 1 - cx - bx
            cy = 3 * y1
            by = 3 * (y2 - y1) - cy
            ay = 1 - cy - by
        }

        /// 收尾很柔的减速,多数位移、淡入用它。
        public static let ease = Curve(0.22, 1, 0.36, 1)
        /// 带一点点回弹(过冲不到 1%),灵动岛展开 / 收起、叶子长出来用它。
        public static let soft = Curve(0.3, 1.16, 0.5, 1)
        public static let easeOut = Curve(0, 0, 0.58, 1)
        public static let easeInOut = Curve(0.42, 0, 0.58, 1)

        public func callAsFunction(_ x: Double) -> Double {
            let x = min(max(x, 0), 1)
            return sampleY(solveT(x))
        }

        private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
        private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
        private func slopeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

        private func solveT(_ x: Double) -> Double {
            var t = x
            for _ in 0..<8 {
                let error = sampleX(t) - x
                if abs(error) < 1e-7 { return t }
                let slope = slopeX(t)
                if abs(slope) < 1e-6 { break }
                t -= error / slope
            }
            // 牛顿法不收敛时退回二分。
            var lo = 0.0, hi = 1.0
            t = x
            for _ in 0..<40 {
                let value = sampleX(t)
                if abs(value - x) < 1e-7 { return t }
                if value < x { lo = t } else { hi = t }
                t = (lo + hi) / 2
            }
            return t
        }
    }

    /// 时间轴上的一段:从 `start` 秒起、历时 `duration` 秒。
    public struct Segment: Equatable, Sendable {
        public let start: Double
        public let duration: Double

        public init(_ start: Double, _ duration: Double) {
            self.start = start
            self.duration = duration
        }

        public var end: Double { start + duration }

        /// 0...1 的线性进度,段前恒 0、段后恒 1。
        public func progress(_ t: Double) -> Double {
            guard duration > 0 else { return t >= start ? 1 : 0 }
            return min(max((t - start) / duration, 0), 1)
        }

        public func progress(_ t: Double, _ curve: Curve) -> Double { curve(progress(t)) }
    }

    /// 关键帧插值:`frames` 按 x 升序,x、y 都在 0...1 区间里取;每两帧之间套 `curve`(同 CSS 动画的 timing function)。
    public static func keyframes(_ x: Double, _ frames: [(x: Double, y: Double)], curve: Curve = .easeOut) -> Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for i in 1..<frames.count where x <= frames[i].x {
            let a = frames[i - 1], b = frames[i]
            let span = b.x - a.x
            let local = span > 0 ? (x - a.x) / span : 1
            return a.y + (b.y - a.y) * curve(local)
        }
        return last.y
    }

    // MARK: - 时间轴(秒)

    /// 刘海淡入。开场一开始刘海就在窗口顶上。
    public static let notchIn = Segment(0, 0.3)
    /// 暮光底上的光晕亮起来。
    public static let glowIn = Segment(0.04, 1.1)
    /// 里拉琴开始描线的时刻;各笔按 `lyreStrokeDelays` 错开。
    public static let lyreDrawStart = 0.04
    public static let lyreStrokeDuration = 0.9
    /// 琴角尖两颗小星开始闪的时刻和周期。
    public static let sparkStarts: [Double] = [0.84, 1.54]
    public static let sparkPeriod = 1.4
    /// 灵动岛照真的样子分两步展开:先从刘海两侧长出耳朵(左耳封面、右耳音量条),再往下长出一行放歌词。
    public static let islandEarsOpen = Segment(0.18, 0.55)
    public static let islandEarsIn = Segment(0.3, 0.3)
    public static let islandDrop = Segment(0.42, 0.6)
    public static let islandLyricIn = Segment(0.55, 0.3)
    /// 从灵动岛往下淌的一束柔光。
    public static let beam = Segment(0.42, 1.2)
    /// 桌面歌词浮上来。
    public static let deskIn = Segment(0.52, 0.9)
    /// 灵动岛和桌面两处同步扫光唱这一句。
    public static let sing = Segment(0.72, 1.2)
    /// 第 i 根弦被拨响的时刻,跟扫光的进度大致对上。
    public static func pluckStart(_ string: Int) -> Double { 0.78 + Double(string) * 0.23 }
    public static let pluckDuration = 0.56
    public static let stringCount = 5
    /// 唱完:歌词碎成光点、里拉琴淡去、音量条跳快。
    public static let burstStart = 1.95
    /// 第 i 个字开始消散。
    public static func charDissolveStart(_ index: Int) -> Double { burstStart + 0.03 + Double(index) * 0.03 }
    /// 光点陆续到了,灵动岛背后亮起一圈光。
    public static let absorb = Segment(2.43, 0.5)
    /// 灵动岛收回刘海:先收起歌词那一行,再收起耳朵。
    public static let bloomStart = 2.8
    public static let islandDropClose = Segment(2.8, 0.45)
    public static let islandEarsClose = Segment(2.95, 0.45)
    /// 灵动岛收耳朵的同时,刘海里挤出一颗光球,一口气落到图标的位置、边落边长成图标(中间不停顿、不分两段)。
    public static let orbFlight = Segment(2.95, 0.85)
    /// 落地:闪一下柔光、开场底色褪掉(窗口亮灯)。
    public static let flash = Segment(3.72, 1.2)
    public static let nightOut = Segment(3.76, 0.75)
    /// 欢迎页的内容开始进场、真图标接替光球。等底色基本褪干净再进场,字不会隔着半透明的底色发虚。
    public static let handoff = 3.95
    /// 开场的视图可以整个摘掉的时刻(闪光收干净)。
    public static let end = 5.0

    /// 里拉琴各笔的描线延迟:两只琴臂、琴腹、横梁、琴码,然后五根弦。
    public static let lyreStrokeDelays: [Double] = [0, 0, 0.12, 0.26, 0.32] + (0..<stringCount).map { 0.42 + Double($0) * 0.06 }

    // MARK: - 各部分此刻的值

    /// 开场底色的不透明度:开场全程 1,落地时褪到 0。
    public static func nightOpacity(_ t: Double) -> Double { 1 - nightOut.progress(t, .ease) }

    /// 光晕的不透明度:亮到 0.35;落地时提到 0.6 衬一下闪光,随后褪掉(欢迎页另有一层静止的淡光晕接着)。
    public static func glowOpacity(_ t: Double) -> Double {
        let lit = 0.35 * glowIn.progress(t, .ease)
        let boost = 0.25 * Segment(flash.start, 0.8).progress(t, .ease)
        let fade = Segment(3.9, 1.0).progress(t, .ease)
        return (lit + boost) * (1 - fade)
    }

    /// 里拉琴第 i 笔描到哪(0...1)。
    public static func lyreStroke(_ index: Int, _ t: Double) -> Double {
        let delay = index < lyreStrokeDelays.count ? lyreStrokeDelays[index] : 0
        return Segment(lyreDrawStart + delay, lyreStrokeDuration).progress(t, .ease)
    }

    /// 里拉琴淡去的进度(0 = 还在、1 = 没了)。
    public static func lyreOut(_ t: Double) -> Double { Segment(burstStart, 0.7).progress(t, .ease) }

    /// 小星闪烁:返回缩放(0 = 还没出现)。
    public static func sparkScale(_ index: Int, _ t: Double) -> Double {
        guard index < sparkStarts.count, t >= sparkStarts[index] else { return 0 }
        let phase = ((t - sparkStarts[index]) / sparkPeriod).truncatingRemainder(dividingBy: 1)
        let wave = phase < 0.5 ? Curve.easeInOut(phase * 2) : Curve.easeInOut((1 - phase) * 2)
        return 0.35 + 0.65 * wave
    }

    /// 第 i 根弦此刻横向偏多少(pt)和发白多少(0...1)。没拨或拨完返回 (0, 0)。
    public static func pluck(_ string: Int, _ t: Double) -> (offset: Double, white: Double) {
        let segment = Segment(pluckStart(string), pluckDuration)
        guard t >= segment.start, t <= segment.end else { return (0, 0) }
        let x = segment.progress(t)
        let offset = keyframes(x, [(0, 0), (0.12, 2), (0.24, -1.6), (0.38, 1.2), (0.52, -0.8), (0.7, 0.4), (1, 0)])
        return (offset, 1 - Curve.easeOut(x))
    }

    /// 柔光往下伸出来的比例和不透明度。
    public static func beamState(_ t: Double) -> (scale: Double, opacity: Double) {
        let x = beam.progress(t)
        guard t >= beam.start else { return (0, 0) }
        let scale = keyframes(x, [(0, 0), (0.6, 0.94), (1, 1)])
        let opacity = keyframes(x, [(0, 0), (0.3, 0.9), (1, 0)])
        return (scale, opacity)
    }

    /// 桌面歌词入场:不透明度、往上浮的距离(pt,从 18 到 0)、缩放(0.94 → 1)。不做模糊入场:模糊半径逐帧变,这一行字和
    /// 它的两层光晕每帧都要重新模糊一遍,Instruments 里这一下是 80ms 级的卡顿。
    public static func deskState(_ t: Double) -> (opacity: Double, rise: Double, scale: Double) {
        let move = deskIn.progress(t, .ease)
        let fade = Segment(deskIn.start, 0.8).progress(t, .ease)
        return (fade, 18 * (1 - move), 0.94 + 0.06 * move)
    }

    /// 唱完这句消散:一道软边从左往右扫过整行,扫过的字淡掉(第 i 个字被扫到的时刻跟它的光点出发对得上)。返回软边扫到
    /// 哪儿(0 = 还没开始,1 = 整行扫完,中间按「行宽 + 两倍软边」折算)和整行往上飘的距离(pt)。
    ///
    /// 整行一个遮罩,不是一个字一个视图各自缩放、淡出:逐字动画每帧都要重画那一行字和它的两层光晕,碎裂这一段会掉帧。
    public static func dissolve(_ t: Double, charCount: Int) -> (front: Double, lift: Double) {
        let span = Double(max(charCount, 1)) * 0.03 + 0.35
        let p = Segment(charDissolveStart(0), span).progress(t, .ease)
        return (p, 8 * p)
    }

    /// 扫光前沿那道亮光的不透明度(唱到最后 12% 渐隐)。
    public static func shineOpacity(_ t: Double) -> Double {
        guard t >= sing.start, t <= sing.end else { return 0 }
        let x = sing.progress(t)
        return x < 0.88 ? 1 : 1 - (x - 0.88) / 0.12
    }

    /// 灵动岛此刻的尺寸:刘海 → 长出耳朵(`earsWidth`,高度不变)→ 往下长出歌词那一行(`openWidth` × `openHeight`,
    /// 宽度由界面按歌词实际宽度给)→ 倒着收回刘海。光点吸进来时尺寸不变(只在背后亮一圈光):尺寸一变玻璃和阴影
    /// 每帧都要重算,碎裂这一段会掉帧;也不做横竖不等的缩放(那会把形状拉变形)。
    public static func islandSize(_ t: Double, notch: CGSize, earsWidth: Double, openWidth: Double, openHeight: Double) -> CGSize {
        let ears = islandEarsOpen.progress(t, .soft) - islandEarsClose.progress(t, .soft)
        let drop = islandDrop.progress(t, .soft) - islandDropClose.progress(t, .soft)
        let collapsed = Double(notch.width) + (earsWidth - Double(notch.width)) * ears
        let width = collapsed + (max(openWidth, earsWidth) - earsWidth) * drop
        let height = Double(notch.height) + (openHeight - Double(notch.height)) * drop
        return CGSize(width: width, height: height)
    }

    /// 耳朵里那两样(封面、音量条)的不透明度:耳朵长出来时淡入,开始收耳朵时淡出。
    public static func islandEarsOpacity(_ t: Double) -> Double {
        islandEarsIn.progress(t, .ease) * (1 - Segment(islandEarsClose.start, 0.2).progress(t, .ease))
    }

    /// 灵动岛里歌词那一行的不透明度:展开后淡入,收回时淡出。不做模糊入场,理由同 `deskState`。
    public static func islandLyricOpacity(_ t: Double) -> Double {
        islandLyricIn.progress(t, .ease) * (1 - Segment(islandDropClose.start, 0.2).progress(t, .ease))
    }

    /// 灵动岛整体不透明度:开场淡入,落地亮灯时淡出。
    public static func islandOpacity(_ t: Double) -> Double {
        notchIn.progress(t, .ease) * (1 - Segment(flash.start, 0.3).progress(t, .ease))
    }

    /// 光点吸进来时灵动岛背后那圈光的亮度(0...1),收回刘海时退回去。
    public static func absorbAmount(_ t: Double) -> Double {
        absorb.progress(t, .ease) * (1 - Segment(bloomStart, 0.5).progress(t, .ease))
    }

    /// 音量条的跳动快慢:唱完到收回之间跳得飞快。
    public static func isHype(_ t: Double) -> Bool { t >= burstStart && t < bloomStart }

    /// 光球此刻的圆心、直径、圆角、不透明度、图标显出多少,以及刚挤出刘海时的拉长量(0...1,像一滴水先拉长再回弹)。
    /// `notchBottom` 是刘海底边的 y,`target` 是图标中心。
    ///
    /// 一段走完:位置先慢后快再慢(`flightPath`),直径越到后面长得越快(`flightGrowth`);后半程圆角从正圆收到图标那档 21,
    /// 图标从一半处开始浮现、跟光球交叠着换过去,不是到点一下子换掉。
    public static func orbState(_ t: Double, centerX: Double, notchBottom: Double, target: CGPoint)
        -> (center: CGPoint, diameter: Double, radius: Double, opacity: Double, icon: Double, stretch: Double)
    {
        let p = orbFlight.progress(t)
        let duration = orbFlight.duration
        let opacity = Segment(orbFlight.start, 0.15).progress(t, .ease)
        let move = flightPath(p)
        let startY = notchBottom - 4
        let x = centerX + (Double(target.x) - centerX) * move
        let y = startY + (Double(target.y) - startY) * move
        let diameter = 14 + (84 - 14) * flightGrowth(p)
        let round = Segment(orbFlight.start + duration * 0.45, duration * 0.55).progress(t, .ease)
        // 圆角从正圆(直径一半)收到图标那档 21。
        let radius = diameter / 2 + (21 - diameter / 2) * round
        let icon = Segment(orbFlight.start + duration * 0.5, duration * 0.4).progress(t, .ease)
        let stretch = t >= orbFlight.start ? 1 - Segment(orbFlight.start, 0.25).progress(t, .ease) : 0
        return (CGPoint(x: x, y: y), diameter, radius, opacity, icon, stretch)
    }

    /// 光球位置:先慢后快再慢。
    public static let flightPath = Curve(0.45, 0, 0.25, 1)
    /// 光球直径:前面长得慢、越到后面长得越快,落地时收住。
    public static let flightGrowth = Curve(0.55, 0, 0.3, 1)

    /// 落地闪光的不透明度。
    public static func flashOpacity(_ t: Double) -> Double {
        guard t >= flash.start else { return 0 }
        return keyframes(flash.progress(t), [(0, 0), (0.3, 0.85), (1, 0)])
    }

    /// 音量条第 i 根的高度比例(0.25...1)。
    public static func equalizerBar(_ index: Int, _ t: Double) -> Double {
        let periods = [0.8, 0.55, 0.7, 0.45]
        let period = isHype(t) ? 0.16 : periods[index % periods.count]
        // 来回跳(同 CSS `alternate`):半个周期升、半个周期降。
        let phase = (t / period + Double(index) * 0.37).truncatingRemainder(dividingBy: 2)
        let x = phase < 1 ? phase : 2 - phase
        return 0.25 + 0.75 * Curve.easeInOut(x)
    }

    // MARK: - 光点

    /// 一颗光点:从某个字里出发,沿二次贝塞尔加速飞进灵动岛。时间都相对 `burstStart`。
    public struct Particle: Equatable, Sendable {
        public let origin: CGPoint
        public let control: CGPoint
        public let delay: Double
        public let duration: Double
        public let size: Double
        public let colorIndex: Int
    }

    /// 每个字拆出多少颗光点。英文那句二十多个字符,再多这一段就开始掉帧。
    public static let particlesPerChar = 10
    public static let particleColorCount = 4

    /// 把一句歌词拆成光点。`charSpans` 是每个字在画面里的横向范围(界面按字体量出来),`lineTop` / `lineHeight` 是这行字的竖向范围。
    public static func particles(charSpans: [ClosedRange<Double>], lineTop: Double, lineHeight: Double,
                                 target: CGPoint, seed: UInt64) -> [Particle] {
        var rng = SeededRandom(seed: seed)
        var result: [Particle] = []
        result.reserveCapacity(charSpans.count * particlesPerChar)
        let tx = Double(target.x), ty = Double(target.y)
        for (index, span) in charSpans.enumerated() {
            for k in 0..<particlesPerChar {
                let x0 = span.lowerBound + rng.unit() * (span.upperBound - span.lowerBound)
                let y0 = lineTop + rng.unit() * lineHeight
                let cx = (x0 + tx) / 2 + (rng.unit() - 0.5) * 260
                let cy = (y0 + ty) / 2 + (rng.unit() - 0.3) * 90
                result.append(Particle(
                    origin: CGPoint(x: x0, y: y0),
                    control: CGPoint(x: cx, y: cy),
                    delay: Double(index) * 0.03 + rng.unit() * 0.1,
                    duration: 0.52 + rng.unit() * 0.26,
                    size: 0.8 + rng.unit() * 2.2,
                    colorIndex: k % particleColorCount))
            }
        }
        return result
    }

    /// 一颗光点在 `sinceBurst` 秒时的位置、拖尾起点和不透明度;还没出发或已经到了返回 nil。
    public static func particleState(_ p: Particle, sinceBurst: Double, target: CGPoint)
        -> (point: CGPoint, tail: CGPoint, alpha: Double)?
    {
        let t = (sinceBurst - p.delay) / p.duration
        guard t >= 0, t <= 1 else { return nil }
        func position(_ s: Double) -> CGPoint {
            // 越飞越快:进度三次方。
            let u = s * s * s
            let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, c = u * u
            return CGPoint(x: a * Double(p.origin.x) + b * Double(p.control.x) + c * Double(target.x),
                           y: a * Double(p.origin.y) + b * Double(p.control.y) + c * Double(target.y))
        }
        let alpha = t < 0.15 ? t / 0.15 : 1 - max(0, (t - 0.8) / 0.2)
        return (position(t), position(max(0, t - 0.14)), alpha)
    }

    /// 最后一颗光点到达的时刻(相对 `burstStart`)。
    public static func particlesDuration(_ particles: [Particle]) -> Double {
        particles.map { $0.delay + $0.duration }.max() ?? 0
    }
}

// MARK: - 月桂冠

/// 欢迎页图标外圈的月桂冠:两根枝从图标下方往两侧上方弯,每个节点一对叶子,越往枝头越小,枝头一片顶叶。
/// 坐标在 `box` 见方的画布里,图标(`iconSide` 见方)居中;叶子与图标至少隔 `minimumClearance`。见 14 章决策 109。
public enum LaurelWreath {
    public static let box: Double = 176
    public static let iconSide: Double = 84
    public static let minimumClearance: Double = 6

    /// 两根枝,各是一段三次贝塞尔(起点、两个控制点、终点)。
    public static let stems: [[CGPoint]] = [
        [CGPoint(x: 80, y: 164), CGPoint(x: 26, y: 160), CGPoint(x: 8, y: 100), CGPoint(x: 34, y: 40)],
        [CGPoint(x: 96, y: 164), CGPoint(x: 150, y: 160), CGPoint(x: 168, y: 100), CGPoint(x: 142, y: 40)],
    ]

    /// 每根枝上的节点数(每个节点一对叶子)。
    public static let nodesPerStem = 7
    /// 叶子朝枝的方向往两侧撇开的角度。
    public static let splayDegrees: Double = 34
    /// 叶子本身的长度(画成朝上的杏仁形,底在原点、尖在 (0, -leafLength))和最宽处的半宽。
    public static let leafLength: Double = 13
    public static let leafHalfWidth: Double = 2.1

    public struct Leaf: Equatable, Sendable {
        /// 叶底。
        public let base: CGPoint
        /// 叶尖朝向,弧度,0 = 朝上(-y),顺时针为正。
        public let angle: Double
        public let scale: Double
        /// 第几对(从枝底往上 1、2、3…,顶叶最后),决定长出来的先后。
        public let order: Int
    }

    public static func point(on stem: [CGPoint], _ t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * Double(stem[0].x) + b * Double(stem[1].x) + c * Double(stem[2].x) + d * Double(stem[3].x),
                       y: a * Double(stem[0].y) + b * Double(stem[1].y) + c * Double(stem[2].y) + d * Double(stem[3].y))
    }

    /// 枝在 t 处的走向,换成「叶尖朝上转多少能对齐它」的弧度。
    private static func alongAngle(_ stem: [CGPoint], _ t: Double) -> Double {
        let p = point(on: stem, t), q = point(on: stem, min(1, t + 0.01))
        let r = t + 0.01 > 1 ? point(on: stem, t - 0.01) : p
        let (from, to) = t + 0.01 > 1 ? (r, p) : (p, q)
        return atan2(Double(to.y - from.y), Double(to.x - from.x)) + .pi / 2
    }

    public static let leaves: [Leaf] = {
        var result: [Leaf] = []
        let splay = splayDegrees * .pi / 180
        for stem in stems {
            for i in 1...nodesPerStem {
                let t = Double(i) / (Double(nodesPerStem) + 0.5)
                let base = point(on: stem, t)
                let along = alongAngle(stem, t)
                let scale = 1 - t * 0.35
                result.append(Leaf(base: base, angle: along - splay, scale: scale, order: i))
                result.append(Leaf(base: base, angle: along + splay, scale: scale, order: i))
            }
            result.append(Leaf(base: point(on: stem, 1), angle: alongAngle(stem, 1), scale: 0.62, order: nodesPerStem + 1))
        }
        return result
    }()

    /// 叶子轮廓上的几个特征点(叶底、两侧最宽处、叶尖),给「离图标多远」的检查用。
    public static func outline(_ leaf: Leaf) -> [CGPoint] {
        let local: [(Double, Double)] = [(0, 0), (-leafHalfWidth, -leafLength / 2), (leafHalfWidth, -leafLength / 2), (0, -leafLength)]
        return local.map { x, y in
            let sx = x * leaf.scale, sy = y * leaf.scale
            let c = cos(leaf.angle), s = sin(leaf.angle)
            return CGPoint(x: Double(leaf.base.x) + sx * c - sy * s, y: Double(leaf.base.y) + sx * s + sy * c)
        }
    }

    /// 图标在画布里的位置。
    public static var iconRect: CGRect {
        let inset = (box - iconSide) / 2
        return CGRect(x: inset, y: inset, width: iconSide, height: iconSide)
    }

    /// 长出来的时间轴(秒,从开始戴冠算起):枝描线,叶子一对对按 `order` 先后长出。
    public static let stemDraw = OnboardingIntro.Segment(0, 0.8)
    public static func leafGrowth(order: Int) -> OnboardingIntro.Segment { .init(Double(order) * 0.05 + 0.12, 0.56) }
    public static var growDuration: Double { leafGrowth(order: nodesPerStem + 1).end }
}
