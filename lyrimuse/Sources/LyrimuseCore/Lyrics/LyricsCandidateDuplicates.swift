import Foundation

/// 「搜索候选歌词」列表里的跨源同词标注(2026-09-04)。
///
/// 候选按来源一条一个,不同源经常给出逐字相同的词(同一份社区 LRC 被多家收录)。列表里
/// 把后到的那几条标成「歌词文字与 X 相同」——**只标注、不隐藏**:用户可能就是要选某个源拿它
/// 的译文或逐字轨,把"词相同"的候选整条丢掉会把这些增值内容一起丢掉。
///
/// 比对口径复用 `ManualPickLock.fingerprint(lyrics:)`(只取词、不含时间戳/YRC/译文)——那是
/// 追溯锁定的既有口径,跨 Go/Swift 有金标准钉着;这里只拿来展示,判宽判窄都不落盘。
///
/// 放在 LyrimuseCore 是为了可测:面板在 app target 里,selftest 够不着。
public enum LyricsCandidateDuplicates {
    /// 给**按名次排好**的候选算「这条跟前面哪一条的词逐字相同」。
    ///
    /// 返回 `source → 前面第一条同指纹候选的 source`。每组的首条(名次最高那条)不在结果里
    /// ——徽章挂在后来者身上,指向排在前面的那个;指纹为空(没有词)的候选既不当锚也不被标。
    /// 同一个 source 出现两次时以第一次为准(候选本来就一源一条)。
    public static func firstMatches(_ ordered: [(source: String, fingerprint: String)]) -> [String: String] {
        var anchorBySHA: [String: String] = [:]
        var out: [String: String] = [:]
        for item in ordered {
            guard !item.fingerprint.isEmpty, !item.source.isEmpty else { continue }
            if let anchor = anchorBySHA[item.fingerprint] {
                if anchor != item.source, out[item.source] == nil {
                    out[item.source] = anchor
                }
            } else {
                anchorBySHA[item.fingerprint] = item.source
            }
        }
        return out
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
