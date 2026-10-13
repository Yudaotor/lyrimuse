import AppKit
import Foundation
import LyrimuseCore
import SwiftUI

/// 「辅助功能」权限的**唯一状态源**,设置页「播放器」那张卡和引导页那一步共用。
///
/// 替播放器读、按它们的界面:Amazon Music 读进度和按播放模式按钮,QQ 音乐 / 网易云按自己的菜单,酷狗 / 汽水音乐按喜欢(`PlaybackPlayer.accessibilityUse`)。
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
    /// 这台机器上授权成功过(`PermissionGrantMemory`)。没授权时据此说「授权已失效」、按钮直接开系统设置。
    @Published private(set) var everGranted: Bool

    private init() {
        trusted = AccessibilitySkipPress.isTrusted
        everGranted = PermissionGrantMemory.everGranted(PermissionGrantMemory.accessibilityKey)
        noteGranted()
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
        noteGranted()
    }

    private func noteGranted() {
        guard trusted, !everGranted else { return }
        PermissionGrantMemory.record(PermissionGrantMemory.accessibilityKey)
        everGranted = true
    }

    /// 行尾那颗按钮:没弹过对话框、也没授权过时先弹(系统会把 Lyrimuse 加进列表、对话框里自带「打开系统设置」),
    /// 否则直接开设置。授权失效时列表里还留着旧的那条,弹对话框不会替换它。
    func handleAction() {
        if prompted || everGranted {
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

    var actionTitle: String { prompted || everGranted ? L10n.t("打开系统设置") : L10n.t("请求权限") }
    var caption: String { trusted ? L10n.t("已授权") : everGranted ? L10n.t("授权已失效") : L10n.t("未获授权") }

    /// 没授权时怎么补,两个界面共用。授权过的直接讲删掉再加回来:失效的那条留在列表里、开关亮着,关了再开不管用。
    /// macOS 27 改了系统页面的名字,TCC 类型和设置深链仍是 Accessibility。
    private var settingsPaneTitle: String {
        if #available(macOS 27, *) { return L10n.t("设备控制和数据访问") }
        return L10n.t("辅助功能")
    }

    var steps: String {
        everGranted
            ? String(format: L10n.t("授权已失效。请在「系统设置 → 隐私与安全性 → %@」中移除旧条目，重新添加当前运行的 Lyrimuse.app，然后重启 Lyrimuse。"), settingsPaneTitle)
            : String(format: L10n.t("在「系统设置 → 隐私与安全性 → %@」中开启 Lyrimuse。列表里没有时，用「+」添加当前运行的 Lyrimuse.app；已开启却仍无效时，移除旧条目并重新添加，然后重启 Lyrimuse。"), settingsPaneTitle)
    }
    var iconName: String { trusted ? "checkmark.circle.fill" : "xmark.circle.fill" }
    var iconColor: Color { trusted ? .green : .orange }

    /// 「Amazon Music」—— 说明文字里替哪几家要。拼接走 `L10n.list`(按界面语言,见 `SettingsToggleSummary` 头注)。
    func playerNames(_ players: [PlaybackPlayer]) -> String {
        L10n.list(players.map(\.displayName))
    }
}

/// 设置页没授权时那段:怎么补 + 动作。「为什么要这项授权」在行尾的「?」里(`reason`),这里不重复。
struct AccessibilityPermissionGuide: View {
    @ObservedObject private var model = AccessibilityPermission.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.steps)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(model.actionTitle) { model.handleAction() }
            }
            .padding(.top, 2)
        }
    }

    /// 「为什么要这项授权」那一句,按用途(`PlaybackPlayer.accessibilityUse`)各说一句:读进度的那几家顺带按随机 / 循环键,切模式的按菜单项。
    @MainActor
    static func reason(_ players: [PlaybackPlayer]) -> String {
        let model = AccessibilityPermission.shared
        var lines: [String] = []
        let progress = players.filter { $0.accessibilityUse == .calibratesProgress }
        if !progress.isEmpty {
            lines.append(String(format: L10n.t("%@ 不向系统报告播放进度。授权后 Lyrimuse 会读取它界面上的播放时间来校准，并在你点随机、循环键时替你按下对应按钮。不授权也能用，但自动连播时进度可能差一两秒，也没有这两颗键。"),
                                model.playerNames(progress)))
        }
        let playMode = players.filter { $0.accessibilityUse == .switchesPlayMode }
        if !playMode.isEmpty {
            lines.append(String(format: L10n.t("%@ 没有脚本接口。授权后 Lyrimuse 会读取并点按它的菜单，以控制随机、循环与喜欢；系统媒体焦点被其它 App 占用时，也能暂停、恢复和切换上下首。不授权也能用，但没有这几颗键，失焦时也无法控制播放。失焦时的进度跳转暂不支持。"),
                                model.playerNames(playMode)))
        }
        let playback = players.filter { $0.accessibilityUse == .controlsPlayback }
        if !playback.isEmpty {
            lines.append(String(format: L10n.t("授权后 Lyrimuse 会读取并点按%@的界面，以显示和切换喜欢；系统媒体焦点被其它 App 占用时，也能暂停、恢复和切换上下首。不授权也能显示歌词，但没有喜欢键，失焦时也无法控制播放；失焦时的进度跳转暂不支持。"),
                                model.playerNames(playback)))
        }
        let favorite = players.filter { $0.accessibilityUse == .pressesFavorite }
        if !favorite.isEmpty {
            lines.append(String(format: L10n.t("授权后 Lyrimuse 会读取%@的喜欢状态，并在你点喜欢键时替你按下它界面上对应的那一项。不授权也能用，只是没有喜欢键。"),
                                model.playerNames(favorite)))
        }
        return lines.joined(separator: "\n")
    }
}
