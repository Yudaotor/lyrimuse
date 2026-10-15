import AppKit
import LyrimuseCore
import SwiftUI

/// 首启引导第一页的开场,盖在整扇引导窗上(含标题栏那一截)。见 14 章决策 109。
///
/// 时间轴、曲线、光点和月桂冠的几何都在 core `OnboardingIntro` / `LaurelWreath`,这里只按「开场后第几秒」画:
/// 一个 `TimelineView` 每帧把秒数交给各部分,各部分没有自己的动画状态。开场期间藏起窗口标题(它在标题栏正中,
/// 会压在灵动岛上),摘掉时还原。点一下由宿主收掉(`onSkip`)。
///
/// 只动位置、缩放、透明度和遮罩宽度;发光、模糊都挂在内容不变的层上,不跟着每帧重画。
@MainActor
struct OnboardingIntroView: View {
    /// 唱的那一句(已按界面语言取好)。
    let line: String
    let start: Date
    /// 欢迎页图标中心,全局坐标(宿主从图标那边量来);光球落到这里、长成图标。
    let iconCenterGlobal: CGPoint
    /// 交接之后开场只剩闪光收尾,不再吃点击,欢迎页的控件已经能用。
    let interactive: Bool
    let onSkip: () -> Void

    @State private var cache = OnboardingIntroLayoutCache()

    /// 帧间隔上限 60Hz,理由同 `ConfettiOverlay.frameInterval`。
    private static let frameInterval: TimeInterval = 1.0 / 60.0

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let target = CGPoint(x: iconCenterGlobal.x - frame.minX, y: iconCenterGlobal.y - frame.minY)
            let layout = cache.layout(line: line, size: geo.size, target: target)
            TimelineView(.animation(minimumInterval: Self.frameInterval)) { context in
                OnboardingIntroFrame(layout: layout, t: context.date.timeIntervalSince(start))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSkip)
        .allowsHitTesting(interactive)
        .background(WindowTitleHider())
        // 纯装饰;欢迎页该说的话由它自己的标题和说明说。
        .accessibilityHidden(true)
    }
}

/// 一句歌词在开场里的排版和那一阵光点。尺寸、目标点不变时只算一次。
struct OnboardingIntroLayout {
    let size: CGSize
    let target: CGPoint
    let deskChars: [String]
    let deskCharWidths: [CGFloat]
    let deskWidth: CGFloat
    let deskCenterY: CGFloat
    let islandText: String
    let islandTextWidth: CGFloat
    let particles: [OnboardingIntro.Particle]
    let particlesEnd: Double

    static let notch = CGSize(width: 110, height: 24)
    /// 长出耳朵后的宽度:刘海两侧各一只 46pt 的耳朵(左封面、右音量条)。
    static let earsWidth: CGFloat = 202
    /// 往下长出歌词那一行之后的高度(刘海那一截 + 34pt 的歌词行)。
    static let openHeight: CGFloat = 58
    static let deskLineHeight: CGFloat = 44
    static let deskFont = NSFont.systemFont(ofSize: 30, weight: .bold)
    static let islandFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// 光点那一阵的种子(固定:每次开场长得一样,好对着截图调)。
    static let particleSeed: UInt64 = 0x4C79_7269_6D75_7365

    /// 光点飞进灵动岛歌词那一行的正中。
    var islandCenter: CGPoint { CGPoint(x: size.width / 2, y: (Self.notch.height + Self.openHeight) / 2) }

    init(line: String, size: CGSize, target: CGPoint) {
        self.size = size
        self.target = target
        deskChars = line.map(String.init)
        // 整行按整句量(含字距调整);逐字宽度只用来给光点定出发位置,按整行宽度等比摊开。
        let lineWidth = (line as NSString).size(withAttributes: [.font: Self.deskFont]).width
        let raw = deskChars.map { ($0 as NSString).size(withAttributes: [.font: Self.deskFont]).width }
        let rawTotal = raw.reduce(0, +)
        deskWidth = lineWidth
        deskCharWidths = raw.map { rawTotal > 0 ? $0 * lineWidth / rawTotal : 0 }
        deskCenterY = size.height - 114
        islandText = line
        islandTextWidth = (line as NSString).size(withAttributes: [.font: Self.islandFont]).width
        var spans: [ClosedRange<Double>] = []
        var x = Double((size.width - deskWidth) / 2)
        for width in deskCharWidths {
            spans.append(x...(x + Double(width)))
            x += Double(width)
        }
        let island = CGPoint(x: size.width / 2, y: (Self.notch.height + Self.openHeight) / 2)
        particles = OnboardingIntro.particles(charSpans: spans,
                                              lineTop: Double(deskCenterY - Self.deskLineHeight / 2),
                                              lineHeight: Double(Self.deskLineHeight),
                                              target: island, seed: Self.particleSeed)
        particlesEnd = OnboardingIntro.particlesDuration(particles)
    }
}

/// 只在尺寸或目标点变了时重排(每帧都会问一次)。引用类型放进 `@State`,改它不触发重绘。
final class OnboardingIntroLayoutCache {
    private var key: (String, CGSize, CGPoint)?
    private var value: OnboardingIntroLayout?

    func layout(line: String, size: CGSize, target: CGPoint) -> OnboardingIntroLayout {
        if let key, let value, key.0 == line, key.1 == size, key.2 == target { return value }
        let fresh = OnboardingIntroLayout(line: line, size: size, target: target)
        key = (line, size, target)
        value = fresh
        return fresh
    }
}

/// 开场某一帧。
private struct OnboardingIntroFrame: View {
    let layout: OnboardingIntroLayout
    let t: Double

    private typealias I = OnboardingIntro

    var body: some View {
        let w = layout.size.width, h = layout.size.height
        ZStack {
            OnboardingIntroPalette.dusk
                .opacity(I.nightOpacity(t))
            OnboardingGlowBlobs(size: layout.size, drift: t)
                .opacity(I.glowOpacity(t))
            lyre
                .position(x: w / 2, y: h * 0.4)
            beam
                .position(x: w / 2, y: 50 + 160)
            desk
                .position(x: w / 2, y: layout.deskCenterY)
            if t >= I.burstStart, t <= I.burstStart + layout.particlesEnd {
                OnboardingIntroParticles(layout: layout, sinceBurst: t - I.burstStart)
            }
            island
            // 柔光在光球下面:从图标背后晕开,不盖在图标上把它冲淡。
            flash
            orb
            Text(L10n.t("点一下跳过"))
                .font(.system(size: 11))
                .foregroundStyle(OnboardingIntroPalette.mauve.opacity(0.7))
                .opacity(I.Segment(1.2, 0.4).progress(t) * (t < I.handoff ? 1 : 0))
                .position(x: w / 2, y: h - 24)
        }
        .frame(width: w, height: h)
    }

    // MARK: 里拉琴

    private var lyre: some View {
        let out = I.lyreOut(t)
        let move = I.Segment(I.burstStart, 0.9).progress(t, .ease)
        return OnboardingLyre(t: t)
            .frame(width: 220, height: 260)
            .scaleEffect(1 + 0.04 * move)
            .offset(y: -12 * move)
            .opacity(0.9 * (1 - out))
    }

    // MARK: 柔光

    private var beam: some View {
        let state = I.beamState(t)
        return RoundedRectangle(cornerRadius: 40, style: .continuous)
            .fill(LinearGradient(colors: [OnboardingIntroPalette.rose.opacity(0.45), OnboardingIntroPalette.blush.opacity(0)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 80, height: 320)
            .blur(radius: 18)
            .scaleEffect(x: 1, y: state.scale, anchor: .top)
            .opacity(state.opacity)
    }

    // MARK: 桌面歌词

    /// 桌面歌词「融进壁纸」:底色是很淡的薰衣草白到蜜桃白,没唱到的字是半透明的藕紫,像淡淡印在底上;唱到的字
    /// 染成玫瑰色、带一圈粉色光晕。染色前沿是一段软边渐变,遮罩上下左右都留出光晕的余量。不用深色阴影、不用
    /// 饱和金:压在浅色底上发脏、像贴上去的(14 章决策 109)。
    ///
    /// 唱完时一道软边从左往右扫过,扫过的字淡掉、光点从那里出发(`OnboardingIntro.dissolve`)。整行是一个 Text,
    /// 染色、消散都只动遮罩:字和光晕画一次,不跟着每帧重画。
    private var desk: some View {
        let state = I.deskState(t)
        let lit = layout.deskWidth * I.sing.progress(t)
        let dissolve = I.dissolve(t, charCount: layout.deskChars.count)
        return ZStack(alignment: .leading) {
            deskLine(OnboardingIntroPalette.mauve.opacity(0.3))
            deskLine(OnboardingIntroPalette.rose)
                .shadow(color: OnboardingIntroPalette.blush, radius: 6)
                .shadow(color: OnboardingIntroPalette.rose.opacity(0.35), radius: 16)
                .mask(alignment: .leading) { softWipe(lit: lit) }
        }
        .frame(width: layout.deskWidth, height: OnboardingIntroLayout.deskLineHeight)
        .mask(alignment: .leading) { dissolveMask(dissolve.front) }
        .offset(y: -dissolve.lift)
        .scaleEffect(state.scale)
        .offset(y: state.rise)
        .opacity(state.opacity)
    }

    /// 消散遮罩:软边左侧透明、右侧实。`front` 0 时软边整个在行首之前(全露),1 时整个过了行尾(全隐)。
    private func dissolveMask(_ front: Double) -> some View {
        let edge: CGFloat = 60, pad: CGFloat = 40
        let x = -edge + CGFloat(front) * (layout.deskWidth + edge * 2)
        return HStack(spacing: 0) {
            Color.clear.frame(width: max(0, pad + x))
            LinearGradient(colors: [.white.opacity(0), .white], startPoint: .leading, endPoint: .trailing)
                .frame(width: edge)
            Rectangle()
        }
        .frame(width: layout.deskWidth + pad * 2 + edge * 2, height: OnboardingIntroLayout.deskLineHeight + pad * 2)
        .offset(x: -pad)
    }

    /// 染色遮罩:左边实、前沿 24pt 软边;往左和上下各多铺 40pt,光晕不被遮罩切掉。
    private func softWipe(lit: CGFloat) -> some View {
        let edge: CGFloat = 24, pad: CGFloat = 40
        return HStack(spacing: 0) {
            Rectangle().frame(width: max(0, pad + lit - edge / 2))
            LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: edge)
            Spacer(minLength: 0)
        }
        .frame(width: layout.deskWidth + pad * 2 + edge, height: OnboardingIntroLayout.deskLineHeight + pad * 2)
        .offset(x: -pad)
        // 还没开始唱时整块不露(软边那半截也不该先亮)。
        .opacity(lit > 0 ? 1 : 0)
    }

    private func deskLine(_ color: Color) -> some View {
        Text(layout.islandText)
            .font(Font(OnboardingIntroLayout.deskFont as CTFont))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    /// 扫光前沿那道亮光:遮罩右缘一条窄窗,左透明右实,亮的只有字本身。
    private func shineWindow(width: CGFloat, at edge: CGFloat) -> some View {
        LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
            .frame(width: width)
            .offset(x: edge - width)
    }

    // MARK: 灵动岛

    /// 照真灵动岛的样子:刘海两侧长出耳朵,左耳一枚封面(用 App 图标)、右耳音量条;再往下长出一行,歌词在里面
    /// 扫光染色。形状是真灵动岛那个 `NotchHangingShape`,底角随高度变圆。底不是纯黑:液态玻璃(折射背后流动的光晕,
    /// 背景一动它跟着变)里铺一层放大模糊的封面,同真灵动岛「跟随封面」的背景。光点吸进来时往下鼓一点、外圈发淡粉光,
    /// 不做横竖不等的缩放。
    private var island: some View {
        let notch = OnboardingIntroLayout.notch
        let size = I.islandSize(t, notch: notch, earsWidth: Double(OnboardingIntroLayout.earsWidth),
                                openWidth: Double(layout.islandTextWidth) + 56,
                                openHeight: Double(OnboardingIntroLayout.openHeight))
        let absorb = I.absorbAmount(t)
        let shape = NotchHangingShape.card(notchHeight: notch.height)
        let progress = I.sing.progress(t)
        return ZStack(alignment: .top) {
            // 光点吸进来时背后亮一圈光:形状和模糊都不变,只动不透明度。
            shape.fill(OnboardingIntroPalette.rose)
                .frame(width: size.width, height: size.height)
                .blur(radius: 14)
                .opacity(0.5 * absorb)
            OnboardingIslandGlass(shape: shape, size: size, coverWidth: layout.islandTextWidth + 56)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 17, height: 17)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Spacer(minLength: 0)
                    OnboardingEqualizer(t: t)
                }
                .padding(.horizontal, 14)
                .frame(height: notch.height)
                .opacity(I.islandEarsOpacity(t))
                ZStack(alignment: .leading) {
                    islandText(.white.opacity(0.45))
                    islandText(.white)
                        .mask(alignment: .leading) { Rectangle().frame(width: layout.islandTextWidth * progress) }
                    islandText(OnboardingIntroPalette.shine)
                        .mask(alignment: .leading) { shineWindow(width: 10, at: layout.islandTextWidth * progress) }
                        .opacity(I.shineOpacity(t))
                }
                .frame(width: layout.islandTextWidth, alignment: .leading)
                .opacity(I.islandLyricOpacity(t))
                .frame(maxHeight: .infinity)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
            // 玻璃边上一圈高光(上亮下淡),边界才浮得起来。
            shape.stroke(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                         lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: OnboardingIntroPalette.mauve.opacity(0.18), radius: 12, y: 5)
        .opacity(I.islandOpacity(t))
        .position(x: layout.size.width / 2, y: size.height / 2)
    }

    private func islandText(_ color: Color) -> some View {
        Text(layout.islandText)
            .font(Font(OnboardingIntroLayout.islandFont as CTFont))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: 光球

    private var orb: some View {
        let state = I.orbState(t, centerX: Double(layout.size.width / 2),
                               notchBottom: Double(OnboardingIntroLayout.notch.height), target: layout.target)
        let shape = RoundedRectangle(cornerRadius: state.radius, style: .continuous)
        return ZStack {
            // 图标自带透明边,落地时把底下的光球底色一起褪掉,只留图标本身。
            shape.fill(OnboardingIntroPalette.orbFill).opacity(1 - state.icon)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .opacity(state.icon)
        }
        .frame(width: state.diameter, height: state.diameter)
        .clipShape(shape)
        // 光晕是一个径向渐变的圆跟着缩放,不用 shadow:光球每帧变大小,shadow 每帧都要重新模糊一遍。
        .background {
            Circle()
                .fill(RadialGradient(colors: [OnboardingIntroPalette.orbGlow.opacity(0.75), OnboardingIntroPalette.orbGlow.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: 0.95))
                .scaleEffect(state.diameter * 0.95)
                .frame(width: 2, height: 2)
                .opacity(0.7 * (1 - state.icon) + 0.35)
        }
        // 刚从刘海挤出来时像一滴水,先拉长、再回弹成圆。
        .scaleEffect(x: 1 - 0.18 * state.stretch, y: 1 + 0.35 * state.stretch, anchor: .top)
        .opacity(state.opacity)
        .position(state.center)
    }

    // MARK: 落地闪光

    private var flash: some View {
        let corners = [CGPoint.zero, CGPoint(x: layout.size.width, y: 0),
                       CGPoint(x: 0, y: layout.size.height), CGPoint(x: layout.size.width, y: layout.size.height)]
        let reach = corners.map { hypot($0.x - layout.target.x, $0.y - layout.target.y) }.max() ?? 400
        return RadialGradient(stops: [.init(color: .white.opacity(0.8), location: 0),
                                      .init(color: OnboardingIntroPalette.blush.opacity(0.3), location: 0.35),
                                      .init(color: .white.opacity(0), location: 0.7)],
                              center: UnitPoint(x: layout.target.x / layout.size.width,
                                                y: layout.target.y / layout.size.height),
                              startRadius: 0, endRadius: reach)
            .opacity(I.flashOpacity(t))
    }
}

/// 开场用到的颜色,往 App 图标的气质靠:底色是很淡的薰衣草白、粉白、蜜桃白,光晕是图标里那几种粉、桃、紫的
/// 淡色;线条和光点用香槟金和玫瑰色,在浅底上看得清又不扎眼。
enum OnboardingIntroPalette {
    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255) }

    static let dusk = LinearGradient(stops: [.init(color: rgb(255, 244, 249), location: 0),
                                            .init(color: rgb(255, 238, 245), location: 0.4),
                                            .init(color: rgb(255, 241, 238), location: 0.75),
                                            .init(color: rgb(255, 248, 245), location: 1)],
                                     startPoint: .top, endPoint: .bottom)
    static let shine = rgb(255, 251, 234)
    static let blush = rgb(255, 214, 228)
    static let rose = rgb(222, 112, 150)
    static let mauve = rgb(160, 110, 150)
    /// 灵动岛封面底上压的那层淡玫瑰灰,白字才看得清。
    static let plumShade = rgb(150, 80, 110)
    static let orbGlow = rgb(255, 196, 218)
    static let orbFill = RadialGradient(colors: [.white, rgb(255, 225, 236), rgb(255, 179, 207)],
                                        center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 50)
    static let lyreGold = Gradient(stops: [.init(color: rgb(236, 196, 120), location: 0),
                                           .init(color: rgb(210, 158, 72), location: 0.5),
                                           .init(color: rgb(232, 186, 108), location: 1)])
    static let laurelGold = Gradient(stops: [.init(color: rgb(255, 233, 168), location: 0),
                                             .init(color: rgb(232, 176, 79), location: 0.55),
                                             .init(color: rgb(246, 207, 124), location: 1)])
    /// 粒子四种暖色(香槟金、玫瑰、蜜桃、浅香槟),槽位数同 `OnboardingIntro.particleColorCount`。浅底上多一种冷色
    /// 就像撒五彩纸屑。
    static let particles: [Color] = [rgb(232, 182, 90), rgb(232, 130, 165), rgb(245, 165, 120), rgb(236, 200, 140)]
}

/// 三团光晕(粉、桃、紫):自带软边的径向渐变,不用模糊滤镜。`drift` 给秒数就慢慢飘,给 nil 就静止
/// (欢迎页背后那层淡光晕)。
struct OnboardingGlowBlobs: View {
    let size: CGSize
    var drift: Double?

    private struct Blob {
        let color: Color
        let center: (CGSize) -> CGPoint
        let offset: CGSize
        let scale: CGFloat
        let period: Double
    }

    private static let blobs: [Blob] = [
        Blob(color: OnboardingIntroPalette.rgb(255, 196, 214), center: { _ in CGPoint(x: 150, y: 170) },
             offset: CGSize(width: 70, height: 50), scale: 1.15, period: 7),
        Blob(color: OnboardingIntroPalette.rgb(255, 218, 200), center: { CGPoint(x: $0.width - 120, y: 260) },
             offset: CGSize(width: -60, height: -30), scale: 0.9, period: 8),
        Blob(color: OnboardingIntroPalette.rgb(232, 214, 255), center: { CGPoint(x: 250, y: $0.height - 100) },
             offset: CGSize(width: 40, height: -60), scale: 1.2, period: 9),
    ]

    var body: some View {
        ZStack {
            ForEach(Self.blobs.indices, id: \.self) { index in
                let blob = Self.blobs[index]
                let k = drift.map { Self.sway($0, period: blob.period) } ?? 0
                Circle()
                    .fill(RadialGradient(colors: [blob.color.opacity(0.95), blob.color.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 200))
                    .frame(width: 400, height: 400)
                    .scaleEffect(1 + (blob.scale - 1) * k)
                    .position(x: blob.center(size).x + blob.offset.width * k,
                              y: blob.center(size).y + blob.offset.height * k)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// 来回飘(同 CSS `alternate` + ease-in-out)。
    private static func sway(_ t: Double, period: Double) -> CGFloat {
        let phase = (t / period).truncatingRemainder(dividingBy: 2)
        return CGFloat(OnboardingIntro.Curve.easeInOut(phase < 1 ? phase : 2 - phase))
    }
}

/// 金色里拉琴:两只琴臂、琴腹、横梁、琴码、五根弦,琴角尖两颗小星。一笔笔描出来,弦按时间轴被拨响。
/// 坐标照设计稿的 200×240 画,四周留 10pt 给光晕和弦的颤动。
private struct OnboardingLyre: View {
    let t: Double

    private typealias I = OnboardingIntro

    /// 描线顺序同 `OnboardingIntro.lyreStrokeDelays`:两只琴臂、琴腹、横梁、琴码。
    private static let frame: [Path] = [
        Path { p in
            p.move(to: CGPoint(x: 72, y: 180))
            p.addCurve(to: CGPoint(x: 50, y: 98), control1: CGPoint(x: 48, y: 164), control2: CGPoint(x: 38, y: 128))
            p.addCurve(to: CGPoint(x: 56, y: 44), control1: CGPoint(x: 60, y: 74), control2: CGPoint(x: 66, y: 60))
            p.addCurve(to: CGPoint(x: 36, y: 38), control1: CGPoint(x: 50, y: 34), control2: CGPoint(x: 40, y: 32))
        },
        Path { p in
            p.move(to: CGPoint(x: 128, y: 180))
            p.addCurve(to: CGPoint(x: 150, y: 98), control1: CGPoint(x: 152, y: 164), control2: CGPoint(x: 162, y: 128))
            p.addCurve(to: CGPoint(x: 144, y: 44), control1: CGPoint(x: 140, y: 74), control2: CGPoint(x: 134, y: 60))
            p.addCurve(to: CGPoint(x: 164, y: 38), control1: CGPoint(x: 150, y: 34), control2: CGPoint(x: 160, y: 32))
        },
        Path { p in
            p.move(to: CGPoint(x: 68, y: 178))
            p.addLine(to: CGPoint(x: 132, y: 178))
            p.addCurve(to: CGPoint(x: 68, y: 178), control1: CGPoint(x: 132, y: 212), control2: CGPoint(x: 68, y: 212))
            p.closeSubpath()
        },
        Path { p in
            p.move(to: CGPoint(x: 48, y: 60))
            p.addLine(to: CGPoint(x: 152, y: 60))
        },
        Path { p in
            p.move(to: CGPoint(x: 82, y: 190))
            p.addLine(to: CGPoint(x: 118, y: 190))
        },
    ]
    private static let stringXs: [CGFloat] = [86, 93, 100, 107, 114]
    private static let sparkCenters = [CGPoint(x: 34, y: 26), CGPoint(x: 166, y: 26)]

    private static func star(at center: CGPoint, radius: CGFloat) -> Path {
        Path { p in
            let r = radius, k = radius * 0.25
            p.move(to: CGPoint(x: center.x, y: center.y - r))
            p.addLine(to: CGPoint(x: center.x + k, y: center.y - k))
            p.addLine(to: CGPoint(x: center.x + r, y: center.y))
            p.addLine(to: CGPoint(x: center.x + k, y: center.y + k))
            p.addLine(to: CGPoint(x: center.x, y: center.y + r))
            p.addLine(to: CGPoint(x: center.x - k, y: center.y + k))
            p.addLine(to: CGPoint(x: center.x - r, y: center.y))
            p.addLine(to: CGPoint(x: center.x - k, y: center.y - k))
            p.closeSubpath()
        }
    }

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: 10, y: 10)
            let gold = GraphicsContext.Shading.linearGradient(OnboardingIntroPalette.lyreGold,
                                                              startPoint: .zero, endPoint: CGPoint(x: 0, y: 240))
            // 发光是金线下面一道更粗、半透明的暖色线,不挂 shadow 滤镜:这块画布描线、拨弦期间每帧重画,滤镜每帧都要重新模糊。
            let halo = GraphicsContext.Shading.color(OnboardingIntroPalette.rgb(255, 205, 130).opacity(0.28))
            let heavy = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
            let haloStyle = StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
            for (index, path) in Self.frame.enumerated() {
                let drawn = I.lyreStroke(index, t)
                guard drawn > 0 else { continue }
                let trimmed = path.trimmedPath(from: 0, to: drawn)
                context.stroke(trimmed, with: halo, style: haloStyle)
                context.stroke(trimmed, with: gold, style: heavy)
            }
            for (index, x) in Self.stringXs.enumerated() {
                let drawn = I.lyreStroke(Self.frame.count + index, t)
                guard drawn > 0 else { continue }
                let pluck = I.pluck(index, t)
                let string = Path { p in
                    p.move(to: CGPoint(x: x + pluck.offset, y: 60))
                    p.addLine(to: CGPoint(x: x + pluck.offset, y: 190))
                }.trimmedPath(from: 0, to: drawn)
                context.stroke(string, with: gold, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                if pluck.white > 0 {
                    context.stroke(string, with: .color(.white.opacity(pluck.white)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            for (index, center) in Self.sparkCenters.enumerated() {
                let scale = I.sparkScale(index, t)
                guard scale > 0 else { continue }
                context.opacity = 0.5 + 0.5 * (scale - 0.35) / 0.65
                context.fill(Self.star(at: center, radius: 8 * scale),
                             with: .color(OnboardingIntroPalette.rgb(236, 190, 100)))
                context.opacity = 1
            }
        }
    }
}

/// 灵动岛的底:液态玻璃里铺一层放大、模糊的封面(App 图标),压一层淡深紫让白字看得清。玻璃折射窗口里它背后的
/// 内容(开场底色和流动的光晕),背景一动它跟着变。macOS 26 以前没有液态玻璃,退回窗口内模糊的材质。
/// 封面按展开后的宽度(`coverWidth`)铺、尺寸固定,只随灵动岛的形状裁:灵动岛每帧变大小时不用重新模糊一遍。
private struct OnboardingIslandGlass: View {
    let shape: NotchHangingShape
    let size: CGSize
    let coverWidth: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFill()
            .frame(width: coverWidth * 1.3, height: coverWidth * 0.5)
            .blur(radius: 16)
            .opacity(0.75)
            .overlay(OnboardingIntroPalette.plumShade.opacity(0.22))
            .frame(width: size.width, height: size.height)
            .clipped()
            .onboardingIslandGlass(in: shape, tint: OnboardingIntroPalette.rose.opacity(0.25))
    }
}

/// 灵动岛右耳四根音量条。
private struct OnboardingEqualizer: View {
    let t: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 2.5, height: 12)
                    .scaleEffect(x: 1, y: OnboardingIntro.equalizerBar(index, t), anchor: .center)
            }
        }
        .frame(height: 12)
    }
}

/// 歌词碎成的光点(浅底上正常混合,叠加变亮会白成一片):一层 Canvas 画完,光点是预先画好的四张柔光贴图(每帧只贴图,不现算渐变)。
private struct OnboardingIntroParticles: View {
    let layout: OnboardingIntroLayout
    let sinceBurst: Double

    var body: some View {
        Canvas { context, _ in
            let sprites = (0..<OnboardingIntro.particleColorCount).map { context.resolveSymbol(id: $0) }
            for particle in layout.particles {
                guard let state = OnboardingIntro.particleState(particle, sinceBurst: sinceBurst,
                                                                target: layout.islandCenter) else { continue }
                let color = OnboardingIntroPalette.particles[particle.colorIndex % OnboardingIntroPalette.particles.count]
                var tail = Path()
                tail.move(to: state.tail)
                tail.addLine(to: state.point)
                context.opacity = state.alpha * 0.18
                context.stroke(tail, with: .color(color), style: StrokeStyle(lineWidth: particle.size * 1.6, lineCap: .round))
                let radius = particle.size * 3
                context.opacity = state.alpha * 0.9
                if let sprite = sprites[particle.colorIndex % sprites.count] {
                    context.draw(sprite, in: CGRect(x: state.point.x - radius, y: state.point.y - radius,
                                                    width: radius * 2, height: radius * 2))
                }
            }
        } symbols: {
            ForEach(OnboardingIntroPalette.particles.indices, id: \.self) { index in
                Circle()
                    .fill(RadialGradient(stops: [.init(color: OnboardingIntroPalette.particles[index], location: 0),
                                                 .init(color: OnboardingIntroPalette.particles[index].opacity(0.55), location: 0.35),
                                                 .init(color: OnboardingIntroPalette.particles[index].opacity(0), location: 1)],
                                         center: .center, startRadius: 0, endRadius: 16))
                    .frame(width: 32, height: 32)
                    .tag(index)
            }
        }
        // 交给显卡画:几百颗光点和拖尾在 CPU 上逐帧光栅化,碎裂这一段会掉帧。
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// 欢迎页图标外圈的月桂冠(几何在 core `LaurelWreath`)。`growStart` 给时刻就从那一刻起长出来,长完停掉逐帧刷新;
/// 给 nil 直接画完整的(减弱动态效果、或者早就长完了)。
struct LaurelWreathView: View {
    let growStart: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var growing = false

    var body: some View {
        Group {
            if growing, let growStart {
                // 长的过程中不挂发光:画布每帧重画,发光滤镜每帧都要重新模糊。长完换成带发光的静态那张。
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    Self.wreath(elapsed: context.date.timeIntervalSince(growStart), glow: false)
                }
            } else {
                Self.wreath(elapsed: .infinity, glow: true)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: growStart) { await grow() }
    }

    private func grow() async {
        guard let growStart, !reduceMotion else {
            growing = false
            return
        }
        let remaining = LaurelWreath.growDuration - Date().timeIntervalSince(growStart)
        guard remaining > 0 else {
            growing = false
            return
        }
        growing = true
        try? await Task.sleep(for: .seconds(remaining))
        // 换了 growStart 时旧任务被取消,别让它的收尾把新一轮的 growing 清掉(同 `ConfettiOverlay.play`)。
        guard !Task.isCancelled else { return }
        growing = false
    }

    private static let leafPath = Path { p in
        let w = LaurelWreath.leafHalfWidth * 2, l = LaurelWreath.leafLength
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: 0, y: -l), control: CGPoint(x: w, y: -l * 6 / 13))
        p.addQuadCurve(to: .zero, control: CGPoint(x: -w, y: -l * 6 / 13))
        p.closeSubpath()
    }

    private static func wreath(elapsed: Double, glow: Bool) -> some View {
        Canvas { context, size in
            let scale = size.width / LaurelWreath.box
            context.scaleBy(x: scale, y: scale)
            if glow {
                context.addFilter(.shadow(color: OnboardingIntroPalette.rgb(255, 205, 120).opacity(0.6), radius: 3))
            }
            let gold = GraphicsContext.Shading.linearGradient(OnboardingIntroPalette.laurelGold, startPoint: .zero,
                                                              endPoint: CGPoint(x: 0, y: LaurelWreath.box))
            let drawn = LaurelWreath.stemDraw.progress(elapsed, .ease)
            for stem in LaurelWreath.stems {
                var path = Path()
                path.move(to: stem[0])
                path.addCurve(to: stem[3], control1: stem[1], control2: stem[2])
                context.stroke(path.trimmedPath(from: 0, to: drawn), with: gold,
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            for leaf in LaurelWreath.leaves {
                let segment = LaurelWreath.leafGrowth(order: leaf.order)
                let grown = segment.progress(elapsed, .soft)
                guard grown > 0 else { continue }
                let transform = CGAffineTransform(scaleX: leaf.scale * grown, y: leaf.scale * grown)
                    .concatenating(CGAffineTransform(rotationAngle: leaf.angle))
                    .concatenating(CGAffineTransform(translationX: leaf.base.x, y: leaf.base.y))
                context.opacity = OnboardingIntro.Segment(segment.start, 0.3).progress(elapsed)
                context.fill(leafPath.applying(transform), with: gold)
            }
        }
    }
}

/// 开场期间藏起窗口标题(它在标题栏正中,会压在灵动岛上),视图摘掉时还原。
/// 标题平时由 `OnboardingWindowBackground` 设成可见(scene 的 `.hiddenTitleBar` 会把它藏掉)。
private struct WindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HiderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HiderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { window?.titleVisibility = .visible }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
