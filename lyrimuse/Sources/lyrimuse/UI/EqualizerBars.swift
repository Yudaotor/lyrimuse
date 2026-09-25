import AppKit
import Foundation
import QuartzCore
import SwiftUI
import LyrimuseCore

// 灵动岛左耳歌名前面那几根"跳动的均衡条"——纯装饰性的播放指示器,不是真的频谱。
//
// 名字叫均衡条,但它跟音频数据没有任何关系,也不该有:拿到真实频谱需要 CoreAudio 抓
// 系统输出(要么装虚拟声卡,要么申请录屏/录音权限),对一个"显示歌词"的 App 来说代价完全
// 不成比例。被参考的那个 fork 的 README 宣称有频谱,读代码发现它的 visualizer.metal 根本
// 没进编译清单,实际画的也是随机动画 —— 这里不重复那种宣称,注释和 UI 文案都只说"播放
// 指示",不说"频谱"。
//
// 条高的**振幅**由逐字歌词时间轴调制(`amplitude` 闭包),所以它确实跟着歌在动 —— 但
// 驱动它的是"这一刻有没有字正在唱",不是音频。这是 lyrimuse 相对那类抓音频的实现的
// 便宜之处:逐字时间轴本来就在手上(LyricsSyncEngine 解析出的 words 带真实起止毫秒),
// 等于白拿一个跟人声同步的包络,零权限、零新数据源、零常驻音频线程。
//
// 形状(每根条子此刻多高)全在 `EqualizerBarCurve`(LyrimuseCore,selftest 钉住):每根
// 一条自己的连续曲线、速度按条序拉开,平滑地各走各的。别给它们加一个全组共享的节奏源
// —— 那样五根会同时顶起同时压低,整排一起抽;理由与实测数字见那个文件的头注。
//
// ## 性能:整段关键帧交给 Core Animation,主线程不按帧参与
//
// 之前是 SwiftUI `TimelineView(.animation(minimumInterval: 1/30))` 每拍现算五根条高。条子只有
// 16×16pt,但 SwiftUI 里**任何一个**逐帧刷新的子视图都会让整个灵动岛窗口每拍走一遍
// NSHostingView 布局 + 显示列表 + 图层提交 —— 实测只开灵动岛、
// 播放中 15.5%,关掉音浪 8.9%:这五根条子一项就占 6.6 个百分点,而且播放期间永远不停
// (逐字填色一行填完会停表,音浪不会)。
//
// 现在:曲线(`EqualizerBarCurve`)和人声包络(`VocalEnvelope`)都是**时间的纯函数**,未来几秒的
// 条高此刻就算得出来。于是每次需要时一次性排好 `resyncSpan` 秒、每秒 `keyframeRate` 个点的
// 高度关键帧(`EqualizerBarCurve.keyframes`),五根条子各挂一条 `CAKeyframeAnimation`,之后由渲染
// 服务播,App 主线程不再醒。重排只在这几种时候发生:
//   - `resyncKey` 变了(调用方拼的:换行 / 锚点重发 / 本曲偏移调整)—— 包络依赖当前行的逐字
//     时间,位置基准一变旧的关键帧就对不上字了;
//   - 播放 / 暂停、入窗 / 离窗;
//   - 排好的这一段快播完了(`resyncSpan` 到点续排一段)。
// 主线程唤醒从每秒 30 次降到最多每几秒一次。
//
// 隐式补间的老坑(灵动岛 hover 展开时尺寸弹簧会接管条子位置,见旧版注释)在这里不存在:
// 条高动画挂在自己的图层上,SwiftUI 只管这块 NSView 的外框,弹簧平移的是整块视图而不是
// 条子的高度属性;图层的隐式动作也全部关掉了(见 `EqualizerBarsNSView.init`)。
struct EqualizerBars: View {
    var color: Color
    var isPlaying: Bool
    /// 位置基准变了、需要按新基准重排关键帧的那组输入的摘要(调用方拼:当前行 + 锚点 + 偏移)。
    /// 只拿来判"变没变",值本身没有含义。默认 0 = 只按 `isPlaying` 与定时续排重排。
    var resyncKey: Int = 0
    /// 某一时刻的"人声强度"(`VocalEnvelope`,0…1.25)。排关键帧时对未来的每个采样点各求一次。
    ///
    /// 闭包而不是值:要的是"这一段里每个时刻的值",不是父 body 重算那一刻的快照。闭包直读
    /// 协调器(当前行的逐字 + 锚点外推),跟逐字填色那几处"闭包直读协调器、不经代理订阅"
    /// 同一个模式。它只在**当前行**内准确 —— 换行时调用方的 `resyncKey` 会变,这里随即重排。
    ///
    /// 默认 `{ _ in 1 }` = 满幅,等价于加这个参数之前的行为。
    var amplitude: (Date) -> Double = { _ in 1 }

    /// 改成 iPhone 那种"上下对称、从中线生长"的声浪。
    ///
    /// 5 是两头的折中:对称形态下条太少读不出波形轮廓(4 根看着像四个孤立的胶囊),
    /// 而灵动岛这个尺寸下 8 根又密得糊成一团 —— 参考图里那 8 根是 iPhone 上更大的
    /// 控制中心卡片,直接照搬根数到这块只有 `NotchMetrics.collapsedEarWidth`(34pt)宽的
    /// 耳朵上并不成立。**改根数只需要动这一个常量**,`width` 和相位都是按它算的。
    fileprivate static let barCount = 5
    /// 比 iPhone 参考图里那簇细线略粗:那张图是控制中心的大卡片,同样的线宽放到灵动岛
    /// 耳朵这个尺寸上会细到发虚;5 根这么少的条数下太细还会显得稀疏。
    ///
    /// **条宽与间距都必须是 0.5pt 的整数倍**(2x 屏上落在整物理像素边界)。尤其
    /// **别让 `barWidth + spacing` 这个步距带零头**:步距不是整数像素时,五根条子各自落在
    /// 不同的亚像素相位上,光栅化会把它们交替舍入成不同宽度 —— 截图逐列亮度实测过一次
    /// 1.8 + 1.5(步距 3.3pt = 6.6px)的后果:五根的实际物理宽度是 3 / 4 / 3 / 4 / 4 px,
    /// 粗细肉眼可辨,而间隙一律 3px。现在 2.0(4px)+ 1.5(3px),步距 3.5pt = 7px 整。
    fileprivate static let barWidth: CGFloat = 2.0
    fileprivate static let spacing: CGFloat = 1.5
    /// 高度 16:耳朵这一行的高度
    /// 是 `NotchLyricsWindowController.contentTopInset`,实测下限是自动隐藏菜单栏时的
    /// `fallbackNotchHeight = 24`(外接屏常见 24~37pt);16pt 居中放进 24pt 高的行,
    /// 上下各留 4pt,跟同一行里 `earArtworkSide` 那枚封面缩略图的量级相当,不会顶到行
    /// 边界裁切。
    fileprivate static let maxHeight: CGFloat = 16
    /// 静止时的高度。不取 0 —— 归零会让整排条子消失成一条线,暂停时看着像出了故障。
    /// 对称形态下这是"中线上的一排小短横",跟 iPhone 暂停时的观感一致。
    ///
    /// 振幅只压缩"能跳多高",不动这条地板 —— 间奏/纯音乐时条子收敛成小幅晃动而不是趴平。
    /// 趴平的观感是"坏了",而这个元件的职责是"告诉你还在放"。
    fileprivate static let minHeight: CGFloat = 2.5

    /// 关键帧的采样率。跟原来 `TimelineView` 的 30Hz 同一个密度;渲染服务在相邻点之间线性插值,
    /// 实际观感比原来的 30Hz 阶梯更顺。起音脉冲的时间常数是 80ms(`VocalEnvelope.attackMs`),
    /// 33ms 一个点够抓住它。
    fileprivate static let keyframeRate: Double = 30
    /// 一次排多长。到点续排一段:短了白醒,长了换行之外的漂移(全局偏移改动、没有新锚点的长间奏)
    /// 要等更久才被校正。8 秒 = 主线程每 8 秒最多醒一次,比原来每秒 30 次少两个数量级。
    fileprivate static let resyncSpan: Double = 8

    static var width: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    }

    var body: some View {
        EqualizerBarsLayer(color: NSColor(color), isPlaying: isPlaying,
                           resyncKey: resyncKey, amplitude: amplitude)
            .frame(width: Self.width, height: Self.maxHeight)
            // 装饰元素,读屏软件念"2.5、7、4、9"没有任何意义。
            .accessibilityHidden(true)
    }
}

private struct EqualizerBarsLayer: NSViewRepresentable {
    let color: NSColor
    let isPlaying: Bool
    let resyncKey: Int
    let amplitude: (Date) -> Double

    func makeNSView(context: Context) -> EqualizerBarsNSView { EqualizerBarsNSView() }

    func updateNSView(_ view: EqualizerBarsNSView, context: Context) {
        view.amplitude = amplitude
        view.update(color: color, isPlaying: isPlaying, resyncKey: resyncKey)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EqualizerBarsNSView, context: Context) -> CGSize? {
        CGSize(width: EqualizerBars.width, height: EqualizerBars.maxHeight)
    }
}

/// 五根条子各一个纯色图层,圆角 = 半个条宽(胶囊);高度动画以中线为轴上下对称伸缩
/// (`anchorPoint` 在中心,只动 `bounds.size.height`)。
@MainActor
final class EqualizerBarsNSView: NSView {
    private static let animationKey = "lyrimuse.equalizer-bars"

    var amplitude: (Date) -> Double = { _ in 1 }

    private var bars: [CALayer] = []
    private var color: NSColor?
    private var isPlaying = false
    private var resyncKey: Int?
    /// 这一段快播完时续排下一段。只在"在播且在窗口里"时存在。
    private var renewTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for i in 0..<EqualizerBars.barCount {
            let bar = CALayer()
            bar.cornerRadius = EqualizerBars.barWidth / 2
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.bounds = CGRect(x: 0, y: 0, width: EqualizerBars.barWidth, height: EqualizerBars.minHeight)
            bar.position = CGPoint(
                x: CGFloat(i) * (EqualizerBars.barWidth + EqualizerBars.spacing) + EqualizerBars.barWidth / 2,
                y: EqualizerBars.maxHeight / 2)
            // 隐式动作全关:颜色 / 高度的每一次改动都是这里显式决定的,不能让 CA 顺手补一段 0.25s 的过渡。
            bar.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(color: NSColor, isPlaying: Bool, resyncKey: Int) {
        if self.color != color {
            self.color = color
            let cg = color.cgColor
            for bar in bars { bar.backgroundColor = cg }
        }
        guard self.isPlaying != isPlaying || self.resyncKey != resyncKey else { return }
        self.isPlaying = isPlaying
        self.resyncKey = resyncKey
        reinstall()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reinstall()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // 换到不同缩放的屏幕:纯色图层没有位图要重画,但圆角边缘按新的 contentsScale 光栅化。
        let scale = window?.backingScaleFactor ?? 2
        for bar in bars { bar.contentsScale = scale }
    }

    /// 按此刻的时钟重排一段关键帧(或者不在播 / 不在窗口里时落到地板、停掉续排)。
    private func reinstall() {
        renewTimer?.invalidate()
        renewTimer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for bar in bars { bar.removeAnimation(forKey: Self.animationKey) }
        guard isPlaying, window != nil else {
            for bar in bars { bar.bounds.size.height = EqualizerBars.minHeight }
            return
        }

        let span = EqualizerBars.resyncSpan
        let rate = EqualizerBars.keyframeRate
        let count = Int(span * rate) + 1
        let startDate = Date()
        let startRef = startDate.timeIntervalSinceReferenceDate
        let amplitude = self.amplitude
        let levels = EqualizerBarCurve.keyframes(
            barCount: EqualizerBars.barCount, start: startRef, step: 1 / rate, count: count,
            amplitude: { amplitude(Date(timeIntervalSinceReferenceDate: $0)) })
        let range = EqualizerBars.maxHeight - EqualizerBars.minHeight
        let mediaNow = CACurrentMediaTime()
        for (bar, series) in zip(bars, levels) {
            let heights = series.map { EqualizerBars.minHeight + range * CGFloat($0) }
            let anim = CAKeyframeAnimation(keyPath: "bounds.size.height")
            anim.values = heights
            anim.calculationMode = .linear
            anim.duration = span
            anim.beginTime = bar.convertTime(mediaNow, from: nil)
            // 播完停在最后一帧,等续排接上(续排比这一段结束早一点点,正常情况下看不到停顿)。
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            // 这段曲线本来就是 30Hz 采样的,合成器不必按屏幕刷新率(ProMotion 120Hz)去插值。
            anim.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            bar.add(anim, forKey: Self.animationKey)
            // 模型值落在这一段的最后一帧,动画被系统摘掉时也不会跳回地板。
            bar.bounds.size.height = heights.last ?? EqualizerBars.minHeight
        }

        let timer = Timer(timeInterval: span - 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reinstall() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        renewTimer = timer
    }
}
