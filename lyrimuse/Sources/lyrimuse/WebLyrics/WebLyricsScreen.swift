import AppKit
import Combine
import CoreVideo
import LyrimuseCore
import Metal
import QuartzCore
import SwiftUI
import VideoToolbox

/// 副屏画面的分发:同一尺寸的网页共用一个渲染器,最后一个网页断开就停掉那个渲染器。见 19 章。
@MainActor
final class WebLyricsScreenHub {
    /// 同时最多画几种尺寸;再来新尺寸的网页就共用最早那一个(画面按比例缩放显示)。
    static let maxRenderers = 3

    private var renderers: [WebLyricsViewport: WebLyricsScreenRenderer] = [:]
    private var order: [WebLyricsViewport] = []
    private var viewers: [ObjectIdentifier: (connection: WebLyricsConnection, viewport: WebLyricsViewport)] = [:]

    func add(_ connection: WebLyricsConnection, viewport requested: WebLyricsViewport) {
        var viewport = requested
        if renderers[viewport] == nil {
            if renderers.count >= Self.maxRenderers, let first = order.first {
                viewport = first
            } else {
                let renderer = WebLyricsScreenRenderer(viewport: viewport)
                renderer.onFrame = { [weak self] jpeg in self?.broadcast(jpeg, for: viewport) }
                renderers[viewport] = renderer
                order.append(viewport)
                renderer.start()
            }
        }
        viewers[ObjectIdentifier(connection)] = (connection, viewport)
        renderers[viewport]?.requestFrame()
    }

    func remove(_ connection: WebLyricsConnection) {
        guard let entry = viewers.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        guard !viewers.values.contains(where: { $0.viewport == entry.viewport }) else { return }
        renderers.removeValue(forKey: entry.viewport)?.stop()
        order.removeAll { $0 == entry.viewport }
    }

    /// 网页发回来的点按。别的设备要「允许局域网设备控制播放」开着才算数。
    func tap(_ connection: WebLyricsConnection, payload: Data) {
        guard let entry = viewers[ObjectIdentifier(connection)], let point = WebLyricsTap.parse(payload),
              WebLyricsTap.permits(remoteIsLoopback: connection.isLoopback,
                                   lanControlEnabled: AppSettings.shared.webLyricsAllowLANControl) else { return }
        renderers[entry.viewport]?.handleTap(point)
    }

    private func broadcast(_ jpeg: Data, for viewport: WebLyricsViewport) {
        for entry in viewers.values where entry.viewport == viewport { entry.connection.sendFrame(jpeg) }
    }
}

/// 离屏画一份歌词窗口(完整布局)、编成 JPEG 推给副屏。网页点画面时按位置判点中哪颗播放控制、哪一句歌词,
/// 照歌词窗口同一个动作执行。
///
/// 背景(`BackdropNSView`)和歌词列表(`LyricsLayerListView`)是歌词窗口用的同一份组件,数据来自同一个
/// 窄订阅代理(`WindowPlayback`);左栏的封面卡、歌名、进度在歌词窗口里是 SwiftUI,离屏画不了,这里用图层
/// 照同样的尺寸重搭(`WebLyricsPlayerPane`)。三块组件不挂窗口,每帧用 `DetachedLayerTree` 拼树,交给
/// `CARenderer` 直接画进 IOSurface 像素缓冲,GPU 画完后交给 VideoToolbox 编 JPEG,不经过 CPU 读回。
/// 像素缓冲轮着用三块:画下一帧时前两帧可以还在编码,主线程不等 GPU 也不等编码器。
///
/// 毛玻璃背景折射的是窗口背后的桌面,副屏上没有对应物,按「跟随封面」画。停播时歌词窗口是停播页,这里只画
/// 「未在播放」的空状态。见 19 章决策 2。
@MainActor
final class WebLyricsScreenRenderer {
    let viewport: WebLyricsViewport
    var onFrame: ((Data) -> Void)?

    /// 在播时 60 帧,暂停或停播时 5 帧:逐字填色、换句滚动和背景光斑都只在播放时动。状态刚变的那一小段
    /// (暂停时封面缩小、换歌时封面淡入)照样按在播算,不然过渡动画只剩几帧。
    private static let fastInterval: TimeInterval = 1.0 / 60
    /// 画一帧在主线程上平均超过 9ms 就降到 30 帧、回到 6ms 以下再升回 60 帧,不让副屏把 App 自己的界面拖卡。
    private static let reducedInterval: TimeInterval = 1.0 / 30
    private static let reduceAbove: CFTimeInterval = 0.009
    private static let restoreBelow: CFTimeInterval = 0.006
    private static let idleInterval: TimeInterval = 1.0 / 5
    private static let transitionHold: CFTimeInterval = 1.2
    /// 同时在 GPU 或编码器里的帧数上限;像素缓冲比它多一块,正在画的那块不会是正在编的。
    private static let maxFramesInFlight = 2
    private static let jpegQuality = 0.75
    /// 左栏整组垂直居中后再往上挪的量,同歌词窗口(`fullBody` 里 `-safeAreaInsets.top / 2 - 2`,顶部 inset 约 28pt)。
    private static let paneVerticalOffset: CGFloat = 16

    private let playback = WindowPlayback()
    private var subs: [AnyCancellable] = []
    private var dirty = true

    private let container = CALayer()
    private let wrapper = CALayer()
    private let fillLayer = CAGradientLayer()
    private let backdrop: BackdropNSView
    private let dimLayer = CALayer()
    private let pane = WebLyricsPlayerPane()
    private let list: LyricsLayerListView
    private let emptyState = WebLyricsEmptyStateLayer()
    private var fastUntil: CFTimeInterval = 0
    private var timerInterval: TimeInterval = 0
    /// 主线程上画一帧的耗时,指数平均。
    private var frameCost: CFTimeInterval = 0
    private var reduced = false

    private let device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var renderer: CARenderer?
    private var slots: [(buffer: CVPixelBuffer, texture: CVMetalTexture)] = []
    private var nextSlot = 0
    private var textureCache: CVMetalTextureCache?
    private var session: VTCompressionSession?
    private var framesInFlight = 0
    private var timer: Timer?

    init(viewport: WebLyricsViewport) {
        self.viewport = viewport
        let bounds = CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
        backdrop = BackdropNSView(frame: bounds)
        list = LyricsLayerListView(frame: .zero)
        list.rendersDetached = true
        device = MTLCreateSystemDefaultDevice()

        wrapper.anchorPoint = .zero
        wrapper.bounds = bounds
        wrapper.masksToBounds = true
        // Metal 纹理的原点在左下:整幅上下翻一次,出来的画面才是正的。别改成给图层设 isGeometryFlipped,
        // 那样布局翻过来了、字形却是倒的。
        // 像素尺寸取过偶数,按它反算两向倍数,画面正好铺满、边上不留黑线。
        wrapper.position = CGPoint(x: 0, y: viewport.pixelHeight)
        wrapper.transform = CATransform3DMakeScale(CGFloat(viewport.pixelWidth) / CGFloat(viewport.width),
                                                   -CGFloat(viewport.pixelHeight) / CGFloat(viewport.height), 1)
        container.frame = CGRect(x: 0, y: 0, width: viewport.pixelWidth, height: viewport.pixelHeight)
        container.backgroundColor = NSColor.black.cgColor
        container.addSublayer(wrapper)

        fillLayer.frame = bounds
        dimLayer.frame = bounds
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        wrapper.addSublayer(fillLayer)
        if let l = backdrop.layer {
            l.masksToBounds = true
            wrapper.addSublayer(l)
        }
        wrapper.addSublayer(dimLayer)
        wrapper.addSublayer(pane)
        if let l = list.layer { wrapper.addSublayer(l) }
        wrapper.addSublayer(emptyState)
        for layer in [wrapper, fillLayer, dimLayer, pane, emptyState] as [CALayer] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(),
                             "colors": NSNull(), "backgroundColor": NSNull()]
        }
        list.nowProvider = { PlaybackCoordinator.shared.lyricsTimelineMs() }
        layoutComponents()

        subs = [
            playback.objectWillChange.sink { [weak self] _ in self?.dirty = true },
            NSApp.publisher(for: \.effectiveAppearance).sink { [weak self] _ in self?.dirty = true },
        ]
    }

    func start() {
        setUpRendering()
        scheduleTimer(interval: Self.fastInterval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        subs = []
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        renderer = nil
    }

    /// 新网页连上来时立刻出一帧,不等下一拍。
    func requestFrame() {
        dirty = true
        tick()
    }

    /// 网页点了画面上的这一点(相对位置,左上为原点):左栏的播放控制照歌词窗口那几颗键执行,歌词行跳到那一句。
    func handleTap(_ unit: CGPoint) {
        let p = CGPoint(x: unit.x * width, y: unit.y * height)
        if !pane.isHidden, pane.frame.contains(p),
           let button = pane.button(at: CGPoint(x: p.x - pane.frame.minX, y: p.y - pane.frame.minY)) {
            guard perform(button) else { return }
            pane.press(button)
        } else if !list.isHidden, list.frame.contains(p),
                  let index = list.lineIndex(at: NSPoint(x: p.x - list.frame.minX, y: p.y - list.frame.minY)),
                  playback.allLines.indices.contains(index) {
            // 减去当前歌词偏移,同歌词窗口的 onTapLine
            PlaybackCoordinator.shared.seek(
                toMs: max(0, playback.allLines[index].timeMs - PlaybackCoordinator.shared.currentLyricsOffsetMs))
        } else {
            return
        }
        dirty = true
        tick()
    }

    /// 执行了返回 true。播放控制被拦下时上一首 / 播放 / 下一首不执行;随机、循环只在画出来时能点。
    private func perform(_ button: WebLyricsControlsLayout.Button) -> Bool {
        let mode = playback.playbackMode
        let options = playback.playbackModeOptions
        switch button {
        case .previous, .playPause, .next:
            guard playback.controlsWithheldReason == nil else { return false }
            switch button {
            case .previous: MusicPlaybackController.previousTrack()
            case .next: MusicPlaybackController.nextTrack()
            default: PlaybackCoordinator.shared.userTogglePlayPause()
            }
        case .shuffle:
            guard mode != nil, options.contains(.shuffle) else { return false }
            PlaybackCoordinator.shared.setPlaybackMode(mode == .shuffle ? .list : .shuffle)
        case .repeatMode:
            guard mode != nil, options.canRepeat else { return false }
            PlaybackCoordinator.shared.setPlaybackMode(
                (mode ?? .list).nextRepeat(allowsRepeatOne: options.contains(.repeatOne),
                                           allowsRepeatAll: options.contains(.repeatAll)))
        }
        return true
    }

    // MARK: - 布局

    private var width: CGFloat { CGFloat(viewport.width) }
    private var height: CGFloat { CGFloat(viewport.height) }
    private var coverWidth: CGFloat { min(width * 0.279, 460) }
    private var listX: CGFloat { viewport.showsPlayerPane ? width * 0.111 + coverWidth : 0 }
    private var listLeading: CGFloat {
        viewport.showsPlayerPane ? max(24, width * 0.515 - (width * 0.111 + coverWidth)) : 44
    }
    private var listTrailing: CGFloat { max(32, width * 0.06) }
    private var fontSize: CGFloat {
        LyricsWindowTypography.listFontSize(columnWidth: width - listX, viewportHeight: height)
    }

    private func layoutComponents() {
        list.frame = CGRect(x: listX, y: 0, width: width - listX, height: height)
        pane.frame = CGRect(x: width * 0.111, y: 0, width: coverWidth, height: height)
        emptyState.frame = CGRect(x: listX, y: 0, width: width - listX, height: height)
    }

    // MARK: - 每一拍

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timerInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if dirty {
            dirty = false
            syncModel()
            fastUntil = now + Self.transitionHold
        }
        if frameCost > Self.reduceAbove { reduced = true } else if frameCost < Self.restoreBelow { reduced = false }
        let active = reduced ? Self.reducedInterval : Self.fastInterval
        let interval = playback.isPlayingNow || now < fastUntil ? active : Self.idleInterval
        if interval != timerInterval, timer != nil { scheduleTimer(interval: interval) }
        pane.updateProgress(positionMs: currentPositionMs(), durationMs: currentDurationMs())
        if renderFrame() {
            let cost = CACurrentMediaTime() - now
            frameCost = frameCost == 0 ? cost : frameCost * 0.9 + cost * 0.1
        }
    }

    private var isIdle: Bool { playback.title.isEmpty }

    private var lyricsOnHold: Bool { playback.isRadioTalkBreak || playback.isCurrentTrackAdBreak }

    private var effectiveBackgroundMode: LyricsWindowBackgroundMode {
        playback.backgroundMode == .glass ? .artwork : playback.backgroundMode
    }

    private var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 同歌词窗口的 `hasArtworkBackground`:这一刻背景是不是暗的。纯色 / 渐变背后没有桌面,按黑底算。
    private var hasArtworkBackground: Bool {
        switch effectiveBackgroundMode {
        case .artwork, .glass:
            return playback.artworkData != nil || playback.highResArtworkImage != nil || playback.windowBackgroundLayers != nil
        case .solid:
            return LyricsWindowBackgroundLuma.prefersLightText(hexes: [playback.backgroundColorHex],
                                                               darkAppearance: isDarkAppearance, backdropLuma: 0)
        case .gradient:
            return LyricsWindowBackgroundLuma.prefersLightText(hexes: [playback.backgroundColorHex, playback.backgroundColorEndHex],
                                                               darkAppearance: isDarkAppearance, backdropLuma: 0)
        }
    }

    private func resolved(_ color: Color) -> NSColor {
        var out = NSColor(color)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { out = NSColor(color).usingColorSpace(.sRGB) ?? out }
        return out
    }

    private func syncModel() {
        let onArtwork = hasArtworkBackground
        let tone = playback.textColorMode.tone(hasArtworkBackground: onArtwork)
        let text: NSColor
        let secondary: NSColor
        switch tone {
        case .white:
            text = .white
            secondary = NSColor.white.withAlphaComponent(0.73)
        case .systemPrimary:
            text = resolved(.primary)
            secondary = resolved(.secondary)
        case .dark:
            text = NSColor.black.withAlphaComponent(0.85)
            secondary = NSColor.black.withAlphaComponent(0.5)
        case .custom:
            text = resolved(playback.textColor)
            secondary = text.withAlphaComponent(text.alphaComponent * 0.73)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyBackground(onArtwork: onArtwork)

        let state = LyricsWindowEmptyState.resolve(.init(
            hasTitle: !isIdle, isAdBreak: playback.isCurrentTrackAdBreak, isRadioTalkBreak: playback.isRadioTalkBreak,
            isInstrumental: playback.isCurrentTrackInstrumental, hasNoLyrics: playback.currentTrackHasNoLyrics,
            engineNetworkDown: playback.engineNetworkDown, hasLyricsContent: playback.hasLyricsContent,
            isPlaying: playback.isPlayingNow))
        let showsList = !isIdle && !lyricsOnHold && !playback.allLines.isEmpty
        list.isHidden = !showsList
        emptyState.isHidden = showsList
        if !showsList {
            emptyState.frame = isIdle ? CGRect(x: 0, y: 0, width: width, height: height)
                : CGRect(x: listX, y: 0, width: width - listX, height: height)
            emptyState.show(icon: state.icon, text: Self.emptyText(state), onArtwork: onArtwork,
                            color: onArtwork ? NSColor.white.withAlphaComponent(0.75) : secondary)
        }
        pane.isHidden = isIdle || !viewport.showsPlayerPane
        if !pane.isHidden {
            pane.apply(.init(
                artwork: (playback.highResArtworkImage ?? playback.artworkImage)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                title: playback.isCurrentTrackAdBreak ? L10n.t("广告中") : playback.displayTitle,
                artistAlbum: playback.isCurrentTrackAdBreak ? "" : Self.artistAlbum(playback.displayArtist, playback.displayAlbum),
                primary: onArtwork ? .white : resolved(.primary),
                secondary: onArtwork ? resolved(amVibrantColor(layers: playback.windowBackgroundLayers, satScale: 0.5, satCap: 0.45,
                                                               brightness: 0.85, fallback: .white.opacity(0.6),
                                                               minContrastToBackground: 0.25)) : resolved(.secondary),
                timeColor: onArtwork ? resolved(amVibrantColor(layers: playback.windowBackgroundLayers, satScale: 0.62, satCap: 0.5,
                                                               brightness: 0.68, fallback: .white.opacity(0.6),
                                                               minContrastToBackground: 0.25)) : resolved(.secondary),
                barFill: onArtwork ? resolved(amVibrantColor(layers: playback.windowBackgroundLayers, satScale: 0.5, satCap: 0.4,
                                                             brightness: 0.92, fallback: .white.opacity(0.85)))
                    : resolved(.primary).withAlphaComponent(0.85),
                shadowOpacity: onArtwork ? 0.45 : 0.2,
                isPlaying: playback.isPlayingSmoothed,
                height: height, verticalOffset: Self.paneVerticalOffset,
                controls: .init(
                    shuffleShown: playback.playbackMode != nil && playback.playbackModeOptions.contains(.shuffle),
                    shuffleActive: playback.playbackMode == .shuffle,
                    repeatShown: playback.playbackMode != nil && playback.playbackModeOptions.canRepeat,
                    repeatActive: playback.playbackMode == .repeatOne || playback.playbackMode == .repeatAll,
                    repeatOne: playback.playbackMode == .repeatOne,
                    withheld: playback.controlsWithheldReason != nil,
                    activeFill: onArtwork ? NSColor.white.withAlphaComponent(0.22)
                        : resolved(.primary).withAlphaComponent(0.12),
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)))
        }
        CATransaction.commit()

        if showsList {
            let fs = fontSize
            let columnWidth = width - listX
            let style = LyricsLayerRowStyle(
                fontSize: fs, romaFontSize: fs * 0.54, translationFontSize: fs * 0.57,
                fontFamily: playback.lyricsFontFamily, textColor: text, secondaryColor: secondary,
                showRomanization: playback.showRomanization, showTranslation: playback.showTranslation,
                centered: false, wordRise: true, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                duetInsetUnit: LyricDuetLayout.insets(for: .leading, availableWidth: columnWidth, fontSize: fs).trailing,
                scale: CGFloat(viewport.scale))
            list.apply(LyricsLayerList.Spec(
                lines: playback.allLines, gapMarkers: playback.lyricsGapMarkersByIndex, songwriters: playback.songwriters,
                style: style, lineSpacing: fs * 0.98, showsScrollIndicator: false,
                leading: listLeading, trailing: listTrailing, onArtwork: onArtwork, suspendsBlur: false,
                currentLineIndex: playback.currentLineIndex, scrollLineIndex: playback.scrollLineIndex,
                overlapping: Set(playback.overlappingLineIndices), currentGapIndex: playback.currentGapIndex,
                fillSettled: playback.currentLineFillSettled, isPlaying: playback.isPlayingNow, surfaceVisible: true,
                timingEpoch: LyricsTimingEpoch.of(anchor: playback.anchor, pausedPositionMs: playback.pausedPositionMs,
                                                  offsetMs: PlaybackCoordinator.shared.currentLyricsOffsetMs),
                rate: playback.anchor?.rate ?? 1))
        }
    }

    private func applyBackground(onArtwork: Bool) {
        let mode = effectiveBackgroundMode
        let usesArtwork = mode == .artwork
        if usesArtwork, let layers = playback.windowBackgroundLayers {
            backdrop.apply(layers: layers, animating: playback.isPlayingNow)
            backdrop.layer?.isHidden = false
            dimLayer.isHidden = false
            fillLayer.isHidden = true
        } else {
            backdrop.layer?.isHidden = true
            dimLayer.isHidden = true
            fillLayer.isHidden = false
            switch mode {
            case .solid:
                let c = resolved(playback.backgroundColor).cgColor
                fillLayer.colors = [c, c]
            case .gradient:
                fillLayer.colors = [resolved(playback.backgroundColor).cgColor, resolved(playback.backgroundColorEnd).cgColor]
                let vertical = playback.gradientDirection == .vertical
                // 图层坐标 y 向上:竖向渐变从顶(y=1)到底(y=0)。
                fillLayer.startPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 0, y: 0.5)
                fillLayer.endPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 1, y: 0.5)
            case .artwork, .glass:
                fillLayer.colors = [NSColor.black.cgColor, NSColor.black.cgColor]
            }
        }
    }

    private func currentPositionMs() -> Int {
        playback.anchor?.extrapolatedPositionMs(now: Date()) ?? playback.pausedPositionMs ?? 0
    }

    private func currentDurationMs() -> Int {
        playback.anchor?.durationMs ?? playback.currentDurationMs ?? 0
    }

    static func artistAlbum(_ artist: String, _ album: String) -> String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    static func emptyText(_ state: LyricsWindowEmptyState) -> String {
        switch state {
        case .notPlaying: return L10n.t("未在播放")
        case .adBreak: return L10n.t("广告中")
        case .radioTalk: return L10n.t("口白")
        case .instrumental: return L10n.t("纯音乐")
        case .noLyrics: return L10n.t("暂无歌词")
        case .networkDown: return L10n.t("网络连接失败")
        case .searching: return L10n.t("搜索歌词中…")
        case .none: return L10n.t("无歌词")
        }
    }

    // MARK: - 渲染与编码

    private func setUpRendering() {
        guard let device else { return }
        let w = viewport.pixelWidth, h = viewport.pixelHeight
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache, let queue = device.makeCommandQueue() else { return }
        var made: [(buffer: CVPixelBuffer, texture: CVMetalTexture)] = []
        for _ in 0...Self.maxFramesInFlight {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                                &buffer)
            var cvTexture: CVMetalTexture?
            if let buffer { CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTexture) }
            guard let buffer, let cvTexture, CVMetalTextureGetTexture(cvTexture) != nil else { return }
            made.append((buffer, cvTexture))
        }
        guard let first = made.first.flatMap({ CVMetalTextureGetTexture($0.texture) }) else { return }
        slots = made
        textureCache = cache
        self.queue = queue
        let r = CARenderer(mtlTexture: first, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                        kCARendererMetalCommandQueue: queue])
        r.layer = container
        r.bounds = container.bounds
        renderer = r

        var compression: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_JPEG,
                                   encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &compression)
        if let compression {
            VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_Quality, value: Self.jpegQuality as CFNumber)
            VTCompressionSessionPrepareToEncodeFrames(compression)
            session = compression
        }
    }

    /// 画了一帧返回 true;前面的帧还没编完、跳过这一拍时返回 false。
    @discardableResult
    private func renderFrame() -> Bool {
        guard let renderer, let queue, let session, !slots.isEmpty, framesInFlight < Self.maxFramesInFlight,
              let texture = CVMetalTextureGetTexture(slots[nextSlot].texture) else { return false }
        let pixelBuffer = slots[nextSlot].buffer
        nextSlot = (nextSlot + 1) % slots.count
        // 不挂窗口、没有父视图时 AppKit 不会替它们跑 layout():歌词列表的渐隐遮罩、背景光斑的位置都在 layout() 里定,
        // 不手动跑一次就是零尺寸遮罩,整列歌词被遮掉。
        list.layoutSubtreeIfNeeded()
        backdrop.layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let backdropLayer = backdrop.layer, !backdropLayer.isHidden { DetachedLayerTree.assemble(backdrop) }
        if !list.isHidden { DetachedLayerTree.assemble(list) }
        for view in [backdrop, list] as [NSView] {
            view.layer?.anchorPoint = .zero
            view.layer?.position = view.frame.origin
            view.layer?.bounds = CGRect(origin: .zero, size: view.frame.size)
        }
        CATransaction.commit()
        CATransaction.flush()

        renderer.setDestination(texture)
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        guard let commandBuffer = queue.makeCommandBuffer() else { return false }
        framesInFlight += 1
        let presentation = CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)
        // 同一条命令队列按提交顺序执行:这条空命令跑完时,CARenderer 那一帧已经画进像素缓冲。
        commandBuffer.addCompletedHandler { [weak self] _ in
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer, presentationTimeStamp: presentation,
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in
                var jpeg: Data?
                if status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) {
                    var length = 0
                    var pointer: UnsafeMutablePointer<CChar>?
                    if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                                   dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer {
                        jpeg = Data(bytes: pointer, count: length)
                    }
                }
                Self.finish(self, jpeg: jpeg)
            }
            if status != noErr { Self.finish(self, jpeg: nil) }
        }
        commandBuffer.commit()
        return true
    }

    private nonisolated static func finish(_ renderer: WebLyricsScreenRenderer?, jpeg: Data?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let renderer else { return }
                renderer.framesInFlight -= 1
                if let jpeg { renderer.onFrame?(jpeg) }
            }
        }
    }
}

/// 歌词窗口左栏的图层版(封面卡 + 歌名 + 歌手 — 专辑 + 进度),尺寸照 `LyricsWindowView.playerPane`:
/// 封面圆角 12、阴影半径 26 / 下移 12;封面底到歌名 19、歌名 17pt 半粗、歌手行 15.5pt、两行各 22 高叠 −3;
/// 歌手行到进度条 19、进度条 6 高、时间行 11pt 等宽数字、两者相隔 5;进度到播放控制 17。播放控制五颗键的位置和
/// 字号见 `WebLyricsControlsLayout`,不透明度照歌词窗口(播放 0.85、上 / 下一首 0.72、随机 / 循环熄灭 0.55,
/// 控制被拦下时主三键再乘 `withheldControlOpacity`),按下缩到 0.8 再弹回(同 `TransportButtonStyle`)。
/// 整组跟歌词窗口一样垂直居中。暂停时封面缩到 0.732,弹簧 0.5s / 阻尼 0.72。
@MainActor
final class WebLyricsPlayerPane: CALayer {
    struct Content {
        var artwork: CGImage?
        var title: String
        var artistAlbum: String
        var primary: NSColor
        var secondary: NSColor
        var timeColor: NSColor
        var barFill: NSColor
        var shadowOpacity: Float
        var isPlaying: Bool
        var height: CGFloat
        var verticalOffset: CGFloat
        var controls: Controls
    }

    struct Controls {
        var shuffleShown: Bool
        var shuffleActive: Bool
        var repeatShown: Bool
        var repeatActive: Bool
        var repeatOne: Bool
        var withheld: Bool
        /// 随机 / 循环点亮时那圈胶囊底的颜色。
        var activeFill: NSColor
        var reduceMotion: Bool
    }

    private let coverHost = CALayer()
    private let cover = CALayer()
    private let titleLayer = CATextLayer()
    private let artistLayer = CATextLayer()
    private let barTrack = CALayer()
    private let barFill = CALayer()
    private let elapsedLayer = CATextLayer()
    private let durationLayer = CATextLayer()
    private let glyphs: [WebLyricsControlsLayout.Button: CALayer] = Dictionary(
        uniqueKeysWithValues: WebLyricsControlsLayout.Button.allCases.map { ($0, CALayer()) })
    private let shuffleFill = CALayer()
    private let repeatFill = CALayer()
    private var controlsLayout: WebLyricsControlsLayout?
    private var content: Content?
    private var playingShown: Bool?
    private var artworkShown: CGImage?

    override init() {
        super.init()
        isGeometryFlipped = true
        for l in [coverHost, cover, titleLayer, artistLayer, barTrack, barFill, elapsedLayer, durationLayer] as [CALayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "string": NSNull(),
                         "foregroundColor": NSNull(), "backgroundColor": NSNull(), "shadowOpacity": NSNull()]
        }
        cover.cornerRadius = 12
        cover.cornerCurve = .continuous
        cover.masksToBounds = true
        cover.contentsGravity = .resizeAspectFill
        coverHost.addSublayer(cover)
        coverHost.shadowColor = NSColor.black.cgColor
        coverHost.shadowRadius = 26
        coverHost.shadowOffset = CGSize(width: 0, height: 12)
        addSublayer(coverHost)
        for t in [titleLayer, artistLayer, elapsedLayer, durationLayer] {
            t.truncationMode = .end
            t.isWrapped = false
            addSublayer(t)
        }
        durationLayer.alignmentMode = .right
        barTrack.cornerRadius = 3
        barFill.cornerRadius = 3
        addSublayer(barTrack)
        addSublayer(barFill)
        for l in [shuffleFill, repeatFill] + Array(glyphs.values) {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull(),
                         "hidden": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]
            addSublayer(l)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ next: Content) {
        content = next
        let w = bounds.width
        let scale = contentsScaleForText
        let play = min(33, max(17, w * 0.079))
        let controlsHeight = (play * 1.21).rounded()
        let total = w + 19 + 41 + 19 + 6 + 5 + 13 + 17 + controlsHeight
        let top = ((next.height - total) / 2 - next.verticalOffset).rounded()

        // 封面卡带着暂停时的缩小变换,只能设 bounds + position:设 frame 会按当前缩放反算 bounds,
        // 暂停时设一次,继续播放缩放回到 1 时封面就大了 1/0.732 倍。
        coverHost.bounds = CGRect(x: 0, y: 0, width: w, height: w)
        coverHost.position = CGPoint(x: w / 2, y: top + w / 2)
        cover.frame = coverHost.bounds
        coverHost.shadowPath = CGPath(roundedRect: coverHost.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        coverHost.shadowOpacity = next.shadowOpacity
        if next.artwork !== artworkShown {
            artworkShown = next.artwork
            let fade = CABasicAnimation(keyPath: "contents")
            fade.duration = 0.5
            cover.add(fade, forKey: "contents-fade")
            cover.contents = next.artwork
            cover.backgroundColor = next.artwork == nil ? next.primary.withAlphaComponent(0.1).cgColor : nil
        }
        if next.isPlaying != playingShown {
            let target = CATransform3DMakeScale(next.isPlaying ? 1 : 0.732, next.isPlaying ? 1 : 0.732, 1)
            if playingShown != nil {
                let spring = CASpringAnimation(keyPath: "transform")
                spring.mass = 1
                spring.stiffness = pow(2 * .pi / 0.5, 2)
                spring.damping = 4 * .pi * 0.72 / 0.5
                spring.fromValue = coverHost.presentation()?.transform ?? coverHost.transform
                spring.toValue = target
                spring.duration = spring.settlingDuration
                coverHost.add(spring, forKey: "scale")
            }
            coverHost.transform = target
            playingShown = next.isPlaying
        }

        var y = top + w + 19
        setText(titleLayer, next.title, font: .systemFont(ofSize: 17, weight: .semibold), color: next.primary,
                frame: CGRect(x: 0, y: y, width: w, height: 22), scale: scale)
        y += 22 - 3
        setText(artistLayer, next.artistAlbum, font: .systemFont(ofSize: 15.5), color: next.secondary,
                frame: CGRect(x: 0, y: y, width: w, height: 22), scale: scale)
        y += 22 + 19
        barTrack.frame = CGRect(x: 0, y: y, width: w, height: 6)
        barTrack.backgroundColor = next.primary.withAlphaComponent(0.25).cgColor
        barFill.backgroundColor = next.barFill.cgColor
        y += 6 + 5
        elapsedLayer.frame = CGRect(x: 0, y: y, width: w / 2, height: 14)
        durationLayer.frame = CGRect(x: w / 2, y: y, width: w / 2, height: 14)
        y += 13 + 17
        layoutControls(next, width: w, rowTop: y, rowHeight: controlsHeight, scale: scale)
    }

    /// 点中哪颗键(左栏坐标,y 向下)。没画出来的随机 / 循环不算。
    func button(at point: CGPoint) -> WebLyricsControlsLayout.Button? {
        guard let controlsLayout, let content, let b = controlsLayout.button(at: point) else { return nil }
        switch b {
        case .shuffle: return content.controls.shuffleShown ? b : nil
        case .repeatMode: return content.controls.repeatShown ? b : nil
        default: return b
        }
    }

    /// 按下的反馈:缩到 0.8 再弹回(同歌词窗口 `TransportButtonStyle`:按下 0.1s easeOut、松手弹簧)。
    func press(_ button: WebLyricsControlsLayout.Button) {
        guard content?.controls.reduceMotion == false else { return }
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1, 0.8, 1.04, 1]
        pulse.keyTimes = [0, 0.24, 0.62, 1]
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                                 CAMediaTimingFunction(name: .easeInEaseOut)]
        pulse.duration = 0.42
        var layers = [glyphs[button]]
        if button == .shuffle { layers.append(shuffleFill) }
        if button == .repeatMode { layers.append(repeatFill) }
        for l in layers.compactMap({ $0 }) { l.add(pulse, forKey: "press") }
    }

    private func layoutControls(_ next: Content, width w: CGFloat, rowTop: CGFloat, rowHeight: CGFloat, scale: CGFloat) {
        let c = next.controls
        let skipFont = WebLyricsControlsLayout(width: w, rowTop: rowTop, rowHeight: rowHeight, skipGlyphWidth: 0).skipFontSize
        let skipWidth = Self.glyph("backward.fill", size: skipFont, color: next.primary, scale: scale)?.size.width ?? skipFont
        let layout = WebLyricsControlsLayout(width: w, rowTop: rowTop, rowHeight: rowHeight, skipGlyphWidth: skipWidth)
        controlsLayout = layout
        let mainOpacity: Float = c.withheld ? Float(PlaybackCoordinator.withheldControlOpacity) : 1
        let items: [(WebLyricsControlsLayout.Button, String, CGFloat, Float, Bool)] = [
            (.shuffle, "shuffle", layout.modeFontSize, c.shuffleActive ? 1 : 0.55, c.shuffleShown),
            (.previous, "backward.fill", layout.skipFontSize, 0.72 * mainOpacity, true),
            (.playPause, next.isPlaying ? "pause.fill" : "play.fill", layout.playFontSize, 0.85 * mainOpacity, true),
            (.next, "forward.fill", layout.skipFontSize, 0.72 * mainOpacity, true),
            (.repeatMode, c.repeatOne ? "repeat.1" : "repeat", layout.modeFontSize, c.repeatActive ? 1 : 0.55, c.repeatShown),
        ]
        for (button, name, size, opacity, shown) in items {
            guard let layer = glyphs[button], let cell = layout.cells[button] else { continue }
            layer.isHidden = !shown
            guard shown, let g = Self.glyph(name, size: size, color: next.primary, scale: scale) else { continue }
            layer.contents = g.image
            layer.contentsScale = scale
            layer.bounds = CGRect(origin: .zero, size: g.size)
            layer.position = CGPoint(x: cell.midX, y: cell.midY)
            layer.opacity = opacity
        }
        // 点亮态的胶囊底:字形四周内衬横 3、竖 4(同 modeToggleButton)。
        for (fill, button, active, shown) in [(shuffleFill, WebLyricsControlsLayout.Button.shuffle, c.shuffleActive, c.shuffleShown),
                                              (repeatFill, .repeatMode, c.repeatActive, c.repeatShown)] {
            let glyphSize = glyphs[button]?.bounds.size ?? .zero
            let size = CGSize(width: glyphSize.width + 6, height: glyphSize.height + 8)
            fill.isHidden = !(shown && active)
            fill.bounds = CGRect(origin: .zero, size: size)
            fill.position = glyphs[button]?.position ?? .zero
            fill.cornerRadius = size.height / 2
            fill.backgroundColor = c.activeFill.cgColor
        }
    }

    private static var glyphCache: [String: (image: CGImage, size: CGSize)] = [:]

    /// SF Symbol 按字号排好、填成一种颜色,按画面倍数画成位图。
    static func glyph(_ name: String, size: CGFloat, color: NSColor, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let key = "\(name)|\(size)|\(color)|\(scale)"
        if let hit = glyphCache[key] { return hit }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return nil }
        let pt = symbol.size
        let pw = Int(ceil(pt.width * scale)), ph = Int(ceil(pt.height * scale))
        guard pw > 0, ph > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        symbol.draw(in: CGRect(origin: .zero, size: pt))
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(origin: .zero, size: pt))
        guard let image = ctx.makeImage() else { return nil }
        if glyphCache.count > 64 { glyphCache.removeAll() }
        glyphCache[key] = (image, pt)
        return (image, pt)
    }

    func updateProgress(positionMs: Int, durationMs: Int) {
        guard let content, !isHidden else { return }
        let fraction = durationMs > 0 ? min(1, max(0, Double(positionMs) / Double(durationMs))) : 0
        let track = barTrack.frame
        barFill.frame = CGRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let scale = contentsScaleForText
        setText(elapsedLayer, Self.format(positionMs), font: font, color: content.timeColor, frame: elapsedLayer.frame, scale: scale)
        setText(durationLayer, Self.format(durationMs), font: font, color: content.timeColor, frame: durationLayer.frame, scale: scale)
    }

    private var contentsScaleForText: CGFloat {
        var layer: CALayer? = self
        while let l = layer {
            if l.transform.m11 != 1 { return abs(l.transform.m11) }
            layer = l.superlayer
        }
        return 2
    }

    private func setText(_ layer: CATextLayer, _ text: String, font: NSFont, color: NSColor, frame: CGRect, scale: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        if (layer.string as? NSAttributedString) != string { layer.string = string }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let inset = max(0, (frame.height - lineHeight) / 2).rounded()
        layer.frame = CGRect(x: frame.minX, y: frame.minY + inset, width: frame.width, height: frame.height - inset)
        layer.contentsScale = scale
    }

    static func format(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// 没有歌词可画时的那一格(图标 40pt + 16pt 半粗文字,同歌词窗口封面背景上的自绘空状态)。
@MainActor
final class WebLyricsEmptyStateLayer: CALayer {
    private let icon = CALayer()
    private let label = CATextLayer()
    private var shown: (icon: String, text: String, color: NSColor)?

    override init() {
        super.init()
        isGeometryFlipped = true
        icon.contentsGravity = .resizeAspect
        label.alignmentMode = .center
        label.truncationMode = .end
        addSublayer(icon)
        addSublayer(label)
        for l in [icon, label] as [CALayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "string": NSNull()]
        }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(icon name: String, text: String, onArtwork: Bool, color: NSColor) {
        let scale: CGFloat = 3
        if shown?.icon != name || shown?.color != color {
            let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
                .applying(.init(paletteColors: [color]))
            icon.contents = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        label.string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: color,
        ])
        label.contentsScale = scale
        icon.contentsScale = scale
        shown = (name, text, color)
        let iconSize: CGFloat = 48
        let blockHeight = iconSize + 12 + 22
        let top = (bounds.height - blockHeight) / 2
        icon.frame = CGRect(x: (bounds.width - iconSize) / 2, y: top, width: iconSize, height: iconSize)
        label.frame = CGRect(x: 16, y: top + iconSize + 12, width: bounds.width - 32, height: 22)
    }
}
