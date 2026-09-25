import Foundation

/// 「通知平台」下拉菜单的排列:中文用户国内平台在前,其余用户国外平台在前。判据跟「歌词来源」同一条
/// (`LyricsSourceRegion.prefersChineseSources`)。
///
/// 只管显示顺序,存盘的仍是平台 rawValue。Bark 归国内:它是国内开发者的 iOS 推送 App,用户和文档都以中文为主。
/// 两组的并集必须覆盖 App 侧 `NotificationPlatform` 的全部 case —— 漏掉的那个会从菜单里消失,selftest 钉着。
public enum NotificationPlatformRegion {
    public static let chinesePlatforms = ["bark", "dingtalk", "wecom", "feishu", "serverchan"]
    public static let internationalPlatforms = ["telegram", "discord"]

    /// 按用户偏好排好的平台 rawValue。
    public static func displayOrder(chineseFirst: Bool) -> [String] {
        chineseFirst ? chinesePlatforms + internationalPlatforms : internationalPlatforms + chinesePlatforms
    }
}
