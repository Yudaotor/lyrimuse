import AppKit
import LyrimuseCore
import SwiftUI
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-batch-import")

/// 歌词管理「导入歌词文件夹…」(11 章决策 150)。App 读文件夹里的歌词文件(文件夹可能在受保护的目录里,常驻引擎读不到),
/// 写一份暂存请求,交引擎 `plan-lyrics-import` 认出每组文件是哪首歌、出预览清单;用户在预览表里挑定、选好导入方式之后,
/// 交引擎 `import_lyrics_batch` 写入(`EnrichCacheStore.importLyricsBatch`,写之前打自动快照)。歌词库里没有对应歌曲、认得出歌手
/// 歌名的文件默认按身份存进导入库,以后放到这首时用(11 章决策 151)。
enum LyricsBatchImport {
    /// 导入方式,rawValue 跟引擎 importModeManual / importModePrefer / importModeFill 一致。
    enum Mode: String, CaseIterable, Identifiable {
        case prefer, manual, fill
        var id: String { rawValue }

        var title: String {
            switch self {
            case .prefer: L10n.t("替换现有歌词")
            case .manual: L10n.t("替换并锁定")
            case .fill: L10n.t("只补没有歌词的歌曲")
            }
        }

        var explanation: String {
            switch self {
            case .prefer: L10n.t("以后找到明显更好的版本（如带逐字时间轴）时仍会自动更换")
            case .manual: L10n.t("记为手动调整，不再被自动更换")
            case .fill: L10n.t("已有歌词的歌曲保持不变")
            }
        }
    }

    /// 导入方式记在本机偏好里,下次打开照旧。
    static let modeDefaultsKey = "np:lyricsBatchImportMode"
    /// 一次最多读这么多个文件、这么多字节,超了不导(请用户分几次)。
    static let maxFiles = 10_000
    static let maxTotalBytes = 200 << 20
    /// 暂存请求放这里,跟引擎 importStagingDir 是同一个目录。
    static let stagingDirectoryName = "lyrimuse-import-staging"

    struct Plan: Decodable {
        let items: [Item]
    }

    struct Option: Decodable, Hashable, Identifiable {
        let key: String
        let artist: String
        let title: String
        let album: String
        let durationSecs: Double?
        let hasLyrics: Bool
        /// 有纯文本歌词(「只补」时导入纯文本不换掉它)。
        let hasPlain: Bool?
        let manual: Bool
        let source: String?
        var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, artist, title, album, manual, source
            case durationSecs = "duration_secs"
            case hasLyrics = "has_lyrics"
            case hasPlain = "has_plain"
        }
    }

    enum Status: String, Decodable {
        case matched, ambiguous, unmatched, unrecognized, duplicate
    }

    struct Item: Decodable, Identifiable {
        let id: Int
        let files: [String]
        let format: String?
        let lines: Int?
        let hasWordTiming: Bool?
        let hasTranslation: Bool?
        let hasRomanization: Bool?
        let plainText: Bool?
        let artist: String?
        let title: String?
        let album: String?
        let status: Status
        let key: String?
        let options: [Option]?
        /// 歌词库里没有对应歌曲、认得出歌手和歌名,可以存进导入库。
        let canStore: Bool?

        enum CodingKeys: String, CodingKey {
            case id, files, format, lines, artist, title, album, status, key, options
            case canStore = "can_store"
            case hasWordTiming = "has_word_timing"
            case hasTranslation = "has_translation"
            case hasRomanization = "has_romanization"
            case plainText = "plain_text"
        }

        var choices: [Option] { options ?? [] }
    }

    struct Prepared {
        let folder: URL
        let staging: URL
        let plan: Plan
        /// 实际读进暂存的文件(相对路径);读不了的不在里面,监视文件夹据此只把这些记成处理过。
        let stagedPaths: Set<String>
    }

    enum PrepareError: Error {
        case noFiles
        case tooMany
        case failed
    }

    private struct StagingRequest: Encodable {
        struct File: Encodable {
            let name: String
            let path: String
            let data: Data
            /// 大过单个文件的上限:只交文件名,引擎据此报「文件过大」,不把几 MB 的内容塞进暂存。
            var tooLarge = false

            enum CodingKeys: String, CodingKey {
                case name, path, data
                case tooLarge = "too_large"
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(name, forKey: .name)
                try c.encode(path, forKey: .path)
                try c.encode(data, forKey: .data)
                if tooLarge { try c.encode(true, forKey: .tooLarge) }
            }
        }
        let files: [File]
    }

    static var stagingDirectory: URL { LyrimusePaths.configFile(stagingDirectoryName) }

    /// 读文件夹(含子文件夹)里认得的歌词文件,写暂存请求,交引擎出预览清单。阻塞,放后台跑。
    /// `onlyGroups`:只暂存这几组(`groupKey`)的文件,监视文件夹只交有变动的那几组;nil = 整个文件夹。
    static func prepare(folder: URL, onlyGroups: Set<String>? = nil) async -> Result<Prepared, PrepareError> {
        await Task.detached(priority: .userInitiated) { prepareBlocking(folder: folder, onlyGroups: onlyGroups) }.value
    }

    /// 引擎认得的后缀(importbatch.go importStemSuffixes),长的在前。
    private static let stemSuffixes = [".tr.lrc", ".roma.lrc", ".enhanced.lrc", ".lrcx", ".lrc", ".yrc", ".ttml", ".xml", ".qrc", ".krc", ".txt"]

    /// 一个文件属于哪一组:所在子目录 + 去掉后缀的文件名,不分大小写,跟引擎 groupImportFiles 同一个分法。
    static func groupKey(_ relativePath: String) -> String {
        let name = (relativePath as NSString).lastPathComponent
        let dir = (relativePath as NSString).deletingLastPathComponent
        let lower = name.lowercased()
        let stem = stemSuffixes.first { lower.hasSuffix($0) }.map { String(name.dropLast($0.count)) }
            ?? (name as NSString).deletingPathExtension
        return (dir + "\u{0}" + stem).lowercased()
    }

    private static func prepareBlocking(folder: URL, onlyGroups: Set<String>?) -> Result<Prepared, PrepareError> {
        let root = folder.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return .failure(.failed) }
        let extensions = Set(LyricsSearchService.importExtensions)
        var files: [StagingRequest.File] = []
        var total = 0
        for case let url as URL in walker {
            guard extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            let rel = full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : url.lastPathComponent
            if let onlyGroups, !onlyGroups.contains(groupKey(rel)) { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: LyricsSearchService.importMaxBytes + 1) else { continue }
            guard files.count < maxFiles else { return .failure(.tooMany) }
            if data.count > LyricsSearchService.importMaxBytes {
                files.append(.init(name: url.lastPathComponent, path: rel, data: Data(), tooLarge: true))
                continue
            }
            total += data.count
            guard total <= maxTotalBytes else { return .failure(.tooMany) }
            files.append(.init(name: url.lastPathComponent, path: rel, data: data))
        }
        guard !files.isEmpty else { return .failure(.noFiles) }
        FileIO.createDirectory(stagingDirectory)
        let staging = stagingDirectory.appendingPathComponent("\(UUID().uuidString).json")
        guard let body = try? JSONEncoder().encode(StagingRequest(files: files)), FileIO.write(body, to: staging) else {
            return .failure(.failed)
        }
        guard let result = ProcessRunner.run(LyrimusePaths.bundledEnginePath, ["plan-lyrics-import", staging.path],
                                             timeout: 300, environment: LyrimusePaths.engineProcessEnvironment()),
              result.succeeded,
              let plan = try? JSONDecoder().decode(Plan.self, from: result.stdout) else {
            logger.error("plan-lyrics-import failed for \(files.count, privacy: .public) files")
            discard(staging)
            return .failure(.failed)
        }
        return .success(Prepared(folder: folder, staging: staging, plan: plan, stagedPaths: Set(files.map(\.path))))
    }

    static func discard(_ staging: URL) {
        FileIO.remove(staging)
    }

    /// 早于 `age` 秒的暂存请求:面板没走到 onDisappear 就没了(随窗口一起关、App 退出)时留下的。App 启动时传 0 全部清掉。
    static func discardStaleStaging(olderThan age: TimeInterval = 3600) {
        let cutoff = Date().addingTimeInterval(-age)
        let names = (try? FileManager.default.contentsOfDirectory(
            at: stagingDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in names where url.pathExtension == "json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { FileIO.remove(url) }
        }
    }

    /// 时长写成 4:31。
    static func clock(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return LyricsCandidateDuration.clock(seconds)
    }
}

/// 打开歌词管理的「导入歌词文件夹」面板的请求(调试深链也走这里,见 AppActions.requestLyricsFolderImport)。
struct LyricsBatchImportRequest: Identifiable {
    let id = UUID()
    let folder: URL
}

/// 「导入歌词文件夹」的预览面板:读文件夹 → 预览表(每组对到哪首、要不要导)→ 导入方式 → 导入 → 结果。
struct LyricsBatchImportSheet: View {
    let folder: URL

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var languageSettings = AppLanguageObserver.shared
    @AppStorage(LyricsBatchImport.modeDefaultsKey) private var mode: LyricsBatchImport.Mode = .prefer
    @State private var prepared: LyricsBatchImport.Prepared?
    @State private var prepareError: LyricsBatchImport.PrepareError?
    /// 用户取消勾选的组。
    @State private var excluded: Set<Int> = []
    /// 用户勾上的手改过的组(引擎按 force 写)。
    @State private var forced: Set<Int> = []
    /// 歌词库里没有对应歌曲的组里,用户取消「存入导入库」的。
    @State private var notStored: Set<Int> = []
    /// 对得上好几首时用户挑的那一首。
    @State private var choices: [Int: String] = [:]
    /// 导入进行到哪一步(先打整库快照,歌词库大时要几十秒,再写入);nil = 没在导入。
    @State private var importPhase: EnrichCacheStore.BatchImportPhase?
    @State private var importedCount: Int?
    /// 这次存进导入库的个数(结果页分开说)。
    @State private var storedCount = 0
    @State private var importFailed = false
    /// 面板已经关了(随歌词管理窗口一起关):还在跑的导入收尾时自己删暂存。
    @State private var closed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 640)
        // 导入进行中不能关:关了也停不下来(快照照打、引擎照写),还会删掉引擎要读的暂存。
        .interactiveDismissDisabled(importPhase != nil)
        .task { await load() }
        .onDisappear {
            closed = true
            if let prepared, importPhase == nil { LyricsBatchImport.discard(prepared.staging) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.t("导入歌词文件夹")).font(.headline)
            Text(folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private var content: some View {
        if let importedCount {
            let songs = max(0, importedCount - storedCount)
            ContentUnavailableView {
                Label(songs == 0 && storedCount > 0
                      ? String(format: L10n.plural("已存入导入库 %@ 个文件", count: storedCount), "\(storedCount)")
                      : String(format: L10n.plural("已导入 %@ 首歌曲的歌词", count: songs), "\(songs)"),
                      systemImage: "checkmark.circle")
            } description: {
                VStack(spacing: 4) {
                    if songs > 0, storedCount > 0 {
                        Text(String(format: L10n.plural("另有 %@ 个文件存入导入库，播放到对应歌曲时使用", count: storedCount),
                                    "\(storedCount)"))
                    }
                    Text(L10n.t("导入前已自动备份歌词库，可在歌词管理的「⋯」菜单中恢复"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let prepareError {
            ContentUnavailableView(Self.prepareErrorText(prepareError), systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let prepared {
            planList(prepared.plan)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text(L10n.t("正在读取并匹配歌词文件…")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func prepareErrorText(_ error: LyricsBatchImport.PrepareError) -> String {
        switch error {
        case .noFiles: L10n.t("文件夹中没有可识别的歌词文件")
        case .tooMany: String(format: L10n.t("文件过多（上限 %@ 个、200 MB），请分批导入"), LyricsBatchImport.maxFiles.formatted())
        case .failed: L10n.t("读取失败，请重试")
        }
    }

    // MARK: - 预览表

    /// 一组最后对到哪首:用户挑过的,否则引擎认出的。
    private func target(_ item: LyricsBatchImport.Item) -> LyricsBatchImport.Option? {
        let key = choices[item.id] ?? item.key
        return item.choices.first { $0.key == key }
    }

    private enum Bucket: CaseIterable {
        case ready, choose, manual, hasLyrics, unmatched, unrecognized, duplicate
    }

    private func bucket(_ item: LyricsBatchImport.Item) -> Bucket {
        switch item.status {
        case .unmatched: return .unmatched
        case .unrecognized: return .unrecognized
        case .duplicate: return .duplicate
        case .matched, .ambiguous:
            guard let t = target(item) else { return .choose }
            if t.manual { return .manual }
            // 纯文本盖不住已有的逐行歌词,引擎不写(applyImportBatchLocked)。
            if mode == .fill || item.plainText == true, t.hasLyrics { return .hasLyrics }
            // 「只补」时纯文本也不换掉已有的纯文本(引擎同一条规则)。
            if mode == .fill, item.plainText == true, t.hasPlain == true { return .hasLyrics }
            return .ready
        }
    }

    private func bucketTitle(_ b: Bucket, count: Int) -> String {
        let n = "\(count)"
        switch b {
        case .ready: return String(format: L10n.t("将导入 %@"), n)
        case .choose: return String(format: L10n.t("对应多首歌曲，请选择 %@"), n)
        case .manual: return String(format: L10n.t("已人工修正，默认不导入 %@"), n)
        case .hasLyrics: return String(format: L10n.t("已有歌词，将跳过 %@"), n)
        case .unmatched: return String(format: L10n.t("歌词库中没有对应的歌曲 %@"), n)
        case .unrecognized: return String(format: L10n.t("无法识别歌词 %@"), n)
        case .duplicate: return String(format: L10n.t("与其他文件对应同一首歌曲，未使用 %@"), n)
        }
    }

    private func isIncluded(_ item: LyricsBatchImport.Item) -> Bool {
        switch bucket(item) {
        case .ready: !excluded.contains(item.id)
        case .manual: forced.contains(item.id)
        case .unmatched: item.canStore == true && !notStored.contains(item.id)
        default: false
        }
    }

    private func planList(_ plan: LyricsBatchImport.Plan) -> some View {
        let grouped = Dictionary(grouping: plan.items, by: bucket)
        return List {
            ForEach(Bucket.allCases, id: \.self) { b in
                if let items = grouped[b], !items.isEmpty {
                    Section {
                        ForEach(items) { item in row(item, bucket: b) }
                    } header: {
                        Text(bucketTitle(b, count: items.count))
                    } footer: {
                        if b == .unmatched, items.contains(where: { $0.canStore == true }) {
                            Text(L10n.t("勾选的文件存入导入库，播放到对应歌曲时使用"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ item: LyricsBatchImport.Item, bucket b: Bucket) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if b == .ready || b == .manual || (b == .unmatched && item.canStore == true) {
                Toggle("", isOn: Binding(
                    get: { isIncluded(item) },
                    set: { on in
                        if b == .manual {
                            if on { forced.insert(item.id) } else { forced.remove(item.id) }
                        } else if b == .unmatched {
                            if on { notStored.remove(item.id) } else { notStored.insert(item.id) }
                        } else if on {
                            excluded.remove(item.id)
                        } else {
                            excluded.insert(item.id)
                        }
                    }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.files.first ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.files.joined(separator: "\n"))
                Text(fileTraits(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            targetView(item, bucket: b)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    /// 「LRC · 32 行 · 逐字 · 译文 · 另有 2 个文件」。
    private func fileTraits(_ item: LyricsBatchImport.Item) -> String {
        var parts: [String] = []
        if let format = item.format, !format.isEmpty { parts.append(format.uppercased()) }
        if let lines = item.lines, lines > 0 { parts.append(String(format: L10n.t("%@ 行"), "\(lines)")) }
        if item.hasWordTiming == true { parts.append(L10n.t("逐字时间轴")) }
        if item.hasTranslation == true { parts.append(L10n.t("译文")) }
        if item.hasRomanization == true { parts.append(L10n.t("自带读音")) }
        if item.plainText == true { parts.append(L10n.t("纯文本")) }
        if item.files.count > 1 {
            parts.append(String(format: L10n.plural("另有 %@ 个文件", count: item.files.count - 1), "\(item.files.count - 1)"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func targetView(_ item: LyricsBatchImport.Item, bucket b: Bucket) -> some View {
        if item.status == .ambiguous {
            SettingsGlassMenuPicker(
                selection: Binding(
                    get: { choices[item.id] ?? item.key ?? "" },
                    set: { choices[item.id] = $0 }),
                options: [""] + item.choices.map(\.key),
                label: { key in
                    guard let o = item.choices.first(where: { $0.key == key }) else { return L10n.t("选择歌曲") }
                    return optionLabel(o)
                },
                compact: true)
                .fixedSize()
        } else if let t = target(item) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).lineLimit(1)
                Text([t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(optionLabel(t))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(guessText(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if b == .unmatched, item.canStore != true {
                    Text(L10n.t("无法确定歌手，不存入"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 「歌名 · 歌手 · 专辑 · 4:31」。
    private func optionLabel(_ o: LyricsBatchImport.Option) -> String {
        ([o.title, o.artist, o.album] + [LyricsBatchImport.clock(o.durationSecs)].compactMap { $0 })
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// 库里没有对应歌曲时,写从文件里认出来的身份。
    private func guessText(_ item: LyricsBatchImport.Item) -> String {
        [item.title, item.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - 底栏

    private var selectedItems: [LyricsBatchImport.Item] {
        (prepared?.plan.items ?? []).filter(isIncluded)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if importedCount == nil, prepared != nil {
                // 说明单独一行、能折行:跟下拉、按钮挤在一行时长语言被截掉半句。
                Text(mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footerControls
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var footerControls: some View {
        HStack(spacing: 12) {
            if importedCount == nil, prepared != nil {
                Text(L10n.t("导入方式"))
                    .foregroundStyle(.secondary)
                SettingsGlassMenuPicker(selection: $mode, options: LyricsBatchImport.Mode.allCases, label: \.title, compact: true)
                    .fixedSize()
                    .disabled(importPhase != nil)
            }
            if importFailed {
                Label(L10n.t("导入失败，请重试"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            if importedCount != nil || prepared == nil {
                Button(L10n.t("完成")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .settingsGlassButtons(inSheet: true)
            } else {
                Button(L10n.t("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .settingsGlassButtons(inSheet: true)
                    .disabled(importPhase != nil)
                let count = selectedItems.count
                Button(importButtonTitle(count: count)) {
                    Task { await runImport() }
                }
                .keyboardShortcut(.defaultAction)
                .settingsProminentGlassButton(tint: .accentColor)
                .disabled(count == 0 || importPhase != nil)
            }
        }
    }

    private func importButtonTitle(count: Int) -> String {
        switch importPhase {
        case .backingUp: L10n.t("正在备份歌词库…")
        case .writing: L10n.t("正在导入…")
        case nil: String(format: L10n.plural("导入 %@ 首", count: count), "\(count)")
        }
    }

    // MARK: - 动作

    private func load() async {
        guard prepared == nil, prepareError == nil else { return }
        let result = await LyricsBatchImport.prepare(folder: folder)
        // 读的时候面板已经关了:读好的暂存没人用,删掉(onDisappear 那时还没有它)。
        if Task.isCancelled || closed {
            if case .success(let p) = result { LyricsBatchImport.discard(p.staging) }
            return
        }
        switch result {
        case .success(let p): prepared = p
        case .failure(let e): prepareError = e
        }
    }

    private func runImport() async {
        guard let prepared, importPhase == nil else { return }
        let chosen = Self.dedupe(selectedItems) { target($0)?.key }
        let items: [[String: Any]] = chosen.compactMap { item in
            if item.status == .unmatched { return ["id": item.id, "key": "", "store": true] }
            guard let key = target(item)?.key else { return nil }
            var entry: [String: Any] = ["id": item.id, "key": key]
            if forced.contains(item.id) { entry["force"] = true }
            return entry
        }
        let storing = chosen.filter { $0.status == .unmatched }.count
        importPhase = .backingUp
        importFailed = false
        let changed = await EnrichCacheStore.shared.importLyricsBatch(
            staging: prepared.staging, mode: mode.rawValue, items: items) { importPhase = $0 }
        importPhase = nil
        if let changed {
            storedCount = storing
            importedCount = changed
            LyricsBatchImport.discard(prepared.staging)
        } else {
            importFailed = true
            if closed { LyricsBatchImport.discard(prepared.staging) }
        }
    }

    /// 同一首歌只导一组:挑歌之后几组对到同一首(「01. 晴天」挑了《晴天》、又有「周杰伦 - 晴天」),或几个子文件夹里有同一首
    /// 库里没有的歌,各发一组的话后写的盖掉先写的、结果页也多算。留带逐字的、再是行数多的那组。
    static func dedupe(_ items: [LyricsBatchImport.Item], target: (LyricsBatchImport.Item) -> String?) -> [LyricsBatchImport.Item] {
        func groupKey(_ item: LyricsBatchImport.Item) -> String? {
            if item.status == .unmatched {
                guard let title = item.title, !title.isEmpty else { return nil }
                return "id:" + (item.artist ?? "").lowercased() + "|" + title.lowercased()
            }
            return target(item).map { "key:" + $0 }
        }
        func better(_ a: LyricsBatchImport.Item, _ b: LyricsBatchImport.Item) -> Bool {
            let wa = a.hasWordTiming == true, wb = b.hasWordTiming == true
            if wa != wb { return wa }
            return (a.lines ?? 0) > (b.lines ?? 0)
        }
        var best: [String: LyricsBatchImport.Item] = [:]
        for item in items {
            guard let k = groupKey(item) else { continue }
            if let cur = best[k], !better(item, cur) { continue }
            best[k] = item
        }
        return items.filter { item in
            guard let k = groupKey(item) else { return true }
            return best[k]?.id == item.id
        }
    }
}
