import ApplicationServices
import Foundation

/// 酷我音乐的「喜欢」= 当前这首在不在当前账号的「我喜欢听」。见 02 章决策 267。
/// - 读:状态在酷我容器的 `cloud.db`,App 不读别的 App 的容器,交给引擎子命令 `kuwo-favorite`(`kuwofavorite.go`,
///   要「完全磁盘访问」),按系统此刻报的歌名、歌手问一次。
/// - 写:「编辑」菜单「收藏/取消收藏」(⌘L,标题不随状态变,按一下切换当前这首),先读、一样就不按,按完等读回变过来才算。
/// 没授权辅助功能时写不了,读也当读不到,不显示心。只有简体中文界面。
public enum KuwoFavoriteControl {
    static let bundleID = PlaybackPlayer.kuwo.bundleIdentifier
    public static let menuTitle = "收藏/取消收藏"
    /// 引擎读一次最多等这么久(它自己查库的上限是 2 秒)。按完确认那步会问好几次,撞上酷我的写锁时不能一直挂着。
    static let queryTimeout: TimeInterval = 3

    public static let favorite = MenuTitleFavorite(bundleID: bundleID, itemTitle: menuTitle, commandKey: "L",
                                                   confirmWait: 2, readState: { readState() })

    /// 当前这首喜欢了没有;读不到为 nil。会阻塞到子进程结束,别在主线程调。
    public static func readFavorited() -> Bool? { favorite.read() }

    /// 设成喜欢 / 不喜欢,返回到没到(见 `MenuTitleFavorite.set`)。会阻塞,别在主线程调。
    public static func setFavorited(_ value: Bool) -> Bool { favorite.set(value) }

    /// 引擎子命令的参数。纯函数,selftest 覆盖。
    public static func engineArguments(title: String, artist: String) -> [String] {
        ["kuwo-favorite", "-title", title, "-artist", artist]
    }

    /// 引擎那一行 JSON → 喜欢了没有:`{"favorited":true|false}`;`{}`(读不到)和认不出的为 nil。纯函数,selftest 覆盖。
    public static func favorited(fromEngineOutput data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["favorited"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    /// 系统此刻报的是酷我时,问引擎这一首在不在「我喜欢听」。
    static func readState() -> Bool? {
        guard AXIsProcessTrusted(), let now = MediaControlClient.currentNowPlayingIdentifiers(), now.bundleID == bundleID,
              !now.title.isEmpty else { return nil }
        guard let result = ProcessRunner.run(LyrimusePaths.bundledEnginePath,
                                             engineArguments(title: now.title, artist: now.artist), timeout: queryTimeout,
                                             environment: LyrimusePaths.engineProcessEnvironment()),
              result.succeeded else { return nil }
        return favorited(fromEngineOutput: result.stdout)
    }
}
