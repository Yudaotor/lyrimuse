import AppKit
import LyrimuseCore
import QuartzCore

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
//          └ textLayer  (contents = 整句长图,动的就是它的 position.x)
//
// 用两层而不是"直接给 self.layer 设 contents":文字要能滚出可视区并被裁掉,而可视区
// 的位置得跟按钮里 image 的绘制位置对齐(见 layout())。分成两层之后,layout 只碰
// clipLayer、动画只碰 textLayer,两者互不干扰 —— 尤其是**换颜色时不能打断正在跑的滚动**
// (见 rebuildImage:只换 contents 和 bounds,绝不碰 position/动画)。
@MainActor
final class MenuBarScrollingLabel: NSView {
    private static let scrollAnimationKey = "lyrimuse.marquee"

    private let clipLayer = CALayer()
    private let textLayer = CALayer()

    /// 一句歌词的滚动参数。只有它变了才重排版 + 重启动画;换颜色不动它。
    private struct Plan: Equatable {
        var text: String
        var windowWidth: CGFloat
        var pointsPerSecond: CGFloat
        var holdSeconds: Double
    }

    private var plan: Plan?
    private var prepared: MenuBarMarqueeRenderer.PreparedLine?
    private var highlighted = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        clipLayer.masksToBounds = true
        // anchorPoint 归零之后 position 就等于左下角,layout/动画里算坐标不用再折算半个尺寸。
        clipLayer.anchorPoint = .zero
        textLayer.anchorPoint = .zero
        clipLayer.addSublayer(textLayer)
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
    func present(text: String, windowWidth: CGFloat,
                 pointsPerSecond: CGFloat, holdSeconds: Double) {
        let next = Plan(text: text, windowWidth: windowWidth,
                        pointsPerSecond: pointsPerSecond, holdSeconds: holdSeconds)
        guard next != plan else {
            isHidden = false
            return
        }
        plan = next
        isHidden = false
        rebuildImage()
        restartAnimation()
        needsLayout = true
    }

    /// 退出滚动模式(这一句装得下、菜单栏歌词关掉、或者没在播放)。
    /// 必须真的把动画摘掉:留一条 repeatCount = .infinity 的动画在隐藏图层上,
    /// 渲染层会一直为它做无用功。
    func clear() {
        guard plan != nil || !isHidden else { return }
        plan = nil
        prepared = nil
        textLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contents = nil
        CATransaction.commit()
        isHidden = true
    }

    /// 菜单打开/关闭。只换文字颜色,**不碰**正在跑的滚动动画 —— 点开菜单看一眼再关掉,
    /// 歌词该滚到哪儿还在哪儿。
    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        rebuildImage()
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
        let x = ((bounds.width - plan.windowWidth) / 2).rounded()
        let y = ((bounds.height - height) / 2).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.frame = CGRect(x: x, y: y, width: plan.windowWidth, height: height)
        // 只写 y。x 由动画接管,这里碰它会跟滚动打架。
        textLayer.position = CGPoint(x: textLayer.position.x, y: 0)
        CATransaction.commit()
    }

    private var tintColor: NSColor {
        // 菜单打开时状态栏项整块反白,文字得跟着变 —— 这正是以前用模板图时系统免费
        // 帮我们做的那件事,自己拿图层之后要自己做。
        highlighted ? .selectedMenuItemTextColor : .labelColor
    }

    /// 按当前颜色重排这一句。**不重启动画**:图片尺寸只跟文字+字体有关,颜色变了尺寸不变,
    /// 所以换 contents 是安全的,position 和动画原封不动。
    private func rebuildImage() {
        guard let plan else { return }
        let color = tintColor
        var built: MenuBarMarqueeRenderer.PreparedLine?
        // ⚠️ labelColor/selectedMenuItemTextColor 是**动态**颜色,真正解析成 RGB 是在
        // 绘制那一刻按"当前绘制 appearance"决定的。不套这一层的话,深色菜单栏上会画出
        // 一行几乎看不见的深色字(取决于 App 自己的 appearance,而不是菜单栏的)。
        effectiveAppearance.performAsCurrentDrawingAppearance {
            built = MenuBarMarqueeRenderer.prepare(text: plan.text, color: color)
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
        CATransaction.commit()
        needsLayout = true
    }

    private func restartAnimation() {
        textLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        guard let plan, let prepared else { return }
        let maxOffset = prepared.textWidth - plan.windowWidth
        guard let frames = MenuBarMarquee.scrollKeyframes(
            maxOffset: maxOffset,
            pointsPerSecond: plan.pointsPerSecond,
            holdSeconds: plan.holdSeconds)
        else {
            // 走到这里说明调用方判断"要滚"和这里算出来的不一致(比如宽度刚好卡在边界)。
            // 静止停在开头,别留一条跑不起来的动画。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            textLayer.position = CGPoint(x: 0, y: textLayer.position.y)
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
        textLayer.add(animation, forKey: Self.scrollAnimationKey)
    }
}
