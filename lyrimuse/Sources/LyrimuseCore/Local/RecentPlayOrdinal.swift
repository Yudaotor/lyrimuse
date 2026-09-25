import Foundation

/// 「最近记录里这一行是这首歌的第几次听」的换算。从 LastfmStatsSection 的
/// private `recentRows` **下沉**到 Core —— 停播页的「最近听过」是第二个消费方。
///
/// 为什么必须共享、不能各写一份:这段里有**两把不同的尺子**,抄错任何一处都会显示错次数 ——
/// 取总数用调用方注入的 `playCountKey`(表就是按它建的),而「比这一行更新的同曲收听」必须按
/// `PlayCountFold.familyKey` 的**折叠族**数(表里存的是整族合并后的总数)。抄错的表现是
/// 「第 15 次听下面紧跟第 21 次听」正是两把尺子不一致造出来的:同一首歌的两种写法是两个不同的
/// playCountKey,跨写法的更新收听一次都减不掉,于是同页两行显示同一个 N。第二个消费方一出现,
/// 复制这段就等于把那个 bug 的成因复制一份,所以这里落成一份实现 + selftest 钉住。
///
/// 算法:服务给的是**当前总数**(userplaycount,已含最近这一次),不是「那一刻是第几次」。
/// 换算 = 当前总数 − 比这一行更新的同族收听次数。列表按时间倒序,所以比某一行更新的同族收听
/// 必然也落在这个窗口里 —— 这个减法**窗口内精确**、不需要额外请求,**跨页不精确**。
///
/// 整段**一次线性扫描**算完,不要写成「每行现算」:那样每行都要重跑一遍全表 filter、
/// 还要对它前面所有行重建归一化键,20 行就是 21 次数组分配 + 210 次字符串归一化,而这段跑在
/// SwiftUI body 的同步路径上(性能审阅坐实)。
public enum RecentPlayOrdinal {
    /// - Parameters:
    ///   - rows: 按时间**倒序**(最新在前)的行,只需要 歌手 / 歌名 两个字段。
    ///     正在播放那条**不要传进来**:它还没被 scrobble、不在 userplaycount 里(实时行自己 +1)。
    ///   - totals: 折叠族合并后的总收听数,键由 `playCountKey` 给出。
    ///   - playCountKey: 取 `totals` 用的键函数,由调用方注入 —— 保证跟建表时是**同一把尺子**。
    /// - Returns: 与 `rows` 等长。查不到总数、或竞态(刚多了一次收听、总数还没重取)导致
    ///   算出 ≤ 0 的位置一律 nil ——**宁可不显示,也不显示错的**。
    public static func ordinals(
        rows: [(artist: String, title: String)],
        totals: [String: Int],
        playCountKey: (String, String) -> String
    ) -> [Int?] {
        var newerSame: [String: Int] = [:]
        return rows.map { row in
            let familyKey = PlayCountFold.familyKey(artist: row.artist, title: row.title)
            let newer = newerSame[familyKey, default: 0]
            newerSame[familyKey] = newer + 1
            guard let total = totals[playCountKey(row.artist, row.title)] else { return nil }
            let n = total - newer
            return n > 0 ? n : nil
        }
    }
}

/// 「最近记录」里**连续**听同一首歌的几行折成一组(单曲循环时一屏全是同一首)。
///
/// 「同一首」用的是跟次数换算同一把尺子 `PlayCountFold.familyKey`:同一首歌的两种写法
/// (繁简 / 中英署名)在次数上是连着数的(第 5 次、第 6 次),折叠时也必须当成同一首,
/// 否则会出现「上一组第 1–5 次、紧挨着的下一组第 6–7 次」这种一眼就是同一首歌的两组。
public enum RecentRepeatRuns {
    /// - Parameter rows: 按时间倒序、实际要显示的行(调用方已剔除不显示的行)。
    /// - Returns: 覆盖全部下标的连续区间,顺序不变;长度 1 的区间就是不折叠的单行。
    public static func runs(rows: [(artist: String, title: String)]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        var currentKey: String?
        for (i, row) in rows.enumerated() {
            let key = PlayCountFold.familyKey(artist: row.artist, title: row.title)
            if key != currentKey {
                if i > start { out.append(start..<i) }
                start = i
                currentKey = key
            }
        }
        if rows.count > start { out.append(start..<rows.count) }
        return out
    }
}
