import Foundation
import os

/// 把字幕装在系统会话歌手栏里的播放器(听书,`PlaybackPlayer.subtitlesInArtist`,目前只有微信读书)。
///
/// 这类播放器每换一段就带着新锚点把那段原文发成 artist,锚点就是这段的起点;没有作者一栏。这里在快照进来的第一层
/// (`MediaControlClient.fetchSnapshotWithProvenance`)把那一栏收成一句字幕,快照上的歌手换成书名(专辑),
/// 身份、缓存 key、播放状态都不随字幕变。收到的字幕按起点排成一份 LRC,`LocalPlaybackSource.reloadCurrentLyrics`
/// 拿它当这一集的歌词;没收到的后文显示不了,屏上停在最近一句,下一句到了再换。
public enum PlayerSubtitles {
    public struct Line: Equatable, Sendable {
        public let ms: Int
        public let text: String
        public init(ms: Int, text: String) {
            self.ms = ms
            self.text = text
        }
    }

    /// 一集最多留这么多句,多了丢最早的(一章二十几分钟、每段三四秒,约四百句)。
    public static let maxLines = 4000
    /// 新来的一句跟已有一句起点相差不超过这么多,算同一句重发(真人有声书的锚点按 0.25 秒取整),换成新的。
    public static let sameLineToleranceMs = 300

    private struct Store {
        var key = ""
        var lines: [Line] = []
        var revision = 0
    }

    private static let store = OSAllocatedUnfairLock<Store>(initialState: Store())

    /// 这个播放器的歌手栏是不是字幕。
    public static func carriesSubtitles(bundleID: String?) -> Bool {
        PlaybackPlayer.builtin(forBundleID: bundleID)?.subtitlesInArtist == true
    }

    /// 这一集的身份:书名(专辑)+ 集名。
    public static func trackKey(album: String?, title: String?) -> String {
        "\(album ?? "")|\(title ?? "")"
    }

    /// 快照进来的第一层:是字幕播放器就记下这一句、把歌手换成书名;别家原样返回。在轮询的后台线程上调。
    public static func adapted(_ snapshot: MediaControlSnapshot?) -> MediaControlSnapshot? {
        guard let snapshot, carriesSubtitles(bundleID: snapshot.bundleIdentifier) else { return snapshot }
        let book = snapshot.album ?? ""
        if let at = snapshot.anchorElapsedTime ?? snapshot.elapsedTime, at.isFinite, at >= 0 {
            record(key: trackKey(album: snapshot.album, title: snapshot.title),
                   text: snapshot.artist ?? "", ms: Int((at * 1000).rounded()))
        }
        return snapshot.withArtist(book)
    }

    /// 记下一句。换了一集就从头记。
    static func record(key: String, text: String, ms: Int) {
        store.withLock { s in
            if s.key != key {
                s.key = key
                s.lines = []
                s.revision &+= 1
            }
            let next = recorded(s.lines, text: text, ms: ms)
            if next != s.lines {
                s.lines = next
                s.revision &+= 1
            }
        }
    }

    /// 字幕每变一次加一,轮询收尾比对它决定要不要重载歌词。
    public static var revision: Int { store.withLock { $0.revision } }

    /// 这一集收到的字幕;不是这一集(或还没收到)为空。
    public static func lines(forKey key: String) -> [Line] {
        store.withLock { $0.key == key ? $0.lines : [] }
    }

    /// 字幕播放器这一集的歌词(收到的字幕拼成的 LRC);不是字幕播放器为 nil。还没收到一句时歌词为空、按没解析完交出去。
    public static func lyrics(bundleID: String?, album: String?, title: String?) -> EnrichCacheLyrics? {
        guard carriesSubtitles(bundleID: bundleID) else { return nil }
        let lines = lines(forKey: trackKey(album: album, title: title))
        return EnrichCacheLyrics(
            lyrics: lrc(lines), lyricsTr: "", lyricsRoma: "", lyricsYRC: "", lyricsBG: "",
            songwriters: [], speakers: nil, playerVersions: [:], kanaDonor: "",
            instrumental: false, resolved: !lines.isEmpty, isCantonese: false, isHokkien: false,
            plainLyrics: "", searchIncomplete: false, storedLyrics: "")
    }

    /// 把一句并进已有的字幕(纯函数,selftest 覆盖):空的不记;跟那一刻正在显示的那句一样(暂停、恢复时原样重发)不记;
    /// 起点跟已有一句挨得很近的换掉那一句;其余按起点插进去。超过 `maxLines` 丢最早的。
    public static func recorded(_ lines: [Line], text raw: String, ms: Int) -> [Line] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, ms >= 0 else { return lines }
        var out = lines
        if let near = out.firstIndex(where: { abs($0.ms - ms) <= sameLineToleranceMs }) {
            if out[near].text == text { return lines }
            out[near] = Line(ms: ms, text: text)
            return out
        }
        if let shown = out.last(where: { $0.ms <= ms }), shown.text == text { return lines }
        let at = out.firstIndex(where: { $0.ms > ms }) ?? out.count
        out.insert(Line(ms: ms, text: text), at: at)
        if out.count > maxLines { out.removeFirst(out.count - maxLines) }
        return out
    }

    /// 拼成 LRC(纯函数)。文字里的换行压成空格,一句一行。
    public static func lrc(_ lines: [Line]) -> String {
        lines.map { line in
            let cs = line.ms / 10
            let text = line.text.replacingOccurrences(of: "\n", with: " ")
            return String(format: "[%02d:%02d.%02d]", cs / 6000, (cs / 100) % 60, cs % 100) + text
        }.joined(separator: "\n")
    }
}
