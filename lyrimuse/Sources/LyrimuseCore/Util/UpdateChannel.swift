import Foundation

/// 「接收测试版更新」的纯逻辑:Release 列表接口地址、响应解析、该读哪份 appcast、刷新判据。发请求与 Sparkle 接线在
/// App 侧 `SparkleUpdaterManager`,被 selftest update-channel 组钉住的是这里。
///
/// 为什么开关打开后要**自己挑 appcast**,而不是只靠 Sparkle 的 channel 过滤(2026-09-05):appcast 是每个 Release 自带
/// 一份、只列它自己;正式用户读的 `releases/latest/download/appcast.xml` 经 GitHub 的 latest 重定向永远落在最新**正式版**
/// 上(GitHub 的 latest 不含 prerelease),预发布的 appcast 只在它自己的 tag 目录下、没有稳定地址。所以 beta 用户得先问
/// 一遍 Release 列表,把版本最高的那一份(可能是预发布,也可能是已把它盖过的正式版)的 tag 目录 appcast 交给 Sparkle。
/// channel 过滤(`allowedChannels`)仍然接上,是第二道保险:预发布 appcast 的 item 都带 `<sparkle:channel>beta</sparkle:channel>`,
/// 开关关着的实例即使被手动 `defaults write` 指到一份 beta appcast 也看不见它。
public enum UpdateChannel {
    public static let repository = "Yudaotor/lyrimuse"
    /// 匿名读公开仓库的 Release 列表,**不带凭据**;30 条足够覆盖最近若干正式版 + 预发布。跟 star 数同一个 host,
    /// 01 章「对外请求」那张表登记的是 host 级别。
    public static let releasesAPIURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!

    /// 某一版的 GitHub Release 页。tag = "v" + 展示版本(build-version.sh 的映射:vX.Y.Z / vX.Y.Z-beta.N 去掉 v
    /// 就是 CFBundleShortVersionString),所以从展示版本能反推回去。「软件更新」页那个 ⓘ 用它兜底
    /// (appcast 自己带 link / fullReleaseNotesLink 时优先用那个)。
    public static func releasePageURL(displayVersion: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(displayVersion)")
            ?? URL(string: "https://github.com/\(repository)/releases")!
    }
    /// 多久重查一次 Release 列表。预发布不是分钟级的事,1 小时够;开关切换与手动「检查更新」会强制刷新。
    public static let refreshTTL: TimeInterval = 3600
    /// 失败 / 限流后多久才允许再试。
    public static let failureBackoff: TimeInterval = 15 * 60
    /// 预发布 item 挂的 channel 名,跟 release.yml 里写进 appcast 的那个字符串逐字对应。
    public static let betaChannelName = "beta"

    public struct Release: Equatable {
        public let tag: String
        public let prerelease: Bool
        public let draft: Bool
        public init(tag: String, prerelease: Bool, draft: Bool) {
            self.tag = tag
            self.prerelease = prerelease
            self.draft = draft
        }
    }

    /// 解析 `/repos/{owner}/{repo}/releases` 的响应,只取三个字段。顶层不是数组、或某条缺 tag_name → nil(整份不信)。
    public static func parseReleases(_ data: Data) -> [Release]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var out: [Release] = []
        for item in array {
            guard let tag = item["tag_name"] as? String else { return nil }
            out.append(Release(tag: tag,
                               prerelease: item["prerelease"] as? Bool ?? false,
                               draft: item["draft"] as? Bool ?? false))
        }
        return out
    }

    /// 非 draft、tag 能解析的 Release 里版本最高的那一个;没有 → nil。draft 的还没发出来、资产可能不全;
    /// 解析不了的 tag(历史遗留的奇形怪状)不参与比较。
    public static func newestRelease(_ releases: [Release]) -> Release? {
        releases
            .filter { !$0.draft }
            .compactMap { release in ReleaseVersion(tag: release.tag).map { (release, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// 某个 Release 自己 tag 目录下的 appcast —— 跟 release.yml 上传的资产名(appcast.xml)与 enclosure 的目录一致。
    public static func appcastURL(forTag tag: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(tag)/appcast.xml")!
    }

    /// 开关打开时 Sparkle 该读的 appcast。nil = 没有可用条目,App 侧退回 Info.plist 默认地址(最新正式版)。
    public static func betaFeedURL(releases: [Release]) -> URL? {
        newestRelease(releases).map { appcastURL(forTag: $0.tag) }
    }

    /// 该不该现在重查一次。判据同 `GitHubStars.shouldRefresh`:退避优先;取数时间在未来(时钟回拨)当过期。
    public static func shouldRefresh(now: Date, fetchedAt: Date?, retryNotBefore: Date?) -> Bool {
        if let retryNotBefore, now < retryNotBefore { return false }
        guard let fetchedAt else { return true }
        let age = now.timeIntervalSince(fetchedAt)
        if age < 0 { return true }
        return age >= refreshTTL
    }
}
