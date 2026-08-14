import Foundation

// 对唱歌词的左右分栏 —— Apple Music 歌词页上那种"男声靠左、女声靠右"的排版。
//
// 数据从哪来:中文歌词源**把演唱者塞在正文里当前缀**,不是独立字段(Apple 自己用的是
// TTML 的 ttm:agent,每句都有明确归属,那个源我们拿不到)。实测用户缓存里 QQ 音乐/酷狗
// 的对唱曲是这样的:
//
//   [00:21.15]男：周末守着烤箱
//   [00:25.88]情人节也落单          ← 没有前缀
//   [00:30.39]红色炸弹一波一波轰炸    ← 没有前缀
//   [00:40.31]女：偏爱年轻女伴
//   [00:54.22]合：何时想戒掉流浪
//
// 《真爱等一下 (feat. 蔡健雅)》65 行里只有 22 行带前缀 —— 但这不是漏标,中文歌词的通行
// 写法就是"一个标记管到下一个标记"。所以往后延续是**读法**,不是猜测。
//
// ⚠️ 逐字时间轴里前缀是**跟第一个字粘在一起**的,共享同一个时间戳:
//   [21155,2620](21155,180,0)男：周(21335,320,0)末…
// 剥的时候只能改这个词的文本,不能把词整个删掉 —— 它扛着「周」的发声时间。
public enum LyricDuet {
    /// 一行歌词摆在哪一边。
    public enum Side: String, Equatable, Sendable {
        case leading
        case trailing
        /// 合唱(两人一起)。UI 上居中,跟任何一边都区分得开。
        case center
    }

    /// 认得的演唱者标记。
    ///
    /// 刻意**只认这一小撮已知词**,不接受任意的 "X：" 前缀:歌词文件里 `词：`/`曲：`/
    /// `编曲：`/`制作人：` 这类署名行虽然大多被 strippingCreditLines 滤掉了,但不是全部,
    /// 放开成通配会把它们误判成演唱者、连带把整首歌的左右分栏搞乱。
    ///
    /// 将来要支持 `陶喆：`/`蔡健雅：` 这种人名前缀,只需要放宽这个识别器 —— 左右怎么分是
    /// 下面 sides(for:) 按**出现顺序**定的,跟标记具体是什么词无关,那一步不用改。
    private static let soloMarkers = ["男声", "女声", "男", "女", "Male", "Female", "M", "F"]
    private static let groupMarkers = ["合唱", "齐唱", "合", "Both", "All", "Duet"]

    /// 从行首剥出演唱者标记。没有标记时 marker 为 nil、text 原样返回。
    ///
    /// 全角冒号(：)和半角冒号(:)都收,标记后面允许有空格。
    public static func splitMarker(_ text: String) -> (marker: String?, text: String) {
        // 剥完什么都不剩就当没有标记 —— 整行只有"男："的话剥成空行会让它在界面上凭空消失。
        split(text, allowEmptyRest: false)
    }

    /// 同上,但允许剥完为空 —— 给**逐字行的第一个词**用。
    ///
    /// 逐字数据里标记通常跟第一个字粘在一起(`男：周`),剥掉前缀改这个词的文本即可;但也
    /// 存在标记单独成词(`(t,d)男：` `(t,d)周`)的写法,那种情况剥完确实是空的,调用方应该把
    /// 这个词整个丢掉。整行文本那条路不能这么干(见 splitMarker),所以分成两个入口。
    public static func splitMarkerAllowingEmpty(_ text: String) -> (marker: String?, text: String) {
        split(text, allowEmptyRest: true)
    }

    private static func split(_ text: String, allowEmptyRest: Bool) -> (marker: String?, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // 长的先试,否则 "男" 会先命中 "男声" 的前半截,剩下一个孤零零的 "声" 留在正文里。
        for marker in (groupMarkers + soloMarkers).sorted(by: { $0.count > $1.count }) {
            for colon in ["：", ":"] {
                let prefix = marker + colon
                guard trimmed.hasPrefix(prefix) else { continue }
                let rest = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                if rest.isEmpty && !allowEmptyRest { return (nil, text) }
                return (marker, rest)
            }
        }
        return (nil, text)
    }

    private static func isGroup(_ marker: String) -> Bool { groupMarkers.contains(marker) }

    /// 给整首歌逐行定边。
    ///
    /// - 标记**向后延续**到下一个标记(见类型注释里那段真实数据)。
    /// - 左右按标记**首次出现的顺序**分,不写死性别:先出现的那位靠左。这样将来换成人名
    ///   前缀也不用改这里,而且遇到"女声先开口"的歌不会莫名把她推到右边。
    /// - 合唱类一律居中。
    /// - 第一个标记出现之前的行(前奏,以及整首都没有标记的歌)是 **nil = 没有对唱信息**,
    ///   不是 leading。这个区分很要紧:歌词窗口的默认排版是左对齐、悬浮窗的默认排版是
    ///   居中,把"没信息"和"左边那位"混成同一个值,悬浮窗上每一首普通歌都会莫名其妙从
    ///   居中变成靠左。各视图自己决定 nil 时用什么(`?? .leading` / `?? .center`)。
    public static func sides(for markers: [String?]) -> [Side?] {
        var order: [String] = [] // 已出现过的独唱标记,按首次出现排
        var current: Side?
        var out: [Side?] = []
        out.reserveCapacity(markers.count)
        for marker in markers {
            if let marker {
                if isGroup(marker) {
                    current = .center
                } else {
                    if !order.contains(marker) { order.append(marker) }
                    // 第 1 位靠左、第 2 位靠右;第 3 位及以后(极少见)回到左边,
                    // 总比凭空造出第三种排版好。
                    current = (order.firstIndex(of: marker) ?? 0) % 2 == 0 ? .leading : .trailing
                }
            }
            out.append(current)
        }
        return out
    }

    /// 一次算完:逐行剥掉标记、并给出每行该摆哪一边。
    ///
    /// 调用方拿到的 texts 是**已经剥掉标记**的正文 —— 前缀不该画在界面上(改动之前它是
    /// 真的画出来了,当前行的逐字填色还会从"男："开始扫)。
    public static func plan(lineTexts texts: [String]) -> (texts: [String], sides: [Side?]) {
        let split = texts.map { splitMarker($0) }
        return (split.map(\.text), sides(for: split.map(\.marker)))
    }
}
