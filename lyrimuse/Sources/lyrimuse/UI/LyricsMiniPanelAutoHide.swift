import AppKit
import Combine
import LyrimuseCore

/// 迷你窗「暂停时隐藏」「全屏时隐藏」的执行(判据在 Core `LyricsWindowMiniAutoHide`,见 07 章决策 142)。
///
/// 只在判据翻转那一拍动手:藏用 `orderOut`、不 close,「开着 / 是迷你」照旧记着;翻回来只摆回自己藏起来的那扇。
/// 用户自己打开歌词窗口照常亮出来(`LyricsMiniPanelHost.show`),不被当场收回,到下一次翻转再按规则办。
@MainActor
final class LyricsMiniPanelAutoHide {
    static let shared = LyricsMiniPanelAutoHide()

    /// 面板此刻是被这里藏起来的。启动重开的核对把它算作已上屏(`LyricsWindowLaunchRestorer`)。
    private(set) var isHoldingPanel = false
    /// 规则此刻要不要藏(最近一次算出来的)。
    private(set) var hides = false
    private var isPlaying = false
    private var fullScreenDisplays: Set<String> = []
    private var hideWhenNotPlaying = false
    private var hideInFullScreen = false
    /// 订阅各报完一次当前值之后才动手。
    private var primed = false
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?

    private init() {
        let settings = AppSettings.shared
        // @Published 在写入之前就发布,订阅里回读属性拿到的是旧值:各路一律用发布出来的值。
        // 订阅时各报一次当前值,只记下来、不动手(`primed` 之前)。
        PlaybackCoordinator.shared.$isPlayingSmoothed.removeDuplicates()
            .sink { [weak self] in self?.isPlaying = $0; self?.reevaluate() }.store(in: &cancellables)
        FullScreenSpaceMonitor.shared.$fullScreenDisplays.removeDuplicates()
            .sink { [weak self] in self?.fullScreenDisplays = $0; self?.reevaluate() }.store(in: &cancellables)
        settings.$lyricsWindowMiniHideWhenNotPlaying.removeDuplicates()
            .sink { [weak self] in self?.hideWhenNotPlaying = $0; self?.reevaluate() }.store(in: &cancellables)
        settings.$lyricsWindowMiniHideInFullScreen.removeDuplicates()
            .sink { [weak self] in self?.hideInFullScreen = $0; self?.reevaluate() }.store(in: &cancellables)
        primed = true
        hides = currentHides()
    }

    /// 面板建出来时调:换屏要重算「全屏时隐藏」。
    func attach(_ panel: NSPanel) {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
    }

    /// 面板放掉时调。
    func detach() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        isHoldingPanel = false
    }

    /// 用户打开了歌词窗口(面板亮出来):不再算是这里藏着的。
    func panelShownByUser() {
        isHoldingPanel = false
    }

    /// 启动重开:规则此刻要藏就不上屏、记成藏着,返回 true;否则返回 false,由调用方摆出来。
    func holdAtLaunch() -> Bool {
        hides = currentHides()
        guard hides else { return false }
        isHoldingPanel = true
        return true
    }

    private func reevaluate() {
        guard primed else { return }
        let now = currentHides()
        guard now != hides else { return }
        hides = now
        guard let panel = LyricsMiniPanelHost.panel else { return }
        switch LyricsWindowMiniAutoHide.action(hides: now, panelVisible: panel.isVisible, hiddenByRule: isHoldingPanel) {
        case .hide:
            panel.orderOut(nil)
            isHoldingPanel = true
        case .show:
            panel.orderFrontRegardless()
            isHoldingPanel = false
        case .none:
            break
        }
    }

    private func currentHides() -> Bool {
        LyricsWindowMiniAutoHide.hides(hideWhenNotPlaying: hideWhenNotPlaying, isPlaying: isPlaying,
                                       hideInFullScreen: hideInFullScreen,
                                       coveredByFullScreen: hideInFullScreen && panelScreenIsFullScreen())
    }

    /// 面板所在屏幕此刻是否被全屏 App 占着。按 frame 跟各块屏的交叠面积找屏:藏着(orderOut)的面板 `screen` 不可靠。
    /// 全屏表用订阅收下的那份,别回读监视器上的属性(订阅回调里那是旧值)。
    private func panelScreenIsFullScreen() -> Bool {
        guard let frame = LyricsMiniPanelHost.panel?.frame else { return false }
        let screen = NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(frame), ib = b.frame.intersection(frame)
            return ia.width * ia.height < ib.width * ib.height
        }
        return FullScreenSpaces.covers(screenID: screen.flatMap(ScreenIdentity.id(of:)),
                                       isMainScreen: screen != nil && screen == NSScreen.screens.first,
                                       fullScreenDisplays: fullScreenDisplays)
    }
}
