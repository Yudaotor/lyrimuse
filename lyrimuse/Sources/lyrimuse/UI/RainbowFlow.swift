import AppKit
import LyrimuseCore
import SwiftUI

/// 彩虹歌词(`RainbowLyrics`)的流动渐变:一组 `CAGradientLayer` 铺满 `width` 再多一圈,由一条无限循环的 `position.x` 动画
/// 从 −一圈平移到 0(从左往右流),装好之后由渲染服务播,主线程不参与。同一组里的几层同一条动画、同一个起点,颜色对得上。
/// 全进程从同一个零相位起算(`epoch`)、从不冻住(`RainbowLyrics.phase`),各展示面、各行、换句前后颜色始终一致;停着
/// (暂停、看不见、系统开了「减弱动态效果」)时停在此刻的全局相位上,再走时直接回到全局相位。见 17 章决策 54。
@MainActor
final class RainbowGradientDriver {
    static let animationKey = "lyrimuse.rainbow-flow"
    /// 全进程的零相位。
    static let epoch = CACurrentMediaTime()

    private var configured: (cycles: Int, stops: [RainbowLyrics.RGB])?

    /// 按一圈 `period` 摆好 `layers`:宽 = 铺满 `width` 再多一圈,高 = `height`;`flowing` 时(且系统没开「减弱动态效果」)
    /// 装流动动画,否则停在此刻的全局相位。
    /// `stops` 是一圈的色标,浅色底上传压暗的那组(`RainbowLyrics.lightBackgroundCycleStops`)。
    func apply(to layers: [CAGradientLayer], period: CGFloat, width: CGFloat, height: CGFloat, flowing: Bool,
               stops: [RainbowLyrics.RGB] = RainbowLyrics.cycleStops) {
        guard period > 0 else {
            layers.forEach { $0.removeAnimation(forKey: Self.animationKey) }
            return
        }
        let now = CACurrentMediaTime()
        let animates = flowing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cycles = Int((width / period).rounded(.up)) + 1
        let x = -period + CGFloat(RainbowLyrics.phase(at: now, epoch: Self.epoch)) * period
        let colors = configured.map { $0.cycles == cycles && $0.stops == stops } == true
            ? nil : Self.colors(cycles: cycles, stops: stops)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in layers {
            if let colors {
                g.colors = colors.colors
                g.locations = colors.locations
            }
            g.startPoint = CGPoint(x: 0, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
            g.anchorPoint = .zero
            g.bounds = CGRect(x: 0, y: 0, width: period * CGFloat(cycles), height: height)
            g.position = CGPoint(x: x, y: 0)
            g.removeAnimation(forKey: Self.animationKey)
        }
        CATransaction.commit()
        configured = (cycles, stops)
        guard animates else { return }
        for g in layers {
            let flow = CABasicAnimation(keyPath: "position.x")
            flow.fromValue = -period
            flow.toValue = 0
            flow.duration = RainbowLyrics.cycleSeconds
            flow.repeatCount = .infinity
            flow.beginTime = g.convertTime(Self.epoch, from: nil)
            g.add(flow, forKey: Self.animationKey)
        }
    }

    /// `cycles` 圈首尾相接的色标和位置(每圈 `stops` 去掉末尾那个重复色,最后补回第一个)。
    private static func colors(cycles: Int, stops: [RainbowLyrics.RGB]) -> (colors: [CGColor], locations: [NSNumber]) {
        let perCycle = stops.count - 1
        var colors: [CGColor] = []
        for _ in 0..<cycles {
            colors += stops.dropLast().map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
        }
        colors.append(CGColor(srgbRed: stops[0].r, green: stops[0].g, blue: stops[0].b, alpha: 1))
        let total = Double(cycles * perCycle)
        return (colors, (0...cycles * perCycle).map { NSNumber(value: Double($0) / total) })
    }
}

/// 一块铺满自身的流动彩虹,给 SwiftUI 画字的地方当底:`.rainbowFill` 拿字去遮它。一圈 = 自身宽度
/// (`RainbowLyrics.cycleWidth`,字多宽这块就多宽)。
final class RainbowFlowNSView: NSView {
    private let gradient = CAGradientLayer()
    private let driver = RainbowGradientDriver()
    var flowing = true {
        didSet { if flowing != oldValue { needsLayout = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        gradient.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let w = bounds.width
        driver.apply(to: [gradient], period: CGFloat(RainbowLyrics.cycleWidth(textWidth: w, viewWidth: w)),
                     width: w, height: bounds.height, flowing: flowing)
    }
}

struct RainbowFlowView: NSViewRepresentable {
    var flowing: Bool

    func makeNSView(context: Context) -> RainbowFlowNSView {
        let v = RainbowFlowNSView()
        v.flowing = flowing
        return v
    }

    func updateNSView(_ view: RainbowFlowNSView, context: Context) {
        view.flowing = flowing
    }
}

extension View {
    /// 开着时把这段内容的颜色换成流动彩虹:内容自己只当蒙版(透明度照旧,所以未唱、副行打的折保留),颜色由底下那块
    /// `RainbowFlowView` 给。内容要用白色画、透明度表示深浅。描边、阴影这类按内容剪影画的修饰挂在它外面时,剪影源要另给
    /// 一份纯文字(`lyricsTextStroke(_:width:color:maskSource:)`):剪影画不出 AppKit 视图。
    @ViewBuilder
    func rainbowFill(_ on: Bool, flowing: Bool) -> some View {
        if on {
            hidden().overlay(RainbowFlowView(flowing: flowing).mask(self))
        } else {
            self
        }
    }
}
