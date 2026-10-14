import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 网页歌词 OBS 那条的数据源(19 章):样式照悬浮歌词(字体、字号、粗细、已唱 / 未唱色、描边、背景卡、读音 / 译文开关,
/// 颜色规则同 `OverlayPlayback`),歌词是播放协调器那份整首歌词,位置扣掉设备延迟(见 `WebLyricsObsPayload.obsTimelineMs`)。
/// 没有网页连着时不订阅任何东西。
@MainActor
final class WebLyricsObsFeed {
    /// 位置心跳:锚点没变时也隔一会儿重发一次,网页那边的推算误差不会累积。
    static let heartbeat: TimeInterval = 5

    private var clients: [ObjectIdentifier: WebLyricsConnection] = [:]
    private var subs: [AnyCancellable] = []
    private var timer: Timer?
    private var lastStyle = ""
    private var lastTrack = ""
    private var lastPosition = ""

    func add(_ connection: WebLyricsConnection) {
        clients[ObjectIdentifier(connection)] = connection
        if subs.isEmpty { subscribe() }
        for message in [lastStyle, lastTrack, lastPosition] where !message.isEmpty { connection.sendText(message) }
    }

    func remove(_ connection: WebLyricsConnection) {
        guard clients.removeValue(forKey: ObjectIdentifier(connection)) != nil, clients.isEmpty else { return }
        subs = []
        timer?.invalidate()
        timer = nil
        lastStyle = ""
        lastTrack = ""
        lastPosition = ""
    }

    private func subscribe() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        let offsets = LyricsOffsetStore.shared
        let styleInputs: [AnyPublisher<Void, Never>] = [
            p.$artworkAccentColor.map { _ in () }.eraseToAnyPublisher(),
            s.$followsCoverArt.map { _ in () }.eraseToAnyPublisher(),
            s.$foregroundColor.map { _ in () }.eraseToAnyPublisher(),
            s.$karaokeUnsungFollowsCoverArt.map { _ in () }.eraseToAnyPublisher(),
            s.$karaokeUnsungColor.map { _ in () }.eraseToAnyPublisher(),
            s.$textStrokeEnabled.map { _ in () }.eraseToAnyPublisher(),
            s.$textStrokeColor.map { _ in () }.eraseToAnyPublisher(),
            s.$backgroundIsVisible.map { _ in () }.eraseToAnyPublisher(),
            s.$backgroundColor.map { _ in () }.eraseToAnyPublisher(),
            s.$fontFamilyName.map { _ in () }.eraseToAnyPublisher(),
            s.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayFontWeight.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayShowRomanization.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayShowTranslation.map { _ in () }.eraseToAnyPublisher(),
        ]
        let trackInputs: [AnyPublisher<Void, Never>] = [
            p.$allLines.map { _ in () }.eraseToAnyPublisher(),
            p.$lyricsGapMarkers.map { _ in () }.eraseToAnyPublisher(),
        ]
        let positionInputs: [AnyPublisher<Void, Never>] = [
            p.$anchor.map { _ in () }.eraseToAnyPublisher(),
            p.$pausedPositionMs.map { _ in () }.eraseToAnyPublisher(),
            p.$isPlayingNow.map { _ in () }.eraseToAnyPublisher(),
            p.$currentLyricsOffsetMs.map { _ in () }.eraseToAnyPublisher(),
            p.$title.map { _ in () }.eraseToAnyPublisher(),
            p.$isRadioTalkBreak.map { _ in () }.eraseToAnyPublisher(),
            p.$isCurrentTrackAdBreak.map { _ in () }.eraseToAnyPublisher(),
            offsets.$globalOffsetMs.map { _ in () }.eraseToAnyPublisher(),
            offsets.$playerOffsets.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published 是 willSet 语义:先让这一拍的赋值落定,再读当前值组消息。
        subs = [
            Publishers.MergeMany(styleInputs).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.publish(style: Self.makeStyle()) },
            Publishers.MergeMany(trackInputs).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.publish(track: Self.makeTrack()) },
            Publishers.MergeMany(positionInputs).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.publish(position: Self.makePosition()) },
        ]
        publish(style: Self.makeStyle())
        publish(track: Self.makeTrack())
        publish(position: Self.makePosition())
        let t = Timer(timeInterval: Self.heartbeat, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish(position: Self.makePosition(), force: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func publish(style: String) {
        guard style != lastStyle else { return }
        lastStyle = style
        broadcast(style)
    }

    private func publish(track: String) {
        guard track != lastTrack else { return }
        lastTrack = track
        broadcast(track)
    }

    private func publish(position: String, force: Bool = false) {
        guard force || position != lastPosition else { return }
        lastPosition = position
        broadcast(position)
    }

    private func broadcast(_ text: String) {
        for client in clients.values { client.sendText(text) }
    }

    private static func css(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return WebLyricsObsPayload.cssColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }

    private static func makeStyle() -> String {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        let sung = (s.followsCoverArt ? p.artworkAccentColor : nil) ?? s.foregroundColor
        let unsung = (s.karaokeUnsungFollowsCoverArt ? p.artworkAccentColor?.opacity(WordKaraokeGradient.dimOpacity) : nil)
            ?? s.karaokeUnsungColor
        return WebLyricsObsPayload.style(.init(
            fontFamily: s.fontFamilyName, fontSize: s.fontSize, weight: WebLyricsObsPayload.cssWeight(s.overlayFontWeight),
            sung: css(sung), unsung: css(unsung),
            stroke: s.textStrokeEnabled ? css(s.textStrokeColor) : nil,
            card: s.backgroundIsVisible ? css(s.backgroundColor) : nil,
            showRomanization: s.overlayShowRomanization, showTranslation: s.overlayShowTranslation))
    }

    private static func makeTrack() -> String {
        let p = PlaybackCoordinator.shared
        return WebLyricsObsPayload.track(id: p.title + "\u{1F}" + p.artist, lines: p.allLines, gaps: p.lyricsGapMarkers)
    }

    private static func makePosition() -> String {
        let p = PlaybackCoordinator.shared
        let offsets = LyricsOffsetStore.shared
        let state: WebLyricsObsPayload.State
        if p.title.isEmpty {
            state = .idle
        } else if p.isRadioTalkBreak || p.isCurrentTrackAdBreak {
            state = .hold
        } else {
            state = p.isPlayingNow ? .playing : .paused
        }
        let timeline = WebLyricsObsPayload.obsTimelineMs(
            timelineMs: p.lyricsTimelineMs(), bundleID: LocalPlaybackSource.shared.lastResolvedBundleID,
            playerOffsets: offsets.playerOffsets, globalOffsetMs: offsets.globalOffsetMs)
        return WebLyricsObsPayload.position(timelineMs: timeline, rate: p.anchor?.rate ?? 1, state: state)
    }
}
