import Foundation

// 「歌词管理」列表四列(歌名/歌手/专辑/来源)的列宽模型 + 拖拽分隔条的宽度计算。
//
// 只有后三列有显式宽度,歌名是弹性列、吃掉剩下的空间——所以三个分隔条的语义不完全对称,
// 第一条(歌名|歌手)只能改「歌手」,由歌名被动吸收;后两条是标准的"此消彼长、总宽不变"。
// 这段夹值逻辑是最容易出错的地方(拖到负宽、把歌名挤没、窗口缩小后列宽仍然超出可用宽度),
// 所以做成纯函数放在 LyrimuseCore 里,由 lyrimuse-selftest 覆盖——UI 那侧
// (LyricsColumnWidthsStore/LyricsManagerView)只负责手势和持久化,不重复实现任何算术。
public struct LyricsColumnWidths: Equatable, Sendable {
    public var artist: CGFloat
    public var album: CGFloat
    public var source: CGFloat

    public init(artist: CGFloat, album: CGFloat, source: CGFloat) {
        self.artist = artist
        self.album = album
        self.source = source
    }

    // 改动之前写死在 LyricsListColumns 里的那三个值,保持原样当默认值——默认外观不变。
    public static let defaults = LyricsColumnWidths(artist: 96, album: 110, source: 84)

    // 56pt 大约是"歌手"两个中日韩字 + 省略号还看得出来是什么"的下限;来源列放的是胶囊
    // 徽章(见 SourceBadge),再窄就会把"网易云音乐"这种四字来源截掉,单独给它一个更高的下限。
    public static let minColumn: CGFloat = 56
    public static let minSourceColumn: CGFloat = 70
    // 歌名是主列,任何时候都得留下足够看清歌名开头的宽度,不能被三条固定列挤没。
    public static let minTitle: CGFloat = 140
    // 单列上限——防止一次误拖就把某列拉到几百 pt。
    public static let maxColumn: CGFloat = 280

    public var total: CGFloat { artist + album + source }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        // lo > hi 时(可用宽度极小,上下限打架)以下限为准:宁可让歌名被挤窄,也不要返回
        // 一个比 minColumn 还小的宽度——那会让某一列直接消失。
        hi < lo ? lo : min(max(v, lo), hi)
    }

    /// 拖动第 `divider` 条分隔条:0 = 歌名|歌手,1 = 歌手|专辑,2 = 专辑|来源。
    /// `dx` 是相对本次手势起点的水平位移(向右为正),`start` 是手势开始那一刻的列宽快照。
    /// `totalWidth` 是表头整行的可用宽度,`chrome` 是这一行里不属于任何列的固定开销
    /// (左右内边距 + 列间距之和),两者一起才能算出歌名列还剩多少。
    public static func dragged(
        from start: LyricsColumnWidths, divider: Int, dx: CGFloat,
        totalWidth: CGFloat, chrome: CGFloat
    ) -> LyricsColumnWidths {
        var out = start
        switch divider {
        case 0:
            // 边界右移(dx > 0)= 歌名变宽 → 歌手必须变窄,所以是减号。
            // 上限还要保证歌名不低于 minTitle。
            //
            // totalWidth <= 0 = 调用方还没量到可用宽度(首帧、或列表当前一行都没有)。
            // 这时不能照常算 room:算出来是个负数,clamp 里 hi < lo 就直接返回下限,表现成
            // "一拖歌手就弹到最窄"。没量到就只受单列上限约束,等量到之后 fitted 会把越界的
            // 值收敛回来——这一档只在拿不到测量值时走,不是常规路径。
            let room = totalWidth > 0
                ? totalWidth - chrome - minTitle - start.album - start.source
                : maxColumn
            out.artist = clamp(start.artist - dx, minColumn, min(maxColumn, room))
        case 1:
            // 内部边界:歌手 + 专辑 之和不变 → 歌名宽度完全不受影响,不需要看 totalWidth。
            let d = clamp(dx, minColumn - start.artist, min(start.album - minColumn, maxColumn - start.artist))
            out.artist = start.artist + d
            out.album = start.album - d
        default:
            let d = clamp(dx, minColumn - start.album, min(start.source - minSourceColumn, maxColumn - start.album))
            out.album = start.album + d
            out.source = start.source - d
        }
        return out
    }

    /// 渲染前的兜底收敛:窗口/侧栏被拖窄之后,原来合法的列宽可能已经把歌名挤到 minTitle
    /// 以下。按比例缩三条固定列直到歌名重新够宽(缩不动了就到各自下限为止)——不改用户存下来
    /// 的值,只影响这一次渲染,窗口拖回去还是原来的列宽。
    public static func fitted(_ w: LyricsColumnWidths, totalWidth: CGFloat, chrome: CGFloat) -> LyricsColumnWidths {
        let budget = totalWidth - chrome - minTitle
        guard budget > 0, w.total > budget else { return w }
        let floorTotal = minColumn + minColumn + minSourceColumn
        // 连各列下限之和都塞不进去 → 直接全部回落到下限,歌名只能被挤窄(总比某列消失好)。
        guard budget > floorTotal else {
            return LyricsColumnWidths(artist: minColumn, album: minColumn, source: minSourceColumn)
        }
        // 只按"可压缩余量"(当前宽度 - 下限)等比分摊要缩掉的量,保证缩完谁都不会低于下限。
        let excess = w.total - budget
        let slack = (w.artist - minColumn) + (w.album - minColumn) + (w.source - minSourceColumn)
        guard slack > 0 else { return w }
        let k = min(1, excess / slack)
        return LyricsColumnWidths(
            artist: w.artist - (w.artist - minColumn) * k,
            album: w.album - (w.album - minColumn) * k,
            source: w.source - (w.source - minSourceColumn) * k
        )
    }

    /// 从持久化值恢复时用:挡住手改 UserDefaults / 老版本残留写进来的非法值(NaN、0、负数、
    /// 大得离谱),任何一项不合法就整体退回默认值,不做逐项修补——三列宽度是一组配套的值。
    public static func sanitized(_ w: LyricsColumnWidths) -> LyricsColumnWidths {
        for v in [w.artist, w.album, w.source] where !v.isFinite { return defaults }
        guard w.artist >= minColumn, w.artist <= maxColumn,
              w.album >= minColumn, w.album <= maxColumn,
              w.source >= minSourceColumn, w.source <= maxColumn else { return defaults }
        return w
    }
}
