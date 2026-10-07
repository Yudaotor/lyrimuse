import AppKit
import LyrimuseCore

/// 反馈入口(设置「关于」页、菜单栏右键菜单、歌词搜索面板、选播放器弹层)都走这里:收集版本、系统和播放器,打开 GitHub 的
/// issue 表单或写邮件(链接怎么拼见 `FeedbackLinks`)。只读本机现成的状态,不带账号;歌名只在歌词类表单里带,那一类本来就是
/// 问这首歌。
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

    static func copyEmailAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(FeedbackLinks.feedbackEmail, forType: .string)
    }

    static func environment() -> FeedbackLinks.Environment {
        FeedbackLinks.Environment(
            appVersion: appVersion(),
            macOSVersion: FeedbackLinks.macOSVersionString(ProcessInfo.processInfo.operatingSystemVersion),
            player: playerName())
    }

    /// 「1.9.0 (Apple Silicon)」这样的版本串。
    static func appVersion() -> String {
        "\(SparkleUpdaterManager.appVersionString) (\(FeedbackLinks.architectureName))"
    }

    /// 最近认出的那个播放器;还没认出过就留空,由用户在表单里填。网页播放器报的是浏览器的媒体进程,换回浏览器本身。
    /// 名字跟界面语言走:内置播放器用 App 自己的叫法,别的 App 取它自己在这种语言下的名字(`LocalizedAppName`)。
    private static func playerName() -> String {
        guard let bundleID = PlaybackCoordinator.shared.resolvedPlayerBundleID, !bundleID.isEmpty else { return "" }
        if let player = PlaybackPlayer.builtin(forBundleID: bundleID) { return player.displayName }
        let host = TrustedPlayers.mediaProxyOwner(of: bundleID) ?? bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host),
           let name = LocalizedAppName.name(bundleURL: url, uiLanguage: L10n.current) {
            return name
        }
        return host
    }
}
