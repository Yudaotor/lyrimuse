import AppKit
import Foundation
import Combine
import LyrimuseCore
import SwiftUI
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
    @Published private(set) var hasLyricsContent: Bool = false
    // 联网查过了、明确是纯音乐,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var isCurrentTrackInstrumental: Bool = false
    // Spotify 广告插播,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var isCurrentTrackAdBreak: Bool = false
    @Published private(set) var anchor: ProgressAnchor?
    // "歌词窗口"(完整可滚动歌词列表)用,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var currentLineIndex: Int?
    @Published private(set) var allLines: [LyricsWindowLine] = []
    // "歌词窗口"背景用的模糊封面图,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var artworkData: Data?
    // 上面那份原始字节解码出来的位图,只在封面数据真的变了的时候解一次。
    //
    // 2026-08-05 加"灵动岛顶行显示专辑封面"时补上的:灵动岛那一个 body 里会有两处读封面
    // (顶行那枚清晰小图 + "跟随封面"风格的模糊背景),各自现调 `NSImage(data:)` 的话,
    // 每次 body 重算都要把同一张几百 KB 的 JPEG 重解两遍——而 body 重算在换歌词行、换歌、
    // 重锚进度时都会发生(逐字高亮那一块是 TimelineView 自己的闭包,不牵动整个 body,
    // 所以不是 20Hz,但仍然远比"每首歌一次"频繁)。解码收敛到这一层做一次、两处共用。
    //
    // 放在这一层而不是 LocalPlaybackSource:跟 artworkAccentColor 同一个分层理由——
    // LyrimuseCore 那一层不引入 AppKit/SwiftUI,类型转换只能在这一层做。
    @Published private(set) var artworkImage: NSImage?
    // 从封面算出来的动态高亮色(已经从 LocalPlaybackSource 转发的十六进制字符串转成
    // Color——LyrimuseCore 那一层不引入 SwiftUI,转换只能在这一层做,见
    // LocalPlaybackSource.artworkAccentHex 的注释)。供"跟随封面"外观模式用,见
    // displayForegroundColor。
    @Published private(set) var artworkAccentColor: Color?
    // 当前曲目已生效的歌词时间轴校正值,见 LocalPlaybackSource 同名属性的注释——直接
    // 转发权威值,不在这一层另外拼 key 重新查一遍(2026-08-03 之前这里是一个计算属性,
    // 自己拼了个 "\(artist)|\(title)" 去查 LyricsOffsetStore,跟实际存储用的
    // key(LyricsOffsetStore.trackKey,多一段内容指纹)对不上,查出来的永远是 0)。
    @Published private(set) var currentLyricsOffsetMs: Int = 0
    // "歌词窗口"进度条的暂停态冻结位置/时长,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?

    private var cancellables: [AnyCancellable] = []
    private var started = false

    private init() {}

    // 供 EnrichCacheStore 保存/删除/移除逐字后调用——默认只在"换歌"那一刻才重新读
    // 歌词,同一首歌播放中途改了缓存内容不会自动生效,这里直接读磁盘强制刷新,写完盘
    // 立刻调用就行。
    func refreshLyricsForCurrentTrack() {
        LocalPlaybackSource.shared.forceReloadLyricsForCurrentTrack()
    }

    // 拖进度条跳转——转发给 LocalPlaybackSource,由它发指令 + 立刻重锚(见那边注释)。
    // UI 层(歌词窗口/灵动岛的进度条)只认 PlaybackCoordinator。
    func seek(toMs targetMs: Int) {
        LocalPlaybackSource.shared.seek(toMs: targetMs)
    }

    // 「导出诊断信息」用:这一刻实际被认下来的播放器,翻成人读得懂的名字。认不出来的
    // bundle id 原样附上(比只说"未知"有用得多——排查时那串 id 就是线索)。
    var resolvedPlayerDescription: String {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return "none (no snapshot yet)" }
        if let known = PlaybackPlayer.allCases.first(where: { $0.bundleIdentifier == id }) {
            return "\(known.rawValue) (\(id))"
        }
        return "unknown (\(id))"
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

    // 「喜欢」(Apple Music 的 favorited)只有 Apple Music 有:QQ 音乐/网易云音乐没有
    // AppleScript 支持,media-control 走的系统级 MediaRemote 也只有播放控制、没有收藏这个
    // 概念。所以 nil 有明确含义 ——"这个播放器根本没有这回事",悬浮窗据此整个不显示那个
    // 按钮,而不是显示一个永远点不亮的心。
    //
    // 这条状态**没有**跟着 2 秒轮询走:读一次要起一个 osascript 子进程,为一个绝大多数时候
    // 不变的布尔值每 2 秒 fork 一次不值当。改成两个时机各刷一次 —— 换歌时(见 start() 里
    // 那条订阅),以及鼠标悬停、控制排真的露出来的时候(见 LyricsOverlayView)。后者正好
    // 覆盖了"用户在 Music.app 里自己点了心、回头来看悬浮窗"这种情况。
    @Published private(set) var isFavorited: Bool?

    /// 播放模式(列表/随机/单曲循环)。跟"喜欢"一样只有 Apple Music 有 —— media-control 走的
    /// 系统级 MediaRemote 没有这个概念 —— 所以 nil 同样表示"这个播放器根本没有这回事",
    /// 按钮据此整个不显示。刷新时机也跟"喜欢"共用(换歌 / 窗口出现 / App 回到前台):
    /// 用户可能在 Music.app 里自己改了模式,我们没有任何事件能收到,只能在这几个时机回读。
    @Published private(set) var playbackMode: MusicPlaybackController.MusicPlaybackMode?

    /// 这一刻**实际在播**的是不是 Apple Music。
    ///
    /// ⚠️ 判定必须看这个,不能看 PlaybackPlayerPreference.current。设置里那一档可以是"自动
    /// 识别"(这台机器上就是),那时 current 不等于 .appleMusic,但实际在播的完全可能就是
    /// Apple Music —— 用设置值判断会让这颗心在"自动识别"下永远不出现。seek 那条路径早就
    /// 踩过同一个坑并用同一个信号修好了(见 LocalPlaybackSource.seek 里的 resolvedIsAppleMusic)。
    private var isAppleMusicPlayingNow: Bool {
        LocalPlaybackSource.shared.lastResolvedBundleID == PlaybackPlayer.appleMusic.bundleIdentifier
    }

    /// 重新读一次当前曲目的"喜欢"状态。当前在播的不是 Apple Music、或自动化权限还没拿到时
    /// 置 nil(按钮据此整个不显示)。
    ///
    /// 权限用 askIfNeeded: false 检查 —— 这是个后台刷新,绝不能因为它弹出系统授权对话框。
    func refreshFavorited() {
        guard isAppleMusicPlayingNow,
              MusicAutomationPermission.check(askIfNeeded: false).isAuthorized else {
            if isFavorited != nil { isFavorited = nil }
            return
        }
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.favoritedState()
            await MainActor.run { [weak self] in
                guard let self, self.isFavorited != value else { return }
                self.isFavorited = value
            }
        }
    }

    /// 点心:翻转当前曲目的"喜欢"状态。先乐观更新本地状态好让按钮立刻有反馈,再回读一次
    /// 以实际结果为准(写失败/曲目刚好换掉时会被纠回来)。
    ///
    /// 这里的权限检查用 askIfNeeded: true —— 这是用户主动点的,该问就问,跟播放控制那三个
    /// 按钮同一套(见 LyricsOverlayView.controlButton)。
    /// 重新读一次播放模式。跟 refreshFavorited 同一套前置判断和后台线程约定。
    func refreshPlaybackMode() {
        guard isAppleMusicPlayingNow,
              MusicAutomationPermission.check(askIfNeeded: false).isAuthorized else {
            if playbackMode != nil { playbackMode = nil }
            return
        }
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.playbackMode()
            await MainActor.run { [weak self] in
                guard let self, self.playbackMode != value else { return }
                self.playbackMode = value
            }
        }
    }

    /// 点一下切到下一档模式。跟 toggleFavorited 一样先乐观更新再回读,以实际结果为准。
    func cyclePlaybackMode() {
        guard isAppleMusicPlayingNow else { return }
        let target = (playbackMode ?? .list).next
        playbackMode = target
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
                return
            }
            MusicPlaybackController.setPlaybackMode(target)
            await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
        }
    }

    func toggleFavorited() {
        guard isAppleMusicPlayingNow else { return }
        let target = !(isFavorited ?? false)
        isFavorited = target
        Task.detached(priority: .userInitiated) {
            // 用 checkAppleMusicSafely 而不是 checkForCurrentPlayerSafely:后者在设置为
            // "自动识别"时会直接返回 true(它假定别的播放器不需要这个权限),而这里已经确认
            // 实际在播的就是 Apple Music,必须真的查一次权限,否则下面的 AppleScript 会静默失败。
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run { [weak self] in self?.refreshFavorited() }
                return
            }
            MusicPlaybackController.setFavorited(target)
            await MainActor.run { [weak self] in self?.refreshFavorited() }
        }
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
            // 换歌就重读一次"喜欢"状态。用 title+artist 组合去重而不是只看 title:同名不同
            // 歌手的曲目(翻唱/合辑里很常见)只看 title 会被当成同一首,漏掉一次刷新。
            s.$title.combineLatest(s.$artist)
                .map { "\($0)|\($1)" }
                .removeDuplicates()
                .sink { [weak self] _ in
                    self?.refreshFavorited()
                    self?.refreshPlaybackMode()
                },
            s.$artist.assign(to: \.artist, on: self),
            s.$album.assign(to: \.album, on: self),
            s.$isPlayingNow.assign(to: \.isPlayingNow, on: self),
            s.$currentLine.sink { [weak self] line in
                logger.debug("coordinator currentLine updated: hasLine=\(line != nil) hasWords=\(line?.words != nil) hasMainText=\(line?.mainText != nil)")
                self?.currentLine = line
            },
            s.$nextLineText.assign(to: \.nextLineText, on: self),
            s.$anchor.assign(to: \.anchor, on: self),
            s.$hasLyricsContent.assign(to: \.hasLyricsContent, on: self),
            s.$isCurrentTrackInstrumental.assign(to: \.isCurrentTrackInstrumental, on: self),
            s.$isCurrentTrackAdBreak.assign(to: \.isCurrentTrackAdBreak, on: self),
            s.$currentLineIndex.assign(to: \.currentLineIndex, on: self),
            s.$allLines.assign(to: \.allLines, on: self),
            s.$artworkData.assign(to: \.artworkData, on: self),
            // 解码在这里做一次,消费方(灵动岛顶行小封面/模糊背景)直接拿 NSImage,不在
            // view body 里反复解同一张图,见 artworkImage 声明处的注释。@Published 的
            // willSet 语义让这两条订阅在同一次调用里同步跑完,artworkData 和 artworkImage
            // 不会跨渲染帧不一致(SwiftUI 在这一轮 runloop 结束时才真正重绘)。
            s.$artworkData
                .map { $0.flatMap { NSImage(data: $0) } }
                .assign(to: \.artworkImage, on: self),
            // 十六进制字符串在这一层转成 Color——LocalPlaybackSource 所在的
            // LyrimuseCore 不引入 SwiftUI,见该属性定义处的注释。
            s.$artworkAccentHex
                .map { $0.map { Color(hexWithAlpha: $0, fallback: .white) } }
                .assign(to: \.artworkAccentColor, on: self),
            s.$currentLyricsOffsetMs.assign(to: \.currentLyricsOffsetMs, on: self),
            s.$pausedPositionMs.assign(to: \.pausedPositionMs, on: self),
            s.$currentDurationMs.assign(to: \.currentDurationMs, on: self),
        ]
    }

    // 悬浮歌词实际显示用的前景色——"跟随封面"外观模式开着且这首歌已经算出动态高亮色
    // 时用它,否则退回用户在"外观"设置里手选的固定色(没有封面数据、还没算出来、或者
    // 干脆没开这个模式都算这一档)。只被 LyricsOverlayView 消费,灵动岛/歌词窗口有
    // 各自独立的、故意不接入 ColorTheme 的前景色规则(见 SettingsView.swift"外观"分组
    // 的 footer 注释),不应该跟着"跟随封面"变。
    var displayForegroundColor: Color {
        let settings = AppSettings.shared
        if settings.followsCoverArt, let accent = artworkAccentColor {
            return accent
        }
        return settings.foregroundColor
    }
}
