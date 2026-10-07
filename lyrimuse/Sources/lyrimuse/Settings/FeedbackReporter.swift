import AppKit
import LyrimuseCore

/// 反馈入口(设置「关于」页、菜单栏右键菜单、歌词搜索面板)都走这里:收集版本、系统和播放器,打开 GitHub 的 issue 表单或
/// 写邮件(链接怎么拼见 `FeedbackLinks`)。只读本机现成的状态,不带账号;歌名只在歌词类表单里带,那一类本来就是问这首歌。
@MainActor
enum FeedbackReporter {
    static func openNewIssue() {
        NSWorkspace.shared.open(FeedbackLinks.newIssueURL(environment()))
    }

    static func openLyricsIssue(_ report: FeedbackLinks.LyricsReport) {
        NSWorkspace.shared.open(FeedbackLinks.lyricsIssueURL(report, environment: environment()))
    }

    static func openEmail() {
        NSWorkspace.shared.open(FeedbackLinks.emailURL(subject: L10n.t("Lyrimuse 反馈"), environment: environment()))
    }

    static func environment() -> FeedbackLinks.Environment {
        FeedbackLinks.Environment(
            appVersion: "\(SparkleUpdaterManager.appVersionString) (\(FeedbackLinks.architectureName))",
            macOSVersion: FeedbackLinks.macOSVersionString(ProcessInfo.processInfo.operatingSystemVersion),
            player: playerName())
    }

    /// 最近认出的那个播放器;还没认出过就列出用户选中的播放器。网页播放器报的是浏览器的媒体进程,换回浏览器本身。
    private static func playerName() -> String {
        if let bundleID = PlaybackCoordinator.shared.resolvedPlayerBundleID, !bundleID.isEmpty {
            if let player = PlaybackPlayer.builtin(forBundleID: bundleID) { return player.displayName }
            let host = TrustedPlayers.mediaProxyOwner(of: bundleID) ?? bundleID
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) {
                return FileManager.default.displayName(atPath: url.path)
            }
            return host
        }
        let selected = FeatureSettingsStore.shared.players
        return PlaybackPlayer.displayOrder
            .filter { $0 != .auto && selected.contains($0) }
            .map(\.displayName)
            .joined(separator: L10n.t("、"))
    }
}
