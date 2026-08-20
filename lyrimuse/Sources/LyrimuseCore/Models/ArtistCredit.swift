import Foundation

/// 「多人合 credit」歌手串的拆分,以及由它派生的两条列表口径(播放次数合并 / 同专辑封面共识)。
///
/// 存在的理由是同一次收听会以**两种歌手写法**进 Last.fm:
///
/// - Mac 这边照抄 Apple Music 的逐曲 credit(`Daniel Caesar & Mustafa`);
/// - 手机那边(iPhone → Last.fm,再桥接回来)报的是主歌手(`Daniel Caesar`)。
///
/// 2026-08-20 实测坐实:同一首《Toronto 2014》08:58 从手机进来记在 `Daniel Caesar` 名下、
/// 11:11 从 Mac 进来记在 `Daniel Caesar & Mustafa` 名下 —— Last.fm 上是**两个实体**,于是
/// ①次数各记一本(两边都显示「第 1 次听」),②封面各挂一张(合唱实体挂的是「Toronto 2014」
/// 单曲封面,同专辑其它行挂的是专辑封面)。
///
/// ⚠️ 这里的"取第一位"**只用于列表口径的归并**,绝不能回写展示名/canonical_artist ——
/// 把 "A & B" 缩窄成 "A" 正是 2026-07-10 那次回归的形态。
public enum ArtistCredit {
    /// 合 credit 的分隔符。跟 collector 侧 `isArtistCreditSep`(match.go)同一份,
    /// **但 `/` 单独处理**(见 slashHeadIsPlausible)。
    private static let separators: Set<Character> = ["、", "&", ",", "，"]

    /// feat. 家族:`A feat. B` / `A (ft. B)` 也算多人 credit。
    private static let featMarkers = ["feat.", "feat ", "ft.", "ft ", "featuring"]

    /// 合 credit 串里的**第一位**;不是多人 credit(切不出第二段)时返回 nil ——
    /// nil 的语义是"没有'主歌手'这回事",调用方据此跳过归并,不要拿原串当主歌手。
    public static func primary(_ artist: String) -> String? {
        let trimmed = artist.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var head = trimmed
        // 先切 feat.:它常带括号(`A (feat. B)`),按分隔符切不开。
        // 直接在原串上做 .caseInsensitive 查找,不拿 lowercased() 的下标去索引原串 ——
        // 小写化对某些字符会改变长度(ß→ss),跨串用下标是错的。
        for marker in featMarkers {
            guard let r = trimmed.range(of: marker, options: [.caseInsensitive]) else { continue }
            let cut = String(trimmed[trimmed.startIndex..<r.lowerBound])
            if cut.count < head.count { head = cut }
        }
        head = head.trimmingCharacters(in: CharacterSet(charactersIn: " ([（"))
            .trimmingCharacters(in: .whitespaces)
        // 再按分隔符切。`/` 不在这一档里,只当兜底 —— 顺序本身就有意义:
        // 「K/DA, Madison Beer & (G)I-DLE」先撞上逗号,切出来的是完整的「K/DA」,
        // 而不是被 `/` 劈成「K」(2026-08-20 从真实历史里发现的这一例)。
        if let idx = head.firstIndex(where: { separators.contains($0) }) {
            head = String(head[head.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
        } else if let idx = head.firstIndex(of: "/") {
            let candidate = String(head[head.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            if slashHeadIsPlausible(candidate) { head = candidate }
        }
        guard !head.isEmpty, head.count < trimmed.count else { return nil }
        return head
    }

    /// 只有 `/` 一个分隔符时,切出来的头部像不像一个真的艺人名。
    ///
    /// `/` 是双面刃:网易云的合 credit 常写成 `陶喆/卢广仲`(该切),而 `K/DA`、`AC/DC`、
    /// `AJR`… 里的斜杠是名字自带的(切了就把一个人劈成「K」「AC」)。判据用长度,按书写系统
    /// 分档:含汉字的两个字就是完整名字(陶喆/方大同),纯拉丁两个字母几乎只可能是缩写的
    /// 前半截,要求 ≥3。判不准时**不切** —— 归并少做一次只是维持现状,切错会把两个不同的
    /// 艺人并成一个。
    private static func slashHeadIsPlausible(_ head: String) -> Bool {
        guard !head.isEmpty else { return false }
        let hasHan = head.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return head.count >= (hasHan ? 2 : 3)
    }

    /// 归并用的歌手键:多人 credit 归到第一位,单人原样。
    public static func mergeArtist(_ artist: String) -> String {
        primary(artist) ?? artist.trimmingCharacters(in: .whitespaces)
    }

    /// 同专辑封面共识的键:`归并歌手 + 专辑名`(都做小写/去首尾空白归一)。
    /// 专辑名为空返回 nil —— 空专辑不该互相共享封面(跟 LastfmStatsService.albumKey 同口径)。
    public static func albumConsensusKey(artist: String, album: String?) -> String? {
        guard let album = album?.trimmingCharacters(in: .whitespaces), !album.isEmpty else { return nil }
        return mergeArtist(artist).lowercased() + "|" + album.lowercased()
    }

    /// 一批列表行的「同专辑共识封面」。
    ///
    /// 只在**同一张专辑里至少两行挂着同一张图**时才认这张图是共识 —— 一行一张各不相同
    /// (合辑/每曲独立封面)时没有共识可言,返回里就没有这张专辑,调用方照原样用各自的图。
    ///
    /// 平票时取"出现在最前面(最新)的那张":recent 是倒序,最新的写法更可能是用户当下
    /// 在听的那个版本;而且要有确定性 —— 字典遍历顺序不保证稳定,不定序会让同一批行
    /// 每次刷新选出不同的封面。
    public static func albumConsensusCovers(
        rows: [(artist: String, album: String?, image: URL?)]
    ) -> [String: URL] {
        var tally: [String: [(url: URL, count: Int, firstIndex: Int)]] = [:]
        for (i, row) in rows.enumerated() {
            guard let image = row.image,
                  let key = albumConsensusKey(artist: row.artist, album: row.album) else { continue }
            var bucket = tally[key] ?? []
            if let pos = bucket.firstIndex(where: { $0.url == image }) {
                bucket[pos].count += 1
            } else {
                bucket.append((image, 1, i))
            }
            tally[key] = bucket
        }
        var out: [String: URL] = [:]
        for (key, bucket) in tally {
            guard let best = bucket.max(by: { a, b in
                a.count != b.count ? a.count < b.count : a.firstIndex > b.firstIndex
            }), best.count >= 2 else { continue }
            out[key] = best.url
        }
        return out
    }
}
