import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

// 灵动岛卡片主视图(`NotchLyricsView`,主体在 NotchLyricsView.swift)的顶行:刘海空当与品牌胶囊、音浪、两只耳朵里的可配模块。
extension NotchLyricsView {
    /// 刘海空当(物理刘海遮挡处)里的品牌胶囊彩蛋。
    ///
    /// 肉眼永远看不到——那块被硬件挡死;只在截全屏 / 录屏 / 投屏或镜像到无刘海显示器时
    /// 露出来,像给刘海贴了个牌子。两个条件缺一不画:
    ///  - `notchWidth > 0`:无刘海屏幕的兜底几何和外接屏上的镜像副本都是 0,画了就真的能
    ///    看见,那就不是彩蛋而是一块白疤。
    ///  - `hasTrack`:会议里没放歌、灵动岛停在空闲黑块时,共享画面顶上不该挂着牌子(用户
    ///    选了"只在有曲目时画",而不是参考实现那种常驻)。
    /// 「截屏/录屏时隐藏」开着时整窗不进截图,不必另加开关。高度按顶行让 8pt 边、夹在
    /// 14～22pt(矮刘海机型顶行可能不到 26pt)。装饰元素,读屏不念。
    /// 顶行中间刘海那一段的**占位**:只有宽度,什么都不画。胶囊本体(notchSeam)自钉在 body 的
    /// ZStack 顶部居中(理由见那里),顶行只需要把这段宽度让出来。
    private var notchGap: some View {
        Spacer(minLength: 0).frame(width: controller.notchWidth)
    }

    var notchSeam: some View {
        ZStack {
            if controller.notchWidth > 0, controller.hasTrack {
                Text(verbatim: "Lyrimuse")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(seamTextColor)
                    .padding(.horizontal, 9)
                    .frame(height: min(22, max(14, controller.contentTopInset - 8)))
                    .background {
                        // 底色跟灵动岛当前主色走(同歌名/音浪那份 accent),上半截叠一层淡白渐变
                        // 加 0.5pt 浅描边当光泽——纯色胶囊贴在纯黑刘海里像一块色卡,加点高光才
                        // 读得出"是个立体的牌子"("颜色跟着灵动岛走,稍微
                        // 加一点光泽有区分度")。
                        Capsule().fill(accentOrWhite)
                            .overlay {
                                Capsule().fill(LinearGradient(
                                    colors: [.white.opacity(0.42), .white.opacity(0.10), .clear],
                                    startPoint: .top, endPoint: .center))
                            }
                            .overlay { Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5) }
                    }
                    .accessibilityHidden(true)
            }
        }
        .frame(width: controller.notchWidth)
    }

    /// 胶囊字色按底色的 WCAG 相对亮度选黑/白:亮度 > 0.179(黑白两侧对比度相等的临界点)
    /// 时黑字更清楚,否则白字。复用 LocalPlaybackSource 描边取色那套亮度公式,别再写一份。
    private var seamTextColor: Color {
        guard let ns = NSColor(accentOrWhite).usingColorSpace(.sRGB) else { return .black }
        let lum = LocalPlaybackSource.relativeLuminance(
            r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
        return lum > 0.179 ? .black : .white
    }

    /// 播放指示条(音浪)是不是配给了这只耳朵,而且这只耳朵没选控制键——三键本身已经在
    /// 报播放状态(播放时画 ⏸),音浪摆在旁边是同一件事说两遍,而且窄宽度下(耳朵最窄
    /// 70pt,减内缩 6 之后 64pt)刚好放得下三键的 48pt,再挤进音浪的 14+5 就超了。这是
    /// "音浪贴这只耳朵外缘"唯一的例外,跟哪只耳朵无关。
    private func showsEqualizer(on side: NotchEqualizerEar, module: NotchEarModule) -> Bool {
        controller.showsEqualizer && controller.equalizerEar == side && module != .controls
    }

    private var equalizerBars: some View {
        // 窗口看不见时按暂停处理:TimelineView 不会因为窗口被遮住 / orderOut 自己停。
        // 「减弱动态效果」开着也按暂停画:音浪是纯装饰的动画,别的会动的部分(弹簧、出场撑开)都已经为它停了。
        EqualizerBars(color: accentOrWhite, isPlaying: playback.isPlayingNow && surfaceVisible && !reduceMotion,
                      resyncKey: equalizerResyncKey,
                      amplitude: Self.vocalAmplitude(at:))
    }

    /// 音浪的关键帧是按「当前行的逐字 + 锚点外推」预先排好一段的(见 EqualizerBars 头注),这几样
    /// 一变就得按新基准重排:换行(包络跟着新一行的字走)、锚点重发(拖动进度 / 恢复播放)、总偏移。
    private var equalizerResyncKey: Int {
        var h = Hasher()
        let line = playback.currentLine
        h.combine(line?.words?.first?.startMs)
        h.combine(line?.words?.count)
        h.combine(line?.plainText)
        h.combine(playback.anchor?.fetchedAt)
        h.combine(playback.anchor?.progressMs)
        h.combine(playback.anchor?.rate)
        h.combine(playback.lyricsOffsetMs)
        return h.finalize()
    }

    /// 顶行:收起态与稳态/展开态共用这一个 HStack。两只耳朵的 `.frame(width: earWidth)` 随卡片连续动画;收起/稳态之间变的只是
    /// "这只耳朵此刻显示哪个模块、音浪在不在这侧"两个值:
    ///  - 收起:左耳固定封面、右耳固定音浪(iPhone 灵动岛式极简,歌名/播放键都收进 hover 展开卡);
    ///  - 稳态/展开:按设置(`leftEar` / `rightEar` / 音浪贴哪侧)。
    /// 两种形态下模块相同时(比如本来就左耳封面、右耳音浪)视图身份完全不变,连淡入淡出都没有,封面和音浪只是跟着耳朵边沿平移;
    /// 模块不同时,切换发生在耳朵内部、贴着耳朵外缘。别改成两个视图在 VStack 里按 isCollapsed 整行互换:SwiftUI 对离场的那一行按
    /// 离场时的耳宽布局、对刚插入的那一行按目标耳宽布局,两行都从卡片左沿起排,hover 展开的头 ~200ms 里两行的内容各在错的位置上
    /// 淡入淡出(刘海胶囊会漏出来,耳朵里的音浪 / 文字同样错位)。
    /// 音浪在暂停时是静止的矮条(EqualizerBars 自己按 isPlaying 处理),收起态的封面是"刚才在放什么"的余韵;没封面时左耳留空,
    /// 不画占位方块(理由同 artworkThumbnail)。
    ///
    /// 布局细节两条,收起与稳态一致、不随状态变:朝刘海那一侧内缩 `earNotchInset`(收起态 34pt 的耳朵减掉 6 还剩 28,放得下 23pt 的
    /// 封面 / 14pt 的音浪);左耳内容靠左外缘、右耳靠右外缘(05 章「指示条贴外缘,收放切换时不横跳」)。
    func topRow(earWidth: CGFloat) -> some View {
        let collapsed = controller.isCollapsed
        let leftModule: NotchEarModule = collapsed ? .artwork : playback.leftEar
        let rightModule: NotchEarModule = collapsed ? .none : playback.rightEar
        let equalizerOnLeft = !collapsed && showsEqualizer(on: .left, module: playback.leftEar)
        let equalizerOnRight = collapsed || showsEqualizer(on: .right, module: playback.rightEar)
        // 音浪**独占**这只耳朵时的位置:非展开态一律贴外缘(左耳最左、右耳最右);只有
        // 卡片顶在宽度下限(最小宽,耳朵窄到音浪几乎填满可视段)时保持居中 —— 那是居中
        // 修好偏心的那个状态,宽度一放开居中就成了"飘在中间"。其余情况(耳朵里还有模块)
        // 本来就贴外缘 —— 那时音浪跟模块是一组,而文字跑马灯溢出时必须从外缘起排,不能居中。
        // **hover 展开态也不居中**(「展开要在最边上」):展开时耳朵宽出一大截,居中
        // 就成了飘在中间 —— 判据与推导见 soloEqualizerInset 的注释。
        let soloEqualizerLeft = equalizerOnLeft && !isIdleNoTrack && !controller.isAdBreakNow
            && leftModule == .none
        let soloEqualizerRight = equalizerOnRight && rightModule == .none
        let soloInset = NotchWidthBounds.soloEqualizerInset(
            earWidth: earWidth, barsWidth: EqualizerBars.width,
            cardPadding: controller.topRowPadding,
            shoulder: NotchOutline.shoulderRadius(notchHeight: controller.contentTopInset),
            expanded: controller.isExpanded,
            atMinimumWidth: controller.isCardAtMinimumWidth)
        return HStack(spacing: 0) {
            // 左耳:模块 + (可选)音浪。音浪贴哪只耳朵可配,
            // 这里跟下面右耳是完全对称的结构——只是音浪在外缘,外缘在左耳是"最左",
            // 所以音浪排在模块**前面**(下面右耳反过来,音浪排在模块后面)。
            // `.none` 不渲染(它是一条空的跑马灯,在 HStack 里会把音浪推到另一头去;要"贴外缘"
            // 靠的是外面那句 .frame(maxWidth:alignment:))。
            HStack(spacing: NotchMetrics.earWaveSpacing) {
                if equalizerOnLeft {
                    equalizerBars
                }
                // 压根没有曲目时左耳固定画 App 图标,
                // 不看配置:这时候除「播放控制」外每个模块都是空的(歌名/歌手/专辑/时长在 metadataText /
                // clockText 里对 isIdleNoTrack 一律回空串,封面为 nil 整块不画),左耳本来就是一片
                // 空白 —— 图标占的是这片空白,不是抢走谁的位置;左耳配了「播放控制」的,没有曲目时
                // 三键也无物可控,一并让位。有曲目的那一刻它让回配置的模块。
                if isIdleNoTrack {
                    // 经 idleEarIcon 再包一层:有「发现新播放器」的信任提议挂着时换成那个播放器的图标。
                    idleEarIcon(alignment: .leading)
                } else if leftModule == .artwork {
                    // 换歌翻牌:封面和广告时的喇叭画在同一枚翻牌里,广告结束、新封面到了,喇叭才能翻成封面。
                    flippingEarArtwork(alignment: .leading, showsAdIcon: controller.isAdBreakNow)
                } else if controller.isAdBreakNow {
                    // 广告期间左耳那枚喇叭。不看配置、也不看这一格原本有没有内容:只要识别到是广告,封面部分都用这个替代,不做
                    // "只占空白"那种折中,也不保留播放器给的广告物料图。这条口径覆盖全 App 四个当前曲目封面位(左耳、歌词行末尾、
                    // 歌词窗口封面卡、菜单栏面板那枚),清单与"为什么灵动岛展开头部那枚不用改"见 05 章「广告态」⑦。
                    //
                    // 代价:左耳配了「播放控制」的用户,广告期间那三颗键会被这枚图标顶掉。可接受,hover 展开卡的进度条下方本来就有
                    // 一整排三键(广告期间照旧渲染,见 adStatusColumn 头注)。这跟决策 #30(没有曲目时左耳固定画 App 图标、配了播放
                    // 控制的一并让位)是同一个取舍。收起态自动一并覆盖:上面 `leftModule` 在收起时固定是 `.artwork`。
                    adBreakEarIcon(alignment: .leading)
                } else if leftModule != .none {
                    earContent(leftModule, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 音浪独占且卡片顶在宽度下限时才往里推(居中于可视耳朵),其余贴外缘
            // (见 soloEqualizerInset)。
            .padding(.leading, soloEqualizerLeft ? soloInset : 0)
            // 内缩必须在 .frame(width:) **之前** —— 之后加等于把耳朵整体变宽 6pt,
            // 三段就不再严丝合缝铺满,背景形状/刘海空当会跟着错位。
            .padding(.trailing, NotchMetrics.earNotchInset)
            .frame(width: earWidth)

            // 刘海本身的空当——物理硬件不发光区域。那枚肉眼看不见的彩蛋(notchSeam)
            // **不画在这一行里**,而是钉在 body 的 ZStack 顶部居中,这里只留空当的宽度(理由见 notchGap)。
            notchGap

            // 右耳:模块 + (可选)音浪。控制键不放耳朵里:岛是 hover 展开的,光标到达耳朵之前岛已经展开,完整三键就在展开卡的
            // 进度条下方(见 expandedContent),耳朵里再留一枚播放键是重复目标。
            HStack(spacing: NotchMetrics.earWaveSpacing) {
                if rightModule != .none {
                    earContent(rightModule, alignment: .trailing)
                }
                if equalizerOnRight {
                    equalizerBars
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, soloEqualizerRight ? soloInset : 0) // 理由同左耳
            .padding(.leading, NotchMetrics.earNotchInset) // 理由同左耳,见 earNotchInset
            .frame(width: earWidth)
        }
        // 展开态收到跟下面那一列内容同一条边界(见 topRowPadding),跟卡片同一条弹簧过去。
        .padding(.horizontal, controller.topRowPadding)
    }

    // MARK: - 耳朵里的可配模块

    /// 一只耳朵里画什么。`alignment` 是**耳朵**的属性(左耳靠左、右耳靠右),不是模块的。
    ///
    /// 三条约束,每条都对应本仓一处既有做法:
    ///
    /// ① **只有时间类模块才套 `TimelineView`。** 给歌名/歌手/专辑也套一个时钟纯属白付(见 NotchPlayback 的头注)。
    ///
    /// ② **没有锚点就不排表**,静态画冻结值 —— 跟本仓既有的**存在性门**同一个做法(`NotchScrubber`
    ///    和歌词窗口那条进度都是 `if let anchor` 才挂表)。暂停/没在播放时 `LocalPlaybackSource`
    ///    会把 anchor 置 nil,于是这一格退回 `pausedPositionMs` 的冻结读数、一次表都不排。
    /// 这条不是可选优化:设置页那块编辑台渲染的是**同一份**视图,而它的替身 chrome 把
    ///    `isCollapsed` 写死 false、暂停着也照样画耳朵 —— 没有这道门,只要有人把耳朵配成时间类,
    ///    设置页开着就会每秒空转一次,哪怕歌是停着的。
    ///
    /// ③ **周期起点按锚点对齐到"曲目位置的整秒"**,步长按倍速取 `1/rate`(见
    ///    `NotchTimeFormat.clockSchedule`)。钉在**墙钟**整秒上是不行的:曲目位置的整秒边界跟
    ///    墙钟整秒无关,两者的相位差在一条锚点的生命周期里是**常量** —— 也就是说 hover 展开时
    ///    耳朵可能整首歌都比正下方那条迷你进度条**慢 1 秒**(耳朵 1:23、进度条 1:24 长期并排),
    ///    而不是偶尔闪一下。对齐之后两处读数同源同相。
    /// 别顺手把 `clockText` 里的 `Date()` 换成 `context.date`:对齐之后 tick 恰好落在边界上,
    ///    用调度时刻采样有可能因为亚毫秒取整读回旧的那一秒;实际派发比调度晚几毫秒,`Date()`
    ///    反而落在边界的正确一侧。
    @ViewBuilder
    private func earContent(_ module: NotchEarModule, alignment: Alignment) -> some View {
        switch module {
        case .artwork:
            flippingEarArtwork(alignment: alignment, showsAdIcon: false)
        case .controls:
            earControls(alignment: alignment)
        case .elapsed, .remaining:
            if let anchor = playback.anchor, surfaceVisible {
                TimelineView(NotchTimeFormat.clockSchedule(
                    for: anchor, countdownFromMs: module == .remaining ? playback.currentDurationMs : nil)) { _ in
                    earText(clockText(module), module: module, alignment: alignment)
                }
            } else {
                earText(clockText(module), module: module, alignment: alignment)
            }
        case .playCount:
            // 广告、电台口白期间没有「这首」可数(口白时歌名耳朵已换成台名)。
            if !isIdleNoTrack, !playback.isCurrentTrackAdBreak, radioTalkStation == nil {
                NotchEarPlayCount(title: playback.title, artist: playback.artist, tint: accentOrWhite, alignment: alignment)
            }
        case .player:
            if !isIdleNoTrack {
                NotchEarPlayerIcon(side: NotchMetrics.earAppIconSide(contentTopInset: controller.contentTopInset),
                                   scale: max(1, displayScale), alignment: alignment,
                                   trackKey: "\(playback.artist)|\(playback.title)")
            }
        case .title, .artist, .album, .none:
            earText(metadataText(module), module: module, alignment: alignment)
        }
    }

    /// 耳朵里那枚封面(`NotchEarArtworkFlip`):换歌后新封面到了、控制器揭晓了这一首(歌名掉下来的那一拍)翻一下,
    /// 一直开着、不看设置。`showsAdIcon` 只有左耳会传 true —— 喇叭也画在这枚翻牌里,广告结束才能翻成封面。
    ///
    /// 尺寸走**收起态那一枚**的公式(`contentTopInset − 10`,约 23pt),**不是**歌词行末尾
    /// 那枚 32pt 的:耳朵只有 `contentTopInset` 那么高,32pt 塞进来上下一点余量都不剩(见 artworkThumbnail 上方)。
    ///
    /// 没有封面数据时**整块不画**(不摆占位方块)—— 跟歌词行末尾那枚同一个取舍,理由见那边。
    private func flippingEarArtwork(alignment: Alignment, showsAdIcon: Bool) -> some View {
        let side = NotchMetrics.earArtworkSide(contentTopInset: controller.contentTopInset)
        return NotchEarArtworkFlip(
            title: playback.title, artist: playback.artist,
            artworkImage: playback.artworkImage, highResImage: playback.highResArtworkImage,
            overrideImage: radioTalkStation?.image, isAdBreak: showsAdIcon,
            isRevealed: controller.revealsTrack(NotchTrackDropRules.key(
                title: playback.title, artist: playback.artist, isAdBreak: playback.isCurrentTrackAdBreak)),
            alignment: alignment, animated: !reduceMotion,
            artwork: { artworkThumbnail($0, side: side) },
            adIcon: { adBreakEarIconContent })
    }

    /// 广告期间左耳那枚喇叭。
    ///
    /// 符号沿用 `adStatusColumn` 和「没能跳过这条广告」瞬态横幅里的同一枚 `megaphone.fill` ——
    /// 同一件事在这张卡上不该出现两种画法。前景色也跟那一行同口径(`accentOrWhite` 七成不透明
    /// + 同一道投影);广告期间底已经是纯黑(见 body 里那层 `Color.black`),七成白在纯黑上足够清楚。
    ///
    /// 不接点击:它是个状态标记,不是按钮 —— 广告期间真正能点的那件事(「跳过广告」)有自己的键,
    /// 在展开卡的状态行右侧,见 `adStatusColumn`。读屏也不念(装饰元素):同一行的「广告中 · 还剩
    /// 0:20」已经把这件事说清楚了,再念一遍是重复。
    private func adBreakEarIcon(alignment: Alignment) -> some View {
        adBreakEarIconContent.frame(maxWidth: .infinity, alignment: alignment)
    }

    /// 喇叭本体(不含占满耳朵的那层 frame):换歌翻牌那枚翻牌里也画它。
    @ViewBuilder
    private var adBreakEarIconContent: some View {
        let side = NotchMetrics.earAdIconSize(contentTopInset: controller.contentTopInset)
        let hint = showsAdSkipHint
        HStack(spacing: side * 0.22) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: side, weight: .semibold))
            if hint {
                // 比喇叭小一号、再淡一点:它是**附注**(这条广告能跳),不是这一格的主语(在放广告)。
                // 符号跟展开卡那颗「跳过广告」键同一枚 `forward.end.fill` —— 同一件事在这张卡上
                // 不该出现两种画法(同喇叭那条)。
                // 0.78:喇叭 ~13pt 时这枚约 10pt,跟悬浮窗那排非主按钮的 10.5pt 同量级(那是这个
                // 仓库验过的"小到不挡视线、又还认得出"的下界),再小就开始糊成一个点。
                Image(systemName: "forward.end.fill")
                    .font(.system(size: side * 0.78, weight: .semibold))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(accentOrWhite.opacity(0.7))
        .notchTextShadow()
        // 喇叭本身是装饰(同一行的「广告中 · 还剩 0:20」已经说清楚了);带上提示之后这一组就有了
        // 独立信息 —— 稳态下它**是**读屏用户唯一能知道"这条能跳"的地方,所以这时候要念。
        .accessibilityHidden(!hint)
        .accessibilityLabel(hint ? L10n.t("此广告可跳过") : "")
    }

    /// 稳态下要不要在左耳那枚喇叭旁边补一枚「可跳过」提示(「这个按钮目前只在展开
    /// 状态有;帮我在灵动岛歌词行那里也加一个,虽然移动上去就展开了,但是可以起到提示可以跳过的作用」)。
    ///
    /// 两道门,都是"别把同一件事说两遍":
    ///  ① **展开态不画** —— 那时 `adStatusColumn` 右端就是那颗真的「跳过广告」键,再加一枚图标是重复。
    ///  ② **稳态歌词行画得出来时也不画** —— 开着「显示歌词」的人,稳态那份 `lyricRow` 渲染的就是
    ///     `adStatusColumn`(带真键),同理重复。关着的人稳态只剩顶行,那枚喇叭是广告这件事在卡上
    ///     唯一的落点,提示只能挂在它旁边。
    ///
    /// 刻意**只是个标记、不接点击**:稳态下指针一压上来卡片就展开了,这一格根本没有"被点到"的时机,
    /// 做成按钮只会是又一段永不触发的死代码(同喇叭那条、同悬浮窗那排按钮为什么不是 Button)。
    private var showsAdSkipHint: Bool {
        playback.canSkipAd && !controller.isExpanded && !controller.showsLyrics
    }

    /// 没有曲目时左耳里的 App 图标。
    ///
    /// 图标取 `NSApplication.shared.applicationIconImage`(bundle 里的 AppIcon.icns),但**不**直接
    /// `Image(nsImage:).resizable()` 缩 —— 那样 1024px 那档位图会被
    /// SwiftUI 一步线性采样到 ~52px,圆角和音符边缘全是台阶("很有锯齿感")。现在按「pt 边长 × 显示倍率」预先光栅化
    /// 一次(`NotchIdleAppIcon.bitmap`,高质量重采样、按像素边长缓存),`Image(decorative:scale:)` 逐像素
    /// 贴上去,运行期零缩放。不裁圆角、不描边、不投影 —— 它自己就是一枚带圆角方块的 macOS 图标,再套
    /// 一层 `artworkThumbnail` 那圈处理会把它的形状裁掉一截。
    ///
    /// 只是一个"我在这儿"的标记,不接点击:没有曲目时点它能做的事(打开歌词窗口 / 设置)在
    /// hover 展开卡和菜单栏里都有,这里再接一遍是重复目标;读屏也不念(装饰元素)。
    /// 尺寸见 `NotchMetrics.earAppIconSide`。
    @ViewBuilder
    func idleAppIcon(alignment: Alignment) -> some View {
        let side = NotchMetrics.earAppIconSide(contentTopInset: controller.contentTopInset)
        let scale = max(1, displayScale)
        Group {
            if let bitmap = NotchIdleAppIcon.bitmap(pixelSide: Int((side * scale).rounded())) {
                Image(decorative: bitmap, scale: scale)
            } else {
                // 理论上到不了:CGContext 建不出来才会 nil。退回原图,至少有东西。
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityHidden(true)
    }

    /// 耳朵里那一排播放控制键。
    ///
    /// 尺寸沿用 `controlButton` 的 `primary` 两档默认值(侧键 glyph 9.5 / 命中 15,播放键 11 / 18)。展开卡里那一排是 22pt,
    /// 比这里大一号,是刻意的(那儿是真正会被点的地方)。
    ///
    /// 横向账(min 宽度下也要放得下):三键 15+18+15 = 48pt,`spacing: 0` —— 命中框本身就比
    /// 图标大一圈(15 的框装 9.5 的图标,两侧各 2.75pt),再加间距会白白撑宽。而耳朵最窄是
    /// **70pt**(`NotchLyricsWindowController.minEarWidth`,宽度滑杆的下界就是按它算的),
    /// 减掉朝刘海那侧 6pt 的内缩还有 64pt,放得下。右耳还要再减音浪那 14pt + 5pt 间距 = 45pt
    /// —— 放不下,所以右耳选控制键时**音浪让位**(见 topRow)。
    private func earControls(alignment: Alignment) -> some View {
        HStack(spacing: 0) {
            controlButton("backward.fill") { MusicPlaybackController.previousTrack() }
            controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill", primary: true) {
                // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
                PlaybackCoordinator.shared.userTogglePlayPause()
            }
            controlButton("forward.fill") { MusicPlaybackController.nextTrack() }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    /// 三个元数据模块的取值。
    ///
    /// 三条既有规矩原样保留,别在加模块时顺手丢掉:
    ///   ① **广告插播**:歌名位写「广告中」,不展示广告物料的名字;
    ///      歌手/专辑在广告期间一律留空 —— 广告没有"歌手"可言,画上去是假信息。
    ///   ② **压根没有曲目时留白**,不摆 ♪("那个无意义的音符不要占位置")。
    ///   ③ 歌名为空时的 ♪ 兜底只在"有曲目但拿不到歌名"这种边角才到得了,保留。
    func metadataText(_ module: NotchEarModule) -> String {
        if isIdleNoTrack { return "" }
        let isAd = playback.isCurrentTrackAdBreak
        // 口白:歌名位换成台名,
        // 歌手/专辑留空 —— 理由跟广告那条一模一样,口白没有"歌手"可言,画上去是假信息。
        // 抓不到台卡(`radioTalkStation` 为 nil)就整条不生效,还显示上一首,见 RadioStationCard。
        let station = radioTalkStation
        switch module {
        case .title:
            if isAd { return L10n.t("广告中") }
            if let station { return station.name }
            return playback.displayTitle.isEmpty ? "♪" : playback.displayTitle
        case .artist: return (isAd || station != nil) ? "" : playback.displayArtist
        case .album: return (isAd || station != nil) ? "" : playback.displayAlbum
        // 非文本模块不走这条路(见 earContent 的分发),这里只是把 switch 补齐。
        case .artwork, .controls, .elapsed, .remaining, .playCount, .player, .none: return ""
        }
    }

    /// 口白期间顶替曲目卡的台名 / 台标。抓不到台卡就是 nil —— 那时一切照旧(还显示上一首),
    /// 宁可保持现状也不要编一个台名出来,判据与实测见 `RadioStationCard`。
    var radioTalkStation: (name: String, image: NSImage?)? {
        guard playback.isRadioTalkBreak, let name = playback.radioStationName, !name.isEmpty else { return nil }
        return (name, playback.radioStationImage)
    }

    /// 歌词行、展开头部那两枚封面画哪张图:电台口白期间换台标,其余高清图优先、退到普通那张。
    var displayedArtworkImage: NSImage? {
        radioTalkStation?.image ?? playback.highResArtworkImage ?? playback.artworkImage
    }

    /// 已播 / 剩余。位置口径跟卡片里那条迷你进度条同源:锚点外推 ?? 暂停冻结位置;歌词时间轴
    /// 偏移**不适用**(那是歌词的事,不是播放进度的事,别顺手加上去)。时长未知(播客/流)时
    /// 剩余算不出来,整块留白而不是画个 `--:--` 占位 —— 不为拿不到的数据编一个占位符,跟预览
    /// 那条"不编造假进度"是同一个态度。
    ///
    /// 同源**不等于**逐帧同值,两处已知的差:
    ///   - **拖动进度条时**:进度条画的是拖到哪儿(它自己的 `@GestureState`,私有),耳朵画的仍是
    ///     真实播放位置。不把拖动状态提上来是刻意的 —— 那要么把私有手势状态提到整卡这一层
    ///     (整卡跟着每个指针事件重估,正是那轮性能审计修掉的东西),要么再拉一条通道。
    ///   - **剩余时长的时长来源**:这里用 `playback.currentDurationMs`,进度条用 `anchor.durationMs`。
    ///     正常一致,但这是第二个可漂的点,改任一处时对一下另一处。
    ///
    /// **广告插播时照常显示**,不套用 `metadataText` 那条"广告期间歌手/专辑留空"的规矩:
    /// 位置和时长在广告期间是播放器对广告物料的真实读数,不是假信息;清空反而会让耳朵跟正下方
    /// 那条进度条自相矛盾。
    private func clockText(_ module: NotchEarModule) -> String {
        guard !isIdleNoTrack else { return "" }
        guard let position = playback.anchor?.extrapolatedPositionMs(now: Date())
                ?? playback.pausedPositionMs else { return "" }
        switch module {
        case .elapsed:
            return NotchTimeFormat.mmss(ms: position)
        case .remaining:
            guard let total = playback.currentDurationMs, total > 0 else { return "" }
            return "-" + NotchTimeFormat.mmss(ms: max(0, total - position))
        default:
            return ""
        }
    }

    /// 耳朵里那一行字。跑马灯的 id 用**显示串**本身 —— 换了内容才重新测量/重新开始滚动。
    /// 跑马灯走图层(`LayerMarquee`),按窗口可见性停(05 章决策 99)。
    ///
    /// 等宽数字**只给时间类**。给歌名/歌手/专辑也套上的话,带数字的名字("M83"、
    /// "24K Magic")字形会被静默改掉 —— 而前提是"默认配置逐像素稳定"。
    /// 时间类必须套:不套的话每秒跳一格数字宽度就变、整行跟着抖。
    /// 条件收进 **Font 值本身**(`Font.monospacedDigit()` 返回 Font),不走 `if/else` 也不走
    /// `ViewModifier` + `AnyView`:那两种都会在视图树上多一层类型/身份变化,而这里变的只是
    /// 一个字体属性。别为「避免分支切换整块重建」改回 modifier:`isClock` 一变,上面 `earContent` 的分支本来就先换了,
    /// 子树无论如何都要重建。
    private func earText(_ text: String, module: NotchEarModule, alignment: Alignment) -> some View {
        let base = Font.system(size: 11.5, weight: module.isPrimary ? .semibold : .medium)
        return LayerMarquee(id: text, restingAlignment: alignment, isActive: surfaceVisible) {
            Text(text)
                .font(module.isClock ? base.monospacedDigit() : base)
                .foregroundStyle(accentOrWhite.opacity(module.isPrimary ? 0.85 : 0.6))
                .lineLimit(1)
        }
    }
}
