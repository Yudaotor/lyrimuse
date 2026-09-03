import Foundation

/// 按**绝对位置**把「最近记录」的第 N 页从已知行里拼出来(2026-09-03)。
///
/// 背景:此前翻页缓存是"按页存原始行",翻回去先原样端上、超过 5 分钟再背后重拉一次。
/// 但 Last.fm 的分页是"最新 N 条"上的偏移量——期间每进来 k 条新 scrobble,所有页的边界就
/// 整体下移 k 行,重拉回来的"现在的第 N 页"跟缓存那一版对不上,1–9 秒后整批被换掉(用户
/// 2026-09-03 报「切换页码的时候过了一会会突然重新换一批」)。
///
/// 改法:每份来源都知道自己在**当下**这份历史里的绝对起点——collector feed 的 50 行永远是
/// 位置 0 起;某个缓存页抓取时总数是 T、现在总数是 total,那它的起点就是 `(N-1)*pageSize +
/// (total - T)`。把这些来源按位置铺到第 N 页的 20 个槽位上,槽位全满、且没有同一条记录出现
/// 两次(手机迟到同步会把 scrobble 插进历史中段,这时纯偏移模型会错位一行,靠"同一 uts 出现
/// 两次"抓出来)→ 这一页**精确**,直接显示、不必再拉;有洞 → 返回 nil,调用方去网络取(转圈是
/// 明确的加载态,不是"先给一批假的再换")。
///
/// 纯函数,行类型泛化(Core 不认识 App 侧的 RecentTrack),身份由调用方给。
public enum LastfmPageComposer {
    /// 一份已知的连续行:`firstPosition` 是 rows[0] 在当下这份历史里的绝对位置(0 = 最新)。
    public struct Source<Row> {
        public let firstPosition: Int
        public let rows: [Row]

        public init(firstPosition: Int, rows: [Row]) {
            self.firstPosition = firstPosition
            self.rows = rows
        }
    }

    /// 缓存页在当下的绝对起点。`totalAtFetch` 是抓那一页时的账号总数;总数变小(用户删过记录)
    /// 时偏移模型不成立,返回 nil 让这份来源作废。
    public static func firstPosition(page: Int, pageSize: Int, totalAtFetch: Int, totalNow: Int) -> Int? {
        guard page >= 1, pageSize > 0, totalNow >= totalAtFetch else { return nil }
        return (page - 1) * pageSize + (totalNow - totalAtFetch)
    }

    /// 拼第 `page` 页(1 起)。`sources` 按可信度排序:先到先占槽。返回 nil = 拼不齐/有重复。
    /// 最后一页不满 `pageSize` 行是正常的(按 `total` 截),空页(page 超出范围)返回 nil。
    public static func compose<Row>(
        page: Int, pageSize: Int, total: Int,
        sources: [Source<Row>], identity: (Row) -> String
    ) -> [Row]? {
        guard page >= 1, pageSize > 0, total > 0 else { return nil }
        let lo = (page - 1) * pageSize
        let hi = min(page * pageSize, total)
        guard lo < hi else { return nil }
        var slots = [Row?](repeating: nil, count: hi - lo)
        for src in sources {
            guard src.firstPosition >= 0 else { continue }
            for (j, row) in src.rows.enumerated() {
                let pos = src.firstPosition + j
                guard pos >= lo, pos < hi else { continue }
                if slots[pos - lo] == nil { slots[pos - lo] = row }
            }
        }
        var out: [Row] = []
        out.reserveCapacity(slots.count)
        var seen = Set<String>()
        for slot in slots {
            guard let row = slot else { return nil }
            guard seen.insert(identity(row)).inserted else { return nil } // 同一条出现两次 = 错位
            out.append(row)
        }
        return out
    }
}
