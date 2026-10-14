import LyrimuseCore
import SwiftUI

// 设置侧栏的「实验室」:分类下面单独一组的一行,点进来是一页总览,列出住在这里的功能(`AccountDestination.livesInLabs`),
// 每个一行,点了进它原来的那一页。见 14 章决策 106。

/// 侧栏「实验室」那一行。行尾只在住在这里的功能有毛病时亮一枚状态图标(红的优先,其次橙的),配好了、没配都不画:
/// 三个功能各自的绿勾在总览页里看。
struct LabsSidebarRow: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var lastfmConnect = LastfmConnectController.shared
    @ObservedObject private var mirrorStatus = LastfmMirrorStatusWatcher.shared
    @ObservedObject private var relayStatus = RelayPushStatusWatcher.shared
    // 手动切语言时这一行要重画(理由同 AccountSidebarRow)。
    @ObservedObject private var languageSettings = AppSettings.shared

    /// 侧栏宽度按它算(SettingsSidebarWidth)。
    static var title: String { L10n.t("实验室") }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(Self.title)
                if let attention {
                    attention.indicator
                }
            }
        } icon: {
            labsIconBadge()
        }
    }

    private var attention: DestinationStatus? {
        let statuses = AccountDestination.allCases.filter(\.livesInLabs).map {
            destinationStatus(for: $0, config: config, lastfmConnect: lastfmConnect,
                              mirrorInfo: mirrorStatus.info, relayVerdict: relayStatus.verdict)
        }
        if let error = statuses.first(where: { if case .error = $0 { return true } else { return false } }) {
            return error
        }
        return statuses.first {
            switch $0 {
            case .missingCreds, .warning: return true
            default: return false
            }
        }
    }
}

/// 「实验室」的图标:青底烧瓶,跟六个分类一套渐变(配色理由见 `SettingsTab.tint`)。
func labsIconBadge(size: CGFloat = 20, cornerRadius: CGFloat = 5) -> some View {
    iconBadge("flask.fill", tint: settingsHex(0x2AAEC2), top: settingsHex(0x3FBFD0), size: size, cornerRadius: cornerRadius)
}

/// 「实验室」总览页。
struct LabsPage: View {
    let open: (AccountDestination) -> Void

    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var lastfmConnect = LastfmConnectController.shared
    @ObservedObject private var mirrorStatus = LastfmMirrorStatusWatcher.shared
    @ObservedObject private var relayStatus = RelayPushStatusWatcher.shared

    var body: some View {
        SettingsPage(title: L10n.t("实验室"), subtitle: L10n.t("尚未成熟、可能不够完善的功能，之后可能调整、重构或移除")) {
            VStack(spacing: 14) {
                SettingsCard {
                    let destinations = AccountDestination.allCases.filter(\.livesInLabs)
                    ForEach(Array(destinations.enumerated()), id: \.element) { index, destination in
                        if index > 0 { CardDivider() }
                        LabsFeatureRow(
                            destination: destination,
                            status: destinationStatus(for: destination, config: config, lastfmConnect: lastfmConnect,
                                                      mirrorInfo: mirrorStatus.info, relayVerdict: relayStatus.verdict)
                        ) { open(destination) }
                    }
                }
            }
            .background { LastfmGlassGlow() }
        }
        // 语言切换时整页重建,同「软件更新」页。
        .id(L10n.current)
    }
}

/// 总览页里的一行:功能图标、名字和页头那句说明、状态,整行可点。悬停反馈同 `SettingsLinkRow`。
private struct LabsFeatureRow: View {
    let destination: AccountDestination
    let status: DestinationStatus
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
            accountIconBadge(destination, size: 28, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title)
                    .font(.system(size: 13))
                Text(destination.intro)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            status.label
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
