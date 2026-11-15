import AppKit
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
/// 重新算回来。被拆的那棵树很大时,拆本身在主线程上要花时间,先量过再接(15 章决策 112)。
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
    /// 占位一直没报到也要收尾的时限。
    static let reshowTimeout: Duration = .seconds(1)
    /// 正摆回去、还没收尾的那几个。
    private static var inReshow: [ObjectIdentifier: ClosedWindowContent] = [:]

    /// 开窗入口在开窗之前调:正摆回去的窗口当场收尾。不收的话,开窗那一下只把这扇透明窗摆到最前(它在屏上,
    /// `WindowActivation.surfaceIfOnScreen` / `openWindow` 都当它开着),随后收尾的 `close()` 又把它关掉,这次开窗就丢了。
    static func finishPendingReshows() {
        for content in inReshow.values { content.finishReshow() }
    }

    /// 根视图 onAppear 调。false = 这是关窗后摆回去的那一下,不是开窗。
    func windowAppeared() -> Bool {
        guard reshow == nil else { return false }
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

    /// 占位的 onAppear 调。推到下一拍再关:别在 SwiftUI 更新视图的当中关窗。
    func placeholderAppeared() {
        guard reshow != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.finishReshow() }
    }

    private func beginReshow(_ window: NSWindow) {
        // 这一拍之前已经重新开窗(released 被 windowAppeared 放下)或窗口还在屏上,就不动它。
        guard released, reshow == nil, !window.isVisible else { return }
        reshow = Reshow(window: window, alpha: window.alphaValue,
                        animation: window.animationBehavior, ignoresMouse: window.ignoresMouseEvents)
        window.animationBehavior = .none
        window.alphaValue = 0
        window.ignoresMouseEvents = true
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
