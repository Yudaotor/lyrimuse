import AppKit
import CoreImage
import Foundation
import Combine
import LyrimuseCore
import SwiftUI
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "coordinator")

/// 「歌词窗口」AM 式动画背景的一套预烘焙图层(烘焙见 PlaybackCoordinator
/// .bakeWindowBackgroundLayers,消费见 LyricsWindowView.WindowAnimatedBackground)。
/// class 而非 struct:视图用实例身份(===)当换歌交叉淡入/动画重启的触发键,
/// Equatable 按身份实现正是为了配 `.animation(value:)`。
final class WindowBackgroundLayers: Equatable {
    /// 暗底:封面压暗+重模糊,静态铺满。AM 背景的"黑位下限"来自这层。
    let base: NSImage
    /// 光斑层:各自取封面不同区域、径向羽化,与 poses 一一对应。
    let glows: [NSImage]
    /// 每层的确定性姿态/动画参数(seed 来自曲目标识,同一首歌永远同一布局)。
    struct GlowPose {
        let initialAngle: Double   // 初始角(度)
        let spinDuration: Double   // 转一整圈的周期(秒),负值反向
        let anchor: UnitPoint      // 旋转锚点(偏心,转动才带出"漂移"感)
        let scale: CGFloat         // scaledToFill 之上的额外放大
    }
    let poses: [GlowPose]
    /// 背景均色的色相/饱和度(2026-08-21):左栏次级元素(副行/时间/进度已播段)要做
    /// AM 式 vibrancy 染色 —— 从太阳之子截图逐通道反解,AM 的次级文字不是半透明白
    /// (那样三通道等效 α 应相等,实测 r0.74/g0.58/b0.49),而是**背景色相的亮化低饱和
    /// 版**。这里存烘焙后 base 的 CIAreaAverage(再乘 0.15 遮罩)转 HSB 的 h/s,亮度
    /// 各元素自定。
    let tintHue: Double
    let tintSaturation: Double
    /// 背景均色的**亮度**(已含视图层 0.15 黑遮罩的 ×0.85,即屏幕见到的亮度)。
    /// 2026-08-22 从"没人用的 v"转正:固定亮度档的 vibrancy 染色在亮封面(金色 bgV≈0.7)
    /// 上会撞上背景亮度直接隐形,文字类调用要靠它做最小对比度自适应(见 amVibrantColor)。
    /// 0 = 未知(取色失败),调用方按旧行为处理。
    let tintBrightness: Double

    init(base: NSImage, glows: [NSImage], poses: [GlowPose],
         tintHue: Double = 0, tintSaturation: Double = 0, tintBrightness: Double = 0) {
        self.base = base
        self.glows = glows
        self.poses = poses
        self.tintHue = tintHue
        self.tintSaturation = tintSaturation
        self.tintBrightness = tintBrightness
    }

    static func == (l: WindowBackgroundLayers, r: WindowBackgroundLayers) -> Bool { l === r }
}

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
    // 0.5 秒。2026-08-17 从 2 秒压到这里(用户反馈"暂停后缩回去太慢,一暂停就该缩")。
    //
    // 2 秒当初是按"盖住换歌间隙和常见的 seek/缓冲"取的,但收起动画本身还有 0.45 秒,
    // 加起来接近 2.5 秒 —— 用户按下暂停之后要盯着一个没在动的灵动岛等两秒多,明显像
    // 卡住了。0.5 秒仍然能吸收掉亚秒级的抖动(播放器切歌那一下的空档),而人对这个量级
    // 的延迟基本无感,观感就是"一暂停就收"。
    //
    // ⚠️ 别直接归零:归零意味着 isPlayingNow 任何一次瞬时 false 都会立刻触发收起/隐藏,
    // 换歌、seek、缓冲时就会看到灵动岛缩回去再弹出来。真要再快,先确认那些抖动在你的
    // 播放器上不存在。
    private static let stopGracePeriod: TimeInterval = 0.5
    private var stopGraceWork: DispatchWorkItem?
    /// userTogglePlayPause 乐观翻转后的对账定时(见那边注释)。
    private var optimisticReconcileWork: DispatchWorkItem?
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
    // 歌词窗口滚动锚(AM 式"滚动先于染色"),见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var scrollLineIndex: Int?
    // 单行展示面(灵动岛/菜单栏)专用的三个值,见 LocalPlaybackSource 同名属性与 CompactLyricLead。
    @Published private(set) var compactLine: SyncedLyricLine?
    @Published private(set) var compactShowsPlaceholder: Bool = false
    @Published private(set) var compactDwellMs: Int?
    /// compactLine 出现之后、开唱之前那段还没染色的提前量(毫秒)。见 CompactLyricLead.leadInMs。
    @Published private(set) var compactLeadInMs: Int?
    @Published private(set) var allLines: [LyricsWindowLine] = []
    // 歌词间奏点(歌词窗口的「•••」),见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published private(set) var currentGapIndex: Int?
    // 当前行逐字填色是否已定格(悬浮歌词的 TimelineView 停表条件),见 LocalPlaybackSource
    // 同名属性的注释。
    @Published private(set) var currentLineFillSettled: Bool = true
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
    /// 上面那张的**高清替代**,只在系统给的那份实在太小时才有值(否则 nil,消费方退回
    /// artworkImage)。给歌词窗口那张最大 460pt(Retina 下 920px)的封面卡用。
    ///
    /// 为什么需要:系统 Now Playing 的封面分辨率由播放器决定,而网易云 macOS 客户端只给
    /// **100×100**(2026-08-17 实测:7.3KB 的 JPEG,`get` 和 `get --now`、自带和 homebrew
    /// 两份 media-control 四种组合全都是这个尺寸,media-control 也没有"要大图"的参数)。
    /// 放到 920px 去显示等于放大 9 倍,就是用户报的"封面非常模糊"。
    /// **QQ 音乐客户端给 300×300**(2026-08-24 实测:27202 字节的 JPEG)—— 同一个毛病的
    /// 另一档,恰好卡在阈值边界上,见 lowResArtworkThreshold 里那条 ⚠️。
    ///
    /// 替代图来自 collector 已经存在缓存里的 `cover_url`(网易云/Apple/QQ 解析歌词时顺手
    /// 记下的),实测同两首歌能拿到 495×495 和 800×800;取用前还会过一遍
    /// `EnrichCacheReader.nativeSizedCoverURL` 把图源自己的尺寸档顶到最大(网易云摘 param、
    /// QQ 提到 800、Apple 提到 1200),否则 QQ 源那张存的也只有 300、白替一趟。
    ///
    /// ⚠️ 只在系统那份 ≤ lowResArtworkThreshold 时才替。系统那份才是"正在播的这一项"的
    /// 权威图;缓存里那张是按歌手/歌名/专辑匹配出来的,同名不同版本时可能是另一张封面。
    /// 播放器本来就给大图时(Apple Music)完全不碰这条路。
    @Published private(set) var highResArtworkImage: NSImage?
    /// 灵动岛 coverArt 背景用的**预烘焙模糊图**(2026-08-19 性能审计落地)。视图层原来
    /// 直接挂 `.blur(radius: 20)` —— 那是合成期实时滤镜,而灵动岛窗口播放期间因逐字填色/
    /// 音浪/跑马灯几乎永动,GPU 每次重合成都对同一张封面重算同一个模糊结果,封面每首歌
    /// 才换一次。改成封面到货时离线烘焙一次(见 rebakeBlurredArtwork),视图直接铺静态图。
    /// 源取 highResArtworkImage ?? artworkImage,跟视图层原来的取图口径一致;nil = 还没
    /// 烘出来/没有封面,视图回落深色渐变。
    @Published private(set) var blurredArtworkImage: NSImage?
    /// 「歌词窗口」AM 式动画背景的一套预烘焙图层(2026-08-20 第四轮重做,按反向工程的
    /// AM 真实架构替换此前的单张静态合成图,依据 Priva28 gist + AMLL,详见
    /// docs/features/07):暗底 + 3 份封面**不同区域**取色的羽化光斑,视图层 lighten
    /// (变亮)混合 + 慢速 GPU 旋转——lighten 让封面亮色区变成浮在暗底上的光斑(普通
    /// 叠加会把亮暗平均掉,怎么调都"平"),动画让背景像 AM 一样缓慢流动。烘焙仍是
    /// 离线一次,视图层只做变换动画,无合成期滤镜,性能纪律不破。
    @Published private(set) var windowBackgroundLayers: WindowBackgroundLayers?
    /// 上面那张高清替代的均值色(十六进制,格式同 LocalPlaybackSource.artworkAverageHex)。
    /// 有高清图时两个"跟随封面"强调色必须按它算:系统那份可能是网易云的灰底音符占位图,
    /// 界面上实际显示的是高清替代,强调色还按占位图算就是一团跟画面无关的灰。nil = 没有
    /// 高清替代,强调色回落到系统那份的均值(见下面两条管线的 highResHex ?? systemHex)。
    @Published private(set) var highResAverageHex: String?
    // 从封面均值算出来的动态高亮色,**桌面悬浮歌词专用**(已经从 LocalPlaybackSource
    // 转发的十六进制字符串转成 Color——LyrimuseCore 那一层不引入 SwiftUI,转换只能在
    // 这一层做,见 LocalPlaybackSource.artworkAverageHex 的注释)。供"跟随封面"外观模式
    // 用,见 displayForegroundColor。
    //
    // 这一侧的背景是壁纸/任意窗口,不能假定深浅,所以判据是"跟描边色够对比"而不是
    // "够亮"(见 LocalPlaybackSource.accentAgainstStroke);描边关着时才退回"够亮"。
    // ⚠️ 因此它依赖描边那两项设置——改描边颜色/开关会连带重算这个色,这是有意的。
    @Published private(set) var artworkAccentColor: Color?
    // 同一份封面均值的"深色背景"变体:先过 HSB 亮度地板(brightenedAccent),再补一道
    // 感知亮度下限(见 LocalPlaybackSource.accentForDarkBackdrop 的注释:HSB 地板拦不住
    // 饱和冷色,纯蓝 luma 只有 0.07,贴在灵动岛的深色背景上区分度差)。只给灵动岛消费 ——
    // 它的三种风格底色全是暗的,越亮越好;桌面那一侧正好相反,见上面。
    @Published private(set) var notchAccentColor: Color?
    // 当前曲目已生效的歌词时间轴校正值,见 LocalPlaybackSource 同名属性的注释——直接
    // 转发权威值,不在这一层另外拼 key 重新查一遍(2026-08-03 之前这里是一个计算属性,
    // 自己拼了个 "\(artist)|\(title)" 去查 LyricsOffsetStore,跟实际存储用的
    // key(LyricsOffsetStore.trackKey,多一段内容指纹)对不上,查出来的永远是 0)。
    @Published private(set) var currentLyricsOffsetMs: Int = 0
    // 上面那个总偏移里只属于当前这首歌的那一半,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var trackLyricsOffsetMs: Int = 0
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
    /// 单行展示面(灵动岛/菜单栏)的配速用时长:compactLine **总共会显示多久**。
    ///
    /// 算不出来时退回 currentLineDwellSeconds —— 主要是**最后一句**:引擎不知道曲目时长,
    /// 而那边有(用曲目时长兜底,尾奏通常还有几秒够滚完)。
    var compactDwellSeconds: Double? {
        if let ms = compactDwellMs, ms > 50 { return Double(ms) / 1000 }
        // 这条退路 2026-08-24 起**几乎不可达**:曲长已经喂进引擎(见 tickQuery 的
        // trackEndMs),最后一句的窗口也算得出来了,只剩"连曲长都不知道"这一种。
        //
        // ⚠️ 刻意**不**在它上面叠 compactLeadInSeconds:它按 currentLineIndex 取行,而
        // 提前量窗口里那是**已经唱完的上一句** —— 基数本来就错的,再补一段提前量只是把
        // 错数字算得更精细。真正的修法是上面那条(让引擎算得出来),不是修饰这条。
        return currentLineDwellSeconds
    }

    /// compactLine 出现之后、开唱之前那段还没染色的提前量(秒)。菜单栏跑马灯拿它当
    /// "起步前至少等多久" —— 没染色就不该滚,见 MenuBarMarquee.pacing 约束 4。
    /// 0 = 出现即开唱(行级 LRC 恒为 0,它从不抢跑)。
    var compactLeadInSeconds: Double {
        guard let ms = compactLeadInMs, ms > 0 else { return 0 }
        return Double(ms) / 1000
    }

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

    // 菜单栏面板「正在播放」卡右上角的来源角标(2026-08-19):此刻实际被认下来的播放器
    // 的人话名。认不出来/还没有任何快照给 nil,角标整个不显示 —— 别摆一个「未知」。
    // 不用单独发布:播放器切换必然伴随曲目/播放态变化,面板反正会跟着那些 @Published 重渲染。
    var resolvedPlayerDisplayName: String? {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return nil }
        return PlaybackPlayer.allCases.first { $0 != .auto && $0.bundleIdentifier == id }?.displayName
    }

    /// 上面那个的图标版(2026-08-19 用户拍板改图标):取**已安装播放器的真实 App 图标**。
    /// 查找/缓存逻辑收在 `AppIconResolver`(2026-08-25,跟另外两处消费点共用一份缓存,
    /// 见那个类型的类头注)。没装(理论上不可能:它正在放)/认不出来给 nil,角标不显示。
    var resolvedPlayerIcon: NSImage? {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return nil }
        return AppIconResolver.icon(forBundleID: id)
    }

    /// 点面板右上角的来源角标(2026-08-19 用户要求):把正在播放的那个播放器唤到前台。
    ///
    /// ⚠️ 第一版用 NSRunningApplication.activate()(在跑就激活、没在跑才 openApplication),
    /// 用户实测点了毫无反应:macOS 14 起的**协作式激活**会把「后台 accessory App 请求
    /// 激活别的 App」静默拒绝 —— 不报错、不打日志、就是不动。NSWorkspace.openApplication
    /// 是系统认可的路径:对已在跑的 App 等价于"带到前台"(open -b 同款行为),没在跑就
    /// 顺便启动,一条路两件事。
    func openResolvedPlayerApp() {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else {
            logger.notice("openResolvedPlayerApp: no resolved player")
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            logger.notice("openResolvedPlayerApp: no app for \(id, privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                logger.notice("openResolvedPlayerApp: \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            } else {
                logger.notice("openResolvedPlayerApp: activated \(id, privacy: .public)")
            }
        }
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

    // 全局歌词时间轴基准 —— 对所有歌生效,跟上面那个单曲微调叠加(见
    // LyricsOffsetStore.globalOffsetMs)。设置页那个控件走这里。
    var globalLyricsOffsetMs: Int { LyricsOffsetStore.shared.globalOffsetMs }

    /// 写走这里而不是直接写 store:改完要让**正在播的这首**立刻用上新值,那一步在
    /// LocalPlaybackSource 里(见 setGlobalLyricsOffset)。读则直接观察
    /// LyricsOffsetStore.shared —— 它是 ObservableObject,没在放歌时也能刷新界面。
    func setGlobalLyricsOffset(_ ms: Int) {
        LocalPlaybackSource.shared.setGlobalLyricsOffset(ms)
    }

    // 「按播放器」那一层(2026-08-21 加)—— 同一个控件上的下拉框选中具体播放器时,改的是这层。
    // 读写各走哪边的理由跟上面全局那层完全一致。
    func playerLyricsOffsetMs(forBundleID bundleID: String) -> Int {
        LyricsOffsetStore.shared.playerOffset(forBundleID: bundleID)
    }

    func setPlayerLyricsOffset(_ ms: Int, forBundleID bundleID: String) {
        LocalPlaybackSource.shared.setPlayerLyricsOffset(ms, forBundleID: bundleID)
    }

    /// 这一刻真正在播的那个 App 的 bundle id —— 设置页拿它在下拉框里标出"正在播放"那一项,
    /// 用户不用自己猜"我现在这首是哪个 App 在放"。故意不做成 @Published(理由见
    /// LocalPlaybackSource.lastResolvedBundleID):设置页本来就有 2 秒的轮询在跑。
    var resolvedPlayerBundleID: String? { LocalPlaybackSource.shared.lastResolvedBundleID }

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

    /// 换歌时的三项后台回读(喜欢/播放模式/音量)——合并成**一次** osascript 子进程
    /// (2026-08-20 性能审计:原来三个独立 fork + 三次 TCC 检查,喜欢那项的属性候选循环
    /// 最坏还要两趟)。三个 seq 守卫原样保留:期间用户点了喜欢/切了模式/拖了音量,对应
    /// 项的回读结果单独作废,不牵连另两项。
    func refreshExtendedControls() {
        let includeFavorited = isAppleMusicPlayingNow
            && MusicAutomationPermission.check(askIfNeeded: false).isAuthorized
        guard let player = extendedControlPlayerForBackgroundRefresh() else {
            if isFavorited != nil { isFavorited = nil }
            if playbackMode != nil { playbackMode = nil }
            if soundVolume != nil { soundVolume = nil }
            return
        }
        let favSeq = favoritedActionSeq
        let modeSeq = playbackModeActionSeq
        let volSeq = volumeActionSeq
        Task.detached(priority: .utility) {
            let state = MusicPlaybackController.extendedControlsState(
                for: player, includeFavorited: includeFavorited && player == .appleMusic)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.favoritedActionSeq == favSeq {
                    let value = includeFavorited ? state.favorited : nil
                    if self.isFavorited != value { self.isFavorited = value }
                }
                if self.playbackModeActionSeq == modeSeq, self.playbackMode != state.mode {
                    self.playbackMode = state.mode
                }
                if self.volumeActionSeq == volSeq, self.soundVolume != state.volume {
                    self.soundVolume = state.volume
                }
            }
        }
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
        // 相等守卫:@Published 是 willSet 语义,赋相同的值照样广播 objectWillChange。拖动中
        // 相邻鼠标事件量化到同一个整数(慢速微调/抖动/拖出 0~100 两端被 clamp)时,这些纯
        // 重复赋值会白白打醒 coordinator 的全部观察面 —— 下面的合流机制只保护 osascript
        // 那一半,@Published 这一半靠这里。三条 refresh 回读路径早就有同款守卫,唯独这条
        // 用户手指驱动的最高频写入漏了。
        if soundVolume != target { soundVolume = target }
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
        setPlaybackMode(target)
    }

    /// 当前播放器够不够得到「单曲循环」档(Spotify 的脚本接口只有 repeating 布尔,够不到)。
    /// 歌词窗口的「循环」按钮读不到这一档时整颗不显示,别摆一个落不了地的开关。
    var playbackModeSupportsRepeatOne: Bool {
        guard let player = extendedControlPlayer else { return false }
        return MusicPlaybackController.supportsRepeatOne(player)
    }

    /// 直接设到某一档(2026-08-19 歌词窗口按 Apple Music 排布把三态拆成「随机/循环」两颗
    /// 互斥按钮,要的是"点谁设谁"而不是循环下一档)。乐观更新/权限检查/写成功不回读,
    /// 跟 cyclePlaybackMode 完全同一套取舍。
    func setPlaybackMode(_ target: MusicPlaybackController.MusicPlaybackMode) {
        guard let player = extendedControlPlayer else { return }
        // 播放器够不到的档位静默降为列表,别让乐观更新画出一个永远写不进去的图标。
        // (repeatAll 跟 repeatOne 同一道闸:Spotify 的 repeating 布尔写得进读不回。)
        let resolved: MusicPlaybackController.MusicPlaybackMode =
            ((target == .repeatOne || target == .repeatAll)
                && !MusicPlaybackController.supportsRepeatOne(player))
            ? .list : target
        playbackMode = resolved
        playbackModeActionSeq &+= 1
        Task.detached(priority: .userInitiated) {
            if player == .appleMusic,
               await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
                return
            }
            let wrote = MusicPlaybackController.setPlaybackMode(resolved, for: player)
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
        // 桌面悬浮歌词那份封面取色要跟着描边设置一起算(见下面 artworkAccentColor 那条
        // 订阅),所以这里也要拿到 AppSettings。
        let settings = AppSettings.shared
        s.start()
        cancellables = [
            s.$title.assign(to: \.title, on: self),
            // 换歌就重读一次"喜欢"状态。用 title+artist 组合去重而不是只看 title:同名不同
            // 歌手的曲目(翻唱/合辑里很常见)只看 title 会被当成同一首,漏掉一次刷新。
            s.$title.combineLatest(s.$artist)
                .map { "\($0)|\($1)" }
                .removeDuplicates()
                .sink { [weak self] _ in
                    // 三项合并成一次 osascript 回读(2026-08-20 性能审计),见
                    // refreshExtendedControls;单项 refresh 保留给写后回读/视图 onAppear。
                    self?.refreshExtendedControls()
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
            s.$scrollLineIndex.assign(to: \.scrollLineIndex, on: self),
            s.$compactLine.assign(to: \.compactLine, on: self),
            s.$compactShowsPlaceholder.assign(to: \.compactShowsPlaceholder, on: self),
            s.$compactDwellMs.assign(to: \.compactDwellMs, on: self),
            s.$compactLeadInMs.assign(to: \.compactLeadInMs, on: self),
            s.$allLines.assign(to: \.allLines, on: self),
            s.$lyricsGapMarkers.assign(to: \.lyricsGapMarkers, on: self),
            s.$currentGapIndex.assign(to: \.currentGapIndex, on: self),
            s.$currentLineFillSettled.assign(to: \.currentLineFillSettled, on: self),
            s.$artworkData.assign(to: \.artworkData, on: self),
            // 解码在这里做一次,消费方(灵动岛顶行小封面/模糊背景)直接拿 NSImage,不在
            // view body 里反复解同一张图,见 artworkImage 声明处的注释。@Published 的
            // willSet 语义让这两条订阅在同一次调用里同步跑完,artworkData 和 artworkImage
            // 不会跨渲染帧不一致(SwiftUI 在这一轮 runloop 结束时才真正重绘)。
            s.$artworkData
                .map { $0.flatMap { NSImage(data: $0) } }
                .assign(to: \.artworkImage, on: self),
            // 高清封面:换歌或换封面之后重找一次,见 highResArtworkImage 的注释。
            //
            // ⚠️ debounce 不是为了省请求,是为了**避开 @Published 的 willSet 时机**:
            // 这四个属性各自的订阅回调都跑在"值还没落库"的那一刻,回调里读 self 的其它
            // 属性可能读到上一首的值(这个项目为这个时机踩过两次坑)。等 300ms 之后所有
            // willSet 都已落定,refreshHighResCover() 再去读一份自洽的快照。
            // 这 300ms 用户看不见 —— 系统那张小图在第一帧就已经显示了。
            Publishers.CombineLatest4(s.$title, s.$artist, s.$album, s.$artworkData)
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _, _, _, _ in self?.refreshHighResCover() },
            // 第二个触发点(2026-08-24):**缓存里多了东西**也要补查一次。
            //
            // 上面那条只在 曲目/封面字节 变化时跑,而 collector 解析一首没听过的歌要好几秒
            // (实测「七月上」13:52:52 开播、13:53:00 才写进 cover_url,晚 8 秒)—— 换歌后
            // 300ms 那一次必然查空,然后**永不重试**,整首歌都停在系统那张 100×100 上。
            // 这就是用户 2026-08-24 报「网易云这个封面依然很糊」的真根因(那之前修的是 QQ
            // 恰好卡在 300px 阈值边界那个**另一个**问题,两者独立)。对照组:同一张专辑里
            // 被"同专辑预取"提前解析好的曲目,换歌后 1 秒就抓到了 640px 那张、是清晰的。
            //
            // ⚠️ 必须 onlyIfMissing —— refreshHighResCover 开头会 clearHighRes(),已经拿到
            // 高清图时再跑一遍就是"清空→重设",而 highResArtworkImage 挂着 0.5s 交叉淡入,
            // 表现成封面每隔几秒闪一下。而 collector 写缓存是常态(每解析一首歌都写)。
            s.$enrichContentVersion
                .dropFirst() // 启动时那一次不是"新解析出来的",换歌那条路已经覆盖
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.refreshHighResCover(onlyIfMissing: true) },
            // 两个消费面各自从**同一份原始均值**派生自己那一版,处理都是纯数学,放在这一层
            // 跟 hex→Color 的转换一起做,每首歌只算一次,不在两边的 body 里反复算。
            // (十六进制字符串必须在这一层才转得成 Color——LocalPlaybackSource 所在的
            // LyrimuseCore 不引入 SwiftUI,见该属性定义处的注释。)
            //
            // 桌面悬浮歌词:背景未知,判据是"跟描边色够对比",所以要跟着描边设置一起算。
            // 两条管线都优先吃高清替代的均值(highResHex ?? systemHex),理由见
            // highResAverageHex 的注释:强调色要跟实际显示的那张图对上。
            Publishers.CombineLatest4(
                s.$artworkAverageHex,
                $highResAverageHex,
                settings.$textStrokeEnabled,
                settings.$textStrokeColorHex
            )
            .map { systemHex, highResHex, strokeOn, strokeHex -> Color? in
                guard let hex = highResHex ?? systemHex,
                      let ns = NSColor(hexStringWithAlpha: hex) else { return nil }
                // NSColor(hexStringWithAlpha:) 用 srgbRed 构造,分量可以直接读,
                // 不需要再过一次 usingColorSpace。
                let (r, g, b) = (ns.redComponent, ns.greenComponent, ns.blueComponent)
                // 描边关着(或者淡到基本不存在)时字直接压在未知背景上,没有"跟谁对比"
                // 可言 —— 退回那条保证够亮的老规则,这也是这个场景 2026-08-17 之前的行为。
                // 0.5 这个门槛是取舍不是测量:半透明描边的实际观感取决于它背后是什么,
                // 而那正是这一层不知道的东西。
                guard strokeOn,
                      let stroke = NSColor(hexStringWithAlpha: strokeHex),
                      stroke.alphaComponent >= 0.5
                else {
                    let lifted = LocalPlaybackSource.brightenedAccent(r: r, g: g, b: b)
                    return Color(.sRGB, red: lifted.r, green: lifted.g, blue: lifted.b)
                }
                let fitted = LocalPlaybackSource.accentAgainstStroke(
                    r: r, g: g, b: b,
                    strokeR: stroke.redComponent,
                    strokeG: stroke.greenComponent,
                    strokeB: stroke.blueComponent)
                return Color(.sRGB, red: fitted.r, green: fitted.g, blue: fitted.b)
            }
            // 输出去重(2026-08-20):四个输入里任何一个抖动(高清 hex 的 nil 重赋值是
            // 常客)都会重发,而算出来的颜色多数时候没变——Color? 是 Equatable,挡在
            // assign 前面,别让 coordinator 的全部观察面白挨一轮 objectWillChange。
            .removeDuplicates()
            .assign(to: \.artworkAccentColor, on: self),
            // 灵动岛:背景永远深色,判据是"够亮"——先过 HSB 亮度地板,再补一道感知亮度
            // 下限(饱和冷色 HSB 地板拦不住,见 accentForDarkBackdrop)。
            Publishers.CombineLatest(s.$artworkAverageHex, $highResAverageHex)
                .map { systemHex, highResHex -> Color? in
                    guard let hex = highResHex ?? systemHex,
                          let ns = NSColor(hexStringWithAlpha: hex) else { return nil }
                    let base = LocalPlaybackSource.brightenedAccent(
                        r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
                    let lifted = LocalPlaybackSource.accentForDarkBackdrop(
                        r: base.r, g: base.g, b: base.b)
                    return Color(.sRGB, red: lifted.r, green: lifted.g, blue: lifted.b)
                }
                .removeDuplicates() // 同 artworkAccentColor 那条的理由
                .assign(to: \.notchAccentColor, on: self),
            s.$currentLyricsOffsetMs.assign(to: \.currentLyricsOffsetMs, on: self),
            s.$trackLyricsOffsetMs.assign(to: \.trackLyricsOffsetMs, on: self),
            s.$pausedPositionMs.assign(to: \.pausedPositionMs, on: self),
            s.$currentDurationMs.assign(to: \.currentDurationMs, on: self),
            // 灵动岛 coverArt 背景的模糊图,封面(系统份或高清替代)一变就重烘一次 ——
            // 见 blurredArtworkImage 声明处的注释。sink 用参数值,不回读属性(willSet 时机)。
            Publishers.CombineLatest($artworkImage, $highResArtworkImage)
                .map { system, high in high ?? system }
                // 恒等去重(2026-08-20 性能审计):高清封面刷新路径会对 highResArtworkImage
                // 反复赋 nil(每次换歌 1-2 次),CombineLatest 每次都发——源图引用没变时
                // 重烘两份 720px 高斯模糊纯属白做,还白触发下游 0.5s 交叉淡入。
                .removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] source in self?.rebakeBlurredArtwork(from: source) },
        ]
    }

    private var blurBakeTask: Task<Void, Never>?
    // CIContext 创建不便宜且线程安全,进程级复用一个(只在下面的后台烘焙里用)。
    nonisolated(unsafe) private static let blurBakeContext = CIContext()

    private func rebakeBlurredArtwork(from source: NSImage?) {
        blurBakeTask?.cancel()
        blurBakeTask = nil
        guard let source,
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            if blurredArtworkImage != nil { blurredArtworkImage = nil }
            if windowBackgroundLayers != nil { windowBackgroundLayers = nil }
            return
        }
        // 光斑取区/姿态的种子:同一首歌每次烘出同一布局(烘焙里不允许真随机——换歌
        // 交叉淡入的触发键是图层实例,布局还随机跳会被看成"背景闪变")。跨进程稳定,
        // 用 FNV 而不是 hashValue(SipHash 每次启动换 key)。
        let s = LocalPlaybackSource.shared
        let seed = Self.stableSeed("\(s.artist)|\(s.title)")
        blurBakeTask = Task { [weak self] in
            // CoreImage 渲染放后台,跟 refreshHighResCover 里算均值色同一套写法。
            // 两份一起烘(灵动岛 + 歌词窗口,参数见各自 @Published 的注释),共享一次
            // 源图解码;单次烘焙毫秒级,合在一个任务里不值得再拆。
            let baked = await Task.detached(priority: .utility) {
                (notch: Self.bakeBackgroundBlur(cgImage: cg, targetWidth: 720, sigma: 40, saturation: nil),
                 window: Self.bakeWindowBackgroundLayers(cgImage: cg, seed: seed))
            }.value
            guard let self, !Task.isCancelled else { return }
            if let notch = baked.notch { self.blurredArtworkImage = notch }
            if let window = baked.window { self.windowBackgroundLayers = window }
        }
    }

    nonisolated private static func stableSeed(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// 「歌词窗口」AM 式动画背景的图层烘焙(2026-08-21 第六轮:同封面同屏对拍定稿)。
    /// 机理(五轮真机对照+一次同屏定量对拍逐步坐实):**AM 的背景 ≈ 封面的宏观色彩布局,
    /// 但明度布局被抹平** —— 同一封面(破气球/100种生活)同屏对拍量出 AM 四采样区 V50 全在
    /// 0.22~0.31(封面本身左暗右亮),色相却逐区各异;我们此前保留明度布局,表现为"左缘
    /// 死黑 + 黄斑突兀"(黄斑区局部幅度 0.114 vs AM 0.043,左缘 V50 0.157 vs 0.306,
    /// 调 EV 根本够不着)。固化的选择:
    /// - 宏观场 = 6×6 面积平均降采样 + **逐格乘法亮度归一化**(RGB × mean/L,homog 0.55
    ///   部分归一,系数夹 [0.4, 3.5] 防近黑格爆噪)再放大,σ35 高斯只融格边。乘法保
    ///   色相/饱和 —— 加法提黑会灰掉(AM 暗区 S 仍有 0.62);纯高斯的老两难照旧:σ 大
    ///   混泥、σ 小见人形,所以仍是"降采样出场、高斯只融边"。
    /// - 逐格**饱和度**归一 + 少数派**色相**收拢(2026-08-22 Addison 亮封面五轮对拍,
    ///   详见各段落内注释):S 抬到 p75×1.5(cap 0.95)防白纱/留白灰化;偏主色相(S²
    ///   加权圆均值)>60° 的格子夹回 ±60°(青 logo 格→橄榄,AM 的场=一个主色系+近亲
    ///   点缀);灰阶封面两步都自动 no-op。
    /// - 成场后 CIVibrance 0.4 + **闭环饱和度乘子**(= satTarget ÷ 融合后场的实测均值 S,
    ///   clamp [0.6, 2.2]):σ35 融合互混+光斑 lighten 会磨掉 ~30% 饱和,固定乘子对
    ///   混合结构不同的封面不可能都对 —— 08-21 对拍量出 AM S50 0.42~0.72、定 0.85;
    ///   08-22 亮封面上同一个 0.85 只到 0.50~0.65(AM 0.63~0.97)。闭环后鲜艳均匀
    ///   封面乘子自动 <1(接管 0.85 的职责),灰化结构自动 >1。
    /// - 底色 EV −0.15:旧 −1.2 是"保留明度布局"时代为压亮斑留的,归一化后只需轻压。
    /// - 光斑仍锚**原始**最亮格(归一化前的亮度),羽化外沿 0.7W(旧 0.40 有可见轮廓,
    ///   AM 没有独立光斑,只有柔和的色场渐变)。
    /// - 视图层 3 层 lighten α0.25 摆动照旧(对拍显示 α 在归一化的平场上影响很小)。
    /// 定量:四区 V5/V50/V95/S50/H50 加权 loss 从旧参数 1.41 → 0.79(工具 scratchpad
    /// bgbake6 + sweep_pair6)。残余主要是 AM 各区内部还有 0.10~0.21 的柔和起伏(其动画
    /// 瞬间的相位),我们单帧偏平 —— 由摆动动画在时间维上补。
    nonisolated private static func bakeWindowBackgroundLayers(cgImage: CGImage, seed: UInt64) -> WindowBackgroundLayers? {
        let W: CGFloat = 720
        let frame = CGRect(x: 0, y: 0, width: W, height: W)

        // 6×6 面积平均降采样 + 逐格乘法亮度归一化(见函数头注释)。CGContext 自管缓冲
        // (data: nil),draw 之后直接原位改写像素再 makeImage —— 别用 data: &数组 那种
        // 临时指针写法(仅初始化调用期间有效,后续使用是未定义行为)。
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cgctx = CGContext(data: nil, width: 6, height: 6, bitsPerComponent: 8,
                                    bytesPerRow: 6 * 4, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        cgctx.interpolationQuality = .medium
        cgctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 6, height: 6))
        guard let data = cgctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: 36 * 4)
        // 归一化用的亮度取**归一化前**的原始格亮度;光斑锚点也用它(场归一化之后
        // "最亮格"就没意义了)。
        var cellLuma = [Double](repeating: 0, count: 36)
        for i in 0..<36 {
            let o = i * 4
            cellLuma[i] = (0.299 * Double(px[o]) + 0.587 * Double(px[o + 1]) + 0.114 * Double(px[o + 2])) / 255
        }
        let meanLuma = cellLuma.reduce(0, +) / 36
        let homog = 0.55
        for i in 0..<36 {
            let f0 = meanLuma / max(0.02, cellLuma[i])
            let f = (1 - homog) + homog * min(3.5, max(0.4, f0))
            for ch in 0..<3 {
                px[i * 4 + ch] = UInt8(min(255, Double(px[i * 4 + ch]) * f))
            }
            px[i * 4 + 3] = 255
        }
        // 逐格**饱和度**归一化(2026-08-22,Addison 亮封面同帧对拍):AM 的背景饱和度
        // 跟随封面的**鲜艳端**而不是面积均值 —— 白纱/留白参与 6×6 平均会把格子灰化
        // (实测 AM 各区 S50 0.63~0.97,我们 0.13~0.65,左上区整个发灰)。与上面的亮度
        // 归一化对称:各格 S 向全场 p75 鲜艳端部分归一(satHomog 0.6),保 H/V
        // (c' = max−(max−c)×k 只放大与 max 的距离)。灰阶封面 p75 本身≈0 → 自动
        // 不动,不伤黑白封面;中饱和封面 p75≈均值 → 变化很小,不动摇 08-21 的对拍校准。
        var cellSat = [Double](repeating: 0, count: 36)
        for i in 0..<36 {
            let o = i * 4
            let mx = Double(max(px[o], max(px[o + 1], px[o + 2])))
            let mn = Double(min(px[o], min(px[o + 1], px[o + 2])))
            cellSat[i] = mx > 0 ? (mx - mn) / mx : 0
        }
        // 少数派色相向主色相收拢(2026-08-22 五轮实拍):封面小块青色 logo 的格子被下面
        // 的饱和归一放大成刺眼纯绿斑 —— AM 的场是"一个主色系 + 近亲色点缀",同帧对拍
        // 它同区是暖橄榄绿。主色相 = S² 加权圆均值;偏离 >60° 的格子夹回主色相 ±60°
        // (青→橄榄,保留点缀、不抹掉),S/V 不动。单色/灰阶封面各格本就贴着主色相或
        // S≈0 被跳过,自动 no-op。
        //
        // ⚠️ 2026-08-22 用户实测反例推翻了当时"真双色封面被拉向均值,AM 的场本来就读作
        // 一个色系"这条假设:圣米歇尔山封面(蓝天+暖色古堡+倒影,两大色系面积相当)被
        // 拉成一片脏绿,AM 参考图是天空蓝到暖棕的自然过渡,并没有被拉成同一色系。离屏
        // 复现实测坐实——hDom≈185°(蓝天,S² 权重占优),暖色城堡格(H22~41°)全部被夹到
        // 124°(纯绿),因为"偏离 >60° 就夹"这条判据只看角度、不看这批离群格子占的权重
        // 有多大:小块 logo 杂色天然只占总权重几个百分点,但这张封面的暖色区占了到
        // ~27%——早就不是"少数派",是构图里第二个真实色系。加一道"离群到底占多少权重"
        // 的判据:只有离群权重明显是小头(<20%)时才当杂色拉回来;逼近对半分的两大色系
        // 直接放行,交给下面 σ35 高斯模糊做自然的空间过渡(蓝→绿→棕,而不是硬夹出一片
        // 假色),这也更贴近圣米歇尔山这类反例里 AM 自己的观感。
        func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
            let mx = Swift.max(r, g, b), mn = Swift.min(r, g, b), d = mx - mn
            var h = 0.0
            if d > 0 {
                if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
                h *= 60
                if h < 0 { h += 360 }
            }
            return (h, mx > 0 ? d / mx : 0, mx)
        }
        func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
            let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let i = Int(hh), f = hh - Double(i)
            let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
            switch i {
            case 0: return (v, t, p)
            case 1: return (q, v, p)
            case 2: return (p, v, t)
            case 3: return (p, q, v)
            case 4: return (t, p, v)
            default: return (v, p, q)
            }
        }
        var hueSin = 0.0, hueCos = 0.0
        for i in 0..<36 where cellSat[i] > 0.05 {
            let o = i * 4
            let (h, s, _) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
            hueSin += sin(h * .pi / 180) * s * s
            hueCos += cos(h * .pi / 180) * s * s
        }
        // 1 = 色相一致、正常走既有的饱和度放大;越接近 0 越是"噪声凑巧不为零",
        // 下面 satTarget/satMul/CIVibrance 按它收着放大,见下方大段注释。
        var hueCoherenceScale = 1.0
        if hueSin != 0 || hueCos != 0 {
            let hDom = atan2(hueSin, hueCos) * 180 / .pi
            // 色相一致度(2026-08-22,窦靖童《春游》灰阶反例坐实):S² 加权圆均值向量的
            // 合成模长 / 总权重——多格色相互相印证(同一色系)时接近 1,多格色相彼此
            // 抵消(蓝天一点、暖灰一点,方向各异)时接近 0。上面这套 hDom/offHueFraction
            // 只管"要不要把离群格子夹回来",没管"这个 hDom 本身有多可信"——一张几乎
            // 无彩的封面(几格发蓝、多格发暖灰,S 全在 0.06~0.22)也能算出一个看似成立
            // 的 hDom,但那只是噪声方向凑巧不为零,不代表真有这个颜色。实测这张灰阶
            // 鹅照 coherence≈0.27,远低于圣米歇尔山(两大真实色系)的 0.47 和 MJ 红棕
            // 封面(单一色系)的 0.59——三者离屏复现坐实这条线能分开"真的没有主色"和
            // "有两个/一个真主色"。低于参考值时按比例收着后面的饱和度放大,别把噪声级别
            // 的偏色也当真色去放大(下面 satTarget/satMul/CIVibrance 三处一起收)。
            var totalHueWeight = 0.0, offHueWeight = 0.0
            for i in 0..<36 where cellSat[i] > 0.05 {
                let o = i * 4
                let (h, s, _) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
                var d = h - hDom
                while d > 180 { d -= 360 }
                while d < -180 { d += 360 }
                totalHueWeight += s * s
                // 只把"够近、值得拉回来"的离群格子计入这道占比闸——上限 120° 见下面
                // clamp 循环同一道判据的注释(色轮对面的真补色本来就不进这套机制,不该
                // 因为它占比大就反过来拦住"该拉的近似色"被拉)。
                if abs(d) > 60 && abs(d) <= 120 { offHueWeight += s * s }
            }
            let offHueFraction = totalHueWeight > 0 ? offHueWeight / totalHueWeight : 0
            if totalHueWeight > 0 {
                let resultantMag = (hueSin * hueSin + hueCos * hueCos).squareRoot()
                let coherenceLinear = min(1, (resultantMag / totalHueWeight) / 0.4)
                hueCoherenceScale = coherenceLinear * coherenceLinear
            }
            if offHueFraction < 0.2 {
                for i in 0..<36 where cellSat[i] > 0.05 {
                    let o = i * 4
                    let (h, s, v) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
                    var d = h - hDom
                    while d > 180 { d -= 360 }
                    while d < -180 { d += 360 }
                    // 上限 120°(2026-08-23 用户截图坐实的第二个反例):《你瞒我瞒》雪山蓝天
                    // (离主色相约 150~156°,offHueFraction 算出 19.8%——刚好卡在 20% 那条
                    // 线内侧一点点,仍然触发了collapse)被 ±60 硬夹成刺眼的桃红/紫红——
                    // "偏离 60°就等距拉近 60°"这套位移量本来是照着"小块 logo 杂色"标定的
                    // (原注释的例子是青色 logo 拉成暖橄榄绿,两者本就是同一色系的近亲,
                    // 相隔本该不远);对色轮对面的真补色(蓝 vs 暖棕,>120°)套用同一个
                    // 固定位移,新色相落在哪全看 d 的正负号,跟原色、跟主色相都不沾边,
                    // 输出的是一个随机撞上的颜色,不是"往回拉近"。只处理 60°~120° 这个
                    // "近似色被饱和归一放大跑偏"的窗口,超过 120° 的真补色原样放行,交给
                    // σ35 高斯模糊做自然过渡(跟 offHueFraction≥20% 那条分支一个道理)。
                    guard abs(d) > 60, abs(d) <= 120 else { continue }
                    let (r, g, b) = hsvToRGB(hDom + (d > 0 ? 60 : -60), s, v)
                    px[o] = UInt8(min(255, max(0, r * 255)))
                    px[o + 1] = UInt8(min(255, max(0, g * 255)))
                    px[o + 2] = UInt8(min(255, max(0, b * 255)))
                }
            }
        }
        let satP75 = cellSat.sorted()[26]
        // ⚠️⚠️ 2026-08-23 推翻重标:上面这些"×1.5"系的注释、以及为了压住它反复打的三个
        // 补丁(少数派色相收拢/角度上限/hueCoherenceScale)全都是在给一个**方向错了**的
        // 基础倍率止血。真根因直到这天才找到——用户要求"自己去多播几首歌,把 Apple
        // Music 原生「播放中」窗口的背景跟我们的取色结果对比着截图",于是这轮直接控制
        // 真机 Music.app(菜单「窗口→播放中」能调出跟 AM 一模一样的原生沉浸态)播了 5 首
        // 色彩特征完全不同的歌(你瞒我瞒/黑夜/Get on the Boat/Earth Song/The Beautiful
        // Ones),把 AM 真实截图和这份 6×6 算法各自跑出来的饱和度做了正面比对:
        //
        //   封面           源图 satP75   AM 真实输出 p75    比值(AM÷源)
        //   你瞒我瞒         0.236         0.14              0.593
        //   黑夜             0.577         0.25              0.433
        //   Get on the Boat  0.769         0.51              0.663
        //   Earth Song       0.458         0.21              0.459
        //   Beautiful Ones   0.380         0.24              0.632
        //                                            均值 ≈ 0.56
        //
        // AM 的背景饱和度是源图鲜艳端的**一半左右**,不是 1.5 倍——"×1.5"这个方向从
        // 一开始就反了,这也是本条注释历史上四次打补丁(发绿→发粉→夹错色相→依然偏
        // 鲜艳)始终按下葫芦浮起瓢的原因:补丁全在压一个基数过大 3 倍的放大器,压得住
        // 一张封面就压不住下一张。
        //
        // ⚠️ 上面那版比值(均值 0.55)是拿"整张背景的**单点面积均值**"(CIAreaAverage,
        // 一张图揉成一个色)去跟 AM 截图的均值比;换成跟人眼实际观感更接近的**网格
        // 采样**(在 AM 截图和我们自己烘焙的图上各打 25 个点算 p75)重新核对,发现
        // 0.55 仍然让个别封面(你瞒我瞒、Beautiful Ones)的网格 p75 比 AM 真实值高
        // 出 1.5~2 倍——单点均值天然会被"两个色系互相稀释"拉低,不能代表人眼真正
        // 盯着看的那一小片区域有多鲜艳。改用网格 p75 重新拟合,并统一把下面 satMul
        // 的上下限也按同一幅度收下来(0.6~2.2 → 0.35~1.6,那两个数同样是照着旧的
        // ×1.5 基线定的,基数变了它们也该跟着变,不然只压这一处、卡在 satMul 那道
        // 上下限里的封面照样纹丝不动)。0.35 是 5 组真实封面网格比对后取的折中值——
        // 单一参数拟合不出每张封面的精确比例(源图饱和度与 AM 输出并非严格线性,
        // 越浓烈的封面 AM 相对给得越足),折中值让 5 张里 4 张落在 AM 真实值的
        // 0.8~1.5 倍以内,只有你瞒我瞒因为下面高斯模糊在蓝棕两色交界处生成的过渡色
        // (structural 问题,不是这个系数能治的)仍偏高一截。灰阶封面 satP75≈0 → 目标
        // 仍≈0,这条 no-op 性质不变。
        //
        // ⚠️⚠️⚠️ 2026-08-23 第九轮,固定倍率 0.35 本身又被推翻——用户这轮批量拉了
        // 23 组真机 AM×我们 的同封面对拍截图并逐组给"差别大/还好/可以接受"判断,
        // 对每组用同一条左侧背景取样带(避开封面卡片与歌词文字)做网格 p75 定量,
        // 结果坐实:被判"差别大"的 7 组里有 5 组(P. Control/Babygirl/谁稀罕/Sign O'
        // The Times/小镇姑娘)根子不在色相、就是纯饱和度差——这 5 组源图 satP75 全在
        // 0.65~0.96(封面本身极浓烈),AM 真机输出 p75 也跟着到 0.76~1.00(AM 几乎
        // **不怎么压**这类封面,AM/源 比值 0.98~1.20,不是"减半"是"原样甚至更浓"),
        // 而固定 0.35 倍无论源图多浓都只给 0.23~0.34,砍掉了七成还多,肉眼看就是"浓烈
        // 橙红→浑浊灰棕"。全部 23 组按 (源 satP75, AM 真机 p75) 作对数-对数回归得
        // 幂函数 AM_p75 ≈ 0.94 × satP75^1.45(R²≈0.77)——固定倍率模型的本质缺陷是
        // "把 AM 的处理看成线性缩放",而真机数据是一条**凸曲线**:源图越浓烈,AM 保留
        // 的比例反而越高,不是越低。换成这条幂函数重新烘焙同一批 23 张封面,7 组"差别
        // 大"里那 5 组纯饱和度问题的(网格 p75 target vs 实测)误差从均值 0.39 收到
        // 0.13(P. Control 0.41→0.03,小镇姑娘 0.58→0.05,详细数字见
        // docs/features/07-lyrics-window.md 第九轮记录);其余 15 组"还好/可以接受"
        // 的均值误差基本没变(0.133→0.142,在噪声范围内)。剩下 2 组"差别大"(黑夜/
        // Get on the Boat)复测 hueCoherenceScale 都是 1.0(算法判定色相完全一致、
        // 没有触发任何色相纠偏),说明它们的偏差另有病灶(大概率出在色相本身而不是
        // 饱和度量级),这条幂函数**修不了它们**,留给下一轮专门查色相。0.94/1.45
        // 两个数字是 23 组回归系数,不是拍脑袋——想再收紧就该在这批数据上重新拟合,
        // 不要凭感觉调。
        let satTarget = min(0.95, 0.94 * pow(satP75, 1.45)) * hueCoherenceScale
        for i in 0..<36 where cellSat[i] > 0.01 && cellSat[i] < satTarget {
            let target = satTarget
            let k = target / cellSat[i]
            let o = i * 4
            let mx = Double(max(px[o], max(px[o + 1], px[o + 2])))
            for ch in 0..<3 {
                let c = Double(px[o + ch])
                px[o + ch] = UInt8(min(255, max(0, mx - (mx - c) * k)))
            }
        }
        guard let fieldCG = cgctx.makeImage() else { return nil }

        func clamp(_ img: CIImage) -> CIImage {
            img.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
        }
        func render(_ img: CIImage) -> NSImage? {
            guard let out = blurBakeContext.createCGImage(img, from: frame) else { return nil }
            return NSImage(cgImage: out, size: NSSize(width: frame.width / 2, height: frame.height / 2))
        }

        let field = CIImage(cgImage: fieldCG)
            .transformed(by: CGAffineTransform(scaleX: W / 6, y: W / 6))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 35)
            .cropped(to: frame)
        // 闭环饱和度乘子:格级归一后 σ35 融合(相邻异色相格互混)+光斑 lighten 还会
        // 磨掉一截饱和度,按融合后场的实测均值闭环拉回 satTarget —— 场内部再怎么互混,
        // 出场饱和度都贴住目标;鲜艳均匀封面 fieldS 超标时乘子自动 <1 回落。
        //
        // ⚠️ "AM S50 0.63~0.97"这条 2026-08-21/22 写下的校准基准是错的,2026-08-23
        // 拿真机 Apple Music 原生「播放中」窗口实测 5 张不同封面推翻——AM 真实背景
        // 网格采样的 S 中位数普遍落在 0.08~0.42,p75 也就 0.14~0.51,从没到过 0.6+;
        // 当时"S50 0.63~0.97"的样本来源已不可考,大概率是拿了个位数张偏鲜艳的封面就
        // 定了基准,没跟真机对照过更大范围的封面。satTarget 的具体倍率与来源见上面
        // satTarget 声明处的注释。
        //
        // ⚠️ 2026-08-23 第九轮:satTarget 换成幂函数后数值整体变大,但**这里的上下限
        // 刻意没跟着抬**——23 组真机回归数据里只有 1 组(I Wanna Be Your Lover,蓝底
        // +人像肤色两大色系反差大)顶到过 1.6 那个上限,而且顶到上限也治不好它:这张
        // 封面 σ35 模糊后 fieldS 崩得极狠(0.56→0.15),就算把上限抬到 2.2/3.5,网格
        // p75 依然从 0.37 的目标冲到 0.8~1.0(实测过,见 07-lyrics-window.md 第九轮)
        // ——根子是"闭环乘子按面积均值 fieldS 算、但目标 satTarget 是按网格 p75 校准"
        // 这个本来就存在的口径错位(旧版本用小基数掩盖了它),抬上限只会把这类高反差
        // 封面推向过饱和,不抬上限则维持"跟旧版本一样欠一截"——两害相权,不抬。
        var satMul = 0.85
        let fieldAvg = field.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: frame),
        ])
        if let avgCG = blurBakeContext.createCGImage(fieldAvg, from: CGRect(x: 0, y: 0, width: 1, height: 1)),
           let d = avgCG.dataProvider?.data as Data?, d.count >= 3 {
            let mx = Double(max(d[0], max(d[1], d[2])))
            let mn = Double(min(d[0], min(d[1], d[2])))
            let fieldS = mx > 0 ? (mx - mn) / mx : 0
            // 上下限 0.35~1.6(2026-08-23 随 satTarget 基数一起收窄,原先 0.6~2.2 是
            // 照着 ×1.5 那版基线定的——基数缩小了三分之一还留着旧上下限,等于只压住了
            // "目标"没压住"最终能打多高/压多低",一部分封面(尤其源图本身饱和度就很
            // 高、fieldS 天然大的)会被旧上限重新顶回高饱和)。上限也按 hueCoherenceScale
            // 收,给一致色相封面留够放大空间(coherenceScale=1 时上限不变)。
            if fieldS > 0.02 {
                satMul = min(1.6 * max(0.4, hueCoherenceScale), max(0.35 * hueCoherenceScale, satTarget / fieldS))
            }
        }
        let vivified = field
            .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.4 * hueCoherenceScale])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: satMul])

        let baseImage = clamp(vivified
            .applyingFilter("CIExposureAdjust", parameters: ["inputEV": -0.15]))
        guard let base = render(baseImage) else { return nil }

        // 背景均色 → HSB 的 h/s(见 WindowBackgroundLayers.tintHue 注释)。均色取烘焙
        // 后的 base(就是屏幕上那层),亮度再乘 0.85 对齐视图层的 0.15 黑遮罩 —— 不过
        // 只取 h/s,乘不乘只影响没人用的 v,留个心眼而已。
        var tintHue: Double = 0
        var tintSat: Double = 0
        var tintBright: Double = 0
        let avg = baseImage.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: frame),
        ])
        if let avgCG = blurBakeContext.createCGImage(avg, from: CGRect(x: 0, y: 0, width: 1, height: 1)),
           let data = avgCG.dataProvider?.data as Data?, data.count >= 3 {
            let color = NSColor(
                red: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255,
                blue: CGFloat(data[2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            tintHue = Double(h)
            tintSat = Double(s)
            // ×0.85 对齐视图层的 0.15 黑遮罩,存的是屏幕实际见到的背景亮度。
            tintBright = Double(v) * 0.85
        }

        // 光斑锚在**原始**最亮格(归一化前):lighten 原位补一点暖亮渐变(对拍里 AM 的
        // B 区比周边亮 ~0.05 就是这类柔和抬升)。CGContext 缓冲行 0 是图像顶行,
        // CIImage y 向上,坐标要翻转。
        let brightest = (0..<36).max(by: { cellLuma[$0] < cellLuma[$1] }) ?? 14
        let bx = (Double(brightest % 6) + 0.5) / 6.0
        let by = 1.0 - (Double(brightest / 6) + 0.5) / 6.0
        guard let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: bx * frame.width, y: by * frame.height),
            "inputRadius0": frame.width * 0.08,
            "inputRadius1": frame.width * 0.7,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])?.outputImage?.cropped(to: frame) else { return nil }
        let glowImage = clamp(vivified.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame),
        ]))
        guard let glow = render(glowImage) else { return nil }

        var state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        // 三层共用同一张光斑图,姿态微差;周期错开、视图端做 ±小角度往复摆动。
        let periods: [Double] = [55, 75, 95]
        var poses: [WindowBackgroundLayers.GlowPose] = []
        for i in 0..<3 {
            poses.append(WindowBackgroundLayers.GlowPose(
                initialAngle: (next() - 0.5) * 30,
                spinDuration: periods[i],
                anchor: UnitPoint(x: 0.4 + next() * 0.2, y: 0.4 + next() * 0.2),
                scale: 1.0 + next() * 0.25
            ))
        }
        return WindowBackgroundLayers(base: base, glows: [glow, glow, glow], poses: poses,
                                      tintHue: tintHue, tintSaturation: tintSat,
                                      tintBrightness: tintBright)
    }

    /// 背景模糊的离线烘焙(2026-08-19 性能审计:替代视图层的合成期活滤镜)——灵动岛用,
    /// 歌词窗口那份走上面的 bakeWindowBackground(多副本合成)。先把源图缩到 targetWidth
    /// (模糊本来就抹掉细节,更高分辨率纯属浪费);可选先拉饱和度;clampedToExtent 让边缘
    /// 像素外延再裁回原框 —— 视图层的 .blur 会把边缘羽化成半透明,烘焙版边缘实心。
    nonisolated private static func bakeBackgroundBlur(
        cgImage: CGImage, targetWidth: CGFloat, sigma: Double, saturation: Double?
    ) -> NSImage? {
        var image = CIImage(cgImage: cgImage)
        let scale = targetWidth / max(1, image.extent.width)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let saturation {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
        }
        let blurred = image.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: image.extent)
        guard let out = blurBakeContext.createCGImage(blurred, from: blurred.extent) else { return nil }
        // size 用 pt(像素 /2):这张图是 2x 烘的,视图端 resizable 只关心宽高比,
        // 给个符合语义的点尺寸即可。
        return NSImage(cgImage: out, size: NSSize(width: blurred.extent.width / 2,
                                                  height: blurred.extent.height / 2))
    }

    /// 系统那份封面的边长**不超过**这个像素数,才去缓存里找高清替代。300 的依据:歌词窗口
    /// 那张封面卡最大 460pt,Retina 下 920px —— 300px 已经是 3 倍放大、肉眼能看出软,再小
    /// 就明显糊了;而正常给图的播放器(Apple Music)都远在这条线之上,一次都不会触发。
    ///
    /// ⚠️ 判据是"≤ 300"而不是"< 300"(2026-08-24 修)。原来写的是严格小于,而 **QQ 音乐
    /// 客户端往系统 Now Playing 报的封面恰好就是 300×300**(实测:27202 字节的 JPEG,
    /// 300×300),于是这条自愈路径对 QQ 音乐**一次都没触发过** —— 300px 顶到 820px 的封面
    /// 卡上是 2.73 倍放大,正是用户报的"QQ 音乐这个封面很模糊"。恰好落在边界上的那一档
    /// 本来就是这个阈值的注释自己在说"3 倍放大、肉眼能看出软"的那一档,该替。
    private static let lowResArtworkThreshold = 300

    private var highResCoverTask: Task<Void, Never>?

    /// 给当前曲目找一张比系统那份更大的封面。见 highResArtworkImage 的注释。
    ///
    /// onlyIfMissing:给"缓存内容变了"那条补查路用 —— 已经拿到高清图就直接不动,别走下面
    /// 那条 clearHighRes()→重下 的路(会让封面闪一下,理由见调用点)。换歌那条路传 false:
    /// 上一首的高清图**必须**立刻撤掉。
    private func refreshHighResCover(onlyIfMissing: Bool = false) {
        if onlyIfMissing, highResArtworkImage != nil { return }
        highResCoverTask?.cancel()
        highResCoverTask = nil
        // 刻意重新从数据源读,而不是用订阅回调的参数:那几个值来自 willSet 时机,
        // 彼此可能不是同一首歌的(见调用点注释)。
        let s = LocalPlaybackSource.shared
        let (title, artist, album) = (s.title, s.artist, s.album)
        // @Published 是 willSet 语义,给已是 nil 的属性再赋 nil 照样广播——四条清空路径
        // 每次换歌至少走一条,不加闸就是每换歌 1-2 轮白广播,还会穿透下游按 === 去重的
        // 订阅(2026-08-20 性能审计)。撤掉旧图的语义不变,只是已经空了就别再赋。
        func clearHighRes() {
            if highResArtworkImage != nil { highResArtworkImage = nil }
            if highResAverageHex != nil { highResAverageHex = nil }
        }
        guard !title.isEmpty else {
            clearHighRes()
            return
        }
        let systemPixels = Self.pixelWidth(of: s.artworkData)
        // 系统那份够大(或者压根没有封面 —— 那时该显示占位音符,不该悄悄换成缓存里
        // 匹配到的另一张图)就不动。
        guard systemPixels > 0, systemPixels <= Self.lowResArtworkThreshold else {
            clearHighRes()
            return
        }
        guard let cached = EnrichCacheReader.coverURL(artist: artist, title: title, album: album) else {
            // 这条分支就是「第一次听的歌封面一直糊」的现场:collector 还没解析完。
            // 现在缓存写入会再触发一次补查(见订阅处),所以这里不再是终点。
            logger.debug("highres: no cached cover yet for \(title, privacy: .public) (system=\(systemPixels, privacy: .public)px)")
            clearHighRes()
            return
        }
        let url = EnrichCacheReader.nativeSizedCoverURL(cached)
        // 上一首的高清图必须立刻撤掉:留着的话换歌后到新图下载完之间会显示上一首的封面,
        // 比"先小图后变清晰"糟得多。均值色跟图同进退。
        clearHighRes()
        highResCoverTask = Task { [weak self] in
            // 走 App 已有的那套内存缓存(同 URL 并发只发一次请求、命中不闪占位符)。
            // 原图档:这张要给歌词窗口 920pt@2x 的封面卡当高清替代,不能吃缩略降采样。
            guard let image = await ImageMemoryCache.shared.load(url, variant: .original),
                  !Task.isCancelled else { return }
            // 下载期间可能已经换歌了 —— 这张是上一首的,丢掉。
            guard LocalPlaybackSource.shared.title == title else { return }
            // 拿回来的还不如系统那份大就不值得换(缓存里可能存着一张同样小的图)。
            guard Int(image.size.width.rounded()) > systemPixels else { return }
            // 均值色跟图一起给(理由见 highResAverageHex 的注释)。CIAreaAverage 放到
            // 后台算,跟 LocalPlaybackSource 取图那条路的做法一致,不挡主线程。
            var hex: String?
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                hex = await Task.detached { LocalPlaybackSource.computeAverageHex(cgImage: cg) }.value
            }
            guard !Task.isCancelled, LocalPlaybackSource.shared.title == title else { return }
            logger.debug("highres: swapped in \(Int(image.size.width), privacy: .public)px for \(title, privacy: .public) (system=\(systemPixels, privacy: .public)px)")
            self?.highResArtworkImage = image
            self?.highResAverageHex = hex
        }
    }

    /// 封面原始字节的像素宽度。用 CGImageSource 只读图头,不解码整张图。
    private static func pixelWidth(of data: Data?) -> Int {
        guard let data,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int
        else { return 0 }
        return w
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

    /// 播放/暂停 —— 各 UI 面(歌词窗/灵动岛/悬浮层热键/菜单栏面板/全局快捷键)都走这里,
    /// 不直接调 MusicPlaybackController.playPause():发命令的同时**乐观翻转**观感层
    /// isPlayingSmoothed,封面缩放/播放图标点击即动。真实链路(命令→播放器切状态→分布式
    /// 通知→250ms 去抖→poll 子进程→apply)实测要 0.5~1s,等它回读再动画,对比 AM 的即时
    /// 反馈明显迟钝(2026-08-21 用户反馈"扩大延迟太久")。
    ///
    /// 只翻观感层、不碰 isPlayingNow 真值:进度时钟/歌词填色仍由 poll 链路驱动,状态机
    /// 不引入第二条写路径。万一命令没落地(播放器没开/权限没给),真值不会来"纠正"它
    /// (updateSmoothedPlaying 只在 isPlayingNow **变化**时被调),所以 2.5s 后对账一次、
    /// 拨回真值 —— 有 grace 定时在跑说明真值正在按老路径收敛,那种情况不抢。
    func userTogglePlayPause() {
        MusicPlaybackController.playPause()
        stopGraceWork?.cancel()
        stopGraceWork = nil
        isPlayingSmoothed = !isPlayingNow
        optimisticReconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.optimisticReconcileWork = nil
            if self.isPlayingSmoothed != self.isPlayingNow, self.stopGraceWork == nil {
                self.isPlayingSmoothed = self.isPlayingNow
            }
        }
        optimisticReconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
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
