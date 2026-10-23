import Foundation
import os

/// Apple Music 正在放资料库里的本地文件时,那个文件在哪。系统那份会话不给路径;换到一首没有目录 ID 的曲目时在后台问一次
/// 脚本的 `location`(只有 file track 有),结论按这首记下。流媒体和匹配过目录的曲目带目录 ID,不问。写进给引擎的播放
/// 状态(`local_file`),引擎读同名 .lrc、文件标签里的歌词和网易云 163 key。见 02 章决策 178。
public enum AppleMusicLocalFile {
    struct Answer: Equatable {
        var title: String
        var artist: String
        var path: String?
    }

    private static let state = OSAllocatedUnfairLock<(answer: Answer?, asking: String?)>(initialState: (nil, nil))
    private static let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.apple-music-local-file", qos: .utility)

    /// 没在跑不拉起它;停着、不是 file track、没有 location 回空串;否则「歌名 tab 路径」。
    public static let script = """
    if application "Music" is not running then return ""
    tell application "Music"
        if player state is stopped then return ""
        try
            set t to current track
            if class of t is not file track then return ""
            set loc to location of t
            if loc is missing value then return ""
            return (name of t) & tab & (POSIX path of loc)
        on error
            return ""
        end try
    end tell
    """

    /// 脚本的回答 → 这首的文件。歌名对不上(问的时候已经换了歌)、不是绝对路径为 nil。纯函数,selftest 覆盖。
    public static func parse(_ output: String, title: String) -> String? {
        let line = output.trimmingCharacters(in: .newlines)
        guard let tab = line.firstIndex(of: "\t"), line[..<tab] == title else { return nil }
        let path = String(line[line.index(after: tab)...])
        return path.hasPrefix("/") ? path : nil
    }

    /// 要不要为这首问脚本:有歌名、没有目录 ID。本地文件报的「目录 ID」是资料库 persistent ID 当成有符号数,是负的,
    /// 跟没有一样问;目录里的歌是正数。纯函数,selftest 覆盖。
    public static func shouldAsk(title: String, catalogTrackID: Int64?) -> Bool {
        !title.isEmpty && (catalogTrackID ?? 0) <= 0
    }

    /// 这首(歌手、歌名)的文件:问过就交结论;没问过就在后台问一次,这一拍交 nil,问完之后的下一拍交。
    public static func currentFilePath(artist: String, title: String, catalogTrackID: Int64?) -> String? {
        guard shouldAsk(title: title, catalogTrackID: catalogTrackID) else { return nil }
        let key = artist + "\u{1F}" + title
        let (known, start) = state.withLock { s -> (Answer?, Bool) in
            if let a = s.answer, a.title == title, a.artist == artist { return (a, false) }
            if s.asking == key { return (nil, false) }
            s.asking = key
            return (nil, true)
        }
        if let known { return known.path }
        if start {
            queue.async {
                let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script],
                                               timeout: MusicPlaybackController.appleScriptTimeout)
                let path = result.flatMap { $0.succeeded ? parse($0.stdoutText, title: title) : nil }
                state.withLock { s in
                    if s.asking == key { s.asking = nil }
                    s.answer = Answer(title: title, artist: artist, path: path)
                }
            }
        }
        return nil
    }
}
