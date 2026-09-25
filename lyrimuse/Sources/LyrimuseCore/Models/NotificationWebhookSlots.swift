import Foundation

/// 推送提醒各平台各自的 webhook 地址(键是 NotificationPlatform 的 rawValue)。
///
/// 设置页只有一个地址输入框,切换平台时要换成那个平台自己的地址:不换的话,切到 Telegram 还显示着
/// Bark 的地址;切换时直接清空的话,手滑切一下原来的地址就丢了。collector 只读 `bark_url`(当前平台
/// 那一份),其余平台的地址只由 App 侧另存(config.json 的 `notification_webhook_urls`)。
public struct NotificationWebhookSlots: Equatable, Sendable {
    public private(set) var urls: [String: String]

    /// `stored` 是磁盘上存的各平台地址;当前平台以 `activeURL`(即 `bark_url`)为准。
    public init(stored: [String: String], activePlatform: String, activeURL: String) {
        urls = stored
        record(activeURL, for: activePlatform)
    }

    /// 从 `from` 切到 `to`:记下 `from` 此刻输入框里的地址,返回 `to` 该显示的地址(没存过就是空)。
    public mutating func switchPlatform(from: String, currentURL: String, to: String) -> String {
        record(currentURL, for: from)
        return urls[to] ?? ""
    }

    /// 落盘用的全集:并入当前平台此刻的地址,去掉空值。
    public func persisted(activePlatform: String, activeURL: String) -> [String: String] {
        var copy = self
        copy.record(activeURL, for: activePlatform)
        return copy.urls
    }

    private mutating func record(_ url: String, for platform: String) {
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urls.removeValue(forKey: platform)
        } else {
            urls[platform] = url
        }
    }
}
