import Foundation
import Combine
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "coordinator")

// 目前只有本地 media-control 一个数据源,这个类退化成 LocalPlaybackSource 的一层薄
// 转发,但还是留着这一层不直接让 UI 碰 LocalPlaybackSource.shared——万一以后又要接
// 别的数据源,UI 层不用跟着改。
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
    private var started = false

    private init() {}

    // 供 EnrichCacheStore 保存/删除/移除逐字后调用——默认只在"换歌"那一刻才重新读
    // 歌词,同一首歌播放中途改了缓存内容不会自动生效,这里直接读磁盘强制刷新,写完盘
    // 立刻调用就行。
    func refreshLyricsForCurrentTrack() {
        LocalPlaybackSource.shared.forceReloadLyricsForCurrentTrack()
    }

    // 单曲歌词时间轴微调——转发给 LocalPlaybackSource,UI 层(菜单/快捷键)只认
    // PlaybackCoordinator,不用关心底下具体是谁在跑。
    func nudgeLyricsOffset(by deltaMs: Int) {
        LocalPlaybackSource.shared.nudgeLyricsOffset(by: deltaMs)
    }

    func resetLyricsOffset() {
        LocalPlaybackSource.shared.resetLyricsOffset()
    }

    // 供"歌词管理"窗口的偏移输入框用——那边直接写 LyricsOffsetStore(敲一个具体数值,
    // 不是靠 nudge 累加),写完调这个让数据源重新读一遍,如果编辑的恰好是正在播的
    // 这首歌,立刻就能看到效果,不用等下次换歌。
    func refreshLyricsOffsetForCurrentTrack() {
        LocalPlaybackSource.shared.refreshOffsetFromStore()
    }

    // 当前曲目已经校准过的时间偏移——读 LyricsOffsetStore,key 跟 trackKey 拼法完全
    // 一致(artist/title 都是空字符串时 LyricsOffsetStore 自己会判定 key 无效返回 0,
    // 不需要在这里额外判断"还没拿到任何曲目信息"这种情况)。
    var currentLyricsOffsetMs: Int {
        LyricsOffsetStore.shared.offset(forKey: "\(artist)|\(title)")
    }

    // 应用启动时调一次即可——只有一个数据源,不需要再区分"切换模式",started 只是防手滑
    // 重复调用重新订阅一遍。
    func start() {
        guard !started else { return }
        started = true
        let s = LocalPlaybackSource.shared
        s.start()
        cancellables = [
            s.$title.assign(to: \.title, on: self),
            s.$artist.assign(to: \.artist, on: self),
            s.$album.assign(to: \.album, on: self),
            s.$isPlayingNow.assign(to: \.isPlayingNow, on: self),
            s.$currentLine.sink { [weak self] line in
                logger.debug("coordinator currentLine updated: hasLine=\(line != nil) hasWords=\(line?.words != nil) hasMainText=\(line?.mainText != nil)")
                self?.currentLine = line
            },
            s.$nextLineText.assign(to: \.nextLineText, on: self),
            s.$anchor.assign(to: \.anchor, on: self),
        ]
    }
}
