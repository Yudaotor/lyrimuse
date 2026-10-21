import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 网页歌词 OBS 那条的数据源(19 章):样式照悬浮歌词(字体、字号、四行字重、已唱 / 未唱色、描边、背景卡、读音 / 译文 /
/// 下一句开关、卡拉OK、对齐方式、换行或滚动、行距、宽度、暂停时隐藏、换句动画,颜色规则同 `OverlayPlayback`),歌词按悬浮歌词断好的整首
/// (长句拆分 / 短句合并之后;断句跟着悬浮歌词的字号和宽度变,所以悬浮歌词那一面换句时也重组一次,内容没变不重发),位置扣掉设备延迟(见 `WebLyricsObsPayload.obsTimelineMs`)。
/// 歌名卡用界面上显示的歌名、歌手、专辑,封面优先取高清替代的小图,缩成 JPEG 随 `song` 消息发,同一张图只编一次。
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
    private var lastSong = ""
    private var coverThumbnail: NSImage?
    private var coverData: Data?
    private var coverURL: String?

    func add(_ connection: WebLyricsConnection) {
        // 先订阅再登记:订阅当场就把三样广播一遍,登记在前的话这条连接会收到两份(下面再补发一遍)
        if subs.isEmpty { subscribe() }
        clients[ObjectIdentifier(connection)] = connection
        for message in [lastStyle, lastTrack, lastPosition, lastSong] where !message.isEmpty { connection.sendText(message) }
    }

    func remove(_ connection: WebLyricsConnection) {
        guard clients.removeValue(forKey: ObjectIdentifier(connection)) != nil, clients.isEmpty else { return }
        subs = []
        timer?.invalidate()
        timer = nil
        lastStyle = ""
        lastTrack = ""
        lastPosition = ""
        lastSong = ""
        coverThumbnail = nil
        coverData = nil
        coverURL = nil
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
            s.$showNextLinePreview.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayLyricsKaraoke.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayDuetAlignmentOverride.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayLineOverflow.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayRomanizationSpacing.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayTranslationSpacing.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayNextLineSpacing.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayWidth.map { _ in () }.eraseToAnyPublisher(),
            s.$hideWhenNotPlaying.map { _ in () }.eraseToAnyPublisher(),
            s.$overlayLineChangeAnimation.map { _ in () }.eraseToAnyPublisher(),
            s.$obsSongCard.map { _ in () }.eraseToAnyPublisher(),
        ]
        let trackInputs: [AnyPublisher<Void, Never>] = [
            p.$allLines.map { _ in () }.eraseToAnyPublisher(),
            p.$lyricsGapMarkers.map { _ in () }.eraseToAnyPublisher(),
            p.$overlayLyrics.map(\.lineIndex).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
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
        let songInputs: [AnyPublisher<Void, Never>] = [
            p.$title.map { _ in () }.eraseToAnyPublisher(),
            p.$artist.map { _ in () }.eraseToAnyPublisher(),
            p.$displayTitle.map { _ in () }.eraseToAnyPublisher(),
            p.$displayArtist.map { _ in () }.eraseToAnyPublisher(),
            p.$displayAlbum.map { _ in () }.eraseToAnyPublisher(),
            p.$artworkData.map { _ in () }.eraseToAnyPublisher(),
            p.$highResArtworkThumbnail.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published 是 willSet 语义:先让这一拍的赋值落定,再读当前值组消息。
        subs = [
            Publishers.MergeMany(styleInputs).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.publish(style: Self.makeStyle()) },
            Publishers.MergeMany(trackInputs).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.publish(track: Self.makeTrack()) },
            Publishers.MergeMany(positionInputs).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.publish(position: Self.makePosition()) },
            Publishers.MergeMany(songInputs).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.publishSong() },
        ]
        publish(style: Self.makeStyle())
        publish(track: Self.makeTrack())
        publish(position: Self.makePosition())
        publishSong()
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

    private func publishSong() {
        let song = makeSong()
        guard song != lastSong else { return }
        lastSong = song
        broadcast(song)
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
        let duet = WebLyricsObsPayload.duetInsets(overlayWidth: s.overlayWidth, fontSize: s.fontSize)
        return WebLyricsObsPayload.style(.init(
            fontFamily: s.fontFamilyName, fontSize: s.fontSize, weights: WebLyricsObsPayload.cssWeights(s.overlayFontWeight),
            sung: css(sung), unsung: css(unsung),
            stroke: s.textStrokeEnabled ? css(s.textStrokeColor) : nil,
            card: s.backgroundIsVisible ? css(s.backgroundColor) : nil,
            showRomanization: s.overlayShowRomanization, showTranslation: s.overlayShowTranslation,
            showNextLine: s.showNextLinePreview, karaoke: s.overlayLyricsKaraoke,
            alignment: s.overlayDuetAlignmentOverride, overflow: s.overlayLineOverflow,
            spacing: s.overlayRowSpacing, width: s.overlayWidth, hideWhenPaused: s.hideWhenNotPlaying,
            lineChangeAnimation: s.overlayLineChangeAnimation, duetStageInset: duet.stage, duetCenterInset: duet.center,
            songCard: s.obsSongCard))
    }

    private static func makeTrack() -> String {
        let p = PlaybackCoordinator.shared
        let segmented = LocalPlaybackSource.shared.overlayWindowLines()
        return WebLyricsObsPayload.track(id: p.title + "\u{1F}" + p.artist, lines: segmented.isEmpty ? p.allLines : segmented,
                                         gaps: p.lyricsGapMarkers)
    }

    private func makeSong() -> String {
        let p = PlaybackCoordinator.shared
        let thumbnail = p.highResArtworkThumbnail
        let data = thumbnail == nil ? p.artworkData : nil
        if thumbnail !== coverThumbnail || data != coverData {
            coverThumbnail = thumbnail
            coverData = data
            coverURL = (thumbnail?.tiffRepresentation ?? data).flatMap { WebLyricsObsPayload.coverDataURL($0) }
        }
        return WebLyricsObsPayload.song(id: p.title + "\u{1F}" + p.artist, title: p.displayTitle, artist: p.displayArtist,
                                        album: p.displayAlbum, cover: p.title.isEmpty ? nil : coverURL)
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
            // 锚点被暂停通知冻住时就报暂停:网页把速率 0 当没报、按 1 倍速往前推,报「在放」的话会先冲再跳回。
            state = p.lyricsClockRunning ? .playing : .paused
        }
        let timeline = WebLyricsObsPayload.obsTimelineMs(
            timelineMs: p.lyricsTimelineMs(), bundleID: LocalPlaybackSource.shared.lastResolvedBundleID,
            playerOffsets: offsets.playerOffsets, globalOffsetMs: offsets.globalOffsetMs)
        return WebLyricsObsPayload.position(timelineMs: timeline, rate: p.anchor?.rate ?? 1, state: state)
    }
}
