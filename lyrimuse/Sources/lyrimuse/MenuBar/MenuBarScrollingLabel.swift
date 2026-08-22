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
//     └ clipLayer   (masksToBounds,尺寸/位置 = NSStatusBarButton 画 image 的那一块)
//          └ contentLayer  (滚动动画动的是它的 position.x)
//               ├ baseClipLayer  (masksToBounds,只露出**未唱**区 [边界, 句尾])
//               │    └ textLayer      (contents = 整句长图,基础色)
//               └ fillClipLayer  (masksToBounds,只露出**已唱**区 [0, 边界])
//                    └ fillTextLayer (contents = 同一句的强调色长图)
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

    private let clipLayer = CALayer()
    private let contentLayer = CALayer()
    private let baseClipLayer = CALayer()
    private let textLayer = CALayer()
    private let fillClipLayer = CALayer()
    private let fillTextLayer = CALayer()

    /// 一句歌词的滚动参数。只有它变了才重排版 + 重启动画;换颜色不动它。
    private struct Plan: Equatable {
        var text: String
        var windowWidth: CGFloat
        /// nil = 这一句装得下,静止显示。格子宽度照样是 windowWidth(固定宽度,见
        /// MenuBarMarqueeRenderer.presentation)。
        var pacing: MenuBarMarquee.ScrollPacing?
        /// 逐字染色的填色边界路径(nil = 这句没有逐字数据 / 开关关着,不染)。
        /// 路径是词时间轴的纯翻译,不含播放位置 —— 时钟另走 updateKaraokeClock。
        var fillPath: [MenuBarMarquee.KaraokeFillPoint]?
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
                 fillPath: [MenuBarMarquee.KaraokeFillPoint]? = nil) {
        let next = Plan(text: text, windowWidth: windowWidth, pacing: pacing, fillPath: fillPath)
        guard next != plan else {
            isHidden = false
            return
        }
        // 只有**位图内容会变**时才重排(2026-08-19,兑现 PreparedLine.color 注释承诺的那类
        // 幂等):位图内容只由 text+解析色+要不要染色决定,几何推迟落地这类"同一句只换
        // 槽宽/配速"的调用(interim → 重建落地)原来会把逐像素相同的长图白排一遍。颜色在
        // 本路径不变(highlighted/appearance 变化各有自己的入口,那两处照旧重画)。
        // fillPath 的**有无**参与判定(强调色那张图要不要排),路径数值本身不影响位图。
        let bitmapsUnchanged = prepared != nil && plan?.text == next.text
            && (plan?.fillPath != nil) == (next.fillPath != nil)
        plan = next
        isHidden = false
        if !bitmapsUnchanged { rebuildImage() }
        restartAnimation()
        // 换句/换路径后按存底时钟重装填色(时钟按墙钟外推,不用等下一次对表)。
        applyKaraokeFill()
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
            return
        }
        let next = KaraokeClock(baseMs: positionMs, rate: rate, playing: playing, capturedAt: Date())
        if !force, playing, let old = karaokeClock, old.playing, old.rate == rate,
           fillClipLayer.animation(forKey: Self.fillAnimationKey) != nil,
           abs(old.positionMs() - positionMs) < 250 {
            karaokeClock = next
            return
        }
        karaokeClock = next
        applyKaraokeFill()
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contents = nil
        fillTextLayer.contents = nil
        fillClipLayer.isHidden = true
        CATransaction.commit()
        isHidden = true
    }

    /// 菜单打开/关闭。只换文字颜色,**不碰**正在跑的滚动动画 —— 点开菜单看一眼再关掉,
    /// 歌词该滚到哪儿还在哪儿。反白期间逐字染色整个隐掉(基础字已换成选中色,强调色叠在
    /// 选中背景上要么撞色要么看不清,索性回到整行统一色,关掉菜单再恢复)。
    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        rebuildImage()
        applyKaraokeFill()
    }

    // 系统在浅色/深色之间切换时,labelColor 解析出来的是另一个值,得重画。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildImage()
    }

    // MARK: - 内部

    override func layout() {
        super.layout()
        guard let plan else { return }
        let height = prepared?.pointHeight ?? MenuBarMarqueeRenderer.lineHeight
        // 可视窗口跟 NSStatusBarButton 画 image 的位置对齐:水平居中 + 垂直居中。
        // 宽度用 plan.windowWidth 而不是 bounds.width —— 按钮比它宽一圈(系统给状态栏项
        // 留的左右内边距),文字必须落在中间那一块,否则会顶到相邻图标上。
        // 裁剪窗钳制在自身 bounds 内(2026-08-19):bounds 短暂陈旧(启动竞态/尺寸切换
        // 的一拍)时,原来的居中公式会算出大负数/大偏移,把可视窗甩到槽位外。
        let clipW = min(plan.windowWidth, bounds.width)
        let x = max(0, ((bounds.width - clipW) / 2).rounded())
        let y = ((bounds.height - height) / 2).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.frame = CGRect(x: x, y: y, width: clipW, height: height)
        // 只写 y。x 由滚动动画接管(动的是 contentLayer),这里碰它会跟滚动打架。
        contentLayer.position = CGPoint(x: contentLayer.position.x, y: 0)
        CATransaction.commit()
    }

    private var tintColor: NSColor {
        // 菜单打开时状态栏项整块反白,文字得跟着变 —— 这正是以前用模板图时系统免费
        // 帮我们做的那件事,自己拿图层之后要自己做。
        highlighted ? .selectedMenuItemTextColor : .labelColor
    }

    /// 染色用的强调色。跟随用户在系统设置里挑的颜色,但**深色菜单栏上向白提亮四成** ——
    /// 系统强调色按浅底设计,直接压在深底上亮度低于旁边的白色基础字,染过的反而更难读
    /// (2026-08-22 用户截图实测"看不清文字")。浅色菜单栏保持原样:深色文字旁边的饱和
    /// 强调色本来就够跳。动态色,必须在 performAsCurrentDrawingAppearance 里取值。
    private var karaokeFillColor: NSColor {
        let accent = NSColor.controlAccentColor
        guard effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else {
            return accent
        }
        return accent.blended(withFraction: 0.4, of: .white) ?? accent
    }

    /// 按当前颜色重排这一句。**不重启动画**:图片尺寸只跟文字+字体有关,颜色变了尺寸不变,
    /// 所以换 contents 是安全的,position 和动画原封不动(滚动**和**填色两条都是)。
    private func rebuildImage() {
        guard let plan else { return }
        let color = tintColor
        var built: MenuBarMarqueeRenderer.PreparedLine?
        var fillBuilt: MenuBarMarqueeRenderer.PreparedLine?
        // ⚠️ labelColor/selectedMenuItemTextColor 是**动态**颜色,真正解析成 RGB 是在
        // 绘制那一刻按"当前绘制 appearance"决定的。不套这一层的话,深色菜单栏上会画出
        // 一行几乎看不见的深色字(取决于 App 自己的 appearance,而不是菜单栏的)。
        effectiveAppearance.performAsCurrentDrawingAppearance {
            built = MenuBarMarqueeRenderer.prepare(text: plan.text, color: color)
            if plan.fillPath != nil {
                fillBuilt = MenuBarMarqueeRenderer.prepare(text: plan.text, color: karaokeFillColor)
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

        func makeNSView(context: Context) -> MenuBarScrollingLabel { MenuBarScrollingLabel() }

        func updateNSView(_ view: MenuBarScrollingLabel, context: Context) {
            // present 对"参数没变"是空操作,所以设置页每次重算 body 都不会把滚动打回开头。
            view.present(text: text, windowWidth: windowWidth, pacing: pacing)
        }
    }

    private func restartAnimation() {
        contentLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        guard let plan, let prepared else { return }
        let maxOffset = prepared.textWidth - plan.windowWidth
        guard let pacing = plan.pacing,
              let frames = MenuBarMarquee.scrollKeyframes(
                maxOffset: maxOffset,
                pointsPerSecond: pacing.pointsPerSecond,
                headHoldSeconds: pacing.headHoldSeconds,
                tailHoldSeconds: pacing.tailHoldSeconds)
        else {
            // 两种情况会走到这儿:这一句本来就装得下(pacing == nil,固定宽度下这是常态),
            // 或者调用方判断"要滚"和这里算出来的不一致(比如宽度刚好卡在边界)。
            // 都是静止停在开头,别留一条跑不起来的动画。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.position = CGPoint(x: 0, y: contentLayer.position.y)
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
}
