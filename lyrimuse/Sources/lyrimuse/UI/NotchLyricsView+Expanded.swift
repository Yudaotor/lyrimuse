import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

// 灵动岛卡片主视图(`NotchLyricsView`,主体在 NotchLyricsView.swift)的展开区:曲目信息头部与快捷操作、进度条与播放控制、没有曲目时的空闲面板。
extension NotchLyricsView {
    // hover 展开时多出来的这一块——下一句歌词预览 + 迷你进度条,用来强化"这是个歌词类
    // 产品"而不是退化成通用媒体控制器;进度条属于"有余量就加"的加分项。
    //
    // 曲目信息头部(歌名/歌手/专辑)**不在这里**——它在 body 里 lyricRow 前面,是一个
    // 独立的 `trackInfoHeader` 块(见 body 那段注释)。这里因此永远传
    // `trackInfoHeight: 0`——那部分高度已经在 `expandedTrackInfoHeaderHeight` 那份独立
    // 的 `.frame(height:)` 里算过一次。
    var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            // `showsExpandedLyricPreview` 这一条跟下面 .frame(height:) 里留不留这行的高度
            // 是**同一个值**(协议扩展里那份),别在这里换成别的判据。没有下一句(最后一句)时照样占这一行、
            // 画一个空格,进度条和控制键不往上挪。见 05 章决策 75。
            if controller.showsExpandedLyricPreview {
                Text(nextLineDisplayText.isEmpty ? " " : nextLineDisplayText)
                    // 跟副行同一个派生字体:它俩是同一类"辅助的下一句",字号不随主行变、粗细细一档。
                    .font(playback.secondaryFont)
                    .lyricTypesetting(nextLineDisplayText)
                    .foregroundStyle(accentOrWhite.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 「对齐方式」也管这一行。不能只改主歌词行:那样选了「居中」之后主行居中、这一行还贴着左边,看起来就是没做完
                    // (同一个视觉属性别漏改一条路径,见 swiftUIAlignment 注释)。
                    //
                    // 用**这一行自己**的 `.frame(maxWidth:.infinity, alignment:)`,而不是
                    // 去改外层 `VStack(alignment:)`:那个 VStack 里还有进度条和播放键,而
                    // 下面那两条 `.padding(.bottom,)`/`.frame(height:)` 的高度算术是跟
                    // `NotchExpandedMetrics` 对账的(注释里记着"两处一个开一个不开必然对不上"),
                    // 动 VStack 的对齐属性等于把这一项的影响面从"一行文字"扩到整块布局。
                    // Text 撑满整行宽之后它自己的 leading 对齐导线就落在容器左边缘,VStack 那
                    // 一侧看到的仍是原来的形状;`.lineLimit(1)` 也保证高度不变。
                    .frame(maxWidth: .infinity,
                           alignment: playback.nextLineAlignment)
            }

            // 进度条独立成 NotchScrubber 子视图(拖动状态自持 + 30Hz 帧率上限),见其注释。
            NotchScrubber(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                isPlayingNow: playback.isPlayingNow,
                seekable: PlaybackCoordinator.shared.acceptsSeek,
                tint: accentOrWhite,
                // 广告期间不画「− 歌词 0.0s +」:广告没有歌词,校准无物可校。
                showsLyricsOffsetControls: playback.showsLyricsOffsetControls && !playback.isCurrentTrackAdBreak,
                trackLyricsOffsetMs: playback.trackLyricsOffsetMs,
                lyricsOffsetStepMs: playback.lyricsOffsetStepMs)

            // 完整三键:岛是 hover 展开的,真正的点击全发生在展开态,控制就该在展开卡里、进度条下方居中,跟菜单栏面板卡片同一套
            // 设计语言(进度条 + 居中三键),目标也大得多(22pt vs 耳朵里 15pt)。
            //
            // `expandedShowsControls` 关掉后这排键不画,理由见 `NotchChromeSource.expandedShowsControls` 的注释(不是唯一入口,
            // `NotchEarModule` 本来就有「播放控制」这个选项)。
            //
            // 随机、循环此刻都能切的播放器在播时左右两端再加随机 / 循环(歌词窗口同款排布),两颗等宽,
            // 三键仍居中。
            if controller.expandedShowsControls {
                HStack(spacing: 0) {
                    if let mode = playback.fullPlaybackMode {
                        shuffleButton(mode)
                        Spacer(minLength: 8)
                    }
                    HStack(spacing: 34) {
                        controlButton("backward.fill", glyphSize: 11.5, hitSize: 22, hintKey: "transport.previous") {
                            MusicPlaybackController.previousTrack()
                        }
                        controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill",
                                      glyphSize: 14, hitSize: 22, hintKey: "transport.playPause") {
                            // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
                            PlaybackCoordinator.shared.userTogglePlayPause()
                        }
                        controlButton("forward.fill", glyphSize: 11.5, hitSize: 22, hintKey: "transport.next") {
                            MusicPlaybackController.nextTrack()
                        }
                    }
                    if let mode = playback.fullPlaybackMode {
                        Spacer(minLength: 8)
                        repeatButton(mode)
                    }
                }
                .frame(maxWidth: .infinity)
                // 播放控制被拦下时那三颗键的说明往上弹,盖在歌词上(同头部快捷操作那排的气泡)。
                .modifier(QuickActionTooltipOverlay(hovered: hoveredQuickAction,
                                                    shown: $shownQuickActionTooltip,
                                                    tint: accentOrWhite, edge: .top))
            }
        }
        .padding(.horizontal, NotchMetrics.expandedContentInset)
        // 10pt 底边距是 `NotchExpandedMetrics.controlsBlock`(35 = 22 键高 + 10 底边距 +
        // 3pt 余量)的一部分,关掉播放控制键之后这一整块(含底边距)在高度算术里都不占
        // 地方了(见 height(...) 的 hasControls 分支),渲染这侧必须跟着不加,否则算出来的
        // 高度比实际渲染矮 10pt,会把上面的内容顶出去一截、被 `.frame(alignment: .top)`
        // 裁掉底部——两处一个开一个不开,必然对不上。 代价:关掉控制键但进度条/下一句
        // 预览还开着时,最后一个元素少了这 10pt 专属边距,只剩它自己那份"间距4"贴底(比如
        // 进度条时间行离底边只剩 4pt,不是 10pt)——比专属边距紧一些,但不会被裁,这是
        // 接受的取舍,不值得为这一种组合另开一条独立的常量。
        .padding(.bottom, controller.expandedShowsControls ? 10 : 0)
        // maxWidth: .infinity 是必须的,不是随手加的保险。
        //
        // 不钉这一下,这一块的宽度就跟着**内容**走。播放时里面有进度条,进度条用
        // GeometryReader 会自己撑满,于是整块占满整行、歌词预览自然贴左;而暂停时进度条
        // 那一段整个不渲染(它挂在 playback.anchor 上,暂停后 anchor 为 nil),VStack 里只
        // 剩一句歌词预览,这一块就缩成那行字那么宽 —— 再被外层 VStack 默认的**居中**
        // 对齐推到正中间。表现就是"暂停时下一句歌词跑到中间、播放时又靠左"。
        // 撑满 + topLeading 之后,两种状态下它都在同一个位置。
        // (分两个 .frame:maxWidth 走的是弹性那个重载,height 走固定尺寸那个,
        // 混在一次调用里编译不过。)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 高度跟 NotchWindowRoot.cardHeight **走同一个函数、同一组入参**(都读 controller
        // 上那两个曲目级标志)—— 两处各自判断的话必然漂,而漂的表现是卡片和内容差一截:
        // 要么底部多一条空隙,要么最下面那排三键被裁掉。
        .frame(height: NotchExpandedMetrics.height(
            hasLyricPreview: controller.showsExpandedLyricPreview,
            hasScrubber: controller.expandedShowsScrubber,
            hasControls: controller.expandedShowsControls,
            trackInfoHeight: 0), alignment: .top)
    }

    /// 曲目信息头部:封面 + 歌名/歌手/专辑,四项独立开关。解决的缺口:两只耳朵都配成非文本模块(比如「剩余时长」)时,hover 展开
    /// 也看不出这是哪首歌。
    ///
    /// 头部有自己的一枚封面(`expandedTrackInfoShowsArtwork`,这个协议里),固定贴文字块左边;歌词行末尾那枚是另一个开关
    /// (`lyricRowContent` 里的 `artworkThumbnail`,受 `notchLyricRowShowsArtwork`/`notchLyricRowArtworkPosition` 控制,走
    /// `NotchPlayback` 镜像,不在这个协议里)。两枚能同时开,不算矛盾。
    @ViewBuilder
    var trackInfoHeader: some View {
        if controller.showsExpandedTrackInfo {
            HStack(spacing: 8) {
                trackInfoArtwork
                trackInfoTextStack
                trackInfoQuickActions
            }
                // 悬浮提示挂在**整行**上、不挂在那排按钮上:气泡要收敛在卡片里,而"卡片内容区有多宽"
                // 只有这一层的 GeometryReader 量得到(按钮排自己只有 100pt 宽)。见 `QuickActionTooltipOverlay`。
                .modifier(QuickActionTooltipOverlay(hovered: hoveredQuickAction,
                                                    shown: $shownQuickActionTooltip,
                                                    tint: accentOrWhite, edge: .bottom))
                // 左右内边距是展开态那一列内容的边界(歌词首字、进度条、控制键同一条),展开态的顶行也收到这里(topRowPadding)。
                .padding(.horizontal, NotchMetrics.expandedContentInset)
                // 顶部间距:头部紧挨在 topRow 下面,没有它标题首行会贴到上面边。这份间距已经在 `expandedTrackInfoHeaderHeight`/
                // `NotchExpandedMetrics.height` 的高度算术里算过(`trackInfoSpacing * 2`,一份在上一份在下),这里只是把"上面那份"
                // 实现成看得见的留白;`.frame(alignment: .top)` 会把这段 padding 之后的内容继续钉在分配到的那块高度顶部。
                .padding(.top, NotchExpandedMetrics.trackInfoTopSpacing)
        }
    }

    /// 头部里的封面缩略图,复用 `artworkThumbnail`(点击打开歌词窗口的行为跟着一起继承)。
    /// 没有封面数据(没曲目/取图失败)时不画占位方块——跟 `lyricRowContent` 末尾那枚同一个
    /// 惯例(`@ViewBuilder` 的 `if let` 不满足时直接产出零视图,HStack 自然收缩)。
    @ViewBuilder
    private var trackInfoArtwork: some View {
        // 电台口白期间换台标,跟耳朵、歌词行那两枚同一个取法(头部标题这时也已经是台名)。
        if controller.trackInfoShowsTrackFields, controller.expandedTrackInfoShowsArtwork,
           let image = displayedArtworkImage {
            artworkThumbnail(image, side: NotchExpandedMetrics.trackInfoArtworkSide)
        }
    }

    /// 头部里的歌名/歌手/专辑三行,复用 `metadataText`——跟耳朵里那三个文本模块走同一份
    /// 广告插播/空曲目规则(广告中歌名写「广告中」、歌手专辑留空),不重新定义一套。
    ///
    /// `.frame(maxWidth: .infinity, alignment: .leading)` 是必须的:没有它,`.lineLimit(1)`
    /// 的 `Text` 在 VStack 里只会按内容天然宽度收缩,压根不会触发截断——这一块需要一个
    /// 明确的宽度提议才截得断长歌名/长专辑名。
    /// 广告期间三行都不画(`trackInfoShowsTrackFields`),留下的空 VStack 仍按 `maxWidth: .infinity` 吃掉
    /// 剩余宽度,把快捷操作那排键推到右端 —— 跟四项全关、只开快捷操作时同一个形态。
    /// 头部的专辑名。当前这首有专辑简介时可点(开 / 关浮框),没有就只是文字 —— 判据与悬停态在
    /// `NotchEditorialLine` 里,它自己订阅 `EditorialNotesStore`,简介到货只重画这一行。
    private var trackInfoAlbumLine: some View {
        NotchEditorialLine(kind: .album, text: metadataText(.album), tint: accentOrWhite,
                           font: .system(size: 9), restingOpacity: 0.4, hoverOpacity: 0.75,
                           tappable: !playback.album.isEmpty || !playback.youtubeMusicAlbum.isEmpty) { controller.toggleEditorial(.album) }
    }

    private var trackInfoTextStack: some View {
        let fields = controller.trackInfoShowsTrackFields
        return VStack(alignment: .leading, spacing: NotchExpandedMetrics.trackInfoLineSpacing) {
            // 歌名能点开歌曲简介;电台口白期间这一行是台名,不接。
            if fields && controller.expandedTrackInfoShowsTitle {
                NotchEditorialLine(kind: .song, text: metadataText(.title), tint: accentOrWhite,
                                   font: .system(size: 12, weight: .semibold), restingOpacity: 0.9, hoverOpacity: 1,
                                   tappable: !playback.title.isEmpty && radioTalkStation == nil) { controller.toggleEditorial(.song) }
            }
            if fields && controller.expandedTrackInfoShowsArtist {
                NotchEditorialLine(kind: .artist, text: metadataText(.artist), tint: accentOrWhite,
                                   font: .system(size: 10, weight: .medium), restingOpacity: 0.6, hoverOpacity: 0.9,
                                   tappable: !playback.artist.isEmpty) { controller.toggleEditorial(.artist) }
            }
            if fields && controller.expandedTrackInfoShowsAlbum {
                trackInfoAlbumLine
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 头部右侧那排「快捷操作」:喜欢、搜索歌词、显示 / 隐藏歌词、Last.fm、设置、关闭灵动岛。
    ///
    /// 排法照悬浮歌词那排控制胶囊(`LyricsOverlayView.playbackControls`):**对这首歌的操作 │ 窗口级
    /// 操作**,中间一条细竖线分组,✕ 放最右最边上 —— 喜欢 · 搜索歌词 · 显示歌词 │ Last.fm · 设置 · 关闭
    /// (喜欢只在播放器有「喜欢」时出现,Last.fm 只在连着账号时出现)。每颗都是
    /// 22pt 命中格(跟下面播放控制三键同一档,`NotchExpandedMetrics.trackInfoActionsHeight`),
    /// 字形 11pt,颜色跟卡上其它图标一样走 `accentOrWhite`、压到七成五 —— 这排是"手边的入口",
    /// 不该比歌名重。
    ///
    /// 各颗键的语义:
    ///   * 喜欢 → `PlaybackCoordinator.toggleFavorited()`,跟悬浮歌词那颗心、歌词窗口那颗星同一条路。`isFavorited` 为 nil
    ///     (这个播放器没有「喜欢」或没拿到权限)和广告期间不画。排在最左:这排键贴右对齐,它出现 / 消失时别的键不挪。
    ///     已喜欢画实心、全亮、带淡底,同随机 / 循环键点亮。展开时回读一次状态(`NotchLyricsWindowController.refreshExpanded`)。
    ///     见 05 章决策 79。
    ///   * 搜索歌词 → `AppActions.openLyricsQuickSearch`,跟悬浮歌词 ⚙ 菜单的「搜索歌词…」同一扇小窗。
    ///     头部本来就要求 `hasTrack`,所以不用像那边一样再按"有没有歌"决定显隐。广告期间四颗照常画、照常可点
    ///     (头部此时只剩这一排,见 `trackInfoShowsTrackFields`)。
    ///   * 显示歌词 → 切 `AppSettings.notchShowLyrics`(稳态那 44pt 歌词行的开关)。**展开态里看不出
    ///     变化**(展开永远画歌词行,见 `showsLyricRow`),关着时字形压淡到四成、tooltip 换成「显示歌词」,
    ///     让"现在是关的"当场可辨;收回稳态才看得出效果。状态读 `controller.showsLyrics`(控制器的镜像),
    ///     不另订阅 AppSettings。
    ///   * Last.fm 到 设置 › Last.fm 详情页(`openLastfmSettingsPage`)。是去 App 里某个页面、不是对这首歌做什么,
    ///     所以在竖线右边。只在 `LastfmStatsService.isConnected` 时画:没连的人点了只会落到一张连接卡上。
    ///   * 设置 → 直接翻到 设置 › 歌词显示 › 灵动岛,照抄 `OverlayQuickSettingsMenu.openMoreSettings` 那三行。
    ///   * 关闭 → 关掉「灵动岛歌词」**总开关**(`closeFromQuickAction` → `setVisible(false)`),跟悬浮歌词
    ///     那颗 ✕ 同一个意思;再打开走菜单栏面板 / 设置 / 快捷键。不做"只收起这一次":hover 展开
    ///     本来移开指针就收,那颗键等于没用。
    ///
    /// 不套 `controlButton` 那层"先查 Apple Music 自动化权限"的守卫:这几个动作跟播放控制毫不相干,
    /// 借那层守卫会引入一个跟按钮语义不匹配的隐藏依赖(跟悬浮歌词的锁定键同一条理由)。
    @ViewBuilder
    private var trackInfoQuickActions: some View {
        if controller.expandedShowsQuickActions {
            HStack(spacing: 2) {
                if let favorited = playback.isFavorited, !controller.isAdBreakNow {
                    quickActionButton(favorited ? "heart.fill" : "heart", key: "favorite",
                                      label: favorited ? L10n.t("取消喜欢") : L10n.t("喜欢"), lit: favorited) {
                        PlaybackCoordinator.shared.toggleFavorited()
                    }
                }
                quickActionButton("magnifyingglass", label: L10n.t("搜索歌词…")) {
                    AppActions.shared.openLyricsQuickSearch?()
                }
                quickActionButton("text.alignleft",
                                  label: controller.showsLyricsSetting ? L10n.t("隐藏歌词") : L10n.t("显示歌词"),
                                  dimmed: !controller.showsLyricsSetting) {
                    AppSettings.shared.notchShowLyrics.toggle()
                }
                // 分组线:前两颗是"对这首歌 / 这行歌词"的操作,后两颗是"这块卡片"的操作。
                Rectangle()
                    .fill(accentOrWhite.opacity(0.18))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 3)
                // 只在连着 Last.fm 时出现:没连的人这颗键无处可去,这排仍是四颗。
                // `isConnected` 不是 @Published,随下一次 body 重算取值(同歌词窗口的统计元素)。
                if LastfmStatsService.shared.isConnected {
                    quickActionButton("chart.bar.fill", label: L10n.t("在设置中查看 Last.fm")) {
                        openLastfmSettingsPage()
                    }
                }
                quickActionButton("gearshape.fill", label: L10n.t("设置…")) { openNotchSettingsPage() }
                quickActionButton("xmark", label: L10n.t("关闭灵动岛歌词")) {
                    controller.closeFromQuickAction()
                }
            }
            .frame(height: NotchExpandedMetrics.trackInfoActionsHeight)
        }
    }

    /// 「Last.fm」快捷键的动作:翻到 设置 › Last.fm 详情页,跟歌词窗口「收听次数」那行同一个落点。
    private func openLastfmSettingsPage() {
        AppActions.shared.requestSettings(.account(.lastfm))
        AppActions.shared.openSettings?()
    }

    /// 「设置…」快捷键的动作:直接翻到 设置 › 歌词显示 › 灵动岛,照抄 `OverlayQuickSettingsMenu.openMoreSettings`
    /// 那三行。抽成函数是因为头部快捷操作与空闲面板各有一颗。
    private func openNotchSettingsPage() {
        UserDefaults.standard.set(LyricsSurface.notch.appearanceSectionRawValue,
                                  forKey: LyricsSurface.appearanceSectionStorageKey)
        AppActions.shared.requestSettings(.tab(.appearance))
        AppActions.shared.openSettings?()
    }

    /// 没有曲目时左耳那一格(决策 #37):平时是 `idleAppIcon`;有「发现新播放器」的信任提议挂着时换成那个播放器的图标 + 右上角
    /// 一粒小圆点,收起态下这是提示存在的唯一线索(被动的那一半;主动的那一半是卡片自己撑开一次,见 NotchUnknownPlayerPrompt)。
    /// 切换与订阅都在宿主子视图里,这里只把尺寸账(同 idleAppIcon:`earAppIconSide` × 显示倍率)交下去。
    func idleEarIcon(alignment: Alignment) -> some View {
        NotchIdleEarIconHost(prompt: prompt,
                             side: NotchMetrics.earAppIconSide(contentTopInset: controller.contentTopInset),
                             scale: max(1, displayScale), alignment: alignment) {
            idleAppIcon(alignment: alignment)
        }
    }

    /// 没有曲目时 hover 展开出来的那一块。卡片高度给它留的就是这一块(`cardHeight(expanded:)` 的无曲目分支),
    /// 不照有曲目的通式留「三键 + 进度条」—— 那块内容整个被 `hasTrack` 挡掉,留了就是一大块空黑。排法照曲目信息头部
    /// (`trackInfoHeader`):左边两行字、右边一排 22pt 图标键,左内边距同样是歌词那一列的 16pt,上面留
    /// `trackInfoTopSpacing`,下面留 `idlePanelBottomSpacing`(它贴底,4pt 太紧)—— 有曲目和没曲目时
    /// 展开出来的是"同一个位置上的同一种东西",不是两套版式。
    ///
    /// 文案与动作全部复用歌词窗口停播页那套(`IdleStandbyView.noTrackHero` / `IdlePlaybackActions`):
    /// 「没有在播放」+「在 X 播放任意歌曲,歌词会自动出现」;第一颗键 AM / Spotify 是「继续播放」(三段式,
    /// 失败兜底激活 App),其它播放器没有 AppleScript、只给「打开 X」。后两颗是「设置…」「关闭灵动岛歌词」,
    /// 跟头部快捷操作同款、同分组线 —— 但**不看** `expandedShowsQuickActions` 那个开关:那开关管的是"头部
    /// 右侧那块空地要不要塞按钮",而这里的键是空闲面板存在的全部理由,关掉就只剩两行字。不放「搜索歌词」
    /// 「显示歌词」:没有曲目,两者都无物可指。左耳那枚 App 图标已经在顶行上,这里不再画第二枚。
    ///
    /// 不套 `controlButton` 那层"先查 Apple Music 自动化权限"的守卫:`IdlePlaybackActions.resume` 自己会查
    /// (AM 那条走 `checkAppleMusicSafely`),「打开 X」压根不需要权限。
    var idleExpandedPanel: some View {
        let player = IdlePlaybackActions.player
        let canResume = IdlePlaybackActions.canResume(player)
        let name = player.displayName
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: NotchExpandedMetrics.trackInfoLineSpacing) {
                Text(L10n.t("未在播放"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.9))
                // 提示句不点名播放器——
                // 灵动岛这句是泛指,不像歌词窗口停播页那句要跟旁边「打开 X」按钮对上;右边那颗键的
                // tooltip 仍带具体名字(那是一个具体动作的目标)。
                Text(L10n.t("在播放器中播放任意歌曲，歌词将自动显示"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accentOrWhite.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                quickActionButton(canResume ? "play.fill" : "arrow.up.forward.app",
                                  label: canResume ? L10n.t("继续播放") : String(format: L10n.t("打开 %@"), name)) {
                    if canResume {
                        IdlePlaybackActions.resume(player: player)
                    } else {
                        IdlePlaybackActions.openPlayerApp(player)
                    }
                }
                // 分组线,同头部快捷操作:左边是"对播放器做什么",右边是"对这块卡片做什么"。
                Rectangle()
                    .fill(accentOrWhite.opacity(0.18))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 3)
                quickActionButton("gearshape.fill", label: L10n.t("设置…")) { openNotchSettingsPage() }
                quickActionButton("xmark", label: L10n.t("关闭灵动岛歌词")) {
                    controller.closeFromQuickAction()
                }
            }
            .frame(height: NotchExpandedMetrics.trackInfoActionsHeight)
        }
        // 同一份提示,但**往上**弹:这块面板贴着卡片底(下面只剩 idlePanelBottomSpacing 那 10pt),
        // 气泡往下会被窗口硬裁;往上是顶行,空闲态那儿只有一枚 App 图标,盖一下无妨。
        .modifier(QuickActionTooltipOverlay(hovered: hoveredQuickAction,
                                            shown: $shownQuickActionTooltip,
                                            tint: accentOrWhite, edge: .top))
        .padding(.horizontal, NotchMetrics.expandedContentInset)
        .padding(.top, NotchExpandedMetrics.trackInfoTopSpacing)
    }

    /// 快捷操作里的一颗图标键。`label` 当读屏标签,同时喂给自绘的悬浮提示(见 `QuickActionTooltipOverlay`)
    /// —— 这几颗都是纯图标,没有文字。悬停 / 按下反馈在 `NotchIconButton` 里(加,跟三键同一份)。
    ///
    /// `.help(label)` 撤掉了:系统 tooltip 在这扇窗上一次都没弹过,理由与替代方案见
    /// `QuickActionTooltipOverlay` 的头注。
    ///
    /// `key` 是气泡认这颗键用的名字,字形会随状态换的键(喜欢:心 / 实心)要给一个固定的,不然点完气泡对不上它。
    /// `lit`:点亮样式(字形全亮 + 淡底),同随机 / 循环键。
    private func quickActionButton(_ systemName: String, key: String? = nil, label: String, dimmed: Bool = false,
                                   lit: Bool = false, action: @escaping () -> Void) -> some View {
        let hintKey = key ?? systemName
        return NotchIconButton(systemName: systemName, glyphSize: 11, hitSize: NotchExpandedMetrics.trackInfoActionsHeight,
                               tint: accentOrWhite, glyphOpacity: lit ? 1 : (dimmed ? 0.4 : 0.75),
                               restingLevel: lit ? 0.16 : 0, action: action)
            // 指针进出这颗键。离开时**只在"记着的还是自己"时**才清 —— 相邻两颗键的 enter/exit
            // 到达顺序没有保证,少了这道守卫会出现 B 刚记上就被 A 那条迟到的 exit 抹掉。
            .onHover { inside in
                if inside {
                    hoveredQuickAction = QuickActionHint(key: hintKey, text: label)
                } else if hoveredQuickAction?.key == hintKey {
                    hoveredQuickAction = nil
                }
            }
            // 「显示 / 隐藏歌词」那颗点完 `label` 就变,但指针没动、`onHover` 不会再来一次 —— 不同步
            // 的话气泡会停在点之前那句,而这颗键的状态本来就靠这句提示交代(05 章决策 28)。
            .onChange(of: label) { _, newLabel in
                if hoveredQuickAction?.key == hintKey {
                    hoveredQuickAction = QuickActionHint(key: hintKey, text: newLabel)
                }
            }
            // 把自己的位置报给上面那层,气泡靠它对准这颗键 —— 几何交给 SwiftUI 算,不在别处照着
            // 「22 + spacing 2 + 分隔线」再手写一份坐标(那种两处各算一份的数迟早会漂)。
            .anchorPreference(key: QuickActionAnchorKey.self, value: .bounds) { [hintKey: $0] }
            .accessibilityLabel(label)
    }

    private var nextLineDisplayText: String {
        playback.nextLineText ?? ""
    }

    // 必须用 checkForCurrentPlayerSafely(异步),不能用同步版本——理由跟
    // LyricsOverlayView.swift 同名方法的注释一致:同步版本在还没问过时会直接触达有据
    // 可查、可能永久挂起主线程的系统 API。权限不够时用 NSSound.beep() 给一个"没有
    // 生效"的听觉反馈(补上,跟另外两处播放控制入口保持一致),不静默无声。
    /// 随机:点亮 = shuffle,再点回列表。跟循环键互斥(脚本接口只有三态,见
    /// `LyricsWindowView.shuffleButton`)。权限检查在 `setPlaybackMode` 里。
    private func shuffleButton(_ mode: MusicPlaybackController.MusicPlaybackMode) -> some View {
        modeButton("shuffle", active: mode == .shuffle) {
            PlaybackCoordinator.shared.setPlaybackMode(mode == .shuffle ? .list : .shuffle)
        }
    }

    /// 循环:关 → 列表循环 → 单曲循环 → 关;没有单曲循环的播放器两态。跟歌词窗口 `repeatButton` 同一套。
    private func repeatButton(_ mode: MusicPlaybackController.MusicPlaybackMode) -> some View {
        modeButton(mode == .repeatOne ? "repeat.1" : "repeat",
                   active: mode == .repeatOne || mode == .repeatAll) {
            PlaybackCoordinator.shared.setPlaybackMode(
                mode.nextRepeat(allowsRepeatOne: playback.playbackModeAllowsRepeatOne,
                                allowsRepeatAll: playback.playbackModeAllowsRepeatAll))
        }
    }

    /// 熄灭时字形半透明、没有底;点亮时字形全亮、垫一层淡底(歌词窗口 `modeToggleButton` 的样子)。
    private func modeButton(_ systemName: String, active: Bool, action: @escaping () -> Void) -> some View {
        NotchIconButton(systemName: systemName, glyphSize: 10.5, hitSize: 22,
                        tint: accentOrWhite, glyphOpacity: active ? 1 : 0.45,
                        restingLevel: active ? 0.16 : 0, action: action)
            .accessibilityLabel(Text(Self.controlAccessibilityName(systemName)))
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// 播控键的读屏名。键只有图标,不给的话 VoiceOver 读的是符号自带的英文描述(「backward fill」),
    /// 也不跟界面语言走。按图标名给,调用处不用各传一遍。
    private static func controlAccessibilityName(_ systemName: String) -> String {
        switch systemName {
        case "backward.fill": return L10n.t("上一首")
        case "forward.fill": return L10n.t("下一首")
        case "play.fill", "pause.fill": return L10n.t("播放/暂停")
        case "shuffle": return L10n.t("随机播放")
        case "repeat.1": return L10n.t("单曲循环")
        case "repeat": return L10n.t("循环播放")
        default: return ""
        }
    }

    /// glyphSize/hitSize 显式给时优先(展开卡里的三键要比耳朵里的大一号),
    /// 不给就沿用 primary 的两档旧尺寸(耳朵那一个)。
    /// `hintKey` 不为 nil 时,播放控制被拦下那段时间悬停弹一句说明(同快捷操作那排的自绘气泡,外面那层要挂
    /// `QuickActionTooltipOverlay`)。耳朵上那排太窄、放不下气泡,不传。
    func controlButton(_ systemName: String, primary: Bool = false,
                               glyphSize: CGFloat? = nil, hitSize: CGFloat? = nil, hintKey: String? = nil,
                               action: @escaping () -> Void) -> some View {
        let glyph = glyphSize ?? (primary ? 11 : 9.5)
        let hit = hitSize ?? (primary ? 18 : 15)
        let withheldReason = playback.controlsWithheldReason
        return NotchIconButton(systemName: systemName, glyphSize: glyph, hitSize: hit,
                               tint: accentOrWhite, glyphOpacity: withheldReason == nil ? 1 : PlaybackCoordinator.withheldControlOpacity) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                action()
            }
        }
        .accessibilityLabel(Text(Self.controlAccessibilityName(systemName)))
        .modifier(WithheldControlHint(key: hintKey, reason: withheldReason, hovered: $hoveredQuickAction))
    }
}
