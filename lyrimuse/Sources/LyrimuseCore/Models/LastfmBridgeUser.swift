import Foundation

/// 「连接 Last.fm」授权成功之后,桥接 / 统计读的用户名(config.json 的 lastfm_user)要不要换成这次授权的账号。
///
/// 用户名输入框已经删了,lastfm_user 只能靠授权回填。只在还没填过时回填的话,换了一个账号授权,引擎的
/// 桥接、最近播放、榜单会一直读旧账号,写入却进了新账号,界面上也没有地方能改回来。所以:还没填,或者填的
/// 就是上一次授权的账号(Last.fm 用户名不区分大小写)时换;之前没授权过、却填着一个名字(输入框还在时代手填的、
/// 桥接跟写入不同的账号)时保留。
public enum LastfmBridgeUser {
    public static func shouldAdoptAuthorized(current: String, previousAuthorized: String) -> Bool {
        if current.isEmpty { return true }
        return !previousAuthorized.isEmpty && current.caseInsensitiveCompare(previousAuthorized) == .orderedSame
    }
}
