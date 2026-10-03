import Foundation

/// 译文 / 罗马音按原文内容配不上的那几行,「就近兜底」怎么处理。`LyricsSyncEngine.load` 对整首各算一次。
///
/// 内容键查不到时,引擎挂 700ms 内最近的那一条(`LyricsSyncEngine.nearestLine`)。这里在它前后各加一道:
/// - **不挂重复的**:就近那一条已经显示在别的行下面 —— 那一行按内容配上了它,或者那一行离它更近、也就近挂上了它
///   —— 而这一行跟那条所属的整行原句不相干:原文相似度低于 `unrelatedBelow`,那句原句(不短于 4 个字符)也没有
///   整句出现在这一行里。语气词、段落标记、歌名行、署名行抢隔壁那句的翻译就是这个形状;去掉的只是重复显示的那一份。
/// - **补漏**:附近一条都没有(或者上一条把它去掉了)时,从哪一行下面都还没显示过的整行里,找 `adoptWindowMs` 以内、
///   原文相似度不低于 `adoptAtLeast` 的那一句(时间最近的),挂它的;一句只补给一行。这一行的长度跟那句原句的比
///   要落在 `adoptLengthRatio` 里:译文只拦比原句短太多的半句碎片(半句挂整句的翻译),罗马音逐字对应,多一个字
///   就多一个音,调用方要求两行一样长。
/// 其余情况就近那一条照挂。整行与译文的时间戳有的源只精确到 10ms、有的精确到 1ms,对时间一律容许
/// `timeSlackMs` 的差。阈值与全库回放见 08 章决策 33。
public struct SecondaryLineFallback: Equatable {
    public struct Adoption: Equatable {
        public let key: String
        public let text: String
    }

    /// 不挂的行:行起点 → 这一行的内容键。
    public private(set) var suppressed: [Int: String] = [:]
    /// 补上的行:行起点 → 这一行的内容键与补上的那一条。
    public private(set) var adopted: [Int: Adoption] = [:]

    public static let unrelatedBelow = 0.5
    public static let adoptAtLeast = 0.8
    public static let adoptWindowMs = 5000
    public static let timeSlackMs = 10

    public init() {}

    /// - display:显示行(起点, 内容键),按起点升序;不含独占一行的演唱者标签。
    /// - base:整行(起点, 内容键),按起点升序。译文 / 罗马音的时间戳抄自它。
    /// - secondary:译文或罗马音那一轨,按起点升序。
    /// - matched:这个内容键能不能按内容查到(引擎的内容匹配字典)。
    public static func plan(display: [(timeMs: Int, key: String)], base: [(timeMs: Int, key: String)],
                            secondary: [LyricLine], matched: (String) -> Bool,
                            adoptLengthRatio: ClosedRange<Double>, nearTolerance: Int = 700) -> SecondaryLineFallback {
        var out = SecondaryLineFallback()
        guard !secondary.isEmpty, !display.isEmpty else { return out }
        let secondaryByTime = Dictionary(secondary.map { ($0.timeMs, $0.text) }, uniquingKeysWith: { _, new in new })
        var keysByTime: [Int: [String]] = [:]
        var timesByKey: [String: [Int]] = [:]
        for b in base where !b.key.isEmpty {
            keysByTime[b.timeMs, default: []].append(b.key)
            timesByKey[b.key, default: []].append(b.timeMs)
        }
        // 相邻两句的拼接键(同 LyricsSyncEngine.addAdjacentPairKeys,已有同名的单句键不覆盖)。
        for i in base.indices.dropLast() {
            let a = base[i], c = base[i + 1]
            guard !a.key.isEmpty, !c.key.isEmpty, timesByKey[a.key + c.key] == nil else { continue }
            timesByKey[a.key + c.key] = [a.timeMs, c.timeMs]
        }
        func near<T>(_ t: Int, in dict: [Int: T]) -> T? {
            if let v = dict[t] { return v }
            for d in 1...timeSlackMs {
                if let v = dict[t - d] ?? dict[t + d] { return v }
            }
            return nil
        }
        func contains(_ set: Set<Int>, near t: Int) -> Bool {
            (t - timeSlackMs...t + timeSlackMs).contains { set.contains($0) }
        }

        // 按内容显示出去的那些整行的起点。
        var contentShown = Set<Int>()
        for d in display where !d.key.isEmpty && matched(d.key) {
            contentShown.formUnion(timesByKey[d.key] ?? [])
        }
        // 内容键查不到的行就近会挂上哪一条,以及每一条离挂上它的行最近有多近。
        var nearOf: [Int: LyricLine] = [:]
        var closest: [Int: Int] = [:]
        for d in display where !matched(d.key) {
            guard let line = LyricsSyncEngine.nearestLine(secondary, d.timeMs, tolerance: nearTolerance) else { continue }
            nearOf[d.timeMs] = line
            closest[line.timeMs] = min(closest[line.timeMs] ?? Int.max, abs(line.timeMs - d.timeMs))
        }

        var shown = contentShown
        var waiting: [(timeMs: Int, key: String)] = []
        for d in display where !matched(d.key) {
            guard let line = nearOf[d.timeMs] else {
                if !d.key.isEmpty { waiting.append(d) }
                continue
            }
            let shownElsewhere = contains(contentShown, near: line.timeMs)
                || (closest[line.timeMs] ?? Int.max) < abs(line.timeMs - d.timeMs)
            if !d.key.isEmpty, shownElsewhere, let owners = near(line.timeMs, in: keysByTime), !owners.isEmpty,
               owners.allSatisfy({ unrelated(d.key, owner: $0) }) {
                out.suppressed[d.timeMs] = d.key
                waiting.append(d)
            } else {
                shown.insert(line.timeMs)
            }
        }

        for d in waiting {
            var best: (dt: Int, similarity: Double, timeMs: Int, text: String)?
            for b in base where !b.key.isEmpty && !contains(shown, near: b.timeMs) {
                let dt = abs(b.timeMs - d.timeMs)
                guard dt <= adoptWindowMs, let text = near(b.timeMs, in: secondaryByTime), !text.isEmpty else { continue }
                guard adoptLengthRatio.contains(Double(d.key.unicodeScalars.count) / Double(b.key.unicodeScalars.count))
                else { continue }
                let s = similarity(d.key, b.key)
                guard s >= adoptAtLeast else { continue }
                if let cur = best, cur.dt < dt || (cur.dt == dt && cur.similarity >= s) { continue }
                best = (dt, s, b.timeMs, text)
            }
            if let best {
                out.adopted[d.timeMs] = Adoption(key: d.key, text: best.text)
                shown.insert(best.timeMs)
            }
        }
        return out
    }

    /// 这一行跟那句原句不相干:原文相似度低于 `unrelatedBelow`,而且原句(不短于 4 个字符)没有整句出现在这一行里。
    public static func unrelated(_ key: String, owner: String) -> Bool {
        if owner.unicodeScalars.count >= 4 && key.contains(owner) { return false }
        return similarity(key, owner) < unrelatedBelow
    }

    /// 两个内容键的相似度:最长公共子序列占两边总长的比例(2·LCS / (|a| + |b|)),按 Unicode 标量算。
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: y.count + 1)
        var cur = prev
        for i in 1...x.count {
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return Double(2 * prev[y.count]) / Double(x.count + y.count)
    }
}
