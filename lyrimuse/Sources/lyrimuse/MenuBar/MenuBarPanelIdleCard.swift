import AppKit
import LyrimuseCore
import SwiftUI

/// 正在播放卡在压根没有曲目时的样子。有上次那首(停播前最后那首)时跟播放时那张卡同一套排布:封面、歌名歌手专辑、
/// 播放器角标、一句这首里的歌词、进度条那一行、走带键(就是播放时那一排,`transport`),只多一句「上次播放 · 时间」;
/// 开始播放时每样东西原地换成播放时的样子。从没放过歌是「未在播放」+ 提示 + `fallbackAction`。数据跟灵动岛空闲面板同一份(`NotchIdleLastTrack`)。见 06 章决策 98。
struct PanelIdleNowPlaying<Transport: View, Action: View>: View {
    @ObservedObject private var model = NotchIdleLastTrack.shared
    /// 加宽(6×2)照完整的正在播放卡;大号(3×2)照控制中心那一格:封面在上、字和三键往下排。
    let wide: Bool
    let coverSide: CGFloat
    let openLyricsWindow: () -> Void
    /// 点播放器角标:打开那家并收面板。
    let openPlayer: () -> Void
    /// 播放时那一排走带键(`MenuBarPanelView.transportRow` / `compactTransportRow`)。
    let transport: () -> Transport
    /// 从没放过歌时那颗键(`MenuBarPanelView.idleActionButton`)。
    @ViewBuilder let fallbackAction: () -> Action

    @State private var playerIcon: NSImage?

    private var player: PlaybackPlayer { IdlePlaybackActions.player }

    var body: some View {
        Group {
            if let track = model.track {
                if wide { wideBody(track) } else { compactBody(track) }
            } else if wide {
                wideNeverPlayed
            } else {
                compactNeverPlayed
            }
        }
        // 每次打开面板换一句(同灵动岛悬停展开)。
        .onAppear { model.rerollQuote() }
        .task(id: player) {
            playerIcon = AppIconResolver.icon(forBundleID: player.bundleIdentifier)
        }
    }

    // MARK: 有上次那首

    /// 行距、字号、各行高度照 `MenuBarPanelView.nowPlayingCard`(头部 / 歌词行 16 / 进度条槽 14 + 时间行 / 走带)。
    private func wideBody(_ track: IdleLastTrack) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 9) {
                coverButton(track)
                VStack(alignment: .leading, spacing: 2) {
                    Text(TrackNameDisplay.cleaned(track.title))
                        .font(.system(size: 12, weight: .semibold))
                    if !track.artist.isEmpty {
                        Text(track.artist)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    if !track.album.isEmpty {
                        Text(track.album)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
                playerBadge
            }
            // 歌词那一行:挑得出句子放句子,时间挪到进度条下面;挑不出(纯音乐、没歌词)放「上次播放 · 时间」。
            Group {
                if let quote = model.quote {
                    Text(quote)
                } else {
                    Text(playedAtText(track))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 16)
            // 进度条那一行照 `PanelProgressSection`:空槽,左 0:00、右剩余时长(缓存里有曲长时),中间是有歌词时那根微调换成的时间。
            VStack(spacing: 3) {
                Capsule()
                    .fill(Color(nsColor: .tertiarySystemFill))
                    .frame(height: 4)
                    .frame(height: 14)
                HStack {
                    Text(Self.mmss(0))
                    Spacer()
                    if model.quote != nil {
                        Text(playedAtText(track))
                            .lineLimit(1)
                    }
                    Spacer()
                    if let duration = EnrichCacheReader.trackDurationSecs(artist: track.artist, title: track.title,
                                                                          album: track.album) {
                        Text("-" + Self.mmss(Int(duration * 1000)))
                    }
                }
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            transport()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 照 `MenuBarPanelView.playingCompactNowPlaying`。
    private func compactBody(_ track: IdleLastTrack) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                coverButton(track)
                Spacer(minLength: 0)
                playerBadge
            }
            Spacer(minLength: 4)
            Text(TrackNameDisplay.cleaned(track.title))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(track.artist.isEmpty ? playedAtText(track) : track.artist)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            transport()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 「上次播放 · 今天 00:47」:时间是最后一次真在放这首的时刻,跟界面语言走。比这个键早的安装还没记过时刻,只写「上次收听」。
    private func playedAtText(_ track: IdleLastTrack) -> String {
        guard let date = track.playedAt else { return L10n.t("上次收听") }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return String(format: L10n.t("上次播放 · %@"), formatter.string(from: date))
    }

    /// 同 `PanelProgressSection.mmss`。
    private static func mmss(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 右上角那家播放器的图标,同有曲目时的来源角标。
    @ViewBuilder private var playerBadge: some View {
        if let playerIcon {
            Button(action: openPlayer) {
                Image(nsImage: playerIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glassIcon())
            .help(String(format: L10n.t("打开 %@"), player.displayName))
        }
    }

    // MARK: 从没放过歌

    private var wideNeverPlayed: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                placeholderCover
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("未在播放"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(L10n.t("播放歌曲后，歌词将自动显示"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            fallbackAction()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 提示句在三列宽里放不下,只留「未在播放」。
    private var compactNeverPlayed: some View {
        VStack(alignment: .leading, spacing: 0) {
            placeholderCover
            Spacer(minLength: 4)
            Text(L10n.t("未在播放"))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            fallbackAction()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 封面

    /// 点封面开歌词窗口,同有曲目时那枚。缓存里没封面按歌手名恒定取色 + 首字(同灵动岛、歌词窗口停播页)。
    private func coverButton(_ track: IdleLastTrack) -> some View {
        Button(action: openLyricsWindow) {
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
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L10n.t("打开歌词窗口"))
    }

    /// 从没放过歌:有曲目时缺封面那块渐变音符。
    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [.blue.opacity(0.55), .purple.opacity(0.45)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: coverSide, height: coverSide)
            .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.85)))
    }
}
