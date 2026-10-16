import AppKit
import QuartzCore
import SwiftUI

/// 把一块**静态**的 SwiftUI 内容交给 Core Animation 做横向往复:靠左伸缩(`stretch`),或左右平移(`slide`)。
///
/// 跟 `LayerBreathing` / `LayerFloating` 同一个思路:内容只画一次(`NSHostingView`),往复挂在宿主图层的
/// `sublayerTransform` 上(原点在图层左下角,所以横向缩放天然靠左),装好之后由渲染服务播,主线程不参与。
/// 别换回 SwiftUI 的 `.repeatForever`:那是主线程逐帧推进,窗口被挡住、最小化也照跑(引导页四张示意图
/// 实测屏幕外的窗口里仍占约 1.3% CPU,见 14 章决策 109)。
///
/// 动画从 `motion` 给的那一端走到原样再走回来;摘掉动画时停在原样(整条、原位)。`animating` = false
/// (系统开了减弱动态效果)或所在窗口看不见(`occlusionState` 不含 `.visible`:被挡住、最小化、在别的桌面)
/// 时摘掉,窗口重新看得见时重装。
struct LayerLoop<Content: View>: NSViewRepresentable {
    var motion: LayerLoopMotion
    /// 单程时长(秒);往返一次是它的两倍,同 `.easeInOut(duration:).repeatForever(autoreverses: true)`。
    var duration: Double = 1.4
    var animating: Bool
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> LayerLoopNSView {
        LayerLoopNSView(rootView: AnyView(content))
    }

    func updateNSView(_ view: LayerLoopNSView, context: Context) {
        view.hosting.rootView = AnyView(content)
        view.configure(motion: motion, duration: duration, animating: animating)
    }

    /// 内容是填满的形状,没有自己的尺寸:调用方用 `.frame` 给多大就多大。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayerLoopNSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// `LayerLoop` 往复的那一端。
enum LayerLoopMotion: Equatable {
    /// 靠左缩到 `from` 倍宽,再伸回整条。
    case stretch(from: CGFloat)
    /// 横向挪开 `from` 点(负数往左),再回原位。
    case slide(from: CGFloat)
}

@MainActor
final class LayerLoopNSView: NSView {
    private static let loopKey = "lyrimuse.loop"

    let hosting: NSHostingView<AnyView>
    private var motion: LayerLoopMotion = .slide(from: 0)
    private var duration: Double = 1
    private var animating = false
    private var windowVisible = false
    private var occlusionObserver: NSObjectProtocol?
    /// 上一次装动画时的尺寸:只有它变了(或开关 / 参数 / 可见性变了)才重装,SwiftUI 的每次重估不打断正在跑的那一条。
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

    func configure(motion: LayerLoopMotion, duration: Double, animating: Bool) {
        let changed = self.motion != motion || self.duration != duration || self.animating != animating
        self.motion = motion
        self.duration = duration
        self.animating = animating
        if changed { reinstall() }
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        if installedSize != bounds.size { reinstall() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            // 还没上屏时 occlusionState 也不含 .visible,上屏后系统会补一次通知,那时再装。
            windowVisible = window.occlusionState.contains(.visible)
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] note in
                guard let win = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let visible = win.occlusionState.contains(.visible)
                    guard visible != self.windowVisible else { return }
                    self.windowVisible = visible
                    self.reinstall()
                }
            }
        }
        reinstall()
    }

    private func reinstall() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.loopKey)
        installedSize = bounds.size
        guard animating, windowVisible, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let from: CATransform3D = switch motion {
        case .stretch(let from): CATransform3DMakeScale(from, 1, 1)
        case .slide(let from): CATransform3DMakeTranslation(from, 0, 0)
        }
        let loop = CABasicAnimation(keyPath: "sublayerTransform")
        loop.fromValue = NSValue(caTransform3D: from)
        loop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        loop.duration = duration
        loop.autoreverses = true
        loop.repeatCount = .infinity
        loop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // 一秒多一个来回的小示意,合成器不必按 ProMotion 120Hz 去插值。
        loop.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        layer.add(loop, forKey: Self.loopKey)
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }
}
