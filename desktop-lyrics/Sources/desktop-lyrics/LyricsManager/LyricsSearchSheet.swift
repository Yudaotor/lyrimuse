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
                    Text(L10n.t("搜索候选歌词")).font(.title3.weight(.semibold))
                    Text("\(artist) - \(title)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.t("关闭")) { dismiss() }
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
                Text(L10n.t("正在查询网易云 / QQ音乐 / 酷狗 / LRCLIB…"))
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
                Button(L10n.t("重试")) { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let candidates):
            if candidates.isEmpty {
                ContentUnavailableView(L10n.t("四个源都没找到可用的候选"), systemImage: "text.badge.xmark")
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
            VStack(alignment: .leading, spacing: 4) {
                Text(c.source).font(.body.weight(.medium))
                Text(String(format: L10n.t("分数 %@ · %@ 行"), "\(c.score)", "\(c.lineCount)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                characteristicBadges(c)
            }
            Spacer()
        }
        .tag(c.source)
        .padding(.vertical, 3)
    }

    private func previewPane(_ c: LyricsSearchService.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.source).font(.headline)
                    Text(String(format: L10n.t("分数 %@ · %@ 行"), "\(c.score)", "\(c.lineCount)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.t("采用此候选")) {
                    onApply(c)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            characteristicBadges(c)
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

    // 逐字/译文/罗马音——分别对应"是否有逐字时间戳""是否带翻译""是否带罗马音标注",
    // 跟 LyricsManagerView 详情页三个编辑区(歌词/译文/罗马音)用同一组图标,方便用户
    // 把候选列表里的图标和保存后详情页里的字段对上号。
    @ViewBuilder
    private func characteristicBadges(_ c: LyricsSearchService.Candidate) -> some View {
        HStack(spacing: 5) {
            if c.hasWordTiming {
                characteristicBadge(L10n.t("逐字时间戳"), "text.word.spacing", .blue)
            }
            if c.hasTranslation {
                characteristicBadge(L10n.t("译文"), "character.book.closed", .green)
            }
            if c.hasRomanization {
                characteristicBadge(L10n.t("罗马音"), "textformat.abc", .purple)
            }
        }
        .font(.caption2)
    }

    private func characteristicBadge(_ text: String, _ icon: String, _ tint: Color) -> some View {
        Label(text, systemImage: icon)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
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
