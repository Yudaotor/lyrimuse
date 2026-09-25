import AppKit
import QuartzCore
import SwiftUI
import LyrimuseCore

/// 间奏「•••」(Apple Music 歌词页同款)的呼吸圆点本体。悬浮歌词 / 歌词窗口 / 灵动岛共用
/// 这一个视图;菜单栏那一面用不了 SwiftUI(状态栏项里没有活的视图可挂,见
/// `MenuBarScrollingLabel` 头注),它自己用 CALayer 排三颗点,但**曲线走同一份
/// `GapDotsCurve`**(LyrimuseCore,selftest 钉住)——视图搬不过去,常数不能也跟着各写一份。
///
/// ## 动画交给 Core Animation
///
/// 原来是 30Hz `TimelineView` 每拍现算三颗点的亮度与缩放:这个视图挂在灵动岛 / 悬浮歌词 / 歌词窗口里,
/// 间奏期间它每拍都带着整扇窗口走一遍布局 + 显示列表 + 图层提交(跟逐字填色搬图层之前同一个问题)。
/// 现在两条曲线都是**播放位置的纯函数**、间奏的起止时间又是已知的,于是一次排好交给渲染服务:
///   - 点亮进度:随时间线性推进,`opacity(dot:progress:)` 在 progress = i/3、(i+1)/3 处折一下 ——
///     每颗点 4 个关键帧就是精确的,不用采样;
///   - 呼吸:`breathe(atMs:)` 以 `breathePeriodMs` 为周期,排一个周期(30 点/秒)无限循环,按此刻的
///     位置对齐相位。三颗点同步放大缩小(AM 的样子),各绕自己的中心。
/// 重装时机:起止时间 / 在播 / 可见 / 减弱动态效果变了,以及每 3 秒对一次表(拖动进度 / 锚点重发会让
/// 位置跳一下,偏差超过 250ms 就按新位置重排)。暂停 / 看不见时摘掉动画、定格在此刻的样子。
///
/// 位置入参仍是闭包(`currentPositionMs`):装动画、对表时各现读一次,不再每帧调。
struct LyricsGapDotsView: View {
    let startMs: Int
    let endMs: Int
    let dotSize: CGFloat
    let spacing: CGFloat
    let color: Color
    let isPlaying: Bool
    let isVisible: Bool
    let reduceMotion: Bool
    /// 非 nil = 三颗点各投一层阴影(灵动岛那条 `.shadow(color: .black.opacity(0.45), radius: 2, y: 1)`
    /// 的图层版 —— SwiftUI 的 `.shadow` 罩不到原生图层上)。
    var shadow: GapDotsShadow? = nil
    /// 某一刻的播放位置(歌词时间轴毫秒)。入参是求值那一刻的 `Date`。
    let currentPositionMs: (Date) -> Int

    var body: some View {
        GapDotsLayer(startMs: startMs, endMs: endMs, dotSize: dotSize, spacing: spacing,
                     color: NSColor(color), running: isPlaying && isVisible,
                     reduceMotion: reduceMotion, shadow: shadow, currentPositionMs: currentPositionMs)
            .frame(width: CGFloat(GapDotsCurve.dotCount) * dotSize
                       + CGFloat(GapDotsCurve.dotCount - 1) * spacing,
                   height: dotSize)
            .accessibilityHidden(true)
    }
}

struct GapDotsShadow: Equatable {
    var color: NSColor
    var radius: CGFloat
    /// SwiftUI 口径:正 = 往下。
    var offsetY: CGFloat
}

private struct GapDotsLayer: NSViewRepresentable {
    let startMs: Int
    let endMs: Int
    let dotSize: CGFloat
    let spacing: CGFloat
    let color: NSColor
    let running: Bool
    let reduceMotion: Bool
    let shadow: GapDotsShadow?
    let currentPositionMs: (Date) -> Int

    func makeNSView(context: Context) -> GapDotsNSView { GapDotsNSView() }

    func updateNSView(_ view: GapDotsNSView, context: Context) {
        view.positionProvider = currentPositionMs
        view.apply(.init(startMs: startMs, endMs: endMs, dotSize: dotSize, spacing: spacing, color: color,
                         running: running, reduceMotion: reduceMotion, shadow: shadow))
    }
}

@MainActor
final class GapDotsNSView: NSView {
    struct Config: Equatable {
        var startMs: Int
        var endMs: Int
        var dotSize: CGFloat
        var spacing: CGFloat
        var color: NSColor
        var running: Bool
        var reduceMotion: Bool
        var shadow: GapDotsShadow?
    }

    private static let opacityKey = "lyrimuse.gapdots-opacity"
    private static let breatheKey = "lyrimuse.gapdots-breathe"
    /// 对表间隔与容差:拖动进度 / 锚点重发之后按新位置重排。
    private static let resyncInterval: TimeInterval = 3
    private static let resyncToleranceMs = 250.0
    /// 呼吸那一个周期的采样密度。
    private static let breatheSamplesPerSecond = 30.0

    var positionProvider: ((Date) -> Int)?
    private var config: Config?
    private var dots: [CALayer] = []
    /// 装动画那一刻的(歌词位置, 媒体时间),对表时外推「动画此刻推到哪」。
    private var installedAt: (posMs: Double, media: CFTimeInterval)?
    private var resyncTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0..<GapDotsCurve.dotCount {
            let dot = CALayer()
            dot.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(),
                           "transform": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull(),
                           "shadowColor": NSNull(), "shadowOpacity": NSNull()]
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ next: Config) {
        guard next != config else { return }
        config = next
        layoutDots()
        install()
    }

    override func layout() {
        super.layout()
        layoutDots()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
    }

    private func layoutDots() {
        guard let c = config else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let y = bounds.height / 2
        for (i, dot) in dots.enumerated() {
            dot.bounds = CGRect(x: 0, y: 0, width: c.dotSize, height: c.dotSize)
            dot.position = CGPoint(x: CGFloat(i) * (c.dotSize + c.spacing) + c.dotSize / 2, y: y)
            dot.cornerRadius = c.dotSize / 2
            dot.backgroundColor = c.color.cgColor
            if let s = c.shadow {
                dot.shadowColor = s.color.withAlphaComponent(1).cgColor
                dot.shadowOpacity = Float(s.color.alphaComponent)
                dot.shadowRadius = s.radius
                // 图层坐标 y 向上,SwiftUI 的正 offsetY 是往下。
                dot.shadowOffset = CGSize(width: 0, height: -s.offsetY)
                dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            } else {
                dot.shadowOpacity = 0
            }
        }
        CATransaction.commit()
    }

    private func currentPos() -> Double {
        Double(positionProvider?(Date()) ?? config?.startMs ?? 0)
    }

    /// 按此刻的位置重排(或定格)。
    private func install() {
        resyncTimer?.invalidate()
        resyncTimer = nil
        guard let c = config else { return }
        let pos = currentPos()
        let progress = GapDotsCurve.progress(posMs: Int(pos), startMs: c.startMs, endMs: c.endMs)
        let breathe = GapDotsCurve.breathe(atMs: Int(pos), reduceMotion: c.reduceMotion)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, dot) in dots.enumerated() {
            dot.removeAnimation(forKey: Self.opacityKey)
            dot.removeAnimation(forKey: Self.breatheKey)
            dot.opacity = Float(GapDotsCurve.opacity(dot: i, progress: progress))
            dot.transform = CATransform3DMakeScale(CGFloat(breathe), CGFloat(breathe), 1)
        }
        CATransaction.commit()
        installedAt = nil
        guard c.running, window != nil else { return }

        let media = CACurrentMediaTime()
        installedAt = (pos, media)
        let remainingMs = max(0, Double(c.endMs) - pos)
        for (i, dot) in dots.enumerated() {
            let begin = dot.convertTime(media, from: nil)
            // 点亮:progress 线性于时间,opacity 在 i/3、(i+1)/3 处折 —— 这两个时刻加首尾四个关键帧。
            let frames = GapDotsCurve.opacityKeyframes(dot: i, startMs: c.startMs, endMs: c.endMs, fromMs: pos)
            if remainingMs > 0, !frames.isEmpty {
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = frames.map(\.opacity)
                fade.keyTimes = frames.map { NSNumber(value: ($0.ms - pos) / remainingMs) }
                fade.duration = remainingMs / 1000
                fade.beginTime = begin
                fade.calculationMode = .linear
                fade.fillMode = .forwards
                fade.isRemovedOnCompletion = false
                dot.add(fade, forKey: Self.opacityKey)
                dot.opacity = Float(GapDotsCurve.opacity(dot: i, progress: 1))
            }
            // 呼吸:一个周期的关键帧、无限循环,相位对齐此刻的位置。
            if !c.reduceMotion {
                let period = GapDotsCurve.breathePeriodMs
                let count = Int(period / 1000 * Self.breatheSamplesPerSecond)
                let values = (0...count).map { k -> NSValue in
                    let s = GapDotsCurve.breathe(atMs: Int(Double(k) / Double(count) * period))
                    return NSValue(caTransform3D: CATransform3DMakeScale(CGFloat(s), CGFloat(s), 1))
                }
                let breathe = CAKeyframeAnimation(keyPath: "transform")
                breathe.values = values
                breathe.calculationMode = .linear
                breathe.duration = period / 1000
                breathe.repeatCount = .infinity
                breathe.beginTime = begin
                breathe.timeOffset = pos.truncatingRemainder(dividingBy: period) / 1000
                breathe.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
                dot.add(breathe, forKey: Self.breatheKey)
            }
        }
        let t = Timer(timeInterval: Self.resyncInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.resyncIfDrifted() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        resyncTimer = t
    }

    private func resyncIfDrifted() {
        guard let at = installedAt else { return }
        let predicted = at.posMs + (CACurrentMediaTime() - at.media) * 1000
        if abs(currentPos() - predicted) > Self.resyncToleranceMs { install() }
    }

    override func removeFromSuperview() {
        resyncTimer?.invalidate()
        resyncTimer = nil
        super.removeFromSuperview()
    }
}
