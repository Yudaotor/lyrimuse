import AppKit
import LyrimuseCore
import SwiftUI

// 「外观」页里**菜单栏**那一段钉在页顶的预览。
//
// (2026-08-31 之前这个文件里还有灵动岛那一段的预览 `NotchPreviewBar` 和它的替身 chrome
//  `NotchPreviewChrome`。灵动岛改成编辑台范式之后,预览从页顶钉条挪进了可滚动内容区并且
//  变得可交互,两样一起搬去 NotchEditorStage.swift —— 钉条那一层收不到点击事件,凡是
//  "能动手改"的预览都只能待在内容区,理由见 SettingsView 里那段 2026-08-16 的复现记录。
//  三段预览栏共用的 `SectionPreviewMetrics` 留在这里:菜单栏那条还在用,悬浮歌词/灵动岛
//  两块编辑台也拿它的 caption 度量对齐疏密。)
//
// 桌面悬浮歌词那一段早就有预览了,菜单栏这一段一度没有 —— 而它同样面临"改完的效果只出现
// 在别处、而那个别处此刻多半看不见"的问题:菜单栏歌词只有一行字,还得等有歌在播。
//
// ⚠️ 刻意**不**复用悬浮歌词那条预览。那一条画的是悬浮歌词的字体/颜色/描边/宽度,而菜单栏
// **根本不读那些设置**(它就是系统菜单栏字)。拿同一条预览挂在这一段上,等于暗示那些设置
// 对它也有效 —— 那是错的。每一段的预览只反映这一段自己那几项设置。
//
// 几条教训(跟悬浮歌词那条钉条同源):高度固定不跟内容变(挂在页顶,高度一动整页就跳)、
// 只订阅要用的那一两个 @Published(别 ObservedObject 整个 PlaybackCoordinator)、自带
// 不透明底色(头部区域盖不到 ScrollView 的 background)。
//
// MARK: 全仓预览的一条共同原则 —— 不为示例句编造进度
//
// **预览只画真实数据能支撑的东西;演示效果不值得用假数据换。**没在播放(或这首歌没有逐字
// 时间轴)时,预览画的是整行的最终颜色,**不**编一份不存在的播放进度去演示逐字染色 ——
// 假数据会让预览在"没放歌"这个大多数场景里显得像在骗人,而预览存在的全部意义就是所见即所得。
// 真的在放歌、这一句确实有逐字数据时,给的是**完全真实**的数据,不是演示。
//
// (这条原来记在悬浮歌词那条钉条 `OverlayPreviewBar` 的头注里。钉条 2026-08-31 随死代码
//  一起删了 —— 悬浮歌词/灵动岛两段都改成了编辑台,它没有任何实例化点 —— 原则本身对这个文件
//  里的菜单栏预览、以及两块编辑台仍然成立,所以搬到这里。别处引用这条时指这里。)

// 三段预览栏共用的外层度量。
//
// 高度按**当前段自己的卡**算,不再三段统一取最大(2026-08-19 改回)。统一高度是
// 2026-08-15 为"点来点去整个框架一直在动"定的,但它的代价是矮预览的段常驻一大块留白,
// 同日灵动岛展开区加高(40→76)后留白涨到几十 pt,用户报"这块太空了,下方内容空间大点"。
// 两个诉求的调和:高度跟段走 + 换段的高度变化交给动画滑过去(见 SettingsView 挂在
// 预览 switch 上的 .animation(value: sectionRaw)),不再是硬跳。
@MainActor
enum SectionPreviewMetrics {
    static let topPadding: CGFloat = 14
    static let bottomPadding: CGFloat = 10
    static let captionSpacing: CGFloat = 6
    /// caption 那一行(.font(.caption))的行高经验值。
    static let captionHeight: CGFloat = 15

    /// 卡片之外的固定开销。
    private static var chromeHeight: CGFloat {
        topPadding + captionSpacing + captionHeight + bottomPadding
    }

    /// 这一段预览栏的总高:固定开销 + 这一段自己的卡高。
    static func barHeight(cardHeight: CGFloat) -> CGFloat {
        chromeHeight + cardHeight
    }
}

/// 菜单栏那一段的预览。
///
/// 2026-08-16 重做:以前这里是"仿"一条菜单栏 —— 圆角条 + 一个现实里根本不存在的音符
/// 图标 + `.system(size: 13)` 的文字,而且滚动只演开头那一帧(静止的)。跟用户真正看到的
/// 东西差得远(用户原话:预览里要真实模拟实际的菜单栏)。
///
/// 现在这条预览**就是菜单栏本体那套代码**:
///   * 要不要滚、滚多快、首尾停多久 —— 走 MenuBarMarqueeRenderer.presentation,跟
///     MenuBarStatusItem 同一个函数,不可能漂;
///   * 需要滚的句子直接挂 MenuBarScrollingLabel(真窗口里那个 layer-backed NSView),
///     同一张长图、同一条 CAKeyframeAnimation,**真的会滚**;
///   * 装得下的句子用 NSFont.menuBarFont(系统菜单栏字体本体),不是 13pt 系统字。
///
/// 逐字染色(2026-08-22 补齐):正在播放且当前句有逐字(YRC)数据时,染色跟真菜单栏一样
/// 走 MenuBarScrollingLabel 的填色图层,时钟公式也是 MenuBarStatusItem.syncKaraokeClock
/// 那一条(anchor 外推/暂停位置 + 时间轴偏移)——不是另开一套。没在播放时的示例句刻意
/// 不染:那是编不出真实时间轴的场景,跟 OverlayPreviewBar 不为示例句假装播放进度是同一个
/// 原则(见该文件头注)。
///
/// 外框改成一小段仿菜单栏:.bar 材质(就是菜单栏/工具栏那层材质)、内容靠右,右边跟着
/// 几个常见的状态栏图标和真实时钟 —— 这些只是给"占多宽"一个参照物,让宽度滑杆的效果
/// 看得出来。歌词那一格占多宽跟真菜单栏上一模一样 —— 固定模式下恒等于「显示宽度」、
// 长短句来回切都不伸缩,自适应模式下短句跟着文字缩短(见 MenuBarLyricsWidthMode)。
@MainActor
struct MenuBarPreviewBar: View {
    /// 在仿菜单栏那条下面**预留一条通道**给宽度调整条(2026-09-01,用户第三次点名要
    /// "和之前两个页面一样加到这个预览框里面去")。默认 false —— 这个开关只为编辑台那个
    /// 宿主存在,别的地方拿这条预览去用时形状不变。
    ///
    /// 做法照 `OverlayEditorStage`:那块舞台在卡片下面留一条 `widthBarLaneHeight`(44pt)
    /// 高的通道,壁纸铺进通道里,调整条浮在上面。这里通道矮一些(28pt)——胶囊本身就比
    /// 那边的窄,而这条预览总高只有 69pt,留 44pt 会让预览条本身显得很挤。
    var reservesWidthLane = false

    /// 见 reservesWidthLane。
    static let widthLaneHeight: CGFloat = 28

    @ObservedObject private var settings = AppSettings.shared
    @State private var line: SyncedLyricLine?
    // 逐字染色对表用的播放时钟快照(2026-08-22 加)。这几个跟 line 一样是
    // PlaybackCoordinator 的镜像,靠各自的 onReceive 保持新鲜 —— 不新开一份状态管理,
    // 只是把 MenuBarStatusItem.syncKaraokeClock 那套对表逻辑搬到宿主 body 里重算一遍。
    @State private var anchor: ProgressAnchor?
    @State private var pausedPositionMs: Int?
    @State private var lyricsOffsetMs = 0
    @State private var isPlayingNow = false

    private var fullText: String {
        if let text = line?.plainText, !text.isEmpty { return text }
        return L10n.t("这里是一句歌词示例")
    }

    /// 当前句的逐字填色路径。跟 MenuBarStatusItem.karaokeFillPath 同一份判定:
    /// 只在真的在播放、这句确实有逐字(YRC)数据、且没跟标签文本代际错位时才染。
    ///
    /// ⚠️ 没在播放时的示例句("这里是一句歌词示例")**刻意不**编一份假时间轴去演示染色 ——
    /// 见本文件头注「不为示例句编造进度」那一段(全仓预览共用的原则)。真的在放歌且这句
    /// 有逐字数据时,这里给的是**完全真实**的数据,不是演示。
    private var karaokeFillPath: [MenuBarMarquee.KaraokeFillPoint]? {
        guard settings.menuBarLyricsKaraoke,
              let line, let words = line.words, !words.isEmpty,
              line.plainText == fullText else { return nil }
        let path = MenuBarMarquee.karaokeFillPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words))
        return path.isEmpty ? nil : path
    }

    /// 位置公式跟 MenuBarStatusItem.syncKaraokeClock 完全同一条:anchor 外推 ??
    /// 暂停位置,再加歌词时间轴偏移校准。
    private var karaokePositionMs: Int? {
        let raw = anchor?.extrapolatedPositionMs(now: Date()) ?? pausedPositionMs
        return raw.map { $0 + lyricsOffsetMs }
    }

    private var presentation: MenuBarMarqueeRenderer.Presentation {
        MenuBarMarqueeRenderer.presentation(
            for: fullText, windowWidth: settings.menuBarLyricsWidth,
            // 演的是示例句(没在播放)时没有"这句会显示多久"可言,给 nil 走固定速度。
            //
            // ⚠️ 这个值是在 **body 求值时**现读的,不是在上面那个 onReceive 里存下来的。
            // $currentLine 是 @Published,回调跑在 willSet 时机 —— 那一刻
            // currentLineIndex/allLines 还可能是旧值(这个项目已经为这个时机踩过两次坑)。
            // 而 body 求值发生在状态落定之后,读到的必然是同一句歌词对应的那份数据。
            dwellSeconds: line == nil ? nil : PlaybackCoordinator.shared.currentLineDwellSeconds,
            // 预览镜像的是 currentLine(**正在唱**的那一句),不是菜单栏本体用的 compactLine
            // (它会提前亮出下一句)—— 所以这里的句子按定义总是已经开唱了,提前量恒为 0。
            leadInSeconds: 0,
            widthMode: settings.menuBarLyricsWidthMode)
    }

    private static func willScroll(_ p: MenuBarMarqueeRenderer.Presentation) -> Bool {
        if case .fixed(_, _, let pacing) = p { return pacing != nil }
        return false
    }

    /// 预览下面那行说明。
    ///
    /// ⚠️ 2026-09-01 砍掉了宽度和模式(原来是「预览 · 固定宽度 150pt」/「预览 · 自适应,
    /// 最宽 150pt」)。同一件事这时候已经被说了**三遍**:虚线边界直接把那一格画出来了
    /// (见 slotEdgeOutline —— 固定宽度时右边空一块、自适应时贴着文字收紧,模式也在里面),
    /// 具体数值在编辑台「最大宽度」那条滑杆右侧,这行字是第三遍。用户原话是把那半句框起来
    /// 「去掉红框文案」。
    ///
    /// **留着的是滚动那一句** —— 它是这行字唯一说得出、而画面说不出的事:那一格的宽度看得见,
    /// "这句放不下、会横向滚动"看不见。别把"会滚动"说成"已截断",超宽时到底是滚还是截由
    /// 宽度决定,说反了正是让人觉得这个功能"怪怪的"的原因之一。
    ///
    /// presentation 由调用方(body)求值一次传进来 —— 它看着像存量属性,实际每次访问都做
    /// 一趟 NSString 测宽(2026-08-20 性能审计,原来 body 一轮里被求值 2-3 次)。
    private func previewCaption(_ p: MenuBarMarqueeRenderer.Presentation) -> String {
        Self.willScroll(p) ? L10n.t("预览 · 本句会横向滚动") : L10n.t("预览")
    }

    /// 仿菜单栏那一条的高度。真菜单栏内容区约 22pt,这里取整到 24 留一点呼吸。
    static var cardHeight: CGFloat { 24 }

    var body: some View {
        // presentation 一轮 body 只求值一次(caption 和歌词格共用),见 previewCaption 注释。
        let p = presentation
        return VStack(spacing: 6) {
            menuBarStrip(p)
            // 别把"会滚动"说成"已截断" —— 超宽时到底是滚还是截,由宽度决定,说反了正是
            // 让人觉得这个功能"怪怪的"的原因之一。
            Text(previewCaption(p))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            // 预留通道时把 caption 顶在菜单栏条正下方,剩下的空间留给浮在下面的胶囊 ——
            // 不加这个 Spacer 的话 VStack 会把 caption 均摊到通道中间、正好跟胶囊叠上。
            if reservesWidthLane { Spacer(minLength: 0) }
        }
        .padding(.top, SectionPreviewMetrics.topPadding)
        .padding(.bottom, SectionPreviewMetrics.bottomPadding)
        // 三条预览栏共用一个高度(见 SectionPreviewMetrics)。这一条内容最少,多出来的
        // 空间留白 —— 留白远好过让下面整页跟着跳。
        .frame(height: SectionPreviewMetrics.barHeight(cardHeight: Self.cardHeight)
               + (reservesWidthLane ? Self.widthLaneHeight : 0))
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(PlaybackCoordinator.shared.$currentLine.removeDuplicates()) { line = $0 }
        // 逐字染色对表通道,跟 MenuBarStatusItem.syncKaraokeClock 订阅的是同四个源
        // (锚点/暂停位置/时间轴偏移/播放态),搬到这里重算是因为预览没有自己的
        // MenuBarStatusItem 实例可以复用那份订阅。
        .onReceive(PlaybackCoordinator.shared.$anchor) { anchor = $0 }
        .onReceive(PlaybackCoordinator.shared.$pausedPositionMs) { pausedPositionMs = $0 }
        .onReceive(PlaybackCoordinator.shared.$currentLyricsOffsetMs) { lyricsOffsetMs = $0 }
        .onReceive(PlaybackCoordinator.shared.$isPlayingNow) { isPlayingNow = $0 }
        .accessibilityHidden(true)
    }

    /// 一小段仿菜单栏。内容靠右,跟真菜单栏上状态栏项的位置一致。
    private func menuBarStrip(_ p: MenuBarMarqueeRenderer.Presentation) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 12)
            lyricsSlot(p)
                .overlay(slotEdgeOutline)
            // 右边这几个只是参照物,让"歌词占了菜单栏多宽"看得出来。用真实时钟而不是
            // 写死一个时间 —— 假数据会让人下意识觉得这块预览"不是真的"。
            HStack(spacing: 11) {
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
                Text(Date(), style: .time)
            }
            .font(Font(MenuBarMarqueeRenderer.font))
            .foregroundStyle(Color(nsColor: .labelColor).opacity(0.55))
            .padding(.leading, 14)
            .padding(.trailing, 12)
        }
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity)
        // ⚠️ 只铺 .bar 材质是不够的:那层材质压在设置窗自己的背景上几乎同色,整条读起来
        // 就是"悬空的文字",完全不像菜单栏(2026-08-16 第一版实拍确认)。真菜单栏之所以
        // 一眼认得出来,是因为它半透明地压在**桌面壁纸**上。所以这里跟桌面悬浮歌词那条
        // 预览用同一张真实壁纸垫底(DesktopWallpaperSample),再压 .bar ——
        // 合成出来的就是菜单栏本来的样子。
        //
        // 壁纸顶端对齐:菜单栏在屏幕最上面,透出来的本来就是壁纸的上边缘那一条。
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                if let wallpaper = DesktopWallpaperSample.image {
                    Image(nsImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(height: Self.cardHeight, alignment: .top)
                        .clipped()
                } else {
                    // 读不到壁纸(动态壁纸/没权限/无屏)就退回一块中性深色 —— 它至少还是
                    // 一条"压在别的东西上的横条",不会退化成跟页面同色的空白。
                    Color(nsColor: .textColor).opacity(0.14)
                }
                // 用 .ultraThinMaterial 而不是 .bar:.bar 在浅色外观下几乎不透明,压上去
                // 直接把壁纸糊成一块灰(2026-08-16 实拍确认),而真菜单栏的透明度高得多 ——
                // 深色壁纸下整条菜单栏是深的、文字自动转白,那正是它一眼认得出来的原因。
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// 歌词那一格的虚线边界(2026-09-01,用户要求"跟悬浮歌词一样把清晰的边界用虚线画出来")。
    ///
    /// 套在 `lyricsSlot` 上,所以**不用自己算宽度** —— 那一格的 frame 本来就恒等于
    /// 「最大宽度」(`.fixed` 分支)或文字自然宽度(`.text` 分支),虚线贴着它画出来的就是
    /// 真实边界。顺带把两种宽度模式的差别也画出来了:固定宽度时虚线框右边空出一块,
    /// 自适应时虚线贴着文字收紧 —— 这正是原来 caption 里那句话在说的事(见 previewCaption)。
    ///
    /// 配色照 `OverlayEditorStage.windowEdgeOutline` 那条老规矩:**固定白色 + 黑色投影,
    /// 不跟深浅色模式走**。理由在这里同样成立 —— 这一格压在 `DesktopWallpaperSample` 那张
    /// 真实壁纸上(再压一层 `.ultraThinMaterial`),底色什么样完全不受 App 控制,语义色
    /// (primary/secondary)在浅壁纸上会直接读不出来;投影负责在亮壁纸上给白线兜一圈暗轮廓。
    ///
    /// 透明度取 0.6 而不是悬浮歌词那条的 0.5:那一圈是常驻在**用户真实桌面**上的,画满了
    /// 会变成一个"假窗口边框"(真窗口并没有边),所以刻意克制;这一圈在**预览**里、而且是
    /// 它接替了 caption 去回答"这一格有多宽",读不清就等于什么都没说。
    ///
    /// 没有悬浮歌词那条"拖动宽度时提亮到 0.95"的联动:那需要把「最大宽度」滑杆的
    /// onEditingChanged 一路传到这里,而滑杆现在住在 `MenuBarEditorStage`(另一个文件、
    /// 另一个所有者)。真需要再补,属于加法。
    private var slotEdgeOutline: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .shadow(color: .black.opacity(0.55), radius: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 歌词那一格。宽度恒等于设置里的「显示宽度」,跟真状态栏项一致(那边靠一张固定尺寸的
    /// 透明占位图把 footprint 跟内容脱钩,见 MenuBarStatusItem.showFixedWidth)。
    ///
    /// 短句右边空出一块是**正常的**,真菜单栏上就是这样 —— 那正是固定宽度换来的稳定:
    /// 长短句来回切,这一项和右边的图标都不会动。
    ///
    /// (这一段 2026-08-17 反复过两次:先是两条分支都钉成上限宽 → 那时语义还是"上限",
    /// 于是预览空一大片而真机不空,是真偏差;改成按文字自然宽度之后语义对上了,但用户
    /// 随即指出真机上那种伸缩本身就难看,于是把设置改成固定宽度,两边又都钉死了。)
    @ViewBuilder
    private func lyricsSlot(_ presentation: MenuBarMarqueeRenderer.Presentation) -> some View {
        switch presentation {
        case .text(let visible):
            // 自适应模式下装得下的句子(以及宽度设成 0 的退化路径)。真机上这两种都是
            // 交给按钮自己画文字,宽度跟着文字走 —— 这里的 fixedSize() 就是那个行为。
            //
            // ⚠️ 跟真机同一条岔路(见 MenuBarStatusItem.refresh 的 .text 分支):这句
            // 真有逐字数据要染时,button.title 画不出叠色,改走跟 .fixed 一样的图层渲染,
            // 窗口宽就取文字自身宽 —— footprint 跟 Text(visible).fixedSize() 逐像素一致。
            // visible != fullText 只发生在宽度设成 0 的截断退化路径,那里不染(跟真机一致)。
            if let fillPath = karaokeFillPath, visible == fullText {
                let w = MenuBarMarqueeRenderer.width(of: visible)
                MenuBarScrollingLabel.Representable(
                    text: visible, windowWidth: w, pacing: nil, fillPath: fillPath,
                    karaokePositionMs: karaokePositionMs,
                    karaokeRate: anchor?.rate ?? 0, karaokePlaying: isPlayingNow)
                    .frame(width: w, height: MenuBarMarqueeRenderer.lineHeight)
            } else {
                Text(visible)
                    .font(Font(MenuBarMarqueeRenderer.font))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: MenuBarMarqueeRenderer.lineHeight)
            }
        case .fixed(let text, let windowWidth, let pacing):
            MenuBarScrollingLabel.Representable(
                text: text, windowWidth: windowWidth, pacing: pacing,
                fillPath: karaokeFillPath, karaokePositionMs: karaokePositionMs,
                karaokeRate: anchor?.rate ?? 0, karaokePlaying: isPlayingNow)
                .frame(width: windowWidth, height: MenuBarMarqueeRenderer.lineHeight)
        }
    }
}
