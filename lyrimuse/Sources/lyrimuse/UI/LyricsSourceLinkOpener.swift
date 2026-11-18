import AppKit
import LyrimuseCore
import os

/// 打开歌词来源处的链接(`LyricsSourceLink`):歌词窗口简介的「来源」行、歌词管理详情的来源胶囊共用。用默认浏览器打开;
/// 本机验证时 `debug/hold-opens` 开着就只记下要打开的地址(`debug/state` 的 `heldOpens`),不弹浏览器。
@MainActor
enum LyricsSourceLinkOpener {
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "lyrics-source-link")

    static func open(_ url: URL) {
        if DebugExternalOpens.holding {
            DebugExternalOpens.held.append(url.absoluteString)
            logger.notice("lyrics source link held \(url.absoluteString, privacy: .public)")
            return
        }
        logger.notice("lyrics source link open \(url.absoluteString, privacy: .public)")
        NSWorkspace.shared.open(url)
    }

    /// 悬停提示:「在 Megalobiz 上查看这首歌的歌词」。
    static func help(source: String) -> String {
        String(format: L10n.t("在 %@ 上查看这首歌的歌词"), sourceDisplayName(source))
    }
}
