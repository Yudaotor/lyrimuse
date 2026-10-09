import Foundation

/// 「搜索候选歌词」侧栏把搜索结果分成三组:正常的摆在列表里,跟别的候选一样又不多带东西的、评分时被排除的
/// 各收进一个默认折叠的组。放在 LyrimuseCore 是为了可测:面板在 app target 里,selftest 够不着。见 11 章决策 102。
public enum LyricsCandidateGroups {
    public enum Group: Equatable {
        case main
        /// 词和每行时间都跟排在前面的一条一样(`LyricsCandidateDuplicates` 的「内容相同」),而且没多带逐字时间轴、
        /// 译文、读音里任何一样。只有词一样、时间不同的不收:比的就是各家的时间轴。
        case sameAsAnother
        /// 评分时被排除(分数 -1,原因是 `scoreTerms` 第一项)。仍能预览、采用(纯文本的那条采纳为静态文本)。
        case excluded
    }

    public struct Traits: Equatable {
        public let source: String
        public let excluded: Bool
        public let hasWordTiming: Bool
        public let hasTranslation: Bool
        public let hasRomanization: Bool

        public init(source: String, excluded: Bool, hasWordTiming: Bool, hasTranslation: Bool, hasRomanization: Bool) {
            self.source = source
            self.excluded = excluded
            self.hasWordTiming = hasWordTiming
            self.hasTranslation = hasTranslation
            self.hasRomanization = hasRomanization
        }
    }

    /// source → 组。`duplicates` 是同一批候选按同一顺序算的 `LyricsCandidateDuplicates.firstMatches`。
    /// 锚是被排除的那条时不收:收起来之后列表里就看不到跟它一样的那一条了。
    public static func groups(
        _ items: [Traits], duplicates: [String: LyricsCandidateDuplicates.Match]
    ) -> [String: Group] {
        let bySource = Dictionary(items.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [String: Group] = [:]
        for item in items where out[item.source] == nil {
            if item.excluded {
                out[item.source] = .excluded
            } else if let match = duplicates[item.source], match.sameTimeline,
                      let anchor = bySource[match.anchor], !anchor.excluded,
                      !(item.hasWordTiming && !anchor.hasWordTiming),
                      !(item.hasTranslation && !anchor.hasTranslation),
                      !(item.hasRomanization && !anchor.hasRomanization) {
                out[item.source] = .sameAsAnother
            } else {
                out[item.source] = .main
            }
        }
        return out
    }
}

/// 候选的源自报曲长跟这首歌比。
public enum LyricsCandidateDuration {
    /// 相差超过较长那一方的这个比例,当成另一次录音标出来。跟引擎打分的 sourceDurationOff 同一个门槛(match.go)。
    public static let offRatio = 0.12
    /// 相差不到这么多秒不写差多少。
    public static let negligibleSecs = 2

    /// 候选比这首长多少秒(短为负),四舍五入;任一边不知道时长(≤ 0)时是 nil。
    public static func differenceSecs(candidate: Double, song: Double) -> Int? {
        guard candidate > 0, song > 0 else { return nil }
        return Int((candidate - song).rounded())
    }

    /// 是否差得算另一个版本;任一边不知道时长时不下结论。
    public static func isOff(candidate: Double, song: Double) -> Bool {
        guard candidate > 0, song > 0 else { return false }
        return abs(candidate - song) / max(candidate, song) > offRatio
    }

    /// 「4:31」「1:02:05」。
    public static func clock(_ secs: Double) -> String {
        let total = Int(secs.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
