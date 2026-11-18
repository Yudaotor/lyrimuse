import Foundation

/// 在主线程上响应一份 UserDefaults 的变更通知(`UserDefaults.didChangeNotification`),但不让后台线程上的写入等主线程。
///
/// 别写成 `addObserver(forName: UserDefaults.didChangeNotification, …, queue: .main)`:后台线程写这份偏好时,
/// NotificationCenter 把回调排进主队列再同步等它跑完,主线程卡住期间后台的写盘(遥测记账这类)就跟着排队,
/// 用户这时强制退出,记下的就丢了(14 章决策 175、231)。这里回调登记在发通知的线程上(`queue: nil`),
/// 主线程上要做的事异步投过去;在主线程上发的通知照旧当场跑。
public enum UserDefaultsChangeRelay {
    /// 返回的观察者交给 `NotificationCenter.default.removeObserver` 撤掉;常驻的不用留。
    @discardableResult
    public static func observe(_ defaults: UserDefaults,
                               onMain handler: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
            }
        }
    }
}
