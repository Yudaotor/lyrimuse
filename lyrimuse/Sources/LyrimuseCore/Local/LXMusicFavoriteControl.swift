import AppKit
import Foundation

/// 洛雪音乐的「喜欢」= 当前这首在不在它的「我的收藏」(本地库 `lx.data.db` 里 listId 为 `love` 的那个列表)。见 07 章决策 158。
///
/// - 读:按系统正在报的歌名、歌手在收藏列表里找;洛雪报的就是列表里那一条的 name、singer,逐字对。只读打开,走
///   `/usr/bin/sqlite3`(引擎读它的库也是这样,见 lyrimuse-engine/lxmusic.go)。
/// - 写:洛雪自己的链接 `lxmusic://player/collect` / `uncollect`,收的是它正在放的那首;后台打开,不把它拉到前台。按完等本地库
///   里真的有 / 没有了才算到(实测 0.25 秒落库)。
/// - 用户打开了开放 API(`LXMusicOpenAPI`)、推来的又是这一首时,读它推的收藏状态、写走它的 `/collect`,在洛雪里点了收藏这边
///   也马上跟着变。系统那边没报洛雪、读数是开放 API 顶上来的(`MediaControlClient.lxMusicReadViaOpenAPI`)时,按它推的歌名、
///   歌手认这一首。
public enum LXMusicFavoriteControl {
    public static let bundleID = PlaybackPlayer.lxMusic.bundleIdentifier
    /// 按完等本地库确认:最多等这么久、隔这么久看一次。
    static let confirmWait: TimeInterval = 3
    static let confirmPollInterval: TimeInterval = 0.1
    /// 读一次本地库最多等这么久(按完确认那步一次最多读 30 次,库被锁、磁盘卡住时不能一直挂着)。
    static let queryTimeout: TimeInterval = 2

    public static var databasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/lx-music-desktop/LxDatas/lx.data.db").path
    }

    /// 系统正在报的这首在不在收藏里;不是洛雪在报、读不动返回 nil。会阻塞到子进程结束,不要在主线程调用。
    public static func readFavorited() -> Bool? {
        guard let now = currentTrack() else { return nil }
        if let api = LXMusicOpenAPI.shared.currentState(), LXMusicOpenAPI.describes(api, title: now.title, artist: now.artist),
           let collected = api.collect {
            return collected
        }
        return isCollected(title: now.title, artist: now.artist, databasePath: databasePath)
    }

    /// 洛雪此刻在放的这一首:系统报的是洛雪就按系统那份;读数是开放 API 顶上来的就按它推的。都不是为 nil。
    static func currentTrack() -> (title: String, artist: String)? {
        if let now = MediaControlClient.currentNowPlayingIdentifiers(), now.bundleID == bundleID, !now.title.isEmpty {
            return (now.title, now.artist)
        }
        guard MediaControlClient.lxMusicReadViaOpenAPI, let api = LXMusicOpenAPI.shared.currentState(),
              let name = api.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return (name, api.singer ?? "")
    }

    /// 收藏列表里有没有这一首;库不在、读不动、超过 `queryTimeout` 返回 nil。会阻塞到子进程结束或超时。selftest 覆盖。
    public static func isCollected(title: String, artist: String, databasePath: String) -> Bool? {
        guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
        let query = "SELECT count(*) FROM my_list_music_info WHERE listId = 'love' AND name = \(sqlString(title)) "
            + "AND singer = \(sqlString(artist))"
        // 不读 ~/.sqliterc:用户在里面开了 .headers 或换了输出格式,count(*) 就解析不出来。
        guard let result = ProcessRunner.run("/usr/bin/sqlite3", ["-init", "/dev/null", "-batch", "file:\(databasePath)?mode=ro", query],
                                             timeout: queryTimeout),
              result.succeeded,
              let count = Int(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return count > 0
    }

    static func sqlString(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

    /// 设成 `value`,返回写成没有。读不出现在的状态(不是洛雪在报)时不按:链接收的是洛雪正在放的那首,不一定是界面上这一首。
    @discardableResult
    public static func setFavorited(_ value: Bool) -> Bool {
        guard let current = readFavorited() else { return false }
        if current == value { return true }
        if LXMusicOpenAPI.shared.currentState() != nil, LXMusicOpenAPI.shared.setCollected(value) {
            return waitUntilFavorited(value)
        }
        guard let url = URL(string: value ? "lxmusic://player/collect" : "lxmusic://player/uncollect") else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
        return waitUntilFavorited(value)
    }

    private static func waitUntilFavorited(_ value: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(confirmWait)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: confirmPollInterval)
            if readFavorited() == value { return true }
        }
        return false
    }
}
