import Foundation
import Combine
import DesktopLyricsCore
import os

private let logger = Logger(subsystem: "com.chenyuhao.applemusic-desktop-lyrics", category: "coordinator")

// 按设置里选的数据源(远程 relay / 本地 media-control),二选一持有 RelayPoller 或
// LocalPlaybackSource,把激活中的那个源转发到自己的 @Published 属性上——UI 层只认
// PlaybackCoordinator.shared,不用关心当前到底是哪个源在跑。切换时把旧源 stop()、
// 新源 start(),不会两个源同时在后台空转。
@MainActor
final class PlaybackCoordinator: ObservableObject {
    static let shared = PlaybackCoordinator()

    @Published private(set) var title: String = ""
    @Published private(set) var artist: String = ""
    @Published private(set) var album: String = ""
    @Published private(set) var isPlayingNow: Bool = false
    @Published private(set) var currentLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?

    private var cancellables: [AnyCancellable] = []
    private var activeMode: PlaybackSourceMode?

    private init() {}

    func applyMode(_ mode: PlaybackSourceMode) {
        guard mode != activeMode else { return }
        activeMode = mode
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()

        switch mode {
        case .relay:
            LocalPlaybackSource.shared.stop()
            let p = RelayPoller.shared
            p.start()
            bind(to: p)
        case .local:
            RelayPoller.shared.stop()
            let s = LocalPlaybackSource.shared
            s.start()
            bind(to: s)
        }
    }

    private func bind(to source: RelayPoller) {
        cancellables = [
            source.$title.assign(to: \.title, on: self),
            source.$artist.assign(to: \.artist, on: self),
            source.$album.assign(to: \.album, on: self),
            source.$isPlayingNow.assign(to: \.isPlayingNow, on: self),
            source.$currentLine.assign(to: \.currentLine, on: self),
            source.$nextLineText.assign(to: \.nextLineText, on: self),
        ]
    }

    private func bind(to source: LocalPlaybackSource) {
        cancellables = [
            source.$title.assign(to: \.title, on: self),
            source.$artist.assign(to: \.artist, on: self),
            source.$album.assign(to: \.album, on: self),
            source.$isPlayingNow.assign(to: \.isPlayingNow, on: self),
            source.$currentLine.sink { [weak self] line in
                logger.debug("coordinator currentLine updated: hasLine=\(line != nil) hasWords=\(line?.words != nil) hasMainText=\(line?.mainText != nil)")
                self?.currentLine = line
            },
            source.$nextLineText.assign(to: \.nextLineText, on: self),
        ]
    }
}
