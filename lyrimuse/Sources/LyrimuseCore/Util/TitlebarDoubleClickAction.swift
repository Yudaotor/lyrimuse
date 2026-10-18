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
}
