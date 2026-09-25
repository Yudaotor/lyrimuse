import AppKit
import Combine
import Foundation
import LyrimuseCore
import SwiftUI

/// 「自动化」权限的**唯一状态源**,设置页那张卡和引导页那一步共用。
///
/// ## 为什么要收拢
///
/// 需要这份权限的播放器不止一个:有 AppleScript 字典、且本仓真的在向它发 Apple Event 的
/// 每一家都要(判据 `PlaybackPlayer.needsAutomationPermission`,源头在 shared/players.json)。
/// 每多一家就在设置页和引导页各摆一份状态/请求/超时 UI,是三处各写一遍同一套竞态处理
/// (`requestWithTimeout` 的超时赛跑、切回前台重读、已确定就清掉转圈),漂起来谁也发现不了。
/// 状态与动作全部收在这里,两个界面只负责排版。
///
/// ## 「选中即请求」
///
/// 勾上一个播放器的那一刻就主动把系统弹窗要出来(`requestOnSelect`),不等它第一次播歌。
/// 两处入口(设置页网格 / 引导页网格)都接这一个函数。分寸见那个函数的头注 ——
/// 勾「自动识别」时**不拉起**没在跑的播放器。
///
/// ## 装没装
///
/// 列表按"这台机器上真的装了"过滤(`isInstalled`)。没装的播放器给不出权限:
/// `AECreateDesc` 解析不到进程,`check` 只会一直返回 `.notDetermined`,摆在界面上就是
/// 一行永远修不好的「未授权」。这一层刻意留在这里而不是进 `playersNeedingAutomation`
/// 那个纯函数 —— 判据要能被 selftest 钉住,不该依赖这台机器上装了什么。
@MainActor
final class PlayerAutomationPermissions: ObservableObject {
    static let shared = PlayerAutomationPermissions()

    /// 每家各自的授权状态。没查过的当 `.notDetermined`(跟系统那边"还没问过"同义)。
    @Published private(set) var statuses: [PlaybackPlayer: MusicAutomationPermissionStatus] = [:]
    /// 正在等这一家的系统弹窗。
    @Published private(set) var requesting: Set<PlaybackPlayer> = []
    /// 这一家的请求等超时了(`requestWithTimeout` 返回 nil)—— 不是"已拒绝",只是这次不等了。
    @Published private(set) var timedOut: Set<PlaybackPlayer> = []
    /// 上次查询时目标没在运行、结果又是 `.notDetermined`:这时系统给不出真实状态,
    /// 不能显示成「未授权」(见 `MusicAutomationPermission.check(bundleID:askIfNeeded:)`)。
    @Published private(set) var notRunning: Set<PlaybackPlayer> = []

    private init() {}

    func status(_ player: PlaybackPlayer) -> MusicAutomationPermissionStatus {
        statuses[player] ?? .notDetermined
    }

    func isRequesting(_ player: PlaybackPlayer) -> Bool { requesting.contains(player) }
    func hasTimedOut(_ player: PlaybackPlayer) -> Bool { timedOut.contains(player) }
    /// 两个界面据此决定要不要在这一行下面摆 `PlayerAutomationWaitingNote`。
    func showsWaitingNote(_ player: PlaybackPlayer) -> Bool { isRequesting(player) || hasTimedOut(player) }

    /// 这台机器上装了这个播放器没有。Apple Music 是系统自带,实际会被过滤掉的只有别家。
    func isInstalled(_ player: PlaybackPlayer) -> Bool {
        guard !player.bundleIdentifier.isEmpty else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) != nil
    }

    /// 这套选择下要摆出来的那几行:需要权限 ∩ 装了。
    func visiblePlayers(for selection: Set<PlaybackPlayer>) -> [PlaybackPlayer] {
        selection.playersNeedingAutomation.filter(isInstalled)
    }

    /// 重读一遍状态(不弹窗)。
    ///
    /// 查询走 `MusicAutomationPermission.status`(专用线程 + 超时),结果回主 actor 再写;
    /// 超时(nil)就保留上一次的结论不动。
    /// `clearRequestUI` 给"切去系统设置手动开完又切回来"那条路用:状态已经不是
    /// `.notDetermined` 了就把转圈/超时提示一起清掉,不然文字变了、下面还卡着。
    func refresh(_ players: [PlaybackPlayer], clearRequestUI: Bool = false) {
        for player in players {
            let bundleID = player.bundleIdentifier
            guard !bundleID.isEmpty else { continue }
            let running = MusicAutomationPermission.isRunning(bundleID: bundleID)
            Task { [weak self] in
                guard let latest = await MusicAutomationPermission.status(bundleID: bundleID, askIfNeeded: false),
                      let self else { return }
                if self.statuses[player] != latest { self.statuses[player] = latest }
                self.setNotRunning(player, latest == .notDetermined && !running)
                if clearRequestUI, latest != .notDetermined {
                    self.requesting.remove(player)
                    self.timedOut.remove(player)
                }
            }
        }
    }

    /// 勾上一个播放器那一刻主动把权限要出来 —— 两个网格(设置页 / 引导页)点一下就调这里。
    ///
    /// 向谁要、允不允许后台拉起,由 `AutomationRequestPlan.onSelect` 决定(分寸见那边;勾具体
    /// 播放器必须允许拉起 —— 目标没在跑时 `AECreateDesc` 解析不到进程,系统弹窗**压根不出现**,
    /// 见 `MusicAutomationPermission.requestWithTimeout` 头注)。
    ///
    /// 已经有结论的(authorized / denied)在 `request` 里一律不碰:系统不会重复弹窗,再问一次只是白等。
    func requestOnSelect(justEnabled player: PlaybackPlayer) {
        let plan = AutomationRequestPlan.onSelect(
            player, isInstalled: isInstalled,
            isRunning: { MusicAutomationPermission.isRunning(bundleID: $0.bundleIdentifier) })
        for item in plan {
            request(item.player, launchIfNeeded: item.launchIfNeeded)
        }
    }

    /// 真正发起一次请求。
    ///
    /// 不能在按钮点击回调里同步调 `check(askIfNeeded: true)` —— 那会把整个 App UI 冻住、
    /// 表现成"点了没反应"(`AEDeterminePermissionToAutomateTarget` 在主线程有据可查的
    /// 永久挂起,见 `MusicAutomationPermission.requestWithTimeout` 头注)。
    ///
    /// 超时(返回 nil)时停掉转圈、按钮还给用户,同时留着超时提示(「打开系统设置」)。
    /// 那次系统调用可能还挂着;再点一次会合并到同一次调用上等结果,不会并发发起第二次。
    func request(_ player: PlaybackPlayer, launchIfNeeded: Bool = true) {
        let bundleID = player.bundleIdentifier
        guard !bundleID.isEmpty, !requesting.contains(player) else { return }
        guard status(player) == .notDetermined else { return }
        requesting.insert(player)
        timedOut.remove(player)
        Task { [weak self] in
            let result = await MusicAutomationPermission.requestWithTimeout(
                bundleID: bundleID, launchIfNeeded: launchIfNeeded)
            guard let self else { return }
            self.requesting.remove(player)
            if let result {
                self.statuses[player] = result
                self.timedOut.remove(player)
                if result != .notDetermined { self.setNotRunning(player, false) }
            } else {
                self.timedOut.insert(player)
            }
        }
    }

    private func setNotRunning(_ player: PlaybackPlayer, _ value: Bool) {
        guard notRunning.contains(player) != value else { return }
        if value { notRunning.insert(player) } else { notRunning.remove(player) }
    }

    /// 按钮点下去干什么:还没问过就请求(会真的弹系统对话框),已经有结论的系统不会再弹,
    /// 只能引导去系统设置手动改。
    func handleAction(_ player: PlaybackPlayer) {
        if status(player) == .notDetermined {
            request(player, launchIfNeeded: true)
        } else {
            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
        }
    }

    // MARK: - 两个界面共用的措辞

    func actionTitle(_ player: PlaybackPlayer) -> String {
        status(player) == .notDetermined ? L10n.t("请求权限") : L10n.t("打开系统设置")
    }

    func caption(_ player: PlaybackPlayer) -> String {
        switch status(player) {
        case .authorized: return L10n.t("已授权")
        case .denied: return L10n.t("已拒绝")
        case .notDetermined:
            return notRunning.contains(player) ? L10n.t("没在运行，查不到当前状态") : L10n.t("未授权")
        }
    }

    func iconName(_ player: PlaybackPlayer) -> String {
        switch status(player) {
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        }
    }

    func iconColor(_ player: PlaybackPlayer) -> Color {
        switch status(player) {
        case .authorized: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        }
    }

    /// 这几家是不是都授权了 —— 引导页那张体检清单用。
    func allAuthorized(_ players: [PlaybackPlayer]) -> Bool {
        players.allSatisfy { status($0) == .authorized }
    }
}

/// 「正在等系统弹窗」那两行提示。设置页塞进 `SettingsNote`,引导页直接摆,措辞一份。
struct PlayerAutomationWaitingNote: View {
    let timedOut: Bool

    var body: some View {
        if timedOut {
            Text(L10n.t("这次请求耗时有点久。如果你已经看到系统弹窗，请去处理它；找不到弹窗的话，可以直接去系统设置里手动开启"))
            Button(L10n.t("打开系统设置")) {
                NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
            }
        } else {
            Text(L10n.t("请查看屏幕上弹出的系统授权对话框，选择「允许」"))
        }
    }
}
