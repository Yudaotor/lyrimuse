import AppKit
import LyrimuseCore
import SwiftUI

/// 停播前最后那首。LocalPlaybackSource 停播时把曲目清掉,只有这三个键还记得
/// (完整停播页 `IdleLastTrackHero` 读的是同三个键)。
struct IdleLastTrack: Equatable {
    let title: String
    let artist: String
    /// 旧安装第一次停播前是空的(这个键比另外两个晚加),空就只显示歌手。
    let album: String

    var key: String { artist + "|" + title + "|" + album }

    static var current: IdleLastTrack {
        let d = UserDefaults.standard
        return IdleLastTrack(title: d.string(forKey: "np:lastTrackTitle") ?? "",
                             artist: d.string(forKey: "np:lastTrackArtist") ?? "",
                             album: d.string(forKey: "np:lastTrackAlbum") ?? "")
    }

    /// 缓存里这首的封面地址。EnrichCacheReader 只许在主线程用(静态缓存没有锁)。
    @MainActor
    func coverURL() -> URL? {
        EnrichCacheReader.coverURL(artist: artist, title: title, album: album)
    }

    /// 从这首歌词里挑出的候选乐句(每条 1~3 行原文)。歌词正文在主线程读,解析与选句放后台。
    ///
    /// 必须走 LRCParser:酷狗那批 CRLF 歌词自己按换行切不开,会把整首歌当成一行。排序 / 剥对唱标记 /
    /// 挡署名 / 把被拆成多行的碎片并回整句 / 收尾复验,整条链都在 `LyricQuotePicker`(selftest 钉着),
    /// 跟完整停播页同一个挑法。
    @MainActor
    func loadQuotes() async -> [[String]] {
        let lyrics = EnrichCacheReader.lookup(artist: artist, title: title, album: album)?.lyrics ?? ""
        guard !lyrics.isEmpty else { return [] }
        let title = self.title, artist = self.artist
        return await Task.detached(priority: .userInitiated) {
            let parsed = LRCParser.parse(lyrics)
                .map { LyricQuotePicker.Line(timeMs: $0.timeMs, text: $0.text) }
            return LyricQuotePicker.phrases(parsed, trackTitle: title, trackArtist: artist)
        }.value
    }
}

/// 迷你窗停播页:上次那首里挑一句歌词做主角,下面一行小封面 + 歌名歌手,再下面「继续播放」
/// 和一颗带播放器图标的「打开」。完整停播页左下那块「上次那首 + 一句歌词」的小窗版(07 章决策 67)。
///
/// **不用一句话点名某家播放器**:这里指向的是停播前最后用的那家(`IdlePlaybackActions.player`),
/// 而用户往往勾了好几家;写成「在 X 播放任意歌曲」读起来像只有 X 才行。播放器只出现在「打开」
/// 那颗按钮的图标上(悬停提示写全名)。
///
/// 三种数据情形:有上次那首且挑得出句子 → 歌词做主角;挑不出(纯音乐、没歌词、缓存里没有)→
/// 封面 + 歌名做主角;连上次那首都没有(全新用户)→ 呼吸音符 + 「没有在播放」。
/// 每种都按窗口高度用 `ViewThatFits` 逐档减内容(迷你窗能缩到 300×110),只减内容、不压字号。
/// 颜色走系统语义色:底是统一的中心柔光(`IdleStandbyBackground`),不是用户选的背景。
struct MiniIdleStandby: View {
    let player: PlaybackPlayer
    /// 呼吸动画开不开(看不见 / 减弱动态效果时关),由窗口那边定。
    let breathing: Bool
    let onResume: () -> Void
    let onOpenPlayer: () -> Void

    @State private var cover: URL?
    @State private var quote: [String]?
    @State private var playerIcon: NSImage?

    private var canResume: Bool { IdlePlaybackActions.canResume(player) }

    var body: some View {
        let track = IdleLastTrack.current
        Group {
            if track.title.isEmpty {
                ViewThatFits(in: .vertical) {
                    noTrackStack(halo: 64, note: 22, showsHint: true)
                    noTrackStack(halo: 44, note: 16, showsHint: false)
                    HStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(L10n.t("未在播放"))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        openButton(prominent: true)
                    }
                }
            } else if let quote {
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 0) {
                        quoteText(quote, size: 17, lines: 2)
                        trackLine(track).padding(.top, 12)
                        buttonRow.padding(.top, 16)
                    }
                    VStack(spacing: 0) {
                        quoteText(quote, size: 15, lines: 1)
                        buttonRow.padding(.top, 12)
                    }
                    HStack(spacing: 8) {
                        quoteText(quote, size: 13, lines: 1)
                        primaryButton
                    }
                }
            } else {
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            coverImage(track, side: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        buttonRow.padding(.top, 14)
                    }
                    HStack(spacing: 8) {
                        coverImage(track, side: 26)
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        primaryButton
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .task(id: track.key) {
            guard !track.title.isEmpty else {
                cover = nil
                quote = nil
                return
            }
            cover = track.coverURL()
            quote = await track.loadQuotes().randomElement()
        }
        // 取数那一刻缓存还没解码完(App 刚启动)、或引擎还没写上封面时 cover 是空的:
        // 缓存换了内容就再补一次封面。只补封面,不重选句子。
        .onReceive(LocalPlaybackSource.shared.$enrichContentVersion.removeDuplicates()) { _ in
            if cover == nil, !track.title.isEmpty { cover = track.coverURL() }
        }
        .task(id: player) {
            playerIcon = AppIconResolver.icon(forBundleID: player.bundleIdentifier)
        }
    }

    /// 那句歌词。保留乐句自己的换行(只给一行的那两档拼成一行),弯引号包起来 —— 它是引文不是正文。
    private func quoteText(_ lines: [String], size: CGFloat, lines limit: Int) -> some View {
        let body = limit > 1 ? lines.joined(separator: "\n") : lines.joined(separator: " ")
        return Text("\u{201C}\(body)\u{201D}")
            .font(.system(size: size, weight: .semibold, design: .serif).italic())
            .foregroundStyle(.primary.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(limit)
            .truncationMode(.tail)
    }

    private func trackLine(_ track: IdleLastTrack) -> some View {
        HStack(spacing: 8) {
            coverImage(track, side: 26)
            Text(track.artist.isEmpty ? track.title : "\(track.title) · \(track.artist)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// 封面小图:缓存里有就贴图(缩略图档),没有退回按歌手名恒定取色的色块 + 首字母,
    /// 口径同完整停播页那张大封面。
    private func coverImage(_ track: IdleLastTrack, side: CGFloat) -> some View {
        let placeholder = ZStack {
            LastfmStatsSection.stableColor(for: track.artist.isEmpty ? track.title : track.artist)
                .opacity(0.65)
            Text(String(track.title.prefix(1)))
                .font(.system(size: side * 0.45, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
        return Group {
            if let cover {
                CachedImage(url: cover) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side > 40 ? 8 : 5, style: .continuous))
        .shadow(color: .black.opacity(side > 40 ? 0.18 : 0), radius: 6, y: 2)
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            if canResume {
                primaryButton
                openButton(prominent: false)
            } else {
                openButton(prominent: true)
            }
        }
    }

    /// 主按钮:能真继续播放的播放器给「继续播放」,其余就是「打开」(同完整停播页那条规则)。
    @ViewBuilder
    private var primaryButton: some View {
        if canResume {
            Button(action: onResume) {
                Label(L10n.t("继续播放"), systemImage: "play.fill")
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
            openButton(prominent: true)
        }
    }

    @ViewBuilder
    private func openButton(prominent: Bool) -> some View {
        let button = Button(action: onOpenPlayer) {
            HStack(spacing: 4) {
                if let playerIcon {
                    Image(nsImage: playerIcon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(L10n.t("打开"))
                    .lineLimit(1)
            }
        }
        .controlSize(.small)
        .help(String(format: L10n.t("打开 %@"), player.displayName))
        .accessibilityLabel(String(format: L10n.t("打开 %@"), player.displayName))
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func noTrackStack(halo: CGFloat, note: CGFloat, showsHint: Bool) -> some View {
        VStack(spacing: 0) {
            // 呼吸同完整停播页:交给 Core Animation,主线程不参与。
            LayerBreathing(animating: breathing) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color.accentColor.opacity(0.12), .clear],
                            center: .center, startRadius: halo * 0.045, endRadius: halo * 0.5))
                        .frame(width: halo, height: halo)
                    Image(systemName: "music.note")
                        .font(.system(size: note, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: halo, height: halo)
            Text(L10n.t("未在播放"))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            if showsHint {
                Text(L10n.t("播放歌曲后，歌词将自动显示"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            openButton(prominent: true)
                .padding(.top, 12)
        }
    }
}
