import LyrimuseCore
import SwiftUI

// 「听歌报告」卡里的「推送内容」:四档报告共用的自定义标题和正文(Core `DigestTemplate`,引擎 digesttemplate.go)。
// 编辑器里点一个占位符插到正在编辑的那一栏末尾,下面按这一期的真实数据(取不到时用测试数据)实时预览。见 15 章决策 84。

/// 「推送内容」那一行:默认 / 已自定义,行尾「编辑…」开编辑器。
struct DigestTemplateRow: View {
    @ObservedObject private var features = FeatureSettingsStore.shared
    @State private var editing = false

    var body: some View {
        SettingsRow(icon: "text.quote", title: L10n.t("推送内容"),
                    subtitle: features.digestTemplate.isCustom ? L10n.t("已自定义，按纯文本推送") : L10n.t("默认")) {
            Button(L10n.t("编辑…")) { editing = true }
                .controlSize(.small)
                .buttonBorderShape(.capsule)
        }
        .settingsSearchHighlight(title: L10n.t("推送内容"))
        .sheet(isPresented: $editing) {
            DigestTemplateEditor(original: features.digestTemplate) { saved in
                editing = false
                guard saved != features.digestTemplate else { return }
                features.digestTemplate = saved
                Task { await features.save() }
            } onCancel: {
                editing = false
            }
        }
    }
}

/// 编辑标题和正文。保存时跟默认一样的那一段存成空(`DigestTemplate.resolved`)。
struct DigestTemplateEditor: View {
    let original: DigestTemplate
    let onSave: (DigestTemplate) -> Void
    let onCancel: () -> Void

    @ObservedObject private var features = FeatureSettingsStore.shared
    @State private var title: String
    @State private var bodyText: String
    @State private var kind: NotificationPreview.Kind = .daily
    @State private var loaded: [NotificationPreview.Kind: NotificationPreviewLoader.State] = [:]
    @State private var loading: Set<NotificationPreview.Kind> = []
    @FocusState private var focus: Field?
    /// 最近一次在编辑的那一栏:点占位符时焦点会离开输入框,插到这一栏。
    @State private var lastField: Field = .body
    private let now = Date()

    private enum Field { case title, body }

    init(original: DigestTemplate, onSave: @escaping (DigestTemplate) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: original.editableTitle)
        _bodyText = State(initialValue: original.editableBody)
    }

    private var draft: DigestTemplate { DigestTemplate.resolved(title: title, body: bodyText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("推送内容")).font(.system(size: 15, weight: .bold))
                Text(L10n.t("四档报告共用。一行里的占位符都没有数据时，这一行不发送"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fields
            placeholderChips
            preview
            if draft.isCustom {
                Label(L10n.t("自定义内容按纯文本推送，不套用各平台的卡片排版"), systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button(L10n.t("恢复默认")) {
                    title = DigestTemplate.defaultTitle
                    bodyText = DigestTemplate.defaultBody
                }
                .disabled(!draft.isCustom)
                Spacer()
                Button(L10n.t("取消")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("保存")) { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: focus) { _, field in if let field { lastField = field } }
        .task(id: kind) { await load(kind) }
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text(L10n.t("标题")).gridColumnAlignment(.trailing)
                TextField(L10n.t("标题"), text: $title, prompt: Text(DigestTemplate.defaultTitle))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .title)
            }
            GridRow {
                Text(L10n.t("正文"))
                TextEditor(text: $bodyText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 130)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                    .focused($focus, equals: .body)
            }
        }
        .font(.system(size: 13))
    }

    /// 占位符一排:标签是说法,悬停说明写占位符本身和它是什么。
    private var placeholderChips: some View {
        SettingsFlowRow(spacing: 5) {
            ForEach(DigestTemplate.placeholders, id: \.self) { name in
                Button { insert(name) } label: {
                    Text(Self.label(name))
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(SettingsGlassHoverButtonStyle())
                .hoverNote("{\(name)}  " + Self.note(name))
            }
        }
    }

    private func insert(_ name: String) {
        let token = "{\(name)}"
        switch lastField {
        case .title:
            title += token
        case .body:
            // 多行的(三份榜单、整份正文)单独起一行。
            let multiline = ["body", "top_artists", "top_albums", "top_tracks"].contains(name)
            if multiline, !bodyText.isEmpty, !bodyText.hasSuffix("\n") { bodyText += "\n" }
            bodyText += token
        }
    }

    // MARK: 预览

    private var real: (title: String, stats: NotificationPreview.Stats)? {
        if case .real(let title, let stats)? = loaded[kind] { return (title, stats) }
        return nil
    }

    private var preview: some View {
        let stats = real?.stats ?? NotificationPreview.sample(kind)
        let defaultTitle = real?.title ?? NotificationPreview.title(kind, now: now)
        let defaultBody = NotificationPreview.body(stats, topN: features.digestTopN)
        let out = draft.render(defaultTitle: defaultTitle, defaultBody: defaultBody, stats: stats, topN: features.digestTopN)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.t("预览")).font(.system(size: 12, weight: .semibold))
                SettingsPillSegmentedControl(selection: $kind, options: NotificationPreview.Kind.allCases, label: {
                    $0 == .daily ? L10n.t("每日报告") : L10n.t("每周小结")
                }, minWidth: 0)
                .fixedSize()
                Spacer()
                Group {
                    if real != nil {
                        Text(String(format: L10n.t("真实数据 · %@"), stats.sourceName))
                    } else if loading.contains(kind) {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(L10n.t("正在取真实数据…"))
                        }
                    } else {
                        Text(L10n.t("测试数据"))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(out.title).font(.system(size: 13, weight: .semibold))
                    Text(out.body).font(.system(size: 12.5))
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 190)
            .settingsCardBackground(cornerRadius: 10, inSheet: true)
        }
    }

    private func load(_ kind: NotificationPreview.Kind) async {
        if let hit = NotificationPreviewLoader.cached(kind) {
            loaded[kind] = hit
            return
        }
        loading.insert(kind)
        let state = await NotificationPreviewLoader.load(kind)
        loading.remove(kind)
        if let state { loaded[kind] = state }
    }

    // MARK: 占位符的说法

    static func label(_ name: String) -> String {
        switch name {
        case "title": return L10n.t("默认标题")
        case "body": return L10n.t("默认正文")
        case "summary": return L10n.t("概况")
        case "plays": return L10n.t("播放次数")
        case "prev_plays": return L10n.t("上期次数")
        case "prev_label": return L10n.t("上期名称")
        case "change": return L10n.t("涨跌")
        case "duration": return L10n.t("时长")
        case "top_artists": return L10n.t("歌手榜")
        case "top_albums": return L10n.t("专辑榜")
        case "top_tracks": return L10n.t("歌曲榜")
        case "top_artist": return L10n.t("最常听的歌手")
        case "top_album": return L10n.t("最常听的专辑")
        case "top_track": return L10n.t("最常听的歌曲")
        case "new_artists": return L10n.t("新歌手数")
        case "new_artist_names": return L10n.t("新歌手名单")
        case "source": return L10n.t("数据来源")
        case "from": return L10n.t("开始日期")
        case "to": return L10n.t("结束日期")
        case "link": return L10n.t("榜单链接")
        default: return name
        }
    }

    static func note(_ name: String) -> String {
        switch name {
        case "title": return L10n.t("不自定义时的标题，带这一期的日期")
        case "body": return L10n.t("不自定义时的整份正文")
        case "summary": return L10n.t("默认正文的第一行：次数、跟上一期比、时长")
        case "plays": return L10n.t("这一期的播放次数")
        case "prev_plays": return L10n.t("上一期的播放次数，日报没有")
        case "prev_label": return L10n.t("上一期怎么称呼，如「前一周」")
        case "change": return L10n.t("跟上一期比的涨跌，如「↑12%」")
        case "duration": return L10n.t("听了多久，如「17 小时 52 分」")
        case "top_artists": return L10n.t("歌手榜，按「每类列出」的条数，一行一位")
        case "top_albums": return L10n.t("专辑榜，按「每类列出」的条数，一行一张")
        case "top_tracks": return L10n.t("歌曲榜，按「每类列出」的条数，一行一首")
        case "top_artist": return L10n.t("这一期听得最多的歌手")
        case "top_album": return L10n.t("这一期听得最多的专辑")
        case "top_track": return L10n.t("这一期听得最多的歌曲")
        case "new_artists": return L10n.t("这一期新听的歌手有几位")
        case "new_artist_names": return L10n.t("新听的歌手里听得最多的几位")
        case "source": return L10n.t("Last.fm 或 ListenBrainz")
        case "from": return L10n.t("这一期的第一天")
        case "to": return L10n.t("这一期的最后一天")
        case "link": return L10n.t("在 Last.fm 或 ListenBrainz 上看完整榜单的地址")
        default: return ""
        }
    }
}
