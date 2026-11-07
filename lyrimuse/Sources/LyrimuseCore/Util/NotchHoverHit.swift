import CoreGraphics

/// 灵动岛 hover 命中判定。
///
/// # 不能只靠 `.contentShape(Rectangle())`
///
/// `onContinuousHover` 给的 local 坐标原点在**卡片左上角**,`contentShape` 只把 x 约束在卡片宽内,y 仍按整扇窗给。窗口常驻
/// 展开态的最大尺寸,卡片下面那片透明区压着用户自己的窗口,光标划过那里也会把卡片撑开。所以**自己拿坐标跟当前卡片矩形比**,
/// 跟设置页编辑台(`NotchEditorStage`,`point.y <= cardHeight`)同一个口径。实测坐标见 05 章「三种形态」里命中区那一条。
///
/// # 展开之后"下面也算数"
///
/// 传进来的是**当前**卡片尺寸:展开后光标停在原来那片透明区上仍判 inside、维持展开。展开卡片包含稳态卡片,不会"进了又出"。
public enum NotchHoverHit {
    /// - Parameters:
    ///   - point: `onContinuousHover` 给的 local 坐标,原点在卡片左上角。
    ///   - cardWidth/cardHeight: **当前**卡片尺寸(稳态/展开态各自的那一份)。
    public static func isInside(point: CGPoint, cardWidth: CGFloat, cardHeight: CGFloat) -> Bool {
        point.x >= 0 && point.x <= cardWidth && point.y >= 0 && point.y <= cardHeight
    }

    public enum Region: Equatable, Sendable {
        case outside
        /// 接指针的部分:悬停展开、点击、滚动手势都在这里。
        case card
        /// 只显示的那一截:指针压上来不展开,点击和滚动穿到下层窗口。
        case passThrough
    }

    /// 机器刘海在卡片里的位置(卡片局部坐标):居中,宽 `width`,下沿在 `bottom`。没有刘海的屏幕不传。
    public struct Notch: Equatable, Sendable {
        public var width: CGFloat
        public var bottom: CGFloat

        public init(width: CGFloat, bottom: CGFloat) {
            self.width = width
            self.bottom = bottom
        }

        /// 刘海横跨卡片局部 x 的哪一段。
        public func span(cardWidth: CGFloat) -> ClosedRange<CGFloat> {
            let left = (cardWidth - width) / 2
            return left...(left + width)
        }
    }

    /// 刘海下沿往下这么深、跟刘海一样宽的一条也算顶行。指针进不了刘海那一块:从下往上移会停在刘海下沿,横着移会被直接挪到
    /// 刘海另一侧。卡片收起时中间那一段全在刘海里,不留这一条的话从刘海正下方移上去永远够不着卡片。见 05 章决策 140。
    public static let notchCatchDepth: CGFloat = 6

    /// 指针落在卡片哪一块。`passThroughBelow` 是只显示的那一截的上沿(卡片局部 y,即顶行下沿),nil = 整张卡都接指针。
    /// 上沿那条线本身算顶行。见 05 章决策 121。`notch` 给了就把刘海正下方那一条(`notchCatchDepth`)也算顶行。
    public static func region(point: CGPoint, cardWidth: CGFloat, cardHeight: CGFloat,
                              passThroughBelow: CGFloat?, notch: Notch? = nil) -> Region {
        if let notch, notch.width > 0, notch.span(cardWidth: cardWidth).contains(point.x),
           point.y > notch.bottom, point.y <= notch.bottom + notchCatchDepth {
            return .card
        }
        guard isInside(point: point, cardWidth: cardWidth, cardHeight: cardHeight) else { return .outside }
        if let top = passThroughBelow, point.y > top { return .passThrough }
        return .card
    }

    /// 指针在顶行里从刘海一侧到了另一侧:是系统把它从刘海这边直接挪过去的,说明用户正往刘海里推。耳朵只有几十点宽,
    /// 等进入延迟的话指针多半已经冲出卡片了。
    public static func crossesNotch(from: CGPoint, to: CGPoint, cardWidth: CGFloat, notch: Notch) -> Bool {
        guard notch.width > 0, from.y <= notch.bottom, to.y <= notch.bottom else { return false }
        let span = notch.span(cardWidth: cardWidth)
        return (from.x <= span.lowerBound && to.x >= span.upperBound) || (from.x >= span.upperBound && to.x <= span.lowerBound)
    }
}

/// 只显示那一截在指针压上来时淡到多少、多久淡完。跟悬浮歌词「悬浮淡化」同一个值。
public enum NotchPassThroughFade {
    public static let opacity: Float = 0.15
    public static let duration: Double = 0.15
}
