import AppKit
import LyrimuseCore
import QuartzCore
import SwiftUI

// 菜单栏里那一行滚动歌词的**渲染层**(2026-08-16 加)——一句歌词排版成一张长图,交给
// Core Animation 在渲染层平移。主线程每句只干一次活,之后一帧都不碰。
//
// ---- 为什么非得走这条路 ----
//
// 2026-08-05 到 08-16 之间,菜单栏歌词是 SwiftUI 的 MenuBarExtra + 一个 30/60fps 的
// 计时器:每帧算出"此刻该偏移多少"、画(后来是裁)一张新图、发布出去让 label 重渲染。
// 用户反复反馈"菜单栏歌词滚动还是有点卡",而灵动岛上的歌名滚得很顺。
//
// 2026-08-16 把这件事测清楚了,结论跟直觉相反:
//   * 画图**从来不是瓶颈**。离线基准 300 帧:旧的逐帧重排 0.057ms/帧,30fps 下每秒只占
//     主线程 1.7ms(0.17%);改成整句排版一次、每帧只 CGImage.cropping 之后是 0.002ms。
//     把一件只占 0.17% 的事再快 30 倍,用户当然感觉不到差别 —— 那次优化(a589c76)
//     本身没错,但它治不了用户报的病。
//   * 真正的差距在**驱动方式**。灵动岛歌名是真窗口里的 SwiftUI 视图,offset 交给
//     Core Animation 在渲染层插值,主线程零参与;菜单栏那条路每一帧都必须走
//     "模型侧换图 → label 重渲染 → 系统状态栏更新",帧与帧之间的间隔完全取决于主线程
//     什么时候轮得到它。主线程上还跑着 20Hz 的逐字高亮重绘、2 秒一次的播放轮询,
//     一旦被挤,滚动就跟着一顿一顿。
//   * 而 MenuBarExtra **注定**只能走那条路:探针读出 NSStatusBarButton 的实际内容后
//     确认,SwiftUI 是把 label **快照成一张 NSImage** 塞进 button.image 的
//     (title 为空、image 是 16x13 的模板图)。视图侧根本没有活的图层可以挂动画 ——
//     这也顺带解释了此前"`.task` 挂在 MenuBarLabel 上从来不触发"那个实测现象。
//
// 所以只能放弃 MenuBarExtra、自建 NSStatusItem,拿到一个真的 NSView 和它的 CALayer,
// 让滚动变成一条 CAKeyframeAnimation。装好之后主线程不再参与任何一帧。
//
// ---- 图层结构 ----
//
//   self.layer
//     ├ clipLayer   (masksToBounds,尺寸/位置 = NSStatusBarButton 画 image 的那一块)
//     │    └ contentLayer  (滚动动画动的是它的 position.x)
//     │         ├ baseClipLayer  (masksToBounds,只露出**未唱**区 [边界, 句尾])
//     │         │    └ textLayer      (contents = 整句长图,基础色)
//     │         └ fillClipLayer  (masksToBounds,只露出**已唱**区 [0, 边界])
//     │              └ fillTextLayer (contents = 同一句的强调色长图)
//     └ iconHostLayer  (歌词旁那枚带播放进度的图标,2026-09-03;关掉时整层 isHidden)
//          ├ iconBaseClipLayer (masksToBounds,只露出**还没放到**的那截 [边界, 顶])
//          │    └ iconBaseLayer (contents = 图标模板图,基础色)
//          └ iconFillClipLayer (masksToBounds,只露出**已经放过**的那截 [底, 边界])
//               └ iconFillLayer (contents = 同一枚图标的强调色版)
//
// 图标那一支**挂在 self.layer 上、不挂在 clipLayer/contentLayer 里** —— 它不跟着歌词滚,
// 也不该被歌词那一格的裁剪窗切掉;它跟歌词是并排的两块,只在 layout() 里一起排位。
//
// 用多层而不是"直接给 self.layer 设 contents":文字要能滚出可视区并被裁掉,而可视区
// 的位置得跟按钮里 image 的绘制位置对齐(见 layout())。分层之后,layout 只碰
// clipLayer、滚动只碰 contentLayer、染色只碰两个裁剪层,互不干扰 —— 尤其是
// **换颜色时不能打断正在跑的滚动/染色**(见 rebuildImage:只换 contents 和 bounds,
// 绝不碰 position/动画)。
//
// 逐字染色(2026-08-22,用户点名"像酷狗菜单栏歌词"):基础色/强调色两张同字形长图做
// **互补裁剪**——已唱区只显示强调色那张、未唱区只显示基础色那张,像经典 KTV 字幕那样
// 在边界处硬切。⚠️ 不能做成"强调色叠在基础色上面"(第一版就是,当天被用户截图打回):
// 两张图的字形抗锯齿覆盖率相同,叠着画时边缘半透明像素会让底下的基础色透出来,深色
// 菜单栏上蓝字四周就镶一圈白晕("染色后有白边")。互补裁剪让每个区域的字形只与背景
// 合成一次,哪里都没有叠色。
// 整行的填色进程编成三条**同步**的 CAKeyframeAnimation(fillClip 的宽 + baseClip 的
// position.x/bounds,共享 beginTime/keyTimes,按逐字时间轴生成,见
// MenuBarMarquee.karaokeFillKeyframes),装好后主线程一帧都不碰,跟滚动同一哲学。
// 两个裁剪层都挂在 contentLayer 里,滚动时天然跟文字焊在一起。
@MainActor
final class MenuBarScrollingLabel: NSView {
    private static let scrollAnimationKey = "lyrimuse.marquee"
    private static let fillAnimationKey = "lyrimuse.karaoke-fill"
    private static let basePositionAnimationKey = "lyrimuse.karaoke-base-pos"
    private static let baseBoundsAnimationKey = "lyrimuse.karaoke-base-bounds"
    private static let iconFillAnimationKey = "lyrimuse.progress-fill"
    private static let iconBasePositionAnimationKey = "lyrimuse.progress-base-pos"
    private static let iconBaseBoundsAnimationKey = "lyrimuse.progress-base-bounds"

    private let clipLayer = CALayer()
    private let contentLayer = CALayer()
    private let baseClipLayer = CALayer()
    private let textLayer = CALayer()
    private let fillClipLayer = CALayer()
    private let fillTextLayer = CALayer()
    private let iconHostLayer = CALayer()
    private let iconBaseClipLayer = CALayer()
    private let iconBaseLayer = CALayer()
    private let iconFillClipLayer = CALayer()
    private let iconFillLayer = CALayer()

    /// 歌词旁边那枚带播放进度的图标要不要画、画哪一款、摆哪边(nil = 关着)。
    ///
    /// 存的是**款式枚举**而不是 NSImage:NSImage 没有值语义的相等性,放进 `Plan` 会让
    /// "同参数重复调用是空操作"这条失效(每次都判定成变了 → 每次重排位图 + 重启动画)。
    /// 真正的图从 `MenuBarProgressIcon`(内部走 `MenuBarIconStyle.cachedImage`)现取。
    struct IconBadge: Equatable {
        let style: MenuBarIconStyle
        /// 只会是 `.leading` / `.trailing` —— `.off` 由调用方转成 `icon: nil`。
        let position: MenuBarLyricsIconPosition
    }

    /// 一句歌词的滚动参数。只有它变了才重排版 + 重启动画;换颜色不动它。
    private struct Plan: Equatable {
        var text: String
        var windowWidth: CGFloat
        /// 静止(装得下)时短句在格子里靠哪边。由 present() 现读 AppSettings 填进来 ——
        /// 不让调用方传:两个调用点(MenuBarStatusItem.showFixedWidth、设置页预览的
        /// Representable)都只关心"画哪句话多宽",对齐是纯样式,从这里读一次比在两处各传
        /// 一遍少一个漂的机会。
        var alignment: LyricsRestingAlignment
        /// 字重(2026-09-03)。跟 alignment 一样由 present() 现读 AppSettings。它同时改变**位图内容**
        /// 和**文字宽度**(滚动距离),所以下面 bitmapsUnchanged / scrollUnchanged 两道判定都要看它,
        /// 否则用户在设置里换了粗细,菜单栏要等到下一次换句才变。
        var fontWeight: OverlayFontWeight
        /// 字号(2026-09-03),0 = 跟随系统。同 fontWeight:位图、行高、滚动距离都随它变。
        var fontSize: CGFloat
        /// nil = 这一句装得下,静止显示。格子宽度照样是 windowWidth(固定宽度,见
        /// MenuBarMarqueeRenderer.presentation)。
        var pacing: MenuBarMarquee.ScrollPacing?
        /// 逐字染色的填色边界路径(nil = 这句没有逐字数据 / 开关关着,不染)。
        /// 路径是词时间轴的纯翻译,不含播放位置 —— 时钟另走 updateKaraokeClock。
        var fillPath: [MenuBarMarquee.KaraokeFillPoint]?
        /// 跟唱滚动的阅读位置路径(2026-09-04;nil = 这句没有逐字数据,滚动走时间配速)。
        /// 跟 fillPath 一样是词时间轴的纯翻译、不含播放位置,时钟同走 updateKaraokeClock。
        /// ⚠️ 跟 fillPath 是两条路径:fillPath 在词间空隙是平的,这条把空隙吸收进运动里
        /// (见 MenuBarMarquee.followReadingPath);而且这条**不看**卡拉OK开关 —— 不染色也要
        /// 跟着唱到的位置滚。偏移路径不在这里存:它还依赖格子宽和长图宽,装动画时现算。
        var followPath: [MenuBarMarquee.KaraokeFillPoint]?
        /// 歌词旁那枚带播放进度的图标(nil = 关着)。跟 fillPath 一样只描述"画什么",
        /// 进度到哪儿了是另一条时钟通道(updateProgressClock)。
        var icon: IconBadge?
    }

    private var plan: Plan?
    private var prepared: MenuBarMarqueeRenderer.PreparedLine?
    private var highlighted = false

    /// 逐字染色的播放时钟快照:外面(MenuBarStatusItem)对表时存底,内部要重装填色动画
    /// (换句/换色重建)时按墙钟外推,不用等下一次对表。
    private struct KaraokeClock {
        let baseMs: Int
        let rate: Double
        let playing: Bool
        let capturedAt: Date

        func positionMs(at date: Date = Date()) -> Int {
            guard playing, rate > 0 else { return baseMs }
            return baseMs + Int(date.timeIntervalSince(capturedAt) * 1000 * rate)
        }
    }

    private var karaokeClock: KaraokeClock?

    /// 整首歌的播放时钟快照(进度图标用)。跟上面那份 `KaraokeClock` 长得像但**不是**
    /// 同一份,刻意不合并:
    ///   * 这一份多一个 `durationMs`(逐字染色不需要曲长,它的终点是这一行唱完);
    ///   * 喂进来的位置**不含歌词时间轴偏移**(那份含)—— 见
    ///     `MenuBarMarquee.progressFillLength` 上面那段⚠️ 和调用点
    ///     `MenuBarStatusItem.syncProgressClock`。
    /// 合并成一个类型只会让"这个位置到底加没加偏移"变成一个要靠记忆回答的问题。
    private struct ProgressClock {
        let baseMs: Int
        let durationMs: Int
        let rate: Double
        let playing: Bool
        let capturedAt: Date

        func positionMs(at date: Date = Date()) -> Int {
            guard playing, rate > 0 else { return baseMs }
            return baseMs + Int(date.timeIntervalSince(capturedAt) * 1000 * rate)
        }
    }

    private var progressClock: ProgressClock?

    /// 进度图标染好色的两张位图(基础色 / 强调色)。nil = 这一刻不画图标。
    private var preparedIcon: (base: MenuBarProgressIcon.Prepared,
                               fill: MenuBarProgressIcon.Prepared)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        clipLayer.masksToBounds = true
        // 视图自身的 layer 也裁(2026-08-19 错位排查加的硬保证):实测存在一种启动时序,
        // 文字越过状态栏槽位压到左右邻居的图标上(几何模型日志里 clip 明明是对的,屏上
        // 却溢出;同一份代码有的启动坏、有的启动好,竞态没钉死)。这一层兜底让任何内容
        // **物理上**画不出 label 自己的 frame —— frame 由 autoresizing 跟着按钮走,
        // 最坏情况是文字被裁短,绝不再盖到别人头上。
        layer?.masksToBounds = true
        // anchorPoint 归零之后 position 就等于左下角,layout/动画里算坐标不用再折算半个尺寸。
        // baseClipLayer 靠"position.x = bounds.origin.x = 边界"这组关系露出 [边界, 句尾]
        // 而让里面的 textLayer 在 contentLayer 坐标系里纹丝不动(见 applyKaraokeFill)。
        clipLayer.anchorPoint = .zero
        contentLayer.anchorPoint = .zero
        baseClipLayer.anchorPoint = .zero
        textLayer.anchorPoint = .zero
        fillClipLayer.anchorPoint = .zero
        fillTextLayer.anchorPoint = .zero
        baseClipLayer.masksToBounds = true
        fillClipLayer.masksToBounds = true
        baseClipLayer.addSublayer(textLayer)
        contentLayer.addSublayer(baseClipLayer)
        fillClipLayer.addSublayer(fillTextLayer)
        contentLayer.addSublayer(fillClipLayer)
        clipLayer.addSublayer(contentLayer)
        layer?.addSublayer(clipLayer)
        // 进度图标那一支。几何关系跟上面那对裁剪层**逐条对称**,只是把横向换成纵向:
        // fillClip 露出 [底, 边界]、baseClip 露出 [边界, 顶](2026-09-03 用户从
        // "左→右"和"下→上"里选的后者,像水位涨上来)。
        for l in [iconHostLayer, iconBaseClipLayer, iconBaseLayer, iconFillClipLayer, iconFillLayer] {
            l.anchorPoint = .zero
        }
        iconBaseClipLayer.masksToBounds = true
        iconFillClipLayer.masksToBounds = true
        iconHostLayer.isHidden = true
        iconBaseClipLayer.addSublayer(iconBaseLayer)
        iconHostLayer.addSublayer(iconBaseClipLayer)
        iconFillClipLayer.addSublayer(iconFillLayer)
        iconHostLayer.addSublayer(iconFillClipLayer)
        layer?.addSublayer(iconHostLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不使用") }

    // 这一层只负责画。点击必须落到底下的 NSStatusBarButton 上去弹菜单,否则点了没反应。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // 状态栏项的宽度会随 button.image 的尺寸变(用户拖宽度滑杆、或者在"图标/文字/滚动"
    // 三种模式之间切换),这一层靠 autoresizing 跟着变;尺寸一变就得重新摆 clipLayer,
    // 否则可视窗口还停在旧的居中位置上。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // MARK: - 对外

    /// 显示(或更新)一句要滚动的歌词。同一句用同样的参数重复调用是空操作 ——
    /// 否则每次 recompute 都会把滚动打回开头,用户永远看不到后半句。
    func present(text: String, windowWidth: CGFloat, pacing: MenuBarMarquee.ScrollPacing?,
                 fillPath: [MenuBarMarquee.KaraokeFillPoint]? = nil,
                 followPath: [MenuBarMarquee.KaraokeFillPoint]? = nil,
                 icon: IconBadge? = nil) {
        let next = Plan(text: text, windowWidth: windowWidth,
                        alignment: AppSettings.shared.menuBarLyricsAlignment,
                        fontWeight: AppSettings.shared.menuBarLyricsFontWeight,
                        fontSize: AppSettings.shared.menuBarLyricsFontSize,
                        pacing: pacing, fillPath: fillPath, followPath: followPath, icon: icon)
        guard next != plan else {
            isHidden = false
            return
        }
        // 只有**位图内容会变**时才重排(2026-08-19,兑现 PreparedLine.color 注释承诺的那类
        // 幂等):位图内容只由 text+解析色+要不要染色决定,几何推迟落地这类"同一句只换
        // 槽宽/配速"的调用(interim → 重建落地)原来会把逐像素相同的长图白排一遍。颜色在
        // 本路径不变(highlighted/appearance 变化各有自己的入口,那两处照旧重画)。
        // fillPath 的**有无**参与判定(强调色那张图要不要排),路径数值本身不影响位图。
        // ⚠️ 图标也进这道判定:换款式(用户在设置里一款款点着挑)、开关这一项、换边,
        // 三件事都要重出位图。不带它的话换款式在菜单栏上要等下一次换句才生效。
        let bitmapsUnchanged = prepared != nil && plan?.text == next.text
            && (plan?.fillPath != nil) == (next.fillPath != nil)
            && plan?.icon == next.icon
            && plan?.fontWeight == next.fontWeight
            && plan?.fontSize == next.fontSize
        // 滚动动画只在**滚动参数**(文字/槽宽/配速)真的变了时才重启。fillPath 从 nil 变成
        // 非 nil **不算** —— 那是"开唱那一刻把逐字填色挂上"(菜单栏订了 compactLine 和
        // currentLine 两条流,后者就管这一下,见 MenuBarStatusItem)。2026-08-24 之前它会
        // 连带把滚动打回开头:提前量窗口里那一句本来已经静止等着了(head 以提前量为下限),
        // 开唱那一下再从零起一遍首停,等于把提前量白等两遍,长句更滚不完。
        // ⚠️ followPath 跟 fillPath 不同,它**算**滚动参数(2026-09-04):跟唱滚动的关键帧就是
        // 从它算出来的,开唱那一刻它从 nil 变非 nil 必须把跟唱动画装上。这不会重蹈上面那个坑:
        // 此刻阅读位置还没到锚点、偏移是 0,位置无跳变;跟唱模式也没有首停可以被白等。
        let scrollUnchanged = prepared != nil && (plan.map {
            $0.text == next.text && $0.windowWidth == next.windowWidth && $0.pacing == next.pacing
                && $0.followPath == next.followPath
                && $0.fontWeight == next.fontWeight && $0.fontSize == next.fontSize
        } ?? false)
        plan = next
        isHidden = false
        if !bitmapsUnchanged { rebuildImage() }
        // 自愈那一半:参数没变但动画不在(首次装上、clear 之后、或者这一句本来就不用滚)
        // 照样得跑一趟 restartAnimation —— 它对"不用滚"的情况就是把位置复位到开头。
        if !scrollUnchanged || contentLayer.animation(forKey: Self.scrollAnimationKey) == nil {
            restartAnimation()
        }
        // 换句/换路径后按存底时钟重装填色(时钟按墙钟外推,不用等下一次对表)。
        applyKaraokeFill()
        // 进度图标同理。⚠️ 它跟换句**没关系**(整首歌一条匀速动画),但重排位图会把
        // contents 换掉、裁剪层的 bounds 也被重设,所以每次走到这儿都得按存底时钟重装一次,
        // 否则换句那一下进度会跳回 0 停在那儿。
        applyProgressFill()
        needsLayout = true
    }

    /// 逐字染色对表:MenuBarStatusItem 在锚点/暂停位置/时间轴偏移变化时喂进来。
    /// - force: 跳过漂移门(时间轴偏移那种"小步但必须立刻生效"的变化用;seek 的大跳
    ///   本来就过不了漂移门,不用 force)。
    ///
    /// 漂移门:动画在跑、播放状态没变、且新旧时钟推算的位置差 < 250ms 时**不打断动画**,
    /// 只换存底 —— 锚点每次 poll(~2s)都会重发,位置只差外推误差,逐次重装动画会让
    /// 填色边界肉眼可见地小跳一下。250ms 跟位置伺服的容差同量级,seek 必然超过。
    func updateKaraokeClock(positionMs: Int?, rate: Double, playing: Bool, force: Bool = false) {
        guard let positionMs else {
            karaokeClock = nil
            applyKaraokeFill()
            applyFollowScroll()
            return
        }
        let next = KaraokeClock(baseMs: positionMs, rate: rate, playing: playing, capturedAt: Date())
        if !force, playing, let old = karaokeClock, old.playing, old.rate == rate,
           hasClockDrivenAnimation,
           abs(old.positionMs() - positionMs) < 250 {
            karaokeClock = next
            return
        }
        karaokeClock = next
        applyKaraokeFill()
        applyFollowScroll()
    }

    /// 漂移门看的"动画在跑":填色那三条,或跟唱滚动那一条(2026-09-04 起卡拉OK关着时只有
    /// 后者)。两者都没有说明这一刻没有可动的东西,重装也只是把静止位置再对一遍,门开着无妨。
    private var hasClockDrivenAnimation: Bool {
        fillClipLayer.animation(forKey: Self.fillAnimationKey) != nil
            || (plan?.followPath != nil
                && contentLayer.animation(forKey: Self.scrollAnimationKey) != nil)
    }

    /// 整首歌的进度对表(进度图标用)。跟上面那条逐字染色的对表是**两条独立通道**,由
    /// `MenuBarStatusItem` 在同一批订阅里各喂各的。
    ///
    /// - Parameter positionMs: 当前播放位置,**不含**歌词时间轴偏移(见 ProgressClock)。
    /// - Parameter durationMs: 曲长。nil / 非正 = 不知道这首歌多长(有些播放器不报),
    ///   那就整枚图标只用基础色,不假装有进度。
    /// - Parameter force: 跳过漂移门。
    ///
    /// 漂移门比逐字染色那道**宽得多(1s,那边 250ms)**,而且这是算出来的不是拍的:整首歌
    /// 的进度铺在图标那 ~15pt 高上,一首 4 分钟的歌里 1 秒 = 15 × 1/240 ≈ **0.06pt**,
    /// 肉眼绝无可能看出来。而锚点每 ~2s 例行重发一次,门太窄就会没事重装动画。
    func updateProgressClock(positionMs: Int?, durationMs: Int?, rate: Double, playing: Bool,
                             force: Bool = false) {
        guard let positionMs, let durationMs, durationMs > 0 else {
            progressClock = nil
            applyProgressFill()
            return
        }
        let next = ProgressClock(baseMs: positionMs, durationMs: durationMs, rate: rate,
                                 playing: playing, capturedAt: Date())
        if !force, playing, let old = progressClock, old.playing, old.rate == rate,
           old.durationMs == durationMs,
           iconFillClipLayer.animation(forKey: Self.iconFillAnimationKey) != nil,
           abs(old.positionMs() - positionMs) < 1000 {
            progressClock = next
            return
        }
        progressClock = next
        applyProgressFill()
    }

    /// 退出滚动模式(这一句装得下、菜单栏歌词关掉、或者没在播放)。
    /// 必须真的把动画摘掉:留一条 repeatCount = .infinity 的动画在隐藏图层上,
    /// 渲染层会一直为它做无用功。
    func clear() {
        guard plan != nil || !isHidden else { return }
        plan = nil
        prepared = nil
        contentLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        fillClipLayer.removeAnimation(forKey: Self.fillAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.basePositionAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.baseBoundsAnimationKey)
        // 进度图标那条也必须真的摘掉(同一条理由:留一条 fillMode=forwards 的动画在
        // 隐藏图层上,渲染层会一直为它做无用功)。
        iconFillClipLayer.removeAnimation(forKey: Self.iconFillAnimationKey)
        iconBaseClipLayer.removeAnimation(forKey: Self.iconBasePositionAnimationKey)
        iconBaseClipLayer.removeAnimation(forKey: Self.iconBaseBoundsAnimationKey)
        preparedIcon = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contents = nil
        fillTextLayer.contents = nil
        fillClipLayer.isHidden = true
        iconBaseLayer.contents = nil
        iconFillLayer.contents = nil
        iconHostLayer.isHidden = true
        CATransaction.commit()
        isHidden = true
    }

    /// 只把**歌词**收掉、那枚进度图标留在原地(2026-09-03,悬停三键接管时用)。用户原话:
    /// "如果有开启左右侧图标的话,悬浮之后图标依旧保留,只是歌词部分变为控制键"。
    ///
    /// 跟 `clear()` 的差别只有两处,但都要紧:
    ///  - **`isHidden` 不置真** —— 图标就画在这一层上,整层藏了图标也没了;
    ///  - **`preparedIcon` / `iconHostLayer` / 三条进度动画全部留着** —— `syncProgressClock`
    ///    那条通道在接管期间照常喂进来(它不经 `refresh()`),图标上的进度会继续涨。
    ///
    /// `plan` **照样置 nil**:留着的话退出接管后 `present()` 拿同一句进来会被 `next != plan`
    /// 那道去重当成空操作直接 return,而文字层已经被清空了 —— 表现是"移开鼠标之后歌词一片
    /// 空白,要等换下一句才回来"。置 nil 之后 `layout()` 会早退,图标的 frame 就停在接管前
    /// 那一次算好的位置上,而接管期间几何本来就是冻住的,正好。
    func clearLyricsKeepingIcon() {
        guard plan != nil else { return }
        plan = nil
        prepared = nil
        contentLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        fillClipLayer.removeAnimation(forKey: Self.fillAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.basePositionAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.baseBoundsAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contents = nil
        fillTextLayer.contents = nil
        fillClipLayer.isHidden = true
        CATransaction.commit()
    }

    /// 菜单打开/关闭。只换文字颜色,**不碰**正在跑的滚动动画 —— 点开菜单看一眼再关掉,
    /// 歌词该滚到哪儿还在哪儿。反白期间逐字染色整个隐掉(基础字已换成选中色,强调色叠在
    /// 选中背景上要么撞色要么看不清,索性回到整行统一色,关掉菜单再恢复)。
    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        rebuildImage()
        applyKaraokeFill()
        // 反白期间进度填色也整个隐掉(同逐字染色:基础图已换成选中色,强调色叠在选中
        // 背景上要么撞色要么看不清)。关掉菜单恢复。
        applyProgressFill()
    }

    // 位图比例跟着按钮所在窗口走(2026-09-05):状态项在不同 DPI 的显示器之间迁移、或第一次挂进
    // 窗口时,当前比例可能跟上次排版用的不一样 —— 只换 contents 重排一遍,不碰滚动和填色动画
    // (跟 refreshColors 同一条安全边界)。prepared.scale 是上次实际用的比例,相等就什么都不做,
    // 所以单屏下这两个回调等于空操作。
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildIfScaleChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildIfScaleChanged()
    }

    private func rebuildIfScaleChanged() {
        guard let prepared, prepared.scale != menuBarBitmapScale else { return }
        refreshColors()
    }

    // 系统在浅色/深色之间切换时,labelColor 解析出来的是另一个值,得重画。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildImage()
    }

    // MARK: - 内部

    /// 这一层里两块内容各自的矩形(视图坐标):歌词那一格、以及可选的那枚进度图标。
    ///
    /// 抽出来是因为**第二个消费者**:悬停三键要正好落在「歌词那一格」里(开着图标时那一格
    /// 比整个按钮窄,图标那一块要留着,见 MenuBarStatusItem 的 hover 那一段)。各算一份迟早
    /// 漂开,而这套算式跟状态栏项**出生时**算槽宽的那份本来就是配对的
    /// (`MenuBarProgressIcon.reservedWidth`,对不上就是歌词画到槽外压邻居)。
    struct ContentGeometry {
        /// 歌词格:滚动裁剪窗的位置和大小(高度是这一句的行高,不是整个按钮高)。
        let lyrics: CGRect
        /// 那枚进度图标;没开就是 nil。
        let icon: CGRect?
    }

    func contentGeometry() -> ContentGeometry? {
        guard let plan else { return nil }
        let height = prepared?.pointHeight ?? MenuBarMarqueeRenderer.lineHeight
        // 可视窗口跟 NSStatusBarButton 画 image 的位置对齐:水平居中 + 垂直居中。
        // 宽度用 plan.windowWidth 而不是 bounds.width —— 按钮比它宽一圈(系统给状态栏项
        // 留的左右内边距),文字必须落在中间那一块,否则会顶到相邻图标上。
        // 裁剪窗钳制在自身 bounds 内(2026-08-19):bounds 短暂陈旧(启动竞态/尺寸切换
        // 的一拍)时,原来的居中公式会算出大负数/大偏移,把可视窗甩到槽位外。
        // 开着进度图标时,这一格里是**并排的两块**:图标 + 间距 + 歌词格。整块一起在按钮里
        // 居中,图标按设置落在左端或右端;歌词格的宽度**不受影响**(图标占的是额外让出来的
        // 地方,用户设的「最大宽度」仍然全是歌词的)。
        //
        // ⚠️ 让出多宽用 `MenuBarProgressIcon.reservedWidth` —— 跟状态栏项**出生时**算槽宽
        // 用的是同一个函数。这里另算一遍的后果不是"差几个点":macOS 26 起项的宽度只在出生
        // 那一刻算数,两边对不上就是歌词画到槽外、压在邻居图标上(见 MenuBarStatusItem
        // .present 头注)。
        let iconSize = plan.icon.map { MenuBarProgressIcon.size(of: $0.style) } ?? .zero
        let reserved = MenuBarProgressIcon.reservedWidth(for: plan.icon?.style)
        // ⚠️ 横向那一半交给 `MenuBarHoverControls.lyricsSlot` —— 悬停三键要落在**同一格**里,
        // 而它拿不到 `plan`(易失),只能从槽宽反推。两个入口共用一份算式,别在这儿再写一遍
        // (为什么:那正是 2026-09-03「点暂停生效上一首」那个 bug 的病根,见那个函数的头注)。
        guard let slot = MenuBarHoverControls.lyricsSlot(
            buttonWidth: bounds.width, contentWidth: plan.windowWidth + reserved,
            reservedIconWidth: reserved, iconLeading: plan.icon?.position == .leading)
        else { return nil }
        let contentW = min(plan.windowWidth + reserved, bounds.width)
        let left = max(0, ((bounds.width - contentW) / 2).rounded())
        let clipW = slot.width
        let y = ((bounds.height - height) / 2).rounded()
        let lyricsX = slot.x
        let iconX: CGFloat
        switch plan.icon?.position {
        case .leading:
            iconX = left
        case .trailing:
            iconX = left + clipW + MenuBarProgressIcon.gap
        default:
            iconX = 0
        }
        return ContentGeometry(
            lyrics: CGRect(x: lyricsX, y: y, width: clipW, height: height),
            // 图标按自己的高度在按钮里垂直居中 —— 跟"图标独占那一格"时按钮自己居中画
            // 模板图的落点一致,两态之间切换时图标不会上下跳。
            icon: plan.icon == nil ? nil : CGRect(
                x: iconX, y: ((bounds.height - iconSize.height) / 2).rounded(),
                width: iconSize.width, height: iconSize.height))
    }

    // ⚠️ 这里曾经有个 `lyricsSlotFrame`,供悬停三键问"歌词格在哪"(2026-09-03 当天加、当天删)。
    // 删掉的原因不是没用,而是**这条路本身是错的**:它按 `plan` 算,而 `plan` 是易失的
    // (悬停接管时被清、暂停收成图标时又被清),于是同一格会算出两套位置、三个键的矩形在
    // `48.5/72.5/96.5` 和 `36/60/84` 之间跳,差 12.5pt 正好够点到隔壁键。现在由
    // `MenuBarStatusItem.currentLyricsSlot()` 从槽宽(`item.length`,这一项的硬事实)反推,
    // 横向算式两边共用 `MenuBarHoverControls.lyricsSlot`。**别再加回来。**

    /// 这一刻画着那枚进度图标没有。悬停三键要据此决定收歌词时能不能连图标一起收
    /// (答案是不能,见 `clearLyricsKeepingIcon`)。读这一层的**实际状态**而不是去读设置:
    /// 设置刚改完、还没走到重画时两者会短暂不一致。
    var showsIconBadge: Bool { plan?.icon != nil }

    override func layout() {
        super.layout()
        guard let geometry = contentGeometry() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.frame = geometry.lyrics
        // 只写 y。x 由滚动动画接管(动的是 contentLayer),这里碰它会跟滚动打架。
        contentLayer.position = CGPoint(x: contentLayer.position.x, y: 0)
        if let icon = geometry.icon { iconHostLayer.frame = icon }
        CATransaction.commit()
    }

    /// 「未唱到 / 整行」文字色的**唯一口径**。设置页那个色块也从这里取(定型在菜单栏那一档
    /// 的 appearance 下,见 MenuBarAppearanceStore)—— 各写一份的后果就是 2026-09-03 用户
    /// 报的"菜单栏上是白字,设置里的色块是黑的"。
    ///
    /// ⚠️ 返回的可能是**动态色**(`labelColor` / `selectedMenuItemTextColor`),真正解析成 RGB
    /// 是在绘制那一刻按当前 appearance 决定的 —— 调用方负责套 `performAsCurrentDrawingAppearance`
    /// 或 `resolved(in:)`。
    static func textColor(hex: String, highlighted: Bool) -> NSColor {
        // 菜单打开时状态栏项整块反白,文字得跟着变 —— 这正是以前用模板图时系统免费
        // 帮我们做的那件事,自己拿图层之后要自己做。反白优先于自定义色:选中蓝底上
        // 什么自定义色都可能看不清。
        if highlighted { return .selectedMenuItemTextColor }
        guard !hex.isEmpty else { return .labelColor }
        return NSColor(Color(hexWithAlpha: hex, fallback: Color(nsColor: .labelColor)))
    }

    /// 「已唱到」那一半的颜色的**唯一口径**(理由同上)。`darkMenuBar` 显式传进来而不是在里面
    /// 读 `effectiveAppearance`:设置页那个色块问的是"**菜单栏**上会是什么色",而它自己身处
    /// 浅色的设置窗口里。
    static func fillColor(hex: String, darkMenuBar: Bool) -> NSColor {
        if !hex.isEmpty {
            return NSColor(Color(hexWithAlpha: hex, fallback: Color(nsColor: .controlAccentColor)))
        }
        let accent = NSColor.controlAccentColor
        guard darkMenuBar else { return accent }
        return accent.blended(withFraction: 0.4, of: .white) ?? accent
    }

    private var tintColor: NSColor {
        Self.textColor(hex: AppSettings.shared.menuBarLyricsTextColorHex, highlighted: highlighted)
    }

    /// 染色用的颜色。用户设了自定义色(设置 › 菜单栏 › 染色颜色)就**原样用**;没设则跟随
    /// 系统强调色,但**深色菜单栏上向白提亮四成** —— 系统强调色按浅底设计,直接压在深底上
    /// 亮度低于旁边的白色基础字,染过的反而更难读(2026-08-22 用户截图实测"看不清文字")。
    /// 浅色菜单栏保持原样:深色文字旁边的饱和强调色本来就够跳。动态色,必须在
    /// performAsCurrentDrawingAppearance 里取值。
    private var karaokeFillColor: NSColor {
        Self.fillColor(
            hex: AppSettings.shared.menuBarLyricsFillColorHex,
            darkMenuBar: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// 颜色设置(文字色/染色色)变了:重排位图 + 重放填色几何,**不碰**滚动动画 ——
    /// 跟 setHighlighted 同一套安全边界。
    func refreshColors() {
        rebuildImage()
        applyKaraokeFill()
        applyProgressFill()
    }

    /// 按当前颜色重排这一句。**不重启动画**:图片尺寸只跟文字+字体有关,颜色变了尺寸不变,
    /// 所以换 contents 是安全的,position 和动画原封不动(滚动**和**填色两条都是)。
    private func rebuildImage() {
        guard let plan else { return }
        let color = tintColor
        // 位图按**这个视图所在窗口**的比例栅格化(2026-09-05,见 NSView.menuBarBitmapScale);
        // 排完记在 prepared.scale 里,换屏时跟当前值比对决定要不要重排(rebuildIfScaleChanged)。
        let scale = menuBarBitmapScale
        var built: MenuBarMarqueeRenderer.PreparedLine?
        var fillBuilt: MenuBarMarqueeRenderer.PreparedLine?
        var iconBase: MenuBarProgressIcon.Prepared?
        var iconFill: MenuBarProgressIcon.Prepared?
        // ⚠️ labelColor/selectedMenuItemTextColor 是**动态**颜色,真正解析成 RGB 是在
        // 绘制那一刻按"当前绘制 appearance"决定的。不套这一层的话,深色菜单栏上会画出
        // 一行几乎看不见的深色字(取决于 App 自己的 appearance,而不是菜单栏的)。
        effectiveAppearance.performAsCurrentDrawingAppearance {
            built = MenuBarMarqueeRenderer.prepare(text: plan.text, color: color, scale: scale)
            if plan.fillPath != nil {
                fillBuilt = MenuBarMarqueeRenderer.prepare(text: plan.text, color: karaokeFillColor,
                                                           scale: scale)
            }
            // 图标跟歌词共用**同两个颜色**(未唱到的 / 已唱到的),所以它跟旁边的字永远
            // 是一套配色 —— 深浅色菜单栏、菜单反白、用户自定义色三件事一次都不用另写。
            // ⚠️ 强调色这一张跟 `plan.fillPath` **没有**关系:逐字染色关掉了(或者这首歌
            // 没有逐字数据)时,进度图标照样要染 —— 它的进度来自播放位置,不是歌词时间轴。
            if let icon = plan.icon {
                iconBase = MenuBarProgressIcon.tinted(style: icon.style, color: color, scale: scale)
                iconFill = MenuBarProgressIcon.tinted(style: icon.style, color: karaokeFillColor,
                                                      scale: scale)
            }
        }
        guard let built else {
            // 排版失败(宽度算成 0、内存分配失败)——宁可什么都不显示,也不要留半张旧图。
            isHidden = true
            return
        }
        prepared = built
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contents = built.cg
        textLayer.contentsScale = built.scale
        // 用 bounds 而不是 frame:frame 会连 position 一起写,那就把动画的落点冲掉了。
        textLayer.bounds = CGRect(x: 0, y: 0, width: built.textWidth, height: built.pointHeight)
        if let fillBuilt {
            fillTextLayer.contents = fillBuilt.cg
            fillTextLayer.contentsScale = fillBuilt.scale
            fillTextLayer.bounds = CGRect(x: 0, y: 0, width: fillBuilt.textWidth,
                                          height: fillBuilt.pointHeight)
            // 只动高,不碰宽 —— 宽是填色动画的领地(见 applyKaraokeFill)。
            fillClipLayer.bounds.size.height = fillBuilt.pointHeight
        } else {
            fillTextLayer.contents = nil
        }
        if let iconBase, let iconFill {
            preparedIcon = (iconBase, iconFill)
            iconBaseLayer.contents = iconBase.cg
            iconBaseLayer.contentsScale = iconBase.scale
            iconBaseLayer.bounds = CGRect(origin: .zero, size: iconBase.size)
            iconFillLayer.contents = iconFill.cg
            iconFillLayer.contentsScale = iconFill.scale
            iconFillLayer.bounds = CGRect(origin: .zero, size: iconFill.size)
            // 只动宽,不碰高 —— 高是进度动画的领地(见 applyProgressFill)。
            iconFillClipLayer.bounds.size.width = iconFill.size.width
            iconHostLayer.isHidden = false
        } else {
            preparedIcon = nil
            iconBaseLayer.contents = nil
            iconFillLayer.contents = nil
            iconHostLayer.isHidden = true
        }
        CATransaction.commit()
        needsLayout = true
    }

    // (2026-08-19 错位排查用的 debugGeometryDescription 已删——排查结案、全仓零调用,
    // 要再看几何直接在这里临时打印,别恢复一个常驻的死函数。)

    /// 把这一层原样搬进 SwiftUI —— 设置页那条菜单栏预览用它。
    ///
    /// 预览不再"仿"一遍菜单栏的样子,而是**直接用菜单栏本体这个视图**:同一套字体、同一张
    /// 长图、同一条 CAKeyframeAnimation。滚动速度/停留时长也来自同一个
    /// MenuBarMarqueeRenderer.presentation ——想让预览跟实际不一样都难。
    struct Representable: NSViewRepresentable {
        let text: String
        let windowWidth: CGFloat
        /// nil = 这一句装得下,静止显示(格子宽度照样是 windowWidth)。
        let pacing: MenuBarMarquee.ScrollPacing?
        /// 逐字染色边界路径(2026-08-22 加,给设置页预览用):nil = 这句不染
        /// (开关关着 / 没有逐字数据)。含义、构造方式跟 MenuBarStatusItem.karaokeFillPath
        /// 完全一样 —— 调用方(MenuBarPreviewBar)只在真的在播放且当前句有逐字数据时
        /// 才传非 nil,不为空闲时的示例句编造假时间轴(那样会跟其它预览的既有原则相悖,
        /// 见 SectionPreviewBars.swift 头注「不为示例句编造进度」那一段)。
        let fillPath: [MenuBarMarquee.KaraokeFillPoint]?
        /// 跟唱滚动的阅读位置路径(2026-09-04):nil = 这句没有逐字数据。含义、构造方式跟
        /// MenuBarStatusItem.followReadingPath 完全一样,同样不为示例句编造。
        let followPath: [MenuBarMarquee.KaraokeFillPoint]?
        /// 染色对表用的播放时钟快照,含义同 MenuBarStatusItem.syncKaraokeClock 的三个参数。
        let karaokePositionMs: Int?
        let karaokeRate: Double
        let karaokePlaying: Bool
        /// 歌词旁那枚带播放进度的图标(nil = 关着)。跟本体一样由调用方现读 AppSettings 传
        /// 进来 —— 预览这条路没有 MenuBarStatusItem 的订阅可蹭。
        let icon: IconBadge?
        /// 进度对表:位置**不含**歌词时间轴偏移(跟上面 karaokePositionMs 的区别就在这儿),
        /// 曲长 nil = 不知道这首歌多长。速率和播放态两条时钟共用同一份,不再重复传。
        let progressPositionMs: Int?
        let progressDurationMs: Int?

        func makeNSView(context: Context) -> MenuBarScrollingLabel { MenuBarScrollingLabel() }

        func updateNSView(_ view: MenuBarScrollingLabel, context: Context) {
            // ⚠️ 按**真实菜单栏**那一档的明暗渲染,不跟宿主(设置窗口)走。
            // 「跟随系统」的文字色是 `labelColor` 这个**动态色**,在浅色的设置窗口里解析出来
            // 是黑的,而菜单栏上是白的 —— 2026-09-03 用户报的"预览也是黑色"就是这个。
            // `NSView.appearance` 一设,内部那些 `effectiveAppearance` 取色的地方(rebuildImage /
            // karaokeFillColor)自然就换到这一档,不用给渲染路径另开参数。
            // 见 MenuBarAppearanceStore 头注。
            view.appearance = MenuBarAppearanceStore.shared.appearance
            // present 对"参数没变"是空操作,所以设置页每次重算 body 都不会把滚动打回开头。
            view.present(text: text, windowWidth: windowWidth, pacing: pacing, fillPath: fillPath,
                         followPath: followPath, icon: icon)
            // 预览实例不在 MenuBarStatusItem 的颜色订阅覆盖范围内,靠宿主 body 重算带一次
            // 重排 —— 用户在旁边拖「文字颜色」色轮时预览才跟手(重排一句位图 sub-ms 级)。
            view.refreshColors()
            // 对表同理:预览没有自己的 anchor/pausedPositionMs 订阅链,靠宿主 body 重算
            // 把最新播放时钟带进来 —— 内部漂移门保证这不会打断正在跑的填色动画。
            view.updateKaraokeClock(positionMs: karaokePositionMs, rate: karaokeRate,
                                    playing: karaokePlaying)
            view.updateProgressClock(positionMs: progressPositionMs,
                                     durationMs: progressDurationMs,
                                     rate: karaokeRate, playing: karaokePlaying)
        }
    }

    private func restartAnimation() {
        contentLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        guard let plan, let prepared else { return }
        let maxOffset = prepared.textWidth - plan.windowWidth
        // 跟唱滚动优先(2026-09-04):这句有逐字时间轴、且判定要滚,就按存底时钟装跟唱动画;
        // 下面的时间配速只给没有逐字数据的句子兜底。
        if applyFollowScroll() { return }
        guard let pacing = plan.pacing,
              let frames = MenuBarMarquee.scrollKeyframes(
                maxOffset: maxOffset,
                pointsPerSecond: pacing.pointsPerSecond,
                headHoldSeconds: pacing.headHoldSeconds,
                tailHoldSeconds: pacing.tailHoldSeconds)
        else {
            // 两种情况会走到这儿:这一句本来就装得下(pacing == nil,固定宽度下这是常态),
            // 或者调用方判断"要滚"和这里算出来的不一致(比如宽度刚好卡在边界)。
            // 都是静止的,别留一条跑不起来的动画。
            //
            // 静止时的横向落点 = 「对齐模式」(2026-09-01)。slack 是格子比文字宽出来的那段;
            // maxOffset = textWidth - windowWidth,所以装得下时它是负的,slack 取 -maxOffset。
            // **放不下时 slack 恒为 0**,三个选项都退回 x=0 —— 文字比格子宽,没有位置可挪
            // (这也正是设置界面只在固定宽度模式下露出这一行的同一个道理,见
            // LyricsRestingAlignment 头注)。
            //
            // ⚠️ 只动 contentLayer 就够了:染色那两个裁剪层(baseClipLayer/fillClipLayer)是
            // 它的**子层**(见文件头「图层结构」),跟着一起平移,填色几何一个数都不用改。
            let slack = max(0, -maxOffset)
            let alignedX: CGFloat
            switch plan.alignment {
            case .leading: alignedX = 0
            case .center: alignedX = (slack / 2).rounded()
            case .trailing: alignedX = slack.rounded()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.position = CGPoint(x: alignedX, y: contentLayer.position.y)
            CATransaction.commit()
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        // 偏移量是"文字往左走多少",落到 position.x 上就是负的。
        animation.values = frames.offsets.map { NSNumber(value: Double(-$0)) }
        animation.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
        animation.calculationMode = .linear
        animation.duration = frames.duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        contentLayer.add(animation, forKey: Self.scrollAnimationKey)
    }

    // MARK: - 跟唱滚动(2026-09-04)

    /// 有逐字时间轴时按存底时钟(重新)装滚动动画:偏移是播放位置的函数(见
    /// MenuBarMarquee.followScrollPath),所以它跟填色一样挂在 karaokeClock 上,换句 / 对表 /
    /// 暂停都从这里重装。返回 false = 这一句不走跟唱(没有逐字数据、或判定不用滚),调用方
    /// 回落到时间配速;此时**不碰**现有动画。
    ///
    /// 跟 restartAnimation 的时间配速那条同一个动画键:任一时刻内容层上只有一条滚动动画,
    /// clear() / clearLyricsKeepingIcon() 摘的也是它。播放中装从"此刻"到唱完的剩余关键帧,
    /// fillMode=forwards 停在末端不循环(唱到哪滚到哪,唱完就该换句了);暂停 / 已唱完 /
    /// 还没对表就静置在此刻该有的偏移上。
    @discardableResult
    private func applyFollowScroll() -> Bool {
        guard let plan, let prepared, plan.pacing != nil, let reading = plan.followPath else {
            return false
        }
        let path = MenuBarMarquee.followScrollPath(
            reading: reading, windowWidth: plan.windowWidth, textWidth: prepared.textWidth)
        guard !path.isEmpty else { return false }
        contentLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // 偏移量是"文字往左走多少",落到 position.x 上就是负的。
        func rest(at offset: CGFloat) {
            contentLayer.position = CGPoint(x: -offset, y: contentLayer.position.y)
        }
        guard let clock = karaokeClock else {
            // 还没对表:停在开头。showFixedWidth 紧接着就会 force 对一次表,那时再装。
            rest(at: 0)
            return true
        }
        let nowMs = clock.positionMs()
        if clock.playing, clock.rate > 0,
           let frames = MenuBarMarquee.followScrollKeyframes(path: path, nowMs: nowMs,
                                                             rate: clock.rate) {
            // 模型值直接放终态(动画 fillMode=forwards 盖着;动画一旦被摘,这句也已唱完,
            // 终态正确)—— 跟 applyKaraokeFill 同一手法。
            rest(at: frames.widths.last ?? 0)
            let animation = CAKeyframeAnimation(keyPath: "position.x")
            animation.values = frames.widths.map { NSNumber(value: Double(-$0)) }
            animation.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
            animation.calculationMode = .linear
            animation.duration = frames.duration
            animation.beginTime = contentLayer.convertTime(CACurrentMediaTime(), from: nil)
            animation.isRemovedOnCompletion = false
            animation.fillMode = .forwards
            contentLayer.add(animation, forKey: Self.scrollAnimationKey)
        } else {
            rest(at: MenuBarMarquee.followScrollOffset(atMs: nowMs, path: path))
        }
        return true
    }

    // MARK: - 逐字染色

    /// 按当前 plan + 存底时钟(重新)装填色。所有出口都先摘旧动画:换句/暂停/对表重锚,
    /// 旧动画描述的都是过去那套时间轴。
    ///
    /// 两个裁剪层做**互补**运动(白边教训见文件头注):fillClip 露出 [0, 边界],baseClip
    /// 露出 [边界, 句尾]。baseClip 的几何关系:anchorPoint 零 + position.x 与
    /// bounds.origin.x 同为边界值 —— frame 落在 [边界, 句尾],而 bounds 原点同步右移让
    /// 里面的 textLayer 在 contentLayer 坐标系里纹丝不动。
    ///
    /// 播放中:从"此刻"到这行唱完编成三条**共享 beginTime/keyTimes** 的 CAKeyframeAnimation
    /// (fillClip 的 bounds.size.width、baseClip 的 position.x 和 bounds),
    /// fillMode=forwards 停在全填,不循环 —— 一句只染一遍,染完保持,跟歌词语义一致。
    /// 暂停/时钟缺失/已唱完:静置在此刻该有的边界上(karaokeFillX)。
    /// 不染(开关关/无逐字/反白):fillClip 隐藏,baseClip 复位成全宽 —— 基础字永远经由
    /// baseClip 显示,这个复位是所有"不染"路径的必经出口。
    private func applyKaraokeFill() {
        fillClipLayer.removeAnimation(forKey: Self.fillAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.basePositionAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.baseBoundsAnimationKey)
        let textWidth = prepared?.textWidth ?? 0
        let height = prepared?.pointHeight ?? MenuBarMarqueeRenderer.lineHeight
        func baseRect(_ boundary: CGFloat) -> CGRect {
            CGRect(x: min(boundary, textWidth), y: 0,
                   width: max(0, textWidth - boundary), height: height)
        }
        func setBoundary(_ boundary: CGFloat) {
            fillClipLayer.bounds = CGRect(x: 0, y: 0, width: max(0, boundary), height: height)
            baseClipLayer.position = CGPoint(x: min(boundary, textWidth), y: 0)
            baseClipLayer.bounds = baseRect(boundary)
        }
        guard let plan, let path = plan.fillPath, !path.isEmpty,
              prepared != nil, !highlighted, let clock = karaokeClock else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillClipLayer.isHidden = true
            setBoundary(0)
            CATransaction.commit()
            return
        }
        let nowMs = clock.positionMs()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillClipLayer.isHidden = false
        if clock.playing, clock.rate > 0,
           let frames = MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: nowMs,
                                                            rate: clock.rate) {
            // 模型值直接放终态(动画 fillMode=forwards 盖着;动画一旦被摘,这行也已唱完,
            // 终态正确)。
            setBoundary(frames.widths.last ?? 0)
            let keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
            // 三条动画显式共享同一个 beginTime:互补裁剪的两边要是差半帧,边界处会闪出
            // 一条双色缝或一条空缝。
            let start = fillClipLayer.convertTime(CACurrentMediaTime(), from: nil)
            func install(_ keyPath: String, _ values: [Any], on layer: CALayer, key: String) {
                let animation = CAKeyframeAnimation(keyPath: keyPath)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.calculationMode = .linear
                animation.duration = frames.duration
                animation.beginTime = start
                animation.isRemovedOnCompletion = false
                animation.fillMode = .forwards
                layer.add(animation, forKey: key)
            }
            install("bounds.size.width",
                    frames.widths.map { NSNumber(value: Double($0)) },
                    on: fillClipLayer, key: Self.fillAnimationKey)
            install("position.x",
                    frames.widths.map { NSNumber(value: Double(min($0, textWidth))) },
                    on: baseClipLayer, key: Self.basePositionAnimationKey)
            install("bounds",
                    frames.widths.map { NSValue(rect: baseRect($0)) },
                    on: baseClipLayer, key: Self.baseBoundsAnimationKey)
        } else {
            // 暂停 / 已唱完:静止停在此刻该有的边界。
            setBoundary(MenuBarMarquee.karaokeFillX(atMs: nowMs, path: path))
        }
        CATransaction.commit()
    }

    // MARK: - 整首歌的进度(歌词旁那枚图标)

    /// 按当前 plan + 存底时钟(重新)装进度填色。跟上面 `applyKaraokeFill` **逐条对称**,
    /// 只是两处换了:横向换成纵向(用户选的"下→上,像水位"),按词边界分段的关键帧换成
    /// **一条匀速动画**(整首歌的进度本来就是匀速的,不需要分段)。
    ///
    /// 两个裁剪层同样做**互补**运动 —— 文件头注那条"白边"教训对图标一字不改地成立:两张
    /// 同字形的图叠着画,边缘的半透明像素会让底下那张透出来,深色菜单栏上就镶一圈白晕。
    /// fillClip 露出 [底, 边界],baseClip 露出 [边界, 顶];baseClip 的几何关系 =
    /// anchorPoint 零 + position.y 与 bounds.origin.y 同为边界值,让里面的 iconBaseLayer
    /// 在 host 坐标系里纹丝不动。
    ///
    /// 播放中:一条从此刻到放完的线性动画,fillMode=forwards 停在满格、不循环。
    /// 暂停 / 曲长未知 / 菜单反白:静置(曲长未知就是 0,也就是整枚基础色,不假装有进度)。
    private func applyProgressFill() {
        iconFillClipLayer.removeAnimation(forKey: Self.iconFillAnimationKey)
        iconBaseClipLayer.removeAnimation(forKey: Self.iconBasePositionAnimationKey)
        iconBaseClipLayer.removeAnimation(forKey: Self.iconBaseBoundsAnimationKey)
        guard let icon = preparedIcon else { return }
        let w = icon.base.size.width
        let h = icon.base.size.height
        func baseRect(_ boundary: CGFloat) -> CGRect {
            CGRect(x: 0, y: min(boundary, h), width: w, height: max(0, h - boundary))
        }
        func setBoundary(_ boundary: CGFloat) {
            iconFillClipLayer.bounds = CGRect(x: 0, y: 0, width: w, height: max(0, boundary))
            iconBaseClipLayer.position = CGPoint(x: 0, y: min(boundary, h))
            iconBaseClipLayer.bounds = baseRect(boundary)
        }
        // 所有"不染"路径的必经出口:填色层隐掉、baseClip 复位成整枚 —— 基础图**永远**经由
        // baseClip 显示,漏了这一步就是"关掉进度之后图标只剩上半截"。
        guard !highlighted, let clock = progressClock, clock.durationMs > 0 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            iconFillClipLayer.isHidden = true
            setBoundary(0)
            CATransaction.commit()
            return
        }
        let nowMs = clock.positionMs()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconFillClipLayer.isHidden = false
        if let ramp = MenuBarMarquee.progressFillRamp(
            positionMs: nowMs, durationMs: clock.durationMs,
            rate: clock.playing ? clock.rate : 0, fullLength: h) {
            // 模型值直接放终态(动画 fillMode=forwards 盖着;动画一旦被摘,这首歌也已经
            // 放完了,终态正确)。
            setBoundary(ramp.to)
            // 三条动画显式共享同一个 beginTime:互补裁剪的两边差半帧,边界处就会闪出一条
            // 双色缝或空缝(同逐字染色那三条)。
            let start = iconFillClipLayer.convertTime(CACurrentMediaTime(), from: nil)
            func install(_ keyPath: String, from: Any, to: Any, on layer: CALayer, key: String) {
                let animation = CABasicAnimation(keyPath: keyPath)
                animation.fromValue = from
                animation.toValue = to
                animation.duration = ramp.duration
                animation.beginTime = start
                // ⚠️ CABasicAnimation 默认曲线是 easeInEaseOut,**必须**显式给线性:这条
                // 动画一铺就是整首歌好几分钟,默认曲线会让进度开头爬得极慢、中间冲一下、
                // 结尾又慢下来 —— 那不是"进度条"。(逐字染色那三条是 CAKeyframeAnimation
                // 且显式设了 calculationMode = .linear,不吃这个默认值。)
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                animation.isRemovedOnCompletion = false
                animation.fillMode = .forwards
                layer.add(animation, forKey: key)
            }
            install("bounds.size.height",
                    from: NSNumber(value: Double(ramp.from)),
                    to: NSNumber(value: Double(ramp.to)),
                    on: iconFillClipLayer, key: Self.iconFillAnimationKey)
            install("position.y",
                    from: NSNumber(value: Double(min(ramp.from, h))),
                    to: NSNumber(value: Double(min(ramp.to, h))),
                    on: iconBaseClipLayer, key: Self.iconBasePositionAnimationKey)
            install("bounds",
                    from: NSValue(rect: baseRect(ramp.from)),
                    to: NSValue(rect: baseRect(ramp.to)),
                    on: iconBaseClipLayer, key: Self.iconBaseBoundsAnimationKey)
        } else {
            // 暂停 / 已放完:静止停在此刻该有的边界。
            setBoundary(MenuBarMarquee.progressFillLength(
                positionMs: nowMs, durationMs: clock.durationMs, fullLength: h))
        }
        CATransaction.commit()
    }
}
