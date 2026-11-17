import AppKit
import LyrimuseCore
import os
import ScreenCaptureKit

/// 进 / 出迷你的变形动画(07 章决策 125):完整尺寸那扇窗和迷你面板之间交接(决策 133)。
///
/// 真窗口自己不做尺寸动画:它的内容区就是 SwiftUI 的宿主视图,尺寸每变一帧整窗重排一遍,AppKit 的窗口尺寸
/// 动画本身也是主线程逐帧推,主线程一忙就掉帧。这里另起一扇透明、不接鼠标的临时窗,上面一张卡片:先摆切换前
/// 那张窗口截图,从旧 frame 走到新 frame;目标窗口换好新布局后截第二张,叠在旧图上淡入。卡片的几何和淡入都是
/// 显式的 Core Animation 动画,提交后由渲染进程逐帧合成,主线程这时在重排新布局也不影响。
///
/// 目标窗口跟第一张截图同时备好、截第二张,卡片起步时两张图都在手里,新图跟卡片几何同一条曲线、同一时长淡入:
/// 内容换成新布局的进度跟尺寸走到哪一步一致。别写成卡片起步之后才开目标窗口、截第二张:曲线起步快,
/// 新图晚到时尺寸已经走完,看着是先变大、后换内容(07 章决策 205)。卡片几何一开始就交给渲染进程、推迟 `newImageWait` 起步,新图在那之前到了就一起提前起步,
/// 没到就按时起步、到了再补淡入:目标窗口排版占住主线程时,卡片停在原处的时间也不超过 `newImageWait`。
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
    private static let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-window-morph")

    /// 从截第一张到临时窗撤掉这一整段。期间真窗口的层级归这里管。
    private(set) var isRunning = false
    /// 动画期间别处要改真窗口的层级(切迷你时的置顶)写这里,收尾时一起还。直接写 `window.level` 会把藏在桌面
    /// 以下的真窗口提前亮出来。
    var levelAfterMorph: NSWindow.Level?

    private var warmFilter: (id: CGWindowID, filter: SCContentFilter, at: CFTimeInterval)?
    /// 目标窗口藏在桌面以下的这段里,它自己的控制器挂上来时会直接改层级(迷你面板默认置顶),把它顶到卡片上面。
    /// 这里每拍看一眼,被改了就记下要的层级、压回桌面以下,收尾时按记下的还。
    private var hold: (window: NSWindow, wanted: NSWindow.Level?, timer: Timer)?
    private var isWarming = false

    /// 藏真窗口用的层级:桌面图片那一层之下。
    static let hiddenLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    /// 预热拿到的过滤器多久内可以直接拿来截第一张(指针移到键上到点下去通常一两秒)。
    private static let warmFilterLifetime: CFTimeInterval = 5
    /// 临时窗上屏、真窗口回到原层级之后,各等这么久再动下一步,不留空帧。
    private static let settleFrames: Double = 2.0 / 60

    /// 这一次能不能做动画。不能就由调用方直接切。迷你开着「截屏时隐藏」时不做:面板 `sharingType = .none`,
    /// 截出来是空白(07 章决策 209)。
    static func canAnimate(_ window: NSWindow, to target: NSRect) -> Bool {
        guard #available(macOS 14.4, *) else { return false }
        return !AppSettings.shared.lyricsWindowMiniHideDuringScreenCapture
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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

    /// 从 `source` 交接到另一扇窗,停在 `target`。`prepare` 由调用方实现:把目标窗口摆到 `target`,交回来(交 nil = 没开出来);
    /// 交回来的窗口由这里藏到桌面以下再上屏、截图、淡入,落地后回到它交回来时的层级。`finish` 在目标窗口接手之后调,由调用方
    /// 关掉 `source`;没开出来时不调 `finish`,`source` 回到原层级,改调 `failed`。不管动画做不做得成,`prepare` 都恰好调一次。
    func handoff(from source: NSWindow, to target: NSRect,
                 prepare: @escaping @MainActor (@escaping (NSWindow?) -> Void) -> Void,
                 finish: @escaping @MainActor (NSWindow) -> Void,
                 failed: @escaping @MainActor () -> Void) {
        isRunning = true
        levelAfterMorph = nil
        Task { await perform(source, target, prepare, finish, failed) }
    }

    private func perform(_ source: NSWindow, _ target: NSRect,
                         _ prepare: @escaping @MainActor (@escaping (NSWindow?) -> Void) -> Void,
                         _ finish: @escaping @MainActor (NSWindow) -> Void,
                         _ failed: @escaping @MainActor () -> Void) async {
        let start = source.frame
        let scale = source.backingScaleFactor
        let sourceLevel = source.level
        let wasKey = source.isKeyWindow
        let t0 = CACurrentMediaTime()
        // 目标窗口跟第一张截图同时备:摆好、在桌面以下上屏(用户看不见,截得到它的新内容)、截第二张。
        let staged = Task { @MainActor () -> (window: NSWindow, level: NSWindow.Level)? in
            let window: NSWindow? = await withCheckedContinuation { (done: CheckedContinuation<NSWindow?, Never>) in
                Task { @MainActor in prepare { done.resume(returning: $0) } }
            }
            guard let window else { return nil }
            let level = window.level
            window.level = Self.hiddenLevel
            self.holdHidden(window)
            if !window.isVisible { window.orderFrontRegardless() }
            return (window, level)
        }
        let newImage = Task { @MainActor () -> CGImage? in
            guard let window = await staged.value?.window else { return nil }
            let stagedAt = CACurrentMediaTime()
            await Self.pause(1.0 / 60)
            guard !Task.isCancelled else { return nil }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            let image = await self.capture(window, allowWarm: false, timeout: Plan.secondCaptureTimeout)
            Self.log.info("form morph: destination \(Self.ms(stagedAt - t0), privacy: .public) ms, new image \(image == nil ? "none" : "\(Self.ms(CACurrentMediaTime() - t0)) ms", privacy: .public)")
            return image
        }
        guard let old = await capture(source, allowWarm: true, timeout: Plan.firstCaptureTimeout),
              source.isVisible, source.frame == start else {
            newImage.cancel()
            guard let (destination, level) = await staged.value else {
                isRunning = false
                return failed()
            }
            // 不做动画:目标窗口从桌面以下直接回到它的层级(动画期间别处要改的那份优先)。
            let wanted = releaseHold()
            destination.level = levelAfterMorph ?? wanted ?? level
            levelAfterMorph = nil
            destination.orderFrontRegardless()
            isRunning = false
            finish(destination)
            return
        }
        let oldAt = CACurrentMediaTime()
        let overlay = MorphOverlay(frame: Plan.overlayFrame(from: start, to: target), level: sourceLevel, scale: scale,
                                   keyShadow: wasKey)
        overlay.show(old, at: start, cornerRadius: Self.cornerRadius(of: old, scale: scale))
        CATransaction.flush()
        await Self.pause(Self.settleFrames)

        source.level = Self.hiddenLevel
        // 卡片几何先交给渲染进程、推迟 `newImageWait` 起步:目标窗口排版把主线程占住时,卡片照样按时动。
        // 新图赶在起步前到了就让卡片和新图从这一刻一起起步。
        let timing = CAMediaTimingFunction(controlPoints: Plan.curve.0, Plan.curve.1, Plan.curve.2, Plan.curve.3)
        var begin = CACurrentMediaTime() + Plan.newImageWait
        overlay.animate(from: start, to: target, duration: Plan.duration, timing: timing, delay: Plan.newImageWait)
        CATransaction.flush()
        // `.some(nil)` = 没开出来或没截到,nil = 等超时。
        let early = await Self.value(of: newImage, within: Plan.newImageWait)
        var withMotion = false
        if let new = early ?? nil, CACurrentMediaTime() < begin {
            begin = CACurrentMediaTime()
            overlay.animate(from: start, to: target, duration: Plan.duration, timing: timing, delay: 0)
            overlay.fadeIn(new, duration: Plan.duration, timing: timing, delay: 0)
            CATransaction.flush()
            withMotion = true
        }

        guard let (destination, destinationLevel) = await staged.value else {
            _ = releaseHold()
            source.level = sourceLevel
            overlay.fadeOut(duration: Plan.fadeOutUnmatched) { [weak self] in
                MainActor.assumeIsolated {
                    overlay.close()
                    self?.isRunning = false
                }
            }
            failed()
            return
        }
        var new = early ?? nil
        if early == nil { new = await newImage.value }
        var landing = begin + Plan.duration
        var crossfade = withMotion ? "with motion" : "none"
        if !withMotion, let late = new {
            let now = CACurrentMediaTime()
            if now < begin {
                overlay.fadeIn(late, duration: Plan.duration, timing: timing, delay: begin - now)
                crossfade = "with motion"
            } else {
                let fade = Plan.crossfadeDuration(elapsed: now - begin)
                overlay.fadeIn(late, duration: fade, timing: CAMediaTimingFunction(name: .easeInEaseOut), delay: 0)
                landing = max(landing, now + fade)
                crossfade = "late +\(Self.ms(now - begin)) ms"
            }
            CATransaction.flush()
        }
        Self.log.info("form morph: old image \(Self.ms(oldAt - t0), privacy: .public) ms, motion start \(Self.ms(begin - t0), privacy: .public) ms, crossfade \(crossfade, privacy: .public)")
        let wait = landing - CACurrentMediaTime()
        if wait > 0 { await Self.pause(wait) }

        // 目标窗口回到它的层级(动画期间别处要改的那份优先),此刻它正好在卡片底下、跟新图对齐;源窗口交给调用方关掉。
        // 层级不看在不在屏:落地前被「暂停时隐藏」这类规则藏起的,下次摆出来不能还在桌面以下。
        let wanted = releaseHold()
        destination.level = levelAfterMorph ?? wanted ?? destinationLevel
        // 迷你面板不当 main,也不抢 key。
        if destination.isVisible, wasKey, destination.canBecomeMain { destination.makeKey() }
        levelAfterMorph = nil
        finish(destination)
        // 关掉的源窗口层级还回去:SwiftUI 关掉场景窗后留着它,下次开出来复用同一扇,停在桌面以下就看不见了(07 章决策 135)。
        source.level = sourceLevel
        CATransaction.flush()
        await Self.pause(Self.settleFrames)
        overlay.fadeOut(duration: new == nil ? Plan.fadeOutUnmatched : Plan.fadeOutMatched) { [weak self] in
            MainActor.assumeIsolated {
                overlay.close()
                self?.isRunning = false
            }
        }
    }

    private func holdHidden(_ window: NSWindow) {
        hold?.timer.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassertHidden() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hold = (window, nil, timer)
    }

    private func reassertHidden() {
        guard let held = hold, held.window.level != Self.hiddenLevel else { return }
        hold?.wanted = held.window.level
        held.window.level = Self.hiddenLevel
    }

    /// 停掉看守,交回藏着期间被改成的层级(没人改过是 nil)。
    private func releaseHold() -> NSWindow.Level? {
        reassertHidden()
        let wanted = hold?.wanted
        hold?.timer.invalidate()
        hold = nil
        if let wanted { Self.log.info("form morph: destination asked for level \(wanted.rawValue, privacy: .public) while hidden") }
        return wanted
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

    /// `task` 在 `seconds` 秒内交出结果就返回它,否则返回 nil;任务照跑,之后还能再取。
    private static func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
        await withCheckedContinuation { (result: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce()
            Task { @MainActor in
                let value = await task.value
                if once.claim() { result.resume(returning: value) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if once.claim() { result.resume(returning: nil) }
            }
        }
    }

    private static func ms(_ seconds: CFTimeInterval) -> Int { Int((seconds * 1000).rounded()) }

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

/// 临时窗本身。上沿伸进菜单栏或屏幕外时,AppKit 上屏会把普通窗口往下推,卡片跟着整体下移、跟真窗口对不上;
/// 这里原样返回,窗口留在要的位置(伸出去的只是透明的阴影位,07 章决策 128)。
private final class MorphWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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

    init(frame: NSRect, level: NSWindow.Level, scale: CGFloat, keyShadow: Bool) {
        let window = MorphWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
        // 阴影照系统窗口阴影:焦点窗口大而深、往下偏得多,非焦点窗口小而浅(数值见 07 章决策 125)。
        // 切换那一刻真窗口是哪种就照哪种画,卡片跟真窗口换上换下那一下阴影不跳。
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = keyShadow ? 0.42 : 0.22
        card.shadowRadius = keyShadow ? 20 : 8
        card.shadowOffset = CGSize(width: 0, height: keyShadow ? -16 : -7)
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

    /// 卡片从 `start` 走到 `rect`:位置、尺寸、阴影路径三样同一条曲线,`delay` 秒后起步(起步前停在 `start`)。
    /// 再调一次换掉上一次的那组动画。
    func animate(from start: NSRect, to rect: NSRect, duration: Double, timing: CAMediaTimingFunction, delay: Double) {
        let from = local(start)
        let fromBounds = CGRect(origin: .zero, size: from.size)
        let fromPath = CGPath(roundedRect: fromBounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(local(rect))
        CATransaction.commit()
        let beginTime = card.convertTime(CACurrentMediaTime(), from: nil) + delay
        func animate(_ layer: CALayer, _ keyPath: String, from: Any?, to: Any?) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = timing
            animation.beginTime = beginTime
            animation.fillMode = .backwards
            layer.add(animation, forKey: "morph." + keyPath)
        }
        animate(card, "position", from: NSValue(point: from.origin), to: NSValue(point: card.position))
        for layer in [card, clip, oldImage, newImage] {
            animate(layer, "bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: card.bounds))
        }
        animate(card, "shadowPath", from: fromPath, to: card.shadowPath)
    }

    /// 新图叠在旧图上淡入。旧图垫在底下不动,省得两张一起半透明时透出背后的桌面。
    func fadeIn(_ image: CGImage, duration: Double, timing: CAMediaTimingFunction, delay: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        newImage.contents = image
        newImage.opacity = 1
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = timing
        animation.beginTime = newImage.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .backwards
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
