import Foundation
import os

/// Apple Music 正在放资料库里的曲目时,这首是什么。系统那份会话对资料库里的曲目只给资料库 persistent ID(正负都有,不是目录 ID),
/// 不给本地文件的路径,也不说是不是 Apple Music 的目录音频。换到一首没有目录 ID 的曲目时在后台问一次脚本,结论按这首记下:
/// file track 交 `location`,写进给引擎的播放状态(`local_file`),引擎读同名 .lrc、文件标签里的歌词和网易云 163 key(02 章决策 178);
/// 别的曲目交 `cloud status`,是订阅 / 购买的目录音频时写 `apple_catalog_stream`,引擎按核对过的锚点认出它的目录 ID(02 章决策 197)。
public enum AppleMusicLocalFile {
    public struct Answer: Equatable, Sendable {
        /// 本地文件的 POSIX 路径;不是 file track 为 nil。
        public var path: String?
        /// 放的是 Apple Music 目录里的音频(订阅 / 购买,`catalogCloudStatuses`)。
        public var catalogStream: Bool

        public init(path: String?, catalogStream: Bool) {
            self.path = path
            self.catalogStream = catalogStream
        }
    }

    private struct Asked: Equatable {
        var title: String
        var artist: String
        var answer: Answer?
    }

    /// asked:最近一首问出来的结论;asking:正在问的那首;failed:没问出结论的那首和时间,`retryInterval` 之后再问。
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "apple-music-library")
    private static let state = OSAllocatedUnfairLock<(asked: Asked?, asking: String?, failed: (key: String, at: Date)?)>(
        initialState: (nil, nil, nil))
    private static let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.apple-music-local-file", qos: .utility)

    /// 脚本超时、出错、回空串(问的那一刻停着、换歌)时不记结论,隔这么久再问。负载高时第一次常常超时,记成「什么都不是」
    /// 这首就再也认不出来了。
    static let retryInterval: TimeInterval = 30

    /// 目录 ID 的合理上界,跟引擎 `appleCatalogMaxPlausibleID` 两处同步改:现役目录 ID 是 10 位数量级,资料库 persistent ID 是满量程 64 位。
    public static let maxCatalogTrackID: Int64 = 1_000_000_000_000

    /// 这几种 `cloud status` 放的是 Apple Music 目录里的那份音频。匹配(matched)和上传(uploaded)的不算:匹配可能配到别的版本,上传的是用户自己的文件。
    public static let catalogCloudStatuses: Set<String> = ["subscription", "purchased"]

    /// 没在跑不拉起它;停着、出错回空串;file track 回「歌名 tab file tab 路径」(没有 location 回空串),别的回「歌名 tab cloud tab 云状态」。
    public static let script = """
    if application "Music" is not running then return ""
    tell application "Music"
        if player state is stopped then return ""
        try
            set t to current track
            if class of t is file track then
                set loc to location of t
                if loc is missing value then return ""
                return (name of t) & tab & "file" & tab & (POSIX path of loc)
            end if
            return (name of t) & tab & "cloud" & tab & (cloud status of t as text)
        on error
            return ""
        end try
    end tell
    """

    /// 脚本的回答 → 这首是什么。歌名对不上(问的时候已经换了歌)、路径不是绝对路径、认不出的回答为 nil。纯函数,selftest 覆盖。
    public static func parse(_ output: String, title: String) -> Answer? {
        let parts = output.trimmingCharacters(in: .newlines).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == title else { return nil }
        let value = String(parts[2])
        switch parts[1] {
        case "file":
            return value.hasPrefix("/") ? Answer(path: value, catalogStream: false) : nil
        case "cloud":
            return Answer(path: nil, catalogStream: catalogCloudStatuses.contains(value))
        default:
            return nil
        }
    }

    /// 要不要为这首问脚本:有歌名、报的不像目录 ID。资料库里的曲目报的是 persistent ID 当成有符号数,正负各半,
    /// 正数那一半比目录 ID 大好几个数量级。纯函数,selftest 覆盖。
    public static func shouldAsk(title: String, catalogTrackID: Int64?) -> Bool {
        guard !title.isEmpty else { return false }
        guard let id = catalogTrackID else { return true }
        return id <= 0 || id >= maxCatalogTrackID
    }

    /// 这首(歌手、歌名)是什么:问过就交结论;没问过就在后台问一次,这一拍交 nil,问完之后的下一拍交。
    public static func current(artist: String, title: String, catalogTrackID: Int64?, now: Date = Date()) -> Answer? {
        guard shouldAsk(title: title, catalogTrackID: catalogTrackID) else { return nil }
        let key = artist + "\u{1F}" + title
        let (known, start) = state.withLock { s -> (Asked?, Bool) in
            if let a = s.asked, a.title == title, a.artist == artist { return (a, false) }
            if s.asking == key { return (nil, false) }
            if let f = s.failed, f.key == key, now.timeIntervalSince(f.at) < retryInterval { return (nil, false) }
            s.asking = key
            return (nil, true)
        }
        if let known { return known.answer }
        if start {
            queue.async {
                let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script],
                                               timeout: MusicPlaybackController.appleScriptTimeout, captureStderr: true)
                let answer = result.flatMap { $0.succeeded ? parse($0.stdoutText, title: title) : nil }
                if answer == nil {
                    let status = result.map { $0.timedOut ? "timed out" : "exit \($0.status)" } ?? "not launched"
                    let detail = result.map { String($0.stderrText.prefix(160)) + " | " + String($0.stdoutText.prefix(80)) } ?? ""
                    logger.notice("library track: no answer (\(status, privacy: .public)): \(detail, privacy: .public)")
                }
                state.withLock { s in
                    if s.asking == key { s.asking = nil }
                    if let answer {
                        s.asked = Asked(title: title, artist: artist, answer: answer)
                    } else {
                        s.failed = (key, Date())
                    }
                }
            }
        }
        return nil
    }
}
