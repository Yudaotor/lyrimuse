import Foundation

/// 系统设置「桌面与程序坞 › 双击窗口标题栏以」那一项。读全局偏好 `AppleActionOnDoubleClick`(Maximize = 缩放、
/// Fill = 填充、Minimize = 最小化、None = 不执行任何操作);没有这一项时看旧的 `AppleMiniaturizeOnDoubleClick`,
/// 两项都没有按系统默认的放大算。认不得的取值也按放大算。
public enum TitlebarDoubleClickAction: Equatable, Sendable {
    case zoom
    case minimize
    case none

    public static func resolve(action: String?, miniaturizeOnDoubleClick: Bool) -> TitlebarDoubleClickAction {
        switch action {
        case "Minimize": return .minimize
        case "None": return .none
        case .some: return .zoom
        case nil: return miniaturizeOnDoubleClick ? .minimize : .zoom
        }
    }

    public static func current(_ defaults: UserDefaults = .standard) -> TitlebarDoubleClickAction {
        resolve(action: defaults.string(forKey: "AppleActionOnDoubleClick"),
                miniaturizeOnDoubleClick: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"))
    }

    /// 控件矩形往外让出的余量:点在胶囊描边上不算空白。
    public static let controlSlop: CGFloat = 2

    /// 这一下落在标题栏那一条的空白处:窗口左上原点、y 向下,在标题栏高度以内,不在任何一颗控件(外扩 `controlSlop`)里。
    public static func isBlankTitlebar(_ point: CGPoint, titlebarHeight: CGFloat, controls: [CGRect]) -> Bool {
        guard titlebarHeight > 0, point.y >= 0, point.y < titlebarHeight else { return false }
        return !controls.contains { $0.insetBy(dx: -controlSlop, dy: -controlSlop).contains(point) }
    }
}
