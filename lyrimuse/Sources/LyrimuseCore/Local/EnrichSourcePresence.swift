import Foundation

/// "歌词源的曲库里有这首歌"的判据(2026-09-05,见 EnrichCacheStore.Summary.knownOnSources)。
///
/// 两个字段的形状来自 collector:
///   - `netease_url` 只在网易云真的匹配到曲目时才写(`https://music.163.com/song?id=<id>`),
///     没匹配到就是空——非空即命中。
///   - `qq_music_url` 有两档:smartbox 查到时是 `https://y.qq.com/n/ryqq/songDetail/<mid>`;
///     查不到时 collector 拼一个**纯本地的搜索页**兜底(`…/search?w=…`,见 qq.go),
///     那一档不需要网络就能得到、不构成"有这首歌"的证据——enrich.go 里"全空不写入"那道
///     守卫排除它的理由一样(isQQSearchFallbackURL)。这里按路径段 `/songDetail/` 判。
public enum EnrichSourcePresence {
    public static func knownOnSources(neteaseURL: String?, qqMusicURL: String?) -> Bool {
        if let n = neteaseURL, !n.isEmpty { return true }
        if let q = qqMusicURL, q.contains("/songDetail/") { return true }
        return false
    }
}
