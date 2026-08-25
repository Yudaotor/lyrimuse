import AppKit
import LyrimuseCore
import SwiftUI

// 选播放器的图标卡片网格——2026-08-25 先在引导页"选择播放器"那一步用上,后来设置页
// "播放器"那张卡也换成同一套(用户要求两处排版和谐一致),所以从 OnboardingView.swift
// 挪出来独立成文件,两处共用同一个组件、同一份取图标逻辑,不重复维护。

/// 一张"选它"的图标卡片。真图标优先——已安装就用 `AppIconResolver` 按 bundleIdentifier
/// 查到的真实 App 图标(跟"正在播放"面板来源角标同一个理由:2026-08-19 用户拍板
/// "最好认,还不用自带任何商标素材",见 `PlaybackCoordinator.resolvedPlayerIcon`);
/// 引导阶段/没装这个播放器时,查不到就退回 `PlaybackPlayer.tintColor` +
/// `fallbackSymbolName` 这套占位,不留空白方块。选中态是强调色描边+浅色底,跟引导页
/// 别处(displayModeRow 的 Toggle)统一靠颜色/开关状态表达选中,不额外叠一个对号图标。
struct PlayerChoiceCard: View {
    let player: PlaybackPlayer
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var installedIcon: NSImage?

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                iconView
                Text(player.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .onAppear(perform: loadRealIconIfInstalled)
    }

    @ViewBuilder
    private var iconView: some View {
        if let installedIcon {
            Image(nsImage: installedIcon)
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: player.fallbackSymbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(player.tintColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    // .auto 没有对应的 App,不用查。
    private func loadRealIconIfInstalled() {
        guard player != .auto else { return }
        installedIcon = AppIconResolver.icon(forBundleID: player.bundleIdentifier)
    }
}

/// 引导页网格里第三行第一格那张占位卡(只在引导页用,设置页那张卡六个选项正好排满
/// 2 行,不需要它)——用户 2026-08-25 明确要求摆在这个位置(截图纠正过来的:第一次说
/// "加几个点"以为是指文案末尾,其实指的是六个真选项排完之后网格自己留出来的这一格)。
/// 不用 Button 包、没有选中态的描边/底色——虚线框 + 三个点的视觉语言故意跟六张真选项卡
/// 区分开,不会被当成"点了没反应的坏按钮"。
struct MorePlayersComingCard: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("•••")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 26, height: 26)
            Text(L10n.t("陆续支持中"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .combine)
    }
}
