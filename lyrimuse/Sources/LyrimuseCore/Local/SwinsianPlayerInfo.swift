import Foundation
import os

/// Swinsian 的分布式通知和脚本读数。曲目走系统会话(歌名、歌手、专辑、精确时长都齐),这里只给位置表(`SwinsianPlayhead`)
/// 和当前文件补料:
///
/// - 通知 `com.swinsian.Swinsian-Track-Playing` / `-Track-Paused` / `-Track-Stopped`:开播、恢复、暂停、换歌(元数据完全相同的
///   下一首也发)、单曲循环每次绕回都发,跳转不发;userInfo 带精确的 `currentTime`、`title`、`artist`、`path`。系统会话在
///   元数据相同的下一首、循环第二次起的绕回上不重发,靠这条接上。
/// - 脚本 `player position` 是下取整的整秒,整秒跳变的时刻跟真实出声对得上(`SwinsianPlayhead`)。
/// - 当前文件:通知和脚本都给路径,`PlayerOpenFile` 按开着的文件认不到时用它们。
///
/// 见 02 章决策 241。
public enum SwinsianPlayerInfo {
    public static var bundleID: String { PlaybackPlayer.swinsian.bundleIdentifier }

    public static let playingNotification = "com.swinsian.Swinsian-Track-Playing"
    public static let pausedNotification = "com.swinsian.Swinsian-Track-Paused"
    public static let stoppedNotification = "com.swinsian.Swinsian-Track-Stopped"
    public static let noticeNames = [playingNotification, pausedNotification, stoppedNotification]

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "swinsian")

    // MARK: 通知

    /// 一条通知。`at` 是收到的时刻,`position` 是那一刻的位置。
    public struct Notice: Equatable, Sendable {
        public var playing: Bool
        public var stopped: Bool
        public var position: Double?
        public var at: Date
        public var title: String
        public var artist: String
        public var path: String?

        /// 解不出(不是这三条、没有歌名)为 nil。纯函数,selftest 覆盖。
        public init?(name: String, userInfo: [AnyHashable: Any]?, at: Date) {
            guard SwinsianPlayerInfo.noticeNames.contains(name),
                  let title = userInfo?["title"] as? String, !title.isEmpty else { return nil }
            playing = name == SwinsianPlayerInfo.playingNotification
            stopped = name == SwinsianPlayerInfo.stoppedNotification
            position = (userInfo?["currentTime"] as? NSNumber)?.doubleValue
            self.at = at
            self.title = title
            artist = userInfo?["artist"] as? String ?? ""
            path = (userInfo?["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private static let latest = OSAllocatedUnfairLock<Notice?>(initialState: nil)

    /// `LocalPlaybackSource` 收到通知时记下(主队列上写,轮询的后台线程上读)。
    public static func note(_ notice: Notice) {
        latest.withLock { $0 = notice }
        logger.debug("swinsian notice: playing \(notice.playing, privacy: .public) at \(notice.position ?? -1, format: .fixed(precision: 3))")
    }

    public static func latestNotice() -> Notice? { latest.withLock { $0 } }

    /// 这条通知说的是不是系统那份报的这一首:歌名一样,通知带了歌手时歌手也一样。纯函数,selftest 覆盖。
    public static func matches(_ notice: Notice, title: String?, artist: String?) -> Bool {
        guard let title, notice.title == title else { return false }
        return notice.artist.isEmpty || notice.artist == (artist ?? "")
    }

    /// 通知换成位置表用的锚点:说的是这一首、带位置、不是停住。纯函数,selftest 覆盖。
    public static func anchor(from notice: Notice?, track: String, title: String?, artist: String?) -> SwinsianPlayhead.Anchor? {
        guard let notice, !notice.stopped, let position = notice.position, position >= 0,
              matches(notice, title: title, artist: artist) else { return nil }
        return SwinsianPlayhead.Anchor(track: track, elapsed: position, at: notice.at, playing: notice.playing)
    }

    // MARK: 脚本

    /// 每拍核对用的 JXA 快照:没在跑、停住时回 `null`,不会把它拉起来。位置放在最后读。
    public static let script = """
    (() => {
        \(JXARunningApp.attach("S", player: .swinsian, notRunning: "JSON.stringify(null)"))
        try {
            const state = S.playerState();
            if (state !== "playing" && state !== "paused") return JSON.stringify(null);
            const track = S.currentTrack();
            const reading = { state: state, title: track.name() || "", path: track.path() || "" };
            reading.position = S.playerPosition();
            return JSON.stringify(reading);
        } catch (e) {
            return JSON.stringify(null);
        }
    })()
    """

    /// 一次脚本读数。
    public struct ScriptReading: Decodable, Equatable, Sendable {
        public var state: String
        public var title: String
        public var path: String
        public var position: Int

        public var playing: Bool { state == "playing" }
    }

    /// 脚本输出 → 读数;`null`、解不开为 nil。纯函数,selftest 覆盖。
    public static func scriptReading(from data: Data) -> ScriptReading? {
        try? JSONDecoder().decode(ScriptReading.self, from: data)
    }

    /// 读数换成位置表的核对:在放、说的是这一首。纯函数,selftest 覆盖。
    public static func check(_ reading: ScriptReading, title: String?, from: Date, to: Date) -> SwinsianPlayhead.Check? {
        guard reading.playing, let title, reading.title == title, reading.position >= 0 else { return nil }
        return SwinsianPlayhead.Check(position: reading.position, from: from, to: to)
    }

    private static let lastScript = OSAllocatedUnfairLock<ScriptReading?>(initialState: nil)

    static func remember(_ reading: ScriptReading) {
        lastScript.withLock { $0 = reading }
    }

    /// 盯整秒跳变的 JXA:在放时每 20 毫秒读一次位置,跳到下一秒就回跳到的值和前后两次读数的时刻(毫秒);1.3 秒内没跳、
    /// 中途跳转了(不是 +1)、换了歌、没在放,回 `null`。
    public static let tickScript = """
    (() => {
        \(JXARunningApp.attach("S", player: .swinsian, notRunning: "JSON.stringify(null)"))
        try {
            if (S.playerState() !== "playing") return JSON.stringify(null);
            const name = S.currentTrack().name();
            let last = S.playerPosition(), lastAt = Date.now();
            const end = lastAt + 1300;
            while (Date.now() < end) {
                delay(0.02);
                const value = S.playerPosition(), at = Date.now();
                if (value === last + 1) {
                    if (S.currentTrack().name() !== name) return JSON.stringify(null);
                    return JSON.stringify({ value: value, before: lastAt, after: at });
                }
                if (value !== last) return JSON.stringify(null);
                last = value;
                lastAt = at;
            }
            return JSON.stringify(null);
        } catch (e) {
            return JSON.stringify(null);
        }
    })()
    """

    struct TickOutput: Decodable {
        let value: Int
        let before: Double
        let after: Double
    }

    /// 盯跳变脚本的输出 → 跳变;时刻取前后两次读数的中间。纯函数,selftest 覆盖。
    public static func tick(from data: Data) -> SwinsianPlayhead.Tick? {
        guard let out = try? JSONDecoder().decode(TickOutput.self, from: data), out.after >= out.before else { return nil }
        return SwinsianPlayhead.Tick(value: out.value, at: Date(timeIntervalSince1970: (out.before + out.after) / 2000))
    }

    /// 跑一次盯跳变的脚本(单独起一个 osascript,不占常驻那个)。阻塞最多 `timeout`。
    static func sampleTick(timeout: TimeInterval) -> SwinsianPlayhead.Tick? {
        guard let r = ProcessRunner.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", tickScript], timeout: timeout),
              r.succeeded else { return nil }
        return tick(from: r.stdout)
    }

    // MARK: 当前文件

    /// 通知或脚本最近报的那个文件,说的是播放器原样报的这一首(`rawTitle`)时才给;通知关掉了只看脚本。
    public static func currentFilePath(rawTitle: String?) -> String? {
        guard let rawTitle, !rawTitle.isEmpty else { return nil }
        if !SourceKnockout.isOut(.swinsianNotice), let notice = latestNotice(), notice.title == rawTitle,
           let path = notice.path {
            return path
        }
        guard !SourceKnockout.isOut(.swinsianScript), let reading = lastScript.withLock({ $0 }),
              reading.title == rawTitle, !reading.path.isEmpty else { return nil }
        return reading.path
    }
}
