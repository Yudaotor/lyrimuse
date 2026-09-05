import AppKit
import SwiftUI

// 两块补给「没有系统标题栏的面板」的窗口能力,`.sheet` 弹出的那几张都缺(2026-09-05 从
// LyricsSearchSheet.swift 搬出来共用 —— 决策弹窗也要这两样,用户原话「决策解析这个窗口也要
// 支持可拖拽可调整大小」)。两块都只做一件很小的事,但都必须落到底层 `NSWindow` 上:
// SwiftUI 层没有对应的表达。

/// 垫在自定义标题栏背后的一块透明拖拽区——按下并拖动时直接对它所在的 `NSWindow` 发起
/// `performDrag`,让没有系统标题栏的窗口(sheet / hiddenTitleBar 都算)也能靠那一行拖动。
///
/// sheet 默认**不可拖**:AppKit 故意把它钉死在依附点,不是漏配了 `isMovableByWindowBackground`
/// 能补的(那个修饰符对 sheet 样式的窗口不生效)。垫在背景层不影响上面的按钮各自接收点击
/// ——SwiftUI 命中测试是前景优先,背景只接住前景没吃掉的那些。
///
/// 只在 `mouseDown` 里取 window、不缓存:`NSViewRepresentable` 的实例在 SwiftUI 重新求值
/// body 时会重建,view 却是同一个,取当次真实生效的 window 才对。
struct WindowDragHandle: NSViewRepresentable {
    final class DragCatcherView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> NSView { DragCatcherView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 让这扇面板能拖边框改大小,**并钉死一个最小尺寸**。sheet 的默认 `styleMask` 里没有
/// `.resizable`,四边对拖拽完全没反应;`Window` 场景那条路径本来就有,插一次是无操作。
///
/// 插两次(`viewDidMoveToWindow` 里同步一次 + 下一拍再一次):sheet 真正落到 `NSWindow`
/// 上的样式由 AppKit 在依附动画那一刻定,同步这次可能被它随后覆盖掉。
///
/// # 最小尺寸必须自己设(2026-09-05 用户报「应该有一个最小大小才对,现在都没有限制」)
///
/// 内容侧 `.frame(minWidth:minHeight:)` 声明的下限**管不住窗口**:它约束的是 SwiftUI 的
/// 布局,而窗口能被拖到多小由 `NSWindow.contentMinSize` 说了算 —— 那个值默认是零。加
/// `.resizable` 之前这件事看不出来(压根不能拖),放开之后就成了"能一路拖到只剩标题栏、
/// 内容被挤成一团"。所以两件事必须成对做:插标志的同时把下限写进 `contentMinSize`,
/// 取值就用挂它那个视图 frame 里的那一对,别让两处各说各的。
///
/// ⚠️ 光有下限还不够,**挂它的视图根部要留出长大的余地**:根 frame 只写 min 的话,窗口
/// 拖大了内容仍停在原尺寸,得配 `maxWidth/maxHeight: .infinity`。
/// 2026-09-04 离屏探针实测(父窗口摆屏幕外、跑完即退):sheet 依附动画结束后 `.resizable`
/// 仍在、`setContentSize` 到 980×700 生效、内部 `NSHostingView` 跟着变宽——这条路才敢用。
struct WindowResizeEnabler: NSViewRepresentable {
    /// 窗口能被拖到的最小内容尺寸。传挂它那个视图 frame 里声明的同一对下限。
    let minWidth: CGFloat
    let minHeight: CGFloat

    final class Probe: NSView {
        var minSize: NSSize = .zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            apply(to: window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.apply(to: window)
            }
        }

        private func apply(to window: NSWindow) {
            window.styleMask.insert(.resizable)
            guard minSize.width > 0, minSize.height > 0 else { return }
            window.contentMinSize = minSize
            // 已经比下限还小就顺手撑回去 —— 面板刚弹出来那一下如果已经过小,用户看到的
            // 就是一扇挤坏了的窗口,而"拖不小于下限"救不了它(它本来就没被拖过)。
            let content = window.contentRect(forFrameRect: window.frame).size
            if content.width < minSize.width || content.height < minSize.height {
                window.setContentSize(NSSize(
                    width: max(content.width, minSize.width),
                    height: max(content.height, minSize.height)))
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = Probe()
        view.minSize = NSSize(width: minWidth, height: minHeight)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? Probe else { return }
        probe.minSize = NSSize(width: minWidth, height: minHeight)
        if let window = probe.window {
            window.contentMinSize = probe.minSize
        }
    }
}
