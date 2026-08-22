import AppKit
import SwiftUI
import Combine
import CoreAudio
import LyrimuseCore

/// 歌词窗口的**窄订阅代理**(2026-08-19 性能审计,五个展示面最后一个接上;完整机制见
/// OverlayPlayback 的注释)。这扇窗实读面本来就大(37 个 @Published 读约 24 个),代理的
/// 收益不在"滤掉大半",而在三处:① 滤掉它不读的高频源 —— currentLine/nextLineText 每句
/// 歌词各发一次,原来每句白打醒整窗 body 2~3 次;② soundVolume **故意不转发**,音量胶囊
/// 下沉成自持订阅的子视图(WindowVolumeCapsule),拖音量只失效那个小胶囊;③ 值类型逐条
/// removeDuplicates。anchor 入订阅(progressSection 要按锚点存在性分支,重锚低频);
/// 填色闭包里的 anchor/offset 仍直读协调器(TimelineView 按帧重跑,见 KaraokeWordText)。
@MainActor
private final class WindowPlayback: ObservableObject {
    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var isPlayingSmoothed = false
    @Published private(set) var currentLineIndex: Int?
    @Published private(set) var currentGapIndex: Int?
    @Published private(set) var allLines: [LyricsWindowLine] = []
    @Published private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published private(set) var currentLineFillSettled = true
    @Published private(set) var artworkData: Data?
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var highResArtworkImage: NSImage?
    @Published private(set) var windowBackgroundLayers: WindowBackgroundLayers?
    @Published private(set) var anchor: ProgressAnchor?
    @Published private(set) var pausedPositionMs: Int?
    /// 「⋯」菜单里「歌词时间轴」行的当前值(只这首歌的微调;低频,只在用户按 提前/延后/
    /// 重置 或换歌加载校准时变)。
    @Published private(set) var trackLyricsOffsetMs = 0
    @Published private(set) var currentDurationMs: Int?
    @Published private(set) var isFavorited: Bool?
    @Published private(set) var playbackMode: MusicPlaybackController.MusicPlaybackMode?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    // ---- 来自 AppSettings(只挑本窗口实读的两项) ----
    @Published private(set) var showRomanization = true
    @Published private(set) var showTranslation = false
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$isPlayingSmoothed.removeDuplicates().sink { [weak self] in self?.isPlayingSmoothed = $0 },
            p.$currentLineIndex.removeDuplicates().sink { [weak self] in self?.currentLineIndex = $0 },
            p.$currentGapIndex.removeDuplicates().sink { [weak self] in self?.currentGapIndex = $0 },
            p.$allLines.removeDuplicates().sink { [weak self] in self?.allLines = $0 },
            p.$lyricsGapMarkers.removeDuplicates().sink { [weak self] in self?.lyricsGapMarkers = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$artworkData.removeDuplicates().sink { [weak self] in self?.artworkData = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
            p.$windowBackgroundLayers.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.windowBackgroundLayers = $0 },
            p.$anchor.sink { [weak self] in self?.anchor = $0 },
            p.$pausedPositionMs.removeDuplicates().sink { [weak self] in self?.pausedPositionMs = $0 },
            p.$trackLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.trackLyricsOffsetMs = $0 },
            p.$currentDurationMs.removeDuplicates().sink { [weak self] in self?.currentDurationMs = $0 },
            p.$isFavorited.removeDuplicates().sink { [weak self] in self?.isFavorited = $0 },
            p.$playbackMode.removeDuplicates().sink { [weak self] in self?.playbackMode = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            s.$showRomanization.removeDuplicates().sink { [weak self] in self?.showRomanization = $0 },
            s.$showTranslation.removeDuplicates().sink { [weak self] in self?.showTranslation = $0 },
        ]
    }
}

// 这个绿色按钮目前只会"放大铺满屏幕",点不出真正的原生全屏(独立 Space、隐藏菜单栏/
// Dock)——2026-08-01 实测排查过一整轮,不是这个窗口自己代码的问题:"歌词管理"这个
// 完全没碰过的既有窗口,按钮同样是 AXZoomButton 而不是 AXFullScreenButton(拿 TextEdit
// 一个正常支持全屏的窗口对比过,那边点了真的会全屏,AXFullScreen 从 false 变 true;
// 这两个窗口点了 AXFullScreen 恒为 false),说明这是这个 App 里所有 Window(id:) 场景
// 共有的表现,不是这一个视图的局部问题。
//
// ⚠️ 2026-08-16 订正:当时把原因归到"MenuBarExtra 作为主 Scene 的这整个 App"上,这个
// 归因是错的。菜单栏那一项这天换成了自建 NSStatusItem、MenuBarExtra 已经从 App.swift
// 里整个删掉,重新用 AX 查过这扇窗:绿色按钮仍然是 AXZoomButton、没有
// AXFullScreenButton、AXFullScreen 仍恒为 false。所以 MenuBarExtra 是被排除的第 4 个
// 假设,真正的原因还没找到。已经验证过并排除的
// 方向:①window.collectionBehavior 加 .fullScreenPrimary(用 rawValue 位掩码确认过真的
// 生效,菜单栏"显示"菜单里也确实多出"进入全屏幕"这一项);②NSApp.activationPolicy
// 切到 .regular(用户自己"在 Dock 中显示"这项本来就是开着的,全程确认过 activationPolicy
// 就是 .regular,不存在切换时机问题);③Info.plist 的 LSUIElement 改成 false(临时改过
// build.sh 重新构建验证,同样无效,已改回)。三个假设逐一用真机验证证伪,不是没试就
// 放弃。真正卡住的那一步是"进入全屏幕"这个菜单命令点了也确实不生效(不只是按钮图标不
// 对),指向比这几个属性更深的层面,没有再继续往下猜——参见对话记录里跟用户的讨论。
//
// ✅ 2026-08-21 真根因坐实并修复:**SwiftUI Window 默认禁全屏**。探针实验:同一进程里
// 开一扇纯 AppKit NSWindow,绿键是 AXFullScreenButton、AXFullScreen 置 true 能真进
// 全屏 Space;这扇 SwiftUI 窗同刻是 AXZoomButton。当年那四个假设全都没碰到 SwiftUI
// 场景宿主这一层。修复:.windowFullScreenBehavior(.enabled)(App.swift)实测没生效,
// 真正起效的是 attach() 里对 collectionBehavior 的**持续守护**(SwiftUI 每个更新周期
// 会把标志复写掉,设一次不够——当年①号假设"加 fullScreenPrimary 无效"其实就是被
// 复写了,位掩码当场验证过生效、下一个周期又被抹掉);toggle() 在 15+ 直接
// window.toggleFullScreen(nil)。下面的伪全屏整套保留,只作老系统兜底。
//
// 用户选择的替代方案:不追求真正的原生全屏,做一个"伪全屏"——工具栏按钮触发,手动把
// 窗口 setFrame 撑满整个屏幕(不是 visibleFrame,是含菜单栏/Dock 那块区域在内的完整
// 屏幕范围,配合下面的 presentationOptions 一起用)、隐藏标题栏和三个红黄绿按钮、拿
// NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock] 这个官方 API 让菜单栏/
// Dock 跟真全屏一样悬停才弹出——不是真的切换 Space,但视觉效果接近,而且完全不依赖
// 上面那个已经证实卡死的原生全屏机制,退出路径(按钮再点一次/Esc)完全在自己掌控中,
// 稳定可靠。
//
// LyricsWindowController 管这一整套跟真实 NSWindow 打交道的状态(伪全屏 + 置于最
// 顶层),是个 ObservableObject 而不是纯 NSView 内部状态——工具栏按钮需要跟着
// isActive/isAlwaysOnTop 换图标/文案,SwiftUI 侧需要能观察到。用
// LyricsWindowCapture(下面的 NSViewRepresentable)拿到真实 NSWindow 交给它,
// 复用跟 LyricsOverlayWindowController.shared 类似的"独立于 View 生命周期的状态持有者"
// 思路,但这里不是单例——每个 LyricsWindowView 实例自己持有一个,反正这个窗口场景本身
// 是 App 内单例 Window(id:),不会有多份内容同时需要各自独立状态。
@MainActor
private final class LyricsWindowController: ObservableObject {
    @Published private(set) var isActive = false
    // 置于最顶层——跟伪全屏是两回事,不互斥(可以同时开)。用 NSWindow.level 而不是
    // collectionBehavior:.floating 是标准的"漂浮在普通窗口之上"层级,系统里很多类似
    // 功能(画中画、计算器"始终置顶"一类第三方 App)都是这么做的。不持久化——每次
    // 重新打开这个窗口都从"不置顶"开始,跟伪全屏状态同一个"只在这次打开期间有效"的
    // 处理原则,没有额外加一个 UserDefaults 存档的必要性。
    @Published private(set) var isAlwaysOnTop = false

    private weak var window: NSWindow?
    /// 窗口此刻在不在屏幕上 —— App 激活刷新的可见性守卫用(Window 场景关闭后视图树
    /// 保活,onReceive 还会进来)。
    var isWindowVisible: Bool { window?.isVisible ?? false }
    private var savedFrame: NSRect?
    private var escapeMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var enterFullScreenObserver: NSObjectProtocol?
    private var exitFullScreenObserver: NSObjectProtocol?
    private var nativeFullScreenEscapeMonitor: Any?
    private var fullScreenCapabilityObserver: NSObjectProtocol?

    /// 缺才写(写入后自身即满足条件,不会自激);见 attach() 里的守护注释。
    private static func enforceFullScreenCapability(_ window: NSWindow) {
        var behavior = window.collectionBehavior
        guard behavior.contains(.fullScreenNone) || behavior.contains(.fullScreenAuxiliary)
            || !behavior.contains(.fullScreenPrimary) else { return }
        behavior.remove(.fullScreenNone)
        behavior.remove(.fullScreenAuxiliary)
        behavior.insert(.fullScreenPrimary)
        window.collectionBehavior = behavior
    }

    /// 红绿灯默认位置(AppKit 坐标,标题栏容器内),首次 attach 时记录。
    private var trafficLightDefaultY: CGFloat?
    private var trafficLightDefaultXs: [NSWindow.ButtonType.RawValue: CGFloat] = [:]
    /// 红绿灯下移量(2026-08-22 第二轮对拍,用户给的 AM 整窗参考图逐像素量出:红点
    /// 中心 y=25.75pt,此前 22 仍偏高):默认中心窗内 16pt,下移 10 → 26pt,与右上
    /// 胶囊行(offset −safeTop+10)同心。
    private static let trafficLightDownshift: CGFloat = 10
    /// 红点(close)目标中心 x(2026-08-21 第二轮:用户报"过于靠边",AM 整窗截图量出
    /// 红点中心 x=25.8pt);整组随 close 平移,保留系统自己的按钮间距。
    private static let trafficLightCloseCenterX: CGFloat = 26
    /// 系统每次标题栏布局都会把按钮拉回默认位,跟 collectionBehavior 一样要持续钉——
    /// 搭同一个 didUpdate 观察者的车,不等才写不自激。原生全屏中标题栏由系统全权
    /// 接管(自动隐藏/悬停浮出),不掺和。
    private func enforceTrafficLightPosition(_ window: NSWindow) {
        guard !isNativeFullScreen else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        // 首次记录整组默认位(必须在动它们之前一次记齐)。
        if trafficLightDefaultXs.isEmpty {
            for type in types {
                guard let button = window.standardWindowButton(type) else { continue }
                trafficLightDefaultXs[type.rawValue] = button.frame.origin.x
                if trafficLightDefaultY == nil { trafficLightDefaultY = button.frame.origin.y }
            }
        }
        guard let defaultY = trafficLightDefaultY,
              let closeButton = window.standardWindowButton(.closeButton),
              let closeDefaultX = trafficLightDefaultXs[NSWindow.ButtonType.closeButton.rawValue]
        else { return }
        // 整组横向平移量:让 close 的中心落到目标 x(默认位已对时 dx≈0,写入是 no-op)。
        let dx = (Self.trafficLightCloseCenterX - closeButton.frame.width / 2) - closeDefaultX
        // AppKit y 向上:origin.y 减小 = 视觉往下。
        let targetY = defaultY - Self.trafficLightDownshift
        for type in types {
            guard let button = window.standardWindowButton(type),
                  let defaultX = trafficLightDefaultXs[type.rawValue] else { continue }
            let targetX = defaultX + dx
            if abs(button.frame.origin.y - targetY) > 0.5 || abs(button.frame.origin.x - targetX) > 0.5 {
                button.setFrameOrigin(NSPoint(x: targetX, y: targetY))
            }
        }
    }

    // 只在窗口第一次挂上来时调一次,拿到真实 NSWindow 存住弱引用,同时挂两个兜底:
    // ① 窗口关闭就强制退出伪全屏——不然用户在伪全屏状态下直接关闭这个窗口,
    // presentationOptions 全局状态(菜单栏/Dock 隐藏)会一直挂着不清,污染到 App 里其它
    // 窗口甚至其它 App 的观感,必须在窗口消失前无条件复原。
    // ② 窗口失去 key 状态(不关闭,只是用户切到 App 内其它窗口,比如设置页/歌词管理)
    // 也退出伪全屏——2026-08-02 实测排查过一轮:presentationOptions 是 NSApplication
    // 级别的进程级全局状态,不跟哪一扇具体窗口绑定,只在①这个窗口关闭时才清理是不够的:
    // 用户在这个窗口开着伪全屏、切去操作另一扇窗口时,菜单栏/Dock 会跟着继续隐藏,
    // 那扇窗口反而变得不好用(找不到菜单栏)。真全屏(其它 App 常见的那种)在这种场景下
    // 是"焦点窗口所在的那个 Space 单独隐藏菜单栏",别的窗口不受影响;这里没有真的 Space
    // 隔离,只能退而求其次——失去焦点就整个退出伪全屏,不去做"记住哪些窗口該保持全屏"
    // 这类更复杂的模拟。置顶状态不需要类似兜底——window.level 是这个 NSWindow 实例自己
    // 的属性,窗口一关就随实例一起没了,也不受切换焦点影响,不会像 presentationOptions
    // 那样是进程级的全局状态、需要显式清理。
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // 原生全屏(2026-08-21):.windowFullScreenBehavior(.enabled) 在这版 SwiftUI 上
        // 实测没生效(绿键仍是 AXZoomButton),AppKit 层直接改 collectionBehavior 强制
        // 打开;探针实验证明同进程纯 AppKit 窗全屏机制完好。
        // ⚠️ 设一次不够:SwiftUI 会在后续更新周期把 collectionBehavior 复写回去 ——
        // 实测右上角按钮(toggle 前刚补过标志)能进真全屏,绿键(用系统当下的标志)却
        // 还是 zoom。挂 didUpdate(每个绘制周期)做**持续守护**,回调只查一个位、缺了
        // 才写,写入本身也满足守卫条件,不会自激。
        Self.enforceFullScreenCapability(window)
        enforceTrafficLightPosition(window)
        if let fullScreenCapabilityObserver { NotificationCenter.default.removeObserver(fullScreenCapabilityObserver) }
        fullScreenCapabilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let win = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                Self.enforceFullScreenCapability(win)
                self?.enforceTrafficLightPosition(win)
            }
        }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forceExit() }
        }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forceExit() }
        }
        // 真原生全屏的状态跟踪(2026-08-21):按钮图标/提示跟着换,进入时装 Esc 退出
        // (AM 同款手感;guard isKeyWindow 的理由同伪全屏那段注释)。真全屏不需要
        // forceExit 那类清理 —— Space/菜单栏都是系统管的,切走焦点它自己好好的。
        if let enterFullScreenObserver { NotificationCenter.default.removeObserver(enterFullScreenObserver) }
        enterFullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isNativeFullScreen = true
                if self.nativeFullScreenEscapeMonitor == nil {
                    self.nativeFullScreenEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                        guard event.keyCode == 53, // kVK_Escape
                              let self, self.isNativeFullScreen,
                              self.window?.isKeyWindow == true else { return event }
                        self.window?.toggleFullScreen(nil)
                        return nil
                    }
                }
            }
        }
        if let exitFullScreenObserver { NotificationCenter.default.removeObserver(exitFullScreenObserver) }
        exitFullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isNativeFullScreen = false
                if let monitor = self.nativeFullScreenEscapeMonitor {
                    NSEvent.removeMonitor(monitor)
                    self.nativeFullScreenEscapeMonitor = nil
                }
            }
        }
    }

    func toggleAlwaysOnTop() {
        guard let window else { return }
        isAlwaysOnTop.toggle()
        window.level = isAlwaysOnTop ? .floating : .normal
    }

    /// 真·原生全屏进行中(自己的 Space、三指横滑)。与伪全屏 isActive 是两个独立状态:
    /// 真全屏由系统管理,切走焦点/关窗都不需要我们清理什么;伪全屏的 presentationOptions
    /// 全局态才需要 forceExit 那套兜底。
    @Published private(set) var isNativeFullScreen = false
    /// 按钮图标/提示用:处于任意一种全屏。
    var isFullScreenActive: Bool { isActive || isNativeFullScreen }

    func toggle(reduceMotion: Bool) {
        // macOS 15+ 走真原生全屏(2026-08-21:根因坐实是 SwiftUI Window 默认禁全屏,
        // 场景内容挂 .windowFullScreenBehavior(.enabled) 已打开,见 App.swift)。
        // 伪全屏只留给拿不到那个修饰符的老系统兜底。
        if #available(macOS 15.0, *), let window {
            // 进全屏前再补一次(didUpdate 守护之外的双保险,幂等)。
            Self.enforceFullScreenCapability(window)
            window.toggleFullScreen(nil)
            return
        }
        if isActive {
            exit(animate: !reduceMotion)
        } else {
            enter(animate: !reduceMotion)
        }
    }

    private func enter(animate: Bool) {
        guard let window, let screen = window.screen ?? NSScreen.main, !isActive else { return }
        savedFrame = window.frame
        // 标题栏透明/隐藏/fullSizeContentView 已是常驻状态(scene 的 .hiddenTitleBar,
        // 2026-08-21 AM 式顶部),这里只需要藏红黄绿。
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // .autoHideMenuBar 单独用没有效果——文档要求两个一起设,菜单栏才会真的让出空间、
        // 悬停到顶部才重新弹出(实测坐实,不是随手加的)。
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        window.setFrame(screen.frame, display: true, animate: animate)
        isActive = true
        // ⚠️ 上面这次 setFrame 可能被钳:presentationOptions 刚设下去、菜单栏还没真正
        // 让位时,WindowServer 会把 normal 层级窗口的 frame 压到菜单栏之下 —— 表现为
        // "全屏后顶上留一条空"(2026-08-21 用户实测)。等隐藏生效后再校两次(一拍 +
        // 0.35s 兜底,动画版 setFrame 也要等它跑完),已经到位就是 no-op。
        for delay in [0.05, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isActive, let window = self.window else { return }
                if window.frame != screen.frame {
                    window.setFrame(screen.frame, display: true)
                }
            }
        }
        // Esc 退出——伪全屏状态下用户的第一直觉,跟真全屏的既有习惯一致。用局部事件
        // 监听(跟 ShortcutRecorderButton 同款手法),不是全局热键。
        //
        // ⚠️ NSEvent.addLocalMonitorForEvents 是"发给本 App 任意窗口"级别的钩子,不是
        // 按窗口过滤的——2026-08-02 实测排查坐实:早先这里的注释错误地写着"只在这个
        // 窗口是第一响应者时才拦截",但回调体内其实完全没有做这个判断,导致用户在这个
        // 窗口伪全屏时,切去 App 内另一扇窗口(比如设置页的"存为新配色主题"弹窗)按 Esc
        // 想做别的操作(取消弹窗),会被这里无条件 return nil 吞掉——目标窗口收不到这次
        // Esc,后台这扇窗口反而莫名退出了全屏。现在显式判断 self?.window?.isKeyWindow,
        // 不是当前 key window 就放行事件(return event),不拦截、也不触发 exit。跟上面
        // attach() 里新增的 didResignKeyNotification 兜底是两道独立防线:那道处理"切走
        // 焦点后主动退出全屏"这个状态清理,这里处理"这次具体的 Esc 按键该不该被这个
        // 监听器吞掉",避免依赖两个异步通知的到达顺序。
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53, self?.window?.isKeyWindow == true else { return event } // 53 = kVK_Escape
            self?.exit(animate: true)
            return nil
        }
    }

    private func exit(animate: Bool) {
        guard let window, isActive else { return }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        NSApp.presentationOptions = []
        if let savedFrame {
            window.setFrame(savedFrame, display: true, animate: animate)
        }
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        // 标题栏不复原:透明+无标题是常驻状态(.hiddenTitleBar),这里恢复的只有红黄绿。
        savedFrame = nil
        isActive = false
    }

    // 窗口关闭/失去焦点时的无条件复原——跟上面 exit(animate:) 的区别是不需要动画(前者
    // 窗口马上就没了,后者用户已经在看别的窗口,过渡动画没有意义,反而显得拖沓)。
    private func forceExit() {
        guard isActive else { return }
        exit(animate: false)
    }

    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let nativeFullScreenEscapeMonitor { NSEvent.removeMonitor(nativeFullScreenEscapeMonitor) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        if let enterFullScreenObserver { NotificationCenter.default.removeObserver(enterFullScreenObserver) }
        if let exitFullScreenObserver { NotificationCenter.default.removeObserver(exitFullScreenObserver) }
        if let fullScreenCapabilityObserver { NotificationCenter.default.removeObserver(fullScreenCapabilityObserver) }
    }
}

private struct LyricsWindowCapture: NSViewRepresentable {
    let controller: LyricsWindowController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                controller.attach(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            controller.attach(window)
        }
    }
}
//
// "歌词窗口"(2026-07-31 新增):正经的标题栏窗口,展示当前歌曲完整歌词并跟随播放
// 自动滚动高亮当前行——跟悬浮歌词(LyricsOverlayView)/灵动岛歌词(NotchLyricsView)
// 那种"只看当前一句"的无边框浮层是完全不同的形态,不复用它们的 AppSettings 主题
// (foregroundColor/textStrokeEnabled/fontFamilyName/fontSize/overlayWidth 这些是为了
// 在任意桌面背景上保持可读性专门调的),默认用系统原生颜色(.primary/.secondary,自动
// 跟随浅色/深色模式),风格更接近"歌词管理"窗口而不是悬浮窗。
//
// 例外:拿到当前曲目的封面图时(见 PlaybackCoordinator.artworkData),背景会铺一层
// 模糊+压暗的封面(Apple Music 歌词页最标志性的元素),这时候文字底下不再是纯系统
// 窗口背景,如果继续吃 .primary/.secondary,浅色系统外观下会变成"深色文字配深色模糊
// 照片"、基本看不清——所以只要有封面数据,主/罗马音/译文这三行文字统一切到固定的浅色
// (不跟随系统深浅色),拿不到封面(还没换过一次歌、这次 Now Playing 会话本来没有封面
// 数据)时维持原来的纯系统色,不会出现"有时候看得清有时候看不清"的中间态。
//
// 自动滚动 + 手动回归的交互思路直接照抄 LyricsManagerView.focusCurrentlyPlaying 的
// 按钮点子:工具栏放一个"回到当前播放",不试图自动侦测"用户是不是正在手动往回翻歌词"
// ——那需要 SwiftUI 较新的 scrollPosition(id:) 读写观察机制,这个项目目前完全没有
// 用过,没能真机验证它跟这里用的 ScrollViewReader.scrollTo 混用是否稳定;这次先用
// LyricsManagerView 已经验证过的简单方案:自动跟随永远生效,用户想往回看就手动滚,
// 看完点"回到当前播放"跳回去。如果实际用起来觉得"被拽回去"太打扰,再考虑加那套更
// 复杂的侦测逻辑。
struct LyricsWindowView: View {
    // 不整对象订阅 PlaybackCoordinator/AppSettings —— 见 WindowPlayback 的注释。
    @StateObject private var playback = WindowPlayback()
    @StateObject private var windowController = LyricsWindowController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 这块屏一个点等于几个物理像素。外接 1x 显示器上 = 1,内建 Retina = 2 —— 逐字抬升
    // 的落点要按它对齐到整像素,见 karaokeRise。
    @Environment(\.displayScale) private var displayScale
    /// 封面的实际边长。控制排的图标大小和间距都按它算 —— 封面是随窗口缩放的,而按钮
    /// 原来是写死的字号,窄窗口下整排比左栏还宽、最左边那个模式键直接被裁在窗口外面
    /// (2026-08-09 用户截图),宽窗口下又显得过小、跟封面不成比例。
    @State private var artworkWidth: CGFloat = 0
    /// 鼠标悬在哪一行(行 id)。悬停的行不虚化、点一下跳到那一句。
    @State private var hoveredLineID: String?
    /// 「…」的自绘 AM 式菜单开着没有(2026-08-21,替代系统 Menu,见 titleSideButtons)。
    @State private var showsMoreMenu = false
    /// 「显示简介」面板(2026-08-22,「⋯」菜单项之一):与菜单同锚点、同玻璃样式。
    @State private var showsInfoPanel = false
    /// 右下角「翻译与发音」菜单(2026-08-22,对照 AM 歌词页右下角同位按钮):开关的是
    /// 设置里现成的 showTranslation/showRomanization 两个总开关,这里只是快捷入口。
    @State private var showsTranslationMenu = false
    /// 歌词栏显隐(2026-08-22,AM 右下角「引号气泡」钮):关掉=封面居中的纯播放器视图
    /// (AM 同款)。会话内状态,不持久化。仅双列模式可关 —— 单列窗口整个就是歌词,
    /// 关了剩一片空白(生效判断见 body 的 lyricsPaneVisible)。
    @State private var showsLyricsPane = true
    /// 「播放队列」面板(2026-08-22,AM 右下角「列表」钮):内容=current playlist 从
    /// 当前曲目起的一段(nil=加载中,空=拿不到)。
    @State private var showsQueuePanel = false
    @State private var queueItems: [MusicPlaybackController.UpNextItem]?
    /// 自绘滚动指示条的数据(offset/内容高):收在小 model 里、只有指示条子视图订阅 ——
    /// 滚动期间逐帧的 preference 更新不能拖着整窗 body 陪跑(性能纪律同 WindowVolumeCapsule)。
    @StateObject private var scrollMetrics = LyricsScrollMetricsModel()
    /// 停播欢迎态的呼吸动画驱动(onAppear 置真触发 repeatForever)。
    @State private var idleBreath = false
    /// 简介面板里的歌词来源(EnrichCacheReader 异步查,面板打开时取一次)。
    @State private var infoLyricsSource: String?
    /// 「搜索歌词…」的上下文(2026-08-22):菜单点击瞬间把 曲目字段+写回 key+当前来源
    /// 一次性快照下来 —— sheet 打开期间歌可能换,搜索和写回都要钉在点击那一刻的曲目上。
    @State private var lyricsSearchContext: LyricsSearchContext?
    /// 「添加到资料库」行的即时状态(2026-08-22):此前点完静默关面板,成功/本来就在库/
    /// 失败三种结局全都看不出差别(用户实测"点了没反应"那次就是歌 7 月已在库、duplicate
    /// 静默 no-op)。现在开菜单时异步查一次"已在库?",点击后行内走 添加中→已添加/失败,
    /// 全程不关菜单。
    private enum LibraryAddState: Equatable {
        case idle, alreadyInLibrary, adding, added, failed, removing, removeFailed
    }
    @State private var libraryAddState: LibraryAddState = .idle
    /// 「减少推荐」是否已生效(同上一批的反馈缺口):开菜单时读回 disliked,行上带勾;
    /// 点击在 减少/撤销 之间切换 —— AM 自己的菜单也是勾选态可再点撤销。
    @State private var suggestLessApplied = false
    /// 菜单状态代际:每次 刷新(开菜单/菜单开着换曲) +1。异步任务(回查/添加)落地前
    /// 核对自己出发时的代际,不同代际=过期结果直接丢弃 —— 防止上一首歌的在途结果
    /// 贴到新曲的菜单上(审阅抓的跨曲竞态)。
    @State private var moreMenuStateGeneration = 0
    /// 本次菜单会话内用户是否已手动切过「减少推荐」:切过之后,后到的回查结果不许再
    /// 覆盖它(回查读的是开菜单那一刻的旧值,覆盖=抹掉用户刚点的勾)。
    @State private var suggestLessUserToggled = false
    /// 「减少推荐」写操作串行链:快速连点时两个 detached task 之间本无顺序保证,
    /// 后点的先执行会让终态与 UI 相反 —— 每次写先 await 上一次,保证按点击序生效。
    @State private var suggestLessSerialTask: Task<Void, Never>?
    /// 音频输出面板(AirPlay 键)开着没有;isExternalOutput = 默认输出是非内建设备
    /// (键染红,开窗/开关面板/选设备时刷新)。
    @State private var showsOutputMenu = false
    @State private var isExternalOutput = false
    @Environment(\.colorScheme) private var colorScheme
    /// 歌词那一栏的实际宽度。字号按它算 —— 写死 28pt 的话窗口越拖越大、文字占的比例
    /// 越来越小,右边空出一大片(2026-08-09 用户对比 Apple Music 提的)。Apple Music 的
    /// 歌词字号是跟着窗口长的,这里照做。
    @State private var lyricsColumnWidth: CGFloat = 0
    /// 歌词栏可视高度。字号的主锚(见 lyricFontSize):AM 的"一屏约 7 行"是行距吃掉
    /// 窗高 12.9% 的结果,行距又是字号的固定倍数,所以字号必须跟高度走才能锁住行数。
    @State private var lyricsViewportHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { scrollProxy in
            GeometryReader { geo in
                // 2026-08-04 按 Apple Music 歌词页一比一重做:左列是封面卡片+曲目信息+
                // 进度条+播放控制,右列是左对齐的大字歌词。左列只在窗口够宽时显示——
                // 老版本竖长窗口的存档尺寸(~460pt)下硬塞两列会挤成一团,退化成只有
                // 歌词的单列,跟 Apple Music 自己把窗口拖窄时的行为一致。
                let showPlayerPane = geo.size.width >= 640
                // 布局比例一比一对齐 Apple Music 歌词页(2026-08-21 按用户红框标注逐项
                // 量出,AM 截图 1999px 宽):封面左缘 0.111W、封面宽 0.279W(上限 460pt,
                // 超宽窗口不再放大)、歌词文字左缘 0.515W、右缘留 0.06W。此前面板贴左
                // 缘(3%W)、歌词从 0.34W 就开始,整体重心偏左,跟 AM 的"左右两半、各自
                // 大留白"的观感差一截。
                let coverWidth = min(geo.size.width * 0.279, 460)
                // 歌词栏只有双列模式可隐藏(单列=整窗都是歌词,关了剩空白,强制显示)。
                let lyricsPaneVisible = showsLyricsPane || !showPlayerPane
                let paneLeading = lyricsPaneVisible
                    ? geo.size.width * 0.111
                    // 歌词隐藏 = AM 的"封面居中"纯播放器视图,左缘 padding 把封面推到正中。
                    : (geo.size.width - coverWidth) / 2
                // 停播欢迎态(2026-08-22 用户选型 B+D):整窗换成居中 hero,不再摆一套
                // 没有内容的双列骨架(占位封面+悬空「⋯」+光杆播放键)。判据与
                // emptyStateSpec 第一档同源:停播时 LocalPlaybackSource 清曲目,title 空。
                let isIdle = playback.title.isEmpty
                Group {
                if isIdle {
                    idleWelcomeView
                        .offset(y: -geo.safeAreaInsets.top / 2)
                } else {
                HStack(spacing: 0) {
                    if showPlayerPane {
                        playerPane
                            .frame(width: coverWidth)
                            .padding(.leading, paneLeading)
                            .frame(maxHeight: .infinity)
                            // 垂直居中基准=整窗(2026-08-22 第二轮对拍:AM 左列内容中心
                            // 落在整窗高度中点 429pt,我们此前在 safe area 内居中 ——
                            // hiddenTitleBar 仍有 ~28pt 顶部 inset,整列被压低半个 inset,
                            // 正是用户红框"左栏坐标没对齐"的主项。渲染偏移不影响布局。
                            // 再 −2:实拍残差,整列仍比 AM 低 4px@2x)。
                            .offset(y: -geo.safeAreaInsets.top / 2 - 2)
                    }
                    if lyricsPaneVisible {
                        rightPane(
                            leading: showPlayerPane
                                ? max(24, geo.size.width * 0.515 - (geo.size.width * 0.111 + coverWidth))
                                : 44,
                            trailing: max(32, geo.size.width * 0.06)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 0).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // ignoresSafeArea:AM 式顶部(.hiddenTitleBar)下背景要一直通到窗顶、
                // 红绿灯悬浮其上。旧的"不 ignoresSafeArea"是为了避开系统标题栏文字
                // 撞色——标题已隐藏,那个约束不存在了。
                .background(artworkBackground.ignoresSafeArea())
                // ⚠️ 音量胶囊必须**浮在内容之上**,不能放进 .toolbar。
                //
                // 2026-08-09 用户反馈"这个玻璃效果好垃圾",对比 Apple Music 那个能透出背景
                // 暖色、边缘有光泽的胶囊。查了 Liquid Glass 的规则(见 LiquidGlassReference:
                // "Glass cannot sample other glass"、"Avoid Glass-on-Glass"、玻璃只用于
                // **浮在内容之上**的导航层),再做了一次对照实验:同一个胶囊同时放进工具栏和
                // 内容浮层,同一张截图里工具栏那个是灰扁色块、浮层那个透出了背后模糊封面的
                // 暖棕色。工具栏本身就是一层玻璃,玻璃采样不到玻璃,只能退化成不透明材质。
                .overlay(alignment: .topTrailing) {
                    // 音量胶囊自持订阅(2026-08-19 性能审计):soundVolume 故意不进
                    // WindowPlayback 代理,拖音量只失效这个小胶囊,不再整窗重估。
                    // 右上只放它一颗(2026-08-22 第二轮对拍:AM 右上就一颗音量胶囊,
                    // 窗口动作胶囊在 AM 是左上 X/画中画那颗 —— 置顶/全屏挪去左上同位,
                    // 见下一个 overlay)。
                    WindowVolumeCapsule(onArtwork: hasArtworkBackground,
                                        showsOutputMenu: $showsOutputMenu,
                                        isExternalOutput: isExternalOutput)
                    // 贴右缘 5pt(2026-08-22 第二轮对拍:AM 胶囊亮缘离窗缘 8px@2x,
                    // 布局缘取 5 让亮缘落到同位)。
                    .padding(.trailing, 5)
                    // 与红绿灯同一行(2026-08-22 第二轮对拍 AM 整窗参考图):胶囊
                    // y16-87px@2x → 顶 8pt+高 36/2 → 中心 26,与红绿灯(下移 10 后
                    // 中心 26)同心。⚠️ 必须减掉 safeAreaInsets.top:hiddenTitleBar 下
                    // 内容区顶部仍有一段标题栏高度的 safe inset,"top 0" 只是内容区顶,
                    // 第一版就是因此整体低了约 28pt(用户截图实锤"明显没有在同一行")。
                    .offset(y: -geo.safeAreaInsets.top + 8)
                }
                .overlay(alignment: .topLeading) {
                    // 置顶/全屏胶囊(2026-08-22 第二轮对拍挪到左上:AM 同位是 X/画中画
                    // 那颗,x204-349px@2x → 左缘 102pt、高 71px 与右上音量胶囊一致)。
                    windowActionsCapsule()
                        .padding(.leading, 102)
                        .offset(y: -geo.safeAreaInsets.top + 8)
                }
                // 「…」的 AM 式自绘菜单:锚在按钮上方、右缘对齐按钮右缘(AM 的菜单就悬在
                // 那两颗圆钮上方)。放在**窗级** overlay 而不是按钮的 overlay:面板要浮在
                // 歌词列表之上,且"点面板外任何地方关掉"需要一层全窗捕手。
                .overlayPreferenceValue(MoreMenuButtonBoundsKey.self) { anchor in
                    if showsMoreMenu, let anchor {
                        let r = geo[anchor]
                        ZStack(alignment: .bottomTrailing) {
                            // 全窗点击捕手(透明但可命中),点哪都只是关菜单。
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsMoreMenu = false }
                                }
                                .transition(.opacity)
                            moreMenuPanel
                                .fixedSize()
                                .padding(.trailing, max(8, geo.size.width - r.maxX))
                                .padding(.bottom, max(8, geo.size.height - r.minY + 8))
                                // 缩放锚在面板右下角 —— 正好是贴着「…」按钮的那个角,
                                // 观感是从按钮上长出来(AM 同款)。
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                        }
                    }
                }
                // 「显示简介」面板(2026-08-22):从「⋯」菜单点出,与菜单同锚点同样式。
                .overlayPreferenceValue(MoreMenuButtonBoundsKey.self) { anchor in
                    if showsInfoPanel, let anchor {
                        let r = geo[anchor]
                        ZStack(alignment: .bottomTrailing) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsInfoPanel = false }
                                }
                                .transition(.opacity)
                            trackInfoPanel
                                .fixedSize()
                                .padding(.trailing, max(8, geo.size.width - r.maxX))
                                .padding(.bottom, max(8, geo.size.height - r.minY + 8))
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                        }
                    }
                }
                // 右下角「翻译与发音」按钮(2026-08-22,AM 歌词页同位;二轮外观严格对拍:
                // AM 该钮 71×71px@2x=35.5pt——与顶部胶囊同高度档,贴角 右10/底11pt;
                // 译文正在显示时是**激活态**=近白填充圆+深色字形(实测填充亮度 220 vs
                // 背景 70),未激活=与顶部胶囊同款 clearGlass 玻璃圆。此前 26pt 平底暗圆
                // 被用户抓出"大小和质感都不对")。只在当前曲目真有译文或罗马音时出现 ——
                // 两行全灰的菜单比没有更糟。
                .overlay(alignment: .bottomTrailing) {
                    // 右下角一排(2026-08-22 三批,AM 歌词页同布局):翻译圆钮 + [歌词|队列]
                    // 双钮胶囊。间距/边距照 AM 实测:胶囊贴角 右10/底11,翻译钮在其左、
                    // 间隔 8.5(AM 翻译钮右缘距窗缘 90.5pt=10+71.5+8.5)。
                    HStack(spacing: 8.5) {
                        if !isIdle, playback.hasLyricsContent && (trackHasTranslation || trackHasRomanization)
                            && lyricsPaneVisible {
                            Button {
                                withAnimation(.easeOut(duration: 0.12)) { showsTranslationMenu.toggle() }
                            } label: {
                                translationButtonLabel
                            }
                            .buttonStyle(.plain)
                            .help(L10n.t("翻译与发音"))
                            .anchorPreference(key: TranslationMenuButtonBoundsKey.self, value: .bounds) { $0 }
                        }
                        if !isIdle { lyricsQueuePill(showPlayerPane: showPlayerPane) }
                    }
                    .padding(.trailing, 10)
                    .padding(.bottom, 11)
                }
                // 「播放队列」面板:锚在胶囊上方、右缘对齐(机制同翻译菜单)。
                .overlayPreferenceValue(QueuePillBoundsKey.self) { anchor in
                    if showsQueuePanel, let anchor {
                        let r = geo[anchor]
                        ZStack(alignment: .bottomTrailing) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsQueuePanel = false }
                                }
                                .transition(.opacity)
                            queuePanel
                                .fixedSize()
                                .padding(.trailing, max(8, geo.size.width - r.maxX))
                                .padding(.bottom, max(8, geo.size.height - r.minY + 8))
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                        }
                    }
                }
                // 「翻译与发音」菜单:同「⋯」菜单的窗级自绘玻璃面板机制,悬在按钮上方、
                // 右缘对齐(AM 同款)。
                .overlayPreferenceValue(TranslationMenuButtonBoundsKey.self) { anchor in
                    if showsTranslationMenu, let anchor {
                        let r = geo[anchor]
                        ZStack(alignment: .bottomTrailing) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsTranslationMenu = false }
                                }
                                .transition(.opacity)
                            translationMenuPanel
                                .fixedSize()
                                .padding(.trailing, max(8, geo.size.width - r.maxX))
                                .padding(.bottom, max(8, geo.size.height - r.minY + 8))
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                        }
                    }
                }
                // 音频输出面板(AirPlay 键弹出,2026-08-21):同「⋯」菜单的窗级自绘玻璃
                // 面板机制,锚在按钮**下方**(AM 的输出面板悬在胶囊下方)。⚠️ 按钮的锚点
                // 坐标在 safe 区坐标系里,而胶囊行被 offset 提到了真窗顶(−safeTop+6),
                // 面板定位要做同样的换算。
                .overlayPreferenceValue(OutputMenuButtonBoundsKey.self) { anchor in
                    if showsOutputMenu, let anchor {
                        let r = geo[anchor]
                        let buttonBottom = r.maxY - geo.safeAreaInsets.top + 6
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsOutputMenu = false }
                                }
                                .transition(.opacity)
                            outputDevicePanel
                                .fixedSize()
                                .padding(.leading, max(8, r.minX - 16))
                                .padding(.top, max(8, buttonBottom + 8))
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                    }
                }
            }
            // 「搜索歌词…」:歌词管理的联网搜索面板独立调起(它自包含,写回 key 由这里
            // 持有,见 LyricsSearchContext)。用 sheet(item:) 而不是 isPresented:上下文
            // 快照即身份,换歌后再开是新的一份。
            .sheet(item: $lyricsSearchContext) { ctx in
                LyricsSearchSheet(
                    artist: ctx.artist, title: ctx.title, album: ctx.album,
                    currentSource: ctx.currentSource, durationSecs: ctx.durationSecs
                ) { candidate in
                    Task {
                        // reload(onlyIfChanged:) 兜住「store 还没加载过」:saveEdit 直接改
                        // raw[key],空 raw 上写会把条目的其它字段(cover_url 等)整个丢掉。
                        await EnrichCacheStore.shared.reload(onlyIfChanged: true)
                        await EnrichCacheStore.shared.saveEdit(
                            key: ctx.key,
                            lyrics: candidate.lyrics, tr: candidate.lyricsTr,
                            roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC,
                            source: candidate.source)
                        // 让播放侧立刻重载,不等 2s 轮询的 mtime 检查。
                        PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
                    }
                }
            }
            .onChange(of: playback.currentLineIndex) {
                scrollToActiveLine(scrollProxy: scrollProxy, animated: true)
            }
            .onChange(of: playback.currentGapIndex) {
                // 进入间奏 → 滚到那排「•••」(跟当前行同一个 41% 锚位)。出间奏不用管:
                // 下一句开始时 currentLineIndex 变化,上面那条 onChange 自然把页面滚过去。
                // intro(-1)不走 gapRowID:那一行刚在本次事务里插入、还没布局,scrollTo
                // 解析不到 —— 交给 scrollToActiveLine 的"滚第一句、锚 0.52"路径,再延一拍
                // 让布局先落地(实测同一事务里滚,圆点停在列表顶部)。
                if let g = playback.currentGapIndex {
                    if g == -1 {
                        DispatchQueue.main.async {
                            scrollToActiveLine(scrollProxy: scrollProxy, animated: true)
                        }
                    } else if let id = gapRowID(g) {
                        withAnimation(Self.lineTransition) {
                            scrollProxy.scrollTo(id, anchor: Self.activeLineAnchor)
                        }
                    }
                }
            }
            .onChange(of: playback.allLines) {
                // 换歌/歌词内容重新加载:新旧两份数组的 id 前缀完全不同(见
                // LyricsWindowLine 类型注释),等新内容渲染出来后跳到新歌当前行——
                // 还没到第一句时锚到前奏「•••」/间奏点(AM 式开场,歌词从窗口中部
                // 开始,见 scrollToActiveLine 的兜底链)。
                DispatchQueue.main.async {
                    scrollToActiveLine(scrollProxy: scrollProxy, animated: false)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    scrollToActiveLine(scrollProxy: scrollProxy, animated: false)
                }
            }
        }
        // 2026-08-04 从竖长阅读面板改成 Apple Music 歌词页同款的横向双列比例。窗口尺寸
        // 由系统状态恢复机制记忆,老用户第一次打开还是旧的竖长尺寸(此时按上面的宽度
        // 判断退化成单列),手动拖宽一次之后就会记住新比例。
        .frame(minWidth: 520, idealWidth: 1020, minHeight: 480, idealHeight: 660)
        .background(LyricsWindowCapture(controller: windowController).frame(width: 0, height: 0))
        // 见 AuxiliaryWindowActivation 注释——.accessory 策略下临时借一个 Dock 图标,
        // 方便 Cmd-Tab 切回这扇正经标题栏窗口(这个窗口本来就设计成"跟随播放持续显示",
        // 用户中途切去别的 App 很常见)。
        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }
        .onDisappear { AuxiliaryWindowActivation.windowDidDisappear() }
        // 音量跟"喜欢""播放模式"共用同一批刷新时机,理由见下面那段注释。
        // "喜欢"状态不跟着 2 秒轮询走(每读一次要起一个 osascript 子进程,为一个几乎不变
        // 的布尔值那么干不值当),换歌时由 PlaybackCoordinator 刷一次。悬浮窗还借"控制排
        // 露出来"这个动作补刷,而这扇窗口是常显的、没有那个动作,所以换成:打开时刷一次,
        // 以及每次 App 重新变成前台时刷一次 —— 后者正好覆盖"用户刚切去 Music.app 点了
        // 心、再切回来"这条路径。
        .onAppear {
            PlaybackCoordinator.shared.refreshFavorited()
            PlaybackCoordinator.shared.refreshPlaybackMode()
            PlaybackCoordinator.shared.refreshVolume()
            isExternalOutput = AudioOutputDeviceManager.isExternalOutputActive()
        }
        // 面板开合时都刷一次"外接输出中":用户可能刚在系统里切过输出。
        .onChange(of: showsOutputMenu) {
            isExternalOutput = AudioOutputDeviceManager.isExternalOutputActive()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // 可见性守卫(2026-08-19 性能审计):Window 场景关闭后视图树/订阅仍保活,
            // 原来每次 App 激活(Cmd-Tab/点状态栏)都在关着的窗口背后白起最多 3 个
            // osascript 子进程。重开窗口时上面 onAppear 的全量刷新本来就会跑一遍。
            guard windowController.isWindowVisible else { return }
            PlaybackCoordinator.shared.refreshFavorited()
            PlaybackCoordinator.shared.refreshPlaybackMode()
            PlaybackCoordinator.shared.refreshVolume()
        }
    }

    private var activeID: String? {
        guard let idx = playback.currentLineIndex, playback.allLines.indices.contains(idx) else { return nil }
        return playback.allLines[idx].id
    }

    // Apple Music 歌词页把当前行定位在窗口偏上约 1/3 处(不是正中)——上面留少量已经
    // 唱过的行,下面留更多即将到来的行,2026-08-04 从 .center 改过来。
    // 0.41:AM 整窗截图里当前行中心在窗高 691/1690 = 40.9% 处(2026-08-21 量,原 0.35)。
    private static let activeLineAnchor = UnitPoint(x: 0.5, y: 0.41)

    /// 换行时整页滚动 + 每行虚化/亮度/缩放变化,用**同一条**曲线、同一个时长 —— 原来滚动
    /// 用 withAnimation 的默认曲线、行样式用 easeInOut(0.3),两套动画各走各的,同一次换行
    /// 里页面和文字的节奏对不上,看起来就是"一顿一顿"。
    ///
    /// 用 .smooth(无回弹的弹簧)而不是 easeInOut:Apple Music 的歌词滚动是减速停下、末尾
    /// 不回弹,easeInOut 起步太"推"、收尾太硬。
    static let lineTransition: Animation = .smooth(duration: 0.45)

    private func scrollToActiveLine(scrollProxy: ScrollViewProxy, animated: Bool) {
        // 开场(还没唱到第一句)不停在顶部:AM 的开场是前奏「•••」锚在 41%、第一句
        // 在它下方约窗高 52% 处(2026-08-21 对照 AM 截图量出第一句中心 51.8%)。
        // ⚠️ 不能直接 scrollTo「•••」那一行 —— gapDotsRow 不活跃时整行不渲染,id 根本
        // 没注册,scrollTo 静默无效;激活的同一事务里滚,行还没布局同样无效(第一版
        // 兜底链就是这么失败的,实测圆点停在列表顶部)。也不能给它加零高占位行:
        // VStack 会为占位多算一段行距,所有带间奏点的位置行距全变。
        // 所以 intro 场景滚**第一句**(永远存在、永远有布局),锚点下移一行的量(0.52)。
        let target: (id: String, anchor: UnitPoint)?
        if let id = activeID {
            target = (id, Self.activeLineAnchor)
        } else if gapMarker(-1) != nil, let first = playback.allLines.first {
            target = (first.id, UnitPoint(x: 0.5, y: 0.52))
        } else {
            target = nil
        }
        guard let target else { return }
        if animated {
            withAnimation(Self.lineTransition) {
                scrollProxy.scrollTo(target.id, anchor: target.anchor)
            }
        } else {
            scrollProxy.scrollTo(target.id, anchor: target.anchor)
        }
    }

    // ---- 右列:歌词滚动列表 / 占位态 --------------------------------------------

    /// 歌词正文字号。系数是 2026-08-21 从 AM 歌词页整窗截图(2940×1690 @2x,即
    /// 1470×845pt)量出来的:当前行「无敌铁金刚」墨高 89px,PingFang 粗体的墨高/字号比
    /// 0.88(离线 ImageRenderer 标定)→ 字号 50.6pt;除以窗高 845pt 得 0.0598×窗高,
    /// 除以右栏宽 896.7pt 得 0.0564×右栏宽。两个锚在 AM 自己的窗口纵横比下相等,取
    /// min:窗口偏矮时高度锚接管(保住"一屏约 7 行"),偏窄时宽度锚接管(别让长句
    /// 疯狂折行)。上界不再夹死(旧版 56):AM 全屏字号能到 68pt+,一比一就该跟着长。
    private var lyricFontSize: CGFloat {
        let w = lyricsColumnWidth > 0 ? lyricsColumnWidth : 460
        let h = lyricsViewportHeight > 0 ? lyricsViewportHeight : 640
        return max(22, min(h * 0.0598, w * 0.0564))
    }
    // 罗马音/译文跟正文保持原来的比例(15/28、17/28)。
    private var romaFontSize: CGFloat { lyricFontSize * 0.54 }
    private var translationFontSize: CGFloat { lyricFontSize * 0.61 }
    /// 行间距:AM 行距(基线到基线)218px / 字号 101px = 2.156em;单行 Text 视图高
    /// 1.175em(同一次 ImageRenderer 标定),VStack spacing = 2.156 − 1.175 ≈ 0.98em。
    /// 旧值 1.14em 比 AM 松 8%,是"一屏 7 行"差一口气的原因之一。
    private var lyricLineSpacing: CGFloat { lyricFontSize * 0.98 }

    @ViewBuilder
    private func rightPane(leading: CGFloat, trailing: CGFloat) -> some View {
        if playback.allLines.isEmpty {
            emptyState
        } else {
            ScrollView {
                // 用 VStack 而不是 LazyVStack:歌词就几十行(这首 43 行),lazy 省不下什么,
                // 却会让带动画的 scrollTo 卡 —— 目标行没渲染过就没有尺寸,滚动动画得一边
                // 跑一边现算行高,表现就是换行时一顿一顿。全部一次性布好之后,滚动只是
                // 平移已经量好的内容。
                VStack(alignment: .leading, spacing: lyricLineSpacing) {
                    // 前奏的「•••」放在第一行之前(间奏点数据见 gapMarker/gapDotsRow)。
                    if let intro = gapMarker(-1), let firstID = playback.allLines.first?.id {
                        gapDotsRow(intro, id: "\(firstID)-intro")
                    }
                    ForEach(Array(playback.allLines.enumerated()), id: \.element.id) { index, item in
                        // .equatable():没有它,**每一行**都会跟着整页 body 重算一遍。
                        //
                        // 2026-08-14 用 sample 量到的:稳定播放期间主线程有 ~22% 的时间耗在
                        // NSHostingView.layout → ViewGraphRootValueUpdater.render 里,栈里能
                        // 看到 ForEachChild.updateValue → lineView,也就是几十行全在重建。
                        // LyricsWindowView 订阅的是整个 PlaybackCoordinator(二十来个
                        // @Published),任何一个变动都会重算 body;而行视图带闭包参数
                        // (onTap/onHover),函数值永远不相等,SwiftUI 自带的结构比较救不了,
                        // 必须显式给一个只比较**值输入**的 ==。
                        LyricsLineRow(
                            item: item,
                            distance: distance(for: index),
                            // 间奏进行中"当前"是那排「•••」,唱完的行不再保持活跃态。
                            isActive: item.id == activeID && playback.currentGapIndex == nil,
                            isHovered: hoveredLineID == item.id,
                            isPlaying: playback.isPlayingNow,
                            // 只给**当前行**传真实值,其余行恒 false —— settled 每行翻转
                            // 两次,全表行都跟着比较变化的话,一次翻转就是整表行重算。
                            fillSettled: item.id == activeID && playback.currentLineFillSettled,
                            fontSize: lyricFontSize,
                            romaFontSize: romaFontSize,
                            translationFontSize: translationFontSize,
                            onArtwork: hasArtworkBackground,
                            showRomanization: playback.showRomanization,
                            showTranslation: playback.showTranslation,
                            reduceMotion: reduceMotion,
                            displayScale: displayScale,
                            onHover: { inside in
                                if inside { hoveredLineID = item.id }
                                else if hoveredLineID == item.id { hoveredLineID = nil }
                            },
                            onTap: {
                                // 减去当前歌词偏移:引擎判定"现在是哪一行"时会把 offsetMs 加到
                                // 播放位置上(见 activeLine),这里不减回去的话,跳过去之后落在
                                // 的会是隔壁行。
                                PlaybackCoordinator.shared.seek(toMs: max(0, item.timeMs - PlaybackCoordinator.shared.currentLyricsOffsetMs))
                            }
                        )
                        .equatable()
                        .id(item.id)
                        // 这一行之后有间奏 → 插「•••」(不活跃时零高度不占位,见 gapDotsRow)。
                        if let g = gapMarker(index) {
                            gapDotsRow(g, id: "\(item.id)-gap")
                        }
                    }
                }
                // 间奏点的插入/移除(以及各行随之退暗一档)跟换行滚动同一条曲线。
                // 用 value 限定形而不是 withAnimation:只在进出间奏那一刻生效,
                // 不会波及各行叶子上逐帧跑的填色 TimelineView(上午面板那个坑)。
                .animation(Self.lineTransition, value: playback.currentGapIndex)
                // 顶/底留白按**视口比例**(2026-08-21 三轮排查后的真根因):此前固定 88pt,
                // 列表顶部之上根本没有可滚空间 —— scrollTo(第一句, 0.52) 超出内容范围被
                // 钳回 offset 0,开场永远停在顶部;前两版修 id 注册/滚动时序都没用。顶部
                // 0.395h = 0.41h 锚位 − 「•••」半行,offset 0 本身就是 AM 的开场版式(dots
                // 在 41%、第一句 ~52%),不依赖任何 scrollTo;底部 0.55h 让最后一句也能锚
                // 在 41%(此前每首歌头几句/尾几句的锚定其实都被钳,几行后才收敛)。
                .padding(.top, max(88, lyricsViewportHeight * 0.395))
                .padding(.bottom, max(88, lyricsViewportHeight * 0.55))
                // 左右边距由 body 按 AM 比例现算传入(歌词文字左缘 0.515W、右缘 0.06W),
                // 单列模式退回固定 44/按比例右缘。
                .padding(.leading, leading)
                .padding(.trailing, trailing)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 自绘滚动指示条的数据源:内容在滚动坐标系里的 minY(=负的滚动量)与
                // 总高。写进 scrollMetrics 小 model,只失效指示条子视图(见声明处注释)。
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: LyricsScrollMetricsKey.self,
                            value: LyricsScrollMetricsValue(
                                offsetY: -g.frame(in: .named("lyricsScroll")).minY,
                                contentHeight: g.size.height))
                    }
                )
            }
            // 系统滚动条藏掉,换自绘常显指示条(2026-08-22 对拍:AM 的指示条**不贴窗缘**
            // ——暗轨道 6pt+白滑块 12pt,中心距窗右缘 59pt,两张参考图位置一致且常显;
            // 系统 overlay 滚动条只能贴 ScrollView 右缘,挪不动,只能自绘)。
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "lyricsScroll")
            .onPreferenceChange(LyricsScrollMetricsKey.self) { [weak scrollMetrics] v in
                scrollMetrics?.update(offsetY: v.offsetY, contentHeight: v.contentHeight)
            }
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear {
                            lyricsColumnWidth = g.size.width
                            lyricsViewportHeight = g.size.height
                        }
                        .onChange(of: g.size.width) { _, w in lyricsColumnWidth = w }
                        .onChange(of: g.size.height) { _, h in lyricsViewportHeight = h }
                }
            )
            // 上下边缘渐隐。
            //
            // 2026-08-09 用户反馈右上角那两个玻璃胶囊挡住歌词。挪走不如照 Apple Music 的
            // 做法:它的胶囊也在右上角、歌词也从底下滚过去,靠的是列表顶部有一段渐隐,
            // 文字在够到胶囊之前就已经淡掉了。
            //
            // 右上角本来也是最该放它们的位置 —— 当前行锚在从上往下 41% 处(activeLineAnchor),
            // 所以上方是**已经唱过的**行,下方是还没唱到、跟着唱时要预读的行。要挡也是挡
            // 上面那半。
            //
            // 顺带底边也渐隐:滚动列表被窗口边缘直切一刀本来就不好看。
            .mask(
                LinearGradient(
                    stops: [
                        // 顶部这一段要一直全透明到**胶囊下沿之后**才开始显现 —— 胶囊占了
                        // 内容区顶部约 7% 的高度,渐隐若从 0 就开始爬,滚到那里的文字仍有
                        // 一半不透明度,照样糊在胶囊上。
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.075),
                        .init(color: .black, location: 0.2),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
            // 指示条挂在 mask 之后 —— AM 的指示条在渐隐带里仍是全强度,不跟文字一起淡。
            .overlay(alignment: .trailing) {
                LyricsScrollIndicator(metrics: scrollMetrics, onArtwork: hasArtworkBackground)
                    .frame(width: 12)
                    // 53:滑块宽 12,右缘落在 53、中心 59 —— AM 实测中心距窗右缘 59pt。
                    .padding(.trailing, 53)
                    .allowsHitTesting(false)
            }
        }
    }

    // ---- 左列:封面 + 曲目信息 + 进度条 + 播放控制 --------------------------------

    private var playerPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 20)
            artworkCard
            // 三段间距 19/19/15(2026-08-22 第二轮对拍,用户红框"左栏坐标没对齐":
            // AM 封面底→歌名 19、歌手底→进度条 23.5(帧距≈19)、时间行→播控中心比
            // 我们短 5 —— 此前 22/14/20 逐段累积把播控行推低了 ~10pt)。
            trackInfoRow
                .padding(.top, 19)
            // 进度条子视图自持五个拖动/补间瞬态(2026-08-19 性能审计):1Hz 补间推进、
            // 拖动、悬停变粗的失效全部收敛在子树内,不再击穿整窗。
            WindowProgressSection(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                onArtwork: hasArtworkBackground,
                backgroundLayers: playback.windowBackgroundLayers)
                .padding(.top, 19)
            playbackControls
                .padding(.top, 17)
            Spacer(minLength: 20)
        }
        // 水平内边距不再在这里加:列宽=封面宽、左缘位置由 body 按 AM 比例(0.111W)
        // 传入(2026-08-21 布局对齐 AM)。
    }

    private var artworkCard: some View {
        // Color.clear 先撑出 1:1 的方形框、图片以 scaledToFill 铺进去再裁圆角——不能
        // 直接对 Image 用 scaledToFill(没有外框约束时它会按原始比例撑开布局)。
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                // 优先用高清替代:这张卡最大 460pt(Retina 下 920px),而系统 Now Playing
                // 给的封面可能只有 100×100(网易云客户端就是),放大 9 倍会明显糊。
                // highResArtworkImage 只在系统那份确实太小时才有值,见它的注释。
                if let nsImage = playback.highResArtworkImage ?? playback.artworkImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(hasArtworkBackground ? Color.white.opacity(0.1) : Color.primary.opacity(0.06))
                        Image(systemName: "music.note")
                            .font(.system(size: 44))
                            .foregroundStyle(secondaryTextColor)
                    }
                }
            }
            // 动画收在 overlay 内容上,而不是挂在整张卡片的最外层。
            //
            // 挂在最外层时,这个 0.5s 的动画作用域会覆盖卡片自身的几何——只要有别的状态在
            // 同一个更新事务里改变了布局(2026-08-05 实测坐实的那次:anchor 到达让进度条那
            // 一行插进 VStack,整个左栏跟着重排),这次布局位移就会被它一起 animate 成缓慢
            // 飘移,表现成"进度条从上面飘下来"。它要动画的本来只是"换歌时封面图交叉淡入"
            // 这一件事,不该有能力动画到版式。
            .animation(.easeInOut(duration: 0.5), value: playback.artworkData)
            // 高清替代到货/撤掉同样交叉淡入(指针比较在这里是对的:每次到货都是新解码的
            // NSImage 实例)。
            .animation(.easeInOut(duration: 0.5), value: playback.highResArtworkImage)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(hasArtworkBackground ? 0.45 : 0.2), radius: 26, y: 12)
            // 封面随播放状态缩放(2026-08-19 用户要求,仿 Apple Music 歌词页):播放满幅、
            // 暂停缩到 78%,状态一眼可辨。scaleEffect 是渲染变换、不改布局 —— 下方
            // 歌名/进度条纹丝不动;放在 clipShape+shadow 之后,阴影跟着一起缩,观感同
            // Apple Music。用缓收版 isPlayingSmoothed 而不是 isPlayingNow:切歌间隙/
            // seek 的瞬时 false 会让封面每首歌之间都抖一下,0.5s 宽限正好吸掉,而暂停
            // 到收缩的那 0.5s 延迟无感。reduceMotion 下跳变不补间 —— 缩放本身是
            // "没在播放"的功能反馈,要保留,去掉的只是过渡。
            // 0.732(2026-08-22 第二轮对拍:AM 暂停态封面 599px@2x / 满幅 0.279W=818px
            // = 0.732;此前 0.78 让暂停态封面比 AM 大 6%。只影响封面视觉大小 ——
            // 这是渲染变换,下方各行位置由满幅布局撑出,与此无关)。
            .scaleEffect(playback.isPlayingSmoothed ? 1 : 0.732, anchor: .center)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72),
                       value: playback.isPlayingSmoothed)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { artworkWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in artworkWidth = w }
                }
            )
    }

    private var trackInfoRow: some View {
        // 外层 HStack(2026-08-19 对齐 AM):文字块靠左,收藏/更多两颗圆钮贴右 ——
        // AM 歌词页就是这个排布。文字块可滚(MarqueeText),圆钮定宽不参与挤压。
        HStack(alignment: .center, spacing: 12) {
            trackInfoTexts
            Spacer(minLength: 8)
            titleSideButtons
        }
    }

    private var trackInfoTexts: some View {
        // spacing -3(2026-08-21 对拍 AM 同区截图):AM 两行视觉空隙 3pt,我们此前 9pt
        // ——两行各是 22pt 定高框(墨高 16pt,上下各余 3pt),3+spacing+3 要等于 3,
        // spacing 只能是 -3。别去缩 frame 高:MarqueeText 会把超出框的拉丁降部裁掉。
        VStack(alignment: .leading, spacing: -3) {
            // 放不下就滚,不再直接截断成 "Automatic (Remastered 20…" —— 这两行是这一栏
            // 唯一说明"现在放的是哪一版"的地方,截掉的恰好是版本后缀。
            // 显式给行高:MarqueeText 内部是 GeometryReader,纵向贪心,不定高会把整栏撑开。
            // 广告插播:歌名位写「广告中」,跟灵动岛(NotchLyricsView)和下面歌词区的空状态
            // (emptyStateSpec)用同一个判据、同一句文案。2026-08-19 用户报的就是这里 ——
            // 那两处早就处理了,只有这一行还在原样显示 Spotify 给的占位标题「—」,配上没有
            // 封面的占位图,整张卡看起来像是坏了。
            //
            // ⚠️ MarqueeText 的 id 必须用**显示串**而不是 playback.title:切进/切出广告时要
            // 重置跑马灯,用原标题的话 id 不变、滚动位置会带着上一条的进度(灵动岛那边
            // 同一个理由,见 NotchLyricsView 那段注释)。
            MarqueeText(id: displayTitle) {
                Text(displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(primaryTextColor)
            }
            .frame(height: 22)
            MarqueeText(id: displayArtistAlbum) {
                Text(displayArtistAlbum)
                    // 15.5:同一对拍量出 AM 副行墨高 28px、我们(17pt 时)31px,副行比
                    // 歌名小一号;歌名的 17pt 与 AM 完全一致(32px vs 32px)不动。
                    .font(.system(size: 15.5))
                    .foregroundStyle(secondaryTextColor)
            }
            .frame(height: 22)
        }
    }

    /// 标题右侧的 收藏(星)+ 更多(…)圆钮 —— Apple Music 歌词页同款位置与形态
    /// (2026-08-19 用户要求完全对齐:收藏从播放控制排挪上来;AM 现在的收藏就是星形,
    /// 心形是它的旧设计)。星只有 Apple Music 有(isFavorited 为 nil 不显示),
    /// 「…」始终在 —— 它装的是这扇窗自己的动作,与播放器无关。
    private var titleSideButtons: some View {
        HStack(spacing: 8) {
            if let favorited = playback.isFavorited {
                Button {
                    PlaybackCoordinator.shared.toggleFavorited()
                } label: {
                    circleIcon(favorited ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .help(L10n.t(favorited ? "取消喜欢" : "喜欢"))
            }
            // 2026-08-21 从系统 Menu 换成自绘面板(moreMenuPanel,窗级 overlay 定位),
            // 一次解决三件事:① 样式对齐 AM(深色玻璃圆角白字,系统 NSMenu 是浅色小面板,
            // 用户对照截图要求换);② 热区 —— Menu(.borderlessButton) 的实际可点范围只有
            // label 固有尺寸那一点(用户报"只有点按钮中心才有效"),普通 Button + circleIcon
            // 的 contentShape(Circle()) 整圆都是热区,跟星星一致;③ 永久摆脱 Menu 压平
            // 自定义 label 的机制(圆底/白点两轮翻车,见 docs 已知坑 11)。
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showsMoreMenu.toggle() }
            } label: {
                circleIcon("ellipsis")
            }
            .buttonStyle(.plain)
            .anchorPreference(key: MoreMenuButtonBoundsKey.self, value: .bounds) { $0 }
        }
    }

    /// 「…」的 AM 式菜单面板:深色玻璃圆角、白字、悬停行高亮(对照用户给的 AM 截图:
    /// 它的菜单是采样背景的暗玻璃,不是系统 NSMenu 的浅色小面板)。玻璃用 ultraThinMaterial
    /// 并在有封面背景时强制深色外观 —— 跟 AM 一样透出封面底色;无封面背景的普通窗口
    /// 跟随系统外观。每行点完动作前先关面板。
    /// 当前播放器是不是 Apple Music —— Apple Music 专属菜单项(资料库/减少推荐/前往
    /// 专辑·艺人)的显示条件。非 @Published,但面板每次打开都重建,取值足够新鲜。
    private var isAppleMusicPlayer: Bool {
        PlaybackCoordinator.shared.resolvedPlayerBundleID == PlaybackPlayer.appleMusic.bundleIdentifier
    }

    private var moreMenuPanel: some View {
        let playerName = PlaybackCoordinator.shared.resolvedPlayerDisplayName
        let isAM = isAppleMusicPlayer
        return VStack(alignment: .leading, spacing: 2) {
            // ---- Apple Music 目录动作(对照 AM 自己的「⋯」菜单,2026-08-22) ----
            if isAM {
                addToLibraryRow
                MoreMenuRow(
                    title: L10n.t(suggestLessApplied ? "已减少推荐" : "减少推荐"),
                    trailingSystemImage: suggestLessApplied ? "checkmark" : nil
                ) {
                    // 不关菜单:勾的出现/消失就是反馈。乐观更新,AppleScript 那头失败
                    // 也只是勾跟真实状态短暂不一致,下次开菜单会读回纠正。
                    suggestLessUserToggled = true
                    let newValue = !suggestLessApplied
                    suggestLessApplied = newValue
                    // 串行链:连点两下(减少→撤销)若各自独立 detached,执行序没保证,
                    // 可能 false 先落、true 后落,终态与 UI 相反。
                    let previous = suggestLessSerialTask
                    suggestLessSerialTask = Task.detached(priority: .userInitiated) {
                        await previous?.value
                        guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else { return }
                        MusicPlaybackController.setDisliked(newValue)
                    }
                }
                menuDivider
                MoreMenuRow(title: L10n.t("前往专辑")) {
                    closeMoreMenu()
                    openCatalogPage(album: true)
                }
                MoreMenuRow(title: L10n.t("前往艺人")) {
                    closeMoreMenu()
                    openCatalogPage(album: false)
                }
            }
            // 「在 XX 中显示」:标题随当前播放器变;Apple Music 走 reveal(在 Music 里
            // 定位选中当前曲目,2026-08-22 实测流媒体曲目可用),其它播放器没有 reveal
            // 能力,退化为激活该 App(原「在播放器中打开」的行为)。
            MoreMenuRow(title: String(format: L10n.t("在 %@ 中显示"), playerName ?? L10n.t("播放器"))) {
                closeMoreMenu()
                if isAM {
                    runAppleMusicMenuAction { MusicPlaybackController.revealCurrentTrack() }
                } else {
                    PlaybackCoordinator.shared.openResolvedPlayerApp()
                }
            }
            menuDivider
            MoreMenuRow(title: L10n.t("显示简介")) {
                closeMoreMenu()
                openInfoPanel()
            }
            if !playback.title.isEmpty {
                MoreMenuRow(title: L10n.t("搜索歌词…")) {
                    closeMoreMenu()
                    openLyricsSearch()
                }
            }
            // 歌词时间轴微调:内联控件行,点「提前/延后」**不关菜单**(校准通常要按好几
            // 下边听边对),动作/步长/显示口径与菜单栏「歌词时间轴」子菜单完全同源。
            lyricsOffsetRow
        }
        .padding(6)
        .frame(minWidth: 200, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
        .onAppear { refreshMoreMenuTrackState() }
        // 菜单开着期间换曲(自然播完/手动切):两个状态行描述的是曲目,必须跟着重刷,
        // 否则勾和「已在资料库」还挂着上一首的状态、点撤销会打在新曲上(审阅 D2)。
        .onChange(of: moreMenuTrackIdentity) { _ in refreshMoreMenuTrackState() }
    }

    /// 菜单状态行绑定的曲目身份(标题|歌手|专辑拼串,只用于变更检测)。
    private var moreMenuTrackIdentity: String {
        "\(playback.title)|\(playback.artist)|\(playback.album)"
    }

    /// 「添加到资料库」/「从资料库删除」共用一行,按 libraryAddState 呈现:不在库=添加,
    /// 已在库=删除(AM 自己的「⋯」菜单就是这么切的),添加中/删除中/已添加 不可点,
    /// 两种失败态可点重试。删除成功后回 .idle —— 行自己翻回「添加到资料库」就是反馈。
    @ViewBuilder private var addToLibraryRow: some View {
        switch libraryAddState {
        case .idle:
            MoreMenuRow(title: L10n.t("添加到资料库")) { addCurrentTrackToLibraryFromMenu() }
        case .failed:
            MoreMenuRow(title: L10n.t("添加失败"), trailingSystemImage: "arrow.clockwise") {
                addCurrentTrackToLibraryFromMenu()
            }
        case .alreadyInLibrary:
            MoreMenuRow(title: L10n.t("从资料库删除")) { removeCurrentTrackFromLibraryFromMenu() }
        case .adding:
            MoreMenuRow(title: L10n.t("添加中…"), enabled: false) {}
        case .added:
            MoreMenuRow(title: L10n.t("已添加"), trailingSystemImage: "checkmark", enabled: false) {}
        case .removing:
            MoreMenuRow(title: L10n.t("删除中…"), enabled: false) {}
        case .removeFailed:
            MoreMenuRow(title: L10n.t("删除失败"), trailingSystemImage: "arrow.clockwise") {
                removeCurrentTrackFromLibraryFromMenu()
            }
        }
    }

    /// 把 AM 两个状态行刷新到真实值(开菜单时 + 菜单开着换曲时;只读查询,不触发授权
    /// 弹窗 —— 弹窗只该出现在用户显式点动作的时候)。代际 +1 让所有在途异步结果作废。
    private func refreshMoreMenuTrackState() {
        moreMenuStateGeneration += 1
        let generation = moreMenuStateGeneration
        libraryAddState = .idle
        suggestLessApplied = false
        suggestLessUserToggled = false
        guard isAppleMusicPlayer else { return }
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: false) else { return }
            let inLibrary = MusicPlaybackController.currentTrackIsInLibrary()
            let disliked = MusicPlaybackController.currentTrackDisliked()
            await MainActor.run {
                // 换曲/重开菜单后这批结果已经是别的歌的,直接丢弃
                guard generation == moreMenuStateGeneration else { return }
                // 查询期间用户可能已点了"添加"(adding/added),别把进行中的状态盖掉
                if inLibrary == true, libraryAddState == .idle { libraryAddState = .alreadyInLibrary }
                // 同理:用户已手动切过勾,后到的旧值不许再覆盖(审阅 D1)
                if let disliked, !suggestLessUserToggled { suggestLessApplied = disliked }
            }
        }
    }

    /// 点「添加到资料库」:添加中→已添加/失败,不关菜单。成功与否**不信 duplicate 的
    /// 返回值** —— 它对"已在库静默 no-op"也报 ok(2026-08-22 实测),事后重新读回
    /// 资料库才算数;读回本身失败(nil)时才退回信命令返回值。
    private func addCurrentTrackToLibraryFromMenu() {
        libraryAddState = .adding
        let generation = moreMenuStateGeneration
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run {
                    if generation == moreMenuStateGeneration { libraryAddState = .failed }
                }
                return
            }
            let commandOK = MusicPlaybackController.addCurrentTrackToLibrary()
            let verified = MusicPlaybackController.currentTrackIsInLibrary()
            await MainActor.run {
                // 关菜单→换曲→重开 后落地的旧结局不能贴到新曲的行上(审阅 D2c)
                guard generation == moreMenuStateGeneration else { return }
                libraryAddState = (verified ?? commandOK) ? .added : .failed
            }
        }
    }

    /// 点「从资料库删除」:删除中→回 idle(行翻回「添加到资料库」即反馈)/删除失败。
    /// 与添加同款纪律:成败不信命令返回值,事后读回资料库(目标=不在库)才算数。
    private func removeCurrentTrackFromLibraryFromMenu() {
        libraryAddState = .removing
        let generation = moreMenuStateGeneration
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run {
                    if generation == moreMenuStateGeneration { libraryAddState = .removeFailed }
                }
                return
            }
            let commandOK = MusicPlaybackController.removeCurrentTrackFromLibrary()
            let verified = MusicPlaybackController.currentTrackIsInLibrary()
            await MainActor.run {
                guard generation == moreMenuStateGeneration else { return }
                let gone = verified.map { !$0 } ?? commandOK
                libraryAddState = gone ? .idle : .removeFailed
            }
        }
    }

    private var menuDivider: some View {
        Divider().overlay(Color.primary.opacity(0.12)).padding(.horizontal, 6).padding(.vertical, 2)
    }

    private func closeMoreMenu() {
        withAnimation(.easeOut(duration: 0.12)) { showsMoreMenu = false }
    }

    /// Apple Music 专属菜单动作的统一外壳:权限确认 + 后台线程执行(AppleScript 会阻塞,
    /// 不能在主线程跑)。失败静默 —— 与 toggleFavorited 的宽松约定一致,这些都不是核心
    /// 路径,权限被拒时 checkAppleMusicSafely 自己会弹一次系统授权框。
    private func runAppleMusicMenuAction(_ action: @escaping @Sendable () -> Void) {
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else { return }
            action()
        }
    }

    /// 前往专辑/前往艺人:iTunes Search API 按 歌名+歌手+系统店面 解析目录链接,经
    /// music:// scheme 让 Music.app 原生跳页(机制与踩坑见 MusicCatalogSearch 注释)。
    private func openCatalogPage(album: Bool) {
        let title = playback.title
        let artist = playback.artist
        Task.detached(priority: .userInitiated) {
            let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
            guard let item = await MusicCatalogSearch.resolve(
                title: title, artist: artist, storefront: storefront) else { return }
            let https = album ? (item.collectionViewUrl ?? item.trackViewUrl) : item.artistViewUrl
            guard let url = MusicCatalogSearch.musicSchemeURL(https) else { return }
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }

    private func openInfoPanel() {
        infoLyricsSource = nil
        withAnimation(.easeOut(duration: 0.12)) { showsInfoPanel = true }
        // 歌词来源在 enrich 缓存里,首次加载要解析整份 JSON(mtime 缓存,之后是 µs 级),
        // 放后台取,取到再补进面板。
        let artist = playback.artist, title = playback.title, album = playback.album
        Task.detached(priority: .userInitiated) {
            let info = EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)
            await MainActor.run { infoLyricsSource = info?.lyricsSource }
        }
    }

    /// 「搜索歌词…」:点击瞬间快照曲目字段、后台解析 写回 key + 当前来源,齐了再弹面板。
    /// key 用缓存里**实际命中**的那条(EnrichCacheReader.resolvedKey,含宽松匹配)——
    /// 播放器报法与缓存写法有空格/繁简出入时,写回必须落在读取路径同一条上;缓存里还
    /// 没有条目(collector 未解析)就退回 normalizedKey 新建。
    private func openLyricsSearch() {
        let artist = playback.artist, title = playback.title, album = playback.album
        let durationSecs = Double(playback.currentDurationMs ?? 0) / 1000
        Task.detached(priority: .userInitiated) {
            let key = EnrichCacheReader.resolvedKey(artist: artist, title: title, album: album)
                ?? EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
            let source = EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)?.lyricsSource
            await MainActor.run {
                lyricsSearchContext = LyricsSearchContext(
                    artist: artist, title: title, album: album,
                    key: key, currentSource: source, durationSecs: durationSecs)
            }
        }
    }

    /// 「歌词时间轴」内联行:标签 + 当前值(只显示**这首歌**的微调,不含全局基准 ——
    /// 口径同菜单栏 offsetMenuTitle 的注释)+ 重置(按需)/−/＋ 三颗小钮。
    /// 交互对齐菜单栏面板 offsetControls(2026-08-22 用户点名"和控制面板一样"):
    /// **左「−」=延后、右「＋」=提前**——那边 08-20 已经为同一个反直觉问题定过稿
    /// ("想歌词快一点应该点右边"),圆箭头 gobackward/goforward 也是那轮被换掉的
    /// (它们是 Apple 的"快退/快进 15 秒"符号,一直往"调播放进度"上带)。
    private var lyricsOffsetRow: some View {
        let trackMs = playback.trackLyricsOffsetMs
        let stepMs = AppSettings.shared.lyricsOffsetStepMs
        let stepHelp = AppSettings.formattedSeconds(ms: stepMs) + L10n.t("秒")
        return HStack(spacing: 4) {
            Text(L10n.t("歌词时间轴"))
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            if trackMs != 0 {
                Text(AppSettings.signedSeconds(ms: trackMs) + "s")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            // 「重置」按需出现,且在 ± 的**左侧**(2026-08-22 用户点名):出现/消失只向
            // 左伸缩,右侧锚定的 ± 两颗钮纹丝不动 —— 原来摆在最右,一出现就把 ± 挤走,
            // 连点「＋」的第二下会点到刚冒出来的重置上。口径同菜单栏:清的是这首歌的
            // 微调,这首没调过就不摆一个点了什么都不变的按钮。
            if trackMs != 0 {
                OffsetNudgeButton(symbol: "arrow.counterclockwise", help: L10n.t("重置")) {
                    PlaybackCoordinator.shared.resetLyricsOffset()
                }
            }
            OffsetNudgeButton(symbol: "minus", help: L10n.t("延后") + " " + stepHelp) {
                PlaybackCoordinator.shared.nudgeLyricsOffset(by: -stepMs)
            }
            OffsetNudgeButton(symbol: "plus", help: L10n.t("提前") + " " + stepHelp) {
                PlaybackCoordinator.shared.nudgeLyricsOffset(by: stepMs)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// 当前曲目有没有译文/罗马音(判据与简介面板的「歌词形态」一行同一套)。
    private var trackHasTranslation: Bool {
        playback.allLines.contains { $0.line.translation != nil }
    }
    private var trackHasRomanization: Bool {
        playback.allLines.contains { $0.line.romanization != nil }
    }

    /// 「翻译与发音」按钮外观(对拍数值见调用处注释):激活态(译文正在显示)=近白
    /// 填充圆 + 深色字形,未激活 = 顶部胶囊同款 clearGlass 玻璃圆 + 亮边。
    private var translationButtonLabel: some View {
        let active = playback.showTranslation && trackHasTranslation
        return Group {
            if active {
                Image(systemName: "translate")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .frame(width: 36, height: 36)
                    // 0.84:AM 激活态填充实测亮度 ~220/255,透着背景暖底,纯白 0.92 偏刺眼。
                    .background(Circle().fill(Color.white.opacity(0.84)))
            } else {
                Image(systemName: "translate")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(capsuleIconColor)
                    .frame(width: 36, height: 36)
                    .clearGlassCapsule(
                        rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
            }
        }
        .contentShape(Circle())
    }

    /// [歌词|队列] 双钮胶囊(2026-08-22 三批,AM 同款:71.5×35.5pt 胶囊,激活的一半
    /// 是白圆+深字形)。歌词钮=歌词栏显隐(仅双列模式显示,单列关了剩空白);队列钮=
    /// 「播放队列」面板(AppleScript 只有 Apple Music 有,其它播放器不显示)。两颗都
    /// 没有就整颗胶囊不摆。
    @ViewBuilder private func lyricsQueuePill(showPlayerPane: Bool) -> some View {
        let showsLyricsButton = showPlayerPane
        let showsQueueButton = isAppleMusicPlayer
        if showsLyricsButton || showsQueueButton {
            HStack(spacing: 2) {
                if showsLyricsButton {
                    pillSlotButton(icon: "quote.bubble.fill", active: showsLyricsPane,
                                   help: L10n.t(showsLyricsPane ? "隐藏歌词" : "显示歌词")) {
                        withAnimation(.smooth(duration: 0.35)) { showsLyricsPane.toggle() }
                    }
                }
                if showsQueueButton {
                    pillSlotButton(icon: "list.bullet", active: showsQueuePanel,
                                   help: L10n.t("待播清单")) {
                        withAnimation(.easeOut(duration: 0.12)) { showsQueuePanel.toggle() }
                        if showsQueuePanel { loadQueue() }
                    }
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 36)
            .clearGlassCapsule(
                rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
            .anchorPreference(key: QueuePillBoundsKey.self, value: .bounds) { $0 }
        }
    }

    /// 胶囊里的一格:激活=白圆底+深字形(AM 同款,填充亮度对拍同翻译钮),未激活=
    /// 浅色字形。
    private func pillSlotButton(icon: String, active: Bool, help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color.black.opacity(0.75))
                                        : AnyShapeStyle(capsuleIconColor))
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? Color.white.opacity(0.84) : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 「待播清单」面板:current playlist 从当前曲目起的一段(能力边界见
    /// MusicPlaybackController.upNextQueue 注释),行点击跳播该曲。
    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.t("待播清单"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
            if let items = queueItems {
                if items.isEmpty {
                    Text(L10n.t("无法获取待播清单"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(items, id: \.index) { item in
                                QueueRow(item: item) {
                                    Task.detached(priority: .userInitiated) {
                                        guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else { return }
                                        MusicPlaybackController.playTrackInCurrentPlaylist(index: item.index)
                                        // 跳播后当前曲变了,清单重拉(小延迟等 Music 切歌落定)
                                        try? await Task.sleep(nanoseconds: 600_000_000)
                                        await MainActor.run { loadQueue() }
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 260)
                    .frame(maxHeight: 320)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
        .padding(6)
        .frame(minWidth: 200, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
        // 面板开着时换曲(自然播完/跳播)清单跟着刷新。
        .onChange(of: playback.title) { _ in if showsQueuePanel { loadQueue() } }
    }

    private func loadQueue() {
        queueItems = nil
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run { queueItems = [] }
                return
            }
            let items = MusicPlaybackController.upNextQueue() ?? []
            await MainActor.run { queueItems = items }
        }
    }

    /// 「翻译与发音」菜单(2026-08-22,对照 AM 歌词页右下角):两行开关,开的是设置里
    /// 现成的 showTranslation/showRomanization 总开关(与设置页同一个值,别处同步生效)。
    /// 当前曲目缺某一路数据时对应行灰化不可点(AM 同款:它的「显示发音」没数据时也是
    /// 灰的);点完即关面板(AM 同款),行文案随开关状态在 显示/隐藏 之间切。
    private var translationMenuPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            MoreMenuRow(title: L10n.t(playback.showTranslation ? "隐藏翻译" : "显示翻译"),
                        enabled: trackHasTranslation) {
                withAnimation(.easeOut(duration: 0.12)) { showsTranslationMenu = false }
                AppSettings.shared.showTranslation.toggle()
            }
            MoreMenuRow(title: L10n.t(playback.showRomanization ? "隐藏发音" : "显示发音"),
                        enabled: trackHasRomanization) {
                withAnimation(.easeOut(duration: 0.12)) { showsTranslationMenu = false }
                AppSettings.shared.showRomanization.toggle()
            }
        }
        .padding(6)
        .frame(minWidth: 150, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
    }

    /// 「显示简介」面板:与「⋯」菜单同玻璃样式。行内容全部来自已有的本地状态,不发
    /// AppleScript(简介不该有可感知的等待);歌词来源一项异步补齐。
    private var trackInfoPanel: some View {
        // 歌词形态:有逐字轴的行存在 = 逐字;否则有内容 = 逐行;再否则按 纯音乐/无歌词。
        let lyricsKind: String = {
            if playback.hasLyricsContent {
                let wordSynced = playback.allLines.contains { $0.line.words != nil }
                var parts = [L10n.t(wordSynced ? "逐字歌词" : "逐行歌词")]
                if playback.allLines.contains(where: { $0.line.translation != nil }) {
                    parts.append(L10n.t("译文"))
                }
                if playback.allLines.contains(where: { $0.line.romanization != nil }) {
                    parts.append(L10n.t("罗马音"))
                }
                return parts.joined(separator: " · ")
            }
            if playback.isCurrentTrackInstrumental { return L10n.t("纯音乐") }
            return L10n.t("无歌词")
        }()
        let durationText: String? = playback.currentDurationMs.map { ms in
            let s = ms / 1000
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return VStack(alignment: .leading, spacing: 6) {
            InfoPanelRow(label: L10n.t("歌名"), value: playback.title)
            InfoPanelRow(label: L10n.t("歌手"), value: playback.artist)
            if !playback.album.isEmpty {
                InfoPanelRow(label: L10n.t("专辑"), value: playback.album)
            }
            if let durationText {
                InfoPanelRow(label: L10n.t("时长"), value: durationText)
            }
            if let player = PlaybackCoordinator.shared.resolvedPlayerDisplayName {
                InfoPanelRow(label: L10n.t("播放器"), value: player)
            }
            InfoPanelRow(label: L10n.t("歌词"), value: lyricsKind)
            if let source = infoLyricsSource, !source.isEmpty {
                InfoPanelRow(label: L10n.t("来源"), value: sourceDisplayName(source))
            }
        }
        .padding(12)
        .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
    }

    /// 音频输出面板(2026-08-21,AirPlay 键弹出):AM 同款版式——每行 设备类型图标 +
    /// 名称 + 右侧勾选,玻璃底与「⋯」菜单同一套。设备列表在面板出现时现枚举
    /// (CoreAudio 同步调用,µs 级)。
    private var outputDevicePanel: some View {
        let devices = AudioOutputDeviceManager.outputDevices()
        let current = AudioOutputDeviceManager.defaultOutputDeviceID()
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(devices, id: \.id) { device in
                OutputDeviceRow(
                    title: device.name,
                    symbol: Self.deviceSymbol(device),
                    isCurrent: device.id == current
                ) {
                    AudioOutputDeviceManager.setDefaultOutput(device.id)
                    isExternalOutput = AudioOutputDeviceManager.isExternalOutputActive()
                    withAnimation(.easeOut(duration: 0.12)) { showsOutputMenu = false }
                }
            }
        }
        .padding(6)
        .frame(minWidth: 230, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
    }

    /// 设备类型 → 行图标(AM 的输出面板每行左侧是设备形状图标)。transportType 先分大类,
    /// AirPods 系按名称再细分(蓝牙传输层区分不出 Max/Pro)。
    private static func deviceSymbol(_ device: AudioOutputDeviceManager.Device) -> String {
        let name = device.name.lowercased()
        switch device.kind {
        case .builtIn: return "laptopcomputer"
        case .airPlay: return "hifispeaker"
        case .display: return "display"
        case .bluetooth:
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            return "headphones"
        case .other: return "speaker.wave.2"
        }
    }

    private func circleIcon(_ name: String) -> some View {
        circleIconGlyph(name)
            .frame(width: 26, height: 26)
            .background(Circle().fill(circleIconFill))
            .contentShape(Circle())
    }

    /// 圆底跟字形拆开:「…」那颗是 Menu,圆底只能画在 Menu 外面(见那边注释),
    /// 但两颗按钮的圆底必须是同一个值 —— 拆成一份常量,别在两处各写一遍。
    private var circleIconFill: Color {
        hasArtworkBackground ? Color.white.opacity(0.16) : Color.primary.opacity(0.08)
    }

    private func circleIconGlyph(_ name: String) -> some View {
        Image(systemName: name)
            // 14:2026-08-21 用户对照 AM 特写要求放大 —— AM 的星形约占圆钮内 60%+,
            // 12pt 只有五成出头。圆底 26pt 与 AM 一致,不动。
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(primaryTextColor.opacity(0.9))
    }

    // Apple Music 同款"歌手 — 专辑"一行(em dash),专辑缺失时只显示歌手。
    private var artistAlbumText: String {
        playback.album.isEmpty ? playback.artist : "\(playback.artist) — \(playback.album)"
    }

    /// 广告插播时歌名位显示的文案。判据 isCurrentTrackAdBreak 由 LocalPlaybackSource 给
    /// (字段启发式 + 同曲棘轮 + AppleScript `spotify url` 权威分类,见那边注释)。
    private var displayTitle: String {
        playback.isCurrentTrackAdBreak ? L10n.t("广告中") : playback.title
    }

    /// 广告插播时第二行**留空**,不展示广告物料的歌手/专辑名(用户 2026-08-19 拍板的口径,
    /// 跟灵动岛一致)。这不是多余的判断:广告有时会带全 artist/album 字段,不显式清掉的话
    /// 第二行会冒出广告主的名字。
    private var displayArtistAlbum: String {
        playback.isCurrentTrackAdBreak ? "" : artistAlbumText
    }


    // 控制排的尺寸全部从封面边长算出来,再夹进一个合理区间 —— 封面随窗口缩放,按钮
    // 写死尺寸就会在窄窗口下溢出被裁、在宽窗口下小得跟封面不成比例(2026-08-09 用户反馈)。
    // 夹值的上下界是按"最窄能用"和"再大就傻了"定的,不是等比无限放大。
    private var controlScale: CGFloat { artworkWidth > 0 ? artworkWidth : 300 }
    private func ctrl(_ ratio: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(hi, max(lo, controlScale * ratio))
    }

    private var playbackControls: some View {
        // 布局对照 AM(2026-08-21 用户红框标注):五键**不是等间距**——随机贴列左缘、
        // 循环贴右缘(AM 里 shuffle 中心离进度条左缘仅 ~13pt),主三键按原间距居中成组。
        // 图标档位 2026-08-22 第二轮对拍(用户红框:我们全线偏大):AM 上/下一首字形
        // 64px@2x、播放 52px 高、随机/循环 38px 宽 —— 换算成字号比例 上下一首 0.060、
        // 播放 0.079(帧 0.10)、随机/循环 0.043(此前 0.075/0.105/0.062,播放大 15%、
        // 随机循环大 30%)。
        HStack(spacing: 0) {
            shuffleButton
            Spacer(minLength: 12)
            HStack(spacing: ctrl(0.116, 18, 48)) {
            Button {
                MusicPlaybackController.previousTrack()
            } label: {
                Image(systemName: "backward.fill").font(.system(size: ctrl(0.060, 13, 25)))
            }
            .help(L10n.t("上一首"))
            Button {
                // 走 coordinator 的乐观回声版,不直接发命令:封面缩放/图标点击即动,
                // 不等 0.5~1s 的轮询回读(见 userTogglePlayPause 注释)。
                PlaybackCoordinator.shared.userTogglePlayPause()
            } label: {
                // 图标跟观感层 isPlayingSmoothed 走(不是 isPlayingNow 真值):点击瞬间
                // 翻转,还顺带吸掉切歌间隙真值抖 false 时图标闪一下的毛病。
                Image(systemName: playback.isPlayingSmoothed ? "pause.fill" : "play.fill")
                    .font(.system(size: ctrl(0.079, 17, 33)))
                    // 播放/暂停两个图标宽度不同,固定住避免两侧按钮跟着跳动
                    .frame(width: ctrl(0.10, 22, 38))
            }
            .help(L10n.t("播放/暂停"))
            Button {
                MusicPlaybackController.nextTrack()
            } label: {
                Image(systemName: "forward.fill").font(.system(size: ctrl(0.060, 13, 25)))
            }
            .help(L10n.t("下一首"))
            }
            Spacer(minLength: 12)
            repeatButton
        }
        // AM 式点按反馈:按下快缩、松手弹回(2026-08-21 用户要求)。作用于整排五颗。
        .buttonStyle(TransportButtonStyle(reduceMotion: reduceMotion))
        .foregroundStyle(primaryTextColor)
        .frame(maxWidth: .infinity)
    }

    /// 置顶 / 全屏 / 回到当前播放。
    ///
    /// 这三个原来是 .toolbar 里的 ToolbarItem。2026-08-09 搬出来的理由:工具栏的玻璃是
    /// 系统给的 .regular 磨砂档,我改不了它的材质,于是它永远是块不透明浅灰,跟旁边用
    /// .clear 的音量胶囊放在一起对比强烈。搬成浮层之后两组用同一档材质、同一套描边,
    /// 而且都能真的采样到背后的模糊封面。
    ///
    /// 顺带跟 Apple Music 更像了:它的窗口控件也是浮在内容上的胶囊,不是标题栏工具栏。
    private func windowActionsCapsule() -> some View {
        // 尺寸跟音量胶囊同档(2026-08-21 第三轮:图标对齐音量喇叭的 17pt/24 占位),
        // 两颗胶囊必须等高。「回到当前播放」按钮已删——换行时 onChange(currentLineIndex)
        // 本来就会自动滚回当前行,按钮冗余(用户拍板移除)。
        // 14/18/12(2026-08-22 对拍 AM 左上 X/画中画胶囊:总宽 145px@2x=72.5pt,
        // 图标间隔 ~17.5、内衬 ~12.5;此前 16/24/14 总宽 92pt 偏宽)。
        HStack(spacing: 14) {
            Button {
                windowController.toggleAlwaysOnTop()
            } label: {
                Image(systemName: windowController.isAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 17))
                    .frame(width: 18)
            }
            // 2026-08-02 补上——置顶/伪全屏这两个状态是"只在这次打开期间有效",不持久化
            // (见 LyricsWindowController 顶部注释),但按钮本身没有任何提示说明,习惯把它
            // 固定置顶的用户每次重开窗口都要重新点一次,容易被当成 bug。
            .help(
                (windowController.isAlwaysOnTop ? L10n.t("取消置顶") : L10n.t("置于最顶层"))
                    + " · " + L10n.t("这个状态只在本次打开这扇窗口期间有效，下次重新打开会恢复默认"))
            Button {
                windowController.toggle(reduceMotion: reduceMotion)
            } label: {
                Image(
                    systemName: windowController.isFullScreenActive
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .font(.system(size: 17))
                .frame(width: 18)
            }
            .help(L10n.t(windowController.isFullScreenActive ? "退出全屏" : "进入全屏"))
        }
        .buttonStyle(.plain)
        // 图标跟着背景走:.clear 玻璃是透明的,背后是深色的模糊封面时 .secondary 会暗到
        // 快看不清 —— Apple Music 那两个胶囊上的图标也是白色系。
        .foregroundStyle(capsuleIconColor)
        // 内容高钉死到跟音量胶囊一致(那边最高的是 22pt 滑杆),两颗胶囊必须严格等高。
        .frame(height: 22)
        .padding(.horizontal, 12)
        // 7:与音量胶囊同高 36(2026-08-22 对拍 AM 胶囊高 71px@2x),和红绿灯同心
        // (见 overlay 注释)。
        .padding(.vertical, 7)
        .clearGlassCapsule(
            rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
    }


    /// 随机(最左)/ 循环(最右)—— 按 Apple Music 歌词页的排布拆成两颗独立按钮
    /// (2026-08-19 用户要求完全对齐 AM;此前是一颗三态循环切换的「播放模式」钮 +
    /// 最右一颗心,收藏挪去了标题旁,见 titleSideButtons)。
    ///
    /// 底层仍是三态 playbackMode,两颗**互斥**:点亮随机=shuffle、点亮循环=repeatOne、
    /// 都不亮=list。AM 里随机和循环可以同时开,但脚本接口只有三态 —— 宁可少一个组合,
    /// 也不摆一个落不了地的开关。读不到模式(非 AM/Spotify、没权限)时不显示;定宽占位
    /// 保住播放键居中(两侧异步读出,不占位按钮排会在窗口打开后错开一瞬)。
    private var shuffleButton: some View {
        modeToggleButton(icon: "shuffle",
                         active: playback.playbackMode == .shuffle,
                         shown: playback.playbackMode != nil,
                         label: L10n.t("随机播放")) {
            PlaybackCoordinator.shared.setPlaybackMode(playback.playbackMode == .shuffle ? .list : .shuffle)
        }
    }

    /// 循环键三态(2026-08-21 对齐 AM):关 → 列表循环(亮 repeat) → 单曲循环(亮
    /// repeat.1) → 关。此前只有 关↔单曲 两态,而且 Music.app 的 song repeat=all 被解析
    /// 塌缩成「列表」 —— 用户开着整张循环,这颗键却是灰的,也没法从 UI 点出这一档。
    /// Spotify 够不到(repeating 布尔且读不回),这颗整个不显示、只占位。
    private var repeatButton: some View {
        let mode = playback.playbackMode
        return modeToggleButton(
            icon: mode == .repeatOne ? "repeat.1" : "repeat",
            active: mode == .repeatOne || mode == .repeatAll,
            shown: mode != nil && PlaybackCoordinator.shared.playbackModeSupportsRepeatOne,
            label: L10n.t("循环播放")
        ) {
            let next: MusicPlaybackController.MusicPlaybackMode
            switch mode {
            case .repeatAll: next = .repeatOne
            case .repeatOne: next = .list
            default: next = .repeatAll
            }
            PlaybackCoordinator.shared.setPlaybackMode(next)
        }
    }

    /// 点亮态:AM 同款「亮图标 + 一圈淡胶囊底」;熄灭态半透明。
    private func modeToggleButton(icon: String, active: Bool, shown: Bool, label: String,
                                  action: @escaping () -> Void) -> some View {
        Group {
            if shown {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(.system(size: ctrl(0.043, 11, 18)))
                        .opacity(active ? 1 : 0.55)
                        // 3(2026-08-22 对拍:随机贴列左缘/循环贴列右缘,此前 6pt 内衬
                        // 把两颗字形各往内推了 6px@2x,shuffle cx 362 vs AM 352)。
                        .padding(.horizontal, 3)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                active
                                    ? (hasArtworkBackground
                                        ? Color.white.opacity(0.22) : Color.primary.opacity(0.12))
                                    : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .help(label)
            }
        }
        // 定宽=字号+8(2026-08-22 对拍:这个占位框才是随机/循环字形横向落点的真正
        // 旋钮 —— 字形在框内居中,AM 随机字形中心离列左缘 13pt,框宽 ≈26 才对得上;
        // 旧公式 0.062+14=37 把两颗各往内推了 5px@2x)。
        .frame(width: ctrl(0.043, 11, 18) + 8)
    }

    // ---- 颜色:有封面背景时全窗白色系,没有时退回系统色(浅色外观可读性) ------------

    private var primaryTextColor: Color { hasArtworkBackground ? .white : .primary }
    /// 浮在内容上的那两个玻璃胶囊里的图标颜色。
    private var capsuleIconColor: Color {
        hasArtworkBackground ? .white.opacity(0.9) : .primary.opacity(0.75)
    }
    /// 副行/次级文字:AM 式 vibrancy 染色(带背景色调的亮化色),不是半透明白。
    /// 档位常数从太阳之子截图反解:s≈0.47×背景饱和、v0.85。见 amVibrantColor
    /// (亮封面下走最小对比度自适应,同时间行)。
    private var secondaryTextColor: Color {
        guard hasArtworkBackground else { return .secondary }
        return amVibrantColor(layers: playback.windowBackgroundLayers,
                              satScale: 0.5, satCap: 0.45, brightness: 0.85,
                              fallback: .white.opacity(0.6),
                              minContrastToBackground: 0.25)
    }

    // 距当前行的行数差——按下标算,不按内容(副歌重复句内容相同但下标不同,详见
    // LyricsSyncEngine.activeLineIndex 的注释)。nil(还没播到第一句)统一按"远"处理。
    /// 视觉上真正有区别的最大行距。
    ///
    /// 不透明度 `max(0.35, 0.55 - d*0.05)` 到 d=4 就压到下限 0.35,模糊 `min(d×6%字号, 15%字号)`
    /// 到 d≈3.64 就封顶 —— 也就是说 d≥4 的行,**画出来一模一样**。
    ///
    /// 夹在这里的收益不是省几次乘法,而是让远处那几十行的 distance **不再变化**:
    /// LyricsLineRow 是 Equatable 的,输入没变就整行跳过重算,也不会去跑那条
    /// `.animation(value: distance)`。换行时真正需要重画/重跑动画的从"整表"缩到当前行
    /// 上下各 4 行。这一步是像素级等价的,不是拿观感换性能。
    private static let maxVisualDistance = 4

    private func distance(for index: Int) -> Int? {
        guard let activeIdx = playback.currentLineIndex else { return nil }
        // 间奏进行中整体退一档:此刻的"当前"是那排「•••」,唱完的那一行不该再保持
        // 全亮 —— Apple Music 间奏时上一句同样是退暗的。
        let gapPenalty = playback.currentGapIndex != nil ? 1 : 0
        return min(abs(index - activeIdx) + gapPenalty, Self.maxVisualDistance)
    }

    // ---- 间奏「•••」(2026-08-19,Apple Music 歌词页同款) --------------------------

    /// 间奏点按 index 建好的字典 —— gapMarker 被列表每行调一次,线性扫是 O(N×M);
    /// markers 只在换歌时变,这里作为计算属性每次 body 建一次 O(M)(M 通常个位数),
    /// 仍远优于 N×M。
    private var gapMarkersByIndex: [Int: LyricsGapMarker] {
        Dictionary(uniqueKeysWithValues: playback.lyricsGapMarkers.map { ($0.index, $0) })
    }

    private func gapMarker(_ index: Int) -> LyricsGapMarker? {
        gapMarkersByIndex[index]
    }

    /// 间奏活跃时滚动定位用的行 id(跟列表里 gapDotsRow 的 .id 拼法保持一致)。
    private func gapRowID(_ index: Int) -> String? {
        if index == -1 { return playback.allLines.first.map { "\($0.id)-intro" } }
        guard playback.allLines.indices.contains(index) else { return nil }
        return "\(playback.allLines[index].id)-gap"
    }

    /// 三颗呼吸圆点。不活跃时**整行不渲染**(零高度零开销,VStack 也不会为它多出一段
    /// 行距);间奏进行中在原位展开,三颗点随间奏进度依次点亮 —— 活跃判定在数据层
    /// (LocalPlaybackSource 20Hz 发布 currentGapIndex,进出间奏才变),同一时刻至多
    /// 一行在跑 TimelineView(0.5s 一档,足够点亮的节奏感,填色那种帧率在这里是浪费)。
    @ViewBuilder
    private func gapDotsRow(_ marker: LyricsGapMarker, id: String) -> some View {
        if playback.currentGapIndex == marker.index {
            // .animation(minimumInterval:paused:) 替代 .periodic(2026-08-19):节奏一样是
            // 0.5s 一档,但暂停时把表停掉 —— 暂停在间奏中时圆点亮度本来就定格(闭包里的
            // pausedPositionMs 兜底),表继续走只是白跑。
            TimelineView(.animation(minimumInterval: 0.5, paused: !playback.isPlayingNow)) { context in
                // 跟逐字填色同一套时间基准:外推位置 + 当前歌词偏移(间奏窗口是歌词
                // 原始时间轴,见 LyricsGapMarker 注释)。暂停时 anchor 为 nil,退回
                // 冻结位置,点就停在当下的亮度上。
                let pos = (playback.anchor?.extrapolatedPositionMs()
                    ?? playback.pausedPositionMs ?? marker.startMs)
                    + PlaybackCoordinator.shared.currentLyricsOffsetMs
                let span = max(1, marker.endMs - marker.startMs)
                let progress = min(1, max(0, Double(pos - marker.startMs) / Double(span)))
                HStack(spacing: lyricFontSize * 0.3) {
                    ForEach(0 ..< 3, id: \.self) { i in
                        Circle()
                            .fill(primaryTextColor)
                            .frame(width: lyricFontSize * 0.32, height: lyricFontSize * 0.32)
                            // 第 i 颗在间奏进行到 i/3 之后点亮,亮度平滑爬升。
                            .opacity(0.22 + 0.78 * min(1, max(0, progress * 3 - Double(i))))
                    }
                }
                // 亮度变化按 0.5s 步进到货,补一段柔和过渡就是"呼吸"。
                .animation(.easeInOut(duration: 0.45), value: Int(progress * 24))
            }
            .frame(height: lyricFontSize * 0.5)
            .id(id)
            .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: .leading)))
        }
    }

    // Apple Music 歌词页的景深:当前行完全清晰,其余行统一压到低不透明度、并随距离
    // 加重高斯模糊——非当前行之间的不透明度差异很小(0.50 → 0.35 缓降),远近感主要靠
    // 模糊量区分。nil(还没播到第一句)整页轻虚化,保持可读。

    // 距离越远、高斯模糊越重——1.1pt/行、封顶 4pt。2026-08-04 第一版按 1.6pt/行封顶
    // 6pt,用户对照 AM 同曲截图反馈"太糊了,后面几行都失真了"——AM 最远的可见行仍然
    // 认得出字形(模糊半径约为字号的 12~14%,6pt/28pt 是 21%),照它调轻。SwiftUI 的
    // .blur() 本身就是可动画属性,复用调用点已有的 .animation(value: distance)。

    private var hasArtworkBackground: Bool { playback.artworkData != nil }

    // Apple Music 歌词页最标志性的元素:当前封面模糊放大铺满、压一层半透明黑提升文字
    // 可读性。data 解码失败(损坏的图片数据,理论上不该发生,fetchArtwork() 已经在
    // Data(base64Encoded:) 这一步失败就返回 nil 了,这里只是再兜一层)时同样什么都不画,
    // 退回系统默认背景,不留一个突兀的纯色占位块。
    //
    // 故意不加 .ignoresSafeArea()——加了之后这层背景会一路铺到标题栏底下(实测坐实:
    // 2026-08-01 用户反馈"歌词窗口"标题栏文字"有时候会不明显"),系统标题栏文字颜色是
    // 按"标题栏本该是不透明系统材质"这个假设算的,被我们自己这层深色模糊图顶到底下之后
    // 撞色、对比度不够。去掉这个修饰符,背景就只填满 ScrollView 自己的内容区域(标题栏
    // 下方),不需要额外裁剪——ScrollView 的 frame 本来就已经是"标题栏以下的可用区域",
    // 内部 LazyVStack 的上下 60pt padding 不影响 ScrollView 自身、也就不影响这层
    // .background() 铺的范围。
    @ViewBuilder
    private var artworkBackground: some View {
        // AM 式动画背景(2026-08-20 第四轮重做,反向工程依据 Priva28 gist + AMLL,烘焙
        // 与参数见 PlaybackCoordinator.bakeWindowBackgroundLayers):暗底静态铺满,3 份
        // 取自封面不同区域的羽化光斑以 lighten(变亮)混合、绕各自的偏心锚点慢速旋转
        // (75/−100/130s 一圈,组合姿态几乎不重复)——这就是 AM 歌词页背景"缓慢流动的
        // 光斑"的来源。图层全部预烘焙,视图层只有 GPU 变换动画,无合成期滤镜。
        //
        // 遮罩只留 0.15 的可读性保底:主要压暗已在暗底烘焙(EV −1.9)里完成。
        if let layers = playback.windowBackgroundLayers {
            WindowAnimatedBackground(layers: layers)
                // 换歌重建整棵子树:动画从新一首的初始姿态干净重启,onAppear 重新点火。
                .id(ObjectIdentifier(layers))
                .overlay(Color.black.opacity(0.15))
                .clipped()
                // 换歌/高清替代到货都会产出新的图层实例(Equatable 按 === 实现),一条
                // 过渡覆盖原来 artworkData 字节比较 + highRes 指针比较两条。
                .animation(.easeInOut(duration: 0.5), value: playback.windowBackgroundLayers)
        }
    }

    // 完全没有歌词内容 vs "这首歌还没解析完、collector 后台正在搜"共用同一个
    // allLines.isEmpty,含义不一样,判断条件跟 LyricsOverlayView.mainLine 里的同一个
    // 分支保持一致(playback.hasLyricsContent 的注释详见 LocalPlaybackSource)。文案复用
    // 已有的本地化字符串,不新造。
    // 广告/纯音乐两个分支必须排在"还在搜索中"前面,理由跟 LyricsOverlayView.mainLine
    // 一致,见 playback.isCurrentTrackAdBreak / isCurrentTrackInstrumental 定义处的注释。
    /// 停播欢迎态用哪个播放器(2026-08-22 用户指正"不一定是 Apple Music"):设置里选了
    /// 具体播放器就用它;「自动识别」用停播前最后认下来的那家(LocalPlaybackSource 落在
    /// UserDefaults,停播时快照已清空、只有它还记得);全新用户兜底 Apple Music。
    private var idlePlayer: PlaybackPlayer {
        let configured = PlaybackPlayerPreference.current
        if configured != .auto { return configured }
        if let bid = UserDefaults.standard.string(forKey: "np:lastPlayerBundleID"),
           let p = PlaybackPlayer.allCases.first(where: { $0 != .auto && $0.bundleIdentifier == bid }) {
            return p
        }
        return .appleMusic
    }

    /// 停播欢迎态(2026-08-22 用户选型 B+D):居中 hero(呼吸光晕音符 + 文案 + 按钮),
    /// 替换整套没有内容的双列骨架。按钮按播放器能力给:AM/Spotify 有 AppleScript 能真
    /// 「继续播放」(AM=三段式,见 resumePlayback 注释;Spotify 自带恢复上下文),失败
    /// 兜底激活 App——点击永远有可见反应;QQ/网易云/酷狗没有 AppleScript,只给「打开」。
    /// 呼吸(D):图标+光晕 2.6s 往复缩放,reduceMotion 下静止。
    private var idleWelcomeView: some View {
        let player = idlePlayer
        let playerName = player.displayName
        let canResume = player == .appleMusic || player == .spotify
        return VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color.accentColor.opacity(0.12), .clear],
                        center: .center, startRadius: 8, endRadius: 90))
                    .frame(width: 180, height: 180)
                Image(systemName: "music.note")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .scaleEffect(idleBreath ? 1.05 : 0.96)
            .opacity(idleBreath ? 1 : 0.8)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                value: idleBreath)
            .onAppear { idleBreath = true }
            .onDisappear { idleBreath = false }
            Text(L10n.t("没有在播放"))
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 4)
            Text(String(format: L10n.t("在 %@ 播放任意歌曲，歌词会自动出现"), playerName))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            HStack(spacing: 10) {
                if canResume {
                    Button {
                        resumeFromIdle(player: player)
                    } label: {
                        Label(L10n.t("继续播放"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                // 没有「继续播放」可给的播放器,「打开」升格为主按钮。
                if canResume {
                    Button {
                        openIdlePlayerApp(player)
                    } label: {
                        Text(String(format: L10n.t("打开 %@"), playerName))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button {
                        openIdlePlayerApp(player)
                    } label: {
                        Text(String(format: L10n.t("打开 %@"), playerName))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 「继续播放」:AM 走三段式(裸 play→上次那首→都不行),Spotify 自带恢复;任何
    /// 失败都兜底把播放器 App 带到前台 —— 点了必须有可见反应(2026-08-22 用户实测
    /// "点了没反应":裸 play 对空队列静默 no-op)。
    private func resumeFromIdle(player: PlaybackPlayer) {
        let lastTitle = UserDefaults.standard.string(forKey: "np:lastTrackTitle")
        let lastArtist = UserDefaults.standard.string(forKey: "np:lastTrackArtist")
        Task.detached(priority: .userInitiated) {
            var ok = false
            switch player {
            case .appleMusic:
                if await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                    ok = MusicPlaybackController.resumePlayback(
                        lastTitle: lastTitle, lastArtist: lastArtist)
                }
            case .spotify:
                ok = MusicPlaybackController.resumeSpotifyPlayback()
            default:
                ok = false
            }
            if !ok {
                await MainActor.run { openIdlePlayerApp(player) }
            }
        }
    }

    private func openIdlePlayerApp(_ player: PlaybackPlayer) {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: player.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private var emptyStateSpec: (icon: String, text: String) {
        // 什么都没在放(播放列表放完/播放器退出)—— 这时候写"无歌词"是答非所问:不是这首歌
        // 没词,是压根没有"这首歌"。判据用曲名为空:停播时 LocalPlaybackSource 会把曲目信息
        // 一并清掉(见 clearIfWasPlaying),播放中/暂停中它一定非空。
        if playback.title.isEmpty { return ("music.note", L10n.t("没有在播放")) }
        if playback.isCurrentTrackAdBreak { return ("megaphone", L10n.t("广告中")) }
        if playback.isCurrentTrackInstrumental { return ("waveform", L10n.t("纯音乐")) }
        // 搜完确实没有 → 别再说"搜索中",理由见 playback.currentTrackHasNoLyrics。
        if playback.currentTrackHasNoLyrics { return ("text.badge.xmark", L10n.t("暂无歌词")) }
        // 断网:collector 什么都查不到,而"全空不写缓存"的守卫让 hasLyricsContent 永远
        // 是 false —— 不插这一档的话界面会一直显示"搜索歌词中…",而那句话在断网时永远
        // 不会有下文。排在"暂无歌词"之后:那是明确结论,比"此刻没网"更有信息量。
        if playback.collectorNetworkDown && !playback.hasLyricsContent {
            return ("wifi.slash", L10n.t("网络连接失败"))
        }
        if playback.isPlayingNow && !playback.hasLyricsContent { return ("magnifyingglass", L10n.t("搜索歌词中…")) }
        return ("text.quote", L10n.t("无歌词"))
    }

    @ViewBuilder
    private var emptyState: some View {
        let spec = emptyStateSpec
        if hasArtworkBackground {
            // 封面背景上 ContentUnavailableView 的系统默认文字颜色没法覆盖(深色模糊图
            // 上的浅色外观深色文字基本看不清),换成自绘的白色版本,条件跟系统版共用
            // emptyStateSpec。
            VStack(spacing: 12) {
                Image(systemName: spec.icon).font(.system(size: 40))
                Text(spec.text).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(spec.text, systemImage: spec.icon)
        }
    }

    /// 这一行是不是把读音逐词标进正文了(标了就别再单独渲染一整行罗马音)。
}

// 一行歌词。
//
// 2026-08-14 从 LyricsWindowView 的几个 @ViewBuilder 方法里拆出来变成独立的 View struct,
// 起因是用户反馈"换行滚动时有卡顿/掉帧感"。用 sample 量到的现场:稳定播放期间主线程约
// 22% 的时间耗在 NSHostingView.layout → ViewGraphRootValueUpdater.render,栈里能看到
// ForEachChild.updateValue → lineView —— 也就是几十行歌词在跟着整页反复重建。
//
// 为什么原来会全表重建:LyricsWindowView 用 @ObservedObject 订阅了整个 PlaybackCoordinator
// (二十来个 @Published:封面、音量、播放模式、收藏状态、暂停位置…),其中任何一个变动都
// 会让整个 body 重算;方法形式的行视图没有独立身份,只能跟着一起重建。拆成 struct +
// Equatable 之后,只有输入真的变了的那几行才会重算 —— 换行时变的是当前行和它的邻居。
//
// Equatable 必须**手写**:行视图带 onTap/onHover 两个闭包参数,函数值永远不相等,
// SwiftUI 自带的结构化比较对带闭包的视图直接失效,只比较值输入才有意义。
private struct LyricsLineRow: View, Equatable {
    let item: LyricsWindowLine
    let distance: Int?
    let isActive: Bool
    let isHovered: Bool
    // 逐字填色的 TimelineView 用它决定要不要暂停。传值而不是在这里再订阅一次
    // PlaybackCoordinator —— 那样等于把刚拆掉的全量订阅又加回来。
    let isPlaying: Bool
    /// 当前行的填色是否已定格(行尾/间奏停表):传值给 KaraokeLineText 停掉粗时钟 +
    /// isLive 判定 —— 非当前行恒 false(见调用点注释)。
    let fillSettled: Bool
    let fontSize: CGFloat
    let romaFontSize: CGFloat
    let translationFontSize: CGFloat
    let onArtwork: Bool
    let showRomanization: Bool
    let showTranslation: Bool
    let reduceMotion: Bool
    let displayScale: CGFloat
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    static func == (a: LyricsLineRow, b: LyricsLineRow) -> Bool {
        // item 只比 id:id 里带了曲目标识 + 行下标(见 LyricsWindowLine),同 id 必然同内容。
        a.item.id == b.item.id
            && a.distance == b.distance
            && a.isActive == b.isActive
            && a.isHovered == b.isHovered
            && a.isPlaying == b.isPlaying
            && a.fillSettled == b.fillSettled
            && a.fontSize == b.fontSize
            && a.romaFontSize == b.romaFontSize
            && a.translationFontSize == b.translationFontSize
            && a.onArtwork == b.onArtwork
            && a.showRomanization == b.showRomanization
            && a.showTranslation == b.showTranslation
            && a.reduceMotion == b.reduceMotion
            && a.displayScale == b.displayScale
    }

    private var secondaryTextColor: Color { onArtwork ? .white.opacity(0.6) : .secondary }

    /// 对唱歌词的左右分栏(见 LyricDuet)。
    ///
    /// nil = 这首歌没有演唱者标记(绝大多数歌),按这个窗口原本的排版走 —— 左对齐。
    private var side: LyricDuet.Side { item.line.side ?? .leading }

    private var alignment: Alignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var textAlignment: TextAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var rowAlignment: WrapLayout.RowAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var usesPerWordRomanization: Bool {
        isActive && showRomanization && item.line.wordGroups?.isEmpty == false
            && item.line.words != nil
    }

    // Apple Music 歌词页的景深(2026-08-21 第五版:不再目测,直接从 AM 截图**拟合**)。
    // 方法:AM 整窗截图里同一句「无敌铁金刚」出现在 d0/d1/d2/d3 多个距离上,同文行的
    // 墨量总和(∑亮度-背景)是高斯模糊的不变量,比值就是不透明度;特写图里再拿 d0 行
    // 人工加 σ 扫描去逐像素拟合各距离行,解出每档的 σ。
    // 量出:α d1≈0.42、d2≈0.41、d3≈0.28、d4≈0.23 —— 近两档几乎不衰减,d3 起掉得快。
    private var lineOpacity: Double {
        guard let d = distance else { return 0.45 }
        if d == 0 { return 1 }
        return max(0.22, 0.42 - 0.10 * Double(max(0, d - 2)))
    }

    // 模糊量:同一次拟合解出 σ(d1)=3.0px、σ(d2)=4.5px、σ(d4)=7.5px —— 严格线性
    // σ = 1.5×(d+1)px,除以字号 101px 得 **0.0148×(d+1) 字号**(d1≈3%、d4≈7.4%,
    // distance 本身封顶 4,不需要另设上限)。历史:08-04 固定 1.6pt/行"远行失真"→
    // 1.1pt/行"不够糊"→ 08-21 按特写目测 9%/22%"太糊"→ 回收 6%/15%"还是有点糊"
    // ——前四版都在猜,这版是从截图解出来的,d1 比 6% 那版整整轻一半。
    // SwiftUI 的 .blur() 本身是可动画属性,复用调用点已有的 .animation(value: distance)。
    private var lineBlur: CGFloat {
        guard let d = distance else { return fontSize * 0.03 }
        if d == 0 { return 0 }
        return fontSize * 0.0148 * CGFloat(d + 1)
    }

    var body: some View {
        VStack(alignment: alignment.horizontal, spacing: 6) {
            mainText
            // 罗马音在**下面**,跟 Apple Music 一致(原来在上面)。当前行如果分得出词组,
            // 读音已经逐词标进 mainText 里了,这里就不再重复一整行。
            if showRomanization, !usesPerWordRomanization, let roma = item.line.romanization {
                Text(roma)
                    .font(.system(size: romaFontSize, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
            }
            if showTranslation, let tr = item.line.translation {
                Text(tr)
                    .font(.system(size: translationFontSize, weight: .semibold))
                    .foregroundStyle(secondaryTextColor)
            }
        }
        // Apple Music 歌词是左对齐排版,2026-08-04 从居中改过来。对唱歌词按演唱者分左右
        // (2026-08-14),不带标记的歌 side 恒为 .leading,跟原来完全一致。
        .multilineTextAlignment(textAlignment)
        .frame(maxWidth: .infinity, alignment: alignment)
        // 动画屏障(2026-08-21 七轮,60fps 逐帧胶片实测抓包):下面那两条行级
        // .animation(value:) 本意只给 opacity/blur 的景深过渡用,但它们的作用域是整棵
        // 子树 —— 行激活瞬间词的填色取值从"定格全亮"跳到"按时间≈0",这个 diff 被
        // lineTransition 捕获,渐变 stop 被从 1 插值回 0,表现为"下一行前几个字先全亮、
        // 亮暗边界 ~100ms 从右往左回撤"。字级叶子上的 .transaction{animation=nil} 实测
        // **拦不住**这条路径;同类型的 .animation(nil, value:) 屏障(内层覆盖外层是
        // 文档化行为)插在内容与 opacity/blur 之间才切实有效:内容子树对这两个 value 的
        // 变化拿到 nil 动画,opacity/blur 在屏障之上、照常吃外层动画。
        .animation(nil, value: distance)
        .animation(nil, value: isHovered)
        .opacity(isHovered ? 1 : lineOpacity)
        // 激活行的不透明度**瞬时到位**(2026-08-22 八轮,60fps 亮度轨迹实测):行落位瞬间
        // 填色已瞬时切到"未唱暗色",若不透明度还在 0.42→1.0 慢慢爬,两通道相乘出一个
        // "先暗一拍(129→120)再用 0.45s 爬回 139"的凹陷 —— 用户反馈"新行像被重新加载
        // 一遍,闪烁一下"就是它。激活行直接落在终态(129→139 的一次性小步升,无凹陷);
        // 退场行/其他行仍走 lineTransition(1→0.42 的退暗要动画,否则旧行"啪"地熄灭)。
        // 模糊不在此列 —— 它由更外层的 .animation 驱动,激活行仍有 0.45s 的"对焦"过程。
        .animation(isActive ? nil : LyricsWindowView.lineTransition, value: distance)
        // 模糊跟缩放一样受 reduceMotion 影响时直接关掉——虽然模糊本身不是"位移类"动效,
        // 但它是这套"聚焦感"视觉效果里跟缩放同一批的非必要装饰,减少动态效果的用户大概率
        // 也不想要这层模糊,统一用同一个开关关掉,不单独加一个新设置项。
        // 鼠标悬在哪一行,哪一行就恢复清晰 —— 跟 Apple Music 一样,让你能看清要跳去的是
        // 哪一句,再决定点不点。
        .blur(radius: (reduceMotion || isHovered) ? 0 : lineBlur)
        // 这里原来给当前行挂了 .scaleEffect(1.02)。删掉了 —— .scaleEffect 是**渲染后**
        // 的仿射变换:文字先按原字号栅格化,再整体拉大 1.02 倍,是个非整数倍重采样。在
        // Retina 上看不太出来,在 1x 外接屏上直接把**最该看清的那一行**糊掉:2026-08-10
        // 实测同一张截图里,当前行的字形边缘平均过渡宽度 1.48px,而同窗口里没做任何变换
        // 的左栏歌名只有 1.25px、歌手行 1.14px。
        //
        // 2% 的放大本来就几乎看不出来,而"当前行"的强调其实是另外三样在扛:满不透明度、
        // 零模糊、逐字填色。为了一个看不见的收益去糊掉正文,不划算。
        .animation(LyricsWindowView.lineTransition, value: distance)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        // 命中区要盖满整行(含左右空白),否则只有文字上才点得到
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var mainText: some View {
        // Apple Music 歌词页所有行同一字号同一字重(远近靠透明度+模糊区分,不靠字号),
        // 当前行的逐字填色也是"同色 35% → 全强度"的同色系渐变,不引入另一个强调色——
        // 2026-08-04 按截图一比一对照改过来(旧版是当前行 accentColor 30pt/其余 24pt)。
        // 有封面背景时这个"同色"是白色;没有封面时退回系统 .primary(白字在浅色外观的
        // 默认窗口背景上不可读,正确性优先),远近区分交给 lineOpacity。
        let base: Color = onArtwork ? .white : .primary
        // 有逐字时间轴的行**不论活跃与否都走 KaraokeLineText**(2026-08-21):原来非活跃走
        // 单个 Text、激活瞬间整棵子树换成 WrapLayout+逐词结构,SwiftUI 对结构替换只能淡出
        // 淡入,叠上行级 blur/opacity 动画,观感就是用户报的"新行有一个虚化重新构建的
        // 过程"(纯行级歌词两个状态都是 Text,没这问题——正好解释"有时候")。统一结构后
        // 只有参数在变,无替换。非活跃行:词强制全填色(视觉=原来的全色 Text)、粗/细时钟
        // 全停、字不上浮 —— 静态成本只是"多几个 Text + 一次 WrapLayout 布局",没有逐帧
        // 失效(性能红线见 KaraokeLineText.body 的实测记录)。
        // 例外:逐词读音(groups)仍只在活跃时挂 —— 读音出现本来就是内容变化,且非活跃行
        // 渲染读音占位会撑高行高、改变整列行距。
        if let words = item.line.words {
            KaraokeLineText(
                words: words,
                groups: usesPerWordRomanization ? item.line.wordGroups : nil,
                base: base,
                isActive: isActive,
                isPlaying: isPlaying,
                fillSettled: fillSettled,
                fontSize: fontSize,
                romaFontSize: romaFontSize,
                reduceMotion: reduceMotion,
                displayScale: displayScale,
                rowAlignment: rowAlignment
            )
        } else {
            Text(item.line.plainText ?? "")
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(base)
        }
    }
}

// 当前行的逐字填色。
//
// ---- 驱动方式的定稿(2026-08-21 五轮,别再翻烧饼)----
//
// 逐帧重算(TimelineView 叶子时钟)是**实测后的终点**,不是没试过更"先进"的:同日第三轮
// 性能架构曾整体改成排程式(fillFraction 对时间线性 → 一次性排 .linear 显式动画交给
// 渲染管线插值,LyricsX/AMLL 同架构),CPU 上确实是零逐帧代码 —— 但 SCK 逐帧探针实测
// **macOS 只以 ~20Hz 提交这些动画**(系统对长时程慢动画自动降档,无 API 干预;对照组
// 悬浮歌词的 TimelineView 30Hz 准点投递),20Hz×14px 的边缘步进正是用户报的"卡顿感"。
// TimelineView 的频率受控、实测准点,所以回到逐帧重算,档位开到面板满刷新率
// (WordKaraokeGradient.windowRefreshInterval = 60Hz)。
//
// 逐帧的开销结构此前两轮已经修到位(实测记录保留在此,别退回去):
// * 08-14:TimelineView 包在 WrapLayout 外面=每帧重排版(主线程 91% 忙,67% 在
//   LayoutEngineBox.sizeThatFits)→ 时钟下沉到**字级叶子**,布局每帧不再被推翻。
// * 08-17:一行十几个相位不齐的满速字时钟并集盖满每个显示帧(85.8% 忙)→ 行级 4Hz
//   粗时钟只判"哪个字正在扫",只有那个字保留满速细时钟。
// * 08-20:WrapLayout contentKey 缓存(粗 tick 不再整行重测宽)、Palette 纯色渐变
//   跨帧复用(静态词不再每 tick 重建 AnyShapeStyle)。
// 排程式那轮真正留下的三个修复也都保留:①激活瞬间取值跳变被行级 .animation(value:)
// 插值成"全亮再褪色"→ 叶子挂 .transaction 禁掉外来动画;②forceFilled 用 fraction=1.0
// 走不到纯色快路径、右缘 band 段被淡到半强度 → 定格值 1+band;③上浮参数(幅度 0.05em、
// 时长 min(词长,1000ms) —— 两头的取舍见 riseWindowMs 注释)。
private struct KaraokeLineText: View {
    let words: [SyncedLyricWord]
    let groups: [SyncedLyricWordGroup]?
    let base: Color
    /// 是不是当前行(2026-08-21 统一结构):非活跃行也渲染这套 WrapLayout+逐词结构
    /// (消灭激活瞬间的整树替换),但词强制全填色、粗/细时钟全停、字不上浮。
    let isActive: Bool
    let isPlaying: Bool
    /// 整行填色已定格(所有词/组越过过渡带)。true 时粗时钟停表、isLive 全灭,行尾/间奏/
    /// 曲末不再重排版。⚠️ 必须同时喂给 isLive:只停粗时钟的话 isLive 会冻结在 true,最后
    /// 一个字的细时钟反而在整段间奏/outro 永动。
    let fillSettled: Bool
    let fontSize: CGFloat
    let romaFontSize: CGFloat
    let reduceMotion: Bool
    let displayScale: CGFloat
    /// 对唱分栏:换行时行内也要跟着靠左/靠右/居中,否则右侧那句折下来的第二行会飘回左边。
    var rowAlignment: WrapLayout.RowAlignment = .leading

    /// WrapLayout 的内容身份(2026-08-20 性能审计):行文本/字号/罗马音形态都没变时,
    /// 布局回合跳过整行 CoreText 重新测宽(见 WrapLayout.Cache 守卫注释)。这里的
    /// 字体是 .system(size:weight:.bold) 固定族,fontSize/romaFontSize 就是完整字体身份;
    /// 文本身份用 words 拼接(低频:只在行内容/字号变化时走到)。
    private var lineLayoutKey: AnyHashable {
        AnyHashable(WindowLineKey(
            text: words.map(\.text).joined(),
            hasGroups: groups?.isEmpty == false,
            fontSize: fontSize,
            romaFontSize: romaFontSize))
    }

    private struct WindowLineKey: Hashable {
        let text: String
        let hasGroups: Bool
        let fontSize: CGFloat
        let romaFontSize: CGFloat
    }

    var body: some View {
        // 行级 4Hz 粗时钟:只判断每个字"此刻是不是正在被扫"(isLive)+ 给静态字一个时间
        // 基准(staticDate);满速细时钟只挂在正在扫的那个字上(见 KaraokeWordText)。
        // 粗时钟让 WrapLayout 每秒过 4 次布局回合,但 contentKey 缓存保证不整行重测宽。
        TimelineView(.animation(minimumInterval: Self.coarseInterval,
                                paused: !isActive || !isPlaying || fillSettled)) { coarse in
            lineContent(coarseDate: coarse.date, coarseMs: currentMs(at: coarse.date))
        }
    }

    /// 粗时钟档位。0.25 秒足够判断"这个字是不是快到了/刚过去"。
    private static let coarseInterval: Double = 0.25

    /// 跟 KaraokeWordText 里用同一条公式(含歌词时间轴校准),否则"当前词判定"和"填色
    /// 进度"的时间基准会对不上。?? pausedPositionMs:暂停时 anchor 是 nil、位置冻结在
    /// pausedPositionMs,退到 ?? 0 会把整行画回"未唱"态(2026-08-19 修过的暂停 bug)。
    private func currentMs(at date: Date) -> Int {
        let coordinator = PlaybackCoordinator.shared
        return (coordinator.anchor?.extrapolatedPositionMs(now: date)
            ?? coordinator.pausedPositionMs ?? 0)
            + coordinator.currentLyricsOffsetMs
    }

    /// 这个字此刻要不要保留满速时钟。窗口两头各放宽一档粗时钟 + 一点余量:不放宽会在
    /// 字的开头漏掉最初几帧("啪"地跳出一截填色);末尾把上浮窗口也算进去 —— 填色满了
    /// 之后字还在往上浮。
    private func isLive(_ w: SyncedLyricWord, atMs ms: Int) -> Bool {
        guard isActive, !fillSettled else { return false }
        let margin = Int(Self.coarseInterval * 1000) + 80
        let end = w.startMs + max(1, w.durationMs) + Int(KaraokeWordText.riseWindowMs(for: w))
        return ms >= w.startMs - margin && ms <= end + margin
    }

    @ViewBuilder
    private func lineContent(coarseDate: Date, coarseMs: Int) -> some View {
        WrapLayout(rowAlignment: rowAlignment, contentKey: lineLayoutKey) {
            if let groups, !groups.isEmpty {
                // 一组一列:上面这一组的字各自逐字填色,下面标这一组的读音,列宽取
                // 两者更宽的那个 —— 主文字的间距因此被读音撑开,跟 Apple 一样。
                ForEach(groups) { g in
                    // 组内左对齐:罗马音跟这一组的**第一个字**对齐,不是居中。
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(g.words.indices, id: \.self) { i in
                                KaraokeWordText(word: g.words[i], base: base, isPlaying: isPlaying,
                                                isLive: isLive(g.words[i], atMs: coarseMs),
                                                staticDate: coarseDate,
                                                fontSize: fontSize, reduceMotion: reduceMotion,
                                                displayScale: displayScale,
                                                lineSettled: fillSettled)
                            }
                        }
                        if let roma = g.romanization {
                            // 读音按**整组**的进度填,不跟着组里单个字跳:拿整组的起止时间
                            // 造一个"伪字",复用同一套填色。
                            let romaWord = SyncedLyricWord(
                                text: roma, startMs: g.startMs,
                                durationMs: max(1, g.endMs - g.startMs))
                            KaraokeWordText(
                                word: romaWord,
                                base: base.opacity(0.75), isPlaying: isPlaying,
                                isLive: isLive(romaWord, atMs: coarseMs),
                                staticDate: coarseDate,
                                fontSize: romaFontSize, weight: .medium,
                                reduceMotion: reduceMotion, displayScale: displayScale,
                                rises: false, // 读音不跟着抬,只有正文的字会浮起来
                                lineSettled: fillSettled
                            )
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 2)
                        }
                    }
                }
            } else {
                ForEach(words.indices, id: \.self) { i in
                    KaraokeWordText(word: words[i], base: base, isPlaying: isPlaying,
                                    isLive: isLive(words[i], atMs: coarseMs), staticDate: coarseDate,
                                    fontSize: fontSize, reduceMotion: reduceMotion,
                                    displayScale: displayScale,
                                    // 非活跃行定格全填色:视觉上就是全色 Text,
                                    // 外层 lineOpacity 负责压暗。
                                    forceFilled: !isActive,
                                    lineSettled: fillSettled)
                }
            }
        }
        .font(.system(size: fontSize, weight: .bold))
    }
}

/// 一个逐字填色的字(或一整组的罗马音)。自己挂 TimelineView,自己按帧算填色和上浮量。
///
/// 拆到这一层的理由见 KaraokeLineText 顶部实测记录:逐帧失效必须落在叶子上,落在容器上
/// 会把整行的自定义 Layout 每帧推翻重算。填色几何与悬浮歌词逐像素同款(渐变中心=人声
/// 位置、软边=词宽的 ±band,用户点名的观感基准),唯一差别是刷新档位(60Hz vs 30Hz,
/// 见 WordKaraokeGradient.windowRefreshInterval 的取舍记录)。
private struct KaraokeWordText: View {
    let word: SyncedLyricWord
    let base: Color
    let isPlaying: Bool
    /// 这个字此刻是不是"正在被扫过"。false 就把满速时钟停掉 —— 还没唱到的字填充恒为 0、
    /// 唱过的恒为 1,都是静态画面,没有任何理由每秒醒 60 次(见 KaraokeLineText.isLive)。
    let isLive: Bool
    /// 时钟停着的时候拿它当时间基准。用**粗时钟**的时刻而不是被冻住的 context.date:
    /// 后者会停在这个字最后一次活跃的瞬间,一旦停早了,填色就会永远卡在 0.97 这种位置上。
    let staticDate: Date
    let fontSize: CGFloat
    var weight: Font.Weight = .bold
    let reduceMotion: Bool
    let displayScale: CGFloat
    var rises: Bool = true
    /// 非活跃行(结构统一,见已知坑 #11):不按时间算填色,恒为全色;不上浮。时钟由上游的
    /// isLive=false 停掉,这里只管画面。
    var forceFilled: Bool = false
    /// 整行已定格(2026-08-22 九轮):停表后 staticDate 冻结在最后一次粗 tick(最多陈旧
    /// 250ms),若恰好早于末字的完成时刻,末字的渐变会被算回"没填完"的位置 —— 用户实测
    /// "行尾最后一两个字染完又退去染色","有时候"=停表与粗 tick 的相位差。定格的语义
    /// 本来就是"所有词都已填满、所有字都已浮定"(settled 阈值≥每个词的完成点、rise 窗口
    /// min(词长,1000) 必然早于 1.08×词长的定格点),所以 settled 时直接渲染终态,不再
    /// 依赖任何时间基准。与 forceFilled 的区别:行还是当前行,浮起要**保持**不落回。
    var lineSettled: Bool = false

    /// 定格全填色的 fraction:必须取 1+band 让软边**整个**越过右缘走进纯色快路径 ——
    /// 取 1.0 的话 left=1−band<1,右缘 band 段会被淡到半强度(排程式那轮修掉的隐藏 bug)。
    private static let settledFraction = 1 + KaraokeFill.wordEdgeSoftenBand

    /// 抬升时长 = min(词长, 1000ms)(2026-08-21 七轮定稿,两头都有用户实测背书):
    /// * 上界 1000ms 防长词亚像素颤抖 —— 3s 的字按词长爬完整词=每帧 ~0.05 物理像素,
    ///   字形抗锯齿被持续重采样,肉眼上下颤(六轮反馈);到顶后钉在整数设备像素上不动。
    /// * 跟词长对齐防"人都走了还在浮" —— 上浮不得晚于这个字自己的染色结束,短词随
    ///   染色一起利落收尾(七轮反馈"染色结束=上浮结束,不要都过去了还在慢慢上浮")。
    /// KaraokeLineText.isLive 用它决定细时钟要活到多晚,所以是 internal。
    static func riseWindowMs(for w: SyncedLyricWord) -> Double {
        min(max(1, Double(w.durationMs)), 1000)
    }

    /// 上浮幅度 0.05em(用户定稿),收到整数个设备像素防 1x 屏重采样发糊。
    private var riseAmplitude: CGFloat {
        let scale = max(1, displayScale)
        return (fontSize * 0.05 * scale).rounded() / scale
    }

    /// 上浮:sin(p·π/2) 平滑升到 1、终点斜率 0,抬起后**保持**,行退场落回(「点头式」被
    /// 用户否掉过)。
    private func rise(atMs currentMs: Int) -> CGFloat {
        guard rises, !reduceMotion else { return 0 }
        let elapsed = Double(currentMs - word.startMs)
        guard elapsed > 0 else { return 0 } // 还没唱到这个字
        let p = min(1, elapsed / Self.riseWindowMs(for: word))
        return -sin(p * .pi / 2) * riseAmplitude
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: WordKaraokeGradient.windowRefreshInterval,
                                paused: !isPlaying || !isLive)) { context in
            // 直接读单例而不是 @ObservedObject:这个闭包本来就由 TimelineView 按帧驱动,
            // 订阅反而会把协调器上二十来个 @Published 的每次变动都变成额外重算。
            let coordinator = PlaybackCoordinator.shared
            // 时钟停着时用粗时钟的时刻,理由见 staticDate。
            let date = isLive ? context.date : staticDate
            // +currentLyricsOffsetMs:同"当前词判定"的时间基准,不加会填到一半卡住;
            // ?? pausedPositionMs:暂停基准兜底(2026-08-19)。
            let currentMs = (coordinator.anchor?.extrapolatedPositionMs(now: date)
                ?? coordinator.pausedPositionMs ?? 0)
                + coordinator.currentLyricsOffsetMs
            let fraction = (forceFilled || lineSettled)
                ? Self.settledFraction
                : WordKaraokeGradient.fillFraction(for: word, atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand
            // 定格后浮起保持满幅(定格时每个字必然已过自己的 rise 窗口,见 lineSettled 注释)。
            let lift: CGFloat = forceFilled ? 0
                : (lineSettled ? ((rises && !reduceMotion) ? -riseAmplitude : 0)
                               : rise(atMs: currentMs))
            Text(word.text)
                .font(.system(size: fontSize, weight: weight))
                // Palette:纯色两端(没唱到/唱过了)复用跨帧同一实例,只有真在过渡带里的
                // 词才现算渐变 —— 否则静态词每个粗 tick 都被迫重走样式失效。
                .foregroundStyle(WordKaraokeGradient.palette(fg: base)
                    .style(left: fraction - band, right: fraction + band))
                // .offset 是渲染期位移,不参与布局 —— 字抬起来不会把整行的排版推歪。
                .offset(y: lift)
                // 禁掉一切外来动画事务:填色/上浮由本时钟逐帧给真值,任何插值都是错的。
                // 行激活瞬间 forceFilled→按时间 的取值跳变会落在行级
                // .animation(value: distance) 的作用域里,渐变 stop 被从 1 插值回 0,
                // 就是"下一行先全部亮一下、再从头逐字"那个 bug 的机制;未唱到的字时钟
                // 停着,没有下一帧掰正,褪色动画会播完整。
                .transaction { t in
                    if t.animation != nil { t.animation = nil }
                }
        }
    }
}

// MARK: - 进度条(2026-08-19 性能审计拆出:瞬态自持,失效不击穿整窗)

/// AM 式 vibrancy 染色(2026-08-21,太阳之子截图逐通道反解):左栏次级元素=**背景色相
/// 的亮化低饱和版**,不是半透明白 —— 纯白 alpha 的三通道等效透明度应相等,实测副行是
/// r0.74/g0.58/b0.49(暖倾斜)。h/s 来自烘焙背景的 CIAreaAverage(见
/// WindowBackgroundLayers.tintHue),brightness/satScale 按元素档位:副行 0.5×/v0.85、
/// 时间行 0.62×/v0.68、进度已播段 0.5×/v0.92。背景层还没到(刚开窗)回退半透明白。
/// minContrastToBackground(2026-08-22,用户实测金色亮封面上时间行"都看不清"):
/// 固定 brightness 档是从**暗封面**截图反解的,背景自己亮起来(bgV≈0.7)时标签亮度
/// 撞上背景直接隐形。传入后保证与背景的亮度差 ≥ 该值,方向是**提亮**——同帧对拍
/// AM 亮橙背景上歌手行 S0.27 V1.00、时间行 S0.39 V0.94、播控近白,**全部比背景亮**
/// (第一版压暗成 V0.42 深棕,被用户抓出"字颜色没统一":AM 的统一感=次级元素清一色
/// 淡奶油,对比度靠 文字淡 vs 背景艳 的饱和度差,前提是背景够饱和——背景灰化 bug
/// 修掉后此前提成立)。唯一压暗分支:背景又亮又淡(近白封面,bgV>0.75 且 S<0.5),
/// 淡奶油提不出对比,退成 bgV−0.32 的深色(AM 白封面同款)。只给文字类调用用 ——
/// 进度条已播段是控件,别传。
private func amVibrantColor(layers: WindowBackgroundLayers?, satScale: Double, satCap: Double,
                            brightness: Double, fallback: Color,
                            minContrastToBackground: Double? = nil) -> Color {
    guard let layers, layers.tintSaturation > 0.01 else { return fallback }
    var v = brightness
    if let minC = minContrastToBackground {
        let bgV = layers.tintBrightness
        if bgV > 0, v - bgV < minC {
            if bgV <= 0.75 || layers.tintSaturation >= 0.5 {
                v = min(0.97, max(bgV + minC, brightness))
            } else {
                v = max(0.22, bgV - 0.32)
            }
        }
    }
    return Color(hue: layers.tintHue,
                 saturation: min(satCap, layers.tintSaturation * satScale),
                 brightness: v)
}

private struct WindowProgressSection: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    let onArtwork: Bool
    let backgroundLayers: WindowBackgroundLayers?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 正在拖进度条时手指所在的比例(0~1);没在拖就是 nil。拖动期间进度条和时间文字都显示
    // 这个值而不是真实播放位置,松手才发 seek —— 见 progressBar 里的注释。
    // 用 @GestureState:手势被取消时会自动复位,不会像 @State 那样永久卡住(理由同上)。
    @GestureState private var scrubbingFraction: Double?
    // 进度条那一块的实际宽度,拖拽时换算比例用(见 progressBar 里为什么不用 GeometryReader 包)。
    @State private var scrubWidth: CGFloat = 0
    /// 进度条真正画出来的进度。跟 fraction 分开存,是为了**自己决定什么时候补间**:
    /// 每秒一档的推进要补间(否则一跳一跳),而冷启动第一次赋值、以及窗口缩放引起的
    /// 宽度变化不能补间 —— 那正是"进度条从别的位置平移过来"的来源。
    @State private var shownFraction: Double = 0
    @State private var progressPrimed = false
    /// 进度条轨道粗细:恒定 6(2026-08-21 用户反馈把"悬停变粗"砍了 —— frame(height:)
    /// 参与布局,悬停那一下会把上面整块内容顶起来;AM 的进度条常态就是粗的,不做
    /// 粗细反馈,悬停反馈只剩系统光标)。
    private let scrubberHeight: CGFloat = 6

    @ViewBuilder
    var body: some View {
        if let anchor {
            // 播放中:1 秒一档从锚点外推——4pt 高的进度条上,秒级步进配 .linear 补间在
            // 视觉上已经连续,不值得为它再挂一个逐帧刷新的 TimelineView(.animation)。
            TimelineView(.periodic(from: .now, by: 1)) { context in
                progressBar(
                    positionMs: anchor.extrapolatedPositionMs(now: context.date),
                    durationMs: anchor.durationMs,
                    // 播放中每过一墙钟秒,播放头前进多少毫秒(倍速播放时不是 1000)。
                    // 补间要用它把终点提前一秒,见 progressBar 里 onChange 的注释。
                    advancePerSecondMs: 1000 * anchor.rate)
            }
        } else if let paused = pausedPositionMs, let duration = durationMs, duration > 0 {
            // 暂停:显示冻结位置(anchor 此时是 nil,见 pausedPositionMs 定义处注释)。
            progressBar(positionMs: paused, durationMs: duration)
        } else {
            // 什么位置数据都还没有(刚打开窗口、poller 还没读到第一份快照)时**占住同样的
            // 空间**,而不是整块不渲染。
            //
            // 2026-08-05 用户反馈"首次进入时进度条会从上面飘下来到对应位置"的根因就在这里:
            // 原来这个分支什么都不渲染,等 anchor 到达才把这一行插进 playerPane 的 VStack,
            // 于是整个左栏的 Spacer 重新分配、上下内容各自位移十几 pt;而这块布局变化恰好
            // 落在 artworkCard 那条 0.5s easeInOut 动画的同一个更新事务里,被它一起animate
            // 成了"缓慢飘移"。占住位之后布局从第一帧起就是终态,插入这件事本身不再发生。
            //
            // .hidden() 保留布局、不参与命中测试;durationMs 传 0,progressBar 里的手势有
            // `durationMs > 0` 守卫,不会误发 seek。
            progressBar(positionMs: 0, durationMs: 0).hidden()
        }
    }

    private func progressBar(positionMs: Int, durationMs: Int, advancePerSecondMs: Double = 0) -> some View {
        // 拖动期间显示手指按住的位置,而不是真实播放位置——松手才真的发 seek。拖动中
        // 播放器还在按旧位置走,若这里显示真实位置,进度条会在手指底下往回跳。
        let shownMs = scrubbingFraction.map { Int($0 * Double(durationMs)) } ?? positionMs
        let fraction = durationMs > 0 ? min(1, max(0, Double(shownMs) / Double(durationMs))) : 0
        return VStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(primaryTextColor.opacity(0.25))
                    // 已播段:AM 式染色(太阳之子实测 s≈0.5×背景饱和、v0.92),不是白 0.85。
                    Capsule().fill(onArtwork
                        ? amVibrantColor(layers: backgroundLayers, satScale: 0.5, satCap: 0.4,
                                         brightness: 0.92, fallback: .white.opacity(0.85))
                        : primaryTextColor.opacity(0.85))
                        // 进度用 shownFraction(自己驱动)而不是 fraction,补间由下面的
                        // onChange 显式决定 —— 挂 .animation(_:value: fraction) 那一版有两个
                        // 症状:冷启动时 fraction 从 0 一步跳到真实进度,被补成"滑过去";
                        // 缩放窗口时 g.size.width 变了,而这次宽度变化恰好落在每秒一次的
                        // 动画事务里,于是整条也跟着平移。现在这两种情况都直接赋值、不补间。
                        //
                        // ⚠️ 2026-08-17:这里原来是 `.frame(width: g.size.width * shownFraction)`,
                        // 也就是让**布局属性**跟着每秒一次的线性补间走 —— 补间是按显示帧
                        // 插值的,于是每一帧都要把整个 NSHostingView 重新布局一次。实测
                        // (歌词窗口开着、正在播放)这一条就吃掉了主线程的一大半:
                        //   双列(有这条进度条)61.4% 忙 / 单列(窄窗,播放器面板整块不显示)9.4% 忙
                        // 改成整条满宽 + 只让**渲染变换**随进度走:变换不参与布局,补间
                        // 只落在变换矩阵上。
                        //
                        // ⚠️ 但那一版的变换用的是 `.scaleEffect(x: f)`,还附了一句"视觉上
                        // 等价:圆头被压成 x 半径 (h/2)·f 的椭圆,这么矮的条上看不出来"——
                        // **那句是错的,而且就是用户报的 bug**(2026-08-22「进度条有时候
                        // 变成方的,不是弧形」)。它只在 f 接近 1 时成立:横向缩放把圆头一起
                        // 压扁,f 越小越扁,小到一定程度圆头直接没了、变成直角。离线渲染
                        // 逐列量覆盖高度坐实(条高 48px,数字=该列有色行数,取右端 12 列):
                        //   f=1.00 → 42,40,38,36,36,34,30,28,26,22,16,10   正常圆头
                        //   f=0.50 → 48,48,46,46,44,42,40,38,34,30,24,14   已明显压扁
                        //   f=0.02 → 48,48,48,48,48,48,48,48,48,48,48,48   纯矩形
                        // 一首 3 分钟的歌播到 0:04 就是 f≈0.02,所以现象是"进度靠前时方、
                        // 靠后才圆",不是随机 —— 别按"偶发"去找竞态。
                        //
                        // 现在改成 offset + clipShape:满宽胶囊整条**向左移出** (1-f)·w,
                        // 外面再按固定的满宽胶囊裁一次。两端的圆各有出处 —— 左端来自
                        // clipShape 那个胶囊的左圆头(裁剪框不随 f 动、只有内容在动),右端
                        // 来自填充自己的右圆头(被 offset 平移到 f·w 处)。圆头形状因此跟 f
                        // 完全无关:同一份离线测量里 f 从 0.02 到 1.00,右端剖面恒为
                        // 42,40,38,36,36,34,30,28,26,22,16,10。
                        //
                        // ⚠️ 性能约束没有放松,别为了圆头改回去:随 f 变的只有 `.offset`,
                        // 跟 scaleEffect 一样是不参与布局的渲染变换,上面那 61.4% 的教训
                        // 依然成立 —— **绝不能**把宽度写回 `.frame(width: w * f)`。
                        //
                        // 移出量算在 Core 里(ProgressFillGeometry,含下限/退化窗口的夹值
                        // 和两轮返工的完整来由),这里只负责把它接到 offset 上 —— 分层理由
                        // 见 AGENTS.md「XxxxView.swift 里不放几何/数学」,而这条填充正是
                        // 那条纪律的活教材:两轮 bug 全出在几何判断上。
                        .frame(width: g.size.width, height: scrubberHeight)
                        .offset(x: -ProgressFillGeometry.leadingOffset(
                            containerWidth: g.size.width, fraction: shownFraction))
                        .clipShape(Capsule())
                }
            }
            .frame(height: scrubberHeight)
            .onAppear {
                shownFraction = fraction
                // 第一次渲染之后才允许补间:开窗那一下的赋值必须是瞬时的。
                DispatchQueue.main.async { progressPrimed = true }
            }
            .onChange(of: fraction) { _, f in
                let smooth = progressPrimed && !reduceMotion && scrubbingFraction == nil
                if smooth {
                    // 正常推进:1 秒一档,配 .linear 补间在视觉上就是连续的。
                    //
                    // ⚠️ 补间的终点必须是**一秒之后**的位置,不是刚算出来的这个当前位置。
                    // 2026-08-10 用户报"进度比 Apple Music 慢不到 1 秒",根因就在这里:
                    // 原来是 `shownFraction = f`,即用一秒时间从上一档"走到"刚拿到的这一档,
                    // 于是走到位的那一刻这个值已经旧了整整一秒 —— 稳态下 t+s 时刻条上显示的
                    // 是 pos(t-1+s),**恒定落后 1 秒**。这是把插值当外推用的经典错误:两档
                    // 采样之间做线性插值,画出来的永远是过去。
                    //
                    // 改成终点取 pos(t+1) 之后,[t, t+1] 这一秒里线性走过去,每一刻显示的
                    // 正好是 pos(t+s) —— 也就是当下的真实位置。
                    //
                    // 数据源本身不是问题:同一时刻实测 media-control 的 elapsedTimeNow 跟
                    // Apple Music 播放头只差 36~50ms,位置伺服的校正门槛也只有 0.15s。
                    let step = durationMs > 0 ? advancePerSecondMs / Double(durationMs) : 0
                    withAnimation(.linear(duration: 1)) { shownFraction = min(1, max(0, f + step)) }
                } else {
                    // 冷启动 / 拖动中 / 关了动效:直接到位。拖动时补间会让进度条追着
                    // 手指慢慢挪,手感发黏。
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { shownFraction = f }
                }
            }
            // 命中区**只覆盖进度条这一行**,不含下面的时间行。原来把手势挂在整个 VStack 上,
            // 于是点右侧那个"剩余时间"文字就等于 seek 到 ~95%(把这首歌跳过去)、点左侧已播
            // 时间则从头重播——那两个看起来是纯静态标签的文字,点一下就毁掉当前播放。
            //
            // 上下各撑 9pt 让 4pt 的条好按,再用**等量负 padding** 把布局高度抵消回去:
            // 这块 AM 风格的间距是逐像素对着截图调过的,不能因为要加命中区就长高 18pt。
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .padding(.vertical, -9)
            // 量宽度的 background 和手势必须挂在**同一个**视图上,location.x 与 scrubWidth
            // 才在同一个坐标系里。不把它包进 GeometryReader:那个是贪心的,会撑满可用空间。
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { scrubWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in scrubWidth = w }
                }
            )
            .gesture(
                // minimumDistance: 0 让"点一下就跳"也能用,不用真的拖开一段距离。
                //
                // 用 @GestureState 而不是 @State 存拖动位置:SwiftUI 在手势被**取消**时
                // (拖动过程中宿主子树被移出层级,比如这首歌播完/被暂停,进度条所在的条件
                // 分支整块被摘掉)不会调 onEnded,用 @State 的话 scrubbingFraction 会永久
                // 停在最后一次 onChanged 的值,进度条和两个时间文字从此冻结、补间动画也被
                // 永久关掉,只有再完整拖一次才自愈。@GestureState 在手势结束或取消时自动
                // 复位成初始值,天然没有这个问题。
                DragGesture(minimumDistance: 0)
                    .updating($scrubbingFraction) { value, state, _ in
                        guard durationMs > 0, scrubWidth > 0 else { return }
                        // 只有这次手势的第一帧 state 才是 nil,拿它当"刚按下"的边沿信号
                        // 给一次触觉;放 onChanged 里会每帧都震。
                        if state == nil {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment, performanceTime: .now)
                        }
                        state = min(1, max(0, value.location.x / scrubWidth))
                    }
                    .onEnded { value in
                        guard durationMs > 0, scrubWidth > 0 else { return }
                        let f = min(1, max(0, value.location.x / scrubWidth))
                        PlaybackCoordinator.shared.seek(toMs: Int(f * Double(durationMs)))
                    }
            )
            HStack {
                Text(Self.formatTime(ms: shownMs))
                Spacer()
                // 右侧显示**总时长**而不是剩余时间(2026-08-21 布局对齐 AM:它的歌词页
                // 时间行是「0:20 ··· 3:12」)。
                Text(Self.formatTime(ms: durationMs))
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(secondaryTextColor)
        }
    }

    private static func formatTime(ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        return "\(totalSeconds / 60):" + String(format: "%02d", totalSeconds % 60)
    }

    private var primaryTextColor: Color { onArtwork ? .white : .primary }
    /// 时间行/无损标签:AM 式染色(实测 s≈0.62×背景饱和、v0.68),比副行更暗更饱和。
    private var secondaryTextColor: Color {
        guard onArtwork else { return .secondary }
        return amVibrantColor(layers: backgroundLayers,
                              satScale: 0.62, satCap: 0.5, brightness: 0.68,
                              fallback: .white.opacity(0.6),
                              minContrastToBackground: 0.25)
    }
}

// MARK: - 音量胶囊(2026-08-19 性能审计拆出:soundVolume 只在这里订阅)

private struct WindowVolumeCapsule: View {
    let onArtwork: Bool
    /// 输出面板开关与"外接输出中"(键染红)状态都归窗口层管(面板是窗级 overlay,
    /// 见 LyricsWindowView.outputDevicePanel),这里只负责按钮本身。
    @Binding var showsOutputMenu: Bool
    let isExternalOutput: Bool
    @StateObject private var model = Model()

    /// 只订 soundVolume 的微型代理 —— 拖音量时的乐观发布(≈每帧一次)只失效这个
    /// 小胶囊,整窗 body 不再陪跑(WindowPlayback 故意不转发它)。
    @MainActor
    private final class Model: ObservableObject {
        @Published private(set) var soundVolume: Int?
        private var sub: AnyCancellable?
        init() {
            sub = PlaybackCoordinator.shared.$soundVolume.removeDuplicates()
                .sink { [weak self] in self?.soundVolume = $0 }
        }
    }

    private var capsuleIconColor: Color {
        onArtwork ? .white.opacity(0.9) : .primary.opacity(0.75)
    }
    private var hasArtworkBackground: Bool { onArtwork }

    /// 音量。调的是 **Music.app 自己的输出音量**(跟 Apple Music 那个滑杆同一个东西),
    /// 不是系统音量 —— 拖它不会影响别的 App 的声音。
    ///
    /// 跟"喜欢""播放模式"一样,只有 Apple Music 有这个概念,读不到就整个不显示(外面
    /// `if let volume = model.soundVolume` 那道判断)。
    ///
    /// 样式照着 Apple Music 那个玻璃胶囊做:左边一个静音开关、一条发丝分隔线、中间是
    /// **不带蓝色填充**的轨道加圆头滑块、右边一个跟着音量变的喇叭图标。系统 Slider 的
    /// 蓝色填充和小圆点在这里太"表单化",跟这扇窗口其余部分对不上。

    @ViewBuilder
    var body: some View {
        if let volume = model.soundVolume {
            // 形态对照 AM 顶栏音量胶囊特写(2026-08-21 第二轮):**只有滑杆 + 右侧喇叭**,
            // 没有左侧静音键和分隔线,整体宽高比 ≈4:1(我们 32pt 高 → 总宽 ~143)。静音
            // 功能收进右侧喇叭(点击切换,图标仍随档位变)。
            // 尺寸第三轮(2026-08-21,菜单栏 64px 作共同标尺的同屏对拍):滑块/轨道已与
            // AM 一致(12.5pt 高/3pt),差的是滑杆长(AM ≈125pt vs 88)和喇叭(AM ≈25pt
            // vs 12pt 字号,差一倍)。
            HStack(spacing: 10) {
                // AirPlay/音频输出键(2026-08-21 用户对照 AM 补上):AM 音量胶囊最左就是
                // 它 + 一条发丝分隔线;输出到**任何非内建设备**(蓝牙耳机/AirPlay/显示器)
                // 时染红 —— 实测 AM 输出到蓝牙 AirPods 时键也是红的,不只 AirPlay。
                // 点击弹的是窗级自绘面板(outputDevicePanel,与「⋯」菜单同款玻璃样式,
                // 系统 NSMenu 的紧凑样式跟 AM 对不上,用户要求统一)。
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { showsOutputMenu.toggle() }
                } label: {
                    Image(systemName: "airplay.audio")
                        // 17(2026-08-22 对拍:AM 该键字形宽 33px@2x=16.5pt,此前 16 号
                        // 字形量出 15.5pt,差半档)。
                        .font(.system(size: 17))
                        .frame(width: 22)
                        .foregroundStyle(
                            isExternalOutput
                                ? AnyShapeStyle(Color.red) : AnyShapeStyle(capsuleIconColor))
                }
                .buttonStyle(.plain)
                .help(L10n.t("音频输出"))
                .anchorPreference(key: OutputMenuButtonBoundsKey.self, value: .bounds) { $0 }
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: 18)
                // 114(2026-08-22 对拍:AM 滑杆区 228px@2x=114pt,此前 124 略长,
                // 挤得整颗胶囊比 AM 宽 7pt)。
                volumeSlider(volume: volume)
                    .frame(width: 114, height: 22)
                Button {
                    PlaybackCoordinator.shared.toggleMute()
                } label: {
                    Image(systemName: volumeLevelIcon(volume))
                        .font(.system(size: 17))
                        // 图标宽度随音量档位变化,固定住,不然整条控件会左右呼吸。
                        .frame(width: 24, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(volume == 0 ? L10n.t("取消静音") : L10n.t("静音"))
            }
            .foregroundStyle(capsuleIconColor)
            .padding(.horizontal, 14)
            // 7:胶囊总高 36(2026-08-22 对拍 AM 71px@2x=35.5)—— 行的落点见 body 里
            // overlay 的注释。
            .padding(.vertical, 7)
            .clearGlassCapsule(
                // 有封面背景时边缘走白色 —— 那一圈亮边正是"玻璃光泽"的来源;纯色底
                // (没有封面)下白边会显得脏,退回中性描边。
                rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
        }
    }

    private func volumeLevelIcon(_ v: Int) -> String {
        switch v {
        case 0: return "speaker.slash.fill"
        case 1...33: return "speaker.wave.1.fill"
        case 34...66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    /// 自绘滑杆。不用系统 Slider:那个的蓝色强调填充和小圆点是表单控件的样子,
    /// Apple Music 这个位置是"轨道 + 圆头滑块",而且已播部分只是比轨道稍亮一点。
    private func volumeSlider(volume: Int) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let f = min(1, max(0, Double(volume) / 100))
            // 滑块是**横向药丸**(2026-08-21 第二轮:胶囊收紧到 32pt 高后滑块同比缩到
            // ≈22×14;AM 特写里滑块宽约占滑杆全长 17%,30 宽在 88 长的滑杆里占 34% 太笨),
            // 不是圆点。
            // 23(2026-08-22 对拍:AM 滑块宽 47px@2x=23.5pt)。
            let knob: CGFloat = 23
            let knobHeight: CGFloat = 14
            let travel = max(0, w - knob)
            ZStack(alignment: .leading) {
                // AM 的轨道:已填充段是**亮白**、跟滑块连成一体;未填充段淡到几乎看不见
                // (特写里喇叭前那段轨道基本隐形)。无封面背景时退回中性色。
                // 轨道 6pt(2026-08-21 第三轮:AM 整窗截图逐列采样,轨道厚 12px@2x=6pt;
                // 此前 3pt 被用户点名"还是稍微细了点"——实际差一倍)。
                Capsule()
                    .fill(onArtwork ? Color.white.opacity(0.20) : Color.primary.opacity(0.14))
                    .frame(height: 6)
                // 已填充段 0.80(2026-08-22 对拍:AM 已填充段亮度 223/255,0.95 在
                // 截图里跟纯白滑块几乎分不开,AM 是明显"滑块更白一档")。
                Capsule()
                    .fill(onArtwork ? Color.white.opacity(0.80) : Color.primary.opacity(0.55))
                    .frame(width: knob / 2 + travel * f, height: 6)
                Capsule()
                    .fill(Color.white)
                    .frame(width: knob, height: knobHeight)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: travel * f)
            }
            .frame(height: g.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 0:点一下就跳到那个位置,不用真的拖。
                // 换算时把滑块自身宽度扣掉,否则拖到最右也到不了 100。
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard travel > 0 else { return }
                        let x = min(travel, max(0, value.location.x - knob / 2))
                        PlaybackCoordinator.shared.setVolume(Int((x / travel * 100).rounded()))
                    }
            )
        }
    }
}

// MARK: - AM 式动画背景

/// 「歌词窗口」背景的合成与动画:暗底 + 光斑层 lighten 混合 + 慢速旋转(2026-08-20,
/// 反向工程依据与图层烘焙见 PlaybackCoordinator.bakeWindowBackgroundLayers)。这里只做
/// GPU 变换动画——repeatForever 的 transform 动画由 CoreAnimation 驱动,不重算 SwiftUI
/// body;光斑图带径向羽化 alpha,旋转永不露硬边。「减少动态效果」开着时静止在初始姿态。
/// 光斑不透明度 0.75 是校准整组的一员(动它要重新校准,见烘焙函数注释)。
/// 「…」按钮的窗内坐标,自绘菜单据此定位(anchorPreference → overlayPreferenceValue)。
private struct MoreMenuButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// AirPlay/音频输出按钮的窗内坐标(同上,输出面板定位用)。
private struct OutputMenuButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// 右下角「翻译与发音」按钮的窗内坐标(同上,翻译菜单定位用)。
private struct TranslationMenuButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// 右下角 [歌词|队列] 胶囊的窗内坐标(同上,队列面板定位用)。
private struct QueuePillBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// 歌词滚动几何(自绘指示条用):内容在滚动坐标系里的偏移与总高。
private struct LyricsScrollMetricsValue: Equatable {
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
}
private struct LyricsScrollMetricsKey: PreferenceKey {
    static let defaultValue = LyricsScrollMetricsValue()
    static func reduce(value: inout LyricsScrollMetricsValue, nextValue: () -> LyricsScrollMetricsValue) {
        value = nextValue()
    }
}

/// 滚动指示条的数据小 model:滚动期间 preference 逐帧更新,只有指示条订阅它,
/// 整窗 body 不陪跑(性能纪律同 WindowVolumeCapsule.Model)。
@MainActor final class LyricsScrollMetricsModel: ObservableObject {
    @Published private(set) var offsetY: CGFloat = 0
    @Published private(set) var contentHeight: CGFloat = 0
    func update(offsetY: CGFloat, contentHeight: CGFloat) {
        if abs(offsetY - self.offsetY) > 0.5 { self.offsetY = offsetY }
        if abs(contentHeight - self.contentHeight) > 0.5 { self.contentHeight = contentHeight }
    }
}

/// 自绘滚动指示条(2026-08-22 对拍 AM:暗轨道 6pt + 白滑块 12pt、圆角胶囊、常显;
/// 位置由挂载处 padding 定,中心距窗右缘 59pt)。不可交互(allowsHitTesting false),
/// 滚动仍走滚轮/触控板。
private struct LyricsScrollIndicator: View {
    @ObservedObject var metrics: LyricsScrollMetricsModel
    let onArtwork: Bool

    var body: some View {
        GeometryReader { g in
            let viewH = g.size.height
            let topInset: CGFloat = 90
            let bottomInset: CGFloat = 40
            let trackH = viewH - topInset - bottomInset
            let content = metrics.contentHeight
            if content > viewH + 4, trackH > 80 {
                let thumbH = min(trackH, max(40, trackH * viewH / content))
                let maxScroll = content - viewH
                let f = maxScroll > 0 ? min(1, max(0, metrics.offsetY / maxScroll)) : 0
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Color.white.opacity(onArtwork ? 0.08 : 0.10))
                        .frame(width: 6, height: trackH)
                    Capsule()
                        .fill(Color.white.opacity(onArtwork ? 0.30 : 0.35))
                        .frame(width: 12, height: thumbH)
                        .offset(y: (trackH - thumbH) * f)
                }
                .frame(width: 12)
                .padding(.top, topInset)
            }
        }
    }
}

/// 待播清单的一行:曲名 + 歌手,当前曲带小喇叭标;悬停圆角高亮、整行可点(点击跳播)。
private struct QueueRow: View {
    let item: MusicPlaybackController.UpNextItem
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if item.isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13, weight: item.isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// 输出面板的一行:设备图标 + 名称 + 右侧勾选(AM 版式),悬停圆角高亮、整行可点
/// (contentShape 不能省,理由同 MoreMenuRow)。
private struct OutputDeviceRow: View {
    let title: String
    let symbol: String
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(width: 22)
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 16)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .opacity(isCurrent ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// AM 式菜单的一行:整行(含左右留白)可点、悬停圆角高亮 —— AM 的悬停态就是行级
/// 白色 12% 圆角块。contentShape(Rectangle()) 不能省:plain Button 默认只有非透明
/// 像素可命中,没有它就只有文字本身能点(跟「…」按钮热区太小是同一类坑)。
/// 「歌词时间轴」行里的小圆钮(提前/延后/重置):不关菜单,可连按。
private struct OffsetNudgeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.16 : 0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// 「搜索歌词…」的曲目快照(sheet(item:) 的身份即快照,见声明处注释)。
private struct LyricsSearchContext: Identifiable {
    let artist: String
    let title: String
    let album: String
    /// 写回用的缓存条目 key(实际命中优先,新建退 normalizedKey)。
    let key: String
    let currentSource: String?
    let durationSecs: Double

    var id: String { key }
}

/// 「显示简介」面板的一行:次级色标签 + 主色值,值可换行(长歌名/长专辑名)。
private struct InfoPanelRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MoreMenuRow: View {
    let title: String
    /// 行尾小图标(勾/重试箭头,状态行用),nil = 纯文本行。
    var trailingSystemImage: String? = nil
    /// false = 状态展示行(已在库/添加中/已添加):不可点、无悬停高亮、文字压暗。
    var enabled: Bool = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let icon = trailingSystemImage {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(enabled ? 1 : 0.55)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = enabled && $0 }
    }
}

/// AM 式播控点按反馈:按下瞬间快缩到 0.8,松手带一点过冲弹回(2026-08-21 用户对照
/// AM 要求"播放/上一首/下一首点击都有动画")。按下用短 easeOut(手指落下要立刻有
/// 反应,弹簧起步太肉),松手换弹簧(过冲才是"弹"的观感)。reduceMotion 下不做过渡、
/// 但保留按压缩小本身 —— 它是"点到了"的功能反馈,不是纯装饰。
private struct TransportButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.8 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : configuration.isPressed
                        ? .easeOut(duration: 0.1)
                        : .spring(response: 0.32, dampingFraction: 0.55),
                value: configuration.isPressed)
    }
}

private struct WindowAnimatedBackground: View {
    let layers: WindowBackgroundLayers
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(nsImage: layers.base)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                ForEach(layers.poses.indices, id: \.self) { i in
                    let pose = layers.poses[i]
                    Image(nsImage: layers.glows[i])
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(pose.scale)
                        // ±12° 往复摆动而不是整圈旋转(2026-08-21 定稿):光斑内容必须与
                        // 底层布局保持对齐,lighten 才是"原位增亮亮区";大角度旋转会把
                        // 封面布局盖掉(园游会的绿被转过来的暖色区污染,见烘焙函数注释)。
                        .rotationEffect(
                            .degrees(pose.initialAngle + (spinning ? 12 : -12)),
                            anchor: pose.anchor
                        )
                        .animation(
                            spinning
                                ? .easeInOut(duration: pose.spinDuration).repeatForever(autoreverses: true)
                                : nil,
                            value: spinning
                        )
                        .opacity(0.25)
                        .blendMode(.lighten)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // lighten 只在背景组内部生效,不跟窗口底色/别的图层混。
            .compositingGroup()
        }
        .onAppear { if !reduceMotion { spinning = true } }
    }
}
