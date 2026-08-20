import CoreGraphics
import Foundation

// 菜单栏歌词的跑马灯取窗算法(2026-08-05 加,点子来自 FlowX/Kadxy/FlowX——它的菜单栏
// 歌词超宽时会横向滚动,而不是像我们原来那样直接截断成"前 N 个字…")。
//
// ⚠️ 历史(2026-08-05 ~ 08-16):这里原来只有 scrollOffset 一个函数,因为那时菜单栏还是
// SwiftUI 的 MenuBarExtra —— 它 .menu 样式的 label **挂不住任何动画**(实测坐实 `.task`
// 从来不触发;后来用探针读出根因:MenuBarExtra 是把 label **快照成一张 NSImage** 塞进
// NSStatusBarButton.image 的,所以视图侧根本没有活的图层可动)。于是当时只能反过来做:
// 由模型层每帧算出"此刻该偏移多少"、换一张图,靠 @Published 驱动 label 重渲染。
//
// 2026-08-16 菜单栏改成自建 NSStatusItem 之后,滚动交给 Core Animation 在渲染层插值,
// 主线程每句只干一次活 —— 见下面 scrollKeyframes 和 MenuBarScrollingLabel。
//
// 纯函数、无状态,selftest 直接覆盖。
public enum MenuBarMarquee {
    // 2026-08-15 删掉了原来那个按**字符**取窗的 window(text:maxChars:step:holdSteps:)。
    // 它每 0.25 秒整体平移一个字(等于 4fps),而且窗口按字符数固定、字符宽度却差着一倍
    // (中文 128pt vs 英文 65pt 同为 10 个字),菜单栏项因此跟着内容忽宽忽窄。取代它的是
    // 按像素连续平移:偏移由下面的 scrollOffset 算,取窗/截断由 MenuBarMarqueeRenderer
    // 按真实文字宽度做。两份实现不并存 —— 留着那个没人调的旧版只会让人以为还有第二条路。

    // ---- 像素级滚动 ----
    //
    // 2026-08-15 加。上面那个按字符取窗的版本用户实测"显得很卡顿",原因不是性能,是两件
    // 事叠在一起:
    //   1. 每 0.25 秒整体平移**一个字**,这是肉眼可辨的大跨度跳变,本质上就是 4fps 的动画;
    //   2. 窗口固定 maxChars 个**字符**,而字符的显示宽度并不相等(英文 'i' 和 'm' 差一倍、
    //      中文又比拉丁宽得多)。于是每跳一次,这段文字的像素宽度也跟着变 —— 菜单栏项宽度
    //      随之伸缩,把右边其它 App 的图标一起顶得左右晃。
    //
    // 所以改成:窗口宽度按**像素**钉死(菜单栏不再抖),文字在这个窗口里按像素连续平移
    // (真正的平滑)。渲染那一半必须落在 AppKit 那边(要测字宽、要画图),但"此刻该偏移多少"
    // 仍然是纯函数,留在这里给 selftest 覆盖。
    //
    // 一个完整周期跟按字符那版一致:先停 holdSeconds(开头最该看清)→ 匀速滚过 maxOffset →
    // 末尾再停 holdSeconds → 回到开头循环。
    //
    // 用「已过去的秒数」而不是「第几帧」当输入,是有意的:计时器回调会被主线程上别的活儿
    // (逐字高亮那套 60fps 的重绘)推迟,累加式计帧会把这些延迟原样变成忽快忽慢的滚动 ——
    // 那正是"卡顿"的另一半来源。按墙钟时间算,延迟只表现为丢帧,节奏始终是匀的。
    /// 首尾停留时长可以不一样 —— 见 pacing:知道这一句会显示多久时,尾部那一停几乎没有
    /// 价值(读到末尾之后就该换句了),把时间让给滚动本身。
    public static func scrollOffset(
        elapsed: Double, maxOffset: CGFloat, pointsPerSecond: CGFloat,
        headHoldSeconds: Double, tailHoldSeconds: Double
    ) -> CGFloat {
        // 装得下(maxOffset<=0)就不滚。速度非正是调用方算错了,同样退化成不滚,不要除零。
        guard maxOffset > 0, pointsPerSecond > 0 else { return 0 }
        let head = max(0, headHoldSeconds)
        let tail = max(0, tailHoldSeconds)
        let travel = Double(maxOffset / pointsPerSecond)
        let cycle = head + travel + tail
        // cycle 恒 > 0(travel > 0),不用防除零。
        var t = elapsed.truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle } // elapsed 传负数(时钟回拨)也不会跳到奇怪的位置
        if t < head { return 0 }
        if t < head + travel {
            // 夹一次上界:浮点乘法在末尾那一帧可能算出比 maxOffset 大一丁点,越界会露出
            // 右边的空白。
            return min(maxOffset, CGFloat(t - head) * pointsPerSecond)
        }
        return maxOffset
    }

    /// 首尾等长的便利写法(不知道这句会显示多久时就走它)。
    public static func scrollOffset(
        elapsed: Double, maxOffset: CGFloat, pointsPerSecond: CGFloat, holdSeconds: Double
    ) -> CGFloat {
        scrollOffset(elapsed: elapsed, maxOffset: maxOffset, pointsPerSecond: pointsPerSecond,
                     headHoldSeconds: holdSeconds, tailHoldSeconds: holdSeconds)
    }

    // ---- 同一段运动的**声明式**写法(2026-08-16 加) ----
    //
    // 上面 scrollOffset 是"给我一个时刻,我告诉你此刻偏移多少",要有人每帧来问才动得起来。
    // 2026-08-16 把菜单栏从 MenuBarExtra 换成原生 NSStatusItem 之后,滚动交给 Core Animation
    // 在渲染层插值(见 MenuBarScrollingLabel),而 CA 要的是另一种形状的输入:整个周期多长、
    // 在哪几个归一化时刻、各自停在哪个偏移量上。这个函数就是把同一段运动翻译成那个形状。
    //
    // 两者**必须**描述同一段运动 —— selftest 里直接拿这里的关键帧做线性插值,逐点跟
    // scrollOffset 对答案(见"菜单栏跑马灯:关键帧与逐帧采样必须描述同一段运动")。这样
    // 换驱动方式没有偷偷改变观感,而不是靠"我记得参数抄对了"。
    //
    // 保留 scrollOffset 不删:它是这段运动的可读定义,也是关键帧的验收标准。
    public struct ScrollKeyframes: Equatable, Sendable {
        /// 一个完整周期的秒数(停 → 滚 → 停)。CA 那边 repeatCount = .infinity。
        public let duration: Double
        /// 归一化时刻(0...1),跟 offsets 一一对应。
        public let keyTimes: [Double]
        /// 各时刻的偏移量(点,>= 0,越大表示文字越往左走)。
        public let offsets: [CGFloat]
    }

    /// nil = 这一句不用滚(装得下,或者调用方把速度算成了非正数)。
    public static func scrollKeyframes(
        maxOffset: CGFloat, pointsPerSecond: CGFloat,
        headHoldSeconds: Double, tailHoldSeconds: Double
    ) -> ScrollKeyframes? {
        guard maxOffset > 0, pointsPerSecond > 0 else { return nil }
        let head = max(0, headHoldSeconds)
        let tail = max(0, tailHoldSeconds)
        let travel = Double(maxOffset / pointsPerSecond)
        let cycle = head + travel + tail
        // travel > 0 保证 cycle > 0,不用防除零。
        return ScrollKeyframes(
            duration: cycle,
            keyTimes: [0, head / cycle, (head + travel) / cycle, 1],
            offsets: [0, 0, maxOffset, maxOffset]
        )
    }

    /// 首尾等长的便利写法。
    public static func scrollKeyframes(
        maxOffset: CGFloat, pointsPerSecond: CGFloat, holdSeconds: Double
    ) -> ScrollKeyframes? {
        scrollKeyframes(maxOffset: maxOffset, pointsPerSecond: pointsPerSecond,
                        headHoldSeconds: holdSeconds, tailHoldSeconds: holdSeconds)
    }

    // ---- 配速:让这一句在换到下一句**之前**滚完 ----
    //
    // 2026-08-17 用户反馈:"一句歌词比较长的时候滚动太慢,还没滚到底就切到下一行了"。
    // 根因是速度一直写死成"每秒 4 个字",跟这一句实际会显示多久**完全脱钩** —— 句子越长,
    // 走完需要的时间越长,而它能显示的时间并不会跟着变长,于是越长的句子越看不到后半截。
    //
    // 现在按这一句的停留时长倒推速度:留出首尾停顿之后,剩下的时间正好把 maxOffset 走完。
    //
    // 三条约束:
    //   1. **只加速,不减速**。停留时间很长的句子仍按原来的每秒 4 个字走,走完就停在末尾 ——
    //      那是现有观感,没人抱怨,不动它。
    //   2. **有速度上限**。再快就成了一片糊影,读不到等于没显示。上限取每秒 12 个字
    //      (中文字幕公认的舒适上限附近,约为基准速度的 3 倍)。撞到上限仍然滚不完的极长句子
    //      就是滚不完 —— 这是**明知的取舍**:比起把字甩成残影,宁可少看几个字。
    //   3. **首尾停顿跟着句子时长缩,而且尾部先缩**。一句只显示 3 秒时,首尾各停 1.5 秒
    //      等于根本没滚。开头那一停优先保住 —— 一句歌词最该看清的就是开头;句尾那一停
    //      时间不够时先让路。
    //      (⚠️ 2026-08-17 第一版把句尾价值判成 0、让滚动恰好在换句那一刻走完 ——
    //      2026-08-19 用户实测推翻:"一到最后一个字就马上到下一句了",末尾几个字根本
    //      来不及读。现在句尾按 tailReadSeconds 预留一段读完时间,滚动相应加速。)
    public struct ScrollPacing: Equatable, Sendable {
        public let pointsPerSecond: CGFloat
        public let headHoldSeconds: Double
        public let tailHoldSeconds: Double
    }

    /// 基准速度:每秒 4 个字。2026-08-05 初版定的,换过两次驱动方式都没动过。
    public static let baseCharsPerSecond: CGFloat = 4
    /// 速度上限:每秒 12 个字。中文字幕的舒适阅读速度公认在每秒 9~12 字附近,再快就只是
    /// 一片糊影、读不到等于没显示。这是**故意**不为了"滚完"而突破的一道线。
    public static let maxCharsPerSecond: CGFloat = 12
    /// 开头那一停:最多这么久。
    public static let baseHoldSeconds: Double = 1.5
    /// 开头那一停最多占这一句时长的多少 —— 短句上 1.5 秒会把整句时间吃光。
    public static let headHoldMaxFraction: Double = 0.25
    /// 句尾那一停:滚完之后至少让末尾**在换句之前**可见这么久(2026-08-19 用户反馈
    /// "一到最后一个字就马上到下一句了"——原来滚动被规划成恰好在换句那一刻走完,
    /// 句尾零停留)。为此滚动会相应加速,但仍不越过 maxCharsPerSecond。
    public static let tailReadSeconds: Double = 1.0
    /// 句尾那一停最多占这一句时长的多少 —— 短句给足 1 秒会挤掉滚动本身。
    public static let tailHoldMaxFraction: Double = 0.2
    /// 走完之后额外多停一会儿再回到开头。停留时长是**估**出来的(歌词时间轴校准、播放
    /// 位置外推都有误差),留这点余量,循环就永远不会赶在换句之前发生 —— 否则末尾那几个字
    /// 会闪一下跳回开头。
    public static let loopGuardSeconds: Double = 0.5

    /// - Parameter dwellSeconds: 这一句会显示多久。nil = 不知道(没有下一句的时间信息),
    ///   此时完全维持 2026-08-17 之前的行为(固定速度、首尾各停 1.5 秒)。
    public static func pacing(
        maxOffset: CGFloat, averageCharWidth: CGFloat, dwellSeconds: Double?
    ) -> ScrollPacing {
        // 兜一个正数下限:字宽算成 0 的话速度也会是 0,关键帧那边会当成"不滚"。
        let base = max(1, baseCharsPerSecond * averageCharWidth)
        guard let dwell = dwellSeconds, dwell > 0, maxOffset > 0 else {
            return ScrollPacing(pointsPerSecond: base,
                                headHoldSeconds: baseHoldSeconds,
                                tailHoldSeconds: baseHoldSeconds)
        }
        let cap = max(1, maxCharsPerSecond * averageCharWidth)
        // 两个端点:最慢(基准速度)和最快(上限速度)各要走多久。
        let travelAtBase = Double(maxOffset / base)
        let travelAtCap = Double(maxOffset / cap)

        // 开头那一停**按需让路**:时间够就给足,不够就一路让到 0 —— 让"看得到整句"优先于
        // "看清开头"。这一步是 2026-08-17 第一版漏掉的,当时首停按固定比例扣,长句因此
        // 白白撞上速度上限、依然滚不完。
        let head = min(baseHoldSeconds, dwell * headHoldMaxFraction, max(0, dwell - travelAtCap))

        // 句尾也预留一段读完时间(2026-08-19):原来 travel 直接吃满 dwell - head,滚动
        // 恰好在换句那一刻走完、末尾零停留,"一到最后一个字就马上到下一句"。时间不够时
        // 尾停**先于**首停让路 —— 首停关系到开头能不能读到,尾停只是末尾多看一眼。
        let tailReserve = min(tailReadSeconds, dwell * tailHoldMaxFraction,
                              max(0, dwell - head - travelAtCap))

        // 剩下的时间全部拿来走。够慢就慢(不比基准速度快,免得短句被无谓地甩快),
        // 不够就加速,但不越过上限。
        let travel = min(max(dwell - head - tailReserve, travelAtCap), travelAtBase)
        let pointsPerSecond = min(cap, max(base, maxOffset / CGFloat(travel)))

        // 走完之后一直停在末尾,直到这一句被换掉 —— 所以一句歌词**只滚一轮**,
        // 不会在时间充裕时反复从头再来(那样会显得很闹)。
        let tail = max(0, dwell - head - travel) + loopGuardSeconds
        return ScrollPacing(pointsPerSecond: pointsPerSecond,
                            headHoldSeconds: head, tailHoldSeconds: tail)
    }
}
