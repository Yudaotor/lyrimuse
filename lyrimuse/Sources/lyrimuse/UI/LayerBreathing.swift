import AppKit
import QuartzCore
import SwiftUI

/// 把一块**静态**的 SwiftUI 内容交给 Core Animation 做「缩放 + 透明度」往复呼吸。
///
/// 停播页那枚「光晕 + 音符」原来是 `.scaleEffect / .opacity` + `.easeInOut.repeatForever`:SwiftUI 的
/// 动画在主线程上逐帧推进(每帧重算依赖图 + 提交一次图层事务),页面开着就按屏幕刷新率一直跑 ——
/// 跟歌词窗口动画背景改 Core Animation 之前是同一个问题(07 章决策 48,`BackdropNSView`)。
/// 这里内容只画一次(`NSHostingView`),呼吸挂在宿主图层上,装好之后由渲染服务播,主线程不参与。
///
/// 缩放绕中心:动画的是宿主图层的 `sublayerTransform`(AppKit 不碰它,不像 `transform` / 锚点那样
/// 会被视图布局改写),平移量按当前尺寸现算,尺寸变了重装一次。
///
/// `animating` = false 时摘掉动画、定格在原尺寸原透明度(窗口不可见 / 系统开了减弱动态效果)。
struct LayerBreathing<Content: View>: NSViewRepresentable {
    var scale: ClosedRange<CGFloat> = 0.96...1.05
    var opacity: ClosedRange<Float> = 0.8...1
    /// 单程时长(秒);往返一次是它的两倍,同原来 `.easeInOut(duration:).repeatForever(autoreverses: true)`。
    var duration: Double = 2.6
    var animating: Bool
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> LayerBreathingNSView {
        LayerBreathingNSView(rootView: AnyView(content))
    }

    func updateNSView(_ view: LayerBreathingNSView, context: Context) {
        view.hosting.rootView = AnyView(content)
        view.configure(scale: scale, opacity: opacity, duration: duration, animating: animating)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayerBreathingNSView, context: Context) -> CGSize? {
        nsView.hosting.fittingSize
    }
}

@MainActor
final class LayerBreathingNSView: NSView {
    private static let scaleKey = "lyrimuse.breathing-scale"
    private static let opacityKey = "lyrimuse.breathing-opacity"

    let hosting: NSHostingView<AnyView>
    private var scale: ClosedRange<CGFloat> = 1...1
    private var opacity: ClosedRange<Float> = 1...1
    private var duration: Double = 1
    private var animating = false
    /// 上一次装动画时的尺寸:只有它变了(或开关 / 参数变了)才重装,SwiftUI 的每次重估不打断正在跑的那一条。
    private var installedSize: CGSize?

    init(rootView: AnyView) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(scale: ClosedRange<CGFloat>, opacity: ClosedRange<Float>, duration: Double, animating: Bool) {
        let changed = self.scale != scale || self.opacity != opacity || self.duration != duration
            || self.animating != animating
        self.scale = scale
        self.opacity = opacity
        self.duration = duration
        self.animating = animating
        if changed { reinstall() }
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        if installedSize != bounds.size { reinstall() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reinstall()
    }

    private func reinstall() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.scaleKey)
        layer.removeAnimation(forKey: Self.opacityKey)
        installedSize = bounds.size
        guard animating, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        func around(_ s: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(c.x, c.y, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -c.x, -c.y, 0)
        }
        let grow = CABasicAnimation(keyPath: "sublayerTransform")
        grow.fromValue = NSValue(caTransform3D: around(scale.lowerBound))
        grow.toValue = NSValue(caTransform3D: around(scale.upperBound))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity.lowerBound
        fade.toValue = opacity.upperBound
        for a in [grow, fade] {
            a.duration = duration
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // 缓慢的呼吸,合成器不必按 ProMotion 120Hz 去插值。
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        }
        layer.add(grow, forKey: Self.scaleKey)
        layer.add(fade, forKey: Self.opacityKey)
    }
}
