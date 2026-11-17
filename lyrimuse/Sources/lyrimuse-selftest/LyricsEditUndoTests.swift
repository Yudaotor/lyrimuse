import Foundation
import LyrimuseCore

/// 歌词改动之后的撤销:「搜索歌词…」采纳(11 章决策 177),歌词管理「保存修改」、外部编辑器存回、「重新自动匹配」、
/// 标 / 撤纯音乐(11 章决策 178),多选「全部标为纯音乐」(11 章决策 179)。lyrics-manager 组开头调。
@MainActor
func checkLyricsEditUndo() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let engine = source("../../lyrimuse-engine/enrichundo.go")
    let edit = source("../../lyrimuse-engine/enrichedit.go")
    let sheet = source("lyrimuse/LyricsManager/LyricsSearchSheet.swift")
    let quick = source("lyrimuse/LyricsManager/LyricsQuickSearchWindow.swift")
    let store = source("lyrimuse/LyricsManager/EnrichCacheStore.swift")
    let channel = source("lyrimuse/LyricsManager/EnrichEditChannel.swift")
    let button = source("lyrimuse/LyricsManager/LyricsEditUndoButton.swift")
    let manager = source("lyrimuse/LyricsManager/LyricsManagerView.swift")
    let actions = source("lyrimuse/UI/LyricsWindowActions.swift")
    let windowView = source("lyrimuse/UI/LyricsWindowView.swift")
    let external = source("lyrimuse/LyricsManager/LyricsExternalEditor.swift")
    let rematchEngine = source("../../lyrimuse-engine/lyricsrematch.go")

    // 跟引擎对拍:时限、错误码、请求和结果的键。
    expectEqual(sourceHas(engine, "enrichUndoTTL = \(Int(LyricsEditUndo.engineTTLSeconds)) * time.Second")
                && LyricsEditUndo.offerSeconds < LyricsEditUndo.engineTTLSeconds, true,
                "采纳撤销: 引擎认 undo_id 的时限跟 App 记的一致,「撤销」按钮比它早消失")
    for code in LyricsEditUndo.engineErrorCodes {
        expectEqual(engine.contains("= \"\(code)\""), true, "采纳撤销: 引擎有错误码 \(code)")
        expectEqual(LyricsEditUndo.reasonKey(code: code) != nil, true, "采纳撤销: 错误码 \(code) 有对应的一句")
    }
    expectEqual(LyricsEditUndo.reasonKey(code: nil), nil, "采纳撤销: 没有错误码时交给通道的原因或通用那句")
    let showFeedback = sourceBody("private func showApplyFeedback(_ text: String, ok: Bool, undoable: Bool = false)", in: sheet)
    expectEqual(sourceHas(showFeedback, "let ownUndo = pendingUndo?.id")
                && sourceHas(showFeedback, "guard !undoing else { return }\n if pendingUndo?.id == ownUndo { pendingUndo = nil }")
                && !sourceHas(showFeedback, "guard !undoing else { return }\n pendingUndo = nil"), true,
                "采纳撤销: 采纳回声到点只收自己那一笔,不把之后「重新自动匹配」挂上的撤销提前收掉")
    expectEqual(LyricsEditUndo.engineErrorCodes.map { LyricsEditUndo.isRefusal(code: $0) }
                + [LyricsEditUndo.isRefusal(code: nil), LyricsEditUndo.isRefusal(code: "io")], [true, true, false, false],
                "采纳撤销: 只有引擎的两个拒绝码算「按规矩拒了」")
    expectEqual(sourceHas(sourceBody("private func commit(_ op: String, _ fields: [String: Any] = [:]) async -> EnrichEditChannel.Result", in: store),
                          "} else if LyricsEditUndo.isRefusal(code: result.errorCode) {"), true,
                "采纳撤销: 撤销被拒(过时限、又被改过)时歌词管理不挂「写入本地记录文件失败」,原因只由回声说")
    expectEqual(sourceHas(edit, "Undoable bool   `json:\"undoable,omitempty\"`")
                && sourceHas(edit, "UndoID   string `json:\"undo_id,omitempty\"`")
                && sourceHas(edit, "UndoID string `json:\"undo_id,omitempty\"`")
                && sourceHas(edit, "case \"undo_edit\":")
                && sourceHas(channel, "undoID: (obj[\"undo_id\"] as? String)")
                && sourceHas(store, "if undoable { fields[\"undoable\"] = true }")
                && sourceHas(store, "await commit(\"undo_edit\", [\"undo_id\": undoID])"), true,
                "采纳撤销: undoable / undo_id / undo_edit 两边的键对得上")

    // 文案都在 catalog 里。
    let catalog = (try? Data(contentsOf: root.deletingLastPathComponent().appendingPathComponent("Localization/Localizable.xcstrings"))) ?? Data()
    let keys = LyricsEditUndo.engineErrorCodes.compactMap { LyricsEditUndo.reasonKey(code: $0) }
        + [LyricsEditUndo.fallbackKey, LyricsEditUndo.reasonFormatKey, "撤销", "已撤销", "快捷键：⌘Z",
           "已保存", "已标为纯音乐", "已取消纯音乐标记", "已标为纯音乐 %@ 首", LyricsEditUndo.batchChangedKey]
    let missing = keys.filter { catalog.range(of: Data("\"\($0)\" : {".utf8)) == nil }
    expectEqual(missing, [], "采纳撤销: 文案都在 Localizable.xcstrings 里")

    // 接线:接了撤销的入口都带 undoable;撤销经 undoEdit。
    expectEqual(quick.components(separatedBy: "undoable: true").count - 1, 2,
                "采纳撤销: 搜索窗口的 saveEdit、savePlainTextEdit 都带 undoable")
    expectEqual(sourceHas(quick, "return LyricsSearchSheet.ApplyOutcome(saved: result.ok, undoID: result.undoID)")
                && sourceHas(quick, "} onUndo: { undoID in")
                && sourceHas(quick, "let result = await EnrichCacheStore.shared.undoEdit(undoID: undoID)"), true,
                "采纳撤销: 宿主把 undo_id 交给面板,撤销经 EnrichCacheStore.undoEdit")
    let appDir = root.appendingPathComponent("lyrimuse")
    // 每个文件带 undoable 的调用处数目:歌词管理是保存修改、单首标 / 撤纯音乐、多选「全部标为纯音乐」三处。
    var undoableCallers: [String: Int] = [:]
    if let walker = FileManager.default.enumerator(atPath: appDir.path) {
        for case let rel as String in walker where rel.hasSuffix(".swift") && rel != "LyricsManager/EnrichCacheStore.swift" {
            let text = (try? String(contentsOf: appDir.appendingPathComponent(rel), encoding: .utf8)) ?? ""
            if sourceBytes(text, contain: "undoable: true") { undoableCallers[rel] = text.components(separatedBy: "undoable: true").count - 1 }
        }
    }
    expectEqual(undoableCallers, ["LyricsManager/LyricsExternalEditor.swift": 3, "LyricsManager/LyricsManagerView.swift": 3,
                                  "LyricsManager/LyricsQuickSearchWindow.swift": 2],
                "采纳撤销: 接了撤销的入口就这几处(再接别的入口,先在 11 章那几条决策里登记)")
    expectEqual(sourceHas(manager, "store.saveEdit(key: key, lyrics: lyrics, tr: tr, roma: roma, yrc: yrc, undoable: true)")
                && sourceHas(manager, "store.setInstrumental(key: key, value, undoable: true)")
                && !manager.contains("store.setInstrumental(key: summary.key")
                && sourceHas(store, "func setInstrumental(key: String, _ value: Bool, undoable: Bool) async -> EnrichEditChannel.Result")
                && sourceHas(store, "if undoable { fields[\"undoable\"] = true }\n return await commit(\"set_instrumental\", fields)"), true,
                "详情页撤销: 保存修改、标 / 撤纯音乐(按钮、「⋯」、右键)都经带 undoable 的那条路")

    // 多选「全部标为纯音乐」:一次请求带 undoable,一笔一个 undo_id;回声在面板按钮行下面,只认标的那一批选中。
    let mark = sourceBody("private func markInstrumental(_ keys: [String]) {", in: manager)
    expectEqual(sourceHas(mark, "let result = await store.setInstrumental(keys: keys, true, undoable: true)")
                && sourceHas(mark, "guard result.ok, let id = result.undoID, selectedKeys == selection else { return }")
                && sourceHas(mark, "text: String(format: L10n.plural(\"已标为纯音乐 %@ 首\", count: keys.count), keys.count.formatted()),\n undoID: id)")
                && sourceHas(store, "func setInstrumental(keys: [String], _ value: Bool, undoable: Bool) async -> EnrichEditChannel.Result")
                && sourceHas(store, "if undoable { fields[\"undoable\"] = true }\n return await commit(\"set_instrumental\", fields)\n }\n\n /// 一条记录"),
                true, "多选撤销: 「全部标为纯音乐」(面板按钮、列表右键)带 undoable 一次写回,回声写首数")
    let panel = sourceBody("private var batchSelectionPanel: some View {", in: manager)
    expectEqual(sourceHas(panel, ".controlSize(.large)\n .padding(.top, 22)\n batchEchoRow\n Divider().padding(.top, 22)")
                && sourceHas(sourceBody("private var batchEchoRow: some View {", in: manager),
                             "if let echo = batchEcho, echo.selection == selectedKeys {")
                && sourceHas(sourceBody("private var batchEchoRow: some View {", in: manager),
                             "if batchUndoID != nil {\n LyricsEditUndoButton(disabled: batchUndoing || markingInstrumental) {"),
                true, "多选撤销: 回声挂在面板按钮行下面,选中还是标的那一批时才显示,「撤销」用共用那颗")
    let batchUndo = sourceBody("private func undoBatchInstrumental() async {", in: manager)
    expectEqual(sourceHas(batchUndo, "let result = await store.undoEdit(undoID: id)")
                && sourceHas(batchUndo, "guard batchUndoID == id else { return }")
                && sourceHas(batchUndo, "showBatchEcho(selection: selection, text: LyricsEditUndo.failureText(result, batch: true), ok: false)")
                && sourceHas(batchUndo, "showBatchEcho(selection: selection, text: L10n.t(\"已撤销\"))"),
                true, "多选撤销: 成功说「已撤销」,整笔被拒说其中有歌曲改过(不说「这首」)")
    let batchShow = sourceBody("private func showBatchEcho(", in: manager)
    expectEqual(sourceHas(batchShow, "try? await Task.sleep(for: .seconds(undoID != nil ? LyricsEditUndo.offerSeconds : 2.5))")
                && sourceHas(batchShow, "guard generation == batchEchoGeneration, !batchUndoing else { return }")
                && sourceHas(sourceBody(".onChange(of: selectedKeys) { _, keys in", in: manager),
                             "if let echo = batchEcho, echo.selection != keys { dropBatchEcho() }")
                && sourceHas(manager, "// 关窗之后不能再撤。\n dropDetailEcho()\n dropBatchEcho()"),
                true, "多选撤销: 「撤销」停 offerSeconds,选中变了、关窗作废")
    expectEqual(LyricsEditUndo.failure(code: "undo_changed", localizedReason: nil, batch: true), .key(LyricsEditUndo.batchChangedKey),
                "多选撤销: 整笔被拒时说其中有歌曲改过")
    expectEqual(LyricsEditUndo.failure(code: "undo_expired", localizedReason: nil, batch: true), .key("无法撤销：已超过撤销时限"),
                "多选撤销: 过期那句跟单首一样")
    expectEqual(sourceHas(button, "static func failureText(_ result: EnrichEditChannel.Result, batch: Bool = false) -> String {")
                && sourceHas(button, "failure(code: result.errorCode, localizedReason: result.errorIsLocalized ? result.error : nil, batch: batch)"),
                true, "多选撤销: 失败那句按是不是多选那一笔取")

    // 「撤销」按钮:玻璃小按钮、⌘Z(只在它出着时占),各处共用这一颗。
    expectEqual(sourceHas(button, "Button(L10n.t(\"撤销\"), action: action)")
                && sourceHas(button, ".settingsGlassButtons()")
                && sourceHas(button, ".keyboardShortcut(\"z\", modifiers: .command)\n .help(L10n.t(\"快捷键：⌘Z\"))"), true,
                "撤销按钮: 玻璃按钮、⌘Z、悬停说快捷键")

    // 面板:回声带「撤销」、停 offerSeconds、换歌 / 关窗 / 别的回声顶掉都作废;成功摆回采纳之前,失败说原因。
    let feedback = sourceBody("private var applyFeedbackView: some View {", in: sheet)
    expectEqual(sourceHas(feedback, "if applyFeedback.undoable, let pending = pendingUndo, !pending.autoMatch {\n LyricsEditUndoButton(disabled: undoing || applyingSource != nil || autoMatching) {"),
                true, "采纳撤销: 回声上的「撤销」用共用那颗,撤销 / 采纳 / 自动匹配在飞时置灰")
    let show = sourceBody("private func showApplyFeedback(_ text: String, ok: Bool, undoable: Bool = false) {", in: sheet)
    expectEqual(sourceHas(show, "if !undoable { pendingUndo = nil }")
                && sourceHas(show, "try? await Task.sleep(for: .seconds(undoable ? LyricsEditUndo.offerSeconds : 2.5))")
                && sourceHas(show, "if pendingUndo?.id == ownUndo { pendingUndo = nil }\n withAnimation { applyFeedback = nil }"), true,
                "采纳撤销: 带「撤销」的回声停 offerSeconds,消失或被别的回声顶掉时撤销作废")
    let subjectChange = sourceBody(".onChange(of: searchSubject) { _, _ in", in: sheet)
    let disappear = sourceBody(".onDisappear {", in: sheet)
    expectEqual(subjectChange.contains("pendingUndo = nil") && disappear.contains("pendingUndo = nil"), true,
                "采纳撤销: 换歌、关窗之后不能再撤")
    let undo = sourceBody("private func undoApply() async {", in: sheet)
    expectEqual(sourceHas(undo, "guard let pending = pendingUndo, !undoing, applyingSource == nil, !autoMatching else { return }")
                && sourceHas(undo, "guard subject == subjectGeneration else { return }")
                && sourceHas(undo, "showApplyFeedback(LyricsEditUndo.failureText(result), ok: false)")
                && sourceHas(undo, "if pending.autoMatch { autoMatchLine = nil }")
                && sourceHas(undo, "appliedSource = pending.appliedSource")
                && sourceHas(undo, "instrumentalOverride = pending.instrumentalOverride")
                && sourceHas(undo, "showApplyFeedback(L10n.t(\"已撤销\"), ok: true)"), true,
                "采纳撤销: 撤销成功摆回采纳之前的「当前使用」和纯音乐标记,失败说原因,等待期间换了歌不动面板")
    let apply = sourceBody("private func apply(_ c: LyricsSearchService.Candidate) async {", in: sheet)
    let baseline = sourceBody("private var undoBaseline: PendingUndo {", in: sheet)
    expectEqual(sourceHas(baseline, "PendingUndo(id: \"\", appliedSource: effectiveCurrentSource ?? \"\", appliedFingerprint: effectiveCurrentFingerprint,\n appliedPick: effectiveCurrentPick,")
                && sourceHas(apply, "var before = undoBaseline"),
                true, "采纳撤销: 记的是采纳之前实际显示的「当前使用」,撤销后不等宿主重读缓存")
    expectEqual(sourceHas(apply, "showApplyFeedback(String(format: L10n.t(\"已采用 %@ 的歌词\"), name), ok: true, undoable: outcome.undoID != nil)"),
                true, "采纳撤销: 引擎给了 undo_id 才出「撤销」")

    // 失败原因:错误码优先,其次通道给的本地化原因,最后通用那句。
    expectEqual(LyricsEditUndo.failure(code: "undo_changed", localizedReason: "x"), .key("无法撤销：这首歌曲的歌词已有其他改动"),
                "采纳撤销: 动过时说已有其他改动")
    expectEqual(LyricsEditUndo.failure(code: "undo_expired", localizedReason: nil), .key("无法撤销：已超过撤销时限"),
                "采纳撤销: 过期时说超过时限")
    expectEqual(LyricsEditUndo.failure(code: nil, localizedReason: "歌词引擎无响应"), .format("无法撤销：%@", reason: "歌词引擎无响应"),
                "采纳撤销: 引擎没响应时带上通道的原因")
    expectEqual(LyricsEditUndo.failure(code: nil, localizedReason: nil), .key("无法撤销，请重试"),
                "采纳撤销: 引擎的英文内部错误不原样给人看")
    expectEqual(sourceHas(button, "failure(code: result.errorCode, localizedReason: result.errorIsLocalized ? result.error : nil, batch: batch)"),
                true, "采纳撤销: 按引擎错误码、通道的本地化原因取那一句")

    // 重新自动匹配:引擎结论里的 undoID 跟 App 的键对得上,按请求 id 取。
    expectEqual(sourceHas(rematchEngine, "UndoID string `json:\"undoID,omitempty\"`"), true, "重新匹配撤销: 引擎结论带 undoID")
    let finished = #"{"id":"r1","key":"k","running":false,"startedAt":1,"updatedAt":2,"result":{"outcome":"changed","undoID":"u1"}}"#
    let status = try? JSONDecoder().decode(LyricsRematch.Status.self, from: Data(finished.utf8))
    expectEqual(LyricsRematch.undoID(of: status, id: "r1"), "u1", "重新匹配撤销: 跑完的这一轮取得到 undo_id")
    expectEqual(LyricsRematch.undoID(of: status, id: "r2"), nil, "重新匹配撤销: 别的一轮的不认")
    let running = LyricsRematch.Status(id: "r1", key: "k", running: true, startedAt: 1, updatedAt: 2,
                                       result: LyricsRematch.Conclusion(outcome: "changed", undoID: "u1"))
    expectEqual(LyricsRematch.undoID(of: running, id: "r1"), nil, "重新匹配撤销: 还在跑的不认")
    let empty = LyricsRematch.Status(id: "r1", key: "k", running: false, startedAt: 1, updatedAt: 2,
                                     result: LyricsRematch.Conclusion(outcome: "changed", undoID: ""))
    expectEqual(LyricsRematch.undoID(of: empty, id: "r1"), nil, "重新匹配撤销: 空串当没给")
    expectEqual(sourceHas(quick, "return LyricsSearchSheet.AutoMatchOutcome(line: line, undoID: LyricsRematch.undoID(of: LyricsRematch.current, id: id))")
                && sourceHas(sourceBody("private func runRematch(key: String) async {", in: manager),
                             "if let undoID = LyricsRematch.undoID(of: LyricsRematch.current, id: id) { offerRematchUndo(key: key, undoID: undoID) }")
                && sourceHas(actions, "let undo = LyricsRematch.undoID(of: LyricsRematch.current, id: id).map { LyricsWindowActionNotes.Undo(id: $0) }"),
                true, "重新匹配撤销: 搜索窗口、歌词管理详情页、歌词窗口三处按自己那一轮的请求 id 取 undo_id")
    let autoMatch = sourceBody("private func runAutoMatch() async {", in: sheet)
    let autoStatus = sourceBody("private var autoMatchStatus: some View {", in: sheet)
    expectEqual(sourceHas(autoMatch, "before.autoMatch = true\n pendingUndo = before")
                && sourceHas(autoMatch, "try? await Task.sleep(for: .seconds(LyricsEditUndo.offerSeconds))\n if pendingUndo?.id == id, !undoing { pendingUndo = nil }")
                && sourceHas(autoStatus, "if pendingUndo?.autoMatch == true {\n LyricsEditUndoButton("), true,
                "重新匹配撤销: 搜索窗口结论旁的「撤销」停 offerSeconds,结论照留")

    // 歌词管理详情页:那一行的回声带「撤销」;换歌、关窗、进编辑、别的回声都作废;成功重载编辑框,失败说原因,保存时搬过的偏移搬回去。
    let echo = sourceBody("private func showDetailEcho(", in: manager)
    expectEqual(sourceHas(echo, "try? await Task.sleep(for: .seconds(undoID != nil ? LyricsEditUndo.offerSeconds : 2.5))")
                && sourceHas(echo, "rematchResult = nil"), true, "详情页撤销: 带「撤销」的回声停 offerSeconds,顶掉重新匹配的结论")
    expectEqual(sourceHas(sourceBody(".onChange(of: key) { _, newKey in", in: manager), "dropDetailEcho()")
                && sourceHas(manager, ".onChange(of: editMode) { _, mode in\n if mode != .preview { detailUndo = nil }\n }")
                && sourceHas(manager, "// 关窗之后不能再撤。\n dropDetailEcho()")
                && sourceHas(sourceBody("private func finishRematch(key: String, line: LyricsRematch.Line) {", in: manager), "dropDetailEcho()")
                && sourceHas(sourceBody("private func detailUndoButton(key: String) -> some View {", in: manager),
                             "if let undo = detailUndo, undo.key == key, editMode == .preview {"), true,
                "详情页撤销: 换歌、关窗、进编辑、新的结论都作废,编辑时不占 ⌘Z")
    let detailUndo = sourceBody("private func undoDetailEdit() async {", in: manager)
    expectEqual(sourceHas(detailUndo, "let result = await store.undoEdit(undoID: pending.id)")
                && sourceHas(detailUndo, "LyricsOffsetStore.shared.carryOffset(from: carried.to, to: carried.from, pinKey: pending.key,")
                && sourceHas(detailUndo, "guard detailUndo?.id == pending.id else { return }")
                && sourceHas(detailUndo, "showDetailEcho(key: pending.key, text: LyricsEditUndo.failureText(result), ok: false)")
                && sourceHas(detailUndo, "showDetailEcho(key: pending.key, text: L10n.t(\"已撤销\"))")
                && sourceHas(sourceBody("private func saveEdits(key: String, summary: EnrichCacheStore.Summary) async -> Bool {", in: manager),
                             "showDetailEcho(key: key, text: L10n.t(\"已保存\"), undoID: id, carried: carried)"), true,
                "详情页撤销: 保存修改之后给「撤销」,撤销经 undoEdit、搬回偏移、成败各说一句,等待期间换了歌不动这一页")

    // 歌词窗口说明条:外部编辑器存回、重新匹配的回执带「撤销」;别的一句顶掉、换歌、关窗作废。
    let post = sourceBody("func post(title: String, text: String, symbol: String, tint: Color, seconds: Double, undo: Undo? = nil) {", in: actions)
    expectEqual(sourceHas(post, "self.undo = undo")
                && sourceHas(post, "let shown = undo == nil ? seconds : max(seconds, LyricsEditUndo.offerSeconds)")
                && sourceHas(actions, "if notes.undo != nil {\n LyricsEditUndoButton(disabled: notes.undoing || rematch.round != nil) {")
                && sourceHas(actions, ".onChange(of: currentTitle) { _, _ in notes.dropUndo() }")
                && sourceHas(windowView, "if !handoff { LyricsWindowActionNotes.shared.dropUndo() }")
                && sourceHas(sourceBody("func performUndo() async {", in: actions), "let result = await EnrichCacheStore.shared.undoEdit(undoID: undo.id)")
                && sourceHas(external, "notes.post(.success, title: session.title, text: done.joined(separator: \"\\n\"), undo: undo)"), true,
                "说明条撤销: 回执带「撤销」、停 offerSeconds,换歌、关窗作废,撤销经 undoEdit")
}
