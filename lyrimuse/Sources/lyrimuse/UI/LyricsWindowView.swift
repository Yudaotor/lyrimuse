import AppKit
import SwiftUI
import Combine
import CoreAudio
import LyrimuseCore

/// 歌词窗口的**窄订阅代理**(完整机制见 OverlayPlayback 的注释)。这扇窗实读面本来就大
/// (37 个 @Published 读约 24 个),代理的收益不在"滤掉大半",而在三处:① 滤掉它不读的
/// 高频源 —— currentLine/nextLineText 每句歌词各发一次,不滤的话每句白打醒整窗 body 2~3 次;
/// ② soundVolume **故意不转发**,音量胶囊下沉成自持订阅的子视图(WindowVolumeCapsule),
/// 拖音量只失效那个小胶囊;③ 值类型逐条 removeDuplicates。anchor 入订阅(progressSection
/// 要按锚点存在性分支,重锚低频);填色闭包里的 anchor/offset 仍直读协调器(TimelineView
/// 按帧重跑,见 KaraokeWordText)。
@MainActor
private final class WindowPlayback: ObservableObject {
    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    /// 画在界面上的那份(署名不可信的播放器在纠正落地前是空串,判据见
    /// `PlayerArtistFix.displayArtist`)。`artist` 留着给查缓存 / 拼链接那些拿它当 key 的地方。
    @Published private(set) var displayArtist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var isPlayingSmoothed = false
    @Published private(set) var currentLineIndex: Int?
    /// 滚动锚(AM 式"滚动先于染色"):滚动看它,染色/加粗/虚化仍看
    /// currentLineIndex。空档语义见 LyricsSyncEngine.scrollLeadIndex。
    @Published private(set) var scrollLineIndex: Int?
    @Published private(set) var currentGapIndex: Int?
    @Published private(set) var allLines: [LyricsWindowLine] = []
    @Published private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published private(set) var currentLineFillSettled = true
    @Published private(set) var artworkData: Data?
    @Published private(set) var artworkImage: NSImage?
    /// 电台口白:这一刻在放的不是歌,台里在说话;台名台标顶替曲目卡。
    @Published private(set) var isRadioTalkBreak = false
    @Published private(set) var radioStationName: String?
    @Published private(set) var radioStationImage: NSImage?
    @Published private(set) var highResArtworkImage: NSImage?
    /// 动态封面的本地文件。nil = 这张专辑没有 / 还没下好 / 被总闸拦了,
    /// 三种情况在这张卡上都是"只铺静态图"。
    @Published private(set) var motionCoverFile: URL?
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
    // 没有时间戳的纯文本歌词兜底,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var currentTrackPlainLyrics = ""
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    // ---- 来自 AppSettings(只挑本窗口实读的几项) ----
    @Published private(set) var showRomanization = true
    @Published private(set) var showTranslation = false
    /// 背景档位 + 两个自定义色。hex 和 Color 两份都留着:hex 给亮度判断
    /// (`LyricsWindowBackgroundLuma`,它要自己解析通道),Color 给渲染 —— body 会被逐字填色的
    /// 时钟带着高频求值,不该每帧重解析一遍字符串。
    @Published private(set) var backgroundMode: LyricsWindowBackgroundMode = .artwork
    @Published private(set) var backgroundColorHex = AppSettings.defaultLyricsWindowBackgroundColorHex
    @Published private(set) var backgroundColorEndHex = AppSettings.defaultLyricsWindowBackgroundColorEndHex
    @Published private(set) var gradientDirection: LyricsWindowGradientDirection = .vertical
    /// 歌词字体族(空串 = 跟随系统)。
    @Published private(set) var lyricsFontFamily = ""
    /// 迷你顶部那一行显示哪几样。
    @Published private(set) var miniHeaderFields: LyricsWindowMiniHeaderFields = .default
    /// 迷你顶部要不要再摆一行「已播 / 总长」。
    @Published private(set) var miniShowsTime = true
    /// 迷你悬停要不要浮出控制条。
    @Published private(set) var miniShowsControls = true
    /// 迷你顶部信息那一组左边要不要摆封面小图。
    @Published private(set) var miniShowsCover = true
    @Published private(set) var miniLineOverflow: OverlayLineOverflow = .wrap
    @Published private(set) var miniLyricsLayout: LyricsWindowMiniLyricsLayout = .compact
    /// 歌词文字色(完整 / 迷你各一套)。`.auto` 之外的三档不再问背景亮度,见 LyricsWindowTextColorMode。
    @Published private(set) var textColorMode: LyricsWindowTextColorMode = .auto
    @Published private(set) var miniTextColorMode: LyricsWindowTextColorMode = .auto
    private(set) var textColor = AppSettings.defaultLyricsWindowTextColorFallback
    private(set) var miniTextColor = AppSettings.defaultLyricsWindowTextColorFallback
    // 迷你自己那套外观(跟上面完整那组同名同结构,各存各的)。
    @Published private(set) var miniBackgroundMode: LyricsWindowBackgroundMode = .artwork
    @Published private(set) var miniBackgroundColorHex = AppSettings.defaultLyricsWindowBackgroundColorHex
    @Published private(set) var miniBackgroundColorEndHex = AppSettings.defaultLyricsWindowBackgroundColorEndHex
    @Published private(set) var miniGradientDirection: LyricsWindowGradientDirection = .vertical
    @Published private(set) var miniFontFamily = ""
    @Published private(set) var glassIntensity: OverlayGlassIntensity = .default
    @Published private(set) var miniGlassIntensity: OverlayGlassIntensity = .default
    @Published private(set) var miniFontSizeCap = AppSettings.defaultLyricsWindowMiniFontSize
    private(set) var miniBackgroundColor = AppSettings.defaultLyricsWindowBackgroundColorFallback
    private(set) var miniBackgroundColorEnd = AppSettings.defaultLyricsWindowBackgroundColorEndFallback
    private(set) var backgroundColor = AppSettings.defaultLyricsWindowBackgroundColorFallback
    private(set) var backgroundColorEnd = AppSettings.defaultLyricsWindowBackgroundColorEndFallback
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$displayArtist.removeDuplicates().sink { [weak self] in self?.displayArtist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$isPlayingSmoothed.removeDuplicates().sink { [weak self] in self?.isPlayingSmoothed = $0 },
            p.$currentLineIndex.removeDuplicates().sink { [weak self] in self?.currentLineIndex = $0 },
            p.$scrollLineIndex.removeDuplicates().sink { [weak self] in self?.scrollLineIndex = $0 },
            p.$currentGapIndex.removeDuplicates().sink { [weak self] in self?.currentGapIndex = $0 },
            p.$allLines.removeDuplicates().sink { [weak self] in self?.allLines = $0 },
            p.$lyricsGapMarkers.removeDuplicates().sink { [weak self] in self?.lyricsGapMarkers = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$artworkData.removeDuplicates().sink { [weak self] in self?.artworkData = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            p.$isRadioTalkBreak.removeDuplicates().sink { [weak self] in self?.isRadioTalkBreak = $0 },
            p.$radioStationName.removeDuplicates().sink { [weak self] in self?.radioStationName = $0 },
            p.$radioStationImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.radioStationImage = $0 },
            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
            p.$motionCoverFile.removeDuplicates()
                .sink { [weak self] in self?.motionCoverFile = $0 },
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
            p.$currentTrackPlainLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackPlainLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            s.$showRomanization.removeDuplicates().sink { [weak self] in self?.showRomanization = $0 },
            s.$showTranslation.removeDuplicates().sink { [weak self] in self?.showTranslation = $0 },
            s.$lyricsWindowBackgroundMode.removeDuplicates().sink { [weak self] in self?.backgroundMode = $0 },
            s.$lyricsWindowGradientDirection.removeDuplicates().sink { [weak self] in self?.gradientDirection = $0 },
            s.$lyricsWindowFontFamily.removeDuplicates().sink { [weak self] in self?.lyricsFontFamily = $0 },
            s.$lyricsWindowMiniHeaderFields.removeDuplicates().sink { [weak self] in self?.miniHeaderFields = $0 },
            s.$lyricsWindowMiniShowsTime.removeDuplicates().sink { [weak self] in self?.miniShowsTime = $0 },
            s.$lyricsWindowMiniShowsControls.removeDuplicates().sink { [weak self] in self?.miniShowsControls = $0 },
            s.$lyricsWindowMiniShowsCover.removeDuplicates().sink { [weak self] in self?.miniShowsCover = $0 },
            s.$lyricsWindowMiniLineOverflow.removeDuplicates().sink { [weak self] in self?.miniLineOverflow = $0 },
            s.$lyricsWindowMiniLyricsLayout.removeDuplicates().sink { [weak self] in self?.miniLyricsLayout = $0 },
            s.$lyricsWindowTextColorMode.removeDuplicates().sink { [weak self] in self?.textColorMode = $0 },
            s.$lyricsWindowMiniTextColorMode.removeDuplicates().sink { [weak self] in self?.miniTextColorMode = $0 },
            // Color 必须从**参数** hex 现算,不能回头读 `AppSettings.shared.lyricsWindowTextColor`
            // (同下面背景色那两条:@Published 是 willSet 语义,sink 跑的时候 didSet 还没执行,
            // 缓存里还是上一个颜色 —— 表现是"改了颜色要再改一次才生效")。
            s.$lyricsWindowTextColorHex.removeDuplicates().sink { [weak self] hex in
                self?.textColor = Color(
                    hexWithAlpha: hex, fallback: AppSettings.defaultLyricsWindowTextColorFallback)
            },
            s.$lyricsWindowMiniTextColorHex.removeDuplicates().sink { [weak self] hex in
                self?.miniTextColor = Color(
                    hexWithAlpha: hex, fallback: AppSettings.defaultLyricsWindowTextColorFallback)
            },
            s.$lyricsWindowMiniBackgroundMode.removeDuplicates().sink { [weak self] in self?.miniBackgroundMode = $0 },
            s.$lyricsWindowMiniGradientDirection.removeDuplicates().sink { [weak self] in self?.miniGradientDirection = $0 },
            s.$lyricsWindowMiniFontFamily.removeDuplicates().sink { [weak self] in self?.miniFontFamily = $0 },
            s.$lyricsWindowGlassIntensity.removeDuplicates().sink { [weak self] in self?.glassIntensity = $0 },
            s.$lyricsWindowMiniGlassIntensity.removeDuplicates().sink { [weak self] in self?.miniGlassIntensity = $0 },
            s.$lyricsWindowMiniFontSize.removeDuplicates().sink { [weak self] in self?.miniFontSizeCap = $0 },
            // Color 同样必须从**参数** hex 现算,不能回读 AppSettings 的缓存(@Published 是 willSet
            // 语义,那时 didSet 还没跑)—— 理由见上面完整那套同款注释。
            s.$lyricsWindowMiniBackgroundColorHex.removeDuplicates().sink { [weak self] hex in
                self?.miniBackgroundColorHex = hex
                self?.miniBackgroundColor = Color(
                    hexWithAlpha: hex, fallback: AppSettings.defaultLyricsWindowBackgroundColorFallback)
            },
            s.$lyricsWindowMiniBackgroundColorEndHex.removeDuplicates().sink { [weak self] hex in
                self?.miniBackgroundColorEndHex = hex
                self?.miniBackgroundColorEnd = Color(
                    hexWithAlpha: hex, fallback: AppSettings.defaultLyricsWindowBackgroundColorEndFallback)
            },
            // Color 必须从**参数** hex 现算,不能回头读 `AppSettings.shared.lyricsWindowBackgroundColor`:
            // Combine 的 @Published 是 **willSet** 语义,sink 跑的时候 AppSettings 那边的 didSet 还没执行,
            // 缓存里还是上一个颜色 —— 表现就是"改了颜色要再改一次才生效"。这个坑这个项目实测踩过。
            s.$lyricsWindowBackgroundColorHex.removeDuplicates().sink { [weak self] hex in
                self?.backgroundColorHex = hex
                self?.backgroundColor = Color(
                    hexWithAlpha: hex, fallback: AppSettings.defaultLyricsWindowBackgroundColorFallback)
            },
            s.$lyricsWindowBackgroundColorEndHex.removeDuplicates().sink { [weak self] hex in
                self?.backgroundColorEndHex = hex
                self?.backgroundColorEnd = Color(
                    hexWithAlpha: hex, fallback: AppSettings.defaultLyricsWindowBackgroundColorEndFallback)
            },
        ]
    }
}

/// 迷你尺寸的唯一真源。
///
/// 独立成一个 enum 而不是挂在 `LyricsWindowController` 上:那个类是 `private`,而**设置页的预览**
/// 也要按同一个尺寸渲染(见 `LyricsWindowPreviewStage`)—— 两边各写一个数,预览就不再是"它真打开
/// 的样子"了。
///
/// 420×250 按迷你布局自己的几段量:顶部信息组(三行)连上边距约 59、歌词区在这个宽度下字号
/// 31.5(宽度那一支 0.075×宽)、控制条预留约 53(`miniDeckReserve`)、进度条 3,歌词区剩约
/// 135 —— 当前行单行 + 译文 + 下一行(约 100)宽松放下,当前行折成两行且不开译文(约 111)也放得下。
/// 宽度的下限是底部控制条:三颗胶囊并排约 330pt,再窄会贴边。再宽一档字号被宽度那一支推大,
/// 高度得跟着涨,就不"迷你"了。
enum LyricsWindowMiniMetrics {
    static let size = CGSize(width: 420, height: 250)
}

// 全屏:macOS 15+ 走**真原生全屏**,老系统用下面那套伪全屏兜底。
//
// 根因是 **SwiftUI Window 默认禁全屏**,不是这扇窗自己的代码问题:同一进程里开一扇纯
// AppKit NSWindow,绿键是 AXFullScreenButton、AXFullScreen 置 true 能真进全屏 Space;这扇
// SwiftUI 窗同刻是 AXZoomButton。别再往这几个方向排查,都已经逐一证伪过:
// ① window.collectionBehavior 加 .fullScreenPrimary(位掩码确认真的生效、菜单里也多出
//    「进入全屏幕」,但下一个更新周期就被 SwiftUI 复写掉);
// ② NSApp.activationPolicy 切 .regular;
// ③ Info.plist 的 LSUIElement 改 false;
// ④ MenuBarExtra 作为主 Scene(它已经整个删掉了,现象不变)。
//
// 真正起效的是 attach() 里对 collectionBehavior 的**持续守护**(SwiftUI 每个更新周期会把
// 标志复写掉,设一次不够;`.windowFullScreenBehavior(.enabled)` 单独用不生效),
// toggle() 在 15+ 直接 window.toggleFullScreen(nil)。
//
// 伪全屏(老系统兜底):工具栏按钮触发,手动把窗口 setFrame 撑满整个屏幕(不是
// visibleFrame,是含菜单栏/Dock 那块区域在内的完整屏幕范围,配合下面的 presentationOptions
// 一起用)、隐藏标题栏和三个红黄绿按钮、拿 NSApp.presentationOptions =
// [.autoHideMenuBar, .autoHideDock] 让菜单栏/Dock 跟真全屏一样悬停才弹出——不是真的切换
// Space,但视觉效果接近,退出路径(按钮再点一次/Esc)完全在自己掌控中。
//
// LyricsWindowController 管这一整套跟真实 NSWindow 打交道的状态(伪全屏 + 置于最顶层),
// 是个 ObservableObject 而不是纯 NSView 内部状态——工具栏按钮需要跟着 isActive/
// isAlwaysOnTop 换图标/文案,SwiftUI 侧需要能观察到。用 LyricsWindowCapture(下面的
// NSViewRepresentable)拿到真实 NSWindow 交给它,复用跟 LyricsOverlayWindowController.shared
// 类似的"独立于 View 生命周期的状态持有者"思路,但这里不是单例——每个 LyricsWindowView
// 实例自己持有一个,反正这个窗口场景本身是 App 内单例 Window(id:)。
@MainActor
private final class LyricsWindowController: ObservableObject {
    @Published private(set) var isActive = false
    // 置于最顶层——跟伪全屏是两回事,不互斥(可以同时开)。用 NSWindow.level 而不是
    // collectionBehavior:.floating 是标准的"漂浮在普通窗口之上"层级,系统里很多类似
    // 功能(画中画、计算器"始终置顶"一类第三方 App)都是这么做的。不持久化——每次
    // 重新打开这个窗口都从"不置顶"开始,跟伪全屏状态同一个"只在这次打开期间有效"的
    // 处理原则,没有额外加一个 UserDefaults 存档的必要性。
    @Published private(set) var isAlwaysOnTop = false
    /// 窗口面此刻是否真的看得见(`occlusionState` 含 `.visible`):被别的窗口**完全**遮住、
    /// 最小化、orderOut 都是 false;部分露出算可见。逐字两级时钟 / 间奏三点 / 换行滚动动画的
    /// 门控用(见已知坑 #17)。默认 true——宁可多跑也不能把看得见的窗口停表。
    @Published private(set) var isSurfaceVisible = true
    /// `isSurfaceVisible` 的两个输入:系统的 occlusionState,以及「是不是几乎被别的窗口整扇盖住」
    /// (`WindowCoverageMonitor`)。后者补 occlusionState 的盲区 —— 露一条 16pt 的缝它也报可见,
    /// 实测盖住 98.4% 时逐字填色照样整窗每秒 60 次重绘(29.3% 对最小化时 13.7%)。
    private var occlusionVisible = true
    private var coveredByOthers = false
    private var coverageMonitor: WindowCoverageMonitor?

    private func refreshSurfaceVisible() {
        let visible = occlusionVisible && !coveredByOthers
        if isSurfaceVisible != visible { isSurfaceVisible = visible }
    }

    /// 设置页预览用:预览这份 controller 从不 attach 窗口,可见性改由宿主(设置窗口)推进来,
    /// 见 `LyricsWindowView.previewMode` 那条 onChange。真窗口别调。
    func setPreviewHostVisible(_ visible: Bool) {
        if isSurfaceVisible != visible { isSurfaceVisible = visible }
    }

    /// 迷你尺寸。
    ///
    /// 跟伪全屏(`isActive`)是**同一类东西**:都是"这扇窗自己的形态",都靠存一份原始 frame
    /// 再复原。两者刻意不互斥判定 —— 全屏时切迷你、迷你时切全屏都不该崩,各自复原各自那份 frame。
    @Published private(set) var isMini = false
    /// 用户正按着窗口边角拖动(live resize)。拖动期间歌词字号不跟着窗口变,松手再按最终尺寸
    /// 排一次(07 章决策 53)。只在开始 / 结束各翻一次,不是逐帧信号。
    @Published private(set) var isLiveResizing = false
    /// 进 / 出迷你的这一两拍里窗口尺寸和布局分两步换(见 toggleMini),中间态的尺寸不许拿去
    /// 算歌词字号,否则一次切换要把整张列表换字号重排两三遍(07 章决策 53)。
    @Published private(set) var isSwitchingForm = false
    /// 进迷你之前那份 frame,退出时复原。
    private var frameBeforeMini: NSRect?
    /// 进迷你之前是否置顶,退出时复原(迷你默认置顶)。
    private var alwaysOnTopBeforeMini: Bool?

    /// 迷你窗口的默认尺寸(从没拖过迷你窗时用它)。
    static var miniSize: CGSize { LyricsWindowMiniMetrics.size }
    /// 迷你下限,跟 body 根容器那层 `.frame(minWidth:minHeight:)` 的迷你一档必须一致。
    static let miniMinSize = CGSize(width: 300, height: 110)
    /// 用户拖出来的迷你尺寸。
    private static let miniSizeKey = "np:lyricsWindowMiniSize"
    /// 迷你窗在屏幕上的位置(左下角,绝对屏幕坐标)+ 所在屏幕的稳定 ID。跟尺寸分开存:尺寸换台
    /// 机器照样有意义,坐标和屏幕 ID 不是(所以这两个在配置备份的排除表里,尺寸不在)。
    private static let miniOriginKey = "np:lyricsWindowMiniOrigin"
    private static let miniScreenKey = "np:lyricsWindowMiniScreenID"

    /// 上次迷你窗待过的位置,按这次的尺寸摆回去。**先认屏幕**:那块屏不在了就返回 nil,交回
    /// "顶边钉在原位"的默认摆法 —— 跟完整窗口 `restorePersistedFrame` 同一条不变量,绝不拿旧
    /// 坐标往现有屏幕上硬摆。夹进那块屏的可见区(分辨率/缩放可能变过)。
    private func restoredMiniFrame(size: CGSize) -> NSRect? {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: Self.miniOriginKey),
              let id = defaults.string(forKey: Self.miniScreenKey),
              let screen = ScreenIdentity.screen(withID: id) else { return nil }
        return WindowFrameFit.clamp(NSRect(origin: NSPointFromString(raw), size: size),
                                    into: screen.visibleFrame)
    }

    /// 这次进迷你用多大:存过就用存的(夹在下限与所在屏可见区之间),没存过用默认。
    private func miniTargetSize(on screen: NSScreen?) -> CGSize {
        WindowFrameFit.miniSize(
            saved: UserDefaults.standard.string(forKey: Self.miniSizeKey).map(NSSizeFromString),
            defaultSize: Self.miniSize, minimum: Self.miniMinSize, visible: screen?.visibleFrame.size)
    }

    /// 背景要不要让窗口本体透出去(自定义背景色带了不透明度时)。
    ///
    /// 存成状态而不是让调用方直接改 window:`attach` 是异步的(见 LyricsWindowCapture),
    /// 视图 onAppear 那一刻 `window` 多半还是 nil,只写一次会丢。这里记住意图,attach 到手时
    /// 再补一次(见 applyWindowOpacity 的两个调用点)。
    private var wantsTransparentBackground = false

    private weak var window: NSWindow?
    /// 窗口此刻在不在屏幕上 —— App 激活刷新的可见性守卫用(Window 场景关闭后视图树
    /// 保活,onReceive 还会进来)。
    var isWindowVisible: Bool { window?.isVisible ?? false }
    private var savedFrame: NSRect?
    private var escapeMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var becomeKeyObserver: NSObjectProtocol?
    private var enterFullScreenObserver: NSObjectProtocol?
    private var exitFullScreenObserver: NSObjectProtocol?
    private var nativeFullScreenEscapeMonitor: Any?
    private var fullScreenCapabilityObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var liveResizeStartObserver: NSObjectProtocol?
    private var liveResizeEndObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    /// 落盘去抖。拖动窗口期间 didMove 每帧都来,不去抖就是每帧一次 UserDefaults 写 ——
    /// 跟「歌词管理」列宽拖动那次(松手才落盘)同一个坑,同一个修法。
    private var persistFrameTask: Task<Void, Never>?

    // MARK: - 窗口位置/尺寸/所在屏幕的持久化
    //
    // 不能只靠 SwiftUI `Window(id:)` 的系统状态恢复:系统那套的问题不在"存不存",而在**它不
    // 认识屏幕**——多显示器下拔插一次或换个分辨率,窗口经常回到主屏、或者落在一块已经不存在
    // 的屏幕的坐标上(表现是"打开了但看不见")。悬浮歌词早就为同一类问题写了 `OverlayPlacement`
    // 那一套(04 章),这里是把同样的不变量补给歌词窗口。
    //
    // 存两个键:frame(绝对屏幕坐标)+ 所在屏幕的稳定 ID。恢复时**先认屏幕**:那块屏还接着
    // 就按存的 frame 放,不在了就整个放弃、交回系统默认 —— 绝不拿旧坐标往现有屏幕上硬摆。
    private static let frameKey = "np:lyricsWindowFrame"
    private static let screenKey = "np:lyricsWindowScreenID"

    /// 拖动/缩放停下来之后再落盘。
    private func schedulePersistFrame() {
        persistFrameTask?.cancel()
        persistFrameTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistFrame()
        }
    }

    /// 存一次。**伪全屏/原生全屏期间不存**,**迷你期间只存迷你尺寸、不碰完整窗口那份 frame** ——
    /// 那时的 frame 不是完整窗口该有的样子,存进完整那份等于把"全屏尺寸"或"迷你尺寸"当成用户
    /// 想要的窗口大小:退出全屏再开就是一扇满屏的窗;迷你那边更隐蔽,下次打开会是一扇迷你大小、
    /// 却**不在**迷你模式的窗,看着像"窗口自己缩水了"。两份各存各的键。
    private func persistFrame() {
        guard let window, !isActive, !isNativeFullScreen else { return }
        // 窗口还没真正上屏时 frame 可能是 SwiftUI 给的中间值,不足为据。
        guard window.isVisible else { return }
        let defaults = UserDefaults.standard
        if isMini {
            // 小于下限的是进出迷你那一拍动画的中间值,不是用户拖出来的。
            let size = window.frame.size
            guard size.width >= Self.miniMinSize.width, size.height >= Self.miniMinSize.height
            else { return }
            defaults.set(NSStringFromSize(size), forKey: Self.miniSizeKey)
            // 位置与屏幕 ID 成对写;屏幕认不出来时两个都清掉,不留一对对不上的值。
            if let screen = window.screen, let id = ScreenIdentity.id(of: screen) {
                defaults.set(NSStringFromPoint(window.frame.origin), forKey: Self.miniOriginKey)
                defaults.set(id, forKey: Self.miniScreenKey)
            } else {
                defaults.removeObject(forKey: Self.miniOriginKey)
                defaults.removeObject(forKey: Self.miniScreenKey)
            }
            return
        }
        defaults.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
        // 屏幕认不出来(极少数情况 window.screen 为 nil)时把旧值清掉,而不是留一个跟这次
        // frame 对不上的屏幕 ID —— 下次恢复会拿错屏幕做校验。
        if let screen = window.screen, let id = ScreenIdentity.id(of: screen) {
            defaults.set(id, forKey: Self.screenKey)
        } else {
            defaults.removeObject(forKey: Self.screenKey)
        }
    }

    /// 首次 attach 时恢复一次。返回是否真的摆过 —— 只是给调用点读着清楚。
    @discardableResult
    private func restorePersistedFrame(_ window: NSWindow) -> Bool {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: Self.frameKey) else { return false }
        let saved = NSRectFromString(raw)
        guard saved.width > 0, saved.height > 0 else { return false }
        // 认屏幕:存过 ID 就必须那块屏还在。不在 = 用户换了显示器配置,旧坐标没有任何意义。
        guard let id = defaults.string(forKey: Self.screenKey),
              let screen = ScreenIdentity.screen(withID: id) else { return false }
        // 夹进那块屏的可见区。存的时候屏幕分辨率可能跟现在不同(接同一块屏但改了缩放),
        // 不夹的话窗口会有一部分挂在屏幕外 —— 跟悬浮窗 `repositionIfOffscreen` 同一个理由。
        window.setFrame(WindowFrameFit.clamp(saved, into: screen.visibleFrame), display: false)
        return true
    }

    /// 进 / 出迷你**都不做动画**:窗口尺寸直接跳到位,布局同一拍换好(07 章决策 51)。
    /// 别改回 `setFrame(animate: true)` / `NSAnimationContext`:缩放动画每一帧都会按新尺寸把
    /// 整张歌词列表重排一遍,几版补救(先放大后切布局、动画期间冻结字号)都没能让它顺。
    func toggleMini() {
        guard let window else { return }
        isSwitchingForm = true
        if isMini {
            // 置顶状态回到进迷你之前那样(迷你默认置顶,见下面进迷你那一支)。
            setAlwaysOnTop(alwaysOnTopBeforeMini ?? false)
            alwaysOnTopBeforeMini = nil
            let restore = frameBeforeMini
            frameBeforeMini = nil
            // 先在迷你布局下把 frame 摆到位,再切完整布局:反过来的话完整布局会先按迷你那点
            // 尺寸排一帧(挤成一团)再跳到大窗。迷你那档尺寸下限(300×110)不挡放大。
            if let restore { window.setFrame(restore, display: false, animate: false) }
            isMini = false
            updateTrafficLightVisibility()
            DispatchQueue.main.async { [weak self] in self?.isSwitchingForm = false }
        } else {
            frameBeforeMini = window.frame
            isMini = true
            updateTrafficLightVisibility()
            // 迷你**默认置顶**:这一档就是"缩成一条放在旁边看"的形态,被别的窗口一盖就等于没开。
            // 进之前的状态记下来,退出时原样还回去 —— 完整尺寸那扇窗默认仍不置顶。
            alwaysOnTopBeforeMini = isAlwaysOnTop
            setAlwaysOnTop(true)
            // setFrame 必须等下一拍。窗口的最小尺寸来自 SwiftUI 那层
            // `.frame(minWidth:minHeight:)`(见 body 根容器),它跟着 isMini 变 —— 而 @Published
            // 的更新要等 SwiftUI 跑完一轮才落到 NSWindow 的 contentMinSize 上。同一拍里直接
            // setFrame 会被**旧的**下限(520×480)钳住,表现是"点了迷你,窗口只缩了一点点"。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.isSwitchingForm = false }
                guard self.isMini else { return }
                let size = self.miniTargetSize(on: window.screen)
                // 回到上次迷你窗待的位置;没存过(或那块屏不在了)就顶边钉在原位。
                let f = self.restoredMiniFrame(size: size) ?? {
                    var f = window.frame
                    // 窗口坐标系原点在左下,缩高度时要把 y 往上提,否则整扇窗会"掉下去"。
                    f.origin.y += f.height - size.height
                    f.size = size
                    return f
                }()
                window.setFrame(f, display: true, animate: false)
            }
        }
    }

    /// 自定义背景带不透明度时,让窗口本体真的透出背后的桌面。
    ///
    /// 不这么做的话「不透明度」那根滑杆是半残的:SwiftUI 那层 `Color` 是画在**窗口自己的系统
    /// 底色**之上的,alpha 归零只等于"这一层不画",看到的仍是 `.windowBackgroundColor`
    /// (浅色模式下约 #ECECEC)—— 用户拉到 0% 期待看见桌面,结果是一片白。
    ///
    /// 只在**真的需要**时才关掉 isOpaque:不透明窗口是 AppKit 的快路径(合成器可以跳过它
    /// 背后的一切),跟随封面那一档和 alpha 满格的纯色都没有理由放弃它。
    func setBackgroundTransparent(_ transparent: Bool) {
        guard wantsTransparentBackground != transparent else { return }
        wantsTransparentBackground = transparent
        applyWindowOpacity()
    }

    private func applyWindowOpacity() {
        guard let window else { return }
        window.isOpaque = !wantsTransparentBackground
        // 透明时必须把窗口底色一并换掉 —— isOpaque=false 只是允许透,底色还铺着就照样挡着。
        window.backgroundColor = wantsTransparentBackground ? .clear : .windowBackgroundColor
    }

    /// 手动把这扇窗挂进「Window」菜单(= Dock 图标右键菜单里的窗口列表),别指望 AppKit
    /// 自动做这件事——只在 attach() 里调一次,不进 didUpdate 那套持续守护:
    /// `NSApp.addWindowsItem` 不是"缺才写"的幂等操作,每帧调一次会往菜单里堆出一排重复项。
    ///
    /// 为什么非手动不可:「设置」「歌词管理」两扇窗最小化后 `AXSubrole` 仍报 `AXStandardWindow`,
    /// 而**这扇窗最小化之后会变成 `AXDialog`**(这个 App 三扇正经标题栏窗口里唯一一扇有这个
    /// 现象的)。AppKit 自动填充「Window」菜单、以及 Dock 据此生成的窗口列表,都会把 AXDialog
    /// 当成次要/临时窗口过滤掉,结果是 Dock 右键菜单里根本没有「歌词窗口」这一项。病根大概率
    /// 是 `enforceTrafficLightPosition` 直接搬动了标题栏三个原生按钮的 frame(整个项目里独一份
    /// 的操作),干扰了 AppKit 判断"这是不是一扇标准窗口"的内部启发式,但没能在代码层面反向
    /// 坐实到具体是哪一步 —— 这个函数不去纠正 AXSubrole 本身,而是绕开它:不管 AppKit 认不认,
    /// 直接把这扇窗**显式**塞进菜单。窗口关闭时对称地 `removeWindowsItem`(见 attach() 里
    /// closeObserver 那段),免得关掉之后菜单里留一条点了没反应的死项。
    private func addToWindowsMenu(_ window: NSWindow) {
        window.isExcludedFromWindowsMenu = false
        NSApp.addWindowsItem(window, title: window.title, filename: false)
    }

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
    /// 红绿灯离父视图顶边的目标距离。
    ///
    /// 这是个**常量**,不是"首次量到的默认值"。两版错法都踩过:
    ///   1. 记首次那个绝对 `origin.y` —— AppKit y 向上、相对父视图左下角算,窗口一改高度这个值
    ///      就该跟着变,用旧值摆回去,按钮相对窗口顶边整体漂。
    ///   2. 记首次的"离顶边距离"再按 `superview.bounds.height` 反推 —— 看着自适应了,但**父视图
    ///      本身会换**:有时是窗口 themeFrame(高 = 窗口高),有时是标题栏容器(高固定)。两者不是
    ///      同一个参照,记录时是 A、使用时是 B,算出来的位置跟窗口尺寸完全对不上 —— 实测拖宽到
    ///      477 时三颗按钮被摆到距顶 8pt(正确是 18),就是这么来的。
    /// 直接钉一个常量,无论父视图是谁、多高,按钮永远贴着它的顶边这么远。
    private var trafficLightDefaultXs: [NSWindow.ButtonType.RawValue: CGFloat] = [:]
    /// 红绿灯下移量(按 Apple Music 整窗参考图逐像素量出:红点中心 y=25.75pt):默认中心
    /// 窗内 16pt,下移 10 → 26pt,与右上胶囊行(offset −safeTop+10)同心。
    private static let trafficLightTopMargin: CGFloat = 18
    /// 红点(close)目标中心 x(按 Apple Music 整窗截图量出:红点中心 x=25.8pt);
    /// 整组随 close 平移,保留系统自己的按钮间距。
    private static let trafficLightCloseCenterX: CGFloat = 26
    /// 系统每次标题栏布局都会把按钮拉回默认位,跟 collectionBehavior 一样要持续钉——
    /// 搭同一个 didUpdate 观察者的车,不等才写不自激。原生全屏中标题栏由系统全权
    /// 接管(自动隐藏/悬停浮出),不掺和。
    /// 红绿灯此刻该不该藏起来。
    ///
    /// 两个来源合成一处,不让任何一方直接写 `isHidden` —— 各写各的必然打架:伪全屏里藏了、
    /// 失焦再显一次,退出全屏时就又冒出来。
    ///   * **伪全屏**(`isActive`):全屏本来就不该有窗口按钮。
    ///   * **失焦**:这扇窗大部分时间是"放在旁边看着"的,不是在操作的那一扇 —— 三颗彩色圆点在
    ///     它不活跃时只是噪点。系统默认是变灰不是消失,这里是刻意的偏好。
    ///   * **迷你**:只留关闭和最小化,绿键单独藏 —— 迷你窗要"放大/进全屏"跟它存在的意义相反,
    ///     右上角胶囊里的全屏键在迷你时也是收起来的,同一个理由。
    private func updateTrafficLightVisibility() {
        guard let window else { return }
        let hidden = isActive || !window.isKeyWindow
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let hide = hidden || (type == .zoomButton && isMini)
            if let button = window.standardWindowButton(type), button.isHidden != hide {
                button.isHidden = hide
            }
        }
    }

    private func enforceTrafficLightPosition(_ window: NSWindow) {
        guard !isNativeFullScreen else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        // 只记 x 的默认位(必须在动它们之前一次记齐)。横向不随窗口尺寸变,三颗按钮的相对间距
        // 也只有从系统默认位才量得准 —— 纵向不记,见 trafficLightTopMargin。
        if trafficLightDefaultXs.isEmpty {
            for type in types {
                guard let button = window.standardWindowButton(type) else { continue }
                trafficLightDefaultXs[type.rawValue] = button.frame.origin.x
            }
        }
        guard let closeButton = window.standardWindowButton(.closeButton),
              let superview = closeButton.superview,
              let closeDefaultX = trafficLightDefaultXs[NSWindow.ButtonType.closeButton.rawValue]
        else { return }
        // 整组横向平移量:让 close 的中心落到目标 x(默认位已对时 dx≈0,写入是 no-op)。
        let dx = (Self.trafficLightCloseCenterX - closeButton.frame.width / 2) - closeDefaultX
        // 贴父视图顶边固定距离。AppKit y 向上,所以从父视图高度往下减。
        let targetY = superview.bounds.height - Self.trafficLightTopMargin - closeButton.frame.height
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
    // 也退出伪全屏——presentationOptions 是 NSApplication 级别的**进程级全局状态**,不跟哪一扇
    // 具体窗口绑定,只在①这个窗口关闭时才清理是不够的:用户在这个窗口开着伪全屏、切去操作
    // 另一扇窗口时,菜单栏/Dock 会跟着继续隐藏,那扇窗口反而变得不好用(找不到菜单栏)。
    // 真全屏在这种场景下是"焦点窗口所在的那个 Space 单独隐藏菜单栏",别的窗口不受影响;这里
    // 没有真的 Space 隔离,只能退而求其次——失去焦点就整个退出伪全屏,不去做"记住哪些窗口
    // 该保持全屏"这类更复杂的模拟。置顶状态不需要类似兜底——window.level 是这个 NSWindow
    // 实例自己的属性,窗口一关就随实例一起没了,也不受切换焦点影响,不像 presentationOptions
    // 那样是进程级的全局状态、需要显式清理。
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // 打开 / 关闭不要系统那套缩放淡入淡出:窗口直接出现、直接消失(07 章决策 51)。
        window.animationBehavior = .none
        // 原生全屏:.windowFullScreenBehavior(.enabled) 在这版 SwiftUI 上
        // 实测没生效(绿键仍是 AXZoomButton),AppKit 层直接改 collectionBehavior 强制
        // 打开;探针实验证明同进程纯 AppKit 窗全屏机制完好。
        // 设一次不够:SwiftUI 会在后续更新周期把 collectionBehavior 复写回去 ——
        // 实测右上角按钮(toggle 前刚补过标志)能进真全屏,绿键(用系统当下的标志)却
        // 还是 zoom。挂 didUpdate(每个绘制周期)做**持续守护**,回调只查一个位、缺了
        // 才写,写入本身也满足守卫条件,不会自激。
        Self.enforceFullScreenCapability(window)
        enforceTrafficLightPosition(window)
        updateTrafficLightVisibility()
        addToWindowsMenu(window)
        // 窗口本体的不透明度。attach 之前视图就可能已经算出了意图,这里补上。
        applyWindowOpacity()
        // 位置/尺寸/所在屏幕:先恢复一次,再挂上观察者。顺序要紧 —— 反过来的话我们自己那次
        // setFrame 会立刻触发 didMove/didResize、把刚读出来的值原样再写一遍(无害但没意义),
        // 更糟的是恢复失败(屏幕不在了)时会把系统摆的那个默认位置当成用户意图存下来。
        restorePersistedFrame(window)
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        // didMove 和 didResize 合用一个回调:两者要存的东西完全一样,而拖动窗口边角同时
        // 产生这两个通知 —— 分开挂只会写两遍。
        let persist: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePersistFrame() }
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main, using: persist)
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        // 缩放这一支除了存 frame,还要**当场把红绿灯摆回去**。
        //
        // 摆红绿灯的守护原本只挂在 didUpdate 上,而 live resize(按住边框还没松手)期间那条通知
        // 不保证来 —— AppKit 在拖动的每一帧重排标题栏按钮到系统默认位,没人纠,于是拖动过程中
        // 三颗按钮肉眼可见地跳到另一个位置,松手后 didUpdate 才补一次、又跳回来。didResize 在
        // live resize 期间是**每帧**都发的,挂在这里才跟得上手。
        // (enforce 很轻:读几个 frame,位置已对就是 no-op,不会给拖动加负担。)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.schedulePersistFrame()
                if let win = note.object as? NSWindow { self?.enforceTrafficLightPosition(win) }
            }
        }
        if let liveResizeStartObserver { NotificationCenter.default.removeObserver(liveResizeStartObserver) }
        liveResizeStartObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLiveResizing = true }
        }
        if let liveResizeEndObserver { NotificationCenter.default.removeObserver(liveResizeEndObserver) }
        liveResizeEndObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLiveResizing = false }
        }
        // 窗口面可见性:SwiftUI 对被遮住/最小化/orderOut 的窗口**不会**自动
        // 暂停 TimelineView(.animation)——离屏探针实测五种不可见状态都还是 ~63 次/秒。
        // 用 occlusionState 当唯一信号:遮挡与最小化都会让它失去 .visible,不用再单挂
        // miniaturize 通知;切 Space 只是短暂翻一下、几帧后自己翻回来,不需要防抖。
        // attach 时窗口可能还没 orderFront(此时 occlusionState 也是"不可见"),先按可见算——
        // 首次显示后系统会补一次通知(探针实测 orderFront 后 ~30ms 到),再以它为准。
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionVisible = window.isVisible ? window.occlusionState.contains(.visible) : true
        coveredByOthers = false
        refreshSurfaceVisible()
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let win = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.occlusionVisible = win.occlusionState.contains(.visible)
                self?.refreshSurfaceVisible()
            }
        }
        // occlusionState 的盲区:几乎整扇被别的窗口盖住、只露一条缝时它仍报可见(见 occlusionVisible 注释)。
        coverageMonitor?.stop()
        coverageMonitor = WindowCoverageMonitor(window: window) { [weak self] covered in
            self?.coveredByOthers = covered
            self?.refreshSurfaceVisible()
        }
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
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.forceExit()
                self?.coverageMonitor?.stop()
                self?.coverageMonitor = nil
                // addToWindowsMenu 手动加的那条,窗口关掉后手动摘掉——不摘的话菜单里会
                // 留一条指向已释放窗口的死项。
                if let win = note.object as? NSWindow { NSApp.removeWindowsItem(win) }
            }
        }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forceExit()
                self?.updateTrafficLightVisibility()
            }
        }
        if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTrafficLightVisibility() }
        }
        // 真原生全屏的状态跟踪:按钮图标/提示跟着换,进入时装 Esc 退出
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
        setAlwaysOnTop(!isAlwaysOnTop)
    }

    private func setAlwaysOnTop(_ on: Bool) {
        guard let window else { return }
        isAlwaysOnTop = on
        window.level = on ? .floating : .normal
    }

    /// 真·原生全屏进行中(自己的 Space、三指横滑)。与伪全屏 isActive 是两个独立状态:
    /// 真全屏由系统管理,切走焦点/关窗都不需要我们清理什么;伪全屏的 presentationOptions
    /// 全局态才需要 forceExit 那套兜底。
    @Published private(set) var isNativeFullScreen = false
    /// 按钮图标/提示用:处于任意一种全屏。
    var isFullScreenActive: Bool { isActive || isNativeFullScreen }

    func toggle(reduceMotion: Bool) {
        // macOS 15+ 走真原生全屏(根因是 SwiftUI Window 默认禁全屏,场景内容挂
        // .windowFullScreenBehavior(.enabled) 已打开,见 App.swift)。
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
        // Apple Music 式顶部),这里只需要藏红黄绿。
        isActive = true   // 先置位,下面那次显隐才按"已进全屏"算
        updateTrafficLightVisibility()
        // .autoHideMenuBar 单独用没有效果——文档要求两个一起设,菜单栏才会真的让出空间、
        // 悬停到顶部才重新弹出(实测坐实,不是随手加的)。
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        window.setFrame(screen.frame, display: true, animate: animate)
        // 上面这次 setFrame 可能被钳:presentationOptions 刚设下去、菜单栏还没真正让位时,
        // WindowServer 会把 normal 层级窗口的 frame 压到菜单栏之下 —— 表现为"全屏后顶上留一条
        // 空"。等隐藏生效后再校两次(一拍 + 0.35s 兜底,动画版 setFrame 也要等它跑完),已经到位
        // 就是 no-op。
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
        // NSEvent.addLocalMonitorForEvents 是"发给本 App 任意窗口"级别的钩子,**不按窗口
        // 过滤**,所以回调体内必须显式判 `self?.window?.isKeyWindow`,不是当前 key window 就
        // 放行事件(return event)、不拦截也不触发 exit。少了这个判断的话,用户在这个窗口伪全屏
        // 时切去 App 内另一扇窗口(比如设置页的"存为新配色主题"弹窗)按 Esc 想取消弹窗,会被
        // 这里无条件 return nil 吞掉 —— 目标窗口收不到这次 Esc,后台这扇窗反而莫名退出了全屏。
        // 跟 attach() 里的 didResignKeyNotification 兜底是两道独立防线:那道处理"切走焦点后主动
        // 退出全屏"这个状态清理,这里处理"这次具体的 Esc 按键该不该被这个监听器吞掉",避免
        // 依赖两个异步通知的到达顺序。
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
        isActive = false  // 先置位,下面那次显隐才按"已退出全屏"算
        updateTrafficLightVisibility()
        // 标题栏不复原:透明+无标题是常驻状态(.hiddenTitleBar),这里恢复的只有红黄绿。
        savedFrame = nil
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

    /// 在视图被放进窗口的**那一刻**同步 attach,不等下一拍。
    ///
    /// attach 里要恢复上次的窗口位置尺寸、关掉开窗动画 —— 这些都必须赶在窗口第一次显示之前。
    /// 原来是 `DispatchQueue.main.async` 里再 attach,那时窗口往往已经按 SwiftUI 的默认尺寸
    /// (idealWidth / idealHeight)显示出来了,紧接着被恢复成上次的大小,表现就是"先出来一个小窗、
    /// 一闪变大"(以前系统开窗动画把这一跳盖住了,去掉动画后才露出来,07 章决策 52)。
    final class CaptureView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(frame: .zero)
        view.onWindow = { [controller] window in controller.attach(window) }
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        if let window = nsView.window {
            controller.attach(window)
        }
    }
}
//
// "歌词窗口":正经的标题栏窗口,展示当前歌曲完整歌词并跟随播放
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
    /// 这一份是**设置页里的预览**,不是真窗口。
    ///
    /// 预览要的是"跟真窗口逐像素一致",所以走的就是这份视图本体、不另画一个仿制品
    /// (仿制品迟早跟本体走散,`SectionPreviewBars` 的头注记过这条教训)。真窗口独有的两件事
    /// 必须关掉,它们都会**反过来伤到宿主窗口**:
    ///
    ///   ① `LyricsWindowCapture` —— 它拿 `view.window` 去 `controller.attach()`,而 attach 会改
    ///      `collectionBehavior`、挪红绿灯、把窗口加进「窗口」菜单,还会**把宿主窗口的尺寸恢复成
    ///      歌词窗口存的那一份**,之后用户拖设置窗口又会把位置写回歌词窗口的存档。预览挂在设置
    ///      窗口里,attach 的就是设置窗口。
    ///   ② `AuxiliaryWindowActivation` 的出现/消失记账 —— 预览的出现不是"歌词窗口打开了"。
    ///
    /// 其余的窗口级副作用(伪全屏、Esc 监视、置顶)都在 `LyricsWindowController` 内部、带
    /// `self.window` 或 `isActive` 守卫,不 attach 就够不到;点击类副作用(开菜单、开链接)由调用方
    /// 的 `.allowsHitTesting(false)` 挡住 —— 见 `LyricsWindowPreviewStage`。
    ///
    /// 另外**两处窗口控件在预览里整个不摆**(搜 `previewMode` 找得到):左上角的置顶/全屏胶囊、
    /// 右下角的翻译钮 + [歌词|播放记录] 胶囊。它们跟 `allowsHitTesting` 挡掉的那些不是一回事 ——
    /// 那些是"能看但点不动"就够了(播控、逐行 hover 都属于画面本身),而这两处管的是**这扇窗自己**
    /// 或**这一份实例自己的会话状态**,预览里既没有对应的窗口、切出来的状态也传不到真窗口,
    /// 摆着只会让人以为预览坏了。
    var previewMode = false
    /// 只给预览用:强制按**迷你布局**画。
    ///
    /// 真窗口那边迷你与否由 `windowController.isMini` 定,而那个状态只能经 `toggleMini()` 翻、
    /// 且要有真实 NSWindow 才动得了 —— 预览没有窗口,够不着它。所以另开一个只读入参,
    /// 两者取或(见 showsMiniLayout)。
    var previewMini = false
    // 不整对象订阅 PlaybackCoordinator/AppSettings —— 见 WindowPlayback 的注释。
    @StateObject private var playback = WindowPlayback()
    @StateObject private var windowController = LyricsWindowController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 预览模式下宿主(设置窗口)看不看得见,见 PreviewHostVisibility.swift。真窗口恒 true、不读它。
    @Environment(\.previewHostVisible) private var previewHostVisible
    // 这块屏一个点等于几个物理像素。外接 1x 显示器上 = 1,内建 Retina = 2 —— 逐字抬升
    // 的落点要按它对齐到整像素,见 karaokeRise。
    @Environment(\.displayScale) private var displayScale
    /// 封面的实际边长。控制排的图标大小和间距都按它算 —— 封面是随窗口缩放的,按钮要是写死
    /// 字号,窄窗口下整排会比左栏还宽、最左边那个模式键直接被裁在窗口外面,宽窗口下又显得
    /// 过小、跟封面不成比例。
    @State private var artworkWidth: CGFloat = 0
    /// 鼠标悬在哪一行(行 id)。悬停的行不虚化、点一下跳到那一句。
    @State private var hoveredLineID: String?
    /// 「…」的自绘 AM 式菜单开着没有(替代系统 Menu,见 titleSideButtons)。
    @State private var showsMoreMenu = false
    /// 「显示简介」面板(「⋯」菜单项之一):与菜单同锚点、同玻璃样式。
    @State private var showsInfoPanel = false
    /// 「你的常听」榜单面板(Last.fm 系列 #7)。
    @State private var showsChartsPanel = false
    /// 「⋯」按钮锚点矩形的**快照**。面板定位改读它、
    /// 不再在 overlayPreferenceValue 闭包里直接消费 geo[anchor]:菜单面板开着时会形成
    /// 一个自持的几何重算循环,热路径穿过「锚令牌 到 geo 解析 到 面板 ZStack 布局」这条
    /// 依赖边,每个显示周期整窗都要重新走一遍布局(菜单一关立即回全闲)。快照定位把面板
    /// 从几何依赖链上摘下来:锚点矩形经 onChange 落进 @State(变了才写),面板走普通
    /// .overlay,只随真实状态变化重建,不再被每帧几何重算连坐。
    @State private var moreAnchorRect: CGRect = .zero
    /// 右下角「翻译与发音」菜单(对照 AM 歌词页右下角同位按钮):开关的是
    /// 设置里现成的 showTranslation/showRomanization 两个总开关,这里只是快捷入口。
    @State private var showsTranslationMenu = false
    /// 歌词栏显隐(AM 右下角「引号气泡」钮):关掉=封面居中的纯播放器视图
    /// (AM 同款)。会话内状态,不持久化。仅双列模式可关 —— 单列窗口整个就是歌词,
    /// 关了剩一片空白(生效判断见 body 的 lyricsPaneVisible)。
    @State private var showsLyricsPane = true
    /// 「播放记录」面板是否在替代右侧歌词栏(取代原来 AM 右下角「列表」钮
    /// 打开的「待播清单」)。原来那个功能靠 AppleScript 读 `current playlist` 模拟队列,
    /// 用户 /26 两次报"明明在放专辑却拿不到"——查到根因是这个属性只在**从
    /// 本地资料库对象**播放时才可靠,直接点开 Apple Music 目录里的专辑/播放列表(没
    /// 先进资料库)同样会失效,不是电台专属、范围比想象中宽得多,且没有已知的可靠
    /// 替代路径(见 MusicPlaybackController.upNextQueue 被删前的注释,git 历史可查)。
    /// 用户决定干脆把这个位置换成一个不依赖这个能力边界的功能:Last.fm 播放记录 ——
    /// 连了账号就是"最近听过"(与停播页共用 RecentListensPanel),没连就是本地静默
    /// 记的、还没提交的收听("待补提交",与设置页的 pendingListensRow 共用数据源
    /// ScrobbleBackfillService)。跟 showsLyricsPane 是**同一块地皮**上的两种内容,
    /// 不是弹出面板——见 body 里 `if showsListenHistory` 那处切换。
    @State private var showsListenHistory = false
    /// 自绘滚动指示条的数据(offset/内容高):收在小 model 里、只有指示条子视图订阅 ——
    /// 滚动期间逐帧的 preference 更新不能拖着整窗 body 陪跑(性能纪律同 WindowVolumeCapsule)。
    @StateObject private var scrollMetrics = LyricsScrollMetricsModel()
    /// 窗口面不可见期间是否发生过需要滚动的换行/间奏切换(见 isSurfaceVisible 的 onChange)。
    @State private var scrollPendingWhileHidden = false
    /// 简介面板里的歌词来源(EnrichCacheReader 异步查,面板打开时取一次)。
    @State private var infoLyricsSource: String?
    /// 「搜索歌词…」的上下文:菜单点击瞬间把 曲目字段+写回 key+当前来源
    /// 一次性快照下来 —— sheet 打开期间歌可能换,搜索和写回都要钉在点击那一刻的曲目上。
    @State private var lyricsSearchContext: LyricsSearchContext?
    /// 「添加到资料库」行的即时状态:此前点完静默关面板,成功/本来就在库/
    /// 失败三种结局全都看不出差别(实测"点了没反应"那次就是歌 7 月已在库、duplicate
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
    /// 这首歌在各平台的跳转目标。零网络,全是 collector 早就存进 enrich 缓存的
    /// 字段;开菜单/换曲时后台读一次(首次要解析整份缓存 JSON,不能在主线程)。
    @State private var platformLinks: PlatformLinks?
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
    /// 越来越小,右边空出一大片(用户对比 Apple Music 提的)。Apple Music 的
    /// 歌词字号是跟着窗口长的,这里照做。
    /// 高度是字号的主锚(见 lyricFontSize):AM 的"一屏约 7 行"是行距吃掉窗高 12.9% 的结果,
    /// 行距又是字号的固定倍数,所以字号必须跟高度走才能锁住行数。
    ///
    /// 完整和迷你「多行」各存一份:两边共用 rightPane,共用一份的话切形态后第一帧会按另一种
    /// 形态的尺寸算字号,整张列表白排一遍再改回来。
    @State private var fullLyricsPaneSize: CGSize = .zero
    @State private var miniLyricsPaneSize: CGSize = .zero
    private var lyricsPaneSize: CGSize { showsMiniLayout ? miniLyricsPaneSize : fullLyricsPaneSize }
    private var lyricsColumnWidth: CGFloat { lyricsPaneSize.width }
    /// 此刻量到的歌词栏尺寸先不提交(拖窗口边角中 / 切迷你中)。
    private var defersLyricsPaneResize: Bool {
        windowController.isLiveResizing || windowController.isSwitchingForm
    }
    private var lyricsViewportHeight: CGFloat { lyricsPaneSize.height }

    private func setLyricsPaneSize(_ size: CGSize) {
        if showsMiniLayout {
            if miniLyricsPaneSize != size { miniLyricsPaneSize = size }
        } else {
            if fullLyricsPaneSize != size { fullLyricsPaneSize = size }
        }
    }
    /// 鼠标在不在迷你窗里 —— 迷你模式下窗口控件悬停才露(见 miniBody)。
    @State private var miniHovered = false
    /// 迷你进度条拖动中按住的位置(0…1),没在拖就是 nil。
    /// `@GestureState` 而不是 `@State` —— 手势被取消时它自动复位,理由见 miniProgressBar。
    @GestureState private var miniScrubFraction: Double?
    /// 迷你进度条那一行的实测宽度,换算点击位置用。
    @State private var miniScrubWidth: CGFloat = 0

    var body: some View {
        // 诊断探针(「菜单开着很卡」排查,debug 级、不 log stream 时零成本):
        // 打出每次主 body 重算的触发属性。定位结束后可删。
        let _ = { if #available(macOS 14.1, *) { Self._logChanges() } }()
        // 两套布局共用下面那一整串**窗口级**修饰符(尺寸下限、attach、透明度、记账、
        // 刷新时机)—— 它们管的是这扇窗本身,跟里面画什么无关。布局本身分两支:
        // 迷你是为小尺寸**重新排的**一版(见 miniBody),不是把完整布局挤窄。
        return Group {
            if showsMiniLayout {
                miniBody
            } else {
                fullBody
            }
        }
        // 从竖长阅读面板改成 Apple Music 歌词页同款的横向双列比例。窗口尺寸
        // 由系统状态恢复机制记忆,老用户第一次打开还是旧的竖长尺寸(此时按上面的宽度
        // 判断退化成单列),手动拖宽一次之后就会记住新比例。
        // 迷你模式要突破正常的尺寸下限(520×480)才缩得下去 —— 这两个数直接决定 NSWindow 的
        // contentMinSize,不放开的话 setFrame 会被钳住。见 LyricsWindowController.toggleMini。
        .frame(minWidth: showsMiniLayout ? LyricsWindowController.miniMinSize.width : 520,
               idealWidth: 1020,
               minHeight: showsMiniLayout ? LyricsWindowController.miniMinSize.height : 480,
               idealHeight: 660)
        // 预览模式下**不能**挂:它会把宿主(设置)窗口当成歌词窗口接管,见 previewMode 的注释。
        .background {
            if !previewMode {
                LyricsWindowCapture(controller: windowController).frame(width: 0, height: 0)
            }
        }
        // 见 AuxiliaryWindowActivation 注释——只记账,不碰 Dock 图标。
        // 这扇窗设计成"跟随播放持续显示"、用户中途切去别的 App 很常见,所以它曾是借 Dock
        // 图标最有理由的一扇;用户仍然选择让「在 Dock 中显示」这个开关说了算,切走之后靠
        // 菜单栏图标把它叫回来。
        // 窗口本体的不透明度跟着背景设置走。预览没有自己的窗口(也不该去动设置窗口),
        // controller 里 `window` 为 nil 时这两个调用是空操作,不用额外 gate。
        .onAppear { windowController.setBackgroundTransparent(wantsTransparentWindow) }
        .onChange(of: wantsTransparentWindow) { _, transparent in
            windowController.setBackgroundTransparent(transparent)
        }
        // 预览不是"这扇窗打开了",不参与记账(记了会让 Dock 图标跟着设置页开关闪)。
        .onAppear { if !previewMode { AuxiliaryWindowActivation.windowDidAppear("lyrics-window") } }
        // 预览的 controller 不 attach 窗口,自己的可见性永远是 true;改用设置窗口的可见性,
        // 逐字时钟 / 间奏三点 / 进度条 / 滚动动画就跟真窗口被遮住时一样停下来。
        .onChange(of: previewHostVisible, initial: true) { _, visible in
            if previewMode { windowController.setPreviewHostVisible(visible) }
        }
        .onDisappear { if !previewMode { AuxiliaryWindowActivation.windowDidDisappear("lyrics-window") } }
        // 音量跟"喜欢""播放模式"共用同一批刷新时机,理由见下面那段注释。
        // "喜欢"状态不跟着 2 秒轮询走(每读一次要起一个 osascript 子进程,为一个几乎不变
        // 的布尔值那么干不值当),换歌时由 PlaybackCoordinator 刷一次。悬浮窗还借"控制排
        // 露出来"这个动作补刷,而这扇窗口是常显的、没有那个动作,所以换成:打开时刷一次,
        // 以及每次 App 重新变成前台时刷一次 —— 后者正好覆盖"用户刚切去 Music.app 点了
        // 心、再切回来"这条路径。
        .onAppear {
            // 这个是 CoreAudio 查询,便宜,预览也要(耳机图标是画面的一部分)。
            isExternalOutput = AudioOutputDeviceManager.isExternalOutputActive()
            // 下面三个各起一个 osascript 子进程。预览**不主动刷** —— 它们读的是
            // PlaybackCoordinator 的共享状态,换歌时协调器自己会刷,真窗口/悬浮窗打开时也会刷,
            // 预览跟着读现成的值就够了。为"用户瞄一眼设置页"白起三个子进程,跟下面那条
            // 「App 每次激活都在关着的窗口背后白起 3 个 osascript」守卫是同一笔账。
            guard !previewMode else { return }
            PlaybackCoordinator.shared.refreshFavorited()
            PlaybackCoordinator.shared.refreshPlaybackMode()
            PlaybackCoordinator.shared.refreshVolume()
        }
        // 面板开合时都刷一次"外接输出中":用户可能刚在系统里切过输出。
        .onChange(of: showsOutputMenu) {
            isExternalOutput = AudioOutputDeviceManager.isExternalOutputActive()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // 可见性守卫:Window 场景关闭后视图树/订阅仍保活,
            // 原来每次 App 激活(Cmd-Tab/点状态栏)都在关着的窗口背后白起最多 3 个
            // osascript 子进程。重开窗口时上面 onAppear 的全量刷新本来就会跑一遍。
            guard windowController.isWindowVisible else { return }
            PlaybackCoordinator.shared.refreshFavorited()
            PlaybackCoordinator.shared.refreshPlaybackMode()
            PlaybackCoordinator.shared.refreshVolume()
        }
    }

    // MARK: - 迷你尺寸

    /// 这一份此刻该不该画成迷你:真窗口看 controller,预览看入参(见 previewMini)。
    private var showsMiniLayout: Bool { previewMini || windowController.isMini }

    // MARK: 按当前形态选那一套外观
    //
    // 完整和迷你各存各的背景/字体(理由见 AppSettings 那组字段的注释)。下面五个是**唯一**的读取
    // 入口 —— 视图里别再直接摸 playback.backgroundMode 那几个,不然加一处就漏一处形态判断。
    private var activeBackgroundMode: LyricsWindowBackgroundMode {
        showsMiniLayout ? playback.miniBackgroundMode : playback.backgroundMode
    }
    private var activeBackgroundColor: Color {
        showsMiniLayout ? playback.miniBackgroundColor : playback.backgroundColor
    }
    private var activeBackgroundColorEnd: Color {
        showsMiniLayout ? playback.miniBackgroundColorEnd : playback.backgroundColorEnd
    }
    private var activeBackgroundColorHex: String {
        showsMiniLayout ? playback.miniBackgroundColorHex : playback.backgroundColorHex
    }
    private var activeBackgroundColorEndHex: String {
        showsMiniLayout ? playback.miniBackgroundColorEndHex : playback.backgroundColorEndHex
    }
    private var activeGradientDirection: LyricsWindowGradientDirection {
        showsMiniLayout ? playback.miniGradientDirection : playback.gradientDirection
    }
    private var activeFontFamily: String {
        showsMiniLayout ? playback.miniFontFamily : playback.lyricsFontFamily
    }
    private var activeGlassIntensity: OverlayGlassIntensity {
        showsMiniLayout ? playback.miniGlassIntensity : playback.glassIntensity
    }
    private var activeTextColorMode: LyricsWindowTextColorMode {
        showsMiniLayout ? playback.miniTextColorMode : playback.textColorMode
    }
    private var activeCustomTextColor: Color {
        showsMiniLayout ? playback.miniTextColor : playback.textColor
    }

    // MARK: 歌词文字色
    //
    // 只有 `.auto` 才回去问背景亮度(`hasArtworkBackground`)—— 那是加这颗设置之前的唯一行为,
    // 也是默认,所以没碰过设置的人升级后逐像素不变。其余三档钉死,理由见 LyricsWindowTextColorMode。
    //
    // **这两个只喂歌词文字(正文 / 译文 / 罗马音),别顺手接到 chrome 上。** 音量胶囊、进度条、
    // 玻璃描边要跟**背景**有对比度才看得见,跟用户给歌词挑了什么颜色无关;接上去的话选个深色文字
    // 会把玻璃胶囊那圈亮边也翻黑,而那圈亮边正是玻璃质感的来源。

    /// 深色档那个"黑"。取 85% 而不是纯黑:macOS 的 `labelColor` 就是这个量,钉死纯黑在浅底上
    /// 反而比系统控件更重、显脏。
    private static let forcedDarkTextColor = Color.black.opacity(0.85)

    /// 歌词正文色。
    private var lyricTextColor: Color {
        // 哪一档对应哪种色调在 Core(`LyricsWindowTextColorMode.tone`,selftest 钉着 `.auto` 档
        // 保持老行为),这里只把色调换成具体颜色。
        switch activeTextColorMode.tone(hasArtworkBackground: hasArtworkBackground) {
        case .white: return .white
        case .systemPrimary: return .primary
        case .dark: return Self.forcedDarkTextColor
        case .custom: return activeCustomTextColor
        }
    }

    /// 译文 / 罗马音那两行的色。三个钉死档一律按正文色降透明度,不走 AM 那套 vibrancy 派生 ——
    /// 用户明确指定了颜色,再拿封面去调一个"相近但不同"的色出来只会显得没听话。
    private var lyricSecondaryTextColor: Color {
        switch activeTextColorMode.tone(hasArtworkBackground: hasArtworkBackground) {
        case .white: return .white.opacity(0.6)
        case .systemPrimary: return .secondary
        case .dark: return .black.opacity(0.5)
        case .custom: return activeCustomTextColor.opacity(0.6)
        }
    }

    /// 迷你布局:上面歌名歌手 + 时间、中间当前行 + 下一行、底边一条贴合的进度条;
    /// 鼠标移进来时,歌词和进度条之间预留的那一格浮出控制条(走带三键 / 音量 / 歌词时间轴)。
    ///
    /// **这是为小尺寸重排的一版,不是把完整布局挤窄。**完整布局那条"窗口窄于 640 就退化成单列"
    /// 的路看着很省事,但它退化出来的是"一扇被挤窄的大窗":歌词还是整列滚动、顶部还留着为红绿灯
    /// 让位的大片空白、行距按七行一屏算 —— 在 460×240 里全是浪费。迷你要的是**一眼就读到当前这句**,
    /// 所以只留三样东西:是谁在唱、唱到哪了、还剩多久。
    ///
    /// **操作藏进悬停,但位置常驻预留。**控制条平时不画,只在悬停时浮出来;它那一格高度却一直
    /// 留着(`miniDeckReserve`),这样浮出来时下一行不被盖住、歌词也不用挪。不想要这一格的,
    /// 右上角那颗开关把控制条整个关掉,预留随之取消。
    ///
    /// 背景、字体、文字色都跟完整布局共用同一份设置(`artworkBackground` / `lyricsFontFamily` /
    /// `hasArtworkBackground`),所以在设置里调背景和字体,迷你窗跟着变。
    private var miniBody: some View {
        GeometryReader { geo in
            let fontSize = Self.miniFontSize(geo.size, cap: playback.miniFontSizeCap)
            VStack(spacing: 0) {
                miniTopInfo
                if miniUsesLyricsList {
                    // 「多行」:完整布局那份整页列表原样搬进来(行、间奏点、自动滚动、点行跳转都是
                    // 同一份),字号由这块视口自己推(`lyricFontSize`,迷你档再夹一道字号上限)。
                    lyricsScrollReader { _ in
                        rightPane(leading: Self.miniListHorizontalInset, trailing: Self.miniListHorizontalInset,
                                  centered: true, wordRise: false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 4)
                } else {
                    Spacer(minLength: 4)
                    miniLyrics(fontSize: fontSize)
                    Spacer(minLength: 4)
                }
                // 控制条那一格的**常驻预留**:歌词区的下沿永远停在控制条上沿之上,控制条浮出来时
                // 下一行照常显示、谁也不压谁,而且悬停进出时歌词一个像素都不动。
                Color.clear.frame(height: miniDeckReserve)
                miniProgressBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(artworkBackground.ignoresSafeArea())
            // 控制条**钉在最底部**,而且是 overlay、**不参与布局** —— 它进出时上面的歌词
            // 一个像素都不动。不压到下一行,靠的是上面那格 `miniDeckReserve`。
            .overlay(alignment: .bottom) {
                if !previewMode {
                    miniDeck
                        .padding(.bottom, Self.miniDeckBottomInset)
                        .opacity(miniControlsVisible ? 1 : 0)
                        // 藏着的时候不能吃点击:否则鼠标还没进窗,光标从上面划过就已经能按到
                        // 一颗看不见的「下一首」。
                        .allowsHitTesting(miniControlsVisible)
                        .animation(.easeOut(duration: 0.14), value: miniControlsVisible)
                }
            }
            // 窗口控件悬停才露:迷你窗每一寸都是内容,两颗常驻胶囊会把顶部那行标题挤没。
            // 挂 topTrailing 而不是 topLeading —— 左上角被红绿灯占着(.hiddenTitleBar 下常显)。
            //
            // 预览里整个不摆,跟 fullBody 那处同一个理由:它管的是**这扇窗自己**,而预览不是一扇窗。
            .overlay(alignment: .topTrailing) {
                if !previewMode {
                    windowActionsCapsule()
                        .padding(.trailing, 10)
                        .offset(y: -geo.safeAreaInsets.top + 8)
                        .opacity(miniHovered ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: miniHovered)
                }
            }
            .onHover { miniHovered = $0 }
        }
    }

    /// 迷你「多行」这一刻走不走整页列表。没有同步歌词(空态 / 纯文本兜底)和电台口白时退回两行那套:
    /// 列表那几种占位是按完整窗口的尺寸画的(大图标 + 大字),塞进迷你那块视口里会挤爆。
    private var miniUsesLyricsList: Bool {
        playback.miniLyricsLayout == .list && !playback.allLines.isEmpty && !playback.isRadioTalkBreak
    }

    /// 迷你「多行」列表左右留白。完整布局单列时是 44,迷你窄得多,收到 20(同两行那套的左右边距)。
    private static let miniListHorizontalInset: CGFloat = 20

    /// 迷你窗的正文字号。
    ///
    /// 跟完整布局的 `lyricFontSize` 同一个思路(跟着窗口长),但比例大得多:那边要在一屏里排七行,
    /// 这边只排一行半,字就该顶满。
    ///
    /// `cap` 是用户设的**上限**(设置里那根滑杆),不是最终值 —— 窗口够大时按它走,窗口被拖小了
    /// 仍由宽高压下来。反过来写(让用户值直接生效)的话,把窗口拖到最小会看到一句话占三行、
    /// 下一行和译文全被挤出窗外。下限 12 保证极端尺寸下还认得出字。
    static func miniFontSize(_ size: CGSize, cap: CGFloat) -> CGFloat {
        LyricsWindowTypography.miniFontSize(size, cap: cap)
    }

    /// 顶部那一组:竖排的曲目信息行与时间行**按窗口居中**,封面小图(可关)挂在文字块左边。
    ///
    /// **居中的只是文字,封面不参与**:横排「封面 | 文字 | 同宽透明占位」,两侧等宽,文字就
    /// 落在正中。只排「封面 | 文字」一起居中的话,文字会被往右推半个封面宽,跟正下方居中的歌词
    /// 对不齐,而且开关封面时文字会左右跳。
    ///
    /// 别改成 overlay + `alignmentGuide` 把封面挂到文字外面:封面不占布局就会压到文字上
    /// (见 07 章决策 33)。三块都参与布局,才不可能重叠。
    ///
    /// 左右各留 76pt:左边是常显的红绿灯,右边是悬停才出现的窗口控件。代价是有封面时标题
    /// 可用宽度少两个封面位,长标题会早一点被省略号截断。
    ///
    /// 三样全关(或选了的那几样这首歌恰好都没有值)就整组不摆 —— 空容器仍会吃掉 padding,
    /// 留一条莫名的空白。
    @ViewBuilder
    private var miniTopInfo: some View {
        let hasText = !miniHeaderParts.isEmpty || miniShowsTimeRow
        // 广告那一档没有图也要占位(画广告标识),所以不能只判 miniCoverImage。
        let hasCover = playback.miniShowsCover
            && (playback.isCurrentTrackAdBreak || miniCoverImage != nil)
        if hasText {
            HStack(spacing: Self.miniCoverGap) {
                if hasCover { miniCover }
                // 贴得紧一点才读成"一组",松开就成了几条互不相干的信息。
                VStack(spacing: Self.miniInfoLineSpacing) {
                    miniHeader
                    miniTimeRow
                }
                // 跟封面同宽的透明占位:让文字两侧等宽,文字才在正中。
                if hasCover {
                    Color.clear.frame(width: miniCoverSide, height: 1)
                }
            }
            .padding(.horizontal, 76)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
        } else if hasCover {
            miniCover
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
        }
    }

    /// 封面小图和文字块之间的空。
    private static let miniCoverGap: CGFloat = 8

    /// 顶部信息那一组左边那枚封面小图。
    ///
    /// 按 `边长 × 显示倍率`**预先重采样成位图再贴**,不在运行期缩 —— 半调网点封面在小图上会缩成
    /// 摩尔纹黑斑,全 App 的小封面都走这条(理由与算法见 ArtworkThumbnail / ArtworkThumbnailCache)。
    ///
    /// 拿不到封面就整个不画,不摆占位方块:迷你窗每一寸都是内容,一个灰方块既不提供信息、又把
    /// 旁边的文字往右推。
    @ViewBuilder
    private var miniCover: some View {
        if playback.miniShowsCover {
            if playback.isCurrentTrackAdBreak {
                // 广告期间让位成广告标识:播放器这时给的是**广告物料**的缩略图,当成"正在听的这张
                // 专辑"摆出来最误导。全 App 的封面位在广告期间统一这么让位(清单见 05 章「广告态」),
                // 这是第五个;底和符号都照完整布局那张大卡,只是尺寸小一档。
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hasArtworkBackground ? Color.white.opacity(0.1) : Color.primary.opacity(0.06))
                    .frame(width: miniCoverSide, height: miniCoverSide)
                    .overlay {
                        Image(systemName: "megaphone.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(miniSecondaryColor)
                    }
            } else if let image = miniCoverImage {
                let scale = max(1, displayScale)
                Group {
                    if let bitmap = ArtworkThumbnailCache.bitmap(
                        for: image, pixelSide: Int((miniCoverSide * scale).rounded())) {
                        Image(decorative: bitmap, scale: scale)
                    } else {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: miniCoverSide, height: miniCoverSide)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }

    /// 台卡优先、其次高清替代 —— 口径跟完整布局那张大封面一字不差(漏了哪一层,表现就是同一首歌
    /// 两处封面不一样)。广告那一档不走这里,见 `miniCover`。
    private var miniCoverImage: NSImage? {
        radioTalkStation?.image ?? playback.highResArtworkImage ?? playback.artworkImage
    }

    /// 第一行(主角,一般是歌名)。
    private static let miniInfoFontSize: CGFloat = 12
    /// 第二行(其余几样合成一行,一般是「歌手 — 专辑」)。
    private static let miniSubInfoFontSize: CGFloat = 11
    private static let miniTimeFontSize: CGFloat = 10
    private static let miniInfoLineSpacing: CGFloat = 1
    /// 封面小图的边长区间。上限让它始终是"文字旁边的一枚小标记",不跟着三行文字长成一块方图;
    /// 下限是只剩一行时还认得出是什么图。
    private static let miniCoverMinSide: CGFloat = 24
    private static let miniCoverMaxSide: CGFloat = 32

    /// 封面小图的边长 = 右边那叠文字的高度,夹在 24...32 之间(行多时不再跟着长)。
    ///
    /// **按"哪几行开着"算出来,而不是让 SwiftUI 把它撑开**(`maxHeight: .infinity` 那种):这张图
    /// 要先知道边长才能**按像素预先重采样**(见 miniCover),跟着布局撑开就只剩运行期缩一条路,
    /// 而那正是要避开的那件事(半调网点封面会缩出摩尔纹黑斑)。
    ///
    /// 行高按字号 × 1.3 估(SwiftUI 系统字的默认行高比例),差个一两 pt 只是封面比文字块高/矮
    /// 一线,靠 HStack 居中吸收掉,看不出来。
    private var miniCoverSide: CGFloat {
        let lines = miniHeaderLines.count
        let mainLines: CGFloat = lines > 0 ? 1 : 0
        let subLines: CGFloat = lines > 1 ? 1 : 0
        let timeLines: CGFloat = miniShowsTimeRow ? 1 : 0
        let rows = mainLines + subLines + timeLines
        guard rows > 0 else { return Self.miniCoverMinSide }
        let height = mainLines * (Self.miniInfoFontSize * 1.3)
            + subLines * (Self.miniSubInfoFontSize * 1.3)
            + timeLines * (Self.miniTimeFontSize * 1.3)
            + max(0, rows - 1) * Self.miniInfoLineSpacing
        return min(Self.miniCoverMaxSide, max(Self.miniCoverMinSide, height.rounded()))
    }

    /// 顶部信息里要显示的那几样(歌名 / 歌手 / 专辑,见 LyricsWindowMiniHeaderFields)。
    ///
    /// **别直接把播放器报的 title / artist / album 摆上来。** 广告期间那三样装的是**广告物料**
    /// 的字段 —— Spotify 会把广告词塞进 title(实测「Listen to music, ad-free.」),照搬出来就是
    /// 把广告词当歌名摆在这扇窗最顶上。判断口径跟完整布局左栏那套(`displayTitle` /
    /// `displayArtist`)同源,别在这儿另写一份。
    private var miniHeaderParts: [String] {
        // 广告期间**整行不摆**,而不是改摆「广告中」:正下方的歌词区已经在说「广告中」了
        // (走同一份 `emptyStateSpec`),头上再说一遍是同一件事说两遍 —— 菜单栏面板遇到同一件事
        // 走的也是"这一格留空"那一支。
        if playback.isCurrentTrackAdBreak { return [] }
        // 口白换成台名:那不是广告,台名就是此刻"在放什么"的答案(同完整布局)。
        if let station = radioTalkStation { return [station.name] }
        return playback.miniHeaderFields.visibleValues(
            title: playback.title, artist: playback.artist, album: playback.album)
    }

    /// 顶部文字最多两行:第一样独占第一行,其余几样用「 — 」合成第二行(Apple Music 迷你播放器
    /// 同款的「歌手 — 专辑」)。
    ///
    /// 排版规则跟"选了哪几样"解耦 —— **第一样**用主色加粗、其余用次要色。所以只选「歌手」时
    /// 歌手就是那个主角,不会出现"次要色的孤零零一行"。
    ///
    /// **别把三样全串进一行**:长歌名一挤,歌手和专辑就全被省略号切掉;也别再拆成三行 ——
    /// 顶部这一块每多一行,歌词区就矮一截。歌名单独一行、次要信息合一行是两头的平衡点。
    private var miniHeaderLines: [String] {
        let parts = miniHeaderParts
        guard let first = parts.first else { return [] }
        let rest = parts.dropFirst()
        return rest.isEmpty ? [first] : [first, rest.joined(separator: " — ")]
    }

    @ViewBuilder
    private var miniHeader: some View {
        let lines = miniHeaderLines
        if !lines.isEmpty {
            VStack(spacing: Self.miniInfoLineSpacing) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i])
                        .font(.system(size: i == 0 ? Self.miniInfoFontSize : Self.miniSubInfoFontSize,
                                      weight: i == 0 ? .semibold : .regular))
                        .foregroundStyle(i == 0 ? miniPrimaryColor : miniSecondaryColor)
                }
            }
            // 每一行只占一行,不许折:折了之后这一块的高度就跟着歌名长短忽高忽低,歌词区也跟着上下跳。
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }

    /// 顶部第二行:「已播 / 总长」。
    ///
    /// 时钟走 `NotchTimeFormat.clockSchedule(for:)` 而不是随便一个 `.periodic(by: 1)` —— 那个函数
    /// 存在的理由就是这件事:曲目位置的整秒边界跟墙钟整秒**没有关系**,相位差由 seek/换歌那一刻的
    /// 锚点定死并在整条锚点生命周期里是常量,钉墙钟的话这一行可能**整首歌**都比同屏别的时间显示
    /// 慢一秒(而不是偶尔闪一下)。`mmss` 也用它那份,别为这一行再写第二个格式化函数。
    ///
    /// 拖进度条时显示**手指按住的位置**,跟条子本身同步 —— 条子跳到那儿而数字还报旧位置的话,
    /// 拖着找副歌根本没法用。
    @ViewBuilder
    private var miniTimeRow: some View {
        if miniShowsTimeRow, let total = playback.currentDurationMs {
            TimelineView(miniClockSchedule) { ctx in
                let posMs = miniScrubFraction.map { Int($0 * Double(total)) }
                    ?? miniPositionMs(now: ctx.date)
                Text(NotchTimeFormat.mmss(ms: posMs) + " / " + NotchTimeFormat.mmss(ms: total))
                    .font(.system(size: Self.miniTimeFontSize).monospacedDigit())
                    .foregroundStyle(miniSecondaryColor)
            }
        }
    }

    /// 时间那一行此刻摆不摆。抽出来是因为上面那一组要先知道"右边到底有没有文字",
    /// 才能决定整组摆不摆(封面全关、文字也全空时,整组连 padding 一起省掉)。
    private var miniShowsTimeRow: Bool {
        playback.miniShowsTime && (playback.currentDurationMs ?? 0) > 0
    }

    /// 时间行那条秒表。没有锚点(没在放 / 还没拿到位置)时退回墙钟整秒 —— 那时数字本来就不动。
    private var miniClockSchedule: PeriodicTimelineSchedule {
        guard let anchor = playback.anchor else {
            return .periodic(from: NotchTimeFormat.clockEpoch, by: 1)
        }
        return NotchTimeFormat.clockSchedule(for: anchor)
    }

    /// 迷你这一格的"此刻播到哪"(毫秒)。锚点外推 ?? 暂停冻结位置 —— 跟逐字填色、间奏三点
    /// 同一套口径,三处必须同源,否则同一扇窗里的数字、填色、点亮进度会互相对不上。
    private func miniPositionMs(now: Date) -> Int {
        let coordinator = PlaybackCoordinator.shared
        return coordinator.anchor?.extrapolatedPositionMs(now: now)
            ?? coordinator.pausedPositionMs ?? 0
    }

    /// 中间:当前行(逐字填色)+ 它的读音/译文 + 下一行(压暗)。
    ///
    /// 当前行和它那两条副行是**一组**(内层 VStack 用更紧的行距),跟下一行之间才拉开 —— 不这样
    /// 的话四行等距排下来,看不出"译文是属于上面那句的"。
    ///
    /// 读音这里只画**整行**的那一份,不做完整布局里那套逐词对齐(`usesPerWordRomanization`):
    /// 逐词要给每个词留出读音的宽度,在 460pt 宽里会把一句话挤成两三行,而迷你统共就这么高。
    @ViewBuilder
    private func miniLyrics(fontSize: CGFloat) -> some View {
        VStack(spacing: fontSize * 0.34) {
            if let gap = miniCurrentGap {
                // 间奏:三颗呼吸点**顶替**当前行的位置(完整布局是把它插在滚动列表里对应那一行
                // 之后,迷你只有"当前"这一格,所以是顶替不是插入)。点亮算法/呼吸曲线走跟悬浮歌词、
                // 完整布局同一个 LyricsGapDotsView,比例也照完整那份(点 0.32 字号、间距 0.3)。
                LyricsGapDotsView(
                    startMs: gap.startMs, endMs: gap.endMs,
                    dotSize: fontSize * 0.32, spacing: fontSize * 0.3,
                    color: miniPrimaryColor,
                    isPlaying: playback.isPlayingNow, isVisible: windowController.isSurfaceVisible,
                    reduceMotion: reduceMotion
                ) { _ in
                    // 时间基准跟逐字填色同一套:外推位置 + 当前歌词偏移(间奏窗口是歌词原始
                    // 时间轴)。暂停时 anchor 为 nil,退回冻结位置,点定格在当下的亮度。
                    (playback.anchor?.extrapolatedPositionMs()
                        ?? playback.pausedPositionMs ?? gap.startMs)
                        + PlaybackCoordinator.shared.currentLyricsOffsetMs
                }
                .frame(height: fontSize * 0.5)
            } else if miniCurrentLine == nil, !playback.hasLyricsContent {
                // 没歌词时不留一片空白:那会让人以为窗口坏了。
                //
                // 文案走完整布局那套 `emptyStateSpec`,别在这儿另写一句 —— 它分了「没有在播放 /
                // 广告中 / 口白 / 纯音乐 / 暂无歌词 / 网络连接失败 / 搜索歌词中…」七档,而且**顺序
                // 有讲究**(广告和纯音乐必须排在"搜索中"前面,否则那两种情况会一直显示"搜索中"
                // 并且永远没有下文)。这里原来硬写「暂无歌词」,于是还在搜的时候就把"没有"当成
                // 结论报出去了。
                Text(emptyStateSpec.text)
                    .font(.overlayFont(familyName: activeFontFamily,
                                       size: fontSize * 0.62, weight: .medium))
                    .foregroundStyle(miniSecondaryColor)
            }
            // 当前行 + 下一行。控制条浮出来时下一行**照常显示**(它下面那格已经给控制条预留好了,
            // 见 miniDeckReserve);悬停进出不许摘掉或挪动它 —— 摘掉是一次真重排,当前行会上下弹。
            MiniLyricsReel(
                current: miniCurrentGap == nil ? miniCurrentLine : nil,
                next: miniNextLine,
                fontSize: fontSize,
                fontFamily: activeFontFamily,
                color: miniPrimaryColor,
                secondaryColor: miniSecondaryColor,
                showRomanization: playback.showRomanization,
                showTranslation: playback.showTranslation,
                lineOverflow: playback.miniLineOverflow,
                timing: playback.miniLineOverflow == .scroll ? miniReelTiming : nil,
                isPlaying: playback.isPlayingNow && windowController.isSurfaceVisible,
                fillSettled: playback.currentLineFillSettled,
                reduceMotion: reduceMotion,
                displayScale: displayScale
            )
            .equatable()
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    /// 控制条的高度(玻璃胶囊 22 内容 + 上下 6 内衬 = 34)。
    private static let miniDeckHeight: CGFloat = 34
    /// 底边进度条**占的布局高度**。静止和悬停一律是它,变粗只是往上溢出地画,见 miniProgressBar。
    private static let miniBarHeight: CGFloat = 3
    /// 悬停时进度条画多粗。
    private static let miniBarHoverHeight: CGFloat = 7
    /// 歌词区下面给控制条常驻预留的高度:从进度条上沿量到控制条上沿,再留 4pt 空。
    ///
    /// 控制条被整个关掉(`miniShowsControls` 为 false)时不留 —— 那格就是白白吃掉的歌词高度。
    /// 预览里照样留:预览要画的是"没悬停时这扇窗的样子",少了这一格歌词位置就对不上。
    private var miniDeckReserve: CGFloat {
        guard playback.miniShowsControls else { return 0 }
        return Self.miniDeckBottomInset + Self.miniDeckHeight - Self.miniBarHeight + 4
    }

    /// 控制条离窗底多远。
    ///
    /// 18 = 悬停时进度条画 7pt,底下再留 11pt 的空 —— 贴太近两者会读成一整块。下限是进度条那
    /// 13pt 的命中区(3pt 布局 + 往上撑的 10pt,见 miniProgressBar 的负 padding):小于它,
    /// 控制条的胶囊会盖在命中区上,那一条就按不到了。它每大 1pt,`miniDeckReserve` 就从歌词区
    /// 多吃 1pt。
    private static let miniDeckBottomInset: CGFloat = 18

    /// 底边那条进度条。悬停时变粗、长出圆头滑块,并且**可以拖**。
    ///
    /// 贴死窗口下沿、不留边距(参考图就是这个做法):它既是进度、也是这扇小窗的视觉底边。
    /// 刷新频率 4Hz —— 进度条一格像素要好几秒才走完,没有任何理由跟着逐字填色跑 60Hz。
    ///
    /// 拖的那套跟完整布局那条(`WindowProgressSection.progressBar`)同一条规矩:拖动中显示
    /// **手指按住的位置**而不是真实播放位置(否则条子会在手指底下往回跳),**松手才发 seek**,
    /// 按下第一帧给一次触觉。位置存 `@GestureState` 不存 `@State` —— 手势被系统取消时
    /// (拖到一半这首播完、进度条所在分支整块被摘掉)不会调 onEnded,用 `@State` 的话会永久
    /// 冻在最后一次 onChanged 的值。
    ///
    /// **悬停变粗不许改这一条占的布局高度。** 它是那个 VStack 的最后一格,长高 4pt 就等于
    /// 把上面整块歌词往上顶 4pt —— 表现是"鼠标一放上去,歌词整块跳一下"。
    /// 现在布局恒占 `miniBarHeight`,变粗是**底对齐地往上溢出着画**(SwiftUI 默认不裁剪),
    /// 溢出的那 4pt 落在歌词区底部的 Spacer 上,盖不到任何字。
    private var miniProgressBar: some View {
        let total = playback.currentDurationMs ?? 0
        let thick = miniControlsVisible ? Self.miniBarHoverHeight : Self.miniBarHeight
        // 暂停 / 窗口不可见时停表:位置不动,条子就不用每秒重画四次(暂停中拖动、seek 会改
        // miniScrubFraction / pausedPositionMs,照样触发重算,不靠这个时钟)。
        return TimelineView(.animation(minimumInterval: 0.25,
                                       paused: !playback.isPlayingNow || !windowController.isSurfaceVisible)) { ctx in
            let played = total > 0
                ? min(1, max(0, Double(miniPositionMs(now: ctx.date)) / Double(total))) : 0
            let fraction = miniScrubFraction ?? played
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(miniPrimaryColor.opacity(0.18))
                    Rectangle()
                        .fill(miniPrimaryColor.opacity(0.85))
                        .frame(width: g.size.width * fraction)
                    if miniControlsVisible {
                        // 滑块直径**等于**悬停时的条高,不能更大:这条贴死窗底,超出的那半个圆
                        // 会被窗口边沿直接切掉,看着像个半圆缺口。
                        Circle()
                            .fill(Color.white)
                            .frame(width: thick, height: thick)
                            .offset(x: max(0, g.size.width * fraction - thick / 2))
                    }
                }
                .frame(height: thick)
                // 布局只认 g.size.height(= miniBarHeight),多出来的那几 pt 向上溢出。
                .frame(height: g.size.height, alignment: .bottom)
                .onAppear { miniScrubWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in miniScrubWidth = w }
            }
        }
        .frame(height: Self.miniBarHeight)
        // 3~7pt 的条子直接按太细。往上撑 10pt 做命中区,再用**等量负 padding** 把布局高度
        // 抵消回去 —— 不抵消的话窗底会凭空多出一截空白,歌词区跟着矮一圈。
        .padding(.top, 10)
        .contentShape(Rectangle())
        .padding(.top, -10)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($miniScrubFraction) { value, state, _ in
                    guard total > 0, miniScrubWidth > 0 else { return }
                    // 只有这次手势的第一帧 state 才是 nil,拿它当"刚按下"的边沿信号给一次触觉;
                    // 放 onChanged 里会每帧都震。
                    if state == nil {
                        NSHapticFeedbackManager.defaultPerformer.perform(
                            .alignment, performanceTime: .now)
                    }
                    state = min(1, max(0, value.location.x / miniScrubWidth))
                }
                .onEnded { value in
                    guard total > 0, miniScrubWidth > 0 else { return }
                    let f = min(1, max(0, value.location.x / miniScrubWidth))
                    PlaybackCoordinator.shared.seek(toMs: Int(f * Double(total)))
                }
        )
    }

    // MARK: 迷你控制条

    /// 控制条此刻露不露。
    ///
    /// **拖进度时强制留着**:拖着拖着指针滑出窗口,`onHover` 会报 false,控制条连同正在拖的
    /// 那根条子一起消失 —— 手势的宿主被摘掉,SwiftUI 直接当手势取消,松手根本不 seek。
    ///
    /// 预览里整个不摆,同左上角那两颗窗口控件的理由:预览是设置页里的一张画,按下去会真的
    /// 切歌/改音量,而看的人以为自己只是在看效果。
    private var miniControlsVisible: Bool {
        playback.miniShowsControls && !previewMode && (miniHovered || miniScrubFraction != nil)
    }

    /// 玻璃胶囊的描边。有封面背景时走白色 —— 那一圈亮边正是"玻璃光泽"的来源;纯色底下
    /// 白边会显得脏,退回中性描边。口径跟音量胶囊、左上角窗口控件那两颗一字不差。
    private var miniCapsuleRim: Color {
        hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10)
    }

    /// 悬停时露出来的控制条:走带三键 · 音量 · 歌词时间轴微调。
    ///
    /// **收哪三样的判据:按一下就完事、不存盘的"这一刻的播放动作"。**背景 / 字体 / 字号那些
    /// "这扇窗长什么样"的旋钮一律不收 —— 它们在设置页里而且**迷你和完整各存一套**,搬一份
    /// 进来就是同一个值两个入口、两种控件形态。对标物 FloatLyrics 把字号/不透明度/主题三根
    /// 滑杆都摆在窗里,那是因为它压根没有设置页。够不着的走「⋯」菜单和设置页。
    private var miniDeck: some View {
        HStack(spacing: 8) {
            miniTransportPill
            WindowVolumeCapsule(onArtwork: hasArtworkBackground,
                                showsOutputMenu: .constant(false),
                                isExternalOutput: false,
                                compact: true)
            miniOffsetPill
        }
        .frame(height: Self.miniDeckHeight)
    }

    private var miniTransportPill: some View {
        HStack(spacing: 10) {
            Button { MusicPlaybackController.previousTrack() } label: {
                Image(systemName: "backward.fill").font(.system(size: 12))
                    .modifier(miniDeckHover)
            }
            .help(L10n.t("上一首"))
            Button {
                // 走 coordinator 的乐观回声版,不直接发命令:图标点击即动,不等 0.5~1s 的
                // 轮询回读(见 userTogglePlayPause 注释)。同完整布局那排。
                PlaybackCoordinator.shared.userTogglePlayPause()
            } label: {
                // 图标跟观感层 isPlayingSmoothed 走(不是 isPlayingNow 真值):点击瞬间翻转,
                // 还顺带吸掉切歌间隙真值抖 false 时图标闪一下的毛病。
                Image(systemName: playback.isPlayingSmoothed ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    // 播放/暂停两个图标宽度不同,固定住,否则两侧的键会跟着左右跳。
                    .frame(width: 17)
                    .modifier(miniDeckHover)
            }
            .help(L10n.t("播放/暂停"))
            Button { MusicPlaybackController.nextTrack() } label: {
                Image(systemName: "forward.fill").font(.system(size: 12))
                    .modifier(miniDeckHover)
            }
            .help(L10n.t("下一首"))
        }
        // AM 式点按反馈:按下快缩、松手弹回。跟完整布局那排五颗同一个 style。
        .buttonStyle(TransportButtonStyle(reduceMotion: reduceMotion))
        .foregroundStyle(miniPrimaryColor)
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .clearGlassCapsule(rim: miniCapsuleRim)
    }

    /// 迷你控制条上各个小键的悬停底块(见 HoverHighlight)。取色跟控制条图标同一个颜色 —— 用户
    /// 把文字钉成深色时,底块也跟着是深色。扩 4:胶囊内高 22、上下各 6,底块 30 刚好不顶到胶囊边。
    private var miniDeckHover: HoverHighlight {
        HoverHighlight(tint: miniPrimaryColor, inset: 4, cornerRadius: 7,
                       hoverOpacity: 0.16, pressOpacity: 0.26)
    }

    /// 「歌词时间轴」微调。左「−」=延后、右「＋」=提前,跟菜单栏面板和完整布局那行一致
    /// (那边已经为同一个反直觉问题定过稿:"想歌词快一点应该点右边")。
    ///
    /// 跟完整布局那行有两处**故意不同**:
    ///   ① 当前值**一直显示**(没调过就是 0.0s)且宽度钉死。那边是"调过才出现数字和重置",
    ///      靠右侧的 ± 锚定不动;这里横向预算只有 460pt,数字进出会把两颗键推来推去,连点
    ///      第二下就点空了。
    ///   ② 没有单独的「重置」键 —— 改成**点那个数字**就归零(只在非 0 时才是个键,那时它自带
    ///      底色和手型,不是一段看不出能点的文字)。多一颗键这一格就超宽了。
    private var miniOffsetPill: some View {
        let trackMs = playback.trackLyricsOffsetMs
        let stepMs = AppSettings.shared.lyricsOffsetStepMs
        let stepHelp = AppSettings.formattedSeconds(ms: stepMs) + L10n.t("秒")
        return HStack(spacing: 4) {
            Text(L10n.t("歌词"))
                .font(.system(size: 11))
                .foregroundStyle(miniSecondaryColor)
            miniNudge("minus", help: L10n.t("延后") + " " + stepHelp) {
                PlaybackCoordinator.shared.nudgeLyricsOffset(by: -stepMs)
            }
            miniOffsetValue(trackMs)
            miniNudge("plus", help: L10n.t("提前") + " " + stepHelp) {
                PlaybackCoordinator.shared.nudgeLyricsOffset(by: stepMs)
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .clearGlassCapsule(rim: miniCapsuleRim)
    }

    /// 偏移读数。口径同菜单栏 `offsetMenuTitle`:只报**这首歌**的微调,不含全局基准 ——
    /// 含了的话点「重置」之后数字对不上操作。
    @ViewBuilder
    private func miniOffsetValue(_ trackMs: Int) -> some View {
        let text = Text(AppSettings.signedSeconds(ms: trackMs) + "s")
            .font(.system(size: 11).monospacedDigit())
            // 宽度钉死:0.0 / +0.2 / −1.4 字形宽度不同,不钉的话每点一下整颗胶囊都在呼吸。
            .frame(width: 38)
        if trackMs == 0 {
            text.foregroundStyle(miniSecondaryColor)
        } else {
            Button { PlaybackCoordinator.shared.resetLyricsOffset() } label: {
                text
                    .foregroundStyle(miniPrimaryColor)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(miniPrimaryColor.opacity(0.16))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(WindowActionButtonStyle(onArtwork: hasArtworkBackground, inset: 0, cornerRadius: 5))
            .help(L10n.t("重置"))
        }
    }

    private func miniNudge(_ symbol: String, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(miniPrimaryColor)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        // ± 两颗之间只隔 4pt、中间还夹着读数,底块不往外扩,就是 20×20 的框本身。
        .buttonStyle(WindowActionButtonStyle(onArtwork: hasArtworkBackground, inset: 0, cornerRadius: 6))
        .help(help)
    }

    /// 此刻在不在间奏里(含前奏,它的 index 是 -1)。在的话当前行那一格画三颗点。
    private var miniCurrentGap: LyricsGapMarker? {
        guard let idx = playback.currentGapIndex else { return nil }
        return playback.lyricsGapMarkers.first { $0.index == idx }
    }

    /// 当前行 / 下一行。`currentLineIndex` 为 nil(还没唱到第一句)时,把第一句当"下一行"预告。
    private var miniCurrentLine: LyricsWindowLine? {
        MiniLyricsSelection.currentIndex(currentLineIndex: playback.currentLineIndex,
                                         lineCount: playback.allLines.count)
            .map { playback.allLines[$0] }
    }

    /// 播放时间基准的指纹:重新锚定(拖进度、位置校正)、暂停位置、歌词时间轴偏移任一变了就变。
    /// 只在滚动档喂给 reel —— 图层版那一行的填色 / 滚动是装好就自己跑的关键帧动画,时间基准变了
    /// 得有人叫它重对一次;换行档每帧自己读时钟,不需要。
    private var miniReelTiming: MiniLyricsReel.Timing {
        MiniLyricsReel.Timing(
            anchorFetchedAt: playback.anchor?.fetchedAt,
            anchorProgressMs: playback.anchor?.progressMs,
            pausedPositionMs: playback.pausedPositionMs,
            offsetMs: PlaybackCoordinator.shared.currentLyricsOffsetMs)
    }

    private var miniNextLine: LyricsWindowLine? {
        MiniLyricsSelection.nextIndex(currentLineIndex: playback.currentLineIndex,
                                      lineCount: playback.allLines.count)
            .map { playback.allLines[$0] }
    }

    /// 文字色跟完整布局同一条判据(`lyricTextColor` / `lyricSecondaryTextColor`,它们自己会先看
    /// 「文字颜色」那颗设置、`.auto` 才回去问背景亮度),不另起一套。
    ///
    /// 迷你这两个还兼着**控制条和顶部信息**的颜色 —— 那两处在这个尺寸下紧挨着歌词、
    /// 跟歌词是同一块视觉,跟完整布局里那些贴边的 chrome 不是一回事,所以它们跟着文字色走是对的。
    private var miniPrimaryColor: Color { lyricTextColor }
    private var miniSecondaryColor: Color {
        // 副行比完整布局再淡一档(0.55 对 0.6)是迷你原有的口径,只在 `.auto` 档保留;
        // 其余三档一律走共用那份,免得同一颗设置在两个尺寸下深浅不一样。
        guard activeTextColorMode == .auto else { return lyricSecondaryTextColor }
        return hasArtworkBackground ? .white.opacity(0.55) : .secondary
    }

    /// 正常尺寸的完整布局:左封面/播控 + 右歌词双列,窗口拖窄到 640 以下退化成单列歌词。
    private var fullBody: some View {
        lyricsScrollReader { scrollProxy in
            GeometryReader { geo in
                // 按 Apple Music 歌词页一比一排:左列是封面卡片+曲目信息+进度条+播放控制,右列是
                // 左对齐的大字歌词。左列只在窗口够宽时显示——竖长窗口(~460pt)下硬塞两列会挤成
                // 一团,退化成只有歌词的单列,跟 Apple Music 自己把窗口拖窄时的行为一致。
                let showPlayerPane = geo.size.width >= 640
                // 布局比例一比一对齐 Apple Music 歌词页(按 AM 截图 1999px 宽逐项量出):封面左缘
                // 0.111W、封面宽 0.279W(上限 460pt,超宽窗口不再放大)、歌词文字左缘 0.515W、右缘留
                // 0.06W。面板贴左缘(3%W)、歌词从 0.34W 就开始的话整体重心偏左,跟 AM 那种"左右两半、
                // 各自大留白"的观感差一截。
                let coverWidth = min(geo.size.width * 0.279, 460)
                // 歌词栏只有双列模式可隐藏(单列=整窗都是歌词,关了剩空白,强制显示)。
                // showsListenHistory 也要算进来:右栏关着歌词、切到播放记录时这一项也得让右栏亮
                // 起来——漏了它的话,「隐藏歌词」再点「播放记录」会出现按钮显示已激活、右栏却因为
                // showsLyricsPane 仍是 false 而整块塌成空白(lyricsQueuePill 里两个开关各管各的,唯独
                // 这个"该不该显示整块右栏"的闸门容易只看 showsLyricsPane 一个)。
                let lyricsPaneVisible = showsLyricsPane || showsListenHistory || !showPlayerPane
                let paneLeading = lyricsPaneVisible
                    ? geo.size.width * 0.111
                    // 歌词隐藏 = AM 的"封面居中"纯播放器视图,左缘 padding 把封面推到正中。
                    : (geo.size.width - coverWidth) / 2
                // 停播欢迎态:整窗换成居中 hero,不摆一套没有内容的双列骨架(占位封面+悬空「⋯」+
                // 光杆播放键)。判据与 emptyStateSpec 第一档同源:停播时 LocalPlaybackSource 清曲目,
                // title 空。
                let isIdle = playback.title.isEmpty
                // 停播页宽窄断点。背景里柔光的锚点也吃它(宽窗唱片在左栏、窄窗居中),
                // 所以必须是同一个变量、不能两处各写一遍 860。
                let idleWide = geo.size.width >= 860
                Group {
                if isIdle {
                    // 三区版停播页(左上收听总览、左下上次那首 + 一句歌词、右列通高最近听过)。只在
                    // **窗口够宽**时用,窄窗仍走居中欢迎态 —— 与播放态那条 640pt 双列断点同一个思路,
                    // 硬塞两列会挤成一团。未连 Last.fm 时左上收听总览没有本地替代来源、直接省略,右列
                    // 改成本地待补提交清单(详见 IdleStandbyView 顶部注释)。
                    if idleWide {
                        IdleStandbyView(
                            player: idlePlayer,
                            onResume: { resumeFromIdle(player: idlePlayer) },
                            onOpenPlayer: { openIdlePlayerApp(idlePlayer) },
                            onOpenAlbum: { title, artist in
                                openCatalogPage(title: title, artist: artist, target: .album)
                            },
                            onOpenTrack: { title, artist in
                                openCatalogPage(title: title, artist: artist, target: .track)
                            })
                    } else {
                        idleWelcomeView
                            .offset(y: -geo.safeAreaInsets.top / 2)
                    }
                } else {
                HStack(spacing: 0) {
                    if showPlayerPane {
                        playerPane
                            .frame(width: coverWidth)
                            .padding(.leading, paneLeading)
                            .frame(maxHeight: .infinity)
                            // 垂直居中基准=**整窗**,不是 safe area:AM 左列内容中心落在整窗高度中点
                            // 429pt,而 hiddenTitleBar 仍有 ~28pt 顶部 inset,在 safe area 内居中会把整列
                            // 压低半个 inset。再 −2 是实拍残差(整列仍比 AM 低 4px@2x)。渲染偏移不影响布局。
                            .offset(y: -geo.safeAreaInsets.top / 2 - 2)
                    }
                    if lyricsPaneVisible {
                        // 「歌词」⟷「播放记录」是同一块地皮上的两种内容(见
                        // showsListenHistory 声明处),leading/trailing 沿用同一套
                        // 边距算法 —— 切换时两种内容的左右缘对得上,不会跳一下。
                        Group {
                            if showsListenHistory {
                                listenHistoryPane(
                                    leading: showPlayerPane
                                        ? max(24, geo.size.width * 0.515 - (geo.size.width * 0.111 + coverWidth))
                                        : 44,
                                    trailing: max(32, geo.size.width * 0.06))
                            } else {
                                rightPane(
                                    leading: showPlayerPane
                                        ? max(24, geo.size.width * 0.515 - (geo.size.width * 0.111 + coverWidth))
                                        : 44,
                                    trailing: max(32, geo.size.width * 0.06))
                            }
                        }
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
                .background(
                    ZStack {
                        artworkBackground
                        // 停播页背景(V2 中心柔光)。叠在 artworkBackground **之上**而不是
                        // 二选一:停播时那边本来什么都不画(windowBackgroundLayers 为 nil),
                        // 所以不是白画一层。用 opacity 而不是 if/else 是为了拿到一次交叉
                        // 淡入 —— 从「柔光底」硬切到「封面光斑场」很突兀。
                        IdleStandbyBackground(wide: idleWide)
                            .opacity(isIdle ? 1 : 0)
                    }
                    .animation(.easeInOut(duration: 0.45), value: isIdle)
                    .ignoresSafeArea())
                // 音量胶囊必须**浮在内容之上**,不能放进 .toolbar。
                //
                // Liquid Glass 的规则(见 LiquidGlassReference:"Glass cannot sample other glass"、
                // "Avoid Glass-on-Glass"、玻璃只用于**浮在内容之上**的导航层):工具栏本身就是一层
                // 玻璃,玻璃采样不到玻璃,只能退化成不透明材质。对照实验很直观 —— 同一个胶囊同时放进
                // 工具栏和内容浮层,同一张截图里工具栏那个是灰扁色块、浮层那个透出了背后模糊封面的
                // 暖棕色。
                .overlay(alignment: .topTrailing) {
                    // 音量胶囊自持订阅:soundVolume 故意不进 WindowPlayback 代理,拖音量只失效这个小
                    // 胶囊,不再整窗重估。右上只放它一颗(AM 右上就一颗音量胶囊,窗口动作胶囊在 AM 是
                    // 左上 X/画中画那颗 —— 置顶/全屏挪去左上同位,见下一个 overlay)。
                    //
                    // `!isIdle` 判断不能省,而且原因不只是"跟旁边那个 overlay 的判据保持一致":
                    // `PlaybackCoordinator.soundVolume` 读的是 `LocalPlaybackSource.lastResolvedBundleID`,
                    // 而那个字段读的是 `lastSnapshot?.bundleIdentifier` —— `lastSnapshot` **真正停播后也
                    // 从不清空**(SettingsView.offsetScope 那条注释也踩过同一个坑),所以就算歌词窗已经
                    // 判定 isIdle=true、切进了「停播页」,`soundVolume` 依然吐着最后一次播放时的音量值,
                    // 胶囊会照常渲染。不改底层那个"从不清空"的字段(它另有存在理由,见自身注释),只在
                    // 这一个消费点上判 isIdle。
                    // 预览里整个不摆,跟左上角那对置顶/全屏胶囊、右下角那两颗同一个判据(见
                    // previewMode 头注):设置页那张预览是给人看背景 / 字体 / 文字颜色的效果的,
                    // 而这颗胶囊既点不动(预览整块 allowsHitTesting(false))、又正好压在右上角,
                    // 留着只是挡住要看的东西。
                    if !isIdle, !previewMode {
                        WindowVolumeCapsule(onArtwork: hasArtworkBackground,
                                            showsOutputMenu: $showsOutputMenu,
                                            isExternalOutput: isExternalOutput)
                        // 贴右缘 5pt(AM 胶囊亮缘离窗缘 8px@2x,布局缘取 5 让亮缘落到同位)。
                        .padding(.trailing, 5)
                        // 胶囊**不能**落进窗口顶部那一段 safe-area 高度(geo.safeAreaInsets.top,与真实
                        // NSTitlebarContainerView 等高):hiddenTitleBar 窗口的这段区间在系统层面**无条件**
                        // 认领拖动,起手点落在里面就会被 WindowServer 直接接管去挪窗口,表现是"拖音量键把
                        // 窗口一起拖走"。
                        //
                        // 这不是 isMovableByWindowBackground、也不是"谁的 mouseDownCanMoveWindow 返回什么"
                        // 能改的:挂 NSViewRepresentable 覆写 mouseDownCanMoveWindow、直接 addSubview 到
                        // contentView 绕开 SwiftUI 树、自定义 NSWindow 子类覆写 sendEvent 整段吞掉再手动转发、
                        // 同步 nextEvent tracking loop(仿 NSControl 内部机制)—— 五种方案在独立 harness 里
                        // 逐一验证过,应用进程收到的 NSEvent 序列完全不受影响,没有任何应用层介入点。唯一
                        // 有效的办法是**不落在这段区间里**:y 越过这段高度的那一刻,挪窗口行为精确消失。
                        // 旁边的置顶/全屏/静音/AirPlay 键不受影响,因为它们是**点按**、没有拖动位移。
                        //
                        // 因此**不要**做"减去 safeAreaInsets.top 再加 8 去对齐红绿灯"那套 —— 那正是把胶囊往
                        // 危险区间里怼。让胶囊留在 safe-area 自然让出的位置(= 危险区间正下方)之后只再下移
                        // 8pt 留个观感缓冲,牺牲"与红绿灯同一行"的对齐(AM 参考图是那样,但那条约束与"拖动
                        // 不能挪窗口"这条硬约束冲突,后者优先)。
                        .offset(y: 8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // 置顶/全屏胶囊(AM 同位是 X/画中画那颗,x204-349px@2x → 左缘 102pt、高 71px
                    // 与右上音量胶囊一致)。
                    //
                    // 预览里不摆:它管的是**这扇窗自己**(置顶、伪全屏),而预览根本不是一扇窗 ——
                    // 摆一对点不动、也没有对应对象的窗口控件,只会让人以为预览坏了。
                    // 迷你模式下**照样要摆**:那是退出迷你的唯一入口 —— 左栏(「⋯」菜单所在)在
                    // 单列模式下根本不显示,而迷你窗必然是单列。胶囊自己会在迷你时收成两颗。
                    if !previewMode {
                        windowActionsCapsule()
                            .padding(.leading, 102)
                            .offset(y: -geo.safeAreaInsets.top + 8)
                    }
                }
                // 「…」的 AM 式自绘菜单:锚在按钮上方、右缘对齐按钮右缘(AM 的菜单就悬在那两颗圆钮
                // 上方)。放在**窗级** overlay 而不是按钮的 overlay:面板要浮在歌词列表之上,且"点面板
                // 外任何地方关掉"需要一层全窗捕手。
                //
                // 这一块只是锚点矩形的**搬运工**(理由详见 moreAnchorRect 的注释):面板本体不能挂
                // 在这个闭包里 —— 直接消费 geo[anchor] 会把整块玻璃面板焊在几何依赖链上,抓到过一次
                // 开着菜单时主线程 2472/2485 采样全忙的整窗逐帧重排。矩形取整后经 onChange 落进
                // @State,没动就一个字节都不写,面板在下面的普通 .overlay 里只随真实状态重建。
                .overlayPreferenceValue(MoreMenuButtonBoundsKey.self) { anchor in
                    if let anchor {
                        let r = geo[anchor].integral
                        Color.clear
                            .allowsHitTesting(false)
                            .onAppear { moreAnchorRect = r }
                            .onChange(of: r) { _, v in moreAnchorRect = v }
                    }
                }
                .overlay {
                    if showsMoreMenu, moreAnchorRect != .zero {
                        // 面板"贴按钮右缘、向右长出"而不是向左:按钮本来就在左栏靠右的位置,向左长出会
                        // 盖住左栏封面/曲目信息,向右正好落进歌词栏那片更空的区域。
                        ZStack(alignment: .bottomLeading) {
                            // 全窗点击捕手(透明但可命中),点哪都只是关菜单。
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsMoreMenu = false }
                                }
                                .transition(.opacity)
                            moreMenuPanel
                                .fixedSize()
                                .padding(.leading, moreAnchorRect.maxX)
                                .padding(.bottom, max(8, geo.size.height - moreAnchorRect.minY + 8))
                                // 缩放锚在面板左下角 —— 正好是贴着「…」按钮的那个角,
                                // 观感是从按钮上长出来(AM 同款,只是方向翻到右边)。
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                        }
                    }
                }
                // 「显示简介」面板:从「⋯」菜单点出,与菜单同锚点同样式。
                .overlay {
                    if showsInfoPanel, moreAnchorRect != .zero {
                        // 同「⋯」菜单本体一起翻到按钮右边(见上面那块的注释)—— 这个面板
                        // 就是从「⋯」菜单里的「显示简介」点出来的,方向必须跟菜单一致,
                        // 不然会出现"菜单在右边、点进去的子面板跳回左边"的错位。
                        ZStack(alignment: .bottomLeading) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsInfoPanel = false }
                                }
                                .transition(.opacity)
                            trackInfoPanel
                                .fixedSize()
                                .padding(.leading, moreAnchorRect.maxX)
                                .padding(.bottom, max(8, geo.size.height - moreAnchorRect.minY + 8))
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                        }
                    }
                }
                // 「你的常听」面板(Last.fm 系列):同锚点同样式的第三块面板。
                .overlay {
                    if showsChartsPanel, moreAnchorRect != .zero {
                        // 同上,跟「⋯」菜单本体一起翻到按钮右边。
                        ZStack(alignment: .bottomLeading) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsChartsPanel = false }
                                }
                                .transition(.opacity)
                            ChartsPanelView()
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 300)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                                .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
                                .padding(.leading, moreAnchorRect.maxX)
                                .padding(.bottom, max(8, geo.size.height - moreAnchorRect.minY + 8))
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                        }
                    }
                }
                // 右下角「翻译与发音」按钮(AM 歌词页同位;外观严格对拍:AM 该钮
                // 71×71px@2x=35.5pt——与顶部胶囊同高度档,贴角 右10/底11pt;译文正在显示时是**激活态**
                // =近白填充圆+深色字形(填充亮度 220 vs 背景 70),未激活=与顶部胶囊同款 clearGlass
                // 玻璃圆)。只在当前曲目真有译文或罗马音时出现 —— 两行全灰的菜单比没有更糟。
                .overlay(alignment: .bottomTrailing) {
                    // 右下角一排(AM 歌词页同布局):翻译圆钮 + [歌词|队列] 双钮胶囊。间距/边距照 AM 量:
                    // 胶囊贴角 右10/底11,翻译钮在其左、间隔 8.5(AM 翻译钮右缘距窗缘 90.5pt=10+71.5+8.5)。
                    // 同左上那对窗口控件:预览里整排不摆。这两颗切的是**这一份视图自己的会话状态**
                    // (要不要显示歌词栏 / 换成播放记录 / 开翻译菜单),在预览里既点不动,切出来的
                    // 状态也只属于预览这一份实例,跟用户真打开的那扇窗没关系。
                    HStack(spacing: 8.5) {
                        if !previewMode, !isIdle,
                            playback.hasLyricsContent && (trackHasTranslation || trackHasRomanization)
                            && lyricsPaneVisible {
                            Button {
                                withAnimation(.easeOut(duration: 0.12)) { showsTranslationMenu.toggle() }
                            } label: {
                                translationButtonLabel
                            }
                            .buttonStyle(.plain)
                            .help(L10n.t("译文与罗马音"))
                            .anchorPreference(key: TranslationMenuButtonBoundsKey.self, value: .bounds) { $0 }
                        }
                        if !previewMode, !isIdle { lyricsQueuePill(showPlayerPane: showPlayerPane) }
                    }
                    .padding(.trailing, 10)
                    .padding(.bottom, 11)
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
                // 音频输出面板(AirPlay 键弹出):同「⋯」菜单的窗级自绘玻璃
                // 面板机制,锚在按钮**下方**(AM 的输出面板悬在胶囊下方)。 按钮的锚点
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
                    currentSource: ctx.currentSource, currentFingerprint: ctx.currentFingerprint,
                    durationSecs: ctx.durationSecs
                ) { candidate in
                    // reload(onlyIfChanged:) 兜住「store 还没加载过」:saveEdit 直接改
                    // raw[key],空 raw 上写会把条目的其它字段(cover_url 等)整个丢掉。
                    await EnrichCacheStore.shared.reload(onlyIfChanged: true)
                    // 仅纯文本的候选走独立的存法(见 savePlainTextEdit 头注)——不能
                    // 跟带时间戳的候选共用 saveEdit,那会把纯文本当成一份"没有任何一行
                    // 能同步显示"的坏 LRC 写进 lyrics,反而让这首歌在别的展示面上从
                    // "至少有静态文字"退化成"看起来完全没有歌词"。
                    let saved: Bool
                    if candidate.isPlainTextOnly {
                        saved = await EnrichCacheStore.shared.savePlainTextEdit(
                            key: ctx.key, plainLyrics: candidate.lyrics, source: candidate.source)
                    } else {
                        // 必须显式传 markManual / sourceChoice:落进 saveEdit 的默认值 markManual: true
                        // 的话,「歌词窗口」里搜一次、采纳一次就把这首歌**永久冻结**了,以后打分改进/该源
                        // 补出逐字都再也不会被采纳,而用户只是想换份词。
                        //
                        // 这是「采纳候选」的第三个入口(另外两个:歌词管理、悬浮窗 ⚙ 的「搜索歌词…」小窗)。
                        // 三处必须同进同出 —— 改任何一处之前先 grep `LyricsSearchSheet(` 数清楚有几个。
                        saved = await EnrichCacheStore.shared.saveEdit(
                            key: ctx.key,
                            lyrics: candidate.lyrics, tr: candidate.lyricsTr,
                            roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC,
                            source: candidate.source,
                            markManual: AppSettings.shared.manualPickLocksLyrics,
                            sourceChoice: "", fromManualPick: true)
                    }
                    // 让播放侧立刻重载,不等 2s 轮询的 mtime 检查。
                    PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
                    // 回报落盘成败:面板等它决定关窗/挪徽标(onApply 可等待,不用自己套 Task)。
                    return saved
                }
            }
        }
    }

    /// 歌词列表的滚动容器 + 自动滚动那一整套(换行滚到当前行、进间奏滚到呼吸点、换歌重新定位、
    /// 窗口从不可见恢复时补一次)。完整布局和迷你「多行」共用这一份 —— 两边各写一套 onChange,
    /// 迟早只改一边。
    @ViewBuilder
    private func lyricsScrollReader<Content: View>(
        @ViewBuilder content: @escaping (ScrollViewProxy) -> Content
    ) -> some View {
        ScrollViewReader { scrollProxy in
            content(scrollProxy)
            // 滚动跟 scrollLineIndex 走而不是 currentLineIndex(对拍 AM):
            // AM 的滚动**先于**染色 —— 一句唱完、下一句还没开始的空档里页面已经滚到下一句
            // 的位置,开唱那一刻只染色、不再滚动。scrollLineIndex 在空档里提前指向下一行
            // (逐字歌词才知道"唱完"是几点;行级 LRC 不抢跑,两个下标恒等,行为跟改前
            // 一致),染色/加粗/虚化仍全部看 currentLineIndex。
            .onChange(of: playback.scrollLineIndex) {
                // 窗口面不可见时不做滚动动画(没人看,被遮住/最小化的窗口也不会去合成),
                // 直接定位;并记一笔,恢复可见时再无动画定位一次兜底(已知坑 #17)。
                scrollToActiveLine(scrollProxy: scrollProxy, animated: windowController.isSurfaceVisible)
                if !windowController.isSurfaceVisible { scrollPendingWhileHidden = true }
            }
            .onChange(of: playback.currentGapIndex) {
                // 进入间奏 → 滚到那排「•••」(跟当前行同一个 41% 锚位)。出间奏不用管:
                // 下一句开始时 currentLineIndex 变化,上面那条 onChange 自然把页面滚过去。
                // intro(-1)不走 gapRowID:那一行刚在本次事务里插入、还没布局,scrollTo
                // 解析不到 —— 交给 scrollToActiveLine 的"滚第一句、锚 0.52"路径,再延一拍
                // 让布局先落地(实测同一事务里滚,圆点停在列表顶部)。
                if let g = playback.currentGapIndex {
                    let visible = windowController.isSurfaceVisible
                    if !visible { scrollPendingWhileHidden = true }
                    if g == -1 {
                        DispatchQueue.main.async {
                            scrollToActiveLine(scrollProxy: scrollProxy, animated: visible)
                        }
                    } else if let id = gapRowID(g) {
                        if visible {
                            withAnimation(Self.lineTransition) {
                                scrollProxy.scrollTo(id, anchor: Self.activeLineAnchor)
                            }
                        } else {
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
            .onChange(of: windowController.isSurfaceVisible) { _, visible in
                // 恢复可见:**只有**隐藏期间发生过换行/进出间奏才重定位,且无动画——用户手动
                // 翻看歌词后切个 Space 回来,不该被拽回当前行(那是今天没有的行为)。隐藏期间
                // 那次无动画 scrollTo 通常已经到位,这里是它在最小化窗口里没生效时的兜底。
                guard visible, scrollPendingWhileHidden else { return }
                scrollPendingWhileHidden = false
                DispatchQueue.main.async {
                    scrollToActiveLine(scrollProxy: scrollProxy, animated: false)
                }
            }
            .onChange(of: defersLyricsPaneResize) { _, deferring in
                // 松手 / 切完形态后字号可能一次跳到新尺寸,当前行会偏离锚位;等新字号排完(延一拍)
                // 无动画拉回来。
                guard !deferring else { return }
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
    }

    /// 滚动目标行的 id —— 用滚动锚 scrollLineIndex 而不是 currentLineIndex(空档里
    /// 提前指向下一行,见上面 onChange 的注释);兜底 currentLineIndex 只是防御性写法,
    /// 两者同一 tick 一起赋值,正常不会一有一无。
    private var activeID: String? {
        guard let idx = playback.scrollLineIndex ?? playback.currentLineIndex,
              playback.allLines.indices.contains(idx) else { return nil }
        return playback.allLines[idx].id
    }

    // Apple Music 歌词页把当前行定位在窗口偏上约 1/3 处(不是正中)——上面留少量已经
    // 唱过的行,下面留更多即将到来的行,从 .center 改过来。
    // 0.41:AM 整窗截图里当前行中心在窗高 691/1690 = 40.9% 处(量,原 0.35)。
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
        // 在它下方约窗高 52% 处(对照 AM 截图量出第一句中心 51.8%)。
        // 不能直接 scrollTo「•••」那一行 —— gapDotsRow 不活跃时整行不渲染,id 根本
        // 没注册,scrollTo 静默无效;激活的同一事务里滚,行还没布局同样无效(圆点会停在
        // 列表顶部)。也不能给它加零高占位行:
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

    /// 歌词正文字号。系数是从 AM 歌词页整窗截图(2940×1690 @2x,即
    /// 1470×845pt)量出来的:当前行「无敌铁金刚」墨高 89px,PingFang 粗体的墨高/字号比
    /// 0.88(离线 ImageRenderer 标定)→ 字号 50.6pt;除以窗高 845pt 得 0.0598×窗高,
    /// 除以右栏宽 896.7pt 得 0.0564×右栏宽。两个锚在 AM 自己的窗口纵横比下相等,取
    /// min:窗口偏矮时高度锚接管(保住"一屏约 7 行"),偏窄时宽度锚接管(别让长句
    /// 疯狂折行)。上界不再夹死在 56 上:AM 全屏字号能到 68pt+,一比一就该跟着长。
    private var lyricFontSize: CGFloat {
        // 迷你「多行」也吃设置里那根「字号」上限,跟两行那套同一个语义(上限,不是定值)。
        LyricsWindowTypography.listFontSize(
            columnWidth: lyricsColumnWidth, viewportHeight: lyricsViewportHeight,
            cap: showsMiniLayout ? CGFloat(playback.miniFontSizeCap) : nil)
    }
    // 罗马音/译文跟正文保持原来的比例(15/28、17/28)。
    /// 对唱行两侧留白的基准量(见 LyricDuetLayout)。在父视图算一次传下去 —— 每一行
    /// 自己去算的话,窗口拖动时整表行都要重跑同一个式子。
    private var duetInsetUnit: CGFloat {
        LyricDuetLayout.insets(
            for: .leading,
            availableWidth: lyricsColumnWidth,
            fontSize: lyricFontSize
        ).trailing
    }

    private var romaFontSize: CGFloat { lyricFontSize * 0.54 }
    private var translationFontSize: CGFloat { lyricFontSize * 0.61 }
    /// 行间距:AM 行距(基线到基线)218px / 字号 101px = 2.156em;单行 Text 视图高
    /// 1.175em(同一次 ImageRenderer 标定),VStack spacing = 2.156 − 1.175 ≈ 0.98em。
    /// 旧值 1.14em 比 AM 松 8%,是"一屏 7 行"差一口气的原因之一。
    private var lyricLineSpacing: CGFloat { lyricFontSize * 0.98 }

    @ViewBuilder
    /// `centered`:迷你「多行」传 true —— 没有对唱标记的行居中(同两行那套);有标记的行仍按声部
    /// 左 / 右 / 中分栏,那是在告诉你谁在唱。完整布局照 Apple Music 左对齐,不传。
    /// `wordRise`:正在唱的字要不要上浮。迷你两档都不要(07 章决策 42),完整布局要。
    private func rightPane(leading: CGFloat, trailing: CGFloat, centered: Bool = false,
                           wordRise: Bool = true) -> some View {
        if playback.isRadioTalkBreak {
            // 口白期间不显示任何歌词(电台曲和曲之间穿插口白时,标题与封面都已经换成台名台标,
            // 这一栏不挡的话还在滚上一首歌的词)。
            //
            // 这道闸必须排在 `allLines.isEmpty` **之前**。只改 emptyStateSpec 不够 —— 那是
            // 「一行歌词都没有」时的占位,而口白期间上一首的 allLines 原封不动地留着,压根走不到
            // 空状态。灵动岛 / 悬浮窗只显示"当前这一行",各自的 isRadioTalkBreak 分支天然盖住了;
            // 只有这里是整段列表,得单独挡。
            //
            // 复用 emptyState:它的文案与图标本来就由 emptyStateSpec 按同一个判据给出「口白」+
            // `dot.radiowaves.left.and.right`,不另写一套。纯文本兜底(plainLyricsFallback)一并挡掉
            // —— 那同样是上一首的词。
            emptyState
        } else if playback.allLines.isEmpty {
            // 没有能同步显示的版本,但用户在「搜索候选歌词」里采纳过一条纯文本兜底
            // (见 currentTrackPlainLyrics 声明处注释)——「歌词窗口」是目前唯一认这个
            // 字段的展示面,当静态文字读;不跟播放位置联动,不高亮,不自动滚动。
            if !playback.currentTrackPlainLyrics.isEmpty {
                plainLyricsFallback(leading: leading, trailing: trailing)
            } else {
                emptyState
            }
        } else {
            ScrollView {
                // 用 VStack 而不是 LazyVStack:歌词就几十行(这首 43 行),lazy 省不下什么,
                // 却会让带动画的 scrollTo 卡 —— 目标行没渲染过就没有尺寸,滚动动画得一边
                // 跑一边现算行高,表现就是换行时一顿一顿。全部一次性布好之后,滚动只是
                // 平移已经量好的内容。
                VStack(alignment: centered ? .center : .leading, spacing: lyricLineSpacing) {
                    // 前奏的「•••」放在第一行之前(间奏点数据见 gapMarker/gapDotsRow)。
                    if let intro = gapMarker(-1), let firstID = playback.allLines.first?.id {
                        gapDotsRow(intro, id: "\(firstID)-intro", centered: centered)
                    }
                    ForEach(Array(playback.allLines.enumerated()), id: \.element.id) { index, item in
                        // .equatable():没有它,**每一行**都会跟着整页 body 重算一遍 —— 稳定播放期间主线程
                        // 曾有 ~22% 的时间耗在 NSHostingView.layout → ViewGraphRootValueUpdater.render 里,
                        // 栈里能看到 ForEachChild.updateValue → lineView,也就是几十行全在重建。
                        // LyricsWindowView 订阅的是整个 PlaybackCoordinator(二十来个 @Published),任何一个
                        // 变动都会重算 body;而行视图带闭包参数(onTap/onHover),函数值永远不相等,SwiftUI
                        // 自带的结构比较救不了,必须显式给一个只比较**值输入**的 ==。
                        LyricsLineRow(
                            item: item,
                            distance: distance(for: index),
                            // 间奏进行中"当前"是那排「•••」,唱完的行不再保持活跃态。
                            isActive: item.id == activeID && playback.currentGapIndex == nil,
                            isHovered: hoveredLineID == item.id,
                            // 这个值在 LyricsLineRow → KaraokeLineText → KaraokeWordText 一路只喂两处
                            // TimelineView 的 paused(粗时钟 / 细时钟),不参与任何画面判断,所以窗口面不可见
                            // 时直接并进来一起停表(已知坑 #17):被完全遮住/最小化的窗口里 60Hz 细时钟照跑
                            // 是白烧。恢复可见那一帧时钟重新给真值,填色不插值(叶子 .transaction 清动画),
                            // 没有补播。
                            isPlaying: playback.isPlayingNow && windowController.isSurfaceVisible,
                            // 只给**染色当前行**传真实值,其余行恒 false —— settled 每行翻转两次,全表行都
                            // 跟着比较变化的话,一次翻转就是整表行重算。
                            // 按 currentLineIndex 配对而不是 activeID:currentLineFillSettled 是引擎按
                            // **染色当前行**算的;滚动锚提前后,空档里 activeID 已指向还没开唱的下一句,把
                            // 上一句的 settled=true 挂它身上,KaraokeWordText 会按「整行定格」渲染成全填色
                            // 终态(锚位行 top2% 亮度 255 = 已染色),正是"滚到位时该清晰但未染色"的反面。
                            fillSettled: index == playback.currentLineIndex
                                && playback.currentLineFillSettled,
                            fontSize: lyricFontSize,
                            romaFontSize: romaFontSize,
                            translationFontSize: translationFontSize,
                            fontFamily: activeFontFamily,
                            duetInsetUnit: duetInsetUnit,
                            centered: centered,
                            wordRise: wordRise,
                            onArtwork: hasArtworkBackground,
                            // 行自己不再从 onArtwork 推文字色 —— 那等于把「文字颜色」那颗设置绕过去。
                            // 颜色在窗口层解析好再传进来(`.auto` 档解析出来的就是老的那两个值)。
                            textColor: lyricTextColor,
                            secondaryColor: lyricSecondaryTextColor,
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
                            gapDotsRow(g, id: "\(item.id)-gap", centered: centered)
                        }
                    }
                }
                // 间奏点的插入/移除(以及各行随之退暗一档)跟换行滚动同一条曲线。
                // 用 value 限定形而不是 withAnimation:只在进出间奏那一刻生效,
                // 不会波及各行叶子上逐帧跑的填色 TimelineView(上午面板那个坑)。
                .animation(Self.lineTransition, value: playback.currentGapIndex)
                // 顶/底留白按**视口比例**,不能写固定值:固定 88pt 时列表顶部之上根本没有可滚空间
                // —— scrollTo(第一句, 0.52) 超出内容范围被钳回 offset 0,开场永远停在顶部(改 id
                // 注册/滚动时序都救不了)。顶部 0.395h = 0.41h 锚位 −「•••」半行,offset 0 本身就是
                // AM 的开场版式(dots 在 41%、第一句 ~52%),不依赖任何 scrollTo;底部 0.55h 让最后
                // 一句也能锚在 41%(否则每首歌头几句/尾几句的锚定都会被钳,几行后才收敛)。
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
            // 系统滚动条藏掉,换自绘常显指示条(AM 的指示条**不贴窗缘**——暗轨道 6pt+白滑块
            // 12pt,中心距窗右缘 59pt,且常显;系统 overlay 滚动条只能贴 ScrollView 右缘,挪不动,
            // 只能自绘)。
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "lyricsScroll")
            .onPreferenceChange(LyricsScrollMetricsKey.self) { [weak scrollMetrics] v in
                scrollMetrics?.update(offsetY: v.offsetY, contentHeight: v.contentHeight)
            }
            .background(
                GeometryReader { g in
                    Color.clear
                        // 拖窗口边角 / 切迷你期间不提交:字号跟着尺寸变,整张列表每变一次都要换字号
                        // 重排(07 章决策 53)。结束那一刻按最终尺寸提交一次。
                        .onAppear { if !defersLyricsPaneResize { setLyricsPaneSize(g.size) } }
                        .onChange(of: g.size) { _, size in
                            if !defersLyricsPaneResize { setLyricsPaneSize(size) }
                        }
                        .onChange(of: defersLyricsPaneResize) { _, deferring in
                            if !deferring { setLyricsPaneSize(g.size) }
                        }
                }
            )
            // 上下边缘渐隐。
            //
            // 右上角那两个玻璃胶囊会挡歌词,解法照 Apple Music:它的胶囊也在右上角、歌词也从底下
            // 滚过去,靠的是列表顶部有一段渐隐,文字在够到胶囊之前就已经淡掉了。
            //
            // 右上角本来也是最该放它们的位置 —— 当前行锚在从上往下 41% 处(activeLineAnchor),
            // 所以上方是**已经唱过的**行,下方是还没唱到、跟着唱时要预读的行。要挡也是挡上面那半。
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
            // 三段间距 19/19/15(对拍 AM:封面底→歌名 19、歌手底→进度条 23.5(帧距≈19)、
            // 时间行→播控中心比我们短 5。22/14/20 那种逐段累积会把播控行推低 ~10pt)。
            trackInfoRow
                .padding(.top, 19)
            // 进度条子视图自持五个拖动/补间瞬态:1Hz 补间推进、
            // 拖动、悬停变粗的失效全部收敛在子树内,不再击穿整窗。
            WindowProgressSection(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                onArtwork: hasArtworkBackground,
                backgroundLayers: playback.windowBackgroundLayers,
                title: playback.title,
                artist: playback.artist)
                .padding(.top, 19)
            playbackControls
                .padding(.top, 17)
            Spacer(minLength: 20)
        }
        // 水平内边距不再在这里加:列宽=封面宽、左缘位置由 body 按 AM 比例(0.111W)传入。
    }

    private var artworkCard: some View {
        // Color.clear 先撑出 1:1 的方形框、图片以 scaledToFill 铺进去再裁圆角——不能
        // 直接对 Image 用 scaledToFill(没有外框约束时它会按原始比例撑开布局)。
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                // 优先用高清替代:这张卡最大 460pt(Retina 下 920px),而系统 Now Playing
                // 给的封面可能只有 100×100(网易云客户端)或 300×300(QQ 音乐客户端),
                // 分别是 9 倍和 2.7 倍放大,都明显糊。
                // highResArtworkImage 只在系统那份确实太小时才有值,见它的注释。
                if playback.isCurrentTrackAdBreak {
                    // 广告期间整张卡换成广告标识:播放器在广告时给的是广告物料的缩略图 —— 把它当
                    // "正在听的这张专辑"摆在这张最大 460pt 的卡上最误导。底沿用下面那个"没有封面"占位
                    // 的同一块(跟着 hasArtworkBackground 走),只把符号从 music.note 换成
                    // megaphone.fill,跟灵动岛/菜单栏是同一枚。
                    ZStack {
                        Rectangle().fill(hasArtworkBackground ? Color.white.opacity(0.1) : Color.primary.opacity(0.06))
                        Image(systemName: "megaphone.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(secondaryTextColor)
                    }
                } else if let nsImage = radioTalkStation?.image ?? playback.highResArtworkImage ?? playback.artworkImage {
                    ZStack {
                        // 静态图**始终铺在底下**:动态封面还没下好(首次要几秒)、或者压根没有的
                        // 专辑,这张卡就是它;下好了只是在它之上盖一层会动的画面,不是替换。
                        // 这也让"动态封面加载完"表现成一次淡入,而不是从占位符跳到视频。
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                        // 动态封面(Apple Music 的 motion artwork)。
                        //
                        // `isPlaying` 跟着 `isPlayingSmoothed`:暂停时封面就该停住(它描述的是"这首歌在放"),
                        // 而缓收版能吸掉切歌间隙那一下瞬时 false —— 否则每首歌之间动画都要停一下再起来。
                        // 这跟下面 scaleEffect 用同一个量、同一个理由。
                        //
                        // `reduceMotion` 是这一面最后一道闸:总闸(用户开关 / 低电量)已经在
                        // PlaybackCoordinator 拦过,那两个不是视图环境值。
                        if !reduceMotion, let file = playback.motionCoverFile {
                            MotionCoverView(file: file, isPlaying: playback.isPlayingSmoothed)
                                .transition(.opacity)
                        }
                    }
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
            // 挂在最外层时,这个 0.5s 的动画作用域会覆盖卡片自身的几何 —— 只要有别的状态在同一个
            // 更新事务里改变了布局(比如 anchor 到达让进度条那一行插进 VStack、整个左栏跟着重排),
            // 这次布局位移就会被它一起 animate 成缓慢飘移,表现成"进度条从上面飘下来"。它要动画的
            // 本来只是"换歌时封面图交叉淡入"这一件事,不该有能力动画到版式。
            .animation(.easeInOut(duration: 0.5), value: playback.artworkData)
            // 高清替代到货/撤掉同样交叉淡入(指针比较在这里是对的:每次到货都是新解码的
            // NSImage 实例)。
            .animation(.easeInOut(duration: 0.5), value: playback.highResArtworkImage)
            // 动态封面到货/撤掉也走同一条 0.5s 交叉淡入,跟静态高清替代一个观感。
            .animation(.easeInOut(duration: 0.5), value: playback.motionCoverFile)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(hasArtworkBackground ? 0.45 : 0.2), radius: 26, y: 12)
            // 封面随播放状态缩放(仿 Apple Music 歌词页):播放满幅、暂停缩到 73.2%,状态一眼可辨。
            // scaleEffect 是渲染变换、不改布局 —— 下方歌名/进度条纹丝不动;放在 clipShape+shadow
            // 之后,阴影跟着一起缩,观感同 Apple Music。用缓收版 isPlayingSmoothed 而不是
            // isPlayingNow:切歌间隙/seek 的瞬时 false 会让封面每首歌之间都抖一下,0.5s 宽限正好
            // 吸掉,而暂停到收缩的那 0.5s 延迟无感。reduceMotion 下跳变不补间 —— 缩放本身是
            // "没在播放"的功能反馈,要保留,去掉的只是过渡。
            // 0.732 是对拍 AM 量的(AM 暂停态封面 599px@2x / 满幅 0.279W=818px = 0.732;0.78 会让
            // 暂停态封面比 AM 大 6%)。只影响封面视觉大小 —— 这是渲染变换,下方各行位置由满幅
            // 布局撑出,与此无关。
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
        // 外层 HStack(对齐 AM):文字块靠左,收藏/更多两颗圆钮贴右 —— AM 歌词页就是这个
        // 排布。文字块可滚(MarqueeText),圆钮定宽不参与挤压。
        HStack(alignment: .center, spacing: 12) {
            trackInfoTexts
            Spacer(minLength: 8)
            titleSideButtons
        }
    }

    private var trackInfoTexts: some View {
        // spacing -3(对拍 AM 同区截图):AM 两行视觉空隙 3pt,而两行各是 22pt 定高框
        // (墨高 16pt,上下各余 3pt),3+spacing+3 要等于 3,spacing 只能是 -3。
        // 别去缩 frame 高:MarqueeText 会把超出框的拉丁降部裁掉。
        VStack(alignment: .leading, spacing: -3) {
            // 放不下就滚,不直接截断成 "Automatic (Remastered 20…" —— 这两行是这一栏唯一说明
            // "现在放的是哪一版"的地方,截掉的恰好是版本后缀。
            // 显式给行高:MarqueeText 内部是 GeometryReader,纵向贪心,不定高会把整栏撑开。
            // 广告插播:歌名位写「广告中」,跟灵动岛(NotchLyricsView)和下面歌词区的空状态
            // (emptyStateSpec)用同一个判据、同一句文案 —— 少了这一处,广告时这一行会原样显示
            // 播放器给的占位标题「—」,配上没有封面的占位图,整张卡看起来像是坏了。
            //
            // MarqueeText 的 id 必须用**显示串**而不是 playback.title:切进/切出广告时要重置
            // 跑马灯,用原标题的话 id 不变、滚动位置会带着上一条的进度(灵动岛那边同一个理由,
            // 见 NotchLyricsView 那段注释)。
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
    /// (完全对齐:收藏从播放控制排挪上来;AM 现在的收藏就是星形,
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
            // 从系统 Menu 换成自绘面板(moreMenuPanel,窗级 overlay 定位),
            // 一次解决三件事:① 样式对齐 AM(深色玻璃圆角白字,系统 NSMenu 是浅色小面板,
            // 跟目标视觉对不上);② 热区 —— Menu(.borderlessButton) 的实际可点范围只有
            // label 固有尺寸那一点(只有点按钮中心才有效),普通 Button + circleIcon
            // 的 contentShape(Circle()) 整圆都是热区,跟星星一致;③ 永久摆脱 Menu 压平
            // 自定义 label 的机制(圆底/白点两轮翻车,见 docs 已知坑 11)。
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showsMoreMenu.toggle() }
            } label: {
                circleIcon("ellipsis")
            }
            .buttonStyle(.plain)
            .anchorPreference(key: MoreMenuButtonBoundsKey.self, value: .bounds) { $0 }
            // 「设置…」("加在三个点旁边"):这扇窗口本身没有右键菜单/
            // 工具栏,原来只能从菜单栏图标右键或 Dock 才够得着设置。跟星形/「…」同款
            // circleIcon,排在「…」右边——三颗圆钮都是"这扇窗自己的功能",不跟播放控件
            // 混在一起。动作跟菜单栏右键菜单「设置…」那条同一条路径:
            // `AppActions.shared.openSettings?()` 已经带 `NSApp.activate`(`.accessory`
            // 策略下没有 Dock 图标,缺这一步点了没反应,见 MenuBarStatusMenu.openSettings
            // 同款注释),不经 `requestSettings` 指定分类——从这里打开沿用上次停留的设置页。
            // 文案复用 MenuBarStatusMenu 同一句「设置…」,同一个本地化键,不必新增翻译。
            Button {
                AppActions.shared.openSettings?()
            } label: {
                circleIcon("gearshape")
            }
            .buttonStyle(.plain)
            .help(L10n.t("设置…"))
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
            // ---- Apple Music 目录动作(对照 AM 自己的「⋯」菜单) ----
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
                MoreMenuRow(title: L10n.t("前往歌手")) {
                    closeMoreMenu()
                    openCatalogPage(album: false)
                }
            }
            // ---- QQ 音乐 / 网易云的目录动作。AM 有自己那套(上面这块) ----
            //
            // 只给**当前播放器**那一个平台,不把三个平台全铺进菜单(菜单每多一行都在变长)。
            // 「显示简介」面板那行「网页」同样只给当前播放器,两处口径一致;区别只在
            // 菜单多给 QQ 的专辑页 / 歌手页。
            //
            // 文案统一写「…页」而不是「在 XX 中打开」:这些**全部落在浏览器**。QQ 音乐没有
            // associated-domains 授权(y.qq.com 不会被 App 接走),它注册的 qqmusicmac://
            // 命令表只有 playsong/downloadsong、没有"打开这一页"的语义(而 playsong 会把
            // 正在放的这首从头重播,不是我们要的)。详见 PlatformLinks 的头注。
            if !platformMenuRows.isEmpty {
                ForEach(platformMenuRows) { row in
                    // 标题带 ↗:这三项**落在浏览器**,不是在客户端里打开。用户
                    // 实测问过「这三个不能在客户端打开吗」——不能,而且是查透了的:QQ 音乐
                    // 整个 bundle 只注册一个 scheme(qqmusicmac),而它的协议处理器
                    // (QMTenProtocolHandler.mm)完整字符串簇只有三个命令 playsong /
                    // downloadsong / CODE(登录回调),**没有任何"打开某一页"的命令**;
                    // qmusic:// 是它自己 webview 的 JS 桥(紧挨着 GeneralWebview
                    // openUrlString:),外部用不了;也没有 associated-domains。
                    // 连 `open -a QQ音乐 <y.qq.com URL>` 都实测过:只把 App 拉到前台、
                    // 窗口数不变、URL 被忽略。所以 ↗ 不是装饰,是如实告知落点。
                    MoreMenuRow(title: row.title + " ↗") {
                        closeMoreMenu()
                        NSWorkspace.shared.open(row.url)
                    }
                }
                menuDivider
            }
            // 「在 XX 中显示」:标题随当前播放器变;Apple Music 走 reveal(在 Music 里定位选中
            // 当前曲目,流媒体曲目也可用);Spotify 原生客户端走 `spotify:track:<id>` 深链跳到
            // 曲目页(SpotifyReveal;网页版的播放器 bundle 是浏览器,不进这支);其它走
            // openResolvedPlayer —— 原生播放器激活该 App,网页平台翻到正在放歌的那枚标签页。
            MoreMenuRow(title: String(format: L10n.t("在 %@ 中显示"), playerName ?? L10n.t("播放器"))) {
                closeMoreMenu()
                if isAM {
                    runAppleMusicMenuAction { MusicPlaybackController.revealCurrentTrack() }
                } else if PlaybackCoordinator.shared.resolvedPlayerBundleID == PlaybackPlayer.spotify.bundleIdentifier {
                    SpotifyReveal.revealCurrentTrack { PlaybackCoordinator.shared.openResolvedPlayerApp() }
                } else {
                    PlaybackCoordinator.shared.openResolvedPlayer()
                }
            }
            menuDivider
            MoreMenuRow(title: L10n.t("显示简介")) {
                closeMoreMenu()
                openInfoPanel()
            }
            // 「你的常听」(Last.fm 系列):榜单面板,连着账号才有这一行。
            LastfmLoveMenuRow()
            if LastfmStatsService.shared.isConnected {
                MoreMenuRow(title: L10n.t("你的常听")) {
                    closeMoreMenu()
                    withAnimation(.easeOut(duration: 0.12)) { showsChartsPanel = true }
                }
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
    private struct PlatformMenuRow: Identifiable {
        let id: String
        let title: String
        let url: URL
    }

    /// 当前播放器那一个平台的目录入口。AM 走它自己那套(前往专辑/前往艺人,经 iTunes
    /// Search),所以这里只管非 AM;酷狗没有任何已存的链接,自然是空数组。
    private var platformMenuRows: [PlatformMenuRow] {
        guard !isAppleMusicPlayer, let links = platformLinks else { return [] }
        let bundleID = PlaybackCoordinator.shared.resolvedPlayerBundleID
        var out: [PlatformMenuRow] = []
        if bundleID == PlaybackPlayer.qqMusic.bundleIdentifier {
            if let u = links.qqSong { out.append(.init(id: "qq-song", title: L10n.t("QQ 音乐歌曲页"), url: u)) }
            if let u = links.qqAlbum { out.append(.init(id: "qq-album", title: L10n.t("QQ 音乐专辑页"), url: u)) }
            if let u = links.qqArtist { out.append(.init(id: "qq-artist", title: L10n.t("QQ 音乐歌手页"), url: u)) }
        } else if bundleID == PlaybackPlayer.netease.bundleIdentifier {
            // 网易云只白捡歌曲页:collector 解出过专辑 ID,但它只活在内存里给同专辑预取用,
            // 没有落进 enrich 缓存(要加得动 collector,与 QQ 那两个 mid 同一条路)。
            if let u = links.neteaseSong { out.append(.init(id: "ne-song", title: L10n.t("网易云音乐歌曲页"), url: u)) }
        }
        return out
    }

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
        // 平台链接的加载必须放在下面那道 `isAppleMusicPlayer` 早退**之前** ——
        // 非 AM 播放器(QQ/网易云)正是要用它的那一档,放在早退之后等于永远不加载。
        platformLinks = nil
        let linkArtist = playback.artist, linkTitle = playback.title, linkAlbum = playback.album
        if !linkTitle.isEmpty {
            Task.detached(priority: .userInitiated) {
                let links = EnrichCacheReader.platformLinks(
                    artist: linkArtist, title: linkTitle, album: linkAlbum)
                await MainActor.run {
                    guard generation == moreMenuStateGeneration else { return }
                    platformLinks = links
                }
            }
        }
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
    /// 返回值** —— 它对"已在库静默 no-op"也报 ok,事后重新读回
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
    ///
    /// Music.app 没在跑时,必须先 `ensureMusicAppRunning()` 等它真正启动完再发
    /// music:// URL——直接对着一个还没起来的 Music.app 发深链会被冷启动流程吞掉,
    /// 用户看到的是"打开了 Music.app,但没跳到点的这个页面"(见
    /// MusicAutomationPermission.ensureMusicAppRunning 注释)。
    /// 目录页跳转的去处:专辑 / 艺人 / 曲目(停播页「最近听过」行点击要的是曲目页)。
    private enum CatalogTarget { case album, artist, track }

    private func openCatalogPage(album: Bool) {
        openCatalogPage(title: playback.title, artist: playback.artist,
                        target: album ? .album : .artist)
    }

    /// 任意 (歌名, 歌手) 的目录页跳转 —— 停播页那几块要跳的不是「当前播放」而是历史行,
    /// 所以曲目字段必须由调用方传进来,不能像上面那样从 playback 现读(停播时它是空的)。
    private func openCatalogPage(title: String, artist: String, target: CatalogTarget) {
        guard !title.isEmpty || !artist.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
            guard let item = await MusicCatalogSearch.resolve(
                title: title, artist: artist, storefront: storefront) else { return }
            let https: String?
            switch target {
            case .album: https = item.collectionViewUrl ?? item.trackViewUrl
            case .artist: https = item.artistViewUrl
            case .track: https = item.trackViewUrl ?? item.collectionViewUrl
            }
            guard let url = MusicCatalogSearch.musicSchemeURL(https) else { return }
            // Music.app 没在跑时直接 open(music://…) 会被 LaunchServices 吞掉(冷启动走到
            // 能接 Apple Event 之前 URL 就丢了),表现成「App 打开了但停在上次退出的页面」。
            await MusicAutomationPermission.ensureMusicAppRunning()
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
            // 一次缓存读同时供两处用(来源 + 各平台链接):都走 EnrichCacheReader,
            // mtime 没变时是 µs 级,不值得拆成两个 task。
            let info = EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)
            let links = EnrichCacheReader.platformLinks(artist: artist, title: title, album: album)
            await MainActor.run {
                infoLyricsSource = info?.lyricsSource
                platformLinks = links
            }
        }
    }

    /// 「搜索歌词…」:点击瞬间快照曲目字段、后台解析 写回 key + 当前来源,齐了再弹面板。
    /// key 用缓存里**实际命中**的那条(EnrichCacheReader.resolvedKey,含宽松匹配)——
    /// 播放器报法与缓存写法有空格/繁简出入时,写回必须落在读取路径同一条上;缓存里还
    /// 没有条目(collector 未解析)就退回 normalizedKey 新建。
    ///
    /// 直接读 PlaybackCoordinator.shared,不经本窗口的 WindowPlayback 代理(那份代理对
    /// title/artist/album/currentDurationMs 各开一条独立的 Combine 订阅转发,见
    /// WindowPlayback.init)——只隔一层转发更直接,跟 LyricsManagerView.refreshPlaceholder
    /// 已有的写法一致。
    private func openLyricsSearch() {
        let p = PlaybackCoordinator.shared
        let artist = p.artist, title = p.title, album = p.album
        let durationSecs = Double(p.currentDurationMs ?? 0) / 1000
        Task.detached(priority: .userInitiated) {
            let key = EnrichCacheReader.resolvedKey(artist: artist, title: title, album: album)
                ?? EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
            let source = EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)?.lyricsSource
            // 「当前使用」双判据要的正文指纹,跟上面几次读取同在这个后台任务里。
            let lyrics = EnrichCacheReader.lookup(artist: artist, title: title, album: album)?.lyrics ?? ""
            let fingerprint = lyrics.isEmpty ? nil : ManualPickLock.fingerprint(lyrics: lyrics)
            await MainActor.run {
                // title 传归一化后的(EnrichCacheKeys.normalizedTitle),不是原始播放器标题:collector
                // 算缓存 key 时会把标题结尾那种非版本标记的括号剥掉(林潔心《想逃避(22)》→「想逃避」),
                // 这里传原始标题的话,手动搜索会重蹈自动解析"八个源全搜不到"的覆辙。
                // key/source 两个查找仍然传原始 title——它们各自内部会归一化,契约不变。
                lyricsSearchContext = LyricsSearchContext(
                    artist: artist, title: EnrichCacheKeys.normalizedTitle(title), album: album,
                    key: key, currentSource: source, currentFingerprint: fingerprint, durationSecs: durationSecs)
            }
        }
    }

    /// 「歌词时间轴」内联行:标签 + 当前值(只显示**这首歌**的微调,不含全局基准 ——
    /// 口径同菜单栏 offsetMenuTitle 的注释)+ 重置(按需)/−/＋ 三颗小钮。
    /// 交互对齐菜单栏面板 offsetControls:**左「−」=延后、右「＋」=提前** —— 那边已经为
    /// 同一个反直觉问题定过稿("想歌词快一点应该点右边");也别换回圆箭头
    /// gobackward/goforward,它们是 Apple 的"快退/快进 15 秒"符号,会一直往"调播放进度"上带。
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
            // 「重置」按需出现,且在 ± 的**左侧**:出现/消失只向左伸缩,右侧锚定的 ± 两颗钮
            // 纹丝不动 —— 摆在最右的话,它一出现就把 ± 挤走,连点「＋」的第二下会点到刚冒出来
            // 的重置上。口径同菜单栏:清的是这首歌的微调,这首没调过就不摆一个点了什么都不变
            // 的按钮。
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

    /// [歌词|播放记录] 双钮胶囊(AM 同款:71.5×35.5pt 胶囊,激活的一半是白圆+深字形)。
    /// 歌词钮=歌词栏显隐(仅双列模式显示,单列关了剩空白);播放记录钮=右侧栏内容在"歌词"
    /// 与"播放记录"之间切换(不做「播放队列」:AppleScript 读不到目录内容的播放上下文,见
    /// showsListenHistory 声明处注释)。播放记录不挑播放器(数据来自 collector 本地记录/
    /// Last.fm,不靠 AppleScript)。两颗都没有就整颗胶囊不摆(理论上不会发生:播放记录钮恒真)。
    ///
    /// **两颗钮互斥**,不是两个独立布尔量各管各的(`showsLyricsPane.toggle()` /
    /// `showsListenHistory.toggle()`)—— 那样会出现"歌词已隐藏、又点了播放记录,再点歌词
    /// 切回去,`showsLyricsPane` 却因为从没被这条路径碰过而仍是 false"这类脱节状态。
    /// 显式的二选一:歌词钮点击时,当前在播放记录就切回歌词(不碰 `showsLyricsPane`,不
    /// 隐藏整栏);当前已经是歌词就走隐藏/显示切换。播放记录钮点击是**单向选中**(不是
    /// toggle)—— 点它总是切到播放记录并确保整栏可见,要切回去点左边那颗歌词钮,跟 AM
    /// 自己的 Lyrics/Queue 分段控件同一个交互(点已选中的那段不会取消选中)。
    @ViewBuilder private func lyricsQueuePill(showPlayerPane: Bool) -> some View {
        let showsLyricsButton = showPlayerPane
        // 歌词钮"激活"只在"整栏可见 且 当前显示的确实是歌词"时才算——不是单看
        // showsLyricsPane:播放记录钮点击后会强制把它设回 true(保证整栏不塌),
        // 这时候 showsLyricsPane 本身已经不能单独代表"现在显示的是歌词"了。
        let showsLyricsActive = showsLyricsPane && !showsListenHistory
        if showsLyricsButton {
            HStack(spacing: 2) {
                pillSlotButton(icon: "quote.bubble.fill", active: showsLyricsActive,
                               help: L10n.t(showsLyricsActive ? "隐藏歌词" : "显示歌词")) {
                    withAnimation(.smooth(duration: 0.35)) {
                        if showsListenHistory {
                            showsListenHistory = false
                        } else {
                            showsLyricsPane.toggle()
                        }
                    }
                }
                pillSlotButton(icon: "list.bullet", active: showsListenHistory,
                               help: L10n.t("播放记录")) {
                    withAnimation(.smooth(duration: 0.35)) {
                        showsListenHistory = true
                        showsLyricsPane = true
                    }
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 36)
            .clearGlassCapsule(
                rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
        } else {
            // 单列窗口:没有「隐藏歌词」这颗钮——单列的右栏本来就是整窗
            // 唯一内容、不能收起来。播放记录钮独立一颗圆钮,这里没有配对的歌词钮
            // 可以"切回去",所以仍然是普通 toggle(点一下切过去,再点一下切回来)。
            pillSlotButton(icon: "list.bullet", active: showsListenHistory,
                           help: L10n.t(showsListenHistory ? "显示歌词" : "播放记录")) {
                withAnimation(.smooth(duration: 0.35)) { showsListenHistory.toggle() }
            }
            .frame(width: 36, height: 36)
            .clearGlassCapsule(
                rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
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

    /// 「播放记录」面板:填在右侧栏跟歌词同一块地皮上(不是弹出面板),内容按
    /// Last.fm 连没连二选一。完整背景见 showsListenHistory 声明处注释。
    private func listenHistoryPane(leading: CGFloat, trailing: CGFloat) -> some View {
        ListenHistoryPane(
            leading: leading, trailing: trailing,
            onArtwork: hasArtworkBackground, colorScheme: colorScheme,
            onOpenTrack: { title, artist in
                openCatalogPage(title: title, artist: artist, target: .track)
            })
    }

    /// 「翻译与发音」菜单(对照 AM 歌词页右下角):两行开关,开的是设置里现成的
    /// showTranslation/showRomanization 总开关(与设置页同一个值,别处同步生效)。
    /// 当前曲目缺某一路数据时对应行灰化不可点(AM 同款:它的「显示发音」没数据时也是
    /// 灰的);点完即关面板(AM 同款),行文案随开关状态在 显示/隐藏 之间切。
    private var translationMenuPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            MoreMenuRow(title: L10n.t(playback.showTranslation ? "隐藏译文" : "显示译文"),
                        enabled: trackHasTranslation) {
                withAnimation(.easeOut(duration: 0.12)) { showsTranslationMenu = false }
                AppSettings.shared.showTranslation.toggle()
            }
            MoreMenuRow(title: L10n.t(playback.showRomanization ? "隐藏罗马音" : "显示罗马音"),
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
            if playback.isRadioTalkBreak { return L10n.t("口白") }
            if playback.isCurrentTrackInstrumental { return L10n.t("纯音乐") }
            if !playback.currentTrackPlainLyrics.isEmpty { return L10n.t("纯文本（无时间戳）") }
            return L10n.t("无歌词")
        }()
        let durationText: String? = playback.currentDurationMs.map { ms in
            let s = ms / 1000
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return VStack(alignment: .leading, spacing: 6) {
            InfoPanelRow(label: L10n.t("歌名"), value: playback.title, onArtwork: hasArtworkBackground)
            if !playback.displayArtist.isEmpty {
                InfoPanelRow(label: L10n.t("歌手"), value: playback.displayArtist, onArtwork: hasArtworkBackground)
            }
            if !playback.album.isEmpty {
                InfoPanelRow(label: L10n.t("专辑"), value: playback.album, onArtwork: hasArtworkBackground)
            }
            if let durationText {
                InfoPanelRow(label: L10n.t("时长"), value: durationText, onArtwork: hasArtworkBackground)
            }
            if let player = PlaybackCoordinator.shared.resolvedPlayerDisplayName {
                InfoPanelRow(label: L10n.t("播放器"), value: player, onArtwork: hasArtworkBackground)
            }
            InfoPanelRow(label: L10n.t("歌词"), value: lyricsKind, onArtwork: hasArtworkBackground)
            if let source = infoLyricsSource, !source.isEmpty {
                InfoPanelRow(label: L10n.t("来源"), value: sourceDisplayName(source), onArtwork: hasArtworkBackground)
            }
            // 「网页」行:**只显示当前播放器自己那个平台**的歌曲页。三个平台全铺(QQ / 网易云 /
            // Apple Music)的话,酷狗播放时面板上会摆着 QQ 音乐和 Apple Music 两个别家的链接,
            // 看不出这行想说什么。跟「⋯」菜单的平台入口同一口径;该平台没链接(酷狗 / YouTube
            // Music 没存链接、网易云版权下架的周杰伦、QQ 只有搜索兜底)整行不出现,不拿别的平台
            // 顶上。判定是纯函数 PlatformLinks.songLink(forPlayerBundleID:webPlatformID:),
            // selftest 钉住。
            if let links = platformLinks,
               let link = links.songLink(forPlayerBundleID: PlaybackCoordinator.shared.resolvedPlayerBundleID,
                                         webPlatformID: PlaybackCoordinator.shared.resolvedWebPlatformID) {
                InfoPanelLinksRow(name: Self.platformDisplayName(link.platform), url: link.url,
                                  onArtwork: hasArtworkBackground)
            }
            // 收听档案(Last.fm 系列):累计次数 + 首次/上次听。连着账号才有;首次/上次是面板
            // 打开那一刻才发的两个请求(user.getTrackScrobbles),到货前这几行整体缺席,面板高度
            // 随之长一截 —— 面板本来就是 fixedSize 浮层,长高不顶别人。
            InfoPanelListeningRows(title: playback.title, artist: playback.artist, onArtwork: hasArtworkBackground)
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

    /// 「网页」行上平台的人话名。三个中文键早就在 Localizable 里(菜单那几项也在用);Spotify 是
    /// 品牌名,各语言写法一样,不过 L10n(跟 BrowserMusicPlatform.displayName 同一口径)。
    private static func platformDisplayName(_ platform: PlatformLinks.Platform) -> String {
        switch platform {
        case .appleMusic: return L10n.t("Apple Music")
        case .qqMusic: return L10n.t("QQ 音乐")
        case .netease: return L10n.t("网易云音乐")
        case .spotify: return "Spotify"
        }
    }

    /// 音频输出面板(AirPlay 键弹出):AM 同款版式——每行 设备类型图标 + 名称 + 右侧勾选,
    /// 玻璃底与「⋯」菜单同一套。设备列表在面板出现时现枚举(CoreAudio 同步调用,µs 级)。
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
            // 14:对照 AM 特写 —— AM 的星形约占圆钮内 60%+,12pt 只有五成出头。
            // 圆底 26pt 与 AM 一致,不动。
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(primaryTextColor.opacity(0.9))
    }

    // Apple Music 同款"歌手 — 专辑"一行(em dash),缺哪一半就只显示另一半。
    // 用 displayArtist 而不是 artist:署名不可信的播放器在纠正落地前歌手位会一直跳歌词,
    // 判据见 PlayerArtistFix.displayArtist。两边都空时整行为空串,不会剩一个孤零零的破折号。
    private var artistAlbumText: String {
        [playback.displayArtist, playback.album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// 广告插播时歌名位显示的文案。判据 isCurrentTrackAdBreak 由 LocalPlaybackSource 给
    /// (字段启发式 + 同曲棘轮 + AppleScript `spotify url` 权威分类,见那边注释)。
    private var displayTitle: String {
        if playback.isCurrentTrackAdBreak { return L10n.t("广告中") }
        // 口白期间换成台名。抓不到台卡就还显示上一首 —— 判据见 RadioStationCard。
        if let station = radioTalkStation { return station.name }
        return playback.title
    }

    /// 口白期间顶替曲目卡的台名 / 台标。抓不到台卡就是 nil,一切照旧。跟灵动岛那份同名同义。
    private var radioTalkStation: (name: String, image: NSImage?)? {
        guard playback.isRadioTalkBreak, let name = playback.radioStationName, !name.isEmpty else { return nil }
        return (name, playback.radioStationImage)
    }

    /// 广告插播时第二行**留空**,不展示广告物料的歌手/专辑名(跟灵动岛一致)。这不是多余的
    /// 判断:广告有时会带全 artist/album 字段,不显式清掉的话第二行会冒出广告主的名字。
    private var displayArtistAlbum: String {
        playback.isCurrentTrackAdBreak ? "" : artistAlbumText
    }


    // 控制排的尺寸全部从封面边长算出来,再夹进一个合理区间 —— 封面随窗口缩放,按钮写死
    // 尺寸就会在窄窗口下溢出被裁、在宽窗口下小得跟封面不成比例。夹值的上下界是按"最窄能用"
    // 和"再大就傻了"定的,不是等比无限放大。
    private var controlScale: CGFloat { artworkWidth > 0 ? artworkWidth : 300 }
    private func ctrl(_ ratio: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(hi, max(lo, controlScale * ratio))
    }

    private var playbackControls: some View {
        // 布局对照 AM:五键**不是等间距**——随机贴列左缘、循环贴右缘(AM 里 shuffle 中心离
        // 进度条左缘仅 ~13pt),主三键按原间距居中成组。图标档位也是对拍量的:AM 上/下一首
        // 字形 64px@2x、播放 52px 高、随机/循环 38px 宽 —— 换算成字号比例 上下一首 0.060、
        // 播放 0.079(帧 0.10)、随机/循环 0.043。
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
        // AM 式点按反馈:按下快缩、松手弹回。作用于整排五颗。
        .buttonStyle(TransportButtonStyle(reduceMotion: reduceMotion))
        .foregroundStyle(primaryTextColor)
        .frame(maxWidth: .infinity)
    }

    /// 置顶 / 全屏 / 回到当前播放。
    ///
    /// 浮层放在这里,不放 .toolbar 里的 ToolbarItem:工具栏的玻璃是系统给的 .regular
    /// 磨砂档,改不了它的材质,会是块不透明浅灰,跟旁边用 .clear 的音量胶囊放在一起对比
    /// 强烈。浮层用同一档材质、同一套描边,而且都能真的采样到背后的模糊封面。
    ///
    /// 顺带跟 Apple Music 更像了:它的窗口控件也是浮在内容上的胶囊,不是标题栏工具栏。
    private static let windowActionIconFont = Font.system(size: 14, weight: .medium)
    private static let windowActionIconWidth: CGFloat = 18
    private static let windowActionIconSpacing: CGFloat = 18

    private func windowActionsCapsule() -> some View {
        // 胶囊高度跟音量胶囊一致(两颗必须等高);里面的图标统一 14pt Medium、间距 18,
        // 对齐 Apple Music 全屏歌词页左上「✕ + 画中画」那颗胶囊的字重与疏密。
        // 三颗必须同一字号字重,别单独把某一颗调大——同族感就靠这一条。
        // 换行时 onChange(currentLineIndex) 会自动滚回当前行,不需要「回到当前播放」按钮。
        HStack(spacing: Self.windowActionIconSpacing) {
            Button {
                windowController.toggleAlwaysOnTop()
            } label: {
                Image(systemName: windowController.isAlwaysOnTop ? "pin.fill" : "pin")
                    .font(Self.windowActionIconFont)
                    .frame(width: Self.windowActionIconWidth)
            }
            // 补上——置顶/伪全屏这两个状态是"只在这次打开期间有效",不持久化
            // (见 LyricsWindowController 顶部注释),但按钮本身没有任何提示说明,习惯把它
            // 固定置顶的用户每次重开窗口都要重新点一次,容易被当成 bug。
            .help(
                (windowController.isAlwaysOnTop ? L10n.t("取消置顶") : L10n.t("置于最顶层"))
                    + " · " + L10n.t("这个状态只在本次打开这扇窗口期间有效，下次重新打开会恢复默认"))
            // 全屏那颗在迷你模式下收起来:一扇迷你大小的窗要"进入全屏"是自相矛盾的,
            // 而且迷你时胶囊每多一颗都在挤那点横向空间。
            // 判据用 showsMiniLayout 而不是 windowController.isMini —— 后者在预览里恒为 false,
            // 会让迷你预览画出三颗、跟真迷你窗对不上。
            if !showsMiniLayout {
                Button {
                    windowController.toggle(reduceMotion: reduceMotion)
                } label: {
                    Image(
                        systemName: windowController.isFullScreenActive
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .font(Self.windowActionIconFont)
                    .frame(width: Self.windowActionIconWidth)
                }
                .help(L10n.t(windowController.isFullScreenActive ? "退出全屏" : "进入全屏"))
            }
            // 「悬停时浮出控制条」的开关,只在迷你里出现 —— 完整尺寸没有那条控制条,播控本来
            // 就常驻在左栏。
            //
            // 图标用 `rectangle.bottomthird.inset.filled`:那个图形本身就是"矩形底部那一条",
            // 正是这颗开关管的东西;关掉换成空心矩形,跟旁边那颗置顶用 pin.fill / pin 表达开关态
            // 是同一套语言。
            if showsMiniLayout {
                Button {
                    AppSettings.shared.lyricsWindowMiniShowsControls.toggle()
                } label: {
                    Image(
                        systemName: playback.miniShowsControls
                            ? "rectangle.bottomthird.inset.filled"
                            : "rectangle"
                    )
                    .font(Self.windowActionIconFont)
                    .frame(width: Self.windowActionIconWidth)
                }
                .help(L10n.t(playback.miniShowsControls ? "不再悬停显示播放控制" : "悬停显示播放控制"))
            }
            // 迷你尺寸用画中画那对符号:「缩成一扇小窗」在 Apple 的播放器语汇里就是 pip
            // (Apple Music 全屏歌词页、QuickTime、Safari 视频控件同款),跟全屏那对斜箭头分得开。
            Button {
                windowController.toggleMini()
            } label: {
                Image(systemName: showsMiniLayout ? "pip.exit" : "pip.enter")
                    .font(Self.windowActionIconFont)
                    .frame(width: Self.windowActionIconWidth)
            }
            .help(L10n.t(showsMiniLayout ? "退出迷你尺寸" : "进入迷你尺寸"))
        }
        .buttonStyle(WindowActionButtonStyle(onArtwork: hasArtworkBackground))
        // 图标跟着背景走:.clear 玻璃是透明的,背后是深色的模糊封面时 .secondary 会暗到
        // 快看不清 —— Apple Music 那两个胶囊上的图标也是白色系。
        .foregroundStyle(capsuleIconColor)
        // 内容高钉死到跟音量胶囊一致(那边最高的是 22pt 滑杆),两颗胶囊必须严格等高。
        .frame(height: 22)
        .padding(.horizontal, 14)
        // 7:与音量胶囊同高 36(对拍 AM 胶囊高 71px@2x),和红绿灯同心
        // (见 overlay 注释)。
        .padding(.vertical, 7)
        .clearGlassCapsule(
            rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
    }


    /// 随机(最左)/ 循环(最右)—— 按 Apple Music 歌词页的排布拆成两颗独立按钮
    /// (完全对齐 AM;此前是一颗三态循环切换的「播放模式」钮 +
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

    /// 循环键三态(对齐 AM):关 → 列表循环(亮 repeat) → 单曲循环(亮
    /// repeat.1) 到 关。此前只有 关与单曲 两态,而且 Music.app 的 song repeat=all 被解析
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
                        // 3(对拍:随机贴列左缘/循环贴列右缘,此前 6pt 内衬
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
        // 定宽=字号+8:这个占位框才是随机/循环字形横向落点的真正旋钮 —— 字形在框内居中,
        // AM 随机字形中心离列左缘 13pt,框宽 ≈26 才对得上(0.062+14=37 那种公式会把两颗各
        // 往内推 5px@2x)。
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

    private func distance(for index: Int) -> Int? {
        // 景深(不透明度/模糊)跟**滚动锚**走,不跟染色下标:滚动落位的那一刻下一句就该已经
        // 清晰。钉在 currentLineIndex 上的话,页面先滚过去、下一句却还挂着 d=1 的暗度和模糊,
        // 开唱才"对焦",正好比 AM 慢一拍。染色(逐字填色)仍看 currentLineIndex/词时间轴,
        // 这里只管清晰度。
        // 间奏进行中整体退一档(此刻的"当前"是那排「•••」),见 LyricsWindowDepth.distance。
        LyricsWindowDepth.distance(index: index,
                                   anchorIndex: playback.scrollLineIndex ?? playback.currentLineIndex,
                                   inGap: playback.currentGapIndex != nil)
    }

    // ---- 间奏「•••」(Apple Music 歌词页同款) ------------------------------------

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
    /// (LocalPlaybackSource 20Hz 发布 currentGapIndex,进出间奏才变)。
    ///
    /// 帧率:用 `.animation(paused:)` 不设 minimumInterval——跟着显示器刷新率走,每帧直接
    /// 算真值,**不要**退回"粗时钟采样 + `.animation(value:)` 补间"。0.5s 一档的采样点之间
    /// pos 一跳就是 500ms,对应呼吸周期里 ~7% 的相位跳变,而 cos² 曲线鼓起来最快的那一段
    /// (相位变化率最大)恰恰最需要密集采样,补间出来就是一格一格跳、"鼓起来的时候卡顿"。
    /// 这跟本文件"逐字时钟两级化"那条已知坑是同一个病根:采样再补间只在被采样的量本身接近
    /// 匀速/线性时才顺滑。补间修饰符也一并去掉(值本身逐帧连续,不需要动画引擎再插值)。
    /// 三颗点加起来就是几次三角函数+几个 Circle,帧预算跟逐字填色那种要做整行 WrapLayout
    /// 重排的场景完全不是一个量级,全速率不算浪费。
    @ViewBuilder
    private func gapDotsRow(_ marker: LyricsGapMarker, id: String, centered: Bool) -> some View {
        if playback.currentGapIndex == marker.index {
            // 呼吸曲线/点亮算法抽到 LyricsGapDotsView(悬浮歌词共用,见该文件头注)。
            // 暂停时把表停掉——暂停在间奏中时圆点亮度/大小本来就该定格(闭包里的
            // pausedPositionMs 兜底),表继续走只是白跑。窗口面不可见也停(已知坑 #17):
            // 这是这扇窗里唯一一个满帧率、且整段间奏都在跑的时钟,最小化时白烧得最多。
            LyricsGapDotsView(
                startMs: marker.startMs, endMs: marker.endMs,
                dotSize: lyricFontSize * 0.32, spacing: lyricFontSize * 0.3,
                // 三点是**歌词内容**(它顶替的是一行词),跟着「文字颜色」走,不跟 chrome。
                color: lyricTextColor,
                isPlaying: playback.isPlayingNow, isVisible: windowController.isSurfaceVisible,
                reduceMotion: reduceMotion
            ) { _ in
                // 跟逐字填色同一套时间基准:外推位置 + 当前歌词偏移(间奏窗口是歌词
                // 原始时间轴,见 LyricsGapMarker 注释)。暂停时 anchor 为 nil,退回
                // 冻结位置,点就停在当下的亮度上。
                (playback.anchor?.extrapolatedPositionMs()
                    ?? playback.pausedPositionMs ?? marker.startMs)
                    + PlaybackCoordinator.shared.currentLyricsOffsetMs
            }
            .frame(height: lyricFontSize * 0.5)
            .id(id)
            .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: centered ? .center : .leading)))
        }
    }

    // Apple Music 歌词页的景深:当前行完全清晰,其余行统一压到低不透明度、并随距离
    // 加重高斯模糊——非当前行之间的不透明度差异很小(0.50 → 0.35 缓降),远近感主要靠
    // 模糊量区分。nil(还没播到第一句)整页轻虚化,保持可读。

    // 距离越远、高斯模糊越重——1.1pt/行、封顶 4pt。别调回 1.6pt/行封顶 6pt:AM 最远的
    // 可见行仍然认得出字形(模糊半径约为字号的 12~14%,而 6pt/28pt 是 21%,整屏都糊了)。
    // SwiftUI 的 .blur() 本身就是可动画属性,复用调用点已有的 .animation(value: distance)。

    /// 自定义背景色里有没有"没填满"的部分 —— 有就让窗口本体透出去。
    ///
    /// 渐变看**两端里更透的那个**:只要有一端透,那一侧就该见到背后的东西。
    private var wantsTransparentWindow: Bool {
        func alpha(_ hex: String) -> Double { LyricsWindowBackgroundLuma.parse(hex: hex)?.a ?? 1 }
        switch activeBackgroundMode {
        case .artwork:
            // 封面那一档铺的是不透明图层,没有"透出去"这回事。
            return false
        case .solid:
            return alpha(activeBackgroundColorHex) < 1
        case .gradient:
            return min(alpha(activeBackgroundColorHex), alpha(activeBackgroundColorEndHex)) < 1
        case .glass:
            // 恒真:材质要有东西可折射(见 LyricsWindowBackgroundMode.alwaysNeedsTransparentWindow)。
            return true
        }
    }

    /// 这扇窗此刻该不该用白字。
    ///
    /// **名字留着没改**:它有十几处消费点(主文字/副行/时间/进度/图标/各个面板),而语义其实一直是
    /// "背景是不是暗的" —— 以前背景只有"封面"和"没有"两种,`artworkData != nil` 正好等价于它,
    /// 所以那时候写成这样没问题。用户能自己填背景色之后这个等价关系断了(填一个浅黄背景,白字直接
    /// 消失),判据换成真的算背景亮度。改名会波及十几处调用点、跟并发改动撞车,收益只是名字更贴切。
    private var hasArtworkBackground: Bool {
        switch activeBackgroundMode {
        case .artwork:
            // 封面背景必然是暗的(烘焙压过 EV −1.9 + 0.15 黑遮罩),维持原判据;拿不到封面时
            // 什么都不画、退回系统窗口底色,那就该跟随系统深浅色。
            return playback.artworkData != nil
        case .solid:
            return LyricsWindowBackgroundLuma.prefersLightText(
                hexes: [activeBackgroundColorHex], darkAppearance: colorScheme == .dark)
        case .gradient:
            return LyricsWindowBackgroundLuma.prefersLightText(
                hexes: [activeBackgroundColorHex, activeBackgroundColorEndHex],
                darkAppearance: colorScheme == .dark)
        case .glass:
            // 毛玻璃的亮度取决于此刻窗口背后是什么,算不出来也不该算。交给系统:返回 false 让
            // 文字走 `.primary`/`.secondary`,那两个语义色在 Material 上本来就会做 vibrancy
            // 自适应(浅材质上转深、深材质上转浅),比我们钉死一个白或黑都准。
            return false
        }
    }

    // Apple Music 歌词页最标志性的元素:当前封面模糊放大铺满、压一层半透明黑提升文字
    // 可读性。data 解码失败(损坏的图片数据,理论上不该发生,fetchArtwork() 已经在
    // Data(base64Encoded:) 这一步失败就返回 nil 了,这里只是再兜一层)时同样什么都不画,
    // 退回系统默认背景,不留一个突兀的纯色占位块。
    //
    // 故意**不加** .ignoresSafeArea():加了之后这层背景会一路铺到标题栏底下,而系统
    // 标题栏文字颜色是按"标题栏本该是不透明系统材质"这个假设算的,被这层深色模糊图顶到
    // 底下之后撞色、对比度不够,表现是标题栏文字"有时候会不明显"。去掉这个修饰符,背景
    // 就只填满 ScrollView 自己的内容区域(标题栏下方),不需要额外裁剪——ScrollView 的
    // frame 本来就已经是"标题栏以下的可用区域",内部 LazyVStack 的上下 60pt padding 不
    // 影响 ScrollView 自身、也就不影响这层 .background() 铺的范围。
    @ViewBuilder
    private var artworkBackground: some View {
        // AM 式动画背景(反向工程依据 Priva28 gist + AMLL,烘焙与参数见
        // PlaybackCoordinator.bakeWindowBackgroundLayers):暗底静态铺满,3 份取自封面不同区域
        // 的羽化光斑以 lighten(变亮)混合、绕各自的偏心锚点慢速往复摆动 —— 这就是 AM 歌词页背景
        // "缓慢流动的光斑"的来源。图层全部预烘焙,动画在 Core Animation 里跑(见 WindowAnimatedBackground)。
        //
        // 遮罩只留 0.15 的可读性保底:主要压暗已在暗底烘焙(EV −1.9)里完成。
        switch activeBackgroundMode {
        case .artwork:
            if let layers = playback.windowBackgroundLayers {
                // 窗口不可见 / 暂停播放时背景定格:没人看、或者画面上别的都不动,光斑还在转纯属耗电。
                WindowAnimatedBackground(
                    layers: layers,
                    animating: windowController.isSurfaceVisible && playback.isPlayingNow)
                    // 换歌重建整棵子树:动画从新一首的初始姿态干净重启,onAppear 重新点火。
                    .id(ObjectIdentifier(layers))
                    .overlay(Color.black.opacity(0.15))
                    .clipped()
                    // 换歌/高清替代到货都会产出新的图层实例(Equatable 按 === 实现),一条
                    // 过渡覆盖原来 artworkData 字节比较 + highRes 指针比较两条。
                    .animation(.easeInOut(duration: 0.5), value: playback.windowBackgroundLayers)
            }
        case .solid:
            activeBackgroundColor
        case .gradient:
            LinearGradient(
                colors: [activeBackgroundColor, activeBackgroundColorEnd],
                startPoint: activeGradientDirection == .vertical ? .top : .leading,
                endPoint: activeGradientDirection == .vertical ? .bottom : .trailing)
        case .glass:
            // 材质铺满即可 —— 它折射的是窗口**背后**的桌面,所以这一档必然要求窗口本体透明
            // (见 wantsTransparentWindow),否则折射到的只有窗口底色、看着就是一块死灰。
            Rectangle().fill(activeGlassIntensity.material)
        }
    }

    // 完全没有歌词内容 vs "这首歌还没解析完、collector 后台正在搜"共用同一个
    // allLines.isEmpty,含义不一样,判断条件跟 LyricsOverlayView.mainLine 里的同一个
    // 分支保持一致(playback.hasLyricsContent 的注释详见 LocalPlaybackSource)。文案复用
    // 已有的本地化字符串,不新造。
    // 广告/纯音乐两个分支必须排在"还在搜索中"前面,理由跟 LyricsOverlayView.mainLine
    // 一致,见 playback.isCurrentTrackAdBreak / isCurrentTrackInstrumental 定义处的注释。
    /// 停播欢迎态用哪个播放器(不一定是 Apple Music):设置里选了恰好一个具体播放器就用它;
    /// 「自动识别」、或者同时勾了两个以上具体播放器(没有唯一答案,跟纯 auto 归为同一类)时,
    /// 用停播前最后认下来的那家(LocalPlaybackSource 落在 UserDefaults,停播时快照已清空、
    /// 只有它还记得);全新用户兜底 Apple Music。
    /// 实现在 `IdlePlaybackActions.player`(灵动岛空闲展开卡要用同一份判定),这里只转发。
    private var idlePlayer: PlaybackPlayer { IdlePlaybackActions.player }

    /// 停播欢迎态:居中 hero(呼吸光晕音符 + 文案 + 按钮),替换整套没有内容的双列骨架。
    /// 按钮按播放器能力给:AM/Spotify 有 AppleScript 能真「继续播放」(AM=三段式,见
    /// resumePlayback 注释;Spotify 自带恢复上下文),失败兜底激活 App——点击永远有可见
    /// 反应;QQ/网易云/酷狗没有 AppleScript,只给「打开」。
    /// 呼吸:图标+光晕 2.6s 往复缩放,reduceMotion 下静止。
    private var idleWelcomeView: some View {
        let player = idlePlayer
        let playerName = player.displayName
        let canResume = player == .appleMusic || player == .spotify
        return VStack(spacing: 0) {
            // 呼吸交给 Core Animation(`LayerBreathing`,主线程不参与);原来的 SwiftUI `.repeatForever`
            // 是主线程逐帧推进的。看不见时照样停(那一侧省的是渲染服务的合成)。
            LayerBreathing(animating: !reduceMotion && windowController.isSurfaceVisible) {
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
            }
            .frame(width: 180, height: 180)
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
            // Last.fm 统计:今日/本周计数、那年今日、迷你热力图。连着账号才有;没连时这块整体
            // 缺席,欢迎态不受影响。
            IdleLastfmSection()
                .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 「继续播放」:AM 走三段式(裸 play→上次那首→都不行),Spotify 自带恢复;任何
    /// 失败都兜底把播放器 App 带到前台 —— 点了必须有可见反应(裸 play 对空队列是静默
    /// no-op,只靠它会"点了没反应")。
    /// 实现在 `IdlePlaybackActions.resume(player:)`(灵动岛空闲展开卡放同一颗键),这里只转发。
    private func resumeFromIdle(player: PlaybackPlayer) {
        IdlePlaybackActions.resume(player: player)
    }

    private func openIdlePlayerApp(_ player: PlaybackPlayer) {
        IdlePlaybackActions.openPlayerApp(player)
    }

    /// 第三个字段 `offersSearch`:这一档要不要在图标文案下面给一颗「搜索歌词…」。
    /// 只有「暂无歌词」「网络连接失败」为 true —— 前者是自动解析的明确结论,用户不服就手动搜;
    /// 后者是此刻查不了,网好了想立刻再查也在这里。**「纯音乐」刻意不给**;「没有在播放」
    /// 「广告中」没有可搜的对象,「搜索歌词中…」正在搜,兜底那档理论上到不了。
    private var emptyStateSpec: (icon: String, text: String, offersSearch: Bool) {
        // 判定与优先级在 Core(`LyricsWindowEmptyState.resolve`,各档为什么排在那里见那边的注释,
        // selftest 钉着顺序),这里只配文案。
        let state = LyricsWindowEmptyState.resolve(.init(
            hasTitle: !playback.title.isEmpty,
            isAdBreak: playback.isCurrentTrackAdBreak,
            isRadioTalkBreak: playback.isRadioTalkBreak,
            isInstrumental: playback.isCurrentTrackInstrumental,
            hasNoLyrics: playback.currentTrackHasNoLyrics,
            collectorNetworkDown: playback.collectorNetworkDown,
            hasLyricsContent: playback.hasLyricsContent,
            isPlaying: playback.isPlayingNow))
        let text: String
        switch state {
        case .notPlaying: text = L10n.t("没有在播放")
        case .adBreak: text = L10n.t("广告中")
        case .radioTalk: text = L10n.t("口白")
        case .instrumental: text = L10n.t("纯音乐")
        case .noLyrics: text = L10n.t("暂无歌词")
        case .networkDown: text = L10n.t("网络连接失败")
        case .searching: text = L10n.t("搜索歌词中…")
        case .none: text = L10n.t("无歌词")
        }
        return (state.icon, text, state.offersSearch)
    }

    /// 纯文本歌词兜底的静态展示(见 currentTrackPlainLyrics 声明处注释)。不用 rightPane
    /// 主分支那一整套逐字/滚动锚/间奏点渲染管线——那套是为"跟着播放位置走"设计的,这里的
    /// 内容压根没有时间戳,没有"现在唱到哪一行"这回事,硬套上去只会画出一个恒定不动的
    /// "当前行"高亮,反而误导用户以为它在跟播放联动。
    @ViewBuilder
    private func plainLyricsFallback(leading: CGFloat, trailing: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(L10n.t("这份歌词没有时间戳，无法跟随播放高亮或自动滚动"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hasArtworkBackground ? .white.opacity(0.75) : Color.orange)
                Text(playback.currentTrackPlainLyrics)
                    .font(.system(size: lyricFontSize * 0.62))
                    .lineSpacing(lyricFontSize * 0.32)
                    .foregroundStyle(hasArtworkBackground ? .white.opacity(0.92) : Color.primary)
                    .textSelection(.enabled)
            }
            .padding(.top, 40)
            .padding(.bottom, 60)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
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
                // 「搜索歌词…」:此前这个入口只藏在「⋯」菜单里,看到「暂无歌词」的人
                // 得先知道那里有。样式跟本窗口别的浮层控件一样是白色玻璃胶囊(clearGlassCapsule),
                // 动作跟「⋯」菜单那一项同一条 openLyricsSearch(),弹同一个面板、不另开小窗。
                if spec.offersSearch {
                    Button {
                        openLyricsSearch()
                    } label: {
                        Label(L10n.t("搜索歌词…"), systemImage: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .clearGlassCapsule(rim: Color.white.opacity(0.28))
                    .padding(.top, 6)
                }
            }
            .foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 系统版用 actions 插槽放同一颗按钮(按钮样式交给系统),条件同上。
            ContentUnavailableView {
                Label(spec.text, systemImage: spec.icon)
            } description: {
                EmptyView()
            } actions: {
                if spec.offersSearch {
                    Button(L10n.t("搜索歌词…")) { openLyricsSearch() }
                }
            }
        }
    }

    /// 这一行是不是把读音逐词标进正文了(标了就别再单独渲染一整行罗马音)。
}

// 一行歌词。
//
// 从 LyricsWindowView 的几个 @ViewBuilder 方法里拆出来变成独立的 View struct——
// LyricsWindowView 用 @ObservedObject 订阅了整个 PlaybackCoordinator(二十来个
// @Published:封面、音量、播放模式、收藏状态、暂停位置…),其中任何一个变动都会让整个
// body 重算;方法形式的行视图没有独立身份,只能跟着一起重建。稳定播放期间主线程约 22%
// 的时间耗在这类全表重建的布局计算上。拆成 struct + Equatable 之后,只有输入真的变了的
// 那几行才会重算 —— 换行时变的是当前行和它的邻居。
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
    /// 歌词字体族(空串 = 跟随系统)。
    let fontFamily: String
    /// 对唱行两侧留白的基准量,父视图按列宽和字号算好(见 LyricDuetLayout)。
    let duetInsetUnit: CGFloat
    /// 没有对唱标记的行居中(迷你「多行」);false = 左对齐(完整布局)。
    var centered: Bool = false
    /// 正在唱的字要不要上浮(迷你「多行」关、完整布局开)。
    var wordRise: Bool = true
    let onArtwork: Bool
    /// 正文色 / 副行(译文·罗马音)色。由窗口层解析好传进来,这里**不再**自己从 `onArtwork` 推 ——
    /// 推的话就把「文字颜色」那颗设置绕过去了。`onArtwork` 留着管别的(阴影、vibrancy 那类跟
    /// 背景深浅有关、跟文字色无关的东西)。
    let textColor: Color
    let secondaryColor: Color
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
            // 漏掉它 = 换字体后这一行不重画(整表行都挂着 Equatable 跳过重绘),表现是
            // "改了字体没反应、要滚一下或换首歌才生效"。
            && a.fontFamily == b.fontFamily
            && a.duetInsetUnit == b.duetInsetUnit
            && a.centered == b.centered
            && a.wordRise == b.wordRise
            && a.onArtwork == b.onArtwork
            // 漏掉这两个 = 改了「文字颜色」整表行不重画(全表行都挂着 Equatable 跳过重绘),
            // 表现同上面字体那条:"改了没反应,要滚一下或换首歌才生效"。
            && a.textColor == b.textColor
            && a.secondaryColor == b.secondaryColor
            && a.showRomanization == b.showRomanization
            && a.showTranslation == b.showTranslation
            && a.reduceMotion == b.reduceMotion
            && a.displayScale == b.displayScale
    }

    private var secondaryTextColor: Color { secondaryColor }

    /// 对唱歌词的左右分栏(见 LyricDuet)。
    ///
    /// nil = 这首歌没有演唱者标记(绝大多数歌),按宿主的排版走 —— 完整布局左对齐,迷你「多行」居中。
    private var side: LyricDuet.Side { item.line.side ?? (centered ? .center : .leading) }

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

    /// 这里用 `item.line.side` 而不是上面那个 `side` —— 后者已经把 nil 兜底成
    /// `.leading` 了,拿它算留白会让**每一首普通歌**的每一行都凭空缩进右边。
    private var duetInsets: (leading: CGFloat, trailing: CGFloat) {
        guard let s = item.line.side else { return (0, 0) }
        switch s {
        case .leading: return (0, duetInsetUnit)
        case .trailing: return (duetInsetUnit, 0)
        case .center: return (duetInsetUnit, duetInsetUnit)
        }
    }

    /// 这一行能不能把罗马音标到每个词底下:开着「显示罗马音」且引擎给这一行分出了词组
    /// (日文靠分词器、中文/粤语靠字数对音节数,见 LyricsOverlayView 同名属性)。
    /// **不看 isActive**:非当前行同样逐词标——只给当前行逐词、其它行退回正文下方一整行
    /// 罗马音的话,同一句话唱完往上一滚,读音的排法会跟着换一种,把行与行之间的"景深"
    /// 差异做成了"内容"差异。见 07 章决策 #21。
    private var usesPerWordRomanization: Bool {
        showRomanization && item.line.wordGroups?.isEmpty == false
            && item.line.words != nil
    }

    // Apple Music 歌词页的景深(不再目测,直接从 AM 截图**拟合**)。
    // 方法:AM 整窗截图里同一句「无敌铁金刚」出现在 d0/d1/d2/d3 多个距离上,同文行的
    // 墨量总和(∑亮度-背景)是高斯模糊的不变量,比值就是不透明度;特写图里再拿 d0 行
    // 人工加 σ 扫描去逐像素拟合各距离行,解出每档的 σ。
    // 量出:α d1≈0.42、d2≈0.41、d3≈0.28、d4≈0.23 —— 近两档几乎不衰减,d3 起掉得快。
    private var lineOpacity: Double { LyricsWindowDepth.opacity(distance: distance) }

    // 模糊量:同一次拟合解出 σ(d1)=3.0px、σ(d2)=4.5px、σ(d4)=7.5px —— 严格线性
    // σ = 1.5×(d+1)px,除以字号 101px 得 **0.0148×(d+1) 字号**(d1≈3%、d4≈7.4%,
    // distance 本身封顶 4,不需要另设上限)。历史:08-04 固定 1.6pt/行"远行失真"→
    // 1.1pt/行"不够糊"→ 08-21 按特写目测 9%/22%"太糊"→ 回收 6%/15%"还是有点糊"
    // ——前四版都在猜,这版是从截图解出来的,d1 比 6% 那版整整轻一半。
    // SwiftUI 的 .blur() 本身是可动画属性,复用调用点已有的 .animation(value: distance)。
    private var lineBlur: CGFloat { LyricsWindowDepth.blurRadius(distance: distance, fontSize: fontSize) }

    var body: some View {
        VStack(alignment: alignment.horizontal, spacing: 6) {
            mainText
            // 罗马音在**下面**,跟 Apple Music 一致(原来在上面)。分得出词组的行(不论
            // 活跃)读音已经逐词标进 mainText 里了,这里就不再重复一整行。
            if showRomanization, !usesPerWordRomanization, let roma = item.line.romanization {
                Text(roma)
                    // 复用悬浮歌词那条字体解析(空 family 走系统、装不上兜底系统),
                    // 名字带 overlay 只是它最早的出处,逻辑是通用的 —— 别再复制一份。
                    .font(.overlayFont(familyName: fontFamily, size: romaFontSize, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
            }
            if showTranslation, let tr = item.line.translation {
                Text(tr)
                    .font(.overlayFont(familyName: fontFamily, size: translationFontSize, weight: .semibold))
                    .foregroundStyle(secondaryTextColor)
            }
        }
        // Apple Music 歌词是左对齐排版,从居中改过来。对唱歌词按演唱者分左右
        //,不带标记的歌 side 恒为 .leading,跟原来完全一致。
        .multilineTextAlignment(textAlignment)
        // 对唱行的两侧留白(见 LyricDuetLayout)。光靠对齐不够 —— 这一列按比例算只放得下约
        // 12 个汉字,顶满整宽的行左对齐和右对齐渲染完全相同。
        // 留白在 frame 之内、撑宽之前:先把可用宽度收窄,再在收窄后的范围里按 side 对齐。
        .padding(.leading, duetInsets.leading)
        .padding(.trailing, duetInsets.trailing)
        .frame(maxWidth: .infinity, alignment: alignment)
        // 动画屏障(60fps 逐帧胶片实测抓包定的):下面那两条行级 .animation(value:) 本意只给
        // opacity/blur 的景深过渡用,但它们的作用域是整棵子树 —— 行激活瞬间词的填色取值从
        // "定格全亮"跳到"按时间≈0",这个 diff 被 lineTransition 捕获,渐变 stop 被从 1 插值回 0,
        // 表现为"下一行前几个字先全亮、亮暗边界 ~100ms 从右往左回撤"。字级叶子上的
        // .transaction{animation=nil} **拦不住**这条路径;同类型的 .animation(nil, value:) 屏障
        // (内层覆盖外层是文档化行为)插在内容与 opacity/blur 之间才切实有效:内容子树对这两个
        // value 的变化拿到 nil 动画,opacity/blur 在屏障之上、照常吃外层动画。
        .animation(nil, value: distance)
        .animation(nil, value: isHovered)
        .opacity(isHovered ? 1 : lineOpacity)
        // 激活行的不透明度**瞬时到位**(60fps 亮度轨迹实测):行落位瞬间填色已瞬时切到"未唱
        // 暗色",若不透明度还在 0.42→1.0 慢慢爬,两通道相乘出一个"先暗一拍(129→120)再用
        // 0.45s 爬回 139"的凹陷 —— 观感就是"新行像被重新加载一遍,闪烁一下"。激活行直接落在
        // 终态(129→139 的一次性小步升,无凹陷);退场行/其他行仍走 lineTransition(1→0.42 的
        // 退暗要动画,否则旧行"啪"地熄灭)。模糊不在此列 —— 它由更外层的 .animation 驱动,
        // 激活行仍有 0.45s 的"对焦"过程。
        .animation(isActive ? nil : LyricsWindowView.lineTransition, value: distance)
        // 模糊跟缩放一样受 reduceMotion 影响时直接关掉——虽然模糊本身不是"位移类"动效,
        // 但它是这套"聚焦感"视觉效果里跟缩放同一批的非必要装饰,减少动态效果的用户大概率
        // 也不想要这层模糊,统一用同一个开关关掉,不单独加一个新设置项。
        // 鼠标悬在哪一行,哪一行就恢复清晰 —— 跟 Apple Music 一样,让你能看清要跳去的是
        // 哪一句,再决定点不点。
        .blur(radius: (reduceMotion || isHovered) ? 0 : lineBlur)
        // 别给当前行挂 .scaleEffect(1.02)。.scaleEffect 是**渲染后**的仿射变换:文字先按
        // 原字号栅格化,再整体拉大 1.02 倍,是个非整数倍重采样。在 Retina 上看不太出来,在 1x
        // 外接屏上直接把**最该看清的那一行**糊掉 —— 同一张截图里当前行的字形边缘平均过渡宽度
        // 1.48px,而同窗口里没做任何变换的左栏歌名只有 1.25px、歌手行 1.14px。
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
        // 当前行的逐字填色也是"同色 35% → 全强度"的同色系渐变,不引入另一个强调色。
        // 这个"同色"由窗口层给(`.auto` 档解析出来就是老的"有封面白、没封面 .primary";
        // 用户钉死了颜色就是那个颜色),远近区分交给 lineOpacity。
        let base: Color = textColor
        // 有逐字时间轴的行**不论活跃与否都走 KaraokeLineText**。非活跃走单个 Text、激活瞬间
        // 整棵子树换成 WrapLayout+逐词结构的话,SwiftUI 对结构替换只能淡出淡入,叠上行级
        // blur/opacity 动画,观感就是"新行有一个虚化重新构建的过程"(纯行级歌词两个状态都是
        // Text,没这问题——正好解释"有时候")。统一结构后只有参数在变,无替换。非活跃行:
        // 词强制全填色(视觉=原来的全色 Text)、粗/细时钟全停、字不上浮 —— 静态成本只是
        // "多几个 Text + 一次 WrapLayout 布局",没有逐帧失效(性能红线见 KaraokeLineText.body
        // 的实测记录)。
        // 逐词读音(groups)也**不论活跃与否**都挂(决策 #21):别再给非活跃行开例外("渲染读音
        // 占位会撑高行高"——开着罗马音的非活跃行本来就在下面另画一整行读音,占位早就在)。开了
        // 例外只换来"当前行逐词、一滚上去就变回整行"的排法跳变,以及激活瞬间一次真正的结构替换
        // (WrapLayout+整行 Text 与 带读音的 WrapLayout)—— 正是统一结构想消灭的。
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
                fontFamily: fontFamily,
                reduceMotion: reduceMotion,
                displayScale: displayScale,
                rowAlignment: rowAlignment,
                rises: wordRise
            )
        } else {
            Text(item.line.plainText ?? "")
                .font(.overlayFont(familyName: fontFamily, size: fontSize, weight: .bold))
                .foregroundStyle(base)
        }
    }
}

// 当前行的逐字填色。
//
// ---- 驱动方式的定稿(别再翻烧饼)----
//
// 逐帧重算(TimelineView 叶子时钟)是**实测后的终点**,不是没试过更"先进"的:排程式
// (fillFraction 对时间线性 → 一次性排 .linear 显式动画交给渲染管线插值,这类歌词渲染的
// 常规架构)CPU 上确实是零逐帧代码 —— 但 SCK 逐帧探针实测 **macOS 只以 ~20Hz 提交这些
// 动画**(系统对长时程慢动画自动降档,无 API 干预;对照组悬浮歌词的 TimelineView 30Hz
// 准点投递),20Hz×14px 的边缘步进正是那种"卡顿感"。TimelineView 的频率受控、实测准点,
// 所以用逐帧重算,档位开到面板满刷新率(WordKaraokeGradient.windowRefreshInterval = 60Hz)。
//
// 逐帧的开销结构已经修到位(实测记录保留在此,别退回去):
// * TimelineView 包在 WrapLayout 外面 = 每帧重排版(主线程 91% 忙,67% 在
//   LayoutEngineBox.sizeThatFits)→ 时钟必须下沉到**字级叶子**,布局每帧不再被推翻。
// * 一行十几个相位不齐的满速字时钟并集盖满每个显示帧(85.8% 忙)→ 行级 4Hz 粗时钟只判
//   "哪个字正在扫",只有那个字保留满速细时钟。
// * WrapLayout contentKey 缓存(粗 tick 不再整行重测宽)、Palette 纯色渐变跨帧复用
//   (静态词不再每 tick 重建 AnyShapeStyle)。
// 排程式那轮留下的三个修复也都保留:①激活瞬间取值跳变被行级 .animation(value:) 插值成
// "全亮再褪色"→ 叶子挂 .transaction 禁掉外来动画;②forceFilled 用 fraction=1.0 走不到
// 纯色快路径、右缘 band 段被淡到半强度 → 定格值 1+band;③上浮参数(幅度 0.05em、时长
// min(词长,1000ms) —— 两头的取舍见 riseWindowMs 注释)。
/// 迷你窗中间那两行(当前行 + 下一行)。换句**不做动画**,新的一句直接替上来(见 07 章决策 42)。
///
/// 1. **每一行按歌词 id 保持同一个视图**(ForEach 按 id)。换句时下一行那个视图原地升格成当前行,
///    只翻 isActive,不重建。
/// 2. **两个位置用同一套渲染结构**(有逐字数据就都走 `KaraokeLineText`,靠 isActive 区分),升格时
///    不做结构替换 —— 结构一换就是"虚一下重建"(07 章决策 11 同一个坑)。
/// 3. **大小靠缩放,不靠改字号**:两行都按当前行字号、当前行宽度排版,下一行只是整体缩到
///    `nextScale`。所以下一行显示的就是它升格之后的折行样子,升格时不重新折行。
///
/// Equatable:窗口 body 每次重算都会把它重建一遍,只比较值输入才挡得住(同完整布局 LyricsLineRow)。
private struct MiniLyricsReel: View, Equatable {
    let current: LyricsWindowLine?
    let next: LyricsWindowLine?
    let fontSize: CGFloat
    let fontFamily: String
    let color: Color
    let secondaryColor: Color
    let showRomanization: Bool
    let showTranslation: Bool
    /// 换行 / 滚动。滚动时每一行(含译文、罗马音)都只占一行高,放不下的横向滚动;带逐字时间轴的
    /// 当前行走悬浮歌词那条图层版跟唱滚动(`OverlayScrollingLyricRow`),跟着唱到哪滚到哪。
    let lineOverflow: OverlayLineOverflow
    /// 滚动档的时间基准指纹(换行档恒 nil)。它一变,reel 就重算一次、把新的播放位置交给图层那一行,
    /// 那一行按漂移判断决定要不要重装动画。少了它,拖进度 / 调歌词偏移之后填色会一直按旧时间跑,
    /// 直到换句 —— 这层 Equatable 正好把能纠正它的那些重算全挡掉了。
    let timing: Timing?
    let isPlaying: Bool
    let fillSettled: Bool
    let reduceMotion: Bool
    let displayScale: CGFloat

    /// 下一行相对当前行的大小(原来下一行字号 = 当前行 × 0.62)。
    static let nextScale: CGFloat = 0.62
    /// 下一行的透明度。颜色两行共用正文色,压暗只靠它。
    static let nextOpacity: Double = 0.55

    struct Timing: Equatable {
        let anchorFetchedAt: Date?
        let anchorProgressMs: Int?
        let pausedPositionMs: Int?
        let offsetMs: Int
    }

    private enum Role { case current, next }

    private struct Row: Identifiable {
        let line: LyricsWindowLine
        let role: Role
        var id: String { line.id }
    }

    private var rows: [Row] {
        var out: [Row] = []
        var seen = Set<String>()
        for (line, role) in [(current, Role.current), (next, .next)] {
            guard let line, seen.insert(line.id).inserted else { continue }
            out.append(Row(line: line, role: role))
        }
        return out
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            ForEach(rows) { row in
                rowView(row, isLast: row.id == rows.last?.id)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, isLast: Bool) -> some View {
        let scale: CGFloat = row.role == .next ? Self.nextScale : 1
        let opacity: Double = row.role == .current ? 1 : Self.nextOpacity
        MiniReelRowBox(scale: scale, trailingSpace: isLast ? 0 : fontSize * 0.34) {
            VStack(spacing: fontSize * 0.16) {
                lineText(row)
                if row.role == .current, showRomanization,
                   let roma = row.line.line.romanization, !roma.isEmpty {
                    subLine(roma, size: fontSize * 0.54, weight: .medium)
                }
                if row.role == .current, showTranslation,
                   let tr = row.line.line.translation, !tr.isEmpty {
                    subLine(tr, size: fontSize * 0.61, weight: .semibold)
                }
            }
            .scaleEffect(scale, anchor: .top)
        }
        .opacity(opacity)
    }

    /// 译文 / 罗马音那一行。滚动时钉成一行、放不下就跑马灯(滚一遍停在句尾,换句才归零)。
    @ViewBuilder
    private func subLine(_ text: String, size: CGFloat, weight: OverlayFontWeight) -> some View {
        let label = Text(text)
            .font(.overlayFont(familyName: fontFamily, size: size, weight: weight))
            .foregroundStyle(secondaryColor)
        if lineOverflow == .scroll {
            label
                .overlayLineFit(.scroll)
                .overlayScroll(true, id: text, alignment: .center,
                               height: Self.scrollLineHeight(
                                   .overlayFont(familyName: fontFamily, size: size, weight: weight)))
        } else {
            label
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    /// 滚动模式下一行字的高度 —— 跟 `OverlayPlayback.scrollTextHeight` /
    /// `OverlayLyricScrollView` 里的行高必须同一个式子,否则图层版那一行的字会被裁掉一截。
    static func scrollLineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 2
    }

    @ViewBuilder
    private func lineText(_ row: Row) -> some View {
        if lineOverflow == .scroll {
            scrollingLineText(row)
        } else {
            wrappingLineText(row)
        }
    }

    /// 滚动模式:每一行钉成一行高。
    ///
    /// 带逐字时间轴的**当前行**走悬浮歌词那条图层版(整行一张长图交给 CALayer,滚动与填色各一条
    /// 关键帧动画,跟着唱到哪滚到哪);别改成 `MarqueeText` 包 `KaraokeLineText` —— 悬浮歌词为
    /// 这件事实测过,SwiftUI 那条会把主线程打满、滚动一顿一顿(04 章「长句处理」)。
    /// 上一行 / 下一行 / 没有逐字的行画成一行字的跑马灯。代价是下一行升格成当前行时换了一次渲染
    /// 结构(跑马灯 → 图层),那一下是淡入淡出,跟着升格的动画一起走。
    @ViewBuilder
    private func scrollingLineText(_ row: Row) -> some View {
        let font = NSFont.overlayFont(familyName: fontFamily, size: fontSize, weight: .bold)
        let height = Self.scrollLineHeight(font)
        if row.role == .current, let words = row.line.line.words {
            let unsung = NSColor(color.opacity(WordKaraokeGradient.dimOpacity))
            OverlayScrollingLyricRow(
                spec: .init(
                    lineKey: row.line.id,
                    words: words,
                    groups: nil,
                    font: font,
                    romaFont: .overlayFont(familyName: fontFamily, size: fontSize * 0.54, weight: .medium),
                    baseColor: unsung,
                    fillColor: NSColor(color),
                    romaBaseColor: unsung,
                    romaFillColor: NSColor(color.opacity(0.75)),
                    strokeColor: nil,
                    alignment: .center,
                    // 跟换行模式那条逐字填色的时钟同一条停表判据。
                    paused: !isPlaying || fillSettled),
                // 位置基准同 KaraokeLineText:锚点外推 ?? 暂停冻结位置,再叠歌词时间轴偏移。
                nowMs: {
                    (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: Date())
                        ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
                        + PlaybackCoordinator.shared.currentLyricsOffsetMs
                })
            .frame(maxWidth: .infinity)
            .frame(height: height)
        } else {
            Text(row.line.line.plainText ?? "")
                .font(.overlayFont(familyName: fontFamily, size: fontSize, weight: .bold))
                .foregroundStyle(color)
                .overlayLineFit(.scroll)
                .overlayScroll(true, id: row.line.id, alignment: .center, height: height)
        }
    }

    @ViewBuilder
    private func wrappingLineText(_ row: Row) -> some View {
        if let words = row.line.line.words {
            KaraokeLineText(
                words: words,
                groups: nil,
                base: color,
                isActive: row.role == .current,
                isPlaying: isPlaying,
                // settled 是引擎按染色当前行算的,只挂当前行;挂到下一行会把它画成"已唱完"。
                fillSettled: row.role == .current && fillSettled,
                fontSize: fontSize,
                romaFontSize: fontSize * 0.54,
                fontFamily: fontFamily,
                reduceMotion: reduceMotion,
                displayScale: displayScale,
                rowAlignment: .center,
                // 迷你窗不做逐字上浮:两行挤在一小块里,字一抬一抬只显得在晃。
                rises: false
            )
            .multilineTextAlignment(.center)
        } else {
            Text(row.line.line.plainText ?? "")
                .font(.overlayFont(familyName: fontFamily, size: fontSize, weight: .bold))
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }
}

/// reel 里的一行:把唯一的子视图按给定宽度排版,报告 `内容高 × scale + trailingSpace` 的高度。
/// 配合子视图上同一个值的 `.scaleEffect(anchor: .top)`,得到"看起来小了、占的地方也小了、折行
/// 却不变"(单用 scaleEffect 只改画面不改布局,占位还是原尺寸)。
private struct MiniReelRowBox: Layout {
    var scale: CGFloat
    var trailingSpace: CGFloat

    private func contentHeight(_ sub: LayoutSubview, width: CGFloat?) -> CGFloat {
        sub.sizeThatFits(ProposedViewSize(width: width, height: nil)).height * scale
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sub = subviews.first else { return .zero }
        let width = proposal.width ?? sub.sizeThatFits(.unspecified).width
        return CGSize(width: width, height: contentHeight(sub, width: proposal.width) + trailingSpace)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let sub = subviews.first else { return }
        sub.place(at: CGPoint(x: bounds.midX, y: bounds.minY),
                  anchor: .top,
                  proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private struct KaraokeLineText: View {
    let words: [SyncedLyricWord]
    let groups: [SyncedLyricWordGroup]?
    let base: Color
    /// 是不是当前行。非活跃行也渲染这套 WrapLayout+逐词结构(消灭激活瞬间的整树替换),
    /// 但词强制全填色、粗/细时钟全停、字不上浮。
    let isActive: Bool
    let isPlaying: Bool
    /// 整行填色已定格(所有词/组越过过渡带)。true 时粗时钟停表、isLive 全灭,行尾/间奏/
    /// 曲末不再重排版。 必须同时喂给 isLive:只停粗时钟的话 isLive 会冻结在 true,最后
    /// 一个字的细时钟反而在整段间奏/outro 永动。
    let fillSettled: Bool
    let fontSize: CGFloat
    let romaFontSize: CGFloat
    /// 歌词字体族(空串 = 跟随系统)。**必须**进 lineLayoutKey,理由见那里。
    let fontFamily: String
    let reduceMotion: Bool
    let displayScale: CGFloat
    /// 对唱分栏:换行时行内也要跟着靠左/靠右/居中,否则右侧那句折下来的第二行会飘回左边。
    var rowAlignment: WrapLayout.RowAlignment = .leading
    /// 正在唱的字要不要上浮(完整布局要、迷你不要)。
    var rises: Bool = true

    /// WrapLayout 的内容身份:行文本/字号/字体族/罗马音形态都没变时,
    /// 布局回合跳过整行 CoreText 重新测宽(见 WrapLayout.Cache 守卫注释)。
    /// 文本身份用 words 拼接(低频:只在行内容/字号/字体变化时走到)。
    ///
    /// **字体族必须在里面**。这里原来写死 `.system`,所以注释说"fontSize/romaFontSize 就是
    /// 完整字体身份" —— 字体可选之后那句话不再成立。漏掉它,换字体时 key 不变、缓存里还是上一个
    /// 字体量出来的每个词的宽度,WrapLayout 就拿**陈旧宽度**去摆新字形:窄字体换宽字体会重叠,
    /// 反过来会散开,而且换行位置也是错的。这正是 WrapLayout.contentKey 头注里那句
    /// "漏掉一个影响尺寸的输入 = 拿陈旧尺寸错误换行"。
    private var lineLayoutKey: AnyHashable {
        AnyHashable(WindowLineKey(
            text: words.map(\.text).joined(),
            hasGroups: groups?.isEmpty == false,
            fontSize: fontSize,
            romaFontSize: romaFontSize,
            fontFamily: fontFamily))
    }

    private struct WindowLineKey: Hashable {
        let text: String
        let hasGroups: Bool
        let fontSize: CGFloat
        let romaFontSize: CGFloat
        let fontFamily: String
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
    /// pausedPositionMs,退到 ?? 0 会把整行画回"未唱"态。
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
        let end = w.startMs + max(1, w.durationMs) + (rises ? Int(KaraokeWordText.riseWindowMs(for: w)) : 0)
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
                                                fontSize: fontSize, fontFamily: fontFamily,
                                                reduceMotion: reduceMotion,
                                                displayScale: displayScale,
                                                rises: rises,
                                                // 非活跃行定格全填色、不上浮,跟下面无词组那条分支一致(非活跃行也走这条
                                                // 分支,见 LyricsLineRow.mainText)。
                                                forceFilled: !isActive,
                                                lineSettled: fillSettled)
                            }
                        }
                        // 这一行已经在走逐词罗马音(外层 groups 非空),每一组都要占住这一行读音的高度,
                        // 哪怕这一组没有读音(混合语言行里英文词的 romanization 是 nil)—— 直接不摆这个
                        // 子视图的话,这一组的 VStack 矮一截,WrapLayout 按行高把矮的往下居中,英文词就跟
                        // 韩文词的读音撞到同一条水平线上,看着像"分成了两行"。用占位撑住同样的字体行高,
                        // 组跟组才能对齐,空位置真的只是空、不是消失。
                        // 占位不能用空字符串 "" —— Text 在这个上下文里量出来的高度会直接塌成 0(没有
                        // 字形可排),等于没修。换成一个空格 " " 才有真实行高,这是标准规避写法。
                        let romaWord = SyncedLyricWord(
                            text: g.romanization ?? " ", startMs: g.startMs,
                            durationMs: max(1, g.endMs - g.startMs))
                        KaraokeWordText(
                            word: romaWord,
                            base: base.opacity(0.75), isPlaying: isPlaying,
                            isLive: isLive(romaWord, atMs: coarseMs),
                            staticDate: coarseDate,
                            fontSize: romaFontSize, fontFamily: fontFamily, weight: .medium,
                            reduceMotion: reduceMotion, displayScale: displayScale,
                            rises: false, // 读音不跟着抬,只有正文的字会浮起来
                            forceFilled: !isActive,
                            lineSettled: fillSettled
                        )
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 2)
                        .opacity(g.romanization == nil ? 0 : 1)
                    }
                }
            } else {
                ForEach(words.indices, id: \.self) { i in
                    KaraokeWordText(word: words[i], base: base, isPlaying: isPlaying,
                                    isLive: isLive(words[i], atMs: coarseMs), staticDate: coarseDate,
                                    fontSize: fontSize, fontFamily: fontFamily,
                                    reduceMotion: reduceMotion,
                                    displayScale: displayScale,
                                    rises: rises,
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
/// 位置、软边=词宽的 ±band),唯一差别是刷新档位(60Hz vs 30Hz,
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
    /// 歌词字体族(空串 = 跟随系统)。
    let fontFamily: String
    /// 换成 `OverlayFontWeight` 而不是 `Font.Weight`:自定义字体要靠 `NSFontManager` 按
    /// **AppKit 的 0…15 粗细刻度**去取字面,而 `Font.Weight` 是个不透明 struct、给不出那个数。
    /// 这个枚举两边都给得出(swiftUIWeight / appKitWeight),是全仓字体解析的共同入口。
    /// 默认档 `.bold` 与改动前的 `Font.Weight.bold` 逐像素等价。
    var weight: OverlayFontWeight = .bold
    let reduceMotion: Bool
    let displayScale: CGFloat
    var rises: Bool = true
    /// 非活跃行(结构统一,见已知坑 #11):不按时间算填色,恒为全色;不上浮。时钟由上游的
    /// isLive=false 停掉,这里只管画面。
    var forceFilled: Bool = false
    /// 整行已定格:停表后 staticDate 冻结在最后一次粗 tick(最多陈旧 250ms),若恰好早于
    /// 末字的完成时刻,末字的渐变会被算回"没填完"的位置 —— 表现是"行尾最后一两个字染完
    /// 又退去染色","有时候"= 停表与粗 tick 的相位差。定格的语义本来就是"所有词都已填满、
    /// 所有字都已浮定"(settled 阈值≥每个词的完成点、rise 窗口 min(词长,1000) 必然早于
    /// 1.08×词长的定格点),所以 settled 时直接渲染终态,不再依赖任何时间基准。
    /// 与 forceFilled 的区别:行还是当前行,浮起要**保持**不落回。
    var lineSettled: Bool = false

    /// 定格全填色的 fraction:必须取 1+band 让软边**整个**越过右缘走进纯色快路径 ——
    /// 取 1.0 的话 left=1−band<1,右缘 band 段会被淡到半强度(排程式那轮修掉的隐藏 bug)。
    private static let settledFraction = 1 + KaraokeFill.wordEdgeSoftenBand

    /// 抬升时长 = min(词长, 1000ms),两头都有实测背书:
    /// * 上界 1000ms 防长词亚像素颤抖 —— 3s 的字按词长爬完整词=每帧 ~0.05 物理像素,
    ///   字形抗锯齿被持续重采样,肉眼上下颤;到顶后钉在整数设备像素上不动。
    /// * 跟词长对齐防"人都走了还在浮" —— 上浮不得晚于这个字自己的染色结束,短词随染色
    ///   一起利落收尾。
    /// KaraokeLineText.isLive 用它决定细时钟要活到多晚,所以是 internal。
    static func riseWindowMs(for w: SyncedLyricWord) -> Double {
        min(max(1, Double(w.durationMs)), 1000)
    }

    /// 上浮幅度 0.05em,收到整数个设备像素防 1x 屏重采样发糊。
    private var riseAmplitude: CGFloat {
        let scale = max(1, displayScale)
        return (fontSize * 0.05 * scale).rounded() / scale
    }

    /// 上浮:sin(p·π/2) 平滑升到 1、终点斜率 0,抬起后**保持**,行退场落回(「点头式」被
    /// 过)。
    private func rise(atMs currentMs: Int) -> CGFloat {
        guard rises, !reduceMotion else { return 0 }
        let elapsed = Double(currentMs - word.startMs)
        guard elapsed > 0 else { return 0 } // 还没唱到这个字
        let p = min(1, elapsed / Self.riseWindowMs(for: word))
        return -sin(p * .pi / 2) * riseAmplitude
    }

    var body: some View {
        // 两层:底下一层透明的同款字只管占位(决定尺寸,永远不变),逐帧换色的那层作为 overlay
        // 画在同一位置。别把 TimelineView 直接放回布局链里:它每帧一失效,SwiftUI 就顺着把所有
        // 祖先重新测一遍 —— 这一行、整张列表(几十行)、滚动视图、直到窗口根,颜色变化明明不改
        // 尺寸也照测。实测多行列表开着时主线程每帧约 40ms、卡顿不断(07 章决策 50)。overlay 里
        // 怎么变都不影响父视图尺寸,每帧只剩这一个字自己重画。
        //
        // 非当前行(forceFilled)只画一层静态字:画面跟时钟那层的定格终态逐像素相同(同一份
        // fullStyle、零上浮),却省掉一半 Text 和整个 TimelineView。整张列表几百个字,建树 / 换字号
        // 时这两样的解析和测量就是大头(07 章决策 53)。行激活时这里换分支,换在行级
        // `.animation(nil, value: distance)` 屏障之下,不会淡入淡出。
        if forceFilled {
            Text(word.text)
                .font(.overlayFont(familyName: fontFamily, size: fontSize, weight: weight))
                .foregroundStyle(WordKaraokeGradient.palette(fg: base).fullStyle)
        } else {
            Text(word.text)
                .font(.overlayFont(familyName: fontFamily, size: fontSize, weight: weight))
                .opacity(0)
                .overlay { animatedGlyph }
        }
    }

    private var animatedGlyph: some View {
        TimelineView(.animation(minimumInterval: WordKaraokeGradient.windowRefreshInterval,
                                paused: !isPlaying || !isLive)) { context in
            // 直接读单例而不是 @ObservedObject:这个闭包本来就由 TimelineView 按帧驱动,
            // 订阅反而会把协调器上二十来个 @Published 的每次变动都变成额外重算。
            let coordinator = PlaybackCoordinator.shared
            // 时钟停着时用粗时钟的时刻,理由见 staticDate。
            let date = isLive ? context.date : staticDate
            // +currentLyricsOffsetMs:同"当前词判定"的时间基准,不加会填到一半卡住;
            // ?? pausedPositionMs:暂停基准兜底。
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
                .font(.overlayFont(familyName: fontFamily, size: fontSize, weight: weight))
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
                // 必须跟底下那层同尺寸同位置:同一段字、同一个字体,不裁、不折。
                .fixedSize()
        }
        // 底下那层透明字已经被读屏读到了,这一层再进无障碍树就是同一个字读两遍。
        .accessibilityHidden(true)
    }
}

// MARK: - 进度条(瞬态自持,失效不击穿整窗)

/// AM 式 vibrancy 染色(太阳之子截图逐通道反解):左栏次级元素=**背景色相的亮化低饱和
/// 版**,不是半透明白 —— 纯白 alpha 的三通道等效透明度应相等,而实测副行是
/// r0.74/g0.58/b0.49(暖倾斜)。h/s 来自烘焙背景的 CIAreaAverage(见
/// WindowBackgroundLayers.tintHue),brightness/satScale 按元素档位:副行 0.5×/v0.85、
/// 时间行 0.62×/v0.68、进度已播段 0.5×/v0.92。背景层还没到(刚开窗)回退半透明白。
///
/// minContrastToBackground:固定 brightness 档是从**暗封面**反解的,背景自己亮起来
/// (bgV≈0.7)时标签亮度会撞上背景直接隐形。传入后保证与背景的亮度差 ≥ 该值,方向是
/// **提亮** —— 同帧对拍 AM 亮橙背景上歌手行 S0.27 V1.00、时间行 S0.39 V0.94、播控近白,
/// **全部比背景亮**。别改成压暗(压成 V0.42 深棕会被看出"字颜色没统一"):AM 的统一感
/// = 次级元素清一色淡奶油,对比度靠 文字淡 vs 背景艳 的饱和度差。唯一压暗分支:背景
/// 又亮又淡(近白封面,bgV>0.75 且 S<0.5),淡奶油提不出对比,退成 bgV−0.32 的深色
/// (AM 白封面同款)。只给文字类调用用 —— 进度条已播段是控件,别传。
private func amVibrantColor(layers: WindowBackgroundLayers?, satScale: Double, satCap: Double,
                            brightness: Double, fallback: Color,
                            minContrastToBackground: Double? = nil) -> Color {
    guard let layers, layers.tintSaturation > 0.01 else { return fallback }
    // 亮度档与对比度保护的算术在 Core(`AMVibrancy.brightness`,selftest 钉着提亮 / 压暗两支)。
    let v = AMVibrancy.brightness(base: brightness, backgroundBrightness: layers.tintBrightness,
                                  backgroundSaturation: layers.tintSaturation,
                                  minContrast: minContrastToBackground)
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
    /// 收听次数徽标要用的曲目标识(摆在时间行正中央)。
    let title: String
    let artist: String
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
    /// 这一次 shownFraction 的变化要不要补间 —— 补间本身由 `ProgressFillLayer` 交给 Core Animation 做,
    /// 这里只告诉它「这一次走过去 / 直接到位」。
    @State private var fillAnimates = false
    @State private var progressPrimed = false
    /// 进度条轨道粗细:恒定 6。**别做"悬停变粗"** —— frame(height:) 参与布局,悬停那一下
    /// 会把上面整块内容顶起来;AM 的进度条常态就是粗的,悬停反馈只剩系统光标。
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
            // 什么位置数据都还没有(刚打开窗口、poller 还没读到第一份快照)时**占住同样的空间**,
            // 而不是整块不渲染。
            //
            // 不占位的话,等 anchor 到达才把这一行插进 playerPane 的 VStack,整个左栏的 Spacer 重新
            // 分配、上下内容各自位移十几 pt;而这块布局变化恰好落在 artworkCard 那条 0.5s easeInOut
            // 动画的同一个更新事务里,被它一起 animate 成"缓慢飘移" —— 表现就是"首次进入时进度条
            // 会从上面飘下来到对应位置"。占住位之后布局从第一帧起就是终态,插入这件事本身不再发生。
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
                    //
                    // 这一段画在 `ProgressFillLayer`(原生图层)上:几何照旧(满宽胶囊 + 左移
                    // + 固定胶囊裁剪,下面那段注释的每条结论都还成立),只是每秒那段 1 秒线性补间不再由
                    // SwiftUI 在主线程逐帧推,而是交给 Core Animation —— 原来那段动画段段相接、永远在跑,
                    // 歌词窗口因此一直按屏幕刷新率逐帧重算(见 ProgressFillLayer 头注)。
                    ProgressFillLayer(
                        color: NSColor(onArtwork
                            ? amVibrantColor(layers: backgroundLayers, satScale: 0.5, satCap: 0.4,
                                             brightness: 0.92, fallback: .white.opacity(0.85))
                            : primaryTextColor.opacity(0.85)),
                        fraction: shownFraction,
                        animatesChange: fillAnimates)
                        // 进度用 shownFraction(自己驱动)而不是 fraction,补间由下面的 onChange 显式决定 ——
                        // 挂 .animation(_:value: fraction) 那一版有两个症状:冷启动时 fraction 从 0 一步跳到
                        // 真实进度,被补成"滑过去";缩放窗口时 g.size.width 变了,而这次宽度变化恰好落在每秒
                        // 一次的动画事务里,于是整条也跟着平移。现在这两种情况都直接赋值、不补间。
                        //
                        // **绝不能**把宽度写回 `.frame(width: w * f)`:那是让**布局属性**跟着每秒一次的
                        // 线性补间走,而补间按显示帧插值,于是每一帧都要把整个 NSHostingView 重新布局一次。
                        // 实测(歌词窗口开着、正在播放)这一条就吃掉主线程的一大半:
                        //   双列(有这条进度条)61.4% 忙 / 单列(窄窗,播放器面板整块不显示)9.4% 忙
                        // 正解是整条满宽 + 只让**渲染变换**随进度走:变换不参与布局,补间只落在变换矩阵上。
                        //
                        // 但变换也不能用 `.scaleEffect(x: f)`:横向缩放会把圆头一起压扁,f 越小越扁,小到
                        // 一定程度圆头直接没了、变成直角 —— 表现是"进度条有时候变成方的,不是弧形"。离线渲染
                        // 逐列量覆盖高度坐实(条高 48px,数字=该列有色行数,取右端 12 列):
                        //   f=1.00 → 42,40,38,36,36,34,30,28,26,22,16,10   正常圆头
                        //   f=0.50 → 48,48,46,46,44,42,40,38,34,30,24,14   已明显压扁
                        //   f=0.02 → 48,48,48,48,48,48,48,48,48,48,48,48   纯矩形
                        // 一首 3 分钟的歌播到 0:04 就是 f≈0.02,进度靠前时方、靠后才圆是这个必然结果,
                        // 不是随机 —— 别按"偶发"去找竞态。
                        //
                        // 现在是 offset + clipShape:满宽胶囊整条**向左移出** (1-f)·w,外面再按固定的满宽胶囊
                        // 裁一次。两端的圆各有出处 —— 左端来自 clipShape 那个胶囊的左圆头(裁剪框不随 f 动、
                        // 只有内容在动),右端来自填充自己的右圆头(被 offset 平移到 f·w 处)。圆头形状因此跟
                        // f 完全无关:同一份离线测量里 f 从 0.02 到 1.00,右端剖面恒为
                        // 42,40,38,36,36,34,30,28,26,22,16,10。随 f 变的只有 `.offset`,跟 scaleEffect 一样是
                        // 不参与布局的渲染变换,上面那 61.4% 的教训依然成立。
                        //
                        // 移出量算在 Core 里(ProgressFillGeometry,含下限/退化窗口的夹值和完整来由),这里只
                        // 负责把它接到 offset 上 —— 分层理由见 AGENTS.md「XxxxView.swift 里不放几何/数学」,
                        // 而这条填充正是那条纪律的活教材:两轮 bug 全出在几何判断上。
                        .frame(width: g.size.width, height: scrubberHeight)
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
                    // 补间的终点必须是**一秒之后**的位置,不是刚算出来的这个当前位置。
                    // 写成 `shownFraction = f`(用一秒时间从上一档"走到"刚拿到的这一档)的话,
                    // 走到位的那一刻这个值已经旧了整整一秒 —— 稳态下 t+s 时刻条上显示的
                    // 是 pos(t-1+s),**恒定落后 1 秒**。这是把插值当外推用的经典错误:两档
                    // 采样之间做线性插值,画出来的永远是过去。
                    //
                    // 改成终点取 pos(t+1) 之后,[t, t+1] 这一秒里线性走过去,每一刻显示的
                    // 正好是 pos(t+s) —— 也就是当下的真实位置。
                    //
                    // 数据源本身不是问题:同一时刻实测 media-control 的 elapsedTimeNow 跟
                    // Apple Music 播放头只差 36~50ms,位置伺服的校正门槛也只有 0.15s。
                    let step = durationMs > 0 ? advancePerSecondMs / Double(durationMs) : 0
                    // 补间由 ProgressFillLayer 在 Core Animation 里做(1 秒线性),这里不再包 withAnimation。
                    fillAnimates = true
                    shownFraction = min(1, max(0, f + step))
                } else {
                    // 冷启动 / 拖动中 / 关了动效:直接到位。拖动时补间会让进度条追着
                    // 手指慢慢挪,手感发黏。
                    var t = Transaction()
                    t.disablesAnimations = true
                    fillAnimates = false
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
                // 右侧显示**总时长**而不是剩余时间(布局对齐 AM:它的歌词页
                // 时间行是「0:20 ··· 3:12」)。
                Text(Self.formatTime(ms: durationMs))
            }
            .overlay {
                // 收听次数徽标挪到
                // AM「高解析度无损」标签的原位——时间行正中央,复用同一份 AM 染色配方
                // (见 secondaryTextColor 注释),不再挤占标题下方独立一行。
                NowPlayingCountBadge(title: title, artist: artist, textColor: secondaryTextColor)
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

// MARK: - 音量胶囊(瞬态自持:soundVolume 只在这里订阅)

private struct WindowVolumeCapsule: View {
    let onArtwork: Bool
    /// 输出面板开关与"外接输出中"(键染红)状态都归窗口层管(面板是窗级 overlay,
    /// 见 LyricsWindowView.outputDevicePanel),这里只负责按钮本身。
    @Binding var showsOutputMenu: Bool
    let isExternalOutput: Bool
    /// 迷你窗控制条那一档:**只留滑杆和喇叭**,不摆 AirPlay 键和那条发丝分隔线,滑杆也短一半。
    /// 460pt 宽里三颗胶囊并排,这颗按完整形态(总宽 ~143)会把另外两颗挤出去;而输出面板是
    /// 窗级 overlay、迷你窗根本没有它的位置。
    var compact = false
    @StateObject private var model = Model()
    @State private var sliderHovered = false

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
            // 形态对照 AM 顶栏音量胶囊特写:**只有滑杆 + 右侧喇叭**,没有左侧静音键和分隔线,
            // 整体宽高比 ≈4:1(32pt 高 → 总宽 ~143)。静音功能收进右侧喇叭(点击切换,图标仍随
            // 档位变)。尺寸按"菜单栏 64px 作共同标尺"的同屏对拍定:滑块 12.5pt 高 / 轨道 3pt、
            // 滑杆长 ≈125pt、喇叭 ≈25pt。
            HStack(spacing: compact ? 8 : 10) {
                if !compact {
                    // AirPlay/音频输出键(AM 音量胶囊最左就是它 + 一条发丝分隔线):输出到**任何非内建
                    // 设备**(蓝牙耳机/AirPlay/显示器)时染红 —— AM 输出到蓝牙 AirPods 时键也是红的,
                    // 不只 AirPlay。点击弹的是窗级自绘面板(outputDevicePanel,与「⋯」菜单同款玻璃样式;
                    // 系统 NSMenu 的紧凑样式跟 AM 对不上)。
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) { showsOutputMenu.toggle() }
                    } label: {
                        Image(systemName: "airplay.audio")
                            // 17(对拍:AM 该键字形宽 33px@2x=16.5pt,16 号字形只量出 15.5pt,差半档)。
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
                }
                // 114(对拍:AM 滑杆区 228px@2x=114pt;124 会挤得整颗胶囊比 AM 宽 7pt)。
                volumeSlider(volume: volume)
                    .frame(width: compact ? 58 : 114, height: compact ? 18 : 22)
                Button {
                    PlaybackCoordinator.shared.toggleMute()
                } label: {
                    Image(systemName: volumeLevelIcon(volume))
                        .font(.system(size: compact ? 13 : 17))
                        // 图标宽度随音量档位变化,固定住,不然整条控件会左右呼吸。
                        .frame(width: compact ? 18 : 24, alignment: .leading)
                }
                .buttonStyle(WindowActionButtonStyle(onArtwork: onArtwork, inset: 4))
                .help(volume == 0 ? L10n.t("取消静音") : L10n.t("静音"))
            }
            .foregroundStyle(capsuleIconColor)
            .frame(height: compact ? 22 : nil)
            .padding(.horizontal, compact ? 12 : 14)
            // 7:胶囊总高 36(对拍 AM 71px@2x=35.5)—— 行的落点见 body 里 overlay 的注释。
            // 迷你那一档取 6,跟旁边两颗胶囊同高 34。
            .padding(.vertical, compact ? 6 : 7)
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
            // 滑块是**横向药丸**不是圆点:AM 特写里滑块宽约占滑杆全长 17%(30 宽在 88 长的滑杆里
            // 占 34%,太笨)。23(对拍:AM 滑块宽 47px@2x=23.5pt)。
            // 迷你那一档滑杆只有 58pt 长,滑块必须跟着缩 —— 照搬 23 的话它自己就占掉 40%,
            // 可走的行程不到一半,拖起来像坏了。
            let knob: CGFloat = compact ? 15 : 23
            let knobHeight: CGFloat = compact ? 11 : 14
            let track: CGFloat = compact ? 4 : 6
            let travel = max(0, w - knob)
            ZStack(alignment: .leading) {
                // AM 的轨道:已填充段是**亮白**、跟滑块连成一体;未填充段淡到几乎看不见(特写里喇叭
                // 前那段轨道基本隐形)。无封面背景时退回中性色。
                // 轨道 6pt(AM 整窗截图逐列采样,轨道厚 12px@2x=6pt;3pt 会细一倍)。
                Capsule()
                    .fill(onArtwork ? Color.white.opacity(0.20) : Color.primary.opacity(0.14))
                    .frame(height: track)
                // 已填充段 0.80(对拍:AM 已填充段亮度 223/255;0.95 在截图里跟纯白滑块几乎分不开,
                // 而 AM 是明显"滑块更白一档")。
                Capsule()
                    .fill(onArtwork ? Color.white.opacity(0.80) : Color.primary.opacity(0.55))
                    .frame(width: knob / 2 + travel * f, height: track)
                Capsule()
                    .fill(Color.white)
                    .frame(width: knob, height: knobHeight)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    // 指针在滑杆上时滑块略放大:告诉用户这一条能拖。scaleEffect 是渲染期变换,不动布局。
                    .scaleEffect(sliderHovered ? 1.18 : 1)
                    .animation(.easeOut(duration: 0.12), value: sliderHovered)
                    .offset(x: travel * f)
            }
            .frame(height: g.size.height, alignment: .center)
            .contentShape(Rectangle())
            .onHover { sliderHovered = $0 }
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

/// 自绘滚动指示条(对拍 AM:暗轨道 6pt + 白滑块 12pt、圆角胶囊、常显;位置由挂载处
/// padding 定,中心距窗右缘 59pt)。不可交互(allowsHitTesting false),滚动仍走滚轮/触控板。
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

/// 「播放记录」面板的外壳(完整背景见 LyricsWindowView.showsListenHistory 声明处注释):
/// 按 Last.fm 连没连二选一,自带 isConnected 订阅——不进 LyricsWindowView 自己的
/// WindowPlayback 代理,跟 ChartsPanelView/WindowVolumeCapsule 同一个理由,这一小块状态
/// 没必要让整个歌词窗口 body 陪跑。
private struct ListenHistoryPane: View {
    let leading: CGFloat
    let trailing: CGFloat
    let onArtwork: Bool
    let colorScheme: ColorScheme
    let onOpenTrack: (String, String) -> Void

    @ObservedObject private var stats = LastfmStatsService.shared

    var body: some View {
        Group {
            // showsCard: false —— 带卡片背景会让人觉得"盖了一层东西,不是歌词真的被换掉了"。
            // 歌词文字本身从来没有卡片背景,直接铺在封面模糊背景上;这里让它跟歌词用同一种
            // "裸铺"外观,onArtwork 同步传过去让文字颜色也走跟歌词一样的"有封面就固定白色系"
            // 那套(详见两个参数在 RecentListensPanel/PendingListensPanel 声明处的注释)。
            if stats.isConnected {
                RecentListensPanel(onOpenTrack: onOpenTrack, showsCard: false, onArtwork: onArtwork)
            } else {
                PendingListensPanel(onOpenTrack: onOpenTrack, showsCard: false, onArtwork: onArtwork)
            }
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        // 上下留白撑够,躲开两个**窗级 overlay**(不属于这块内容自己的布局,内容本身不知道
        // 它们在哪,只能靠外部撞出来的经验值让开),否则顶部卡头会跟音量胶囊挤在一起、底部行
        // 会跟翻译/播放记录那两颗圆钮撞上。
        // 上:音量/AirPlay 胶囊(WindowVolumeCapsule)贴 topTrailing、`.offset(y: 8)`、自身高
        // 36pt(`.padding(.vertical, 7)` 包住 ~22pt 内容)——两者共用同一个 safe-area 原点
        // (本窗口全程不 ignoresSafeArea 内容层,只有背景那层 ignoresSafeArea),下缘 = 8 + 36
        // = 44pt,52 留出 8pt 视觉间隙。
        // 下:翻译/播放记录那两颗圆钮贴 bottomTrailing、`.padding(.bottom, 11)`、自身高 36pt,
        // 上缘 = 11 + 36 = 47pt,52 同理留一点余量。
        .padding(.top, 52)
        .padding(.bottom, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, onArtwork ? .dark : colorScheme)
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
    /// 当前正文的只取词指纹(「当前使用」双判据);没有正文时 nil。
    let currentFingerprint: String?
    let durationSecs: Double

    var id: String { key }
}

/// 「显示简介」面板的一行:次级色标签 + 主色值,值可换行(长歌名/长专辑名)。
///
/// 标签**不能**固定用 `.secondary`:这块面板背景是 `.ultraThinMaterial`,故意让封面
/// 底色透上来(跟「…」菜单同一个设计意图,见 trackInfoPanel 注释),而 `.secondary` 那点
/// 暗淡的灰度差,在封面恰好是浅色/白色区域(挡在材质后面透出来)时几乎被完全吃掉 ——
/// `.primary` 的值列因为是接近纯白的高对比度还扛得住,所以只有标签列出问题。有封面背景
/// 时固定用不透明度收着点的白 + 一圈深色阴影(阴影是让白字在任意亮度背景上都读得出来
/// 的标准手法,悬浮歌词的文字阴影设置同一个道理),没有封面背景时原样退回 `.secondary`。
private struct InfoPanelRow: View {
    let label: String
    let value: String
    var onArtwork: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(onArtwork ? Color.white.opacity(0.75) : Color.secondary)
                .shadow(color: onArtwork ? .black.opacity(0.5) : .clear, radius: 1.5)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 简介面板的「网页」行:当前播放器自己那个平台上这首歌的歌曲页,一个可点的短标签。
///
/// 只显示对应播放器那一项(不是把三个平台全铺成一排 chips)—— 选哪一项在调用方
/// (`PlatformLinks.songLink`),这里只管画。
///
/// 标签写「网页」而不是「打开」:这里面只有 Apple Music 那个会**进 App**(music://),
/// QQ 音乐 / 网易云 / Spotify 都落到**浏览器**(理由见 PlatformLinks 头注)。与其在一行里
/// 解释两种落点,不如统一说"网页"、把唯一的例外(AM 进 App)当成惊喜。
private struct InfoPanelLinksRow: View {
    let name: String
    let url: URL
    var onArtwork: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L10n.t("网页"))
                .font(.system(size: 12))
                .foregroundStyle(onArtwork ? Color.white.opacity(0.75) : Color.secondary)
                .shadow(color: onArtwork ? .black.opacity(0.5) : .clear, radius: 1.5)
                .frame(width: 52, alignment: .leading)
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(name + " ↗")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }
}

/// 「⋯」菜单里的「在 Last.fm 上喜欢」,所有播放器都有(连着 Last.fm 时)。跟「减少推荐」同一个
/// 交互:点了不关菜单,勾的出现 / 消失就是反馈,再点一下撤销。
private struct LastfmLoveMenuRow: View {
    @ObservedObject private var model = LastfmLoveModel.shared

    var body: some View {
        Group {
            if model.target != nil {
                let loved = model.loved == true
                MoreMenuRow(title: L10n.t(loved ? "已在 Last.fm 上喜欢" : "在 Last.fm 上喜欢"),
                            trailingSystemImage: loved ? "checkmark" : nil) {
                    model.toggle()
                }
            }
        }
        .onAppear { model.retain() }
        .onDisappear { model.release() }
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

/// 可点控件的悬停 / 按下态:控件背后浮出一块圆角底,按下时再深一档 —— 告诉用户"指针已经在这颗
/// 上、可以点"。歌词窗口胶囊里的小图标键(窗口动作、迷你控制条)共用这一份。
///
/// 底块画在 background 里、向外扩 `inset`,**不参与布局**:这些键的框宽和间距都是对拍定的,悬停
/// 不许把邻居挤开。命中区跟着扩到底块那么大,指针落在底块上就算悬停,不会"亮着底块却点不到"。
private struct HoverHighlight: ViewModifier {
    let tint: Color
    var inset: CGFloat = 5
    var cornerRadius: CGFloat = 7
    var hoverOpacity: Double = 0.18
    var pressOpacity: Double = 0.30
    var pressed = false
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(pressed ? pressOpacity : (hovered ? hoverOpacity : 0)))
                    .padding(-inset)
            }
            .contentShape(Rectangle().inset(by: -inset))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// 窗口动作胶囊(置顶 / 全屏 / 控制条开关 / 迷你)的按钮样式:悬停 + 按下底块(见 HoverHighlight)。
/// 封面背景上用白、普通窗口用系统前景色,跟胶囊描边同一套取色(见 clearGlassCapsule 的 rim)。
private struct WindowActionButtonStyle: ButtonStyle {
    let onArtwork: Bool
    var inset: CGFloat = 5
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(HoverHighlight(
            tint: onArtwork ? .white : .primary, inset: inset, cornerRadius: cornerRadius,
            hoverOpacity: onArtwork ? 0.18 : 0.10, pressOpacity: onArtwork ? 0.30 : 0.18,
            pressed: configuration.isPressed))
    }
}

/// AM 式播控点按反馈:按下瞬间快缩到 0.8,松手带一点过冲弹回。按下用短 easeOut(手指
/// 落下要立刻有反应,弹簧起步太肉),松手换弹簧(过冲才是"弹"的观感)。reduceMotion 下
/// 不做过渡、但保留按压缩小本身 —— 它是"点到了"的功能反馈,不是纯装饰。
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

/// AM 式动画背景:暗底 + 3 份羽化光斑绕偏心锚点慢速往复摆动、以 lighten 混合。
///
/// 动画交给 **Core Animation** 跑(`BackdropLayerView` 里的关键帧动画),装好之后由渲染进程逐帧
/// 合成,主线程不参与。别改回 SwiftUI 的 `.rotationEffect` + `.repeatForever`:那种写法是 SwiftUI
/// 在主线程上逐帧推进的 —— 每帧重算依赖图 + 提交一次图层事务,这扇窗开着就一直跑,是它最大的
/// 常驻耗电项(07 章决策 48)。
///
/// `animating` = false 时定格在当下的姿态(窗口不可见 / 暂停播放 / 系统开了减弱动态效果)。
private struct WindowAnimatedBackground: View {
    let layers: WindowBackgroundLayers
    let animating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BackdropLayerView(layers: layers, animating: animating && !reduceMotion)
    }
}

/// 背景那棵图层树:base 铺满,每个光斑是「旋转层(锚点 = pose.anchor)⊃ 缩放层(绕中心放大 pose.scale)」,
/// 旋转层上挂一条 `transform.rotation.z` 往复动画。几何口径照 SwiftUI 那版:`scaledToFill` =
/// `.resizeAspectFill`(不裁,溢出部分转进来时要看得见)。图层用 AppKit 默认的 y 轴向上坐标,
/// 所以 SwiftUI 的锚点 y 要翻成 `1 − y`、角度要取负(`rotationEffect` 正角是顺时针,y 向上坐标里
/// 正角是逆时针)。别改成翻转坐标系省掉这两处换算:层背视图的翻转由 AppKit 管,跟手动设
/// geometryFlipped 叠在一起时方向说不准。
private struct BackdropLayerView: NSViewRepresentable {
    let layers: WindowBackgroundLayers
    let animating: Bool

    func makeNSView(context: Context) -> BackdropNSView { BackdropNSView() }

    func updateNSView(_ view: BackdropNSView, context: Context) {
        view.apply(layers: layers, animating: animating)
    }
}

@MainActor
final class BackdropNSView: NSView {
    private static let spinKey = "lyrimuse.backdrop-spin"
    /// 往复摆动的幅度(度)。光斑必须跟底层布局保持对齐,lighten 才是"原位增亮亮区";大角度
    /// 会把封面布局盖掉(见烘焙函数注释)。
    private static let swingDegrees: Double = 12

    private let baseLayer = CALayer()
    private var rotators: [CALayer] = []
    private var scalers: [CALayer] = []
    private weak var appliedLayers: WindowBackgroundLayers?
    private var isAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        baseLayer.contentsGravity = .resizeAspectFill
        baseLayer.actions = Self.noActions
        layer?.addSublayer(baseLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "transform": NSNull(),
        "anchorPoint": NSNull(),
    ]

    func apply(layers: WindowBackgroundLayers, animating: Bool) {
        if appliedLayers !== layers {
            rebuild(layers)
        }
        setAnimating(animating)
    }

    private func rebuild(_ layers: WindowBackgroundLayers) {
        appliedLayers = layers
        rotators.forEach { $0.removeFromSuperlayer() }
        rotators = []
        scalers = []
        let scale = window?.backingScaleFactor ?? 2
        baseLayer.contents = layers.base.cgImage(forProposedRect: nil, context: nil, hints: nil)
        baseLayer.contentsScale = scale
        for (i, pose) in layers.poses.enumerated() where i < layers.glows.count {
            let rotator = CALayer()
            rotator.actions = Self.noActions
            rotator.anchorPoint = CGPoint(x: pose.anchor.x, y: 1 - pose.anchor.y)
            let scaler = CALayer()
            scaler.actions = Self.noActions
            scaler.contents = layers.glows[i].cgImage(forProposedRect: nil, context: nil, hints: nil)
            scaler.contentsScale = scale
            scaler.contentsGravity = .resizeAspectFill
            scaler.opacity = 0.25
            scaler.compositingFilter = "lightenBlendMode"
            rotator.addSublayer(scaler)
            layer?.addSublayer(rotator)
            rotators.append(rotator)
            scalers.append(scaler)
        }
        isAnimating = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.frame = b
        for (i, rotator) in rotators.enumerated() {
            guard let pose = appliedLayers?.poses[i] else { continue }
            rotator.bounds = CGRect(origin: .zero, size: b.size)
            rotator.position = CGPoint(x: b.width * pose.anchor.x, y: b.height * (1 - pose.anchor.y))
            let scaler = scalers[i]
            scaler.bounds = CGRect(origin: .zero, size: b.size)
            scaler.position = CGPoint(x: b.width / 2, y: b.height / 2)
            scaler.transform = CATransform3DMakeScale(pose.scale, pose.scale, 1)
            // 模型值 = 往复的起点;动画在它上面跑(定格时就停在这里或暂停那一刻)。
            if rotator.animation(forKey: Self.spinKey) == nil {
                rotator.transform = CATransform3DMakeRotation(
                    Self.caAngle(pose.initialAngle - Self.swingDegrees), 0, 0, 1)
            }
        }
        CATransaction.commit()
    }

    /// 走 / 停。停 = 冻结在当下那一帧(speed 0 + timeOffset),再走时从那一帧接着摆,不跳。
    private func setAnimating(_ on: Bool) {
        guard on != isAnimating || (on && rotators.first?.animation(forKey: Self.spinKey) == nil) else { return }
        isAnimating = on
        guard let poses = appliedLayers?.poses else { return }
        for (i, rotator) in rotators.enumerated() where i < poses.count {
            if on {
                if rotator.animation(forKey: Self.spinKey) == nil {
                    let pose = poses[i]
                    let swing = CABasicAnimation(keyPath: "transform.rotation.z")
                    swing.fromValue = Self.caAngle(pose.initialAngle - Self.swingDegrees)
                    swing.toValue = Self.caAngle(pose.initialAngle + Self.swingDegrees)
                    // 烘焙里的时长带符号(负 = 反向),摆动只要一个周期长度,方向由往复本身给出。
                    swing.duration = max(1, abs(pose.spinDuration))
                    swing.autoreverses = true
                    swing.repeatCount = .infinity
                    swing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    swing.isRemovedOnCompletion = false
                    rotator.add(swing, forKey: Self.spinKey)
                }
                resume(rotator)
            } else {
                pause(rotator)
            }
        }
    }

    private func pause(_ l: CALayer) {
        guard l.speed != 0 else { return }
        let t = l.convertTime(CACurrentMediaTime(), from: nil)
        l.speed = 0
        l.timeOffset = t
    }

    private func resume(_ l: CALayer) {
        guard l.speed == 0 else { return }
        let paused = l.timeOffset
        l.speed = 1
        l.timeOffset = 0
        l.beginTime = 0
        l.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) - paused
    }

    /// SwiftUI 角度(度,顺时针为正)→ y 向上图层里的弧度(逆时针为正)。
    static func caAngle(_ degrees: Double) -> CGFloat { CGFloat(-degrees * .pi / 180) }
}

// MARK: - Last.fm 系列

/// 「第 N 次听」小胶囊,挂在时间行正中央 —— AM 在这个位置放的是「高解析度无损」这类
/// 音质标签,纯文字、无底色胶囊。数字来自 LastfmStatsService 的 nowPlayingCount
/// (track.getinfo userplaycount+1,孪生写法合并、防"刚 scrobble 查回 0"的坑都在服务侧)。
/// 刻意订阅整个服务单例但只在这棵小子树上 —— 主窗 body 的窄代理纪律不破(见文件头注),
/// 服务的其它 @Published 变动最多重算这一个胶囊。
/// 颜色直接吃调用方(WindowProgressSection.secondaryTextColor)算好的同一份 AM 染色,
/// 这里不再自己重算 onArtwork/layers。
private struct NowPlayingCountBadge: View {
    let title: String
    let artist: String
    let textColor: Color
    @ObservedObject private var stats = LastfmStatsService.shared

    var body: some View {
        // 容器必须永远在场:onAppear/onChange 是取数的唯一触发点,挂在条件内容上会
        // 陷入"没数字→不渲染→永远不取数"的死锁。
        Group {
            if stats.isConnected, !title.isEmpty, let n = stats.nowPlayingCount {
                // 点这行字直接跳设置的 Last.fm 详情页 —— 这个数字本来就来自 Last.fm scrobble 记录,
                // 点它去看/管理那份连接是最直接的落点。跳转机制跟 OnboardingView 的"现在去设置里
                // 连接"同一套:请求信箱/subject 两条路都要发(见 AppActions.requestSettings 注释),
                // 窗口未建/已开着都能对;这颗视图不在 Settings 场景里,openSettings 走 AppActions
                // 那份桥接,不额外加一份 @Environment(\.openSettings)。
                Button {
                    AppActions.shared.requestSettings(.account(.lastfm))
                    NSApp.activate(ignoringOtherApps: true)
                    AppActions.shared.openSettings?()
                } label: {
                    Text(String(format: L10n.t("收听次数：%@"), "\(n)"))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(textColor)
                }
                .buttonStyle(.plain)
                .help(L10n.t("在设置中查看 Last.fm"))
                .transition(.opacity)
            }
        }
        .onAppear { refresh() }
        .onChange(of: "\(artist)|\(title)") { refresh() }
    }

    private func refresh() {
        guard !title.isEmpty, LastfmStatsService.shared.isConnected else { return }
        LastfmStatsService.shared.refreshNowPlayingCount(title: title, artist: artist)
    }
}

/// 「显示简介」里的收听档案三行(系列 #5):累计次数 + 首次/上次听。首次/上次的两个
/// 请求(user.getTrackScrobbles)只在面板打开那一刻发,见服务侧 refreshNowPlayingSpan。
private struct InfoPanelListeningRows: View {
    let title: String
    let artist: String
    var onArtwork: Bool = false
    @ObservedObject private var stats = LastfmStatsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if stats.isConnected {
                if let n = stats.nowPlayingCount {
                    InfoPanelRow(label: L10n.t("累计"),
                                 value: String(format: L10n.t("第 %@ 次听"), "\(n)"), onArtwork: onArtwork)
                }
                if let span = stats.nowPlayingSpan, span.total > 0 {
                    if let first = span.first {
                        InfoPanelRow(label: L10n.t("首次听"),
                                     value: first.formatted(date: .abbreviated, time: .omitted), onArtwork: onArtwork)
                    }
                    if let last = span.last {
                        InfoPanelRow(label: L10n.t("上次听"),
                                     value: last.formatted(.relative(presentation: .named)), onArtwork: onArtwork)
                    }
                }
            }
        }
        .onAppear { refresh() }
        // 面板开着跨曲(自然播完切歌)时也要重取:参数跟着 playback 变了、onAppear 却不再
        // 触发,span 的 key 还是旧曲 →「首次/上次听」显示上一首的档案,跟同面板里新曲的
        // 歌名混排。
        .onChange(of: "\(artist)|\(title)") { refresh() }
    }

    private func refresh() {
        guard !title.isEmpty, stats.isConnected else { return }
        stats.refreshNowPlayingCount(title: title, artist: artist)
        stats.refreshNowPlayingSpan(title: title, artist: artist)
    }
}

/// 欢迎态(停播页)的 Last.fm 统计块(系列 #2/#3/#4):今日/本周计数、那年今日、迷你
/// 热力图。没连账号整块缺席,欢迎态与原版逐像素一致。
private struct IdleLastfmSection: View {
    @ObservedObject private var stats = LastfmStatsService.shared

    /// 「本周」跟设置页 / 待机页那个「近 7 天」**同一个口径**(自然日对齐的日桶,见
    /// IdleListeningStats.lastSevenDays)。之前这里直接读 API 的 `overview.week`
    /// (滚动 168 小时)——三个面里唯一一处口径不同;而且最近记录改走 collector
    /// feed 之后,`overview.week` 只在 feed 不在、退回轮询时才会被刷新,读它就是读一个陈值。
    /// 桶还没同步完时退回 API 值(那时桶本身残缺)。
    private var weekValue: Int? {
        guard !stats.dailySyncing else { return stats.overview?.week }
        return IdleListeningStats.lastSevenDays(
            dailyCounts: stats.dailyCounts, today: Date(),
            todayCount: stats.overview?.today,
            dayKey: { LastfmStatsService.dayKey($0) })
    }

    var body: some View {
        if stats.isConnected {
            VStack(spacing: 12) {
                if let o = stats.overview, let week = weekValue {
                    Text(String(format: L10n.t("今天听了 %1$@ 首 · 本周 %2$@ 首"),
                                "\(o.today)", "\(week)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let day = stats.onThisDay, let top = day.top.first {
                    VStack(spacing: 3) {
                        Text(String(format: L10n.t("那年今日 · %1$@ 年前听了 %2$@ 首"),
                                    "\(day.yearsAgo)", "\(day.total)"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(String(format: L10n.t("循环最多：《%1$@》— %2$@（%3$@ 次）"),
                                    top.track.title, top.track.artist, "\(top.count)"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                MiniHeatmapStrip(dailyCounts: stats.dailyCounts)
                // 首次连接的后台引导同步期间,这条迷你热力图是空白格子——不加一句说明
                // 用户会以为这个功能坏了。total > 3 跟 LastfmStatsService
                // 内部 dailySyncProgress 的既有分界线一致,日常 1-3 页 top-up 不弹这行字。
                if case .syncing(_, let total) = stats.bootstrapState, total > 3 {
                    Text(L10n.t("首次同步历史中，稍候完整数据会自动出现"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 420)
            .task {
                // 欢迎态可能一挂几小时,只靠 onAppear 一次会让"今天 N 首"越挂越旧 ——
                // 3 分钟轮一次;baseline/onThisDay 自带 TTL,重复调用是空操作。
                // refreshDailyCounts 只有单飞**没有 TTL**(每次都真发请求+落盘,审阅 #7),
                // 热力图按天变化,这里每 20 轮(约 1 小时)才带它一次。
                var tick = 0
                while !Task.isCancelled {
                    stats.refreshBaseline()
                    stats.refreshOnThisDay()
                    if tick % 20 == 0 { stats.refreshDailyCounts() }
                    tick += 1
                    try? await Task.sleep(nanoseconds: 180_000_000_000)
                }
            }
        }
    }
}

/// 近 12 周迷你热力图(系列 #4):列=周(旧→新)、行=周一到周日,数据直接读服务的
/// dailyCounts 天粒度桶(完整年历版在设置的统计页,LastfmHeatmapView)。
private struct MiniHeatmapStrip: View {
    let dailyCounts: [String: Int]
    private static let weeks = 12

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today) // 1=周日 … 7=周六
        let daysSinceMonday = (weekday + 5) % 7
        let thisMonday = cal.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        HStack(alignment: .top, spacing: 2) {
            ForEach(0..<Self.weeks, id: \.self) { w in
                let monday = cal.date(byAdding: .day, value: (w - Self.weeks + 1) * 7,
                                      to: thisMonday) ?? thisMonday
                VStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: d, to: monday) ?? monday
                        cell(for: day, future: day > today)
                    }
                }
            }
        }
        .help(L10n.t("近 12 周的收听热力（完整年历在设置的统计页）"))
    }

    private func cell(for day: Date, future: Bool) -> some View {
        let n = future ? 0 : (dailyCounts[LastfmStatsService.dayKey(day)] ?? 0)
        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(future ? Color.clear : Color.accentColor.opacity(intensity(for: n)))
            .frame(width: 7, height: 7)
    }

    private func intensity(for n: Int) -> Double {
        switch n {
        case 0: return 0.08
        case 1...2: return 0.3
        case 3...5: return 0.5
        case 6...9: return 0.72
        default: return 0.95
        }
    }
}

/// 「你的常听」榜单面板(系列 #7):种类(歌曲/专辑/歌手)×周期(近7天/近30天/近一年/全部)
/// 的 Top 10,数据/缓存/单飞全在 LastfmStatsService.refreshChart(15 分钟 TTL)。点条目
/// 经 iTunes Search 解析后用 music:// 跳 Apple Music(与「前往专辑/艺人」同一条管线)。
/// 玻璃容器样式由调用处(overlay 那块)统一给,跟简介面板一致。
private struct ChartsPanelView: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    @State private var kind: LastfmStatsService.ChartKind = .tracks
    @State private var period: LastfmStatsService.Period = .week

    /// content 区域曾经渲染到过的最大高度——用来防止"加载时窗口先缩小再突然变大"。
    ///
    /// 根因:面板整体靠外层 `.fixedSize(vertical: true)` 跟着 content 的天然高度走,而
    /// content 四态天差地别 —— 有数据时最多 10 行(~300+pt),loading/失败/无数据只是一个
    /// spinner 或一行灰字(~50pt 出头)。切 kind/period 会触发 refreshChart 重新进入 loading
    /// 那一档(哪怕只是一瞬间),面板跟着缩成 spinner 那么高,数据一到又弹回大尺寸 —— 就是
    /// 对拍想避免的"转圈时先缩小、突然变大"。
    ///
    /// 修法是"水位线":content 用 `.frame(minHeight:)` 兜住曾经量到过的最大高度,只会长
    /// 不会缩;下面 `growMinHeight` 量的是 minHeight 生效**之后**的高度(即
    /// max(旧水位,天然高度)),所以水位线只可能单调不减,不会因为"量到自己抬高后的高度"
    /// 而失控增长。
    ///
    /// 落 @AppStorage 而不是纯 @State:同一个道理也适用于**这个 App 启动后第一次**打开
    /// 这面板 —— 冷启动时水位线是 0,那一次没法靠"上一次量到的高度"兜。持久化把这个也
    /// 解决了,下次开 App 直接用上次退出前那个高度起步。key 不用 "np:" 前缀 —— 那是配置
    /// 导出白名单(见 SettingsView.offsetScope 同类注释),这是纯渲染测量值,换一台机器/
    /// 换一次系统字体设置就该失效,不该跟着配置搬家。
    @AppStorage("settings:chartsPanelMinHeight") private var contentMinHeight: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("你的常听"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            SettingsSegmentedControl(
                selection: $kind,
                options: LastfmStatsService.ChartKind.allCases,
                label: \.displayName
            )
            SettingsSegmentedControl(
                selection: $period,
                options: LastfmStatsService.Period.allCases,
                label: \.displayName
            )
            content
        }
        .padding(10)
        .onAppear { stats.refreshChart(kind: kind, period: period) }
        .onChange(of: kind) { _, k in stats.refreshChart(kind: k, period: period) }
        .onChange(of: period) { _, p in stats.refreshChart(kind: kind, period: p) }
    }

    /// 只在真的变高时才写 —— @AppStorage 写入即落 UserDefaults,同值重复写没有代价但也
    /// 没有必要,这里比较一下更干净。
    private func growMinHeight(_ h: CGFloat) {
        if h > contentMinHeight { contentMinHeight = h }
    }

    /// nil = 还没量到过任何高度(全新装机/从未打开过这面板),这时不设下限,跟原来行为
    /// 一样从小渲染起——没有"上一次"可参照,强行给个猜的数字不如不给。
    private var reservedMinHeight: CGFloat? { contentMinHeight > 0 ? contentMinHeight : nil }

    @ViewBuilder
    private var content: some View {
        Group {
            if let entries = stats.chart(kind, period), !entries.isEmpty {
                // .top:真有数据时,行数不足 10 行也让它们贴顶,空出来的地方留白在下面 ——
                // 这本身就是排行榜类 UI 的自然形态,比强行把几行字撑到垂直居中更像列表。
                VStack(spacing: 0) {
                    ForEach(entries.prefix(10)) { entry in
                        row(entry)
                    }
                }
                .frame(minHeight: reservedMinHeight, alignment: .top)
            } else if stats.chartLoading(kind, period) {
                // .center:这三档都是"内容缺席"的占位态,居中比贴顶更自然——不会看着像
                // 一个 spinner 孤零零钉在一大块空白的最上头。
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .frame(minHeight: reservedMinHeight, alignment: .center)
            } else if stats.chartFailed(kind, period) {
                Button(L10n.t("重试")) { stats.refreshChart(kind: kind, period: period) }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .frame(minHeight: reservedMinHeight, alignment: .center)
            } else {
                Text(L10n.t("暂无数据"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .frame(minHeight: reservedMinHeight, alignment: .center)
            }
        }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { growMinHeight(g.size.height) }
                    .onChange(of: g.size.height) { _, h in growMinHeight(h) }
            }
        )
    }

    private func row(_ entry: LastfmStatsService.ChartEntry) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 8) {
                Text("\(entry.rank)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(String(format: L10n.t("%@ 次"), "\(entry.playcount)"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("在 Apple Music 中打开"))
    }

    /// 与 openCatalogPage 同一条跳转管线:iTunes Search 解析 → music:// 原生跳页。
    private func open(_ entry: LastfmStatsService.ChartEntry) {
        let kind = kind
        Task.detached(priority: .userInitiated) {
            let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
            let title: String
            let artist: String
            switch kind {
            case .tracks, .albums:
                title = entry.name
                artist = entry.detail
            case .artists:
                // 传 artist 而不是 title:搜索 term 拼出来一样,但 pickBest 的"只歌手匹配"
                // 分支才会激活,优先挑该歌手演唱的歌再取 artistViewUrl —— 传 title 的话
                // 两个优选分支全死路、退化成拿第一条,恰好以歌手名为歌名的别人的歌会把
                // 跳转带偏(审阅)。
                title = ""
                artist = entry.name
            }
            guard let item = await MusicCatalogSearch.resolve(
                title: title, artist: artist, storefront: storefront) else { return }
            let https: String?
            switch kind {
            case .tracks: https = item.trackViewUrl
            case .albums: https = item.collectionViewUrl ?? item.trackViewUrl
            case .artists: https = item.artistViewUrl
            }
            guard let url = MusicCatalogSearch.musicSchemeURL(https) else { return }
            // Music.app 没在跑时先等它真正启动完,理由见 openCatalogPage 同一处注释。
            await MusicAutomationPermission.ensureMusicAppRunning()
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }
}
