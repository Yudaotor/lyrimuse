import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 此刻的「Last.fm 账号建议」:侧栏那一行出不出现、计数几条,建议页列哪几条。连接流程、授权状态、Spotify 连接、账号一变
/// 就重算;排序与判据在 Core `LastfmAccountSuggestion.current`。只发布这一份列表,侧栏不必为它去订阅那几个来源。
@MainActor
final class LastfmSuggestionsStore: ObservableObject {
    static let shared = LastfmSuggestionsStore()

    @Published private(set) var items: [LastfmAccountSuggestion] = []

    private var observer: AnyCancellable?

    private init() {
        // 这几个都在改之前发,延一拍再读。
        observer = Publishers.Merge4(
            LastfmMirrorStatusWatcher.shared.$info.map { _ in () },
            LastfmConnectController.shared.$state.map { _ in () },
            LastfmSpotifyLinkMonitor.shared.$hint.map { _ in () },
            ConfigStore.shared.objectWillChange.map { _ in () }
        )
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        var connectFailure: String?
        if case .failed(let message) = LastfmConnectController.shared.state { connectFailure = message }
        let next = LastfmAccountSuggestion.current(
            connectFailure: connectFailure,
            connected: !ConfigStore.shared.lastfmScrobbleSessionKey.isEmpty,
            authRevoked: LastfmMirrorStatusWatcher.shared.info != nil,
            spotify: LastfmSpotifyLinkMonitor.shared.hint)
        if next != items { items = next }
    }
}

/// 一条建议的排法(仿系统设置「Apple 账户建议」里的一行):左边彩色方块图标,中间标题和一句说明,右边按钮并排、同一种样式。
struct LastfmSuggestionRowLayout<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            iconBadge(icon, tint: tint, size: 28, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                actions()
            }
            .fixedSize()
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}

/// 授权失效 / 连接失败那一条:要重新连接。
struct LastfmReconnectSuggestionRow: View {
    let title: String
    let detail: String

    var body: some View {
        LastfmSuggestionRowLayout(icon: "exclamationmark", tint: .red, title: title, detail: detail) {
            // 切到 Last.fm 页并直接打开连接向导(向导是那一页的 sheet,见 AppActions.requestLastfmWizard)。
            Button(L10n.t("重新连接…")) {
                AppActions.shared.requestLastfmWizard()
                AppActions.shared.requestSettings(.account(.lastfm))
            }
        }
    }
}

/// Last.fm 跟 Spotify 的连接让 Spotify 重复记或漏记时的那一条建议,按钮点了才改,不替用户改勾选。Last.fm 账号页的「建议」
/// 分组和「Last.fm 账号建议」页共用;判据在 `LastfmSpotifyLinkMonitor.hint`。
struct LastfmSpotifySuggestionRow: View {
    let hint: LastfmSpotifyLink.PlayersRowHint

    var body: some View {
        LastfmSuggestionRowLayout(icon: "music.note", tint: .green, title: hint.headline, detail: detail) {
            switch hint {
            case .doubleScrobble:
                // 留哪一边:这边取消勾选(之后只由 Last.fm 记,其它设备上听的也算),或者去 Last.fm 断开(之后只记这台 Mac)。
                Button(L10n.t("仅由 Last.fm 记录")) {
                    let spotify = PlaybackPlayer.spotify.bundleIdentifier
                    Task { await FeatureSettingsStore.shared.updateLastfmExclusion(scrobbled: [], excluded: [spotify]) }
                }
                .help(L10n.t("在「Scrobble 的播放器」中取消勾选 Spotify；在手机等其他设备上收听的 Spotify 仍会照常记录。"))
                Button(L10n.t("仅由 Lyrimuse 记录…")) { openLastfmApplications() }
                    .help(L10n.t("打开 Last.fm 网站，在「Spotify Scrobbling」一栏点按 Disconnect；之后仅记录这台 Mac 上播放的 Spotify。"))
            case .expiredWhileExcluded:
                Button(L10n.t("前往 Last.fm 重新连接…")) { openLastfmApplications() }
                    .help(L10n.t("打开 Last.fm 网站，在「Spotify Scrobbling」一栏点按 Connect。"))
            }
        }
    }

    private var detail: String {
        switch hint {
        case .doubleScrobble:
            return L10n.t("Last.fm 已直接连接 Spotify，Lyrimuse 也在记录，保留其中一方即可。")
        case .expiredWhileExcluded(let at):
            return String(format: L10n.t("Last.fm 与 Spotify 的连接已于 %@ 过期，Lyrimuse 中也未勾选 Spotify。"),
                          at.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L10n.locale)))
        }
    }

    /// Last.fm 网站上管 Spotify 连接的那一页。在那边改完回到这里时重查一次,提示跟着变,不等每天那一次。
    private func openLastfmApplications() {
        LastfmSpotifyLinkMonitor.shared.recheckWhenBack()
        NSWorkspace.shared.open(URL(string: "https://www.last.fm/settings/applications")!)
    }
}

/// 「Last.fm 账号建议」页:侧栏那一行(仿系统设置「Apple 账户建议」)点进来的页面,每条建议一行,要紧的在前。处理完侧栏那一行
/// 就消失,这一页还停着的话显示一句没有建议。
struct LastfmSuggestionsPage: View {
    @ObservedObject private var suggestions = LastfmSuggestionsStore.shared

    var body: some View {
        // 窗口副标题已经写着「Last.fm 账号建议」,页内不再画大标题(同「软件更新」页)。
        SettingsPage(title: L10n.t("Last.fm 账号建议"), showsHeader: false) {
            SettingsCard {
                if suggestions.items.isEmpty {
                    Text(L10n.t("暂无待处理的建议"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else {
                    ForEach(Array(suggestions.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { CardDivider() }
                        row(item)
                    }
                }
            }
        }
        // 语言切换时整页重建,同「软件更新」页。
        .id(L10n.current)
    }

    @ViewBuilder
    private func row(_ item: LastfmAccountSuggestion) -> some View {
        switch item {
        case .connectFailed(let message):
            LastfmReconnectSuggestionRow(title: L10n.t("无法连接 Last.fm"), detail: message)
        case .authRevoked:
            LastfmReconnectSuggestionRow(title: L10n.t("授权已失效，Scrobble 已暂停"),
                                         detail: L10n.t("授权可能已在 Last.fm 网站上被撤销，重新连接即可恢复。"))
        case .spotify(let hint):
            LastfmSpotifySuggestionRow(hint: hint)
        }
    }
}
