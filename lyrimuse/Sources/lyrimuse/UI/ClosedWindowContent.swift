import AppKit
import LyrimuseCore
import SwiftUI

/// 关掉的 SwiftUI 窗口(`Window` / `Settings` 场景)放下里面那块重的内容。
///
/// 这两种场景关窗只把窗口 orderOut:窗口、整棵视图树、树里攥着的数据和视图图都留着,
/// 而且关着的窗口不再处理状态变化,关窗那一刻在 onDisappear 里改状态也要等下次开窗才落到视图树上。所以关窗后
/// 把窗口透明、不接鼠标、不带动画地摆回窗口列表,让 SwiftUI 把内容换成占位,占位真的摆上(`placeholderAppeared`)
/// 就 `close()`、还原透明度。见 15 章决策 112。
///
/// 收尾必须是 `close()`,别换成 `orderOut`:只 orderOut 的话 SwiftUI 当窗口还开着,下次开窗不再触发 onAppear,
/// 内容一直是占位。摆回去、关掉这两下会让根视图多走一遍 onAppear / onDisappear,`windowAppeared()` /
/// `windowDisappeared()` 返回 false 时调用方跳过自己的开关窗逻辑(Dock 图标记账是计数器,多记一笔就对不上账)。
/// 关窗期间不许有窗口动画:动画结束会把透明度还原成开始时的 0,盖掉设回的值(14 章决策 141)。
///
/// 用 `releasedWhenWindowClosed` 包住的那块:它的视图值本身一直留在视图图里,值里别直接带大数组(包一层取数的闭包,
/// 如 `ScrollViewReader { … }`);它在被拆掉之前还会再求值一次,读的缓存在 `released` 时要返回空,不然会把刚放掉的数据
/// 重新算回来。
///
/// 被拆的那棵树很大时拆本身要占主线程好几秒(歌词管理三万行的列表 3～5 秒,SwiftUI 的 List 数据一变就整表更新,分批拆、
/// 先清数据源都一样),这种窗口用 `releaseLater`:关窗时只登记,等屏幕锁定 / 显示器睡眠(`releaseDeferred`)再拆,
/// 拆的那一段告诉卡顿探针是有意的(`MainThreadWatchdog.beginExpectedStall`),不当卡顿上报。见 15 章决策 112。
@MainActor
final class ClosedWindowContent: ObservableObject {
    /// 窗口关着,内容已换成(或正要换成)占位。
    @Published private(set) var released = false

    private struct Reshow {
        let window: NSWindow
        let alpha: CGFloat
        let animation: NSWindow.AnimationBehavior
        let ignoresMouse: Bool
    }
    private var reshow: Reshow?
    /// 收尾那次 `close()` 引出的 onDisappear 还没到。下一次真开窗时清掉,防止它没来、吞掉之后真关窗那一笔。
    private var pendingSyntheticDisappear = false
    private var fallback: Task<Void, Never>?
    /// `releaseLater` 登记、还没拆:拆之前要做的事(清掉根视图上攥着数据的缓存)和那扇窗。
    private var deferredPrepare: (@MainActor () -> Void)?
    private weak var deferredWindow: NSWindow?
    /// 这一次摆回去是延后拆的(拆得慢,告诉卡顿探针);占位报到过没有。
    private var reshowIsDeferred = false
    /// 告诉过卡顿探针「接下来是有意占住主线程」、还没说结束。
    private var expectedStallOpen = false
    private var deferredReason = ""
    private var placeholderShown = false
    /// 占位一直没报到也要收尾的时限。
    static let reshowTimeout: Duration = .seconds(1)
    /// 正摆回去、还没收尾的那几个。
    private static var inReshow: [ObjectIdentifier: ClosedWindowContent] = [:]
    /// 关着、等锁屏 / 睡眠再拆的那几个。
    private static var waiting: [ObjectIdentifier: ClosedWindowContent] = [:]
    private static var triggerObservers: [NSObjectProtocol] = []

    /// App 启动时装一次:屏幕锁定、显示器睡眠时拆掉登记着的窗口(`releaseDeferred`)。
    static func installDeferredReleaseTriggers() {
        guard triggerObservers.isEmpty else { return }
        let fire: @Sendable (Notification) -> Void = { note in
            let reason = note.name == NSWorkspace.screensDidSleepNotification ? "displays asleep" : "screen locked"
            MainActor.assumeIsolated { releaseDeferred(reason: reason) }
        }
        triggerObservers = [
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: fire),
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: fire),
        ]
    }

    /// 拆掉登记着的窗口。那扇窗已经重新开着(或正在开)就不动它,等下次关窗重新登记。
    static func releaseDeferred(reason: String) {
        let pending = waiting.values
        waiting.removeAll()
        for content in pending { content.fireDeferred(reason: reason) }
    }

    /// 开窗入口在开窗之前调:正摆回去的窗口当场收尾。不收的话,开窗那一下只把这扇透明窗摆到最前(它在屏上,
    /// `WindowActivation.surfaceIfOnScreen` / `openWindow` 都当它开着),随后收尾的 `close()` 又把它关掉,这次开窗就丢了。
    static func finishPendingReshows() {
        for content in inReshow.values { content.finishReshow() }
    }

    /// 根视图 onAppear 调。false = 这是关窗后摆回去的那一下,不是开窗。
    func windowAppeared() -> Bool {
        guard reshow == nil else { return false }
        cancelDeferred()
        pendingSyntheticDisappear = false
        if released { released = false }
        return true
    }

    /// 根视图 onDisappear 调。false = 这是收尾那次 `close()`,不是用户关窗。
    func windowDisappeared() -> Bool {
        if reshow != nil { return false }
        if pendingSyntheticDisappear {
            pendingSyntheticDisappear = false
            return false
        }
        return true
    }

    /// 真关窗时(`windowDisappeared()` 为 true)调:内容换成占位,下一拍把窗口摆回去让这次替换落地。
    func release(_ window: NSWindow?) {
        guard !released else { return }
        released = true
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in self?.beginReshow(window) }
    }

    /// 真关窗时调(拆起来慢的窗口):只登记,等 `releaseDeferred` 再先跑 `prepare`、再换占位。重开过就作废。
    func releaseLater(_ window: NSWindow?, prepare: @escaping @MainActor () -> Void) {
        guard !released, let window else { return }
        deferredPrepare = prepare
        deferredWindow = window
        Self.waiting[ObjectIdentifier(self)] = self
    }

    private func cancelDeferred() {
        deferredPrepare = nil
        deferredWindow = nil
        Self.waiting[ObjectIdentifier(self)] = nil
    }

    private func fireDeferred(reason: String) {
        let prepare = deferredPrepare
        deferredPrepare = nil
        guard let window = deferredWindow, !window.isVisible else {
            deferredWindow = nil
            return
        }
        reshowIsDeferred = true
        deferredReason = reason
        if released {
            // 上一回没换成(占位没报到就超时收尾了):内容已经是占位状态,再摆回去一次。
            DispatchQueue.main.async { [weak self] in self?.beginReshow(window) }
        } else {
            // prepare 清缓存同样要占主线程,在它之前就告诉卡顿探针。
            beginExpectedStall()
            prepare?()
            release(window)
        }
    }

    private func beginExpectedStall() {
        guard !expectedStallOpen else { return }
        expectedStallOpen = true
        MainThreadWatchdog.shared.beginExpectedStall("release closed window: \(deferredReason)")
    }

    private func endExpectedStall() {
        guard expectedStallOpen else { return }
        expectedStallOpen = false
        MainThreadWatchdog.shared.endExpectedStall()
    }

    /// 占位的 onAppear 调。推到下一拍再关:别在 SwiftUI 更新视图的当中关窗。
    func placeholderAppeared() {
        guard reshow != nil else { return }
        placeholderShown = true
        DispatchQueue.main.async { [weak self] in self?.finishReshow() }
    }

    private func beginReshow(_ window: NSWindow) {
        // 这一拍之前已经重新开窗(released 被 windowAppeared 放下)或窗口还在屏上,就不动它;fireDeferred 先开的预期停顿
        // 这时就结束,别一直开着把之后的真卡顿都当成有意的(正摆回去的那次自己会在收尾时结束)。
        guard released, reshow == nil, !window.isVisible else {
            if reshow == nil { endExpectedStall() }
            return
        }
        reshow = Reshow(window: window, alpha: window.alphaValue,
                        animation: window.animationBehavior, ignoresMouse: window.ignoresMouseEvents)
        window.animationBehavior = .none
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        placeholderShown = false
        if reshowIsDeferred { beginExpectedStall() }
        window.orderBack(nil)
        Self.inReshow[ObjectIdentifier(self)] = self
        fallback = Task { [weak self] in
            try? await Task.sleep(for: Self.reshowTimeout)
            guard !Task.isCancelled else { return }
            self?.finishReshow()
        }
    }

    private func finishReshow() {
        fallback?.cancel()
        fallback = nil
        guard let r = reshow else { return }
        Self.inReshow[ObjectIdentifier(self)] = nil
        pendingSyntheticDisappear = true
        r.window.close()
        r.window.alphaValue = r.alpha
        r.window.ignoresMouseEvents = r.ignoresMouse
        r.window.animationBehavior = r.animation
        reshow = nil
        guard reshowIsDeferred else { return }
        reshowIsDeferred = false
        endExpectedStall()
        // 占位没报到就超时收尾了(显示器睡着时可能不画):留到下一次锁屏 / 睡眠再摆一次。
        if released, !placeholderShown {
            deferredWindow = r.window
            Self.waiting[ObjectIdentifier(self)] = self
        }
    }
}

/// 窗口关着时把挂上它的那块换成占位(见 ClosedWindowContent)。
private struct ClosedWindowPlaceholder: ViewModifier {
    @ObservedObject var state: ClosedWindowContent

    func body(content: Content) -> some View {
        if state.released {
            Color.clear.onAppear { state.placeholderAppeared() }
        } else {
            content
        }
    }
}

extension View {
    func releasedWhenWindowClosed(_ state: ClosedWindowContent) -> some View {
        modifier(ClosedWindowPlaceholder(state: state))
    }
}
