import Foundation

/// 设置页那一行时间轴偏移的「作用于哪个播放器」下拉框,候选集怎么算。
///
/// 抽成纯函数放进 Core 的理由跟这个仓库其它几处一样(AGENTS.md 的分层约定):这段逻辑
/// 里有三条**只在特定用户状态下才暴露**的不变量,混在 View 里除了肉眼盯着下拉框以外
/// 没有别的验证办法 —— 而其中一条(配过偏移但已不在信任名单)恰恰就是 2026-08-18 那版
/// 按播放器偏移翻车的原因。
public enum LyricsOffsetScope {
    /// 「全部播放器」那一项的 tag。空串不可能是任何 App 的 bundle id,拿它当哨兵是安全的;
    /// 它在存储层没有对应物 —— 选中它时改的是既有的 `globalOffsetMs`。
    public static let allPlayersTag = ""

    /// 候选 bundle id,顺序即展示顺序。
    ///
    /// - `trusted`: 用户信任的未知播放器(`TrustedPlayers.current`,bundleID → 显示名)。
    /// - `configured`: 已经配过非零偏移的 bundleID(`LyricsOffsetStore.playerOffsets.keys`)。
    /// - `nowPlaying`: 此刻真正在放的那个,没有就传 nil。
    ///
    /// 四组并集,每组内部按 bundle id 排序(字典遍历顺序不稳定,不排会每次启动乱跳):
    ///  1. 内置播放器 —— 按枚举声明顺序,**排除 `.auto`**:它的 bundleIdentifier 是空串,
    ///     存进去会被 `setPlayerOffset` 静默丢掉(用户调了没反应也没报错),而「自动」这层
    ///     语义本来就由「全部播放器」承担。
    ///  2. 信任的未知播放器 —— 浏览器就在这一组,是这个功能的动机。
    ///  3. **已经配过偏移的** —— 哪怕它既不是内置、也已经不在信任名单里(取消信任了、App
    ///     卸了)也必须列出来,否则那个非零偏移会变成看不见、改不动的隐形值。
    ///  4. 此刻正在放的那个 —— 可能是还没加进信任名单的 App,用户往往正是为它才来调。
    public static func options(trusted: [String: String],
                              configured: Set<String>,
                              nowPlaying: String?) -> [String] {
        var ids: [String] = []
        func append(_ id: String) {
            guard !id.isEmpty, !ids.contains(id) else { return }
            ids.append(id)
        }
        for player in PlaybackPlayer.allCases where player != .auto {
            append(player.bundleIdentifier)
        }
        for id in trusted.keys.sorted() { append(id) }
        for id in configured.sorted() { append(id) }
        if let nowPlaying { append(nowPlaying) }
        return ids
    }
}
