import LyrimuseCore
import SwiftUI

/// 「歌词来源」卡里那颗橙色三角点开后的说明:这个源最近哪里不正常、依据的数字是多少。判定和数字都是
/// 引擎统计的(`LyricSourceHealth`),这里只负责说成人话。
struct LyricSourceHealthHelp: View {
    let source: LyricsSource
    let summary: LyricSourceHealth.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(detail)
                .fixedSize(horizontal: false, vertical: true)
            if summary.rounds > 0 {
                Text(String(format: L10n.t("近 7 天：查询 %1$d 次，返回歌词 %2$d%%，被选用 %3$d%%"),
                            summary.rounds,
                            LyricSourceHealth.percent(summary.responded, of: summary.rounds),
                            LyricSourceHealth.percent(summary.won, of: summary.rounds)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.t("其他歌词源照常搜索，只要有其他源找到歌词，就不受影响。这些数据仅在本机统计。"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(13)
        .frame(width: 310, alignment: .leading)
    }

    private var title: String {
        let name = source.displayName
        switch summary.alert {
        case .barely: return String(format: L10n.t("%@ 近期几乎未返回歌词"), name)
        case .belowUsual: return String(format: L10n.t("%@ 近期找到的歌词明显少于平时"), name)
        case .cooling: return String(format: L10n.t("%@ 近期频繁出错"), name)
        case .blocked: return String(format: L10n.t("%@ 拒绝了这台 Mac 的请求"), name)
        case .stopped: return String(format: L10n.t("%@ 突然不再返回歌词"), name)
        case .network, nil: return String(format: L10n.t("%@ 近期频繁无法连接"), name)
        }
    }

    private var detail: String {
        let name = source.displayName
        let peerRate = LyricSourceHealth.percent(summary.peerRate)
        let skipRate = LyricSourceHealth.percent(summary.skipRate)
        switch summary.alert {
        case .barely:
            return String(format: L10n.t("最近 3 天的 %1$d 次查询中，同类曲库至少有两家找到了歌词，而 %2$@ 仅在其中 %3$d%% 提供了歌词。可能是其接口发生变化，或请求被拦截。"),
                          summary.peerRounds, name, peerRate)
        case .belowUsual:
            // 「平时」是引擎按这几天两类歌(中日韩文 / 其他)各占多少现算的,不是这个源过去的总比例。
            return String(format: L10n.t("最近 3 天的 %1$d 次查询中，同类曲库至少有两家找到了歌词，%2$@ 在其中 %3$d%% 提供了歌词；按这几天所听歌曲的语种构成，平时约为 %4$d%%。"),
                          summary.peerRounds, name, peerRate, LyricSourceHealth.percent(summary.usualRate))
        case .cooling:
            return String(format: L10n.t("最近 2 天有 %1$d%% 的查询未使用 %2$@：该源连续出错，已被暂时停用，稍后将自动恢复。"),
                          skipRate, name)
        case .blocked:
            return String(format: L10n.t("%1$@ 的反爬限制拦下了这台 Mac 的请求，最近有 %2$d 次查询因此未使用它。已暂时停用，稍后将自动重试。"),
                          name, summary.blockedRounds)
        case .stopped:
            return String(format: L10n.t("最近连续 %1$d 次查询中，同类曲库至少有两家找到了歌词，%2$@ 一次也没有提供；按它平时的收录情况，本该提供约 %3$d 次。可能是其接口发生变化，或请求被拦截。"),
                          summary.streak, name, summary.expectedHits)
        case .network, nil:
            let peers = summary.networkPeers.map(sourceDisplayName).joined(separator: L10n.t("、"))
            return String(format: L10n.t("最近 2 天有 %1$d%% 的查询因无法连接 %2$@ 而跳过，%3$@ 也是如此。多个源同时无法连接，通常是这台 Mac 无法访问这些网站（例如需要开启代理），而非歌词源本身故障。"),
                          skipRate, name, peers)
        }
    }
}
