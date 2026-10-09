import Foundation

/// Amazon Music 的播放位置。
///
/// 它在系统 Now Playing 里**不报 elapsedTime**:时间戳是这首真正出声(缓冲完)的时刻,暂停只翻 `playing`、
/// `playbackRate` 恒为 1、时间戳不动,拖动进度什么都不报。所以位置由这里自己算,分两层:
///
/// 1. **日志重放**:Amazon Music 把开播、暂停、恢复、拖动(精确到毫秒的目标位置)、缓冲卡顿实时写进
///    `~/Library/Application Support/Amazon Music/Logs/AmazonMusic.log`(命令发出后 50~75 毫秒落盘)。
///    `parse` 认这几种行,`apply` 推进状态,`position` 给出任意时刻的位置。拖动之后要等引擎进入 `kStarting`
///    才真正出声(实测同一秒到晚 1 秒多),表停在目标位置等这一行,见 `seekStartTimeout`。
/// 2. **自记时**:日志读不到、或者日志里没有这首歌的开播(措辞改了、文件被删),退回 `SelfTimer`:从系统
///    时间戳起算,扣掉观察到的暂停。拖动之后会错位,到下一首为止。
///
/// 调用方用 `reading` 在两层之间选。Go 侧 `amazonmusic.go` 同一套规则,两侧的测试读同一份样例
/// `shared/testdata/amazonmusic.log`。
///
/// **自动连播的提前量**:自然播完切下一首时,日志(`End of stream reached` + `new track playing`)和系统元数据都是在
/// 解码器读完上一首的那一刻换的,上一首还有一段在输出缓冲里没放完(实测 1.2~3.5 秒,每次不同,日志里推不准)。
/// 这样开播的那首标成 `startedNaturally`,位置要扣掉 `audibleLead`;这个量由 App 读 Amazon 界面上的播放时间校准
/// (`AmazonMusicUIProbe`),没校准前是 0。点播开头(缓冲完才出声)、拖动之后(缓冲清空)都不用扣。暂停不清缓冲,
/// 恢复后提前量照扣(恢复跟着的那次卡顿会触发重新校准,修掉恢复出声的零点几秒延迟)。
///
/// **缓冲卡顿之后也要重新校准**:日志里卡顿常是同一秒里起止,真正断音却有一截(实测一次卡顿后真实出声又晚了约 1.5 秒),
/// 所以卡过的曲目(不论怎么开的头)在卡顿平息后再对一次界面(`needsLeadCalibration`),校准出的量可正可负。
///
/// **一次校准不够准**:界面时间只到整秒,一次校准只能把起点圈进 0.45 秒宽的区间、取中点。校准过的一段隔 `leadRefineDelay`
/// 再对一次界面,两次的区间取交集(`needsLeadRefinement` / `calibratingLead`)。
public enum AmazonMusicPlayhead {
    /// 日志里认得的事件。
    public enum Event: Equatable, Sendable {
        /// 新的一首从 0 开始放。参数是曲目标识:`asin://<ASIN>` 取 ASIN,播客取整段 `podcast://…`。
        case trackStarted(String)
        case paused
        case resumed
        /// 拖到某个位置(秒)。
        case seek(Double)
        /// 缓冲卡顿开始 / 结束。卡顿期间表停。
        case stall(Bool)
        /// 引擎进入 `kStarting`(开始出声)。拖动之后等的就是它。
        case starting
        /// 解码器读完这一首(`End of stream reached`)。紧跟着的开播是自然连播。
        case endOfStream
    }

    /// 解析一行日志。认不出的行返回 nil。`lineTime` 是行首的时刻,日志只精确到秒(UTC,`YYMMDD:HHMMSS`)。
    public static func parse(line: String) -> (lineTime: Date, event: Event)? {
        guard let lineTime = lineTimestamp(line) else { return nil }
        if let r = line.range(of: "new track playing : ") {
            let uri = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let id = trackID(fromURI: uri) else { return nil }
            return (lineTime, .trackStarted(id))
        }
        // 暂停认引擎的 `setPaused(1)`(控制层那行 `setPaused , paused = true` 不认),外加播放回调
        // `Received callback with paused state: 1`:起播失败(Track Initialization Failed)后引擎自己停下时只有回调这一行。
        // 重复的暂停不改状态;回调里的 0 不当恢复(重复的恢复会把计时起点挪后),恢复只认 `setPaused(0)`。
        if line.contains("setPaused(1)") || line.contains("Received callback with paused state: 1") { return (lineTime, .paused) }
        if line.contains("Entering kStarting state") { return (lineTime, .starting) }
        if line.contains("End of stream reached") { return (lineTime, .endOfStream) }
        if line.contains("setPaused(0)") { return (lineTime, .resumed) }
        if let r = line.range(of: "function seek : Seeking to: ") {
            let digits = line[r.upperBound...].prefix { $0.isNumber }
            guard let ms = Double(digits) else { return nil }
            return (lineTime, .seek(ms / 1000))
        }
        if let r = line.range(of: "Received callback with stalled state: ") {
            switch line[r.upperBound...].first {
            case "1": return (lineTime, .stall(true))
            case "0": return (lineTime, .stall(false))
            default: return nil
            }
        }
        return nil
    }

    /// `asin://B0EXAMPLE:15:87015` → `asin://B0EXAMPLE`;`podcast://…` 原样。
    static func trackID(fromURI uri: String) -> String? {
        if uri.hasPrefix("asin://") {
            let rest = uri.dropFirst("asin://".count)
            let asin = rest.prefix { $0 != ":" }
            return asin.isEmpty ? nil : "asin://" + asin
        }
        if uri.hasPrefix("podcast://") { return uri }
        return nil
    }

    private static let lineTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMdd:HHmmss"
        return f
    }()

    public static func lineTimestamp(_ line: String) -> Date? {
        guard line.count >= 13 else { return nil }
        let head = String(line.prefix(13))
        guard head.dropFirst(6).first == ":", head.allSatisfy({ $0.isNumber || $0 == ":" }) else { return nil }
        return lineTimeFormatter.date(from: head)
    }

    /// 重放从哪个字节开始:末尾 `tailBytes`,但不晚于最后一次开播那一行(再往前留 `replayLead`,带上紧挨着它的
    /// `End of stream`,自然连播要靠它认)。开播后暂停得久,Amazon 照样往日志里写,开播行会被推到末尾那段之前:实测暂停
    /// 54 分钟后开播行离末尾 303 KB,只看末尾就认不出这首、退回自记时,位置按开播时刻一路外推到曲尾卡住。
    /// 同 Go 侧 amazonReplayStart。纯函数。
    public static func replayStart(_ data: Data, tailBytes: Int) -> Int {
        let bytes = [UInt8](data)
        let start = max(0, bytes.count - tailBytes)
        let needle = Array("new track playing".utf8)
        guard bytes.count >= needle.count else { return start }
        var last = -1
        var i = bytes.count - needle.count
        while i >= 0 {
            if bytes[i] == needle[0], Array(bytes[i ..< i + needle.count]) == needle { last = i; break }
            i -= 1
        }
        guard last >= 0, last < start else { return start }
        var back = max(0, last - replayLead)
        while back > 0, bytes[back - 1] != UInt8(ascii: "\n") { back -= 1 }
        return back
    }

    /// 见 `replayStart`。
    public static let replayLead = 4096

    /// 重放历史行时,行首只到秒,真实时刻落在 [该秒, 该秒 + 1),取中点。实时读到的行用读到的那一刻。
    public static let replayedLineOffset: TimeInterval = 0.5

    public struct State: Equatable, Sendable {
        /// 当前这首(`Event.trackStarted` 的参数)。nil = 日志里还没见过开播。
        public var trackID: String?
        /// 这首开播的时刻(日志口径)。
        public var trackStartedAt: Date?
        /// `since` 那一刻的位置;表停着时就是当前位置。引擎口径,不扣 `audibleLead`(扣只在 `position` 里扣一次)。
        public var base: Double = 0
        /// 表从这一刻开始走;nil = 停着(暂停或卡顿)。
        public var since: Date?
        public var paused = false
        public var stalled = false
        /// 开播之后没暂停、没拖动过。只有这时才能拿系统时间戳校准起点,见 `calibrated`。
        public var pristine = false
        /// 拖动之后还没等到 `kStarting`:表停在目标位置,最晚到这一刻起表(见 `seekStartTimeout`)。
        public var awaitingStartUntil: Date?
        /// 最近一次解码器读完一首的时刻。
        public var lastEndOfStreamAt: Date?
        /// 这首是自然连播开的头(开播前 `naturalAdvanceWindow` 内有 `endOfStream`),位置领先真正出声一段。
        public var startedNaturally = false
        /// 位置要扣掉的量(秒):自然连播时上一首还没放完的那段。没校准前是 0。
        public var audibleLead: Double = 0
        /// `audibleLead` 已经按界面校准过。
        public var leadCalibrated = false
        /// 提前量所在的区间(这一段几次校准的交集),`audibleLead` 取它的中点。nil = 还没校准,或者暂停之后不再拿来叠。
        public var leadRange: ClosedRange<Double>?
        /// 最近一次校准的时刻,以及这一段在首次校准之后又叠过几次(见 `needsLeadRefinement`)。
        public var leadCalibratedAt: Date?
        public var leadRefinements = 0
        /// 这首卡顿过,要重新对一次界面。
        public var stalledSinceCalibration = false
        /// 最近一次卡顿事件的时刻(调用方等它平息再校准)。
        public var lastStallAt: Date?

        public init() {}
    }

    public static func apply(_ event: Event, at t: Date, to state: State) -> State {
        var s = state
        switch event {
        case .trackStarted(let id):
            s.trackID = id
            s.trackStartedAt = t
            s.base = 0
            s.paused = false
            s.pristine = true
            s.awaitingStartUntil = nil
            s.startedNaturally = s.lastEndOfStreamAt.map { t.timeIntervalSince($0) <= naturalAdvanceWindow } ?? false
            s.lastEndOfStreamAt = nil
            s.audibleLead = 0
            s.leadCalibrated = false
            s.leadRange = nil
            s.stalledSinceCalibration = false
            s.lastStallAt = nil
            s.since = s.stalled ? nil : t
        case .endOfStream:
            s.lastEndOfStreamAt = t
        case .paused:
            s.base = engineTimelinePosition(s, at: t) ?? 0
            s.paused = true
            s.since = nil
            s.awaitingStartUntil = nil
            s.pristine = false
            // 暂停后 `calibrated` 不再把起点换成系统时间戳,日志时钟的零点可能挪了不到一秒,暂停前量的区间不能再叠。
            s.leadRange = nil
        case .resumed:
            s.paused = false
            if !s.stalled { s.since = t }
        case .seek(let target):
            // 开播时也会先定位到 0,那一下不算拖动,那时位置还在 0 附近。放过 `seekToStartTolerance` 之后拖回 0
            // 是真拖动:不当拖动的话 `pristine` 留着,`calibrated` 会把起点换回这首开播时的系统时间戳,拖动被抹掉。
            let dragged = target > 0 || (engineTimelinePosition(s, at: t) ?? 0) > seekToStartTolerance
            s.base = max(0, target)
            s.since = nil
            s.awaitingStartUntil = (s.paused || s.stalled) ? nil : t.addingTimeInterval(seekStartTimeout)
            // 拖动会清空输出缓冲,之后按真正出声走,提前量归零。
            if dragged {
                s.pristine = false
                s.startedNaturally = false
                s.audibleLead = 0
                s.leadCalibrated = false
                s.leadRange = nil
                s.stalledSinceCalibration = false
            }
        case .starting:
            if s.awaitingStartUntil != nil {
                s.awaitingStartUntil = nil
                if !s.paused && !s.stalled { s.since = t }
            }
        case .stall(let on):
            s.lastStallAt = t
            if s.trackID != nil { s.stalledSinceCalibration = true }
            if on {
                s.base = engineTimelinePosition(s, at: t) ?? s.base
                s.stalled = true
                s.since = nil
                s.awaitingStartUntil = nil
            } else {
                s.stalled = false
                if !s.paused { s.since = t }
            }
        }
        return s
    }

    public static func position(_ s: State, at t: Date) -> Double? {
        guard let raw = engineTimelinePosition(s, at: t) else { return nil }
        return max(0, raw - s.audibleLead)
    }

    /// 按日志事件推出的位置,还没扣自动连播的提前量(校准要拿它跟界面上的时间比)。
    public static func engineTimelinePosition(_ s: State, at t: Date) -> Double? {
        guard s.trackID != nil else { return nil }
        if let deadline = s.awaitingStartUntil {
            return s.base + max(0, t.timeIntervalSince(deadline))
        }
        guard let since = s.since else { return s.base }
        return s.base + max(0, t.timeIntervalSince(since))
    }

    /// `endOfStream` 之后多久之内的开播算自然连播。实测两行在同一秒。
    public static let naturalAdvanceWindow: TimeInterval = 1.5
    /// 校准出的提前量超出这个范围就不采信(界面读错、读到别的曲目)。自动连播实测 1.2~3.5 秒;卡顿之后可能反过来慢,留负值。
    public static let audibleLeadRange: ClosedRange<Double> = -4...8

    /// 这首还要不要按界面校准:自然连播开的头还没校准过,或者校准之后又卡顿过。
    public static func needsLeadCalibration(_ s: State) -> Bool {
        s.trackID != nil && ((s.startedNaturally && !s.leadCalibrated) || s.stalledSinceCalibration)
    }

    /// 首次校准之后隔多久再对一次界面,把两次的区间叠起来。一次校准只把起点收到 `AmazonMusicUIProbe.targetWidth`(0.45 秒)
    /// 以内、取中点,误差可到 ±0.2 秒;同一段(没卡顿、没拖动、没暂停)的真实起点不变,两次区间的交集更窄。
    public static let leadRefineDelay: TimeInterval = 20
    /// 每段最多再叠几次。每次都要开关几次辅助功能树,让 Amazon 重建界面。
    public static let maxLeadRefinements = 1
    /// 区间已经窄到这个宽度就不再叠。
    public static let leadRefineWidth: Double = 0.2

    /// 现在能不能开始读界面:卡顿还没结束时界面时间停着,读了必然失败,还让播放器在缓冲见底、最吃力的时候重建整棵
    /// 辅助功能树;卡顿结束后再等 `settle`。只看最近一次卡顿事件的时刻不够,卡顿开始那一行过了 `settle` 也还在卡。
    public static func mayStartCalibration(_ s: State, now: Date, settle: TimeInterval) -> Bool {
        !s.stalled && (s.lastStallAt.map { now.timeIntervalSince($0) >= settle } ?? true)
    }

    /// 这一段要不要再对一次界面、把区间叠窄:首次校准过了 `leadRefineDelay`、之后没卡顿没暂停、区间还不够窄。
    public static func needsLeadRefinement(_ s: State, now: Date) -> Bool {
        guard s.trackID != nil, s.leadCalibrated, !s.stalledSinceCalibration, !s.paused, !s.stalled,
              s.leadRefinements < maxLeadRefinements, let range = s.leadRange, let at = s.leadCalibratedAt else { return false }
        return now.timeIntervalSince(at) >= leadRefineDelay && range.upperBound - range.lowerBound > leadRefineWidth
    }

    /// 界面读出这首的真实起点落在 `origin`(epoch 秒,位置 = 时刻 − 起点)里,`t` 是算的这一刻。换成提前量的区间
    /// (日志时钟 − 真实位置),要叠就跟之前的区间取交集(交集为空说明之前那次读错了,只信这次),提前量取中点记上。
    /// 中点不在 `audibleLeadRange` 里返回 nil(原样不动)。
    public static func calibratingLead(_ s: State, origin: ClosedRange<Double>, at t: Date) -> State? {
        let refining = needsLeadRefinement(s, now: t)
        guard needsLeadCalibration(s) || refining, let engine = engineTimelinePosition(s, at: t) else { return nil }
        let shift = engine - t.timeIntervalSince1970
        let measured = (origin.lowerBound + shift)...(origin.upperBound + shift)
        let range = refining ? intersectedLeadRange(s.leadRange, measured) : measured
        let lead = (range.lowerBound + range.upperBound) / 2
        guard audibleLeadRange.contains(lead) else { return nil }
        var out = s
        out.audibleLead = lead
        out.leadRange = range
        out.leadCalibrated = true
        out.leadCalibratedAt = t
        out.leadRefinements = refining ? s.leadRefinements + 1 : 0
        out.stalledSinceCalibration = false
        return out
    }

    /// 两次校准的提前量区间取交集;不相交(之前那次读错了)只信新的。纯函数。
    public static func intersectedLeadRange(_ previous: ClosedRange<Double>?, _ measured: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let previous else { return measured }
        let lo = max(previous.lowerBound, measured.lowerBound)
        let hi = min(previous.upperBound, measured.upperBound)
        return lo <= hi ? lo...hi : measured
    }

    /// 拖动之后最多等 `kStarting` 这么久。等不到(措辞改了)就按拖动时刻加这么多起表,不让表一直停着。
    public static let seekStartTimeout: TimeInterval = 2

    /// 定位到 0 时位置超过这么多秒才算拖动,不到的是开播时那一下定位。
    public static let seekToStartTolerance: TimeInterval = 1

    /// 系统时间戳就是这首真正出声的时刻,精确到微秒,比日志的秒级行首准。开播之后没暂停、没拖动过,
    /// 而且两者相差不大(同一次开播)时,把起点换成它。
    public static let calibrationWindow: TimeInterval = 15

    public static func calibrated(_ s: State, metadataTimestamp: Date?) -> State {
        guard s.pristine, s.base == 0, s.since != nil, let startedAt = s.trackStartedAt,
              let ts = metadataTimestamp else { return s }
        let lead = ts.timeIntervalSince(startedAt)
        guard lead >= -calibrationWindow, lead <= calibrationWindow else { return s }
        var out = s
        out.since = ts
        return out
    }

    /// 系统元数据跟日志里这首的开播对不对得上:元数据时间戳比日志开播早出这么多,就是上一次会话留下的旧曲目
    /// (Amazon Music 刚开播时偶尔先发一帧那种),先不采纳。
    public static let staleMetadataLead: TimeInterval = 5

    public static func metadataIsStale(_ s: State, metadataTimestamp: Date?) -> Bool {
        guard let startedAt = s.trackStartedAt, let ts = metadataTimestamp else { return false }
        return ts < startedAt.addingTimeInterval(-staleMetadataLead)
    }

    /// 日志里这首的开播能不能对上系统元数据(同一首歌)。对不上说明日志没记到这首,改用自记时。
    public static func logCovers(_ s: State, metadataTimestamp: Date?) -> Bool {
        guard let startedAt = s.trackStartedAt, let ts = metadataTimestamp else { return false }
        let lead = ts.timeIntervalSince(startedAt)
        return lead >= -staleMetadataLead && lead <= calibrationWindow
    }

    /// 读不到日志时的自记时:从系统时间戳起算,扣掉观察到的暂停。按曲目记,换歌从头起。
    public struct SelfTimer: Equatable, Sendable {
        public var trackKey: String
        public var base: Double
        public var since: Date?

        public init(trackKey: String, base: Double, since: Date?) {
            self.trackKey = trackKey
            self.base = base
            self.since = since
        }

        public func position(at t: Date) -> Double {
            guard let since else { return base }
            return base + max(0, t.timeIntervalSince(since))
        }
    }

    /// 推进自记时。`observedAt` 是这一拍观察到状态的时刻(暂停取 stream watcher 记下的那一刻,见调用方)。
    public static func advance(_ timer: SelfTimer?, trackKey: String, metadataTimestamp: Date?,
                               playing: Bool, observedAt: Date) -> SelfTimer {
        guard let timer, timer.trackKey == trackKey else {
            // 新的一首:系统时间戳就是出声的时刻。拿不到就从现在起。
            let start = metadataTimestamp.map { min($0, observedAt) } ?? observedAt
            if playing { return SelfTimer(trackKey: trackKey, base: 0, since: start) }
            return SelfTimer(trackKey: trackKey, base: max(0, observedAt.timeIntervalSince(start)), since: nil)
        }
        var next = timer
        switch (timer.since != nil, playing) {
        case (true, false):
            next.base = timer.position(at: observedAt)
            next.since = nil
        case (false, true):
            next.since = observedAt
        default:
            break
        }
        return next
    }

    /// 这一拍用哪层算出的位置。
    public enum Source: String, Sendable {
        case log
        case selfTimer
    }

    public struct Reading: Equatable, Sendable {
        public var position: Double
        public var source: Source
        /// 元数据是上一次会话留下的旧曲目,这一拍不该采纳。
        public var staleMetadata: Bool
    }

    /// 在两层之间选:日志对得上这首就用日志,否则用自记时。
    public static func reading(log: State?, timer: SelfTimer, metadataTimestamp: Date?, now: Date) -> Reading {
        if let log {
            if metadataIsStale(log, metadataTimestamp: metadataTimestamp) {
                return Reading(position: 0, source: .log, staleMetadata: true)
            }
            if logCovers(log, metadataTimestamp: metadataTimestamp),
               let p = position(calibrated(log, metadataTimestamp: metadataTimestamp), at: now) {
                return Reading(position: p, source: .log, staleMetadata: false)
            }
        }
        return Reading(position: timer.position(at: now), source: .selfTimer, staleMetadata: false)
    }
}
