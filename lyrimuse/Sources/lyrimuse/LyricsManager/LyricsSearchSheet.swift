import SwiftUI

// "联网搜索候选歌词"弹窗,参考 LyricsX 的 SearchLyricsViewController:左侧候选列表
// (来源+分数+是否逐字),右侧选中候选的完整预览,"采用此候选"把内容交回调用方
// (LyricsManagerView 负责真正写回缓存,这里只管搜索和展示)。
//
// 歌名/歌手/专辑是可编辑字段,默认沿用这首歌本身的元数据,也支持改关键词后重新联网
// 查(比如原始元数据不准/有别名,想换个关键词试试能不能搜到更好的候选)。改这三个
// 字段只影响"拿什么关键词去查",不影响写回哪条缓存记录——onApply 只回传选中的
// candidate,真正决定写入 key 的是调用方 LyricsManagerView.swift 里早就捕获好的稳定
// key,跟 artist/title/album 这三个字段无关。
struct LyricsSearchSheet: View {
    // 原始值——用来在用户改乱查询关键词之后一键恢复,也是"默认查询"这句里"默认"的
    // 具体所指(初次打开时 artist/title/album 就是从这三个值来的)。
    let originalArtist: String
    let originalTitle: String
    let originalAlbum: String
    let onApply: (LyricsSearchService.Candidate) -> Void

    @Environment(\.dismiss) private var dismiss
    // 只为了让这个弹窗在手动切换语言时重新渲染,同 LyricsManagerView 的理由。
    @ObservedObject private var languageSettings = AppSettings.shared
    @State private var state: LoadState = .loading
    @State private var selectedSource: String?

    // 可编辑的查询关键词,初始值取自 originalXxx——默认就是"现有逻辑"那套查询。
    @State private var artist: String
    @State private var title: String
    @State private var album: String

    private enum LoadState {
        case loading
        case loaded([LyricsSearchService.Candidate])
        case failed(String)
    }

    init(artist: String, title: String, album: String, onApply: @escaping (LyricsSearchService.Candidate) -> Void) {
        self.originalArtist = artist
        self.originalTitle = title
        self.originalAlbum = album
        self.onApply = onApply
        self._artist = State(initialValue: artist)
        self._title = State(initialValue: title)
        self._album = State(initialValue: album)
    }

    private var isDirty: Bool {
        artist != originalArtist || title != originalTitle || album != originalAlbum
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("搜索候选歌词")).font(.title3.weight(.semibold))
                Spacer()
                Button(L10n.t("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            queryFieldsBar

            Divider()

            content
        }
        .frame(minWidth: 680, minHeight: 480)
        .task { await load() }
    }

    // 三个可编辑的查询维度——默认展示这首歌本身的元数据,.task { await load() } 直接
    // 拿这三个初始值发起搜索;改了之后要显式点"重新搜索"(或者在任一输入框按下 Enter)
    // 才会真的重新发起查询,不会敲一个字就发一次网络请求。
    private var queryFieldsBar: some View {
        HStack(spacing: 10) {
            TextField(L10n.t("歌名"), text: $title).textFieldStyle(.roundedBorder)
            TextField(L10n.t("歌手"), text: $artist).textFieldStyle(.roundedBorder)
            TextField(L10n.t("专辑"), text: $album).textFieldStyle(.roundedBorder)
            if isDirty {
                Button(L10n.t("恢复原信息")) {
                    artist = originalArtist
                    title = originalTitle
                    album = originalAlbum
                }
                .buttonStyle(.link)
            }
            Button(L10n.t("重新搜索")) { Task { await load() } }
                .disabled(isLoading || title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onSubmit { Task { await load() } }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.t("正在查询网易云 / QQ音乐 / 酷狗 / Musixmatch / LRCLIB…"))
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
