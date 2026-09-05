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
    static let bottomPadding: CGFloat = 10
    static let captionSpacing: CGFloat = 6
    /// caption 那一行(.font(.caption))的行高经验值。
    static let captionHeight: CGFloat = 15

    // (2026-09-02 删掉了 `barHeight(cardHeight:)` 和它的私有 `chromeHeight`:那两个是给
    //  "三条预览栏共用一个总高"这条契约用的,而另外两条钉条(OverlayPreviewBar /
    //  NotchPreviewBar)在 2026-08-31 改编辑台时就删完了,只剩菜单栏这一条;它这次又把
    //  caption 挪到舞台外面自己算高度(见 MenuBarPreviewBar.stageHeight),这两个符号从此
    //  零调用点。剩下的常量仍然是共用的 —— 三块编辑台的 caption 疏密靠它们保持一致。)
    // (2026-09-03 又删掉了 `topPadding`(14):仿菜单栏那一条从此**贴死舞台上沿**,它上面
    //  不该有桌面(用户原话「这里菜单栏没有贴合顶部」,见 MenuBarPreviewBar.stage)。删了
    //  之后同样零调用点 —— 另外两块编辑台的舞台里,那个形态本体各有自己的摆法(悬浮歌词
    //  居中于 cardArea、灵动岛顶对齐贴刘海),从来没用过这个常量。)
}

extension MenuBarPreviewBar where Lane == EmptyView {
    /// 不需要往通道里浮东西时的构造(通道也就没有存在意义,`reservesWidthLane` 默认 false)。
    /// 目前没有调用点 —— 留着是为了让"拿这条预览去别处用"仍然是一行代码的事,不必先想清楚
    /// 泛型参数。
    init(reservesWidthLane: Bool = false) {
        self.reservesWidthLane = reservesWidthLane
        self.lane = { EmptyView() }
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
struct MenuBarPreviewBar<Lane: View>: View {
    /// 在仿菜单栏那条下面**预留一条通道**给宽度调整条(2026-09-01,用户第三次点名要
    /// "和之前两个页面一样加到这个预览框里面去")。默认 false —— 这个开关只为编辑台那个
    /// 宿主存在,别的地方拿这条预览去用时形状不变。
    ///
    /// 做法照 `OverlayEditorStage`:那块舞台在卡片下面留一条 `widthBarLaneHeight`(44pt)
    /// 高的通道,壁纸铺进通道里,调整条浮在上面。这里通道矮一些(28pt)——胶囊本身就比
    /// 那边的窄,而这条预览总高只有 69pt,留 44pt 会让预览条本身显得很挤。
    var reservesWidthLane = false

    /// 浮在那条通道里的东西(编辑台的宽度调整条)。
    ///
    /// ⚠️ 2026-09-02 从"宿主在外面套一层 `.overlay(alignment: .bottom)`"改成由这里注入。
    /// 起因是用户要求「把预览背景部分扩展到这下面,把下面的滑条包在里面,和灵动岛和悬浮歌词
    /// 设置一样」——舞台的壁纸底一旦要包住调整条,**谁画背景、谁定高度、谁裁圆角就必须是
    /// 同一个人**;宿主在外面 overlay 的话,那一层落在"舞台 + caption"整块上,胶囊会掉到
    /// caption 下面去。插槽在这里,`stage` 自己 overlay 它,几何只有一处。
    @ViewBuilder var lane: () -> Lane

    /// 见 reservesWidthLane。
    static var widthLaneHeight: CGFloat { 28 }

    @ObservedObject private var settings = AppSettings.shared
    /// 舞台整块按**真实菜单栏**的明暗渲染(见 stage 末尾那段);菜单栏由亮转暗时要重画。
    @ObservedObject private var menuBarAppearance = MenuBarAppearanceStore.shared
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

    /// 跟唱滚动的阅读位置路径(2026-09-04)。跟 `MenuBarStatusItem.followReadingPath` 同一份
    /// 判定:有逐字数据、没跟标签文本代际错位;**不看**卡拉OK开关(不染色也要跟着唱到的位置
    /// 滚)。示例句同样不编 —— 没在放歌时它是 nil,预览按时间配速滚,跟真机一致。
    private var followReadingPath: [MenuBarMarquee.KaraokeFillPoint]? {
        guard let line, let words = line.words, !words.isEmpty,
              line.plainText == fullText else { return nil }
        let path = MenuBarMarquee.followReadingPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words))
        return path.isEmpty ? nil : path
    }

    /// 位置公式跟 MenuBarStatusItem.syncKaraokeClock 完全同一条:anchor 外推 ??
    /// 暂停位置,再加歌词时间轴偏移校准。
    private var karaokePositionMs: Int? {
        let raw = anchor?.extrapolatedPositionMs(now: Date()) ?? pausedPositionMs
        return raw.map { $0 + lyricsOffsetMs }
    }

    /// 歌词旁那枚带播放进度的图标(nil = 关着)。判定跟本体
    /// `MenuBarStatusItem.lyricsIconBadge` 逐字相同:同一个开关、同一款图标。
    private var previewIconBadge: MenuBarScrollingLabel.IconBadge? {
        let position = settings.menuBarLyricsIconPosition
        guard position != .off else { return nil }
        return MenuBarScrollingLabel.IconBadge(style: settings.menuBarIconStyle,
                                               position: position)
    }

    /// 图标额外占多宽(关着是 0)。跟真菜单栏算槽宽用的是同一个函数。
    private var reservedIconWidth: CGFloat {
        MenuBarProgressIcon.reservedWidth(for: previewIconBadge?.style)
    }

    /// 进度图标的对表位置。⚠️ 跟上面 `karaokePositionMs` 差的正是 `lyricsOffsetMs`:那个
    /// 偏移挪的是歌词、不是歌 —— 跟 `MenuBarStatusItem.syncProgressClock` 同一条纪律,
    /// 两边都别顺手"统一"成一个。
    private var progressPositionMs: Int? {
        anchor?.extrapolatedPositionMs(now: Date()) ?? pausedPositionMs
    }

    /// 曲长。优先取锚点里那份(跟位置是同一次采样),它缺/为 0 时现读 coordinator ——
    /// 跟上面 `dwellSeconds` 同一个理由在 body 求值时读,不为它另开一条 @State 镜像
    /// (锚点每 ~2s 重发一次会带着 body 重算,晚一步也补得上)。
    ///
    /// 都没有 → nil → 整枚图标只画基础色。**没在放歌时的示例句因此不会演假进度**,跟
    /// 上面 karaokeFillPath 那条"不为示例句编造进度"是同一个原则。
    private var progressDurationMs: Int? {
        [anchor?.durationMs, PlaybackCoordinator.shared.currentDurationMs]
            .compactMap { $0 }.first { $0 > 0 }
    }

    /// 歌词那一格本身有多宽(**不含**旁边那枚进度图标)。虚线边界按它画。
    private func lyricsSlotWidth(_ p: MenuBarMarqueeRenderer.Presentation) -> CGFloat {
        switch p {
        case .text(let visible): return MenuBarMarqueeRenderer.width(of: visible)
        case .fixed(_, let windowWidth, _): return windowWidth
        }
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

    /// 预览下面那行说明。⚠️ 2026-09-02 起它在**舞台外面**(壁纸底之下、卡片背景上),
    /// 跟 `OverlayEditorStage` / `NotchEditorStage` 那两块编辑台的 caption 同一个排法
    /// (`VStack(spacing: captionSpacing) { stage; caption }`)。之前它夹在壁纸条和通道
    /// 之间、靠一个 `Spacer` 顶着,壁纸一扩展下来这行灰字就会压在壁纸上读不清 —— 挪出去
    /// 同时解决了这件事,不需要给它另配一套白字加投影的配色。
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

    /// 舞台(壁纸那一块)的高度。
    ///
    /// 拆开写是因为壁纸底、通道、圆角裁切都要用它。现在是 24 + 10 + 28 = **62**
    /// (仿菜单栏条 + 条与通道之间的呼吸 + 宽度调整条那条通道),加舞台外面那 6 + 15 的
    /// caption 一共 83。
    ///
    /// ⚠️ **2026-09-03 从 76 降到 62**:删掉的是原来垫在仿菜单栏条**上面**的 14pt
    /// (`SectionPreviewMetrics.topPadding`)—— 用户原话「这里菜单栏没有贴合顶部」,理由和
    /// 那 14pt 为什么不该存在见 `stage`。这一页因此整体上移 14pt。
    /// (改版前那条"总高必须凑成 97,一动下面所有卡片就跟着跳"的说法只对了一半:要守的是
    ///  **高度是个常量、不随内容变**(caption 一行/两行、歌词滚不滚都不许改它),不是"必须
    ///  等于 97"这个具体数字 —— 那个数只是当年三条钉条共用总高留下的遗产,而另外两条钉条
    ///  2026-08-31 就删完了。改这个常量只会让页面重排**一次**,不会抖。)
    private var stageHeight: CGFloat {
        Self.cardHeight + SectionPreviewMetrics.bottomPadding
            + (reservesWidthLane ? Self.widthLaneHeight : 0)
    }

    var body: some View {
        // presentation 一轮 body 只求值一次(caption 和歌词格共用),见 previewCaption 注释。
        let p = presentation
        return VStack(spacing: SectionPreviewMetrics.captionSpacing) {
            stage(p)
            // 别把"会滚动"说成"已截断" —— 超宽时到底是滚还是截,由宽度决定,说反了正是
            // 让人觉得这个功能"怪怪的"的原因之一。
            Text(previewCaption(p))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                // 钉住行高:caption 常态是一行,但"预览"和"预览 · 本句会横向滚动"来回切时
                // 不该让整块高度抖一下(同 stageHeight 上面那条不变量)。
                .frame(height: SectionPreviewMetrics.captionHeight)
        }
        .frame(maxWidth: .infinity)
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

    /// 舞台:一小片**屏幕顶端**——壁纸铺满整块,仿菜单栏那一条贴在它的上边缘,底下那条
    /// 通道里浮着宽度调整条。
    ///
    /// 2026-09-02 从"只有仿菜单栏那一条有壁纸底、caption 和胶囊掉在卡片白底上"改成这样
    /// (用户原话:「这里帮我把预览背景部分扩展到这下面,把下面的滑条包在里面,和灵动岛和
    /// 悬浮歌词设置一样」)。改完之后三块编辑台的舞台是同一个模型:一片桌面 + 贴在上面的
    /// 那个形态本体 + 舞台内的宽度调整条,caption 一律在舞台外面。
    ///
    /// ⚠️ 壁纸只画**一张**、由这一层负责,`menuBarStrip` 自己那份已经删掉了。两份各按各的
    /// 高度做 `scaledToFill` 缩放比必然对不上,同一张壁纸会在菜单栏条的下边缘露出一道接缝
    /// (悬浮歌词编辑台第七步为这件事付过一次代价,见 OverlayDesktopSurface 头注)。
    private func stage(_ p: MenuBarMarqueeRenderer.Presentation) -> some View {
        menuBarStrip(p)
            // 顶对齐、**上面不留任何边距**:菜单栏就在屏幕最上面,它上面不可能有桌面;
            // 下面剩下的才是桌面。
            //
            // ⚠️ 2026-09-03 删掉了这里原有的 `.padding(.top, SectionPreviewMetrics.topPadding)`
            // (14pt)。用户原话:「这里菜单栏没有贴合顶部」。那 14pt 是 2026-09-02 把壁纸
            // 从"只垫菜单栏那一条"扩展成"铺满整块舞台"时留下的:在那之前条子上方是卡片白底,
            // 14pt 只是块留白;壁纸铺满之后同样的 14pt 变成了**从菜单栏上方透出来的桌面**,
            // 于是仿菜单栏条看着像一张浮在桌面上的卡片 —— 而它演的恰恰是"贴死屏幕上沿"的
            // 那一条。别再加回来:任何"给条子上面留点呼吸"的改动都会把这个语义再破一次。
            .frame(height: stageHeight, alignment: .top)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) { desktopSurface }
            .overlay(alignment: .bottom) { lane() }
            // 顶直角、底圆角 —— 同一个理由的第二次应用:8pt 的顶圆角会把"贴死上沿"那一条的
            // 两个直角削圆,"这是屏幕最上面那一条"就说不出口了(灵动岛那块舞台为同一件事
            // 用的就是这个形状,见 docs/features/05-notch.md「舞台顶直角」那条)。
            // 形状直接复用灵动岛卡片那个 `NotchHangingShape`:名字带 Notch,画的其实是通用的
            // "顶直角 + 底圆角",与其再抄一份同样的 path 数学不如共用(它在
            // `NotchLyricsView.swift`,改那边记得两处一起看)。
            .clipShape(NotchHangingShape(bottomCornerRadius: 8))
            // ⚠️ 整块舞台按**真实菜单栏**的明暗渲染,不跟设置窗口走(2026-09-03)。
            //
            // 起因是歌词颜色:「跟随系统」= `labelColor` 这个动态色,在浅色的设置窗口里解析
            // 成黑、在深色菜单栏上是白,于是用户看到"菜单栏上白字、预览里黑字"。歌词那一层
            // 的 appearance 在 `MenuBarScrollingLabel.Representable` 里单独钉了,但**只钉它
            // 不够** —— 底下那层 `.ultraThinMaterial` 和 wifi/电池/时钟那几个参照物还跟着
            // 设置窗口走,结果会是"浅色的仿菜单栏条上压着白字",比原来还难读。整块一起换档,
            // 三样东西才是同一个菜单栏。
            .environment(\.colorScheme, menuBarAppearance.colorScheme)
    }

    /// 铺满舞台的那片桌面。
    ///
    /// ⚠️ **壁纸顶端对齐**:菜单栏在屏幕最上面,透出来的本来就是壁纸的上边缘那一条 ——
    /// 所以是 `.frame(height: stageHeight, alignment: .top).clipped()`,不是 `OverlayDesktopSurface`
    /// 那种居中裁切。这也是这里没有直接复用那个共用组件的唯一原因(另一个是读不到壁纸时的
    /// 兜底:那边退回"表示透明"的棋盘格,而菜单栏这一块底下压的是桌面、不是透明,退回一块
    /// 中性深色才对)。
    ///
    /// ⚠️ 那层 16% 的薄纱**必须均匀**盖住整块舞台(照 `NotchEditorStage.desktopSurround`):
    /// 任何"只压某一块"的遮罩都会随宽度模式/宽度变形,那就变成"改宽度把背景也改了"。
    private var desktopSurface: some View {
        ZStack(alignment: .top) {
            if let wallpaper = DesktopWallpaperSample.image {
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
                    .frame(height: stageHeight, alignment: .top)
                    .clipped()
            } else {
                // 读不到壁纸(动态壁纸/没权限/无屏)就退回一块中性深色 —— 它至少还是
                // 一片"压在别的东西上的地",不会退化成跟页面同色的空白。
                Color(nsColor: .textColor).opacity(0.14)
            }
            // 把这一小片屏幕压得别在设置页里太抢眼,同灵动岛那块舞台。
            Color(nsColor: .windowBackgroundColor).opacity(0.16)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 一小段仿菜单栏。**左端一枚苹果标**,歌词格和右边那几个参照物靠右 —— 跟真菜单栏上
    /// 状态栏项的位置一致(第三方状态栏项本来就都在右边)。结构跟灵动岛编辑台那条
    /// `NotchEditorStage.menuBarStrip` 到此同构。
    private func menuBarStrip(_ p: MenuBarMarqueeRenderer.Presentation) -> some View {
        HStack(spacing: 0) {
            // 最左边那颗苹果(2026-09-02 用户要求"在这个位置加一个经典的苹果图标,和系统的
            // 一样")。它跟右边那几个的职责**不是一回事**:右簇是"占多宽"的参照物,这一枚不参与
            // 任何度量,只负责让这一条一眼被认成菜单栏 —— 所以理由单独写在这儿,别并进下面
            // 右簇那句。灵动岛编辑台那条仿菜单栏 2026-08-31 就有这一枚了,这次是补齐菜单栏
            // 这一条。
            //
            // ⚠️ **必须自带 `.font` 和 `.foregroundStyle`**:这一条的那两个修饰符挂在下面
            // **内层右簇的 HStack** 上,外层这一层什么都没挂(跟灵动岛那条挂在外层不一样)。
            // 不自带的话它会继承设置页默认的 body 字体和全不透明 primary 色 —— 不报错,只是
            // 明显比右边那几个更大更黑。
            //
            // ⚠️ 字号 16 **不跟 `MenuBarMarqueeRenderer.font` 走**,这是这一条里唯一一处刻意
            // 脱钩,锚的是**真菜单栏实测墨迹**而不是字体:2026-09-02 抓这台机器真菜单栏量到
            // 那颗苹果的墨迹是 12.50 × 15.50pt,而 `apple.logo` 配 `.system(size: 16)` 在这条
            // 24pt 的仿条里量出来也是 12.50 × 15.50pt(端到端复核:真开窗 + `screencapture -l`,
            // 因为 `.ultraThinMaterial` 必须由 window server 合成、离屏抓不到)。跟着
            // menuBarFont(恒 13pt)画只有 10.25 × 12.62;`Text("\u{F8FF}")` 更小,只有
            // 8.00 × 10.00 —— 比系统矮 35%、窄 36%,一眼就是小一号的苹果("真菜单栏是用
            // U+F8FF 拿到这个图形的"这个想当然的前提实测不成立,两者是同一套图形、不同 metric
            // 缩放)。**别顺手把它改回 `Font(MenuBarMarqueeRenderer.font)` 去"统一"。**
            //
            // ⚠️ 明度跟右簇同取 0.55,不是真菜单栏那样的全不透明:真菜单栏里苹果和状态项本来
            // 就是同一个 labelColor,这条预览既然把右簇压到 0.55,苹果单独画满会变成整条最重的
            // 东西、而右边 wifi/电池还是淡的,反而露馅(两档都实拍比过)。
            //
            // 垂直不用给偏移:16pt 的符号盒(15×18)在 24pt 条里居中后墨迹中心 12.13,时钟文字
            // 墨迹中心 12.375,差 0.25pt —— 比系统自己那条(差 0.50pt)还准。
            // 12 是跟右簇 `.padding(.trailing, 12)` 对称来的。
            //
            // 无障碍什么都不用加:整条预览在 `body` 最外层就挂了 `.accessibilityHidden(true)`,
            // 这棵子树对辅助技术一律不可见,再补一遍是冗余。
            Image(systemName: "apple.logo")
                .font(.system(size: 16))
                .foregroundStyle(Color(nsColor: .labelColor).opacity(0.55))
                .padding(.leading, 12)
            // ⚠️ 这个 Spacer 别删:它把歌词格顶到右边,那是对真机的还原(第三方状态栏项都在
            // 右边)。它原来还兼任这一条的左边距,现在左边距由上面那枚苹果自己的 padding 提供,
            // 这里的 12 剩下的作用是"苹果和歌词格之间至少留这么多"。
            Spacer(minLength: 12)
            lyricsSlot(p)
                // 2026-09-02 用户反馈虚线贴着文字("完全贴着，观感不是很好")。左右各加 3pt
                // 让虚线离文字有点呼吸空间——虚线因此比 windowWidth 本身宽了 6pt,跟"这一格
                // 恒等于真实宽度"这条不变量有一点点出入,但这一圈线本来就是给人看的示意
                // (真实数值在编辑台「最大宽度」滑杆那边,见 previewCaption 的注释),几个点的
                // 松量换来不贴脸的观感,划得来。
                .padding(.horizontal, 3)
                // ⚠️ 虚线只框**歌词那一格**,不含旁边那枚进度图标(2026-09-03)。这一圈的
                // 职责是回答"这一格有多宽"=用户设的「最大宽度」(见 slotEdgeOutline 头注),
                // 把图标一起框进去,这个数就对不上滑杆上的读数了。做法:按歌词自身的宽度画、
                // 贴在图标的**对侧**;没开图标时它就等于整块宽度,跟改动前逐点相同。
                .overlay(alignment: previewIconBadge?.position == .leading ? .trailing : .leading) {
                    slotEdgeOutline.frame(width: lyricsSlotWidth(p) + 6)
                }
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
        // 一眼认得出来,是因为它半透明地压在**桌面壁纸**上。
        //
        // ⚠️ 2026-09-02 起壁纸**不在这一层**:它由 `desktopSurface` 铺满整块舞台,这一条只
        // 负责把材质压上去。壁纸从这里搬走的理由见 `stage` 头注(两份各按各的高度做
        // scaledToFill,缩放比对不上,菜单栏条的下边缘会露出一道接缝)。
        //
        // 材质用 `.ultraThinMaterial` 而不是 `.bar`:`.bar` 在浅色外观下几乎不透明,压上去
        // 直接把壁纸糊成一块灰(2026-08-16 实拍确认),而真菜单栏的透明度高得多 ——
        // 深色壁纸下整条菜单栏是深的、文字自动转白,那正是它一眼认得出来的原因。
        .background(.ultraThinMaterial)
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
            // ⚠️ 2026-09-03 起判据多了一个 `previewIconBadge != nil`,跟真机同步:一枚要按
            // 进度半染色的图标同样塞不进按钮自绘那条路,所以开着图标时装得下的句子也改走
            // 图层渲染(见 MenuBarStatusItem.refresh 的 .text 分支)。
            if visible == fullText, karaokeFillPath != nil || previewIconBadge != nil {
                let w = MenuBarMarqueeRenderer.width(of: visible)
                MenuBarScrollingLabel.Representable(
                    text: visible, windowWidth: w, pacing: nil, fillPath: karaokeFillPath,
                    followPath: followReadingPath, karaokePositionMs: karaokePositionMs,
                    karaokeRate: anchor?.rate ?? 0, karaokePlaying: isPlayingNow,
                    icon: previewIconBadge, progressPositionMs: progressPositionMs,
                    progressDurationMs: progressDurationMs)
                    .frame(width: w + reservedIconWidth,
                           height: MenuBarMarqueeRenderer.lineHeight)
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
                fillPath: karaokeFillPath, followPath: followReadingPath,
                karaokePositionMs: karaokePositionMs,
                karaokeRate: anchor?.rate ?? 0, karaokePlaying: isPlayingNow,
                icon: previewIconBadge, progressPositionMs: progressPositionMs,
                progressDurationMs: progressDurationMs)
                .frame(width: windowWidth + reservedIconWidth,
                       height: MenuBarMarqueeRenderer.lineHeight)
        }
    }
}
