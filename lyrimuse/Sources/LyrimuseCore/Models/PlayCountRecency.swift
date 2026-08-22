import Foundation

/// 「每个 key 最新一条收听是什么时候」—— 「第 N 次听」缓存作废判据的输入。
///
/// 为什么要有这个判据(2026-08-21 用户报「第 15 次听下面紧跟着第 21 次听」):原来只按
/// **页内出现次数变多**判作废,而连播同一首歌时最近记录那一页很快被它占满 —— 新的挤进来、
/// 旧的挤出去,页内次数**不再增长**,于是缓存的总次数永久冻结,而真实次数一路往上爬。
/// 实测那次缓存冻在 15,真实合计 22(《园游会》10 + 《園遊會》12 —— Last.fm 上是两个实体,
/// 歌手的简繁被 autocorrect 折了、歌名的没折)。而实时行是每次换歌现取的,显示 21。
///
/// 「最新一条收听的时刻往前走了」这个判据不会随页面被同一首歌占满而饱和。
///
/// 放在 LyrimuseCore 而不是跟 LastfmStatsService 待在一起:那个类在 App target 里
/// (要 SwiftUI),而 selftest 只依赖 LyrimuseCore。输入取成 `(key, date?)` 这种最小形态,
/// 上层负责把自己的行类型映射过来 —— 纯算术下沉,不把 App 的模型也拖进来。
public enum PlayCountRecency {
    /// 同一个 key 出现多次时取**最新**那条;date 为 nil 的项跳过(还没落库的"正在播放"
    /// 那条就是这种 —— 它不在 userplaycount 里,不该参与)。
    public static func newest(_ items: [(key: String, date: Date?)]) -> [String: Date] {
        var out: [String: Date] = [:]
        for item in items {
            guard let d = item.date else { continue }
            if let cur = out[item.key], cur >= d { continue }
            out[item.key] = d
        }
        return out
    }
}
