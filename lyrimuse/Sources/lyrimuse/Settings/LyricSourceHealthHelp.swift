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
                Text(String(format: L10n.t("近 7 天：查了 %1$d 次，给出歌词 %2$d%%，被选中 %3$d%%"),
                            summary.rounds,
                            LyricSourceHealth.percent(summary.responded, of: summary.rounds),
                            LyricSourceHealth.percent(summary.won, of: summary.rounds)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.t("其它源照常在找，一首歌只要有别家找得到，歌词就不受影响。这些数字只在这台 Mac 上统计。"))
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
        case .barely: return String(format: L10n.t("%@ 最近几乎找不到歌词"), name)
        case .belowUsual: return String(format: L10n.t("%@ 最近找到的歌词比平时少很多"), name)
        case .cooling: return String(format: L10n.t("%@ 最近经常出错"), name)
        case .network, nil: return String(format: L10n.t("%@ 最近经常连不上"), name)
        }
    }

    private var detail: String {
        let name = source.displayName
        let peerRate = LyricSourceHealth.percent(summary.peerRate)
        let skipRate = LyricSourceHealth.percent(summary.skipRate)
        switch summary.alert {
        case .barely:
            return String(format: L10n.t("最近 3 天有 %1$d 次查询，同类曲库里至少两家都找到了歌词，%2$@ 只在其中 %3$d%% 给出了歌词。多半是它的接口变了，或者请求被拦了。"),
                          summary.peerRounds, name, peerRate)
        case .belowUsual:
            return String(format: L10n.t("最近 3 天有 %1$d 次查询，同类曲库里至少两家都找到了歌词，%2$@ 在其中 %3$d%% 给出了歌词，平时是 %4$d%%。"),
                          summary.peerRounds, name, peerRate, LyricSourceHealth.percent(summary.usualRate))
        case .cooling:
            return String(format: L10n.t("最近 2 天有 %1$d%% 的查询没有问 %2$@：它接连出错，被暂时停用了一阵，过后会自动恢复。"),
                          skipRate, name)
        case .network, nil:
            let peers = summary.networkPeers.map(sourceDisplayName).joined(separator: L10n.t("、"))
            return String(format: L10n.t("最近 2 天有 %1$d%% 的查询因为连不上 %2$@ 被跳过，%3$@ 也是这样。几家同时连不上，多半是这台 Mac 到不了这些网站（比如要开代理），不是源本身坏了。"),
                          skipRate, name, peers)
        }
    }
}
