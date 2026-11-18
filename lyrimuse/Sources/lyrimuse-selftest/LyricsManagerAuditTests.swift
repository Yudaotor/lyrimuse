import Foundation
import LyrimuseCore

/// 歌词管理整模块审计的修复(11 章决策 141)。lyrics-manager 组开头调。
@MainActor
func checkLyricsManagerAudit() {
    // ---- 整段编辑拒存的判据(LyricsExternalEdit,外部编辑器和「保存修改」共用) ----
    do {
        typealias E = LyricsExternalEdit
        expectEqual(E.hasLyricText("[ti:歌名]\n[00:01.00]\n\n"), false, "拒存判据: 只剩时间戳和文件头标签算没有歌词")
        expectEqual(E.hasLyricText("[00:01.00]第一句"), true, "拒存判据: 时间戳后面有字算有歌词")
        expectEqual(E.hasTimedLines("第一句\n第二句"), false, "拒存判据: 没有一行带时间戳")
        expectEqual(E.hasTimedLines("[00:01.00]第一句"), true, "拒存判据: 带时间戳的一行")
    }

    // ---- 搜索候选的进度句 ----
    do {
        typealias P = LyricsSearchProgress
        expectEqual(P.parts(responded: 0, done: 0, total: 0, round: 1), [.querying], "搜索进度: 还没收到第一行时说正在查询")
        expectEqual(P.parts(responded: 0, done: 3, total: 16, round: 1), [.waiting(13)], "搜索进度: 还没有源给结果时只说还有几个在搜")
        expectEqual(P.parts(responded: 6, done: 9, total: 16, round: 1), [.responded(6), .waiting(7)],
                    "搜索进度: 第一轮先说几个源已有结果(徽标的分子),再说还有几个在搜")
        expectEqual(P.parts(responded: 6, done: 16, total: 16, round: 1), [.responded(6)], "搜索进度: 这一轮都回来了不写 0")
        expectEqual(P.parts(responded: 0, done: 16, total: 16, round: 1), [.querying], "搜索进度: 都回来了又没有结果时不留空")
        expectEqual(P.parts(responded: 6, done: 4, total: 16, round: 2), [.retrying(round: 2), .waiting(12)],
                    "搜索进度: 第二轮另说一句,接着说这一轮还有几个在搜")
        expectEqual(P.parts(responded: 6, done: 20, total: 16, round: 3), [.retrying(round: 3)], "搜索进度: 第三轮照样标轮次,回来的比总数多也不写负数")
    }

    // ---- 接线(契约) ----
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let manager = source("lyrimuse/LyricsManager/LyricsManagerView.swift")
    let parts = source("lyrimuse/LyricsManager/LyricsManagerParts.swift")
    let store = source("lyrimuse/LyricsManager/EnrichCacheStore.swift")
    let sheet = source("lyrimuse/LyricsManager/LyricsSearchSheet.swift")
    let service = source("lyrimuse/LyricsManager/LyricsSearchService.swift")
    let runner = source("lyrimuse/LyricsManager/LyricsRematchRunner.swift")
    let quick = source("lyrimuse/LyricsManager/LyricsQuickSearchWindow.swift")
    let externalEditor = source("lyrimuse/LyricsManager/LyricsExternalEditor.swift")
    let searchCLI = source("../../lyrimuse-engine/searchcli.go")

    // 详情编辑
    do {
        let save = sourceBody("private func saveEdits(key: String, summary: EnrichCacheStore.Summary) async -> Bool", in: manager)
        expectEqual(sourceHas(save, "if !LyricsExternalEdit.hasLyricText(edited), LyricsExternalEdit.hasLyricText(original) {")
                    && sourceHas(save, "if !LyricsExternalEdit.hasTimedLines(edited),\n !loadedYRC.isEmpty || LyricsExternalEdit.hasTimedLines(loadedLyrics) {")
                    && save.components(separatedBy: "store.reportEditRejected(").count - 1 == 2, true,
                    "歌词管理: 正文改成空的、原来有时间轴改完一行时间戳都没有,保存前拒存,编辑框原样留着")
        expectEqual(sourceHas(save, "guard !isSavingEdits else { return false }\n isSavingEdits = true\n defer { isSavingEdits = false }")
                    && manager.contains(".disabled(detailIncomplete || !isEditorDirty || isSavingEdits)"), true,
                    "歌词管理: 保存进行中再按保存不另起一轮,保存键置灰")
        expectEqual(sourceBody("private func discardEdits()", in: manager).contains("store.dismissEditError()"), true,
                    "歌词管理: 放弃修改顺手收掉保存失败的红字")
        expectEqual(manager.contains(".disabled(editMode != .preview || detailIncomplete)"), true,
                    "歌词管理: 正文读不回来时偏移框同保存键一起禁掉")
        expectEqual(parts.contains("onUserScroll: { if isNowPlaying, follow { follow = false } })"), true,
                    "歌词管理: 只有滚动正在播放那首的预览才关跟随播放")
        expectEqual(sourceHas(manager, ".onReceive(LocalPlaybackSource.shared.$romanizationScripts.removeDuplicates().dropFirst()) { scripts in")
                    && sourceHas(manager, "lyrics: loadedLyrics, tr: loadedTr, roma: loadedRoma,\n scripts: scripts)"), true,
                    "歌词管理: 设置里改读音的文字种类,预览按推送来的新值重算")
        let applied = sourceBody(".onReceive(AppActions.shared.lyricsSearchApplied) { key in", in: manager)
        expectEqual(applied.contains("guard editingKey == key, !isEditorDirty else { return }"), true,
                    "歌词管理: 「搜索歌词…」采纳后只在编辑框没有未保存改动时重载")
        expectEqual(sourceHas(manager, "guard ms != shownStoredOffsetMs else { return }"), true,
                    "歌词管理: 偏移存储换代时只在存的值真变了才改输入框,不冲掉正在敲的数")
        expectEqual(manager.components(separatedBy: "title: summary.shownTitle, album: summary.album, key: summary.key)").count - 1 >= 2
                    && externalEditor.contains("key cacheKey: String? = nil"), true,
                    "歌词管理: 外部编辑器按条目 key 找那一条,不按三段重拼")
    }

    // 列表
    do {
        let single = sourceBody("private func singleItemMenu(_ summary: EnrichCacheStore.Summary) -> [LyricsManagerListMenuItem]", in: manager)
        expectEqual(single.components(separatedBy: "enabled: !editingThis)").count - 1, 2, "歌词管理: 正在编辑的那首右键菜单里标不了纯音乐")
        let more = sourceBody("private func detailMoreMenu(_ summary: EnrichCacheStore.Summary) -> some View", in: manager)
        expectEqual(more.components(separatedBy: ".disabled(editMode != .preview)").count - 1, 2, "歌词管理: 编辑中「⋯」里标不了纯音乐")
        expectEqual(manager.components(separatedBy: "markingInstrumental || editingAny(").count - 1, 2,
                    "歌词管理: 批量标纯音乐避开正在编辑的那首")
        expectEqual(manager.contains("if !isEditorDirty { focusCurrentlyPlaying(scroll: false) }"), true,
                    "歌词管理: 带着未保存修改关窗再开,不自动换歌")
        let reveal = sourceBody("private func revealInList(_ key: String)", in: manager)
        expectEqual(reveal.contains("guard select(key) else { return }") && reveal.contains("resetFilters()")
                    && reveal.contains("clearSearch()") && reveal.contains("pendingListReveal = key")
                    && sourceHas(manager, ".onChange(of: pendingListReveal) { _, key in\n guard let key else { return }\n pendingListReveal = nil\n centerListRow(key)"), true,
                    "歌词管理: 同曲条目「在列表中显示」被筛选挡住时先清掉,再滚到那一行")
        expectEqual(sourceHas(manager, ".onChange(of: store.summariesGeneration) { _, _ in\n guard !store.summaries.isEmpty else { return }\n if let a = artistFilter,"), true,
                    "歌词管理: 关窗清快照不重置歌手 / 专辑筛选")
        expectEqual(manager.contains("summary.shownArtist.isEmpty ? L10n.t(\"未知歌手\") : summary.shownArtist, summary.shownTitle)")
                    && sourceBody("private var cleanupMessage: String", in: manager).contains("writingDisplayName(key)"), true,
                    "歌词管理: 删除、清理确认框用列表上的歌名和歌手")
        expectEqual(manager.contains("let id = (s.isListedMV ? \"\\u{1E}\" : \"\") + s.normAlbum + \"\\u{1F}\" + s.normPrimaryArtist"), true,
                    "歌词管理: 按专辑分组时 MV 和没有专辑的歌分成两组")
        expectEqual(!manager.contains("store.summaries.contains(where: { $0.key == candidate })"), true,
                    "歌词管理: 找正在播放那首的条目走索引,不线性扫全库")
        expectEqual(manager.contains("guard await store.clearAll() else { return }")
                    && sourceBody("public func clearAll() async -> Bool", in: store).contains("return true"), true,
                    "歌词管理: 清空全部没成就不清选中")
    }

    // 搜索候选歌词 / 重新自动匹配
    do {
        expectEqual(runner.contains("final class LyricsRematchActivity: ObservableObject")
                    && sourceHas(runner, "LyricsRematchActivity.shared.begin()\n defer { LyricsRematchActivity.shared.end() }")
                    && sourceHas(manager, "@ObservedObject private var rematchActivity = LyricsRematchActivity.shared")
                    && sheet.contains(".disabled(autoMatching || rematchActivity.isRunning || applyingSource != nil || settingInstrumental)")
                    && sheet.contains("guard !autoMatching, !rematchActivity.isRunning, applyingSource == nil, !settingInstrumental else { return }"), true,
                    "重新匹配: 歌词管理和「搜索歌词…」窗口有一边在跑,另一边的按钮让开")
        expectEqual(sheet.contains("key: isDirty ? nil : songKey) { update in")
                    && service.contains("if let key, !key.isEmpty { process.arguments?.append(contentsOf: [\"-key\", key]) }")
                    && searchCLI.contains("cacheKey := fs.String(\"key\", \"\",")
                    && sourceHas(searchCLI, "if *cacheKey != \"\" {\n key = *cacheKey\n }"), true,
                    "搜索候选: 查询词没改过就把条目 key 原样交给引擎,不按剥过括号的歌名重拼")
        // 快照还没读好(首次开窗、放掉后再开)时首数留空,不写假的 0。
        expectEqual(sourceHas(store, "private var isReleased = true {\n didSet { if summariesLoaded == isReleased { summariesLoaded = !isReleased } }")
                    && sourceHas(store, "@Published public private(set) var summariesLoaded = false")
                    && sourceHas(sourceBody("private var sidebarHeader: some View", in: manager),
                                 "if store.summariesLoaded {\n Text(String(format: L10n.plural(\"共 %@ 首\"")
                    && sourceHas(manager, "count: store.summariesLoaded && ((count ?? 0) > 0 || status == .all) ? count : nil,")
                    && sourceHas(sourceBody("private var listHeader: some View", in: manager),
                                 "if committedSearchText.isEmpty, store.summariesLoaded {\n Text(selectableFiltered.count.formatted())"), true,
                    "歌词管理: 加载中标题、「全部」胶囊、列表头的首数留空,不显示 0")
        let progress = sourceBody("private var searchProgressText: String", in: sheet)
        expectEqual(sourceHas(progress, "let responded = Self.allLyricSourceNames.filter(respondedSources.contains).count")
                    && sourceHas(progress, "LyricsSearchProgress.parts(responded: responded, done: sourcesDone, total: sourcesTotal, round: searchRound)")
                    && sourceHas(progress, ".joined(separator: \" · \")")
                    && sheet.contains("Text(\"\\(Self.allLyricSourceNames.filter(respondedSources.contains).count)/\\(availabilityDenominator)\")"), true,
                    "搜索候选: 进度句「N 个源已有结果」跟徽标分子同一个数,应答源计数只数联网歌词源(11 章决策 185)")
        expectEqual(quick.contains("stored?.lyricsSource") && !quick.contains("EnrichCacheStore.shared.summary(forKey: key)"), true,
                    "搜索候选: 「当前使用」徽标读条目自己的来源,不依赖歌词管理的快照")
    }
}
