import Foundation

/// 添加渠道时平台的排列:不分组,一排铺开。中文用户国内平台在前,其余用户国外平台在前,判据跟「歌词来源」同一条
/// (`LyricsSourceRegion.prefersChineseSources`)。通用 Webhook 不在这里:它不是一个消息平台,表单里永远排在最后。
///
/// 只管显示顺序,存盘的仍是平台 rawValue。Bark 归国内:它是国内开发者的 iOS 推送 App,用户和文档都以中文为主。
/// 这里加上 `generic` 必须覆盖 App 侧 `NotificationPlatform` 的全部 case —— 漏掉的那个会从表单里消失,selftest 钉着。
public enum NotificationPlatformRegion {
    public static let chinesePlatforms = ["bark", "feishu", "dingtalk", "wecom", "serverchan"]
    public static let internationalPlatforms = ["telegram", "discord", "slack", "ntfy"]
    /// 自己写接收端用的,永远排最后。
    public static let generic = ["webhook"]

    /// 按用户偏好排好的消息平台 rawValue(不含 `generic`)。
    public static func displayOrder(chineseFirst: Bool) -> [String] {
        chineseFirst ? chinesePlatforms + internationalPlatforms : internationalPlatforms + chinesePlatforms
    }
}
