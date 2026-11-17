import AppKit

/// 把标题栏三颗原生按钮(红绿灯)挪到自定义位置,并负责它们的显隐。
///
/// 系统每次重排标题栏(`-[NSThemeFrame _tileTitlebarAndRedisplay:]`)都把三颗按钮拉回默认位。切任何一颗的
/// `isHidden` 就会当场触发这次重排,所以显隐一律走 `setHidden`,写完同一拍摆回去;别直接写按钮的 `isHidden`
/// 再等别处(`didUpdate`)补摆 —— 没有事件进来时那一下不来,按钮就停在默认位上露出来。改标题、窗口开始 /
/// 停止被录制这类别处触发的重排由 `track` 兜底。见 07 章决策 203。
///
/// 指针进三颗按钮那一组才画 × − ⤢,判据是系统挂在窗口框架上的一块组跟踪区。它按挂上那一刻按钮在哪来画,挪按钮
/// 不跟着走,只在系统重排标题栏时重挂(那时按钮刚被拉回默认位),所以摆完要让它按新位置重挂,见 07 章决策 210。
@MainActor
public final class TitlebarButtonPlacement {
    public static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// 关闭键中心离窗口左边的距离;整组跟着关闭键平移,保留系统自己的按钮间距。
    public let closeCenterX: CGFloat
    /// 按钮顶边离父视图顶边的距离。钉常量、不记首次量到的值:父视图有时是窗口框架、有时是标题栏容器,
    /// 两者高度不同,记下来的绝对 y 或离顶距离换个父视图就对不上。
    public let topMargin: CGFloat
    /// 各按钮的系统默认 x,第一次摆之前一次记齐(只有从系统默认位才量得准相对间距)。
    private var defaultXs: [NSWindow.ButtonType.RawValue: CGFloat] = [:]
    /// 自己在写按钮(摆位、设显隐)期间,按钮的位置变化不算被系统挪走。
    private var writing = false
    private var repositionPending = false
    private weak var trackedWindow: NSWindow?
    private var trackObservers: [NSObjectProtocol] = []
    private var canPlace: () -> Bool = { true }
    private let schedule: (@escaping @Sendable () -> Void) -> Void
    private static let updateHoverTracking = NSSelectorFromString("_updateMouseTracking")

    /// `schedule` 决定 `track` 发现按钮被挪走后在哪一拍摆回去,默认排进主线程这一轮休眠之前(早于画面提交)。
    public init(closeCenterX: CGFloat, topMargin: CGFloat,
                schedule: @escaping (@escaping @Sendable () -> Void) -> Void = { RunLoop.main.perform(inModes: [.common], block: $0) }) {
        self.closeCenterX = closeCenterX
        self.topMargin = topMargin
        self.schedule = schedule
    }

    /// 摆到目标位;已经在目标位上不写(放在 `didUpdate` 这类每拍都来的通知里不自激)。
    public func place(in window: NSWindow) {
        if defaultXs.isEmpty {
            for type in Self.buttonTypes {
                guard let button = window.standardWindowButton(type) else { continue }
                defaultXs[type.rawValue] = button.frame.origin.x
            }
        }
        guard let closeButton = window.standardWindowButton(.closeButton),
              let superview = closeButton.superview,
              let closeDefaultX = defaultXs[NSWindow.ButtonType.closeButton.rawValue]
        else { return }
        let dx = (closeCenterX - closeButton.frame.width / 2) - closeDefaultX
        // AppKit y 向上,从父视图高度往下减。
        let targetY = superview.bounds.height - topMargin - closeButton.frame.height
        let wasWriting = writing
        writing = true
        defer { writing = wasWriting }
        var moved = false
        for type in Self.buttonTypes {
            guard let button = window.standardWindowButton(type),
                  let defaultX = defaultXs[type.rawValue] else { continue }
            let targetX = defaultX + dx
            if abs(button.frame.origin.y - targetY) > 0.5 || abs(button.frame.origin.x - targetX) > 0.5 {
                button.setFrameOrigin(NSPoint(x: targetX, y: targetY))
                moved = true
            }
        }
        if moved { Self.hoverOwner(of: closeButton)?.perform(Self.updateHoverTracking) }
    }

    /// 挂组跟踪区的那个视图(窗口框架):从按钮往上第一个认 `_updateMouseTracking` 的。
    private static func hoverOwner(of button: NSView) -> NSView? {
        var view = button.superview
        while let current = view, !current.responds(to: updateHoverTracking) { view = current.superview }
        return view
    }

    /// 三颗露着的按钮的外接矩形和那块组跟踪区,窗口坐标(左上原点);给 `debug/state` 和 selftest 对账。
    public static func hoverGeometry(in window: NSWindow) -> (buttons: CGRect, hoverArea: CGRect?)? {
        let buttons = buttonTypes.compactMap { window.standardWindowButton($0) }.filter { !$0.isHidden }
        guard let first = buttons.first, let owner = hoverOwner(of: first) else { return nil }
        let height = window.frame.height
        func topLeft(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        let union = buttons.map { $0.convert($0.bounds, to: nil) }.reduce(CGRect.null) { $0.union($1) }
        let area = owner.trackingAreas
            .first { $0.owner === owner && $0.rect.width < 200 && $0.rect.height < 60 }
            .map { topLeft(owner.convert($0.rect, to: nil)) }
        return (topLeft(union), area)
    }

    /// 按 `hidden(type)` 设三颗按钮的显隐,真有一颗翻了就当场摆回目标位。`reposition` 为 false 时只设显隐
    /// (原生全屏里标题栏归系统管)。返回这次有没有翻。
    @discardableResult
    public func setHidden(in window: NSWindow, reposition: Bool = true,
                          _ hidden: (NSWindow.ButtonType) -> Bool) -> Bool {
        var changed = false
        let wasWriting = writing
        writing = reposition
        for type in Self.buttonTypes {
            let hide = hidden(type)
            if let button = window.standardWindowButton(type), button.isHidden != hide {
                button.isHidden = hide
                changed = true
            }
        }
        writing = wasWriting
        if changed, reposition { place(in: window) }
        return changed
    }

    /// 盯着这扇窗的三颗按钮:被系统挪走(不是自己写的)就排一次摆回,同一拍里被挪几次只摆一次;`canPlace`
    /// 为 false 时不摆(原生全屏和进出全屏的过渡里标题栏归系统管)。别在挪动通知里当场摆:那时系统正排到一半,
    /// 当场写会跟它后面几颗的摆放打架,最后一颗停在默认位。换了窗就改盯新的那扇。
    public func track(_ window: NSWindow, canPlace: @escaping () -> Bool) {
        self.canPlace = canPlace
        guard window !== trackedWindow else { return }
        for observer in trackObservers { NotificationCenter.default.removeObserver(observer) }
        trackObservers = []
        trackedWindow = window
        for type in Self.buttonTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            button.postsFrameChangedNotifications = true
            trackObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.buttonMoved() }
            })
        }
    }

    private func buttonMoved() {
        guard !writing, !repositionPending else { return }
        repositionPending = true
        schedule { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.repositionPending = false
                guard let window = self.trackedWindow, self.canPlace() else { return }
                self.place(in: window)
            }
        }
    }

    deinit {
        for observer in trackObservers { NotificationCenter.default.removeObserver(observer) }
    }
}
