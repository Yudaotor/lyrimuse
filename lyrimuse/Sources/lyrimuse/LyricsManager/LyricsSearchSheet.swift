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
    // candidates/isSearching 分开存,而不是揉进一个"loading/loaded/failed"三态 enum——
    // 现在结果是陆续到达的(collector 那边改成 NDJSON 流式输出,谁先查完谁先展示,见
    // LyricsSearchService.search 的 onUpdate),搜索"进行中"和"目前已经有哪些候选"是
    // 两个独立维度:可能已经有几条候选摆在那了、但后面的源还没回来。用一个三态 enum
    // 表达不了"进行中 + 已经有部分结果"这个中间状态。
    @State private var candidates: [LyricsSearchService.Candidate] = []
    @State private var isSearching = false
    @State private var loadError: String?
    @State private var selectedSource: String?

    // 可编辑的查询关键词,初始值取自 originalXxx——默认就是"现有逻辑"那套查询。
    @State private var artist: String
    @State private var title: String
    @State private var album: String

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
        .frame(minWidth: 720, minHeight: 480)
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
                .disabled(isSearching || title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onSubmit { Task { await load() } }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // candidates 陆续到达、isSearching 才是"是否还没结束"的唯一依据——不能用
    // "candidates.isEmpty"反过来判断有没有搜索完:目前为止一个候选都还没到手,不代表
    // 五个源已经查完了(可能只是跑得快的那几个还没轮到),那样会把"还在搜"误判成
    // "查完了、真的什么都没有",提前弹出"没找到候选"的空状态提示。
    @ViewBuilder
    private var content: some View {
        if let msg = loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(msg).font(.callout).multilineTextAlignment(.center).padding(.horizontal, 40)
                Button(L10n.t("重试")) { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            if isSearching {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.t("正在查询网易云 / QQ音乐 / 酷狗 / Musixmatch / LRCLIB…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L10n.t("五个源都没找到可用的候选"), systemImage: "text.badge.xmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                if isSearching {
                    // 已经有候选可看了,但还有源没回来——小小一条提示,不用整页占用
                    // ProgressView 挡住已经到手的结果。
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("其它源仍在搜索中…"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                }
                HSplitView {
                    List(candidates, selection: $selectedSource) { c in
                        candidateRow(c)
                    }
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)

                    if let c = candidates.first(where: { $0.source == selectedSource }) ?? candidates.first {
                        previewPane(c)
                    }
                }
            }
        }
    }

    private func candidateRow(_ c: LyricsSearchService.Candidate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            coverThumbnail(c.coverURL, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.source).font(.body.weight(.medium))
                candidateMatchInfo(c)
                Text(String(format: L10n.t("分数 %@ · %@ 行"), "\(c.score)", "\(c.lineCount)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                characteristicBadges(c)
            }
            Spacer(minLength: 0)
        }
        .tag(c.source)
        .padding(.vertical, 3)
    }

    private func previewPane(_ c: LyricsSearchService.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                coverThumbnail(c.coverURL, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.source).font(.headline)
                    candidateMatchInfo(c)
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

    // 这个候选实际匹配到的歌名(单独一行)+ 歌手/专辑(合并一行,用"·"分隔)——不是每个源
    // 都能给全,哪一项是空的就不显示那一行,不留空白占位;title 单独一行是因为它通常
    // 跟搜索关键词的歌名差不多、但偶尔不同(比如带 Live/Remix 后缀),值得单独看清楚。
    @ViewBuilder
    private func candidateMatchInfo(_ c: LyricsSearchService.Candidate) -> some View {
        if !c.title.isEmpty {
            Text(c.title).font(.caption).lineLimit(1)
        }
        if !c.artist.isEmpty || !c.album.isEmpty {
            Text([c.artist, c.album].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // 封面缩略图——没有 URL(这个源本来就没给,比如 LRCLIB 恒无)或者加载失败/加载中,
    // 一律显示同一个占位图标,不特意区分"没有"和"加载中"这两种状态,用户不需要关心
    // 这个区别。
    @ViewBuilder
    private func coverThumbnail(_ url: URL?, size: CGFloat) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        coverPlaceholder
                    }
                }
            } else {
                coverPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.quaternary)
            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
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
        candidates = []
        loadError = nil
        selectedSource = nil
        isSearching = true
        do {
            try await LyricsSearchService.shared.search(artist: artist, title: title, album: album) { updated in
                candidates = updated
                // 只在第一次收到候选时选中"当前最靠前"的那个,后续更新哪怕重新排序也不
                // 抢用户已经手动点开看的那个候选——同一个 source 不会在后续更新里消失
                // (候选只增不减,见 collector 侧 scoreAndSort 的注释),只是分数/排序可能
                // 变,selectedSource 指向的行还在,不会失效。
                if selectedSource == nil {
                    selectedSource = updated.first?.source
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
        isSearching = false
    }
}
