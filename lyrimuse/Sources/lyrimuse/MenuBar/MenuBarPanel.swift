import AppKit
import SwiftUI
import Combine
import LyrimuseCore

/// 面板的**窄订阅代理**(2026-08-19 性能审计,四个展示面里最后一个接上;完整机制见
/// OverlayPlayback 的注释):PlaybackCoordinator 32 个 @Published 面板实读约 16 个、
/// AppSettings 48 个只读 4 个,整对象订阅会让歌词窗口拖音量、设置页无关滑杆这类写入
/// 打醒整个面板 body。只转发实读字段,值类型一律 removeDuplicates。
///
/// ⚠️ sink 只用参数值,不回读源属性(@Published willSet 时机,回读是旧值)。
///
/// anchor 入订阅(同 NotchPlayback 的取舍:progressArea 要在 body 里按锚点存在性分
/// 播放/暂停两条分支,而锚点只在换歌/seek 时重建,低频);currentLyricsOffsetMs 仍由
/// 逐字填色的 TimelineView 闭包直读协调器。resolvedPlayerIcon/DisplayName 不是
/// @Published(计算属性),body 直读 shared 即可,不经代理。
/// 三个悬浮层开关转发进来只为触发 body 重估 —— LyricsSurface.isEnabled 自己读
/// AppSettings.shared 的存储值(body 重估发生在落库后,读到的是新值)。
@MainActor
private final class PanelPlayback: ObservableObject {
    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var currentLine: SyncedLyricLine?
    /// 单行展示面取这一行,见 CompactLyricLead。面板那一格也是**定高单行**,跟灵动岛/
    /// 菜单栏文字同一处境,所以一起走这套。
    @Published private(set) var compactLine: SyncedLyricLine?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    @Published private(set) var currentLineFillSettled = true
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var anchor: ProgressAnchor?
    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?
    @Published private(set) var trackLyricsOffsetMs = 0
    // ---- 来自 AppSettings(只挑面板实读的四项) ----
    @Published private(set) var classicOverlayEnabled = false
    @Published private(set) var notchOverlayEnabled = false
    @Published private(set) var showLyricsInMenuBar = false
    @Published private(set) var lyricsOffsetStepMs = 200
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$currentLine.removeDuplicates().sink { [weak self] in self?.currentLine = $0 },
            p.$compactLine.removeDuplicates().sink { [weak self] in self?.compactLine = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            p.$anchor.sink { [weak self] in self?.anchor = $0 },
            p.$pausedPositionMs.removeDuplicates().sink { [weak self] in self?.pausedPositionMs = $0 },
            p.$currentDurationMs.removeDuplicates().sink { [weak self] in self?.currentDurationMs = $0 },
            p.$trackLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.trackLyricsOffsetMs = $0 },
            s.$classicOverlayEnabled.removeDuplicates().sink { [weak self] in self?.classicOverlayEnabled = $0 },
            s.$notchOverlayEnabled.removeDuplicates().sink { [weak self] in self?.notchOverlayEnabled = $0 },
            s.$showLyricsInMenuBar.removeDuplicates().sink { [weak self] in self?.showLyricsInMenuBar = $0 },
            s.$lyricsOffsetStepMs.removeDuplicates().sink { [weak self] in self?.lyricsOffsetStepMs = $0 },
        ]
    }
}

// 菜单栏左键面板(2026-08-19,用户从九个设计方向里选定 F「控制中心风」):
// 一张全宽「正在播放」卡 + 2×2 大圆钮块(开关/入口,带状态副文字) + 一条细底栏。
// 右键仍是原来那棵完整 NSMenu(MenuBarStatusMenu)——所有低频功能的家不动,
// 面板只承载高频:看一眼在放什么、切歌/拖进度、开关两种歌词悬浮层、进统计。
//
// 用 NSPopover 而不是自建无边框 NSPanel:transient(点外面自动收)、锚定状态栏按钮、
// 系统材质都是免费的,跟控制中心的观感也最接近。
@MainActor
final class MenuBarPanelController {
    private var popover: NSPopover?
    private var closeObserver: NSObjectProtocol?
    /// 「点到别的 App 上」的收起路径。NSPopover 的 .transient 只管 App 语境内的点击 ——
    /// 菜单栏 accessory App 的面板弹出时**不激活 App**,点到别的应用上 transient 根本
    /// 不触发(2026-08-19 用户实测「失焦后不缩回」)。全局监视器只收得到**别的 App**
    /// 的事件,恰好补上这一半;本 App 内其它窗口的点击仍由 transient 行为处理。
    private var outsideClickMonitor: Any?
    /// cmd-tab 这类不带点击的失焦也要收 —— App 真的活跃过时靠这个通知兜住。
    private var resignActiveObserver: NSObjectProtocol?
    /// 切 Space 也要收 —— 面板现在会出现在每个 Space 上(见 toggle 里 collectionBehavior
    /// 那段),不收的话切走之后它还挂在那儿。⚠️ 挂在 NSWorkspace 的通知中心,不是
    /// NotificationCenter.default,拆的时候也要从那边拆。
    private var spaceChangeObserver: NSObjectProtocol?
    /// 面板开/关 —— 状态栏那行滚动歌词要跟着反白,跟 NSMenu 的 delegate 回调同一件事。
    var onVisibilityChange: ((Bool) -> Void)?

    func toggle(relativeTo button: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let content = MenuBarPanelView(close: { [weak pop] in pop?.performClose(nil) })
        pop.contentViewController = FirstMouseHostingController(rootView: content)
        popover = pop
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: pop, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.teardownDismissWatchers()
                self.onVisibilityChange?(false)
                // 面板收起即整树释放(2026-08-19 性能审计):下次 toggle 本来就是全新建
                // (onAppear 快照语义还依赖这一点),保留旧树零复用收益,只是让两条
                // @ObservedObject 订阅在离窗死树上继续挨 objectWillChange 派发、并常驻
                // 一份视图树+NSPopover 内存。observer 自己也一并拆掉,不再等下次开面板。
                self.popover = nil
                if let closeObserver = self.closeObserver {
                    NotificationCenter.default.removeObserver(closeObserver)
                    self.closeObserver = nil
                }
            }
        }
        // 两道「失焦收起」:落在别的 App 上的任何按下 / 本 App 失活(cmd-tab)。
        // 都挂在弹出这一刻、由 didClose 统一拆 —— 面板不在时零常驻监听。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak pop] _ in
            Task { @MainActor in pop?.performClose(nil) }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak pop] _ in
            Task { @MainActor in pop?.performClose(nil) }
        }
        // 切 Space 也要收起。这是下面 collectionBehavior 连带出来的:面板从此会跟着用户
        // 出现在**每个** Space 上,切走之后它还挂在那儿就成了甩不掉的残影。而已有的两道
        // 监视器都接不住这种情况——切 Space 既不是"点到别的 App 上"(没有鼠标按下),
        // App 也从来没活跃过(所以不会 resign)。
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak pop] _ in
            Task { @MainActor in pop?.performClose(nil) }
        }
        onVisibilityChange?(true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // ⚠️ 2026-08-31 修「别的 App 全屏时面板打不开」(用户报)。
        //
        // 真实症状不是"点了没反应",而是**面板弹在了桌面 Space 上**:日志里
        // `panel opened` 照常打出来(说明点击到位、popover 也 show 了),用户在全屏里看不见,
        // 于是再点一下——第二下走 toggle 开头 `popover.isShown` 那个分支把它关掉。日志上就是
        // 一对间隔一两秒的 opened/closed(17:22:28→17:22:30、17:22:57→17:22:58 实测)。
        //
        // 成因:NSPopover 自建的窗口 collectionBehavior 是默认的"受管",进不了别的 App 的
        // 全屏 Space;而这个面板刻意**不** NSApp.activate()(理由见下面 FirstMouseHostingView
        // 那段注释),没有激活就不会切 Space,窗口只能落在桌面 Space 上。别家菜单栏 App 没这个
        // 毛病,多半是它们 activate 了——代价是把用户正在用的全屏 App 顶掉,这里不接受。
        //
        // 用的是跟 LyricsOverlayWindow.swift:26 / NotchLyricsWindow.swift:47 同一套 flag 里
        // 相关的那两位:.fullScreenAuxiliary 给"能进别人全屏 Space"的许可,.canJoinAllSpaces
        // 让它落在**当前**这个 Space 上,两个缺一不可。刻意不带那边另外两位:.stationary 是给
        // 常驻悬浮窗防 Mission Control 搬动的,套在一个活几秒的 popover 上反而像卡住的残影;
        // .ignoresCycle 管 Cmd-` 轮转,popover 窗口本来就不在那张表里。
        //
        // ⚠️ 只能放在 show **之后**:那个窗口是 show 内部现建的,willShow 时
        // `contentViewController?.view.window` 还是 nil。也不需要像 LyricsWindowView 那样
        // 持续守护——每次 toggle 都是全新的 NSPopover(didClose 里置 nil),AppKit 不会回写,
        // 跟着每次弹出设一次就够。formUnion 而不是直接赋值:别把 AppKit 自己塞的位覆盖掉。
        pop.contentViewController?.view.window?.collectionBehavior
            .formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    private func teardownDismissWatchers() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        resignActiveObserver = nil
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        }
        spaceChangeObserver = nil
    }
}

/// 让面板里的 SwiftUI 控件也「第一下就算数」。
///
/// 菜单栏面板弹出时**不激活 App**(见上面 outsideClickMonitor 那段)。AppKit 的规矩是:
/// 非活跃 App 里,鼠标按下先问被点中的那个视图 `acceptsFirstMouse` —— 返回 false 的话
/// 这一下**只用来激活 App**,不会传给控件。SwiftUI 的控件全都住在 NSHostingView 这一层
/// 里,它默认返回 false,于是面板里除了三个圆钮块(TileMouseRouter 自己接了 first mouse)
/// 之外的东西 —— 播放键、进度条、底栏、快捷设置里的滑杆/开关 —— 都得先点一下"唤醒"、
/// 再点一下才动。2026-08-19 用户报的「打开之后没有马上获得焦点,需要点一下才行」就是这个。
///
/// 不走 `NSApp.activate()` 那条路:那会把用户正在用的 App 顶到后台,只为了瞄一眼面板,
/// 代价比问题本身还大(系统控制中心也不激活任何 App)。这里只是让这一层认下第一次点击,
/// 前台 App 是谁完全不变。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 只为把上面那层换进去。仍然用 NSHostingController 而不是裸 NSViewController:
/// popover 的高度是跟着 SwiftUI 内容变的(展开/收起快捷设置那一下),这套自动尺寸
/// 传递归它管,裸控制器接不上。
private final class FirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }
}

// MARK: - 面板本体

private struct MenuBarPanelView: View {
    // ⚠️ 跟 MenuBarStatusMenu 文件头同一条不变量:**渲染路径只读 AppSettings/
    // PlaybackCoordinator,绝不碰两个悬浮窗控制器的 .shared**(碰了就把用户关掉的
    // 悬浮窗凭空建出来)。动作闭包里可以碰 —— 那是用户主动要求。
    // 不整对象订阅 PlaybackCoordinator/AppSettings —— 见 PanelPlayback 的注释。
    @StateObject private var playback = PanelPlayback()
    let close: () -> Void
    // 长按 / 右键某个「歌词展示形态」的格子之后,面板下半部分换成它自己的快捷设置;
    // nil = 正常的钮块网格。见 MenuBarPanelQuickSettings.swift。
    @State private var quickTarget: LyricsSurface?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Last.fm 连接情况,开窗那一刻取一次快照(见 lastfmFooterItem)。
    @State private var lastfmStatus: DestinationStatus?

    var body: some View {
        VStack(spacing: 9) {
            nowPlayingCard
            // 「正在播放」卡不参与切换 —— 它是这张面板的身份,连它一起换掉就像换了一扇窗;
            // 留着它高度落差也更小(快捷设置比两排钮块还矮一点)。
            if let quickTarget {
                PanelQuickSettings(
                    surface: quickTarget,
                    toggle: toggleAction(for: quickTarget),
                    back: { setQuickTarget(nil) },
                    close: close)
            } else {
                knobGrid
                footer
            }
        }
        .padding(10)
        .frame(width: 336)
        // 只在弹出这一刻取一次 —— 面板每次打开都是新建的一份视图,所以"每次开窗刷新一次"
        // 已经够了,不用为它常驻订阅 ConfigStore/LastfmConnectController/状态文件观察器
        // 三个东西(这张面板的渲染路径一直刻意只依赖 AppSettings/PlaybackCoordinator)。
        //
        // 代价说清楚:面板**开着的时候**在设置里连上/断开 Last.fm,这一项不会当场跟着变,
        // 收起再开就对了。而 destinationStatus 的判定本身跟设置页共用同一个函数,不会出现
        // 两处口径不一致。
        .onAppear {
            lastfmStatus = destinationStatus(
                for: .lastfm,
                config: .shared,
                lastfmConnect: .shared,
                // 这里直接读那个带 mtime 缓存的静态量,不走 LastfmMirrorStatusWatcher:
                // 那个观察器是给**常驻**视图用的(文件被 collector 自愈删掉时要能推一次
                // 更新);这张面板活不过一次开合,读一次当下的状态正好。
                mirrorInfo: LastfmMirrorStatus.current)
        }
    }

    /// 展开 / 收起快捷设置。
    ///
    /// ⚠️ **不包 withAnimation**(2026-08-19 改)。原来包了 0.15s 的 easeOut,想让面板高度
    /// 变化柔和一点;但 withAnimation 开的是一个**事务**,这一帧里所有可动画的变化都会被它
    /// 接管 —— 包括「正在播放」卡里那行歌词(跑马灯的横向偏移、逐字填色的渐变)。用户报的
    /// 「收起快捷设置时整行歌词跳一下」就是这么来的:歌词行本来跟这次展开/收起毫无关系,
    /// 却被顺带补间了一次。
    ///
    /// 而这个动画本来也没什么用:面板高度是 NSPopover 的窗口尺寸,归 AppKit 自己的
    /// resize 动画管(pop.animates),SwiftUI 这一层补间不到它。等于是白担了副作用。
    private func setQuickTarget(_ surface: LyricsSurface?) {
        quickTarget = surface
    }

    /// 某个形态"开 / 关"这一下该做什么。抽成一份是因为格子和快捷设置头部那个开关必须是
    /// **同一种**行为 —— 尤其菜单栏歌词那条"先收面板"的绕路,两处各写一遍必然走岔。
    ///
    /// ⚠️ 这里只是**造闭包**、不执行,文件头那条"渲染路径绝不碰两个悬浮窗控制器 .shared"
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
                // 先收面板、等 popover 退场再切(2026-08-19 实测:面板开着切,状态栏项被锚着的
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
            // 三种歌词展示形态凑成完整一排(2026-08-19 用户提议加菜单栏歌词):它们本来
            // 就是同级三兄弟;而且菜单栏这个开关的效果就发生在面板正上方,点完立刻看得见。
            HStack(spacing: 9) {
                surfaceTile(.overlay)
                surfaceTile(.notch)
                surfaceTile(.menuBar)
            }
            HStack(spacing: 9) {
                // 不带副文字(2026-08-19 用户要求去掉「点击打开」):钮块本来就是按钮,
                // "点击打开"是同义反复,去掉后跟第一排三个形态格的高度也更齐。
                knobTile(symbol: "text.quote", title: L10n.t("歌词窗口"), on: false) {
                    close()
                    AppActions.shared.openLyricsWindow?()
                }
                // 2026-08-19 用户拍板:这一格从「统计」换成「歌词管理」(统计入口收进
                // 设置窗口的 Last.fm 账号页),底栏那条「歌词管理…」随之撤掉,不留双入口。
                knobTile(symbol: "music.note.list", title: L10n.t("歌词管理"), on: false) {
                    close()
                    AppActions.shared.openLyricsManager?()
                }
            }
        }
    }

    /// 三个「歌词展示形态」的格子:短按 = 开 / 关,长按或右键 = 翻到它自己的快捷设置。
    private func surfaceTile(_ surface: LyricsSurface) -> some View {
        knobTile(symbol: surface.symbolName, title: surface.panelTitle,
                 on: surface.isEnabled, quick: surface,
                 action: toggleAction(for: surface))
    }

    // MARK: 正在播放卡

    // 广告插播时这张卡的三行文案。判据 isCurrentTrackAdBreak 由 LocalPlaybackSource 给
    // (字段启发式 + 同曲棘轮 + AppleScript `spotify url` 权威分类)。
    //
    // 2026-08-19:用户报的「广告这里要显示广告而不是一个横」指的就是这张卡 —— 我第一轮
    // 改到了 LyricsWindowView(那处也确实缺,一并留着),但没解决这里。灵动岛
    // (NotchLyricsView)和歌词窗口歌词区(emptyStateSpec)早就是「广告中」了,口径统一。
    private var displayTitle: String {
        if playback.isCurrentTrackAdBreak { return L10n.t("广告中") }
        // 没歌在放就留白,不再摆一个占位破折号(2026-08-19 用户要求)。那一横不携带任何
        // 信息:封面已经是空封面、歌手/专辑也都是空的,"没在放"这件事已经说得很清楚了,
        // 再画一横反倒像"有一首歌但名字读不出来"。
        //
        // 仍然返回一个空串、让这个 Text 留在原地,而不是整行 if 掉:它占着一行行高,
        // 文字块高度不随播放状态跳动,下面那排控制按钮才不会上下弹。
        return playback.title
    }

    /// 广告时歌手/专辑都留空,不展示广告物料的名字(跟灵动岛一致的口径)。不是多余判断:
    /// 广告有时会带全 artist/album 字段,不显式清掉就会冒出广告主的名字。
    private var displayArtist: String {
        playback.isCurrentTrackAdBreak ? "" : playback.artist
    }

    private var displayAlbum: String {
        playback.isCurrentTrackAdBreak ? "" : playback.album
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
            // 点封面 → 打开歌词窗口(2026-08-19 用户要求,跟灵动岛上两处封面同一动作);
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
                Text(displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                // 2026-08-19 去掉了这一行右边的「● 记录中」标识(用户要求)。原来是
                // 红点 + 文案跟在歌手后面,靠一个 HStack 拼起来;去掉之后这里只剩歌手
                // 一个 Text,外层那层 HStack 也一并拆掉,不留空壳容器。
                //
                // 顺带清掉了只服务它的 recording 计算属性,以及只被 recording 用到的
                // features(FeatureSettingsStore)订阅 —— 留着的话这张面板会因为任何
                // 无关的功能开关变化白重渲染一次。
                Text(displayArtist)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // 专辑行(2026-08-19 用户要求)。只在真有专辑名时才渲染 —— Spotify 常常
                // 不上报专辑,占一个空行会让卡片凭空高一截、看着像排版错了。
                //
                // 用 .tertiary 而不是 .secondary:标题(primary)→ 歌手(secondary)→
                // 专辑(tertiary)三级递减,跟「最近记录」列表里专辑列的处理一致。
                // 加上这一行之后文字块约 45pt,正好跟 44pt 的封面齐平(原来只有两行、
                // 比封面矮一截),所以卡片总高几乎不变。
                if !displayAlbum.isEmpty {
                    Text(displayAlbum)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // 来源角标:右上角放播放器的真实 App 图标(2026-08-19 用户拍板,比文字
            // 胶囊更好认更安静),悬停给名字。放卡片内容内部而不是 .overlay ——
            // 设置页实测过卡片背景吞外挂 overlay 的坑,别再赌。
            // 2026-08-19 加点击(用户要求):点角标把这个播放器唤到前台,顺手收面板
            // (跳去别的 App 了,面板留着也只会被失焦监视器收掉,不如主动收干净)。
            if let icon = PlaybackCoordinator.shared.resolvedPlayerIcon {
                Button {
                    PlaybackCoordinator.shared.openResolvedPlayerApp()
                    close()
                } label: {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(PlaybackCoordinator.shared.resolvedPlayerDisplayName ?? "")
            }
    }
    }

    private var nowPlayingCard: some View {
        VStack(spacing: 8) {
            // 什么都没在放时,这上半张卡整块不渲染(2026-08-21 用户要求"那个无意义的音符
            // 不要占位置")。
            //
            // 只藏掉音符占位图不够:藏了之后原地还剩两行**空文本**(歌名/歌手,见
            // displayTitle 的注释——那两行是刻意留白的)和 VStack 给它们的间距,以及一条
            // 同样空着的定高歌词行(lyricContent 的 .idle 分支画的是 Text(""))。
            // 所以整块一起收,留下的是真有用的那部分:进度条(没时长时自己不渲染)+ 三键
            // (可以按播放键把上一首接着放)。
            //
            // ⚠️ 判据是"压根没有曲目"而不是"没有封面":播放中拿不到封面的曲目(播客/取图
            // 失败)照旧要显示那个渐变占位图 —— 那时候占位图是有意义的(它代表一首真的歌),
            // 而卡片右边还有歌名/歌手撑着。广告插播也照旧显示(标题是「广告中」,有东西在放)。
            if !isIdleNoTrack {
                trackHeader
                lyricLine
            }
            // 进度条独立成 PanelProgressSection 子视图(2026-08-19 性能审计):拖动/悬停
            // 状态自持,拖一次 seek 不再整面板逐指针事件重估。
            PanelProgressSection(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                trackLyricsOffsetMs: playback.trackLyricsOffsetMs,
                lyricsOffsetStepMs: playback.lyricsOffsetStepMs)
            HStack(spacing: 28) {
                controlButton("backward.fill", size: 13) { MusicPlaybackController.previousTrack() }
                controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill", size: 18) {
                    // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
                    PlaybackCoordinator.shared.userTogglePlayPause()
                }
                controlButton("forward.fill", size: 13) { MusicPlaybackController.nextTrack() }
            }
        }
        .padding(10)
        .background(Color(nsColor: .quaternarySystemFill),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 当前歌词(2026-08-19 用户要求,带逐字高亮)

    /// 卡片里那一行「现在唱到哪」。填色跟灵动岛/悬浮歌词/歌词窗口是**同一套**
    /// (WordKaraokeGradient + KaraokeFill),不是这里另画一份。
    ///
    /// 通栏放在封面那一行下面、进度条上面:封面右边那一列已经三行(歌名/歌手/专辑),再挤
    /// 一行会比 44pt 的封面高出一截、两边不齐;通栏还天然读成"这张卡的字幕"。
    ///
    /// **定高一行**,状态为空时也占着 —— 歌词几秒一换,不定高的话整张 popover 会跟着一句
    /// 一句地弹高弹矮,比不显示还烦。长句交给 MarqueeText 滚,不换行、不省略号。
    private var lyricLine: some View {
        // id 用**纯文本**而不是带填色进度的东西:同一句里逐字变色是每秒 30 次的高频刷新,
        // 拿它当 id 会把正在进行的滚动一直打回开头(MarqueeText 头注说的就是这件事)。
        MarqueeText(id: playback.compactLine?.plainText ?? "") {
            lyricContent
        }
        .font(.system(size: 11.5, weight: .medium))
        // MarqueeText 内层是 GeometryReader,没有固有高度,必须由这里给死。
        .frame(height: 16)
    }

    @ViewBuilder private var lyricContent: some View {
        // 判定链(以及那三处"必须排在谁前面"的坑)在 LyrimuseCore.LyricsLineDisplay 里,
        // selftest 钉着;这里只负责把结果画出来。
        switch LyricsLineDisplay.resolve(
            // 喂 compactLine:长间奏中段它是 nil,判定链自然落到 .idle —— 那一档的
            // 注释本来就写着「间奏、还没开始」,不用改判定链。
            hasWordTiming: !(playback.compactLine?.words ?? []).isEmpty,
            hasCurrentLine: playback.compactLine != nil,
            isAdBreak: playback.isCurrentTrackAdBreak,
            isInstrumental: playback.isCurrentTrackInstrumental,
            hasNoLyrics: playback.currentTrackHasNoLyrics,
            networkDown: playback.collectorNetworkDown,
            hasLyricsContent: playback.hasLyricsContent,
            isPlaying: playback.isPlayingNow
        ) {
        case .words:
            karaokeLine(playback.compactLine?.words ?? [])
        case .plain:
            // 行级 LRC(没有逐字数据)—— 整行一个颜色,不假装有进度。
            Text(playback.compactLine?.plainText ?? "").foregroundStyle(.primary).lineLimit(1)
        case .adBreak:
            // 这一格**故意留空**:广告时卡片标题已经是「广告中」了(见 displayTitle),
            // 正下方再说一遍是同一件事说两遍。另外三个展示面没有标题行,才需要自己说。
            Text("")
        case .instrumental:
            statusText(L10n.t("纯音乐"))
        case .noLyrics:
            statusText(L10n.t("暂无歌词"))
        case .networkDown:
            statusText(L10n.t("网络连接失败"))
        case .searching:
            statusText(L10n.t("搜索歌词中…"))
        case .idle:
            Text("")
        }
    }

    /// 状态占位用三级灰:它不是歌词,不该跟歌名/歌手抢。
    private func statusText(_ text: String) -> some View {
        Text(text).foregroundStyle(.tertiary).lineLimit(1)
    }

    private func karaokeLine(_ words: [SyncedLyricWord]) -> some View {
        // 帧率上限走 WordKaraokeGradient.refreshInterval(30Hz),跟另外三处逐字视图同一个:
        // 裸 .animation 是显示器刷新率(这台 120Hz),实测会把主线程吃满(见那边的注释)。
        // paused: 没在放就不空转 —— 面板可能被开着晾在那儿。
        // paused 第二条件(2026-08-19):行填完到换行前视觉零变化,把表停掉 —— 四个逐字
        // 展示面的同款停表,面板是最后一个接上的(悬浮窗/灵动岛同字段,歌词窗口有等价机制)。
        TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                paused: !playback.isPlayingNow || playback.currentLineFillSettled)) { context in
            // 必须带上 currentLyricsOffsetMs:不加的话"当前唱到哪个字"和"这个字填了多少"
            // 用的时间基准对不上,会出现填到一半卡住(跟悬浮歌词/灵动岛同一段注释)。
            // anchor/offset 直读协调器不经代理:闭包按帧重跑,每帧读到的都是最新值。
            // ?? pausedPositionMs:暂停基准兜底(2026-08-19,四个展示面同款,理由见
            // LyricsOverlayView.mainLine 同位置注释)。
            let ms = (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: context.date)
                ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
                + PlaybackCoordinator.shared.currentLyricsOffsetMs
            // 渐变素材每帧只取一次,纯色词跨帧复用同一实例(2026-08-20 性能审计,见
            // WordKaraokeGradient.Palette 注释);indices 代替 Array(enumerated()),
            // 少一次每帧纯为当 id 的数组物化。
            let palette = WordKaraokeGradient.palette(fg: .primary)
            HStack(spacing: 0) {
                ForEach(words.indices, id: \.self) { i in
                    let fraction = WordKaraokeGradient.fillFraction(for: words[i], atMs: ms)
                    Text(words[i].text)
                        .foregroundStyle(palette.style(
                            left: fraction - WordKaraokeGradient.wordEdgeSoftenBand,
                            right: fraction + WordKaraokeGradient.wordEdgeSoftenBand))
                }
            }
            .lineLimit(1)
            // 掐掉一切**环境**动画事务(2026-08-19 用户实测:从快捷设置返回的那一下,
            // 正在填色的单词偶尔"跳一下")—— setQuickTarget 的 withAnimation 事务会把
            // 同一帧里撞上的 30Hz 填色跳变也做成 0.15s 插值。填色是离散刷新,每帧直接
            // 落到新位置,永远不该吃任何外来动画。只挂在这个填色 HStack 上:外层
            // MarqueeText 自己的滚动动画不经过这里,不受影响。
            // (同款坑见 memory:swiftui-implicit-animation-at-ancestor-animates-
            // unrelated-layout —— 祖先事务连带 animate 子树里不相干的变化。)
            .transaction { $0.animation = nil }
        }
    }

    @ViewBuilder private var coverView: some View {
        if let image = playback.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [.blue.opacity(0.55), .purple.opacity(0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.85)))
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat,
                               action: @escaping () -> Void) -> some View {
        // cornerRadius 13 = 26pt 高的胶囊,视觉上就是个圆钮;沿用原来的 30×26 命中区,
        // 不改尺寸(改了会把卡片撑高)。
        ChipButton(cornerRadius: 13, action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 26)
        }
    }



    // MARK: 圆钮块

    private func knobTile(symbol: String, title: String, subtitle: String? = nil, on: Bool,
                          quick: LyricsSurface? = nil,
                          action: @escaping () -> Void) -> some View {
        KnobTile(symbol: symbol, title: title, subtitle: subtitle, on: on,
                 action: action,
                 // 只有能长按的格子才接一个去处;「歌词窗口」「统计」是纯动作,长按/右键
                 // 就当普通按一下(见 KnobTile.body 的 onSecondary)。
                 openQuick: quick.map { surface in { setQuickTarget(surface) } })
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
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: fillColor))
                )
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
        }

        /// 静止 → 悬停 → 按下三档系统填充色,一档比一档实一点点。原来是 Button,靠
        /// buttonStyle 什么反馈都没给,鼠标放上去看不出这一格是可点的。
        private var fillColor: NSColor {
            if pressing { return .secondarySystemFill }
            return hovering ? .tertiarySystemFill : .quaternarySystemFill
        }

        // 2026-08-19 去掉了右上角那个悬停才出现的「⋯」。它本来是"这一格还能长按"的提示,
        // 但用户第一眼是当成一个**可点的按钮**在问它什么意思 —— 一个要靠解释才成立的暗示,
        // 本身就说明它没在做提示该做的事,反倒给格子添了噪音。
        //
        // 可发现性还剩两条:悬停时的 tooltip「长按或右键打开设置」(挂在 TileMouseRouter
        // 那层 NSView 上),以及三个形态格子共有的悬停高亮。真要再补,应该补一个说得明白的
        // 形态(比如首次使用时的一次性提示),而不是把这个符号原样放回来。

        private var content: some View {
            // 图标在**上**、文字在下(2026-08-19 改)。原来是图标在左、文字在右:
            // 面板内容宽 316,一排三个 + 9pt 间距 → 每格 99pt,再扣掉 16pt 内边距、28pt 图标
            // 和 7pt 间隔,留给文字只有 **48pt**。「菜单栏歌词」在 11pt 下要 55pt,靠
            // minimumScaleFactor(0.82) 缩到 9pt 勉强够,实测仍被截成「菜单栏...」;英文更
            // 没救 —— "Floating Lyrics"/"Menu Bar Lyrics" 缩到 0.72 都还在截断。
            //
            // 改成竖排之后文字独占整格宽度(约 83pt),中英文都完整显示。离线四方案并排渲过
            // (图标在左 / 收紧度量+缩字 / 图标在上 / 每行两个),只有这一种两种语言都过关:
            // "每行两个"也能放下,但三个歌词展示形态就不在同一排了,而它们是同级三兄弟。
            //
            // 代价:每格高一些(图标不再跟文字并排占同一行高)。菜单栏面板是 popover,
            // 纵向余量本来就宽松,换来的是不必为每种语言各想一套缩写。
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(on ? AnyShapeStyle(Color.accentColor)
                                         : AnyShapeStyle(Color(nsColor: .quaternarySystemFill)))
                    )
                VStack(spacing: 1) {
                    // 缩字保留但门槛提到 0.85:正常语言都放得下,它只兜"某种翻译特别长"的
                    // 意外,不再是常态依赖。
                    Text(title).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    // 副标题可选(2026-08-19):三个开关的「已开启/已关闭」去掉了 —— 开关状态
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
    // 2026-08-19 用户拍板收敛成两项:「歌词管理…」上移进钮块网格(见 knobGrid),
    // 「更多」撤掉(完整菜单本来就有右键这个入口,面板里再放一份是双入口),
    // 换成直接的「退出」。

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("gearshape", L10n.t("设置…")) {
                close()
                AppActions.shared.openSettings?()
            }
            lastfmFooterItem
            footerButton("rectangle.portrait.and.arrow.right", L10n.t("退出 Lyrimuse")) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Last.fm 的连接情况(2026-08-19 用户要求),点了跳设置里的 Last.fm 那一页。
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
                // 就是四个白点(2026-08-19 用户报的正是这一处)。
                lastfmBadge(size: 11)
            }
        case .error(let message), .missingCreds(let message):
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
            // 一次性信箱把设置窗口直接翻到 Last.fm 那一页,跟原来「统计」那一格同一条路。
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
        // 底栏一格很宽(约 105pt),压下去整格缩 8% 会很晃 —— pressScale 收到 0.97。
        ChipButton(cornerRadius: 6, pressScale: 0.97, action: action) {
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
/// 2026-08-19 用户:「这块交互逻辑感觉做的都不够」。原来播放键/底栏/时间轴箭头全是
/// `.buttonStyle(.plain)` —— 那个样式**什么反馈都不给**:鼠标压上去、按下去,画面一动
/// 不动,手感像按在图片上。这类反馈只要有一处缺,那一处就显得"按不动",所以统一成一份。
///
/// @State 必须住在**每个按钮自己**身上(每个按钮各有各的悬停状态),所以是个独立的
/// View 而不是一个 modifier 函数。
private struct ChipButton<Label: View>: View {
    var cornerRadius: CGFloat = 7
    var pressScale: CGFloat = 0.92
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) { label().contentShape(Rectangle()) }
            .buttonStyle(ChipStyle(cornerRadius: cornerRadius, hovering: hovering,
                                   pressScale: pressScale))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        // 用 .primary 的低透明度而不是写死的灰:深浅色模式下自动反过来,不用维护两套值。
        let level: Double = pressed ? 0.14 : (hovering ? 0.07 : 0)
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(level))
            )
            // 按下缩一点 —— 悬停给的是"这里可按",按下要给"按到了"。
            .scaleEffect(pressed ? pressScale : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.65),
                       value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - 进度条(播放态外推 / 暂停态冻结,拖动松手才 seek —— 跟灵动岛同一套语义)

/// 独立子视图(2026-08-19 性能审计,同灵动岛 NotchScrubber 的拆法):拖动的 @GestureState
/// 和悬停状态在这里自持 —— 原来挂在面板根视图上,拖一次 seek 每个指针事件整面板重估。
/// 时间轴微调那三个控件也住在这里(它们就在进度条下面那行,读的也是同一批值)。
private struct PanelProgressSection: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
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
                    Capsule().fill(Color(nsColor: .quaternarySystemFill).opacity(0.9))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * fraction))
                }
                // ⚠️ 变粗只发生在**外层那个恒高的槽**里(下面 .frame(height: 14)),垂直居中、
                // 布局上一分不多占 —— 灵动岛那边踩过:高度直接参与布局的话,悬停那 2pt 会把
                // 时间行和三个播放键整块往下推一下(2026-08-19 用户报「移到进度条上按钮会位移」)。
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
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: 歌词时间轴微调(2026-08-19 从右键菜单搬进来,用户点的 A)

    /// 歌词早了/晚了半秒时就地校准。右键菜单里那个子菜单**保持原样**(还没动它),这里是
    /// 第二个入口。
    ///
    /// 搬进来的理由是**连点**:这是全 App 最典型的"边听边调" —— 对不上时往往要连点两三下
    /// 才贴合,而 NSMenu 点一下就整个关掉,调三次要开三次菜单、每次还要再进一层子菜单。
    /// 面板不会因为点了按钮而关,可以连着点到满意为止。
    ///
    /// 位置在进度条下面那一行的正中间:那一行原本只有左右两个时间数字、中间一大片空着,
    /// 是白捡的位置(整张卡片一点没变高);而且那一行的主题本来就是"时间",歌词时间轴是
    /// 时间的一种,摆这儿不突兀。
    private var offsetControls: some View {
        HStack(spacing: 3) {
            // 左减右加 —— 跟中间那个带符号的数字对齐:点右边数字变大,点左边变小。
            // 「正的步长 = 提前」这条口径不在这里定义,跟右键菜单的 nudgeEarlier、
            // 设置页那个 Stepper(▲ = 提前)是同一条。
            //
            // 2026-08-20 用户反馈「这两个按钮有点反直觉,想歌词快一点应该点右边」。原来是
            // 左「提前」右「延后」——那个左右分工其实是把右键菜单的**上下**顺序(提前在上)
            // 顺手横过来,横过来就丢了含义。而这一行左右夹着 1:02 / -5:28 两个播放时间,
            // 读者的参照系就是播放器:右 = 往前 = 赶快一点。
            //
            // 顺带把两颗圆箭头换掉(原来是 gobackward/goforward,Apple 的「快退/快进 15 秒」
            // 符号):它们在这个位置一直在往"调播放进度"上带 —— 上一轮为此才在中间补了
            // 「歌词」这个词 —— 而 ± 压根没有方向隐喻,只说"把这个数字调大/调小"。
            offsetButton("minus", help: nudgeHelp(L10n.t("延后"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: -lyricsOffsetStepMs)
            }
            // 中间这一格必须带「歌词」这个**词**(2026-08-19 用户反馈)。原来 0 的时候只放一个
            // ⏱ 图标,而这一整行左右夹着 1:02 / -5:28 两个播放时间 —— 两个圆箭头夹一个钟表,
            // 在这个语境里怎么看都像"快退/快进",误读成调播放进度。位置本身就是误导源,光换
            // 图标救不回来,得有个词把它跟播放进度切开。
            //
            // 定宽 64pt:实测最宽的形态是英文两位数负值 "Lyrics -12.5s" = 60.9pt(9.5pt
            // 等宽数字)。不定宽的话两颗按钮会随数值长短左右跳。
            Text(offsetText)
                .foregroundStyle(trackLyricsOffsetMs != 0 ? .secondary : .tertiary)
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
        // 只有 16×14,圆角取 4 —— 再大就成了一块方片压在 9.5pt 的文字行里。
        // 尺寸保持原样:这一行的行高就是被这 14pt 撑起来的,动了会连带改卡片高度。
        ChipButton(cornerRadius: 4, pressScale: 0.88, action: action) {
            Image(systemName: symbol)
                // semibold 而不是 medium:± 比原来那两颗圆箭头细得多,minus 更是只有一根
                // 横杠,再轻就读成一条分隔线而不是按钮了。
                .font(.system(size: 10, weight: .semibold))
                // 比两边的时间数字略实一点:它们是读数,这两个是能按的。
                .foregroundStyle(.secondary)
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

        func body(content: Content) -> some View {
            content
                .contentShape(Rectangle())
                .onTapGesture { if enabled { action() } }
                .modifier(OptionalHelp(text: enabled ? L10n.t("点击归零") : nil))
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
