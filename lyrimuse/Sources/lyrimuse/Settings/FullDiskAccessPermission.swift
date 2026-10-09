import AppKit
import Combine
import Foundation
import LyrimuseCore
import SwiftUI

/// 「完全磁盘访问」的**唯一状态源**,设置页「播放器」那张卡和引导页那一步共用。
///
/// 结论只认引擎发布的 `LocalCacheAccess`:授权两个进程共用一份,却在每个进程里各自生效,
/// 真正去读客户端容器的是引擎(见 `LocalCacheAccess` 头注)。这里只做三件事:
/// 哪几家要摆出来(`visiblePlayers`)、把这几家合成一个结论(`grant`)、「重启后台服务」之后
/// 一直等到引擎发布了新结论才算完(`restartEngine`)。
///
/// 授权是整个 App 一份,不是每个播放器一份 —— 所以两个界面都只摆**一行**,标题是这项权限本身,
/// 替哪几家要只出现在「为什么要这项授权」那句里(`FullDiskAccessGuide.reason`)。
@MainActor
final class FullDiskAccessPermission: ObservableObject {
    static let shared = FullDiskAccessPermission()

    enum RestartPhase: Equatable {
        case idle
        /// 已经发起重启,正在等引擎发布新结论。
        case waiting
        /// 引擎重启后发布的结论仍然是被拒。
        case stillDenied
    }

    @Published private(set) var state: LocalCacheAccess.State?
    @Published private(set) var restartPhase: RestartPhase = .idle
    /// 这台机器上授权成功过(`PermissionGrantMemory`)。被拒时据此说「授权已失效」。
    @Published private(set) var everGranted: Bool
    /// 上一次「重启后台服务」替哪几家等的结论 —— `.stillDenied` 要在它们不再被拒时自己撤掉。
    private var restartTargets: [PlaybackPlayer] = []

    /// 引擎启动时先探容器再跑耗时的启动迁移(localcacheprobe.go),新结论通常几秒内就到;
    /// 这个上限只兜引擎起不来的情况。
    private static let settleTimeout: TimeInterval = 90
    private static let pollInterval: TimeInterval = 1

    private init() {
        state = LocalCacheAccess.current
        everGranted = PermissionGrantMemory.everGranted(PermissionGrantMemory.fullDiskAccessKey)
        noteGranted()
    }

    /// 这套选择下要替哪几家说话:需要授权 ∩ 装了。没装的播放器没有容器,引擎不会探它,
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

    /// 重读引擎发布的状态(按 mtime 缓存,很便宜,可以定时调)。
    func refresh() {
        let latest = LocalCacheAccess.current
        if latest != state { state = latest }
        noteGranted()
        if restartPhase == .stillDenied, grant(restartTargets) != .denied {
            restartPhase = .idle
        }
    }

    /// 引擎读得到任意一家,授权就是在生效的,记下来。
    private func noteGranted() {
        guard !everGranted, let state, !state.readable.isEmpty else { return }
        PermissionGrantMemory.record(PermissionGrantMemory.fullDiskAccessKey)
        everGranted = true
    }

    func openSystemSettings() {
        if let url = LocalCacheAccess.fullDiskAccessSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// 重启引擎,然后**一直等到它发布了这次启动之后的结论**才算完。
    ///
    /// `requestRestart()` 返回只代表 launchd 报出了新 pid;状态文件在那之后才被新进程删掉重写,
    /// 所以判据是「文件里的 updatedAt 不早于发起重启那一刻」。
    func restartEngine(for players: [PlaybackPlayer]) async {
        guard restartPhase != .waiting else { return }
        restartPhase = .waiting
        restartTargets = players
        let startedAt = Int64(Date().timeIntervalSince1970)
        _ = await EngineRestartCoordinator.shared.requestRestart()
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
        case .denied: return everGranted ? L10n.t("授权已失效") : L10n.t("未获授权")
        case .unknown: return L10n.t("尚未确认")
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

    /// 没授权时怎么补,两个界面共用。授权过的直接讲删掉再加回来:失效的那条留在列表里、开关亮着,关了再开不管用。
    var steps: String {
        everGranted
            ? L10n.t("更新后，之前的授权已失效。请在系统设置中用「−」移除 Lyrimuse，再用「+」重新添加，然后点「重启歌词引擎」。")
            : L10n.t("在系统设置中打开 Lyrimuse，然后点「重启歌词引擎」。开关已打开却仍未生效时，用「−」移除 Lyrimuse，再用「+」重新添加。")
    }

    var stillDeniedNote: String { L10n.t("重启后仍无法读取。请确认 Lyrimuse 已打开；已打开时，用「−」移除后再用「+」重新添加。") }

    /// 「QQ 音乐和酷狗音乐」—— 说明文字里替哪几家要。拼接走 `L10n.list`(按界面语言,见
    /// `SettingsToggleSummary` 头注)。
    func playerNames(_ players: [PlaybackPlayer]) -> String {
        L10n.list(players.map(\.displayName))
    }
}

/// 设置页没授权时那段:怎么补 + 两个动作。「为什么要这项授权」在行尾的「?」里(`reason`),这里不重复。
///
/// 「打开系统设置」和「重启后台服务」必须并排:TCC 的权限在进程启动那一刻定下,运行中授权
/// 不会补发给已经在跑的引擎(见第 09 章「kugou 的本地快速路径」)。
struct FullDiskAccessGuide: View {
    let players: [PlaybackPlayer]
    @ObservedObject private var model = FullDiskAccessPermission.shared
    @ObservedObject private var coordinator = EngineRestartCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.steps)
                .fixedSize(horizontal: false, vertical: true)
            switch model.restartPhase {
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在重启歌词引擎并重新检查授权…"))
                }
            case .stillDenied:
                Text(model.stillDeniedNote)
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
        String(format: L10n.t("%@ 的歌词缓存和播放队列在受保护的目录中。授权后可直接使用本机已有的歌词，并提前解析即将播放的歌曲；不授权也能联网查找歌词。"),
               FullDiskAccessPermission.shared.playerNames(players))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L10n.t("打开系统设置")) { model.openSystemSettings() }
            Button(L10n.t("重启歌词引擎")) {
                Task { await model.restartEngine(for: players) }
            }
            .disabled(coordinator.isRestarting)
        }
        .padding(.top, 2)
    }
}
