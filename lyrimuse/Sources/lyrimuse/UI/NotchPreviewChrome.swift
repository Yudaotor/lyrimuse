import AppKit
import Combine
import LyrimuseCore
import SwiftUI

// MARK: - 预览用 chrome

/// 灵动岛编辑台用的 chrome:凑齐 NotchLyricsView 要的那几个属性,但不建窗口、不碰屏幕。
///
/// 这个类存在的唯一理由,就是让预览**不去碰 NotchLyricsWindowController.shared**。
/// 见那个文件顶部那条不变量:`.shared` 是 `static let`,哪怕只是拿来读一下属性都会执行
/// init() 建出整扇窗(NSPanel + NSHostingView + 一串 Combine 订阅和通知观察者),灵动岛
/// 关着的用户一打开设置页就凭空多一套。所以刘海几何这里走的是那边不碰实例状态的 static
/// 函数(`targetScreen()` / `geometry(for:)` / `contentWidth(baseWidth:notchWidth:)`)。
///
/// 用独立实例还有第二个好处:鼠标划过编辑台时展开的是**这一份**,不会顺手把真窗口也撑开。
@MainActor
final class NotchPreviewChrome: ObservableObject, NotchChromeSource {
    /// 指针 / 浮层 / 宽度调整条给出的展开态(`setExpandedFromPreview`)。
    @Published private var pointerExpanded = false
    /// 正在调「圆角 / 展开圆角」哪一态(`NotchCornerLive.focusPublisher`:按着那根滑杆,或指针停在那一行上)。
    /// 这时预览摆成那一态 —— 指针在设置行上、卡片没被 hover,不摆过去就看不见在调的那个圆角;移开交还给 `pointerExpanded`。
    @Published private var cornerFocus: NotchCornerSlot?
    var isExpanded: Bool { cornerFocus.map { $0 == .expanded } ?? pointerExpanded }
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var contentTopInset: CGFloat = 0
    /// 卡片两种形态的真实宽,由舞台按真窗口同一套公式算好推进来(`NotchEditorStage.card` 的 onAppear /
    /// onChange),歌词行按它们定宽居中交叉淡入淡出(NotchChromeSource 里的说明)。初值只是占位。
    @Published private(set) var steadyCardWidth: CGFloat = AppSettings.defaultNotchContentWidth
    @Published private(set) var expandedCardWidth: CGFloat = AppSettings.defaultNotchContentWidth

    func setCardWidths(steady: CGFloat, expanded: CGFloat) {
        if steadyCardWidth != steady { steadyCardWidth = steady }
        if expandedCardWidth != expanded { expandedCardWidth = expanded }
    }

    /// 预览恒为 false。isCollapsed 是真窗口"没在播放就缩回刘海大小、内容整套不渲染"的
    /// 行为 —— 照搬到设置页就是一片空白,而用户恰恰是来这里看样式的。
    var isCollapsed: Bool { false }

    /// 预览恒按**最完整**形态画(有歌词预览、有进度条)—— 用户来这里是看样式的,给他一个
    /// 因为"此刻这首歌没歌词"而缩掉一截的样张没有意义。跟 isCollapsed 恒 false 同一个理由。
    var expandedShowsLyricPreview: Bool { true }
    var expandedShowsScrubber: Bool { true }
    /// 有没有曲目:跟真窗口同一个判据、同一组输入(`NotchLyricsWindowController.trackPresent`)。没放歌时预览跟
    /// 真窗口一样画空闲那一套(左耳 App 图标、整卡纯黑、展开是空闲面板);别写死成 true,那样预览会画出一张
    /// 真窗口从来不会出现的「有曲目但全空」的卡片(空歌词行、播放键)。
    @Published private(set) var hasTrack = false
    /// 此刻在放的是不是广告:跟真窗口同源(`PlaybackCoordinator.isCurrentTrackAdBreak`),预览跟真窗口一样进广告态。
    /// 广告态的门槛轮询不归预览登记,见 `NotchLyricsView.drivesAdSkipGate`。
    @Published private(set) var isAdBreakNow = false
    /// 预览不报收听里程碑:那是一次性的真事件,预览里凭空撑开只会让人以为设置把它弄坏了。
    var milestone: ListenMilestone? { nil }
    var trackDrop: NotchTrackDrop? { nil }
    var transientBannerActive: Bool { false }
    var showsProgressLine: Bool { AppSettings.shared.notchShowsProgressLine }
    var progressLineStyle: NotchProgressLineStyle { AppSettings.shared.notchProgressLineStyle }
    /// 预览不掉歌名,耳朵里的封面也不等揭晓。
    func revealsTrack(_ key: String) -> Bool { true }

    /// 「显示歌词」现读设置 —— 这一项**必须**反映真实配置(它决定卡片还剩不剩歌词行,
    /// 正是用户在这块画布上要看的东西),不能像上面几项那样为了"看样式"钉成常量。
    /// 不用 @Published 镜像:编辑台自己观察 AppSettings,设置一变整块重画,读到的必然是新值。
    var showsLyrics: Bool { AppSettings.shared.notchShowLyrics }
    var showsLyricsSetting: Bool { AppSettings.shared.notchShowLyrics }
    /// 歌词行实际高度,同上现读:拖「行高」滑杆时预览卡片跟着变矮(舞台本身按上限留高度,不跟着动,见 `cardAreaHeight`)。
    var lyricRowHeight: CGFloat { AppSettings.shared.notchEffectiveLyricRowHeight }
    /// 音浪开关/贴哪只耳朵,同上现读设置——预览要如实反映用户正在配的效果。
    ///
    /// 这两项比「显示歌词」更不能钉成常量:它们**同时**决定顶行怎么排
    /// (`NotchLyricsView.topRow`)和卡片宽度下限(`NotchLyricsWindowController.minEarWidth`
    /// 要按"哪只耳朵挂音浪"留出 `EqualizerBars.width + earWaveSpacing`)。钉死的话编辑台那根
    /// 宽度调整条的下界会跟真窗口对不上 —— 而"设定值和真实宽度之间不许有歧义"正是这块画布
    /// 改造的出发点(见 widthValueText / `NotchLyricsWindowController.usableWidthRange`)。
    var showsEqualizer: Bool { AppSettings.shared.notchShowsEqualizer }
    var equalizerEar: NotchEqualizerEar { AppSettings.shared.notchEqualizerEar }
    /// 展开态那一组同上,一律现读设置——它们决定的正是"展开态"浮层里那几个
    /// 开关此刻要不要生效,预览必须如实反映。不含歌词行末尾那枚封面的开关/位置——那两项
    /// 走 `NotchPlayback` 而不是这个协议;但**含**头部自己的封面开关
    /// (`expandedTrackInfoShowsArtwork`),理由见 `NotchChromeSource.expandedTrackInfoShowsArtwork`
    /// 的注释——它跟另外三项一样参与高度计算,预览这边不能漏。
    // 「下一句歌词预览」画不画 = 用户开关 && 没被歌词行「副行 · 下一句」顶掉,判据只有
    // Core 那一份,跟真窗口 NotchLyricsWindowController 的订阅同源。
    var expandedShowsNextLine: Bool {
        LyricSecondaryLine.expandedNextLinePreviewVisible(
            userToggle: AppSettings.shared.notchExpandedShowsNextLine, secondary: AppSettings.shared.notchSecondaryLine)
    }
    var expandedShowsControls: Bool { AppSettings.shared.notchExpandedShowsControls }
    var expandedTrackInfoShowsArtwork: Bool { AppSettings.shared.notchExpandedShowsArtwork }
    var expandedTrackInfoShowsTitle: Bool { AppSettings.shared.notchExpandedShowsTrackTitle }
    var expandedTrackInfoShowsArtist: Bool { AppSettings.shared.notchExpandedShowsArtist }
    var expandedTrackInfoShowsAlbum: Bool { AppSettings.shared.notchExpandedShowsAlbum }
    var expandedShowsQuickActions: Bool { AppSettings.shared.notchExpandedShowsQuickActions }
    var expandedLyricListHeight: CGFloat { AppSettings.shared.notchExpandedLyricListHeight }

    init() {
        refreshGeometry()
        // 屏幕设置从哪条路改的都要跟上(「屏幕」浮层、「恢复默认」、设置页别处的重置),跟随当前窗口时跟到的屏换了
        // 也一样。@Published 在 willSet 发布、那时 targetScreen() 读到的还是旧值,所以挪到下一拍再算。
        screenSubscription = Publishers.Merge3(
            AppSettings.shared.$notchScreenID.removeDuplicates().map { _ in () },
            AppSettings.shared.$notchFollowsActiveScreen.removeDuplicates().map { _ in () },
            NotchFollowedScreen.shared.$id.removeDuplicates().map { _ in () }
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshGeometry() }
        cornerSubscription = NotchCornerLive.shared.focusPublisher
            .sink { [weak self] slot in self?.cornerFocus = slot }
        // 同真窗口:三个输入一次给全,存 sink 参数值(@Published 在 willSet 发布)。
        let playback = PlaybackCoordinator.shared
        trackSubscription = Publishers.CombineLatest3(playback.$title, playback.$artist, playback.$isCurrentTrackAdBreak)
            .sink { [weak self] title, artist, isAd in
                guard let self else { return }
                let present = NotchLyricsWindowController.trackPresent(title: title, artist: artist, isAdBreak: isAd)
                if self.hasTrack != present { self.hasTrack = present }
                if self.isAdBreakNow != isAd { self.isAdBreakNow = isAd }
            }
    }

    private var screenSubscription: AnyCancellable?
    private var cornerSubscription: AnyCancellable?
    private var trackSubscription: AnyCancellable?

    /// 快捷操作的 ✕ 在预览里**故意**是空实现:预览卡整块 `allowsHitTesting(false)`,点不到;真要能点到
    /// 也不该让"预览"把用户的灵动岛关掉(预览卡上的可点区域只开浮层、不产生副作用,见 05 章)。
    func closeFromQuickAction() {}
    /// 同上:预览卡点不到,也不该从预览里弹一扇真浮框。
    func toggleEditorial(_ kind: EditorialCard.Kind) {}

    /// 编辑台自己算出来的命中结果,这才是预览里真正生效的那条路。
    func setExpandedFromPreview(_ expanded: Bool) {
        guard expanded != pointerExpanded else { return }
        pointerExpanded = expanded
    }

    /// 跟真窗口 recomputeGeometry 取的是同一块屏、同一个公式,编辑台里的让位宽度/高度才
    /// 会跟真出来的严丝合缝。
    ///
    /// 可重入,有**两个**触发源:
    ///   - 插拔显示器(didChangeScreenParametersNotification);
    ///   - 用户在「屏幕」浮层里改了「显示于」。只订通知的话,从"内建屏"换到一块没有刘海的外接屏之后,预览里的刘海空当和让位高度
    ///     还是旧屏的;编辑台把刘海本身也画出来了(见 notchCutout),陈旧值会直接表现成"画了一个那块屏根本没有的刘海"。
    /// 两个赋值**刻意不判等**。这个方法只在屏幕插拔和「屏幕」浮层提交时跑(低频到可以
    /// 忽略),判等省下的那次 objectWillChange 没有任何收益,却会掐掉编辑台唯一的一条刷新
    /// 通道:工具栏「屏幕」按钮上的摘要(`NotchScreenSummary.current`)是从 `NSScreen.screens`
    /// 现算的**纯派生值**,那个全局没有任何 publisher,只能靠这次发布带着 body 重估一遍。
    /// 判等版本会在"刘海几何恰好没变"的插拔里让摘要停在旧值 —— 典型场景:一台没有内建刘海
    /// 的机器接两块菜单栏等高的外接屏,钉住的那块拔掉/插回,notchWidth 恒 0、notchHeight 相等,
    /// 于是按钮上仍写着已经拔掉的那台显示器的名字(反过来插回来则卡在「已断开的屏幕」)。
    func refreshGeometry() {
        guard let screen = NotchLyricsWindowController.targetScreen() else { return }
        let geo = NotchLyricsWindowController.geometry(for: screen)
        notchWidth = geo.notchWidth
        contentTopInset = geo.notchHeight
    }
}
