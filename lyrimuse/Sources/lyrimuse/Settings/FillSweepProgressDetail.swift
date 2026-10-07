import LyrimuseCore
import SwiftUI

/// 自动匹配 / 全量扫库跑着时的进度详情。「歌词管理」侧栏「⋯」菜单、底部进度卡和设置页「歌词库」那两行的
/// 进度圆环(点开是 `FillSweepProgressDetail`)共用这一份文字 —— 几处说的是同一轮扫描,各写一遍迟早说成两样。
///
/// 每一句都要先看 `isFullScan`:「重新匹配整个歌词库」复用自动匹配那条通道(状态文件、单轮互斥、取消都共用,
/// 见 lyrimuse-engine/lyricsfullscan.go 头注),全量跑着时说「正在自动匹配」,说的跟做的就不是一回事。
enum FillSweepProgressText {
    /// 此刻在做什么。上一首一个歌词源都没连上时引擎在原地等网络,那时说这个,不说「正在搜索」。
    /// 两首之间(自动匹配隔几秒才搜下一首)没有「当前这首」:搜过至少一首就说在等下一首,一首都没搜就还在准备。
    /// 全量那一轮的兜底走现成的「重新匹配整个歌词库」,不另起一句只露脸一瞬的翻译串。
    static func title(_ status: LyricsFillSweep.Info) -> String {
        if status.isOffline { return L10n.t("网络不可用，稍后重试…") }
        if let current = status.current {
            return String(format: L10n.t("正在搜索：%@"), LyricsFillSweep.displayName(key: current))
        }
        if status.isFullScan { return L10n.t("重新匹配整个歌词库") }
        return status.done > 0 ? L10n.t("等待下一首…") : L10n.t("正在准备自动匹配…")
    }

    /// 进度与结果分布,一句一行,最后一句是「大约还要多久」(跑完了就没有)。全量扫库的 Done / Filled 是
    /// 跨重启的累计值,Skipped 只记这个进程这一轮,凑不出「没变」的准确数,所以全量只报更新了几首。
    static func lines(_ status: LyricsFillSweep.Info, fallbackSecondsPerTrack: Double) -> [String] {
        var out = [String(format: L10n.t("已完成 %1$@ / %2$@ 首"),
                          status.done.formatted(), status.total.formatted())]
        if status.isFullScan {
            out.append(String(format: L10n.t("已更新 %@ 首"), status.filled.formatted()))
            if status.deferredCount > 0 {
                out.append(String(format: L10n.t("%@ 首本次无法判断，扫描结束后将重试"), status.deferredCount.formatted()))
            }
        } else {
            out.append(String(format: L10n.t("找到 %1$@ · 未找到 %2$@ · 跳过 %3$@"),
                              "\(status.filled)", "\(status.missedCount)", "\(status.skippedCount)"))
        }
        if status.done < status.total {
            out.append(String(format: L10n.t("预计还需%@"),
                              remainingText(status, fallbackSecondsPerTrack: fallbackSecondsPerTrack)))
        }
        return out
    }

    /// 最近完成那一条的结果图标。全量那一轮的 missed 是「重选后没变」,换成等号图标;deferred 是「这一轮
    /// 没法判断」,用稍后再试的图标。
    static func recentSymbol(_ item: LyricsFillSweep.Info.Recent, isFullScan: Bool) -> String {
        switch item.result {
        case "filled": return "checkmark.circle"
        case "skipped": return "forward.circle"
        case "deferred": return "clock.arrow.circlepath"
        default: return isFullScan ? "equal.circle" : "xmark.circle"
        }
    }

    /// 「大约还要」的时长,按这一轮实测速度外推;还没跑完一首时按 `fallbackSecondsPerTrack` 估
    /// (自动匹配约 20 秒:两首之间的间隔加上一首的搜索;全量取引擎发布的每首耗时)。
    private static func remainingText(_ status: LyricsFillSweep.Info, fallbackSecondsPerTrack: Double) -> String {
        let seconds = LyricsFillSweep.remainingSeconds(status, now: Date(), fallbackSecondsPerTrack: fallbackSecondsPerTrack)
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 1 { return L10n.t("不足 1 分钟") }
        if minutes < 60 { return String(format: L10n.t("%@ 分钟"), "\(minutes)") }
        return String(format: L10n.t("%1$@ 小时 %2$@ 分钟"), "\(minutes / 60)", "\(minutes % 60)")
    }

    /// 自动匹配那一轮估剩余时长用的每首秒数,见 `remainingText`。全量那一轮用引擎发布的值
    /// (`LyricsLibraryStatsPanel.fullScanSecondsPerTrack`)。
    static let fillFallbackSecondsPerTrack = 20.0
}

/// 设置页「歌词库」那两行点进度圆环、「歌词管理」点进度卡弹出的详情,内容与「歌词管理」「⋯」菜单跑着时那几段相同
/// (`FillSweepProgressText`)。停止按钮不在这里:行尾本来就有一颗。
struct FillSweepProgressDetail: View {
    let status: LyricsFillSweep.Info
    let fallbackSecondsPerTrack: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(FillSweepProgressText.title(status))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(FillSweepProgressText.lines(status, fallbackSecondsPerTrack: fallbackSecondsPerTrack), id: \.self) {
                Text($0).monospacedDigit()
            }
            if let recent = status.recent, !recent.isEmpty {
                Divider().padding(.vertical, 2)
                Text(L10n.t("最近完成"))
                    .font(.system(size: 10, weight: .semibold))
                ForEach(Array(recent.enumerated()), id: \.offset) { _, item in
                    Label(LyricsFillSweep.displayName(key: item.key),
                          systemImage: FillSweepProgressText.recentSymbol(item, isFullScan: status.isFullScan))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(13)
        .frame(width: 280, alignment: .leading)
    }
}
