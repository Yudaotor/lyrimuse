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
    /// 背景均色的色相/饱和度:左栏次级元素(副行/时间/进度已播段)要做 AM 式 vibrancy 染色 ——
    /// AM 的次级文字不是半透明白(那样三通道等效 α 应相等,对着 AM 截图逐通道反解是 r0.74/g0.58/b0.49),
    /// 而是背景色相的亮化低饱和版。这里存烘焙后 base 的 CIAreaAverage 转 HSB 的 h/s,亮度各元素自定。
    let tintHue: Double
    let tintSaturation: Double
    /// 背景均色的**亮度**(已含视图层 0.15 黑遮罩的 ×0.85,即屏幕见到的亮度)。固定亮度档的 vibrancy
    /// 染色在亮封面(金色 bgV≈0.7)上会撞上背景亮度直接隐形,文字类调用靠它做最小对比度自适应
    /// (见 amVibrantColor)。0 = 未知(取色失败),不做自适应、用固定亮度档(见 AMVibrancy.brightness)。
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

// 只有本地 media-control 一个数据源,这个类是 LocalPlaybackSource 的一层薄转发;留着这一层、
// 不让 UI 直接碰 LocalPlaybackSource.shared,以后要接别的数据源时 UI 层不用跟着改。
@MainActor
final class PlaybackCoordinator: ObservableObject {
    static let shared = PlaybackCoordinator()

    @Published private(set) var title: String = ""
    /// 界面上显示的歌名(`TrackNameDisplay.cleaned`)。拿它画界面,别拿它当 key(查缓存 / 拼链接 / 打卡仍用 `title`)。
    @Published private(set) var displayTitle: String = ""
    @Published private(set) var artist: String = ""
    /// 界面上显示的歌手名。判据见 `PlayerArtistFix.displayArtist` —— 署名不可信的播放器在
    /// 纠正落地之前是空串;画之前过一遍 `TrackNameDisplay.cleaned`。拿它画界面,别拿它当 key(查缓存 / 拼链接 / 打卡仍用 `artist`)。
    @Published private(set) var displayArtist: String = ""
    @Published private(set) var album: String = ""
    /// 播放器没报专辑时 YouTube Music 上登记的那张(见 `LocalPlaybackSource.youtubeMusicAlbum`)。只给界面用。
    @Published private(set) var youtubeMusicAlbum: String = ""
    /// 界面上专辑位显示的字,判据见 `LocalPlaybackSource.displayAlbum`(播放器报的 → YouTube Music 上登记的 →「MV」)。
    /// 同样过一遍 `TrackNameDisplay.cleaned`。只画在界面上 —— 缓存 key、简介、链接一律仍用 `album`。
    @Published private(set) var displayAlbum: String = ""
    /// 播放器没报歌手时引擎认出来的歌手 / 专辑,给上面两个显示位兜底(`InferredTrackIdentity`,见 03 章决策 32)。
    @Published private var inferredIdentity: InferredTrackIdentity?
    @Published private(set) var isPlayingNow: Bool = false
    /// 播放器说在放、声音还没走起来,见 `LocalPlaybackSource.isWaitingToPlay`。
    @Published private(set) var isWaitingToPlay: Bool = false
    /// 播放控制此刻被拦下时悬停要说的那句,没拦下是 nil(见 `LocalPlaybackSource.playbackControlsWithheldBundleID`)。
    /// 各展示面据此把上一首 / 播放暂停 / 下一首画灰(`withheldControlOpacity`)。
    @Published private(set) var playbackControlsWithheldReason: String?
    /// 播放控制被拦下时那几颗键的不透明度。
    static let withheldControlOpacity: Double = 0.35
    // isPlayingNow 的"缓收版":开始播放立刻为 true,停止播放要**静默满宽限期**才变 false。
    //
    // 给"要不要把悬浮窗/灵动岛收起来"这类决策用,不给歌词显示用 —— 歌词该在暂停的一瞬间
    // 就停住,而窗口不该。切歌间隙、seek、缓冲都会让 isPlayingNow 短暂掉 false,跟着它走
    // 就会看到灵动岛缩回刘海再弹出来、悬浮窗闪一下,而用户从头到尾都在听同一首歌。
    //
    // 只延后"停",不延后"起":恢复播放必须立刻有反应,那是用户刚刚按下的操作。
    //
    // 暂停 / 恢复要等播放器的通知或下一次 2 秒轮询才感知得到(见 LocalPlaybackSource.handlePlayerInfoChanged),
    // "宽限期内恢复 → 取消收起"这条路很少走到;真正起作用的是另一半:切歌间隙、seek 这类
    // isPlayingNow 只掉 false 一瞬间的抖动。
    @Published private(set) var isPlayingSmoothed: Bool = false
    // 停播宽限 0.25 秒:取更长的值(如 2 秒)盖得住换歌间隙和常见的 seek/缓冲,但加上收起动画本身的时长,
    // 用户按下暂停之后要盯着一个没在动的灵动岛等好几秒,明显像卡住了。0.25 秒仍能吸收亚 1/4 秒的瞬时
    // false(播放器切歌那一下的空档),人对这个量级的延迟基本无感,观感就是"一暂停就收"。
    //
    // 别直接归零:归零意味着 isPlayingNow 任何一次瞬时 false 都会立刻触发收起/隐藏,换歌、seek、
    // 缓冲时就会看到灵动岛缩回去再弹出来。若换歌/seek 时看到灵动岛缩一下又弹开,就是播放器的空档
    // 超过了这个窗口,调回 0.5(只此一个常量)。
    private static let stopGracePeriod: TimeInterval = 0.25
    private var stopGraceWork: DispatchWorkItem?
    /// userTogglePlayPause 乐观翻转后的对账定时(见那边注释)。
    private var optimisticReconcileWork: DispatchWorkItem?
    @Published private(set) var currentLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?
    // 下一句摆哪一边,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var nextLineSide: LyricDuet.Side?
    // 下一行的罗马音/译文,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var nextLineRomanization: String?
    @Published private(set) var nextLineTranslation: String?
    @Published private(set) var nextLineWordGroups: [SyncedLyricWordGroup]?
    @Published private(set) var hasLyricsContent: Bool = false
    // 联网查过了、明确是纯音乐,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var isCurrentTrackInstrumental: Bool = false
    @Published private(set) var currentTrackHasNoLyrics: Bool = false
    /// 上面两项合成的「这首没有歌词」(`NoLyricsAutoHide.lacksLyrics`),「纯音乐/无歌词时隐藏」(灵动岛是收起歌词行)读它。
    @Published private(set) var currentTrackLacksLyrics: Bool = false
    // 没有时间戳的纯文本歌词兜底,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var currentTrackPlainLyrics: String = ""
    // 完整歌词窗口末尾「创作者：…」的名单,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var currentTrackSongwriters: [String] = []
    /// 引擎报"网络不通,这一轮查不了"(见 EngineStatus)。
    @Published private(set) var engineNetworkDown: Bool = false
    // Spotify 广告插播,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var isCurrentTrackAdBreak: Bool = false
    /// 电台口白:当前这首歌已经放完、台里在说话。语义与 `isCurrentTrackAdBreak`
    /// 平行 —— 都是"这一刻在放的不是歌",三个展示面据此把歌词那一格换成「口白」。
    @Published private(set) var isRadioTalkBreak: Bool = false
    /// 口白期间顶上去的台名与台标。抓不到台卡时是 nil,界面退回原样(还显示上一首),
    /// 判据与实测见 `RadioStationCard`。
    @Published private(set) var radioStationName: String?
    @Published private(set) var radioStationImage: NSImage?
    /// 这条广告是插播里的第几条 / 一共几条。只有 YT Music 网页广告给得出,
    /// 拿不到是 nil、界面上那一段不画。语义与生命周期见 `LocalPlaybackSource.currentAdSlot`。
    @Published private(set) var currentAdSlot: YouTubeMusicAdProbe.AdSlot? = nil
    /// 「广告中」那一行的倒计时从哪来,见 `LocalPlaybackSource.adCountdown`。
    @Published private(set) var adCountdown: AdCountdown = .track
    @Published private(set) var anchor: ProgressAnchor?
    // "歌词窗口"(完整可滚动歌词列表)用,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var currentLineIndex: Int?
    // 歌词窗口滚动锚(AM 式"滚动先于染色"),见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var scrollLineIndex: Int?
    // 歌词窗口里跟当前行重叠着还在唱的前几行,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var overlappingLineIndices: [Int] = []
    // 单行展示面(悬浮歌词 / 灵动岛 / 菜单栏 / 触控栏)各自按宽度断句后此刻该显示的内容,见 LocalPlaybackSource
    // 同名属性的注释。
    @Published private(set) var overlayLyrics = LyricsSyncEngine.SurfaceLyrics.empty
    @Published private(set) var notchLyrics = LyricsSyncEngine.SurfaceLyrics.empty
    @Published private(set) var menuBarLyrics = LyricsSyncEngine.SurfaceLyrics.empty
    @Published private(set) var touchBarLyrics = LyricsSyncEngine.SurfaceLyrics.empty
    @Published private(set) var menuBarSongRowWidth: CGFloat?
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
    /// `currentGapIndex` 的不设门槛版本,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var rawGapWindow: LyricsGapWindow?
    // 当前行逐字填色是否已定格(悬浮歌词的 TimelineView 停表条件),见 LocalPlaybackSource
    // 同名属性的注释。
    @Published private(set) var currentLineFillSettled: Bool = true
    // "歌词窗口"背景用的模糊封面图,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var artworkData: Data?
    // 上面那份原始字节解码出来的位图,只在封面数据真的变了的时候解一次。灵动岛、歌词窗口、触控栏
    // 都读封面,各自现调 `NSImage(data:)` 的话,每次 body 重算都要把同一张几百 KB 的 JPEG 重解一遍——
    // 而 body 重算在换歌词行、换歌、重锚进度时都会发生,远比"每首歌一次"频繁。解码收敛到这一层做一次、
    // 各处共用。
    //
    // 放在这一层而不是 LocalPlaybackSource:跟 artworkAccentColor 同一个分层理由——
    // LyrimuseCore 那一层不引入 AppKit/SwiftUI,类型转换只能在这一层做。
    @Published private(set) var artworkImage: NSImage?
    /// 上面那张的高清替代,只在系统给的那份实在太小、或者压根不是封面的形状时才有值(否则 nil,消费方退回
    /// artworkImage)。给歌词窗口那张最大 460pt(Retina 下 920px)的封面卡用。
    ///
    /// 系统 Now Playing 的封面分辨率由播放器决定:网易云 macOS 客户端只给 100×100(`get` 和 `get --now`、自带和
    /// homebrew 两份 media-control 都是这个尺寸,media-control 也没有"要大图"的参数),放到 920px 显示等于放大 9 倍;
    /// QQ 音乐客户端给 300×300,恰好卡在阈值边界上(见 lowResArtworkThreshold)。
    ///
    /// 替代图来自引擎已经存在缓存里的 `cover_url`(网易云/Apple/QQ 解析歌词时顺手记下的);取用前还会过一遍
    /// `EnrichCacheReader.nativeSizedCoverURL` 把图源自己的尺寸档顶到最大(网易云摘 param、QQ 提到 800、Apple 提到 1200),
    /// 否则 QQ 源那张存的也只有 300、白替一趟。
    ///
    /// 只在系统那份 ≤ lowResArtworkThreshold、或者不是方形时才替(判定收在 `CoverArtReplacementGate`,交给引擎的
    /// 设备封面也按它判)。系统那份才是"正在播的这一项"的权威图;缓存里那张是按歌手/歌名/专辑匹配出来的,同名不同版本时
    /// 可能是另一张封面。播放器本来就给大图时(Apple Music)完全不碰这条路。
    ///
    /// 形状也要判:YouTube Music 的 MV 条目经 Safari MediaSession 上报的 artwork 是 320×180 的视频缩略图,宽 320 刚越过
    /// 300 的门槛,不判形状就会被当成正经封面原样显示,再被展示面的 scaledToFill 裁成方块。
    @Published private(set) var highResArtworkImage: NSImage?
    /// 上面那张高清替代的**预缩小图**(≤256px),给菜单栏面板 44pt 那格小封面
    /// 用。`highResArtworkImage` 是 `NSImage(data:)` 懒解码的**原图档**(给歌词窗口 920pt@2x
    /// 的封面卡),面板每次打开都是全新建树、首帧直接画它 = 在主线程把一张 1400~3000px 的
    /// 图整张解码再缩到 88px,离线量过一次要 ~30ms(300px 的只要 5ms);面板收起即整树释放,
    /// 所以这笔账每次打开都可能重付。这里在图到货那一刻、跟均值色同一个后台任务里缩好,
    /// 面板拿到就是画起来只要 1~2ms 的小图。跟 `blurredArtworkImage` 同一个"到货时离线烘
    /// 一次、视图只铺静态图"的纪律。nil 的含义跟 highResArtworkImage 一致,同进退。
    @Published private(set) var highResArtworkThumbnail: NSImage?
    /// 灵动岛 coverArt 背景用的**预烘焙模糊图**:封面到货时离线烘焙一次(见 rebakeBlurredArtwork),
    /// 视图直接铺静态图。别改回视图层挂 `.blur(radius:)`:那是合成期实时滤镜,灵动岛窗口播放期间因
    /// 逐字填色/音浪/跑马灯几乎永动,GPU 每次重合成都会对同一张封面重算同一个模糊结果。
    /// 源取 highResArtworkImage ?? artworkImage;nil = 还没烘出来/没有封面,视图铺纯黑。
    @Published private(set) var blurredArtworkImage: NSImage?
    /// 上面那张模糊图的亮区色(`NotchBackdropTone`),跟它一起烘、一起换;nil = 没有模糊图。灵动岛背景按它压暗,
    /// `notchAccentColor` 按它做对比度检查。
    @Published private(set) var notchBackdropTone: NotchBackdropTone?
    /// 「歌词窗口」AM 式动画背景的一套预烘焙图层(依据 Priva28 gist + AMLL 反推的 AM 架构,见 07 章
    /// 「背景取色逼近 Apple Music」):暗底 + 3 份封面**不同区域**取色的羽化光斑,视图层 lighten
    /// (变亮)混合 + 慢速 GPU 旋转——lighten 让封面亮色区变成浮在暗底上的光斑(普通
    /// 叠加会把亮暗平均掉,怎么调都"平"),动画让背景像 AM 一样缓慢流动。烘焙离线一次,
    /// 视图层只做变换动画,无合成期滤镜。
    @Published private(set) var windowBackgroundLayers: WindowBackgroundLayers?
    /// 上面那张高清替代的均值色(十六进制,格式同 LocalPlaybackSource.artworkAverageHex)。
    /// 有高清图时两个"跟随封面"强调色必须按它算:系统那份可能是网易云的灰底音符占位图,
    /// 界面上实际显示的是高清替代,强调色还按占位图算就是一团跟画面无关的灰。nil = 没有
    /// 高清替代,强调色回落到系统那份的均值(见下面两条管线的 highResHex ?? systemHex)。
    @Published private(set) var highResAverageHex: String?

    /// 当前这首歌的**动态封面**本地文件(Apple Music 的 motion artwork)。
    /// nil = 这张专辑没有 / 还没下好 / 用户关了开关 —— 三种情况在界面上都是"铺静态封面",
    /// 消费面不需要区分。整条链路见 `MotionCoverStore` 与 `MotionCoverManifest` 的头注。
    ///
    /// 它跟 `highResArtworkImage` 是**并行**的两件事,不互相替代:静态高清图管"这一格画什么",
    /// 动态封面只在它之上再叠一层会动的画面,拿不到就退回静态图。所以这里**不**参与均值取色 ——
    /// 强调色仍旧按静态图算,不然同一张专辑会因为"动画播到哪一帧"而颜色抖动。
    @Published private(set) var motionCoverFile: URL?
    private var motionCoverTask: Task<Void, Never>?
    // 从封面均值算出来的动态高亮色,**桌面悬浮歌词专用**(已经从 LocalPlaybackSource
    // 转发的十六进制字符串转成 Color——LyrimuseCore 那一层不引入 SwiftUI,转换只能在
    // 这一层做,见 LocalPlaybackSource.artworkAverageHex 的注释)。供"跟随封面"外观模式
    // 用,见 displayForegroundColor。
    //
    // 这一侧的背景是壁纸/任意窗口,不能假定深浅,所以判据是"跟描边色够对比"而不是
    // "够亮"(见 LocalPlaybackSource.accentAgainstStroke);描边关着时才退回"够亮"。
    // 因此它依赖描边那两项设置——改描边颜色/开关会连带重算这个色,这是有意的。
    @Published private(set) var artworkAccentColor: Color?
    // 同一份封面均值的"深色背景"变体:先过 HSB 亮度地板(brightenedAccent),再补一道
    // 感知亮度下限(见 LocalPlaybackSource.accentForDarkBackdrop 的注释:HSB 地板拦不住
    // 饱和冷色,纯蓝 luma 只有 0.07,贴在灵动岛的深色背景上区分度差)。只给灵动岛消费 ——
    // 它的三种风格底色全是暗的,越亮越好;桌面那一侧正好相反,见上面。
    @Published private(set) var notchAccentColor: Color?
    // 当前曲目已生效的歌词时间轴校正值,见 LocalPlaybackSource 同名属性的注释——直接转发权威值,
    // 别在这一层另外拼 key 重新查:存储用的 key 是 LyricsOffsetStore.trackKey(多一段内容指纹),
    // 自己拼 "\(artist)|\(title)" 查出来的永远是 0。
    @Published private(set) var currentLyricsOffsetMs: Int = 0
    // 上面那个总偏移里只属于当前这首歌的那一半,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var trackLyricsOffsetMs: Int = 0
    // "歌词窗口"进度条的暂停态冻结位置/时长,见 LocalPlaybackSource 同名属性的注释。
    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?

    /// 单行展示面(灵动岛/菜单栏)的配速用时长:compactLine **总共会显示多久**。
    ///
    /// 算不出来时退回 currentLineDwellSeconds —— 主要是**最后一句**:引擎不知道曲目时长,
    /// 而那边有(用曲目时长兜底,尾奏通常还有几秒够滚完)。
    var compactDwellSeconds: Double? {
        if let ms = compactDwellMs, ms > 50 { return Double(ms) / 1000 }
        // 这条退路 **几乎不可达**:曲长已经喂进引擎(见 tickQuery 的
        // trackEndMs),最后一句的窗口也算得出来了,只剩"连曲长都不知道"这一种。
        //
        // 刻意**不**在它上面叠 compactLeadInSeconds:它按 currentLineIndex 取行,而
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

    /// 当前行会显示多久(毫秒)。窗口口径见 `LyricDisplayWindow`(最后一句用曲长兜底,时间戳异常
    /// 返回 nil,调用方拿它做除数);还没播到第一句、没有歌词时也是 nil。用的是两句歌词时间戳之差,
    /// 歌词时间轴校准(currentLyricsOffsetMs)同时加在两句上,不影响它;最后一句兜底的曲长是播放时间,要加上它换到歌词时间。
    var currentLineDwellMs: Int? {
        LyricDisplayWindow.of(index: currentLineIndex, starts: allLines.lazy.map(\.timeMs),
                              trackDurationMs: currentDurationMs.map { $0 + currentLyricsOffsetMs })?.dwellMs
    }

    /// 同 `currentLineDwellMs`,单位秒。
    var currentLineDwellSeconds: Double? { currentLineDwellMs.map { Double($0) / 1000 } }

    /// 歌词时间轴上的此刻(毫秒):锚点外推 ?? 暂停冻结的位置,再叠歌词时间轴偏移。悬浮歌词和触控栏的
    /// 图层歌词行装动画时都读它。只给歌词用:进度条、播放位置不叠这个偏移,别拿它。
    func lyricsTimelineMs(now: Date = Date()) -> Int {
        (anchor?.extrapolatedPositionMs(now: now) ?? pausedPositionMs ?? 0) + currentLyricsOffsetMs
    }

    /// 提前 `leadMs` 解一次歌词行,给网页歌词副屏用,见 `LocalPlaybackSource.lyricsLookahead`。
    func lyricsLookahead(leadMs: Int) -> LocalPlaybackSource.LyricsLookahead? {
        LocalPlaybackSource.shared.lyricsLookahead(leadMs: leadMs)
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

    /// 这一刻在播的播放器能不能拖进度(见 `LocalPlaybackSource.acceptsSeek`)。各处进度条、点歌词跳转都看它。
    var acceptsSeek: Bool { LocalPlaybackSource.shared.acceptsSeek }

    // 「导出诊断信息」用:这一刻实际被认下来的播放器,翻成人读得懂的名字。认不出来的
    // bundle id 原样附上(比只说"未知"有用得多——排查时那串 id 就是线索)。
    var resolvedPlayerDescription: String {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return "none (no snapshot yet)" }
        if let known = PlaybackPlayer.allCases.first(where: { $0.bundleIdentifier == id }) {
            return "\(known.rawValue) (\(id))"
        }
        return "unknown (\(id))"
    }

    // 菜单栏面板「正在播放」卡右上角的来源角标:此刻实际被认下来的播放器
    // 的人话名。认不出来/还没有任何快照给 nil,角标整个不显示 —— 别摆一个「未知」。
    // 不用单独发布:播放器切换必然伴随曲目/播放态变化,面板反正会跟着那些 @Published 重渲染。
    var resolvedPlayerDisplayName: String? {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return nil }
        if let platformID = resolvedWebPlatformID,
           let platform = BrowserPositionProbe.supportedPlatforms.first(where: { $0.id == platformID }) {
            return platform.displayName
        }
        return PlaybackPlayer.allCases.first { $0 != .auto && $0.bundleIdentifier == id }?.displayName
    }

    /// 浏览器在放的是哪个**网页音乐平台**(nil = 不是网页播放器 / 认不出来)。
    ///
    /// 浏览器在放 YouTube Music / Spotify 网页版时,来源角标显示那个平台而不是浏览器;别的网站照旧显示
    /// 浏览器。判据全在 `BrowserPositionProbe.playingPlatformID`(证据优先、配对推断兜底,那边有完整取舍),
    /// 这里只负责把它接上当前这条播放。歌词窗口简介面板的「网页」行也用它(Spotify 网页版要认成 Spotify 那个平台)。
    var resolvedWebPlatformID: String? {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return nil }
        return BrowserPositionProbe.shared.playingPlatformID(forBundleID: id)
    }

    /// 上面那个的图标版:取**已安装播放器的真实 App 图标**。
    /// 查找/缓存逻辑收在 `AppIconResolver`(跟另外两处消费点共用一份缓存,
    /// 见那个类型的类头注)。没装(理论上不可能:它正在放)/认不出来给 nil,角标不显示。
    ///
    /// 浏览器多一层:认得出在放哪个网页音乐平台时,画**平台**图标而不是
    /// 浏览器图标(YouTube Music / Spotify 网页版)。认不出来(没配对、配了两个又还没探到、
    /// 或者放的压根不是这两个站)照旧画浏览器图标,不做猜测。
    ///
    /// 点击走 `openResolvedPlayer()`:认得出平台时翻到**正在放歌的那枚标签页**(网页平台的
    /// "对应播放器页面"是标签页,不是整个浏览器),翻不到或原生播放器退回整 App 激活。
    var resolvedPlayerIcon: NSImage? {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return nil }
        if let platformID = resolvedWebPlatformID, let icon = WebPlatformIcon.image(platformID) {
            return icon
        }
        // 浏览器图标按宿主取:Safari 上报的 com.apple.WebKit.GPU 查不到 App 图标。
        return AppIconResolver.icon(forBundleID: BrowserPositionProbe.probeTargetBundleID(forReported: id) ?? id)
    }

    /// 点面板右上角的来源角标:把正在播放的那个播放器唤到前台。
    ///
    /// 别用 NSRunningApplication.activate()(在跑就激活、没在跑才 openApplication):
    /// 实测点了毫无反应:macOS 14 起的**协作式激活**会把「后台 accessory App 请求
    /// 激活别的 App」静默拒绝 —— 不报错、不打日志、就是不动。NSWorkspace.openApplication
    /// 是系统认可的路径:对已在跑的 App 等价于"带到前台"(open -b 同款行为),没在跑就
    /// 顺便启动,一条路两件事。
    ///
    /// 要按**宿主**找 App(`probeTargetBundleID`):Safari 上报的 `com.apple.WebKit.GPU`
    /// 不是一个能打开的 App,裸查 `urlForApplication` 必然落空。
    func openResolvedPlayerApp() {
        guard let id = BrowserPositionProbe.probeTargetBundleID(
            forReported: LocalPlaybackSource.shared.lastResolvedBundleID) else {
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

    /// 点来源角标 / 「在 XX 中显示」的统一入口:把此刻正在播放的播放器带到台前。
    /// 原生播放器 = 激活那个 App(`openResolvedPlayerApp`);网页平台(YouTube Music /
    /// Spotify 网页版)= 先把**正在放歌的那枚标签页**翻到台前(`revealPlayingTab`,URL 判据
    /// 与进度探测同一份),翻不到再退回整 App 激活 —— 兜底永远在,不比只有整 App 激活差。
    ///
    /// 为什么网页平台不能只激活 App:歌多半就是在那个浏览器里放的,点击时浏览器本来就常是
    /// 前台 App,再"激活"一次等于什么都没发生;要跳的"播放器页面"是那枚标签页。
    ///
    /// 标签页脚本要起 osascript 子进程(秒级上限),丢后台任务跑,不在点击的那条主线程上等。
    func openResolvedPlayer() {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else {
            logger.notice("openResolvedPlayer: no resolved player")
            return
        }
        guard let platformID = resolvedWebPlatformID else {
            openResolvedPlayerApp()
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            if BrowserPositionProbe.revealPlayingTab(bundleID: id, platformID: platformID) { return }
            await MainActor.run { self?.openResolvedPlayerApp() }
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

    // 「按播放器」那一层—— 同一个控件上的下拉框选中具体播放器时,改的是这层。
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

    // 「喜欢」:哪些播放器有见 MusicPlaybackController.supportsFavorite。nil 有明确含义 ——"这个播放器
    // 根本没有这回事"(或没拿到权限),悬浮窗据此整个不显示那个按钮,而不是显示一个永远点不亮的心。
    //
    // 这条状态**不**跟着 2 秒轮询走:读一次不便宜(Apple Music 要起一个 osascript 子进程),为一个绝大多数
    // 时候不变的布尔值每 2 秒读一次不值当。只在几个时机刷新 —— 换歌时(见 start() 里那条订阅)、歌词
    // 窗口出现 / App 回到前台、悬浮窗控制排露出来的时候(见 LyricsOverlayView)。后者正好覆盖了"用户在
    // 播放器里自己点了心、回头来看悬浮窗"这种情况。
    @Published private(set) var isFavorited: Bool?
    /// 上一次换歌的时刻和那一首(歌名|歌手),「喜欢」靠菜单标题读写的播放器按它推迟读写(07 章决策 147)。
    private var trackChangedAt = Date.distantPast
    private var currentTrackKey = ""
    /// 靠菜单标题写「喜欢」没写成的那一首:这一首不再显示心、不再按(没登录的网易云按下去会弹登录窗口,每点一下弹一次),
    /// 换歌后自然恢复。
    private var favoriteUnavailableTrackKey: String?
    /// 换歌后等菜单标题换好再读一次「喜欢」。
    private var settledFavoriteRefresh: Task<Void, Never>?
    private var favoriteBlockedForTrack: Bool { favoriteUnavailableTrackKey == currentTrackKey }

    /// 播放模式(列表/随机/列表循环/单曲循环)。哪些播放器有见 MusicPlaybackController.supportsExtendedControls;
    /// media-control 走的系统级 MediaRemote 没有这个概念 —— 所以 nil 同样表示"这个播放器根本没有这回事",
    /// 按钮据此整个不显示。刷新时机也跟"喜欢"共用(换歌 / 窗口出现 / App 回到前台):
    /// 用户可能在播放器里自己改了模式,我们没有任何事件能收到,只能在这几个时机回读。
    @Published private(set) var playbackMode: MusicPlaybackController.MusicPlaybackMode?
    /// 这个播放器此刻能切哪几档(随机 / 列表循环 / 单曲循环;模式为 nil 时为空)。随机、循环两颗键各按它显示,
    /// 循环键按有没有单曲循环走三态或两态;灵动岛展开区的两颗键只在随机、循环都能切时出现。跟 `playbackMode`
    /// 只经 `applyPlaybackMode` 一起赋值,别单独改其中一个。
    @Published private(set) var playbackModeOptions: MusicPlaybackController.PlaybackModeOptions = []

    /// 用户动作序号,"喜欢"和"播放模式"各一份。
    ///
    /// 回读是**异步**的(要起一个 osascript 子进程,实测约 125ms),而这期间用户完全可能已经
    /// 点了按钮。没有这道守卫的话,一次在途的旧读数会把刚点出来的新状态盖回去 —— 最容易撞上
    /// 的时机就是"点击窗口把 App 激活"本身:激活触发一次刷新,紧接着的那一下点击落在按钮上,
    /// 读数回来正好把它抹掉。读之前记下序号,回来发现序号变了就整个丢弃。
    private var favoritedActionSeq = 0
    /// 上次由 Lyrimuse 给哪一首写「喜欢」、什么时候写的。快捷键回读时据此判断读数是不是还没跟上(`adoptsFavoriteReadback`)。
    private var lastFavoriteWrite: (trackKey: String, at: Date)?
    private var playbackModeActionSeq = 0
    private var volumeActionSeq = 0

    /// Music.app 自己的输出音量(0~100)。nil = 当前播放器没有这个概念/没拿到权限,
    /// 跟"喜欢""播放模式"同一个约定,界面据此整个不显示这个控件。
    @Published private(set) var soundVolume: Int?
    /// 读不到音量、但能说清怎么才有时的那句话(音量胶囊灰着显示、悬停给它):在放洛雪、它的开放 API 没开。别的时候 nil。
    @Published private(set) var volumeHint: String?
    /// 有 `volumeHint` 时灰着的胶囊显示的档位:洛雪配置文件里的音量(`LXMusicOpenAPI.configVolumePercent`,只读);读不到为 nil。
    @Published private(set) var volumeHintLevel: Int?

    /// 音量写入的合流状态:同一时刻只允许一次 osascript 在飞,拖动期间新来的值只更新
    /// pendingVolumeTarget,等在飞的那次回来再补写最后一个值。
    ///
    /// 必须做成"同一时刻只飞一次":滑杆的 DragGesture.onChanged 每来一个
    /// 鼠标移动事件就调一次 setVolume,而每次 setVolume 都 `Task.detached` 起一个
    /// **osascript 子进程**(实测单次往返 Music 90ms / Spotify 101ms)——拖一秒钟就是六十到
    /// 一百多个进程同时在飞,互相抢 CPU,主线程跟着被拖垮,滑块跟不上手指。
    ///
    /// 为什么用"同一时刻只飞一次"而不是按固定间隔节流:写一次本来就要 ~100ms,这个规则会
    /// 自然收敛到约 10 次/秒,不需要另外拍一个魔数;而且"回来后若还有新值就再写一次"保证
    /// **最后松手的那个值一定落地**,不会停在中途某个位置。
    private var volumeWriteInFlight = false
    private var pendingVolumeTarget: Int?

    /// 静音之前的音量,用来再点一次时还原。
    ///
    /// 静音必须是个**开关**,不能是无条件 setVolume(0)——已经是 0 的时候再点
    /// 等于把 0 写成 0,什么都不会发生。
    private var volumeBeforeMute: Int?

    /// 这一刻**实际在播**的是不是 Apple Music。
    ///
    /// 判定必须看这个,不能看 PlaybackPlayerPreference.selected/isExclusivelyAppleMusic。
    /// 设置里那一档可以是"自动识别"、或者多选了好几个,那时选中集合不排他地等于 {.appleMusic},
    /// 但实际在播的完全可能就是 Apple Music —— 用设置值判断会让这颗心在这些情况下永远不出现。
    /// seek 那条路径用的是同一个信号(见 LocalPlaybackSource.seek 里的 resolvedIsAppleMusic)。
    private var isAppleMusicPlayingNow: Bool {
        LocalPlaybackSource.shared.lastResolvedBundleID == PlaybackPlayer.appleMusic.bundleIdentifier
    }

    /// 播放控制被拦下时的那句说明。认得出播放器就点名(「QQ 音乐」),认不出说「播放」。
    static func withheldControlsReason(bundleID: String) -> String {
        guard let player = PlaybackPlayer.allCases.first(where: { $0 != .auto && $0.bundleIdentifier == bundleID }) else {
            return L10n.t("其他 App 正占用播放焦点，暂时无法控制播放")
        }
        return String(format: L10n.t("其他 App 正占用播放焦点，暂时无法控制「%@」"), player.displayName)
    }

    /// **这一刻实际在播**的那个播放器。注意不是设置里选的那个 —— 设置可能是"自动识别",
    /// 而这几个控件要按真正在播的那个 App 发指令。
    private var currentPlayer: PlaybackPlayer? {
        let bundleID = LocalPlaybackSource.shared.lastResolvedBundleID
        return PlaybackPlayer.allCases.first { $0 != .auto && $0.bundleIdentifier == bundleID }
    }

    /// 能接受「播放模式 / 音量」这两组扩展控制的当前播放器,不能就是 nil(按钮据此不显示)。哪些播放器
    /// 能见 MusicPlaybackController.supportsExtendedControls;QQ 音乐只有模式(菜单栏「播放模式」,
    /// `QQMusicMenuControl`),音量读不到、那颗胶囊不出现。网易云等 .app 里没有 .sdef 的不行。
    private var extendedControlPlayer: PlaybackPlayer? {
        guard let player = currentPlayer,
              MusicPlaybackController.supportsExtendedControls(player) else { return nil }
        return player
    }

    /// 有「喜欢」的当前播放器(见 MusicPlaybackController.supportsFavorite),没有就是 nil(按钮据此不显示)。
    private var favoritePlayer: PlaybackPlayer? {
        guard let player = currentPlayer, MusicPlaybackController.supportsFavorite(player) else { return nil }
        return player
    }

    /// 循环键、点赞、音量走浏览器里 YouTube Music 网页版(`YouTubeMusicWebControls`)时的那个浏览器,不是就 nil。只在当前播放器
    /// 不是内置播放器时看(内置的走 `extendedControlPlayer` / `favoritePlayer`)。网页版没有随机。
    /// `resolvedWebPlatformID` 只是推断,读写脚本另外核对页面上放的是不是当前这一首(带上标题),见 02 章决策 150。
    private var youtubeMusicWebTarget: YouTubeMusicWebControls.Target? {
        guard currentPlayer == nil else { return nil }
        return YouTubeMusicWebControls.target(
            reportedBundleID: LocalPlaybackSource.shared.lastResolvedBundleID, webPlatformID: resolvedWebPlatformID,
            title: LocalPlaybackSource.shared.title,
            isPaired: { BrowserPositionProbe.shared.isPaired(bundleID: $0, platformID: YouTubeMusicWebControls.platformID) })
    }

    /// 网页版三样一次读回,各按自己的动作序号丢弃过期结果(同 `refreshExtendedControls`)。
    private func refreshYouTubeMusicWeb(_ web: YouTubeMusicWebControls.Target, mode: Bool, favorite: Bool, volume: Bool) {
        let favSeq = favoritedActionSeq
        let modeSeq = playbackModeActionSeq
        let volSeq = volumeActionSeq
        Task.detached(priority: .utility) {
            let state = YouTubeMusicWebControls.readState(web)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if mode, self.playbackModeActionSeq == modeSeq {
                    self.applyPlaybackMode(state?.mode.map {
                        MusicPlaybackController.PlaybackModeState(mode: $0, options: YouTubeMusicWebControls.modeOptions)
                    })
                }
                if favorite, self.favoritedActionSeq == favSeq, self.isFavorited != state?.liked {
                    self.isFavorited = state?.liked
                }
                if volume, self.volumeActionSeq == volSeq, self.soundVolume != state?.volume {
                    self.soundVolume = state?.volume
                }
            }
        }
    }

    /// Apple Music 走 AppleScript 需要"自动化"权限;后台刷新路径上检查它,**绝不弹窗**。
    /// Spotify 不走这个检查:本仓没有针对它的权限探测(读播放位置那条路也没有),权限没给时
    /// 脚本自然失败、读回 nil,按钮不显示 —— 跟"读不出来就不显示"是同一个降级路径。
    ///
    /// 只能在后台任务里 await,别改回主线程上同步调 `MusicAutomationPermission.check`:
    /// 那次系统调用可能永远不返回,整个 App 跟着冻住(02 章决策 8)。查询超时当没权限。
    nonisolated private static func backgroundRefreshAllowed(for player: PlaybackPlayer) async -> Bool {
        guard player == .appleMusic else { return true }
        return await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: false)
    }

    private func clearExtendedControls() {
        if isFavorited != nil { isFavorited = nil }
        applyPlaybackMode(nil)
        if soundVolume != nil { soundVolume = nil }
        applyVolumeHint(player: nil, volume: nil)
    }

    /// 见 volumeHint。读洛雪的配置文件(按修改时间缓存,很便宜)。
    private func applyVolumeHint(player: PlaybackPlayer?, volume: Int?) {
        let config = player == .lxMusic && volume == nil ? LXMusicOpenAPI.shared.currentConfig() : nil
        let hint = player == .lxMusic && volume == nil && config?.enabled != true
            ? L10n.t("在洛雪音乐的设置中开启开放 API 后可调节音量") : nil
        let level = hint == nil ? nil : LXMusicOpenAPI.configVolumePercent(config)
        if volumeHint != hint { volumeHint = hint }
        if volumeHintLevel != level { volumeHintLevel = level }
    }

    /// 换歌时的三项后台回读(喜欢/播放模式/音量)合并成**一次** osascript 子进程,不分三次 fork、
    /// 三次 TCC 检查。三个 seq 守卫各管各的:期间用户点了喜欢/切了模式/拖了音量,对应项的回读结果
    /// 单独作废,不牵连另两项。
    func refreshExtendedControls() {
        guard let player = extendedControlPlayer else {
            if let web = youtubeMusicWebTarget {
                // 不先清,换歌时几颗键不闪一下。
                refreshYouTubeMusicWeb(web, mode: true, favorite: true, volume: true)
            } else if favoritePlayer != nil {
                // 只有「喜欢」、没有播放模式和音量的播放器(网易云等):另两项清掉,喜欢单独回读,不先清(换歌时心不闪)。
                // 见 07 章决策 146。
                applyPlaybackMode(nil)
                if soundVolume != nil { soundVolume = nil }
                applyVolumeHint(player: nil, volume: nil)
                refreshFavorited()
            } else {
                clearExtendedControls()
            }
            return
        }
        let includeFavorited = MusicPlaybackController.supportsFavorite(player)
        let favSeq = favoritedActionSeq
        let modeSeq = playbackModeActionSeq
        let volSeq = volumeActionSeq
        Task.detached(priority: .utility) {
            guard await Self.backgroundRefreshAllowed(for: player) else {
                await MainActor.run { [weak self] in self?.clearExtendedControls() }
                return
            }
            let state = MusicPlaybackController.extendedControlsState(
                for: player, includeFavorited: includeFavorited)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.favoritedActionSeq == favSeq {
                    let value = includeFavorited && !self.favoriteBlockedForTrack ? state.favorited : nil
                    if self.isFavorited != value { self.isFavorited = value }
                }
                if self.playbackModeActionSeq == modeSeq {
                    self.applyPlaybackMode(state.mode)
                }
                if self.volumeActionSeq == volSeq, self.soundVolume != state.volume {
                    self.soundVolume = state.volume
                }
                self.applyVolumeHint(player: player, volume: state.volume)
            }
        }
    }

    /// 「喜欢」读的是别处的播放器(菜单标题、Amazon 的资料库):换歌那一刻那次回读可能读到上一首的,`favoriteSettleSeconds` 后再读一次纠正。
    private func scheduleSettledFavoriteRefresh() {
        settledFavoriteRefresh?.cancel()
        guard let player = favoritePlayer, MusicPlaybackController.favoriteSettlesAfterTrackChange(player) else { return }
        settledFavoriteRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MusicPlaybackController.favoriteSettleSeconds))
            guard !Task.isCancelled else { return }
            self?.refreshFavorited()
        }
    }

    /// 重新读一次当前曲目的"喜欢"状态。当前在播的播放器没有「喜欢」、或 Apple Music 的自动化权限还没拿到时
    /// 置 nil(按钮据此整个不显示)。
    ///
    /// 权限用 askIfNeeded: false 检查 —— 这是个后台刷新,绝不能因为它弹出系统授权对话框。
    func refreshFavorited() {
        guard let player = favoritePlayer else {
            if let web = youtubeMusicWebTarget {
                refreshYouTubeMusicWeb(web, mode: false, favorite: true, volume: false)
            } else if isFavorited != nil {
                isFavorited = nil
            }
            return
        }
        if favoriteBlockedForTrack {
            if isFavorited != nil { isFavorited = nil }
            return
        }
        let seq = favoritedActionSeq
        Task.detached(priority: .utility) {
            let value = await Self.backgroundRefreshAllowed(for: player)
                ? MusicPlaybackController.favoritedState(for: player) : nil
            await MainActor.run { [weak self] in
                guard let self, self.favoritedActionSeq == seq else { return }
                guard self.isFavorited != value else { return }
                self.isFavorited = value
            }
        }
    }

    /// 重新读一次播放模式。跟 refreshFavorited 同一套前置判断和后台线程约定。
    func refreshPlaybackMode() {
        if extendedControlPlayer == nil, let web = youtubeMusicWebTarget {
            refreshYouTubeMusicWeb(web, mode: true, favorite: false, volume: false)
            return
        }
        guard let player = extendedControlPlayer else {
            applyPlaybackMode(nil)
            return
        }
        let seq = playbackModeActionSeq
        Task.detached(priority: .utility) {
            let value = await Self.backgroundRefreshAllowed(for: player)
                ? MusicPlaybackController.playbackMode(for: player) : nil
            await MainActor.run { [weak self] in
                guard let self, self.playbackModeActionSeq == seq else { return }
                self.applyPlaybackMode(value)
            }
        }
    }

    /// 重新读一次 Music.app 的音量。跟 refreshFavorited 同一套前置判断与守卫。
    func refreshVolume() {
        guard let player = extendedControlPlayer else {
            if let web = youtubeMusicWebTarget {
                refreshYouTubeMusicWeb(web, mode: false, favorite: false, volume: true)
            } else if soundVolume != nil {
                soundVolume = nil
            }
            return
        }
        let seq = volumeActionSeq
        Task.detached(priority: .utility) {
            let value = await Self.backgroundRefreshAllowed(for: player)
                ? MusicPlaybackController.soundVolume(for: player) : nil
            await MainActor.run { [weak self] in
                guard let self, self.volumeActionSeq == seq else { return }
                self.applyVolumeHint(player: player, volume: value)
                guard self.soundVolume != value else { return }
                self.soundVolume = value
            }
        }
    }

    /// 拖音量滑杆。跟"喜欢"一样先乐观更新再写回去 —— 滑杆必须跟着手指走,不能等
    /// osascript 往返(实测约 125ms)才动。
    func setVolume(_ value: Int) {
        let writer: VolumeWriter
        if let player = extendedControlPlayer {
            writer = .player(player)
        } else if let web = youtubeMusicWebTarget {
            writer = .youtubeMusicWeb(web)
        } else {
            return
        }
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
        pumpVolumeWrite(for: writer)
    }

    /// 音量写给谁:内置播放器走它自己的脚本,YouTube Music 网页版改它页面上的音量条。
    private enum VolumeWriter: Sendable {
        case player(PlaybackPlayer)
        case youtubeMusicWeb(YouTubeMusicWebControls.Target)
    }

    /// 把排队的音量值写下去。同一时刻只允许一次在飞;写完如果期间又来了新值,立刻补写一次,
    /// 保证最后松手的那个值一定落地。
    private func pumpVolumeWrite(for writer: VolumeWriter) {
        guard !volumeWriteInFlight, let target = pendingVolumeTarget else { return }
        pendingVolumeTarget = nil
        volumeWriteInFlight = true
        Task.detached(priority: .userInitiated) {
            // 权限弹窗只对 Apple Music 弹 —— 这是用户主动点的,该问就问;Spotify 没有对应的
            // 探测,直接发脚本,失败了走下面的回读纠正。
            // let(不是 var):var 会被下面的 MainActor.run 闭包捕获,Swift 6 模式下直接是错误。
            let ok: Bool
            switch writer {
            case .player(let player):
                if player == .appleMusic,
                   await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                    ok = false
                } else {
                    ok = MusicPlaybackController.setSoundVolume(target, for: player)
                }
            case .youtubeMusicWeb(let web):
                ok = YouTubeMusicWebControls.setVolume(target, web)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.volumeWriteInFlight = false
                if self.pendingVolumeTarget != nil {
                    // 拖动还在继续(或刚结束但最后一个值还没写),补写最新的那个。
                    self.pumpVolumeWrite(for: writer)
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

    /// `playbackMode` 与 `playbackModeOptions` 的唯一写入点。判等再写,两个都是 @Published。
    private func applyPlaybackMode(_ state: MusicPlaybackController.PlaybackModeState?) {
        let mode = state?.mode
        let options = state?.options ?? []
        if playbackMode != mode { playbackMode = mode }
        if playbackModeOptions != options { playbackModeOptions = options }
    }

    /// 直接设到某一档(歌词窗口按 Apple Music 排布把三态拆成「随机/循环」两颗
    /// 互斥按钮,要的是"点谁设谁"而不是循环下一档)。乐观更新/权限检查/写成功不回读,
    /// 跟 toggleFavorited 完全同一套取舍。
    func setPlaybackMode(_ target: MusicPlaybackController.MusicPlaybackMode) {
        if extendedControlPlayer == nil, let web = youtubeMusicWebTarget {
            setYouTubeMusicWebMode(target, web: web)
            return
        }
        guard let player = extendedControlPlayer else { return }
        // 播放器此刻够不到的档位静默降为列表,别让乐观更新画出一个永远写不进去的图标。
        let options = playbackModeOptions
        let resolved: MusicPlaybackController.MusicPlaybackMode = options.allows(target) ? target : .list
        applyPlaybackMode(MusicPlaybackController.PlaybackModeState(mode: resolved, options: options))
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

    /// 网页版的循环键,取舍同 `setPlaybackMode`:乐观更新、写成了不回读、没写成回读纠正。
    private func setYouTubeMusicWebMode(_ target: MusicPlaybackController.MusicPlaybackMode,
                                        web: YouTubeMusicWebControls.Target) {
        let options = playbackModeOptions
        let resolved: MusicPlaybackController.MusicPlaybackMode = options.allows(target) ? target : .list
        applyPlaybackMode(MusicPlaybackController.PlaybackModeState(mode: resolved, options: options))
        playbackModeActionSeq &+= 1
        Task.detached(priority: .userInitiated) {
            guard !YouTubeMusicWebControls.setMode(resolved, web) else { return }
            await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
        }
    }

    /// 点心:翻转当前曲目的"喜欢"状态。先乐观更新本地状态好让按钮立刻有反馈;写被接受了就不回读
    /// (Music.app 的 getter 会滞后),写失败或等待期间换了歌才回读纠正。
    ///
    /// 权限检查用 askIfNeeded: true —— 这是用户主动点的,该问就问,跟播放控制那三个按钮同一套
    /// (见 LyricsOverlayWindowController.withMusicPermission)。
    func toggleFavorited() {
        if favoritePlayer == nil, let web = youtubeMusicWebTarget {
            // 网页版的赞,取舍同下面:乐观更新、写成了不回读、没写成回读纠正。
            let target = !(isFavorited ?? false)
            isFavorited = target
            favoritedActionSeq &+= 1
            Task.detached(priority: .userInitiated) {
                guard !YouTubeMusicWebControls.setLiked(target, web) else { return }
                await MainActor.run { [weak self] in self?.refreshFavorited() }
            }
            return
        }
        guard let player = favoritePlayer, !favoriteBlockedForTrack else { return }
        let target = !(isFavorited ?? false)
        isFavorited = target
        favoritedActionSeq &+= 1
        let trackKey = currentTrackKey
        let writtenAt = Date()
        lastFavoriteWrite = (trackKey, writtenAt)
        let delay = MusicPlaybackController.favoriteWriteDelay(for: player,
                                                               sinceTrackChange: Date().timeIntervalSince(trackChangedAt))
        Task.detached(priority: .userInitiated) {
            // 刚换歌:菜单标题可能还是上一首的状态,照它判断会把这一首按反。等标题换好;等的时候又换了歌就作废。
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard await MainActor.run(body: { [weak self] in self?.currentTrackKey == trackKey }) else {
                    await MainActor.run { [weak self] in self?.refreshFavorited() }
                    return
                }
            }
            // Apple Music 用 checkAppleMusicSafely 而不是 checkForCurrentPlayerSafely:后者在设置为
            // "自动识别"时会直接返回 true(它假定别的播放器不需要这个权限),而这里已经确认
            // 实际在播的就是 Apple Music,必须真的查一次权限,否则下面的 AppleScript 会静默失败。
            if player == .appleMusic,
               await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                await MainActor.run { [weak self] in self?.refreshFavorited() }
                return
            }
            // 跟播放模式同一个道理:写被接受了就别马上回读,Music.app 的 getter 会滞后。Kaset 没登录时不理这条命令,
            // 那时 setFavorited 回 false,照样回读纠正。
            guard !MusicPlaybackController.setFavorited(target, for: player) else {
                // Music.app 的写入要好几秒才生效,这期间反向再写一次会被吞掉。过了滞后期这次仍是最后一次写、还是这一首时
                // 回读一次,跟写的不一样就补写。见 07 章决策 175。
                guard MusicPlaybackController.reconcilesFavoriteAfterWrite(player) else { return }
                try? await Task.sleep(for: .seconds(MusicPlaybackController.favoriteReadbackLagSeconds))
                let stillLatest = await MainActor.run { [weak self] in
                    self?.lastFavoriteWrite?.at == writtenAt && self?.currentTrackKey == trackKey
                }
                guard stillLatest, let landed = MusicPlaybackController.favoritedState(for: player), landed != target else { return }
                logger.notice("toggleFavorited: favorite write did not stick for \(player.rawValue, privacy: .public), writing again")
                _ = MusicPlaybackController.setFavorited(target, for: player)
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 读别处状态的播放器按下去没生效:多半是没登录(弹了登录窗口)、界面上找不到那颗键,这一首不再显示心、不再按。
                if MusicPlaybackController.favoriteSettlesAfterTrackChange(player), self.currentTrackKey == trackKey {
                    logger.notice("toggleFavorited: favorite did not change for \(player.rawValue, privacy: .public), hiding the heart for this track")
                    self.favoriteUnavailableTrackKey = trackKey
                }
                self.refreshFavorited()
            }
        }
    }

    enum ShortcutFavoriteResult { case liked, unliked, notPlaying, unsupported, needsPermission }

    /// 全局快捷键 / `action/toggle-favorite` 的「喜欢」。界面都没开时 `isFavorited` 可能是上一首的、或者还没读过,照它取反会
    /// 按反:内置播放器先读一次这一首此刻的状态,`on` 给了就设成它,没给就取反。写入交给 `toggleFavorited`(乐观更新、
    /// 刚换歌时等标题、写不成回读都在那边)。网页版没有同步读法,照界面那份取反。
    func toggleFavoritedFromShortcut(on: Bool?, done: @escaping @MainActor @Sendable (ShortcutFavoriteResult) -> Void) {
        guard !title.isEmpty else { return done(.notPlaying) }
        if favoritePlayer == nil, youtubeMusicWebTarget != nil {
            let now = isFavorited ?? false
            let target = on ?? !now
            if target != now { toggleFavorited() }
            return done(target ? .liked : .unliked)
        }
        guard let player = favoritePlayer, !favoriteBlockedForTrack else { return done(.unsupported) }
        let trackKey = currentTrackKey
        Task.detached(priority: .userInitiated) {
            if player == .appleMusic, await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                await MainActor.run { done(.needsPermission) }
                return
            }
            let current = MusicPlaybackController.favoritedState(for: player)
            await MainActor.run { [weak self] in
                guard let self, self.currentTrackKey == trackKey else { return }
                let sinceWrite = self.lastFavoriteWrite.flatMap { $0.trackKey == trackKey ? Date().timeIntervalSince($0.at) : nil }
                if let current, MusicPlaybackController.adoptsFavoriteReadback(current, local: self.isFavorited,
                                                                               sinceLocalWrite: sinceWrite) {
                    self.isFavorited = current
                    self.favoritedActionSeq &+= 1
                }
                let now = self.isFavorited ?? false
                let target = on ?? !now
                if target != now { self.toggleFavorited() }
                done(target ? .liked : .unliked)
            }
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
        // 这一组里的去抖都挂主队列、别挂 RunLoop.main:菜单栏菜单开着时主线程在事件跟踪模式里转,RunLoop.main 的计时器
        // 要等菜单关了才走,换歌后的高清封面、收藏 / 随机状态都会跟着晚(见 01 章决策 11)。
        cancellables = [
            // 洛雪开放 API 开着时,屏上每换一句告诉它一声,跟洛雪自己换句的时刻比(只进日志,见 LXMusicLyricCheck)。
            $currentLine.map { $0?.plainText ?? "" }.removeDuplicates()
                .sink { [weak self] text in
                    guard self?.currentPlayer == .lxMusic else { return }
                    LXMusicOpenAPI.shared.noteDisplayedLine(text, at: Date())
                },
            // 洛雪开放 API 推来收藏、音量的变化(在洛雪里点的也算):回读这两项。
            NotificationCenter.default.publisher(for: LXMusicOpenAPI.controlsChangedNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, self.currentPlayer == .lxMusic else { return }
                    self.refreshFavorited()
                    self.refreshVolume()
                },
            s.$title.assign(to: \.title, on: self),
            s.$title.map(TrackNameDisplay.cleaned).removeDuplicates().assign(to: \.displayTitle, on: self),
            // 换歌就重读一次"喜欢"状态。用 title+artist 组合去重而不是只看 title:同名不同
            // 歌手的曲目(翻唱/合辑里很常见)只看 title 会被当成同一首,漏掉一次刷新。
            // 防抖 50ms:LocalPlaybackSource 换歌时 title / artist 是先后分开写的,不压一下会先放出一个
            // 「新歌名|旧歌手」的中间态,一次换歌就起两次 osascript 回读(停播时依次清空也一样)。
            s.$title.combineLatest(s.$artist)
                .map { "\($0)|\($1)" }
                .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
                .removeDuplicates()
                .sink { [weak self] key in
                    guard let self else { return }
                    self.trackChangedAt = Date()
                    self.currentTrackKey = key
                    // 三项合并成一次 osascript 回读,见
                    // refreshExtendedControls;单项 refresh 保留给写后回读/视图 onAppear。
                    self.refreshExtendedControls()
                    self.scheduleSettledFavoriteRefresh()
                },
            s.$artist.assign(to: \.artist, on: self),
            // 除了 artist / title 变化,纠正文件换了一版也要重算:署名本来就干净的歌,纠正落地时
            // artist / title 一个字都不变(App 2 秒一拍、引擎 5 秒一拍,App 先看到新歌那一拍
            // 文件里还是上一首),只靠 combineLatest 会把这首歌的歌手位整首钉在空串上。
            // 文件变了没有靠 PlayerArtistFix.changes(盯配置目录的目录事件),不每秒 stat;只在播放时订阅,
            // 暂停 / 停播时纠正文件不会变。恢复播放时立刻补一拍(prepend)。见 02 章决策 139。
            s.$artist.combineLatest(
                s.$title,
                s.$isPlayingNow.removeDuplicates()
                    .map { playing -> AnyPublisher<Void, Never> in
                        playing
                            ? PlayerArtistFix.changes.prepend(()).eraseToAnyPublisher()
                            : Just(()).eraseToAnyPublisher()
                    }
                    .switchToLatest(),
                $inferredIdentity
            )
                .map { artist, title, _, inferred in
                    InferredTrackIdentity.displayArtist(
                        playerArtist: artist,
                        display: PlayerArtistFix.displayArtist(
                            bundle: LocalPlaybackSource.shared.lastResolvedBundleID,
                            title: title, artist: artist),
                        inferred: inferred)
                }
                .map(TrackNameDisplay.cleaned)
                .removeDuplicates()
                .assign(to: \.displayArtist, on: self),
            s.$album.assign(to: \.album, on: self),
            s.$youtubeMusicAlbum.assign(to: \.youtubeMusicAlbum, on: self),
            s.$album.combineLatest(s.$youtubeMusicAlbum, s.$isMusicVideo, s.$youtubeMusicIsMV)
                .combineLatest($inferredIdentity)
                .map { fields, inferred in
                    let (album, listed, isMusicVideo, listedMV) = fields
                    let display = LocalPlaybackSource.displayAlbum(album: album, youtubeMusicAlbum: listed, isMusicVideo: isMusicVideo || listedMV,
                                                                   musicVideoLabel: L10n.t("MV"))
                    return InferredTrackIdentity.displayAlbum(playerAlbum: album, display: display, inferred: inferred)
                }
                .map(TrackNameDisplay.cleaned)
                .removeDuplicates()
                .assign(to: \.displayAlbum, on: self),
            s.$isPlayingNow.assign(to: \.isPlayingNow, on: self),
            s.$isPlayingNow.sink { [weak self] playing in self?.updateSmoothedPlaying(playing) },
            s.$isWaitingToPlay.assign(to: \.isWaitingToPlay, on: self),
            s.$playbackControlsWithheldBundleID.removeDuplicates()
                .map { $0.map(PlaybackCoordinator.withheldControlsReason(bundleID:)) }
                .assign(to: \.playbackControlsWithheldReason, on: self),
            s.$currentLine.sink { [weak self] line in
                logger.debug("coordinator currentLine updated: hasLine=\(line != nil) hasWords=\(line?.words != nil) hasMainText=\(line?.mainText != nil)")
                self?.currentLine = line
            },
            s.$nextLineText.assign(to: \.nextLineText, on: self),
            s.$nextLineSide.assign(to: \.nextLineSide, on: self),
            s.$nextLineRomanization.assign(to: \.nextLineRomanization, on: self),
            s.$nextLineTranslation.assign(to: \.nextLineTranslation, on: self),
            s.$nextLineWordGroups.assign(to: \.nextLineWordGroups, on: self),
            s.$anchor.assign(to: \.anchor, on: self),
            s.$hasLyricsContent.assign(to: \.hasLyricsContent, on: self),
            s.$isCurrentTrackInstrumental.assign(to: \.isCurrentTrackInstrumental, on: self),
            s.$currentTrackHasNoLyrics.assign(to: \.currentTrackHasNoLyrics, on: self),
            // 防抖 50ms:两项是先后分开写的,从纯音乐换到一首没搜到词的歌会先放出一个「两项都是 false」的中间态,
            // 不压一下开着「纯音乐/无歌词时隐藏」的窗口会闪出来一下、灵动岛的歌词行会弹出来一下(见 04 章决策 58)。
            s.$isCurrentTrackInstrumental.combineLatest(s.$currentTrackHasNoLyrics)
                .map { NoLyricsAutoHide.lacksLyrics(isInstrumental: $0, hasNoLyrics: $1) }
                .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
                .removeDuplicates()
                .assign(to: \.currentTrackLacksLyrics, on: self),
            s.$currentTrackPlainLyrics.assign(to: \.currentTrackPlainLyrics, on: self),
            s.$currentTrackSongwriters.assign(to: \.currentTrackSongwriters, on: self),
            s.$engineNetworkDown.assign(to: \.engineNetworkDown, on: self),
            s.$isCurrentTrackAdBreak.assign(to: \.isCurrentTrackAdBreak, on: self),
            s.$isRadioTalkBreak.assign(to: \.isRadioTalkBreak, on: self),
            s.$radioStationName.assign(to: \.radioStationName, on: self),
            // 台标同样在这一层解一次码,消费方直接拿 NSImage —— 理由同下面 artworkImage 那条。
            s.$radioStationArtwork
                .map { $0.flatMap { NSImage(data: $0) } }
                .assign(to: \.radioStationImage, on: self),
            s.$currentAdSlot.assign(to: \.currentAdSlot, on: self),
            s.$adCountdown.assign(to: \.adCountdown, on: self),
            s.$currentLineIndex.assign(to: \.currentLineIndex, on: self),
            s.$scrollLineIndex.assign(to: \.scrollLineIndex, on: self),
            s.$overlappingLineIndices.assign(to: \.overlappingLineIndices, on: self),
            s.$overlayLyrics.assign(to: \.overlayLyrics, on: self),
            s.$notchLyrics.assign(to: \.notchLyrics, on: self),
            s.$menuBarLyrics.assign(to: \.menuBarLyrics, on: self),
            s.$touchBarLyrics.assign(to: \.touchBarLyrics, on: self),
            s.$menuBarSongRowWidth.assign(to: \.menuBarSongRowWidth, on: self),
            s.$compactLine.assign(to: \.compactLine, on: self),
            s.$compactShowsPlaceholder.assign(to: \.compactShowsPlaceholder, on: self),
            s.$compactDwellMs.assign(to: \.compactDwellMs, on: self),
            s.$compactLeadInMs.assign(to: \.compactLeadInMs, on: self),
            s.$allLines.assign(to: \.allLines, on: self),
            s.$lyricsGapMarkers.assign(to: \.lyricsGapMarkers, on: self),
            s.$currentGapIndex.assign(to: \.currentGapIndex, on: self),
            s.$rawGapWindow.assign(to: \.rawGapWindow, on: self),
            s.$currentLineFillSettled.assign(to: \.currentLineFillSettled, on: self),
            s.$artworkData.assign(to: \.artworkData, on: self),
            // 解码在这里做一次,消费方直接拿 NSImage,不在 view body 里反复解同一张图,见 artworkImage
            // 声明处的注释。@Published 的 willSet 语义让这两条订阅在同一次调用里同步跑完,artworkData 和
            // artworkImage 不会跨渲染帧不一致(SwiftUI 在这一轮 runloop 结束时才真正重绘)。
            s.$artworkData
                .map { $0.flatMap { NSImage(data: $0) } }
                .assign(to: \.artworkImage, on: self),
            // 高清封面:换歌或换封面之后重找一次,见 highResArtworkImage 的注释。
            //
            // debounce 不是为了省请求,是为了**避开 @Published 的 willSet 时机**:
            // 这四个属性各自的订阅回调都跑在"值还没落库"的那一刻,回调里读 self 的其它
            // 属性可能读到上一首的值。等 300ms 之后所有
            // willSet 都已落定,refreshHighResCover() 再去读一份自洽的快照。
            // 这 300ms 用户看不见 —— 系统那张小图在第一帧就已经显示了。
            Publishers.CombineLatest4(s.$title, s.$artist, s.$album, s.$artworkData)
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] _, _, _, _ in
                    self?.refreshInferredIdentity()
                    self?.refreshHighResCover()
                    // 动态封面挂同一个时机、同一个理由(避开 willSet、300ms 用户无感),
                    // 不另起一条 debounce。
                    self?.refreshMotionCover()
                },
            // 认出占位图那一刻封面字节不一定变(上一首本来就没有封面),上面那条不会触发:这里补查一次(见 03 章决策 32)。
            s.$artworkIsPlaceholder
                .removeDuplicates()
                .filter { $0 }
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshHighResCover(onlyIfMissing: true) },
            // 缓存里多了东西也要补查一次:换歌那条(CombineLatest4)只在曲目/封面字节变化时跑,而引擎解析一首
            // 没听过的歌要好几秒(开播后七八秒才写进 cover_url),换歌后 300ms 那一次必然查空;不补查的话
            // 整首歌都停在系统那张小图上(网易云只给 100×100)。
            //
            // 必须 onlyIfMissing —— refreshHighResCover 开头会 clearHighRes(),已经拿到
            // 高清图时再跑一遍就是"清空→重设",而 highResArtworkImage 挂着 0.5s 交叉淡入,
            // 表现成封面每隔几秒闪一下。而引擎写缓存是常态(每解析一首歌都写)。
            s.$enrichContentVersion
                .dropFirst() // 启动时那一次不是"新解析出来的",换歌那条路已经覆盖
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshInferredIdentity()
                    self?.refreshHighResCover(onlyIfMissing: true)
                    // 动态封面同样需要这条补查路 —— 它读的是引擎写的同一份 enrich 缓存,
                    // 第一次听的歌在换歌后 300ms 那一次必然查空(解析要好几秒)。
                    self?.refreshMotionCover(onlyIfMissing: true)
                },
            // 动态封面的两个总闸变化时立刻重算:用户拨了开关、或者系统进出低电量模式。
            // 关掉要当场停下(而不是等下一首),打开也该当场生效。
            // @Published 在 willSet 时发布:回调里再读 AppSettings.shared.motionCoverEnabled 拿到的是旧值,
            // 新值只能用发布出来的这个参数。
            settings.$motionCoverEnabled
                .dropFirst()
                .sink { [weak self] enabled in self?.refreshMotionCover(enabled: enabled) },
            // 动态封面要跟显示的封面比:高清替代换上、撤掉都重新比一次(见 refreshMotionCover)。
            $highResArtworkImage
                .dropFirst()
                .removeDuplicates { $0 === $1 }
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshMotionCover() },
            NotificationCenter.default.publisher(for: NSNotification.Name.NSProcessInfoPowerStateDidChange)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshMotionCover() },
            // Spotify 原生客户端的图床地址到了(开播 2.5s 后的位置探针顺带带回,
            // 见 LocalPlaybackSource.spotifyArtworkURL),或者系统封面字节变了(上面那条路会顺手清掉高清图,
            // 这里按同一地址放回去)。跟 artworkData 合在一起订阅、比上面多等 50ms,保证跑在
            // refreshHighResCover 的 clearHighRes() **之后**,不然刚换上的原图会被它撤掉。
            Publishers.CombineLatest(s.$spotifyArtworkURL, s.$artworkData)
                .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
                .sink { [weak self] url, _ in self?.refreshSpotifyOriginalCover(url) },
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
                // 可言 —— 退回保证够亮的那条规则。
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
            // 输出去重:四个输入里任何一个抖动(高清 hex 的 nil 重赋值是
            // 常客)都会重发,而算出来的颜色多数时候没变——Color? 是 Equatable,挡在
            // assign 前面,别让 coordinator 的全部观察面白挨一轮 objectWillChange。
            .removeDuplicates()
            .assign(to: \.artworkAccentColor, on: self),
            // 灵动岛:背景永远深色,判据是"够亮"——先过 HSB 亮度地板,再补一道感知亮度
            // 下限(饱和冷色 HSB 地板拦不住,见 accentForDarkBackdrop)。
            //
            // notchCardStyle 也是输入:上面两步假设背景永远接近纯黑,对纯黑/深色渐变两种风格成立,
            // 但 coverArt 风格的背景亮度正比于封面本身的亮度——亮封面(比如黄底)叠 45% 黑之后依然不暗,
            // 固定的文字亮度地板量不出这种情况,文字会跟背景撞色(实测 WCAG 对比度只有 2.78;灵动岛字号
            // 9~13.5pt 够不上 WCAG 大号文字那档,门槛该是 4.5)。只在这个风格下多算一步
            // accentForCoverArtBackground,纯黑/深色渐变两种风格背景是真的暗,不需要多算。
            // 背景亮区(`notchBackdropTone`)到了就按它查:歌词落在封面亮区时看得清看不清取决于那一块,均值会估低;
            // 背景压暗也随亮区加深,两者配套传。还没烘出来时按均值和固定压暗查。
            Publishers.CombineLatest4(s.$artworkAverageHex, $highResAverageHex, settings.$notchCardStyle, $notchBackdropTone)
                .map { systemHex, highResHex, cardStyle, tone -> Color? in
                    guard let hex = highResHex ?? systemHex,
                          let ns = NSColor(hexStringWithAlpha: hex) else { return nil }
                    let rawR = ns.redComponent, rawG = ns.greenComponent, rawB = ns.blueComponent
                    let base = LocalPlaybackSource.brightenedAccent(r: rawR, g: rawG, b: rawB)
                    var lifted = LocalPlaybackSource.accentForDarkBackdrop(
                        r: base.r, g: base.g, b: base.b)
                    if cardStyle == .coverArt {
                        lifted = LocalPlaybackSource.accentForCoverArtBackground(
                            r: lifted.r, g: lifted.g, b: lifted.b,
                            rawR: tone?.r ?? rawR, rawG: tone?.g ?? rawG, rawB: tone?.b ?? rawB,
                            overlayOpacity: tone?.overlayOpacity ?? LocalPlaybackSource.notchCoverArtOverlayOpacity)
                    }
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
                // 恒等去重:高清封面刷新路径会对 highResArtworkImage
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
            // 换歌时旧封面先清空、新封面要过零点几秒才到:这段空档里先别撤背景。撤了歌词窗口就露出
            // 窗口底色(浅色外观下是白的),每次换歌闪一下白(07 章决策 84)。新封面在等待期内到了,
            // 这个任务被下一次烘焙取消、背景直接交叉淡入接上;真没封面才撤。
            blurBakeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.artworkGapGraceNanos)
                guard let self, !Task.isCancelled else { return }
                if self.blurredArtworkImage != nil { self.blurredArtworkImage = nil }
                if self.notchBackdropTone != nil { self.notchBackdropTone = nil }
                if self.windowBackgroundLayers != nil { self.windowBackgroundLayers = nil }
            }
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
                let notch = Self.bakeBackgroundBlur(cgImage: cg, targetWidth: 720, sigma: 40, saturation: nil)
                let tone = notch?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(NotchBackdropTone.bright(cgImage:))
                return (notch: notch, tone: tone, window: Self.bakeWindowBackgroundLayers(cgImage: cg, seed: seed))
            }.value
            guard let self, !Task.isCancelled else { return }
            // 烘不出来(解码 / 渲染失败)也要覆盖掉:留着就是上一首的背景挂在这一首上。
            self.notchBackdropTone = baked.tone
            self.blurredArtworkImage = baked.notch
            self.windowBackgroundLayers = baked.window
        }
    }

    /// 封面清空后等多久才撤背景(见 rebakeBlurredArtwork)。要盖住换歌时新封面到货的延迟(实测零点几秒),
    /// 又不能长到「真没封面」时上一首的背景挂得让人看出来。
    private static let artworkGapGraceNanos: UInt64 = 1_500_000_000

    nonisolated private static func stableSeed(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// 「歌词窗口」AM 式动画背景的图层烘焙。AM 的背景 ≈ 封面的宏观色彩布局,但明度布局被抹平:同屏对拍里 AM 各采样区的
    /// 明度都落在一个窄带里,色相却逐区各异;保留封面的明度布局会出现"左缘死黑 + 亮斑突兀",调 EV 够不着。做法:
    /// - 宏观场 = 6×6 面积平均降采样 + 逐格乘法亮度归一化(RGB × mean/L,homog 0.55 部分归一,系数夹 [0.4, 3.5] 防近黑格
    ///   爆噪)再放大,σ35 高斯只融格边。乘法保色相/饱和 —— 加法提黑会灰掉;纯高斯 σ 大混泥、σ 小见人形,所以是
    ///   "降采样出场、高斯只融边"。
    /// - 逐格饱和度归一 + 少数派色相收拢:饱和度低于目标的格子抬到目标(satTarget,按源图鲜艳端 satP75 的幂函数取;
    ///   近黑格不动,见 darkLumaFloor);偏离主色相(S² 加权圆均值)60°~120° 的格子夹回 ±60°(AM 的场 = 一个主色系 +
    ///   近亲点缀);灰阶封面两步都自动 no-op。
    /// - 成场后 CIVibrance 0.4 × hueCoherenceScale + 闭环饱和度乘子(= satTarget ÷ 融合后场的实测均值 S,上下限见 satMul):
    ///   σ35 融合互混 + 光斑 lighten 会磨掉约 30% 饱和,固定乘子对混合结构不同的封面不可能都对;闭环后鲜艳均匀的封面
    ///   乘子自动 <1,灰化结构自动 >1。
    /// - 底色 EV −0.15:归一化之后只需轻压。
    /// - 光斑锚原始最亮格(归一化前的亮度),羽化外沿 0.7W(AM 没有独立光斑,只有柔和的色场渐变)。
    /// - 视图层 3 层 lighten α0.25 摆动(α 在归一化的平场上影响很小)。
    /// 残余差异主要是 AM 各区内部还有 0.10~0.21 的柔和起伏(其动画瞬间的相位),我们单帧偏平,由摆动动画在时间维上补。
    /// 对拍数据见 07 章「背景取色逼近 Apple Music」。
    /// 歌词窗口背景两张位图存成排版边长的几分之一(见 bakeWindowBackgroundLayers 里的 render)。
    nonisolated static let windowBackgroundStoreDivisor: CGFloat = 3

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
        // 各格饱和度:下面判主色相、算 satP75、把欠饱和格子抬到 satTarget 都用它。AM 的背景饱和度跟着封面的
        // 鲜艳端走,不是面积均值:白纱/留白参与 6×6 平均会把格子灰化。灰阶封面各格 S≈0,后面几步自动不动。
        var cellSat = [Double](repeating: 0, count: 36)
        for i in 0..<36 {
            let o = i * 4
            let mx = Double(max(px[o], max(px[o + 1], px[o + 2])))
            let mn = Double(min(px[o], min(px[o + 1], px[o + 2])))
            cellSat[i] = mx > 0 ? (mx - mn) / mx : 0
        }
        // 少数派色相向主色相收拢:封面上小块杂色(如青色 logo)的格子会被下面的饱和归一放大成刺眼的纯色斑,
        // 而 AM 的场是"一个主色系 + 近亲色点缀"。主色相 hDom = S² 加权圆均值;偏离 60°~120° 的格子夹回主色相
        // ±60°(保留点缀、不抹掉),S/V 不动。离群权重占到 20% 以上时不收拢:那是构图里第二个真实色系(比如
        // 蓝天 + 暖色建筑),交给下面 σ35 高斯模糊做自然的空间过渡,硬夹会夹出一片假色。单色/灰阶封面各格
        // 本就贴着主色相或 S≈0 被跳过,自动 no-op。
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
        // 近黑格的饱和度读数不可信:肉眼纯黑的一大片背景,原始 RGB 往往带一丝几乎不可见的偏色(摄影黑位 /
        // JPEG 压缩常见),这个偏色的比值(HSV 饱和度)在亮度极小时会被放大到跟中高亮区一样高,把整张图的
        // 主色相拖偏("大面积纯黑 + 一小块金属反光"这类封面,能有两成格子亮度 ≈0.047 却读出 s≈0.36)。
        // 上面的亮度归一化只保留原有比值、不产生新色相,要的是一道"多暗就不信它的颜色"的判据:用归一化前
        // 的原始格亮度(`cellLuma`,光斑锚点也用它)设下限,低于它的格子不参与色相判定与 p75 统计,也不
        // 参与把欠饱和格子拉向 satTarget 的那次修正。0.08 是经验值(伪影格 ≈0.047、合理的暗色内容普遍
        // >0.1),不是精确阈值。
        let darkLumaFloor = 0.08
        var hueSin = 0.0, hueCos = 0.0
        for i in 0..<36 where cellSat[i] > 0.05 && cellLuma[i] > darkLumaFloor {
            let o = i * 4
            let (h, s, _) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
            hueSin += sin(h * .pi / 180) * s * s
            hueCos += cos(h * .pi / 180) * s * s
        }
        // 1 = 色相一致、正常走既有的饱和度放大;越接近 0 越是"噪声凑巧不为零",
        // 下面 satTarget/satMul/CIVibrance 按它收着放大,见算它那段的注释。
        var hueCoherenceScale = 1.0
        if hueSin != 0 || hueCos != 0 {
            let hDom = atan2(hueSin, hueCos) * 180 / .pi
            // 色相一致度:S² 加权圆均值向量的合成模长 / 总权重——多格色相互相印证(同一色系)时接近 1,
            // 彼此抵消(方向各异)时接近 0。hDom/offHueFraction 只管"要不要把离群格子夹回来",不管"这个 hDom
            // 本身有多可信":一张几乎无彩的封面(S 全在 0.06~0.22)也能算出一个看似成立的 hDom,那只是噪声方向
            // 凑巧不为零。对拍里灰阶封面 coherence≈0.27,两大真实色系 0.47,单一色系 0.59;低于参考值时按比例
            // 收着后面的饱和度放大(satTarget/satMul/CIVibrance 三处一起收)。
            var totalHueWeight = 0.0, offHueWeight = 0.0
            for i in 0..<36 where cellSat[i] > 0.05 && cellLuma[i] > darkLumaFloor {
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
                for i in 0..<36 where cellSat[i] > 0.05 && cellLuma[i] > darkLumaFloor {
                    let o = i * 4
                    let (h, s, v) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
                    var d = h - hDom
                    while d > 180 { d -= 360 }
                    while d < -180 { d += 360 }
                    // 上限 120°:色轮对面的真补色(比如蓝天对暖棕,相距 150° 上下)套用"偏离 60° 就拉近 60°"
                    // 的固定位移,新色相落在哪全看 d 的正负号,跟原色、跟主色相都不沾边,会夹出刺眼的桃红/紫红。
                    // 这套位移只为"近似色被饱和归一放大跑偏"的 60°~120° 窗口标定,超过 120° 原样放行,交给
                    // σ35 高斯模糊做自然过渡(跟 offHueFraction ≥ 20% 那条分支一个道理)。
                    guard abs(d) > 60, abs(d) <= 120 else { continue }
                    let (r, g, b) = hsvToRGB(hDom + (d > 0 ? 60 : -60), s, v)
                    px[o] = UInt8(min(255, max(0, r * 255)))
                    px[o + 1] = UInt8(min(255, max(0, g * 255)))
                    px[o + 2] = UInt8(min(255, max(0, b * 255)))
                }
            }
        }
        // satP75 同样排除近黑格(见上面 darkLumaFloor 的注释)——不然"大面积纯黑+一角
        // 高光"这类封面,近黑格的伪饱和度会直接顶到排序里的 p75 位置,把 satTarget 算
        // 得远高于封面实际观感。样本太暗、亮格不够 9 个(排序后 p75 位置会落空/退化)时
        // 退回全 36 格——这类封面本来就该给低 satTarget,不筛也没问题。
        let brightIdx = (0..<36).filter { cellLuma[$0] > darkLumaFloor }
        let satP75: Double
        if brightIdx.count >= 9 {
            let sats = brightIdx.map { cellSat[$0] }.sorted()
            satP75 = sats[min(sats.count - 1, Int(Double(sats.count) * 26.0 / 36.0))]
        } else {
            satP75 = cellSat.sorted()[26]
        }
        // 目标饱和度按源图鲜艳端(satP75)的幂函数取:AM_p75 ≈ 1.029 × satP75^1.433,是拿 36 组 Apple Music 真机截图
        // 跟同一张封面对拍、做对数-对数回归拟合出来的(源图越浓,AM 保留的比例越高,不是固定倍率)。要调就在那批数据上
        // 重新拟合,别凭感觉改。数据和排除过的假说见 07 章「背景取色逼近 Apple Music」第九、十轮。
        let satTarget = min(0.95, 1.029 * pow(satP75, 1.433)) * hueCoherenceScale
        for i in 0..<36 where cellSat[i] > 0.01 && cellSat[i] < satTarget && cellLuma[i] > darkLumaFloor {
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
        // 底图和光斑都出自 σ35 模糊过的平滑色场,按 720 排版、存成 1/3 边长:贴到整窗时放大看不出差别,
        // 常驻和窗口服务器那份位图各省九成(07 章决策 173)。
        func render(_ img: CIImage) -> NSImage? {
            let stored = W / Self.windowBackgroundStoreDivisor
            let small = img.transformed(by: CGAffineTransform(scaleX: stored / W, y: stored / W))
            guard let out = blurBakeContext.createCGImage(small, from: CGRect(x: 0, y: 0, width: stored, height: stored))
            else { return nil }
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
        // 上下限刻意没跟着 satTarget 的幂函数抬:回归数据里只有一组(蓝底 + 人像肤色,两大色系反差大)
        // 顶到过 1.6 的上限,抬到 2.2/3.5 也治不好(那张 σ35 模糊后 fieldS 0.56→0.15,网格 p75 会从 0.37 的
        // 目标冲到 0.8~1.0)。根子是"闭环乘子按面积均值 fieldS 算、目标 satTarget 按网格 p75 校准"的口径错位,
        // 抬上限只会把这类高反差封面推向过饱和,不抬则欠一截饱和度,两害相权取后者。数据见 07 章「背景取色
        // 逼近 Apple Music」。
        var satMul = 0.85
        let fieldAvg = field.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: frame),
        ])
        if let avgCG = blurBakeContext.createCGImage(fieldAvg, from: CGRect(x: 0, y: 0, width: 1, height: 1)),
           let d = avgCG.dataProvider?.data as Data?, d.count >= 3 {
            let mx = Double(max(d[0], max(d[1], d[2])))
            let mn = Double(min(d[0], min(d[1], d[2])))
            let fieldS = mx > 0 ? (mx - mn) / mx : 0
            // 上下限 0.35~1.6,跟 satTarget 的幂函数基数配套;上限也按 hueCoherenceScale 收,给色相一致的封面留够
            // 放大空间(coherenceScale=1 时上限不变)。
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

        // 背景均色 → HSB(见 WindowBackgroundLayers.tintHue / tintBrightness 的注释)。均色取烘焙后的 base
        // (就是屏幕上那层)。
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

    /// 背景模糊的离线烘焙(性能审计:替代视图层的合成期活滤镜)——灵动岛用,
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
    /// 判据是"≤ 300"而不是"< 300":QQ 音乐客户端往系统 Now Playing 报的封面恰好就是 300×300,
    /// 严格小于的话这条路对它一次都不会触发,而 300px 在封面卡上正是"3 倍放大、肉眼能看出软"那一档。
    ///
    /// 这不是唯一的触发条件:系统那份**不是方形**(长宽比偏离正方形超过 15%)时
    /// 也替,判定收在 `CoverArtReplacementGate`,理由见 highResArtworkImage 的注释。
    private static let lowResArtworkThreshold = 300

    /// 系统这份封面要不要找高清替代(nil = 不找),判据见 `CoverArtReplacementGate.reason`。
    /// `refreshHighResCover` 和 `seeksHighResCover` 共用这一处。
    private static func highResReplacementReason(systemSize: (width: Int, height: Int),
                                                 bundleID: String?, playerHasOwnCover: Bool) -> CoverArtReplacementGate.Reason? {
        CoverArtReplacementGate.reason(
            width: systemSize.width, height: systemSize.height, lowResThreshold: lowResArtworkThreshold,
            systemNeverHasArtwork: CoverArtReplacementGate.missingArtworkUsesMatchedCover(bundleID: bundleID),
            systemArtworkIsPlaceholder: LocalPlaybackSource.shared.artworkIsPlaceholder,
            playerHasOwnCover: playerHasOwnCover)
    }

    /// 正在放的这首在当前播放器里自带的封面(引擎从播放器本机数据里读的,见 `EnrichCacheReader.playerCoverURLs`),换成要大图时
    /// 那一档。没有为 nil。
    private static func currentPlayerOwnCover() -> URL? {
        let s = LocalPlaybackSource.shared
        guard let bundleID = s.lastResolvedBundleID, !s.title.isEmpty else { return nil }
        return EnrichCacheReader.playerCoverURLs(artist: s.artist, title: s.title, album: s.album)[bundleID]
            .map(EnrichCacheReader.nativeSizedCoverURL)
    }

    /// 播放器没报歌手时,读引擎认出来的歌手 / 专辑(见 `inferredIdentity`)。换歌、缓存内容变了时重读,跟高清封面同一个时机。
    private func refreshInferredIdentity() {
        let s = LocalPlaybackSource.shared
        let next = s.artist.isEmpty && !s.title.isEmpty
            ? EnrichCacheReader.inferredIdentity(artist: s.artist, title: s.title, album: s.album) : nil
        if inferredIdentity != next { inferredIdentity = next }
    }

    /// 界面上的封面会不会换成高清替代:系统那份太小、不是封面的形状,或播放器从不报封面。换歌通知按它决定
    /// 要不要等高清替代到货。
    var seeksHighResCover: Bool {
        Self.highResReplacementReason(systemSize: CoverArtReplacementGate.pixelSize(of: artworkData),
                                      bundleID: LocalPlaybackSource.shared.lastResolvedBundleID,
                                      playerHasOwnCover: Self.currentPlayerOwnCover() != nil) != nil
    }

    private var highResCoverTask: Task<Void, Never>?
    /// Spotify 原生客户端「同一张图的原图档」那条替代路(见 refreshSpotifyOriginalCover)。
    private var spotifyCoverTask: Task<Void, Never>?
    /// 上一次成功换上去的那个图床地址 —— 同一地址不重复下载、不闪:refreshHighResCover 因 artworkData
    /// 重发而清空高清图之后,那条路会按同一地址从内存缓存原样放回去。换歌(地址变 nil)时清。
    private var spotifyCoverAppliedURL: URL?
    /// `refreshHighResCover` 铺上去的那张高清替代:地址和图。撤掉高清图时一起清。
    private var highResCoverApplied: (url: URL, image: NSImage)?

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
        // Spotify 原图档那条路挂上的图不归这里撤:它的身份由播放时刻保证(图床地址是这首的),系统封面
        // 后到、被清掉或换了一份都不影响它。撤了再等那条路 350ms 后放回,中间背景会整块消失一下。
        // 换歌时 spotifyArtworkURL 先被置空,这道闸自然不成立,上一首的原图照常撤掉。
        if let applied = spotifyCoverAppliedURL, applied == s.spotifyArtworkURL, highResArtworkImage != nil {
            return
        }
        let (title, artist, album) = (s.title, s.artist, s.album)
        // @Published 是 willSet 语义,给已是 nil 的属性再赋 nil 照样广播——四条清空路径
        // 每次换歌至少走一条,不加闸就是每换歌 1-2 轮白广播,还会穿透下游按 === 去重的
        // 订阅。撤掉旧图的语义不变,只是已经空了就别再赋。
        func clearHighRes() {
            if highResArtworkImage != nil { highResArtworkImage = nil }
            if highResArtworkThumbnail != nil { highResArtworkThumbnail = nil }
            if highResAverageHex != nil { highResAverageHex = nil }
            highResCoverApplied = nil
        }
        guard !title.isEmpty else {
            clearHighRes()
            return
        }
        let systemSize = CoverArtReplacementGate.pixelSize(of: s.artworkData)
        let systemPixels = systemSize.width
        // 系统那份够大且是方形(或者压根没有封面 —— 那时该显示占位音符,不该悄悄换成缓存里
        // 匹配到的另一张图;从不往系统里报封面的、放本地文件的播放器和洛雪除外,见 CoverArtReplacementGate.missingArtworkUsesMatchedCover)就不动。
        // 「不是封面的形状」(YouTube Music MV 的 16:9 视频缩略图)跟「太小」一样要找替代,两条
        // 的后续接受判据不同,见 CoverArtReplacementGate.accepts。
        let playerOwn = Self.currentPlayerOwnCover()
        guard let reason = Self.highResReplacementReason(systemSize: systemSize, bundleID: s.lastResolvedBundleID,
                                                         playerHasOwnCover: playerOwn != nil) else {
            clearHighRes()
            return
        }
        // 用 albumMatchedCoverURL,不是 coverURL:后者会退到"忽略专辑"的兜底,同一首歌换了个专辑版本
        // (比如 Gold / Explicit 版对原版,缓存里还留着原版的旧记录)时可能凑出一张**别的版本**的封面。
        // 系统这份的专辑名来自 Now Playing、就是当前真正在播的这一版,没有必要也不应该退这一步——
        // 选错版本的封面会被 start() 里 enrichContentVersion 补查路的 onlyIfMissing 焊死到
        // 换歌之前,详见 albumMatchedCoverURL 的注释。
        // 按顺序试,头一张够格的就用;系统那份还没有时只认播放器自带的那张,见 replacementCandidates。
        let candidates = CoverArtReplacementGate.replacementCandidates(
            cached: EnrichCacheReader.albumMatchedCoverURL(artist: artist, title: title, album: album),
            playerOwn: playerOwn, reason: reason
        ).map(EnrichCacheReader.nativeSizedCoverURL)
        guard !candidates.isEmpty else {
            // 引擎还没解析完(第一次听的歌):缓存写入后会再触发一次补查(见 start() 里
            // enrichContentVersion 那条订阅),这里不是终点。
            logger.debug("highres: no cached cover yet for \(title, privacy: .public) (system=\(systemSize.width, privacy: .public)x\(systemSize.height, privacy: .public)px, reason=\(String(describing: reason), privacy: .public))")
            clearHighRes()
            return
        }
        // 铺着的就是其中一张(同一首的系统封面换了、留着的旧封面到期清掉):不撤了重铺,撤掉再挂回来,0.5s 交叉淡入会让封面闪一下。
        if let applied = highResCoverApplied, candidates.contains(applied.url), let shown = highResArtworkImage,
           shown === applied.image { return }
        // 上一首的高清图必须立刻撤掉:留着的话换歌后到新图下载完之间会显示上一首的封面,
        // 比"先小图后变清晰"糟得多。均值色跟图同进退。
        clearHighRes()
        highResCoverTask = Task { [weak self] in
            for url in candidates {
                // 走 App 已有的那套内存缓存(同 URL 并发只发一次请求、命中不闪占位符)。
                // 原图档:这张要给歌词窗口 920pt@2x 的封面卡当高清替代,不能吃缩略降采样。
                let loaded = await ImageMemoryCache.shared.load(url, variant: .original)
                guard !Task.isCancelled else { return }
                guard let image = loaded else { continue }
                // 下载期间可能已经换歌了 —— 这张是上一首的,丢掉。
                guard LocalPlaybackSource.shared.title == title else { return }
                // 太小那条:拿回来的还不如系统那份大就不值得换(缓存里可能存着一张同样小的图);
                // 形状那条:替代图自己得是张方形封面,不再拿"比系统那份宽"当门槛 —— 换的是形状
                // 不是分辨率,否则 1280×720 的视频帧会把 600×600 的真封面挡在外面。
                // 尺寸按像素比(NSImage.pixelWidth / pixelHeight),不能用 size 的点数 —— 带 DPI 标签的图两者相差几倍,
                // 出处见 CachedImage.swift 里那个 extension 的注释。
                guard CoverArtReplacementGate.accepts(candidateWidth: image.pixelWidth,
                                                      candidateHeight: image.pixelHeight,
                                                      systemWidth: systemPixels, reason: reason) else { continue }
                // 均值色跟图一起给(理由见 highResAverageHex 的注释)。CIAreaAverage 放到
                // 后台算,跟 LocalPlaybackSource 取图那条路的做法一致,不挡主线程。
                var hex: String?
                var thumbnail: NSImage?
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    // 均值色和面板小图同一趟后台算:两个都只依赖这张 CGImage,分两趟就是把同一张
                    // 大图的解码结果多搬一遍。
                    (hex, thumbnail) = await Task.detached {
                        (LocalPlaybackSource.computeAverageHex(cgImage: cg),
                         Self.downscaledThumbnail(cg, maxPixel: 256))
                    }.value
                }
                guard !Task.isCancelled, LocalPlaybackSource.shared.title == title else { return }
                logger.debug("highres: swapped in \(image.pixelWidth, privacy: .public)px for \(title, privacy: .public) (system=\(systemSize.width, privacy: .public)x\(systemSize.height, privacy: .public)px, reason=\(String(describing: reason), privacy: .public))")
                self?.highResArtworkImage = image
                self?.highResArtworkThumbnail = thumbnail
                self?.highResAverageHex = hex
                self?.highResCoverApplied = (url, image)
                return
            }
        }
    }

    /// 动态封面:查这张专辑有没有,有就把本地文件备好,跟此刻显示的封面是同一张图才叠上去。
    ///
    /// 纪律逐条照 `refreshHighResCover`,理由也一样:
    ///   * **重新从数据源读快照**,不用订阅回调的参数(那几个值来自 willSet 时机,彼此可能不是
    ///     同一首歌的);
    ///   * **换歌立刻撤掉上一首那份** —— 留着的话新歌开头会顶着上一首的动画,比"先静态后动"糟；
    ///   * 已是 nil 就不再赋 nil(@Published 是 willSet 语义,白广播会穿透下游去重);
    ///   * 比完、下载完再校验一次 `title` 没变。
    ///
    /// 跟那条**不同**的两点:
    ///   * 用 `albumMatchedMotionCover`(精确 key → 仍然认专辑的 looseMatch),同样不退到"忽略专辑"
    ///     那一级 —— 在这里退一步拿到的是**另一张专辑的动画**,比一张静态错图扎眼得多；
    ///   * 同一张专辑的下一首:盘上那份已经在播就先留着,比完对不上再撤,不闪回静态图。
    /// - Parameter enabled: 开关刚拨动时由订阅传进来的新值(那一刻 AppSettings 里还是旧值);其余调用读设置。
    private func refreshMotionCover(onlyIfMissing: Bool = false, enabled: Bool? = nil) {
        if onlyIfMissing, motionCoverFile != nil { return }
        motionCoverTask?.cancel()
        motionCoverTask = nil
        let s = LocalPlaybackSource.shared
        let (title, artist, album) = (s.title, s.artist, s.album)
        func clear() {
            if motionCoverFile != nil { motionCoverFile = nil }
        }
        guard !title.isEmpty else {
            clear()
            return
        }
        // 总闸收在这里算一次:用户的开关、以及低电量模式。两者都**不是视图环境值**,而两个消费面
        // (歌词窗口封面卡、灵动岛)要问的是同一个问题 —— 各自 body 里判一遍必然漂。视图侧只剩
        // 两件它自己才知道的事:`reduceMotion`(环境值)和"我这一面此刻可不可见"。
        //
        // 低电量模式下不动:macOS 的低电量本来就降刷新、限后台活动,一个装饰性的 24fps 循环正是
        // 该第一个让位的东西。它变化时有 NSProcessInfoPowerStateDidChange,下面订阅了。
        guard enabled ?? AppSettings.shared.motionCoverEnabled,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            clear()
            return
        }
        guard let found = EnrichCacheReader.albumMatchedMotionCover(artist: artist, title: title, album: album) else {
            clear()
            return
        }
        // 动画只叠在跟它是同一张图的封面上:拿视频中段那一帧跟此刻显示的封面(highResArtworkImage 优先,没有才退系统那份,
        // 跟六处图像消费面同一口径)比,盘上已有的那份也比,比过的按参照图记着不重复解帧(MotionCoverStore.prepare)。封面还没到
        // 就先不叠:封面到了(artworkData、highResArtworkImage 变了)会再走一遍。见 03 章决策 53。
        //
        // 引擎靠专辑身份核验放行的(identityVerified),核的是引擎这条的封面就是 Apple 那张专辑的官方封面;动画首帧本来就跟封面
        // 长得不一样(满幅原图 vs 带标题的方版、上色版 vs 压银浮雕版),再拿中段帧比会把确认过的身份否掉。这一种只确认此刻显示的
        // 就是引擎那张封面(同一张图),是就不比中段帧,不是照常比。
        //
        // 主线程只取一次 CGImage,指纹放到后台算:整图、去边各 64 次 CIAreaAverage,在主线程上换歌那一下要占
        // 一百多毫秒(03 章决策 34)。
        guard let shown = (highResArtworkImage ?? artworkImage)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            clear()
            return
        }
        let cached = MotionCoverStore.shared.cachedFile(master: found.master)
        if cached == nil || motionCoverFile != cached { clear() }
        let engineCover = found.identityVerified ? found.cover.map(EnrichCacheReader.nativeSizedCoverURL) : nil
        let shownIsEngineCover = engineCover != nil && highResArtworkImage != nil && highResCoverApplied?.url == engineCover
        motionCoverTask = Task { [weak self] in
            let reference = await Task.detached(priority: .utility) { CoverFingerprint.reference(of: shown) }.value
            var compareFrame = !shownIsEngineCover
            if compareFrame, let engineCover,
               let cover = await ImageMemoryCache.shared.load(engineCover)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let same = await Task.detached(priority: .utility) { CoverFingerprint.matches(cover, reference: reference).same }.value
                compareFrame = !same
            }
            guard !Task.isCancelled else { return }
            let file = await MotionCoverStore.shared.prepare(master: found.master, reference: compareFrame ? reference : nil)
            // 比的、下载的这段时间换歌了 —— 这份是上一首的。
            guard !Task.isCancelled, LocalPlaybackSource.shared.title == title else { return }
            if let file {
                if self?.motionCoverFile != file { self?.motionCoverFile = file }
            } else if self?.motionCoverFile != nil {
                self?.motionCoverFile = nil
            }
        }
    }

    /// Spotify 原生客户端:把高清替代换成**同一张图的原图档**。
    ///
    /// 跟 refreshHighResCover 那条路的分工:那条只在系统那份太小 / 不是方形时才去缓存里按文字匹配找替代;
    /// 而 Spotify 交给系统的封面实测是 600×600(与 Spotify 图床 640 档同一张图,8×8 均值哈希距离 0),又方
    /// 又不小,永远不进那条路 —— 可歌词窗口那张卡要画到 920px。这里拿的是 AppleScript `artwork url`
    /// (SpotifyPositionProbe 开播 2.5s 后那次脚本顺带带回),身份由播放时刻保证、不靠匹配,所以不需要
    /// CoverArtReplacementGate 那套判据,只要"拿回来的比系统那份宽"就换。下载顺序 原图(82c1,实测
    /// 800 / 1425 / 2000)→ 640,见 SpotifyArtworkURL.downloadCandidates。
    ///
    /// 时序:换歌时 LocalPlaybackSource 把 spotifyArtworkURL 置 nil,这里只清自己的记录、不动图(旧图由
    /// refreshHighResCover 的 clearHighRes 撤);探针带回地址 → 下载 → 换上,期间显示系统那份 600。
    ///
    /// 系统那份没有时(换歌那几秒系统还挂着上一首、被 fetchArtworkForCurrentTrack 丢掉),这张就是唯一的封面:
    /// 先下 640 档立刻挂上,再升级原图档;系统那份在时仍先下原图。下载走 DirectFirstImageLoad(先直连、
    /// 连不上再走系统代理):经系统代理时这两档实测要几十秒到超时,直连一两秒。每一档都等到下载结束,
    /// 下完还是这首才换 —— 别加「等 N 秒就放弃」:放弃之后图照样下完,却没人再把它挂上。
    /// 同一地址已经换上就不再动(spotifyCoverAppliedURL),避免 artworkData 重发时清空→重设闪一下;
    /// 反过来被清空了(highResArtworkImage == nil)就按同一地址从内存缓存放回。
    private func refreshSpotifyOriginalCover(_ url: URL?) {
        spotifyCoverTask?.cancel()
        spotifyCoverTask = nil
        guard let url else {
            spotifyCoverAppliedURL = nil
            return
        }
        if spotifyCoverAppliedURL == url, highResArtworkImage != nil { return }
        let s = LocalPlaybackSource.shared
        let title = s.title
        guard !title.isEmpty, s.spotifyArtworkURL == url else { return }
        // 系统那份的像素宽(NSImage.pixelWidth 读图头,不触发整图解码)。没有系统封面时按 0 算 —— 任何原图都比它大。
        let systemWidth = artworkImage?.pixelWidth ?? 0
        let candidates = SpotifyArtworkURL.downloadCandidates(for: url)
        let ordered = systemWidth == 0 ? Array(candidates.reversed()) : candidates
        spotifyCoverTask = Task { [weak self] in
            var shownWidth = systemWidth
            var loadedAny = false
            for candidate in ordered {
                if Task.isCancelled { return }
                // 原图档:这张要给歌词窗口 920pt@2x 的封面卡,不能吃缩略降采样(同 refreshHighResCover)。
                guard let image = await DirectFirstImageLoad.loadOriginal(candidate) else {
                    continue
                }
                loadedAny = true
                // 下载期间可能已经换歌了 —— 这张是上一首的,丢掉。
                guard !Task.isCancelled, LocalPlaybackSource.shared.title == title,
                      LocalPlaybackSource.shared.spotifyArtworkURL == url else { return }
                // 比大小用像素(NSImage.pixelWidth),不能用 NSImage.size:那是"点",会跟着 JPEG 里的 DPI 元数据走 ——
                // Spotify 图床的原图带 797 dpi,2000×2000 的图 size.width 只有 181(装机实测;用点数就会在
                // 这里把原图当成小图丢掉的)。理由与出处见 NSImage.pixelWidth 的注释(CachedImage.swift)。
                let width = image.pixelWidth
                guard width > shownWidth else { continue }
                var hex: String?
                var thumbnail: NSImage?
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    (hex, thumbnail) = await Task.detached {
                        (LocalPlaybackSource.computeAverageHex(cgImage: cg),
                         Self.downscaledThumbnail(cg, maxPixel: 256))
                    }.value
                }
                guard !Task.isCancelled, LocalPlaybackSource.shared.title == title else { return }
                logger.notice("spotify original cover: swapped in \(width, privacy: .public)px for \(title, privacy: .public) (system=\(systemWidth, privacy: .public)px)")
                self?.highResArtworkImage = image
                self?.highResArtworkThumbnail = thumbnail
                self?.highResAverageHex = hex
                self?.spotifyCoverAppliedURL = url
                shownWidth = width
            }
            if !loadedAny {
                logger.notice("spotify original cover: no candidate loaded for \(title, privacy: .public)")
            } else if shownWidth == systemWidth {
                logger.notice("spotify original cover: nothing larger than system \(systemWidth, privacy: .public)px, keeping system cover")
            }
        }
    }

    /// 把一张(已解码的)CGImage 等比缩到最长边 ≤ maxPixel,给 highResArtworkThumbnail 用。
    /// 纯 CoreGraphics,可以在后台线程跑;本来就不比 maxPixel 大的图原样包成 NSImage 返回。
    nonisolated private static func downscaledThumbnail(_ cg: CGImage, maxPixel: Int) -> NSImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let longest = max(w, h)
        guard longest > maxPixel else {
            return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        }
        let scale = CGFloat(maxPixel) / CGFloat(longest)
        let tw = max(1, Int((CGFloat(w) * scale).rounded()))
        let th = max(1, Int((CGFloat(h) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: tw, height: th))
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
    /// 不直接调 MusicPlaybackController.playPause():指令送出后**乐观翻转**观感层 isPlayingSmoothed
    /// (`MusicPlaybackController.shownPlayingAfterPlayPause`)。菜单通路在 AXPress 送出后才回报,没按下去不翻。
    /// 真实链路(命令→播放器切状态→分布式通知→250ms 去抖→poll 子进程→apply)要 0.5~1s,等它回读再动画,
    /// 对比 AM 的即时反馈明显迟钝。
    ///
    /// 只翻观感层、不碰 isPlayingNow 真值:进度时钟/歌词填色仍由 poll 链路驱动,状态机
    /// 不引入第二条写路径。万一命令没落地(播放器没开/权限没给),真值不会来"纠正"它
    /// (updateSmoothedPlaying 只在 isPlayingNow **变化**时被调),所以 2.5s 后对账一次、
    /// 拨回真值 —— 有 grace 定时在跑说明真值正在按老路径收敛,那种情况不抢。
    func userTogglePlayPause() {
        let targetBundleID = LocalPlaybackSource.shared.lastResolvedBundleID
        let truthAtTap = isPlayingNow
        MusicPlaybackController.playPause { [weak self] route in
            guard let route, let self, LocalPlaybackSource.shared.lastResolvedBundleID == targetBundleID else { return }
            stopGraceWork?.cancel()
            stopGraceWork = nil
            isPlayingSmoothed = MusicPlaybackController.shownPlayingAfterPlayPause(
                route: route, shown: isPlayingSmoothed, truthAtTap: truthAtTap, truthNow: isPlayingNow)
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
