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
    // isPlayingNow 的"缓收版":开始播放立刻为 true,停止播放要**静默满宽限期**才变 false。
    //
    // 给"要不要把悬浮窗/灵动岛收起来"这类决策用,不给歌词显示用 —— 歌词该在暂停的一瞬间
    // 就停住,而窗口不该。切歌间隙、seek、缓冲都会让 isPlayingNow 短暂掉 false,跟着它走
    // 就会看到灵动岛缩回刘海再弹出来、悬浮窗闪一下,而用户从头到尾都在听同一首歌。
    //
    // 只延后"停",不延后"起":恢复播放必须立刻有反应,那是用户刚刚按下的操作。
    //
    // ⚠️ 2026-08-16 实测的一个约束:当前 media-control 路径是 2 秒轮询,而"恢复播放"要
    // 等下一次轮询才被感知(实测 pause 被感知于 T,grace 于 T+2.0 到期,resume 直到 T+4.0
    // 才感知到),所以"宽限期内恢复→取消收起"这条路**目前几乎走不到**。真正在起作用的是
    // 另一半:切歌间隙/seek 这类 isPlayingNow 压根不掉 false 的抖动。等事件驱动
    // (media-control stream / Spotify 分布式通知)把感知延迟降到亚秒,取消路径才会真正生效
    // —— 到那时不必调这里的 2 秒,它本来就是按"用户感知得到的一口气"定的。
    @Published private(set) var isPlayingSmoothed: Bool = false
    // 2 秒:够盖住换歌间隙和常见的 seek/缓冲,又不至于让"真暂停"迟钝到让人以为没生效。
    private static let stopGracePeriod: TimeInterval = 2
    private var stopGraceWork: DispatchWorkItem?
    @Published private(set) var currentLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?
    @Published private(set) var hasLyricsContent: Bool = false
    // 联网查过了、明确是纯音乐,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var isCurrentTrackInstrumental: Bool = false
    @Published private(set) var currentTrackHasNoLyrics: Bool = false
    /// collector 报"网络不通,这一轮查不了"(见 CollectorStatus)。只有本地源有这个信号
    /// —— relay 模式下歌词是别的机器解析好推过来的,本机通不通网跟它无关。
    @Published private(set) var collectorNetworkDown: Bool = false
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
    // 同一个封面强调色的"深色背景"变体——在上面那个的基础上再保一道感知亮度下限
    // (见 LocalPlaybackSource.accentForDarkBackdrop 的注释:HSB 地板拦不住饱和冷色,
    // 纯蓝 luma 只有 0.07,贴在灵动岛的深色背景上区分度差)。只给灵动岛消费;桌面悬浮
    // 歌词的壁纸可能是浅色,继续用上面未提亮的 artworkAccentColor。
    @Published private(set) var notchAccentColor: Color?
    // 当前曲目已生效的歌词时间轴校正值,见 LocalPlaybackSource 同名属性的注释——直接
    // 转发权威值,不在这一层另外拼 key 重新查一遍(2026-08-03 之前这里是一个计算属性,
    // 自己拼了个 "\(artist)|\(title)" 去查 LyricsOffsetStore,跟实际存储用的
    // key(LyricsOffsetStore.trackKey,多一段内容指纹)对不上,查出来的永远是 0)。
    @Published private(set) var currentLyricsOffsetMs: Int = 0
    // "歌词窗口"进度条的暂停态冻结位置/时长,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?

    /// 当前这一行会显示多久(秒)。nil = 算不出来(还没播到第一句、没有歌词、或者这是
    /// 最后一句而且连曲目时长都不知道)。
    ///
    /// 菜单栏跑马灯拿它配速 —— 让一句歌词在换到下一句**之前**滚完,而不是永远按固定的
    /// 每秒 4 个字爬(见 MenuBarMarquee.pacing)。
    ///
    /// 用两句歌词时间戳之**差**,所以歌词时间轴校准(currentLyricsOffsetMs)不影响它:
    /// 那个偏移会同时加到两句上,差值不变。
    var currentLineDwellSeconds: Double? {
        guard let index = currentLineIndex, allLines.indices.contains(index) else { return nil }
        let startMs = allLines[index].timeMs
        let endMs: Int
        if allLines.indices.contains(index + 1) {
            endMs = allLines[index + 1].timeMs
        } else if let duration = currentDurationMs, duration > startMs {
            // 最后一句:用曲目时长兜底(尾奏通常还有几秒,足够滚完)。
            endMs = duration
        } else {
            return nil
        }
        let seconds = Double(endMs - startMs) / 1000
        // 时间戳异常(乱序/重复)时别返回 0 或负数 —— 调用方会拿它做除数。
        return seconds > 0.05 ? seconds : nil
    }

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
    /// 返回累加后的新偏移(毫秒),给快捷键那边闪一条提示用;不关心结果的调用方直接忽略。
    @discardableResult
    func nudgeLyricsOffset(by deltaMs: Int) -> Int {
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

    /// 用户动作序号,"喜欢"和"播放模式"各一份。
    ///
    /// 回读是**异步**的(要起一个 osascript 子进程,实测约 125ms),而这期间用户完全可能已经
    /// 点了按钮。没有这道守卫的话,一次在途的旧读数会把刚点出来的新状态盖回去 —— 最容易撞上
    /// 的时机就是"点击窗口把 App 激活"本身:激活触发一次刷新,紧接着的那一下点击落在按钮上,
    /// 读数回来正好把它抹掉。读之前记下序号,回来发现序号变了就整个丢弃。
    private var favoritedActionSeq = 0
    private var playbackModeActionSeq = 0
    private var volumeActionSeq = 0

    /// Music.app 自己的输出音量(0~100)。nil = 当前播放器没有这个概念/没拿到权限,
    /// 跟"喜欢""播放模式"同一个约定,界面据此整个不显示这个控件。
    @Published private(set) var soundVolume: Int?

    /// 音量写入的合流状态:同一时刻只允许一次 osascript 在飞,拖动期间新来的值只更新
    /// pendingVolumeTarget,等在飞的那次回来再补写最后一个值。
    ///
    /// ⚠️ 2026-08-14 用户反馈"拖音量条有卡顿感"。根因是滑杆的 DragGesture.onChanged 每来一个
    /// 鼠标移动事件就调一次 setVolume,而每次 setVolume 都 `Task.detached` 起一个
    /// **osascript 子进程**(实测单次往返 Music 90ms / Spotify 101ms)。拖一秒钟就是六十到
    /// 一百多个进程同时在飞,互相抢 CPU,主线程跟着被拖垮 —— 滑块自然跟不上手指。
    ///
    /// 为什么用"同一时刻只飞一次"而不是按固定间隔节流:写一次本来就要 ~100ms,这个规则会
    /// 自然收敛到约 10 次/秒,不需要另外拍一个魔数;而且"回来后若还有新值就再写一次"保证
    /// **最后松手的那个值一定落地**,不会停在中途某个位置。
    private var volumeWriteInFlight = false
    private var pendingVolumeTarget: Int?

    /// 静音之前的音量,用来再点一次时还原。
    ///
    /// 2026-08-09 用户反馈"静音键再点一次没反应" —— 原来那个按钮是无条件 setVolume(0),
    /// 已经是 0 的时候再点等于把 0 写成 0,什么都不会发生。静音本来就该是个**开关**。
    private var volumeBeforeMute: Int?

    /// 这一刻**实际在播**的是不是 Apple Music。
    ///
    /// ⚠️ 判定必须看这个,不能看 PlaybackPlayerPreference.current。设置里那一档可以是"自动
    /// 识别"(这台机器上就是),那时 current 不等于 .appleMusic,但实际在播的完全可能就是
    /// Apple Music —— 用设置值判断会让这颗心在"自动识别"下永远不出现。seek 那条路径早就
    /// 踩过同一个坑并用同一个信号修好了(见 LocalPlaybackSource.seek 里的 resolvedIsAppleMusic)。
    private var isAppleMusicPlayingNow: Bool {
        LocalPlaybackSource.shared.lastResolvedBundleID == PlaybackPlayer.appleMusic.bundleIdentifier
    }

    /// **这一刻实际在播**的那个播放器。注意不是设置里选的那个 —— 设置可能是"自动识别",
    /// 而这几个控件要按真正在播的那个 App 发指令。
    private var currentPlayer: PlaybackPlayer? {
        let bundleID = LocalPlaybackSource.shared.lastResolvedBundleID
        return PlaybackPlayer.allCases.first { $0 != .auto && $0.bundleIdentifier == bundleID }
    }

    /// 能接受「播放模式 / 音量」这两组扩展控制的当前播放器,不能就是 nil(按钮据此不显示)。
    ///
    /// 2026-08-14 从"只认 Apple Music"放开到"Apple Music + Spotify":Spotify 的 AppleScript
    /// 字典里 `sound volume` 和 `shuffling` 都是可写属性,能力是有的,只是当初接 Spotify 时
    /// 没有把这两处一并接上。QQ 音乐/网易云音乐仍然不行 —— 它们的 .app 里根本没有 .sdef。
    private var extendedControlPlayer: PlaybackPlayer? {
        guard let player = currentPlayer,
              MusicPlaybackController.supportsExtendedControls(player) else { return nil }
        return player
    }

    /// Apple Music 走 AppleScript 需要"自动化"权限;这里在后台刷新路径上检查它,**绝不弹窗**。
    /// Spotify 不走这个检查:本仓没有针对它的权限探测(读播放位置那条路也没有),权限没给时
    /// 脚本自然失败、读回 nil,按钮不显示 —— 跟"读不出来就不显示"是同一个降级路径。
    private func extendedControlPlayerForBackgroundRefresh() -> PlaybackPlayer? {
        guard let player = extendedControlPlayer else { return nil }
        if player == .appleMusic,
           !MusicAutomationPermission.check(askIfNeeded: false).isAuthorized { return nil }
        return player
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
        let seq = favoritedActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.favoritedState()
            await MainActor.run { [weak self] in
                guard let self, self.favoritedActionSeq == seq else { return }
                guard self.isFavorited != value else { return }
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
        guard let player = extendedControlPlayerForBackgroundRefresh() else {
            if playbackMode != nil { playbackMode = nil }
            return
        }
        let seq = playbackModeActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.playbackMode(for: player)
            await MainActor.run { [weak self] in
                guard let self, self.playbackModeActionSeq == seq else { return }
                guard self.playbackMode != value else { return }
                self.playbackMode = value
            }
        }
    }

    /// 重新读一次 Music.app 的音量。跟 refreshFavorited 同一套前置判断与守卫。
    func refreshVolume() {
        guard let player = extendedControlPlayerForBackgroundRefresh() else {
            if soundVolume != nil { soundVolume = nil }
            return
        }
        let seq = volumeActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.soundVolume(for: player)
            await MainActor.run { [weak self] in
                guard let self, self.volumeActionSeq == seq else { return }
                guard self.soundVolume != value else { return }
                self.soundVolume = value
            }
        }
    }

    /// 拖音量滑杆。跟"喜欢"一样先乐观更新再写回去 —— 滑杆必须跟着手指走,不能等
    /// osascript 往返(实测约 125ms)才动。
    func setVolume(_ value: Int) {
        guard let player = extendedControlPlayer else { return }
        let target = min(100, max(0, value))
        // 先乐观更新:滑杆必须跟着手指走,不能等 osascript 往返(~100ms)才动。
        soundVolume = target
        volumeActionSeq &+= 1
        // 真正的写入排队,不是每个鼠标事件都起一个子进程 —— 见 pendingVolumeTarget 的注释。
        pendingVolumeTarget = target
        pumpVolumeWrite(for: player)
    }

    /// 把排队的音量值写下去。同一时刻只允许一次在飞;写完如果期间又来了新值,立刻补写一次,
    /// 保证最后松手的那个值一定落地。
    private func pumpVolumeWrite(for player: PlaybackPlayer) {
        guard !volumeWriteInFlight, let target = pendingVolumeTarget else { return }
        pendingVolumeTarget = nil
        volumeWriteInFlight = true
        Task.detached(priority: .userInitiated) {
            // 权限弹窗只对 Apple Music 弹 —— 这是用户主动点的,该问就问;Spotify 没有对应的
            // 探测,直接发脚本,失败了走下面的回读纠正。
            // let(不是 var):var 会被下面的 MainActor.run 闭包捕获,Swift 6 模式下直接是错误。
            let ok: Bool
            if player == .appleMusic,
               await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                ok = false
            } else {
                ok = MusicPlaybackController.setSoundVolume(target, for: player)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.volumeWriteInFlight = false
                if self.pendingVolumeTarget != nil {
                    // 拖动还在继续(或刚结束但最后一个值还没写),补写最新的那个。
                    self.pumpVolumeWrite(for: player)
                } else if !ok {
                    // 只有写没被接受时才回读纠正乐观更新。写成功就**不回读**:Music.app 的
                    // getter 滞后于 setter,这时候读回来的是旧值,只会把刚画对的抹掉。
                    self.refreshVolume()
                }
            }
        }
    }

    /// 静音 / 取消静音。已经静音时还原到静音前那个音量;没有记录(比如一进来音量就是 0)
    /// 时给一个能听见的默认值,总好过点了没反应。
    func toggleMute() {
        guard let current = soundVolume else { return }
        if current > 0 {
            volumeBeforeMute = current
            setVolume(0)
        } else {
            setVolume(volumeBeforeMute ?? 50)
            volumeBeforeMute = nil
        }
    }

    /// 点一下切到下一档模式。跟 toggleFavorited 一样先乐观更新再回读,以实际结果为准。
    func cyclePlaybackMode() {
        guard let player = extendedControlPlayer else { return }
        // Spotify 的档位只有 列表 ↔ 随机:它的脚本字典里 repeating 是布尔,够不到"单曲循环"
        // (见 MusicPlaybackMode.next(allowsRepeatOne:))。
        let target = (playbackMode ?? .list)
            .next(allowsRepeatOne: MusicPlaybackController.supportsRepeatOne(player))
        playbackMode = target
        playbackModeActionSeq &+= 1
        Task.detached(priority: .userInitiated) {
            if player == .appleMusic,
               await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
                return
            }
            let wrote = MusicPlaybackController.setPlaybackMode(target, for: player)
            // 写成功就**不回读**:Music.app 的 getter 滞后于 setter(见 setPlaybackMode
            // 的注释),这时候读回来的是旧值,只会把刚画对的图标又抹掉。只有写没被接受时
            // 才需要问一遍真实状态,好把乐观更新纠回去。
            guard !wrote else { return }
            await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
        }
    }

    func toggleFavorited() {
        guard isAppleMusicPlayingNow else { return }
        let target = !(isFavorited ?? false)
        isFavorited = target
        favoritedActionSeq &+= 1
        Task.detached(priority: .userInitiated) {
            // 用 checkAppleMusicSafely 而不是 checkForCurrentPlayerSafely:后者在设置为
            // "自动识别"时会直接返回 true(它假定别的播放器不需要这个权限),而这里已经确认
            // 实际在播的就是 Apple Music,必须真的查一次权限,否则下面的 AppleScript 会静默失败。
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run { [weak self] in self?.refreshFavorited() }
                return
            }
            // 跟播放模式同一个道理:写被接受了就别回读,Music.app 的 getter 会滞后。
            guard !MusicPlaybackController.setFavorited(target) else { return }
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
                    self?.refreshVolume()
                },
            s.$artist.assign(to: \.artist, on: self),
            s.$album.assign(to: \.album, on: self),
            s.$isPlayingNow.assign(to: \.isPlayingNow, on: self),
            s.$isPlayingNow.sink { [weak self] playing in self?.updateSmoothedPlaying(playing) },
            s.$currentLine.sink { [weak self] line in
                logger.debug("coordinator currentLine updated: hasLine=\(line != nil) hasWords=\(line?.words != nil) hasMainText=\(line?.mainText != nil)")
                self?.currentLine = line
            },
            s.$nextLineText.assign(to: \.nextLineText, on: self),
            s.$anchor.assign(to: \.anchor, on: self),
            s.$hasLyricsContent.assign(to: \.hasLyricsContent, on: self),
            s.$isCurrentTrackInstrumental.assign(to: \.isCurrentTrackInstrumental, on: self),
            s.$currentTrackHasNoLyrics.assign(to: \.currentTrackHasNoLyrics, on: self),
            s.$collectorNetworkDown.assign(to: \.collectorNetworkDown, on: self),
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
            // 深色背景变体在同一条源上再派生一份——luma 提亮是纯数学,放在这一层跟
            // hex→Color 的转换一起做,每首歌只算一次,不在灵动岛 body 里反复算。
            s.$artworkAccentHex
                .map { hex -> Color? in
                    guard let hex, let ns = NSColor(hexStringWithAlpha: hex) else { return nil }
                    // NSColor(hexStringWithAlpha:) 用 srgbRed 构造,分量可以直接读,
                    // 不需要再过一次 usingColorSpace。
                    let lifted = LocalPlaybackSource.accentForDarkBackdrop(
                        r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
                    return Color(.sRGB, red: lifted.r, green: lifted.g, blue: lifted.b)
                }
                .assign(to: \.notchAccentColor, on: self),
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

    private func updateSmoothedPlaying(_ playing: Bool) {
        stopGraceWork?.cancel()
        stopGraceWork = nil
        if playing {
            if !isPlayingSmoothed { isPlayingSmoothed = true }
            return
        }
        // 已经是 false 就不必再排一次(重复的停止事件不该刷新宽限期起点)。
        guard isPlayingSmoothed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopGraceWork = nil
            // 到期时再核一次当下的真实状态:这段时间里可能已经恢复播放了。
            if !self.isPlayingNow { self.isPlayingSmoothed = false }
        }
        stopGraceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopGracePeriod, execute: work)
    }
}
