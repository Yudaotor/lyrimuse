import Foundation
import SwiftUI
import LyrimuseCore

// 灵动岛左耳歌名前面那几根"跳动的均衡条"——纯装饰性的播放指示器,不是真的频谱。
//
// ⚠️ 名字叫均衡条,但它跟音频数据没有任何关系,也不该有:拿到真实频谱需要 CoreAudio 抓
// 系统输出(要么装虚拟声卡,要么申请录屏/录音权限),对一个"显示歌词"的 App 来说代价完全
// 不成比例。被参考的那个 fork 的 README 宣称有频谱,读代码发现它的 visualizer.metal 根本
// 没进编译清单,实际画的也是随机动画 —— 这里不重复那种宣称,注释和 UI 文案都只说"播放
// 指示",不说"频谱"。
//
// 2026-08-22:条高的**振幅**改由逐字歌词时间轴调制(`amplitude` 闭包),所以它现在确实
// 跟着歌在动 —— 但驱动它的是"这一刻有没有字正在唱",不是音频。这是 lyrimuse 相对那类
// 抓音频的实现的便宜之处:逐字时间轴本来就在手上(LyricsSyncEngine 解析出的 words 带
// 真实起止毫秒),等于白拿一个跟人声同步的包络,零权限、零新数据源、零常驻音频线程。
// 形状(哪根跳多高)仍是伪随机 —— 那部分本来就不该假装有物理意义。
//
// 性能:用 .animation(minimumInterval:) 而不是裸的 .animation。后者是每帧(60/120Hz)重算
// 一次 body,而这个视图常驻在屏幕顶端 —— 这个 App 已经有一条 20Hz 的逐字填色热路径了,
// 不该再挂一条更热的纯装饰路径上去。给了 minimumInterval 之后 0.28 秒才重算一次、换一个
// 目标高度,中间的过渡交给隐式动画在 Core Animation 那边跑(不经过 SwiftUI 重算)。
//
// ⚠️ 不能用 .periodic:它没有 paused 参数,暂停时条子会一直跳。
struct EqualizerBars: View {
    var color: Color
    var isPlaying: Bool
    /// 这一刻的"人声强度",0...1。在 TimelineView 的每个 tick 上求值一次(不是每帧 ——
    /// tick 频率仍是 `interval`,见下面的性能注释,**不要**为了更跟手去提高它)。
    ///
    /// 闭包而不是值:值只会在父 body 重算时更新,而父 body 的重算时机跟这个视图自己的
    /// tick 完全对不上,表现就是"唱了一整行条子的幅度纹丝不动"。闭包让它在 tick 那一刻
    /// 直读当下的播放状态,跟逐字填色那几处"闭包直读协调器、不经代理订阅"是同一个模式。
    ///
    /// 默认 `{ _ in 1 }` = 满幅,等价于加这个参数之前的行为。
    var amplitude: (Date) -> Double = { _ in 1 }

    /// 求一次高度的间隔。
    ///
    /// 2026-08-23 从 0.28 降到 0.10(用户反馈"跳动比较机械感,能不能顺滑一点、频率快一些")。
    /// 旧注释说"再快就显得毛躁、跟音乐没关系的抖动感很强" —— 那个结论是**跟旧的随机高度
    /// 绑在一起**的:相邻 tick 的目标值互不相关,越快抖得越凶。换成下面的连续函数之后,
    /// 快反而是顺滑的前提(采样越密,越贴近那条连续曲线)。
    ///
    /// 2026-09-01 再从 0.10 降到 0.08(用户反馈"动的幅度太小、不够动感",连同下面的
    /// `maxHeight`/频率一起调):下面两个频率常量整体调高了约 25%,采样率跟着同比例
    /// 提高,保持"每个周期的采样点数"跟调之前基本一致——否则只提频率不提采样率,最快那根
    /// 条子(bar 4)会退回到 2026-08-23 之前那种"稀疏采样、线性补间啃出棱角"的机械感,
    /// 等于白改。
    ///
    /// ⚠️ 这**没有**推翻 2026-08-19 的性能结论。那条说的是"补间时长不能等于间隔,否则
    /// 尺寸动画 100% 时间在跑、把窗口钉死在持续合成状态";这里补间仍然只占半个周期
    /// (见 body 末尾),每个周期照样有一半时间完全静止,合成循环该 idle 还是 idle。变的
    /// 只是**求值频率**:3.6Hz → 10Hz → 12.5Hz,仍远低于逐字填色那条 30Hz 的热路径。
    private static let interval: TimeInterval = 0.08
    /// 2026-08-31 改成 iPhone 那种"上下对称、从中线生长"的声浪。条数几经调整:4(原始)
    /// → 8(照参考图) → **5**(用户看过 8 根的实机效果后说"太多了")。
    ///
    /// 5 是两头的折中:对称形态下条太少读不出波形轮廓(4 根看着像四个孤立的胶囊),
    /// 而灵动岛这个尺寸下 8 根又密得糊成一团 —— 参考图里那 8 根是 iPhone 上更大的
    /// 控制中心卡片,直接照搬根数到这块只有 `NotchMetrics.collapsedEarWidth`(34pt)宽的
    /// 耳朵上并不成立。**改根数只需要动这一个常量**,`width` 和相位都是按它算的。
    private static let barCount = 5
    /// 每根条子的相位偏移,按**黄金角**(≈2.39996 rad)递推。
    ///
    /// 等分相位会让条子呈现肉眼可辨的"波浪依次推过去"的规律感,那是另一种机械感;黄金角
    /// 是最"不成简单分数比"的分割,**任意根数**都不会出现相位重合或整齐推进。原来是手写的
    /// 无理数数组 `[0, 1.9, 3.4, 5.1]`,只够 4 根用;换成公式之后调根数不用连带重挑相位
    /// (思路跟菜单栏图标那套音条 `MenuBarLiveIconView.barPhases` 一致)。
    private static func barPhase(_ i: Int) -> Double { Double(i) * 2.399963 }
    /// 比 iPhone 参考图里那簇细线略粗:那张图是控制中心的大卡片,同样的线宽放到灵动岛
    /// 耳朵这个尺寸上会细到发虚。减到 5 根之后又回调了一点(1.6 → 1.8),条少了太细会显得稀疏。
    private static let barWidth: CGFloat = 1.8
    private static let spacing: CGFloat = 1.5
    /// 2026-09-01 从 11 提到 16(用户反馈"动的幅度太小、不够动感")。耳朵这一行的高度
    /// 是 `NotchLyricsWindowController.contentTopInset`,实测下限是自动隐藏菜单栏时的
    /// `fallbackNotchHeight = 24`(外接屏常见 24~37pt);16pt 居中放进 24pt 高的行,
    /// 上下各留 4pt,跟同一行里 `earArtworkSide` 那枚封面缩略图的量级相当,不会顶到行
    /// 边界裁切。
    private static let maxHeight: CGFloat = 16
    /// 静止时的高度。不取 0 —— 归零会让整排条子消失成一条线,暂停时看着像出了故障。
    /// 对称形态下这是"中线上的一排小短横",跟 iPhone 暂停时的观感一致。
    private static let minHeight: CGFloat = 2.5

    static var width: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.interval, paused: !isPlaying)) { context in
            // 直接用**连续**的时间戳,不再取整成 tick。高度现在是时间的连续函数(见 height),
            // 取整反而会把曲线切成阶梯。仍然从时间戳推而不是自己维护累加器:TimelineView 在
            // 窗口不可见/paused 期间不保证按时给点,累加器会漂,时间戳则任何时候重建视图都
            // 接得上同一条曲线。
            let t = context.date.timeIntervalSinceReferenceDate
            // 每次求一次,四根条子共用 —— 它描述的是"此刻",跟是哪根条子无关。
            let amp = amplitude(context.date)
            // ⚠️ 2026-08-31 从 .bottom 改成 .center(用户给了 iPhone 锁屏「正在播放」那个
            // 声浪的参考图):条子不再"立在地面上往上长",而是**以中线为轴上下对称地伸缩**。
            // 这是这次改动唯一真正改变形态的一行 —— 条数/粗细/间距都只是为了配合它。
            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: Self.barWidth, height: height(bar: i, time: t, amplitude: amp))
                }
            }
            .frame(width: Self.width, height: Self.maxHeight, alignment: .center)
            // 补间时长只取间隔的一半(2026-08-19 性能审计):原来 duration == interval,
            // 上一次高度补间刚结束下一 tick 就到,首尾相接零空档 —— 播放期间这 4 根
            // 胶囊的尺寸动画 100% 时间在跑,把整个灵动岛窗口钉死在持续动画/持续合成
            // 状态(body 重算确实被 minimumInterval 压到了 3.6Hz,但合成频率仍是满帧)。
            // 减半后每个周期有一半时间完全静止,合成循环能间歇 idle;观感仍是跳动的条,
            // 只是每跳快一点、停一下 —— 反而更像"拍点"。
            // ⚠️ `value:` 必须是随时间变的那个量。以前是离散的 tick,现在没有 tick 了,
            // 改用"第一根条子此刻的高度"当变化信号 —— 它每次求值都不同,等价于每个周期
            // 触发一次补间。
            //
            // 曲线从 easeInOut 换成 linear:目标值本身已经是连续曲线上的采样点,再套
            // ease 会在每个采样点两端各加一次加减速,反而把平滑的正弦啃成一段段的"顿挫"
            // —— 那正是"机械感"的另一半来源。linear 把相邻采样点直连,12.5Hz 下就是这条
            // 曲线的分段线性逼近,肉眼即连续。
            //
            // 时长仍是半个周期(0.04s),不是整个周期 —— 见 interval 注释里对 2026-08-19
            // 那条性能结论的说明。
            .animation(.linear(duration: Self.interval * 0.5), value: height(bar: 0, time: t, amplitude: amp))
            .animation(.easeInOut(duration: Self.interval), value: isPlaying)
        }
        .frame(width: Self.width, height: Self.maxHeight)
        // 装饰元素,读屏软件念"2.5、7、4、9"没有任何意义。
        .accessibilityHidden(true)
    }

    /// 条高 = 双正弦叠加的连续函数 × 振幅。
    ///
    /// **为什么不再用伪随机**(2026-08-23 换掉):旧实现按 (bar, tick) 做 splitmix64 散列,
    /// 相邻两个 tick 的目标值完全无关 —— 于是每 0.28s 硬跳到一个不相干的高度,补间再怎么
    /// 调都是"抽一下、停一下",这就是用户说的机械感。散列当时解决的是另一个问题
    /// (`Double.random` 会让同一个 tick 每次重算 body 得到不同结果,导致无缘无故抽动),
    /// 而连续函数天然也是纯函数、同样没有那个问题,顺便把机械感一起解决了。
    ///
    /// **为什么是双正弦**:单个正弦四根条子会整齐地波浪推过去,一眼看出是假的;两个频率
    /// 不成简单整数比的正弦叠加,周期长到肉眼认不出重复。这跟菜单栏图标那套音条
    /// (`MenuBarLiveIconView.buildEqualizer`,注释原文「双正弦打破机械感」)是同一个手法,
    /// 保持两处观感一致。
    ///
    /// 频率取 2.2/3.6 Hz 附近并按条序错开:整体节奏接近中速歌曲的拍点,又不跟任何真实
    /// 节拍同步(它本来就与音频无关,装成对得上反而是虚假承诺)。
    ///
    /// 2026-09-01 从 1.7/2.9 调到 2.2/3.6(连同上面 `maxHeight`/`interval` 一起,回应
    /// "动的幅度太小、不够动感"):两个频率同比例调高约 25%(比值仍是 3.6/2.2≈1.64,
    /// 跟原来的 2.9/1.7≈1.71 一样不成简单整数比,保留"两两错开、不会看出规律"的性质),
    /// `interval` 同比例从 0.10 降到 0.08 保持采样密度,不然只提频率会让最快那根条子
    /// 露出线性补间的棱角。
    private func height(bar: Int, time: Double, amplitude: Double) -> CGFloat {
        guard isPlaying else { return Self.minHeight }
        let phase = Self.barPhase(bar)
        let f1 = 2.2 + Double(bar) * 0.34
        let f2 = 3.6 + Double(bar) * 0.26
        let raw = 0.62 * sin(time * f1 + phase) + 0.38 * sin(time * f2 + phase * 1.7)
        // raw ∈ [-1, 1] → [0, 1]
        let unit = (raw + 1) / 2
        // 振幅只压缩"能跳多高",不动地板 —— minHeight 那条线永远在,间奏/纯音乐时条子
        // 收敛成小幅晃动而不是趴平。趴平的观感是"坏了",而这个元件的职责是"告诉你还在放"。
        //
        // 2026-09-02:夹取从「先夹振幅再乘曲线」改成「乘完再夹」。VocalEnvelope 在字起音那一拍
        // 会给到 1.25——以前 min(1, amplitude) 直接把它吃掉,起音脉冲根本显示不出来;乘完再夹的
        // 效果是起音那一刻更多条子顶到 maxHeight 上限、然后回落,那就是 kick,高度永远不超上限。
        //
        // 2026-09-03:unit 先过 smoothstep 对比曲线再乘振幅(`EqualizerBarCurve`,LyrimuseCore,
        // 用户拍板的「小幅压平、大幅拉伸」版本)。曲线在 0.5 处不动,所以均值高度不变、不会重演
        // 「幅度太小」;变的是顶满与贴地的时间占比,数字与被否掉的 ease-in / 逐柱轮廓的理由见那个
        // 文件的头注。
        let scaled = EqualizerBarCurve.level(unit: unit, amplitude: amplitude)
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * CGFloat(scaled)
    }
}
