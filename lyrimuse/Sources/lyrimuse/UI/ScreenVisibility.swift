import Foundation

/// 屏幕上此刻看不看得见东西:锁屏、熄屏、切到别的用户三种情况任一成立就是看不见。
///
/// 由 AppDelegate 汇总那三个系统通知后写进来(见 `startObservingScreenLock`),歌词那一拍的计时
/// 走 `LocalPlaybackSource.setScreenLocked`,菜单栏的常驻动画订阅这里 —— 两边口径同一份。
@MainActor
final class ScreenVisibility: ObservableObject {
    static let shared = ScreenVisibility()

    @Published private(set) var isHidden = false

    func setHidden(_ hidden: Bool) {
        if isHidden != hidden { isHidden = hidden }
    }
}
