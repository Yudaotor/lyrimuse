import AppKit
import Foundation
import LyrimuseCore
import SwiftUI

/// 「辅助功能」权限的**唯一状态源**,设置页「播放器」那张卡和引导页那一步共用。
///
/// 替播放器要的这份权限只给读界面用(Amazon Music:读界面上的播放时间校准进度,见 `AmazonMusicUIProbe`),
/// 判据是 `Set<PlaybackPlayer>.playersNeedingAccessibility`。授权是整个 App 一份,两个界面都只摆**一行**,
/// 替哪几家要只出现在「为什么要这项授权」那句里(`AccessibilityPermissionGuide.reason`)。
///
/// 系统只给一个布尔(`AXIsProcessTrusted`),分不出「没问过」和「拒绝了」,也不推送变化:两个界面在出现时、
/// 回到前台时和定时轮询里调 `refresh()`。这次运行里弹过一次系统对话框之后,按钮换成「打开系统设置」。
@MainActor
final class AccessibilityPermission: ObservableObject {
    static let shared = AccessibilityPermission()

    @Published private(set) var trusted: Bool
    @Published private(set) var prompted = false

    private init() {
        trusted = AccessibilitySkipPress.isTrusted
    }

    /// 这套选择下要替哪几家说话:需要 ∩ 装了。没装的播放器没有界面可读。
    func visiblePlayers(for selection: Set<PlaybackPlayer>) -> [PlaybackPlayer] {
        selection.playersNeedingAccessibility.filter { player in
            !player.bundleIdentifier.isEmpty
                && NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) != nil
        }
    }

    /// 重读授权状态(一次系统调用,可以定时调)。
    func refresh() {
        let now = AccessibilitySkipPress.isTrusted
        if now != trusted { trusted = now }
    }

    /// 行尾那颗按钮:没弹过对话框先弹(系统会把 Lyrimuse 加进列表、对话框里自带「打开系统设置」),弹过就直接开设置。
    func handleAction() {
        if prompted {
            openSystemSettings()
        } else {
            prompted = true
            AccessibilitySkipPress.promptForTrust()
        }
        refresh()
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 两个界面共用的措辞

    var actionTitle: String { prompted ? L10n.t("打开系统设置") : L10n.t("请求权限") }
    var caption: String { trusted ? L10n.t("已授权") : L10n.t("未获授权") }
    var iconName: String { trusted ? "checkmark.circle.fill" : "xmark.circle.fill" }
    var iconColor: Color { trusted ? .green : .orange }

    /// 「Amazon Music」—— 说明文字里替哪几家要。拼接走 `ListFormatter`(见 `SettingsToggleSummary` 头注)。
    func playerNames(_ players: [PlaybackPlayer]) -> String {
        ListFormatter.localizedString(byJoining: players.map(\.displayName))
    }
}

/// 没授权时那段说明 + 动作。设置页塞进 `SettingsNote`,引导页直接摆,措辞一份。
struct AccessibilityPermissionGuide: View {
    let players: [PlaybackPlayer]
    /// 要不要先讲一句「为什么要这项授权」。引导页那一步卡片下面已经讲过,传 false。
    var showsReason = true
    @ObservedObject private var model = AccessibilityPermission.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsReason {
                Text(Self.reason(players))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.t("请在系统设置的「辅助功能」中开启 Lyrimuse。如已授权但此处仍显示未授权，请将 Lyrimuse 取消勾选后重新勾选。"))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(model.actionTitle) { model.handleAction() }
            }
            .padding(.top, 2)
        }
    }

    /// 「为什么要这项授权」那一句,按用途(`PlaybackPlayer.accessibilityUse`)各说一句:读进度只读不点,切模式会按菜单项。
    @MainActor
    static func reason(_ players: [PlaybackPlayer]) -> String {
        let model = AccessibilityPermission.shared
        var lines: [String] = []
        let progress = players.filter { $0.accessibilityUse == .calibratesProgress }
        if !progress.isEmpty {
            lines.append(String(format: L10n.t("%@ 不向系统报告播放进度，Lyrimuse 会读取其界面上的播放时间来校准进度（仅读取，不会点按任何按钮）。不授权也可使用，但自动连播时进度可能偏差一到两秒。"),
                                model.playerNames(progress)))
        }
        let playMode = players.filter { $0.accessibilityUse == .switchesPlayMode }
        if !playMode.isEmpty {
            lines.append(String(format: L10n.t("%@ 没有脚本接口，Lyrimuse 会通过其菜单栏里的「播放模式」读取和切换随机、循环（只在你点这两颗键时按下对应的菜单项）。不授权也可使用，只是不显示这两颗键。"),
                                model.playerNames(playMode)))
        }
        return lines.joined(separator: "\n")
    }
}
