import CoreGraphics
import Foundation

/// 引导页最后一页那阵**撒花**的纯几何(2026-09-11,用户:「帮我在引导页的最后一页加入
/// Mac 很经典的那种撒花效果」)。
///
/// 形态照的是 macOS/iMessage「庆祝」那种:一阵小纸片从画面上沿之外落下来,左右飘摆、
/// 边落边翻面(正对镜头时最宽、侧过来收成一条线),几秒钟落干净。**不是**从中心炸开的
/// 礼花 —— 那种要么盖住整页文字,要么得在一个 480×420 的小窗里塞进爆炸+重力两套参数。
///
/// 为什么这份几何放 core 而不是写在 View 里(同 `OverlayCardGeometry` / `WrapLayoutMath`
/// 那条理由):它有两条**性质**值得被机械钉住,而这两条只要有一条不成立,用户看到的就是
/// 明显的瑕疵,而不是"少了点花哨":
///  ① 同一个 seed 每次生成同一场雪。摇系统随机数的话下面这条断言无从下手。
///  ② **到 `duration` 那一刻,每一片都已经整片落出画面**。View 层是靠"`duration` 到点把
///     整个 TimelineView 摘掉"来停掉逐帧重算的(见 `ConfettiOverlay`),那一刻要是还有
///     纸片停在画面里,用户看到的就是"撒花撒了一半被整块抹掉"。同理开头:每片的起点在
///     上沿之外一整片,所以也不会凭空出现在画面中间。
///
/// 一片纸屑的全部随机量在 `init` 里一次摇完,之后每帧只做代数(sin/cos 各一次)——
/// 逐帧摇随机数不只是慢,更会让轨迹在相邻两帧之间乱跳。
public struct ConfettiField {
    /// 一片纸屑的"出生参数",全部只读。
    public struct Piece: Equatable {
        /// 调色板下标。**调色板本体在 View 那边**(颜色是观感,不是几何),这里只发号;
        /// 消费方按 `% palette.count` 取,两边数目不一致也不会越界。
        public let colorIndex: Int
        public let width: CGFloat
        public let height: CGFloat
        /// 起始横向落点,画面宽度的比例。刻意允许略微出界(见 `init` 里的取值范围):
        /// 夹在 0...1 会让两侧边缘明显比中间稀。
        public let xFraction: CGFloat
        /// 出场延迟(秒)。错开出场才是"一阵",一起出场是"一排"。
        public let delay: Double
        /// 从上沿之外落到下沿之外用多久(秒)。
        public let fall: Double
        /// 左右飘摆:振幅(pt)、频率(Hz)、初相。
        public let swayAmplitude: CGFloat
        public let swayFrequency: Double
        public let swayPhase: Double
        /// 整段下落里横向匀速漂多少 pt(可正可负)—— 只有飘摆的话,每片都在自己那一列
        /// 里左右晃,一眼能看出"纸片是按列发的"。
        public let drift: CGFloat
        /// 整段下落里翻几圈、初相。
        public let spinTurns: Double
        public let spinPhase: Double
        /// 面内固定倾角(弧度)。
        public let tilt: Double

        /// 任意旋转下的最大半径。"完全落出画面"按它算,不按 width/height ——
        /// 一片 6×13 的纸屑斜着转过来,占的地方比 13 还多。
        public var span: CGFloat { (width * width + height * height).squareRoot() / 2 }
    }

    /// 某一刻某一片该画在哪、画多大。
    public struct PieceState: Equatable {
        public let center: CGPoint
        /// **画出来的**宽度:纸片在翻面,`piece.width × |cos(转角)|`,侧过来时收成一条线
        /// (经典撒花的"翻纸"感就在这)。不会小于 `minRenderedWidth`,免得整片消失一瞬。
        public let width: CGFloat
        public let height: CGFloat
        /// 面内转角(弧度)。
        public let angle: Double
        public let colorIndex: Int
    }

    public let pieces: [Piece]
    /// 整阵撒花的时长(秒)= 最后出场那片落完的时刻。View 层拿它决定什么时候停掉逐帧刷新。
    public let duration: Double

    /// 纸片翻到最侧面时仍然留这么宽 —— 给 0 会让它在那一帧彻底不见,看着像闪。
    public static let minRenderedWidth: CGFloat = 0.7
    /// 终点再往下多送这么多 pt。纯粹是把"progress = 1 时整片在画面外"从"刚好相切"变成
    /// "严格越过",免得浮点误差让最后一帧留一条边。
    public static let exitMargin: CGFloat = 1

    /// - Parameters:
    ///   - pieceCount: 纸片数。默认 130 是按引导窗那 480×420 调的:再多就从"一阵纸屑"变成
    ///     "一层雪",挡住这一页那几行字;再少落不满一屏。
    ///   - seed: 决定这一场雪的样子。同一个 seed 每次一模一样(见类型头注 ①)。
    public init(pieceCount: Int = 130, seed: UInt64 = 0x4C79_7269_4D75_7365) {
        var rng = Random(seed: seed)
        let count = max(0, pieceCount)
        var made: [Piece] = []
        made.reserveCapacity(count)
        for index in 0 ..< count {
            let width = CGFloat(rng.double(5, 8.5))
            made.append(Piece(
                // 按下标轮着发色,不摇随机:摇的话很容易连着出四五片同色,看着像"某个颜色
                // 特别多"。轨迹本身够乱,颜色不需要再乱一次。
                colorIndex: index % Self.colorCount,
                width: width,
                height: width * CGFloat(rng.double(1.25, 2.1)),
                xFraction: CGFloat(rng.double(-0.04, 1.04)),
                delay: rng.double(0, Self.spawnWindow),
                fall: rng.double(1.5, 2.6),
                swayAmplitude: CGFloat(rng.double(4, 16)),
                swayFrequency: rng.double(0.35, 1.1),
                swayPhase: rng.double(0, 2 * .pi),
                drift: CGFloat(rng.double(-30, 30)),
                spinTurns: rng.double(0.8, 3.2),
                spinPhase: rng.double(0, 2 * .pi),
                tilt: rng.double(0, 2 * .pi)))
        }
        pieces = made
        duration = made.map { $0.delay + $0.fall }.max() ?? 0
    }

    /// 调色板槽位数(颜色本体在 View 那边,见 `Piece.colorIndex`)。
    public static let colorCount = 7
    /// 出场延迟的上限:这么长的一段窗口里陆续出场,看着是"撒"而不是"倒"。
    ///
    /// ⚠️ 这个数和 `fall`(1.5...2.6s)、`pieceCount`(130)是**一起调的一组**,离屏预演过才定的
    /// (把落点画成 PNG 逐帧看,scratchpad 里那个一次性 renderer)。第一版是 0.9s / 90 片 /
    /// 1.6...2.9s,画出来是**一条纸带扫过去**:最后一片 0.9s 就出场了,到 1.8s 上沿已经全空,
    /// 只剩一横带纸屑往下走。拉到 1.5s 之后前后叠上,t=1.4 / 2.2 两帧都是满窗的持续洒落;
    /// 片数同比例补到 130 是为了保住"同时在画面里多少片"(出场窗口一长,瞬时密度就摊薄了)。
    /// 代价是整阵从 ~3.2s 变成 ~4.1s —— 撒花本来就该洒够两三秒才收。
    public static let spawnWindow: Double = 1.5

    /// `elapsed` 这一刻这片纸屑的落点;还没出场、或者已经落完(整片在下沿之外)返回 nil。
    ///
    /// `size` 是画布尺寸:落点按它现算,所以同一场雪换个窗宽照样铺满,不用重新生成。
    public func state(of piece: Piece, elapsed: Double, in size: CGSize) -> PieceState? {
        guard size.width > 0, size.height > 0, piece.fall > 0 else { return nil }
        let local = elapsed - piece.delay
        guard local >= 0 else { return nil }
        let progress = local / piece.fall
        guard progress <= 1 else { return nil }

        let span = piece.span
        // 起点在上沿之外一整片、终点在下沿之外一整片(见类型头注 ②)。
        let y = Double(-span) + (Double(size.height) + 2 * Double(span) + Double(Self.exitMargin)) * progress
        let sway = Double(piece.swayAmplitude) * sin(2 * .pi * piece.swayFrequency * local + piece.swayPhase)
        let x = Double(piece.xFraction) * Double(size.width) + sway + Double(piece.drift) * progress
        let spin = 2 * .pi * piece.spinTurns * progress + piece.spinPhase
        let rendered = max(Self.minRenderedWidth, piece.width * CGFloat(abs(cos(spin))))
        return PieceState(
            center: CGPoint(x: x, y: y),
            width: rendered,
            height: piece.height,
            // 翻面之外再慢慢转一点面内角度:只翻面的话每片都像挂在一根固定的轴上。
            // 系数刻意小于 1 —— 转得跟翻面一样快就看不清是纸片了。
            angle: piece.tilt + spin * 0.35,
            colorIndex: piece.colorIndex)
    }

    /// 确定性伪随机(SplitMix64)。
    ///
    /// **不用 `Double.random(in:)`**:那个走系统 RNG,同一个 seed 也每次不同,于是"这一场雪
    /// 长什么样"根本没法断言(整份类型头注 ① 那条性质就是为它写的)。这里要的随机只是
    /// "看着乱",不需要密码学强度;SplitMix64 短、无状态依赖、跨平台同结果。
    private struct Random {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// 0 ..< 1。取高 53 位 —— Double 的有效位就这么多,低位给了也是丢。
        mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }

        mutating func double(_ lower: Double, _ upper: Double) -> Double {
            lower + (upper - lower) * unit()
        }
    }
}
