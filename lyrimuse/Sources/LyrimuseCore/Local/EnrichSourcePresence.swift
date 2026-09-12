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

    /// 「最近一轮一个源都没应答」(2026-09-12,借鉴清单 V4)。
    ///
    /// 上面 `knownOnSources` 判的是**历史事实**——某一轮确实在网易云 / QQ 曲库里定位到了这首歌;
    /// 而这条判的是**最近这一轮的状态**。两者可以同时成立,而它们给用户的行动建议相反:
    /// 「源里有歌、无词」= 词还不存在,不用管、只能等;「最近一轮没人应答」= 那一刻网络全挂,
    /// 重搜一下也许就有了。所以显示时这一档要**排在 `knownOnSources` 之前**,不然界面会拿
    /// 一条更早那轮的证据,去替这一轮下"不用管"的结论(09 章决策 48 修的就是同一类口径问题)。
    ///
    /// ⚠️ **判据必须用「决策存档在不在」而不是顶层 `lyrics_sources_responded` 是不是空**:
    /// 那个字段在 collector 侧带 `omitempty`(enrich.go),空数组根本不会被序列化出来,于是
    /// 「老条目压根没有这个字段」和「真的零个源应答」在顶层字段上**完全不可区分**。
    /// 决策存档则是只要评估过就一定写,所以「有存档 + 存档里 sources_responded 为空」才是准的。
    ///
    /// 取 `lyrics_decision`(最近一次评估)那一槽,不取 `lyrics_decision_applied`(当前歌词的出处):
    /// 空条目从来没"采用"过任何东西,applied 槽恒为空(本机 142 条空条目实测 0/142 有 applied)。
    ///
    /// - Parameters:
    ///   - hasDecisionRecord: `lyrics_decision` 这一槽在不在。
    ///   - respondedCount: 那一槽里 `sources_responded` 的长度(缺失按 0)。
    public static func lastRoundHadNoResponder(hasDecisionRecord: Bool, respondedCount: Int) -> Bool {
        hasDecisionRecord && respondedCount == 0
    }
}
