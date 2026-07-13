import SwiftUI

// 歌词管理窗口:浏览目前 collector 缓存了哪些歌的歌词、来源是什么,支持手动纠正内容、
// 单独移除逐字时间轴、或整条删除(强制下次播放重新解析)。参考 LyricsX 的歌词管理能力,
// 但不做"手动搜索/联网重新匹配"那部分——歌词解析本来就在 Go collector 那边,这里只管
// 已经缓存下来的内容,改动通过 EnrichCacheStore 落盘+踢一脚重启 collector 生效(见该
// 文件顶部注释,解释为什么必须这么做而不是直接改内存)。
struct LyricsManagerView: View {
    @ObservedObject private var store = EnrichCacheStore.shared
    @State private var searchText = ""
    @State private var selectedKey: String?
    @State private var editedLyrics = ""
    @State private var editedTr = ""
    @State private var editedRoma = ""
    @State private var showDeleteConfirm = false

    private var filtered: [EnrichCacheStore.Summary] {
        guard !searchText.isEmpty else { return store.summaries }
        let q = searchText.lowercased()
        return store.summaries.filter {
            $0.artist.lowercased().contains(q) || $0.title.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selectedKey) { summary in
                LyricsManagerRow(summary: summary)
            }
            .searchable(text: $searchText, prompt: "搜索歌手/歌名")
            .navigationTitle("歌词管理(\(store.summaries.count))")
            .toolbar {
                ToolbarItem {
                    Button {
                        store.reload()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
        } detail: {
            if let key = selectedKey, let summary = store.summaries.first(where: { $0.key == key }) {
                detailView(key: key, summary: summary)
            } else {
                ContentUnavailableView("选择左侧一首歌", systemImage: "text.quote")
            }
        }
        .onAppear { store.reload() }
        .frame(minWidth: 720, minHeight: 440)
    }

    @ViewBuilder
    private func detailView(key: String, summary: EnrichCacheStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(summary.artist) - \(summary.title)").font(.headline)
                    Text(summary.album).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    if summary.isManual {
                        Label("人工修正", systemImage: "pencil.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    if summary.hasWordTiming {
                        Label("逐字", systemImage: "text.word.spacing")
                            .foregroundStyle(.blue)
                    }
                    Text(summary.lyricsSource.isEmpty ? "无来源" : summary.lyricsSource)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                .font(.caption)
            }

            GroupBox("歌词(LRC)") {
                TextEditor(text: $editedLyrics)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
            }
            GroupBox("译文") {
                TextEditor(text: $editedTr).frame(minHeight: 60)
            }
            GroupBox("罗马音") {
                TextEditor(text: $editedRoma).frame(minHeight: 60)
            }

            if let error = store.lastError {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button("保存修改") {
                    store.saveEdit(key: key, lyrics: editedLyrics, tr: editedTr, roma: editedRoma)
                }
                .keyboardShortcut("s", modifiers: .command)

                if summary.hasWordTiming {
                    Button("移除逐字时间轴(仅保留整行歌词)") {
                        store.removeWordTiming(key: key)
                    }
                }

                Spacer()

                Button("删除此缓存", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
        .padding(20)
        .onAppear { loadDetail(key: key) }
        .onChange(of: key) { _, newKey in loadDetail(key: newKey) }
        .confirmationDialog(
            "确定要删除「\(summary.artist) - \(summary.title)」的缓存吗?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                store.delete(key: key)
                selectedKey = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次播放这首歌会重新走一遍匹配解析,不保证一定能找到一样的歌词。")
        }
    }

    private func loadDetail(key: String) {
        let d = store.detail(for: key)
        editedLyrics = d.lyrics
        editedTr = d.tr
        editedRoma = d.roma
    }
}

private struct LyricsManagerRow: View {
    let summary: EnrichCacheStore.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(summary.artist) - \(summary.title)")
            HStack(spacing: 6) {
                if !summary.hasLyrics {
                    Text("无歌词").foregroundStyle(.red)
                } else {
                    Text(summary.lyricsSource.isEmpty ? "?" : summary.lyricsSource)
                        .foregroundStyle(.secondary)
                }
                if summary.hasWordTiming {
                    Image(systemName: "text.word.spacing").foregroundStyle(.blue)
                }
                if summary.isManual {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                }
            }
            .font(.caption2)
        }
    }
}
