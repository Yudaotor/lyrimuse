import AppKit
import LyrimuseCore
import QuartzCore

/// 灵动岛「悬停时淡化」(`AppSettings.notchFadeLyricRowOnHover`):稳态顶行以下那一截(歌词行、掉歌名条、横幅条)只显示、不接指针。
/// 指针压上来时整扇窗切成 `ignoresMouseEvents`,点击、滚动落到下层窗口,这一截整条淡下去露出底下的内容;指针离开这一截就恢复接收。
/// 见 05 章决策 121、124。
///
/// 穿透期间这扇窗收不到任何指针事件,SwiftUI 的悬停也就不来了:指针去哪由全局 / 本地监听器跟踪,再加一个低频兜底,
/// 监听器漏了事件也能及时退出。
///
/// `ignoresMouseEvents` 设过 true 之后再设回 false,AppKit 让整扇窗连透明处都接点击(没设过时透明像素的点击落到下层),
/// 没有公开接口回到没设过的样子,换前台、重新上屏也不行。所以第一次穿透结束后不再把整扇窗设回接点击,改成按指针位置
/// 显式管(`managesHitTesting`):在卡片上收点击、卡片外放过去,监听器从那以后窗口露着就装着(同经典悬浮窗),收起时卸;没穿透过的窗不装。
/// 见 05 章决策 126。
///
/// 淡化挂在 hosting view 的 layer 上(`CALayer.mask`),只在穿透期间存在。别改成 SwiftUI 里常驻的 `.mask`:灵动岛的逐字填色
/// 一直在动,常驻遮罩让整卡每帧多一次离屏合成;按条件挂又会换掉卡片的视图身份、重置里面的状态。
@MainActor
final class NotchLyricRowPassThrough {
    struct Hit {
        var region: NotchHoverHit.Region
        var cardSize: CGSize
        /// 只显示那一截的上沿(卡片局部 y);nil = 此刻整张卡都接指针。
        var bandTop: CGFloat?
    }

    private weak var window: NSWindow?
    private weak var hostView: NSView?
    /// 给一个屏幕坐标,按此刻的卡片矩形和形态判它落在哪一块。
    private let locate: (NSPoint) -> Hit?
    /// 指针离开只显示那一截时调,参数是它现在所在的那一块。
    private let onExit: (NotchHoverHit.Region) -> Void

    private var monitors: [Any] = []
    private var fallbackTimer: Timer?
    private var maskLayer: CALayer?
    /// 顶行那一块,一直不透明。
    private var maskTop: CALayer?
    /// 只显示那一截,透明度在 1 与 `NotchPassThroughFade.opacity` 之间渐变。
    private var maskBand: CALayer?

    /// 兜底复查的间隔:指针移到本 App 别的窗口上时两个监听器都可能收不到。
    private static let fallbackInterval: TimeInterval = 0.25

    init(window: NSWindow?, hostView: NSView?, locate: @escaping (NSPoint) -> Hit?,
         onExit: @escaping (NotchHoverHit.Region) -> Void) {
        self.window = window
        self.hostView = hostView
        self.locate = locate
        self.onExit = onExit
    }

    /// 正在穿透。
    private(set) var isActive = false
    /// 穿透过一次之后按指针位置显式管点击(见头注)。
    private(set) var managesHitTesting = false

    /// Keep the existing pointer monitors and fade mask while the AppKit panel is
    /// replaced to escape a stale Space assignment.
    func replaceWindow(_ window: NSWindow) {
        self.window = window
    }

    /// 设了就拿它代替真指针(屏幕坐标,`debug/notch-pass-through`),只管这一次穿透。
    var debugPointer: NSPoint?
    /// 设了就一直拿它代替真指针(屏幕坐标,`debug/notch-pointer`),直到 `debug/notch-pass-through?off=1` 清掉。
    var stickyPointer: NSPoint?

    private var pointer: NSPoint { debugPointer ?? stickyPointer ?? NSEvent.mouseLocation }

    func begin() {
        guard !isActive, let window else { return }
        isActive = true
        window.ignoresMouseEvents = true
        installMonitors()
        let timer = Timer(timeInterval: Self.fallbackInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
        NotchLyricsWindowController.hoverLog.notice("pass-through begin")
        track()
    }

    /// 卡片尺寸或形态变了(展开、广告开始、换行高)时复查一次:指针没动也可能已经不在只显示那一截上了,
    /// 显式管点击时卡片的范围也跟着变。
    func refresh() {
        if managesHitTesting, window?.isVisible == true { installMonitors() }
        track()
    }

    func end() {
        guard isActive else { return }
        isActive = false
        // 模拟的那一点只管这一次穿透:留着的话下次真指针进来还按它判,退不出去。
        debugPointer = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        // 别设回 false:那样整扇窗连透明处都接点击(见头注)。从这里起按指针位置管。
        managesHitTesting = true
        syncHitTesting()
        unfade()
        NotchLyricsWindowController.hoverLog.notice("pass-through end")
    }

    /// 窗口收起(隐藏)时调:退出穿透、卸监听,不然指针在哪动都唤醒 App。显式管点击照旧(回不去,见头注),
    /// 重新露面时 `refresh()` 把监听装回来。
    func suspend() {
        end()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// 窗口收掉时调:退出穿透、卸监听。
    func stop() {
        end()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        managesHitTesting = false
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.track() }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// 不在穿透时:指针在卡片接指针的那块上收点击,在卡片外(透明区)放过去;落到只显示那一截就转去穿透
    /// (窗口放过点击时 SwiftUI 收不到悬停,只能在这里认)。
    private func syncHitTesting() {
        guard managesHitTesting, !isActive, let window else { return }
        guard window.isVisible, let hit = locate(pointer) else {
            window.ignoresMouseEvents = true
            return
        }
        if hit.region == .passThrough, hit.bandTop != nil {
            begin()
            return
        }
        let ignores = hit.region == .outside
        if window.ignoresMouseEvents != ignores { window.ignoresMouseEvents = ignores }
    }

    private func track() {
        guard isActive else {
            syncHitTesting()
            return
        }
        guard window?.isVisible ?? false, let hit = locate(pointer) else {
            end()
            onExit(.outside)
            return
        }
        guard hit.region == .passThrough, let bandTop = hit.bandTop else {
            end()
            onExit(hit.region)
            return
        }
        fade(bandTop: bandTop, cardSize: hit.cardSize)
    }

    // MARK: - 淡化

    private func fade(bandTop: CGFloat, cardSize: CGSize) {
        guard let hostView, let layer = hostView.layer else { return }
        let opening = maskLayer == nil
        if opening { installMask(on: layer) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = layer.bounds
        maskLayer?.frame = bounds
        // 卡片贴着窗口顶边,上沿那条线以上是顶行(整宽都算:卡片两侧本来就是透明区)。
        let lineY = hostView.isFlipped ? bandTop : bounds.height - bandTop
        let top = hostView.isFlipped
            ? CGRect(x: 0, y: 0, width: bounds.width, height: lineY)
            : CGRect(x: 0, y: lineY, width: bounds.width, height: bounds.height - lineY)
        let band = hostView.isFlipped
            ? CGRect(x: 0, y: lineY, width: bounds.width, height: bounds.height - lineY)
            : CGRect(x: 0, y: 0, width: bounds.width, height: lineY)
        maskTop?.frame = top
        maskBand?.frame = band
        CATransaction.commit()
        // 正在淡回(刚离开又压回来)时模型值已经是 1,接着从当前样子淡下去。
        if opening || maskBand?.opacity != NotchPassThroughFade.opacity { animateBand(to: NotchPassThroughFade.opacity) }
    }

    private func installMask(on layer: CALayer) {
        let container = CALayer()
        let top = CALayer()
        top.backgroundColor = NSColor.black.cgColor
        let band = CALayer()
        band.backgroundColor = NSColor.black.cgColor
        container.addSublayer(top)
        container.addSublayer(band)
        layer.mask = container
        maskLayer = container
        maskTop = top
        maskBand = band
    }

    private func animateBand(to opacity: Float, completion: (() -> Void)? = nil) {
        guard let band = maskBand else { completion?(); return }
        CATransaction.begin()
        // 只走下面这条显式动画:独立 layer 改模型值会自带一条 0.25 秒的隐式动画,叠在一起淡完会先跳回一截再落下去。
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = band.presentation()?.opacity ?? band.opacity
        animation.toValue = opacity
        animation.duration = NotchPassThroughFade.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        band.opacity = opacity
        band.add(animation, forKey: "fade")
        CATransaction.commit()
    }

    /// 淡回不透明之后才摘遮罩:直接摘掉会一下子跳回来。淡回途中又穿透了就接着用这一份。
    private func unfade() {
        guard let container = maskLayer else { return }
        animateBand(to: 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isActive, self.maskLayer === container else { return }
                self.hostView?.layer?.mask = nil
                self.maskLayer = nil
                self.maskTop = nil
                self.maskBand = nil
            }
        }
    }
}
