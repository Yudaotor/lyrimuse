import CoreGraphics

/// 灵动岛进度线画在哪(「进度线」那一行的后两档,关着时 `AppSettings.notchShowsProgressLine` 为 false)。
public enum NotchProgressLineStyle: String, Codable, Hashable, CaseIterable, Sendable {
    /// 卡片底边一根横线。关着歌词行时卡片为它多长 `NotchCardLayout.Metrics.progressLineStrip`。
    case bottom
    /// 沿卡片外沿从屏幕上沿往下、绕过底角走到刘海,左右两半同时走。卡片不为它变高。
    case ears
}

/// 「进度线」那一行的三档。存成两个设置(开关 + `NotchProgressLineStyle`):旧版只有开关,开着时就是底边那一档。
public enum NotchProgressLineChoice: String, CaseIterable, Sendable {
    case off
    case bottom
    case ears

    public init(shows: Bool, style: NotchProgressLineStyle) {
        guard shows else { self = .off; return }
        switch style {
        case .bottom: self = .bottom
        case .ears: self = .ears
        }
    }

    /// 选这一档时开关该是什么。
    public var shows: Bool { self != .off }

    /// 选这一档时样式该是什么;nil = 不显示,样式留着上一次的。
    public var style: NotchProgressLineStyle? {
        switch self {
        case .off: return nil
        case .bottom: return .bottom
        case .ears: return .ears
        }
    }
}

/// 「耳朵」那一档进度线左半边的路径(右半边左右镜像)。原点在卡片左上角,线心离卡片外沿 `inset`。
///
/// 从屏幕上沿沿左侧边往下,绕过底角圆弧,再沿底边往中间走。底边被刘海挡住时(有刘海、卡片不比刘海高,即关着歌词行)
/// 停在刘海左沿;底边露在刘海下面时(开着歌词行、无刘海屏)走到卡片正中,两半在那里接上。见 05 章决策 111。
public struct NotchEarProgressPath: Equatable, Sendable {
    /// 竖段的 x。
    public var x: CGFloat
    /// 底边那一段的 y。
    public var bottomY: CGFloat
    /// 底角那段圆弧的半径(卡片底角半径减去 `inset`,同心)。
    public var cornerRadius: CGFloat
    /// 终点的 x。
    public var endX: CGFloat

    /// - Parameters:
    ///   - shoulder / cardCornerRadius: 卡片外形此刻的肩膀和底角半径(App 侧 `NotchHangingShape.cornerMetrics`)。
    ///   - notchHeight: 顶行高度(真刘海屏 = 刘海高)。
    public init(width: CGFloat, height: CGFloat, notchWidth: CGFloat, notchHeight: CGFloat,
                shoulder: CGFloat, cardCornerRadius: CGFloat, inset: CGFloat) {
        x = shoulder + inset
        bottomY = max(0, height - inset)
        cornerRadius = max(0, min(cardCornerRadius - inset, bottomY))
        let center = width / 2
        let bottomUnderNotch = notchWidth > 0 && height <= notchHeight + 0.5
        endX = max(x + cornerRadius, bottomUnderNotch ? center - notchWidth / 2 : center)
    }

    /// 左半边的长度(竖段 + 四分之一圆弧 + 底边段)。重画间隔按它算。
    public var length: CGFloat {
        (bottomY - cornerRadius) + .pi / 2 * cornerRadius + (endX - x - cornerRadius)
    }
}
