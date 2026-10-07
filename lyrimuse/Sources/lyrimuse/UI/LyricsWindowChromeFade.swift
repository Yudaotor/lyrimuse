import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 歌词窗口完整布局的「闲置隐藏」:按钮组、红绿灯、滚动指示条一起露、一起收,判据见 `LyricsWindowChromeIdle`。
///
/// `visible` 只在露 / 收翻转时写,鼠标每动一下只记个时刻 —— 套在按钮组外面的 `LyricsWindowChromeFadeModifier`
/// 各自订阅它,整扇窗的视图不跟着鼠标重算。设置页预览那份 controller 从不 attach,一直露着。
@MainActor
final class LyricsWindowChromeFade: ObservableObject {
    @Published private(set) var visible = true

    private weak var window: NSWindow?
    private var state = LyricsWindowChromeIdle.State()
    private var isMini = false
    private var hoveredGroups: Set<String> = []
    private var heldPanels = false
    private var actionMenuOpen = false
    private var checkWork: DispatchWorkItem?
    private var eventMonitor: Any?
    private var pointerArea: NSTrackingArea?
    private weak var pointerAreaView: NSView?
    private lazy var pointerOwner = PointerOwner(fade: self)
    private var cancellables: Set<AnyCancellable> = []

    /// 窗口第一次 attach 时调。迷你时不管(迷你有自己的悬停露出),从迷你回来当作刚打开。
    func attach(_ window: NSWindow, isMini: AnyPublisher<Bool, Never>) {
        self.window = window
        cancellables.removeAll()
        isMini.removeDuplicates().sink { [weak self] mini in
            guard let self else { return }
            self.isMini = mini
            if !mini { self.reveal() } else { self.evaluate() }
        }.store(in: &cancellables)
        // 右下胶囊箭头弹出来的小菜单:指针挪到菜单上时已经出了胶囊。
        LyricsWindowActionMenu.shared.$isOpen.removeDuplicates().sink { [weak self] open in
            self?.actionMenuOpen = open
            self?.evaluate()
        }.store(in: &cancellables)
        if eventMonitor == nil {
            // 本地监听收得到送进本 App 的点按、拖动、滚动(App 不在前台时滚动也送进来);指针移动靠跟踪区。
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
            ]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return }
                    self.activity()
                }
                return event
            }
        }
        installPointerTracking(on: window)
        reveal()
    }

    /// 跟踪区挂在整扇窗最外层的框架上(内容视图的父视图),标题栏那一条也算:标题栏是盖在内容上面的单独一层,
    /// 挂在内容里的跟踪区一进标题栏就报「离开」、也收不到移动,左上那组按钮正好在那一条里。
    /// 用 AppKit 跟踪区、选项带 `.activeAlways`,不用 SwiftUI `.onHover`:这扇窗常放在副屏上看、焦点在别的 App,
    /// `.onHover` 那时不报。
    private func installPointerTracking(on window: NSWindow) {
        guard let frameView = window.contentView?.superview ?? window.contentView else { return }
        if let pointerArea { pointerAreaView?.removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: pointerOwner)
        frameView.addTrackingArea(area)
        pointerArea = area
        pointerAreaView = frameView
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    /// 窗口打开、从迷你回来:先露 `idleSeconds`,让人看见有哪些按钮。
    func reveal() {
        state.revealUntil = Date().addingTimeInterval(LyricsWindowChromeIdle.idleSeconds)
        evaluate()
    }

    func pointer(inside: Bool) {
        // 报「离开」时指针其实还在这扇窗的范围里(跟踪区所在的视图被换掉、窗口边缘的阴影区),不算离开。
        if !inside, let window, window.isVisible, window.frame.contains(NSEvent.mouseLocation) { return }
        state.pointerInside = inside
        if inside { state.lastActivity = Date() }
        if !inside { hoveredGroups.removeAll() }
        evaluate()
    }

    /// 指针在窗里动了、滚了、按了。
    func activity() {
        state.pointerInside = true
        state.lastActivity = Date()
        guard !visible || checkWork == nil else { return }
        evaluate()
    }

    /// 某一组按钮上的悬停:停在按钮上不收。
    func setHovering(_ group: String, _ hovering: Bool) {
        if hovering { hoveredGroups.insert(group) } else { hoveredGroups.remove(group) }
        evaluate()
    }

    /// 按钮弹出来的面板(译文菜单、音频输出、「⋯」那几块)开着就不收。
    func setPanelsOpen(_ open: Bool) {
        guard heldPanels != open else { return }
        heldPanels = open
        if !open { state.lastActivity = Date() }
        evaluate()
    }

    /// 关窗时调:下次打开从露着开始。
    func windowClosed() {
        checkWork?.cancel()
        checkWork = nil
        state = LyricsWindowChromeIdle.State()
        hoveredGroups.removeAll()
        if !visible { visible = true }
    }

    private func evaluate() {
        let now = Date()
        state.held = !hoveredGroups.isEmpty || heldPanels || actionMenuOpen
        state.mouseDown = NSEvent.pressedMouseButtons != 0
        state.voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        let show = window == nil || isMini || LyricsWindowChromeIdle.isVisible(state, now: now)
        if visible != show { visible = show }
        checkWork?.cancel()
        checkWork = nil
        guard !isMini, let deadline = LyricsWindowChromeIdle.nextCheck(state, now: now) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.checkWork = nil
                self?.evaluate()
            }
        }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, deadline.timeIntervalSince(now)), execute: work)
    }
}

/// 套在一组按钮外面:跟着 `LyricsWindowChromeFade.visible` 淡入淡出,收着时不接点击;指针停在上面时不收。
struct LyricsWindowChromeFadeModifier: ViewModifier {
    @ObservedObject var fade: LyricsWindowChromeFade
    let group: String

    func body(content: Content) -> some View {
        content
            .opacity(fade.visible ? 1 : 0)
            .allowsHitTesting(fade.visible)
            .animation(.easeOut(duration: fade.visible ? LyricsWindowChromeIdle.fadeInSeconds
                                                       : LyricsWindowChromeIdle.fadeOutSeconds),
                       value: fade.visible)
            .onHover { fade.setHovering(group, $0) }
    }
}

extension View {
    func lyricsWindowChromeFade(_ fade: LyricsWindowChromeFade, group: String) -> some View {
        modifier(LyricsWindowChromeFadeModifier(fade: fade, group: group))
    }
}

/// 跟踪区的接收者:把进出、移动转给 `LyricsWindowChromeFade`。
private final class PointerOwner: NSResponder {
    weak var fade: LyricsWindowChromeFade?

    init(fade: LyricsWindowChromeFade) {
        self.fade = fade
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { fade?.pointer(inside: true) } }
    override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { fade?.pointer(inside: false) } }
    override func mouseMoved(with event: NSEvent) { MainActor.assumeIsolated { fade?.activity() } }
}
