import LyrimuseCore
import SwiftUI

/// 「与播放器联动」卡里的一行(2026-09-03):标题 + 副标题(勾了谁)+ 尾部一排播放器图标芯片,点图标勾选 / 取消。
///
/// 为什么是图标芯片而不是三个 Toggle 或一个多选菜单:上面那张播放器网格已经用同一套图标(`PlayerIconView`
/// 三级兜底取图)教过用户"哪个图标是哪个播放器",这里沿用同一种语言,一眼就能看出每项联动绑了谁;候选最多
/// 五个,一排放得下。未勾选的芯片去饱和 + 半透明,勾选的带强调色描边,跟 `PlayerChoiceCard` 的选中态同源。
/// 副标题把勾选结果再用文字写一遍(「Apple Music、Spotify」/「未勾选,此项关闭」),不靠图标一种通道。
struct PlayerLinkageRow: View {
    let icon: String
    let title: String
    var help: String?
    /// 候选按 displayOrder 排好再传进来;不在候选里的勾选记录不显示但保留(见 PlayerLinkage.effective)。
    let candidates: [PlaybackPlayer]
    let chosen: Set<PlaybackPlayer>
    let onChange: (Set<PlaybackPlayer>) -> Void

    private var summary: String {
        let picked = candidates.filter { chosen.contains($0) }
        return picked.isEmpty ? L10n.t("未勾选，此项关闭") : picked.map(\.displayName).joined(separator: "、")
    }

    var body: some View {
        SettingsRow(icon: icon, title: title, subtitle: summary, help: help) {
            PlayerLinkageChips(candidates: candidates, chosen: chosen) { player in
                var next = chosen
                if next.contains(player) { next.remove(player) } else { next.insert(player) }
                onChange(next)
            }
        }
    }
}

private struct PlayerLinkageChips: View {
    let candidates: [PlaybackPlayer]
    let chosen: Set<PlaybackPlayer>
    let toggle: (PlaybackPlayer) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(candidates) { player in
                let selected = chosen.contains(player)
                Button {
                    toggle(player)
                } label: {
                    PlayerIconView(player: player, size: 22)
                        .saturation(selected ? 1 : 0)
                        .opacity(selected ? 1 : 0.4)
                        .padding(3)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help(player.displayName)
                // 旁白要能读出"勾没勾"—— 视觉上只在描边和饱和度里,VoiceOver 听不出来。
                .accessibilityLabel(player.displayName)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // 钉住理想宽度:SettingsRow 的三个可伸缩成员均分剩余宽度,不钉的话芯片会被压扁(04 章决策 #15 同款坑)。
        .fixedSize()
    }
}
