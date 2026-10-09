import AppKit
import LyrimuseCore
import SwiftUI

/// 迷你尺寸的歌词窗口:一扇不激活 App 的面板(07 章决策 133)。
///
/// 迷你窗要在每个桌面都出现、能浮在别的 App 的全屏上、点它不抢键盘焦点。SwiftUI 的 `Window` 场景是普通 NSWindow:
/// App 显示在 Dock 里时进不了别人的全屏 Space,点一下也会把 App 切到前台,这两样只有 `.nonactivatingPanel` 的面板做得到。
/// 完整尺寸仍是场景那扇窗,两种形态之间切换是两扇窗交接(`LyricsWindowController.toggleMini`)。
///
/// 不当 key(`becomesKeyOnlyIfNeeded`):点歌词、点播控键都不会把键盘从用户正在用的 App 拿走,代价是迷你时空格 / ← → 不控制播放。
final class LyricsMiniPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = L10n.t("歌词窗口")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(frame, display: false)
    }

    override var canBecomeMain: Bool { false }
}

/// 面板里的 SwiftUI 宿主,认下第一次点击:App 不在前台时 NSHostingView 默认把第一下点击只用来激活 App,控件收不到
/// (同菜单栏面板的 `FirstMouseHostingView`)。
final class LyricsMiniHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 建、放迷你面板。同一时刻最多一扇;关掉之后放掉整棵 SwiftUI 树(播放订阅、逐帧时钟一起停),下次进迷你重建。
@MainActor
enum LyricsMiniPanelHost {
    private(set) static var panel: LyricsMiniPanel?
    private static var closeObserver: NSObjectProtocol?

    /// 建好面板、摆到 `frame`,还不上屏(上屏由调用方决定:交接时先藏在桌面以下再亮出来)。已经有一扇就挪过去。
    static func make(frame: NSRect) -> LyricsMiniPanel {
        if let panel {
            panel.setFrame(frame, display: false)
            return panel
        }
        let panel = LyricsMiniPanel(frame: frame)
        let host = LyricsMiniHostingView(rootView: LyricsWindowView(hostsMiniPanel: true))
        // 只让 SwiftUI 那层给出最小尺寸,别让它按内容的理想尺寸改面板大小。
        host.sizingOptions = [.minSize]
        panel.contentView = host
        panel.setFrame(frame, display: false)
        self.panel = panel
        LyricsMiniPanelAutoHide.shared.attach(panel)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { release() } }
        }
        return panel
    }

    /// 直接打开迷你(没有完整那扇窗可以参照):上次的位置,没存过就贴在主屏右上角。已经开着就摆到最前。
    /// 被「暂停时隐藏」「全屏时隐藏」藏着的也摆出来(用户要看);`atLaunch` 是启动重开,规则要藏就只建不上屏(07 章决策 142)。
    static func show(atLaunch: Bool = false) {
        if let panel, panel.isVisible {
            panel.orderFrontRegardless()
            return
        }
        let panel = make(frame: LyricsWindowSession.miniFrameToOpen())
        if atLaunch, LyricsMiniPanelAutoHide.shared.holdAtLaunch() { return }
        LyricsMiniPanelAutoHide.shared.panelShownByUser()
        panel.orderFrontRegardless()
    }

    /// 关掉被规则藏着的面板(要开完整尺寸时),免得规则翻回来又亮出一扇迷你、跟完整那扇同在。
    static func closeHeldPanel() {
        guard let panel, !panel.isVisible, LyricsMiniPanelAutoHide.shared.isHoldingPanel else { return }
        LyricsMiniPanelAutoHide.shared.detach()
        panel.close()
    }

    private static func release() {
        guard let panel, !panel.isVisible else { return }
        LyricsMiniPanelAutoHide.shared.detach()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        panel.contentView = nil
        self.panel = nil
    }
}
