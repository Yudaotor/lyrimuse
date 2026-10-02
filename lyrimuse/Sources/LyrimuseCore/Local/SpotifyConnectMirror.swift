import Foundation

/// 桌面版 Spotify 遥控别的设备(Spotify Connect)时,本机不出声,却照样报自己在播,曲目和进度跟着那台设备走。
/// 那台设备是配对浏览器里的 Spotify 网页版时,系统「正在播放」的焦点会被桌面版抢走:歌手只剩第一位,曲目身份跟着变。
/// 这里判焦点上的桌面版是不是网页版的镜像。纯函数,selftest 覆盖;接线在 `MediaControlClient.resolvingSpotifyConnectMirror`,
/// 见 02 章决策 79。
///
/// 遥控音箱、手机这类别的设备时网页版不在报这首,照旧用桌面版那份,别把「桌面版没在出声」单独当成拒收的理由。
public enum SpotifyConnectMirror {
    /// 焦点上是桌面版 Spotify、上一份被接受的来自配对了 Spotify 网页版的浏览器时,要不要按 bundle id 问一次那个浏览器。
    /// 桌面版自己在往本机输出音频(在放,或者刚暂停)就是它在出声,不用问。
    public static func shouldAskWebPlayer(focusBundleID: String, webSourceBundleID: String?, desktopOutputting: Bool) -> Bool {
        guard focusBundleID == PlaybackPlayer.spotify.bundleIdentifier,
              let webSourceBundleID, !webSourceBundleID.isEmpty, webSourceBundleID != focusBundleID else { return false }
        return !desktopOutputting
    }

    /// 问到的网页版那份能不能顶替焦点上的桌面版:两边报的是同一首(按清洗后的曲名比,歌手两边写法不一样)。
    /// 播放状态不比:网页版刚暂停时桌面版会晚一两拍才跟上,那几拍它还报在播。
    public static func webPlayerWins(desktop: MediaControlSnapshot, web: MediaControlSnapshot?) -> Bool {
        guard let web else { return false }
        let desktopTitle = EnrichCacheKeys.cleanTag(desktop.title ?? "")
        return !desktopTitle.isEmpty && desktopTitle == EnrichCacheKeys.cleanTag(web.title ?? "")
    }

    /// 接受了一份快照之后「网页版来源」记成什么:来自配对了 Spotify 网页版的浏览器就记下它报上来的 bundle id,别的一律清掉。
    public static func nextWebSource(acceptedBundleID: String, acceptedIsSpotifyWebBrowser: Bool) -> String? {
        acceptedIsSpotifyWebBrowser && !acceptedBundleID.isEmpty ? acceptedBundleID : nil
    }
}
