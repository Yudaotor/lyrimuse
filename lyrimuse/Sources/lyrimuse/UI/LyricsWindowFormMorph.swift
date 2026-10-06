import AppKit
import LyrimuseCore
import ScreenCaptureKit

/// 进 / 出迷你的变形动画(07 章决策 125)。
///
/// 真窗口自己不做尺寸动画:它的内容区就是 SwiftUI 的宿主视图,尺寸每变一帧整窗重排一遍,AppKit 的窗口尺寸
/// 动画本身也是主线程逐帧推,主线程一忙就掉帧。这里另起一扇透明、不接鼠标的临时窗,上面一张卡片:先摆切换前
/// 那张窗口截图,从旧 frame 走到新 frame;真窗口换好新布局后截第二张,叠在旧图上淡入。卡片的几何和淡入都是
/// 显式的 Core Animation 动画,提交后由渲染进程逐帧合成,主线程这时在重排新布局也不影响。
///
/// 动画期间真窗口降到桌面层级以下:用户看不见,截图照样截得到最新内容。别改成调透明度或挪到屏幕外 ——
/// 透明度为 0 的窗口截出来全透明,带标题栏的窗口挪出屏幕会被系统拉回屏内。
///
/// 截图走 `SCShareableContent.currentProcess`(macOS 14.4 起),只列本进程自己的窗口、不经录屏授权。别换成
/// 不带 Process 的那个 `current`:那条要录屏授权。第一张截不到(系统太旧、截图失败或超时)就不做动画、直接切;
/// 第二张截不到就跳过淡入,卡片落地后直接把旧图淡成真窗口。
@MainActor
final class LyricsWindowFormMorph {
    private typealias Plan = LyricsWindowFormMorphPlan

    /// 从截第一张到临时窗撤掉这一整段。期间真窗口的层级归这里管。
    private(set) var isRunning = false
    /// 动画期间别处要改真窗口的层级(切迷你时的置顶)写这里,收尾时一起还。直接写 `window.level` 会把藏在桌面
    /// 以下的真窗口提前亮出来。
    var levelAfterMorph: NSWindow.Level?

    private var warmFilter: (id: CGWindowID, filter: SCContentFilter, at: CFTimeInterval)?
    private var isWarming = false

    /// 藏真窗口用的层级:桌面图片那一层之下。
    private static let hiddenLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    /// 预热拿到的过滤器多久内可以直接拿来截第一张(指针移到键上到点下去通常一两秒)。
    private static let warmFilterLifetime: CFTimeInterval = 5
    /// 临时窗上屏、真窗口回到原层级之后,各等这么久再动下一步,不留空帧。
    private static let settleFrames: Double = 2.0 / 60

    /// 这一次能不能做动画。不能就由调用方直接切。
    static func canAnimate(_ window: NSWindow, to target: NSRect) -> Bool {
        guard #available(macOS 14.4, *) else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
            && Plan.sameScreen(window.frame, target, screens: NSScreen.screens.map(\.frame))
    }

    /// 指针移到切换键上时调:截图服务冷启动第一张要 300 多毫秒,等点下去才叫醒就赶不上
    /// `firstCaptureTimeout`,只能放弃动画。这里先把它叫醒、把这扇窗的截图过滤器备好。
    func prewarm(_ window: NSWindow) {
        guard #available(macOS 14.4, *), !isRunning, !isWarming else { return }
        let id = CGWindowID(window.windowNumber)
        if let warm = warmFilter, warm.id == id, CACurrentMediaTime() - warm.at < Self.warmFilterLifetime { return }
        isWarming = true
        Task {
            defer { isWarming = false }
            guard let filter = await Self.freshFilter(id) else { return }
            warmFilter = (id, filter, CACurrentMediaTime())
            let cfg = SCStreamConfiguration()
            cfg.width = 16
            cfg.height = 16
            cfg.showsCursor = false
            _ = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        }
    }

    /// 切到 `target`。`apply` 由调用方实现:改形态、把真窗口一步摆到 `target`,全部做完调它收到的回调。
    /// 不管动画做不做得成,`apply` 都恰好调一次。
    func run(window: NSWindow, to target: NSRect, apply: @escaping @MainActor (@escaping () -> Void) -> Void) {
        isRunning = true
        levelAfterMorph = nil
        Task { await perform(window, target, apply) }
    }

    private func perform(_ window: NSWindow, _ target: NSRect,
                         _ apply: @escaping @MainActor (@escaping () -> Void) -> Void) async {
        let start = window.frame
        let scale = window.backingScaleFactor
        guard let old = await capture(window, allowWarm: true, timeout: Plan.firstCaptureTimeout),
              window.isVisible, window.frame == start else {
            isRunning = false
            apply {}
            return
        }
        let levelBefore = window.level
        let overlay = MorphOverlay(frame: Plan.overlayFrame(from: start, to: target), level: levelBefore, scale: scale)
        overlay.show(old, at: start, cornerRadius: Self.cornerRadius(of: old, scale: scale))
        CATransaction.flush()
        await Self.pause(Self.settleFrames)

        let wasKey = window.isKeyWindow
        window.level = Self.hiddenLevel
        let begin = CACurrentMediaTime()
        overlay.animate(to: target, duration: Plan.duration,
                        timing: CAMediaTimingFunction(controlPoints: Plan.curve.0, Plan.curve.1, Plan.curve.2, Plan.curve.3))
        CATransaction.flush()

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task { @MainActor in apply { done.resume() } }
        }
        await Self.pause(1.0 / 60)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let new = await capture(window, allowWarm: false, timeout: Plan.secondCaptureTimeout)
        var landing = begin + Plan.duration
        if let new {
            let now = CACurrentMediaTime()
            let fade = Plan.crossfadeDuration(elapsed: now - begin)
            overlay.fadeIn(new, duration: fade)
            CATransaction.flush()
            landing = max(landing, now + fade)
        }
        let wait = landing - CACurrentMediaTime()
        if wait > 0 { await Self.pause(wait) }

        // 真窗口回到原层级(动画期间别处要改的那份优先),此刻它正好在卡片底下、跟新图对齐。
        if window.isVisible {
            window.level = levelAfterMorph ?? levelBefore
            if wasKey { window.makeKey() }
        }
        levelAfterMorph = nil
        CATransaction.flush()
        await Self.pause(Self.settleFrames)
        overlay.fadeOut(duration: new == nil ? Plan.fadeOutUnmatched : Plan.fadeOutMatched) { [weak self] in
            MainActor.assumeIsolated {
                overlay.close()
                self?.isRunning = false
            }
        }
    }

    /// 截这扇窗此刻的样子(不带阴影,按屏幕倍率出像素)。`timeout` 秒内没回来当没截到。
    private func capture(_ window: NSWindow, allowWarm: Bool, timeout: Double) async -> CGImage? {
        guard #available(macOS 14.4, *) else { return nil }
        let id = CGWindowID(window.windowNumber)
        let scale = window.backingScaleFactor
        let size = window.frame.size
        var warm: SCContentFilter?
        if allowWarm, let w = warmFilter, w.id == id, CACurrentMediaTime() - w.at < Self.warmFilterLifetime {
            warm = w.filter
        }
        let preset = warm
        return await Self.withTimeout(timeout) {
            let fetched: SCContentFilter?
            if let preset { fetched = preset } else { fetched = await Self.freshFilter(id) }
            guard let filter = fetched else { return nil }
            let cfg = SCStreamConfiguration()
            cfg.width = Int((size.width * scale).rounded())
            cfg.height = Int((size.height * scale).rounded())
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        }
    }

    @available(macOS 14.4, *)
    private static func freshFilter(_ id: CGWindowID) async -> SCContentFilter? {
        guard let content = try? await SCShareableContent.currentProcess,
              let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        return SCContentFilter(desktopIndependentWindow: window)
    }

    private static func withTimeout(_ seconds: Double,
                                    _ work: @escaping @MainActor () async -> CGImage?) async -> CGImage? {
        await withCheckedContinuation { (result: CheckedContinuation<CGImage?, Never>) in
            let once = ResumeOnce()
            Task { @MainActor in
                let image = await work()
                if once.claim() { result.resume(returning: image) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if once.claim() { result.resume(returning: nil) }
            }
        }
    }

    /// 截图的圆角半径(点):读左上角对角线上的 alpha,交给 `LyricsWindowFormMorphPlan.cornerRadius`。
    private static func cornerRadius(of image: CGImage, scale: CGFloat) -> CGFloat {
        guard image.bitsPerPixel == 32, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
        else { return Plan.fallbackCornerRadius }
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let alphaFirst = [.premultipliedFirst, .first, .noneSkipFirst].contains(image.alphaInfo)
        let offset = alphaFirst != little ? 0 : 3
        let n = min(64, image.width, image.height)
        let diagonal = (0..<n).map { bytes[$0 * image.bytesPerRow + $0 * 4 + offset] }
        return Plan.cornerRadius(diagonalAlpha: diagonal, scale: scale) ?? Plan.fallbackCornerRadius
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// 超时与截图回来两条路只有先到的那条能交差。两条都在主线程上走。
private final class ResumeOnce: @unchecked Sendable {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

/// 变形动画那扇临时窗:无边框、透明、不接鼠标、不进窗口循环。卡片 = 阴影层 ⊃ 圆角裁切层 ⊃ 旧图 / 新图两层,
/// 两张图都按卡片尺寸等比铺满(多出来的裁掉)。图层用 AppKit 默认的 y 轴向上坐标,跟屏幕坐标同向,
/// 换算只减临时窗原点。
@MainActor
private final class MorphOverlay {
    private let window: NSWindow
    private let origin: CGPoint
    private let card = CALayer()
    private let clip = CALayer()
    private let oldImage = CALayer()
    private let newImage = CALayer()
    private var radius = LyricsWindowFormMorphPlan.fallbackCornerRadius

    init(frame: NSRect, level: NSWindow.Level, scale: CGFloat) {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.level = level
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        window.contentView = host
        self.window = window
        origin = frame.origin

        for layer in [card, clip, oldImage, newImage] {
            layer.anchorPoint = .zero
            layer.position = .zero
            layer.contentsScale = scale
        }
        // 阴影照系统窗口的样子:偏下,往下拖得比往上长。
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.3
        card.shadowRadius = 14
        card.shadowOffset = CGSize(width: 0, height: -8)
        clip.masksToBounds = true
        for image in [oldImage, newImage] { image.contentsGravity = .resizeAspectFill }
        newImage.opacity = 0
        clip.addSublayer(oldImage)
        clip.addSublayer(newImage)
        card.addSublayer(clip)
        host.layer?.addSublayer(card)
    }

    func show(_ image: CGImage, at rect: NSRect, cornerRadius: CGFloat) {
        radius = cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        oldImage.contents = image
        clip.cornerRadius = radius
        place(local(rect))
        CATransaction.commit()
        window.orderFrontRegardless()
    }

    /// 卡片走到 `rect`:位置、尺寸、阴影路径三样同一条曲线。
    func animate(to rect: NSRect, duration: Double, timing: CAMediaTimingFunction) {
        let fromPosition = card.position
        let fromBounds = card.bounds
        let fromPath = card.shadowPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(local(rect))
        CATransaction.commit()
        func animate(_ layer: CALayer, _ keyPath: String, from: Any?, to: Any?) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = timing
            layer.add(animation, forKey: "morph." + keyPath)
        }
        animate(card, "position", from: NSValue(point: fromPosition), to: NSValue(point: card.position))
        for layer in [card, clip, oldImage, newImage] {
            animate(layer, "bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: card.bounds))
        }
        animate(card, "shadowPath", from: fromPath, to: card.shadowPath)
    }

    /// 新图叠在旧图上淡入。旧图垫在底下不动,省得两张一起半透明时透出背后的桌面。
    func fadeIn(_ image: CGImage, duration: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        newImage.contents = image
        newImage.opacity = 1
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        newImage.add(animation, forKey: "morph.fade")
    }

    func fadeOut(duration: Double, completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        card.opacity = 0
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = duration
        card.add(animation, forKey: "morph.out")
        CATransaction.commit()
    }

    func close() {
        window.orderOut(nil)
    }

    private func local(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX - origin.x, y: rect.minY - origin.y, width: rect.width, height: rect.height)
    }

    private func place(_ rect: CGRect) {
        let bounds = CGRect(origin: .zero, size: rect.size)
        card.position = rect.origin
        for layer in [card, clip, oldImage, newImage] { layer.bounds = bounds }
        card.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
