import AppKit

/// 图层行的描边:颜色和粗细档。四周预留 `inset` 跟换行模式那条 `OptionalTextStroke` 的 padding 同一个量。
public struct LyricLayerStroke: Equatable {
    public var color: NSColor
    public var width: OverlayTextStrokeWidth

    public init(color: NSColor, width: OverlayTextStrokeWidth) {
        self.color = color
        self.width = width
    }

    public var inset: CGFloat { width.inset }
}

/// 图层歌词行(App 侧 `OverlayScrollingLyricRow.Spec`,换行模式每一行同样用它)的全部渲染输入。
/// 只有它变了才重画长图 / 重装动画(`updateNSView` 会被 SwiftUI 的任意一次重估叫到)。
/// 下面几条判据(`sameImages` / `sameImageKey` / `textRect`)由 selftest 直接调用,别搬回 App 侧。
public struct LyricLayerRowSpec: Equatable {
    public var lineKey: String
    public var words: [SyncedLyricWord]
    /// 非 nil = 开了逐词罗马音:每一列是「这一组的字 + 它的读音」上下两行,列宽取更宽的
    /// 那一行(同 SwiftUI 那边 VStack 取更宽子视图)。nil = 只有一行字。
    public var groups: [SyncedLyricWordGroup]?
    /// 逐词读音跟上面那行字之间多出来的距离(可以是负的),只在 `groups` 非 nil 时起作用。只有悬浮歌词传,
    /// 见 `OverlayRowSpacing.perWordReadingGap`。
    public var romaGap: CGFloat
    public var font: NSFont
    public var romaFont: NSFont
    public var baseColor: NSColor
    public var fillColor: NSColor
    public var romaBaseColor: NSColor
    public var romaFillColor: NSColor
    /// nil = 不描边。
    public var stroke: LyricLayerStroke?
    public var alignment: LyricDuet.Side
    public var paused: Bool
    /// 非 nil = 按显示时长配速(没有逐字时间轴的行、译文 / 罗马音 / 下一句这些副行):不填色、
    /// 整行按 `fillColor` 画,滚动路径由 `MenuBarMarquee.pacedScrollPath` 按这个窗口算。
    /// nil = 跟唱:填色和滚动都跟着 `words` 的逐字时间轴走。
    public var pacedWindow: PacedWindow?
    /// 非 nil = 整行投一层阴影(灵动岛那条 `.compositingGroup().shadow(...)` 的图层版)。直接画进
    /// 两张长图里,之后每帧零开销。阴影只占位图四周的出血,不参与排版(见 `bleed`)。
    public var shadow: TextShadow?
    /// > 0 = 放不下、还没开始滚的时候,尾部留一条这么宽的渐隐带(同 `MarqueeText.edgeFadeWidth`,
    /// 判据同 `MarqueeMath.trailingFadeWidth`:一开始滚就收掉)。
    public var edgeFadeWidth: CGFloat
    /// 时间基准的指纹(宿主传歌词时间轴总偏移之类):一变就按新基准重装动画,不等漂移超过
    /// `resyncToleranceMs`。调一次偏移常常只有 200ms,小于那道阈值,不强制重装的话这一行一直按旧偏移走。
    public var timingEpoch: Int
    /// 播放速率(锚点的 rate,倍速播放时不是 1)。关键帧按「歌词毫秒 ÷ 速率 = 墙钟秒」排,
    /// 写死 1 的话倍速时填色和滚动越走越偏,只能靠漂移超过阈值时一次次重装去追。
    public var rate: Double
    /// 这一行是译文(排字语言按译文判,见 `LyricTypesetting`)。
    public var translation: Bool
    /// true = 不装滚动和填色动画:整行按 `fillColor` 画,放不下时停在开头、尾部渐隐(触控栏在系统开了
    /// 「减弱动态效果」时传,见 17 章决策 43)。
    public var still: Bool
    /// true = 字的颜色换成沿这一行流动的彩虹(`RainbowLyrics`):两张长图只当蒙版用,透明度照旧(未唱的字暗一档),
    /// 颜色由底下横向循环平移的渐变给。`still` 时彩虹停住。触控栏、悬浮歌词、灵动岛传,见 17 章决策 54。
    public var rainbow: Bool
    /// 彩虹停不停:nil = 跟着 `paused`。逐字填色唱完一句就停表的宿主(悬浮歌词、灵动岛)单独给,彩虹不在两句之间停住。
    public var rainbowPaused: Bool?
    /// 非 nil = 这一行是一句里的一折行,方向跟着整句(悬浮歌词换行模式传):不按这一折行自己的字判,
    /// 不然一折行里拉丁字母占多数时这一行不镜像(见 04 章决策 116)。nil = 按这一行自己的字判。
    public var lineRightToLeft: Bool?

    /// 这一行按从右往左排(镜像、逐词量宽和画字都按它)。
    public var rightToLeft: Bool {
        lineRightToLeft ?? LyricTextDirection.isRightToLeft(words.map(\.text).joined())
    }

    /// 整行阴影。`offsetY` 取 SwiftUI 的口径(正 = 往下)。
    public struct TextShadow: Equatable {
        public var color: NSColor
        public var radius: CGFloat
        public var offsetY: CGFloat

        public init(color: NSColor, radius: CGFloat, offsetY: CGFloat) {
            self.color = color
            self.radius = radius
            self.offsetY = offsetY
        }
    }

    /// 一行的显示窗口(歌词时间轴毫秒,跟 `nowMs` 同一个基准)。
    public struct PacedWindow: Equatable {
        public var startMs: Int
        /// nil = 不知道会显示多久,配速退回固定速度。
        public var dwellMs: Int?

        public init(startMs: Int, dwellMs: Int?) {
            self.startMs = startMs
            self.dwellMs = dwellMs
        }
    }

    /// 参数顺序和默认值跟逐项初始化一致,调用处按字段名逐个传。
    public init(lineKey: String, words: [SyncedLyricWord], groups: [SyncedLyricWordGroup]? = nil, romaGap: CGFloat = 0,
                font: NSFont, romaFont: NSFont, baseColor: NSColor, fillColor: NSColor,
                romaBaseColor: NSColor, romaFillColor: NSColor, stroke: LyricLayerStroke? = nil,
                alignment: LyricDuet.Side, paused: Bool, pacedWindow: PacedWindow? = nil, shadow: TextShadow? = nil,
                edgeFadeWidth: CGFloat = 0, timingEpoch: Int = 0, rate: Double = 1, translation: Bool = false,
                still: Bool = false, rainbow: Bool = false, rainbowPaused: Bool? = nil, lineRightToLeft: Bool? = nil) {
        self.lineKey = lineKey
        self.words = words
        self.groups = groups
        self.romaGap = romaGap
        self.font = font
        self.romaFont = romaFont
        self.baseColor = baseColor
        self.fillColor = fillColor
        self.romaBaseColor = romaBaseColor
        self.romaFillColor = romaFillColor
        self.stroke = stroke
        self.alignment = alignment
        self.paused = paused
        self.pacedWindow = pacedWindow
        self.shadow = shadow
        self.edgeFadeWidth = edgeFadeWidth
        self.timingEpoch = timingEpoch
        self.rate = rate
        self.translation = translation
        self.still = still
        self.rainbow = rainbow
        self.rainbowPaused = rainbowPaused
        self.lineRightToLeft = lineRightToLeft
    }

    /// 两份输入画出来的长图是不是同一张 —— 除了 `paused` / `pacedWindow` / `timingEpoch` / `rate` / `still` / `rainbowPaused` 全都一样。
    /// 这几项只影响动画和摆位,不重画位图。
    public static func sameImages(_ a: LyricLayerRowSpec, _ b: LyricLayerRowSpec) -> Bool {
        var a = a
        a.paused = b.paused
        a.pacedWindow = b.pacedWindow
        a.timingEpoch = b.timingEpoch
        a.rate = b.rate
        a.still = b.still
        a.rainbowPaused = b.rainbowPaused
        return a == b
    }

    /// 换行模式出图缓存(`WrappedRowImageCache`)认的键:位图只看字、字体、颜色、描边和排版,跟逐字时间戳、动画参数无关,
    /// 比较前先把时间戳抹平(`sameImages` 本身连时间戳一起比)。
    public static func sameImageKey(_ a: LyricLayerRowSpec, _ b: LyricLayerRowSpec) -> Bool {
        sameImages(a.untimed, b.untimed)
    }

    private var untimed: LyricLayerRowSpec {
        func strip(_ words: [SyncedLyricWord]) -> [SyncedLyricWord] {
            words.map { SyncedLyricWord(text: $0.text, startMs: 0, durationMs: 0) }
        }
        var s = self
        s.words = strip(s.words)
        s.groups = s.groups?.map { SyncedLyricWordGroup(id: $0.id, words: strip($0.words), romanization: $0.romanization) }
        return s
    }

    /// 文字在一行里实际占据的矩形(左上原点):放得下按对齐方式摆(同 `place` 的静置落点,从右往左的行翻转后
    /// 落在同一侧),放不下要滚时占满整行。排版宽度跟 `layout` 同一个式子,不算阴影出血(悬浮歌词不带阴影)。
    /// 量字宽由 App 传进来(`MenuBarMarqueeRenderer.width`)。
    public func textRect(width: CGFloat, height: CGFloat,
                         measureMain: (String) -> CGFloat, measureRoma: (String) -> CGFloat) -> CGRect {
        let inset = stroke?.inset ?? 0
        let w = OverlayRowLayout.layOut(
            words: words, groups: groups, inset: inset, strokeInset: inset,
            measureMain: measureMain, measureRoma: measureRoma).boxWidth
        guard w > 0, w < width else { return CGRect(x: 0, y: 0, width: width, height: height) }
        let x: CGFloat
        switch alignment {
        case .leading: x = 0
        case .center: x = (width - w) / 2
        case .trailing: x = width - w
        }
        return CGRect(x: x, y: 0, width: w, height: height)
    }
}
