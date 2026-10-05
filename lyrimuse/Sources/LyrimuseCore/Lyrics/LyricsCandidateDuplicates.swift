import Foundation

/// 「搜索候选歌词」列表里的跨源同词标注。
///
/// 候选按来源一条一个,不同源经常给出一样的词(同一份社区 LRC 被多家收录)。列表里把后到的那几条
/// 标出来:词和每行时间都跟前面某一条一样的标「歌词内容与 X 相同」,只有词一样的标「歌词文字与 X 相同」。
/// **只标注、不隐藏**:用户可能就是要选某个源拿它的译文或逐字轨,把"词相同"的候选整条丢掉会把这些
/// 增值内容一起丢掉。逐字时间与译文不比,所以哪一档都不说「完全相同」。
///
/// 词的比对口径复用 `ManualPickLock.fingerprint(lyrics:)`(只取词、不含时间戳/YRC/译文)——那是
/// 追溯锁定的既有口径,跨 Go/Swift 有金标准钉着;每行时间按同一套取行规则另取(`lineTimestamps`)。
/// 这里只拿来展示,判宽判窄都不落盘。
///
/// 放在 LyrimuseCore 是为了可测:面板在 app target 里,selftest 够不着。
public enum LyricsCandidateDuplicates {
    /// 一条候选跟排在它前面的哪一条一样。
    public struct Match: Equatable {
        /// 排在前面、跟它一样的那条候选的 source。
        public let anchor: String
        /// true = 词和每行时间都一样;false = 只有词一样。
        public let sameTimeline: Bool

        public init(anchor: String, sameTimeline: Bool) {
            self.anchor = anchor
            self.sameTimeline = sameTimeline
        }
    }

    /// 每个时间戳最多差这么多仍算同一个时间轴:吸收毫秒写法(`[00:11.134]`)和百分秒写法(`[00:11.13]`)之间的取整。
    public static let timelineToleranceMs = 10

    /// 给**按名次排好**的候选算「这条跟前面哪一条一样」。
    ///
    /// 先找排在前面、词和每行时间都一样的第一条,找不到再退到词一样的第一条。每组的首条(名次最高那条)
    /// 不在结果里 ——徽章挂在后来者身上,指向排在前面的那个;指纹为空(没有词)的候选既不当锚也不被标。
    /// 同一个 source 出现两次时只认第一次(候选本来就一源一条)。
    public static func firstMatches(
        _ ordered: [(source: String, fingerprint: String, timeline: [[Int]])]
    ) -> [String: Match] {
        var seen = Set<String>()
        var earlier: [(source: String, fingerprint: String, timeline: [[Int]])] = []
        var out: [String: Match] = [:]
        for item in ordered {
            guard !item.fingerprint.isEmpty, !item.source.isEmpty, seen.insert(item.source).inserted else { continue }
            let sameText = earlier.filter { $0.fingerprint == item.fingerprint }
            if let same = sameText.first(where: { sameTimeline($0.timeline, item.timeline) }) {
                out[item.source] = Match(anchor: same.source, sameTimeline: true)
            } else if let first = sameText.first {
                out[item.source] = Match(anchor: first.source, sameTimeline: false)
            }
            earlier.append(item)
        }
        return out
    }

    /// 每一行挂的时间戳,毫秒。取行规则跟 `ManualPickLock.canonicalLyrics` 一样(按 Unicode 标量切行、去首尾空白、
    /// 剥掉行首的方括号标签、剥完是空的那行不算),所以跟只取词的指纹一行对一行;行首标签里认不出时间的
    /// (`[ti:…]` 这类)不算时间戳,一行挂几个时间就记几个。
    public static func lineTimestamps(_ lyrics: String) -> [[Int]] {
        var out: [[Int]] = []
        for rawScalars in lyrics.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = GoStringSemantics.trimSpace(rawScalars)
            var stamps: [Int] = []
            while line.unicodeScalars.first == "[", let end = line.unicodeScalars.firstIndex(of: "]") {
                let tag = String(line.unicodeScalars[line.unicodeScalars.index(after: line.unicodeScalars.startIndex)..<end])
                if let ms = timestampMs(tag) { stamps.append(ms) }
                line = GoStringSemantics.trimSpace(line.unicodeScalars[line.unicodeScalars.index(after: end)...])
            }
            if line.isEmpty { continue }
            out.append(stamps)
        }
        return out
    }

    /// 两份词一样的歌词每行时间是不是也一样:行数、每行时间戳的个数都相同,每个时间戳相差不超过
    /// `timelineToleranceMs`。
    public static func sameTimeline(_ a: [[Int]], _ b: [[Int]]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.count == y.count else { return false }
            for (p, q) in zip(x, y) where abs(p - q) > timelineToleranceMs { return false }
        }
        return true
    }

    /// `mm:ss.xx` / `mm:ss.xxx` / `mm:ss` → 毫秒;别的标签(`ti:…`、`offset:…`)返回 nil。
    private static func timestampMs(_ tag: String) -> Int? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0,
              parts[1].first?.isASCII == true, parts[1].first?.isNumber == true,
              let seconds = Double(parts[1]), seconds >= 0 else { return nil }
        return Int(((Double(minutes) * 60 + seconds) * 1000).rounded())
    }

    /// 「当前使用」的双判据:来源相同**且**词相同。任一侧拿不到指纹(这首歌还没有正文 / 候选
    /// 没有词)时退回只比来源——没有证据说它不是,不能因为拿不到证据就把徽章摘掉。
    public static func isCurrent(candidateSource: String, candidateFingerprint: String,
                                 currentSource: String?, currentFingerprint: String?) -> Bool {
        guard let currentSource, candidateSource == currentSource else { return false }
        guard let currentFingerprint, !currentFingerprint.isEmpty, !candidateFingerprint.isEmpty else {
            return true
        }
        return currentFingerprint == candidateFingerprint
    }
}
