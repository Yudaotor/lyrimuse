import AppKit
import LyrimuseCore
import SwiftUI

/// 「歌词来源」卡里那颗橙色锁点开后的说明。
///
/// 必须讲两件事,少一件用户就会卡在半路:①要授权「完全磁盘访问」;②**授权对已经在运行的
/// 引擎不生效**。TCC 的权限在进程启动那一刻就定下了,运行中授权不会补发给它 —— 只讲第一件,
/// 用户照做完回来看见提示还在,得到的结论是"授权没用"(实测走到过这一步)。所以「重启后台服务」
/// 跟「打开系统设置」并列摆着,不藏在别处、也不只写在文字里。
///
/// 这段说明走 popover 而不是 `.help` 的 tooltip:这颗锁只有 12pt,tooltip 要精确悬停在它上面
/// 并停住才出得来,而它恰恰是**唯一**能解释"为什么这个源没在用本地缓存"的地方。tooltip 仍然留着,
/// 作鼠标党的快速通道,但它不再是唯一的出口。
struct LocalCacheAccessHelp: View {
    let source: LyricsSource
    /// 这个源真的不再被挡住了(引擎重新发布了状态)。调用方据此收起说明。
    let onResolved: () -> Void

    @ObservedObject private var coordinator = EngineRestartCoordinator.shared
    @State private var phase: Phase = .idle

    private enum Phase { case idle, waiting, stillDenied }

    /// 等引擎重新发布状态的上限。
    ///
    /// 别按「重启要多久」定这个数 —— `requestRestart()` 返回时 launchd 才刚报出新 pid(1~3 秒),
    /// 而引擎要在几万个歌词文件之上跑完启动流程、真的去读一次客户端缓存,才会重新发布这份
    /// 名单。实测一次完整启动 2 分钟以上(见 09 章决策 65 里量的那组数),4 分钟是留足余量的上限,
    /// 不是预期值。
    private static let settleTimeout: TimeInterval = 240
    private static let pollInterval: TimeInterval = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(String(format: L10n.t("无法读取 %@ 的歌词缓存"), source.displayName),
                  systemImage: "lock.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(String(format: L10n.t("%@ 的歌词缓存位于受系统保护的目录中。授予「完全磁盘访问权限」后，可直接使用本机已有的逐字歌词，无需每次联网搜索。"),
                        source.displayName))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.t("授权不会作用于已在运行的歌词引擎。在系统设置中勾选后，请回到此处点按「重启歌词引擎」。"))
                .fixedSize(horizontal: false, vertical: true)
            switch phase {
            case .waiting:
                // 进度里明说要等多久。这一步真的慢(引擎要把整个歌词库重新读一遍),
                // 不说清楚的话用户会以为按钮没反应、反复点。
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在重启歌词引擎，需要重新读取歌词缓存，通常需要一到两分钟…"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            case .stillDenied:
                Text(L10n.t("歌词引擎已重启，但仍无法读取此源。请在系统设置的「完全磁盘访问权限」中确认 Lyrimuse 已开启。"))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            case .idle:
                actions
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(13)
        .frame(width: 310, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L10n.t("打开系统设置")) {
                if let url = LocalCacheAccess.fullDiskAccessSettingsURL {
                    NSWorkspace.shared.open(url)
                }
            }
            Button(L10n.t("重启歌词引擎")) {
                Task { await restartAndWaitForState() }
            }
            .disabled(coordinator.isRestarting)
        }
        .padding(.top, 2)
    }

    /// 重启引擎,然后**一直等到它重新发布状态**才算完。
    ///
    /// 别在 `requestRestart()` 返回时就宣布完成:那只代表 launchd 收下了指令并报出新 pid,
    /// 这一刻状态文件里还是上一轮的结论。按钮的完成信号跟用户看得见的结果之间差着一个数量级,
    /// 而中间这段时间正是用户判断"这个按钮到底有没有用"的时候。
    private func restartAndWaitForState() async {
        phase = .waiting
        let startedAt = Int64(Date().timeIntervalSince1970)
        _ = await coordinator.requestRestart()
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(Self.pollInterval))
            // 只认这次重启之后发布的结论,而且要明确是「读得到」:新进程启动时先删掉状态文件再重写,
            // 那段空窗里「不是被拒」只是没有数据(判据同 FullDiskAccessPermission.restartEngine)。
            guard let state = LocalCacheAccess.current, state.updatedAt >= startedAt else { continue }
            if LocalCacheAccess.grant(for: [source.rawValue], state: state) == .granted {
                onResolved()
                return
            }
        }
        // 超时不等于"授权肯定错了" —— 也可能引擎还没轮到去读这个源。文案因此只请用户
        // 回去核对那一项,不断言是哪种情况。
        phase = .stillDenied
    }
}
