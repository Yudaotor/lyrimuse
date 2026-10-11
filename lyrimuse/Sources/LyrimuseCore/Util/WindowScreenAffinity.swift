import Foundation

/// 窗口跟盘上记的那块屏的关系。位置只认用户拖出来的那个:记的那块屏不在时窗口借别的屏显示、
/// 这期间不写盘,那块屏回来就送回去。歌词窗口用(完整、迷你各记一份屏);悬浮歌词是同一套规则,
/// 按几何判断,见 OverlayPlacement。
public enum WindowScreenAffinity {
    public enum Action: Equatable, Sendable {
        case keep
        /// 记的那块屏不在了:标记借屏,之后的位置不写盘。
        case startBorrowing
        /// 正在借屏,记的那块屏回来了:按盘上的位置摆回去。
        case returnHome
    }

    /// - savedScreenID: 盘上记的那块屏;没存过是 nil。
    /// - connected: 现在接着的屏。
    public static func onScreensChanged(savedScreenID: String?, connected: Set<String>, borrowing: Bool) -> Action {
        guard let saved = savedScreenID else { return .keep }
        if connected.contains(saved) { return borrowing ? .returnHome : .keep }
        return borrowing ? .keep : .startBorrowing
    }
}
