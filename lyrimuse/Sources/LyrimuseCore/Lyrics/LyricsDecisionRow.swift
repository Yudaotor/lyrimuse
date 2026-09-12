import Foundation

/// 「解析决策」面板里一条候选**是不是一条真候选** —— 纯判定,不碰 IO。
///
/// 背景:collector 判定"这首歌本来就没有词"时,会借候选列表**搭车**把这个信号带出来 ——
/// 往 scored 列表里塞一条 `{source, score: -1, instrumental: true}` 的伪候选,标题/歌手/
/// 专辑/封面/分数明细**一概没有**(见 collector `enrich.go` 的 instrumentalMarker;当初
/// 这么做是为了不改 fetchScoredLyricCandidatesStreaming 的返回值签名,它被手动搜索 CLI 和
/// 常驻解析两条路共用)。那个负分是**手段不是评价**:它让 pickLyricCandidate 一定跳过这条,
/// 不参与打分排序 —— 对用户而言 -1 是个纯粹的内部实现细节。
///
/// 手动搜索那条路 2026-08-03 就把这类标记过滤掉了(collector `searchcli.go` 的
/// filterEnabledLyricSources,注释原话:"不该多出一行歌词是空的、点了也没用的候选"),而
/// 「解析决策」面板一直没有 —— 于是面板上会多出一行**除了源名和一个红色 -1 什么都没有**的
/// 空壳。2026-09-12 用户截图问「它怎么是空的,并且是 -1?」。
///
/// ⚠️ 面板这边**不能照搬"过滤掉"**:手动搜索的判据是"能不能点选采用",而这个面板是"当时
/// 那一刻的证据"——「某个源明确说过这首是纯音乐」恰恰是复盘时最想看到的一句话,尤其在别的源
/// 却给了词、还赢了的时候(用户那次就是:LRCLIB 说纯音乐,而另两个源匹配到带词版本、以 1208
/// 分胜出)。删掉等于把证据删了。所以这里只负责"认出来",由面板换一种说法显示。
public enum LyricsDecisionRow {
    /// 这条候选是不是"纯音乐标记"(不是候选,是一个信号)。
    ///
    /// - instrumental: 存档里的 `instrumental` 字段。**老存档没有这个字段** → nil,
    ///   那时候的标记行只能继续按普通候选显示(存档是当时那一刻的固化,不能事后补)。
    /// - score: 存档里的分数。
    ///
    /// 两个条件都要:`instrumental == true` 认的是 collector 塞的那条标记;`score < 0` 是
    /// 第二道保险 —— 万一日后某个源既给出了歌词、又把 instrumental 标成 true,那是一条
    /// **真候选**(有正分、有标题、能被选中、甚至可能是胜者),不该被当成空壳换掉说法。
    public static func isInstrumentalMarker(instrumental: Bool?, score: Int) -> Bool {
        instrumental == true && score < 0
    }
}
