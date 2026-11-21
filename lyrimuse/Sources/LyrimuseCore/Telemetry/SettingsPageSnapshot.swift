import Foundation

/// 设置窗口此刻停在哪一页(`TelemetryHang.settingsPages` 里的取值;窗口关着为 nil)。
/// App 在主线程上换页时写,看门狗报卡顿时在自己的队列上读:加锁存着,主线程卡住时照样读得到,别改成卡顿时去问主线程。
public final class SettingsPageSnapshot: @unchecked Sendable {
    public static let shared = SettingsPageSnapshot()

    private let lock = NSLock()
    private var page: String?

    public init() {}

    /// 不在 `TelemetryHang.settingsPages` 里的记成 nil。
    public func set(_ page: String?) {
        let known = page.flatMap { TelemetryHang.settingsPages.contains($0) ? $0 : nil }
        lock.withLock { self.page = known }
    }

    public var current: String? {
        lock.withLock { page }
    }
}
