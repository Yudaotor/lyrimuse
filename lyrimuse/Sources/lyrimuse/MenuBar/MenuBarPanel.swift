import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

/// 面板翻面、摆窗口这类界面事件的 debug 级日志:不落盘,验证时边触发边 `log stream --level debug` 对,不靠截图(14 章决策 98)。
private let panelLogger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "menubar-panel")

/// 面板的**窄订阅代理**(性能审计,四个展示面里最后一个接上;完整机制见
/// OverlayPlayback 的注释):PlaybackCoordinator 32 个 @Published 面板实读约 16 个、
/// AppSettings 48 个只读 5 个,整对象订阅会让歌词窗口拖音量、设置页无关滑杆这类写入
/// 打醒整个面板 body。只转发实读字段,值类型一律 removeDuplicates。
///
/// sink 只用参数值,不回读源属性(@Published willSet 时机,回读是旧值)。
///
/// anchor 入订阅(同 NotchPlayback 的取舍:progressArea 要在 body 里按锚点存在性分
/// 播放/暂停两条分支,而锚点只在换歌/seek 时重建,低频);currentLyricsOffsetMs 仍由
/// 逐字填色的 TimelineView 闭包直读协调器。resolvedPlayerIcon/DisplayName 不是
/// @Published(计算属性),body 直读 shared 即可,不经代理。
/// 三个悬浮层开关和触控栏开关转发进来只为触发 body 重估 —— LyricsSurface.isEnabled /
/// PanelQuickTarget.isEnabled 自己读 AppSettings.shared 的存储值(body 重估发生在落库后,读到的是新值)。
@MainActor
private final class PanelPlayback: ObservableObject {
    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var title = ""
    @Published private(set) var displayTitle = ""
    @Published private(set) var artist = ""
    @Published private(set) var displayArtist = ""
    @Published private(set) var displayAlbum = ""
    @Published private(set) var isPlayingNow = false
    /// 播放控制被拦下时的说明,没拦下是 nil(见 `PlaybackCoordinator.playbackControlsWithheldReason`)。
    @Published private(set) var controlsWithheldReason: String?
    /// 播放键图标用的乐观状态(点了当场翻,见 PlaybackCoordinator.userTogglePlayPause)。isPlayingNow 要等
    /// 0.5~1 秒回读才翻,容易被当成没点上而连点,媒体层假暂停那几秒还会闪成 ▶。
    @Published private(set) var isPlayingSmoothed = false
    /// 单行展示面取这一行,见 CompactLyricLead。面板那一格也是**定高单行**,跟灵动岛/
    /// 菜单栏文字同一处境,所以一起走这套。
    @Published private(set) var compactLine: SyncedLyricLine?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var engineNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    /// 电台口白 / 台卡:这一刻在放的不是歌。语义与 isCurrentTrackAdBreak 平行。
    @Published private(set) var isRadioTalkBreak = false
    @Published private(set) var radioStationName: String?
    @Published private(set) var currentLineFillSettled = true
    /// 歌词时间轴总偏移:逐字图层行拿它当时间基准指纹,调了偏移当场按新基准重装(见 layerKaraokeLine)。
    @Published private(set) var lyricsOffsetMs = 0
    @Published private(set) var artworkImage: NSImage?
    /// 系统那张封面的**高清替代**(`PlaybackCoordinator.highResArtworkImage`),系统给的
    /// 实在太小/不像封面时才有值。
    ///
    /// 消费方必须写 `highResArtworkImage ?? artworkImage` —— 这是那个属性声明处就写明的
    /// 口径(灵动岛、歌词窗口、悬浮歌词三处都照它写)。漏订阅 `highResArtworkImage`、只订阅
    /// `artworkImage` 的消费面会显示系统原图而不是缓存里的专辑封面——系统经 MediaSession
    /// 给的封面有时是一帧偏离正方形长宽比的 MV 画面(超过 `deviceArtworkMaxAspectSkew`
    /// 的 0.15,引擎侧那道守卫因此没把它当封面收下),两者显示的会不一样。
    ///
    /// 面板**画的不是它本尊**,是它的预缩小图 `highResArtworkThumbnail`:
    /// 这张是懒解码的原图档(1400~3000px),面板 44pt 那格首帧直接画它 = 主线程整张解码再缩,
    /// 离线量过 ~30ms,而面板每次打开都是全新建树、每次都重付,是"点图标之后有个小延迟
    /// 才弹出"的一部分。缩好的小图由 PlaybackCoordinator 在图到货时后台烘一次。
    /// 这里仍然订阅本尊只是为了跟 thumbnail 同进退时不出现"图有、缩略没有"的半拍。
    @Published private(set) var highResArtworkImage: NSImage?
    @Published private(set) var highResArtworkThumbnail: NSImage?
    /// 面板该显示的那张 —— 别在视图里各写一遍 `?? `,漏一处就又是一个显示原图的消费面。
    /// 优先级:预缩小的高清图 → 高清原图(理论上不该走到,thumbnail 跟原图同一趟产出,
    /// 只有缩图失败才会) → 系统那张。
    var displayArtworkImage: NSImage? { highResArtworkThumbnail ?? highResArtworkImage ?? artworkImage }
    @Published private(set) var anchor: ProgressAnchor?
    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?
    @Published private(set) var trackLyricsOffsetMs = 0
    // ---- 来自 AppSettings(只挑面板实读的五项) ----
    @Published private(set) var classicOverlayEnabled = false
    @Published private(set) var notchOverlayEnabled = false
    @Published private(set) var showLyricsInMenuBar = false
    @Published private(set) var showLyricsInTouchBar = false
    @Published private(set) var lyricsOffsetStepMs = 200
    // ---- 来自 TouchBarAvailability ----
    /// 这台 Mac 此刻有没有触控栏。第二排那一格「触控栏歌词」只在有的时候出现,模拟器开 / 关时面板开着也跟着变。
    @Published private(set) var touchBarPresent = false
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$displayTitle.removeDuplicates().sink { [weak self] in self?.displayTitle = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            // 两份都要:`artist` 给「有没有曲目」那道判断用(它问的是载荷里有没有东西),
            // `displayArtist` 只画在卡片上。判据见 `PlayerArtistFix.displayArtist`。
            p.$displayArtist.removeDuplicates().sink { [weak self] in self?.displayArtist = $0 },
            p.$displayAlbum.removeDuplicates().sink { [weak self] in self?.displayAlbum = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$playbackControlsWithheldReason.removeDuplicates().sink { [weak self] in self?.controlsWithheldReason = $0 },
            // 面板只读 compactLine、不读 currentLine:两者每句各变一次、不同步,订后者等于每句多重绘一次整个面板。
            p.$isPlayingSmoothed.removeDuplicates().sink { [weak self] in self?.isPlayingSmoothed = $0 },
            // 面板里那一行歌词跟状态栏项是同一个展示面(菜单栏),吃同一颗「卡拉OK效果」
            // (`menuBarLyricsKaraoke`,是它唯一的闸):关着时把行
            // 压成整行(`SyncedLyricLine.lineLevel`),`lyricContent` 的判定链自然落到 `.plain`。
            // 状态栏项自己在 `MenuBarStatusItem.karaokeFillPath` 里判这颗开关,不经这里。
            Publishers.CombineLatest(p.$menuBarLyrics.map(\.compactLine), s.$menuBarLyricsKaraoke)
                .map { line, karaoke in karaoke ? line : line?.lineLevel }
                .removeDuplicates()
                .sink { [weak self] in self?.compactLine = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$engineNetworkDown.removeDuplicates().sink { [weak self] in self?.engineNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$isRadioTalkBreak.removeDuplicates().sink { [weak self] in self?.isRadioTalkBreak = $0 },
            p.$radioStationName.removeDuplicates().sink { [weak self] in self?.radioStationName = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$currentLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.lyricsOffsetMs = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            // 这条订阅不能省:高清替代是**换歌后异步下载**的,只改
            // 读取处不加订阅的话,面板会一直停在系统原图上、等到下一次别的 @Published
            // 变化顺带刷新才换过来。按指针去重跟上面那条同款(每次到货都是新实例)。
            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
            p.$highResArtworkThumbnail.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkThumbnail = $0 },
            p.$anchor.sink { [weak self] in self?.anchor = $0 },
            p.$pausedPositionMs.removeDuplicates().sink { [weak self] in self?.pausedPositionMs = $0 },
            p.$currentDurationMs.removeDuplicates().sink { [weak self] in self?.currentDurationMs = $0 },
            p.$trackLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.trackLyricsOffsetMs = $0 },
            s.$classicOverlayEnabled.removeDuplicates().sink { [weak self] in self?.classicOverlayEnabled = $0 },
            s.$notchOverlayEnabled.removeDuplicates().sink { [weak self] in self?.notchOverlayEnabled = $0 },
            s.$showLyricsInMenuBar.removeDuplicates().sink { [weak self] in self?.showLyricsInMenuBar = $0 },
            s.$showLyricsInTouchBar.removeDuplicates().sink { [weak self] in self?.showLyricsInTouchBar = $0 },
            s.$lyricsOffsetStepMs.removeDuplicates().sink { [weak self] in self?.lyricsOffsetStepMs = $0 },
            TouchBarAvailability.shared.$isPresent.removeDuplicates()
                .sink { [weak self] in self?.touchBarPresent = $0 },
        ]
    }
}

// 菜单栏左键面板(「控制中心风」):
// 一张全宽「正在播放」卡 + 2×2 大圆钮块(开关/入口,带状态副文字) + 一条细底栏。
// 右键是那棵完整 NSMenu(MenuBarStatusMenu)——所有低频功能的家,
// 面板只承载高频:看一眼在放什么、切歌/拖进度、开关两种歌词悬浮层、进歌词管理。
//
// 窗口是自建的**不激活 App 的面板**(`MenuBarPanelWindow`,同 Spotlight / 控制中心那一类),不是 NSPopover:
// 弹出就是 key window,控件按「当前窗口」的样子画,不用先点一下才亮;又不激活 App —— 激活会把用户正在用的
// App 顶到后台、把开着的歌词窗口 / 设置窗口一起带到前面,在别人的全屏空间里还可能被拉回桌面空间。
// NSPopover 的窗口是系统现建的,「不激活也能成为 key」这一位必须在建窗时就带上,事后补不上(见 06 章决策 40)。
// 代价是 transient(点外面收起)、锚定位置、跟着内容变高这三件 NSPopover 白给的事要自己做,见下面各段。
@MainActor
final class MenuBarPanelController {
    private var panel: MenuBarPanelWindow?
    /// 面板挂在哪颗状态栏按钮下面。内容变高时按它重新定位(顶边不动、往下长)。
    private weak var anchorButton: NSStatusBarButton?
    /// 「点到别的 App 上」的收起路径:全局监视器只收得到**别的 App** 的事件。
    private var outsideClickMonitor: Any?
    /// 「点到本 App 别的窗口上」的收起路径(相当于 NSPopover .transient 管的那一半)。
    private var localClickMonitor: Any?
    /// 切 Space 也要收 —— 面板会出现在每个 Space 上(见 MenuBarPanelWindow 的 collectionBehavior),
    /// 不收的话切走之后它还挂在那儿。挂在 NSWorkspace 的通知中心,拆的时候也要从那边拆。
    private var spaceChangeObserver: NSObjectProtocol?
    /// 别的 App 被激活(Cmd-Tab、空闲卡上点「打开 X」把播放器带到前台)也收起。
    private var appActivationObserver: NSObjectProtocol?
    /// 面板开/关 —— 状态栏那行滚动歌词要跟着反白,跟 NSMenu 的 delegate 回调同一件事。
    var onVisibilityChange: ((Bool) -> Void)?

    /// `quick`:打开就翻到那一格的快捷设置(lyrimuse://menubar-panel?quick=…),nil = 正常的钮块网格。
    func toggle(relativeTo button: NSStatusBarButton, quick: PanelQuickTarget? = nil) {
        if panel != nil {
            close()
            return
        }
        anchorButton = button
        let window = MenuBarPanelWindow()
        window.onCancel = { [weak self] in self?.close() }
        let content = MenuBarPanelRoot(
            content: MenuBarPanelView(close: { [weak self] in self?.close() }, initialQuickTarget: quick))
        let host = FirstMouseHostingView(rootView: content)
        // 只要固有尺寸(下面 fittingSize 要用),不要 min / max:那两项会往窗口上加尺寸约束,跟 place 摆的 frame 打架。
        host.sizingOptions = [.intrinsicContentSize]
        host.onFittingSizeChange = { [weak self] size in self?.place(size: size) }
        // 先登记再装内容:内容第一次布局就会报尺寸(onFittingSizeChange),那时 panel 还是 nil 的话这次摆位会被跳过。
        panel = window
        window.setContent(host)
        place(size: host.fittingSize)
        installDismissWatchers(for: window)
        // 面板开着时预取简介:歌名、歌手名、专辑名只在有简介时可点,得提前知道。与 close 里的 release 成对。
        EditorialNotesStore.shared.retain()
        onVisibilityChange?(true)
        window.orderFrontRegardless()
        // 深链带 background=1 时不当 key:不激活的面板当了 key 照样接走键盘输入,用户在别的 App 里打的字会落进面板。
        if !WindowActivation.isBackground { window.makeKey() }
    }

    func close() {
        guard let window = panel else { return }
        MenuBarPanelDebugState.quickTarget = nil
        teardownDismissWatchers()
        EditorialNotesStore.shared.release()
        // 收起即整树释放:下次 toggle 本来就是全新建(onAppear 快照语义还依赖这一点)。
        panel = nil
        window.orderOut(nil)
        onVisibilityChange?(false)
    }

    /// 顶边贴着状态栏按钮下沿(留 4pt)、水平居中在按钮下面,再钳进屏幕可用区。内容变高时只往下长。
    private func place(size: CGSize) {
        guard let window = panel, size.width > 0, size.height > 0 else { return }
        guard let button = anchorButton, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonRect
        let margin: CGFloat = 8
        let x = min(max(buttonRect.midX - size.width / 2, visible.minX + margin), visible.maxX - size.width - margin)
        let top = min(buttonRect.minY - 4, visible.maxY)
        let frame = NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
        if window.frame != frame {
            panelLogger.debug("panel placed: \(Int(frame.width), privacy: .public)x\(Int(frame.height), privacy: .public)")
            window.setFrame(frame, display: true)
        }
        // 玻璃底(`NSGlassEffectView`)按内容的固有尺寸自己先长 / 缩一次,窗口改尺寸时又按自动缩放再改一次,高度差算了两遍:
        // 内容视图比窗口高(内容往上顶出去)或矮(内容沉到底)。每次摆完都把它对齐到窗口。见 06 章决策 52。
        if let content = window.contentView, content.frame.size != frame.size {
            content.frame = NSRect(origin: .zero, size: frame.size)
        }
    }

    /// 状态栏按钮在屏幕上的矩形。
    private var anchorButtonScreenRect: NSRect? {
        guard let button = anchorButton, let buttonWindow = button.window else { return nil }
        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func installDismissWatchers(for window: MenuBarPanelWindow) {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                // 点状态栏按钮那一下也会先到这里(macOS 26 上状态栏的点击先当作别的进程的事件发出来),
                // 在这里收的话按钮的 toggle 紧接着又把面板打开。开关交给 toggle。
                guard let self, self.anchorButtonScreenRect?.contains(location) != true else { return }
                self.close()
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self, weak window] event in
            guard let self, let window else { return event }
            let target = event.window
            // 面板自己、面板里下拉菜单的菜单窗口(level ≥ popUpMenu)都不算「点到外面」。
            if target === window { return event }
            if let level = target?.level, level >= .popUpMenu { return event }
            // 状态栏按钮也不算:它的点击走 toggle,在这里先收的话 toggle 紧接着又把面板打开。按点击位置认。
            if self.anchorButtonScreenRect?.contains(NSEvent.mouseLocation) == true { return event }
            self.close()
            return event
        }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.close() }
        }
    }

    private func teardownDismissWatchers() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        localClickMonitor = nil
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        }
        spaceChangeObserver = nil
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        appActivationObserver = nil
    }
}

/// 面板窗口:不激活 App 也能成为 key 的无边框面板,底是一整块液态玻璃(macOS 26 起;更早是系统 popover 材质)+ 圆角 + 窗口阴影。
///
/// `.nonactivatingPanel` 必须在建窗时传进 styleMask(事后插入不生效)。无边框窗口默认不能成为 key,
/// 所以 canBecomeKey 要显式放开。collectionBehavior 的两位是「别的 App 全屏时也打得开」:
/// `.fullScreenAuxiliary` 给进别人全屏 Space 的许可,`.canJoinAllSpaces` 让它落在当前 Space 上,缺一不可。
private final class MenuBarPanelWindow: NSPanel {
    static let cornerRadius: CGFloat = 24
    /// Esc 收起。
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 336, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // 别设 isFloatingPanel:它会把 level 改回 .floating,压不过别的 App 的浮动窗口。
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// 窗口阴影的形状。无边框窗口的阴影 AppKit 只认两处给的圆角:内容视图是带 `maskImage` 的 `NSVisualEffectView`
    /// (旧系统那档),或者窗口自己的 `_cornerMask`(私有方法,Chromium / Electron 的无边框圆角窗口同样靠它)。玻璃底
    /// 两样都没有,不给的话阴影是方的,下面两个圆角外各露出一块方角深色。只是覆盖一个返回图片的方法:系统不再调它时
    /// 退回方形阴影,不会出错。见 06 章决策 47。
    @objc(_cornerMask) func shadowCornerMask() -> NSImage {
        Self.roundedMask(radius: Self.cornerRadius)
    }

    /// 底 + 圆角,内容铺满。macOS 26 起是 `NSGlassEffectView` 常规那一档,圆角和边上的亮边由它自己画;窗口本来就透明,
    /// 玻璃折射的是背后的桌面。更早的系统是 popover 材质 + 圆角遮罩。见 06 章决策 47。
    func setContent(_ content: NSView) {
        if let glass = menuBarPanelGlassBackdrop(content: content, cornerRadius: Self.cornerRadius) {
            contentView = glass
            return
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        contentView = effect
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 面板内容的外壳:按理想尺寸排(窗口多大由宿主视图报给控制器,见 FirstMouseHostingView);旧系统的材质底再描一圈发丝边,
/// macOS 26 起的玻璃底自带亮边,不描。
///
/// 内容贴着窗口顶边摆:内容跟窗口一时对不上高度时,宿主视图默认把它上下居中,翻面那一下整块先往上 / 往下挪半个高度差、
/// 窗口改完尺寸再弹回来,看着就是整个面板抖一下。贴顶之后多出 / 少掉的只在底部。`minHeight: 0` 不能省:不写的话这层
/// frame 不会比内容矮,照样被撑高、照样居中。见 06 章决策 45。
private struct MenuBarPanelRoot<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .fixedSize()
            .overlay {
                if #unavailable(macOS 26.0) {
                    RoundedRectangle(cornerRadius: MenuBarPanelWindow.cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

/// 让面板里的 SwiftUI 控件也「第一下就算数」。面板平时就是 key window,这一层兜的是它失去 key 之后
/// (比如点开过别的窗口又点回来):NSHostingView 默认 `acceptsFirstMouse` 为 false,那一下会只用来把窗口变回 key。
///
/// 它也负责报尺寸:内容的理想尺寸(`fittingSize`)跟自己现在的尺寸对不上时,当场交给控制器摆窗口。翻出快捷设置、行内
/// 多出一行这类变化之后它一定会走一次 `layout()`。别换回 GeometryReader + PreferenceKey:内容长得比窗口高时那条回调
/// 不来,窗口停在旧高度、下面截掉(06 章决策 44)。也别推到下一拍再改窗口:中间那一帧窗口和内容对不上,面板抖一下;
/// 当场改完窗口会再走一次 layout,那时尺寸已经对上、直接返回(06 章决策 45)。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onFittingSizeChange: ((CGSize) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let fitting = fittingSize
        guard fitting != bounds.size else { return }
        onFittingSizeChange?(fitting)
    }
}

// MARK: - 面板本体

private struct MenuBarPanelView: View {
    // 跟 MenuBarStatusMenu 文件头同一条不变量:**渲染路径只读 AppSettings/
    // PlaybackCoordinator,绝不碰两个悬浮窗控制器的 .shared**(碰了就把用户关掉的
    // 悬浮窗凭空建出来)。动作闭包里可以碰 —— 那是用户主动要求。
    // 不整对象订阅 PlaybackCoordinator/AppSettings —— 见 PanelPlayback 的注释。
    @StateObject private var playback = PanelPlayback()
    let close: () -> Void
    // 长按 / 右键某个能翻面的格子之后,面板下半部分换成它自己的快捷设置;
    // nil = 正常的钮块网格。见 MenuBarPanelQuickSettings.swift。
    @State private var quickTarget: PanelQuickTarget?
    /// 点了歌名 / 歌手名 / 专辑名之后,面板下半部分换成那一类简介(`PanelEditorialPage`);nil = 没翻到简介。
    @State private var editorialKind: EditorialCard.Kind?
    @ObservedObject private var editorial = EditorialNotesStore.shared

    init(close: @escaping () -> Void, initialQuickTarget: PanelQuickTarget? = nil) {
        self.close = close
        _quickTarget = State(initialValue: initialQuickTarget)
        MenuBarPanelDebugState.quickTarget = initialQuickTarget?.deepLinkValue
    }
    /// 停播卡「打开」键上那枚播放器图标(见 idleRow)。按播放器取一次,不在 body 里现查。
    @State private var idlePlayerIcon: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 封面小图按像素预先重采样要知道显示倍率(见 coverView)。
    @Environment(\.displayScale) private var displayScale
    /// Last.fm 连接情况,开窗那一刻取一次快照(见 lastfmFooterItem)。
    @State private var lastfmStatus: DestinationStatus?
    /// 有没有查到还没装的新版本,开窗那一刻取一次快照(同 lastfmStatus 的理由:面板是短命
    /// 视图,不为一个几天才变一次的值常驻订阅;见 versionFooterItem)。
    @State private var pendingUpdate: SparkleUpdaterManager.AvailableUpdate?

    var body: some View {
        VStack(spacing: 9) {
            nowPlayingCard
            // 「正在播放」卡不参与切换 —— 它是这张面板的身份,连它一起换掉就像换了一扇窗;
            // 留着它高度落差也更小(快捷设置比两排钮块还矮一点)。
            if let card = shownEditorialCard {
                PanelEditorialPage(card: card, back: { editorialKind = nil })
            } else if let quickTarget {
                PanelQuickSettings(
                    target: quickTarget,
                    action: quickAction(for: quickTarget),
                    back: { setQuickTarget(nil) },
                    close: close)
            } else {
                knobGrid
                footer
            }
        }
        .padding(10)
        // 旧系统的材质底上垫一层淡光,同设置页:材质上玻璃折射不到东西,没有它卡片边界看不出来。玻璃底透得到桌面,不垫。
        .background {
            if #unavailable(macOS 26.0) { LastfmGlassGlow() }
        }
        .frame(width: 336)
        // 换歌时简介先撤掉:翻着的简介页退回钮块网格,新歌的简介到了也不自己翻出来。
        .onChange(of: shownEditorialCard == nil) { _, missing in
            if missing { editorialKind = nil }
        }
        // 快捷设置正翻在「触控栏歌词」那一格上时触控栏没了(模拟器关掉):那一格已经不在了,退回钮块网格。
        .onChange(of: playback.touchBarPresent) { _, present in
            if !present, quickTarget == .touchBar { setQuickTarget(nil) }
        }
        // 只在弹出这一刻取一次 —— 面板每次打开都是新建的一份视图,所以"每次开窗刷新一次"
        // 已经够了,不用为它常驻订阅 ConfigStore/LastfmConnectController/状态文件观察器
        // 三个东西(这张面板的渲染路径一直刻意只依赖 AppSettings/PlaybackCoordinator)。
        //
        // 代价说清楚:面板**开着的时候**在设置里连上/断开 Last.fm,这一项不会当场跟着变,
        // 收起再开就对了。而 destinationStatus 的判定本身跟设置页共用同一个函数,不会出现
        // 两处口径不一致。
        .onAppear {
            pendingUpdate = SparkleUpdaterManager.shared.availableUpdate
            lastfmStatus = destinationStatus(
                for: .lastfm,
                config: .shared,
                lastfmConnect: .shared,
                // 这里直接读那个带 mtime 缓存的静态量,不走 LastfmMirrorStatusWatcher:
                // 那个观察器是给**常驻**视图用的(文件被引擎自愈删掉时要能推一次
                // 更新);这张面板活不过一次开合,读一次当下的状态正好。
                mirrorInfo: LastfmMirrorStatus.current)
        }
    }

    private var shownEditorialCard: EditorialCard? {
        editorialKind.flatMap { editorial.card($0) }
    }

    /// 点歌名 / 歌手名 / 专辑名:翻到那一类简介;再点同一类 = 翻回去。
    private func toggleEditorial(_ kind: EditorialCard.Kind) {
        editorialKind = editorialKind == kind ? nil : kind
        if editorialKind != nil { setQuickTarget(nil) }
    }

    /// 歌名那一行能不能点开歌曲简介:这一行摆的确实是这首的歌名 —— 广告时是「广告中」,电台口白时是台名。
    private var titleOpensSongNotes: Bool {
        editorial.song != nil && !playback.isCurrentTrackAdBreak && !playback.isRadioTalkBreak
    }

    /// 展开 / 收起快捷设置。
    ///
    /// **不包 withAnimation**。withAnimation 开的是一个**事务**,这一帧里所有可动画的
    /// 变化都会被它接管 —— 包括「正在播放」卡里那行歌词(跑马灯的横向偏移、逐字填色的
    /// 渐变)。包了的话,收起快捷设置时整行歌词会跟着跳一下:歌词行本来跟这次展开/收起
    /// 毫无关系,却被顺带补间了一次。
    ///
    /// 而这个动画本来也没什么用:面板高度是窗口尺寸,由控制器按内容报的尺寸摆(见
    /// FirstMouseHostingView),SwiftUI 这一层补间不到它。等于是白担了副作用。
    private func setQuickTarget(_ target: PanelQuickTarget?) {
        quickTarget = target
        MenuBarPanelDebugState.quickTarget = target?.deepLinkValue
        panelLogger.debug("panel quick target: \(target?.deepLinkValue ?? "grid", privacy: .public)")
    }

    /// 某一格的主动作。快捷设置头部那颗控件跟格子本身调的必须是**同一条闭包**(三个形态和触控栏
    /// 那里是总开关,歌词窗口那里是「打开」),两处各写一遍必然走岔 —— 尤其菜单栏歌词那条"先收面板"
    /// 的绕路和歌词窗口这条"先收面板再开窗"的顺序。
    private func quickAction(for target: PanelQuickTarget) -> () -> Void {
        switch target {
        case .surface(let surface): return toggleAction(for: surface)
        case .lyricsWindow: return openLyricsWindowAction
        case .touchBar: return toggleTouchBarAction
        case .lyricsManager: return openLyricsManagerAction
        }
    }

    /// 「歌词管理」那一格:先收面板再开窗,理由同 `openLyricsWindowAction`。
    private var openLyricsManagerAction: () -> Void {
        {
            close()
            AppActions.shared.openLyricsManager?()
        }
    }

    /// 「歌词窗口」那一格:先收面板再开窗。收面板不只是顺手 —— `openLyricsWindow` 会
    /// `NSApp.activate` 把那扇窗带到前台(见 NotchEditorStage 里那条注释),面板是一扇
    /// `.transient` 的 popover,本来也会被这一下顶掉,显式收干净比让它自己被撞掉可控。
    private var openLyricsWindowAction: () -> Void {
        {
            close()
            AppActions.shared.openLyricsWindow?()
        }
    }

    /// 「触控栏歌词」那一格:翻总开关,跟设置页那张开关卡、右键菜单「快速开关」那一项是同一个值。控制器订阅着它,
    /// 打开那一下当场展开触控栏(`TouchBarLyricsController.start`)。不收面板:效果在触控栏上,跟面板锚着的状态栏项无关。
    private var toggleTouchBarAction: () -> Void {
        { AppSettings.shared.showLyricsInTouchBar.toggle() }
    }

    /// 某个形态"开 / 关"这一下该做什么。抽成一份是因为格子和快捷设置头部那个开关必须是
    /// **同一种**行为 —— 尤其菜单栏歌词那条"先收面板"的绕路,两处各写一遍必然走岔。
    ///
    /// 这里只是**造闭包**、不执行,文件头那条"渲染路径绝不碰两个悬浮窗控制器 .shared"
    /// 的不变量没被破坏:闭包体要等用户真按了才跑。
    private func toggleAction(for surface: LyricsSurface) -> () -> Void {
        switch surface {
        case .overlay:
            return {
                LyricsOverlayWindowController.shared.setVisible(!AppSettings.shared.classicOverlayEnabled)
            }
        case .notch:
            return {
                NotchLyricsWindowController.shared.setVisible(!AppSettings.shared.notchOverlayEnabled)
            }
        case .menuBar:
            return {
                // 先收面板、等 popover 退场再切(实测:面板开着切,状态栏项被锚着的
                // popover 拖住不变宽,歌词却已按新宽度画出,整段文字甩到左边邻居的图标上)。
                // 收面板也顺 UX:开关的效果就发生在状态栏上,正好看得见。
                //
                // 状态栏项那边另有一道"面板开着不重建"的闸(MenuBarStatusItem 的 panelIsOpen),
                // 它管的是**别的**触发源(换句 / 歌词间隙 / 快捷设置里拖宽度),这条绕路仍然
                // 是这个开关自己的事。
                close()
                // 0.5s:popover 退场动画 ~0.3s,0.25s 时锚还没完全撤(实测关闭后项不缩回,
                // 直到面板彻底走掉才恢复),留足余量。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    AppSettings.shared.showLyricsInMenuBar.toggle()
                }
            }
        }
    }

    // MARK: 钮块网格

    private var knobGrid: some View {
        VStack(spacing: 9) {
            // 三种歌词展示形态凑成完整一排(用户提议加菜单栏歌词):它们本来
            // 就是同级三兄弟;而且菜单栏这个开关的效果就发生在面板正上方,点完立刻看得见。
            HStack(spacing: 9) {
                surfaceTile(.overlay)
                surfaceTile(.notch)
                surfaceTile(.menuBar)
            }
            HStack(spacing: 9) {
                // 不带副文字(去掉「点击打开」):钮块本来就是按钮,
                // "点按打开"是同义反复,去掉后跟第一排三个形态格的高度也更齐。
                //
                // 这一格**也能翻面**:短按照旧开窗,长按 / 右键翻到它自己的快捷设置
                // (背景样式 / 渐变方向 / 动态封面)。符号和标题都从 PanelQuickTarget 取,
                // 别在这儿和背面各写一份。
                knobTile(symbol: PanelQuickTarget.lyricsWindow.symbolName,
                         title: PanelQuickTarget.lyricsWindow.panelTitle,
                         on: false, quick: .lyricsWindow,
                         action: openLyricsWindowAction)
                // 「触控栏歌词」只在这台 Mac 此刻有触控栏时出现(真机,或 Xcode 的触控栏模拟器开着;判据同设置页
                // 「触控栏」那一段、右键菜单「快速开关」那一项),没有时这一排照旧两格。短按 = 总开关,长按 / 右键 =
                // 它自己的快捷设置,跟第一排三个形态同一套。见 06 章决策 37。
                if playback.touchBarPresent {
                    knobTile(symbol: PanelQuickTarget.touchBar.symbolName,
                             title: PanelQuickTarget.touchBar.panelTitle,
                             on: PanelQuickTarget.touchBar.isEnabled, quick: .touchBar,
                             action: toggleTouchBarAction)
                }
                // 「歌词管理」(统计入口在设置窗口的 Last.fm 账号页),底栏不另放一条「歌词管理…」,不留双入口。
                // 短按开窗,长按 / 右键翻到背面:正在放的这首的几个动作(PanelLyricsManagerRows)。
                knobTile(symbol: PanelQuickTarget.lyricsManager.symbolName,
                         title: PanelQuickTarget.lyricsManager.panelTitle,
                         on: false, quick: .lyricsManager,
                         action: openLyricsManagerAction)
            }
        }
    }

    /// 三个「歌词展示形态」的格子:短按 = 开 / 关,长按或右键 = 翻到它自己的快捷设置。
    private func surfaceTile(_ surface: LyricsSurface) -> some View {
        knobTile(symbol: surface.symbolName, title: surface.panelTitle,
                 on: surface.isEnabled, quick: .surface(surface),
                 action: toggleAction(for: surface))
    }

    // MARK: 正在播放卡

    // 广告插播时这张卡的三行文案。判据 isCurrentTrackAdBreak 由 LocalPlaybackSource 给
    // (字段启发式 + 同曲棘轮 + AppleScript `spotify url` 权威分类)。
    //
    // 广告插播时这张卡显示「广告中」——灵动岛(NotchLyricsView)和歌词窗口歌词区
    // (emptyStateSpec)是同一口径。
    private var displayTitle: String {
        if playback.isCurrentTrackAdBreak { return L10n.t("广告中") }
        // 电台口白 / 台卡:换成台名,跟灵动岛、歌词窗口同一口径。抓不到台卡就照旧。
        if playback.isRadioTalkBreak, let station = playback.radioStationName, !station.isEmpty {
            return station
        }
        // 没歌在放就留白,别摆占位破折号。那一横不携带任何
        // 信息:封面已经是空封面、歌手/专辑也都是空的,"没在放"这件事已经说得很清楚了,
        // 再画一横反倒像"有一首歌但名字读不出来"。
        //
        // 仍然返回一个空串、让这个 Text 留在原地,而不是整行 if 掉:它占着一行行高,
        // 文字块高度不随播放状态跳动,下面那排控制按钮才不会上下弹。
        return playback.displayTitle
    }

    /// 广告时歌手/专辑都留空,不展示广告物料的名字(跟灵动岛一致的口径)。不是多余判断:
    /// 广告有时会带全 artist/album 字段,不显式清掉就会冒出广告主的名字。
    private var displayArtist: String {
        playback.isCurrentTrackAdBreak ? "" : playback.displayArtist
    }

    private var displayAlbum: String {
        playback.isCurrentTrackAdBreak ? "" : playback.displayAlbum
    }

    /// 压根没有曲目(不是"没有封面"):没歌名、没歌手,而且不是广告插播。
    ///
    /// 用于把上半张卡整块收掉,见 nowPlayingCard 里那段注释。刻意不看 isPlayingNow ——
    /// 暂停中仍然有一首曲目,那时候封面/歌名/歌词都该照常显示。
    private var isIdleNoTrack: Bool {
        playback.title.isEmpty && playback.artist.isEmpty && !playback.isCurrentTrackAdBreak
    }

    /// 卡片上半部分:封面 + 歌名/歌手/专辑 + 右上角来源角标。
    /// 抽成独立属性只为了让上面那个 `if` 能整块开关它(没抽的话那段 55 行要整体缩进)。
    private var trackHeader: some View {
        HStack(alignment: .top, spacing: 9) {
            // 点封面 → 打开歌词窗口(跟灵动岛上两处封面同一动作);
            // 先收面板再开窗,同「歌词窗口」块的顺序。
            Button {
                close()
                AppActions.shared.openLyricsWindow?()
            } label: {
                coverView
            }
            .buttonStyle(.plain)
            .help(L10n.t("打开歌词窗口"))
            VStack(alignment: .leading, spacing: 2) {
                // 三行各自在有简介时可点(下划线 + 提亮),点了面板下半部分翻到那一类简介。
                EditorialLinkText(text: displayTitle, available: titleOpensSongNotes,
                                  restColor: .primary, hoverColor: .primary,
                                  hint: EditorialCard.Kind.song.openHint) { toggleEditorial(.song) }
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                // 这一行只有歌手一个 Text,没有额外包装的空壳容器。
                //
                // 顺带清掉了只服务它的 recording 计算属性,以及只被 recording 用到的
                // features(FeatureSettingsStore)订阅 —— 留着的话这张面板会因为任何
                // 无关的功能开关变化白重渲染一次。
                EditorialLinkText(text: displayArtist, available: !displayArtist.isEmpty && editorial.artist != nil,
                                  restColor: .secondary, hoverColor: .primary,
                                  hint: EditorialCard.Kind.artist.openHint) { toggleEditorial(.artist) }
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                // 专辑行。只在真有专辑名时才渲染 —— Spotify 常常
                // 不上报专辑,占一个空行会让卡片凭空高一截、看着像排版错了。
                //
                // 用 .tertiary 而不是 .secondary:标题(primary)→ 歌手(secondary)→
                // 专辑(tertiary)三级递减,跟「最近记录」列表里专辑列的处理一致。
                if !displayAlbum.isEmpty {
                    EditorialLinkText(text: displayAlbum, available: editorial.album != nil,
                                      restColor: Color(nsColor: .tertiaryLabelColor), hoverColor: .primary,
                                      hint: EditorialCard.Kind.album.openHint) { toggleEditorial(.album) }
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // 来源角标:右上角放播放器的真实 App 图标(比文字
            // 胶囊更好认更安静),悬停给名字。放卡片内容内部而不是 .overlay ——
            // 设置页实测过卡片背景吞外挂 overlay 的坑,别再赌。
            // 加点击:点角标跳到那个播放器(网页平台翻到正在放歌的那枚标签页,
            // 原生播放器激活 App —— `openResolvedPlayer` 一条路管两种),顺手收面板
            // (跳去别的 App 了,面板留着也只会被失焦监视器收掉,不如主动收干净)。
            if let icon = PlaybackCoordinator.shared.resolvedPlayerIcon {
                Button {
                    PlaybackCoordinator.shared.openResolvedPlayer()
                    close()
                } label: {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassIcon())
                .modifier(OptionalHelp(text: PlaybackCoordinator.shared.resolvedPlayerDisplayName))
            }
    }
    }

    private var nowPlayingCard: some View {
        VStack(spacing: 8) {
            // 压根没有曲目时整张卡换成 idleRow —— 上半截(封面/歌名/歌手/歌词行)全是空的,
            // 摆在那儿只剩占位图和两行空文本;进度条没时长本来就不渲染;三键里前两颗对空
            // 队列是静默 no-op。
            //
            // 判据是"压根没有曲目"而不是"没有封面":播放中拿不到封面的曲目(播客/取图
            // 失败)照旧走下面这条 —— 那时候渐变占位图是有意义的(它代表一首真的歌),而卡片
            // 右边还有歌名/歌手撑着。广告插播同理(标题是「广告中」,有东西在放)。
            if isIdleNoTrack {
                idleRow
            } else {
                trackHeader
                lyricLine
                // 进度条独立成 PanelProgressSection 子视图:拖动/悬停
                // 状态自持,拖一次 seek 不会整面板逐指针事件重估。
                PanelProgressSection(
                    anchor: playback.anchor,
                    pausedPositionMs: playback.pausedPositionMs,
                    durationMs: playback.currentDurationMs,
                    seekable: PlaybackCoordinator.shared.acceptsSeek,
                    trackLyricsOffsetMs: playback.trackLyricsOffsetMs,
                    lyricsOffsetStepMs: playback.lyricsOffsetStepMs)
                HStack(spacing: 28) {
                    // 三个键跟状态栏悬停三键同一道「点了才校验权限」(没授权时响一声,不是静默失败)。
                    controlButton("backward.fill", size: 13) {
                        MenuBarStatusItem.withMusicPermission { MusicPlaybackController.previousTrack() }
                    }
                    controlButton(playback.isPlayingSmoothed ? "pause.fill" : "play.fill", size: 18) {
                        // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
                        MenuBarStatusItem.withMusicPermission { PlaybackCoordinator.shared.userTogglePlayPause() }
                    }
                    controlButton("forward.fill", size: 13) {
                        MenuBarStatusItem.withMusicPermission { MusicPlaybackController.nextTrack() }
                    }
                }
            }
        }
        .padding(12)
        .menuBarPanelCardBackground(cornerRadius: 18)
    }

    /// 压根没有曲目时这张卡的全部内容:两行状态字 + 一颗主动作键。
    ///
    /// 文案与动作跟歌词窗口停播页(`IdleStandbyView`)、灵动岛 hover 展开
    /// (`NotchLyricsView.idleExpandedPanel`)同一套 —— 同一个 `IdlePlaybackActions` 决定
    /// 指哪家播放器、能不能真的「继续播放」(AM / Spotify 有 AppleScript,其余只能「打开 X」)。
    /// 三个展示面对"没在放"说同样的话,不是各写一份。
    ///
    /// 这里不留走带三键:没有曲目时上一首/下一首对空队列是**静默 no-op**,裸 play 同样
    /// 打不着(`IdlePlaybackActions.resume` 为此才是三段式:裸 play → 上次那首 → 都不行就把
    /// 播放器带到前台)。一颗点下去必有可见反应的键,比三颗按不出东西的键有用。
    ///
    /// 点完**不收面板**:放起来之后这张卡当场变成正在播放卡,那是最好的反馈;真走到"把播放器
    /// 带到前台"那条兜底时,失焦监视器会自己把面板收掉。
    private var idleRow: some View {
        let player = IdlePlaybackActions.player
        let canResume = IdlePlaybackActions.canResume(player)
        let name = player.displayName
        let act: () -> Void = {
            if canResume {
                IdlePlaybackActions.resume(player: player)
            } else {
                IdlePlaybackActions.openPlayerApp(player)
            }
        }
        return HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("未在播放"))
                    .font(.system(size: 12, weight: .semibold))
                // 不点名播放器:这里指的是停播前最后用的那家,而用户往往勾了好几家,点名读起来像只有
                // 那一家才行;句子也得短到这一行放得下(同迷你窗停播页那句)。
                Text(L10n.t("播放歌曲后，歌词将自动显示"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 静息态就带底色(baseLevel):面板里其它 Chip 都是次要入口,不悬停看不出是键没关系;
            // 这一颗是这个状态下唯一能做的事,必须一眼认得出来。色相跟圆钮块"开"的那圈同一个
            // Color.accentColor。
            ChipButton(cornerRadius: 8, tint: .accentColor, baseLevel: 0.16, action: act) {
                // 只能「打开」的播放器:键上是那家的图标 +「打开」,全名放进悬停提示 —— 写成
                // 「打开 网易云音乐」既点名、又把左边那句挤没。
                HStack(spacing: 5) {
                    if canResume {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                    } else if let idlePlayerIcon {
                        Image(nsImage: idlePlayerIcon)
                            .resizable()
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    Text(canResume ? L10n.t("继续播放") : L10n.t("打开"))
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 11)
                .frame(height: 28)
            }
            .fixedSize()
            .help(canResume ? L10n.t("继续播放") : String(format: L10n.t("打开 %@"), name))
            .accessibilityLabel(canResume ? L10n.t("继续播放") : String(format: L10n.t("打开 %@"), name))
        }
        .task(id: player) {
            idlePlayerIcon = AppIconResolver.icon(forBundleID: player.bundleIdentifier)
        }
        // 有曲目时卡片靠封面撑高,这里只有一行字。给同样的下限,面板在"放着"和
        // "没放"之间切换时顶部这一块不会突然塌掉一截。
        .frame(minHeight: Self.coverSide)
    }

    // MARK: 当前歌词(带逐字高亮)

    /// 卡片里那一行「现在唱到哪」。填色跟灵动岛/悬浮歌词/歌词窗口是**同一套**
    /// (WordKaraokeGradient + KaraokeFill),不是这里另画一份。
    ///
    /// 通栏放在封面那一行下面、进度条上面:封面右边那一列已经三行(歌名/歌手/专辑),再挤
    /// 一行会比 44pt 的封面高出一截、两边不齐;通栏还天然读成"这张卡的字幕"。
    ///
    /// **定高一行**,状态为空时也占着 —— 歌词几秒一换,不定高的话整张 popover 会跟着一句
    /// 一句地弹高弹矮,比不显示还烦。长句交给 MarqueeText 滚,不换行、不省略号;有逐字时间轴的那一档走图层行(见 layerKaraokeLine)。
    private var lyricLine: some View {
        Group {
            if lyricDisplay == .words {
                layerKaraokeLine(playback.compactLine?.words ?? [])
            } else {
                // id 用**纯文本**:拿会变的东西当 id 会把正在进行的滚动一直打回开头(MarqueeText 头注说的就是这件事)。
                MarqueeText(id: playback.compactLine?.plainText ?? "") {
                    lyricContent
                }
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        // MarqueeText 内层是 GeometryReader,没有固有高度,必须由这里给死。
        .frame(height: 16)
    }

    /// 判定链(以及那三处"必须排在谁前面"的坑)在 LyrimuseCore.LyricsLineDisplay 里,selftest 钉着;这里只负责把结果画出来。
    private var lyricDisplay: LyricsLineDisplay {
        LyricsLineDisplay.resolve(
            // 喂 compactLine:长间奏中段它是 nil,判定链自然落到 .idle —— 那一档的
            // 注释本来就写着「间奏、还没开始」,不用改判定链。
            hasWordTiming: !(playback.compactLine?.words ?? []).isEmpty,
            hasCurrentLine: playback.compactLine != nil,
            isAdBreak: playback.isCurrentTrackAdBreak,
            isRadioTalk: playback.isRadioTalkBreak,
            isInstrumental: playback.isCurrentTrackInstrumental,
            hasNoLyrics: playback.currentTrackHasNoLyrics,
            networkDown: playback.engineNetworkDown,
            hasLyricsContent: playback.hasLyricsContent,
            isPlaying: playback.isPlayingNow
        )
    }

    @ViewBuilder private var lyricContent: some View {
        switch lyricDisplay {
        case .plain:
            // 行级 LRC(没有逐字数据)—— 整行一个颜色,不假装有进度。
            Text(playback.compactLine?.plainText ?? "").foregroundStyle(.primary).lineLimit(1)
        case .adBreak:
            // 这一格**故意留空**:广告时卡片标题已经是「广告中」了(见 displayTitle),
            // 正下方再说一遍是同一件事说两遍。另外三个展示面没有标题行,才需要自己说。
            Text("")
        case .radioTalk:
            statusText(L10n.t("口白"))
        case .instrumental:
            statusText(L10n.t("纯音乐"))
        case .noLyrics:
            statusText(L10n.t("暂无歌词"))
        case .networkDown:
            statusText(L10n.t("网络连接失败"))
        case .searching:
            statusText(L10n.t("搜索歌词中…"))
        case .idle, .words:
            Text("")
        }
    }

    /// 状态占位用三级灰:它不是歌词,不该跟歌名/歌手抢。
    private func statusText(_ text: String) -> some View {
        Text(text).foregroundStyle(.tertiary).lineLimit(1)
    }

    @Environment(\.colorScheme) private var colorScheme

    /// 有逐字时间轴的这一行走 AppKit 图层(`OverlayScrollingLyricRow`,灵动岛主行同一套):整行画成长图,逐字填色与跟唱滚动
    /// 各一条 CAKeyframeAnimation,装好之后主线程不再按帧参与。别换回 MarqueeText 包 30Hz `TimelineView`、每个字一个渐变
    /// `Text`:那样面板开着放歌时每拍都带着整个宿主布局一遍、`layout()` 里再量一遍整块面板(见 06 章决策 54)。
    /// 跟 SwiftUI 版对齐的:字体、已唱 = 面板的 `.primary`、未唱 = 它的 `WordKaraokeGradient.dimOpacity`、靠左、停表判据;
    /// 已唱 / 未唱的交界是硬边(灵动岛、悬浮歌词滚动模式同款)。
    private func layerKaraokeLine(_ words: [SyncedLyricWord]) -> some View {
        let fg = Self.primaryColor(dark: colorScheme == .dark)
        return OverlayScrollingLyricRow(
            spec: .init(
                lineKey: playback.compactLine?.plainText ?? "",
                words: words,
                groups: nil,
                font: .systemFont(ofSize: 11.5, weight: .medium),
                romaFont: .systemFont(ofSize: 11.5, weight: .medium),
                baseColor: fg.withAlphaComponent(fg.alphaComponent * WordKaraokeGradient.dimOpacity),
                fillColor: fg,
                romaBaseColor: fg,
                romaFillColor: fg,
                strokeColor: nil,
                alignment: .leading,
                paused: !playback.isPlayingNow || playback.currentLineFillSettled,
                timingEpoch: playback.lyricsOffsetMs),
            nowMs: Self.lyricsNowMs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: playback.compactLine?.plainText ?? ""))
    }

    /// 面板外观下的 `labelColor`(SwiftUI `.primary` 的 AppKit 值):图层画长图要一个定死的颜色,动态色在那里解析不到面板的外观。
    private static func primaryColor(dark: Bool) -> NSColor {
        var color = NSColor.labelColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return color
    }

    /// 图层行读的播放位置:锚点外推 ?? 暂停冻结位置,再叠歌词时间轴偏移(另外几个逐字展示面同款)。
    private static func lyricsNowMs() -> Int {
        (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: Date())
            ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
            + PlaybackCoordinator.shared.currentLyricsOffsetMs
    }

    /// 封面边长。没在播放那一行的最小高度跟它一致(见 idleRow)。
    private static let coverSide: CGFloat = 52

    @ViewBuilder private var coverView: some View {
        // displayArtworkImage 而不是裸 artworkImage:高清替代优先,口径跟灵动岛/歌词窗口/
        // 悬浮歌词一致(见那个属性的注释;漏了它的表现是同一首歌两处封面不一样)。
        if playback.isCurrentTrackAdBreak {
            // 广告期间封面换成广告标识。底沿用下面"没有封面"那块同一个渐变,只把符号从 music.note 换成
            // megaphone.fill —— 跟灵动岛、歌词窗口是同一枚,同一件事全App 一种画法。
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [.blue.opacity(0.55), .purple.opacity(0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: Self.coverSide, height: Self.coverSide)
                .overlay(Image(systemName: "megaphone.fill").foregroundStyle(.white.opacity(0.85)))
        } else if let image = playback.displayArtworkImage {
            // 按封面边长 × 显示倍率预先重采样成位图再贴,不在运行期缩(半调网点封面在灵动岛小图上
            // 缩成摩尔纹黑斑,这里同一张图、同一种缩法;理由与算法见 ArtworkThumbnail / ArtworkThumbnailCache)。
            let scale = max(1, displayScale)
            Group {
                if let bitmap = ArtworkThumbnailCache.bitmap(for: image, pixelSide: Int((Self.coverSide * scale).rounded())) {
                    Image(decorative: bitmap, scale: scale)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
                .frame(width: Self.coverSide, height: Self.coverSide)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [.blue.opacity(0.55), .purple.opacity(0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: Self.coverSide, height: Self.coverSide)
                .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.85)))
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat,
                               action: @escaping () -> Void) -> some View {
        // cornerRadius 13 = 26pt 高的胶囊,视觉上就是个圆钮;命中区 30×26,
        // 不改尺寸(改了会把卡片撑高)。
        ChipButton(cornerRadius: 13, action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .opacity(playback.controlsWithheldReason == nil ? 1 : PlaybackCoordinator.withheldControlOpacity)
                .frame(width: 30, height: 26)
        }
        // 播放控制被拦下时说明原因;没拦下时不弹(空串不出提示)。
        .help(playback.controlsWithheldReason ?? "")
    }



    // MARK: 圆钮块

    private func knobTile(symbol: String, title: String, subtitle: String? = nil, on: Bool,
                          quick: PanelQuickTarget? = nil,
                          action: @escaping () -> Void) -> some View {
        KnobTile(symbol: symbol, title: title, subtitle: subtitle, on: on,
                 action: action,
                 // 只有能长按的格子才接一个去处;没接的长按 / 右键就当普通按一下(见 KnobTile.body 的 onSecondary)。
                 openQuick: quick.map { target in { setQuickTarget(target) } })
    }

    /// 面板上那些大圆钮块。
    ///
    /// 不是 Button:有快捷设置的格子要分辨"短按 / 长按 / 右键",而 Button 的 action 认的是
    /// 松手 —— 长按到点再松手会把主动作也放一遍。主动作因此走 TileMouseRouter 那层 AppKit
    /// 事件路由,悬停/按下的视觉状态也由它给(格子上盖了一层 NSView 之后,底下 SwiftUI 的
    /// .onHover 未必还收得到)。
    private struct KnobTile: View {
        let symbol: String
        let title: String
        let subtitle: String?
        let on: Bool
        let action: () -> Void
        /// nil = 这个格子没有快捷设置。
        let openQuick: (() -> Void)?

        @State private var hovering = false
        @State private var pressing = false

        var body: some View {
            content
                // 玻璃格,同正在播放卡;悬停 / 按下在玻璃上再叠一层灰(玻璃自带的交互反馈收不到:
                // 鼠标事件都落在上面那层 TileMouseRouter 上)。
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(stateFillLevel))
                )
                .menuBarPanelCardBackground(cornerRadius: 16)
                .overlay {
                    // 事件路由盖在最上面一层:整格都是热区,内容那边不用再加 contentShape。
                    TileMouseRouter(
                        onPrimary: action,
                        onSecondary: { (openQuick ?? action)() },
                        onPressingChange: { pressing = $0 },
                        onHoverChange: { hovering = $0 },
                        toolTip: openQuick == nil ? nil : L10n.t("长按或右键打开设置"))
                }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                // 点击全走盖在上面的 AppKit 视图(TileMouseRouter)的鼠标事件,VoiceOver 的「按下」到不了那里:
                // 把主动作和「长按 / 右键」那一下各挂成一个无障碍动作。
                .accessibilityAction { action() }
                .accessibilityActions {
                    if let openQuick {
                        Button(L10n.t("打开设置"), action: openQuick)
                    }
                }
        }

        /// 静止 → 悬停 → 按下三档,一档比一档实一点点——默认的 Button + buttonStyle
        /// 什么反馈都没给,鼠标放上去看不出这一格是可点的。
        private var stateFillLevel: Double {
            if pressing { return 0.10 }
            return hovering ? 0.05 : 0
        }

        // 去掉了右上角那个悬停才出现的「⋯」。它本来是"这一格还能长按"的提示,
        // 但用户第一眼是当成一个**可点的按钮**在问它什么意思 —— 一个要靠解释才成立的暗示,
        // 本身就说明它没在做提示该做的事,反倒给格子添了噪音。
        //
        // 可发现性还剩两条:悬停时的 tooltip「长按或右键打开设置」(挂在 TileMouseRouter
        // 那层 NSView 上),以及三个形态格子共有的悬停高亮。真要再补,应该补一个说得明白的
        // 形态(比如首次使用时的一次性提示),而不是把这个符号原样放回来。

        private var content: some View {
            // 图标在**上**、文字在下(不是图标在左、文字在右):
            // 面板内容宽 316,一排三个 + 9pt 间距 → 每格 99pt,再扣掉 16pt 内边距、28pt 图标
            // 和 7pt 间隔,留给文字只有 **48pt**。「菜单栏歌词」在 11pt 下要 55pt,靠
            // minimumScaleFactor(0.82) 缩到 9pt 也会被截成「菜单栏...」;英文更没救 ——
            // "Floating Lyrics"/"Menu Bar Lyrics" 缩到 0.72 都还在截断。
            //
            // 竖排时文字独占整格宽度(约 83pt),中英文都完整显示。"每行两个"也能放下,但三个歌词展示形态就
            // 不在同一排了,而它们是同级三兄弟。
            //
            // 代价:每格高一些(图标不跟文字并排占同一行高)。面板纵向余量本来就宽松,换来的是不必为每种
            // 语言各想一套缩写。
            VStack(spacing: 5) {
                SymbolImage(name: symbol, size: 16, weight: .semibold)
                    .foregroundStyle(on ? Color.white : Color.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(on ? AnyShapeStyle(Color.accentColor)
                                         : AnyShapeStyle(Color(nsColor: .tertiarySystemFill)))
                    )
                VStack(spacing: 1) {
                    // 缩字保留但门槛提到 0.85:正常语言都放得下,它只兜"某种翻译特别长"的
                    // 意外,不是常态依赖。
                    Text(title).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    // 副标题可选:三个开关的「已开启/已关闭」去掉了 —— 开关状态
                    // 本来就由图标那个高亮圆底表达(开=白字+强调色底,关=次要色+浅灰底),
                    // 再写一行字是同一件事说两遍。剩下两格的副标题是**真信息**,保留:
                    // 「统计」要报今天多少次,「歌词窗口」要说明点了会发生什么。
                    if let subtitle {
                        Text(subtitle).font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            // 定高:有没有副标题都不影响格子尺寸,同排/跨排都对得齐。不定高的话「统计」
            // (有副标题)会比旁边「歌词窗口」高一截,HStack 里就看得出参差。
            .frame(height: 78)
        }
    }

    // MARK: 底栏(低频入口;完整功能在右键菜单里)
    //
    // 「设置…」+(连着 Last.fm 时)Last.fm 那一格 + 右下角的版本号(见 versionFooterItem)。「歌词管理」在钮块
    // 网格里(见 knobGrid),退出留在右键菜单与 ⌘Q;完整菜单只在右键,面板里不放第二份。

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("gearshape", L10n.t("设置…")) {
                close()
                AppActions.shared.openSettings?()
            }
            if lastfmFooterVisible {
                footerSeparator
                lastfmFooterItem
            }
            footerSeparator
            versionFooterItem
        }
    }

    /// 右下角那一格:平时是版本号,有未安装的新版本时是升级提示;点了都翻到设置的「软件更新」页(06 章决策 46)。
    ///
    /// 状态来自 `SparkleUpdaterManager.availableUpdate`(Sparkle 委托只记状态、不接管显示,
    /// 见那边注释),开窗时取一次快照。升级提示用强调色 + 下载图标,而不是只换文字——跟
    /// Last.fm 出错那格换橙色三角是同一个理由:颜色和图形一起说"这里有事",一格宽度放不下
    /// 更多字。「已下载」和「有新版本」分开写:自动下载开着时 Sparkle 已经把包拉完,点开是
    /// "重启安装"而不是再等一次下载,文案要对得上用户接下来看到的窗口。
    @ViewBuilder private var versionFooterItem: some View {
        if let update = pendingUpdate {
            footerItem(
                // 两个 L10n.t 分开写:三目塞进 L10n.t 里,文案守卫(parity 脚本 / selftest)扫不到字面量。
                title: String(format: update.downloaded ? L10n.t("%@ 已下载，点按安装") : L10n.t("有新版本 %@"),
                              update.version),
                tint: .accentColor, help: L10n.t("打开软件更新"),
                icon: { Image(systemName: "arrow.down.circle.fill").font(.system(size: 10.5)) }
            ) {
                close()
                // 更新界面在设置窗口的「软件更新」页,跟下面版本号那格同一条路翻过去;页面上已经摆着
                // 查到的版本和「立即更新」。
                AppActions.shared.requestSettings(.softwareUpdate)
                AppActions.shared.openSettings?()
            }
        } else {
            footerItem(
                title: String(format: L10n.t("版本 %@"), SparkleUpdaterManager.appVersionString),
                tint: .secondary, help: L10n.t("打开软件更新"),
                icon: { Image(systemName: "info.circle").font(.system(size: 10.5)) }
            ) {
                close()
                // 一次性信箱把设置窗口直接翻到「软件更新」:那一页就是版本号、检查更新和这一版的更新内容。
                AppActions.shared.requestSettings(.softwareUpdate)
                AppActions.shared.openSettings?()
            }
        }
    }

    /// 底栏几项之间的「·」:三项都没有底色,靠它分开。
    private var footerSeparator: some View {
        Text(verbatim: "·")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    /// Last.fm 那一项出不出现(跟 lastfmFooterItem 的分支同一个判据),分隔点跟着它走。
    private var lastfmFooterVisible: Bool {
        switch lastfmStatus {
        case .active, .error, .missingCreds, .warning: return true
        case .notConfigured, .disabled, .none: return false
        }
    }

    /// Last.fm 的连接情况,点了跳设置里的 Last.fm 那一页。
    ///
    /// **只在真的连上(或连过但出了问题)时才出现**:没配过的人底栏就还是两项,不拿一句
    /// "未连接"占着位置 —— 那既不是状态也不是入口,劝人连接是设置里那张卡的事。
    ///
    /// 显示账号名而不是"已连接"三个字:名字本身就说明连上了,而且能一眼看出连的是**哪个**
    /// 账号(多账号切换过的人才知道这有多重要)。回落顺序跟设置页共用 lastfmDisplayName。
    @ViewBuilder private var lastfmFooterItem: some View {
        switch lastfmStatus {
        case .active:
            lastfmButton(tint: .secondary, help: nil) {
                // 必须走 lastfmBadge():那张 PNG 四角是不透明的白,不裁圆角的话深色模式下
                // 就是四个白点。
                lastfmBadge(size: 11)
            }
        case .error(let message), .missingCreds(let message), .warning(let message):
            // 出问题时换成警告图标 + 橙色,而不是只把文字染色 —— 颜色一个人扛不住"这里
            // 出事了"这件事(色弱、以及面板整体本来就是灰调)。具体哪儿出问题交给悬停提示,
            // 这一格宽度放不下一句完整的错误。
            lastfmButton(tint: .orange, help: message) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            }
        // .disabled 是「功能开关」那一页专用的第四态,destinationStatus 永远不构造它
        // (见 DestinationStatus 定义处),这里只是把 switch 补全。
        case .notConfigured, .disabled, .none:
            EmptyView()
        }
    }

    private func lastfmButton<Icon: View>(tint: Color, help: String?,
                                          @ViewBuilder icon: @escaping () -> Icon) -> some View {
        let name = lastfmDisplayName(config: .shared)
        return footerItem(title: name.isEmpty ? "Last.fm" : name, tint: tint, help: help,
                          icon: icon) {
            close()
            // 一次性信箱把设置窗口直接翻到 Last.fm 那一页。
            AppActions.shared.requestSettings(.account(.lastfm))
            AppActions.shared.openSettings?()
        }
    }

    private func footerButton(_ symbol: String, _ title: String,
                              action: @escaping () -> Void) -> some View {
        footerItem(title: title, tint: .secondary, help: nil,
                   icon: { Image(systemName: symbol).font(.system(size: 10.5)) },
                   action: action)
    }

    /// 底栏那一排的通用样式。图标做成 @ViewBuilder 是因为 Last.fm 那一项用的是**品牌图**
    /// (Image(nsImage:))而不是 SF Symbol,不能只收一个符号名。
    private func footerItem<Icon: View>(title: String, tint: Color, help: String?,
                                        // @escaping:图标闭包要被 ChipButton 存下来(它带
                                        // @State,是个真正的 View 而不是就地求值的函数)。
                                        @ViewBuilder icon: @escaping () -> Icon,
                                        action: @escaping () -> Void) -> some View {
        // 底栏一格很宽(约 105pt),压下去整格缩 8% 会很晃 —— pressScale 收到 0.97。悬停底是胶囊。
        ChipButton(cornerRadius: 11, pressScale: 0.97, action: action) {
            HStack(spacing: 4) {
                icon()
                Text(title)
                    .font(.system(size: 10.5))
                    // 账号名可能很长(底栏一格约 105pt),截断而不是把三项挤歪。
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .modifier(OptionalHelp(text: help))
    }
}

/// 面板里所有小控件共用的「悬停/按下」反馈。
///
/// 别用 `.buttonStyle(.plain)`:那个样式**什么反馈都不给**,鼠标压上去、按下去画面一动不动,
/// 手感像按在图片上。这类反馈只要有一处缺,那一处就显得"按不动",所以统一成一份。
///
/// @State 必须住在**每个按钮自己**身上(每个按钮各有各的悬停状态),所以是个独立的
/// View 而不是一个 modifier 函数。
private struct ChipButton<Label: View>: View {
    var cornerRadius: CGFloat = 7
    var pressScale: CGFloat = 0.92
    /// 底色的色相。默认 .primary = 中性灰,深浅色模式下自动反过来。
    var tint: Color = .primary
    /// 静息态就带的底色浓度。默认 0 = 只有悬停/按下才现形,次要入口(走带三键、底栏、
    /// 时间轴微调)全走这一档;主动作键给个非 0 值,不悬停也看得出是一颗键。
    var baseLevel: Double = 0
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) { label().contentShape(Rectangle()) }
            .buttonStyle(ChipStyle(cornerRadius: cornerRadius, hovering: hovering,
                                   pressScale: pressScale, tint: tint, baseLevel: baseLevel))
            // SwiftUI 的 .onHover 在这个 App 里**非活跃状态下也收得到**(灵动岛悬停展开
            // 就是靠它,而那个窗口同样从不激活 App),所以不必像圆钮块那样自己铺一层
            // activeAlways 的 NSTrackingArea。
            .onHover { hovering = $0 }
    }
}

private struct ChipStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let hovering: Bool
    let pressScale: CGFloat
    var tint: Color = .primary
    var baseLevel: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        // 默认色相是 .primary 的低透明度而不是写死的灰:深浅色模式下自动反过来,不用维护
        // 两套值。悬停/按下的增量在两种色相下是同一份,浓度差因此保持一致。
        let level: Double = baseLevel + (pressed ? 0.14 : (hovering ? 0.07 : 0))
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(level))
            )
            // 按下缩一点 —— 悬停给的是"这里可按",按下要给"按到了"。
            .scaleEffect(pressed ? pressScale : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.65),
                       value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - 进度条(播放态外推 / 暂停态冻结,拖动松手才 seek —— 跟灵动岛同一套语义)

/// 独立子视图(性能审计,同灵动岛 NotchScrubber 的拆法):拖动的 @GestureState
/// 和悬停状态在这里自持 —— 挂在面板根视图上的话,拖一次 seek 每个指针事件整面板重估。
/// 时间轴微调那三个控件也住在这里(它们就在进度条下面那行,读的也是同一批值)。
private struct PanelProgressSection: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    /// 能不能拖(`PlaybackCoordinator.acceptsSeek`)。由父视图算好传进来,广告开始、结束那一拍这里跟着重算。
    let seekable: Bool
    let trackLyricsOffsetMs: Int
    let lyricsOffsetStepMs: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 拖进度中手指所在比例;松手才真的 seek。用 @GestureState:手势被取消时自动复位。
    @GestureState private var scrubFraction: Double?
    /// 鼠标在不在进度条上 —— 悬停时把条变粗,跟灵动岛同一套反馈(见 scrubberHeight)。
    @State private var hoveringScrubber = false

    @ViewBuilder var body: some View {
        if let anchor, anchor.durationMs > 0 {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let current = scrubFraction.map { Int($0 * Double(anchor.durationMs)) }
                    ?? anchor.extrapolatedPositionMs(now: context.date)
                progressBar(currentMs: current, durationMs: anchor.durationMs)
            }
        } else if let paused = pausedPositionMs,
                  let duration = durationMs, duration > 0 {
            let current = scrubFraction.map { Int($0 * Double(duration)) } ?? paused
            progressBar(currentMs: current, durationMs: duration)
        }
    }

    private func progressBar(currentMs: Int, durationMs: Int) -> some View {
        let fraction = min(max(Double(currentMs) / Double(durationMs), 0), 1)
        return VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .tertiarySystemFill))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * fraction))
                }
                // 变粗只发生在**外层那个恒高的槽**里(下面 .frame(height: 14)),垂直居中、
                // 布局上一分不多占——高度若直接参与布局,悬停那 2pt 会把时间行和三个播放键
                // 整块往下推一下。
                .frame(height: scrubberHeight)
                .frame(maxHeight: .infinity)
                // reduceMotion 下仍然变粗 —— 那是功能反馈(告诉你这条能拖),不是装饰,
                // 只是不补间。跟灵动岛用同一条弹簧参数。
                .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7),
                           value: scrubberHeight)
                .contentShape(Rectangle())
                .onHover { hoveringScrubber = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($scrubFraction) { value, state, _ in
                            // state 只有**这次手势第一帧**才是 nil(@GestureState 的初始值),
                            // 拿它当"刚按下"的边沿信号给一次触觉;放 onChanged 里会每帧都震。
                            // 跟灵动岛的进度条同一个做法。
                            if state == nil {
                                NSHapticFeedbackManager.defaultPerformer.perform(
                                    .alignment, performanceTime: .now)
                            }
                            state = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { value in
                            let f = min(max(value.location.x / geo.size.width, 0), 1)
                            PlaybackCoordinator.shared.seek(toMs: Int(f * Double(durationMs)))
                        }
                )
                // 播放器不吃外部跳转指令(Amazon Music)、或者在放广告时只显示、不能拖,见 `PlaybackCoordinator.acceptsSeek`。
                .allowsHitTesting(seekable)
            }
            .frame(height: 14)
            HStack {
                Text(Self.mmss(currentMs))
                Spacer()
                offsetControls
                Spacer()
                Text("-" + Self.mmss(max(0, durationMs - currentMs)))
            }
            .font(.system(size: 9.5).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: 歌词时间轴微调(从右键菜单搬进来,用户点的 A)

    /// 歌词早了/晚了半秒时就地校准。右键菜单里还有一个子菜单入口。
    ///
    /// 搬进来的理由是**连点**:这是全 App 最典型的"边听边调" —— 对不上时往往要连点两三下
    /// 才贴合,而 NSMenu 点一下就整个关掉,调三次要开三次菜单、每次还要再进一层子菜单。
    /// 面板不会因为点了按钮而关,可以连着点到满意为止。
    ///
    /// 位置在进度条下面那一行的正中间:那一行只有左右两个时间数字、中间一大片空着,
    /// 是白捡的位置(整张卡片一点没变高);而且那一行的主题本来就是"时间",歌词时间轴是
    /// 时间的一种,摆这儿不突兀。
    private var offsetControls: some View {
        HStack(spacing: 3) {
            // 左减右加 —— 跟中间那个带符号的数字对齐:点右边数字变大,点左边变小。
            // 「正的步长 = 提前」这条口径不在这里定义,跟菜单里的偏移行(`MenuStepperRowView.lyricsOffset`)、
            // 设置页那个 Stepper(▲ = 提前)是同一条。
            //
            // 左右分工按这一行的参照系来定:这一行左右夹着 1:02 / -5:28 两个播放时间,
            // 读者的参照系是播放器——右 = 往前 = 赶快一点。
            //
            // 用 ± 而不是圆箭头或 Apple 的「快退/快进 15 秒」符号(gobackward/goforward):那些在这个位置
            // 容易被读成"调播放进度",± 没有方向隐喻,只说"把这个数字调大/调小"。
            offsetButton("minus", help: nudgeHelp(L10n.t("延后"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: -lyricsOffsetStepMs)
            }
            // 中间这一格必须带「歌词」这个**词**:这一整行左右夹着两个播放时间,两颗按钮夹一个图标在这个
            // 语境里怎么看都像"快退/快进",容易误读成调播放进度,得有个词把它跟播放进度切开。
            //
            // 定宽 64pt:实测最宽的形态是英文两位数负值 "Lyrics -12.5s" = 60.9pt(9.5pt
            // 等宽数字)。不定宽的话两颗按钮会随数值长短左右跳。
            // 调过就换强调色:这首被单独调过,一眼看得出来。
            Text(offsetText)
                .foregroundStyle(trackLyricsOffsetMs != 0 ? AnyShapeStyle(Color.accentColor)
                                                          : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 64)
                // 只有真调过才让它变成「归零」按钮 —— 已经是 0 时点了什么都不会发生,
                // 那种按钮比没有更糟(跟右键菜单里「重置」按需出现同一个道理)。
                .modifier(TapToReset(enabled: trackLyricsOffsetMs != 0) {
                    PlaybackCoordinator.shared.resetLyricsOffset()
                })
            offsetButton("plus", help: nudgeHelp(L10n.t("提前"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: lyricsOffsetStepMs)
            }
        }
    }

    /// 「歌词 +0.5s」/「歌词 0.0s」。
    ///
    /// 值是**这首歌**那一部分(trackLyricsOffsetMs),不含设置里的全局基准 —— 跟右键菜单
    /// 标题同一个理由:显示总和的话,点了「归零」却只回到全局基准,数字跟操作对不上。
    /// 符号走现成的 AppSettings.signedSeconds(它就是给"双向调整"这类地方准备的),免得
    /// 步长设成 0.15s 时这里和别处四舍五入出不同的数。
    private var offsetText: String {
        "\(L10n.t("歌词")) \(AppSettings.signedSeconds(ms: trackLyricsOffsetMs))s"
    }

    private func nudgeHelp(_ verb: String) -> String {
        "\(verb) \(AppSettings.formattedSeconds(ms: lyricsOffsetStepMs))\(L10n.t("秒"))"
    }

    private func offsetButton(_ symbol: String, help: String,
                              action: @escaping () -> Void) -> some View {
        // 16×14,悬停底是小圆(圆角 7)。
        // 尺寸保持原样:这一行的行高就是被这 14pt 撑起来的,动了会连带改卡片高度。
        ChipButton(cornerRadius: 7, pressScale: 0.88, action: action) {
            Image(systemName: symbol)
                // semibold 而不是 medium:± 很细,minus 更是只有一根
                // 横杠,再轻就读成一条分隔线而不是按钮了。
                .font(.system(size: 10, weight: .semibold))
                // 比两边的时间数字略实一点:它们是读数,这两个是能按的。
                .foregroundStyle(Color.primary.opacity(0.7))
                .frame(width: 16, height: 14)
        }
        .help(help)
    }

    /// 「够条件时才变成可点的归零按钮」。写成 modifier 是因为 SwiftUI 里 if/else 两个分支
    /// 会被当成**两个不同身份**的视图,数值跨过 0 的那一下会整块重建、文字闪一下;
    /// 这样只换手势、视图身份不变。
    private struct TapToReset: ViewModifier {
        let enabled: Bool
        let action: () -> Void
        @State private var hovering = false

        func body(content: Content) -> some View {
            content
                // 能归零时悬停垫一层淡底,深浅同 SettingsGlassHoverButtonStyle。
                .background(Capsule().fill(Color.primary.opacity(enabled && hovering ? 0.06 : 0)))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Rectangle())
                .onTapGesture { if enabled { action() } }
                .modifier(OptionalHelp(text: enabled ? L10n.t("点按归零") : nil))
        }
    }

    /// 静止 4pt → 悬停 6pt → 拖动中 7pt。槽高恒为 14pt(见调用点),所以这三档都不动布局。
    private var scrubberHeight: CGFloat {
        if scrubFraction != nil { return 7 }
        return hoveringScrubber ? 6 : 4
    }

    private static func mmss(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
