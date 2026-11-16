import Foundation
import LyrimuseCore

func runLyricsWritebackTests() {
    let file = NowPlayingLocalFile(player: "com.example.player", path: "/Users/a/Music/x.MP3")
    expectEqual(LyricsWriteback.unavailable(isNowPlaying: true, file: file, probeError: nil), nil,
                "写回: 正在放的本地 MP3(扩展名不分大小写)能写")
    expectEqual(LyricsWriteback.unavailable(isNowPlaying: false, file: file, probeError: nil), .notPlayingLocalFile,
                "写回: 不是正在放的那首不能写")
    expectEqual(LyricsWriteback.unavailable(isNowPlaying: true, file: nil, probeError: nil), .notPlayingLocalFile,
                "写回: 没在放本地文件不能写")
    for ext in ["m4a", "OGG", "opus", "oga", "wav", "wave", "aif", "AIFF", "aifc", "flac"] {
        expectEqual(LyricsWriteback.unavailable(isNowPlaying: true, file: NowPlayingLocalFile(player: "p", path: "/a/x.\(ext)"),
                                                probeError: nil), nil, "写回: \(ext) 能写")
    }
    for ext in ["wma", "ape", "m4b", "mp4", "dsf", ""] {
        expectEqual(LyricsWriteback.unavailable(isNowPlaying: true, file: NowPlayingLocalFile(player: "p", path: "/a/x.\(ext)"),
                                                probeError: nil), .unsupportedFormat, "写回: \(ext.isEmpty ? "没有扩展名" : ext) 不支持")
    }
    expectEqual(LyricsWriteback.unavailable(isNowPlaying: true, file: file, probeError: "unsupported_tag"),
                .engine("unsupported_tag"), "写回: 引擎查文件报的错(标签格式不支持之类)灰掉菜单项")
    expectEqual(LyricsWriteback.reasonKey(.engine("unsupported_tag")), "这个文件的标签格式暂不支持写入",
                "写回: 标签格式不支持时悬停说明照实说")
    expectEqual(LyricsWriteback.wantsPlainText(player: PlaybackPlayer.appleMusic.bundleIdentifier), true,
                "写回: Apple Music 的曲目只写文字")
    expectEqual(LyricsWriteback.wantsPlainText(player: "com.reamp.reAMP"), false, "写回: 别的播放器写 LRC")

    // 跟引擎对拍:错误码、格式、Apple Music 规则都在引擎源码里,文案键都在 catalog 里。
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    func text(_ path: String) -> String {
        (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
    }
    let engine = text("lyrimuse-engine/lyricswriteback.go")
    let engineCodes = engine.split(separator: "\n").compactMap { line -> String? in
        guard line.contains("wbErr"), line.contains("= \""), let start = line.range(of: "= \"") else { return nil }
        let rest = line[start.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
    expectEqual(Set(engineCodes), Set(LyricsWriteback.engineErrorCodes), "写回: App 认的错误码跟引擎 lyricswriteback.go 一致")
    let engineFormats = Set(engine.split(separator: "\n").compactMap { line -> String? in
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("\""), t.hasSuffix("WritebackLayout,"), let end = t.dropFirst().firstIndex(of: "\"") else { return nil }
        return String(t[t.index(after: t.startIndex)..<end])
    })
    expectEqual(engineFormats, LyricsWriteback.supportedExtensions, "写回: 支持的格式两边一致(引擎 lyricsWritebackFormats)")
    expectEqual(sourceHas(engine, "return bundleID == appleMusicBundleID"), true,
                "写回: 只写文字的判据两边一致(引擎 writebackWantsPlainText)")
    let catalog = (try? Data(contentsOf: root.appendingPathComponent("lyrimuse/Localization/Localizable.xcstrings"))) ?? Data()
    var missing: [String] = []
    let keys = LyricsWriteback.engineErrorCodes.map(LyricsWriteback.errorKey(code:))
        + [LyricsWriteback.reasonKey(.notPlayingLocalFile), LyricsWriteback.reasonKey(.unsupportedFormat), LyricsWriteback.errorKey(code: "?")]
    for key in Set(keys) where catalog.range(of: Data("\"\(key)\" : {".utf8)) == nil {
        missing.append(key)
    }
    expectEqual(missing, [], "写回: 每条原因文案都在 Localizable.xcstrings 里")

    // 「覆盖其他软件写入的歌词」:App 写 features.json 的键、读回、引擎认同一个键并在自动写入里看它(11 章决策 166)。
    let store = text("lyrimuse/Sources/lyrimuse/Settings/FeatureSettingsStore.swift")
    let features = text("lyrimuse-engine/features.go")
    let autoWB = text("lyrimuse-engine/lyricsautowriteback.go")
    expectEqual(sourceHas(store, "case lyricsAutoWritebackOverwrite = \"lyrics_auto_writeback_overwrite\"")
                && sourceHas(store, "lyricsAutoWritebackOverwrite: lyricsAutoWritebackOverwrite ? true : nil,")
                && sourceHas(store, "lyricsAutoWritebackOverwrite = f.lyricsAutoWritebackOverwrite ?? false"), true,
                "写回覆盖开关: App 按 lyrics_auto_writeback_overwrite 写出(关时不写)、读回(缺失为关)")
    expectEqual(sourceHas(features, "LyricsAutoWritebackOverwrite bool `json:\"lyrics_auto_writeback_overwrite,omitempty\"`")
                && sourceHas(features, "LyricsAutoWritebackOverwrite: f.LyricsAutoWritebackOverwrite,")
                && sourceHas(autoWB, "overwrite := features().LyricsAutoWritebackOverwrite"), true,
                "写回覆盖开关: 引擎认同一个键、带进 featureFlags、自动写入时看它")
    let labs = text("lyrimuse/Sources/lyrimuse/Settings/LabsPage.swift")
    expectEqual(sourceHas(labs, """
        if features.lyricsAutoWriteback {
            CardDivider()
            SettingsSubRow(title: L10n.t("覆盖其他软件写入的歌词"), subtitle: L10n.t("替换前先备份原有歌词")) {
                Toggle("", isOn: Binding(
                    get: { features.lyricsAutoWritebackOverwrite },
                    set: { features.lyricsAutoWritebackOverwrite = $0; Task { await features.save() } }
                ))
        """) && sourceHas(labs, "withAnimation(.settingsCardReveal) { features.lyricsAutoWriteback = newValue }")
                && !labs.contains("不覆盖其他软件写入的歌词"), true,
                "写回覆盖开关: 实验室里总开关开着才出现子开关、读写同一个字段并存盘;总开关说明不再写死「不覆盖」")
    // 关确认框时绑定的 setter 先清掉 plan,按钮里排的 Task 再读 self.plan 已是 nil、什么都不写。
    let manager = text("lyrimuse/Sources/lyrimuse/LyricsManager/LyricsManagerView.swift")
    let writebackController = text("lyrimuse/Sources/lyrimuse/LyricsManager/LyricsWritebackController.swift")
    expectEqual(sourceHas(manager, "Button(plan.hasLyrics ? L10n.t(\"替换\") : L10n.t(\"写入\")) { Task { await controller.confirm(plan) } }")
                && sourceHas(writebackController, "guard let plan = confirmed ?? plan, !busy else { return }"), true,
                "写回确认框: 按钮把确认框交进来的那份传给 confirm,不读关框时已清掉的 self.plan")
}
