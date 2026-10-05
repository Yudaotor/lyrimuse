import AppKit
import Combine
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "touchbar")

/// 触控栏歌词(默认关,设置 › 歌词显示 › 触控栏)。
///
/// 开着时功能栏里常驻一枚图标(菜单栏图标当前选的那一款),轻点展开成整条触控栏:封面、上一首 / 播放暂停 /
/// 下一首(旁边一颗设置键,打开设置里这一段)、这一句歌词,封面和三键各自摆在歌词哪一边听它们各自的「位置」(Core `TouchBarSlot.order`);广告期间封面那一格
/// 换成喇叭(`TouchBarLyricsCell.artworkTile`)。展开态是系统
/// 模态条,不管哪个 App 在前台都显示,左端的 ✕ 收回成图标;开了「展开时隐藏功能栏」时展开条占满整条触控栏,
/// 系统不给 ✕,左端换成 App 自己那颗样子相同的收起键。在设置里打开开关的那一下直接展开,App 启动时只放图标。
/// 系统入口见 `TouchBarPrivateAPI`。这台 Mac 此刻没有触控栏时(`TouchBarAvailability`)开关开着也不启用,
/// 触控栏出现 / 消失时跟着启停。
///
/// 歌词那一格就是悬浮歌词的图层行 `OverlayLyricScrollView`:逐字填色、跟唱滚动、按显示时长配速、尾部渐隐都是它的,
/// 这里只喂规格和时钟。显示哪一档由 Core `TouchBarLyricsContent` 定,规格怎么拼在 `TouchBarLyricsCell`(设置页那块
/// 预览也用它)。开了「副行」时这一格里叠两行(主行在上、副行在下,落点见 `TouchBarLyricsStyle` 的两行那一节),
/// 关着时只有主行、在 30pt 里垂直居中。触控栏看不见时(收着、没有触控栏的 Mac)只记状态,不画位图、不装动画,
/// 看得见了再补上。
///
/// 设置(同一段里):卡拉OK效果、跟随封面、字号、显示封面 / 播放控制(连同各自的位置)、对齐方式、副行、
/// 展开时隐藏功能栏,改了当场生效。
@MainActor
final class TouchBarLyricsController: NSObject, NSTouchBarDelegate {
    static let shared = TouchBarLyricsController()

    private enum Item {
        static let tray = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.tray")
        static let collapse = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.collapse")
        static let artwork = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.artwork")
        static let controls = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.controls")
        static let lyrics = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.lyrics")

        static func identifier(for slot: TouchBarSlot) -> NSTouchBarItem.Identifier {
            switch slot {
            case .collapse: return collapse
            case .artwork: return artwork
            case .controls: return controls
            case .lyrics: return lyrics
            }
        }
    }

    private var started = false
    private var enabled = false
    private var settingsObservers: [AnyCancellable] = []
    private var playbackObservers: [AnyCancellable] = []
    private var visibilityObservation: NSKeyValueObservation?
    private var refreshScheduled = false

    private let bar = NSTouchBar()
    private let trayItem = NSCustomTouchBarItem(identifier: Item.tray)
    private lazy var trayButton = NSButton(
        image: MenuBarIconStyle.cachedImage(for: AppSettings.shared.menuBarIconStyle),
        target: self, action: #selector(trayTapped))
    /// 隐藏功能栏时左端那颗收起键:系统这时不给 ✕,换成样子相同的这一颗,按下去收回成功能栏图标。
    private lazy var collapseButton: NSButton = {
        let button = NSButton(image: TouchBarLyricsCell.collapseImage(), target: self, action: #selector(collapseTapped))
        button.isBordered = false
        button.setAccessibilityLabel(L10n.t("收起"))
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let artworkView = NSImageView()
    /// 三键 + 一颗设置键,同一个分段控件:设置键跟着三键出没、跟着它的「位置」挪。
    private lazy var controls = NSSegmentedControl(
        images: [Self.controlImage(NSImage.touchBarSkipToStartTemplateName, label: L10n.t("上一首")),
                 Self.controlImage(NSImage.touchBarPlayTemplateName, label: L10n.t("播放/暂停")),
                 Self.controlImage(NSImage.touchBarSkipToEndTemplateName, label: L10n.t("下一首")),
                 Self.settingsImage()],
        trackingMode: .momentary, target: self, action: #selector(controlTapped(_:)))
    /// 歌词那一项的视图:主行、副行两个图层行叠在里面。
    private let lyricsContainer = NSView()
    private let lyricsView = OverlayLyricScrollView()
    private let secondaryView = OverlayLyricScrollView()
    /// 主行那一格的上缘和高:一行时占满整条高,两行时挪到上面那一格(`setRowLayout`)。
    private lazy var mainRowTop = lyricsView.topAnchor.constraint(equalTo: lyricsContainer.topAnchor)
    private lazy var mainRowHeight = lyricsView.heightAnchor.constraint(equalToConstant: TouchBarLyricsCell.barHeight)
    /// 「跟随封面」时歌词的颜色(`TouchBarLyricsCell.coverAccent(hex:)`);取不到封面主色时 nil,退回白色。
    private var coverAccent: NSColor?
    /// 展开态那三项,建一次留着(触控栏重新展开时会再问代理要)。
    private var items: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]
    private var playPauseImageName: NSImage.Name?
    /// 正在显示的那一档从哪一刻起显示。
    private var displayStart = TouchBarDisplayStart()

    private override init() {
        super.init()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Item.artwork, Item.controls, Item.lyrics]
        configureViews()
    }

    /// App 启动时调一次。开关开着、这台 Mac 也有触控栏,就把图标放进功能栏,不自动展开。
    func start() {
        guard !started else { return }
        started = true
        let settings = AppSettings.shared
        let availability = TouchBarAvailability.shared
        availability.start()
        setEnabled(settings.showLyricsInTouchBar && availability.isPresent, presentNow: false)
        // sink 里只用收到的值:@Published 在 willSet 时发布,这时回读发布方自己的属性还是旧值(另一个对象的照读)。
        settingsObservers = [
            // 用户拨开开关的那一下直接展开。
            settings.$showLyricsInTouchBar.dropFirst().removeDuplicates()
                .sink { [weak self] on in
                    self?.setEnabled(on && TouchBarAvailability.shared.isPresent, presentNow: on)
                },
            // 触控栏出现 / 消失(模拟器开关、系统重连触控栏):跟着启停,不自动展开。
            availability.$isPresent.dropFirst().removeDuplicates()
                .sink { [weak self] present in
                    self?.setEnabled(present && AppSettings.shared.showLyricsInTouchBar, presentNow: false)
                },
            settings.$menuBarIconStyle.dropFirst().removeDuplicates()
                .sink { [weak self] in self?.trayButton.image = MenuBarIconStyle.cachedImage(for: $0) },
            Publishers.CombineLatest(
                Publishers.CombineLatest4(settings.$touchBarShowsArtwork, settings.$touchBarArtworkSide,
                                          settings.$touchBarShowsControls, settings.$touchBarControlsSide),
                settings.$touchBarHidesControlStrip)
                // 隐藏功能栏只在系统入口在时才算数,不然左端会同时有系统的 ✕ 和这颗收起键。
                .map { items, hides in
                    TouchBarSlot.order(artworkSide: items.1, controlsSide: items.3,
                                       showsArtwork: items.0, showsControls: items.2,
                                       hidesControlStrip: hides && TouchBarPrivateAPI.supportsHidingControlStrip)
                }
                .removeDuplicates()
                .sink { [weak self] in self?.setItems($0) },
            // 展开着的时候切换「展开时隐藏功能栏」:按新的方式重新展开一次,当场生效。
            settings.$touchBarHidesControlStrip.dropFirst().removeDuplicates()
                .sink { [weak self] hides in self?.representIfVisible(hidingControlStrip: hides) },
            // 这几项在 refresh 里现读:攒到下一拍才读,那时已经是新值。
            settings.$touchBarLyricsFontSize.dropFirst().removeDuplicates()
                .sink { [weak self] _ in self?.scheduleRefresh() },
            settings.$touchBarLyricsKaraoke.dropFirst().removeDuplicates()
                .sink { [weak self] _ in self?.scheduleRefresh() },
            settings.$touchBarLyricsFollowsCover.dropFirst().removeDuplicates()
                .sink { [weak self] _ in self?.scheduleRefresh() },
            settings.$touchBarSecondaryLine.dropFirst().removeDuplicates()
                .sink { [weak self] _ in self?.scheduleRefresh() },
            settings.$touchBarLyricsAlignment.dropFirst().removeDuplicates()
                .sink { [weak self] _ in self?.scheduleRefresh() },
        ]
    }

    /// 展开态从左到右排哪几项。展开着的时候改了,系统当场重排;让出来的宽度歌词那一格自己填上。
    private func setItems(_ slots: [TouchBarSlot]) {
        bar.defaultItemIdentifiers = slots.map(Item.identifier(for:))
    }

    /// 一行 / 两行:主行那一格占满整条高(位图垂直居中),或者挪到上面那一格(`TouchBarLyricsStyle.twoRowMain*`)。
    /// 副行那一格位置不变,一行时藏着。
    private func setRowLayout(twoRows: Bool) {
        let top = twoRows ? CGFloat(TouchBarLyricsStyle.twoRowMainTop) : 0
        let height = twoRows ? CGFloat(TouchBarLyricsStyle.twoRowMainHeight) : TouchBarLyricsCell.barHeight
        if mainRowTop.constant != top { mainRowTop.constant = top }
        if mainRowHeight.constant != height { mainRowHeight.constant = height }
    }

    private func configureViews() {
        trayItem.view = trayButton
        trayButton.setAccessibilityLabel(L10n.t("触控栏歌词"))

        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = TouchBarLyricsCell.artworkCornerRadius
        artworkView.layer?.masksToBounds = true
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        for segment in 0..<controls.segmentCount {
            controls.setWidth(TouchBarLyricsCell.controlSegmentWidth, forSegment: segment)
        }

        lyricsContainer.translatesAutoresizingMaskIntoConstraints = false
        // 横向最不抗拉伸:填满前面几项之后剩下的宽度(见 `TouchBarLyricsCell.lyricsMinWidth`)。
        lyricsContainer.setContentHuggingPriority(.init(1), for: .horizontal)
        for row in [lyricsView, secondaryView] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.nowProvider = { PlaybackCoordinator.shared.lyricsTimelineMs() }
            lyricsContainer.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: lyricsContainer.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: lyricsContainer.trailingAnchor),
            ])
        }
        secondaryView.isHidden = true
        NSLayoutConstraint.activate([
            collapseButton.widthAnchor.constraint(equalToConstant: CGFloat(TouchBarLyricsStyle.collapseItemWidth)),
            collapseButton.heightAnchor.constraint(equalToConstant: TouchBarLyricsCell.barHeight),
            artworkView.widthAnchor.constraint(equalToConstant: TouchBarLyricsCell.barHeight),
            artworkView.heightAnchor.constraint(equalToConstant: TouchBarLyricsCell.barHeight),
            lyricsContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: TouchBarLyricsCell.lyricsMinWidth),
            lyricsContainer.heightAnchor.constraint(equalToConstant: TouchBarLyricsCell.barHeight),
            mainRowTop,
            mainRowHeight,
            secondaryView.topAnchor.constraint(equalTo: lyricsContainer.topAnchor,
                                               constant: CGFloat(TouchBarLyricsStyle.twoRowSecondaryTop)),
            secondaryView.heightAnchor.constraint(equalToConstant: CGFloat(TouchBarLyricsStyle.twoRowSecondaryHeight)),
        ])
        updateArtwork(TouchBarLyricsCell.placeholderArtwork)
        updatePlayPause(playing: false)
    }

    private func setEnabled(_ on: Bool, presentNow: Bool) {
        guard on != enabled else { return }
        guard !on || TouchBarPrivateAPI.isAvailable else {
            logger.error("[TouchBarLyricsController.setEnabled] system touch bar entry points unavailable, staying off")
            return
        }
        enabled = on
        if on {
            TouchBarPrivateAPI.showCloseBoxWhenFrontmost(true)
            TouchBarPrivateAPI.setInControlStrip(trayItem, true)
            observePlayback()
            visibilityObservation = bar.observe(\.isVisible, options: [.new]) { _, _ in
                DispatchQueue.main.async { TouchBarLyricsController.shared.visibilityChanged() }
            }
            refresh()
            if presentNow { presentLyrics(hidingControlStrip: AppSettings.shared.touchBarHidesControlStrip) }
        } else {
            visibilityObservation = nil
            playbackObservers = []
            TouchBarPrivateAPI.dismissSystemModal(bar)
            TouchBarPrivateAPI.setInControlStrip(trayItem, false)
            displayStart = TouchBarDisplayStart()
        }
        logger.notice("[TouchBarLyricsController.setEnabled] enabled=\(on) presentNow=\(presentNow)")
    }

    private func presentLyrics(hidingControlStrip: Bool) {
        TouchBarPrivateAPI.presentSystemModal(bar, trayIdentifier: Item.tray, hidingControlStrip: hidingControlStrip)
    }

    /// 「展开时隐藏功能栏」改了:展开着就先收起、再按新的方式展开;收着时什么都不用做,下次展开自然按新的来。
    private func representIfVisible(hidingControlStrip: Bool) {
        guard enabled, bar.isVisible else { return }
        TouchBarPrivateAPI.dismissSystemModal(bar)
        presentLyrics(hidingControlStrip: hidingControlStrip)
        logger.notice("[TouchBarLyricsController.representIfVisible] hidingControlStrip=\(hidingControlStrip)")
    }

    @objc private func trayTapped() {
        presentLyrics(hidingControlStrip: AppSettings.shared.touchBarHidesControlStrip)
    }

    @objc private func collapseTapped() {
        TouchBarPrivateAPI.minimizeSystemModal(bar)
    }

    /// 同悬浮歌词那排按钮:播放 / 暂停走乐观回声版,三个动作都先过「点了才校验权限」。第四格是设置键。
    @objc private func controlTapped(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: MenuBarStatusItem.withMusicPermission { MusicPlaybackController.previousTrack() }
        case 1: MenuBarStatusItem.withMusicPermission { PlaybackCoordinator.shared.userTogglePlayPause() }
        case 2: MenuBarStatusItem.withMusicPermission { MusicPlaybackController.nextTrack() }
        case 3: openTouchBarSettings()
        default: break
        }
    }

    /// 打开设置,翻到「歌词显示 › 触控栏」这一段(同灵动岛展开态的「设置…」:先把那一页停的分段写好,再叫窗口)。
    private func openTouchBarSettings() {
        UserDefaults.standard.set(SettingsSearchCatalog.touchBarSectionValue,
                                  forKey: LyricsSurface.appearanceSectionStorageKey)
        AppActions.shared.requestSettings(.tab(.appearance))
        AppActions.shared.openSettings?()
    }

    private func visibilityChanged() {
        guard enabled else { return }
        let visible = bar.isVisible
        logger.notice("[TouchBarLyricsController.visibilityChanged] visible=\(visible)")
        guard visible else { return }
        displayStart.restartIfNotLyric(nowMs: PlaybackCoordinator.shared.lyricsTimelineMs())
        refresh()
    }

    // MARK: - 跟播放状态

    private func observePlayback() {
        let p = PlaybackCoordinator.shared
        playbackObservers = [
            Publishers.MergeMany(TouchBarLyricsCell.playbackChanges(p)).sink { [weak self] in self?.scheduleRefresh() },
            Publishers.CombineLatest(LocalPlaybackSource.shared.$artworkAverageHex, p.$highResAverageHex)
                .map { system, highRes in TouchBarLyricsCell.coverAccent(hex: highRes ?? system) }
                .removeDuplicates()
                .sink { [weak self] in
                    self?.coverAccent = $0
                    self?.scheduleRefresh()
                },
        ]
    }

    /// 一次换行会同时惊动好几条订阅,攒到下一拍只算一次;到那时 @Published 的属性也都已经是新值。
    private func scheduleRefresh() {
        guard enabled, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard enabled else { return }
        let p = PlaybackCoordinator.shared
        let settings = AppSettings.shared
        let secondary = settings.touchBarSecondaryLine
        updatePlayPause(playing: p.isPlayingNow)
        setRowLayout(twoRows: secondary.showsSecondaryRow)
        let content = TouchBarLyricsCell.content(p, secondary: secondary)
        updateArtwork(TouchBarLyricsCell.artworkTile(p, content: content))
        let nowMs = p.lyricsTimelineMs()
        displayStart.update(content: content, lineIndex: p.currentLineIndex, nowMs: nowMs)
        guard bar.isVisible else { return }
        let inputs = TouchBarLyricsCell.Inputs(
            startMs: displayStart.sinceMs, dwellMs: TouchBarLyricsCell.dwellMs(p, secondary: secondary),
            isPlaying: p.isPlayingNow,
            timingEpoch: LyricsTimingEpoch.of(anchor: p.anchor, pausedPositionMs: p.pausedPositionMs,
                                              offsetMs: p.currentLyricsOffsetMs),
            rate: p.anchor?.rate ?? 1,
            font: TouchBarLyricsCell.mainFont(fontSize: settings.touchBarLyricsFontSize, secondary: secondary),
            color: TouchBarLyricsCell.lyricColor(followsCover: settings.touchBarLyricsFollowsCover,
                                                 coverAccent: coverAccent),
            karaoke: settings.touchBarLyricsKaraoke,
            alignment: settings.touchBarLyricsAlignment)
        guard let spec = TouchBarLyricsCell.spec(for: content, inputs) else {
            lyricsView.isHidden = true
            secondaryView.isHidden = true
            return
        }
        lyricsView.isHidden = false
        lyricsView.apply(spec: spec, nowMs: nowMs)
        // 副行这一刻没字时那一行藏起来,主行不挪位置。
        guard let row = TouchBarLyricsCell.secondarySpec(for: content, kind: secondary, nextLineText: p.nextLineText,
                                                         nextLineSide: p.nextLineSide, inputs) else {
            secondaryView.isHidden = true
            return
        }
        secondaryView.isHidden = false
        secondaryView.apply(spec: row, nowMs: nowMs)
    }

    private func updatePlayPause(playing: Bool) {
        let name = playing ? NSImage.touchBarPauseTemplateName : NSImage.touchBarPlayTemplateName
        guard name != playPauseImageName else { return }
        playPauseImageName = name
        controls.setImage(Self.controlImage(name, label: L10n.t("播放/暂停")), forSegment: 1)
    }

    private func updateArtwork(_ image: NSImage) {
        guard artworkView.image !== image else { return }
        artworkView.image = image
    }

    /// 三键的图标带上无障碍描述(旁白读它,触控栏不显示 tooltip)。系统图是进程内共享的实例,拷一份再改。
    private static func controlImage(_ name: NSImage.Name, label: String) -> NSImage {
        let image = (NSImage(named: name)?.copy() as? NSImage) ?? NSImage()
        image.accessibilityDescription = label
        return image
    }

    /// 设置键的图标:系统没有触控栏专用的齿轮模板图,用 SF Symbol,字号照三键的图标大小。
    private static func settingsImage() -> NSImage {
        let symbol = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.t("设置…"))
        return symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
            ?? symbol ?? NSImage()
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if let cached = items[identifier] { return cached }
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case Item.collapse:
            item.view = collapseButton
        case Item.artwork:
            item.view = artworkView
            item.visibilityPriority = .low
        case Item.controls:
            item.view = controls
        case Item.lyrics:
            item.view = lyricsContainer
            item.visibilityPriority = .high
        default:
            return nil
        }
        items[identifier] = item
        return item
    }
}
