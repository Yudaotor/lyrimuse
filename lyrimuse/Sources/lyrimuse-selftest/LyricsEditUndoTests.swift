import Foundation
import LyrimuseCore

/// 「搜索歌词…」采纳之后的撤销(11 章决策 177)。lyrics-manager 组开头调。
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

    // 跟引擎对拍:时限、错误码、请求和结果的键。
    expectEqual(sourceHas(engine, "enrichUndoTTL = \(Int(LyricsEditUndo.engineTTLSeconds)) * time.Second")
                && LyricsEditUndo.offerSeconds < LyricsEditUndo.engineTTLSeconds, true,
                "采纳撤销: 引擎认 undo_id 的时限跟 App 记的一致,「撤销」按钮比它早消失")
    for code in LyricsEditUndo.engineErrorCodes {
        expectEqual(engine.contains("= \"\(code)\""), true, "采纳撤销: 引擎有错误码 \(code)")
        expectEqual(LyricsEditUndo.reasonKey(code: code) != nil, true, "采纳撤销: 错误码 \(code) 有对应的一句")
    }
    expectEqual(LyricsEditUndo.reasonKey(code: nil), nil, "采纳撤销: 没有错误码时交给通道的原因或通用那句")
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
        + [LyricsEditUndo.fallbackKey, LyricsEditUndo.reasonFormatKey, "撤销", "已撤销", "快捷键：⌘Z"]
    let missing = keys.filter { catalog.range(of: Data("\"\($0)\" : {".utf8)) == nil }
    expectEqual(missing, [], "采纳撤销: 文案都在 Localizable.xcstrings 里")

    // 接线:只有「搜索歌词…」这一个入口带 undoable,两条采纳路都带;撤销经 undoEdit。
    expectEqual(quick.components(separatedBy: "undoable: true").count - 1, 2,
                "采纳撤销: 搜索窗口的 saveEdit、savePlainTextEdit 都带 undoable")
    expectEqual(sourceHas(quick, "return LyricsSearchSheet.ApplyOutcome(saved: result.ok, undoID: result.undoID)")
                && sourceHas(quick, "} onUndo: { undoID in")
                && sourceHas(quick, "let result = await EnrichCacheStore.shared.undoEdit(undoID: undoID)"), true,
                "采纳撤销: 宿主把 undo_id 交给面板,撤销经 EnrichCacheStore.undoEdit")
    let appDir = root.appendingPathComponent("lyrimuse")
    var undoableCallers: [String] = []
    if let walker = FileManager.default.enumerator(atPath: appDir.path) {
        for case let rel as String in walker where rel.hasSuffix(".swift") && rel != "LyricsManager/EnrichCacheStore.swift" {
            let text = (try? String(contentsOf: appDir.appendingPathComponent(rel), encoding: .utf8)) ?? ""
            if sourceBytes(text, contain: "undoable: true") { undoableCallers.append(rel) }
        }
    }
    expectEqual(undoableCallers, ["LyricsManager/LyricsQuickSearchWindow.swift"],
                "采纳撤销: 只接了搜索窗口这一个入口(别的入口要接,先在 11 章那条决策里登记)")

    // 面板:回声带「撤销」(玻璃按钮)、停 offerSeconds、换歌 / 关窗 / 别的回声顶掉都作废;成功摆回采纳之前,失败说原因。
    let feedback = sourceBody("private var applyFeedbackView: some View {", in: sheet)
    expectEqual(sourceHas(feedback, "if applyFeedback.undoable, pendingUndo != nil {\n Button(L10n.t(\"撤销\")) {")
                && sourceHas(feedback, ".settingsGlassButtons()")
                && sourceHas(feedback, ".keyboardShortcut(\"z\", modifiers: .command)\n .help(L10n.t(\"快捷键：⌘Z\"))")
                && sourceHas(feedback, ".disabled(undoing || applyingSource != nil || autoMatching)"), true,
                "采纳撤销: 回声上的「撤销」是玻璃按钮、⌘Z,撤销 / 采纳 / 自动匹配在飞时置灰")
    let show = sourceBody("private func showApplyFeedback(_ text: String, ok: Bool, undoable: Bool = false) {", in: sheet)
    expectEqual(sourceHas(show, "if !undoable { pendingUndo = nil }")
                && sourceHas(show, "try? await Task.sleep(for: .seconds(undoable ? LyricsEditUndo.offerSeconds : 2.5))")
                && sourceHas(show, "pendingUndo = nil\n withAnimation { applyFeedback = nil }"), true,
                "采纳撤销: 带「撤销」的回声停 offerSeconds,消失或被别的回声顶掉时撤销作废")
    let subjectChange = sourceBody(".onChange(of: searchSubject) { _, _ in", in: sheet)
    let disappear = sourceBody(".onDisappear {", in: sheet)
    expectEqual(subjectChange.contains("pendingUndo = nil") && disappear.contains("pendingUndo = nil"), true,
                "采纳撤销: 换歌、关窗之后不能再撤")
    let undo = sourceBody("private func undoApply() async {", in: sheet)
    expectEqual(sourceHas(undo, "guard let pending = pendingUndo, !undoing, applyingSource == nil, !autoMatching else { return }")
                && sourceHas(undo, "guard subject == subjectGeneration else { return }")
                && sourceHas(undo, "showApplyFeedback(Self.undoFailureText(result), ok: false)")
                && sourceHas(undo, "appliedSource = pending.appliedSource")
                && sourceHas(undo, "instrumentalOverride = pending.instrumentalOverride")
                && sourceHas(undo, "showApplyFeedback(L10n.t(\"已撤销\"), ok: true)"), true,
                "采纳撤销: 撤销成功摆回采纳之前的「当前使用」和纯音乐标记,失败说原因,等待期间换了歌不动面板")
    let apply = sourceBody("private func apply(_ c: LyricsSearchService.Candidate) async {", in: sheet)
    expectEqual(sourceHas(apply, "let before = PendingUndo(id: \"\", appliedSource: effectiveCurrentSource ?? \"\", appliedFingerprint: effectiveCurrentFingerprint,\n appliedPick: effectiveCurrentPick,"),
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
    expectEqual(sourceHas(sheet, "LyricsEditUndo.failure(code: result.errorCode, localizedReason: result.errorIsLocalized ? result.error : nil)"),
                true, "采纳撤销: 面板按引擎错误码、通道的本地化原因取那一句")
}
