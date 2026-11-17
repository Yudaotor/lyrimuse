import Foundation
import LyrimuseCore

/// 悬浮歌词「无歌词时显示歌名」(04 章决策 104):判据、设置读写、主行分支的位置、设置行。
func checkOverlayNoLyricsTitle() {
    print("\n== 悬浮歌词无歌词时显示歌名 ==")
    typealias T = OverlayNoLyricsTitle
    func text(_ on: Bool = true, instrumental: Bool = false, noLyrics: Bool = false,
              title: String = "晴天", artist: String = "周杰伦") -> String? {
        T.text(enabled: on, isInstrumental: instrumental, hasNoLyrics: noLyrics, title: title, artist: artist)
    }
    expectEqual(text(instrumental: true), "晴天 — 周杰伦", "无歌词时显示歌名: 纯音乐换成「歌名 — 歌手」")
    expectEqual(text(noLyrics: true), "晴天 — 周杰伦", "无歌词时显示歌名: 搜完确认没有(含只有纯文本)换成歌名")
    expectEqual(text(), nil, "无歌词时显示歌名: 有词或还在搜(没有结论)不换")
    expectEqual(text(false, noLyrics: true), nil, "无歌词时显示歌名: 开关关着照旧写状态字")
    expectEqual(text(noLyrics: true, artist: "  "), "晴天", "无歌词时显示歌名: 没歌手只写歌名")
    expectEqual(text(noLyrics: true, title: " ", artist: "周杰伦"), nil, "无歌词时显示歌名: 没歌名不换")
    expectEqual(text(noLyrics: true, title: " 晴天 ", artist: " 周杰伦"), "晴天 — 周杰伦", "无歌词时显示歌名: 首尾空白去掉")

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let view = source("lyrimuse/UI/LyricsOverlayView.swift")
    let rows = source("lyrimuse/UI/OverlayBehaviorSettingsRows.swift")
    let appSettings = source("lyrimuse/Settings/AppSettings.swift")
    let debugLinks = source("lyrimuse/Settings/DebugDeepLinks.swift")

    expectEqual(sourceHas(appSettings, "static let overlayShowsTitleWhenNoLyrics = \"np:overlayShowsTitleWhenNoLyrics\"")
                && sourceHas(appSettings, "static let defaultOverlayShowsTitleWhenNoLyrics = true")
                && sourceHas(appSettings, "overlayShowsTitleWhenNoLyrics = (defaults.object(forKey: Keys.overlayShowsTitleWhenNoLyrics) as? Bool)\n ?? Self.defaultOverlayShowsTitleWhenNoLyrics")
                && sourceHas(appSettings, "didSet { defaults.set(overlayShowsTitleWhenNoLyrics, forKey: Keys.overlayShowsTitleWhenNoLyrics) }"),
                true, "无歌词时显示歌名: 自己一个 np: 键,默认开(同菜单栏那颗),改了就写回")
    expectEqual(sourceHas(view, "Publishers.CombineLatest4(s.$overlayShowsTitleWhenNoLyrics, p.$isCurrentTrackInstrumental,\n p.$currentTrackHasNoLyrics, Publishers.CombineLatest(p.$displayTitle, p.$displayArtist))")
                && sourceHas(view, "OverlayNoLyricsTitle.text(enabled: enabled, isInstrumental: instrumental, hasNoLyrics: noLyrics,\n title: track.0, artist: track.1)"),
                true, "无歌词时显示歌名: 代理里五个输入同时从 sink 参数拿,用界面上显示的歌名、歌手")
    // 分支顺序:广告、口白之后,纯音乐、暂无歌词之前;「搜索歌词中…」那几支不动。
    let mainLine = sourceBody("private var mainLine: some View {", in: view)
    func at(_ marker: String) -> Int {
        mainLine.range(of: marker).map { mainLine.distance(from: mainLine.startIndex, to: $0.lowerBound) } ?? -1
    }
    let ad = at("} else if playback.isCurrentTrackAdBreak {"), talk = at("} else if playback.isRadioTalkBreak {")
    let title = at("} else if let name = playback.noLyricsTitle {")
    let instrumental = at("} else if playback.isCurrentTrackInstrumental {"), noLyrics = at("} else if playback.currentTrackHasNoLyrics {")
    expectEqual(ad >= 0 && talk > ad && title > talk && instrumental > title && noLyrics > instrumental, true,
                "无歌词时显示歌名: 主行那一支排在广告、口白后,纯音乐、暂无歌词前")
    expectEqual(sourceHas(mainLine, "(Text(Image(systemName: \"music.note\")) + Text(verbatim: \" \" + name))"), true,
                "无歌词时显示歌名: 前面画一个音符,歌名不走本地化")
    expectEqual(sourceHas(rows, "case .showsTitleWhenNoLyrics: return !AppSettings.shared.hideWhenNoLyrics")
                && sourceHas(rows, "var isAutoHide: Bool { self == .hideInFullScreen || self == .showsTitleWhenNoLyrics }")
                && sourceHas(rows, "case .showsTitleWhenNoLyrics:\n return Binding(get: { settings.overlayShowsTitleWhenNoLyrics },\n set: { settings.overlayShowsTitleWhenNoLyrics = $0 })"),
                true, "无歌词时显示歌名: 设置行在「行为」自动隐藏那一格,「纯音乐/无歌词时隐藏」开着时置灰")
    expectEqual(sourceHas(debugLinks, "if let overlay { AppSettings.shared.overlayShowsTitleWhenNoLyrics = overlay }"), true,
                "无歌词时显示歌名: debug 深链写同一个设置")
    expectEqual(SettingsSearchCatalog.entries.contains { $0.sectionValue == "overlay" && $0.titleKey == "无歌词时显示歌名" }, true,
                "无歌词时显示歌名: 设置搜索能搜到悬浮歌词那一行")
}
