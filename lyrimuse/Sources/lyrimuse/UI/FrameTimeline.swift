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

    nonisolated init() {}

    deinit { link?.invalidate() }

    /// `FrameClockHost` 调:display link 改跟这个视图所在的屏幕。
    func host(on view: NSView) {
        guard view !== host || link == nil else { return }
        host = view
        link?.invalidate()
        link = nil
        startIfNeeded()
    }

    func setActive(_ ticket: FrameTicket, _ on: Bool) {
        if on { active.add(ticket) } else { active.remove(ticket) }
        startIfNeeded()
        link?.isPaused = active.count == 0
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
            return
        }
        let date = Date(timeIntervalSinceNow: link.targetTimestamp - CACurrentMediaTime())
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

/// 逐帧刷新内容,用法同 `TimelineView(.animation(minimumInterval:paused:))`,时钟换成环境里的 `FrameClock`。
/// 停表时日期冻结在最后一次刷新;恢复时立刻按当下刷新一次。
struct FrameTimeline<Content: View>: View {
    var minimumInterval: Double = 0
    let paused: Bool
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.frameClock) private var clock
    @StateObject private var ticket = FrameTicket()

    var body: some View {
        content(ticket.date)
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
