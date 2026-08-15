import AppKit
import LyrimuseCore
import SwiftUI

// 「外观」页里灵动岛/菜单栏两段各自的顶部预览。
//
// 桌面悬浮歌词那一段早就有 OverlayPreviewBar 了,这两段一直没有 —— 而它们同样面临
// "改完的效果只出现在别处、而那个别处此刻多半看不见"的问题:灵动岛贴在刘海下(设置窗
// 一挡就没了),菜单栏歌词只有一行字还得等有歌在播。
//
// ⚠️ 刻意**不**复用 OverlayPreviewBar。那一条画的是悬浮歌词的字体/颜色/描边/宽度,而
// 灵动岛和菜单栏**根本不读那些设置**(灵动岛用自己的 notchCardStyle,菜单栏就是系统
// 菜单栏字)。拿同一条预览挂在这两段上,等于暗示那些设置对它们也有效 —— 那是错的。
// 每一段的预览只反映这一段自己那几项设置。
//
// 这两个都照 OverlayPreviewBar 的几条教训写(见那边注释):高度固定不跟内容变(挂在
// safeAreaInset 上,高度一动整页就跳)、只订阅要用的那一两个 @Published(别 ObservedObject
// 整个 PlaybackCoordinator)、自带不透明底色(inset 区域盖不到 ScrollView 的 background)。

/// 灵动岛那一段的预览:按当前「风格」和「宽度」画一张缩略的刘海卡。
@MainActor
struct NotchPreviewBar: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var line: SyncedLyricLine?
    @State private var artwork: NSImage?

    // 预览条能给的最大宽度。比卡片列(600)窄一截,两侧留呼吸。
    private let maxPreviewWidth: CGFloat = 460
    // 真卡片稳态高度(NotchLyricsView.compactRowHeight 44 + 顶部让位 ~32)。
    private let cardHeight: CGFloat = 76
    private let cornerRadius: CGFloat = 20

    // 宽度滑杆能拖到 500,超过预览区就整体等比缩小 —— 这样"宽度"这一项在预览里看得见。
    private var scale: CGFloat { min(1, maxPreviewWidth / max(settings.notchContentWidth, 1)) }

    private var previewText: String {
        if let text = line?.plainText, !text.isEmpty { return text }
        return L10n.t("这里是一句歌词示例")
    }

    var body: some View {
        VStack(spacing: 6) {
            card
                .frame(width: settings.notchContentWidth, height: cardHeight)
                .scaleEffect(scale, anchor: .center)
                // 缩放不改变布局占位,得显式把外框收到缩放后的尺寸。
                .frame(width: settings.notchContentWidth * scale, height: cardHeight * scale)
            Text(String(format: L10n.t("预览 · %@pt"), "\(Int(settings.notchContentWidth))"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .onReceive(PlaybackCoordinator.shared.$currentLine.removeDuplicates()) { line = $0 }
        .onReceive(PlaybackCoordinator.shared.$artworkImage.removeDuplicates()) { artwork = $0 }
        .accessibilityHidden(true)
    }

    private var card: some View {
        ZStack {
            // 跟真卡片同一套:.coverArt 走封面模糊图,其余三种走 NotchCardStyle.fill。
            // 没有封面时退回渐变,跟 NotchLyricsView.backgroundLayer 的兜底一致。
            if settings.notchCardStyle == .coverArt, let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: settings.notchContentWidth, height: cardHeight)
                    .blur(radius: 20)
                    .overlay(Color.black.opacity(0.45))
            } else {
                Rectangle().fill(settings.notchCardStyle.fill)
            }
            Text(previewText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        }
        // 顶直角、底圆角 —— 复用真卡片那个形状,不复制轮廓代码。
        .clipShape(NotchHangingShape(bottomCornerRadius: cornerRadius))
    }
}

/// 菜单栏那一段的预览:按当前「最大字数」和「横向滚动」显示这一行会被截成什么样。
@MainActor
struct MenuBarPreviewBar: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var line: SyncedLyricLine?

    private var fullText: String {
        if let text = line?.plainText, !text.isEmpty { return text }
        return L10n.t("这里是一句歌词示例")
    }

    /// 复用真实的截断/取窗逻辑,不自己另写一份 —— 两份实现必然漂。
    /// step 传 0 = 停在开头那一帧(滚动到中段的样子这里没必要演,那需要常驻一个定时器)。
    private var visibleText: String {
        if settings.menuBarLyricsScroll {
            return MenuBarMarquee.window(
                text: fullText, maxChars: settings.menuBarLyricsMaxChars, step: 0, holdSteps: 0)
        }
        return fullText.count > settings.menuBarLyricsMaxChars
            ? String(fullText.prefix(settings.menuBarLyricsMaxChars)) + "…"
            : fullText
    }

    private var truncated: Bool { fullText.count > settings.menuBarLyricsMaxChars }

    var body: some View {
        VStack(spacing: 6) {
            // 仿一小段菜单栏:圆角条 + 音符图标 + 那行字。用系统菜单栏字号(13),
            // 因为菜单栏歌词就是系统字,这一页没有字体/颜色可调。
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                Text(visibleText)
                    .lineLimit(1)
            }
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            Text(
                truncated
                    ? String(format: L10n.t("预览 · 上限 %@ 字，本句已截断"),
                             "\(settings.menuBarLyricsMaxChars)")
                    : String(format: L10n.t("预览 · 上限 %@ 字"), "\(settings.menuBarLyricsMaxChars)")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .onReceive(PlaybackCoordinator.shared.$currentLine.removeDuplicates()) { line = $0 }
        .accessibilityHidden(true)
    }
}
