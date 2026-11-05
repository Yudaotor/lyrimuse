import LyrimuseCore
import SwiftUI

/// 正在播放卡在压根没有曲目时的样子:停播前最后那首(封面、歌名、「上次播放 · 歌手」),加宽那一档再挂一句这首里的歌词,
/// 底下一颗主动作键(`MenuBarPanelView.idleActionButton`)。从没放过歌时是「未在播放」+ 提示。
/// 数据跟灵动岛空闲面板同一份(`NotchIdleLastTrack`):封面、挑句子的口径都在那边。见 06 章决策 96。
struct PanelIdleNowPlaying<Action: View>: View {
    @ObservedObject private var model = NotchIdleLastTrack.shared
    /// 加宽(6×2):封面在左上、字在右,中间一句歌词,键在底下正中。大号(3×2):同控制中心那一格,封面在上、字和键往下排。
    let wide: Bool
    let coverSide: CGFloat
    let openLyricsWindow: () -> Void
    @ViewBuilder let action: () -> Action

    var body: some View {
        Group {
            if wide { wideBody } else { compactBody }
        }
        // 每次打开面板换一句(同灵动岛悬停展开)。
        .onAppear { model.rerollQuote() }
    }

    /// 头部、那句歌词、键三样作为一组在卡片里上下居中:挑不出句子时只剩头部和键,上下留白一样多,不在中间空出一截。
    private var wideBody: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                coverButton
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.track != nil, let quote = model.quote {
                // 两行封顶、居中:按句尾截断会把后引号一起截掉。
                Text("\u{201C}\(quote)\u{201D}")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverButton
            Spacer(minLength: 4)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            // 没有上次那首时只留「未在播放」:提示句在三列宽里放不下。
            if model.track != nil {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: String {
        model.track.map { TrackNameDisplay.cleaned($0.title) } ?? L10n.t("未在播放")
    }

    private var subtitle: String {
        guard let track = model.track else { return L10n.t("播放歌曲后，歌词将自动显示") }
        return track.artist.isEmpty ? L10n.t("上次收听") : String(format: L10n.t("上次播放 · %@"), track.artist)
    }

    /// 点封面开歌词窗口,同有曲目时那枚。
    private var coverButton: some View {
        Button(action: openLyricsWindow) { cover }
            .buttonStyle(.plain)
            .help(L10n.t("打开歌词窗口"))
    }

    /// 缓存里的封面;没有封面按歌手名恒定取色 + 首字(同灵动岛、歌词窗口停播页);从没放过歌是有曲目时缺封面那块渐变音符。
    @ViewBuilder private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if let track = model.track {
            let placeholder = ZStack {
                LastfmStatsSection.stableColor(for: track.artist.isEmpty ? track.title : track.artist)
                    .opacity(0.65)
                Text(String(TrackNameDisplay.cleaned(track.title).prefix(1)))
                    .font(.system(size: coverSide * 0.45, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Group {
                if let url = model.cover {
                    CachedImage(url: url) { placeholder }
                } else {
                    placeholder
                }
            }
            .frame(width: coverSide, height: coverSide)
            .clipShape(shape)
        } else {
            shape
                .fill(LinearGradient(colors: [.blue.opacity(0.55), .purple.opacity(0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: coverSide, height: coverSide)
                .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.85)))
        }
    }
}
