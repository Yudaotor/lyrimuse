import CoreGraphics

/// 悬浮歌词文字描边的粗细(「颜色」那一组「描边粗细」),三档。
///
/// 档位定的是剪影模糊的 σ(`points`),描边外沿离字边约 2.3σ。换行模式(`OptionalTextStroke`)、滚动模式
/// (`OverlayScrollingLyricRow`)、按描边预留算的排版(行高、卡片自然宽、读音两侧留白、断句宽度)和 OBS 页都读同一档,
/// 两种模式粗细一致。只有桌面悬浮歌词(和画它的编辑台预览)、OBS 页用,配色主题不带它。见 04 章决策 106。
public enum OverlayTextStrokeWidth: String, Codable, Hashable, CaseIterable, Sendable, Identifiable {
    case thin
    case standard
    case thick

    public var id: Self { self }

    /// 默认档:没存过这项设置时读它。
    public static let `default`: OverlayTextStrokeWidth = .standard

    /// 剪影模糊半径 σ(点)。`standard` 必须是 1.2:没碰过这项设置的人升级后描边逐像素不变。
    public var points: CGFloat {
        switch self {
        case .thin: return 0.8
        case .standard: return 1.2
        case .thick: return 1.6
        }
    }

    /// 描边在内容四周各预留的空白(点):模糊让剪影往外胀,不留这一圈会被裁掉。
    public var inset: CGFloat { points * 2 }

    /// 每侧预留:描边开着时是这一档的 `inset`,关着为 0。
    public static func inset(enabled: Bool, width: OverlayTextStrokeWidth) -> CGFloat {
        enabled ? width.inset : 0
    }
}
