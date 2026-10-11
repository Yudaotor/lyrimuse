import AppKit
import LyrimuseCore
import SwiftUI

/// 歌词管理详情页「同一首歌的其他写法」(18 章决策 28):同一首歌的其他写法、凭什么认成同一首、自动匹配的歌词是不是共用
/// 一份;每行能拆开,拆开过的能恢复合并。拆开、恢复合并都交给引擎(EnrichCacheStore.splitSong / unsplitSong),列表数据见
/// SongVersions。
struct SongVersionsSheet: View {
    let summary: EnrichCacheStore.Summary
    /// 关掉弹窗、在列表里选中这一条。
    let onOpen: (String) -> Void

    @ObservedObject private var store = EnrichCacheStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var listing: SongVersions.Listing?
    @State private var loaded = false
    @State private var pendingSplit: String?
    @State private var confirmingSplit = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(minWidth: 460, idealWidth: 540, maxWidth: .infinity,
               minHeight: 360, idealHeight: 480, maxHeight: .infinity)
        .background(WindowResizeEnabler(minWidth: 460, minHeight: 360))
        // 拆开、恢复合并之后歌词管理会重读一遍(summariesGeneration 变),跟着重算列表。
        .task(id: store.summariesGeneration) { await reload() }
        // 要拆的那条经 presenting 交给按钮:关确认框时会先把开关置回去,按钮里再读 @State 可能已经晚了。
        .alert(splitTitle, isPresented: $confirmingSplit, presenting: pendingSplit) { key in
            Button(L10n.t("拆开"), role: .destructive) {
                run { await store.splitSong(keys: [key]) }
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: { _ in
            Text(L10n.t("拆开后它单独算一首歌：播放次数分开，歌词不再跟这首共用；从这首同步过去的歌词会换回它原来那份。之后可以在这里恢复合并。"))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("同一首歌的其他写法")).font(.headline)
                Text(L10n.t("这些写法算作同一首歌，播放次数合在一起。认错了就拆开。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L10n.t("完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !loaded {
                ProgressView().controlSize(.small)
            } else if let listing, !listing.isEmpty {
                ForEach(listing.rows, id: \.key) { row in
                    versionRow(row)
                }
                if !listing.splits.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("拆开过的写法")).font(.callout.weight(.semibold))
                        Text(L10n.t("这些写法被你拆开过，不会再跟这首歌合在一起。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, listing.rows.isEmpty ? 0 : 8)
                    ForEach(listing.splits, id: \.key) { split in
                        splitRow(split)
                    }
                }
            } else {
                Text(L10n.t("没有认成同一首歌的其他写法"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func versionRow(_ row: SongVersions.Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                names(row.key)
                SettingsFlowRow(spacing: 6) {
                    if row.evidence.isEmpty {
                        LyricsManagerTag(icon: "link", text: L10n.t("经由其他写法连着"), tint: .secondary)
                    }
                    ForEach(row.evidence, id: \.self) { kind in
                        LyricsManagerTag(icon: "link", text: Self.evidenceLabel(kind), tint: .accentColor)
                    }
                    LyricsManagerTag(icon: row.sharesLyrics ? "text.quote" : "text.badge.xmark",
                                     text: row.sharesLyrics ? L10n.t("歌词共用一份") : L10n.t("歌词各自匹配"),
                                     tint: row.sharesLyrics ? .green : .secondary)
                }
            }
            Spacer(minLength: 0)
            Button(L10n.t("查看")) {
                dismiss()
                onOpen(row.key)
            }
            .disabled(store.summary(forKey: row.key) == nil)
            Button(L10n.t("拆开…")) {
                pendingSplit = row.key
                confirmingSplit = true
            }
                .disabled(busy)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func splitRow(_ split: SongVersions.SplitRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            names(split.key)
            Spacer(minLength: 0)
            Button(L10n.t("恢复合并")) { run { await store.unsplitSong(keys: split.mergeKeys) } }
                .disabled(busy)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    /// 歌名一行,歌手 · 专辑一行。歌词管理里没有这条(刚删掉)时按写法键的三段显示。
    private func names(_ key: String) -> some View {
        let s = store.summary(forKey: key)
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let title = s?.shownTitle ?? (parts.count > 1 ? parts[1] : key)
        let artist = s?.shownArtist ?? parts.first ?? ""
        let album = s?.displayAlbum ?? (parts.count > 2 ? parts[2] : "")
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.semibold)).lineLimit(2)
            Text([artist, album].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .textSelection(.enabled)
    }

    private var splitTitle: String {
        guard let key = pendingSplit else { return "" }
        let title = store.summary(forKey: key)?.shownTitle
            ?? key.split(separator: "|", omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? key
        return String(format: L10n.t("把「%@」拆出去？"), title)
    }

    private func run(_ action: @escaping () async -> Bool) {
        busy = true
        Task {
            _ = await action()
            busy = false
            await reload()
        }
    }

    /// 写法 → 实体与共享组取自播放那一侧的读取(EnrichCacheReader,整份在内存里),涉及的几条再用歌词管理刚重读的快照
    /// 校正一遍:拆开之后播放那一侧要等下一拍才读到。证据、拆开记录在后台读文件。
    private func reload() async {
        let key = summary.key
        let (edges, splits) = await Task.detached(priority: .userInitiated) {
            let edges = FileIO.read(SongVersions.tableURL).map { SongVersions.edges(tableData: $0, key: key) } ?? []
            let splits = FileIO.read(SongVersions.userURL).map(SongVersions.splits(userData:)) ?? []
            return (edges, splits)
        }.value
        var memberships = EnrichCacheReader.songMemberships()
        func refresh(_ keys: [String]) {
            for k in keys {
                memberships[k] = store.songMembership(forKey: k)
            }
        }
        refresh([key])
        if let first = SongVersions.listing(key: key, memberships: memberships, edges: edges, splits: splits) {
            refresh(first.rows.map(\.key) + first.splits.flatMap(\.mergeKeys))
        }
        listing = SongVersions.listing(key: key, memberships: memberships, edges: edges, splits: splits)
        loaded = true
    }

    static func evidenceLabel(_ kind: String) -> String {
        switch kind {
        case "isrc": return L10n.t("同一个 ISRC")
        case "mb_recording": return L10n.t("同一个 MusicBrainz 录音")
        case "spotify_track": return L10n.t("同一首 Spotify 曲目")
        case "amazon_asin": return L10n.t("同一首 Amazon Music 曲目")
        case "kkbox_song": return L10n.t("同一首 KKBOX 歌曲")
        case "soda_track": return L10n.t("同一首汽水音乐歌曲")
        case "youtube_video": return L10n.t("同一个 YouTube Music 视频")
        case "apple_song": return L10n.t("同一首 Apple Music 歌曲")
        case "netease_song": return L10n.t("同一首网易云音乐歌曲")
        case "qq_song": return L10n.t("同一首 QQ 音乐歌曲")
        case "family": return L10n.t("同一位歌手、同一个歌名，时长相近")
        case "lyrics": return L10n.t("各自找到的歌词一致")
        case "apple_name": return L10n.t("跟 Apple Music 登记的名字对得上")
        case "netease_name": return L10n.t("跟网易云音乐登记的名字对得上")
        default: return kind
        }
    }
}
