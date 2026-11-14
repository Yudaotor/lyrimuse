import AppKit
import LyrimuseCore
import SwiftUI

/// 歌词管理「⋯ → 写入歌曲文件…」:查文件 → 确认框 → 写 → 成功提示 / 失败框。写入本身在引擎(lyricswriteback.go),
/// 这里只经编辑通道发 probe_file_lyrics / write_file_lyrics。见 11 章决策 162、163。
@MainActor
final class LyricsWritebackController: ObservableObject {
    /// 确认框里要写的那一次。
    struct Plan: Equatable, Identifiable {
        var key: String
        var path: String
        var player: String
        var hasLyrics: Bool
        var id: String { key + "\u{0}" + path }
    }

    /// 成功提示:写进了哪个文件。
    struct Note: Equatable {
        var path: String
    }

    /// 最近查过的文件和引擎报的错误码(nil = 能写)。菜单项据此灰掉、悬停说原因。
    @Published private(set) var probedPath: String?
    @Published private(set) var probeError: String?
    @Published var plan: Plan?
    /// 失败框的正文(已本地化);nil = 没有失败框。
    @Published var failure: String?
    @Published private(set) var note: Note?
    @Published private(set) var busy = false

    /// 成功提示停留的时间。
    static let noteSeconds: Double = 5

    /// 菜单项能不能点;灰掉时交原因。
    func unavailable(isNowPlaying: Bool, file: NowPlayingLocalFile?) -> LyricsWriteback.Unavailable? {
        let error = file.flatMap { $0.path == probedPath ? probeError : nil }
        return LyricsWriteback.unavailable(isNowPlaying: isNowPlaying, file: file, probeError: error)
    }

    /// 正在放的文件换了就重查一遍(详情页显示正在放的那首时由 `.task(id:)` 调)。只查支持的格式。
    func refreshProbe(path: String?) async {
        guard let path, LyricsWriteback.supports(path: path) else {
            probedPath = nil
            probeError = nil
            return
        }
        let result = await EnrichCacheStore.shared.probeFileLyrics(path: path)
        probedPath = path
        probeError = result.ok ? nil : (result.errorCode ?? "io")
    }

    /// 点了菜单项:先查文件,能写就弹确认框,不能写弹失败框。
    func begin(key: String, file: NowPlayingLocalFile?) async {
        guard !busy, let file, LyricsWriteback.supports(path: file.path) else {
            failure = L10n.t(LyricsWriteback.reasonKey(.notPlayingLocalFile))
            return
        }
        busy = true
        defer { busy = false }
        let result = await EnrichCacheStore.shared.probeFileLyrics(path: file.path)
        probedPath = file.path
        probeError = result.ok ? nil : (result.errorCode ?? "io")
        guard result.ok else {
            failure = Self.failureText(result)
            return
        }
        plan = Plan(key: key, path: result.filePath ?? file.path, player: file.player, hasLyrics: result.fileHasLyrics)
    }

    /// 确认框的「写入 / 替换」。按钮要把确认框交进来的那份传进来:关框时绑定的 setter 先调 `cancel()` 清掉 `plan`,
    /// 按钮里排的 Task 跑起来时 `self.plan` 已是 nil。不传(调试深链)才读 `self.plan`。见 11 章决策 169。
    func confirm(_ confirmed: Plan? = nil) async {
        guard let plan = confirmed ?? plan, !busy else { return }
        self.plan = nil
        busy = true
        defer { busy = false }
        let result = await EnrichCacheStore.shared.writeFileLyrics(key: plan.key, path: plan.path, player: plan.player,
                                                                   overwrite: plan.hasLyrics)
        guard result.ok else {
            failure = Self.failureText(result)
            return
        }
        let shown = Note(path: result.filePath ?? plan.path)
        withAnimation { note = shown }
        Task {
            try? await Task.sleep(for: .seconds(Self.noteSeconds))
            if note == shown { withAnimation { note = nil } }
        }
    }

    func cancel() {
        plan = nil
    }

    func revealNoteFile() {
        guard let note else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: note.path)])
    }

    /// 确认框的正文:文件路径,原有歌词会被替换、Apple Music 只写文字时各补一句。
    static func confirmMessage(_ plan: Plan) -> String {
        var lines = [(plan.path as NSString).abbreviatingWithTildeInPath]
        if plan.hasLyrics { lines.append(L10n.t("文件中已有的歌词将被替换")) }
        if LyricsWriteback.wantsPlainText(player: plan.player) { lines.append(L10n.t("Apple Music 曲目只写入歌词文字")) }
        return lines.joined(separator: "\n\n")
    }

    /// 失败框正文:原因一句 + 「原文件没有改动」。引擎没给错误码(超时、引擎没响应)时用通道给的那句。
    static func failureText(_ result: EnrichEditChannel.Result) -> String {
        let reason: String
        if let code = result.errorCode {
            reason = L10n.t(LyricsWriteback.errorKey(code: code))
        } else if result.errorIsLocalized, let error = result.error {
            reason = error
        } else {
            reason = L10n.t("写入失败")
        }
        return reason + "\n" + L10n.t("原文件没有改动")
    }
}
