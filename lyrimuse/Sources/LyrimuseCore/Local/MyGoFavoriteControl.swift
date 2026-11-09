import CryptoKit
import Foundation

/// MyGo Music 本机曲目的「喜欢」。
/// - 读:当前这首对上的文件(`PlayerOpenFile`)算出曲目 ID(`sha256("track" + NUL + 路径)` 前 8 字节的十六进制),
///   看它在不在本地库 `local/library.json` 的 `likes` 里。按一下喜欢它当场整份写这个文件。
/// - 写:先读,跟要的一样就不按;不一样按它「控制」菜单里「喜欢/取消喜欢」那一项(标题固定、按一下切换),
///   等 `library.json` 真的变成要的样子才算写成。
/// 插件音源的曲目不在本地库里,没有对上的本机文件,读写都为 nil / false,界面上不显示心。见 07 章决策 199。
public enum MyGoFavoriteControl {
    static let bundleID = PlaybackPlayer.mygoMusic.bundleIdentifier

    /// 菜单项标题:它的界面只有简体中文和英文两套。
    public static let menuTitles = ["喜欢/取消喜欢", "Like/Unlike"]

    /// 按完等本地库变过来最多多久、多久看一次。
    static let writeSettleSeconds: TimeInterval = 1.5
    static let writePollSeconds: TimeInterval = 0.05

    static var libraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MyGo Music/local/library.json")
    }

    /// 本机文件的曲目 ID(MyGo 源码 `local.makeID`)。纯函数,selftest 覆盖。
    public static func trackID(path: String) -> String {
        let digest = SHA256.hash(data: Data(("track\u{0}" + path).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 本地库里喜欢过的曲目 ID;解不开为 nil,没喜欢过任何一首为空。纯函数,selftest 覆盖。
    public static func likes(libraryData: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: libraryData) as? [String: Any] else { return nil }
        return object["likes"] as? [String] ?? []
    }

    /// 系统此刻报的是 MyGo、而且放的是对上了本机文件的那一首时,那个文件的曲目 ID。
    static func currentLocalTrackID() -> String? {
        guard let now = MediaControlClient.currentNowPlayingIdentifiers(), now.bundleID == bundleID, !now.title.isEmpty,
              let path = PlayerOpenFile.currentFilePath(bundleID: bundleID, rawArtist: now.artist, rawTitle: now.title)
        else { return nil }
        return trackID(path: path)
    }

    static func liked(id: String) -> Bool? {
        guard let data = FileIO.read(libraryURL), let likes = likes(libraryData: data) else { return nil }
        return likes.contains(id)
    }

    /// 读不到(不是 MyGo、放的是插件音源、本地库读不出)为 nil。会读盘,不要在主线程调用。
    public static func readFavorited() -> Bool? {
        guard let id = currentLocalTrackID() else { return nil }
        return liked(id: id)
    }

    /// 设「喜欢」,返回写成没有。会阻塞(跨进程按菜单、等本地库),不要在主线程调用。
    public static func setFavorited(_ value: Bool) -> Bool {
        guard let id = currentLocalTrackID(), let now = liked(id: id) else { return false }
        if now == value { return true }
        guard pressMenuItem() == .pressed else { return false }
        let deadline = Date().addingTimeInterval(writeSettleSeconds)
        while Date() < deadline {
            if liked(id: id) == value { return true }
            Thread.sleep(forTimeInterval: writePollSeconds)
        }
        return liked(id: id) == value
    }

    static func pressMenuItem() -> PlaybackMenuControl.Outcome {
        var last = PlaybackMenuControl.Outcome.menuUnavailable
        for title in menuTitles {
            last = PlaybackMenuControl.pressItem(titled: title, for: .mygoMusic)
            if last != .menuUnavailable { return last }
        }
        return last
    }
}
