import AppKit
import Combine
import LyrimuseCore

/// 触控栏「更多」那一页的几项(Core `TouchBarMorePage`):返回、播放进度、歌词校准、喜欢、随机、循环、音量。放哪几项、每项的状态
/// 都跟灵动岛展开区读同一份播放状态(`PlaybackCoordinator`),动作也走同一组入口。换页由 `TouchBarLyricsController`
/// 管,这里只建键、刷新状态,有操作时叫 `onInteraction`(重新计「没有操作多久回到歌词」),这一页显示着、放哪几项
/// 变了时叫 `onItemsChanged`(控制器重排这一页)。
///
/// 每颗键定宽 `TouchBarMorePage.keyWidth`、滑杆能缩,进度和音量的显示优先级最低:不占满整条时放不下,系统先藏这两条,
/// 不藏一按就生效的键(17 章决策 48)。
@MainActor
final class TouchBarMorePageBar {
    private enum ID {
        static let back = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.more.back")
        static let progress = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.more.progress")
        static let offset = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.more.offset")
        static let favorite = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.more.favorite")
        static let shuffle = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.more.shuffle")
        static let `repeat` = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.more.repeat")
        static let volume = NSTouchBarItem.Identifier("me.yudaotor.lyrimuse.touchbar.more.volume")
    }

    var onInteraction: () -> Void = {}
    var onBack: () -> Void = {}
    var onItemsChanged: () -> Void = {}

    private var cache: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]
    /// 这一页此刻排着的几项(`identifiers()` 记下),状态变了跟它比,不一样才重排。
    private var shown: [TouchBarMorePage.Item] = []
    /// 这一页此刻显示着没有(`setActive`):没显示时状态变了不重排、不跟进度。
    private var active = false
    /// 用户最近一次拖音量的时刻:拖着的时候不拿回读的值去盖滑杆。
    private var lastVolumeDrag: Date = .distantPast
    /// 进度:这一页显示着时每 `progressTickSeconds` 跟一次播放位置;拖着的时候(和松手后一小会儿)不去盖滑杆,
    /// 松手 `seekSettleSeconds` 之后才发一次跳转(拖动时滑杆连着报值,每一下都跳会连发几十条指令)。
    private var progressTimer: Timer?
    private var lastProgressDrag: Date = .distantPast
    private var pendingSeek: DispatchWorkItem?
    private static let progressTickSeconds: TimeInterval = 0.5
    private static let seekSettleSeconds: TimeInterval = 0.3
    private lazy var progressItem: NSSliderTouchBarItem = {
        let item = NSSliderTouchBarItem(identifier: ID.progress)
        item.slider.minValue = 0
        item.slider.maxValue = 1
        item.target = self
        item.action = #selector(progressChanged(_:))
        item.minimumSliderWidth = CGFloat(TouchBarMorePage.progressMinWidth)
        item.maximumSliderWidth = 260
        item.visibilityPriority = .low
        item.customizationLabel = L10n.t("播放进度")
        item.slider.setAccessibilityLabel(L10n.t("播放进度"))
        return item
    }()

    private lazy var offsetLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: CGFloat(TouchBarMorePage.offsetReadoutWidth)).isActive = true
        return label
    }()
    private lazy var favoriteButton = Self.button(symbol: "heart", label: L10n.t("喜欢"), target: self,
                                                  action: #selector(favoriteTapped))
    private lazy var shuffleButton = Self.button(symbol: "shuffle", label: L10n.t("随机播放"), target: self,
                                                 action: #selector(shuffleTapped))
    private lazy var repeatButton = Self.button(symbol: "repeat", label: L10n.t("循环播放"), target: self,
                                                action: #selector(repeatTapped))
    private lazy var volumeItem: NSSliderTouchBarItem = {
        let item = NSSliderTouchBarItem(identifier: ID.volume)
        item.slider.minValue = 0
        item.slider.maxValue = 100
        item.target = self
        item.action = #selector(volumeChanged(_:))
        item.minimumSliderWidth = CGFloat(TouchBarMorePage.volumeMinWidth)
        item.maximumSliderWidth = 200
        item.visibilityPriority = .low
        if let low = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil) {
            item.minimumValueAccessory = NSSliderAccessory(image: low)
        }
        if let high = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil) {
            item.maximumValueAccessory = NSSliderAccessory(image: high)
        }
        item.customizationLabel = L10n.t("音量")
        item.slider.setAccessibilityLabel(L10n.t("音量"))
        return item
    }()

    /// 此刻这一页该放哪几项,并记下来。
    func identifiers() -> [NSTouchBarItem.Identifier] {
        shown = currentItems()
        return shown.map(Self.identifier(for:))
    }

    private func currentItems() -> [TouchBarMorePage.Item] {
        let p = PlaybackCoordinator.shared
        return TouchBarMorePage.items(hasDuration: (p.currentDurationMs ?? 0) > 0,
                                      isAdBreak: p.isCurrentTrackAdBreak,
                                      supportsFavorite: p.isFavorited != nil,
                                      canShuffle: p.playbackModeOptions.contains(.shuffle),
                                      canRepeat: p.playbackModeOptions.canRepeat,
                                      supportsVolume: p.soundVolume != nil)
    }

    private static func identifier(for item: TouchBarMorePage.Item) -> NSTouchBarItem.Identifier {
        switch item {
        case .back: return ID.back
        case .progress: return ID.progress
        case .offset: return ID.offset
        case .favorite: return ID.favorite
        case .shuffle: return ID.shuffle
        case .repeat: return ID.repeat
        case .volume: return ID.volume
        }
    }

    /// 喜欢、播放模式、音量、这首的偏移一变就刷新这一页;放哪几项变了交给控制器重排。`receive(on:)` 推到下一拍再读:
    /// @Published 在 willSet 时发布,当场回读还是旧值。
    func observations() -> [AnyCancellable] {
        let p = PlaybackCoordinator.shared
        return [
            Publishers.MergeMany(TouchBarLyricsCell.signal(p.$isFavorited), TouchBarLyricsCell.signal(p.$playbackMode),
                                 TouchBarLyricsCell.signal(p.$playbackModeOptions), TouchBarLyricsCell.signal(p.$soundVolume),
                                 TouchBarLyricsCell.signal(p.$trackLyricsOffsetMs),
                                 TouchBarLyricsCell.signal(p.$currentDurationMs),
                                 TouchBarLyricsCell.signal(p.$isCurrentTrackAdBreak))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.stateChanged() },
        ]
    }

    private func stateChanged() {
        guard active else { return }
        refreshStates()
        if currentItems() != shown { onItemsChanged() }
    }

    /// 各项的样子跟着此刻的状态:偏移读数、心是不是实心、随机 / 循环亮没亮、音量。
    func refreshStates() {
        let p = PlaybackCoordinator.shared
        offsetLabel.stringValue = "\(L10n.t("歌词")) \(AppSettings.signedSeconds(ms: p.trackLyricsOffsetMs))s"
        let favorited = p.isFavorited == true
        favoriteButton.image = Self.symbol(favorited ? "heart.fill" : "heart")
        favoriteButton.setAccessibilityLabel(favorited ? L10n.t("取消喜欢") : L10n.t("喜欢"))
        let mode = p.playbackMode ?? .list
        Self.setActive(shuffleButton, mode == .shuffle)
        Self.setActive(repeatButton, mode == .repeatOne || mode == .repeatAll)
        repeatButton.image = Self.symbol(mode == .repeatOne ? "repeat.1" : "repeat")
        if let volume = p.soundVolume, Date().timeIntervalSince(lastVolumeDrag) > 1.5 {
            volumeItem.slider.doubleValue = Double(volume)
        }
        refreshProgress()
    }

    /// 这一页显示着就每 `progressTickSeconds` 跟一次播放位置,离开就停。
    func setActive(_ active: Bool) {
        self.active = active
        progressTimer?.invalidate()
        progressTimer = nil
        guard active else { return }
        refreshProgress()
        let timer = Timer(timeInterval: Self.progressTickSeconds, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refreshProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    /// 进度滑杆跟着播放位置(锚点外推 ?? 暂停冻结的位置,不叠歌词偏移,同灵动岛的进度条);播放器不接受跳转时只显示、
    /// 不能拖(`PlaybackCoordinator.acceptsSeek`)。
    private func refreshProgress() {
        let p = PlaybackCoordinator.shared
        progressItem.slider.isEnabled = p.acceptsSeek
        guard let duration = p.currentDurationMs, duration > 0,
              Date().timeIntervalSince(lastProgressDrag) > 1.5 else { return }
        let position = p.anchor?.extrapolatedPositionMs(now: Date()) ?? p.pausedPositionMs ?? 0
        progressItem.slider.doubleValue = min(1, max(0, Double(position) / Double(duration)))
    }

    func makeItem(for identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if let cached = cache[identifier] { return cached }
        let item: NSTouchBarItem
        switch identifier {
        case ID.back:
            let custom = NSCustomTouchBarItem(identifier: identifier)
            let image = (NSImage(named: NSImage.touchBarGoBackTemplateName)?.copy() as? NSImage) ?? NSImage()
            let button = NSButton(image: image, target: self, action: #selector(backTapped))
            button.setAccessibilityLabel(L10n.t("返回"))
            Self.fixWidth(button)
            custom.view = button
            custom.visibilityPriority = .high
            item = custom
        case ID.progress:
            item = progressItem
        case ID.offset:
            let custom = NSCustomTouchBarItem(identifier: identifier)
            let minus = Self.button(symbol: "minus", label: L10n.t("延后"), target: self, action: #selector(delayTapped))
            let plus = Self.button(symbol: "plus", label: L10n.t("提前"), target: self, action: #selector(advanceTapped))
            let stack = NSStackView(views: [minus, offsetLabel, plus])
            stack.spacing = 4
            custom.view = stack
            item = custom
        case ID.favorite:
            let custom = NSCustomTouchBarItem(identifier: identifier)
            custom.view = favoriteButton
            item = custom
        case ID.shuffle:
            let custom = NSCustomTouchBarItem(identifier: identifier)
            custom.view = shuffleButton
            item = custom
        case ID.repeat:
            let custom = NSCustomTouchBarItem(identifier: identifier)
            custom.view = repeatButton
            item = custom
        case ID.volume:
            item = volumeItem
        default:
            return nil
        }
        cache[identifier] = item
        return item
    }

    // MARK: - 动作(同灵动岛展开区那几颗键)

    @objc private func backTapped() {
        onBack()
    }

    @objc private func delayTapped() {
        _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: -AppSettings.shared.lyricsOffsetStepMs)
        onInteraction()
    }

    @objc private func advanceTapped() {
        _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: AppSettings.shared.lyricsOffsetStepMs)
        onInteraction()
    }

    @objc private func favoriteTapped() {
        PlaybackCoordinator.shared.toggleFavorited()
        onInteraction()
    }

    /// 随机:点亮 = shuffle,再点回列表;跟循环键互斥(同灵动岛 `shuffleButton`)。
    @objc private func shuffleTapped() {
        let mode = PlaybackCoordinator.shared.playbackMode ?? .list
        PlaybackCoordinator.shared.setPlaybackMode(mode == .shuffle ? .list : .shuffle)
        onInteraction()
    }

    /// 循环:关 → 列表循环 → 单曲循环 → 关,播放器够不到的那一档跳过(同灵动岛 `repeatButton`)。
    @objc private func repeatTapped() {
        let p = PlaybackCoordinator.shared
        let mode = p.playbackMode ?? .list
        p.setPlaybackMode(mode.nextRepeat(allowsRepeatOne: p.playbackModeOptions.contains(.repeatOne),
                                          allowsRepeatAll: p.playbackModeOptions.contains(.repeatAll)))
        onInteraction()
    }

    @objc private func progressChanged(_ sender: NSSliderTouchBarItem) {
        lastProgressDrag = Date()
        onInteraction()
        guard let duration = PlaybackCoordinator.shared.currentDurationMs, duration > 0 else { return }
        let target = Int(sender.slider.doubleValue * Double(duration))
        pendingSeek?.cancel()
        let work = DispatchWorkItem { PlaybackCoordinator.shared.seek(toMs: target) }
        pendingSeek = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seekSettleSeconds, execute: work)
    }

    @objc private func volumeChanged(_ sender: NSSliderTouchBarItem) {
        lastVolumeDrag = Date()
        PlaybackCoordinator.shared.setVolume(Int(sender.slider.doubleValue.rounded()))
        onInteraction()
    }

    // MARK: - 样子

    private static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
            ?? image ?? NSImage()
    }

    private static func button(symbol name: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: symbol(name), target: target, action: action)
        button.setAccessibilityLabel(label)
        fixWidth(button)
        return button
    }

    private static func fixWidth(_ button: NSButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: CGFloat(TouchBarMorePage.keyWidth)).isActive = true
    }

    /// 随机 / 循环点亮时键底换成强调色,熄灭时用触控栏默认的灰底。
    private static func setActive(_ button: NSButton, _ active: Bool) {
        button.bezelColor = active ? .controlAccentColor : nil
        button.setAccessibilitySelected(active)
    }
}
