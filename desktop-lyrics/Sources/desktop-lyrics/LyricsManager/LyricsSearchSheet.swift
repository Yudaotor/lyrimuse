import SwiftUI

// "联网搜索候选歌词"弹窗,参考 LyricsX 的 SearchLyricsViewController:左侧候选列表
// (来源+分数+是否逐字),右侧选中候选的完整预览,"采用此候选"把内容交回调用方
// (LyricsManagerView 负责真正写回缓存,这里只管搜索和展示)。
struct LyricsSearchSheet: View {
    let artist: String
    let title: String
    let album: String
    let onApply: (LyricsSearchService.Candidate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var selectedSource: String?

    private enum LoadState {
        case loading
        case loaded([LyricsSearchService.Candidate])
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("搜索候选歌词").font(.title3.weight(.semibold))
                    Text("\(artist) - \(title)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            content
        }
        .frame(minWidth: 680, minHeight: 480)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("正在查询网易云 / QQ音乐 / 酷狗 / LRCLIB…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(msg).font(.callout).multilineTextAlignment(.center).padding(.horizontal, 40)
                Button("重试") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let candidates):
            if candidates.isEmpty {
                ContentUnavailableView("四个源都没找到可用的候选", systemImage: "text.badge.xmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(candidates, selection: $selectedSource) { c in
                        candidateRow(c)
                    }
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)

                    if let c = candidates.first(where: { $0.source == selectedSource }) ?? candidates.first {
                        previewPane(c)
                    }
                }
            }
        }
    }

    private func candidateRow(_ c: LyricsSearchService.Candidate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.source).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if c.hasWordTiming {
                        Label("逐字", systemImage: "text.word.spacing")
                            .foregroundStyle(.blue)
                    }
                    Text("分数 \(c.score)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
            Spacer()
        }
        .tag(c.source)
        .padding(.vertical, 2)
    }

    private func previewPane(_ c: LyricsSearchService.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(c.source).font(.headline)
                if c.hasWordTiming {
                    Label("含逐字时间轴", systemImage: "text.word.spacing")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                Spacer()
                Button("采用此候选") {
                    onApply(c)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            ScrollView {
                Text(c.lyrics)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
        .frame(minWidth: 380)
    }

    private func load() async {
        state = .loading
        do {
            let results = try await LyricsSearchService.shared.search(artist: artist, title: title, album: album)
            state = .loaded(results)
            selectedSource = results.first?.source
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
