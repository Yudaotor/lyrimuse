import AppKit
import LyrimuseCore
import QuartzCore
import SwiftUI

/// 歌词窗口的逐帧时钟:一条跟着宿主窗口所在屏幕走的 display link,有人要刷新时才开。
///
/// 替代 `TimelineView(.animation)`:进程里有 SwiftUI `ScrollView` 时,`TimelineView(.animation)` 驱动的每一帧要完整
/// 渲染两次;display link 回调里改一次状态,这一帧只渲染一次(07 章决策 99)。
@MainActor
final class FrameClock {
    nonisolated(unsafe) private var link: CADisplayLink?
    private weak var host: NSView?
    /// 此刻要逐帧刷新的票。弱引用:视图没走 `onDisappear` 就被释放时自动出列。
    private let active = NSHashTable<FrameTicket>.weakObjects()
    /// 主线程卡住、漏掉的帧累计多长(秒,判据见 `FrameStall`),只增不减。
    private(set) var stalledSeconds: Double = 0
    /// 上一帧的目标时刻(`CACurrentMediaTime` 时基);时钟停着时 nil。
    private var lastFrame: CFTimeInterval?

    nonisolated init() {}

    deinit { link?.invalidate() }

    /// `FrameClockHost` 调:display link 改跟这个视图所在的屏幕。
    func host(on view: NSView) {
        guard view !== host || link == nil else { return }
        host = view
        link?.invalidate()
        link = nil
        lastFrame = active.count > 0 ? CACurrentMediaTime() : nil
        startIfNeeded()
    }

    func setActive(_ ticket: FrameTicket, _ on: Bool) {
        if on { active.add(ticket) } else { active.remove(ticket) }
        startIfNeeded()
        let idle = active.count == 0
        // 从停着恢复时从这一刻算起:恢复它的那次更新把主线程卡住的话,下一帧晚到的那段照样算卡住。
        if idle { lastFrame = nil } else if lastFrame == nil { lastFrame = CACurrentMediaTime() }
        link?.isPaused = idle
    }

    /// 过渡动画(换句错开、景深、滚动指示条)用的时刻:墙钟减去累计卡住的时长(07 章决策 108)。
    /// 逐字填色、进度这类跟着播放位置走的不用它。
    func transitionDate(_ date: Date) -> Date {
        date.addingTimeInterval(-stalledSeconds)
    }

    func transitionNow() -> Date {
        transitionDate(Date())
    }

    private func startIfNeeded() {
        guard link == nil, active.count > 0 else { return }
        let proxy = DisplayLinkProxy(owner: self)
        let selector = #selector(DisplayLinkProxy.tick(_:))
        let made = host.map { $0.displayLink(target: proxy, selector: selector) }
            ?? NSScreen.main?.displayLink(target: proxy, selector: selector)
        made?.add(to: .main, forMode: .common)
        link = made
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let tickets = active.allObjects
        guard !tickets.isEmpty else {
            link.isPaused = true
            lastFrame = nil
            return
        }
        let target = link.targetTimestamp
        if let last = lastFrame {
            stalledSeconds += FrameStall.missedSeconds(gap: target - last, frame: target - link.timestamp)
        }
        lastFrame = target
        let date = Date(timeIntervalSinceNow: target - CACurrentMediaTime())
        for ticket in tickets { ticket.advance(to: date) }
    }
}

/// display link 强引用它的 target,中间隔一层弱引用,`FrameClock` 才能跟着视图一起释放。
private final class DisplayLinkProxy: NSObject {
    weak var owner: FrameClock?

    init(owner: FrameClock) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.tick(link)
        }
    }
}

/// 一个 `FrameTimeline` 的刷新票:display link 每帧敲一次,离上次刷新够了 `minimumInterval` 才换日期。
@MainActor
final class FrameTicket: ObservableObject {
    @Published private(set) var date = Date()
    var minimumInterval: Double = 0
    private var last = Date.distantPast

    func advance(to now: Date) {
        guard FrameCadence.isDue(sinceLast: now.timeIntervalSince(last), minimumInterval: minimumInterval) else { return }
        last = now
        date = now
    }

    /// 恢复刷新的那一刻按当下刷新一次。
    func jump(to now: Date) {
        last = now
        date = now
    }
}

/// `FrameTimeline` 交给内容的时刻。
enum FrameTimebase {
    /// 墙钟。跟着播放位置走的(逐字填色、进度)用这个。
    case wall
    /// 过渡时刻(`FrameClock.transitionDate`):主线程卡住漏掉的帧不算进度。过渡的起点也要用同一个时钟的 `transitionNow()` 记。
    case transition
}

/// 逐帧刷新内容,用法同 `TimelineView(.animation(minimumInterval:paused:))`,时钟换成环境里的 `FrameClock`。
/// 停表时日期冻结在最后一次刷新;恢复时立刻按当下刷新一次。
struct FrameTimeline<Content: View>: View {
    var minimumInterval: Double = 0
    var timebase: FrameTimebase = .wall
    let paused: Bool
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.frameClock) private var clock
    @StateObject private var ticket = FrameTicket()

    var body: some View {
        content(timebase == .transition ? clock.transitionDate(ticket.date) : ticket.date)
            .onAppear {
                ticket.minimumInterval = minimumInterval
                if !paused { ticket.jump(to: Date()) }
                clock.setActive(ticket, !paused)
            }
            .onDisappear { clock.setActive(ticket, false) }
            .onChange(of: paused) { _, nowPaused in
                if !nowPaused { ticket.jump(to: Date()) }
                clock.setActive(ticket, !nowPaused)
            }
    }
}

private struct FrameClockKey: EnvironmentKey {
    /// 没挂宿主时跟主屏的 display link 走。
    static let defaultValue = FrameClock()
}

extension EnvironmentValues {
    var frameClock: FrameClock {
        get { self[FrameClockKey.self] }
        set { self[FrameClockKey.self] = newValue }
    }
}

/// 把 `FrameClock` 挂到所在窗口上:display link 跟着这扇窗所在的屏幕走。零尺寸、不接鼠标。
struct FrameClockHost: NSViewRepresentable {
    let clock: FrameClock

    func makeNSView(context: Context) -> FrameClockHostView { FrameClockHostView(clock: clock) }

    func updateNSView(_ view: FrameClockHostView, context: Context) { view.attach(clock) }
}

final class FrameClockHostView: NSView {
    private var clock: FrameClock

    init(clock: FrameClock) {
        self.clock = clock
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func attach(_ newClock: FrameClock) {
        guard newClock !== clock else { return }
        clock = newClock
        if window != nil { clock.host(on: self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { clock.host(on: self) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
