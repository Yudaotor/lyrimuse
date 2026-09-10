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
        HStack(spacing: PlayerChipMetrics.spacing) {
            ForEach(candidates) { player in
                PlayerChip(selected: chosen.contains(player), label: player.displayName) {
                    toggle(player)
                } icon: {
                    PlayerIconView(player: player, size: PlayerChipMetrics.iconSize)
                }
            }
        }
        // 钉住理想宽度:SettingsRow 的三个可伸缩成员均分剩余宽度,不钉的话芯片会被压扁(04 章决策 #15 同款坑)。
        .fixedSize()
    }
}

// MARK: - 按 bundle 勾选的芯片行(2026-09-10)

/// 一枚芯片对应的候选。内置播放器带 `player`(走 `PlayerIconView` 的三级兜底取图);信任列表里的 App /
/// 浏览器没有 `PlaybackPlayer` 枚举值,只有 bundle id + 当初存下的显示名,用它自己的 App 图标。
struct PlayerBundleChoice: Identifiable, Equatable {
    /// bundle id —— 也是排除集合里的键。
    let id: String
    let name: String
    let player: PlaybackPlayer?
}

/// 「按 bundle 勾选一组播放器」的一行(2026-09-10,Last.fm 页的「Scrobble 的播放器」)。
///
/// 跟 `PlayerLinkageRow` 是姐妹:同一套芯片视觉、同一种"图标即选项"的语言,区别只在候选的身份——那边是
/// `PlaybackPlayer` 枚举,这边是 bundle id,好让内置播放器和信任列表里的浏览器摆进**同一排**。
/// 第一版把信任项做成一人一行的开关,四个浏览器就吃掉五行、比整张卡其余部分加起来还高(2026-09-10 用户
/// 原话「这一块占用区域太大了…收拢到一起」),所以收成芯片。
///
/// 存的是**排除**集合而不是勾选集合:缺省(空)= 全部勾选,新装机和老配置都不会因为少一个键而静默少记。
/// 副标题按状态说人话——全勾「全部勾选」、全不勾「全部不 scrobble」、部分则只列**被排除**的那几个
/// (通常就一两个,比列出全部九个短得多,也正是用户改完想确认的那件事)。
struct PlayerBundleChipsRow: View {
    let icon: String
    let title: String
    var help: String?
    let choices: [PlayerBundleChoice]
    /// 未勾选(被排除)的 bundle id。
    let excluded: Set<String>
    /// (bundle id, 改后是否勾选)
    let onToggle: (String, Bool) -> Void

    private var summary: String {
        let off = choices.filter { excluded.contains($0.id) }
        if off.isEmpty { return L10n.t("全部勾选") }
        if off.count == choices.count { return L10n.t("全部不 scrobble") }
        return String(format: L10n.t("不 scrobble：%@"), off.map(\.name).joined(separator: "、"))
    }

    var body: some View {
        SettingsRow(icon: icon, title: title, subtitle: summary, help: help) {
            PlayerChipFlow(spacing: PlayerChipMetrics.spacing) {
                ForEach(choices) { choice in
                    let selected = !excluded.contains(choice.id)
                    PlayerChip(selected: selected, label: choice.name) {
                        onToggle(choice.id, !selected)
                    } icon: {
                        if let player = choice.player {
                            PlayerIconView(player: player, size: PlayerChipMetrics.iconSize)
                        } else {
                            TrustedPlayerIconView(bundleID: choice.id, size: PlayerChipMetrics.iconSize)
                        }
                    }
                }
            }
            // 芯片数量由用户的信任列表决定(可能十几个),所以给一个上限让它换行,而不是像
            // PlayerLinkageRow 那样 fixedSize 钉成一行——一行钉死在窄窗口下会把标题挤没。
            // 320 ≈ 十枚芯片:最窄窗口(760 − 侧栏 170)下仍给标题留 200pt 以上。
            .frame(maxWidth: PlayerChipMetrics.flowMaxWidth, alignment: .trailing)
        }
    }
}

/// 信任列表里那个 App 自己的图标。查不到(App 刚被删了)退回一个通用印章符号,不留空白方块 ——
/// 跟播放器页「已信任的播放器」卡同一个兜底口径。
private struct TrustedPlayerIconView: View {
    let bundleID: String
    var size: CGFloat
    @State private var resolved: NSImage?

    var body: some View {
        Group {
            if let resolved {
                Image(nsImage: resolved).resizable().frame(width: size, height: size)
            } else {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: size * 0.58, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.secondary,
                                in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            }
        }
        .onAppear { if resolved == nil { resolved = AppIconResolver.icon(forBundleID: bundleID) } }
    }
}

// MARK: - 共用的芯片外壳与排布

enum PlayerChipMetrics {
    static let iconSize: CGFloat = 22
    static let spacing: CGFloat = 6
    static let flowMaxWidth: CGFloat = 320
}

/// 一枚可勾选的播放器芯片:未勾选去饱和 + 半透明,勾选带强调色描边与浅底。两个行组件共用,
/// 免得调样式时漏改一处。
private struct PlayerChip<Icon: View>: View {
    let selected: Bool
    let label: String
    let toggle: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: toggle) {
            icon()
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
        .help(label)
        // 旁白要能读出"勾没勾"—— 视觉上只在描边和饱和度里,VoiceOver 听不出来。
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 芯片的流式排布:一行放不下就换行,每行**右对齐**(它住在 SettingsRow 的尾部槽位)。
/// 用 `Layout` 而不是 `HStack` + `fixedSize`:候选个数由用户的信任列表决定,写死一行会在窄窗口下
/// 把标题挤没或把芯片裁掉半个。
private struct PlayerChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = ChipFlowGeometry.rows(widths: sizes.map(\.width), spacing: spacing,
                                         limit: proposal.width ?? .greatestFiniteMagnitude)
        return ChipFlowGeometry.size(rows: rows, rowHeight: sizes.map(\.height).max() ?? 0, spacing: spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rowHeight = sizes.map(\.height).max() ?? 0
        var y = bounds.minY
        for row in ChipFlowGeometry.rows(widths: sizes.map(\.width), spacing: spacing, limit: bounds.width) {
            // 每行右对齐:它住在 SettingsRow 的尾部槽位,跟旁边的开关 / 分段控件贴同一条右缘。
            var x = bounds.maxX - row.width
            for index in row.indices {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
