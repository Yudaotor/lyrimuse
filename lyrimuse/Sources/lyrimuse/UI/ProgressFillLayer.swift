import AppKit
import LyrimuseCore
import QuartzCore
import SwiftUI

/// 歌词窗口进度条的**已播段**:满宽胶囊整条向左移出 (1-f)·w、外面按固定满宽胶囊裁一次 —— 几何跟原来
/// SwiftUI 那版逐字相同(`ProgressFillGeometry.leadingOffset`,圆头形状与 f 无关的来由见调用处注释),
/// 只是**平移的补间交给 Core Animation**。
///
/// 为什么:原来是 `withAnimation(.linear(duration: 1))` 推 `.offset`。
/// offset 不参与布局,可 SwiftUI 的动画是在主线程上逐帧插值的 —— 每秒一段、段段相接,这段动画**永远在跑**,
/// 歌词窗口于是一直按屏幕刷新率(ProMotion 120Hz)逐帧重算显示列表、旁边的时间文字跟着每帧重新排版,
/// 逐字填色停表的间隙也不例外。实测歌词窗口开着、播放中:SwiftUI 更新表里这条胶囊 8 秒 1500 次、
/// 可动画 frame 1800 次。现在每秒只在拿到新位置时装一条 1 秒的线性动画,之后由渲染服务播。
struct ProgressFillLayer: NSViewRepresentable {
    let color: NSColor
    let fraction: Double
    /// 这一次 `fraction` 的变化要不要用 1 秒线性补过去。false = 直接到位(冷启动 / 拖动中 / 减弱动态效果)。
    let animatesChange: Bool

    func makeNSView(context: Context) -> ProgressFillLayerNSView { ProgressFillLayerNSView() }

    func updateNSView(_ view: ProgressFillLayerNSView, context: Context) {
        view.update(color: color, fraction: fraction, animated: animatesChange)
    }
}

@MainActor
final class ProgressFillLayerNSView: NSView {
    private static let slideKey = "lyrimuse.progress-fill-slide"
    private let fill = CALayer()
    private var fraction: Double = 0
    private var color: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        fill.anchorPoint = .zero
        fill.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                        "backgroundColor": NSNull(), "cornerRadius": NSNull()]
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func offsetX(for f: Double) -> CGFloat {
        -ProgressFillGeometry.leadingOffset(containerWidth: bounds.width, fraction: f)
    }

    func update(color: NSColor, fraction next: Double, animated: Bool) {
        if self.color != color {
            self.color = color
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.backgroundColor = color.cgColor
            CATransaction.commit()
        }
        guard next != fraction else { return }
        let from = (fill.presentation() ?? fill).transform
        fraction = next
        let to = CATransform3DMakeTranslation(offsetX(for: next), 0, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.removeAnimation(forKey: Self.slideKey)
        fill.transform = to
        CATransaction.commit()
        guard animated, window != nil, bounds.width > 0 else { return }
        // 从此刻屏幕上的位置接着走,不从上一段的终点跳:上一段还没走完时新的一秒已经到了也不会顿一下。
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = NSValue(caTransform3D: from)
        slide.toValue = NSValue(caTransform3D: to)
        slide.duration = 1
        slide.timingFunction = CAMediaTimingFunction(name: .linear)
        // 一秒走 1~2 个像素的补间,合成器不必按 120Hz 插值。
        slide.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        fill.add(slide, forKey: Self.slideKey)
    }

    override func layout() {
        super.layout()
        // 尺寸一变(缩放窗口)直接到位、不补间 —— 同原来「宽度变化不补间」的规矩。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        fill.removeAnimation(forKey: Self.slideKey)
        fill.bounds = CGRect(origin: .zero, size: bounds.size)
        fill.position = .zero
        fill.cornerRadius = bounds.height / 2
        fill.transform = CATransform3DMakeTranslation(offsetX(for: fraction), 0, 0)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        fill.contentsScale = scale
    }
}
