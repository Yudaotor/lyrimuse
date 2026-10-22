import Foundation

/// 10-22 当日新功能审计(VOX 认文件、分享歌词)的源码契约。VOX 那几条挂在 vox 组末尾,分享那几条挂在 lyrics-window 组末尾。
func runVoxFileCacheContracts() {
    let src = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("LyrimuseCore/Local/VoxPlayerInfo.swift"), encoding: .utf8)) ?? ""
    let body = sourceBody("static func systemFile(title: String, pid: pid_t, now: Date)", in: src)
    expectEqual(sourceHas(body, "let key = \"\\(pid)|\\(title)\""), true,
                "VOX 认文件: 缓存按 VOX 进程和歌名记,不只按歌名")
    expectEqual(sourceHas(body, "let stillOpen = hit.found.map { audioPaths.contains($0.path) } ?? false")
                && sourceHas(body, "if (hit.exact && stillOpen) ||"), true,
                "VOX 认文件: 命中时核对文件还开着,只有按歌名对上的才一直用")
}

func runLyricShareContracts() {
    let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lyrimuse/UI")
    func read(_ name: String) -> String {
        (try? String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
    let share = read("LyricShareWindow.swift")
    expectEqual(sourceHas(share, ".task(id: renderKey) { rendered = (renderKey, render(snapshot)) }")
                && !sourceHas(share, "let image = render(snapshot)\nVStack(spacing: 16) {"), true,
                "分享歌词: 出图按选择和开关缓存,刷新提示文字不重画")
    expectEqual(sourceHas(share, "feedback = NSPasteboard.general.writeObjects([image]) ? L10n.t(\"已拷贝\") : nil"), true,
                "分享歌词: 写进剪贴板了才说「已拷贝」")
    expectEqual(sourceHas(share, "let onHold = playback.isRadioTalkBreak || playback.isCurrentTrackAdBreak"), true,
                "分享歌词: 口白、广告期间不取上一首的歌词")
    expectEqual(sourceHas(read("LyricsWindowView.swift"), "if !playback.allLines.isEmpty, !lyricsOnHold {\nMoreMenuRow(title: L10n.t(\"分享歌词…\")) {"), true,
                "分享歌词: 菜单项在口白、广告期间不出现")
}
