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
    @Published private(set) var anchor: ProgressAnchor?

    private var cancellables: [AnyCancellable] = []
    private var activeMode: PlaybackSourceMode?

    private init() {}

    // 供 EnrichCacheStore 保存/删除/移除逐字后调用——两个数据源默认都只在"换歌"那一刻
    // 才重新读歌词,同一首歌播放中途改了缓存内容不会自动生效(这正是"改完歌词、悬浮窗
    // 还是旧版本"这个反馈的根因)。本地模式直接读磁盘,写完盘立刻调用就行;relay 模式
    // 靠网络轮询,内容来自 collector 的 /now 接口,得等 launchctl kickstart 真的把
    // collector 重启完(异步、没有完成回调)才能拿到新内容,所以延迟一下再强制轮询,
    // 避免打到正在退出的旧进程。
    func refreshLyricsForCurrentTrack() {
        switch activeMode {
        case .relay:
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                RelayPoller.shared.forceRefetchNow()
            }
        case .local:
            LocalPlaybackSource.shared.forceReloadLyricsForCurrentTrack()
        case nil:
            break
        }
    }

    // 单曲歌词时间轴微调——转发给当前生效的那个数据源(跟 refreshLyricsForCurrentTrack()
    // 同一个"按 activeMode 分发"模式),UI 层(菜单/快捷键)只认 PlaybackCoordinator,
    // 不用关心当前到底是本地模式还是 relay 模式在跑。
    func nudgeLyricsOffset(by deltaMs: Int) {
        switch activeMode {
        case .relay: RelayPoller.shared.nudgeLyricsOffset(by: deltaMs)
        case .local: LocalPlaybackSource.shared.nudgeLyricsOffset(by: deltaMs)
        case nil: break
        }
    }

    func resetLyricsOffset() {
        switch activeMode {
        case .relay: RelayPoller.shared.resetLyricsOffset()
        case .local: LocalPlaybackSource.shared.resetLyricsOffset()
        case nil: break
        }
    }

    // 当前曲目已经校准过的时间偏移——读 LyricsOffsetStore,key 跟 trackKey 拼法完全
    // 一致(artist/title 都是空字符串时 LyricsOffsetStore 自己会判定 key 无效返回 0,
    // 不需要在这里额外判断"还没拿到任何曲目信息"这种情况)。
    var currentLyricsOffsetMs: Int {
        LyricsOffsetStore.shared.offset(forKey: "\(artist)|\(title)")
    }

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
            source.$anchor.assign(to: \.anchor, on: self),
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
            source.$anchor.assign(to: \.anchor, on: self),
        ]
    }
}
