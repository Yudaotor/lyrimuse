import Foundation

/// MV 的时间轴换算:把 MV 里「不是音乐」的片段(SponsorBlock 的 `music_offtopic`)扣掉,
/// MV 播到第 t 秒对应歌曲版的第几秒。歌词源只有歌曲版的时间轴,这个换算让歌词跟上画面。
///
/// 换算以**偏移**的形式交给歌词引擎(`offsetMs(atVideoMs:)`,叠进 `LocalPlaybackSource.applyOffsets`),
/// 所有歌词面和逐字填色都走引擎那一个偏移,进度条仍然显示视频时间。
///
/// 片段按位置分三种处理:
/// - 从 0 开始的片头:整首固定扣掉它的长度。片头里算出来是负的歌曲时间,落在第一句之前,不用停。
/// - 延伸到视频结尾的片尾:只在走过它之后才会碰到,那时已经在最后一句之后,不用停。
/// - 夹在中间的插段:进入之后歌词停在插段开始那一刻,走出来再整段扣掉。只有这一种会让偏移随时间连续变化。
///
/// 启用全部片段(`isComplete`)要过时长检查:设 kept = MV 时长 − 扣掉的总长,trailing = 片尾那段的长度(没有片尾为 0),
/// 歌曲版时长落在 [kept − durationToleranceSecs, kept + trailing + durationToleranceSecs] 里才算过。
/// 片尾只放宽「片尾盖住了歌曲尾音」这一个方向:它只决定歌在哪儿结束,那时已经过了最后一句,不影响同步;
/// kept 比歌曲版长出容差以上(有片段没标全)照旧不过。这道检查挡掉两种会越修越错的情况:片段只标了一头,
/// 以及 MV 本身是另一个剪辑。检查不过、或者还不知道歌曲版时长时只扣片头:片头标的就是「这段不是音乐」,
/// 扣掉它在任何情况下都不比不扣差,而且不用等歌词判决。
/// 平移只作用于显示,不写进歌词缓存、导出文件或任何会分发出去的地方:SponsorBlock 的数据是
/// CC BY-NC-SA 4.0,不能打包、也不能经我们转发(见 02 章决策 50)。
public struct MusicVideoTimeline: Equatable, Sendable {
    public struct Cut: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// 合并、裁剪到 `[0, videoDurationSecs]` 之后的片段,按起点升序。
    public let cuts: [Cut]
    public let videoDurationSecs: Double
    /// true = 通过了时长检查、用上了全部片段;false = 只扣了片头。
    public let isComplete: Bool

    /// 「剪完的 MV」与歌曲版时长最多差多少秒仍然启用(片尾方向另有放宽,见类型头注)。
    public static let durationToleranceSecs: Double = 3
    /// 起点在这个值以内的片段按片头处理;终点离视频结尾在这个值以内的按片尾处理(SponsorBlock 的
    /// 片段端点常差零点几秒,如《One More Time》MV 的 `[0, 0.6]`)。
    public static let edgeSlackSecs: Double = 1

    /// 哪些 `musicVideoType` 算 MV。OMV = 官方 MV,UGC = 用户上传;ATV(歌曲版)与读不到的都不算。
    /// 与 collector 的 `ytmusicIsMusicVideoType` 同一份白名单,两边一起改。
    public static func isMusicVideoType(_ type: String?) -> Bool {
        type == "MUSIC_VIDEO_TYPE_OMV" || type == "MUSIC_VIDEO_TYPE_UGC"
    }

    /// 建时间轴。`songDurationSecs` 为 nil = 还不知道。检查通过用全部片段;否则只留片头,连片头都没有返回 nil。
    public static func make(cuts rawCuts: [Cut], videoDurationSecs: Double, songDurationSecs: Double?) -> MusicVideoTimeline? {
        guard videoDurationSecs > 0 else { return nil }
        let cuts = merged(rawCuts, videoDurationSecs: videoDurationSecs)
        guard !cuts.isEmpty else { return nil }
        if let song = songDurationSecs, song > 0 {
            let removed = cuts.reduce(0) { $0 + ($1.end - $1.start) }
            let kept = videoDurationSecs - removed
            let trailing = cuts.last.map { $0.end >= videoDurationSecs - edgeSlackSecs ? $0.end - $0.start : 0 } ?? 0
            if song >= kept - durationToleranceSecs, song <= kept + trailing + durationToleranceSecs {
                return MusicVideoTimeline(cuts: cuts, videoDurationSecs: videoDurationSecs, isComplete: true)
            }
        }
        let leading = cuts.filter { $0.start <= edgeSlackSecs }
        guard !leading.isEmpty else { return nil }
        return MusicVideoTimeline(cuts: leading, videoDurationSecs: videoDurationSecs, isComplete: false)
    }

    /// 裁剪到视频范围内、丢掉空片段、合并相互重叠的片段(众包数据里同一段常被标两次,
    /// 如 Tame Impala MV 的 `[0, 78.5]` 与 `[0, 1.2]`)。
    public static func merged(_ raw: [Cut], videoDurationSecs: Double) -> [Cut] {
        let clipped = raw
            .map { Cut(start: max(0, $0.start), end: min(videoDurationSecs, $0.end)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var out: [Cut] = []
        for c in clipped {
            if let last = out.last, c.start <= last.end {
                out[out.count - 1] = Cut(start: last.start, end: max(last.end, c.end))
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// 播到视频第 `videoMs` 毫秒时叠进歌词引擎的偏移(≤ 0)。歌曲时间 = 视频时间 + 偏移。
    public func offsetMs(atVideoMs videoMs: Int) -> Int {
        let t = Double(videoMs) / 1000
        var removed = 0.0
        for c in cuts {
            let isLeading = c.start <= Self.edgeSlackSecs
            let isTrailing = c.end >= videoDurationSecs - Self.edgeSlackSecs
            if isLeading {
                removed += c.end - c.start
            } else if t >= c.end {
                removed += c.end - c.start
            } else if t > c.start {
                // 夹在中间的插段:歌曲时间停在插段开始那一刻。片尾走进去时已经在最后一句之后,不用停。
                if !isTrailing { removed += t - c.start }
                break
            } else {
                break
            }
        }
        return -Int((removed * 1000).rounded())
    }

    /// 从歌词判决的候选明细(`DecisionSidecar.loadRecord` 读出的旁路记录)里取歌曲版时长:
    /// 优先取「此刻显示的那份歌词」的来源自报的曲长,取不到就取所有候选曲长的中位数。
    /// MV 本身不报歌曲版时长,这是唯一现成、而且跟显示的歌词同一版本的来源。
    public static func songDurationSecs(fromDecisionRecord record: [String: Any], lyricsSource: String?) -> Double? {
        var bySource: [String: Double] = [:]
        var all: [Double] = []
        for slot in ["applied", "latest"] {
            guard let s = record[slot] as? [String: Any],
                  let cands = s["candidates"] as? [[String: Any]] else { continue }
            for c in cands {
                guard let d = (c["source_reported_duration_secs"] as? NSNumber)?.doubleValue, d > 0 else { continue }
                all.append(d)
                if let src = c["source"] as? String, bySource[src] == nil { bySource[src] = d }
            }
        }
        if let src = lyricsSource, let d = bySource[src] { return d }
        guard !all.isEmpty else { return nil }
        let sorted = all.sorted()
        return sorted[sorted.count / 2]
    }
}
