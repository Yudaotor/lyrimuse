import AppKit
import Combine
import Foundation
import LyrimuseCore
import SwiftUI

/// 「完全磁盘访问」的**唯一状态源**,设置页「播放器」那张卡和引导页那一步共用。
///
/// 结论只认 collector 发布的 `LocalCacheAccess`:App 与 collector 是两个进程、TCC 授权各自独立,
/// 真正去读客户端容器的是 collector(见 `LocalCacheAccess` 头注)。这里只做三件事:
/// 哪几家要摆出来(`visiblePlayers`)、把这几家合成一个结论(`grant`)、「重启后台服务」之后
/// 一直等到 collector 发布了新结论才算完(`restartCollector`)。
///
/// 授权是整个 App 一份,不是每个播放器一份 —— 所以两个界面都只摆**一行**,标题是这项权限本身,
/// 替哪几家要只出现在「为什么要这项授权」那句里(`FullDiskAccessGuide.reason`)。
@MainActor
final class FullDiskAccessPermission: ObservableObject {
    static let shared = FullDiskAccessPermission()

    enum RestartPhase: Equatable {
        case idle
        /// 已经发起重启,正在等 collector 发布新结论。
        case waiting
        /// collector 重启后发布的结论仍然是被拒。
        case stillDenied
    }

    @Published private(set) var state: LocalCacheAccess.State?
    @Published private(set) var restartPhase: RestartPhase = .idle
    /// 上一次「重启后台服务」替哪几家等的结论 —— `.stillDenied` 要在它们不再被拒时自己撤掉。
    private var restartTargets: [PlaybackPlayer] = []

    /// collector 启动时先探容器再跑耗时的启动迁移(localcacheprobe.go),新结论通常几秒内就到;
    /// 这个上限只兜 collector 起不来的情况。
    private static let settleTimeout: TimeInterval = 90
    private static let pollInterval: TimeInterval = 1

    private init() {
        state = LocalCacheAccess.current
    }

    /// 这套选择下要替哪几家说话:需要授权 ∩ 装了。没装的播放器没有容器,collector 不会探它,
    /// 摆出来就是一行永远确认不了的状态。
    func visiblePlayers(for selection: Set<PlaybackPlayer>) -> [PlaybackPlayer] {
        selection.playersNeedingFullDiskAccess.filter { player in
            !player.bundleIdentifier.isEmpty
                && NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) != nil
        }
    }

    /// 这几家合起来的结论。状态文件里的来源名就是各家的 `nativeLyricSource`。
    func grant(_ players: [PlaybackPlayer]) -> LocalCacheAccess.Grant {
        LocalCacheAccess.grant(for: players.compactMap(\.nativeLyricSource), state: state)
    }

    /// 重读 collector 发布的状态(按 mtime 缓存,很便宜,可以定时调)。
    func refresh() {
        let latest = LocalCacheAccess.current
        if latest != state { state = latest }
        if restartPhase == .stillDenied, grant(restartTargets) != .denied {
            restartPhase = .idle
        }
    }

    func openSystemSettings() {
        if let url = LocalCacheAccess.fullDiskAccessSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// 重启 collector,然后**一直等到它发布了这次启动之后的结论**才算完。
    ///
    /// `requestRestart()` 返回只代表 launchd 报出了新 pid;状态文件在那之后才被新进程删掉重写,
    /// 所以判据是「文件里的 updatedAt 不早于发起重启那一刻」。
    func restartCollector(for players: [PlaybackPlayer]) async {
        guard restartPhase != .waiting else { return }
        restartPhase = .waiting
        restartTargets = players
        let startedAt = Int64(Date().timeIntervalSince1970)
        _ = await CollectorRestartCoordinator.shared.requestRestart()
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(Self.pollInterval))
            refresh()
            guard let state, state.updatedAt >= startedAt else { continue }
            switch grant(players) {
            case .granted:
                restartPhase = .idle
                return
            case .denied:
                restartPhase = .stillDenied
                return
            case .unknown:
                continue
            }
        }
        restartPhase = grant(players) == .denied ? .stillDenied : .idle
    }

    // MARK: - 两个界面共用的措辞

    func caption(_ players: [PlaybackPlayer]) -> String {
        switch grant(players) {
        case .granted: return L10n.t("已授权")
        case .denied: return L10n.t("没有授权")
        case .unknown: return L10n.t("还没确认")
        }
    }

    func iconName(_ players: [PlaybackPlayer]) -> String {
        switch grant(players) {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    func iconColor(_ players: [PlaybackPlayer]) -> Color {
        switch grant(players) {
        case .granted: return .green
        case .denied: return .red
        case .unknown: return .orange
        }
    }

    /// 「QQ 音乐和酷狗音乐」—— 说明文字里替哪几家要。拼接走 `ListFormatter`(见
    /// `SettingsToggleSummary` 头注)。
    func playerNames(_ players: [PlaybackPlayer]) -> String {
        ListFormatter.localizedString(byJoining: players.map(\.displayName))
    }
}

/// 没授权时那段说明 + 两个动作。设置页塞进 `SettingsNote`,引导页直接摆,措辞一份。
///
/// 「打开系统设置」和「重启后台服务」必须并排:TCC 的权限在进程启动那一刻定下,运行中授权
/// 不会补发给已经在跑的 collector(见第 09 章「kugou 的本地快速路径」)。
struct FullDiskAccessGuide: View {
    let players: [PlaybackPlayer]
    /// 要不要先讲一句「为什么要这项授权」。引导页那一步的正文已经讲过,传 false。
    var showsReason = true
    @ObservedObject private var model = FullDiskAccessPermission.shared
    @ObservedObject private var coordinator = CollectorRestartCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsReason {
                Text(FullDiskAccessGuide.reason(players))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.t("在系统设置的「完全磁盘访问权限」里打开 Lyrimuse（列表里没有就点「+」把它加进去），再回到这里点「重启后台服务」——授权对已经在运行的后台服务不生效。"))
                .fixedSize(horizontal: false, vertical: true)
            switch model.restartPhase {
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在重启后台服务，等它重新确认授权…"))
                }
            case .stillDenied:
                Text(L10n.t("后台服务已经重启过了，还是读不到。到系统设置的「完全磁盘访问权限」里确认一下 Lyrimuse 那一项是开着的。"))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            case .idle:
                actions
            }
        }
    }

    /// 「为什么要这项授权」那一句,引导页正文也用它。
    @MainActor
    static func reason(_ players: [PlaybackPlayer]) -> String {
        String(format: L10n.t("%@ 把歌词缓存和播放队列放在受系统保护的目录里。授权后，本机已有的歌词可以直接用，还能提前解析接下来要播的歌；不授权歌词照样能联网找到。"),
               FullDiskAccessPermission.shared.playerNames(players))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L10n.t("打开系统设置")) { model.openSystemSettings() }
            Button(L10n.t("重启后台服务")) {
                Task { await model.restartCollector(for: players) }
            }
            .disabled(coordinator.isRestarting)
        }
        .padding(.top, 2)
    }
}
