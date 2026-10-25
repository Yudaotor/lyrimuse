import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

// 灵动岛卡片主视图(`NotchLyricsView`,主体在 NotchLyricsView.swift)的封面缩略图与歌词行:主行(图层逐字 / 跑马灯)、副行、广告态那一格、音浪振幅。
extension NotchLyricsView {
    // 32pt 是"在 44pt 高的歌词行里上下各留 6pt"倒推出来的观感取值,夹在 [16, 32] 之间:
    // 上限避免歌词行万一变高就把封面撑得比歌词本身还抢眼(歌词才是这个产品的主体),
    // 下限保证行高万一变矮,方块也不会缩到看不出是一张封面。
    private static func artworkSide(rowHeight: CGFloat) -> CGFloat {
        max(16, min(32, rowHeight - 12))
    }

    // 歌词行尾端(卡片右下角)那枚专辑封面小图。
    //
    // 位置选在这里而不是顶行歌名左边:顶行左耳的可用宽度是 (窗口宽 - 刘海宽 - 20) / 2,默认 360pt 宽配 179pt 刘海只有 80.5pt,
    // 放进一枚小图连间距要占掉四分之一以上,歌名被挤得只剩 50 多 pt。歌词行是整条 360pt(去掉左右各 16pt padding 还有 328pt)、
    // 行高 44pt,同一枚封面在这里能做到 32pt 见方而只占掉歌词 12.8% 的宽度,视觉上也正好落在卡片右下角这个空着的位置上。
    //
    // 稳态下这里就是卡片的右下角;hover 展开时下面会再长出"下一句预览+进度条"那一块,封面保持钉在歌词行内不动(不跟着卡片底边
    // 往下跑),避免鼠标一进一出封面就上下跳。
    //
    // 没有封面数据时不画占位方块、直接连位置一起不占:播放中绝大多数曲目都拿得到封面(拿不到的是本来没有封面的播客/取图失败这类
    // 少数情况),为少数情况长期锁掉一块位置画一个空方块不值得。换歌时不会"封面消失再出现":换歌那一刻旧封面会一直留着直到新封面
    // 取回来(见 LocalPlaybackSource 的 scheduleArtworkStaleTimeout/artworkRetryDelays),只有"启动后第一首"和"这首歌真的没有封面"
    // 两种情况才会真的发生一次宽度增减。
    //
    // 描边 + 投影是给"卡片背景可能是浅色"兜底:磨砂玻璃风格会透出桌面颜色,浅色壁纸下一张浅色封面直接贴上去边界会糊成一片,
    // 一圈极淡的白描边能把方块轮廓钉住。
    /// side:不给就按歌词行那一档(32pt)。耳朵里那枚要小一号,理由见 earArtwork。
    ///
    /// 图不在运行期缩:`Image(nsImage:).resizable().scaledToFill()` 把 600px 的封面一步缩到 46px 走的是线性采样、没有面积平均,
    /// 半调网点封面(黄底黑点那种)缩出来是一片摩尔纹黑斑,而且随展开动画里的亚像素相位一帧一个样。按目标像素边长预先重采样一次
    /// (`ArtworkThumbnailCache` → `ArtworkThumbnail.squareBitmap`,`.high` 插值),`Image(decorative:scale:)` 逐像素贴,跟左耳
    /// App 图标(`NotchIdleAppIcon`,决策 #30)同一招。裁方(aspect-fill 居中裁)也在位图里做,所以这里不 `.scaledToFill()`;
    /// `.frame` 仍钉一次,`clipShape` 才按这枚的尺寸裁圆角。悬停 / 按下反馈的状态由 `HoverReveal` 持有而不是放在本视图上,理由见
    /// 那个壳的注释(这是函数,三处调用点共用)。
    func artworkThumbnail(_ image: NSImage, side: CGFloat? = nil) -> some View {
        let side = side ?? Self.artworkSide(rowHeight: controller.lyricRowHeight)
        return HoverReveal { hovering in
            artworkButton(image, side: side, hovering: hovering)
        }
    }

    /// 封面键的本体。拆成单独一个函数只为**不给下面这四十行整体缩进**:壳套在外面、本体原位不动,
    /// diff 就只有签名和 buttonStyle 两行(这个文件同时有别的会话在改,小 diff 是硬要求)。
    private func artworkButton(_ image: NSImage, side: CGFloat, hovering: Bool) -> some View {
        let scale = max(1, displayScale)
        // 点封面 → 打开歌词窗口。走 AppActions 统一入口,激活
        // 时序(先 NSApp.activate 再 openWindow)在注册处已处理,跟快捷键/菜单/面板同路。
        return Button {
            AppActions.shared.openLyricsWindow?()
        } label: {
            Group {
                if let bitmap = ArtworkThumbnailCache.bitmap(for: image, pixelSide: Int((side * scale).rounded())) {
                    Image(decorative: bitmap, scale: scale)
                } else {
                    // 理论上到不了:CGContext 建不出来才会 nil。退回运行期缩放,至少有图。
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
                .frame(width: side, height: side)
                // 这一格只画静态封面,别叠动态封面(MotionCoverView):这一格最大也就 NotchExpandedMetrics.trackInfoArtworkSide 这个量级
                // (耳朵那档只有 32pt),Apple 的 motion artwork 是给整张专辑封面设计的慢镜头,缩到这么小基本只剩一片蠕动的色块,
                // 看不出画的是什么。歌词窗口那张 460pt 的卡才是它该出现的地方(03 章第 6 节)。
                .clipShape(RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous))
                // 那圈 0.18 白描边搬进了 `NotchArtworkButtonStyle` —— 它现在要随悬停 / 按下
                // 抬亮(0.18 → 0.38 → 0.5),留在标签里只能是定值。
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        }
        .buttonStyle(NotchArtworkButtonStyle(cornerRadius: NotchMetrics.artworkCornerRadius,
                                             hovering: hovering))
        .help(L10n.t("打开歌词窗口"))
    }

    /// 歌词行,外面包一层瞬态横幅:有瞬态提示(改歌词偏移/调音量)时这一行让位给提示条,提示到期再换回歌词。只盖歌词行、
    /// 不动卡片高度和顶行控件:提示是"顺带说一句",不该让整块卡片跳一下。
    func lyricRow(reportsWidth: Bool) -> some View {
        // NotchTransientCenter 的订阅下沉在 NotchTransientHost 子视图里 —— 横幅出现/
        // 消失(音量连调时每档一次)只失效歌词行,不打醒整卡 body。
        NotchTransientHost(tint: accentOrWhite) {
            lyricRowContent(reportsWidth: reportsWidth)
        }
    }

    private func lyricRowContent(reportsWidth: Bool) -> some View {
        HStack(spacing: NotchMetrics.artworkLyricSpacing) {
            // 封面贴左还是贴右可配(`notchLyricRowShowsArtwork` / `notchLyricRowArtworkPosition`,见 NotchPlayback 的注释),默认贴右、
            // 默认开:升级上来的人不能发现封面凭空挪位或消失。
            if playback.lyricRowArtworkPosition == .left { lyricRowArtwork }
            // restingAlignment = 「对齐方式」。只管**装得下**的短句靠哪边:
            // 溢出的句子跑马灯一律按 .leading 起滚(理由见 `MarqueeText.restingAlignment` 的注释,靠右摆等于
            // 一上来就把开头几个字挂在容器外面),所以这一项在长句上天然无效果 —— 跟菜单栏
            // 同名设置是同一条语义,help 文案里说明了。
            //
            // 对齐的参照系是**歌词这一格**,不是整张卡:封面是这个 HStack 的兄弟,它占掉的
            // 那 42pt(32 封面 + 10 间距)不在跑马灯的容器里。所以开着封面选「居中」时,
            // 文字是在"除封面之外的剩余宽度"里居中、相对整卡略偏封面对侧。这是刻意的 ——
            // 要相对整卡居中就得把封面改成 overlay 叠在歌词上,那会直接违反上面那段
            // `.animation(nil, value)` 治的"封面遮挡歌词"。
            // 广告插播:这一格整个换成「📣 广告中 · 还剩 0:21   [跳过广告]」,不走歌词那套
            // (副行 / 跑马灯 / 逐字染色对广告全无意义)。分流放在这一层而不是 `mainLyricLine` 的那个
            // 「广告中」分支里,因为倒计时和跳过键要占满这一格的宽度,而那个分支只是一段文字。
            Group {
                if playback.isCurrentTrackAdBreak {
                    adStatusColumn
                } else {
                    lyricTextColumn
                }
            }
            // 跑马灯按被提议的宽度定尺寸(能吃下任何宽度),HStack 会先给定尺寸的封面分配它那 32pt,
            // 剩下的宽度都留给歌词。这里仍然显式写一次 maxWidth: .infinity 把"歌词吃掉剩余宽度"
            // 这个意图钉死,不依赖它在 stack 里的隐式伸缩行为。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if reportsWidth { LineLayoutWidthReporter() }
            }
            if playback.lyricRowArtworkPosition == .right { lyricRowArtwork }
        }
        .padding(.horizontal, NotchMetrics.expandedContentInset)
        // 封面在场性的变化必须是瞬时的,不能落进任何补间,否则歌词会被封面挡住一截。
        //
        // 机制:封面是这个 HStack 的**条件兄弟**。它从不在场变在场时,SwiftUI 把它当结构性
        // 插入 —— 新插入的视图**一帧就落在终态位置**;而歌词那一侧的 frame(以及跟着 frame
        // 走的跑马灯裁剪边界)是被**动画平滑收缩**的,要花整条弹簧
        // 才从"没有封面时"的宽度收到"有封面时"的宽度。这段时间里歌词被裁到更靠右的旧边界,
        // 那一截字正好画在已经就位的封面**底下** —— HStack 里靠后的兄弟盖在前面的上面。
        //
        // 独立最小复现(SwiftUI,同构的 HStack + GeometryReader/.clipped 弹性子 + 32pt 定宽
        // 兄弟,弹簧刻意放慢到 3s 便于逐帧抓):封面到位那一帧文字右边界仍停在旧位置(623px),
        // 要 4 帧才收到终态 603px,90 帧里 25 帧文字被压在封面底下;加上这一行 .animation(nil,)
        // 之后同样 90 帧 **0** 帧遮挡,四次插入全部一帧到位。
        //
        // 触发窗口:必须"封面在场性变化"和某条活动动画落进**同一次** SwiftUI 更新 —— 把两者
        // 错开 300ms 复现同样是 0/90。现实里够得着这个窗口的有两处:
        // NotchWindowRoot 挂在整棵子树上的三条 .animation(cardAnimation, value:)
        // (cardWidth/cardHeight/isCollapsed),以及 NotchTransientHost 自己那条 0.18s。
        // 而封面确实会真的离场再回来:换歌后取图迟迟不来时 LocalPlaybackSource 的
        // scheduleArtworkStaleTimeout 会在 3s 后把 artworkData 清成 nil,重试成功再填回来。
        //
        // 为什么不用别的修法:给封面留永久占位能根治,但那要一直吃掉 42pt 歌词宽度,与
        // artworkThumbnail 上面那段"没有封面就连位置一起不占"的决定直接冲突;给它加
        // .transition 淡入也不行 —— 淡入到不透明的过程中 clip 边界照旧滞后,只是把遮挡
        // 从"实心"变成"半透明"。封面出现/消失本来就是一次宽度**跳变**,补间只会制造不同步。
        //
        // value 必须是"封面这一刻实际占不占位"这个合成布尔(开关 && 有数据),不能只看数据:开关关着时数据端的有无变化不该触发
        // 任何布局动作,只 key 数据端的话,开关重新打开的那一刻可能撞上活动动画的同一次更新窗口。
        .animation(nil, value: !lyricRowArtworkPresent)
    }

    /// 广告插播时歌词那一格的内容:
    ///
    ///     广告中 · 还剩 0:21                                 [⏭ 跳过广告]
    ///
    /// * 左边是这一态唯一有信息量的东西:还要多久结束。倒计时按 1Hz 走(`adCountdown`),跟耳朵里的时间模块同一套调度
    ///   (`NotchTimeFormat.clockSchedule`,相位对齐到曲目位置的整秒,跟正下方进度条同源同相),暂停时冻结、时长未知时不编数字。
    ///   这一行不带图标:左耳那枚喇叭在广告期间恒显示,同一张卡上再画一枚是重复。字号 / 七成不透明 / 投影跟 `mainLyricLine` 里
    ///   那个「广告中」分支逐字相同:稳态(不展开)时这一行也是这一格,用户看到的是同一句话变成了带倒计时的版本,不是一套新版式。
    /// * 右边那颗「跳过广告」只在 `playback.canSkipAd` 时出现:广告中且这是 YT Music 网页广告(`YouTubeMusicAdSkipper.isYouTubeMusicAd`,
    ///   探针强信号)且页面此刻真的放出了跳过键(`adSkipAvailable`,不可跳过的广告上不挂键)。Spotify 的广告没有可点的东西,不给键。
    ///   点了去点页面自己的跳过按钮(`NotchPlayback.skipAd`,不做拖到结尾那种绕过),结果用瞬态横幅回报。
    /// * 头部在广告期间只剩快捷操作那排键(`trackInfoShowsTrackFields`),状态文字只在这一行出现。广告期间全 App 四个封面位都让位
    ///   给同一枚 `megaphone.fill`(`adBreakArtworkTile` 等,清单见 05 章「广告态」⑦);这一列自己不画封面。
    private var adStatusColumn: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                // 这一格**不画喇叭**:广告期间左耳那枚(`adBreakEarIcon`)是无条件画的
                // (`isAdBreakNow` 那条分支不看配置、不看原本有没有内容),两枚并排在同一张卡上
                // 就是把同一件事说了两遍。留文字这一路 —— 它带着计数和倒计时,是这一态唯一有信息量的东西。
                //
                // 字体跟歌词主行同一份派生值:这一格就是歌词那一格换了内容,用户换了字体后它不该
                // 突然变回系统字体。倒计时那截同字号、细一档(`mainDetailFont`),保住 semibold / medium 的主次。
                Text(L10n.t("广告中"))
                    .font(playback.mainFont)
                adSlotText
                    .font(playback.mainDetailFont)
                adCountdown
                    .font(playback.mainDetailFont)
            }
            .foregroundStyle(accentOrWhite.opacity(0.7))
            .notchTextShadow()
            .lineLimit(1)
            Spacer(minLength: 0)
            if playback.canSkipAd {
                NotchPillButton(systemName: "forward.end.fill", title: L10n.t("跳过广告"), tint: accentOrWhite) {
                    playback.skipAd()
                }
                // 正在跑(点 + 复核)时压淡、不接第二下,理由见 `NotchPlayback.skipAdInFlight`。
                .opacity(playback.skipAdInFlight ? 0.45 : 1)
                .disabled(playback.skipAdInFlight)
            }
        }
    }

    /// 「· 还剩 0:21」。来源见 `playback.adCountdown`:广告本身就是一首曲目的(Spotify、YouTube Music 网页版)按曲目算,
    /// 位置口径同 `clockText`(锚点外推 ?? 暂停冻结位置);Kaset 的广告跟接下来那首歌共用身份,曲目时长是那首歌的,按广告
    /// 自己的那只表(`AdBreakClock`,内嵌网页报的时长与进度)算;拿不到时长就整个不画(不为拿不到的数据编占位)。
    /// TimelineView 只在这一层可见(层内读的 `notchCardLayerActive`)时才排表 —— 收起态 / 编辑台预览都不该有一张每秒空转的表
    /// (理由同 `earContent` 时间模块那条)。采样用 `Date()` 而不是 `context.date`,理由见 `earContent` 头注第 ③ 条。
    private var adCountdown: some View {
        NotchLayerActiveReader { active in
            switch playback.adCountdown {
            case .own(let clock):
                // 暂停时停在取样那一刻:这只表纯按墙钟外推、每次轮询重建,暂停着照推的话每秒减 1、每次轮询又跳回去。
                if !playback.isPlayingNow {
                    Text(adRemainingText(total: clock.durationMs, position: clock.positionMs))
                } else if active {
                    TimelineView(.periodic(from: clock.capturedAt.addingTimeInterval(-NotchClockPhase.msSinceBoundary(
                        positionMs: Double(clock.positionMs), countdownFromMs: clock.durationMs) / 1000), by: 1)) { _ in
                        Text(adRemainingText(total: clock.durationMs, position: clock.positionMs(now: Date())))
                    }
                } else {
                    Text(adRemainingText(total: clock.durationMs, position: clock.positionMs(now: Date())))
                }
            case .unknown:
                EmptyView()
            case .track:
                if let total = playback.currentDurationMs, total > 0 {
                    if let anchor = playback.anchor, active {
                        TimelineView(NotchTimeFormat.clockSchedule(for: anchor, countdownFromMs: total)) { _ in
                            Text(adRemainingText(total: total, position: anchor.extrapolatedPositionMs(now: Date())))
                        }
                    } else if let position = playback.anchor?.extrapolatedPositionMs(now: Date()) ?? playback.pausedPositionMs {
                        Text(adRemainingText(total: total, position: position))
                    }
                }
            }
        }
    }

    private func adRemainingText(total: Int, position: Int) -> String {
        "· " + String(format: L10n.t("还剩 %@"), NotchTimeFormat.mmss(ms: max(0, total - position)))
    }

    /// 「这是插播里的第几条」,排在「广告中」和倒计时之间,连起来读是「广告中 · 1/2 · 还剩 0:20」。
    ///
    /// 字号跟倒计时同一档(`mainDetailFont`,主行同字号细一档),两段都是"广告中"这句话的补充说明,不该有各自的字重。
    ///
    /// 写成 `1/2` 而不是「还剩 1 条」:它跟 YouTube 自己徽章上的写法逐字一致,用户在页面上看到什么、在灵动岛上就看到什么,不用在
    /// 心里做减法;而且纯数字不需要新增本地化文案。
    ///
    /// 拿不到就整段不画:只有 YT Music 网页广告给得出这个数,Spotify 恒 nil,YT Music 英文界面(`Ad 1 of 2`)也抓不到。宁可少一段,
    /// 不编。
    @ViewBuilder
    private var adSlotText: some View {
        if let slot = playback.currentAdSlot {
            Text(verbatim: "· \(slot.index)/\(slot.total)")
        }
    }

    /// 歌词这一格:副行关着就是改动前那一行跑马灯(逐像素不变);副行开着(
    /// 方案二)就在它下面再放一行 11pt 的副行,两行 + 3pt 间距 = 31pt,竖直居中塞进
    /// 44pt 的行里,**行高不变** —— 这是选方案二而不是叠行方案的全部理由:不动 `cardHeight`、
    /// 编辑台舞台常量、出场动画这片高度体系(05 章决策 22)。
    /// 主行那一格的高度随「字号」走(`playback.mainLineHeight`,11…17pt → 13…19pt),两行最多 35pt,
    /// 仍在 44 里、上下各余 ≥ 4pt —— 字号范围就是按这条倒推的,Core 有 selftest 钉着。
    @ViewBuilder
    private var lyricTextColumn: some View {
        if playback.secondaryLine.showsSecondaryRow {
            VStack(alignment: .leading, spacing: NotchLyricRowMetrics.lineSpacing) {
                mainLyricLine
                    .frame(height: playback.mainLineHeight)
                secondaryLyricLine
                    .frame(height: NotchLyricRowMetrics.secondaryLineHeight)
            }
        } else {
            mainLyricLine
                .offset(y: -NotchMetrics.singleLineOpticalLift)
        }
    }

    /// 主行本体,从 `lyricRowContent` 拆出来给副行让位。用这一行纯文本(不含逐字填色进度)当跑马灯的 id:换到新的一句才重新
    /// 测量/重新开始滚动,同一句内部逐字变色的高频刷新不打断正在进行的滚动。
    /// restingAlignment 与 edgeFadeWidth 的理由见 `lyricRowContent` 里紧挨着 `lyricTextColumn` 的那段注释。
    ///
    /// 没有逐字时间的行走图层跑马灯(`LayerMarquee`),只按窗口可见性停、不按所在那一层停:稳态 / 展开两份靠透明度轮流显示,
    /// 按层停会让长句在悬停展开时跳回开头;藏着那份的图层动画不占主线程。它的内容不继承这里的环境,字体要在里面再写一次(05 章决策 99)。
    private var mainLyricLine: some View {
        NotchLayerActiveReader { layerActive in
            if let words = playback.displayLine?.words, !words.isEmpty {
                layerKaraokeLine(words: words, layerActive: layerActive)
            } else {
                LayerMarquee(id: playback.displayLine?.plainText ?? "",
                             edgeFadeWidth: NotchMetrics.lyricEdgeFadeWidth,
                             restingAlignment: playback.mainLyricAlignment,
                             loops: false,
                             isActive: surfaceVisible) {
                    lyricContent(layerActive: layerActive)
                        .font(playback.mainFont)
                }
            }
        }
        // 字体 / 粗细 / 字号三件由设置决定,默认是 13pt semibold。里面那几个状态占位
        // 文字(纯音乐 / 暂无歌词 / …)和逐字染色的每个字都从这里继承字体,不各自再写。
        .font(playback.mainFont)
    }

    /// 有逐字时间轴的主行:走 AppKit 图层(`OverlayScrollingLyricRow`,悬浮歌词滚动模式那一套),
    /// 整行画成长图、逐字填色与跟唱滚动各一条 CAKeyframeAnimation,装好之后主线程不再按帧参与。
    ///
    /// 不用 `MarqueeText` 包 30Hz `TimelineView`、每个字一个渐变 `Text`:灵动岛窗口里任何一个逐帧子视图都会带着整窗每拍布局 +
    /// 提交一遍,那样这条逐字填色是灵动岛开销的大头。
    ///
    /// 跟 SwiftUI 版逐项对齐的:字体(`mainNSFont` = `mainFont` 的 AppKit 版)、已唱 = `accentOrWhite`、未唱 = 它的
    /// `WordKaraokeGradient.dimOpacity`、整行阴影(黑 0.45 / 半径 2 / 下移 1,同 `lyricContent` 里那条 `.compositingGroup().shadow`)、
    /// 溢出时尾部渐隐(`lyricEdgeFadeWidth`)、装得下时按「对齐方式」静置、停表判据(同 `lyricFollow`)。不同的一处:已唱 / 未唱的
    /// 交界是硬边(悬浮歌词滚动模式、菜单栏同款),没有 SwiftUI 版那条 `wordEdgeSoftenBand` 软过渡。
    private func layerKaraokeLine(words: [SyncedLyricWord], layerActive: Bool) -> some View {
        let fg = NSColor(accentOrWhite)
        let side: LyricDuet.Side
        switch playback.mainLyricAlignment.horizontal {
        case .leading: side = .leading
        case .trailing: side = .trailing
        default: side = .center
        }
        return OverlayScrollingLyricRow(
            spec: .init(
                lineKey: playback.displayLine?.plainText ?? "",
                words: words,
                groups: nil,
                font: playback.mainNSFont,
                romaFont: playback.mainNSFont,
                baseColor: fg.withAlphaComponent(fg.alphaComponent * WordKaraokeGradient.dimOpacity),
                fillColor: fg,
                romaBaseColor: fg,
                romaFillColor: fg,
                strokeColor: nil,
                alignment: side,
                paused: !playback.lyricsClockRunning || playback.currentLineFillSettled || !layerActive,
                shadow: .init(color: NSColor.black.withAlphaComponent(0.45), radius: 2, offsetY: 1),
                edgeFadeWidth: NotchMetrics.lyricEdgeFadeWidth,
                timingEpoch: LyricsTimingEpoch.of(anchor: playback.anchor, pausedPositionMs: playback.pausedPositionMs,
                                                  offsetMs: playback.lyricsOffsetMs),
                rate: playback.playbackRate),
            nowMs: Self.lyricsNowMs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: playback.displayLine?.plainText ?? ""))
    }

    /// 歌词读的播放位置,图层行、间奏三点、音浪振幅共用这一份:锚点外推 ?? 暂停冻结位置 ?? `fallbackMs`,再叠歌词时间轴偏移。
    /// 直读协调器、不经窄代理订阅:锚点重建会打醒整卡 body,而这里只要调用那一刻的快照。
    private static func lyricsPositionMs(at date: Date, fallbackMs: Int = 0) -> Int {
        let coordinator = PlaybackCoordinator.shared
        return (coordinator.anchor?.extrapolatedPositionMs(now: date) ?? coordinator.pausedPositionMs ?? fallbackMs)
            + coordinator.currentLyricsOffsetMs
    }

    private static func lyricsNowMs() -> Int { lyricsPositionMs(at: Date()) }

    /// 副行:下一句 / 当前句译文 / 当前句罗马音(由 `NotchPlayback.secondaryText` 按设置选好)。
    /// **不滚动**:装不下就尾部省略号 —— 主行已经是一条跑马灯,两条同时动太乱;而且它是"提前看一眼"
    /// 的辅助信息,不是要逐字跟唱的正文。对齐跟主行吃同一个「对齐方式」设置(展开态那行「下一句」
    /// 预览也是,selftest 钉着 `swiftUIAlignment` 的接线处数)。取不到内容时留空不缩高。
    /// 三档透明度沿用悬浮歌词那三行的口径(下一句那边 40%,这里 45% —— 11pt 在深底上再淡就看不清了;
    /// 译文 75%、罗马音 60% 照抄)。
    private var secondaryLyricLine: some View {
        Text(playback.secondaryText ?? "")
            // 固定 11pt、比主行细一档,只跟主行的字体族与粗细(理由见 NotchLyricRowMetrics.secondaryFontSize)。
            .font(playback.secondaryFont)
            .lyricTypesetting(playback.secondaryText, translation: playback.secondaryLine == .translation)
            .foregroundStyle(accentOrWhite.opacity(secondaryLineOpacity))
            .notchTextShadow()
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: playback.secondaryLyricAlignment)
    }

    private var secondaryLineOpacity: Double {
        switch playback.secondaryLine {
        case .off, .nextLine: return 0.45
        case .translation: return 0.75
        case .romanization: return 0.6
        }
    }

    /// 歌词行末尾(或开头)那枚封面缩略图,就有、到之间
    /// 固定显示,现在受 `notchLyricRowShowsArtwork` 开关控制。没有封面数据(没曲目/取图
    /// 失败)或开关关着时都不画占位方块,理由见 `artworkThumbnail` 上面那段。
    @ViewBuilder
    private var lyricRowArtwork: some View {
        if playback.lyricRowShowsArtwork {
            if controller.isAdBreakNow {
                // 广告期间这一格换成广告标识:播放器在广告时给的图是广告物料的缩略图,不是"这一刻在听什么"的封面,四个封面位统一让位
                // 给同一枚喇叭。开关(`notchLyricRowShowsArtwork`)仍然管这一格在不在:关了就还是不画,广告不该把用户关掉的东西请回来。
                adBreakArtworkTile(side: Self.artworkSide(rowHeight: controller.lyricRowHeight))
            } else if let image = displayedArtworkImage {
                artworkThumbnail(image)
            }
        }
    }

    /// 广告期间顶替封面的那枚方块。外框跟 `artworkThumbnail` 逐项对齐(同一个
    /// 圆角、同一道 0.5pt 白描边、同一层投影),这样广告开始/结束时这一格只是内容换了、
    /// 几何一点不动;里面是跟状态行、跟左耳同一枚 `megaphone.fill`。
    /// 不接点击:`artworkThumbnail` 那枚点了会打开歌词窗口,而广告没有歌词可看。
    private func adBreakArtworkTile(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous)
            .fill(.white.opacity(0.10))
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: "megaphone.fill")
                    .font(.system(size: side * 0.44, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .accessibilityHidden(true)
    }

    /// 上面那枚封面此刻是不是真的占着一个位置——给 `.animation(nil, value:)` 当判据用,
    /// 见那一行的注释。
    private var lyricRowArtworkPresent: Bool {
        // 广告期间那枚替代方块同样占着这个位置(见 lyricRowArtwork),判据要跟着算上,
        // 否则 `.animation(nil, value:)` 会以为这一格是空的、放行一次不该有的布局动画。
        playback.lyricRowShowsArtwork
            && (controller.isAdBreakNow
                || displayedArtworkImage != nil)
    }

    private func lyricContent(layerActive: Bool) -> some View {
        Group {
            // 有逐字时间轴的行不走这里:`mainLyricLine` 先分流到图层行(`layerKaraokeLine`)。
            if playback.isCurrentTrackAdBreak {
                // 同 LyricsOverlayView.mainLine 的区分,必须排在"还在搜索中"分支前面,
                // 见 PlaybackCoordinator.isCurrentTrackAdBreak 定义处的注释。
                // 广告态在 `lyricRowContent` 那一层就分流到 `adStatusColumn` 了,这个分支
                // 正常到不了;留着当兜底(顺序契约不变),别删。
                Text(L10n.t("广告中"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else if playback.isRadioTalkBreak {
                // 电台口白:这首歌已经放完、台里在说话。必须排在"还在搜索中"之前,
                // 理由同上面那条广告分支 —— 口白期间元数据还停在上一首,不拦就会显示成
                // 「搜索歌词中…」。收歌词的判定在 LocalPlaybackSource.radioTrackFinished。
                Text(L10n.t("口白"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else if playback.isCurrentTrackInstrumental {
                // 同 LyricsOverlayView.mainLine 的区分,必须排在"还在搜索中"分支前面,
                // 见 PlaybackCoordinator.isCurrentTrackInstrumental 定义处的注释。
                Text(L10n.t("纯音乐"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else if playback.currentTrackHasNoLyrics {
                // 搜完了、确实一句都没有,同 LyricsOverlayView.mainLine 的同名分支——
                // 必须排在下面那个"搜索歌词中…"前面。
                Text(playback.hasPlainLyrics ? L10n.t("仅有纯文本，无时间戳") : L10n.t("暂无歌词"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else if playback.engineNetworkDown && !playback.hasLyricsContent {
                // 顺序理由同 LyricsOverlayView.mainLine 里那段:必须排在"搜索歌词中…"
                // 之前、"暂无歌词"之后。
                Text(L10n.t("网络连接失败"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else if playback.isPlayingNow && !playback.hasLyricsContent {
                // 同 LyricsOverlayView.mainLine 的区分:currentLine==nil 可能是"还没解析
                // 出这首歌的歌词"(引擎后台搜索中,见 PlaybackCoordinator.hasLyricsContent 注释),
                // 不能跟"这首歌真没歌词/正在间奏"共用同一个♪占位符。
                Text(L10n.t("搜索歌词中…"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else {
                // 前奏/间奏占位符:跟悬浮歌词一样用三点动画(LyricsGapDotsView)。displayLine 为 nil 的成因这里天然合流:
                // 单行面的长间奏中段(唱完了、下一句还早)、"这一刻不在任何一句上"、
                // 以及副行开着时的前奏和够格的间奏(见 LyricSecondaryLine.currentLine(_:inMarkedInterlude:))。
                // 但压根没有曲目时它什么都不代表,留白。上面那一长串 else-if 已经把
                // 广告/纯音乐/无歌词/断网/搜索中都各自接走了,能落到这里的空态只剩"没有曲目"。
                if let plainText = playback.displayLine?.plainText {
                    Text(plainText)
                        .foregroundStyle(accentOrWhite)
                        .lyricTypesetting(plainText)
                        .notchTextShadow()
                } else if !isIdleNoTrack, let raw = playback.rawGapWindow {
                    let window = playback.secondaryLine.gapDotsWindow(raw, compactPlaceholder: playback.compactShowsPlaceholder)
                    // 尺寸按字号等比,别写死:歌词窗口字号至少 22(见 lyricFontSize),它那边 8pt 只相当于 0.36 倍字号;灵动岛主行只有
                    // 13pt(范围 11…17),同样画 8pt 就是 0.62 倍,呼吸到最大(×1.28)时逼近 10pt、在 15pt 的行高里比歌词本身还抢眼。
                    //
                    // 比例取 0.40 而不是歌词窗口 / 悬浮歌词那边的 0.32:小字号要补偿。那两处字号 22~38,0.32 出来是 7~12pt;灵动岛 13pt
                    // 照搬只剩 4.2pt,在 15pt 行高里弱到像三粒灰尘。0.40 = 5.2pt,还看得出是三颗会呼吸的圆点。spacing 跟着取 0.375,
                    // 维持两处一贯的「间距≈0.94 倍点径」手感。
                    LyricsGapDotsView(
                        startMs: window.startMs, endMs: window.endMs,
                        dotSize: playback.mainFontSize * 0.40,
                        spacing: playback.mainFontSize * 0.375,
                        color: accentOrWhite,
                        isPlaying: playback.lyricsClockRunning, isVisible: layerActive,
                        reduceMotion: reduceMotion,
                        timingEpoch: LyricsTimingEpoch.of(anchor: playback.anchor, pausedPositionMs: playback.pausedPositionMs,
                                                          offsetMs: playback.lyricsOffsetMs),
                        rate: playback.playbackRate,
                        // 同这一格其它占位文字的 `notchTextShadow()`;
                        // 三点现在画在原生图层上(见 LyricsGapDotsView 头注),SwiftUI 的 .shadow 罩不到,由图层自己投。
                        shadow: .init(color: NSColor.black.withAlphaComponent(0.45), radius: 2, offsetY: 1)
                    ) { date in
                        Self.lyricsPositionMs(at: date, fallbackMs: window.startMs)
                    }
                } else {
                    Text(isIdleNoTrack ? "" : "♪")
                        .foregroundStyle(accentOrWhite)
                        .notchTextShadow()
                }
            }
        }
        .lineLimit(1)
    }

    /// 灵动岛音浪的振幅:这一刻有没有字正在唱。
    ///
    /// 输入全部直读 `PlaybackCoordinator.shared`,**不经窄代理订阅** —— 跟同文件里逐字填色
    /// 那个 TimelineView 闭包同一个取舍(见 lyricRow 里 currentMs 那段注释):锚点重建会打醒
    /// 整卡 body,而这里只需要"调用那一刻的快照"。
    ///
    /// 形状由 `VocalEnvelope`(LyrimuseCore,selftest 覆盖)决定:字内稳态 1 + 起音脉冲、字间从 1
    /// 指数泄放到 0.6、没有逐字 1。取舍见 VocalEnvelope 头注(字内稳态刻意不动:按已唱比例插值反而更不像人声)。
    /// 这里只剩"读协调器快照、算位置、交给 Core":XxxxView 里不放数学,是仓库的分层边界。
    static func vocalAmplitude(at date: Date) -> Double {
        let coordinator = PlaybackCoordinator.shared
        guard let words = coordinator.currentLine?.words, !words.isEmpty else {
            return VocalEnvelope.idleAmplitude
        }
        // 位置口径必须跟逐字填色一致,否则条子跟高亮的字对不上。
        return VocalEnvelope.amplitude(atMs: lyricsPositionMs(at: date), words: words)
    }
}
